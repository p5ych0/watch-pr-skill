#!/usr/bin/env bash
# Emit <PREFIX>_REVIEW lines for a project's Codex review-bus responses.
# Single-domain + universal: repo / prefix / bus-dir are derived from THIS
# checkout's git origin, so the identical script drives whatever project it
# lives in — no hardcoded repo.
#
# This intentionally replays existing response files on startup so a Claude
# session that starts after Codex finishes still receives the handoff.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)}"
REMOTE="${REVIEW_BUS_REMOTE:-$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)}"
if [ -n "$REMOTE" ]; then
    _p="${REMOTE%.git}"; REPO="${REVIEW_BUS_REPO:-${_p##*/}}"; _p="${_p%/*}"; OWNER="${REVIEW_BUS_OWNER:-${_p##*[:/]}}"
else
    REPO="${REVIEW_BUS_REPO:-review}"; OWNER="${REVIEW_BUS_OWNER:-}"
fi
PREFIX="${REVIEW_BUS_PREFIX:-$(printf '%s' "$REPO" | tr '[:lower:]-' '[:upper:]_')}"
# Owner-scoped bus dir — must match the watcher/start/request derivation.
BUS_SLUG="$(printf '%s' "${OWNER:+${OWNER}-}${REPO}" | tr -c 'A-Za-z0-9._-' '-')"
BUS_DIR="${BUS_DIR:-/tmp/${BUS_SLUG:-review}-review-bus}"
RESP_DIR="$BUS_DIR/responses"
# Two-marker delivery model (both keyed on response base + content digest):
#   EMITTED_DIR — WITHIN-session dedup. A per-session reader (the Claude Monitor)
#     sets MONITOR_EMITTED_DIR to a FRESH dir each session, so a response that was
#     printed but not yet acted on (session died mid-handling) re-surfaces on the
#     next session instead of being suppressed forever by a stale marker.
#   ACK_DIR — persistent "handled" markers, written via `--ack <resp>` after the
#     session closes a round out (resolve + re-request) or merges. Replay skips an
#     ACKED response regardless of emit state, so already-handled/merged responses
#     are never re-fired even though EMITTED_DIR is fresh each session.
# The daemon audit-log monitor leaves MONITOR_EMITTED_DIR unset (persistent dir).
EMITTED_DIR="${MONITOR_EMITTED_DIR:-$BUS_DIR/.monitor-emitted}"
ACK_DIR="${MONITOR_ACK_DIR:-$BUS_DIR/.monitor-acked}"

# ── Live review progress (repository-scoped) ────────────────────────────────
# The watcher writes structured lifecycle state under $BUS/progress/ as a review
# advances; here we surface it as THROTTLED <PREFIX>_REVIEW_PROGRESS lines so the
# attached chat sees a review start + phase changes + heartbeats WITHOUT waiting
# for the terminal resp-<sha>.json. Progress lines are NEVER <PREFIX>_REVIEW, so
# they can't be mistaken for the final findings handoff. Same bus dir only —
# never cross-project. Safe default detail = counters + phase (no reasoning text).
# Coerce a knob to a POSITIVE integer, else the default. A non-integer / empty /
# 0 / negative value would make the numeric `[ -lt/-ge ]` tests (and inotifywait
# `-t`) below ERROR under `set -Eeuo pipefail` and terminate the monitor — killing
# both progress AND the final _REVIEW handoff. Coercing keeps a bad env harmless.
_positive_int_or() {   # <value> <default>
    case "$1" in
        ''|*[!0-9]*) printf '%s' "$2" ;;
        *) { [ "$1" -ge 1 ] 2>/dev/null && printf '%s' "$1"; } || printf '%s' "$2" ;;
    esac
}
PROGRESS_ENABLED="${CODEX_REVIEW_PROGRESS:-1}"
PROGRESS_INTERVAL="$(_positive_int_or "${CODEX_REVIEW_PROGRESS_INTERVAL_SECONDS:-30}" 30)"
PROGRESS_DETAIL="${CODEX_REVIEW_PROGRESS_DETAIL:-status}"   # status|summary|off
PROGRESS_DIR="$BUS_DIR/progress"
# In-memory per-run state for the live loop: last emitted "state/phase" signature
# and the epoch of the last emit (heartbeat throttle). Reset on daemon restart —
# which is exactly what drives the "replay the active review as resumed" behavior.
declare -A PROG_SIG=()
declare -A PROG_LAST_EMIT=()

ONCE=0
ACK_MODE=0
ACK_FILE=""
ACK_EXPECT=""

case "${1:-}" in
    --once)
        ONCE=1
        shift
        ;;
    --ack)
        ACK_MODE=1
        shift
        ACK_FILE="${1:-}"
        ;;
    --ack-if-digest)
        # Race-free ack: mark a response handled by a CALLER-CAPTURED digest
        # instead of re-hashing the on-disk file (which the watcher may have
        # swapped for a fresh same-SHA review). The marker key is the passed
        # digest, so it can only ever suppress the exact content the caller
        # handled — a fresh review carries a different digest and still fires.
        ACK_MODE=2
        ACK_FILE="${2:-}"
        ACK_EXPECT="${3:-}"
        ;;
    --help|-h)
        echo "Usage: $0 [--once | --ack <response-file> | --ack-if-digest <response-file> <sha256>]"
        exit 0
        ;;
esac

# Preflight external tools (mirrors review-bus-codex-watcher.sh's require_tools)
# so a missing dependency fails with a machine-parseable line + exit 127 instead
# of a generic "command not found" under set -euo pipefail. inotifywait is only
# needed for the live watch loop, not --once replay.
require_tools() {
    local missing=0 tool
    local tools=(jq sha256sum awk find)
    { [ "$ONCE" -eq 1 ] || [ "$ACK_MODE" -ne 0 ]; } || tools+=(inotifywait)
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "MONITOR_FATAL missing_tool=$tool" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || exit 127
}

require_tools

mkdir -p "$RESP_DIR" "$EMITTED_DIR" "$ACK_DIR" "$PROGRESS_DIR"

response_digest() {
    sha256sum "$1" | awk '{print $1}'
}

emit_response() {
    local file="$1"
    local base digest marker line

    case "$file" in
        */resp-*.json|resp-*.json) ;;
        *) return 0 ;;
    esac

    [ -f "$file" ] || return 0

    base="$(basename "$file")"
    digest="$(response_digest "$file" 2>/dev/null || true)"
    [ -n "$digest" ] || return 0

    # Cross-session ACK gate: a response the Claude session already handled
    # (marker written via --ack after resolve + re-request, or merge) is never
    # re-emitted, even under a fresh per-session EMITTED_DIR.
    [ -e "$ACK_DIR/${base}.${digest}" ] && return 0

    # Parse the response ONCE, slurped, and require exactly one top-level object.
    # jq reads a STREAM: a file holding two objects produced one handoff line per
    # object, and the control-byte strip below then removed the newline between
    # them - collapsing two reviews into a single line carrying two `status=` and
    # two `resp=` tokens. A driver parsing positionally could read an ambiguous
    # clean status instead of a fail-closed sentinel. Validate BEFORE claiming the
    # emit marker so an invalid response is not silently marked as delivered.
    local snap
    if ! snap="$(jq -s 'if length == 1 and (.[0] | type) == "object" then .[0] else empty end' "$file" 2>/dev/null)" \
       || [ -z "$snap" ]; then
        printf '%s_REVIEW_PARSE_ERROR resp=%s reason=not_a_single_json_object\n' "$PREFIX" "$file"
        return 0
    fi

    # Within-session dedup keyed by base + content digest. A fresh per-session
    # EMITTED_DIR means a crash-after-emit response re-surfaces next session (the
    # ACK gate above is what stops handled ones from re-firing). The claim is
    # ATOMIC (noclobber) so the startup replay and the inotify loop, which can
    # both see a response created during startup, never double-print it — exactly
    # one caller wins the marker and emits.
    marker="$EMITTED_DIR/${base}.${digest}"
    if ! ( set -o noclobber; : > "$marker" ) 2>/dev/null; then
        return 0
    fi

    line="$(
        jq -rc --arg path "$file" --arg prefix "$PREFIX" '
          "\($prefix)_REVIEW pr=\(.pr) sha=\(.sha) status=\(.status) findings=\(.findings_count) reviewer=\(.reviewer) summary=\"\(.summary // "" | gsub("[\n\r\"]"; " ") | .[0:200])\" resp=" + $path
        ' <<< "$snap" 2>/dev/null || true
    )"

    # `summary` is QUOTED. On a zero-finding review it holds the reviewer's own
    # text, so a note containing `resp=` or `status=` would otherwise put a second
    # copy of a framing token into a line the driver parses positionally. Quoting
    # (with `"` stripped from the content) bounds it, and the real `resp=` stays
    # the LAST token on the line - so a parser must take the last one.
    #
    # Defense-in-depth, mirroring emit_progress: strip ALL control bytes from the
    # assembled line. `summary` is composed by the watcher, but a stray escape in
    # any interpolated field would otherwise be a log/terminal-injection vector.
    line="$(printf '%s' "$line" | tr -d '[:cntrl:]')"

    if [ -z "$line" ]; then
        printf '%s_REVIEW_PARSE_ERROR resp=%s\n' "$PREFIX" "$file"
        return 0
    fi

    printf '%s\n' "$line"
}

# Mark a response handled WITHOUT emitting — used to suppress stale prior-
# iteration responses on startup so they never drive a fix loop.
mark_emitted() {
    local file="$1" base digest
    [ -f "$file" ] || return 0
    base="$(basename "$file")"
    digest="$(response_digest "$file" 2>/dev/null || true)"
    [ -n "$digest" ] || return 0
    : > "$EMITTED_DIR/${base}.${digest}"
}

# Emit one <PREFIX>_REVIEW_PROGRESS line from a progress file. $2 overrides the
# reported state (started / resumed / running). elapsed_s is computed from
# started_at; the optional sanitized reasoning note appears only in summary detail.
emit_progress() {
    local f="$1" estate="$2" now="$3" started elapsed="" line st
    started="$(jq -r '.started_at // ""' "$f" 2>/dev/null || true)"
    if [ -n "$started" ]; then
        st="$(date -d "$started" +%s 2>/dev/null || true)"
        [ -n "$st" ] && elapsed=$(( now - st ))
    fi
    line="$(jq -rc \
        --arg prefix "$PREFIX" --arg estate "$estate" --arg elapsed "${elapsed:-}" \
        --arg detail "$PROGRESS_DETAIL" '
        "\($prefix)_REVIEW_PROGRESS pr=\(.pr) sha=\(.sha) run=\(.run_id) state=\($estate) phase=\(.phase) iter=\(.iter)"
        + (if ($elapsed | length) > 0 then " elapsed_s=\($elapsed)" else "" end)
        + (if (.events // 0) > 0 then " events=\(.events)" else "" end)
        + (if (.commands // 0) > 0 then " commands=\(.commands)" else "" end)
        + (if (.last_event // "") != "" then " last_event=\(.last_event)" else "" end)
        + (if (.findings // 0) > 0 then " findings=\(.findings)" else "" end)
        + (if $detail == "summary" and (.reasoning // "") != ""
             then " note=\"\(.reasoning | gsub("[\n\r\"]"; " ") | .[0:240])\"" else "" end)
    ' "$f" 2>/dev/null || true)"
    # Defense-in-depth: $BUS/progress/*.json is local state (the watcher sanitizes
    # on write), but strip ALL control bytes from the assembled line before it
    # reaches the monitor log / an operator's terminal — a stray ANSI escape or BEL
    # in ANY interpolated field (note, last_event, phase) would otherwise be a
    # log/terminal-injection vector. Mirrors the watcher's `tr -d '[:cntrl:]'`.
    line="$(printf '%s' "$line" | tr -d '[:cntrl:]')"
    [ -n "$line" ] && printf '%s\n' "$line"
}

# Sweep $BUS/progress: emit start/resumed on first sight, phase changes
# immediately, and a heartbeat every PROGRESS_INTERVAL seconds while a review is
# active. A run whose terminal resp-<sha>.json exists (or whose state is terminal)
# is retired WITHOUT emitting — the <PREFIX>_REVIEW handoff covers completion, and
# completed historical progress is never replayed. $1 = start | resume (controls
# the first-sight state for the initial vs. restart pass).
sweep_progress() {
    local mode="$1" f run_id sha state phase sig now
    [ "$PROGRESS_ENABLED" = "1" ] || return 0
    [ "$PROGRESS_DETAIL" != "off" ] || return 0
    [ -d "$PROGRESS_DIR" ] || return 0
    now="$(date +%s)"
    while IFS= read -r f; do
        run_id="$(jq -r '.run_id // ""' "$f" 2>/dev/null || true)"
        [ -n "$run_id" ] || continue
        sha="$(jq -r '.sha // ""' "$f" 2>/dev/null || true)"
        state="$(jq -r '.state // ""' "$f" 2>/dev/null || true)"
        phase="$(jq -r '.phase // ""' "$f" 2>/dev/null || true)"

        # Retire once the review has a terminal response OR a terminal state — no
        # progress line (completion is delivered by <PREFIX>_REVIEW), and never
        # replay it again this session.
        if [ -f "$RESP_DIR/resp-${sha}.json" ] \
           || [ "$state" = completed ] || [ "$state" = error ] || [ "$state" = superseded ]; then
            PROG_SIG[$run_id]="__done__"
            continue
        fi
        [ "${PROG_SIG[$run_id]:-}" = "__done__" ] && continue

        sig="$state/$phase"
        if [ -z "${PROG_SIG[$run_id]:-}" ]; then
            # First sight of this run: started (initial pass) or resumed (restart).
            emit_progress "$f" "$([ "$mode" = resume ] && echo resumed || echo started)" "$now"
            PROG_SIG[$run_id]="$sig"; PROG_LAST_EMIT[$run_id]="$now"
        elif [ "${PROG_SIG[$run_id]}" != "$sig" ]; then
            emit_progress "$f" running "$now"       # phase/state change → immediate
            PROG_SIG[$run_id]="$sig"; PROG_LAST_EMIT[$run_id]="$now"
        elif [ $(( now - ${PROG_LAST_EMIT[$run_id]:-0} )) -ge "$PROGRESS_INTERVAL" ]; then
            emit_progress "$f" running "$now"       # unchanged → heartbeat on interval
            PROG_LAST_EMIT[$run_id]="$now"
        fi
    done < <(find "$PROGRESS_DIR" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null)
}

# On startup, emit only the LATEST response per PR (newest by mtime). Older
# per-PR responses are stale prior iterations — mark them handled so a resumed
# monitor doesn't replay them and re-trigger duplicate/out-of-order fix loops.
# Live responses arriving after startup always emit via the inotify loop.
replay_existing() {
    local file pr
    local -a snapshot=()
    declare -A latest_for_pr=()

    # Build the latest-per-PR map AND the stale-suppression list from ONE
    # snapshot. The previous two-scan version could mis-handle a response written
    # between the scans: absent from the latest map (built by scan 1) but seen by
    # scan 2, it was wrongly marked stale and dropped. Snapshotting once means a
    # response that lands during replay simply isn't in the snapshot; it is
    # picked up by the post-arm catch-up below instead.
    while IFS= read -r file; do
        snapshot+=("$file")
        pr="$(jq -r '.pr // empty' "$file" 2>/dev/null || true)"
        [ -n "$pr" ] || continue
        if [ -z "${latest_for_pr[$pr]:-}" ] || [ "$file" -nt "${latest_for_pr[$pr]}" ]; then
            latest_for_pr[$pr]="$file"
        fi
    done < <(find "$RESP_DIR" -maxdepth 1 -type f -name 'resp-*.json' -print)

    for file in "${snapshot[@]}"; do
        pr="$(jq -r '.pr // empty' "$file" 2>/dev/null || true)"
        [ -n "$pr" ] || continue
        if [ "$file" = "${latest_for_pr[$pr]:-}" ]; then
            emit_response "$file"
        else
            mark_emitted "$file"
        fi
    done
}

# --ack <response-file>: record that the session has fully handled this response
# (called after resolve + re-request, or merge) so future sessions never
# re-surface it. Keyed on base + content digest, so a same-SHA re-request that
# rewrites the file with new content is a new digest → not acked → re-emitted.
if [ "$ACK_MODE" -eq 1 ]; then
    { [ -n "$ACK_FILE" ] && [ -f "$ACK_FILE" ]; } || { echo "MONITOR_ACK_FATAL no_such_response=${ACK_FILE:-<none>}" >&2; exit 1; }
    _ack_base="$(basename "$ACK_FILE")"
    _ack_digest="$(response_digest "$ACK_FILE" 2>/dev/null || true)"
    [ -n "$_ack_digest" ] || { echo "MONITOR_ACK_FATAL cannot_digest=$ACK_FILE" >&2; exit 1; }
    : > "$ACK_DIR/${_ack_base}.${_ack_digest}"
    echo "MONITOR_ACKED resp=$_ack_base digest=${_ack_digest:0:12}"
    exit 0
fi

# --ack-if-digest <response-file> <sha256>: mark the response handled by a
# digest the CALLER captured (before it mutated anything), NOT a re-hash of the
# on-disk file. This closes the ack TOCTOU: if the watcher overwrites
# resp-$SHA.json with a fresh same-SHA review between the caller's snapshot and
# this ack, the fresh review carries a DIFFERENT digest, so the marker written
# here (keyed on the captured digest) can never suppress it — its notification
# still fires. The response file need not still exist; only its name + the
# captured digest form the marker key.
if [ "$ACK_MODE" -eq 2 ]; then
    { [ -n "$ACK_FILE" ] && [ -n "$ACK_EXPECT" ]; } \
        || { echo "MONITOR_ACK_FATAL usage=--ack-if-digest <response-file> <sha256>" >&2; exit 1; }
    [[ "$ACK_EXPECT" =~ ^[0-9a-f]{64}$ ]] \
        || { echo "MONITOR_ACK_FATAL bad_digest=$ACK_EXPECT" >&2; exit 1; }
    _ack_base="$(basename "$ACK_FILE")"
    : > "$ACK_DIR/${_ack_base}.${ACK_EXPECT}"
    echo "MONITOR_ACKED resp=$_ack_base digest=${ACK_EXPECT:0:12}"
    exit 0
fi

replay_existing

# Surface any review that is STILL in flight as state=resumed (a monitor that
# started after Codex began, or restarted mid-review). Completed/terminal runs are
# retired without emitting, so historical progress is never replayed.
sweep_progress resume

if [ "$ONCE" -eq 1 ]; then
    exit 0
fi

# Live watch — mirrors review-bus-codex-watcher.sh's poll loop. Each iteration
# FIRST sweeps the responses dir (emitting any new response, deduped by the
# atomic marker), then blocks on inotifywait with a timeout. inotify gives
# near-instant latency on a write; the per-iteration sweep is the DETERMINISTIC
# safety net — anything inotify could miss (notably a response written before
# the watch is fully armed) is caught by the next sweep within
# MONITOR_POLL_SECONDS, with no reliance on a fixed arming sleep. inotifywait is
# backgrounded with a captured pid so the trap reaps it on shutdown (no orphaned
# watch), and -t bounds it as a secondary guard.
POLL_SECONDS="$(_positive_int_or "${MONITOR_POLL_SECONDS:-15}" 15)"   # also numeric (-lt, inotifywait -t)
inotify_pid=""
cleanup() {
    trap - EXIT INT TERM
    [ -n "$inotify_pid" ] && kill "$inotify_pid" 2>/dev/null || true
    exit 0
}
trap cleanup EXIT INT TERM

# The heartbeat cadence caps the wait so an unchanged in-flight review still gets
# a periodic progress line even with no filesystem event (inotify would otherwise
# block up to POLL_SECONDS). Progress emission is throttled inside sweep_progress.
if [ "$PROGRESS_ENABLED" = "1" ] && [ "$PROGRESS_DETAIL" != "off" ] && [ "$PROGRESS_INTERVAL" -lt "$POLL_SECONDS" ]; then
    POLL_SECONDS="$PROGRESS_INTERVAL"
fi

while true; do
    while IFS= read -r file; do
        emit_response "$file"
    done < <(find "$RESP_DIR" -maxdepth 1 -type f -name 'resp-*.json' -print)

    # New runs → started; phase changes → immediate; unchanged → interval heartbeat.
    sweep_progress start

    # Watch BOTH the responses and the progress dir so a phase-change file write
    # wakes the loop for a near-immediate progress line (not only on the timeout).
    inotifywait -q -e close_write,moved_to -t "$POLL_SECONDS" "$RESP_DIR" "$PROGRESS_DIR" >/dev/null 2>&1 &
    inotify_pid=$!
    wait "$inotify_pid" 2>/dev/null || true
    inotify_pid=""
done
