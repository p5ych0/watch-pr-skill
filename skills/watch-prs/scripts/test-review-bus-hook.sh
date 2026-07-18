#!/usr/bin/env bash
# Gating test for the SessionStart hook (hooks/session-start.sh): it must be a
# quiet no-op unless the current repo opted in with a .review-bus.md, and inject
# the arm-instruction (plain stdout) when it did. Daemon start is stubbed so the
# test never touches systemd.
set -uo pipefail
SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SELF/../../../hooks/session-start.sh"   # plugin-root/hooks/session-start.sh
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

[ -f "$HOOK" ] || { echo "FAIL - hook not found: $HOOK"; echo "RESULT: FAIL"; exit 1; }

# Stub plugin root: a harmless start script so the hook's detached launch never
# hits real systemd.
STUB="$TMP/plugin"; mkdir -p "$STUB/skills/watch-prs/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/skills/watch-prs/scripts/review-bus-codex-start.sh"
chmod +x "$STUB/skills/watch-prs/scripts/review-bus-codex-start.sh"

# (a) non-git dir → no-op (no context)
out="$(cd "$TMP" && CLAUDE_PLUGIN_ROOT="$STUB" bash "$HOOK" 2>/dev/null)"
[ -z "$out" ] && pass "non-git dir => no-op (no context)" || die "non-git emitted: '$out'"

# (b) git repo WITHOUT .review-bus.md → no-op
REPO="$TMP/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q
out="$(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$STUB" bash "$HOOK" 2>/dev/null)"
[ -z "$out" ] && pass "git repo without .review-bus.md => no-op" || die "no-optin emitted: '$out'"

# (c) git repo WITH .review-bus.md → inject the arm instruction (plain stdout)
: > "$REPO/.review-bus.md"
out="$(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$STUB" bash "$HOOK" 2>/dev/null)"
echo "$out" | grep -q 'watch-pr-skill' \
  && echo "$out" | grep -qi 'watch-prs skill' \
  && pass "opt-in repo => arm instruction injected on stdout" \
  || die "opt-in produced no/incomplete context: '$out'"

# (d) always exits 0 even when the start script is missing (must never block session)
rm -f "$STUB/skills/watch-prs/scripts/review-bus-codex-start.sh"
( cd "$REPO" && CLAUDE_PLUGIN_ROOT="$STUB" bash "$HOOK" >/dev/null 2>&1 )
[ "$?" -eq 0 ] && pass "missing start script => still exits 0 (never blocks)" || die "hook exited non-zero when start script absent"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
