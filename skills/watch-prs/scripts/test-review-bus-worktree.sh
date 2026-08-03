#!/usr/bin/env bash
# Focused test for prepare_review_worktree() in review-bus-codex-watcher.sh.
#
# Regression cover for the same-SHA dirty-worktree reuse case: because Codex
# runs with `-s workspace-write`, a prior review pass can leave tracked edits
# or untracked files in a per-SHA review worktree. A same-SHA re-enqueue
# (resolve-threads-then-repoll, no new push) reuses that worktree, so it MUST
# be restored to the requested commit before the reviewer reads it — otherwise
# the reviewer sees source that is not in the PR while the snapshot diff still
# reflects the clean SHA.
#
# Self-contained: throwaway git repo + BUS_DIR under a temp dir. No network,
# no gh, no codex. Sources the watcher (main() is guarded off when sourced).

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SELF_DIR/review-bus-codex-watcher.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

# Override the watcher's env anchors BEFORE sourcing so nothing touches the
# real repo or the real /tmp/strumok-review-bus.
export REPO_DIR="$TMP/repo"
export BUS_DIR="$TMP/bus"
export WORKTREE_ROOT="$BUS_DIR/.codex-worktrees"

mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email test@example.com
git -C "$REPO_DIR" config user.name test
printf 'clean\n' > "$REPO_DIR/file.txt"
printf '*.ignoredcache\n' > "$REPO_DIR/.gitignore"
git -C "$REPO_DIR" add file.txt .gitignore
git -C "$REPO_DIR" commit -qm init
SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
SHORT="${SHA:0:7}"

# shellcheck disable=SC1090
source "$WATCHER"
set +e   # the watcher's `set -e` should not govern the test assertions below

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# 1. First call creates the detached worktree at the requested SHA.
WT="$(prepare_review_worktree 7 "$SHORT" "$SHA")"
if [ -d "$WT" ] && [ "$(git -C "$WT" rev-parse HEAD)" = "$SHA" ]; then
    pass "worktree created at requested SHA"
else
    die "worktree not created at requested SHA"
fi

# 1b. The worker marker is stamped into the worktree's GIT DIR. The SessionStart
#     hook's env-free fallback reads exactly this file, so if the producer here
#     regresses the hook silently arms the bus from inside a review again — and
#     the hook's own suite would stay green, because it creates the marker by
#     hand. It must live in the git dir, never the working tree, or it would show
#     up as an untracked file in the reviewed diff.
WT_GIT_DIR="$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)"
[ -n "$WT_GIT_DIR" ] && [ -f "$WT_GIT_DIR/review-bus-worker" ] \
    && pass "worker marker stamped in the worktree git dir" \
    || die "worker marker missing at $WT_GIT_DIR/review-bus-worker"
[ -z "$(git -C "$WT" status --porcelain)" ] \
    && pass "marker does not dirty the worktree (git dir, not working tree)" \
    || die "marker leaked into the working tree: $(git -C "$WT" status --porcelain | tr '\n' ';')"

# 2. Simulate workspace-write residue from a prior pass: a tracked edit plus an
#    untracked stray file.
printf 'DIRTY tracked edit\n' >> "$WT/file.txt"
printf 'stray\n' > "$WT/untracked-stray.txt"
printf 'ignored\n' > "$WT/residue.ignoredcache"   # matches .gitignore → invisible to status --porcelain
[ -n "$(git -C "$WT" status --porcelain)" ] || die "precondition: worktree should be dirty"
[ -e "$WT/residue.ignoredcache" ] || die "precondition: ignored residue should exist"

# 3. Same-SHA reuse must return the SAME path, restored to pristine.
WT2="$(prepare_review_worktree 7 "$SHORT" "$SHA")"
[ "$WT2" = "$WT" ] || die "reuse returned a different path ($WT2 != $WT)"
if [ -z "$(git -C "$WT2" status --porcelain)" ]; then
    pass "reused worktree restored to pristine (no dirty tracked/untracked)"
else
    die "reused worktree still dirty: $(git -C "$WT2" status --porcelain | tr '\n' ';')"
fi
[ ! -e "$WT2/untracked-stray.txt" ] && pass "untracked residue removed on reuse" \
    || die "untracked residue survived reuse"
[ ! -e "$WT2/residue.ignoredcache" ] && pass "ignored residue removed on reuse (clean -ffdx)" \
    || die "ignored residue survived reuse"
[ "$(cat "$WT2/file.txt")" = "clean" ] && pass "tracked edit reverted to requested SHA" \
    || die "tracked edit not reverted"

# 4. HEAD is still the requested SHA after cleaning.
[ "$(git -C "$WT2" rev-parse HEAD)" = "$SHA" ] && pass "reused worktree HEAD still at requested SHA" \
    || die "reused worktree HEAD drifted"

# 4b. The marker survives the reuse path too. `git clean -ffdx` runs against the
#     working tree, so it must not remove it — but the reuse branch is a separate
#     code path from the create branch and could stop stamping independently.
[ -f "$WT_GIT_DIR/review-bus-worker" ] \
    && pass "worker marker still present after same-SHA reuse" \
    || die "worker marker lost on reuse"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
