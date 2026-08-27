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
# THE TRACE IS MOVED OFF THE CAPTURE BEFORE ANY `$( )` RUNS, or xtrace lands inside the value.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
if [[ -n "$( RB_TRACE_PROBE=1 )" ]] && ( BASH_XTRACEFD=2 ) 2>/dev/null; then
    BASH_XTRACEFD=2
fi
# THE REPOSITORY ROOT IS CAPTURED WITH ITS STATUS TAKEN, or a failed read becomes a path.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
REPO_DIR="$(git rev-parse --show-toplevel)" \
    || { echo "ABORT: could not resolve the repository root"; exit 1; }
# THE HELPERS ARE LOCATED FIRST, because the identity parser is one of them.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
RB_SCRIPTS="${CLAUDE_PLUGIN_ROOT:-}/skills/watch-prs/scripts"
# THE NEWEST INSTALLED COPY IS CHOSEN BY MTIME, not by `sort -V`, which is GNU-only.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
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

# THE IDENTITY COMES FROM THE SHARED PARSER, never from a copy written out here.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
unset -f rb_identity 2>/dev/null \
    || { echo "ABORT: a pre-existing rb_identity could not be cleared"; exit 1; }
. "$RB_SCRIPTS/identitylib.sh" \
    || { echo "ABORT: could not load the identity parser from $RB_SCRIPTS"; exit 1; }
[ "$(type -t rb_identity 2>/dev/null)" = function ] \
    || { echo "ABORT: the identity parser loaded but defines nothing"; exit 1; }
# THE IDENTITY IS PINNED HERE, ONCE, AND EVERY HELPER INHERITS IT.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
RB_REMOTE=
# THE CLEAR IS A CONDITION, WITH EVERYTHING THAT DEPENDS ON THE VALUE AS ITS ARM.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
if [[ -z $RB_REMOTE ]]; then
    # ONE GENERIC TEST REPLACES THE ENUMERATION, because a list of names is wrong by omission.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    if ( RB_TMPPARENT="RbProbe$$$RANDOM$RANDOM"; [[ $RB_TMPPARENT = RbProbe* ]] \
         && [[ -z ${!RB_TMPPARENT:-} ]] ) 2>/dev/null \
       && ( RB_TMPPARENT2="RbProbe$$$RANDOM$RANDOM"; [[ $RB_TMPPARENT2 = RbProbe* ]] \
         && [[ -z ${!RB_TMPPARENT2:-} ]] ) 2>/dev/null \
       && ( RB_ORIGIN_DIR="RbProbe$$$RANDOM$RANDOM"; [[ $RB_ORIGIN_DIR = RbProbe* ]] \
         && [[ -z ${!RB_ORIGIN_DIR:-} ]] ) 2>/dev/null \
       && ( RB_ORIGIN_DIR2="RbProbe$$$RANDOM$RANDOM"; [[ $RB_ORIGIN_DIR2 = RbProbe* ]] \
         && [[ -z ${!RB_ORIGIN_DIR2:-} ]] ) 2>/dev/null; then
        # `-w` AND `-x` AS WELL AS `-d`, because "can hold a directory" is what the fallback is for.
        # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
        RB_TMPPARENT=
        [[ ${TMPDIR:-} = /* ]] && [[ -d ${TMPDIR:-} ]] && [[ -w ${TMPDIR:-} ]] \
            && [[ -x ${TMPDIR:-} ]] && RB_TMPPARENT="$TMPDIR"
        RB_TMPPARENT2=
        [[ ${HOME:-} = /* ]] && [[ -d ${HOME:-} ]] && [[ -w ${HOME:-} ]] \
            && [[ -x ${HOME:-} ]] && RB_TMPPARENT2="$HOME"
        # AND `HOME` MOVES UP WHERE `TMPDIR` IS UNUSABLE, so the FIRST attempt is
        # always the one that exists and the second is simply absent.
        [[ -n $RB_TMPPARENT ]] \
            || { RB_TMPPARENT="$RB_TMPPARENT2"; RB_TMPPARENT2=; }
        # THE SAME PARENT TWICE IS NOT DEDUPLICATED, because two random leaves are two usable names.
        # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
        RB_ORIGIN_DIR=
        RB_ORIGIN_DIR="${RB_TMPPARENT:?neither TMPDIR nor HOME is an absolute directory this session can write to}/watch-pr.$$.$RANDOM$RANDOM$RANDOM"
        # THE SECOND CANDIDATE IS EMPTY WHERE THERE IS NO SECOND PARENT.
        # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
        RB_ORIGIN_DIR2=
        [[ -n $RB_TMPPARENT2 ]] \
            && RB_ORIGIN_DIR2="$RB_TMPPARENT2/watch-pr-2.$$.$RANDOM$RANDOM$RANDOM"
        # THE READ AND BOTH REMOVALS ARE THE HELPER'S SUCCESS ARM, not statements after a guard.
        # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
        if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh read "$RB_ORIGIN_DIR"; then
            # THE READ-BACK IS THE CALLER'S HALF AND STAYS HERE, where the descriptor can be checked.
            # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
            if { [[ -O /dev/fd/9 ]] && [[ -f /dev/fd/9 ]] \
                && RB_REMOTE="$(<"/dev/fd/9")"; } 9<"$RB_ORIGIN_DIR/origin"; then
                /usr/bin/env rm -f "$RB_ORIGIN_DIR/origin"
                /usr/bin/env rmdir "$RB_ORIGIN_DIR"
            else
                # THE TRANSPORT FILE IS REMOVED WHETHER OR NOT THE READ SUCCEEDED.
                # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
                /usr/bin/env rm -f "$RB_ORIGIN_DIR/origin"
                /usr/bin/env rmdir "$RB_ORIGIN_DIR"
                # THE EXPANSION IS FIRST, AND THAT ORDER IS THE WHOLE OF IT.
                # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
                : "${RB_REMOTE:?the transport file is not the one this setup created. Setup refuses to pin from it, and the directory it was in has been removed.}"
                echo "ABORT: the transport file is not the one this setup created; refusing to pin from it"
                exit 1
                [[ -n "" ]]
            fi
        # THE RETRY IS A SECOND CALL, NOT A SECOND CANDIDATE PASSED TO ONE.
        # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
        elif [[ $? -eq 2 ]] && [[ -n $RB_ORIGIN_DIR2 ]] \
            && /usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh read "$RB_ORIGIN_DIR2"; then
            # THE PARENT THAT WORKED BECOMES THE PRIMARY ONE, or the session dies one step later.
            # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
            RB_TMPPARENT2="$RB_TMPPARENT"
            RB_TMPPARENT="${RB_ORIGIN_DIR2%/*}"
            if { [[ -O /dev/fd/9 ]] && [[ -f /dev/fd/9 ]] \
                && RB_REMOTE="$(<"/dev/fd/9")"; } 9<"$RB_ORIGIN_DIR2/origin"; then
                /usr/bin/env rm -f "$RB_ORIGIN_DIR2/origin"
                /usr/bin/env rmdir "$RB_ORIGIN_DIR2"
            else
                /usr/bin/env rm -f "$RB_ORIGIN_DIR2/origin"
                /usr/bin/env rmdir "$RB_ORIGIN_DIR2"
                # THE EXPANSION IS FIRST HERE TOO, for the reason spelled out on
                # the arm above: a shadowed `echo` that forges a value and neuters
                # `exit` is past every statement that follows it, and the shell
                # refusing to expand is reached before any command runs. #178.
                : "${RB_REMOTE:?the transport file is not the one this setup created. Setup refuses to pin from it, and the directory it was in has been removed.}"
                echo "ABORT: the transport file is not the one this setup created; refusing to pin from it"
                exit 1
                [[ -n "" ]]
            fi
        else
            # THIS ARM IS REACHED THREE WAYS AND SAYS SO IN ONE MESSAGE, because it cannot tell them apart.
            # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
            : "${RB_REMOTE:?could not read the origin for this session. Setup could not get a transport directory it could use, and each ABORT line above is one attempt and its reason. Read those: a name that was already taken is not the same failure as a filesystem with no room, and neither is an ancestry another account can interfere with or a checkout with no usable origin.}"
            echo "ABORT: could not read this session's origin"
            exit 1
            [[ -n "" ]]
        fi
    else
        # THE EXPANSION IS FIRST HERE TOO. Nothing has read the origin on this
        # path, so `RB_REMOTE` is still the value the clear left, and the shell
        # refusing to expand runs before the `echo` a startup file can have
        # replaced with one that forges a URL and neuters `exit`. #178.
        : "${RB_REMOTE:?one of RB_TMPPARENT, RB_TMPPARENT2, RB_ORIGIN_DIR and RB_ORIGIN_DIR2 is readonly, value-transforming, or aimed at another transport variable; the transport directory cannot be chosen}"
        echo "ABORT: one of RB_TMPPARENT, RB_TMPPARENT2, RB_ORIGIN_DIR and RB_ORIGIN_DIR2 is readonly, value-transforming, or aimed at another transport variable; the transport directory cannot be chosen"
        exit 1
        [[ -n "" ]]
    fi
    # THE EXPANSION IS THE REFUSAL, NOT A GUARD IN FRONT OF ONE.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    RB_REMOTE="${RB_REMOTE:?origin is empty; there is no repository to pin this session to}"
    # ONE LINE, OR IT IS NOT A REMOTE — an interior newline means the value is not an origin.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    [[ $RB_REMOTE = *$'\n'* ]] && RB_REMOTE=
    RB_REMOTE="${RB_REMOTE:?the origin read returned more than one line; something is writing to the stream it came back on}"
    # A COMMAND PREFIX, NOT THE EXPORT, so the driver and its children cannot disagree.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    REVIEW_BUS_REMOTE="$RB_REMOTE" rb_identity || RB_REMOTE=
    RB_REMOTE="${RB_REMOTE:?origin is not a usable identity: $RB_IDENTITY_REASON}"
    CODEX_BOT='chatgpt-codex-connector[bot]'; COPILOT_BOT='copilot-pull-request-reviewer[bot]'
    # THE CI KNOBS ARE EXPORTED, because a child process is what reads them now.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    for _rb_knob in PR_CI_INTERVAL PR_CI_TIMEOUT PR_CI_GRACE PR_CI_PROBE_TIMEOUT REVIEW_MERGE_STRICT RB_SUITE_JOBS; do
        [ -n "${!_rb_knob-}" ] && export "$_rb_knob"
    done
    unset _rb_knob
    # THE PIN IS THE LAST THING SETUP DOES, AND SETUP SAYS SO OR SAYS NOTHING.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    export REVIEW_BUS_REMOTE="$RB_REMOTE" \
        || { echo "ABORT: could not pin this session's repository — REVIEW_BUS_REMOTE is readonly in this shell"; exit 1; }
    # THE PIN NAMES GET THE SAME GENERIC TEST, for the reason the transport probe gives.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    if ( RB_PIN_DIR="RbProbe$$$RANDOM$RANDOM"; [[ $RB_PIN_DIR = RbProbe* ]] \
         && [[ -z ${!RB_PIN_DIR:-} ]] ) 2>/dev/null \
       && ( RB_PIN_DIR2="RbProbe$$$RANDOM$RANDOM"; [[ $RB_PIN_DIR2 = RbProbe* ]] \
         && [[ -z ${!RB_PIN_DIR2:-} ]] ) 2>/dev/null \
       && ( RB_PIN_SEEN="RbProbe$$$RANDOM$RANDOM"; [[ $RB_PIN_SEEN = RbProbe* ]] \
         && [[ -z ${!RB_PIN_SEEN:-} ]] ) 2>/dev/null; then
        # THE PIN PARENT IS REQUIRED BY THE EXPANSION, or an empty one builds a path from nothing.
        # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
        RB_PIN_DIR=
        RB_PIN_DIR="${RB_TMPPARENT:?neither TMPDIR nor HOME is an absolute directory this session can write to}/watch-pr-pin.$$.$RANDOM$RANDOM$RANDOM"
        # AND THE SECOND, for the same reason and because half a retry is none:
        # the origin read succeeding under `HOME` while this probe still refused on
        # `TMPDIR` would end the session one step later, on the pin instead of on
        # the origin. #161.
        RB_PIN_DIR2=
        [[ -n $RB_TMPPARENT2 ]] \
            && RB_PIN_DIR2="$RB_TMPPARENT2/watch-pr-pin-2.$$.$RANDOM$RANDOM$RANDOM"
        RB_PIN_SEEN=
        # THE PIN REMOVALS ARE THE HELPER'S SUCCESS ARM TOO, for the reason the read above states.
        # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
        if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh pin "$RB_PIN_DIR"; then
            { [[ -O /dev/fd/9 ]] && [[ -f /dev/fd/9 ]] \
                && RB_PIN_SEEN="$(<"/dev/fd/9")"; } 9<"$RB_PIN_DIR/pin"
            /usr/bin/env rm -f "$RB_PIN_DIR/pin"
            /usr/bin/env rmdir "$RB_PIN_DIR"
        # THE SAME SECOND CALL AS THE ORIGIN READ, and for the same reasons: an
        # `elif` reads the first call's status in its own condition, which is inside
        # the same `if`, and each arm names the directory the helper just created
        # rather than guessing between two.
        elif [[ $? -eq 2 ]] && [[ -n $RB_PIN_DIR2 ]] \
            && /usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh pin "$RB_PIN_DIR2"; then
            # THE PARENT THAT WORKED BECOMES PRIMARY HERE TOO. The primary
            # filesystem can fill between the origin read and this probe, and
            # without the swap the working directory is still allocated from the
            # one that just refused — so a pin that recovered would be followed by
            # a session that could not start.
            RB_TMPPARENT2="$RB_TMPPARENT"
            RB_TMPPARENT="${RB_PIN_DIR2%/*}"
            { [[ -O /dev/fd/9 ]] && [[ -f /dev/fd/9 ]] \
                && RB_PIN_SEEN="$(<"/dev/fd/9")"; } 9<"$RB_PIN_DIR2/pin"
            /usr/bin/env rm -f "$RB_PIN_DIR2/pin"
            /usr/bin/env rmdir "$RB_PIN_DIR2"
        fi
        # WHAT THE PIN PROOF PROVES, AND WHAT IT CANNOT, stated because review walks up to it every time.
        # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
        if [[ -n $RB_PIN_SEEN ]] && [[ $RB_PIN_SEEN = "$RB_REMOTE" ]]; then
            # THE SESSION'S FOUR WORKING FILES COME FROM ONE ALLOCATION.
            # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
            if { ( RB_WORK_DIR="RbProbe$$$RANDOM$RANDOM"; [[ $RB_WORK_DIR = RbProbe* ]] \
                    && [[ -z ${!RB_WORK_DIR:-} ]] ) \
                 || { echo "ABORT: RB_WORK_DIR is readonly or value-transforming in this shell; the session's working directory cannot be chosen"; [[ -n "" ]]; }; } \
               && {
                    # THE WORKING-DIRECTORY PARENT IS REQUIRED TOO, and is not redundant with the two above.
                    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
                    RB_WORK_DIR="${RB_TMPPARENT:?neither TMPDIR nor HOME is an absolute directory this session can write to}/watch-pr-work.$$.$RANDOM$RANDOM$RANDOM"
                    [[ $RB_WORK_DIR = "$RB_TMPPARENT"/watch-pr-work.* ]] \
                 || { echo "ABORT: the session's working directory is not under the parent this setup proved"; [[ -n "" ]]; }; } \
               && { /usr/bin/env mkdir -m 700 "$RB_WORK_DIR" \
                 || { echo "ABORT: could not create the session's working directory at $RB_WORK_DIR"; [[ -n "" ]]; }; }
            then
                # Where each round's summary is written before it is posted.
                SUMMARY_FILE="$RB_WORK_DIR/summary.md"
                # THE OPENING ACCOUNT IS NOT THE ROUND SUMMARY, and they must not share a file.
                # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
                REQUEST_FILE="$RB_WORK_DIR/request.md"
                # Where the review baseline comes back. A capture written as
                # `V="$(helper …)"` inside an `if` is an ASSIGNMENT, and a name a startup file
                # has already made readonly makes it fail — which abandons the `if` without
                # either branch running, so a refusal falls through into the wait. A plain
                # command with its output redirected has no assignment to fail.
                PRIOR_FILE="$RB_WORK_DIR/prior.txt"
                # THE GATED HEAD TRAVELS IN A FILE, and this is where it lands.
                # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
                HEAD_FILE="$RB_WORK_DIR/head.txt"
                # READ BACK AGAINST THE LITERALS, and again as a CONDITION whose body is the
                # work: this is what catches a readonly name still pointing somewhere else,
                # and it has to exclude the writes rather than merely precede them.
                if [[ $SUMMARY_FILE = "$RB_WORK_DIR/summary.md" ]] \
                   && [[ $REQUEST_FILE = "$RB_WORK_DIR/request.md" ]] \
                   && [[ $PRIOR_FILE = "$RB_WORK_DIR/prior.txt" ]] \
                   && [[ $HEAD_FILE = "$RB_WORK_DIR/head.txt" ]]
                then
                    # THE WORKING FILES ARE CREATED EMPTY BY REDIRECTION ALONE, so there is no command name to shadow.
                    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
                    > "$SUMMARY_FILE" ; > "$REQUEST_FILE" ; > "$PRIOR_FILE" ; > "$HEAD_FILE"
                    # AND THE COMPLETION LINE IS THE INNERMOST SUCCESS ARM. It is how the
                    # driver knows setup finished, so every refusal above has to be unable to
                    # REACH it — and with `exit` replaced by a function that returns, "the
                    # abort ran" does not mean "the line did not". Only containment does.
                    if [[ -f "$SUMMARY_FILE" ]] && [[ ! -s "$SUMMARY_FILE" ]] \
                       && [[ -f "$REQUEST_FILE" ]] && [[ ! -s "$REQUEST_FILE" ]] \
                       && [[ -f "$PRIOR_FILE" ]] && [[ ! -s "$PRIOR_FILE" ]] \
                       && [[ -f "$HEAD_FILE" ]] && [[ ! -s "$HEAD_FILE" ]]; then
                        echo "OWNER=$OWNER REPO=$REPO RB_SCRIPTS=$RB_SCRIPTS SUMMARY_FILE=$SUMMARY_FILE"
                    else
                        echo "ABORT: the session's working files were not created empty under $RB_WORK_DIR"
                        exit 1
                        [[ -n "" ]]
                    fi
                else
                    echo "ABORT: one of SUMMARY_FILE, REQUEST_FILE, PRIOR_FILE and HEAD_FILE is readonly in this shell; the session's working paths cannot be set"
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
        echo "ABORT: one of RB_PIN_DIR, RB_PIN_DIR2 and RB_PIN_SEEN is readonly, value-transforming, or aimed at another transport variable; the pin proof cannot be made"
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

#   pr-request-review.sh <pr> <auto-review: yes|no> < <body>
#
#     0  posted — the baseline is on stdout, and it is EMPTY on the automatic
#        path, where the trigger preceded us and there is nothing to capture
#     1  stopped — nothing was posted
#
# Write the account into `$REQUEST_FILE` with your file-writing tool — not from
# this shell, and NOT into `$SUMMARY_FILE`: one paragraph on what this change does
# and what to look at. It is inserted as DATA, so prose quoting a command line is
# posted rather than executed; a line reproducing one of the markers the loop reads
# as a record, or an `@codex review` on the automatic path, is refused rather than
# published. `$REQUEST_FILE` was created empty at setup and an empty body is
# refused, so a write that does not happen stops the request.
# THE NAME IS PROVEN ASSIGNABLE BEFORE THE MUTATION.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# THE PROBE IS A SUBSHELL, because a failed readonly assignment here is fatal.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# ONE PROBE VALUE IS ENOUGH, and a second proves nothing the first does not.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# THE VALUE IS COMPARED INSIDE IT, because a transforming attribute succeeds.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# THE PROBE IS A CONDITION WHOSE SUCCESS ARM HOLDS THE REQUEST.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
if { ( PRIOR_REVIEW="RbProbe$$$RANDOM$RANDOM"; [[ $PRIOR_REVIEW = RbProbe* ]] \
                    && [[ -z ${!PRIOR_REVIEW:-} ]] ) \
     || { echo "ABORT: PRIOR_REVIEW is readonly or value-transforming in this shell; the review baseline cannot be read back, and nothing has been posted."; [[ -n "" ]]; }; }
then
    # THE REQUEST IS A SCRIPT.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    # THE REQUEST RUNS AS A CONDITION.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    # THE BODY NEVER BECOMES SHELL SOURCE, because an account can close a heredoc.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    # AND THE FILE IS NOT WRITTEN FROM THIS SHELL, because `cat` and `printf` are names.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    # NOTHING HERE IS AN ASSIGNMENT.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    # THE ANSWER GOES TO A FILE, A PATH RATHER THAN A NAME.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    # THE CONTINUATION IS THE `then` BRANCH HERE TOO.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-request-review.sh N "$AUTO_REVIEW" < "$REQUEST_FILE" > "$PRIOR_FILE"; then
        PRIOR_REVIEW="$(<"$PRIOR_FILE")"
        # THE ASSIGNMENT IS PROVEN, because here there is something to prove it against.
        # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
        if [[ $PRIOR_REVIEW != "$(<"$PRIOR_FILE")" ]]; then
            echo "ABORT: the review baseline did not survive being read back; PRIOR_REVIEW is not this session's to set."
            exit 0
            [[ -n "" ]]
        else
            # EMPTY IS AN ANSWER, THE PATTERN IS A LITERAL, AND THERE ARE TWO SHAPES.
            # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
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
        # THE LAST WORD IS A RESERVED ONE, or a failed request reads as a posted one.
        # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
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
shipped, every script has a test, no fixture pipes a `printf` into `grep` — the
gate reports that shape whatever the reader, while the race itself needs an
early-exiting one such as `grep -q`, which under `pipefail` reports a present line
as missing; a producer the check does not name is left to review — and the suite
passes. That set is not
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
#   pr-close-round.sh gate N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW" "$HEAD_FILE"
#   pr-close-round.sh post N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW" "$HEAD_FILE"
#
# `gate` writes the head it proved into `$HEAD_FILE`; `post` reads it back out.
# The same path both times, and the value never enters this shell.
#
#     0  gated (`gate`) / closed (`post`)
#     1  stopped  — the reason is on stdout; the round is NOT closed
#     3  paused   — a round boundary. Decide with the operator
#
# Run `gate` from a checkout on this PR's branch. It pushes, and a push has to go
# somewhere: it names the ref it may write, proves every push URL of `origin` is
# the pinned repository, and refuses — having pushed nothing — if any of that does
# not hold. Every refusal is a 1 with the reason on stdout and the round untouched.
#
# Two kinds of refusal, and only one is retryable:
#
#   · this checkout — on another branch, or on a detached HEAD. Move to the
#     worktree holding the PR's branch and run it again. Nothing has happened;
#   · this PR — it is from a FORK, or `origin` pushes somewhere that is not the
#     pinned repository. Running it again changes nothing, because neither is
#     about where you are standing. Stop and put it to the operator: a fork PR is
#     outside what this loop drives, and a redirected `origin` is a configuration
#     decision that is not the loop's to make.
# THE ROUND CLOSES THROUGH A SCRIPT, because both orderings were prose in `SKILL.md`.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# THE GATE RUNS BEFORE THE REPLIES, because a resolve cannot be taken back.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# IT IS A REFUSAL BECAUSE THE ALTERNATIVE HAPPENED, and what it pushed was `main`.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# `$AUTO_REVIEW` IS PASSED, NOT WRITTEN IN.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# THE GATED HEAD TRAVELS IN A FILE, so no name in this shell has to hold it.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# AND THE STAGE RUNS AS A CONDITION, so a refusal cannot be walked past.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# AND THE HEAD IS PROVEN AN OID FROM A FILE THAT IS NOT THE SUMMARY, before the replies.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-close-round.sh gate N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW" "$HEAD_FILE"; then
    [[ -n x ]]    # a reserved word, not `:`, and TRUE — under `errexit` a false
                  # one here would end the shell on the successful path
else
    case $? in
        3) echo "Stopping here: the operator decides at a round boundary."
           exit 3
           [[ -n "" ]] ;;
        *) echo "The round did not close, and nothing has been resolved or posted. The reason is above; do not retry it blind."
           exit 1
           [[ -n "" ]] ;;
    esac
fi
if [[ ! $HEAD_FILE -ef $SUMMARY_FILE ]]; then
    case "$(<"$HEAD_FILE")" in
        ????????????????????????????????????????)
            case "$(<"$HEAD_FILE")" in
                *[!0-9a-f]*)
                    echo "ABORT: $HEAD_FILE does not hold a commit id, so no gate has proven a head. Do not resolve any thread."
                    exit 1
                    [[ -n "" ]] ;;
            esac ;;
        *)  echo "ABORT: $HEAD_FILE does not hold a commit id, so no gate has proven a head. Do not resolve any thread."
            exit 1
            [[ -n "" ]] ;;
    esac
else
    echo "ABORT: $HEAD_FILE and $SUMMARY_FILE are the same file, so the gate refused before it could write and what is there is the summary. Do not resolve any thread."
    exit 1
    [[ -n "" ]]
fi
```

**Now answer the threads** — reply, react 👍/👎, and resolve, per step 4 above.
The head is pushed and green, so a resolve is a claim that is true when made.
Then, and only then:

```bash
# THE POST STEP ASKS THE SAME QUESTION AGAIN, because it is a step a session can resume into.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
case "$(<"$HEAD_FILE")" in
    ????????????????????????????????????????)
        case "$(<"$HEAD_FILE")" in
            *[!0-9a-f]*)
                echo "ABORT: $HEAD_FILE does not hold a commit id, so no gate has proven a head for this round. Nothing has been posted."
                exit 1
                [[ -n "" ]] ;;
        esac ;;
    *)  echo "ABORT: $HEAD_FILE does not hold a commit id, so no gate has proven a head for this round. Nothing has been posted."
        exit 1
        [[ -n "" ]] ;;
esac
# ONLY NOW IS THE ROUND CLOSED, after the threads are answered.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# AND THE HEAD IS RE-PROVED BEFORE ANYTHING IS POSTED.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
POST_OUT="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-close-round.sh post N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW" "$HEAD_FILE" 2>&1)"; ROUND_RC=$?
printf '%s\n' "$POST_OUT"
# THE BASELINE COMES BACK IN THE SUCCESS RECORD, and step 3's watch needs exactly it.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
if [ "$ROUND_RC" -eq 0 ]; then
    # THE RECORD HAS TO BE THERE.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    # THE BASELINE MAY LEGITIMATELY BE EMPTY, which is a different question.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    CLOSED_REC="$(printf '%s\n' "$POST_OUT" | sed -n '/^PR_ROUND_CLOSED /p' | tail -1)"
    [ -n "$CLOSED_REC" ] \
        || { echo "ABORT: the round reported no closing record; step 3 would watch against a stale baseline."; exit 1; }
    # THE FIELD IS WHAT IS CHECKED FOR, not what is in it.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    case "$CLOSED_REC" in
        *' prior-review='*) ;;
        *) echo "ABORT: the closing record carries no baseline field; step 3 would watch against a stale one."; exit 1 ;;
    esac
    # `prior-review=` IS LAST IN THE RECORD, so everything after it is the value.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
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
# boundary.
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
# phase changed. If Codex approved on the first pass with no fix rounds, say so.
#
# THE RESERVED MARKERS MUST NOT START A LINE IN THIS BODY:
# `**Review-Signoff:**`, `**Review-Signoff-Revoked:**`, `**Review-Pause-Acknowledged:**`.
# Indent one by four spaces or quote it inline. A fence does not help — the readers
# scan the raw body, where a line inside a fence still begins at column 0.
# `**Reviewed commit:**` is not one of them and is left alone.
#
# `@codex review` is matched ANYWHERE in the body, case-insensitively, so
# indenting, quoting or fencing it changes nothing: break the mention up, or
# write it without the `@`.
# THE ACCOUNT IS PROSE, AND MUST NOT BECOME A RECORD, A REQUEST, OR A FRAGMENT.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
cat > "$SUMMARY_FILE" <<'EOF' || { echo "ABORT: could not write the phase body."; exit 1; }
<what the PR does, and what the Codex phase changed — one paragraph>
EOF
# WHICH REPOSITORY THIS ACTS ON IS SETTLED IN THE SETUP BLOCK, not here.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
PHASE_OUT="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-copilot-phase.sh record N "$SUMMARY_FILE" 2>&1)"; PHASE_RC=$?
printf '%s\n' "$PHASE_OUT"
case "$PHASE_RC" in
    0|3) ;;   # 3 is a pause, and the signoff is recorded either way
    *) echo "The phase did not advance and no signoff was recorded. The reason is above; do not retry it blind."; exit "$PHASE_RC" ;;
esac
# THE SIGNED-OFF HEAD IS READ BACK FROM THE RECORD, on the pause as well as on 0.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
CODEX_SHA="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-signoff.sh sha N "$CODEX_BOT")"; SHA_RC=$?
RX_PHASE_SHA40='^[0-9a-f]{40}$'
# THE STATUS AND THE SHAPE, because neither covers the other.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
if [[ $SHA_RC -eq 0 ]] && [[ $CODEX_SHA =~ $RX_PHASE_SHA40 ]]; then
    if [[ $PHASE_RC -eq 3 ]]; then
        echo "Stopping here: the operator decides at a round boundary. Codex is signed off on $CODEX_SHA, so merging on that signoff is one of the answers."
        exit 3
    fi
else
    echo "ABORT: no Codex signoff could be read back for this phase (rc=$SHA_RC, sha='$CODEX_SHA'); step 8 would have nothing to gate on"
    exit 1
    # THE LAST WORD IS A RESERVED ONE, because both lines above it can be taken away.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
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
# then.
# PROVED STILL OPEN THREE TIMES, AND THE ORDER IS revoke, prove, baseline, request.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
OPEN_OUT="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-copilot-phase.sh open N "$CODEX_SHA" 2>&1)"; OPEN_RC=$?
printf '%s\n' "$OPEN_OUT"
[ "$OPEN_RC" -eq 0 ] \
    || { echo "The Copilot phase did not open. This is not permission to skip the pass: decide with the operator."; exit "$OPEN_RC"; }
WHO="$COPILOT_BOT"
# THE BASELINE COMES BACK IN THE SUCCESS RECORD, AND THE RECORD IS WHAT IS CHECKED.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
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
# `$CODEX_SHA` is passed as well as the head being read, because whether the two
# are EQUAL decides which question the stop asks.
# THE MODE IS SET BEFORE ANYTHING IN STEP 8 RUNS, and `codex-only` is not a skip.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
REVIEWERS=both   # or `codex-only`
# THE SESSION PIN SETTLES THE REPOSITORY HERE AS WELL, and the gate below is another question.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-copilot-phase.sh close N "$CODEX_SHA" "$REVIEWERS"
CLOSE_RC=$?
# `[[`, A RESERVED WORD, NOT `[` — and the branch ends in one too.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
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
#   pr-phase-state.sh <pr>
#
#     0  readable, and the record it names still stands
#     1  stopped — the record on stdout says which: no signoff, a moved head, or a
#        verdict that no longer stands
#     2  unreadable — fail closed. NOT "no signoff"
#
# THE PHASE IS A FACT ON THE PR, NOT SOMETHING A SESSION REMEMBERS.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# READING IT IS A HELPER, because 112 lines here exited 0 on every refusal.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# THERE IS NO STATUS VARIABLE; THE STATUS IS BRANCHED WHERE IT IS PRODUCED.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# THE CONTINUATION IS THE `then` BRANCH, and nothing follows it.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# THE HELPER RUNS AS A CONDITION, which is what exempts it from `errexit`.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-phase-state.sh N; then
    # THE SHA THE GATE IS PINNED TO, its status and its shape both checked.
    # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
    CODEX_SHA="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-signoff.sh sha N "$CODEX_BOT")"; SIGNOFF_RC=$?
    RX_SHA40='^[0-9a-f]{40}$'
    if [[ $SIGNOFF_RC -ne 0 ]] || ! [[ "$CODEX_SHA" =~ $RX_SHA40 ]]; then
        echo "ABORT: the recorded Codex signoff did not read back as a sha (rc=$SIGNOFF_RC, sha='$CODEX_SHA')"
        exit 0
        # THE LAST WORD IS A RESERVED ONE, and this branch needs it as much as step 7's.
        # WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
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
#   pr-merge-gate.sh <pr> <codex-sha> <auto-review>
#
#     0  merged   — the head it names is on the base branch
#     1  blocked  — a gate refused; the reason is on stdout
#     3  paused   — a round boundary. NOT a refusal: decide with the operator
#     4  queued   — the request was accepted but the PR is not MERGED. A merge
#                   queue does that, and `gh` reports it as success. The head is
#                   not on the base branch; the session is not finished
#
# CODEX_SHA is the FULL 40-hex head Codex signed off on, captured and validated in
# step 7. In the Copilot phase the head moves past it and Codex is deliberately not
# re-run, so this — not the current head — is what Codex's verdict is checked
# against. THERE IS NO PLACEHOLDER TO FILL IN: the value is already in this session.
#
# REVIEWERS is `both` unless the operator chose otherwise at the stop that closed
# the Codex phase.
# THE GATE IS A SCRIPT.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# RUN FROM THE REPOSITORY THIS SESSION STARTED IN.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# AUTO_REVIEW IS PASSED AS AN ARGUMENT, not read from the environment.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# THERE IS NO PLACEHOLDER HERE, and that is the third attempt at this line.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# REVIEWERS IS `both` UNLESS THE OPERATOR CHOSE OTHERWISE at the Codex stop.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
# `codex-only` IS NOT A WEAKER GATE, and requires the head to BE the signed commit.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
(cd "$REPO_DIR" && /usr/bin/env bash -p "$RB_SCRIPTS"/pr-merge-gate.sh N "$CODEX_SHA" "$AUTO_REVIEW" "$REVIEWERS")
MERGE_RC=$?
case "$MERGE_RC" in
    0) ;;   # merged; the script printed the head it pinned
    3) echo "Stopping here: the operator decides whether to merge at a round boundary." ;;
    4) echo "NOT merged: the request was accepted but the PR is not MERGED — a merge queue takes the request without landing it. Do not close this out; confirm on the PR." ;;
    *) echo "Not merged. The reason is above; do not retry it blind." ;;
esac
# THE STATUS LEAVES THIS BLOCK, or a blocked merge reports success.
# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md
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
