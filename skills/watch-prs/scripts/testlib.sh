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
    # No `timeout`: run the command in the background and race it against a
    # sleeper. `kill -0` distinguishes "still running" from "already gone", so
    # the watchdog never reports a limit that was not reached.
    "$@" &
    local pid=$!
    local waited=0
    while [ "$waited" -lt "$secs" ]; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 124
    fi
    wait "$pid"
    return $?
}
