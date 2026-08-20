#!/usr/bin/env bash
# Unit tests for pr-phase-state.sh.
#
# This is the recipe a resumed session runs to find out which phase a PR is in.
# It lived in `SKILL.md` as 112 lines of prose-embedded shell that nothing
# executed — three arms and six refusals, every one of them aborting with
# `exit 0`, so "the phase is not closed" and "this ran correctly" were the same
# status. What it does is SELECT and REFUSE, so the two helpers it reads through
# and `gh` are stubbed, and each case asserts the concrete answer rather than
# "not clean". #123, under #26.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-phase-state.sh"

TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

HEAD40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER40=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
CODEXBOT='chatgpt-codex-connector[bot]'
COPILOTBOT='copilot-pull-request-reviewer[bot]'

# ── the harness ────────────────────────────────────────────────────────────
DIR="$TMP/s"; mkdir -p "$DIR" "$TMP/bin"
cp "$SCRIPT" "$SELF_DIR/loadlib.sh" "$SELF_DIR/recordlib.sh" "$SELF_DIR/identitylib.sh" "$DIR/" \
    || { die "the subject could not be staged"; echo "RESULT: FAIL"; exit 1; }
# THE TWO HELPERS ARE KEYED ON THE REVIEWER, not on call order. The whole point
# of the branch under test is that the two signoffs answer differently and the
# ANSWERS select the arm — a stub that served one value to both would make every
# case agree with every arm.
cat > "$DIR/pr-signoff.sh" <<'SIGNSH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$CALLS"
case " $* " in
    *"chatgpt-codex-connector"*)          _w=codex ;;
    *"copilot-pull-request-reviewer"*)    _w=copilot ;;
    *)                                    _w=other ;;
esac
[ -f "$W/$_w.sha" ] && cat "$W/$_w.sha"
exit "$(cat "$W/$_w.rc" 2>/dev/null || echo 0)"
SIGNSH
chmod +x "$DIR/pr-signoff.sh"
cat > "$DIR/pr-review-state.sh" <<'STATESH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$CALLS"
case " $* " in
    *"chatgpt-codex-connector"*)       _w=codex ;;
    *"copilot-pull-request-reviewer"*) _w=copilot ;;
    *)                                 _w=other ;;
esac
[ -f "$W/$_w.verdict.out" ] && cat "$W/$_w.verdict.out"
exit "$(cat "$W/$_w.verdict.rc" 2>/dev/null || echo 0)"
STATESH
chmod +x "$DIR/pr-review-state.sh"
cat > "$TMP/bin/gh" <<'GHSH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$CALLS"
cat "$W/head.out" 2>/dev/null
exit "$(cat "$W/head.rc" 2>/dev/null || echo 0)"
GHSH
chmod +x "$TMP/bin/gh"

world() {   # world ; a PR whose Codex phase is closed on the current head
    W="$TMP/w"; rm -rf "$W"; mkdir -p "$W"; : > "$TMP/calls"
    printf '%s\n' "$HEAD40" > "$W/head.out"
    printf '%s\n' "$HEAD40" > "$W/codex.sha"
    printf '0\n' > "$W/codex.rc"
    # NO COPILOT SIGNOFF is status 1 with an empty answer, which is what
    # `pr-signoff.sh sha` reports when nothing is recorded. It is an ANSWER here,
    # not a refusal, and the default world is the one before that phase has run.
    : > "$W/copilot.sha"
    printf '1\n' > "$W/copilot.rc"
}
run() {   # run [args…] ; prints "<rc>|<output>"
    local out rc=0
    out="$(cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        "$DIR/pr-phase-state.sh" "$@" 2>&1)" || rc=$?
    printf '%s|%s' "$rc" "$out"
}

# ── THE TWO ANSWERS THAT ARE PERMISSION TO CONTINUE ────────────────────────
world; got="$(run 7)"
{ [ "${got%%|*}" = 0 ] && printf '%s' "${got#*|}" \
    | grep -qF "PR_PHASE pr=7 state=before-copilot codex-sha=$HEAD40 head=$HEAD40"; } \
    && pass "a Codex signoff on the current head reads as the phase before Copilot" \
    || die "the before-Copilot state gave '${got}'"

# AFTER THE COPILOT PHASE THE CODEX SIGNOFF IS OLDER THAN THE HEAD BY DESIGN, and
# demanding equality there rejects the state the second stop exists in. What must
# still hold is the COPILOT signoff, on the head being merged.
world; printf '%s\n' "$HEAD40" > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
printf '%s\n' "$OTHER40" > "$W/codex.sha"
got="$(run 7)"
{ [ "${got%%|*}" = 0 ] && printf '%s' "${got#*|}" \
    | grep -qF "PR_PHASE pr=7 state=after-copilot codex-sha=$OTHER40 copilot-sha=$HEAD40 head=$HEAD40"; } \
    && pass "…and a Copilot signoff on the head reads as the phase after it, with an older Codex sha" \
    || die "the after-Copilot state gave '${got}'"

# THE BRANCH TURNS ON WHICH SIGNOFF DESCRIBES THE HEAD, not on whether a Copilot
# record exists at all. After a fault-tolerance pass produced fixes, the NEW Codex
# signoff names the current head while the older Copilot one still names the
# previous — and selecting the post-Copilot arm merely because that historical
# record exists reported that neither phase was closed.
world; printf '%s\n' "$OTHER40" > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
got="$(run 7)"
{ [ "${got%%|*}" = 0 ] && printf '%s' "${got#*|}" | grep -qF 'state=before-copilot'; } \
    && pass "…while a historical Copilot signoff naming an older commit does not select that arm" \
    || die "a stale Copilot signoff selected the post-Copilot arm: '${got}'"

# ── NO SIGNOFF IS NOT A PHASE ──────────────────────────────────────────────
world; printf '1\n' > "$W/codex.rc"; : > "$W/codex.sha"
got="$(run 7)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'status=stopped reason=codex_phase_open'; } \
    && pass "no recorded Codex signoff stops rather than inventing one" \
    || die "an unrecorded phase gave '${got}'"
printf '%s' "${got#*|}" | grep -qF 'state=' \
    && die "…but it also reported a state" \
    || pass "…and reports no state to act on"

# ── AND AN UNREADABLE ANSWER IS NOT "NO SIGNOFF" ───────────────────────────
# Read as one it repeats a phase; read as a signoff it skips a review nobody did.
# Both are wrong, so it fails closed with its own status.
world; printf '2\n' > "$W/codex.rc"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'status=error reason=signoff_unreadable'; } \
    && pass "an unreadable Codex signoff fails closed with its own status" \
    || die "an unreadable signoff gave '${got}'"
printf '%s' "${got#*|}" | grep -qF 'state=' \
    && die "…but it also reported a state" \
    || pass "…and reports no state"
world; printf '%s\n' "$HEAD40" > "$W/copilot.sha"; printf '2\n' > "$W/copilot.rc"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=copilot_signoff_unreadable'; } \
    && pass "…and so does an unreadable Copilot signoff, which selects the arm" \
    || die "an unreadable Copilot signoff gave '${got}'"

# ── A SHA OF ANOTHER SHAPE IS NOT AN ANSWER ────────────────────────────────
# `sha` prints 40 hex or nothing, so this cannot come from the helper — which is
# the point. What this prints is what the merge gate is pinned to.
world; printf 'not-a-sha\n' > "$W/codex.sha"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=bad_codex_sha'; } \
    && pass "a Codex sha of another shape refuses rather than being pinned to" \
    || die "a malformed Codex sha gave '${got}'"
# THE MALFORMED COPILOT SHA IS THE FIRST ARM OF THE BRANCH, not a guard before it.
# Read as "no signoff" it would send the operator back through a phase that is
# closed; and with a head malformed the same way it would SELECT the post-Copilot
# arm on two values that match only because both are wrong.
world; printf 'not-a-sha\n' > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=bad_copilot_sha'; } \
    && pass "…and so does a Copilot sha of another shape" \
    || die "a malformed Copilot sha gave '${got}'"
world; printf 'not-a-sha\n' > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
printf 'not-a-sha\n' > "$W/head.out"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qvF 'state=after-copilot'; } \
    && pass "…and a head malformed the same way does not select the post-Copilot arm" \
    || die "two matching malformed values selected an arm: '${got}'"

# ── THE HEAD READ FAILS CLOSED TOO ─────────────────────────────────────────
# Anything `gh` printed before failing is not data: command substitution keeps it,
# so a call that emitted a plausible sha and then errored reads as success unless
# the status is checked AND the shape validated.
world; printf '1\n' > "$W/head.rc"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=head_unreadable'; } \
    && pass "a failed head read fails closed" \
    || die "a failed head read gave '${got}'"
world; printf 'error: something\n' > "$W/head.out"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=bad_head'; } \
    && pass "…and so does a head of another shape that arrived with status 0" \
    || die "a malformed head gave '${got}'"

# ── THE RECORD IS HISTORY, NOT A CURRENT FACT ──────────────────────────────
# A push while the stop was parked leaves the marker exactly as it was.
world; printf '%s\n' "$OTHER40" > "$W/head.out"
got="$(run 7)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'status=stopped reason=head_moved'; } \
    && pass "a head that moved past the Codex signoff stops before the Copilot phase" \
    || die "a moved head gave '${got}'"
printf '%s' "${got#*|}" | grep -qF 'state=' \
    && die "…but it also reported a state" \
    || pass "…and reports no state"

# A REVIEW CAN BE DISMISSED AFTER THE MARKER WAS WRITTEN, which leaves the record
# saying something that is no longer true.
world; printf '1\n' > "$W/codex.verdict.rc"
printf 'PR_REVIEW_STATE verdict=findings\n' > "$W/codex.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_verdict_withdrawn'; } \
    && pass "a Codex verdict that no longer stands stops, though the marker is unchanged" \
    || die "a withdrawn Codex verdict gave '${got}'"
world; printf '%s\n' "$HEAD40" > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
printf '%s\n' "$OTHER40" > "$W/codex.sha"
printf '1\n' > "$W/copilot.verdict.rc"
got="$(run 7)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'reason=copilot_verdict_withdrawn'; } \
    && pass "…and so does a Copilot verdict, on the arm where that is the one that must hold" \
    || die "a withdrawn Copilot verdict gave '${got}'"

# ── "NOT CLEAN" AND "COULD NOT READ IT" ARE DIFFERENT ANSWERS ──────────────
# `pr-review-state.sh verdict` documents 0 clean, 1 not clean, 2 unreadable, and a
# `-ne 0` test folds the last two together. A dismissal is a phase to reopen; an
# unreadable reviews endpoint is not an answer about the phase at all, and
# reporting it as one sends the operator to re-request a review nobody dismissed.
world; printf '2\n' > "$W/codex.verdict.rc"
printf 'PR_REVIEW_STATE verdict=error reason=unreadable\n' > "$W/codex.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_verdict_unreadable'; } \
    && pass "an unreadable Codex verdict fails closed rather than reading as a dismissal" \
    || die "an unreadable Codex verdict gave '${got}'"
printf '%s' "${got#*|}" | grep -qF 'withdrawn' \
    && die "…but it reported the phase as reopened as well" \
    || pass "…and does not tell the operator to re-request a review"
world; printf '%s\n' "$HEAD40" > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
printf '%s\n' "$OTHER40" > "$W/codex.sha"
printf '2\n' > "$W/copilot.verdict.rc"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=copilot_verdict_unreadable'; } \
    && pass "…and so does an unreadable Copilot verdict, on the other arm" \
    || die "an unreadable Copilot verdict gave '${got}'"
printf '%s' "${got#*|}" | grep -qF 'withdrawn' \
    && die "…but it reported that phase as reopened as well" \
    || pass "…without telling the operator to re-request that one either"

# ── EACH ARM RE-VALIDATES ITS OWN REVIEWER, NOT THE OTHER ──────────────────
# The post-Copilot arm must not ask about Codex: its signoff is older than the
# head by design, so a verdict lookup pinned to that sha proves nothing about what
# is being merged — and a Codex review dismissed after the phase closed would stop
# a merge the gate is there to decide.
world; printf '%s\n' "$HEAD40" > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
printf '%s\n' "$OTHER40" > "$W/codex.sha"
printf '1\n' > "$W/codex.verdict.rc"
got="$(run 7)"
{ [ "${got%%|*}" = 0 ] && printf '%s' "${got#*|}" | grep -qF 'state=after-copilot'; } \
    && pass "the post-Copilot arm does not re-validate the Codex verdict" \
    || die "the post-Copilot arm asked about Codex: '${got}'"
grep -q -- 'pr-review-state.sh verdict 7 chatgpt-codex-connector' "$TMP/calls" \
    && die "…but it looked the Codex verdict up anyway" \
    || pass "…and never looks it up"

# ── THE ARGUMENT IS REQUIRED AND CHECKED ───────────────────────────────────
world; got="$(run)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=bad_pr'; } \
    && pass "a missing PR number refuses" \
    || die "a missing PR gave '${got}'"
world; got="$(run notanumber)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=bad_pr'; } \
    && pass "…and so does one that is not a number" \
    || die "a non-numeric PR gave '${got}'"

# ── IT REFUSES TO RUN UNPRIVILEGED ─────────────────────────────────────────
# `$-` proves less than it looks and is a last-resort refusal, but the honest
# mistake — calling the file with a plain `bash` — is what it catches.
world
out="$(cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    bash "$DIR/pr-phase-state.sh" 7 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && printf '%s' "$out" | grep -qF 'reason=not_privileged'; } \
    && pass "an unprivileged interpreter is refused" \
    || die "an unprivileged run gave rc=$rc '$out'"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
