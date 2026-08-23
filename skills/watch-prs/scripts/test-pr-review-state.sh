#!/usr/bin/env bash
# Unit tests for pr-review-state.sh, with a stubbed `gh` on PATH.
#
# Every case here is a defect that was found and fixed while this logic lived in
# the v1 Copilot helper. They are kept because the failure mode is always the
# same shape: something unreadable answering as though it were "nothing to worry
# about", which is merge permission.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# `mktemp_d`: a bare `mktemp -d` that fails leaves $TMP empty and the cleanup
# trap then runs `rm -rf` over paths at the filesystem root.
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-review-state.sh"
TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
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
        # A PARTIAL PAGE AND THEN A FAILURE. `--paginate` can print pages and
        # then fail on a later one, and command substitution keeps what was
        # printed — so a caller that checks only the parse sees a well-formed
        # array and answers from half the data.
        if [ -n "${GH_COMMENTS_PARTIAL:-}" ]; then
          cat "$GH_COMMENTS_PARTIAL"; exit "${GH_COMMENTS_RC:-1}"
        fi
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
# A REVIEW COMMENT ROW, in the shape the API sends: `user` and `created_at` are
# always present, and `in_reply_to_id` is ABSENT on a top-level comment. The
# counter validates all three, so a minimal `{id, body}` row is a malformed
# payload rather than a convenient shorthand.
mk_rc() {   # mk_rc <id> <body> [in_reply_to_id]
    if [ -n "${3:-}" ]; then
        printf '{"user":{"login":"%s"},"id":%s,"body":%s,"created_at":"2026-01-01T00:00:00Z","in_reply_to_id":%s}' \
            "$BOT" "$1" "$2" "$3"
    else
        printf '{"user":{"login":"%s"},"id":%s,"body":%s,"created_at":"2026-01-01T00:00:00Z"}' \
            "$BOT" "$1" "$2"
    fi
}
mk_reviews() {   # <state> <submitted_at|null> <id>
    printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"%s","submitted_at":%s,"id":%s}]' \
        "$BOT" "$HEAD40" "$1" "$2" "$3" > "$TMP/reviews.json"
}

# ── identity is derived, never hard-coded ──────────────────────────────────
out="$(PR_REVIEW_STATE_LIB_ONLY=1 REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        bash -p -c 'source "$1"; echo "$REPO_SLUG"' _ "$SCRIPT" 2>&1)"
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
            bash -p -c 'source "$1"; echo "$REPO_SLUG"' _ "$SCRIPT" 2>&1)"
    [ "$got" = "$want" ] \
        && pass "identity: $url => $want" \
        || die "identity: $url gave '$got' (want $want)"
done

# An origin with no network authority is not an identity. A local path such as
# `/srv/mirrors/acme/widget.git` has no host, and defaulting it to github.com
# while the path split still yields `acme/widget` pointed every call at the
# unrelated PUBLIC repository of that name.
for badremote in '/srv/mirrors/acme/widget.git' '../acme/widget.git' './acme/widget.git' 'acme/widget'; do
    out="$(REVIEW_BUS_REMOTE="$badremote" "$SCRIPT" state 7 "$BOT" 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "origin '$badremote' is refused rather than assumed to be GitHub" \
        || die "origin '$badremote' gave rc=$rc '$out'"
    grep -q 'origin_has_no_host' <<<"$out" \
        && pass "…and named as hostless" \
        || die "the hostless origin was not named: $out"
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
    grep -q "state=$want" <<<"$out" \
        && pass "state: $st => $want" \
        || die "state: $st gave '$out' (want $want)"
done

printf '[]' > "$TMP/none.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/none.json" run state 7 "$BOT" 2>&1)"
grep -q 'state=none' <<<"$out" && pass "state: no review => none" \
    || die "state: empty review list gave '$out'"

# A review on ANOTHER head says nothing about this one.
# A FULL sha for the other head: commit_id is validated, so a short one would be
# rejected as malformed and this case would pass without testing head scoping.
OTHER40="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z","id":12}]' \
    "$BOT" "$OTHER40" > "$TMP/other.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/other.json" run state 7 "$BOT" 2>&1)"
grep -q 'state=none' <<<"$out" && pass "state: a review on another head does not count" \
    || die "state: an other-head review leaked in: $out"

# ── an unrecognised state is unreadable, not a dismissal ──────────────────
# `head_review_snapshot` sends anything it does not recognise through its
# catch-all as `dismissed` with status 0, so a null or an unknown string became
# an actionable "the review was withdrawn" — and the driver answers that by
# requesting another pass. A malformed parse then drives a review loop rather
# than stopping. The other two helpers already enforced this set; this one had
# drifted, which is the divergence issue #11 is about.
for badstate in 'null' '"WIBBLE"' '"approved"' '"APPROVED "' '123'; do
    printf '[{"user":{"login":"%s"},"commit_id":"%s","state":%s,"submitted_at":"2026-01-01T00:00:00Z","id":31}]' \
        "$BOT" "$HEAD40" "$badstate" > "$TMP/badstate.json"
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/badstate.json" run state 7 "$BOT" 2>&1)"; rc=$?
    { [ "$rc" -eq 2 ] && grep -q 'status=error' <<<"$out"; } \
        && pass "state: $badstate is unreadable, not a dismissal" \
        || die "state: $badstate gave rc=$rc out='$out'"
    grep -q 'state=dismissed' <<<"$out" \
        && die "state: $badstate was reported as a withdrawn review: $out"
done
# The control: every value in the known set must still be accepted, or "reject
# everything" would satisfy the cases above.
for goodstate in APPROVED CHANGES_REQUESTED COMMENTED DISMISSED; do
    printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"%s","submitted_at":"2026-01-01T00:00:00Z","id":32}]' \
        "$BOT" "$HEAD40" "$goodstate" > "$TMP/goodstate.json"
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/goodstate.json" run state 7 "$BOT" 2>&1)"
    grep -q 'status=error' <<<"$out" \
        && die "state: the valid state $goodstate was rejected: $out" \
        || pass "state: $goodstate is still accepted"
done

# The LATEST submitted review is authoritative: an old clean review followed by a
# dismissal is not a signoff, and the reverse still is.
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"COMMENTED","submitted_at":"2026-01-01T00:00:00Z","id":21},{"user":{"login":"%s"},"commit_id":"%s","state":"DISMISSED","submitted_at":"2026-01-02T00:00:00Z","id":22}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/seq.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/seq.json" run state 7 "$BOT" 2>&1)"
grep -q 'state=dismissed' <<<"$out" \
    && pass "state: a later dismissal overrides an earlier clean review" \
    || die "state: old-clean-then-dismissed gave '$out'"
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"DISMISSED","submitted_at":"2026-01-01T00:00:00Z","id":23},{"user":{"login":"%s"},"commit_id":"%s","state":"APPROVED","submitted_at":"2026-01-02T00:00:00Z","id":24}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/seq2.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/seq2.json" run state 7 "$BOT" 2>&1)"
grep -q 'state=reviewed' <<<"$out" \
    && pass "state: a later approval supersedes an earlier dismissal" \
    || die "state: dismissed-then-approved gave '$out'"

# A draft dominates: a re-review in flight means the pass is not finished.
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"COMMENTED","submitted_at":"2026-01-01T00:00:00Z","id":25},{"user":{"login":"%s"},"commit_id":"%s","state":"PENDING","submitted_at":null,"id":26}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/draft.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/draft.json" run state 7 "$BOT" 2>&1)"
grep -q 'state=pending' <<<"$out" \
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

# ── WHAT `review-at` PROVED, AND WHERE IT WENT ─────────────────────────────
# Nine cases lived here: the comment channel, the later of the two records in both
# directions, and failing closed on an unreadable fetch. `review-at` had exactly
# one consumer — ordering an operator signoff against the verdict — and #139
# replaced it with `clean-at`, which answers "clean, and when" from ONE snapshot
# rather than leaving the caller to prove cleanliness separately and pair the two.
#
# What they proved is proved below on the subcommand that has a caller: the
# comment channel, the shape of the value, and every unreadable read. A second,
# weaker answer to the same question is one a future caller reaches for, which is
# why it is gone rather than kept for symmetry — the same call `replies-at` got.

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
mk_clean_comment() {   # <sha10> [phrase] [login] [created_at]
    jq -n --arg login "${3:-$BOT}" --arg phrase "${2:-$CLEAN_PHRASE}" --arg sha "$1" \
        --arg ts "${4-2026-01-05T00:00:00Z}" \
        '[{id: 901, created_at: $ts, user: {login: $login},
           body: ($phrase + "\n\n**Reviewed commit:** `" + $sha + "`\n")}]' \
        > "$TMP/icomments.json"
}
printf '[]' > "$TMP/noreviews.json"
mk_clean_comment "${HEAD40:0:10}"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
grep -q 'state=reviewed' <<<"$out" \
    && pass "a clean-pass comment bound to this head is a reviewed state" \
    || die "clean comment gave '$out'"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'verdict=clean findings=0' <<<"$out"; } \
    && pass "…and yields a clean verdict, so the phase can complete" \
    || die "clean comment verdict gave rc=$rc '$out'"

# BOUND to this head. A clean pass on another commit says nothing about this one.
mk_clean_comment "bbbbbbbbbb"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
grep -q 'state=none' <<<"$out" \
    && pass "a clean comment for another head does not count" \
    || die "other-head clean comment leaked in: $out"

# BOTH signals required: the commit binding alone would accept any comment that
# happens to quote this head.
mk_clean_comment "${HEAD40:0:10}" "Some unrelated remark about the diff"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
grep -q 'state=none' <<<"$out" \
    && pass "a comment quoting the head without the clean phrasing is not a signoff" \
    || die "an unrelated comment was read as clean: $out"

# Another account cannot sign off for this reviewer.
mk_clean_comment "${HEAD40:0:10}" "$CLEAN_PHRASE" "somebody"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
grep -q 'state=none' <<<"$out" \
    && pass "a clean comment from another account is not this reviewer's signoff" \
    || die "another account signed off: $out"

# A SUBMITTED review always wins: a later blocking review must not be masked by
# an earlier clean comment on the same head.
mk_clean_comment "${HEAD40:0:10}" "$CLEAN_PHRASE" "$BOT" "2026-01-01T00:00:00Z"
mk_reviews CHANGES_REQUESTED '"2026-01-02T00:00:00Z"' 903
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
grep -q 'state=blocked' <<<"$out" \
    && pass "an older clean comment does not mask a newer blocking review" \
    || die "a stale clean comment masked a newer blocking review: $out"

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
grep -q 'state=reviewed' <<<"$out" \
    && pass "a newer clean comment supersedes an older blocking review" \
    || die "the stale review stayed authoritative: $out"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'verdict=clean' <<<"$out"; } \
    && pass "…and the verdict is clean, so the phase can move on" \
    || die "newer clean comment gave rc=$rc '$out'"

# ── verdict: a reply counts, and a review of nothing BUT replies is named ──
# A reviewer's clean verdict is sometimes delivered as a REPLY — "No blocking
# findings on <sha>" arrived that way — and counting it as a finding leaves the
# loop stuck, because the count cannot drop: the comment IS the verdict. Three
# attempts to exempt it failed, the last generally: the real verdict is followed
# by paragraphs of explanation, and a retraction is also a paragraph after the
# verdict line. Telling those apart needs a denylist of words meaning "except".
#
# So a reply counts, and the ANSWER says when they were all replies. There is
# nothing to fix and it is not a signoff — the driver stops for the operator.
mk_reviews COMMENTED '"2026-01-01T00:00:00Z"' 950
printf '[%s]' "$(mk_rc 1 '"## Review\n\nNo blocking findings on `aaaaaaa`."' 42)" \
    > "$TMP/comments-950.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_FIXTURE_DIR="$TMP" \
        run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'verdict=findings findings=1 source=replies-only' <<<"$out"; } \
    && pass "a review whose only comment is a reply is named, not read as either answer" \
    || die "a reply-only review gave rc=$rc '$out'"

# THE RETRACTION CASE, which is why there is no exemption: the verdict line is
# there, and so is the correction. No reading of the text separates this from the
# verdict followed by its explanation.
printf '[%s]' "$(mk_rc 2 '"No blocking findings on `aaaaaaa`.\n\nCorrection: this still crashes."' 42)" \
    > "$TMP/comments-950.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_FIXTURE_DIR="$TMP" \
        run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'findings=1' <<<"$out"; } \
    && pass "…so a reply that carries a verdict line and then retracts it never clears" \
    || die "a retracting reply gave rc=$rc '$out'"

# A TOP-LEVEL COMMENT IS A FINDING, and is not named as replies-only.
printf '[%s]' "$(mk_rc 3 '"this is wrong"')" > "$TMP/comments-950.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_FIXTURE_DIR="$TMP" \
        run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'verdict=findings findings=1' <<<"$out"; } \
    && { [ -n "$out" ] && grep -qv 'replies-only' <<<"$out"; } \
    && pass "…while a top-level comment is a finding like any other" \
    || die "a top-level comment gave rc=$rc '$out'"

# A REVIEW CARRYING BOTH is not replies-only: there is something to fix.
printf '[%s,%s]' "$(mk_rc 4 '"one"')" "$(mk_rc 5 '"a follow-up"' 4)" \
    > "$TMP/comments-950.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_FIXTURE_DIR="$TMP" \
        run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'findings=2' <<<"$out"; } \
    && { [ -n "$out" ] && grep -qv 'replies-only' <<<"$out"; } \
    && pass "…and a review carrying both counts both, without the name" \
    || die "a mixed review gave rc=$rc '$out'"

# A MALFORMED `in_reply_to_id` IS UNREADABLE, NOT A REPLY. A presence-only test
# discarded such a row silently, so a page of them counted zero — which is clean,
# on a payload nothing could read.
# NULL IS NOT MALFORMED — it is "no parent", the same as an absent key, so the
# comment OPENS a thread and counts as an ordinary finding. Rejecting it would
# make every finding page unreadable on a host that serialises nullable fields.
printf '[{"user":{"login":"%s"},"id":9,"body":"x","created_at":"2026-01-01T00:00:00Z","in_reply_to_id":null}]' \
    "$BOT" > "$TMP/comments-950.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_FIXTURE_DIR="$TMP" \
        run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'verdict=findings findings=1' <<<"$out"; } \
    && { [ -n "$out" ] && grep -qv 'replies-only' <<<"$out"; } \
    && pass "a null in_reply_to_id is a top-level finding, not a reply and not malformed" \
    || die "a null in_reply_to_id gave rc=$rc '$out'"

for bad in '"7"' '{}' '[42]'; do
    printf '[{"user":{"login":"%s"},"id":8,"body":"x","created_at":"2026-01-01T00:00:00Z","in_reply_to_id":%s}]' \
        "$BOT" "$bad" > "$TMP/comments-950.json"
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_FIXTURE_DIR="$TMP" \
            run verdict 7 "$BOT" 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "a malformed in_reply_to_id ($bad) is a stop, not a silent clean" \
        || die "in_reply_to_id=$bad gave rc=$rc '$out'"
done
rm -f "$TMP/comments-950.json"

# The other direction: an OLDER clean comment must not beat a newer review.
mk_reviews CHANGES_REQUESTED '"2026-01-03T00:00:00Z"' 941
mk_clean_comment_at "${HEAD40:0:10}" "2026-01-02T00:00:00Z"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
grep -q 'state=blocked' <<<"$out" \
    && pass "an older clean comment does not supersede a newer review" \
    || die "a stale clean comment won: $out"

# A draft still dominates both: the pass is not finished.
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"PENDING","submitted_at":null,"id":942}]' \
    "$BOT" "$HEAD40" > "$TMP/reviews.json"
mk_clean_comment_at "${HEAD40:0:10}" "2026-01-09T00:00:00Z"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
grep -q 'state=pending' <<<"$out" \
    && pass "an in-flight draft outranks even a newer clean comment" \
    || die "a clean comment overrode a draft: $out"

# A clean comment is ordered against reviews, so it must carry the SAME canonical
# UTC stamp they do. `zzzz` sorts above every real timestamp and would override a
# newer CHANGES_REQUESTED; a null would read as clean whenever no review existed.
printf '[]' > "$TMP/noreviews.json"
for badts in '' 'zzzz' '2026-01-05' '2026-01-05T00:00:00+01:00'; do
    mk_clean_comment "${HEAD40:0:10}" "$CLEAN_PHRASE" "$BOT" "$badts"
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
            run state 7 "$BOT" 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "a clean comment timestamped '${badts:-<empty>}' => 2" \
        || die "clean comment with timestamp '${badts:-<empty>}' gave rc=$rc '$out'"
done
# A genuinely absent created_at is the same: unreadable ordering is not ordering.
jq -n --arg login "$BOT" --arg phrase "$CLEAN_PHRASE" --arg sha "${HEAD40:0:10}" \
    '[{id: 902, created_at: null, user: {login: $login},
       body: ($phrase + "\n\n**Reviewed commit:** `" + $sha + "`\n")}]' > "$TMP/icomments.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "a clean comment with a null created_at => 2" \
    || die "null created_at gave rc=$rc '$out'"

# The hash is taken FROM THE FOOTER, not found anywhere in the body. A clean pass
# for an older head that merely mentions the current prefix in its prose is not a
# signoff for the current head.
jq -n --arg login "$BOT" --arg cur "${HEAD40:0:10}" --arg phrase "$CLEAN_PHRASE" \
    '[{id: 903, created_at: "2026-01-05T00:00:00Z", user: {login: $login},
       body: ($phrase + " Superseded by " + $cur + " later.\n\n**Reviewed commit:** `bbbbbbbbbb`\n")}]' \
    > "$TMP/icomments.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
grep -q 'state=none' <<<"$out" \
    && pass "the current prefix in prose is not a signoff; only the footer counts" \
    || die "a prose mention was read as the reviewed commit: $out"

# A FIELD-SHAPED line in prose, ahead of the real footer. `capture` takes the
# first match anywhere, so an older clean comment carrying this would have been
# read as a signoff for whatever the decoy named.
jq -n --arg login "$BOT" --arg cur "${HEAD40:0:10}" --arg phrase "$CLEAN_PHRASE" \
    '[{id: 904, created_at: "2026-01-05T00:00:00Z", user: {login: $login},
       body: ($phrase + "\n\nEarlier I wrote:\n**Reviewed commit:** `" + $cur + "`\n\n**Reviewed commit:** `bbbbbbbbbb`\n")}]' \
    > "$TMP/icomments.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
grep -q 'state=none' <<<"$out" \
    && pass "a decoy footer line in prose does not sign off; the last footer wins" \
    || die "a decoy footer was read as the reviewed commit: $out"

# …and the genuine footer still works when it IS the last line.
jq -n --arg login "$BOT" --arg cur "${HEAD40:0:10}" --arg phrase "$CLEAN_PHRASE" \
    '[{id: 905, created_at: "2026-01-05T00:00:00Z", user: {login: $login},
       body: ($phrase + "\n\nEarlier I wrote:\n**Reviewed commit:** `bbbbbbbbbb`\n\n**Reviewed commit:** `" + $cur + "`\n")}]' \
    > "$TMP/icomments.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/noreviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
grep -q 'state=reviewed' <<<"$out" \
    && pass "…and the real footer still signs off when it is the last one" \
    || die "the genuine footer was not read: $out"

# Second-resolution timestamps TIE. A clean re-review comment created in the same
# second as the review it supersedes cannot be ordered against it, and a strict
# `>` silently kept the older review — so the watch rejected a completed clean
# pass as stale.
mk_reviews CHANGES_REQUESTED '"2026-01-07T12:00:00Z"' 960
mk_clean_comment_at "${HEAD40:0:10}" "2026-01-07T12:00:00Z"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a same-second review and clean comment => 2, not a silent winner" \
    || die "same-second tie gave rc=$rc '$out'"
grep -q 'ambiguous_verdict_order' <<<"$out" \
    && pass "…named as an ambiguous ordering" \
    || die "the tie was not named: $out"

# One second apart still orders cleanly, in both directions.
mk_clean_comment_at "${HEAD40:0:10}" "2026-01-07T12:00:01Z"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
grep -q 'state=reviewed' <<<"$out" \
    && pass "a comment one second later still supersedes" \
    || die "a later comment did not win: $out"
mk_clean_comment_at "${HEAD40:0:10}" "2026-01-07T11:59:59Z"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        run state 7 "$BOT" 2>&1)"
grep -q 'state=blocked' <<<"$out" \
    && pass "…and one second earlier still does not" \
    || die "an earlier comment won: $out"

# ── verdict: only an accepted review with zero findings is clean ───────────
mk_reviews APPROVED '"2026-01-01T00:00:00Z"' 31
printf '[]' > "$TMP/comments-31.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'verdict=clean' <<<"$out"; } \
    && pass "verdict: approved with zero comments => clean (0)" \
    || die "verdict: clean case gave rc=$rc '$out'"

printf '[%s,%s]' "$(mk_rc 1 '"x"')" "$(mk_rc 2 '"y"')" > "$TMP/comments-31.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" run verdict 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'findings=2' <<<"$out"; } \
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
    grep -q 'state=none' <<<"$out" \
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
grep -q 'verdict=clean' <<<"$out" \
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
grep -q 'verdict=clean' <<<"$out" \
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
grep -q 'verdict=clean' <<<"$out" \
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
grep -q 'verdict=clean' <<<"$out" \
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
{ [ "$rc" -eq 1 ] && grep -q 'review_state_changed' <<<"$out"; } \
    && pass "verdict: a review that changes between snapshots is reported as changed" \
    || die "verdict: judged one snapshot and counted another (rc=$rc '$out')"

# ── `clean-at` — CLEAN, AND WHEN, FROM ONE SNAPSHOT ────────────────────────
# `record` asked `verdict` and then `review-at`, and a result arriving between
# them was the one `review-at` timed — so the signoff could carry the time of a
# verdict nobody proved. The time now comes from the snapshot that proved the
# verdict clean, so there is no second question to answer differently. #139.
# ITS OWN STUB, because an earlier case replaced the general one to make a review
# change between two reads — and a case that inherits that world is asserting
# about somebody else's fixture.
cat > "$TMP/bin/gh" <<'CLEANSH'
#!/usr/bin/env bash
case "$*" in
  *"/reviews/"*"/comments"*) [ -n "${GH_COMMENTS_RC:-}" ] && exit "$GH_COMMENTS_RC"
                             cat "${GH_COMMENTS:-/dev/null}" ;;
  *"/issues/"*"/comments"*)  cat "${GH_ICOMMENTS:-/dev/null}" ;;
  *"/reviews"*)              [ -n "${GH_REVIEWS_RC:-}" ] && exit "$GH_REVIEWS_RC"
                             cat "${GH_REVIEWS:-/dev/null}" ;;
  *"pr view"*)               printf '%s' "${GH_HEAD:-}" ;;
  *)                         printf '{}' ;;
esac
CLEANSH
chmod +x "$TMP/bin/gh"
mk_reviews APPROVED '"2026-03-03T00:00:00Z"' 51
printf '[]' > "$TMP/comments.json"; printf '[]' > "$TMP/icomments.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        GH_COMMENTS="$TMP/comments.json" run clean-at 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = '2026-03-03T00:00:00Z' ]; } \
    && pass "clean-at: a clean review answers with its own time" \
    || die "clean-at gave (rc=$rc out='$out')"
# A CLEAN VERDICT DELIVERED AS A COMMENT CARRIES ITS TIME TOO, since that is the
# record the snapshot selected.
#
# THE NEWLINES ARE ESCAPED FOR JSON, NOT FOR `printf`. Written as a real newline
# inside a JSON string this is a parse error, and the helper then answers
# `unreadable` — so the case would fail for a reason that has nothing to do with
# the channel it exists to test.
_cleanicb="I didn't find any major issues.\\n\\n**Reviewed commit:** \`${HEAD40:0:10}\`\\n"
printf '[{"id":9001,"user":{"login":"%s"},"created_at":"2026-04-04T00:00:00Z","body":"%s"}]' \
    "$BOT" "$_cleanicb" > "$TMP/icomments.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        GH_COMMENTS="$TMP/comments.json" run clean-at 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = '2026-04-04T00:00:00Z' ]; } \
    && pass "…and a clean verdict delivered as a comment answers with that comment's time" \
    || die "clean-at ignored the comment channel (rc=$rc out='$out')"
# A HEAD WITH FINDINGS IS 1, NOT AN ERROR AND NOT A TIME.
printf '[]' > "$TMP/icomments.json"
printf '[{"user":{"login":"%s"},"id":9001,"body":"x","created_at":"2026-01-05T00:00:00Z"}]' "$BOT" \
    > "$TMP/comments.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" \
        GH_COMMENTS="$TMP/comments.json" run clean-at 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$out" ]; } \
    && pass "…while a head with findings answers 1 with nothing on stdout" \
    || die "clean-at on a findings head gave (rc=$rc out='$out')"
# AND AN UNREADABLE FETCH IS 2, with nothing on stdout.
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_REVIEWS_RC=1 \
        run clean-at 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=unreadable' <<<"$out"; } \
    && pass "…and an unreadable reviews fetch is 2" \
    || die "clean-at on an unreadable fetch gave (rc=$rc out='$out')"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews.json" GH_REVIEWS_RC=1 \
        run clean-at 7 "$BOT" 2>/dev/null)"
[ -z "$out" ] \
    && pass "…with nothing on stdout, which a substitution would have captured" \
    || die "the unreadable answer printed '$out'"

# ── `escape-snapshot` — ONE RESPONSE, NOT A PROTOCOL OVER TWO ──────────────
# The escape has to know which review it is, that its comments are all replies,
# when it landed and when its newest reply did. The REST endpoints answer reviews
# and review comments separately, and NO ordering of separate reads makes them one
# snapshot: with the comments read last a review dismissed afterwards is invisible,
# with the reviews read last a reply posted afterwards is, and alternating a third
# time only moves the race. GraphQL returns both in one response. #133.
gql() {   # gql <reviews-json-array> ; a stub answering the escape query
    printf '{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasPreviousPage":false},"nodes":%s}}}}}' "$1" \
        > "$TMP/gql.json"
    cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *graphql*) cat "$TMP/gql.json" ;;
  *"pr view"*) printf '%s' "$HEAD40" ;;
  *) printf '{}' ;;
esac
SH
    chmod +x "$TMP/bin/gh"
}
gql_review() {   # gql_review <state> <submitted_at|null> <id> <comments-json>
    # `null` UNQUOTED, because a draft carries a JSON null and a quoted "null" is
    # a string that is not a time — a different case, and one the validator now
    # refuses rather than treating as an unsubmitted review.
    local _at="\"$2\""
    [ "$2" = null ] && _at=null
    printf '[{"databaseId":%s,"submittedAt":%s,"state":"%s","author":{"login":"%s"},"commit":{"oid":"%s"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":%s}}]' \
        "$3" "$_at" "$1" "$BOT" "$HEAD40" "$4"
}
gql "$(gql_review COMMENTED 2026-01-01T00:00:00Z 42 \
    '[{"databaseId":9001,"createdAt":"2026-01-05T00:00:00Z","replyTo":{"databaseId":8001}},
      {"databaseId":9002,"createdAt":"2026-01-09T00:00:00Z","replyTo":{"databaseId":8001}}]')"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = "$(printf '42\t2026-01-01T00:00:00Z\t2026-01-09T00:00:00Z')" ]; } \
    && pass "escape-snapshot: the id, the review time and the newest reply, from one response" \
    || die "escape-snapshot gave (rc=$rc out='$out')"
# A COMMENT THAT OPENS A THREAD IS A FINDING, not a reply — and a finding is not a
# question an operator was asked, so this is not the escape's shape.
gql "$(gql_review COMMENTED 2026-01-01T00:00:00Z 42 \
    '[{"databaseId":9001,"createdAt":"2026-01-05T00:00:00Z","replyTo":null}]')"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$out" ]; } \
    && pass "…a comment that opens a thread is not that shape" \
    || die "an opening comment was reported as replies-only (rc=$rc out='$out')"
# NO COMMENTS AT ALL IS A DIFFERENT RECORD AGAIN.
gql "$(gql_review COMMENTED 2026-01-01T00:00:00Z 42 '[]')"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$out" ]; } \
    && pass "…nor is a review with no comments" \
    || die "an empty review was reported as replies-only (rc=$rc out='$out')"
# AND NEITHER IS A HEAD WITH NO SUBMITTED REVIEW.
gql '[]'
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$out" ]; } \
    && pass "…nor a head with no submitted review" \
    || die "no review was reported as replies-only (rc=$rc out='$out')"
# A DISMISSED REVIEW IS NOT ONE THIS CAN ACT ON, and neither is a draft in flight.
gql "$(gql_review DISMISSED 2026-01-01T00:00:00Z 42 \
    '[{"databaseId":9001,"createdAt":"2026-01-05T00:00:00Z","replyTo":{"databaseId":8001}}]')"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] \
    && pass "…nor a dismissed one" \
    || die "a dismissed review was reported as replies-only (rc=$rc out='$out')"
gql "$(gql_review PENDING null 42 \
    '[{"databaseId":9001,"createdAt":"2026-01-05T00:00:00Z","replyTo":{"databaseId":8001}}]')"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] \
    && pass "…nor one with a draft still open on the head" \
    || die "a pending review was reported as replies-only (rc=$rc out='$out')"
# A TRUNCATED PAGE IS UNREADABLE, NOT "NOT THAT SHAPE". The reviews are the LAST
# hundred, so an earlier page could hold a draft that dominates; a review with
# more than a hundred comments would have its newest one cut off.
printf '{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasPreviousPage":true},"nodes":%s}}}}}' \
    "$(gql_review COMMENTED 2026-01-01T00:00:00Z 42 '[{"databaseId":9001,"createdAt":"2026-01-05T00:00:00Z","replyTo":{"databaseId":8001}}]')" \
    > "$TMP/gql.json"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=unreadable' <<<"$out"; } \
    && pass "…while a truncated review page is unreadable" \
    || die "a truncated review page gave (rc=$rc out='$out')"
printf '{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasPreviousPage":false},"nodes":[{"databaseId":42,"submittedAt":"2026-01-01T00:00:00Z","state":"COMMENTED","author":{"login":"%s"},"commit":{"oid":"%s"},"comments":{"pageInfo":{"hasNextPage":true},"nodes":[{"databaseId":9001,"createdAt":"2026-01-05T00:00:00Z","replyTo":{"databaseId":8001}}]}}]}}}}}' \
    "$BOT" "$HEAD40" > "$TMP/gql.json"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=unreadable' <<<"$out"; } \
    && pass "…and so is a truncated comment page" \
    || die "a truncated comment page gave (rc=$rc out='$out')"
# A 200 CAN CARRY BOTH `errors` AND A STRUCTURALLY VALID `data`, and the partial
# data would answer "not that shape" from a response that failed.
printf '{"errors":[{"message":"nope"}],"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasPreviousPage":false},"nodes":[]}}}}}' \
    > "$TMP/gql.json"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=unreadable' <<<"$out"; } \
    && pass "…and a response carrying errors beside data is unreadable" \
    || die "an errors-bearing response gave (rc=$rc out='$out')"
# A COMMENT ROW THIS CANNOT READ IS A PAYLOAD, NOT A COMMENT.
gql "$(gql_review COMMENTED 2026-01-01T00:00:00Z 42 \
    '[{"databaseId":9001,"createdAt":"whenever","replyTo":{"databaseId":8001}}]')"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=unreadable' <<<"$out"; } \
    && pass "…and a comment row with an unreadable time refuses rather than being skipped" \
    || die "a malformed comment row gave (rc=$rc out='$out')"
out="$(run escape-snapshot 7 "$BOT" 2>/dev/null)"
[ -z "$out" ] \
    && pass "…with nothing on stdout, which a substitution would have captured" \
    || die "the unreadable answer printed '$out'"
# EVERY NODE IS VALIDATED BEFORE ANY IS FILTERED. A `select` over a malformed
# node DISCARDS it, and discarding a NEWER review leaves an older replies-only one
# as the latest — so a signoff newer than that older review closes the phase over
# a review nothing could read. "This response is not trustworthy" and "that review
# is not mine" are the two answers this has to keep apart.
printf '{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasPreviousPage":false},"nodes":[{"databaseId":42,"submittedAt":"2026-01-01T00:00:00Z","state":"COMMENTED","author":{"login":"%s"},"commit":{"oid":"%s"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":9001,"createdAt":"2026-01-05T00:00:00Z","replyTo":{"databaseId":8001}}]}},{"databaseId":43,"submittedAt":"2026-02-02T00:00:00Z","state":"CHANGES_REQUESTED","author":null,"commit":{"oid":"%s"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":[]}}]}}}}}' \
    "$BOT" "$HEAD40" "$HEAD40" > "$TMP/gql.json"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=unreadable' <<<"$out"; } \
    && pass "…and a malformed NEWER review is unreadable, not filtered past" \
    || die "a malformed newer review was discarded (rc=$rc out='$out')"
# AND THE COMMIT OID IS A COMMIT, not merely a string. A truncated head passes a
# type check and is then DISCARDED by the head filter, which hands the decision to
# an older replies-only review — the same route as a malformed time, through a
# different field.
printf '{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasPreviousPage":false},"nodes":[{"databaseId":42,"submittedAt":"2026-01-01T00:00:00Z","state":"COMMENTED","author":{"login":"%s"},"commit":{"oid":"%s"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":9001,"createdAt":"2026-01-05T00:00:00Z","replyTo":{"databaseId":8001}}]}},{"databaseId":43,"submittedAt":"2026-02-02T00:00:00Z","state":"CHANGES_REQUESTED","author":{"login":"%s"},"commit":{"oid":"aaaaaaa"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":[]}}]}}}}}' \
    "$BOT" "$HEAD40" "$BOT" > "$TMP/gql.json"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=unreadable' <<<"$out"; } \
    && pass "…and a newer review whose commit is not a commit cannot be filtered past" \
    || die "a truncated oid was discarded (rc=$rc out='$out')"

# AND THE TIME IS CHECKED FOR SHAPE, NOT MERELY FOR BEING A STRING. The sort
# decides which review is authoritative, and a string that is not a time sorts
# SOMEWHERE — `"0000"` sorts under every real timestamp, so a malformed newer
# review hands the decision to an older replies-only one, whose own time then
# passes the only shape check there was.
printf '{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasPreviousPage":false},"nodes":[{"databaseId":42,"submittedAt":"2026-01-01T00:00:00Z","state":"COMMENTED","author":{"login":"%s"},"commit":{"oid":"%s"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":9001,"createdAt":"2026-01-05T00:00:00Z","replyTo":{"databaseId":8001}}]}},{"databaseId":43,"submittedAt":"0000","state":"CHANGES_REQUESTED","author":{"login":"%s"},"commit":{"oid":"%s"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":[]}}]}}}}}' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/gql.json"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=unreadable' <<<"$out"; } \
    && pass "…and a newer review whose time is not a time cannot hand the decision to an older one" \
    || die "a low-sorting malformed time selected an older review (rc=$rc out='$out')"

# THE SAME FOR A REPLY LINK. A `replyTo` that is a string or an array is not null,
# so a presence test reads it as a REPLY — and a set of rows nothing could
# classify then produces a valid snapshot, which is a merge on a finding/reply
# relationship that was never read.
gql "$(gql_review COMMENTED 2026-01-01T00:00:00Z 42 \
    '[{"databaseId":9001,"createdAt":"2026-01-05T00:00:00Z","replyTo":"8001"}]')"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=unreadable' <<<"$out"; } \
    && pass "…and a reply link that is not an object is unreadable, not a reply" \
    || die "a malformed reply link was classified (rc=$rc out='$out')"
gql "$(gql_review COMMENTED 2026-01-01T00:00:00Z 42 \
    '[{"databaseId":9001,"createdAt":"2026-01-05T00:00:00Z","replyTo":{"databaseId":"8001"}}]')"
out="$(run escape-snapshot 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=unreadable' <<<"$out"; } \
    && pass "…and neither is one whose id is not a number" \
    || die "a reply link with a non-numeric id was classified (rc=$rc out='$out')"

# ANOTHER REVIEWER'S REVIEW ON THE SAME HEAD IS NOT THIS ONE.
gql "$(gql_review COMMENTED 2026-01-01T00:00:00Z 42 \
    '[{"databaseId":9001,"createdAt":"2026-01-05T00:00:00Z","replyTo":{"databaseId":8001}}]')"
out="$(run escape-snapshot 7 'copilot-pull-request-reviewer[bot]' 2>&1)"; rc=$?
[ "$rc" -eq 1 ] \
    && pass "…and a review by another reviewer is not this reviewer's" \
    || die "another reviewer's review answered (rc=$rc out='$out')"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
