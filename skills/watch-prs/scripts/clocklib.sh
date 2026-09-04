#!/usr/bin/env bash
# One clock reader, with the guards a bare `date +%s` has not got. Sourced, never executed.
# `date` is a command rather than `$SECONDS` so that a fixture can own time, and there is
# one function because `rb_load` clears and verifies exactly one name.

# rb_elapsed start   begins a bounded stretch of time
# rb_elapsed         seconds since it began, in RB_ELAPSED
rb_elapsed() {   # rb_elapsed [start] ; sets RB_ELAPSED, non-zero if untrustworthy
    local t _rb_v
    t="$(date +%s 2>/dev/null)" || return 1
    # Twelve `?`, because N marks then `*` matches length N or more; `0?*` because a
    # zero-padded reading is octal inside `$(( ))`.
    case "$t" in
        ""|*[!0-9]*|0?*|????????????*) return 1 ;;
    esac
    if [ "${1-}" = start ]; then
        # An assignment to a readonly name is fatal, so it is tried in a subshell first, with
        # distinct values so a nameref aliasing two of the names shows on the read-back.
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
    # A clock that steps backward is unreadable, not a longer deadline.
    [ "$t" -ge "$RB_CLOCK_LAST" ] || return 1
    RB_CLOCK_LAST="$t" || return 1
    RB_ELAPSED=$(( t - RB_CLOCK_T0 )) || return 1
    return 0
}
