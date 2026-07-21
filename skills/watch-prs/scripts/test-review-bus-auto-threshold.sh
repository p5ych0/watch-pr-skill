#!/usr/bin/env bash
# The PASSIVE auto-enqueue path (write_auto_request in the watcher) must honor the
# SAME round check-in as the manual review-bus-request.sh — otherwise the polling
# watcher bypasses the operator pause it emits. Regression for the shared-gate fix
# (review-bus-rounds.sh), plus a direct check of the shared helpers.
#
# Self-contained: throwaway repo + BUS_DIR. Sources the watcher (main() guarded off).

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SELF_DIR/review-bus-codex-watcher.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

export REPO_DIR="$TMP/repo"
export BUS_DIR="$TMP/bus"
export REVIEW_BUS_OWNER=acme REVIEW_BUS_REPO=widgets   # skip origin derivation
mkdir -p "$REPO_DIR"; git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email t@t.t; git -C "$REPO_DIR" config user.name t
echo x > "$REPO_DIR/f"; git -C "$REPO_DIR" add f; git -C "$REPO_DIR" commit -qm init

# shellcheck disable=SC1090
source "$WATCHER"
set +e

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

req_written() { ls "$BUS_DIR/requests"/req-*.json >/dev/null 2>&1; }
seed_rounds() {   # <count> distinct recorded SHAs for PR 7
    rm -rf "$BUS_DIR/.rounds" "$BUS_DIR/requests"; mkdir -p "$BUS_DIR/.rounds" "$BUS_DIR/requests"
    local n; for n in $(seq 1 "$1"); do printf 'seedsha%02d\n' "$n"; done > "$BUS_DIR/.rounds/pr-7.shas"
}
SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# ── Shared helpers (review-bus-rounds.sh) in isolation ──────────────────────
seed_rounds 10
review_bus_threshold_reached "$BUS_DIR" 7 "$SHA_A" 10 \
    && pass "helper: 10 rounds + new sha → threshold reached" || die "helper: threshold not reached at 10"
review_bus_threshold_reached "$BUS_DIR" 7 "$SHA_A" 0 \
    && die "helper: threshold=0 must disable" || pass "helper: threshold=0 disables the check-in"
# an already-recorded sha must NOT re-trigger the pause
printf '%s\n' "$SHA_A" >> "$BUS_DIR/.rounds/pr-7.shas"
review_bus_threshold_reached "$BUS_DIR" 7 "$SHA_A" 10 \
    && die "helper: an already-recorded sha re-triggered" || pass "helper: recorded sha does not re-trigger"

# ── Passive path: at the threshold it HOLDS (skip, no write, counter unchanged) ─
seed_rounds 10
out="$(write_auto_request 7 feat "$SHA_A" 2>&1)"
if printf '%s\n' "$out" | grep -q 'CODEX_AUTO_SKIP .*reason=round_threshold' && ! req_written; then
    pass "auto path: holds at the round threshold (skip, no request)"
else
    die "auto path: did NOT hold (out=$out, req_written=$(req_written && echo y || echo n))"
fi
[ "$(review_bus_rounds_done "$BUS_DIR" 7)" -eq 10 ] \
    && pass "auto path: counter unchanged at 10 (no bypass write)" \
    || die "auto path: counter moved off 10 ($(review_bus_rounds_done "$BUS_DIR" 7))"

# ── Passive path: below the threshold it enqueues AND records the round ──────
seed_rounds 9
out="$(write_auto_request 7 feat "$SHA_B" 2>&1)"
if printf '%s\n' "$out" | grep -q 'CODEX_AUTO_REQUEST ' && req_written; then
    pass "auto path: enqueues below the threshold"
else
    die "auto path: did not enqueue below threshold (out=$out)"
fi
{ [ "$(review_bus_rounds_done "$BUS_DIR" 7)" -eq 10 ] \
    && grep -qxF "$SHA_B" "$BUS_DIR/.rounds/pr-7.shas"; } \
    && pass "auto path: recorded the enqueued round (9→10, full sha)" \
    || die "auto path: did not record the round"

# ── Both paths share ONE counter (manual record advances the passive gate) ──
seed_rounds 9
review_bus_record_round "$BUS_DIR" 7 "$SHA_A"    # a MANUAL enqueue records round 10
review_bus_threshold_reached "$BUS_DIR" 7 "$SHA_B" 10 \
    && pass "shared counter: a manual round makes the passive path pause next" \
    || die "shared counter: manual record did not advance the passive gate"

# ── TOCTOU: two CONCURRENT distinct-SHA claims at the 9→10 boundary. The atomic
#    check-and-claim must let exactly ONE cross (records round 10) and the other
#    PAUSE (sees 10) — the counter advances by exactly one (10, never 11). This is
#    the interleaving the append-only lock did NOT close.
seed_rounds 9
( review_bus_claim_round "$BUS_DIR" 7 "$SHA_A" 10 > "$TMP/ra" ) &
( review_bus_claim_round "$BUS_DIR" 7 "$SHA_B" 10 > "$TMP/rb" ) &
wait
ra="$(cat "$TMP/ra")"; rb="$(cat "$TMP/rb")"
cnt="$(review_bus_rounds_done "$BUS_DIR" 7)"
if [ "$cnt" -eq 10 ] && [ "$(printf '%s\n%s\n' "$ra" "$rb" | sort -u | paste -sd, -)" = "claimed,pause" ]; then
    pass "atomic claim: concurrent boundary enqueue → one claims, one pauses (count 10, not 11)"
else
    die "atomic claim: TOCTOU not closed (ra=$ra rb=$rb count=$cnt)"
fi
# Run it a few more times: the interleaving must ALWAYS resolve to one-claim-one-pause.
races_ok=1
for _ in 1 2 3 4 5; do
    seed_rounds 9
    ( review_bus_claim_round "$BUS_DIR" 7 "$SHA_A" 10 >/dev/null ) &
    ( review_bus_claim_round "$BUS_DIR" 7 "$SHA_B" 10 >/dev/null ) &
    wait
    [ "$(review_bus_rounds_done "$BUS_DIR" 7)" -eq 10 ] || races_ok=0
done
[ "$races_ok" -eq 1 ] && pass "atomic claim: 5 repeated races all land the counter at 10 (never 11)" \
    || die "atomic claim: a repeated race let the counter reach 11 (pause skipped)"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
