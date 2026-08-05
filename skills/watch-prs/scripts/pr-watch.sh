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
        --interval) INTERVAL="${2:-}"; shift 2 || true ;;
        --timeout)  TIMEOUT="${2:-}";  shift 2 || true ;;
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
case "$INTERVAL" in 0|*[!0-9]*|"") INTERVAL=30 ;; esac
case "$TIMEOUT"  in *[!0-9]*|"")   TIMEOUT=3600 ;; esac

waited=0
last=""
while :; do
    line="$("$STATE_SCRIPT" state "$PR" "$WHO" 2>&1)"; rc=$?
    if [ "$rc" -eq 2 ]; then
        # An unreadable state is not "still waiting": the caller must decide,
        # because the difference between "no review yet" and "cannot tell" is the
        # difference between waiting and merging on a bad read.
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error detail=%s\n' "$PR" "$WHO" "$line"
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
            printf 'PR_REVIEW_READY pr=%s reviewer=%s state=%s %s\n' \
                "$PR" "$WHO" "$state" "${verdict##*reviewer=* }"
            printf '%s\n' "$verdict"
            [ "$vrc" -eq 2 ] && exit 2
            exit 0 ;;
    esac

    if [ "$waited" -ge "$TIMEOUT" ]; then
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=timeout waited_s=%s\n' "$PR" "$WHO" "$waited"
        exit 1
    fi
    sleep "$INTERVAL"
    waited=$((waited + INTERVAL))
done
