#!/usr/bin/env bash
# How a shipped script loads a shared library. Sourced, never executed.
#
# NOT named `test-*.sh`: `pr-selfcheck.sh` and CI both run every `test-*.sh` as a
# test, and a library that ran as one would report a vacuous pass.
#
# WHY THIS EXISTS
#
# Loading a library was written out four times, and every rule in it was added
# AFTER a copy was found missing it — the pattern issues #11 and #18 were both
# opened for. Issue #22.
#
#   * Clearing an inherited definition, because Bash exports functions through the
#     environment: a caller that ran `export -f rb_identity` leaves one defined
#     before the `.`, and a library that is EMPTY or truncated above its
#     definition still sources successfully. The verification then finds the
#     inherited symbol and reports the library loaded.
#   * Taking the CLEARING's status, because `readonly -f` makes the unset fail
#     while leaving the old definition installed — a definition that cannot be
#     removed reading exactly like one that was never there.
#   * Verifying that the library defined anything, rather than treating a
#     successful `.` as a loaded library.
#
# Each landed in whichever copy was under review at the time. What a stale or
# empty library costs differs per case — the wrong repository, an unvalidated
# record, a watchdog that does not kill — but the loading rule is identical.
#
# THE BOOTSTRAP IS THE ONE THING THAT CANNOT USE THIS. Every caller writes the
# sequence out itself — clear, take the clear's status, define a refusing stub,
# source — because a helper cannot load the file that defines it. Taking the
# CLEARING's status is a separate step on purpose: describing it as part of the
# clear is how it comes to be the step that gets collapsed.
#
# THERE IS NO `type -t` VERIFICATION IN IT, and the FIRST LOAD is what replaced
# one: calling an `rb_load` that does not exist fails exactly as an empty library
# would, and the handler on that call names it `reason=loadlib_empty`. The stub is
# what makes that true rather than optional — an `rb_load` that is not a function
# is looked up on `PATH`, which privileged startup does not change, and an
# executable by that name exiting 0 would report every load successful with
# nothing cleared and no library sourced. #88.
#
# The asymmetry is irreducible; it is stated here so the next reader does not
# spend time looking for the trick that removes it.

# Load a library and prove it loaded.
#
#   rb_load <dir> <lib-basename> <symbol> <error-prefix> [func|var]
#
#   rb_load "$_RB_SELF_DIR" recordlib RECORDLIB_JQ "PR_FINDINGS status=error" var || exit 2
#
# Prints `<error-prefix> reason=<lib>_<what>` to stderr and returns 2 on any
# failure; returns 0 with the library loaded otherwise.
#
# THE WHOLE PREFIX IS THE CALLER'S, not just its name. `pr-watch.sh` reports
# `state=error` where the others report `status=error`, and a loader that supplied
# the key would either impose one spelling on a script whose every other line uses
# the other, or emit `state=error status=error`. It knows the reason; the caller
# knows how it says "this failed".
#
# THE KIND MATTERS, and getting it wrong is silent. A function is cleared with
# `unset -f` and verified with `type -t`; a variable is cleared with `unset` and
# verified as non-empty. `RECORDLIB_JQ` is a variable, and an exported one
# satisfies a non-empty test against an empty library exactly as an exported
# function satisfies a `type -t` — which is issue #20, and is why this takes the
# kind rather than guessing from the name.
rb_load() {
    local dir="$1" lib="$2" sym="$3" prefix="$4" kind="${5:-func}"
    case "$kind" in
        func|var) ;;
        *) echo "$prefix reason=${lib}_bad_kind kind=$kind" >&2; return 2 ;;
    esac
    # Cleared BEFORE the source, and the clearing is checked. `unset` of a name
    # that is not set returns 0, so the only thing a non-zero status here means is
    # that something survived — which is exactly the condition to refuse on.
    if [ "$kind" = func ]; then
        unset -f "$sym" 2>/dev/null || {
            echo "$prefix reason=${lib}_stale_definition" >&2; return 2; }
    else
        unset "$sym" 2>/dev/null || {
            echo "$prefix reason=${lib}_stale_definition" >&2; return 2; }
    fi
    # shellcheck disable=SC1090
    . "$dir/$lib.sh" || {
        echo "$prefix reason=${lib}_unreadable" >&2; return 2; }
    # ── `type` IS A NAME, AND THAT IS ACCEPTED HERE RATHER THAN GUESSED AT ──
    #
    # A `type() { return 1; }` inherited from the operator's shell turns a
    # perfectly good library into `reason=${lib}_empty`. Measured; it fails in the
    # safe direction, but it fails, and the loop stops on nothing being wrong.
    #
    # #88 REMOVED THE SAME CALL FROM THE TEN HELPERS that wrap this one, because
    # there the verification has somewhere to go: a refusing stub, and a first
    # load whose failure IS the check. That does not transfer here.
    # Asking whether a NAME is a function needs `type`, `declare` or `command` —
    # all shadowable — or calling the symbol, and calling an arbitrary library
    # function as a probe runs it: `rb_identity` would shell out to `git`.
    #
    # The alternatives were weighed on #96 and each costs more than it buys:
    # dropping the check moves the failure to the caller's first use and loses the
    # precise `reason=`, and a subshell probe forks per load and still executes
    # the function. So the check stays, on the boundary #76 settled — this needs
    # an exported function in the operator's own shell, and a shell that can do
    # that can edit this library instead.
    if [ "$kind" = func ]; then
        [ "$(type -t "$sym" 2>/dev/null)" = function ] || {
            echo "$prefix reason=${lib}_empty" >&2; return 2; }
    else
        [ -n "${!sym:-}" ] || {
            echo "$prefix reason=${lib}_empty" >&2; return 2; }
    fi
    return 0
}
