#!/usr/bin/env bash
# Reviewer-phase memory (S1).
#
# Once Codex signs off clean, commits that exist ONLY to address Copilot findings
# must not pull Codex back in: SKILL.md says those commits do not gate, but the
# watcher had no way to honour it, so every Copilot fix burned a review, consumed
# a round against the threshold, and fired a notification.
#
# The phase is keyed on a `Review-Phase: copilot` commit TRAILER, not on a commit
# subject prefix — subject-prefix counting already failed in this repository
# (CHANGELOG 1.0.10, where round-fix commits used module scopes and the count was
# permanently zero).
#
# FAIL-CLOSED DIRECTION: every uncertainty falls through to a REVIEW. A wrong
# hold means a commit is never reviewed; a wrong review costs one redundant pass.
#
# Self-contained: throwaway git repo + BUS_DIR under a temp dir. `gh` is stubbed
# from PATH. No network.

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
CLEAN_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
echo more > "$REPO_DIR/g.txt"
git -C "$REPO_DIR" add -A; git -C "$REPO_DIR" commit -qm next
HEAD_OID="$(git -C "$REPO_DIR" rev-parse HEAD)"

export REPO_DIR BUS_DIR="$TMP/bus" REVIEW_BUS_REMOTE="git@github.com:test/demo.git"
mkdir -p "$BUS_DIR/requests" "$BUS_DIR/responses" "$BUS_DIR/.codex-seen" "$BUS_DIR/.codex-logs"

# `gh` stub. Behaviour is driven by files the test writes, so each case is
# explicit rather than depending on argument order.
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
case " $* " in
    *compare/*)
        [ -f "$GH_COMPARE_FAIL" ] && exit 1
        cat "$GH_COMPARE_OUT"
        exit 0 ;;
    *"/reviews"*)
        printf '{"id": 4242}\n'
        exit 0 ;;
esac
printf '[]\n'
GH
chmod +x "$STUB/gh"
PATH="$STUB:$PATH"
export GH_COMPARE_OUT="$TMP/compare.json" GH_COMPARE_FAIL="$TMP/compare-fail"

# shellcheck disable=SC1090
source "$WATCHER"
set +e

# Helper: what does the gh compare stub return for a given set of messages?
# `--jq` is applied by the real gh; the stub ignores it, so the watcher must not
# depend on gh-side filtering. Emit the raw shape and let the watcher parse.
# $1 = compare status, $2 = total_commits GitHub reports, rest = commit messages.
# status and total_commits are load-bearing: a `diverged` range can still list
# fully tagged commits that the signoff does not cover, and a total_commits
# larger than the returned list means the 250-commit cap truncated it.
compare_full() {
    local status="$1" reported="$2"; shift 2
    local msgs=("$@") first=1
    { printf '{"status":"%s","total_commits":%s,"commits":[' "$status" "$reported"
      for m in "${msgs[@]}"; do
          [ "$first" -eq 1 ] || printf ','
          first=0
          jq -n --arg m "$m" '{commit:{message:$m}}' | tr -d '\n'
      done
      printf ']}\n'
    } > "$GH_COMPARE_OUT"
}

# The ordinary case: a clean fast-forward whose list is complete.
compare_with() {
    compare_full ahead "$#" "$@"
}

# ── 1. write_response carries next_phase only when given one ────────────────
resp="$TMP/r1.json"
write_response "$resp" 4 abc1234 approved 0 "clean" "/dev/null" copilot
[ "$(jq -r '.next_phase // "ABSENT"' "$resp")" = "copilot" ] \
    && pass "write_response: next_phase present when supplied" \
    || die "write_response: next_phase missing"

resp2="$TMP/r2.json"
write_response "$resp2" 4 abc1234 comments_posted 2 "findings" "/dev/null"
[ "$(jq -r '.next_phase // "ABSENT"' "$resp2")" = "ABSENT" ] \
    && pass "write_response: no next_phase key when not supplied (7-arg callers unchanged)" \
    || die "write_response: next_phase leaked into a 7-arg call"

# ── 2. record_clean_signoff stores the FULL sha ─────────────────────────────
rm -f "$BUS_DIR/.codex-clean-4"
record_clean_signoff 4 "$CLEAN_SHA"
[ "$(cat "$BUS_DIR/.codex-clean-4" 2>/dev/null)" = "$CLEAN_SHA" ] \
    && pass "record_clean_signoff: marker holds the full signoff sha" \
    || die "record_clean_signoff: marker missing or wrong"

# A marker that cannot be written must NOT abort the review — the safe direction
# is to lose the memory and re-review, never to fail the pass.
chmod 500 "$BUS_DIR"
record_clean_signoff 5 "$CLEAN_SHA" >/dev/null 2>&1
rc=$?
chmod 700 "$BUS_DIR"
[ "$rc" -eq 0 ] \
    && pass "record_clean_signoff: unwritable bus dir is non-fatal (returns 0)" \
    || die "record_clean_signoff: returned $rc — a failed marker must not fail the review"

# ── 3. Phase hold: every commit since the signoff carries the trailer ───────
enqueue() {
    rm -f "$BUS_DIR/requests/req-${HEAD_OID:0:7}.json"
    ( write_auto_request 4 main "$HEAD_OID" ) >"$TMP/out.txt" 2>&1
}
requested() { [ -f "$BUS_DIR/requests/req-${HEAD_OID:0:7}.json" ]; }

printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
rm -f "$GH_COMPARE_FAIL"
compare_with "fix(review): address Copilot finding

Review-Phase: copilot" "fix(review): second Copilot fix

Review-Phase: copilot"
enqueue
if ! requested && grep -q 'reason=copilot_phase' "$TMP/out.txt"; then
    pass "all-trailer range => held, no request written"
else
    die "copilot-phase range was reviewed anyway (out: $(tr '\n' ' ' < "$TMP/out.txt"))"
fi
[ -f "$BUS_DIR/.codex-clean-4" ] \
    && pass "hold keeps the marker (phase continues across several Copilot fixes)" \
    || die "hold deleted the marker"

# ── 4. Any untagged commit invalidates the phase ────────────────────────────
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_with "fix(review): a Copilot fix

Review-Phase: copilot" "feat: unrelated new work"
enqueue
if requested; then
    pass "untagged commit => phase invalidated, review enqueued"
else
    die "untagged commit was held (a real change would never be reviewed)"
fi
[ ! -f "$BUS_DIR/.codex-clean-4" ] \
    && pass "invalidation removes the marker" \
    || die "marker survived invalidation"

# ── 5. A trailer-shaped string in prose must not count ──────────────────────
# Guards the sloppy implementation that greps the whole message for the phrase.
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_with "docs: explain that Review-Phase: copilot marks Copilot fixes"
enqueue
requested \
    && pass "trailer mentioned mid-sentence does not count as a trailer" \
    || die "prose containing the trailer text was treated as a tagged commit"

# ── 6. compare failure falls through to a REVIEW ────────────────────────────
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_with "fix(review): a Copilot fix

Review-Phase: copilot"
: > "$GH_COMPARE_FAIL"
enqueue
rm -f "$GH_COMPARE_FAIL"
requested \
    && pass "compare failure => reviews (fails closed toward reviewing)" \
    || die "a failed compare caused a HOLD — a commit would never be reviewed"

# ── 7. No marker => untouched behaviour ─────────────────────────────────────
rm -f "$BUS_DIR/.codex-clean-4"
enqueue
requested \
    && pass "no marker => normal auto-enqueue" \
    || die "auto-enqueue broke when no clean marker exists"


# ── 8. A DIVERGED range must not hold, however well tagged ─────────────────
# After a force-push the compare can report every commit as tagged while none of
# them is reachable from the signed-off SHA - so the signoff does not cover this
# head and Codex must look at it.
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_full diverged 2 "fix(review): a

Review-Phase: copilot" "fix(review): b

Review-Phase: copilot"
enqueue
requested \
    && pass "diverged range => reviewed (signoff does not cover this head)" \
    || die "a diverged range was held on the strength of its trailers"

# ── 9. A TRUNCATED range must not hold ────────────────────────────────────
# The unpaginated compare list is capped at 250. If GitHub reports more commits
# than it returned, an untagged commit may sit beyond the cap, invisible to the
# count.
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_full ahead 300 "fix(review): only one listed

Review-Phase: copilot"
enqueue
requested \
    && pass "truncated range (total_commits > listed) => reviewed" \
    || die "a truncated compare was held on a partial commit list"

# ── 10. Marker removal failure must not kill the watcher ──────────────────
# The cleanup runs under production strict mode. An unguarded failure would exit
# write_auto_request, and its unguarded caller would take the daemon down -
# restarting into the same failure instead of falling through to a review.
# NOTE: run under `set -Eeuo pipefail` explicitly; the assertions above run with
# -e disabled, so they could not catch this.
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_with "feat: untagged work"          # invalidates -> takes the rm path
chmod 500 "$BUS_DIR"                        # make the unlink fail
rm -f "$BUS_DIR/requests/req-${HEAD_OID:0:7}.json" 2>/dev/null
out_strict="$( set -Eeuo pipefail
               write_auto_request 4 main "$HEAD_OID" >/dev/null 2>&1
               echo survived )"
chmod 700 "$BUS_DIR"
[ "$out_strict" = "survived" ] \
    && pass "marker removal failure is non-fatal under set -e (daemon survives)" \
    || die "unguarded rm killed write_auto_request under strict mode"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
