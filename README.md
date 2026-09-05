# watch-pr-skill

**A team-grade code-review rhythm for solo developers.** You write the code;
GitHub's own reviewers, **Codex** and **Copilot**, review every pull request, and
**Claude Code** works the fix → reply → resolve → re-request loop until they sign
off. Then it stops and asks you before opening the second reviewer's phase, and
again before merging, or takes the answers you gave in advance and runs unattended.

One install serves every project on your machine. No daemon: nothing keeps
running between sessions.

## What it does

The plugin is a driver for the native GitHub reviewers. Your session:

1. states the task on the PR and requests a Codex review;
2. waits for the verdict without polling by hand;
3. reads the findings, fixes what each one names and nothing else, replies on
   every thread, resolves it, and requests the next pass;
4. repeats until Codex is clean, then **stops and asks** whether to merge on that
   signoff alone or open the Copilot phase on the same head;
5. runs the Copilot phase the same way, then **stops and asks** again;
6. evaluates every merge gate immediately before merging, pinned to one commit.

| Reviewer | Identity | How it is asked |
| --- | --- | --- |
| Codex | `chatgpt-codex-connector[bot]` | a PR comment containing `@codex review` |
| Copilot | `copilot-pull-request-reviewer[bot]` | a review request for `@copilot` |

The reviewers judge relevance against what the PR says it set out to do, so the
description is the one input the whole loop is calibrated on. Write it first.

**Use it** when a change deserves a second pair of eyes and there is nobody to
ask: behaviour changes, anything touching money, auth, data loss or concurrency,
a refactor you want checked, work you will not remember the reasoning behind.
**Skip it** for a one-line typo, generated files, formatting-only commits, or a
spike you will throw away. If a loop runs long, that is information: rounds that
keep finding defects in the *fixes* usually mean the change is too large.

## Requirements

- **`git`, `gh`, `jq`, `perl`.** `gh` must be authenticated with the `repo` scope
  (`gh auth status`). `perl` is a hard requirement: the helpers hand values to
  each other in files, and the shell has no safe spelling of the exclusive create
  and exact rename that takes. macOS ships it; on Linux, install it if your
  distribution does not.
- **The Codex GitHub connector**, linked once per account at
  [chatgpt.com/codex/cloud/settings/connectors](https://chatgpt.com/codex/cloud/settings/connectors).
  Until it is linked, `@codex` replies with a setup link instead of a review.
- **Copilot code review** on the repository, for the two-reviewer loop. A
  Codex-only merge is supported as a decision you make at the first stop. What
  there is deliberately no switch for is skipping a reviewer silently: the mode
  is chosen at the stop, by you or by the unattended rule below, recorded on the
  PR and passed to the merge gate by name.
- **Claude Code.** Both reviewers run in GitHub's cloud; nothing is installed for
  them here.

Works on Linux and macOS. Running one of the privileged helpers by hand goes
through its `#!/usr/bin/env -S bash -p` shebang and needs an `env` that supports
`-S` (GNU coreutils 8.30 or later, or BSD `env`). The skill itself never depends
on it, `pr-selfcheck.sh` does not use it, and `pr-origin.sh` cannot be run by
hand at all.

## Install

```
/plugin marketplace add p5ych0/watch-pr-skill
/plugin install watch-pr-skill@p5ych0-tools
```

Install once at user scope. To update:

```
/plugin marketplace update p5ych0-tools
/plugin update watch-pr-skill
/reload-plugins
```

## Per-project setup

1. Authenticate `gh` for the repository.
2. Commit review conventions the reviewers read from the base branch:
   - `AGENTS.md` for Codex, which reads it natively in PR review;
   - `.github/copilot-instructions.md` for Copilot, which reads only that file
     and follows no pointers, so restate the policy inline.

   This repository's own copies are a working example: scope discipline, where
   an out-of-scope problem goes, what counts as a blocking finding, and who can
   waive one. Without them the reviewers use a generic review.
3. On the Codex **Code review** settings page, turn **Automatic review off** for
   the repository. The `@codex review` mention is then the only trigger, each
   round is requested deliberately, and a red head stops the round before
   anything is resolved or posted. With automatic review on and its review
   trigger set to every push, the push queues the pass, the summary has to
   follow the push, and each round costs two Codex passes instead of one; the
   loop supports no other automatic combination.

   **Exhaustive review** keeps looking after the first problem and is worth
   leaving on. For a repository that can be reviewed statically, as this one of
   shell and Markdown can, a Codex environment with a setup script or dependency
   installation only slows the pass; remove it there.

### Watching without prompts

The session waits for verdicts through Claude Code's `Monitor` tool, which no
`Bash(…)` permission rule covers, so allow it once in `.claude/settings.local.json`
or the session asks before every wait:

```json
{ "permissions": { "allow": ["Monitor", "TaskStop"] } }
```

`TaskStop` is what cancels a watch. This is deliberately not in the committed
settings: granting a tool that runs background commands is each user's decision
for their own checkout. An unattended session needs it: a wait that prompts is a
stop.

## A session

Invoke the skill with `/watch-pr-skill:watch-prs` from a checkout of the
repository, on the PR's branch. The session pins itself to that repository's
`origin` at the start, so changing directory later does not retarget anything;
to work on another repository, start a new session. The loop drives
same-repository pull requests only: a PR whose head is in a fork is refused at
the first push.

### The Codex phase

The session posts the request, waits, and reads the findings. For each one it
reproduces the claim before acting on it, fixes the defect the finding names
(including the same defect in another copy the PR already changes), and prefers
removing a dependency over guarding it. Where a finding does not hold, it says so
on the thread with evidence rather than changing code to satisfy it. Each fix
commit is proved to fail without the fix; where that cannot be constructed, the
session writes the limitation at the site and **stops for you**.

Before closing a round the session runs this plugin's own pre-push self-check,
which reports "not applicable" in any other repository and checks nothing of
your project (your CI does that), then it must check the round boundary, since
with automatic review on the push itself is the next request. It then hands the closing to `pr-close-round.sh`, which runs in
two stages with the thread replies between them: the push, then the CI gate,
which waits for that head's checks on the runner and lets the round close on
green or on no checks configured, never on red or pending; then the replies and
resolves, then the summary comment that carries the next request. The summary says what was
addressed and what was intentionally skipped, as a past-tense disposition and an
issue number, because it shares a comment with the review request and a request
that describes work to be done is treated as one.

### The stops

The loop stops and asks at these points:

1. **A review that is only replies.** Reviewers sometimes deliver a clean
   verdict, or a retraction, as a reply. Nothing in the text separates the two,
   so the session stops and asks you to read it. If it was a clean verdict, say
   so and a signoff is recorded for that head; if it was a finding, fix it and
   push.
2. **A limitation it cannot test**, as above. Accepting it is your call, and it
   becomes binding as a dated record landed on the base branch by its own PR,
   under `docs/decisions/`.
3. **The round check-in.** Every `REVIEW_ROUND_THRESHOLD` distinct reviewed
   heads per reviewer (default 10), the session stops: continue, merge, leave
   the PR open, or abandon. Saying "continue" is recorded on the PR, so the next
   check-in is a further threshold past that count.
4. **Codex is clean.** Merge on that signoff alone, or open the Copilot phase on
   the same head. The Codex-only merge is the narrower gate, not a looser one: it
   requires the head to *be* the commit Codex signed.
5. **Copilot is clean.** Merge, leave the PR open, or, only if the Copilot
   phase produced commits, ask Codex once more as fault tolerance over what it
   changed. Where the phase
   produced no commits, both signoffs name the same head and the pass is not
   offered.

   The body you supply is prose and is posted under your identity, so a line
   that reproduces one of the record markers a reader trusts from you —
   `**Review-Signoff:**`, `**Review-Signoff-Revoked:**`,
   `**Review-Pause-Acknowledged:**` — is refused rather than published: it would
   create the record it quotes. Indent it by four spaces or quote it inline with
   backticks; a fenced block does not help, since the readers scan the raw body.
   A body containing `@codex review` is refused wherever the comment is posted
   on its own, because any comment containing that text requests a pass.

Every signoff is a `**Review-Signoff:**` comment on the PR naming the reviewer,
the head and, where the phase could read it, the time of the verdict it
answers, so a decision that arrives
tomorrow, or on another machine, costs nothing already done. A new session
reads the records back and resumes from the right stop.

### Running unattended

Export `WATCH_PR_AUTONOMOUS=1` and the session takes these answers at the decision
stops instead of asking, recording each on the PR as it would your word:

- **the round check-in**: acknowledge and continue, so the record of a long loop
  stays on the PR;
- **Codex is clean**: merge on that signoff alone if Codex approved the opening
  request, otherwise open the Copilot phase; a session resumed at this stop opens
  the Copilot phase, or merges where a Copilot signoff already stands;
- **Copilot is clean**: merge if the phase produced no commits; otherwise run the
  fault-tolerance pass and merge on its signoff, with no third Copilot phase over
  the pass's own fixes.

It answers decisions, never readings: a review that is only replies, a limitation
it cannot test, an unavailable reviewer and every failed or unreadable gate still
stop, and a session stopped there resumes from the records exactly as an attended
one does. An unattended wait needs the `Monitor` permission above.

### The merge gate

On your word, the session resolves the head once and evaluates every gate before
merging pinned to that head: each reviewer's verdict on the head that reviewer
judged, the reviewed range (every commit past the Codex signoff must be a Copilot
fix carrying a `Review-Phase: copilot` trailer), all checks and the base branch's
required checks on the merge target, no unresolved threads, and the round
boundary. A head that moved mid-gate is refused, not merged.

The merge uses `--admin` by default, a trade accepted for one case: a branch
that requires an approval no eligible account can provide, where neither
reviewer counts and dropping the flag removes the merge path rather than
tightening it. The trade-off is recorded in
[`docs/decisions/2026-08-06-merge-admin-default.md`](docs/decisions/2026-08-06-merge-admin-default.md).
Everywhere else set `REVIEW_MERGE_STRICT=1`: where the branch's rules are ones
the loop can satisfy, and always where the branch uses a merge queue, which the
default bypasses. GitHub then evaluates reviews, checks and conversations
itself, at merge time. With required checks, conversation resolution, zero
required approvals where no eligible approver exists, and bypass disallowed,
that evaluation is atomic. If GitHub refuses, the merge does not happen and you
decide.

## Configuration

**Export** these in the shell you start the session from. The helpers run as
separate processes, and a value merely assigned in your shell never reaches them.

| Variable | Default | Meaning |
| --- | --- | --- |
| `REVIEW_ROUND_THRESHOLD` | `10` | reviewed heads per reviewer between check-ins; `0` disables the pause |
| `REVIEW_MERGE_STRICT` | unset | `1` drops `--admin`, so GitHub enforces branch protection itself |
| `WATCH_PR_AUTONOMOUS` | unset | `1` takes the answers under *Running unattended* at the decision stops; every failure still stops |
| `PR_CI_INTERVAL` | `30` | seconds between polls while the pushed head's checks run |
| `PR_CI_TIMEOUT` | `1800` | how long to wait for those checks before stopping rather than guessing |
| `PR_CI_GRACE` | `90` | how long a round-closing answer, green or no checks configured, must hold before it is believed, since a workflow registers a moment after the push |
| `PR_CI_PROBE_TIMEOUT` | `60` | bound on each `gh` call the check probe makes |
| `PR_WATCH_INTERVAL` | `30` | seconds between polls while waiting for a verdict |
| `PR_WATCH_TIMEOUT` | `3600` | how long to wait for a verdict before reporting a timeout |
| `PR_WATCH_PROBE_TIMEOUT` | `60` | budget for each read the watch makes of the review state, one helper run of several `gh` calls; a read that stalls past it is retried afresh rather than run to the watch's timeout |
| `RB_SUITE_JOBS` | `4` | how many test files the pre-push self-check runs at once (contributors) |
| `REVIEW_BUS_REMOTE`, `REVIEW_BUS_OWNER`, `REVIEW_BUS_REPO` | derived from `origin` | override the repository identity (tests) |

There are no reviewer knobs: model, effort, exhaustiveness, automatic review and
credit use are Codex account and repository settings.

## Troubleshooting

- **`@codex` answers with a setup link.** The connector is not linked for this
  account. Link it; that reply is the diagnostic, not an empty review.
- **No review arrives.** Check `gh auth status`, that the mention is on the pull
  request rather than an issue, and that the repository is enabled on the Codex
  Code review settings page.
- **The review stops with a usage message.** The account hit its rate limit.
  Wait for the reset or turn on credit use in the Codex settings.
- **`--add-reviewer @copilot` fails.** Copilot review is not available to the
  repository. The session stops rather than skipping the pass; decide.
- **The session stops on a review with no findings listed.** The review was only
  replies. Read it and answer, as described under the stops.
- **A round stops with "the head you just pushed is RED".** Working as intended:
  the suite passing locally and the checks passing on the runner are different
  claims. Fix it and push again.
- **A round waits on pending checks.** It waits for them rather than reading
  "still running" as a pass. Raise `PR_CI_TIMEOUT` if your CI takes longer than
  thirty minutes, and export it.
- **`ABORT: could not set this session up`.** The `PR_SETUP status=error
  reason=…` line above it says why: the working directory could not be created,
  the checkout has no usable `origin`, or the storage refused. If the storage
  refused, point `TMPDIR` at a filesystem with room; there is no retry under
  another parent. No such line at all means the helper never got to report: an
  interrupted run, or an installation missing `pr-setup.sh`. `pr-setup.sh`
  removes nothing it created, deliberately; the origin helper gives back only its
  own empty transport directory when it refuses before writing.
- **Setup says the pinned remote is not this checkout's origin.** The origin is
  read twice, once to obtain it and once to confirm it, and the two disagreed:
  `origin` or the git configuration resolving it changed mid-setup. Re-run.
- **Reviews go to the wrong repository.** The session is pinned to the `origin`
  of the checkout it started in. Start a new session in the intended checkout.
- **A stale review after a push.** The merge gate refuses a moved head. Post a
  fresh round summary and re-request.
- **"merge queued: the PR is OPEN, not MERGED".** The base branch uses a merge
  queue and `gh` reports success for joining it. Watch the PR until it merges.
  This happens under `REVIEW_MERGE_STRICT=1`; the default merge bypasses the
  queue.

## Contributing

`skills/watch-prs/SKILL.md` is the driver contract, `skills/watch-prs/scripts/`
holds the helpers, the shared libraries and one `test-<area>.sh` per file, and
`CLAUDE.md` holds the authoring rules. Run the pre-push self-check before every
push:

```
skills/watch-prs/scripts/pr-selfcheck.sh
```

It proves every variable the driver uses is assigned, every script parses and
has a test, no fixture races a `printf` into `grep`, and the whole suite passes.
CI runs the suite on Ubuntu with bash 5 and again on bash 3.2.57 with a
mac-shaped `PATH`, so a construct newer than 3.2 or a GNU-only tool on a path the
suite executes fails there before it reaches a macOS contributor. A path the
suite never takes, a GNU-only flag on a command both platforms have, and `\s` in
a `grep` pattern are review's job.

Every behaviour change ships its test in the same PR, proved to fail against the
unfixed code; every change to an installed file bumps the version and adds a
changelog entry, explaining the failure it fixes or, for a comment-only change,
what the comment now records. One issue per PR.

## License

GPL-2.0 — see [LICENSE](LICENSE).
