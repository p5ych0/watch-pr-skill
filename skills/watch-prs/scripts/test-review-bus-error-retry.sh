#!/usr/bin/env bash
# Focused test for write_auto_request() error-response retry in
# review-bus-codex-watcher.sh.
#
# The review cap is unlimited by default (CODEX_REVIEW_MAX_ITERATIONS=0), but
# error-response auto-retries must STILL be bounded — by a DEDICATED
# CODEX_REVIEW_ERROR_RETRY_MAX counter (.codex-error-<pr>), reset on a successful
# review — so a persistently failing codex/GitHub error does not auto-requeue
# forever. (Regression for the "unlimited review cap unbounds error retries" bug.)
#
# Self-contained: throwaway BUS_DIR under a temp dir. No network, gh, or codex.
# Sources the watcher (main() is guarded off when sourced).

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SELF_DIR/review-bus-codex-watcher.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

export BUS_DIR="$TMP/bus"
export REPO_DIR="$TMP/repo"          # keep the watcher's anchors off the real tree
export WORKTREE_ROOT="$BUS_DIR/.codex-worktrees"
export CODEX_REVIEW_MAX_ITERATIONS=0     # unlimited review cap (the new default)
export CODEX_REVIEW_ERROR_RETRY_MAX=5    # the error-retry bound under test
mkdir -p "$REPO_DIR"

# shellcheck disable=SC1090
source "$WATCHER"
set +e

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

BRANCH="feature/x"
OID="a980dc3000000000000000000000000000000000"   # 40 hex; short = first 7
SHORT="${OID:0:7}"
REQ="$REQ_DIR/req-${SHORT}.json"
RESP="$RESP_DIR/resp-${SHORT}.json"
SEEN="$SEEN_DIR/req-${SHORT}.json"
ERRF="$BUS_DIR/.codex-error-42-${SHORT}"

reset_state() { rm -f "$REQ" "$RESP" "$SEEN" "$ERRF" "$BUS_DIR/.codex-iter-42"; }
mk_resp() { printf '{"pr":42,"sha":"%s","status":"%s","findings_count":0}\n' "$SHORT" "$1" > "$RESP"; }
mk_err()  { printf '%s\n' "$1" > "$ERRF"; }

# ── Case 1: error response under the error cap → re-request + counter bumps ───
reset_state
mk_resp error
: > "$REQ"; : > "$SEEN"      # request exists AND already seen (terminal-seen)
out="$(write_auto_request 42 "$BRANCH" "$OID")"
if grep -q 'CODEX_AUTO_REQUEST' <<< "$out" && [ "$(cat "$ERRF" 2>/dev/null)" = "1" ]; then
    pass "error under cap → re-requested + error counter=1"
else
    die "error under cap not re-requested / counter not bumped (out='$out' err='$(cat "$ERRF" 2>/dev/null)')"
fi

# ── Case 2: terminal non-error response → no re-request ──────────────────────
reset_state
mk_resp comments_posted
: > "$REQ"; : > "$SEEN"
out="$(write_auto_request 42 "$BRANCH" "$OID")"
[ -z "$out" ] && pass "comments_posted response → not re-requested" \
    || die "comments_posted was re-requested (out='$out')"

# ── Case 3: error at the error cap → NOT re-requested, even though the REVIEW
#            cap is unlimited (0). This is the regression. ────────────────────
reset_state
mk_resp error
: > "$REQ"; : > "$SEEN"
mk_err 5                     # error counter already at cap
out="$(write_auto_request 42 "$BRANCH" "$OID")"
[ -z "$out" ] && pass "error at error-cap → bounded (not re-requested) despite unlimited review cap" \
    || die "error at cap re-requested — unbounded error retry with MAX_ITERATIONS=0 (out='$out')"

# ── Case 4: no prior response → fresh request (baseline still works) ──────────
reset_state
out="$(write_auto_request 42 "$BRANCH" "$OID")"
grep -q 'CODEX_AUTO_REQUEST' <<< "$out" && pass "no prior response → fresh request" \
    || die "baseline fresh request failed (out='$out')"

# ── Case 5: POSITIVE review cap — a cap-exceeded error is TERMINAL, not retried
reset_state
mk_resp error
: > "$REQ"; : > "$SEEN"
printf '5\n' > "$BUS_DIR/.codex-iter-42"      # review-round counter at the positive cap
out="$(MAX_ITERATIONS=5 write_auto_request 42 "$BRANCH" "$OID")"
[ -z "$out" ] && pass "positive cap: cap-exceeded error not retried (terminal)" \
    || die "positive cap: cap-exceeded error was re-requested (out='$out')"

# ── Case 6: POSITIVE cap but UNDER it — a transient error still retries ───────
reset_state
mk_resp error
: > "$REQ"; : > "$SEEN"
printf '2\n' > "$BUS_DIR/.codex-iter-42"      # under the cap
out="$(MAX_ITERATIONS=5 write_auto_request 42 "$BRANCH" "$OID")"
grep -q 'CODEX_AUTO_REQUEST' <<< "$out" && pass "positive cap, under it: transient error re-requested" \
    || die "positive cap, under it: transient error NOT re-requested (out='$out')"

# ── Case 7: per-SHA budget — exhausting sha A must not starve a later sha B ───
OID_B="b111111000000000000000000000000000000000"; SHORT_B="${OID_B:0:7}"
REQ_B="$REQ_DIR/req-${SHORT_B}.json"; RESP_B="$RESP_DIR/resp-${SHORT_B}.json"
SEEN_B="$SEEN_DIR/req-${SHORT_B}.json"; ERRF_B="$BUS_DIR/.codex-error-42-${SHORT_B}"
reset_state; rm -f "$REQ_B" "$RESP_B" "$SEEN_B" "$ERRF_B"
printf '5\n' > "$ERRF"                                # sha A's budget exhausted
printf '{"pr":42,"sha":"%s","status":"error","findings_count":0}\n' "$SHORT_B" > "$RESP_B"
: > "$REQ_B"; : > "$SEEN_B"
out="$(write_auto_request 42 "$BRANCH" "$OID_B")"
if grep -q 'CODEX_AUTO_REQUEST' <<< "$out" && [ "$(cat "$ERRF_B" 2>/dev/null)" = "1" ]; then
    pass "per-SHA budget: sha B gets its own retry budget despite sha A exhausted"
else
    die "per-SHA budget: sha B starved by sha A's counter (out='$out' errB='$(cat "$ERRF_B" 2>/dev/null)')"
fi

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
