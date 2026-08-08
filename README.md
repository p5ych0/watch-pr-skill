# watch-pr-skill

**A team-grade code-review rhythm for solo developers.** You write the code;
GitHub's own reviewers — **Codex** and **Copilot** — review every pull request,
and **Claude Code** works the fix → resolve → re-request loop until they sign
off. The review discipline of a team, with no teammates required.

One install serves every project on your machine.

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
resolve → re-request loop, and gates the merge. Seven small scripts answer the
questions `gh` cannot answer safely on its own — whether a reviewer's review of
the *current* head can carry a merge, whether everything pushed since the
reviewed commit is a review fix, what the unresolved findings actually are, how
many rounds this PR has had, when a verdict is ready to act on, whether the
change about to be pushed passes its own checks *here*, and whether the commit
that was pushed is green *there*. The last two are different questions: a suite
that passes locally can fail on the runner, and one did — for four rounds.

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

### What it asks of the session driving it

The skill binds the model to a working discipline, because the failure mode of an
automated fix loop is not laziness — it is enthusiasm. Each rule below exists
because breaking it turns a three-round PR into a long one:

- **Fix what the finding names, and nothing else** — where "what the finding
  names" is the *defect*, so the same defect in another copy the PR already
  changes is part of it, and a regression the fix itself introduces is always this
  round's work. A round is about that round's findings. Nearby tidying, an opportunistic rename, hardening a path nobody
  raised — all of it enlarges the diff the next review must read, and it arrives
  bundled into a commit whose summary says "closing review comments", where a
  reviewer has no reason to look for it.
- **Build the smallest thing that makes the finding false.** Configuration nobody
  asked for, an abstraction for a single call site, a general mechanism where a
  specific fix was requested — each becomes surface that must then be reviewed and
  maintained. If a broader fix is genuinely warranted, the session opens an issue
  and raises it with you rather than deciding by building — and keeps that
  discussion out of the review request, where a design proposal reads as a work
  order.
- **Validate a finding before acting on it.** Reviewers can be wrong, or right
  about a defect and wrong about its cause. The session reproduces the claim
  first, and where it does not hold, says so in the thread with evidence instead
  of changing code to satisfy it.
- **Read the whole finding, not its title.** The reviewers write a one-line title
  and then the actual argument — the triggering input, the consequence, and often
  a note that the same defect exists elsewhere. A code suggestion attached to a
  finding is treated as a proposal, weighed against context the reviewer could
  not see, with the reasoning recorded in the thread if it is not taken.
- **Prove a fix can fail, or stop.** A test that passes against the unfixed code
  converts an unverified assumption into a green tick, so the session reverts each
  fix and confirms the test fails for the reason it names. Where that genuinely
  cannot be constructed, it writes the limitation at the site and **stops for
  you** — the loop will not close on its own say-so. Accepting the limitation is
  your call, and it becomes binding the way the `--admin` trade-off did: a dated
  record landed on the base branch by its own PR. If a loop refuses to close and
  the summary says a mutation could not be built, that is this rule, and that is
  the decision it is waiting on.
- **Say what was not done.** Anything skipped, deferred or disagreed with goes in
  the round summary. Silence would read as "addressed", and neither you nor the
  reviewer could tell the difference. It goes there as a past-tense disposition
  and an issue number, not as a description of the unfixed problem: the summary
  shares a comment with the review request, and a request that describes work to
  be done gets treated as one.

You are not expected to police this. It is in the skill contract, the reviewers
are told what a well-formed finding contains, and the round check-in brings the
decision back to you at a cadence you set.

## When to use it

**Use it when a change deserves a second pair of eyes and there is nobody to
ask** — anything you would want reviewed if you had a colleague: behaviour
changes, anything touching money, auth, data loss or concurrency, a refactor you
want an independent check on, or work you will not remember the reasoning behind
in a month. It is at its best on a PR that has a clear stated goal, because that
is what the reviewers judge relevance against.

**It is worth less on:** a one-line typo fix, generated or vendored files,
formatting-only commits, or a spike you intend to throw away. The loop costs
reviewer time and round-trips; a PR whose diff is not worth reading is not worth
gating.

**Do not reach for it as a substitute for knowing what you want.** The reviewers
judge the change against what the PR says it set out to do, so a PR with no clear
goal produces vague findings and long rounds. Write the description first; that
is the one input the whole loop is calibrated on.

**If a review loop is running long**, that is information rather than a reason to
push through. The round check-in exists to surface exactly that — see
[Round check-in](#round-check-in). Rounds that keep finding defects in the *fixes*
usually mean the change is too large, and splitting the PR is the faster route.

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
| Automatic review | **off** | The `@codex review` mention is then the only trigger, which is what the loop assumes: each round is requested deliberately, and a red head stops it before anything is resolved or posted. On, the *push* also triggers a pass — one that necessarily reads open threads and no summary, since the checks on what was pushed are what decide whether the round may close at all. The driver waits that pass out and supersedes it with an explicit mention carrying the summary, so a round costs two Codex passes instead of one. Note the per-repository column overrides this default, so check both. |
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

Then:

1. **State the task on the PR.** The description says what the change does and
   what it deliberately does not. The reviewers judge relevance against it, so
   this is a precondition rather than paperwork.
2. **Request the review — Codex first.** With automatic review **off** (the
   recommended setting) that is a comment containing `@codex review`. With it
   **on**, opening or pushing the PR has *already* queued a pass, so no mention is
   sent — one would queue a duplicate review of the same head; post the context
   comment without the mention and go straight to waiting. The loop is *phased*:
   Codex reviews to a clean signoff, and only then is Copilot asked (step 6).
   Running both every round buys a Copilot pass on every intermediate commit and
   mixes its findings into rounds that were not about them.
3. **Wait — without hand-polling.** `pr-watch.sh` blocks until the reviewer's
   state is actionable and prints one line when it changes. In Claude Code it
   runs as the session's Monitor, so the verdict surfaces into the chat by
   itself. It is armed and re-armed as part of each round without asking you —
   see **Watching without prompts**. An unreadable state is a stop, never
   "no findings".
4. **Fix and close the round** — commit `fix(review): …`, run the **self-check**
   (`pr-selfcheck.sh`), **check the round boundary**
   (`pr-round-count.sh <PR> <reviewer>`), reply to each thread with what changed,
   react 👍/👎, and resolve it. Then, **with automatic review off** (the
   recommended setting), push and post **one comment** that opens with
   `@codex review` and continues with the round summary — the mention *is* the
   request, so the account of what changed and the request for the next pass are
   the same comment. **With automatic review on** the push *is* the request, so
   the summary must be posted **before** it and no mention is sent at all; a
   mention would queue a second review of the same head. Either way the summary
   says what was addressed and what was intentionally skipped, and both checks
   come *before the push*: with Codex automatic
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
| `PR_CI_INTERVAL` | `30` | seconds between polls while the pushed head's checks are still running |
| `PR_CI_TIMEOUT` | `1800` | how long to wait for those checks before stopping rather than guessing |
| `PR_CI_GRACE` | `90` | how long a round-closing verdict must hold before it is believed, since a workflow run is registered a moment after the head moves |
| `PR_CI_PROBE_TIMEOUT` | `60` | per-request bound on each `gh` call the check probe makes, so a hung connection cannot outlast the gate's own timeout |

### The pushed head has to be green

A round is not closed until the checks on the commit it pushed have finished and
passed. This is separate from the pre-push self-check below, and it is separate on
purpose: that one runs the suite *here*, and cannot see a failure that only
happens on the runner. One did, and CI stayed red for four consecutive rounds
before anyone looked at the checks tab.

A still-running check is not a pass; the gate waits, bounded by `PR_CI_TIMEOUT`
measured as real elapsed time. A repository with no checks configured has nothing
to be green, and says so rather than blocking.

An answer that would close the round — green, or nothing configured — has to still
be the answer `PR_CI_GRACE` seconds later. A push that starts two workflows can
have the fast one passing before the second is registered at all, so the first
look is green about an incomplete picture.

### Self-check before the push

`pr-selfcheck.sh` runs over the plugin's own sources before a round is pushed:
every variable `SKILL.md` uses is assigned in it, every script parses, every
helper it drives is shipped, every script has a test, and the suite passes.

It exists because this plugin's own PR took nineteen review rounds, and almost
none of the findings were subtle. Rounds are the expensive part of the loop —
each is a review pass, a fix, a summary and a wait — so a finding caught before
the push is worth several caught after it. `SKILL.md § 5a` pairs it with a short
list of the judgement checks a script cannot make.

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

The trade-off is recorded in
[`docs/decisions/2026-08-06-merge-admin-default.md`](docs/decisions/2026-08-06-merge-admin-default.md).

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

**Saying "continue" is recorded on the PR.** The driver posts a comment carrying
a `**Review-Pause-Acknowledged:** \`<reviewer>\` \`<count>\`` line, and the next
check-in is a further `REVIEW_ROUND_THRESHOLD` heads past that number. It names
the reviewer because the count does: the Codex and Copilot phases are separate
loops with separate counts, and an unscoped marker acknowledging 41 Codex rounds
is read by a Copilot phase with 5 as ahead of its count and refused permanently. Without it the gate would
pause on every subsequent call, since it re-derives everything from GitHub and
keeps nothing locally. Only repository owners, members and collaborators can
write that marker, and one naming a round that has not happened yet is rejected:
it records a decision you made, it cannot create permission on its own.

The boundary is a **threshold crossed, not a multiple landed on**. It used to be
`rounds % threshold == 0`, which silently assumes the count rises by one at a
time — a single round can add several heads, and this repository's own PR #10 went
from 35 to 41 across two rounds with the check-in at 40 never firing.

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

Verified against Claude Code as of July 2026. **The plugin system is young and
moving fast** — if install or invocation differs from the above, check the current
plugin docs and open an issue.

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
- **A round stops with "the head you just pushed is RED":** working as intended.
  The suite passing locally and the checks passing on the runner are different
  claims — GitHub Actions ignores `SIGPIPE`, runs a different shell, and has no
  credentials — so the round will not be closed on a commit whose CI is failing.
  Fix it, push again, and the round continues.
- **A round waits on "pending":** the checks start when the push lands, so it
  waits for them rather than reading "still running" as a pass. Set
  `PR_CI_TIMEOUT` if your CI takes longer than thirty minutes.

## License

GPL-2.0 — see [LICENSE](LICENSE).
