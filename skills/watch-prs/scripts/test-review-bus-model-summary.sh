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

# write_response now takes the note JSON-ENCODED, because a raw shell value
# cannot round-trip an arbitrary JSON string (trailing newlines are stripped by
# command substitution, NUL cannot be held at all). Tests that supply a note
# encode it the same way the watcher does.
enc() { jq -Rs . <<< "$1" | jq -c '.[:-1]'; }   # -Rs adds one \n; drop it back off

# ── 1. A review WITH findings keeps the model's summary ─────────────────────
resp="$TMP/with-findings.json"
write_response "$resp" 4 abc1234 comments_posted 2 \
    "2 findings posted as inline PR review comments on sha=abc1234." \
    "/dev/null" "$(enc "$MODEL_SUMMARY")"

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
{ [ "$rc" -eq 0 ] && [ "$extracted" = "$(enc "$MODEL_SUMMARY")" ]; } \
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
write_response "$resp_sp" 4 abc1234 comments_posted 1 "1 finding." "/dev/null" "$(enc "$SPACED")"
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


# ── Byte-exactness end to end: trailing newlines and NUL ────────────────────
# The note crossed the shell as a RAW value, and a raw shell value cannot
# round-trip an arbitrary JSON string: command substitution strips EVERY trailing
# newline, and the shell cannot hold a NUL byte at all. Both losses were silent -
# validation reported success and the ALTERED text was recorded as the
# reviewer's own words. These run the real process_review, so they cover the
# whole path (require_model_summary -> process_review -> write_response), not
# just the writer.
run_with_summary() {
    local tag="$1"
    local out="$TMP/pr-$tag"
    rm -rf "$out"; mkdir -p "$out/snap"
    # The fixture is built by jq from a JSON literal, so the awkward bytes never
    # pass through the shell on the way IN either.
    jq -n --argjson s "$2" '{summary: $s, findings: []}' > "$out/result.json"
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
        post_findings() { printf '0 0 0\n'; }
        process_review 4 abc1234 main "$out/prompt.txt" "$out/result.json" \
                       "$out/snap" "$out/resp.json" "$out/log.txt" "" >/dev/null 2>&1
    )
    printf '%s\n' "$out/resp.json"
}

# (a) trailing newlines: "alpha\nbeta\n\n" was recorded as "alpha\nbeta".
nl_json='"alpha\nbeta\n\n"'
nl_resp="$(run_with_summary trailnl "$nl_json")"
if [ -f "$nl_resp" ]; then
    [ "$(jq -c '.model_summary' "$nl_resp")" = "$nl_json" ] \
        && pass "trailing newlines survive end to end" \
        || die "trailing newlines were stripped: $(jq -c '.model_summary' "$nl_resp")"
else
    die "trailing-newline fixture produced no response"
fi

# (b) NUL: "a\u0000b" was recorded as "ab".
nul_json='"a\u0000b"'
nul_resp="$(run_with_summary nul "$nul_json")"
if [ -f "$nul_resp" ]; then
    [ "$(jq -c '.model_summary' "$nul_resp")" = "$nul_json" ] \
        && pass "an embedded NUL survives end to end" \
        || die "the embedded NUL was dropped: $(jq -c '.model_summary' "$nul_resp")"
else
    die "NUL fixture produced no response"
fi

# (c) The clean signoff must still happen for both - byte-exact storage must not
# come at the cost of the review completing.
[ "$(jq -r '.status' "$nl_resp")" = "approved" ] && [ "$(jq -r '.status' "$nul_resp")" = "approved" ] \
    && pass "awkward notes still produce a normal clean signoff" \
    || die "an awkward note broke the signoff path"


# ── An unreadable summary must not become an APPROVAL ──────────────────────
# process_review runs beneath `if !` in handle(), so errexit does not stop it,
# and `|| summary=""` turned a failed decode into an empty string - at which
# point post_clean_signoff substituted its built-in no-findings text and posted
# an APPROVE for a result we had failed to read.

# (a) the decode itself fails. The stub faults ONLY `jq -r .`, the decode call;
# every other jq in the watcher runs for real, so the review reaches that point
# normally.
DEC_BIN="$TMP/decbin"; mkdir -p "$DEC_BIN"
cat > "$DEC_BIN/jq" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAULT_DECODE:-}" ] && [ "$1" = "-r" ] && [ "$2" = "." ] && [ "$#" -eq 2 ]; then
    exit 7
fi
exec /usr/bin/jq "$@"
SH
chmod +x "$DEC_BIN/jq"

dec_resp="$(PATH="$DEC_BIN:$PATH" FAULT_DECODE=1 run_with_summary decodefail '"a real note"')"
if [ -f "$dec_resp" ]; then
    [ "$(jq -r '.status' "$dec_resp")" != "approved" ] \
        && pass "a failed summary decode earns no approval" \
        || die "a failed decode still produced a clean APPROVE"
    [ "$(jq -r '.status' "$dec_resp")" = "error" ] \
        && pass "the failed decode is recorded as an error" \
        || die "the failed decode was not recorded as an error: $(jq -r '.status' "$dec_resp")"
else
    die "decode-failure fixture produced no response"
fi

# (b) a summary with nothing VISIBLE in it. `\S` matches control and format code
# points, so a NUL-only (or bidi-only) summary passed validation and then decoded
# to an empty shell string - the same approval path by a different route.
for invisible in '"\u0000"' '"\u0000\u0000"' '"\u202e"'; do
    inv_resp="$(run_with_summary "invisible$(printf '%s' "$invisible" | tr -cd '0-9a-z')" "$invisible")"
    # No response at all is the CORRECT outcome here: require_model_summary now
    # rejects the result before any signoff, so process_review returns without
    # recording a verdict. What must never happen is an approval.
    if [ -f "$inv_resp" ]; then
        [ "$(jq -r '.status' "$inv_resp")" != "approved" ] \
            && pass "an invisible-only summary ($invisible) earns no approval" \
            || die "an invisible-only summary ($invisible) produced a clean APPROVE"
    else
        pass "an invisible-only summary ($invisible) is rejected before any verdict"
    fi
done

# And the control: a summary with visible content around an invisible byte is
# still a valid signoff - the guard rejects the unreadable, not the awkward.
vis_resp="$(run_with_summary visible '"a\u0000b"')"
[ "$(jq -r '.status' "$vis_resp")" = "approved" ] \
    && pass "visible content around a NUL still signs off" \
    || die "the guard rejected a summary that does have visible content"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
