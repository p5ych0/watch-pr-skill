#!/usr/bin/env bash
# Ships at runtime inside `pr-ci-state.sh`, so nothing here may unset an exported value.

# Bounded for a command that waits for its children; one that backgrounds a child and exits
# keeps the caller's capture open until the orphan ends.
run_limited() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        # Only a `timeout` that takes `-k` is used: TERM alone leaves a command that traps it
        # running past the limit, and the fallback below escalates to KILL itself.
        if [ -z "${_RB_TIMEOUT_KILL_AFTER:-}" ]; then
            if timeout -k 1 1 true >/dev/null 2>&1; then
                _RB_TIMEOUT_KILL_AFTER=yes
            else
                _RB_TIMEOUT_KILL_AFTER=no
            fi
        fi
        if [ "$_RB_TIMEOUT_KILL_AFTER" = yes ]; then
            timeout -k 5 "$secs" "$@"
            return $?
        fi
    fi
    # Output goes to files this shell replays, since a child holding the caller's capture pipe
    # blocks the substitution past the limit; stderr apart, since a runtime caller matches it.
    local tmp
    tmp="$(mktemp 2>/dev/null)" || return 125
    local tmperr
    tmperr="$(mktemp 2>/dev/null)" || { rm -f "$tmp" 2>/dev/null; return 125; }
    set -m
    # `<&0` keeps the caller's stdin: a background job gets /dev/null without it.
    ( "$@" ) >"$tmp" 2>"$tmperr" <&0 &
    local pid=$!
    set +m
    local waited=0
    # A `sleep` that fails is a broken clock, not a timeout; 125, not 2, which a command can return.
    while [ "$waited" -lt "$secs" ]; do
        { kill -0 -"$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null; } || break
        if ! sleep 1; then
            kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            rm -f "$tmp" "$tmperr" 2>/dev/null
            return 125
        fi
        waited=$((waited + 1))
    done
    local rc
    if kill -0 -"$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null; then
        # The group first; killing the leader alone leaves its children running.
        kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rc=124
    else
        wait "$pid"; rc=$?
    fi
    # Each replay takes its own status: a `cat` that emits a partial buffer and then fails
    # would hand the caller a truncated capture under the command's own 0.
    cat "$tmp"; local read_rc=$?
    cat "$tmperr" >&2; local read_err_rc=$?
    rm -f "$tmp" "$tmperr" 2>/dev/null
    [ "$read_err_rc" -eq 0 ] || return 125
    [ "$read_rc" -eq 0 ] || return 125
    return "$rc"
}

# Never a bare `mktemp -d`: it can print a plausible path and fail, and the caller's EXIT
# trap then runs `rm -rf` over wherever `$TMP/bin` resolved to.
mktemp_d() {
    local d
    d="$(mktemp -d 2>/dev/null)" || return 1
    case "$d" in
        ""|/|/.|/..) return 1 ;;
        /*) ;;
        *)  return 1 ;;
    esac
    [ -d "$d" ] || return 1
    printf '%s' "$d"
}
