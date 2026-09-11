#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../../.."
HOOKS="$ROOT/.claude/hooks"
SETTINGS="$ROOT/.claude/settings.json"
fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }
. "$SCRIPT_DIR/testlib.sh" || exit 1
tmp="$(mktemp_d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

ships_no_hook() {
    local found
    [ ! -e "$1/hooks" ] && [ ! -L "$1/hooks" ] \
        && jq -e 'has("hooks") | not' "$1/.claude-plugin/plugin.json" >/dev/null \
        && jq -e 'all(.plugins[]; has("hooks") | not)' "$1/.claude-plugin/marketplace.json" >/dev/null \
        && found="$(find "$1" -name .git -prune -o -name '*.md' -exec awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } /^hooks:/ { f = 1; exit } END { exit !f }' {} \; -print)" \
        && [ -z "$found" ]
}
for d in clean dir plugin market skill; do
    mkdir -p "$tmp/root-$d/.claude-plugin" "$tmp/root-$d/skills/s"
    printf '{"name":"p"}\n' > "$tmp/root-$d/.claude-plugin/plugin.json"
    printf '{"plugins":[{"name":"p","source":"./"}]}\n' > "$tmp/root-$d/.claude-plugin/marketplace.json"
    printf -- '---\nname: s\n---\n\nhooks: prose, not frontmatter\n' > "$tmp/root-$d/skills/s/SKILL.md"
done
mkdir -p "$tmp/root-dir/hooks" "$tmp/root-unread/.claude-plugin"
printf '{"name":"p","hooks":"./h.json"}\n' > "$tmp/root-plugin/.claude-plugin/plugin.json"
printf '{"plugins":[{"name":"p","source":"./","hooks":{}}]}\n' > "$tmp/root-market/.claude-plugin/marketplace.json"
printf -- '---\nname: s\nhooks:\n  Stop: []\n---\n' > "$tmp/root-skill/skills/s/SKILL.md"
ships_no_hook "$tmp/root-clean" && pass "a plugin root with no hook route passes the install check" \
    || die "the install check refuses a plugin root that ships no hook"
for d in dir plugin market skill unread; do
    ships_no_hook "$tmp/root-$d" && die "the $d decoy passed the install check" || pass "the $d decoy fails the install check"
done
ships_no_hook "$ROOT" && pass "no hook ships with the plugin, so the evasion the authoring-tools record accepts stays in this checkout" \
    || die "a hook ships with the plugin, or a manifest could not be read; docs/decisions/2026-09-07-authoring-tools-not-boundaries.md accepts neither"

BRIEF="$ROOT/agents/cold-reviewer.md"
front_ok() {
    local fm
    fm="$(awk 'NR == 1 && $0 != "---" { exit 1 } NR > 1 && $0 == "---" { c = 1; exit } NR > 1 { print } END { exit !c }' "$1")" \
        && [ "$(grep -c '^name:' <<<"$fm")" -eq 1 ] && grep -qx 'name: cold-reviewer' <<<"$fm" && [ "$(grep -c '^tools:' <<<"$fm")" -eq 1 ] && grep -qx 'tools: Read, Bash' <<<"$fm"
}
if [ -f "$BRIEF" ] && [ ! -L "$BRIEF" ]; then
    front_ok "$BRIEF" \
        && pass "the cold reviewer ships at the plugin root, its frontmatter closed, named, with only Read and Bash" \
        || die "agents/cold-reviewer.md has no closed frontmatter, holds a name or tools line other than exactly one cold-reviewer and one Read, Bash"
    awk '!(NR > 1 && $0 == "---" && !d++)' "$BRIEF" > "$tmp/brief-open.md" || die "the open brief decoy was not written"
    awk '{ print } $0 == "tools: Read, Bash" { print "tools: Read, Bash, Write" }' "$BRIEF" > "$tmp/brief-twotools.md" || die "the twotools brief decoy was not written"
    awk '{ print } $0 == "name: cold-reviewer" { print "name: other" }' "$BRIEF" > "$tmp/brief-twonames.md" || die "the twonames brief decoy was not written"
    awk '$0 != "name: cold-reviewer"' "$BRIEF" > "$tmp/brief-unnamed.md" || die "the unnamed brief decoy was not written"
    for d in open twotools twonames unnamed; do
        front_ok "$tmp/brief-$d.md" && die "the $d brief decoy passed the frontmatter check" || pass "the $d brief decoy fails the frontmatter check"
    done
    # The brief is prose a subagent follows, so its commands are pinned by shape, not by running.
    grep -q 'GIT_OPTIONAL_LOCKS=0 git -C' "$BRIEF" && pass "the cold reviewer's commands write no index" \
        || die "the brief no longer disables optional locks, so its status can rewrite the index"
    grep -q 'core.fsmonitor=false' "$BRIEF" && pass "…and run no configured monitor hook" \
        || die "the brief no longer disables the filesystem monitor"
    grep -q 'test -e <that root>/<path>' "$BRIEF" && pass "…and what the tree still holds is decided by a probe" \
        || die "the brief no longer probes for the path before reading it"
    [ "$(grep -n 'test -L <that root>/<path>' "$BRIEF" | head -1 | cut -d: -f1)" -lt "$(grep -n 'test -e <that root>/<path>' "$BRIEF" | head -1 | cut -d: -f1)" ] \
        && pass "…with the link probe first, since -e follows a link and calls a dangling one absent" \
        || die "the brief asks -e before -L, so a dangling link reads as absent"
    grep -q 'readlink -- <that root>/<path>' "$BRIEF" && pass "…and a link is read without following it" \
        || die "the brief no longer reads a link with readlink at the root"
    grep -qF 'for each path the secrets rule does' "$BRIEF" \
        && grep -qF 'one named `.env`, `.env.*`, `*.pem` or `*.key`, or with a `.env`, `.env.*` or' "$BRIEF" \
        && grep -qF '`.ssh` directory anywhere above it' "$BRIEF" \
        && pass "…and it leaves a path unopened when its name, or any directory above it, marks it as holding secrets" \
        || die "the brief's secrets rule no longer covers both a path's name and the directories above it"
    policy=0
    for s in 'ls-tree --name-only <base> -- <paths>' '`.github/copilot-instructions.md`' '`AGENTS.override.md`, `AGENTS.md` and `CLAUDE.md`' 'holds a changed path or lies above one' 'naming none the secrets rule marks' '`AGENTS.override.md` is read' 'in place of its `AGENTS.md`'; do
        grep -qF -- "$s" "$BRIEF" || { die "the brief no longer reads policy through: $s"; policy=1; }
    done
    if [ "$policy" -eq 0 ]; then
        shows="$(grep -oE 'git( [^` ]+)* show [^`]*' "$BRIEF")"
        [ "$(sort -u <<<"$shows")" = 'git show <base>:<path>' ] \
            && pass "…and it reads whichever policy files the base has, through one git show that names no fixed file" \
            || die "the brief's git show is not exactly git show <base>:<path>, so it can name a file a consuming project lacks: $shows"
    fi
else
    die "agents/cold-reviewer.md is not a regular file, so no project that installs the plugin gets the cold reviewer"
fi

# The settings file is the promise; a copy without one has no hooks to prove.
if [ ! -f "$SETTINGS" ]; then
    echo "ok   - no .claude/settings.json in this copy; hook checks skipped"
    [ "$fail" -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
fi

GUARD='h="$1"; LC_ALL=C bash -p -n -- "$h" 2>/dev/null || { echo "blocked: the hook does not parse; it was not run" >&2; exit 2; }; exec bash -p -- "$h"'
PRE_CMD="/usr/bin/env bash -p -c '$GUARD' guard \"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/pre-push.sh"
POST_CMD="/usr/bin/env bash -p -c '$GUARD' guard \"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/post-edit.sh"
wired() {
    jq -e --arg c "$PRE_CMD" '.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]? | select(.type == "command" and .command == $c and .timeout == 600)' "$1" >/dev/null \
    && jq -e --arg c "$POST_CMD" '.hooks.PostToolUse[]? | select(.matcher == "Write|Edit") | .hooks[]? | select(.type == "command" and .command == $c)' "$1" >/dev/null
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

# So the push arm is proved without the suite.
for p in ok bad hang none; do
    mkdir -p "$tmp/$p/skills/watch-prs/scripts"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/ok/skills/watch-prs/scripts/pr-selfcheck.sh"
printf '#!/usr/bin/env bash\necho "PR_SELFCHECK finding=x"\nexit 1\n' > "$tmp/bad/skills/watch-prs/scripts/pr-selfcheck.sh"
printf '#!/usr/bin/env bash\nsleep 3600 &\necho "$!" > "%s"\nwait\n' "$tmp/child.pid" > "$tmp/hang/skills/watch-prs/scripts/pr-selfcheck.sh"
printf '#!/usr/bin/env bash\necho "PR_SELFCHECK finding=quoted_line SKILL.md:12"\necho "  gh pr comment --body PLACEHOLDER_VALUE_NOT_FOR_LOGS"\necho "PR_SELFCHECK finding=PLACEHOLDER_VALUE_NOT_FOR_LOGS"\necho "PR_SELFCHECK status=findings count=1"\nexit 1\n' > "$tmp/ok/skills/watch-prs/scripts/pr-selfcheck.sh.quoting"
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
mkdir -p "$tmp/PLACEHOLDER_VALUE_NOT_FOR_LOGS/skills/watch-prs/scripts"
expect "$tmp/PLACEHOLDER_VALUE_NOT_FOR_LOGS" "$(cmd 'git push origin b')" 2 "a project path that itself holds a value blocks"
! grep -q PLACEHOLDER_VALUE_NOT_FOR_LOGS "$tmp/err" && pass "…and no part of that path is in the message" || die "the project path reached stderr: $(head -c 160 "$tmp/err")"
expect "$tmp/hang" "$(cmd 'git push origin b')" 2 "a self-check that hangs is bounded inside the hook and blocks"
grep -q 'did not finish' "$tmp/err" && pass "…and says so" || die "the hang was not named: $(head -c 120 "$tmp/err")"
! grep -q ' 2s' "$tmp/err" && pass "…without repeating the bound it was given" || die "the bound reached the message: $(head -c 160 "$tmp/err")"

# The change being pushed owns everything under the project, the watchdog and the findings alike.
mkdir -p "$tmp/quoting/skills/watch-prs/scripts"
cp "$tmp/ok/skills/watch-prs/scripts/pr-selfcheck.sh.quoting" "$tmp/quoting/skills/watch-prs/scripts/pr-selfcheck.sh"
chmod +x "$tmp/quoting/skills/watch-prs/scripts/pr-selfcheck.sh"
mkdir -p "$tmp/detached/skills/watch-prs/scripts"
printf '#!/usr/bin/env bash\nsleep 3600 &\necho "PR_SELFCHECK finding=x"\nexit 1\n' > "$tmp/detached/skills/watch-prs/scripts/pr-selfcheck.sh"
chmod +x "$tmp/detached/skills/watch-prs/scripts/pr-selfcheck.sh"
started=$(date +%s)
expect "$tmp/detached" "$(cmd 'git push origin b')" 2 "a self-check whose child outlives it and holds the pipe open still blocks"
[ "$(( $(date +%s) - started ))" -le 8 ] && pass "…within the bound, since the deadline covers the counting too" || die "the detached child held the hook for $(( $(date +%s) - started ))s"
mkdir -p "$tmp/detachedok/skills/watch-prs/scripts"
printf '#!/usr/bin/env bash\nsleep 3600 &\nexit 0\n' > "$tmp/detachedok/skills/watch-prs/scripts/pr-selfcheck.sh"
chmod +x "$tmp/detachedok/skills/watch-prs/scripts/pr-selfcheck.sh"
expect "$tmp/detachedok" "$(cmd 'git push origin b')" 2 "a check that exits clean while a child holds the pipe is not a clean check"
grep -q 'did not finish' "$tmp/err" && pass "…it is a deadline, and says so" || die "the cut-short run was called clean: $(head -c 160 "$tmp/err")"
# The status of the read that recovers the check's result: a plausible value from a failed
# read is the deadline path, not a clean one.
mkdir -p "$tmp/badcat"
for c in bash env jq grep sleep kill mktemp rm; do
    p="$(command -v "$c")" && ln -sf "$p" "$tmp/badcat/$c"
done
printf '#!/usr/bin/env bash\nprintf 0\nexit 1\n' > "$tmp/badcat/cat"; chmod +x "$tmp/badcat/cat"
rc=0; printf '%s' "$(cmd 'git push origin b')" | env PATH="$tmp/badcat" CLAUDE_PROJECT_DIR="$tmp/ok" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && pass "a read that prints a clean status and then fails does not pass the push" || die "failed status read rc=$rc: $(head -c 160 "$tmp/err")"
# grep says 0 for a match and 1 for none; anything else is a count that did not happen.
mkdir -p "$tmp/failcount"
for c in bash env jq sleep kill mktemp rm cat; do
    p="$(command -v "$c")" && ln -sf "$p" "$tmp/failcount/$c"
done
printf '#!/usr/bin/env bash\nprintf 0\nexit 2\n' > "$tmp/failcount/grep"; chmod +x "$tmp/failcount/grep"
rc=0; printf '%s' "$(cmd 'git push origin b')" | env PATH="$tmp/failcount" CLAUDE_PROJECT_DIR="$tmp/ok" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && pass "a count that prints a number and then fails does not pass the push" || die "failed count rc=$rc: $(head -c 160 "$tmp/err")"
printf '#!/usr/bin/env bash\nprintf 0\nexit 1\n' > "$tmp/failcount/grep"
rc=0; printf '%s' "$(cmd 'git push origin b')" | env PATH="$tmp/failcount" CLAUDE_PROJECT_DIR="$tmp/ok" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 0 ] && pass "…while a count of none is a count, and the push passes" || die "no-match count rc=$rc: $(head -c 160 "$tmp/err")"
mkdir -p "$tmp/nogread"
for c in bash env jq grep sleep kill mktemp rm; do
    p="$(command -v "$c")" && ln -sf "$p" "$tmp/nogread/$c"
done
printf '#!/usr/bin/env bash\ncase "$*" in *"/g") printf 0; exit 1 ;; esac\nexec %s "$@"\n' "$(command -v cat)" > "$tmp/nogread/cat"; chmod +x "$tmp/nogread/cat"
rc=0; printf '%s' "$(cmd 'git push origin b')" | env PATH="$tmp/nogread" CLAUDE_PROJECT_DIR="$tmp/ok" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && pass "a failed read of the count's status blocks, as the check's own does" || die "unread count status rc=$rc: $(head -c 160 "$tmp/err")"
mkdir -p "$tmp/nonread"
for c in bash env jq grep sleep kill mktemp rm; do
    p="$(command -v "$c")" && ln -sf "$p" "$tmp/nonread/$c"
done
printf '#!/usr/bin/env bash\ncase "$*" in *"/n") printf 0; exit 1 ;; esac\nexec %s "$@"\n' "$(command -v cat)" > "$tmp/nonread/cat"; chmod +x "$tmp/nonread/cat"
rc=0; printf '%s' "$(cmd 'git push origin b')" | env PATH="$tmp/nonread" CLAUDE_PROJECT_DIR="$tmp/bad" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && grep -q 'an unknown number of findings' "$tmp/err" \
    && pass "…and a count that could not be read is reported as unknown, not as none" || die "unread count rc=$rc: $(head -c 200 "$tmp/err")"
[ -L "$ROOT/.claude/agents/cold-reviewer.md" ] && [ "$(readlink "$ROOT/.claude/agents/cold-reviewer.md")" = ../../agents/cold-reviewer.md ] \
    && pass "this checkout reads the cold reviewer it ships, through a link, not an installed copy" \
    || die ".claude/agents/cold-reviewer.md is not the link to ../../agents/cold-reviewer.md, so this checkout reviews with another brief"
# A parent that is not there fails every open whatever the user's privileges are.
mkdir -p "$tmp/noopen"
for c in bash env jq grep sleep kill rm cat; do
    p="$(command -v "$c")" && ln -sf "$p" "$tmp/noopen/$c"
done
printf '#!/usr/bin/env bash\nprintf %%s "%s/PLACEHOLDER_VALUE_NOT_FOR_LOGS.gone/scratch"\n' "$tmp" > "$tmp/noopen/mktemp"; chmod +x "$tmp/noopen/mktemp"
for p in ok hang; do
    rc=0; printf '%s' "$(cmd 'git push origin b')" | env PATH="$tmp/noopen" CLAUDE_PROJECT_DIR="$tmp/$p" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
    [ "$rc" -eq 2 ] && ! grep -q PLACEHOLDER_VALUE_NOT_FOR_LOGS "$tmp/err" \
        && pass "a scratch directory that cannot be written blocks a $p check, and its path is in no diagnostic" \
        || die "unwritable scratch, $p check, rc=$rc: $(head -c 200 "$tmp/err")"
done
mkdir -p "$tmp/norm"
for c in bash env jq grep sleep kill mktemp cat; do
    p="$(command -v "$c")" && ln -sf "$p" "$tmp/norm/$c"
done
printf '#!/usr/bin/env bash\necho "rm: cannot remove PLACEHOLDER_VALUE_NOT_FOR_LOGS/tmp.XXX" >&2\nexit 1\n' > "$tmp/norm/rm"; chmod +x "$tmp/norm/rm"
rc=0; printf '%s' "$(cmd 'git push origin b')" | env PATH="$tmp/norm" CLAUDE_PROJECT_DIR="$tmp/bad" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && ! grep -q PLACEHOLDER_VALUE_NOT_FOR_LOGS "$tmp/err" && pass "a cleanup that cannot remove the scratch directory says nothing about it" || die "cleanup diagnostic rc=$rc: $(head -c 160 "$tmp/err")"
mkdir -p "$tmp/nomktemp"
for c in bash env jq grep sleep kill rm cat; do
    p="$(command -v "$c")" && ln -sf "$p" "$tmp/nomktemp/$c"
done
printf '#!/usr/bin/env bash\necho "mktemp: failed to create directory via template PLACEHOLDER_VALUE_NOT_FOR_LOGS/tmp.XXX" >&2\nexit 1\n' > "$tmp/nomktemp/mktemp"; chmod +x "$tmp/nomktemp/mktemp"
rc=0; printf '%s' "$(cmd 'git push origin b')" | env PATH="$tmp/nomktemp" CLAUDE_PROJECT_DIR="$tmp/ok" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && ! grep -q PLACEHOLDER_VALUE_NOT_FOR_LOGS "$tmp/err" && pass "a scratch directory that cannot be made blocks, and the utility's own path is not passed on" || die "mktemp failure rc=$rc: $(head -c 160 "$tmp/err")"
mkdir -p "$tmp/notimeout"
for c in bash env jq grep sort head sleep kill mktemp rm; do
    p="$(command -v "$c")" && ln -sf "$p" "$tmp/notimeout/$c"
done
rc=0; printf '%s' "$(cmd 'git push origin b')" | env PATH="$tmp/notimeout" CLAUDE_PROJECT_DIR="$tmp/hang" PRE_PUSH_BOUND=2 "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && grep -q 'did not finish' "$tmp/err" && pass "the bound holds where timeout is not installed" || die "no-timeout hang rc=$rc: $(head -c 160 "$tmp/err")"
[ "$(wc -l <"$tmp/err")" -eq 1 ] && pass "…and the shell's own notice about the killed job is not passed on" || die "the fallback said more than its message: $(head -c 200 "$tmp/err")"
child="$(cat "$tmp/child.pid" 2>/dev/null)"
[ -n "$child" ] && ! kill -0 "$child" 2>/dev/null && pass "…and what the self-check started is gone with it" || die "a child of the self-check outlived the deadline: pid '${child:-none}'"
mkdir -p "$tmp/loud/skills/watch-prs/scripts"
printf '#!/usr/bin/env bash\nsleep 1\nawk "BEGIN{ for (i = 0; i < 200000; i++) print \\"PR_SELFCHECK finding=x line of noise\\" }"\nexit 1\n' > "$tmp/loud/skills/watch-prs/scripts/pr-selfcheck.sh"
chmod +x "$tmp/loud/skills/watch-prs/scripts/pr-selfcheck.sh"
started=$(date +%s)
expect "$tmp/loud" "$(cmd 'git push origin b')" 2 "a slow self-check with a great deal of output blocks"
[ "$(( $(date +%s) - started ))" -le 8 ] && pass "…and reading what it printed stays inside the deadline" || die "the count took $(( $(date +%s) - started ))s"
expect "$tmp/quoting" "$(cmd 'git push origin b')" 2 "a finding that quotes the line it was found on still blocks"
grep -q 'with 2 findings' "$tmp/err" && ! grep -q PLACEHOLDER_VALUE_NOT_FOR_LOGS "$tmp/err" && [ "$(wc -l <"$tmp/err")" -eq 1 ] \
    && pass "…and the hook reports how many, never a word of what the check printed" || die "the check's output reached stderr: $(head -c 200 "$tmp/err")"
long="$(printf '9%.0s' {1..40})"
rc=0; printf '%s' "$(cmd 'git push origin b')" | env CLAUDE_PROJECT_DIR="$tmp/ok" PRE_PUSH_BOUND="$long" "$HOOKS/pre-push.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && ! grep -q 99999 "$tmp/err" && pass "a bound too large to compare is refused without any of it reaching the message" || die "long bound rc=$rc: $(head -c 160 "$tmp/err")"
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
printf 'echo ok\n' > "$tmp/-x.sh"
rc=0; ( cd "$tmp" && printf '%s' "$(fp '-x.sh')" | "$HOOKS/post-edit.sh" >/dev/null 2>"$tmp/err" ) || rc=$?
[ "$rc" -eq 0 ] && pass "…including one named so that it reads as an option" || die "-x.sh rc=$rc: $(head -c 160 "$tmp/err")"
rc=0; post "$(fp "$tmp/notes.md")" || rc=$?;  [ "$rc" -eq 0 ] && pass "a non-shell file is not parsed" || die "notes.md rc=$rc"
printf 'x=PLACEHOLDER_VALUE_NOT_FOR_LOGS )\n' > "$tmp/hook-itself.sh"; chmod +x "$tmp/hook-itself.sh"
rc=0; printf '%s' "$(fp "$tmp/good.sh")" | /usr/bin/env bash -p -c "$GUARD" guard "$tmp/hook-itself.sh" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] && ! grep -q PLACEHOLDER_VALUE_NOT_FOR_LOGS "$tmp/err" && ! grep -q "$tmp" "$tmp/err" \
    && pass "a hook the edit just broke is refused without its path or its own diagnostic" || die "the broken hook's line reached stderr: $(head -c 200 "$tmp/err")"
rc=0; post 'not json' || rc=$?;               [ "$rc" -eq 2 ] && pass "unreadable input is reported" || die "malformed post-edit input rc=$rc"
rc=0; post '{"tool_input":{}}' || rc=$?;      [ "$rc" -eq 2 ] && pass "an envelope with no path is reported" || die "pathless post-edit input rc=$rc"
rc=0; post '{"tool_input":{"file_path":null}}' || rc=$?; [ "$rc" -eq 2 ] && pass "a null path is reported" || die "null post-edit path rc=$rc"
rc=0; post '' || rc=$?;                       [ "$rc" -eq 2 ] && pass "empty post-edit input is reported" || die "empty post-edit input rc=$rc"
rc=0; post "$(fp "$tmp/broken.sh")$(fp "$tmp/good.sh")" || rc=$?; [ "$rc" -eq 2 ] && pass "two envelopes are reported, not read as one path" || die "two post-edit envelopes rc=$rc"
grep -q 'LC_ALL=C bash -p -n' "$HOOKS/post-edit.sh" && pass "the syntax probe runs under a fixed locale, where a translated diagnostic would hide the line" || die "post-edit.sh does not pin the locale of its syntax probe"
newline_path="$tmp/$(printf 'two\nlines').sh"
printf 'x=1 )\n' > "$newline_path"
rc=0; post "$(fp "$newline_path")" || rc=$?
[ "$rc" -eq 2 ] && grep -q 'at line 1' "$tmp/err" && [ "$(wc -l <"$tmp/err")" -eq 1 ] \
    && pass "a path holding a newline is reported at its line, on one line" || die "newline path rc=$rc: $(head -c 200 "$tmp/err")"
secret_path="$tmp/PLACEHOLDER_VALUE_NOT_FOR_LOGS.sh"
printf 'x=1 )\n' > "$secret_path"
rc=0; post "$(fp "$secret_path")" || rc=$?
[ "$rc" -eq 2 ] && grep -q 'at line 1' "$tmp/err" && ! grep -q PLACEHOLDER_VALUE_NOT_FOR_LOGS "$tmp/err" \
    && pass "a path that itself holds a value is reported by line alone" || die "secret path rc=$rc: $(head -c 200 "$tmp/err")"
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
