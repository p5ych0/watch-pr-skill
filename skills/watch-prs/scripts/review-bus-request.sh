#!/usr/bin/env bash
# review-bus-request.sh — write a request file telling the codex reviewer
# that a PR head is ready for review.
#
# Usage:
#   scripts/review-bus-request.sh [PR_NUMBER] [--force]
#
# If PR_NUMBER is omitted, derived from the current branch via
# `gh pr view --json number`. SHA + branch read from local git. Writes
# JSON to /tmp/<repo>-review-bus/requests/req-<sha>.json which the
# codex watcher consumes.
#
# Preflight gate — refuses to write a request unless ALL hold:
#   1. Working tree clean (no uncommitted tracked changes).
#   2. Local HEAD pushed to origin/<branch> (local SHA == upstream SHA).
#   3. Zero unresolved review threads on the PR.
#   4. An issue-level summary comment exists on the PR that is newer
#      than the latest inline pull-comment — heuristic that the
#      implementer posted the round close-out after addressing every
#      codex inline finding.
#
# The bus is the *only* legitimate trigger for a codex review pass.
# Codex must never start before every prior comment is addressed,
# replies posted, threads resolved, HEAD pushed, and summary published.
# Bypass with --force only when debugging the bus itself.

set -euo pipefail

# Single-domain + universal: repo identity derived from this checkout's origin.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)}"
REMOTE="${REVIEW_BUS_REMOTE:-$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)}"
if [ -n "$REMOTE" ]; then
    # Host-agnostic parse (SSH git@host:owner/repo.git or HTTPS .../owner/repo.git).
    _p="${REMOTE%.git}"
    REPO="${REVIEW_BUS_REPO:-${_p##*/}}"
    _p="${_p%/*}"
    OWNER="${REVIEW_BUS_OWNER:-${_p##*[:/]}}"
else
    OWNER="${REVIEW_BUS_OWNER:-}"
    REPO="${REVIEW_BUS_REPO:-}"
fi
REPO_SLUG="$OWNER/$REPO"
# Owner-scoped so alice/shared and bob/shared don't collide on one bus.
BUS_SLUG="$(printf '%s' "${OWNER:+${OWNER}-}${REPO}" | tr -c 'A-Za-z0-9._-' '-')"
BUS_DIR="${BUS_DIR:-/tmp/${BUS_SLUG:-review}-review-bus}"
REQ_DIR="$BUS_DIR/requests"
mkdir -p "$REQ_DIR"

FORCE=0
CONTINUE_THRESHOLD=0
PR=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --continue-threshold) CONTINUE_THRESHOLD=1 ;;
        --help|-h)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) PR="$arg" ;;
    esac
done

if [ -z "$PR" ]; then
    PR=$(gh pr view --repo "$REPO_SLUG" --json number --jq '.number' 2>/dev/null || true)
fi
if [ -z "$PR" ]; then
    echo "ERR: no PR number (pass as arg or open a PR for current branch first)" >&2
    exit 1
fi
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
    echo "ERR: PR number must be numeric (got: $PR)" >&2
    exit 1
fi

SHA=$(git rev-parse --short=7 HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
NOW=$(date -u +%FT%TZ)

preflight_fail() {
    echo "BUS_REQUEST_BLOCKED reason=$1" >&2
    echo "    $2" >&2
    echo "" >&2
    echo "Address the gate condition and retry, or pass --force to bypass" >&2
    echo "(bypass is only legitimate when debugging the bus itself)." >&2
    exit 2
}

if [ "$FORCE" -eq 0 ]; then
    # 1. Working tree clean.
    if ! git diff --quiet --ignore-submodules HEAD -- 2>/dev/null; then
        preflight_fail "dirty_worktree" \
            "uncommitted tracked changes exist. Commit (or stash) them so the review covers what is on HEAD."
    fi

    # 2. HEAD pushed to upstream.
    if ! upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
        preflight_fail "no_upstream" \
            "branch $BRANCH has no upstream tracking ref. Run: git push -u origin $BRANCH"
    fi
    # Fail CLOSED on a failed fetch: otherwise we'd compare HEAD to a stale
    # local tracking ref and could attest "pushed" for an unpushed commit.
    if ! git fetch --quiet origin "$BRANCH" 2>/dev/null; then
        preflight_fail "fetch_failed" \
            "could not fetch origin/$BRANCH to confirm HEAD is pushed. Retry once the network/remote is reachable."
    fi
    local_sha=$(git rev-parse HEAD)
    # Compare against the freshly-fetched remote head, not just the local
    # tracking ref, so an unpushed commit can't slip through.
    remote_sha=$(git rev-parse "origin/$BRANCH" 2>/dev/null || git rev-parse "$upstream" 2>/dev/null || echo "")
    if [ -z "$remote_sha" ] || [ "$local_sha" != "$remote_sha" ]; then
        preflight_fail "head_not_pushed" \
            "local HEAD ($local_sha) != origin/$BRANCH (${remote_sha:-unknown}). Push HEAD before requesting review."
    fi

    # 3. Zero unresolved review threads (paginated — PRs commonly exceed 100).
    # Fail CLOSED: any fetch or parse failure must BLOCK the request, never let
    # an empty/`{}` fallback satisfy the zero-unresolved gate by accident.
    unresolved=0
    cursor=""
    while true; do
        if [ -z "$cursor" ]; then
            page=$(gh api graphql -F pr="$PR" -F owner="$OWNER" -F name="$REPO" \
                -f query='query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){pullRequest(number:$pr){reviewThreads(first:100){nodes{isResolved} pageInfo{endCursor hasNextPage}}}}}' \
                2>/dev/null) || preflight_fail "threads_fetch_failed" \
                "could not fetch review threads for PR #$PR (GraphQL call failed). Retry once GitHub is reachable."
        else
            page=$(gh api graphql -F pr="$PR" -F owner="$OWNER" -F name="$REPO" -F c="$cursor" \
                -f query='query($owner:String!,$name:String!,$pr:Int!,$c:String!){repository(owner:$owner,name:$name){pullRequest(number:$pr){reviewThreads(first:100, after:$c){nodes{isResolved} pageInfo{endCursor hasNextPage}}}}}' \
                2>/dev/null) || preflight_fail "threads_fetch_failed" \
                "could not fetch review threads (page) for PR #$PR (GraphQL call failed). Retry once GitHub is reachable."
        fi
        # A malformed/errors payload (no data node) must fail closed, not yield 0.
        if ! echo "$page" | jq -e '.data.repository.pullRequest.reviewThreads' >/dev/null 2>&1; then
            preflight_fail "threads_parse_failed" \
                "unexpected GraphQL payload for PR #$PR review threads. Retry or inspect the API response."
        fi
        count=$(echo "$page" | jq '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false)] | length' 2>/dev/null) \
            || preflight_fail "threads_parse_failed" "could not parse review-thread count for PR #$PR."
        unresolved=$((unresolved + count))
        has_next=$(echo "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' 2>/dev/null)
        cursor=$(echo "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""' 2>/dev/null)
        [ "$has_next" = "true" ] && [ -n "$cursor" ] || break
    done
    if [ "$unresolved" -ne 0 ]; then
        preflight_fail "unresolved_threads" \
            "$unresolved unresolved review thread(s) on PR #$PR. Reply + resolve every prior codex thread first."
    fi

    # 4. Implementer summary newer than latest inline pull-comment.
    # Both endpoints may be authored by the same token (p5ych0 is shared
    # between the implementer and codex), so we cannot author-filter;
    # the timestamp ordering between the two endpoints is the signal.
    # Inline pull-comments (pulls/<pr>/comments) cover BOTH codex's
    # findings AND the implementer's per-thread replies, so the latest
    # inline timestamp jumps every time the implementer answers a
    # thread. A fresh issue-level summary (issues/<pr>/comments) must
    # land AFTER the last reply for the round to count as closed.
    # Fetch raw (NOT --jq): with `--paginate --jq`, jq runs PER PAGE so `last`
    # is a per-page max, not the global latest. Slurp all pages with `jq -rs`
    # and aggregate once. Fail CLOSED on any fetch/parse failure.
    raw_inline=$(gh api "repos/$REPO_SLUG/pulls/$PR/comments?per_page=100" --paginate 2>/dev/null) \
        || preflight_fail "pull_comments_fetch_failed" \
            "could not fetch inline pull comments for PR #$PR. Retry once GitHub is reachable."
    raw_summary=$(gh api "repos/$REPO_SLUG/issues/$PR/comments?per_page=100" --paginate 2>/dev/null) \
        || preflight_fail "issue_comments_fetch_failed" \
            "could not fetch issue comments for PR #$PR. Retry once GitHub is reachable."

    latest_inline=$(jq -rs '[.[][] | .created_at] | sort | last // ""' <<< "$raw_inline" 2>/dev/null) \
        || preflight_fail "pull_comments_parse_failed" "could not parse inline pull comments for PR #$PR."
    latest_summary=$(jq -rs '[.[][] | .created_at] | sort | last // ""' <<< "$raw_summary" 2>/dev/null) \
        || preflight_fail "issue_comments_parse_failed" "could not parse issue comments for PR #$PR."
    if [ -z "$latest_summary" ]; then
        preflight_fail "no_summary" \
            "no issue-level summary comment on PR #$PR. Post the round close-out summary first."
    fi
    if [ -n "$latest_inline" ] && [[ "$latest_summary" < "$latest_inline" ]]; then
        preflight_fail "stale_summary" \
            "latest summary ($latest_summary) predates latest inline comment ($latest_inline). Post a fresh close-out summary after addressing every inline thread."
    fi
fi

# ── Round-count threshold pause ──────────────────────────────────────────────
# A safety check-in that fires every N closed rounds (default 10) regardless of
# WHO drives the loop. This is the chokepoint every next-round enqueue passes
# through — manual OR via review-bus-close-round.sh — so, unlike a skill-only
# step, it cannot be bypassed by a driver that never re-enters the skill.
#
# Rounds are counted the ROBUST way: distinct HEAD SHAs already enqueued for this
# PR (a same-SHA retry never double-counts), recorded below — NOT a fragile
# commit-message prefix (round-fix commits use a module scope like
# `fix(shipment): … (review r7)`, so a `fix(review):` count is always 0 and never
# fires). At a non-zero multiple of the threshold the request is REFUSED with a
# distinct exit (3) so the DRIVER pauses to ask the operator: continue / stop &
# merge / stop & leave open / abandon. This is INDEPENDENT of --force: --force
# bypasses the correctness gates above (for debugging the bus), but the round
# check-in is an operator-safety feature that must be crossed deliberately — pass
# --continue-threshold, or set CODEX_REVIEW_ROUND_THRESHOLD=0 to disable it.
THRESHOLD="${CODEX_REVIEW_ROUND_THRESHOLD:-10}"
ROUNDS_DIR="$BUS_DIR/.rounds"
ROUNDS_FILE="$ROUNDS_DIR/pr-${PR}.shas"
FULL_SHA=$(git rev-parse HEAD)
rounds_done=0
[ -f "$ROUNDS_FILE" ] && rounds_done=$(grep -c . "$ROUNDS_FILE" 2>/dev/null || echo 0)

if [ "$THRESHOLD" -gt 0 ] && [ "$CONTINUE_THRESHOLD" -eq 0 ] \
   && [ "$rounds_done" -gt 0 ] && [ $((rounds_done % THRESHOLD)) -eq 0 ] \
   && ! grep -qxF "$FULL_SHA" "$ROUNDS_FILE" 2>/dev/null; then
    echo "REVIEW_BUS_THRESHOLD_PAUSE pr=$PR rounds=$rounds_done next_sha=$SHA" >&2
    echo "    $rounds_done review round(s) closed on PR #$PR — a check-in before the next." >&2
    echo "    Decide with the operator: continue / stop & merge / stop & leave open / abandon." >&2
    echo "    To continue (enqueue the next review): re-run with --continue-threshold." >&2
    echo "    To disable these pauses entirely: export CODEX_REVIEW_ROUND_THRESHOLD=0." >&2
    exit 3
fi

REQ_FILE="$REQ_DIR/req-${SHA}.json"
TMP_FILE="${REQ_FILE}.tmp.$$"

# Emit real JSON types via jq — `force` MUST be a boolean. The watcher checks
# `.preflight.force == "true"`; a JSON number (1/0) would never match, so a
# --force request would silently lose its force semantics.
force_bool=false
[ "$FORCE" -eq 1 ] && force_bool=true

jq -n \
  --argjson pr "$PR" \
  --arg sha "$SHA" \
  --arg branch "$BRANCH" \
  --arg requested_at "$NOW" \
  --argjson force "$force_bool" \
  '{
    pr: $pr,
    sha: $sha,
    branch: $branch,
    requested_at: $requested_at,
    requested_by: "claude-implementer",
    preflight: {
      force: $force,
      worktree_clean: true,
      head_pushed: true,
      unresolved_threads: 0,
      summary_posted: true
    }
  }' > "$TMP_FILE"
mv "$TMP_FILE" "$REQ_FILE"

# Record this SHA as an enqueued round (deduped) so the threshold counter above
# advances by one per DISTINCT round, immune to same-SHA retries.
mkdir -p "$ROUNDS_DIR"
grep -qxF "$FULL_SHA" "$ROUNDS_FILE" 2>/dev/null || printf '%s\n' "$FULL_SHA" >> "$ROUNDS_FILE"

echo "review request written: ${REQ_FILE}"
