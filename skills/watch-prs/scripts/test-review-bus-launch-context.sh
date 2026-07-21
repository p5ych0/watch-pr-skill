#!/usr/bin/env bash
# Focused launcher test: start.sh must split the watcher's GIT root from its
# CONTEXT root. Git ops run on the dedicated clone, but the watcher must still
# receive the IMPLEMENTER's sibling wiki as context. Guidance is NOT forwarded —
# it is loaded base-ref-only by the watcher itself (a PR can't steer its own
# review). Operator CODEX_REVIEW_* knobs ARE forwarded (systemd --user starts
# from a clean env). Proven by launching a STUB watcher that dumps the env.
#
# Self-contained: temp implementer with stub daemons + a bare origin. No network.

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
START="$SELF_DIR/review-bus-codex-start.sh"

# The launcher is now systemd-only (it aborts before launching the daemons when
# no `systemd --user` manager is present), so this launch-context assertion can
# only run where systemd --user is usable. Skip as PASS otherwise — the context
# split it proves is exercised wherever the daemons can actually start.
# Also probe a real transient-unit launch (bounded): a CI runner can answer
# show-environment yet be unable to START a unit, which would fail these
# real-daemon assertions spuriously. Skip (as PASS) when it cannot.
if ! command -v systemd-run >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1 \
   || ! timeout 15 systemd-run --user --quiet --collect --wait --unit="rb-probe-$$-$RANDOM.service" /bin/true >/dev/null 2>&1; then
    echo "ok   - systemd --user cannot launch transient units; skipping launch-context assertions"
    echo "RESULT: PASS"
    exit 0
fi

TMP="$(mktemp -d)"
ORIGIN="$TMP/origin.git"
IMPL="$TMP/proj"
BUS="$TMP/bus"
ENVOUT="$TMP/watcher-env.txt"
MONENVOUT="$TMP/monitor-env.txt"

# Cleanup: the launcher now runs the daemons as systemd --user services, so
# stop them by unit name (owner pinned below to make the slug predictable) —
# a bare kill would trip Restart=on-failure and respawn the stub.
trap '
    systemctl --user stop review-bus-testowner-proj-watcher.service review-bus-testowner-proj-monitor.service 2>/dev/null || true
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
mkdir -p "$TMP/proj.wiki"   # the implementer's sibling wiki

# Stub watcher: record the env start.sh handed us, then stay alive briefly so
# start.sh's is_watcher_pid liveness check passes.
cat > "$IMPL/scripts/review-bus-codex-watcher.sh" <<STUB
#!/usr/bin/env bash
{
    echo "REPO_DIR=\$REPO_DIR"
    echo "WIKI_DIR=\$WIKI_DIR"
    echo "REVIEW_BUS_GUIDANCE_FILE=\$REVIEW_BUS_GUIDANCE_FILE"
    echo "CODEX_REVIEW_MAX_ITERATIONS=\$CODEX_REVIEW_MAX_ITERATIONS"
    echo "SSH_AUTH_SOCK=\$SSH_AUTH_SOCK"
} > "$ENVOUT"
sleep 5
STUB
# Stub monitor: record the CODEX_REVIEW_* env start.sh handed IT (the monitor also
# consumes the progress knobs), then stay alive briefly for the liveness check.
cat > "$IMPL/scripts/review-bus-response-monitor.sh" <<STUB
#!/usr/bin/env bash
{
    echo "CODEX_REVIEW_PROGRESS_DETAIL=\$CODEX_REVIEW_PROGRESS_DETAIL"
    echo "CODEX_REVIEW_MAX_ITERATIONS=\$CODEX_REVIEW_MAX_ITERATIONS"
} > "$MONENVOUT"
sleep 5
STUB
chmod +x "$IMPL/scripts/"*.sh
git -C "$IMPL" add -A
git -C "$IMPL" commit -q -m init

# Hermetic: start.sh honors WIKI_DIR (and the other REVIEW_BUS_* vars) as
# explicit overrides. When this test runs inside a bus-worker environment those
# are already set, which would mask the derivation under test. Strip them so
# start.sh derives context from the temp implementer. OWNER is pinned (not
# derived) so the systemd unit slug is predictable for cleanup; the derivation
# under test here is the WIKI context split, not the owner parse (that's covered
# by test-review-bus-busdir.sh). CODEX_REVIEW_MAX_ITERATIONS is set to prove the
# CODEX_REVIEW_* forwarding reaches the daemon.
env -u WIKI_DIR -u REVIEW_BUS_GUIDANCE_FILE -u REVIEW_BUS_REMOTE \
    -u REVIEW_BUS_PREFIX -u REVIEW_BUS_REPO_CLONE -u CODEX_REVIEW_WORKTREE_ROOT \
    REPO_DIR="$IMPL" BUS_DIR="$BUS" REVIEW_BUS_REPO="proj" REVIEW_BUS_OWNER="testowner" \
    REVIEW_BUS_WATCHER="$IMPL/scripts/review-bus-codex-watcher.sh" \
    REVIEW_BUS_MONITOR="$IMPL/scripts/review-bus-response-monitor.sh" \
    CODEX_REVIEW_MAX_ITERATIONS=7 \
    CODEX_REVIEW_PROGRESS_DETAIL=summary \
    SSH_AUTH_SOCK="/tmp/watch-pr-skill-launch-context-auth.sock" \
    bash "$START" >/dev/null 2>&1 || true
sleep 0.5

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

[ -f "$ENVOUT" ] || die "stub watcher was never launched"

grep -qx "REPO_DIR=$BUS/.review-clone" "$ENVOUT" \
    && pass "git root = dedicated review clone" \
    || die "REPO_DIR not the clone: $(grep '^REPO_DIR=' "$ENVOUT" 2>/dev/null)"
grep -qx "WIKI_DIR=$TMP/proj.wiki" "$ENVOUT" \
    && pass "context: WIKI_DIR = implementer's sibling wiki" \
    || die "WIKI_DIR wrong: $(grep '^WIKI_DIR=' "$ENVOUT" 2>/dev/null)"
grep -qx "REVIEW_BUS_GUIDANCE_FILE=" "$ENVOUT" \
    && pass "guidance NOT forwarded (watcher loads it base-ref-only)" \
    || die "REVIEW_BUS_GUIDANCE_FILE leaked into the daemon env: $(grep '^REVIEW_BUS_GUIDANCE_FILE=' "$ENVOUT" 2>/dev/null)"
grep -qx "CODEX_REVIEW_MAX_ITERATIONS=7" "$ENVOUT" \
    && pass "operator CODEX_REVIEW_* knobs forwarded to the daemon" \
    || die "CODEX_REVIEW_MAX_ITERATIONS not forwarded: $(grep '^CODEX_REVIEW_MAX_ITERATIONS=' "$ENVOUT" 2>/dev/null)"
grep -qx "SSH_AUTH_SOCK=/tmp/watch-pr-skill-launch-context-auth.sock" "$ENVOUT" \
    && pass "forwards the auth whitelist (SSH_AUTH_SOCK) into the daemon" \
    || die "SSH_AUTH_SOCK not forwarded: $(grep '^SSH_AUTH_SOCK=' "$ENVOUT" 2>/dev/null)"

# The MONITOR unit must ALSO receive the CODEX_REVIEW_* knobs (it emits the
# progress lines): a clean --user env would otherwise silently reset progress to
# the defaults, ignoring an operator override.
[ -f "$MONENVOUT" ] || die "stub monitor was never launched"
grep -qx "CODEX_REVIEW_PROGRESS_DETAIL=summary" "$MONENVOUT" \
    && pass "progress knobs forwarded to the MONITOR unit" \
    || die "monitor missing CODEX_REVIEW_PROGRESS_DETAIL: $(grep '^CODEX_REVIEW_PROGRESS_DETAIL=' "$MONENVOUT" 2>/dev/null)"
grep -qx "CODEX_REVIEW_MAX_ITERATIONS=7" "$MONENVOUT" \
    && pass "monitor unit receives the shared CODEX_REVIEW_* env" \
    || die "monitor missing CODEX_REVIEW_MAX_ITERATIONS: $(grep '^CODEX_REVIEW_MAX_ITERATIONS=' "$MONENVOUT" 2>/dev/null)"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
