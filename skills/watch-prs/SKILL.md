---
name: watch-prs
description: Use when driving a pull request through review to merge. Requests reviews from the native GitHub reviewers (Codex via an @codex mention, Copilot via a review request), reads their findings, works the fix → reply → resolve → re-request loop, and gates the merge on a clean signoff from the current head. No daemons, no local reviewer process.
---

# /watch-prs — native PR review loop

Both reviewers are first-party GitHub apps; nothing runs locally. You drive the loop with
the helper scripts, one invocation per step. Every status is branched on, an `ABORT:` ends
the session, and every "cannot tell" is a stop rather than "no findings". The driving shell
is trusted (`docs/decisions/2026-09-05-driving-shell-trusted.md`): the helpers are what
prove, mutate and gate, each started as `/usr/bin/env bash -p "$RB_SCRIPTS"/<helper>`
except `pr-selfcheck.sh`, which re-execs into a clean shell itself and is run directly.

| Reviewer | Login | Trigger |
| --- | --- | --- |
| Codex | `chatgpt-codex-connector[bot]` | a comment containing `@codex review`, or automatically on push if the repo has auto-review on |
| Copilot | `copilot-pull-request-reviewer[bot]` | `gh pr edit <PR> --add-reviewer @copilot` |

**Once per account** the Codex GitHub connector must be linked at
`chatgpt.com/codex/cloud/settings/connectors`. Until it is, `@codex` replies *"To use
Codex here, create a Codex account and connect to github"* — that reply is the
diagnostic, not a review. Per-repository behaviour (auto-review, trigger condition,
exhaustive review, credit use) is set on the Codex **Code review** settings page.

**The loop:** setup → 1 state the task → 2 request Codex → 3 wait → 4 read the findings →
5 fix and close the round, with the check-in of 6 inside it → back to 3 until Codex is
clean → 7 STOP, and on the operator's word the Copilot phase, which is 3–6 again with
`$WHO` switched → 8 STOP, and on the operator's word the merge gate.

With `WATCH_PR_AUTONOMOUS=1` exported the operator has made the decision stops in advance:
each carries an **Unattended:** line naming its answer, taken without asking and recorded
on the PR as the operator's word would be. A stop that exists because something could not
be read, proved or told apart has no such line and is never answered by it. Setup says
which mode this session runs in, as `mode=unattended` or `mode=attended` on its record.

## How to work this loop

These rules bind every round.

**Fix what the finding names. Nothing else.** A round is about that round's findings;
refactoring, tidying, hardening or renaming nearby enlarges the diff the next review reads,
and unrelated improvements arrive as their own PR or an issue. "What the finding names" is
the DEFECT, not the line: the same defect in a copy this PR already changes is the same
finding, and fixing fewer of those is leaving it open. A scope the finding states governs
for the copies this PR already changes; a different pre-existing defect, or a same-shape one
outside this PR's diff, is answered on the thread and filed, with the number in the summary.
A regression the fix itself introduces is this round's work wherever the file sits.

**Do not build more than the finding requires.** The smallest change that makes the
finding false is the correct change. A general fix that is genuinely justified is an issue
raised with the operator outside the review request — never built silently, and never
proposed in the summary, which rides with the `@codex review` mention.

**Prefer removing the dependency over guarding it.** A check can be mis-parsed, locked or
forgotten; a shape in which the failure cannot arise stays fixed. Take the removal whenever
it is not larger, and say on the thread which of the two you took and why.

**Every change you make must be reviewable as a fix.** An unrelated change bundled into a
review-fix commit is one the reviewer has no reason to look for.

**Validate a finding before you act on it.** Reproduce the claim against the current code.
If it does not hold, say so on the thread with the evidence. If it holds but the suggested
remedy is wrong, fix the defect the right way and explain the difference.

**Prove a fix can fail.** Revert the fix, confirm the test fails *for the reason it names*,
restore it. Not waivable by disclosure. Where no mutation can be constructed — tried, not
assumed — write the limitation as a comment **at the site** and **stop for the operator**:
acceptance is a dated record under `docs/decisions/`, landed on the **base ref by its own
pull request**.

**Say what you did not do — as a disposition, never as a description.** Silence reads as
"addressed". Past tense and a bare issue number — "one finding was answered on its thread
rather than applied", "one is deferred to #11" — never the defect, its file, its consequence
or what closing it would take.

## Setup

Once per session, from the checkout, on the PR's branch:

```bash
RB_SCRIPTS="${CLAUDE_PLUGIN_ROOT:-}/skills/watch-prs/scripts"
[ -x "$RB_SCRIPTS/pr-setup.sh" ] || RB_SCRIPTS="$(ls -dt "$HOME"/.claude/plugins/cache/*/watch-pr-skill/*/skills/watch-prs/scripts 2>/dev/null | head -1)"
[ -x "$RB_SCRIPTS/pr-setup.sh" ] || { echo "ABORT: the plugin helper scripts were not found"; exit 1; }
RB_SETUP_DIR="${TMPDIR:-$HOME}/watch-pr-setup.$$.$RANDOM$RANDOM"
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-setup.sh "$RB_SETUP_DIR" \
    || { [ $? -eq 2 ] && RB_SETUP_DIR="$HOME/watch-pr-setup-2.$$.$RANDOM$RANDOM" && /usr/bin/env bash -p "$RB_SCRIPTS"/pr-setup.sh "$RB_SETUP_DIR"; } \
    || { echo "ABORT: setup failed; the PR_SETUP line above says why"; exit 1; }
export REVIEW_BUS_REMOTE="$(<"$RB_SETUP_DIR/origin")"
. "$RB_SCRIPTS/identitylib.sh" || { echo "ABORT: the identity parser could not be loaded"; exit 1; }
[ -n "$REVIEW_BUS_REMOTE" ] && rb_identity || { echo "ABORT: the origin read back is not a usable identity"; exit 1; }
REPO_DIR="$(git rev-parse --show-toplevel)" || { echo "ABORT: not in a git checkout"; exit 1; }
CODEX_BOT='chatgpt-codex-connector[bot]'; COPILOT_BOT='copilot-pull-request-reviewer[bot]'
SUMMARY_FILE="$RB_SETUP_DIR/work/summary.md"; REQUEST_FILE="$RB_SETUP_DIR/work/request.md"
PRIOR_FILE="$RB_SETUP_DIR/work/prior.txt"; HEAD_FILE="$RB_SETUP_DIR/work/head.txt"
```

`pr-setup.sh` reads the origin through `pr-origin.sh`, refuses one that is not a GitHub
network transport, writes it into `$RB_SETUP_DIR/origin` as data, and creates the four
empty working files under `$RB_SETUP_DIR/work`; its record ends `mode=unattended` or
`mode=attended`. The driver reads the origin back, exports it as `REVIEW_BUS_REMOTE` — the
pin every helper routes by whatever the current directory is — and proves it a GitHub
identity through the parser the helpers use, which sets `HOST`, `OWNER` and `REPO`.
Status 2 means the storage refused the directory, and the one retry under `$HOME` is the
bound `docs/decisions/2026-08-26-transport-candidate-in-argv.md` accepts a squat at; 1 is
terminal. Nothing under `$RB_SETUP_DIR` is ever removed.

## 1. State the task on the PR

The reviewers judge relevance against what the PR says it set out to do. Before the first
request, the PR description states what the change does and what it deliberately does not.
Every later round adds a round-summary comment: what was addressed, and what was skipped
as a past-tense disposition with a bare issue number. Neither can waive a finding.

## 2. Request the review — Codex first

The loop is phased: Codex reviews to a clean signoff, and only then is Copilot asked.

`AUTO_REVIEW` is set once per PR and used by every later step. It is a Codex account
setting `gh` cannot probe, so ask the operator: with automatic review on, opening or
pushing the PR has already queued a pass and a mention queues a second over the same head;
with it off, the mention is the only trigger.

Write the account into `$REQUEST_FILE` with your file tool — never into `$SUMMARY_FILE`:
one paragraph on what the change does and what to look at. It is posted as data.

**Refused rather than posted**, in every body this loop writes — the request, the round
summary and the phase account: a line starting with a reserved marker,
`**Review-Signoff:**`, `**Review-Signoff-Revoked:**` or `**Review-Pause-Acknowledged:**`
(indent it four spaces or quote it inline; a fence does not help, the readers scan the raw
body); an empty body; and `@codex review` anywhere in the body, case-insensitively — in the
opening request where automatic review is on, since a pass is already queued, and in a
Copilot-round summary or the phase account whatever the mode, since it would start a Codex
pass nobody asked for. Write the mention without the `@`, or broken up.

The nonce is generated fresh before every request and handed to both the writer and the
watch, so a baseline left by an earlier round is refused rather than waited past.

```bash
AUTO_REVIEW=no   # or `yes`, per the repo's Codex Code review settings
WHO="$CODEX_BOT"
RB_NONCE="$(perl -e 'printf "%010d%07d%06d", time, $$ % 10000000, int(rand 1e6)')"
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-request-review.sh N "$AUTO_REVIEW" --baseline-file "$PRIOR_FILE" --nonce "$RB_NONCE" < "$REQUEST_FILE"
```

0: posted, `$PRIOR_FILE` holds the baseline for the watch — the newest verdict's id on the
manual path, `none` on the automatic one, where the trigger preceded us — and the wait step
is next. Anything else: nothing was posted, the reason is above; stop, and do not enter the
wait step.

## 3. Wait for the verdict

`$WHO` is the active reviewer — set in step 2, switched in step 7 — and `$PRIOR_FILE` and
`$RB_NONCE` are what the step that made the request left. Do not poll by hand.

```bash
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-watch.sh N "$WHO" --after-review-file "$PRIOR_FILE" --require-nonce "$RB_NONCE"
```

**Claude Code** — run it as this session's **Monitor**, so the verdict surfaces into the
chat by itself: `command` as above, `description` `Review verdict for PR N`, `timeout_ms`
`3600000`, `persistent` `true`. **Arm it as part of the round, and re-arm it the same way —
do not ask.** One arming covers one verdict. A harness that prompts anyway is a permissions
gap, which `README.md § Watching without prompts` answers.

| status | meaning | what to do |
| --- | --- | --- |
| `0` | terminal state reached, verdict on the last line | step 4 |
| `1` | timed out — the review is still in flight | **re-arm the same watch.** Do not re-request: that queues a duplicate pass on the same head. Do not ask. |
| `2` | the state could not be read | **fail closed** — never "no findings" |
| `4` | the review carried comments and **every one was a reply** | **STOP. Do not go to step 4.** Nothing to list and not a signoff. Put the comment to the operator. |

States: `none` no review on this head · `pending` a draft is open · `reviewed` a
submitted APPROVED/COMMENTED review · `blocked` CHANGES_REQUESTED — findings, plus its
body in step 4 · `dismissed` the signoff was withdrawn — request again.
`probe_stalled` is not a state of the review: a read stalled past `PR_WATCH_PROBE_TIMEOUT`
and the watch has already killed and retried it. Nothing to do, and no re-request.

**On `4` the operator's answer must become state**, or the stop is a deadlock: the watch
returns 4 for as long as that review is the newest, there is no thread to resolve, and
re-requesting is forbidden.

- **It was a clean verdict** — record the signoff, the same `**Review-Signoff:**` line
  step 7 writes: reviewer and head in backticks, and the verdict's time as a third field
  whenever you have it, since that is what a later revocation is ordered against. Record
  it AFTER reading: it must be newer than the later of that review and its newest reply,
  or the merge gate and `pr-phase-state.sh` refuse it, naming both times.
- **It was a finding** — fix it and push. The head moves and the round is ordinary again.

Absence is not permission: with no signoff recorded, the gate refuses and names what to do.

## 4. Read the findings

Inline review comments are the findings. The review body is the non-blocking channel and
does not gate the merge, with one exception below.

```bash
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-findings.sh list N
```

0: the printed threads are the complete set of unresolved findings, each with its full body
under its `thread=`/`comment=` line. 2: the read could not be trusted — stop; do not reply,
resolve or summarise.

When the state is `blocked`, read the review body too: a `CHANGES_REQUESTED` review can
carry its whole argument there with no inline comment, and the merge gate then refuses
while `list` shows nothing to fix. The same contract: 2 is a stop, and empty output from a
failed read is "could not read", not "no body".

```bash
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-findings.sh blocked-body N "$WHO"
```

### Read each finding whole, not just its title

`list` prints one line per thread so the set is countable. **That line is not the
finding.** The argument is in the body printed under it; read it there and nowhere else,
since `pulls/N/comments` returns every comment the PR ever had. Three things in a body
change what you do: a **code suggestion** is a proposal written without your context —
where you disagree, implement the correct fix and say on the thread why; a **stated
consequence** — "…so the merge proceeds with no trusted checks result" — is what the test
asserts; a **scope hint** — "apply the same rule in the other parsers" — is part of the
finding, for the copies this PR changes. Reply to each thread with what changed and why,
not "fixed".

## 5. Fix, then close the round

Fix the findings; where you disagree, say so on the thread rather than resolving it
silently. Then, in this order:

1. **commit** — `fix(review): <what changed>`. In the Copilot phase add a
   `Review-Phase: copilot` trailer: it tells the merge gate the head advanced only through
   Copilot fixes, so Codex's signoff still covers it. `git` reads trailers from the LAST
   paragraph only, so it goes in the same block as `Co-Authored-By:` with no blank line
   above it:

   ```
   fix(x): what changed

   Why it changed.

   Review-Phase: copilot
   Co-Authored-By: …
   ```

   A blank line above it makes it invisible to the gate, which reports `untagged_commit`;
   `pr-merge-range.sh` names that case `trailer_not_in_trailer_block`;
2. **run the self-check — 5a — and fix what it finds**, before anything leaves the machine;
3. **check the round boundary — step 6.** Both precede the push: with automatic review on
   the push itself requests the next review, so a check after it stops nothing. **The push
   is not here** — `gate` pushes, because the checks on what it pushes decide whether the
   round may close at all;
4. **run `gate`**, and only then reply to each thread with what changed, react to it,
   resolve it, and read the `isResolved` the resolve returns. A resolve cannot be taken
   back, so it follows the pushed, green head;
5. **run `post`** — it re-proves that head, posts the summary and re-requests `$WHO`. The
   irreversible parts of a round come last.

### 5a. Self-check before the push

A finding a script can make in a second must not cost a review pass.

```bash
"$RB_SCRIPTS"/pr-selfcheck.sh
```

0: the mechanical checks pass. 1: findings — fix them now. 2: the check could not run —
fail closed. 3: **not applicable** — this repository is not a `watch-pr-skill` checkout,
so nothing was in scope; normal in every other project, and a separate status from `0` on
purpose: say so in the summary rather than claiming a clean check.

Then read your own diff against the classes that produced the rounds: did I fix the
instance or the class, within this diff; did I widen a validator or a contract without
rechecking what consumes it; did I trace every identifier and ordering I touched; can each
new assertion fail for the reason it names; did I answer the finding, or just silence it.
Write what this pass changed into the round summary; if it found nothing, say so.

### The two stages, and what triggers the review

The reviewer reads the newest round summary before the diff, so the summary has to exist
before the pass starts — and what starts it differs. With automatic review OFF the mention
is the trigger and the push is inert. With it ON the push starts the pass, so the order is
decided by what is irreversible: push, prove the checks, close afterwards; that pass reads
open threads and no summary, and the explicit request `post` makes supersedes it. A wasted
pass is recoverable; a round closed on a red head is not. `pr-close-round.sh` takes
`$AUTO_REVIEW` and holds both orders.

```bash
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-close-round.sh gate N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW" "$HEAD_FILE" "$PRIOR_FILE"
```

0: pushed, the head proved green and written into `$HEAD_FILE`. **Now answer the threads:**

```bash
gh api --hostname "$HOST" --silent -X POST "repos/$OWNER/$REPO/pulls/N/comments/<comment-id>/replies" -f body='<what changed and why>' || { echo "ABORT: the reply was not posted; do not resolve this thread and do not post the round"; exit 1; }
gh api --hostname "$HOST" --silent -X POST "repos/$OWNER/$REPO/pulls/comments/<comment-id>/reactions" -f content='+1' || echo "note: the reaction failed"
[ "$(gh api --hostname "$HOST" graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -F id='<thread-id>' --jq '.data.resolveReviewThread.thread.isResolved')" = true ] || { echo "ABORT: the thread was not resolved; do not post the round"; exit 1; }
```

`list` prints `comment=<id>` beside `thread=<id>` for these: the comment id replies and
reacts over REST, the thread id resolves over GraphQL. 👍 acted on, or correct and recorded
as accepted; 👎 only when wrong on the facts. A failed reply is a stop, and so is a resolve
that errors or answers anything but `true`: a round posted over an unanswered or unresolved
finding requests a pass over a thread the reviewer will raise again. Only the reaction is a
note.

3: the operator decides at a round boundary (step 6); the round did not close. Anything
else: the round did not close and nothing has been resolved or posted; the reason is above,
do not retry it blind. Then, and only then:

```bash
RB_NONCE="$(perl -e 'printf "%010d%07d%06d", time, $$ % 10000000, int(rand 1e6)')"
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-close-round.sh post N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW" "$HEAD_FILE" "$PRIOR_FILE" "$RB_NONCE"
```

0: closed on the head it prints, and the wait step is next. 3: the pass left only replies,
so there is nothing to fix and no signoff — read it with the operator, as on `4` above.
Anything else: the threads are answered but no summary was posted and no pass was
requested; the reason is above, do not retry it blind.

In the Copilot phase the request is `gh pr edit --add-reviewer @copilot`, which no push
triggers, so the summary goes first. Re-request **only the active reviewer**.

### Write the summary as a record, never as a work order

State only what was done, in the past tense. A `@codex` mention whose body describes an
unfixed defect — its file, its consequence, what it would take to close — is read as a
task: Codex then edits and commits in an environment with no remote, the commit exists
nowhere, the review never happens and the round is spent. That happened here once.
Anything still open is a GitHub issue, linked by number and nothing more. A resolved
thread is not a record of a fix — the summary is.

## 6. Round check-in

Runs inside step 5, before the request-triggering command; steps 7 and 8 check the same
boundary. The count is per reviewer: a round is a distinct PR head that received a submitted
review, derived from GitHub each time, so it survives a new session.

```bash
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-round-count.sh N "$WHO"
```

0: carry on. 2: the count could not be established — fail closed; do not re-request as if
it were round one. 3: **stop and decide with the operator.** Say what the rounds have been
about, not only how many, and put all four options: **continue**; **merge now**; **leave it
open** — the signoffs are on the PR and a later session resumes from them; **close it and
start over with a better approach** — ten rounds is evidence about the approach, and this is
the option a loop never proposes for itself. When the operator says continue, record it on
the PR before requesting the next review, with the reviewer and the count the counter's
`PR_ROUND_PAUSE` line reports, or every later call pauses on the same count:

```bash
gh pr comment N --repo "$HOST/$OWNER/$REPO" --body "$(printf 'Continuing after the round check-in.\n\n**Review-Pause-Acknowledged:** `%s` `%s`\n' "$WHO" '<rounds>')" || { echo "ABORT: the acknowledgement was not recorded; do not request a review or run the paused stage again"; exit 1; }
```

Only OWNER, MEMBER and COLLABORATOR comments are read as acknowledgements, and one naming
a round that has not happened yet is refused. `REVIEW_ROUND_THRESHOLD=0` disables the
check-in entirely.

**Unattended:** continue — where the 3 is this boundary, which the stage's output says
with a `PR_ROUND_PAUSE` line. `gate`'s `PAUSE: the pass the push started left only replies`
is step 3's status 4 by another route, carries no such line, and stays a stop. Wherever a
stage reports the boundary — this counter, `gate`, `record`, `open` or the merge gate — it
belongs to the reviewer that stage counted: `$WHO` at the counter and `gate`, Codex at
`record` and `open`, Copilot at the merge gate; the template line the counter prints names
it. Record the acknowledgement above with that login in place of `$WHO`, say in the round
summary what the rounds have been about, and run the stage again — except `record`, which
pauses after its signoff is written: go on to step 7's answer, since
running it twice records two signoffs. The count stays on the PR, where
`REVIEW_ROUND_THRESHOLD=0` would leave no record that the loop ran long.

## 7. Codex is clean — now the Copilot phase

A clean verdict counts every comment on the newest review, replies included: a retraction
is a paragraph after the verdict line, so no reading of the text separates them.
`source=replies-only` is neither answer — nothing to fix, and not a signoff; stop and put it
to the operator, and neither re-request nor treat it as clean.

Write one paragraph into `$SUMMARY_FILE` with your file tool — what the PR does and what
the Codex phase changed; say so if Codex approved on the first pass — under the body rules
of step 2. `record` proves Codex clean on an exact head, proves that head's checks,
re-proves both immediately before writing, orders any revocation against the verdict, and
writes the Codex signoff onto the PR; `$CODEX_SHA` is read back from `$HEAD_FILE` and is
the only record of what Codex approved.

```bash
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-copilot-phase.sh record N "$SUMMARY_FILE" "$HEAD_FILE"
```

0: recorded. 3: recorded, then paused at a round boundary — the operator decides, and
merging on that signoff is one of the answers. Anything else: the phase did not advance and
no signoff was recorded; the reason is above, do not retry it blind, and do not read the
head. On 0 or 3, and only then, read the head it signed:

```bash
CODEX_SHA="$(<"$HEAD_FILE")"
```

**STOP — the next phase is the operator's decision.** The signoff is on the PR, so either
answer is resumable; `pr-signoff.sh` reads it back in a later session.

- **merge now** — one reviewer's clean signoff is a legitimate place to stop, and for a
  small or urgent change often the right one. Run step 8 with `REVIEWERS=codex-only`,
  which requires the head to BE `$CODEX_SHA`: a narrower gate, not a looser one;
- **open the Copilot phase** — a second, differently-trained reviewer over the same head.
  It costs rounds, and it finds things Codex does not.

**Unattended:** merge now where Codex's first verdict on this PR was clean — the opening
request's watch reported `verdict=clean findings=0` — and open the Copilot phase
otherwise: a change Codex sent back gets the second reviewer, even where the answer on
its thread left the head unchanged, and a change it passed is merged on that signoff.
That is the answer of the session that saw the opening verdict: a session resumed at this
stop opens the Copilot phase, since a second review costs rounds and a merge on one
signoff is not taken on evidence this session has not got. Where instead a Copilot
signoff already stands — `pr-signoff.sh`, asked as in the resume recipe but for
`$COPILOT_BOT`, reports one — the Copilot phase has happened and the signoff just recorded
is the fault-tolerance pass's, whatever the opening verdict was: run the counter of step 6
for `$CODEX_BOT` first and acknowledge a 3 as there, since the merge gate counts Copilot's
boundary alone, then merge now, `codex-only` where the head is past the Copilot signoff
and `both` where it is that head; open nothing.

Ask, then stop, unless unattended. Only on the second answer:

```bash
RB_NONCE="$(perl -e 'printf "%010d%07d%06d", time, $$ % 10000000, int(rand 1e6)')"
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-copilot-phase.sh open N "$CODEX_SHA" "$PRIOR_FILE" "$RB_NONCE" && WHO="$COPILOT_BOT"
```

0: the phase is open, Copilot is requested, and `$WHO` is Copilot. 3: paused at a round
boundary — not permission to skip the pass; decide with the operator. Anything else: the
phase did not open — not permission to skip the pass either.

Then run steps 3–6 again with `$WHO` set to Copilot until its verdict is clean, every fix
commit carrying `Review-Phase: copilot`. **Codex is not re-requested during this phase**:
the merge gate proves the head advanced only through Copilot fixes, and a commit without the
trailer fails the range check. `gh pr edit --add-reviewer` failing because Copilot is
unavailable to the repository is not permission to skip the pass: report it and decide with
the operator.

## 8. Merge gate

Run every check immediately before merging — an earlier check answered about an earlier
head.

### First: record the Copilot signoff, then STOP and ask

A clean Copilot verdict is the end of the review work, not the start of a merge. `close`
records it and prints a menu; it is given `$CODEX_SHA` because whether the two shas are
equal decides which menu: equal means Codex reviewed exactly what is being merged and no
fault-tolerance pass is offered; different means the Codex signoff is carried forward only
if the gate proves every commit between them is a `Review-Phase: copilot` fix.

```bash
REVIEWERS=both   # or `codex-only`
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-copilot-phase.sh close N "$CODEX_SHA" "$REVIEWERS"
```

0: `PR_COPILOT_PHASE_CLOSED pr=N reviewer=<copilot> copilot-sha=<sha> codex-sha=<sha>`
and the menu. Anything else: the phase did not close and no signoff was recorded; the
reason is above, do not retry it blind.

**On the two-reviewer path, STOP. MERGING IS THE OPERATOR'S DECISION.** The stage prints
a menu and asks; do not run the merge gate until the operator has answered.

**Unattended:** on the first menu, merge, with `REVIEWERS=both`. On the second, the
fault-tolerance pass: post the revocation the menu describes, write the account of the
Copilot-phase commits into `$REQUEST_FILE`, and run steps 2–6 — step 2's block sets
`$WHO` to `$CODEX_BOT` again, and this one request is made with the auto-review argument
`no` whatever `$AUTO_REVIEW` is, since no push precedes it: the mention is its only trigger
and the baseline must be the verdict before the revocation — until Codex is clean; then
`record` from step 7 once more, with a body saying what the pass changed, which writes the
replacement signoff and reads back the new `$CODEX_SHA`. Merge with `REVIEWERS=codex-only`
where the pass moved the head and `both` where it did not: Copilot's verdict is on the head
the pass started from, and a third phase over the pass's own fixes would restart the cycle.
The pass runs once.

**In `codex-only` there is no second question.** No Copilot review was requested, so the
stage records nothing and prints no menu, and the decision was taken at the Codex stop. Go
straight to the merge gate.

### Resuming after a stop

A later session has none of the variables the stop was reached with. Run this before step
8, or before continuing into the Copilot phase. `pr-phase-state.sh` reads the phase off the
PR's own records and re-validates the one that has to stand: 0 readable and standing; 1
stopped — no signoff, a moved head, or a verdict that no longer stands, and its record says
which; 2 unreadable, which is not "no signoff". Only on 0 is the signoff read back, and it
must read back as a 40-hex sha.

```bash
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-phase-state.sh N && CODEX_SHA="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-signoff.sh sha N "$CODEX_BOT")"
```

### Then: the gate

`pr-merge-gate.sh` evaluates every gate immediately before the merge and pins the merge to
one head: 0 merged, and the head it names is on the base branch; 1 blocked, with the reason
on stdout; 3 paused at a round boundary, which is not a refusal; 4 queued — a merge queue
took the request without landing it, and `gh` calls that success, so do not close this out
before confirming on the PR. `$CODEX_SHA` is the full 40-hex head Codex signed off on; in
the Copilot phase the head moves past it and Codex is deliberately not re-run, so that is
what Codex's verdict is checked against. `$REVIEWERS` is `both` unless the operator chose
otherwise at the Codex stop.

```bash
(cd "$REPO_DIR" && /usr/bin/env bash -p "$RB_SCRIPTS"/pr-merge-gate.sh N "$CODEX_SHA" "$AUTO_REVIEW" "$REVIEWERS")
```

If any gate fails, do **not** merge: post the reason on the PR and hand it back to the
operator.

**Unattended:** 3 is the check-in of step 6, answered there and the gate run again; 1 and 4
are handed back as above.

## What this skill deliberately does not do

- **It does not run a reviewer.** Codex and Copilot are GitHub apps; a local process
  reviewing PRs duplicates them, authors its comments as the repository owner, and spends
  a separate credit pool.
- **It does not merge unattended past a failed or unreadable gate.** Every "cannot tell"
  is a stop, and `WATCH_PR_AUTONOMOUS=1` answers none of them.
