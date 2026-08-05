#!/usr/bin/env bash
# Unit tests for pr-watch.sh, with pr-review-state.sh stubbed.
#
# The watch is what replaces v1's response monitor, so the property that matters
# is the same one that mattered there: an unreadable state must not look like
# "still waiting", and a terminal state must surface exactly once with its
# verdict attached.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/pr-watch.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

BOT='chatgpt-codex-connector[bot]'

# A stub whose answers come from a script file, one line per call:
#   "<state>" | "ERR" ; the verdict line is fixed.
cat > "$TMP/state.sh" <<'SH'
#!/usr/bin/env bash
cmd="$1"; pr="$2"; who="$3"
seq_file="$SEQ_FILE"; n_file="$SEQ_FILE.n"
n=$(cat "$n_file" 2>/dev/null || echo 1)
if [ "$cmd" = "verdict" ]; then
    printf 'PR_REVIEW_STATE pr=%s sha=abc reviewer=%s %s\n' "$pr" "$who" "${VERDICT:-verdict=findings findings=2}"
    exit "${VERDICT_RC:-1}"
fi
ans=$(sed -n "${n}p" "$seq_file"); [ -n "$ans" ] || ans=$(tail -1 "$seq_file")
echo $((n + 1)) > "$n_file"
if [ "$ans" = "ERR" ]; then
    printf 'PR_REVIEW_STATE pr=%s sha=abc reviewer=%s status=error reason=unreadable\n' "$pr" "$who"
    exit 2
fi
printf 'PR_REVIEW_STATE pr=%s sha=abc reviewer=%s state=%s\n' "$pr" "$who" "$ans"
exit 0
SH
chmod +x "$TMP/state.sh"
run() { PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" "$@"; }
seq_set() { printf '%s\n' "$@" > "$TMP/seq"; rm -f "$TMP/seq.n"; }

# ── a terminal state ends the watch, with its verdict ──────────────────────
seq_set none none reviewed
out="$(run 7 "$BOT" --interval 1 --timeout 30 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] || [ "$rc" -eq 0 ]; } && pass "watch exits when the state turns terminal" \
    || die "watch did not exit on a terminal state (rc=$rc)"
printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
    && pass "the terminal line is distinguishable (PR_REVIEW_READY)" \
    || die "no PR_REVIEW_READY line: $out"
printf '%s' "$out" | grep -q 'findings=2' \
    && pass "the verdict is reported without a second round-trip" \
    || die "the verdict was not attached: $out"

# ── it prints on CHANGE, not on every poll ─────────────────────────────────
seq_set none none none none pending reviewed
out="$(run 7 "$BOT" --interval 1 --timeout 30 2>&1)"
n_none=$(printf '%s\n' "$out" | grep -c 'state=none')
[ "$n_none" -eq 1 ] \
    && pass "a repeated state is reported once, not once per poll" \
    || die "state=none printed $n_none times"
printf '%s' "$out" | grep -q 'state=pending' \
    && pass "an intermediate state change is reported" || die "the pending transition was not shown"

# ── an unreadable state is NOT 'still waiting' ─────────────────────────────
seq_set none ERR reviewed
out="$(run 7 "$BOT" --interval 1 --timeout 30 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "an unreadable state exits 2 rather than polling on" \
    || die "unreadable state gave rc=$rc (must fail closed)"
printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
    && die "an unreadable state produced a READY line" \
    || pass "no READY line from an unreadable state"

# ── a clean verdict propagates 0 ───────────────────────────────────────────
seq_set reviewed
out="$(VERDICT='verdict=clean findings=0' VERDICT_RC=0 run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'verdict=clean'; } \
    && pass "a clean verdict exits 0" || die "clean verdict gave rc=$rc out='$out'"

# An unreadable VERDICT after a terminal state must also fail closed.
seq_set reviewed
out="$(VERDICT='verdict=error reason=unreadable' VERDICT_RC=2 run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "an unreadable verdict after a terminal state => 2" \
    || die "unreadable verdict gave rc=$rc"

# ── the timeout is honoured and distinguishable ────────────────────────────
seq_set none
out="$(run 7 "$BOT" --interval 1 --timeout 2 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'state=timeout'; } \
    && pass "the timeout exits 1 with a timeout line" || die "timeout gave rc=$rc out='$out'"

# ── argument validation ────────────────────────────────────────────────────
run 2>&1 >/dev/null; [ "$?" -eq 2 ] && pass "no arguments => 2" || die "missing args did not exit 2"
run abc "$BOT" >/dev/null 2>&1; [ "$?" -eq 2 ] && pass "a non-numeric PR => 2" || die "bad PR did not exit 2"
# A zero interval would spin; a non-numeric one must not abort.
seq_set reviewed
out="$(run 7 "$BOT" --interval 0 --timeout 5 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || [ "$rc" -eq 0 ] && pass "a zero interval falls back rather than spinning" \
    || die "interval 0 gave rc=$rc"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
