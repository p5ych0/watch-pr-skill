#!/usr/bin/env bash
# Exit 2 blocks the command and hands stderr back to Claude.
set -uo pipefail

cmd="$(jq -er 'if (.tool_input.command | type) == "string" then .tool_input.command else error("no command") end' 2>/dev/null)" \
    || { echo "blocked: the pre-push hook could not read a command from its input; is jq installed, and is the envelope whole?" >&2; exit 2; }

# So a spelling that only quotes or escapes a word is the word, and a mention inside an argument
# costs a self-check run.
norm="${cmd//[\\\"\']/}"
push='(^|[;&|(`[:space:]])([^[:space:]]*/)?git[[:space:]]+(.*[[:space:]]+)?push([;&|()<>`[:space:]]|$)'
gate='pr-close-round\.sh[[:space:]]+gate([;&|()<>`[:space:]]|$)'
[[ $norm =~ $push ]] || [[ $norm =~ $gate ]] || exit 0

# Inside the 600 s deadline settings.json gives the hook, since a hook that overruns it does not block.
bound="${PRE_PUSH_BOUND:-580}"
case "$bound" in *[!0-9]*) bound=x ;; esac
[ "$bound" != x ] && [ "$bound" -ge 1 ] && [ "$bound" -le 580 ] \
    || { echo "blocked: PRE_PUSH_BOUND='${PRE_PUSH_BOUND:-}' is not a whole number of seconds from 1 to 580; nothing is pushed unbounded" >&2; exit 2; }
root="${CLAUDE_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
check="$root/skills/watch-prs/scripts/pr-selfcheck.sh"
[ -x "$check" ] || { echo "blocked: $check is missing or not executable; nothing is pushed unchecked" >&2; exit 2; }
. "$root/skills/watch-prs/scripts/testlib.sh" 2>/dev/null && [ "$(type -t run_limited)" = function ] \
    || { echo "blocked: the watchdog in testlib.sh could not be loaded; nothing is pushed unbounded" >&2; exit 2; }
out="$(run_limited "$bound" "$check" "$root" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && exit 0
printf '%s\n' "$out" | grep -v '^ok' | tail -15 >&2
if [ "$rc" -eq 124 ]; then
    echo "blocked: pr-selfcheck.sh did not finish within ${bound}s; nothing is pushed unchecked" >&2
else
    echo "blocked: pr-selfcheck.sh is not clean (rc=$rc); fix it before anything is pushed" >&2
fi
exit 2
