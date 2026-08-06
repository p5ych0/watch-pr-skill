#!/usr/bin/env bash
# Block until a reviewer's review of the current head is actionable, printing a
# line whenever the state changes and one final line when it is.
#
#   pr-watch.sh <pr> <reviewer-login> [--interval SECONDS] [--timeout SECONDS]
#
#   0  a terminal state was reached — the last line says which
#   1  the timeout expired first
#   2  the state could not be read — fail closed, do NOT treat as "no findings"
#
# This exists because v2 removed v1's response monitor along with the bus, and
# with it the only channel that surfaced a finished review into the session. The
# replacement is not a daemon: it is one foreground command that exits when there
# is something to do, so a session can run it as a background watch (Claude Code:
# the Monitor tool) or simply block on it.
#
# It prints on CHANGE, not on every poll, so a long wait does not bury the
# session in identical lines.
#
# `set -uo pipefail`, NOT `-e`: pr-review-state.sh uses exit status as control
# flow. See CLAUDE.md § Bash conventions.
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_SCRIPT="${PR_WATCH_STATE_SCRIPT:-$SELF_DIR/pr-review-state.sh}"

INTERVAL="${PR_WATCH_INTERVAL:-30}"
TIMEOUT="${PR_WATCH_TIMEOUT:-3600}"
PR=""
WHO=""
AFTER_REVIEW=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        # A missing value is usage, not something to recover from: `shift 2 ||
        # true` left the same option in $1 and the parser span forever, hanging
        # the watch before it started.
        --interval) [ "$#" -ge 2 ] || { echo "$0: --interval needs a value" >&2; exit 2; }
                    INTERVAL="$2"; shift 2 ;;
        --timeout)  [ "$#" -ge 2 ] || { echo "$0: --timeout needs a value" >&2; exit 2; }
                    TIMEOUT="$2"; shift 2 ;;
        # The review id observed BEFORE the request was made. A re-request on an
        # UNCHANGED head — after a dismissal, or after answering a finding — has
        # nothing to distinguish the old terminal review from the new one, so the
        # first poll reported the previous pass as this round's and the loop acted
        # on it again. With this set, a terminal state whose authoritative review
        # is still that id is treated as "not yet".
        --after-review) [ "$#" -ge 2 ] || { echo "$0: --after-review needs a value" >&2; exit 2; }
                    AFTER_REVIEW="$2"; shift 2 ;;
        -*) echo "usage: $0 <pr> <reviewer-login> [--interval S] [--timeout S]" >&2; exit 2 ;;
        *) if [ -z "$PR" ]; then PR="$1"; elif [ -z "$WHO" ]; then WHO="$1"; fi; shift ;;
    esac
done

# Leading zeros are rejected, not normalised. The records below are matched
# against $PR as a STRING — `010` and `10` are the same PR to GitHub but never
# compare equal here, so an accepted `010` would make every well-formed record
# look like it belonged to another PR and the watch would fail closed forever.
case "$PR" in
    ""|0|0*|*[!0-9]*) echo "usage: $0 <pr> <reviewer-login> [--interval S] [--timeout S]" >&2; exit 2 ;;
esac
[ -n "$WHO" ] || { echo "usage: $0 <pr> <reviewer-login> [--interval S] [--timeout S]" >&2; exit 2; }
# Non-numeric values fall back to the defaults rather than aborting or, worse,
# becoming 0 — a zero interval would spin, and a zero timeout would return
# "timed out" before the first poll.
# Leading zeros are rejected, not accepted as digits: Bash reads them as octal, so
# `00` made `sleep` return at once and `waited` never advance — a spin — while
# `08`/`09` aborted inside the arithmetic below.
case "$INTERVAL" in 0|0*|*[!0-9]*|"") INTERVAL=30 ;; esac
case "$TIMEOUT"  in 0) ;; 0*|*[!0-9]*|"") TIMEOUT=3600 ;; esac

# Helper output quoted onto ONE line before it is printed as a diagnostic.
#
# The diagnostics below echo whatever the helper wrote, and this script's own
# output IS the signal channel: under Monitor, a line beginning PR_REVIEW_READY
# is what tells the session a review is finished. A failing helper that printed
# a newline followed by `PR_REVIEW_READY pr=… verdict=clean findings=0` therefore
# got that forged line surfaced as actionable even though the watch exited 2 —
# the exit status is not what the session reads.
#
# `%q` collapses newlines and control bytes into escapes, so nothing a helper
# emits can start a line of its own.
q() { printf '%q' "$1"; }

# An ABSOLUTE deadline, measured against the clock rather than accumulated from
# the sleeps. Counting only the naps excluded every second spent inside the head,
# state and verdict probes — so a run of slow GitHub reads made a one-hour watch
# run far past an hour, and a probe that hung meant the timeout check was never
# reached at all. `--timeout` has to mean elapsed time or it means nothing.
# The clock is READ with its status and its shape checked, like every other
# probe here. `date` can print a plausible epoch and then fail, and command
# substitution keeps it — an elapsed time stuck at a small number means the
# deadline is never reached and the watch runs forever, which is the failure this
# deadline exists to prevent.
now_s() {
    local t
    t="$(date +%s 2>/dev/null)" || return 1
    case "$t" in
        ""|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$t"
}
started="$(now_s)" || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
# Returns non-zero when the clock cannot be read, so callers branch rather than
# silently treating a failed read as "no time has passed". `echo $(( … ))` hid
# exactly that behind its own success.
elapsed_s() {
    local t
    t="$(now_s)" || return 1
    printf '%s' $(( t - started ))
}

# Run a probe under the REMAINING deadline.
#
# The elapsed checks only ran between probes, so a `gh` that hung inside one
# blocked forever and the deadline was never reached — and even a merely slow
# probe could start before the deadline and run arbitrarily past it. Each probe
# now gets its own limit, so `--timeout` bounds the whole watch and not just the
# gaps between its calls.
#
# `set -m` puts the probe in its own process group so the kill reaches anything
# `gh` spawned; without that a surviving child holds the capture pipe open and
# the substitution blocks regardless of the dead parent.
probe() {   # probe <limit-seconds> <command...> ; stdout on stdout, 124 on limit
    local limit="$1"; shift
    [ "$limit" -gt 0 ] || limit=1
    local out rc pid tmp
    # `mktemp`, not a constructed name. `/tmp/pr-watch.<pid>.<15-bit>` is
    # predictable and the redirection below truncates it, so on a shared host
    # another user who sees the watch PID can pre-create a matching symlink and
    # have the watch truncate any file the operator can write.
    tmp="$(mktemp "${TMPDIR:-/tmp}/pr-watch.XXXXXX")" || {
        echo "PR_REVIEW_WATCH state=error reason=no_probe_buffer" >&2
        return 125
    }
    set -m
    ( "$@" ) >"$tmp" 2>&1 &
    pid=$!
    set +m
    # Polled in FRACTIONS of a second where the platform allows it. At one-second
    # granularity every probe cost a full second even when the helper answered
    # immediately, which quietly turned `--timeout` into a budget the machinery
    # spent rather than one the reviewer got.
    local tick ticks n=0
    if sleep 0.2 2>/dev/null; then tick=0.2; ticks=$(( limit * 5 ))
    else tick=1; ticks="$limit"; fi
    while [ "$n" -lt "$ticks" ]; do
        kill -0 -"$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null || break
        # A failed `sleep` advanced the counter anyway, so the loop could burn
        # the limit at once and kill a healthy probe as a "timeout".
        sleep "$tick" || { rm -f "$tmp" 2>/dev/null; return 125; }
        n=$((n + 1))
    done
    if kill -0 -"$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null; then
        kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rm -f "$tmp" 2>/dev/null
        return 124
    fi
    wait "$pid"; rc=$?
    [ "$rc" -eq 124 ] && timed_out
    [ "$rc" -eq 125 ] && { echo "PR_REVIEW_WATCH state=error reason=probe_unreadable" >&2; exit 2; }
    # The READ has its own status, captured before `rm` overwrites `$?`. A `cat`
    # that emitted a complete, plausible record and then failed would otherwise
    # come back as the child's success, and the caller would accept a state or a
    # verdict from a buffer read that never finished.
    local crc
    out="$(cat "$tmp" 2>/dev/null)"; crc=$?
    rm -f "$tmp" 2>/dev/null
    [ "$crc" -eq 0 ] || return 125
    printf '%s' "$out"
    return "$rc"
}

# A probe that hit the remaining deadline IS the timeout, not an unreadable
# state: the wait ended because `--timeout` elapsed, which is what rc 1 means.
# Reporting it as rc 2 would tell the caller the state could not be read, and the
# contract answers those two differently — one waits, the other stops the round.
timed_out() {
    # The clock read here has its status taken too. Falling back to `$TIMEOUT`
    # turned a broken clock into a plausible ordinary timeout — and the driver
    # RE-ARMS on status 1, so the round would loop indefinitely instead of
    # stopping as unreadable. A timeout it cannot measure is not a timeout.
    #
    # NO ISOLATING FIXTURE, measured rather than assumed. Every arrangement that
    # breaks the clock trips one of the main-loop reads first, which already exit
    # 2 with `clock_unreadable` — so a mutant here is masked and a test would pass
    # either way. That also means the fail-closed BEHAVIOUR is covered; this guard
    # closes the narrow window where the clock survives every earlier read and
    # fails only on this one. Kept for that, not because a test proves it.
    local e
    e="$(elapsed_s)" || {
        echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=clock_unreadable" >&2
        exit 2
    }
    printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=timeout waited_s=%s\n' "$PR" "$WHO" "$e"
    exit 1
}

# Seconds left before the deadline, at least 1 so a probe is always attempted.
remaining_s() {
    local e
    e="$(elapsed_s)" || return 1
    local r=$(( TIMEOUT - e ))
    # An exhausted remainder is the TIMEOUT, not one more second. Clamping it let
    # a probe start after the deadline had already passed, and a verdict or
    # head-recheck begun there could still produce PR_REVIEW_READY.
    [ "$r" -lt 1 ] && return 2
    printf '%s' "$r"
}
waited=0
last=""
while :; do
    # ONE head per poll, resolved first and passed to both probes.
    #
    # Letting each call resolve its own head made the state and the verdict
    # describe different commits when a push landed between them, and comparing
    # their printed `sha=` fields could not detect it: the records abbreviate to
    # seven hex, and two heads can share a seven-hex prefix. Pinning both to a
    # full 40-hex OID removes the comparison rather than tightening it.
    #
    # Resolved per POLL, not once per watch, so the watch still follows the head
    # when a push lands between polls — which is the case it is there to notice.
    rem="$(remaining_s)"; rrc=$?
    [ "$rrc" -eq 2 ] && timed_out
    [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    head="$(probe "$rem" "$STATE_SCRIPT" head "$PR")"; hrc=$?
    [ "$hrc" -eq 124 ] && timed_out
    [ "$hrc" -eq 125 ] && { echo "PR_REVIEW_WATCH state=error reason=probe_unreadable" >&2; exit 2; }
    if [ "$hrc" -ne 0 ] || ! [[ "$head" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=head_unresolvable rc=%s detail=%s\n' \
            "$PR" "$WHO" "$hrc" "$(q "$head")"
        exit 2
    fi
    want_sha="${head:0:7}"

    rem="$(remaining_s)"; rrc=$?
    [ "$rrc" -eq 2 ] && timed_out
    [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    line="$(probe "$rem" "$STATE_SCRIPT" state "$PR" "$WHO" "$head")"; rc=$?
    [ "$rc" -eq 124 ] && timed_out
    [ "$rc" -eq 125 ] && { echo "PR_REVIEW_WATCH state=error reason=probe_unreadable" >&2; exit 2; }
    if [ "$rc" -ne 0 ]; then
        # ANY non-zero status, not just the helper's documented 2. A missing or
        # non-executable helper exits 126/127, and treating that as a state left
        # the watch polling stderr until it reported a timeout — which reads as
        # "wait or re-request" when the truth is "this cannot be read at all".
        #
        # An unreadable state is not "still waiting": the difference between "no
        # review yet" and "cannot tell" is the difference between waiting and
        # merging on a bad read.
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error rc=%s detail=%s\n' "$PR" "$WHO" "$rc" "$(q "$line")"
        exit 2
    fi

    # The WHOLE record is matched, not "the last state= token in whatever was
    # printed". Taking the trailing token accepted rc-0 noise such as
    # `warning: cached state=reviewed`, which then drove the watch into the
    # terminal path — or, as `state=none`, polled quietly to a timeout that the
    # contract reads as "re-request or ask whether to keep waiting".
    if [[ "$line" =~ ^PR_REVIEW_STATE\ pr=([0-9]+)\ sha=([0-9a-f]{7,40})\ reviewer=([^[:space:]]+)\ state=([a-z]+)$ ]]; then
        r_pr="${BASH_REMATCH[1]}"; r_sha="${BASH_REMATCH[2]}"
        r_who="${BASH_REMATCH[3]}"; state="${BASH_REMATCH[4]}"
    else
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=unparseable detail=%s\n' "$PR" "$WHO" "$(q "$line")"
        exit 2
    fi
    # WHOSE state, and on WHAT. Matching the record's SHAPE is not the same as
    # matching THIS poll: a well-formed `PR_REVIEW_STATE pr=999 sha=abcdef0
    # reviewer=other state=reviewed` returned by a misrouted wrapper or a stale
    # cache satisfied the pattern above and drove the loop into the terminal
    # verdict path for a review of a different PR by a different reviewer.
    #
    # Including the sha, which is now the head this poll pinned both probes to —
    # so a record about any other commit is rejected outright rather than merely
    # cross-checked against the other record.
    if [ "$r_pr" != "$PR" ] || [ "$r_who" != "$WHO" ] || [ "$r_sha" != "$want_sha" ]; then
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=record_identity_mismatch detail=%s\n' \
            "$PR" "$WHO" "$(q "$line")"
        exit 2
    fi
    case "$state" in
        none|pending|reviewed|blocked|dismissed) ;;
        *) printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=unknown_state detail=%s\n' "$PR" "$WHO" "$(q "$line")"
           exit 2 ;;
    esac
    if [ "$state" != "$last" ]; then
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=%s waited_s=%s\n' "$PR" "$WHO" "$state" "$waited"
        last="$state"
    fi

    # A terminal state that is still the review we were told to wait past is not
    # this round's answer.
    if [ -n "$AFTER_REVIEW" ]; then
        case "$state" in
            reviewed|blocked|dismissed)
                rem="$(remaining_s)"; rrc=$?
                [ "$rrc" -eq 2 ] && timed_out
                [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
                cur="$(probe "$rem" "$STATE_SCRIPT" review-id "$PR" "$WHO" "$head")"; crc2=$?
                [ "$crc2" -eq 124 ] && timed_out
                [ "$crc2" -ne 0 ] && { echo "PR_REVIEW_WATCH state=error reason=review_id_unreadable" >&2; exit 2; }
                if [ "$cur" = "$AFTER_REVIEW" ]; then
                    if [ "$last" != "stale" ]; then
                        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=awaiting_new_review after=%s waited_s=%s\n' \
                            "$PR" "$WHO" "$AFTER_REVIEW" "$waited"
                        last="stale"
                    fi
                    state="pending"
                fi ;;
        esac
    fi
    case "$state" in
        reviewed|blocked|dismissed)
            # Terminal. Report the verdict too, so the caller has the whole
            # answer without a second round-trip.
            rem="$(remaining_s)"; rrc=$?
    [ "$rrc" -eq 2 ] && timed_out
    [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
            verdict="$(probe "$rem" "$STATE_SCRIPT" verdict "$PR" "$WHO" "$head")"; vrc=$?
            [ "$vrc" -eq 124 ] && timed_out
            [ "$vrc" -eq 125 ] && { echo "PR_REVIEW_WATCH state=error reason=probe_unreadable" >&2; exit 2; }
            # Only 0 (clean) and 1 (not clean) are ANSWERS. Anything else — the
            # documented 2, or a 126/127 if the helper stops being executable
            # between the two calls — is unreadable, and this is the same class
            # the state probe above already guards.
            if [ "$vrc" -ne 0 ] && [ "$vrc" -ne 1 ]; then
                # PR_REVIEW_READY is THE signal that there is something to act on
                # — under Monitor it is what reaches the session. Emitting it and
                # then exiting 2 tells the session to act and the shell that it
                # could not be read, and the line is what gets noticed.
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error detail=%s\n' "$PR" "$WHO" "$(q "$verdict")"
                exit 2
            fi
            # The verdict LINE is validated, not just the exit status. A wrapper
            # that truncates stdout leaves an rc of 0/1 with no `verdict=` field,
            # and PR_REVIEW_READY is the actionable signal under Monitor — so an
            # unreadable verdict would be indistinguishable from a finished review.
            # An exact field, not a glob: `*verdict=clean*` also matched
            # `verdict=cleaned` and any line merely quoting the word, and
            # PR_REVIEW_READY is the actionable signal under Monitor.
            if [[ "$verdict" =~ ^PR_REVIEW_STATE\ pr=([0-9]+)\ sha=([0-9a-f]{7,40})\ reviewer=([^[:space:]]+)\ verdict=([a-z]+)(.*)$ ]]; then
                v_pr="${BASH_REMATCH[1]}"; v_sha="${BASH_REMATCH[2]}"
                v_who="${BASH_REMATCH[3]}"; v_field="${BASH_REMATCH[4]}"; v_tail="${BASH_REMATCH[5]}"
            else
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=unparseable_verdict detail=%s\n' \
                    "$PR" "$WHO" "$(q "$verdict")"
                exit 2
            fi
            # Same identity check as the state record, against the SAME pinned
            # head — not against the state record's own field. Comparing the two
            # records to each other could not tell two commits apart when their
            # seven-hex prefixes collided; comparing both to the 40-hex OID this
            # poll resolved cannot.
            if [ "$v_pr" != "$PR" ] || [ "$v_who" != "$WHO" ] || [ "$v_sha" != "$want_sha" ]; then
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=verdict_identity_mismatch detail=%s\n' \
                    "$PR" "$WHO" "$(q "$verdict")"
                exit 2
            fi
            # The verdict VALUE, its trailing field, and the exit status must all
            # agree. Accepting any `verdict=<word>` with any tail let through
            # `verdict=clean` with no `findings=0`, and — worse — a clean record
            # returned with rc 1, which PR_REVIEW_READY then announced as a
            # finished clean review and started the next phase on.
            case "$v_field/$vrc" in
                clean/0)    [ "$v_tail" = " findings=0" ] || v_field="" ;;
                findings/1) [[ "$v_tail" =~ ^\ findings=[0-9]+$ ]] || v_field="" ;;
                none/1)     [[ "$v_tail" =~ ^\ reason=[a-z_]+$ ]] || v_field="" ;;
                *)          v_field="" ;;
            esac
            if [ -z "$v_field" ]; then
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=inconsistent_verdict rc=%s detail=%s\n' \
                    "$PR" "$WHO" "$vrc" "$(q "$verdict")"
                exit 2
            fi
            # The verdict must describe the SAME state the terminal branch was
            # entered on. These are two separate fetches, and the review can move
            # between them without the head moving at all — a re-review opens and
            # `reviewed` becomes PENDING, or a CHANGES_REQUESTED is superseded by
            # an approval. The verdict then legitimately reports the new state
            # while `$state` still holds the old one, and announcing
            # PR_REVIEW_READY on that pair reports a finished pass that is not
            # finished. The reason field is exactly what says so:
            #
            #   state=reviewed  -> clean or findings; `none` means it moved
            #   state=blocked   -> reason=blocked   (terminal, body carries it)
            #   state=dismissed -> reason=dismissed (terminal, re-request)
            #   reason=review_state_changed -> the helper's own re-check caught it
            #
            # A mismatch is not an error: it means this poll is out of date, so
            # the loop goes round again and reports whatever is true then.
            v_reason="${v_tail# reason=}"
            agree=1
            case "$state" in
                reviewed)  [ "$v_field" = "clean" ] || [ "$v_field" = "findings" ] || agree=0 ;;
                blocked)   { [ "$v_field" = "none" ] && [ "$v_reason" = "blocked" ]; } || agree=0 ;;
                dismissed) { [ "$v_field" = "none" ] && [ "$v_reason" = "dismissed" ]; } || agree=0 ;;
                *)         agree=0 ;;
            esac
            if [ "$agree" -eq 0 ]; then
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=moved_between_probes observed=%s verdict=%s%s waited_s=%s\n' \
                    "$PR" "$WHO" "$state" "$v_field" "$v_tail" "$waited"
                # The next poll's state is about a review that has changed, so the
                # change-suppression memory must not hide it.
                last=""
                waited="$(elapsed_s)" || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
                if [ "$waited" -ge "$TIMEOUT" ]; then
                    printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=timeout waited_s=%s\n' "$PR" "$WHO" "$waited"
                    exit 1
                fi
                nap="$INTERVAL"
                remaining=$((TIMEOUT - waited))
                [ "$nap" -gt "$remaining" ] && nap="$remaining"
                # COVERAGE, stated accurately after measuring rather than assuming.
    #
    # An earlier version of this comment claimed the INTER-POLL guard was the
    # uncovered one. That was wrong: removing it fails four assertions. It is the
    # MOVED-HEAD sleep guard, in the terminal branch above, that no fixture
    # isolates — the two paths emit the same `reason=sleep_failed` record, so a
    # mutant on either is masked by the other and both variants exit 2 identically.
    #
    # Both guards are kept because both are correct; one of them is proven by
    # test and one is not, and the file says which rather than letting the
    # assertion count imply otherwise.
    #
    # A failed sleep here would launch the next round of GitHub probes at once,
    # hammering the API until the clock expired and then reporting an ordinary
    # timeout — so a broken scheduler looked exactly like a slow review.
    sleep "$nap" || { echo "PR_REVIEW_WATCH state=error reason=sleep_failed" >&2; exit 2; }
                waited="$(elapsed_s)" || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
                continue
            fi
            # The head is re-resolved AFTER the verdict, and READY is withheld
            # unless it is still the one both probes were pinned to.
            #
            # Pinning made the state and the verdict describe the same commit. It
            # did not make that commit current: a push landing after the head
            # probe leaves both probes correctly describing the OLD head, and
            # announcing that as READY advances the driver on a review of code
            # that is no longer there — step 7 would then capture the NEW head as
            # the Codex-signed-off sha, and nothing would notice until the merge
            # gate failed.
            #
            # A moved head is not an error: it means this poll's answer is stale
            # and the next poll should ask about the new head. So the loop
            # CONTINUES rather than exiting — the new head has no review yet, so
            # it reports `none` and goes back to waiting, which is the truth.
            rem="$(remaining_s)"; rrc=$?
    [ "$rrc" -eq 2 ] && timed_out
    [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
            head_now="$(probe "$rem" "$STATE_SCRIPT" head "$PR")"; nrc=$?
            [ "$nrc" -eq 124 ] && timed_out
            [ "$nrc" -eq 125 ] && { echo "PR_REVIEW_WATCH state=error reason=probe_unreadable" >&2; exit 2; }
            if [ "$nrc" -ne 0 ] || ! [[ "$head_now" =~ ^[0-9a-f]{40}$ ]]; then
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=head_recheck_failed rc=%s detail=%s\n' \
                    "$PR" "$WHO" "$nrc" "$(q "$head_now")"
                exit 2
            fi
            if [ "$head_now" != "$head" ]; then
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=head_moved from=%s to=%s waited_s=%s\n' \
                    "$PR" "$WHO" "${head:0:7}" "${head_now:0:7}" "$waited"
                # The next poll's state is about a different commit, so the
                # change-suppression memory must not hide it.
                last=""
            else
                printf 'PR_REVIEW_READY pr=%s reviewer=%s state=%s verdict=%s%s\n' \
                    "$PR" "$WHO" "$state" "$v_field" "$v_tail"
                printf '%s\n' "$verdict"
                exit 0
            fi
            ;;
    esac

    waited="$(elapsed_s)" || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    if [ "$waited" -ge "$TIMEOUT" ]; then
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=timeout waited_s=%s\n' "$PR" "$WHO" "$waited"
        exit 1
    fi
    # Never sleep past the deadline. A full interval was slept before the timeout
    # was re-checked, so `--timeout 1` with the default 30s interval waited 30
    # seconds to report a one-second timeout — and any caller whose timeout is
    # shorter than the interval saw the same.
    nap="$INTERVAL"
    remaining=$((TIMEOUT - waited))
    [ "$nap" -gt "$remaining" ] && nap="$remaining"
    # A failed sleep here would launch the next round of GitHub probes at once,
    # hammering the API until the clock expired and then reporting an ordinary
    # timeout — so a broken scheduler looked exactly like a slow review.
    sleep "$nap" || { echo "PR_REVIEW_WATCH state=error reason=sleep_failed" >&2; exit 2; }
    waited="$(elapsed_s)" || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
done
