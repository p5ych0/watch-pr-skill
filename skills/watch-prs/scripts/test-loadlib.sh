#!/usr/bin/env bash
# The shared library loader: `rb_load` in loadlib.sh.
#
# Every rule here was previously asserted through whichever caller happened to be
# under review, which is why each one was missing from at least one copy. They are
# proven against the definition now, and `test-pr-identity.sh` proves each caller
# is wired to it. Issue #22.
set -Eeuo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

TMP="$(mktemp_d)" || { die "could not create a scratch directory"; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# Each case runs in its OWN shell. `rb_load` mutates the shell it runs in — that
# is its whole job — so cases sharing one would inherit each other's libraries and
# a later one could pass on an earlier one's symbol, which is the exact confusion
# it exists to prevent.
#
# The library under test is written per case, so "empty", "truncated" and
# "well-formed" are all the same code path with different content.
run_case() {   # run_case <lib body> <pre-loader shell> <rb_load args…>
    local body="$1" pre="$2"; shift 2
    printf '%s\n' "$body" > "$TMP/widgetlib.sh"
    bash -c '
        . "'"$SELF_DIR"'/loadlib.sh"
        eval "$1"
        shift
        rb_load "'"$TMP"'" "$@" && echo "LOADED" || echo "RC=$?"
    ' _ "$pre" "$@" 2>&1
}

# ── the well-formed cases ──────────────────────────────────────────────────
got="$(run_case 'widget_fn() { :; }' '' widgetlib widget_fn PR_X)"
[ "$got" = LOADED ] && pass "a library defining its function loads" \
    || die "a well-formed function library did not load ('$got')"
got="$(run_case 'WIDGET_VAR="something"' '' widgetlib WIDGET_VAR PR_X var)"
[ "$got" = LOADED ] && pass "…and one defining its variable loads" \
    || die "a well-formed variable library did not load ('$got')"

# ── an empty library is refused, whichever kind ────────────────────────────
# A `.` of an empty file SUCCEEDS. Treating that as a loaded library is the whole
# reason the symbol is verified afterwards.
for kind_case in 'func:widget_fn:' 'var:WIDGET_VAR:var'; do
    kind="${kind_case%%:*}"; rest="${kind_case#*:}"
    sym="${rest%%:*}"; arg="${rest##*:}"
    got="$(run_case '' '' widgetlib "$sym" PR_X ${arg:+"$arg"} 2>&1)"
    grep -q 'widgetlib_empty' <<<"$got" \
        && pass "an empty library is refused for a $kind symbol" \
        || die "an empty library loaded for a $kind symbol ('$got')"
done

# ── AN INHERITED SYMBOL DOES NOT COUNT AS A LOADED ONE ─────────────────────
# Bash exports functions through the environment, so a caller that ran
# `export -f` leaves one defined before the `.` — and an empty library still
# sources successfully, so the verification finds the inherited symbol and reports
# the library loaded. What runs after that is a stale definition: the wrong
# repository, an unvalidated record, a watchdog that does not kill.
#
# THE VARIABLE FORM IS THE SAME HOLE, and it is the one that was still open:
# `RECORDLIB_JQ` was checked with `[ -n … ]`, which an exported value satisfies
# exactly as an exported function satisfies `type -t`. Issue #20.
got="$(run_case '' 'widget_fn() { printf stale; }; export -f widget_fn' widgetlib widget_fn PR_X)"
grep -q 'widgetlib_empty' <<<"$got" \
    && pass "an inherited FUNCTION does not satisfy an empty library" \
    || die "an exported function satisfied the load check ('$got')"
got="$(run_case '' 'export WIDGET_VAR=stale' widgetlib WIDGET_VAR PR_X var)"
grep -q 'widgetlib_empty' <<<"$got" \
    && pass "…and neither does an inherited VARIABLE" \
    || die "an exported variable satisfied the load check ('$got')"
# …and the clearing is what does it: after a refusal the stale value is gone, so
# nothing downstream can pick it up from a load that failed.
got="$(bash -c '
    . "'"$SELF_DIR"'/loadlib.sh"
    export WIDGET_VAR=stale
    : > "'"$TMP"'/widgetlib.sh"
    rb_load "'"$TMP"'" widgetlib WIDGET_VAR PR_X var 2>/dev/null
    printf "after=[%s]" "${WIDGET_VAR-unset}"')"
[ "$got" = 'after=[unset]' ] \
    && pass "…and the stale value is gone, not merely disbelieved" \
    || die "a refused load left the inherited value in place ('$got')"

# ── a symbol that CANNOT be cleared is a load failure ──────────────────────
# `readonly` makes the clear fail while leaving the old definition installed, so a
# discarded status made a symbol that could not be removed read exactly like one
# that was never there.
got="$(run_case 'widget_fn() { :; }' 'widget_fn() { printf stale; }; readonly -f widget_fn' \
        widgetlib widget_fn PR_X)"
grep -q 'widgetlib_stale_definition' <<<"$got" \
    && pass "a readonly function that cannot be cleared is a load failure" \
    || die "a readonly function was loaded over ('$got')"
got="$(run_case 'WIDGET_VAR=fresh' 'WIDGET_VAR=stale; readonly WIDGET_VAR' \
        widgetlib WIDGET_VAR PR_X var)"
grep -q 'widgetlib_stale_definition' <<<"$got" \
    && pass "…and so is a readonly variable" \
    || die "a readonly variable was loaded over ('$got')"

# ── a library that is not there ────────────────────────────────────────────
got="$(bash -c '. "'"$SELF_DIR"'/loadlib.sh"; rb_load "'"$TMP"'" nosuchlib nosuch_fn PR_X 2>&1' || true)"
grep -q 'nosuchlib_unreadable' <<<"$got" \
    && pass "a library that cannot be sourced is refused as unreadable" \
    || die "a missing library was not reported ('$got')"

# ── the kind is required to be one of the two ──────────────────────────────
# Getting it wrong is otherwise SILENT: a variable checked as a function is always
# absent, and a function checked as non-empty is always empty — both refuse
# everything, which is a tool nobody can run rather than one that fails closed.
got="$(run_case 'widget_fn() { :; }' '' widgetlib widget_fn PR_X funtion)"
grep -q 'widgetlib_bad_kind' <<<"$got" \
    && pass "a misspelled kind is refused rather than guessed at" \
    || die "an unknown kind was accepted ('$got')"

# ── every refusal names the library and the caller ─────────────────────────
# The sentinel is what a caller's own diagnostics are keyed on, and the library
# name is what tells the reader which of three loads failed. A message with
# neither is a failure with no address.
got="$(run_case '' '' widgetlib widget_fn PR_SOMETHING)"
{ grep -q 'PR_SOMETHING status=error' <<<"$got" && grep -q 'reason=widgetlib_' <<<"$got"; } \
    && pass "a refusal names both the caller's sentinel and the library" \
    || die "a refusal is not addressed ('$got')"
# …and returns 2, which is what every caller branches on.
grep -q 'RC=2' <<<"$got" \
    && pass "…and returns 2, the status the callers exit on" \
    || die "a refusal did not return 2 ('$got')"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
