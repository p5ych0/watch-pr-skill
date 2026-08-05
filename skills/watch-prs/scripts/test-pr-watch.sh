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

# ── ANY non-zero helper status is an error, not a state ────────────────────
# A missing or non-executable helper exits 126/127. Treating that as a state left
# the watch polling stderr until it reported a TIMEOUT, which reads as "wait or
# re-request" when the truth is "this cannot be read at all".
for rc_case in 126 127 3; do
    cat > "$TMP/broken.sh" <<SH
#!/usr/bin/env bash
echo "some stderr noise" >&2
exit $rc_case
SH
    chmod +x "$TMP/broken.sh"
    out="$(PR_WATCH_STATE_SCRIPT="$TMP/broken.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "a helper exiting $rc_case => 2, not a timeout" \
        || die "helper rc=$rc_case gave rc=$rc out='$out'"
    printf '%s' "$out" | grep -q 'state=timeout' \
        && die "helper rc=$rc_case was reported as a timeout" \
        || pass "helper rc=$rc_case is not reported as a timeout"
done

# ── READY must not precede a verdict that could not be read ────────────────
# Under Monitor, PR_REVIEW_READY is what reaches the session. Printing it and
# then exiting 2 tells the session to act while telling the shell it could not
# be read — and the line is what gets noticed.
seq_set reviewed
out="$(VERDICT='verdict=error reason=unreadable' VERDICT_RC=2 run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
    && die "an unreadable verdict still emitted the READY signal: $out" \
    || pass "no READY line when the verdict could not be read"
[ "$rc" -eq 2 ] && pass "and it exits 2" || die "unreadable verdict gave rc=$rc"

# Any non-0/1 verdict status is unreadable, not just the documented 2 — the same
# class the state probe guards, on the second call.
for vrc_case in 2 126 127 3; do
    seq_set reviewed
    out="$(VERDICT='verdict=error' VERDICT_RC=$vrc_case run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "a verdict helper exiting $vrc_case => 2" \
        || die "verdict rc=$vrc_case gave rc=$rc"
    printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
        && die "verdict rc=$vrc_case still emitted the READY signal" \
        || pass "verdict rc=$vrc_case emitted no READY signal"
done
# rc 1 IS an answer — "not clean" — and must still be reported as actionable.
seq_set reviewed
out="$(VERDICT='verdict=findings findings=3' VERDICT_RC=1 run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
{ printf '%s' "$out" | grep -q 'PR_REVIEW_READY' && printf '%s' "$out" | grep -q 'findings=3'; } \
    && pass "a not-clean verdict is still an actionable READY" \
    || die "rc 1 was treated as unreadable (rc=$rc out='$out')"

# ── an option without its value is usage, not an infinite loop ─────────────
# `shift 2 || true` left the same option in $1 and the parser span forever,
# hanging the watch before it started. Run under `timeout` so a regression fails
# the suite instead of freezing it.
for opt in --interval --timeout; do
    timeout 5 env PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" \
        "$SCRIPT" 7 "$BOT" "$opt" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 2 ] && pass "$opt without a value => 2 (no hang)" \
        || die "$opt without a value gave rc=$rc (124 = it hung)"
done

# ── leading-zero intervals are octal in Bash arithmetic ────────────────────
# `00` made sleep return at once and `waited` never advance — a spin — and
# `08`/`09` aborted inside the arithmetic. Both must fall back to the default.
seq_set none
for bad in 00 08 09; do
    start=$(date +%s)
    timeout 20 env PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" \
        "$SCRIPT" 7 "$BOT" --interval "$bad" --timeout 1 >/dev/null 2>&1; rc=$?
    elapsed=$(( $(date +%s) - start ))
    { [ "$rc" -eq 1 ] && [ "$elapsed" -lt 20 ]; } \
        && pass "--interval $bad falls back rather than spinning or aborting" \
        || die "--interval $bad gave rc=$rc after ${elapsed}s"
done

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
