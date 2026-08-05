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
# ONLY rc 0 is an answer: this branch decides whether to fall back to the older
# signoff, so a bad read merges on a state that was never trusted.
grep -q 'CODEX_STATE_RC" -ne 0' "$SKILL" \
    && pass "any non-zero Codex head-state status blocks the merge" \
    || die "only the documented rc 2 blocks — a wrapper failure would fall through"
# CODEX_SHA has to be captured before the head moves; nothing else records it.
grep -q 'CODEX_SHA=$(gh pr view' "$SKILL" \
    && pass "the Codex-signed-off head is captured before the Copilot phase" \
    || die "CODEX_SHA is required by the gate but never assigned"
# With auto-review on, the PUSH requests the next review — so the boundary check
# has to precede it, not merely precede the explicit re-request.
grep -qi 'BEFORE pushing' "$SKILL" \
    && pass "the round boundary is checked before the push" \
    || die "the boundary check runs after the push, which auto-review has already acted on"
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
grep -qi 'push itself' "$SKILL" \
    && pass "and says why the order matters (auto-review acts on the push)" \
    || die "the ordering is stated without its reason"

# The README is the first thing a user reads, so v1's architecture must not
# survive in it: someone told about a "file-based bus" goes looking for daemons
# and bus state that this release deletes.
if [ -f "$ROOT/README.md" ]; then
    # Blockquotes are excluded: the "Upgrading from 1.x" note legitimately
    # describes what v1 WAS, and a blunt grep would forbid explaining the thing
    # this release removes.
    readme_now="$(grep -v '^[[:space:]]*>' "$ROOT/README.md")"
    for gone in 'file-based bus' 'systemd --user' 'response monitor'; do
        printf '%s' "$readme_now" | grep -qi -- "$gone" \
            && die "README still presents removed v1 machinery as current: $gone" \
            || pass "README does not present removed machinery as current ($gone)"
    done
fi

# The README carries the same flow for users who never open SKILL.md, so the
# ordering has to hold there too — it did not, one round after the skill was
# fixed.
README="$ROOT/README.md"
if [ -f "$README" ]; then
    # Matched on fragments that survive the line wrap: "check the round" and
    # "boundary" sit on different lines, and a phrase-spanning regex silently
    # never matches — which is how a line-order assertion reports failure
    # regardless of the text.
    readme_order=$(awk '/check the round/{b=NR} /then push/{p=NR} END{print (b && p && b<p) ? "ok" : "bad"}' "$README")
    [ "$readme_order" = "ok" ] \
        && pass "README checks the round boundary before the push" \
        || die "README still tells users to push before the boundary check"
else
    pass "README not present; flow-order check skipped"
fi

# A failed Copilot request must not start the phase: --add-reviewer IS the
# request, so a failure means there is no pass to wait for.
grep -q 'if ! gh pr edit N --repo $OWNER/$REPO --add-reviewer @copilot; then' "$SKILL" \
    && pass "the Copilot request is branched on before the phase begins" \
    || die "a failed Copilot request still enters the Copilot phase"
# The @codex comment IS the request, so the same rule applies to it.
grep -q 'if ! gh pr comment N --body "@codex review' "$SKILL" \
    && pass "the Codex request is branched on before the wait begins" \
    || die "a failed @codex request still enters the wait step"

# The merge gate validates the verdict RECORDS, not only the exit codes: this is
# the final permission, so an rc-swallowing wrapper must not read as clean.
grep -q 'V_WANT="PR_REVIEW_STATE pr=N sha=' "$SKILL" \
    && pass "the merge gate requires an exact clean verdict record from both reviewers" \
    || die "the merge gate trusts the exit codes without checking the records"
# …and each record must name ITS OWN reviewer and the sha that reviewer judged.
# Wildcarding pr/sha/reviewer let one clean line satisfy the check for either
# variable, so a clean Copilot record — or a clean record for a stale sha —
# passed as Codex's signoff.
grep -q 'reviewer=\$V_WHO verdict=clean findings=0"' "$SKILL" \
    && pass "each clean record is bound to the reviewer it is meant to prove" \
    || die "the merge gate accepts a clean record from any reviewer"
grep -q '"\$CODEX_BOT|\$CODEX_EFFECTIVE_SHA|\$CODEX_VERDICT"' "$SKILL" \
    && pass "…on the sha that reviewer actually judged" \
    || die "the clean records are not bound to the sha each reviewer judged"
# A literal comparison, not `[[ == ]]`: the bot logins end in `[bot]`, which a
# pattern context reads as a character class.
grep -q '\[ "\$V_LINE" != "\$V_WANT" \]' "$SKILL" \
    && pass "the verdict records are compared literally, not as patterns" \
    || die "the verdict comparison would read [bot] as a character class"

# ── the round summary and the review request are ONE comment ───────────────
# The mention IS the request, so splitting them divides the record the reviewer
# is told to read and sends the request half with no account of what changed.
grep -q 'SUMMARY_FILE' "$SKILL" \
    && pass "the round summary is posted in the same comment as the @codex request" \
    || die "the summary and the request are still two separate comments"

# A mention describing an UNFIXED defect is read as a task, not as context: Codex
# then edits and commits in an environment with no remote and no credentials, so
# the commit exists nowhere and the review never happens. This cost a whole round
# once already.
grep -qi 'never as a work order' "$SKILL" \
    && pass "the skill warns that an open defect in a mention is read as a task" \
    || die "nothing stops a round summary restating an unfixed defect to the reviewer"

# Resolving is checked, not assumed: a round reported as fully resolved when it
# was not sends the next review back over findings that were already answered.
#
# Matched on the rule's own words, not on `isResolved` — that token also appears
# in the merge gate's GraphQL query further down the file, so a grep for it
# passed against a SKILL.md with the rule deleted.
#
# A FRAGMENT that fits on one line, not the whole phrase: this file is wrapped,
# `grep` is line-oriented, and an assertion spanning a line break silently never
# matches. That has now happened three times in this suite.
grep -qi 'resolve succeeded' "$SKILL" \
    && pass "the skill says to verify each resolve succeeded" \
    || die "thread resolution is assumed rather than verified"

# The watch is armed as part of the round, not put to the operator as a question.
grep -qi 'do not ask' "$SKILL" \
    && pass "the watch is armed and re-armed without asking the operator" \
    || die "the skill leaves arming the watch as a question for the operator"

# ── the merge mode is a setting, not a hard-coded bypass ───────────────────
# `--admin` stays the default because branch protection normally requires an
# approving review from another account, and neither reviewer is one — dropping
# it would remove the solo maintainer's merge path rather than tighten the gate.
# But it must be reachable: strict mode is what closes the window between the
# last probe and the merge, where a review can change without the head moving.
grep -q 'REVIEW_MERGE_STRICT' "$SKILL" \
    && pass "the merge mode is selectable, not a hard-coded --admin" \
    || die "--admin is unconditional; there is no way to let GitHub enforce protection"
grep -q 'ADMIN=--admin' "$SKILL" \
    && pass "…defaulting to --admin so a protected solo repo can still merge" \
    || die "the default merge mode is not --admin"
grep -q 'merge N --repo \$OWNER/\$REPO --squash --delete-branch \$ADMIN' "$SKILL" \
    && pass "…and the merge command uses the selected mode" \
    || die "the merge command does not use \$ADMIN"

# ── pagination must terminate ──────────────────────────────────────────────
# A page reporting hasNextPage=true with the cursor it was asked for makes the
# gate request that identical page forever. A hang is worse than a blocked merge:
# nothing times out and the operator waits on a gate that never answers.
grep -q 'NEXT" != "\$CURSOR"' "$SKILL" \
    && pass "the merge gate stops when the pagination cursor does not advance" \
    || die "a repeated cursor would loop the merge gate forever"

# ── v2 ships to Claude Code only ───────────────────────────────────────────
# Both reviewers run in GitHub's cloud, so nothing is installed for them; the
# driver needs a watch tool, which is why there is one manifest and not two.
[ -e "$ROOT/.codex-plugin" ] \
    && die "the Codex plugin manifest is back; v2 ships to Claude Code only" \
    || pass "no Codex plugin manifest"
[ -e "$ROOT/.agents" ] \
    && die "the Codex marketplace metadata is back" \
    || pass "no Codex marketplace metadata"
if [ -f "$ROOT/README.md" ]; then
    grep -q 'codex plugin' "$ROOT/README.md" \
        && die "README still documents installing this plugin into Codex" \
        || pass "README does not document a Codex install"
fi

# A GraphQL 200 can carry both `errors` and structurally valid `data`. The
# unresolved-thread count answers 0 on partial data, and 0 is merge permission —
# taken with `--admin`, so nothing downstream catches the omitted thread.
grep -q 'has("errors") | not' "$SKILL" \
    && pass "the unresolved-thread gate refuses a response carrying GraphQL errors" \
    || die "a partial GraphQL response can still produce UNRESOLVED=0"

# The README must not advertise Copilot as optional while the gate requires it:
# a user would install for a repository without Copilot and find out at merge
# time that the loop cannot finish.
if [ -f "$SCRIPT_DIR/../../../README.md" ]; then
    README="$SCRIPT_DIR/../../../README.md"
    grep -qi 'if you want the second pass' "$README" \
        && die "README still presents Copilot as optional while the gate requires it" \
        || pass "README does not present Copilot as optional"
    grep -qi 'required, not' "$README" \
        && pass "README says plainly that Copilot is required" \
        || die "README does not state that Copilot is required"
fi

# The head-state line is parsed, not substring-matched.
grep -q 'CODEX_HEAD_STATE" =~ \^PR_REVIEW_STATE' "$SKILL" \
    && pass "the Codex head-state line is matched as a whole record" \
    || die "the head-state decision is made on a substring or trailing token"
# …and the record must be ABOUT the PR, reviewer and head that were asked for.
# A well-formed `state=none` for something else took the fallback path and merged
# on the recorded signoff while Codex had a current-head CHANGES_REQUESTED.
grep -q '"\$S_PR" != "N" \] || \[ "\$S_WHO" != "\$CODEX_BOT" \] || \[ "\$S_SHA" != "\${HEAD_OID:0:7}"' "$SKILL" \
    && pass "the head-state record is bound to the PR, reviewer and head requested" \
    || die "any well-formed state record satisfies the head-state check"
grep -q 'none|pending|reviewed|blocked|dismissed) ;;' "$SKILL" \
    && pass "…and validated against the known states" \
    || die "the parsed head-state is not checked against the known states"

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
