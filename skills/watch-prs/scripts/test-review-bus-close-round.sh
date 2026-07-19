#!/usr/bin/env bash
# Focused test for review-bus-close-round.sh — the one-command round close-out.
#
# Proves the finalize sequence that a half-done handoff skips: every unresolved
# thread is resolved, a summary is posted, the next SHA is enqueued as a request
# file, and the pre-existing response is acked. Uses a REAL throwaway git repo
# (bare origin + pushed HEAD) so request.sh's git gates pass; `gh` is stubbed and
# --force forwards a bypass to request.sh so its GraphQL gates need no network.
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

BUS="$TMP/bus"; mkdir -p "$BUS/responses" "$BUS/requests"
SHA=$(git -C "$REPO" rev-parse --short=7 HEAD)
# A pre-existing round-1 response for PR 7 that close-round must ack.
printf '{"pr":7,"sha":"oldsha1","status":"changes","findings_count":2}' > "$BUS/responses/resp-oldsha1.json"

# ── gh stub: dispatch on the call close-round makes ─────────────────────────
GHLOG="$TMP/gh.log"
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<STUB
#!/usr/bin/env bash
echo "gh \$*" >> "$GHLOG"
args="\$*"
case "\$args" in
  *"reviewThreads"*)
    # Two unresolved threads, single page.
    printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T1","isResolved":false},{"id":"T2","isResolved":false}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'
    ;;
  *"addPullRequestReviewThreadReply"*) echo "REPLY" >> "$GHLOG"; printf '{"data":{}}' ;;
  *"resolveReviewThread"*)              echo "RESOLVE" >> "$GHLOG"; printf '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}' ;;
  *"pr comment"*)                       echo "SUMMARY" >> "$GHLOG"; echo "https://x/comment" ;;
  *"pr view"*)                          echo 7 ;;
  *) printf '{}' ;;
esac
STUB
chmod +x "$BIN/gh"

# ── Run: close-round 7 --force ───────────────────────────────────────────────
( cd "$REPO" && PATH="$BIN:$PATH" BUS_DIR="$BUS" "$CLOSE" 7 --force >"$TMP/out" 2>"$TMP/err" )
rc=$?

[ "$rc" -eq 0 ] || die "close-round exited non-zero (rc=$rc): $(cat "$TMP/err")"
[ "$(grep -c RESOLVE "$GHLOG")" -eq 2 ] && pass "resolved both unresolved threads" || die "expected 2 RESOLVE, got $(grep -c RESOLVE "$GHLOG")"
[ "$(grep -c REPLY "$GHLOG")" -eq 2 ] && pass "posted a thread-level reply per thread" || die "expected 2 REPLY, got $(grep -c REPLY "$GHLOG")"
grep -q SUMMARY "$GHLOG" && pass "posted the round-summary comment" || die "no summary comment posted"
ls "$BUS/requests"/req-*.json >/dev/null 2>&1 && pass "enqueued a review request for the new SHA" || die "no request file written"
ls "$BUS/.monitor-acked"/resp-oldsha1.json.* >/dev/null 2>&1 && pass "acked the pre-existing round-1 response" || die "round-1 response not acked"

exit $fail
