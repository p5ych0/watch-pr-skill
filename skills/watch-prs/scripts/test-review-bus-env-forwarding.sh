#!/usr/bin/env bash
# Focused test for review-bus-codex-start.sh's systemd env forwarding.
#
# systemd --user units start from a CLEAN environment, so start.sh must forward
# every operator-tunable CODEX_REVIEW_* knob explicitly or it silently resets to
# the watcher's default. Regression for the setsid->systemd migration: prove the
# iteration cap (and the other knobs) survive, defaults are seeded, and the
# removed guidance override is NOT smuggled back in.
#
# Sources start.sh with REVIEW_BUS_LIB_ONLY=1, which short-circuits before any
# side effect, exposing the pure codex_watcher_setenv() helper.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
START="$SCRIPT_DIR/review-bus-codex-start.sh"

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# Print the forwarded --setenv args for the current environment.
setenv() { ( REVIEW_BUS_LIB_ONLY=1; source "$START" >/dev/null 2>&1; codex_watcher_setenv ); }

# ── An operator override of the iteration cap survives the migration ─────────
out="$(CODEX_REVIEW_MAX_ITERATIONS=5 setenv)"
echo "$out" | grep -qx -- '--setenv=CODEX_REVIEW_MAX_ITERATIONS=5' \
    && pass "MAX_ITERATIONS override survives the systemd migration" \
    || die "MAX_ITERATIONS override not forwarded"

# ── The other previously-dropped knobs are forwarded when set ────────────────
out="$(CODEX_REVIEW_AUTO_POLL_SECONDS=7 CODEX_REVIEW_AUTO_PR_LIMIT=3 CODEX_REVIEW_WORKTREE_ROOT=/tmp/wt setenv)"
for kv in CODEX_REVIEW_AUTO_POLL_SECONDS=7 CODEX_REVIEW_AUTO_PR_LIMIT=3 CODEX_REVIEW_WORKTREE_ROOT=/tmp/wt; do
    echo "$out" | grep -qx -- "--setenv=$kv" && pass "forwarded $kv" || die "did not forward $kv"
done

# ── Always-on knobs get sane defaults even in a clean env ────────────────────
out="$(env -u CODEX_REVIEW_MODEL -u CODEX_REVIEW_AUTO_OPEN_PRS -u CODEX_REVIEW_REASONING_EFFORT \
        bash -c 'REVIEW_BUS_LIB_ONLY=1 source "$1" >/dev/null 2>&1; codex_watcher_setenv' _ "$START")"
echo "$out" | grep -qx -- '--setenv=CODEX_REVIEW_MODEL=gpt-5.6-sol'  && pass "MODEL default seeded"        || die "MODEL default missing"
echo "$out" | grep -qx -- '--setenv=CODEX_REVIEW_AUTO_OPEN_PRS=1' && pass "AUTO_OPEN_PRS default seeded" || die "AUTO_OPEN_PRS default missing"

# ── Iteration cap defaults to unlimited (0); the skill drives the pause ───────
out="$(env -u CODEX_REVIEW_MAX_ITERATIONS bash -c 'REVIEW_BUS_LIB_ONLY=1 source "$1" >/dev/null 2>&1; codex_watcher_setenv' _ "$START")"
echo "$out" | grep -qx -- '--setenv=CODEX_REVIEW_MAX_ITERATIONS=0' && pass "iteration cap defaults to unlimited (0)" || die "cap default is not 0/unlimited"

# ── The removed guidance override must never be forwarded ────────────────────
out="$(REVIEW_BUS_GUIDANCE_FILE=/tmp/evil.md setenv)"
echo "$out" | grep -q 'REVIEW_BUS_GUIDANCE_FILE' \
    && die "REVIEW_BUS_GUIDANCE_FILE forwarded (guidance must stay base-ref-only)" \
    || pass "REVIEW_BUS_GUIDANCE_FILE not forwarded (guidance stays base-ref-only)"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
