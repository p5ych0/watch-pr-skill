#!/usr/bin/env bash
# Unit tests for pr-close-round.sh.
#
# THIS IS THE FIRST TIME EITHER ROUND-CLOSING RECIPE HAS BEEN RUN BY ANYTHING.
# They were 56 and 191 lines of prose-embedded shell doing the same job in
# different ORDERS, and the order is the whole content: which of push, checks,
# summary and request happens before which, and what is irreversible by the time
# each one has.
#
# So these cases are mostly about ORDERING and about REFUSING. `gh` and `git` are
# stubbed and every call is logged in sequence, because "did it post the summary"
# is a weaker question than "did it post the summary before or after it knew the
# head was green".
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-close-round.sh"

TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

HEAD40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PREV40=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
CODEXBOT='chatgpt-codex-connector[bot]'
COPILOTBOT='copilot-pull-request-reviewer[bot]'

# ── the harness ────────────────────────────────────────────────────────────
# The subject is staged beside its libraries and a stub for every helper, exactly
# as `pr-merge-gate.sh`'s fixtures are: the script finds its siblings next to
# itself, which is what makes any of this possible.
DIR="$TMP/s"; mkdir -p "$DIR" "$TMP/bin"
cp "$SCRIPT" "$SELF_DIR/loadlib.sh" "$SELF_DIR/recordlib.sh" "$SELF_DIR/identitylib.sh" "$DIR/" \
    || { die "the subject could not be staged"; echo "RESULT: FAIL"; exit 1; }
# `pr-watch.sh` VALIDATES ITS BASELINE, like the real one: a stub that accepts
# anything cannot tell a well-formed id from the noise that stops the next round.
cat > "$DIR/pr-watch.sh" <<'WATCHSH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$CALLS"
_after=""
while [ $# -gt 0 ]; do
    [ "$1" = --after-review ] && { _after="$2"; shift 2; continue; }
    shift
done
case "${_after#comment:}" in
    ""|*[!0-9]*) printf 'PR_REVIEW_WATCH state=error reason=malformed_review_id detail=%s\n' "$_after"
                 exit 2 ;;
esac
exit "$(cat "$W/pr-watch.rc" 2>/dev/null || echo 0)"
WATCHSH
chmod +x "$DIR/pr-watch.sh"
for h in pr-round-count.sh pr-ci-gate.sh pr-review-state.sh; do
    cat > "$DIR/$h" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$0")" "\$*" >> "\$CALLS"
_n="\$(basename "\$0" .sh)"
# A SECOND ANSWER, WHEN A CASE NEEDS THE WORLD TO CHANGE MID-RUN. The
# push-triggered pass can FINISH while the CI gate is still settling, and the
# whole question is which side of that the baseline was read on — so the stub can
# answer differently the second time it is asked.
if [ -f "\$W/pushed" ] && [ -f "\$W/\${_n}.after.out" ]; then cat "\$W/\${_n}.after.out"
elif [ ! -f "\$W/pushed" ] && [ -f "\$W/\${_n}.before.out" ]; then cat "\$W/\${_n}.before.out"
elif [ -f "\$W/\${_n}.out" ]; then cat "\$W/\${_n}.out"; fi
exit "\$(cat "\$W/\${_n}.rc" 2>/dev/null || echo 0)"
STUB
    chmod +x "$DIR/$h"
done
cat > "$TMP/bin/gh" <<'GHSH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$CALLS"
case " $* " in
    *" pr view "*)    # SEQUENCED, because the head MOVING is the whole subject of
                      # some cases: the pre-push read and the post-push read are
                      # the same call to this stub and must be able to differ.
                      if [ ! -f "$W/pushed" ] && [ -f "$W/head.before.out" ]
                      then cat "$W/head.before.out"
                      else cat "$W/head.out" 2>/dev/null; fi
                      exit "$(cat "$W/head.rc" 2>/dev/null || echo 0)" ;;
    *" pr comment "*) exit "$(cat "$W/comment.rc" 2>/dev/null || echo 0)" ;;
    *" pr edit "*)    exit "$(cat "$W/edit.rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
GHSH
cat > "$TMP/bin/git" <<'GITSH'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$CALLS"
case "$1 $2" in
    "rev-parse HEAD") cat "$W/local.out" 2>/dev/null; exit 0 ;;
esac
# THE PUSH MARKS THE WORLD. Cases about "before or after the push" then key their
# answers on the event itself rather than on a call count — a counter makes the
# first call special whether or not it precedes the push, so a defect that MOVES a
# call past the push still gets the first answer and looks correct.
[ "$1" = push ] && { : > "$W/pushed"; exit "$(cat "$W/push.rc" 2>/dev/null || echo 0)"; }
exit 0
GITSH
chmod +x "$TMP/bin/gh" "$TMP/bin/git"

world() {   # world ; the state in which a round closes cleanly
    W="$TMP/w"; rm -rf "$W"; mkdir -p "$W"; : > "$TMP/calls"
    printf '%s\n' "$HEAD40" > "$W/local.out"
    printf '%s\n' "$HEAD40" > "$W/head.out"
    # THE REAL HELPER PRINTS A BARE ID — `42`, or `comment:42`. A stub returning a
    # structured line let the propagation cases pass on a value `pr-watch.sh`
    # rejects as `malformed_review_id`, which stops the NEXT round: the fixture was
    # agreeing with itself about a shape the real contract refuses.
    printf '42\n' > "$W/pr-review-state.out"
}
run() {   # run [reviewer] [auto] ; prints "<rc>|<output>"
    local out rc=0
    printf 'the round summary\n' > "$TMP/summary.md"
    out="$(cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        "$DIR/pr-close-round.sh" 7 "${1-$CODEXBOT}" "$TMP/summary.md" "${2-no}" 2>&1)" || rc=$?
    printf '%s|%s' "$rc" "$out"
}
case_is() {   # case_is <want rc> <needle> <label> [reviewer] [auto]
    local got rc body
    got="$(run "${4-$CODEXBOT}" "${5-no}")"; rc="${got%%|*}"; body="${got#*|}"
    { [ "$rc" = "$1" ] && printf '%s' "$body" | grep -qF "$2"; } \
        && pass "$3" \
        || die "$3 — rc=$rc (wanted $1) out='$body'"
}
# `before <a> <b>` — a happened earlier in the call log than b. The ordering IS
# the subject here, so it gets a predicate of its own.
before() {
    local la lb
    la="$(grep -n -- "$1" "$TMP/calls" | head -1 | cut -d: -f1)"
    lb="$(grep -n -- "$2" "$TMP/calls" | head -1 | cut -d: -f1)"
    { [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; }
}

# ── a round closes at all ──────────────────────────────────────────────────
# First, because every other case asserts a refusal and a script that can never
# close a round would satisfy all of them.
world; case_is 0 "PR_ROUND_CLOSED" "a clean round closes, in mention mode"
world; case_is 0 "mode=push" "…and in push mode" "$CODEXBOT" yes

# ── THE ORDERING, WHICH IS THE WHOLE POINT ─────────────────────────────────
# In push mode the push is the trigger, so nothing irreversible may happen before
# the checks are known: push, then gate, then summary. Closing first and pushing
# last cannot be gated — by the time the checks can be consulted the summary is
# already posted, and a later "not closed" comment is a record, not a retraction.
world; run "$CODEXBOT" yes >/dev/null
before 'git push' 'pr-ci-gate.sh' \
    && pass "push mode pushes before it consults the checks" \
    || die "the CI gate ran before the push it is about"
before 'pr-ci-gate.sh' 'gh pr comment' \
    && pass "…and knows the head is green before it posts anything" \
    || die "push mode posts the summary before the checks are known"
# In mention mode the comment IS the trigger, so the same rule holds for a
# different reason: nothing is queued until it is posted.
world; run "$CODEXBOT" no >/dev/null
before 'pr-ci-gate.sh' 'gh pr comment' \
    && pass "mention mode also proves the head before requesting" \
    || die "mention mode requests a review on an unproven head"
# THE BOUNDARY IS CHECKED BEFORE THE PUSH, because in push mode the push IS the
# request. Checking it later paused after the round it was meant to precede had
# already been queued.
world; run "$CODEXBOT" yes >/dev/null
before 'pr-round-count.sh' 'git push' \
    && pass "…and the round boundary is checked before the push queues anything" \
    || die "the boundary check runs after the push has already triggered a pass"

# ── the boundary is a PAUSE, not a refusal ─────────────────────────────────
world; printf '3' > "$W/pr-round-count.rc"
case_is 3 "PAUSE" "a round boundary pauses with its own status"
grep -q 'git push' "$TMP/calls" \
    && die "the boundary paused after pushing" \
    || pass "…and nothing was pushed before it"
world; printf '2' > "$W/pr-round-count.rc"
case_is 1 "could not establish the round count" "…while an unreadable count stops the round"

# ── refusing ───────────────────────────────────────────────────────────────
world; printf '1' > "$W/push.rc"
case_is 1 "push failed" "a failed push stops the round"
# THE GATE'S OWN DIAGNOSTIC IS ITS OUTPUT, so the case asserts the STATUS and the
# consequence rather than a message this script never writes. An empty needle
# cannot match: `grep -qF ""` on empty input returns 1, so the first version of
# this failed for a reason that had nothing to do with the subject.
world; printf '1' > "$W/pr-ci-gate.rc"
got="$(run "$CODEXBOT" no)"; rc="${got%%|*}"
[ "$rc" = 1 ] \
    && pass "a red head stops the round before anything is posted" \
    || die "a red head did not stop the round (rc=$rc)"
grep -q 'gh pr comment' "$TMP/calls" \
    && die "the summary was posted on a red head" \
    || pass "…and no summary was posted"
world; printf '1' > "$W/comment.rc"
case_is 1 "could not request the review" "a failed request stops the round"
# IN PUSH MODE, which is the mode that reads the head at all: mention mode uses
# the local `rev-parse` and never asks the API, so this case proved nothing there.
world; printf '1' > "$W/head.rc"
case_is 1 "could not read the head" "an unreadable head stops the round" "$CODEXBOT" yes
world; printf 'not-a-sha\n' > "$W/head.out"
case_is 1 "not a full OID" "…and a malformed one is not a head" "$CODEXBOT" yes

# ── the summary is read BEFORE anything happens ────────────────────────────
# A round that cannot produce its own summary should not push either — and a
# truncated summary is worse than none, because the reviewer contract makes the
# newest summary the thing read before the diff, so it looks complete.
world; : > "$TMP/summary.md"
got="$(cd "$TMP" && run_limited 20 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    "$DIR/pr-close-round.sh" 7 "$CODEXBOT" "$TMP/summary.md" no 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$got" | grep -qF 'summary is empty'; } \
    && pass "an empty summary stops the round" \
    || die "an empty summary gave rc=$rc '$got'"
grep -q 'git push' "$TMP/calls" \
    && die "it pushed before reading its own summary" \
    || pass "…before pushing anything"
world
got="$(cd "$TMP" && run_limited 20 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    "$DIR/pr-close-round.sh" 7 "$CODEXBOT" "$TMP/nope.md" no 2>&1)"; rc=$?
[ "$rc" -eq 1 ] \
    && pass "…and so does a summary file that is not there" \
    || die "a missing summary file gave rc=$rc"

# ── WHICH REVIEWER THE ROUND WAS ABOUT ─────────────────────────────────────
# Copilot is never triggered by a mention and never by a push — only by
# `--add-reviewer`. A Copilot round that posted the Codex mention requested
# nothing at all, and the watch then waited past the old review indefinitely.
world; run "$COPILOTBOT" no >/dev/null
grep -q -- '--add-reviewer @copilot' "$TMP/calls" \
    && pass "a Copilot round is re-requested with --add-reviewer" \
    || die "a Copilot round requested nothing"
grep -q '@codex review' "$TMP/calls" \
    && die "a Copilot round posted the Codex mention" \
    || pass "…and not with the Codex mention"
world; run "$CODEXBOT" no >/dev/null
grep -q '@codex review' "$TMP/calls" \
    && pass "a Codex round carries the mention that triggers it" \
    || die "a Codex round did not mention Codex"
# EXACTLY ONE COMMENT, in each mode and for each reviewer. The automatic path once
# posted the summary standalone AND again inside the mention, leaving two
# identical round-summary comments — and the contract makes the NEWEST summary the
# one read before the diff, so a duplicate is a record with two answers to the
# same question.
[ "$(grep -c 'gh pr comment' "$TMP/calls")" -eq 1 ] \
    && pass "…exactly once, not standalone and again inside the mention" \
    || die "a Codex round posted $(grep -c 'gh pr comment' "$TMP/calls") summary comments"
world; run "$COPILOTBOT" no >/dev/null
[ "$(grep -c 'gh pr comment' "$TMP/calls")" -eq 1 ] \
    && pass "…and a Copilot round posts exactly one too" \
    || die "a Copilot round posted $(grep -c 'gh pr comment' "$TMP/calls") summary comments"
# THE BASELINE IS READ BEFORE THE REQUEST IT IS FOR, not after. Read afterwards it
# includes the very review the request is meant to supersede, so the watch accepts
# the old pass as the answer to the new one.
before 'pr-review-state.sh review-id' 'gh pr edit' \
    && pass "…and its baseline is read before the request is made" \
    || die "the request went out before the baseline that will be watched against"
world; run "$CODEXBOT" yes >/dev/null
grep -q 'PR_ROUND_CLOSED.*prior-review=' "$TMP/calls" 2>/dev/null || true
out="$(run "$CODEXBOT" yes)"; body="${out#*|}"
printf '%s' "$body" | grep -qE 'prior-review=(comment:)?[0-9]+$' \
    && pass "…and the closing record carries it back to the driver" \
    || die "the round closed without reporting the baseline ('$body')"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "a Codex round used --add-reviewer" \
    || pass "…and does not use --add-reviewer"

# ── the pass the push started ──────────────────────────────────────────────
# In push mode a moved head means a pass is already running, and its result would
# otherwise answer the request made after it.
world; run "$CODEXBOT" yes >/dev/null
grep -q 'pr-watch.sh' "$TMP/calls" \
    && die "it waited for a pass on an unmoved head" \
    || pass "an unmoved head starts no pass, so none is waited for"
world; printf '%s\n' "$PREV40" > "$W/head.out"
# The head the API reports differs from the local one, then catches up: this is
# the retry path, and the case exists because the API can serve the previous head
# for a moment after a push.
case_is 1 "not the" "a head that never catches up stops the round" "$CODEXBOT" yes

# ── THE BASELINE IS READ BEFORE THE PUSH ───────────────────────────────────
#
# This is the one ordering in the script that runs the other way round from
# everything else: later is normally safer, and here later is WRONG. The push
# starts a pass; a fast one finishes while the CI gate is still settling; a
# baseline taken after that captures the COMPLETED pass as the thing to wait past,
# so the watch waits for a newer pass nobody requested and the round never closes
# despite being clean.
#
# The stub answers `id=1` first and `id=2` afterwards — the completed pass — and
# the assertion is that the watch was handed the FIRST one.
# THE HEAD MOVED: the pre-push read reports the previous commit, every read after
# reports the pushed one. That is what makes a pass have been started at all.
world
printf '%s\n' "$PREV40" > "$W/head.before.out"
printf '1\n' > "$W/pr-review-state.before.out"
printf '2\n' > "$W/pr-review-state.out"
run "$CODEXBOT" yes >/dev/null
grep -q 'pr-watch.sh 7 .* --after-review 1$' "$TMP/calls" \
    && pass "the watch is given the baseline from BEFORE the push" \
    || die "the baseline was taken after the push: $(grep pr-watch "$TMP/calls" | head -1)"
before 'pr-review-state.sh review-id' 'git push' \
    && pass "…which is to say the review id is read before the push" \
    || die "the review id is read after the push has already started a pass"
# …AND NOT AT ALL ON A COPILOT ROUND. A push never triggers Copilot, so reading it
# there puts a `gh` call that can fail transiently in front of the
# `--add-reviewer` that is the only thing such a round needs — a stall with no
# upside.
world; run "$COPILOTBOT" yes >/dev/null
grep -q 'pr-review-state.sh review-id' "$TMP/calls" \
    && pass "a Copilot round still reads its own request baseline" \
    || die "a Copilot round requests a review with no baseline"
[ "$(grep -c 'pr-review-state.sh review-id' "$TMP/calls")" -eq 1 ] \
    && pass "…but only the one it uses, not a pre-push baseline it never will" \
    || die "a Copilot round reads a pre-push baseline it cannot use"

# ── THE FIXES OF THE LAST ROUND, PROVEN ────────────────────────────────────
# Each of these covers a behaviour that was corrected without a case to hold it.

# AN UNRECOGNISED REVIEWER IS REFUSED. Every branch asks "is this Copilot?", so a
# typo took the Codex path: the mention was posted, Copilot was never requested,
# and the round waited on a pass nobody asked for.
world
got="$(cd "$TMP" && run_limited 20 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    "$DIR/pr-close-round.sh" 7 'some-other-bot[bot]' "$TMP/summary.md" no 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$got" | grep -qF 'not a reviewer this loop drives'; } \
    && pass "an unrecognised reviewer is refused, by name" \
    || die "an unknown reviewer gave rc=$rc '$got'"
grep -q 'git push' "$TMP/calls" \
    && die "it pushed for a reviewer it does not know" \
    || pass "…before anything was pushed"

# THE PRE-PUSH LOOKUPS ARE SKIPPED WHERE THEY ARE UNUSED. A push never starts a
# Copilot pass, so neither the baseline nor the pre-push head is consumed on a
# Copilot round — and a transient failure of either aborted before the
# `--add-reviewer` that is the only thing such a round needs.
world; printf '1' > "$W/head.rc"
got="$(run "$COPILOTBOT" yes)"; rc="${got%%|*}"
[ "$rc" = 1 ] \
    && pass "a Copilot round still fails on the head confirmation it does need" \
    || die "a Copilot round ignored an unreadable head (rc=$rc)"
world; run "$COPILOTBOT" yes >/dev/null
[ "$(grep -c 'gh pr view' "$TMP/calls")" -eq 1 ] \
    && pass "…and reads the head once, not twice, since the pre-push one is unused" \
    || die "a Copilot round made $(grep -c 'gh pr view' "$TMP/calls") head lookups"

# THE PASS THE PUSH STARTED CAN TIME OUT, and that stops the round: its result
# would otherwise answer the request made after it.
world
printf '%s\n' "$PREV40" > "$W/head.before.out"
printf '1' > "$W/pr-watch.rc"
case_is 1 "has not finished" "a push-started pass that never finishes stops the round" "$CODEXBOT" yes
world
printf '%s\n' "$PREV40" > "$W/head.before.out"
printf '2' > "$W/pr-watch.rc"
case_is 1 "could not observe" "…and an unobservable one stops it too" "$CODEXBOT" yes

# A FAILED COPILOT RE-REQUEST STOPS THE ROUND. `--add-reviewer` is the only thing
# that triggers Copilot, so a round that posted its summary and failed here has
# announced a pass that will never come.
world; printf '1' > "$W/edit.rc"
case_is 1 "could not re-request Copilot" "a failed Copilot re-request stops the round" "$COPILOTBOT" no

# ── the arguments ──────────────────────────────────────────────────────────
world
for spec in "seven|$CODEXBOT|no|a PR number is required" \
            "7||no|a reviewer login is required" \
            "7|$CODEXBOT|maybe|auto-review must be"; do
    _pr="${spec%%|*}"; _r="${spec#*|}"; _who="${_r%%|*}"; _r="${_r#*|}"
    _auto="${_r%%|*}"; _want="${_r#*|}"
    got="$(cd "$TMP" && run_limited 20 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        "$DIR/pr-close-round.sh" "$_pr" "$_who" "$TMP/summary.md" "$_auto" 2>&1)"; rc=$?
    { [ "$rc" -eq 1 ] && printf '%s' "$got" | grep -qF "$_want"; } \
        && pass "refused by name: $_want" \
        || die "'$_pr/$_who/$_auto' gave rc=$rc '$got'"
done

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
