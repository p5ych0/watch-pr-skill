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
# THE TRACE IS MOVED OFF THE CAPTURE, BEFORE ANY `$( )` RUNS. `BASH_XTRACEFD=1`
# sends xtrace to file descriptor 1 — and inside `X="$(cmd)"` fd 1 IS the capture,
# so the trace of `cmd` is assigned to `X` along with its output. Measured:
#
#   SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c 'X="$(printf hello)"; echo "[$X]"'
#   [++ printf hello
#   hello]
#
# Every substitution in this block is affected — the repository root, the plugin
# discovery, the `mktemp`, the `type -t` probe — so it is one property of the
# block rather than a defect in any line. The validations below then reject the
# corrupted values and setup aborts, which fails closed but ends a session that
# had nothing wrong with it. Issue #92.
#
# AN ASSIGNMENT, BECAUSE `set +x` IS A NAME. `set` is a builtin and a function can
# shadow it, so a guard written that way leaves tracing on in the one shell state
# it exists for. The parser handles an assignment and no function can take its
# place — and this one needs no `unset`, which is the operation that would be
# unsafe: bash CLOSES the descriptor `BASH_XTRACEFD` referred to when it is unset
# or set to the empty string, so `BASH_XTRACEFD=` closes fd 1 outright. Measured
# both ways on bash 5: `BASH_XTRACEFD=2` leaves fd 1 open and the capture clean;
# `BASH_XTRACEFD=` kills the shell's stdout.
#
# IT MOVES THE TRACE RATHER THAN ENDING IT. `set +x` would take the operator's
# diagnostics away for the rest of their session; fd 2 is where bash sends xtrace
# by default, so this puts it back where it belongs and the operator still sees
# every line.
#
# NORMALLY ONLY WHEN THE TARGET IS THE CAPTURE. A session tracing to stderr, or
# to a log file on some other descriptor, writes nothing into the probe's capture,
# so the condition is false and it is left as it was — `[[` is a reserved word, so
# the test cannot be shadowed either. On bash 3.2 `BASH_XTRACEFD` does not exist,
# the trace goes to stderr whatever this says, and the condition is false there
# too.
#
# THE EXCEPTION IS THE ACCEPTED FALSE POSITIVE, described below and repeated here
# because this is the paragraph a maintainer reads as the postcondition: where
# something ELSE writes into that capture — an inherited `DEBUG` trap under
# `set -T` is the only thing that can — a log-file target IS moved to fd 2. That
# session's captures are corrupted by the trap regardless and setup refuses
# further down, so this is not a postcondition to preserve.
#
# THE SUBSHELL IS A WRITABILITY PROBE, AND IT IS THERE FOR `set -e`. A readonly
# `BASH_XTRACEFD` makes the assignment a FATAL error, not an ordinary failure: it
# is not caught by `||`, not caught by an `if` around it, and under `errexit` it
# ends the operator's long-lived shell where the documented outcome is a refusal
# further down. Measured — all three forms exit 1 with the same message.
#
# So the assignment is attempted in a subshell first, where that fatality is
# confined, and its STATUS decides whether the real one runs. `( … )` is a parser
# construct and an assignment is a parser construct, so the probe introduces no
# name; a condition of `&&` is exempt from `errexit`, so a failing probe is a
# skip rather than an exit. Where the variable is readonly the block does nothing
# and the session behaves as it did before this guard existed.
#
# NO POSTCONDITION ON THE REAL ASSIGNMENT, AND THAT IS DELIBERATE. Its other
# failure mode is fd 2 not being open, and there bash takes the VALUE and rejects
# it as a trace target, so there is no status to take and nothing to do: the trace
# stays on stdout, the next capture is corrupted, its validation rejects it, and
# setup stops. What the extra check WOULD add is another abort
# reached through `exit` — a builtin a function shadows, so under
# `exit() { return 0; }` it announces the refusal and continues anyway, with
# tracing still aimed at every capture. That is the boundary #101 and #102 are
# open on, and it is not one this line should quietly take a position on. The
# guard is removed rather than hardened.
#
# STDOUT IS NOT TOUCHED BY THIS. bash closes the descriptor `BASH_XTRACEFD`
# referred to when it is UNSET or set to the empty string; a reassignment closes
# nothing, and that is not a 5.3 behaviour: `sv_xtracefd` calls `xtrace_reset` —
# the only path that closes — when the variable is UNSET or its value is EMPTY,
# and takes `xtrace_set` for a valid descriptor, which replaces the target without
# closing the old one. Measured on 4.4.0, 5.2.0 and 5.3.9, each built and run for
# this: after `BASH_XTRACEFD=1` → `2`, ordinary
# `printf` output still arrives on fd 1 and `exec 3>&1` still succeeds, while
# `BASH_XTRACEFD=` produces no further output at all. `test-pr-skill-contract.sh`
# asserts that on whatever bash runs the suite rather than trusting the version
# this was measured on.
# THE TEST IS THE EFFECT, NOT THE VALUE. `$( RB_TRACE_PROBE=1 )` puts one
# assignment inside a capture: if this shell's trace lands there, the capture
# comes back holding the trace of it, and if it does not, the capture is empty.
# That is the exact property this guard exists for, measured directly. Why an
# assignment rather than a command is two paragraphs down; the shape of the test
# is the same either way.
#
# COMPARING THE VARIABLE TO `1` WAS WRONG BY OMISSION, twice over. bash resolves
# `01`, `+1` and ` 1` to descriptor 1 and a string compare misses all three —
# measured. And the value is not the property anyway: an operator who runs
# `exec 9>&1; BASH_XTRACEFD=9` has aimed the trace at a descriptor that is not
# `1`, and one who traces to a log file has aimed it at one that is not the
# capture either. A test on the number has to enumerate which descriptors alias
# stdout, which is the list-that-is-wrong-by-omission shape this repository keeps
# deleting. There is no list here.
#
# IT SUBSUMES THE `x` CHECK TOO. With tracing off nothing is written, the capture
# is empty, and a session that set `BASH_XTRACEFD` ready for a later `set -x`
# keeps the destination it chose.
#
# AN ASSIGNMENT INSIDE THE CAPTURE, BECAUSE EVERY COMMAND IS A NAME. `$( : )` was
# the first spelling and it is wrong: a driving shell with `:() { printf marker; }`
# makes the capture non-empty through the function's own output. An assignment is
# handled by the parser, produces no output of its own, and is traced like any
# other command. It runs in the substitution's subshell, so the variable does not
# survive it.
#
# AND THE TEST IS FOR SOMETHING ONLY XTRACE CAN WRITE. Non-empty was the second
# spelling and the probe's own text was the third, and both are wrong for the same
# reason one step further out: a `DEBUG` trap under `set -T` is inherited by the
# substitution's subshell, so a trap that prints lands in the capture while xtrace
# itself is still going somewhere else entirely. `trap 'printf "%s\n"
# "$BASH_COMMAND"' DEBUG` prints exactly the probe's text, so matching that
# literal cannot establish where it came from.
#
# SO THE TEST IS "DID ANYTHING COME BACK", AND THE ASYMMETRY BELOW IS WHAT MAKES
# THAT ACCEPTABLE. Marker schemes were tried — the probe's own text, then a pid
# delivered through `PS4` — and each was forged by the next trap: `$BASH_COMMAND`
# reproduces the command exactly, and `printf "%s:" "$$"` produces the pid. A trap
# can emit any bytes, so no content test can prove provenance, and each sharper
# marker added a way to MISS: an operator with `readonly PS4` made the pid scheme
# blind, which is the harmful direction — the trace stays on stdout, every capture
# is corrupted, and a perfectly good checkout is refused.
#
# THE TWO DIRECTIONS ARE NOT SYMMETRIC, and that is the whole argument. A false
# positive sends the trace to fd 2, which is where bash sends xtrace by default,
# so every line still arrives. A false negative leaves it on stdout, corrupts
# every capture below and aborts the session. So the test is the one that cannot
# miss.
#
# A DRIVING SHELL WITH NO STDERR IS OUT OF THIS GUARD'S REACH, and that is stated
# rather than pretended away. With fd 2 closed, `BASH_XTRACEFD=2` is rejected by
# bash as an invalid descriptor — the variable takes the value and the trace stays
# on stdout — so the captures below are contaminated exactly as before. There is
# no other target to choose: every descriptor that is not the capture is one this
# block would have to open, and the one place a trace belongs is the standard
# error that shell does not have. The consequence is the fail-closed one: a
# corrupted `REPO_DIR` is not a directory, so the first thing that uses it
# refuses, and no stage runs against a path that was never read.
#
# WHERE OTHER OUTPUT REALLY DOES ARRIVE IN CAPTURES, this guard is not the cure
# and does not pretend to be: a `DEBUG` trap that prints corrupts every capture in
# this block, moving the trace fixes none of them, and setup refuses further down.
# The session ends either way; what this line decides is only where the trace goes
# on the way out.
#
# AND NOTHING IS SAVED, BECAUSE THE SAVE IS WHAT A HOSTILE SHELL ATTACKS. Three
# successive rounds found the same shape and it has no fixed point: a startup file
# pre-seeds `RB_XTRACE_SAVED` — or the flag added to validate it — as `readonly`,
# both assignments here fail silently, and the restore then aims the operator's
# trace at a descriptor that startup file chose. Making the flag's value the pid
# does not help: that file runs in THIS shell, so `$$` is as knowable to it as to
# this line. Any state this block writes can be pre-seeded with the value it was
# going to write.
#
# SO THERE IS NO STATE. The trace is moved when it is reaching a capture and left
# on fd 2 — which is where bash sends xtrace by default, so every line still
# arrives and nothing is lost. What the removed restore bought was tidiness after
# a MIS-FIRE, and a mis-fire needs something else writing into that capture. Only
# a `DEBUG` trap inherited under `set -T` can: the probe runs no command, so there
# is no function for a shadowed name to supply. Such a shell has
# already corrupted every capture in this block, so setup refuses further down and
# the session ends either way. Trading that for an unbounded regress of collision
# guards is the over-building this file's own rules warn against.
#
# WHAT IS ACCEPTED, STATED: in that shell the operator's chosen trace destination
# becomes stderr for the rest of their session. `README.md` says so, rather than
# leaving it to be discovered.
if [[ -n "$( RB_TRACE_PROBE=1 )" ]] && ( BASH_XTRACEFD=2 ) 2>/dev/null; then
    BASH_XTRACEFD=2
fi
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
# THE VALUE COMES BACK IN A FILE, NOT ON A DESCRIPTOR, and that is the third
# mechanism this call has used. Stdout was first: a driving shell tracing to fd 1
# writes its trace into the capture. fd 9 was second, with the redirections on a
# group: it moved the problem to a caller tracing to fd 9, whose target the `9>&1`
# then pointed at the capture. Moving the trace target instead was third and
# worse — bash CLOSES the descriptor `BASH_XTRACEFD` referred to when it is unset,
# so restoring it closed fd 2 and the next call in the session returned nothing.
#
# A path has none of those properties. The operator's tracing goes wherever it
# already went, the helper writes where it was told, and there is no descriptor
# for the two to collide over. Measured: `$(<file)` and `read` are both clean
# under an inherited xtrace, because nothing executes inside them to be traced.
#
# `/usr/bin/env`, A PATH, BECAUSE `bash` IS A NAME. Written as `bash -p …` this
# calls a function called `bash` if the driving shell has one — and such a function
# writes a forged URL to the file it was handed and returns, with the helper never
# running. A path cannot be shadowed. `/usr/bin/env` is the same one every script here already depends on
# through its shebang, so it is not a new assumption; which `bash` it then finds is
# a `PATH` question, and that is #91.
#
# `bash -p` STARTS THE FIRST INTERPRETER PROTECTED, and it has to be the first:
# privileged mode is what stops `BASH_ENV` being sourced at all, so entering it
# from inside a shell that has already run the hook is too late. A hook needs to
# shadow nothing to win that race: one that writes the transport file and exits is
# a complete attack. There is no fallback inside the helper: it is not executable,
# it carries no re-exec, and a missing `-p` is refused — by then the hook has
# already run, so nothing in the file can recover from it.
#
# READ THROUGH A HELPER, BY PATH, BECAUSE `git` IS A NAME. This was
# `git remote get-url origin` here, and a function answering only
# `remote get-url origin` forged the identity every stage is then addressed by —
# successfully, with a plausible value. `"$RB_SCRIPTS"/pr-origin.sh` is a PATH, so
# no function can stand in front of it, and `bash -p` means no startup hook is
# sourced and no inherited function is imported in the first place. #84.
# THE TRANSPORT IS A DIRECTORY, AND THE HELPER IS WHAT CREATES IT. `watch-pr-origin.$$`
# was a FILE this setup named and the helper truncated, and that name is
# predictable from another account on the machine: pre-created as a world-writable
# file or as a symlink, the helper wrote through it and the value read back — the
# one every later signoff, revocation and review request is addressed by — was
# whatever that account left there. A directory created with `mkdir` answers it,
# because `mkdir` FAILS if the name exists: a directory, a file and a symlink
# alike. That exclusion is the helper's since #157, along with the ancestry walk
# and the write, so all three run privileged, where `mkdir` is not a name an
# operator's startup file can replace.
#
# TWO DIRECTORIES, NOT ONE, AND EACH GONE AS SOON AS ITS VALUE IS READ. The origin
# read and the pin probe are separate calls at separate times, and the second is
# behind the first's success; sharing one directory would mean keeping it open
# across the whole of setup for no gain. `-m 700` is applied by `mkdir` itself, so
# there is no interval between creation and use in which anything can be placed
# inside.
#
# THE PATH IS BUILT, NOT CAPTURED. `$(mktemp -d)` would name the directory in one
# line, and a driving shell tracing to fd 1 would put the trace of `mktemp` inside
# the value — so the variable holds trace text and a path, and the helper cannot
# open it. `$$` and `$RANDOM` are the shell's own, so nothing runs and there is
# nothing to trace. Three `$RANDOM` draws make the name unguessable enough that
# nobody can hold the session open by squatting it; the exclusion, not the
# randomness, is what makes a guess harmless.
#
# THE PARENT HAS TO BE ONE NOBODY ELSE CAN REPLACE THE DIRECTORY IN, and mode 700
# does not give that. It protects what is INSIDE the directory; it says nothing
# about the entry naming it. On a shared `TMPDIR` that another account can write
# and search and that lacks the sticky bit, that account can watch for the name,
# RENAME the directory without ever entering it, and put a writable one of its own
# at the same path — after which the helper writes `origin` into the replacement
# and the value read back is theirs. The random suffix stops the name being
# pre-created and does nothing about it being observed and then replaced.
#
# WHO MAY RENAME THE DIRECTORY IS THE QUESTION, AND THE HELPER ANSWERS IT. Checking
# a path and then opening it are two operations on a name, and whoever controls the
# directory controls what the name means in between. That rule lives in
# `pr-origin.sh`, which walks the whole ancestry as written and as it resolves —
# ownership, group- and world-writability without the sticky bit, and the `+`/`@`
# marks that show an ACL the mode bits do not. It is NOT the same as "owned by this
# user": root-owned and sticky — `/tmp` — is safe, and an attacker-owned sticky
# directory is not, because sticky says nothing about its OWNER renaming ours.
#
# WHAT IS DECIDED HERE IS ONLY WHETHER A PARENT CAN BE TRIED AT ALL. Absolute,
# because a relative path cannot be walked to the root and the helper refuses one —
# and a relative but perfectly usable `TMPDIR` such as `.tmp` selected here and
# refused there ended a session that had a working fallback next to it. A
# directory, because a name that is not one cannot hold a transport. Writable and
# searchable, because "can hold a directory" is what the fallback to `HOME` is FOR
# and `-d` does not answer it: `/usr` satisfies `-d`, was committed to, and the
# helper's `mkdir` then failed. None of the four is a SAFETY rule; the safety rules
# are the helper's, in one place, and this stopped deciding them after an owned
# mode-0777 `TMPDIR` passed an `-O` test here and was rejected there.
#
# SO AN ANCESTRY REFUSAL IS REPORTED, NOT ROUTED AROUND. The two-candidate loop
# this replaced tried `HOME` whenever the helper refused, which meant it also
# retried after a bad ORIGIN — where `HOME` is just as bad — and it could only
# work by re-asking the safety question here. A `TMPDIR` whose ancestry is unsafe
# is a state an operator has to SEE named, and the helper names which component and
# why.
#
# THE NAMES THAT ARE LEFT ARE PROVED ASSIGNABLE BEFORE ANYTHING USES THEM. There
# were five — `RB_TMPPARENT`, `RB_TRY`, `RB_TMPDIR`, `RB_ORIGIN_OUT` and
# `RB_PIN_OUT` — each with a probe and each a thing this shell had to defend; two
# remain per stage, because the helper owns the rest. A readonly or
# value-transforming one in the long-lived driving shell survives an assignment and
# leaves a STALE value behind, and a stale `/somewhere/owned` then passes every
# check: its `origin` is read as this session's remote and the cleanup deletes it.
#
# A SUBSHELL, ONE MIXED-CASE VALUE, COMPARED INSIDE. The subshell inherits the
# attribute, so a readonly fails there and a `declare -i` or `declare -l` stores
# something else and the comparison catches it — and as an `if` CONDITION the
# failure is contained, which a bare assignment is not: under `errexit` a failed
# readonly assignment ends the session where it stands. #151.
#
# AND IT READS ANOTHER NAME BACK, because reading its OWN back cannot see an
# ALIAS. `declare -n RB_ORIGIN_DIR=RB_REMOTE` passes an assign-and-read-back probe
# perfectly: the assignment works and the value returns. The two are then the SAME
# VARIABLE, so the origin read — which sets `RB_REMOTE` — silently changes
# `RB_ORIGIN_DIR` before the cleanups run. For a local origin such as
# `/tmp/victim` they remove `/tmp/victim/origin` and try to remove `/tmp/victim`.
#
# DISTINCT VALUES ARE WHAT MAKES IT VISIBLE, which is the pattern `clocklib.sh`
# already uses and states: one value says nothing about whether two names are one
# variable. `RB_REMOTE` was cleared and proved clear immediately above, so it
# holds the empty string — writing `Probe-A` here and finding it there is an
# alias, and finding it unchanged is not. Each probe checks the same way, and the
# refusal names its own variables rather than a class.
#
# WHICH PAIRS THESE COVER, STATED NARROWLY. Each stage's probe compares against
# `RB_REMOTE` and against the other name in that stage — the ones that can REDIRECT
# the read or the cleanups, which is the damage.
#
# `2>/dev/null` because a nameref loop is a message, not an answer.
# THE VALUE THIS SESSION PINS BY IS CLEARED AND PROVED CLEARED HERE, ABOVE THE
# TRANSPORT REGION AND OUTSIDE IT. A readonly `RB_REMOTE` already in the driving
# shell survives the assignment further down, and the checks after it — non-empty,
# single-line, parseable — all pass on the stale URL, which is then exported and
# addressed by every later post.
#
# ABOVE, BECAUSE A COMPOUND COMMAND TAKES THIS DIAGNOSTIC AWAY. Inside the `if`
# below, a failed readonly assignment ends the shell BEFORE the test that would
# have named the variable — measured, and caught by the suite. Nothing here needs
# the transport directory, so nothing here belongs inside it; and with the clear
# proved out here, the arm contains no assignment a startup file can have frozen.
#
# NOTHING TO CLEAN UP, EITHER. This used to sit after the directory existed, so
# its refusal removed the transport file and the directory; up here there is
# neither, which is two fewer commands taking a path from a variable.
RB_REMOTE=
# AND THE CLEAR IS A CONDITION, WITH EVERYTHING THAT DEPENDS ON THE VALUE AS ITS
# ARM. Written as a guard it prints and RETURNS once `exit` has been replaced —
# the descriptor assignment further down cannot overwrite a readonly either, and
# its refusal returns the same way, so the stale non-empty URL reaches the
# identity parser, passes it, and is exported. Every request, signoff, revocation
# and merge for that session is then addressed at a repository the operator's
# environment chose. #155.
#
# THE CLEAR ITSELF STAYS OUTSIDE IT. Inside a compound command a failed readonly
# assignment ends the shell BEFORE the test that would have named the variable —
# measured, and a containment reverted over it — so the assignment is out here
# where its own diagnostic survives, and the TEST is the condition.
#
# THE ARM RUNS TO THE END OF SETUP, because the pin is the last thing here and
# what it pins is this value. With the continuation contained there is nothing
# after the final `fi` at all.
if [[ -z $RB_REMOTE ]]; then
    # ── THE ORIGIN, READ WHERE THIS SHELL'S NAMES CANNOT REACH ────────────
    #
    # ONE NAME, ONE CALL, ONE READ. This was thirty-five lines: a two-candidate
    # loop, `RB_TMPPARENT`, `RB_TRY` and `RB_TMPDIR`, an assignability probe for
    # each with cross-variable alias checks, an exclusive `mkdir`, two cleanup
    # arms, a `${RB_TMPDIR:?…}` on every later use, and a containment arm around
    # the whole region. Every line of it defended NAMES IN THIS SHELL — which is
    # exactly what a startup file can have made readonly, `declare -i`, `declare
    # -l`, or a `declare -n` aimed at another of them. #146, #148, #150, #151 and
    # half of #155 are all that block.
    #
    # THE HELPER CREATES THE DIRECTORY NOW, and it runs `bash -p`: no functions
    # imported, no `BASH_ENV` sourced, its names its own. The exclusion is where
    # it can be relied on, so there is nothing here left to defend. #157.
    #
    # THE PARENT IS CHOSEN BY EXPANSION, and `TMPDIR` is tried before `HOME`
    # because a session that cannot write its temporary directory has bigger
    # problems than this read — but a relative or missing one is ordinary, and
    # falls through rather than ending the session.
    # THE PARENT IS CHOSEN ONCE, HERE, and the pin probe and the session's working
    # files build under the same one. It was a `for` loop over both candidates
    # with the helper's own answer as the acceptance test — which meant a bad
    # ORIGIN sent it to try `HOME`, where the origin is just as bad. What the
    # fallback is actually for is a `TMPDIR` that cannot hold a directory, and
    # that is a question two expansions answer.
    # AND BOTH NAMES ARE PROVED FIRST, because they are still names in this shell —
    # the two that are left of the five. A subshell, one mixed-case value, compared
    # inside, and `RB_REMOTE` read back to catch a nameref between them: the probe
    # each of `RB_TMPPARENT`, `RB_TRY` and `RB_TMPDIR` used to carry, now carried
    # by what remains.
    #
    # THE SELECTION IS THE PROBE'S SUCCESS ARM, NOT A LINE ABOVE IT. A readonly
    # `RB_TMPPARENT` makes `RB_TMPPARENT="$TMPDIR"` fail, and under `errexit` — which
    # a driving shell may well be in — a failed readonly assignment ends the session
    # AT THAT LINE, with bash's own message and none of the diagnosis this refusal
    # carries. Selecting inside the arm means the probe answers first and the
    # operator is told which name is unusable. Reverting the containment restores
    # exactly that regression, which is why `test-pr-skill-contract.sh` asserts the
    # excerpt reaches the selection.
    # AND `REPO_DIR` WITH THEM, which is neither a candidate nor a transport name
    # but is in scope and is what the MERGE stage runs `cd` into. An alias onto it
    # passed both probes — neither read it — and the assignments then replaced the
    # captured repository root with a transport path this setup deletes a few lines
    # later, so the merge could not inspect the pull request it had just approved.
    # The rule is every name in scope that an assignment here can reach, not every
    # name this stage introduces; that narrower reading is what left `HOME`,
    # `TMPDIR` and now this one out, one round each.
    #
    # AND `HOME` AND `TMPDIR` ARE READ BACK TOO, because they are the CANDIDATES and
    # a nameref onto one is not a nameref between two of these names. With
    # `declare -n RB_ORIGIN_DIR=HOME` the probe passed — it read neither — and the
    # assignments below then cleared the operator's `HOME` and replaced it with a
    # transient path this setup removes a few lines later, leaving their long-lived
    # shell pointing at a directory that no longer exists. A probe that compares
    # only against the names its own stage introduces cannot see that.
    if ( RB_TMPPARENT=Probe-A; [[ $RB_TMPPARENT = Probe-A ]] \
         && [[ ${RB_REMOTE:-} != Probe-A ]] && [[ ${REPO_DIR:-} != Probe-A ]] \
         && [[ ${HOME:-} != Probe-A ]] && [[ ${TMPDIR:-} != Probe-A ]] ) 2>/dev/null \
       && ( RB_ORIGIN_DIR=Probe-B; [[ $RB_ORIGIN_DIR = Probe-B ]] \
         && [[ ${RB_REMOTE:-} != Probe-B ]] && [[ ${RB_TMPPARENT:-} != Probe-B ]] \
         && [[ ${REPO_DIR:-} != Probe-B ]] \
         && [[ ${HOME:-} != Probe-B ]] && [[ ${TMPDIR:-} != Probe-B ]] ) 2>/dev/null; then
        # `-w` AND `-x` AS WELL AS `-d`, because "can hold a directory" is what the
        # fallback is FOR and `-d` does not answer it. An absolute, existing but
        # unwritable `TMPDIR` — `/usr` is one — passed `-d`, was committed to, and
        # the helper's `mkdir` then failed with a usable `HOME` sitting next to it.
        # The candidate loop this replaced did fall through in that state.
        #
        # WHAT IS NOT RETRIED, AND WHY. A parent whose ANCESTRY the helper refuses —
        # another account owning a component, a world-writable non-sticky one, an
        # ACL — is reported rather than silently routed around. Deciding it here
        # means a second copy of that walk in the one shell nothing can harden,
        # which is the removal this whole change is; and a `TMPDIR` whose ancestry
        # is unsafe is a state an operator has to SEE named, not one to step past
        # into `HOME`. The helper says which component and why.
        RB_TMPPARENT=
        [[ ${TMPDIR:-} = /* ]] && [[ -d ${TMPDIR:-} ]] && [[ -w ${TMPDIR:-} ]] \
            && [[ -x ${TMPDIR:-} ]] && RB_TMPPARENT="$TMPDIR"
        [[ -n $RB_TMPPARENT ]] \
            || { [[ ${HOME:-} = /* ]] && [[ -d ${HOME:-} ]] && [[ -w ${HOME:-} ]] \
                 && [[ -x ${HOME:-} ]] && RB_TMPPARENT="$HOME"; }
        # AND AN EMPTY PARENT CANNOT PRODUCE A PATH AT ALL. Written as
        # `[[ -n $RB_TMPPARENT ]] || { echo …; exit 1; }` this was a GUARD, and
        # `exit` is a name a startup file can replace with one that RETURNS: the
        # refusal printed, the next line built `/watch-pr.…` from the empty value,
        # and for a root operator the helper could create it — so setup read an
        # origin from the filesystem root and went on to announce success. The
        # expansion is not a guard and has no name in it: `${VAR:?}` is the SHELL
        # refusing to expand, and in a non-interactive shell it ends the shell
        # where it stands whatever `exit` has become. Interactively it abandons
        # only its own command, which leaves the variable unset and the helper
        # refusing an empty argument — the same answer one step later.
        # CLEARED FIRST, BECAUSE AN ABANDONED ASSIGNMENT LEAVES THE OLD VALUE.
        # INTERACTIVELY `${VAR:?}` abandons only the command it is in — the shell
        # survives — so with a STALE `RB_ORIGIN_DIR` from an earlier run in the
        # same long-lived shell, the refusal fired and the helper was then invoked
        # with the previous session's path. Clearing it immediately before means an
        # abandoned assignment leaves EMPTY, and an empty argument is one the helper
        # refuses by name. That is a removal rather than a guard: there is no
        # condition here for a shadowed `exit` to walk past, because there is no
        # value left to walk past it WITH.
        RB_ORIGIN_DIR=
        RB_ORIGIN_DIR="${RB_TMPPARENT:?neither TMPDIR nor HOME is an absolute directory this session can write to}/watch-pr.$$.$RANDOM$RANDOM$RANDOM"
        # THE READ AND BOTH REMOVALS ARE THE HELPER'S SUCCESS ARM, not statements
        # after a guard. `mkdir` is what proves this shell's helper created that
        # directory, and it is the helper that runs it — so a REFUSED call means
        # the name was already something, and something is not ours. Written as a
        # guard the refusal was walked past by a shadowed `exit` and the lines
        # below then read a pre-existing `origin` owned by this user, which passes
        # `-O` and `-f`, and pinned the session from it — and removed the
        # operator's file and directory on the way out. Containment is what a
        # neutralised `exit` cannot step over.
        if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh read "$RB_ORIGIN_DIR"; then
            # THE READ IS THE CALLER'S HALF AND STAYS HERE. `-O` and `-f` are asked
            # of the OPEN DESCRIPTOR, so they describe the object this shell is
            # about to read rather than a name it could be talked into looking up
            # twice.
            # AND A REFUSED READ REMOVES WHAT THE HELPER LEFT. The helper cleans up
            # after its OWN refusals — it created the directory — but a read this
            # side rejects leaves a written file in a directory nothing else will
            # remove. The obligation follows whoever the refusal belongs to.
            { [[ -O /dev/fd/9 ]] && [[ -f /dev/fd/9 ]] \
                && RB_REMOTE="$(<"/dev/fd/9")"; } 9<"$RB_ORIGIN_DIR/origin" \
                || { /usr/bin/env rm -f "$RB_ORIGIN_DIR/origin"; /usr/bin/env rmdir "$RB_ORIGIN_DIR"; echo "ABORT: the transport file is not the one this setup created; refusing to pin from it"; exit 1; }
            /usr/bin/env rm -f "$RB_ORIGIN_DIR/origin"
            /usr/bin/env rmdir "$RB_ORIGIN_DIR"
        else
            echo "ABORT: could not read this session's origin"
            exit 1
            [[ -n "" ]]
        fi
    else
        echo "ABORT: RB_TMPPARENT or RB_ORIGIN_DIR is readonly, value-transforming, or aimed at another transport variable; the transport directory cannot be chosen"
        exit 1
        [[ -n "" ]]
    fi
    [[ -n $RB_REMOTE ]] \
        || { echo "ABORT: origin is empty; there is no repository to pin this session to"; exit 1; }
    # THE FILE IS REMOVED WHETHER OR NOT THE READ SUCCEEDED. It holds one line of
    # public information, so this is tidiness rather than secrecy — but the setup block
    # already allocates one temporary and `test-pr-skill-contract.sh` counts what a run
    # leaves behind, so a second one that survives a refusal would be a leak the suite
    # reports and nobody meant.
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
    # bash 3.2 CI job all cover `scripts/` — the CI job when it is running, which it is
    # not while #93 stands — and none of them can see shell inside a Markdown file — `test-pr-skill-contract.sh` had to `sed` the function back out of
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
    # is the guard. Do not add a step below it.
    #
    # AND "ABOVE IT" WAS NOT ENOUGH EITHER, WHICH IS WHY THE WORKING FILES ARE INSIDE
    # ITS SUCCESS ARM. Allocated above, their own refusals fell into THIS block with
    # `exit` replaced — and the completion line then reported a finished setup naming
    # paths that were unset or somebody else's. Position guards what comes after a
    # failure; only containment guards what comes after a failure that could not stop
    # the shell. So the allocation is nested here, and the completion line is nested
    # inside IT.
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
    # NO FALLBACK ON FAILURE, because `:` is a name. `… || : > "$RB_PIN_OUT"` called
    # whatever the operator's shell had defined as `:`, and one that wrote `$RB_REMOTE`
    # into that file made the equality below pass while the child probe had actually
    # failed.
    #
    # WHAT REPLACED IT IS NOT ANOTHER FALLBACK: THE FILE IS READ ONLY IF THE HELPER
    # SUCCEEDED. Relying on the truncation was relying on the helper having reached it,
    # and a helper that cannot start — missing, unreadable, or `env` unable to exec it —
    # never truncates anything. The status was ignored, so what got read was whatever
    # was at that path already, and it only had to equal `$RB_REMOTE` to report that a
    # child had inherited the pin when no child had run. Branching removes the
    # dependency on the file's contents rather than adding a guard over them; an
    # unset `RB_PIN_SEEN` cannot match a non-empty remote, so the failure lands on the
    # postcondition that is already here.
    #
    # WRITTEN AS `if` RATHER THAN AS `&&`, WHICH IS THE OPPOSITE OF WHAT STOOD HERE.
    # The `&&` form was chosen because the postcondition below is lifted out of this
    # file and executed by `test-pr-skill-contract.sh`, and that lift used to end at
    # the first `fi` at COLUMN 0 — so an `if` around this call ended it before the
    # postcondition and nine assertions ran against a truncated block. The lift ends
    # at the pin branch's own `fi`, four spaces in, since #155; an `if` around the
    # call closes eight spaces in and the lift is unaffected. The `&&` form's real
    # cost is the one the round after found: the removals that followed it ran on
    # every path, including the one where the helper refused because the directory
    # was already the operator's.
    #
    # ITS OWN DIRECTORY, ALLOCATED HERE AND GONE ON EVERY PATH OUT OF THE ARM BELOW.
    # The origin read removed the first one as soon as it had its value; this is the
    # second half of that. Same parent, same rules, same lifetime — and the lifetime
    # is the HELPER'S ANSWER, because WHO MADE IT decides who may remove it: the
    # `mkdir` inside the helper is what proves this shell's call created it, so its
    # success arm removes the directory and nothing outside that arm removes
    # anything at all.
    # ── DOES A CHILD SEE THE PIN? ─────────────────────────────────────────
    #
    # THE SAME MOVE AS THE READ ABOVE. This was `RB_PIN_DIR`, `RB_PIN_OUT` and
    # `RB_PIN_SEEN` with an assignability arm each, an exclusive `mkdir` and two
    # cleanups — twenty-five lines defending three names in THIS shell. The helper
    # creates the directory now, so `RB_PIN_DIR` is the only one of the three that
    # has to exist here, and `RB_PIN_SEEN` holds the answer. #157.
    #
    # THE PROBE IS STILL A REAL CHILD, and that is the point of the stage: an
    # `export` that assigns without setting the export attribute leaves this shell
    # holding the right value while every helper holds none. Reading the variable
    # back here answers a different question; only asking a child answers this one.
    # THE PROBE COMES FIRST, AND THE REAL ASSIGNMENTS ARE ITS ARM. Written above
    # the probe they were the very thing it exists to make safe: a readonly
    # `RB_PIN_DIR` or `RB_PIN_SEEN` makes the assignment fail, and under `errexit`
    # a failed readonly assignment ends the session AT THAT LINE with bash's own
    # message and none of the diagnosis below — while a `declare -n` aimed at
    # another transport variable mutates its target before anything has validated
    # it. The transport read above settled this the same way.
    # AND `RB_TMPPARENT` IS CROSS-CHECKED HERE TOO, which the first version of this
    # probe left out. It compares only against the names this STAGE introduces, and
    # `declare -n RB_PIN_SEEN=RB_TMPPARENT` therefore passes both subshells —
    # neither reads that name — after which the real pin read assigns the inherited
    # origin through the nameref and REPLACES the parent this setup proved. For a
    # local origin such as `/tmp/repo` the session's working directory is then
    # created inside that repository. The transport probe above already compares
    # against every name it can reach; this one now does the same.
    # AND `HOME` AND `TMPDIR` HERE TOO, for the reason the transport probe gives.
    # This stage removes what it creates as well, so an alias onto a candidate has
    # the same end: the operator's variable is replaced with a path and the path is
    # then deleted. Written into ONE of two identical probes it is the shape this
    # repository records as the cause of its worst bugs — a rule that reached two
    # of three helpers and sat missing from the third for eleven rounds.
    if ( RB_PIN_DIR=Probe-A; [[ $RB_PIN_DIR = Probe-A ]] \
         && [[ ${RB_PIN_SEEN:-} != Probe-A ]] && [[ ${RB_REMOTE:-} != Probe-A ]] \
         && [[ ${RB_TMPPARENT:-} != Probe-A ]] && [[ ${REPO_DIR:-} != Probe-A ]] \
         && [[ ${HOME:-} != Probe-A ]] && [[ ${TMPDIR:-} != Probe-A ]] ) 2>/dev/null \
       && ( RB_PIN_SEEN=Probe-B; [[ $RB_PIN_SEEN = Probe-B ]] \
         && [[ ${RB_PIN_DIR:-} != Probe-B ]] && [[ ${RB_REMOTE:-} != Probe-B ]] \
         && [[ ${RB_TMPPARENT:-} != Probe-B ]] && [[ ${REPO_DIR:-} != Probe-B ]] \
         && [[ ${HOME:-} != Probe-B ]] && [[ ${TMPDIR:-} != Probe-B ]] ) 2>/dev/null; then
        # AND THE PARENT IS REQUIRED BY THE EXPANSION HERE TOO, for the reason the
        # origin read gives: an empty one built `/watch-pr-pin.…` from nothing.
        # CLEARED FIRST, for the reason the origin read gives: interactively the
        # expansion abandons its own command and a stale `RB_PIN_DIR` from an
        # earlier run in the same shell would otherwise be what the helper is
        # handed.
        RB_PIN_DIR=
        RB_PIN_DIR="${RB_TMPPARENT:?neither TMPDIR nor HOME is an absolute directory this session can write to}/watch-pr-pin.$$.$RANDOM$RANDOM$RANDOM"
        RB_PIN_SEEN=
        # THE REMOVALS ARE THE HELPER'S SUCCESS ARM TOO, for the reason the read
        # above states: a refused call means the `mkdir` inside the helper found
        # the name already taken, so the directory and the file in it are the
        # OPERATOR'S — and `rm -f` deletes that file while `rmdir` deletes the
        # directory whenever it is empty, which an operator's directory often is.
        # Written after the call they ran on every path, including that one.
        if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh pin "$RB_PIN_DIR"; then
            { [[ -O /dev/fd/9 ]] && [[ -f /dev/fd/9 ]] \
                && RB_PIN_SEEN="$(<"/dev/fd/9")"; } 9<"$RB_PIN_DIR/pin"
            /usr/bin/env rm -f "$RB_PIN_DIR/pin"
            /usr/bin/env rmdir "$RB_PIN_DIR"
        fi
        # WHAT THIS PROVES, AND WHAT IT CANNOT — the boundary is here because several
        # rounds of review walked up to it and it is cheaper to state than to
        # rediscover. #102.
        #
        # IT PROVES A CHILD INHERITED THE PIN, which is the failure it was built for:
        # an `export` that assigns without setting the export attribute leaves this
        # shell holding the right value while every helper holds none, and a `cd` into
        # a second checkout then retargets every stage. That is #80, it is an ACCIDENT
        # rather than an attack, and asking a real child is what catches it.
        #
        # IT DOES NOT PROVE ANYTHING AGAINST A FUNCTION IN THIS SHELL, and no
        # comparison written here can. `export` is a name, and one that MUTATES its
        # operand —
        #
        #     export() { RB_REMOTE='git@github.com:WRONG/other.git'
        #                builtin export REVIEW_BUS_REMOTE="$RB_REMOTE"; }
        #
        # — makes the child report the forged value and this line compare forged with
        # forged. Measured. A SECOND `pr-origin.sh read` was built to compare against
        # the repository instead, and it is not in this file because it bought exactly
        # one thing: an attacker who knew one variable name and not the other. The same
        # function rewrites both; it can also `cd` first, so a later read agrees with
        # the forgery, and an earlier one is just another variable. Every value this
        # shell holds is nameable, and the function runs at a point of its own
        # choosing — so there is no ordering and no extra child that makes the
        # comparison mean more than the shell it runs in. `SKILL.md` itself is a file
        # such a shell can edit, which is the same boundary `pr-origin.sh` § WHAT THIS
        # DOES NOT CLOSE and #91 draw.
        #
        # NON-EMPTY AS WELL AS EQUAL, and the emptiness is the half that matters here.
        # A refusal walked past with `exit` shadowed leaves `RB_REMOTE` empty, the pin
        # probe reports empty because no child was asked, and `"" = ""` SUCCEEDS — so
        # setup announced success with no `REVIEW_BUS_REMOTE` at all, and every later
        # stage derived its identity from wherever the session happened to stand.
        if [[ -n $RB_PIN_SEEN ]] && [[ $RB_PIN_SEEN = "$RB_REMOTE" ]]; then
            # THE SESSION'S THREE WORKING FILES, FROM ONE ALLOCATION. Files rather than
            # shell variables: the text is long, contains backticks and quotes, and passing
            # it inline mangles it — and the baseline comes back in one because a variable is
            # a name a startup file can have made readonly, which `pr-origin.sh` settled the
            # same way. Freshly created per PR and per session, because a reused path is how
            # a stale summary from another round — or another PR — gets posted as if it were
            # this one's.
            #
            # ONE DIRECTORY, AND THE THREE PATHS DERIVED FROM IT. Three `mktemp` calls made
            # them three separate answers, and `mktemp` is a NAME: a function returning the
            # same existing empty path each time passes every validation and leaves all three
            # ALIASED. Writing the opening account would then populate the round-summary
            # file, and a first round that missed its own summary write would post that
            # account as the summary and request another pass — the exact regression the
            # separate files exist to prevent. Derived by literal suffixes there is nothing to
            # make equal: the distinctness is in the source, not in what a command returned.
            #
            # AND NO `mktemp` AT ALL, WHICH IS THE SAME ANSWER THE TRANSPORT DIRECTORY ABOVE
            # ALREADY GIVES. The path is BUILT by expansion — `$$` and `$RANDOM` are the
            # shell's own, so nothing runs and a driving shell tracing to fd 1 has nothing to
            # write into the value. `mkdir` IS THE EXCLUSION: it fails if the name exists, so
            # an account on this machine that guesses the name gets nothing rather than a
            # file this session then writes through, and `-m 700` is applied by `mkdir`
            # itself, so all three files inherit that protection rather than each needing its
            # own. It runs through `/usr/bin/env` for the reason every other command in this
            # block does.
            #
            # THE PARENT IS THE ONE ALREADY PROVEN — absolute, a directory, and one this user
            # could create under. Choosing it a second time would be a second copy of the
            # loop above, which is the defect this document keeps deleting.
            # ASSIGNABLE FIRST, AND ASKED IN A SUBSHELL — the probe the transport parent
            # above already uses, and for the reason it gives. ONE value, because the
            # subshell is where the assignment happens: a readonly pre-seeded with the
            # probe's own value makes it fail outright there, so the comparison inside
            # is never reached. Two unequal values were what a comparison in THIS shell
            # needed, and that comparison is gone.
            #
            # THE SHAPE CHECK BELOW IS NOT WHAT STOPS ONE. It matches a PREFIX, and a readonly
            # value such as `…/watch-pr-work.anchor/../elsewhere/session` satisfies it while
            # naming a directory under a parent nothing proved — `mkdir` resolves the `..`,
            # and another account owning that parent could then replace the directory and with
            # it the account this session posts and the baseline it waits on. It stays as a
            # statement of the shape; the probes are what make the value this session's.
            # EVERY FAILURE ARM EXCLUDES THE WORK STRUCTURALLY, rather than ending it. `exit`
            # is a builtin a startup file can replace with one that RETURNS, and this bash
            # runs in the operator's own shell — so a guard written as
            # `… || { echo …; exit 1; }` prints and then carries straight on to the next
            # line. With `RB_WORK_DIR` readonly to an existing directory that meant reaching
            # the three redirections below and truncating `summary.md`, `request.md` and
            # `prior.txt` inside it. `[[ -n "" ]]` is not the answer here either: it makes the
            # LIST report non-zero, which nothing reads. The allocation is one condition and
            # the files are its `then`, so a failed arm cannot reach them whatever `exit` was
            # made to do. Each cause still names itself, from inside the condition, ending in
            # a reserved word so the arm is false however `echo` was replaced.
            # ASKED IN A SUBSHELL, WHICH IS WHAT MAKES IT SAFE TO ASK. It was two
            # unequal assignments read back here, because one proves nothing against a
            # readonly holding the probe's own value — and both were assignments in
            # THIS shell, which is the operator's, where a failed readonly assignment
            # under `errexit` is FATAL. The probe ended the session in exactly the
            # state it exists to detect. A subshell inherits the attribute, fails for
            # the same reason, and as a condition is exempt. The value is compared
            # INSIDE it, because a TRANSFORMING attribute — `declare -i` — lets the
            # assignment succeed and stores something else, which a status-only probe
            # accepts. One value is enough: a readonly pre-seeded with the probe's own
            # value makes the subshell's assignment fail outright, so the comparison
            # is never reached. #148.
            if { ( RB_WORK_DIR=Probe-A; [[ $RB_WORK_DIR = Probe-A ]] ) \
                 || { echo "ABORT: RB_WORK_DIR is readonly or value-transforming in this shell; the session's working directory cannot be chosen"; [[ -n "" ]]; }; } \
               && {
                    # THE PARENT IS REQUIRED BY THE EXPANSION HERE TOO, and it is
                    # not redundant with the two above: the prefix check on the
                    # next line compares against `$RB_TMPPARENT`, so with an EMPTY
                    # one it reads `[[ /watch-pr-work.X = /watch-pr-work.* ]]` and
                    # AGREES — the check that exists to keep this under the proven
                    # parent is the check an empty parent satisfies. Reaching here
                    # with one requires the pin to have succeeded, which the clears
                    # above make impossible; stating the requirement locally means
                    # that argument does not have to be re-derived three blocks
                    # away.
                    RB_WORK_DIR="${RB_TMPPARENT:?neither TMPDIR nor HOME is an absolute directory this session can write to}/watch-pr-work.$$.$RANDOM$RANDOM$RANDOM"
                    [[ $RB_WORK_DIR = "$RB_TMPPARENT"/watch-pr-work.* ]] \
                 || { echo "ABORT: the session's working directory is not under the parent this setup proved"; [[ -n "" ]]; }; } \
               && { /usr/bin/env mkdir -m 700 "$RB_WORK_DIR" \
                 || { echo "ABORT: could not create the session's working directory at $RB_WORK_DIR"; [[ -n "" ]]; }; }
            then
                # Where each round's summary is written before it is posted.
                SUMMARY_FILE="$RB_WORK_DIR/summary.md"
                # The opening account, which is NOT the round summary. Sharing one file meant
                # that a first round whose summary write did not happen left the OPENING
                # account sitting there — non-empty, well-formed, and about the right PR — so
                # `pr-close-round.sh` posted it as the round summary and requested the next
                # pass instead of refusing to close. The round-summary file has to be empty
                # until that round writes it, and that is only true if nothing else writes it.
                REQUEST_FILE="$RB_WORK_DIR/request.md"
                # Where the review baseline comes back. A capture written as
                # `V="$(helper …)"` inside an `if` is an ASSIGNMENT, and a name a startup file
                # has already made readonly makes it fail — which abandons the `if` without
                # either branch running, so a refusal falls through into the wait. A plain
                # command with its output redirected has no assignment to fail.
                PRIOR_FILE="$RB_WORK_DIR/prior.txt"
                # READ BACK AGAINST THE LITERALS, and again as a CONDITION whose body is the
                # work: this is what catches a readonly name still pointing somewhere else,
                # and it has to exclude the writes rather than merely precede them.
                if [[ $SUMMARY_FILE = "$RB_WORK_DIR/summary.md" ]] \
                   && [[ $REQUEST_FILE = "$RB_WORK_DIR/request.md" ]] \
                   && [[ $PRIOR_FILE = "$RB_WORK_DIR/prior.txt" ]]
                then
                    # CREATED HERE, EMPTY, BY REDIRECTION ALONE — no command name, so there is
                    # none to shadow, and a redirection that cannot be made reports it:
                    # measured, a `> path` into a directory that does not exist is status 1.
                    # Each is then proven present and empty. A missing one fails closed later
                    # anyway — the request's `<` refuses and `pr-close-round.sh` cannot read
                    # its summary — but "fails closed later" is not a reason to leave setup
                    # unable to say so.
                    > "$SUMMARY_FILE" ; > "$REQUEST_FILE" ; > "$PRIOR_FILE"
                    # AND THE COMPLETION LINE IS THE INNERMOST SUCCESS ARM. It is how the
                    # driver knows setup finished, so every refusal above has to be unable to
                    # REACH it — and with `exit` replaced by a function that returns, "the
                    # abort ran" does not mean "the line did not". Only containment does.
                    if [[ -f "$SUMMARY_FILE" ]] && [[ ! -s "$SUMMARY_FILE" ]] \
                       && [[ -f "$REQUEST_FILE" ]] && [[ ! -s "$REQUEST_FILE" ]] \
                       && [[ -f "$PRIOR_FILE" ]] && [[ ! -s "$PRIOR_FILE" ]]; then
                        echo "OWNER=$OWNER REPO=$REPO RB_SCRIPTS=$RB_SCRIPTS SUMMARY_FILE=$SUMMARY_FILE"
                    else
                        echo "ABORT: the session's working files were not created empty under $RB_WORK_DIR"
                        exit 1
                        [[ -n "" ]]
                    fi
                else
                    echo "ABORT: one of SUMMARY_FILE, REQUEST_FILE and PRIOR_FILE is readonly in this shell; the session's working paths cannot be set"
                    exit 1
                    [[ -n "" ]]
                fi
            else
                exit 1
                [[ -n "" ]]
            fi
        else
            echo "ABORT: the repository pin did not take; every stage would route by the current directory"
            exit 1
            [[ -n "" ]]
        fi
    else
        echo "ABORT: RB_PIN_DIR or RB_PIN_SEEN is readonly, value-transforming, or aimed at another transport variable; the pin proof cannot be made"
        exit 1
        [[ -n "" ]]
    fi
else
    echo "ABORT: RB_REMOTE is readonly in this shell; setup would pin the session to a stale value"
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

# THE REQUEST IS A SCRIPT. It was eighteen lines here that nothing executed, and
# what they do is post the comment that — on the manual path — IS the review
# request. It was also a second, weaker copy of the round-closing request: that
# one refuses a body carrying a marker the loop honours or a mention it did not
# write itself, and this one refused neither, so the opening account was the one
# posting site with no rules. Issues #26, #144.
#
#   pr-request-review.sh <pr> <auto-review: yes|no> < <body>
#
#     0  posted — the baseline is on stdout, and it is EMPTY on the automatic
#        path, where the trigger preceded us and there is nothing to capture
#     1  stopped — nothing was posted
#
# WRITE THE ACCOUNT INTO `$REQUEST_FILE` WITH YOUR FILE-WRITING TOOL, not from
# this shell and NOT into `$SUMMARY_FILE`: one paragraph on what this change does
# and what to look at. It is inserted as DATA, so prose quoting a command line is
# posted rather than executed — but a line reproducing one of the markers the loop
# reads as a record CREATES that record, because this is posted under your
# identity, and on the automatic path a quoted `@codex review` queues a second
# pass over the same head. The script refuses both rather than publishing them.
#
# THE BODY NEVER BECOMES SHELL SOURCE, WHICH IS WHY IT IS NOT WRITTEN HERE. A
# heredoc splices it in: an account containing a line that is exactly the
# delimiter ENDS the heredoc, and whatever follows is parsed by your long-lived
# shell — and `EOF` is a line this loop's own accounts quote, out of a diff or a
# finding. Choosing a rarer delimiter narrows that and does not close it, because
# the body is not known when the delimiter is chosen. And writing the file from
# here needs a command — `cat`, `printf` — which is a NAME your shell can replace,
# so the account validated and posted would be the function's text. Your file tool
# is neither: it does not go through this shell at all. `$REQUEST_FILE` was
# created empty at setup and the script refuses an empty body, so a write that
# does not happen stops the request rather than posting nothing as this PR's
# account.
#
# NOTHING HERE IS AN ASSIGNMENT, AND THAT IS THE SHAPE. Written as
# `PRIOR_REVIEW="$(…)"` — inside the `if` or beside a `; REQ_RC=$?` — the capture
# is an assignment, and a startup file that has already made either name readonly
# makes it FAIL: with `errexit` on that ends your shell before any status is read,
# and without it the `if` is abandoned with NEITHER branch running, so a refused
# request falls straight through into the wait for a review nobody asked for. A
# plain command run as a CONDITION has no assignment to fail and is exempt from
# `errexit`, and its answer goes to a FILE — a path rather than a name, which is
# how `pr-origin.sh` settled the same question.
# AND THE CONTINUATION IS THE `then` BRANCH, which is structural too. `exit` is a
# builtin a startup file can replace with one that RETURNS, so a refusal written
# as `echo …; exit` prints and carries straight on — into the read-back below, and
# from there into the wait for a review that was never requested. Ending the arm
# in `[[ -n "" ]]` makes the LIST report non-zero, which nothing here reads. What
# does hold is that the work sits inside the branch a refusal does not take.
# AND THE NAME THAT WILL HOLD IT IS PROVEN ASSIGNABLE FIRST, BEFORE THE MUTATION.
# The read-back below is a simple command: with `errexit` on and `PRIOR_REVIEW`
# already readonly, it fails and ends your shell — but by then the request has
# been POSTED, so the pass is in flight and no watch is ever armed. Nothing after
# a mutation can undo that; the only place the question can be asked is before it,
# where the same failure costs a stop and nothing else.
#
# AND ASKED IN A SUBSHELL, which is what makes it safe to ask at all. It was two
# unequal assignments read back here, because one proves nothing against a
# readonly holding the probe's own value — and both were assignments in YOUR
# shell, where a failed readonly assignment under `errexit` is FATAL, so the probe
# ended the session in exactly the state it exists to detect. A subshell inherits
# the attribute, fails for the same reason, and as a condition is exempt. The
# value is compared INSIDE it, because a TRANSFORMING attribute — `declare -i
# PRIOR_REVIEW` — lets the assignment succeed and stores something else, and a
# status-only probe accepts that: the request would go out and the ordinary empty
# baseline would come back rewritten. One value is enough, because a readonly
# pre-seeded with the probe's own value makes the subshell's assignment fail
# outright and the comparison is never reached. #148.
# AND THE PROBE IS A CONDITION, WITH THE REQUEST AS ITS SUCCESS ARM. Written
# as a standalone guard it detects the readonly name and then cannot act on it:
# `exit` is a builtin your shell can replace with one that RETURNS, and the
# trailing `[[ -n "" ]]` only gives the `if` a false status that nothing consumes
# — so execution reached the request and posted it anyway, which is the state
# these probes exist to prevent. Only containment excludes it.
if { ( PRIOR_REVIEW=Probe-A; [[ $PRIOR_REVIEW = Probe-A ]] ) \
     || { echo "ABORT: PRIOR_REVIEW is readonly or value-transforming in this shell; the review baseline cannot be read back, and nothing has been posted."; [[ -n "" ]]; }; }
then
    if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-request-review.sh N "$AUTO_REVIEW" < "$REQUEST_FILE" > "$PRIOR_FILE"; then
        PRIOR_REVIEW="$(<"$PRIOR_FILE")"
        # AND THE ASSIGNMENT IS PROVEN, because here there is something to prove it
        # against. `CLAUDE.md` says to prove an assignment by reading the variable
        # back, and the usual difficulty is that nothing else knows what the value
        # should have been — a readonly name simply keeps whatever it held. The file
        # does know. If this name was already readonly the assignment fails and the
        # two disagree, which is the one case a check on the variable alone cannot
        # see: the helper SUCCEEDED and the baseline is somebody else's.
        if [[ $PRIOR_REVIEW != "$(<"$PRIOR_FILE")" ]]; then
            echo "ABORT: the review baseline did not survive being read back; PRIOR_REVIEW is not this session's to set."
            exit 0
            [[ -n "" ]]
        else
            # AND EMPTY IS AN ANSWER, NOT A FAILURE. On the automatic path there is
            # nothing to capture because the trigger preceded us; on the manual path
            # Codex has usually not reviewed this head at all yet, which is the
            # ordinary FIRST request — so `review-id` succeeds with an empty value and
            # a digits-only test would abort after the request had already been
            # posted. What is refused is a value that is neither shape.
            #
            # THE PATTERN IS A LITERAL IN THE `case`, not a variable holding one: a
            # validator in a variable is a second name a startup file can seed
            # readonly, and a seeded pattern accepting a seeded value is a check that
            # agrees with itself. `case` is a reserved word, so nothing can take its
            # place either.
            #
            # AND THERE ARE TWO SHAPES, BECAUSE THERE ARE TWO CHANNELS. A reviewer's
            # newest verdict arrives either as a submitted review, whose id is digits,
            # or as a clean COMMENT on the head — which `pr-review-state.sh` reports
            # as `comment:<id>` and `pr-watch.sh` accepts as a baseline. A digits-only
            # test refuses the second AFTER the request has been posted, leaving a
            # pass in flight that nothing waits for.
            case "$PRIOR_REVIEW" in
                "") ;;
                comment:)
                    echo "ABORT: the review baseline read back as '$PRIOR_REVIEW', which names the comment channel with no id; do not enter the wait step."
                    exit 0
                    [[ -n "" ]] ;;
                comment:*[!0-9]*)
                    echo "ABORT: the review baseline read back as '$PRIOR_REVIEW', which is not a comment id; do not enter the wait step."
                    exit 0
                    [[ -n "" ]] ;;
                comment:*) ;;
                *[!0-9]*)
                    echo "ABORT: the review baseline read back as '$PRIOR_REVIEW', which is not a review id; do not enter the wait step."
                    exit 0
                    [[ -n "" ]] ;;
            esac
        fi
    else
        echo "ABORT: no review was requested; the reason is above. Do not enter the wait step."
        exit 0
        # THE LAST WORD IS A RESERVED ONE. `echo` and `exit` are builtins a function
        # can shadow, and with both shadowed this branch says nothing and returns 0 —
        # a failed request indistinguishable from a posted one.
        [[ -n "" ]]
    fi
else
    exit 0
    [[ -n "" ]]
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
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-watch.sh N "$WHO" --after-review "$PRIOR_REVIEW"; WATCH_RC=$?
```

**Claude Code** — run it as this session's **Monitor** so the verdict surfaces
into the chat by itself instead of being waited on:

- `command`: `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-watch.sh N "$WHO" --after-review "$PRIOR_REVIEW"`
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
  same `**Review-Signoff:**` line step 7 writes — reviewer and head in backticks,
  and optionally a third field, the time of the verdict being signed off, which
  the phase adds when it can read it. **That third field is what a later
  revocation is ordered against**: a signoff stands only if no revocation is newer
  than the verdict it answers, so one posted while the phase was proving still
  reopens the phase even though the signoff was written after it. A revocation in
  the same second reopens it too, because the two cannot be ordered and treating
  that as "the signoff stands" is the answer the rule exists to stop. Where there
  is nothing to compare — no third field, or a revocation whose own time cannot be
  read — the last record wins, as it always did. The merge gate accepts it *for
  this shape only*: a `source=replies-only` verdict plus a recorded signoff naming
  that head merges, and says so in its output. A review with real findings is not
  a question anyone was asked, so a signoff never carries one.

  **RECORD IT AFTER READING, NOT BEFORE.** The signoff must be newer than the
  LATEST of that review and its newest reply — a head is not a moment, and the
  verdict here is produced by the replies rather than by the review. One recorded
  before a later reply arrives does not answer that reply, and both the merge gate
  and `pr-phase-state.sh` refuse it, naming the two times so you can see which one
  moved. If a reply lands while you are deciding, read it and record again;
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
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-findings.sh list N; FIND_RC=$?
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
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-findings.sh blocked-body N "$WHO"; BODY_RC=$?
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
# RUN `gate` FROM A CHECKOUT ON THIS PR'S BRANCH. It pushes, and a push has to go
# somewhere: it names the ref it may write, proves every push URL of `origin` is
# the pinned repository, and refuses — having pushed nothing — if any of that does
# not hold. Every refusal is a 1 with the reason on stdout and the round
# untouched.
#
# TWO KINDS OF REFUSAL, AND ONLY ONE IS RETRYABLE:
#
#   · THIS CHECKOUT — on another branch, or on a detached HEAD. Move to the
#     worktree holding the PR's branch and run it again. Nothing has happened;
#   · THIS PR — it is from a FORK, or `origin` pushes somewhere that is not the
#     pinned repository. Running it again changes nothing, because neither is
#     about where you are standing. STOP and put it to the operator: a fork PR is
#     outside what this loop drives, and a redirected `origin` is a configuration
#     decision that is not the loop's to make.
#
# IT IS A REFUSAL BECAUSE THE ALTERNATIVE HAPPENED. A bare `git push` sends
# whatever branch the checkout is on, and a round driven from a checkout left on
# `main` — a `cd` or `checkout` that failed, a second worktree holding the branch
# — pushed the DEFAULT BRANCH: an unreviewed commit on `main`, and the round lost
# as well, because the checks were then awaited on a head the PR did not have.
# #119.
#
# `$AUTO_REVIEW` IS PASSED, NOT WRITTEN IN. It was established in step 2 and the
# script refuses anything but `yes` or `no`, so the mode this PR is in picks the
# order INSIDE the script — rather than deciding which of two recipes to copy out
# of here, which is how the two drifted apart in the first place.
GATE_OUT="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-close-round.sh gate N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW" 2>&1)"; GATE_RC=$?
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
POST_OUT="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-close-round.sh post N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW" "$GATED_HEAD" 2>&1)"; ROUND_RC=$?
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
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-round-count.sh N "$WHO"; ROUNDS_RC=$?
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
  ROUNDS_OUT="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-round-count.sh N "$WHO" 2>/dev/null)"; ROUNDS_RC=$?
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
PHASE_OUT="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-copilot-phase.sh record N "$SUMMARY_FILE" 2>&1)"; PHASE_RC=$?
printf '%s\n' "$PHASE_OUT"
case "$PHASE_RC" in
    0|3) ;;   # 3 is a pause, and the signoff is recorded either way
    *) echo "The phase did not advance and no signoff was recorded. The reason is above; do not retry it blind."; exit "$PHASE_RC" ;;
esac
# THE SIGNED-OFF HEAD IS THE ONE VALUE THAT OUTLIVES THIS STEP. Step 8 needs the
# full 40 characters of it, and a child cannot assign a variable here — so it is
# read back from the record `record` just wrote.
#
# READ ON THE PAUSE TOO. The boundary message offers "merge on the Codex
# signoff", and that path needs this sha: exiting without it made the operator
# re-run a phase that had already been proved clean, just to recover a value that
# was printed and thrown away.
#
# ASKED OF THE HELPER THAT OWNS THE RECORD, rather than parsed out of the stage's
# stdout. This was ~90 lines of expansion-only code against
# `PR_PHASE_RECORDED … codex-sha=`, and every one of them was paid for in review:
# a truncated record that could not overwrite a stale candidate, a bare
# `PR_PHASE_RECORDED` with no trailing space, `xcodex-sha=` matching as the field,
# a greedy `##*codex-sha=` reading the value after a LATER substring. Nine rounds
# on #74, for a fact the PR itself already holds.
#
# `sha` PRINTS THE HEAD ALONE, and stdout carries that value or nothing — every
# reason goes to stderr, so there is no record shape here to get wrong and no
# `sed` in the path. That matters beyond tidiness: `sed` is a NAME, and one that
# prints a plausible forty hex and exits 0 pins a merge to whatever it says. The
# rule about what a well-formed record is stays in `recordlib.sh`, where it is
# tested. Issue #89.
#
# IT IS A ROUND TRIP, and that is the trade. `record` posted the signoff and this
# reads it straight back, so a stale or eventually-consistent read is a failure
# mode the parse did not have — but it is the same read a RESUMED session makes at
# the bottom of this file, so the exposure is the system's rather than this step's,
# and it fails as a stop rather than as a silent empty. A revocation landing in
# between reads as status 1, which is a refusal here: the phase it would open is
# no longer closed.
CODEX_SHA="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-signoff.sh sha N "$CODEX_BOT")"; SHA_RC=$?
RX_PHASE_SHA40='^[0-9a-f]{40}$'
# THE STATUS AND THE SHAPE, because neither covers the other. A status of 1 with
# an empty answer is the phase not being closed; a status of 0 with something
# that is not 40 hex cannot happen through the helper and is checked anyway,
# because this value is what every gate in step 8 is pinned to.
if [[ $SHA_RC -eq 0 ]] && [[ $CODEX_SHA =~ $RX_PHASE_SHA40 ]]; then
    if [[ $PHASE_RC -eq 3 ]]; then
        echo "Stopping here: the operator decides at a round boundary. Codex is signed off on $CODEX_SHA, so merging on that signoff is one of the answers."
        exit 3
    fi
else
    echo "ABORT: no Codex signoff could be read back for this phase (rc=$SHA_RC, sha='$CODEX_SHA'); step 8 would have nothing to gate on"
    exit 1
    # THE LAST WORD IS A RESERVED ONE, because both lines above it can be taken
    # away. `echo` and `exit` are builtins a function can shadow, and with both
    # shadowed this branch says nothing and returns 0 — a failed read
    # indistinguishable from an ordinary phase, which is the reading that lets the
    # driver carry on. `[[ … ]]` is a reserved word, so this branch ends non-zero
    # whatever has been done to the builtins, and the block's status is the last
    # signal left.
    [[ -n "" ]]
fi
```

**STOP — the next phase is the operator's decision.** `record` has proved Codex
clean on an exact head, proved that head's checks, re-proved the head and the
verdict immediately before writing — and, where a revocation is the newest
record, proved it is OLDER than that verdict, so this pass is answering a
reopening rather than superseding one — the CI gate WAITS, so a push or a dismissal
can land in that window and either stops the record with nothing posted — and
written the signoff onto the PR. What happens next is not the loop's call to
make:

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
OPEN_OUT="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-copilot-phase.sh open N "$CODEX_SHA" 2>&1)"; OPEN_RC=$?
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
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-copilot-phase.sh close N "$CODEX_SHA" "$REVIEWERS"
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
# THE PHASE IS A FACT ON THE PR, NOT SOMETHING A SESSION REMEMBERS. `record`
# writes a signoff precisely so a later session can read it back, and this helper
# is that reading: it takes the two signoffs and the head, selects which stop is
# being resumed from, and re-validates the record that has to still stand — the
# head must BE the Codex commit before the Copilot phase, and must be the COPILOT
# commit after it, where the head has advanced through Copilot fixes by design.
#
# IT WAS 112 LINES HERE, and nothing executed them: three arms and six refusals,
# every abort exiting 0 so that "the phase is not closed" and "this ran correctly"
# were the same status to anything that read it. Issues #123 and #26.
#
#   pr-phase-state.sh <pr>
#
#     0  readable, and the record it names still stands
#     1  stopped — the record on stdout says which: no signoff, a moved head, or a
#        verdict that no longer stands
#     2  unreadable — fail closed. NOT "no signoff"
#
# NO STATUS VARIABLE AT ALL, and that is the point of the shape below. Written as
# `if …; then RC=0; else RC=$?; fi` and then a `case "$RC"`, a startup file that
# had already made that name readonly with the value 0 caused BOTH assignments to
# fail while leaving it at 0 — and a helper that returned 1 or 2 was sent through
# the continuation into the merge flow. A failed assignment does not even fire an
# `||`, so there is no status to take; the answer is not to guard the variable but
# to have none. The helper's status is branched on where it is produced.
#
# THE CONTINUATION IS THE `then` BRANCH, AND THAT IS STRUCTURAL TOO. This bash
# runs in YOUR shell, which nothing here controls — `exit` is a builtin a function
# can take the place of, and one that RETURNS instead of exiting leaves a refusal
# falling straight through into whatever came after it. Nothing follows, so there
# is nothing to fall into; and each refusal ENDS in a reserved word, so it reports
# non-zero even with `echo` and `exit` both taken away.
#
# AND IT IS A CONDITION, NOT a simple command whose status is read afterwards. If
# your shell has `errexit` on — this block is pasted into one as often as it is
# typed — a simple command that exits non-zero ends the shell before anything can
# read its status, so the 1/2 distinction is lost at exactly the two statuses it
# exists for. A command run as a CONDITION is exempt.
if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-phase-state.sh N; then
    # AND THE SHA THE GATE IS PINNED TO, by the same idiom step 7 uses: `sha`
    # asks for the head alone, so nothing here parses a record line. The status
    # AND the shape are checked, because neither covers the other and this value
    # is what every gate below is measured against.
    CODEX_SHA="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-signoff.sh sha N "$CODEX_BOT")"; SIGNOFF_RC=$?
    RX_SHA40='^[0-9a-f]{40}$'
    if [[ $SIGNOFF_RC -ne 0 ]] || ! [[ "$CODEX_SHA" =~ $RX_SHA40 ]]; then
        echo "ABORT: the recorded Codex signoff did not read back as a sha (rc=$SIGNOFF_RC, sha='$CODEX_SHA')"
        exit 0
        # THE LAST WORD IS A RESERVED ONE. `echo` and `exit` are builtins a
        # function can shadow, and with both shadowed this branch says nothing and
        # returns 0 — a failed read indistinguishable from a resumed phase.
        # `[[ … ]]` is a reserved word, so the block ends non-zero whatever was
        # done to the builtins.
        [[ -n "" ]]
    fi
else
    # `$?` HERE IS THE CONDITION'S, read before anything else can change it.
    case $? in
        1) echo "Stopping here: the phase is not what resuming assumed. The record above says which, and what to run instead."
           exit 0
           [[ -n "" ]] ;;
        *) echo "ABORT: the phase could not be read. Do not merge on a phase nothing could establish."
           exit 0
           [[ -n "" ]] ;;
    esac
fi
```

### Then: the gate

```bash
# THE GATE IS A SCRIPT. It was 291 lines here, pasted into your shell, and
# nothing checked it — which is how it came to contain a construct the bash macOS
# ships cannot PARSE, for fifty review rounds. `scripts/` is covered by the suite,
# by `pr-selfcheck.sh` and — while it is enabled, which #93 owns — by the bash 3.2
# CI job; a fenced block is covered by none of them. Issue #26.
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
(cd "$REPO_DIR" && /usr/bin/env bash -p "$RB_SCRIPTS"/pr-merge-gate.sh N "$CODEX_SHA" "$AUTO_REVIEW" "$REVIEWERS")
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
