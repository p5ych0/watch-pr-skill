#!/usr/bin/env -S bash -p
# A last-resort refusal: `$-` proves the mode, not how the shell got there.
if [[ $- != *p* ]]; then
    echo "PR_ROUND_COUNT status=error reason=not_privileged" >&2
    exit 2
fi

# No `-e`: statuses are control flow here.
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_ROUND_COUNT status=error reason=lib_dir_unresolvable" >&2; exit 2; }
# The bootstrap cannot use the loader: clear and take the clear's status, define a refusing stub
# so an empty `loadlib.sh` cannot leave `rb_load` to `PATH`, source. The first load's 127 is the stub's.
unset -f rb_load 2>/dev/null || {
    echo "PR_ROUND_COUNT status=error reason=loadlib_stale_definition" >&2; exit 2; }
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_ROUND_COUNT status=error reason=loadlib_unreadable" >&2; exit 2; }
rb_load "$_RB_SELF_DIR" recordlib RECORDLIB_JQ "PR_ROUND_COUNT status=error" var || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "PR_ROUND_COUNT status=error reason=loadlib_empty" >&2
    exit 2; }

THRESHOLD="${REVIEW_ROUND_THRESHOLD:-10}"
# A malformed threshold falls back to the default rather than disabling the pause; only a
# literal `0` disables it, and a leading zero is octal.
case "$THRESHOLD" in
    0)           ;;              # explicitly disabled
    0*)          THRESHOLD=10 ;; # 00, 08, 012 … not a plain decimal
    ""|*[!0-9]*) THRESHOLD=10 ;;
esac
# Beyond fixed-width arithmetic a value wraps, possibly to the disabling zero.
case "$THRESHOLD" in
    0) ;;
    ??????????*) THRESHOLD=10 ;;
esac

rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_ROUND_COUNT status=error" || exit 2
rb_identity || {
    echo "PR_ROUND_COUNT status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }
REPO_SLUG="$HOST/$OWNER/$REPO"

PR="${1:-}"
case "$PR" in
    ""|*[!0-9]*) echo "usage: $0 <pr> [reviewer-login ...]" >&2; exit 2 ;;
esac
shift || true

if [ "$#" -gt 0 ]; then
    REVIEWERS=("$@")
else
    REVIEWERS=('chatgpt-codex-connector[bot]' 'copilot-pull-request-reviewer[bot]')
fi
WHO_JSON="$(printf '%s\n' "${REVIEWERS[@]}" | jq -R . | jq -s -c .)" || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=reviewer_list_unreadable" >&2
    exit 2
}

raw=$(gh api --hostname "$HOST" "repos/$OWNER/$REPO/pulls/$PR/reviews" --paginate 2>/dev/null) || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=fetch_failed"
    exit 2
}

# A clean pass is a round and leaves no review behind: Codex reports it as a comment.
icraw=$(gh api --hostname "$HOST" "repos/$OWNER/$REPO/issues/$PR/comments" --paginate 2>/dev/null) || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=comments_fetch_failed"
    exit 2
}

# Per reviewer list, because the pause prints each reviewer's own count for the operator to
# acknowledge.
count_for() {
local _rounds _clean
    _rounds=$(printf '%s' "$raw" | jq -s --argjson who "$1" "$RECORDLIB_JQ"'
    pages_or_error
    | [ .[][] ] as $all
    | if any($all[]; valid_review_record | not)
      then error("malformed review record")
      # PENDING is a draft in flight, not a round.
      else [ $all[]
             | select((.user.login | IN($who[]))
                      and .submitted_at != null
                      and .state != "PENDING")
             | .commit_id ] | unique
      end' 2>/dev/null) || {
        echo "PR_ROUND_COUNT pr=$PR status=error reason=unreadable"
        return 2
    }

_clean=$(printf '%s' "$icraw" | jq -s --argjson who "$1" "$RECORDLIB_JQ"'
    pages_or_error
    | [ .[][] ] as $all
      | if any($all[]; valid_comment_record | not)
        then error("malformed comment record")
        else [ $all[]
               | select((.user.login | IN($who[])) and ((.body | type) == "string"))
               | select(.body | test("(?m)^\\*\\*Reviewed commit:\\*\\* `[0-9a-f]{10}`"))
               | select(.body | test("[Dd]idn.t find any major issues"))
               # Exactly ten hex, the footer width, so a clean re-review of a counted head
               # deduplicates against the ten-character prefix of a full sha; the last anchored line.
               | (.body | [scan("(?m)^\\*\\*Reviewed commit:\\*\\* `([0-9a-f]{10})`")] | last // [""] | .[0])
             ] | map(select(. != "")) | unique
        end' 2>/dev/null) || {
        echo "PR_ROUND_COUNT pr=$PR status=error reason=comments_unreadable"
        return 2
    }

    jq -n --argjson r "$_rounds" --argjson c "$_clean" '
    ($r | map(.[0:10])) as $rp
    | ($rp + ($c | map(.[0:10]))) | unique | length' 2>/dev/null || {
        echo "PR_ROUND_COUNT pr=$PR status=error reason=count_unreadable"
        return 2
    }
}


rounds="$(count_for "$WHO_JSON")" || exit 2
case "$rounds" in
    ""|*[!0-9]*) echo "PR_ROUND_COUNT pr=$PR status=error reason=bad_count"; exit 2 ;;
esac

if [ "$THRESHOLD" -eq 0 ]; then
    echo "PR_ROUND_COUNT pr=$PR rounds=$rounds threshold=0 pause=0"
    exit 0
fi

# The boundary is crossed, not landed on: one call can step over a multiple of the threshold,
# so the test is an inequality against the count the operator last acknowledged for this reviewer.
ack_for() {
ack=$(printf '%s' "$icraw" | jq -s -r --argjson who "$1" "$RECORDLIB_JQ"'
    pages_or_error
    | [ .[][] ] as $all
      # Not `valid_comment_record`: an unread acknowledgement causes an extra pause, the safe
      # direction, so an odd record is skipped rather than failing the count.
      | if any($all[]; type != "object")
        then error("malformed comment record")
        else [ $all[]
               | select((.author_association | type) == "string")
               | select(.author_association | IN("OWNER","MEMBER","COLLABORATOR"))
               | select((.body | type) == "string")
               # Anchored, so a footer-shaped line quoted in prose is not an acknowledgement;
               # every matching line, since one comment carries a line per reviewer.
               | (.body | [scan("(?m)^\\*\\*Review-Pause-Acknowledged:\\*\\* `([^`\n]{1,200})` `([0-9]{1,9})`")])
               | .[]
               # Compared, never interpolated into a pattern: the logins end in `[bot]`.
               | select(.[0] | IN($who[]))
               | .[1]
             ] | map(select(. != "")) | map(tonumber) | max // 0
        end' 2>/dev/null) || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=ack_unreadable"
    return 2
}
case "$ack" in
    ""|*[!0-9]*) echo "PR_ROUND_COUNT pr=$PR status=error reason=bad_ack ack=$ack"; return 2 ;;
esac
printf '%s' "$ack"
}

ack="$(ack_for "$WHO_JSON")" || exit 2

# Each reviewer against its own count and its own acknowledgement: the union of heads and the
# largest acknowledgement do not measure the same set.
pause=0
for _w in "${REVIEWERS[@]}"; do
    _wj="$(printf '%s' "$_w" | jq -R . | jq -s -c .)" || {
        echo "PR_ROUND_COUNT pr=$PR status=error reason=reviewer_list_unreadable"
        exit 2
    }
    _wc="$(count_for "$_wj")" || exit 2
    _wa="$(ack_for "$_wj")" || exit 2
    # An acknowledgement ahead of the count is the disable-forever shape: unreadable, not permissive.
    if [ "$_wa" -gt "$_wc" ]; then
        echo "PR_ROUND_COUNT pr=$PR status=error reason=ack_ahead_of_count reviewer=$_w ack=$_wa rounds=$_wc"
        exit 2
    fi
    [ "$_wc" -ge $((_wa + THRESHOLD)) ] && pause=1
done

if [ "$pause" = 1 ]; then
    echo "PR_ROUND_PAUSE pr=$PR rounds=$rounds threshold=$THRESHOLD acknowledged=$ack"
    echo "Decide with the operator: continue / stop & merge / stop & leave open / abandon." >&2
    echo "To continue, post a comment containing, for each reviewer counted here:" >&2
    for _w in "${REVIEWERS[@]}"; do
        _wj="$(printf '%s' "$_w" | jq -R . | jq -s -c .)" || {
            echo "PR_ROUND_COUNT pr=$PR status=error reason=reviewer_list_unreadable" >&2
            exit 2
        }
        _wr="$(count_for "$_wj")" || exit 2
        # Each reviewer's own count, and not indented: the scan anchors these at column 1.
        echo "**Review-Pause-Acknowledged:** \`$_w\` \`$_wr\`" >&2
    done
    exit 3
fi

echo "PR_ROUND_COUNT pr=$PR rounds=$rounds threshold=$THRESHOLD acknowledged=$ack pause=0"
exit 0
