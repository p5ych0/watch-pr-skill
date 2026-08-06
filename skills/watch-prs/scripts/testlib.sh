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
    # No `timeout`. Two things have to hold, and the second is what the
    # earlier versions kept getting wrong:
    #
    #   1. the limit is enforced — poll, then kill;
    #   2. the CALLER's capture must not outlive the limit.
    #
    # (2) is the harder one. Callers use command substitution, so anything still
    # holding the inherited stdout keeps the pipe open and the shell blocks on
    # the read no matter what happened to the process that was killed. Killing
    # the leader left children holding it; killing the process group missed a
    # child whose leader had already exited; and `set -m` inside a
    # command-substitution subshell does not reliably create a group to kill.
    #
    # So the child never gets the pipe at all: output goes to a temp file and is
    # printed by THIS shell once the command is done or killed. Nothing the
    # command spawns can hold the capture open, whatever survives.
    local tmp
    tmp="$(mktemp)" || return 2
    # `exec` the redirections FIRST, inside the subshell, and detach stdin too.
    # Redirecting the job itself still left a window between fork and redirect in
    # which the child held the substitution pipe, and anything it spawned kept
    # that descriptor — so `sh -c 'sleep 30 &'` returned instantly from here while
    # the CALLER's capture blocked for the full thirty seconds. Nothing inherits
    # the pipe now, so the capture closes when this shell is done with it.
    # Output goes to a temp file, never to the caller's capture pipe, and the
    # command is killed at the limit.
    #
    # WHAT THIS DOES NOT SOLVE, stated rather than papered over: a command that
    # backgrounds a child and then EXITS — `sh -c 'sleep 30 &'` — leaves an
    # orphan that keeps the caller's command substitution blocked until it
    # finishes on its own, regardless of what is killed here. Redirecting the
    # job, detaching its descriptors with `exec`, and running it under `setsid`
    # were each tried and none of them close the caller's pipe; the descriptor is
    # inherited before any of them take effect.
    #
    # It is bounded for every command that WAITS for its own children, which is
    # all this suite runs, and the fixture below covers that case. A fixture for
    # the orphan case would assert behaviour this helper does not have, so it is
    # recorded as a limitation instead of tested as a feature.
    "$@" >"$tmp" 2>&1 </dev/null &
    local pid=$!
    local waited=0
    # THE SLEEP IS THE WATCHDOG. If it fails, the loop still advanced `waited`
    # and burned through the limit at once, killed the command and returned an
    # ordinary 124 — so a fixture asserting "this hangs, so it times out" passed
    # while no wall-clock limit was in force at all, which is the exact
    # failure-looks-like-success shape this suite exists to catch. A broken clock
    # is unreadable, not a timeout.
    while [ "$waited" -lt "$secs" ]; do
        kill -0 "$pid" 2>/dev/null || break
        if ! sleep 1; then
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            rm -f "$tmp" 2>/dev/null
            return 125
        fi
        waited=$((waited + 1))
    done
    local rc
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rc=124
    else
        wait "$pid"; rc=$?
    fi
    # THE READ HAS ITS OWN STATUS, taken before `rm` overwrites it. `cat` can
    # emit a partial buffer and then fail; the command's own 0 was then returned
    # and the caller compared a truncated capture against its expectation. Where
    # that expectation is a prefix or a `grep`, it still matched, and a mandatory
    # gate reported PASS on output it never finished reading.
    cat "$tmp"; local read_rc=$?
    rm -f "$tmp" 2>/dev/null
    # 125 for "the watchdog itself could not do its job", distinct from 124 (the
    # limit was hit) and from the command's own status. GNU `timeout` uses 125
    # the same way, so the two paths still read alike.
    [ "$read_rc" -eq 0 ] || return 125
    return "$rc"
}
