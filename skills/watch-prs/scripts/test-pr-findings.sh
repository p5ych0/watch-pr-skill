#!/usr/bin/env bash
# Unit tests for pr-findings.sh.
#
# This logic spent three review rounds as a snippet in SKILL.md, where nothing
# executed it, and every round found another fail-open case. These are those
# cases, now runnable.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/pr-findings.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

BOT='chatgpt-codex-connector[bot]'
HEAD40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD40="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# GH_PAGE1/GH_PAGE2: graphql pages ; GH_GQL_RC: graphql failure
# GH_REVIEWS: reviews payload ; GH_REVIEWS_RC: its failure
# GH_HEAD: headRefOid
case "$1 ${2:-}" in
  "api graphql")
    [ -n "${GH_GQL_RC:-}" ] && exit "$GH_GQL_RC"
    if [ -n "${GH_PAGE2:-}" ] && [ -e "$TMP_SEEN" ]; then cat "$GH_PAGE2"; else
       : > "$TMP_SEEN" 2>/dev/null || true; cat "${GH_PAGE1:-/dev/null}"; fi ;;
  "api "*) [ -n "${GH_REVIEWS_RC:-}" ] && exit "$GH_REVIEWS_RC"; cat "${GH_REVIEWS:-/dev/null}" ;;
  "pr view"*) printf '%s' "${GH_HEAD:-}" ;;
  *) printf '{}' ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" TMP_SEEN="$TMP/seen"
run() { rm -f "$TMP_SEEN"; REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" "$@"; }

page() {   # <hasNextPage> <cursor> <nodes-json>
    printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":%s,"endCursor":%s},"nodes":%s}}}}}' \
        "$1" "$2" "$3"
}
NODE_OK='[{"id":"T_1","isResolved":false,"path":"a.sh","line":1,"comments":{"nodes":[{"author":{"login":"bot"},"body":"finding one"}]}},{"id":"T_2","isResolved":true,"path":"b.sh","line":2,"comments":{"nodes":[{"author":{"login":"bot"},"body":"old"}]}}]'

# ── list: the happy path ───────────────────────────────────────────────────
page false null "$NODE_OK" > "$TMP/p1.json"
out="$(GH_PAGE1="$TMP/p1.json" run list 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'finding one'; } \
    && pass "list: prints unresolved findings" || die "list happy path (rc=$rc out='$out')"
printf '%s' "$out" | grep -q 'old' \
    && die "list: printed a RESOLVED thread" || pass "list: resolved threads are skipped"

# No unresolved threads is an empty, successful answer.
page false null '[]' > "$TMP/empty.json"
out="$(GH_PAGE1="$TMP/empty.json" run list 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
    && pass "list: no findings is empty and successful" || die "empty case (rc=$rc out='$out')"

# ── list: pagination is followed, and its state validated ──────────────────
page true '"CUR"' "$NODE_OK" > "$TMP/p1.json"
page false null '[{"id":"T_3","isResolved":false,"path":"c.sh","line":3,"comments":{"nodes":[{"author":{"login":"bot"},"body":"finding two"}]}}]' > "$TMP/p2.json"
out="$(GH_PAGE1="$TMP/p1.json" GH_PAGE2="$TMP/p2.json" run list 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'finding one' && printf '%s' "$out" | grep -q 'finding two'; } \
    && pass "list: follows the cursor to the next page" || die "pagination (rc=$rc out='$out')"

# hasNextPage=true with no cursor would loop or truncate silently.
page true null "$NODE_OK" > "$TMP/nocur.json"
out="$(GH_PAGE1="$TMP/nocur.json" run list 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "list: hasNextPage=true with no cursor => 2" || die "missing cursor gave rc=$rc"

# A non-boolean hasNextPage must not read as "last page".
page '"yes"' null "$NODE_OK" > "$TMP/badnext.json"
out="$(GH_PAGE1="$TMP/badnext.json" run list 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "list: non-boolean hasNextPage => 2" || die "bad hasNextPage gave rc=$rc"

# ── list: malformed nodes must not become findings ─────────────────────────
# Each of these once produced output rather than an abort.
i=0
for bad in '{}' '[{}]' \
    '[{"id":"T_9","isResolved":false,"path":"a","line":1,"comments":{"nodes":[]}}]' \
    '[{"id":"T_9","isResolved":false,"path":"a","line":1,"comments":{"nodes":[{"author":null,"body":"x"}]}}]' \
    '[{"id":"T_9","isResolved":false,"path":"a","line":1,"comments":{"nodes":[{"author":{"login":"b"},"body":null}]}}]' \
    '[{"id":"T_9","isResolved":"false","path":"a","line":1,"comments":{"nodes":[{"author":{"login":"b"},"body":"x"}]}}]'
do
    i=$((i + 1))
    page false null "$bad" > "$TMP/bad$i.json"
    out="$(GH_PAGE1="$TMP/bad$i.json" run list 7 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] && pass "list: malformed nodes #$i => 2" || die "malformed #$i gave rc=$rc out='$out'"
    printf '%s' "$out" | grep -q 'null' \
        && die "list: malformed #$i emitted 'null' as finding text" \
        || pass "list: malformed #$i emitted no bogus finding"
done

# A failed fetch is not "no findings".
out="$(GH_GQL_RC=1 run list 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "list: fetch failure => 2" || die "fetch failure gave rc=$rc"

# ── blocked-body: scoped to the reviewer AND the head ──────────────────────
printf '[{"user":{"login":"%s"},"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","body":"please change X"}]' \
    "$BOT" "$HEAD40" > "$TMP/rev.json"
out="$(GH_REVIEWS="$TMP/rev.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'please change X'; } \
    && pass "blocked-body: prints the blocking body for this head" || die "blocked-body (rc=$rc out='$out')"

# A stale CHANGES_REQUESTED on an OLDER commit is not an active finding.
printf '[{"user":{"login":"%s"},"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","body":"stale request"}]' \
    "$BOT" "$OLD40" > "$TMP/stale.json"
out="$(GH_REVIEWS="$TMP/stale.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
    && pass "blocked-body: a stale request on an older head is not printed" \
    || die "stale body leaked (rc=$rc out='$out')"

# Another reviewer's blocking body is not this reviewer's.
printf '[{"user":{"login":"someone-else"},"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","body":"theirs"}]' \
    "$HEAD40" > "$TMP/other.json"
out="$(GH_REVIEWS="$TMP/other.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"
[ -z "$out" ] && pass "blocked-body: scoped to the named reviewer" || die "another reviewer's body leaked: $out"

# A reviews fetch that fails is not "no blocking body".
out="$(GH_REVIEWS_RC=1 run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "blocked-body: fetch failure => 2" || die "fetch failure gave rc=$rc"
: > "$TMP/empty-out.json"
out="$(GH_REVIEWS="$TMP/empty-out.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "blocked-body: empty output => 2 (zero pages is not zero reviews)" \
    || die "empty output gave rc=$rc"
printf '{"message":"Not Found"}' > "$TMP/obj.json"
out="$(GH_REVIEWS="$TMP/obj.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "blocked-body: object-shaped page => 2" || die "object page gave rc=$rc"

# A malformed reviews page must not be indistinguishable from "no body". The
# optional selectors would map it away and exit 0, leaving the loop without the
# one finding it has to act on.
i=0
for bad in '[{}]' \
    '[{"user":{"login":"x"},"state":"CHANGES_REQUESTED","commit_id":"'"$HEAD40"'","submitted_at":"t","body":123}]' \
    '[{"user":"notanobject","state":"CHANGES_REQUESTED","commit_id":"'"$HEAD40"'","submitted_at":"t","body":"x"}]' \
    '[{"user":{"login":"x"},"state":"CHANGES_REQUESTED","commit_id":42,"submitted_at":"t","body":"x"}]'
do
    i=$((i + 1))
    printf '%s' "$bad" > "$TMP/badrec$i.json"
    out="$(GH_REVIEWS="$TMP/badrec$i.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "blocked-body: malformed record #$i => 2 (not silence)" \
        || die "malformed record #$i gave rc=$rc out='$out'"
done

# A resolved head must be a FULL sha. `abc` is all-hex, so a character-only check
# accepted it and the commit_id filter then matched nothing — printing no body
# with rc 0, which is indistinguishable from "no blocking body".
for shorthead in abc aaaa 0123456789; do
    out="$(GH_REVIEWS="$TMP/rev.json" run blocked-body 7 "$BOT" "$shorthead" 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "blocked-body: an all-hex but short head ('$shorthead') => 2" \
        || die "short head '$shorthead' gave rc=$rc out='$out'"
done
# The same when the helper resolves the head itself and gh returns something short.
out="$(GH_HEAD="abc" GH_REVIEWS="$TMP/rev.json" run blocked-body 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "blocked-body: a short head from its own lookup => 2" \
    || die "self-resolved short head gave rc=$rc out='$out'"

# A MATCHING blocked review must carry a readable body. `.body // empty` mapped a
# null or absent one to empty stdout with rc 0 — indistinguishable from "the
# blocking review had no body", in the one path whose whole job is to surface a
# finding that has nowhere else to appear.
for nobody in 'null' '""x'; do
    if [ "$nobody" = 'null' ]; then
        printf '[{"user":{"login":"%s"},"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","body":null}]' \
            "$BOT" "$HEAD40" > "$TMP/nobody.json"
    else
        printf '[{"user":{"login":"%s"},"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z"}]' \
            "$BOT" "$HEAD40" > "$TMP/nobody.json"
    fi
    out="$(GH_REVIEWS="$TMP/nobody.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "blocked-body: a matching review with no readable body => 2" \
        || die "missing body ($nobody) gave rc=$rc out='$out'"
done

# ── a SUPERSEDED request is not an active finding ─────────────────────────
# Filtering on state alone printed a request the reviewer had already withdrawn
# by approving the same head — sending the driver into another fix round after a
# signoff.
printf '[{"user":{"login":"%s"},"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","body":"please change X"},{"user":{"login":"%s"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-01-02T00:00:00Z","body":"looks good now"}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/superseded.json"
out="$(GH_REVIEWS="$TMP/superseded.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
    && pass "blocked-body: a request superseded by a later approval is not printed" \
    || die "superseded request still printed (rc=$rc out='$out')"

# …and the reverse: a request that came AFTER an approval is still active.
printf '[{"user":{"login":"%s"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","body":"fine"},{"user":{"login":"%s"},"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-01-02T00:00:00Z","body":"actually, change Y"}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/relatest.json"
out="$(GH_REVIEWS="$TMP/relatest.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'change Y'; } \
    && pass "blocked-body: a request newer than an approval is still active" \
    || die "the latest request was suppressed (rc=$rc out='$out')"

# ── findings carry the thread id the driver has to resolve ────────────────
# path:line is not an identifier: two unresolved comments can share a line, and a
# fix commit shifts the lines anyway.
page false null "$NODE_OK" > "$TMP/p1.json"
out="$(GH_PAGE1="$TMP/p1.json" run list 7 2>&1)"
printf '%s' "$out" | grep -q 'thread=T_1' \
    && pass "list: each finding carries its thread id" \
    || die "no thread id in the findings output: $out"
printf '%s' "$out" | grep -q 'thread=T_2' \
    && die "list: printed a resolved thread's id" || pass "list: only unresolved threads are listed"
# A node without an id is malformed: the driver would have nothing to resolve.
page false null '[{"isResolved":false,"path":"a","line":1,"comments":{"nodes":[{"author":{"login":"b"},"body":"x"}]}}]' > "$TMP/noid.json"
out="$(GH_PAGE1="$TMP/noid.json" run list 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "list: a thread with no id => 2" || die "missing thread id gave rc=$rc"

# ── a GraphQL 200 carrying `errors` is not a response ─────────────────────
# GraphQL answers 200 with BOTH `errors` and a structurally valid `data` when it
# resolves part of a query. The partial data passes every shape check, so a
# silently short findings list is indistinguishable from a shorter review — and
# the driver replies to, resolves and summarises against exactly that list.
printf '{"errors":[{"message":"Something went wrong"}],"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' \
    > "$TMP/partial.json"
out="$(GH_PAGE1="$TMP/partial.json" run list 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "list: a partial response carrying GraphQL errors => 2" \
    || die "a page with .errors and valid data gave rc=$rc out='$out'"

# The same when the partial data still contains findings — the danger is the ones
# it left out, so a non-empty list is not evidence the read was complete.
printf '{"errors":[{"message":"timeout"}],"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":%s}}}}}' \
    "$NODE_OK" > "$TMP/partial2.json"
out="$(GH_PAGE1="$TMP/partial2.json" run list 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "list: errors alongside real findings still => 2" \
    || die "partial page with findings gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'thread=T_1' \
    && die "a partial page's findings were printed as if complete" \
    || pass "list: nothing is printed from a partial page"

# `errors: []` is not an error — GitHub does not send it, but treating any
# `errors` key as fatal regardless of contents would be a different bug.
printf '{"errors":[],"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":%s}}}}}' \
    "$NODE_OK" > "$TMP/emptyerr.json"
out="$(GH_PAGE1="$TMP/emptyerr.json" run list 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "list: an empty errors array is still refused (fail closed)" \
    || die "empty errors array gave rc=$rc out='$out'"

# ── a cursor that does not advance is a hang, not a page ──────────────────
# A stale or malformed page can report `hasNextPage: true` while returning the
# same `endCursor` it was asked for. The loop then requests that identical page
# forever — worse than the documented failure, because nothing times out and the
# caller waits on a command that will never answer.
page true '"C1"' "$NODE_OK" > "$TMP/cur1.json"
page true '"C1"' "$NODE_OK" > "$TMP/cur2.json"
out="$(timeout 20 env GH_PAGE1="$TMP/cur1.json" GH_PAGE2="$TMP/cur2.json" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" list 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "list: a cursor that repeats => 2, not an endless walk" \
    || die "repeated cursor gave rc=$rc (124 = it hung) out='$out'"

# A CYCLE, not just a self-loop: `null -> A -> B -> A -> B ...` passes an
# "is it different from the last one" check on every step and alternates forever.
# The guard tracks every cursor already requested, so a cycle of any length ends
# the walk instead of hanging it.
page true '"A"' "$NODE_OK" > "$TMP/cyc1.json"
printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"A"},"nodes":%s}}}}}' \
    "$NODE_OK" > "$TMP/cycB.json"
# Page 2 onward alternates B, A, B, A ... by echoing back a cursor already used.
cat > "$TMP/bin/gh" <<'GHSH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "api graphql")
    n=$(cat "$CYC_N" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CYC_N"
    if [ $((n % 2)) -eq 0 ]; then cur='"B"'; else cur='"A"'; fi
    printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":%s},"nodes":[]}}}}}' "$cur" ;;
  *) printf '{}' ;;
esac
GHSH
chmod +x "$TMP/bin/gh"
rm -f "$TMP/cyc.n"
out="$(timeout 20 env CYC_N="$TMP/cyc.n" REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" list 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "list: a two-page cursor cycle => 2, not an endless alternation" \
    || die "cursor cycle gave rc=$rc (124 = it hung) out='$out'"
# Restore the shared stub for the cases below.
cat > "$TMP/bin/gh" <<'GHSH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "api graphql")
    [ -n "${GH_GQL_RC:-}" ] && exit "$GH_GQL_RC"
    if [ -n "${GH_PAGE2:-}" ] && [ -e "$TMP_SEEN" ]; then cat "$GH_PAGE2"; else
       : > "$TMP_SEEN" 2>/dev/null || true; cat "${GH_PAGE1:-/dev/null}"; fi ;;
  "api "*) [ -n "${GH_REVIEWS_RC:-}" ] && exit "$GH_REVIEWS_RC"; cat "${GH_REVIEWS:-/dev/null}" ;;
  "pr view"*) printf '%s' "${GH_HEAD:-}" ;;
  *) printf '{}' ;;
esac
GHSH
chmod +x "$TMP/bin/gh"

# A cursor that DOES advance still paginates — the guard must not stop a real
# multi-page read.
page true '"C1"' "$NODE_OK" > "$TMP/adv1.json"
page false null "$NODE_OK" > "$TMP/adv2.json"
out="$(timeout 20 env GH_PAGE1="$TMP/adv1.json" GH_PAGE2="$TMP/adv2.json" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" list 7 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
    && pass "list: an advancing cursor still paginates" \
    || die "advancing cursor gave rc=$rc out='$out'"

# ── blocked-body: an unknown state is not "no body" ───────────────────────
# This helper SUPPRESSES output for anything that is not exactly
# CHANGES_REQUESTED, so a record with a null or unrecognised state produced empty
# stdout and rc 0 — indistinguishable from "this blocking review has no body".
# The driver only gets here because it saw `state=blocked`, so that is precisely
# where silence loses the only text there is.
for badstate in 'null' '"WIBBLE"' '""'; do
    printf '[{"user":{"login":"%s"},"commit_id":"%s","state":%s,"submitted_at":"2026-01-02T00:00:00Z","body":"the request","id":1}]' \
        "$BOT" "$HEAD40" "$badstate" > "$TMP/badstate.json"
    out="$(GH_REVIEWS="$TMP/badstate.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "blocked-body: review state $badstate => 2, not silent" \
        || die "blocked-body state $badstate gave rc=$rc out='$out'"
done

# A real CHANGES_REQUESTED body still comes back.
printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"CHANGES_REQUESTED","submitted_at":"2026-01-02T00:00:00Z","body":"the request","id":1}]' \
    "$BOT" "$HEAD40" > "$TMP/goodstate.json"
out="$(GH_REVIEWS="$TMP/goodstate.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'the request'; } \
    && pass "blocked-body: a real blocking body is still returned" \
    || die "valid CHANGES_REQUESTED body was lost (rc=$rc out='$out')"

# ── blocked-body sorts on submitted_at too, so the same rule applies ──────
# `sort_by(.submitted_at) | last` decides which review is authoritative here as
# well, and the sort is lexical. An older APPROVED carrying a numeric offset
# sorts ABOVE a newer CHANGES_REQUESTED — `03:00:00+02:00` is 01:00 UTC — so the
# latest record is read as the approval and the blocking body is silently
# suppressed: empty output, rc 0, which the driver reads as "no body".
printf '[{"user":{"login":"%s"},"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-01-02T02:30:00Z","body":"the newer request"},{"user":{"login":"%s"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-01-02T03:00:00+02:00","body":"older approval"}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/bboffset.json"
out="$(GH_REVIEWS="$TMP/bboffset.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "blocked-body: an offset timestamp => 2, not a hidden request body" \
    || die "blocked-body offset timestamp gave rc=$rc out='$out'"

# Fractional seconds mis-sort the other way: `.5Z` sorts before plain `Z`.
printf '[{"user":{"login":"%s"},"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-01-02T03:00:00.5Z","body":"the newer request"},{"user":{"login":"%s"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-01-02T03:00:00Z","body":"older approval"}]' \
    "$BOT" "$HEAD40" "$BOT" "$HEAD40" > "$TMP/bbfrac.json"
out="$(GH_REVIEWS="$TMP/bbfrac.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "blocked-body: a fractional-second timestamp => 2" \
    || die "blocked-body fractional timestamp gave rc=$rc out='$out'"

# A bad head is rejected rather than matched against.
out="$(GH_REVIEWS="$TMP/rev.json" run blocked-body 7 "$BOT" "not-a-sha" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "blocked-body: a malformed head => 2" || die "bad head gave rc=$rc"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
