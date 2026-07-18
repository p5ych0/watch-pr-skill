#!/usr/bin/env bash
# Focused tests for two launcher guarantees:
#
#   A. Health gate — `systemd-run` accepting a unit does NOT prove the daemon
#      stayed up. A daemon that exits at once must make start.sh FAIL (non-zero
#      + REVIEW_BUS_UNHEALTHY), not print a false "STARTED" over a dead bus.
#
#   B. Legacy process-group termination — retiring a legacy setsid daemon must
#      kill its whole process GROUP, so an in-flight `codex exec`-style child
#      can't outlive the parent and race the new daemon.
#
# Both need a systemd --user manager (the launcher is systemd-only); skip as
# PASS where unavailable.

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
START="$SELF_DIR/review-bus-codex-start.sh"

if ! command -v systemd-run >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "ok   - systemd --user unavailable; skipping health/group-kill assertions"
    echo "RESULT: PASS"
    exit 0
fi

TMP="$(mktemp -d)"
fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# Unique owner per scenario so unit slugs are predictable + isolated.
trap '
    systemctl --user stop "review-bus-htha-proj-watcher.service" "review-bus-htha-proj-monitor.service" 2>/dev/null || true
    systemctl --user stop "review-bus-hthb-proj-watcher.service" "review-bus-hthb-proj-monitor.service" 2>/dev/null || true
    systemctl --user reset-failed "review-bus-hth*-proj-*" 2>/dev/null || true
    for f in "$TMP"/*/parent.pid "$TMP"/*/child.pid; do
        p="$(cat "$f" 2>/dev/null || true)"; [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    rm -rf "$TMP" 2>/dev/null || true
    true
' EXIT

mk_impl() {   # $1=dir  — a git checkout with a bare origin + scripts dir
    local impl="$1" origin="$1.git"
    git init -q --bare "$origin"
    git clone -q "$origin" "$impl" 2>/dev/null
    git -C "$impl" config user.email t@example.com
    git -C "$impl" config user.name test
    mkdir -p "$impl/scripts"
    printf 'GUIDANCE\n' > "$impl/.review-bus.md"
}

run_start() {   # $1=impl $2=bus $3=owner ; extra args passed through
    local impl="$1" bus="$2" owner="$3"; shift 3
    env -u WIKI_DIR -u REVIEW_BUS_GUIDANCE_FILE -u REVIEW_BUS_REMOTE \
        -u REVIEW_BUS_PREFIX -u REVIEW_BUS_REPO_CLONE -u CODEX_REVIEW_WORKTREE_ROOT \
        REPO_DIR="$impl" BUS_DIR="$bus" REVIEW_BUS_REPO="proj" REVIEW_BUS_OWNER="$owner" \
        REVIEW_BUS_WATCHER="$impl/scripts/review-bus-codex-watcher.sh" \
        REVIEW_BUS_MONITOR="$impl/scripts/review-bus-response-monitor.sh" \
        bash "$START" "$@"
}

# ── Scenario A: an immediately-exiting daemon fails the health gate ──────────
IMPL_A="$TMP/a"; BUS_A="$TMP/busa"
mk_impl "$IMPL_A"
# Watcher exits at once (broken). Monitor stays up so the failure is isolated to
# the health gate, not a setup artifact.
cat > "$IMPL_A/scripts/review-bus-codex-watcher.sh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat > "$IMPL_A/scripts/review-bus-response-monitor.sh" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
chmod +x "$IMPL_A/scripts/"*.sh
git -C "$IMPL_A" add -A; git -C "$IMPL_A" commit -q -m init

set +e
out_a="$(run_start "$IMPL_A" "$BUS_A" htha 2>&1)"; rc_a=$?
set -e
[ "$rc_a" -ne 0 ] \
    && pass "start.sh exits non-zero when a daemon dies immediately (rc=$rc_a)" \
    || die "start.sh returned success over a dead daemon"
grep -q 'REVIEW_BUS_UNHEALTHY' <<<"$out_a" \
    && pass "reports REVIEW_BUS_UNHEALTHY with the failing unit" \
    || die "no REVIEW_BUS_UNHEALTHY diagnostic emitted"

# ── Scenario B: retiring a legacy setsid daemon kills its whole group ────────
IMPL_B="$TMP/b"; BUS_B="$TMP/busb"
mk_impl "$IMPL_B"
# A "legacy" watcher: spawns a child (stands in for an in-flight `codex exec`),
# records both pids, then blocks. Child shares the setsid group.
cat > "$IMPL_B/scripts/review-bus-codex-watcher.sh" <<STUB
#!/usr/bin/env bash
sleep 300 &
echo \$! > "$TMP/b/child.pid"
sleep 300
STUB
cat > "$IMPL_B/scripts/review-bus-response-monitor.sh" <<'STUB'
#!/usr/bin/env bash
sleep 300
STUB
chmod +x "$IMPL_B/scripts/"*.sh
git -C "$IMPL_B" add -A; git -C "$IMPL_B" commit -q -m init

# Launch it the way the OLD flow did — detached setsid, its own session/group.
setsid bash "$IMPL_B/scripts/review-bus-codex-watcher.sh" >/dev/null 2>&1 &
echo "$!" > "$TMP/b/parent.pid"
# Wait for the child to register.
for _ in $(seq 1 25); do [ -f "$TMP/b/child.pid" ] && break; sleep 0.2; done
parent="$(cat "$TMP/b/parent.pid" 2>/dev/null || true)"
child="$(cat "$TMP/b/child.pid" 2>/dev/null || true)"

if [ -z "$child" ] || ! kill -0 "$parent" 2>/dev/null || ! kill -0 "$child" 2>/dev/null; then
    die "legacy stub did not come up with a live parent+child (parent=$parent child=$child)"
else
    pass "legacy setsid daemon running with a live child (parent=$parent child=$child)"
    # --stop retires legacy daemons (stop_unit + kill_legacy). Group termination
    # must take the child down too.
    run_start "$IMPL_B" "$BUS_B" hthb --stop >/dev/null 2>&1 || true
    sleep 0.4
    kill -0 "$parent" 2>/dev/null && die "legacy parent survived migration" || pass "legacy parent terminated"
    kill -0 "$child"  2>/dev/null && die "legacy CHILD survived (would race the new daemon)" || pass "legacy child terminated with the group"
fi

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
