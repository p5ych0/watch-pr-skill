#!/usr/bin/env bash
# Regression: two origins that share a repo basename (alice/shared vs
# bob/shared) must derive DIFFERENT bus dirs, or one checkout's watcher could
# consume/mark-seen the other's requests. Exercises the watcher's actual header
# derivation via a subshell source (main() is guarded off when sourced).

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SELF_DIR/review-bus-codex-watcher.sh"
TMP="$(mktemp -d)"

# Derive BUS_DIR the way the real script does, for a given origin.
bus_for() {
    (
        export REVIEW_BUS_REMOTE="$1"
        export REPO_DIR="$TMP/repo"
        unset BUS_DIR
        mkdir -p "$REPO_DIR"
        source "$WATCHER" >/dev/null 2>&1
        printf '%s\n' "$BUS_DIR"
    )
}

a="$(bus_for 'git@github.com:alice/shared.git')"
b="$(bus_for 'https://github.com/bob/shared.git')"

# The sourced header mkdir's the derived bus dirs — clean them + TMP.
trap 'rm -rf "$TMP" "$a" "$b" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

printf 'alice/shared -> %s\n' "$a"
printf 'bob/shared   -> %s\n' "$b"

[ "$a" != "$b" ] && pass "same repo name, different owners -> different bus dirs" \
    || die "bus dir collision: both resolved to $a"
case "$a" in *alice*shared*) pass "alice bus includes owner + repo";; *) die "alice bus missing owner: $a";; esac
case "$b" in *bob*shared*)   pass "bob bus includes owner + repo";;   *) die "bob bus missing owner: $b";; esac

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
