#!/usr/bin/env bash
# Doc-regression for the v2 driver contract.
#
# Every assertion here exists because the contract and the behaviour drifted
# apart at least once in v1: a documented command that could not run, a merge
# that was not pinned to the head its gates checked, a "cannot tell" the driver
# was never told to stop on.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$SCRIPT_DIR/../SKILL.md"
ROOT="$SCRIPT_DIR/../../.."

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

if [ ! -f "$SKILL" ]; then
    echo "ok   - skill not present in this checkout; contract checks skipped"
    echo "RESULT: PASS"
    exit 0
fi

# ── the reviewers are the GitHub apps, not a local process ─────────────────
grep -q 'chatgpt-codex-connector\[bot\]' "$SKILL" \
    && pass "skill names the Codex bot login" \
    || die "skill does not name chatgpt-codex-connector[bot]"
grep -q 'copilot-pull-request-reviewer\[bot\]' "$SKILL" \
    && pass "skill names the Copilot bot login" \
    || die "skill does not name copilot-pull-request-reviewer[bot]"
grep -q '@codex review' "$SKILL" \
    && pass "skill documents the @codex mention as the Codex trigger" \
    || die "skill does not document the @codex trigger"
grep -q 'add-reviewer @copilot' "$SKILL" \
    && pass "skill documents the Copilot review request" \
    || die "skill does not document requesting Copilot"

# v1's daemons must not come back by reference: a contract that still tells the
# driver to start a watcher would leave it waiting for a bus that no longer
# exists.
for gone in review-bus-codex-start review-bus-codex-watcher review-bus-response-monitor \
            review-bus-request review-bus-close-round 'systemd --user'; do
    grep -q -- "$gone" "$SKILL" \
        && die "skill still references the removed v1 machinery: $gone" \
        || pass "no reference to removed machinery ($gone)"
done

# ── the connector prerequisite is stated ───────────────────────────────────
# Without it @codex answers with a setup link, which is easy to misread as a
# review that found nothing.
grep -qi 'connect' "$SKILL" && grep -q 'connectors' "$SKILL" \
    && pass "skill states the one-time connector prerequisite" \
    || die "skill does not tell the operator to link the Codex connector"

# ── every 'cannot tell' is a stop ──────────────────────────────────────────
grep -qi 'fail closed' "$SKILL" \
    && pass "skill states the fail-closed rule" \
    || die "skill does not state that an unreadable state fails closed"
grep -q 'pr-review-state.sh' "$SKILL" \
    && pass "skill drives pr-review-state.sh" \
    || die "skill does not use pr-review-state.sh"
grep -q 'pr-merge-range.sh' "$SKILL" \
    && pass "skill drives pr-merge-range.sh" \
    || die "skill does not use pr-merge-range.sh"
# The round check-in must have an implementation, not just a promise: v1's
# guarantee lived in a /tmp counter that vanished with the file.
grep -q 'pr-round-count.sh' "$SKILL" \
    && pass "the round check-in is enforced by a script, not only described" \
    || die "skill promises a round check-in with nothing implementing it"

# ── the merge gate resolves the head ONCE and pins every check to it ───────
# Letting each verdict resolve the head itself lets a push land between them, so
# both verdicts describe an older commit while the merge pins the newer one.
grep -qE 'verdict N "\$CODEX_BOT" +"\$HEAD_OID"' "$SKILL" \
    && pass "reviewer verdicts are pinned to the resolved head" \
    || die "verdict calls do not take an explicit \$HEAD_OID"
grep -q 'HEAD_RC' "$SKILL" \
    && pass "the head lookup checks its exit status" \
    || die "the head lookup does not branch on its own status"
grep -q 'CHECKS_RC' "$SKILL" \
    && pass "the required-checks probe checks its exit status" \
    || die "the required-checks probe compares output without its status"

# ── portability: no GNU-only tools on the path that must work on macOS ─────
# Comment lines are excluded on purpose: the skill EXPLAINS why `sort -V` is not
# used, and matching that explanation would make the assertion unfalsifiable.
if grep -vE '^[[:space:]]*#' "$SKILL" | grep -q 'sort -V'; then
    die "skill uses GNU-only 'sort -V' while README advertises portability"
else
    pass "no GNU-only sort in the script-resolution fallback"
fi

# ── the merge is pinned to the head the gates were evaluated against ───────
grep -qE -- '--match-head-commit "\$HEAD_OID"' "$SKILL" \
    && pass "merge is pinned to the gated head" \
    || die "merge is not pinned with --match-head-commit \"\$HEAD_OID\""
grep -qE '^[[:space:]]*if gh pr merge' "$SKILL" \
    && pass "the merge result is branched on" \
    || die "the merge result is not branched on"

# ── both reviewers gate the merge ──────────────────────────────────────────
grep -q 'CODEX_RC' "$SKILL" && grep -q 'COPILOT_RC' "$SKILL" \
    && pass "the merge gate consults BOTH reviewers" \
    || die "the merge gate does not consult both reviewers"

# ── thread pagination ──────────────────────────────────────────────────────
# A truncated thread list reads exactly like a shorter review, so the contract
# has to say so in both places it fetches threads.
[ "$(grep -c 'hasNextPage' "$SKILL")" -ge 2 ] \
    && pass "thread fetches are paginated in both places" \
    || die "a thread fetch is not paginated"

# ── the instruction files carry the scope + issue policy ───────────────────
# These are what reach the reviewers; the loop depends on them, so a missing
# clause is a behaviour change, not a doc nit.
for doc in "$ROOT/AGENTS.md" "$ROOT/.github/copilot-instructions.md"; do
    name="$(basename "$(dirname "$doc")")/$(basename "$doc")"
    [ -f "$doc" ] || { die "$name is missing"; continue; }
    grep -qi 'set out to do' "$doc" \
        && pass "$name: reviewers judge the PR against its stated goal" \
        || die "$name: no scope rule"
    grep -qi 'untrusted context' "$doc" \
        && pass "$name: PR narrative is untrusted" \
        || die "$name: does not mark the PR narrative untrusted"
    grep -qi 'issue' "$doc" \
        && pass "$name: out-of-scope problems can be filed as issues" \
        || die "$name: no issue-filing route for out-of-scope problems"
    grep -qi 'review body' "$doc" \
        && pass "$name: names the non-blocking channel" \
        || die "$name: does not name the review body as the non-blocking channel"
    grep -qi 'fail-closed\|fail closed' "$doc" \
        && pass "$name: fail-closed is a review criterion" \
        || die "$name: does not state the fail-closed criterion"
    grep -qi 'base ref\|base-ref' "$doc" \
        && pass "$name: only a base-ref authority waives a finding" \
        || die "$name: no waiver authority rule"
done

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
