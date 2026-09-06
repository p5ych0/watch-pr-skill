#!/usr/bin/env bash
# Exit 2 blocks the command and hands stderr back to Claude; an unreadable input blocks too.
set -uo pipefail

cmd="$(jq -r '.tool_input.command // empty' 2>/dev/null)" \
    || { echo "blocked: the pre-push hook could not read its input; is jq installed?" >&2; exit 2; }
[ -n "$cmd" ] || exit 0

push='(^|[;&|[:space:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+|[[:space:]]+--?[[:alnum:]-]+)*[[:space:]]+push([[:space:]]|$)'
case "$cmd" in
    *"pr-close-round.sh gate"*) ;;
    *) [[ $cmd =~ $push ]] || exit 0 ;;
esac
# A text match: a command line that only quotes one of these spellings is refused too.
force='push.*(--force|[[:space:]]-[[:alpha:]]*f[[:alpha:]]*([[:space:]]|$)|[[:space:]]\+[^[:space:]]+)'
if [[ $cmd =~ $force ]]; then
    echo "blocked: a push spelled with --force, -f or a + refspec rewrites a remote branch, and this loop never does" >&2
    exit 2
fi

root="${CLAUDE_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
check="$root/skills/watch-prs/scripts/pr-selfcheck.sh"
[ -x "$check" ] || { echo "blocked: $check is missing or not executable; nothing is pushed unchecked" >&2; exit 2; }
# Bounded inside, since a hook that overruns its own timeout does not block.
if command -v timeout >/dev/null 2>&1; then
    out="$(timeout -k 5 290 "$check" "$root" 2>&1)"; rc=$?
else
    out="$("$check" "$root" 2>&1)"; rc=$?
fi
[ "$rc" -eq 0 ] && exit 0
printf '%s\n' "$out" | grep -v '^ok' | tail -15 >&2
echo "blocked: pr-selfcheck.sh is not clean (rc=$rc); fix it before anything is pushed" >&2
exit 2
