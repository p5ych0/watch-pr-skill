#!/usr/bin/env bash
# Focused test for review-bus-request.sh's fail-closed preflight (recovered from
# the retired pulse legacy smoke test): when the unresolved-threads GraphQL query
# FAILS, request.sh must block and write NO request file — it must never satisfy
# the zero-unresolved gate on a fetch error. Also proves the happy path writes a
# request, so the fail-closed result is attributable to the GraphQL failure and
# not a broken harness.
#
# Uses a REAL throwaway git repo (bare origin + pushed HEAD) so the clean-tree and
# head-pushed gates pass with real git; only `gh` is stubbed. No network.
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REQUEST="$SELF_DIR/review-bus-request.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# ── Real repo: clean tree + pushed HEAD so preflight gates 1-2 hold ──────────
ORIGIN="$TMP/origin.git"; REPO="$TMP/repo"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name test
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" push -q -u origin HEAD 2>/dev/null

# ── Stub gh: reviewThreads GraphQL fails when GH_GRAPHQL_FAIL is set, else
#    reports 0 unresolved; no inline pull comments; a fresh issue-level summary ─
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *graphql*)
    [ -n "${GH_GRAPHQL_FAIL:-}" ] && exit 1
    printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}' ;;
  *"/pulls/"*"/comments"*)  printf '%s' '[]' ;;
  *"/issues/"*"/comments"*) printf '%s' '[{"created_at":"2026-07-18T23:59:59Z"}]' ;;
  *) printf '%s' '{}' ;;
esac
SH
chmod +x "$TMP/bin/gh"

req_written() { ls "$TMP/bus"/requests/req-*.json >/dev/null 2>&1; }

# ── (a) happy path — every gate passes → a request IS written (exit 0) ───────
rm -rf "$TMP/bus"
( cd "$REPO" && PATH="$TMP/bin:$PATH" BUS_DIR="$TMP/bus" REPO_DIR="$REPO" bash "$REQUEST" 42 ) >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && req_written; then
    pass "happy path: gates pass → request written (harness valid)"
else
    die "happy path did not write a request (rc=$rc) — harness broken, fail-closed result would be meaningless"
fi

# ── (b) fail-closed — threads GraphQL fails → BLOCK + write NO request ───────
rm -rf "$TMP/bus"
( cd "$REPO" && PATH="$TMP/bin:$PATH" BUS_DIR="$TMP/bus" REPO_DIR="$REPO" GH_GRAPHQL_FAIL=1 bash "$REQUEST" 42 ) >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! req_written; then
    pass "fail-closed: threads GraphQL failure blocks + writes no request (rc=$rc)"
else
    die "NOT fail-closed: rc=$rc, request written=$(ls "$TMP/bus"/requests/ 2>/dev/null || echo none)"
fi

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
