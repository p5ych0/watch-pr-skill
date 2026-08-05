#!/usr/bin/env bash
# How many review rounds has this PR had, and is this a check-in boundary?
#
#   pr-round-count.sh <pr> [reviewer-login ...]
#
#   0  below the boundary — carry on
#   3  boundary reached: PAUSE and decide with the operator
#   2  the count could not be established — fail closed, do NOT silently continue
#
# A round is a DISTINCT PR head that received a submitted review. Counting heads
# rather than reviews means two reviewers on the same commit is one round, and a
# re-review of an unchanged head does not inflate the count.
#
# The count is derived from GitHub every time, never from local state: the v1
# counter lived in a `/tmp` file, so the pause it promised silently disappeared
# whenever a session started on a different machine or the file was cleaned up.
# A guarantee that only holds while a temp file survives is not a guarantee.
#
# `set -uo pipefail`, NOT `-e`: `gh` probes fail as normal operation and the
# result is control flow. See CLAUDE.md § Bash conventions.
set -uo pipefail

THRESHOLD="${REVIEW_ROUND_THRESHOLD:-10}"
# A malformed threshold falls back to the default rather than disabling the
# check-in: a typo must not silently remove a safety pause. `0` disables it, but
# only when written exactly.
case "$THRESHOLD" in
    ""|*[!0-9]*) THRESHOLD=10 ;;
esac

REMOTE="${REVIEW_BUS_REMOTE:-$(git remote get-url origin 2>/dev/null)}"
if [ -z "$REMOTE" ]; then
    echo "PR_ROUND_COUNT status=error reason=no_origin" >&2
    exit 2
fi
_p="${REMOTE%.git}"; REPO="${REVIEW_BUS_REPO:-${_p##*/}}"; _p="${_p%/*}"
OWNER="${REVIEW_BUS_OWNER:-${_p##*[:/]}}"
REPO_SLUG="$OWNER/$REPO"

PR="${1:-}"
case "$PR" in
    ""|*[!0-9]*) echo "usage: $0 <pr> [reviewer-login ...]" >&2; exit 2 ;;
esac
shift || true

# Default to the two native reviewers; any logins given override that.
if [ "$#" -gt 0 ]; then
    REVIEWERS=("$@")
else
    REVIEWERS=('chatgpt-codex-connector[bot]' 'copilot-pull-request-reviewer[bot]')
fi
WHO_JSON="$(printf '%s\n' "${REVIEWERS[@]}" | jq -R . | jq -s -c .)" || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=reviewer_list_unreadable" >&2
    exit 2
}

raw=$(gh api "repos/$REPO_SLUG/pulls/$PR/reviews" --paginate 2>/dev/null) || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=fetch_failed"
    exit 2
}

# Same page-shape discipline as pr-review-state.sh: `jq -s` slurps into an array
# of PAGES, empty input slurps to zero pages, and `.[][]` over an object iterates
# its values — so an errored body or an empty read would otherwise count as
# "no rounds yet", which is the direction that skips the pause.
rounds=$(printf '%s' "$raw" | jq -s --argjson who "$WHO_JSON" '
    if length == 0 then error("no pages")
    elif any(.[]; type != "array") then error("non-array page")
    else [ .[][] ] as $all
      | if any($all[];
               type != "object"
               or (.user | type) != "object"
               or (.user.login | type) != "string"
               or (.commit_id | type) != "string"
               or ((.submitted_at | type) != "string" and .submitted_at != null))
        then error("malformed review record")
        else [ $all[]
               | select((.user.login | IN($who[])) and .submitted_at != null)
               | .commit_id ] | unique | length
        end
    end' 2>/dev/null) || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=unreadable"
    exit 2
}
case "$rounds" in
    ""|*[!0-9]*) echo "PR_ROUND_COUNT pr=$PR status=error reason=bad_count"; exit 2 ;;
esac

if [ "$THRESHOLD" -eq 0 ]; then
    echo "PR_ROUND_COUNT pr=$PR rounds=$rounds threshold=0 pause=0"
    exit 0
fi

# Pause ON the boundary: after the 10th reviewed head, before requesting an 11th.
if [ "$rounds" -gt 0 ] && [ $((rounds % THRESHOLD)) -eq 0 ]; then
    echo "PR_ROUND_PAUSE pr=$PR rounds=$rounds threshold=$THRESHOLD"
    echo "Decide with the operator: continue / stop & merge / stop & leave open / abandon." >&2
    exit 3
fi

echo "PR_ROUND_COUNT pr=$PR rounds=$rounds threshold=$THRESHOLD pause=0"
exit 0
