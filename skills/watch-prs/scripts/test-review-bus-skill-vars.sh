#!/usr/bin/env bash
# Doc-regression for the watch-prs skill: guards the variable-collision that made
# `--ack` receive a GraphQL page instead of the response-file path.
#
# The thread-fetch loop assigns the GraphQL page to a page variable; the `--ack`
# command must use a DISTINCT captured response path (RESP_PATH). If the loop
# reused `RESP` and `--ack "$RESP"` followed it in one shell, the ack got the
# last GraphQL payload, failed, and the "handled" response re-fired next session
# (the emit dir is intentionally fresh now).

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$SCRIPT_DIR/../SKILL.md"

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# The watch-prs skill is version-controlled in some repos and gitignored
# (local-only) in others, so it may be absent in a clean checkout / review
# worktree. When absent there is nothing to lint — skip (PASS), don't fail.
if [ ! -f "$SKILL" ]; then
    echo "ok   - skill not present in this checkout (gitignored / local-only); skill-vars checks skipped"
    echo "RESULT: PASS"
    exit 0
fi

# There is at least one --ack command, and every one uses $RESP_PATH.
ack_lines="$(grep -nE 'review-bus-response-monitor\.sh --ack' "$SKILL" || true)"
[ -n "$ack_lines" ] && pass "skill documents --ack commands" || die "no --ack command found in the skill"
if printf '%s\n' "$ack_lines" | grep -q . && printf '%s\n' "$ack_lines" | grep -vq 'RESP_PATH'; then
    die "an --ack command does not use \$RESP_PATH:"
    printf '%s\n' "$ack_lines" | grep -v 'RESP_PATH' | sed 's/^/    /'
else
    pass "every --ack command uses \$RESP_PATH"
fi

# RESP_PATH is captured somewhere before use.
grep -q 'RESP_PATH=' "$SKILL" && pass "RESP_PATH is captured" || die "RESP_PATH is never assigned"

# The thread-fetch GraphQL page must NOT reuse the colliding bare RESP variable.
if grep -qE '^[[:space:]]*RESP=\$\(gh api graphql' "$SKILL"; then
    die "thread-fetch loop assigns RESP= (collides with the --ack response path)"
else
    pass "thread-fetch loop uses a non-colliding page variable"
fi

# The iteration cap is opt-in (0=unlimited); the stale "Hard-cap at 30" /
# MAX_ITERATIONS-default-30 text must not drift back — it contradicts the watcher
# and the round-count check-in. (Narrow to the iteration cap: the progress
# heartbeat legitimately defaults to 30s.)
if grep -qE 'Hard-cap iterations at 30|MAX_ITERATIONS[^0-9]{0,20}30' "$SKILL"; then
    die "stale hard-cap-30 text present (cap is now 0=unlimited + round-count pause)"
else
    pass "no stale hard-cap-30 text"
fi

# The daemon-boot command must be \$REPO_DIR-prefixed so it works from a nested
# cwd (SessionStart/resume can run in backend/ or frontend/); a bare
# 'scripts/review-bus-codex-start.sh' command at line-start assumes the repo root
# and fails with 'No such file or directory'.
if grep -qE '^[[:space:]]*scripts/review-bus-codex-start\.sh' "$SKILL"; then
    die "bare start.sh command (must be \$REPO_DIR-prefixed for nested-cwd safety):"
    grep -nE '^[[:space:]]*scripts/review-bus-codex-start\.sh' "$SKILL" | sed 's/^/    /'
else
    pass "start.sh boot invocations are \$REPO_DIR-prefixed (nested-cwd safe)"
fi

# The round count must come from the PR's commits via the API (cwd-independent),
# NOT `git log … HEAD` against the current shell's HEAD — a resumed session can
# sit on main or another worktree, computing ROUNDS=0 and skipping the pause for
# PR #N. Using the API also removes the origin/main + fetch-refspec footguns.
if grep -qE 'git log.*fix\(review\).*HEAD' "$SKILL"; then
    die "round-count uses 'git log … HEAD' (cwd-dependent); use gh pr view --json commits"
else
    pass "round-count is not a cwd-dependent 'git log … HEAD'"
fi
grep -qE 'gh pr view .*--json commits' "$SKILL" \
    && pass "round-count reads the PR's commits via gh pr view --json commits" \
    || die "round-count does not use the gh pr view --json commits API"

# The re-request + ack commands must not be bare relative script paths at
# line-start: review-bus-request.sh reads cwd's HEAD (must run from the PR
# worktree, via `( cd "$WT" && … )`), and the ack must be "$REPO_DIR"-prefixed
# (cwd-independent). A bare command assumes the repo root / right worktree and
# silently requests the wrong SHA or fails with No such file or directory.
if grep -qE '^[[:space:]]*scripts/review-bus-(request|response-monitor)\.sh' "$SKILL"; then
    die "bare review-bus command at line-start (cwd-dependent); use ( cd \"\$WT\" && … ) or a \$REPO_DIR prefix:"
    grep -nE '^[[:space:]]*scripts/review-bus-(request|response-monitor)\.sh' "$SKILL" | sed 's/^/    /'
else
    pass "re-request runs from the PR worktree; ack is \$REPO_DIR-prefixed (cwd-safe)"
fi

# After a clean signoff both preflights block on a missing fresh summary, so a
# moved head is NOT auto-reviewable — the head-mismatch surface must document the
# real recovery (post a summary + re-request, or --force), not falsely promise
# auto-pickup.
if grep -qi 'picked up.*by.*auto-enqueue' "$SKILL"; then
    die "head-mismatch surface falsely promises auto-pickup of a moved head after clean signoff"
else
    pass "head-mismatch surface does not falsely promise auto-pickup"
fi
grep -qE 'review-bus-request\.sh --force' "$SKILL" \
    && pass "moved-head recovery documents review-bus-request.sh --force" \
    || die "moved-head recovery does not document the --force escape hatch"

# The round-count check-in is now enforced by the SCRIPTS (review-bus-request.sh
# refuses to enqueue at every Nth SHA), not counted in the skill — so the skill
# must document the script-emitted pause + how to cross it, not a fragile
# in-skill commit count that a manual driver bypasses.
grep -qE 'REVIEW_BUS_THRESHOLD_PAUSE' "$SKILL" \
    && pass "round-count check-in documents the script-emitted pause" \
    || die "SKILL does not mention REVIEW_BUS_THRESHOLD_PAUSE (the script-enforced check-in)"
grep -qE '\-\-continue-threshold|CODEX_REVIEW_ROUND_THRESHOLD' "$SKILL" \
    && pass "round-count pause documents how to continue / disable" \
    || die "SKILL does not document --continue-threshold / CODEX_REVIEW_ROUND_THRESHOLD"

# ── Optional Copilot pass (Phase D): the skill must document the ask, the
#    hold-on-no-answer, the iterate-to-clean loop, merge-on-Copilot-clean, and
#    the every-10th-round threshold pause — and must NOT auto-merge past the ask.
grep -qE 'review-bus-copilot\.sh' "$SKILL" \
    && pass "skill drives review-bus-copilot.sh" \
    || die "skill does not reference review-bus-copilot.sh"
grep -qiE 'optional Copilot pass' "$SKILL" \
    && pass "skill documents the Optional Copilot pass" \
    || die "skill missing the Optional Copilot pass section"
grep -qiE 'no answer|do not merge unattended|hold the merge|held for your' "$SKILL" \
    && pass "skill documents hold-on-no-answer" \
    || die "skill missing hold-on-no-answer"
grep -qiE 'clean Copilot signoff' "$SKILL" \
    && pass "skill documents merge-on-clean-Copilot-signoff" \
    || die "skill missing clean-Copilot-signoff gate"
grep -qiE 'every 10th Copilot round|10th Copilot round|10th round' "$SKILL" \
    && pass "skill documents the Copilot threshold pause" \
    || die "skill missing the Copilot threshold pause"
# The once-per-PR guard must be HEAD-AWARE (via the `status` subcommand) so a
# stale Copilot review on an older SHA cannot satisfy the merge gate.
grep -qE 'review-bus-copilot\.sh status' "$SKILL" \
    && pass "once-per-PR guard is head-aware (uses copilot status)" \
    || die "guard not head-aware — a stale Copilot review could satisfy the gate"
# The Copilot poll's status=error must be a documented fail-closed branch — an
# agent must not treat a failed findings/reviews fetch as a clean signoff.
grep -qiE 'status=error.*fail closed|fail closed.*status=error|status=error` \(rc 2\)' "$SKILL" \
    && pass "skill documents status=error as fail-closed (no false clean signoff)" \
    || die "skill missing the status=error fail-closed branch"
# The merge must recheck the head AFTER the Copilot pass (the step-8 head gate
# ran before the ask/poll, which can span a new push).
grep -qE 'MERGE_SHA' "$SKILL" \
    && pass "merge rechecks head after the Copilot pass (MERGE_SHA gate)" \
    || die "merge does not recheck head after the Copilot pass (TOCTOU)"
# The merge block must also confirm the head only advanced past the Codex-reviewed
# SHA via the loop's own fix(review): commits (no unreviewed change slipped in).
grep -qE 'non-fix\(review\)|rev-list --count' "$SKILL" \
    && pass "merge verifies head advanced only via fix(review) commits (Codex-vetted)" \
    || die "merge does not verify the REVIEWED_SHA..HEAD delta is Codex-vetted"
# The unresolved-thread gate must be RE-RUN inside the final merge block (the
# ask/poll window can open a new thread after step 8's check).
[ "$(grep -c 'reviewThreads(first:100, after:' "$SKILL")" -ge 2 ] \
    && pass "unresolved-thread gate re-run inside the merge block (post-Copilot)" \
    || die "unresolved-thread gate not re-run before the final merge (TOCTOU)"
# The required status-check gate must ALSO be re-run inside the final merge block.
[ "$(grep -c 'gh pr checks' "$SKILL")" -ge 2 ] \
    && pass "required-check gate re-run inside the merge block (post-Copilot)" \
    || die "required-check gate not re-run before the final merge (TOCTOU)"
# A transient `request` failure (REQ=2) must fail closed — never collapse into
# "unavailable → merge on Codex" and silently skip the opted-in Copilot pass.
grep -qE 'REQ=2' "$SKILL" \
    && pass "transient request failure (REQ=2) fails closed (no silent Copilot skip)" \
    || die "skill missing the REQ=2 fail-closed branch for a transient request failure"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
