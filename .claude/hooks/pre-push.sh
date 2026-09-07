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
# Length first: `[` prints the whole operand back when it is too large to compare.
case "$bound" in *[!0-9]*) bound=x ;; esac
[ "${#bound}" -le 3 ] || bound=x
[ "$bound" != x ] && [ "$bound" -ge 1 ] && [ "$bound" -le 580 ] \
    || { echo "blocked: PRE_PUSH_BOUND is not a whole number of seconds from 1 to 580; nothing is pushed unbounded" >&2; exit 2; }
root="${CLAUDE_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
# The check reads the tree, the push sends the commit; where there is a work tree to compare,
# they must be the same thing.
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    dirty="$(git -C "$root" status --porcelain --untracked-files=no 2>/dev/null)" || dirty=x
    [ -z "$dirty" ] \
        || { echo "blocked: tracked files differ from the commit being pushed, so the check would not read what the push sends; commit or stash first" >&2; exit 2; }
fi
check="$root/skills/watch-prs/scripts/pr-selfcheck.sh"
[ -x "$check" ] || { echo "blocked: pr-selfcheck.sh is missing or not executable; nothing is pushed unchecked" >&2; exit 2; }
# A finding quotes the line it was found on, and that line is the change being pushed.
work="$(mktemp -d 2>/dev/null)" || { echo "blocked: the pre-push hook could not make a directory for the self-check's result" >&2; exit 2; }
trap 'rm -rf "$work" 2>/dev/null' EXIT
# The change being checked owns everything under $root, this bound included; the group is the
# unit, since a descendant that outlives the check holds the pipe open.
set -m
( { /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS "$check" "$root" 2>&1; { echo $? >"$work/rc"; } 2>/dev/null; } \
    | { { grep -c '^PR_SELFCHECK finding=' >"$work/n"; echo $? >"$work/g"; } 2>/dev/null; } ) &
gpid=$!
set +m
( i=0; while [ "$i" -lt "$bound" ]; do sleep 1; kill -0 "$gpid" 2>/dev/null || exit 0; i=$((i + 1)); done; { : >"$work/killed"; } 2>/dev/null; kill -9 -"$gpid" 2>/dev/null || kill -9 "$gpid" 2>/dev/null ) &
wpid=$!
# The shell announces a killed job on its own stderr, naming the command it ran.
{ wait "$gpid"; kill "$wpid" 2>/dev/null; wait "$wpid"; } 2>/dev/null
rc="$(cat "$work/rc" 2>/dev/null)" || rc=x
case "$rc" in ''|*[!0-9]*) rc=124 ;; esac
# The check's own status says nothing if the deadline cut the run short around it, or if the
# count that ran beside it failed: grep says 0 for a match and 1 for none, and nothing else.
{ [ -e "$work/killed" ] || [ ! -s "$work/n" ]; } && rc=124
g="$(cat "$work/g" 2>/dev/null)" || g=x
case "$g" in 0|1) ;; *) rc=124 ;; esac
[ "$rc" -eq 0 ] && exit 0
if [ "$rc" -eq 124 ]; then
    echo "blocked: pr-selfcheck.sh did not finish within the bound; nothing is pushed unchecked" >&2
else
    n="$(cat "$work/n" 2>/dev/null)" || n=x
    case "$n" in ''|*[!0-9]*) n=an\ unknown\ number\ of ;; esac
    echo "blocked: pr-selfcheck.sh is not clean (rc=$rc), with $n findings; run it to read them" >&2
fi
exit 2
