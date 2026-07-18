# watch-pr-skill

**A team-grade code-review rhythm for solo developers.** You write the code; a
second AI agent (Codex) reviews every pull request on a file-based bus, and your
coding agent (Claude Code *or* Codex) works the fix → resolve → re-request loop
until the review signs off — the review discipline of a team, with no teammates
required.

One install serves every project on your machine, and it runs under **both Claude
Code and Codex**.

## Why

A solo developer has no one to open a PR to. This plugin gives you the missing
half of a healthy workflow: an independent reviewer that reads every pushed head,
posts inline findings, and holds the merge until they're addressed — so your work
goes through the same gate a teammate's review would, automatically.

## What it is

A file-based **review bus**:

- A detached **watcher** reviews each pushed PR head with `codex exec` (in a
  dedicated clone, on a per-SHA worktree) and writes a response file.
- A **response monitor** turns each response into a `<PREFIX>_REVIEW` notification.
- Your session (Claude Code or Codex) surfaces the notification, reads the
  findings, fixes them, commits, pushes, replies + resolves the threads, posts a
  round summary, and re-requests — looping to a clean signoff, then merging.
- Optional: a **GitHub Copilot** review pass after the Codex signoff.

Everything is derived from the repo's git `origin`, so it works in any project
unchanged, and each project's bus is isolated under `/tmp/<owner>-<repo>-review-bus`.

## Prerequisites

- `git`, `gh` (authenticated — `gh auth status`, `repo` scope), `jq`
- `codex` CLI (`npm i -g @openai/codex`) — the reviewer engine
- `inotify-tools` (`inotifywait`)
- Linux with `systemd --user` for the persistent daemons (a `setsid` fallback is
  used where systemd-user is unavailable)

## Install

**Claude Code:**

```
/plugin marketplace add p5ych0/watch-pr-skill
/plugin install watch-pr-skill@p5ych0-tools
```

**Codex:**

```
codex plugin marketplace add p5ych0/watch-pr-skill
codex plugin add watch-pr-skill@p5ych0-tools
```

(Older/newer Codex builds vary — some use `codex plugin install`; if `add` is
missing, run `codex plugin --help`. The `@p5ych0-tools` marketplace suffix is
required.)

Install once per tool at user scope; it is then available in every project.

## Per-project setup

1. Authenticate `gh` for the repo (`repo` scope).
2. Add review conventions: copy [`.review-bus.example.md`](.review-bus.example.md)
   to your project root as `.review-bus.md`, edit it for your stack, and commit it.
   (A generic review is used if the file is absent.)

## Usage

Invoke the skill:

- Claude Code: `/watch-pr-skill:watch-prs`
- Codex: `/skills` → pick `watch-prs` (or type `$watch-prs`)

It starts the watcher + response monitor (idempotent) and arms the session to
surface reviews. Then:

1. Push your PR branch; request a review — the skill runs `review-bus-request.sh`
   once its preflight gates pass (clean tree, head pushed, no unresolved threads,
   a fresh round-summary comment).
2. When Codex finishes, a `<PREFIX>_REVIEW` notification arrives.
3. The skill reads the findings, fixes them, commits `fix(review): …`, pushes,
   replies + resolves each thread, posts a round summary, and re-requests.
4. On a clean signoff it re-checks the merge gate (head unchanged, threads
   resolved, required checks green) and admin-merges.

### Optional Copilot pass

After a clean Codex signoff the skill can run an optional GitHub Copilot review
pass. It **asks first**; if you don't answer it **holds the merge** (nothing
merges unattended). On opt-in it iterates Copilot to a clean signoff, then merges.

## Automatic arming (opt-in per repo)

The plugin ships a `SessionStart` hook (both tools). In any repo that has a
committed **`.review-bus.md`**, every new session automatically ensures the
daemons are running (in the background) and prompts the agent to attach the
session's review monitor — so you don't have to invoke the skill by hand. In
repos **without** a `.review-bus.md` the hook is a silent no-op, so it never
intrudes on unrelated work. Adding `.review-bus.md` is therefore both the review
conventions *and* the on-switch. (You can still invoke the skill manually
anytime.)

## Configuration (environment variables, all optional)

| Variable | Default | Meaning |
|---|---|---|
| `CODEX_REVIEW_AUTO_OPEN_PRS` | `0` | `1` = watcher auto-discovers open PR heads |
| `CODEX_REVIEW_MAX_ITERATIONS` | `0` | `0` = unlimited; the skill pauses to ask every 10th round |
| `CODEX_REVIEW_ERROR_RETRY_MAX` | `5` | bound on auto-retries after a reviewer error |
| `CODEX_REVIEW_MODEL` | `gpt-5.5` | reviewer model |
| `CODEX_REVIEW_REASONING_EFFORT` | `xhigh` | reviewer reasoning effort |
| `CODEX_REVIEW_COPILOT_TIMEOUT` | `300` | seconds to wait for a Copilot review |

## Updating

**Claude Code:**

```
/plugin marketplace update p5ych0-tools
/plugin update watch-pr-skill
/reload-plugins
```

**Codex:**

```
codex plugin marketplace upgrade p5ych0-tools
codex plugin add watch-pr-skill@p5ych0-tools
```

The `systemd --user` daemons keep running from the *previously* installed plugin
path until relaunched — an update alone doesn't switch the live reviewer. After
updating, relaunch them onto the new version:

```
systemctl --user stop review-bus-<owner>-<repo>-{watcher,monitor}
```

then invoke the skill again (or just start a new session in a repo with a
`.review-bus.md` — the SessionStart hook relaunches them from the new path).

## Tested versions

Verified against Claude Code and Codex as of July 2026. **Both plugin systems are
young and moving fast** (Codex's marketplace CLI is recent; `~/.codex/prompts`
regressed once) — if install or invocation differs from the above, check each
tool's current plugin docs and open an issue.

## Troubleshooting

- **No notifications:** re-invoke the skill (idempotent — it restarts the daemons)
  and confirm `gh auth status`.
- **Reviews target the wrong repo:** the bus derives identity from `git remote
  get-url origin` — run from inside the intended checkout.
- **Stale review after a push:** the merge gate blocks a moved head — post a fresh
  round summary and re-request.
- **Daemons running old code after an update:** stop the `systemd --user` units
  (`systemctl --user stop review-bus-<owner>-<repo>-{watcher,monitor}`) and
  re-invoke the skill to relaunch from the new plugin path.

## License

GPL-2.0 — see [LICENSE](LICENSE).
