#!/usr/bin/env -S bash -p
# Block until a reviewer's review of the current head is actionable, printing a
# line whenever the state changes and one final line when it is.
#
#   pr-watch.sh <pr> <reviewer-login> [--interval SECONDS] [--timeout SECONDS]
#               [--after-review ID | --after-review-file PATH]
#
#   0  a terminal state was reached — the last line says which
#   1  the timeout expired first
#   2  the state could not be read — fail closed, do NOT treat as "no findings"
#   4  the review carried comments and every one of them was a REPLY. There is
#      nothing for `pr-findings.sh` to list and it is not a signoff, so this is
#      neither "fix these" nor "move on": a human reads the one comment.
#
#      IT HAS ITS OWN STATUS BECAUSE EVERY CALLER ALREADY BRANCHES ON STATUS. The
#      first attempt said it only in the record, and the one caller that was not
#      taught to read the record — `pr-close-round.sh`, waiting on the pass a push
#      started — took the 0 and closed the round, which is the stop not happening.
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
# ── STARTED PRIVILEGED, OR NOT STARTED ─────────────────────────────────────
#
# The shebang above is `env -S bash -p`, and that is the defence this block
# exists to state. An ordinary `#!/usr/bin/env bash` SOURCES `BASH_ENV`, IMPORTS
# functions from the environment, and honours an exported `SHELLOPTS` — so every
# builtin this script uses is a name the operator's shell can replace, and each
# one found took a review round of its own: `type`, `return`, `set`, `echo`,
# `exit`. Privileged mode does none of the three, so there is nothing to shadow
# and nothing to clear. Measured: under `BASH_FUNC_echo%` and `BASH_FUNC_set%`,
# a privileged shell reports both as builtins.
#
# THE HOOK CANNOT BE OUT-RUN FROM IN HERE, which is why this is the shebang and
# not a re-exec. A `BASH_ENV` hook runs before this file's first line, and one
# that prints a forged `PR_REVIEW_WATCH state=error` line and exits has already answered the
# caller — no later re-exec takes that back. The interpreter has to be privileged
# from the start, which only the shebang or the caller can arrange.
#
# WHAT STARTS IT PRIVILEGED IS THE CALLER, AND THE SHEBANG IS THE FALLBACK.
# `SKILL.md` invokes every helper as `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-x.sh`,
# which starts a fresh privileged interpreter whatever the driving shell is and
# whatever that platform's `env` supports. The shebang covers the other way in —
# executing the file directly — and needs `env -S`, which is why it is not the
# thing relied on.
#
# `$-` IS A LAST-RESORT REFUSAL AND PROVES LESS THAN IT LOOKS. It reports the
# MODE this shell is in, not how it got there: run as `BASH_ENV=hook bash
# pr-x.sh`, the hook is sourced BEFORE this line and can itself run `set -p` and
# then define `echo` or `exit`, after which `$-` contains `p` and this test
# passes on a shell that has already executed hostile code. Nothing inside a
# script can detect work done before its first line — so this catches the honest
# mistake, and `bash pr-x.sh` is UNSUPPORTED rather than defended. Measured:
# `BASH_ENV=/tmp/h bash -c 'printf "%s %s" "$-" "$(type -t echo)"'` with a hook
# running `set -p; echo() { :; }` prints `hpBc function`.
if [[ $- != *p* ]]; then
    echo "PR_REVIEW_WATCH state=error reason=not_privileged" >&2
    exit 2
fi

set -uo pipefail

# The shared shape rules. `pr-watch.sh` validates helper OUTPUT rather than API
# records, but "a full commit SHA" must mean one thing across the plugin — it was
# written out twice here as a Bash regex while three other scripts each had their
# own jq copy. See recordlib.sh and issue #11.
_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_REVIEW_WATCH state=error reason=lib_dir_unresolvable" >&2; exit 2; }
# The library loader — and it obeys its own rule. A helper cannot load the file
# that defines it, so this sequence is written out here; an exported `rb_load`
# survives into this shell and an empty `loadlib.sh` still sources successfully,
# so without the clear the first load runs the INHERITED function — and a stale
# loader is the one thing that can make every OTHER load look clean. See
# loadlib.sh and issue #22.
unset -f rb_load 2>/dev/null || {
    echo "PR_REVIEW_WATCH state=error reason=loadlib_stale_definition" >&2; exit 2; }
# NO `type -t rb_load` PREFLIGHT. It verified the loader by asking `type`, which
# is a NAME — and while a privileged interpreter means no function by that name
# can be imported, verifying a thing by asking a second thing about it is the
# shape #88 is about: the answer is only as good as the asker. The FIRST LOAD is
# the verification instead: the stub below is what an empty `loadlib.sh` leaves
# behind, and calling it fails. Nothing is asked ABOUT the loader — the load
# itself is the answer.
#
# THE REFUSING STUB IS WHAT MAKES THAT TRUE. Without it, an `rb_load` that is not
# a function is looked up on `PATH` — privileged mode does not change `PATH` —
# and an executable by that name exiting 0 would report every load successful
# with nothing cleared and no library sourced. Defining it means the call cannot
# leave this shell: a good `loadlib.sh` replaces the stub when sourced, an empty
# one leaves the refusal. `return` is a builtin and nothing can shadow it here,
# because a privileged shell imports no functions. #88.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_REVIEW_WATCH state=error reason=loadlib_unreadable" >&2; exit 2; }
# `state=` rather than `status=`, which is this script's own sentinel shape — the
# loader takes the prefix precisely so each caller keeps its own.
# THE FIRST LOAD CARRIES THE SENTINEL, because it is what the preflight used to
# say. An empty `loadlib.sh` leaves the stub, the stub returns 127, and without
# this arm the only trace is a bare exit status — the ordinary-looking empty
# answer `CLAUDE.md` forbids. 127 is the stub's and nothing else's: `rb_load`'s
# own refusals report their own reason and their own status.
rb_load "$_RB_SELF_DIR" recordlib is_full_sha "PR_REVIEW_WATCH state=error" || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "PR_REVIEW_WATCH state=error reason=loadlib_empty" >&2
    exit 2; }
rb_load "$_RB_SELF_DIR" recordlib rb_review_record "PR_REVIEW_WATCH state=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_replies_only_line "PR_REVIEW_WATCH state=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_review_record_is_about "PR_REVIEW_WATCH state=error" || exit 2
rb_load "$_RB_SELF_DIR" clocklib rb_elapsed "PR_REVIEW_WATCH state=error" || exit 2
# The two reviewer logins this loop drives, so the argument can be REFUSED rather than
# polled for an hour. See the reviewer check below.
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "PR_REVIEW_WATCH state=error" var || exit 2
rb_load "$_RB_SELF_DIR" recordlib RB_COPILOT_BOT "PR_REVIEW_WATCH state=error" var || exit 2

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# STARTED PRIVILEGED AT EVERY CALL SITE BELOW, not folded into this variable.
# `pr-review-state.sh` is a helper like any other, and a nested call that reaches
# it by pathname alone leaves the kernel to process its shebang — which needs
# `env -S`, the thing the driver's own invocation exists to avoid depending on.
# The prefix stays at the call sites because `probe` takes a command list and an
# override may name a stub, which `bash -p` reads just as well.
STATE_SCRIPT="${PR_WATCH_STATE_SCRIPT:-$SELF_DIR/pr-review-state.sh}"

INTERVAL="${PR_WATCH_INTERVAL:-30}"
TIMEOUT="${PR_WATCH_TIMEOUT:-3600}"
PR=""
WHO=""
AFTER_REVIEW=""
AFTER_REVIEW_FILE=""
# SUPPLIED-NESS IS TRACKED SEPARATELY FROM THE VALUE, for the value form only. An
# empty `--after-review ""` is LEGITIMATE — it is what a first request on a fresh
# head carries — so its emptiness cannot stand in for "not given", and a both-forms
# check reading the value alone let `--after-review "" --after-review-file path`
# through: the explicit "there is no prior review" was discarded and the file read
# instead, which can hold an id that makes the watch wait out its whole timeout. The
# FILE form needs no flag, because an empty path is refused where it arrives.
AFTER_REVIEW_GIVEN=""

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
                    AFTER_REVIEW="$2"; AFTER_REVIEW_GIVEN=yes; shift 2 ;;
        # THE SAME VALUE, FOR A CALLER THAT CANNOT HOLD ONE. `SKILL.md`'s bash runs
        # in the operator's own shell, where an assignment can be defeated by a
        # readonly name, a nameref or a transforming attribute — so the driver read
        # the baseline back into `PRIOR_REVIEW`, proved the name assignable first,
        # and re-validated the shape before entering the wait. That last part was a
        # SECOND, WEAKER COPY of the four-arm check below, and CLAUDE.md records
        # what a second copy of a rule costs: every field check in `recordlib.sh`
        # was written out two or three times and every one was found missing from
        # at least one copy. The value has one consumer, so it crosses in a file the
        # caller names and is validated HERE, once — the arrangement #202 gave the
        # gated head and #240 the Codex signoff sha.
        #
        # The two spellings are not two answers. `--after-review` is for a caller
        # holding the value in a hardened process of its own — `pr-close-round.sh`
        # waiting on the pass its push started — and both reach the same validation.
        #
        # AN EMPTY PATH IS REFUSED HERE, and it has to be here rather than at the read.
        # A caller expanding an unset name — `--after-review-file "$PRIOR_FILE"` with
        # `PRIOR_FILE` never assigned — satisfies the argument count and leaves this
        # empty, and an empty value then skips the read block entirely: the watch runs
        # with NO baseline and announces the already-terminal review as the new pass.
        # That is the exact failure the baseline exists to prevent, reached by passing
        # the option rather than by omitting it. `--after-review` keeps accepting an
        # empty VALUE, which legitimately means "no prior review to wait past"; an
        # empty PATH names no file and is never that answer.
        --after-review-file) [ "$#" -ge 2 ] || { echo "$0: --after-review-file needs a value" >&2; exit 2; }
                    [ -n "$2" ] || { echo "$0: --after-review-file needs a path, and was given an empty one" >&2; exit 2; }
                    AFTER_REVIEW_FILE="$2"; shift 2 ;;
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
# BOUNDED BY LENGTH, before any arithmetic. An all-digit value beyond Bash's
# integer range passes the digit test and then wraps inside `TIMEOUT - e`,
# possibly to zero or negative — `remaining_s` reports an immediate ordinary
# timeout, and the documented driver re-arms an ordinary timeout indefinitely.
# Ten digits is far past any real interval or deadline and safely inside the
# range, so an over-long value is a misconfiguration, not a duration.
case "$INTERVAL" in 0|0*|*[!0-9]*|""|??????????*) INTERVAL=30 ;; esac
case "$TIMEOUT"  in 0) ;; 0*|*[!0-9]*|""|??????????*) TIMEOUT=3600 ;; esac

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

# THE REVIEWER IS ONE THIS LOOP DRIVES, OR THIS IS NOT A WAIT WORTH STARTING. The name
# arrives from `SKILL.md`'s own shell, where it is a variable an operator's startup file
# can have aimed somewhere else — a nameref onto a path hands this stage a FILE NAME as
# the reviewer. Nothing here can prove what happened in that shell, and guarding the
# driver one name at a time is the list-of-names shape `CLAUDE.md` records paying for
# twice. What this process CAN do is refuse a login that is nobody: unrecognised, the
# watch would poll until its deadline and report a timeout, which the driver re-arms —
# so a corrupted reviewer looks exactly like a slow one, forever. `pr-close-round.sh`
# has made this same check since it was written; this is the copy that was missing.
case "$WHO" in
    "$RB_CODEX_BOT"|"$RB_COPILOT_BOT") ;;
    *) echo "PR_REVIEW_WATCH pr=$PR reviewer=$(q "$WHO") state=error reason=unknown_reviewer" >&2
       exit 2 ;;
esac


# An ABSOLUTE deadline, measured against the clock rather than accumulated from
# the sleeps. Counting only the naps excluded every second spent inside the head,
# state and verdict probes — so a run of slow GitHub reads made a one-hour watch
# run far past an hour, and a probe that hung meant the timeout check was never
# reached at all. `--timeout` has to mean elapsed time or it means nothing.
# The clock, its shape checks and its monotonicity guard live in `clocklib.sh` —
# they were written here first and `pr-ci-gate.sh` needed every one of them, and
# a rule that applies to more than one helper does not get a second copy. #66.
rb_elapsed start || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
# Returns non-zero when the clock cannot be read, so callers branch rather than
# silently treating a failed read as "no time has passed". `echo $(( … ))` hid
# exactly that behind its own success.
# The LAST accepted epoch, so a clock that steps BACKWARD is caught. A backward
# step produced a smaller elapsed value while still returning success, and
# `remaining_s` then handed the next probe a LARGER budget — `--timeout` exceeded
# by the size of the correction, or extended without bound by repeated ones. Time
# that runs backwards is not a clock this watch can measure a deadline with.
# THE RESULT IS A VARIABLE, not stdout, because the monotonic state has to
# SURVIVE the call — and that is why `rb_elapsed` sets one too. Every caller here
# used `e="$(elapsed_s)"`, so the function ran in a subshell and the previous
# reading was discarded the moment it returned: the comparison was always against
# the start, so a clock going 100 → 110 → 105 was accepted and the budget grew.
# Only a retreat past the start was caught, which is the one case the first
# fixture happened to test.
ELAPSED=0
elapsed_s() {   # sets $ELAPSED; non-zero when the clock cannot be trusted
    rb_elapsed || return 1
    ELAPSED="$RB_ELAPSED"
    return 0
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
        #
        # THE PROBE IS KILLED AND REAPED FIRST. Returning on the clock failure
        # alone left a running `gh` behind — the capability check above passed, so
        # this path is reached with a live child — and the watch then exited 2 with
        # that process still holding an API call open. Every re-arm of a persistent
        # watch added another. The same teardown as the timeout branch, because it
        # is the same situation: this probe is over and nothing may outlive it.
        sleep "$tick" || {
            kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            rm -f "$tmp" 2>/dev/null
            return 125
        }
        n=$((n + 1))
    done
    if kill -0 -"$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null; then
        kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rm -f "$tmp" 2>/dev/null
        return 124
    fi
    wait "$pid"; rc=$?
    # THE CHILD'S 124 IS NOT THE WATCHDOG'S. Expiry returns 124 from the branch
    # above, before this point; anything reaching here is the helper's own status.
    # Treating a helper that exited 124 — because it was wrapped in `timeout`, or
    # simply failed that way — as an ordinary timeout returned status 1, and
    # `SKILL.md` re-arms status 1 indefinitely. A broken probe became "the review
    # is still in flight", forever, which is the one outcome a fail-closed watch
    # must not produce. Both 124 and 125 from the child mean the probe is
    # unreadable.
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 125 ]; then
        rm -f "$tmp" 2>/dev/null
        echo "PR_REVIEW_WATCH state=error reason=probe_unreadable child_rc=$rc" >&2
        exit 2
    fi
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
    elapsed_s || {
        echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=clock_unreadable" >&2
        exit 2
    }
    printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=timeout waited_s=%s\n' "$PR" "$WHO" "$ELAPSED"
    exit 1
}

# Seconds left before the deadline, at least 1 so a probe is always attempted.
# Also a VARIABLE, for the same reason: called through command substitution it
# would carry `elapsed_s` into a subshell and lose the monotonic state again.
REMAINING=0
remaining_s() {   # sets $REMAINING; 1 = unreadable clock, 2 = deadline passed
    elapsed_s || return 1
    local r=$(( TIMEOUT - ELAPSED ))
    # An exhausted remainder is the TIMEOUT, not one more second. Clamping it let
    # a probe start after the deadline had already passed, and a verdict or
    # head-recheck begun there could still produce PR_REVIEW_READY.
    [ "$r" -lt 1 ] && return 2
    REMAINING="$r"
    return 0
}

# BOTH SPELLINGS AT ONCE IS A REFUSAL, not a precedence rule. They are the same
# value by two routes, and a caller passing both has two answers in hand and no
# reason to believe this one picked the right one.
if [ -n "$AFTER_REVIEW_FILE" ] && [ -n "$AFTER_REVIEW_GIVEN" ]; then
    echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=after_review_both_forms" >&2
    exit 2
fi
# THE READ IS BOUNDED, because opening the path can block forever. A FIFO at that
# name — supplied directly, or substituted by a same-UID process between the caller
# naming it and this open — makes `9<` wait for a writer that never arrives, and the
# `-f` test that would reject it is on the far side of the redirection and never
# runs. Measured: the watch stayed silent past its own `--timeout` and had to be
# killed from outside. A type check BEFORE the open would not fix it either, since
# the open is what blocks and the check it follows can be raced. So the open itself
# runs under the same watchdog every other probe here uses, and an expiry is
# `state=error` like any unreadable answer.
#
# AND A NUL BYTE IS NOT AN EMPTY BASELINE. `$(<file)` DROPS NUL bytes, so a file
# holding one read back as the empty string — which is the LEGITIMATE "there is no
# prior review to wait past" — and the watch would announce the terminal review this
# round just handled as the next one. Measured: bash warned about the ignored null
# byte and the run reported an ordinary timeout. The child reads with `read -d ""`
# instead, whose delimiter IS the NUL: finding one is a successful read and that is
# what makes it a refusal, while an ordinary file ends at EOF with status 1 and the
# whole content assigned. The trailing newline every writer leaves is stripped by the
# capture, as before.
if [ -n "$AFTER_REVIEW_FILE" ]; then
    # The child's statuses, and they are distinct because each names a different
    # thing to tell an operator: 4 the open failed, 5 a NUL byte, 6 not a regular
    # file. 124 is the watchdog's, from `probe` itself.
    # THE BUDGET IS THE WATCH'S OWN, not a fixed number. `--timeout 1` must not spend
    # ten seconds inside this read before reporting; `--timeout` bounds the whole
    # watch, and a step that ignores it makes the contract mean nothing. An exhausted
    # budget here is the ORDINARY timeout, because that is what it is: the deadline
    # passed before there was an answer.
    #
    # AN ALREADY-EXPIRED DEADLINE DOES NOT SKIP THE VALIDATION. `--timeout 0` made this
    # first read report the ordinary timeout before the file was opened at all — so a
    # missing, malformed or NUL-carrying baseline came back as `state=timeout`, which
    # the driver RE-ARMS, and a caller error was indistinguishable from a slow reviewer.
    # A bad argument is bad whatever the clock says; the deadline decides how long to
    # WAIT, not whether the input was well formed. So an expired budget still runs the
    # read, with the minimum bound below, and the timeout is reported afterwards.
    remaining_s; _bl_rrc=$?; _bl_rem="$REMAINING"
    _bl_expired=
    [ "$_bl_rrc" -eq 2 ] && { _bl_expired=yes; _bl_rem=0; }
    { [ "$_bl_rrc" -eq 0 ] || [ -n "$_bl_expired" ]; } \
        || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    # A SHORT LIMIT OF ITS OWN, CAPPED BY THE REMAINING BUDGET. Spending the WHOLE
    # budget here collapses two different answers into one status: an expiry would
    # mean both "this open is stuck" and "the watch ran out of time", and the caller
    # branches on those differently — `state=error` stops the round, a timeout is
    # re-armed. Ten seconds is long enough that no reachable filesystem read hits it
    # and short enough to leave the deadline meaning what it says.
    # AND THE BOUND IS AT LEAST ONE SECOND. `probe` floors its own limit at 1, so a 0
    # here would not shorten anything; making it explicit is what stops an expired
    # deadline reading as "do not bother opening it".
    _bl_lim=10
    [ "$_bl_rem" -lt "$_bl_lim" ] && _bl_lim="$_bl_rem"
    [ "$_bl_lim" -lt 1 ] && _bl_lim=1
    # THE TRAILING NEWLINE IS PRESERVED THROUGH THE READ, and it is the COMPLETION
    # DELIMITER. Every writer ends with `printf '%s\n'`, so a write that failed part-way —
    # a full filesystem, a quota reached mid-flush — leaves the value without it. Without
    # that byte the reader cannot tell a finished write from a truncated one: a `none` whose
    # newline never landed is the accepted no-floor token, and a `123` truncated from `1234`
    # is a well-formed id. Both are fail-opens of exactly the kind this change is closing.
    #
    # A COMMAND SUBSTITUTION STRIPS TRAILING NEWLINES, so the child appends a sentinel the
    # parent removes — the same shape `pr-origin.sh` uses to keep `git`'s own terminator.
    _bl_out="$(probe "$_bl_lim" /usr/bin/env bash -p -c '
        { [ -f /dev/fd/9 ] || exit 6
          IFS= read -r -d "" _r <&9
          _s=$?
        } 9<"$1" || exit 4
        [ "$_s" -eq 0 ] && exit 5
        printf %s "$_r"; printf x' _ "$AFTER_REVIEW_FILE")"; _bl_rc=$?
    [ "$_bl_rc" -eq 0 ] && _bl_out="${_bl_out%x}"
    case "$_bl_rc" in
        # AN EMPTY FILE IS A REFUSAL, AND "NO PRIOR REVIEW" IS SPELLED `none`. #264.
        #
        # Empty used to BE the no-floor value, and that made absence indistinguishable from
        # failure. Every writer truncates this file before writing it, so any failure between
        # the truncation and the write left the legal "no floor" value — and with the driver's
        # `exit` shadowed to return, a refused stage reaches this watch, the empty file passes,
        # and an existing terminal verdict is announced as this round's answer. A pass that was
        # never requested.
        #
        # The state is real and still has to be expressible — a first request, or a reviewer
        # that has never reviewed — so it is expressed by PRESENCE rather than by absence.
        # `none` is a value a writer has to produce on purpose; a truncation cannot fake it.
        #
        # THE VALUE FORM IS NOT CHANGED, deliberately. `--after-review ""` is passed by a
        # caller holding the id in a hardened process of its own — `pr-close-round.sh`
        # waiting on the pass its own push started — where empty is a choice rather than a
        # residue, and nothing truncated a file to produce it.
        0) case "$_bl_out" in
               "") echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=empty_after_review_file detail=$(q "$AFTER_REVIEW_FILE")" >&2
                   exit 2 ;;
               # THE WRITE MUST HAVE FINISHED, which is what the terminator says. Checked
               # BEFORE the value is looked at, so no shape test ever runs on a prefix.
               #
               # AT LEAST ONE, THEN ALL OF THEM STRIPPED. What the terminator proves is that
               # the LAST byte written was the newline the writer ends with, which a
               # truncated write cannot have; how many precede it is not part of the value,
               # and a reader that took only one would refuse a file a writer never produces
               # for a reason that has nothing to do with completion.
               *"
")  while :; do
                       case "$_bl_out" in
                           *"
")  _bl_out="${_bl_out%
}" ;;
                           *) break ;;
                       esac
                   done ;;
               *) echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=unterminated_after_review_file detail=$(q "$AFTER_REVIEW_FILE")" >&2
                  exit 2 ;;
           esac
           case "$_bl_out" in
               none) AFTER_REVIEW="" ;;
               *) AFTER_REVIEW="$_bl_out" ;;
           esac ;;
        5) echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=after_review_file_nul detail=$(q "$AFTER_REVIEW_FILE")" >&2
           exit 2 ;;
        6) echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=after_review_file_not_regular detail=$(q "$AFTER_REVIEW_FILE")" >&2
           exit 2 ;;
        # AN EXPIRY IS ASKED WHICH DEADLINE IT HIT. If the watch's own has passed, this
        # is the ORDINARY timeout — status 1, which the driver re-arms — because that
        # is what happened: the deadline expired while the read was in progress.
        # Reporting `state=error` there stops the round over a clock the caller set.
        # With budget left it is the read that is stuck, which is a different answer
        # and a different status.
        # AND THE THIRD CLOCK READ HAS ITS OWN ANSWER. `remaining_s` reports 2 for a
        # passed deadline and 1 for a clock it cannot read, and only the first is a
        # timeout — falling through on a 1 blamed a baseline path that may be fine and
        # sent the operator to the wrong recovery.
        124) remaining_s; _bl_r3=$?
             [ "$_bl_r3" -eq 2 ] && timed_out
             [ "$_bl_r3" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
             echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=after_review_file_blocked detail=$(q "$AFTER_REVIEW_FILE")" >&2
             exit 2 ;;
        *) echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=after_review_file_unreadable detail=$(q "$AFTER_REVIEW_FILE")" >&2
           exit 2 ;;
    esac
    # THE SHAPE IS PROVED HERE TOO, not only in the loop. The check below runs on
    # the first TERMINAL state, which may be an hour away; a malformed baseline is
    # a caller error and belongs at the call, where the caller can still act on it.
    case "$AFTER_REVIEW" in
        ""|*[0-9]) ;;
        comment:*[0-9]) ;;
        *) echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=malformed_review_id detail=$(q "$AFTER_REVIEW")" >&2
           exit 2 ;;
    esac
    case "${AFTER_REVIEW#comment:}" in
        ""|*[!0-9]*) [ -z "$AFTER_REVIEW" ] || {
              echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=malformed_review_id detail=$(q "$AFTER_REVIEW")" >&2
              exit 2; } ;;
    esac
    # THE TIMEOUT IS REPORTED HERE, after the baseline has been proved good. Reported
    # before it, a caller error was re-armed as a slow reviewer.
    [ -n "$_bl_expired" ] && timed_out
fi
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
    remaining_s; rrc=$?; rem="$REMAINING"
    [ "$rrc" -eq 2 ] && timed_out
    [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    head="$(probe "$rem" /usr/bin/env bash -p "$STATE_SCRIPT" head "$PR")"; hrc=$?
    [ "$hrc" -eq 124 ] && timed_out
    [ "$hrc" -eq 125 ] && { echo "PR_REVIEW_WATCH state=error reason=probe_unreadable" >&2; exit 2; }
    if [ "$hrc" -ne 0 ] || ! is_full_sha "$head"; then
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=head_unresolvable rc=%s detail=%s\n' \
            "$PR" "$WHO" "$hrc" "$(q "$head")"
        exit 2
    fi

    remaining_s; rrc=$?; rem="$REMAINING"
    [ "$rrc" -eq 2 ] && timed_out
    [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    line="$(probe "$rem" /usr/bin/env bash -p "$STATE_SCRIPT" state "$PR" "$WHO" "$head")"; rc=$?
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
    # THE PATTERN LIVES IN A VARIABLE, and that is a portability requirement rather
    # than a style. Bash 3.2 — the bash macOS ships — cannot PARSE a `[[ =~ ]]` whose
    # pattern contains a parenthesis written inline: it fails with "syntax error in
    # conditional expression", and the whole script dies before it runs a line. In a
    # variable the pattern is a string to the parser and a regex to the match, which
    # is what both 3.2 and every later bash do.
    #
    # It is not a Bash 4 construct by name — it is a PARSING difference, which no
    # list of constructs would contain. The `macos-shell` CI job is what found it,
    # by running the suite rather than by reading it.
    # THROUGH `recordlib.sh`, because this shape was written out here and in
    # `pr-merge-gate.sh` and was missing from `pr-phase-state.sh`. #126.
    if rb_review_record "$line" state; then
        state="$RB_REC_VALUE"
    else
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=unparseable detail=%s\n' "$PR" "$WHO" "$(q "$line")"
        exit 2
    fi
    # NOTHING MAY FOLLOW THE VALUE on this question. The library returns the tail
    # rather than accepting it, because what may follow differs per question — the
    # verdict below has a grammar of its own.
    if [ -n "$RB_REC_TAIL" ]; then
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
    if ! rb_review_record_is_about "$PR" "$WHO" "$head"; then
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
                remaining_s; rrc=$?; rem="$REMAINING"
                [ "$rrc" -eq 2 ] && timed_out
                [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
                cur="$(probe "$rem" /usr/bin/env bash -p "$STATE_SCRIPT" review-id "$PR" "$WHO" "$head")"; crc2=$?
                [ "$crc2" -eq 124 ] && timed_out
                [ "$crc2" -ne 0 ] && { echo "PR_REVIEW_WATCH state=error reason=review_id_unreadable" >&2; exit 2; }
                # The SHAPE of both ids, before they are compared or printed.
                # An rc-0 helper returning empty, multiline or junk output was
                # treated as a real id: differing from the baseline, it let the
                # watch announce the OLD terminal verdict as this round. A
                # newline in either value also smuggles an extra line into the
                # diagnostic below, and that is the channel Monitor reads.
                # An EMPTY current id is malformed here. The state probe just
                # reported a terminal state, so an authoritative review exists
                # and the helper must name it; empty differed from a non-empty
                # baseline and let the watch announce the OLD verdict as this
                # round. An empty BASELINE stays legal — it means there was no
                # prior review to wait past.
                case "$cur" in
                    "") echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=empty_review_id" >&2
                        exit 2 ;;
                esac
                for _id in "$cur" "$AFTER_REVIEW"; do
                    case "$_id" in
                        ""|*[0-9]) ;;
                        comment:*[0-9]) ;;
                        *) echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=malformed_review_id detail=$(q "$_id")" >&2
                           exit 2 ;;
                    esac
                    case "${_id#comment:}" in
                        ""|*[!0-9]*) [ -z "$_id" ] || {
                              echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=malformed_review_id detail=$(q "$_id")" >&2
                              exit 2; } ;;
                    esac
                done
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
            remaining_s; rrc=$?; rem="$REMAINING"
    [ "$rrc" -eq 2 ] && timed_out
    [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
            verdict="$(probe "$rem" /usr/bin/env bash -p "$STATE_SCRIPT" verdict "$PR" "$WHO" "$head")"; vrc=$?
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
            if rb_review_record "$verdict" verdict; then
                v_field="$RB_REC_VALUE"; v_tail="$RB_REC_TAIL"
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
            if ! rb_review_record_is_about "$PR" "$WHO" "$head"; then
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=verdict_identity_mismatch detail=%s\n' \
                    "$PR" "$WHO" "$(q "$verdict")"
                exit 2
            fi
            # The verdict VALUE, its trailing field, and the exit status must all
            # agree. Accepting any `verdict=<word>` with any tail let through
            # `verdict=clean` with no `findings=0`, and — worse — a clean record
            # returned with rc 1, which PR_REVIEW_READY then announced as a
            # finished clean review and started the next phase on.
            v_replies=0
            case "$v_field/$vrc" in
                clean/0)    [ "$v_tail" = " findings=0" ] || v_field="" ;;
                # `source=replies-only` is a THIRD shape, not a looser one: the
                # review carried comments, all of them replies, so there is
                # nothing for `pr-findings.sh` to list and it is not a signoff.
                # The tail is spelled out rather than made optional, because a
                # trailing `.*` here would accept any field anyone ever appends —
                # and this grammar exists to catch exactly that.
                findings/1) if [[ "$v_tail" =~ ^\ findings=[0-9]+$ ]]; then
                                v_replies=0
                            # THE SHAPE IS `recordlib.sh`'s, AND IT IS DECIDED HERE.
                            # A record that DECLARES `source=replies-only` and does
                            # not satisfy the shared predicate — `findings=0`, say —
                            # is not an ordinary findings verdict; classified as one
                            # it left the round closer acting on an answer nothing
                            # had validated. Either it is that record or the verdict
                            # is inconsistent. #125.
                            elif rb_replies_only_line "$verdict" "$PR" "$WHO" "$head"; then
                                v_replies=1
                            else
                                v_field=""
                            fi ;;
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
                elapsed_s || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
                waited="$ELAPSED"
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
                elapsed_s || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
                waited="$ELAPSED"
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
            remaining_s; rrc=$?; rem="$REMAINING"
    [ "$rrc" -eq 2 ] && timed_out
    [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
            head_now="$(probe "$rem" /usr/bin/env bash -p "$STATE_SCRIPT" head "$PR")"; nrc=$?
            [ "$nrc" -eq 124 ] && timed_out
            [ "$nrc" -eq 125 ] && { echo "PR_REVIEW_WATCH state=error reason=probe_unreadable" >&2; exit 2; }
            if [ "$nrc" -ne 0 ] || ! is_full_sha "$head_now"; then
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
                # READY EITHER WAY — the verdict is in hand and the watch is over.
                # The STATUS is what separates "act on this" from "somebody read
                # this", because that is what callers branch on.
                # DECIDED IN THE GRAMMAR ABOVE, and read here. Asked twice, the
                # second ask could disagree with the first: a record that declared
                # `source=replies-only` and failed the predicate passed the grammar
                # as an ordinary findings verdict and then exited 0, so a caller
                # branching on the status acted on an answer nothing had validated.
                [ "$v_replies" -eq 1 ] && exit 4
                exit 0
            fi
            ;;
    esac

    elapsed_s || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    waited="$ELAPSED"
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
    elapsed_s || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    waited="$ELAPSED"
done
