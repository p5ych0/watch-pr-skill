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
# The assertion is on the REQUEST BODY, not on the file appearing somewhere in the
# document. Matching `SUMMARY_FILE` anywhere passed while the round-closing
# request interpolated nothing: the file was still created and read, and Codex
# received a bare mention with no account of what changed — which the review
# policy makes it read first. The definition and the use are separate things, and
# only the use reaches the reviewer.
#
# The FIRST request is exempt and identified by its placeholder: it opens the PR,
# so there is no prior round to summarise. Every other one closes a round.
summary_req="$(awk '
    /--body "@codex review/ { want = 3; body = ""; next }
    want > 0 { body = body $0 "\n"; want--
               if (want == 0) {
                   if (body ~ /<one paragraph:/) { opening++ }
                   else if (body ~ /\$SUMMARY/) { withsum++ }
                   else { bare++ }
               }
             }
    END { printf "opening=%d withsum=%d bare=%d", opening, withsum, bare }
' "$SKILL")"; sreq_rc=$?
[ "$sreq_rc" -eq 0 ] || die "could not scan SKILL.md for the review requests (rc=$sreq_rc)"
case "$summary_req" in
    *"bare=0"*) pass "every round-closing @codex request carries \$SUMMARY in its body" ;;
    *) die "a round-closing @codex request has no summary in its body ($summary_req)" ;;
esac
case "$summary_req" in
    *"withsum=0"*) die "no @codex request interpolates the summary at all ($summary_req)" ;;
    *) pass "…and the summary reaches the reviewer in the same comment as the mention" ;;
esac

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

# ── the re-request depends on WHICH reviewer the round was about ──────────
# Copilot is never triggered by a push and never by an `@codex` mention — only by
# `--add-reviewer`. A Copilot fix round that posted the Codex mention requested
# nothing, and the watch waited past the old Copilot review indefinitely.
[ "$(grep -c 'if \[ "\$WHO" = "\$COPILOT_BOT" \]; then' "$SKILL")" -ge 2 ] \
    && pass "both round-closing paths branch on the reviewer" \
    || die "a round-closing request assumes Codex regardless of \$WHO"
grep -q 'could not re-request Copilot' "$SKILL" \
    && pass "…and a Copilot round re-requests through --add-reviewer" \
    || die "a Copilot round never re-requests Copilot"

# ── the fetched heads are validated, not merely fetched ───────────────────
# An rc-0 call yielding empty or `null` makes every unchanged-head comparison
# false, so automatic mode assumes the no-op push queued a review.
[ "$(grep -c 'PRIOR_HEAD" =~ \^\[0-9a-f\]{40}\$' "$SKILL")" -ge 2 ] \
    && pass "the head baseline is validated as a full OID, each time it is read" \
    || die "a fetched head is used as a baseline without validation"
grep -q 'HEAD_AFTER" =~ \^\[0-9a-f\]{40}\$' "$SKILL" \
    && pass "…and so is the head after the push" \
    || die "the pushed head is not validated"
grep -q 'could not re-read the head for this round' "$SKILL" \
    && pass "…and the baseline is refreshed per round, not carried from step 2" \
    || die "a stale baseline makes the unchanged-head check false after a fix round"

# ── the boundary is checked BEFORE the request, in both recipes ───────────
# Counting afterwards meant the pause fired once round N+1 was already queued and
# probably running — a notification, not a decision.
# Line numbers, compared per recipe. An awk state machine got this wrong twice:
# `inb` never reset, so the second recipe saw the first one's request line.
off_start=$(grep -n 'Automatic review OFF' "$SKILL" | head -1 | cut -d: -f1)
on_start=$(grep -n 'Automatic review ON' "$SKILL" | head -1 | cut -d: -f1)
in_range() {   # in_range <pattern> <from> <to> -> first matching line number
    # `-e`, not `--`: passing `--` as the first ARGUMENT shifted every parameter
    # by one, so the pattern became the range and every lookup returned line 1.
    grep -n -e "$1" "$SKILL" | awk -F: -v a="$2" -v b="$3" '$1>a && $1<b {print $1; exit}'
}
end_of_file=$(wc -l < "$SKILL")
for spec in "OFF|$off_start|$on_start" "ON|$on_start|$end_of_file"; do
    label="${spec%%|*}"; rest="${spec#*|}"; from="${rest%%|*}"; to="${rest#*|}"
    c=$(in_range 'pr-round-count.sh N "$WHO"' "$from" "$to")
    q1=$(in_range '--add-reviewer @copilot' "$from" "$to")
    q2=$(in_range '--body "@codex review' "$from" "$to")
    # In automatic mode the PUSH is the request, so it counts as a triggering
    # command. Checking only the mention and --add-reviewer let a boundary check
    # sit after the push and still pass — the third placement of this check, and
    # the first assertion that covers every way a review can start.
    q3=""
    [ "$label" = "ON" ] && q3=$(in_range '^git push' "$from" "$to")
    q=""
    for cand in "$q1" "$q2" "$q3"; do
        [ -n "$cand" ] || continue
        { [ -z "$q" ] || [ "$cand" -lt "$q" ]; } && q=$cand
    done
    { [ -n "$c" ] && [ -n "$q" ] && [ "$c" -lt "$q" ]; } \
        && pass "the automatic-review-$label recipe counts rounds before requesting" \
        || die "the automatic-review-$label recipe requests before the boundary check (count=$c request=$q)"
done

# ── Copilot is re-requested regardless of whether the head moved ──────────
# A push never triggers Copilot, so branching on the head first skipped
# `--add-reviewer` on any Copilot round that DID change the head.
awk '/^if \[ "\$WHO" = "\$COPILOT_BOT" \]; then$/ {w=NR}
     /HEAD_BEFORE" = "\$HEAD_AFTER/ {if (w && w < NR) {print "ok"; exit}}' "$SKILL" | grep -q ok \
    && pass "the reviewer is checked before the head in the automatic recipe" \
    || die "a Copilot round that changed the head skips --add-reviewer"

# ── the push must have landed on THIS PR ──────────────────────────────────
# A successful `git push` from the wrong worktree, or with a refspec pointing at
# another branch, leaves the PR head untouched — and because the local head then
# differs from it, the no-op branch is skipped and nothing is requested at all.
grep -q 'the push did not update PR N' "$SKILL" \
    && pass "the round verifies the push actually moved this PR" \
    || die "a push that landed elsewhere is treated as having queued a review"
# …against the SHA it pushed, not a fresh read of mutable local HEAD. A checkout
# reset after the push would otherwise satisfy the comparison with a commit that
# never reached the PR.
awk '/^if \[ "\$HEAD_BEFORE" != "\$HEAD_AFTER" \]; then$/ {inb=1}
     inb && /^fi$/ {inb=0}
     inb && /git rev-parse HEAD/ {print "bad"; exit}' "$SKILL" | grep -q bad \
    && die "the push confirmation re-reads mutable local HEAD" \
    || pass "…comparing against the pushed SHA rather than re-reading HEAD"

# ── a hostless origin is refused, not defaulted to GitHub ─────────────────
grep -q 'names no host; refusing to guess one' "$SKILL" \
    && pass "an origin with no network authority is refused" \
    || die "a local-path origin would be treated as github.com"

# ── the helper selection takes its pipeline status ────────────────────────
# `head` can emit a plausible path and then fail; if that directory holds
# executables the validation below passes and every gate runs helpers chosen by a
# failed read. Asserted on the guard, not on the abort message — the message
# survives the defect.
grep -q 'RB_CANDIDATES" | head -1)" \\' "$SKILL" \
    && pass "the helper selection branches on its pipeline status" \
    || die "the helper selection pipeline status is unchecked"

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

# ── the phase summary is written by a QUOTED heredoc ───────────────────────
# `SKILL.md` is executed by the driver verbatim, so an unquoted heredoc around
# prose is a live substitution site: the summary body is composed from the round
# and routinely contains Markdown code spans holding shell text, including text
# copied out of an untrusted PR description or a reviewer comment. The assertion
# is structural rather than on the abort message, because a message survives the
# defect it names.
hd="$(grep -n 'cat >>\{0,1\} "\$SUMMARY_FILE" <<' "$SKILL" || true)"
if [ -z "$hd" ]; then
    die "no summary heredoc found in SKILL.md — has the recipe moved?"
else
    bad="$(printf '%s\n' "$hd" | grep -v "<<'EOF'" || true)"
    [ -z "$bad" ] \
        && pass "every summary heredoc is quoted, so prose is written, not executed" \
        || die "an unquoted summary heredoc executes the prose it writes: $bad"
fi
# …and the one value it needs still reaches the file, or the quoting silently
# turned the SHA into the literal text $CODEX_SHA in every summary. The two parts
# are matched separately because the printf and its argument are on separate
# continued lines, and a single-line pattern would fail on correct code.
if grep -q "printf .*Codex signed off on" "$SKILL" \
   && grep -q '"\$CODEX_SHA" >> "\$SUMMARY_FILE"' "$SKILL"; then
    pass "the reviewed SHA is emitted separately through printf"
else
    die "the quoted heredoc drops the reviewed SHA and nothing re-emits it"
fi

# ── the required-checks payload is shape-checked before `all` ──────────────
# `all(.[]; …)` over an empty stream is `true`, so an object, a null, or an empty
# array from a SUCCESSFUL read came out as "every required check passed" and the
# default administrator merge proceeded on a payload nothing had read.
grep -q 'if type != "array" or length == 0 then "malformed"' "$SKILL" \
    && pass 'the checks payload must be a non-empty array before all() runs' \
    || die 'the checks jq computes all() without validating its container'
grep -q 'any(.\[\]; type != "object" or (.bucket | type) != "string")' "$SKILL" \
    && pass "…and each element must actually carry a bucket string" \
    || die "the checks jq does not validate the bucket records"

# ── the identity parser rejects transports that reach no GitHub server ─────
# `SKILL.md` carries its own copy of the parser, and it is the copy the driver
# runs. `test-pr-identity.sh` can execute the three scripts' copies but not this
# one, so the structural assertion is what covers it.
grep -q 'ssh://\*|git://\*|https://\*|http://\*|git+ssh://\*' "$SKILL" \
    && pass "SKILL.md accepts only GitHub network transports" \
    || die "SKILL.md parses any URL scheme as a GitHub identity"
grep -q 'reaches no GitHub server' "$SKILL" \
    && pass "…and refuses the rest rather than guessing a host" \
    || die "SKILL.md has no rejection path for an unsupported transport"

# ── acknowledging a check-in takes the gate's status, and names the reviewer ─
# The acknowledgement is the one place the driver records the OPERATOR's
# permission. Reading it out of a pipeline hid the helper's status: a run that
# printed a plausible pause line and then died some other way still yielded
# digits, `sed` still succeeded, and permission was recorded from an unreadable
# probe. And the count is per reviewer, so an unscoped footer acknowledging 41
# Codex rounds is read by a Copilot invocation with 5, trips its ahead-of-count
# guard and blocks that phase for good.
grep -q 'ROUNDS_RC" -eq 3' "$SKILL" \
    && pass "the acknowledgement requires the gate's distinguished pause status" \
    || die "the driver acknowledges a check-in without checking the gate exited 3"
grep -q 'Review-Pause-Acknowledged:\*\* `%s` `%s`' "$SKILL" \
    && pass "the acknowledgement footer names the reviewer and the count" \
    || die "the acknowledgement footer is unscoped and will cross between phases"

# ── the none-configured checks message is matched whole, not searched ──────
# `gh pr checks` has no dedicated status for "no required checks" — it documents
# exit 8 for pending and nothing for this — so the message is the only signal.
# A substring test therefore accepted the benign phrase inside a LARGER failure:
# a run that printed it and then failed for an unrelated reason was classified as
# benign, and the default administrator merge proceeded with no trusted checks
# result. The helper is extracted so this can be executed rather than read.
# The EXTRACTION has its own status. `sed` can print a plausible complete helper
# and then fail, and command substitution keeps it — all six cases below would
# then pass on a source read that never finished, which is a mandatory gate
# reporting coverage it does not have.
CHK="$(sed -n '/^checks_msg_is_none_configured() {/,/^}/p' "$SKILL")"; chk_rc=$?
# …and the helper must be the one the GATE actually calls. Six passing cases prove
# nothing if the merge condition still greps for a substring beside an unused
# function — the definition and the call site are separate things, and only the
# second decides whether the merge proceeds.
if [ "$chk_rc" -ne 0 ]; then
    die "could not read SKILL.md to extract the checks helper (rc=$chk_rc)"
elif [ -z "$CHK" ]; then
    die "no checks-diagnostic helper in SKILL.md — has the merge gate moved?"
elif ! grep -q 'elif checks_msg_is_none_configured "\$CHECKS_MSG"; then' "$SKILL"; then
    die "the merge gate does not call checks_msg_is_none_configured; the helper is dead code"
else
    chk() { bash -c "$CHK"'
checks_msg_is_none_configured "$1" && echo BENIGN || echo BLOCK' _ "$1"; }
    [ "$(chk "no required checks reported on the '"'"'main'"'"' branch")" = BENIGN ] \
        && pass "the exact none-configured message opens the gate" \
        || die "the real gh diagnostic was not recognised"
    [ "$(chk "no checks reported on the '"'"'main'"'"' branch")" = BENIGN ] \
        && pass "…including the wording gh uses when there are no checks at all" \
        || die "the no-checks-whatsoever wording blocks forever"
    # The finding: the phrase followed by a real error.
    [ "$(chk "no required checks reported on the '"'"'main'"'"' branch
error: connection reset by peer")" = BLOCK ] \
        && pass "the phrase followed by an error blocks the merge" \
        || die "a failed probe containing the benign phrase was treated as benign"
    [ "$(chk "warning: no required checks reported on the '"'"'main'"'"' branch, and the API call failed")" = BLOCK ] \
        && pass "…and so does the phrase embedded in a larger message" \
        || die "an embedded phrase was treated as the whole diagnostic"
    [ "$(chk "")" = BLOCK ] && pass "an empty diagnostic blocks" || die "an empty diagnostic opened the gate"
    [ "$(chk "some other failure entirely")" = BLOCK ] \
        && pass "an unrelated failure blocks" || die "an unrelated failure opened the gate"
fi

# ── `none` is not permission while auto-review has a pass in flight ────────
# With auto-review on, every Copilot-fix push queues a Codex pass, and Codex
# exposes no review record while that pass is queued — which the merge gate read
# as the same `none` that means "nothing asked Codex about this head". It then
# fell back to the pre-Copilot signoff and could merge before the in-flight pass
# reported, including a body-only CHANGES_REQUESTED that leaves no unresolved
# thread for the other gates to catch.
none_branch="$(awk '/^case "\$CODEX_STATE" in/ { c++ } c == 2 { print } c == 2 && /^esac/ { exit }' "$SKILL")"
if [ -z "$none_branch" ]; then
    die "the merge gate no longer has a CODEX_STATE dispatch — has it moved?"
else
    printf '%s' "$none_branch" | grep -q 'AUTO_REVIEW.*=.*yes' \
        && pass "the merge gate distinguishes an in-flight auto-review from no review" \
        || die "the none branch falls back to the signoff without checking AUTO_REVIEW"
    printf '%s' "$none_branch" | grep -q 'merge blocked' \
        && pass "…and blocks rather than trusting the pre-Copilot signoff" \
        || die "the in-flight case does not block the merge"
fi

# ── the phase trailer has to be documented as a TRAILER ────────────────────
# `git` parses trailers from the last paragraph only, so `Review-Phase: copilot`
# written with a blank line above it is not a trailer — the commit looks correct
# to a reader and is invisible to the merge gate. The contract told the driver to
# "carry the trailer" without saying where, and following it produced exactly that
# commit while developing this plugin.
grep -q 'LAST paragraph' "$SKILL" \
    && pass "the contract says where the phase trailer has to go" \
    || die "the contract asks for a trailer without saying it must be in the trailer block"
grep -q 'trailer_not_in_trailer_block' "$SKILL" \
    && pass "…and names the status the gate reports when it is misplaced" \
    || die "the contract does not mention the misplaced-trailer status"

# ── the driver's working discipline is stated, not assumed ─────────────────
# The failure mode of an automated fix loop is not laziness, it is enthusiasm:
# fixing more than was asked, building more than the finding requires, and
# bundling both into a commit whose summary says "closing review comments". Each
# of these rules exists because breaking it lengthened a real PR here, so each is
# asserted rather than left to be inferred from the surrounding prose.
# EVERY clause this contract declares binding, not a sample of them. The first
# version asserted five of six, so deleting "every change must be reviewable as a
# fix" left the suite green — a contract can lose a rule silently exactly as a
# helper can lose a field check.
for rule in \
    'Fix what the finding names' \
    'Do not build more than the finding requires' \
    'Every change you make must be reviewable as a fix' \
    'Validate a finding before you act on it' \
    'Prove a fix can fail' \
    'Say what you did not do'; do
    grep -qF "$rule" "$SKILL" \
        && pass "the contract states: $rule" \
        || die "the contract no longer states: $rule"
done

# ── the driver is told to read a finding whole ─────────────────────────────
# `list` prints one line per thread so the set is countable; that line is not the
# finding. Acting on the title alone produces a fix aimed at a paraphrase, which
# is how a round ends with the thread resolved and the finding still true.
grep -q 'Read each finding whole' "$SKILL" \
    && pass "the contract tells the driver to read the finding body" \
    || die "the contract does not tell the driver to read past the title"
grep -q 'suggestion' "$SKILL" \
    && pass "…including any code suggestion attached to it" \
    || die "the contract never mentions code suggestions"
grep -q 'proposal rather than an instruction' "$SKILL" \
    && pass "…and that a suggestion is a proposal, not an instruction" \
    || die "the contract does not say how to weigh a code suggestion"
# The bodies come from the helper, which filters to UNRESOLVED threads. The REST
# comments endpoint has no such filter and returns every review comment the PR has
# ever had, so fetching bodies there hands the driver findings answered three
# rounds ago — and fixing an already-answered comment is the scope expansion these
# same rules forbid. The contract said so only after a review round said it first.
# The endpoint is NAMED — the contract warns against it — so what must be absent
# is a CALL to it, not the string. FLATTENED, because `gh api` calls in this file
# routinely span continuation lines: a line-based match saw only one token of a
# split invocation and reported clean. Third time line-wrapping has defeated a
# check in this PR, which is why the flattened copy is taken once and reused.
skill_flat="$(tr '\n' ' ' < "$SKILL" | tr -s ' ')" \
    || die "could not flatten SKILL.md for the endpoint check"
# The scans below use herestrings rather than `printf | grep`: under `pipefail`,
# `grep -q` exiting at the first match SIGPIPEs the producer and the pipeline
# reports the match as ABSENT — the fail-open direction. The fixture demonstrating
# that hazard, and the counting machinery for CHANGELOG consistency, are held back
# for a follow-up PR: both are hardening of this file rather than tests of the
# documentation this change delivers, and both were the source of most of the
# review churn on it.
# A POSITIVE CONSTRAINT, not a blacklist of route spellings.
#
# Three versions of this guard tried to recognise the forbidden call by its shape
# — `[^|]*` treated a jq pipe as a pipeline boundary, `{0,200}` was a ceiling a
# long filter walks past, and the route regex was defeated in turn by `$PR`,
# quotes, and a backslash continuation. Each fix was correct and each was one
# spelling behind, because a lexical blacklist can always be evaded: the last
# evasion found was `PULLS="repos/…/pulls/$PR"; gh api "$PULLS/comments"`, where no
# contiguous route substring exists at all.
#
# The invariant was never really about that string. It is that the findings are
# read through the HELPER, which filters to unresolved threads — so the check is
# now that the findings-reading section executes `pr-findings.sh` and calls no
# `gh api` at all. No composition of variables satisfies that, because the
# constraint is on what the section may invoke rather than on how a URL is spelt.
#
# `gh api` remains legitimate elsewhere in the file — reactions and thread
# resolution use it — so the constraint is scoped to the section that reads
# findings.
findings_code="$(awk '
    /^## 4\. Read the findings/ { insec = 1 }
    insec && /^## 5\./ { insec = 0 }
    !insec { next }
    /^[ ]{0,3}(```+|~~~+)/ {
        line = $0; sub(/^[ ]+/, "", line)
        ch = substr(line, 1, 1); n = 0
        while (substr(line, n + 1, 1) == ch) n++
        if (!inb) { inb = 1; fch = ch; fn = n; next }
        if (ch == fch && n >= fn && substr(line, n + 1) ~ /^[[:space:]]*$/) { inb = 0; next }
    }
    inb { print }' "$SKILL")" \
    || die "could not extract the findings-reading section from SKILL.md"
[ -n "$findings_code" ] \
    || die "the findings-reading section has no executable block; has it moved?"
# A WHITELIST, which is where this had to end up. Blacklisting the route was
# defeated by five spellings; blacklisting `gh api` was still lexical and is
# defeated by `gh  api`, `"gh" api`, or a continuation between the two words.
# Every blacklist is one spelling behind because the space of ways to write a
# command is open.
#
# So the section is constrained to what it MAY run rather than what it may not:
# every executable line here has to be a `pr-findings.sh` invocation. Anything
# else fails however it is spelt, because the check is not looking at how a
# command is written — it is looking for anything that is not the one permitted
# command. That closes the sequence rather than extending it.
#
# If this section ever legitimately needs a second command, this guard fails and
# is updated deliberately. That is the correct cost: adding a call here is exactly
# the change that should not happen quietly.
findings_stmts=0 findings_bad=""
while IFS= read -r line; do
    case "$line" in
        ''|'#'*|' '*'#'*) continue ;;
    esac
    findings_stmts=$((findings_stmts + 1))
    # ANCHORED to the whole statement. An unanchored glob only asked that the
    # permitted call appear SOMEWHERE, so `gh api …; "$RB_SCRIPTS"/pr-findings.sh
    # list N` satisfied it — a whitelist carrying a blacklist's hole. The statement
    # is split on `;`: the first command must BE the helper, and every following
    # segment must be a status capture, which is the only other thing these lines
    # do.
    stmt="${line#"${line%%[![:space:]]*}"}"
    first="${stmt%%;*}"; rest="${stmt#"$first"}"
    ok=1
    case "$first" in
        '"$RB_SCRIPTS"/pr-findings.sh '*) ;;
        *) ok=0 ;;
    esac
    while [ -n "$rest" ] && [ "$ok" -eq 1 ]; do
        rest="${rest#;}"; seg="${rest%%;*}"; rest="${rest#"$seg"}"
        seg="${seg#"${seg%%[![:space:]]*}"}"; seg="${seg%"${seg##*[![:space:]]}"}"
        case "$seg" in
            ''|[A-Za-z_]*'=$?') ;;
            *) ok=0 ;;
        esac
    done
    [ "$ok" -eq 1 ] || findings_bad="$findings_bad
       $line"
done <<<"$findings_code"
[ "$findings_stmts" -gt 0 ] \
    && pass "the findings-reading section has executable statements to check" \
    || die "the findings-reading section executes nothing; has it moved?"
if [ -z "$findings_bad" ]; then
    pass "…and every one of them is a pr-findings.sh call, whatever else could be spelt"
else
    die "the findings-reading section runs something other than pr-findings.sh:"
    printf '%s\n' "$findings_bad"
fi
grep -q 'no resolution filter' "$SKILL" \
    && pass "…and says why that endpoint cannot be used for findings" \
    || die "the contract does not explain why the REST endpoint is wrong here"
# The deferral rule must not contradict the work-order rule: a mention describing
# an UNFIXED defect is read as a task, and Codex then commits in an environment
# with no remote. The disposition belongs in the summary; the description does not.
# Mutation proof is mandatory in this repository, so the contract must not offer
# disclosure as a way out of it: a summary is untrusted context, not authority,
# and closing a round on "no mutant is claimed" leaves an assertion that passed
# before the fix while the suite reports green.
grep -q 'not waivable by disclosure' <<<"$skill_flat" \
    && pass "mutation proof cannot be waived by saying so in the summary" \
    || die "the contract lets a summary line stand in for an unproven fixture"
grep -qi 'recorded \*\*at the site' <<<"$skill_flat" \
    && pass "…an unprovable case is recorded on the base ref instead" \
    || die "the contract does not say where an unprovable limitation is recorded"
# The OUTCOME, not only the prohibition. Recording the limitation and carrying on
# is still closing a round on an unproven fixture — the stop is what makes the
# rule bite, and it was the one clause the previous pair of assertions missed.
grep -q 'round \*\*stops for the operator\*\*' <<<"$skill_flat" \
    && pass "…and the round stops for the operator rather than closing" \
    || die "the contract records an unprovable case but lets the round close anyway"

# The scope rule and the class-wide self-check must not contradict each other:
# one says fix only what was named, the other says find every occurrence of the
# same shape. They are reconciled by scope, not left for the driver to pick.
grep -q 'is the DEFECT, not the line' <<<"$skill_flat" \
    && pass "the scope rule and the class-wide self-check are reconciled" \
    || die "the contract gives the driver two incompatible scope instructions"
grep -q 'outside this PR' <<<"$skill_flat" \
    && pass "…and a same-shape defect outside the diff is recorded, not pulled in" \
    || die "the contract does not bound class-wide fixing to the PR's own diff"
# The DECISIVE clause: when a finding states its scope, that scope governs — but
# only over copies this PR already changes. Without the first half the driver has
# no rule for an explicit "fix the other parsers"; without the second half it
# contradicts the outside-diff boundary directly above.
grep -q 'states its scope' <<<"$skill_flat" \
    && pass "a finding's stated scope governs the class-wide fix" \
    || die "the contract has no rule for a finding that states its own scope"
grep -q 'that scope governs \*\*for the copies this PR already changes\*\*' <<<"$skill_flat" \
    && pass "…bounded to the copies this PR already changes" \
    || die "stated scope is unbounded and contradicts the outside-diff rule"
# `[[:space:]]`, never `\s`. `\s` is a GNU extension: BSD grep on stock macOS —
# which README lists as supported — reads it as a literal `s`, so this searched for
# "evens*when", failed, and called `die` on correct text. The whole suite is a
# mandatory pre-push gate, so a macOS contributor could not close a round while CI
# stayed green. Same class as the `timeout`, `sha1sum` and `seq` findings before it.
#
# The flattened text has already collapsed runs of whitespace to single spaces, so
# a plain space would do; the class is used anyway because the next person to copy
# this line may not be matching flattened text.
grep -q 'even[[:space:]]*when the finding names it' <<<"$skill_flat" \
    && pass "…and a named copy outside the diff is still not pulled in" \
    || die "a finding naming an untouched file could still widen the PR"
# A REGRESSION THE FIX CAUSED BELONGS TO THIS ROUND. The rule said a different
# defect found while fixing is "never in scope", which would have the driver defer
# a defect it had just introduced — part of what this PR changed, and on its way to
# a merge if the next reviewer misses it. The line is drawn at pre-existing, not at
# "was it the defect the finding named".
# THE OUTCOME, not the subject. Matching only "a regression the fix itself
# introduces" passed when the sentence was negated — the contract could say such a
# regression is NOT this round's work and this check would still be green.
grep -q 'regression the fix itself introduces' <<<"$skill_flat" \
    && pass "the contract addresses a regression the fix introduces" \
    || die "the contract no longer addresses a regression the fix causes"
grep -q 'it is part of what this PR changed, so it is this round' <<<"$skill_flat" \
    && pass "…and says it is this round's work" \
    || die "the contract does not say a fix-introduced regression is this round's work"
# BOTH qualifiers. "pre-existing" alone still excluded the same defect in a copy
# this PR changes, which the bullets above require fixing together — the driver
# could leave an in-diff twin and collect the same finding next round.
# Subject AND outcome. `A *different* pre-existing defect` alone passed with the
# sentence reversed to "is in scope", which is the opposite instruction.
grep -q 'A \*different\* pre-existing defect' <<<"$skill_flat" \
    && pass "…and only a DIFFERENT pre-existing defect is out of scope" \
    || die "the out-of-scope rule would exclude an in-diff twin of the same defect"
grep -qE 'A \*different\* pre-existing defect found while fixing this one is not in scope' <<<"$skill_flat" \
    && pass "…and that defect is stated to be OUT of scope" \
    || die "the contract does not state the out-of-scope outcome"
# …and the CURRENT release entry must not describe these rules the old way. Four
# stale copies have now been found in it, so the check is negative — the wrong
# forms must be ABSENT — rather than positive: asserting that a qualified form
# appears somewhere is satisfied by one occurrence while another sits unqualified
# two paragraphs down, which is exactly how the last two survived.
#
# Scoped to the TOP entry only. Everything below it is history, and a release note
# has to be able to quote a superseded rule to explain what was fixed.
grep -q 'disposition, never as a description' "$SKILL" \
    && pass "deferrals are recorded as a disposition, not a description" \
    || die "the contract invites a summary that reads as a work order"
# …and NO copy of the summary rule may ask for the reasoning. "what was skipped,
# and why" invites the unfixed defect into the mention, which is the work order.
# Three files carried that wording; fixing one and not the others is how a rule
# survives being reconciled.
# CHANGELOG.md is NOT in this list, and adding it was a mistake I made and am
# undoing: a changelog has to be able to QUOTE a superseded directive in order to
# explain the failure that was fixed — "the old contract said the summary explains
# why" is exactly the sentence a release note needs — and a whole-file ban would
# fail the mandatory suite for describing history correctly. Its current entry is
# checked below instead, positively and scoped to that entry.
for doc in "$SKILL" "$SCRIPT_DIR/../../../CLAUDE.md" "$SCRIPT_DIR/../../../README.md"; do
    [ -f "$doc" ] || { die "missing instruction file: $doc"; continue; }
    dname="$(basename "$doc")"
    dflat="$(tr '\n' ' ' < "$doc" | tr -s ' ')" || { die "$dname: could not read"; continue; }
    # A SET of phrasings, not one literal. The first version matched only
    # `intentionally skipped, and why`, and a third copy of the rule was worded
    # differently — "the summary explains why" — so the check could not see it.
    # Three rounds of this PR each found one more copy; the pattern list is what
    # each of them added, and a new phrasing belongs here rather than being
    # noticed by a reviewer for a fourth time.
    # The pattern set grew again: a fourth copy asked the summary to argue for a
    # BROADER FIX — a design proposal rather than a reason for a skip, different
    # wording, same outcome, because anything in the mention that describes work
    # to be done is read as a work order.
    #
    # Deliberately NOT matched: "say so in the summary" where what is said is a
    # past-tense fact about this round's own checks — the self-check reporting it
    # had nothing in scope. That cannot become a work order, and widening the
    # pattern to catch it would forbid the summary from doing its job.
    dir_rc=0
    grep -qiE \
        'skipped, and why|summary explains why|explains? why it was (skipped|deferred|left)|and why it was (skipped|deferred|left)|(warranted|broader fix)[^.]{0,60}say so in the summary|(the )?(reason|rationale)[^.]{0,40}(not applied|was skipped|for skipping|it was left)' \
        <<<"$dflat" || dir_rc=$?
    case "$dir_rc" in
        0) die "$dname: still asks the summary to explain something that was not done" ;;
        1) pass "$dname: does not invite the deferred defect into the summary" ;;
        *) die "$dname: the summary-directive scan could not be completed" ;;
    esac
done

# ── both reviewer files carry the same context and finding-quality rules ───
# `.github/copilot-instructions.md` restates the policy inline because Copilot
# reads only that file and does not follow pointers, so a rule added to AGENTS.md
# alone reaches one reviewer of two. That asymmetry is the documented reason the
# duplicate exists, which makes it exactly the thing that drifts.
for doc in "$SCRIPT_DIR/../../../AGENTS.md" "$SCRIPT_DIR/../../../.github/copilot-instructions.md"; do
    [ -f "$doc" ] || { die "missing reviewer instruction file: $doc"; continue; }
    name="$(basename "$doc")"
    # DISTINGUISHING text, not a phrase the file already contained. `resolved
    # threads` matched `AGENTS.md`'"'"'s "zero unresolved threads" and the Copilot
    # file'"'"'s "Waivers and resolved threads" heading, so this pair of assertions
    # passed with the reply-context paragraph deleted from both — a guard for
    # duplicate drift that could not see the duplicate drift.
    # FLATTENED before matching. These files are wrapped prose, so a phrase that
    # spans a line break is invisible to line-based grep — the first version of
    # these assertions failed on correct text for exactly that reason.
    flat="$(tr '\n' ' ' < "$doc" | tr -s ' ')" || { die "$name: could not read"; continue; }
    grep -qi 'replies on .*resolved threads' <<<"$flat" \
        && pass "$name: earlier-round replies are named as context" \
        || die "$name: does not tell the reviewer to read earlier thread replies"
    # The PREDICATE, not the phrase: "changed code is still" alone is satisfied by
    # "…is still correct", which reverses the rule while matching the check.
    grep -qi 'changed code is still[[:space:]]*defective' <<<"$flat" \
        && pass "$name: a wrong reply is a finding only if the code is still DEFECTIVE" \
        || die "$name: would have the reviewer block a merge to correct the record"
    # THE REQUIREMENT, not the field name. Searching for `consequence` passed when
    # the instruction was reversed to "do not include the triggering input or
    # consequence" — the words present, the direction inverted. Same
    # subject-without-outcome defect as the guards above.
    grep -qiE '(include|name|state)s?[^.]{0,140}consequence' <<<"$flat" \
        && pass "$name: a finding must state its consequence" \
        || die "$name: does not require a finding to state its consequence"
    # …and must not NEGATE it. "do not include the triggering input or consequence"
    # contains every word the positive check looks for, which is the same
    # subject-without-outcome hole in its last form: the verb is there, the
    # polarity is not.
    neg_rc=0
    grep -qiE '(do not|do n.t|never|must not)[^.]{0,40}(include|name|state)[^.]{0,100}(consequence|triggering input|input or state that triggers)' <<<"$flat" || neg_rc=$?
    case "$neg_rc" in
        0) die "$name: tells the reviewer NOT to include a finding's required fields" ;;
        1) pass "…and does not tell the reviewer to omit them" ;;
        *) die "$name: the negation scan could not be completed (rc=$neg_rc)" ;;
    esac
    grep -qiE '(include|name|state)s?[^.]{0,80}(triggering input|input or state that triggers)' <<<"$flat" \
        && pass "$name: a finding must state the input that triggers it" \
        || die "$name: does not require a finding to state its triggering input"
    # DISTINGUISHING text again. Bare `scope` matched several pre-existing uses in
    # both files — "judge the PR against its own goal", "out-of-scope problems" —
    # so this passed with the second-copy requirement deleted. Same defect as the
    # `resolved threads` assertion beside it, and I fixed that one without
    # checking its sibling: the instance rather than the class, which is the thing
    # this PR is about.
    # ONE COMBINED PREDICATE, not two independent ones. Separate checks for
    # `second copy` and `this PR also` are both satisfied by a rule that says to
    # name a second copy WHETHER OR NOT this PR changes it — the two facts can be
    # present while the relationship between them is reversed, which is the whole
    # instruction. This is the same subject-versus-outcome gap as the guards above,
    # in its last hiding place.
    # …AND the required ACTION. Binding the two noun phrases still matched
    # "do not name a second copy that this PR also changes" — the relationship
    # correct, the instruction inverted. Every layer of this check has now been
    # defeated by a negation until the verb was included.
    # …AND the required ACTION, in whichever form the file states it. Binding the
    # two noun phrases still matched "do NOT name a second copy that this PR also
    # changes" — relationship correct, instruction inverted. Every layer of this
    # check has been defeated by a negation until the verb was included.
    #
    # AGENTS.md ends the clause with ", say so"; the Copilot copy leads with
    # "naming any second copy …". Both are the positive instruction; matching only
    # one would fail the other file for wording rather than for meaning.
    grep -qiE '(naming any second copy[^.]{0,80}that this PR also changes|second copy[^.]{0,80}that this PR also changes(\*\*)?, say so)' <<<"$flat" \
        && pass "$name: a finding must NAME a second copy this PR also changes" \
        || die "$name: does not require naming an in-diff second copy"
    grep -qi 'proposal, not the finding' <<<"$flat" \
        && pass "$name: a code suggestion is a proposal, not the finding" \
        || die "$name: does not say a code suggestion is only a proposal"
done

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
