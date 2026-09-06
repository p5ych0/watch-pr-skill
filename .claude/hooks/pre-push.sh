#!/usr/bin/env -S bash -p
# A last resort: `$-` reports the mode, not how the shell got there, and a BASH_ENV that exits
# would kill an unprivileged shell before this line.
if [[ $- != *p* ]]; then
    echo "blocked: this hook must be started privileged, as .claude/settings.json starts it" >&2
    exit 2
fi
set -uo pipefail
unset BASH_ENV ENV

cmd="$(jq -ers 'if length == 1 and (.[0].tool_input.command | type) == "string" then .[0].tool_input.command else error("no command") end' 2>/dev/null)" \
    || { echo "blocked: the pre-push hook could not read one command from its input; is jq installed, and is the envelope whole and single?" >&2; exit 2; }

# So a spelling that only quotes or escapes a word is the word, and a mention inside an argument
# costs a self-check run.
norm="${cmd//[\\\"\']/}"
push='(^|[^[:alnum:]_./-])([^[:space:]]*/)?git[^[:alnum:]_./-](.*[^[:alnum:]_=./-])?push([^[:alnum:]_=./-]|$)'
gate='pr-close-round\.sh[^[:alnum:]_./-](.*[^[:alnum:]_=./-])?gate([^[:alnum:]_=./-]|$)'
[[ $norm =~ $push ]]; p=$?
[[ $norm =~ $gate ]]; g=$?
[ "$p" -eq 1 ] && [ "$g" -eq 1 ] && exit 0
[ "$p" -eq 0 ] || [ "$g" -eq 0 ] \
    || { echo "blocked: a pattern in the pre-push hook did not compile; nothing is pushed unchecked" >&2; exit 2; }

# Inside the 600 s deadline settings.json gives the hook, since a hook that overruns it does not block.
bound="${PRE_PUSH_BOUND:-580}"
case "$bound" in *[!0-9]*) bound=x ;; esac
[ "$bound" != x ] && [ "$bound" -ge 1 ] && [ "$bound" -le 580 ] \
    || { echo "blocked: PRE_PUSH_BOUND='${PRE_PUSH_BOUND:-}' is not a whole number of seconds from 1 to 580; nothing is pushed unbounded" >&2; exit 2; }
root="${CLAUDE_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
log="$(mktemp)" || { echo "blocked: the pre-push hook could not make a file for the self-check's output" >&2; exit 2; }
trap 'rm -f "$log"' EXIT
check="$root/skills/watch-prs/scripts/pr-selfcheck.sh"
[ -x "$check" ] || { echo "blocked: $check is missing or not executable; nothing is pushed unchecked" >&2; exit 2; }
# The bound is the hook's own, since the change being checked owns everything under $root.
if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$bound" /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS "$check" "$root" >"$log" 2>&1; rc=$?
else
    # Job control makes the child a group leader, so the deadline reaches what it started too.
    set -m
    /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS "$check" "$root" >"$log" 2>&1 &
    cpid=$!
    set +m
    ( i=0; while [ "$i" -lt "$bound" ]; do sleep 1; kill -0 "$cpid" 2>/dev/null || exit 0; i=$((i + 1)); done; kill -9 -"$cpid" 2>/dev/null || kill -9 "$cpid" 2>/dev/null ) &
    wpid=$!
    # The shell announces a killed job on its own stderr, naming the command it ran.
    { wait "$cpid"; rc=$?; kill "$wpid" 2>/dev/null; wait "$wpid"; } 2>/dev/null
    [ "$rc" -ge 128 ] && rc=124
fi
[ "$rc" -eq 0 ] && exit 0
if [ "$rc" -eq 124 ]; then
    echo "blocked: pr-selfcheck.sh did not finish within ${bound}s; nothing is pushed unchecked" >&2
else
    # A count, since a finding quotes the line it was found on and that line is being pushed.
    n=$(head -c 1000000 "$log" | grep -c '^PR_SELFCHECK finding=')
    case "$n" in *[!0-9]*) n=an\ unknown\ number\ of ;; esac
    echo "blocked: pr-selfcheck.sh is not clean (rc=$rc), with $n findings; run it to read them" >&2
fi
exit 2
