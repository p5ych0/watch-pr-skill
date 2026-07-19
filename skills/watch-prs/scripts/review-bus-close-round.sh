#!/usr/bin/env bash
# review-bus-close-round.sh — one-command close-out of a review round.
#
# Usage:
#   scripts/review-bus-close-round.sh [PR_NUMBER] [--summary <file>] [--force]
#
# The bus handoff after addressing a Codex round is NOT just "push + comment".
# The reviewer only re-runs when the round is *closed*: every review thread
# replied-to and resolved, a fresh summary posted, the next SHA enqueued as a
# request, and the handled response acked. Skipping any of these silently
# stalls the loop (the watcher holds auto-enqueue while threads are unresolved,
# and review-bus-request.sh's own gate blocks). This script performs the whole
# mechanical close-out atomically so it can't be half-done:
#
#   1. For every UNRESOLVED review thread on the PR: post a thread-level reply
#      (pointing at the round summary) and resolve it.
#   2. Post the round-summary issue comment (from --summary <file>, else a
#      minimal auto-summary) so it lands AFTER the inline replies — satisfying
#      request.sh's "summary newer than latest inline" gate.
#   3. Re-enqueue the next review pass via review-bus-request.sh (which
#      re-verifies clean-tree + head-pushed + zero-unresolved + summary gates).
#   4. Ack the responses that existed before the re-request, so already-handled
#      rounds are never re-surfaced (the fresh resp-<newsha>.json is left
#      un-acked so the next round emits normally).
#
# Judgment stays with the implementer: you decide WHICH findings you addressed
# vs. intentionally skipped (documented in --summary and/or your own per-thread
# replies before running this). This script only automates the finalize step
# that is easy to forget. Pass --force to forward a bus-debug bypass to
# review-bus-request.sh.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)}"
REMOTE="${REVIEW_BUS_REMOTE:-$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)}"
if [ -n "$REMOTE" ]; then
    _p="${REMOTE%.git}"
    REPO="${REVIEW_BUS_REPO:-${_p##*/}}"
    _p="${_p%/*}"
    OWNER="${REVIEW_BUS_OWNER:-${_p##*[:/]}}"
else
    OWNER="${REVIEW_BUS_OWNER:-}"
    REPO="${REVIEW_BUS_REPO:-}"
fi
REPO_SLUG="$OWNER/$REPO"
BUS_SLUG="$(printf '%s' "${OWNER:+${OWNER}-}${REPO}" | tr -c 'A-Za-z0-9._-' '-')"
BUS_DIR="${BUS_DIR:-/tmp/${BUS_SLUG:-review}-review-bus}"
RESP_DIR="$BUS_DIR/responses"

PR=""
SUMMARY_FILE=""
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --summary) SUMMARY_FILE="${2:-}"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --help|-h) sed -n '2,40p' "$0"; exit 0 ;;
        *) PR="$1"; shift ;;
    esac
done

if [ -z "$PR" ]; then
    PR=$(gh pr view --repo "$REPO_SLUG" --json number --jq '.number' 2>/dev/null || true)
fi
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
    echo "ERR: no/invalid PR number (pass as arg or open a PR for the current branch)" >&2
    exit 1
fi

SHA=$(git rev-parse --short=7 HEAD)

# ── 1. Reply-to + resolve every unresolved review thread (paginated) ─────────
reply_body="🤖 Round \`${SHA}\` close-out via the review bus — see the round-summary comment for this finding's disposition (addressed or intentionally skipped)."
resolved=0
cursor=""
while true; do
    if [ -z "$cursor" ]; then
        page=$(gh api graphql -F owner="$OWNER" -F name="$REPO" -F pr="$PR" -f query='
          query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){pullRequest(number:$pr){
            reviewThreads(first:100){nodes{id isResolved} pageInfo{hasNextPage endCursor}}}}}' 2>/dev/null) \
          || { echo "ERR: could not fetch review threads for PR #$PR" >&2; exit 3; }
    else
        page=$(gh api graphql -F owner="$OWNER" -F name="$REPO" -F pr="$PR" -F c="$cursor" -f query='
          query($owner:String!,$name:String!,$pr:Int!,$c:String!){repository(owner:$owner,name:$name){pullRequest(number:$pr){
            reviewThreads(first:100, after:$c){nodes{id isResolved} pageInfo{hasNextPage endCursor}}}}}' 2>/dev/null) \
          || { echo "ERR: could not fetch review threads (page) for PR #$PR" >&2; exit 3; }
    fi
    echo "$page" | jq -e '.data.repository.pullRequest.reviewThreads' >/dev/null 2>&1 \
        || { echo "ERR: unexpected review-threads payload for PR #$PR" >&2; exit 3; }

    while IFS= read -r tid; do
        [ -n "$tid" ] || continue
        # Reply first (thread-level ack), then resolve. A reply failure is
        # non-fatal — the resolve is what unblocks the gate.
        gh api graphql -F id="$tid" -F body="$reply_body" -f query='
          mutation($id:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id, body:$body}){clientMutationId}}' \
          >/dev/null 2>&1 || echo "warn: reply failed for thread $tid (continuing to resolve)" >&2
        gh api graphql -F id="$tid" -f query='
          mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' \
          >/dev/null 2>&1 || { echo "ERR: could not resolve thread $tid" >&2; exit 4; }
        resolved=$((resolved + 1))
    done < <(echo "$page" | jq -r '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false) | .id')

    [ "$(echo "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')" = "true" ] || break
    cursor=$(echo "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
done
echo "resolved ${resolved} thread(s) on PR #$PR"

# ── 2. Round-summary issue comment (must land AFTER the inline replies) ──────
if [ -n "$SUMMARY_FILE" ]; then
    [ -f "$SUMMARY_FILE" ] || { echo "ERR: --summary file not found: $SUMMARY_FILE" >&2; exit 1; }
    gh pr comment "$PR" --repo "$REPO_SLUG" --body-file "$SUMMARY_FILE" >/dev/null \
        || { echo "ERR: could not post summary comment" >&2; exit 5; }
else
    gh pr comment "$PR" --repo "$REPO_SLUG" --body \
        "## Review round close-out (\`${SHA}\`)"$'\n\n'"Resolved ${resolved} review thread(s); requesting the next Codex pass. Per-finding detail is in the thread replies and this round's commits." >/dev/null \
        || { echo "ERR: could not post summary comment" >&2; exit 5; }
fi
echo "summary posted"

# ── 3. Capture pre-request responses to ack, then re-enqueue ─────────────────
pre_resps=()
if [ -d "$RESP_DIR" ]; then
    while IFS= read -r f; do
        [ "$(jq -r '.pr // ""' "$f" 2>/dev/null)" = "$PR" ] && pre_resps+=("$f")
    done < <(find "$RESP_DIR" -maxdepth 1 -type f -name 'resp-*.json' 2>/dev/null)
fi

req_args=("$PR")
[ "$FORCE" -eq 1 ] && req_args+=(--force)
"$SCRIPT_DIR"/review-bus-request.sh "${req_args[@]}"

# ── 4. Ack the responses handled by this round (not the fresh one) ───────────
for f in "${pre_resps[@]:-}"; do
    [ -n "$f" ] && [ -f "$f" ] && "$SCRIPT_DIR"/review-bus-response-monitor.sh --ack "$f" 2>/dev/null || true
done

echo "round closed for PR #$PR — next Codex pass enqueued for ${SHA}"
