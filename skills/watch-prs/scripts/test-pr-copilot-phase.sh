#!/usr/bin/env bash
# Unit tests for pr-copilot-phase.sh.
#
# This is the Codex→Copilot transition, which lived in `SKILL.md` as 176 lines of
# prose-embedded shell that nothing executed. What it does is mostly ORDERING and
# REFUSING — prove the verdict on an exact sha, prove that sha's checks, record
# the signoff, and only then ask — so `gh` and the helpers are stubbed and every
# call is logged in sequence.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-copilot-phase.sh"

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
# `pr-review-state.sh` ANSWERS TWO DIFFERENT QUESTIONS HERE — `verdict` and
# `review-id` — and they fail independently, so the stub keys on the subcommand
# rather than serving one answer to both.
cat > "$DIR/pr-review-state.sh" <<'STATESH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$CALLS"
# A PUSH CAN LAND WHILE A PROBE RUNS. When the case asks for it, this moves the
# head during the lookup — which is exactly the window the re-read before the
# mutations exists to close.
[ -f "$W/move-head-on-probe" ] && cat "$W/move-head-on-probe" > "$W/head.out"
case "${1:-}" in
    verdict)   _n=$(( $(cat "$W/verdict.n" 2>/dev/null || echo 0) + 1 )); printf '%s' "$_n" > "$W/verdict.n"
               if [ "$_n" -ge 2 ] && [ -f "$W/verdict.2.rc" ]; then
                   cat "$W/verdict.2.out" 2>/dev/null; exit "$(cat "$W/verdict.2.rc")"
               fi
               cat "$W/verdict.out" 2>/dev/null
               exit "$(cat "$W/verdict.rc" 2>/dev/null || echo 0)" ;;
    review-id) # THE BASELINE IS READ ONCE, LAST. A pass that lands during the
               # probes must not be the value handed to `--after-review`, so the
               # fixture can change what this returns after the revocation.
               [ -f "$W/posted" ] && [ -f "$W/review-id.after.out" ] \
                   && { cat "$W/review-id.after.out"; exit 0; }
               cat "$W/review-id.out" 2>/dev/null
               exit "$(cat "$W/review-id.rc" 2>/dev/null || echo 0)" ;;
esac
exit 2
STATESH
chmod +x "$DIR/pr-review-state.sh"
cat > "$DIR/pr-signoff.sh" <<'SIGNSH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$CALLS"
# A SECOND ANSWER, FOR THE SECOND ASK. The phase is proved twice — once up front
# and once immediately before the mutations — and the whole question is what
# happens when another session changes something in between. `.2` is that change.
_n=$(( $(cat "$W/signoff.n" 2>/dev/null || echo 0) + 1 )); printf '%s' "$_n" > "$W/signoff.n"
if [ "$_n" -ge 2 ] && [ -f "$W/signoff.2.out" ]; then
    cat "$W/signoff.2.out"; exit "$(cat "$W/signoff.2.rc" 2>/dev/null || echo 0)"
fi
[ -f "$W/signoff.out" ] && cat "$W/signoff.out"
exit "$(cat "$W/signoff.rc" 2>/dev/null || echo 0)"
SIGNSH
chmod +x "$DIR/pr-signoff.sh"
for h in pr-ci-gate.sh pr-round-count.sh; do
    cat > "$DIR/$h" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$0")" "\$*" >> "\$CALLS"
_n="\$(basename "\$0" .sh)"
[ -f "\$W/\${_n}.out" ] && cat "\$W/\${_n}.out"
exit "\$(cat "\$W/\${_n}.rc" 2>/dev/null || echo 0)"
STUB
    chmod +x "$DIR/$h"
done
# THE COMMENT BODY IS KEPT, not just the fact of the call. A summary that posts
# the signoff marker mangled, or the caller's paragraph expanded as shell, is a
# successful `gh pr comment` — so the fixture reads what was actually sent.
cat > "$TMP/bin/gh" <<'GHSH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$CALLS"
case " $* " in
    *" pr view "*)    cat "$W/head.out" 2>/dev/null
                      exit "$(cat "$W/head.rc" 2>/dev/null || echo 0)" ;;
    *" pr comment "*) _b=""
                      while [ $# -gt 0 ]; do
                          [ "$1" = --body ] && { _b="$2"; break; }
                          shift
                      done
                      printf '%s' "$_b" >> "$W/posted"
                      exit "$(cat "$W/comment.rc" 2>/dev/null || echo 0)" ;;
    *" pr edit "*)    exit "$(cat "$W/edit.rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
GHSH
chmod +x "$TMP/bin/gh"

world() {   # world ; the state in which the phase advances cleanly
    W="$TMP/w"; rm -rf "$W"; mkdir -p "$W"; : > "$TMP/calls"
    printf '%s\n' "$HEAD40" > "$W/head.out"
    printf 'PR_REVIEW_STATE verdict=clean findings=0\n' > "$W/verdict.out"
    printf '42\n' > "$W/review-id.out"
    printf 'PR_SIGNOFF pr=7 reviewer=%s sha=%s\n' "$CODEXBOT" "$HEAD40" > "$W/signoff.out"
    printf 'the paragraph about what changed\n' > "$TMP/body.md"
}
run() {   # run <stage> [args…] ; prints "<rc>|<output>"
    local out rc=0
    out="$(cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        "$DIR/pr-copilot-phase.sh" "$@" 2>&1)" || rc=$?
    printf '%s|%s' "$rc" "$out"
}
posted() { cat "$W/posted" 2>/dev/null; }
# `before <a> <b>` — a happened earlier in the call log than b.
before() {
    local la lb
    la="$(grep -n -- "$1" "$TMP/calls" | head -1 | cut -d: -f1)"
    lb="$(grep -n -- "$2" "$TMP/calls" | head -1 | cut -d: -f1)"
    { [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; }
}

# ── the phase advances at all ──────────────────────────────────────────────
world; got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 0 ] && printf '%s' "${got#*|}" | grep -qF "PR_PHASE_RECORDED pr=7 reviewer=$CODEXBOT codex-sha=$HEAD40"; } \
    && pass "a clean Codex verdict records the phase" \
    || die "record gave '${got}'"
printf '%s' "${got#*|}" | grep -qF "pr-copilot-phase.sh open 7 $HEAD40" \
    && pass "…and the stop names the command that opens the phase" \
    || die "the operator stop does not say how to resume: '${got#*|}'"

# ── WHAT IT POSTS IS THE RECORD SOMETHING LATER READS BACK ─────────────────
# The marker's format is `pr-signoff.sh`'s: the name and the sha in backticks, on
# a line of their own. Composed here rather than left to the caller's prose,
# because a marker one character off signs nothing off and still looks posted.
posted | grep -qF "**Review-Signoff:** \`$CODEXBOT\` \`$HEAD40\`" \
    && pass "the summary carries the signoff marker in the form pr-signoff.sh reads" \
    || die "the posted marker was: $(posted | head -3)"
posted | grep -qF 'the paragraph about what changed' \
    && pass "…and the caller's account of the phase" \
    || die "the caller's body is not in what was posted"
posted | grep -qF 'Review-Phase: copilot' \
    && pass "…and the trailer the merge gate depends on" \
    || die "the trailer note is missing from the summary"

# THE BODY IS DATA, NOT A TEMPLATE. This was a heredoc the shell expanded: a
# summary quoting a finding about a command substitution EXECUTED it while being
# written, and text lifted from an untrusted PR description is the same
# substitution with someone else choosing the command. Where it did not execute it
# vanished silently, which is worse — `cat` still succeeded.
world; printf 'before $(touch %s/PWNED) `touch %s/PWNED2` after\n' "$W" "$W" > "$TMP/body.md"
run record 7 "$TMP/body.md" >/dev/null
{ [ ! -f "$W/PWNED" ] && [ ! -f "$W/PWNED2" ]; } \
    && pass "a body containing shell substitutions is not executed while being written" \
    || die "the body was executed: $(ls "$W")"
posted | grep -qF '$(touch' \
    && pass "…and reaches the PR verbatim rather than silently emptied" \
    || die "the substitution vanished from the posted body: $(posted)"

# ── THE VERDICT AND THE CHECKS ARE ABOUT THE CAPTURED SHA ──────────────────
# Not about "whatever the API calls the head now". A push landing between the
# verdict and this lookup records an unreviewed head as the signoff, and the merge
# gate only discovers the missing verdict after the whole Copilot phase has run.
world; run record 7 "$TMP/body.md" >/dev/null
grep -qF "pr-review-state.sh verdict 7 $CODEXBOT $HEAD40" "$TMP/calls" \
    && pass "the verdict is re-validated against the sha being recorded" \
    || die "the verdict was not pinned to the captured sha: $(grep review-state "$TMP/calls")"
grep -qF "pr-ci-gate.sh 7 $HEAD40" "$TMP/calls" \
    && pass "…and the checks are asked about that same sha" \
    || die "the CI gate was not pinned to the captured sha: $(grep ci-gate "$TMP/calls")"
# NOTHING IS PUBLISHED UNTIL ALL THREE HAVE ANSWERED — the verdict, the checks
# and the round count. Establishing the boundary and ACTING on it are separate:
# the count is read before the post so an unreadable one leaves nothing behind,
# and the pause is taken after it, because the pause offers "merge on the Codex
# signoff" and that signoff has to exist by then. Nothing in this stage requests a
# review, so publishing before the pause queues nothing.
{ before 'pr-review-state.sh verdict' 'pr-ci-gate' \
    && before 'pr-ci-gate' 'pr-round-count' \
    && before 'pr-round-count' 'gh pr comment'; } \
    && pass "…and nothing is published until the head and the boundary are both established" \
    || die "the phase posted before it had proved the head: $(cat "$TMP/calls")"

# ── EVERY PROOF IS A STOP, AND NOTHING IS RECORDED WHEN ONE FAILS ──────────
# A failed probe must never be indistinguishable from a clean phase: the signoff
# is what a later session trusts, so recording one that was not proven is the
# failure this whole file exists to prevent.
nothing_posted() {   # nothing_posted <label>
    [ -s "$W/posted" ] \
        && die "$1 — but the signoff was posted anyway" \
        || pass "$1"
}
world; printf '1\n' > "$W/verdict.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'Codex is not clean on the sha being recorded'; } \
    && pass "a verdict that is not clean stops the phase" \
    || die "an unclean verdict gave '${got}'"
nothing_posted "…with no signoff recorded"

world; printf '1\n' > "$W/pr-ci-gate.rc"
got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 1 ] \
    && pass "a head whose checks are not green stops the phase" \
    || die "a failing CI gate gave '${got}'"
nothing_posted "…with no signoff recorded"

world; printf '1\n' > "$W/head.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'could not capture the Codex-signed-off head'; } \
    && pass "an unreadable head stops the phase" \
    || die "an unreadable head gave '${got}'"
nothing_posted "…with no signoff recorded"

world; printf 'not-a-sha\n' > "$W/head.out"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'is not a full OID'; } \
    && pass "a head that is not a full OID stops the phase" \
    || die "a malformed head gave '${got}'"
nothing_posted "…with no signoff recorded"

# THE ABBREVIATED SHA IS THE ONE THAT MATTERS. `pr-review-state.sh` prints seven
# characters and the merge gate needs forty, so a phase recorded from the short
# form populates the gate with something it cannot match.
world; printf '%s\n' "${HEAD40:0:7}" > "$W/head.out"
got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 1 ] \
    && pass "…and so does an abbreviated one" \
    || die "a 7-character head gave '${got}'"

# ── THE BOUNDARY PAUSES THE TRANSITION ─────────────────────────────────────
# A phase that ends on the threshold-th reviewed head went straight from a clean
# verdict into the next phase, so the pause was skipped in exactly the case it
# exists for: long enough to reach the boundary AND about to commit to more work.
world; printf '3\n' > "$W/pr-round-count.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 3 ] && printf '%s' "${got#*|}" | grep -qF 'round boundary reached'; } \
    && pass "a round boundary pauses the transition" \
    || die "a boundary gave '${got}'"
# THE RECORD SURVIVES THE PAUSE. The boundary message offers "merge on the Codex
# signoff" and "leave it open", so a pause that exited before posting left the
# operator neither a durable signoff for a later session nor the sha the
# codex-only merge needs — they had to acknowledge the boundary and re-run this
# stage to recover a phase that was already proved clean.
posted | grep -qF "**Review-Signoff:** \`$CODEXBOT\` \`$HEAD40\`" \
    && pass "…with the signoff recorded, since the pause offers merging on it" \
    || die "the pause discarded the signoff it offers to merge on: $(posted)"
printf '%s' "${got#*|}" | grep -qF "codex-sha=$HEAD40" \
    && pass "…and the sha reported, so the codex-only merge path has it" \
    || die "the pause reported no sha: '${got#*|}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "the pause opened the Copilot phase anyway" \
    || pass "…and nothing requested, which is what the pause is for"

# AN UNREADABLE COUNT IS A STOP, AND A STOP LEAVES NOTHING BEHIND. Establishing
# the boundary before publishing and acting on it after are two requirements: with
# only the second, a count that could not be read exited with the signoff already
# posted, and a later session's `pr-signoff.sh` accepted that record without
# anyone having established whether a boundary was due.
world; printf '2\n' > "$W/pr-round-count.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'nothing recorded'; } \
    && pass "an unreadable round count is a stop, not a pause and not a pass" \
    || die "an unreadable count gave '${got}'"
nothing_posted "…with no signoff a later session could act on"
before 'pr-round-count' 'gh pr comment' \
    || pass "…the boundary having been established before anything was published"

# ── THE CALLER'S ACCOUNT IS REQUIRED ───────────────────────────────────────
world; got="$(run record 7)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'a body file is required'; } \
    && pass "the phase body is required" \
    || die "a missing body argument gave '${got}'"
world; got="$(run record 7 "$TMP/nope.md")"
[ "${got%%|*}" = 1 ] \
    && pass "…and a body file that is not there is a stop" \
    || die "a missing body file gave '${got}'"
world; : > "$TMP/empty.md"; got="$(run record 7 "$TMP/empty.md")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'the phase body is empty'; } \
    && pass "…and an empty one is too" \
    || die "an empty body gave '${got}'"
grep -q 'gh pr view' "$TMP/calls" \
    && die "it read the head before reading its own body" \
    || pass "…refused before any of the proving is done"

# A POST THAT FAILED RECORDED NOTHING, and the message has to say so: the signoff
# is the thing the next session reads, so "the phase advanced" and "the comment
# failed" must not look alike.
world; printf '1\n' > "$W/comment.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'the signoff is not recorded'; } \
    && pass "a failed post stops the phase and says the signoff is not recorded" \
    || die "a failed post gave '${got}'"

# ── PROSE MUST NOT BECOME A RECORD ────────────────────────────────────────
# The body quotes findings, PR descriptions and reviewer comments, and this
# comment is posted under an identity `pr-signoff.sh` and `pr-round-count.sh`
# trust. A line reproducing one of their markers CREATES the record it describes:
# a quoted finding about an acknowledgement becomes the acknowledgement, and the
# boundary it answers never fires again.
for _mk in '**Review-Pause-Acknowledged:** `chatgpt-codex-connector[bot]` `10`' \
           '**Review-Signoff:** `copilot-pull-request-reviewer[bot]` `deadbeef`' \
           '**Review-Signoff-Revoked:** `chatgpt-codex-connector[bot]`'; do
    world; printf 'the finding said it should read:\n%s\nand that is why\n' "$_mk" > "$TMP/body.md"
    got="$(run record 7 "$TMP/body.md")"
    { [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'reads as a record'; } \
        && pass "a body line that is a control marker is refused: ${_mk%% *}" \
        || die "a body carrying ${_mk%% *} gave '${got}'"
    nothing_posted "…and nothing was published under the operator's identity"
done
# A QUOTED `@codex review` REQUESTS A PASS. A comment CONTAINING it is the
# trigger, and this summary is posted standalone with the loop stopping right
# after — so the quoted mention starts a Codex pass that answers nobody.
world; printf 'the finding said to post `@codex review` afterwards\n' > "$TMP/body.md"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF "contains '@codex review'"; } \
    && pass "a body quoting the Codex trigger is refused" \
    || die "a body quoting @codex review gave '${got}'"
nothing_posted "…and nothing was posted to request that pass"
world; printf 'and then @CODEX REVIEW is posted\n' > "$TMP/body.md"
got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 1 ] \
    && pass "…in any case, since the trigger is not case-sensitive" \
    || die "an upper-case trigger gave '${got}'"

# `**Reviewed commit:**` IS NOT REFUSED: `pr-round-count.sh` reads it only from a
# reviewer bot's own comment, so a body posted here cannot create one.
world; printf 'the footer reads:\n**Reviewed commit:** `0123456789`\n' > "$TMP/body.md"
got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 0 ] \
    && pass "…while a marker no caller-posted body can create is left alone" \
    || die "the reviewed-commit footer was refused: '${got}'"

# INDENTED OR INLINE IS STILL PROSE, because the readers anchor these markers to
# the start of a line. Refusing those too would stop an author saying what a
# finding was about. A FENCE IS NOT one of those ways: the readers scan the raw
# body, where a line inside a fence still starts at column 0.
world; printf 'the finding said:\n\n    **Review-Signoff:** `x` `y`\n\nwhich is why\n' > "$TMP/body.md"
got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 0 ] \
    && pass "…while an indented one is prose and passes, as the readers see it" \
    || die "an indented marker was refused: '${got}'"

# ── open: THE PHASE OPENS ON THE HEAD THAT WAS SIGNED OFF ──────────────────
world; got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 0 ] && printf '%s' "${got#*|}" | grep -qF "PR_COPILOT_PHASE_OPENED pr=7 head=$HEAD40 prior-review=42"; } \
    && pass "the operator's answer opens the Copilot phase" \
    || die "open gave '${got}'"
grep -q -- '--add-reviewer @copilot' "$TMP/calls" \
    && pass "…by --add-reviewer, which is the only thing that requests Copilot" \
    || die "Copilot was not requested: $(cat "$TMP/calls")"
posted | grep -qF "**Review-Signoff-Revoked:** \`$COPILOTBOT\`" \
    && pass "…and any earlier Copilot signoff is revoked" \
    || die "no revocation was posted: $(posted)"
before 'gh pr comment' 'gh pr edit' \
    && pass "…before the request, so no window exists where a stale signoff describes a reopened phase" \
    || die "the request preceded the revocation: $(cat "$TMP/calls")"

# THE HEAD IS RE-PROVEN, because the operator's answer can arrive in a later
# session. Opening the phase against a moved head spends it on one commit and the
# merge gate on another, and only the gate finds out.
world; printf '%s\n' "$OTHER40" > "$W/head.out"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF "the head is $OTHER40, not the $HEAD40"; } \
    && pass "a head that moved since the signoff stops the phase from opening" \
    || die "a moved head gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested against a head Codex never signed off" \
    || pass "…with Copilot not requested"
[ -s "$W/posted" ] \
    && die "…but the previous signoff was revoked anyway" \
    || pass "…and nothing revoked, since the phase did not open"

# A RECORDED SIGNOFF IS HISTORY, NOT CURRENT STATE. A review dismissed while the
# head stood still leaves the head-equality check passing, so without re-reading
# the verdict the whole Copilot phase is spent before the merge gate discovers the
# signoff no longer describes a clean review.
world; printf '1\n' > "$W/verdict.rc"; got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF "Codex is no longer clean on $HEAD40"; } \
    && pass "a Codex review dismissed on an unchanged head stops the phase from opening" \
    || die "a same-head dismissal gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested on a signoff that no longer holds" \
    || pass "…with Copilot not requested"
[ -s "$W/posted" ] \
    && die "…but the previous Copilot signoff was revoked anyway" \
    || pass "…and nothing revoked, since the phase did not open"
grep -qF "pr-review-state.sh verdict 7 $CODEXBOT $HEAD40" "$TMP/calls" \
    && pass "…the verdict being re-read against the recorded sha, not the current head" \
    || die "open did not re-validate the verdict: $(cat "$TMP/calls")"

world; printf '1\n' > "$W/head.rc"; got="$(run open 7 "$HEAD40")"
[ "${got%%|*}" = 1 ] \
    && pass "an unreadable head stops the phase from opening" \
    || die "an unreadable head gave '${got}'"

# THE BASELINE IS READ BEFORE THE REQUEST, and a failed read is fatal: without it
# the watch cannot tell the new pass from the old one on an unchanged head.
world; printf '1\n' > "$W/review-id.rc"; got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'do not request a review blind'; } \
    && pass "an unreadable review id stops the phase from opening" \
    || die "an unreadable review id gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested with no baseline to wait past" \
    || pass "…with Copilot not requested"

# AN EMPTY BASELINE IS AN ANSWER: a head with no Copilot review yet has no id, and
# `pr-watch.sh` takes that as "wait on any terminal review".
world; : > "$W/review-id.out"; got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 0 ] && printf '%s' "${got#*|}" | grep -q 'PR_COPILOT_PHASE_OPENED .* prior-review=$'; } \
    && pass "a head with no Copilot review yet opens, reporting an empty baseline" \
    || die "an empty baseline gave '${got}'"

# A DISMISSAL OR A REVOCATION DURING THE PROBES. Neither moves the head, so the
# head check alone passes — and the phase is proved twice for exactly this: once
# up front, once immediately before the mutations.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s sha=none\n' "$CODEXBOT" > "$W/signoff.2.out"
printf '1\n' > "$W/signoff.2.rc"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'no current Codex signoff'; } \
    && pass "a Codex signoff revoked while the phase was being proved stops it" \
    || die "a mid-probe revocation gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested underneath a phase reopened mid-probe" \
    || pass "…with Copilot not requested"

world; printf '1\n' > "$W/verdict.2.rc"
printf 'PR_REVIEW_STATE verdict=none reason=dismissed\n' > "$W/verdict.2.out"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'no longer clean'; } \
    && pass "…and so does a verdict dismissed while it was being proved" \
    || die "a mid-probe dismissal gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested on a verdict withdrawn mid-probe" \
    || pass "…with Copilot not requested"

# THE BASELINE IS THE LAST THING READ BEFORE THE REQUEST. A Copilot pass already
# in flight on this unchanged head can finish during the probes or the revocation,
# and a baseline captured earlier would let `--after-review` accept that
# pre-request review as the answer to a request made after it.
world; printf '7\n' > "$W/review-id.out"; printf '99\n' > "$W/review-id.after.out"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 0 ] && printf '%s' "${got#*|}" | grep -q 'prior-review=99'; } \
    && pass "the baseline is read after the revocation, so a pass landing meanwhile is waited past" \
    || die "the baseline was captured before the revocation: '${got}'"
before 'gh pr comment' 'pr-review-state.sh review-id' \
    && pass "…and the call order says so" \
    || die "the baseline was read before the revocation: $(cat "$TMP/calls")"

# A PUSH DURING THE PROBES. The equality check passed, and the verdict is pinned
# to the recorded sha so it stays clean — while the revocation and the request
# would land on the moved PR, and `--add-reviewer` re-requests, so Copilot spends
# the phase on a head Codex never signed off.
world; printf '%s\n' "$OTHER40" > "$W/move-head-on-probe"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF "the head moved to $OTHER40"; } \
    && pass "a push landing while the phase is being proved stops it from opening" \
    || die "a head moving mid-probe gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested against a head that moved during the probes" \
    || pass "…with Copilot not requested"
[ -s "$W/posted" ] \
    && die "…but the previous Copilot signoff was revoked against the moved head" \
    || pass "…and nothing revoked"

# A REVOKED CODEX SIGNOFF MEANS THE PHASE WAS REOPENED. Reopening the Codex phase
# over an unchanged head posts a revocation and requests a new pass, and GitHub
# keeps serving the OLD clean verdict until that pass reports — so the verdict
# check passes and only the recorded signoff says what happened.
world; printf '1\n' > "$W/signoff.rc"; printf 'PR_SIGNOFF pr=7 reviewer=%s sha=none\n' "$CODEXBOT" > "$W/signoff.out"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'no current Codex signoff'; } \
    && pass "a revoked Codex signoff stops the phase from opening" \
    || die "a revoked signoff gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested underneath a reopened Codex phase" \
    || pass "…with Copilot not requested"
[ -s "$W/posted" ] \
    && die "…but Copilot's signoff was revoked anyway" \
    || pass "…and nothing revoked"

# …AND A SIGNOFF FOR A DIFFERENT HEAD IS NOT THIS ONE.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s sha=%s\n' "$CODEXBOT" "$OTHER40" > "$W/signoff.out"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'not for'; } \
    && pass "a recorded signoff naming another head stops the phase from opening" \
    || die "a mismatched signoff gave '${got}'"

# THE BOUNDARY IS ENFORCED AGAIN WHEN OPENING. `record` publishes the signoff
# before it pauses, so a later session can read that signoff back and arrive here
# with the boundary still unacknowledged — the pause skipped by the very resume
# path the published signoff exists to enable.
world; printf '3\n' > "$W/pr-round-count.rc"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 3 ] && printf '%s' "${got#*|}" | grep -qF 'not acknowledged'; } \
    && pass "an unacknowledged round boundary pauses the phase from opening" \
    || die "an unacknowledged boundary gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested past an unacknowledged boundary" \
    || pass "…with Copilot not requested"
[ -s "$W/posted" ] \
    && die "…but Copilot's signoff was revoked anyway" \
    || pass "…and nothing revoked"
world; printf '2\n' > "$W/pr-round-count.rc"
got="$(run open 7 "$HEAD40")"
[ "${got%%|*}" = 1 ] \
    && pass "…and an unreadable count there is a stop, not a pass" \
    || die "an unreadable count on open gave '${got}'"

world; printf '1\n' > "$W/comment.rc"; got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'could not revoke'; } \
    && pass "a failed revocation stops the phase from opening" \
    || die "a failed revocation gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested while a stale signoff still described the head" \
    || pass "…with Copilot not requested"

world; printf '1\n' > "$W/edit.rc"; got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'not permission to skip the pass'; } \
    && pass "a failed request stops, and says so rather than reading as a slow reviewer" \
    || die "a failed --add-reviewer gave '${got}'"

world; got="$(run open 7)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF "'open' needs the head"; } \
    && pass "open without the signed-off head is refused" \
    || die "open with no sha gave '${got}'"
world; got="$(run open 7 "${HEAD40:0:7}")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'is not a full OID'; } \
    && pass "…and an abbreviated one is refused, since the merge gate needs forty" \
    || die "open with a short sha gave '${got}'"

# ── THE STAGE IS NAMED, AND HAS NO DEFAULT ─────────────────────────────────
# The two halves have an operator decision between them: a caller that gets one
# when it meant the other has either skipped that decision or re-asked a question
# already answered.
world; got="$(run)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'a stage is required'; } \
    && pass "an absent stage is refused" \
    || die "no stage gave '${got}'"
world; got="$(run 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF "'7' is not a stage"; } \
    && pass "a PR number in stage position is refused by name" \
    || die "a stageless call gave '${got}'"
world; got="$(run start 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF "'start' is not a stage"; } \
    && pass "an unknown stage is refused by name" \
    || die "an unknown stage gave '${got}'"
world; got="$(run record x "$TMP/body.md")"
[ "${got%%|*}" = 1 ] \
    && pass "a PR number that is not a number is refused" \
    || die "a non-numeric PR gave '${got}'"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
