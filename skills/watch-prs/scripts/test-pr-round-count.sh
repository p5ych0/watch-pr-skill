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

# Expand a short tag into a 40-hex SHA. `commit_id` is validated as a real SHA,
# so fixtures must look like commits: a short tag would be rejected as malformed
# and every case would pass for the wrong reason.
#
# sha1sum, not zero-padding: padding "c1" and "c10" to 40 characters produces the
# SAME string, which silently merged two rounds into one and made the boundary
# fixtures off by one.
sha() { printf '%s' "$1" | sha1sum | cut -c1-40; }

# `submitted_at != null` is what makes a record count as a submitted review, and
# the script now requires a well-formed ISO timestamp before believing that — so
# the fixtures have to carry real ones. The tag in a spec only has to be
# non-null; this turns it into a valid, distinct timestamp. `RAW:<json>` passes a
# value through untouched, for the cases that feed a deliberately bad one.
iso() { printf '"2026-01-%02dT00:00:00Z"' "$(( ($1 - 1) % 28 + 1 ))"; }

# Build a reviews list. Each argument is
#   "<login>|<commit-tag>|<submitted_at|null>[|<state-json>]"
# where the optional fourth field is the raw JSON for `state` — it defaults to a
# plain submitted review, and the state cases below override it.
mk() {
    local first=1 n=0 who c sub st
    { printf '['
      for spec in "$@"; do
          IFS='|' read -r who tag sub st <<<"$spec"
          c="$(sha "$tag")"
          n=$((n + 1))
          case "$sub" in
              null)   ;;
              RAW:*)  sub="${sub#RAW:}" ;;
              *)      sub="$(iso "$n")" ;;
          esac
          [ -n "$st" ] || st='"COMMENTED"'
          [ "$first" -eq 1 ] || printf ','
          first=0
          printf '{"user":{"login":"%s"},"commit_id":"%s","submitted_at":%s,"state":%s,"id":1}' \
              "$who" "$c" "$sub" "$st"
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

# Leading zeros are OCTAL to Bash arithmetic: `00` silently disabled the safety
# pause and `08`/`09` aborted with an undocumented exit 1 — neither being the
# documented fallback to 10.
#
# These existed once and were lost when the file was reverted to fix an unrelated
# fixture bug, so the guard shipped without them. That is exactly the regression
# this block prevents.
specs_lz=(); for i in $(seq 1 10); do specs_lz+=("$CODEX|lz$i|\"t$i\""); done
mk "${specs_lz[@]}"
for bad in 00 08 09 012; do
    out="$(REVIEW_ROUND_THRESHOLD="$bad" GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
    { [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'threshold=10'; } \
        && pass "threshold '$bad' falls back to 10, not to disabled or an error" \
        || die "threshold '$bad' gave rc=$rc out='$out'"
done
# Exactly `0` still disables the check-in.
out="$(REVIEW_ROUND_THRESHOLD=0 GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'threshold=0'; } \
    && pass "a bare 0 still disables the check-in" || die "0 no longer disables (rc=$rc)"

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

# ── a malformed submitted_at is not one more round ─────────────────────────
# `submitted_at != null` decides whether a record counts as a submitted review,
# so any old string satisfied it. One extra matching-reviewer record with a junk
# timestamp and a full-SHA commit_id was counted as another distinct head — and
# at a real boundary that inflates `rounds` past the multiple and SKIPS the
# operator pause, which is the direction that loses the safety check.
for bad in '"zzzz"' '""' '"2026-01-02"' '"2026-01-02T00:00:00zzzz"' '"not a timestamp"'; do
    mk "$CODEX|aaa|RAW:$bad"
    out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "submitted_at $bad => 2, not a counted round" \
        || die "malformed submitted_at $bad gave rc=$rc out='$out'"
done

# The exact case that skips the pause: 10 real rounds plus one junk-timestamp
# record must NOT report 11 and sail past the boundary.
specs=(); for i in $(seq 1 10); do specs+=("$CODEX|c$i|t"); done
specs+=("$CODEX|junk|RAW:\"zzzz\"")
mk "${specs[@]}"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a junk timestamp at the boundary fails closed instead of skipping the pause" \
    || die "junk timestamp at the boundary gave rc=$rc out='$out' (0 = the pause was skipped)"

# CANONICAL UTC only. Numeric offsets and fractional seconds are valid ISO 8601
# but do not sort chronologically under the LEXICAL sort the review helpers use —
# `03:00:00+02:00` is 01:00 UTC yet sorts after `02:30:00Z`, and `03:00:00.5Z`
# sorts before `03:00:00Z`. The same rule is applied in all three scripts so they
# cannot disagree about what a timestamp is. GitHub returns `Z` here.
mk "$CODEX|aaa|RAW:\"2026-01-02T03:04:05Z\""
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=1'; } \
    && pass "a canonical UTC submitted_at is a real round" \
    || die "canonical UTC timestamp was rejected (rc=$rc out='$out')"
for nonc in '"2026-01-02T03:04:05.123Z"' '"2026-01-02T03:04:05+01:00"' \
            '"2026-01-02T03:04:05-0500"' '"2026-01-02T03:04:05+00:00"'; do
    mk "$CODEX|aaa|RAW:$nonc"
    out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "non-canonical timestamp $nonc => 2" \
        || die "non-canonical $nonc was accepted (rc=$rc out='$out')"
done

# ── `state` decides whether a record is a finished pass ────────────────────
# Counting on `submitted_at` alone meant a record with a null or unrecognised
# state was still a reviewed head. One of those on a distinct full SHA turns a
# true boundary of 10 into 11 and skips the operator pause.
for badstate in 'null' '"WIBBLE"' '""' '123' '"approved"'; do
    mk "$CODEX|aaa|t|$badstate"
    out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "review state $badstate => 2, not a counted round" \
        || die "state $badstate gave rc=$rc out='$out'"
done

# Every state GitHub actually returns for a submitted review is still a round.
for goodstate in '"APPROVED"' '"CHANGES_REQUESTED"' '"COMMENTED"' '"DISMISSED"'; do
    mk "$CODEX|aaa|t|$goodstate"
    out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
    { [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=1'; } \
        && pass "state $goodstate is a round" \
        || die "valid state $goodstate was rejected (rc=$rc out='$out')"
done

# PENDING is a draft in flight, which is what pr-review-state.sh refuses to read
# as a signoff — so it is not a round however its timestamp reads. Readable, so
# it is a zero rather than an error.
mk "$CODEX|aaa|t|\"PENDING\""
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=0'; } \
    && pass "a PENDING draft is not a round" \
    || die "PENDING counted as a round (rc=$rc out='$out')"

# The case with the consequence: ten real rounds plus one bad-state record must
# not report eleven and sail past the boundary.
specs=(); for i in $(seq 1 10); do specs+=("$CODEX|c$i|t"); done
specs+=("$CODEX|rogue|t|null")
mk "${specs[@]}"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a null-state record at the boundary fails closed instead of skipping the pause" \
    || die "null-state record at the boundary gave rc=$rc out='$out' (0 = the pause was skipped)"

# A genuinely empty list is a readable zero, not an error.
printf '[]' > "$TMP/none.json"
out="$(GH_REVIEWS="$TMP/none.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=0'; } \
    && pass "no reviews yet is a readable zero" || die "empty list gave rc=$rc out='$out'"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
