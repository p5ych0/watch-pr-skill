#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../../../.claude/hooks"
fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

if [ ! -d "$HOOKS" ]; then
    echo "ok   - no hooks directory in this checkout; hook checks skipped"
    echo "RESULT: PASS"
    exit 0
fi
for h in pre-push.sh post-edit.sh; do
    [ -x "$HOOKS/$h" ] || { die "$HOOKS/$h is missing or not executable, so the harness cannot run it"; }
done
[ "$fail" -eq 0 ] || { echo "RESULT: FAIL"; exit 1; }
. "$SCRIPT_DIR/testlib.sh" || exit 1
tmp="$(mktemp_d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

# Scratch projects whose self-check is a stub, so the push arm is proved without the suite;
# the hook loads the watchdog from the project it is given, so the real library is linked in.
for p in ok bad hang none; do
    mkdir -p "$tmp/$p/skills/watch-prs/scripts"
    ln -s "$SCRIPT_DIR/testlib.sh" "$tmp/$p/skills/watch-prs/scripts/testlib.sh"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/ok/skills/watch-prs/scripts/pr-selfcheck.sh"
printf '#!/usr/bin/env bash\necho "PR_SELFCHECK finding=x"\nexit 1\n' > "$tmp/bad/skills/watch-prs/scripts/pr-selfcheck.sh"
printf '#!/usr/bin/env bash\nsleep 3600\n' > "$tmp/hang/skills/watch-prs/scripts/pr-selfcheck.sh"
chmod +x "$tmp"/*/skills/watch-prs/scripts/pr-selfcheck.sh

pre() { printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err"; }
expect() {   # <project> <input> <rc> <label>
    local rc=0; pre "$1" "$2" || rc=$?
    [ "$rc" -eq "$3" ] && pass "$4" || die "$4: rc=$rc, expected $3 ($(head -c 120 "$tmp/err"))"
}
cmd() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

expect "$tmp/ok" "$(cmd 'ls -la')" 0 "a harmless command passes without a check"
expect "$tmp/bad" "$(cmd 'git commit -m "x"')" 0 "a commit is not a push"
expect "$tmp/bad" "$(cmd 'git -c push=1 status')" 0 "…nor is push as an option value"
expect "$tmp/ok" "$(cmd 'git push -q -u origin b')" 0 "a push passes when the self-check is clean"
expect "$tmp/bad" "$(cmd 'git push origin b')" 2 "a push is blocked when the self-check finds something"
for f in 'git -C /somewhere push origin b' 'git -c k=v push origin b' 'git -C d -c k=v push' 'git --git-dir=/g push origin b' 'git --git-dir /g push origin b' 'git --no-pager push origin b' '/usr/bin/git push origin b' 'cd x && git push' 'x; git push' 'git push; x' "bash -c 'git push origin b'" '(git push origin b)' 'out=$(git push origin b)'; do
    expect "$tmp/bad" "$(cmd "$f")" 2 "a push is a push: $f"
done
expect "$tmp/bad" "$(cmd '/usr/bin/env bash -p scripts/pr-close-round.sh gate 7 bot s no h p')" 2 "the round gate is a push"
expect "$tmp/bad" "$(cmd '/usr/bin/env bash -p scripts/pr-close-round.sh   gate 7 bot s no h p')" 2 "…however the gate is spaced"
expect "$tmp/bad" "$(cmd '/usr/bin/env bash -p scripts/pr-close-round.sh post 7 bot s no h p n')" 0 "…and post is not the gate"
expect "$tmp/none" "$(cmd 'git push origin b')" 2 "a missing self-check blocks the push"
expect "$tmp/hang" "$(cmd 'git push origin b')" 2 "a self-check that hangs is bounded inside the hook and blocks"
grep -q 'did not finish' "$tmp/err" && pass "…and says so" || die "the hang was not named: $(head -c 120 "$tmp/err")"
for f in 'git push --force origin b' 'git push -f origin b' 'git push -fu origin b' 'git push -uf origin b' 'git -C d push --force-with-lease' 'git push origin +HEAD:refs/heads/b' 'git push "-f" origin b' "git push origin '+HEAD:refs/heads/b'" 'git push "--force" origin b' 'git push -f; x' 'git push origin b -f&&x' "bash -c 'git push -f origin b'"; do
    expect "$tmp/ok" "$(cmd "$f")" 2 "refused: $f"
done
expect "$tmp/ok" "$(cmd 'git push origin b --follow-tags; echo done')" 0 "a flag that merely starts with -f is not a force"
expect "$tmp/ok" "$(cmd 'git push origin b && rm -rf "$tmp"')" 0 "a flag in the next command is not this push's"
expect "$tmp/ok" "$(cmd 'git push origin b; ls -lf; echo +1')" 0 "…nor after ; or in a later word"
# The accepted limit: a segment that quotes the spelling is refused too, since the match is on text.
expect "$tmp/ok" "$(cmd 'git commit -m "the loop never runs git push --force"')" 2 "a quoted spelling in the same segment is refused, the stated limit"
expect "$tmp/ok" '' 2 "empty input blocks"
expect "$tmp/ok" 'not json' 2 "unreadable input blocks"
expect "$tmp/ok" '{"tool_input":{}}' 2 "an envelope with no command blocks"
expect "$tmp/ok" '{"tool_input":{"command":null}}' 2 "a null command blocks"
bash_bin="$(command -v bash)"
rc=0; printf '%s' "$(cmd 'git push --force origin b')" | PATH="$tmp/nopath" CLAUDE_PROJECT_DIR="$tmp/ok" "$bash_bin" "$HOOKS/pre-push.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "a missing jq blocks rather than passing a forced push" || die "with jq absent rc=$rc"

post() { printf '%s' "$1" | "$HOOKS/post-edit.sh" >/dev/null 2>"$tmp/err"; }
fp() { printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
printf 'echo "(\n' > "$tmp/broken.sh"; printf 'echo ok\n' > "$tmp/good.sh"; printf 'echo "(\n' > "$tmp/notes.md"
rc=0; post "$(fp "$tmp/broken.sh")" || rc=$?; [ "$rc" -eq 2 ] && pass "a shell file that does not parse is reported" || die "broken.sh rc=$rc"
rc=0; post "$(fp "$tmp/good.sh")" || rc=$?;   [ "$rc" -eq 0 ] && pass "a shell file that parses passes" || die "good.sh rc=$rc"
rc=0; post "$(fp "$tmp/notes.md")" || rc=$?;  [ "$rc" -eq 0 ] && pass "a non-shell file is not parsed" || die "notes.md rc=$rc"
rc=0; post 'not json' || rc=$?;               [ "$rc" -eq 2 ] && pass "unreadable input is reported" || die "malformed post-edit input rc=$rc"
rc=0; post '{"tool_input":{}}' || rc=$?;      [ "$rc" -eq 2 ] && pass "an envelope with no path is reported" || die "pathless post-edit input rc=$rc"

[ "$fail" -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
