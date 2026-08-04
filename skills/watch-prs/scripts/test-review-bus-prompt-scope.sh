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
  && pass "prompt addresses the non-blocking observation case" \
  || die "prompt does not mention non-blocking observations"

# Routing, now that strumok#212 is fixed and `summary` survives a review that
# reports findings. The prompt must send the observation to summary and keep it
# OUT of findings[], where every entry becomes a merge-blocking thread. Before
# the fix the prompt had to say "omit it when there are findings", which cost
# the author the observation entirely; asserting the old wording here would now
# lock in the workaround.
grep -qi 'observation in summary' "$PROMPT" \
  && pass "observations route to summary" \
  || die "prompt does not route observations to summary"

grep -qi 'not in findings' "$PROMPT" \
  && pass "observations are kept out of findings[] (which would block the merge)" \
  || die "prompt does not keep observations out of findings[]"

grep -qi 'EVERY review' "$PROMPT" \
  && pass "prompt states summary survives every review, including one with findings" \
  || die "prompt still implies summary is lost when findings exist"

# The prompt must not promise more than this branch delivers. `model_summary` is
# RECORDED in the response here; nothing surfaces it to the driver until the
# reader lands, so claiming it reaches the author would send reviewers into the
# findings loop believing an observation was delivered when it was not.
if grep -qi 'surfaced to the author' "$PROMPT"; then
    die "prompt claims the note is surfaced, which no code in this branch does"
else
    pass "prompt claims recording, not surfacing (matches what ships here)"
fi

grep -qi 'intent, never permission' "$PROMPT" \
  && pass "scope context is marked untrusted" \
  || die "prompt does not mark scope context as untrusted"


# ── base-ref .review-bus.md: project guidance must not contradict the built-in ──
# The guidance block is appended AFTER the built-in observation rule, and it is
# trusted (it loads from the PR's BASE ref, so a PR cannot edit it). A project
# file claiming the note is "surfaced to the author" therefore overrides the
# built-in "RECORDED" statement with a promise no code keeps - reviewers would
# file a mixed-review note believing it reached the author. This fixture proves
# the guidance branch is actually reached, and that the built-in rule survives it.
REPO2="$TMP/repo2"; mkdir -p "$REPO2"
git -C "$REPO2" init -q
git -C "$REPO2" config user.email t@example.com
git -C "$REPO2" config user.name test
cat > "$REPO2/.review-bus.md" <<'GUIDE'
PROJECT_GUIDANCE_MARKER: enforce the house style.
GUIDE
echo seed > "$REPO2/seed.txt"
git -C "$REPO2" add -A; git -C "$REPO2" commit -qm base
git -C "$REPO2" branch -M main
FULL2="$(git -C "$REPO2" rev-parse HEAD)"

PROMPT2="$TMP/prompt2.txt"
( export REPO_DIR="$REPO2" BUS_DIR="$TMP/bus2" \
         REVIEW_BUS_REMOTE="git@github.com:test/demo.git"
  # shellcheck disable=SC1090
  source "$WATCHER" >/dev/null 2>&1
  build_prompt "$PROMPT2" 9 "${FULL2:0:7}" pr-branch "$FULL2" "$SNAP" "$REPO2" )

grep -q 'PROJECT_GUIDANCE_MARKER' "$PROMPT2" \
  && pass "base-ref .review-bus.md guidance reaches the prompt" \
  || die "base-ref guidance branch not exercised (marker absent)"

grep -qi 'EVERY review' "$PROMPT2" \
  && pass "the built-in observation rule survives alongside project guidance" \
  || die "project guidance displaced the built-in observation rule"

if grep -qi 'surfaced to the author\|delivered to the author' "$PROMPT2"; then
    die "the assembled prompt promises surfacing that no code in this branch does"
else
    pass "the assembled prompt (guidance included) promises recording, not surfacing"
fi

# This repository's OWN .review-bus.md is loaded verbatim into the prompt when
# reviewing this plugin, so the same contradiction has to be excluded at source.
# Skipped where the file is absent (vendored scripts / a checkout without it).
OWN_GUIDE="$SCRIPT_DIR/../../../.review-bus.md"
if [ -f "$OWN_GUIDE" ]; then
    if grep -qi 'surfaced to the author\|delivered to the author' "$OWN_GUIDE"; then
        die "this repo's .review-bus.md claims the summary is surfaced, which no shipped code does"
    else
        pass "this repo's .review-bus.md does not claim the summary is surfaced"
    fi
    grep -qi 'not yet surfaced\|recorded' "$OWN_GUIDE" \
      && pass "this repo's .review-bus.md states the note is recorded" \
      || die "this repo's .review-bus.md does not state the recorded-only status"
else
    pass ".review-bus.md not present in this checkout; own-guidance assertions skipped"
fi

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
