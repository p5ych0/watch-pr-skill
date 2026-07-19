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
#   0. Preflight EVERYTHING local before touching GitHub — summary readable,
#      worktree clean, HEAD pushed, and HEAD == PR #N's head. A wrong/dirty/
#      unpushed checkout must fail before any irreversible thread mutation.
#   1. Snapshot the pre-round responses (path + content digest) BEFORE mutating.
#      The captured digest — not a later re-hash — is what step 5 acks, so a
#      review written by auto-enqueue mid-run can't be mistaken for a handled one.
#   2. For every UNRESOLVED review thread: post a thread-level reply, then
#      resolve it. If the reply FAILS, leave the thread unresolved (its ack is
#      the point) and finish with a non-zero, clearly-incomplete result.
#   3. Post the round-summary issue comment (from --summary <file>, else a
#      minimal auto-summary) so it lands AFTER the inline replies — satisfying
#      request.sh's "summary newer than latest inline" gate.
#   4. Re-enqueue the next review pass via review-bus-request.sh (which
#      re-verifies clean-tree + head-pushed + zero-unresolved + summary gates).
#   5. Ack each snapshot response by its CAPTURED digest in one monitor call
#      (--ack-if-digest). The marker is keyed on the step-1 digest, never a
#      re-hash of the on-disk file, so a same-SHA re-review written underneath us
#      carries a different digest and is NOT suppressed — its notification still
#      fires. No compare-then-ack window. Ack failures are surfaced, not swallowed.
#
# Judgment stays with the implementer: you decide WHICH findings you addressed
# vs. intentionally skipped (documented in --summary and/or your own per-thread
# replies before running this). Pass --force to skip the local preflight and
# forward a bus-debug bypass to review-bus-request.sh.

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
        --help|-h) sed -n '2,45p' "$0"; exit 0 ;;
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

FULL_SHA=$(git rev-parse HEAD)
SHA=$(git rev-parse --short=7 HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)

fail() { echo "ERR: $1" >&2; exit "${2:-2}"; }

# ── 0. Preflight — validate EVERYTHING local before any GitHub mutation ──────
# The --summary file is checked unconditionally (a typo must never surface only
# after threads are resolved). It must be a REGULAR readable file: `-r` alone is
# true for directories, FIFOs, and devices, which would pass here and then only
# fail inside `gh pr comment --body-file` AFTER every thread is resolved —
# exactly the half-closeout this preflight exists to prevent. --force skips the
# git/PR-identity gates only, never this one.
if [ -n "$SUMMARY_FILE" ] && { [ ! -f "$SUMMARY_FILE" ] || [ ! -r "$SUMMARY_FILE" ]; }; then
    fail "--summary must be a readable regular file: $SUMMARY_FILE" 1
fi
if [ "$FORCE" -eq 0 ]; then
    # Clean == no UNSTAGED and no STAGED diff vs HEAD. `git diff HEAD` alone
    # misses a staged change whose worktree copy was reverted to HEAD (index !=
    # HEAD, worktree == HEAD), so also check --cached; together they attest the
    # checkout truly matches HEAD. (Untracked files are intentionally ignored —
    # they don't alter the reviewed HEAD state.)
    { git diff --quiet --ignore-submodules HEAD -- 2>/dev/null \
        && git diff --cached --quiet --ignore-submodules HEAD -- 2>/dev/null; } \
        || fail "dirty checkout (unstaged or staged changes) — commit or stash before closing the round (or --force to debug the bus)."
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
        || fail "branch $BRANCH has no upstream — run: git push -u origin $BRANCH"
    git fetch --quiet origin "$BRANCH" 2>/dev/null \
        || fail "could not fetch origin/$BRANCH to confirm HEAD is pushed. Retry when the remote is reachable."
    # Resolve the remote head exactly as review-bus-request.sh does (it runs
    # next): try origin/$BRANCH, then fall back to the actual upstream ref. This
    # keeps close-round from rejecting a branch whose upstream isn't origin/$BRANCH
    # that request.sh would accept — close-round must never be stricter than the
    # gate it forwards to.
    remote_sha=$(git rev-parse "origin/$BRANCH" 2>/dev/null || git rev-parse "$upstream" 2>/dev/null || echo "")
    { [ -n "$remote_sha" ] && [ "$FULL_SHA" = "$remote_sha" ]; } \
        || fail "local HEAD ($FULL_SHA) != origin/$BRANCH (${remote_sha:-unknown}). Push HEAD first."
    pr_head=$(gh pr view "$PR" --repo "$REPO_SLUG" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
        || fail "could not fetch head of PR #$PR to confirm this checkout is its branch."
    [ "$pr_head" = "$FULL_SHA" ] \
        || fail "local HEAD ($FULL_SHA) is not PR #$PR's head ($pr_head) — check out the PR branch before closing its round."
fi

# ── 1. Snapshot pre-round responses (path + digest) BEFORE any mutation ──────
# Tolerant of a transiently unreadable / mid-write response: under
# `set -euo pipefail` an unguarded `sha256sum $f` (or `jq`) on an incomplete or
# vanished file would fail the pipeline and abort the ENTIRE close-round here,
# before anything useful happens, with no hint which file. So obtain BOTH the pr
# and the digest defensively (`|| true` defuses set -e/pipefail) and only snapshot
# a response when both succeeded — a junk/partial file is skipped, not fatal.
snap_files=(); snap_digests=()
if [ -d "$RESP_DIR" ]; then
    while IFS= read -r f; do
        pr_of="$(jq -r '.pr // ""' "$f" 2>/dev/null || true)"
        [ "$pr_of" = "$PR" ] || continue
        dg="$(sha256sum "$f" 2>/dev/null | awk '{print $1}' || true)"
        if [ -z "$dg" ]; then
            echo "note: skipping unreadable/incomplete response in snapshot: $f" >&2
            continue
        fi
        snap_files+=("$f")
        snap_digests+=("$dg")
    done < <(find "$RESP_DIR" -maxdepth 1 -type f -name 'resp-*.json' 2>/dev/null)
fi

# ── 2. Reply-to + resolve every unresolved review thread (paginated) ─────────
reply_body="🤖 Round \`${SHA}\` close-out via the review bus — see the round-summary comment for this finding's disposition (addressed or intentionally skipped)."
resolved=0; reply_failures=0
cursor=""
while true; do
    if [ -z "$cursor" ]; then
        page=$(gh api graphql -F owner="$OWNER" -F name="$REPO" -F pr="$PR" -f query='
          query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){pullRequest(number:$pr){
            reviewThreads(first:100){nodes{id isResolved} pageInfo{hasNextPage endCursor}}}}}' 2>/dev/null) \
          || fail "could not fetch review threads for PR #$PR" 3
    else
        page=$(gh api graphql -F owner="$OWNER" -F name="$REPO" -F pr="$PR" -F c="$cursor" -f query='
          query($owner:String!,$name:String!,$pr:Int!,$c:String!){repository(owner:$owner,name:$name){pullRequest(number:$pr){
            reviewThreads(first:100, after:$c){nodes{id isResolved} pageInfo{hasNextPage endCursor}}}}}' 2>/dev/null) \
          || fail "could not fetch review threads (page) for PR #$PR" 3
    fi
    echo "$page" | jq -e '.data.repository.pullRequest.reviewThreads' >/dev/null 2>&1 \
        || fail "unexpected review-threads payload for PR #$PR" 3

    while IFS= read -r tid; do
        [ -n "$tid" ] || continue
        # Reply is the point of the thread ack — if it fails, do NOT resolve;
        # the thread stays open so the next run retries and the gate blocks.
        if gh api graphql -F id="$tid" -F body="$reply_body" -f query='
              mutation($id:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id, body:$body}){clientMutationId}}' \
              >/dev/null 2>&1; then
            gh api graphql -F id="$tid" -f query='
              mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' \
              >/dev/null 2>&1 || fail "could not resolve thread $tid" 4
            resolved=$((resolved + 1))
        else
            echo "warn: reply failed for thread $tid — leaving it UNRESOLVED" >&2
            reply_failures=$((reply_failures + 1))
        fi
    done < <(echo "$page" | jq -r '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false) | .id')

    [ "$(echo "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')" = "true" ] || break
    cursor=$(echo "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
done
echo "resolved ${resolved} thread(s) on PR #$PR"

if [ "$reply_failures" -gt 0 ]; then
    fail "${reply_failures} thread(s) could not be acknowledged (reply failed); left UNRESOLVED — round NOT closed. Retry once the API recovers." 6
fi

# ── 3. Round-summary issue comment (lands AFTER the inline replies) ──────────
if [ -n "$SUMMARY_FILE" ]; then
    gh pr comment "$PR" --repo "$REPO_SLUG" --body-file "$SUMMARY_FILE" >/dev/null || fail "could not post summary comment" 5
else
    gh pr comment "$PR" --repo "$REPO_SLUG" --body \
        "## Review round close-out (\`${SHA}\`)"$'\n\n'"Resolved ${resolved} review thread(s); requesting the next Codex pass. Per-finding detail is in the thread replies and this round's commits." >/dev/null \
        || fail "could not post summary comment" 5
fi
echo "summary posted"

# ── 4. Re-enqueue the next review pass ───────────────────────────────────────
req_args=("$PR")
[ "$FORCE" -eq 1 ] && req_args+=(--force)
"$SCRIPT_DIR"/review-bus-request.sh "${req_args[@]}"

# ── 5. Ack each snapshot response by its CAPTURED digest (single atomic op) ───
# The marker is keyed on the digest snapshotted in step 1 — the monitor writes
# it verbatim, never re-hashing the on-disk file. So if the watcher overwrote
# resp-$SHA.json with a fresh same-SHA review after the snapshot, that review's
# digest differs and this marker can't suppress it; its notification still fires.
# There is no compare-then-ack window because the marker key is a fixed value,
# not a second read of a file the watcher may have swapped underneath us.
ack_failures=0
for i in "${!snap_files[@]}"; do
    "$SCRIPT_DIR"/review-bus-response-monitor.sh --ack-if-digest "${snap_files[$i]}" "${snap_digests[$i]}" \
        || { echo "ERR: ack failed for ${snap_files[$i]}" >&2; ack_failures=$((ack_failures + 1)); }
done
[ "$ack_failures" -eq 0 ] || fail "$ack_failures response ack(s) failed — the round is enqueued but a handled response may re-surface." 7

echo "round closed for PR #$PR — next Codex pass enqueued for ${SHA}"
