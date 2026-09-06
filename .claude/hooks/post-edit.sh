#!/usr/bin/env bash
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
where=': line ([0-9]+): '
[[ $err =~ $where ]] && where="line ${BASH_REMATCH[1]}" || where="an unknown line"
echo "$f no longer parses, at $where" >&2
exit 2
