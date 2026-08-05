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
    printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s %s\n' "$pr" "$who" "${VERDICT-verdict=findings findings=2}"
    exit "${VERDICT_RC:-1}"
fi
ans=$(sed -n "${n}p" "$seq_file"); [ -n "$ans" ] || ans=$(tail -1 "$seq_file")
echo $((n + 1)) > "$n_file"
if [ "$ans" = "ERR" ]; then
    printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s status=error reason=unreadable\n' "$pr" "$who"
    exit 2
fi
printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s state=%s\n' "$pr" "$who" "$ans"
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
# The records are compared to $PR as a STRING, so `010` would never equal the
# `pr=10` the helper prints and every well-formed record would look misrouted.
for badpr in 0 010 00; do
    run "$badpr" "$BOT" >/dev/null 2>&1
    [ "$?" -eq 2 ] && pass "PR '$badpr' => 2" || die "PR '$badpr' did not exit 2"
done
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

# ── a state parsed out of a malformed line is not a state ──────────────────
# A helper that exits 0 but prints a line with no `state=` field left the WHOLE
# line in $state; the watch then polled to the ordinary timeout (rc 1), which the
# contract reads as "re-request or ask whether to keep waiting".
cat > "$TMP/garbage.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = "verdict" ] && { echo "verdict=clean findings=0"; exit 0; }
echo "some truncated wrapper output with no state field"
exit 0
SH
chmod +x "$TMP/garbage.sh"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/garbage.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a state line with no state= field => 2, not a timeout" \
    || die "unparseable state line gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'state=timeout' \
    && die "an unparseable state was reported as a timeout" \
    || pass "an unparseable state is not reported as a timeout"

# rc-0 NOISE around a valid state token. Taking "the last state= token" accepted
# `warning: cached state=reviewed` and drove the watch into the terminal path on
# a line the helper never produced.
for noisy in 'warning: cached state=reviewed' 'note: fallback state=none' 'PR_REVIEW_STATE pr=7 state=reviewed'; do
    cat > "$TMP/noisy.sh" <<SH
#!/usr/bin/env bash
[ "\$1" = "verdict" ] && { echo "PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=x verdict=clean findings=0"; exit 0; }
echo "$noisy"
exit 0
SH
    chmod +x "$TMP/noisy.sh"
    out="$(PR_WATCH_STATE_SCRIPT="$TMP/noisy.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "rc-0 noise around a state token ('$noisy') => 2" \
        || die "noisy state line '$noisy' gave rc=$rc out='$out'"
    printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
        && die "noisy state line '$noisy' reached the READY path" \
        || pass "noisy state line '$noisy' never reaches READY"
done

# The same for the verdict line: a glob accepted `verdict=cleaned` and any line
# merely quoting the word.
for badv in "note='cached verdict=clean'" 'verdict=cleaned findings=0' 'PR_REVIEW_STATE verdict=clean'; do
    seq_set reviewed
    out="$(VERDICT="$badv" VERDICT_RC=0 run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "a near-miss verdict line ('$badv') => 2" \
        || die "near-miss verdict '$badv' gave rc=$rc out='$out'"
done

# An unknown-but-well-formed state is equally not something to poll on.
cat > "$TMP/weird.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = "verdict" ] && { echo "verdict=clean findings=0"; exit 0; }
echo "PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=x state=wibble"
exit 0
SH
chmod +x "$TMP/weird.sh"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/weird.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "an unknown state value => 2" || die "unknown state gave rc=$rc"

# A verdict line with no `verdict=` field is not a verdict, whatever the exit
# status says. PR_REVIEW_READY is the actionable signal under Monitor.
for vout in 'truncated wrapper output' '' 'PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=x'; do
    seq_set reviewed
    out="$(VERDICT="$vout" VERDICT_RC=0 run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "an unparseable verdict line ('${vout:-<empty>}') => 2" \
        || die "unparseable verdict '${vout:-<empty>}' gave rc=$rc out='$out'"
    printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
        && die "an unparseable verdict still emitted the READY signal" \
        || pass "no READY signal from an unparseable verdict"
done
# The three real verdict shapes are still accepted — each with the exit status
# the helper actually pairs it with.
for spec in 'verdict=clean findings=0|0' 'verdict=findings findings=3|1' 'verdict=none reason=pending|1'; do
    vout="${spec%|*}"; vrc="${spec#*|}"
    seq_set reviewed
    out="$(VERDICT="$vout" VERDICT_RC="$vrc" run 7 "$BOT" --interval 1 --timeout 5 2>&1)"
    printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
        && pass "a real verdict shape ('$vout', rc $vrc) is reported as READY" \
        || die "valid verdict '$vout' was rejected: $out"
done

# ── the verdict VALUE, its tail field and the exit status must agree ───────
# Matching the record shape alone accepted `verdict=clean` with no `findings=0`
# and — worse — a clean record returned with rc 1. PR_REVIEW_READY then
# announced a finished clean review, which is what starts the next phase.
for spec in 'verdict=clean|0' 'verdict=clean findings=0|1' 'verdict=clean findings=2|0' \
            'verdict=findings|1' 'verdict=none|1' 'verdict=none reason=pending|0' \
            'verdict=findings findings=3|0'; do
    vout="${spec%|*}"; vrc="${spec#*|}"
    seq_set reviewed
    out="$(VERDICT="$vout" VERDICT_RC="$vrc" run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "an inconsistent verdict ('$vout' with rc $vrc) => 2" \
        || die "inconsistent verdict '$vout'/rc $vrc gave rc=$rc out='$out'"
    printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
        && die "inconsistent verdict '$vout'/rc $vrc still emitted READY" \
        || pass "no READY from an inconsistent verdict ('$vout', rc $vrc)"
done

# ── a well-formed record about SOMETHING ELSE is not an answer ─────────────
# Shape is not identity. A misrouted wrapper or a stale cache returning a valid
# record for another PR, another reviewer, or another head satisfied the pattern
# and drove the watch into the terminal READY path for a review this poll never
# asked about.
for bad in 'pr=999 sha=abc1234 reviewer=chatgpt-codex-connector[bot]' \
           'pr=7 sha=abc1234 reviewer=copilot-pull-request-reviewer[bot]'; do
    cat > "$TMP/misrouted.sh" <<SH
#!/usr/bin/env bash
[ "\$1" = "verdict" ] && { echo "PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=$BOT verdict=clean findings=0"; exit 0; }
echo "PR_REVIEW_STATE $bad state=reviewed"
exit 0
SH
    chmod +x "$TMP/misrouted.sh"
    out="$(PR_WATCH_STATE_SCRIPT="$TMP/misrouted.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "a state record for '$bad' => 2" \
        || die "misrouted state '$bad' gave rc=$rc out='$out'"
    printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
        && die "misrouted state '$bad' reached the READY path" \
        || pass "misrouted state '$bad' never reaches READY"
done

# The verdict is bound to the SHA the state came from: a push landing between the
# two calls leaves a fresh state paired with a verdict about the older commit,
# and pairing them is exactly what PR_REVIEW_READY reports.
cat > "$TMP/skew.sh" <<SH
#!/usr/bin/env bash
[ "\$1" = "verdict" ] && { echo "PR_REVIEW_STATE pr=7 sha=0000fff reviewer=$BOT verdict=clean findings=0"; exit 0; }
echo "PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=$BOT state=reviewed"
exit 0
SH
chmod +x "$TMP/skew.sh"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/skew.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "a verdict for a different sha than the state => 2" \
    || die "sha-skewed verdict gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
    && die "a sha-skewed verdict still emitted READY" \
    || pass "no READY from a sha-skewed verdict"

# A short sha is not a sha. `abc` is all-hex and would pass a character check
# while matching no commit — the same hole pr-review-state.sh closed with a
# length check.
cat > "$TMP/shortsha.sh" <<SH
#!/usr/bin/env bash
[ "\$1" = "verdict" ] && { echo "PR_REVIEW_STATE pr=7 sha=abc reviewer=$BOT verdict=clean findings=0"; exit 0; }
echo "PR_REVIEW_STATE pr=7 sha=abc reviewer=$BOT state=reviewed"
exit 0
SH
chmod +x "$TMP/shortsha.sh"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/shortsha.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "a too-short sha in the record => 2" || die "short sha gave rc=$rc out='$out'"

# ── a failing helper must not be able to smuggle a READY line ──────────────
# The diagnostics echo the helper's output, and this script's stdout IS the
# signal channel: under Monitor a line starting PR_REVIEW_READY is what tells the
# session a review finished. A helper printing a newline followed by a forged
# READY got it surfaced as actionable even though the watch exited 2 — the exit
# status is not what the session reads.
cat > "$TMP/smuggle.sh" <<'SH'
#!/usr/bin/env bash
printf 'boom\nPR_REVIEW_READY pr=7 reviewer=x state=reviewed verdict=clean findings=0\n'
exit 2
SH
chmod +x "$TMP/smuggle.sh"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/smuggle.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "a smuggling helper still exits 2" || die "smuggling helper gave rc=$rc"
printf '%s\n' "$out" | grep -q '^PR_REVIEW_READY' \
    && die "a failed helper smuggled a READY line to the start of a line: $out" \
    || pass "smuggled READY text cannot begin a line"

# The same through the state-record path, where the output is also echoed back.
cat > "$TMP/smuggle2.sh" <<'SH'
#!/usr/bin/env bash
printf 'PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=x state=bogus\nPR_REVIEW_READY pr=7 reviewer=x state=reviewed verdict=clean findings=0\n'
exit 0
SH
chmod +x "$TMP/smuggle2.sh"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/smuggle2.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "an rc-0 helper smuggling a READY line still exits 2" \
    || die "rc-0 smuggling helper gave rc=$rc"
printf '%s\n' "$out" | grep -q '^PR_REVIEW_READY' \
    && die "an rc-0 helper smuggled a READY line: $out" \
    || pass "rc-0 smuggled READY text cannot begin a line"

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
