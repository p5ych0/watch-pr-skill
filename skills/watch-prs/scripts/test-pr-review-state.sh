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
      *"/issues/"*"/comments"*)
        # The clean-pass channel: Codex reports "no findings" as an ISSUE
        # comment and submits no review at all. Defaults to an empty list so
        # every pre-existing case behaves exactly as before.
        [ -n "${GH_ICOMMENTS_RC:-}" ] && exit "$GH_ICOMMENTS_RC"
        if [ -n "${GH_ICOMMENTS:-}" ]; then cat "$GH_ICOMMENTS"; else printf '[]'; fi ;;
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

# ── the host is parsed from the URL authority ─────────────────────────────
# Matching `github.com` anywhere in the URL sent an enterprise origin whose PATH
# happens to contain it to the public host, and every pinned command with it.
for case in 'git@ghe.example:org/github.com-mirror.git|ghe.example/org/github.com-mirror' \
            'git@github.com:acme/widget.git|github.com/acme/widget' \
            'https://ghe.example/o/r.git|ghe.example/o/r' \
            'ssh://git@ghe.example/o/r.git|ghe.example/o/r'
do
    url="${case%%|*}"; want="${case##*|}"
    got="$(PR_REVIEW_STATE_LIB_ONLY=1 REVIEW_BUS_REMOTE="$url" \
            bash -c 'source "$1"; echo "$REPO_SLUG"' _ "$SCRIPT" 2>&1)"
    [ "$got" = "$want" ] \
        && pass "identity: $url => $want" \
        || die "identity: $url gave '$got' (want $want)"
done

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

# ── review-id: every TERMINAL state carries one ───────────────────────────
# `blocked` and `dismissed` are exactly the same-head re-request cases, and an
# empty id there silently disables the caller comparison that tells the new pass
# from the old one.
for case in 'APPROVED|reviewed|51' 'COMMENTED|reviewed|52' \
            'CHANGES_REQUESTED|blocked|53' 'DISMISSED|dismissed|54'
do
    st="${case%%|*}"; rest="${case#*|}"; want_state="${rest%%|*}"; rid="${rest##*|}"
    mk_reviews "$st" '"2026-01-01T00:00:00Z"' "$rid"
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" run review-id 7 "$BOT" 2>&1)"; rc=$?
    { [ "$rc" -eq 0 ] && [ "$out" = "$rid" ]; } \
        && pass "review-id: $st ($want_state) returns its id" \
        || die "review-id: $st gave rc=$rc '$out' (want $rid)"
done

# No review on this head is an empty id with a successful status: there is
# nothing to wait past, which is different from a failed read.
printf '[]' > "$TMP/none2.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/none2.json" run review-id 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
    && pass "review-id: no review yet is an empty id, not an error" \
    || die "review-id: empty case gave rc=$rc '$out'"

# An unreadable fetch is NOT an empty id.
out="$(GH_HEAD="$HEAD40" GH_REVIEWS_RC=1 run review-id 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "review-id: an unreadable fetch => 2" || die "review-id: fetch failure gave rc=$rc"

# ── a clean pass arrives as a COMMENT, not a review ───────────────────────
# Codex submits a review only when it has findings. A clean pass is an issue
# comment carrying `**Reviewed commit:** <sha10>` and no review at all, so
# `pulls/N/reviews` is empty — and every caller here reported `state=none`,
# leaving the Codex phase unable to complete and the merge gate unable to see a
# clean verdict. Thirty review rounds never reached this path.
# The apostrophe lives in its own single-quoted variable: inside a "${2:-…}"
# default the '"'"' idiom does not escape anything, it just ends the double quote.
CLEAN_PHRASE='Codex Review: Didn'\''t find any major issues. Breezy!'
# Built with `jq`, not `printf`: the body contains newlines, and a raw newline
# inside a JSON string is an unescaped control character — the fixture was
# invalid JSON and the helper failed closed on it, which looked like the code
# being wrong rather than the fixture.
mk_clean_comment() {   # <sha10> [phrase] [login]
    jq -n --arg login "${3:-$BOT}" --arg phrase "${2:-$CLEAN_PHRASE}" --arg sha "$1" \
        '[{id: 901, user: {login: $login}, body: ($phrase + "\n\n**Reviewed commit:** `" + $sha + "`\n")}]' \
        > "$TMP/icomments.json"
}
printf '[]' > "$TMP/noreviews.json"
mk_clean_comment "${HEAD40:0:10}"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
printf '%s' "$out" | grep -q 'state=reviewed' \
    && pass "a clean-pass comment bound to this head is a reviewed state" \
    || die "clean comment gave '$out'"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'verdict=clean findings=0'; } \
    && pass "…and yields a clean verdict, so the phase can complete" \
    || die "clean comment verdict gave rc=$rc '$out'"

# BOUND to this head. A clean pass on another commit says nothing about this one.
mk_clean_comment "bbbbbbbbbb"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
printf '%s' "$out" | grep -q 'state=none' \
    && pass "a clean comment for another head does not count" \
    || die "other-head clean comment leaked in: $out"

# BOTH signals required: the commit binding alone would accept any comment that
# happens to quote this head.
mk_clean_comment "${HEAD40:0:10}" "Some unrelated remark about the diff"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
printf '%s' "$out" | grep -q 'state=none' \
    && pass "a comment quoting the head without the clean phrasing is not a signoff" \
    || die "an unrelated comment was read as clean: $out"

# Another account cannot sign off for this reviewer.
mk_clean_comment "${HEAD40:0:10}" "$CLEAN_PHRASE" "somebody"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
printf '%s' "$out" | grep -q 'state=none' \
    && pass "a clean comment from another account is not this reviewer's signoff" \
    || die "another account signed off: $out"

# A SUBMITTED review always wins: a later blocking review must not be masked by
# an earlier clean comment on the same head.
mk_clean_comment "${HEAD40:0:10}"
mk_reviews CHANGES_REQUESTED '"2026-01-02T00:00:00Z"' 903
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
printf '%s' "$out" | grep -q 'state=blocked' \
    && pass "a submitted review outranks a clean comment on the same head" \
    || die "a clean comment masked a blocking review: $out"

# An unreadable comment fetch is NOT "no clean comment".
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS_RC=1 \
        run state 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "an unreadable comment fetch => 2, never state=none" \
    || die "comment fetch failure gave rc=$rc '$out'"

# ── a NEWER clean comment supersedes an older review on the same head ─────
# A clean re-review arrives through the comment channel, so consulting comments
# only when there was no review at all left an older finding-bearing or blocked
# review authoritative forever — the watch timed out repeatedly despite a newer
# clean pass having landed.
mk_clean_comment_at() {   # <sha10> <created_at>
    jq -n --arg login "$BOT" --arg phrase "$CLEAN_PHRASE" --arg sha "$1" --arg ts "$2" \
        '[{id: 950, created_at: $ts, user: {login: $login},
           body: ($phrase + "\n\n**Reviewed commit:** `" + $sha + "`\n")}]' \
        > "$TMP/icomments.json"
}
mk_reviews CHANGES_REQUESTED '"2026-01-01T00:00:00Z"' 940
mk_clean_comment_at "${HEAD40:0:10}" "2026-01-02T00:00:00Z"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
printf '%s' "$out" | grep -q 'state=reviewed' \
    && pass "a newer clean comment supersedes an older blocking review" \
    || die "the stale review stayed authoritative: $out"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'verdict=clean'; } \
    && pass "…and the verdict is clean, so the phase can move on" \
    || die "newer clean comment gave rc=$rc '$out'"

# The other direction: an OLDER clean comment must not beat a newer review.
mk_reviews CHANGES_REQUESTED '"2026-01-03T00:00:00Z"' 941
mk_clean_comment_at "${HEAD40:0:10}" "2026-01-02T00:00:00Z"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
printf '%s' "$out" | grep -q 'state=blocked' \
    && pass "an older clean comment does not supersede a newer review" \
    || die "a stale clean comment won: $out"

# A draft still dominates both: the pass is not finished.
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"PENDING","submitted_at":null,"id":942}]' \
    "$BOT" "$HEAD40" > "$TMP/reviews.json"
mk_clean_comment_at "${HEAD40:0:10}" "2026-01-09T00:00:00Z"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
printf '%s' "$out" | grep -q 'state=pending' \
    && pass "an in-flight draft outranks even a newer clean comment" \
    || die "a clean comment overrode a draft: $out"

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
  *"/issues/"*"/comments"*) printf '[]' ;;
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
