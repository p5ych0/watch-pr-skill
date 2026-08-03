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

# ── 4. process_review carries it through on the findings path ──────────────
# The unit above proves write_response stores it; this proves the value is
# actually READ from the model result on the path where it used to be dropped.
result="$TMP/result.json"
jq -n --arg s "$MODEL_SUMMARY" '{summary: $s, findings: [{path: "a.sh", line: 1, side: "RIGHT", body: "x"}]}' > "$result"
extracted="$(read_model_summary "$result")"
[ "$extracted" = "$MODEL_SUMMARY" ] \
    && pass "read_model_summary extracts the model's text from a result WITH findings" \
    || die "read_model_summary did not extract the summary (got: '$extracted')"

# Malformed / missing result must yield empty, never a jq error string that
# would then be written into the response as if the reviewer had said it.
[ -z "$(read_model_summary "$TMP/does-not-exist.json")" ] \
    && pass "missing result file => empty, not an error string" \
    || die "missing result produced non-empty model summary"

printf 'not json at all\n' > "$TMP/bad.json"
[ -z "$(read_model_summary "$TMP/bad.json")" ] \
    && pass "malformed result => empty, not an error string" \
    || die "malformed result produced non-empty model summary"

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
        post_findings() { printf '1 0 1\n'; }       # posted failed attempted
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

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
