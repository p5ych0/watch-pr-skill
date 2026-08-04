#!/usr/bin/env bash
# Unit tests for review-bus-copilot.sh, using a stubbed `gh` on PATH.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/review-bus-copilot.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# ---- fake gh -------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# Fake gh for review-bus-copilot tests. Reads canned responses from env:
#   GH_REVIEWS          file: JSON array for  api repos/*/pulls/*/reviews
#   GH_REVIEW_COMMENTS  file: JSON array for  api repos/*/pulls/*/reviews/*/comments
#   GH_HEAD             string: headRefOid for pr view --json headRefOid --jq
#   GH_SEARCH           file: JSON array for  search prs (unset => exit 1 = error)
#   GH_EDIT_RC          int:  exit code for   pr edit
case "$1 ${2:-}" in
  "api "*)
    case "$*" in
      *"/reviews/"*"/comments"*)
        [ -n "${GH_COMMENTS_RC:-}" ] && exit "$GH_COMMENTS_RC"
        args="$*"; rid="${args##*/reviews/}"; rid="${rid%%/comments*}"
        if [ -n "${GH_FIXTURE_DIR:-}" ] && [ -f "$GH_FIXTURE_DIR/comments-$rid.json" ]; then
          cat "$GH_FIXTURE_DIR/comments-$rid.json"
        else cat "${GH_REVIEW_COMMENTS:-/dev/null}"; fi ;;
      *"/reviews"*)              [ -n "${GH_REVIEWS_RC:-}" ] && exit "$GH_REVIEWS_RC"; cat "${GH_REVIEWS:-/dev/null}" ;;
      *) printf '{}' ;;
    esac ;;
  "pr view"*)    printf '%s' "${GH_HEAD:-}" ;;
  "pr edit"*)    [ -n "${GH_EDIT_STDERR:-}" ] && printf '%s\n' "$GH_EDIT_STDERR" >&2; exit "${GH_EDIT_RC:-0}" ;;
  "search prs"*) if [ -n "${GH_SEARCH:-}" ]; then cat "$GH_SEARCH"; else exit 1; fi ;;
  *) printf '{}' ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_FIXTURE_DIR="$TMP"   # lets the fake gh return per-review-id comment fixtures

run_copilot() { REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" "$@"; }

# ---- Task 1: scaffold ----------------------------------------------------
# Identity derives from a fake origin, repo-agnostic, no side effects on source.
out="$(REVIEW_BUS_LIB_ONLY=1 REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        bash -c 'source "$1"; echo "$OWNER/$REPO :: $COPILOT_BOT"' _ "$SCRIPT" 2>&1)"
[ "$out" = "acme/widget :: copilot-pull-request-reviewer[bot]" ] \
  && pass "identity derived from origin; no side effects on source" \
  || die "scaffold identity/source-guard wrong (got: $out)"

# ---- Task 2: available ---------------------------------------------------
# (a) bot already reviewed THIS PR → available (0)
printf '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"deadbeef","id":1}]' > "$TMP/reviews.json"
GH_REVIEWS="$TMP/reviews.json" run_copilot available 7 >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "available: prior review on this PR => 0" || die "available (a) not 0"

# (b) no PR review, but repo search finds a Copilot-reviewed PR → available (0)
printf '[]' > "$TMP/empty.json"; printf '[{"number":5}]' > "$TMP/search.json"
GH_REVIEWS="$TMP/empty.json" GH_SEARCH="$TMP/search.json" run_copilot available 7 >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "available: repo search hit => 0" || die "available (b) not 0"

# (c) no PR review, search returns empty → unknown/ASK (2) — empty ≠ unavailable
printf '[]' > "$TMP/search-empty.json"
GH_REVIEWS="$TMP/empty.json" GH_SEARCH="$TMP/search-empty.json" run_copilot available 7 >/dev/null 2>&1
[ "$?" -eq 2 ] && pass "available: empty search => 2 (ask; empty != unavailable)" || die "available (c) not 2"

# (d) no PR review, search ERRORS (GH_SEARCH unset ⇒ fake gh exits 1) → unknown (2)
GH_REVIEWS="$TMP/empty.json" run_copilot available 7 >/dev/null 2>&1
[ "$?" -eq 2 ] && pass "available: search error => 2 (unknown)" || die "available (d) not 2"

# ---- Task 3: request -----------------------------------------------------
HEAD40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# (a) no prior review → add-reviewer succeeds → requested (0)
GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" GH_EDIT_RC=0 run_copilot request 7 >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "request: fresh => 0 (requested)" || die "request (a) not 0"

# (b) bot already reviewed the CURRENT head → already-reviewed-head (4)
printf '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"%s","id":9,"state":"COMMENTED","submitted_at":"2026-07-18T10:00:00Z"}]' "$HEAD40" > "$TMP/rev-head.json"
GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-head.json" GH_EDIT_RC=0 run_copilot request 7 >/dev/null 2>&1
[ "$?" -eq 4 ] && pass "request: already reviewed head => 4" || die "request (b) not 4"

# (c) bot reviewed an OLDER head → re-request path → requested (0)
printf '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"0000000000000000000000000000000000000000","id":9,"state":"COMMENTED","submitted_at":"2026-07-18T09:00:00Z"}]' > "$TMP/rev-old.json"
GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-old.json" GH_EDIT_RC=0 run_copilot request 7 >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "request: older-head review => 0 (re-request)" || die "request (c) not 0"

# (d1) add-reviewer fails with a POSITIVELY-unavailable signature → 3
GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" GH_EDIT_RC=1 \
  GH_EDIT_STDERR="422 Reviews may only be requested from collaborators. copilot is not a collaborator" \
  run_copilot request 7 >/dev/null 2>&1
[ "$?" -eq 3 ] && pass "request: unavailable signature => 3 (positively unavailable)" || die "request (d1) not 3"

# (d2) add-reviewer fails transiently (no unavailable signature) → 2 (fail closed, NOT skip)
GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" GH_EDIT_RC=1 \
  GH_EDIT_STDERR="HTTP 502 Bad Gateway" \
  run_copilot request 7 >/dev/null 2>&1
[ "$?" -eq 2 ] && pass "request: transient failure => 2 (fail closed, not silent skip)" || die "request (d2) not 2"

# ---- Task 4: poll --------------------------------------------------------
# (a) review present on head → emit findings count + status=commented (0)
printf '[{"id":123},{"id":124}]' > "$TMP/comments.json"   # 2 inline findings
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-head.json" GH_REVIEW_COMMENTS="$TMP/comments.json" \
       CODEX_REVIEW_COPILOT_POLL_SECONDS=1 CODEX_REVIEW_COPILOT_TIMEOUT=1 run_copilot poll 7 2>&1)"
rc=$?
echo "$out" | grep -qx 'COPILOT_REVIEW pr=7 sha=aaaaaaa findings=2 status=commented reviewer=copilot' \
  && [ "$rc" -eq 0 ] && pass "poll: review on head => COPILOT_REVIEW findings=2 (0)" \
  || die "poll (a) wrong (rc=$rc out='$out')"

# (b) no review on head within timeout → status=timeout (1)
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" \
       CODEX_REVIEW_COPILOT_POLL_SECONDS=1 CODEX_REVIEW_COPILOT_TIMEOUT=1 run_copilot poll 7 2>&1)"
rc=$?
echo "$out" | grep -qx 'COPILOT_REVIEW pr=7 sha=aaaaaaa findings=0 status=timeout reviewer=copilot' \
  && [ "$rc" -eq 1 ] && pass "poll: no review => status=timeout (1)" \
  || die "poll (b) wrong (rc=$rc out='$out')"

# ---- Task 8 (review fixes): status (head-aware) + fail-closed --------------
# (a) review on the CURRENT head → status=commented + findings (0)
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-head.json" GH_REVIEW_COMMENTS="$TMP/comments.json" run_copilot status 7 2>&1)"; rc=$?
echo "$out" | grep -qx 'COPILOT_REVIEW pr=7 sha=aaaaaaa findings=2 status=commented reviewer=copilot' \
  && [ "$rc" -eq 0 ] && pass "status: review on head => commented findings=2 (0)" \
  || die "status (a) wrong (rc=$rc out='$out')"

# (b) review only on an OLDER head → status=none (1) — the stale-review gate case
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-old.json" run_copilot status 7 2>&1)"; rc=$?
echo "$out" | grep -qx 'COPILOT_REVIEW pr=7 sha=aaaaaaa findings=0 status=none reviewer=copilot' \
  && [ "$rc" -eq 1 ] && pass "status: only older-head review => none (1) [stale guard]" \
  || die "status (b) wrong (rc=$rc out='$out')"

# (c) no reviews → status=none (1)
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" run_copilot status 7 2>&1)"; rc=$?
echo "$out" | grep -qx 'COPILOT_REVIEW pr=7 sha=aaaaaaa findings=0 status=none reviewer=copilot' \
  && [ "$rc" -eq 1 ] && pass "status: no reviews => none (1)" \
  || die "status (c) wrong (rc=$rc out='$out')"

# (d) review on head but comments FETCH FAILS → status=error (2), fail closed
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-head.json" GH_COMMENTS_RC=1 run_copilot status 7 2>&1)"; rc=$?
echo "$out" | grep -qx 'COPILOT_REVIEW pr=7 sha=aaaaaaa findings=0 status=error reviewer=copilot' \
  && [ "$rc" -eq 2 ] && pass "status: comments fetch fails => error (2, fail closed)" \
  || die "status (d) wrong (rc=$rc out='$out')"

# (e) poll: review on head but comments fetch fails → status=error (2), not a clean 0
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-head.json" GH_COMMENTS_RC=1 \
       CODEX_REVIEW_COPILOT_POLL_SECONDS=1 CODEX_REVIEW_COPILOT_TIMEOUT=1 run_copilot poll 7 2>&1)"; rc=$?
echo "$out" | grep -qx 'COPILOT_REVIEW pr=7 sha=aaaaaaa findings=0 status=error reviewer=copilot' \
  && [ "$rc" -eq 2 ] && pass "poll: comments fetch fails => error (2, not false-clean)" \
  || die "poll (e) wrong (rc=$rc out='$out')"

# (f) status: REVIEWS-list endpoint fails → status=error (2), fail closed
out="$(GH_HEAD="$HEAD40" GH_REVIEWS_RC=1 run_copilot status 7 2>&1)"; rc=$?
echo "$out" | grep -qx 'COPILOT_REVIEW pr=7 sha=aaaaaaa findings=0 status=error reviewer=copilot' \
  && [ "$rc" -eq 2 ] && pass "status: reviews-list fetch fails => error (2, fail closed)" \
  || die "status (f) wrong (rc=$rc out='$out')"

# (g) poll: REVIEWS-list endpoint fails → status=error (2), NOT timeout/false-clean
out="$(GH_HEAD="$HEAD40" GH_REVIEWS_RC=1 \
       CODEX_REVIEW_COPILOT_POLL_SECONDS=1 CODEX_REVIEW_COPILOT_TIMEOUT=1 run_copilot poll 7 2>&1)"; rc=$?
echo "$out" | grep -qx 'COPILOT_REVIEW pr=7 sha=aaaaaaa findings=0 status=error reviewer=copilot' \
  && [ "$rc" -eq 2 ] && pass "poll: reviews-list fetch fails => error (2, not timeout)" \
  || die "poll (g) wrong (rc=$rc out='$out')"

# ---- Task 9 (review fixes): head-resolution failure fails closed ----------
# A transient head lookup (empty GH_HEAD) must NOT read as timeout/none/unavailable.
# (h) request: head unresolved → error (2)
out="$(GH_HEAD="" run_copilot request 7 2>&1)"; rc=$?
echo "$out" | grep -q 'COPILOT_REQUEST pr=7 status=error detail=head_unresolved' \
  && [ "$rc" -eq 2 ] && pass "request: head unresolved => error (2, fail closed)" \
  || die "request (h) wrong (rc=$rc out='$out')"

# (i) status: head unresolved → status=error (2)
out="$(GH_HEAD="" run_copilot status 7 2>&1)"; rc=$?
echo "$out" | grep -qx 'COPILOT_REVIEW pr=7 sha=unknown findings=0 status=error reviewer=copilot' \
  && [ "$rc" -eq 2 ] && pass "status: head unresolved => error (2, fail closed)" \
  || die "status (i) wrong (rc=$rc out='$out')"

# (j) poll: head unresolved → status=error (2), not timeout
out="$(GH_HEAD="" run_copilot poll 7 2>&1)"; rc=$?
echo "$out" | grep -qx 'COPILOT_REVIEW pr=7 sha=unknown findings=0 status=error reviewer=copilot' \
  && [ "$rc" -eq 2 ] && pass "poll: head unresolved => error (2, not timeout)" \
  || die "poll (j) wrong (rc=$rc out='$out')"

# ---- Task 10 (review fixes): only latest SUBMITTED head review counts -------
# (k) only a PENDING current-head review → status=none (1), NOT a false findings=0
printf '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"%s","id":50,"state":"PENDING","submitted_at":null}]' "$HEAD40" > "$TMP/rev-pending.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-pending.json" run_copilot status 7 2>&1)"; rc=$?
echo "$out" | grep -qx 'COPILOT_REVIEW pr=7 sha=aaaaaaa findings=0 status=none reviewer=copilot' \
  && [ "$rc" -eq 1 ] && pass "status: pending-only head review => none (1), not false clean" \
  || die "status (k) wrong (rc=$rc out='$out')"

# (l) two SUBMITTED reviews on the same head → count the LATEST by submitted_at
printf '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"%s","id":60,"state":"COMMENTED","submitted_at":"2026-07-18T08:00:00Z"},{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"%s","id":61,"state":"COMMENTED","submitted_at":"2026-07-18T12:00:00Z"}]' "$HEAD40" "$HEAD40" > "$TMP/rev-two.json"
printf '[{"id":1}]' > "$TMP/comments-60.json"                      # older review: 1 finding
printf '[{"id":1},{"id":2},{"id":3}]' > "$TMP/comments-61.json"    # latest review: 3 findings
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-two.json" run_copilot status 7 2>&1)"; rc=$?
echo "$out" | grep -qx 'COPILOT_REVIEW pr=7 sha=aaaaaaa findings=3 status=commented reviewer=copilot' \
  && [ "$rc" -eq 0 ] && pass "status: two same-head reviews => count the latest (findings=3)" \
  || die "status (l) wrong (rc=$rc out='$out')"

# ---- gate / decline ------------------------------------------------------
# The gate is what makes skipping Copilot an explicit act. Without it the pass
# lives only as SKILL.md prose, and a session can reach merge having never asked
# — which is what happened repeatedly in a downstream repo.
GATE_BUS="$TMP/gatebus"; mkdir -p "$GATE_BUS"
run_gate() { BUS_DIR="$GATE_BUS" REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" "$@"; }

# (n) no Copilot review on this head => pass still owed (1)
printf '[]' > "$TMP/rev-none.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-none.json" run_gate gate 7 2>&1)"; rc=$?
echo "$out" | grep -q 'status=none' && [ "$rc" -eq 1 ] \
  && pass "gate: no review for the head => 1 (pass owed)" || die "gate (n) wrong (rc=$rc out='$out')"

# (o) clean review on this head => may merge (0)
printf '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"%s","id":70,"state":"COMMENTED","submitted_at":"2026-07-18T08:00:00Z"}]' "$HEAD40" > "$TMP/rev-clean.json"
printf '[]' > "$TMP/comments-70.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-clean.json" run_gate gate 7 2>&1)"; rc=$?
echo "$out" | grep -q 'status=clean' && [ "$rc" -eq 0 ] \
  && pass "gate: clean review on the head => 0" || die "gate (o) wrong (rc=$rc out='$out')"

# (p) review WITH findings => still owed (1), never a silent pass
printf '[{"id":1},{"id":2}]' > "$TMP/comments-70.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-clean.json" run_gate gate 7 2>&1)"; rc=$?
echo "$out" | grep -q 'status=findings findings=2' && [ "$rc" -eq 1 ] \
  && pass "gate: findings on the head => 1" || die "gate (p) wrong (rc=$rc out='$out')"

# (q) fetch failure => 2, so the caller fails closed rather than merging
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-clean.json" GH_COMMENTS_RC=1 run_gate gate 7 2>&1)"; rc=$?
echo "$out" | grep -q 'status=error' && [ "$rc" -eq 2 ] \
  && pass "gate: comment fetch failure => 2 (fail closed)" || die "gate (q) wrong (rc=$rc out='$out')"

# (r) head lookup failure => 2, never "no review therefore fine"
out="$(GH_HEAD="" GH_REVIEWS="$TMP/rev-none.json" run_gate gate 7 2>&1)"; rc=$?
echo "$out" | grep -q 'reason=head_lookup_failed' && [ "$rc" -eq 2 ] \
  && pass "gate: head lookup failure => 2 (fail closed)" || die "gate (r) wrong (rc=$rc out='$out')"

# (s) decline records the head and the gate then allows the merge
out="$(GH_HEAD="$HEAD40" run_gate decline 7 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$GATE_BUS/.copilot-declined-7")" = "$HEAD40" ] \
  && pass "decline: records the current head" || die "decline wrong (rc=$rc out='$out')"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/rev-none.json" run_gate gate 7 2>&1)"; rc=$?
echo "$out" | grep -q 'status=declined' && [ "$rc" -eq 0 ] \
  && pass "gate: recorded decline for this head => 0" || die "gate (s) wrong (rc=$rc out='$out')"

# (t) a push after the decline re-opens the question — the waiver must NOT
# carry over to code the operator never saw.
OTHER40="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
out="$(GH_HEAD="$OTHER40" GH_REVIEWS="$TMP/rev-none.json" run_gate gate 7 2>&1)"; rc=$?
echo "$out" | grep -q 'status=decline_stale' && [ "$rc" -eq 1 ] \
  && pass "gate: decline does not carry past the head it was made for" \
  || die "gate (t) STALE DECLINE ACCEPTED (rc=$rc out='$out')"


# (u) request rc 3 (positively unavailable) must leave the gate a way through.
# Previously the documented flow was unreachable: the skill says to merge on the
# Codex signoff when Copilot is positively unavailable, but with no review and no
# decline the gate returned 1 and the merge always aborted.
UNAVAIL_BUS="$TMP/unavailbus"; mkdir -p "$UNAVAIL_BUS"
run_unavail() { BUS_DIR="$UNAVAIL_BUS" REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" "$@"; }

GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" GH_EDIT_RC=1 \
  GH_EDIT_STDERR="422 Reviews may only be requested from collaborators. copilot is not a collaborator" \
  run_unavail request 7 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 3 ] && pass "request: unavailable still returns 3" || die "request rc changed (got $rc)"
[ "$(cat "$UNAVAIL_BUS/.copilot-unavailable-7" 2>/dev/null)" = "$HEAD40" ] \
  && pass "request: records unavailability head-scoped" || die "request: no unavailable marker written"

out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" run_unavail gate 7 2>&1)"; rc=$?
echo "$out" | grep -q 'status=unavailable' && [ "$rc" -eq 0 ] \
  && pass "gate: recorded unavailability for this head => 0 (rc 3 path reaches merge)" \
  || die "gate: unavailable path still blocks (rc=$rc out='$out')"

# A later push re-opens the question - availability was recorded for one head.
out="$(GH_HEAD="$OTHER40" GH_REVIEWS="$TMP/empty.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 1 ] \
  && pass "gate: unavailability does not carry past the head it was recorded for" \
  || die "gate: stale unavailable marker accepted (rc=$rc)"

# (m) The instructions shipped to Copilot must match the counting proved above.
# Case (l) shows every INLINE comment on the latest review is counted, and any
# non-zero count sends the PR through the merge-blocking fix loop — so telling
# Copilot to "raise a non-blocking note" without naming a channel makes it
# manufacture blockers. The only uncounted channel is the overall review body.
# Skipped when the doc is absent (the scripts are also vendored without it).
DOC="$SELF_DIR/../../../.github/copilot-instructions.md"
if [ -f "$DOC" ]; then
    grep -qi 'never file a non-blocking observation as an inline comment' "$DOC" \
      && pass "copilot doc: forbids filing observations inline" \
      || die "copilot doc does not forbid inline non-blocking observations"
    grep -qi 'overall review body' "$DOC" \
      && pass "copilot doc: names the uncounted review-body channel" \
      || die "copilot doc does not name the review-body channel"
else
    pass "copilot doc not present (vendored scripts); routing assertions skipped"
fi

# ---- final ---------------------------------------------------------------
if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
