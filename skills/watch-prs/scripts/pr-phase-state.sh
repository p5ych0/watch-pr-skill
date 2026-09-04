#!/usr/bin/env -S bash -p
# A last-resort refusal: `$-` proves the mode, not how the shell got there.
if [[ $- != *p* ]]; then
    echo "PR_PHASE status=error reason=not_privileged" >&2
    exit 2
fi

# No `-e`: statuses are control flow here.
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_PHASE status=error reason=lib_dir_unresolvable" >&2; exit 2; }
# The bootstrap cannot use the loader. The refusing stub is what stops an empty `loadlib.sh` from
# leaving `rb_load` to `PATH`, and the first load's 127 is the stub's rather than the loader's.
unset -f rb_load 2>/dev/null || {
    echo "PR_PHASE status=error reason=loadlib_stale_definition" >&2; exit 2; }
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_PHASE status=error reason=loadlib_unreadable" >&2; exit 2; }
rb_load "$_RB_SELF_DIR" recordlib is_full_sha "PR_PHASE status=error" || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "PR_PHASE status=error reason=loadlib_empty" >&2
    exit 2; }
# Both logins through `rb_load`, or an exported one from the environment is accepted as library data.
rb_load "$_RB_SELF_DIR" recordlib rb_review_record "PR_PHASE status=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_replies_only_line "PR_PHASE status=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_signoff_answers "PR_PHASE status=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_answer_at "PR_PHASE status=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_escape_snapshot "PR_PHASE status=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_review_record_is_about "PR_PHASE status=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "PR_PHASE status=error" var || exit 2
rb_load "$_RB_SELF_DIR" recordlib RB_COPILOT_BOT "PR_PHASE status=error" var || exit 2
rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_PHASE status=error" || exit 2
rb_identity || { echo "PR_PHASE status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }

# 0 vouched, 1 no record answers it, 2 a probe could not be read — and 2 is not 1: folded, an
# unreadable probe tells the operator to record a signoff they may already have recorded.
RB_VOUCH_REVIEW_AT=''
RB_VOUCH_REPLIES_AT=''
RB_VOUCH_REVIEW_AT=''
RB_VOUCH_REPLIES_AT=''
rb_phase_vouched() {   # rb_phase_vouched <reviewer> <sha>
    local _line _rc=0 _snap _src=0 _rat _pat
    # Cleared here too: the early returns below never reach the library's own clearing.
    RB_VOUCH_REASON=""
    RB_VOUCH_REVIEW_AT=""
    RB_VOUCH_REPLIES_AT=""
    _line=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$1" 2>&1) || _rc=$?
    case "$_rc" in
        0) ;;
        1) RB_VOUCH_REASON=no_signoff; return 1 ;;
        *) RB_VOUCH_REASON=unreadable; return 2 ;;
    esac
    # One GraphQL response carries the id and both times, so no comparison spans separate reads.
    _snap=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh escape-snapshot "$PR" "$1" "$2") || _src=$?
    case "$_src" in
        0) ;;
        1) RB_VOUCH_REASON=not_the_escape_shape; return 1 ;;
        *) RB_VOUCH_REASON=snapshot_unreadable; return 2 ;;
    esac
    rb_escape_snapshot "$_snap" || { RB_VOUCH_REASON=snapshot_malformed; return 2; }
    _rat="$RB_SNAP_REVIEW_AT"; _pat="$RB_SNAP_REPLY_AT"
    rb_answer_at "$_rat" "$_pat"; _src=$?
    case "$_src" in
        0) ;;
        1) RB_VOUCH_REASON=no_times_for_a_recorded_review; return 2 ;;
        *) RB_VOUCH_REASON=answer_time_unreadable; return 2 ;;
    esac
    # The times travel with the answer, so the stop can print them for the operator.
    RB_VOUCH_REVIEW_AT="$_rat"
    RB_VOUCH_REPLIES_AT="$_pat"
    rb_signoff_answers "$_line" "$RB_ANSWER_AT" "$PR" "$1" "$2"
}

PR="${1:-}"
case "$PR" in
    ""|*[!0-9]*) echo "PR_PHASE status=error reason=bad_pr" >&2; exit 2 ;;
esac

# `sha` prints forty hex or nothing; the shape is checked because the merge gate is pinned to this value.
CODEX_SHA="$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh sha "$PR" "$RB_CODEX_BOT")"; CODEX_RC=$?
case "$CODEX_RC" in
    0) ;;
    1) echo "PR_PHASE pr=$PR status=stopped reason=codex_phase_open"
       echo "The Codex phase is not closed on this PR — there is no recorded signoff, or it was revoked. Run it before merging or opening the Copilot phase."
       exit 1 ;;
    *) echo "PR_PHASE pr=$PR status=error reason=signoff_unreadable rc=$CODEX_RC" >&2; exit 2 ;;
esac
if ! is_full_sha "$CODEX_SHA"; then
    echo "PR_PHASE pr=$PR status=error reason=bad_codex_sha" >&2
    exit 2
fi

# The record is history: the head must still be that commit, and the verdict must still stand on it.
HEAD=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "PR_PHASE pr=$PR status=error reason=head_unreadable" >&2; exit 2; }
if ! is_full_sha "$HEAD"; then
    echo "PR_PHASE pr=$PR status=error reason=bad_head" >&2
    exit 2
fi

# 1 is an answer here: "no Copilot signoff" is what the branch below asks about.
COPILOT_SHA="$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh sha "$PR" "$RB_COPILOT_BOT")"; COPILOT_RC=$?
case "$COPILOT_RC" in
    0|1) ;;
    *) echo "PR_PHASE pr=$PR status=error reason=copilot_signoff_unreadable rc=$COPILOT_RC" >&2; exit 2 ;;
esac

# The malformed-sha case is an arm, not a guard: a returning `exit` cannot fall into "no Copilot
# signoff". The branch turns on which signoff names the head, not on whether a Copilot record exists.
if [[ $COPILOT_RC -eq 0 ]] && ! is_full_sha "$COPILOT_SHA"; then
    echo "PR_PHASE pr=$PR status=error reason=bad_copilot_sha" >&2
    exit 2
    # A reserved word last, so the arm ends non-zero whatever was done to the builtins.
    [[ -n "" ]]
elif [[ $COPILOT_RC -eq 0 ]] && [[ $COPILOT_SHA = "$HEAD" ]]; then
    # After the Copilot phase the Codex signoff is older by design; the Copilot one must stand on the head.
    VERDICT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_COPILOT_BOT" "$COPILOT_SHA"); VERDICT_RC=$?
    case "$VERDICT_RC" in
        0) # THE RECORD, NOT ONLY THE STATUS. A probe that exits 0 while printing
           # nothing, or about another PR, reviewer or head, is not permission to continue.
           if ! rb_review_record "$VERDICT" verdict; then
               echo "PR_PHASE pr=$PR status=error reason=copilot_verdict_unparseable" >&2; exit 2
           fi
           if ! rb_review_record_is_about "$PR" "$RB_COPILOT_BOT" "$COPILOT_SHA"; then
               echo "PR_PHASE pr=$PR status=error reason=copilot_verdict_misaddressed" >&2; exit 2
           fi
           if [[ $RB_REC_VALUE != clean ]]; then
               echo "PR_PHASE pr=$PR status=error reason=copilot_verdict_not_clean" >&2; exit 2
           fi
           # The tail is the caller's rule: `verdict=clean` with `findings=0` truncated away is not clean.
           if [[ $RB_REC_TAIL != " findings=0" ]]; then
               echo "PR_PHASE pr=$PR status=error reason=copilot_verdict_truncated" >&2; exit 2
           fi ;;
        1) # `1` IS TWO ANSWERS. A dismissal reopens the phase; a review whose
           # comments are all replies does not, when a recorded signoff answers it.
           if rb_replies_only_line "$VERDICT" "$PR" "$RB_COPILOT_BOT" "$COPILOT_SHA"; then
               rb_phase_vouched "$RB_COPILOT_BOT" "$COPILOT_SHA"; RB_VOUCH_RC=$?
               if [ "$RB_VOUCH_RC" -eq 2 ]; then
                   echo "PR_PHASE pr=$PR status=error reason=copilot_vouch_unreadable" >&2; exit 2
               fi
               if [ "$RB_VOUCH_RC" -ne 0 ]; then
                   echo "PR_PHASE pr=$PR status=stopped reason=copilot_replies_only_unvouched"
                   echo "Copilot's review of $COPILOT_SHA carried only replies, and no signoff of yours answers it ($RB_VOUCH_REASON)."
                   # Only where a deadline was computed; with nothing recorded the line above has said it.
                   [ -n "$RB_ANSWER_AT" ] && echo "It has to be newer than $RB_ANSWER_AT — the latest of that review (${RB_VOUCH_REVIEW_AT:-none}) and its newest reply (${RB_VOUCH_REPLIES_AT:-none})."
                   echo "Read the comment and record a signoff for that head, or request a review."
                   exit 1
               fi
           else
               echo "PR_PHASE pr=$PR status=stopped reason=copilot_verdict_withdrawn"
               echo "Copilot's recorded signoff no longer stands ($VERDICT) — a review can be dismissed after it was written."
               echo "Treat the Copilot phase as open: request a review before merging."
               exit 1
           fi ;;
        *) echo "PR_PHASE pr=$PR status=error reason=copilot_verdict_unreadable rc=$VERDICT_RC" >&2; exit 2 ;;
    esac
    echo "PR_PHASE pr=$PR state=after-copilot codex-sha=$CODEX_SHA copilot-sha=$COPILOT_SHA head=$HEAD"
    exit 0
else
    # Before the Copilot phase nothing licenses a delta: the head must still be the commit Codex signed.
    if [[ $HEAD != "$CODEX_SHA" ]]; then
        echo "PR_PHASE pr=$PR status=stopped reason=head_moved head=$HEAD codex-sha=$CODEX_SHA"
        echo "The head has moved since that signoff (head=$HEAD signed=$CODEX_SHA)."
        echo "The Codex phase is NOT closed on this head: request a review of it before merging or opening the Copilot phase."
        exit 1
    fi
    VERDICT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); VERDICT_RC=$?
    case "$VERDICT_RC" in
        0) # THE SAME THREE, on the other arm.
           if ! rb_review_record "$VERDICT" verdict; then
               echo "PR_PHASE pr=$PR status=error reason=codex_verdict_unparseable" >&2; exit 2
           fi
           if ! rb_review_record_is_about "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"; then
               echo "PR_PHASE pr=$PR status=error reason=codex_verdict_misaddressed" >&2; exit 2
           fi
           if [[ $RB_REC_VALUE != clean ]]; then
               echo "PR_PHASE pr=$PR status=error reason=codex_verdict_not_clean" >&2; exit 2
           fi
           if [[ $RB_REC_TAIL != " findings=0" ]]; then
               echo "PR_PHASE pr=$PR status=error reason=codex_verdict_truncated" >&2; exit 2
           fi ;;
        1) # THE SAME TWO ANSWERS, on the other arm.
           if rb_replies_only_line "$VERDICT" "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"; then
               rb_phase_vouched "$RB_CODEX_BOT" "$CODEX_SHA"; RB_VOUCH_RC=$?
               if [ "$RB_VOUCH_RC" -eq 2 ]; then
                   echo "PR_PHASE pr=$PR status=error reason=codex_vouch_unreadable" >&2; exit 2
               fi
               if [ "$RB_VOUCH_RC" -ne 0 ]; then
                   echo "PR_PHASE pr=$PR status=stopped reason=codex_replies_only_unvouched"
                   echo "Codex's review of $CODEX_SHA carried only replies, and no signoff of yours answers it ($RB_VOUCH_REASON)."
                   [ -n "$RB_ANSWER_AT" ] && echo "It has to be newer than $RB_ANSWER_AT — the latest of that review (${RB_VOUCH_REVIEW_AT:-none}) and its newest reply (${RB_VOUCH_REPLIES_AT:-none})."
                   echo "Read the comment and record a signoff for that head, or request a review."
                   exit 1
               fi
           else
               echo "PR_PHASE pr=$PR status=stopped reason=codex_verdict_withdrawn"
               echo "The recorded signoff no longer stands ($VERDICT) — a review can be dismissed after it was written."
               echo "Treat the Codex phase as open: request a review before merging or opening the Copilot phase."
               exit 1
           fi ;;
        *) echo "PR_PHASE pr=$PR status=error reason=codex_verdict_unreadable rc=$VERDICT_RC" >&2; exit 2 ;;
    esac
    echo "PR_PHASE pr=$PR state=before-copilot codex-sha=$CODEX_SHA head=$HEAD"
    exit 0
fi
