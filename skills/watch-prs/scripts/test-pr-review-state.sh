#!/usr/bin/env bash
# Unit tests for pr-review-state.sh, with a stubbed `gh` on PATH.
#
# Every case here is a defect that was found and fixed while this logic lived in
# the v1 Copilot helper. They are kept because the failure mode is always the
# same shape: something unreadable answering as though it were "nothing to worry
# about", which is merge permission.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/pr-review-state.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

BOT='chatgpt-codex-connector[bot]'
HEAD40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# GH_REVIEWS   file: JSON for  api repos/*/pulls/*/reviews
# GH_COMMENTS  file: JSON for  api repos/*/pulls/*/reviews/<id>/comments
# GH_HEAD      string: headRefOid ; GH_HEAD_RC: its exit code
# GH_REVIEWS_RC / GH_COMMENTS_RC: force a fetch failure
case "$1 ${2:-}" in
  *"api "*)
    case "$*" in
      *"/reviews/"*"/comments"*)
        [ -n "${GH_COMMENTS_RC:-}" ] && exit "$GH_COMMENTS_RC"
        args="$*"; rid="${args##*/reviews/}"; rid="${rid%%/comments*}"
        if [ -n "${GH_FIXTURE_DIR:-}" ] && [ -f "$GH_FIXTURE_DIR/comments-$rid.json" ]; then
          cat "$GH_FIXTURE_DIR/comments-$rid.json"
        else cat "${GH_COMMENTS:-/dev/null}"; fi ;;
      *"/reviews"*) [ -n "${GH_REVIEWS_RC:-}" ] && exit "$GH_REVIEWS_RC"; cat "${GH_REVIEWS:-/dev/null}" ;;
      *) printf '{}' ;;
    esac ;;
  *"pr view"*) printf '%s' "${GH_HEAD:-}"; exit "${GH_HEAD_RC:-0}" ;;
  *) printf '{}' ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_FIXTURE_DIR="$TMP"

run() { REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" "$@"; }
mk_reviews() {   # <state> <submitted_at|null> <id>
    printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"%s","submitted_at":%s,"id":%s}]' \
        "$BOT" "$HEAD40" "$1" "$2" "$3" > "$TMP/reviews.json"
}

# ── identity is derived, never hard-coded ──────────────────────────────────
out="$(PR_REVIEW_STATE_LIB_ONLY=1 REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        bash -c 'source "$1"; echo "$REPO_SLUG"' _ "$SCRIPT" 2>&1)"
# The slug now carries the HOST as well, so a `GH_HOST` override cannot send
# these calls to the same-numbered PR on another GitHub host.
[ "$out" = "github.com/acme/widget" ] && pass "identity derived from origin, host included" \
    || die "identity/source guard wrong (got: $out)"

# ── state: each review state is judged, not counted ────────────────────────
# A comment count cannot tell a signoff from a dismissal, a changes-requested
# review with no inline comments, or a re-review that is still a draft. All three
# have zero comments.
for case in 'PENDING|null|pending' 'DISMISSED|"2026-01-01T00:00:00Z"|dismissed' \
            'CHANGES_REQUESTED|"2026-01-01T00:00:00Z"|blocked' \
            'APPROVED|"2026-01-01T00:00:00Z"|reviewed' \
            'COMMENTED|"2026-01-01T00:00:00Z"|reviewed'
do
    st="${case%%|*}"; rest="${case#*|}"; sub="${rest%%|*}"; want="${rest##*|}"
    mk_reviews "$st" "$sub" 11
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" run state 7 "$BOT" 2>&1)"
    printf '%s' "$out" | grep -q "state=$want" \
        && pass "state: $st => $want" \
        || die "state: $st gave '$out' (want $want)"
done

printf '[]' > "$TMP/none.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/none.json" run state 7 "$BOT" 2>&1)"
printf '%s' "$out" | grep -q 'state=none' && pass "state: no review => none" \
    || die "state: empty review list gave '$out'"

# A review on ANOTHER head says nothing about this one.
# A FULL sha for the other head: commit_id is validated, so a short one would be
# rejected as malformed and this case would pass without testing head scoping.
OTHER40="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z","id":12}]' \
    "$BOT" "$OTHER40" > "$TMP/other.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/other.json" run state 7 "$BOT" 2>&1)"
printf '%s' "$out" | grep -q 'state=none' && pass "state: a review on another head does not count" \
    || die "state: an other-head review leaked in: $out"

# The LATEST submitted review is authoritative: an old clean review followed by a
# dismissal is not a signoff, and the reverse still is.
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"COMMENTED","submitted_at":"2026-01-01T00:00:00Z","id":21},{"user":{"login":"%s"},"commit_id":"%s","state":"DISMISSED","submitted_at":"2026-01-02T00:00:00Z","id":22}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/seq.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/seq.json" run state 7 "$BOT" 2>&1)"
printf '%s' "$out" | grep -q 'state=dismissed' \
    && pass "state: a later dismissal overrides an earlier clean review" \
    || die "state: old-clean-then-dismissed gave '$out'"
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"DISMISSED","submitted_at":"2026-01-01T00:00:00Z","id":23},{"user":{"login":"%s"},"commit_id":"%s","state":"APPROVED","submitted_at":"2026-01-02T00:00:00Z","id":24}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/seq2.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/seq2.json" run state 7 "$BOT" 2>&1)"
printf '%s' "$out" | grep -q 'state=reviewed' \
    && pass "state: a later approval supersedes an earlier dismissal" \
    || die "state: dismissed-then-approved gave '$out'"

# A draft dominates: a re-review in flight means the pass is not finished.
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"COMMENTED","submitted_at":"2026-01-01T00:00:00Z","id":25},{"user":{"login":"%s"},"commit_id":"%s","state":"PENDING","submitted_at":null,"id":26}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/draft.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/draft.json" run state 7 "$BOT" 2>&1)"
printf '%s' "$out" | grep -q 'state=pending' \
    && pass "state: an in-flight re-review outranks the earlier clean one" \
    || die "state: clean-plus-draft gave '$out'"

# ── verdict: only an accepted review with zero findings is clean ───────────
mk_reviews APPROVED '"2026-01-01T00:00:00Z"' 31
printf '[]' > "$TMP/comments-31.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'verdict=clean'; } \
    && pass "verdict: approved with zero comments => clean (0)" \
    || die "verdict: clean case gave rc=$rc '$out'"

printf '[{"path":"a.sh","line":1,"body":"x"},{"path":"b.sh","line":2,"body":"y"}]' > "$TMP/comments-31.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'findings=2'; } \
    && pass "verdict: inline comments => findings (1)" \
    || die "verdict: findings case gave rc=$rc '$out'"

for st in PENDING:null DISMISSED:'"2026-01-01T00:00:00Z"' CHANGES_REQUESTED:'"2026-01-01T00:00:00Z"'; do
    mk_reviews "${st%%:*}" "${st#*:}" 32
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
    [ "$rc" -eq 1 ] && pass "verdict: ${st%%:*} is never clean" \
        || die "verdict: ${st%%:*} gave rc=$rc '$out'"
done

# ── everything unreadable fails closed (2), never 'clean' ──────────────────
mk_reviews APPROVED '"2026-01-01T00:00:00Z"' 41
printf '[]' > "$TMP/comments-41.json"

out="$(GH_HEAD="$HEAD40" GH_REVIEWS_RC=1 run verdict 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "unreadable: reviews fetch fails => 2" || die "reviews-fetch failure gave rc=$rc"

out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_COMMENTS_RC=1 run verdict 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "unreadable: comments fetch fails => 2" || die "comments-fetch failure gave rc=$rc"

# A `gh` call that PRINTS a plausible SHA and then fails is a failure: command
# substitution keeps what was written before the error.
out="$(GH_HEAD="$HEAD40" GH_HEAD_RC=1 GH_REVIEWS="$TMP/reviews.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "unreadable: head lookup that prints then fails => 2" \
    || die "stdout-plus-failure head lookup gave rc=$rc"

out="$(GH_HEAD="abc123" GH_REVIEWS="$TMP/reviews.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "unreadable: a non-40-hex head => 2" || die "short head gave rc=$rc"

# `jq -s` turns empty input into ZERO pages, where `any([]; ...)` is false - so an
# empty-but-successful fetch slipped through as a count of 0.
: > "$TMP/empty-out.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty-out.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "unreadable: empty reviews output => 2 (zero pages is not zero reviews)" \
    || die "empty reviews output gave rc=$rc '$out'"
mk_reviews APPROVED '"2026-01-01T00:00:00Z"' 42
: > "$TMP/comments-42.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "unreadable: empty comments output => 2" \
    || die "empty comments output gave rc=$rc '$out'"

# A page that is not an array - a 200-with-error body - is not data.
printf '{"message":"Not Found"}' > "$TMP/badpage.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/badpage.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "unreadable: object-shaped reviews page => 2" || die "object page gave rc=$rc"
mk_reviews APPROVED '"2026-01-01T00:00:00Z"' 43
printf '{}' > "$TMP/comments-43.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "unreadable: object-shaped comments page => 2" || die "object comments page gave rc=$rc"

# Records missing the fields the callers read are equally unusable: `[{}]` passed
# the array check and produced [], which reads as "no review".
printf '[{}]' > "$TMP/emptyrec.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/emptyrec.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "unreadable: empty review records => 2" || die "[{}] gave rc=$rc"

# ── an explicit head must be a FULL sha ───────────────────────────────────
# `abc123` is all-hex, so a character-only check accepted it and the commit_id
# filter matched nothing — reporting state=none, which the merge gate reads as
# "Codex has not judged this head" and answers by trusting an older signoff.
mk_reviews APPROVED '"2026-01-01T00:00:00Z"' 61
for shorthead in abc abc123 0123456789abcdef; do
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" run state 7 "$BOT" "$shorthead" 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "an explicit short head ('$shorthead') => 2, not state=none" \
        || die "short head '$shorthead' gave rc=$rc out='$out'"
    printf '%s' "$out" | grep -q 'state=none' \
        && die "short head '$shorthead' was reported as state=none" \
        || pass "short head '$shorthead' is not reported as an absent review"
done

# ── submitted_at must look like a timestamp, because the sort is LEXICAL ───
# `head_review_snapshot` sorts on it to pick the authoritative review, so
# "zzzz" sorts after every real ISO timestamp: a stale APPROVED could outrank a
# current CHANGES_REQUESTED and report clean.
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"CHANGES_REQUESTED","submitted_at":"2026-01-02T00:00:00Z","id":71},{"user":{"login":"%s"},"commit_id":"%s","state":"APPROVED","submitted_at":"zzzz","id":72}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/badts.json"
# The stale APPROVED must have a READABLE empty comment list, or the unfixed code
# fails for a different reason (no comments page) and this fixture would pass
# without ever exercising the timestamp rule.
printf '[]' > "$TMP/comments-72.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/badts.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a non-timestamp submitted_at => 2 (never sorted above a real review)" \
    || die "bad timestamp gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'verdict=clean' \
    && die "a stale APPROVED with a junk timestamp reported CLEAN: $out" \
    || pass "no clean verdict from a junk timestamp"
# Canonical UTC works; the non-canonical forms are rejected below, because the
# sort that decides which review is authoritative is lexical.
for ts in '"2026-01-01T00:00:00Z"'; do
    mk_reviews APPROVED "$ts" 73
    printf '[]' > "$TMP/comments-73.json"
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && pass "a real ISO timestamp ($ts) is accepted" \
        || die "valid timestamp $ts rejected (rc=$rc out='$out')"
done

# A review's own commit_id must be a full SHA. Short or non-SHA values were
# filtered out as "another head", so a malformed page read as state=none — which
# the merge gate answers by trusting an older signoff instead of stopping.
for badsha in abc 0123456789abcdef "" not-a-sha; do
    printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z","id":81}]' \
        "$BOT" "$badsha" > "$TMP/badcommit.json"
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/badcommit.json" run state 7 "$BOT" 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "a review with commit_id '${badsha:-<empty>}' => 2, not state=none" \
        || die "commit_id '${badsha:-<empty>}' gave rc=$rc out='$out'"
done

# The timestamp check must be ANCHORED. A prefix match let
# `2026-01-02T00:00:00zzzz` through, and it sorts after the real
# `2026-01-02T00:00:00Z` — the same lexical hole the check was added to close.
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"CHANGES_REQUESTED","submitted_at":"2026-01-02T00:00:00Z","id":91},{"user":{"login":"%s"},"commit_id":"%s","state":"APPROVED","submitted_at":"2026-01-02T00:00:00zzzz","id":92}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/prefixts.json"
printf '[]' > "$TMP/comments-92.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/prefixts.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a same-prefix malformed timestamp => 2" \
    || die "prefix-matching timestamp gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'verdict=clean' \
    && die "a stale APPROVED with a prefix-valid timestamp reported CLEAN: $out" \
    || pass "no clean verdict from a prefix-valid timestamp"

# ── the sort is LEXICAL, so the format must make lexical == chronological ──
# A numeric offset is valid ISO 8601 and passes any format check that allows it,
# but does not order correctly: `03:00:00+02:00` is 01:00 UTC and therefore
# EARLIER than `02:30:00Z`, yet sorts after it. An older APPROVED would then
# outrank a newer CHANGES_REQUESTED and report clean — the exact hole the
# anchored check was added to close, in a subtler form.
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"CHANGES_REQUESTED","submitted_at":"2026-01-02T02:30:00Z","id":95},{"user":{"login":"%s"},"commit_id":"%s","state":"APPROVED","submitted_at":"2026-01-02T03:00:00+02:00","id":96}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/offsetts.json"
printf '[]' > "$TMP/comments-96.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/offsetts.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "an offset timestamp => 2, rather than sorting above a newer UTC review" \
    || die "offset timestamp gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'verdict=clean' \
    && die "an older APPROVED (+02:00) outranked a newer CHANGES_REQUESTED: $out" \
    || pass "no clean verdict from an offset-timestamped approval"

# Fractional seconds fail the same way in the other direction: `03:00:00.5Z`
# sorts BEFORE `03:00:00Z`, because '.' is below 'Z' in ASCII.
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"APPROVED","submitted_at":"2026-01-02T03:00:00Z","id":97},{"user":{"login":"%s"},"commit_id":"%s","state":"CHANGES_REQUESTED","submitted_at":"2026-01-02T03:00:00.5Z","id":98}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/fracts.json"
printf '[]' > "$TMP/comments-97.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/fracts.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a fractional-second timestamp => 2" \
    || die "fractional timestamp gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'verdict=clean' \
    && die "a newer CHANGES_REQUESTED sorted below an older APPROVED: $out" \
    || pass "no clean verdict from a fractional-second timestamp"

# ── the clean verdict is re-checked against a second snapshot ──────────────
# State and count came from separate fetches once, so a review that changed in
# between was judged on one snapshot and counted on another.
cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"/reviews/"*"/comments"*) printf '[]' ;;
  *"/reviews"*)
     if [ ! -e "$TMP/seen" ]; then
        : > "$TMP/seen"
        printf '[{"user":{"login":"$BOT"},"commit_id":"$HEAD40","state":"COMMENTED","submitted_at":"2026-01-01T00:00:00Z","id":51}]'
     else
        printf '[{"user":{"login":"$BOT"},"commit_id":"$HEAD40","state":"DISMISSED","submitted_at":"2026-01-02T00:00:00Z","id":52}]'
     fi ;;
  *"pr view"*) printf '%s' "$HEAD40" ;;
  *) printf '{}' ;;
esac
SH
chmod +x "$TMP/bin/gh"
rm -f "$TMP/seen"
out="$(run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'review_state_changed'; } \
    && pass "verdict: a review that changes between snapshots is reported as changed" \
    || die "verdict: judged one snapshot and counted another (rc=$rc '$out')"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
