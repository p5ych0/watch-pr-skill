#!/usr/bin/env bash
# Re-drift guard: the review-bus scripts + skill must stay repo-agnostic —
# identity is derived from `git remote get-url origin`, never hard-coded. Fails
# if a concrete owner/repo slug or bus path appears. (Bare `p5ych0` is allowed —
# it names the shared review token in comments, not an identity to derive.)
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Concrete-identity patterns that must never be hard-coded: a repo slug
# (p5ych0/pulse), a unit slug (p5ych0-pulse), or any concrete /tmp path keyed on
# the repo name (…/pulse-review-bus, …/pulse-claude-worktrees, …).
PAT='p5ych0/(pulse|strumok)|p5ych0-(pulse|strumok)|/tmp/(p5ych0-)?(pulse|strumok)-|/home/[^ ]*/(pulse|strumok)\b|owner=.?p5ych0|repo=.?(pulse|strumok)|(PULSE|STRUMOK)_REVIEW'

FILES=( "$ROOT"/review-bus-codex-start.sh
        "$ROOT"/review-bus-codex-watcher.sh
        "$ROOT"/review-bus-request.sh
        "$ROOT"/review-bus-response-monitor.sh
        "$ROOT"/review-bus-copilot.sh )
# In the plugin, the five scripts sit beside this test (skills/watch-prs/scripts/)
# and SKILL.md is one level up. Guard the skill only when present (robust if a
# consumer strips it); in the plugin it is always there, so it is always linted.
SKILL="$ROOT/../SKILL.md"
[ -f "$SKILL" ] && FILES+=( "$SKILL" )
# The SessionStart hook (plugin-root/hooks/) must also stay repo-agnostic.
HOOK="$ROOT/../../../hooks/session-start.sh"
[ -f "$HOOK" ] && FILES+=( "$HOOK" )

hits="$(grep -nHE "$PAT" "${FILES[@]}" 2>/dev/null || true)"
if [ -n "$hits" ]; then
    echo "FAIL - hard-coded identity literal(s) found (identity must be derived):"
    printf '%s\n' "$hits" | sed 's/^/  /'
    echo "RESULT: FAIL"
    exit 1
fi
echo "ok   - no hard-coded owner/repo/bus identity in scripts or skill"
echo "RESULT: PASS"
