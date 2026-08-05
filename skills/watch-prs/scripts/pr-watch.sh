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

case "$PR" in
    ""|*[!0-9]*) echo "usage: $0 <pr> <reviewer-login> [--interval S] [--timeout S]" >&2; exit 2 ;;
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
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error rc=%s detail=%s\n' "$PR" "$WHO" "$rc" "$line"
        exit 2
    fi

    state="${line##*state=}"
    state="${state%% *}"
    if [ "$state" != "$last" ]; then
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=%s waited_s=%s\n' "$PR" "$WHO" "$state" "$waited"
        last="$state"
    fi

    case "$state" in
        reviewed|blocked|dismissed)
            # Terminal. Report the verdict too, so the caller has the whole
            # answer without a second round-trip.
            verdict="$("$STATE_SCRIPT" verdict "$PR" "$WHO" 2>&1)"; vrc=$?
            if [ "$vrc" -eq 2 ]; then
                # PR_REVIEW_READY is THE signal that there is something to act on
                # — under Monitor it is what reaches the session. Emitting it and
                # then exiting 2 tells the session to act and the shell that it
                # could not be read, and the line is what gets noticed.
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error detail=%s\n' "$PR" "$WHO" "$verdict"
                exit 2
            fi
            printf 'PR_REVIEW_READY pr=%s reviewer=%s state=%s %s\n' \
                "$PR" "$WHO" "$state" "${verdict##*reviewer=* }"
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
