#!/usr/bin/env -S bash -p
# A last-resort refusal: `$-` proves the mode, not how the shell got there.
if [[ $- != *p* ]]; then
    echo "ABORT: reason=not_privileged"
    exit 1
fi

# No `-e`: statuses are control flow here.
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "ABORT: reason=lib_dir_unresolvable"; exit 1; }
unset -f rb_load 2>/dev/null || { echo "ABORT: reason=loadlib_stale_definition"; exit 1; }
# The bootstrap cannot use the loader. The refusing stub is what stops an empty `loadlib.sh` from
# leaving `rb_load` to `PATH`, and the first load's 127 is the stub's rather than the loader's.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || { echo "ABORT: reason=loadlib_unreadable"; exit 1; }
# `2>&1` on every load: the loader reports on stderr and everything this script says is stdout.
# The first load carries `loadlib_empty`, since a 127 there is the stub's and nothing else's.
rb_load "$_RB_SELF_DIR" testlib run_limited "ABORT:" 2>&1 || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "ABORT: reason=loadlib_empty"
    exit 1; }
rb_load "$_RB_SELF_DIR" recordlib sha_reason "ABORT:" 2>&1 || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "ABORT: reason=loadlib_empty"
    exit 1; }
rb_load "$_RB_SELF_DIR" writelib rb_write_handoff "ABORT:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_reserved_marker_line "ABORT:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_review_trigger "ABORT:" 2>&1 || exit 1
# Both constants through the loader: an exported one would otherwise pass as library data.
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "ABORT:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_COPILOT_BOT "ABORT:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" identitylib rb_identity "ABORT:" 2>&1 || exit 1
rb_identity || { echo "ABORT: reason=$RB_IDENTITY_REASON"; exit 1; }

# No default stage: the two halves have an operator decision between them.
STAGE="${1:-}"
case "$STAGE" in
    record|open|close) ;;
    "") echo "ABORT: a stage is required: 'record' (prove and record the Codex signoff, then ask), 'open' (start the Copilot pass the operator asked for) or 'close' (record Copilot's signoff and ask)"; exit 1 ;;
    *) echo "ABORT: '$STAGE' is not a stage; expected 'record', 'open' or 'close'"; exit 1 ;;
esac
shift

PR="${1:-}"
case "$PR" in
    ""|*[!0-9]*) echo "ABORT: a PR number is required (got '$PR')"; exit 1 ;;
esac

# Reserved-word tests throughout: `[` is a name, and these guards decide whether a signoff is recorded at all.
if [[ $STAGE = open ]]; then
    CODEX_SHA="${2:-}"
    [[ -n $CODEX_SHA ]] \
        || { echo "ABORT: 'open' needs the head Codex signed off, which 'record' reported and pr-signoff.sh reads back."; exit 1; }
    _why="$(sha_reason "$CODEX_SHA")" \
        || { echo "ABORT: the Codex-signed-off head is not a full OID ($_why: '$CODEX_SHA')."; exit 1; }

    # In a file as well as in the record, so the driving shell parses nothing.
    PRIOR_FILE="${3:-}"
    [[ -n $PRIOR_FILE ]] \
        || { echo "ABORT: a baseline file is required: 'open' writes the review id it captured into it, and pr-watch.sh --after-review-file reads it back."; exit 1; }
    # Both writes below prefix the file with it, so a baseline left by an earlier request is refused at the watch.
    NONCE="${4:-}"
    case "$NONCE" in
        ""|*[!0-9]*) echo "ABORT: 'open' takes a fourth argument, the request nonce, as decimal digits (got '$NONCE'); the baseline is prefixed with it and pr-watch.sh --require-nonce refuses any other."; exit 1 ;;
    esac
    # The real write, ahead of both mutations, is the readiness proof: a path that cannot take it is found before
    # the revocation, and the sentinel is not a review id, so a refusal walked past fails closed at the watch.
    _rb_wh="$(run_limited 10 /usr/bin/env bash -p -c \
        'rb_write_handoff() { return 127; }; . "$1"/writelib.sh 2>/dev/null || exit 9; rb_write_handoff "$2" "$3"' \
        _ "$_RB_SELF_DIR" "$PRIOR_FILE" "$NONCE refused-no-baseline")" \
        || { echo "ABORT: could not write the baseline file '$PRIOR_FILE'. Nothing has been posted: $_rb_wh"; exit 1; }
    # Asked three times, since a dismissal or a Codex revocation reopens the phase without moving the head,
    # and GitHub serves the old clean verdict until the new pass reports.
    phase_still_open() {
        local head recheck rc record
        head=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
            || { echo "ABORT: could not read the current head; do not open the phase blind."; return 1; }
        _why="$(sha_reason "$head")" \
            || { echo "ABORT: the current head is not a full OID ($_why: '$head')."; return 1; }
        [[ $head = "$CODEX_SHA" ]] \
            || { echo "ABORT: the head is $head, not the $CODEX_SHA Codex signed off; re-run the Codex phase for what is there now."; return 1; }

        # An unchanged head does not mean an unchanged verdict.
        recheck=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); rc=$?
        [[ $rc -eq 0 ]] \
            || { echo "ABORT: Codex is no longer clean on $CODEX_SHA ($recheck) — the signoff is history, not a current verdict; do not open the Copilot phase"; return 1; }

        # The recorded signoff is the only trace of a deliberate reopening while the old verdict is still served.
        record=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$RB_CODEX_BOT"); rc=$?
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
    phase_still_open || exit 1

    # Enforced here too: `record` publishes the signoff before pausing, so a resumed session can arrive
    # with the boundary unacknowledged.
    /usr/bin/env bash -p "$_RB_SELF_DIR"/pr-round-count.sh "$PR" "$RB_CODEX_BOT"; OPEN_ROUNDS_RC=$?
    case "$OPEN_ROUNDS_RC" in
        0) ;;
        3) echo "PAUSE: round boundary reached and not acknowledged. Decide with the operator before opening the Copilot phase: continue, merge on the Codex signoff, leave it open, or close this PR and start over"
           exit 3 ;;
        *) echo "ABORT: could not establish the round count (rc=$OPEN_ROUNDS_RC); nothing revoked or requested"; exit 1 ;;
    esac

    # Re-read immediately before the mutations: the probes above take time and a push can land in them.
    HEAD_STILL=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
        || { echo "ABORT: could not re-confirm the head before opening the phase."; exit 1; }
    _why="$(sha_reason "$HEAD_STILL")" \
        || { echo "ABORT: the re-read head is not a full OID ($_why: '$HEAD_STILL')."; exit 1; }
    [[ $HEAD_STILL = "$CODEX_SHA" ]] \
        || { echo "ABORT: the head moved to $HEAD_STILL while this phase was being proved; nothing was revoked or requested."; exit 1; }

    phase_still_open || exit 1

    # Unconditional: a stale Copilot signoff naming this head would let a resumed session take the post-Copilot
    # path, and a branch deciding whether to bother is a branch that can be wrong.
    gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" \
        --body "$(printf '**Review-Signoff-Revoked:** `%s`\n\nOpening a Copilot pass on this head; any earlier Copilot signoff no longer describes it.\n' "$RB_COPILOT_BOT")" \
        || { echo "ABORT: could not revoke the previous Copilot signoff — do not request the pass without it"; exit 1; }

    phase_still_open || exit 1

    # Read after the revocation and immediately before the request: a pass finishing during the probes would
    # otherwise answer a request made after it.
    PRIOR_REVIEW=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh review-id "$PR" "$RB_COPILOT_BOT") \
        || { echo "ABORT: could not read the current review id; do not request a review blind."; exit 1; }

    # "No prior review" is spelled `none`, since an empty file is a refusal at the watch.
    PRIOR_REVIEW="${PRIOR_REVIEW:-none}"
    # Written before the request with its status taken: after it the phase is irreversibly half-opened.
    _rb_wh="$(run_limited 10 /usr/bin/env bash -p -c \
        'rb_write_handoff() { return 127; }; . "$1"/writelib.sh 2>/dev/null || exit 9; rb_write_handoff "$2" "$3"' \
        _ "$_RB_SELF_DIR" "$PRIOR_FILE" "$NONCE $PRIOR_REVIEW")" \
        || { echo "ABORT: could not write the review baseline to '$PRIOR_FILE'; Copilot has NOT been requested: $_rb_wh"; exit 1; }

    # `--add-reviewer` is the request: without it the watch would time out on a pass nobody asked for.
    gh pr edit "$PR" --repo "$HOST/$OWNER/$REPO" --add-reviewer @copilot || {
        echo "ABORT: could not request Copilot — do not enter the Copilot phase."
        echo "This is not permission to skip the pass: decide with the operator."
        exit 1; }

    echo "PR_COPILOT_PHASE_OPENED pr=$PR head=$CODEX_SHA prior-review=$PRIOR_REVIEW"
    exit 0
fi

if [[ $STAGE = close ]]; then
    CODEX_SHA="${2:-}"
    [[ -n $CODEX_SHA ]] \
        || { echo "ABORT: 'close' needs the head Codex signed off, so the record can say whether the two phases closed on the same commit."; exit 1; }
    _why="$(sha_reason "$CODEX_SHA")" \
        || { echo "ABORT: the Codex-signed-off head is not a full OID ($_why: '$CODEX_SHA')."; exit 1; }

    # `codex-only` means no Copilot review was requested, so there is no verdict to re-check and nothing to record.
    REVIEWERS="${3:-both}"
    case "$REVIEWERS" in
        both) ;;
        codex-only)
            echo "PR_COPILOT_PHASE_CLOSED pr=$PR mode=codex-only copilot-sha=none codex-sha=$CODEX_SHA"
            exit 0 ;;
        *) echo "ABORT: '$REVIEWERS' is not a reviewers mode; expected 'both' or 'codex-only'"; exit 1 ;;
    esac

    COPILOT_SHA=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
        || { echo "ABORT: could not read the head to record the Copilot signoff"; exit 1; }
    _why="$(sha_reason "$COPILOT_SHA")" \
        || { echo "ABORT: the head is not a full OID ($_why: '$COPILOT_SHA'); do not record a signoff for it"; exit 1; }

    # Re-checked on exactly this sha: only the head's shape was checked above, and a push can land while the
    # stop is parked.
    COPILOT_RECHECK=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_COPILOT_BOT" "$COPILOT_SHA"); COPILOT_RECHECK_RC=$?
    [[ $COPILOT_RECHECK_RC -eq 0 ]] \
        || { echo "ABORT: Copilot is not clean on the sha being recorded ($COPILOT_RECHECK) — the head moved; do not record a signoff for it"; exit 1; }

    # Composed here: both shas are validated OIDs and the logins are library constants, so there is no caller
    # text to quote.
    CLOSE_BODY="$(printf '**Review-Signoff:** `%s` `%s`\n\nCopilot signed off on `%s`. Codex signed off on `%s`; if those differ, the older Codex result carries only if the merge gate validates that every commit between them is a Review-Phase: copilot fix.\n' \
        "$RB_COPILOT_BOT" "$COPILOT_SHA" "$COPILOT_SHA" "$CODEX_SHA")" \
        || { echo "ABORT: could not compose the Copilot signoff."; exit 1; }
    gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "$CLOSE_BODY" \
        || { echo "ABORT: could not record the Copilot signoff"; exit 1; }

    echo "PR_COPILOT_PHASE_CLOSED pr=$PR reviewer=$RB_COPILOT_BOT copilot-sha=$COPILOT_SHA codex-sha=$CODEX_SHA"

    # Which question is asked depends on whether the phase produced commits: with equal shas Codex has already
    # reviewed what is merged, and a pass there costs a revocation and a reopened phase over unchanged code.
    if [[ $COPILOT_SHA = "$CODEX_SHA" ]]; then
        cat <<EOF

Copilot signed off on $COPILOT_SHA, and so did Codex — one commit, both
reviewers, and it is the head being merged. Nothing has changed since either
looked, so there is no fault-tolerance pass to run over it.

  Decide, and say which:
    (a) merge — run pr-merge-gate.sh
    (b) stop and leave the PR open

Nothing further happens until you say.
EOF
    else
        cat <<EOF

Copilot signed off on $COPILOT_SHA. Codex signed off on $CODEX_SHA.

Those differ, so Copilot's fixes moved the head after Codex looked at it — the
older Codex result is carried forward ONLY if the merge gate validates that every
commit between them is a Review-Phase: copilot fix, and it refuses if any is not.
That check has not run yet.

  Decide, and say which:
    (a) merge — run pr-merge-gate.sh
    (b) another Codex pass first, as fault tolerance over the Copilot changes.
        POST A REVOCATION BEFORE REQUESTING IT — a comment whose only content is
        the line **Review-Signoff-Revoked:** followed by the Codex login in
        backticks. Without it the old signoff still stands, and a session resumed
        while the new pass is running reads the reopened phase as closed.

Nothing further happens until you say.
EOF
    fi
    exit 0
fi

BODY_FILE="${2:-}"
[[ -n $BODY_FILE ]] \
    || { echo "ABORT: a body file is required: the paragraph saying what the PR does and what the Codex phase changed."; exit 1; }
# The sha goes back in a file: this stage proves it, and asking the API again is a second answer.
SHA_FILE="${3:-}"
[[ -n $SHA_FILE ]] \
    || { echo "ABORT: a sha file is required: 'record' writes the signed-off commit into it for the caller to read back."; exit 1; }
# By path and by `-ef`: the sha would overwrite the account about to be posted.
if [[ $SHA_FILE = "$BODY_FILE" ]] || [[ $SHA_FILE -ef $BODY_FILE ]] 2>/dev/null; then
    echo "ABORT: the sha file and the body file are the same file ('$SHA_FILE'); the sha would overwrite the account."
    exit 1
fi
# Status taken: a partial body still posts successfully, and a truncated summary looks complete.
BODY="$(cat "$BODY_FILE")" || { echo "ABORT: could not read the phase body."; exit 1; }
[[ -n $BODY ]] || { echo "ABORT: the phase body is empty; say what the Codex phase changed."; exit 1; }
# The body is prose posted under a trusted identity: a line reproducing a marker creates the record it
# describes, and a quoted `@codex review` starts a pass against a phase that has just stopped.
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

# The head the verdict described, re-read and re-validated on exactly that sha: a push landing in between
# would record an unreviewed commit as the Codex signoff.
CODEX_SHA=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not capture the Codex-signed-off head; do not start the Copilot phase"; exit 1; }
_why="$(sha_reason "$CODEX_SHA")" \
    || { echo "ABORT: the captured head is not a full OID ($_why: '$CODEX_SHA'); do not start the Copilot phase"; exit 1; }

CODEX_RECHECK=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); CODEX_RECHECK_RC=$?
[[ $CODEX_RECHECK_RC -eq 0 ]] \
    || { echo "ABORT: Codex is not clean on the sha being recorded ($CODEX_RECHECK) — the head moved; do not start the Copilot phase"; exit 1; }

# A PR whose first review is clean never reaches a push site, and a verdict accepted as phase-completing has to
# have seen the checks.
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-ci-gate.sh "$PR" "$CODEX_SHA" || exit 1

# Established before anything is published and acted on after: an unreadable count must leave nothing behind.
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-round-count.sh "$PR" "$RB_CODEX_BOT"; ROUNDS_RC=$?
case "$ROUNDS_RC" in
    0|3) ;;
    *) echo "ABORT: could not establish the round count (rc=$ROUNDS_RC); nothing recorded"; exit 1 ;;
esac

# The CI gate waits, so the window since the proof is as long as a build.
RECHECK_HEAD=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not re-read the head before recording; nothing posted"; exit 1; }
[[ $RECHECK_HEAD = "$CODEX_SHA" ]] \
    || { echo "ABORT: the head moved to $RECHECK_HEAD while the checks were proving; nothing posted"; exit 1; }

# `clean-at` answers whether the head is clean and when from one snapshot, so the time cannot belong to a
# verdict nobody proved; it is the last cleanliness proof before the write.
RB_VERDICT_AT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh clean-at "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); RB_CLEAN_AT_RC=$?
case "$RB_CLEAN_AT_RC" in
    0) ;;
    1) echo "ABORT: Codex is no longer clean on $CODEX_SHA; nothing posted"; exit 1 ;;
    # An unreadable time costs the cleanliness proof too, so that is asked again on its own; the field is
    # optional, and its absence stops the record only where a revocation has to be ordered against it.
    *) RB_VERDICT_AT=""
       echo "note: when the verdict on $CODEX_SHA landed could not be read; the signoff will not carry one"
       RB_STILL_CLEAN=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); RB_STILL_CLEAN_RC=$?
       [[ $RB_STILL_CLEAN_RC -eq 0 ]] \
           || { echo "ABORT: Codex is no longer clean on $CODEX_SHA ($RB_STILL_CLEAN); nothing posted"; exit 1; } ;;
esac
case "$RB_VERDICT_AT" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) RB_VERDICT_AT="" ;;
esac
[[ -n $RB_VERDICT_AT ]] || echo "note: no readable verdict time for $CODEX_SHA; the signoff will not carry one, and a later revocation cannot be ordered against it"

# After the time probes, which are pinned to `$CODEX_SHA` and say nothing about a move. The ordering proof
# goes last: a moved head is caught by `open`, while a revocation the signoff supersedes is unrecoverable.
FINAL_HEAD=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not re-read the head before posting; nothing posted"; exit 1; }
[[ $FINAL_HEAD = "$CODEX_SHA" ]] \
    || { echo "ABORT: the head moved to $FINAL_HEAD while the phase was being proved; nothing posted"; exit 1; }

# The phase is reopened only when the newest revocation is later than the verdict signed off; earlier means
# this pass answers it. The first read is only the trigger, and the record compared is read again afterwards.
RB_TRIGGER=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$RB_CODEX_BOT" 2>&1); RB_TRIGGER_RC=$?
case "$RB_TRIGGER_RC" in
    0|1) ;;
    *) echo "ABORT: could not read the signoff record before recording (rc=$RB_TRIGGER_RC); nothing posted"; exit 1 ;;
esac
case "$RB_TRIGGER" in
*reason=revoked*)
    # With a revocation standing the time is not optional: an empty one would be placed arbitrarily.
    [[ -n $RB_VERDICT_AT ]] \
        || { echo "ABORT: a revocation is the newest record and no verdict on $CODEX_SHA has a readable time; nothing posted"; exit 1; }
    SIGNOFF_NOW=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$RB_CODEX_BOT" 2>&1); SIGNOFF_NOW_RC=$?
    case "$SIGNOFF_NOW_RC" in
        0|1) ;;
        *) echo "ABORT: could not re-read the signoff record before recording (rc=$SIGNOFF_NOW_RC); nothing posted"; exit 1 ;;
    esac
    # Still a revocation, or this stage cannot place what it was about to act on.
    case "$SIGNOFF_NOW" in
        *reason=revoked*) ;;
        *) echo "ABORT: the newest record changed while the verdict's time was read ('$SIGNOFF_NOW'); nothing posted"; exit 1 ;;
    esac
    # `${…##*at=}` on a record without `at=` returns the whole line, which is not a time and must not reach the comparison.
    case "$SIGNOFF_NOW" in
        *" at="*) ;;
        *) echo "ABORT: a revocation is the newest record and carries no time ('$SIGNOFF_NOW'); nothing posted"; exit 1 ;;
    esac
    RB_REVOKED_AT="${SIGNOFF_NOW##* at=}"
    RB_REVOKED_AT="${RB_REVOKED_AT%% *}"
    # Compared as strings, which is the time order only for canonical UTC; a shape sorting low records over a reopening.
    case "$RB_REVOKED_AT" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
        *) echo "ABORT: a revocation is the newest record and its time is unreadable ('$RB_REVOKED_AT'); nothing posted"; exit 1 ;;
    esac
    # Equal refuses: second-resolution times from different resources cannot be tie-broken by id.
    [[ $RB_REVOKED_AT < $RB_VERDICT_AT ]] \
        || { echo "ABORT: this phase was reopened — the revocation at $RB_REVOKED_AT is not older than the verdict at $RB_VERDICT_AT. Recording a signoff now would supersede it; nothing posted"; exit 1; } ;;
esac

# Two shapes rather than an empty backticked field, which `pr-signoff.sh` refuses.
if [[ -n $RB_VERDICT_AT ]]; then
    RB_MARKER="$(printf '**Review-Signoff:** `%s` `%s` `%s`' "$RB_CODEX_BOT" "$CODEX_SHA" "$RB_VERDICT_AT")" \
        || { echo "ABORT: could not compose the signoff marker."; exit 1; }
else
    RB_MARKER="$(printf '**Review-Signoff:** `%s` `%s`' "$RB_CODEX_BOT" "$CODEX_SHA")" \
        || { echo "ABORT: could not compose the signoff marker."; exit 1; }
fi
SUMMARY="$(printf '## Codex phase complete\n\n%s\n\nCodex signed off on `%s`.\n\n%s\n\nFix commits from here carry a `Review-Phase: copilot` trailer, which is how the merge gate knows the head advanced only through Copilot fixes and that Codex'"'"'s signoff still covers it.\n' \
    "$RB_MARKER" "$CODEX_SHA" "$BODY")" \
    || { echo "ABORT: could not compose the phase summary."; exit 1; }

# Written before the post with its status taken, since after it there is nothing left to refuse with; in a
# child because `run_limited` bounds a command and not a function, with a stub so an emptied library refuses.
_rb_wh="$(run_limited 10 /usr/bin/env bash -p -c \
    'rb_write_handoff() { return 127; }; . "$1"/writelib.sh 2>/dev/null || exit 9; rb_write_handoff "$2" "$3"' \
    _ "$_RB_SELF_DIR" "$SHA_FILE" "$CODEX_SHA")" \
    || { echo "ABORT: could not write the signed-off sha to '$SHA_FILE'; nothing has been posted."; exit 1; }

gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "$SUMMARY" \
    || { echo "ABORT: could not post the phase summary — the signoff is not recorded; do not request Copilot."; exit 1; }

echo "PR_PHASE_RECORDED pr=$PR reviewer=$RB_CODEX_BOT codex-sha=$CODEX_SHA"

# Acted on after the record: the pause offers a merge on this signoff, which needs the sha and the durable record.
[[ $ROUNDS_RC -ne 3 ]] || {
    echo "PAUSE: round boundary reached. Decide with the operator before opening the Copilot phase: continue, merge on the Codex signoff, leave it open, or close this PR and start over"
    exit 3; }

cat <<EOF

Codex has signed off on $CODEX_SHA, and the signoff is recorded on the PR.

  Decide, and say which:
    (a) merge now on Codex's signoff alone — the merge gate with
        REVIEWERS=codex-only, which requires the head to BE this commit and is
        therefore a narrower gate than the two-reviewer one, not a looser one
    (b) open the Copilot phase on the same head —
        pr-copilot-phase.sh open $PR $CODEX_SHA <baseline-file> <nonce>
        where <baseline-file> is a writable path this session will hand to
        pr-watch.sh --after-review-file, and <nonce> is the decimal request nonce
        it will hand to pr-watch.sh --require-nonce; the driver uses its own
        \$PRIOR_FILE and generates \$RB_NONCE immediately before the call

Nothing further happens until you say. This is resumable: the signoff is on the
PR, so a later session can read it back with pr-signoff.sh.
EOF
exit 0
