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
# is driver-agnostic and a same-SHA retry never double-counts. Recording is
# flock-serialized so a manual + passive enqueue racing the same boundary cannot
# write a duplicate line (which would inflate the count).
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
# -> run "<fn> <args>" holding an EXCLUSIVE lock, so the whole critical section is
#    serialized. Prefers flock; falls back to an ATOMIC mkdir mutex where flock is
#    absent — never a lock-less run (that would restore the check-then-claim race).
#    The mkdir mutex is POSIX-atomic (only one creator wins) with a bounded spin +
#    stale-lock steal so a crashed holder can't wedge the counter forever. Set
#    REVIEW_BUS_FORCE_NO_FLOCK=1 to exercise the fallback where flock exists.
_review_bus_locked() {
    local base="$1"; shift
    if [ -z "${REVIEW_BUS_FORCE_NO_FLOCK:-}" ] && command -v flock >/dev/null 2>&1; then
        ( flock 9; "$@" ) 9>>"${base}.lock"
    else
        local lock="${base}.lockd" tries=0 rc
        until mkdir "$lock" 2>/dev/null; do
            tries=$((tries + 1))
            [ "$tries" -ge 500 ] && { rmdir "$lock" 2>/dev/null || true; tries=0; }   # ~5s → steal a dead holder
            sleep 0.01
        done
        "$@"; rc=$?
        rmdir "$lock" 2>/dev/null || true
        return "$rc"
    fi
}

# _review_bus_append_once <file> <sha> — dedup append (the record body; run locked).
_review_bus_append_once() {
    grep -qxF "$2" "$1" 2>/dev/null || printf '%s\n' "$2" >> "$1"
}

# review_bus_record_round <bus_dir> <pr> <full_sha>
# -> append the sha as a closed round (deduped, atomically). Unconditional record
#    (no pause decision) — used only on the operator's explicit --continue-threshold
#    cross. The normal path uses review_bus_claim_round.
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
#    Prints: pause (at a threshold multiple — do NOT enqueue) | claimed (recorded,
#    enqueue) | already (this sha was already recorded — idempotent, enqueue).
review_bus_claim_round() {
    local bus="$1" pr="$2" sha="$3" threshold="$4" f
    f="$(_review_bus_rounds_file "$bus" "$pr")"; mkdir -p "$(dirname "$f")"
    _review_bus_locked "$f" _review_bus_claim_locked "$f" "$bus" "$pr" "$sha" "$threshold"
}
