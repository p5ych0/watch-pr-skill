#!/usr/bin/env bash
# Focused test for review-bus-close-round.sh — the one-command round close-out.
#
# Covers the happy path AND the three "fail before irreversible mutation" gates
# the reviewer flagged: a bad --summary, a reply failure, and a HEAD that is not
# the PR's head must all stop BEFORE any thread is resolved. Uses a REAL
# throwaway git repo (bare origin + pushed HEAD) so request.sh's git gates pass;
# `gh` is stubbed (env-driven) and the happy path uses --force so request.sh's
# GraphQL gates need no network.
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLOSE="$SELF_DIR/review-bus-close-round.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# ── Real repo: clean tree + pushed HEAD ─────────────────────────────────────
ORIGIN="$TMP/origin.git"; REPO="$TMP/repo"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
(
  cd "$REPO"
  git config user.email t@t.t; git config user.name t
  git remote set-url origin git@github.com:acme/widgets.git
  echo x > f; git add f; git commit -qm init
  git branch -M feat
  git -c push.default=current push -q "$ORIGIN" feat 2>/dev/null
  git branch --set-upstream-to=origin/feat >/dev/null 2>&1 || true
)
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

BIN="$TMP/bin"; mkdir -p "$BIN"
# gh stub: env STUB_REPLY_FAIL=1 makes addReply exit nonzero; STUB_PR_HEAD
# overrides the reported PR head (default = real HEAD so preflight passes).
cat > "$BIN/gh" <<STUB
#!/usr/bin/env bash
echo "gh \$*" >> "\$GHLOG"
args="\$*"
case "\$args" in
  *"headRefOid"*)                       printf '%s' "\${STUB_PR_HEAD:-$HEAD_SHA}" ;;
  *"pr view"*"number"*)                 echo 7 ;;
  *"reviewThreads"*)                    printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T1","isResolved":false},{"id":"T2","isResolved":false}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}' ;;
  *"addPullRequestReviewThreadReply"*)  [ "\${STUB_REPLY_FAIL:-0}" = "1" ] && { echo "REPLYFAIL" >> "\$GHLOG"; exit 1; }; echo "REPLY" >> "\$GHLOG"; printf '{"data":{}}' ;;
  *"resolveReviewThread"*)              echo "RESOLVE" >> "\$GHLOG"; printf '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}' ;;
  *"pr comment"*)                       echo "SUMMARY" >> "\$GHLOG"; echo "https://x/comment" ;;
  *)                                    printf '{}' ;;
esac
STUB
chmod +x "$BIN/gh"

new_bus() {   # fresh bus with one pre-existing round-1 response
  local b="$TMP/bus.$1"; mkdir -p "$b/responses" "$b/requests"
  printf '{"pr":7,"sha":"oldsha1","status":"changes","findings_count":2}' > "$b/responses/resp-oldsha1.json"
  echo "$b"
}

# ── 1. Happy path (--force + summary): full close-out ───────────────────────
BUS="$(new_bus 1)"; GHLOG="$TMP/gh1.log"; : > "$GHLOG"
echo "hi" > "$TMP/sum.md"
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" GHLOG="$GHLOG" "$CLOSE" 7 --force --summary "$TMP/sum.md" >/dev/null 2>"$TMP/e1" ); rc=$?
[ "$rc" -eq 0 ] || die "happy: non-zero (rc=$rc): $(cat "$TMP/e1")"
[ "$(grep -c RESOLVE "$GHLOG")" -eq 2 ] && pass "happy: resolved both threads" || die "happy: expected 2 RESOLVE got $(grep -c RESOLVE "$GHLOG")"
grep -q SUMMARY "$GHLOG" && pass "happy: posted summary" || die "happy: no summary"
ls "$BUS/requests"/req-*.json >/dev/null 2>&1 && pass "happy: enqueued request" || die "happy: no request file"
ls "$BUS/.monitor-acked"/resp-oldsha1.json.* >/dev/null 2>&1 && pass "happy: acked unchanged round-1 response" || die "happy: not acked"

# ── 2. Missing --summary file: stop before any mutation (#2) ─────────────────
BUS="$(new_bus 2)"; GHLOG="$TMP/gh2.log"; : > "$GHLOG"
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" GHLOG="$GHLOG" "$CLOSE" 7 --force --summary "$TMP/nope.md" >/dev/null 2>/dev/null ); rc=$?
[ "$rc" -ne 0 ] && pass "bad-summary: exits non-zero" || die "bad-summary: should fail"
[ "$(grep -c RESOLVE "$GHLOG")" -eq 0 ] && pass "bad-summary: resolved nothing" || die "bad-summary: mutated ($(grep -c RESOLVE "$GHLOG") RESOLVE)"

# ── 3. Reply failure: leave unresolved, fail, no request (#3) ────────────────
BUS="$(new_bus 3)"; GHLOG="$TMP/gh3.log"; : > "$GHLOG"
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" GHLOG="$GHLOG" STUB_REPLY_FAIL=1 "$CLOSE" 7 --force >/dev/null 2>/dev/null ); rc=$?
[ "$rc" -ne 0 ] && pass "reply-fail: exits non-zero" || die "reply-fail: should fail"
[ "$(grep -c RESOLVE "$GHLOG")" -eq 0 ] && pass "reply-fail: did NOT resolve a thread whose reply failed" || die "reply-fail: resolved anyway"
ls "$BUS/requests"/req-*.json >/dev/null 2>&1 && die "reply-fail: should not enqueue" || pass "reply-fail: no request enqueued"

# ── 4. HEAD is not the PR head: stop before mutation (#1) ────────────────────
BUS="$(new_bus 4)"; GHLOG="$TMP/gh4.log"; : > "$GHLOG"
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" GHLOG="$GHLOG" STUB_PR_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$CLOSE" 7 >/dev/null 2>/dev/null ); rc=$?
[ "$rc" -ne 0 ] && pass "head-mismatch: exits non-zero" || die "head-mismatch: should fail"
[ "$(grep -c RESOLVE "$GHLOG")" -eq 0 ] && pass "head-mismatch: mutated nothing" || die "head-mismatch: mutated before preflight"

exit $fail
