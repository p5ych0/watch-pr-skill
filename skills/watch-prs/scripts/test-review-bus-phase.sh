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


# ── 11. A partially-parsed compare must not authorise a hold ──────────────
# Valid JSON followed by trailing garbage: jq emits the values and THEN exits
# non-zero. With four separate `jq ... || echo ""` substitutions the fallback
# appended only a blank line, which $( ) strips - so the checks ran on data from
# a failed parse. One guarded jq discards everything when the parse fails.
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
printf '{"status":"ahead","total_commits":1,"commits":[{"commit":{"message":"x\n\nReview-Phase: copilot"}}]} TRAILING-GARBAGE\n' > "$GH_COMPARE_OUT"
enqueue
requested \
    && pass "compare with trailing garbage => reviewed (partial parse is not evidence)" \
    || die "a partially-parsed compare authorised a hold"

# ── 12. A marker-shaped BODY line is not a git trailer ────────────────────
# git looks for trailers in the FINAL block. "subject / Review-Phase: copilot /
# ordinary body" has no trailer, so holding on it would suppress Codex for an
# untagged commit - the unsafe direction this feature exists to prevent.
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_with "subject line

Review-Phase: copilot

ordinary body paragraph"
enqueue
requested \
    && pass "marker-shaped body line (not a trailer) => reviewed" \
    || die "a body line was treated as a Review-Phase trailer"

# The real footer form must still hold.
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_with "fix(review): a real one

Review-Phase: copilot"
enqueue
{ ! requested; } \
    && pass "genuine trailer in the final block still holds" \
    || die "a genuine trailer stopped holding (over-strict)"

# ── 13. A malformed clean marker must not authorise a hold ────────────────
# `tr -cd` would REPAIR this into a valid-looking SHA.
printf 'x%sx\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_with "fix(review): tagged

Review-Phase: copilot"
enqueue
requested \
    && pass "malformed clean marker => reviewed (not repaired into a hold)" \
    || die "a malformed marker was sanitised into a valid hold"


# ── 14. A trailer-shaped line in a MIXED final paragraph is not a trailer ──
# git reports no trailer for "subject / ordinary body / Review-Phase: copilot" -
# the block is not all trailers - yet a last-paragraph regex matched it, holding
# on an untagged commit. Classification now uses git interpret-trailers --parse.
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_with "subject

ordinary body
Review-Phase: copilot"
enqueue
requested \
    && pass "trailer line in a mixed final paragraph => reviewed (git says no trailer)" \
    || die "a mixed final paragraph was treated as carrying a trailer"

# ── 15. A marker with trailing junk must not authorise a hold ─────────────
# Reading only the first line accepted `<valid-sha>\njunk`, defeating the exact
# contents contract the marker is supposed to enforce.
printf '%s\njunk\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_with "fix(review): tagged

Review-Phase: copilot"
enqueue
requested \
    && pass "multiline-corrupted clean marker => reviewed" \
    || die "a marker with trailing junk authorised a hold"


# ── 16. A malformed `.commits` must not be read as a tagged range ───────────
# Validating only the TOP-LEVEL object left the fields it reads unchecked: an
# OBJECT-shaped `.commits` still answers `length` and still iterates under
# `.commits[]`, so status=ahead + total_commits=1 + one trailer-bearing value
# produced tagged=1 and took CODEX_AUTO_SKIP - suppressing Codex on a payload
# whose shape proves nothing about the range.
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
cat > "$GH_COMPARE_OUT" <<'JSON'
{"status":"ahead","total_commits":1,"commits":{"a":{"commit":{"message":"fix(review): tagged\n\nReview-Phase: copilot"}}}}
JSON
enqueue
requested \
    && pass "object-shaped .commits => reviewed (shape proves nothing)" \
    || die "an object-shaped .commits authorised a phase hold"

# The same for the individual fields the parse reads back.
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
cat > "$GH_COMPARE_OUT" <<'JSON'
{"status":"ahead","total_commits":"1","commits":[{"commit":{"message":"fix(review): tagged\n\nReview-Phase: copilot"}}]}
JSON
enqueue
requested \
    && pass "string total_commits => reviewed" \
    || die "a non-numeric total_commits was accepted"

printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
cat > "$GH_COMPARE_OUT" <<'JSON'
{"status":"ahead","total_commits":1,"commits":[{"commit":{"message":["fix(review): tagged","Review-Phase: copilot"]}}]}
JSON
enqueue
requested \
    && pass "non-string commit message => reviewed" \
    || die "a non-string commit message was accepted"


# ── 17. `identical` with commits is a contradiction, not a hold ─────────────
# This block is reached only when clean_sha != head_oid, and the hold also
# requires total > 0 - so a truthful compare of two different commits cannot say
# `identical`. Accepting it let a malformed payload suppress Codex.
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_full identical 1 "fix(review): tagged

Review-Phase: copilot"
enqueue
requested \
    && pass "identical + one tagged commit => reviewed (contradictory tuple)" \
    || die "an identical-with-commits payload authorised a phase hold"

# `ahead` with the same shape still holds - the fix narrows the accepted status,
# it does not break the real case.
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_with "fix(review): tagged

Review-Phase: copilot"
enqueue
requested \
    && die "the ordinary ahead+tagged hold stopped working" \
    || pass "ahead + fully tagged still holds"


# ── 18. A NUL byte in the clean marker must not authorise a hold ───────────
# Command substitution silently DROPS NUL, so `<valid-sha>\0` reached the regex
# as a clean 40-character SHA - and a fully tagged compare then emitted
# CODEX_AUTO_SKIP off a corrupt marker, with no review request written at all.
printf '%s\0' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_with "fix(review): tagged

Review-Phase: copilot"
enqueue
requested \
    && pass "NUL-corrupted clean marker => reviewed" \
    || die "a NUL-corrupted marker authorised a phase hold"

# The well-formed marker must still hold - the byte check rejects corruption,
# not the ordinary trailing newline record_clean_signoff writes.
printf '%s\n' "$CLEAN_SHA" > "$BUS_DIR/.codex-clean-4"
compare_with "fix(review): tagged

Review-Phase: copilot"
enqueue
requested \
    && die "the byte-level marker check broke the ordinary hold" \
    || pass "a well-formed marker still holds (trailing newline accepted)"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
