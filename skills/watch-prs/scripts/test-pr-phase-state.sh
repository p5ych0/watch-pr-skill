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
# TWO QUESTIONS, TWO ANSWERS. `sha` asks for the head alone; the bare form asks
# for the whole record, which is what the replies-only escape reads for its `at=`.
# A stub serving one to both would make the escape's ordering test unreachable.
if [ "${1:-}" = sha ]; then
    [ -f "$W/$_w.sha" ] && cat "$W/$_w.sha"
    exit "$(cat "$W/$_w.rc" 2>/dev/null || echo 0)"
fi
[ -f "$W/$_w.record" ] && cat "$W/$_w.record"
exit "$(cat "$W/$_w.record.rc" 2>/dev/null || echo 1)"
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
# `review-at` IS A DIFFERENT QUESTION FROM `verdict`, and the replies-only escape
# asks both about the same reviewer. Keyed on the subcommand as well, so one
# cannot answer for the other.
if [ "${1:-}" = review-at ]; then
    [ -f "$W/$_w.at.out" ] && cat "$W/$_w.at.out"
    exit "$(cat "$W/$_w.at.rc" 2>/dev/null || echo 0)"
fi
# WHEN THE NEWEST REPLY LANDED, which is a different moment again — and the
# ordinary answer is 1 with nothing, meaning that channel had nothing to say.
if [ "${1:-}" = replies-at ]; then
    [ -f "$W/$_w.replies.out" ] && cat "$W/$_w.replies.out"
    exit "$(cat "$W/$_w.replies.rc" 2>/dev/null || echo 1)"
fi
# A REAL CLEAN RECORD BY DEFAULT, built from the arguments it was asked with —
# `verdict <pr> <who> <sha>` — so the ordinary world is one where the answer is
# about what was asked. A stub that printed nothing made every rc-0 path look
# like the malformed-probe case, which is a case of its own below.
if [ -f "$W/$_w.verdict.out" ]; then
    cat "$W/$_w.verdict.out"
else
    printf 'PR_REVIEW_STATE pr=%s sha=%s reviewer=%s verdict=clean findings=0\n' "$2" "$(printf '%s' "${4:-}" | cut -c1-7)" "$3"
fi
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
    # NO SIGNOFF RECORD by default: the escape below is the exception, not the
    # ordinary path, and a world that vouched by default would hide every case
    # that depends on its absence.
    printf '1\n' > "$W/codex.record.rc"
    printf '1\n' > "$W/copilot.record.rc"
    printf '2026-01-01T00:00:00Z\n' > "$W/codex.at.out"
    printf '2026-01-01T00:00:00Z\n' > "$W/copilot.at.out"
}
replies_only() {   # replies_only <codex|copilot> <bot> <sha> ; only replies on that head
    printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=findings findings=1 source=replies-only\n' \
        "$(printf '%s' "$3" | cut -c1-7)" "$2" > "$W/$1.verdict.out"
    printf '1\n' > "$W/$1.verdict.rc"
}
replied_at() {   # replied_at <codex|copilot> <time> ; the newest reply landed then
    printf '%s\n' "$2" > "$W/$1.replies.out"
    printf '0\n' > "$W/$1.replies.rc"
}
vouched() {   # vouched <codex|copilot> <bot> <sha> [at] ; an operator answered it
    printf 'PR_SIGNOFF pr=7 reviewer=%s at=%s id=901 sha=%s\n' \
        "$2" "${4:-2026-01-02T00:00:00Z}" "$3" > "$W/$1.record"
    printf '0\n' > "$W/$1.record.rc"
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

# ── A FULL-WIDTH RECORD IS ACCEPTED ON BOTH ARMS ───────────────────────────
# The identity check compares the record at ITS OWN WIDTH rather than against a
# seven-hex cut this script makes. Every other record here is seven hex, so a
# caller pinned back to seven would pass the whole file — `test-recordlib.sh`
# proves what the library accepts and nothing about what this helper asks it, and
# the regression would be a valid phase refused. #126.
world; printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0\n' \
    "$HEAD40" "$CODEXBOT" > "$W/codex.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 0 ] && printf '%s' "${got#*|}" | grep -qF 'state=before-copilot'; } \
    && pass "a verdict carrying the full forty-hex head is accepted before the Copilot phase" \
    || die "a full-width verdict was refused: '${got}'"
world; printf '%s\n' "$HEAD40" > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
printf '%s\n' "$OTHER40" > "$W/codex.sha"
printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0\n' \
    "$HEAD40" "$COPILOTBOT" > "$W/copilot.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 0 ] && printf '%s' "${got#*|}" | grep -qF 'state=after-copilot'; } \
    && pass "…and after it, on the arm where the Copilot signoff is the one that must hold" \
    || die "a full-width verdict was refused on the post-Copilot arm: '${got}'"

# ── THE RECORD IS VALIDATED, NOT ONLY THE STATUS ───────────────────────────
# A probe that exits 0 while printing nothing, or a line about another PR,
# reviewer or head, is not an answer about this phase — and acting on the status
# alone turns a malformed probe into permission to continue. The two gates beside
# this helper validate; this one did not. #126.
world; : > "$W/codex.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_verdict_unparseable'; } \
    && pass "an rc-0 verdict with no record refuses rather than reading as clean" \
    || die "an empty rc-0 verdict gave '${got}'"
world; printf 'PR_REVIEW_STATE pr=8 sha=%s reviewer=%s verdict=clean findings=0\n' \
    "$(printf '%s' "$HEAD40" | cut -c1-7)" "$CODEXBOT" > "$W/codex.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_verdict_misaddressed'; } \
    && pass "…and one about another PR refuses" \
    || die "a record for another PR was accepted: '${got}'"
world; printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0\n' \
    "$(printf '%s' "$HEAD40" | cut -c1-7)" "$COPILOTBOT" > "$W/codex.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_verdict_misaddressed'; } \
    && pass "…and one about another reviewer refuses" \
    || die "a record for another reviewer was accepted: '${got}'"
world; printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0\n' \
    "$(printf '%s' "$OTHER40" | cut -c1-7)" "$CODEXBOT" > "$W/codex.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_verdict_misaddressed'; } \
    && pass "…and one about another head refuses" \
    || die "a record for another head was accepted: '${got}'"
# THE VALUE TOO, since rc 0 and `verdict=findings` disagree and only the record
# says which the reviewer meant.
world; printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=findings findings=3\n' \
    "$(printf '%s' "$HEAD40" | cut -c1-7)" "$CODEXBOT" > "$W/codex.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_verdict_not_clean'; } \
    && pass "…and an rc-0 record that is not clean refuses" \
    || die "a non-clean rc-0 record was accepted: '${got}'"
# THE TAIL AS WELL AS THE VALUE. `verdict=clean` with the `findings=0` truncated
# away is not a clean answer, and read as one it closes the phase on a record
# that was cut short. The library hands the tail back rather than accepting it,
# so this rule is the caller's to state.
world; printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean\n' \
    "$(printf '%s' "$HEAD40" | cut -c1-7)" "$CODEXBOT" > "$W/codex.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_verdict_truncated'; } \
    && pass "…and a clean record with its findings count truncated away refuses" \
    || die "a truncated clean record was accepted: '${got}'"
world; printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0 extra=1\n' \
    "$(printf '%s' "$HEAD40" | cut -c1-7)" "$CODEXBOT" > "$W/codex.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_verdict_truncated'; } \
    && pass "…and one carrying a field nobody defined refuses too" \
    || die "an extended clean record was accepted: '${got}'"
world; printf '%s\n' "$HEAD40" > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
printf '%s\n' "$OTHER40" > "$W/codex.sha"
printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean\n' \
    "$(printf '%s' "$HEAD40" | cut -c1-7)" "$COPILOTBOT" > "$W/copilot.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=copilot_verdict_truncated'; } \
    && pass "…and the post-Copilot arm refuses a truncated clean record as well" \
    || die "the post-Copilot arm accepted a truncated clean record: '${got}'"

# AND THE SAME ON THE OTHER ARM, where the Copilot signoff is the one that must
# hold — a rule missing from one of two arms is this repository's recurring shape.
world; printf '%s\n' "$HEAD40" > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
printf '%s\n' "$OTHER40" > "$W/codex.sha"
: > "$W/copilot.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=copilot_verdict_unparseable'; } \
    && pass "…and the post-Copilot arm refuses an rc-0 verdict with no record" \
    || die "the post-Copilot arm accepted an empty rc-0 verdict: '${got}'"
world; printf '%s\n' "$HEAD40" > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
printf '%s\n' "$OTHER40" > "$W/codex.sha"
printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0\n' \
    "$(printf '%s' "$OTHER40" | cut -c1-7)" "$COPILOTBOT" > "$W/copilot.verdict.out"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=copilot_verdict_misaddressed'; } \
    && pass "…and one about another head there too" \
    || die "the post-Copilot arm accepted a record for another head: '${got}'"

# ── THE ONE VERDICT AN OPERATOR CAN ANSWER FOR ─────────────────────────────
# A review whose comments are ALL replies reports `verdict=findings` with
# `source=replies-only`: nothing to fix and not a signoff, so `verdict` exits 1
# the same as for a dismissal — the STATUS cannot tell them apart, only the
# record can. Reported as a dismissal it sends a resumed session to reopen a
# phase the operator has already answered, which is the deadlock the escape
# exists to end. The merge gate had it; this helper did not. #125.
world; replies_only codex "$CODEXBOT" "$HEAD40"; vouched codex "$CODEXBOT" "$HEAD40"
got="$(run 7)"
{ [ "${got%%|*}" = 0 ] && printf '%s' "${got#*|}" | grep -qF 'state=before-copilot'; } \
    && pass "a replies-only review the operator signed off still reads as a closed phase" \
    || die "a vouched replies-only review was read as a dismissal: '${got}'"
# WITHOUT THAT RECORD IT REFUSES, and says which of the two it was. Absence is not
# a disagreement, but here the signoff is the AUTHORITY rather than a cross-check.
world; replies_only codex "$CODEXBOT" "$HEAD40"
got="$(run 7)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_replies_only_unvouched'; } \
    && pass "…and one nobody signed off refuses, naming what it was" \
    || die "an unvouched replies-only review gave '${got}'"
# THE RENDERED MESSAGE, not only the reason field. The commonest unvouched case —
# nothing recorded at all — returned without setting a reason, so the prose the
# operator reads named an empty pair of brackets.
printf '%s' "${got#*|}" | grep -qF '(no_signoff)' \
    && pass "…and the prose says why rather than leaving empty brackets" \
    || die "the unvouched stop rendered without a reason: '${got#*|}'"
printf '%s' "${got#*|}" | grep -qF 'withdrawn' \
    && die "…but it called it a dismissal as well" \
    || pass "…rather than reporting it as a dismissal"
# A HEAD IS NOT A MOMENT. A signoff recorded for an earlier CLEAN review on an
# unchanged head would vouch for a later replies-only review nobody read, so the
# record must be NEWER than the review it answers.
world; replies_only codex "$CODEXBOT" "$HEAD40"
vouched codex "$CODEXBOT" "$HEAD40" 2025-12-31T00:00:00Z
got="$(run 7)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_replies_only_unvouched'; } \
    && pass "…and one recorded before the review does not answer it" \
    || die "a stale signoff vouched for a later review: '${got}'"
# EQUAL IS NOT NEWER: second-resolution timestamps cannot order a tie, and this is
# permission to close a phase.
world; replies_only codex "$CODEXBOT" "$HEAD40"
vouched codex "$CODEXBOT" "$HEAD40" 2026-01-01T00:00:00Z
got="$(run 7)"
[ "${got%%|*}" = 1 ] \
    && pass "…and one recorded in the same second cannot be ordered, so it refuses" \
    || die "a same-second signoff vouched: '${got}'"
# AND IT MUST NAME THIS HEAD.
world; replies_only codex "$CODEXBOT" "$HEAD40"; vouched codex "$CODEXBOT" "$OTHER40"
got="$(run 7)"
[ "${got%%|*}" = 1 ] \
    && pass "…and one naming another commit does not answer this review" \
    || die "a signoff for another head vouched: '${got}'"
# THE SAME ON THE OTHER ARM. A rule missing from one of two arms is this
# repository's recurring shape, and this one IS that shape one level up: the
# escape existed in the merge gate and not here.
world; printf '%s\n' "$HEAD40" > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
printf '%s\n' "$OTHER40" > "$W/codex.sha"
replies_only copilot "$COPILOTBOT" "$HEAD40"; vouched copilot "$COPILOTBOT" "$HEAD40"
got="$(run 7)"
{ [ "${got%%|*}" = 0 ] && printf '%s' "${got#*|}" | grep -qF 'state=after-copilot'; } \
    && pass "…and the post-Copilot arm honours it too" \
    || die "the post-Copilot arm read a vouched replies-only review as a dismissal: '${got}'"
world; printf '%s\n' "$HEAD40" > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
printf '%s\n' "$OTHER40" > "$W/codex.sha"
replies_only copilot "$COPILOTBOT" "$HEAD40"
got="$(run 7)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'reason=copilot_replies_only_unvouched'; } \
    && pass "…and refuses an unvouched one there as well" \
    || die "the post-Copilot arm accepted an unvouched replies-only review: '${got}'"
# A REPLY ADDED AFTER THE SIGNOFF IS NOT ANSWERED BY IT. The verdict is produced
# by the COMMENTS on the review, and one added afterwards does not move the
# review's `submitted_at`: review at T1, signoff at T2, retraction at T3, and
# ordered against the review alone `T2 > T1` still held. #129.
world; replies_only codex "$CODEXBOT" "$HEAD40"; vouched codex "$CODEXBOT" "$HEAD40"
replied_at codex 2026-01-03T00:00:00Z
got="$(run 7)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_replies_only_unvouched'; } \
    && pass "a reply landing after the signoff is not answered by it" \
    || die "a later reply was vouched over: '${got}'"
# AND ONE BEFORE IT STILL CLOSES THE PHASE, or the rule would only ever refuse.
world; replies_only codex "$CODEXBOT" "$HEAD40"; vouched codex "$CODEXBOT" "$HEAD40"
replied_at codex 2026-01-01T12:00:00Z
got="$(run 7)"
{ [ "${got%%|*}" = 0 ] && printf '%s' "${got#*|}" | grep -qF 'state=before-copilot'; } \
    && pass "…while one that landed before it still does" \
    || die "an earlier reply blocked the phase: '${got}'"
# EQUAL IS NOT NEWER HERE EITHER.
world; replies_only codex "$CODEXBOT" "$HEAD40"; vouched codex "$CODEXBOT" "$HEAD40"
replied_at codex 2026-01-02T00:00:00Z
got="$(run 7)"
[ "${got%%|*}" = 1 ] \
    && pass "…and one in the same second cannot be ordered" \
    || die "a same-second reply was ordered: '${got}'"
# AN UNREADABLE REPLY TIME IS NOT "NO REPLIES": read as one, the retracting reply
# it could not see is exactly what the phase closes over.
world; replies_only codex "$CODEXBOT" "$HEAD40"; vouched codex "$CODEXBOT" "$HEAD40"
printf '2\n' > "$W/codex.replies.rc"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_vouch_unreadable'; } \
    && pass "…and an unreadable reply time fails closed" \
    || die "an unreadable reply time gave '${got}'"
# THE SAME ON THE OTHER ARM.
world; printf '%s\n' "$HEAD40" > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
printf '%s\n' "$OTHER40" > "$W/codex.sha"
replies_only copilot "$COPILOTBOT" "$HEAD40"; vouched copilot "$COPILOTBOT" "$HEAD40"
replied_at copilot 2026-01-03T00:00:00Z
got="$(run 7)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'reason=copilot_replies_only_unvouched'; } \
    && pass "…and the post-Copilot arm orders against the reply too" \
    || die "the post-Copilot arm vouched over a later reply: '${got}'"

# AN UNREADABLE PROBE IS NOT "NOBODY SIGNED IT OFF". Folded together, an
# unreadable read tells the operator to record a signoff they may already have
# recorded, and hides a broken read behind an ordinary-looking refusal. Both
# probes, on both arms.
world; replies_only codex "$CODEXBOT" "$HEAD40"; printf '2\n' > "$W/codex.record.rc"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_vouch_unreadable'; } \
    && pass "an unreadable signoff probe fails closed rather than reading as unvouched" \
    || die "an unreadable signoff probe gave '${got}'"
printf '%s' "${got#*|}" | grep -qF 'unvouched' \
    && die "…but it also told the operator to record a signoff" \
    || pass "…and does not send the operator to record one"
world; replies_only codex "$CODEXBOT" "$HEAD40"; vouched codex "$CODEXBOT" "$HEAD40"
printf '2\n' > "$W/codex.at.rc"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_vouch_unreadable'; } \
    && pass "…and so does an unreadable review time" \
    || die "an unreadable review time gave '${got}'"
world; printf '%s\n' "$HEAD40" > "$W/copilot.sha"; printf '0\n' > "$W/copilot.rc"
printf '%s\n' "$OTHER40" > "$W/codex.sha"
replies_only copilot "$COPILOTBOT" "$HEAD40"; printf '2\n' > "$W/copilot.record.rc"
got="$(run 7)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "${got#*|}" | grep -qF 'reason=copilot_vouch_unreadable'; } \
    && pass "…on the post-Copilot arm too" \
    || die "the post-Copilot arm folded an unreadable probe into unvouched: '${got}'"
# A SIGNOFF FOR ANOTHER REVIEWER DOES NOT VOUCH, even with the same head: the
# whole record is read, not its suffix.
world; replies_only codex "$CODEXBOT" "$HEAD40"
printf 'PR_SIGNOFF pr=7 reviewer=%s at=2026-01-02T00:00:00Z id=901 sha=%s\n' \
    "$COPILOTBOT" "$HEAD40" > "$W/codex.record"
printf '0\n' > "$W/codex.record.rc"
got="$(run 7)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_replies_only_unvouched'; } \
    && pass "…and a signoff naming another reviewer does not vouch" \
    || die "another reviewer's signoff vouched: '${got}'"

# A VERDICT THAT IS NOT THAT SHAPE IS STILL A DISMISSAL. The escape is narrow: it
# applies to `source=replies-only` and to nothing else, however many findings a
# review reports.
world; printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=findings findings=2\n' \
    "$(printf '%s' "$HEAD40" | cut -c1-7)" "$CODEXBOT" > "$W/codex.verdict.out"
printf '1\n' > "$W/codex.verdict.rc"
vouched codex "$CODEXBOT" "$HEAD40"
got="$(run 7)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'reason=codex_verdict_withdrawn'; } \
    && pass "…while a review with findings is a dismissal, signoff or no signoff" \
    || die "the escape widened past replies-only: '${got}'"

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
