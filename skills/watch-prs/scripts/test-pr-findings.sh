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
NODE_OK='[{"isResolved":false,"path":"a.sh","line":1,"comments":{"nodes":[{"author":{"login":"bot"},"body":"finding one"}]}},{"isResolved":true,"path":"b.sh","line":2,"comments":{"nodes":[{"author":{"login":"bot"},"body":"old"}]}}]'

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
page false null '[{"isResolved":false,"path":"c.sh","line":3,"comments":{"nodes":[{"author":{"login":"bot"},"body":"finding two"}]}}]' > "$TMP/p2.json"
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
    '[{"isResolved":false,"path":"a","line":1,"comments":{"nodes":[]}}]' \
    '[{"isResolved":false,"path":"a","line":1,"comments":{"nodes":[{"author":null,"body":"x"}]}}]' \
    '[{"isResolved":false,"path":"a","line":1,"comments":{"nodes":[{"author":{"login":"b"},"body":null}]}}]' \
    '[{"isResolved":"false","path":"a","line":1,"comments":{"nodes":[{"author":{"login":"b"},"body":"x"}]}}]'
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
printf '[{"user":{"login":"%s"},"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"t1","body":"please change X"}]' \
    "$BOT" "$HEAD40" > "$TMP/rev.json"
out="$(GH_REVIEWS="$TMP/rev.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'please change X'; } \
    && pass "blocked-body: prints the blocking body for this head" || die "blocked-body (rc=$rc out='$out')"

# A stale CHANGES_REQUESTED on an OLDER commit is not an active finding.
printf '[{"user":{"login":"%s"},"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"t1","body":"stale request"}]' \
    "$BOT" "$OLD40" > "$TMP/stale.json"
out="$(GH_REVIEWS="$TMP/stale.json" run blocked-body 7 "$BOT" "$HEAD40" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
    && pass "blocked-body: a stale request on an older head is not printed" \
    || die "stale body leaked (rc=$rc out='$out')"

# Another reviewer's blocking body is not this reviewer's.
printf '[{"user":{"login":"someone-else"},"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"t1","body":"theirs"}]' \
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

# A bad head is rejected rather than matched against.
out="$(GH_REVIEWS="$TMP/rev.json" run blocked-body 7 "$BOT" "not-a-sha" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "blocked-body: a malformed head => 2" || die "bad head gave rc=$rc"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
