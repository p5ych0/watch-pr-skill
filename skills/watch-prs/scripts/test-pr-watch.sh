#!/usr/bin/env bash
# Unit tests for pr-watch.sh, with pr-review-state.sh stubbed.
#
# The watch is what replaces v1's response monitor, so the property that matters
# is the same one that mattered there: an unreadable state must not look like
# "still waiting", and a terminal state must surface exactly once with its
# verdict attached.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Portable watchdog: stock macOS ships no GNU `timeout`, and the suite is a
# mandatory pre-push gate.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
SCRIPT="$SELF_DIR/pr-watch.sh"
TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

BOT='chatgpt-codex-connector[bot]'

# The watch resolves ONE full head per poll and pins both probes to it, so every
# stub has to answer `head` with a 40-hex OID. Built rather than typed, so it is
# provably 40 characters and its abbreviation is provably the `sha=` the records
# below print.
export HEAD40="abc1234$(printf '%033d' 0)"
export OTHER40="0000fff$(printf '%033d' 0)"

# Every stub answers `head` the same way and only differs in its state/verdict
# behaviour, so the answer is prepended once here rather than copied into each.
# A stub that did not answer `head` would fail the watch before reaching the path
# it was written to exercise — and still exit 2, so it would look like it passed.
mkstub() {
    local p="$1"
    { printf '#!/usr/bin/env bash\n'
      printf '[ "$1" = "head" ] && { printf "%%s\\n" "${HEAD_OUT-$HEAD40}"; exit "${HEAD_RC:-0}"; }\n'
      cat
    } > "$p"
    chmod +x "$p"
}

# A stub whose answers come from a script file, one line per call:
#   "<state>" | "ERR" ; the verdict line is fixed.
mkstub "$TMP/state.sh" <<'SH'
cmd="$1"; pr="$2"; who="$3"
seq_file="$SEQ_FILE"; n_file="$SEQ_FILE.n"
n=$(cat "$n_file" 2>/dev/null || echo 1)
if [ "$cmd" = "head" ]; then
    printf '%s\n' "${HEAD_OUT-$HEAD40}"
    exit "${HEAD_RC:-0}"
fi
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
# ── TIME THE SUBJECT BELIEVES IN, WITHOUT WAITING FOR IT ───────────────────
# `pr-watch.sh` reads the clock with `date +%s` and paces itself with `sleep`,
# both external commands — so the fixture can own them without the subject
# changing at all. `sleep N` ADVANCES the clock by N and returns at once; `date`
# reports it. Time then passes exactly when the subject decides to wait, which is
# both instant and deterministic: the poll counts these cases assert stop
# depending on how loaded the runner is.
FASTCLOCK="$TMP/fastclock"; mkdir -p "$FASTCLOCK"
printf '1754000000\n' > "$TMP/now"
# Resolved BEFORE the stub directory can be on any PATH, and asserted, because a
# stub that cannot find the real thing would silently become the no-op this file
# exists to avoid.
REAL_SLEEP="$(command -v sleep)" \
    || { printf 'FAIL - no sleep on PATH\n'; echo "RESULT: FAIL"; exit 1; }
cat > "$FASTCLOCK/sleep" <<SLEEPSH
#!/usr/bin/env bash
# A WHOLE-SECOND SLEEP IS THE WATCH'S OWN PACING: move the clock, return at once.
#
# A FRACTIONAL ONE IS NOT. \`probe()\` ticks in fifths of a second, and each tick
# paces a REAL child — the helper the watch started a moment ago. Treating those
# as a successful no-op let the tick loop spend its whole \`limit * 5\` budget in
# microseconds and kill a healthy helper as a probe timeout, which is the
# load-dependent failure owning the clock is meant to REMOVE rather than move.
# So a fractional sleep really sleeps, and leaves the clock alone: the fake clock
# is the watch's pacing, and the probe's tick is not pacing, it is yielding.
#
# It yields for a SHORTER real interval than asked, uniformly. What the tick has
# to be is comfortably longer than the helper it waits on — these helpers are
# small Bash stubs that answer in about ten milliseconds — and 0.05 keeps that
# ratio at roughly five to one per tick, and twenty-five to one or better over a
# probe's whole budget, while costing a quarter of what 0.2 does across the two
# hundred probes this file runs. What it must never be is zero, which is the
# defect above.
case "\${1:-}" in
    [0-9]*.[0-9]*) exec "$REAL_SLEEP" 0.05 ;;
    ''|*[!0-9]*)   exec "$REAL_SLEEP" "\$@" ;;
esac
_c="\$(cat "\$FAKE_NOW" 2>/dev/null || echo 0)"
printf '%s\n' "\$((_c + \$1))" > "\$FAKE_NOW"
exit 0
SLEEPSH
cat > "$FASTCLOCK/date" <<'DATESH'
#!/usr/bin/env bash
# Only `+%s` is faked; anything else is the real thing, so a case that formats a
# date still gets one.
case "${1:-}" in
    +%s) cat "$FAKE_NOW" 2>/dev/null || exit 1 ;;
    *)   exec /usr/bin/env -u PATH /bin/date "$@" ;;
esac
DATESH
chmod +x "$FASTCLOCK/sleep" "$FASTCLOCK/date"
run() { PATH="$FASTCLOCK:$PATH" FAKE_NOW="$TMP/now" \
        PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" HEAD40="$HEAD40" "$SCRIPT" "$@"; }
seq_set() { printf '%s\n' "$@" > "$TMP/seq"; rm -f "$TMP/seq.n"; }

# ── a terminal state ends the watch, with its verdict ──────────────────────
seq_set none none reviewed
out="$(run 7 "$BOT" --interval 1 --timeout 30 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] || [ "$rc" -eq 0 ]; } && pass "watch exits when the state turns terminal" \
    || die "watch did not exit on a terminal state (rc=$rc)"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && pass "the terminal line is distinguishable (PR_REVIEW_READY)" \
    || die "no PR_REVIEW_READY line: $out"
grep -q 'findings=2' <<<"$out" \
    && pass "the verdict is reported without a second round-trip" \
    || die "the verdict was not attached: $out"

# ── it prints on CHANGE, not on every poll ─────────────────────────────────
seq_set none none none none pending reviewed
out="$(run 7 "$BOT" --interval 1 --timeout 30 2>&1)"
n_none=$(grep -c 'state=none' <<<"$out")
[ "$n_none" -eq 1 ] \
    && pass "a repeated state is reported once, not once per poll" \
    || die "state=none printed $n_none times"
grep -q 'state=pending' <<<"$out" \
    && pass "an intermediate state change is reported" || die "the pending transition was not shown"

# ── an unreadable state is NOT 'still waiting' ─────────────────────────────
seq_set none ERR reviewed
out="$(run 7 "$BOT" --interval 1 --timeout 30 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "an unreadable state exits 2 rather than polling on" \
    || die "unreadable state gave rc=$rc (must fail closed)"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "an unreadable state produced a READY line" \
    || pass "no READY line from an unreadable state"

# ── a clean verdict propagates 0 ───────────────────────────────────────────
seq_set reviewed
out="$(VERDICT='verdict=clean findings=0' VERDICT_RC=0 run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'verdict=clean' <<<"$out"; } \
    && pass "a clean verdict exits 0" || die "clean verdict gave rc=$rc out='$out'"

# An unreadable VERDICT after a terminal state must also fail closed.
seq_set reviewed
out="$(VERDICT='verdict=error reason=unreadable' VERDICT_RC=2 run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "an unreadable verdict after a terminal state => 2" \
    || die "unreadable verdict gave rc=$rc"

# ── the timeout is honoured and distinguishable ────────────────────────────
seq_set none
out="$(run 7 "$BOT" --interval 1 --timeout 2 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'state=timeout' <<<"$out"; } \
    && pass "the timeout exits 1 with a timeout line" || die "timeout gave rc=$rc out='$out'"
# …AND NO PROBE STARTS AFTER THE DEADLINE HAS PASSED — #46. The case above is
# satisfied by the wrong mechanism: `pr-watch.sh` reports a timeout from THREE
# places, and the two at the bottom of the loop catch that one. The third is the
# `[ "$r" -lt 1 ] && return 2` in `remaining_s`, which refuses to hand a probe a
# budget once the deadline is gone; widening it so it never fires produced ZERO
# failures across this file.
#
# It is not redundant with the other two. They run BEFORE the sleep, on a
# remainder that is still positive; the sleep is then clamped to land exactly on
# the deadline, and the next iteration begins with nothing left. Only this check
# stands between that and a probe — and a probe that answers `reviewed` there
# produces PR_REVIEW_READY, a verdict from after the watch should have given up.
#
# THE SEQUENCE IS WHAT MAKES IT VISIBLE, and why the case above cannot see it: it
# queues only `none`, so a probe running past the deadline answers `none` and
# looks like the timeout it is not. Here the next answer is `reviewed`, so the
# unguarded run reports a verdict and the guarded one reports a timeout.
#
# The arithmetic is exact and owned by the fixture: the first poll is at t=0 with
# 2 seconds left, the nap is clamped from 5 to 2, and the loop resumes at t=2 with
# a remainder of zero. No wall clock is involved, so this is not a race.
seq_set none reviewed
out="$(run 7 "$BOT" --interval 5 --timeout 2 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'state=timeout' <<<"$out"; } \
    && pass "an exhausted deadline is the timeout, not one more probe" \
    || die "a spent deadline gave rc=$rc out='$out'"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "a probe ran after the deadline and reported a verdict: $out" \
    || pass "…and no verdict was produced from after the deadline"

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
    mkstub "$TMP/broken.sh" <<SH
echo "some stderr noise" >&2
exit $rc_case
SH
    out="$(PR_WATCH_STATE_SCRIPT="$TMP/broken.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "a helper exiting $rc_case => 2, not a timeout" \
        || die "helper rc=$rc_case gave rc=$rc out='$out'"
    grep -q 'state=timeout' <<<"$out" \
        && die "helper rc=$rc_case was reported as a timeout" \
        || pass "helper rc=$rc_case is not reported as a timeout"
done

# ── READY must not precede a verdict that could not be read ────────────────
# Under Monitor, PR_REVIEW_READY is what reaches the session. Printing it and
# then exiting 2 tells the session to act while telling the shell it could not
# be read — and the line is what gets noticed.
seq_set reviewed
out="$(VERDICT='verdict=error reason=unreadable' VERDICT_RC=2 run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
grep -q 'PR_REVIEW_READY' <<<"$out" \
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
    grep -q 'PR_REVIEW_READY' <<<"$out" \
        && die "verdict rc=$vrc_case still emitted the READY signal" \
        || pass "verdict rc=$vrc_case emitted no READY signal"
done
# rc 1 IS an answer — "not clean" — and must still be reported as actionable.
seq_set reviewed
out="$(VERDICT='verdict=findings findings=3' VERDICT_RC=1 run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
{ grep -q 'PR_REVIEW_READY' <<<"$out" && grep -q 'findings=3' <<<"$out"; } \
    && pass "a not-clean verdict is still an actionable READY" \
    || die "rc 1 was treated as unreadable (rc=$rc out='$out')"

# ── a review of nothing but replies reaches the operator ──────────────────
# `source=replies-only` is a third verdict shape: the review carried comments, all
# of them replies, so `pr-findings.sh` lists nothing to fix and it is not a
# signoff. The whole point is that a human sees it — so the grammar has to accept
# it, and the tail has to survive into the READY line the Monitor surfaces. A
# strict tail that knew only ` findings=N` classified it as inconsistent, exited 2
# and printed no READY at all, which is the stop silently not happening.
seq_set reviewed
out="$(VERDICT='verdict=findings findings=1 source=replies-only' VERDICT_RC=1 \
        run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
{ grep -q 'PR_REVIEW_READY' <<<"$out" \
    && grep -q 'source=replies-only' <<<"$out"; } \
    && pass "a replies-only verdict is READY, and says so where the operator reads it" \
    || die "the replies-only stop did not surface (rc=$rc out='$out')"
# AND IT HAS ITS OWN STATUS, because every caller branches on status. Saying it
# only in the record left `pr-close-round.sh` — which waits on the pass a push
# starts and checks the status — taking the 0 and closing the round, which is the
# stop not happening.
[ "$rc" -eq 4 ] \
    && pass "…with a status of its own, so a caller that reads only the status still stops" \
    || die "a replies-only verdict exited $rc, which callers cannot tell from actionable"
# The ordinary findings verdict must NOT take that status.
seq_set reviewed
out="$(VERDICT='verdict=findings findings=3' VERDICT_RC=1 run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
    && pass "…while a verdict with real findings is still an ordinary actionable 0" \
    || die "a plain findings verdict exited $rc"

# AND THE GRAMMAR IS STILL A GRAMMAR. The tail is spelled out rather than made
# optional, so a field nobody agreed on is still refused — a trailing `.*` here
# would accept anything anyone ever appends, which is what this check exists to
# stop.
# THE ZERO-COUNT NEAR MISS IS THE ONE THAT MATTERED. A replies-only review HAS
# comments, so `findings=0 source=replies-only` is a different record — and the
# grammar used to accept it as an ordinary findings verdict and exit 0, where the
# shared predicate refuses it. A caller branching on the status then acted on an
# answer nothing had validated. #125.
for badtail in 'verdict=findings findings=1 source=whatever' \
               'verdict=findings findings=1 source=replies-only extra=1' \
               'verdict=findings findings=0 source=replies-only' \
               'verdict=findings findings= source=replies-only' \
               'verdict=findings findings=1 replies-only'; do
    seq_set reviewed
    out="$(VERDICT="$badtail" VERDICT_RC=1 run 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
    { [ "$rc" -eq 2 ] && grep -q 'inconsistent_verdict' <<<"$out"; } \
        && pass "…while an unagreed tail ('${badtail#verdict=findings }') is still refused" \
        || die "a malformed tail was accepted: '$badtail' (rc=$rc out='$out')"
done

# ── a state parsed out of a malformed line is not a state ──────────────────
# A helper that exits 0 but prints a line with no `state=` field left the WHOLE
# line in $state; the watch then polled to the ordinary timeout (rc 1), which the
# contract reads as "re-request or ask whether to keep waiting".
mkstub "$TMP/garbage.sh" <<'SH'
[ "$1" = "verdict" ] && { echo "verdict=clean findings=0"; exit 0; }
echo "some truncated wrapper output with no state field"
exit 0
SH
out="$(PR_WATCH_STATE_SCRIPT="$TMP/garbage.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a state line with no state= field => 2, not a timeout" \
    || die "unparseable state line gave rc=$rc out='$out'"
grep -q 'state=timeout' <<<"$out" \
    && die "an unparseable state was reported as a timeout" \
    || pass "an unparseable state is not reported as a timeout"

# rc-0 NOISE around a valid state token. Taking "the last state= token" accepted
# `warning: cached state=reviewed` and drove the watch into the terminal path on
# a line the helper never produced.
for noisy in 'warning: cached state=reviewed' 'note: fallback state=none' 'PR_REVIEW_STATE pr=7 state=reviewed'; do
    mkstub "$TMP/noisy.sh" <<SH
[ "\$1" = "verdict" ] && { echo "PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=x verdict=clean findings=0"; exit 0; }
echo "$noisy"
exit 0
SH
    out="$(PR_WATCH_STATE_SCRIPT="$TMP/noisy.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "rc-0 noise around a state token ('$noisy') => 2" \
        || die "noisy state line '$noisy' gave rc=$rc out='$out'"
    grep -q 'PR_REVIEW_READY' <<<"$out" \
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
mkstub "$TMP/weird.sh" <<'SH'
[ "$1" = "verdict" ] && { echo "verdict=clean findings=0"; exit 0; }
echo "PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=x state=wibble"
exit 0
SH
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
    grep -q 'PR_REVIEW_READY' <<<"$out" \
        && die "an unparseable verdict still emitted the READY signal" \
        || pass "no READY signal from an unparseable verdict"
done
# The verdict shapes that AGREE with the state are accepted — each with the exit
# status the helper actually pairs it with.
for spec in 'verdict=clean findings=0|0|reviewed' 'verdict=findings findings=3|1|reviewed' \
            'verdict=findings findings=1 source=replies-only|1|reviewed' \
            'verdict=none reason=blocked|1|blocked' 'verdict=none reason=dismissed|1|dismissed'; do
    vout="${spec%%|*}"; rest="${spec#*|}"; vrc="${rest%%|*}"; vstate="${rest#*|}"
    seq_set "$vstate"
    out="$(VERDICT="$vout" VERDICT_RC="$vrc" run 7 "$BOT" --interval 1 --timeout 5 2>&1)"
    grep -q 'PR_REVIEW_READY' <<<"$out" \
        && pass "a verdict agreeing with state=$vstate ('$vout') is reported as READY" \
        || die "valid verdict '$vout' for state=$vstate was rejected: $out"
done

# ── the verdict must describe the state the terminal branch was entered on ─
# State and verdict are two separate fetches, and the review can move between
# them without the head moving: a re-review opens and `reviewed` becomes
# PENDING, or a CHANGES_REQUESTED is superseded. The verdict then legitimately
# reports the NEW state while $state still holds the old one, and announcing
# PR_REVIEW_READY on that pair reports a pass that is not finished.
#
# This case was previously asserted the WRONG WAY ROUND — `state=reviewed` with
# `reason=pending` was accepted as READY.
for spec in 'reviewed|verdict=none reason=pending|1' \
            'reviewed|verdict=none reason=dismissed|1' \
            'reviewed|verdict=none reason=review_state_changed|1' \
            'blocked|verdict=clean findings=0|0' \
            'blocked|verdict=none reason=dismissed|1' \
            'dismissed|verdict=findings findings=2|1'; do
    vstate="${spec%%|*}"; rest="${spec#*|}"; vout="${rest%%|*}"; vrc="${rest#*|}"
    seq_set "$vstate"
    out="$(VERDICT="$vout" VERDICT_RC="$vrc" run 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
    grep -q 'PR_REVIEW_READY' <<<"$out" \
        && die "state=$vstate with '$vout' was announced as READY: $out" \
        || pass "state=$vstate with '$vout' is not READY"
    grep -q 'state=moved_between_probes' <<<"$out" \
        && pass "…and the disagreement is reported rather than swallowed" \
        || die "no moved_between_probes line for state=$vstate / '$vout': $out"
    [ "$rc" -eq 1 ] \
        && pass "…and it keeps polling to the timeout rather than exiting 0" \
        || die "state=$vstate with '$vout' gave rc=$rc (1 = polled on, which is right)"
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
    grep -q 'PR_REVIEW_READY' <<<"$out" \
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
    mkstub "$TMP/misrouted.sh" <<SH
[ "\$1" = "verdict" ] && { echo "PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=$BOT verdict=clean findings=0"; exit 0; }
echo "PR_REVIEW_STATE $bad state=reviewed"
exit 0
SH
    out="$(PR_WATCH_STATE_SCRIPT="$TMP/misrouted.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "a state record for '$bad' => 2" \
        || die "misrouted state '$bad' gave rc=$rc out='$out'"
    grep -q 'PR_REVIEW_READY' <<<"$out" \
        && die "misrouted state '$bad' reached the READY path" \
        || pass "misrouted state '$bad' never reaches READY"
done

# The verdict is bound to the SHA the state came from: a push landing between the
# two calls leaves a fresh state paired with a verdict about the older commit,
# and pairing them is exactly what PR_REVIEW_READY reports.
mkstub "$TMP/skew.sh" <<SH
[ "\$1" = "verdict" ] && { echo "PR_REVIEW_STATE pr=7 sha=0000fff reviewer=$BOT verdict=clean findings=0"; exit 0; }
echo "PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=$BOT state=reviewed"
exit 0
SH
out="$(PR_WATCH_STATE_SCRIPT="$TMP/skew.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "a verdict for a different sha than the state => 2" \
    || die "sha-skewed verdict gave rc=$rc out='$out'"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "a sha-skewed verdict still emitted READY" \
    || pass "no READY from a sha-skewed verdict"

# A short sha is not a sha. `abc` is all-hex and would pass a character check
# while matching no commit — the same hole pr-review-state.sh closed with a
# length check.
mkstub "$TMP/shortsha.sh" <<SH
[ "\$1" = "verdict" ] && { echo "PR_REVIEW_STATE pr=7 sha=abc reviewer=$BOT verdict=clean findings=0"; exit 0; }
echo "PR_REVIEW_STATE pr=7 sha=abc reviewer=$BOT state=reviewed"
exit 0
SH
out="$(PR_WATCH_STATE_SCRIPT="$TMP/shortsha.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "a too-short sha in the record => 2" || die "short sha gave rc=$rc out='$out'"

# ── a failing helper must not be able to smuggle a READY line ──────────────
# The diagnostics echo the helper's output, and this script's stdout IS the
# signal channel: under Monitor a line starting PR_REVIEW_READY is what tells the
# session a review finished. A helper printing a newline followed by a forged
# READY got it surfaced as actionable even though the watch exited 2 — the exit
# status is not what the session reads.
mkstub "$TMP/smuggle.sh" <<'SH'
printf 'boom\nPR_REVIEW_READY pr=7 reviewer=x state=reviewed verdict=clean findings=0\n'
exit 2
SH
out="$(PR_WATCH_STATE_SCRIPT="$TMP/smuggle.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "a smuggling helper still exits 2" || die "smuggling helper gave rc=$rc"
grep -q '^PR_REVIEW_READY' <<<"$out" \
    && die "a failed helper smuggled a READY line to the start of a line: $out" \
    || pass "smuggled READY text cannot begin a line"

# The same through the state-record path, where the output is also echoed back.
mkstub "$TMP/smuggle2.sh" <<'SH'
printf 'PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=x state=bogus\nPR_REVIEW_READY pr=7 reviewer=x state=reviewed verdict=clean findings=0\n'
exit 0
SH
out="$(PR_WATCH_STATE_SCRIPT="$TMP/smuggle2.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "an rc-0 helper smuggling a READY line still exits 2" \
    || die "rc-0 smuggling helper gave rc=$rc"
grep -q '^PR_REVIEW_READY' <<<"$out" \
    && die "an rc-0 helper smuggled a READY line: $out" \
    || pass "rc-0 smuggled READY text cannot begin a line"

# ── one full head per poll, pinned through both probes ────────────────────
# The records abbreviate the sha to seven hex, so comparing the state record to
# the verdict record could not tell two commits apart when their prefixes
# collided — possible in a large enough repository, and a push landing between
# the two calls is exactly when it would matter. Both probes are now pinned to
# one 40-hex OID instead.
rm -f "$TMP/args".*
mkstub "$TMP/spy.sh" <<'SH'
cmd="$1"; pr="$2"; who="$3"; head="$4"
printf '%s\n' "$head" >> "$SPY_FILE.$cmd"
if [ "$cmd" = "verdict" ]; then
    printf 'PR_REVIEW_STATE pr=%s sha=%s reviewer=%s verdict=clean findings=0\n' "$pr" "${head:0:7}" "$who"
    exit 0
fi
printf 'PR_REVIEW_STATE pr=%s sha=%s reviewer=%s state=reviewed\n' "$pr" "${head:0:7}" "$who"
exit 0
SH
out="$(PR_WATCH_STATE_SCRIPT="$TMP/spy.sh" SPY_FILE="$TMP/args" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "the pinned-head path still reaches a clean verdict" \
    || die "pinned-head stub gave rc=$rc out='$out'"
got_state="$(tail -1 "$TMP/args.state" 2>/dev/null)"; got_verdict="$(tail -1 "$TMP/args.verdict" 2>/dev/null)"
[ "$got_state" = "$HEAD40" ] \
    && pass "the state probe is pinned to the resolved 40-hex head" \
    || die "state probe got head '$got_state', not the resolved $HEAD40"
[ "$got_verdict" = "$HEAD40" ] \
    && pass "the verdict probe is pinned to the SAME 40-hex head" \
    || die "verdict probe got head '$got_verdict', not the resolved $HEAD40"

# Two heads sharing a seven-hex prefix are the case the comparison could not
# see. With both probes pinned there is nothing left to compare, so the record
# for the other commit is rejected on its own.
mkstub "$TMP/collide.sh" <<SH
cmd="\$1"; pr="\$2"; who="\$3"
if [ "\$cmd" = "verdict" ]; then
    # Same seven-hex prefix as HEAD40, different commit.
    printf 'PR_REVIEW_STATE pr=%s sha=%s reviewer=%s verdict=clean findings=0\n' "\$pr" "abc1234" "\$who"
    exit 0
fi
printf 'PR_REVIEW_STATE pr=%s sha=%s reviewer=%s state=reviewed\n' "\$pr" "abc1234" "\$who"
exit 0
SH
out="$(PR_WATCH_STATE_SCRIPT="$TMP/collide.sh" HEAD_OUT="abc1234$(printf '%033d' 1)" \
        "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
    && pass "a record abbreviating to the pinned head's prefix is accepted" \
    || die "prefix-matching record gave rc=$rc out='$out'"

# The head probe itself must fail closed: without a head there is nothing to pin
# to, and polling on would compare records against an empty string.
for spec in 'HEAD_RC=2' 'HEAD_OUT=abc1234' 'HEAD_OUT=' 'HEAD_OUT=zzzz' "HEAD_OUT=ABC1234$(printf '%033d' 0)"; do
    seq_set reviewed
    out="$(env "$spec" PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" \
            "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "an unusable head ($spec) => 2" \
        || die "unusable head $spec gave rc=$rc out='$out'"
    grep -q 'PR_REVIEW_READY' <<<"$out" \
        && die "an unusable head ($spec) still emitted READY" \
        || pass "no READY from an unusable head ($spec)"
done

# ── a verdict about a head that is no longer current is not READY ─────────
# Pinning made the state and the verdict describe the SAME commit. It did not
# make that commit CURRENT: a push landing after the head probe leaves both
# probes correctly describing the old head, and announcing that as READY advances
# the driver on a review of code that is no longer there.
#
# ── A FULL-WIDTH RECORD IS ACCEPTED ────────────────────────────────────────
# The identity check compares the record at ITS OWN WIDTH now, rather than
# against a `${head:0:7}` this script cut. Every other record in this file is
# seven hex, so a caller pinned back to seven would pass the whole suite —
# `test-recordlib.sh` proves what the library accepts and nothing about what this
# script asks it. #126.
cat > "$TMP/wide.sh" <<SH
#!/usr/bin/env bash
[ "\$1" = "head" ] && { printf '%s\n' "\$HEAD40"; exit 0; }
head="\$4"
if [ "\$1" = "verdict" ]; then
    printf 'PR_REVIEW_STATE pr=%s sha=%s reviewer=%s verdict=clean findings=0\n' "\$2" "\$head" "\$3"
    exit 0
fi
printf 'PR_REVIEW_STATE pr=%s sha=%s reviewer=%s state=reviewed\n' "\$2" "\$head" "\$3"
exit 0
SH
chmod +x "$TMP/wide.sh"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/wide.sh" HEAD40="$HEAD40" \
        "$SCRIPT" 7 "$BOT" --interval 1 --timeout 10 2>&1)"; rc=$?
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && pass "a state and verdict carrying the full forty-hex head are accepted" \
    || die "a full-width record was not accepted (rc=$rc): $out"
grep -q 'verdict=clean' <<<"$out" \
    && pass "…and the clean verdict is what it reports" \
    || die "the full-width verdict was not reported: $out"
grep -q 'identity_mismatch' <<<"$out" \
    && die "a full-width record was read as being about another head: $out" \
    || pass "…with no identity mismatch, since the width grew rather than the check weakening"

# Written without mkstub, which owns the `head` answer — this stub needs its own.
cat > "$TMP/moving.sh" <<SH
#!/usr/bin/env bash
if [ "\$1" = "head" ]; then
    n=\$(cat "\$MOVE_N" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$MOVE_N"
    # A different head every single call: the recheck can never match the pin.
    printf '%s%033d\n' "abc1234" "\$n"
    exit 0
fi
head="\$4"
if [ "\$1" = "verdict" ]; then
    printf 'PR_REVIEW_STATE pr=%s sha=%s reviewer=%s verdict=clean findings=0\n' "\$2" "\${head:0:7}" "\$3"
    exit 0
fi
printf 'PR_REVIEW_STATE pr=%s sha=%s reviewer=%s state=reviewed\n' "\$2" "\${head:0:7}" "\$3"
exit 0
SH
chmod +x "$TMP/moving.sh"
rm -f "$TMP/move.n"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/moving.sh" MOVE_N="$TMP/move.n" \
        "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "a verdict for a superseded head was announced as READY: $out" \
    || pass "a verdict for a superseded head is not announced as READY"
grep -q 'state=head_moved' <<<"$out" \
    && pass "the moved head is reported, so the wait is explainable" \
    || die "no head_moved line when the head changed mid-poll: $out"
[ "$rc" -eq 1 ] \
    && pass "a head that keeps moving times out rather than announcing a stale verdict" \
    || die "moving head gave rc=$rc (1 = timed out, which is the honest answer)"

# A head that moves ONCE still settles: the next poll asks about the new head and
# reports it. This is what keeps the recheck from being a permanent block.
cat > "$TMP/settling.sh" <<SH
#!/usr/bin/env bash
if [ "\$1" = "head" ]; then
    n=\$(cat "\$MOVE_N" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$MOVE_N"
    if [ "\$n" -le 1 ]; then printf '%s\n' "$HEAD40"; else printf '%s\n' "$OTHER40"; fi
    exit 0
fi
head="\$4"
if [ "\$1" = "verdict" ]; then
    printf 'PR_REVIEW_STATE pr=%s sha=%s reviewer=%s verdict=clean findings=0\n' "\$2" "\${head:0:7}" "\$3"
    exit 0
fi
printf 'PR_REVIEW_STATE pr=%s sha=%s reviewer=%s state=reviewed\n' "\$2" "\${head:0:7}" "\$3"
exit 0
SH
chmod +x "$TMP/settling.sh"
rm -f "$TMP/move.n"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/settling.sh" MOVE_N="$TMP/move.n" \
        "$SCRIPT" 7 "$BOT" --interval 1 --timeout 10 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'PR_REVIEW_READY' <<<"$out"; } \
    && pass "a head that moves once still reaches READY on the new head" \
    || die "settling head never reached READY (rc=$rc out='$out')"
grep -q "${OTHER40:0:7}" <<<"$out" \
    && pass "…and the verdict announced is the one for the NEW head" \
    || die "READY did not name the new head: $out"

# ── the deadline is wall-clock, not the sum of the sleeps ─────────────────
# Counting only the naps excluded every second spent inside the probes, so a run
# of slow GitHub reads made a one-hour watch run far past an hour. This stub
# takes ~2s per probe: with accumulated sleeps a 6s timeout at a 1s interval
# would need ~18s of real time to reach; against the clock it returns in ~6s.
mkstub "$TMP/slow.sh" <<'SH'
sleep 2
printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s state=none\n' "$2" "$3"
exit 0
SH
start=$(date +%s)
out="$(HEAD_SLOW=1 PR_WATCH_STATE_SCRIPT="$TMP/slow.sh" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 6 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" -eq 1 ] \
    && pass "a slow-probe watch still reaches its timeout" \
    || die "slow-probe watch gave rc=$rc out='$out'"
[ "$elapsed" -le 14 ] \
    && pass "…within the configured bound, because probe time counts against it" \
    || die "a 6s timeout took ${elapsed}s: probe time is escaping the deadline"
grep -q 'state=timeout' <<<"$out" \
    && pass "…and reports the timeout record" \
    || die "no timeout record from the slow-probe watch: $out"

# ── a probe that never returns must still hit the deadline ────────────────
# The elapsed checks only ran BETWEEN probes, so a `gh` that hung inside one
# blocked forever and the deadline was never reached at all. Each probe is now
# bounded by what is left of it.
mkstub "$TMP/hang.sh" <<'SH'
sleep 3600
SH
start=$(date +%s)
out="$(PR_WATCH_STATE_SCRIPT="$TMP/hang.sh" run_limited 60 "$SCRIPT" 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" -eq 1 ] \
    && pass "a probe that never returns still reaches the timeout" \
    || die "hanging probe gave rc=$rc after ${elapsed}s (124 = the watch itself hung) out='$out'"
[ "$elapsed" -le 20 ] \
    && pass "…within the configured bound" \
    || die "a 5s timeout took ${elapsed}s with a hanging probe"

# ── a probe that stalls short of the deadline is retried, not run to it ───
cat > "$TMP/stall.sh" <<'SH'
#!/usr/bin/env bash
once() { [ -e "$STALL_N.$1" ] && return 1; : > "$STALL_N.$1"; return 0; }
case "$1" in
    head)
        if [ -e "$STALL_N.verdict_answered" ] && once head-recheck; then sleep 3600; fi
        printf '%s\n' "$HEAD40"; exit 0 ;;
    state)
        once state && sleep 3600
        printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s state=reviewed\n' "$2" "$3"; exit 0 ;;
    review-id)
        once review-id && sleep 3600
        printf '99\n'; exit 0 ;;
    verdict)
        once verdict && sleep 3600
        : > "$STALL_N.verdict_answered"
        printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s verdict=findings findings=2\n' "$2" "$3"; exit 1 ;;
esac
exit 2
SH
chmod +x "$TMP/stall.sh"
rm -f "$TMP"/stall.n.*
start=$(date +%s)
out="$(STALL_N="$TMP/stall.n" PR_WATCH_PROBE_TIMEOUT=1 PR_WATCH_STATE_SCRIPT="$TMP/stall.sh" \
       run_limited 90 "$SCRIPT" 7 "$BOT" --after-review 5 --interval 1 --timeout 30 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - start ))
{ [ "$rc" -eq 0 ] && grep -q 'PR_REVIEW_READY' <<<"$out"; } \
    && pass "probes stalled short of the deadline are retried and the watch reaches the verdict" \
    || die "stalled probes gave rc=$rc after ${elapsed}s: out='$out'"
for _p in state review-id verdict head; do
    grep -q "state=probe_stalled probe=$_p limit_s=1" <<<"$out" \
        && pass "…and the stalled $_p probe is reported, naming the probe and its bound" \
        || die "no probe_stalled record for the stalled $_p probe: $out"
done
[ "$(grep -c 'state=probe_stalled' <<<"$out")" -eq 4 ] \
    && pass "…once each, the head recheck being the head read that stalled" \
    || die "expected four stall records, one per probe: $out"
[ "$elapsed" -le 25 ] \
    && pass "…having cost the bound rather than the deadline" \
    || die "four 1s probe bounds took ${elapsed}s to recover from"
# A stall on every call still counts against the deadline: the retry is bounded by it.
mkstub "$TMP/stall-all.sh" <<'SH'
sleep 3600
SH
start=$(date +%s)
out="$(PR_WATCH_PROBE_TIMEOUT=1 PR_WATCH_STATE_SCRIPT="$TMP/stall-all.sh" \
       run_limited 60 "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - start ))
{ [ "$rc" -eq 1 ] && grep -q 'state=timeout' <<<"$out"; } \
    && pass "…and a probe that stalls on every retry still reaches the timeout" \
    || die "retried stalls escaped the deadline: rc=$rc after ${elapsed}s out='$out'"
grep -q 'state=probe_stalled' <<<"$out" \
    && pass "…with the stalls on record" \
    || die "the stalls before the timeout were not reported: $out"
[ "$elapsed" -le 15 ] \
    && pass "…within the configured bound" \
    || die "a 3s timeout took ${elapsed}s with stalling probes"
# ── a capped probe that crosses the deadline is the timeout, not a stall ──
# The stub moves the fake clock past the deadline and then holds the probe to its cap
# with the real sleep, so the 124 comes back with the watch already expired.
cat > "$TMP/cross.sh" <<SH
#!/usr/bin/env bash
[ "\$1" = head ] && { printf '%s\\n' "\$HEAD40"; exit 0; }
sleep 5
exec "$REAL_SLEEP" 3600
SH
chmod +x "$TMP/cross.sh"
printf '1754000000\n' > "$TMP/now"
out="$(run_limited 60 env PATH="$FASTCLOCK:$PATH" FAKE_NOW="$TMP/now" PR_WATCH_PROBE_TIMEOUT=1 \
       PR_WATCH_STATE_SCRIPT="$TMP/cross.sh" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'state=timeout' <<<"$out"; } \
    && pass "a capped probe that returns with the deadline passed is the timeout" \
    || die "a probe crossing the deadline gave rc=$rc: out='$out'"
grep -q 'probe_stalled' <<<"$out" \
    && die "a probe that crossed the deadline was reported as a stall to retry: $out" \
    || pass "…and is not reported as a stall first"

# ── a clock that prints and then fails is not a clock ─────────────────────
# `date` can print a plausible epoch and then exit non-zero, and the elapsed
# calculation hid that behind its own success — so elapsed time could stay
# ordinary-looking, or zero forever, and the watch would never time out.
CLOCKBIN="$TMP/clockbin"; mkdir -p "$CLOCKBIN"
printf '#!/usr/bin/env bash\nprintf "1700000000\\n"\nexit 1\n' > "$CLOCKBIN/date"
chmod +x "$CLOCKBIN/date"
# Inside the watchdog: `run_limited` reads the clock with its own `date` on the
# portable path, so a stub on the caller's PATH breaks the harness, not the
# subject — and only where GNU `timeout` is missing, which is exactly the
# platform this suite claims to support and never runs on.
out="$(run_limited 30 env PATH="$CLOCKBIN:$PATH" PR_WATCH_STATE_SCRIPT="$TMP/state.sh" \
       SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a clock read that prints and then fails => 2" \
    || die "failing clock gave rc=$rc out='$out'"
grep -q 'clock_unreadable' <<<"$out" \
    && pass "…reported as an unreadable clock" \
    || die "the failing clock was not named: $out"

# ── a same-head re-request waits for a NEW review ─────────────────────────
# After a dismissal, or after answering a finding, the head does not change — so
# the first poll saw the PREVIOUS terminal review and reported it as this round's
# answer. With --after-review the old one is not enough.
mkstub "$TMP/samehead.sh" <<'SH'
cmd="$1"
if [ "$cmd" = "review-id" ]; then printf '%s\n' "${CUR_ID:-99}"; exit 0; fi
if [ "$cmd" = "verdict" ]; then
    printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s verdict=clean findings=0\n' "$2" "$3"; exit 0
fi
printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s state=reviewed\n' "$2" "$3"
exit 0
SH
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review 99 --interval 1 --timeout 4 2>&1)"; rc=$?
[ "$rc" -eq 1 ] \
    && pass "a terminal state that is still the pre-request review is not READY" \
    || die "same-head stale review gave rc=$rc out='$out'"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "the previous review was announced as this round's: $out" \
    || pass "…and no READY line is emitted for it"
grep -q 'state=awaiting_new_review' <<<"$out" \
    && pass "…and the wait is explainable" \
    || die "no awaiting_new_review line: $out"

# A NEW review id on the same head is the answer.
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=100 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review 99 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'PR_REVIEW_READY' <<<"$out"; } \
    && pass "a new review on the same head IS reported" \
    || die "new same-head review gave rc=$rc out='$out'"

# Without the flag the behaviour is unchanged, so existing callers are unaffected.
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --interval 1 --timeout 6 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
    && pass "without --after-review the terminal state is reported as before" \
    || die "the flagless path changed behaviour (rc=$rc out='$out')"

# ── a reviewer this loop does not drive is refused, not polled ────────────
#
# The login arrives from `SKILL.md`'s own shell, where it is a variable an operator's
# startup file can have aimed elsewhere — a nameref onto a path hands this stage a FILE
# NAME as the reviewer. Nothing here can prove what happened in that shell, and guarding
# the driver one name at a time is the shape this repository records paying for twice.
# What this process can do is refuse a login that is nobody. Unrecognised, the watch
# polled to its deadline and reported a TIMEOUT, which the driver re-arms — so a
# corrupted reviewer looked exactly like a slow one, indefinitely.
out="$(run_limited 30 "$SCRIPT" 7 "/tmp/some/baseline/path" --interval 1 --timeout 4 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=unknown_reviewer' <<<"$out"; } \
    && pass "a reviewer this loop does not drive is refused before the first poll" \
    || die "an unknown reviewer gave rc=$rc out='$out'"
grep -q 'state=timeout' <<<"$out" \
    && die "an unknown reviewer was reported as a timeout, which the driver re-arms: $out" \
    || pass "…and is not reported as a timeout"
# AND BOTH REAL REVIEWERS ARE ACCEPTED, or the check above passes by refusing everyone.
for _wr in "$BOT" "copilot-pull-request-reviewer[bot]"; do
    out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=100 \
           run_limited 30 "$SCRIPT" 7 "$_wr" --interval 1 --timeout 6 2>&1)"; rc=$?
    grep -q 'reason=unknown_reviewer' <<<"$out" \
        && die "$_wr was refused as an unknown reviewer: $out" \
        || pass "…while $_wr is accepted"
done

# ── the same baseline, arriving in a FILE ─────────────────────────────────
#
# `SKILL.md`'s bash runs in the operator's own shell, where an assignment can be
# defeated by a readonly name, a nameref or a transforming attribute — so the driver
# used to read this value back into `PRIOR_REVIEW` behind an assignability probe, a
# read-back comparison and a four-arm shape check that was a second, weaker copy of
# the validation below. The value has one consumer, so it crosses in a file and is
# read here. `--after-review` stays for a caller holding the id in a hardened process
# of its own — `pr-close-round.sh` waiting on the pass its own push started. #243.
_bl="$TMP/baseline"

printf '5551 99\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 4 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'state=awaiting_new_review' <<<"$out"; } \
    && pass "a baseline read from a file holds back the stale review, exactly as the value form does" \
    || die "the file form did not hold back a stale review (rc=$rc out='$out')"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "the previous review was announced as this round's: $out" \
    || pass "…and no READY line is emitted for it"

# A NEW review on the same head is still the answer, so the file form is not simply
# refusing everything — which is how a baseline check passes a stale-review case
# while being broken.
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=100 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'PR_REVIEW_READY' <<<"$out"; } \
    && pass "…while a new review on that head is still reported" \
    || die "the file form rejected a new review (rc=$rc out='$out')"

# THE TRAILING NEWLINE A WRITER LEAVES IS NOT PART OF THE ID. Every writer uses
# `printf '%s\n'`, and the comparison is a string equality against an id with none —
# so a baseline that kept its newline would never match, and the watch would report
# the stale review as this round's answer. `$(<…)` strips it; this is the case that
# says so.
printf '5551 99\n\n\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 4 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'state=awaiting_new_review' <<<"$out"; } \
    && pass "…and trailing newlines are not part of the id" \
    || die "a baseline with trailing newlines did not match (rc=$rc out='$out')"

# AND `pr-copilot-phase.sh`'S REFUSAL SENTINEL IS REFUSED, WHICH IS THE POINT OF IT. That
# stage writes a readiness value into this same file before it revokes anything, and a
# refusal between that write and the real one leaves the sentinel behind. It must NOT read
# as a baseline: with the driver's `exit` shadowed to return, a refused `open` reaches this
# watch, and an EMPTY file there WOULD have been taken as "no prior review" and let a
# terminal verdict through as this round's answer — a pass that was never requested. Since
# #264 an empty file is refused here on its own account; the sentinel is refused as well,
# for not being a review id, and it says WHY rather than leaving the watch to infer it.
#
# THE TWO HALVES ARE PINNED TOGETHER: the phase fixture asserts the exact string the stage
# leaves, and this asserts the same string is refused here. Change one and the other fails.
printf '5551 refused-no-baseline\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=malformed_review_id' <<<"$out"; } \
    && pass "…and the phase's refusal sentinel is refused, not read as a baseline" \
    || die "the refusal sentinel was not refused (rc=$rc out='$out')"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "a terminal verdict was announced against the refusal sentinel: $out" \
    || pass "…with no verdict announced for it"

# "NOTHING TO WAIT PAST" IS SPELLED `none`, AND AN EMPTY FILE IS A REFUSAL — #264.
#
# Empty used to BE that value, which made it indistinguishable from a failure: every writer
# truncates this file before writing it, so any failure in between left the legal no-floor
# value, and with the driver's `exit` shadowed to return a refused stage armed this watch
# with no floor at all. The state is real and still expressible, by a token a writer has to
# produce on purpose.
printf '5551 none\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'PR_REVIEW_READY' <<<"$out"; } \
    && pass "…the none token means 'nothing to wait past' and the review is reported" \
    || die "the none token was not treated as no baseline (rc=$rc out='$out')"

# AND AN EMPTY FILE IS REFUSED, which is the half that makes the token worth having. This
# is the state a truncation leaves, and taking it as "no floor" is the fail-open #264
# closes — so it must be an error rather than an answer, and it must not announce a verdict.
: > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=empty_after_review_file' <<<"$out"; } \
    && pass "…while an EMPTY baseline file is refused, since a truncation produces it" \
    || die "an empty baseline file was not refused (rc=$rc out='$out')"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "a verdict was announced against an empty baseline file: $out" \
    || pass "…with no verdict announced for it"

# AND A WRITE THAT STOPPED BEFORE ITS NEWLINE IS REFUSED, WHICH IS WHAT MAKES THE TOKEN
# WORTH ANYTHING. Every writer ends with `printf '%s\n'`, so the trailing newline is the
# completion delimiter: a write that failed part-way — a full filesystem, a quota reached
# mid-flush — leaves the value without it.
#
# WITHOUT THAT CHECK THE TOKEN IS FAKEABLE BY THE VERY FAILURE IT EXISTS FOR: a `none`
# whose newline never landed reads as the deliberate no-floor value, since a command
# substitution discards trailing newlines and the bare prefix is indistinguishable from a
# finished write. Staged for BOTH shapes, because an id has the same defect and is the one
# an earlier reading of this change missed — `123` truncated from `1234` is a well-formed
# id that no shape test can reject.
# AND A FILE HOLDING ONLY THE DELIMITER IS EMPTY TOO. It passes the empty-FILE check,
# since it has a byte in it, and strips to nothing — so without a second look the shape
# test accepts it as "no floor" and the fail-open returns one step later. This is the exact
# shape `printf '%s\n' ""` produces, which is what every writer emitted before this change,
# so a file left by an older plugin or by a caller written against the old contract has it.
printf '\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=empty_after_review_file' <<<"$out"; } \
    && pass "…and a file holding only the delimiter is refused as empty" \
    || die "a newline-only baseline file was not refused (rc=$rc out='$out')"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "a verdict was announced against a newline-only baseline: $out" \
    || pass "…with no verdict announced for it"

for _un_v in none 4321; do
    printf '5551 %s' "$_un_v" > "$_bl"
    out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
           run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
    { [ "$rc" -eq 2 ] && grep -q 'reason=unterminated_after_review_file' <<<"$out"; } \
        && pass "…and a '$_un_v' written without its terminating newline is refused" \
        || die "an unterminated '$_un_v' baseline was not refused (rc=$rc out='$out')"
    grep -q 'PR_REVIEW_READY' <<<"$out" \
        && die "a verdict was announced against an unterminated baseline: $out" \
        || pass "…with no verdict announced for it"
done

# AND A FILE THAT CANNOT BE READ IS state=error, NOT A BASELINE. Degrading to empty made
# a failed read say exactly what the no-floor case above said, and the watch would then
# accept the previous terminal review as this round's — the whole failure the baseline
# exists to prevent, arriving through the read instead of through the absence of a flag.
# Since #264 empty is itself refused, so the two collide no longer; the reason for a
# distinct status is unchanged, because an operator has to be told which recovery applies.
rm -f "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=after_review_file_unreadable' <<<"$out"; } \
    && pass "…while a missing baseline file is state=error, not an empty baseline" \
    || die "a missing baseline file gave rc=$rc out='$out'"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "a failed baseline read still announced a review: $out" \
    || pass "…and announces no review"

if [ "$(id -u)" != 0 ]; then
    printf '5551 99\n' > "$_bl"; chmod 000 "$_bl"
    out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
           run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
    chmod 600 "$_bl"
    { [ "$rc" -eq 2 ] && grep -q 'reason=after_review_file_unreadable' <<<"$out"; } \
        && pass "…and so is an unreadable one" \
        || die "an unreadable baseline file gave rc=$rc out='$out'"
else
    pass "running as root, so the unreadable-baseline state is skipped by name"
fi

# A FIFO AT THAT PATH DOES NOT HANG THE WATCH. `9<` on a FIFO blocks waiting for a
# writer, and the `-f` test that rejects it is on the far side of the redirection, so
# it never runs — the watch stayed silent past its own `--timeout` and had to be killed
# from outside. The open runs under the same watchdog every other probe here uses now.
# The case is bounded by the harness too, so a regression HANGS the fixture rather than
# the suite.
if command -v mkfifo >/dev/null 2>&1; then
    rm -f "$_bl"; mkfifo "$_bl" 2>/dev/null && {
        # THE DEADLINE IS LONGER THAN THE READ'S OWN LIMIT, so this case exercises the
        # BLOCKED answer. With a shorter one the deadline expires first and the run is
        # an ordinary timeout — which is the case below, and the two must not be the
        # same fixture or whichever answer the clock happens to produce passes.
        out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
               run_limited 60 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 40 2>&1)"; rc=$?
        { [ "$rc" -eq 2 ] && grep -qE 'reason=after_review_file_(blocked|not_regular)' <<<"$out"; } \
            && pass "…and a FIFO at the baseline path is state=error rather than a hang" \
            || die "a FIFO baseline path gave rc=$rc out='$out'"
        grep -q 'PR_REVIEW_READY' <<<"$out" \
            && die "a blocked baseline read still announced a review: $out" \
            || pass "…announcing no review"
    }
    rm -f "$_bl"
else
    pass "no mkfifo on this platform, so the FIFO state is skipped by name"
fi

# AND A SHORT DEADLINE MAKES THAT EXPIRY THE ORDINARY TIMEOUT. The probe's own limit
# is capped by the watch's remaining budget, so with `--timeout 1` a blocked open
# exhausts the DEADLINE rather than the read's own allowance — and that is status 1,
# which the driver re-arms, not `state=error`, which stops the round over a clock the
# caller set. The two answers have to stay apart or `--timeout` decides whether a
# stuck file is reported as one.
if command -v mkfifo >/dev/null 2>&1; then
    rm -f "$_bl"; mkfifo "$_bl" 2>/dev/null && {
        out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
               run_limited 45 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 1 2>&1)"; rc=$?
        [ "$rc" -eq 1 ] \
            && pass "…and with a deadline shorter than the read's own limit it is the ordinary timeout" \
            || die "a short-deadline blocked baseline gave rc=$rc out='$out'"
        grep -q 'state=timeout' <<<"$out" \
            && pass "…reported as a timeout rather than an unreadable state" \
            || die "no timeout record for the short-deadline blocked read: $out"
    }
    rm -f "$_bl"
else
    pass "no mkfifo on this platform, so the short-deadline block is skipped by name"
fi

# AND A NUL BYTE IS NOT AN EMPTY BASELINE. `$(<file)` DROPS NUL bytes, so a file
# holding one read back as the empty string — which was the legitimate "no prior review
# to wait past" when this was written — and the watch announced the terminal review this
# round just handled as the next one. Since #264 empty is refused too, so this would now
# be caught either way; the case stays because it pins the READ rather than the shape, and
# a NUL dropped in silence is a file the reader cannot claim to have understood. Asserted
# on the CONSEQUENCE as well as the reason: no READY line.
printf '\000' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=after_review_file_nul' <<<"$out"; } \
    && pass "…and a NUL-only baseline file is refused, not read as an empty baseline" \
    || die "a NUL-only baseline file gave rc=$rc out='$out'"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "a NUL baseline let the stale review through as this round's: $out" \
    || pass "…announcing no review"
# AND A NUL BESIDE A REAL ID IS REFUSED TOO, so the check is about the byte rather
# than about the value happening to come out empty.
printf '99\000\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=after_review_file_nul' <<<"$out"; } \
    && pass "…including a NUL beside an otherwise valid id" \
    || die "a NUL beside an id gave rc=$rc out='$out'"

# A DIRECTORY IS NOT A REGULAR FILE EITHER, and the reason says which.
rm -f "$_bl"; mkdir -p "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -qE 'reason=after_review_file_(not_regular|unreadable)' <<<"$out"; } \
    && pass "…and a directory at the baseline path is state=error" \
    || die "a directory baseline path gave rc=$rc out='$out'"
rmdir "$_bl"

# A MALFORMED BASELINE IS REFUSED AT THE CALL, not an hour later. The four-arm check
# in the loop runs on the first TERMINAL state, which may be far away; a caller that
# handed over junk can still act on it now.
printf '5551 not-an-id\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=malformed_review_id' <<<"$out"; } \
    && pass "…and a malformed baseline is refused at the call, not on the first terminal state" \
    || die "a malformed baseline file gave rc=$rc out='$out'"
printf '5551 comment:\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=malformed_review_id' <<<"$out"; } \
    && pass "…including the comment channel named with no id" \
    || die "a bare 'comment:' baseline gave rc=$rc out='$out'"
printf '5551 comment:100\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=100 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
[ "$rc" -ne 2 ] \
    && pass "…while the comment-channel shape the round close writes is accepted" \
    || die "a comment:<id> baseline was refused: rc=$rc out='$out'"

# BOTH FORMS AT ONCE IS A REFUSAL, not a precedence rule. They are the same value by
# two routes, and a caller passing both has two answers and no reason to think this
# one picked the right half.
printf '5551 99\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review 99 --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=after_review_both_forms' <<<"$out"; } \
    && pass "…and passing both forms is refused rather than silently resolved" \
    || die "both baseline forms together gave rc=$rc out='$out'"

# AND AN EMPTY PATH IS REFUSED, WHICH IS NOT THE SAME AS A MISSING ARGUMENT. A caller
# expanding a name that was never assigned — `--after-review-file "$PRIOR_FILE"` —
# satisfies the argument count and hands over an empty string, which used to skip the
# read block entirely: the watch then ran with NO baseline and announced the
# already-terminal review as the new pass. That is the failure the baseline exists to
# prevent, reached by PASSING the option rather than by omitting it.
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "" --interval 1 --timeout 6 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "…and an empty baseline PATH is refused rather than silently unarming the watch" \
    || die "an empty --after-review-file path gave rc=$rc out='$out'"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "an empty baseline path let the stale review through: $out" \
    || pass "…announcing no review"
# AND THE VALUE FORM IS UNAFFECTED: an empty id there legitimately means "no prior
# review to wait past", which is what the automatic path and a first request carry.
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review "" --interval 1 --timeout 6 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
    && pass "…while an empty --after-review VALUE stays the legitimate 'no baseline' answer" \
    || die "an empty --after-review value was refused (rc=$rc out='$out')"

# AND AN EXPLICITLY EMPTY VALUE FORM STILL COUNTS AS SUPPLIED. `--after-review ""`
# is the legitimate "no prior review to wait past", so its emptiness cannot stand in
# for "not given" — a both-forms check reading the VALUE let this pair through, and
# the explicit "there is nothing to wait past" was discarded in favour of a file that
# can hold an id the watch then waits out its whole timeout for.
printf '5551 99\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review "" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=after_review_both_forms' <<<"$out"; } \
    && pass "…and an EMPTY value form still counts as supplied, so both together are refused" \
    || die "an empty --after-review beside a file gave rc=$rc out='$out'"

# AND THE OPTION NEEDS ITS VALUE. `shift 2` on a missing one left the same option in
# $1 and the parser span forever, which is the defect the other options already carry
# a case for.
out="$(run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'needs a value' <<<"$out"; } \
    && pass "…and a valueless --after-review-file is usage, not a hang" \
    || die "--after-review-file with no value gave rc=$rc out='$out'"

# ── the baseline is bound to its request by a nonce — #264, the half the token missed ──
#
# THE TOKEN TELLS A VALUE FROM NO VALUE; IT CANNOT TELL THIS ROUND'S VALUE FROM THE LAST
# ROUND'S. Both are well-formed ids written on purpose by a real run. With the driver's
# `exit` shadowed to return, a refusal in a writer's bootstrap left the PREVIOUS round's
# baseline in place, the watch accepted it, and a terminal review newer than that was
# announced as this round's answer — a pass nobody requested this round. The nonce is what
# changes between rounds: the driver generates one per request and hands it to the writer,
# which prefixes the value, and to this watch, which refuses any other. Staged as the exact
# state: a file written under one nonce reaching a watch required to see another.
printf '5551 99\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=100 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 7777 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=stale_baseline_nonce' <<<"$out"; } \
    && pass "a baseline written under a previous request's nonce is refused, not waited past" \
    || die "a stale-nonce baseline was accepted (rc=$rc out='$out')"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "a stale-nonce baseline let a newer review through as this round's: $out" \
    || pass "…with no verdict announced against it"
# AND THE PRE-NONCE FORMAT IS REFUSED, NOT READ AS AN ID WITH NO NONCE. A file with no
# space is what every writer produced before this change and what an older plugin or a
# caller on the old contract still produces; taking it as a bare id would keep the
# fail-open and add a spelling, exactly as accepting both empty and `none` would have.
printf '99\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=100 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=baseline_without_nonce' <<<"$out"; } \
    && pass "…and the old un-nonced format is refused rather than read as an id" \
    || die "an un-nonced baseline was accepted (rc=$rc out='$out')"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "an un-nonced baseline let a review through: $out" \
    || pass "…with no verdict announced against it"
# AND THE FILE FORM WITHOUT `--require-nonce` IS A CALLER ERROR, not a file read with no
# nonce to check — that would be the same fail-open reached by omitting the option.
printf '5551 99\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=100 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=nonce_required' <<<"$out"; } \
    && pass "…and the file form without --require-nonce is refused at the call" \
    || die "--after-review-file without a nonce was accepted (rc=$rc out='$out')"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "a file read with no nonce required let a review through: $out" \
    || pass "…with no verdict announced"
# AND THE VALUE FORM REFUSES A NONCE: the caller holds the id in a hardened process of
# its own, nothing was reached past a refusal, and a nonce beside it means two ideas of
# what is being waited on.
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=100 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review 99 --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=nonce_without_file' <<<"$out"; } \
    && pass "…while --require-nonce beside the value form is refused" \
    || die "--after-review with a nonce was accepted (rc=$rc out='$out')"
# AND THE NONCE IS DIGITS. It is spelled into a `case` comparison; a value carrying
# anything else is usage, and a missing one is the hang the other options have a case for.
for _nn in "" "abc" "12 34" "1*"; do
    out="$(run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce "$_nn" --interval 1 --timeout 6 2>&1)"; rc=$?
    { [ "$rc" -eq 2 ] && grep -q 'decimal digits' <<<"$out"; } \
        && pass "…and a nonce of '$_nn' is refused as not decimal digits" \
        || die "--require-nonce '$_nn' gave rc=$rc out='$out'"
done
out="$(run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'needs a value' <<<"$out"; } \
    && pass "…and a valueless --require-nonce is usage, not a hang" \
    || die "--require-nonce with no value gave rc=$rc out='$out'"
# THE SPLIT IS ON THE FIRST SPACE, so a comment-channel value survives whole: the round
# close writes `comment:<id>` and the nonce must not eat into it.
printf '5551 comment:100\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=100 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 6 2>&1)"; rc=$?
[ "$rc" -ne 2 ] \
    && pass "…and a nonced comment:<id> baseline is split on the first space and accepted" \
    || die "a nonced comment:<id> baseline was refused: rc=$rc out='$out'"

# ── an expired deadline does not skip the baseline validation ─────────────
#
# `--timeout 0` made the pre-read clock report the ordinary timeout before the file was
# opened at all, so a missing, malformed or NUL-carrying baseline came back as
# `state=timeout` — which the driver RE-ARMS. A caller error was then indistinguishable
# from a slow reviewer, forever. A bad argument is bad whatever the clock says.
printf '\000' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 0 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=after_review_file_nul' <<<"$out"; } \
    && pass "a NUL baseline is refused even with the deadline already expired" \
    || die "--timeout 0 with a NUL baseline gave rc=$rc out='$out'"
printf '5551 not-an-id\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 0 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=malformed_review_id' <<<"$out"; } \
    && pass "…and so is a malformed one" \
    || die "--timeout 0 with a malformed baseline gave rc=$rc out='$out'"
rm -f "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 0 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'reason=after_review_file_unreadable' <<<"$out"; } \
    && pass "…and so is a missing one" \
    || die "--timeout 0 with a missing baseline gave rc=$rc out='$out'"
# AND A GOOD BASELINE WITH AN EXPIRED DEADLINE IS STILL THE ORDINARY TIMEOUT, or the
# three cases above pass because the expiry stopped being honoured at all.
printf '5551 99\n' > "$_bl"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/samehead.sh" CUR_ID=99 \
       run_limited 30 "$SCRIPT" 7 "$BOT" --after-review-file "$_bl" --require-nonce 5551 --interval 1 --timeout 0 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'state=timeout' <<<"$out"; } \
    && pass "…while a good baseline with an expired deadline is still the timeout" \
    || die "--timeout 0 with a good baseline gave rc=$rc out='$out'"

# ── a buffer read that prints and then fails is not a probe result ────────
# `probe` reads the child output back from a temp file. A `cat` that emitted a
# complete, plausible record and then failed came back as the child's SUCCESS, so
# the caller could accept a state or a verdict from a read that never finished.
CATBIN="$TMP/catbin"; mkdir -p "$CATBIN"
REAL_CAT="$(command -v cat)"
cat > "$CATBIN/cat" <<CATSH
#!/usr/bin/env bash
case "\$*" in
    *pr-watch.*) "$REAL_CAT" "\$@"; exit 1 ;;
esac
exec "$REAL_CAT" "\$@"
CATSH
chmod +x "$CATBIN/cat"
seq_set reviewed
# The `cat` stub goes inside the watchdog too: `run_limited` reads its own buffer
# with `cat` on the portable path, so a stub on the caller's PATH broke the
# harness instead of the subject wherever GNU `timeout` is absent.
out="$(run_limited 30 env PATH="$CATBIN:$PATH" PR_WATCH_STATE_SCRIPT="$TMP/state.sh" \
       SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a probe buffer read that prints and then fails => 2" \
    || die "failing buffer read gave rc=$rc out='$out'"
grep -q 'PR_REVIEW_READY' <<<"$out" \
    && die "a failed buffer read still produced a READY line: $out" \
    || pass "…and never reaches READY"

# ── an inter-poll sleep that fails is not a slow review ───────────────────
# An unchecked failure launched the next round of GitHub probes at once, hammered
# the API until the clock expired, and then reported an ordinary timeout — so a
# broken scheduler was indistinguishable from a review that was merely slow, and
# the driver re-armed on it.
# It fails only for WHOLE-SECOND arguments. `probe` polls in fractions and has
# its own guard, so a sleep that always failed exited there and this fixture
# proved nothing about the inter-poll sleep it was written for.
SLEEPBIN="$TMP/sleepbin"; mkdir -p "$SLEEPBIN"
REAL_SLEEP="$(command -v sleep)"
cat > "$SLEEPBIN/sleep" <<SLEEPSH
#!/usr/bin/env bash
case "\$1" in
    *.*) exec "$REAL_SLEEP" "\$@" ;;
    *)   exit 1 ;;
esac
SLEEPSH
chmod +x "$SLEEPBIN/sleep"
seq_set none
# The stub goes inside `run_limited`, not on its caller's PATH. Where GNU
# `timeout` is missing the watchdog polls with its OWN `sleep`, so a stub on the
# harness PATH broke the harness: it killed the watch and returned 125 before the
# assertion below could see the status it was written for. That made this
# mandatory gate unpassable on stock macOS while passing everywhere `timeout`
# exists — the same portability trap the watchdog itself was written to close.
out="$(run_limited 30 env PATH="$SLEEPBIN:$PATH" PR_WATCH_STATE_SCRIPT="$TMP/state.sh" \
       SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 8 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a failing sleep => 2, not a timeout the driver re-arms" \
    || die "failing sleep gave rc=$rc out='$out'"
grep -q 'state=timeout' <<<"$out" \
    && die "a broken scheduler was reported as an ordinary timeout: $out" \
    || pass "…and is not reported as a timeout"

# ── the MOVED-HEAD sleep path ─────────────────────────────────────────────
# This exercises the moved-head branch and its sleep, which the ordinary
# failing-sleep case above never reaches.
#
# It does NOT isolate that branch's guard, and saying so matters: both sleep
# guards emit the same `reason=sleep_failed` record, so a mutant on either is
# masked by the other — measured, not assumed. The assertions below therefore
# prove the moved-head path behaves correctly, not that its particular guard is
# load-bearing. `pr-watch.sh` records the same limitation beside the guard.
#
# The stub moves the head on every `head` call, so the recheck after the verdict
# always disagrees and the moved-head path is the only one exercised.
cat > "$TMP/movesleep.sh" <<SH
#!/usr/bin/env bash
if [ "\$1" = "head" ]; then
    n=\$(cat "\$MOVE_N" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$MOVE_N"
    printf '%s%033d\n' "abc1234" "\$n"
    exit 0
fi
head="\$4"
if [ "\$1" = "verdict" ]; then
    printf 'PR_REVIEW_STATE pr=%s sha=%s reviewer=%s verdict=clean findings=0\n' "\$2" "\${head:0:7}" "\$3"
    exit 0
fi
printf 'PR_REVIEW_STATE pr=%s sha=%s reviewer=%s state=reviewed\n' "\$2" "\${head:0:7}" "\$3"
exit 0
SH
chmod +x "$TMP/movesleep.sh"
rm -f "$TMP/movesleep.n"
# Sanity: without a failing sleep this reaches the moved-head branch and times
# out. If it does not, the fixture below would prove nothing about the guard.
out="$(PR_WATCH_STATE_SCRIPT="$TMP/movesleep.sh" MOVE_N="$TMP/movesleep.n" \
       run_limited 40 "$SCRIPT" 7 "$BOT" --interval 1 --timeout 4 2>&1)"; rc=$?
grep -q 'state=head_moved' <<<"$out" \
    && pass "the moved-head branch is the one this fixture exercises" \
    || die "the fixture never reached the moved-head branch: $out"

# Now fail whole-second sleeps only — `probe` polls in fractions and has its own
# guard, so a sleep that always failed would exit there and prove nothing.
rm -f "$TMP/movesleep.n"
out="$(run_limited 40 env PATH="$SLEEPBIN:$PATH" PR_WATCH_STATE_SCRIPT="$TMP/movesleep.sh" \
       MOVE_N="$TMP/movesleep.n" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 8 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a failing sleep on the moved-head path => 2 (not isolating; see note)" \
    || die "moved-head failing sleep gave rc=$rc out='$out'"
grep -q 'reason=sleep_failed' <<<"$out" \
    && pass "…reported as a failed sleep, not an ordinary timeout" \
    || die "the moved-head sleep failure was not named: $out"

# ── a clock that fails at the TIMEOUT read is not an ordinary timeout ─────
# `timed_out` reads the clock once more to report how long it waited. Falling
# back to `$TIMEOUT` turned a broken clock into a plausible timeout — and the
# driver RE-ARMS on status 1, so the round would loop forever instead of
# stopping as unreadable.
#
# Isolated with `--timeout 0`: the deadline is already exhausted, so the first
# `remaining_s` sends the watch straight to `timed_out` and no main-loop clock
# read intervenes. A previous attempt at this fixture failed because every
# arrangement tripped an earlier read first; this one reaches the guard directly.
LATECLOCK="$TMP/lateclock"; mkdir -p "$LATECLOCK"
REAL_DATE="$(command -v date)"
cat > "$LATECLOCK/date" <<DATESH
#!/usr/bin/env bash
n=\$(cat "\$CLK_N" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$CLK_N"
if [ "\$n" -ge "\${CLK_FAIL_AT:-999}" ]; then printf '1700000000\n'; exit 1; fi
exec "$REAL_DATE" "\$@"
DATESH
chmod +x "$LATECLOCK/date"
seq_set none
rm -f "$TMP/clk.n"
# `env` inside the watchdog, not a PATH on its caller: where GNU `timeout` is
# missing, `run_limited` polls, reads and cleans up with its OWN `sleep`, `cat`,
# `date`, `mktemp` and `rm`, so a stub prefixed here breaks the harness instead
# of the subject — invisible wherever `timeout` exists.
out="$(run_limited 30 env PATH="$LATECLOCK:$PATH" CLK_N="$TMP/clk.n" CLK_FAIL_AT=3 \
       PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" \
       "$SCRIPT" 7 "$BOT" --interval 1 --timeout 0 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a clock that fails at the timeout read => 2, not a re-armable timeout" \
    || die "late clock failure gave rc=$rc out='$out'"
grep -q 'clock_unreadable' <<<"$out" \
    && pass "…named as an unreadable clock" \
    || die "the late clock failure was not named: $out"
grep -q 'state=timeout' <<<"$out" \
    && die "a broken clock was reported as an ordinary timeout: $out" \
    || pass "…and not as a timeout the driver would re-arm"

# The control: with the clock intact, the same invocation IS an ordinary timeout.
rm -f "$TMP/clk.n"
# `env` inside the watchdog, not a PATH on its caller: where GNU `timeout` is
# missing, `run_limited` polls, reads and cleans up with its OWN `sleep`, `cat`,
# `date`, `mktemp` and `rm`, so a stub prefixed here breaks the harness instead
# of the subject — invisible wherever `timeout` exists.
out="$(run_limited 30 env PATH="$LATECLOCK:$PATH" CLK_N="$TMP/clk.n" CLK_FAIL_AT=999 \
       PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" \
       "$SCRIPT" 7 "$BOT" --interval 1 --timeout 0 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'state=timeout' <<<"$out"; } \
    && pass "…while a working clock at the same deadline is a plain timeout" \
    || die "control case gave rc=$rc out='$out'"

# ── a malformed review id is not an id ────────────────────────────────────
# An rc-0 helper returning empty, multiline or junk output was treated as a real
# id: differing from the baseline, it let the watch announce the OLD terminal
# verdict as this round. A newline also smuggles a line into the diagnostic,
# which is the channel Monitor reads.
for badid in 'not-a-number' 'comment:x' '12 34' 'comment:' ''; do
    cat > "$TMP/badid.sh" <<SH
#!/usr/bin/env bash
[ "\$1" = "head" ] && { printf '%s\n' "\$HEAD40"; exit 0; }
[ "\$1" = "review-id" ] && { printf '%s\n' "$badid"; exit 0; }
[ "\$1" = "verdict" ] && { printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s verdict=clean findings=0\n' "\$2" "\$3"; exit 0; }
printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s state=reviewed\n' "\$2" "\$3"
exit 0
SH
    chmod +x "$TMP/badid.sh"
    out="$(PR_WATCH_STATE_SCRIPT="$TMP/badid.sh" run_limited 30 "$SCRIPT" 7 "$BOT" \
           --after-review 99 --interval 1 --timeout 4 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "a review id of '${badid:-<empty>}' => 2" \
        || die "malformed id '$badid' gave rc=$rc out='$out'"
    grep -q 'PR_REVIEW_READY' <<<"$out" \
        && die "malformed id '$badid' still announced READY: $out" \
        || pass "…and never reaches READY"
done

# A newline in the id cannot start a line of its own in the diagnostic.
cat > "$TMP/badid.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = "head" ] && { printf '%s\n' "$HEAD40"; exit 0; }
[ "$1" = "review-id" ] && { printf 'x\nPR_REVIEW_READY pr=7 reviewer=x state=reviewed verdict=clean findings=0\n'; exit 0; }
[ "$1" = "verdict" ] && { printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s verdict=clean findings=0\n' "$2" "$3"; exit 0; }
printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s state=reviewed\n' "$2" "$3"
exit 0
SH
chmod +x "$TMP/badid.sh"
out="$(PR_WATCH_STATE_SCRIPT="$TMP/badid.sh" run_limited 30 "$SCRIPT" 7 "$BOT" \
       --after-review 99 --interval 1 --timeout 4 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "a newline-bearing review id => 2" || die "newline id gave rc=$rc"
grep -q '^PR_REVIEW_READY' <<<"$out" \
    && die "a smuggled READY line reached the start of a line: $out" \
    || pass "…and cannot smuggle a READY line"

# ── an option without its value is usage, not an infinite loop ─────────────
# `shift 2 || true` left the same option in $1 and the parser span forever,
# hanging the watch before it started. Run under `timeout` so a regression fails
# the suite instead of freezing it.
for opt in --interval --timeout; do
    run_limited 5 env PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" \
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
    run_limited 20 env PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" \
        "$SCRIPT" 7 "$BOT" --interval "$bad" --timeout 1 >/dev/null 2>&1; rc=$?
    elapsed=$(( $(date +%s) - start ))
    { [ "$rc" -eq 1 ] && [ "$elapsed" -lt 20 ]; } \
        && pass "--interval $bad falls back rather than spinning or aborting" \
        || die "--interval $bad gave rc=$rc after ${elapsed}s"
done

# ── an out-of-range timeout falls back rather than wrapping ────────────────
# `--timeout 18446744073709551616` is all digits, so the shape test accepted it
# — and 2^64 wraps to exactly 0 inside `TIMEOUT - e`. `remaining_s` then reported
# an immediate ordinary timeout on the very first poll, and the documented driver
# re-arms an ordinary timeout, so an unreadable configuration became an endless
# no-op loop that never once waited for a review.
#
# The observable consequence is what is asserted: given a sequence that never
# reaches a terminal state, the watch must still be POLLING when the harness
# limit fires, rather than having announced a timeout at once. The run is bounded
# by `run_limited` because the fixed code falls back to a 3600s deadline — an
# unbounded call here would hang the suite for an hour instead of failing it.
for huge in 18446744073709551616 340282366920938463463374607431768211456; do
    seq_set none
    out="$(run_limited 6 env PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" \
             HEAD40="$HEAD40" "$SCRIPT" 7 "$BOT" --interval 1 --timeout "$huge" 2>&1)"; rc=$?
    if [ "$rc" -eq 124 ]; then
        pass "an out-of-range timeout ($huge) falls back instead of wrapping to zero"
    else
        die "timeout=$huge exited early (rc=$rc out='$out')"
    fi
    grep -q 'state=timeout' <<<"$out" \
        && die "…and it announced an immediate timeout from a wrapped deadline" \
        || pass "…and announced no timeout"
done

# ── a helper that answers within the deadline, but not instantly ───────────
# The probe budget is a REAL duration even when the watch's own pacing is not,
# because what it bounds is a real child process. A six-second deadline buys
# thirty ticks, which is one and a half real seconds of the fixture's tick, and
# the helper takes half of one — so the probe must wait for it and report its
# answer rather than kill it.
#
# This is the case that fails if the fixture's `sleep` ever treats a fractional
# argument as a successful no-op again: the tick loop would then burn all thirty
# ticks in about a tenth of a second and kill a healthy helper as a probe
# timeout, and the watch would report state=timeout instead of the verdict.
#
# Invoked directly rather than through `run()`, which pins its own state script.
mkstub "$TMP/slowish.sh" <<SLOWISH
"$REAL_SLEEP" 0.5
[ "\$1" = "verdict" ] && {
    printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s verdict=clean findings=0\n' "\$2" "\$3"
    exit 0
}
printf 'PR_REVIEW_STATE pr=%s sha=abc1234 reviewer=%s state=reviewed\n' "\$2" "\$3"
exit 0
SLOWISH
out="$(run_limited 30 env PATH="$FASTCLOCK:$PATH" FAKE_NOW="$TMP/now" \
        PR_WATCH_STATE_SCRIPT="$TMP/slowish.sh" HEAD40="$HEAD40" \
        "$SCRIPT" 7 "$BOT" --interval 1 --timeout 6 2>&1)"; rc=$?
case "$rc:$out" in
    0:*PR_REVIEW_READY*verdict=clean*)
        pass "a helper that answers within the deadline is waited for, not killed" ;;
    *)  die "a helper answering in half a second was killed as a timeout: rc=$rc '$out'" ;;
esac

# ── a failed polling clock tears the probe down before returning ───────────
# The capability check at the top of `probe` succeeds, so this path is reached
# with a LIVE child. Returning 125 on the clock failure alone left that `gh`
# running: the watch exited 2 with an API call still open, and every re-arm of a
# persistent watch added another orphan.
#
# The stub `sleep` works for the 0.2 capability probe and for the child, and
# fails only for the polling tick — so the child is provably alive when the clock
# fails, and the assertion is about teardown rather than about timing.
ORPH="$TMP/orph"; mkdir -p "$ORPH"
for b in bash sh date true false kill sed grep printf env mktemp cat rm wc awk tr; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$ORPH/$b"
done
# THE WHOLE-SECOND PATH IS FORCED, so there is no capability/tick ambiguity to
# race against. `probe()` uses the same `sleep 0.2` for its fractional-capability
# check as for its polling tick, and no marker can tell them apart from inside the
# stub: keying on the child's start let a descheduled parent fail its capability
# check instead, which silently drops the probe to whole-second ticks and
# exercises nothing. So `0.2` always fails — the capability check is *meant* to
# fail here, that is what a platform without fractional sleep looks like — and the
# tick under test is the unambiguous `sleep 1`.
#
# That tick fails only once the child has published its PID, and passes through to
# a real sleep before then. Nothing depends on ordering: a tick that runs early
# simply sleeps a real second and comes round again, while the child stays alive
# for thirty.
cat > "$ORPH/sleep" <<SLEEPSH
#!/usr/bin/env bash
[ "\$1" = "0.2" ] && exit 1
if [ "\$1" = "1" ] && [ -s "$TMP/probe-started" ]; then exit 1; fi
exec "$REAL_SLEEP" "\$@"
SLEEPSH
chmod +x "$ORPH/sleep"
# The child publishes its OWN PID and then `exec`s, so the PID in the marker is
# the process still holding the buffer. A `pgrep -f`/`pkill -f` over the argv
# matched any `sleep 30` on the machine — the suite is a mandatory pre-push gate,
# so that reported a false leak from an unrelated command and then killed it.
mkstub "$TMP/slowstate.sh" <<SLOWSH
printf '%s' "\$\$" > "$TMP/probe-started"
exec "$REAL_SLEEP" 30
SLOWSH
rm -f "$TMP/probe-started"
# THE HARNESS KEEPS THE REAL PATH; only the watch under test gets the stub.
# Where GNU `timeout` is missing — the portable fallback this suite exists to
# support — `run_limited` polls with its OWN `sleep 1`, and putting the stub on
# the caller's PATH fed it the broken clock too: it killed `pr-watch.sh` and
# returned 125 instead of letting the inner probe answer, so this mandatory gate
# was unpassable on stock macOS while passing here. `env` moves the substitution
# inside the watchdog, where it belongs.
out="$(run_limited 30 env PATH="$ORPH:$PATH" PR_WATCH_STATE_SCRIPT="$TMP/slowstate.sh" \
        SEQ_FILE="$TMP/seq" HEAD40="$HEAD40" \
        "$SCRIPT" 7 "$BOT" --interval 1 --timeout 25 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "a failed polling clock fails the watch closed" \
    || die "a failed polling clock gave rc=$rc: '$out'"
# The teardown, asserted on THAT process and no other. An rc-only assertion passes
# on the leaking version — the leak is invisible to the exit status, which is why
# it survived — but the assertion must not be able to see anything except the
# child this fixture started.
# The READ has its own status, in a function so the guard can be EXERCISED rather
# than asserted about. A `cat` that emits a numeric PREFIX and then fails —
# `12345` truncated to `123` — yields digits that satisfy the shape test, and
# `kill -0 123` then reports no such process, so this gate records PASS while the
# real probe is still leaked.
read_pid_marker() {   # <file> -> prints the PID, non-zero if it cannot be trusted
    local v rc
    v="$(cat "$1" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || return 1
    case "$v" in ""|*[!0-9]*) return 1 ;; esac
    printf '%s' "$v"
}
probe_pid="$(read_pid_marker "$TMP/probe-started")" \
    || die "could not read the fixture child's PID marker"
case "$probe_pid" in
    ""|*[!0-9]*) die "the fixture child never published a PID ('$probe_pid')" ;;
    *)  if kill -0 "$probe_pid" 2>/dev/null; then
            die "the probe (pid $probe_pid) survived the clock failure"
            kill -9 "$probe_pid" 2>/dev/null
        else
            pass "…and reaps the probe rather than leaving it holding an API call"
        fi ;;
esac

# ── the PID-marker read is proven, not merely guarded ──────────────────────
# The guard above cannot be reached with a real `cat`, so it is exercised here
# against one that emits a numeric prefix and then fails — the exact shape that
# made a truncated PID look like a reaped probe.
PIDR="$TMP/pidr"; mkdir -p "$PIDR"
for b in bash sh sleep date true false kill sed grep printf env mktemp rm; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$PIDR/$b"
done
printf '#!/usr/bin/env bash\nprintf "123"\nexit 1\n' > "$PIDR/cat"; chmod +x "$PIDR/cat"
printf '99999' > "$TMP/pidmarker"
# THE PRODUCTION FUNCTION IS CALLED, under a `cat` that prints a valid-looking
# prefix and then fails. The previous version of this case ran an inline snippet
# instead and only demonstrated that Bash exposes `cat`'s status — removing the
# guard from `read_pid_marker` left it passing, which is the precise shape of
# useless coverage this suite exists to refuse.
pidout="$(PATH="$PIDR:$PATH" bash -c '
'"$(declare -f read_pid_marker)"'
read_pid_marker "$1" && echo "ACCEPTED:$?" || echo "REJECTED"' _ "$TMP/pidmarker" 2>&1)"
[ "$pidout" = REJECTED ] \
    && pass "the marker read rejects a PID that was printed and then failed" \
    || die "a truncated PID read was accepted ('$pidout')"
# The control: the same function on a good read must still accept, or "rejects
# everything" would satisfy the assertion above.
pidout="$(bash -c '
'"$(declare -f read_pid_marker)"'
read_pid_marker "$1"' _ "$TMP/pidmarker" 2>&1)"
[ "$pidout" = 99999 ] \
    && pass "…and accepts a complete one" \
    || die "the marker read rejected a good PID ('$pidout')"

# ── an epoch outside Bash arithmetic is an unreadable clock ────────────────
# All digits, so the shape test accepted it, and `t - started` then wraps. A
# CONSTANT oversized value keeps elapsed time at zero forever — the watch never
# reaches its deadline and the caller waits indefinitely — while one appearing
# after startup produces an immediate ordinary timeout, which the driver re-arms
# as though the review were merely slow. Both are the clock failing silently.
BIGCLOCK="$TMP/bigclock"; mkdir -p "$BIGCLOCK"
for big in 18446744073709551616 99999999999999999999; do
    printf '#!/usr/bin/env bash\nprintf "%s\\n"\n' "$big" > "$BIGCLOCK/date"
    chmod +x "$BIGCLOCK/date"
    seq_set none
    out="$(run_limited 20 env PATH="$BIGCLOCK:$PATH" PR_WATCH_STATE_SCRIPT="$TMP/state.sh" \
           SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
    { [ "$rc" -eq 2 ] && grep -q 'clock_unreadable' <<<"$out"; } \
        && pass "an out-of-range epoch ($big) is an unreadable clock, not a deadline" \
        || die "epoch $big gave rc=$rc out='$out'"
    grep -q 'state=timeout' <<<"$out" \
        && die "…and it was reported as a timeout the driver would re-arm: $out" \
        || pass "…and not as an ordinary timeout"
done

# …and the bound must ACCEPT what it claims to. `N` question marks followed by
# `*` matches length N or more, so an eleven-`?` pattern rejected eleven-digit
# epochs — every watch would have exited `clock_unreadable` from 2286, a ceiling
# that behaved as a floor one digit lower. The rejection cases above pass either
# way, which is exactly why this direction has to be asserted separately.
for good in 1754000000 10000000000 99999999999; do
    printf '#!/usr/bin/env bash\nprintf "%s\\n"\n' "$good" > "$BIGCLOCK/date"
    chmod +x "$BIGCLOCK/date"
    # TERMINAL ON THE FIRST POLL, so the watch exits by itself. This clock is
    # FIXED — every reading is the same epoch — so elapsed never grows and the
    # timeout never arrives: with a non-terminal state the case sat until the
    # watchdog killed it, twenty seconds each and three of them. The question here
    # is only whether the epoch is ACCEPTED, which one poll answers.
    seq_set reviewed
    out="$(run_limited 20 env PATH="$BIGCLOCK:$PATH" PR_WATCH_STATE_SCRIPT="$TMP/state.sh" \
           SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 2 2>&1)"; rc=$?
    grep -q 'clock_unreadable' <<<"$out" \
        && die "a valid epoch ($good, ${#good} digits) was rejected as unreadable: $out" \
        || pass "a ${#good}-digit epoch ($good) is accepted as a clock"
done

# ── a helper that exits 124 is unreadable, not a timeout ───────────────────
# 124 is the watchdog's OWN expiry code, returned before the child status is ever
# read. A helper that exits 124 itself — wrapped in `timeout`, or simply failing
# that way — was therefore reported as an ordinary timeout, status 1, which
# `SKILL.md` re-arms indefinitely. A broken probe became "the review is still in
# flight", forever.
mkstub "$TMP/rc124.sh" <<'SH'
[ "$1" = "head" ] && exit 0
exit 124
SH
out="$(run_limited 20 env PR_WATCH_STATE_SCRIPT="$TMP/rc124.sh" SEQ_FILE="$TMP/seq" \
        HEAD40="$HEAD40" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 10 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'probe_unreadable' <<<"$out"; } \
    && pass "a helper exiting 124 is an unreadable probe, not a timeout" \
    || die "helper rc=124 gave rc=$rc out='$out'"
grep -q 'state=timeout' <<<"$out" \
    && die "…and it was reported as a timeout the driver would re-arm: $out" \
    || pass "…so the driver stops instead of re-arming forever"

# ── a clock that steps BACKWARD is not a clock ─────────────────────────────
# A backward step produced a smaller elapsed value while still succeeding, and
# `remaining_s` handed the next probe a LARGER budget — `--timeout` exceeded by
# the size of the correction, or extended without bound by repeated ones.
BACKCLOCK="$TMP/backclock"; mkdir -p "$BACKCLOCK"
cat > "$BACKCLOCK/date" <<BACKSH
#!/usr/bin/env bash
n=\$(cat "\$BACK_N" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$BACK_N"
# Forward for the first few reads, then a step backward — the shape of an NTP
# correction landing mid-watch.
if [ "\$n" -le 3 ]; then printf '1754000%03d\n' "\$n"; else printf '1753000000\n'; fi
BACKSH
chmod +x "$BACKCLOCK/date"
rm -f "$TMP/back.n"; seq_set none
out="$(run_limited 25 env PATH="$BACKCLOCK:$PATH" BACK_N="$TMP/back.n" \
        PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" \
        "$SCRIPT" 7 "$BOT" --interval 1 --timeout 8 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'clock_unreadable' <<<"$out"; } \
    && pass "a clock that steps backward is unreadable, not a longer deadline" \
    || die "backward clock gave rc=$rc out='$out'"

# …AND a retreat that stays ABOVE the start time. The case above passes even when
# the monotonic state is discarded, because the comparison then falls back to
# `$started` and a value below it is still rejected — so it proved only the
# trivial half. Every caller evaluated `elapsed_s` through command substitution,
# which ran it in a subshell and threw the update away, so 100 → 110 → 105 was
# accepted and the remaining budget GREW by the size of the correction. This is
# the shape of a real NTP step: forward, then a small correction back.
cat > "$BACKCLOCK/date" <<BACKSH
#!/usr/bin/env bash
n=\$(cat "\$BACK_N" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$BACK_N"
# Climb, then retreat — but never below where it began, and by small enough
# steps that the deadline is not reached before the retreat is. An earlier
# version of this stub climbed by three a tick and timed out at the fourth read,
# so the retreat never happened and the case passed on the wrong path.
if [ "\$n" -le 4 ]; then printf '%d\n' \$((1754000000 + n))
else printf '%d\n' \$((1754000000 + 2)); fi
BACKSH
chmod +x "$BACKCLOCK/date"
rm -f "$TMP/back.n"; seq_set none
out="$(run_limited 25 env PATH="$BACKCLOCK:$PATH" BACK_N="$TMP/back.n" \
        PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" \
        "$SCRIPT" 7 "$BOT" --interval 1 --timeout 8 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'clock_unreadable' <<<"$out"; } \
    && pass "…including a retreat that stays above the start time" \
    || die "a retreat above the start was accepted (rc=$rc out='$out')"

# The control: a clock that only ever moves FORWARD must not be rejected, or
# "reject every clock" would satisfy both cases above.
cat > "$BACKCLOCK/date" <<FWDSH
#!/usr/bin/env bash
n=\$(cat "\$BACK_N" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$BACK_N"
printf '%d\n' \$((1754000000 + n))
FWDSH
chmod +x "$BACKCLOCK/date"
rm -f "$TMP/back.n"; seq_set none
out="$(run_limited 25 env PATH="$BACKCLOCK:$PATH" BACK_N="$TMP/back.n" \
        PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" \
        "$SCRIPT" 7 "$BOT" --interval 1 --timeout 4 2>&1)"; rc=$?
grep -q 'clock_unreadable' <<<"$out" \
    && die "a monotonically advancing clock was rejected: $out" \
    || pass "…and a clock that only advances is accepted"

# ── AN INHERITED VALIDATOR DOES NOT MAKE A LOADED LIBRARY ──────────────────
# The shape rules are what stand between a configured `PR_WATCH_STATE_SCRIPT` and
# this script trusting its output. Sourced by hand, an exported `is_full_sha` plus
# an EMPTY `recordlib.sh` passed the old `command -v` check — a permissive stale
# validator admitting malformed output, and the watch reporting PR_REVIEW_READY on
# a verdict nothing validated.
#
# Asserted at the WATCH LEVEL, not only as the shape of the source lines. The
# loader has its own tests and `test-pr-identity.sh` checks the wiring, but
# neither says what this script DOES in that state — and "it stops" is the claim
# that matters here. The stub validator returns 0 for everything, which is what a
# permissive one looks like.
IVTMP="$TMP/inherit"; mkdir -p "$IVTMP"
for g in "$SELF_DIR"/*.sh; do ln -sf "$g" "$IVTMP/$(basename "$g")"; done
rm -f "$IVTMP/recordlib.sh"; : > "$IVTMP/recordlib.sh"
# A state script whose output is malformed in the one way the validator exists to
# catch: a `sha=` that is not a full OID.
cat > "$TMP/loose.sh" <<'LOOSESH'
#!/usr/bin/env bash
case "$1" in
    head) printf 'not-a-sha
' ;;
    *)    echo "PR_REVIEW_STATE pr=7 sha=not-a-sha reviewer=x state=reviewed verdict=clean findings=0" ;;
esac
exit 0
LOOSESH
chmod +x "$TMP/loose.sh"
iv_rc=0
iv_out="$(run_limited 20 env PR_WATCH_STATE_SCRIPT="$TMP/loose.sh" \
    bash -c 'is_full_sha() { return 0; }
             export -f is_full_sha
             exec "$1" 7 "$2" --interval 1 --timeout 3' _ "$IVTMP/pr-watch.sh" "$BOT" 2>&1)" || iv_rc=$?
[ "$iv_rc" -eq 2 ] \
    && pass "an empty recordlib is refused even with is_full_sha already defined" \
    || die "the watch ran with an inherited validator (rc=$iv_rc out='$iv_out')"
# The CONSEQUENCE, not just the status: nothing may have been reported ready. An
# rc-only assertion passes on a watch that emitted READY and then failed for some
# other reason on its way out.
grep -q 'PR_REVIEW_READY' <<<"$iv_out" \
    && die "the watch reported READY on output an inherited validator accepted" \
    || pass "…and nothing was reported ready"
grep -q 'reason=recordlib_empty' <<<"$iv_out" \
    && pass "…and it says which library failed to load" \
    || die "the refusal does not name the library (out='$iv_out')"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
