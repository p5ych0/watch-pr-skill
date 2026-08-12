#!/usr/bin/env bash
# Close a review round: push the fixes, prove the head is green, post the summary
# and request the next pass.
#
#   pr-close-round.sh <pr> <reviewer-login> <summary-file> <auto-review: yes|no>
#
#   0  closed   — the summary is posted and the next review is requested
#   1  stopped  — the reason is on stdout; the round is NOT closed
#   3  paused   — a round boundary. NOT a refusal: the operator decides
#
# WHY THIS EXISTS AS A SCRIPT
#
# It was two recipes in `SKILL.md`, 56 and 191 lines, doing the same job in
# different ORDERS — and the ordering is the whole content. Nothing executed
# either of them. Issue #26.
#
# THE TWO ORDERS, AND WHY THEY DIFFER:
#
#   auto-review OFF — the `@codex review` mention is the trigger, so it can carry
#     the summary in one comment. Nothing is queued until that comment is posted,
#     which means the round can be closed before anything is requested.
#
#   auto-review ON — the PUSH is the trigger, so a pass starts before anything
#     here can post or resolve. The ordering is then decided by what is
#     IRREVERSIBLE: push first, prove the checks, and close afterwards.
#
#     This sequence used to close first and push last, so the pass the push
#     started would find the threads resolved and the summary in place. That
#     cannot be gated: by the time the checks on the pushed commit can be
#     consulted, the threads are resolved and the summary posted, and neither can
#     be taken back. A later "this round is not closed" comment is a record, not a
#     retraction — and is itself a call that can fail.
#
#     THE COST IS REAL AND IS NOT HIDDEN: the pass the push starts reads open
#     threads and no summary, so it can re-report findings this round already
#     answered. It is superseded by the explicit request at the end. The trade is
#     a wasted pass against a round that closes on a red head, and only one of
#     those can be undone by the next round.
#
# `set -uo pipefail`, NOT `-e`: every probe here reports its answer as an exit
# status and several fail as ordinary operation. See CLAUDE.md § Bash conventions.
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "ABORT: reason=lib_dir_unresolvable"; exit 1; }
unset -f rb_load 2>/dev/null || { echo "ABORT: reason=loadlib_stale_definition"; exit 1; }
. "$_RB_SELF_DIR/loadlib.sh" || { echo "ABORT: reason=loadlib_unreadable"; exit 1; }
[ "$(type -t rb_load 2>/dev/null)" = function ] || { echo "ABORT: reason=loadlib_empty"; exit 1; }
# `2>&1` on each: `rb_load` reports on stderr, and everything this script says is
# documented as stdout — a caller capturing it would otherwise get nothing for the
# failures that happen before anything else can.
rb_load "$_RB_SELF_DIR" recordlib sha_reason "ABORT:" 2>&1 || exit 1
# BOTH CONSTANTS, EACH THROUGH `rb_load`. Verifying only one leaves the other
# inheritable: a `recordlib.sh` truncated after the first definition passes the
# check, and an exported `RB_COPILOT_BOT` from the environment is then accepted
# as library data — so this would validate a signoff from whatever account that
# variable named. `rb_load` clears before it sources, which is the whole point.
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "ABORT:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_COPILOT_BOT "ABORT:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" identitylib rb_identity "ABORT:" 2>&1 || exit 1
rb_identity || { echo "ABORT: reason=$RB_IDENTITY_REASON"; exit 1; }
COPILOT_BOT="$RB_COPILOT_BOT"

PR="${1:-}"; WHO="${2:-}"; SUMMARY_FILE="${3:-}"; AUTO_REVIEW="${4:-}"
case "$PR" in
    ""|*[!0-9]*) echo "ABORT: a PR number is required (got '$PR')"; exit 1 ;;
esac
# THE REVIEWER IS ONE OF THE TWO THIS LOOP KNOWS. Every branch below asks "is
# this Copilot?" and treats everything else as Codex, so a typo or a third login
# silently took the Codex path: the mention was posted, Copilot was never
# requested, and the round waited on a pass nobody asked for.
case "$WHO" in
    "$RB_CODEX_BOT"|"$RB_COPILOT_BOT") ;;
    "") echo "ABORT: a reviewer login is required"; exit 1 ;;
    *) echo "ABORT: '$WHO' is not a reviewer this loop drives (expected $RB_CODEX_BOT or $RB_COPILOT_BOT)"; exit 1 ;;
esac
[ -n "$SUMMARY_FILE" ] || { echo "ABORT: a summary file is required"; exit 1; }
# AUTO-REVIEW DECIDES THE ORDERING, so an unrecognised value is refused rather
# than assumed. Guessing wrong here does not fail loudly — it closes the round in
# the wrong order, which is only visible afterwards.
case "$AUTO_REVIEW" in
    yes|no) ;;
    *) echo "ABORT: auto-review must be 'yes' or 'no' (got '$AUTO_REVIEW')"; exit 1 ;;
esac

# THE SUMMARY IS READ WITH ITS STATUS TAKEN, before anything is posted or pushed.
# `$(cat …)` inside the argument swallows the reader's status, so a partial read
# still produced a successful `gh pr comment` — and the reviewer contract makes the
# newest summary the thing read before the diff, so a truncated one is worse than
# none: it looks complete. A round that cannot produce its own summary should not
# push either.
SUMMARY="$(cat "$SUMMARY_FILE")" || { echo "ABORT: could not read the round summary."; exit 1; }
[ -n "$SUMMARY" ] || { echo "ABORT: the round summary is empty."; exit 1; }

# THE BOUNDARY IS CHECKED BEFORE ANY WAY A REVIEW CAN BE REQUESTED — which in
# auto-review mode means before the PUSH, because there the push IS the request.
# Placing it before the mention was not enough: a fix commit on the threshold-th
# round moved the head and started the next review while the count had not yet
# run, so the pause fired after the round it was meant to precede was queued.
"$_RB_SELF_DIR"/pr-round-count.sh "$PR" "$WHO"; ROUNDS_RC=$?
case "$ROUNDS_RC" in
    0) ;;
    3) echo "PAUSE: round boundary reached. Decide with the operator before requesting the next pass: continue, merge, leave it open, or close this PR and start over with a better approach. Say what the rounds have been ABOUT, not just how many"
       exit 3 ;;
    *) echo "ABORT: could not establish the round count (rc=$ROUNDS_RC)"; exit 1 ;;
esac

request_review() {   # request_review ; posts the summary and asks for the pass
    # THE BASELINE IS READ IMMEDIATELY BEFORE THE REQUEST, never earlier. A
    # baseline captured before the push accepts a pass that FINISHED during the CI
    # wait as the answer to a request made after it — and a Codex pass on a small
    # diff can beat the checks.
    local prior
    prior=$("$_RB_SELF_DIR"/pr-review-state.sh review-id "$PR" "$WHO") \
        || { echo "ABORT: could not read the current review id; do not request a review blind."; return 1; }
    # WHICH REVIEWER THE ROUND WAS ABOUT DECIDES HOW IT IS RE-REQUESTED. Copilot is
    # never triggered by a mention and never by a push — only by `--add-reviewer` —
    # so a Copilot round that posted the Codex mention requested nothing at all,
    # and the watch then waited past the old review indefinitely.
    if [ "$WHO" = "$COPILOT_BOT" ]; then
        gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "$SUMMARY" \
            || { echo "ABORT: could not post the round summary."; return 1; }
        gh pr edit "$PR" --repo "$HOST/$OWNER/$REPO" --add-reviewer @copilot \
            || { echo "ABORT: could not re-request Copilot."; return 1; }
    else
        # ONE COMMENT, because the mention IS the trigger: the summary posted
        # separately is a summary the pass may not have read.
        gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "@codex review

$SUMMARY" \
            || { echo "ABORT: could not request the review that carries this round's summary."; return 1; }
    fi
    # THE BASELINE GOES BACK TO THE CALLER, in the success record. It is read
    # here, immediately before the request, and the driver's watch in step 3 needs
    # exactly this value: without it the watch keeps the parent's OLDER baseline,
    # and the terminal review this round just handled is newer than that — so it
    # is accepted at once as the answer to a request that has not been answered.
    # A child process cannot assign a variable in its parent; it can only say what
    # the value was.
    RB_PRIOR_REVIEW="$prior"
    return 0
}

if [ "$AUTO_REVIEW" = no ]; then
    # ── THE MENTION IS THE TRIGGER ─────────────────────────────────────────
    # Nothing is queued until the comment is posted, so the push can be proven
    # green first and the round closed in one step afterwards.
    HEAD_PUSHED=$(git rev-parse HEAD) || { echo "ABORT: could not read the local head."; exit 1; }
    git push || { echo "ABORT: push failed; the fixes are not on the PR."; exit 1; }
    "$_RB_SELF_DIR"/pr-ci-gate.sh "$PR" "$HEAD_PUSHED" || exit 1
    request_review || exit 1
    echo "PR_ROUND_CLOSED pr=$PR reviewer=$WHO head=$HEAD_PUSHED mode=mention prior-review=$RB_PRIOR_REVIEW"
    exit 0
fi

# ── THE PUSH IS THE TRIGGER ────────────────────────────────────────────────
HEAD_BEFORE=$(git rev-parse HEAD) || { echo "ABORT: could not read the local head."; exit 1; }
PUSH_FROM=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not read the head this push starts from."; exit 1; }
_why="$(sha_reason "$PUSH_FROM")" \
    || { echo "ABORT: the pre-push head is not a full OID ($_why: '$PUSH_FROM')."; exit 1; }

# THE BASELINE IS READ BEFORE THE PUSH, and this is the one ordering in the whole
# script that runs the other way round from everything else.
#
# Everywhere else, later is safer: read the state as close as possible to the
# decision that uses it. Here later is WRONG. The push starts a pass; a fast one
# finishes while the CI gate is still settling; and a baseline taken after that
# captures the completed pass as the thing to wait past — so `pr-watch.sh` waits
# for a newer pass that nobody requested, times out, and the round never closes
# despite being clean.
#
# Only for reviewers a push can trigger. Copilot is not one, and reading it there
# put a `gh` call that can fail transiently in front of the `--add-reviewer` that
# is the only thing a Copilot round needs — a stall with no upside.
PUSH_BASE=""
if [ "$WHO" != "$COPILOT_BOT" ]; then
    PUSH_BASE=$("$_RB_SELF_DIR"/pr-review-state.sh review-id "$PR" "$WHO") \
        || { echo "ABORT: could not read the review id before the push."; exit 1; }
fi
git push || { echo "ABORT: push failed; no review was queued and the fixes are not on the PR."; exit 1; }
"$_RB_SELF_DIR"/pr-ci-gate.sh "$PR" "$HEAD_BEFORE" || exit 1

# THE PUSHED HEAD IS CONFIRMED, WITH RETRIES. The API can serve the previous head
# for a moment after a push, and every check below is about the commit that was
# pushed rather than the one the API happens to be reporting.
HEAD_AFTER=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not confirm the pushed head."; exit 1; }
_why="$(sha_reason "$HEAD_AFTER")" \
    || { echo "ABORT: the pushed head is not a full OID ($_why: '$HEAD_AFTER')."; exit 1; }
if [ "$HEAD_BEFORE" != "$HEAD_AFTER" ]; then
    for _try in 1 2 3; do
        [ "$HEAD_AFTER" = "$HEAD_BEFORE" ] && break
        sleep 2
        HEAD_AFTER=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
            || { echo "ABORT: could not re-read the head after pushing."; exit 1; }
        _why="$(sha_reason "$HEAD_AFTER")" \
            || { echo "ABORT: the re-read head is not a full OID ($_why: '$HEAD_AFTER')."; exit 1; }
    done
    [ "$HEAD_AFTER" = "$HEAD_BEFORE" ] \
        || { echo "ABORT: the PR head is $HEAD_AFTER, not the $HEAD_BEFORE just pushed."; exit 1; }
fi

# THE PASS THE PUSH STARTED MUST FINISH FIRST — but only when there WAS one. A
# round that ends without a new commit (a dismissal, or a finding answered rather
# than coded around) leaves the push a no-op, so nothing was queued and waiting
# for it would re-arm every timeout forever. Copilot is never triggered by a push
# at all.
if [ "$WHO" != "$COPILOT_BOT" ] && [ "$PUSH_FROM" != "$HEAD_AFTER" ]; then
    "$_RB_SELF_DIR"/pr-watch.sh "$PR" "$WHO" --after-review "$PUSH_BASE"; PUSHPASS_RC=$?
    case "$PUSHPASS_RC" in
        0) ;;
        1) echo "ABORT: the pass the push started has not finished; its result would answer the next request."; exit 1 ;;
        *) echo "ABORT: could not observe the pass the push started (rc=$PUSHPASS_RC)"; exit 1 ;;
    esac
fi

request_review || exit 1
echo "PR_ROUND_CLOSED pr=$PR reviewer=$WHO head=$HEAD_AFTER mode=push prior-review=$RB_PRIOR_REVIEW"
exit 0
