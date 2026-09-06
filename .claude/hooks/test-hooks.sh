#!/usr/bin/env bash
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }
tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

# A scratch project whose self-check is a stub, so the push arm is proved without the suite.
mkdir -p "$tmp/ok/skills/watch-prs/scripts" "$tmp/bad/skills/watch-prs/scripts" "$tmp/none/skills/watch-prs/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/ok/skills/watch-prs/scripts/pr-selfcheck.sh"
printf '#!/usr/bin/env bash\necho "PR_SELFCHECK finding=x"\nexit 1\n' > "$tmp/bad/skills/watch-prs/scripts/pr-selfcheck.sh"
chmod +x "$tmp/ok/skills/watch-prs/scripts/pr-selfcheck.sh" "$tmp/bad/skills/watch-prs/scripts/pr-selfcheck.sh"

pre() { printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" "$here/pre-push.sh" >/dev/null 2>"$tmp/err"; }
expect() {   # <project> <input> <rc> <label>
    local rc=0; pre "$1" "$2" || rc=$?
    [ "$rc" -eq "$3" ] && pass "$4" || die "$4: rc=$rc, expected $3 ($(head -c 120 "$tmp/err"))"
}
cmd() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

expect "$tmp/ok" "$(cmd 'ls -la')" 0 "a harmless command passes without a check"
expect "$tmp/bad" "$(cmd 'git commit -m "x"')" 0 "a commit is not a push"
expect "$tmp/ok" "$(cmd 'git push -q -u origin b')" 0 "a push passes when the self-check is clean"
expect "$tmp/bad" "$(cmd 'git push origin b')" 2 "a push is blocked when the self-check finds something"
expect "$tmp/bad" "$(cmd 'git -C /somewhere push origin b')" 2 "git -C <dir> push is a push"
expect "$tmp/bad" "$(cmd 'cd x && git push')" 2 "a push after && is a push"
expect "$tmp/bad" "$(cmd '/usr/bin/env bash -p scripts/pr-close-round.sh gate 7 bot s no h p')" 2 "the round gate is a push"
expect "$tmp/none" "$(cmd 'git push origin b')" 2 "a missing self-check blocks the push"
for f in 'git push --force origin b' 'git push -f origin b' 'git push -fu origin b' 'git -C d push --force-with-lease' 'git push origin +HEAD:refs/heads/b'; do
    expect "$tmp/ok" "$(cmd "$f")" 2 "refused: $f"
done
expect "$tmp/ok" "$(cmd 'git push origin b --follow-tags')" 0 "a flag that merely starts with -f is not a force"
expect "$tmp/ok" '' 0 "empty input passes"
expect "$tmp/ok" 'not json' 2 "unreadable input blocks"
bash_bin="$(command -v bash)"
rc=0; printf '%s' "$(cmd 'git push --force origin b')" | PATH="$tmp/nopath" CLAUDE_PROJECT_DIR="$tmp/ok" "$bash_bin" "$here/pre-push.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "a missing jq blocks rather than passing a forced push" || die "with jq absent rc=$rc"

post() { printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "$1" | jq -Rs .)" | "$here/post-edit.sh" >/dev/null 2>"$tmp/err"; }
printf 'echo "(\n' > "$tmp/broken.sh"; printf 'echo ok\n' > "$tmp/good.sh"; printf 'echo "(\n' > "$tmp/notes.md"
rc=0; post "$tmp/broken.sh" || rc=$?; [ "$rc" -eq 2 ] && pass "a shell file that does not parse is reported" || die "broken.sh rc=$rc"
rc=0; post "$tmp/good.sh" || rc=$?;   [ "$rc" -eq 0 ] && pass "a shell file that parses passes" || die "good.sh rc=$rc"
rc=0; post "$tmp/notes.md" || rc=$?;  [ "$rc" -eq 0 ] && pass "a non-shell file is not parsed" || die "notes.md rc=$rc"
rc=0; printf 'not json' | "$here/post-edit.sh" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] && pass "unreadable input is reported" || die "malformed post-edit input rc=$rc"

[ "$fail" -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
