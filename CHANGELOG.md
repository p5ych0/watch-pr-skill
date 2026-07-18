# Changelog

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
