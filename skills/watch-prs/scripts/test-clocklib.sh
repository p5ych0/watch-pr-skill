#!/usr/bin/env bash
# The shared clock: `rb_now_s`, `rb_clock_start` and `rb_elapsed` in clocklib.sh.
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

for fn in rb_now_s rb_clock_start rb_elapsed; do
    [ "$(type -t "$fn" 2>/dev/null)" = function ] \
        || { die "clocklib.sh does not define $fn"; echo "RESULT: FAIL"; exit 1; }
done

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
rc=0; with_clock rb_clock_start || rc=$?
{ [ "$rc" -eq 0 ] && [ "$RB_CLOCK_T0" = 1754000000 ]; } \
    && pass "the start is read from the clock" \
    || die "rb_clock_start gave rc=$rc t0='${RB_CLOCK_T0:-}'"
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
rc=0; FAKE_RC=3 FAKE_NOW_TEXT=1754000060 with_clock rb_now_s >/dev/null || rc=$?
[ "$rc" -ne 0 ] \
    && pass "a clock that prints and then fails is refused" \
    || die "a failing date was accepted because it printed something first"

# ── shapes that would wrap or stick ────────────────────────────────────────
# An epoch past Bash's integer range wraps inside the subtraction: a constant
# oversized value keeps elapsed at zero forever, and one appearing later produces
# an immediate ordinary timeout, which a caller re-arms as though the work were
# merely slow.
for bad in '' 'soon' '17540000x0' '18446744073709551616' '99999999999999999999' '-1754000000'; do
    rc=0; tick "$bad"; with_clock rb_now_s >/dev/null || rc=$?
    [ "$rc" -ne 0 ] \
        && pass "an unusable clock reading is refused ('$bad')" \
        || die "'$bad' was accepted as an epoch"
done
# …AND THE BOUND IS A CEILING, NOT A FLOOR. Eleven `?` followed by `*` matches
# eleven digits OR MORE, so the obvious spelling rejected exactly the eleven-digit
# epochs it was written to allow — every caller unreadable from 2286 onward.
for good in 1754000000 99999999999; do
    rc=0; tick "$good"; with_clock rb_now_s >/dev/null || rc=$?
    [ "$rc" -eq 0 ] \
        && pass "a valid epoch is accepted ('$good')" \
        || die "'$good' was refused, and it is a real epoch"
done

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
