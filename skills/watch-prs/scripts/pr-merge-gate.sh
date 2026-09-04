#!/usr/bin/env -S bash -p
# A last-resort refusal: `$-` proves the mode, not how the shell got there.
if [[ $- != *p* ]]; then
    echo "merge blocked: reason=not_privileged"
    exit 1
fi

# No `-e`: statuses are control flow here.
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "merge blocked: reason=lib_dir_unresolvable"; exit 1; }
# The bootstrap cannot use the loader. The refusing stub is what stops an empty `loadlib.sh` from
# leaving `rb_load` to `PATH`, and the first load's 127 is the stub's rather than the loader's.
unset -f rb_load 2>/dev/null || {
    echo "merge blocked: reason=loadlib_stale_definition"; exit 1; }
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "merge blocked: reason=loadlib_unreadable"; exit 1; }
# `2>&1`: every diagnostic of this gate is stdout, and the loader reports on stderr.
rb_load "$_RB_SELF_DIR" recordlib sha_reason "merge blocked:" 2>&1 || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "merge blocked: reason=loadlib_empty"
    exit 1; }
rb_load "$_RB_SELF_DIR" identitylib rb_identity "merge blocked:" 2>&1 || exit 1
rb_identity || { echo "merge blocked: reason=$RB_IDENTITY_REASON"; exit 1; }

PR="${1:-}"; CODEX_SHA="${2:-}"; AUTO_REVIEW="${3:-}"
case "$PR" in
    ""|*[!0-9]*) echo "merge blocked: the gate needs a PR number (got '$PR')"; exit 1 ;;
esac
# Validated before the head lookup, so a bad argument costs no network round trip.
_why="$(sha_reason "$CODEX_SHA")" || {
    echo "merge blocked: CODEX_SHA is not a full 40-hex sha ($_why: '$CODEX_SHA')"; exit 1; }
# An argument rather than the environment: a value assigned without `export` reaches no child,
# and this one decides whether an in-flight Codex pass may be ignored.
case "$AUTO_REVIEW" in
    yes|no) ;;
    *) echo "merge blocked: the gate needs auto-review as 'yes' or 'no' (got '$AUTO_REVIEW')"; exit 1 ;;
esac
# `codex-only` is refused unless chosen: merging on one reviewer is a decision, not a drift.
REVIEWERS="${4:-both}"
case "$REVIEWERS" in
    both|codex-only) ;;
    *) echo "merge blocked: reviewers must be 'both' or 'codex-only' (got '$REVIEWERS')"; exit 1 ;;
esac
# Both logins through `rb_load`, or an exported one from the environment is accepted as library data.
rb_load "$_RB_SELF_DIR" recordlib rb_review_record "merge blocked:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_replies_only_line "merge blocked:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_signoff_answers "merge blocked:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_answer_at "merge blocked:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_escape_snapshot "merge blocked:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_review_record_is_about "merge blocked:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "merge blocked:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_COPILOT_BOT "merge blocked:" var 2>&1 || exit 1
CODEX_BOT="$RB_CODEX_BOT"; COPILOT_BOT="$RB_COPILOT_BOT"
REPO_DIR="$(git rev-parse --show-toplevel)" || {
    echo "merge blocked: could not resolve the repository root"; exit 1; }

# The head is resolved once; every gate below is addressed to it, or to the head its reviewer judged.
HEAD_RC=0
HEAD_OID=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) || HEAD_RC=$?
if [ "$HEAD_RC" -ne 0 ] || ! _head_why="$(sha_reason "$HEAD_OID")"; then
    echo "merge blocked: head lookup failed (rc=$HEAD_RC ${_head_why:-})"; exit 1
fi

# Codex is asked about the current head first and the recorded signoff is the fallback: always the
# head makes the Copilot phase unmergeable, always the signoff ignores an auto-review pass on a fix.
CODEX_HEAD_STATE=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh state "$PR" "$CODEX_BOT" "$HEAD_OID"); CODEX_STATE_RC=$?
# Only rc 0 is an answer: this branch decides whether to fall back to the older signoff.
if [ "$CODEX_STATE_RC" -ne 0 ]; then
    echo "merge blocked: could not read Codex's state on the current head (rc=$CODEX_STATE_RC)"; exit 1
fi
# The whole record, an empty tail and its identity: a line about another PR, reviewer or head,
# or one carrying an appended field, must not select the fallback.
if rb_review_record "$CODEX_HEAD_STATE" state; then
    CODEX_STATE="$RB_REC_VALUE"
else
    echo "merge blocked: Codex head-state line is unparseable ('$CODEX_HEAD_STATE')"; exit 1
fi
if [ -n "$RB_REC_TAIL" ]; then
    echo "merge blocked: Codex head-state line has trailing text ('$CODEX_HEAD_STATE')"; exit 1
fi
if ! rb_review_record_is_about "$PR" "$CODEX_BOT" "$HEAD_OID"; then
    echo "merge blocked: Codex head-state record is about something else ('$CODEX_HEAD_STATE')"; exit 1
fi
case "$CODEX_STATE" in
    none|pending|reviewed|blocked|dismissed) ;;
    *) echo "merge blocked: unknown Codex head state ('$CODEX_STATE')"; exit 1 ;;
esac
case "$CODEX_STATE" in
    none)
        # With auto-review on, `none` is a pass that has not reported yet, not "nothing to answer".
        if [ "$AUTO_REVIEW" = yes ]; then
            echo "merge blocked: auto-review queues a Codex pass on every push and this head has no verdict yet — wait for it rather than falling back to the signoff on $CODEX_SHA"
            exit 1
        fi
        CODEX_EFFECTIVE_SHA="$CODEX_SHA"
        CODEX_VERDICT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$CODEX_BOT" "$CODEX_SHA"); CODEX_RC=$? ;;
    *)
        # Codex has judged this head, so the range below measures from it rather than the recorded sha.
        CODEX_EFFECTIVE_SHA="$HEAD_OID"
        CODEX_VERDICT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$CODEX_BOT" "$HEAD_OID"); CODEX_RC=$? ;;
esac
# The revocation record is the only trace of a deliberately reopened phase while GitHub still serves
# the old verdict, so it is consulted for a contradiction; nothing recorded is not one.
signoff_contradicts() {
    local who="$1" want="$2" line rc=0 got
    line=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$who" 2>&1) || rc=$?
    case "$rc" in
        0) got="${line##*sha=}"
           if [ "$got" != "$want" ]; then
               echo "merge blocked: the recorded $who signoff names ${got:0:7}, not the ${want:0:7} this merge was asked to use"
               return 1
           fi
           return 0 ;;
        1) case "$line" in
               *reason=revoked*)
                   # `open` posts this revocation on every entry, so the message says a pass is
                   # open rather than reopened.
                   echo "merge blocked: a $who pass is open on this PR and no signoff for it has been recorded"
                   return 1 ;;
               *) return 0 ;;   # nothing recorded; the caller's sha is not contradicted
           esac ;;
        *) echo "merge blocked: could not read the $who signoff record (rc=$rc): $line"; return 1 ;;
    esac
}
# rc 1 is still an answer where the review is all replies; only the record tells that from findings.
replies_only_line() {
    rb_replies_only_line "$3" "$PR" "$1" "$2"
}
rc_answered() {
    [ "$3" -eq 0 ] && return 0
    [ "$3" -eq 1 ] && replies_only_line "$1" "$2" "$4" && return 0
    return 1
}
# Absence refuses here, unlike in `signoff_contradicts`: on the replies-only path the signoff is
# the authority rather than a cross-check.
signoff_vouches() {
    local who="$1" want="$2" line rc=0 snap src=0 rat pat
    line=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$who" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || return 1
    # One GraphQL response carries the id and both times; the signoff record is a separate read,
    # ordered against the deadline those two give.
    snap=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh escape-snapshot "$PR" "$who" "$want") || src=$?
    case "$src" in
        0) ;;
        1) echo "merge blocked: $who has no replies-only review on ${want:0:7} for a signoff to answer"; return 1 ;;
        *) echo "merge blocked: could not read $who's review on ${want:0:7} as one snapshot (rc=$src)"; return 1 ;;
    esac
    rb_escape_snapshot "$snap" || {
        echo "merge blocked: $who's review snapshot on ${want:0:7} is not one this gate can read ('$snap')"; return 1; }
    rat="$RB_SNAP_REVIEW_AT"; pat="$RB_SNAP_REPLY_AT"
    rb_answer_at "$rat" "$pat" || {
        echo "merge blocked: when $who's review or newest reply landed could not be placed in time ('$rat' / '$pat')"; return 1; }
    rb_signoff_answers "$line" "$RB_ANSWER_AT" "$PR" "$who" "$want" && return 0
    case "$RB_VOUCH_REASON" in
        other_head|other_pr|other_reviewer) ;;   # a record about something else; not this gate's to explain
        signoff_malformed) echo "merge blocked: the $who signoff record is not one this gate can read ('$line')" ;;
        # Named as the conversation: the deadline is the later of the review and its newest reply.
        not_after)         echo "merge blocked: the $who signoff was not recorded after ${RB_ANSWER_AT} — the latest of that review (${rat:-none}) and its newest reply (${pat:-none}), so it cannot be an answer to it" ;;
        *)                 echo "merge blocked: the $who signoff does not answer the review on ${want:0:7}" ;;
    esac
    return 1
}

signoff_contradicts "$CODEX_BOT" "$CODEX_SHA" || exit 1

# With no Copilot phase nothing licenses a delta, so the head must be exactly the commit Codex
# signed: a narrower gate than the two-reviewer one, not a looser one.
if [ "$REVIEWERS" = codex-only ]; then
    if [ "$HEAD_OID" != "$CODEX_SHA" ]; then
        echo "merge blocked: codex-only merges must be pinned to the reviewed commit, and the head has moved past it (head=${HEAD_OID:0:7} signed=${CODEX_SHA:0:7}). Request a review of this head, or open the Copilot phase."
        exit 1
    fi
    if ! rc_answered "$CODEX_BOT" "$CODEX_EFFECTIVE_SHA" "$CODEX_RC" "$CODEX_VERDICT"; then
        echo "merge blocked: codex=$CODEX_RC (1 = not clean, 2 = could not tell)"; exit 1
    fi
    COPILOT_VERDICT=""; COPILOT_RC=0
else
    # Copilot is checked on the merge head; nothing range-licenses its delta.
    signoff_contradicts "$COPILOT_BOT" "$HEAD_OID" || exit 1
    COPILOT_VERDICT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$COPILOT_BOT" "$HEAD_OID"); COPILOT_RC=$?
    if ! rc_answered "$CODEX_BOT" "$CODEX_EFFECTIVE_SHA" "$CODEX_RC" "$CODEX_VERDICT" \
       || ! rc_answered "$COPILOT_BOT" "$HEAD_OID" "$COPILOT_RC" "$COPILOT_VERDICT"; then
        echo "merge blocked: codex=$CODEX_RC copilot=$COPILOT_RC (1 = not clean, 2 = could not tell)"; exit 1
    fi
fi
# Positional parameters rather than a `printf | while read` pipeline, whose subshell would swallow
# the `exit 1`. Each record must name its own reviewer and the sha that reviewer judged.
set -- "$CODEX_BOT|$CODEX_EFFECTIVE_SHA|$CODEX_VERDICT"
[ "$REVIEWERS" = codex-only ] || set -- "$@" "$COPILOT_BOT|$HEAD_OID|$COPILOT_VERDICT"
for SPEC in "$@"; do
    V_WHO="${SPEC%%|*}"; V_REST="${SPEC#*|}"; V_SHA="${V_REST%%|*}"; V_LINE="${V_REST#*|}"
    V_OK=1
    rb_review_record "$V_LINE" verdict || V_OK=0
    [ "$V_OK" -eq 0 ] || rb_review_record_is_about "$PR" "$V_WHO" "$V_SHA" || V_OK=0
    [ "$V_OK" -eq 0 ] || [ "$RB_REC_VALUE" = clean ] || V_OK=0
    # The tail is spelled out: a trailing `.*` would accept any field anyone ever appends.
    [ "$V_OK" -eq 0 ] || [ "$RB_REC_TAIL" = " findings=0" ] || V_OK=0
    if [ "$V_OK" -ne 1 ]; then
        # Narrow on purpose: only `source=replies-only`, which an operator's own signoff answers;
        # a review with findings, an unreadable state or a missing verdict is not that question.
        if replies_only_line "$V_WHO" "$V_SHA" "$V_LINE"; then
            if signoff_vouches "$V_WHO" "$V_SHA"; then
                echo "note: $V_WHO left only replies on ${V_SHA:0:7}; merging on the signoff an operator recorded for that head after reading them"
            else
                echo "merge blocked: $V_WHO left only replies on ${V_SHA:0:7} and no operator has recorded a signoff for that head — read the reply and record one, or fix what it says and push"
                exit 1
            fi
        else
            echo "merge blocked: $V_WHO did not return an exact clean record for ${V_SHA:0:7} ('$V_LINE')"; exit 1
        fi
    fi
done

# The range from the commit the verdict describes, not from the recorded sha: measured from the
# older one it would demand Copilot trailers across a range Codex reviewed in full.
if [ "$HEAD_OID" != "$CODEX_EFFECTIVE_SHA" ]; then
    /usr/bin/env bash -p "$_RB_SELF_DIR"/pr-merge-range.sh "$CODEX_EFFECTIVE_SHA" "$HEAD_OID" "$REPO_DIR"; RANGE=$?
    if [ "$RANGE" -ne 0 ]; then
        echo "merge blocked: range check returned $RANGE (1 = an untagged commit, or the Codex-reviewed SHA is not an ancestor; 2 = could not inspect)"; exit 1
    fi
fi

# Every cursor requested is remembered, so a cycle of any length stops rather than hangs; an
# incomplete walk is a refusal, since zero unresolved threads is merge permission.
UNRESOLVED=0; CURSOR=null; OK=1; RS=$'\x1e'; SEEN="${RS}null${RS}"
while :; do
  PAGE=$(gh api --hostname "$HOST" graphql -F number="$PR" -f owner="$OWNER" -f repo="$REPO" -F cursor="$CURSOR" -f query='
    query($owner:String!,$repo:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){
      reviewThreads(first:100, after:$cursor){ pageInfo{hasNextPage endCursor} nodes{isResolved} }}}}' 2>/dev/null) || { OK=0; break; }
  # A GraphQL 200 can carry `errors` beside structurally valid, partial `data`.
  echo "$PAGE" | jq -e 'has("errors") | not' >/dev/null 2>&1 || { OK=0; break; }
  echo "$PAGE" | jq -e '.data.repository.pullRequest.reviewThreads' >/dev/null 2>&1 || { OK=0; break; }
  # `nodes:{}` and `nodes:[{}]` both count zero with status 0, so the shape is required first.
  CNT=$(echo "$PAGE" | jq '
      .data.repository.pullRequest.reviewThreads.nodes as $n
      | if ($n | type) != "array"
           or any($n[]; type != "object" or (.isResolved | type) != "boolean")
        then error("malformed nodes")
        else [ $n[] | select(.isResolved == false) ] | length end') || { OK=0; break; }
  UNRESOLVED=$((UNRESOLVED + CNT))
  HAS_NEXT=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage') || { OK=0; break; }
  case "$HAS_NEXT" in
    false) break ;;
    true)  ;;
    *) OK=0; break ;;
  esac
  NEXT=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor') || { OK=0; break; }
  { [ -n "$NEXT" ] && [ "$NEXT" != "null" ]; } || { OK=0; break; }
  case "$SEEN" in *"$RS$NEXT$RS"*) OK=0; break ;; esac
  SEEN="$SEEN$NEXT$RS"
  CURSOR="$NEXT"
done
if [ "$OK" -ne 1 ] || [ "$UNRESOLVED" -gt 0 ]; then echo "merge blocked: unresolved=$UNRESOLVED ok=$OK"; exit 1; fi

# Every check on the merge head, not only the required ones: a PR whose reviews were clean from the
# start never pushed, so nothing has looked at its checks before this.
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-ci-gate.sh "$PR" "$HEAD_OID" || { echo "merge blocked: the head's checks are not green"; exit 1; }

# Through the same helper with `--required`, addressed to the merge head; on the default `--admin`
# path this is the only thing that asks whether branch protection is satisfied.
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-ci-state.sh "$PR" --required --head "$HEAD_OID"; CHECKS_RC=$?
case "$CHECKS_RC" in
    0) ;;
    4) echo "note: no required checks configured on this branch; the checks gate has nothing to assert" ;;
    1) echo "merge blocked: a required check is not green"; exit 1 ;;
    6) echo "merge blocked: the base branch requires its pull requests to be up to date and this head is behind it; bring the base in and re-run the gate"; exit 1 ;;
    3) echo "merge blocked: the required checks have not finished"; exit 1 ;;
    # 5 is a moved head, not a failed probe: the caller re-runs the gate.
    5) echo "merge blocked: the PR head no longer matches the gated head; re-run the gate for the head that is there now"; exit 1 ;;
    *) echo "merge blocked: the required-checks probe failed (rc=$CHECKS_RC)"; exit 1 ;;
esac

# The boundary once more: a clean verdict on the threshold-th head must not walk into the largest
# irreversible action unasked.
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-round-count.sh "$PR" "$COPILOT_BOT"; MERGE_ROUNDS_RC=$?
case "$MERGE_ROUNDS_RC" in
    0) ;;
    3) echo "PAUSE: round boundary reached. Decide with the operator before merging: merge now, leave it open, or close this PR and start over with a better approach. Say what the rounds have been ABOUT, not just how many"
       exit 3 ;;
    *) echo "merge blocked: could not establish the round count (rc=$MERGE_ROUNDS_RC)"; exit 1 ;;
esac

# `--admin` by default, since branch protection normally requires a human approval neither reviewer
# supplies; `docs/decisions/2026-08-06-merge-admin-default.md` records the trade, and `REVIEW_MERGE_STRICT=1` takes the other side.
ADMIN=--admin
[ "${REVIEW_MERGE_STRICT:-}" = "1" ] && ADMIN=""
# `$ADMIN` is deliberately unquoted: it is `--admin` or nothing, and quoting nothing passes an empty argument.
if ! gh pr merge "$PR" --repo "$HOST/$OWNER/$REPO" --squash --delete-branch $ADMIN \
       --match-head-commit "$HEAD_OID"; then
    echo "merge blocked: head moved after the gates ran, branch protection refused (strict mode), or the merge failed."; exit 1
fi
# `gh pr merge` reports success for adding the PR to a merge queue, so the state is read back.
MERGED_STATE=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json state --jq '.state' 2>/dev/null); STATE_RC=$?
if [ "$STATE_RC" -ne 0 ]; then
    echo "merge queued or unconfirmed: the merge command succeeded but the PR state could not be read (rc=$STATE_RC); confirm before treating $HEAD_OID as merged"
    exit 4
fi
case "$MERGED_STATE" in
    MERGED) echo "merged $HEAD_OID" ;;
    *) echo "merge queued: the merge command succeeded but the PR is $MERGED_STATE, not MERGED — a merge queue accepts the request without landing it. Do not treat $HEAD_OID as merged."
       exit 4 ;;
esac
