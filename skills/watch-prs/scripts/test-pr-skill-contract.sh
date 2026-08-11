#!/usr/bin/env bash
# Doc-regression for the v2 driver contract.
#
# Every assertion here exists because the contract and the behaviour drifted
# apart at least once in v1: a documented command that could not run, a merge
# that was not pinned to the head its gates checked, a "cannot tell" the driver
# was never told to stop on.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$SCRIPT_DIR/../SKILL.md"
ROOT="$SCRIPT_DIR/../../.."
# The shared fixture helpers. This was the one test file in the suite that never
# sourced them, and it was the one still holding a bare `mktemp -d`.
. "$SCRIPT_DIR/testlib.sh"

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

if [ ! -f "$SKILL" ]; then
    echo "ok   - skill not present in this checkout; contract checks skipped"
    echo "RESULT: PASS"
    exit 0
fi

# ── the reviewers are the GitHub apps, not a local process ─────────────────
grep -q 'chatgpt-codex-connector\[bot\]' "$SKILL" \
    && pass "skill names the Codex bot login" \
    || die "skill does not name chatgpt-codex-connector[bot]"
grep -q 'copilot-pull-request-reviewer\[bot\]' "$SKILL" \
    && pass "skill names the Copilot bot login" \
    || die "skill does not name copilot-pull-request-reviewer[bot]"
grep -q '@codex review' "$SKILL" \
    && pass "skill documents the @codex mention as the Codex trigger" \
    || die "skill does not document the @codex trigger"
grep -q 'add-reviewer @copilot' "$SKILL" \
    && pass "skill documents the Copilot review request" \
    || die "skill does not document requesting Copilot"

# v1's daemons must not come back by reference: a contract that still tells the
# driver to start a watcher would leave it waiting for a bus that no longer
# exists.
for gone in review-bus-codex-start review-bus-codex-watcher review-bus-response-monitor \
            review-bus-request review-bus-close-round 'systemd --user'; do
    grep -q -- "$gone" "$SKILL" \
        && die "skill still references the removed v1 machinery: $gone" \
        || pass "no reference to removed machinery ($gone)"
done

# ── the connector prerequisite is stated ───────────────────────────────────
# Without it @codex answers with a setup link, which is easy to misread as a
# review that found nothing.
grep -qi 'connect' "$SKILL" && grep -q 'connectors' "$SKILL" \
    && pass "skill states the one-time connector prerequisite" \
    || die "skill does not tell the operator to link the Codex connector"

# ── every 'cannot tell' is a stop ──────────────────────────────────────────
grep -qi 'fail closed' "$SKILL" \
    && pass "skill states the fail-closed rule" \
    || die "skill does not state that an unreadable state fails closed"
grep -q 'pr-review-state.sh' "$SKILL" \
    && pass "skill drives pr-review-state.sh" \
    || die "skill does not use pr-review-state.sh"
grep -q 'pr-merge-range.sh' "$SKILL" \
    && pass "skill drives pr-merge-range.sh" \
    || die "skill does not use pr-merge-range.sh"
# The round check-in must have an implementation, not just a promise: v1's
# guarantee lived in a /tmp counter that vanished with the file.
grep -q 'pr-round-count.sh' "$SKILL" \
    && pass "the round check-in is enforced by a script, not only described" \
    || die "skill promises a round check-in with nothing implementing it"

# ── the merge gate resolves the head ONCE and pins every check to it ───────
# Letting each verdict resolve the head itself lets a push land between them, so
# both verdicts describe an older commit while the merge pins the newer one.
# Each reviewer is checked on the head IT reviewed. Checking Codex on $HEAD_OID
# makes the gate unreachable in the Copilot phase: Codex is deliberately not
# re-run there, so its verdict on a Copilot-fix commit is `none` forever.
# Both obvious answers are wrong: always-$HEAD_OID makes the gate unreachable in
# the Copilot phase, always-$CODEX_SHA ignores a NEW Codex review that auto-review
# may have produced on the current head — and a body-only CHANGES_REQUESTED leaves
# no thread for the unresolved gate to catch.
grep -q 'state N "$CODEX_BOT" "$HEAD_OID"' "$SKILL" \
    && pass "the gate asks whether Codex has judged the CURRENT head" \
    || die "the gate never checks for a newer Codex review on the current head"
grep -qE 'verdict N "\$CODEX_BOT" +"\$CODEX_SHA"' "$SKILL" \
    && pass "…and falls back to the recorded signoff when it has not" \
    || die "there is no fallback to \$CODEX_SHA — the gate cannot pass after a Copilot fix"
grep -qE 'verdict N "\$CODEX_BOT" +"\$HEAD_OID"' "$SKILL" \
    && pass "…and a current-head Codex judgement wins over the older one" \
    || die "a newer Codex review on the current head is never honoured"
# ONLY rc 0 is an answer: this branch decides whether to fall back to the older
# signoff, so a bad read merges on a state that was never trusted.
grep -q 'CODEX_STATE_RC" -ne 0' "$SKILL" \
    && pass "any non-zero Codex head-state status blocks the merge" \
    || die "only the documented rc 2 blocks — a wrapper failure would fall through"
# CODEX_SHA has to be captured before the head moves; nothing else records it.
grep -q 'CODEX_SHA=$(gh pr view' "$SKILL" \
    && pass "the Codex-signed-off head is captured before the Copilot phase" \
    || die "CODEX_SHA is required by the gate but never assigned"
# With auto-review on, the PUSH requests the next review — so the boundary check
# has to precede it, not merely precede the explicit re-request.
# A fragment that fits on ONE line — the file is wrapped and `grep` is line
# oriented, so a phrase spanning a line break silently never matches. Fourth time.
grep -qi 'precede the push' "$SKILL" \
    && pass "the round boundary is checked before the push" \
    || die "the boundary check runs after the push, which auto-review has already acted on"
grep -qE 'verdict N "\$COPILOT_BOT" +"\$HEAD_OID"' "$SKILL" \
    && pass "Copilot is validated on the current head" \
    || die "Copilot's verdict is not pinned to \$HEAD_OID"
# …and the range check is what makes trusting an older Codex signoff safe.
# The range must measure from the sha the VERDICT describes. Keyed to the stale
# recorded sha, it demands Copilot trailers across a range Codex has already
# reviewed in full — blocking a merge both reviewers just approved.
grep -qE 'pr-merge-range.sh "\$CODEX_EFFECTIVE_SHA" "\$HEAD_OID"' "$SKILL" \
    && pass "the range check measures from the sha Codex's verdict describes" \
    || die "the range check is keyed to \$CODEX_SHA even when Codex reviewed the head"
[ "$(grep -c 'CODEX_EFFECTIVE_SHA=' "$SKILL")" -ge 2 ] \
    && pass "the effective Codex sha is set on BOTH branches" \
    || die "the effective Codex sha is not set on every branch"
grep -q 'CODEX_SHA" =~ \^\[0-9a-f\]{40}\$' "$SKILL" \
    && pass "the Codex signoff SHA is shape-checked before it is trusted" \
    || die "CODEX_SHA is used without validating its shape"
grep -q 'HEAD_RC' "$SKILL" \
    && pass "the head lookup checks its exit status" \
    || die "the head lookup does not branch on its own status"
grep -q 'CHECKS_RC' "$SKILL" \
    && pass "the required-checks probe checks its exit status" \
    || die "the required-checks probe compares output without its status"

# ── the pushed head is checked before the round is closed ─────────────────
# CI was red for four consecutive commits and nothing noticed: every round was
# closed on a local suite run, and `pr-selfcheck.sh` runs BEFORE the push, so it
# cannot see a failure that only happens on the runner. "The suite passes here"
# and "the checks pass there" are different claims. Issue #16.
grep -q '^ci_gate() {' "$SKILL" \
    && pass "the driver has a CI gate for the head it pushed" \
    || die "nothing checks whether the pushed head is green"
# EVERY push site calls it. One that does not is a round closed on an unknown
# state, and the two sites exist precisely because the ordering differs — which is
# how one of them comes to be missing a step the other has.
# `|| …=0`: `grep -c` exits 1 when nothing matches, and this file runs under `-e`,
# so an unguarded count terminated the suite at the first call-form change instead
# of reporting the mismatch it exists to report.
# EVERY push site, and every other point that accepts a head. A PR whose reviews
# were clean from the start never pushes anything, so gating only the push sites
# left it never checked at all — through both phases and into a merge gate that
# looks at REQUIRED checks only, which a failing optional one is not.
pushes="$(grep -c '^git push ||' "$SKILL")" || pushes=0
gates="$(grep -cE '^(if ! )?ci_gate N ' "$SKILL")" || gates=0
[ "${pushes:-0}" -gt 0 ] && [ "$gates" -ge "$pushes" ] \
    && pass "…and every push site passes through it ($gates gates, $pushes pushes)" \
    || die "a push site closes its round without checking CI ($gates gates for $pushes pushes)"
# The two paths that accept a verdict WITHOUT a push: the Codex→Copilot phase
# transition, and the merge gate. Named individually, because a count alone is
# satisfied by two gates on the same site.
grep -q '^ci_gate N "\$CODEX_SHA"' "$SKILL" \
    && pass "…and a clean verdict does not open the Copilot phase unchecked" \
    || die "a PR that never pushed can enter the Copilot phase with a red head"
grep -q '^ci_gate N "\$HEAD_OID"' "$SKILL" \
    && pass "…nor reach the merge with only its required checks read" \
    || die "the merge gate reads only required checks; a failing optional one passes"
# …AND EVERY ONE IS ASKED ABOUT A COMMIT. `gh pr checks` is addressed by PR number
# and the API can still be serving the previous head for a moment after a push, so
# an unpinned call can return the previous round's green as this round's answer.
oid_gates="$(grep -cE '^(if ! )?ci_gate N "\$[A-Z_]+"' "$SKILL")" || oid_gates=0
[ "$oid_gates" = "$gates" ] \
    && pass "…naming an OID, not just the PR ($oid_gates/$gates)" \
    || die "$((gates - oid_gates)) CI gate call(s) do not pin the head they ask about"
# …AFTER the push and BEFORE the review is requested. Asking before the push reads
# the previous head's result, which is the last round's answer to this round's
# question; asking after the request means the pass is already running.
awk '/^git push \|\|/ {p=NR}
     /^(if ! )?ci_gate N "\$HEAD_/ {if (p && p < NR) g=NR}
     /gh pr comment N/ {if (g && g < NR) {print "ok"; exit}}' "$SKILL" | grep -q ok \
    && pass "…between the push and the request, so it answers about this head" \
    || die "the CI gate does not sit between the push and the review request"
# THE MANUAL PATH GATES BEFORE ANYTHING IS CLOSED. Where the mention is the
# trigger, nothing has been resolved or posted when the gate runs, so a red head
# leaves the round genuinely open — that ordering is the whole value and it is the
# one a later edit would most easily invert.
awk '/^ci_gate N "\$HEAD_PUSHED"/ {g=NR}
     g && /^SUMMARY="\$\(cat "\$SUMMARY_FILE"\)"/ {print "ok"; exit}' "$SKILL" | grep -q ok \
    && pass "…and in the manual path it precedes the summary, so a red round stays open" \
    || die "the manual path posts its summary before knowing whether the head is green"
# AND SO DOES THE AUTOMATIC PATH. It used to close first and push last, so that
# the pass the push starts would find the summary already there — an ordering that
# cannot be gated, because by the time the checks can be consulted the threads are
# resolved and the summary is posted. A later "this round is not closed" comment is
# a record, not a retraction, and is itself a call that can fail. The push moved
# ahead of the closure; what that costs is a pass reading open threads, and that is
# recoverable in a way a closed round is not.
awk '/^\*\*Automatic review ON\*\*/ {inb=1}
     inb && /^ci_gate N "\$HEAD_BEFORE"/ {g=NR}
     inb && g && /gh pr comment N --repo \$HOST\/\$OWNER\/\$REPO --body "\$SUMMARY"/ {print "ok"; exit}' "$SKILL" \
    | grep -q ok \
    && pass "…and in the automatic path the gate precedes the summary too" \
    || die "the automatic path posts its summary before knowing whether the head is green"
# PENDING IS NOT GREEN — AND THE GATE IS RUN TO PROVE IT. The checks start when
# the push lands, so an immediate ask always finds them running; treating that as a
# pass closes every round before its own CI has said anything, which is the
# original defect with an extra step.
#
# A grep for `PR_CI_TIMEOUT` passed while the pending arm returned 0 — the presence
# of a timeout says nothing about what is done with a pending verdict. So the
# function is extracted and executed against a stubbed `pr-ci-state.sh` that
# answers on a script, the same reason the parser-clear branch is executed rather
# than matched.
gate_fn="$(sed -n '/^ci_gate() {/,/^}/p' "$SKILL")"; gate_rc=$?
[ "$gate_rc" -eq 0 ] && [ -n "$gate_fn" ] \
    || die "the ci_gate function could not be extracted from SKILL.md (rc=$gate_rc)"
# EVERYTHING IT ASSIGNS IS ITS OWN. `SKILL.md`'s blocks run in the driving
# session's shell, so a name this function forgets to declare `local` is written
# into that session — clobbering whatever was there and being clobbered in turn,
# which for a loop counter or a sleep interval is a bug nobody would look for
# here. `nap` was such a name.
#
# `PR_CI_*` is excluded: those are documented inputs, and the one that appears at
# the start of a line is a command PREFIX — `PR_CI_PROBE_TIMEOUT="$b" cmd …` — not
# an assignment to a variable of this function's.
gate_assigned="$(printf '%s\n' "$gate_fn" \
    | grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' | tr -d ' =' | sort -u)" || gate_assigned=""
gate_local="$(printf '%s\n' "$gate_fn" | grep -E '^[[:space:]]*local ' \
    | sed -E 's/^[[:space:]]*local //; s/=[^ ]*//g' | tr ' ' '\n' | sort -u)" || gate_local=""
gate_leaks=""
for v in $gate_assigned; do
    case "$v" in PR_CI_*) continue ;; esac
    printf '%s\n' "$gate_local" | grep -qx "$v" || gate_leaks="$gate_leaks $v"
done
[ -z "$gate_leaks" ] \
    && pass "every name the CI gate assigns is declared local to it" \
    || die "the CI gate writes into the driving session:$gate_leaks"
# THE CHILD SKIPS THESE. The cleanup probe further down re-runs this whole file to
# watch it remove its scratch tree, and these cases are the slow part — every one
# of them waits on real `sleep`s. Re-running them inside that child doubled the
# file's cost for nothing and, run after the other ten suites, pushed the child
# past its own watchdog: the leak check then reported that its run had failed,
# which is true and useless. The child needs the file to COMPLETE, not to re-prove
# the gate.
GATETMP=""
if [ -z "${CONTRACT_SCRATCH_PROBE-}" ]; then
    GATETMP="$(mktemp_d)" || { die "no scratch directory for the CI gate probe"; GATETMP=""; }
fi
if [ -n "$GATETMP" ] && [ -n "$gate_fn" ]; then
    mkdir -p "$GATETMP/s"
    # Answers come from a queue, one per call, so a gate that polls is
    # distinguishable from one that decides on the first answer.
    cat > "$GATETMP/s/pr-ci-state.sh" <<'STUBSH'
#!/usr/bin/env bash
# `tail -n +2`, not `sed -i` — in-place editing without a suffix argument is
# GNU-only, and stock macOS runs this suite as a mandatory pre-push gate.
# The bound it was handed, recorded — the gate is supposed to pass its REMAINING
# time, not let the helper use its own sixty-second default.
printf '%s\n' "${PR_CI_PROBE_TIMEOUT:-unset}" >> "$GATE_PROBE"
rc="$(head -1 "$GATE_Q")"
tail -n +2 "$GATE_Q" > "$GATE_Q.next" && mv "$GATE_Q.next" "$GATE_Q"
# A SLOW PROBE, when asked for. The timeout has to be a real duration bound, and
# counting only the sleeps excluded however long each probe took.
[ -n "${GATE_DELAY:-}" ] && sleep "$GATE_DELAY"
echo "call" >> "$GATE_CALLS"
# An EXHAUSTED queue REPEATS ITS LAST ANSWER, which is what a real check state
# does — it does not change into something else because the fixture ran out of
# script. A fixed default of "pending" made the `none` grace case unreachable: the
# single `4` was followed by `3`s, the grace counter reset every poll, and a
# repository that genuinely has no checks could never close a round.
if [ -n "$rc" ]; then printf '%s\n' "$rc" > "$GATE_LAST"; else rc="$(cat "$GATE_LAST" 2>/dev/null)"; fi
exit "${rc:-3}"
STUBSH
    chmod +x "$GATETMP/s/pr-ci-state.sh"
    gate_case() {   # gate_case <queue> <want rc> <want calls> <label> [env…]
        local out rc=0 calls q="$1" want="$2" mincalls="$3" label="$4"
        shift 4
        printf '%s\n' "$q" > "$GATETMP/q"; : > "$GATETMP/calls"
        : > "$GATETMP/last"
        : > "$GATETMP/probe"
        out="$(run_limited 20 env GATE_Q="$GATETMP/q" GATE_CALLS="$GATETMP/calls" \
            GATE_LAST="$GATETMP/last" GATE_PROBE="$GATETMP/probe" \
            RB_SCRIPTS="$GATETMP/s" PR_CI_INTERVAL=1 PR_CI_TIMEOUT=5 PR_CI_GRACE=2 "$@" \
            bash -c "$gate_fn"'
                ci_gate 7 0123456789abcdef0123456789abcdef01234567' 2>&1)" || rc=$?
        calls="$(grep -c call "$GATETMP/calls" 2>/dev/null)" || calls=0
        { [ "$rc" = "$want" ] && [ "${calls:-0}" -ge "$mincalls" ]; } \
            && pass "$label" \
            || die "$label — rc=$rc calls=$calls out='$out' (wanted $want / >=$mincalls calls)"
    }
    # GREEN MUST HOLD, TOO. A push that triggers two workflows can have the fast
    # one registered and passing before the second is registered at all, so the
    # first probe is green about an incomplete picture — and the later workflow
    # then appears and fails after the round is closed. The same registration
    # grace that `none` needs.
    gate_case '0'     0 2 "a green head lets the round close, once that is stable"
    # Grace beyond the queue, for the same reason as the `none` case below: two
    # greens could earn a grace of two before the queued failure was reached, and
    # the case would close the round it exists to see stopped. Anywhere a QUEUE is
    # the subject, the grace must not be earnable inside it.
    gate_case '0
0
3
1'                    1 4 "…and a green that turns pending then fails still stops the round" \
        PR_CI_GRACE=8 PR_CI_TIMEOUT=20
    # A CHANGED PICTURE RESTARTS THE GRACE. Green, then a check appearing as
    # pending, then green again is not two seconds of stable green — it is a new
    # answer, and the run that made it pending is the one nobody has seen finish.
    # Without the reset the second green inherits the first one's age and closes
    # immediately, which is the incomplete-picture close this grace exists for.
    # A GRACE OF THREE, not two, and a call floor with slack. `SECONDS` has
    # one-second granularity, so with grace 2 and interval 1 the acceptance sat
    # exactly on a tick: this closed in five polls on one runner and four on
    # another, and CI failed on the count while the behaviour was identical. The
    # assertion is that the interruption COST polls, not that it cost exactly five.
    gate_case '0
3
0'                    0 5 "a verdict interrupted by a change starts its grace again" \
        PR_CI_TIMEOUT=15 PR_CI_GRACE=3
    # THE DEADLINE OUTRANKS A STABLE VERDICT. With the timeout checked at the
    # bottom of the loop, a `PR_CI_TIMEOUT` shorter than `PR_CI_GRACE` closed the
    # round past its own bound — and a bound that a verdict can step over is not a
    # bound. Here the grace can never be earned inside the timeout.
    gate_case '0'         1 1 "a verdict that stabilises after the deadline is refused" \
        PR_CI_TIMEOUT=2 PR_CI_GRACE=60
    # THE SLEEP MAY NOT OUTRUN THE DEADLINE. Sleeping a full interval when less
    # than that remains means the gate cannot report its own bound until after the
    # bound has passed: a one-second timeout with the default thirty-second
    # interval took thirty seconds to say it had run out of one. The watchdog here
    # is shorter than that interval, so an uncapped sleep is killed rather than
    # reporting anything.
    gate_case '3'         1 1 "an interval longer than the timeout does not outrun it" \
        PR_CI_TIMEOUT=1 PR_CI_INTERVAL=30
    # NO PROBE STARTS AFTER THE DEADLINE. Clamping an exhausted budget up to one
    # second bought another request past the bound, and each of those can take its
    # second plus the watchdog's escalation — the clamp turning the timeout into a
    # floor. With a one-second bound and a one-second interval, the second poll
    # would land exactly on the deadline: there must not be one.
    gate_case '3'         1 1 "no probe is started once the deadline has passed" \
        PR_CI_TIMEOUT=1 PR_CI_INTERVAL=1
    probes_after="$(grep -c . "$GATETMP/calls" 2>/dev/null)" || probes_after=0
    # EXACTLY ONE. Two is what the clamp produced — probe, sleep onto the
    # deadline, probe again, and only then notice — so `-le 2` accepted the defect
    # it was written to catch. The bound is checked before the second probe, so
    # there is no second probe.
    [ "${probes_after:-0}" -le 1 ] \
        && pass "…so an expired gate makes no further requests ($probes_after)" \
        || die "the gate kept probing past its deadline ($probes_after requests)"
    # …AND NEITHER DOES A PROBE. The helper bounds its own `gh` calls, but at its
    # own default — so with a one-second gate timeout a hung request ran for a
    # minute before this loop could look at the clock. A bound the callee does not
    # know about is not a bound. The stub here reads what it was given and reports
    # it, so the assertion is on the value passed down rather than on a duration.
    # A FLOOR OF ONE, because this case exists for the probe-budget assertion below
    # it, and with grace 1 and interval 1 the acceptance sits on a `SECONDS` tick:
    # two polls or one, depending on the machine. What it must show is that a green
    # closes; how many polls that took is the other cases' business.
    gate_case '0
0'                    0 1 "the gate still closes on a stable green" PR_CI_GRACE=1
    first="$(head -1 "$GATETMP/probe" 2>/dev/null)" || first=""
    { [ -n "$first" ] && [ "$first" != unset ] && [ "$first" -le 5 ]; } \
        && pass "…and each probe was bounded by the gate's remaining time (${first}s of 5)" \
        || die "the probe bound was '$first', not capped at the 5s the gate had left"
    gate_case '1'     1 1 "a red head stops the round"
    gate_case '2'     1 1 "an unreadable check state stops the round"
    # THE ONE THE GREP COULD NOT SEE: pending must be waited on, not accepted.
    # A LONGER BOUND FOR THE CASES THAT MUST REACH ACCEPTANCE. Five seconds left
    # these one second clear of the deadline, so a probe taking any measurable
    # time pushed them over and they failed as timeouts — a fixture that passes on
    # a fast machine and reports a defect on a slow one is testing the machine.
    gate_case '3
3
0'                    0 3 "a pending result is waited on, never read as a pass" PR_CI_TIMEOUT=10
    # …and the wait is bounded, because a wait that never ends is a hang. The queue
    # runs out and the stub then answers 3 forever.
    gate_case '3'         1 2 "…and stops once the checks have not settled in time"
    # A HEAD THE API HAS NOT CAUGHT UP WITH IS NOT AN ANSWER. `gh pr checks` is
    # addressed by PR number and can serve the previous head for a moment after a
    # push; the helper reports 5 for it and the gate waits, because the correct
    # response to "ask again shortly" is not to stop and is certainly not to close.
    gate_case '5
5
0'                    0 3 "a head the API has not caught up with is waited on" PR_CI_TIMEOUT=10
    # NO CHECKS *YET* IS NOT NO CHECKS. A workflow run is registered a moment after
    # the head moves, so the first probe after a push legitimately reports `none` on
    # a repository that does have CI. Taking that as permission to close reproduces
    # the red-head closure with an extra step.
    # A GRACE LONGER THAN THE QUEUE. With grace 2 and interval 1 the two `none`s
    # could earn it before the queued failure was ever reached — the case closed
    # the round and CI went red on a slow runner while the fast one passed. The
    # sequence is what this proves, so the grace is set beyond it and cannot be
    # earned first.
    gate_case '4
4
3
1'                    1 4 "a transient 'none' followed by a real failure still stops the round" \
        PR_CI_GRACE=8 PR_CI_TIMEOUT=20
    # …and a repository that genuinely has no checks is not blocked forever: once
    # `none` has held for the grace period it is believed.
    # A floor of one: how many polls a stable `none` takes is the boundary case
    # above, and pinning it here is the same clock-tick assertion twice.
    gate_case '4'         0 1 "a repository with no checks has nothing to assert, once that is stable"
    # THE BOUNDS ARE VALIDATED, so a bad value cannot turn a bounded gate into an
    # unbounded polling loop. `PR_CI_INTERVAL=0` sleeps zero seconds and leaves the
    # elapsed count at zero forever; a non-numeric timeout makes the `-ge`
    # comparison fail on every iteration. Both fall back to the default, which the
    # watchdog would otherwise have to kill — so `rc=124` here is a failure.
    # A BAD BOUND MUST NOT BECOME AN UNBOUNDED POLLING LOOP. `PR_CI_INTERVAL=0`
    # sleeps zero seconds and leaves the elapsed count at zero forever; a
    # non-numeric `PR_CI_TIMEOUT` makes the `-ge` comparison fail on every
    # iteration. Both fall back to the defaults, and what that is observable as is
    # PACING: with the fallback interval the gate manages a couple of polls in the
    # window below, and without it, hundreds. The exit status cannot be the
    # assertion — falling back to a thirty-minute timeout is the CORRECT
    # behaviour, so the watchdog stopping the run is expected, not a failure.
    gate_spin() {   # gate_spin <max calls> <label> [env…]
        local out rc=0 calls maxc="$1" label="$2"
        shift 2
        printf '3\n' > "$GATETMP/q"; : > "$GATETMP/calls"; : > "$GATETMP/last"
        : > "$GATETMP/probe"
        out="$(run_limited 12 env GATE_Q="$GATETMP/q" GATE_CALLS="$GATETMP/calls" \
            GATE_LAST="$GATETMP/last" GATE_PROBE="$GATETMP/probe" RB_SCRIPTS="$GATETMP/s" "$@" \
            bash -c "$gate_fn"'
                ci_gate 7 0123456789abcdef0123456789abcdef01234567' 2>&1)" || rc=$?
        calls="$(grep -c call "$GATETMP/calls" 2>/dev/null)" || calls=0
        [ "${calls:-0}" -le "$maxc" ] \
            && pass "$label" \
            || die "$label — $calls polls in 12s (at most $maxc); the bound was not applied"
    }
    gate_spin 4 "a zero interval falls back rather than spinning against the API" PR_CI_INTERVAL=0
    gate_spin 4 "…and so does a non-numeric interval" PR_CI_INTERVAL=soon
    gate_spin 4 "…and a non-numeric timeout does not remove the pacing" PR_CI_TIMEOUT=soon
    # THE TIMEOUT IS A DURATION, NOT A SUM OF SLEEPS. Counting only the sleeps
    # excluded the probe time, so two slow `gh` calls per iteration turned a
    # documented thirty-minute bound into ninety. With a 3s probe and a 1s
    # interval, a 4s bound is reached on the second poll; counting sleeps alone it
    # would take five.
    gate_case '3'         1 1 "the timeout counts the probe's own time, not just the sleeps" \
        PR_CI_TIMEOUT=4 GATE_DELAY=3
    gate_slow_calls="$(grep -c call "$GATETMP/calls" 2>/dev/null)" || gate_slow_calls=0
    [ "${gate_slow_calls:-0}" -le 3 ] \
        && pass "…so a slow probe cannot stretch the bound ($gate_slow_calls polls)" \
        || die "a slow probe stretched the timeout: $gate_slow_calls polls for a 4s bound"
    rm -rf "$GATETMP"
fi

# ── the loop is PHASED: Codex to clean, then Copilot ───────────────────────
# Asking both every round buys a Copilot pass on every intermediate commit and
# mixes its findings into a round that was not about them.
grep -q 'Request the review — Codex first' "$SKILL" \
    && pass "the request step asks Codex first" \
    || die "the request step does not establish the Codex-first phase"
grep -qi 'do \*\*not\*\* request copilot yet' "$SKILL" \
    && pass "Copilot is explicitly deferred out of the Codex phase" \
    || die "nothing stops the driver requesting Copilot in the Codex phase"
grep -q 'Codex is clean — now the Copilot phase' "$SKILL" \
    && pass "there is a distinct Copilot phase, entered on a clean Codex verdict" \
    || die "no Copilot phase — the loop cannot be Codex-first without one"
grep -qi 'Re-request \*\*only the active reviewer\*\*' "$SKILL" \
    && pass "the close-round step re-requests only the active reviewer" \
    || die "the close-round step may re-request both reviewers"
grep -qi 'Codex is not re-requested during this phase' "$SKILL" \
    && pass "Codex is not re-run during the Copilot phase" \
    || die "the Copilot phase does not say Codex stays out of it"
# The round counter must be per-reviewer, or a shared count trips a pause neither
# phase reached.
grep -q 'pr-round-count.sh N "\$WHO"' "$SKILL" \
    && pass "rounds are counted for the ACTIVE reviewer" \
    || die "the round count is not scoped to the active reviewer"
# `$WHO` must be a variable throughout, so the Copilot phase gets the same
# treatment rather than leaving a hole for whichever login was hard-coded.
grep -q 'WHO="\$CODEX_BOT"' "$SKILL" && grep -q 'WHO="\$COPILOT_BOT"' "$SKILL" \
    && pass "the active reviewer is a variable, set per phase" \
    || die "the active reviewer is not parameterised across phases"
# The findings read is a SCRIPT, not a snippet. Three rounds of fail-open bugs
# lived in the inline version because no test executed it.
# The verdict must arrive by itself. v2 removed v1's response monitor along with
# the bus; without a replacement the driver hand-polls, which is what the operator
# noticed.
grep -q 'pr-watch.sh' "$SKILL" \
    && pass "the wait is delegated to pr-watch.sh, not hand-polled" \
    || die "nothing surfaces a finished review — the driver would poll by hand"
grep -qi 'Monitor' "$SKILL" \
    && pass "Claude Code is told to run the watch as a Monitor" \
    || die "the skill does not say how to surface the verdict automatically"
grep -q 'WATCH_RC' "$SKILL" \
    && pass "the driver branches on the watch's status" \
    || die "the watch's exit status is not acted on"

grep -q 'pr-findings.sh list' "$SKILL" \
    && pass "the findings read is delegated to a tested script" \
    || die "the findings read is inline again — no test can execute it"
grep -q 'pr-findings.sh blocked-body' "$SKILL" \
    && pass "the blocked-review body is delegated to the same script" \
    || die "the blocked-body fetch is inline again"
grep -q 'FIND_RC=\$?' "$SKILL" \
    && pass "the driver captures the findings read's status" \
    || die "the findings read's status is not captured"
# The blocked-body read needs the same contract: it is the ONLY path that can
# surface a body-only request, so an unreadable one must not read as "no body".
# The ASSIGNMENT, not the prose: the paragraph below the command also names
# BODY_RC, so a bare grep for the word passes even when the status is not
# captured at all.
grep -q 'BODY_RC=\$?' "$SKILL" \
    && pass "the driver captures the blocked-body read's status" \
    || die "the blocked-body read's status is not captured"

# The round boundary must be checked BEFORE the re-request, or the next review is
# already sent by the time the operator is asked.
# Matched on the ordering STATEMENT rather than on the two commands' line
# numbers: the checklist item wraps, so a line-order test silently never matched
# and reported failure regardless of the text.
{ grep -q 'check the round boundary' "$SKILL" && grep -q 'only then' "$SKILL"; } \
    && pass "the close-round checklist checks the boundary before re-requesting" \
    || die "the checklist does not order the boundary check before the re-request"
grep -qi 'push itself' "$SKILL" \
    && pass "and says why the order matters (auto-review acts on the push)" \
    || die "the ordering is stated without its reason"

# The README is the first thing a user reads, so v1's architecture must not
# survive in it: someone told about a "file-based bus" goes looking for daemons
# and bus state that this release deletes.
if [ -f "$ROOT/README.md" ]; then
    # Blockquotes are excluded: the "Upgrading from 1.x" note legitimately
    # describes what v1 WAS, and a blunt grep would forbid explaining the thing
    # this release removes.
    readme_now="$(grep -v '^[[:space:]]*>' "$ROOT/README.md")"
    for gone in 'file-based bus' 'systemd --user' 'response monitor'; do
        printf '%s' "$readme_now" | grep -qi -- "$gone" \
            && die "README still presents removed v1 machinery as current: $gone" \
            || pass "README does not present removed machinery as current ($gone)"
    done
fi

# The README carries the same flow for users who never open SKILL.md, so the
# ordering has to hold there too — it did not, one round after the skill was
# fixed.
README="$ROOT/README.md"
if [ -f "$README" ]; then
    # Matched on fragments that survive the line wrap: "check the round" and
    # "boundary" sit on different lines, and a phrase-spanning regex silently
    # never matches — which is how a line-order assertion reports failure
    # regardless of the text.
    readme_order=$(awk '/check the round/{if(!b)b=NR} /push and post/{if(!p)p=NR} END{print (b && p && b<p) ? "ok" : "bad"}' "$README")
    [ "$readme_order" = "ok" ] \
        && pass "README checks the round boundary before the push" \
        || die "README still tells users to push before the boundary check"
    # …and it must carry BOTH orderings, since the push is the trigger with
    # automatic review on. One round after the skill was fixed the README still
    # described only the auto-review-off flow.
    grep -q 'With automatic review on' "$README" \
        && pass "README describes the auto-review ordering too" \
        || die "README documents only one review mode; the other starts a pass with no summary"
else
    pass "README not present; flow-order check skipped"
fi

# A failed Copilot request must not start the phase: --add-reviewer IS the
# request, so a failure means there is no pass to wait for.
grep -q 'if ! gh pr edit N --repo $HOST/$OWNER/$REPO --add-reviewer @copilot; then' "$SKILL" \
    && pass "the Copilot request is branched on before the phase begins" \
    || die "a failed Copilot request still enters the Copilot phase"
# The @codex comment IS the request, so the same rule applies to it.
grep -q 'if ! gh pr comment N --repo $HOST/$OWNER/$REPO --body "@codex review' "$SKILL" \
    && pass "the Codex request is branched on before the wait begins" \
    || die "a failed @codex request still enters the wait step"

# The merge gate validates the verdict RECORDS, not only the exit codes: this is
# the final permission, so an rc-swallowing wrapper must not read as clean.
grep -q 'V_WANT="PR_REVIEW_STATE pr=N sha=' "$SKILL" \
    && pass "the merge gate requires an exact clean verdict record from both reviewers" \
    || die "the merge gate trusts the exit codes without checking the records"
# …and each record must name ITS OWN reviewer and the sha that reviewer judged.
# Wildcarding pr/sha/reviewer let one clean line satisfy the check for either
# variable, so a clean Copilot record — or a clean record for a stale sha —
# passed as Codex's signoff.
grep -q 'reviewer=\$V_WHO verdict=clean findings=0"' "$SKILL" \
    && pass "each clean record is bound to the reviewer it is meant to prove" \
    || die "the merge gate accepts a clean record from any reviewer"
grep -q '"\$CODEX_BOT|\$CODEX_EFFECTIVE_SHA|\$CODEX_VERDICT"' "$SKILL" \
    && pass "…on the sha that reviewer actually judged" \
    || die "the clean records are not bound to the sha each reviewer judged"
# A literal comparison, not `[[ == ]]`: the bot logins end in `[bot]`, which a
# pattern context reads as a character class.
grep -q '\[ "\$V_LINE" != "\$V_WANT" \]' "$SKILL" \
    && pass "the verdict records are compared literally, not as patterns" \
    || die "the verdict comparison would read [bot] as a character class"

# ── the round summary and the review request are ONE comment ───────────────
# The mention IS the request, so splitting them divides the record the reviewer
# is told to read and sends the request half with no account of what changed.
# The assertion is on the REQUEST BODY, not on the file appearing somewhere in the
# document. Matching `SUMMARY_FILE` anywhere passed while the round-closing
# request interpolated nothing: the file was still created and read, and Codex
# received a bare mention with no account of what changed — which the review
# policy makes it read first. The definition and the use are separate things, and
# only the use reaches the reviewer.
#
# The FIRST request is exempt and identified by its placeholder: it opens the PR,
# so there is no prior round to summarise. Every other one closes a round.
summary_req="$(awk '
    /--body "@codex review/ { want = 3; body = ""; next }
    want > 0 { body = body $0 "\n"; want--
               if (want == 0) {
                   if (body ~ /<one paragraph:/) { opening++ }
                   else if (body ~ /\$SUMMARY/) { withsum++ }
                   else { bare++ }
               }
             }
    END { printf "opening=%d withsum=%d bare=%d", opening, withsum, bare }
' "$SKILL")"; sreq_rc=$?
[ "$sreq_rc" -eq 0 ] || die "could not scan SKILL.md for the review requests (rc=$sreq_rc)"
case "$summary_req" in
    *"bare=0"*) pass "every round-closing @codex request carries \$SUMMARY in its body" ;;
    *) die "a round-closing @codex request has no summary in its body ($summary_req)" ;;
esac
case "$summary_req" in
    *"withsum=0"*) die "no @codex request interpolates the summary at all ($summary_req)" ;;
    *) pass "…and the summary reaches the reviewer in the same comment as the mention" ;;
esac

# A mention describing an UNFIXED defect is read as a task, not as context: Codex
# then edits and commits in an environment with no remote and no credentials, so
# the commit exists nowhere and the review never happens. This cost a whole round
# once already.
grep -qi 'never as a work order' "$SKILL" \
    && pass "the skill warns that an open defect in a mention is read as a task" \
    || die "nothing stops a round summary restating an unfixed defect to the reviewer"

# Resolving is checked, not assumed: a round reported as fully resolved when it
# was not sends the next review back over findings that were already answered.
#
# Matched on the rule's own words, not on `isResolved` — that token also appears
# in the merge gate's GraphQL query further down the file, so a grep for it
# passed against a SKILL.md with the rule deleted.
#
# A FRAGMENT that fits on one line, not the whole phrase: this file is wrapped,
# `grep` is line-oriented, and an assertion spanning a line break silently never
# matches. That has now happened three times in this suite.
grep -qi 'resolve succeeded' "$SKILL" \
    && pass "the skill says to verify each resolve succeeded" \
    || die "thread resolution is assumed rather than verified"

# The watch is armed as part of the round, not put to the operator as a question.
grep -qi 'do not ask' "$SKILL" \
    && pass "the watch is armed and re-armed without asking the operator" \
    || die "the skill leaves arming the watch as a question for the operator"

# ── the merge mode is a setting, not a hard-coded bypass ───────────────────
# `--admin` stays the default because branch protection normally requires an
# approving review from another account, and neither reviewer is one — dropping
# it would remove the solo maintainer's merge path rather than tighten the gate.
# But it must be reachable: strict mode is what closes the window between the
# last probe and the merge, where a review can change without the head moving.
grep -q 'REVIEW_MERGE_STRICT' "$SKILL" \
    && pass "the merge mode is selectable, not a hard-coded --admin" \
    || die "--admin is unconditional; there is no way to let GitHub enforce protection"
grep -q 'ADMIN=--admin' "$SKILL" \
    && pass "…defaulting to --admin so a protected solo repo can still merge" \
    || die "the default merge mode is not --admin"
grep -q 'merge N --repo \$HOST/\$OWNER/\$REPO --squash --delete-branch \$ADMIN' "$SKILL" \
    && pass "…and the merge command uses the selected mode" \
    || die "the merge command does not use \$ADMIN"

# ── pagination must terminate ──────────────────────────────────────────────
# A page reporting hasNextPage=true with a cursor already used makes the gate
# walk that cycle forever. A hang is worse than a blocked merge: nothing times
# out and the operator waits on a gate that never answers.
#
# EVERY cursor, not just the previous one: comparing against the last cursor
# caught an immediate self-loop but not `null → A → B → A → B …`.
grep -q 'SEEN="\$SEEN\$NEXT\$RS"' "$SKILL" \
    && pass "the merge gate records every pagination cursor it has requested" \
    || die "a cursor cycle would loop the merge gate forever"
grep -q 'case "\$SEEN" in \*"\$RS\$NEXT\$RS"\*) OK=0; break ;; esac' "$SKILL" \
    && pass "…and stops when one repeats" \
    || die "the merge gate does not check the cursor against the ones it has used"

# ── the Copilot summary is posted BEFORE the request ───────────────────────
# In the Codex phase the mention carries the summary, so the order is settled by
# construction. Here it is not: --add-reviewer is a separate call and Copilot can
# start reading within seconds, so requesting first means a fast pass reviews
# against the PREVIOUS round's summary.
awk '/gh pr comment N --repo \$HOST\/\$OWNER\/\$REPO --body "\$SUMMARY"/ {c=NR}
     /--add-reviewer @copilot/ {if (c && c < NR) {print "ok"; exit}}' "$SKILL" | grep -q ok \
    && pass "the Copilot round summary is posted before the review request" \
    || die "Copilot can be requested before the round summary exists"
grep -q 'ABORT: could not post the round summary — do not request Copilot yet' "$SKILL" \
    && pass "…and a failed summary post stops the phase" \
    || die "a failed Copilot-phase summary post does not stop the request"

# ── the self-check runs BEFORE the push ────────────────────────────────────
# Rounds are the expensive part of the loop, so a finding a script can make in a
# second must not cost a whole review pass.
grep -q 'pr-selfcheck.sh' "$SKILL" \
    && pass "the contract runs the self-check" \
    || die "nothing runs pr-selfcheck.sh before a round is pushed"
# The ORDER IN THE NUMBERED PROCEDURE, not merely the order of the two lines in
# the file. The previous version matched a self-check line appearing anywhere
# before any later `git push` code block, which stayed true while the checklist
# told the driver to push in step 2 and self-check in step 3 — so a driver
# following the sequence pushed before running the check meant to prevent it.
self_step="$(grep -nE '^[0-9]+\. \*\*run the self-check' "$SKILL" | head -1 | cut -d: -f1)"
push_step="$(grep -nE '^[0-9]+\. \*\*check the round boundary' "$SKILL" | head -1 | cut -d: -f1)"
{ [ -n "$self_step" ] && [ -n "$push_step" ] && [ "$self_step" -lt "$push_step" ]; } \
    && pass "…and the numbered procedure runs it before the step that pushes" \
    || die "the checklist pushes before the self-check that is meant to prevent it"
grep -q 'SELF_RC' "$SKILL" \
    && pass "…and its exit status is branched on" \
    || die "the self-check output is not checked"

# ── the first request respects the review mode too ─────────────────────────
# With auto-review on, opening or pushing the PR has already queued a pass, so an
# unconditional mention queues a SECOND review of the same head.
sel="$(grep -n 'AUTO_REVIEW=no' "$SKILL" | head -1 | cut -d: -f1)"
req="$(grep -n 'Request the review — Codex first' "$SKILL" | head -1 | cut -d: -f1)"
{ [ -n "$sel" ] && [ -n "$req" ] && [ "$sel" -gt "$req" ]; } \
    && pass "the review mode is established in the request step, before the mention" \
    || die "the first @codex mention is posted before the review mode is known"
grep -q 'if \[ "\$AUTO_REVIEW" = "yes" \]; then' "$SKILL" \
    && pass "…and the initial request branches on it" \
    || die "the initial request does not branch on the review mode"

# ── the numbered checklist does not push ──────────────────────────────────
# The push belongs to the mode-specific recipe: with auto-review on it must come
# after the threads are resolved and the summary posted, or the pass it triggers
# reads the previous round's account against threads that are still open.
grep -qE '^3\. \*\*check the round boundary — step 6\.\*\*' "$SKILL" \
    && pass "the boundary step no longer carries the push" \
    || die "the checklist still pushes in the boundary step"
grep -q 'The push is not' "$SKILL" \
    && pass "…and says where the push actually belongs" \
    || die "the checklist does not say where the push belongs"

# In the auto-review branch, the push must come BEFORE the summary post — the
# reverse of what it was. Nothing irreversible may precede the checks verdict, and
# the summary post is irreversible.
awk '/^\*\*Automatic review ON\*\*/ {inb=1}
     inb && /^git push/ {p=NR}
     inb && p && /gh pr comment N --repo \$HOST\/\$OWNER\/\$REPO --body "\$SUMMARY"/ {print "ok"; exit}' "$SKILL" \
    | grep -q ok \
    && pass "with auto-review on, the push precedes the summary the checks decide about" \
    || die "the auto-review recipe closes the round before the checks can be read"

# ── the self-check's third outcome is handled ─────────────────────────────
# `not_applicable` shares no exit status with "checks passed": the same code
# would have let the driver report a clean check when none ran.
grep -q 'not applicable\*\*: this repository is not a' "$SKILL" \
    && pass "the contract documents the not-applicable outcome" \
    || die "SKILL.md defines no handling for a run where nothing was in scope"

# ── findings get a reaction ────────────────────────────────────────────────
# Every Codex finding ends with "Useful? React with thumbs", and that reaction is
# the only signal the reviewer gets about whether a review was worth making.
grep -q 'pulls/comments/<comment-id>/reactions' "$SKILL" \
    && pass "the contract reacts to each finding" \
    || die "findings are resolved without the reaction the reviewer asks for"
grep -q 'comment=' "$ROOT/skills/watch-prs/scripts/pr-findings.sh" \
    && pass "…and list prints the comment id the reaction needs" \
    || die "pr-findings.sh does not print a comment id to react to"

# ── the summary is read with its status taken, on every path ──────────────
# `$(cat …)` inside the argument swallows the reader's status, so a partial read
# still produced a successful post — and the reviewer contract makes the newest
# summary the thing read before the diff, so a truncated one looks complete.
[ "$(grep -c 'SUMMARY="$(cat "$SUMMARY_FILE")"' "$SKILL")" -eq 3 ] \
    && pass "all three summary posts read the file with a guarded status" \
    || die "a summary post still interpolates \$(cat …) and swallows its status"
grep -q 'ABORT: could not read the round summary' "$SKILL" \
    && pass "…and a failed read aborts rather than posting a truncated record" \
    || die "a failed summary read does not abort"

# ── a failed push does not close the round ────────────────────────────────
# The fixes are not on the PR, so resolving threads and requesting a review sends
# the reviewer at code that was never sent — and in auto-review mode the watch
# then reads the already-reviewed remote head's verdict as this round's.
[ "$(grep -c '^git push ||' "$SKILL")" -eq 2 ] \
    && pass "both mode-specific pushes are branched on" \
    || die "a round push is unchecked; a failed push still closes the round"
grep -q 'ABORT: push failed' "$SKILL" \
    && pass "…and a failed push aborts the round" \
    || die "a failed push does not abort"

# ── a timeout re-arms; it never re-requests and never asks ────────────────
# Re-requesting queues a duplicate pass on the same head, and asking turns the
# automatic loop back into the manual one it replaces.
grep -q 're-arm the same watch' "$SKILL" \
    && pass "a watch timeout re-arms the same watch" \
    || die "the timeout action is ambiguous; it may re-request or prompt"
grep -q 'timed out | re-request, or ask the operator' "$SKILL" \
    && die "the timeout row still offers re-requesting or prompting" \
    || pass "…and neither re-requests nor prompts"

# ── the helper discovery is checked and its result validated ──────────────
# `ls` can print one candidate and then fail on an unreadable cache entry, and
# `head` masks that status — so an unchecked pipeline selects a partial or stale
# path and every later call runs a different version of the helpers.
grep -q 'ABORT: could not enumerate installed plugin copies' "$SKILL" \
    && pass "the cached-helper discovery branches on its status" \
    || die "the helper discovery pipeline is unchecked"
grep -q 'ABORT: could not locate the plugin helper scripts' "$SKILL" \
    && pass "…and the selected directory is validated before it is used" \
    || die "the discovered helper directory is used without validation"

# ── every gh pr call names the repository ─────────────────────────────────
# `GH_REPO` overrides the repository `gh` infers from the checkout, so an
# unpinned call can act on the same-numbered PR somewhere else while every gate
# inspects this one. Enforced mechanically by pr-selfcheck.sh; asserted here so
# the contract itself cannot drift.
# A COMPARISON, not a magic number: the count changes whenever a call is added,
# and a fixed expectation fails for that reason rather than for an unpinned call.
comment_calls="$(grep -c 'gh pr comment N' "$SKILL")"
comment_pinned="$(grep -c 'gh pr comment N --repo $HOST/$OWNER/$REPO' "$SKILL")"
[ "$comment_calls" -eq "$comment_pinned" ] \
    && pass "every gh pr comment call is pinned to the derived repository" \
    || die "$((comment_calls - comment_pinned)) gh pr comment call(s) do not pass --repo"

# ── the shipping manifest lists every runtime helper ──────────────────────
# CLAUDE.md calls everything unlisted "documentation", so an incomplete table is
# not a cosmetic gap — it tells a maintainer that four executable helpers are
# prose. Derived from the directory, so adding a helper without listing it fails.
CLAUDEMD="$ROOT/CLAUDE.md"
if [ -f "$CLAUDEMD" ]; then
    # Scoped to the What-ships TABLE, not the whole file. Every helper is also
    # named in the strict-mode table further down, so a whole-file grep passed
    # against a manifest with a helper deleted — the same "the token appears
    # elsewhere" trap that made an earlier assertion here vacuous.
    manifest="$(awk '/^## What ships/{inb=1; next} /^## /{inb=0} inb' "$CLAUDEMD")"
    manifest_missing=""
    for h in "$SCRIPT_DIR"/pr-*.sh; do
        [ -e "$h" ] || continue
        b="$(basename "$h")"
        printf '%s' "$manifest" | grep -q "$b" || manifest_missing="$manifest_missing $b"
    done
    [ -z "$manifest_missing" ] \
        && pass "CLAUDE.md's What-ships table lists every runtime helper" \
        || die "runtime helpers missing from the shipping manifest:$manifest_missing"
fi

# ── every git probe takes its status ──────────────────────────────────────
# Third time this class appeared: the origin lookups, then the self-check's root
# lookup, then these two. `|| true` on a probe is the opposite of failing closed.
grep -q 'ABORT: could not resolve the repository root' "$SKILL" \
    && pass "the identity block branches on the repo-root probe" \
    || die "the repo-root probe is unchecked; a failed read becomes the merge tree"
if [ -f "$SCRIPT_DIR/pr-merge-range.sh" ]; then
    grep -q 'rev-parse --show-toplevel 2>/dev/null || true' "$SCRIPT_DIR/pr-merge-range.sh" \
        && die "pr-merge-range.sh still swallows its root probe status with || true" \
        || pass "pr-merge-range.sh does not swallow its root probe status"
fi

# ── the phase summary WRITE is checked, not only the read ─────────────────
# A truncated write leaves a non-empty partial body that the guarded read
# returns; a failed open leaves the previous round's contents to be read as this
# round's. Either posts an invalid summary and requests Copilot against it.
grep -q 'ABORT: could not write the phase summary' "$SKILL" \
    && pass "the Copilot phase summary write is branched on" \
    || die "the phase summary is written without checking the write"

# ── the summary file's creation is checked ────────────────────────────────
# `mktemp` can print a plausible path and then fail, and every later write and
# guarded read would then point at an existing file — a stale summary read back
# as this round's, which is what the guarded read was added to prevent.
grep -q 'ABORT: could not create the round-summary file' "$SKILL" \
    && pass "the summary file's creation is branched on" \
    || die "mktemp is unchecked; a failed create still yields a path"
grep -q 'ABORT: the round-summary file was not created empty' "$SKILL" \
    && pass "…and the created file is validated as new and empty" \
    || die "the summary file is used without validating what was created"

# ── the watch deadline is absolute ────────────────────────────────────────
# Accumulating only the sleeps excluded the time spent inside the probes, so slow
# GitHub reads made a one-hour watch run far past an hour.
if [ -f "$SCRIPT_DIR/pr-watch.sh" ]; then
    grep -q 'elapsed_s()' "$SCRIPT_DIR/pr-watch.sh" \
        && pass "pr-watch.sh measures elapsed time against the clock" \
        || die "pr-watch.sh accumulates sleeps, so probe time escapes --timeout"
    grep -q 'waited=\$((waited + nap))' "$SCRIPT_DIR/pr-watch.sh" \
        && die "pr-watch.sh still accumulates the nap instead of reading the clock" \
        || pass "…rather than accumulating the naps"
fi

# ── the Codex signoff is re-validated on the sha it records ───────────────
# A push between the clean verdict and this lookup recorded the new, unreviewed
# head as the signoff, and the gate only noticed after the whole Copilot phase.
grep -q 'CODEX_RECHECK' "$SKILL" \
    && pass "the recorded Codex sha is re-validated before the Copilot phase" \
    || die "CODEX_SHA is recorded without confirming Codex is clean on it"

# ── every gh call names the host as well as the repository ────────────────
# `GH_HOST` supplies the hostname when a command gives none, so an unpinned call
# can act on the same-numbered PR on another GitHub host.
# THE ASSERTION FOLLOWS THE RULE, not the text that used to state it. This was
# `grep -q 'HOST='` over SKILL.md, which held only while the parser was written
# out there; the parser is `identitylib.sh` now, and a text check left pointing at
# SKILL.md would have gone on passing against a driver that derived nothing at
# all. So: the driver must DELEGATE, and the parser must derive.
grep -q '^rb_identity \\$' "$SKILL" \
    && pass "the driver derives its identity through the shared parser" \
    || die "SKILL.md does not call rb_identity; the identity comes from somewhere else"
grep -q 'HOST=' "$SCRIPT_DIR/identitylib.sh" \
    && pass "…and the parser derives the host from origin" \
    || die "the host is not derived; GH_HOST can redirect every call"
# …and the parser is sourced only after the helper directory is known. Written the
# other way round the `.` reads an unset path, which under this driver's rules is
# an abort — but a driver that aborts at step zero on every repository is a tool
# nobody can run, and it would be found by trying rather than by reading.
awk '/^RB_SCRIPTS=/ {r=NR}
     /^\. "\$RB_SCRIPTS\/identitylib\.sh"/ {if (r && r < NR) {print "ok"; exit}}' "$SKILL" \
    | grep -q ok \
    && pass "…and the helpers are located before the parser is loaded from them" \
    || die "SKILL.md sources identitylib.sh before RB_SCRIPTS is resolved"
# …and any INHERITED definition is cleared before that source. Bash exports
# functions through the environment, so a session that had already defined
# `rb_identity` leaves one here — and an empty or truncated library still sources
# successfully, at which point the `type -t` guard finds the inherited function,
# reports the parser loaded, and every call is addressed by whatever it derives.
awk '/^unset -f rb_identity/ {u=NR}
     /^\. "\$RB_SCRIPTS\/identitylib\.sh"/ {if (u && u < NR) {print "ok"; exit}}' "$SKILL" \
    | grep -q ok \
    && pass "…and a stale parser definition is cleared before the library loads" \
    || die "an inherited rb_identity would satisfy SKILL.md's parser-load check"
# …and the clearing's own status is taken. `readonly -f rb_identity` makes the
# unset FAIL and leaves the function installed, so a discarded status made a
# definition that could not be cleared indistinguishable from one that was never
# there.
#
# ASSERTED AS A COUPLING, NOT AS THE ABSENCE OF ONE SPELLING. The first version
# forbade the literal `|| true` — a blacklist, and a blacklist is always one
# spelling behind: `|| :`, or deleting the handler outright, passed it while the
# defect returned in full. This repository has already replaced a lexical
# blacklist with a whitelist once, for exactly that reason. So the requirement is
# positive: the unset must be joined to a branch that EXITS. Continuations are
# flattened first, because the branch is on the next line.
#
# AND IT IS RUN, not matched. A regex requiring the token `exit 1` accepts
# `|| echo "exit 1"` — the exit inside quoted data, the handler printing a word and
# the driver carrying on with the stale parser. That is the whitelist repeating the
# blacklist's mistake at one remove: recognising the SPELLING of the guarantee
# instead of the guarantee. So the setup block is extracted from SKILL.md and
# EXECUTED against the state it is supposed to refuse — a readonly `rb_identity`
# that cannot be cleared, and an `identitylib.sh` that is empty.
#
# The block is run in a throwaway git checkout with `CLAUDE_PLUGIN_ROOT` pointed at
# a scripts directory holding an empty parser and an executable `pr-review-state.sh`
# — the two things its own validation looks for — so everything before the parser
# load succeeds and the refusal under test is the only thing that can stop it.
setup_block="$(awk '/^## Derive identity$/ {sec=1}
                    sec && /^```bash$/ {inb=1; next}
                    inb && /^```$/ {exit}
                    inb' "$SKILL")"
[ -n "$setup_block" ] || die "the Derive identity block could not be extracted"
SETUPTMP="$(mktemp_d)" || { die "no scratch directory for the setup probe"; SETUPTMP=""; }
if [ -n "$SETUPTMP" ] && [ -n "$setup_block" ]; then
    mkdir -p "$SETUPTMP/repo" "$SETUPTMP/plugin/skills/watch-prs/scripts"
    : > "$SETUPTMP/plugin/skills/watch-prs/scripts/identitylib.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' \
        > "$SETUPTMP/plugin/skills/watch-prs/scripts/pr-review-state.sh"
    chmod +x "$SETUPTMP/plugin/skills/watch-prs/scripts/pr-review-state.sh"
    ( cd "$SETUPTMP/repo" && git init -q && git remote add origin git@github.com:acme/widget.git ) \
        >/dev/null 2>&1 || die "the setup probe's checkout could not be created"
    # A readonly definition, in the SAME shell the block runs in — which is the
    # driver's situation, and the only place the case is reachable. `readonly -f`
    # does not survive a process boundary.
    # The status is captured at the point it is produced. This file runs under
    # `-e`, and the probe is EXPECTED to fail — that is the assertion — so an
    # unguarded assignment terminates the suite here instead of asserting anything.
    setup_rc=0
    # EVERY function the setup block defines for itself, not just the parser. A
    # stale `ci_gate` that returns 0 lets a red head close its round — the defect
    # the gate exists to prevent, arriving through the gate itself — and it is
    # reachable in exactly the persistent-shell state the parser is cleared for.
    # EACH CASE GETS THE LIBRARY IT NEEDS, AND MUST ABORT FOR ITS OWN REASON.
    #
    # Written with one shared empty `identitylib.sh`, the `ci_gate` case passed
    # while proving nothing: the block aborted at the empty parser, long before it
    # reached the gate, and "the driver stopped" was true for a reason that had
    # nothing to do with what was being tested. So the parser case gets an empty
    # library and the gate case gets the real one — and the expected abort message
    # is asserted, so a stop for some other reason cannot be mistaken for this one
    # again.
    for stale_case in 'rb_identity:empty:could not be cleared' \
                      'ci_gate:real:a pre-existing ci_gate could not be cleared'; do
        stale_fn="${stale_case%%:*}"; stale_rest="${stale_case#*:}"
        stale_lib="${stale_rest%%:*}"; stale_msg="${stale_rest#*:}"
        if [ "$stale_lib" = empty ]; then
            : > "$SETUPTMP/plugin/skills/watch-prs/scripts/identitylib.sh"
        else
            cat "$SCRIPT_DIR/identitylib.sh" \
                > "$SETUPTMP/plugin/skills/watch-prs/scripts/identitylib.sh"
        fi
        setup_rc=0
        setup_out="$(cd "$SETUPTMP/repo" && run_limited 60 env CLAUDE_PLUGIN_ROOT="$SETUPTMP/plugin" \
            bash -c 'eval "$1() { HOST=github.com; OWNER=someone-else; REPO=other-repo; }"
                     readonly -f "$1"
                     eval "$2"
                     echo "CONTINUED:$OWNER"' _ "$stale_fn" "$setup_block" 2>&1)" || setup_rc=$?
        case "$setup_out" in
            *CONTINUED*) die "the driver continued past a $stale_fn it could not clear ($setup_out)" ;;
            *) pass "…and a $stale_fn that cannot be cleared stops the driver" ;;
        esac
        grep -qF "$stale_msg" <<<"$setup_out" \
            && pass "…stopping for that reason and not another" \
            || die "$stale_fn stopped the driver, but not as '$stale_msg' (out='$setup_out')"
        [ "$setup_rc" -ne 0 ] \
            && pass "…reporting a failure rather than an abort message alone" \
            || die "the setup block refused $stale_fn but exited 0 (out='$setup_out')"
    done
    rm -rf "$SETUPTMP"
fi
grep -q 'gh api --hostname "\$HOST" graphql' "$SKILL" \
    && pass "…and the GraphQL calls pass it explicitly" \
    || die "a graphql call does not pass --hostname"

# ── the accepted merge-mode limitation is recorded on the base ref ────────
# AGENTS.md makes a dated decision record the only thing that can accept a
# limitation; a comment in the diff cannot.
if [ -d "$ROOT/docs/decisions" ]; then
    grep -rql 'REVIEW_MERGE_STRICT' "$ROOT/docs/decisions" >/dev/null 2>&1 \
        && pass "the merge-mode trade-off has a decision record" \
        || die "the --admin default is accepted nowhere a reviewer can weigh it"
else
    die "docs/decisions/ is missing; accepted limitations have nowhere to live"
fi

# ── the re-request id is captured and passed, not merely available ────────
# A flag nothing invokes is inert: `--after-review` shipped and the driver never
# called `review-id` nor passed the option, so a same-head re-request still
# accepted the previous terminal review immediately.
grep -q 'pr-watch.sh N "$WHO" --after-review "$PRIOR_REVIEW"' "$SKILL" \
    && pass "the watch is invoked with the pre-request review id" \
    || die "--after-review is documented but never passed"
[ "$(grep -c 'PRIOR_REVIEW=\$("\$RB_SCRIPTS"/pr-review-state.sh review-id' "$SKILL")" -ge 3 ] \
    && pass "…and the id is captured before each request that a watch follows" \
    || die "the pre-request review id is not captured before every request"

# ── "no required checks" is not "could not tell" ──────────────────────────
# `gh pr checks --required` exits NON-ZERO when the branch has no required checks
# at all. Treating every non-zero status as unreadable blocked the merge on every
# repository without branch protection, permanently — a gate that never opens,
# not a fail-closed guard. Found by trying to merge, not by reading the code.
grep -q 'no required checks' "$SKILL" \
    && pass "the gate distinguishes 'none configured' from a failed probe" \
    || die "a repo with no required checks can never pass the merge gate"
grep -q 'the required-checks probe failed' "$SKILL" \
    && pass "…and a genuinely failed probe still blocks" \
    || die "the checks probe no longer blocks on a real failure"
grep -q 'ERRF' "$SCRIPT_DIR/pr-ci-state.sh" \
    && pass "…using stderr, so the message does not pollute the compared value" \
    || die "the checks probe does not capture stderr separately"

# ── a clean pass arrives as a comment, not a review ───────────────────────
# Codex submits a review only when it has findings, so `pulls/N/reviews` is empty
# on a clean head and the phase could never complete.
if [ -f "$SCRIPT_DIR/pr-review-state.sh" ]; then
    grep -q 'clean_comment_for_head' "$SCRIPT_DIR/pr-review-state.sh" \
        && pass "pr-review-state.sh reads the clean-pass comment channel" \
        || die "a clean Codex pass is invisible; the phase cannot complete"
    grep -q 'Reviewed commit:' "$SCRIPT_DIR/pr-review-state.sh" \
        && pass "…bound to the head the comment names" \
        || die "the clean comment is not bound to a commit"
fi

# ── the boundary gates the phase transitions, not only the re-request ─────
# A phase ending on the threshold-th head went from a clean verdict straight into
# the next phase — skipping the pause in exactly the case it exists for.
[ "$(grep -c 'pr-round-count.sh N' "$SKILL")" -ge 3 ] \
    && pass "the round boundary is checked before the phase transition and the merge" \
    || die "a clean verdict on the boundary skips the operator pause"
grep -q 'before opening the Copilot phase' "$SKILL" \
    && pass "…including before the Copilot phase" \
    || die "the Copilot transition does not check the boundary"
grep -q 'before merging' "$SKILL" \
    && pass "…and before merging" \
    || die "the merge does not check the boundary"

# ── EVERY documented watch invocation carries the baseline ────────────────
# The shell example passed --after-review while the Monitor command beside it did
# not, leaving the feature inert in the mode Claude Code is told to use.
# The baseline is a VARIABLE now, not one name: the automatic path waits out the
# pass its own push started, and that wait's baseline is the id from before the
# push rather than the one for the request that follows. What must never happen is
# a watch with no baseline at all.
watch_calls="$(grep -c 'pr-watch.sh N "\$WHO"' "$SKILL")"
watch_pinned="$(grep -cE 'pr-watch.sh N "\$WHO" --after-review "\$[A-Z_]+"' "$SKILL")"
[ "$watch_calls" -eq "$watch_pinned" ] \
    && pass "every documented watch invocation passes a review baseline" \
    || die "$((watch_calls - watch_pinned)) watch invocation(s) omit --after-review"
# …and the one that waits out the push-triggered pass uses the PRE-PUSH id, not
# the one taken for the request that follows it. Using the same variable for both
# is the race with an extra step: the wait would be satisfied by whatever the
# request is about to ask for.
grep -q 'pr-watch.sh N "\$WHO" --after-review "\$PUSH_BASE"' "$SKILL" \
    && pass "…and the push-triggered pass is waited out against the id from before it" \
    || die "the push-triggered pass is not serialised before the next baseline is taken"
# …GUARDED BY WHETHER A PASS WAS ACTUALLY STARTED, and by that comparison rather
# than by a constant. `if false` around it satisfies a grep for the wait itself,
# and a no-op push starts nothing, so waiting unconditionally is a guaranteed
# timeout — the condition is the whole of it.
grep -q '\[ "\$PUSH_FROM" != "\$HEAD_AFTER" \]' "$SKILL" \
    && pass "…only when the push actually moved the head" \
    || die "the serialising wait is unconditional, or its condition was replaced"
# …AND ONLY IN THE CODEX PHASE. A push never triggers Copilot, so there is no pass
# to wait for there — and waiting anyway meant every Copilot round that moved the
# head sat until the watch timed out and exited BEFORE `--add-reviewer` was ever
# reached. The phase where automatic review does nothing is the phase where
# serialising it stalls everything.
grep -q '^if \[ "\$WHO" != "\$COPILOT_BOT" \] && \[ "\$PUSH_FROM" != "\$HEAD_AFTER" \]; then$' "$SKILL" \
    && pass "…and never in the Copilot phase, which no push triggers" \
    || die "a Copilot round that moved the head waits for a pass nothing started"
# …AND NEITHER IS ITS INPUT READ THERE. Guarding only the wait left the baseline
# lookup running on every Copilot round, where a transient failure aborts before
# the push AND before `--add-reviewer` — the same stall, moved one line up. A
# guard that stops the consumer and not the producer relocates the failure.
awk '/^PUSH_BASE=""$/ {z=NR}
     z && /^if \[ "\$WHO" != "\$COPILOT_BOT" \]; then$/ {w=NR}
     w && /pr-review-state.sh review-id N "\$WHO"/ {print "ok"; exit}' "$SKILL" | grep -q ok \
    && pass "…and the baseline it needs is only read in that phase too" \
    || die "the pre-push review-id lookup runs on Copilot rounds that never use it"
# ── the operator instructions match the workflow ──────────────────────────
# README told operators that with automatic review on the summary must precede the
# push and that no mention may be sent, which is the opposite of what the driver
# does now. A settings page is the one place a user decides this, and a
# contradiction there is not a stale note — it is instructions that cannot be
# followed. `SKILL.md` and README are separate files with no mechanism keeping
# them in step, which is what this assertion is.
if [ -f "$ROOT/README.md" ]; then
    grep -q 'no mention may be sent' "$ROOT/README.md" \
        && die "README still says automatic mode sends no mention; the driver always does" \
        || pass "README does not contradict the automatic-mode ordering"
    grep -q 'two Codex passes' "$ROOT/README.md" \
        && pass "…and says what automatic review actually costs" \
        || die "README does not tell the operator that automatic mode costs a second pass"
fi
# …and a wait that TIMED OUT is not permission to continue. Taking a baseline
# while that pass is still in flight is the race this block removes, with an extra
# step: the pass lands a moment later and answers the wrong request.
grep -q 'the pass the push started has not finished' "$SKILL" \
    && pass "…and a pass that has not finished stops the round" \
    || die "a timed-out wait for the push-triggered pass is treated as done"

# ── the automatic path has no pre-request baseline ────────────────────────
# The trigger preceded the skill, so a lookup can capture the very pass being
# waited for — and the watch would reject the only terminal review as stale.
grep -q 'PRIOR_REVIEW=""' "$SKILL" \
    && pass "the automatic-review path waits on any terminal review" \
    || die "the automatic path captures the in-flight pass as its own baseline"

# ── the checks diagnostic is read with its status ─────────────────────────
# A `cat` that emitted text containing "no required checks" and then failed would
# be classified as the benign none-configured case, letting the default admin
# merge proceed with no trusted checks result at all.
grep -q 'MSG_RC' "$SCRIPT_DIR/pr-ci-state.sh" \
    && pass "the checks diagnostic read takes its own status" \
    || die "a failed diagnostic read can be classified as 'no required checks'"
grep -q 'reason=diagnostic_unreadable' "$SCRIPT_DIR/pr-ci-state.sh" \
    && pass "…and reports an error rather than a verdict" \
    || die "a failed diagnostic read does not block"

# ── automatic mode asks EXPLICITLY, whatever the push did ─────────────────
# A round that ends without a new commit — a dismissal, or a finding answered
# rather than coded around — leaves the push a no-op, so nothing is queued and
# `--after-review` rejects the old record forever. That used to be handled by
# comparing three heads and asking only when they matched, which is a condition
# that can be got wrong; and it became insufficient anyway once the push moved
# ahead of the summary, because the pass a moving push starts now reads open
# threads and no summary. An unconditional ask covers both, and there is no
# condition left to invert.
#
# The CONDITION is what is asserted, not the presence of a mention: a mention
# inside a branch is not an unconditional ask, and the branch is exactly what was
# removed.
awk '/^\*\*Automatic review ON\*\*/ {inb=1}
     inb && /^if \[ "\$WHO" = "\$COPILOT_BOT" \]; then$/ {w=1; next}
     inb && w && /^else$/ {e=1; next}
     inb && e && /@codex review/ {print "ok"; exit}
     inb && e && /^(el)?if / {print "conditional"; exit}' "$SKILL" | grep -q '^ok$' \
    && pass "automatic mode requests a review whether or not the push moved the head" \
    || die "the automatic request is conditional again; a no-op push queues nothing"
# `-F`, not a `.` standing in for the apostrophe. A wildcard where an exact
# character belongs matches variants nobody wrote, and the point of asserting a
# message contract is that the message is that message.
grep -qF "could not request the review that carries this round's summary" "$SKILL" \
    && pass "…and says what that request is for" \
    || die "the automatic path does not branch on its own request failing"

# ── the re-request depends on WHICH reviewer the round was about ──────────
# Copilot is never triggered by a push and never by an `@codex` mention — only by
# `--add-reviewer`. A Copilot fix round that posted the Codex mention requested
# nothing, and the watch waited past the old Copilot review indefinitely.
[ "$(grep -c 'if \[ "\$WHO" = "\$COPILOT_BOT" \]; then' "$SKILL")" -ge 2 ] \
    && pass "both round-closing paths branch on the reviewer" \
    || die "a round-closing request assumes Codex regardless of \$WHO"
grep -q 'could not re-request Copilot' "$SKILL" \
    && pass "…and a Copilot round re-requests through --add-reviewer" \
    || die "a Copilot round never re-requests Copilot"

# ── the fetched heads are validated, not merely fetched ───────────────────
# An rc-0 call yielding empty or `null` makes every unchanged-head comparison
# false, so automatic mode assumes the no-op push queued a review.
# NO `PRIOR_HEAD` AT ALL. It existed to decide whether the push had moved
# anything, so a mention could be sent only when it had not; the request is
# unconditional now and nothing reads it. Left in place it is a `gh pr view` whose
# transient failure aborts a step before any context is posted — a call that can
# only cost. The assertion is that there are ZERO assignments, because "one is
# still validated" is what a half-finished removal looks like.
[ "$(grep -c '^PRIOR_HEAD=' "$SKILL")" -eq 0 ] \
    && pass "the obsolete head baseline is gone, not merely unused" \
    || die "a PRIOR_HEAD baseline is still fetched and can abort a step for nothing"
grep -q 'HEAD_AFTER" =~ \^\[0-9a-f\]{40}\$' "$SKILL" \
    && pass "…and the head after the push is validated, not merely fetched" \
    || die "the pushed head is not validated"
# ── the round summary is posted ONCE ──────────────────────────────────────
# The automatic path posted it standalone and then again inside the `@codex
# review` mention, so every Codex round left two identical round-summary comments
# — and the contract makes the NEWEST summary the one read before the diff, so a
# duplicate is a record with two answers to the same question. The count is per
# BRANCH, since each reviewer takes a different route to the same single post.
# BOUNDED TO ITS OWN FENCED BLOCK. Extracting from the heading to end-of-file
# swept in the Copilot phase's own summary post three sections later, so the count
# was two and the assertion failed against correct code — a guard that cannot say
# where the thing it counts lives counts something else.
auto_block="$(awk '/^\*\*Automatic review ON\*\*/ {inb=1; next}
                   inb && /^```bash$/ {code=1; next}
                   inb && code && /^```$/ {exit}
                   inb && code' "$SKILL")"
[ "$(grep -c 'gh pr comment N --repo \$HOST/\$OWNER/\$REPO --body "\$SUMMARY"' <<<"$auto_block")" -eq 1 ] \
    && pass "the automatic path posts a standalone summary exactly once" \
    || die "the automatic path posts the round summary more than once, or not at all"
# …and that one is inside the Copilot branch, whose request carries no body. The
# Codex mention carries the summary itself, so a standalone post there duplicates
# it — which is the shape the count above would still allow if it moved.
awk '/^if \[ "\$WHO" = "\$COPILOT_BOT" \]; then$/ {w=1}
     w && /--body "\$SUMMARY"/ {print "ok"; exit}
     w && /^else$/ {print "outside"; exit}' <<<"$auto_block" | grep -q '^ok$' \
    && pass "…in the Copilot branch, because the Codex mention carries it instead" \
    || die "the standalone summary post is not the Copilot branch's"
# ── the review baseline is taken AFTER the push ───────────────────────────
# In automatic mode the push starts a pass that can FINISH during the CI wait —
# the gate waits for checks, and a Codex pass on a small diff can be quicker. A
# baseline captured before the push then accepts that early pass as the answer to
# the request made after it, and the loop can advance to Copilot, or to the merge
# gate, while the summary-aware pass is still running.
[ "$(grep -c 'PRIOR_REVIEW=' <<<"$auto_block")" -ge 1 ] \
    && pass "the automatic path takes a review baseline before its request" \
    || die "the automatic path requests a review with no baseline to tell passes apart"
awk '/^git push \|\|/ {p=NR}
     p && /PRIOR_REVIEW=/ {print "ok"; exit}
     !p && /PRIOR_REVIEW=/ {print "early"; exit}' <<<"$auto_block" | grep -q '^ok$' \
    && pass "…taken after the push, so the pass the push started cannot answer it" \
    || die "the automatic baseline predates the push; an early pass satisfies the request"
# IN EACH BRANCH, not once anywhere. The two requests are made in different
# branches, so a single baseline satisfies a count and an ordering check while the
# other branch requests a review with nothing to tell the passes apart — which is
# exactly what removing the Codex one leaves behind.
for br in copilot codex; do
    case "$br" in
        copilot) got="$(awk '/^if \[ "\$WHO" = "\$COPILOT_BOT" \]; then$/ {b=1; next}
                             b && /^else$/ {exit}
                             b && /PRIOR_REVIEW=/ {print "ok"; exit}' <<<"$auto_block")" ;;
        *)       got="$(awk '/^if \[ "\$WHO" = "\$COPILOT_BOT" \]; then$/ {w=1; next}
                             w && /^else$/ {b=1; next}
                             b && /@codex review/ {exit}
                             b && /PRIOR_REVIEW=/ {print "ok"; exit}' <<<"$auto_block")" ;;
    esac
    [ "$got" = ok ] \
        && pass "…and the $br branch takes its own, before its own request" \
        || die "the $br branch requests a review with no baseline of its own"
done
# The stale-baseline defect is gone by construction rather than by refreshing:
# with the request unconditional there is no comparison for a stale baseline to
# make false. What replaced it has to stay stated, or the next reader restores the
# comparison and the baseline together.
grep -q 'No .PRIOR_HEAD. baseline any more' "$SKILL" \
    && pass "…and the automatic path says why it no longer keeps one" \
    || die "the automatic path dropped its baseline without saying what replaced it"

# ── the boundary is checked BEFORE the request, in both recipes ───────────
# Counting afterwards meant the pause fired once round N+1 was already queued and
# probably running — a notification, not a decision.
# Line numbers, compared per recipe. An awk state machine got this wrong twice:
# `inb` never reset, so the second recipe saw the first one's request line.
off_start=$(grep -n 'Automatic review OFF' "$SKILL" | head -1 | cut -d: -f1)
on_start=$(grep -n 'Automatic review ON' "$SKILL" | head -1 | cut -d: -f1)
in_range() {   # in_range <pattern> <from> <to> -> first matching line number
    # `-e`, not `--`: passing `--` as the first ARGUMENT shifted every parameter
    # by one, so the pattern became the range and every lookup returned line 1.
    grep -n -e "$1" "$SKILL" | awk -F: -v a="$2" -v b="$3" '$1>a && $1<b {print $1; exit}'
}
end_of_file=$(wc -l < "$SKILL")
for spec in "OFF|$off_start|$on_start" "ON|$on_start|$end_of_file"; do
    label="${spec%%|*}"; rest="${spec#*|}"; from="${rest%%|*}"; to="${rest#*|}"
    c=$(in_range 'pr-round-count.sh N "$WHO"' "$from" "$to")
    q1=$(in_range '--add-reviewer @copilot' "$from" "$to")
    q2=$(in_range '--body "@codex review' "$from" "$to")
    # In automatic mode the PUSH is the request, so it counts as a triggering
    # command. Checking only the mention and --add-reviewer let a boundary check
    # sit after the push and still pass — the third placement of this check, and
    # the first assertion that covers every way a review can start.
    q3=""
    [ "$label" = "ON" ] && q3=$(in_range '^git push' "$from" "$to")
    q=""
    for cand in "$q1" "$q2" "$q3"; do
        [ -n "$cand" ] || continue
        { [ -z "$q" ] || [ "$cand" -lt "$q" ]; } && q=$cand
    done
    { [ -n "$c" ] && [ -n "$q" ] && [ "$c" -lt "$q" ]; } \
        && pass "the automatic-review-$label recipe counts rounds before requesting" \
        || die "the automatic-review-$label recipe requests before the boundary check (count=$c request=$q)"
done

# ── Copilot is re-requested regardless of whether the head moved ──────────
# A push never triggers Copilot, so branching on the head first skipped
# `--add-reviewer` on any Copilot round that DID change the head.
awk '/^\*\*Automatic review ON\*\*/ {inb=1}
     inb && /^if \[ "\$WHO" = "\$COPILOT_BOT" \]; then$/ {w=NR}
     inb && w && /@codex review/ {print "ok"; exit}' "$SKILL" | grep -q ok \
    && pass "the reviewer is checked before the Codex mention in the automatic recipe" \
    || die "a Copilot round would be sent the Codex mention"

# ── the push must have landed on THIS PR ──────────────────────────────────
# A successful `git push` from the wrong worktree, or with a refspec pointing at
# another branch, leaves the PR head untouched — and because the local head then
# differs from it, the no-op branch is skipped and nothing is requested at all.
grep -q 'the push did not update PR N' "$SKILL" \
    && pass "the round verifies the push actually moved this PR" \
    || die "a push that landed elsewhere is treated as having queued a review"
# …against the SHA it pushed, not a fresh read of mutable local HEAD. A checkout
# reset after the push would otherwise satisfy the comparison with a commit that
# never reached the PR.
awk '/^if \[ "\$HEAD_BEFORE" != "\$HEAD_AFTER" \]; then$/ {inb=1}
     inb && /^fi$/ {inb=0}
     inb && /git rev-parse HEAD/ {print "bad"; exit}' "$SKILL" | grep -q bad \
    && die "the push confirmation re-reads mutable local HEAD" \
    || pass "…comparing against the pushed SHA rather than re-reading HEAD"

# ── a hostless origin is refused, not defaulted to GitHub ─────────────────
grep -q 'origin_has_no_host' "$SCRIPT_DIR/identitylib.sh" \
    && pass "an origin with no network authority is refused" \
    || die "a local-path origin would be treated as github.com"
# THE RE-DRIFT GUARD. Four copies of this parser is what issue #18 was about, and
# nothing stops a later edit writing the rules back into the driver "for clarity"
# — at which point the two disagree silently, which is how both the hostless and
# the file-transport rules came to exist in some copies and not others.
grep -qE 'refusing to guess one|origin_transport_unsupported' "$SKILL" \
    && die "SKILL.md has grown its own copy of the origin parser again" \
    || pass "…and the driver carries no second copy of the rule"

# ── the helper selection takes its pipeline status ────────────────────────
# `head` can emit a plausible path and then fail; if that directory holds
# executables the validation below passes and every gate runs helpers chosen by a
# failed read. Asserted on the guard, not on the abort message — the message
# survives the defect.
grep -q 'RB_CANDIDATES" | head -1)" \\' "$SKILL" \
    && pass "the helper selection branches on its pipeline status" \
    || die "the helper selection pipeline status is unchecked"

# ── the reviewers review; they do not implement ────────────────────────────
# Ignoring this is not a no-op: a summary mentioning an unfixed defect was read
# as a work order, and the run edited files and committed from an environment
# with no remote — so the commit existed nowhere and no review was produced.
for f in "$ROOT/AGENTS.md" "$ROOT/.github/copilot-instructions.md"; do
    [ -f "$f" ] || continue
    grep -qi 'You do not implement' "$f" \
        && pass "$(basename "$f") states that the reviewer never writes code" \
        || die "$(basename "$f") does not forbid the reviewer from implementing"
done

# ── v2 ships to Claude Code only ───────────────────────────────────────────
# Both reviewers run in GitHub's cloud, so nothing is installed for them; the
# driver needs a watch tool, which is why there is one manifest and not two.
[ -e "$ROOT/.codex-plugin" ] \
    && die "the Codex plugin manifest is back; v2 ships to Claude Code only" \
    || pass "no Codex plugin manifest"
[ -e "$ROOT/.agents" ] \
    && die "the Codex marketplace metadata is back" \
    || pass "no Codex marketplace metadata"
if [ -f "$ROOT/README.md" ]; then
    grep -q 'codex plugin' "$ROOT/README.md" \
        && die "README still documents installing this plugin into Codex" \
        || pass "README does not document a Codex install"
fi

# A GraphQL 200 can carry both `errors` and structurally valid `data`. The
# unresolved-thread count answers 0 on partial data, and 0 is merge permission —
# taken with `--admin`, so nothing downstream catches the omitted thread.
grep -q 'has("errors") | not' "$SKILL" \
    && pass "the unresolved-thread gate refuses a response carrying GraphQL errors" \
    || die "a partial GraphQL response can still produce UNRESOLVED=0"

# The README must not advertise Copilot as optional while the gate requires it:
# a user would install for a repository without Copilot and find out at merge
# time that the loop cannot finish.
if [ -f "$SCRIPT_DIR/../../../README.md" ]; then
    README="$SCRIPT_DIR/../../../README.md"
    grep -qi 'if you want the second pass' "$README" \
        && die "README still presents Copilot as optional while the gate requires it" \
        || pass "README does not present Copilot as optional"
    grep -qi 'required, not' "$README" \
        && pass "README says plainly that Copilot is required" \
        || die "README does not state that Copilot is required"
fi

# The head-state line is parsed, not substring-matched. The pattern is held in a
# variable because Bash 3.2 cannot PARSE an inline `=~` pattern containing a
# parenthesis at all — the macOS shell rejects the whole block with a syntax error.
#
# THE WHOLE ASSIGNMENT IS ASSERTED, both anchors included. Checking the prefix and
# checking that the variable is used leaves the terminal `$` unguarded: without it
# the pattern accepts `PR_REVIEW_STATE … state=none trailing`, the merge block takes
# the old-signoff fallback, and both halves of a split assertion still pass.
grep -qF "RX_STATE='^PR_REVIEW_STATE pr=([0-9]+) sha=([0-9a-f]{7,40}) reviewer=([^[:space:]]+) state=([a-z]+)\$'" "$SKILL" \
    && grep -q 'CODEX_HEAD_STATE" =~ \$RX_STATE' "$SKILL" \
    && pass "the Codex head-state line is matched as a whole record" \
    || die "the head-state decision is made on a substring or trailing token"
# …and the record must be ABOUT the PR, reviewer and head that were asked for.
# A well-formed `state=none` for something else took the fallback path and merged
# on the recorded signoff while Codex had a current-head CHANGES_REQUESTED.
grep -q '"\$S_PR" != "N" \] || \[ "\$S_WHO" != "\$CODEX_BOT" \] || \[ "\$S_SHA" != "\${HEAD_OID:0:7}"' "$SKILL" \
    && pass "the head-state record is bound to the PR, reviewer and head requested" \
    || die "any well-formed state record satisfies the head-state check"
grep -q 'none|pending|reviewed|blocked|dismissed) ;;' "$SKILL" \
    && pass "…and validated against the known states" \
    || die "the parsed head-state is not checked against the known states"

# ── portability: no GNU-only tools on the path that must work on macOS ─────
# Comment lines are excluded on purpose: the skill EXPLAINS why `sort -V` is not
# used, and matching that explanation would make the assertion unfalsifiable.
if grep -vE '^[[:space:]]*#' "$SKILL" | grep -q 'sort -V'; then
    die "skill uses GNU-only 'sort -V' while README advertises portability"
else
    pass "no GNU-only sort in the script-resolution fallback"
fi

# ── the merge is pinned to the head the gates were evaluated against ───────
grep -qE -- '--match-head-commit "\$HEAD_OID"' "$SKILL" \
    && pass "merge is pinned to the gated head" \
    || die "merge is not pinned with --match-head-commit \"\$HEAD_OID\""
grep -qE '^[[:space:]]*if gh pr merge' "$SKILL" \
    && pass "the merge result is branched on" \
    || die "the merge result is not branched on"

# ── both reviewers gate the merge ──────────────────────────────────────────
grep -q 'CODEX_RC' "$SKILL" && grep -q 'COPILOT_RC' "$SKILL" \
    && pass "the merge gate consults BOTH reviewers" \
    || die "the merge gate does not consult both reviewers"

# ── thread pagination ──────────────────────────────────────────────────────
# A truncated thread list reads exactly like a shorter review, so the contract
# has to say so in both places it fetches threads.
[ "$(grep -c 'hasNextPage' "$SKILL")" -ge 2 ] \
    && pass "thread fetches are paginated in both places" \
    || die "a thread fetch is not paginated"

# ── the instruction files carry the scope + issue policy ───────────────────
# These are what reach the reviewers; the loop depends on them, so a missing
# clause is a behaviour change, not a doc nit.
for doc in "$ROOT/AGENTS.md" "$ROOT/.github/copilot-instructions.md"; do
    name="$(basename "$(dirname "$doc")")/$(basename "$doc")"
    [ -f "$doc" ] || { die "$name is missing"; continue; }
    grep -qi 'set out to do' "$doc" \
        && pass "$name: reviewers judge the PR against its stated goal" \
        || die "$name: no scope rule"
    grep -qi 'untrusted context' "$doc" \
        && pass "$name: PR narrative is untrusted" \
        || die "$name: does not mark the PR narrative untrusted"
    grep -qi 'issue' "$doc" \
        && pass "$name: out-of-scope problems can be filed as issues" \
        || die "$name: no issue-filing route for out-of-scope problems"
    grep -qi 'review body' "$doc" \
        && pass "$name: names the non-blocking channel" \
        || die "$name: does not name the review body as the non-blocking channel"
    grep -qi 'fail-closed\|fail closed' "$doc" \
        && pass "$name: fail-closed is a review criterion" \
        || die "$name: does not state the fail-closed criterion"
    grep -qi 'hard-code' "$doc" \
        && pass "$name: the repo-agnostic invariant is a blocking finding" \
        || die "$name: does not tell the reviewer to block a hard-coded identity"
    grep -qi 'base ref\|base-ref' "$doc" \
        && pass "$name: only a base-ref authority waives a finding" \
        || die "$name: no waiver authority rule"
    # A reviewer that installs dependencies and runs the suite turns a
    # three-minute read into a twenty-minute one, and the author is blocked on it
    # either way. The instruction files are the only lever on that.
    grep -qi 'do not set up an environment' "$doc" \
        && pass "$name: the review is read-only (no env setup, no test runs)" \
        || die "$name: does not tell the reviewer to review statically"
    grep -qi 'run the test suite' "$doc" \
        && pass "$name: running the suite is ruled out explicitly" \
        || die "$name: does not rule out running the tests"
done

# ── the phase summary is written by a QUOTED heredoc ───────────────────────
# `SKILL.md` is executed by the driver verbatim, so an unquoted heredoc around
# prose is a live substitution site: the summary body is composed from the round
# and routinely contains Markdown code spans holding shell text, including text
# copied out of an untrusted PR description or a reviewer comment. The assertion
# is structural rather than on the abort message, because a message survives the
# defect it names.
hd="$(grep -n 'cat >>\{0,1\} "\$SUMMARY_FILE" <<' "$SKILL" || true)"
if [ -z "$hd" ]; then
    die "no summary heredoc found in SKILL.md — has the recipe moved?"
else
    bad="$(printf '%s\n' "$hd" | grep -v "<<'EOF'" || true)"
    [ -z "$bad" ] \
        && pass "every summary heredoc is quoted, so prose is written, not executed" \
        || die "an unquoted summary heredoc executes the prose it writes: $bad"
fi
# …and the one value it needs still reaches the file, or the quoting silently
# turned the SHA into the literal text $CODEX_SHA in every summary. The two parts
# are matched separately because the printf and its argument are on separate
# continued lines, and a single-line pattern would fail on correct code.
if grep -q "printf .*Codex signed off on" "$SKILL" \
   && grep -q '"\$CODEX_SHA" >> "\$SUMMARY_FILE"' "$SKILL"; then
    pass "the reviewed SHA is emitted separately through printf"
else
    die "the quoted heredoc drops the reviewed SHA and nothing re-emits it"
fi

# ── the required-checks payload is shape-checked before `all` ──────────────
# `all(.[]; …)` over an empty stream is `true`, so an object, a null, or an empty
# array from a SUCCESSFUL read came out as "every required check passed" and the
# default administrator merge proceeded on a payload nothing had read.
grep -q 'if type != "array" or length == 0 then "malformed"' "$SCRIPT_DIR/pr-ci-state.sh" \
    && pass 'the checks payload must be a non-empty array before all() runs' \
    || die 'the checks jq computes all() without validating its container'
grep -q 'any(.\[\]; type != "object" or (.bucket | type) != "string")' "$SCRIPT_DIR/pr-ci-state.sh" \
    && pass "…and each element must actually carry a bucket string" \
    || die "the checks jq does not validate the bucket records"

# ── the identity parser rejects transports that reach no GitHub server ─────
# `SKILL.md` carries its own copy of the parser, and it is the copy the driver
# runs. `test-pr-identity.sh` can execute the three scripts' copies but not this
# one, so the structural assertion is what covers it.
grep -q 'ssh://\*|git://\*|https://\*|http://\*|git+ssh://\*' "$SCRIPT_DIR/identitylib.sh" \
    && pass "the identity parser accepts only GitHub network transports" \
    || die "the parser reads any URL scheme as a GitHub identity"
grep -q 'reaches no GitHub server' "$SKILL" \
    && pass "…and refuses the rest rather than guessing a host" \
    || die "SKILL.md has no rejection path for an unsupported transport"

# ── acknowledging a check-in takes the gate's status, and names the reviewer ─
# The acknowledgement is the one place the driver records the OPERATOR's
# permission. Reading it out of a pipeline hid the helper's status: a run that
# printed a plausible pause line and then died some other way still yielded
# digits, `sed` still succeeded, and permission was recorded from an unreadable
# probe. And the count is per reviewer, so an unscoped footer acknowledging 41
# Codex rounds is read by a Copilot invocation with 5, trips its ahead-of-count
# guard and blocks that phase for good.
grep -q 'ROUNDS_RC" -eq 3' "$SKILL" \
    && pass "the acknowledgement requires the gate's distinguished pause status" \
    || die "the driver acknowledges a check-in without checking the gate exited 3"
grep -q 'Review-Pause-Acknowledged:\*\* `%s` `%s`' "$SKILL" \
    && pass "the acknowledgement footer names the reviewer and the count" \
    || die "the acknowledgement footer is unscoped and will cross between phases"

# ── the none-configured checks message is matched whole, not searched ──────
# ── the none-configured diagnostic is matched WHOLE ───────────────────────
# `gh` has no dedicated status for "nothing to report", so the message is the only
# signal — and a substring test accepted it inside a LARGER failure: a run that
# printed the benign line and then failed for an unrelated reason was classified
# as benign, and the default administrator merge proceeded with no trusted checks
# result at all.
#
# The six cases that prove it moved to `test-pr-ci-state.sh` with the helper, and
# they are EXECUTED there rather than read. What remains here is the question only
# this file can answer: that the merge gate reaches that helper at all. A helper
# with perfect coverage decides nothing if the gate stopped calling it.
grep -q '"\$RB_SCRIPTS"/pr-ci-state.sh N --required' "$SKILL" \
    && pass "the merge gate asks the checks helper, not a second copy of it" \
    || die "the merge gate no longer calls pr-ci-state.sh"
# …and it distinguishes "nothing configured" from "could not tell". Collapsing
# them blocked the merge on every repository without branch protection,
# permanently — a gate that never opens rather than one that fails closed.
awk '/pr-ci-state.sh N --required/ {c=NR}
     c && /^ *4\) echo "note: no required checks configured/ {print "ok"; exit}' "$SKILL" \
    | grep -q ok \
    && pass "…and treats 'nothing configured' as its own answer" \
    || die "a repo with no required checks cannot pass the merge gate"

# ── `none` is not permission while auto-review has a pass in flight ────────
# With auto-review on, every Copilot-fix push queues a Codex pass, and Codex
# exposes no review record while that pass is queued — which the merge gate read
# as the same `none` that means "nothing asked Codex about this head". It then
# fell back to the pre-Copilot signoff and could merge before the in-flight pass
# reported, including a body-only CHANGES_REQUESTED that leaves no unresolved
# thread for the other gates to catch.
none_branch="$(awk '/^case "\$CODEX_STATE" in/ { c++ } c == 2 { print } c == 2 && /^esac/ { exit }' "$SKILL")"
if [ -z "$none_branch" ]; then
    die "the merge gate no longer has a CODEX_STATE dispatch — has it moved?"
else
    printf '%s' "$none_branch" | grep -q 'AUTO_REVIEW.*=.*yes' \
        && pass "the merge gate distinguishes an in-flight auto-review from no review" \
        || die "the none branch falls back to the signoff without checking AUTO_REVIEW"
    printf '%s' "$none_branch" | grep -q 'merge blocked' \
        && pass "…and blocks rather than trusting the pre-Copilot signoff" \
        || die "the in-flight case does not block the merge"
fi

# ── the phase trailer has to be documented as a TRAILER ────────────────────
# `git` parses trailers from the last paragraph only, so `Review-Phase: copilot`
# written with a blank line above it is not a trailer — the commit looks correct
# to a reader and is invisible to the merge gate. The contract told the driver to
# "carry the trailer" without saying where, and following it produced exactly that
# commit while developing this plugin.
grep -q 'LAST paragraph' "$SKILL" \
    && pass "the contract says where the phase trailer has to go" \
    || die "the contract asks for a trailer without saying it must be in the trailer block"
grep -q 'trailer_not_in_trailer_block' "$SKILL" \
    && pass "…and names the status the gate reports when it is misplaced" \
    || die "the contract does not mention the misplaced-trailer status"

# ── the driver's working discipline is stated, not assumed ─────────────────
# The failure mode of an automated fix loop is not laziness, it is enthusiasm:
# fixing more than was asked, building more than the finding requires, and
# bundling both into a commit whose summary says "closing review comments". Each
# of these rules exists because breaking it lengthened a real PR here, so each is
# asserted rather than left to be inferred from the surrounding prose.
# EVERY clause this contract declares binding, not a sample of them. The first
# version asserted five of six, so deleting "every change must be reviewable as a
# fix" left the suite green — a contract can lose a rule silently exactly as a
# helper can lose a field check.
for rule in \
    'Fix what the finding names' \
    'Do not build more than the finding requires' \
    'Every change you make must be reviewable as a fix' \
    'Validate a finding before you act on it' \
    'Prove a fix can fail' \
    'Say what you did not do'; do
    grep -qF "$rule" "$SKILL" \
        && pass "the contract states: $rule" \
        || die "the contract no longer states: $rule"
done

# ── the driver is told to read a finding whole ─────────────────────────────
# `list` prints one line per thread so the set is countable; that line is not the
# finding. Acting on the title alone produces a fix aimed at a paraphrase, which
# is how a round ends with the thread resolved and the finding still true.
grep -q 'Read each finding whole' "$SKILL" \
    && pass "the contract tells the driver to read the finding body" \
    || die "the contract does not tell the driver to read past the title"
grep -q 'suggestion' "$SKILL" \
    && pass "…including any code suggestion attached to it" \
    || die "the contract never mentions code suggestions"
grep -q 'proposal rather than an instruction' "$SKILL" \
    && pass "…and that a suggestion is a proposal, not an instruction" \
    || die "the contract does not say how to weigh a code suggestion"
# The bodies come from the helper, which filters to UNRESOLVED threads. The REST
# comments endpoint has no such filter and returns every review comment the PR has
# ever had, so fetching bodies there hands the driver findings answered three
# rounds ago — and fixing an already-answered comment is the scope expansion these
# same rules forbid. The contract said so only after a review round said it first.
# The endpoint is NAMED — the contract warns against it — so what must be absent
# is a CALL to it, not the string. FLATTENED, because `gh api` calls in this file
# routinely span continuation lines: a line-based match saw only one token of a
# split invocation and reported clean. Third time line-wrapping has defeated a
# check in this PR, which is why the flattened copy is taken once and reused.
skill_flat="$(tr '\n' ' ' < "$SKILL" | tr -s ' ')" \
    || die "could not flatten SKILL.md for the endpoint check"
# The scans below use herestrings rather than `printf | grep`: under `pipefail`,
# `grep -q` exiting at the first match SIGPIPEs the producer and the pipeline
# reports the match as ABSENT — the fail-open direction. The fixture demonstrating
# that hazard, and the counting machinery for CHANGELOG consistency, are held back
# for a follow-up PR: both are hardening of this file rather than tests of the
# documentation this change delivers, and both were the source of most of the
# review churn on it.
# A POSITIVE CONSTRAINT, not a blacklist of route spellings.
#
# Three versions of this guard tried to recognise the forbidden call by its shape
# — `[^|]*` treated a jq pipe as a pipeline boundary, `{0,200}` was a ceiling a
# long filter walks past, and the route regex was defeated in turn by `$PR`,
# quotes, and a backslash continuation. Each fix was correct and each was one
# spelling behind, because a lexical blacklist can always be evaded: the last
# evasion found was `PULLS="repos/…/pulls/$PR"; gh api "$PULLS/comments"`, where no
# contiguous route substring exists at all.
#
# The invariant was never really about that string. It is that the findings are
# read through the HELPER, which filters to unresolved threads — so the check is
# now that the findings-reading section executes `pr-findings.sh` and calls no
# `gh api` at all. No composition of variables satisfies that, because the
# constraint is on what the section may invoke rather than on how a URL is spelt.
#
# `gh api` remains legitimate elsewhere in the file — reactions and thread
# resolution use it — so the constraint is scoped to the section that reads
# findings.
findings_code="$(awk '
    /^## 4\. Read the findings/ { insec = 1 }
    insec && /^## 5\./ { insec = 0 }
    !insec { next }
    /^[ ]{0,3}(```+|~~~+)/ {
        line = $0; sub(/^[ ]+/, "", line)
        ch = substr(line, 1, 1); n = 0
        while (substr(line, n + 1, 1) == ch) n++
        if (!inb) { inb = 1; fch = ch; fn = n; next }
        if (ch == fch && n >= fn && substr(line, n + 1) ~ /^[[:space:]]*$/) { inb = 0; next }
        next
    }
    inb { print; next }
    # AN INDENTED BLOCK IS ALSO CODE. Markdown treats four spaces at the top level
    # as a code block, and a fenced helper call elsewhere in the section kept
    # `findings_code` non-empty — so a recipe hidden in an indented block was
    # omitted while the whitelist reported clean. It never had to defeat the
    # check, only to sit outside what the extractor looked at.
    # TABS FIRST. A leading tab indents a Markdown code block exactly as four
    # spaces do, and an extractor that knew only spaces omitted it — the third
    # narrowing of this same extractor, so the fix normalises rather than adding
    # one more accepted shape.
    { gsub(/\t/, "    ") }
    /^[ ]{4,}[^[:space:]]/ { sub(/^[ ]+/, ""); print }' "$SKILL")" \
    || die "could not extract the findings-reading section from SKILL.md"
[ -n "$findings_code" ] \
    || die "the findings-reading section has no executable block; has it moved?"
# A WHITELIST, which is where this had to end up. Blacklisting the route was
# defeated by five spellings; blacklisting `gh api` was still lexical and is
# defeated by `gh  api`, `"gh" api`, or a continuation between the two words.
# Every blacklist is one spelling behind because the space of ways to write a
# command is open.
#
# So the section is constrained to what it MAY run rather than what it may not:
# every executable line here has to be a `pr-findings.sh` invocation. Anything
# else fails however it is spelt, because the check is not looking at how a
# command is written — it is looking for anything that is not the one permitted
# command. That closes the sequence rather than extending it.
#
# If this section ever legitimately needs a second command, this guard fails and
# is updated deliberately. That is the correct cost: adding a call here is exactly
# the change that should not happen quietly.
findings_stmts=0 findings_bad=""
while IFS= read -r line; do
    # A COMMENT IS DECIDED BY THE FIRST NON-BLANK CHARACTER. The glob `' '*'#'*`
    # matched any indented line containing a `#` ANYWHERE, so
    # `    gh api …/comments # fetch bodies` was discarded as a comment and never
    # reached the whitelist at all — a bypass that did not need to defeat the
    # check, only to avoid it.
    _t="${line#"${line%%[![:space:]]*}"}"
    case "$_t" in
        ''|'#'*) continue ;;
    esac
    findings_stmts=$((findings_stmts + 1))
    # ANCHORED to the whole statement. An unanchored glob only asked that the
    # permitted call appear SOMEWHERE, so `gh api …; "$RB_SCRIPTS"/pr-findings.sh
    # list N` satisfied it — a whitelist carrying a blacklist's hole. The statement
    # is split on `;`: the first command must BE the helper, and every following
    # segment must be a status capture, which is the only other thing these lines
    # do.
    stmt="${line#"${line%%[![:space:]]*}"}"
    first="${stmt%%;*}"; rest="${stmt#"$first"}"
    ok=1
    # The permitted segment must be the helper call and NOTHING ELSE. Splitting on
    # `;` alone left `… list N && gh api …` intact in `first`, where a prefix glob
    # accepted it — the anchor was on the start of a segment rather than on the
    # whole command. Control operators and command substitution chain a second
    # command without a semicolon, so they are refused here.
    case "$first" in
        # `>(`/`<(` are process substitution: `… list N > >(gh api …)` runs a second
        # command with none of the tokens above in it. `<` and `>` are refused
        # outright — these statements have no business redirecting.
        *'&&'*|*'||'*|*'|'*|*'&'*|*'$('*|*'`'*|*'>('*|*'<('*|*'>'*|*'<'*) ok=0 ;;
        '"$RB_SCRIPTS"/pr-findings.sh '*) ;;
        *) ok=0 ;;
    esac
    while [ -n "$rest" ] && [ "$ok" -eq 1 ]; do
        rest="${rest#;}"; seg="${rest%%;*}"; rest="${rest#"$seg"}"
        seg="${seg#"${seg%%[![:space:]]*}"}"; seg="${seg%"${seg##*[![:space:]]}"}"
        # A COMPLETE IDENTIFIER ASSIGNMENT, character by character. The glob
        # `[A-Za-z_]*'=$?'` reads as "one identifier character, then anything,
        # then =$?" — so `gh api repos/…/comments && FIND_RC=$?` satisfied it.
        # `*` in a glob is not `*` in a regex, and that difference was the hole.
        case "$seg" in
            '') ;;
            *'=$?')
                _name="${seg%'=$?'}"
                case "$_name" in
                    ''|[!A-Za-z_]*) ok=0 ;;
                    *[!A-Za-z0-9_]*) ok=0 ;;
                esac ;;
            *) ok=0 ;;
        esac
    done
    [ "$ok" -eq 1 ] || findings_bad="$findings_bad
       $line"
done <<<"$findings_code"
[ "$findings_stmts" -gt 0 ] \
    && pass "the findings-reading section has executable statements to check" \
    || die "the findings-reading section executes nothing; has it moved?"
if [ -z "$findings_bad" ]; then
    pass "…and every one of them is a pr-findings.sh call, whatever else could be spelt"
else
    die "the findings-reading section runs something other than pr-findings.sh:"
    printf '%s\n' "$findings_bad"
fi
grep -q 'no resolution filter' "$SKILL" \
    && pass "…and says why that endpoint cannot be used for findings" \
    || die "the contract does not explain why the REST endpoint is wrong here"
# The deferral rule must not contradict the work-order rule: a mention describing
# an UNFIXED defect is read as a task, and Codex then commits in an environment
# with no remote. The disposition belongs in the summary; the description does not.
# Mutation proof is mandatory in this repository, so the contract must not offer
# disclosure as a way out of it: a summary is untrusted context, not authority,
# and closing a round on "no mutant is claimed" leaves an assertion that passed
# before the fix while the suite reports green.
# The body-reading rule needs the SENTENCE, not just the heading above it:
# reversing the prose to "the title is sufficient" left that heading intact and
# every other check satisfied. Asserted here rather than beside the heading
# because the sentence wraps in the file and is only contiguous once flattened.
# The README must describe the operator stop, because it is the one rule a user
# MEETS rather than reads about: a loop that will not close, with the reason only
# in a summary. Documenting the behaviour without documenting the decision that
# unblocks it leaves them stuck with no way to know what is being asked.
rd_flat="$(tr '\n' ' ' < "$SCRIPT_DIR/../../../README.md" | tr -s ' ')" \
    || die "could not flatten README.md"
grep -qF 'stops for you' <<<"$rd_flat" \
    && pass "the README says the loop stops for the operator when a mutation cannot be built" \
    || die "a user could meet a loop that will not close with no user-facing explanation"
grep -qF 'a dated record landed on the base branch by its own PR' <<<"$rd_flat" \
    && pass "…and says what decision unblocks it" \
    || die "the README does not tell the operator how to accept the limitation"

grep -qF 'That line is not the finding.' <<<"$skill_flat" \
    && pass "the contract says explicitly that the printed line is not the finding" \
    || die "the body-reading rule could be reversed under an unchanged heading"
grep -q 'not waivable by disclosure' <<<"$skill_flat" \
    && pass "mutation proof cannot be waived by saying so in the summary" \
    || die "the contract lets a summary line stand in for an unproven fixture"
grep -qi 'write the limitation as a comment \*\*at the site\*\*' <<<"$skill_flat" \
    && pass "…an unprovable case is written at the site" \
    || die "the contract does not say where an unprovable limitation is recorded"
# …and does NOT pretend that comment is authority. A comment added in this PR
# arrives WITH the change, so it is untrusted context exactly like the summary —
# calling it a base-ref record would let the round converge on the author's own
# say-so, which is the thing the rule above exists to forbid.
grep -qi 'It explains; it does not accept' <<<"$skill_flat" \
    && pass "…and that comment explains rather than accepts" \
    || die "the contract treats a comment added in this PR as an accepted limitation"
grep -qi 'landed on the \*\*base ref by its own pull request\*\*' <<<"$skill_flat" \
    && pass "…with acceptance requiring a separately landed base-ref record" \
    || die "the contract does not say how a limitation actually becomes authority"
# The OUTCOME, not only the prohibition. Recording the limitation and carrying on
# is still closing a round on an unproven fixture — the stop is what makes the
# rule bite, and it was the one clause the previous pair of assertions missed.
grep -qE '\*\*stop for the operator\*\*' <<<"$skill_flat" \
    && pass "…and the round stops for the operator rather than closing" \
    || die "the contract records an unprovable case but lets the round close anyway"

# The scope rule and the class-wide self-check must not contradict each other:
# one says fix only what was named, the other says find every occurrence of the
# same shape. They are reconciled by scope, not left for the driver to pick.
grep -q 'is the DEFECT, not the line' <<<"$skill_flat" \
    && pass "the scope rule and the class-wide self-check are reconciled" \
    || die "the contract gives the driver two incompatible scope instructions"
grep -q 'outside this PR' <<<"$skill_flat" \
    && pass "…and a same-shape defect outside the diff is recorded, not pulled in" \
    || die "the contract does not bound class-wide fixing to the PR's own diff"
# The DECISIVE clause: when a finding states its scope, that scope governs — but
# only over copies this PR already changes. Without the first half the driver has
# no rule for an explicit "fix the other parsers"; without the second half it
# contradicts the outside-diff boundary directly above.
grep -q 'states its scope' <<<"$skill_flat" \
    && pass "a finding's stated scope governs the class-wide fix" \
    || die "the contract has no rule for a finding that states its own scope"
grep -q 'that scope governs \*\*for the copies this PR already changes\*\*' <<<"$skill_flat" \
    && pass "…bounded to the copies this PR already changes" \
    || die "stated scope is unbounded and contradicts the outside-diff rule"
# `[[:space:]]`, never `\s`. `\s` is a GNU extension: BSD grep on stock macOS —
# which README lists as supported — reads it as a literal `s`, so this searched for
# "evens*when", failed, and called `die` on correct text. The whole suite is a
# mandatory pre-push gate, so a macOS contributor could not close a round while CI
# stayed green. Same class as the `timeout`, `sha1sum` and `seq` findings before it.
#
# The flattened text has already collapsed runs of whitespace to single spaces, so
# a plain space would do; the class is used anyway because the next person to copy
# this line may not be matching flattened text.
# THE SELF-CHECK BULLET SPECIFICALLY. The bounded wording appears in the scope
# rules, so an assertion that merely finds it somewhere in the file stayed green
# while the self-check thirty lines later still said "search for the same shape
# everywhere else and fix them together" — the two halves of the contract giving
# opposite instructions, which is what this whole PR keeps being about.
grep -qF 'search for the same shape **everywhere else this PR already changes** and fix those together' <<<"$skill_flat" \
    && pass "the class-wide self-check carries the diff boundary too" \
    || die "the self-check would have the driver widen the PR into untouched code"
grep -q 'even[[:space:]]*when the finding names it' <<<"$skill_flat" \
    && pass "…and a named PRE-EXISTING copy outside the diff is still not pulled in" \
    || die "a finding naming an untouched file could still widen the PR"
# …but an untouched file this PR BROKE is not an unrelated problem. A validator
# loosened or a producer altered can break a consumer the diff never touched, and
# repairing it finishes the change rather than widening it. Without this the rule
# told the driver to leave a regression it had just caused, because the file
# happened to sit outside the diff.
grep -qF 'repairing that consumer is not widening the PR, it is' <<<"$skill_flat" \
    && pass "…while repairing a consumer this PR broke stays in scope" \
    || die "the contract would leave a regression it caused in an untouched file"
# A REGRESSION THE FIX CAUSED BELONGS TO THIS ROUND. The rule said a different
# defect found while fixing is "never in scope", which would have the driver defer
# a defect it had just introduced — part of what this PR changed, and on its way to
# a merge if the next reviewer misses it. The line is drawn at pre-existing, not at
# "was it the defect the finding named".
# THE OUTCOME, not the subject. Matching only "a regression the fix itself
# introduces" passed when the sentence was negated — the contract could say such a
# regression is NOT this round's work and this check would still be green.
grep -q 'regression the fix itself introduces' <<<"$skill_flat" \
    && pass "the contract addresses a regression the fix introduces" \
    || die "the contract no longer addresses a regression the fix causes"
grep -q 'it is part of what this PR changed, so it is this round' <<<"$skill_flat" \
    && pass "…and says it is this round's work" \
    || die "the contract does not say a fix-introduced regression is this round's work"
# BOTH qualifiers. "pre-existing" alone still excluded the same defect in a copy
# this PR changes, which the bullets above require fixing together — the driver
# could leave an in-diff twin and collect the same finding next round.
# Subject AND outcome. `A *different* pre-existing defect` alone passed with the
# sentence reversed to "is in scope", which is the opposite instruction.
grep -q 'A \*different\* pre-existing defect' <<<"$skill_flat" \
    && pass "…and only a DIFFERENT pre-existing defect is out of scope" \
    || die "the out-of-scope rule would exclude an in-diff twin of the same defect"
grep -qE 'A \*different\* pre-existing defect found while fixing this one is not in scope' <<<"$skill_flat" \
    && pass "…and that defect is stated to be OUT of scope" \
    || die "the contract does not state the out-of-scope outcome"
# ── the SIGPIPE hazard these scans avoid, demonstrated ────────────────────
# Every scan in this file uses a herestring rather than `printf | grep`. This is
# the fixture that shows why, and it was held back from the documentation PR
# because it tests THIS FILE's idiom rather than anything the contract says.
#
# With `pipefail` on, `grep -q` exits at the first match and the producer takes
# SIGPIPE, so the pipeline reports the match as ABSENT — the fail-open direction,
# where a guard reports clean exactly when it should fire.
#
# MEASURED, and the measurement bounds the claim: the race needs the match on an
# early LINE with more lines behind it, so `grep` can exit before draining the
# writer. Multi-line input reproduces it 5 runs out of 5; single-line input 0 out
# of 5 at the same size, because `grep` must read the whole line before it can
# match at all. The flattened variables here are single-line by construction, so
# the pipeline form was not losing matches — the herestring removes the class
# rather than relying on an invariant one edit could break.
#
# The construction reports separately from the result: `set -uo pipefail` has no
# `-e`, so a failing `head`/`base64` would leave `multi` holding just "EARLYMATCH"
# and both forms would match it, reporting success having built nothing. Exit 9 is
# reserved for that.
sigpipe_probe='set -uo pipefail
    body="$(head -c 300000 /dev/urandom | base64)" || exit 9
    [ "${#body}" -ge 200000 ] || exit 9
    case "$body" in *"
"*) ;; *) exit 9 ;; esac
    multi="EARLYMATCH
$body"'
# PIPESTATUS, not the aggregate: on a runner where SIGPIPE is ignored `printf`
# receives EPIPE and returns 1 rather than dying with 141 — the same phenomenon,
# a different number — and a check accepting only 141 failed CI for four commits.
# The producer losing while the consumer MATCHED is the race, whatever the
# platform reports; a consumer that failed is something else and is not proof.
#   0 no race · 9 unbuildable · 20 producer lost, consumer matched · 21 consumer failed
sigpipe_rc=0
bash -c "$sigpipe_probe"'
    printf "%s" "$multi" | grep -q EARLYMATCH
    rcs=("${PIPESTATUS[@]}")
    prod=${rcs[0]}; cons=${rcs[1]}
    [ "$cons" -eq 0 ] || exit 21
    [ "$prod" -eq 0 ] && exit 0
    exit 20' || sigpipe_rc=$?
case "$sigpipe_rc" in
    9)  die "the SIGPIPE probe could not be built; this case proves nothing" ;;
    0)  pass "SKIPPED: the producer pipeline did not race on this platform" ;;
    20) pass "a producer pipeline loses an early match under pipefail, on multi-line input" ;;
    21) die "the probe consumer failed; the race was not what this case observed" ;;
    *)  die "the SIGPIPE probe returned an unexpected status ($sigpipe_rc)" ;;
esac
here_rc=0
bash -c "$sigpipe_probe"'
    grep -q EARLYMATCH <<<"$multi"' || here_rc=$?
case "$here_rc" in
    9) die "the SIGPIPE probe could not be built; the herestring case proves nothing" ;;
    0) pass "…and the herestring form finds it, which is why these scans use it" ;;
    *) die "the herestring form lost an early match; every scan here is unsafe" ;;
esac

# ── the release entry does not teach a rejected account ────────────────────
# The counting machinery, held back from the documentation PR and restored here.
# Four stale claims were found in this one entry across three rounds, and the
# reason each survived was the same: a check for the PRESENCE of a qualified form
# is satisfied by whichever mention still carries it, while another states the
# rule the old way two paragraphs down.
# PINNED to the entry that introduced these rules, not to whichever is on top: the
# next release prepends its own, every count below would then find zero claims in
# it, and this suite would fail while the 2.0.2 documentation stayed correct. A
# guard that breaks on the next release is a guard that gets deleted rather than
# fixed. Everything below that entry is history, and a release note has to be able
# to quote a superseded rule to explain what was fixed.
cl_202="$(awk -v want='## [2.0.2]' '
    index($0, want) == 1 { inb = 1; next }
    /^## \[/ { inb = 0 }
    inb { print }' "$SCRIPT_DIR/../../../CHANGELOG.md" | tr '\n' ' ' | tr -s ' ')" \
    || die "could not extract the 2.0.2 CHANGELOG entry"
[ -n "$cl_202" ] || die "the 2.0.2 CHANGELOG entry is missing or empty"
# …and the scope account must carry the regression exception, which the entry
# contradicted after SKILL.md gained it — the same instance-not-class miss, one
# file over, for the second round running.
# No-match is a count of ZERO, not a failed command: under this file's `-e` a grep
# that matches nothing exits 1, and the assignment took the whole suite down —
# so deleting a claim entirely terminated the run instead of reaching the branch
# that names it. A real grep error (status > 1) is still a failure.
count_claims() {   # count_claims <pattern> <text> ; prints the count, 2 on error
    local out rc=0
    out="$(grep -oiE "$1" <<<"$2")" || rc=$?
    case "$rc" in
        0) ;;
        1) printf '0'; return 0 ;;
        *) return 2 ;;
    esac
    # COUNTED IN THE SHELL, with no pipeline and no external command. `wc` or `tr`
    # can emit a plausible number and then exit non-zero, and
    # `printf "%s" "$( … | wc -l | tr -d ' ')"` swallowed that status — a failed
    # parse returning success with a bogus count, which is the "a call that printed
    # before failing is not data" rule one layer in.
    #
    # Guarding that status would have worked only because this file sets
    # `pipefail`: without it the pipeline reports `tr`'s success and the failure is
    # invisible again. Counting here removes the failure mode instead of detecting
    # it, and cannot be reintroduced by copying the function somewhere with
    # different shell options.
    local n=0 _line
    while IFS= read -r _line; do n=$((n + 1)); done <<<"$out"
    printf '%s' "$n"
}
# EVERY mention must carry the qualifier, so the two counts have to match. A
# presence check passed while one of two bullets had lost it — the "somewhere in
# the file" weakness reproduced inside a single entry.
cl_count() {   # cl_count <claim-pattern> <qualified-pattern> <label>
    local total qualified
    total="$(count_claims "$1" "$cl_202")" \
        || { die "the claim scan failed for: $3"; return 0; }
    qualified="$(count_claims "$2" "$cl_202")" \
        || { die "the qualifier scan failed for: $3"; return 0; }
    [ "$total" -gt 0 ] || { die "the release entry no longer states: $3"; return 0; }
    [ "$total" = "$qualified" ] \
        && pass "every mention in the release entry is qualified: $3 ($qualified/$total)" \
        || die "the release entry states $3 unqualified in $((total - qualified)) of $total places"
}
# The scratch directory for the fixtures below — through the VALIDATED helper,
# and stopping rather than recording.
#
# This was a bare `mktemp -d` guarded by `die`, and `die` RETURNS 0: it records a
# failure and lets the file carry on. So a full or read-only $TMPDIR left
# `TMP_CL` empty, `CNTB` below became `/bin`, and the `mkdir -p` and `ln -sf`
# that build the fixture wrote symlinks over the system binaries they were meant
# to be shadowing inside a scratch tree.
#
# `die` is right for an assertion — every remaining check should still run — and
# wrong here, because everything after this point dereferences the path. And a
# status check alone is not enough: `mktemp` can print a plausible path and then
# fail, or print one it never created, and command substitution keeps the output
# either way. `mktemp_d` is the definition of "a path that was actually created".
TMP_CL="$(mktemp_d)" || {
    die "no scratch directory for the counter fixture"
    echo "RESULT: FAIL"
    exit 1
}
# …and it is removed. There was no cleanup here at all, so every run of the suite
# left a scratch tree behind. Safe as an unquoted-free `rm -rf` only because
# `mktemp_d` has already established the path is non-empty, absolute and not `/`.
trap 'rm -rf "$TMP_CL"' EXIT

# The stop is exercised, not merely written. The dangerous case is not "mktemp
# failed" — a plain failure is caught by any status check — it is a `mktemp` that
# PRINTS a plausible path, because command substitution keeps that output, so an
# unvalidated caller proceeds with a directory that does not exist. Both shapes
# are replayed, and each has to leave the filesystem untouched.
MTP="$TMP_CL/mtprobe"; mkdir -p "$MTP/bin"
mt_probe() {   # mt_probe <stub exit status> <what the case is>
    local canary out rc
    canary="$TMP_CL/canary$1"; rc=0
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit %s\n' "$canary" "$1" \
        > "$MTP/bin/mktemp"
    chmod +x "$MTP/bin/mktemp"
    out="$(PATH="$MTP/bin:$PATH" bash -c '
set -Eeuo pipefail
'"$(declare -f mktemp_d)"'
d="$(mktemp_d)" || { echo STOPPED; exit 1; }
mkdir -p "$d/bin"; echo "CONTINUED:$d"' 2>&1)" || rc=$?
    { [ "$out" = STOPPED ] && [ "$rc" -eq 1 ]; } \
        && pass "a mktemp that $2 stops the fixture setup" \
        || die "a mktemp that $2 did not stop the setup (rc=$rc, '$out')"
    [ ! -e "$canary" ] \
        && pass "…and nothing is written under the path it printed" \
        || die "the setup wrote under a path a mktemp that $2 merely printed"
}
mt_probe 1 'prints a plausible path and then fails'
mt_probe 0 'prints a path it never created'
rm -f "$MTP/bin/mktemp"

# The CALL SITE, not just the helper. Everything above still passes if the two
# lines that acquire `TMP_CL` are put back the way they were, because a working
# `mktemp` never reaches the guard — the helper is proven and the caller is not.
# So the guard is exercised where it lives: this file is re-run against a `mktemp`
# it cannot trust, and it has to stop before anything is written.
#
# BOTH untrustworthy shapes, because only one of them separates the two
# regressions. A `mktemp` that FAILS is rejected by a bare `mktemp -d` with a
# status guard just as well as by `mktemp_d`, so that case alone leaves the
# status-guarded bare form indistinguishable from the fix. A `mktemp` that prints
# an absolute path it never created and returns 0 is the one only validation
# catches — and it is not hypothetical, it is what a `mktemp` racing a cleaner or
# a broken $TMPDIR does.
#
# `mkdir` and `ln` are stubbed to RECORD rather than act. What the unfixed form
# does is write fixture symlinks into `/bin`, and performing that in order to
# detect it is not a trade this suite can make; an empty record is the same
# evidence at no risk. The child skips this block, so a regression that lets it
# past the guard cannot recurse.
if [ -z "${CONTRACT_SCRATCH_PROBE-}" ]; then
    SPB="$TMP_CL/probe/bin"; mkdir -p "$SPB"
    sp_probe() {   # sp_probe <stub exit status> <what the case is>
        local wit out rc
        wit="$TMP_CL/probe/writes$1"; rc=0
        printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$wit" \
            > "$SPB/mkdir"
        cp "$SPB/mkdir" "$SPB/ln"
        # The path the stub prints is absolute, plausible, and NEVER CREATED —
        # the whole point of the second case.
        printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit %s\n' \
            "$TMP_CL/probe/never-made" "$1" > "$SPB/mktemp"
        chmod +x "$SPB/mkdir" "$SPB/ln" "$SPB/mktemp"
        # `run_limited <secs> env …`, so the stub PATH reaches the SUBJECT and not
        # the watchdog. Written the other way round first, and `test-testlib.sh`
        # caught it: `run_limited`'s own fallback shells out to `mktemp`, which
        # here is a stubbed one — the watchdog would have returned 125 without
        # running this file at all, and the guard would have been asserting about
        # nothing. The environment belongs to the thing under test.
        out="$(run_limited 300 env CONTRACT_SCRATCH_PROBE=1 PATH="$SPB:$PATH" \
            bash "${BASH_SOURCE[0]}" 2>&1)" || rc=$?
        { [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 125 ] \
            && grep -qF 'no scratch directory for the counter fixture' <<<"$out" \
            && grep -qF 'RESULT: FAIL' <<<"$out"; } \
            && pass "a mktemp that $2 stops this file rather than being recorded" \
            || die "a mktemp that $2 did not stop this file (rc=$rc)"
        # The whole point: `die` would have let it carry on with an unusable
        # `TMP_CL`, and every `$TMP_CL/…` under it then resolves somewhere else.
        [ ! -s "$wit" ] \
            && pass "…and it creates nothing under a path it was handed" \
            || die "the run wrote after a mktemp that $2: $(tr '\n' ';' <"$wit")"
    }
    sp_probe 1 'prints a plausible path and then fails'
    sp_probe 0 'prints a path it never created and succeeds'

    # THE CLEANUP, observed rather than assumed. Nothing above looks at `$TMP_CL`
    # after the process is gone, so deleting the EXIT trap — or making it a no-op —
    # left the suite green while every run leaked a scratch tree again. Cleanup was
    # a deliberate change in this commit, so it gets an assertion like any other.
    #
    # The child is given its own $TMPDIR, which is the only way to learn where its
    # scratch went without the child having to report it: whatever `mktemp` gave it
    # is under this directory, so "the trap ran" and "this directory is empty" are
    # the same statement. It runs to completion with a real `mktemp` — that is the
    # path where a leak actually happens.
    CTD="$TMP_CL/tdir"; mkdir -p "$CTD"
    cln_rc=0
    run_limited 300 env CONTRACT_SCRATCH_PROBE=1 TMPDIR="$CTD" \
        bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 || cln_rc=$?
    # THREE ways this can go wrong, reported apart, and the scan has its own.
    #
    # Folded into one condition, a child that failed for a reason of its own — any
    # other assertion in this file — was announced as a LEAK. Splitting the child
    # out left the scan still folded in: `|| cln_left='THE_SCAN_FAILED'` turns an
    # unreadable directory into an ENTRY, so a scan that could not run was reported
    # as a leak of a file by that name, sending the reader to the EXIT trap instead
    # of to the scanner. A substituted sentinel is only a sentinel if the branch
    # reading it treats it as one; consumed as data it is a plausible value, which
    # is the failure this whole file is about.
    #
    # `report_cleanup` returns the verdict, so every branch can be EXERCISED. The
    # branch nobody runs is the branch that breaks — the same reason
    # `test-testlib.sh` made its own reporting a function.
    scan_scratch() {   # scan_scratch <dir> ; prints the entries, 2 if it could not
        local out
        out="$(ls -A "$1" 2>/dev/null)" || return 2
        printf '%s' "$out"
        return 0
    }
    report_cleanup() {   # <child rc> <dir> ; 0 clean, 1 leaked, 2 child failed, 3 scan failed
        local rc="$1" left srx
        [ "$rc" -eq 0 ] || return 2
        srx=0
        left="$(scan_scratch "$2")" || srx=$?
        [ "$srx" -eq 0 ] || return 3
        [ -n "$left" ] || return 0
        printf '%s' "$left"
        return 1
    }
    # THE DIAGNOSTIC IS THE PRODUCT, so it is what gets asserted. A numeric verdict
    # checked in isolation leaves the dispatch below untested: swap the scan-failure
    # text for the leak text and every status still matches, while an unreadable
    # directory once again sends the author to the EXIT trap. The whole point of
    # this round's split was WHICH CAUSE IS NAMED — so the fixture reads the name.
    cleanup_diagnostic() {   # <verdict> <child rc> <entries> ; the message, 0 if clean
        case "$1" in
            0) printf 'a completed run removes its scratch tree rather than leaking it'
               return 0 ;;
            1) printf "a run left its scratch tree behind ('%s')" "$3"; return 1 ;;
            2) printf "the cleanup probe's own run failed (rc=%s); the leak check proves nothing" "$2"
               return 1 ;;
            *) printf 'the scratch directory could not be scanned; the leak check proves nothing'
               return 1 ;;
        esac
    }
    # One entry point, used by the fixture and by the real check alike — otherwise
    # the fixture exercises a copy of the dispatch rather than the dispatch.
    cleanup_verdict() {   # <child rc> <dir> ; prints the diagnostic, 0 if clean
        local v left
        v=0
        left="$(report_cleanup "$1" "$2")" || v=$?
        cleanup_diagnostic "$v" "$1" "$left"
    }
    mkdir -p "$TMP_CL/probe/leaky/tmp.XXXXXX" "$TMP_CL/probe/emptied"
    while IFS='|' read -r want crc where needle what; do
        [ -n "$want" ] || continue
        got=0; msg="$(cleanup_verdict "$crc" "$TMP_CL/probe/$where")" || got=$?
        { [ "$got" = "$want" ] && grep -qF "$needle" <<<"$msg"; } \
            && pass "$what is named as itself, not as another cause" \
            || die "$what reported rc=$got '$msg' (wanted $want naming '$needle')"
    done <<'CLCASES'
0|0|emptied|removes its scratch tree|a run that cleaned up
1|0|leaky|left its scratch tree behind ('tmp.XXXXXX')|a directory holding a leaked tree
1|1|tdir|own run failed (rc=1)|a child run that failed
1|0|never-scanned|could not be scanned|a directory that cannot be scanned
CLCASES
    cln_msg="$(cleanup_verdict "$cln_rc" "$CTD")" && pass "$cln_msg" || die "$cln_msg"
fi
cl_req() {   # cl_req <fixed-string> <what it guarantees> <what its absence means>
    grep -qF "$1" <<<"$cl_202" \
        && pass "the release entry $2" \
        || die "the release entry $3"
}
cl_absent() {   # cl_absent <pattern> <what its presence means>
    local rc=0
    grep -qiE "$1" <<<"$cl_202" || rc=$?
    case "$rc" in
        0) die "the release entry $2" ;;
        1) pass "…and does not $2" ;;
        *) die "the scan for '$2' could not be completed" ;;
    esac
}
# …and that guard is exercised, not merely written. A counter that prints a
# plausible number before failing is the shape that made this fail open, so the
# fixture runs `count_claims` under exactly that.
CNTB="$TMP_CL/bin"; mkdir -p "$CNTB"
for b in bash sh grep printf cat rm; do
    _p="$(command -v "$b" 2>/dev/null)" && ln -sf "$_p" "$CNTB/$b"
done
# The class is REMOVED, so the fixture proves independence rather than detection:
# with no `wc` and no `tr` on the PATH at all, the count must still be right. A
# guard against a failing counter would only have held under `pipefail`; not
# needing the counter holds everywhere.
cnt_out="$(PATH="$CNTB" bash -c '
'"$(declare -f count_claims)"'
count_claims "defect" "a defect and another defect"; echo "|rc=$?"' 2>&1)"
case "$cnt_out" in
    '2|rc=0') pass "the count needs no external counter, so a failing one cannot corrupt it" ;;
    *) die "count_claims depends on an external counter ('$cnt_out')" ;;
esac
# The control: with a working counter the same call must still count.
cnt_ok="$(bash -c '
'"$(declare -f count_claims)"'
count_claims "defect" "a defect and another defect"' 2>&1)"
[ "$cnt_ok" = "2" ] \
    && pass "…while a working counter still counts both mentions" \
    || die "count_claims miscounted a known input ('$cnt_ok')"

cl_req 'repairing a consumer a changed validator or producer breaks is finishing the change' \
    'keeps the regression exception to the scope rule' \
    'would have a reader reject a required regression repair'
cl_req 'explains rather than accepts' \
    'says the at-the-site comment explains rather than accepts' \
    'still teaches that an author-created comment is authority'
# The claims stated TWICE in this entry, counted rather than merely present.
# THE TOTAL RECOGNISES THE CLAIM BY ITS SUBJECT, NEVER BY ITS OUTCOME. This is the
# counting equivalent of the polarity trap the whitelists replaced: a total pattern
# reading `defect … stays out of scope` stops matching the moment the entry says
# `stays IN scope`, so the reversed mention leaves BOTH counts, the survivors stay
# equal, and the suite reports clean on a release note that now directs the session
# to widen the PR. The total asks only "is the claim mentioned here"; the qualifier
# asks "does this mention still say the right thing". A total that embeds the
# answer cannot see the mention that got it wrong.
#
# Three mentions of the pre-existing boundary, not two — the `copy in an untouched
# file` form was outside both patterns, so reversing that one counted as nothing.
cl_count '\*{0,2}different pre-existing\*{0,2} (defect|copy)[^.]{0,60}' \
         '\*{0,2}different pre-existing\*{0,2} (defect stays out of scope|copy in an untouched file stays out|defect found nearby is not in scope)' \
         'a different pre-existing defect is OUT of scope'
# THREE mentions, not two. The third — "the same defect in another copy is the
# same finding" — was outside both patterns, so it counted as neither claim nor
# qualifier and the two recognised mentions stayed equal: removing or reversing
# that boundary left the entry stating an unbounded scope rule with the mandatory
# suite reporting clean. A count only guards the occurrences it can see, which is
# the same "somewhere in the file" weakness one level up.
# …and the qualifier requires the POSITIVE OUTCOME, not merely the boundary. Every
# form here named where the copy is and none named what happens to it, so "is part
# of the finding" flipping to "is NOT part of the finding" left the diff bound
# intact, the counts equal at 3/3, and the entry telling the driver to skip an
# in-diff twin — the one thing this rule exists to require.
cl_count '(same defect in a copy|copy of the same defect|same defect in another copy)[^.]{0,80}' \
         '(same defect in a copy this PR also changes is part of the finding and gets fixed with it|A finding names[^.]{0,150}second copy of the same defect \*\*that this PR also changes\*\*|same defect in another copy is the same finding[^.]{0,40}only within what this PR already changes)' \
         'the second-copy requirement is bounded to the diff AND in it'
# The same polarity-free total here. `is a finding` embedded the outcome, so
# `is not a finding` was invisible to the count — the identical defect one call
# down, in a line this PR adds, which makes it part of this finding rather than a
# separate one to defer.
cl_count 'a wrong reply (on an old thread )?is[^.]{0,20}finding[^.]{0,80}' \
         'a wrong reply (on an old thread )?is a finding \*{0,2}only when (its error means )?the (changed )?code is still[[:space:]]*defective' \
         'a wrong reply is a finding only when the CODE is still defective'
# …and the superseded wordings must be absent, because a qualifier present in one
# bullet says nothing about another two paragraphs down.
cl_absent 'defect found nearby is never in scope' 'still says a nearby defect is never in scope'
cl_absent 'a wrong reply is itself a finding'     'still says a wrong reply is itself a finding'
cl_absent 'any second copy of the same defect[.,]( |$)' 'still requires naming a copy outside the diff'
# THE POSITIVE ACCOUNT. Forbidding one phrasing is a blacklist, and "No operational
# behavior changes; this only updates documentation" evades it while making exactly
# the claim that was wrong. The entry has to SAY both halves: which layer is
# unchanged, and that session behaviour is not.
grep -qF 'No **shell-script logic** changes' <<<"$cl_202" \
    && pass "the release entry names the layer that is unchanged" \
    || die "the release entry does not say what is actually unchanged"
grep -qF 'so this release does change how a session behaves' <<<"$cl_202" \
    && pass "…and states that session behaviour does change" \
    || die "the release entry does not say the driver contract changed behaviour"

grep -q 'disposition, never as a description' "$SKILL" \
    && pass "deferrals are recorded as a disposition, not a description" \
    || die "the contract invites a summary that reads as a work order"
# …and NO copy of the summary rule may ask for the reasoning. "what was skipped,
# and why" invites the unfixed defect into the mention, which is the work order.
# Three files carried that wording; fixing one and not the others is how a rule
# survives being reconciled.
# CHANGELOG.md is NOT in this list, and adding it was a mistake I made and am
# undoing: a changelog has to be able to QUOTE a superseded directive in order to
# explain the failure that was fixed — "the old contract said the summary explains
# why" is exactly the sentence a release note needs — and a whole-file ban would
# fail the mandatory suite for describing history correctly. Its current entry is
# checked below instead, positively and scoped to that entry.
for doc in "$SKILL" "$SCRIPT_DIR/../../../CLAUDE.md" "$SCRIPT_DIR/../../../README.md"; do
    [ -f "$doc" ] || { die "missing instruction file: $doc"; continue; }
    dname="$(basename "$doc")"
    dflat="$(tr '\n' ' ' < "$doc" | tr -s ' ')" || { die "$dname: could not read"; continue; }
    # A SET of phrasings, not one literal. The first version matched only
    # `intentionally skipped, and why`, and a third copy of the rule was worded
    # differently — "the summary explains why" — so the check could not see it.
    # Three rounds of this PR each found one more copy; the pattern list is what
    # each of them added, and a new phrasing belongs here rather than being
    # noticed by a reviewer for a fourth time.
    # The pattern set grew again: a fourth copy asked the summary to argue for a
    # BROADER FIX — a design proposal rather than a reason for a skip, different
    # wording, same outcome, because anything in the mention that describes work
    # to be done is read as a work order.
    #
    # Deliberately NOT matched: "say so in the summary" where what is said is a
    # past-tense fact about this round's own checks — the self-check reporting it
    # had nothing in scope. That cannot become a work order, and widening the
    # pattern to catch it would forbid the summary from doing its job.
    dir_rc=0
    grep -qiE \
        'skipped, and why|summary explains why|explains? why it was (skipped|deferred|left)|and why it was (skipped|deferred|left)|(warranted|broader fix)[^.]{0,60}say so in the summary|(the )?(reason|rationale)[^.]{0,40}(not applied|was skipped|for skipping|it was left)' \
        <<<"$dflat" || dir_rc=$?
    case "$dir_rc" in
        0) die "$dname: still asks the summary to explain something that was not done" ;;
        1) pass "$dname: does not invite the deferred defect into the summary" ;;
        *) die "$dname: the summary-directive scan could not be completed" ;;
    esac
done

# ── both reviewer files carry the same context and finding-quality rules ───
# `.github/copilot-instructions.md` restates the policy inline because Copilot
# reads only that file and does not follow pointers, so a rule added to AGENTS.md
# alone reaches one reviewer of two. That asymmetry is the documented reason the
# duplicate exists, which makes it exactly the thing that drifts.
for doc in "$SCRIPT_DIR/../../../AGENTS.md" "$SCRIPT_DIR/../../../.github/copilot-instructions.md"; do
    [ -f "$doc" ] || { die "missing reviewer instruction file: $doc"; continue; }
    name="$(basename "$doc")"
    # DISTINGUISHING text, not a phrase the file already contained. `resolved
    # threads` matched `AGENTS.md`'"'"'s "zero unresolved threads" and the Copilot
    # file'"'"'s "Waivers and resolved threads" heading, so this pair of assertions
    # passed with the reply-context paragraph deleted from both — a guard for
    # duplicate drift that could not see the duplicate drift.
    # FLATTENED before matching. These files are wrapped prose, so a phrase that
    # spans a line break is invisible to line-based grep — the first version of
    # these assertions failed on correct text for exactly that reason.
    flat="$(tr '\n' ' ' < "$doc" | tr -s ' ')" || { die "$name: could not read"; continue; }
    grep -qi 'replies on .*resolved threads' <<<"$flat" \
        && pass "$name: earlier-round replies are named as context" \
        || die "$name: does not tell the reviewer to read earlier thread replies"
    # The PREDICATE, not the phrase: "changed code is still" alone is satisfied by
    # "…is still correct", which reverses the rule while matching the check.
    grep -qi 'changed code is still[[:space:]]*defective' <<<"$flat" \
        && pass "$name: a wrong reply is a finding only if the code is still DEFECTIVE" \
        || die "$name: would have the reviewer block a merge to correct the record"
    # THE CANONICAL CLAUSE, VERBATIM — the prose analogue of the whitelist that
    # settled the endpoint guard.
    #
    # Positive patterns plus negation scans do not converge here. "Include the
    # triggering input" was defeated by "do not include…", then by "include
    # neither… nor…", and "naming any second copy" by "avoid naming…" and then by
    # "omit naming…". Each fix enumerated one more way to negate, and English has
    # no bounded list of those — the same wall the route and command blacklists
    # hit, with no whitelist of commands available because the subject is meaning.
    #
    # What IS bounded is the sentence itself. Requiring the exact clause makes any
    # alteration fail — negated, reworded, or weakened — and the cost is precisely
    # the property wanted for contract text: changing it is a deliberate act that
    # updates this list, not a quiet edit that still satisfies a pattern.
    case "$name" in
        AGENTS.md)
            req_clauses=(
                'the input or state that triggers it** — the concrete case, not the category'
                '**the consequence** — what ends up wrong, in terms of what this tool does'
                'The author is expected to assert the consequence in a test, and can only do that if you state it'
                'if the same defect exists in a second copy **that this PR also changes**, say so'
            ) ;;
        copilot-instructions.md)
            req_clauses=(
                'Include the input or state that triggers it — **the concrete case, not the category**'
                'the **consequence** in terms of what this tool does'
                'the author is expected to assert that consequence in a test'
                'naming any second copy of the same defect **that this PR also changes**'
            ) ;;
        *) req_clauses=() ;;
    esac
    for clause in ${req_clauses+"${req_clauses[@]}"}; do
        grep -qF "$clause" <<<"$flat" \
            && pass "$name: states verbatim — ${clause:0:52}…" \
            || die "$name: this required clause is altered or missing — ${clause:0:52}…"
    done
    grep -qi 'proposal, not the finding' <<<"$flat" \
        && pass "$name: a code suggestion is a proposal, not the finding" \
        || die "$name: does not say a code suggestion is only a proposal"
done

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
