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
TMP="$(mktemp -d)"
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
    *)  if kill -0 "$desc_pid" 2>/dev/null; then
            kill -9 "$desc_pid" 2>/dev/null
            die "the descendant (pid $desc_pid) outlived the watchdog"
        else
            pass "…and its descendant is reaped with it, not orphaned"
        fi ;;
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
printf '%s' "$out" | grep -q 'rc=124' \
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
out="$(PATH="$CATF" bash -c '. "'"$SELF_DIR"'/testlib.sh"; res="$(run_limited 5 sh -c "echo whole")"; echo "rc=$? res=$res"' 2>&1)"
case "$out" in
    "rc=125 res=partial") pass "a reader that emits and then fails returns 125" ;;
    *) die "failing reader gave '$out' (want rc=125 res=partial)" ;;
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
    out="$(grep -nE 'PATH''=.*run_limited' "$dir"/test-*.sh 2>"$errf")"; rc=$?
    msg="$(cat "$errf" 2>/dev/null)"; mrc=$?
    rm -f "$errf" 2>/dev/null
    [ "$mrc" -eq 0 ] || return 2
    # grep exits 1 for NO MATCH and >1 for a real error. Collapsing those with
    # `|| true` turned an unreadable fixture into an empty result — and an empty
    # result is exactly what "no fixture violates this" looks like, so the guard
    # could report its invariant held without having established anything.
    [ "$rc" -le 1 ] || return 2
    [ -z "$msg" ] || return 2
    printf '%s' "$out"
    return 0
}
bad="$(scan_watchdog_path_misuse "$SELF_DIR")"; scan_rc=$?
[ "$scan_rc" -eq 0 ] || die "the fixture scan could not be completed (rc=$scan_rc)"
bad="$(printf '%s' "$bad" \
       | grep -v "^$SELF_DIR/test-testlib.sh:" \
       | grep -v 'run_limited [0-9]* env ' || true)"
# Continued lines count too: the assignment and the call are routinely split.
# `test-testlib.sh` is skipped here for the same reason as above — its cases exist
# to drive `run_limited` under a PATH with no `timeout` on it.
bad2="$(awk 'FILENAME ~ /test-testlib\.sh$/ { next }
             /PATH=/ && /\\$/ { prev = FILENAME ":" FNR ": " $0; next }
             prev != "" && /run_limited/ && !/run_limited [0-9]+ env / { print prev }
             { prev = "" }' "$SELF_DIR"/test-*.sh)"; scan2_rc=$?
[ "$scan2_rc" -eq 0 ] || die "the continued-line fixture scan failed (rc=$scan2_rc)"
if [ -z "$bad" ] && [ -z "$bad2" ]; then
    pass "no fixture prefixes an environment onto run_limited itself"
else
    die "a fixture puts its environment on the watchdog's PATH, not the subject's:"
    printf '%s\n%s\n' "$bad" "$bad2" | sed '/^$/d; s/^/       /'
fi

# …and the scan's own failure path, exercised against a fixture it cannot read.
SCANTMP="$(mktemp -d)"
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
