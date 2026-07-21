#!/usr/bin/env bash
# Focused test for the live review-progress feature:
#   - watcher: progress_set writes valid state; progress_tap counts JSONL events
#     and survives malformed lines; progress_sanitize strips ANSI/control/newlines
#     and truncates; run_codex_review preserves a non-zero codex exit; secrets /
#     raw output are never read into the relayed note.
#   - monitor: an in-flight run emits <PREFIX>_REVIEW_PROGRESS state=resumed; a run
#     whose terminal resp exists (or whose state is terminal) is NOT replayed;
#     same-SHA runs stay distinct by run_id; status detail carries no note while
#     summary detail carries a sanitized one; progress is never a bare _REVIEW.
#
# Self-contained: throwaway repo + BUS_DIR under a temp dir. No network, no gh.
# A stub codex exercises the --json tap. Sources the watcher (main() guarded off).

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SELF_DIR/review-bus-codex-watcher.sh"
MONITOR="$SELF_DIR/review-bus-response-monitor.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

export REPO_DIR="$TMP/repo"
export BUS_DIR="$TMP/bus"
export REVIEW_BUS_OWNER=acme REVIEW_BUS_REPO=widgets   # deterministic PREFIX=WIDGETS
mkdir -p "$REPO_DIR"; git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email t@t.t; git -C "$REPO_DIR" config user.name t
echo x > "$REPO_DIR/f"; git -C "$REPO_DIR" add f; git -C "$REPO_DIR" commit -qm init

# ── Stub codex: `exec --help` advertises --json; `exec … -` emits JSONL events
#    (incl. one malformed line), writes the --output-last-message result, exits
#    with STUB_CODEX_RC (default 0). Prints a secret to stdout to prove it is
#    never relayed into a progress note. ─────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "exec" ] && printf '%s\n' "$@" | grep -q -- '--help'; then
  echo "  --json    emit JSONL events"; exit 0
fi
result=""; prev=""
for a in "$@"; do [ "$prev" = "--output-last-message" ] && result="$a"; prev="$a"; done
# JSONL event stream (with a malformed line the tap must survive).
printf '%s\n' '{"type":"thread.started"}'
printf '%s\n' '{"type":"item.started","item":{"type":"command_execution"}}'
printf '%s\n' 'NOT-JSON-AT-ALL <<<garbage'
printf '%s\n' '{"type":"item.completed","item":{"type":"command_execution"}}'
printf '%s\n' '{"type":"agent_message","text":"probed the diff"}'
printf '%s\n' '{"type":"turn.completed","usage":{"tokens":123}}'
echo "SECRET_TOKEN=hunter2 should-never-be-relayed"
[ -n "$result" ] && printf '%s' '{"findings":[]}' > "$result"
exit "${STUB_CODEX_RC:-0}"
STUB
chmod +x "$TMP/bin/codex"
export CODEX_BIN="$TMP/bin/codex"

# shellcheck disable=SC1090
source "$WATCHER"
set +e

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

PROG="$BUS_DIR/progress"

# ── 1. progress_set writes a valid, atomic progress file ────────────────────
PROGRESS_RUN_ID="abc1234.111"; PROGRESS_PR=42; PROGRESS_SHA="abc1234"; PROGRESS_BRANCH="feat"
PROGRESS_ITER=3; PROGRESS_STARTED_AT="2026-07-21T00:00:00Z"; PROGRESS_EVENTS=0; PROGRESS_COMMANDS=0
PROGRESS_LAST_EVENT=""; PROGRESS_FINDINGS=0; PROGRESS_REASON=""
progress_set reviewing running
pf="$PROG/abc1234.111.json"
if [ -f "$pf" ] && [ "$(jq -r '.phase' "$pf")" = reviewing ] && [ "$(jq -r '.state' "$pf")" = running ] \
   && [ "$(jq -r '.pr' "$pf")" = 42 ] && [ "$(jq -r '.run_id' "$pf")" = "abc1234.111" ]; then
    pass "progress_set: writes a valid state file"
else
    die "progress_set: bad/missing file ($(cat "$pf" 2>/dev/null))"
fi

# ── 2. progress_sanitize strips ANSI + control + newlines and truncates ─────
raw=$'\x1b[31mred\x1b[0m\nline2\tafter'
san="$(progress_sanitize "$raw")"
has_ctrl=0; printf '%s' "$san" | LC_ALL=C grep -q '[[:cntrl:]]' && has_ctrl=1
if [ "$has_ctrl" -eq 0 ] && printf '%s' "$san" | grep -q 'red' && printf '%s' "$san" | grep -q 'line2'; then
    pass "progress_sanitize: strips ANSI/control/newlines, keeps text"
else
    die "progress_sanitize: not sanitized (ctrl=$has_ctrl san=[$san])"
fi
long="$(printf 'x%.0s' {1..500})"; [ "${#long}" -eq 500 ] && [ "$(progress_sanitize "$long" | wc -c)" -le 241 ] \
    && pass "progress_sanitize: truncates to ~240" || die "progress_sanitize: not truncated"

# ── 3. progress_tap counts events/commands and survives malformed JSONL ─────
PROGRESS_EVENTS=0; PROGRESS_COMMANDS=0; PROGRESS_LAST_EVENT=""; PROGRESS_RUN_ID="tap.1"; PROGRESS_SHA="tap"
out="$(printf '%s\n' \
    '{"type":"thread.started"}' \
    'garbage-not-json' \
    '{"type":"item.started","item":{"type":"command_execution"}}' \
    '{"type":"turn.completed"}' | progress_tap)"
tf="$PROG/tap.1.json"
# Lines are forwarded verbatim (including the malformed one) …
printf '%s' "$out" | grep -q 'garbage-not-json' && pass "progress_tap: forwards every line (log intact)" || die "progress_tap: dropped a line"
# … and the file counts 3 typed events, 1 of them a command.
if [ -f "$tf" ] && [ "$(jq -r '.events' "$tf")" -ge 3 ] && [ "$(jq -r '.commands' "$tf")" -ge 1 ]; then
    pass "progress_tap: counts events + commands, ignores malformed line"
else
    die "progress_tap: bad counters ($(cat "$tf" 2>/dev/null))"
fi

# ── 4. run_codex_review preserves a NON-ZERO codex exit (→ error path) ──────
: > "$SCHEMA_FILE" 2>/dev/null || true
printf 'review please\n' > "$TMP/prompt.txt"
STUB_CODEX_RC=7 run_codex_review "$TMP/prompt.txt" "$TMP/result.json" "$REPO_DIR" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 7 ] && pass "run_codex_review: preserves codex non-zero exit ($rc)" || die "run_codex_review: swallowed exit (got $rc)"
# And on success it wrote the result via --output-last-message (tap didn't break it).
run_codex_review "$TMP/prompt.txt" "$TMP/result.json" "$REPO_DIR" >/dev/null 2>&1
{ [ -s "$TMP/result.json" ] && jq -e '.findings|type=="array"' "$TMP/result.json" >/dev/null; } \
    && pass "run_codex_review: --output-last-message still written under the tap" || die "run_codex_review: no result file"
# The secret printed to stdout must never appear in any progress file.
grep -rqi 'hunter2\|SECRET_TOKEN' "$PROG" 2>/dev/null && die "SECRET leaked into a progress file" || pass "no secret/raw stdout relayed into progress state"

# ── Monitor emission (crafted progress files + --once) ──────────────────────
mk_prog() {   # <run_id> <sha> <state> <phase> [reasoning]
    mkdir -p "$PROG"
    jq -n --arg r "$1" --arg s "$2" --arg st "$3" --arg ph "$4" --arg reason "${5:-}" \
        '{run_id:$r, pr:7, sha:$s, branch:"b", state:$st, phase:$ph,
          started_at:"2026-07-21T00:00:00Z", updated_at:"2026-07-21T00:01:00Z",
          iter:5, events:12, commands:4, last_event:"command_completed", findings:0}
         + (if $reason=="" then {} else {reasoning:$reason} end)' > "$PROG/$1.json"
}
run_monitor() {  # env… -> stdout of a one-shot replay
    ( cd "$REPO_DIR" && PATH="$TMP/bin:$PATH" BUS_DIR="$BUS_DIR" \
        MONITOR_EMITTED_DIR="$(mktemp -d)" "$@" "$MONITOR" --once 2>/dev/null )
}

# 5. An in-flight run (no resp, non-terminal) emits state=resumed progress.
rm -rf "$PROG" "$BUS_DIR/responses"; mkdir -p "$BUS_DIR/responses"
mk_prog "run.a" "sha_a" running reviewing
o="$(run_monitor)"
printf '%s\n' "$o" | grep -q 'WIDGETS_REVIEW_PROGRESS .*run=run.a .*state=resumed .*phase=reviewing' \
    && pass "monitor: in-flight run → resumed progress line" || die "monitor: no resumed line ($o)"
printf '%s\n' "$o" | grep -Eq 'WIDGETS_REVIEW ' && die "monitor: progress mis-emitted a bare _REVIEW handoff" || pass "monitor: progress is not a _REVIEW handoff"

# 6. A run whose terminal resp exists is NOT replayed as progress.
rm -rf "$PROG"; mk_prog "run.b" "sha_b" running reviewing
printf '{"pr":7,"sha":"sha_b","status":"comments_posted","findings_count":3,"reviewer":"codex","summary":"x"}' > "$BUS_DIR/responses/resp-sha_b.json"
o="$(run_monitor)"
printf '%s\n' "$o" | grep -q 'run=run.b' && die "monitor: replayed progress for a completed run" || pass "monitor: terminal-resp run not replayed as progress"

# 7. A terminal-state (completed) progress file is NOT replayed.
rm -rf "$PROG" "$BUS_DIR/responses"; mkdir -p "$BUS_DIR/responses"; mk_prog "run.c" "sha_c" completed completed
o="$(run_monitor)"
printf '%s\n' "$o" | grep -q 'run=run.c' && die "monitor: replayed completed historical progress" || pass "monitor: completed progress not replayed"

# 8. Same-SHA runs stay distinct by run_id (both surfaced).
rm -rf "$PROG"; mk_prog "run.d1" "sha_d" running reviewing; mk_prog "run.d2" "sha_d" running preparing_context
o="$(run_monitor)"
{ printf '%s\n' "$o" | grep -q 'run=run.d1' && printf '%s\n' "$o" | grep -q 'run=run.d2'; } \
    && pass "monitor: same-SHA runs distinct by run_id" || die "monitor: same-SHA runs not distinct ($o)"

# 9. Detail gating: status detail carries NO note; summary detail carries a
#    sanitized one (no ANSI/newline, from the reasoning field).
rm -rf "$PROG"; mk_prog "run.e" "sha_e" running reviewing "$(printf 'clean summary')"
o_status="$(CODEX_REVIEW_PROGRESS_DETAIL=status run_monitor)"
printf '%s\n' "$o_status" | grep -q 'note=' && die "monitor(status): leaked a note" || pass "monitor(status): no reasoning note (safe default)"
o_sum="$(CODEX_REVIEW_PROGRESS_DETAIL=summary run_monitor)"
printf '%s\n' "$o_sum" | grep -q 'note="clean summary"' && pass "monitor(summary): relays the sanitized note" || die "monitor(summary): no note ($o_sum)"

# 10. off disables progress entirely.
rm -rf "$PROG"; mk_prog "run.f" "sha_f" running reviewing
o="$(CODEX_REVIEW_PROGRESS_DETAIL=off run_monitor)"
printf '%s\n' "$o" | grep -q 'run=run.f' && die "monitor(off): emitted progress despite off" || pass "monitor(off): progress disabled"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
