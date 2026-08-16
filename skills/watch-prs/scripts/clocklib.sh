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

# The current epoch second, or non-zero if the clock cannot be trusted.
rb_now_s() {
    local t
    t="$(date +%s 2>/dev/null)" || return 1
    # BOUNDED, not merely all-digit. TWELVE `?`, not eleven: `N` question marks
    # followed by `*` matches every string of length N OR MORE, so eleven would
    # reject the eleven-digit epochs it was written to allow, and every caller
    # would report an unreadable clock from 2286 onward. Eleven digits runs to
    # the year 5138.
    case "$t" in
        ""|*[!0-9]*|????????????*) return 1 ;;
    esac
    printf '%s' "$t"
}

# Start a bounded stretch of time. Sets RB_CLOCK_T0 and RB_CLOCK_LAST.
rb_clock_start() {
    local t
    t="$(rb_now_s)" || return 1
    RB_CLOCK_T0="$t"
    RB_CLOCK_LAST="$t"
    return 0
}

# Seconds since `rb_clock_start`, in RB_ELAPSED. Non-zero when the clock cannot
# be trusted — which callers must treat as an error and never as "no time has
# passed", the reading that turns a bounded loop into an unbounded one.
rb_elapsed() {
    local t
    t="$(rb_now_s)" || return 1
    [ "$t" -ge "$RB_CLOCK_LAST" ] || return 1
    RB_CLOCK_LAST="$t"
    RB_ELAPSED=$(( t - RB_CLOCK_T0 ))
    return 0
}
