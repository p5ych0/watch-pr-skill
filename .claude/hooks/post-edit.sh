#!/usr/bin/env -S bash -p
# A last resort: `$-` reports the mode, not how the shell got there, and a BASH_ENV that exits
# would kill an unprivileged shell before this line.
if [[ $- != *p* ]]; then
    echo "blocked: this hook must be started privileged, as .claude/settings.json starts it" >&2
    exit 2
fi
set -uo pipefail
unset BASH_ENV ENV

# The sentinel keeps a pathname that ends in a newline, which the substitution would eat.
f="$(jq -jers 'if length == 1 and (.[0].tool_input.file_path | type) == "string" then .[0].tool_input.file_path + "X" else error("no path") end' 2>/dev/null)" \
    || { echo "the post-edit hook could not read one path from its input; is jq installed, and is the envelope whole and single?" >&2; exit 2; }
f="${f%X}"
case "$f" in
    *.sh) ;;
    *) exit 0 ;;
esac
[ -f "$f" ] || exit 0
err="$(LC_ALL=C bash -p -n "$f" 2>&1)" && exit 0
# The diagnostic quotes the offending source line, which may hold a value that must not reach a log.
rest="${err#"$f": line }"
rest="${rest%%$'\n'*}"
case "$rest" in
    [0-9]*) where="line ${rest%%:*}" ;;
    *)      where="an unknown line" ;;
esac
printf '%s no longer parses, at %s\n' "$(printf '%q' "$f")" "$where" >&2
exit 2
