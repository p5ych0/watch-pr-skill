#!/usr/bin/env bash
# Focused test for review-bus-close-round.sh — the one-command round close-out.
#
# Covers the happy path AND the "fail before irreversible mutation" gates the
# reviewer flagged: a non-regular --summary (dir/FIFO), a reply failure, and a
# HEAD that is not the PR's head must all stop BEFORE any thread is resolved.
# Plus the ack TOCTOU regression: a same-SHA response swapped in AFTER the
# close-out must still notify (its digest differs, so the marker can't suppress
# it). Uses a REAL throwaway git repo (bare origin + pushed HEAD with upstream)
# so request.sh's git gates pass; identity is forced via REVIEW_BUS_OWNER/REPO
# so `origin` can stay the local bare repo (the head-mismatch gate needs the git
# gates to PASS so execution actually reaches the PR-head comparison). `gh` is
# stubbed (env-driven).
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLOSE="$SELF_DIR/review-bus-close-round.sh"
MONITOR="$SELF_DIR/review-bus-response-monitor.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# Identity is forced via env so origin can remain the real bare repo.
export REVIEW_BUS_OWNER=acme REVIEW_BUS_REPO=widgets

# ── Real repo: clean tree + pushed HEAD with a tracking upstream ─────────────
# `origin` stays the local bare repo (NOT rewritten to a github URL) so the
# close-round git preflight — upstream present, fetch works, remote HEAD ==
# local HEAD — actually PASSES; only then does execution reach the PR-head gate.
ORIGIN="$TMP/origin.git"; REPO="$TMP/repo"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
(
  cd "$REPO"
  git config user.email t@t.t; git config user.name t
  echo x > f; git add f; git commit -qm init
  git branch -M feat
  git push -q -u origin feat 2>/dev/null   # creates origin/feat + sets upstream
)
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

echo "hi" > "$TMP/sum.md"

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
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" GHLOG="$GHLOG" "$CLOSE" 7 --force --summary "$TMP/sum.md" >/dev/null 2>"$TMP/e1" ); rc=$?
[ "$rc" -eq 0 ] || die "happy: non-zero (rc=$rc): $(cat "$TMP/e1")"
[ "$(grep -c RESOLVE "$GHLOG")" -eq 2 ] && pass "happy: resolved both threads" || die "happy: expected 2 RESOLVE got $(grep -c RESOLVE "$GHLOG")"
grep -q SUMMARY "$GHLOG" && pass "happy: posted summary" || die "happy: no summary"
ls "$BUS/requests"/req-*.json >/dev/null 2>&1 && pass "happy: enqueued request" || die "happy: no request file"
ls "$BUS/.monitor-acked"/resp-oldsha1.json.* >/dev/null 2>&1 && pass "happy: acked unchanged round-1 response" || die "happy: not acked"

# ── 2. Missing --summary file: stop before any mutation ──────────────────────
BUS="$(new_bus 2)"; GHLOG="$TMP/gh2.log"; : > "$GHLOG"
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" GHLOG="$GHLOG" "$CLOSE" 7 --force --summary "$TMP/nope.md" >/dev/null 2>/dev/null ); rc=$?
[ "$rc" -ne 0 ] && pass "bad-summary: exits non-zero" || die "bad-summary: should fail"
[ "$(grep -c RESOLVE "$GHLOG")" -eq 0 ] && pass "bad-summary: resolved nothing" || die "bad-summary: mutated ($(grep -c RESOLVE "$GHLOG") RESOLVE)"

# ── 3. --summary is a directory (readable, NOT a regular file): stop ─────────
# `-r` is true for a directory; the preflight must additionally require `-f`,
# else gh pr comment --body-file would fail only AFTER threads are resolved.
BUS="$(new_bus 3)"; GHLOG="$TMP/gh3.log"; : > "$GHLOG"
mkdir -p "$TMP/sumdir"
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" GHLOG="$GHLOG" "$CLOSE" 7 --force --summary "$TMP/sumdir" >/dev/null 2>/dev/null ); rc=$?
[ "$rc" -ne 0 ] && pass "dir-summary: exits non-zero" || die "dir-summary: should fail on a non-regular file"
[ "$(grep -c RESOLVE "$GHLOG")" -eq 0 ] && pass "dir-summary: resolved nothing" || die "dir-summary: mutated ($(grep -c RESOLVE "$GHLOG") RESOLVE)"

# ── 4. Reply failure: leave unresolved, fail, no request ─────────────────────
BUS="$(new_bus 4)"; GHLOG="$TMP/gh4.log"; : > "$GHLOG"
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" GHLOG="$GHLOG" STUB_REPLY_FAIL=1 "$CLOSE" 7 --force >/dev/null 2>/dev/null ); rc=$?
[ "$rc" -ne 0 ] && pass "reply-fail: exits non-zero" || die "reply-fail: should fail"
[ "$(grep -c RESOLVE "$GHLOG")" -eq 0 ] && pass "reply-fail: did NOT resolve a thread whose reply failed" || die "reply-fail: resolved anyway"
ls "$BUS/requests"/req-*.json >/dev/null 2>&1 && die "reply-fail: should not enqueue" || pass "reply-fail: no request enqueued"

# ── 5. HEAD is not the PR head: reach the gate (git preflight PASSES), stop ──
# No --force, so the git gates run. They must PASS (origin is the real bare repo
# with a pushed upstream) so execution REACHES `gh pr view --json headRefOid`;
# the stubbed mismatch then fails. Asserting headRefOid appears in GHLOG proves
# the PR-head gate — not an earlier git gate — is what stopped the run.
BUS="$(new_bus 5)"; GHLOG="$TMP/gh5.log"; : > "$GHLOG"
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" GHLOG="$GHLOG" STUB_PR_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$CLOSE" 7 >/dev/null 2>/dev/null ); rc=$?
[ "$rc" -ne 0 ] && pass "head-mismatch: exits non-zero" || die "head-mismatch: should fail"
grep -q "headRefOid" "$GHLOG" && pass "head-mismatch: reached the PR-head gate (git preflight passed)" || die "head-mismatch: never called headRefOid — failed at an earlier git gate, test is inert"
[ "$(grep -c RESOLVE "$GHLOG")" -eq 0 ] && pass "head-mismatch: mutated nothing" || die "head-mismatch: mutated before failing"

# ── 6. Ack TOCTOU: a same-SHA swap AFTER close-out still notifies ────────────
# close-round acks resp-oldsha1.json by the digest it CAPTURED. If the watcher
# then overwrites that path with a fresh same-SHA review (different content →
# different digest), the marker keyed on the OLD digest must NOT suppress it —
# the monitor must re-emit the fresh review.
BUS="$(new_bus 6)"; GHLOG="$TMP/gh6.log"; : > "$GHLOG"
RESP="$BUS/responses/resp-oldsha1.json"
OLD_DIGEST="$(sha256sum "$RESP" | awk '{print $1}')"
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" GHLOG="$GHLOG" "$CLOSE" 7 --force --summary "$TMP/sum.md" >/dev/null 2>/dev/null ); rc=$?
[ "$rc" -eq 0 ] || die "ack-race: close-out failed (rc=$rc)"
[ -e "$BUS/.monitor-acked/resp-oldsha1.json.$OLD_DIGEST" ] && pass "ack-race: marked the handled digest" || die "ack-race: handled digest not marked"
# Watcher swaps in a FRESH same-SHA review (different content → different digest).
printf '{"pr":7,"sha":"oldsha1","status":"changes","findings_count":9}' > "$RESP"
NEW_DIGEST="$(sha256sum "$RESP" | awk '{print $1}')"
[ -e "$BUS/.monitor-acked/resp-oldsha1.json.$NEW_DIGEST" ] && die "ack-race: fresh review's digest wrongly suppressed" || pass "ack-race: fresh same-SHA review NOT suppressed"
OUT="$( MONITOR_EMITTED_DIR="$TMP/em6" BUS_DIR="$BUS" "$MONITOR" --once 2>/dev/null )"
echo "$OUT" | grep -q "findings=9" && pass "ack-race: monitor re-emits the fresh review" || die "ack-race: monitor suppressed the fresh review"

exit $fail
