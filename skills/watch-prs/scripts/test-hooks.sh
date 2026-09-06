#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../../.."
HOOKS="$ROOT/.claude/hooks"
SETTINGS="$ROOT/.claude/settings.json"
fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# The settings file is the promise; a copy without one has no hooks to prove.
if [ ! -f "$SETTINGS" ]; then
    echo "ok   - no .claude/settings.json in this copy; hook checks skipped"
    echo "RESULT: PASS"
    exit 0
fi
. "$SCRIPT_DIR/testlib.sh" || exit 1
tmp="$(mktemp_d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

wired() {
    jq -e '.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]? | select(.type == "command" and .command == "/usr/bin/env bash -p \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/pre-push.sh" and .timeout == 600)' "$1" >/dev/null \
    && jq -e '.hooks.PostToolUse[]? | select(.matcher == "Write|Edit") | .hooks[]? | select(.type == "command" and .command == "/usr/bin/env bash -p \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/post-edit.sh")' "$1" >/dev/null
}
wired "$SETTINGS" && pass "settings.json runs both hooks by their full path, each under its event and matcher, the push one with a 600 s timeout" \
    || die "settings.json does not run both hooks as the harness must"
jq '(.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]).command = "/usr/bin/env bash -p echo hooks/pre-push.sh"' "$SETTINGS" > "$tmp/decoy-pre.json" || die "the pre decoy was not written"
jq '(.hooks.PostToolUse[] | select(.matcher == "Write|Edit") | .hooks[]).command = "/usr/bin/env bash -p echo hooks/post-edit.sh"' "$SETTINGS" > "$tmp/decoy-post.json" || die "the post decoy was not written"
jq '(.hooks.PostToolUse[] | select(.matcher == "Write|Edit")).matcher = "WriteEdit"' "$SETTINGS" > "$tmp/decoy-matcher.json" || die "the matcher decoy was not written"
jq '(.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]).timeout = 30' "$SETTINGS" > "$tmp/decoy-timeout.json" || die "the timeout decoy was not written"
jq '(.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]).command = "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/pre-push.sh"' "$SETTINGS" > "$tmp/decoy-unprivileged.json" || die "the unprivileged decoy was not written"
for d in pre post matcher timeout unprivileged; do
    wired "$tmp/decoy-$d.json" && die "the $d decoy passed the wiring check" || pass "the $d decoy fails the wiring check"
done
for h in pre-push.sh post-edit.sh; do
    [ -x "$HOOKS/$h" ] || die "$HOOKS/$h is missing or not executable, so the harness cannot run it"
done
[ "$fail" -eq 0 ] || { echo "RESULT: FAIL"; exit 1; }

# So the push arm is proved without the suite; the hook loads the watchdog from the project it
# is given, so the real library is linked in.
for p in ok bad hang none; do
    mkdir -p "$tmp/$p/skills/watch-prs/scripts"
    ln -s "$SCRIPT_DIR/testlib.sh" "$tmp/$p/skills/watch-prs/scripts/testlib.sh"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/ok/skills/watch-prs/scripts/pr-selfcheck.sh"
printf '#!/usr/bin/env bash\necho "PR_SELFCHECK finding=x"\nexit 1\n' > "$tmp/bad/skills/watch-prs/scripts/pr-selfcheck.sh"
printf '#!/usr/bin/env bash\nsleep 3600\n' > "$tmp/hang/skills/watch-prs/scripts/pr-selfcheck.sh"
printf '#!/usr/bin/env bash\necho "PR_SELFCHECK finding=quoted_line SKILL.md:12"\necho "  gh pr comment --body PLACEHOLDER_VALUE_NOT_FOR_LOGS"\necho "PR_SELFCHECK status=findings count=1"\nexit 1\n' > "$tmp/ok/skills/watch-prs/scripts/pr-selfcheck.sh.quoting"
chmod +x "$tmp"/*/skills/watch-prs/scripts/pr-selfcheck.sh

pre() { printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err"; }
expect() {
    local rc=0; pre "$1" "$2" || rc=$?
    [ "$rc" -eq "$3" ] && pass "$4" || die "$4: rc=$rc, expected $3 ($(head -c 120 "$tmp/err"))"
}
cmd() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

expect "$tmp/bad" "$(cmd 'ls -la')" 0 "a harmless command passes without a check"
expect "$tmp/bad" "$(cmd 'git commit -m "x"')" 0 "a commit is not a push"
expect "$tmp/bad" "$(cmd 'git -c push=1 status')" 0 "…nor is push as an option value"
expect "$tmp/bad" "$(cmd 'git config push.default simple')" 0 "…nor as a configuration key"
expect "$tmp/bad" "$(cmd 'git log --grep=push')" 0 "…nor as a value after ="
expect "$tmp/ok" "$(cmd 'git push -q -u origin b')" 0 "a push passes when the self-check is clean"
expect "$tmp/ok" "$(cmd 'git commit -m "the loop never runs git push"')" 0 "a mention inside an argument passes when the self-check is clean"
expect "$tmp/bad" "$(cmd 'git commit -m "the loop never runs git push"')" 2 "…and that run is real: its finding blocks"
expect "$tmp/bad" "$(cmd 'git push origin b')" 2 "a push is blocked when the self-check finds something"
grep -q 'is not clean' "$tmp/err" && pass "…for that reason" || die "the finding was not named: $(head -c 120 "$tmp/err")"
for f in 'git -C /somewhere push origin b' 'git -C "/a repo with spaces" push origin b' 'git -c k=v push origin b' "git -c 'foo.bar=x;y' push origin b" 'git -c "a|b" push origin b' 'git -C d -c k=v push' 'git --git-dir=/g push origin b' 'git --git-dir /g push origin b' 'git --no-pager push origin b' '/usr/bin/git push origin b' '"/usr/bin/git" push origin b' '"/opt/my tools/git" push origin b' '\git push origin b' "git 'push' origin b" 'git "push" origin b' 'git \push origin b' 'git pu"sh" origin b' 'g\it push origin b' $'git commit -m x\ngit push origin b' 'git</dev/null push origin b' 'git&>/dev/null push origin b' 'git${IFS}push origin b' 'cd x && git push' 'x; git push' 'git push; x' 'git push>log 2>&1' "bash -c 'git push origin b'" '(git push origin b)' 'out=$(git push origin b)'; do
    expect "$tmp/bad" "$(cmd "$f")" 2 "a push is a push: ${f//$'\n'/\\n}"
done
expect "$tmp/bad" "$(cmd '/usr/bin/env bash -p scripts/pr-close-round.sh gate 7 bot s no h p')" 2 "the round gate is a push"
expect "$tmp/bad" "$(cmd '/usr/bin/env bash -p scripts/pr-close-round.sh   gate 7 bot s no h p')" 2 "…however the gate is spaced"
expect "$tmp/bad" "$(cmd '/usr/bin/env bash -p scripts/pr-close-round.sh</dev/null gate 7 bot s no h p')" 2 "…or redirected"
expect "$tmp/bad" "$(cmd '/usr/bin/env bash -p scripts/pr-close-round.sh&>/dev/null gate 7 bot s no h p')" 2 "…in any spelling"
expect "$tmp/bad" "$(cmd '/usr/bin/env bash -p scripts/pr-close-round.sh${IFS}gate 7 bot s no h p')" 2 "…or split by an expansion"
expect "$tmp/bad" "$(cmd '/usr/bin/env bash -p scripts/pr-close-round.sh post 7 bot s no h p n')" 0 "…and post is not the gate"
expect "$tmp/none" "$(cmd 'git push origin b')" 2 "a missing self-check blocks the push"
grep -q 'missing or not executable' "$tmp/err" && pass "…and is named" || die "the missing check was not named: $(head -c 120 "$tmp/err")"
expect "$tmp/hang" "$(cmd 'git push origin b')" 2 "a self-check that hangs is bounded inside the hook and blocks"
grep -q 'did not finish' "$tmp/err" && pass "…and says so" || die "the hang was not named: $(head -c 120 "$tmp/err")"

# The change being pushed owns everything under the project, the watchdog and the findings alike.
mkdir -p "$tmp/quoting/skills/watch-prs/scripts"
cp "$tmp/ok/skills/watch-prs/scripts/pr-selfcheck.sh.quoting" "$tmp/quoting/skills/watch-prs/scripts/pr-selfcheck.sh"
chmod +x "$tmp/quoting/skills/watch-prs/scripts/pr-selfcheck.sh"
mkdir -p "$tmp/notimeout"
for c in bash env jq grep sort head sleep kill mktemp rm; do
    p="$(command -v "$c")" && ln -sf "$p" "$tmp/notimeout/$c"
done
rc=0; printf '%s' "$(cmd 'git push origin b')" | env PATH="$tmp/notimeout" CLAUDE_PROJECT_DIR="$tmp/hang" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && grep -q 'did not finish' "$tmp/err" && pass "the bound holds where timeout is not installed" || die "no-timeout hang rc=$rc: $(head -c 160 "$tmp/err")"
[ "$(wc -l <"$tmp/err")" -eq 1 ] && pass "…and the shell's own notice about the killed job is not passed on" || die "the fallback said more than its message: $(head -c 200 "$tmp/err")"
expect "$tmp/quoting" "$(cmd 'git push origin b')" 2 "a finding that quotes the line it was found on still blocks"
grep -q 'finding=quoted_line' "$tmp/err" && ! grep -q PLACEHOLDER_VALUE_NOT_FOR_LOGS "$tmp/err" \
    && pass "…and the hook reports the finding, never the line" || die "the quoted line reached stderr: $(head -c 200 "$tmp/err")"
printf 'run_limited() { return 0; }\nmktemp_d() { return 1; }\n' > "$tmp/bad/skills/watch-prs/scripts/testlib.sh.stub"
rm -f "$tmp/bad/skills/watch-prs/scripts/testlib.sh"
cp "$tmp/bad/skills/watch-prs/scripts/testlib.sh.stub" "$tmp/bad/skills/watch-prs/scripts/testlib.sh"
expect "$tmp/bad" "$(cmd 'git push origin b')" 2 "a watchdog the change replaced with one that runs nothing does not pass the push"
for b in 581 0 abc; do
    rc=0; printf '%s' "$(cmd 'git push origin b')" | CLAUDE_PROJECT_DIR="$tmp/bad" PRE_PUSH_BOUND="$b" "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
    [ "$rc" -eq 2 ] && grep -q 'PRE_PUSH_BOUND' "$tmp/err" && pass "a bound of $b is refused at once, before the deadline can pass" || die "PRE_PUSH_BOUND=$b rc=$rc: $(head -c 120 "$tmp/err")"
done
expect "$tmp/ok" '' 2 "empty input blocks"
expect "$tmp/ok" 'not json' 2 "unreadable input blocks"
expect "$tmp/ok" '{"tool_input":{}}' 2 "an envelope with no command blocks"
expect "$tmp/ok" '{"tool_input":{"command":null}}' 2 "a null command blocks"
expect "$tmp/ok" "$(cmd 'ls')$(cmd 'ls')" 2 "two envelopes block"
bash_bin="$(command -v bash)"
mkdir -p "$tmp/nojq"; ln -s "$bash_bin" "$tmp/nojq/bash"
rc=0; printf '%s' "$(cmd 'git push origin b')" | env PATH="$tmp/nojq" CLAUDE_PROJECT_DIR="$tmp/bad" "$HOOKS/pre-push.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "a missing jq blocks rather than passing an unchecked push" || die "with jq absent rc=$rc"
rc=0; printf '%s' "$(cmd 'git push origin b')" | CLAUDE_PROJECT_DIR="$tmp/ok" "$bash_bin" "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && grep -q 'privileged' "$tmp/err" && pass "a push hook started unprivileged refuses rather than checking" || die "unprivileged start rc=$rc: $(head -c 120 "$tmp/err")"

post() { printf '%s' "$1" | "$HOOKS/post-edit.sh" >/dev/null 2>"$tmp/err"; }
fp() { printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
printf 'echo "(\n' > "$tmp/broken.sh"; printf 'echo ok\n' > "$tmp/good.sh"; printf 'echo "(\n' > "$tmp/notes.md"
rc=0; post "$(fp "$tmp/broken.sh")" || rc=$?; [ "$rc" -eq 2 ] && pass "a shell file that does not parse is reported" || die "broken.sh rc=$rc"
printf 'x=PLACEHOLDER_VALUE_NOT_FOR_LOGS )\n' > "$tmp/leak.sh"
rc=0; post "$(fp "$tmp/leak.sh")" || rc=$?
[ "$rc" -eq 2 ] && grep -q 'line 1' "$tmp/err" && ! grep -q PLACEHOLDER_VALUE_NOT_FOR_LOGS "$tmp/err" && pass "the report names the file and the line, never the line's text" || die "leak.sh rc=$rc: $(head -c 160 "$tmp/err")"
rc=0; post "$(fp "$tmp/good.sh")" || rc=$?;   [ "$rc" -eq 0 ] && pass "a shell file that parses passes" || die "good.sh rc=$rc"
rc=0; post "$(fp "$tmp/notes.md")" || rc=$?;  [ "$rc" -eq 0 ] && pass "a non-shell file is not parsed" || die "notes.md rc=$rc"
rc=0; post 'not json' || rc=$?;               [ "$rc" -eq 2 ] && pass "unreadable input is reported" || die "malformed post-edit input rc=$rc"
rc=0; post '{"tool_input":{}}' || rc=$?;      [ "$rc" -eq 2 ] && pass "an envelope with no path is reported" || die "pathless post-edit input rc=$rc"
rc=0; post '{"tool_input":{"file_path":null}}' || rc=$?; [ "$rc" -eq 2 ] && pass "a null path is reported" || die "null post-edit path rc=$rc"
rc=0; post '' || rc=$?;                       [ "$rc" -eq 2 ] && pass "empty post-edit input is reported" || die "empty post-edit input rc=$rc"
rc=0; post "$(fp "$tmp/broken.sh")$(fp "$tmp/good.sh")" || rc=$?; [ "$rc" -eq 2 ] && pass "two envelopes are reported, not read as one path" || die "two post-edit envelopes rc=$rc"
misleading="$tmp/x: line 99: broken.sh"
printf 'x=1 )\n' > "$misleading"
rc=0; post "$(fp "$misleading")" || rc=$?
[ "$rc" -eq 2 ] && grep -q 'at line 1' "$tmp/err" && pass "the line comes from the diagnostic, not from a path that spells one" || die "misleading path rc=$rc: $(head -c 160 "$tmp/err")"

# Tracing inherited at startup prints every expansion, the sanitised ones included.
rc=0; printf '%s' "$(fp "$tmp/leak.sh")" | env SHELLOPTS=xtrace "$HOOKS/post-edit.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && ! grep -q PLACEHOLDER_VALUE_NOT_FOR_LOGS "$tmp/err" && pass "inherited tracing does not print the diagnostic the edit hook refuses to quote" || die "traced post-edit rc=$rc: $(head -c 160 "$tmp/err")"
! grep -q '^+ ' "$tmp/err" && pass "…and a privileged start left no trace at all" || die "the edit hook traced: $(head -c 160 "$tmp/err")"
rc=0; printf '%s' "$(cmd 'git push origin b # PLACEHOLDER_VALUE_NOT_FOR_LOGS')" | env CLAUDE_PROJECT_DIR="$tmp/bad" PRE_PUSH_BOUND=2 SHELLOPTS=xtrace "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && ! grep -q PLACEHOLDER_VALUE_NOT_FOR_LOGS "$tmp/err" && pass "inherited tracing does not print the push hook's command" || die "traced pre-push rc=$rc: $(head -c 160 "$tmp/err")"
! grep -q '^+ ' "$tmp/err" && pass "…and that start left no trace either" || die "the push hook traced: $(head -c 160 "$tmp/err")"
printf '#!/usr/bin/env bash\nx=PLACEHOLDER_VALUE_NOT_FOR_LOGS\n' > "$tmp/control.sh"; chmod +x "$tmp/control.sh"
env SHELLOPTS=xtrace "$tmp/control.sh" 2>"$tmp/err"
grep -q PLACEHOLDER_VALUE_NOT_FOR_LOGS "$tmp/err" && pass "…where an ordinary shell started the same way does trace" || die "SHELLOPTS traced nothing at all, so the two cases above prove nothing"

# An environment that replaces a name the hooks call: privileged mode is the answer, so the
# override must reach a shell that ignores it rather than one that imports it.
printf 'jq() { cat >/dev/null; return 0; }\nbash() { return 0; }\n' > "$tmp/env.sh"
rc=0; printf '%s' "$(cmd 'git push origin b')" | env BASH_ENV="$tmp/env.sh" CLAUDE_PROJECT_DIR="$tmp/bad" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && pass "a jq defined through BASH_ENV does not pass the push" || die "BASH_ENV jq rc=$rc: $(head -c 160 "$tmp/err")"
rc=0; printf '%s' "$(fp "$tmp/broken.sh")" | env BASH_ENV="$tmp/env.sh" "$HOOKS/post-edit.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && pass "a bash defined through BASH_ENV does not pass a file that will not parse" || die "BASH_ENV bash rc=$rc: $(head -c 160 "$tmp/err")"
rc=0; printf '%s' "$(cmd 'git push origin b')" | env "BASH_FUNC_jq%%=() { cat >/dev/null; return 0; }" CLAUDE_PROJECT_DIR="$tmp/bad" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && pass "an exported jq function does not pass the push" || die "exported jq rc=$rc: $(head -c 160 "$tmp/err")"

# A BASH_ENV that exits kills an unprivileged shell before its first line, so the flag comes
# from the invocation settings.json makes, not from the script.
printf 'exit 0\n' > "$tmp/exit.sh"
rc=0; printf '%s' "$(cmd 'git push origin b')" | env BASH_ENV="$tmp/exit.sh" CLAUDE_PROJECT_DIR="$tmp/bad" PRE_PUSH_BOUND=2 /usr/bin/env bash -p "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && pass "a BASH_ENV that exits does not pass the push" || die "BASH_ENV exit, push hook, rc=$rc: $(head -c 160 "$tmp/err")"
rc=0; printf '%s' "$(fp "$tmp/broken.sh")" | env BASH_ENV="$tmp/exit.sh" /usr/bin/env bash -p "$HOOKS/post-edit.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && pass "a BASH_ENV that exits does not pass a file that will not parse" || die "BASH_ENV exit, edit hook, rc=$rc: $(head -c 160 "$tmp/err")"

[ "$fail" -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
