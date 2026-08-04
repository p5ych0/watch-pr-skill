#!/usr/bin/env bash
# The reviewer's own summary must survive a review that reports findings.
#
# p5ych0/strumok#212: process_review read `.summary` from the model's result
# ONLY in the zero-findings branch. With one or more findings it was overwritten
# by a status line and never reached the PR or the bus response — so a reviewer
# that correctly declined to force a concern into a line-attached finding lost
# the concern entirely. The prompt asks for a summary on every review, including
# a mixed one, so this discarded exactly the text it asked for.
#
# It is preserved in the RESPONSE, never posted as an issue comment. That is not
# a stylistic choice: latest_issue_comment_at() takes ANY issue comment with no
# author filter, and auto_preflight_ready() uses it as the "round was closed out"
# gate — so a watcher-authored issue comment would satisfy that gate by itself
# and let auto-enqueue fire without the author ever closing the round.
#
# Self-contained: throwaway git repo + BUS_DIR under a temp dir. No network.

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
export REPO_DIR BUS_DIR="$TMP/bus" REVIEW_BUS_REMOTE="git@github.com:test/demo.git"
mkdir -p "$BUS_DIR/responses"

# shellcheck disable=SC1090
source "$WATCHER"
set +e

MODEL_SUMMARY="Two blockers below. Also: the retry cap could not be verified because the suite needs credentials this worktree lacks."

# ── 1. A review WITH findings keeps the model's summary ─────────────────────
resp="$TMP/with-findings.json"
write_response "$resp" 4 abc1234 comments_posted 2 \
    "2 findings posted as inline PR review comments on sha=abc1234." \
    "/dev/null" "$MODEL_SUMMARY"

[ "$(jq -r '.model_summary // "ABSENT"' "$resp")" = "$MODEL_SUMMARY" ] \
    && pass "model_summary survives a review that posted findings" \
    || die "model_summary lost on a review with findings (the #212 defect)"

# The status line must still be there — the fix ADDS a channel, it does not
# repurpose the existing one that tooling and humans already read.
[ "$(jq -r '.summary' "$resp")" = "2 findings posted as inline PR review comments on sha=abc1234." ] \
    && pass "status summary is unchanged (model summary is an additional field)" \
    || die "status summary was clobbered by the model summary"

[ "$(jq -r '.findings_count' "$resp")" = "2" ] \
    && pass "findings_count unaffected" || die "findings_count changed"

# ── 2. No key at all when the model gave no summary ────────────────────────
# An empty-string key would read as "the reviewer said nothing of note", which
# is a different claim from "the reviewer was not asked / did not answer".
resp2="$TMP/no-summary.json"
write_response "$resp2" 4 abc1234 comments_posted 1 "1 finding posted." "/dev/null" ""
[ "$(jq -r 'has("model_summary")' "$resp2")" = "false" ] \
    && pass "no model_summary key when the model supplied none" \
    || die "empty model_summary key emitted"

# ── 3. Existing 7-arg callers are untouched ────────────────────────────────
resp3="$TMP/legacy.json"
write_response "$resp3" 4 abc1234 approved 0 "clean" "/dev/null"
[ "$(jq -r 'has("model_summary")' "$resp3")" = "false" ] \
    && pass "7-arg callers unchanged" || die "7-arg call grew a model_summary key"

# ── 4. require_model_summary validates AND extracts in one operation ───────
# Separate validate/extract steps were a TOCTOU: validation ran before any side
# effect, extraction ran after the comments were posted, and a result that
# changed in between yielded an empty summary that the zero-findings branch
# turned into a clean approval. One read, one verdict.
result="$TMP/result.json"
jq -n --arg s "$MODEL_SUMMARY" '{summary: $s, findings: [{path: "a.sh", line: 1, side: "RIGHT", body: "x"}]}' > "$result"
extracted="$(require_model_summary "$result")" && rc=0 || rc=1
{ [ "$rc" -eq 0 ] && [ "$extracted" = "$MODEL_SUMMARY" ]; } \
    && pass "require_model_summary: extracts from a result WITH findings" \
    || die "require_model_summary failed on a valid result (rc=$rc got: '$extracted')"

# Every invalid shape must FAIL, not return empty — an empty return is what the
# caller would have turned into "no note", and then into an approval.
for bad_desc in 'missing:{"findings":[]}' 'null:{"findings":[],"summary":null}' \
                'number:{"findings":[],"summary":123}' 'empty:{"findings":[],"summary":""}'; do
    desc="${bad_desc%%:*}"; body="${bad_desc#*:}"
    printf '%s\n' "$body" > "$TMP/bad.json"
    if require_model_summary "$TMP/bad.json" >/dev/null 2>&1; then
        die "require_model_summary accepted an invalid summary ($desc)"
    else
        pass "require_model_summary rejects $desc summary"
    fi
done

if require_model_summary "$TMP/does-not-exist.json" >/dev/null 2>&1; then
    die "require_model_summary accepted a missing result file"
else
    pass "require_model_summary rejects a missing result file"
fi

printf 'not json at all\n' > "$TMP/malformed.json"
if require_model_summary "$TMP/malformed.json" >/dev/null 2>&1; then
    die "require_model_summary accepted a malformed result"
else
    pass "require_model_summary rejects a malformed result"
fi

# ── 5. process_review end-to-end on the FINDINGS path ──────────────────────
# The units above prove the pieces. They do NOT prove the pieces are wired
# together: deleting either plumbing line in process_review (the read, or the
# 8th argument to write_response) would reproduce #212 with every assertion
# above still green. So drive the real process_review, stubbing only its
# external edges — worktree, GitHub, and the codex run.
drive_process_review() {   # <result-json-file> ; echoes the response path
    local result_src="$1" out="$TMP/pr-run"
    rm -rf "$out"; mkdir -p "$out/snap"
    cp "$result_src" "$out/result.json"
    (
        set +eu
        # External edges only. Everything between them is the code under test.
        progress_set() { :; }
        resolve_requested_commit() { printf 'ffffffffffffffffffffffffffffffffffffffff\n'; }
        prepare_review_worktree() { printf '%s\n' "$REPO_DIR"; }
        fetch_review_context() { :; }
        build_prompt() { :; }
        max_comment_id() { printf '0\n'; }
        count_comments_after() { printf '0\n'; }
        newer_request_for_same_pr() { return 1; }   # not superseded
        run_codex_review() { :; }                   # result.json is pre-placed
        # Faithful: post exactly what the snapshot it is handed contains. A stub
        # that always claimed "1 posted" tripped the posted>produced consistency
        # guard on every zero-finding fixture, so those cases passed for the
        # wrong reason and could not detect their own guard regressing.
        post_findings() { local n; n="$(jq '.findings | length' "$3" 2>/dev/null || echo 0)"; printf '%s 0 %s\n' "$n" "$n"; }
        post_clean_signoff() { printf 'COMMENT\n'; }
        process_review 4 abc1234 main "$out/prompt.txt" "$out/result.json" \
                       "$out/snap" "$out/resp.json" "$out/log.txt" "" >/dev/null 2>&1
    )
    printf '%s\n' "$out/resp.json"
}

jq -n --arg s "$MODEL_SUMMARY" \
   '{summary: $s, findings: [{path: "a.sh", line: 1, side: "RIGHT", body: "x"}]}' > "$TMP/mixed.json"
run_resp="$(drive_process_review "$TMP/mixed.json")"

if [ -f "$run_resp" ]; then
    [ "$(jq -r '.status' "$run_resp")" = "comments_posted" ] \
        && pass "process_review: took the findings-posting path" \
        || die "process_review: wrong path (status=$(jq -r '.status' "$run_resp"))"

    [ "$(jq -r '.model_summary // "ABSENT"' "$run_resp")" = "$MODEL_SUMMARY" ] \
        && pass "process_review: model_summary reaches the response on a review WITH findings" \
        || die "process_review: model_summary absent — the #212 plumbing is not wired"
else
    die "process_review produced no response file"
fi

# ── 6. A schema-invalid result must NOT earn a clean approval ──────────────
# `summary` is required on every review. Without this check a result such as
# {"findings":[]} fell into the zero-findings branch, picked up a default
# "no actionable issues" string, and was APPROVED — a malformed reviewer output
# approving the PR, which is the worst direction this code can fail in.
for bad in '{"findings":[]}' '{"findings":[],"summary":null}' '{"findings":[],"summary":123}' '{"findings":[],"summary":""}'; do
    printf '%s\n' "$bad" > "$TMP/bad-result.json"
    bad_resp="$(drive_process_review "$TMP/bad-result.json")"
    if [ -f "$bad_resp" ] && [ "$(jq -r '.status' "$bad_resp")" = "approved" ]; then
        die "schema-invalid result APPROVED the PR: $bad"
    else
        pass "schema-invalid result earns no approval: $bad"
    fi
done

# ── 7. TOCTOU: a result replaced AFTER validation must not change the verdict ──
# The reproduction from the review: validation runs before any side effect, but
# the extraction used to run after the comments were posted. Swapping the result
# in between produced status=approved with no model_summary and synthesized
# "no actionable issues" text. Because the summary is now captured at validation
# time, the later swap cannot influence anything.
swap_after_validation() {
    local out="$TMP/pr-toctou"
    rm -rf "$out"; mkdir -p "$out/snap"
    jq -n --arg s "$MODEL_SUMMARY" \
       '{summary: $s, findings: [{path: "a.sh", line: 1, side: "RIGHT", body: "x"}]}' > "$out/result.json"
    (
        set +eu
        progress_set() { :; }
        resolve_requested_commit() { printf 'ffffffffffffffffffffffffffffffffffffffff\n'; }
        prepare_review_worktree() { printf '%s\n' "$REPO_DIR"; }
        fetch_review_context() { :; }
        build_prompt() { :; }
        max_comment_id() { printf '0\n'; }
        count_comments_after() { printf '0\n'; }
        newer_request_for_same_pr() { return 1; }
        run_codex_review() { :; }
        post_clean_signoff() { printf 'COMMENT\n'; }
        # The swap happens exactly where the second read used to be: after
        # validation, during the GitHub-posting step.
        post_findings() { printf '{"findings":[]}\n' > "$out/result.json"; printf '1 0 1\n'; }
        process_review 4 abc1234 main "$out/prompt.txt" "$out/result.json" \
                       "$out/snap" "$out/resp.json" "$out/log.txt" "" >/dev/null 2>&1
    )
    printf '%s\n' "$out/resp.json"
}

toctou_resp="$(swap_after_validation)"
if [ -f "$toctou_resp" ]; then
    [ "$(jq -r '.status' "$toctou_resp")" != "approved" ] \
        && pass "result swapped after validation does not become an approval" \
        || die "TOCTOU: a post-validation swap produced status=approved"

    [ "$(jq -r '.model_summary // "ABSENT"' "$toctou_resp")" = "$MODEL_SUMMARY" ] \
        && pass "the VALIDATED summary is the one recorded, not a later re-read" \
        || die "TOCTOU: model_summary came from the swapped result"
else
    die "TOCTOU fixture produced no response file"
fi

# ── 8. Two concatenated top-level objects must not approve ─────────────────
# jq reads a STREAM, so `{...}{...}` parses happily and `.findings | length`
# emits "0\n0" — satisfying no numeric test, falling through to the zero-findings
# branch, and posting a clean APPROVE. Only slurping and requiring exactly one
# object rejects this.
printf '{"summary":"a","findings":[]}{"summary":"b","findings":[]}\n' > "$TMP/two-objects.json"
two_resp="$(drive_process_review "$TMP/two-objects.json")"
if [ -f "$two_resp" ] && [ "$(jq -r '.status' "$two_resp" 2>/dev/null)" = "approved" ]; then
    die "two concatenated JSON objects produced a clean APPROVE"
else
    pass "two concatenated JSON objects earn no approval"
fi

# ── 9. A whitespace-only summary is not a signoff ──────────────────────────
printf '{"summary":" \\t ","findings":[]}\n' > "$TMP/ws-summary.json"
ws_resp="$(drive_process_review "$TMP/ws-summary.json")"
if [ -f "$ws_resp" ] && [ "$(jq -r '.status' "$ws_resp" 2>/dev/null)" = "approved" ]; then
    die "whitespace-only summary produced a clean APPROVE"
else
    pass "whitespace-only summary earns no approval"
fi

# The stored text must keep the reviewer's exact formatting — the whitespace
# check is a test, not a transformation.
SPACED="  leading and trailing spaces matter  "
resp_sp="$TMP/spaced.json"
write_response "$resp_sp" 4 abc1234 comments_posted 1 "1 finding." "/dev/null" "$SPACED"
[ "$(jq -r '.model_summary' "$resp_sp")" = "$SPACED" ] \
    && pass "stored note keeps its exact formatting (validation does not rewrite it)" \
    || die "stored note was altered by validation"

# ── 10. Reverse swap: more posted than the validated result held ───────────
# The mirror of case 7. If post_findings reports posting more comments than the
# snapshot contained, the count about to be recorded disagrees with what reached
# the PR — which is how a PR with posted comments gets marked approved with
# findings_count 0. That disagreement must fail closed, never sign off.
reverse_swap() {
    local out="$TMP/pr-reverse"
    rm -rf "$out"; mkdir -p "$out/snap"
    jq -n --arg s "$MODEL_SUMMARY" '{summary: $s, findings: []}' > "$out/result.json"
    (
        set +eu
        progress_set() { :; }
        resolve_requested_commit() { printf 'ffffffffffffffffffffffffffffffffffffffff\n'; }
        prepare_review_worktree() { printf '%s\n' "$REPO_DIR"; }
        fetch_review_context() { :; }
        build_prompt() { :; }
        max_comment_id() { printf '0\n'; }
        count_comments_after() { printf '0\n'; }
        newer_request_for_same_pr() { return 1; }
        run_codex_review() { :; }
        post_clean_signoff() { printf 'COMMENT\n'; }
        # Claims a comment was posted although the validated result held none.
        post_findings() { printf '1 0 1\n'; }
        process_review 4 abc1234 main "$out/prompt.txt" "$out/result.json" \
                       "$out/snap" "$out/resp.json" "$out/log.txt" "" >/dev/null 2>&1
    )
    printf '%s\n' "$out/resp.json"
}

rev_resp="$(reverse_swap)"
if [ -f "$rev_resp" ]; then
    [ "$(jq -r '.status' "$rev_resp")" != "approved" ] \
        && pass "posted > validated findings does not approve" \
        || die "posted-more-than-validated still produced a clean APPROVE"
    [ "$(jq -r '.findings_count' "$rev_resp")" != "0" ] \
        && pass "the recorded count reflects what was posted, not the stale 0" \
        || die "recorded findings_count=0 while a comment was posted"
else
    die "reverse-swap fixture produced no response file"
fi

# ── 11. An NBSP-only summary is not a signoff either ───────────────────────
# The emptiness test must be UNICODE-AWARE. `tr -d '[:space:]'` under C/C.UTF-8
# leaves U+00A0 (c2 a0) intact, so an NBSP-only summary passed a shell-side
# check and could earn a clean approval with no substantive signoff.
printf '{"summary":"\\u00a0","findings":[]}\n' > "$TMP/nbsp.json"
nbsp_resp="$(drive_process_review "$TMP/nbsp.json")"
if [ -f "$nbsp_resp" ] && [ "$(jq -r '.status' "$nbsp_resp" 2>/dev/null)" = "approved" ]; then
    die "NBSP-only summary produced a clean APPROVE"
else
    pass "NBSP-only summary earns no approval (unicode-aware emptiness)"
fi

# Text that merely CONTAINS an NBSP is perfectly valid and must still pass.
printf '{"summary":"real\\u00a0signoff text","findings":[]}\n' > "$TMP/nbsp-ok.json"
nbsp_ok="$(require_model_summary "$TMP/nbsp-ok.json")" && rc=0 || rc=1
[ "$rc" -eq 0 ] \
    && pass "a summary containing NBSP among real words is accepted" \
    || die "over-strict: rejected a substantive summary that contains an NBSP"

# ── 12. An unreadable findings count must not approve ──────────────────────
# process_review runs beneath `if !`, so errexit does not stop it: an unguarded
# jq failure left `produced` empty, every numeric test evaluated false, and
# execution dropped into the zero-findings branch and a clean signoff.
count_jq_fails() {
    local out="$TMP/pr-countfail"
    rm -rf "$out"; mkdir -p "$out/snap" "$out/bin"
    jq -n --arg s "$MODEL_SUMMARY" '{summary: $s, findings: []}' > "$out/result.json"
    # A jq that answers validation normally but fails the `.findings | length`
    # query specifically — the exact invocation the finding names.
    cat > "$out/bin/jq" <<'JQSTUB'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = ".findings | length" ] && exit 3
done
exec /usr/bin/jq "$@"
JQSTUB
    chmod +x "$out/bin/jq"
    (
        set +eu
        PATH="$out/bin:$PATH"
        progress_set() { :; }
        resolve_requested_commit() { printf 'ffffffffffffffffffffffffffffffffffffffff\n'; }
        prepare_review_worktree() { printf '%s\n' "$REPO_DIR"; }
        fetch_review_context() { :; }
        build_prompt() { :; }
        max_comment_id() { printf '0\n'; }
        count_comments_after() { printf '0\n'; }
        newer_request_for_same_pr() { return 1; }
        run_codex_review() { :; }
        post_clean_signoff() { printf 'COMMENT\n'; }
        post_findings() { printf '0 0 0\n'; }
        process_review 4 abc1234 main "$out/prompt.txt" "$out/result.json" \
                       "$out/snap" "$out/resp.json" "$out/log.txt" "" >/dev/null 2>&1
    )
    printf '%s\n' "$out/resp.json"
}

cnt_resp="$(count_jq_fails)"
if [ -f "$cnt_resp" ] && [ "$(jq -r '.status' "$cnt_resp" 2>/dev/null)" = "approved" ]; then
    die "an unreadable findings count produced a clean APPROVE"
else
    pass "unreadable findings count earns no approval (guarded, not silently empty)"
fi

# ── 13. A failed findings ITERATOR must not read as "zero findings" ────────
# post_findings fed its loop from `< <(jq …)`, which hides the iterator's exit
# status: the function always reached its final printf, so the caller's
# `|| return 1` could never see a parse failure. A failed iterator then looked
# exactly like an empty findings array, and on a zero-finding result that
# produced a clean approval. Uses the REAL post_findings — stubbing it would
# test nothing here.
findings_iter_fails() {
    local out="$TMP/pr-iterfail"
    rm -rf "$out"; mkdir -p "$out/snap" "$out/bin"
    jq -n --arg s "$MODEL_SUMMARY" '{summary: $s, findings: []}' > "$out/result.json"
    cat > "$out/bin/jq" <<'JQSTUB'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = ".findings[]" ] && exit 3
done
exec /usr/bin/jq "$@"
JQSTUB
    chmod +x "$out/bin/jq"
    (
        set +eu
        PATH="$out/bin:$PATH"
        progress_set() { :; }
        resolve_requested_commit() { printf 'ffffffffffffffffffffffffffffffffffffffff\n'; }
        prepare_review_worktree() { printf '%s\n' "$REPO_DIR"; }
        fetch_review_context() { :; }
        build_prompt() { :; }
        max_comment_id() { printf '0\n'; }
        count_comments_after() { printf '0\n'; }
        newer_request_for_same_pr() { return 1; }
        run_codex_review() { :; }
        post_clean_signoff() { printf 'COMMENT\n'; }
        # post_findings is deliberately REAL.
        process_review 4 abc1234 main "$out/prompt.txt" "$out/result.json" \
                       "$out/snap" "$out/resp.json" "$out/log.txt" "" >/dev/null 2>&1
    )
    printf '%s\n' "$out/resp.json"
}

iter_resp="$(findings_iter_fails)"
if [ -f "$iter_resp" ] && [ "$(jq -r '.status' "$iter_resp" 2>/dev/null)" = "approved" ]; then
    die "a failed .findings[] iterator produced a clean APPROVE"
else
    pass "failed findings iterator earns no approval (parse guarded, not silently empty)"
fi

# The guard must not mistake a legitimately EMPTY findings array for a failure:
# an empty parse is zero findings, and `<<<` on an empty string would otherwise
# feed the loop one bogus iteration and report a phantom attempt.
zero_stats="$(post_findings 4 ffffffffffffffffffffffffffffffffffffffff "$TMP/pr-iterfail/result.json" abc1234 2>/dev/null)"
[ "$zero_stats" = "0 0 0" ] \
    && pass "empty findings array reports 0 0 0 (no phantom attempt)" \
    || die "empty findings array reported '$zero_stats'"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
