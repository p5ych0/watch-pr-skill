#!/usr/bin/env bash
# Focused test for the dedicated review clone (start.sh --ensure-clone).
#
# The daemons must operate on a clone that is ISOLATED from the implementer's
# working tree, so a branch-switch/checkout/merge there can't disrupt the
# reviewer. Proves:
#   - a review clone is created,
#   - its origin points at the real remote (so it can fetch PR heads),
#   - it is idempotent (reuse on re-run),
#   - a branch-switch in the implementer tree does NOT move the review clone.
#
# Self-contained: temp bare origin + implementer checkout + bus. No network.

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
START="$SELF_DIR/review-bus-codex-start.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

ORIGIN="$TMP/origin.git"
IMPL="$TMP/impl"
BUS="$TMP/bus"
REVIEW="$BUS/.review-clone"

git init --quiet --bare "$ORIGIN"
git clone --quiet "$ORIGIN" "$IMPL" 2>/dev/null
git -C "$IMPL" config user.email t@example.com
git -C "$IMPL" config user.name test
printf 'x\n' > "$IMPL/f"
git -C "$IMPL" add f
git -C "$IMPL" commit --quiet -m init

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

run_ensure() { REPO_DIR="$IMPL" BUS_DIR="$BUS" bash "$START" --ensure-clone; }

out="$(run_ensure)"
git -C "$REVIEW" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && pass "review clone created" || die "review clone not created ($out)"

o="$(git -C "$REVIEW" remote get-url origin 2>/dev/null)"
[ "$o" = "$ORIGIN" ] && pass "clone origin points at the real remote" \
    || die "clone origin wrong: $o != $ORIGIN"

run_ensure >/dev/null
git -C "$REVIEW" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && pass "idempotent reuse on re-run" || die "clone broke on second --ensure-clone"

# Isolation: switch the implementer to a new branch + commit; the review clone
# HEAD must not move (root cause of the mid-loop watcher death).
before="$(git -C "$REVIEW" rev-parse HEAD)"
git -C "$IMPL" checkout --quiet -b other
printf 'y\n' >> "$IMPL/f"
git -C "$IMPL" add f
git -C "$IMPL" commit --quiet -m other
after="$(git -C "$REVIEW" rev-parse HEAD)"
[ "$before" = "$after" ] && pass "implementer branch-switch does not move the review clone" \
    || die "review clone HEAD moved with the implementer ($before -> $after)"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
