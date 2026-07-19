#!/usr/bin/env bash
# Focused test for review-bus-close-round.sh — the one-command round close-out.
#
# Covers the happy path AND the "fail before irreversible mutation" gates the
# reviewer flagged: a non-regular --summary (dir/FIFO), a reply failure, and a
# HEAD that is not the PR's head must all stop BEFORE any thread is resolved.
# Plus the ack TOCTOU regression: a same-SHA response swapped in DURING the
# close-out — after the snapshot, before the ack (injected via the gh summary
# stub) — must leave the handled (captured) digest marked and the replacement
# unmarked + re-emitted. Swapping only after close-round returns would prove
# nothing (the old compare-then---ack passes that); mid-close is what catches a
# regression. Uses a REAL throwaway git repo (bare origin + pushed HEAD with upstream)
# so request.sh's git gates pass; identity is forced via REVIEW_BUS_OWNER/REPO
# so `origin` can stay the local bare repo (the head-mismatch gate needs the git
# gates to PASS so execution actually reaches the PR-head comparison). `gh` is
# stubbed (env-driven).
#
# Setup runs under `set -Eeuo pipefail` (a failed clone/push/config must abort
# loudly, not silently continue into misleading assertions). The assertion block
# then switches to `set +e` so the intentional non-zero close-round runs can be
# captured via `; rc=$?` and `grep -c` (0 matches → exit 1) works — matching the
# suite's other failure-capturing tests (worktree/health/error-retry).
set -Eeuo pipefail

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
  *"pr comment"*)                       echo "SUMMARY" >> "\$GHLOG";
                                        # STUB_SWAP_RESP=1: overwrite the response
                                        # HERE — mid-close, AFTER close-round's
                                        # snapshot but BEFORE its ack — to prove
                                        # the ack keys on the captured digest and
                                        # cannot regress to a re-hash.
                                        [ "\${STUB_SWAP_RESP:-0}" = "1" ] && printf '%s' '{"pr":7,"sha":"oldsha1","status":"changes","findings_count":9}' > "\$BUS_DIR/responses/resp-oldsha1.json";
                                        echo "https://x/comment" ;;
  *)                                    printf '{}' ;;
esac
STUB
chmod +x "$BIN/gh"

new_bus() {   # fresh bus with one pre-existing round-1 response
  local b="$TMP/bus.$1"; mkdir -p "$b/responses" "$b/requests"
  printf '{"pr":7,"sha":"oldsha1","status":"changes","findings_count":2}' > "$b/responses/resp-oldsha1.json"
  echo "$b"
}

# Assertions capture intentional non-zero results (failure-gate cases) and use
# grep -c (exit 1 on 0 matches), so the -e must not govern them.
set +e

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

# ── 6. Ack TOCTOU proven: swap DURING close-out (snapshot < swap < ack) ──────
# The swap is injected by the gh summary-post stub (STUB_SWAP_RESP=1), so it
# lands AFTER close-round snapshots the response but BEFORE it acks — the exact
# interleaving the fix must survive. A swap AFTER close-round returns would prove
# nothing: the old compare-then---ack passes that too. Here it does NOT:
#   • THIS impl acks the digest CAPTURED at snapshot → the handled (old) digest
#     is marked; the mid-close replacement (new digest) stays unmarked + emits.
#   • The old f55bd6f impl re-hashes the swapped file: its section-5 compare
#     mismatches, it SKIPS the ack, and the handled digest is left UNMARKED — so
#     "handled digest marked" fails, catching the regression.
BUS="$(new_bus 6)"; GHLOG="$TMP/gh6.log"; : > "$GHLOG"
RESP="$BUS/responses/resp-oldsha1.json"
OLD_DIGEST="$(sha256sum "$RESP" | awk '{print $1}')"
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" GHLOG="$GHLOG" STUB_SWAP_RESP=1 "$CLOSE" 7 --force --summary "$TMP/sum.md" >/dev/null 2>/dev/null ); rc=$?
[ "$rc" -eq 0 ] || die "swap-during: close-out failed (rc=$rc)"
NEW_DIGEST="$(sha256sum "$RESP" | awk '{print $1}')"
[ "$OLD_DIGEST" != "$NEW_DIGEST" ] || die "swap-during: response was not actually swapped mid-close (test setup broken)"
[ -e "$BUS/.monitor-acked/resp-oldsha1.json.$OLD_DIGEST" ] && pass "swap-during: HANDLED (captured) digest marked — no regression to re-hash" || die "swap-during: handled digest NOT marked (regressed to compare-then-ack)"
[ -e "$BUS/.monitor-acked/resp-oldsha1.json.$NEW_DIGEST" ] && die "swap-during: mid-close replacement digest wrongly marked (would suppress a fresh review)" || pass "swap-during: replacement digest unmarked"
OUT="$( MONITOR_EMITTED_DIR="$TMP/em6" BUS_DIR="$BUS" "$MONITOR" --once 2>/dev/null )"
echo "$OUT" | grep -q "findings=9" && pass "swap-during: monitor emits the mid-close replacement" || die "swap-during: replacement suppressed"

# ── 7. A junk/unparsable response in the dir must NOT abort the snapshot ──────
# Section 1 runs under set -euo pipefail; an unguarded jq/sha256sum on an
# incomplete or unreadable resp-*.json would fail the pipeline and abort the
# whole close-out before it mutates anything. The snapshot must skip the junk
# file, still process the good one, and never ack the junk.
BUS="$(new_bus 7)"; GHLOG="$TMP/gh7.log"; : > "$GHLOG"
GOOD_DIGEST="$(sha256sum "$BUS/responses/resp-oldsha1.json" | awk '{print $1}')"
printf 'this is not json{' > "$BUS/responses/resp-junk.json"     # unparsable
: > "$BUS/responses/resp-empty.json"                             # empty (jq → no pr)
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" GHLOG="$GHLOG" "$CLOSE" 7 --force --summary "$TMP/sum.md" >/dev/null 2>/dev/null ); rc=$?
[ "$rc" -eq 0 ] && pass "junk-response: close-out still succeeds (snapshot tolerant)" || die "junk-response: aborted (rc=$rc)"
[ "$(grep -c RESOLVE "$GHLOG")" -eq 2 ] && pass "junk-response: threads still resolved" || die "junk-response: threads not resolved ($(grep -c RESOLVE "$GHLOG"))"
[ -e "$BUS/.monitor-acked/resp-oldsha1.json.$GOOD_DIGEST" ] && pass "junk-response: good response acked" || die "junk-response: good response not acked"
ls "$BUS/.monitor-acked"/resp-junk.json.* >/dev/null 2>&1 && die "junk-response: junk file wrongly acked" || pass "junk-response: junk file skipped (not acked)"

# ── 8. A dirty INDEX (staged change, worktree reverted to HEAD) blocks too ───
# `git diff HEAD` alone is clean when a staged change's worktree copy was
# reverted to HEAD, so the preflight must also check --cached. Old code would
# proceed and resolve threads; the fix must fail before any mutation. (Non-force
# so the git preflight runs; the dirty gate is first, before upstream/head.)
BUS="$(new_bus 8)"; GHLOG="$TMP/gh8.log"; : > "$GHLOG"
(
  cd "$REPO"
  printf 'staged only\n' >> f
  git add f
  git cat-file blob HEAD:f > f          # worktree back to HEAD; index stays staged
)
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" GHLOG="$GHLOG" "$CLOSE" 7 --summary "$TMP/sum.md" >/dev/null 2>"$TMP/e8" ); rc=$?
git -C "$REPO" reset -q --hard HEAD 2>/dev/null      # restore clean tree for any later use
[ "$rc" -ne 0 ] && pass "dirty-index: staged-only change blocks the close-out" || die "dirty-index: proceeded on a dirty index"
grep -qi 'dirty' "$TMP/e8" && pass "dirty-index: reports a dirty checkout" || die "dirty-index: did not report dirty ($(cat "$TMP/e8"))"
[ "$(grep -c RESOLVE "$GHLOG")" -eq 0 ] && pass "dirty-index: mutated nothing" || die "dirty-index: mutated before failing"

# ── 9. --summary without a value fails cleanly during arg-parse ──────────────
# A bare `--summary` (or one followed by another flag) must error with a clear
# message during parsing — never `shift 2` past the end (cryptic under set -e) or
# swallow the PR number / next flag as the summary path.
( cd "$REPO" && PATH="$BIN:$PATH" "$CLOSE" 7 --summary >/dev/null 2>"$TMP/e9a" ); rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'requires a file-path' "$TMP/e9a"; } && pass "summary-noval: bare --summary errors clearly" || die "summary-noval: no clear error ($(cat "$TMP/e9a"))"
( cd "$REPO" && PATH="$BIN:$PATH" "$CLOSE" 7 --summary --force >/dev/null 2>"$TMP/e9b" ); rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'requires a file-path' "$TMP/e9b"; } && pass "summary-noval: --summary before a flag errors (flag not swallowed)" || die "summary-noval: flag swallowed as value ($(cat "$TMP/e9b"))"

# ── 10. Missing/non-GitHub origin (no identity env) → clear early error ──────
# With no origin remote and REVIEW_BUS_OWNER/REPO unset, the derived slug is
# empty; the guard must fail early naming the env vars, not fall through to a
# confusing `gh not found`.
NOORIGIN="$TMP/noorigin"; git init -q "$NOORIGIN"
( cd "$NOORIGIN" && git config user.email t@t.t && git config user.name t && echo x > f && git add f && git commit -qm init ) >/dev/null 2>&1
( cd "$NOORIGIN" && PATH="$BIN:$PATH" env -u REVIEW_BUS_OWNER -u REVIEW_BUS_REPO "$CLOSE" 7 --force >/dev/null 2>"$TMP/e10" ); rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'REVIEW_BUS_OWNER' "$TMP/e10"; } && pass "no-identity: clear owner/repo error naming the env vars" || die "no-identity: unclear error ($(cat "$TMP/e10"))"

exit $fail
