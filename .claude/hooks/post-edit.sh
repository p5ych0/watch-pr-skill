#!/usr/bin/env bash
# Privileged mode reads no BASH_ENV, imports no function and ignores SHELLOPTS, so no name this
# hook calls is one the environment can replace; a hook cannot ask its caller for the flag.
if [[ $- != *p* ]]; then
    exec "$BASH" -p "${BASH_SOURCE[0]}" "$@"
fi
set -uo pipefail

f="$(jq -ers 'if length == 1 and (.[0].tool_input.file_path | type) == "string" then .[0].tool_input.file_path else error("no path") end' 2>/dev/null)" \
    || { echo "the post-edit hook could not read one path from its input; is jq installed, and is the envelope whole and single?" >&2; exit 2; }
case "$f" in
    *.sh) ;;
    *) exit 0 ;;
esac
[ -f "$f" ] || exit 0
err="$(bash -n "$f" 2>&1)" && exit 0
# The diagnostic quotes the offending source line, which may hold a value that must not reach a log.
rest="${err%%$'\n'*}"
rest="${rest#"$f": line }"
case "$rest" in
    [0-9]*) where="line ${rest%%:*}" ;;
    *)      where="an unknown line" ;;
esac
echo "$f no longer parses, at $where" >&2
exit 2
