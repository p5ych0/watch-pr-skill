#!/usr/bin/env bash
# The Codex→Copilot phase transition: record what Codex signed off, and — if the
# operator asks for it — open the Copilot pass on that same head.
#
#   pr-copilot-phase.sh record <pr> <body-file>
#   pr-copilot-phase.sh open   <pr> <codex-sha>
#
#   0  recorded / opened
#   1  stopped  — the reason is on stdout; the phase did NOT advance
#   3  paused   — a round boundary. NOT a refusal: the operator decides
#
# WHY TWO STAGES
#
# Between them is a decision that is not the loop's to make. `record` proves Codex
# clean on an exact head, proves that head's checks, posts the account of the
# phase and writes the signoff onto the PR; then it STOPS and asks. Merging on one
# reviewer's signoff is a legitimate answer, and every Copilot pass costs a round
# of somebody's attention — so the loop must not drift into the second phase just
# because it was pointed that way.
#
# `open` runs only on the answer "open the Copilot phase". It is a separate
# invocation because the operator's answer can arrive in a different session:
# `record` puts the signoff on the PR precisely so a later session can read it
# back with `pr-signoff.sh` and pass the sha here.
#
# WHAT THE CALLER WRITES AND WHAT THIS WRITES
#
# The body file is the model's paragraph about the change and what the Codex phase
# did with it. Everything a machine can be held to — the signoff marker, the sha,
# the trailer note — is composed here, because those are the parts something later
# reads back and none of them can be left to prose. The marker's format is the one
# `pr-signoff.sh` scans for: the name and the sha in backticks, on a line of their
# own, anchored at both ends when read.
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
# check, and an exported `RB_COPILOT_BOT` from the environment is then accepted as
# library data — so this would sign off, or revoke, under whatever account that
# variable named.
rb_load "$_RB_SELF_DIR" recordlib rb_reserved_marker_line "ABORT:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_review_trigger "ABORT:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "ABORT:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_COPILOT_BOT "ABORT:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" identitylib rb_identity "ABORT:" 2>&1 || exit 1
rb_identity || { echo "ABORT: reason=$RB_IDENTITY_REASON"; exit 1; }

# THE STAGE IS FIRST AND HAS NO DEFAULT. The two halves have an operator decision
# between them, so a caller that gets one when it meant the other has either
# skipped the decision or re-asked a question already answered.
STAGE="${1:-}"
case "$STAGE" in
    record|open) ;;
    "") echo "ABORT: a stage is required: 'record' (prove and record the Codex signoff, then ask) or 'open' (start the Copilot pass the operator asked for)"; exit 1 ;;
    *) echo "ABORT: '$STAGE' is not a stage; expected 'record' or 'open'"; exit 1 ;;
esac
shift

PR="${1:-}"
case "$PR" in
    ""|*[!0-9]*) echo "ABORT: a PR number is required (got '$PR')"; exit 1 ;;
esac

if [ "$STAGE" = open ]; then
    # ── THE OPERATOR ASKED FOR THE COPILOT PHASE ───────────────────────────
    CODEX_SHA="${2:-}"
    [ -n "$CODEX_SHA" ] \
        || { echo "ABORT: 'open' needs the head Codex signed off, which 'record' reported and pr-signoff.sh reads back."; exit 1; }
    _why="$(sha_reason "$CODEX_SHA")" \
        || { echo "ABORT: the Codex-signed-off head is not a full OID ($_why: '$CODEX_SHA')."; exit 1; }

    # THE PHASE OPENS ON THE HEAD THAT WAS SIGNED OFF, and the answer can arrive
    # a session later, so this is re-proven rather than assumed. Requesting
    # Copilot while the head has moved past the signoff spends the entire phase
    # on one commit and the merge gate on another, and only the gate finds out.
    # WHETHER THE CODEX PHASE IS STILL OPEN ON THIS COMMIT — one definition, asked
    # TWICE. Every one of these can change while the probes below run without the
    # head moving: another session dismisses the verdict, or posts a Codex
    # revocation to reopen the phase. Checking once at the top proves a state that
    # may not survive to the mutations, so this runs again immediately before them.
    phase_still_open() {
        local head recheck rc record
        head=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
            || { echo "ABORT: could not read the current head; do not open the phase blind."; return 1; }
        _why="$(sha_reason "$head")" \
            || { echo "ABORT: the current head is not a full OID ($_why: '$head')."; return 1; }
        [ "$head" = "$CODEX_SHA" ] \
            || { echo "ABORT: the head is $head, not the $CODEX_SHA Codex signed off; re-run the Codex phase for what is there now."; return 1; }

        # THE VERDICT, because an unchanged head does not mean an unchanged
        # verdict: a review dismissed while the head stood still leaves the
        # equality passing and the recorded signoff describing a phase that is no
        # longer clean.
        recheck=$("$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); rc=$?
        [ "$rc" -eq 0 ] \
            || { echo "ABORT: Codex is no longer clean on $CODEX_SHA ($recheck) — the signoff is history, not a current verdict; do not open the Copilot phase"; return 1; }

        # AND THE RECORDED SIGNOFF, which is the only thing that says the phase was
        # deliberately REOPENED. Reopening posts a revocation and requests a new
        # pass, and GitHub keeps serving the old clean verdict until that pass
        # reports — so the verdict alone still passes on a reopened phase.
        record=$("$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$RB_CODEX_BOT"); rc=$?
        case "$rc" in
            0) ;;
            1) echo "ABORT: there is no current Codex signoff on this PR ($record) — it was revoked or never recorded; do not open the Copilot phase"; return 1 ;;
            *) echo "ABORT: could not read the recorded Codex signoff (rc=$rc)"; return 1 ;;
        esac
        case "$record" in
            *" sha=$CODEX_SHA"*) ;;
            *) echo "ABORT: the recorded Codex signoff is not for $CODEX_SHA ($record); do not open the Copilot phase"; return 1 ;;
        esac
        return 0
    }
    # Once here, so a phase that is already closed costs one round-trip rather than
    # the whole probe sequence.
    phase_still_open || exit 1

    # AND THE BOUNDARY IS ENFORCED AGAIN HERE. `record` publishes the signoff
    # before it pauses, deliberately — so a later session can read that signoff
    # back and arrive here with the boundary still unacknowledged. Checking only in
    # `record` meant the pause was skipped by the very resume path the published
    # signoff exists to enable.
    "$_RB_SELF_DIR"/pr-round-count.sh "$PR" "$RB_CODEX_BOT"; OPEN_ROUNDS_RC=$?
    case "$OPEN_ROUNDS_RC" in
        0) ;;
        3) echo "PAUSE: round boundary reached and not acknowledged. Decide with the operator before opening the Copilot phase: continue, merge on the Codex signoff, leave it open, or close this PR and start over"
           exit 3 ;;
        *) echo "ABORT: could not establish the round count (rc=$OPEN_ROUNDS_RC); nothing revoked or requested"; exit 1 ;;
    esac

    # AND RE-READ ONCE MORE, IMMEDIATELY BEFORE THE MUTATIONS. The probes above
    # take time: a push landing after the equality check but during the verdict or
    # baseline lookup leaves the pinned verdict still clean — it is pinned to the
    # old sha — while the revocation and the request land on the moved PR, and
    # `--add-reviewer` re-requests, so Copilot spends the phase on a head Codex
    # never signed off. The window cannot be closed entirely; it can be made as
    # small as the last check before the call.
    HEAD_STILL=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
        || { echo "ABORT: could not re-confirm the head before opening the phase."; exit 1; }
    _why="$(sha_reason "$HEAD_STILL")" \
        || { echo "ABORT: the re-read head is not a full OID ($_why: '$HEAD_STILL')."; exit 1; }
    [ "$HEAD_STILL" = "$CODEX_SHA" ] \
        || { echo "ABORT: the head moved to $HEAD_STILL while this phase was being proved; nothing was revoked or requested."; exit 1; }

    # …AND SO IS EVERYTHING ELSE THAT CAN CHANGE WITHOUT IT. A dismissal or a Codex
    # revocation posted while the probes above ran leaves the head where it was, so
    # the head check alone would pass and this would revoke Copilot's signoff and
    # request a pass underneath a phase somebody had just reopened.
    phase_still_open || exit 1

    # ANY EXISTING COPILOT SIGNOFF IS REVOKED FIRST. Entering this phase a second
    # time — after a Codex pass that returned clean without moving the head —
    # leaves the previous Copilot signoff naming that same head. Until the new pass
    # reports, GitHub still exposes the old clean verdict, so a resumed or
    # concurrent session takes the post-Copilot path and merges the phase that was
    # just reopened. The revocation is the only record that it WAS reopened.
    #
    # Unconditional: revoking a signoff that does not exist costs one comment, and
    # the branch that decides whether to bother is a branch that can be wrong.
    gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" \
        --body "$(printf '**Review-Signoff-Revoked:** `%s`\n\nOpening a Copilot pass on this head; any earlier Copilot signoff no longer describes it.\n' "$RB_COPILOT_BOT")" \
        || { echo "ABORT: could not revoke the previous Copilot signoff — do not request the pass without it"; exit 1; }

    # AND ONCE MORE, AFTER THE REVOCATION. The check above sits before a mutation
    # and two network calls, so it is not "immediately before the request" — the
    # revocation comment and the baseline lookup are both windows in which Codex's
    # verdict can be dismissed, its signoff revoked, or the head moved. The
    # baseline still has to be read LAST, so this is as close to the request as the
    # two constraints allow.
    phase_still_open || exit 1

    # THE BASELINE IS READ HERE, after the revocation and immediately before the
    # request. Read earlier, a Copilot pass already in flight on this unchanged head
    # could finish during the probes or the revocation — and `pr-watch.sh
    # --after-review` would then accept that pre-request review as the answer to a
    # request made after it, advancing the phase on a pass nobody asked for.
    #
    # Empty is a legitimate answer (no review yet); only a failed read is fatal.
    PRIOR_REVIEW=$("$_RB_SELF_DIR"/pr-review-state.sh review-id "$PR" "$RB_COPILOT_BOT") \
        || { echo "ABORT: could not read the current review id; do not request a review blind."; exit 1; }

    # `--add-reviewer` IS the request. If it fails there is no Copilot pass to wait
    # for, so entering the phase would poll for a review nobody asked for and then
    # report a timeout — which reads as "Copilot is slow", not "Copilot was never
    # asked".
    gh pr edit "$PR" --repo "$HOST/$OWNER/$REPO" --add-reviewer @copilot || {
        echo "ABORT: could not request Copilot — do not enter the Copilot phase."
        echo "This is not permission to skip the pass: decide with the operator."
        exit 1; }

    echo "PR_COPILOT_PHASE_OPENED pr=$PR head=$CODEX_SHA prior-review=$PRIOR_REVIEW"
    exit 0
fi

# ── RECORD WHAT CODEX SIGNED OFF, THEN ASK ─────────────────────────────────
BODY_FILE="${2:-}"
[ -n "$BODY_FILE" ] \
    || { echo "ABORT: a body file is required: the paragraph saying what the PR does and what the Codex phase changed."; exit 1; }
# READ WITH ITS STATUS TAKEN, before anything is posted. A partial read still
# produces a successful `gh pr comment`, and the reviewer contract makes the newest
# summary the thing read before the diff — so a truncated one is worse than none:
# it looks complete.
BODY="$(cat "$BODY_FILE")" || { echo "ABORT: could not read the phase body."; exit 1; }
[ -n "$BODY" ] || { echo "ABORT: the phase body is empty; say what the Codex phase changed."; exit 1; }
# THE BODY IS PROSE, AND MUST NOT BECOME A RECORD. It is composed from findings,
# PR descriptions and reviewer comments, and this comment is posted under an
# identity `pr-signoff.sh` and `pr-round-count.sh` trust — so a line reproducing
# one of their markers CREATES the record it was describing. A quoted finding
# about an acknowledgement becomes the acknowledgement, and the round boundary it
# answers never fires again.
# AND MUST NOT REQUEST A REVIEW EITHER. This summary is posted on its own and the
# script stops for the operator immediately afterwards, so a body quoting
# `@codex review` — out of a PR description, a finding, or this repository's own
# documentation — starts a Codex pass against a phase that has just stopped.
rb_review_trigger "$BODY"; _trig_rc=$?
case "$_trig_rc" in
    1) ;;
    0) echo "ABORT: the phase body contains '@codex review', which requests a Codex pass on its own."
       echo "This summary is posted standalone and the loop stops after it, so that pass would answer nobody. Break the mention up, or describe it without the @."
       exit 1 ;;
    *) echo "ABORT: could not tell whether the phase body requests a review (rc=$_trig_rc)"; exit 1 ;;
esac
if _marker="$(rb_reserved_marker_line "$BODY")"; then
    echo "ABORT: the phase body starts a line with a marker the loop reads as a record: $_marker"
    echo "It would be posted under your identity and honoured. Indent it by four spaces, or quote it inline with backticks — either still says what you meant. A fenced block does NOT help: the line inside it still starts at column 0, which is all the readers look at."
    exit 1
fi

# THE HEAD THE CLEAN VERDICT DESCRIBED, re-read and then re-validated — not
# whatever `gh pr view` reports now. If a push lands between the verdict and this
# lookup, recording the new, unreviewed head as the Codex signoff requests Copilot
# against it, and the final gate only discovers the missing Codex verdict after the
# whole Copilot phase has run.
CODEX_SHA=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not capture the Codex-signed-off head; do not start the Copilot phase"; exit 1; }
_why="$(sha_reason "$CODEX_SHA")" \
    || { echo "ABORT: the captured head is not a full OID ($_why: '$CODEX_SHA'); do not start the Copilot phase"; exit 1; }

# RE-VALIDATED ON EXACTLY THAT SHA. If it is not clean, the head moved and the
# phase must not advance.
# THE SIGNOFF RECORD AS IT STANDS BEFORE ANY OF THIS, captured so an intervening
# change is visible later. It is not validated here — there may legitimately be
# none, or a revocation this very pass is answering — only remembered.
SIGNOFF_BEFORE=$("$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$RB_CODEX_BOT" 2>&1); SIGNOFF_BEFORE_RC=$?
case "$SIGNOFF_BEFORE_RC" in
    0|1) ;;
    *) echo "ABORT: could not read the current Codex signoff record (rc=$SIGNOFF_BEFORE_RC): $SIGNOFF_BEFORE"; exit 1 ;;
esac

CODEX_RECHECK=$("$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); CODEX_RECHECK_RC=$?
[ "$CODEX_RECHECK_RC" -eq 0 ] \
    || { echo "ABORT: Codex is not clean on the sha being recorded ($CODEX_RECHECK) — the head moved; do not start the Copilot phase"; exit 1; }

# THE CHECKS ON THAT HEAD, TOO. The CI gate lives at the push sites in step 5, and
# a PR whose first review is clean never enters step 5 at all — so a head with a
# failing check could pass through both phases untouched, and the merge gate looks
# only at REQUIRED checks, which a failing optional one is not. Every path that
# accepts a verdict as phase-completing has to have seen the checks, not just the
# paths that pushed something.
"$_RB_SELF_DIR"/pr-ci-gate.sh "$PR" "$CODEX_SHA" || exit 1


# THE SIGNOFF IS WRITTEN DOWN, not just printed. This line is the record the next
# session reads: `pr-signoff.sh` scans the PR's comments for it, so closing the
# terminal, changing machine or coming back tomorrow no longer loses the one fact
# the phasing rests on — that Codex is clean on this exact commit. A value that
# only exists in a shell variable is the `/tmp` counter mistake v1 made.
#
# COMPOSED HERE, with `printf` and a validated sha, rather than in the caller's
# prose. The marker is a line of its own and anchored when read, so quoting it
# inside prose signs nothing off — and the caller's body is inserted as data, not
# as a template: a summary that quotes a finding about `$(gh pr view …)`, or lifts
# a backtick-delimited command line out of an untrusted PR description, was
# EXECUTED while being written when this was a heredoc the shell expanded.
# THE BOUNDARY IS ESTABLISHED BEFORE ANYTHING IS PUBLISHED, and acted on after.
# These are two different requirements and the first attempt met only the second:
# a count that could not be read exited 1 with the signoff already posted, so a
# later session's `pr-signoff.sh` accepted that record and could open Copilot or
# take the codex-only merge without anyone having established whether an operator
# boundary was due. An unreadable count is a stop, and a stop must leave nothing
# behind.
"$_RB_SELF_DIR"/pr-round-count.sh "$PR" "$RB_CODEX_BOT"; ROUNDS_RC=$?
case "$ROUNDS_RC" in
    0|3) ;;
    *) echo "ABORT: could not establish the round count (rc=$ROUNDS_RC); nothing recorded"; exit 1 ;;
esac

# PROVED AGAIN, IMMEDIATELY BEFORE PUBLISHING. The checks above are followed by
# two probes, and posting a signoff is the one irreversible thing this stage does:
# a `Review-Signoff` comment written after somebody else's `Review-Signoff-Revoked`
# SUPERSEDES it, because the last record wins. GitHub can still be serving the old
# clean verdict, so a later `open` would then see a current signoff and a clean
# verdict and request Copilot underneath a phase that was deliberately reopened.
#
# The head and the verdict are re-read for the same reason they are in `open` —
# neither needs the head to move.
HEAD_STILL=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not re-confirm the head before recording the signoff."; exit 1; }
[ "$HEAD_STILL" = "$CODEX_SHA" ] \
    || { echo "ABORT: the head moved to $HEAD_STILL while this phase was being proved; nothing was recorded."; exit 1; }
RECHECK_AGAIN=$("$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); RECHECK_AGAIN_RC=$?
[ "$RECHECK_AGAIN_RC" -eq 0 ] \
    || { echo "ABORT: Codex is no longer clean on $CODEX_SHA ($RECHECK_AGAIN); nothing was recorded."; exit 1; }

# AND THE RECORD MUST NOT HAVE MOVED UNDER US. Comparing it whole is the check:
# what matters is that somebody wrote something in between, not what they wrote —
# an intervening revocation and an intervening signoff are both reasons to stop
# and neither needs interpreting.
SIGNOFF_NOW=$("$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$RB_CODEX_BOT" 2>&1); SIGNOFF_NOW_RC=$?
case "$SIGNOFF_NOW_RC" in
    0|1) ;;
    *) echo "ABORT: could not re-read the Codex signoff record (rc=$SIGNOFF_NOW_RC): $SIGNOFF_NOW"; exit 1 ;;
esac
{ [ "$SIGNOFF_NOW_RC" -eq "$SIGNOFF_BEFORE_RC" ] && [ "$SIGNOFF_NOW" = "$SIGNOFF_BEFORE" ]; } \
    || { echo "ABORT: the Codex signoff record changed while this phase was being proved ('$SIGNOFF_BEFORE' -> '$SIGNOFF_NOW'); nothing was recorded."; exit 1; }

SUMMARY="$(printf '## Codex phase complete\n\n**Review-Signoff:** `%s` `%s`\n\nCodex signed off on `%s`.\n\n%s\n\nFix commits from here carry a `Review-Phase: copilot` trailer, which is how the merge gate knows the head advanced only through Copilot fixes and that Codex'"'"'s signoff still covers it.\n' \
    "$RB_CODEX_BOT" "$CODEX_SHA" "$CODEX_SHA" "$BODY")" \
    || { echo "ABORT: could not compose the phase summary."; exit 1; }

gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "$SUMMARY" \
    || { echo "ABORT: could not post the phase summary — the signoff is not recorded; do not request Copilot."; exit 1; }

echo "PR_PHASE_RECORDED pr=$PR reviewer=$RB_CODEX_BOT codex-sha=$CODEX_SHA"

# AND ACTED ON AFTER IT. The pause offers "merge on the Codex signoff" and "leave
# it open", so exiting before the record was posted left the operator neither a
# durable signoff for a later session nor the sha the codex-only merge needs.
# Nothing in this stage requests a review, so publishing before the pause queues
# nothing — the boundary still precedes everything that commits to more work.
[ "$ROUNDS_RC" -ne 3 ] || {
    echo "PAUSE: round boundary reached. Decide with the operator before opening the Copilot phase: continue, merge on the Codex signoff, leave it open, or close this PR and start over"
    exit 3; }

# ── STOP. THE NEXT PHASE IS THE OPERATOR'S DECISION ────────────────────────
# Codex is clean and that is now recorded on the PR. What happens next is not the
# loop's call: merging on one reviewer's signoff is a legitimate place to stop,
# and the phase this would open can run as long as the one just finished.
cat <<EOF

Codex has signed off on $CODEX_SHA, and the signoff is recorded on the PR.

  Decide, and say which:
    (a) merge now on Codex's signoff alone — the merge gate with
        REVIEWERS=codex-only, which requires the head to BE this commit and is
        therefore a narrower gate than the two-reviewer one, not a looser one
    (b) open the Copilot phase on the same head —
        pr-copilot-phase.sh open $PR $CODEX_SHA

Nothing further happens until you say. This is resumable: the signoff is on the
PR, so a later session can read it back with pr-signoff.sh.
EOF
exit 0
