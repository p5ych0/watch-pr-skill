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
        # `-k`, because plain `timeout` sends TERM and stops there: a command that
        # traps or ignores TERM — or a wrapper whose child does — survives the
        # limit and the call never returns, which defeats every bound built on
        # this. The fallback below already escalates to KILL; this arm did not,
        # and it is the arm that runs wherever GNU coreutils exist.
        #
        # The capability is probed ONCE and cached: not every `timeout` in the
        # wild takes `-k`, and a usage error would otherwise be indistinguishable
        # from the command failing. `true` returns immediately, so the probe costs
        # nothing despite the one-second arguments.
        if [ -z "${_RB_TIMEOUT_KILL_AFTER:-}" ]; then
            if timeout -k 1 1 true >/dev/null 2>&1; then
                _RB_TIMEOUT_KILL_AFTER=yes
            else
                _RB_TIMEOUT_KILL_AFTER=no
            fi
        fi
        if [ "$_RB_TIMEOUT_KILL_AFTER" = yes ]; then
            timeout -k 5 "$secs" "$@"
        else
            timeout "$secs" "$@"
        fi
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
    # 125 for a watchdog that could not set itself up — NOT 2. Two is a status the
    # bounded command legitimately returns and that several fixtures assert as
    # their primary expectation, so a broken watchdog satisfied them without ever
    # running the subject. It joins the failed-clock and failed-read paths below,
    # which already use 125 for exactly this reason.
    local tmp
    tmp="$(mktemp 2>/dev/null)" || return 125
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
    # `set -m` puts the command in its own PROCESS GROUP, so the kill below reaches
    # what it spawned. Killing the leader alone left descendants running: the
    # `sh -c "sleep 30 & wait"` case here returns 124 with its `sleep` orphaned,
    # and a mandatory suite that leaks a process per run leaks one per run forever.
    # The group is what has to die, not the process that happened to lead it.
    # STDERR STAYS SEPARATE. It used to be folded into the stdout file, which is
    # invisible while every caller was a fixture capturing `2>&1` anyway — and
    # then a RUNTIME caller appeared that distinguishes them. `pr-ci-state.sh`
    # decides "no checks are configured" by matching the whole `gh` diagnostic on
    # stderr; merged, its own `2>` capture received nothing, the exact-message
    # branch could never fire, and on any platform without GNU `timeout` a
    # repository with no checks blocked every round and every merge. The fallback
    # is the only path there, so the bug was invisible wherever `timeout` exists.
    local tmperr
    tmperr="$(mktemp 2>/dev/null)" || { rm -f "$tmp" 2>/dev/null; return 125; }
    set -m
    ( "$@" ) >"$tmp" 2>"$tmperr" </dev/null &
    local pid=$!
    set +m
    local waited=0
    # THE SLEEP IS THE WATCHDOG. If it fails, the loop still advanced `waited`
    # and burned through the limit at once, killed the command and returned an
    # ordinary 124 — so a fixture asserting "this hangs, so it times out" passed
    # while no wall-clock limit was in force at all, which is the exact
    # failure-looks-like-success shape this suite exists to catch. A broken clock
    # is unreadable, not a timeout.
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
        # The GROUP first, the leader only as a fallback where the group never
        # formed. A leader-only kill is what left the orphan.
        kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
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
    # The stderr replay has its own status for the same reason the stdout read
    # does: a `cat` that emits a partial diagnostic and then fails hands the
    # caller a truncated message it will match against.
    cat "$tmperr" >&2; local read_err_rc=$?
    rm -f "$tmp" "$tmperr" 2>/dev/null
    [ "$read_err_rc" -eq 0 ] || return 125
    # 125 for "the watchdog itself could not do its job", distinct from 124 (the
    # limit was hit) and from the command's own status. GNU `timeout` uses 125
    # the same way, so the two paths still read alike.
    [ "$read_rc" -eq 0 ] || return 125
    return "$rc"
}

# A scratch directory, or the caller stops. Never a bare `mktemp -d`.
#
#   dir="$(mktemp_d)" || exit 1
#
# `mktemp` can fail — a full or read-only $TMPDIR — and it can print a plausible
# path before failing. Command substitution keeps both, and an UNCHECKED
# assignment then leaves the caller with an empty or untrusted `$TMP`: every
# `$TMP/bin`, `$TMP/broke`, `$TMP/catf` under it resolves to `/bin`, `/broke`,
# `/catf` instead of inside a fixture, and the EXIT trap that follows runs
# `rm -rf` over whatever that turned out to be. Every test file in this suite had
# the bare form, which in a root-run container is a `rm -rf /bin`.
#
# So the path is required to be non-empty, absolute, not `/`, and an existing
# directory — the last one is what proves `mktemp` actually created it rather
# than merely having printed something.
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
