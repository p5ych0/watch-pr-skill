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

while [ "$#" -gt 0 ]; do
    case "$1" in
        # A missing value is usage, not something to recover from: `shift 2 ||
        # true` left the same option in $1 and the parser span forever, hanging
        # the watch before it started.
        --interval) [ "$#" -ge 2 ] || { echo "$0: --interval needs a value" >&2; exit 2; }
                    INTERVAL="$2"; shift 2 ;;
        --timeout)  [ "$#" -ge 2 ] || { echo "$0: --timeout needs a value" >&2; exit 2; }
                    TIMEOUT="$2"; shift 2 ;;
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

waited=0
last=""
while :; do
    line="$("$STATE_SCRIPT" state "$PR" "$WHO" 2>&1)"; rc=$?
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
    # sha is not compared — this watch is never told which head it is waiting on,
    # and the helper resolves it per poll — so it is bound to the VERDICT record
    # below instead, which must describe the same commit the state came from.
    if [ "$r_pr" != "$PR" ] || [ "$r_who" != "$WHO" ]; then
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

    case "$state" in
        reviewed|blocked|dismissed)
            # Terminal. Report the verdict too, so the caller has the whole
            # answer without a second round-trip.
            verdict="$("$STATE_SCRIPT" verdict "$PR" "$WHO" 2>&1)"; vrc=$?
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
            # Same identity check as the state record, plus the sha: this pair of
            # calls is what PR_REVIEW_READY reports, so a verdict describing
            # another PR, another reviewer, or a DIFFERENT COMMIT than the state
            # that reached the terminal branch is not an answer about this poll.
            # The sha binding is what a push landing between the two calls looks
            # like, and it must stop the watch rather than pair a fresh state with
            # a stale verdict.
            if [ "$v_pr" != "$PR" ] || [ "$v_who" != "$WHO" ] || [ "$v_sha" != "$r_sha" ]; then
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
            printf 'PR_REVIEW_READY pr=%s reviewer=%s state=%s verdict=%s%s\n' \
                "$PR" "$WHO" "$state" "$v_field" "$v_tail"
            printf '%s\n' "$verdict"
            exit 0 ;;
    esac

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
    sleep "$nap"
    waited=$((waited + nap))
done
