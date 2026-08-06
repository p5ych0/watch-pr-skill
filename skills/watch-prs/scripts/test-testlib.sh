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
printf '#!/usr/bin/env bash\nexit 1\n' > "$BROKE/sleep"; chmod +x "$BROKE/sleep"
out="$(PATH="$BROKE" bash -c '. "'"$SELF_DIR"'/testlib.sh"; run_limited 3 sh -c "sleep 30 2>/dev/null; :"; echo "rc=$?"' 2>&1)"
case "$out" in
    *"rc=125"*) pass "a failing watchdog sleep returns 125, not an ordinary timeout" ;;
    *) die "broken sleep gave '$out' (want rc=125)" ;;
esac
printf '%s' "$out" | grep -q 'rc=124' \
    && die "a broken clock was reported as a timeout" \
    || pass "…and is distinguishable from the limit actually being hit"

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

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
