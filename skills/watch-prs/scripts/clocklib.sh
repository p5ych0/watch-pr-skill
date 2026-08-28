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
# was scoped on #69 and belongs to the callers rather than here: it is a
# startup-semantics change to two installed scripts, with failure modes of its own
# — argument and stdin preservation, exit-status transparency, and the marker
# inheritance `pr-selfcheck.sh` got wrong once already.

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
        # THE STATE IS PROVED WRITABLE, THEN PROVED WRITTEN, and neither step uses
        # a command a startup hook can replace.
        #
        # WRITING BLIND IS NOT AN OPTION: an assignment to a variable a hook left
        # `readonly` is FATAL in a non-interactive shell, so the process dies at
        # that line — no `|| return 1`, no caller handler, and `pr-watch.sh` exits
        # 1 with no sentinel, which the driver reads as an ordinary timeout and
        # RE-ARMS.
        #
        # AND ASKING `declare` IS NOT EITHER. That was the first fix, and a hook
        # that defines `declare() { printf 'declare -- %s\n' "$2"; }` makes every
        # name look like a plain variable, after which the assignment is fatal
        # exactly as before. `CLAUDE.md` records the rule this breaks: a function
        # shadows any name, builtin or not, and the prefixes that would bypass one
        # can be shadowed too — prefer a RESERVED WORD or an ASSIGNMENT, which the
        # parser handles and no function can take the place of.
        #
        # So: a throwaway subshell does the writing that might be fatal, where its
        # death costs nothing and its status is readable. Then the values are read
        # BACK, which is what catches a `declare -n` aiming these names at someone
        # else's variable — that assignment succeeds, so only the read-back shows
        # the value is not the one we stored.
        # DISTINCT PROBE VALUES, VERIFIED INSIDE THE SUBSHELL. Writing the same
        # value to all three said nothing about whether they are the same
        # variable: `declare -n RB_CLOCK_T0=RB_CLOCK_LAST` passes a same-value
        # probe and the read-back below too, because the two are deliberately
        # assigned the same time — and then every elapsed count is `t - t`, zero
        # forever, which is the deadline that never arrives. Distinct values make
        # an alias between them visible; the subshell is where a fatal assignment
        # is safe to attempt at all.
        ( RB_CLOCK_T0=1; RB_CLOCK_LAST=2; RB_ELAPSED=3
          [[ $RB_CLOCK_T0 = 1 && $RB_CLOCK_LAST = 2 && $RB_ELAPSED = 3 ]] ) 2>/dev/null \
            || return 1
        RB_CLOCK_T0="$t"
        RB_CLOCK_LAST="$t"
        RB_ELAPSED=0
        [[ $RB_CLOCK_T0 = "$t" && $RB_CLOCK_LAST = "$t" && $RB_ELAPSED = 0 ]] \
            || return 1
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
