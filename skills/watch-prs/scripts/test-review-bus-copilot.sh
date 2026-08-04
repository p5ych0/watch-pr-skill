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
#   GH_HEAD_RC          int:  exit code for   pr view (stdout is still emitted)
#   GH_PENDING          string: a requested reviewer login (empty => none)
#   GH_PENDING_RAW      string: verbatim body for the reviewRequests read
#   GH_PENDING_RC       int:  exit code for that read
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
  "pr view"*)
    # reviewRequests is a separate query from headRefOid; GH_PENDING lists the
    # requested reviewers (empty/unset => none), GH_PENDING_RC faults the read.
    case "$*" in
      *reviewRequests*)
        [ -n "${GH_PENDING_RC:-}" ] && exit "$GH_PENDING_RC"
        # GH_PENDING_RAW injects a body verbatim (malformed-shape cases);
        # otherwise GH_PENDING is a login to list, empty meaning none requested.
        if [ -n "${GH_PENDING_RAW+x}" ]; then printf '%s' "$GH_PENDING_RAW"
        elif [ -n "${GH_PENDING:-}" ]; then printf '{"reviewRequests":[{"login":"%s"}]}' "$GH_PENDING"
        else printf '{"reviewRequests":[]}'
        fi ;;
      *)                printf '%s' "${GH_HEAD:-}"; exit "${GH_HEAD_RC:-0}" ;;
    esac ;;
  "pr edit"*)    [ -n "${GH_EDIT_STDERR:-}" ] && printf '%s\n' "$GH_EDIT_STDERR" >&2; exit "${GH_EDIT_RC:-0}" ;;
  "search prs"*) if [ -n "${GH_SEARCH:-}" ]; then cat "$GH_SEARCH"; else exit 1; fi ;;
  *) printf '{}' ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_FIXTURE_DIR="$TMP"   # lets the fake gh return per-review-id comment fixtures

# EVERY invocation gets a bus under $TMP. `request` is stateful - it records an
# unavailability marker - and the default bus path is derived from the fake
# origin, so an un-overridden call wrote /tmp/acme-widget-review-bus/... : state
# that outlived the trap and could be read by the next run of this suite, or by a
# concurrent one. The later blocks still point BUS_DIR at their own directories;
# this is the floor, not a replacement for them.
DEFAULT_BUS="$TMP/defaultbus"; mkdir -p "$DEFAULT_BUS"
run_copilot() { BUS_DIR="$DEFAULT_BUS" REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" "$@"; }

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


# (v) A malformed marker must not satisfy the gate. `tr -cd` would have repaired
# `x<40-hex>x` into a valid-looking SHA, so corrupt state could authorise a merge
# with no decline and no unavailability ever recorded.
printf 'x%sx\n' "$HEAD40" > "$UNAVAIL_BUS/.copilot-unavailable-7"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "gate: malformed unavailable marker is not repaired into a pass" \
  || die "gate: malformed unavailable marker accepted (rc=$rc out='$out')"

printf 'x%sx\n' "$HEAD40" > "$UNAVAIL_BUS/.copilot-declined-7"
rm -f "$UNAVAIL_BUS/.copilot-unavailable-7"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "gate: malformed decline marker is not repaired into a pass" \
  || die "gate: malformed decline marker accepted (rc=$rc out='$out')"
rm -f "$UNAVAIL_BUS/.copilot-declined-7"


# (w) A marker with trailing junk must not satisfy the gate. Reading only the
# first line accepted `<valid-sha>\njunk`, so a partially-overwritten or
# concatenated marker still looked like an exact head match and carried the
# merge. The marker's contract is its EXACT contents, not its first line.
for m in unavailable declined clean; do
    rm -f "$UNAVAIL_BUS"/.copilot-{unavailable,declined,clean}-7
    printf '%s\njunk\n' "$HEAD40" > "$UNAVAIL_BUS/.copilot-$m-7"
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" run_unavail gate 7 2>&1)"; rc=$?
    [ "$rc" -eq 1 ] \
      && pass "gate: multiline-corrupted $m marker is rejected" \
      || die "gate: multiline $m marker accepted (rc=$rc out='$out')"
done
rm -f "$UNAVAIL_BUS"/.copilot-{unavailable,declined,clean}-7

# (x) `gh pr view` that PRINTS a plausible SHA and THEN exits non-zero must be
# treated as a failure. `pr_head_oid` masked the status with `|| true`, keeping
# the stdout emitted before the error - so a failed lookup was indistinguishable
# from success, and with a matching marker the gate returned 0 (merge) instead of
# its documented fail-closed 2.
printf '%s\n' "$HEAD40" > "$UNAVAIL_BUS/.copilot-unavailable-7"
out="$(GH_HEAD="$HEAD40" GH_HEAD_RC=1 GH_REVIEWS="$TMP/empty.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  && pass "gate: head lookup that prints then fails => 2 (fail closed)" \
  || die "gate: stdout-plus-failure head lookup treated as success (rc=$rc out='$out')"
out="$(GH_HEAD="$HEAD40" GH_HEAD_RC=1 GH_REVIEWS="$TMP/empty.json" GH_EDIT_RC=0 run_unavail request 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  && pass "request: head lookup that prints then fails => 2 (fail closed)" \
  || die "request: stdout-plus-failure head lookup treated as success (rc=$rc)"
# A truncated SHA on a successful call is equally not a head.
out="$(GH_HEAD="abc123" GH_REVIEWS="$TMP/empty.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  && pass "gate: non-40-hex head lookup => 2 (fail closed)" \
  || die "gate: malformed head accepted (rc=$rc out='$out')"

# (y) unavailable -> available transition. Copilot declining once is not a
# permanent state: when a later `request` on the SAME head succeeds, the recorded
# unavailability is now false. Leaving it let the gate short-circuit to
# `status=unavailable` and merge while the pass it had just requested was still
# running.
printf '%s\n' "$HEAD40" > "$UNAVAIL_BUS/.copilot-unavailable-7"
GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" GH_EDIT_RC=0 run_unavail request 7 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "request: rc3 -> rc0 retry on the same head succeeds" \
  || die "request: same-head retry after unavailability did not succeed (rc=$rc)"
[ ! -e "$UNAVAIL_BUS/.copilot-unavailable-7" ] \
  && pass "request: a successful request revokes the stale unavailable marker" \
  || die "request: stale unavailable marker survived a successful request"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 1 ] \
  && pass "gate: after the revocation the gate waits for the requested pass" \
  || die "gate: still merged on the revoked unavailability (rc=$rc out='$out')"

# (z) The rc 4 path (Copilot ALREADY reviewed the current head) is proof of
# availability too, and it returns BEFORE the `gh pr edit` that owned the
# revocation - so the stale marker survived, and the gate answered
# `status=unavailable` (merge) from it without ever reading that review's
# findings.
printf '%s\n' "$HEAD40" > "$UNAVAIL_BUS/.copilot-unavailable-7"
printf '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"%s","state":"COMMENTED","submitted_at":"2026-01-01T00:00:00Z","id":9}]' \
    "$HEAD40" > "$TMP/reviews-head.json"
GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-head.json" run_unavail request 7 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 4 ] && pass "request: already-reviewed current head still returns 4" \
  || die "request: already-reviewed-head rc changed (got $rc)"
[ ! -e "$UNAVAIL_BUS/.copilot-unavailable-7" ] \
  && pass "request: the already-reviewed-head path revokes the stale marker too" \
  || die "request: stale unavailable marker survived the rc 4 path"
# With the marker gone the gate must read the REVIEW, findings and all.
printf '[{"path":"a.sh","line":1,"body":"x"}]' > "$TMP/comments-9.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-head.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'findings=1' \
  && pass "gate: after revocation it reads the review's findings, not the marker" \
  || die "gate: did not fall through to the live review (rc=$rc out='$out')"
rm -f "$TMP/comments-9.json"

# (aa) A paginated page that is not an ARRAY must fail closed. `jq -s` slurps
# pages into an array of pages, and `.[][]` over an OBJECT iterates its values -
# so a `{}` page (a 200-with-error body, or a truncated write) made
# `[.[][]] | length` return 0 with status 0. A real current-head review plus one
# such page therefore reported findings=0 and the gate reported status=clean.
printf '{}' > "$TMP/comments-9.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-head.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'status=error' \
  && pass "gate: object-shaped comments page => 2 (no false clean signoff)" \
  || die "gate: malformed comments page read as zero findings (rc=$rc out='$out')"
printf '{"message":"Not Found"}' > "$TMP/reviews-bad.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-bad.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -ne 0 ] \
  && pass "gate: object-shaped reviews page never yields a clean signoff" \
  || die "gate: malformed reviews page produced a pass (out='$out')"
rm -f "$TMP/comments-9.json"

# (bb) `jq -s` turns empty or whitespace-only input into ZERO pages, and
# `any([]; ...)` is FALSE - so a comments command that exited 0 emitting no JSON
# passed the array guard and returned a count of 0, which the gate reads as a
# clean signoff. No pages is not "no comments"; it is a fetch that said nothing.
: > "$TMP/comments-9.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-head.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  && pass "gate: empty comments output => 2 (zero pages is not zero comments)" \
  || die "gate: empty comments output read as a clean signoff (rc=$rc out='$out')"
printf '   \n' > "$TMP/comments-9.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-head.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  && pass "gate: whitespace-only comments output => 2" \
  || die "gate: whitespace-only comments output accepted (rc=$rc out='$out')"
rm -f "$TMP/comments-9.json"
: > "$TMP/reviews-empty-out.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-empty-out.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -ne 0 ] \
  && pass "gate: empty reviews output never yields a pass" \
  || die "gate: empty reviews output produced a pass (out='$out')"

# (cc) A marker must never outrank a LIVE review on the current head. Copilot can
# reach a head without cmd_request ever running - it picks PRs up itself, a human
# re-requests, an automation does - so the marker is stale the moment a review
# lands, and the gate consulted it first.
printf '%s\n' "$HEAD40" > "$UNAVAIL_BUS/.copilot-unavailable-7"
printf '[{"path":"a.sh","line":1,"body":"x"}]' > "$TMP/comments-9.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-head.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'findings=1' \
  && pass "gate: a live review with findings overrides the unavailable marker" \
  || die "gate: the stale marker outranked a live review (rc=$rc out='$out')"
printf '%s\n' "$HEAD40" > "$UNAVAIL_BUS/.copilot-declined-7"
rm -f "$UNAVAIL_BUS/.copilot-unavailable-7"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-head.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 1 ] \
  && pass "gate: a live review with findings overrides the decline marker too" \
  || die "gate: the decline marker outranked a live review (rc=$rc out='$out')"
# And if the live state cannot be read at all, the marker does not rescue it.
rm -f "$TMP/comments-9.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-head.json" GH_COMMENTS_RC=1 run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  && pass "gate: unreadable live state blocks rather than falling back on a marker" \
  || die "gate: fell back on the marker when live state was unreadable (rc=$rc out='$out')"
rm -f "$UNAVAIL_BUS/.copilot-declined-7"

# (dd) Unavailability must not be recorded off a reviews fetch that FAILED - the
# marker asserts "Copilot has done nothing here" on a question we never got an
# answer to, and it short-circuits the gate.
rm -f "$UNAVAIL_BUS/.copilot-unavailable-7"
GH_HEAD="$HEAD40" GH_REVIEWS_RC=1 GH_EDIT_RC=1 \
  GH_EDIT_STDERR="422 Reviews may only be requested from collaborators. copilot is not a collaborator" \
  run_unavail request 7 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 3 ] && pass "request: unavailability still reported when the reviews fetch failed" \
  || die "request: rc changed on a failed reviews fetch (got $rc)"
[ ! -e "$UNAVAIL_BUS/.copilot-unavailable-7" ] \
  && pass "request: no marker recorded off an unreadable reviews fetch" \
  || die "request: recorded unavailability without being able to read the review state"

# (ee) Revocation must not read a FAILED probe as "nothing to revoke". `[ -e ]`
# is false both when the marker is absent and when BUS_DIR is unsearchable, so
# the guard reported success while the marker survived - and once access
# recovered, the gate honoured it as status=unavailable while the review it had
# just requested was still pending.
LOCK_BUS="$TMP/lockbus"; mkdir -p "$LOCK_BUS"
run_lock() { BUS_DIR="$LOCK_BUS" REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" "$@"; }
printf '%s\n' "$HEAD40" > "$LOCK_BUS/.copilot-unavailable-7"
chmod 000 "$LOCK_BUS"
if [ -r "$LOCK_BUS" ] && [ -x "$LOCK_BUS" ]; then
    chmod 755 "$LOCK_BUS"
    pass "revocation probe check skipped (this user can traverse mode-000 dirs)"
else
    GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" GH_EDIT_RC=0 run_lock request 7 >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 2 ] \
      && pass "request: an unsearchable bus fails closed instead of claiming success" \
      || die "request: reported success while the marker could not be revoked (rc=$rc)"
    chmod 755 "$LOCK_BUS"
    # Access recovered: the marker survived, so it must NOT now carry the gate.
    [ -e "$LOCK_BUS/.copilot-unavailable-7" ] \
      && pass "the marker did indeed survive (the scenario is real)" \
      || die "test setup wrong: the marker was removed after all"
    # The request SUCCEEDED (`gh pr edit` rc 0), so on a real GitHub Copilot is
    # now a requested reviewer - which is exactly the live fact that proves the
    # surviving marker stale.
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" \
           GH_PENDING="copilot-pull-request-reviewer[bot]" run_lock gate 7 2>&1)"; rc=$?
    { [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'stale_unavailable_request_pending'; } \
      && pass "a pending request overrides the surviving unavailable marker" \
      || die "the surviving marker satisfied the gate after recovery: rc=$rc out=$out"
    # And if the pending-request state cannot be read, the marker does not get
    # the benefit of the doubt.
    printf '%s\n' "$HEAD40" > "$LOCK_BUS/.copilot-unavailable-7"
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" GH_PENDING_RC=1 run_lock gate 7 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
      && pass "unreadable request state blocks rather than honouring the marker" \
      || die "gate honoured the marker with unreadable request state (rc=$rc out=$out)"
fi
rm -rf "$LOCK_BUS"

# (ff) A page of EMPTY review records is not "no review". `[{}]` passed the
# array-container check and produced [], which every caller reads as "no live
# review" - so with a matching marker the gate answered status=unavailable off a
# payload that told us nothing.
printf '%s\n' "$HEAD40" > "$UNAVAIL_BUS/.copilot-unavailable-7"
printf '[{}]' > "$TMP/reviews-empty-records.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-empty-records.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  && pass "gate: empty review records => 2 (marker gets no free pass)" \
  || die "gate: [{}] review records read as no-review (rc=$rc out='$out')"
# Records missing only the fields the callers read are equally unusable.
printf '[{"user":{"login":"copilot-pull-request-reviewer[bot]"}}]' > "$TMP/reviews-partial.json"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-partial.json" run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  && pass "gate: review record missing id/commit_id => 2" \
  || die "gate: partial review record accepted (rc=$rc out='$out')"

# (gg) The requested-reviewer probe must not turn unreadable data into
# "no pending request". A flattened string collapsed a missing field, a null, an
# object and a zero-output call into "", which returned 1 - handing the stale
# marker its merge permission.
for raw_case in '' 'null' '{}' '{"reviewRequests":null}' '{"reviewRequests":{}}' '{"reviewRequests":[{}]}' 'not json'; do
    out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" GH_PENDING_RAW="$raw_case" run_unavail gate 7 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
      && pass "gate: unreadable reviewRequests body '${raw_case:-<empty>}' => 2" \
      || die "gate: reviewRequests body '${raw_case:-<empty>}' accepted (rc=$rc out='$out')"
done
# A genuinely EMPTY list is readable and means no request - the marker stands.
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/empty.json" GH_PENDING_RAW='{"reviewRequests":[]}' run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'status=unavailable' \
  && pass "gate: a valid empty reviewRequests list still honours the marker" \
  || die "gate: a valid empty list was treated as unreadable (rc=$rc out='$out')"

# (hh) A current-head PENDING draft proves the marker stale too, and it can exist
# with NO reviewer request listed - an automatic pickup, or a request already
# consumed. head_review_findings deliberately ignores PENDING, so the
# requested-reviewer probe alone left this open.
printf '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"%s","state":"PENDING","submitted_at":null,"id":11}]' \
    "$HEAD40" > "$TMP/reviews-pending.json"
printf '%s\n' "$HEAD40" > "$UNAVAIL_BUS/.copilot-unavailable-7"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-pending.json" GH_PENDING_RAW='{"reviewRequests":[]}' \
       run_unavail gate 7 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'stale_unavailable_review_pending'; } \
  && pass "gate: a current-head PENDING draft overrides the marker (no request listed)" \
  || die "gate: PENDING draft plus marker still permitted the merge (rc=$rc out='$out')"
[ ! -e "$UNAVAIL_BUS/.copilot-unavailable-7" ] \
  && pass "gate: the stale marker is revoked once a draft proves availability" \
  || die "gate: the marker survived a proving draft"
# A PENDING draft on an OLDER head says nothing about this one.
printf '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"%s","state":"PENDING","submitted_at":null,"id":12}]' \
    "$OTHER40" > "$TMP/reviews-pending-old.json"
printf '%s\n' "$HEAD40" > "$UNAVAIL_BUS/.copilot-unavailable-7"
out="$(GH_HEAD="$HEAD40" GH_REVIEWS="$TMP/reviews-pending-old.json" GH_PENDING_RAW='{"reviewRequests":[]}' \
       run_unavail gate 7 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'status=unavailable' \
  && pass "gate: a draft on another head does not invalidate the marker" \
  || die "gate: an unrelated draft invalidated the marker (rc=$rc out='$out')"
rm -f "$UNAVAIL_BUS/.copilot-unavailable-7"

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

# ---- no state outside $TMP ------------------------------------------------
# The bus path is derived from the fake origin, so a missed BUS_DIR override
# writes to a FIXED /tmp path shared by every run of this suite.
for stray in /tmp/acme-widget-review-bus; do
    [ -e "$stray" ] \
      && die "suite left state at the fixed path $stray (a BUS_DIR override is missing)" \
      || pass "no state left at the fixed path $stray"
done

# ---- final ---------------------------------------------------------------
if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
