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
- **Prefer removing the dependency over guarding it.** Where a finding can be
  answered either by adding a check or by changing the shape so the problem cannot
  arise, the session takes the second whenever it is not larger, and says on the
  thread which it took **and why**. A check is a name, and names can be shadowed, mis-parsed
  or forgotten; the fixes that have actually ended a run of review rounds here
  were the ones that removed something rather than watched it.
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
- **Copilot code review**, if you want the two-reviewer loop. It is the default
  and the norm: the merge gate demands a clean verdict from *both* reviewers, and
  the Copilot phase stops rather than skipping if the request cannot be made.

  **A Codex-only merge is supported, and it is a decision rather than a switch.**
  When the Codex phase closes, the loop stops and asks; choosing to merge there
  runs the gate in `codex-only` mode. That mode is **narrower**, not looser: the
  two-reviewer path tolerates a head that advanced past Codex's signoff because
  every commit since carries a `Review-Phase: copilot` trailer, and with no Copilot
  phase there are no such commits and nothing licenses the delta — so it requires
  the head to *be* the commit Codex signed.

  What there is deliberately no switch for is skipping a reviewer *silently*. The
  mode is named at the stop, passed to the gate explicitly, and an unrecognised
  value is refused rather than read as the permissive one.

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

**The helpers run in a privileged shell**, started that way by the skill itself —
`/usr/bin/env bash -p …`. That is what stops a `BASH_ENV` startup file, an
exported shell function or an inherited `SHELLOPTS` from reaching them, and it
needs nothing of your setup: the driver supplies it on every call.

Running a helper **by hand** goes through its shebang instead, which is
`#!/usr/bin/env -S bash -p`. `env -S` has been in GNU coreutils since 8.30 (2018)
and BSD/macOS `env` supports it; on an older `env` the helper refuses to start
rather than starting unprotected.

`pr-origin.sh` is the exception, and cannot be run by hand at all: it is not
executable, because the shell reading it has to be privileged from its first line
and only the caller can arrange that.

**Contributors need that `env`, users do not.** The plugin never depends on the
shebang: the skill supplies `-p` on every call, and so does every call a helper
makes to another helper. The test suite is the exception — it executes the
helpers directly — so `pr-selfcheck.sh`, the mandatory pre-push gate, needs an
`env` with `-S`.

`bash skills/watch-prs/scripts/pr-…​.sh` is **not** supported either way: a startup
file runs before the script's first line and nothing inside it can undo that.

The suite is a mandatory pre-push gate, so a GNU-only construct *in the suite*
stops a macOS contributor from closing a review round while Ubuntu CI stays green
— invisible on the machine that introduced it. CI therefore runs the whole suite a
second time on a machine shaped like a Mac: **bash 3.2.57 built from source — the base release with the official patch
series applied, which is the patch level macOS ships — and first on `PATH`**, with the GNU-only tools removed. Constructs newer than 3.2 fail there
outright, and so do the parsing differences no feature list would contain; a
command name assembled at runtime — `_a=sha1; _b=sum; "$_a$_b"` — dies on absence,
which no text scan can see.

Three things it does not cover, stated rather than assumed: a construct on a branch
the suite never takes; a GNU-only *flag* on a command that exists everywhere
(`sed -i`, `readlink -f`, `grep -P`); and `\s` in a `grep` pattern, where BSD
`grep` does not fail but matches a literal `s`. Those are review's job.

**None of it is running at the moment.** `.github/workflows/tests.yml` is on
`workflow_dispatch` only and `macos-shell` carries `if: false`, so a push produces
no check at all and a dispatch runs the normal job alone. The suite is still the
mandatory pre-push gate — `pr-selfcheck.sh` is unchanged, and it is what a
contributor actually runs — but the second machine is not checking anyone's work
while this stands, so a bash 3.2 or macOS-userland regression can merge. It was
turned off because the per-round cost had grown past what the backlog could carry,
and because several of the portability assertions doing the blocking were
themselves wrong. #93 owns turning the triggers and the job back on — both are named in its
acceptance criteria — after those fixtures are audited.

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

   Every comment on the review counts as a finding, replies included. A reviewer
   sometimes delivers a clean verdict as a reply, and that is *not* exempted:
   the real verdict is followed by paragraphs of explanation, and a retraction is
   also a paragraph after the verdict line, so nothing in the text separates
   them. When a review is nothing but replies the watch reports
   `source=replies-only` and exits **4**, and the skill **stops for you** — there
   is nothing to fix and it is not a signoff, so one comment gets read by a human.
   Both round-closing paths honour that status, so a push-triggered pass cannot
   slip past it either.

   **Your answer becomes state, so the stop ends.** If the comment was a clean
   verdict, the skill records a `**Review-Signoff:**` line for that reviewer and
   head, and the merge gate accepts it *for that shape only*. If it was a finding,
   fix it and push — the head moves and the round is ordinary again. With no
   signoff recorded the gate refuses and says which of the two to do.
4. **Fix and close the round** — commit `fix(review): …`, run the **self-check**
   (`pr-selfcheck.sh`), **check the round boundary**
   (`pr-round-count.sh <PR> <reviewer>`). Then hand the closing to
   **`pr-close-round.sh`**, which holds both orderings so neither has to be
   remembered, and runs in **two stages with your thread replies between them**:

   - `gate <PR> <reviewer> <summary-file> <auto-review>` pushes and proves the
     head is green, and reports it as `head=…`;
   - **then** reply to each thread with what changed, react 👍/👎, and resolve it;
   - `post <PR> <reviewer> <summary-file> <auto-review> <head>` re-proves the head
     has not moved, posts the summary and requests the next pass.

   The threads are answered **after** the gate because a resolve cannot be taken
   back: resolving first means a round that then fails to push, or pushes red, has
   already recorded its findings as answered on a commit that never landed.

   The two orderings the script holds:

   - **automatic review off** (the recommended setting) — the `@codex review`
     mention *is* the request, so it carries the summary in one comment and
     nothing is queued until that comment is posted.
   - **automatic review on** — the *push* is the request, so the push goes first
     and the summary is posted **after** the checks on it are known. Posting
     first cannot be gated: by the time the checks can be consulted the summary is
     already there and cannot be taken back. The pass the push starts reads open
     threads and no summary, and is superseded by an explicit mention carrying the
     summary — which is why this mode costs two Codex passes per round.

   Both checks come *before the push*, because with automatic review on the push
   itself requests the next review and a check placed after it asks you about a
   round that has already started. The summary says what was addressed and what
   was intentionally skipped: a resolved thread is not a record of a fix.
5. **Codex clean → the Copilot phase**, through
   **`pr-copilot-phase.sh`**, which runs in **three stages with your decision
   at each boundary**. Every post they make — and `close` makes none in
   `codex-only`, where there was no Copilot review — goes to the repository **the
   session started in** — the origin URL is read once during
   setup and pinned, so changing directory partway through no longer decides which
   project a signoff or a revocation lands on:

   - `record <PR> <body-file>` re-reads the head, re-validates Codex's verdict
     against *that exact sha*, proves its checks are green, and writes the
     signoff onto the PR in the form `pr-signoff.sh` reads back. Then it stops
     and asks: merge on one reviewer's signoff, or open the second phase. You
     supply one paragraph on what the PR does and what the Codex phase changed;
     everything a machine reads back is composed by the script;
   - `open <PR> <sha>` runs only on the answer, and proves the phase is still
     open before it changes anything: the head is unmoved, Codex's **live verdict**
     on that sha is clean, and the **recorded Codex signoff** still names it. A
     recorded signoff is history, not a current verdict — and a revocation is how a
     phase is deliberately reopened, while GitHub keeps serving the old clean
     verdict until the new pass reports, so neither check answers for the other.
     It also **re-enforces the round boundary**, because the signoff is published
     before the pause and a later session can resume straight into this stage; that
     is why `open` can stop for you rather than proceeding. All of it runs **three
     times** — up front, before the revocation, and again after it — because none
     of these need the head to move, and the revocation is itself a change with the
     request still to come. The order is revoke → prove → baseline → request: the
     proof as late as it can be while the Copilot baseline stays last, which it
     must be or a pass landing in between answers a request made after it.
     Then it revokes any earlier Copilot signoff and requests the pass. The
     revocation is posted on **every** entry, including the first, where there is
     no signoff to revoke: with no Copilot record at all, a head whose only clean
     Copilot verdict is an older review merges, so that comment is the one durable
     mark that a new pass is pending;
   - `close <PR> <codex-sha> [both|codex-only]` is the other end of the same
     phase. Copilot's verdict came back clean, so it re-reads the head, re-checks
     Copilot against *that exact sha* — a push landing while the stop was parked
     would otherwise be recorded as reviewed by someone who never saw it — writes
     the second signoff, and stops to ask what to do with two closed phases.

     **Which question it asks depends on the two shas**, which is why it needs the
     Codex one. Where they differ, Copilot's fixes moved the head after Codex
     looked at it, and a fault-tolerance pass over those commits is offered — with
     the revocation that has to precede it. Where they are the **same commit**,
     Codex has already reviewed exactly what is being merged and no pass is
     offered: taking one there costs a revocation, a round and a reopened phase
     for a verdict that cannot differ, and a session resuming into that reopened
     phase reads it as a Copilot phase to run again. In `codex-only` there was no
     Copilot review at all, so the stage records nothing and says so.

   The body you supply is prose and is posted under your identity, so a line that
   reproduces one of the record markers a reader trusts from *you* —
   `**Review-Signoff:**`, `**Review-Signoff-Revoked:**`,
   `**Review-Pause-Acknowledged:**` — is refused rather than published: it would
   *create* the record it was quoting. (`**Reviewed commit:**` is not among them:
   that one is only read from a reviewer bot's own comment, so writing it here
   creates nothing and is left alone.) **To keep one:** indent it by four spaces
   or quote it inline with backticks — either still says what you meant, because
   the readers only honour these at the start of a line. A fenced block does *not*
   help: the readers scan the raw comment body, where a line inside a fence still
   starts at column 0.

   For a related reason a body containing **`@codex review`** is refused where the
   comment is posted on its own — the phase summary, and a Copilot round's summary.
   Any comment containing that text requests a Codex pass, so quoting it out of a
   finding starts one nobody asked for, in a phase that has just stopped or moved
   on. In a *Codex* round the mention is the request and the script writes it
   itself, so quoting it there changes nothing and is allowed.

   **The remedy is a different one, and indenting is not it.** This trigger is
   matched case-insensitively *anywhere* in the body, not at the start of a line —
   so an indented, quoted or fenced mention still requests the pass and is still
   refused. Break it up, or write it without the `@`.

   Then repeat steps 3–4 until Copilot is clean too. Fix commits here carry a
   `Review-Phase: copilot` trailer, which is how the merge gate knows the head
   advanced only through Copilot fixes and Codex's signoff still covers it — so
   Codex is not re-run.

   The signoff is a comment on the PR rather than a shell variable, so closing
   the terminal or changing machine does not lose it.
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

The suite is the slow part, so it runs four files at a time — they share no
state, and four at a time is ~85s where one after another is ~208s.

It re-runs itself once with `BASH_ENV`, `ENV` and the tracing variables removed,
so a startup file in your shell cannot end up talking over the channel the tests
report through, and cannot leave behind a `readonly -f` function that the check
would then refuse to run past. Exporting `RB_SELFCHECK_CLEAN` skips that step —
a shell that can do so can already edit the tests, so it is a boundary rather
than a guard.

It writes nothing outside itself to do this, and every test reports back whether
it passed, failed, or had vanished before it could run — so a runner that quietly
ran nothing is an error rather than a clean suite, and a test that disappeared
mid-run is neither a pass nor a failure.

`RB_SUITE_JOBS` changes the degree. It takes **one to five digits, no leading
zero**: `1` and `12` are degrees, while `0`, `00`, `01` and `soon` are not, and
neither is a six-digit number. Anything outside that falls back to four rather
than disabling the bound — `xargs -P 0` means *unlimited*, so a spelling of zero
that slipped through would start every file at once, and the degree exists to be
a load bound. Setting it in the shell you drive the skill from is enough: the
skill exports it, along with the other knobs, because the gate runs as a child
process.

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

#### The phase transitions are yours

The loop does not decide how much review your change is worth. It stops twice and
asks:

- **When Codex is clean** — merge on that signoff alone, or open the Copilot
  phase on the same head. One reviewer's clean pass is a legitimate place to stop.
- **When Copilot is clean** — merge, or, *if the Copilot phase produced
  commits*, ask Codex again as fault tolerance over what it changed. Where the
  phase produced none, both signoffs name the same commit and that option is not
  offered: Codex has already reviewed the head being merged, so the pass would
  cost a revocation and a round for a verdict that cannot differ.

Both stops are **resumable**. Each signoff is recorded on the pull request as a
`**Review-Signoff:**` comment naming the reviewer and the exact head, so a
decision that arrives tomorrow — or on another machine — costs nothing that was
already done. `pr-signoff.sh <pr> <reviewer>` reads it back.

## Round check-in

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
check-in is a further `REVIEW_ROUND_THRESHOLD` heads past that number. One comment
may carry a line per reviewer, which is the form the pause message itself prints;
every such line is read, not just the last one in the body.

The count must be that reviewer's own, which is what the pause prints beside each
login. A number ahead of a reviewer's count is refused rather than obeyed — it is
the disable-forever shape, reachable by a typo — and because the highest
acknowledgement wins, a wrong one cannot be lowered by posting another. Edit or
delete the comment instead; the count is derived from the bodies. It names
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

- **Your shell traces to stdout, and the loop moves it:** if you drive with
  `set -x` and a `BASH_XTRACEFD` that lands on standard output, setup reassigns it
  to `2` for the rest of the session — you still see every trace line, on standard error, where
  bash sends it by default. It has to: inside `X="$(cmd)"` file descriptor 1 *is*
  the capture, so a trace aimed there is read back as part of the value, and
  setup would refuse a checkout that is perfectly fine. Nothing else about your
  tracing changes, and a session tracing anywhere else — stderr, a log file on
  another descriptor — is left exactly as it was. So is one that has set
  `BASH_XTRACEFD=1` ready for a later `set -x` but is not tracing yet: with no
  trace running there is nothing to contaminate, and your chosen destination is
  left alone. Setup decides by running one command inside a capture and looking at
  what comes back, so it is the destination that matters and not how you spelled
  it — and it puts your setting back before setup finishes, so nothing about your
  tracing outlives the loop's own startup.
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
  `git remote get-url origin` — read by `pr-origin.sh`, **once at the start of the
  session**, and pinned into `REVIEW_BUS_REMOTE` for every helper. (The read goes
  through a helper, started as `/usr/bin/env bash -p`, rather than running `git` in
  your shell:
  a shell function called `git` would otherwise decide which project the session
  posts to, and privileged mode is what stops a `BASH_ENV` startup file running
  inside the helper at all.) So start the session in the
  intended checkout; changing directory afterwards no longer retargets anything,
  which is the point — the phase stages post signoffs, revocations and review
  requests, and a `cd` into a second checkout used to send those to whatever pull
  request of *that* repository shared the number. If you genuinely need to switch
  repositories, start a new session rather than unsetting the pin.
- **Stale review after a push:** the merge gate blocks a moved head. Post a fresh
  round summary and re-request.
- **"merge queued: … the PR is OPEN, not MERGED":** the base branch uses a merge
  queue. `gh` reports success for *adding* the pull request to that queue, so the
  request was accepted but the head is not on the base branch yet and may still
  leave the queue without landing. The session is **not** finished: watch the PR
  until it merges. `REVIEW_MERGE_STRICT=1` is where this happens — the default
  `--admin` merge bypasses the queue.
- **A round stops with "the head you just pushed is RED":** working as intended.
  The suite passing locally and the checks passing on the runner are different
  claims — GitHub Actions ignores `SIGPIPE`, runs a different shell, and has no
  credentials — so the round will not be closed on a commit whose CI is failing.
  Fix it, push again, and the round continues.
- **A round waits on "pending":** the checks start when the push lands, so it
  waits for them rather than reading "still running" as a pass. Set
  `PR_CI_TIMEOUT` if your CI takes longer than thirty minutes. **Export them**, or
  set them on the command that starts the session: the CI gate is a separate
  process, so a bare `PR_CI_TIMEOUT=3600` in your shell is invisible to it and the
  default applies while your terminal shows the value you set. The driver exports
  any that are already set when it starts, so `export PR_CI_TIMEOUT=3600` before
  invoking the skill is enough.

## License

GPL-2.0 — see [LICENSE](LICENSE).
