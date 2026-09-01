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
# THE REAL RULE, BOTH HALVES OF IT (`pr-watch.sh` lines 411-421): a bare id or a
# `comment:`-prefixed one, and EMPTY is legitimate — a head with no review yet has
# no id, and the watch takes that as "wait on any terminal review". A stub that
# refused empty was stricter than the contract, which is the same defect as one
# that is looser: it makes a fixture pass or fail on a shape the real script does
# not treat that way.
case "$_after" in
    ""|*[0-9]) ;;
    comment:*[0-9]) ;;
    *) printf 'PR_REVIEW_WATCH state=error reason=malformed_review_id detail=%s\n' "$_after"
       exit 2 ;;
esac
case "${_after#comment:}" in
    ""|*[!0-9]*) [ -z "$_after" ] || {
           printf 'PR_REVIEW_WATCH state=error reason=malformed_review_id detail=%s\n' "$_after"
           exit 2; } ;;
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
    *" pr view "*)    # WHICH BRANCH THE PR IS FOR is a different question from
                      # which head it has, and the gate asks it before every push:
                      # a bare `git push` sends whatever branch the checkout is on,
                      # and this stage was never told which one that should be.
                      # #119.
                      case " $* " in
                          # ONE CALL, TWO FACTS, joined by a tab — which a git ref
                          # name cannot contain, so it cannot shift the field.
                          *headRefName*) cat "$W/branch.out" 2>/dev/null
                                         exit "$(cat "$W/branch.rc" 2>/dev/null || echo 0)" ;;
                      esac
                      # SEQUENCED, because the head MOVING is the whole subject of
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
    # WHICH BRANCH THIS CHECKOUT IS ON. Empty with a non-zero status is a DETACHED
    # HEAD, which the gate must refuse: a push from one reaches no PR, and the
    # next step would wait for a head that never appears. #119.
    "symbolic-ref --quiet")
        # THE FULL REF, because `--short` shortens only as far as stays
        # unambiguous: a branch sharing its name with a tag comes back as
        # `heads/release/2.0` while GitHub reports `release/2.0`.
        [ -s "$W/branch.local" ] || exit 1
        cat "$W/branch.local"; exit 0 ;;
    "remote get-url")
        # `--all` PRINTS ONE URL PER LINE, and `git push <name>` sends to every
        # one — so a fixture with a single URL says nothing about the second.
        cat "$W/pushurl.out" 2>/dev/null
        exit "$(cat "$W/pushurl.rc" 2>/dev/null || echo 0)" ;;
esac
# THE PUSH MARKS THE WORLD. Cases about "before or after the push" then key their
# answers on the event itself rather than on a call count — a counter makes the
# first call special whether or not it precedes the push, so a defect that MOVES a
# call past the push still gets the first answer and looks correct.
# THE PUSH'S ARGUMENTS ARE RECORDED, because a bare `git push` leaves both the
# repository and the refspec to configuration — `push.default` and
# `remote.<n>.push` can send it elsewhere however the branch is named. What
# protects the destination is naming it. #119.
[ "$1" = push ] && { printf '%s\n' "$*" > "$W/pushed"; exit "$(cat "$W/push.rc" 2>/dev/null || echo 0)"; }
exit 0
GITSH
chmod +x "$TMP/bin/gh" "$TMP/bin/git"

# THE TERMINATING NEWLINE IS ASSERTED ON RAW BYTES, because nothing else here can see it.
# `$(…)` and `cat` in a substitution both strip trailing newlines, so an assertion phrased
# on the captured value passes whether or not the writer emitted the delimiter — while
# `pr-watch.sh` refuses a baseline without it as `unterminated_after_review_file`. A writer
# changed to emit a bare token would leave this suite green and break the real handoff.
raw_is() {   # raw_is <file> <expected-content-including-newlines> <label>
    printf '%s' "$2" > "$TMP/raw.expected" || die "could not stage the raw expectation for $3"
    cmp -s "$1" "$TMP/raw.expected" \
        && pass "…and $3 lands as raw bytes with its terminating newline" \
        || die "$3 is not byte-for-byte '$2': $(od -c "$1" 2>/dev/null | head -2)"
}
world() {   # world ; the state in which a round closes cleanly
    W="$TMP/w"; rm -rf "$W"; mkdir -p "$W"; : > "$TMP/calls"
    printf '%s\n' "$HEAD40" > "$W/local.out"
    printf '%s\n' "$HEAD40" > "$W/head.out"
    # THE CHECKOUT IS ON THE PR'S BRANCH, which is the ordinary state and the one
    # every other case here assumes. The gate proves it before pushing, because a
    # bare `git push` sends whatever branch the checkout is on. #119.
    printf 'fix/the-branch\tfalse\n' > "$W/branch.out"
    printf 'refs/heads/fix/the-branch\n' > "$W/branch.local"
    # ORIGIN PUSHES WHERE THE SESSION IS PINNED. `origin` is a NAME the checkout
    # resolves, and `remote.origin.pushurl` can send it elsewhere entirely — so
    # the gate parses the effective push URL through `rb_identity` and compares it
    # with the pinned identity. #119.
    printf 'git@github.com:acme/widget.git\n' > "$W/pushurl.out"
    # THE REAL HELPER PRINTS A BARE ID — `42`, or `comment:42`. A stub returning a
    # structured line let the propagation cases pass on a value `pr-watch.sh`
    # rejects as `malformed_review_id`, which stops the NEXT round: the fixture was
    # agreeing with itself about a shape the real contract refuses.
    printf '42\n' > "$W/pr-review-state.out"
}
# THE FIXTURE PINS ITS OWN IDENTITY, WHICH MEANS CLEARING THE OVERRIDES TOO.
# `rb_identity` honours `REVIEW_BUS_OWNER` and `REVIEW_BUS_REPO` over anything it
# derives, and the gate's push-URL proof clears both before parsing — so a
# contributor with either exported saw the pinned identity and the parsed one
# disagree, and every gate refused. The suite is self-contained or it is not.
# `pr-selfcheck.sh` cannot clear these: `SKILL.md` exports `REVIEW_BUS_REMOTE` to
# pin the session and the suite runs with that pin in the environment, so a
# fixture whose subject is an env-driven override clears it itself.
stage() {   # stage <stage> [args…] ; prints "<rc>|<output>" for ONE stage
    local out rc=0 st="$1"; shift
    # THE PRIOR FILE IS SUPPLIED WHEN THE CALLER GAVE A FULL ARGUMENT LIST, which is
    # what the driver does with one of the four working files setup creates. A case
    # deliberately passing FEWER — the missing-head-file one — is left short, so the
    # refusal it is about still fires; a case about the prior file itself passes its
    # own sixth argument and this does nothing.
    if [ "$#" -eq 5 ]; then set -- "$@" "$TMP/prior.txt"; fi
    out="$(cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    REVIEW_BUS_OWNER= REVIEW_BUS_REPO= \
        REVIEW_BUS_OWNER= REVIEW_BUS_REPO= \
        "$DIR/pr-close-round.sh" "$st" "$@" 2>&1)" || rc=$?
    printf '%s|%s' "$rc" "$out"
}
# THE HEAD FILE IS THE HANDOFF, since #202. `gate` writes the head it proved into
# the path it is given and `post` reads it back, so the fixture hands both stages
# the same path rather than lifting the head out of the record — which is exactly
# what the driver no longer does.
HEADF="$TMP/head.txt"
headf() {   # headf [value] ; puts it in the head file and prints the path
    printf '%s\n' "${1-}" > "$HEADF"
    printf '%s' "$HEADF"
}
# A WHOLE ROUND, THE WAY THE DRIVER RUNS IT: gate, then the thread replies, then
# post. The replies are the reason this is two stages at all, so the fixture
# performs them — as a line in the SAME call log — rather than skipping from one
# stage straight to the other. Ordering assertions can then span the boundary,
# which is where the ordering that matters actually lives.
run() {   # run [reviewer] [auto] ; prints "<rc>|<output>" for the whole round
    local who="${1-$CODEXBOT}" auto="${2-no}" g grc gout rc out
    printf 'the round summary\n' > "$TMP/summary.md"
    : > "$HEADF"
    g="$(stage gate 7 "$who" "$TMP/summary.md" "$auto" "$HEADF")"; grc="${g%%|*}"; gout="${g#*|}"
    # A GATE THAT DID NOT PASS IS THE WHOLE ANSWER. Running `post` anyway would be
    # the fixture doing what the driver is forbidden to do.
    [ "$grc" = 0 ] || { printf '%s|%s' "$grc" "$gout"; return 0; }
    printf 'driver resolveReviewThread\n' >> "$TMP/calls"
    out="$(stage post 7 "$who" "$TMP/summary.md" "$auto" "$HEADF")"; rc="${out%%|*}"; out="${out#*|}"
    printf '%s|%s
%s' "$rc" "$gout" "$out"
}
case_is() {   # case_is <want rc> <needle> <label> [reviewer] [auto]
    local got rc body
    got="$(run "${4-$CODEXBOT}" "${5-no}")"; rc="${got%%|*}"; body="${got#*|}"
    { [ "$rc" = "$1" ] && grep -qF "$2" <<<"$body"; } \
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
    REVIEW_BUS_OWNER= REVIEW_BUS_REPO= \
    "$DIR/pr-close-round.sh" gate 7 "$CODEXBOT" "$TMP/summary.md" no "$TMP/head.txt" "$TMP/prior.txt" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF 'summary is empty' <<<"$got"; } \
    && pass "an empty summary stops the round" \
    || die "an empty summary gave rc=$rc '$got'"
grep -q 'git push' "$TMP/calls" \
    && die "it pushed before reading its own summary" \
    || pass "…before pushing anything"
world
got="$(cd "$TMP" && run_limited 20 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    REVIEW_BUS_OWNER= REVIEW_BUS_REPO= \
    "$DIR/pr-close-round.sh" gate 7 "$CODEXBOT" "$TMP/nope.md" no "$TMP/head.txt" "$TMP/prior.txt" 2>&1)"; rc=$?
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
grep -qE 'prior-review=(comment:)?[0-9]+$' <<<"$body" \
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
    REVIEW_BUS_OWNER= REVIEW_BUS_REPO= \
    "$DIR/pr-close-round.sh" gate 7 'some-other-bot[bot]' "$TMP/summary.md" no "$TMP/head.txt" "$TMP/prior.txt" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF 'not a reviewer this loop drives' <<<"$got"; } \
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
# COUNTED WITHIN THE GATE, which is where the pre-push lookup would be. Counting
# across the whole round would count `post`'s re-proof of the head as well — a
# different lookup, made for a different reason — so the number would move
# whenever anything else did, and stop being about the pre-push read at all.
world; printf 'the round summary\n' > "$TMP/summary.md"
stage gate 7 "$COPILOTBOT" "$TMP/summary.md" yes "$(headf)" >/dev/null
# THE HEAD LOOKUPS, NOT EVERY `pr view`. The gate also asks which BRANCH the PR
# is for before it pushes — a different question, made for a different reason —
# so counting every `pr view` would move whenever that one did and stop being
# about the pre-push head read at all.
_hv="$(grep -c 'gh pr view.*headRefOid' "$TMP/calls" || true)"
[ "$_hv" -eq 1 ] \
    && pass "…and the gate reads the head once, not twice, since the pre-push one is unused" \
    || die "a Copilot gate made $_hv head lookups"

# ── THE GATE PUSHES THE PR'S BRANCH, OR NOTHING ───────────────────────────
#
# A bare `git push` sends whatever branch the checkout is on, and this stage is
# given a PR number and a reviewer — it was never told which branch that PR is
# for, and never asked. Driving #118's round from a checkout sitting on `main`,
# because a `git checkout` had failed and the shell stayed put, it pushed the
# DEFAULT BRANCH: an unreviewed commit reached `main`, and the round was lost
# besides, since the CI gate then waited for checks on a head the PR did not have.
# #119.
#
# NOTHING PUSHED IS THE ASSERTION, in every refusal. A message alone would be
# satisfied by a gate that complains and pushes anyway.
nothing_pushed() {   # nothing_pushed <label>
    [ -f "$W/pushed" ]         && die "$1 — but it pushed anyway"         || pass "$1"
}
# THE DESTINATION IS NAMED, NOT LEFT TO CONFIGURATION. A bare `git push` leaves
# both inputs to config: `push.default` and `branch.<n>.remote` choose the
# repository, and `remote.<n>.push` can supply refspecs that update other refs —
# an ahead `main` among them — however the current branch is named. So the branch
# comparison alone is a guard over a call that can still go elsewhere; what
# protects the destination is naming it.
for _m in no yes; do
    world; printf 'the round summary\n' > "$TMP/summary.md"
    stage gate 7 "$CODEXBOT" "$TMP/summary.md" "$_m" "$(headf)" >/dev/null 2>&1
    _pushargs="$(cat "$W/pushed" 2>/dev/null)"
    [ "$_pushargs" = 'push origin HEAD:refs/heads/fix/the-branch' ] \
        && pass "the gate names the repository and the one ref it may write ($_m mode)" \
        || die "the $_m-mode gate left its destination to configuration: 'git $_pushargs'"
done
# A FORK'S BRANCH IS NOT OURS TO WRITE. `origin` pointed at a same-named branch of
# THIS repository would put the round's fixes somewhere else entirely, and report
# success.
world; printf 'fix/the-branch\ttrue\n' > "$W/branch.out"
got="$(run "$CODEXBOT" no)"
{ [ "${got%%|*}" = 1 ] && grep -qF 'does not push to forks' <<<"${got#*|}"; } \
    && pass "…and a PR from a fork refuses rather than pushing at a same-named branch here" \
    || die "a fork PR was pushed for: '${got}'"
nothing_pushed "…with nothing pushed"
# THE FORK ANSWER IS READ, NOT ASSUMED. A missing or unexpected value is "could
# not tell", which is a refusal — the direction that matters, since the other one
# pushes at a repository nobody named.
world; printf 'fix/the-branch\n' > "$W/branch.out"
got="$(run "$CODEXBOT" no)"
{ [ "${got%%|*}" = 1 ] && grep -qF 'could not tell whether' <<<"${got#*|}"; } \
    && pass "…and an answer that says neither refuses rather than assuming same-repository" \
    || die "a missing cross-repository answer was pushed past: '${got}'"
nothing_pushed "…with nothing pushed"
# ── `origin` IS A NAME THE CHECKOUT RESOLVES ──────────────────────────────
# `remote.origin.pushurl` can send it to another repository entirely, and a
# second checkout can define `origin` as a different project — so the branch and
# fork checks pass while the commit lands somewhere nobody asked about and the PR
# stays unchanged. The effective push URL is parsed by `rb_identity`, the one
# parser, and compared with the pinned identity. #119.
world; printf 'git@github.com:someone/other.git\n' > "$W/pushurl.out"
got="$(run "$CODEXBOT" no)"
{ [ "${got%%|*}" = 1 ] && grep -qF 'refusing to push elsewhere' <<<"${got#*|}"; } \
    && pass "…and an origin whose push URL is another repository refuses" \
    || die "a redirected origin was pushed to: '${got}'"
nothing_pushed "…with nothing pushed"
# CASING IS NOT A FORK. `git@github.com:Acme/widget.git` addresses the same
# repository the API calls `acme/widget`, and a case-sensitive comparison of the
# two called every such PR a fork and refused every push — which is why the fork
# question is asked of the API instead of derived from names.
world; printf 'git@github.com:Acme/Widget.git\n' > "$W/pushurl.out"
got="$(run "$CODEXBOT" no)"
[ "${got%%|*}" = 0 ] \
    && pass "…while a differently-cased pinned origin still closes the round" \
    || die "casing was treated as a different repository: '${got}'"
# A SECOND `pushurl` GETS THE COMMIT TOO. `git push origin` sends to every
# configured push URL, so validating the first and pushing to the name put the
# round's fixes in whatever the second names.
world; printf 'git@github.com:acme/widget.git\ngit@github.com:someone/other.git\n' > "$W/pushurl.out"
got="$(run "$CODEXBOT" no)"
{ [ "${got%%|*}" = 1 ] && grep -qF 'someone/other' <<<"${got#*|}"; } \
    && pass "…and a second push URL naming another repository refuses, though the first is right" \
    || die "a second push URL was pushed to: '${got}'"
nothing_pushed "…with nothing pushed"
# A MIRROR OF THE SAME REPOSITORY STILL WORKS, or the check above is satisfied by
# refusing every multi-URL remote rather than by reading them.
world; printf 'git@github.com:acme/widget.git\nhttps://github.com/acme/widget.git\n' > "$W/pushurl.out"
got="$(run "$CODEXBOT" no)"
[ "${got%%|*}" = 0 ] \
    && pass "…while two URLs for the same repository still close the round" \
    || die "a mirror of the pinned repository was refused: '${got}'"
world; printf '1' > "$W/pushurl.rc"
got="$(run "$CODEXBOT" no)"
{ [ "${got%%|*}" = 1 ] && grep -qF "origin's push URL" <<<"${got#*|}"; } \
    && pass "…and an unreadable push URL refuses rather than pushing blind" \
    || die "an unreadable push URL was pushed past: '${got}'"
nothing_pushed "…with nothing pushed"
for _m in no yes; do
    world; printf 'refs/heads/some-other-branch
' > "$W/branch.local"
    got="$(run "$CODEXBOT" "$_m")"
    { [ "${got%%|*}" = 1 ] && grep -qF 'refusing to push the wrong branch' <<<"${got#*|}"; }         && pass "a checkout on another branch refuses ($_m mode)"         || die "the wrong branch was pushed in $_m mode: '${got}'"
    nothing_pushed "…with nothing pushed"
done
# A DETACHED HEAD HAS NO BRANCH, and a push from one reaches no PR — so the next
# step would wait for a head that never appears. The stub reports that as an empty
# answer with a non-zero status, which is what `git symbolic-ref` does.
world; : > "$W/branch.local"
got="$(run "$CODEXBOT" no)"
{ [ "${got%%|*}" = 1 ] && grep -qF 'detached HEAD' <<<"${got#*|}"; }     && pass "…and a detached HEAD refuses rather than pushing nothing useful"     || die "a detached HEAD was pushed from: '${got}'"
nothing_pushed "…with nothing pushed"
# A BRANCH THAT SHARES ITS NAME WITH A TAG STILL CLOSES THE ROUND. `--short`
# shortens only as far as stays UNAMBIGUOUS, so on such a branch it returns
# `heads/release/2.0` while GitHub reports `release/2.0` — and the comparison then
# refused a checkout that was already on the PR's branch, leaving no way to close
# the round at all. Reproduced on git 2.55; the fix reads the full ref and strips
# `refs/heads/`.
world; printf 'refs/heads/release/2.0\n' > "$W/branch.local"
printf 'release/2.0\tfalse\n' > "$W/branch.out"
got="$(run "$CODEXBOT" no)"
[ "${got%%|*}" = 0 ] \
    && pass "…and a branch sharing its name with a tag still closes the round" \
    || die "an ambiguous branch name was refused: '${got}'"
_pushargs="$(cat "$W/pushed" 2>/dev/null)"
[ "$_pushargs" = 'push origin HEAD:refs/heads/release/2.0' ] \
    && pass "…pushing to the branch GitHub named, not the disambiguated form" \
    || die "the ambiguous name reached the refspec: 'git $_pushargs'"
# AND A SYMBOLIC HEAD THAT IS NOT A BRANCH REFUSES. `refs/heads/` is stripped as a
# PREFIX, so anything else — a ref outside that namespace — is not silently
# rewritten into a branch name and pushed at.
world; printf 'refs/remotes/origin/fix/the-branch\n' > "$W/branch.local"
got="$(run "$CODEXBOT" no)"
{ [ "${got%%|*}" = 1 ] && grep -qF 'which is not a branch' <<<"${got#*|}"; } \
    && pass "…while a symbolic HEAD outside refs/heads refuses" \
    || die "a non-branch symbolic HEAD was pushed from: '${got}'"
nothing_pushed "…with nothing pushed"

# AN UNREADABLE ANSWER IS A REFUSAL TOO. "Could not ask which branch" is not
# "any branch will do", and this is the one that decides where a commit lands.
world; printf '1' > "$W/branch.rc"
got="$(run "$CODEXBOT" no)"
{ [ "${got%%|*}" = 1 ] && grep -qF 'refusing to push blind' <<<"${got#*|}"; }     && pass "…and an unreadable head branch refuses rather than pushing blind"     || die "an unreadable head branch was pushed past: '${got}'"
nothing_pushed "…with nothing pushed"
# AND AN EMPTY ONE, which a 200 with a missing field produces — the same shape as
# a successful read, and the reason a status check alone is not enough.
world; : > "$W/branch.out"
got="$(run "$CODEXBOT" no)"
{ [ "${got%%|*}" = 1 ] && grep -qF 'no head branch' <<<"${got#*|}"; }     && pass "…and an empty one, which a 200 with a missing field looks like"     || die "an empty head branch was pushed past: '${got}'"
nothing_pushed "…with nothing pushed"

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

# AND A PASS THAT LEFT ONLY REPLIES PAUSES IT. Nothing for `pr-findings.sh` to
# list and no signoff, so closing here would resolve the previous round's threads,
# post a summary and request another pass — straight past the one thing that has
# to happen, which is a human reading that comment. Paused rather than aborted:
# nothing is wrong, a decision is owed.
world
printf '%s\n' "$PREV40" > "$W/head.before.out"
printf '4' > "$W/pr-watch.rc"
case_is 3 "left only replies" "a push-started pass that left only replies pauses the round" "$CODEXBOT" yes
grep -q 'gh pr comment' "$TMP/calls" \
    && die "it posted a summary past the operator stop" \
    || pass "…with nothing posted"
grep -q -- '--add-reviewer\|@codex review' "$TMP/calls" \
    && die "it requested another pass past the operator stop" \
    || pass "…and nothing requested"

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
    REVIEW_BUS_OWNER= REVIEW_BUS_REPO= \
        REVIEW_BUS_OWNER= REVIEW_BUS_REPO= \
        "$DIR/pr-close-round.sh" gate "$_pr" "$_who" "$TMP/summary.md" "$_auto" "$TMP/head.txt" "$TMP/prior.txt" 2>&1)"; rc=$?
    { [ "$rc" -eq 1 ] && grep -qF "$_want" <<<"$got"; } \
        && pass "refused by name: $_want" \
        || die "'$_pr/$_who/$_auto' gave rc=$rc '$got'"
done


# ── PROSE MUST NOT BECOME A RECORD ────────────────────────────────────────
# The summary quotes findings, PR descriptions and reviewer comments, and it is
# posted under an identity `pr-signoff.sh` and `pr-round-count.sh` trust. A line
# reproducing one of their markers CREATES the record it describes — a summary
# quoting a finding about an acknowledgement becomes that acknowledgement, and the
# boundary it answers never fires again. The rule is `recordlib.sh`'s because
# `pr-copilot-phase.sh` posts a caller-written body too.
world; printf 'we fixed it, and the record now reads:\n**Review-Pause-Acknowledged:** `codex` `10`\n' > "$TMP/summary.md"
got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf)")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'reads as a record' <<<"${got#*|}"; } \
    && pass "a summary line that is a control marker is refused" \
    || die "a summary carrying an acknowledgement marker gave '${got}'"
grep -q 'git push' "$TMP/calls" \
    && die "it pushed with a summary that would publish a record" \
    || pass "…before anything was pushed"
world; printf 'we fixed it:\n\n    **Review-Signoff:** `x` `y`\n' > "$TMP/summary.md"
got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf)")"
[ "${got%%|*}" = 0 ] \
    && pass "…while an indented one is prose and passes, as the readers see it" \
    || die "an indented marker was refused: '${got}'"
printf 'the round summary\n' > "$TMP/summary.md"

# ── A COPILOT ROUND MUST NOT REQUEST CODEX ────────────────────────────────
# A comment CONTAINING `@codex review` is the trigger, and a Copilot round posts
# its summary on its own — so a summary quoting the mention out of a finding or a
# PR description requests Codex in the middle of the Copilot phase, which is the
# phase ordering this loop exists to keep.
world; printf 'the finding said to post `@codex review` afterwards\n' > "$TMP/summary.md"
got="$(stage gate 7 "$COPILOTBOT" "$TMP/summary.md" no "$(headf)")"
{ [ "${got%%|*}" = 1 ] && grep -qF "contains '@codex review'" <<<"${got#*|}"; } \
    && pass "a Copilot round's summary quoting the Codex trigger is refused" \
    || die "a Copilot summary quoting the trigger gave '${got}'"
grep -q 'git push' "$TMP/calls" \
    && die "it pushed with a summary that would request Codex" \
    || pass "…before anything was pushed"

# IN A CODEX ROUND THE MENTION IS THE REQUEST, and this script writes it itself,
# so a body that also carries one changes nothing and must not be refused —
# quoting a finding is most of what a round summary does.
world; printf 'the finding said to post `@codex review` afterwards\n' > "$TMP/summary.md"
got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf)")"
[ "${got%%|*}" = 0 ] \
    && pass "…while a Codex round, whose request IS the mention, is left alone" \
    || die "a Codex summary quoting the trigger was refused: '${got}'"
printf 'the round summary\n' > "$TMP/summary.md"

# ── THE THREADS ARE ANSWERED BETWEEN THE STAGES ────────────────────────────
# This is the ordering the split exists for, and it is the one the call log can
# only show if the fixture performs the driver's part too. A resolve cannot be
# taken back: it must not happen until the head is pushed and green, and the
# summary must not be posted until the resolve has.
world; run >/dev/null
before 'git push' 'driver resolveReviewThread' \
    && pass "the threads are answered AFTER the push" \
    || die "a thread was resolved before the push: $(cat "$TMP/calls")"
before 'pr-ci-gate' 'driver resolveReviewThread' \
    && pass "…and after the checks on what was pushed" \
    || die "a thread was resolved before the CI gate: $(cat "$TMP/calls")"
before 'driver resolveReviewThread' 'gh pr comment' \
    && pass "…and before the summary that says what they were" \
    || die "the summary preceded the replies: $(cat "$TMP/calls")"

# THE SAME ORDERING IN THE MODE WHERE THE PUSH IS THE TRIGGER — and here the pass
# the push STARTED must also have finished before anything is resolved, because
# that pass reads the threads. This is the documented cost of the mode: it reads
# them OPEN.
world; printf '%s\n' "$PREV40" > "$W/head.before.out"; run "$CODEXBOT" yes >/dev/null
before 'pr-watch.sh' 'driver resolveReviewThread' \
    && pass "with auto-review on, the push's own pass finishes before any resolve" \
    || die "a thread was resolved while the push's pass was still reading them: $(cat "$TMP/calls")"
before 'driver resolveReviewThread' 'gh pr comment' \
    && pass "…and the summary still comes last" \
    || die "the summary preceded the replies in push mode: $(cat "$TMP/calls")"

# ── EACH STAGE DOES ONLY ITS OWN HALF ──────────────────────────────────────
# `gate` posting anything is the defect the split removes: it would close the
# round before the threads it is meant to precede were touched.
world; got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf)")"; rc="${got%%|*}"
[ "$rc" = 0 ] && pass "the gate alone succeeds" || die "the gate alone gave rc=$rc '${got#*|}'"
grep -q 'gh pr comment' "$TMP/calls" \
    && die "the gate posted a comment" \
    || pass "…and posts nothing"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "the gate requested a review" \
    || pass "…and requests nothing"
# `-F`: the reviewer login ends in `[bot]`, which as a pattern is a character
# class — an unanchored regex here matched a line the record does not contain.
grep -qF "PR_ROUND_GATED pr=7 reviewer=$CODEXBOT head=$HEAD40 mode=mention" <<<"${got#*|}" \
    && pass "…and reports the head it proved, with the mode it ran in" \
    || die "the gate's record was '${got#*|}'"

# `post` pushing would push whatever the working tree became while the threads
# were being answered — past the gate that proved the head it is closing on.
world; got="$(stage post 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf "$HEAD40")")"; rc="${got%%|*}"
[ "$rc" = 0 ] && pass "post alone closes the round" || die "post alone gave rc=$rc '${got#*|}'"
grep -q 'git push' "$TMP/calls" \
    && die "post pushed" \
    || pass "…and pushes nothing"
grep -q 'pr-round-count' "$TMP/calls" \
    && die "post checked the round boundary, after the push and the replies" \
    || pass "…and does not re-check the boundary it is already past"
grep -q 'PR_ROUND_CLOSED .*prior-review=42' <<<"${got#*|}" \
    && pass "…and carries the baseline back" \
    || die "post's record was '${got#*|}'"

# ── AND THE BASELINE IS HANDED OVER IN A FILE, NOT ONLY IN THE RECORD ──────
# #234. The record is what an operator reads; the FILE is what the driver acts on.
# It travelled in the record alone, which meant the driving shell captured this
# script's stdout, `sed`-ed a line out of it, checked the line was there, checked it
# carried the field, and cut the value out — twelve executable lines in the one
# shell nothing can harden, for a value `gate` already knows how to hand over.
[ "$(cat "$TMP/prior.txt" 2>/dev/null)" = 42 ] \
    && pass "…and writes it into the prior file the caller named" \
    || die "the prior file holds '$(cat "$TMP/prior.txt" 2>/dev/null)', not the baseline"

# ── THE GATE EMPTIES THE PRIOR FILE, so a failed `post` cannot leave the LAST ──
# round's baseline readable. The driver's watch would take it and accept a review
# that predates this round as the answer to a request this round never made.
world; printf '%s\n' 'STALE' > "$TMP/prior.txt"
stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf)" >/dev/null
[ ! -s "$TMP/prior.txt" ] \
    && pass "the gate empties the prior file, so no stale baseline survives a failed post" \
    || die "the gate left '$(cat "$TMP/prior.txt" 2>/dev/null)' in the prior file"

# ── AND IT IS NOT THE SUMMARY OR THE HEAD FILE ────────────────────────────
# Aliased to the summary the baseline overwrites the account this stage posts;
# aliased to the head file it overwrites the head `post` re-proves against. Both are
# what an operator with a tidy scratch directory produces by accident.
world; got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf)" "$TMP/summary.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'overwrite the account' <<<"${got#*|}"; } \
    && pass "a prior file that is the summary file is refused" \
    || die "the prior/summary alias gave '$got'"
world; _hf="$(headf)"; got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$_hf" "$_hf")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'overwrite the head' <<<"${got#*|}"; } \
    && pass "…and one that is the head file is refused too" \
    || die "the prior/head alias gave '$got'"
# …AND UNDER ANOTHER NAME, which is what the `-ef` half is for. The two cases above
# pass the SAME pathname, so string equality answers them and `-ef` never runs — a
# regression dropping it would leave them green while a symlinked prior file
# overwrote the account or the head. Both targets, both reached by a second name.
world; ln -sf "$TMP/summary.md" "$TMP/palias.txt"
got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf)" "$TMP/palias.txt")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'overwrite the account' <<<"${got#*|}"; } \
    && pass "…and a prior file that is the summary under another name is refused" \
    || die "the symlinked prior/summary alias gave '$got'"
rm -f "$TMP/palias.txt"
world; _hf="$(headf)"; ln -sf "$_hf" "$TMP/palias.txt"
got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$_hf" "$TMP/palias.txt")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'overwrite the head' <<<"${got#*|}"; } \
    && pass "…and the head file under another name is refused too" \
    || die "the symlinked prior/head alias gave '$got'"
rm -f "$TMP/palias.txt"

# ── THE WRITE HAPPENS BEFORE THE REQUEST, AND THAT IS WHAT THIS PROVES ─────
# The success assertion above sees the file only after `post` returns, so it passes
# just as well if the write moved AFTER the request, if its status went unchecked,
# or if the read-back went away. What makes the ordering safety-critical is that
# there is nothing to refuse with afterwards: the summary is posted and the pass
# requested, so a driver reading a truncated baseline watches against a value no
# request was made with, and the round cannot be un-closed.
#
# STAGED BY MAKING THE WRITE FAIL: a DIRECTORY at the prior path takes no
# redirection. It passes every argument check — non-empty, neither the summary nor
# the head file — and the pre-bootstrap truncation skips it, being guarded on `-f`.
# So the first thing that can fail is the write itself.
world; rm -rf "$TMP/priordir"; mkdir -p "$TMP/priordir"
got="$(stage post 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf "$HEAD40")" "$TMP/priordir")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'could not write the review baseline' <<<"${got#*|}"; } \
    && pass "a baseline that cannot be written stops the stage" \
    || die "the unwritable prior file gave '$got'"
# AND NOTHING WAS REQUESTED, which is the half the status cannot show. Both request
# paths are checked, because which one runs depends on the reviewer.
grep -qE 'gh pr comment|gh pr edit' "$TMP/calls" \
    && die "the stage requested a review before the baseline was handed over" \
    || pass "…before the summary was posted or any pass requested"
rm -rf "$TMP/priordir"
world; got="$(stage post 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf "$HEAD40")" "")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'a prior file is required' <<<"${got#*|}"; } \
    && pass "…and an absent one is a refusal rather than a silent skip" \
    || die "the missing prior file gave '$got'"

# ── THE HEAD `post` CLOSES ON IS THE HEAD `gate` PROVED ────────────────────
# Answering threads takes as long as it takes. A commit made in between leaves the
# summary describing one commit while the reviewer reads another, and the gate's
# green verdict belongs to the first.
world; printf '%s\n' "$PREV40" > "$W/local.out"
got="$(stage post 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf "$HEAD40")")"
{ [ "${got%%|*}" = 1 ] && grep -qF "the local head is $PREV40" <<<"${got#*|}"; } \
    && pass "a local commit made while the threads were answered stops the close" \
    || die "a moved local head gave '${got}'"
grep -q 'gh pr comment' "$TMP/calls" \
    && die "it posted the summary about a commit it had not proved" \
    || pass "…before anything was posted"

# AND ON THE PR, because the local head agreeing proves only that this checkout
# did not move — a force-push from elsewhere moves the head the reviewer reads.
world; printf '%s\n' "$PREV40" > "$W/head.out"; printf '%s\n' "$HEAD40" > "$W/local.out"
got="$(stage post 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf "$HEAD40")")"
{ [ "${got%%|*}" = 1 ] && grep -qF "the PR head is $PREV40" <<<"${got#*|}"; } \
    && pass "a head moved on the PR stops the close" \
    || die "a moved PR head gave '${got}'"
grep -q 'gh pr comment' "$TMP/calls" \
    && die "it posted the summary about a commit that is no longer the head" \
    || pass "…before anything was posted"

# An unreadable or malformed confirmation is a stop, never "close anyway".
world; printf '1\n' > "$W/head.rc"
got="$(stage post 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf "$HEAD40")")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'could not confirm the head' <<<"${got#*|}"; } \
    && pass "an unreadable head confirmation stops the close" \
    || die "a failed confirmation gave '${got}'"
world; printf 'not-a-sha\n' > "$W/head.out"
got="$(stage post 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf "$HEAD40")")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'is not a full OID' <<<"${got#*|}"; } \
    && pass "…and so does one that is not an OID" \
    || die "a malformed confirmation gave '${got}'"

# ── THE STAGE ITSELF IS NAMED, AND HAS NO DEFAULT ──────────────────────────
# A default is the whole defect back: a caller that forgets which half it is
# running would silently get one, and the one it got would skip the threads. The
# four-argument form this replaced lands here as a PR number in stage position.
world
got="$(stage 7 "$CODEXBOT" "$TMP/summary.md" no)"
{ [ "${got%%|*}" = 1 ] && grep -qF "'7' is not a stage" <<<"${got#*|}"; } \
    && pass "the old four-argument form is refused by name" \
    || die "the old form gave '${got}'"
grep -q 'git push' "$TMP/calls" \
    && die "the old form pushed" \
    || pass "…having done nothing"
world; got="$(stage "" 7 "$CODEXBOT" "$TMP/summary.md" no)"
{ [ "${got%%|*}" = 1 ] && grep -qF 'a stage is required' <<<"${got#*|}"; } \
    && pass "an empty stage is refused" \
    || die "an empty stage gave '${got}'"
world; got="$(stage close 7 "$CODEXBOT" "$TMP/summary.md" no)"
{ [ "${got%%|*}" = 1 ] && grep -qF "'close' is not a stage" <<<"${got#*|}"; } \
    && pass "an unknown stage is refused by name" \
    || die "an unknown stage gave '${got}'"

# THE HANDOFF BELONGS TO EXACTLY ONE STAGE.
world; got="$(stage post 7 "$CODEXBOT" "$TMP/summary.md" no)"
{ [ "${got%%|*}" = 1 ] && grep -qF 'a head file is required' <<<"${got#*|}"; } \
    && pass "post without the head file is refused" \
    || die "post with no head file gave '${got}'"
world; got="$(stage post 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf aaaa)")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'is not a full OID' <<<"${got#*|}"; } \
    && pass "…and so is a file holding an abbreviated one" \
    || die "post with a short head gave '${got}'"
world; got="$(stage post 7 "$CODEXBOT" "$TMP/summary.md" no "$TMP/no-such-head")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'could not read the gated head' <<<"${got#*|}"; } \
    && pass "…and a head file that is not there stops the post" \
    || die "post with a missing head file gave '${got}'"
# THE HEAD FILE MAY NOT BE THE SUMMARY FILE. `gate` reads the summary and then
# writes the head, so one file serving as both means the head overwrites the
# account — and `post` then finds a well-formed OID there, passes the non-empty
# test, and posts the sha as this round's summary. Both identities are staged: the
# same path, and a symlink, which is the same file under two names.
world; got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$TMP/summary.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'are the same file' <<<"${got#*|}"; } \
    && pass "a head file that IS the summary file is refused" \
    || die "the aliased head file gave '${got}'"
world; ln -sf "$TMP/summary.md" "$TMP/alias.txt"
got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$TMP/alias.txt")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'are the same file' <<<"${got#*|}"; } \
    && pass "…and so is a symlink to it" \
    || die "the symlinked head file gave '${got}'"
rm -f "$TMP/alias.txt"
# AND A REFUSAL LEAVES THE HEAD FILE EMPTY, which is what the driver's post step
# guards on. `gate` empties it before it does anything, so a file still holding
# the PREVIOUS round's head cannot pass that guard.
world; printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$HEADF"
got="$(stage gate 7 "$CODEXBOT" "$TMP/nope.md" no "$HEADF")"
{ [ "${got%%|*}" = 1 ] && [ ! -s "$HEADF" ]; } \
    && pass "…and a refused gate leaves no stale head behind" \
    || die "a refused gate left '$(cat "$HEADF" 2>/dev/null)' in the head file (rc=${got%%|*})"
# EVERY NON-ALIAS REFUSAL, INCLUDING THE ONES VALIDATED BEFORE THE SUMMARY IS READ.
# The truncation sat below the PR-number and reviewer checks and was reached by
# neither, so a stale OID survived exactly the refusals a driver is most likely to
# walk past. Both are staged because they abort at different points.
for _st_bad in "PR:x:$CODEXBOT" "reviewer:7:some-other-bot[bot]"; do
    _st_what="${_st_bad%%:*}"; _st_rest="${_st_bad#*:}"
    _st_pr="${_st_rest%%:*}"; _st_who="${_st_rest#*:}"
    world; printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$HEADF"
    got="$(stage gate "$_st_pr" "$_st_who" "$TMP/summary.md" no "$HEADF")"
    { [ "${got%%|*}" = 1 ] && [ ! -s "$HEADF" ]; } \
        && pass "…and a gate refused on the $_st_what leaves no stale head either" \
        || die "a bad $_st_what left '$(cat "$HEADF" 2>/dev/null)' in the head file (rc=${got%%|*})"
done
# AND A BOOTSTRAP REFUSAL TOO, which is earlier than any argument. With no origin
# and no pin, `rb_identity` cannot answer and the stage exits before it has parsed
# anything — so the clearing has to happen before the loads, not after them.
world; printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$HEADF"
# THE REFUSAL IS STAGED BY EMPTYING A LIBRARY IN A COPY OF THE TREE, which is a
# real bootstrap failure — `rb_load` refuses and the stage exits at the top of the
# file, long before any argument is looked at.
rm -rf "$TMP/broken"; cp -R "$DIR" "$TMP/broken" || die "could not copy the scripts for the bootstrap case"
: > "$TMP/broken/recordlib.sh"
printf '%s\n' 'STALE-BASELINE' > "$TMP/prior.txt"
_st_out="$(cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' REVIEW_BUS_OWNER= REVIEW_BUS_REPO= \
    "$TMP/broken/pr-close-round.sh" gate 7 "$CODEXBOT" "$TMP/summary.md" no "$HEADF" "$TMP/prior.txt" 2>&1)"; _st_rc=$?
{ [ "$_st_rc" != 0 ] && [ ! -s "$HEADF" ]; } \
    && pass "…and a gate that cannot bootstrap leaves no stale head either" \
    || die "a bootstrap refusal left '$(cat "$HEADF" 2>/dev/null)' in the head file (rc=$_st_rc out='$_st_out')"
# AND NO STALE BASELINE, for the same reason and by the same means. The truncation
# further down never runs when the bootstrap refuses, so a previous round's value
# would still be sitting there for the driver's watch to take. #234.
[ ! -s "$TMP/prior.txt" ] \
    && pass "…and no stale baseline either" \
    || die "a bootstrap refusal left '$(cat "$TMP/prior.txt" 2>/dev/null)' in the prior file"

# AND A FILE NAMED AFTER AN OID IN THE CURRENT DIRECTORY IS NOT TOUCHED. The
# pre-#202 form puts the head itself in that position, and the bootstrap clear runs
# before anything can recognise it — so the slash is what tells a path from an OID
# there. Without it this call would truncate an unrelated file and only then refuse.
world; printf 'do not touch me\n' > "$TMP/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
got="$(cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' REVIEW_BUS_OWNER= REVIEW_BUS_REPO= \
    "$DIR/pr-close-round.sh" gate 7 "$CODEXBOT" "$TMP/summary.md" no aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$TMP/prior.txt" 2>&1)"; _oid_rc=$?
{ [ "$_oid_rc" = 1 ] && grep -qF 'the head FILE, not the head itself' <<<"$got" \
    && [ -s "$TMP/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]; } \
    && pass "…and an existing file named after an OID is refused, not truncated" \
    || die "the OID-named file case gave rc=$_oid_rc out='$got' content='$(cat "$TMP/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" 2>/dev/null)'"
# AND A HEAD FILE THAT CANNOT BE EMPTIED STOPS THE STAGE, rather than leaving the
# previous round's OID for a bootstrap refusal to hand on.
# THE PRECONDITION IS ESTABLISHED RATHER THAN ASSUMED. `chmod 400` does not stop
# uid 0 from writing, and containers run this suite as root — so the case would
# report a defect in the implementation when the fixture is what could not be set
# up. It probes the mode bits first and skips itself by name when they do not bite.
world; printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$HEADF"
chmod 400 "$HEADF"
if ( > "$HEADF" ) 2>/dev/null; then
    chmod 600 "$HEADF"
    pass "…(the untruncatable-head case is skipped: this uid can write through mode 400)"
else
    got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$HEADF")"
    chmod 600 "$HEADF"
    { [ "${got%%|*}" = 1 ] && grep -qF 'cannot be emptied' <<<"${got#*|}"; } \
        && pass "…and a head file that cannot be emptied stops the stage" \
        || die "an untruncatable head file gave '${got}'"
fi

# AND THE ALIAS REFUSAL IS THE EXCEPTION, deliberately: truncating a head file that
# IS the summary destroys the account. The summary must survive it.
world; got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$TMP/summary.md")"
{ [ "${got%%|*}" = 1 ] && [ -s "$TMP/summary.md" ]; } \
    && pass "…while the alias refusal leaves the summary intact, which is why it comes first" \
    || die "the alias refusal destroyed the summary (rc=${got%%|*})"

# THE OLD FORM IS REFUSED BY NAME, on BOTH stages. A caller still passing the sha
# would otherwise have `gate` create a file called `a8ec960…` and `post` fail with
# a reason about a missing file rather than about the caller. #202.
world; got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'the head FILE, not the head itself' <<<"${got#*|}"; } \
    && pass "a gate handed the head itself is refused by name" \
    || die "gate with a head gave '${got}'"
world; got="$(stage post 7 "$CODEXBOT" "$TMP/summary.md" no "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'the head FILE, not the head itself' <<<"${got#*|}"; } \
    && pass "…and so is a post handed the old fifth argument" \
    || die "post with the old form gave '${got}'"
# AND THE GATE WRITES WHAT IT REPORTS. The record and the file are two claims, and
# `post` reads the file — so the fixture proves they agree rather than trusting
# the record it can see.
# COMPARED AS WHOLE STRINGS, WITH BOTH PRODUCERS' STATUSES TAKEN. `grep -qF` tests
# CONTAINMENT, so a `report_gated` that wrote a truncated prefix while reporting
# the full OID would satisfy it; and an inline `$(cat …)` that fails yields an
# empty pattern, which matches everything. Both were in the first version of this
# case.
world; got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf)")"
_hf_rec=""; _hf_file=""; _hf_rc=0
_hf_rec="$(sed -n 's/^PR_ROUND_GATED .*[[:space:]]head=\([0-9a-f]*\).*$/\1/p' <<<"${got#*|}")" || _hf_rc=1
_hf_file="$(cat "$HEADF")" || _hf_rc=1
{ [ "${got%%|*}" = 0 ] && [ "$_hf_rc" = 0 ] \
  && [ -n "$_hf_rec" ] && [ "$_hf_rec" = "$_hf_file" ]; } \
    && pass "…and the head the gate reports is exactly the head it wrote to the file" \
    || die "the gate's record and its head file disagree: record='$_hf_rec' file='$_hf_file' rc='${got%%|*}/$_hf_rc'"

# ── A HEAD WITH NO REVIEW YET REPORTS THE `none` BASELINE, AND THAT IS AN ANSWER ─
# `pr-review-state.sh review-id` returns nothing when the current head has no
# review — every round that pushes a new commit, and every Copilot round, since a
# push never triggers one. The record must still carry the field, so the driver
# can tell "no baseline yet" from "no record at all"; `pr-watch.sh` takes the
# `none` token as "wait on any terminal review".
world; : > "$W/pr-review-state.out"
got="$(stage post 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf "$HEAD40")")"
{ [ "${got%%|*}" = 0 ] && grep -q 'PR_ROUND_CLOSED .* prior-review=none$' <<<"${got#*|}"; } \
    && pass "a head with no review yet closes, reporting the none baseline" \
    || die "a head with no review yet gave '${got}'"
# …AND IT REACHES THE FILE AS THE `none` TOKEN — #264. It used to reach it as an EMPTY
# file, which meant "no floor" and was therefore indistinguishable from a truncation whose
# write then failed. The token has to be written on purpose, so the watch can tell the
# answer from the accident: an empty file is `state=error` there now.
#
# `gate` STILL EMPTIES THIS FILE, and that is why the change is safe rather than merely
# tidier — an emptied baseline reaching the watch is a refusal instead of a no-floor, so a
# `post` that fails after `gate` stops the round rather than arming a watch against
# nothing.
raw_is "$TMP/prior.txt" 'none
' "post's none baseline"

# ── THE READ-BACK COMPARES THE TERMINATOR, AND WHY THAT IS ASSERTED ON THE SOURCE ─
#
# The read-back used `$(<…)`, which STRIPS trailing newlines, so it could not see the
# delimiter `pr-watch.sh` now requires. A path replaced between the write and the read with
# the SAME id and no newline compared equal, this stage posted the request, and the watch
# then refused the file as `unterminated_after_review_file` — with the round IRREVERSIBLY
# half-closed, since the summary is up and the next pass is queued.
#
# THE WINDOW CANNOT BE STAGED, and that is a fact about its shape rather than a gap left
# open. The write and the read-back are ADJACENT: no external command runs between them, so
# there is nothing on `PATH` a shim can attach to, and a racer would be aiming at an
# interval of two shell operations — a case that tries would pass on scheduling. This was
# built and did not land: a `gh` shim fires only at the post, which is after both.
#
# SO WHAT IS ASSERTED IS THE COMPARISON'S SHAPE: that the child compares against the value
# WITH its newline, and that the caller no longer reads the file into a stripping
# substitution. That is weaker than a behavioural case and it is the strongest thing
# available here — and it is exact enough to fail: restoring `$(<…)` or dropping the
# newline from the expected value both break it.
_rb_body="$(awk '/# THE READ-BACK COMPARES RAW BYTES/,/nothing has been posted."; return 1; }/' "$SCRIPT")" || _rb_body=""
case "$_rb_body" in
    *'_ "$PRIOR_FILE" "$prior
"'*) pass "the baseline read-back compares against the value INCLUDING its terminator" ;;
    *) die "the read-back does not compare the terminator; a replacement stripping it would pass: '$_rb_body'" ;;
esac
case "$_rb_body" in
    *'$(<"$PRIOR_FILE")'*) die "the read-back still reads through a substitution, which strips the terminator" ;;
    *) pass "…and does not read it through a substitution, which would strip that byte" ;;
esac
{ [ -f "$TMP/prior.txt" ] && [ "$(cat "$TMP/prior.txt")" = none ]; } \
    && pass "…and the prior file reads back as the none token rather than empty or a previous round's value" \
    || die "a head with no review yet left '$(cat "$TMP/prior.txt" 2>/dev/null)' in the prior file"

# AND THE FIELD IS STILL THERE, which is the whole difference between an answer
# and a malformed record. Asserted on the record itself rather than on the value,
# because a record that simply dropped the field also has an "empty" value.
grep -qF ' prior-review=' <<<"${got#*|}" \
    && pass "…with the field present, so an absent record stays distinguishable" \
    || die "the none-baseline record dropped the field entirely: '${got#*|}'"

# THE SAME ON THE PATH WHERE THE BASELINE IS ALSO HANDED TO THE WATCH. A first
# auto-review round has no prior review to wait past, and the gate must not refuse
# its own empty baseline before the push it exists to make.
world; : > "$W/pr-review-state.out"; printf '%s\n' "$PREV40" > "$W/head.before.out"
got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" yes "$(headf)")"
{ [ "${got%%|*}" = 0 ] && grep -qF 'PR_ROUND_GATED' <<<"${got#*|}"; } \
    && pass "a first push-triggered round gates on an empty baseline" \
    || die "an empty push baseline gave '${got}'"
grep -q -- '--after-review $' "$TMP/calls" \
    && pass "…and the watch is handed that empty value rather than a substitute" \
    || die "the push-pass watch was not given the empty baseline: $(grep 'pr-watch' "$TMP/calls")"

# ── THE BOUNDARY PAUSES THE GATE, BEFORE THE PUSH ──────────────────────────
world; printf '3\n' > "$W/pr-round-count.rc"
got="$(stage gate 7 "$CODEXBOT" "$TMP/summary.md" no "$(headf)")"
{ [ "${got%%|*}" = 3 ] && grep -qF 'round boundary reached' <<<"${got#*|}"; } \
    && pass "a round boundary pauses the gate" \
    || die "a boundary gave '${got}'"
grep -q 'git push' "$TMP/calls" \
    && die "it pushed at a round boundary" \
    || pass "…with nothing pushed and nothing resolved"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
