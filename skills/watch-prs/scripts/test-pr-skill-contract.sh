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
# A fragment that fits on ONE line — the file is wrapped and `grep` is line
# oriented, so a phrase spanning a line break silently never matches. Fourth time.
grep -qi 'precede the push' "$SKILL" \
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
    readme_order=$(awk '/check the round/{if(!b)b=NR} /push and post/{if(!p)p=NR} END{print (b && p && b<p) ? "ok" : "bad"}' "$README")
    [ "$readme_order" = "ok" ] \
        && pass "README checks the round boundary before the push" \
        || die "README still tells users to push before the boundary check"
    # …and it must carry BOTH orderings, since the push is the trigger with
    # automatic review on. One round after the skill was fixed the README still
    # described only the auto-review-off flow.
    grep -q 'With automatic review on' "$README" \
        && pass "README describes the auto-review ordering too" \
        || die "README documents only one review mode; the other starts a pass with no summary"
else
    pass "README not present; flow-order check skipped"
fi

# A failed Copilot request must not start the phase: --add-reviewer IS the
# request, so a failure means there is no pass to wait for.
grep -q 'if ! gh pr edit N --repo $HOST/$OWNER/$REPO --add-reviewer @copilot; then' "$SKILL" \
    && pass "the Copilot request is branched on before the phase begins" \
    || die "a failed Copilot request still enters the Copilot phase"
# The @codex comment IS the request, so the same rule applies to it.
grep -q 'if ! gh pr comment N --repo $HOST/$OWNER/$REPO --body "@codex review' "$SKILL" \
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
grep -q 'merge N --repo \$HOST/\$OWNER/\$REPO --squash --delete-branch \$ADMIN' "$SKILL" \
    && pass "…and the merge command uses the selected mode" \
    || die "the merge command does not use \$ADMIN"

# ── pagination must terminate ──────────────────────────────────────────────
# A page reporting hasNextPage=true with a cursor already used makes the gate
# walk that cycle forever. A hang is worse than a blocked merge: nothing times
# out and the operator waits on a gate that never answers.
#
# EVERY cursor, not just the previous one: comparing against the last cursor
# caught an immediate self-loop but not `null → A → B → A → B …`.
grep -q 'SEEN="\$SEEN\$NEXT\$RS"' "$SKILL" \
    && pass "the merge gate records every pagination cursor it has requested" \
    || die "a cursor cycle would loop the merge gate forever"
grep -q 'case "\$SEEN" in \*"\$RS\$NEXT\$RS"\*) OK=0; break ;; esac' "$SKILL" \
    && pass "…and stops when one repeats" \
    || die "the merge gate does not check the cursor against the ones it has used"

# ── the Copilot summary is posted BEFORE the request ───────────────────────
# In the Codex phase the mention carries the summary, so the order is settled by
# construction. Here it is not: --add-reviewer is a separate call and Copilot can
# start reading within seconds, so requesting first means a fast pass reviews
# against the PREVIOUS round's summary.
awk '/gh pr comment N --repo \$HOST\/\$OWNER\/\$REPO --body "\$SUMMARY"/ {c=NR}
     /--add-reviewer @copilot/ {if (c && c < NR) {print "ok"; exit}}' "$SKILL" | grep -q ok \
    && pass "the Copilot round summary is posted before the review request" \
    || die "Copilot can be requested before the round summary exists"
grep -q 'ABORT: could not post the round summary — do not request Copilot yet' "$SKILL" \
    && pass "…and a failed summary post stops the phase" \
    || die "a failed Copilot-phase summary post does not stop the request"

# ── the self-check runs BEFORE the push ────────────────────────────────────
# Rounds are the expensive part of the loop, so a finding a script can make in a
# second must not cost a whole review pass.
grep -q 'pr-selfcheck.sh' "$SKILL" \
    && pass "the contract runs the self-check" \
    || die "nothing runs pr-selfcheck.sh before a round is pushed"
# The ORDER IN THE NUMBERED PROCEDURE, not merely the order of the two lines in
# the file. The previous version matched a self-check line appearing anywhere
# before any later `git push` code block, which stayed true while the checklist
# told the driver to push in step 2 and self-check in step 3 — so a driver
# following the sequence pushed before running the check meant to prevent it.
self_step="$(grep -nE '^[0-9]+\. \*\*run the self-check' "$SKILL" | head -1 | cut -d: -f1)"
push_step="$(grep -nE '^[0-9]+\. \*\*check the round boundary' "$SKILL" | head -1 | cut -d: -f1)"
{ [ -n "$self_step" ] && [ -n "$push_step" ] && [ "$self_step" -lt "$push_step" ]; } \
    && pass "…and the numbered procedure runs it before the step that pushes" \
    || die "the checklist pushes before the self-check that is meant to prevent it"
grep -q 'SELF_RC' "$SKILL" \
    && pass "…and its exit status is branched on" \
    || die "the self-check output is not checked"

# ── the first request respects the review mode too ─────────────────────────
# With auto-review on, opening or pushing the PR has already queued a pass, so an
# unconditional mention queues a SECOND review of the same head.
sel="$(grep -n 'AUTO_REVIEW=no' "$SKILL" | head -1 | cut -d: -f1)"
req="$(grep -n 'Request the review — Codex first' "$SKILL" | head -1 | cut -d: -f1)"
{ [ -n "$sel" ] && [ -n "$req" ] && [ "$sel" -gt "$req" ]; } \
    && pass "the review mode is established in the request step, before the mention" \
    || die "the first @codex mention is posted before the review mode is known"
grep -q 'if \[ "\$AUTO_REVIEW" = "yes" \]; then' "$SKILL" \
    && pass "…and the initial request branches on it" \
    || die "the initial request does not branch on the review mode"

# ── the numbered checklist does not push ──────────────────────────────────
# The push belongs to the mode-specific recipe: with auto-review on it must come
# after the threads are resolved and the summary posted, or the pass it triggers
# reads the previous round's account against threads that are still open.
grep -qE '^3\. \*\*check the round boundary — step 6\.\*\*' "$SKILL" \
    && pass "the boundary step no longer carries the push" \
    || die "the checklist still pushes in the boundary step"
grep -q 'The push is not' "$SKILL" \
    && pass "…and says where the push actually belongs" \
    || die "the checklist does not say where the push belongs"

# In the auto-review branch, the push must come AFTER the summary post.
awk '/^\*\*Automatic review ON\*\*/ {inb=1}
     inb && /gh pr comment N --repo \$HOST\/\$OWNER\/\$REPO --body "\$SUMMARY"/ {c=NR}
     inb && /^git push/ {if (c && c < NR) {print "ok"; exit}}' "$SKILL" | grep -q ok \
    && pass "with auto-review on, the summary is posted before the push that triggers the pass" \
    || die "the auto-review recipe pushes before the summary exists"

# ── the self-check's third outcome is handled ─────────────────────────────
# `not_applicable` shares no exit status with "checks passed": the same code
# would have let the driver report a clean check when none ran.
grep -q 'not applicable\*\*: this repository is not a' "$SKILL" \
    && pass "the contract documents the not-applicable outcome" \
    || die "SKILL.md defines no handling for a run where nothing was in scope"

# ── findings get a reaction ────────────────────────────────────────────────
# Every Codex finding ends with "Useful? React with thumbs", and that reaction is
# the only signal the reviewer gets about whether a review was worth making.
grep -q 'pulls/comments/<comment-id>/reactions' "$SKILL" \
    && pass "the contract reacts to each finding" \
    || die "findings are resolved without the reaction the reviewer asks for"
grep -q 'comment=' "$ROOT/skills/watch-prs/scripts/pr-findings.sh" \
    && pass "…and list prints the comment id the reaction needs" \
    || die "pr-findings.sh does not print a comment id to react to"

# ── the summary is read with its status taken, on every path ──────────────
# `$(cat …)` inside the argument swallows the reader's status, so a partial read
# still produced a successful post — and the reviewer contract makes the newest
# summary the thing read before the diff, so a truncated one looks complete.
[ "$(grep -c 'SUMMARY="$(cat "$SUMMARY_FILE")"' "$SKILL")" -eq 3 ] \
    && pass "all three summary posts read the file with a guarded status" \
    || die "a summary post still interpolates \$(cat …) and swallows its status"
grep -q 'ABORT: could not read the round summary' "$SKILL" \
    && pass "…and a failed read aborts rather than posting a truncated record" \
    || die "a failed summary read does not abort"

# ── a failed push does not close the round ────────────────────────────────
# The fixes are not on the PR, so resolving threads and requesting a review sends
# the reviewer at code that was never sent — and in auto-review mode the watch
# then reads the already-reviewed remote head's verdict as this round's.
[ "$(grep -c '^git push ||' "$SKILL")" -eq 2 ] \
    && pass "both mode-specific pushes are branched on" \
    || die "a round push is unchecked; a failed push still closes the round"
grep -q 'ABORT: push failed' "$SKILL" \
    && pass "…and a failed push aborts the round" \
    || die "a failed push does not abort"

# ── a timeout re-arms; it never re-requests and never asks ────────────────
# Re-requesting queues a duplicate pass on the same head, and asking turns the
# automatic loop back into the manual one it replaces.
grep -q 're-arm the same watch' "$SKILL" \
    && pass "a watch timeout re-arms the same watch" \
    || die "the timeout action is ambiguous; it may re-request or prompt"
grep -q 'timed out | re-request, or ask the operator' "$SKILL" \
    && die "the timeout row still offers re-requesting or prompting" \
    || pass "…and neither re-requests nor prompts"

# ── the helper discovery is checked and its result validated ──────────────
# `ls` can print one candidate and then fail on an unreadable cache entry, and
# `head` masks that status — so an unchecked pipeline selects a partial or stale
# path and every later call runs a different version of the helpers.
grep -q 'ABORT: could not enumerate installed plugin copies' "$SKILL" \
    && pass "the cached-helper discovery branches on its status" \
    || die "the helper discovery pipeline is unchecked"
grep -q 'ABORT: could not locate the plugin helper scripts' "$SKILL" \
    && pass "…and the selected directory is validated before it is used" \
    || die "the discovered helper directory is used without validation"

# ── every gh pr call names the repository ─────────────────────────────────
# `GH_REPO` overrides the repository `gh` infers from the checkout, so an
# unpinned call can act on the same-numbered PR somewhere else while every gate
# inspects this one. Enforced mechanically by pr-selfcheck.sh; asserted here so
# the contract itself cannot drift.
# A COMPARISON, not a magic number: the count changes whenever a call is added,
# and a fixed expectation fails for that reason rather than for an unpinned call.
comment_calls="$(grep -c 'gh pr comment N' "$SKILL")"
comment_pinned="$(grep -c 'gh pr comment N --repo $HOST/$OWNER/$REPO' "$SKILL")"
[ "$comment_calls" -eq "$comment_pinned" ] \
    && pass "every gh pr comment call is pinned to the derived repository" \
    || die "$((comment_calls - comment_pinned)) gh pr comment call(s) do not pass --repo"

# ── the shipping manifest lists every runtime helper ──────────────────────
# CLAUDE.md calls everything unlisted "documentation", so an incomplete table is
# not a cosmetic gap — it tells a maintainer that four executable helpers are
# prose. Derived from the directory, so adding a helper without listing it fails.
CLAUDEMD="$ROOT/CLAUDE.md"
if [ -f "$CLAUDEMD" ]; then
    # Scoped to the What-ships TABLE, not the whole file. Every helper is also
    # named in the strict-mode table further down, so a whole-file grep passed
    # against a manifest with a helper deleted — the same "the token appears
    # elsewhere" trap that made an earlier assertion here vacuous.
    manifest="$(awk '/^## What ships/{inb=1; next} /^## /{inb=0} inb' "$CLAUDEMD")"
    manifest_missing=""
    for h in "$SCRIPT_DIR"/pr-*.sh; do
        [ -e "$h" ] || continue
        b="$(basename "$h")"
        printf '%s' "$manifest" | grep -q "$b" || manifest_missing="$manifest_missing $b"
    done
    [ -z "$manifest_missing" ] \
        && pass "CLAUDE.md's What-ships table lists every runtime helper" \
        || die "runtime helpers missing from the shipping manifest:$manifest_missing"
fi

# ── every git probe takes its status ──────────────────────────────────────
# Third time this class appeared: the origin lookups, then the self-check's root
# lookup, then these two. `|| true` on a probe is the opposite of failing closed.
grep -q 'ABORT: could not resolve the repository root' "$SKILL" \
    && pass "the identity block branches on the repo-root probe" \
    || die "the repo-root probe is unchecked; a failed read becomes the merge tree"
if [ -f "$SCRIPT_DIR/pr-merge-range.sh" ]; then
    grep -q 'rev-parse --show-toplevel 2>/dev/null || true' "$SCRIPT_DIR/pr-merge-range.sh" \
        && die "pr-merge-range.sh still swallows its root probe status with || true" \
        || pass "pr-merge-range.sh does not swallow its root probe status"
fi

# ── the phase summary WRITE is checked, not only the read ─────────────────
# A truncated write leaves a non-empty partial body that the guarded read
# returns; a failed open leaves the previous round's contents to be read as this
# round's. Either posts an invalid summary and requests Copilot against it.
grep -q 'ABORT: could not write the phase summary' "$SKILL" \
    && pass "the Copilot phase summary write is branched on" \
    || die "the phase summary is written without checking the write"

# ── the summary file's creation is checked ────────────────────────────────
# `mktemp` can print a plausible path and then fail, and every later write and
# guarded read would then point at an existing file — a stale summary read back
# as this round's, which is what the guarded read was added to prevent.
grep -q 'ABORT: could not create the round-summary file' "$SKILL" \
    && pass "the summary file's creation is branched on" \
    || die "mktemp is unchecked; a failed create still yields a path"
grep -q 'ABORT: the round-summary file was not created empty' "$SKILL" \
    && pass "…and the created file is validated as new and empty" \
    || die "the summary file is used without validating what was created"

# ── the watch deadline is absolute ────────────────────────────────────────
# Accumulating only the sleeps excluded the time spent inside the probes, so slow
# GitHub reads made a one-hour watch run far past an hour.
if [ -f "$SCRIPT_DIR/pr-watch.sh" ]; then
    grep -q 'elapsed_s()' "$SCRIPT_DIR/pr-watch.sh" \
        && pass "pr-watch.sh measures elapsed time against the clock" \
        || die "pr-watch.sh accumulates sleeps, so probe time escapes --timeout"
    grep -q 'waited=\$((waited + nap))' "$SCRIPT_DIR/pr-watch.sh" \
        && die "pr-watch.sh still accumulates the nap instead of reading the clock" \
        || pass "…rather than accumulating the naps"
fi

# ── the Codex signoff is re-validated on the sha it records ───────────────
# A push between the clean verdict and this lookup recorded the new, unreviewed
# head as the signoff, and the gate only noticed after the whole Copilot phase.
grep -q 'CODEX_RECHECK' "$SKILL" \
    && pass "the recorded Codex sha is re-validated before the Copilot phase" \
    || die "CODEX_SHA is recorded without confirming Codex is clean on it"

# ── every gh call names the host as well as the repository ────────────────
# `GH_HOST` supplies the hostname when a command gives none, so an unpinned call
# can act on the same-numbered PR on another GitHub host.
grep -q 'HOST=' "$SKILL" \
    && pass "the host is derived from origin" \
    || die "the host is not derived; GH_HOST can redirect every call"
grep -q 'gh api --hostname "\$HOST" graphql' "$SKILL" \
    && pass "…and the GraphQL calls pass it explicitly" \
    || die "a graphql call does not pass --hostname"

# ── the accepted merge-mode limitation is recorded on the base ref ────────
# AGENTS.md makes a dated decision record the only thing that can accept a
# limitation; a comment in the diff cannot.
if [ -d "$ROOT/docs/decisions" ]; then
    grep -rql 'REVIEW_MERGE_STRICT' "$ROOT/docs/decisions" >/dev/null 2>&1 \
        && pass "the merge-mode trade-off has a decision record" \
        || die "the --admin default is accepted nowhere a reviewer can weigh it"
else
    die "docs/decisions/ is missing; accepted limitations have nowhere to live"
fi

# ── the re-request id is captured and passed, not merely available ────────
# A flag nothing invokes is inert: `--after-review` shipped and the driver never
# called `review-id` nor passed the option, so a same-head re-request still
# accepted the previous terminal review immediately.
grep -q 'pr-watch.sh N "$WHO" --after-review "$PRIOR_REVIEW"' "$SKILL" \
    && pass "the watch is invoked with the pre-request review id" \
    || die "--after-review is documented but never passed"
[ "$(grep -c 'PRIOR_REVIEW=\$("\$RB_SCRIPTS"/pr-review-state.sh review-id' "$SKILL")" -ge 3 ] \
    && pass "…and the id is captured before each request that a watch follows" \
    || die "the pre-request review id is not captured before every request"

# ── "no required checks" is not "could not tell" ──────────────────────────
# `gh pr checks --required` exits NON-ZERO when the branch has no required checks
# at all. Treating every non-zero status as unreadable blocked the merge on every
# repository without branch protection, permanently — a gate that never opens,
# not a fail-closed guard. Found by trying to merge, not by reading the code.
grep -q 'no required checks' "$SKILL" \
    && pass "the gate distinguishes 'none configured' from a failed probe" \
    || die "a repo with no required checks can never pass the merge gate"
grep -q 'the required-checks probe failed' "$SKILL" \
    && pass "…and a genuinely failed probe still blocks" \
    || die "the checks probe no longer blocks on a real failure"
grep -q 'CHECKS_ERR' "$SKILL" \
    && pass "…using stderr, so the message does not pollute the compared value" \
    || die "the checks probe does not capture stderr separately"

# ── a clean pass arrives as a comment, not a review ───────────────────────
# Codex submits a review only when it has findings, so `pulls/N/reviews` is empty
# on a clean head and the phase could never complete.
if [ -f "$SCRIPT_DIR/pr-review-state.sh" ]; then
    grep -q 'clean_comment_for_head' "$SCRIPT_DIR/pr-review-state.sh" \
        && pass "pr-review-state.sh reads the clean-pass comment channel" \
        || die "a clean Codex pass is invisible; the phase cannot complete"
    grep -q 'Reviewed commit:' "$SCRIPT_DIR/pr-review-state.sh" \
        && pass "…bound to the head the comment names" \
        || die "the clean comment is not bound to a commit"
fi

# ── the boundary gates the phase transitions, not only the re-request ─────
# A phase ending on the threshold-th head went from a clean verdict straight into
# the next phase — skipping the pause in exactly the case it exists for.
[ "$(grep -c 'pr-round-count.sh N' "$SKILL")" -ge 3 ] \
    && pass "the round boundary is checked before the phase transition and the merge" \
    || die "a clean verdict on the boundary skips the operator pause"
grep -q 'before opening the Copilot phase' "$SKILL" \
    && pass "…including before the Copilot phase" \
    || die "the Copilot transition does not check the boundary"
grep -q 'before merging' "$SKILL" \
    && pass "…and before merging" \
    || die "the merge does not check the boundary"

# ── EVERY documented watch invocation carries the baseline ────────────────
# The shell example passed --after-review while the Monitor command beside it did
# not, leaving the feature inert in the mode Claude Code is told to use.
watch_calls="$(grep -c 'pr-watch.sh N "\$WHO"' "$SKILL")"
watch_pinned="$(grep -c 'pr-watch.sh N "\$WHO" --after-review "\$PRIOR_REVIEW"' "$SKILL")"
[ "$watch_calls" -eq "$watch_pinned" ] \
    && pass "every documented watch invocation passes the review baseline" \
    || die "$((watch_calls - watch_pinned)) watch invocation(s) omit --after-review"

# ── the automatic path has no pre-request baseline ────────────────────────
# The trigger preceded the skill, so a lookup can capture the very pass being
# waited for — and the watch would reject the only terminal review as stale.
grep -q 'PRIOR_REVIEW=""' "$SKILL" \
    && pass "the automatic-review path waits on any terminal review" \
    || die "the automatic path captures the in-flight pass as its own baseline"

# ── the checks diagnostic is read with its status ─────────────────────────
# A `cat` that emitted text containing "no required checks" and then failed would
# be classified as the benign none-configured case, letting the default admin
# merge proceed with no trusted checks result at all.
grep -q 'CHECKS_MSG_RC' "$SKILL" \
    && pass "the checks diagnostic read takes its own status" \
    || die "a failed diagnostic read can be classified as 'no required checks'"
grep -q 'could not read the checks diagnostic' "$SKILL" \
    && pass "…and blocks the merge when it fails" \
    || die "a failed diagnostic read does not block"

# ── an unchanged head in automatic mode still gets a trigger ──────────────
# A round that ends without a new commit — a dismissal, or a finding answered
# rather than coded around — leaves the push a no-op, so nothing is queued and
# `--after-review` rejects the old record forever.
grep -q 'PRIOR_HEAD' "$SKILL" \
    && pass "the round records the head it started from" \
    || die "automatic mode cannot tell a real push from a no-op one"
# The CONDITION, not just the variable. Asserting the name alone survived
# rewriting the test to `if false`, which is the whole behaviour.
grep -q '\[ "\$HEAD_BEFORE" = "\$HEAD_AFTER" \] && \[ "\$PRIOR_HEAD" = "\$HEAD_AFTER" \]' "$SKILL" \
    && pass "…and compares it against the head after the push" \
    || die "the unchanged-head branch does not actually compare the heads"
grep -q 'could not request a review for an unchanged head' "$SKILL" \
    && pass "…and asks explicitly when the push moved nothing" \
    || die "an unchanged head in automatic mode queues no review at all"

# ── the reviewers review; they do not implement ────────────────────────────
# Ignoring this is not a no-op: a summary mentioning an unfixed defect was read
# as a work order, and the run edited files and committed from an environment
# with no remote — so the commit existed nowhere and no review was produced.
for f in "$ROOT/AGENTS.md" "$ROOT/.github/copilot-instructions.md"; do
    [ -f "$f" ] || continue
    grep -qi 'You do not implement' "$f" \
        && pass "$(basename "$f") states that the reviewer never writes code" \
        || die "$(basename "$f") does not forbid the reviewer from implementing"
done

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
