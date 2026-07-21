#!/usr/bin/env bash
# Shared round-count check-in helpers for the review bus.
#
# Sourced by BOTH enqueue paths so the operator check-in cannot be bypassed:
#   - the MANUAL path  (review-bus-request.sh), and
#   - the PASSIVE path (the watcher's write_auto_request, reached from
#     auto_enqueue_open_pr_heads).
#
# A "round" is a DISTINCT enqueued full SHA for a PR, recorded one-per-line in
# $BUS/.rounds/pr-<PR>.shas. Counting distinct SHAs (not commit-message prefixes)
# is driver-agnostic and a same-SHA retry never double-counts. The threshold check
# and the round record run in ONE critical section, serialized by a single atomic
# mkdir mutex (_review_bus_locked) shared by every process, so a manual + passive
# enqueue racing the same boundary cannot both cross it or write a duplicate line.
#
# Pure functions, no global state — safe to source anywhere; all inputs are args.

# _review_bus_rounds_file <bus_dir> <pr>
_review_bus_rounds_file() { printf '%s/.rounds/pr-%s.shas' "$1" "$2"; }

# review_bus_rounds_done <bus_dir> <pr> -> echoes the count of distinct enqueued SHAs.
review_bus_rounds_done() {
    local f; f="$(_review_bus_rounds_file "$1" "$2")"
    if [ -f "$f" ]; then grep -c . "$f" 2>/dev/null || echo 0; else echo 0; fi
}

# review_bus_threshold_reached <bus_dir> <pr> <full_sha> <threshold>
# -> exit 0 iff enqueuing this NEW sha would cross a non-zero multiple of the
#    threshold (threshold<=0 disables; an already-recorded sha never re-triggers).
review_bus_threshold_reached() {
    local bus="$1" pr="$2" sha="$3" threshold="$4" f done
    [ "${threshold:-0}" -gt 0 ] 2>/dev/null || return 1
    f="$(_review_bus_rounds_file "$bus" "$pr")"
    done="$(review_bus_rounds_done "$bus" "$pr")"
    [ "$done" -gt 0 ] && [ $((done % threshold)) -eq 0 ] \
        && ! grep -qxF "$sha" "$f" 2>/dev/null
}

# _review_bus_locked <lock_base> <fn> <args...>
# -> run "<fn> <args>" holding an EXCLUSIVE lock so the whole critical section is
#    serialized. ONE mutex mechanism for ALL processes (manual request + systemd
#    watcher) — an atomic mkdir mutex — so there is no way for two peers to end up
#    in different lock domains and both enter. (An earlier flock-preferred version
#    split the domain: flock and the mkdir fallback locked different objects.)
#
#    mkdir is POSIX-atomic (one creator wins). A stale lock is reclaimed ONLY when
#    its recorded holder is PROVABLY dead: kill -0 on a live/slow/scheduled PID
#    always succeeds, so a live holder is never evicted; a reused PID reads alive,
#    so we wait (never mis-steal). The reclaim uses an atomic rename to drop the
#    EXACT stale dir, so two waiters can't both remove it and evict a fresh holder.
#    If the lock cannot be acquired within the bound (an unprobeable/wedged holder),
#    it FAILS CLOSED (returns 75) — callers then do NOT enqueue.
_review_bus_locked() {
    local base="$1"; shift
    local lock="${base}.lockd" pidf="${base}.lockd/pid" holder reap rc tries=0
    local max="${REVIEW_BUS_LOCK_TIMEOUT_TICKS:-3000}"   # ~10ms ticks; default ~30s
    while ! mkdir "$lock" 2>/dev/null; do
        holder="$(cat "$pidf" 2>/dev/null || true)"
        if [ -n "$holder" ] && [ "$holder" != "$BASHPID" ] && ! kill -0 "$holder" 2>/dev/null; then
            # Provably-dead holder → atomically claim + drop THIS stale dir only.
            reap="${lock}.reap.$BASHPID.${RANDOM}"
            mv "$lock" "$reap" 2>/dev/null && rm -rf "$reap" 2>/dev/null || true
            continue
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge "$max" ]; then
            echo "REVIEW_BUS_LOCK_TIMEOUT base=$base holder=${holder:-unknown} — stale lock? remove ${lock} if no reviewer is running" >&2
            return 75
        fi
        sleep 0.01
    done
    printf '%s\n' "$BASHPID" > "$pidf" 2>/dev/null || true
    "$@"; rc=$?
    rm -rf "$lock" 2>/dev/null || true
    return "$rc"
}

# _review_bus_append_once <file> <sha> — dedup append (the record body; run locked).
_review_bus_append_once() {
    grep -qxF "$2" "$1" 2>/dev/null || printf '%s\n' "$2" >> "$1"
}

# review_bus_record_round <bus_dir> <pr> <full_sha>
# -> append the sha as a closed round (deduped, atomically). Unconditional record
#    (no pause decision) — used only on the operator's explicit --continue-threshold
#    cross. The normal path uses review_bus_claim_round. Returns non-zero (75) if
#    the lock could not be acquired (fail closed → the caller must not enqueue).
review_bus_record_round() {
    local bus="$1" pr="$2" sha="$3" f
    f="$(_review_bus_rounds_file "$bus" "$pr")"; mkdir -p "$(dirname "$f")"
    _review_bus_locked "$f" _review_bus_append_once "$f" "$sha"
}

# _review_bus_claim_locked <file> <bus> <pr> <sha> <threshold> — the atomic body.
# Under the caller's lock: decide pause-vs-claim from the CURRENT count and, when
# claiming, append in the SAME critical section. Prints: pause | claimed | already.
_review_bus_claim_locked() {
    local f="$1" bus="$2" pr="$3" sha="$4" threshold="$5" d
    if grep -qxF "$sha" "$f" 2>/dev/null; then echo already; return 0; fi
    d="$(review_bus_rounds_done "$bus" "$pr")"
    if [ "${threshold:-0}" -gt 0 ] 2>/dev/null && [ "$d" -gt 0 ] && [ $((d % threshold)) -eq 0 ]; then
        echo pause; return 0
    fi
    printf '%s\n' "$sha" >> "$f"
    echo claimed
}

# review_bus_claim_round <bus_dir> <pr> <full_sha> <threshold>
# -> ONE lock-scoped check-and-claim, so the threshold decision and the round
#    append are atomic. Closes the safety-gate TOCTOU: two distinct-SHA enqueues
#    at the boundary cannot both read the pre-threshold count and both proceed —
#    the first claims the round, the second (seeing the incremented count) pauses.
#    Prints one of: claimed (recorded → enqueue) | already (this sha already
#    recorded → idempotent, enqueue) | pause (at a threshold multiple → do NOT
#    enqueue) | locktimeout (lock unavailable → fail closed, do NOT enqueue).
#
#    The status is the printed TOKEN and the function ALWAYS returns 0, so a bare
#    `claim="$(review_bus_claim_round …)"` under `set -e` never aborts the caller
#    before it can branch on the token (a non-zero here would trip the assignment).
#    The inner substitution is `|| rc=$?`-guarded for the same reason.
review_bus_claim_round() {
    local bus="$1" pr="$2" sha="$3" threshold="$4" f out rc=0
    f="$(_review_bus_rounds_file "$bus" "$pr")"; mkdir -p "$(dirname "$f")"
    out="$(_review_bus_locked "$f" _review_bus_claim_locked "$f" "$bus" "$pr" "$sha" "$threshold")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then echo locktimeout; return 0; fi
    printf '%s\n' "$out"
    return 0
}
