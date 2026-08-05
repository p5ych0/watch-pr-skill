#!/usr/bin/env bash
# Unit tests for pr-round-count.sh.
#
# The v1 pause lived in a /tmp counter file, so the guarantee quietly evaporated
# on a new machine or after a cleanup. These cases pin the two properties that
# matter: the count is derived from GitHub every time, and anything unreadable
# stops rather than reading as "no rounds yet" — which is the direction that
# skips the pause.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/pr-round-count.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

CODEX='chatgpt-codex-connector[bot]'
COPILOT='copilot-pull-request-reviewer[bot]'

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"/reviews"*) [ -n "${GH_RC:-}" ] && exit "$GH_RC"; cat "${GH_REVIEWS:-/dev/null}" ;;
  *) printf '{}' ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
run() { REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" "$@"; }

# Build a reviews list: each argument is "<login>|<commit>|<submitted_at|null>".
mk() {
    local first=1
    { printf '['
      for spec in "$@"; do
          who="${spec%%|*}"; rest="${spec#*|}"; c="${rest%%|*}"; sub="${rest##*|}"
          [ "$first" -eq 1 ] || printf ','
          first=0
          printf '{"user":{"login":"%s"},"commit_id":"%s","submitted_at":%s,"state":"COMMENTED","id":1}' \
              "$who" "$c" "$sub"
      done
      printf ']'
    } > "$TMP/reviews.json"
}

# ── a round is a distinct reviewed HEAD ────────────────────────────────────
mk "$CODEX|aaa|\"t1\"" "$COPILOT|aaa|\"t1\""
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=1'; } \
    && pass "two reviewers on one head is ONE round" \
    || die "same-head reviews counted twice (rc=$rc out='$out')"

mk "$CODEX|aaa|\"t1\"" "$CODEX|aaa|\"t2\""
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
printf '%s' "$out" | grep -q 'rounds=1' \
    && pass "a re-review of an unchanged head does not inflate the count" \
    || die "re-review inflated the count: $out"

mk "$CODEX|aaa|\"t1\"" "$CODEX|bbb|\"t2\"" "$CODEX|ccc|\"t3\""
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=3'; } \
    && pass "three distinct heads is three rounds" \
    || die "distinct-head count wrong (rc=$rc out='$out')"

# An UNSUBMITTED draft is not a round: the pass has not happened yet.
mk "$CODEX|aaa|\"t1\"" "$CODEX|bbb|null"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"
printf '%s' "$out" | grep -q 'rounds=1' \
    && pass "a draft review is not a round" \
    || die "a draft counted as a round: $out"

# Reviews by anyone else are not rounds.
mk "$CODEX|aaa|\"t1\"" "somebody|bbb|\"t2\""
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"
printf '%s' "$out" | grep -q 'rounds=1' \
    && pass "a human review is not a round" \
    || die "a non-reviewer counted: $out"

# ── the boundary pauses, and only ON the boundary ──────────────────────────
specs=(); for i in $(seq 1 9); do specs+=("$CODEX|c$i|\"t$i\""); done
mk "${specs[@]}"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "9 rounds: no pause" || die "paused early at 9 (rc=$rc)"

specs+=("$CODEX|c10|\"t10\""); mk "${specs[@]}"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'PR_ROUND_PAUSE'; } \
    && pass "10 rounds: pause (exit 3)" \
    || die "no pause at the boundary (rc=$rc out='$out')"

specs+=("$CODEX|c11|\"t11\""); mk "${specs[@]}"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "11 rounds: the pause does not stick" || die "still pausing at 11 (rc=$rc)"

# The pause re-arms for the next multiple.
for i in $(seq 12 20); do specs+=("$CODEX|c$i|\"t$i\""); done
mk "${specs[@]}"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && pass "20 rounds: the pause re-arms" || die "no pause at the second boundary (rc=$rc)"

# ── threshold handling ─────────────────────────────────────────────────────
mk "$CODEX|aaa|\"t1\"" "$CODEX|bbb|\"t2\""
out="$(REVIEW_ROUND_THRESHOLD=2 GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && pass "an explicit threshold is honoured" || die "threshold=2 did not pause (rc=$rc)"
out="$(REVIEW_ROUND_THRESHOLD=0 GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'threshold=0'; } \
    && pass "threshold=0 disables the check-in" || die "threshold=0 still paused (rc=$rc)"
# A typo must not silently disable a safety pause.
specs2=(); for i in $(seq 1 10); do specs2+=("$CODEX|d$i|\"t$i\""); done
mk "${specs2[@]}"
out="$(REVIEW_ROUND_THRESHOLD=abc GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'threshold=10'; } \
    && pass "a malformed threshold falls back to 10, never to disabled" \
    || die "a typo disabled the check-in (rc=$rc out='$out')"

# ── everything unreadable fails closed ─────────────────────────────────────
out="$(GH_RC=1 run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "fetch failure => 2" || die "fetch failure gave rc=$rc"
: > "$TMP/empty.json"
out="$(GH_REVIEWS="$TMP/empty.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "empty output => 2 (zero pages is not zero rounds)" || die "empty output gave rc=$rc"
printf '{"message":"Not Found"}' > "$TMP/bad.json"
out="$(GH_REVIEWS="$TMP/bad.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "object-shaped page => 2" || die "object page gave rc=$rc"
printf '[{}]' > "$TMP/rec.json"
out="$(GH_REVIEWS="$TMP/rec.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "empty review records => 2" || die "[{}] gave rc=$rc"

# A genuinely empty list is a readable zero, not an error.
printf '[]' > "$TMP/none.json"
out="$(GH_REVIEWS="$TMP/none.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=0'; } \
    && pass "no reviews yet is a readable zero" || die "empty list gave rc=$rc out='$out'"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
