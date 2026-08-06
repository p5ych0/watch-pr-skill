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
TMP="$(mktemp -d)"
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
run() { PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" HEAD40="$HEAD40" "$SCRIPT" "$@"; }
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
    mkstub "$TMP/broken.sh" <<SH
echo "some stderr noise" >&2
exit $rc_case
SH
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
mkstub "$TMP/garbage.sh" <<'SH'
[ "$1" = "verdict" ] && { echo "verdict=clean findings=0"; exit 0; }
echo "some truncated wrapper output with no state field"
exit 0
SH
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
    mkstub "$TMP/noisy.sh" <<SH
[ "\$1" = "verdict" ] && { echo "PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=x verdict=clean findings=0"; exit 0; }
echo "$noisy"
exit 0
SH
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
    printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
        && die "an unparseable verdict still emitted the READY signal" \
        || pass "no READY signal from an unparseable verdict"
done
# The verdict shapes that AGREE with the state are accepted — each with the exit
# status the helper actually pairs it with.
for spec in 'verdict=clean findings=0|0|reviewed' 'verdict=findings findings=3|1|reviewed' \
            'verdict=none reason=blocked|1|blocked' 'verdict=none reason=dismissed|1|dismissed'; do
    vout="${spec%%|*}"; rest="${spec#*|}"; vrc="${rest%%|*}"; vstate="${rest#*|}"
    seq_set "$vstate"
    out="$(VERDICT="$vout" VERDICT_RC="$vrc" run 7 "$BOT" --interval 1 --timeout 5 2>&1)"
    printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
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
    printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
        && die "state=$vstate with '$vout' was announced as READY: $out" \
        || pass "state=$vstate with '$vout' is not READY"
    printf '%s' "$out" | grep -q 'state=moved_between_probes' \
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
    mkstub "$TMP/misrouted.sh" <<SH
[ "\$1" = "verdict" ] && { echo "PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=$BOT verdict=clean findings=0"; exit 0; }
echo "PR_REVIEW_STATE $bad state=reviewed"
exit 0
SH
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
mkstub "$TMP/skew.sh" <<SH
[ "\$1" = "verdict" ] && { echo "PR_REVIEW_STATE pr=7 sha=0000fff reviewer=$BOT verdict=clean findings=0"; exit 0; }
echo "PR_REVIEW_STATE pr=7 sha=abc1234 reviewer=$BOT state=reviewed"
exit 0
SH
out="$(PR_WATCH_STATE_SCRIPT="$TMP/skew.sh" SEQ_FILE="$TMP/seq" "$SCRIPT" 7 "$BOT" --interval 1 --timeout 3 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "a verdict for a different sha than the state => 2" \
    || die "sha-skewed verdict gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
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
printf '%s\n' "$out" | grep -q '^PR_REVIEW_READY' \
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
printf '%s\n' "$out" | grep -q '^PR_REVIEW_READY' \
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
    printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
        && die "an unusable head ($spec) still emitted READY" \
        || pass "no READY from an unusable head ($spec)"
done

# ── a verdict about a head that is no longer current is not READY ─────────
# Pinning made the state and the verdict describe the SAME commit. It did not
# make that commit CURRENT: a push landing after the head probe leaves both
# probes correctly describing the old head, and announcing that as READY advances
# the driver on a review of code that is no longer there.
#
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
printf '%s' "$out" | grep -q 'PR_REVIEW_READY' \
    && die "a verdict for a superseded head was announced as READY: $out" \
    || pass "a verdict for a superseded head is not announced as READY"
printf '%s' "$out" | grep -q 'state=head_moved' \
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
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'PR_REVIEW_READY'; } \
    && pass "a head that moves once still reaches READY on the new head" \
    || die "settling head never reached READY (rc=$rc out='$out')"
printf '%s' "$out" | grep -q "${OTHER40:0:7}" \
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
printf '%s' "$out" | grep -q 'state=timeout' \
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

# ── a clock that prints and then fails is not a clock ─────────────────────
# `date` can print a plausible epoch and then exit non-zero, and the elapsed
# calculation hid that behind its own success — so elapsed time could stay
# ordinary-looking, or zero forever, and the watch would never time out.
CLOCKBIN="$TMP/clockbin"; mkdir -p "$CLOCKBIN"
printf '#!/usr/bin/env bash\nprintf "1700000000\\n"\nexit 1\n' > "$CLOCKBIN/date"
chmod +x "$CLOCKBIN/date"
out="$(PATH="$CLOCKBIN:$PATH" PR_WATCH_STATE_SCRIPT="$TMP/state.sh" SEQ_FILE="$TMP/seq" \
       run_limited 30 "$SCRIPT" 7 "$BOT" --interval 1 --timeout 5 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a clock read that prints and then fails => 2" \
    || die "failing clock gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'clock_unreadable' \
    && pass "…reported as an unreadable clock" \
    || die "the failing clock was not named: $out"

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

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
