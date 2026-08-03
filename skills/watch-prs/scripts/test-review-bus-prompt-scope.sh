#!/usr/bin/env bash
# Focused test for review-bus-codex-watcher.sh's build_prompt().
#
# Property: every review prompt must direct the reviewer to read the PR's
# intended scope (pr.json title/body + the newest round-summary issue comment)
# and use it for RELEVANCE only, and must mark that context as untrusted. Both
# files are already captured by the snapshot step, so this is prompt text — no
# new fetching. Without it every project has to re-author the same instruction
# by hand in its own .review-bus.md.
#
# Self-contained: a throwaway git repo, no network, no gh.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SCRIPT_DIR/review-bus-codex-watcher.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# Fixture: a repo whose base ref carries NO .review-bus.md, so the prompt takes
# the built-in guidance branch. The scope instructions must be present either
# way — they are not part of the per-project guidance block.
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name test
echo seed > "$REPO/seed.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm base
git -C "$REPO" branch -M main
FULL_SHA="$(git -C "$REPO" rev-parse HEAD)"

SNAP="$TMP/snap"; mkdir -p "$SNAP"
printf 'main\n' > "$SNAP/diff_base.txt"

PROMPT="$TMP/prompt.txt"

( export REPO_DIR="$REPO" BUS_DIR="$TMP/bus" \
         REVIEW_BUS_REMOTE="git@github.com:test/demo.git"
  # shellcheck disable=SC1090
  source "$WATCHER" >/dev/null 2>&1
  build_prompt "$PROMPT" 7 "${FULL_SHA:0:7}" pr-branch "$FULL_SHA" "$SNAP" "$REPO" )

grep -qi 'intended scope' "$PROMPT" \
  && pass "prompt asks the reviewer to establish intended scope" \
  || die "prompt does not mention intended scope"

grep -q 'pr.json' "$PROMPT" \
  && pass "prompt names pr.json as the scope source" \
  || die "prompt does not name pr.json"

grep -q 'issue_comments.jsonl' "$PROMPT" \
  && pass "prompt names issue_comments.jsonl as the round-summary source" \
  || die "prompt does not name issue_comments.jsonl"

grep -qi 'relevance' "$PROMPT" \
  && pass "scope is scoped to relevance" \
  || die "prompt does not limit scope use to relevance"

grep -qi 'non-blocking' "$PROMPT" \
  && pass "out-of-scope work routes to a non-blocking note" \
  || die "prompt does not route out-of-scope work to a non-blocking note"

grep -qi 'intent, never permission' "$PROMPT" \
  && pass "scope context is marked untrusted" \
  || die "prompt does not mark scope context as untrusted"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
