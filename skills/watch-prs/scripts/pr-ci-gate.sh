#!/usr/bin/env -S bash -p
# Wait until this PR's checks have settled on the head that was just pushed, and
# say whether the round may close.
#
#   pr-ci-gate.sh <pr> <head-oid>
#
#   0  carry on — the checks are green, or there are none configured
#   1  stop     — red, timed out, or the state could not be established
#
# WHY THIS EXISTS AS A SCRIPT
#
# It was a shell FUNCTION defined inside a fenced block in `SKILL.md`, pasted into
# the driving session's own shell and called from four sites. That cost three
# things, and all three are gone with the move:
#
#   - IT WAS UNCHECKED. Everything under this directory is covered by the suite,
#     by `pr-selfcheck.sh` — which requires a test per script — and by the
#     `macos-shell` CI job when that job is enabled, which it is not while #93
#     stands. Shell inside a Markdown file is covered by none of them, and reaching it means parsing Markdown, which was tried and deleted
#     (issue #26, PR #25). `test-pr-skill-contract.sh` had resorted to `sed`-ing
#     the function out of the document to execute it.
#   - IT NEEDED A GUARD DANCE. A function pasted into a session that may already
#     have one has to `unset -f` first, check that the unset worked because
#     `readonly -f` makes it fail silently, and then verify something got defined
#     at all. A stale gate returning 0 lets a red head close its round — the
#     defect the gate exists to prevent, arriving through the gate itself. A
#     script cannot be shadowed by a previous session, so none of that is needed.
#   - EVERY NAME IT ASSIGNED WAS A HAZARD. In the driver's shell an undeclared
#     variable is written into that session, clobbering whatever was there. Here
#     the process boundary does that job.
#
# WHAT DID NOT CHANGE is the contract: same two arguments, same environment
# knobs, same diagnostics on stdout, and 0/1 with the same meanings. EVERY
# diagnostic goes to stdout, including the ones about loading a library — the
# function printed on stdout and the four call sites were written against that, so
# a startup failure routed to stderr would be the one message a caller capturing
# the gate's output could not see. The four
# call sites in `SKILL.md` invoke this instead of calling a function, and read the
# status exactly as before.
#
# `set -uo pipefail`, NOT `-e`: the probe's exit status IS the control flow here —
# `pr-ci-state.sh` reports pending, none and stale as non-zero, and every one of
# them is an ordinary answer this loop acts on. See CLAUDE.md § Bash conventions.
# ── STARTED PRIVILEGED, OR NOT STARTED ─────────────────────────────────────
#
# The shebang above is `env -S bash -p`, and that is the defence this block
# exists to state. An ordinary `#!/usr/bin/env bash` SOURCES `BASH_ENV`, IMPORTS
# functions from the environment, and honours an exported `SHELLOPTS` — so every
# builtin this script uses is a name the operator's shell can replace, and each
# one found took a review round of its own: `type`, `return`, `set`, `echo`,
# `exit`. Privileged mode does none of the three, so there is nothing to shadow
# and nothing to clear. Measured: under `BASH_FUNC_echo%` and `BASH_FUNC_set%`,
# a privileged shell reports both as builtins.
#
# THE HOOK CANNOT BE OUT-RUN FROM IN HERE, which is why this is the shebang and
# not a re-exec. A `BASH_ENV` hook runs before this file's first line, and one
# that prints a forged `ABORT: the CI gate` line and exits has already answered the
# caller — no later re-exec takes that back. The interpreter has to be privileged
# from the start, which only the shebang or the caller can arrange.
#
# WHAT STARTS IT PRIVILEGED IS THE CALLER, AND THE SHEBANG IS THE FALLBACK.
# `SKILL.md` invokes every helper as `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-x.sh`,
# which starts a fresh privileged interpreter whatever the driving shell is and
# whatever that platform's `env` supports. The shebang covers the other way in —
# executing the file directly — and needs `env -S`, which is why it is not the
# thing relied on.
#
# `$-` IS A LAST-RESORT REFUSAL AND PROVES LESS THAN IT LOOKS. It reports the
# MODE this shell is in, not how it got there: run as `BASH_ENV=hook bash
# pr-x.sh`, the hook is sourced BEFORE this line and can itself run `set -p` and
# then define `echo` or `exit`, after which `$-` contains `p` and this test
# passes on a shell that has already executed hostile code. Nothing inside a
# script can detect work done before its first line — so this catches the honest
# mistake, and `bash pr-x.sh` is UNSUPPORTED rather than defended. Measured:
# `BASH_ENV=/tmp/h bash -c 'printf "%s %s" "$-" "$(type -t echo)"'` with a hook
# running `set -p; echo() { :; }` prints `hpBc function`.
if [[ $- != *p* ]]; then
    echo "ABORT: the CI gate reason=not_privileged"
    exit 1
fi

set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "ABORT: the CI gate could not resolve its own directory"; exit 1; }
# The library loader, loaded the one way it cannot load itself: clear, source,
# verify. An exported `rb_load` survives into this shell and an empty `loadlib.sh`
# still sources successfully, so without the clear the first load runs the INHERITED
# function — and a stale loader is what makes every other load look
# clean. See loadlib.sh and issue #22.
unset -f rb_load 2>/dev/null || {
    echo "ABORT: a pre-existing rb_load could not be cleared"; exit 1; }
# NO `type -t rb_load` PREFLIGHT. It verified the loader by asking `type`, which
# is a NAME — and while a privileged interpreter means no function by that name
# can be imported, verifying a thing by asking a second thing about it is the
# shape #88 is about: the answer is only as good as the asker. The FIRST LOAD is
# the verification instead, because calling an `rb_load` that does not exist
# fails, and that failure is the same one an empty library would produce.
#
# THE REFUSING STUB IS WHAT MAKES THAT TRUE. Without it, an `rb_load` that is not
# a function is looked up on `PATH` — privileged mode does not change `PATH` —
# and an executable by that name exiting 0 would report every load successful
# with nothing cleared and no library sourced. Defining it means the call cannot
# leave this shell: a good `loadlib.sh` replaces the stub when sourced, an empty
# one leaves the refusal. `return` is a builtin and nothing can shadow it here,
# because a privileged shell imports no functions. #88.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "ABORT: the library loader is unreadable"; exit 1; }
# `sha_reason` — ONE definition of "a full commit SHA" across the plugin. The
# first version of this script wrote the shape out as a `case` of its own, and
# `test-recordlib.sh`'s drift guard rejected it: a rule that applies to more than
# one helper lives in the library, because every field check here was originally
# written out two or three times and every one of them was then found missing from
# a copy. See CLAUDE.md § Tests.
# `2>&1` BECAUSE `rb_load` REPORTS ON STDERR, and the promise above is that every
# diagnostic reaches stdout. Moving this script's own echoes was not enough: a
# missing, unreadable or empty `recordlib.sh` produces its only explanation inside
# the loader, so a caller capturing stdout got an empty result and an exit status
# for the one failure that happens before anything else can.
# THE FIRST LOAD CARRIES THE SENTINEL, because it is what the preflight used to
# say. An empty `loadlib.sh` leaves the stub, the stub returns 127, and without
# this arm the only trace is a bare exit status — the ordinary-looking empty
# answer `CLAUDE.md` forbids. 127 is the stub's and nothing else's: `rb_load`'s
# own refusals report their own reason and their own status.
rb_load "$_RB_SELF_DIR" recordlib sha_reason "ABORT: the CI gate" 2>&1 || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "ABORT: the CI gate reason=loadlib_empty"
    exit 1; }
rb_load "$_RB_SELF_DIR" clocklib rb_elapsed "ABORT: the CI gate" 2>&1 || exit 1

pr="${1:-}"; oid="${2:-}"
# BOTH ARGUMENTS, VALIDATED. The function took them positionally from a call site
# written by hand in prose; a missing one used to become an empty string that
# `pr-ci-state.sh` would reject with an error code the gate reported as "could not
# establish the check state", which names the wrong cause and sends the reader to
# the API. Here the caller is told what it did.
case "$pr" in
    ""|*[!0-9]*) echo "ABORT: the CI gate needs a PR number (got '$pr')"; exit 1 ;;
esac
_why="$(sha_reason "$oid")" || {
    echo "ABORT: the CI gate needs a head oid ($_why: '$oid')"; exit 1; }

iv="${PR_CI_INTERVAL:-30}" tmo="${PR_CI_TIMEOUT:-1800}" grace="${PR_CI_GRACE:-90}"
# THE BOUNDS ARE VALIDATED BEFORE THE LOOP, and a bad value falls back to the
# default rather than disabling the bound. `PR_CI_INTERVAL=0` sleeps zero seconds
# and leaves the elapsed count unchanged forever, and a non-numeric
# `PR_CI_TIMEOUT` makes the `-ge` comparison fail on every iteration — either one
# turns the supposedly bounded gate into an unbounded API-polling loop. Leading
# zeros are rejected rather than accepted as digits: Bash reads them as octal in
# arithmetic, so `08` aborts and `00` is zero.
case "$iv" in  ""|0|0*|*[!0-9]*|??????*) iv=30 ;; esac
case "$tmo" in ""|0*|*[!0-9]*|??????*)   tmo=1800 ;; esac
case "$grace" in ""|0*|*[!0-9]*|??????*) grace=90 ;; esac
probe="${PR_CI_PROBE_TIMEOUT:-60}"
case "$probe" in ""|0|0*|*[!0-9]*|??????*) probe=60 ;; esac

rc=0 elapsed=0 budget=0 nap=0 stable_rc="" stable_since=0
# ELAPSED WALL TIME, not the sum of the sleeps. Counting only the sleeps excludes
# however long each probe took, so two slow `gh` calls per iteration silently
# turned a documented thirty-minute bound into ninety.
#
# THROUGH `clocklib.sh`, NOT `$SECONDS` — issue #66. A builtin is unreachable
# from `PATH`, so `test-pr-ci-gate.sh` could only wait out real seconds and every
# deadline case there raced however loaded the runner was. `date` is a command,
# so the fixture owns time the way `test-pr-watch.sh` already does. The library
# also brings the guards a bare read has not got: a `date` that prints then
# fails, an epoch past Bash's integer range, and a clock that steps backward.
rb_elapsed start || { echo "ABORT: the CI gate could not read the clock; refusing to poll unbounded."; exit 1; }
while :; do
    # PINNED TO THE OID THIS ROUND PUSHED. `gh pr checks` is addressed by PR
    # number, and the API can still be serving the PREVIOUS head for a moment
    # after a push — the head confirmation below already retries for exactly that
    # lag. Asking without the OID meant a green answer about the head from the
    # round before, which is the last round's answer to this round's question, and
    # it reads as permission to close.
    #
    # EACH PROBE IS BOUNDED BY WHAT IS LEFT, not only by its own default. The
    # helper watchdogs its `gh` calls, but at sixty seconds each — so with
    # `PR_CI_TIMEOUT=1` a hung request ran for a minute before this loop could look
    # at the clock at all. A bound the callee does not know about is not a bound;
    # the remaining budget is passed down.
    rb_elapsed || { echo "ABORT: the CI gate lost the clock; refusing to poll unbounded."; exit 1; }
    elapsed="$RB_ELAPSED"
    # AN EXPIRED DEADLINE IS NOT A SHORT DEADLINE. Clamping an exhausted budget up
    # to one second started another probe past the bound — and each of those can
    # take its second plus the watchdog's five-second escalation, so the clamp
    # turned the timeout into a floor. The clock is checked BEFORE the probe as
    # well as after it, because a sleep that lands exactly on the deadline would
    # otherwise buy one more request.
    if [ "$elapsed" -ge "$tmo" ]; then
        echo "ABORT: the checks had not settled after ${tmo}s; do not close this round on an unknown state."
        exit 1
    fi
    budget=$((tmo - elapsed))
    [ "$budget" -gt "$probe" ] && budget="$probe"
    PR_CI_PROBE_TIMEOUT="$budget" /usr/bin/env bash -p "$_RB_SELF_DIR"/pr-ci-state.sh "$pr" --head "$oid"; rc=$?
    rb_elapsed || { echo "ABORT: the CI gate lost the clock; refusing to poll unbounded."; exit 1; }
    elapsed="$RB_ELAPSED"
    # THE DEADLINE IS CHECKED BEFORE A VERDICT IS ACCEPTED, not after. With the
    # check at the bottom of the loop, a `PR_CI_TIMEOUT` shorter than
    # `PR_CI_GRACE` — or simply a probe that returned green after the deadline —
    # closed the round past its own bound, which is a bound that does not bind. A
    # gate that has run out of time has no verdict, whatever the last answer was.
    if [ "$elapsed" -ge "$tmo" ]; then
        echo "ABORT: the checks had not settled after ${tmo}s; do not close this round on an unknown state."
        exit 1
    fi
    case "$rc" in
        0|4)
            # A GOOD ANSWER HAS TO HOLD. Both of these close the round, and both
            # can be true of an incomplete picture: a push that triggers two
            # workflows can have the fast one registered and passing before the
            # second is registered at all, and a run is registered a moment after
            # the head moves, so the first probe reports `none` on a repository
            # that does have CI. Closing on either reproduces the red-head closure
            # with an extra step — the later workflow appears and fails after the
            # round is already closed.
            #
            # So a verdict that would close the round must still be the answer
            # `grace` seconds later. Anything else resets it, because the picture
            # changed.
            if [ "$rc" = "$stable_rc" ] && [ $((elapsed - stable_since)) -ge "$grace" ]; then
                if [ "$rc" -eq 4 ]; then
                    echo "note: no checks are configured; the CI gate has nothing to assert"
                fi
                exit 0
            fi
            if [ "$rc" != "$stable_rc" ]; then stable_rc="$rc"; stable_since="$elapsed"; fi ;;
        1) echo "ABORT: the head you just pushed is RED. Fix it and push again; do not close this round."
           exit 1 ;;
        3|5) stable_rc=""; stable_since=0 ;;   # running, or the API has not caught up
        *) echo "ABORT: could not establish the check state (rc=$rc); do not close this round blind."
           exit 1 ;;
    esac
    # THE SLEEP IS CAPPED AT WHAT IS LEFT. Sleeping a full interval when less than
    # that remains means the gate cannot report its own deadline until after it has
    # passed — `PR_CI_TIMEOUT=1` with the default 30-second interval took thirty
    # seconds to say it had run out of one. The bound is then only ever
    # approximately the bound, and the smaller it is set the more approximate it
    # gets.
    nap=$((tmo - elapsed))
    [ "$nap" -gt "$iv" ] && nap="$iv"
    # `sleep` takes its status like every other call here. A `sleep` that returned
    # immediately — interrupted, or missing — would spin this loop against the API
    # until the timeout, and with the elapsed count taken from the clock the loop
    # would still be bounded but would poll hard for the whole of it.
    sleep "$nap" || { echo "ABORT: the CI wait could not sleep; refusing to spin."; exit 1; }
done
