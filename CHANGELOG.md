# Changelog

## [1.0.3] — 2026-07-18
- Default `CODEX_REVIEW_MODEL` is now `gpt-5.6` (was `gpt-5.5`). Override with the
  env var as before.

## [1.0.2] — 2026-07-18
- Auto-arm: a shared `hooks/hooks.json` SessionStart hook (both tools) runs
  `hooks/session-start.sh`, which — only in repos that opt in via a committed
  `.review-bus.md` — ensures the daemons are up (detached) and injects a prompt to
  attach the session's review monitor. Quiet in every other repo; always exits 0.
- `.codex-plugin/plugin.json` declares `"hooks": "./hooks/hooks.json"` (Codex
  bundled-hook discovery belt-and-suspenders).
- `test-review-bus-hook.sh` covers the hook's opt-in gating + fail-safe exit.

## [1.0.1] — 2026-07-18
- `RB_SCRIPTS` falls back to locating the installed plugin in either tool's cache
  when `$CLAUDE_PLUGIN_ROOT` isn't populated in skill bash (some Codex builds only
  set it for hook commands).
- README: correct the Codex install command (`codex plugin add
  watch-pr-skill@p5ych0-tools`; build-dependent).

## [1.0.0] — 2026-07-18

Initial release: a dual-tool (Claude Code + Codex) installable review-bus plugin.

- Bundles the `watch-prs` skill + the review-bus scripts (`review-bus-codex-start`,
  `review-bus-codex-watcher`, `review-bus-request`, `review-bus-response-monitor`,
  `review-bus-copilot`) + the test suite.
- Repo-agnostic: identity is derived from the checkout's `git remote get-url
  origin`, so one user-scope install serves every project.
- Scripts are self-locating (`SCRIPT_DIR` for siblings) and derive the consuming
  project from `git rev-parse --show-toplevel`, so they run from the plugin
  install dir under either tool.
- Optional GitHub Copilot review pass after a clean Codex signoff (opt-in; the
  skill asks first and holds the merge if unanswered).
- Installs as a Claude Code plugin (`${CLAUDE_PLUGIN_ROOT}`) and a Codex plugin
  (same var via Codex's legacy-compat alias).
