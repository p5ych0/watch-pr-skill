#!/usr/bin/env bash
# Unit tests for testlib.sh's portable watchdog.
#
# The suite is a MANDATORY pre-push gate — `pr-selfcheck.sh` runs every
# `test-*.sh` and treats a failure as a finding — and several fixtures need a
# wall-clock limit so a regression fails rather than hangs. They used GNU
# `timeout`, which stock macOS does not ship, making the gate unpassable on a
# platform README calls supported. So the fallback is the thing under test here:
# if it is wrong, every other test on that platform is wrong with it.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# A PATH with the tools the fallback needs but WITHOUT `timeout`, so the
# fallback branch is what actually runs. Testing it only where `timeout` exists
# would exercise the branch that was never in question.
NOTO="$TMP/bin"; mkdir -p "$NOTO"
for b in bash sh sleep date true false kill sed grep printf env mktemp cat rm; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$NOTO/$b"
done
PATH="$NOTO" command -v timeout >/dev/null 2>&1 \
    && die "the reduced PATH still has timeout; the fallback is not being tested" \
    || pass "the reduced PATH has no timeout, so the fallback branch runs"

# ── the limit is enforced, and reported the way GNU timeout reports it ─────
out="$(PATH="$NOTO" bash -c '. "'"$SELF_DIR"'/testlib.sh"; start=$(date +%s); run_limited 2 sleep 30; rc=$?; echo "rc=$rc elapsed=$(( $(date +%s) - start ))"')"
case "$out" in
    "rc=124 elapsed="*) pass "a command that overruns is killed and reports 124" ;;
    *) die "overrunning command gave '$out' (want rc=124)" ;;
esac
# It must not have waited for the command: a watchdog that returns 124 only
# after the command finishes on its own has enforced nothing.
elapsed="${out##*elapsed=}"
{ [ "$elapsed" -ge 1 ] && [ "$elapsed" -le 8 ]; } \
    && pass "…and returns at the limit rather than when the command ends" \
    || die "the limit was not enforced promptly (elapsed=${elapsed}s for a 2s limit on a 30s command)"

# ── a command that waits for its children is still bounded ────────────────
# Callers use command substitution, so anything holding the inherited stdout
# keeps the pipe open and the shell blocks regardless of what was killed. Output
# goes to a temp file for that reason, and this covers the shape the suite
# actually runs: a command with children that waits for them.
#
# NOT covered, deliberately: a command that backgrounds a child and then exits
# leaves an orphan that keeps the caller's capture open until it finishes on its
# own. testlib.sh records that limitation; asserting it here would be asserting
# behaviour the helper does not have.
out="$(PATH="$NOTO" bash -c '. "'"$SELF_DIR"'/testlib.sh"; start=$(date +%s); res="$(run_limited 2 sh -c "sleep 30 & wait")"; rc=$?; echo "rc=$rc elapsed=$(( $(date +%s) - start ))"')"
case "$out" in
    "rc=124 elapsed="*) pass "a command that waits for its children is killed at the limit" ;;
    *) die "child-waiting case gave '$out' (want rc=124)" ;;
esac
child_elapsed="${out##*elapsed=}"
{ [ "$child_elapsed" -le 8 ]; } \
    && pass "…and the caller's capture returns at the limit, not when the child ends" \
    || die "the capture stayed open for ${child_elapsed}s on a 2s limit"

# ── descendants die with the command, not after it ────────────────────────
# Killing the leader alone left what it spawned running: this exact shape —
# `sleep 30 & wait` — returned 124 with the `sleep` still alive, so a mandatory
# suite leaked one process per run, outside any fixture's cleanup. The PID is
# recorded by the child itself, so the assertion can name the survivor instead of
# matching an argv pattern that could belong to anyone.
rm -f "$TMP/desc.pid"
out="$(PATH="$NOTO" TMP="$TMP" bash -c '. "'"$SELF_DIR"'/testlib.sh"; run_limited 2 sh -c "sleep 30 & echo \$! > \"$TMP/desc.pid\"; wait"; echo "rc=$?"')"
case "$out" in
    *"rc=124"*) pass "a command with a live descendant still stops at the limit" ;;
    *) die "descendant case gave '$out' (want rc=124)" ;;
esac
desc_pid="$(cat "$TMP/desc.pid" 2>/dev/null)"; desc_rc=$?
[ "$desc_rc" -eq 0 ] || die "could not read the descendant PID marker (rc=$desc_rc)"
case "$desc_pid" in
    ""|*[!0-9]*) die "the child never recorded a descendant PID ('$desc_pid')" ;;
    *)  # POLLED, not sampled once. `SIGKILL` is delivered asynchronously and
        # `run_limited` waits only for the group LEADER, so on a loaded machine
        # the descendant can still be scheduled — or lingering as a zombie —
        # when the call returns. An immediate `kill -0` therefore fails this
        # mandatory test on timing rather than on the invariant, which is the
        # scheduling-dependence this fixture was rewritten twice to remove.
        #
        # The grace period is bounded and the failure still fires: a descendant
        # that never goes away is the leak, and five seconds is far longer than
        # a delivery delay while far shorter than the thirty it would sleep.
        desc_gone=0
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$desc_pid" 2>/dev/null || { desc_gone=1; break; }
            sleep 0.5 2>/dev/null || sleep 1
        done
        if [ "$desc_gone" -eq 1 ]; then
            pass "…and its descendant is reaped with it, not orphaned"
        else
            kill -9 "$desc_pid" 2>/dev/null
            die "the descendant (pid $desc_pid) outlived the watchdog"
        fi ;;
esac

# ── the scratch directory is validated, not merely requested ──────────────
# Every test file in this suite used a bare `mktemp -d`. Unchecked, a failure
# leaves `$TMP` empty, so `$TMP/bin` is `/bin` and `$TMP/broke` is `/broke` — and
# the EXIT trap that follows runs `rm -rf` over exactly that. In a root-run
# container that is `rm -rf /bin`. `mktemp` can also print a plausible path and
# then fail, which command substitution keeps.
MKD="$TMP/mkd"; mkdir -p "$MKD"
for b in bash sh sleep date true false kill sed grep printf env cat rm; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$MKD/$b"
done
mkdir -p "$MKD/scratch"
REAL_MKTEMP="$(command -v mktemp)"
[ -n "$REAL_MKTEMP" ] || { printf 'FAIL - no mktemp on PATH\n'; echo "RESULT: FAIL"; exit 1; }
mkd_case() {   # <stub-body> <label> <want: OK|REJECT>
    printf '#!/usr/bin/env bash\n%s\n' "$1" > "$MKD/mktemp"; chmod +x "$MKD/mktemp"
    local got
    # TMPDIR points inside this test's own scratch space, so the one case that
    # reaches a real `mktemp -d` creates its directory where the EXIT trap will
    # remove it. Without that, every run of this file left a directory behind in
    # the system temp — a suite that leaks on each invocation, which is the
    # complaint it makes about the code it tests.
    got="$(PATH="$MKD" TMPDIR="$MKD/scratch" bash -c '. "'"$SELF_DIR"'/testlib.sh"; d="$(mktemp_d)" && echo "OK:$d" || echo REJECT' 2>&1)"
    case "$3:$got" in
        REJECT:REJECT) pass "mktemp_d refuses $2" ;;
        OK:OK:*)       pass "mktemp_d accepts $2" ;;
        *)             die "mktemp_d on $2 gave '$got' (want $3)" ;;
    esac
}
mkd_case 'exit 1'                              'a failed request'                    REJECT
mkd_case 'printf "/tmp/plausible-but-unmade\n"; exit 1' \
                                               'a path printed before failing'       REJECT
mkd_case 'printf "\n"'                         'an empty path'                       REJECT
mkd_case 'printf "/\n"'                        'the filesystem root'                 REJECT
mkd_case 'printf "relative/path\n"'            'a relative path'                     REJECT
mkd_case 'printf "/tmp/definitely-not-created-%s\n" "$$"' \
                                               'a path that was never created'       REJECT
# ABSOLUTE path, resolved before the PATH is reduced. Writing this as
# `exec env mktemp -d` made the stub re-find ITSELF through the stubbed PATH and
# recurse without bound — I ran it, and it had to be killed. A stub that shadows
# a tool must never invoke that tool by name.
mkd_case "exec '$REAL_MKTEMP' -d"              'a real scratch directory'            OK

# ── a watchdog that cannot set itself up says so distinctly ───────────────
# The buffer allocation returned 2, which is ALSO a status the bounded command
# legitimately returns and which several fixtures in this suite assert as their
# primary expectation — so a watchdog that never ran the subject at all satisfied
# them. 125 is the distinguished "the watchdog failed", already used by the clock
# and reader paths.
MKT="$TMP/mkt"; mkdir -p "$MKT"
for b in bash sh sleep date true false kill sed grep printf env cat rm; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$MKT/$b"
done
printf '#!/usr/bin/env bash\nexit 1\n' > "$MKT/mktemp"; chmod +x "$MKT/mktemp"
# The command would exit 2 on its own, so a status-2 setup failure would be
# indistinguishable from it — that is the whole point of the case.
out="$(PATH="$MKT" bash -c '. "'"$SELF_DIR"'/testlib.sh"; run_limited 5 sh -c "exit 2"; echo "rc=$?"' 2>&1)"
case "$out" in
    *"rc=125"*) pass "a watchdog that cannot allocate its buffer returns 125" ;;
    *"rc=2"*)   die "the setup failure was indistinguishable from the command's own status 2" ;;
    *)          die "failing mktemp gave '$out' (want rc=125)" ;;
esac

# ── a command that finishes in time keeps its own status ───────────────────
out="$(PATH="$NOTO" bash -c '. "'"$SELF_DIR"'/testlib.sh"; run_limited 5 true; echo "rc=$?"')"
[ "$out" = "rc=0" ] && pass "a successful command returns 0" || die "success gave '$out'"
out="$(PATH="$NOTO" bash -c '. "'"$SELF_DIR"'/testlib.sh"; run_limited 5 sh -c "exit 3"; echo "rc=$?"')"
[ "$out" = "rc=3" ] && pass "a failing command's own status is preserved" || die "exit 3 gave '$out'"
out="$(PATH="$NOTO" bash -c '. "'"$SELF_DIR"'/testlib.sh"; run_limited 5 sh -c "exit 2"; echo "rc=$?"')"
[ "$out" = "rc=2" ] && pass "…including the 2 the helpers use for 'cannot tell'" || die "exit 2 gave '$out'"

# ── stdout is passed through, since every caller captures it ───────────────
out="$(PATH="$NOTO" bash -c '. "'"$SELF_DIR"'/testlib.sh"; run_limited 5 sh -c "echo hello"')"
[ "$out" = "hello" ] && pass "stdout reaches the caller" || die "stdout was lost: '$out'"

# ── where `timeout` exists, it is used and behaves identically ─────────────
if command -v timeout >/dev/null 2>&1; then
    out="$(run_limited 2 sleep 30; echo "rc=$?")"
    [ "$out" = "rc=124" ] \
        && pass "the timeout branch reports 124 too, so assertions read the same" \
        || die "the timeout branch gave '$out'"
    run_limited 5 sh -c 'exit 3'; [ "$?" -eq 3 ] \
        && pass "…and preserves the command's status" \
        || die "the timeout branch lost the command status"
else
    pass "no timeout on this platform; the fallback is the only path (already covered)"
fi

# ── a broken watchdog clock is unreadable, not a timeout ───────────────────
# `sleep` IS the watchdog on this path. When it failed the loop still advanced
# `waited`, burned the limit in a tight spin, killed the command and returned an
# ordinary 124 — so a fixture asserting "this hangs, therefore it times out"
# passed while no wall-clock limit was in force. That is a mandatory gate
# reporting PASS from a broken clock, which is the precise shape of failure this
# suite exists to refuse.
BROKE="$TMP/broke"; mkdir -p "$BROKE"
for b in bash sh date true false kill sed grep printf env mktemp cat rm; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$BROKE/$b"
done
# The stub fails ONLY for the watchdog's own `sleep 1`, and works for everything
# else. A stub that failed unconditionally was shared with the child on the same
# PATH, so `sleep 30` returned instantly and the child could be FINISHED before
# the parent's first `kill -0` — the watchdog then observed a completed command
# and returned its status, never reaching the 125 path this case exists to prove.
# The test still passed, on scheduling. A mandatory gate that passes for a reason
# it does not name is the failure mode this whole suite is about.
REAL_SLEEP="$(command -v sleep)"
# THE STUB WAITS FOR THE CHILD BEFORE FAILING. Failing the watchdog's first nap
# immediately still left a race the other way: under a scheduler that leaves the
# background child pending, the parent could kill it before its first command, so
# the 125 came back from bounding nothing and the liveness assertion failed on
# timing. The handshake removes the dependence in both directions — the clock
# fails only once the child has provably started.
#
# The wait is BOUNDED. If the child never signals — which is what the shared-stub
# version does, since its `sleep 30` fails instantly and the child runs to
# completion — this must still return, or a broken fixture hangs the suite
# instead of failing it.
cat > "$BROKE/sleep" <<SLEEPSH
#!/usr/bin/env bash
if [ "\$1" = "1" ]; then
    _w=0
    while [ ! -e "\$TMP/child-started" ] && [ "\$_w" -lt 50 ]; do
        "$REAL_SLEEP" 0.1
        _w=\$((_w + 1))
    done
    exit 1
fi
exec "$REAL_SLEEP" "\$@"
SLEEPSH
chmod +x "$BROKE/sleep"
# The child's liveness is OBSERVABLE, not inferred from the status. Whether the
# shared-stub version raced correctly depended on whether the parent's first
# `kill -0` beat the child's `exec` — on this machine the parent wins every time,
# so a status-only assertion passes either way and proves nothing about the fix.
# The marker file does not depend on scheduling: with a shared broken `sleep` the
# child runs to completion at once and writes it; with the clock-only stub it is
# still sleeping when the watchdog gives up, and never does.
rm -f "$TMP/child-started" "$TMP/child-ended"
out="$(PATH="$BROKE" TMP="$TMP" bash -c '. "'"$SELF_DIR"'/testlib.sh"; run_limited 3 sh -c ": > \"$TMP/child-started\"; sleep 30; : > \"$TMP/child-ended\""; echo "rc=$?"' 2>&1)"
case "$out" in
    *"rc=125"*) pass "a failing watchdog sleep returns 125, not an ordinary timeout" ;;
    *) die "broken sleep gave '$out' (want rc=125)" ;;
esac
grep -q 'rc=124' <<<"$out" \
    && die "a broken clock was reported as a timeout" \
    || pass "…and is distinguishable from the limit actually being hit"
# BOTH halves, and the first is what the shared stub cannot satisfy. When the
# watchdog's `sleep` and the child's are the same broken stub, the parent's very
# first nap fails in microseconds and it kills the child before that child has
# even reached its first command — so the 125 came back from bounding nothing.
# With the clock-only stub the child is provably running and provably unfinished.
[ -e "$TMP/child-started" ] \
    && pass "…and the child had actually started, so something was being bounded" \
    || die "the child was killed before it ran; the watchdog bounded nothing"
[ -e "$TMP/child-ended" ] \
    && die "the child ran to completion; the watchdog never had a live command to bound" \
    || pass "…and was still running when the clock failed"

# ── a command that IGNORES TERM is still killed ────────────────────────────
# The GNU arm sent TERM and stopped there: `timeout --help` says plainly that a
# caught or blocked TERM does not kill the command and that `--kill-after` is
# needed to follow with KILL. So a hung wrapper — or a child that traps TERM —
# outlived the limit, and every bound built on this watchdog was advisory. The
# fallback already escalated; this is the arm that runs wherever GNU coreutils do,
# which is to say almost everywhere.
term_start=$SECONDS
term_rc=0
run_limited 2 bash -c 'trap "" TERM; sleep 60' >/dev/null 2>&1 || term_rc=$?
term_took=$((SECONDS - term_start))
# The limit is 2s and the escalation follows 5s later, so anything under about 15
# means it was killed rather than waited out; 60 would mean the command simply
# finished.
[ "$term_took" -lt 15 ] \
    && pass "a command that ignores TERM is killed at the limit (${term_took}s)" \
    || die "a TERM-ignoring command outlived the watchdog (${term_took}s)"
[ "$term_rc" -ne 0 ] \
    && pass "…and the watchdog reports that it did not finish" \
    || die "a killed command was reported as successful"

# …AND A `timeout` THAT CANNOT ESCALATE IS NOT USED. Falling back to a plain
# `timeout` when `-k` is unsupported restores the very defect the escalation
# exists to fix: TERM, no KILL, and a command that traps it runs on. The portable
# path polls and kills itself, so it is strictly better than a watchdog that
# cannot — `-k` is the only reason to prefer the external one.
NOK="$TMP/nok"; mkdir -p "$NOK"
for b in bash sh sleep date true false kill sed grep printf env mktemp rm cat; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$NOK/$b"
done
# A `timeout` that refuses `-k`, exactly as a stripped-down implementation would.
printf '#!/usr/bin/env bash\ncase "$1" in -k) echo "timeout: unrecognized option -k" >&2; exit 125 ;; esac\nshift\nexec "$@"\n' \
    > "$NOK/timeout"; chmod +x "$NOK/timeout"
nok_out="$(PATH="$NOK" bash -c '
    . "'"$SELF_DIR"'/testlib.sh"
    start=$SECONDS
    run_limited 2 bash -c "trap \"\" TERM; sleep 60" >/dev/null 2>&1
    rc=$?
    echo "rc=$rc took=$((SECONDS - start))"' 2>&1)"
nok_took="${nok_out##*took=}"
{ [ -n "$nok_took" ] && [ "$nok_took" -lt 15 ]; } \
    && pass "a timeout without -k is not used; the escalating path kills anyway ($nok_out)" \
    || die "a TERM-only timeout was used and the command outlived it ($nok_out)"

# ── a reader that emits and then fails is not a successful run ─────────────
# `cat` can write a partial buffer and exit non-zero; its status was overwritten
# by `rm` and the COMMAND's 0 returned, so a caller comparing a prefix or
# grepping the capture still matched and reported PASS on output nobody finished
# reading.
CATF="$TMP/catf"; mkdir -p "$CATF"
for b in bash sh sleep date true false kill sed grep printf env mktemp rm; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$CATF/$b"
done
printf '#!/usr/bin/env bash\nprintf "partial"\nexit 1\n' > "$CATF/cat"; chmod +x "$CATF/cat"
# STDERR IS DISCARDED HERE, deliberately. The fallback replays the bounded
# command's stderr as well as its stdout, so the stubbed `cat` runs twice and its
# second "partial" lands on stderr — folding that into the capture with `2>&1`
# made this exact comparison fail against correct behaviour. What this case is
# about is the STDOUT reader's status, so stdout is what it reads.
out="$(PATH="$CATF" bash -c '. "'"$SELF_DIR"'/testlib.sh"; res="$(run_limited 5 sh -c "echo whole")"; echo "rc=$? res=$res"' 2>/dev/null)"
case "$out" in
    "rc=125 res=partial") pass "a reader that emits and then fails returns 125" ;;
    *) die "failing reader gave '$out' (want rc=125 res=partial)" ;;
esac
# …and the STDERR replay has its own status, for the same reason: a `cat` that
# emits a partial diagnostic and then fails hands the caller a truncated message
# to match against, and `pr-ci-state.sh` decides "no checks configured" by
# matching a diagnostic whole. Here stdout reads cleanly and only stderr fails.
CATE="$TMP/cate"; mkdir -p "$CATE"
for b in bash sh sleep date true false kill sed grep printf env mktemp rm; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$CATE/$b"
done
# The two replays are `cat "$tmp"` and `cat "$tmperr"`, both `mktemp` paths, so
# the argument cannot tell them apart — the stub counts instead and fails on the
# SECOND call. The real `cat` is resolved to an absolute path BEFORE the PATH is
# reduced, or the stub re-finds itself through the reduced PATH and recurses.
REAL_CAT="$(command -v cat)" || { printf 'FAIL - no cat on PATH\n'; echo "RESULT: FAIL"; exit 1; }
# Builtins only for the counter: the PATH below is reduced to a handful of
# symlinks, and the first version reached for `head`, which is not among them —
# so the count never advanced past one and the case passed against a `cat` that
# never failed. A stub that cannot count is a fixture asserting nothing.
cat > "$CATE/cat" <<CATSH
#!/usr/bin/env bash
n=0
[ -f "$TMP/catn" ] && read -r n < "$TMP/catn"
n=\$((n + 1))
printf '%s\\n' "\$n" > "$TMP/catn"
if [ "\$n" -eq 2 ]; then printf 'partial'; exit 1; fi
exec "$REAL_CAT" "\$@"
CATSH
chmod +x "$CATE/cat"
: > "$TMP/catn"
eout="$(PATH="$CATE" bash -c '. "'"$SELF_DIR"'/testlib.sh"; res="$(run_limited 5 sh -c "echo whole")"; echo "rc=$? res=$res"' 2>/dev/null)"
case "$eout" in
    "rc=125 res=whole") pass "…and a stderr replay that fails returns 125 too" ;;
    *) die "failing stderr replay gave '$eout' (want rc=125 res=whole)" ;;
esac

# ── no fixture may put its stubs on the WATCHDOG's own PATH ────────────────
# Owned by this file because the hazard belongs to `run_limited`: where GNU
# `timeout` is missing it polls with its own `sleep`, so a stub prefixed onto the
# CALLER's environment is inherited by the watchdog and breaks the harness rather
# than the subject. Three assertions in two fixtures were affected, and the whole
# suite was unpassable on stock macOS while passing wherever `timeout` exists —
# invisible on the machine that wrote them.
#
# The correct shape puts the substitution inside: `run_limited N env VAR=… cmd`.
# PATH specifically, not any variable: the others are inherited harmlessly, while
# a prefixed PATH can shadow the very `sleep`, `cat`, `mktemp` or `kill` the
# watchdog runs. The correct shape puts the substitution inside the watchdog:
# `run_limited N env PATH=… cmd`.
# The pattern is SPLIT so this line cannot match itself — a self-matching guard
# reports a finding against its own source and never goes green, which reads as a
# broken check rather than as the invariant it states.
# THIS FILE is exempt, and only this one: its cases exist to drive `run_limited`
# under a PATH with no `timeout` on it, which is the fallback they test. Every
# other fixture stubs the SUBJECT and must not reach the watchdog.
# THE SCAN'S STATUS IS TAKEN, and "no match" is distinguished from "could not
# read". `2>/dev/null … || true` turned an unreadable fixture into an empty
# result, and an empty result is exactly what "no fixture violates this" looks
# like — so the guard could report its invariant held without having established
# anything. grep exits 1 for no-match and >1 for a real error.
# The scan is a FUNCTION so its failure path can be exercised, not merely
# asserted about — the same lesson as the marker read: a guard nobody runs is a
# guard nobody has tested.
scan_watchdog_path_misuse() {   # <dir> ; prints offenders; 2 if the scan failed
    local dir="$1" errf out rc msg mrc
    errf="$(mktemp)" || return 2
    # ONE pass, ONE status. This was a `grep` piped through two `grep -v`
    # filters with `|| true` on the end, and every one of those could fail with
    # no output — which is indistinguishable from "no fixture violates this", the
    # answer that lets the guard report an invariant it never established. A
    # pipeline whose failures are invisible is the defect; adding a status check
    # to each stage would have kept the shape that caused it.
    #
    # The same pass joins continued lines, since the assignment and the call are
    # routinely split across them, and that used to be a second unguarded scan.
    out="$(awk '
        # ONE definition of what an offender is, reached from both the end of a
        # command and the comment that closes one. Written out twice, the comment
        # boundary would be the copy that drifts.
        function emit() {
            if (buf ~ /PATH=/ && buf ~ /run_limited/ && buf !~ /run_limited [0-9]+ env /)
                print FILENAME ":" start ": " buf
            buf = ""; start = 0
        }
        FNR == 1 { buf = ""; start = 0 }
        # EXACT basename, not a suffix — the same rule as the recordlib guard:
        # a suffix match also exempts a file merely NAMED like the exempt one.
        { _base = FILENAME; sub(/^.*\//, "", _base) }
        _base == "test-testlib.sh" { next }
        # A COMMENT IS NOT CODE — #54. This guard rejected the DOCUMENTATION of
        # its own rule: a comment explaining `run_limited N env …` rather than
        # `PATH=… run_limited` names both tokens by necessity, and was reported as
        # a violation. The workaround is to reword the prose until it no longer
        # says what it means, in a repository whose whole convention is that the
        # why lives beside the code — and it was a false positive in a MANDATORY
        # pre-push gate, so it cost a round to discover and could not be ignored.
        #
        # STRIPPING WHOLE-LINE COMMENTS IS THE OBVIOUS FIX, AND IT IS REJECTED —
        # it is what `pr-selfcheck.sh` does for its own scan, so it was tried here
        # first. It does not survive, for the reason below, and neither does any
        # narrower version of it. Nothing is stripped.
        #
        # NO COMMENT IS SKIPPED, AND THAT IS THE ANSWER TO #54 RATHER THAN A
        # FAILURE TO FIX IT. The ask was to stop reporting a comment that explains
        # this rule. Every way of doing that was tried in #63 and each one made a
        # REAL violation invisible, because the two are the same text:
        #
        #   # `run_limited N env …`, not `PATH=… run_limited`   <- prose
        #   # PATH=quoted" run_limited 5 cmd                    <- quoted DATA,
        #                                                          after `PATH="/x`
        #
        # Nothing local separates them. What separates them is whether a quote was
        # left open on an earlier line, and answering that means lexing the file —
        # which cannot be approximated here, because these fixtures are full of
        # heredocs whose bodies contain arbitrary quotes and hashes.
        #
        # So this guard reports every hash line that carries both tokens. It is a
        # mandatory pre-push gate: one that misses a real violation is worse than
        # one that questions a comment, and the cost is a comment somewhere having
        # to be reworded. #64 carries the redesign, which has to stop inferring
        # structure from text rather than infer it better.
        #
        # THE FIXTURES BELOW PIN ALL OF IT — four shapes that must stay reported,
        # and the false positive that is the price. A future attempt to strip
        # comments fails them, and their messages say where to read first.
        {
            if (start == 0) start = FNR
            line = $0
            sub(/\\$/, " ", line)
            buf = buf line
            if ($0 ~ /\\$/) next
            emit()
        }
    ' "$dir"/test-*.sh 2>"$errf")"; rc=$?
    msg="$(cat "$errf" 2>/dev/null)"; mrc=$?
    rm -f "$errf" 2>/dev/null
    [ "$mrc" -eq 0 ] || return 2
    # awk exits non-zero only on a real error — unlike grep it has no "no match"
    # status — so any non-zero is a failed scan, and anything on stderr is too.
    [ "$rc" -eq 0 ] || return 2
    [ -z "$msg" ] || return 2
    printf '%s' "$out"
    return 0
}
bad="$(scan_watchdog_path_misuse "$SELF_DIR")"; scan_rc=$?
[ "$scan_rc" -eq 0 ] || die "the fixture scan could not be completed (rc=$scan_rc)"
# The REPORTING is a function too, so the failure branch can be exercised. It
# still expanded `$bad2` after that variable's assignment was removed — under
# `set -u` this file aborts with an unbound-variable error, which means the guard
# would have died exactly when it found something, never printing the offender it
# was written to name. The branch nobody runs is the branch that breaks.
report_watchdog_path_misuse() {   # <dir> ; 0 clean, 1 offenders found, 2 scan failed
    local dir="$1" found rc
    found="$(scan_watchdog_path_misuse "$dir")"; rc=$?
    [ "$rc" -eq 0 ] || return 2
    # No cosmetic filter here. It was `printf | sed '/^$/d'` with no status taken,
    # so a `sed` that failed after the scan HAD found an offender emptied `found`
    # and the next line returned 0 — the guard reporting PASS out of a failed
    # parse, which is the same shape as the pipeline this function replaced.
    # Blank lines cannot occur: the scan prints only matched lines.
    [ -n "$found" ] || return 0
    printf '%s\n' "$found" | sed 's/^/       /'
    return 1
}
report_watchdog_path_misuse "$SELF_DIR" > "$TMP/misuse.out"; misuse_rc=$?
case "$misuse_rc" in
    0) pass "no fixture prefixes an environment onto run_limited itself" ;;
    1) die "a fixture puts its environment on the watchdog's PATH, not the subject's:"
       cat "$TMP/misuse.out" ;;
    *) die "the fixture scan could not be completed (rc=$misuse_rc)" ;;
esac

# The scan must still SEE a violation, in both shapes — a guard proven only on
# clean input is a guard proven on nothing.
SEENTMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
printf '#!/usr/bin/env bash\nout="$(PATH="/x:$PATH" run_limited 5 "$SCRIPT" a b)"\n' > "$SEENTMP/test-oneline.sh"
printf '#!/usr/bin/env bash\nout="$(PATH="/x:$PATH" FOO=1 \\\n       run_limited 5 "$SCRIPT" a b)"\n' > "$SEENTMP/test-split.sh"
# …and the two halves of #54: prose describing the rule is not a violation of it,
# while a violation carrying a `#` inside a string still is. The second is what
# stops the fix from being "strip everything after a hash".
printf '#!/usr/bin/env bash\n# `run_limited N env …`, not `PATH=… run_limited`, so the subject sees it\n: \n' > "$SEENTMP/test-comment.sh"
# The `#` sits BEFORE `run_limited`, which is what makes this case load-bearing:
# with it after, stripping from the hash still leaves both tokens and the
# violation is reported anyway — the fixture passes against the over-correction
# and proves nothing. Here the strip removes the call itself, so the offender
# goes unreported and the case fails.
printf '#!/usr/bin/env bash\nout="$(PATH="/x:$PATH" MSG="a # b" run_limited 5 "$SCRIPT" a)"\n' > "$SEENTMP/test-hashstring.sh"
# A CONTINUATION FOLLOWED BY THE SAME PROSE. Bash ends the command at that
# comment; a scanner that keeps the buffer open appends it and reports the
# violation the comment is describing.
printf '#!/usr/bin/env bash\n: \\\n# `run_limited N env …`, not `PATH=… run_limited`, so the subject sees it\n' > "$SEENTMP/test-contcomment.sh"
# …and the two shapes that pay for that choice: a `#` that is quoted DATA because
# the continuation left a quote open, and an assignment that persists into the
# command after the comment. Both are real violations, and both go unreported the
# moment a pending continuation is closed at a comment.
printf '#!/usr/bin/env bash\nout="$(PATH=/x MSG="a \\\n# b" run_limited 5 cmd)"\n' > "$SEENTMP/test-quotehash.sh"
printf '#!/usr/bin/env bash\nPATH="/x:$PATH" \\\n# `run_limited N env …`, not `PATH=… run_limited`\nrun_limited 5 cmd\n' > "$SEENTMP/test-pathassign.sh"
# The one with no backslash at all: the quote itself spans the lines, and the
# hash line carries BOTH tokens. Every comment skip hid this; the parent scanner
# reports it.
printf '#!/usr/bin/env bash\nPATH="/x\n# PATH=quoted" run_limited 5 cmd\n' > "$SEENTMP/test-openquote.sh"
# The whole reporting path, not just the scan: this is the branch that aborted.
report_watchdog_path_misuse "$SEENTMP" > "$TMP/seen.out"; rep_rc=$?
[ "$rep_rc" -eq 1 ] \
    && pass "an offending fixture is reported, not an unbound-variable abort" \
    || die "the offender branch returned $rep_rc instead of 1"
grep -q 'test-oneline.sh' "$TMP/seen.out" \
    && pass "…and the report names the offender" \
    || die "the offender was not named in the report: $(cat "$TMP/seen.out")"
seen="$(scan_watchdog_path_misuse "$SEENTMP")"; seen_rc=$?
[ "$seen_rc" -eq 0 ] || die "the scan failed on the violation fixtures (rc=$seen_rc)"
grep -q 'test-oneline.sh' <<<"$seen" \
    && pass "the scan catches a single-line violation" \
    || die "a single-line PATH-on-watchdog call was not caught: '$seen'"
grep -q 'test-split.sh' <<<"$seen" \
    && pass "…and one split across a continuation" \
    || die "a continued-line PATH-on-watchdog call was not caught: '$seen'"
# THE ACCEPTED COST, PINNED — both shapes of it. A hash line is reported whether
# it is prose or quoted data, because nothing local tells them apart. Reword the
# comment; #64 carries the redesign. A change that makes either of these stop
# being reported has re-opened the fail-open hole #63 measured four times.
grep -q 'test-comment.sh' <<<"$seen" \
    && pass "a comment naming both tokens is questioned, which is the price — #64" \
    || die "comments stopped being reported; #64's four shapes go fail-open first: '$seen'"
grep -q 'test-contcomment.sh' <<<"$seen" \
    && pass "…and so is one after a continuation" \
    || die "a continued comment stopped being reported; read #64 before changing this: '$seen'"
grep -q 'test-quotehash.sh' <<<"$seen" \
    && pass "…and a hash that is quoted data across a continuation is not a comment" \
    || die "a quoted '#' across a continuation hid a real violation: '$seen'"
grep -q 'test-pathassign.sh' <<<"$seen" \
    && pass "…and an assignment persisting past a comment is still a violation" \
    || die "a PATH assignment before a comment hid the run_limited after it: '$seen'"
grep -q 'test-openquote.sh' <<<"$seen" \
    && pass "…and a hash line inside a quote opened on an earlier line" \
    || die "an open multiline quote hid a real violation: '$seen'"
grep -q 'test-hashstring.sh' <<<"$seen" \
    && pass "…and a violation carrying a '#' inside a string is still caught" \
    || die "stripping went past a whole-line comment and lost a real violation: '$seen'"
rm -rf "$SEENTMP"

# …and the scan's own failure path, exercised against a fixture it cannot read.
SCANTMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
printf '#!/usr/bin/env bash\n: \n' > "$SCANTMP/test-unreadable.sh"
chmod 000 "$SCANTMP/test-unreadable.sh"
if cat "$SCANTMP/test-unreadable.sh" >/dev/null 2>&1; then
    # Running as root, or on a filesystem that ignores the mode. Stated rather
    # than passed silently: the case did not run, so it proved nothing.
    pass "SKIPPED: this user can read a mode-000 file, so the unreadable case cannot be built"
else
    scan_watchdog_path_misuse "$SCANTMP" >/dev/null 2>&1
    [ "$?" -eq 2 ] \
        && pass "a fixture the scan cannot read is a failure, not an empty result" \
        || die "an unreadable fixture was reported as 'no offenders'"
fi
# A directory with a clean fixture must still come back clean, or "always fails"
# would satisfy the assertion above.
printf '#!/usr/bin/env bash\nrun_limited 5 env PATH=/x true\n' > "$SCANTMP/test-clean.sh"
rm -f "$SCANTMP/test-unreadable.sh"
scan_watchdog_path_misuse "$SCANTMP" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "…and a readable, compliant fixture scans clean" \
    || die "the scan failed on a compliant fixture"
rm -rf "$SCANTMP"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
