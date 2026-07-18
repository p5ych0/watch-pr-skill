#!/usr/bin/env bash
# Focused test: start.sh runs the daemons as systemd --user services that ESCAPE
# the caller's cgroup.
#
# This is the root-cause fix: setsid gives a new session but leaves the daemon
# in the CALLER'S cgroup (e.g. the terminal tab a Claude Bash tool runs in), so
# it's reaped when that session is recycled/timed out. A systemd --user service
# lands in its own cgroup under user@.service, decoupled from the launcher.
#
# Proven by asserting the watcher unit is active and its cgroup is its own unit
# scope — distinct from this test process's cgroup.
#
# Requires a systemd --user manager; skips (as PASS) where unavailable.

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
START="$SELF_DIR/review-bus-codex-start.sh"

if ! command -v systemd-run >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "ok   - systemd --user unavailable; skipping cgroup-escape assertions"
    echo "RESULT: PASS"
    exit 0
fi

TMP="$(mktemp -d)"
ORIGIN="$TMP/origin.git"
IMPL="$TMP/proj"
BUS="$TMP/bus"
WUNIT="review-bus-testowner-proj-watcher.service"
MUNIT="review-bus-testowner-proj-monitor.service"

trap '
    systemctl --user stop "$WUNIT" "$MUNIT" 2>/dev/null || true
    systemctl --user reset-failed "review-bus-testowner-proj-*" 2>/dev/null || true
    rm -rf "$TMP" 2>/dev/null || true
    true
' EXIT

git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$IMPL" 2>/dev/null
git -C "$IMPL" config user.email t@example.com
git -C "$IMPL" config user.name test

mkdir -p "$IMPL/scripts"
printf 'GUIDANCE_MARKER\n' > "$IMPL/.review-bus.md"

# Stubs that stay alive long enough for is-active + cgroup reads. Clean exit (0)
# so Restart=on-failure never respawns them; the trap stops the units.
cat > "$IMPL/scripts/review-bus-codex-watcher.sh" <<'STUB'
#!/usr/bin/env bash
sleep 10
STUB
cp "$IMPL/scripts/review-bus-codex-watcher.sh" "$IMPL/scripts/review-bus-response-monitor.sh"
chmod +x "$IMPL/scripts/"*.sh
git -C "$IMPL" add -A
git -C "$IMPL" commit -q -m init

# Pin OWNER so unit names are predictable; strip inherited context overrides.
env -u WIKI_DIR -u REVIEW_BUS_GUIDANCE_FILE -u REVIEW_BUS_REMOTE \
    -u REVIEW_BUS_PREFIX -u REVIEW_BUS_REPO_CLONE -u CODEX_REVIEW_WORKTREE_ROOT \
    REPO_DIR="$IMPL" BUS_DIR="$BUS" REVIEW_BUS_REPO="proj" REVIEW_BUS_OWNER="testowner" \
    bash "$START" >/dev/null 2>&1 || true
sleep 0.6

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

systemctl --user is-active --quiet "$WUNIT" \
    && pass "watcher launched as an active systemd --user service" \
    || die "watcher unit not active: $(systemctl --user is-active "$WUNIT" 2>/dev/null)"

wpid="$(systemctl --user show "$WUNIT" -p MainPID --value 2>/dev/null || true)"
[ -n "$wpid" ] && [ "$wpid" != "0" ] \
    && pass "watcher has a MainPID ($wpid)" \
    || die "no watcher MainPID"

wcg="$(cat "/proc/$wpid/cgroup" 2>/dev/null || true)"
selfcg="$(cat /proc/self/cgroup 2>/dev/null || true)"

case "$wcg" in
    *review-bus-testowner-proj-watcher.service)
        pass "watcher cgroup is its OWN unit scope" ;;
    *)
        die "watcher cgroup is not its unit scope: $wcg" ;;
esac

[ -n "$wcg" ] && [ "$wcg" != "$selfcg" ] \
    && pass "watcher cgroup ESCAPED the caller's cgroup" \
    || die "watcher shares the caller's cgroup ($wcg)"

# Idempotency: a second start.sh must be a NO-OP, not a restart. The legacy
# setsid cleanup must not SIGTERM the healthy systemd-managed daemon (whose
# service execs the same script path kill_legacy matches) — regression guard.
env -u WIKI_DIR -u REVIEW_BUS_GUIDANCE_FILE -u REVIEW_BUS_REMOTE \
    -u REVIEW_BUS_PREFIX -u REVIEW_BUS_REPO_CLONE -u CODEX_REVIEW_WORKTREE_ROOT \
    REPO_DIR="$IMPL" BUS_DIR="$BUS" REVIEW_BUS_REPO="proj" REVIEW_BUS_OWNER="testowner" \
    bash "$START" >/dev/null 2>&1 || true
sleep 0.4
wpid2="$(systemctl --user show "$WUNIT" -p MainPID --value 2>/dev/null || true)"
[ -n "$wpid2" ] && [ "$wpid2" = "$wpid" ] \
    && pass "repeat start is idempotent (MainPID $wpid unchanged)" \
    || die "repeat start restarted the daemon (pid $wpid -> ${wpid2:-none})"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
