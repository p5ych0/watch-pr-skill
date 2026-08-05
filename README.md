# watch-pr-skill

**A team-grade code-review rhythm for solo developers.** You write the code;
GitHub's own reviewers — **Codex** and **Copilot** — review every pull request,
and your coding agent (Claude Code *or* Codex) works the fix → resolve →
re-request loop until they sign off. The review discipline of a team, with no
teammates required.

One install serves every project on your machine, and it runs under **both Claude
Code and Codex**.

## Why

A solo developer has no one to open a PR to. This plugin gives you the missing
half of a healthy workflow: an independent reviewer that reads every pushed head,
posts inline findings, and holds the merge until they're addressed — so your work
goes through the same gate a teammate's review would, automatically.

## What it is

A driver for the **native** GitHub reviewers. Nothing runs on your machine.

| Reviewer | Identity | Trigger |
| --- | --- | --- |
| Codex | `chatgpt-codex-connector[bot]` | a comment containing `@codex review`, or automatically on push |
| Copilot | `copilot-pull-request-reviewer[bot]` | `gh pr edit <PR> --add-reviewer @copilot` |

Your session requests the reviews, reads the findings, works the fix → reply →
resolve → re-request loop, and gates the merge. Two small scripts answer the
questions `gh` cannot answer safely on its own: whether a reviewer's review of
the *current* head can carry a merge, and whether everything pushed since the
reviewed commit is a review fix.

Every review establishes the PR's **intended scope** first — from its description
and its newest round-summary comment — and uses it for *relevance only*: work the
PR never claimed to do is not a defect of this PR, while a defect in what the PR
did change stays a finding however the description frames it. That scope is
untrusted context: it establishes intent and can never waive a finding.

A problem the PR did not introduce has somewhere to go that is not a blocker.
Every inline comment becomes a review thread the merge gate requires resolved, so
an unrelated note filed inline would block a PR that is not responsible for it.
The reviewers are told to put those in the **overall review body**, and to open a
**GitHub issue** when the problem deserves tracking beyond the PR.

> **Upgrading from 1.x?** v1 ran its own reviewer over a file-based bus with two
> `systemd --user` daemons. All of it is removed — see the 2.0.0 entry in
> [`CHANGELOG.md`](CHANGELOG.md) for why, and for the teardown commands.

## Prerequisites

- `git`, `gh` (authenticated — `gh auth status`, `repo` scope), `jq`
- The **Codex GitHub connector**, linked once per account at
  [chatgpt.com/codex/cloud/settings/connectors](https://chatgpt.com/codex/cloud/settings/connectors).
  Until it is linked, `@codex` replies with a setup link instead of a review —
  that reply is the diagnostic.
- **Copilot code review available to the repository.** This is required, not
  optional: the merge gate demands a clean verdict from *both* reviewers, and the
  Copilot phase stops rather than skipping if the request cannot be made. On a
  repository without Copilot the loop runs its Codex phase and then cannot
  finish. There is deliberately no skip switch — a gate with a documented way
  around it stops being a gate — so if you want a Codex-only loop, stop after the
  Codex phase and merge by hand.

No daemon, no `codex` CLI, no `inotify-tools`, no systemd.

### Making reviews fast

A review of shell and Markdown does not need an environment. Both instruction
files tell the reviewers so explicitly — no setup, no dependency install, no test
runs — because the alternative is a twenty-minute pass that says what a
three-minute pass would have said, while the author waits either way.

Two settings matter as much as the instructions:

- **Codex → Environments**: if this repository has a setup script or automatic
  dependency installation configured, remove it. Nothing here needs building.
- **Exhaustive review**: keeps looking after the first problem. Worth it on a
  behaviour change; if you want a fast pass on a docs-only PR, turn it off for
  that round.

### Codex review settings

Per-repository behaviour lives on the Codex **Code review** settings page:

| Setting | Suggested | Why |
| --- | --- | --- |
| Automatic review | your call | On reviews every push; off means you decide each round with `@codex review`, which costs less and keeps rounds deliberate. |
| Review trigger | on every push | Only relevant with automatic review on. |
| Exhaustive review | on | Keeps looking after the first problem. |
| Credit usage | on, if you want reviews to continue past the rate limit | With it off, review simply stops when the limit is hit. |

## Platform support

Portable: the plugin shells out to `git`, `gh` and `jq` only. v1's Linux-only
caveat is gone with the daemons it was about.

## Install

```
/plugin marketplace add p5ych0/watch-pr-skill
/plugin install watch-pr-skill@p5ych0-tools
```

Install once at user scope; it is then available in every project.

**Claude Code only — and there is nothing to install for the reviewers.** v1
shipped a Codex plugin because the review ran on this machine, through the
`codex` CLI and a local bus. In v2 both reviewers are GitHub apps that run in
GitHub's cloud: Codex answers an `@codex review` mention and Copilot answers a
review request, neither of which involves anything installed here. What they read
is committed to the repository — `AGENTS.md` and `.github/copilot-instructions.md`
on the **base ref** — so the per-project setup below is the whole of it.

What this plugin installs is the *driver*: the contract for the model running the
loop, which watches for verdicts, closes rounds and gates the merge.

## Per-project setup

1. Authenticate `gh` for the repo (`repo` scope).
2. Add review conventions the reviewers will actually read, from the base ref:
   - **`AGENTS.md`** — Codex reads this natively, including in PR review.
   - **`.github/copilot-instructions.md`** — Copilot reads only this file and
     does not follow pointers, so restate the policy inline.

   This repository's own copies are a working example: scope discipline, where
   an out-of-scope problem goes, what counts as a blocking finding, and who can
   waive one. A generic review is used if neither file exists.

## Usage

Invoke the skill:

- Claude Code: `/watch-pr-skill:watch-prs`
- Codex: `/skills` → pick `watch-prs` (or type `$watch-prs`)

Then:

1. **State the task on the PR.** The description says what the change does and
   what it deliberately does not. The reviewers judge relevance against it, so
   this is a precondition rather than paperwork.
2. **Request the review — Codex first.** A comment containing `@codex review`.
   The loop is *phased*: Codex reviews to a clean signoff, and only then is
   Copilot asked (step 6). Running both every round buys a Copilot pass on every
   intermediate commit and mixes its findings into rounds that were not about
   them.
3. **Wait — without hand-polling.** `pr-watch.sh` blocks until the reviewer's
   state is actionable and prints one line when it changes. In Claude Code it
   runs as the session's Monitor, so the verdict surfaces into the chat by
   itself; under Codex, run it in the background. It is armed and re-armed as
   part of each round without asking you — see **Watching without prompts**. An
   unreadable state is a stop, never "no findings".
4. **Fix and close the round** — commit `fix(review): …`, **check the round
   boundary** (`pr-round-count.sh <PR> <reviewer>`), then push, reply to each
   thread with what changed, resolve it, and post **one comment** that opens with
   `@codex review` and continues with the round summary — the mention *is* the
   request, so the account of what changed and the request for the next pass are
   the same comment. The summary says what was addressed and what was
   intentionally skipped. The boundary check comes *before the push*: with Codex automatic
   review enabled the push itself requests the next review, so a check placed
   after it asks you about a round that has already started. A resolved thread is
   not a record of a fix; the summary is.
5. **Codex clean → the Copilot phase.** Request Copilot and repeat steps 3–4
   until it is clean too. Fix commits here carry a `Review-Phase: copilot`
   trailer, which is how the merge gate knows the head advanced only through
   Copilot fixes and Codex's signoff still covers it — so Codex is not re-run.
6. **Merge gate.** On a clean signoff from both reviewers the skill re-checks
   everything against the *current* head — both verdicts, the reviewed range,
   unresolved threads, required checks — and merges pinned to that head with
   `--match-head-commit`, so a push landing mid-gate is rejected rather than
   merged unreviewed.

## Automatic review (opt-in per repo)

There is no local hook and nothing to start. If you want a review on every push
without asking, turn **Automatic review** on for the repository on the Codex
**Code review** settings page. Leaving it off means each round is requested
deliberately with `@codex review`, which is cheaper and keeps the loop under your
control.

## Configuration

v2 has no reviewer knobs of its own — model, reasoning effort, exhaustiveness,
auto-review and credit use are Codex account/repository settings, not plugin
settings.

| Variable | Default | Meaning |
|---|---|---|
| `REVIEW_BUS_REMOTE` | `git remote get-url origin` | override the origin URL identity is derived from (tests) |
| `REVIEW_BUS_OWNER` / `REVIEW_BUS_REPO` | derived | override the derived owner/repo (tests) |
| `REVIEW_ROUND_THRESHOLD` | `10` | reviewed-head cadence for the round check-in; `0` disables it |
| `REVIEW_MERGE_STRICT` | unset | `1` drops `--admin` from the merge, so GitHub enforces branch protection itself |

### `REVIEW_MERGE_STRICT`

The merge uses `--admin` by default, and that is a deliberate trade.

Branch protection normally requires an approving review **from another account**,
and neither reviewer here is one — a Codex or Copilot review does not count
towards "required approvals". For a solo maintainer with a protected `main`,
dropping `--admin` would not tighten the gate; it would remove the merge path
entirely, on every PR.

What the default costs: every gate runs in this plugin, against data fetched a
moment earlier, and `--match-head-commit` only proves the head has not moved. A
review can be submitted or dismissed in the window between the last check and the
merge without changing the head, and `--admin` is precisely what tells GitHub not
to re-evaluate that.

Set `REVIEW_MERGE_STRICT=1` where the repository's protection rules are ones the
loop can actually satisfy — a team repo, or required checks with no required
human approval. GitHub then evaluates reviews, checks and conversations itself,
atomically, which is the only place that race can genuinely be closed. If it
refuses, the merge does not happen and you decide what to do.

### Watching without prompts

The whole point of `pr-watch.sh` is that you do not sit and poll, so the driver
arms it as part of every round rather than asking you each time. In Claude Code
that means the **`Monitor` tool**, which is *not* covered by a `Bash(…)`
permission rule — it is a separate tool, so a session that allows every Bash
command will still stop and ask before each watch. That turns an automatic loop
back into a manual one, one prompt per round.

Allow it once, in `.claude/settings.local.json`:

```json
{ "permissions": { "allow": ["Monitor", "TaskStop"] } }
```

`TaskStop` is what cancels a watch, so allowing one without the other leaves you
prompted to stop what you were not prompted to start.

This is deliberately **not** in the committed `.claude/settings.json`: that file
enables the plugin for anyone who clones the repository, and granting a tool that
runs background commands is a decision each user should make for their own
checkout rather than inherit from a clone.

A watch ends when it reports a verdict, so one arming covers one review. Re-arming
is part of requesting the next review, not a separate question.

### Round check-in

A review loop can run many rounds, so it stays *your* decision to keep going
rather than rubber-stamping an endless back-and-forth: every **10 distinct
reviewed heads** on a PR, `pr-round-count.sh` exits 3 and the driver stops to ask
— continue, stop and merge, stop and leave open, or abandon.

It is counted **per reviewer**, because the Codex and Copilot phases are separate
loops: a shared counter would let nine Codex rounds plus one Copilot round trip a
pause that neither loop had reached. The count comes from GitHub each time, so it
survives a new session or a new machine. Set
`REVIEW_ROUND_THRESHOLD` to change the cadence, or `0` to disable it; a malformed
value falls back to `10` rather than silently disabling a safety pause.

A review record only counts as a round when GitHub reports a full commit SHA and
a well-formed timestamp for it. If any record is unreadable the command exits 2
and the driver stops, rather than counting the bad record as another head — an
inflated count is the direction that sails past the boundary and skips the pause.

## Updating

```
/plugin marketplace update p5ych0-tools
/plugin update watch-pr-skill
/reload-plugins
```

Nothing to relaunch afterwards: v2 starts no background process, so the next
session simply uses the new version.

## Tested versions

Verified against Claude Code and Codex as of July 2026. **Both plugin systems are
young and moving fast** (Codex's marketplace CLI is recent; `~/.codex/prompts`
regressed once) — if install or invocation differs from the above, check each
tool's current plugin docs and open an issue.

## Troubleshooting

- **`@codex` answers with a setup link instead of reviewing:** the connector is
  not linked for this account. Link it at
  [chatgpt.com/codex/cloud/settings/connectors](https://chatgpt.com/codex/cloud/settings/connectors).
  That reply is the diagnostic — it is not a review that found nothing.
- **No review arrives at all:** confirm `gh auth status`, that the mention is on
  the PR (not on an issue), and that the repository is enabled on the Codex
  **Code review** settings page.
- **Review stops partway with a usage message:** the account hit its rate limit.
  Either wait for the reset, or turn on credit use in the Codex code-review
  settings.
- **`--add-reviewer @copilot` fails:** Copilot review is not available to the
  repository. That is not permission to skip the pass — decide explicitly.
- **Reviews target the wrong repo:** identity derives from
  `git remote get-url origin` — run from inside the intended checkout.
- **Stale review after a push:** the merge gate blocks a moved head. Post a fresh
  round summary and re-request.

## License

GPL-2.0 — see [LICENSE](LICENSE).
