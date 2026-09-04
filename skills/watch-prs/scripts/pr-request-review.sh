#!/usr/bin/env -S bash -p
# A last-resort refusal: `$-` proves the mode, not how the shell got there.
if [[ $- != *p* ]]; then
    echo "ABORT: reason=not_privileged" >&2
    exit 1
fi

# No `-e`: statuses are control flow here.
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "ABORT: reason=lib_dir_unresolvable" >&2; exit 1; }
unset -f rb_load 2>/dev/null || { echo "ABORT: reason=loadlib_stale_definition" >&2; exit 1; }
# The bootstrap cannot use the loader. The refusing stub is what stops an empty `loadlib.sh` from
# leaving `rb_load` to `PATH`, and the first load's 127 is the stub's rather than the loader's.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || { echo "ABORT: reason=loadlib_unreadable" >&2; exit 1; }
# No `2>&1`: nothing goes to stdout from here, and stderr is where every reason goes.
rb_load "$_RB_SELF_DIR" recordlib rb_reserved_marker_line "ABORT:" || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "ABORT: reason=loadlib_empty" >&2
    exit 1; }
rb_load "$_RB_SELF_DIR" recordlib rb_review_trigger "ABORT:" || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "ABORT:" var || exit 1
rb_load "$_RB_SELF_DIR" identitylib rb_identity "ABORT:" || exit 1
rb_load "$_RB_SELF_DIR" writelib rb_write_handoff "ABORT:" || exit 1
rb_identity || { echo "ABORT: reason=$RB_IDENTITY_REASON" >&2; exit 1; }

# A third positional is refused rather than ignored, and the baseline path is an option rather than
# a positional, so a caller passing a body file there cannot have it overwritten with the baseline.
{ [ "$#" -le 2 ] || { [ "$#" -eq 6 ] && [ "$3" = --baseline-file ] && [ "$5" = --nonce ]; }; } \
    || { echo "ABORT: this takes <pr> <auto-review> --baseline-file <path> --nonce <digits> and the body on stdin (got $# — a third positional was the body file, and the body is no longer a file; the four-argument form without --nonce is #264's old contract)" >&2; exit 1; }
PR="${1:-}"; AUTO_REVIEW="${2:-}"; BASELINE_FILE="${4:-}"; NONCE="${6:-}"
case "$PR" in
    ""|*[!0-9]*) echo "ABORT: a PR number is required (got '$PR')" >&2; exit 1 ;;
esac
[ -n "$BASELINE_FILE" ] \
    || { echo "ABORT: --baseline-file <path> is required: the review baseline is written into it, and pr-watch.sh --after-review-file reads it back" >&2; exit 1; }
# Checked after the positionals and the path, so a caller missing those is told about them first.
case "$NONCE" in
    ""|*[!0-9]*) echo "ABORT: --nonce needs decimal digits (got '$NONCE'); the baseline is prefixed with it and pr-watch.sh --require-nonce refuses any other" >&2; exit 1 ;;
esac
# No default and no truthiness test: the two wrong answers are a duplicate pass and a review
# nobody asked for, and the setting cannot be probed from `gh`.
case "$AUTO_REVIEW" in
    yes|no) ;;
    "") echo "ABORT: the auto-review mode is required: 'yes' if Codex automatic review is on for this repository, 'no' if it is not" >&2; exit 1 ;;
    *) echo "ABORT: '$AUTO_REVIEW' is not an auto-review mode; expected 'yes' or 'no'" >&2; exit 1 ;;
esac
# On stdin, read whole and first: a file would be written by a `cat` in the driver's shell, a
# heredoc would splice the account into shell source, and everything below must see stdin at EOF.
BODY="$(cat)" || { echo "ABORT: could not read the request body from stdin." >&2; exit 1; }
[ -n "$BODY" ] || { echo "ABORT: the request body is empty." >&2; exit 1; }

if _marker="$(rb_reserved_marker_line "$BODY")"; then
    echo "ABORT: the request body starts a line with a marker the loop reads as a record: $_marker" >&2
    echo "It would be posted under your identity and honoured. Indent it by four spaces, or quote it inline with backticks — either still says what you meant. A fenced block does NOT help: the line inside it still starts at column 0, which is all the readers look at." >&2
    exit 1
fi

# Only where a pass is already queued: on the manual path this helper writes the mention itself.
if [ "$AUTO_REVIEW" = "yes" ]; then
    rb_review_trigger "$BODY"; _trig_rc=$?
    case "$_trig_rc" in
        1) ;;
        0) echo "ABORT: automatic review is on, so a pass over this head is already queued — and this body contains '@codex review', which queues a second one." >&2
           echo "That is the duplicate pass this path exists to avoid: two passes, two sets of findings, one round. Break the mention up, or write it without the @." >&2
           exit 1 ;;
        *) echo "ABORT: could not tell whether the request body requests a review (rc=$_trig_rc)" >&2; exit 1 ;;
    esac
fi

# No baseline on the automatic path: the trigger preceded this helper, so a lookup could capture
# the very pass being waited for. Read immediately before the request, never earlier.
PRIOR=""
if [ "$AUTO_REVIEW" = "no" ]; then
    PRIOR=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh review-id "$PR" "$RB_CODEX_BOT") \
        || { echo "ABORT: could not read the current review id; do not request a review blind." >&2; exit 1; }
fi

# Written before the post with its status taken, since after the post there is nothing left to
# refuse with; `none` rather than empty, which the watch refuses; the nonce names this request.
_rb_wh="$(rb_write_handoff "$BASELINE_FILE" "$NONCE ${PRIOR:-none}")" \
    || { echo "ABORT: the review baseline could not be written; nothing has been posted: $_rb_wh" >&2; exit 1; }

# One comment on the manual path: the mention is the trigger, and an account posted apart from
# it is one the pass may not read.
if [ "$AUTO_REVIEW" = "yes" ]; then
    gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "$BODY" >&2 \
        || { echo "ABORT: could not post the PR context — do not enter the wait step." >&2; exit 1; }
else
    gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "@codex review

$BODY" >&2 \
        || { echo "ABORT: could not post the @codex request — do not enter the wait step." >&2; exit 1; }
fi
exit 0
