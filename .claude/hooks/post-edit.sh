#!/usr/bin/env -S bash -p
# A last resort: `$-` reports the mode, not how the shell got there, and a BASH_ENV that exits
# would kill an unprivileged shell before this line.
if [[ $- != *p* ]]; then
    echo "blocked: this hook must be started privileged, as .claude/settings.json starts it" >&2
    exit 2
fi
set -uo pipefail
unset BASH_ENV ENV

f="$(jq -ers 'if length == 1 and (.[0].tool_input.file_path | type) == "string" then .[0].tool_input.file_path else error("no path") end' 2>/dev/null)" \
    || { echo "the post-edit hook could not read one path from its input; is jq installed, and is the envelope whole and single?" >&2; exit 2; }
case "$f" in
    *.sh) ;;
    *) exit 0 ;;
esac
[ -f "$f" ] || exit 0
err="$(bash -p -n "$f" 2>&1)" && exit 0
# The diagnostic quotes the offending source line, which may hold a value that must not reach a log.
rest="${err%%$'\n'*}"
rest="${rest#"$f": line }"
case "$rest" in
    [0-9]*) where="line ${rest%%:*}" ;;
    *)      where="an unknown line" ;;
esac
echo "$f no longer parses, at $where" >&2
exit 2
