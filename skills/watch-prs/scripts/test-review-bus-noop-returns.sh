#!/usr/bin/env bash
# Regression test for issue #3 — the watcher crash-loop.
#
# Trigger: CODEX_REVIEW_AUTO_OPEN_PRS=1, an open PR passes auto_preflight_ready,
# and responses/resp-<current-head>.json already exists with a TERMINAL,
# non-error status (`approved`, `comments_posted`). write_auto_request must treat
# that as a SUCCESSFUL no-op and leave the response alone.
#
# The defect was a bare `return` after a failed test: `[ "$prev_status" = "error" ]
# || return` inherits the failed test's exit status 1. Because the function is
# called unguarded under `set -Eeuo pipefail`, the intentional no-op terminated
# the daemon, which systemd then restarted every few seconds. Observed live on
# this repository's own PR #4 (NRestarts=6) and originally on p5ych0/strumok#176.
#
# handle() carries the identical pattern at its `[ -f "$req" ] || return` guard —
# a request file that vanishes between detection and handling would kill the
# daemon the same way — so it is covered here too.
#
# Self-contained: throwaway git repo + BUS_DIR under a temp dir. No network, no
# gh, no codex.

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SELF_DIR/review-bus-codex-watcher.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

REPO_DIR="$TMP/repo"; mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email t@example.com
git -C "$REPO_DIR" config user.name test
echo seed > "$REPO_DIR/f.txt"
git -C "$REPO_DIR" add -A; git -C "$REPO_DIR" commit -qm init
HEAD_OID="$(git -C "$REPO_DIR" rev-parse HEAD)"
SHORT="${HEAD_OID:0:7}"

export REPO_DIR BUS_DIR="$TMP/bus" REVIEW_BUS_REMOTE="git@github.com:test/demo.git"
mkdir -p "$BUS_DIR/requests" "$BUS_DIR/responses" "$BUS_DIR/.codex-seen"

# shellcheck disable=SC1090
source "$WATCHER"
set +e   # the watcher's own set -e must not govern these assertions

# ── 1. Terminal non-error response for the current head → successful no-op ────
# One case per terminal status the watcher can write, since the bug was keyed on
# "not error" rather than on any single status value.
for st in comments_posted approved; do
    resp="$BUS_DIR/responses/resp-${SHORT}.json"
    printf '{"pr":4,"sha":"%s","status":"%s","findings":0}\n' "$SHORT" "$st" > "$resp"
    rm -f "$BUS_DIR/requests/req-${SHORT}.json"

    ( write_auto_request 4 main "$HEAD_OID" ) >/dev/null 2>&1
    rc=$?

    [ "$rc" -eq 0 ] \
        && pass "write_auto_request: status=$st is a no-op with rc=0 (not $rc)" \
        || die  "write_auto_request: status=$st returned $rc — this kills the daemon under set -e"

    [ ! -f "$BUS_DIR/requests/req-${SHORT}.json" ] \
        && pass "write_auto_request: status=$st wrote no request (terminal response left alone)" \
        || die  "write_auto_request: status=$st rewrote a request over a terminal response"
done

# ── 2. The unguarded caller must survive it ──────────────────────────────────
# auto_enqueue_open_pr_heads calls write_auto_request unguarded, and main() calls
# auto_enqueue_open_pr_heads unguarded. Asserting the callee's rc is not enough:
# the daemon death happened at the call site. Re-run under `set -e` in a subshell
# that continues afterwards — if the no-op returns non-zero, `after` never prints.
out="$( set -Eeuo pipefail
        write_auto_request 4 main "$HEAD_OID" >/dev/null 2>&1
        echo after )"
[ "$out" = "after" ] \
    && pass "no-op does not abort an enclosing 'set -e' caller" \
    || die  "enclosing set -e caller aborted on the no-op (daemon would exit)"

# ── 3. handle(): a request that vanishes before handling is also a no-op ──────
# Same defect class: `[ -f "$req" ] || return` inherits 1 from the failed test,
# and handle() is likewise called unguarded from the main loop.
out2="$( set -Eeuo pipefail
         handle "$BUS_DIR/requests/req-doesnotexist.json" >/dev/null 2>&1
         echo after )"
[ "$out2" = "after" ] \
    && pass "handle(): missing request file is a successful no-op" \
    || die  "handle(): missing request file returned non-zero (daemon would exit)"

# ── 4. An ERROR response is still retried (the no-op must not over-apply) ─────
# Guards the obvious wrong fix — returning 0 unconditionally — which would strand
# every transient failure instead of reprocessing it.
resp="$BUS_DIR/responses/resp-${SHORT}.json"
printf '{"pr":4,"sha":"%s","status":"error","findings":0}\n' "$SHORT" > "$resp"
rm -f "$BUS_DIR/requests/req-${SHORT}.json"
( write_auto_request 4 main "$HEAD_OID" ) >/dev/null 2>&1
[ -f "$BUS_DIR/requests/req-${SHORT}.json" ] \
    && pass "error response is still re-requested (no-op did not over-apply)" \
    || die  "error response was treated as terminal — transient failures would stall"

# ── 5. STRUCTURAL: no bare no-op returns anywhere in the watcher ─────────────
# Behavioural cases can only cover the branches someone thought to enumerate.
# Two rounds of this review found bare returns that a hand-built list had missed,
# so the durable guard is structural: every `return` in the daemon states its
# status. This catches the next one at the point it is written, in any function,
# without needing a fixture that reaches that branch.
#
# `return $rc`, `return 1` and similar are untouched — only a naked `return`,
# whose value is whatever the previous command happened to leave behind.
strays="$(grep -nE '^[[:space:]]*return[[:space:]]*$|\|\|[[:space:]]*return[[:space:]]*$' "$WATCHER" || true)"
if [ -z "$strays" ]; then
    pass "watcher contains no bare returns (every no-op states its status)"
else
    die "bare return(s) inherit the previous command's status:"
    printf '        %s\n' "$strays"
fi

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
