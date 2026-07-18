#!/usr/bin/env bash
# Start the Codex review-bus daemons (reviewer watcher + response monitor) as
# systemd --user services.
#
# WHY systemd and not setsid: setsid gives a new session but stays in the
# CALLER'S cgroup (e.g. the terminal tab that a Claude Bash tool runs in), so
# the "daemon" is reaped when that session is recycled/timed out. A systemd
# --user service runs in its own cgroup under user@.service — decoupled from
# the launching terminal, and auto-restarted on failure.
#
# Single-domain + universal: repo identity, an owner-scoped bus dir, and a
# DEDICATED review clone are all derived from THIS checkout's git origin, so the
# identical script drives any project and per-project instances never collide.

set -Eeuo pipefail

# Build the --setenv args that forward operator-tunable CODEX_REVIEW_* knobs to
# the systemd --user units. --user services start from a CLEAN environment, so a
# knob not forwarded here silently resets to the watcher's built-in default —
# e.g. a lowered CODEX_REVIEW_MAX_ITERATIONS would be ignored and a failing
# auto-review could keep retrying to the default cap. Forwarding EVERY set
# CODEX_REVIEW_* var (rather than a hand-maintained list) keeps new knobs covered
# automatically; the three always-on knobs are seeded with defaults so a clean
# launch env still gets sane values. This deliberately does NOT forward
# REVIEW_BUS_GUIDANCE_FILE — reviewer guidance is base-ref-only (see the watcher).
codex_watcher_setenv() {
    local CODEX_REVIEW_AUTO_OPEN_PRS="${CODEX_REVIEW_AUTO_OPEN_PRS:-1}"
    local CODEX_REVIEW_MODEL="${CODEX_REVIEW_MODEL:-gpt-5.6}"
    local CODEX_REVIEW_REASONING_EFFORT="${CODEX_REVIEW_REASONING_EFFORT:-xhigh}"
    local CODEX_REVIEW_MAX_ITERATIONS="${CODEX_REVIEW_MAX_ITERATIONS:-0}"
    local v
    for v in $(compgen -v | grep -E '^CODEX_REVIEW_' | sort || true); do
        [ -n "${!v:-}" ] && printf -- '--setenv=%s=%s\n' "$v" "${!v}"
    done
}

# Tests source this script with REVIEW_BUS_LIB_ONLY=1 to exercise pure helpers
# (e.g. codex_watcher_setenv) without deriving repo identity or launching daemons.
if [ "${BASH_SOURCE[0]}" != "${0}" ] && [ -n "${REVIEW_BUS_LIB_ONLY:-}" ]; then
    return 0
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)}"

# Derive owner/repo from the origin (host-agnostic: SSH + HTTPS).
REMOTE="${REVIEW_BUS_REMOTE:-$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)}"
if [ -n "$REMOTE" ]; then
    _p="${REMOTE%.git}"; REPO="${REVIEW_BUS_REPO:-${_p##*/}}"; _p="${_p%/*}"; OWNER="${REVIEW_BUS_OWNER:-${_p##*[:/]}}"
else
    REPO="${REVIEW_BUS_REPO:-review}"; OWNER="${REVIEW_BUS_OWNER:-}"
fi
BUS_SLUG="$(printf '%s' "${OWNER:+${OWNER}-}${REPO}" | tr -c 'A-Za-z0-9._-' '-')"
BUS_DIR="${BUS_DIR:-/tmp/${BUS_SLUG:-review}-review-bus}"
LOG_DIR="$BUS_DIR/.codex-logs"
RUN_DIR="$BUS_DIR/.codex-run"
PID_FILE="$RUN_DIR/watcher.pid"
MONITOR_PID_FILE="$RUN_DIR/response-monitor.pid"
WORKTREE_ROOT="${CODEX_REVIEW_WORKTREE_ROOT:-$BUS_DIR/.codex-worktrees}"

WATCHER="$SCRIPT_DIR/review-bus-codex-watcher.sh"
MONITOR="$SCRIPT_DIR/review-bus-response-monitor.sh"

WATCHER_UNIT="review-bus-${BUS_SLUG}-watcher"
MONITOR_UNIT="review-bus-${BUS_SLUG}-monitor"

RESTART=0
ENSURE_ONLY=0
STOP_ONLY=0
case "${1:-}" in
    --restart)      RESTART=1;    shift ;;
    --ensure-clone) ENSURE_ONLY=1; shift ;;
    --stop)         STOP_ONLY=1;  shift ;;
    --help|-h)      echo "Usage: $0 [--restart | --ensure-clone | --stop]"; exit 0 ;;
esac

mkdir -p "$LOG_DIR" "$RUN_DIR" "$BUS_DIR/requests" "$BUS_DIR/responses" "$BUS_DIR/.codex-seen" "$WORKTREE_ROOT"

# ── Dedicated review clone ──────────────────────────────────────────────────
# The daemons operate on THIS clone, not the implementer's working tree, so a
# checkout/branch-switch/merge there can't disrupt the reviewer's git ops.
# --no-hardlinks: the /tmp bus dir is usually a different filesystem than the
# /home checkout (hardlinked --local fails cross-device). Working-tree content
# is never read — daemons run the implementer's CURRENT scripts with REPO_DIR
# as a git sandbox — so clone staleness is irrelevant.
REVIEW_DIR="${REVIEW_BUS_REPO_CLONE:-$BUS_DIR/.review-clone}"

# WIKI_DIR comes from the IMPLEMENTER checkout's sibling (the trusted project
# wiki). Reviewer guidance is NOT sourced or forwarded here at all: the watcher
# always loads .review-bus.md from the PR's trusted BASE ref, so a PR editing
# that file cannot steer its own review. There is deliberately no env override.
CONTEXT_WIKI_DIR="${WIKI_DIR:-$(cd "$REPO_DIR/.." && pwd)/${REPO}.wiki}"

ensure_review_clone() {
    if git -C "$REVIEW_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        [ -n "$REMOTE" ] && git -C "$REVIEW_DIR" remote set-url origin "$REMOTE" 2>/dev/null || true
        git -C "$REVIEW_DIR" worktree prune >/dev/null 2>&1 || true
        return 0
    fi
    if [ -z "$REMOTE" ]; then
        echo "REVIEW_BUS_CLONE_FATAL no origin on $REPO_DIR to clone from" >&2
        return 1
    fi
    echo "REVIEW_BUS_CLONE creating dedicated review checkout at $REVIEW_DIR" >&2
    rm -rf "$REVIEW_DIR"
    git clone --no-hardlinks --quiet "$REPO_DIR" "$REVIEW_DIR" || return 1
    git -C "$REVIEW_DIR" remote set-url origin "$REMOTE" || return 1
}

ensure_review_clone || exit 1

if [ "$ENSURE_ONLY" -eq 1 ]; then
    echo "REVIEW_BUS_CLONE_READY path=$REVIEW_DIR origin=$(git -C "$REVIEW_DIR" remote get-url origin 2>/dev/null)"
    exit 0
fi

# ── systemd requirement ─────────────────────────────────────────────────────
if ! command -v systemd-run >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "REVIEW_BUS_FATAL systemd --user unavailable (need systemd-run + a running user manager)" >&2
    exit 1
fi

# Kill any LEGACY setsid'd daemons (pre-systemd launches of the same script), so
# we never double-run. Full-path match keeps a sibling repo's daemons safe.
#
# Terminate the whole process GROUP, not just the matched shell: a setsid daemon
# is its own group leader and its in-flight `codex exec` / git children share its
# PGID — SIGTERM to the parent alone orphans a running review that could still
# post comments and race the new daemon. Bounded wait, then SIGKILL.
#
# Safety: only group-kill when the match is a genuine setsid group LEADER
# (pgid == pid) AND that group is not our own (guards the old `exit 144` trap
# where a negative-pid kill hit the caller's group); otherwise single-pid only.
kill_legacy() {
    local script="$1" pid pgid target mypgid i
    mypgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')"
    for pid in $(pgrep -f -- "$script" 2>/dev/null || true); do
        ps -p "$pid" -o args= 2>/dev/null | grep -Fq -- "$script" || continue
        pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
        if [ -n "$pgid" ] && [ "$pgid" = "$pid" ] && [ "$pgid" != "$mypgid" ]; then
            target="-$pgid"   # setsid daemon → terminate its whole group
        else
            target="$pid"     # not a leader / shares our group → single pid
        fi
        kill -TERM "$target" 2>/dev/null || true
        for i in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        kill -0 "$pid" 2>/dev/null && kill -KILL "$target" 2>/dev/null || true
    done
}

stop_unit() {
    systemctl --user stop "$1" 2>/dev/null || true
    systemctl --user reset-failed "$1" 2>/dev/null || true
}

if [ "$RESTART" -eq 1 ] || [ "$STOP_ONLY" -eq 1 ]; then
    stop_unit "$WATCHER_UNIT"
    stop_unit "$MONITOR_UNIT"
    kill_legacy "$WATCHER"
    kill_legacy "$MONITOR"
    if [ "$STOP_ONLY" -eq 1 ]; then
        echo "REVIEW_BUS_STOPPED units=$WATCHER_UNIT,$MONITOR_UNIT"
        exit 0
    fi
fi

# Transition cleanup: migrate a stray legacy setsid daemon to systemd. Guard on
# is-active — the systemd service execs the SAME script path kill_legacy matches,
# so an unconditional sweep would SIGTERM a HEALTHY unit (interrupting an
# in-flight review) and break idempotency: a second start.sh must be a no-op,
# not a restart. Only sweep when our unit isn't already running the daemon.
systemctl --user is-active --quiet "$WATCHER_UNIT" || kill_legacy "$WATCHER"
systemctl --user is-active --quiet "$MONITOR_UNIT" || kill_legacy "$MONITOR"

# ── Launch as systemd --user services ───────────────────────────────────────
# Notes:
#   - PATH is passed through: --user services get a minimal env, so gh / codex /
#     jq / git / inotifywait must be found via the caller's PATH.
#   - StandardOutput/Error append to the existing log files so the tail-based
#     notification bridge keeps working.
#   - Restart=on-failure auto-heals a death; the watcher's main loop never exits
#     0, so a clean stop only happens via `--stop`/`stop_unit`.

launch_unit() {
    local unit="$1" logfile="$2" bin="$3"; shift 3   # remaining args: extra --setenv=... entries
    if systemctl --user is-active --quiet "$unit"; then
        echo "RUNNING unit=$unit"
        return 0
    fi
    systemctl --user reset-failed "$unit" 2>/dev/null || true
    systemd-run --user --unit="$unit" --collect \
        --property=Restart=on-failure --property=RestartSec=5 \
        --property="StandardOutput=append:$logfile" \
        --property="StandardError=append:$logfile" \
        --working-directory="$REVIEW_DIR" \
        --setenv=PATH="$PATH" \
        --setenv=REPO_DIR="$REVIEW_DIR" \
        --setenv=BUS_DIR="$BUS_DIR" \
        "${AUTH_ENV[@]}" \
        "$@" \
        "$bin" >/dev/null 2>&1 || { echo "FATAL unit=$unit failed to start" >&2; return 1; }
    echo "STARTED unit=$unit log=$logfile"
}

# systemd-run returning 0 only means the transient unit was ACCEPTED, not that
# the daemon stayed up. A daemon that exits at once (missing tool, bad env, wrong
# path) would otherwise leave a "STARTED" line + a dead bus. Poll until the unit
# is active with a nonzero MainPID; on failure, surface the unit + log and return
# non-zero so the caller exits with an error instead of a false success.
verify_healthy() {
    local unit="$1" logfile="$2" i state pid ok=0
    # Require SUSTAINED health, not a single sample: a crash-looping daemon
    # (Restart=on-failure) is briefly "active" for the microseconds between
    # exec and exit right after each restart, so one active+pid reading can be a
    # blip. Demand 3 consecutive healthy samples — a crash-loop can't hold it,
    # a genuinely-up daemon clears it in ~0.6s.
    for i in $(seq 1 40); do   # up to ~8s, longer than one RestartSec=5 backoff
        state="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
        pid="$(systemctl --user show "$unit" -p MainPID --value 2>/dev/null || echo 0)"
        if [ "$state" = "active" ] && [ -n "$pid" ] && [ "$pid" != "0" ]; then
            ok=$((ok + 1))
            [ "$ok" -ge 3 ] && return 0
        else
            ok=0
        fi
        sleep 0.2
    done
    echo "REVIEW_BUS_UNHEALTHY unit=$unit state=${state:-?} pid=${pid:-0} — recent log:" >&2
    tail -n 5 "$logfile" 2>/dev/null >&2 || true
    return 1
}

# Auth/config env the daemons need but systemd's clean --user env drops. The old
# setsid flow inherited the launch shell; forward a CONSERVATIVE whitelist so git
# (the clone's origin is SSH → needs SSH_AUTH_SOCK), gh, and codex keep their
# credentials. Only forward vars that are actually set — an empty `--setenv=X=`
# would clobber a value systemd might otherwise provide.
AUTH_ENV=()
for _v in SSH_AUTH_SOCK GH_TOKEN GITHUB_TOKEN GH_HOST GH_CONFIG_DIR \
          CODEX_BIN CODEX_HOME OPENAI_API_KEY OPENAI_BASE_URL OPENAI_ORG \
          XDG_CONFIG_HOME XDG_RUNTIME_DIR LANG; do
    [ -n "${!_v:-}" ] && AUTH_ENV+=( "--setenv=${_v}=${!_v}" )
done

# Forward operator-tunable CODEX_REVIEW_* knobs (systemd --user starts clean, so
# anything not forwarded resets to the watcher default — e.g. MAX_ITERATIONS).
mapfile -t CODEX_WATCHER_ENV < <(codex_watcher_setenv)
launch_unit "$WATCHER_UNIT" "$LOG_DIR/watcher.log" "$WATCHER" \
    --setenv=WIKI_DIR="$CONTEXT_WIKI_DIR" \
    "${CODEX_WATCHER_ENV[@]}"

launch_unit "$MONITOR_UNIT" "$LOG_DIR/response-monitor.log" "$MONITOR"

# Confirm each daemon actually stayed up (systemd-run success ≠ daemon alive).
# The poll also replaces the old fixed sleep before reading MainPID.
health=0
verify_healthy "$WATCHER_UNIT" "$LOG_DIR/watcher.log" || health=1
verify_healthy "$MONITOR_UNIT" "$LOG_DIR/response-monitor.log" || health=1

# Compat: record MainPIDs where the old setsid flow wrote them, so existing
# "kill the pid" references + health checks keep working.
systemctl --user show "$WATCHER_UNIT" -p MainPID --value 2>/dev/null > "$PID_FILE" || true
systemctl --user show "$MONITOR_UNIT" -p MainPID --value 2>/dev/null > "$MONITOR_PID_FILE" || true

echo "CODEX_WATCHER unit=$WATCHER_UNIT pid=$(cat "$PID_FILE" 2>/dev/null) log=$LOG_DIR/watcher.log"
echo "REVIEW_BUS_RESPONSE_MONITOR unit=$MONITOR_UNIT pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null) log=$LOG_DIR/response-monitor.log"

if [ "$health" -ne 0 ]; then
    echo "REVIEW_BUS_FATAL one or more daemons failed to stay up (see REVIEW_BUS_UNHEALTHY above)" >&2
    exit 1
fi
