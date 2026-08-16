#!/usr/bin/env bash
# What "how much time has passed" means here. Sourced, never executed.
#
# NOT named `test-*.sh`: `pr-selfcheck.sh` and CI both run every `test-*.sh` as a
# test, and a library that ran as one would report a vacuous pass.
#
# WHY THIS EXISTS
#
# `pr-watch.sh` read the clock with `date +%s` and `pr-ci-gate.sh` with
# `$SECONDS`, and the difference is not a style choice — it decides whether the
# fixture can own time. `$SECONDS` is a Bash builtin, unreachable from `PATH`, so
# `test-pr-ci-gate.sh` could only wait out real seconds and every deadline case
# there was a race against however loaded the runner was. That is issue #38's
# flake, and four attempts to answer it inside the fixture each traded a false
# red for a false green. `date` is a command, so a fixture stubs it and time
# passes exactly when the subject decides to wait. Issue #66.
#
# THE GUARDS ARE THE POINT, and each was paid for in `pr-watch.sh`:
#
#   * `date` can print a plausible epoch and then FAIL, and command substitution
#     keeps what it printed. An elapsed time stuck at a small number means the
#     deadline is never reached.
#   * A value past Bash's integer range wraps inside the subtraction: a constant
#     oversized epoch keeps elapsed at zero forever, and one appearing later
#     produces an immediate ordinary timeout — which a caller re-arms as though
#     the work were merely slow. Both are the clock failing silently.
#   * A clock that steps BACKWARD is unreadable, not a longer deadline. Without
#     that, a backward step extends the bound by however far it went.
#
# One copy, because these are the rules a second copy is always found missing —
# the reason `recordlib.sh` and `identitylib.sh` exist.
#
# WHAT THIS DOES NOT DEFEND AGAINST, and cannot: a startup hook that installs a
# readonly `date`, or a nameref over the state variables, owns the clock before
# this file is read. `date` being shadowable IS the feature — a builtin is what
# `pr-ci-gate.sh` had, and no fixture could reach it — so the usual answer of
# removing the dependency would put the untestable clock back. `command date`
# is not an answer either: `CLAUDE.md` records that a function shadows the
# `command` prefix too. The recorded answer is a guarded re-exec with `BASH_ENV`
# and `ENV` removed, which `pr-selfcheck.sh` does and no other helper does; that
# is issue #69, and it belongs to the callers rather than here.

# ONE FUNCTION, BECAUSE `rb_load` CAN ONLY CLEAR ONE NAME. This was three —
# `rb_now_s`, `rb_clock_start`, `rb_elapsed` — and the loader clears and verifies
# the single symbol it is given. A startup hook that installed a READONLY
# `rb_now_s` returning a constant epoch was therefore untouched by the clear,
# survived the source, and left every caller measuring zero elapsed seconds
# forever: a deadline that never arrives, which is the one failure this file
# exists to prevent. Clearing all three would have been a list, and a list is
# wrong by omission the moment a fourth is added. One name cannot be.
#
#   rb_elapsed start   begins a bounded stretch of time
#   rb_elapsed         seconds since it began, in RB_ELAPSED
#
# EVERY ASSIGNMENT TAKES ITS STATUS. The same hook can make `RB_ELAPSED` readonly,
# and a trailing `return 0` then reported success over an assignment that never
# happened — the caller reading a stale zero and polling forever. `readonly` is
# one of the few things a script cannot undo from inside, so the answer is to
# notice rather than to defend.
rb_elapsed() {   # rb_elapsed [start] ; sets RB_ELAPSED, non-zero if untrustworthy
    local t _rb_v
    t="$(date +%s 2>/dev/null)" || return 1
    # BOUNDED, and NOT ZERO-PADDED. TWELVE `?`, not eleven: `N` question marks
    # followed by `*` matches every string of length N OR MORE, so eleven would
    # reject the eleven-digit epochs it was written to allow — every caller
    # unreadable from 2286 onward. Eleven digits runs to the year 5138.
    #
    # `0?*` because a padded reading is arithmetic in OCTAL: `01754000008` passes
    # every all-digit test and then dies on the invalid digit inside `$(( ))`.
    # In `pr-watch.sh` that surfaced as an ordinary status 1 rather than the clock
    # sentinel, so the driver re-armed the watch as though the review were merely
    # slow — a broken clock reported as patience.
    case "$t" in
        ""|*[!0-9]*|0?*|????????????*) return 1 ;;
    esac
    if [ "${1-}" = start ]; then
        # THE STATE IS CHECKED BEFORE IT IS WRITTEN, because writing is not
        # recoverable. An assignment to a variable a startup hook left `readonly`
        # is FATAL in a non-interactive shell: the process dies at that line, so
        # neither `|| return 1` here nor the caller's handler runs, and
        # `pr-watch.sh` exits 1 without its sentinel — a status the driver treats
        # as an ordinary timeout and RE-ARMS, which is the endless watch this file
        # exists to prevent. Noticing after the fact is not available; the only
        # place to notice is before.
        #
        # ANY ATTRIBUTE, NOT A LIST OF THEM. `readonly` is one way to own these
        # names and `declare -n` is another — a nameref makes the assignment
        # SUCCEED against someone else's variable, so every guard below reports a
        # good reading of a clock that is not ours. Rather than enumerate the
        # attributes that are hostile, anything other than a plain variable is
        # refused, which cannot be wrong by omission.
        for _rb_v in RB_CLOCK_T0 RB_CLOCK_LAST RB_ELAPSED; do
            case "$(declare -p "$_rb_v" 2>/dev/null)" in
                ''|'declare -- '*) ;;
                *) return 1 ;;
            esac
        done
        RB_CLOCK_T0="$t"   || return 1
        RB_CLOCK_LAST="$t" || return 1
        RB_ELAPSED=0       || return 1
        return 0
    fi
    # A clock that steps BACKWARD is unreadable, not a longer deadline: without
    # this a backward step extends the bound by however far it went, and repeated
    # ones extend it without limit.
    [ "$t" -ge "$RB_CLOCK_LAST" ] || return 1
    RB_CLOCK_LAST="$t" || return 1
    RB_ELAPSED=$(( t - RB_CLOCK_T0 )) || return 1
    return 0
}
