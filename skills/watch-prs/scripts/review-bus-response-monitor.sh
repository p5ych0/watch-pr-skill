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
ONCE=0
ACK_MODE=0
ACK_FILE=""

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
    --help|-h)
        echo "Usage: $0 [--once | --ack <response-file>]"
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
    { [ "$ONCE" -eq 1 ] || [ "$ACK_MODE" -eq 1 ]; } || tools+=(inotifywait)
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "MONITOR_FATAL missing_tool=$tool" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || exit 127
}

require_tools

mkdir -p "$RESP_DIR" "$EMITTED_DIR" "$ACK_DIR"

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
          "\($prefix)_REVIEW pr=\(.pr) sha=\(.sha) status=\(.status) findings=\(.findings_count) reviewer=\(.reviewer) summary=\(.summary // "" | gsub("[\n\r]"; " ") | .[0:200]) resp=" + $path
        ' "$file" 2>/dev/null || true
    )"

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

replay_existing

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
POLL_SECONDS="${MONITOR_POLL_SECONDS:-15}"
inotify_pid=""
cleanup() {
    trap - EXIT INT TERM
    [ -n "$inotify_pid" ] && kill "$inotify_pid" 2>/dev/null || true
    exit 0
}
trap cleanup EXIT INT TERM

while true; do
    while IFS= read -r file; do
        emit_response "$file"
    done < <(find "$RESP_DIR" -maxdepth 1 -type f -name 'resp-*.json' -print)

    inotifywait -q -e close_write,moved_to -t "$POLL_SECONDS" "$RESP_DIR" >/dev/null 2>&1 &
    inotify_pid=$!
    wait "$inotify_pid" 2>/dev/null || true
    inotify_pid=""
done
