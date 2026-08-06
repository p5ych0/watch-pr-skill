#!/usr/bin/env bash
# Shared helpers for the suite. Sourced, never executed.
#
# NOT named `test-*.sh`: `pr-selfcheck.sh` and CI both run every `test-*.sh` as a
# test, and a library that ran as one would report a vacuous pass.
#
# WHY THIS EXISTS
#
# The fixtures need a watchdog — several of them assert that a guard turns an
# endless walk into a status, and without a time limit a regression hangs the
# suite instead of failing it. They used GNU `timeout`, which stock macOS does
# not ship. Since `pr-selfcheck.sh` runs the whole suite as a MANDATORY pre-push
# gate and treats any failing test as a finding, that made the gate unpassable on
# a platform `README.md` calls supported — an undocumented Coreutils dependency
# standing between a contributor and their first push.

# Run a command with a wall-clock limit, using `timeout` when it exists and a
# background watchdog when it does not.
#
#   run_limited <seconds> <command...>
#
# Returns the command's status, or 124 when the limit was hit — the same code
# GNU `timeout` uses, so assertions read identically either way.
run_limited() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return $?
    fi
    # No `timeout`: run the command in its own PROCESS GROUP and kill the group.
    #
    # Killing the top-level PID alone was not enough. Callers capture this with
    # command substitution, so a surviving child that inherited stdout keeps the
    # capture pipe open — and the shell blocks on the read regardless of the dead
    # parent. The suite is a mandatory pre-push gate, so that hangs the gate past
    # the limit it advertises, which is the one thing the watchdog exists to
    # prevent.
    #
    # `set -m` gives the background job its own process group with `$!` as the
    # leader, so `kill -9 -$pid` reaches every descendant. It is turned back off
    # immediately: leaving job control on changes signal handling for the rest of
    # the caller.
    set -m
    "$@" &
    local pid=$!
    set +m
    local waited=0
    while [ "$waited" -lt "$secs" ]; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        # The group first, then the leader as a fallback for a shell that gave
        # the job no group of its own.
        kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 124
    fi
    wait "$pid"
    return $?
}
