#!/usr/bin/env bash
# The shared clock: `rb_elapsed` in clocklib.sh.
#
# These rules were written inside `pr-watch.sh` and proven only through it, so
# `pr-ci-gate.sh` — which read `$SECONDS` and had none of them — was the copy
# nobody could see was missing them. They are proven against the definition here,
# and `test-pr-identity.sh` proves each caller is wired to it. Issue #66.
set -Eeuo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
. "$SELF_DIR/clocklib.sh"

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

[ "$(type -t rb_elapsed 2>/dev/null)" = function ] \
    || { die "clocklib.sh does not define rb_elapsed"; echo "RESULT: FAIL"; exit 1; }
TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ONE SYMBOL IS THE CONTRACT, not a convenience: `rb_load` clears and verifies the
# single name it is given, so a second entry point is one a startup hook can make
# readonly and keep, and every caller then measures the hook's clock.
#
# COUNTED, NOT NAMED. The first version listed the two retired names, so any
# differently spelled helper — `rb_read`, anything — walked straight past it. What
# the library ADDS is compared before against after, so no name appears here and
# no future one can be forgotten.
#
# THROUGH A SCRIPT FILE, not `bash -c`: a shell whose inherited `SHELLOPTS` carries
# `onecmd` executes one command and stops, which silently truncates every `-c`
# probe — three measurements in this PR contradicted each other before that was
# spotted. `SHELLOPTS` is cleared here for the same reason.
cat > "$TMP/symbols.sh" <<'SYMS'
#!/usr/bin/env bash
before="$(declare -F | awk '{print $3}')"
. "$RB_LIB" || exit 9
declare -F | awk '{print $3}' | while read -r f; do
    printf '%s\n' "$before" | grep -qxF "$f" || printf '%s\n' "$f"
done
SYMS
_added="$(env -u SHELLOPTS RB_LIB="$SELF_DIR/clocklib.sh" bash "$TMP/symbols.sh" 2>/dev/null | sort -u | tr '\n' ' ')"
[ "$_added" = "rb_elapsed " ] \
    && pass "the library adds exactly one symbol, which is all rb_load can clear" \
    || die "clocklib.sh does not add exactly rb_elapsed (added: '$_added')"

# THE CLOCK IS A COMMAND, WHICH IS THE WHOLE POINT — a stub proves the property
# `$SECONDS` cannot have. `+%s` alone is faked, so a caller that formats a date
# for a human still gets a real one.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/date" <<'DATESH'
#!/usr/bin/env bash
case "${1:-}" in
    +%s) [ -n "${FAKE_RC:-}" ] && { printf '%s\n' "${FAKE_NOW_TEXT:-0}"; exit "$FAKE_RC"; }
         cat "$FAKE_NOW" 2>/dev/null || exit 1 ;;
    *)   exec /usr/bin/env -u PATH /bin/date "$@" ;;
esac
DATESH
chmod +x "$TMP/bin/date"
export FAKE_NOW="$TMP/now"
tick() { printf '%s\n' "$1" > "$FAKE_NOW"; }

with_clock() { PATH="$TMP/bin:$PATH" "$@"; }

# ── time passes when the fixture says so, not when the runner gets around to it
tick 1754000000
rc=0; with_clock rb_elapsed start || rc=$?
{ [ "$rc" -eq 0 ] && [ "$RB_CLOCK_T0" = 1754000000 ] && [ "$RB_ELAPSED" = 0 ]; } \
    && pass "the start is read from the clock" \
    || die "rb_elapsed start gave rc=$rc t0='${RB_CLOCK_T0:-}' elapsed='${RB_ELAPSED:-}'"
tick 1754000042
rc=0; with_clock rb_elapsed || rc=$?
{ [ "$rc" -eq 0 ] && [ "$RB_ELAPSED" = 42 ]; } \
    && pass "forty-two seconds pass in no wall clock at all" \
    || die "rb_elapsed gave rc=$rc elapsed='${RB_ELAPSED:-}' (wanted 0 and 42)"

# ── a clock that steps BACKWARD is unreadable, not a longer deadline ────────
# Without this a backward step extends the bound by however far it went, and a
# repeated one extends it without limit. `pr-watch.sh` shipped that.
tick 1754000030
rc=0; with_clock rb_elapsed || rc=$?
[ "$rc" -ne 0 ] \
    && pass "a clock that steps backward is refused" \
    || die "a backward step was accepted as elapsed='${RB_ELAPSED:-}'"

# ── …and the reading that was refused is not remembered as progress ─────────
# THE STATE MUST SURVIVE THE CALL. Every caller in `pr-watch.sh` once used
# `e="$(elapsed_s)"`, so the update happened in a subshell and was discarded: the
# comparison was always against the START, and 100 → 110 → 105 was accepted.
tick 1754000050
rc=0; with_clock rb_elapsed || rc=$?
{ [ "$rc" -eq 0 ] && [ "$RB_ELAPSED" = 50 ]; } \
    && pass "…and the last accepted reading is what the next one is compared to" \
    || die "rb_elapsed gave rc=$rc elapsed='${RB_ELAPSED:-}' after a refused step"

# ── a `date` that prints a plausible epoch and then FAILS is not a reading ──
# Command substitution keeps what it printed, so an unchecked status leaves the
# elapsed count stuck at a small number and the deadline is never reached.
rc=0; FAKE_RC=3 FAKE_NOW_TEXT=1754000060 with_clock rb_elapsed || rc=$?
[ "$rc" -ne 0 ] \
    && pass "a clock that prints and then fails is refused" \
    || die "a failing date was accepted because it printed something first"

# ── shapes that would wrap or stick ────────────────────────────────────────
# An epoch past Bash's integer range wraps inside the subtraction: a constant
# oversized value keeps elapsed at zero forever, and one appearing later produces
# an immediate ordinary timeout, which a caller re-arms as though the work were
# merely slow.
# `01754000008` is the one a plain all-digit test lets through: Bash reads a
# zero-padded value as OCTAL inside the subtraction and dies on the invalid digit,
# which surfaced in `pr-watch.sh` as an ordinary status rather than the clock
# sentinel — so the driver re-armed the watch as though the review were slow.
for bad in '' 'soon' '17540000x0' '18446744073709551616' '99999999999999999999' '-1754000000' '01754000008' '0000000001'; do
    # THROUGH `start`, WHICH IS THE DISCRIMINATING CALL. A plain `rb_elapsed`
    # refuses a padded reading at the monotonic comparison — `$(( ))` dies on the
    # octal digit — so the case passed for a reason that has nothing to do with
    # the shape check it is written for, and removing `0?*` did not fail it.
    rc=0; tick "$bad"; with_clock rb_elapsed start || rc=$?
    [ "$rc" -ne 0 ] \
        && pass "an unusable clock reading is refused ('$bad')" \
        || die "'$bad' was accepted as an epoch"
done
# …AND THE BOUND IS A CEILING, NOT A FLOOR. Eleven `?` followed by `*` matches
# eleven digits OR MORE, so the obvious spelling rejected exactly the eleven-digit
# epochs it was written to allow — every caller unreadable from 2286 onward.
for good in 1754000000 99999999999; do
    rc=0; tick "$good"; with_clock rb_elapsed start || rc=$?
    [ "$rc" -eq 0 ] \
        && pass "a valid epoch is accepted ('$good')" \
        || die "'$good' was refused, and it is a real epoch"
done

# ── a state variable the caller cannot write is not a reading ──────────────
# A startup hook can leave `RB_ELAPSED` readonly, and a trailing `return 0` then
# reported success over an assignment that never happened: the caller reads a
# stale zero and polls forever. `readonly` cannot be undone from inside, so the
# only answer is to notice — and the status of every assignment is what notices.
# A STATE VARIABLE THE CALLER CANNOT WRITE IS NOT A READING. A startup hook can
# leave `RB_ELAPSED` readonly, and a trailing `return 0` would then report success
# over an assignment that never happened — the caller polling forever against a
# stale zero. Every assignment in the library takes its status for that reason.
#
# IT MUST RETURN, NOT DIE. Assigning to a readonly variable is FATAL in a
# non-interactive shell, so the earlier version of this — assign, then take the
# status — killed the process at that line: no `|| return 1`, no caller handler,
# and `pr-watch.sh` exiting 1 without its sentinel, which the driver treats as an
# ordinary timeout and re-arms. `RC=1` is therefore the whole assertion: the
# status was produced, which means the library refused BEFORE writing.
#
# An earlier version accepted empty output as a refusal and so reported that fatal
# exit as a pass. The load is checked separately too, so a case that never sourced
# the library cannot report this as proven.
#
# WHETHER IT IS FATAL DEPENDS ON THE CONTEXT, measured both ways: in this probe
# the shell prints and carries on, so `|| return 1` produces RC=1 with or without
# the guard above it, and this case does NOT distinguish them. The cases that do
# are at CALLER level in `test-pr-identity.sh`, where the same state kills
# `pr-watch.sh` outright and it exits 1 with no sentinel. Said here so the next
# reader does not take this one for the proof.
#
# THE LIBRARY PATH GOES THROUGH THE ENVIRONMENT, not through nested quoting. The
# first version spliced it into the single-quoted script, the `.` silently failed,
# and the case measured a missing function instead of a readonly variable — so the
# load is checked with its own distinct status.
ro="$(PATH="$TMP/bin:$PATH" FAKE_NOW="$FAKE_NOW" RB_LIB="$SELF_DIR/clocklib.sh" bash -c '
    . "$RB_LIB" || exit 9
    readonly RB_ELAPSED=0
    rb_elapsed start
    echo "RC=$?"' 2>/dev/null)"
[ "$ro" = "RC=1" ] \
    && pass "a readonly state variable is refused, and the caller lives to see the status" \
    || die "a readonly state variable did not produce a clean refusal ($ro)"
[ "$ro" = "RC=9" ] \
    && die "the readonly case never loaded the library, so it proved nothing" \
    || pass "…and that case really did load the library it is about"

# ── A NAMEREF AIMS THESE NAMES AT SOMEONE ELSE'S VARIABLE ──────────────────
# Worse than `readonly`, because nothing FAILS: the assignment succeeds against
# the target, so a writability probe passes and every later guard reports a good
# reading of a clock that is not ours. Only reading the values BACK shows that
# what was stored is not what is there.
#
# `declare -n` is Bash 4.3+, and this suite runs on 3.2 in CI, so the case is
# skipped there rather than asserted as a pass — `BASH_VERSINFO` is a variable, so
# no function can answer for it.
if [ "${BASH_VERSINFO[0]:-0}" -gt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 3 ]; }; then
    # BOTH DIRECTIONS: at a variable outside the trio, which the read-back catches,
    # and at another MEMBER of it, which the read-back cannot — `RB_CLOCK_T0` and
    # `RB_CLOCK_LAST` are deliberately given the same time, so an alias between
    # them survives every same-value check and then makes elapsed `t - t`, zero
    # forever. Distinct probe values inside the subshell are what see it.
    for _alias in RB_ELAPSED RB_CLOCK_LAST; do
        nr="$(PATH="$TMP/bin:$PATH" FAKE_NOW="$FAKE_NOW" RB_LIB="$SELF_DIR/clocklib.sh" \
              RB_ALIAS="$_alias" bash -c '
            . "$RB_LIB" || exit 9
            declare -n RB_CLOCK_T0="$RB_ALIAS"
            rb_elapsed start
            echo "RC=$?"' 2>/dev/null)"
        [ "$nr" = "RC=1" ] \
            && pass "a nameref onto $_alias is refused, though nothing failed to write" \
            || die "a nameref onto $_alias was accepted as a good reading ($nr)"
    done
else
    pass "…(nameref case skipped: Bash ${BASH_VERSINFO[0]:-?}.${BASH_VERSINFO[1]:-?} has no declare -n)"
fi

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
