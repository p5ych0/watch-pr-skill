#!/usr/bin/env bash
# SessionStart hook (Claude Code + Codex) — arm the review bus automatically in
# repos that opt in by committing a `.review-bus.md`. Quiet everywhere else.
#
# Contract for a SessionStart hook: it MUST NOT block or fail the session, and
# only its stdout becomes session context. So: gate fast, launch daemons DETACHED
# with output redirected off this stdout, print one plain-text instruction, and
# always exit 0.
set -uo pipefail

# Act only inside a git repo that opted in.
PROJECT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$PROJECT" ] || exit 0
[ -f "$PROJECT/.review-bus.md" ] || exit 0

# NEVER arm the bus inside a review worker. The reviewer runs `codex exec` in a
# detached worktree of the PR head, which carries the project's own
# .review-bus.md — so in a repo that opted in, the gate above passes for the
# reviewer too. Without this guard a self-review re-ensures the daemons and, far
# worse, injects the "invoke watch-prs" instruction into the reviewer's own
# context, spending the review pass on bus setup instead of the diff.
#
# Two independent signals, because either alone can be defeated. The watcher
# exports REVIEW_BUS_WORKER=1, but a tool that does not forward env to hook
# commands would drop it. The fallback is a marker the watcher writes into the
# worktree's GIT DIR (not the working tree, so it never reaches the diff).
#
# The marker is deliberately NOT a path test: WORKTREE_ROOT, BUS_DIR and the
# review clone are all operator-overridable, so matching a literal
# ".codex-worktrees" would miss a custom CODEX_REVIEW_WORKTREE_ROOT — exactly
# the env-stripped case this fallback exists for — while falsely silencing an
# ordinary opted-in checkout that happens to live under such a directory.
[ -z "${REVIEW_BUS_WORKER:-}" ] || exit 0
GIT_DIR_PATH="$(git -C "$PROJECT" rev-parse --absolute-git-dir 2>/dev/null || true)"
[ -z "$GIT_DIR_PATH" ] || [ ! -f "$GIT_DIR_PATH/review-bus-worker" ] || exit 0

# Locate the plugin. Both tools set CLAUDE_PLUGIN_ROOT for hook commands (Codex
# also sets PLUGIN_ROOT); self-locate from this script's dir as a last resort in
# case a build leaves the var empty during SessionStart.
ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}}"
START="$ROOT/skills/watch-prs/scripts/review-bus-codex-start.sh"
[ -x "$START" ] || exit 0

# Ensure the persistent daemons are up — DETACHED, output redirected to a log, so
# nothing pollutes session context and the hook returns immediately (can't block
# or hit the timeout on a first-run clone).
LOG_DIR="${TMPDIR:-/tmp}/watch-pr-skill"
mkdir -p "$LOG_DIR" 2>/dev/null || true
( cd "$PROJECT" && setsid env CODEX_REVIEW_AUTO_OPEN_PRS=1 "$START" ) \
  >"$LOG_DIR/session-start.log" 2>&1 </dev/null &
disown 2>/dev/null || true

# Inject a plain-text instruction (SessionStart stdout → session context). Plain
# text is more reliable than the plugin additionalContext JSON (swallowed on some
# versions); the watch-prs SKILL.md description is the fallback auto-trigger.
cat <<'EOF'
watch-pr-skill: the review bus is enabled for this repo (.review-bus.md present)
and its daemons are being ensured in the background. Invoke the watch-prs skill
now to attach this session's review monitor, so Codex review passes surface as
notifications you can act on.
EOF

exit 0
