#!/usr/bin/env bash
# Unit tests for pr-ci-gate.sh.
#
# THESE CASES ARE NOT NEW. They lived in `test-pr-skill-contract.sh`, where the
# gate was a shell FUNCTION inside a fenced block in `SKILL.md` and the only way
# to execute it was to `sed` it back out of the document. Every one of them was
# written because a grep had passed while the behaviour was wrong — the presence
# of a `PR_CI_TIMEOUT` says nothing about what is done with a pending verdict.
#
# Now the gate is a script, so they run it. That is the whole argument of issue
# #26 in one file: the same assertions, against the real subject, with no
# extraction step that can silently stop finding it.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Portable watchdog: stock macOS ships no GNU `timeout`, and the suite is a
# mandatory pre-push gate.
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-ci-gate.sh"

TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# ── THE ARGUMENTS ARE THE CONTRACT NOW ─────────────────────────────────────
# As a function it took whatever the call site in the prose happened to pass, and
# a missing argument became an empty string that `pr-ci-state.sh` rejected — the
# gate then reported "could not establish the check state", which names the wrong
# cause and sends the reader to the API. A script can say what its caller did.
arg_case() {   # arg_case <label> [args…]
    local out rc=0 label="$1"
    shift
    out="$(run_limited 10 "$SCRIPT" "$@" 2>&1)" || rc=$?
    { [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'the CI gate needs'; } \
        && pass "$label" \
        || die "$label — rc=$rc out='$out'"
}
# ── A BROKEN LIBRARY EXPLAINS ITSELF ON STDOUT ─────────────────────────────
# The gate's diagnostics are documented as stdout, and the four call sites read
# them from there. `rb_load` reports on stderr, so a `recordlib.sh` that is empty —
# or missing, or unreadable — used to exit non-zero with NOTHING on stdout: the one
# failure that happens before the gate can say anything else was the one a caller
# capturing its output could not see. STDOUT IS CAPTURED ALONE here, with stderr
# discarded, because merging the two is exactly the mistake that would make this
# pass while the defect stood.
lib_case() {   # lib_case <what to do to recordlib.sh> <label>
    local dir out rc=0
    dir="$(mktemp_d)" || { die "no scratch directory for the library probe"; return 0; }
    cp "$SCRIPT" "$SELF_DIR/loadlib.sh" "$dir/" || { die "the library probe could not be set up"; return 0; }
    case "$1" in
        empty)   : > "$dir/recordlib.sh" ;;
        missing) : ;;
    esac
    out="$(cd "$dir" && run_limited 10 ./pr-ci-gate.sh 7 \
        0123456789abcdef0123456789abcdef01234567 2>/dev/null)" || rc=$?
    { [ "$rc" -ne 0 ] && [ -n "$out" ]; } \
        && pass "$2" \
        || die "$2 — rc=$rc stdout='$out'"
    rm -rf "$dir"
}
lib_case empty   "an empty recordlib.sh is explained on stdout, not only on stderr"
lib_case missing "…and so is a missing one"

arg_case "no arguments at all are refused, by name"
arg_case "a missing head oid is refused, by name" 7
arg_case "a non-numeric PR is refused, by name" seven 0123456789abcdef0123456789abcdef01234567
arg_case "a head that is not hex is refused, by name" 7 not-a-sha

GATETMP="$TMP/gate"
mkdir -p "$GATETMP/s" || { die "no scratch directory for the CI gate probe"; }
if [ -d "$GATETMP/s" ]; then
    # THE SUBJECT IS COPIED IN BESIDE THE STUB, because the gate finds
    # `pr-ci-state.sh` next to ITSELF rather than through `RB_SCRIPTS`. That is the
    # point of the move: a script locates its siblings, where a function pasted into
    # someone else's shell had to be told where they were.
    # …AND ITS LIBRARIES WITH IT. The gate loads `recordlib.sh` and `clocklib.sh`
    # through `rb_load`
    # for the one definition of "a full commit SHA", and both are found beside the
    # script — so a probe directory holding only the subject makes every case fail
    # on a missing library rather than on the behaviour it is asserting.
    cp "$SCRIPT" "$SELF_DIR/loadlib.sh" "$SELF_DIR/recordlib.sh" "$SELF_DIR/clocklib.sh" "$GATETMP/s/" \
        || die "the gate could not be copied into the probe directory"
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
    # ── TIME THE GATE BELIEVES IN, WITHOUT WAITING FOR IT ──────────────────
    # `pr-ci-gate.sh` reads the clock through `clocklib.sh`, which runs `date +%s`,
    # and paces itself with `sleep` — both external commands since #66, so the
    # fixture owns them without the subject changing at all. `sleep N` ADVANCES the
    # clock by N and returns at once; `date` reports it. Time then passes exactly
    # when the gate decides to wait, which is what makes the deadline cases below
    # exact rather than a race against however loaded the runner is (#38).
    #
    # A FRACTIONAL SLEEP IS NOT PACING and really sleeps. `pr-ci-state.sh` and the
    # watchdog tick in fractions to yield to real children; treating those as a
    # no-op let a tick loop spend its whole budget in microseconds and kill a
    # healthy helper — the load-dependent failure this is meant to REMOVE.
    #
    # Resolved BEFORE the stub directory is on any PATH, and asserted: a stub that
    # cannot find the real thing would silently become the no-op this avoids.
    GATECLOCK="$GATETMP/fastclock"; mkdir -p "$GATECLOCK"
    GATE_NOW="$GATETMP/now"
    REAL_SLEEP="$(command -v sleep)" \
        || { printf 'FAIL - no sleep on PATH\n'; echo "RESULT: FAIL"; exit 1; }
    cat > "$GATECLOCK/sleep" <<SLEEPSH
#!/usr/bin/env bash
case "\${1:-}" in
    [0-9]*.[0-9]*) exec "$REAL_SLEEP" 0.05 ;;
    ''|*[!0-9]*)   exec "$REAL_SLEEP" "\$@" ;;
esac
_c="\$(cat "\$FAKE_NOW" 2>/dev/null || echo 0)"
printf '%s\n' "\$((_c + \$1))" > "\$FAKE_NOW"
exit 0
SLEEPSH
    cat > "$GATECLOCK/date" <<'DATESH'
#!/usr/bin/env bash
# Only `+%s` is faked, so anything formatting a date for a human still gets a
# real one.
case "${1:-}" in
    +%s) cat "$FAKE_NOW" 2>/dev/null || exit 1 ;;
    *)   exec /usr/bin/env -u PATH /bin/date "$@" ;;
esac
DATESH
    chmod +x "$GATECLOCK/sleep" "$GATECLOCK/date"

    gate_case() {   # gate_case <queue> <want rc> <want calls> <label> [env…]
        local out rc=0 calls q="$1" want="$2" mincalls="$3" label="$4"
        shift 4
        printf '%s\n' "$q" > "$GATETMP/q"; : > "$GATETMP/calls"
        : > "$GATETMP/last"
        : > "$GATETMP/probe"
        # THE CLOCK STARTS AT THE SAME PLACE EVERY CASE, or a case inherits the
        # time the one before it spent and its deadline arrives early.
        printf '1754000000\n' > "$GATE_NOW"
        out="$(run_limited 20 env PATH="$GATECLOCK:$PATH" FAKE_NOW="$GATE_NOW" \
            GATE_Q="$GATETMP/q" GATE_CALLS="$GATETMP/calls" \
            GATE_LAST="$GATETMP/last" GATE_PROBE="$GATETMP/probe" \
            PR_CI_INTERVAL=1 PR_CI_TIMEOUT=5 PR_CI_GRACE=2 "$@" \
            "$GATETMP/s/pr-ci-gate.sh" 7 0123456789abcdef0123456789abcdef01234567 2>&1)" || rc=$?
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
    # EXACTLY ONE, not at most one. Two is what the clamp produced — probe, sleep
    # onto the deadline, probe again, and only then notice — and ZERO is a gate
    # that never probed at all, which `-le` accepted as success. Both are now
    # excluded, and the count is a fact rather than a bound because the fixture
    # owns the clock: time moves only when the gate sleeps, so nothing the runner
    # is doing can change it.
    [ "${probes_after:-0}" -eq 1 ] \
        && pass "…so an expired gate makes exactly the one request it had time for" \
        || die "the gate made $probes_after requests around its deadline (wanted 1)"
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
    #
    # THE CEILING CARRIES ONLY THE FIRST OF THE THREE. `PR_CI_INTERVAL=0` is the
    # one that spins — 569 polls unguarded — and a ceiling sees that. The other two
    # do not spin at all when their guard is removed, so until #50 they asserted
    # nothing: `PR_CI_INTERVAL=soon` leaves the sleep unclamped and polls
    # ONCE, and `PR_CI_TIMEOUT=soon` dies on `set -u` before its FIRST poll. Both
    # were comfortably under the ceiling, and both passed for the opposite of the
    # reason they name. The two assertions in `gate_spin` below are what actually
    # separates a paced gate from a dead one; this ceiling remains the one that
    # catches the spin.
    #
    # THE CEILING'S OWN SIZING, NOT THE LENGTH OF THE WINDOW. The documented
    # fallback is thirty seconds, so inside a six-second window a gate that
    # applied it polls EXACTLY ONCE — it polls, sleeps thirty, and the watchdog
    # stops it. A second poll inside the window means the interval was at most
    # five seconds, and that fails here.
    #
    # A CEILING OF FOUR IN A TWELVE-SECOND WINDOW WAS THE WEAKER TEST, not the
    # stronger one. It rejected a fallback of three seconds or less and ACCEPTED
    # a regression to four, while costing twice the wall clock; this rejects four
    # and five as well. Measured, at each value, against a fallback mutated from
    # thirty: 0 spins to 569 polls, 1 gives 5, and 3, 4 and 5 give 2 — all
    # rejected — while 6 gives 1, which is where it stops seeing them.
    #
    # THE WINDOW IS THE BOUNDARY PLUS HEADROOM, and the headroom is why it is six
    # rather than five. At the boundary the second poll lands one interval in, so
    # a window equal to the interval leaves it racing the watchdog against
    # whatever the first probe and the fixture's own bookkeeping cost — on a
    # loaded runner the mutant then survives and the case reports PASS. What is
    # claimed above is therefore what the window rejects with a second to spare,
    # not what it rejects at exactly the deadline.
    #
    # The headroom the OLD CEILING bought is a different thing, and nothing needs
    # it: one poll per window is not a race, because the second poll cannot
    # happen until the interval has elapsed.
    #
    # The window is a variable so the diagnostic cannot drift from the bound it
    # reports — they were two literals, and only one of them would have been
    # changed here.
    gate_spin() {   # gate_spin <max calls> <label> [env…]
        local out rc=0 calls maxc="$1" label="$2" win=6
        shift 2
        printf '3\n' > "$GATETMP/q"; : > "$GATETMP/calls"; : > "$GATETMP/last"
        : > "$GATETMP/probe"
        out="$(run_limited "$win" env GATE_Q="$GATETMP/q" GATE_CALLS="$GATETMP/calls" \
            GATE_LAST="$GATETMP/last" GATE_PROBE="$GATETMP/probe" "$@" \
            "$GATETMP/s/pr-ci-gate.sh" 7 0123456789abcdef0123456789abcdef01234567 2>&1)" || rc=$?
        calls="$(grep -c call "$GATETMP/calls" 2>/dev/null)" || calls=0
        [ "${calls:-0}" -le "$maxc" ] \
            && pass "$label" \
            || die "$label — $calls polls in ${win}s (at most $maxc); the bound was not applied"
        # THE POLL COUNT ALONE ACCEPTED A GATE THAT HAD DIED, and two of the three
        # cases below rested on it entirely — #50. A gate that stops on its first
        # iteration polls once, which is under any ceiling, so "few polls" is
        # satisfied by pacing and by death alike. What separates them is that a
        # PACED gate is still waiting when the window closes, and the watchdog is
        # what ends it: rc=124, from either arm of `run_limited`.
        [ "$rc" = 124 ] \
            && pass "…and it was still waiting when the window closed" \
            || die "$label — exited rc=$rc inside ${win}s; it stopped rather than pacing"
        # …AND THE ABSENCE CHECK AS WELL AS, NEVER INSTEAD OF, THAT. An unvalidated
        # bound reaches the shell as an operand and the shell complains on stderr,
        # which moves no counter — so the poll ceiling and the status above can
        # both pass while the guard is gone.
        #
        # THE WORDING IS NOT MATCHED, AND THAT IS THE POINT. The first version of
        # this looked for `integer expected`, which is what bash 5.3 prints here;
        # `integer expression expected` is also in the wild, the message is
        # LOCALISED, and `set -u` produces a different one again. Enumerating them
        # is a list wrong by omission, and a missed spelling makes this check
        # report clean over the defect it exists to catch.
        #
        # What does not vary is that a gate pacing correctly says NOTHING here: it
        # is mid-wait when the watchdog ends it. Any diagnostic at all, in any
        # wording, fails — and if some future change makes a silent run legitimate,
        # it fails loudly rather than quietly accepting one.
        [ -z "$out" ] \
            && pass "…and it printed nothing, so no bound reached the shell raw" \
            || die "$label — the gate wrote to stderr, so a bound was not validated: $out"
    }
    gate_spin 1 "a zero interval falls back rather than spinning against the API" PR_CI_INTERVAL=0
    gate_spin 1 "…and so does a non-numeric interval" PR_CI_INTERVAL=soon
    gate_spin 1 "…and a non-numeric timeout does not remove the pacing" PR_CI_TIMEOUT=soon
    # ── A CLOCK THAT FAILS MID-GATE STOPS THE ROUND ────────────────────────
    # `pr-ci-gate.sh` measures elapsed time through `clocklib.sh` rather than
    # `$SECONDS` (#66), so it has a runtime failure it never had: the clock can
    # refuse. `test-clocklib.sh` proves the library returns non-zero and
    # `test-pr-identity.sh` proves an EMPTY library is refused; neither would fail
    # if the gate stopped honouring that status mid-poll and carried on with a
    # stale elapsed count — which is the unbounded loop the bound exists to stop.
    #
    # The stub answers once and then breaks, so the failure lands AFTER a
    # successful start: `date` prints a plausible epoch and exits non-zero, which
    # command substitution keeps, and a backward step is the other shape.
    # BOTH PLACES THE GATE READS THE CLOCK, because they are separate branches:
    # `good=1` breaks the reading at the top of the loop, before any probe, and
    # `good=2` breaks the one AFTER a probe has been made — where a gate that
    # ignored the status would accept that probe's verdict on a stale elapsed
    # count, which is the bound not binding.
    clock_case() {   # clock_case <mode> <good-readings> <want-calls> <label>
        local mode="$1" good="$2" wantcalls="$3" label="$4" out rc=0 calls
        printf '3\n' > "$GATETMP/q"; : > "$GATETMP/calls"; : > "$GATETMP/last"
        : > "$GATETMP/probe"; printf '0\n' > "$GATETMP/clockn"
        mkdir -p "$GATETMP/bin"
        cat > "$GATETMP/bin/date" <<DATESH
#!/usr/bin/env bash
case "\${1:-}" in
    +%s) ;;
    *)   exec /usr/bin/env -u PATH /bin/date "\$@" ;;
esac
n=\$(cat "$GATETMP/clockn" 2>/dev/null || echo 0)
printf '%s\\n' "\$((n + 1))" > "$GATETMP/clockn"
if [ "\$n" -lt $good ]; then printf '%s\\n' "\$((1754000000 + \$n))"; exit 0; fi
case "$mode" in
    fails)    printf '1754000001\\n'; exit 3 ;;
    backward) printf '1753999000\\n'; exit 0 ;;
esac
DATESH
        chmod +x "$GATETMP/bin/date"
        out="$(run_limited 20 env PATH="$GATETMP/bin:$PATH" \
            GATE_Q="$GATETMP/q" GATE_CALLS="$GATETMP/calls" GATE_LAST="$GATETMP/last" \
            GATE_PROBE="$GATETMP/probe" PR_CI_INTERVAL=1 PR_CI_TIMEOUT=5 PR_CI_GRACE=2 \
            "$GATETMP/s/pr-ci-gate.sh" 7 0123456789abcdef0123456789abcdef01234567 2>&1)" || rc=$?
        calls="$(grep -c call "$GATETMP/calls" 2>/dev/null)" || calls=0
        { [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'clock'; } \
            && pass "$label" \
            || die "$label — rc=$rc out='$out' (wanted 1 and a clock refusal)"
        [ "${calls:-0}" -eq "$wantcalls" ] \
            && pass "…and it made no request after the clock failed ($calls)" \
            || die "$label — made $calls requests on a broken clock (wanted $wantcalls)"
        rm -rf "$GATETMP/bin"
    }
    clock_case fails    1 0 "a clock that prints and then fails stops the round"
    clock_case fails    2 1 "…and one that fails after a probe, before its verdict is used"
    clock_case backward 1 0 "…and one that steps backward"
    clock_case backward 2 1 "…and one that steps backward after a probe"
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
fi
if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
