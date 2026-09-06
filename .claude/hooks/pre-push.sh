#!/usr/bin/env bash
# Exit 2 blocks the command and hands stderr back to Claude.
set -uo pipefail

cmd="$(jq -er 'if (.tool_input.command | type) == "string" then .tool_input.command else error("no command") end' 2>/dev/null)" \
    || { echo "blocked: the pre-push hook could not read a command from its input; is jq installed, and is the envelope whole?" >&2; exit 2; }

push="(^|[;&|(\`'\"[:space:]])(/[^[:space:]]*/)?git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+|[[:space:]]+--[[:alnum:]-]+[[:space:]]+[^-[:space:]][^[:space:]]*|[[:space:]]+--?[[:alnum:]-]+(=[^[:space:]]*)?)*[[:space:]]+push([;&|)\`'\"[:space:]]|$)"
gate="pr-close-round\\.sh[[:space:]]+gate([;&|)\`'\"[:space:]]|$)"
[[ $cmd =~ $push ]] || [[ $cmd =~ $gate ]] || exit 0

# A text match, stopped at a separator: a segment that only quotes one of these spellings is refused too.
force="push[^;&|"$'\n'"]*[[:space:]][\"']?(--force|-[[:alpha:]]*f[[:alpha:]]*([^[:alpha:]]|$)|\\+[^[:space:]]+)"
if [[ $cmd =~ $force ]]; then
    echo "blocked: a push spelled with --force, -f or a + refspec rewrites a remote branch, and this loop never does" >&2
    exit 2
fi

root="${CLAUDE_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
check="$root/skills/watch-prs/scripts/pr-selfcheck.sh"
[ -x "$check" ] || { echo "blocked: $check is missing or not executable; nothing is pushed unchecked" >&2; exit 2; }
# Bounded inside, since a hook that overruns its own timeout does not block; the repository's watchdog is portable.
. "$root/skills/watch-prs/scripts/testlib.sh" 2>/dev/null && [ "$(type -t run_limited)" = function ] \
    || { echo "blocked: the watchdog in testlib.sh could not be loaded; nothing is pushed unbounded" >&2; exit 2; }
out="$(run_limited "${PRE_PUSH_BOUND:-580}" "$check" "$root" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && exit 0
printf '%s\n' "$out" | grep -v '^ok' | tail -15 >&2
if [ "$rc" -eq 124 ]; then
    echo "blocked: pr-selfcheck.sh did not finish within ${PRE_PUSH_BOUND:-580}s; nothing is pushed unchecked" >&2
else
    echo "blocked: pr-selfcheck.sh is not clean (rc=$rc); fix it before anything is pushed" >&2
fi
exit 2
