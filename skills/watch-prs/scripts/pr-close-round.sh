#!/usr/bin/env -S bash -p
# A last-resort refusal: `$-` proves the mode, not how the shell got there.
if [[ $- != *p* ]]; then
    echo "ABORT: reason=not_privileged"
    exit 1
fi

# No `-e`: statuses are control flow here.
set -uo pipefail

# A parameter expansion rather than `$(cd … && pwd)`: nothing fallible may stand above the clearing
# below, and a source with no `/` in it is this directory.
_RB_LIB_DIR="${BASH_SOURCE[0]%/*}"
[[ $_RB_LIB_DIR = "${BASH_SOURCE[0]}" ]] && _RB_LIB_DIR=.
# Emptied before any refusal can happen, since the driver reads the head file after the gate's `if` and
# a walked-past refusal would hand it a previous round's OID; reached without the loader, behind a refusing stub.
if [[ ${1:-} = gate ]] && [[ -n ${6:-} ]] && [[ -f ${6} ]] && [[ ${6} = */* ]] \
   && [[ -n ${4:-} ]] && [[ ! ${6} -ef ${4} ]]; then
    _rb_eh="$(/usr/bin/env bash -p -c \
        'rb_empty_handoff() { return 127; }; . "$1"/writelib.sh 2>/dev/null || exit 9; rb_empty_handoff "$2"' \
        _ "$_RB_LIB_DIR" "${6}")" || {
        echo "ABORT: the head file '${6}' exists and cannot be emptied; a stale head would be left for the driver to accept: $_rb_eh"
        exit 1
    }
fi
# The same for the baseline, otherwise the previous round's for the watch to accept. Both arms take only
# an existing file whose name holds a `/`, since a commit id has none, and never the summary, whose emptying destroys the account.
if [[ ${1:-} = gate ]] && [[ -n ${7:-} ]] && [[ -f ${7} ]] && [[ ${7} = */* ]] \
   && [[ -n ${4:-} ]] && [[ ! ${7} -ef ${4} ]] \
   && { [[ -z ${6:-} ]] || [[ ! ${7} -ef ${6} ]]; }; then
    _rb_eh="$(/usr/bin/env bash -p -c \
        'rb_empty_handoff() { return 127; }; . "$1"/writelib.sh 2>/dev/null || exit 9; rb_empty_handoff "$2"' \
        _ "$_RB_LIB_DIR" "${7}")" || {
        echo "ABORT: the prior file '${7}' exists and cannot be emptied; a stale baseline would be left for the driver to accept: $_rb_eh"
        exit 1
    }
fi

# Canonicalised only now, below the clearing, since the canonicalisation can fail.
_RB_SELF_DIR="$(cd -- "$_RB_LIB_DIR" && pwd)" || {
    echo "ABORT: reason=lib_dir_unresolvable"; exit 1; }
unset -f rb_load 2>/dev/null || { echo "ABORT: reason=loadlib_stale_definition"; exit 1; }
# The bootstrap cannot use the loader. The refusing stub is what stops an empty `loadlib.sh` from
# leaving `rb_load` to `PATH`, and the first load's 127 is the stub's rather than the loader's.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || { echo "ABORT: reason=loadlib_unreadable"; exit 1; }
# `2>&1` on each: everything this stage says is stdout, and the loader reports on stderr.
rb_load "$_RB_SELF_DIR" recordlib sha_reason "ABORT:" 2>&1 || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "ABORT: reason=loadlib_empty"
    exit 1; }
# After the first load, which is the one that names an empty loader.
rb_load "$_RB_SELF_DIR" writelib rb_write_handoff "ABORT:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" writelib rb_empty_handoff "ABORT:" 2>&1 || exit 1

# Both logins through `rb_load`, or an exported one from the environment is accepted as library data.
rb_load "$_RB_SELF_DIR" recordlib rb_reserved_marker_line "ABORT:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_review_trigger "ABORT:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "ABORT:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_COPILOT_BOT "ABORT:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" identitylib rb_identity "ABORT:" 2>&1 || exit 1
rb_identity || { echo "ABORT: reason=$RB_IDENTITY_REASON"; exit 1; }
# Copied before `rb_identity` runs again below against origin's push URLs and overwrites these.
RB_PIN_HOST="$HOST"; RB_PIN_OWNER="$OWNER"; RB_PIN_REPO="$REPO"
{ [ "$RB_PIN_HOST" = "$HOST" ] && [ "$RB_PIN_OWNER" = "$OWNER" ] && [ "$RB_PIN_REPO" = "$REPO" ]; } \
    || { echo "ABORT: the pinned identity could not be captured; one of RB_PIN_HOST/OWNER/REPO is readonly."; exit 1; }
COPILOT_BOT="$RB_COPILOT_BOT"

# No default: the stage a forgetful caller would get is the one that skips the threads.
STAGE="${1:-}"
case "$STAGE" in
    gate|post) ;;
    "") echo "ABORT: a stage is required: 'gate' (push and prove the head) or 'post' (summarise and request), with the thread replies in between"; exit 1 ;;
    *) echo "ABORT: '$STAGE' is not a stage; expected 'gate' or 'post' — the thread replies go between them"; exit 1 ;;
esac
shift

PR="${1:-}"; WHO="${2:-}"; SUMMARY_FILE="${3:-}"; AUTO_REVIEW="${4:-}"; HEAD_FILE="${5:-}"; PRIOR_FILE="${6:-}"; NONCE="${7:-}"
# The head crosses in a file, since an assignment in the driving shell after the push fails silently
# on a readonly name; a sha in this position is a caller passing the head itself, refused by name.
[ -n "$HEAD_FILE" ] \
    || { echo "ABORT: a head file is required: 'gate' writes the head it proved into it and 'post' reads it back."; exit 1; }
if sha_reason "$HEAD_FILE" >/dev/null 2>&1; then
    echo "ABORT: the fifth argument is now the head FILE, not the head itself (got what looks like an OID: '$HEAD_FILE'). 'gate' writes the head into that file and 'post' reads it back."
    exit 1
fi
# Both identities: equal strings catch the plain case before either file exists, `-ef` a hard link
# or a symlink, which is the same file under two names.
if [[ $HEAD_FILE = "$SUMMARY_FILE" ]] || [[ $HEAD_FILE -ef $SUMMARY_FILE ]]; then
    echo "ABORT: the head file and the summary file are the same file ('$HEAD_FILE'); the head would overwrite the account and be posted as this round's summary."
    exit 1
fi
# The baseline file gets the same checks: aliased to the summary it overwrites the account, aliased
# to the head file it overwrites what `post` re-proves against.
[ -n "$PRIOR_FILE" ] \
    || { echo "ABORT: a prior file is required: 'post' writes the review baseline into it and the driver reads it back."; exit 1; }
if [ "$PRIOR_FILE" = "$SUMMARY_FILE" ] || [ "$PRIOR_FILE" -ef "$SUMMARY_FILE" ] 2>/dev/null; then
    echo "ABORT: the prior file and the summary file are the same file ('$PRIOR_FILE'); the baseline would overwrite the account."
    exit 1
fi
# `post` prefixes the baseline with the nonce the driver hands to `pr-watch.sh --require-nonce`;
# `gate` writes no baseline, so a nonce given to it is a caller confusing the stages, refused below its emptyings.
if [ "$STAGE" = post ]; then
    case "$NONCE" in
        ""|*[!0-9]*) echo "ABORT: 'post' takes a seventh argument, the request nonce, as decimal digits (got '$NONCE'); the baseline is prefixed with it and pr-watch.sh --require-nonce refuses any other."; exit 1 ;;
    esac
fi
if [ "$PRIOR_FILE" = "$HEAD_FILE" ] || [ "$PRIOR_FILE" -ef "$HEAD_FILE" ] 2>/dev/null; then
    echo "ABORT: the prior file and the head file are the same file ('$PRIOR_FILE'); the baseline would overwrite the head 'post' re-proves against."
    exit 1
fi
if [ "$STAGE" = gate ]; then
    # By rename rather than `>`, which follows a symlink. Do not write the `none` token here: it
    # claims there was no prior review, which this gate has not established.
    _rb_wh="$(rb_empty_handoff "$HEAD_FILE")" \
        || { echo "ABORT: could not empty the head file '$HEAD_FILE': $_rb_wh"; exit 1; }
    _rb_wh="$(rb_empty_handoff "$PRIOR_FILE")" \
        || { echo "ABORT: could not empty the prior file '$PRIOR_FILE': $_rb_wh"; exit 1; }
    # Only after the emptyings, so this refusal cannot leave a stale head for a walked-past `exit`.
    [ -z "$NONCE" ] \
        || { echo "ABORT: 'gate' takes six arguments; the request nonce ('$NONCE') belongs to 'post', which writes the baseline. 'gate' only empties it, and it has: the head and prior files are empty."; exit 1; }
fi

case "$PR" in
    ""|*[!0-9]*) echo "ABORT: a PR number is required (got '$PR')"; exit 1 ;;
esac
# Every branch below asks "is this Copilot?" and treats everything else as Codex, so a third login is refused.
case "$WHO" in
    "$RB_CODEX_BOT"|"$RB_COPILOT_BOT") ;;
    "") echo "ABORT: a reviewer login is required"; exit 1 ;;
    *) echo "ABORT: '$WHO' is not a reviewer this loop drives (expected $RB_CODEX_BOT or $RB_COPILOT_BOT)"; exit 1 ;;
esac
[ -n "$SUMMARY_FILE" ] || { echo "ABORT: a summary file is required"; exit 1; }
# A bare `git push` sends whatever branch the checkout is on to wherever configuration says; the
# refspec names the one ref that may be written, and the branch comparison tells the operator they are in the wrong worktree.
rb_push_is_the_prs() {
    local _want _cross _pair _pushurl _have
    # One call joined by a tab, which a ref name cannot contain.
    _pair=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefName,isCrossRepository \
        --jq '.headRefName + "\t" + (.isCrossRepository | tostring)' 2>/dev/null) \
        || { echo "ABORT: could not read the PR's head branch; refusing to push blind."; return 1; }
    _want="${_pair%%$'\t'*}"
    _cross="${_pair#*$'\t'}"
    [ -n "$_want" ] || { echo "ABORT: the PR reports no head branch; refusing to push blind."; return 1; }
    # `isCrossRepository` rather than comparing names, which differ in case without being different repositories.
    case "$_cross" in
        false) ;;
        true) echo "ABORT: PR $PR is from a fork; this loop does not push to forks."; return 1 ;;
        *) echo "ABORT: could not tell whether PR $PR is from a fork (got '$_cross'); refusing to push blind."; return 1 ;;
    esac
    # Every push URL, since `git push origin` sends to all of them; each parsed by `rb_identity` in a
    # subshell and compared case-insensitively, since casing is not a different repository.
    _pushurl=$(git remote get-url --push --all origin 2>/dev/null) \
        || { echo "ABORT: could not read origin's push URLs; refusing to push blind."; return 1; }
    [ -n "$_pushurl" ] || { echo "ABORT: origin has no push URL; refusing to push blind."; return 1; }
    local _rest="$_pushurl" _u _nl='
'
    while [ -n "$_rest" ]; do
        case "$_rest" in
            *"$_nl"*) _u="${_rest%%"$_nl"*}"; _rest="${_rest#*"$_nl"}" ;;
            *)        _u="$_rest"; _rest="" ;;
        esac
        [ -n "$_u" ] || continue
        ( shopt -s nocasematch
          REVIEW_BUS_REMOTE="$_u"; REVIEW_BUS_OWNER=''; REVIEW_BUS_REPO=''
          rb_identity && [[ $HOST == "$RB_PIN_HOST" ]] && [[ $OWNER == "$RB_PIN_OWNER" ]] && [[ $REPO == "$RB_PIN_REPO" ]] ) \
            || { echo "ABORT: origin pushes to '$_u', which is not $RB_PIN_HOST/$RB_PIN_OWNER/$RB_PIN_REPO; refusing to push elsewhere."; return 1; }
    done
    # Not `--short`, which keeps `heads/` where a tag shares the name; `refs/heads/` is removed only as a prefix.
    _have=$(git symbolic-ref --quiet HEAD 2>/dev/null) \
        || { echo "ABORT: this checkout is not on a branch (detached HEAD); a push here would not reach PR $PR."; return 1; }
    case "$_have" in
        refs/heads/*) _have="${_have#refs/heads/}" ;;
        *) echo "ABORT: HEAD points at '$_have', which is not a branch; a push here would not reach PR $PR."; return 1 ;;
    esac
    [[ $_have = "$_want" ]] \
        || { echo "ABORT: this checkout is on '$_have' and PR $PR is for '$_want'; refusing to push the wrong branch."; return 1; }
    RB_PUSH_REFSPEC="HEAD:refs/heads/$_want"
    [[ $RB_PUSH_REFSPEC = "HEAD:refs/heads/$_want" ]] \
        || { echo "ABORT: RB_PUSH_REFSPEC is readonly in this shell; the push destination cannot be pinned."; return 1; }
    return 0
}

# Refused rather than assumed: a wrong guess closes the round in the wrong order, visible only afterwards.
case "$AUTO_REVIEW" in
    yes|no) ;;
    *) echo "ABORT: auto-review must be 'yes' or 'no' (got '$AUTO_REVIEW')"; exit 1 ;;
esac
if [ "$AUTO_REVIEW" = no ]; then _MODE=mention; else _MODE=push; fi

# Read with its status taken before anything is pushed or posted: a truncated summary looks complete.
SUMMARY="$(cat "$SUMMARY_FILE")" || { echo "ABORT: could not read the round summary."; exit 1; }
[ -n "$SUMMARY" ] || { echo "ABORT: the round summary is empty."; exit 1; }
# A Copilot round's summary must not carry the Codex mention, which requests a pass on its own; in a
# Codex round this script writes the mention itself, so a quoted one changes nothing.
if [ "$WHO" = "$COPILOT_BOT" ]; then
    rb_review_trigger "$SUMMARY"; _trig_rc=$?
    case "$_trig_rc" in
        1) ;;
        0) echo "ABORT: this is a Copilot round and the summary contains '@codex review', which requests a Codex pass on its own."
           echo "Only Copilot should be re-requested here. Break the mention up, or describe it without the @."
           exit 1 ;;
        *) echo "ABORT: could not tell whether the round summary requests a review (rc=$_trig_rc)"; exit 1 ;;
    esac
fi
if _marker="$(rb_reserved_marker_line "$SUMMARY")"; then
    echo "ABORT: the round summary starts a line with a marker the loop reads as a record: $_marker"
    echo "It would be posted under your identity and honoured. Indent it by four spaces, or quote it inline with backticks — either still says what you meant. A fenced block does NOT help: the line inside it still starts at column 0, which is all the readers look at."
    exit 1
fi

# In `gate` only, before any way a review can be requested — with auto-review on the push is the
# request; by `post` the round is irreversibly half-closed.
if [ "$STAGE" = gate ]; then
    /usr/bin/env bash -p "$_RB_SELF_DIR"/pr-round-count.sh "$PR" "$WHO"; ROUNDS_RC=$?
    case "$ROUNDS_RC" in
        0) ;;
        3) echo "PAUSE: round boundary reached. Decide with the operator before requesting the next pass: continue, merge, leave it open, or close this PR and start over with a better approach. Say what the rounds have been ABOUT, not just how many"
           exit 3 ;;
        *) echo "ABORT: could not establish the round count (rc=$ROUNDS_RC)"; exit 1 ;;
    esac
fi

report_gated() {
    # The write first, with its status taken: the library proves the bytes crossed, and `post`
    # proves the sha is the right one.
    _rb_wh="$(rb_write_handoff "$HEAD_FILE" "$1")" \
        || { echo "ABORT: could not write the gated head to '$HEAD_FILE'; 'post' would have nothing to read: $_rb_wh"; return 1; }
    echo "PR_ROUND_GATED pr=$PR reviewer=$WHO head=$1 mode=$_MODE"
    return 0
}

request_review() {
    # Read immediately before the request: a pass that finished during the CI wait must not be
    # accepted as the answer to a request made after it.
    local prior _back
    prior=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh review-id "$PR" "$WHO") \
        || { echo "ABORT: could not read the current review id; do not request a review blind."; return 1; }
    # Written before the request with its status taken, since after it there is nothing left to
    # refuse with; `none` rather than empty, which the watch refuses; prefixed with the nonce.
    prior="${prior:-none}"
    _rb_wh="$(rb_write_handoff "$PRIOR_FILE" "$NONCE $prior")" \
        || { echo "ABORT: could not write the review baseline to '$PRIOR_FILE'; nothing has been posted: $_rb_wh"; return 1; }
    # Copilot is requested with `--add-reviewer` and never by a mention or a push; the Codex mention
    # carries the summary in the one comment, since a separate one is one the pass may not read.
    if [ "$WHO" = "$COPILOT_BOT" ]; then
        gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "$SUMMARY" \
            || { echo "ABORT: could not post the round summary."; return 1; }
        gh pr edit "$PR" --repo "$HOST/$OWNER/$REPO" --add-reviewer @copilot \
            || { echo "ABORT: could not re-request Copilot."; return 1; }
    else
        gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "@codex review

$SUMMARY" \
            || { echo "ABORT: could not request the review that carries this round's summary."; return 1; }
    fi
    # For the record only; the driver reads the file.
    RB_PRIOR_REVIEW="$prior"
    return 0
}

if [ "$STAGE" = post ]; then
    # `$(<file)` is a redirection the parser handles, with no `cat` to shadow; an unreadable or empty
    # file is a refusal before anything is posted.
    GATED_HEAD="$(<"$HEAD_FILE")" \
        || { echo "ABORT: could not read the gated head from '$HEAD_FILE'; run 'gate' first."; exit 1; }
    _why="$(sha_reason "$GATED_HEAD")" \
        || { echo "ABORT: the gated head read back from '$HEAD_FILE' is not a full OID ($_why: '$GATED_HEAD')."; exit 1; }
    # Re-proven locally and on the PR: the replies take as long as they take, and a commit or a
    # force-push in between leaves the summary describing one commit while the reviewer reads another.
    HEAD_NOW=$(git rev-parse HEAD) || { echo "ABORT: could not read the local head."; exit 1; }
    [ "$HEAD_NOW" = "$GATED_HEAD" ] \
        || { echo "ABORT: the local head is $HEAD_NOW, not the gated $GATED_HEAD; re-run the gate for what is here now."; exit 1; }
    HEAD_API=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
        || { echo "ABORT: could not confirm the head before posting."; exit 1; }
    _why="$(sha_reason "$HEAD_API")" \
        || { echo "ABORT: the confirmed head is not a full OID ($_why: '$HEAD_API')."; exit 1; }
    [ "$HEAD_API" = "$GATED_HEAD" ] \
        || { echo "ABORT: the PR head is $HEAD_API, not the gated $GATED_HEAD; the round would close on a commit that was never proven."; exit 1; }
    request_review || exit 1
    echo "PR_ROUND_CLOSED pr=$PR reviewer=$WHO head=$GATED_HEAD mode=$_MODE prior-review=$RB_PRIOR_REVIEW"
    exit 0
fi

if [ "$AUTO_REVIEW" = no ]; then
    # The mention is the trigger, so the push is proven green with nothing yet requested.
    HEAD_PUSHED=$(git rev-parse HEAD) || { echo "ABORT: could not read the local head."; exit 1; }
    rb_push_is_the_prs || exit 1
    git push origin "$RB_PUSH_REFSPEC" || { echo "ABORT: push failed; the fixes are not on the PR."; exit 1; }
    /usr/bin/env bash -p "$_RB_SELF_DIR"/pr-ci-gate.sh "$PR" "$HEAD_PUSHED" || exit 1
    report_gated "$HEAD_PUSHED" || exit 1
    exit 0
fi

HEAD_BEFORE=$(git rev-parse HEAD) || { echo "ABORT: could not read the local head."; exit 1; }
# Only for a reviewer a push can trigger: read for Copilot, a transient failure here would stall a
# round that needs only `--add-reviewer`.
PUSH_FROM=""
if [ "$WHO" != "$COPILOT_BOT" ]; then
    PUSH_FROM=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
        || { echo "ABORT: could not read the head this push starts from."; exit 1; }
    _why="$(sha_reason "$PUSH_FROM")" \
        || { echo "ABORT: the pre-push head is not a full OID ($_why: '$PUSH_FROM')."; exit 1; }
fi

# Read before the push, the one ordering here that runs the other way: a fast pass finishes during
# the CI wait, and a baseline taken after it waits for a newer pass nobody requested.
PUSH_BASE=""
if [ "$WHO" != "$COPILOT_BOT" ]; then
    PUSH_BASE=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh review-id "$PR" "$WHO") \
        || { echo "ABORT: could not read the review id before the push."; exit 1; }
fi
rb_push_is_the_prs || exit 1
git push origin "$RB_PUSH_REFSPEC" || { echo "ABORT: push failed; no review was queued and the fixes are not on the PR."; exit 1; }
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-ci-gate.sh "$PR" "$HEAD_BEFORE" || exit 1

# The API can serve the previous head for a moment after a push.
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

# Only where the push moved the head, since a no-op push queues nothing and waiting would re-arm
# forever; rc 4 pauses rather than aborts, since a decision is owed and nothing is wrong.
if [ "$WHO" != "$COPILOT_BOT" ] && [ "$PUSH_FROM" != "$HEAD_AFTER" ]; then
    /usr/bin/env bash -p "$_RB_SELF_DIR"/pr-watch.sh "$PR" "$WHO" --after-review "$PUSH_BASE"; PUSHPASS_RC=$?
    case "$PUSHPASS_RC" in
        0) ;;
        1) echo "ABORT: the pass the push started has not finished; its result would answer the next request."; exit 1 ;;
        4) echo "PAUSE: the pass the push started left only replies — nothing to fix and no signoff. Read it with the operator before closing this round."
           exit 3 ;;
        *) echo "ABORT: could not observe the pass the push started (rc=$PUSHPASS_RC)"; exit 1 ;;
    esac
fi

report_gated "$HEAD_AFTER" || exit 1
exit 0
