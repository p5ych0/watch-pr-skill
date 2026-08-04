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
- A **response monitor** emits a `<PREFIX>_REVIEW` line per response (plus live
  `<PREFIX>_REVIEW_PROGRESS` lines while a review runs) to its log/stdout.
- Your session consumes them and works the loop — reads the findings, fixes them,
  commits, pushes, replies + resolves the threads, posts a round summary, and
  re-requests — looping to a clean signoff, then merging. **Claude Code** surfaces
  the lines into the chat automatically (a background Monitor); **Codex** (no such
  tool) polls the monitor log.
- Optional: a **GitHub Copilot** review pass after the Codex signoff.

Every review establishes the PR's **intended scope** first — from its description
and its newest round-summary comment — and uses it for *relevance only*: work the
PR never claimed to do is not filed as a defect of this PR, while a defect in
what the PR did change stays a finding however the description frames it. That
scope is untrusted context, so it establishes intent and can never waive a
finding. This is built in as of 1.0.11 — projects no longer need to write the
rule into their own `.review-bus.md`.

There is currently **no dedicated channel for a non-blocking note**, so the
prompt routes such observations rather than inventing one: every finding becomes
a review thread the merge gate requires resolved, and the reviewer's `summary`
reaches the PR only on a zero-finding review (giving it a real channel is
tracked separately). A reviewer therefore carries an observation in `summary`
only when it returns no findings, and otherwise omits it. Copilot's equivalent
is its overall review body, which the bus does not count as findings.

Everything is derived from the repo's git `origin`, so it works in any project
unchanged, and each project's bus is isolated under `/tmp/<owner>-<repo>-review-bus`.
The daemons are `systemd --user` units scoped per repo
(`review-bus-<owner>-<repo>-{watcher,monitor}`), so you can run the bus in several
repos at once and they won't interfere — arming a second repo never stops the
first repo's reviewer.

## Prerequisites

- `git`, `gh` (authenticated — `gh auth status`, `repo` scope), `jq`
- `codex` CLI (`npm i -g @openai/codex`) — the reviewer engine
- `inotify-tools` (`inotifywait`)
- Linux with `systemd --user` for the persistent daemons (a `setsid` fallback is
  used where systemd-user is unavailable)

## Platform support

> **Linux only, for now.** The plugin is built and tested on Linux — the daemons
> rely on `systemd --user` (with a `setsid` fallback) and the scripts assume a
> POSIX shell + GNU coreutils. **macOS and Windows are not yet supported or
> tested**; they need dedicated research + implementation (e.g. a `launchd` /
> Windows service supervisor for the daemons, and coreutils/BSD-utils
> differences). Contributions welcome.

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
2. When Codex finishes, the monitor emits a `<PREFIX>_REVIEW` line. In **Claude
   Code** it surfaces into the session automatically; in **Codex** (no watch tool),
   poll the monitor log — `grep "<PREFIX>_REVIEW" "$BUS/.codex-logs/response-monitor.log" | tail` — to pick it up.
3. The skill reads the findings, fixes them, commits `fix(review): …`, pushes,
   then **closes the round in one command** —
   `review-bus-close-round.sh N --summary <file>` resolves every open thread
   (with a thread-level ack), posts the summary, re-enqueues the next Codex pass,
   and acks the handled response.
   (Push + comment alone does **not** re-trigger Codex — the round must be closed,
   or the loop stalls on the unresolved-threads gate.)
4. On a clean signoff it re-checks the merge gate (head unchanged, threads
   resolved, required checks green) and admin-merges. The merge itself is pinned
   to the head those checks ran against (`--match-head-commit`), so a push that
   lands after the last gate is rejected by GitHub rather than merged unreviewed,
   and the round is only marked handled once the merge actually succeeds.

### Round check-in (the every-N-rounds pause)

A review loop can run many rounds. So it stays *your* decision to keep going —
rather than rubber-stamping an endless back-and-forth — the bus pauses for a
check-in every **N distinct pushed heads** for a PR (`N =
CODEX_REVIEW_ROUND_THRESHOLD`, default `10`). At the boundary the next enqueue is
withheld and you'll see:

```
REVIEW_BUS_THRESHOLD_PAUSE pr=<PR> rounds=<count> next_sha=<full sha>
```

You then choose:

- **Continue** — cross a single pause with `--continue-threshold`
  (`review-bus-close-round.sh <PR> --summary <file> --continue-threshold`, or
  re-run `review-bus-request.sh <PR> --continue-threshold`). The pause re-arms
  for the *next* N rounds.
- **Stop** — merge, leave the PR open, or abandon it — whatever the state calls for.
- **Turn the pauses off** — `export CODEX_REVIEW_ROUND_THRESHOLD=0`.

The count is over *distinct* enqueued head SHAs, so a same-SHA retry never
double-counts, and the check-in fires on **both** the manual enqueue and the
auto-discovered one (`CODEX_REVIEW_AUTO_OPEN_PRS=1`) — the polling watcher can't
slip past the checkpoint. (A malformed threshold value is treated as the default
`10`, never as "disabled", so a typo can't silently remove the check-in.)

### Optional Copilot pass

After a clean Codex signoff, the skill asks whether to run an optional GitHub Copilot review pass.

- **If you opt in**, it runs Copilot review rounds until clean signoff, then merges.
- **If you explicitly decline (skip Copilot)**, it merges on the clean Codex signoff (after final merge-gate checks).
- **If you do not answer**, it holds and does not merge unattended.

As of 1.0.12 this is enforced rather than merely instructed. `review-bus-copilot.sh gate <PR>`
is a hard gate in the merge block: it exits 0 only when Copilot has a clean review on the
**current head** or you declined for that head (`review-bus-copilot.sh decline <PR>`), 1 when
the pass is still owed, and 2 when it cannot tell — which fails closed. So skipping Copilot
is now an explicit recorded decision instead of something that can happen by simply never
asking. A decline does not survive a later push: new code re-opens the question.

Copilot being *unavailable* — the repository cannot request it — is recorded the same way,
and is equally head-scoped. It is also revoked the moment a later request on that same head
succeeds, so a repository that gains Copilot mid-loop does not merge on a stale "unavailable"
while the pass it has just requested is still running.

The gate does not simply trust that marker, either: it is the one permissive piece of bus
state, so before honouring it the gate checks whether Copilot is currently a *requested
reviewer* on the PR. A pending request can only exist because the request succeeded, which
proves the marker stale — and if that check cannot be made, the gate fails closed rather than
giving the marker the benefit of the doubt.

Codex also stops re-reviewing during the Copilot loop. A clean signoff records the signed-off
SHA, and auto-enqueue holds while **every** commit since it carries a `Review-Phase: copilot`
trailer — so Copilot-fix commits no longer burn a Codex review, a round against the check-in
threshold, and a notification each. Any commit without the trailer invalidates the phase and
Codex reviews normally, so forgetting it costs one redundant review rather than a missed one.

## Automatic arming (opt-in per repo)

The plugin ships a `SessionStart` hook (both tools). In any repo that has a
committed **`.review-bus.md`**, every new session automatically ensures the
daemons are running (in the background) and prompts the agent to attach the
session's review monitor — so you don't have to invoke the skill by hand. In
repos **without** a `.review-bus.md` the hook is a silent no-op, so it never
intrudes on unrelated work. Adding `.review-bus.md` is therefore both the review
conventions *and* the on-switch. (You can still invoke the skill manually
anytime.)

The hook never arms the bus **inside a review**. The reviewer works in a
detached worktree of the PR head, which carries your `.review-bus.md` — so the
opt-in gate would otherwise pass for the reviewer itself and spend the pass on
bus setup. It exits silently on either of two signals: `REVIEW_BUS_WORKER=1`,
which the watcher exports into the review, or a `review-bus-worker` marker the
watcher writes into the worktree's **git dir** (never the working tree, so it
cannot reach the diff). The second signal covers a tool that does not forward
environment variables to hook commands. Neither is a path test, so a custom
`CODEX_REVIEW_WORKTREE_ROOT` is still recognised and an ordinary checkout that
happens to sit under such a directory still arms normally.

## Configuration (environment variables, all optional)

| Variable | Default | Meaning |
|---|---|---|
| `CODEX_REVIEW_AUTO_OPEN_PRS` | `0` | `1` = watcher auto-discovers open PR heads |
| `CODEX_REVIEW_MAX_ITERATIONS` | `0` | hard cap on total review rounds per PR (a runaway backstop); `0` = unlimited. Distinct from the periodic *pause* below — this is a stop, not a check-in |
| `CODEX_REVIEW_ROUND_THRESHOLD` | `10` | round check-in cadence (see [Round check-in](#round-check-in-the-every-n-rounds-pause)); `0` = disable. `review-bus-request.sh` refuses to enqueue the next review (exit 3, `REVIEW_BUS_THRESHOLD_PAUSE`) every Nth **distinct enqueued SHA** per PR, so the driver pauses to ask. Cross with `--continue-threshold`. A non-integer value falls back to `10` (never silently disabled) |
| `CODEX_REVIEW_ERROR_RETRY_MAX` | `5` | bound on auto-retries after a reviewer error |
| `CODEX_REVIEW_MODEL` | `gpt-5.6-sol` | reviewer model |
| `CODEX_REVIEW_REASONING_EFFORT` | `max` | reviewer reasoning effort (`minimal`…`xhigh`, `max`) |
| `CODEX_REVIEW_COPILOT_TIMEOUT` | `300` | seconds to wait for a Copilot review |
| `CODEX_REVIEW_PROGRESS` | `1` | `1` = emit live `${PREFIX}_REVIEW_PROGRESS` lines while a review runs; `0` = off |
| `CODEX_REVIEW_PROGRESS_INTERVAL_SECONDS` | `30` | heartbeat cadence for an unchanged in-flight review |
| `CODEX_REVIEW_PROGRESS_DETAIL` | `status` | `status` (counters + phase, safe default) · `summary` (adds a sanitized `note=`) · `off` |

### Live review progress

While Codex reviews, the watcher writes lifecycle state under `$BUS/progress/`
(one atomic file per run, keyed by a unique `run_id` so same-SHA re-reviews stay
distinct), and the response monitor surfaces it as throttled
`${PREFIX}_REVIEW_PROGRESS` lines — a review start, phase changes
(`queued` → `preparing_worktree` → `preparing_context` → `reviewing` →
`validating_result` → `posting_comments`), and a periodic heartbeat — so the attached session sees a
review begin and advance instead of waiting silently for the terminal
`${PREFIX}_REVIEW` handoff. When the installed Codex supports `exec --json`, the
watcher taps its structured event stream for live event/command counters (and
falls back to lifecycle phases + elapsed-time heartbeats otherwise), always
preserving Codex's real exit status. Progress lines are **never** a
`${PREFIX}_REVIEW` handoff (only that triggers findings handling), are strictly
repository-scoped, and — at the default `status` detail — carry only counters and
phase, never raw chain-of-thought, command output, or secrets. A monitor that
starts or restarts mid-review replays only the **currently active** run as
`state=resumed`; completed history is never replayed.

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
