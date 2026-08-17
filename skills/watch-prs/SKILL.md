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

**Prefer removing the dependency over guarding it.** When a finding names
something that can go wrong, there are usually two answers: add a check that
catches it, or change the shape so it cannot arise. Take the second whenever it
is not larger. A check is a name, and a name can be shadowed, mis-parsed,
locked, or simply forgotten by the next person — each of those has ended a round
in this repository, and each time the fix that finally held was subtractive:
reading data instead of expanding it, leaving an environment instead of
sanitising it, holding a list in an array instead of a string. Say on the thread
which of the two you took and why, so the reviewer is not left inferring it.

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
# THE IDENTITY IS PINNED HERE, ONCE, AND EVERY HELPER INHERITS IT.
#
# `rb_identity` reads `git remote get-url origin` from the CURRENT DIRECTORY, and
# every helper calls it in its own process. A `cd` into a second checkout — an
# ordinary thing for a driving session to do — therefore pointed the phase stages
# at whatever PR of THAT repository shares this number, and each of them posts: a
# signoff, a revocation, a review request.
#
# `REVIEW_BUS_REMOTE` is the caller stating the identity rather than the library
# deriving it, so exporting it removes the dependency instead of guarding it.
# Wrapping each call in `(cd "$REPO_DIR" && …)` was the guard, and it was itself
# defeatable: `cd` is a name, and a function named `cd` that returns 0 without
# moving leaves the subshell reporting success from the wrong tree. This has no
# name in it to shadow — the value is read once, here, and travels in the
# environment.
#
# `$REPO_DIR` IS STILL NEEDED, and for a different question: `pr-merge-range.sh`
# inspects HISTORY, which is a tree rather than an identity, so the merge gate
# keeps its own `cd`.
# `/usr/bin/env`, A PATH, BECAUSE `bash` IS A NAME. Written as `bash -p …` this
# calls a function called `bash` if the driving shell has one — and such a function
# can print a forged URL to fd 9 and return, which is this capture. A path cannot
# be shadowed. `/usr/bin/env` is the same one every script here already depends on
# through its shebang, so it is not a new assumption; which `bash` it then finds is
# a `PATH` question, and that is #91.
#
# `bash -p` STARTS THE FIRST INTERPRETER PROTECTED, and it has to be the first:
# privileged mode is what stops `BASH_ENV` being sourced at all, so entering it
# from inside a shell that has already run the hook is too late. A hook needs to
# shadow nothing to win that race — `printf '…' >&9; exit 0` is enough, because
# fd 9 is already this capture. The helper hops to `-p` itself as well, for a
# caller that forgets, but only this gets there before the hook.
#
# READ THROUGH A HELPER, BY PATH, BECAUSE `git` IS A NAME. This was
# `git remote get-url origin` here, and a function answering only
# `remote get-url origin` forged the identity every stage is then addressed by —
# successfully, with a plausible value. `"$RB_SCRIPTS"/pr-origin.sh` is a PATH, so
# no function can stand in front of it, and `bash -p` means no startup hook is
# sourced and no inherited function is imported in the first place. #84.
RB_REMOTE="$({ /usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh read; } 9>&1 1>&2)" \
    || { echo "ABORT: could not read origin to pin this session's repository"; exit 1; }
[[ -n $RB_REMOTE ]] \
    || { echo "ABORT: origin is empty; there is no repository to pin this session to"; exit 1; }
# `{ …; } 9>&1 1>&2` IS PART OF THE CALL, NOT DECORATION, AND THE BRACES ARE THE
# POINT. The helper writes its value to fd 9 and everything else to fd 1, and
# these redirections are applied before bash begins executing it — so an exported
# `SHELLOPTS=xtrace` with `BASH_XTRACEFD=1` sends its traces to stderr from its
# very first command. A redirection inside the helper could not manage that: no
# line can come before the trace of the line that performs it.
#
# THE SAME ORDERING APPLIES TO THIS LINE. Written as a simple command, bash traces
# it BEFORE applying its redirections — and inside a command substitution fd 1 is
# already the capture, so the trace lands in `$RB_REMOTE` ahead of the URL.
# Measured: `SIMPLE=[++ …/pr-origin.sh read` against `GROUP=[git@github.com:…]`.
# The group takes the redirections first, and the command inside it is traced
# afterwards, to stderr.
#
# ONE LINE, OR IT IS NOT A REMOTE. Kept as the last check on a value the whole
# session is addressed by. Nothing known still writes to this stream — that is
# what the invocation form buys — so this now guards the unknown rather than the
# tracing case it was added for.
[[ $RB_REMOTE = "${RB_REMOTE%%'
'*}" ]] \
    || { echo "ABORT: the origin read returned more than one line; something is writing to its stdout ('$RB_REMOTE')"; exit 1; }
# A COMMAND PREFIX, NOT THE EXPORT. This derives the DRIVER's own identity from
# the same value the children will be pinned to, without depending on the export
# having succeeded — so the two cannot disagree. The export itself is the last
# thing this block does; see the end of it for why.
REVIEW_BUS_REMOTE="$RB_REMOTE" rb_identity \
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
# `RB_SUITE_JOBS` IS HERE FOR THE SAME REASON AND NOTHING MORE. `pr-selfcheck.sh`
# runs the suite concurrently and takes its degree from that name, and step 5a
# starts it as a CHILD — so an operator who lowers it in this shell without
# exporting it watches the gate go on running four at a time while the terminal
# shows the value they set. The quiet kind of wrong, like the CI bounds above.
for _rb_knob in PR_CI_INTERVAL PR_CI_TIMEOUT PR_CI_GRACE PR_CI_PROBE_TIMEOUT REVIEW_MERGE_STRICT RB_SUITE_JOBS; do
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
# ── THE PIN IS THE LAST THING SETUP DOES, AND SETUP SAYS SO OR SAYS NOTHING ──
#
# `REVIEW_BUS_REMOTE` is what every helper inherits, and every post is addressed
# by it — `record`'s signoff, `open`'s revocation and review request, and the
# second signoff `close` writes on the two-reviewer path. (`close … codex-only`
# records nothing: there was no Copilot review to re-check.) So its failure
# has to end setup, and "ends setup" cannot rest on another name.
#
# A `readonly REVIEW_BUS_REMOTE` already in this long-lived shell makes the export
# fail; a function named `exit` makes the abort return instead of exiting. Either
# alone is caught below. TOGETHER they are not, if there is anything after them to
# run: the guard's last line ends the `if` non-zero, but with no `set -e` the next
# statement simply executes. That is why nothing comes after this — the position
# is the guard. Do not add a step below it; put it above.
#
# THE SUCCESS LINE IS INSIDE THE SUCCESSFUL BRANCH for the same reason. It is how
# the driver knows setup completed, so the failure path does not REACH it, whatever
# `exit` has been replaced with.
#
# "NOT REACHED" IS THE CLAIM, and it is deliberately weaker than "cannot be
# emitted". `echo` is a name too: a function replacing it can print `OWNER=…` from
# the ABORT below, or from anywhere else, and no arrangement of statements inside
# this shell prevents that — the alternative is a failure path that says nothing
# at all, which trades a real diagnostic for a guard against a shell that is
# already lying about its output. What survives a forged `echo` is the STATUS: the
# branch still ends non-zero. Removing the dependency means not composing this
# message here, which is #84 along with `git` and `bash`.
export REVIEW_BUS_REMOTE="$RB_REMOTE" \
    || { echo "ABORT: could not pin this session's repository — REVIEW_BUS_REMOTE is readonly in this shell"; exit 1; }
# THE PROOF IS TAKEN FROM A CHILD, because a child is what the pin is FOR. Reading
# the variable back here answers a different question: an `export` that assigns
# without setting the export attribute leaves this shell holding the right value
# and every helper holding none, so the parent-side check passes and the stages
# still derive from wherever the session later stands. What has to be true is that
# a new process sees it, so that is what is asked — and asking it also subsumes the
# parent-side check, since a wrong value here is a wrong value there.
#
# ASKED THROUGH THE HELPER, NOT WITH `bash -c`. That was the first form and it was
# a name: a function called `bash` runs in a shell copy which inherits NON-exported
# variables, so it agreed the pin had arrived while the real stages — which exec
# through `#!/usr/bin/env bash` and resolve on `PATH` — inherited nothing. The
# helper is reached by path and is a real child, so its answer is the one the
# stages will get. #84.
RB_PIN_SEEN="$({ /usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh pin; } 9>&1 1>&2)" || RB_PIN_SEEN=''
if [[ $RB_PIN_SEEN = "$RB_REMOTE" ]]; then
    echo "OWNER=$OWNER REPO=$REPO RB_SCRIPTS=$RB_SCRIPTS SUMMARY_FILE=$SUMMARY_FILE"
else
    echo "ABORT: the repository pin did not take; every stage would route by the current directory"
    exit 1
    [[ -n "" ]]
fi
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
    if ! gh pr comment N --repo "$HOST/$OWNER/$REPO" --body "<one paragraph: what this change does and what to look at>"; then
        echo "ABORT: could not post the PR context — do not enter the wait step."; exit 0
    fi
else
    # The mention IS the request. Branch on it: a failed post means no review was
    # ever queued, and the wait step would then poll for one until it timed out,
    # reporting "no review arrived" rather than "none was asked for".
    if ! gh pr comment N --repo "$HOST/$OWNER/$REPO" --body "@codex review

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
not that the round is over. Only `0` (verdict in hand), `2` (fail closed) and `4`
(the operator decides) end the watch for that round.

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
| `4` | the review carried comments and **every one was a reply** | **STOP. Do not go to step 4.** There is nothing for `pr-findings.sh` to list and this is not a signoff, so there is no round to fix and none to close. Put the comment to the operator and wait. |

**`4` does not continue into the fix round, and that is the whole point of it.**
A reviewer sometimes answers on an existing thread — a verdict, a correction, a
question — and none of those can be told apart by reading the text. Entering step
4 there finds no findings, closes the round on nothing and requests another pass,
which is the loop this status exists to end. Say what the comment was, and let
the operator decide.

**AND THE DECISION IS RECORDED, or the stop is just a different deadlock.** The
verdict stays non-clean for as long as that review is the newest one: re-running
the watch returns 4 again, there is no thread to resolve, and re-requesting is
forbidden. So the operator's answer has to become state:

- **it was a clean verdict** — record the signoff for that reviewer and head, the
  same `**Review-Signoff:**` line step 7 writes. The merge gate accepts it *for
  this shape only*: a `source=replies-only` verdict plus a recorded signoff naming
  that head merges, and says so in its output. A review with real findings is not
  a question anyone was asked, so a signoff never carries one;
- **it was a finding** — fix it and push. The head moves, the round is ordinary
  again, and nothing needs an override.

Absence is not permission: with no signoff recorded, the gate refuses and names
what to do.

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
4. **run `pr-close-round.sh gate` — the recipe below** — and only then reply to
   each thread with what changed, **react to it**, and resolve it, and
   **verify the resolve succeeded** rather than assuming it did.

   **The gate comes first, and this is an ordering, not a preference.** A
   resolved thread cannot be taken back: resolve before the push and a round that
   then fails to push, or pushes red, has already recorded its findings as
   answered on a commit that never landed. With automatic review on it is worse —
   the pass the push starts reads threads already marked resolved, with no summary
   saying what resolved them.
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
4. **run `pr-close-round.sh post`** — which posts the summary and re-requests
   `$WHO`, after the push, after the CI gate has said the pushed head is green,
   and after the threads are answered. Resolving a thread and posting a summary
   are the irreversible parts of closing a round, so they come last: a comment
   saying "that round did not really close" is a record, not a retraction, and it
   is itself a call that can fail.

   `post` re-proves the head is still the one `gate` reported — locally and on the
   PR — because the replies take as long as they take, and a commit made in
   between leaves the summary describing one commit while the reviewer reads
   another.

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
summary and the push is inert. Nothing is queued until that comment is posted,
which means the gate can prove the head with nothing yet requested.

**Automatic review ON** — the push starts the pass, so the ordering is decided by
what is *irreversible*: push, prove the checks, close afterwards. Closing first
and pushing last cannot be gated — by the time the checks on the pushed commit
can be consulted, the threads are resolved and the summary is posted, and neither
can be taken back. A later "this round is not closed" comment is a record, not a
retraction, and is itself a call that can fail.

**The cost of that mode is real and is not hidden:** the pass the push starts
reads open threads and no summary, so it can re-report findings this round already
answered. It is superseded by the explicit request `post` makes at the end. The
trade is a wasted pass against a round that closes on a red head, and only one of
those can be undone by the next round.

Both orderings live in the script, which takes `$AUTO_REVIEW` rather than a
hard-coded answer — one recipe here, two orders there:

```bash
# THE ROUND CLOSES THROUGH A SCRIPT, IN TWO STAGES, with the thread replies
# between them. Both orderings were prose-embedded shell here, doing the same job
# in different ORDERS, and the ordering is the whole content. Nothing executed
# either. Issue #26.
#
#   pr-close-round.sh gate N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW"
#   pr-close-round.sh post N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW" "$GATED_HEAD"
#
#     0  gated (`gate`) / closed (`post`)
#     1  stopped  — the reason is on stdout; the round is NOT closed
#     3  paused   — a round boundary. Decide with the operator
#
# `$AUTO_REVIEW` IS PASSED, NOT WRITTEN IN. It was established in step 2 and the
# script refuses anything but `yes` or `no`, so the mode this PR is in picks the
# order INSIDE the script — rather than deciding which of two recipes to copy out
# of here, which is how the two drifted apart in the first place.
GATE_OUT="$("$RB_SCRIPTS"/pr-close-round.sh gate N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW" 2>&1)"; GATE_RC=$?
printf '%s\n' "$GATE_OUT"
case "$GATE_RC" in
    0) ;;
    3) echo "Stopping here: the operator decides at a round boundary."; exit 3 ;;
    *) echo "The round did not close, and nothing has been resolved or posted. The reason is above; do not retry it blind."; exit "$GATE_RC" ;;
esac
# THE GATED HEAD IS CARRIED TO `post`, WHICH RE-PROVES IT. A child cannot assign a
# variable here, so it says what the value was and this reads it back out.
GATED_HEAD="$(printf '%s\n' "$GATE_OUT" \
    | sed -n 's/^PR_ROUND_GATED .*[[:space:]]head=\([0-9a-f]*\).*$/\1/p')"
[ -n "$GATED_HEAD" ] \
    || { echo "ABORT: the gate reported no head; there is nothing to hold the summary to."; exit 1; }
```

**Now answer the threads** — reply, react 👍/👎, and resolve, per step 4 above.
The head is pushed and green, so a resolve is a claim that is true when made.
Then, and only then:

```bash
# ONLY NOW IS THE ROUND CLOSED. `post` re-proves that the head is still
# `$GATED_HEAD`, locally and on the PR, before it posts anything: the replies take
# as long as they take, and the gate's green verdict belongs to the commit the
# gate saw and to no other.
POST_OUT="$("$RB_SCRIPTS"/pr-close-round.sh post N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW" "$GATED_HEAD" 2>&1)"; ROUND_RC=$?
printf '%s\n' "$POST_OUT"
# THE BASELINE COMES BACK IN THE SUCCESS RECORD. The script reads it immediately
# before it requests the pass, and step 3's watch needs exactly that value — a
# child cannot assign a variable here, so it says what the value was. Without
# this, the watch keeps the OLDER baseline and the terminal review this round just
# handled is newer than it, so it is accepted at once as the answer to a request
# nobody has answered yet.
if [ "$ROUND_RC" -eq 0 ]; then
    # THE RECORD HAS TO BE THERE; THE BASELINE MAY LEGITIMATELY BE EMPTY, and
    # those are different questions. `pr-review-state.sh review-id` returns
    # nothing when the current head has no review yet — which is every round that
    # pushes a new commit, and every Copilot round, since a push never triggers
    # one — and `pr-watch.sh` takes an empty baseline as "wait on any terminal
    # review", which is exactly right there.
    #
    # Testing the VALUE for emptiness aborted on all of those, AFTER the summary
    # was posted and the pass requested: the watch was never armed, and a retry
    # posts the summary and requests the pass a second time.
    CLOSED_REC="$(printf '%s\n' "$POST_OUT" | sed -n '/^PR_ROUND_CLOSED /p' | tail -1)"
    [ -n "$CLOSED_REC" ] \
        || { echo "ABORT: the round reported no closing record; step 3 would watch against a stale baseline."; exit 1; }
    # THE FIELD IS WHAT IS CHECKED FOR, not what is in it. A record that lost the
    # field entirely is a malformed answer; a record whose field is empty is an
    # answer.
    case "$CLOSED_REC" in
        *' prior-review='*) ;;
        *) echo "ABORT: the closing record carries no baseline field; step 3 would watch against a stale one."; exit 1 ;;
    esac
    # `prior-review=` IS LAST IN THE RECORD, so everything after it is the value —
    # and an empty value is carried through rather than rejected.
    PRIOR_REVIEW="${CLOSED_REC##* prior-review=}"
fi
case "$ROUND_RC" in
    0) ;;   # the script printed the head it closed on
    *) echo "The threads are answered but the round did not close: no summary was posted and no pass was requested. The reason is above; do not retry it blind." ;;
esac
exit "$ROUND_RC"
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
- `3` — **stop and decide with the operator.** A review loop that never pauses is
  a loop nobody chose to keep running. Put the options to them in these terms,
  because the useful ones are not all "carry on or give up":

  - **Continue** — the direction is right and the rounds are converging.
  - **Merge now** — enough review has happened for what this change is worth.
  - **Leave it open** — park it; the signoffs are on the PR and a later session
    resumes from them.
  - **Close it and start over with a better approach.** This is the option a loop
    will never propose for itself, and it is the one that check-ins exist to
    surface. Ten rounds on the same PR is evidence about the APPROACH, not only
    about the remaining defects: a design that needs a finding fixed every round
    is usually a design that will keep producing them. This repository has a
    worked example — a PR spent fifty-two rounds on a text scanner before it was
    abandoned and rebuilt around running the suite instead, which then took
    eleven. Nothing in the first fifty-two rounds was wrong on its own terms.

  **Say what the rounds have been about**, not just how many there were. "Ten
  rounds, each a new false positive in the same parser" and "ten rounds, each a
  distinct defect the fixes did not cause" are the same number and opposite
  situations, and the operator cannot tell them apart from a count.

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
  gh pr comment N --repo "$HOST/$OWNER/$REPO" \
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

That verdict counts the comments on the reviewer's newest review: a comment that OPENS a thread is a finding, and a reply is one too.
A reply is NOT exempt, even when it carries a clean verdict: the real verdict is
followed by paragraphs of explanation and a retraction is also a paragraph after
the verdict line, so no reading of the text separates them.

When a review's comments are ALL replies the answer says `source=replies-only`.
That is neither answer: `pr-findings.sh` lists nothing to fix, and it is not a
signoff. **Stop and put it to the operator** — one comment has to be read by a
human. Do not re-request, and do not treat it as clean.

A malformed `in_reply_to_id` is a stop, not a reply.
Ask Copilot:

```bash
# THE PHASE IS A SCRIPT, IN THREE STAGES with the operator's decision at each
# boundary. It was 176 lines here that nothing executed, and `close` a further 93.
# Issues #26, #78.
#
#   pr-copilot-phase.sh record N "$SUMMARY_FILE"   # prove, record, then ask
#   pr-copilot-phase.sh open   N "$CODEX_SHA"      # only on the answer (b)
#   pr-copilot-phase.sh close  N "$CODEX_SHA" "$REVIEWERS"   # step 8: Copilot clean
#
#     0  recorded / opened / closed
#     1  stopped — the reason is on stdout; the phase did NOT advance
#     3  paused  — a round boundary. Decide with the operator
#
# WRITE THE ACCOUNT FIRST: one paragraph on what the PR does and what the Codex
# phase changed. If Codex approved on the first pass with no fix rounds, say that
# — it is the difference between "nothing was found" and "everything found was
# addressed". Everything a machine reads back is composed by the script: the
# signoff marker in the form `pr-signoff.sh` scans for, the sha, and the trailer
# note. The body is inserted as DATA, so prose quoting a command line is posted
# rather than executed.
# THE BODY IS PROSE AND MUST NOT BECOME A RECORD. It is posted under your
# identity, which `pr-signoff.sh` and `pr-round-count.sh` trust, so a line
# reproducing one of the markers they honour FROM YOU — `**Review-Signoff:**`,
# `**Review-Signoff-Revoked:**`, `**Review-Pause-Acknowledged:**` — CREATES the
# record it was quoting. `**Reviewed commit:**` is NOT one of them: it is read
# only from a reviewer bot's own comment, so writing it here creates nothing and
# is left alone. The script refuses
# one rather than publishing it. They are only honoured at the start of a line, so
# indent by four spaces or quote inline. A FENCE DOES NOT HELP — the readers scan
# the raw body, where a line inside a fence still starts at column 0.
#
# AND IT MUST NOT CONTAIN `@codex review`. Any comment containing that text
# requests a Codex pass; this summary is posted on its own and the loop stops
# right after it, so a quoted mention starts a pass that answers nobody. The
# script refuses one. In a Codex ROUND the mention is the request and
# `pr-close-round.sh` writes it itself, so quoting it there changes nothing.
#
# THE REMEDY IS NOT THE SAME ONE. That trigger is matched case-insensitively
# ANYWHERE in the body, not at the start of a line — so indenting it, quoting it
# inline or fencing it changes nothing and the summary is still refused. Break the
# mention up, or write it without the `@`.
#
# THE WRITE IS CHECKED, not only the read the script does. A redirection that
# truncates the file and then fails — a full filesystem — leaves a non-empty
# FRAGMENT that passes the script's own non-empty test and is posted as this
# phase's account; a failed open leaves the PREVIOUS round's contents there to be
# posted as this one's.
cat > "$SUMMARY_FILE" <<'EOF' || { echo "ABORT: could not write the phase body."; exit 1; }
<what the PR does, and what the Codex phase changed — one paragraph>
EOF
# WHICH REPOSITORY THIS ACTS ON IS SETTLED IN THE SETUP BLOCK, not here. The
# session's origin is read once and exported as `REVIEW_BUS_REMOTE`, which this
# stage and everything it drives inherit — so this call has no cwd dependency and
# needs no wrapper. Do not add one: a `(cd … && …)` guard here is what the pin
# replaced, and `cd` is a name a function can take.
PHASE_OUT="$("$RB_SCRIPTS"/pr-copilot-phase.sh record N "$SUMMARY_FILE" 2>&1)"; PHASE_RC=$?
printf '%s\n' "$PHASE_OUT"
case "$PHASE_RC" in
    0|3) ;;   # 3 is a pause, and the signoff is recorded either way
    *) echo "The phase did not advance and no signoff was recorded. The reason is above; do not retry it blind."; exit "$PHASE_RC" ;;
esac
# THE SIGNED-OFF HEAD IS THE ONE VALUE THAT OUTLIVES THIS STEP. Step 8 needs the
# full 40 characters of it, and a child cannot assign a variable here — so it
# reports the value and this reads it back. A later session, which has no shell
# left to read, gets it from `pr-signoff.sh` instead.
#
# READ ON THE PAUSE TOO. The boundary message offers "merge on the Codex signoff",
# and that path needs this sha: exiting without it made the operator re-run a
# phase that had already been proved clean, just to recover a value that was
# printed and thrown away.
#
# EXACTLY FORTY HEX, AND THE LAST RECORD, which is the rule the resume parser at
# the bottom of this file already applies to `PR_SIGNOFF`. Here it was
# `[0-9a-f]*`: `codex-sha=a` is non-empty, so the emptiness test below passed and
# step 8 was handed something that is not a commit — and two matching records put
# two lines in one variable, which no gate downstream can mean anything by. The
# same rule written twice with one copy right is what `CLAUDE.md` says belongs in
# one place; this is the copy that was wrong. Issue #39.
#
# NO COMMAND AT ALL, WHICH IS THE ONLY WAY TO STOP LOSING THIS ARGUMENT. A `sed`
# or `tail` that prints a plausible forty hex and then fails leaves that value in
# a substitution, where a shape check reads it as a good parse — so the status has
# to be taken. `set -o pipefail` took it, and `set` is a builtin a function can
# shadow. `awk` took it in one process, and `awk` is a command a function can
# shadow: one returning a stale sha and exiting 0 is accepted whatever the record
# says.
#
# `CLAUDE.md` states the way out rather than the next name to distrust: prefer a
# RESERVED WORD or an ASSIGNMENT, which the parser handles and no function can
# take the place of. `while`, `if` and `[[` are reserved; `${…}` is expansion.
# This loop uses nothing else, so there is no status to lose and nothing to
# shadow — the value can only come from `$PHASE_OUT`.
#
# PEELED WITH EXPANSIONS RATHER THAN SPLIT ON IFS: `for x in $PHASE_OUT` would
# also glob, so a record containing `*` would expand against the filesystem, and
# suppressing that needs `set -f` — the builtin this paragraph exists to avoid.
#
# EVERY RECORD OVERWRITES THE ANSWER, so the newest one decides even when it is
# the unreadable one. Keeping only sha-shaped records left a valid record followed
# by a malformed one returning the earlier head: a stale answer, offered exactly
# when the latest record could not be read.
CODEX_SHA=""
_rb_rest="$PHASE_OUT"
while [[ -n $_rb_rest ]]; do
    _rb_line="${_rb_rest%%$'\n'*}"
    if [[ $_rb_rest == *$'\n'* ]]; then _rb_rest="${_rb_rest#*$'\n'}"; else _rb_rest=""; fi
    # EVERY PHASE RECORD OVERWRITES, INCLUDING ONE WITH NO FIELD AT ALL. Matching
    # only records that carry `codex-sha=` left a truncated record — a line that
    # is a phase record and says nothing about the head — unable to overwrite
    # anything, so the previous record's head stood. That is the stale answer
    # again, by the one route the earlier fix did not close: the field missing
    # rather than malformed.
    #
    # DELIMITED BY WHITESPACE, so `xcodex-sha=` is not the field.
    # THE BARE MARKER IS A PHASE RECORD TOO. A line truncated to exactly
    # `PR_PHASE_RECORDED`, with no trailing space, did not match — so it could not
    # reset the candidate, and the previous record's head stood. Same staleness,
    # one character further along than the last one.
    if [[ $_rb_line == PR_PHASE_RECORDED || $_rb_line == PR_PHASE_RECORDED\ * ]]; then
        _rb_v=""
        # THE DELIMITER IS IN THE REMOVAL PATTERN TOO, not only in the test above
        # it. `##*codex-sha=` is greedy, so on
        # `codex-sha=a xcodex-sha=<40 hex>` it took the value after the LATER
        # substring: the condition saw the real field, the extraction read a
        # different one, and the shape check accepted a sha that was never the
        # `codex-sha` field at all.
        if [[ $_rb_line == *[[:space:]]codex-sha=* ]]; then
            _rb_v="${_rb_line##*[[:space:]]codex-sha=}"
            _rb_v="${_rb_v%%[[:space:]]*}"
        fi
        CODEX_SHA="$_rb_v"
    fi
done
# WHAT USES THE HEAD SITS INSIDE THE SUCCESSFUL BRANCH, rather than after a guard
# that aborts. The guard aborted with `exit`, and `exit` is a builtin a function
# can shadow: `exit() { return 0; }` turns the refusal into a `return`, execution
# carries on, and the malformed head this check exists to stop is used by
# everything after it. Reachability is structural and cannot be shadowed;
# `if`, `else` and `[[` are reserved words.
RX_PHASE_SHA40='^[0-9a-f]{40}$'
if [[ "$CODEX_SHA" =~ $RX_PHASE_SHA40 ]]; then
    # AN `if`, NOT A TRAILING `&&`. This is the last command in the block, so its
    # status IS the block's status — and `[ 0 -eq 3 ] && …` is FALSE on the
    # ordinary path, which left a phase that recorded and parsed perfectly exiting
    # 1. A driver reads that as a failed step and stops or retries instead of
    # reaching the operator decision, on the one path where nothing went wrong.
    if [ "$PHASE_RC" -eq 3 ]; then
        echo "Stopping here: the operator decides at a round boundary. Codex is signed off on $CODEX_SHA, so merging on that signoff is one of the answers."
        exit 3
    fi
else
    echo "ABORT: the phase recorded no full 40-hex head; step 8 would have nothing to gate on ('$PHASE_OUT')"
    exit 1
    # THE LAST WORD IS A RESERVED ONE, because both lines above it can be taken
    # away. `echo` and `exit` are builtins a function can shadow, and with both
    # shadowed this branch says nothing and returns 0 — a failed parse
    # indistinguishable from an ordinary phase, which is the reading that lets the
    # driver carry on. `[[ … ]]` is a reserved word, so this branch ends non-zero
    # whatever has been done to the builtins, and the block's status is the last
    # signal left.
    [[ -n "" ]]
fi
```

**STOP — the next phase is the operator's decision.** `record` has proved Codex
clean on an exact head, proved that head's checks, and written the signoff onto
the PR. What happens next is not the loop's call to make:

- **merge now** — one reviewer's clean signoff is a legitimate place to stop, and
  for a small or urgent change it is often the right one. Run step 8 with
  `REVIEWERS=codex-only`, which requires the head to BE `$CODEX_SHA` and is
  therefore a narrower gate than the two-reviewer one, not a looser one;
- **open the Copilot phase** — a second, differently-trained reviewer over the
  same head. It costs rounds, and it finds things Codex does not.

Ask, then stop. Do not open the phase because the loop happens to continue in
that direction: every Copilot pass costs a round of somebody's attention, and the
phase this opens can run as long as the one just finished. It is resumable either
way — the signoff is on the PR, so a later session reads it back with
`pr-signoff.sh` rather than needing this shell.

```bash
# ── ONLY ON (b) ────────────────────────────────────────────────────────────
# Everything here runs when the operator has asked for the Copilot phase, and only
# then. `open` PROVES THE PHASE IS STILL OPEN before it changes anything, and all
# three parts are needed because none of them requires the head to move:
#
#   · the head is unmoved;
#   · Codex's LIVE verdict on that sha is clean — a recorded signoff is history,
#     and a review dismissed while the head stood still leaves head-equality
#     passing;
#   · the RECORDED Codex signoff still names it — a revocation is how a phase is
#     deliberately reopened, and GitHub serves the old clean verdict until the new
#     pass reports, so the verdict alone cannot see it.
#
# It re-enforces the ROUND BOUNDARY too, which is why `open` can return 3: the
# signoff is published before `record` pauses, so a later session can resume
# straight into this stage with the boundary unacknowledged.
#
# ALL OF IT RUNS THREE TIMES — up front, before the revocation, and again after
# it — because another session can change any of it while the probes in between
# are running, and the revocation is itself a mutation with the request still to
# come.
#
# THE ORDER IS revoke → prove → baseline → request. Two constraints pull against
# each other: the proof wants to be last, and the Copilot BASELINE must be last or
# a pass landing in between is accepted as the answer to a request made after it.
# This is the proof as late as the baseline rule allows.
# THE SESSION PIN COVERS THIS STAGE TOO, and it is the one where getting the
# repository wrong costs most: `open` posts a signoff revocation and requests a
# review. Both are inherited from the setup export rather than decided by the
# current directory, so there is nothing to wrap here either.
OPEN_OUT="$("$RB_SCRIPTS"/pr-copilot-phase.sh open N "$CODEX_SHA" 2>&1)"; OPEN_RC=$?
printf '%s\n' "$OPEN_OUT"
[ "$OPEN_RC" -eq 0 ] \
    || { echo "The Copilot phase did not open. This is not permission to skip the pass: decide with the operator."; exit "$OPEN_RC"; }
WHO="$COPILOT_BOT"
# THE BASELINE COMES BACK IN THE SUCCESS RECORD, and the RECORD is what is checked
# — not the value. A head with no Copilot review yet has no id, and `pr-watch.sh`
# takes an empty baseline as "wait on any terminal review"; testing the value for
# emptiness would abort here, after the pass has already been requested.
OPEN_REC="$(printf '%s\n' "$OPEN_OUT" | sed -n '/^PR_COPILOT_PHASE_OPENED /p' | tail -1)"
[ -n "$OPEN_REC" ] \
    || { echo "ABORT: the phase opened without reporting a record; step 3 would watch against a stale baseline."; exit 1; }
case "$OPEN_REC" in
    *' prior-review='*) ;;
    *) echo "ABORT: the record carries no baseline field; step 3 would watch against a stale one."; exit 1 ;;
esac
PRIOR_REVIEW="${OPEN_REC##* prior-review=}"
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

### First: record the Copilot signoff, then STOP and ask

Reaching a clean Copilot verdict is the end of the review work, not the start of
a merge. Record it, then put the decision to the operator — the same shape as the
end of the Codex phase, for the same reason.

```bash
# ── ONLY WHEN THERE WAS A COPILOT PHASE ────────────────────────────────────
#
# Set REVIEWERS to what was decided at the Codex stop, before running any of
# step 8. `codex-only` means no Copilot review was ever requested, so there is no
# verdict to re-check and no second signoff to record — the stage says so and
# does nothing, which is not the same as skipping it.
#
# `$CODEX_SHA` is passed as well as the head being read, because whether the two
# are EQUAL decides which question the stop asks: the fault-tolerance pass is
# offered only where the Copilot phase produced commits.
REVIEWERS=both   # or `codex-only`
# THE SESSION PIN SETTLES THE REPOSITORY HERE AS WELL. The merge gate below still
# runs from `$REPO_DIR`, and that is a different question: it hands
# `pr-merge-range.sh` a tree to inspect, which the pin says nothing about.
"$RB_SCRIPTS"/pr-copilot-phase.sh close N "$CODEX_SHA" "$REVIEWERS"
CLOSE_RC=$?
# `[[`, A RESERVED WORD, NOT `[`. This runs in the driving session's own shell,
# which is long-lived and where a function named `[` can already exist — it
# shadows the builtin and the `command`/`builtin` prefixes alike. One returning
# success turns a failed close into a successful one, and the driver carries on
# with no signoff recorded and no operator stop. A shadowed `exit` neutralises the
# abort the same way, so the branch ends with a structural sentinel that is
# non-zero whatever `echo` and `exit` have been replaced with.
if [[ $CLOSE_RC -ne 0 ]]; then
    echo "The Copilot phase did not close and no signoff was recorded. The reason is above; do not retry it blind."
    exit "$CLOSE_RC"
    [[ -n "" ]]
fi
```

It prints the record it made and then the stop:

```
PR_COPILOT_PHASE_CLOSED pr=N reviewer=<copilot> copilot-sha=<sha> codex-sha=<sha>
```

**On the two-reviewer path, STOP. MERGING IS THE OPERATOR'S DECISION.** The
stage prints a menu and asks; do not run the merge gate until the operator has
answered. Merging is the largest irreversible action this tool takes, and "every
gate passed" is an input to that decision rather than the decision itself.

**In `codex-only` there is no second question.** No Copilot review was ever
requested, so the stage records nothing and prints no menu — and the decision this
stop exists to collect was already taken at the Codex stop, where "merge now on
Codex's signoff alone" is what selected the mode. Go straight to the merge gate.
Waiting here would be waiting for an answer to a question nobody was asked.

**Read the two shas rather than assuming them.** Where they are the same commit,
Codex has already reviewed exactly what is being merged and no fault-tolerance
pass is offered — taking one there costs a revocation, a round and a reopened
phase for a verdict that cannot differ, and a session resuming into the reopened
phase reads it as a Copilot phase to run again. That is what #55 was raised for.
Where they differ, the older Codex result is carried forward only if the merge
gate validates that every commit between them is a `Review-Phase: copilot` fix.

### Resuming after a stop

A later session — tomorrow, another machine — has none of the variables the stop
was reached with. This is the recipe that restores them. Run it before step 8, or
before continuing into the Copilot phase.

```bash
# THE STATUSES ARE DISTINGUISHED, because they mean different things and only one
# of them is permission to continue:
#
#   0  a signoff exists — use the sha it names
#   1  none recorded — the phase is NOT closed. Do not invent one; go and run it
#   2  could not tell — fail closed. An unreadable answer is not "no signoff",
#      and treating it as one repeats a phase; treating it as a signoff skips a
#      review nobody did
SIGNOFF_OUT="$("$RB_SCRIPTS"/pr-signoff.sh N "$CODEX_BOT" 2>&1)"; SIGNOFF_RC=$?
case "$SIGNOFF_RC" in
    0) ;;
    1) echo "The Codex phase is not closed on this PR — there is no recorded signoff. Run it before merging or opening the Copilot phase."; exit 0 ;;
    *) echo "ABORT: could not read the signoff record (rc=$SIGNOFF_RC): $SIGNOFF_OUT"; exit 0 ;;
esac
# PARSED, not substring-matched, and the shape is checked before it is used: this
# value is what every gate in step 8 is evaluated against, so a truncated or
# wrapped line must not become the sha a merge is pinned to.
CODEX_SHA="$(printf '%s\n' "$SIGNOFF_OUT" \
    | sed -n 's/^PR_SIGNOFF .*[[:space:]]sha=\([0-9a-f]\{40\}\)$/\1/p')"
RX_SHA40='^[0-9a-f]{40}$'
if ! [[ "$CODEX_SHA" =~ $RX_SHA40 ]]; then
    echo "ABORT: the recorded signoff did not yield a full 40-hex sha ('$SIGNOFF_OUT')"; exit 0
fi
# THE RECORD IS HISTORY, NOT A CURRENT FACT. It says Codex was clean on that
# commit when it was written — not that the commit is still the head, nor that the
# review still stands. A dismissal, or a push while the stop was parked, leaves
# the marker exactly as it was; continuing on it opens a Copilot phase against a
# head Codex never approved, and the whole loop is spent before the merge gate
# finally refuses.
#
# So the resumed value is re-validated against the world as it is now, and BOTH
# halves matter: the head must still be that commit, and the verdict must still
# be clean on it.
RESUMED_HEAD=$(gh pr view N --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not read the head to check the resumed signoff against"; exit 0; }
# WHICH STOP IS BEING RESUMED FROM decides what "still valid" means, and the two
# answers are opposite. Before the Copilot phase, the Codex signoff is the only
# thing licensing a merge, so the head must still BE that commit. AFTER it, the
# head has advanced through Copilot fixes BY DESIGN — the merge gate accepts that
# delta once it has checked the `Review-Phase: copilot` trailers — and demanding
# equality there rejects the very state the second stop exists in.
#
# A recorded COPILOT signoff is what tells the two apart, and it is a fact on the
# PR rather than a guess about the session.
COPILOT_SIGNOFF_OUT="$("$RB_SCRIPTS"/pr-signoff.sh N "$COPILOT_BOT" 2>&1)"; COPILOT_SIGNOFF_RC=$?
case "$COPILOT_SIGNOFF_RC" in
    0|1) ;;
    *) echo "ABORT: could not read the Copilot signoff record (rc=$COPILOT_SIGNOFF_RC): $COPILOT_SIGNOFF_OUT"; exit 0 ;;
esac
COPILOT_SHA="$(printf '%s\n' "$COPILOT_SIGNOFF_OUT" \
    | sed -n 's/^PR_SIGNOFF .*[[:space:]]sha=\([0-9a-f]\{40\}\)$/\1/p')"
# THE BRANCH TURNS ON WHICH SIGNOFF DESCRIBES THE HEAD, not on whether a Copilot
# record exists at all. After "another Codex pass" produced fixes, the NEW Codex
# signoff names the current head while an older Copilot signoff still names the
# previous one — and choosing the post-Copilot path merely because that historical
# record exists then reported that neither phase was closed, sending the operator
# through a review nobody needed.
if [ "$COPILOT_SIGNOFF_RC" -eq 0 ] && [ "$COPILOT_SHA" = "$RESUMED_HEAD" ]; then
    # RESUMING AFTER THE COPILOT PHASE. The Codex signoff is deliberately older
    # than the head; the gate is what proves the delta is Copilot-only. What must
    # still hold is the COPILOT signoff, on the head being merged.
    RESUMED_VERDICT=$("$RB_SCRIPTS"/pr-review-state.sh verdict N "$COPILOT_BOT" "$COPILOT_SHA"); RESUMED_RC=$?
    if [ "$RESUMED_RC" -ne 0 ]; then
        echo "Copilot's recorded signoff no longer stands ($RESUMED_VERDICT) — a review can be dismissed after it was written."
        echo "Treat the Copilot phase as open: request a review before merging."
        exit 0
    fi
    echo "Resumed after the Copilot phase: Codex on $CODEX_SHA, Copilot on $COPILOT_SHA, both still standing."
else
    # RESUMING BEFORE THE COPILOT PHASE — or in `codex-only`, where there will
    # never be one. Nothing licenses a delta here, so the head must still BE the
    # commit Codex signed.
    if [ "$RESUMED_HEAD" != "$CODEX_SHA" ]; then
        echo "The head has moved since that signoff (head=$RESUMED_HEAD signed=$CODEX_SHA)."
        echo "The Codex phase is NOT closed on this head: request a review of it before merging or opening the Copilot phase."
        exit 0
    fi
    RESUMED_VERDICT=$("$RB_SCRIPTS"/pr-review-state.sh verdict N "$CODEX_BOT" "$CODEX_SHA"); RESUMED_RC=$?
    if [ "$RESUMED_RC" -ne 0 ]; then
        echo "The recorded signoff no longer stands ($RESUMED_VERDICT) — a review can be dismissed after it was written."
        echo "Treat the Codex phase as open: request a review before merging or opening the Copilot phase."
        exit 0
    fi
    echo "Resumed: Codex signed off on $CODEX_SHA, and that still holds on the current head."
fi
```

### Then: the gate

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
# REVIEWERS IS `both` UNLESS THE OPERATOR CHOSE OTHERWISE at the stop that closed
# the Codex phase. `codex-only` is not a weaker gate: it drops Copilot's verdict
# and in exchange requires the head to BE the commit Codex signed, because the
# `Review-Phase: copilot` trailers that license a moved head do not exist when
# there was no Copilot phase.
(cd "$REPO_DIR" && "$RB_SCRIPTS"/pr-merge-gate.sh N "$CODEX_SHA" "$AUTO_REVIEW" "$REVIEWERS")
MERGE_RC=$?
case "$MERGE_RC" in
    0) ;;   # merged; the script printed the head it pinned
    3) echo "Stopping here: the operator decides whether to merge at a round boundary." ;;
    4) echo "NOT merged: the request was accepted but the PR is not MERGED — a merge queue takes the request without landing it. Do not close this out; confirm on the PR." ;;
    *) echo "Not merged. The reason is above; do not retry it blind." ;;
esac
# THE STATUS LEAVES THIS BLOCK. Every arm above ends in an `echo`, whose status is
# 0 — so without this the block reports success for a blocked, paused or queued
# merge, and whatever runs it next carries on as though the PR had landed. The
# distinction the gate exists to draw survives only if it is passed on.
exit "$MERGE_RC"
```

If any gate fails, do **not** merge. Post the reason on the PR and hand it back
to the operator.

## What this skill deliberately does not do

- **It does not run a reviewer.** Codex and Copilot are GitHub apps; a local
  process reviewing PRs duplicates them, authors its comments as the repository
  owner rather than as a bot, and consumes a separate credit pool.
- **It does not merge unattended past a failed or unreadable gate.** Every
  "cannot tell" is a stop.
