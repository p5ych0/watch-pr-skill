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
# ONE SYMBOL IS THE CONTRACT, not a convenience: `rb_load` clears and verifies the
# single name it is given, so a second entry point is one a startup hook can make
# readonly and keep. A definition beside it would pass every case below while the
# caller measured the hook's clock.
_extra="$(type -t rb_now_s 2>/dev/null || true)$(type -t rb_clock_start 2>/dev/null || true)"
[ -z "$_extra" ] \
    && pass "the library exposes one loadable symbol, which is all rb_load can clear" \
    || die "clocklib.sh defines a second entry point rb_load will not clear ('$_extra')"

TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

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
# WHAT THIS CASE PINS IS THE OUTCOME, NOT THE MECHANISM, and it says so because
# the two are not the same here: on the Bash this was written against, the failed
# assignment already returns non-zero without reaching the `return 0`, so removing
# the guard does not change the answer. It may on another — the guard is what
# makes the outcome independent of that — and the assertion is written against
# what a caller can observe: a readonly state variable never yields a SUCCESSFUL
# reading. The load is checked separately so a case that never sourced the library
# cannot report this as proven.
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
[ "$ro" = "RC=0" ] \
    && die "a failed state assignment was reported as a good reading ($ro)" \
    || pass "a readonly state variable is refused, not reported as zero elapsed"
[ "$ro" = "RC=9" ] \
    && die "the readonly case never loaded the library, so it proved nothing" \
    || pass "…and that case really did load the library it is about"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
