---
name: watch-prs
description: Use when driving a pull request through review to merge. Requests reviews from the native GitHub reviewers (Codex via an @codex mention, Copilot via a review request), reads their findings, works the fix → reply → resolve → re-request loop, and gates the merge on a clean signoff from the current head. No daemons, no local reviewer process.
---

# /watch-prs — native PR review loop

Both reviewers are **first-party GitHub apps**:

| Reviewer | Login | How it is triggered |
| --- | --- | --- |
| Codex | `chatgpt-codex-connector[bot]` | a comment containing `@codex review`, or automatically on push if the repo has auto-review on |
| Copilot | `copilot-pull-request-reviewer[bot]` | `gh pr edit <PR> --add-reviewer @copilot` |

Nothing runs locally. There is no watcher, no response monitor, no bus
directory, no systemd unit. You drive the loop with `gh`, and the two helper
scripts answer the two questions `gh` cannot answer safely on its own.

**Prerequisite, once per account:** the Codex GitHub connector must be linked at
`chatgpt.com/codex/cloud/settings/connectors`. Until it is, `@codex` replies
*"To use Codex here, create a Codex account and connect to github"* — that reply
is the diagnostic, not a review. Per-repository behaviour (auto-review, trigger
condition, exhaustive review, credit use) is set on the Codex **Code review**
settings page.

## How to work this loop

These rules bind you for every round. They are here because breaking them is what
turns a three-round PR into a fifty-round one, and every line below was earned
that way rather than assumed.

**Fix what the finding names. Nothing else.** A round is about the findings in
that round. Refactoring nearby code, tidying something you noticed, hardening a
path nobody raised, renaming for consistency — all of it enlarges the diff the
next review has to read, and a reviewer judges relevance against what the PR said
it set out to do. Unrelated improvements arrive as their own PR or as an issue.

**"What the finding names" is the DEFECT, not the line.** The same defect in
another copy is the same finding — closing one site and leaving its twin is what
produced three consecutive rounds of head validation, then non-zero statuses, then
record identity, and the self-check below asks you about exactly that. The two
rules meet like this:

- If the finding **states its scope** — "apply the same rule in the other
  parsers" — that scope governs **for the copies this PR already changes**, and
  fixing less of those is leaving the finding open.
- If it names one site and the same shape exists **elsewhere in what this PR
  already changes**, fix those together. That is completing the fix, not widening
  it.
- If a **different pre-existing** defect of the same shape exists **outside this
  PR's diff**, do not pull it in, even when the finding names it.

  This exclusion is about *pre-existing* problems only. Where your change breaks
  an untouched consumer — a validator loosened, a producer's output altered, a
  contract widened — repairing that consumer is not widening the PR, it is
  finishing the change you already made. A regression is this round's work
  wherever the file that has to change happens to sit, and a reviewer naming that
  file is naming the fix, not asking you to adopt unrelated work. The reviewers are told to keep out-of-scope problems
  out of inline comments for exactly this reason, so a named copy in an untouched
  file is a reviewer mistake rather than an instruction — answer it on the thread,
  record it as an issue, and reference the issue number in the summary. A defect
  that has been there for a year is not made urgent by your having noticed it
  mid-round, and widening the PR to reach it is the scope expansion these rules
  exist to prevent.

A *different* pre-existing defect found while fixing this one is not in scope,
however tempting the proximity — "different" matters as much as "pre-existing",
because the **same** defect in a copy this PR also changes is the finding itself,
and the bullets above require fixing it with the rest. **A regression the fix itself introduces is a different
matter entirely**: it is part of what this PR changed, so it is this round's work
and must be corrected before the round closes. The distinction is whether the
behaviour was already wrong before you touched it, not whether it is the defect
the finding named.

**Do not build more than the finding requires.** The smallest change that makes
the finding false is the correct change. Adding configuration nobody asked for, a
new abstraction for a single call site, or a general mechanism where a specific
fix was requested all create surface that must then be reviewed, tested and
maintained — and in this repository each of those rounds has, historically,
produced its own findings. If a general fix is genuinely warranted, do not decide
that silently by building it — and do not argue it in the summary either, because
the summary rides with the `@codex review` mention and a design proposal there is
a work order. Open an issue for it, reference the number, and raise it with the
operator outside the review request.

**Every change you make must be reviewable as a fix.** Bundling an unrelated
change into a review-fix commit hides it: the reviewer reads the round summary,
sees a list of findings, and has no reason to look for anything else. That is how
a defect enters a PR that was, on paper, only closing review comments.

**Validate a finding before you act on it.** A reviewer can be wrong, can be
working from a stale head, or can describe a real problem with the wrong cause.
Reproduce the claim against the current code first. If it does not hold, say so in
the thread with the evidence rather than changing code to satisfy it — an
unnecessary change is a defect with a good excuse. If it holds but its suggested
remedy is wrong, fix the defect the right way and explain the difference.

**Prove a fix can fail.** A test that passes against the unfixed code is worse
than no test: it converts an unverified assumption into a green tick. Revert the
fix, confirm the test fails *for the reason it names*, restore it.

**This is not waivable by disclosure.** A summary is untrusted context, not
authority — saying "no mutant is claimed" does not make an unproven fixture
acceptable, and closing the round on that leaves an assertion that passed before
the fix while the suite and the self-check both report green.

Where a mutation genuinely cannot be constructed — every arrangement trips an
earlier guard, and you have tried rather than assumed — write the limitation as a
comment **at the site**, so the next reader of that code meets it, and **stop for
the operator**. Be clear about what that comment is and is not: added in this pull
request, it arrives *with* the change and is untrusted context exactly like the
summary. It explains; it does not accept. A reviewer is right to keep reporting
the missing proof, and the round cannot converge on the strength of the comment
alone.

Accepting the limitation is the operator's decision, and it becomes authority only
the way every other accepted limitation here does: a dated record landed on the
**base ref by its own pull request**, which a reviewer can then read as settled.
`docs/decisions/2026-08-06-merge-admin-default.md` is the worked example — it was
landed separately, before the PR that relied on it. `pr-watch.sh`'s clock guard
carries such a comment for a limitation already settled that way.

**Say what you did not do — as a disposition, never as a description.** Silence
reads as "addressed", and the reviewer has no way to tell the difference. But the
summary is posted in the same comment as the `@codex review` mention, and a
mention that describes an *unfixed* defect is read as a task rather than as
context: Codex then runs as a coding agent, commits in an environment with no
remote, and the round is spent producing a commit that exists nowhere. That has
happened here.

So record the **disposition** in the past tense and nothing more — "one finding
was answered on its thread rather than applied", "one is deferred to #11" — with a
bare issue number where there is one. Do not restate the defect, its file, its
consequence, or what closing it would take. Where a broader fix looks warranted,
that discussion belongs **outside the review request** — an issue, and the
operator — with at most "deferred to #N" in the summary itself; naming the
decision in the mention is enough to make it a work order. **Write the summary as a record,
never as a work order** below has the full rule and the incident it came from.

## Derive identity

```bash
# THE HELPERS ARE LOCATED FIRST, because the identity parser is one of them.
#
# Same rule as every probe here: the status is taken. This path is handed to
# `pr-merge-range.sh`, which inspects history in it to decide whether every commit
# since the reviewed SHA is a review fix — so a directory retained from a failed
# probe is a merge decision made about the wrong tree.
REPO_DIR="$(git rev-parse --show-toplevel)" \
    || { echo "ABORT: could not resolve the repository root"; exit 1; }
RB_SCRIPTS="${CLAUDE_PLUGIN_ROOT:-}/skills/watch-prs/scripts"
# `ls -dt … | head -1` — newest by mtime. NOT `sort -V`, which is GNU-only: on
# macOS the fallback would fail before finding the scripts at all.
#
# The discovery's STATUS is taken and the result validated. `ls` can print one
# candidate and then fail on another unreadable cache entry, and `head` masks
# that status anyway — so an unchecked pipeline could select a partial or stale
# path, and every state, findings and merge-gate call below would then run a
# different version of the helpers than the one that was installed.
if [ ! -d "$RB_SCRIPTS" ]; then
    RB_CANDIDATES="$(ls -dt "$HOME"/.claude/plugins/cache/*/watch-pr-skill/*/skills/watch-prs/scripts 2>/dev/null)" \
        || { echo "ABORT: could not enumerate installed plugin copies"; exit 1; }
    # `head` can emit a plausible first path and then fail; the assignment would
    # keep it, and if that directory happens to hold executables the validation
    # below passes — every gate then running helpers chosen by a failed read.
    RB_SCRIPTS="$(printf '%s\n' "$RB_CANDIDATES" | head -1)" \
        || { echo "ABORT: could not select an installed plugin copy."; exit 1; }
fi
# Validated as a directory that actually holds the helpers, not merely non-empty:
# a plausible-looking path that is missing them fails later, one call at a time.
[ -d "$RB_SCRIPTS" ] && [ -x "$RB_SCRIPTS/pr-review-state.sh" ] \
    || { echo "ABORT: could not locate the plugin helper scripts"; exit 1; }

# THE IDENTITY COMES FROM THE SHARED PARSER, not from a copy written out here.
#
# This was ~35 lines of origin parsing inline, and the same rules again in three
# helper scripts. Both the hostless-origin rule and the file-transport rule had to
# be written into all four, and the fixtures proving them had to be built a second
# time to cover the copies that had silently missed one. A rule proven in one copy
# is unproven in the others. See `identitylib.sh` and issue #18.
#
# What a drifted copy costs: an origin whose host cannot be derived, defaulted to
# github.com while the path split still yields a plausible `acme/widget`, points
# every `gh` call at the unrelated PUBLIC repository of that name — reading,
# commenting on and merging there. So the parser refuses rather than guessing: an
# origin that names no host, or one whose transport reaches no GitHub server, is
# not an identity.
#
# `.` and not a subshell: `rb_identity` SETS `HOST`, `OWNER` and `REPO` rather than
# printing them, because serialising three values through one string makes any
# delimiter a value a remote can contain — and a remote carrying it shifts the
# fields, which is the wrong-repository failure the parser exists to prevent.
# The stale definition is cleared first, and the CLEARING IS CHECKED. Bash
# exports functions through the environment, so a session that had already
# defined `rb_identity` leaves one here before the `.` — and a library that is
# empty or truncated above the definition still sources successfully. The check
# below would then find the inherited function and report the parser loaded,
# with every `gh` call addressed by whatever that stale version derives.
#
# `|| true` reopened it: `readonly -f rb_identity` makes the unset FAIL and
# leaves the function installed, and a discarded status makes a definition that
# could not be cleared look like one that was never there. Unsetting a name that
# is not defined returns 0, so a non-zero status here means only one thing.
unset -f rb_identity 2>/dev/null \
    || { echo "ABORT: a pre-existing rb_identity could not be cleared"; exit 1; }
. "$RB_SCRIPTS/identitylib.sh" \
    || { echo "ABORT: could not load the identity parser from $RB_SCRIPTS"; exit 1; }
[ "$(type -t rb_identity 2>/dev/null)" = function ] \
    || { echo "ABORT: the identity parser loaded but defines nothing"; exit 1; }
rb_identity \
    || { echo "ABORT: origin is not a usable identity ($RB_IDENTITY_REASON)"; exit 1; }
CODEX_BOT='chatgpt-codex-connector[bot]'; COPILOT_BOT='copilot-pull-request-reviewer[bot]'
# THE PUSHED HEAD MUST NOT BE RED BEFORE A ROUND IS CLOSED.
#
# CI was red for four consecutive commits on one PR and neither the round loop nor
# the pre-push self-check noticed: every round was closed as green on the strength
# of a local suite run, and the operator had to point at the checks tab.
# `pr-selfcheck.sh` runs the suite HERE, before the push — it cannot see a failure
# that only happens on the runner, and that one only happened there. "The suite
# passes here" and "the checks pass there" are different claims, and only the
# first was ever being made.
#
# THE GATE IS A SCRIPT, not a function defined here.
#
# It was ~100 lines of shell in this document, pasted into your session and called
# from four sites below. Nothing checked it: the suite, `pr-selfcheck.sh` and the
# bash 3.2 CI job all cover `scripts/`, and none of them can see shell inside a
# Markdown file — `test-pr-skill-contract.sh` had to `sed` the function back out of
# this document to execute it at all. It also needed a clear-and-verify dance
# around its own definition, because a `readonly -f` copy left over in your shell
# would silently survive an `unset -f` and a stale gate returning 0 lets a red head
# close its round. A script cannot be shadowed that way, so all of that is gone
# with it. Issue #26.
#
# `pr-ci-gate.sh <pr> <head-oid>` — 0 carry on, 1 stop. Same bounds, same
# `PR_CI_*` knobs, same diagnostics.
#
# THE KNOBS ARE EXPORTED, because a child process is what reads them now. A
# function saw `PR_CI_TIMEOUT=3600` assigned in your shell whether or not it was
# exported; a script does not, and would have gone on using the 1800-second
# default while the terminal showed the value you set. That is the one behaviour
# the move could have changed silently, so it is handled here rather than at each
# of the four call sites.
#
# `REVIEW_MERGE_STRICT` IS IN THIS LIST FOR THE SAME REASON, and it is the one
# that matters most: it is the knob that makes the merge SAFER, by handing the
# decision to GitHub instead of merging with `--admin`. Losing it at the process
# boundary does not fail — it silently restores the very bypass the operator set it
# to avoid. The lesson was already learned for the CI bounds; this was the instance
# it did not get applied to.
for _rb_knob in PR_CI_INTERVAL PR_CI_TIMEOUT PR_CI_GRACE PR_CI_PROBE_TIMEOUT REVIEW_MERGE_STRICT; do
    [ -n "${!_rb_knob-}" ] && export "$_rb_knob"
done
unset _rb_knob
# Where each round's summary is written before it is posted. A file, not a shell
# variable: the text is long, contains backticks and quotes, and passing it
# inline mangles it. Freshly created per PR and per session, because a reused
# path is how a stale summary from another round — or another PR — gets posted
# as if it were this one's.
# `mktemp` takes its status like every other probe here, and the result is
# validated. A wrapper that prints a plausible path and then fails would
# otherwise point every later write and guarded read at an existing file — and a
# stale summary read back as this round's is exactly what the guarded read was
# added to prevent.
SUMMARY_FILE="$(mktemp -t "watch-pr-N-XXXXXX.md")" \
    || { echo "ABORT: could not create the round-summary file"; exit 1; }
[ -f "$SUMMARY_FILE" ] && [ ! -s "$SUMMARY_FILE" ] \
    || { echo "ABORT: the round-summary file was not created empty"; exit 1; }
echo "OWNER=$OWNER REPO=$REPO RB_SCRIPTS=$RB_SCRIPTS SUMMARY_FILE=$SUMMARY_FILE"
```

## 1. State the task on the PR

The reviewers judge relevance against what the PR says it set out to do, so this
is a precondition, not documentation. Before requesting a review, the PR
description must state what the change does and what it deliberately does not.
Every later round adds a **round-summary comment** saying what was addressed and
what was intentionally skipped — the skipped part as a past-tense **disposition**
with a bare issue number, never as a description of the unfixed defect or the
reasoning behind leaving it. That mention is a review request, and a request that
describes work to be done is read as a work order; see **Write the summary as a
record, never as a work order**.

Neither can waive a finding — both are untrusted context to a reviewer. Where a
limitation is genuinely accepted, record it on the **base ref**.

## 2. Request the review — Codex first

The loop is **phased**: Codex reviews to a clean signoff, and only then does
Copilot get asked. Running both every round costs a Copilot pass on every
intermediate commit, and its findings arrive interleaved with Codex's on code
that is about to change anyway.

**Establish the review mode first — it decides whether to ask at all.** With
Codex automatic review enabled, opening or pushing the PR has *already* queued a
pass over this head, and a mention then queues a **second** review of the same
commit: two passes, two sets of findings, one round. This is the same duplicate
the round-closing step avoids, and it applies just as much to the first request.

`AUTO_REVIEW` is set once per PR and used by every later step. It cannot be
probed from `gh` — it is a Codex account/repository setting, not repository
state — so ask the operator rather than guessing. The wrong guess is either a
duplicate pass or a review nobody requested.

```bash
AUTO_REVIEW=no   # or `yes`, per the repo's Codex Code review settings

WHO="$CODEX_BOT"
# The baseline the watch compares against — and it is EMPTY on the automatic
# path.
#
# `--after-review` means "the review I am waiting for is newer than this one".
# On a re-request that is right. On the INITIAL automatic pass it is actively
# wrong: the push or PR-open that triggered the review happened before this skill
# ran, so a lookup here can capture the very pass being waited for. The watch
# would then reject the only terminal review as stale and re-arm forever, waiting
# for a review nobody is going to request.
#
# There is nothing to capture before the trigger, because the trigger preceded
# us. So the automatic path waits on any terminal review, and only the explicit
# re-requests in step 5 carry a baseline.
# No head baseline is captured here. One used to be, so the automatic path could
# tell a real push from a no-op one and send a mention only for the second — and
# the request is unconditional now, so nothing reads it. Left in place it would be
# a `gh pr view` whose transient failure or malformed answer ABORTS this step
# before any context is posted or any wait begins: a call that can only cost.

if [ "$AUTO_REVIEW" = "yes" ]; then
    PRIOR_REVIEW=""
else
    PRIOR_REVIEW=$("$RB_SCRIPTS"/pr-review-state.sh review-id N "$WHO") \
        || { echo "ABORT: could not read the current review id; do not request a review blind."; exit 0; }
fi

if [ "$AUTO_REVIEW" = "yes" ]; then
    # The pass is already queued by the push that created or updated the PR.
    # Post the account of what to look at WITHOUT a mention, so the reviewer has
    # it, and go straight to the wait.
    if ! gh pr comment N --repo $HOST/$OWNER/$REPO --body "<one paragraph: what this change does and what to look at>"; then
        echo "ABORT: could not post the PR context — do not enter the wait step."; exit 0
    fi
else
    # The mention IS the request. Branch on it: a failed post means no review was
    # ever queued, and the wait step would then poll for one until it timed out,
    # reporting "no review arrived" rather than "none was asked for".
    if ! gh pr comment N --repo $HOST/$OWNER/$REPO --body "@codex review

<one paragraph: what this change does and what to look at>"; then
        echo "ABORT: could not post the @codex request — do not enter the wait step."; exit 0
    fi
fi
```

Either way the wait step is next: with auto-review on there is a pass in flight
to watch, and with it off one has just been asked for.

Do **not** request Copilot yet. Step 7 does that, once Codex is clean.

## 3. Wait for the verdict

Poll the **active** reviewer — `$CODEX_BOT` in the Codex phase, `$COPILOT_BOT`
in the Copilot phase. Set `WHO` once at the top of the round and use it
throughout, so the round is fixed, summarised and re-requested for the same
reviewer it was waiting on.

Do not sit in a polling loop by hand. `pr-watch.sh` blocks until there is
something to act on and prints one line when the state changes:

```bash
WHO="$CODEX_BOT"        # or "$COPILOT_BOT" once step 7 has begun
# $PRIOR_REVIEW is the authoritative review id captured BEFORE the request that
# this watch is waiting on — see step 2 and step 5. A re-request on an unchanged
# head (after a dismissal, or after answering a finding rather than changing
# code) has nothing else to tell the new pass from the old one, so without it the
# first poll reports the PREVIOUS review as this round's answer.
"$RB_SCRIPTS"/pr-watch.sh N "$WHO" --after-review "$PRIOR_REVIEW"; WATCH_RC=$?
```

**Claude Code** — run it as this session's **Monitor** so the verdict surfaces
into the chat by itself instead of being waited on:

- `command`: `"$RB_SCRIPTS"/pr-watch.sh N "$WHO" --after-review "$PRIOR_REVIEW"`
- `description`: `Review verdict for PR N` · `timeout_ms`: `3600000`
- `persistent`: `true`

**Arm it as part of the round, and re-arm it the same way — do not ask.** The
watch is how the loop notices anything at all; a round that ends without one
leaves the driver waiting on a verdict nothing will report. `pr-watch.sh` exits
when it reaches a terminal state, so **one arming covers one verdict**: every
review request in step 2 needs its own, for the reviewer named by `$WHO`.

Treat it as part of requesting the review, not as a separate decision to put to
the operator. It reads no secrets, changes nothing, and stopping it costs one
`TaskStop` — so a prompt per round buys nothing and turns an automatic loop back
into a manual one. If the harness prompts anyway, that is a permissions gap
rather than a question worth relaying; `README.md § Watching without prompts`
says what to add.

Re-arm on `WATCH_RC` 1 as well: a timeout means the verdict has not arrived yet,
not that the round is over. Only `0` (verdict in hand) and `2` (fail closed) end
the watch for that round.

It prints on **change**, not on every poll, so a long wait does not bury the
session in identical lines:

```
PR_REVIEW_WATCH pr=10 reviewer=chatgpt-codex-connector[bot] state=none waited_s=0
PR_REVIEW_WATCH pr=10 reviewer=chatgpt-codex-connector[bot] state=pending waited_s=120
PR_REVIEW_READY  pr=10 reviewer=chatgpt-codex-connector[bot] state=reviewed verdict=findings findings=5
```

| `WATCH_RC` | meaning | what to do |
| --- | --- | --- |
| `0` | terminal state reached, verdict on the last line | step 4 |
| `1` | timed out — the review is still in flight | **re-arm the same watch.** Do not re-request: that queues a duplicate pass on the same head. Do not ask: that is the manual loop this replaces. |
| `2` | the state could not be read | **fail closed** — never treat it as "no findings" |

The states it reports, and what each means:

| state | meaning |
| --- | --- |
| `none` | no review on this head yet |
| `pending` | a draft is open — the pass is not finished |
| `reviewed` | a submitted APPROVED/COMMENTED review exists |
| `blocked` | CHANGES_REQUESTED — treat as findings, and read its body in step 4 |
| `dismissed` | the signoff was withdrawn — request the review again |

## 4. Read the findings

Inline review comments are the findings. The review **body** is the reviewer's
non-blocking channel and does not gate the merge — with one exception, below.

```bash
"$RB_SCRIPTS"/pr-findings.sh list N; FIND_RC=$?
```

- `0` — the printed threads are the complete set of unresolved findings.
- `2` — the read could not be trusted. **Stop.** Do not reply, resolve or
  summarise: a truncated or malformed page is indistinguishable from a shorter
  review, and everything downstream would be based on it.

The script paginates, validates each page's shape before formatting anything, and
refuses to guess when `hasNextPage` is missing or a thread has no readable
comment. That is deliberately not inline here: this logic spent three review
rounds as a snippet in this file, where no test ran it, and each round found
another way for it to fail open. The repository has been here before — the
merge-range check lived inline "where nothing executed it" and became a script for
the same reason.

**When a reviewer's state is `blocked`, read its review body too.** A
`CHANGES_REQUESTED` review can carry its whole argument in the body with no
inline comment — the merge gate then refuses to pass while `list` shows nothing to
fix, which looks like a stuck loop rather than a request.

```bash
"$RB_SCRIPTS"/pr-findings.sh blocked-body N "$WHO"; BODY_RC=$?
```

`BODY_RC` carries the same contract as `FIND_RC`: **`2` is a stop.** If the head
lookup or the reviews fetch is unreadable, empty output means "could not read",
not "there is no body" — and this is the only path that can surface a body-only
request, so continuing would fix, close and re-request as though the reviewer had
asked for nothing.

The head argument is **omitted on purpose**: `$HEAD_OID` is not assigned until the
merge gate, so passing it here would abort under `set -u` or — worse in a
long-lived session — filter against a stale 40-hex value left over from another
PR. The helper resolves the head itself, with its own guarded lookup.

Scoped to the current head either way: a stale `CHANGES_REQUESTED` on an older
commit, already superseded by a signoff on this one, is not an active finding.

### Read each finding whole, not just its title

`list` prints one line per thread so the set is countable. **That line is not the
finding.** The reviewers write a one-line title and then several sentences that
carry the actual argument — the input that triggers it, why the current code
mishandles it, and what the consequence is. Acting on the title alone produces a
fix aimed at a paraphrase, which is how a round ends with the finding still true
and the thread resolved.

`list` already prints each finding's **complete body** under its `thread=`/
`comment=` line — that is what the multi-line output after each header is. Read
it there. Do **not** reach for `pulls/N/comments` to fetch bodies: that endpoint
has no resolution filter and returns every review comment the PR has ever had, so
it hands you findings answered three rounds ago mixed in with the current set —
and fixing an already-answered comment is precisely the scope expansion the rules
above forbid. `pr-findings.sh` filters to unresolved threads; the REST endpoint
cannot.

Three things in a body change what you should do, and all three are easy to miss
when skimming:

- **A code suggestion.** Both reviewers can attach one — a fenced ```suggestion
  block, or a proposed patch written into the prose. Read it, and treat it as a
  proposal rather than an instruction: it is written without the surrounding
  context you have, and applying one unread is how a fix lands that satisfies the
  comment and breaks something else. Where you disagree, implement the correct
  fix and say in the thread why the suggestion was not taken.
- **A stated consequence.** "…so the merge proceeds with no trusted checks
  result" tells you what to assert in the test. A fix whose test asserts the
  mechanism but not the consequence leaves the consequence unproven — and in this
  repository that has repeatedly meant a mutant that changed nothing.
- **A scope hint.** Wording like "and apply the same rule in the other parsers"
  or "add a fixture for this form" is part of the finding, not a suggestion for
  later. Ignoring it produces the same finding again next round, in the copy you
  did not touch.

Reply to each thread with **what changed and why**, not "fixed". The reply is
what a reviewer reads if the same area comes up again, and "fixed" tells it
nothing it can check.

## 5. Fix, then close the round

Fix the findings. Where you disagree, say so in the thread rather than silently
resolving it. Then, in one pass:

1. commit — `fix(review): <what changed>`. **In the Copilot phase, add a
   `Review-Phase: copilot` trailer**: it is what tells the merge gate that the
   head advanced only through Copilot fixes, so Codex's earlier signoff still
   covers it and does not have to be re-earned.

   **It has to be a real trailer, not a line in the body.** `git` parses trailers
   from the LAST paragraph of the message only, so this belongs in the same block
   as `Co-Authored-By:` with no blank line before it:

   ```
   fix(x): what changed

   Why it changed.

   Review-Phase: copilot
   Co-Authored-By: …
   ```

   A blank line above it makes it its own paragraph, which `git` does not read as
   a trailer at all — the commit then looks correct to anyone reading it and is
   invisible to the merge gate, which reports `untagged_commit` and asks for a
   trailer that is plainly already there. `pr-merge-range.sh` names that case
   separately (`trailer_not_in_trailer_block`) because the fix is different;
2. **run the self-check — step 5a — and fix what it finds.** This is the step
   that exists to stop a defect reaching a reviewer, so it runs while the change
   can still be amended, before anything leaves the machine;
3. **check the round boundary — step 6.** Both this and the self-check have to
   precede the push: with Codex automatic review enabled the *push itself*
   requests the next review, so a boundary check after it cannot stop anything
   and a self-check after it has already let the round start. **The push is not
   here** — it belongs to the mode-specific recipe below, because the checks on
   what it pushes decide whether this round may be closed at all;
4. reply to each thread with what changed, **react to it**, and resolve it — and
   **verify the resolve succeeded** rather than assuming it did.
   `resolveReviewThread` returns `thread{isResolved}`; read it. A round reported
   as "all threads resolved" when they were not sends the next review over
   findings that were already answered, and the extra volume reads as regression
   rather than repetition.

   The reaction is not decoration: every Codex finding ends with *"Useful? React
   with 👍 / 👎"*, and it is the only signal the reviewer gets about whether a
   review was worth making. `pr-findings.sh list` prints `comment=<id>` beside
   `thread=<id>` for exactly this — the thread id resolves over GraphQL, the
   comment id reacts over REST, and neither substitutes for the other.

   ```bash
   # 👍 when the finding was acted on, or was correct and recorded as accepted.
   # 👎 only when it was wrong on the facts — not when it was right but declined
   # for cost or scope. Marking a correct finding unhelpful teaches the reviewer
   # to stop reporting that class, which is the opposite of what a decline means.
   gh api --hostname "$HOST" --silent -X POST "repos/$OWNER/$REPO/pulls/comments/<comment-id>/reactions" \
       -f content='+1' || echo "note: reaction failed for <comment-id>"
   ```

   A failed reaction is a note, not an abort: it is feedback, and losing it must
   not stop a round from closing;
4. **post the summary and re-request `$WHO`** — after the push, and after the
   CI gate has said the pushed head is green. Resolving a thread and posting a
   summary are the irreversible parts of closing a round, so they come last: a
   comment saying "that round did not really close" is a record, not a retraction,
   and it is itself a call that can fail.

   With automatic review on the push also *starts* a pass, and that one cannot be
   held back. It reads open threads and no summary, so it may re-report what this
   round already answered — which is why the explicit request at the end is sent
   in that mode too, and is the pass that carries the summary. A wasted pass is
   recoverable; a round closed on a red head is not.

### 5a. Self-check before the push

**Review your own diff before a reviewer has to.** PR #10 took nineteen rounds,
and almost none of the findings were subtle — they were the same few mistakes,
reaching a reviewer because nothing looked at the change first. Rounds are the
expensive part of this loop: each one costs a review pass, a fix, a summary and a
wait, so a finding caught here is worth several caught there.

```bash
"$RB_SCRIPTS"/pr-selfcheck.sh; SELF_RC=$?
```

- `0` — the mechanical checks pass. Continue with the judgement list below.
- `1` — findings. **Fix them now.** Pushing a change this catches spends a whole
  round on something a script found in a second.
- `2` — the check could not run. Fail closed: that is not a clean bill.
- `3` — **not applicable**: this repository is not a `watch-pr-skill` checkout,
  so none of these checks had anything in scope. That is the normal case in every
  other project, and it is a *separate status from `0` on purpose* — the same
  exit code would have let the driver report that the checks passed when none
  ran. Nothing was verified, so the judgement list below carries the whole
  weight; say so in the summary rather than claiming a clean check.

It checks what can be checked without judgement: every variable used in this
file is assigned in it, every script parses, every helper this file drives is
shipped, every script has a test, and the suite passes. That set is not
arbitrary — each one is a mistake that actually shipped from this repository.

**Then read your own diff against the list below.** These are the classes that
produced the rounds, and none of them is mechanical:

- **Did I fix the instance or the class, within this diff?** A finding names one
  place. Before fixing it, search for the same shape **everywhere else this PR
  already changes** and fix those together — the same fix arrived in three
  consecutive rounds (head validation, then non-zero statuses, then record
  identity) because each round closed one site. A copy in a file this PR does not
  touch is recorded and left to the operator, exactly as the scope rules above
  require; this check asks whether the class was closed inside the diff, never
  whether the diff was widened to reach it.
- **Did I widen something without rechecking what consumes it?** Accepting ISO
  offsets in a timestamp validator reopened a lexical-sort hole an earlier round
  had closed, because the sort was never revisited. A validator is a contract
  with its consumers; loosening it is a change to all of them.
- **Did I trace every identifier and ordering I touched, end to end?** A variable
  written into two places and assigned in none shipped as a P1. So did an
  ordering that assumed a push was inert when auto-review makes it the trigger.
- **Can each new assertion actually fail?** Revert the fix and watch the test
  fail *for the reason it names*. An assertion matching prose that wrapped across
  a line, or a token that also appears elsewhere in the file, passes against the
  unfixed code — which is worse than no test, because it converts an unverified
  assumption into a green tick.
- **Did I answer the finding, or just silence it?** Resolving a thread without
  fixing or arguing is the one move that guarantees it comes back.

Write what this pass changed into the round summary. If it found nothing, say so
— that is a claim the next review will test.

### The order depends on what triggers the review

The reviewer contract says the newest round summary is read before the diff. That
only holds if the summary exists before the pass starts — so the ordering is
decided by **what starts it**, and there are two different answers.

`$AUTO_REVIEW` was established in step 2 and is carried for the whole PR.

**Automatic review OFF** — the mention is the trigger, so it can carry the
summary and the push is inert:

```bash
# Branched on: if the push fails — auth, a non-fast-forward, a dropped
# connection — the fixes are not on the PR, and closing the round anyway resolves
# threads and requests a review of code that was never sent.
# The SHA this round is pushing, captured before the push and status-checked, so
# the gate can be asked about this commit rather than about whatever the API
# currently calls the PR's head.
HEAD_PUSHED=$(git rev-parse HEAD) || { echo "ABORT: could not read the local head."; exit 0; }
git push || { echo "ABORT: push failed; do not close or re-request this round."; exit 0; }
# The checks on what was just pushed, BEFORE anything else in this round. Threads
# resolved and a summary posted against a red head are a round closed on code that
# does not build — and in this mode nothing has been resolved or posted yet, so a
# red head leaves the round genuinely open.
"$RB_SCRIPTS"/pr-ci-gate.sh N "$HEAD_PUSHED" || exit 0
# reply + resolve threads here
# One comment carries both. Branch on it — the comment IS the request, so a
# failed post means no review was queued and the wait step would poll for one
# until it timed out.
# The summary is READ with its status taken, before any of it is posted.
# `$(cat …)` inside the argument swallows the reader's status, so a partial read
# still produced a successful `gh pr comment` — and the reviewer contract makes
# the newest summary the thing read before the diff, so a truncated one is worse
# than none: it looks complete.
SUMMARY="$(cat "$SUMMARY_FILE")" || { echo "ABORT: could not read the round summary."; exit 0; }
[ -n "$SUMMARY" ] || { echo "ABORT: the round summary is empty."; exit 0; }
# The authoritative review id BEFORE the request, so the watch can tell the new
# pass from the old one on an unchanged head. Empty is a legitimate answer (no
# review yet); only a failed read is fatal.
PRIOR_REVIEW=$("$RB_SCRIPTS"/pr-review-state.sh review-id N "$WHO") \
    || { echo "ABORT: could not read the current review id; do not request a review blind."; exit 0; }

# THE BOUNDARY IS CHECKED BEFORE THE REQUEST, not after it in step 6. Counting
# afterwards meant the pause fired once round N+1 had already been queued and was
# very likely running — which is not a decision about whether to continue, it is
# a notification that continuing has begun.
"$RB_SCRIPTS"/pr-round-count.sh N "$WHO"; ROUNDS_RC=$?
case "$ROUNDS_RC" in
    0) ;;
    3) echo "PAUSE: round boundary reached; decide with the operator before requesting the next pass"; exit 0 ;;
    *) echo "ABORT: could not establish the round count (rc=$ROUNDS_RC)"; exit 0 ;;
esac

# Branch on the reviewer this round was about. Copilot is requested ONLY through
# `--add-reviewer`; posting the Codex mention in a Copilot round re-requests the
# wrong reviewer and leaves the watch waiting past a pass nobody asked for.
if [ "$WHO" = "$COPILOT_BOT" ]; then
    if ! gh pr comment N --repo $HOST/$OWNER/$REPO --body "$SUMMARY"; then
        echo "ABORT: could not post the round summary."; exit 0
    fi
    if ! gh pr edit N --repo $HOST/$OWNER/$REPO --add-reviewer @copilot; then
        echo "ABORT: could not re-request Copilot."; exit 0
    fi
elif ! gh pr comment N --repo $HOST/$OWNER/$REPO --body "@codex review

$SUMMARY"; then
    echo "ABORT: could not post the round summary and @codex request."; exit 0
fi
```

**Automatic review ON** — the push starts the pass, so the ordering is decided by
what is *irreversible*:

```bash
# NOTHING IRREVERSIBLE HAPPENS BEFORE THE CHECKS ARE KNOWN.
#
# This sequence used to close the round first — resolve the threads, post the
# summary — and push last, so that the pass the push starts would find both
# already in place. That ordering cannot be gated: by the time the checks on the
# pushed commit can be consulted, the threads are resolved and the summary is
# posted, and neither can be taken back. A later comment saying "this round is not
# closed" is a record, not a retraction, and it is itself a call that can fail.
#
# So the push comes first and the closure comes after the verdict. THE COST IS
# REAL and is not hidden: the pass the push starts reads open threads and no
# summary, so it can re-report findings this round already answered. That pass is
# superseded by the explicit request at the end, which is sent in this mode
# precisely because the automatic one ran too early to see anything.
#
# The trade is between a wasted pass and a round that closes on a red head. Only
# one of those two can be undone by the next round.
#
# The summary is READ here, with its status taken, but posted later — a round that
# cannot produce its own summary should not push either.
# `$(cat …)` inside the argument swallows the reader's status, so a partial read
# still produced a successful `gh pr comment` — and the reviewer contract makes
# the newest summary the thing read before the diff, so a truncated one is worse
# than none: it looks complete.
SUMMARY="$(cat "$SUMMARY_FILE")" || { echo "ABORT: could not read the round summary."; exit 0; }
[ -n "$SUMMARY" ] || { echo "ABORT: the round summary is empty."; exit 0; }
# NO REVIEW BASELINE IS TAKEN HERE. It used to be, and the push that follows can
# start a pass that FINISHES during the CI wait — the gate waits for checks, and a
# Codex pass on a small diff can be quicker. A baseline captured before the push
# then accepts that early pass as the answer to the request made after it, and the
# loop can advance to Copilot, or to the merge gate, while the summary-aware pass
# is still running. The baseline is taken immediately before the explicit request
# instead, so whatever the push started is already behind it.

# The push is the trigger — but ONLY when it moves the head. A round that ends
# without a new commit (a dismissal, or a finding answered rather than coded
# around) leaves the push a no-op, so nothing is queued: `--after-review` then
# rejects the old terminal record and every timeout re-arms forever. Those rounds
# are explicitly supported, so they need an explicit trigger.
# THE BOUNDARY IS CHECKED BEFORE THE PUSH — because in this mode the push IS the
# request. Placing it before the mention was not enough: a fix commit on the
# threshold-th round moved the head and started the next review while the count
# had not yet run, so status 3 still paused after round N+1 was queued. Third
# placement of this check, and the first one that precedes every way a review can
# be triggered.
"$RB_SCRIPTS"/pr-round-count.sh N "$WHO"; ROUNDS_RC=$?
case "$ROUNDS_RC" in
    0) ;;
    3) echo "PAUSE: round boundary reached; decide with the operator before requesting the next pass"; exit 0 ;;
    *) echo "ABORT: could not establish the round count (rc=$ROUNDS_RC)"; exit 0 ;;
esac

# No `PRIOR_HEAD` baseline any more. It existed to decide whether the push had
# moved anything, because the `@codex review` mention was sent only when it had
# not — a no-op push queues no pass, and `--after-review` then rejects the old
# record forever. The request is unconditional now, so there is nothing to decide:
# a round that moved the head and a round that did not both end with an explicit
# ask, and the question the baseline answered no longer arises.
HEAD_BEFORE=$(git rev-parse HEAD) || { echo "ABORT: could not read the local head."; exit 0; }
# THE REMOTE HEAD AND THE TERMINAL REVIEW ID, BEFORE THE PUSH — and used, which
# is the difference from the baseline that was removed. A push that moves the head
# starts a Codex pass, and that pass can FINISH while the CI gate is still waiting
# for checks. These two are what let the pass be waited on afterwards: the head to
# know one was started at all, the review id to recognise its result. Without
# them, `--after-review` on the explicit request accepts the earlier pass and the
# loop advances while the summary-aware one is still running.
PUSH_FROM=$(gh pr view N --repo $HOST/$OWNER/$REPO --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not read the head this push starts from."; exit 0; }
[[ "$PUSH_FROM" =~ ^[0-9a-f]{40}$ ]] || { echo "ABORT: the pre-push head is not a full OID ('$PUSH_FROM')."; exit 0; }
# CODEX ONLY, like the wait it feeds. Read unconditionally, a transient failure on
# a Copilot round aborted before the push AND before `--add-reviewer` — a round
# stalled by a probe for a pass that phase never has. Only the wait was made
# Codex-only the first time; its input has to be too, or the guard moves the
# failure rather than removing it.
PUSH_BASE=""
if [ "$WHO" != "$COPILOT_BOT" ]; then
    PUSH_BASE=$("$RB_SCRIPTS"/pr-review-state.sh review-id N "$WHO") \
        || { echo "ABORT: could not read the review id before the push."; exit 0; }
fi
git push || { echo "ABORT: push failed; no review was queued and the fixes are not on the PR."; exit 0; }
# The gate, before anything that cannot be taken back. A red head stops here with
# the threads still open and no summary posted, so the round is genuinely still
# open and the next push is its continuation rather than a correction.
"$RB_SCRIPTS"/pr-ci-gate.sh N "$HEAD_BEFORE" || exit 0
HEAD_AFTER=$(gh pr view N --repo $HOST/$OWNER/$REPO --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not confirm the pushed head."; exit 0; }
[[ "$HEAD_AFTER" =~ ^[0-9a-f]{40}$ ]] || { echo "ABORT: the pushed head is not a full OID ('$HEAD_AFTER')."; exit 0; }
# The push must have landed on THIS PR. A successful `git push` from the wrong
# worktree, or with a refspec pointing at another branch, leaves the PR head
# untouched — and because the local head then differs from it, the no-op branch
# is skipped and nothing is requested at all. Retried briefly, since the API can
# lag a moment behind the push.
# Compared against $HEAD_BEFORE — the SHA this round actually pushed, captured
# and status-checked before the push — NOT a fresh `git rev-parse HEAD`. Local
# HEAD is mutable: if something resets the checkout after the push, re-reading it
# can make the comparison succeed against a commit that never reached the PR.
if [ "$HEAD_BEFORE" != "$HEAD_AFTER" ]; then
    for _try in 1 2 3; do
        [ "$HEAD_AFTER" = "$HEAD_BEFORE" ] && break
        sleep 2
        HEAD_AFTER=$(gh pr view N --repo $HOST/$OWNER/$REPO --json headRefOid --jq '.headRefOid' 2>/dev/null) \
            || { echo "ABORT: could not re-read the head after pushing."; exit 0; }
        [[ "$HEAD_AFTER" =~ ^[0-9a-f]{40}$ ]] \
            || { echo "ABORT: the re-read head is not a full OID ('$HEAD_AFTER')."; exit 0; }
    done
    [ "$HEAD_AFTER" = "$HEAD_BEFORE" ] \
        || { echo "ABORT: the push did not update PR N (head is $HEAD_AFTER, pushed $HEAD_BEFORE) — wrong branch or worktree?"; exit 0; }
fi
# THE PUSH-TRIGGERED PASS IS WAITED OUT FIRST.
#
# If the push moved the head it started a Codex pass, and that pass can still be
# running here — CI settling in ninety seconds while a review takes a hundred and
# twenty is an ordinary shape. The explicit request below is answered with
# `--after-review "$PRIOR_REVIEW"`, and a `PRIOR_REVIEW` taken while that pass is
# in flight is the id BEFORE it: the pass then lands, satisfies the wait, and the
# loop advances to Copilot or to the merge while the request it was supposed to
# answer is still queued.
#
# So it is serialised. Only when the head moved — a no-op push starts nothing, and
# waiting for a pass nobody triggered is a guaranteed timeout.
#
# CODEX ONLY. A push never triggers Copilot — the skill establishes that at the
# top — so in the Copilot phase there is no pass to wait for, and waiting anyway
# meant every Copilot round that moved the head sat until the watch timed out and
# then exited BEFORE `--add-reviewer` was ever reached. The phase where automatic
# review does nothing is the phase where serialising it stalls everything.
if [ "$WHO" != "$COPILOT_BOT" ] && [ "$PUSH_FROM" != "$HEAD_AFTER" ]; then
    "$RB_SCRIPTS"/pr-watch.sh N "$WHO" --after-review "$PUSH_BASE"; PUSHPASS_RC=$?
    # A TIMEOUT IS NOT PERMISSION TO CONTINUE. If that pass has not terminated,
    # taking a baseline now is exactly the race this block exists to remove — the
    # pass lands a moment later and answers the wrong request.
    case "$PUSHPASS_RC" in
        0) ;;
        1) echo "ABORT: the pass the push started has not finished; its result would answer the next request."; exit 0 ;;
        *) echo "ABORT: could not observe the pass the push started (rc=$PUSHPASS_RC)"; exit 0 ;;
    esac
fi

# ONLY NOW is the round closed. The head is confirmed and its checks are green, so
# resolving a thread and posting a summary are claims that are true when made.
# reply + resolve threads here
#
# THE SUMMARY IS POSTED ONCE, by whichever branch below carries it. Posting it
# here as well produced two identical round-summary comments on every Codex round
# — and the reviewer contract makes the NEWEST summary the one read before the
# diff, so a duplicated one is a record with two answers to the same question.
# Worse, if the request that follows failed, the standalone comment had already
# recorded a closure that no superseding pass was coming for.

# WHICH reviewer comes FIRST, before any question about the head.
#
# A push never triggers Copilot — the skill establishes that at the top — so in
# the Copilot phase automatic review is irrelevant and the request is always
# explicit. Branching on the head first meant a Copilot round that DID change the
# head skipped `--add-reviewer` entirely, and the watch waited past the old
# Copilot result for a pass nobody had asked for.
if [ "$WHO" = "$COPILOT_BOT" ]; then
    # Same baseline rule, taken before this branch's own request.
    PRIOR_REVIEW=$("$RB_SCRIPTS"/pr-review-state.sh review-id N "$WHO") \
        || { echo "ABORT: could not read the current review id; do not request a review blind."; exit 0; }
    # Copilot's request carries no body, so the summary is its own comment — and
    # it comes FIRST, because `--add-reviewer` starts the pass and the contract
    # says the summary is there to be read before the diff.
    if ! gh pr comment N --repo $HOST/$OWNER/$REPO --body "$SUMMARY"; then
        echo "ABORT: could not post the round summary."; exit 0
    fi
    if ! gh pr edit N --repo $HOST/$OWNER/$REPO --add-reviewer @copilot; then
        echo "ABORT: could not re-request Copilot."; exit 0
    fi
else
    # THE BASELINE IS TAKEN HERE, after the push-triggered pass has had its chance
    # to land, so `--after-review` cannot mistake it for the answer to this
    # request. Empty is a legitimate answer (no review yet); only a failed read is
    # fatal.
    PRIOR_REVIEW=$("$RB_SCRIPTS"/pr-review-state.sh review-id N "$WHO") \
        || { echo "ABORT: could not read the current review id; do not request a review blind."; exit 0; }
    # Codex is asked EXPLICITLY, in this mode too, and the mention CARRIES the
    # summary — one comment, one round.
    #
    # This used to be sent only when the push moved nothing, on the grounds that a
    # push that does move the head already asked. That was true and is no longer
    # sufficient: the automatic pass now starts before the threads are resolved
    # and before the summary exists, so it reviews without the two things the
    # reviewer contract says it reads first. The explicit request is what queues
    # the pass that has them.
    if ! gh pr comment N --repo $HOST/$OWNER/$REPO --body "@codex review

$SUMMARY"; then
        echo "ABORT: could not request the review that carries this round's summary."; exit 0
    fi
fi
```

In the **Copilot phase** the request is `gh pr edit --add-reviewer @copilot`,
which is not a comment and is never triggered by a push, so the summary is a
separate post that goes **first**, branched on — Copilot can start reading within
seconds and would otherwise review against the previous round's summary.

Re-request **only the active reviewer** — unless automatic review has already
done it. The boundary was checked in step 2, before the push, precisely so this
step cannot outrun it. Asking the other reviewer on every round buys a review of
code that is about to change again, and mixes its findings into a round that was
not about them.

### Write the summary as a record, never as a work order

**State only what was done.** A `@codex` mention whose body describes an
*unfixed* defect — its file, its consequence, what it would take to close — is
read as a task, not as context. Codex will then run as a coding agent: it edits,
commits and reports work in an environment with no remote and no credentials, so
the commit exists nowhere, the review never happens, and the round is spent.

That is not hypothetical; it is where this contract came from. A round summary
that ended with "the seventh finding is deferred to #11 — it inflates `rounds` to
11 and skips the operator pause" produced exactly that: an implementation of the
deferred fix, a commit ID that resolves to nothing, and a review that had to be
requested again.

So: describe changes in the past tense, and put anything still open where it
belongs — a GitHub issue, linked by number and nothing more. "One finding was
answered on its thread rather than applied" is a record; **the reasoning lives on
that thread, not in the summary.** The reviewer reads the thread when it matters,
and a reply is not a review request — so the same words that are safe there turn
the mention into a work order. Restating the defect in the mention *is* the work
order, and so is explaining why it was left.

**A resolved thread is not a record of a fix.** The summary is.

## 6. Round check-in

**This runs inside step 5, before the request-triggering command** — both
recipes above call it. Counting afterwards meant the pause fired once the next
round had already been queued, which is a notification rather than a decision.
It is documented separately because the phase transitions in steps 7 and 8 check
the same boundary for the same reason.

```bash
"$RB_SCRIPTS"/pr-round-count.sh N "$WHO"; ROUNDS_RC=$?
```

Counting **per reviewer** is what makes the number mean something: the Codex
phase and the Copilot phase are separate loops, and a shared counter would let
nine Codex rounds plus one Copilot round trip a pause that neither loop had
reached.

- `0` — carry on.
- `3` — **stop and decide with the operator**: continue, stop and merge, stop and
  leave open, or abandon. A review loop that never pauses is a loop nobody chose
  to keep running.

  When the operator says continue, RECORD THAT ON THE PR before requesting the
  next review — the gate reads its own acknowledgement back, so without it every
  subsequent call pauses again on the same count:

  ```bash
  # The count comes from the gate itself rather than being retyped: an
  # acknowledgement naming the wrong number either pauses again immediately or
  # skips a later check-in, and both are silent.
  #
  # THE HELPER'S STATUS IS TAKEN, and it must be the distinguished 3. In a
  # pipeline the parse hides it: a run that printed a plausible pause line and
  # then died some other way still yielded digits and `sed` still succeeded, so
  # the acknowledgement below recorded the operator's permission on the strength
  # of a probe that failed. Permission is the one thing that must never be
  # inferred from unreadable output.
  ROUNDS_OUT="$("$RB_SCRIPTS"/pr-round-count.sh N "$WHO" 2>/dev/null)"; ROUNDS_RC=$?
  [ "$ROUNDS_RC" -eq 3 ] || { echo "ABORT: the round counter did not report a pause (rc=$ROUNDS_RC)."; exit 0; }
  ROUNDS="$(printf '%s\n' "$ROUNDS_OUT" \
            | sed -n 's/^PR_ROUND_PAUSE .*rounds=\([0-9][0-9]*\).*/\1/p')" \
      || { echo "ABORT: could not parse the round count."; exit 0; }
  case "$ROUNDS" in
      ""|*[!0-9]*) echo "ABORT: could not read the round count to acknowledge."; exit 0 ;;
  esac
  # The footer NAMES THE REVIEWER, because the count is per reviewer. An
  # unscoped acknowledgement of 41 Codex rounds is read by a Copilot invocation
  # with 5 and trips its ahead-of-count guard, blocking that phase permanently.
  gh pr comment N --repo $HOST/$OWNER/$REPO \
      --body "$(printf 'Continuing after the round check-in.\n\n**Review-Pause-Acknowledged:** `%s` `%s`\n' "$WHO" "$ROUNDS")" \
      || { echo "ABORT: could not record the acknowledgement; do not request another review."; exit 0; }
  ```
 Only OWNER, MEMBER and
  COLLABORATOR comments are read as acknowledgements, and one naming a round that
  has not happened yet is refused — the marker records a decision, it cannot
  manufacture permission. `REVIEW_ROUND_THRESHOLD=0` still disables the check-in
  entirely, which is a different thing from acknowledging one pause.
- `2` — the count could not be established. Fail closed: do not re-request as if
  it were round one.

The boundary is **crossed, not landed on**. It was a `rounds % threshold == 0`
test, which assumes the counter advances by one per call — it does not, because a
single round can contribute several countable heads, and a real PR went 35 → 41
across two rounds with the pause at 40 never firing. The test is now an
inequality against the last acknowledged count, which no step can jump over.

A round is a **distinct PR head that received a submitted review**, derived from
GitHub each time — so two reviewers on one commit is one round, a re-review of an
unchanged head does not inflate it, and the count survives a new session or a new
machine. v1 kept this in a `/tmp` file, so the pause it promised quietly
disappeared whenever that file did.

## 7. Codex is clean — now the Copilot phase

When `pr-review-state.sh verdict N "$CODEX_BOT"` exits 0, the Codex loop is done.
Ask Copilot:

```bash
# Capture the head Codex signed off BEFORE anything moves it. After the first
# Copilot fix, `gh pr view` reports the new head and nothing else records the old
# one — the state helper prints a 7-character sha, and the merge gate needs the
# full 40. Without this the gate cannot be populated correctly at all.
# The head the CLEAN VERDICT described, re-read and then re-validated — not
# whatever `gh pr view` reports now. If a push lands between the verdict and this
# lookup, that records the new, unreviewed head as the Codex signoff, Copilot is
# requested against it, and the final gate only discovers the missing Codex
# verdict after the whole Copilot phase has run.
CODEX_SHA=$(gh pr view N --repo $HOST/$OWNER/$REPO --json headRefOid --jq '.headRefOid' 2>/dev/null) || CODEX_SHA=""
# Re-validate Codex on exactly that sha. If it is not clean, the head moved and
# the Copilot phase must not start.
CODEX_RECHECK=$("$RB_SCRIPTS"/pr-review-state.sh verdict N "$CODEX_BOT" "$CODEX_SHA"); CODEX_RECHECK_RC=$?
if [ "$CODEX_RECHECK_RC" -ne 0 ]; then
    echo "ABORT: Codex is not clean on the sha being recorded ($CODEX_RECHECK) — the head moved; do not start the Copilot phase"
    exit 0
fi
if ! [[ "$CODEX_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ABORT: could not capture the Codex-signed-off head; do not start the Copilot phase"; exit 0
fi
# THE CHECKS ON THAT HEAD, TOO. The CI gate lives at the two push sites in step 5,
# and a PR whose first review is clean never enters step 5 at all — so a head with
# a failing check could pass through both phases untouched, and the merge gate
# looks only at REQUIRED checks, which a failing optional one is not. Every path
# that accepts a verdict as phase-completing has to have seen the checks, not just
# the paths that pushed something.
"$RB_SCRIPTS"/pr-ci-gate.sh N "$CODEX_SHA" || exit 0

# THE SUMMARY GOES FIRST, and its post is branched on.
#
# In the Codex phase the mention carries the summary, so the ordering is settled
# by construction. Here it is not: `--add-reviewer` is a separate call, and
# Copilot can begin reading within seconds. Requesting first means a fast pass
# reviews against the PREVIOUS round's account of what changed and what was
# skipped — and step 1 makes that account a precondition of asking, not a
# courtesy. If the summary cannot be posted, there is nothing to request against.
#
# WRITTEN HERE, not inherited from step 5. Codex can approve the very first
# request with no fix round at all, and then step 5 has never run: reusing its
# file would post an empty body in a fresh session, or — worse, in a long-lived
# one — a summary left over from another round or another PR. This is the
# phase-transition summary and it is always about the same thing, so it is
# always constructed at the point it is used.
# The WRITE is checked, not only the read below it. A `cat` that truncates the
# file and then fails — a full filesystem — leaves a non-empty partial body that
# the guarded read happily returns; a `cat` that cannot open the file at all
# leaves the PREVIOUS round's contents there to be read as this one's. Either
# posts an invalid summary and requests Copilot against it.
# The heredoc is QUOTED, and the one value it needs is written separately.
# Unquoted, the shell expanded the prose while writing it — and this body is
# prose you compose from the round, which routinely contains Markdown code spans
# holding shell text. A summary quoting a finding about `$(gh pr view …)` or a
# backtick-delimited command line was therefore EXECUTED while being written,
# and text lifted from an untrusted PR description or a reviewer comment is the
# same substitution with someone else choosing the command. Where it did not
# execute, it silently vanished: `$HOST` in quoted prose came out empty and
# `cat` still succeeded, so the mangling was invisible.
cat > "$SUMMARY_FILE" <<'EOF' || { echo "ABORT: could not write the phase summary."; exit 0; }
## Codex phase complete — requesting Copilot
EOF
# `$CODEX_SHA` is already validated as 40-hex above, and `printf` gives it no
# chance to be anything else. Appends are checked individually: a partial file
# reads as a complete summary.
printf '\nCodex signed off on `%s`. Opening the Copilot phase on the same head.\n\n' \
    "$CODEX_SHA" >> "$SUMMARY_FILE" || { echo "ABORT: could not write the phase summary."; exit 0; }
cat >> "$SUMMARY_FILE" <<'EOF' || { echo "ABORT: could not write the phase summary."; exit 0; }
<what the PR does, and what the Codex phase changed — one paragraph. If Codex
approved on the first pass with no fix rounds, say that: it is the difference
between "nothing was found" and "everything found was addressed".>

Fix commits from here carry a `Review-Phase: copilot` trailer, which is how the
merge gate knows the head advanced only through Copilot fixes and that Codex's
signoff still covers it.
EOF
# The summary is READ with its status taken, before any of it is posted.
# `$(cat …)` inside the argument swallows the reader's status, so a partial read
# still produced a successful `gh pr comment` — and the reviewer contract makes
# the newest summary the thing read before the diff, so a truncated one is worse
# than none: it looks complete.
SUMMARY="$(cat "$SUMMARY_FILE")" || { echo "ABORT: could not read the round summary."; exit 0; }
[ -n "$SUMMARY" ] || { echo "ABORT: the round summary is empty."; exit 0; }
if ! gh pr comment N --repo $HOST/$OWNER/$REPO --body "$SUMMARY"; then
    echo "ABORT: could not post the round summary — do not request Copilot yet."; exit 0
fi

# `--add-reviewer` IS the request. If it fails there is no Copilot pass to wait
# for, so entering the phase would poll for a review nobody asked for and then
# report a timeout — which reads as "Copilot is slow", not "Copilot was never
# asked".
# The boundary is checked HERE too, not only before a re-request. A phase that
# ends on the threshold-th reviewed head went straight from a clean verdict into
# the next phase, so the promised pause was skipped in exactly the case it exists
# for: the loop has run long enough to reach the boundary AND is about to commit
# to more work.
"$RB_SCRIPTS"/pr-round-count.sh N "$CODEX_BOT"; ROUNDS_RC=$?
case "$ROUNDS_RC" in
    0) ;;
    3) echo "PAUSE: round boundary reached; decide with the operator before opening the Copilot phase"; exit 0 ;;
    *) echo "ABORT: could not establish the round count (rc=$ROUNDS_RC)"; exit 0 ;;
esac

WHO="$COPILOT_BOT"
# The authoritative review id BEFORE the request, so the watch can tell the new
# pass from the old one on an unchanged head. Empty is a legitimate answer (no
# review yet); only a failed read is fatal.
PRIOR_REVIEW=$("$RB_SCRIPTS"/pr-review-state.sh review-id N "$WHO") \
    || { echo "ABORT: could not read the current review id; do not request a review blind."; exit 0; }

if ! gh pr edit N --repo $HOST/$OWNER/$REPO --add-reviewer @copilot; then
    echo "ABORT: could not request Copilot — do not enter the Copilot phase."
    echo "This is not permission to skip the pass: decide with the operator."
    exit 0
fi
WHO="$COPILOT_BOT"
```

Keep `$CODEX_SHA` for step 8. It is the only record of what Codex approved.

Then run steps 3–6 again with `$WHO` set to Copilot, until its verdict is clean
too. Every fix commit in this phase carries `Review-Phase: copilot`.

`gh pr edit --add-reviewer` fails when Copilot is not available to the
repository. That failure is **not** permission to skip the pass: report it and
decide with the operator.

**Codex is not re-requested during this phase.** That is the point of the
trailer: the merge gate proves the head advanced only through Copilot fixes, so
the Codex signoff still covers it. If a commit here lacks the trailer, the range
check fails and Codex has to review again — which is the correct outcome, since
unreviewed work reached the head.

## 8. Merge gate

Run every check immediately before merging — an earlier check answered about an
earlier head.

```bash
# THE GATE IS A SCRIPT. It was 291 lines here, pasted into your shell, and
# nothing checked it — which is how it came to contain a construct the bash macOS
# ships cannot PARSE, for fifty review rounds. `scripts/` is covered by the suite,
# by `pr-selfcheck.sh` and by the bash 3.2 CI job; a fenced block is covered by
# none of them. Issue #26.
#
#   pr-merge-gate.sh <pr> <codex-sha> <auto-review>
#
#     0  merged   — the head it names is on the base branch
#     1  blocked  — a gate refused; the reason is on stdout
#     3  paused   — a round boundary. NOT a refusal: decide with the operator
#     4  queued   — the request was accepted but the PR is not MERGED. A merge
#                   queue does that, and `gh` reports it as success. The head is
#                   not on the base branch; the session is not finished
#
# CODEX_SHA is the FULL 40-hex head Codex signed off on. In the Copilot phase the
# head moves past it and Codex is deliberately not re-run, so this — not the
# current head — is what Codex's verdict is checked against.
#
# AUTO_REVIEW is passed as an ARGUMENT rather than read from the environment: a
# value assigned in your shell without `export` reaches a function and not a child
# process, and this one decides whether an in-flight Codex pass may be ignored. A
# silent default there is a merge on a verdict nobody read.
# RUN FROM THE REPOSITORY THIS SESSION STARTED IN. The gate derives its identity
# and its range-check root from the current directory, so a `cd` into another
# checkout between setup and here would point every gate — and the `--admin` merge
# — at whatever PR of that repository shares this number. `$REPO_DIR` was captured
# in the setup block, and everything else in this session already used the identity
# derived there.
# THERE IS NO PLACEHOLDER HERE, and that is the third attempt at this line.
#
# `$CODEX_SHA` was captured and validated in step 7, when the Codex phase closed —
# the full 40-hex head Codex signed off on, read back and re-checked against its
# clean verdict before the Copilot phase was allowed to start. Writing it out again
# here as something for you to fill in was redundant, and it did not work: `<…>` is
# a REDIRECTION to the shell in argument position AND after an `=`, so an
# unsubstituted placeholder does not reach the gate's own sha check — the block
# fails to parse, which is a different failure in a different place.
#
# The value is already in this session. Use it.
(cd "$REPO_DIR" && "$RB_SCRIPTS"/pr-merge-gate.sh N "$CODEX_SHA" "$AUTO_REVIEW")
MERGE_RC=$?
case "$MERGE_RC" in
    0) ;;   # merged; the script printed the head it pinned
    3) echo "Stopping here: the operator decides whether to merge at a round boundary." ;;
    4) echo "NOT merged: the request was accepted but the PR is not MERGED — a merge queue takes the request without landing it. Do not close this out; confirm on the PR." ;;
    *) echo "Not merged. The reason is above; do not retry it blind." ;;
esac
```

If any gate fails, do **not** merge. Post the reason on the PR and hand it back
to the operator.

## What this skill deliberately does not do

- **It does not run a reviewer.** Codex and Copilot are GitHub apps; a local
  process reviewing PRs duplicates them, authors its comments as the repository
  owner rather than as a bot, and consumes a separate credit pool.
- **It does not merge unattended past a failed or unreadable gate.** Every
  "cannot tell" is a stop.
