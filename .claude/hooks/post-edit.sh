#!/usr/bin/env bash
set -uo pipefail

f="$(jq -er 'if (.tool_input.file_path | type) == "string" then .tool_input.file_path else error("no path") end' 2>/dev/null)" \
    || { echo "the post-edit hook could not read a path from its input; is jq installed, and is the envelope whole?" >&2; exit 2; }
case "$f" in
    *.sh) ;;
    *) exit 0 ;;
esac
[ -f "$f" ] || exit 0
err="$(bash -n "$f" 2>&1)" && exit 0
printf '%s\n' "$err" >&2
echo "$f no longer parses" >&2
exit 2
