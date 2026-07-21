# Changelog

## [1.0.10] — 2026-07-21

- **Fix: cross-repo monitor/watcher kill (the "kill bug").** Since the plugin
  extraction, every repo's daemons exec the identical installed script path, so
  `kill_legacy`'s `pgrep -f -- "$script"` matched a *sibling* repo's healthy
  systemd daemons and TERMed them — only the last-started repo's monitor
  survived. `kill_legacy` now skips any PID already owned by a
  `review-bus-*.service` systemd cgroup (read from `/proc/$pid/cgroup`); systemd
  owns those lifecycles, so only genuinely-legacy setsid strays are swept. Two
  repos' daemons can now coexist.

- **Fix: the round-count check-in never fired.** The pause-every-10-rounds safety
  stop lived only in `SKILL.md` step 0 (bypassed by a manually-driven loop) and
  counted `fix(review):`-prefixed commits (round-fix commits use a module scope
  like `fix(shipment): … (review r7)`, so the count was always 0). It now lives
  in `review-bus-request.sh` — the chokepoint every next-round enqueue passes
  through, manual or via `review-bus-close-round.sh` — and counts **distinct
  enqueued HEAD SHAs** per PR (a same-SHA retry never double-counts). At a
  non-zero multiple of `CODEX_REVIEW_ROUND_THRESHOLD` (default 10) it refuses to
  enqueue (exit 3, `REVIEW_BUS_THRESHOLD_PAUSE`) so the driver pauses to ask the
  operator; cross a single pause with `--continue-threshold`, or disable with
  `CODEX_REVIEW_ROUND_THRESHOLD=0`. `close-round` forwards the pause as a clean
  stop (round still closed + acked; next review withheld).

- **New: live review-progress notifications.** While Codex reviews, the watcher
  writes lifecycle state under `$BUS/progress/` (atomic per-run files keyed by a
  unique `run_id`, so same-SHA re-reviews stay distinct), and the monitor
  surfaces it as throttled `${PREFIX}_REVIEW_PROGRESS` lines — start, phase
  changes, and a heartbeat — so the session sees a review begin and advance
  instead of waiting for the terminal handoff. When the installed Codex supports
  `exec --json`, the watcher taps its event stream for live event/command
  counters (falling back to lifecycle phases + elapsed heartbeats otherwise),
  always preserving Codex's real exit status. Progress is repository-scoped, is
  never a `${PREFIX}_REVIEW` handoff, and — at the default `status` detail —
  carries only counters + phase (never raw chain-of-thought, command output, or
  secrets; the optional `summary` detail relays a sanitized, truncated note). A
  monitor that (re)starts mid-review replays only the active run as
  `state=resumed`; completed history is never replayed. Knobs:
  `CODEX_REVIEW_PROGRESS`, `CODEX_REVIEW_PROGRESS_INTERVAL_SECONDS`,
  `CODEX_REVIEW_PROGRESS_DETAIL`. New `test-review-bus-progress.sh`.

- **Round check-in covers the PASSIVE auto-enqueue too.** The threshold logic is
  now a shared library (`review-bus-rounds.sh`) sourced by BOTH the manual
  `review-bus-request.sh` and the watcher's `write_auto_request`, with
  a single lock-scoped check-and-claim (`review_bus_claim_round`) — so the polling
  watcher's auto-enqueue can no longer bypass the operator pause (it HOLDS with
  `CODEX_AUTO_SKIP reason=round_threshold`), and a concurrent manual + passive
  enqueue at the boundary can't both slip past (the threshold decision and the
  round append share one lock; append-only locking left a check-then-claim TOCTOU).
  The Codex-vs-Claude-Code progress-consumer split is applied to the arming
  instructions + README too (Codex polls the monitor log; no auto-notification is
  promised there). Progress `CODEX_REVIEW_*` knobs are now forwarded to
  the MONITOR systemd unit too (not only the watcher), so an operator override
  isn't silently reset to defaults. SKILL documents the runtime-agnostic progress
  consumer (the monitor log; auto-surfaced via a watch tool in Claude Code, polled
  in Codex). New `test-review-bus-auto-threshold.sh`; launch-context test extended
  to the monitor env (suite: 19).

## [1.0.9] — 2026-07-19
- **New `review-bus-close-round.sh` — one-command round close-out.** The bus
  handoff after addressing a Codex round is not "push + comment": the loop only
  continues when every thread is replied-to + resolved, a fresh summary is
  posted, the next SHA is enqueued, and the handled response is acked. Skipping
  any of these silently stalls the loop (the watcher holds auto-enqueue while
  threads are unresolved; `review-bus-request.sh`'s gate blocks). The new script
  does the whole finalize in one command — preflight up front, then the steps in
  a fail-safe order: resolve every open thread with a thread-level ack, post the
  summary, re-enqueue via `review-bus-request.sh` (all gates re-checked), and ack
  the pre-request responses. It is not transactional — a failure partway stops
  loudly (non-zero exit) and is safe to re-run — but no step is silently skipped.
  SKILL step 7 now calls it instead of the hand-run resolve → request → ack
  sequence that was easy to half-complete. `test-review-bus-close-round.sh`
  covers it (suite: 17).
  - Preflight validates the whole close-out BEFORE the first GitHub mutation:
    HEAD clean + pushed + equal to the PR's head, and `--summary` a **regular**
    readable file (`-r` alone accepts a dir/FIFO that would only fail inside
    `gh pr comment` after every thread is resolved). A reply failure leaves its
    thread unresolved and exits non-zero — never resolve-without-ack.
  - Race-free ack: the round-summary responses are acked by the digest captured
    **before** mutating, via a new `review-bus-response-monitor.sh
    --ack-if-digest <resp> <sha256>` that writes the marker from that value
    without re-hashing the file. Closes an ack TOCTOU — a watcher that swaps in a
    fresh same-SHA review between snapshot and ack now yields a different digest
    the marker can't suppress, so its notification still fires.
  - The "HEAD pushed" preflight resolves the remote head the same way
    `review-bus-request.sh` does — `origin/$BRANCH`, then the actual upstream ref
    — so close-round never rejects a branch (upstream ≠ `origin/$BRANCH`) that the
    request gate it forwards to would accept.
  - The pre-mutation response snapshot is tolerant of a junk / mid-write /
    unreadable `resp-*.json`: it obtains both the pr and the digest defensively
    and skips a file that yields neither, so a single bad file can no longer abort
    the whole close-out under `set -euo pipefail`.
  - The clean-checkout preflight now checks the index too (`git diff --cached`),
    not just `git diff HEAD` — a staged change whose worktree copy was reverted to
    HEAD (index ≠ HEAD, worktree = HEAD) is no longer mistaken for clean.
  - `--summary` validates its argument before shifting: a bare `--summary`, or one
    followed by another flag, now errors clearly instead of a cryptic `shift`
    failure (or swallowing the PR number as the summary path).
  - Fails early with a clear message when the repo owner/repo can't be derived
    (missing / non-GitHub `origin`) instead of falling through to confusing `gh`
    errors — pointing at `REVIEW_BUS_OWNER`/`REVIEW_BUS_REPO`.
  - The "HEAD pushed" error now names the actual upstream ref (not always
    `origin/$BRANCH`), matching the upstream fallback used to resolve it; and the
    review-thread pagination breaks unless both `hasNextPage` and a non-empty
    cursor are present (mirrors `review-bus-request.sh`), so a partial payload
    can't loop on an invalid cursor.

## [1.0.8] — 2026-07-18
- Test suite: `test-review-bus-request.sh` — verifies `review-bus-request.sh`
  fails closed (blocks + writes no request) when the unresolved-threads GraphQL
  query fails, plus a happy-path check. Recovers the one unique bit of coverage
  from the retired in-repo legacy smoke test. Suite is now 16 tests.

## [1.0.7] — 2026-07-18
- Default `CODEX_REVIEW_MODEL` is now `gpt-5.6-sol` — the correct Codex model id
  (the earlier `gpt-5.6` attempt was the wrong string and returned a hard 400).
  Verified working via `codex exec`.

## [1.0.6] — 2026-07-18
- Reviewer reasoning effort: `max` is now an accepted value and the default (was
  `xhigh`). Override with `CODEX_REVIEW_REASONING_EFFORT`.
- Model stays `gpt-5.5` — `gpt-5.6` remains unsupported for Codex ChatGPT accounts
  (verified: hard 400).

## [1.0.5] — 2026-07-18
- Revert default `CODEX_REVIEW_MODEL` back to `gpt-5.5`. `gpt-5.6` is **not
  supported** for Codex on a ChatGPT account (the reviewer returns a hard
  `400 invalid_request_error`), which fails every review. Set a valid model via
  the `CODEX_REVIEW_MODEL` env var if you need a different one.

## [1.0.4] — 2026-07-18
- Test suite: ported 7 more daemon/behavior tests (busdir, clone, health,
  launch-context, prompt, systemd, worktree) — the plugin now carries 15 tests.
- `review-bus-codex-start.sh` accepts `REVIEW_BUS_WATCHER` / `REVIEW_BUS_MONITOR`
  overrides (default = the bundled siblings) so tests can inject a stub daemon.
  No runtime behavior change — the defaults are unchanged.

## [1.0.3] — 2026-07-18
- Default `CODEX_REVIEW_MODEL` set to `gpt-5.6` (was `gpt-5.5`). *(Reverted in
  1.0.5 — gpt-5.6 is unsupported for Codex ChatGPT accounts.)*

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
