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
# Each reviewer is checked on the head IT reviewed. Checking Codex on $HEAD_OID
# makes the gate unreachable in the Copilot phase: Codex is deliberately not
# re-run there, so its verdict on a Copilot-fix commit is `none` forever.
# Both obvious answers are wrong: always-$HEAD_OID makes the gate unreachable in
# the Copilot phase, always-$CODEX_SHA ignores a NEW Codex review that auto-review
# may have produced on the current head — and a body-only CHANGES_REQUESTED leaves
# no thread for the unresolved gate to catch.
grep -q 'state N "$CODEX_BOT" "$HEAD_OID"' "$SKILL" \
    && pass "the gate asks whether Codex has judged the CURRENT head" \
    || die "the gate never checks for a newer Codex review on the current head"
grep -qE 'verdict N "\$CODEX_BOT" +"\$CODEX_SHA"' "$SKILL" \
    && pass "…and falls back to the recorded signoff when it has not" \
    || die "there is no fallback to \$CODEX_SHA — the gate cannot pass after a Copilot fix"
grep -qE 'verdict N "\$CODEX_BOT" +"\$HEAD_OID"' "$SKILL" \
    && pass "…and a current-head Codex judgement wins over the older one" \
    || die "a newer Codex review on the current head is never honoured"
grep -q 'CODEX_STATE_RC' "$SKILL" \
    && pass "an unreadable Codex head-state blocks the merge" \
    || die "the current-head state probe's status is not acted on"
grep -qE 'verdict N "\$COPILOT_BOT" +"\$HEAD_OID"' "$SKILL" \
    && pass "Copilot is validated on the current head" \
    || die "Copilot's verdict is not pinned to \$HEAD_OID"
# …and the range check is what makes trusting an older Codex signoff safe.
# The range must measure from the sha the VERDICT describes. Keyed to the stale
# recorded sha, it demands Copilot trailers across a range Codex has already
# reviewed in full — blocking a merge both reviewers just approved.
grep -qE 'pr-merge-range.sh "\$CODEX_EFFECTIVE_SHA" "\$HEAD_OID"' "$SKILL" \
    && pass "the range check measures from the sha Codex's verdict describes" \
    || die "the range check is keyed to \$CODEX_SHA even when Codex reviewed the head"
[ "$(grep -c 'CODEX_EFFECTIVE_SHA=' "$SKILL")" -ge 2 ] \
    && pass "the effective Codex sha is set on BOTH branches" \
    || die "the effective Codex sha is not set on every branch"
grep -q 'CODEX_SHA" =~ \^\[0-9a-f\]{40}\$' "$SKILL" \
    && pass "the Codex signoff SHA is shape-checked before it is trusted" \
    || die "CODEX_SHA is used without validating its shape"
grep -q 'HEAD_RC' "$SKILL" \
    && pass "the head lookup checks its exit status" \
    || die "the head lookup does not branch on its own status"
grep -q 'CHECKS_RC' "$SKILL" \
    && pass "the required-checks probe checks its exit status" \
    || die "the required-checks probe compares output without its status"

# ── the loop is PHASED: Codex to clean, then Copilot ───────────────────────
# Asking both every round buys a Copilot pass on every intermediate commit and
# mixes its findings into a round that was not about them.
grep -q 'Request the review — Codex first' "$SKILL" \
    && pass "the request step asks Codex first" \
    || die "the request step does not establish the Codex-first phase"
grep -qi 'do \*\*not\*\* request copilot yet' "$SKILL" \
    && pass "Copilot is explicitly deferred out of the Codex phase" \
    || die "nothing stops the driver requesting Copilot in the Codex phase"
grep -q 'Codex is clean — now the Copilot phase' "$SKILL" \
    && pass "there is a distinct Copilot phase, entered on a clean Codex verdict" \
    || die "no Copilot phase — the loop cannot be Codex-first without one"
grep -qi 'Re-request \*\*only the active reviewer\*\*' "$SKILL" \
    && pass "the close-round step re-requests only the active reviewer" \
    || die "the close-round step may re-request both reviewers"
grep -qi 'Codex is not re-requested during this phase' "$SKILL" \
    && pass "Codex is not re-run during the Copilot phase" \
    || die "the Copilot phase does not say Codex stays out of it"
# The round counter must be per-reviewer, or a shared count trips a pause neither
# phase reached.
grep -q 'pr-round-count.sh N "\$WHO"' "$SKILL" \
    && pass "rounds are counted for the ACTIVE reviewer" \
    || die "the round count is not scoped to the active reviewer"
# `$WHO` must be a variable throughout, so the Copilot phase gets the same
# treatment rather than leaving a hole for whichever login was hard-coded.
grep -q 'WHO="\$CODEX_BOT"' "$SKILL" && grep -q 'WHO="\$COPILOT_BOT"' "$SKILL" \
    && pass "the active reviewer is a variable, set per phase" \
    || die "the active reviewer is not parameterised across phases"
# The findings read is a SCRIPT, not a snippet. Three rounds of fail-open bugs
# lived in the inline version because no test executed it.
# The verdict must arrive by itself. v2 removed v1's response monitor along with
# the bus; without a replacement the driver hand-polls, which is what the operator
# noticed.
grep -q 'pr-watch.sh' "$SKILL" \
    && pass "the wait is delegated to pr-watch.sh, not hand-polled" \
    || die "nothing surfaces a finished review — the driver would poll by hand"
grep -qi 'Monitor' "$SKILL" \
    && pass "Claude Code is told to run the watch as a Monitor" \
    || die "the skill does not say how to surface the verdict automatically"
grep -q 'WATCH_RC' "$SKILL" \
    && pass "the driver branches on the watch's status" \
    || die "the watch's exit status is not acted on"

grep -q 'pr-findings.sh list' "$SKILL" \
    && pass "the findings read is delegated to a tested script" \
    || die "the findings read is inline again — no test can execute it"
grep -q 'pr-findings.sh blocked-body' "$SKILL" \
    && pass "the blocked-review body is delegated to the same script" \
    || die "the blocked-body fetch is inline again"
grep -q 'FIND_RC=\$?' "$SKILL" \
    && pass "the driver captures the findings read's status" \
    || die "the findings read's status is not captured"
# The blocked-body read needs the same contract: it is the ONLY path that can
# surface a body-only request, so an unreadable one must not read as "no body".
# The ASSIGNMENT, not the prose: the paragraph below the command also names
# BODY_RC, so a bare grep for the word passes even when the status is not
# captured at all.
grep -q 'BODY_RC=\$?' "$SKILL" \
    && pass "the driver captures the blocked-body read's status" \
    || die "the blocked-body read's status is not captured"

# The round boundary must be checked BEFORE the re-request, or the next review is
# already sent by the time the operator is asked.
# Matched on the ordering STATEMENT rather than on the two commands' line
# numbers: the checklist item wraps, so a line-order test silently never matched
# and reported failure regardless of the text.
{ grep -q 'check the round boundary' "$SKILL" && grep -q 'only then' "$SKILL"; } \
    && pass "the close-round checklist checks the boundary before re-requesting" \
    || die "the checklist does not order the boundary check before the re-request"
grep -qi 'past the boundary the check-in exists to stop at' "$SKILL" \
    && pass "and says why that order matters" \
    || die "the ordering is stated without its reason"

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
    grep -qi 'hard-code' "$doc" \
        && pass "$name: the repo-agnostic invariant is a blocking finding" \
        || die "$name: does not tell the reviewer to block a hard-coded identity"
    grep -qi 'base ref\|base-ref' "$doc" \
        && pass "$name: only a base-ref authority waives a finding" \
        || die "$name: no waiver authority rule"
    # A reviewer that installs dependencies and runs the suite turns a
    # three-minute read into a twenty-minute one, and the author is blocked on it
    # either way. The instruction files are the only lever on that.
    grep -qi 'do not set up an environment' "$doc" \
        && pass "$name: the review is read-only (no env setup, no test runs)" \
        || die "$name: does not tell the reviewer to review statically"
    grep -qi 'run the test suite' "$doc" \
        && pass "$name: running the suite is ruled out explicitly" \
        || die "$name: does not rule out running the tests"
done

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
