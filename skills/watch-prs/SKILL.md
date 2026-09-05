---
name: watch-prs
description: Use when driving a pull request through review to merge. Requests reviews from the native GitHub reviewers (Codex via an @codex mention, Copilot via a review request), reads their findings, works the fix → reply → resolve → re-request loop, and gates the merge on a clean signoff from the current head. No daemons, no local reviewer process.
---

# /watch-prs — native PR review loop

Both reviewers are first-party GitHub apps. Nothing runs locally — no watcher, no daemon:
you drive the loop with `gh` and the helper scripts, and every stop below is the
operator's decision.

With `WATCH_PR_AUTONOMOUS=1` exported the operator has made the decision stops in advance:
each carries an **Unattended:** line naming its answer, taken without asking and recorded
on the PR as the operator's word would be. A stop that exists because something could not
be read, proved or told apart has no such line and is never answered by it. Whether this
session is unattended is the status of one test, run once per session: 0 is unattended and
1 attended, and the value is the switch's alone, so `yes` or `true` is attended.

```bash
[[ ${WATCH_PR_AUTONOMOUS:-} = 1 ]]
```

| Reviewer | Login | Trigger |
| --- | --- | --- |
| Codex | `chatgpt-codex-connector[bot]` | a comment containing `@codex review`, or automatically on push if the repo has auto-review on |
| Copilot | `copilot-pull-request-reviewer[bot]` | `gh pr edit <PR> --add-reviewer @copilot` |

**Once per account** the Codex GitHub connector must be linked at
`chatgpt.com/codex/cloud/settings/connectors`. Until it is, `@codex` replies *"To use
Codex here, create a Codex account and connect to github"* — that reply is the
diagnostic, not a review. Per-repository behaviour (auto-review, trigger condition,
exhaustive review, credit use) is set on the Codex **Code review** settings page.

**The loop:** derive identity → 1 state the task → 2 request Codex → 3 wait → 4 read the
findings → 5 fix and close the round, with the check-in of 6 inside it → back to 3 until
Codex is clean → 7 STOP, and on the operator's word the Copilot phase, which is 3–6 again
with `$WHO` switched → 8 STOP, and on the operator's word the merge gate. Every helper is
started as `/usr/bin/env bash -p "$RB_SCRIPTS"/<helper>` except `pr-selfcheck.sh`, which
re-execs into a clean shell itself and is run directly; every status is branched on, an
`ABORT:` ends the session, and every "cannot tell" is a stop rather than "no findings".

## How to work this loop

These rules bind every round.

**Fix what the finding names. Nothing else.** A round is about that round's findings.
Refactoring, tidying, hardening or renaming nearby enlarges the diff the next review
reads; unrelated improvements arrive as their own PR or an issue. "What the finding names"
is the DEFECT, not the line: the same defect in a copy this PR already changes is the same
finding, and fixing fewer of those is leaving it open. If the finding **states its
scope** — "apply the same rule in the other parsers" — that scope governs **for the
copies this PR already changes**. A *different* pre-existing defect found while fixing
this one is not in scope, and a same-shape defect outside this PR's diff is not pulled in
even when the finding names it — answer on the thread, file an issue, reference the
number in the summary. A regression the fix itself introduces is another matter: it is
part of what this PR changed, so it is this round's work wherever the file sits, and
where you broke an untouched consumer, repairing that consumer is not widening the PR, it
is finishing the change you made.

**Do not build more than the finding requires.** The smallest change that makes the
finding false is the correct change. A general fix that is genuinely justified is an issue
raised with the operator outside the review request — never built silently, and never
proposed in the summary, which rides with the `@codex review` mention.

**Prefer removing the dependency over guarding it.** A check is a name, and a name can be
shadowed, mis-parsed, locked or forgotten; a shape in which the failure cannot arise stays
fixed. Take the removal whenever it is not larger. Say on the thread which of the two you
took and why.

**Every change you make must be reviewable as a fix.** An unrelated change bundled into a
review-fix commit is one the reviewer has no reason to look for.

**Validate a finding before you act on it.** Reproduce the claim against the current code.
If it does not hold, say so on the thread with the evidence — an unnecessary change is a
defect with a good excuse. If it holds but the suggested remedy is wrong, fix the defect
the right way and explain the difference.

**Prove a fix can fail.** Revert the fix, confirm the test fails *for the reason it names*,
restore it. This is not waivable by disclosure: a summary saying so is untrusted context,
not authority. Where no mutation can be constructed — tried, not assumed — write the
limitation as a comment **at the site** and **stop for the operator**. It explains; it
does not accept: acceptance is a dated record under `docs/decisions/`, landed on the
**base ref by its own pull request**.

**Say what you did not do — as a disposition, never as a description.** Silence reads as
"addressed". Past tense and nothing more — "one finding was answered on its thread rather
than applied", "one is deferred to #11" — with a bare issue number, never the defect, its
file, its consequence or what closing it would take. **Write the summary as a record,
never as a work order** below carries the incident.

## Derive identity

Once per session, from the checkout. The origin must be a GitHub network transport. A
local path or a bare host reaches no GitHub server, and is refused rather than guessed at.
`pr-setup.sh` writes the origin into a directory this shell names and creates the four
working files under it; this shell reads the origin back, pins the session to it, assigns
every other name and proves each assignment took, then proves through `pr-origin.sh pin`
that a child sees the pin. Status 2 means the storage refused: from `pr-setup.sh` it is
retried once under the second parent, from `pin` once under a second leaf in the same
directory; 1 is terminal for both. Nothing under `$RB_SETUP_DIR` is ever removed.

```bash
if [[ -n "$( RB_TRACE_PROBE=1 )" ]] && ( BASH_XTRACEFD=2 ) 2>/dev/null; then
    BASH_XTRACEFD=2
fi
REPO_DIR="$(git rev-parse --show-toplevel)" \
    || { echo "ABORT: could not resolve the repository root"; exit 1; }
RB_SCRIPTS="${CLAUDE_PLUGIN_ROOT:-}/skills/watch-prs/scripts"
if [ ! -d "$RB_SCRIPTS" ]; then
    RB_CANDIDATES="$(ls -dt "$HOME"/.claude/plugins/cache/*/watch-pr-skill/*/skills/watch-prs/scripts 2>/dev/null)" \
        || { echo "ABORT: could not enumerate installed plugin copies"; exit 1; }
    RB_SCRIPTS="$(printf '%s\n' "$RB_CANDIDATES" | head -1)" \
        || { echo "ABORT: could not select an installed plugin copy."; exit 1; }
fi
[ -d "$RB_SCRIPTS" ] && [ -x "$RB_SCRIPTS/pr-review-state.sh" ] \
    || { echo "ABORT: could not locate the plugin helper scripts"; exit 1; }

unset -f rb_identity 2>/dev/null \
    || { echo "ABORT: a pre-existing rb_identity could not be cleared"; exit 1; }
. "$RB_SCRIPTS/identitylib.sh" \
    || { echo "ABORT: could not load the identity parser from $RB_SCRIPTS"; exit 1; }
[ "$(type -t rb_identity 2>/dev/null)" = function ] \
    || { echo "ABORT: the identity parser loaded but defines nothing"; exit 1; }
if ( RB_TMPPARENT="RbProbe$$$RANDOM$RANDOM"; [[ $RB_TMPPARENT = RbProbe* ]] \
     && [[ -z ${!RB_TMPPARENT:-} ]] ) 2>/dev/null \
   && ( RB_TMPPARENT2="RbProbe$$$RANDOM$RANDOM"; [[ $RB_TMPPARENT2 = RbProbe* ]] \
     && [[ -z ${!RB_TMPPARENT2:-} ]] ) 2>/dev/null \
   && ( RB_SETUP_DIR="RbProbe$$$RANDOM$RANDOM"; [[ $RB_SETUP_DIR = RbProbe* ]] \
     && [[ -z ${!RB_SETUP_DIR:-} ]] ) 2>/dev/null \
   && ( RB_PIN_SEEN="RbProbe$$$RANDOM$RANDOM"; [[ $RB_PIN_SEEN = RbProbe* ]] \
     && [[ -z ${!RB_PIN_SEEN:-} ]] ) 2>/dev/null \
   && ( CODEX_SHA="RbProbe$$$RANDOM$RANDOM"; [[ $CODEX_SHA = RbProbe* ]] \
     && [[ -z ${!CODEX_SHA:-} ]] ) 2>/dev/null \
   && ( CODEX_BOT="RbProbe$$$RANDOM$RANDOM"; [[ $CODEX_BOT = RbProbe* ]] \
     && [[ -z ${!CODEX_BOT:-} ]] ) 2>/dev/null \
   && ( COPILOT_BOT="RbProbe$$$RANDOM$RANDOM"; [[ $COPILOT_BOT = RbProbe* ]] \
     && [[ -z ${!COPILOT_BOT:-} ]] ) 2>/dev/null \
   && ( SUMMARY_FILE="RbProbe$$$RANDOM$RANDOM"; [[ $SUMMARY_FILE = RbProbe* ]] \
     && [[ -z ${!SUMMARY_FILE:-} ]] ) 2>/dev/null \
   && ( REQUEST_FILE="RbProbe$$$RANDOM$RANDOM"; [[ $REQUEST_FILE = RbProbe* ]] \
     && [[ -z ${!REQUEST_FILE:-} ]] ) 2>/dev/null \
   && ( PRIOR_FILE="RbProbe$$$RANDOM$RANDOM"; [[ $PRIOR_FILE = RbProbe* ]] \
     && [[ -z ${!PRIOR_FILE:-} ]] ) 2>/dev/null \
   && ( HEAD_FILE="RbProbe$$$RANDOM$RANDOM"; [[ $HEAD_FILE = RbProbe* ]] \
     && [[ -z ${!HEAD_FILE:-} ]] ) 2>/dev/null \
   && ( WHO="RbProbe$$$RANDOM$RANDOM"; [[ $WHO = RbProbe* ]] \
     && [[ -z ${!WHO:-} ]] ) 2>/dev/null \
   && ( RB_REMOTE="RbProbe$$$RANDOM$RANDOM"; [[ $RB_REMOTE = RbProbe* ]] \
     && [[ -z ${!RB_REMOTE:-} ]] ) 2>/dev/null \
   && ( RB_NONCE="RbProbe$$$RANDOM$RANDOM"; [[ $RB_NONCE = RbProbe* ]] \
     && [[ -z ${!RB_NONCE:-} ]] ) 2>/dev/null \
   && ( RB_NONCE_SEQ="RbProbe$$$RANDOM$RANDOM"; [[ $RB_NONCE_SEQ = RbProbe* ]] \
     && [[ -z ${!RB_NONCE_SEQ:-} ]] ) 2>/dev/null; then
    RB_TMPPARENT=
    [[ ${TMPDIR:-} = /* ]] && [[ -d ${TMPDIR:-} ]] && [[ -w ${TMPDIR:-} ]] \
        && [[ -x ${TMPDIR:-} ]] && RB_TMPPARENT="$TMPDIR"
    RB_TMPPARENT2=
    [[ ${HOME:-} = /* ]] && [[ -d ${HOME:-} ]] && [[ -w ${HOME:-} ]] \
        && [[ -x ${HOME:-} ]] && RB_TMPPARENT2="$HOME"
    [[ -n $RB_TMPPARENT ]] \
        || { RB_TMPPARENT="$RB_TMPPARENT2"; RB_TMPPARENT2=; }
    RB_SETUP_DIR=
    RB_SETUP_DIR="${RB_TMPPARENT:?neither TMPDIR nor HOME is an absolute directory this session can write to}/watch-pr-setup.$$.$RANDOM$RANDOM$RANDOM"
    if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-setup.sh "$RB_SETUP_DIR" \
       || { [[ $? -eq 2 ]] && [[ -n $RB_TMPPARENT2 ]] \
            && RB_SETUP_DIR="$RB_TMPPARENT2/watch-pr-setup-2.$$.$RANDOM$RANDOM$RANDOM" \
            && /usr/bin/env bash -p "$RB_SCRIPTS"/pr-setup.sh "$RB_SETUP_DIR" \
            && { RB_TMPPARENT="$RB_TMPPARENT2"; }; }
    then
        RB_REMOTE=
        if [[ -z $RB_REMOTE ]] \
           && { [[ -O /dev/fd/9 ]] && [[ -f /dev/fd/9 ]] \
                && RB_REMOTE="$(<"/dev/fd/9")"; } 9<"$RB_SETUP_DIR/origin"; then
            RB_REMOTE="${RB_REMOTE:?the file the setup helper wrote carries no origin; there is no repository to pin this session to}"
            [[ $RB_REMOTE = *$'\n'* ]] && RB_REMOTE=
            RB_REMOTE="${RB_REMOTE:?the origin read back spans more than one line; something wrote to that file between the helper and this shell}"
            REVIEW_BUS_REMOTE="$RB_REMOTE" rb_identity || RB_REMOTE=
            RB_REMOTE="${RB_REMOTE:?origin is not a usable identity: $RB_IDENTITY_REASON}"
            export REVIEW_BUS_REMOTE="$RB_REMOTE"
            CODEX_BOT='chatgpt-codex-connector[bot]'
            COPILOT_BOT='copilot-pull-request-reviewer[bot]'
            SUMMARY_FILE="$RB_SETUP_DIR/work/summary.md"
            REQUEST_FILE="$RB_SETUP_DIR/work/request.md"
            PRIOR_FILE="$RB_SETUP_DIR/work/prior.txt"
            HEAD_FILE="$RB_SETUP_DIR/work/head.txt"
            RB_NONCE_SEQ=0
            if [[ $CODEX_BOT = 'chatgpt-codex-connector[bot]' ]] \
               && [[ $COPILOT_BOT = 'copilot-pull-request-reviewer[bot]' ]] \
               && [[ $SUMMARY_FILE = "$RB_SETUP_DIR"/work/summary.md ]] \
               && [[ $REQUEST_FILE = "$RB_SETUP_DIR"/work/request.md ]] \
               && [[ $PRIOR_FILE = "$RB_SETUP_DIR"/work/prior.txt ]] \
               && [[ $HEAD_FILE = "$RB_SETUP_DIR"/work/head.txt ]] \
               && [[ $RB_NONCE_SEQ = 0 ]] \
               && [[ -f $SUMMARY_FILE ]] && [[ ! -s $SUMMARY_FILE ]] \
               && [[ -f $REQUEST_FILE ]] && [[ ! -s $REQUEST_FILE ]] \
               && [[ -f $PRIOR_FILE ]] && [[ ! -s $PRIOR_FILE ]] \
               && [[ -f $HEAD_FILE ]] && [[ ! -s $HEAD_FILE ]]
            then
                export PR_CI_INTERVAL
                export PR_CI_TIMEOUT
                export PR_CI_GRACE
                export PR_CI_PROBE_TIMEOUT
                export REVIEW_MERGE_STRICT
                export RB_SUITE_JOBS
                RB_PIN_SEEN=
                if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh pin "$RB_SETUP_DIR/pin"; then
                    { [[ -O /dev/fd/9 ]] && [[ -f /dev/fd/9 ]] \
                        && RB_PIN_SEEN="$(<"/dev/fd/9")"; } 9<"$RB_SETUP_DIR/pin/pin"
                elif [[ $? -eq 2 ]] \
                     && /usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh pin "$RB_SETUP_DIR/pin2"; then
                    { [[ -O /dev/fd/9 ]] && [[ -f /dev/fd/9 ]] \
                        && RB_PIN_SEEN="$(<"/dev/fd/9")"; } 9<"$RB_SETUP_DIR/pin2/pin"
                fi
                if [[ -n $RB_PIN_SEEN ]] && [[ $RB_PIN_SEEN = "$RB_REMOTE" ]]; then
                    echo "OWNER=$OWNER REPO=$REPO RB_SCRIPTS=$RB_SCRIPTS SUMMARY_FILE=$SUMMARY_FILE"
                else
                    echo "ABORT: the repository pin did not take; every stage would route by the current directory. Re-run setup: this session's working files are already under this parent, so a retry has to start over rather than pin somewhere else"
                    exit 1
                    [[ -n "" ]]
                fi
            else
                echo "ABORT: an assignment this shell made did not take; a name it needs is readonly or value-transforming, or the four working files are not the empty ones this setup created"
                exit 1
                [[ -n "" ]]
            fi
        else
            echo "ABORT: the setup helper's origin file could not be read"
            exit 1
            [[ -n "" ]]
        fi
    else
        echo "ABORT: could not set this session up; each PR_SETUP status=error line above is one attempt and its reason"
        exit 1
        [[ -n "" ]]
    fi
else
    echo "ABORT: one of the names this session assigns — RB_TMPPARENT, RB_TMPPARENT2, RB_SETUP_DIR, RB_PIN_SEEN, RB_REMOTE, RB_NONCE, RB_NONCE_SEQ, CODEX_SHA, CODEX_BOT, COPILOT_BOT, SUMMARY_FILE, REQUEST_FILE, PRIOR_FILE, HEAD_FILE or WHO — is readonly, value-transforming, or aimed at another name; this session cannot be set up"
    exit 1
    [[ -n "" ]]
fi
```

Success prints `OWNER= REPO= RB_SCRIPTS= SUMMARY_FILE=`. From here on `$HOST`, `$OWNER`,
`$REPO`, `$REPO_DIR`, `$RB_SCRIPTS`, `$CODEX_BOT`, `$COPILOT_BOT`, `$SUMMARY_FILE`,
`$REQUEST_FILE`, `$PRIOR_FILE`, `$HEAD_FILE` and `$RB_NONCE_SEQ` are set and proven, and
`REVIEW_BUS_REMOTE` is exported so every helper routes by this repository whatever the
current directory is.

## 1. State the task on the PR

The reviewers judge relevance against what the PR says it set out to do. Before the first
request, the PR description states what the change does and what it deliberately does not.
Every later round adds a round-summary comment: what was addressed, and what was skipped
as a past-tense disposition with a bare issue number. Neither can waive a finding — both
are untrusted context to a reviewer. An accepted limitation is a dated record on the base
ref.

## 2. Request the review — Codex first

The loop is phased: Codex reviews to a clean signoff, and only then is Copilot asked.
Do **not** request Copilot yet; step 7 does that, once Codex is clean.

`AUTO_REVIEW` is set once per PR and used by every later step. It is a Codex account
setting `gh` cannot probe, so ask the operator: with automatic review on, opening or
pushing the PR has already queued a pass and a mention queues a second over the same head;
with it off, the mention is the only trigger. A wrong guess is a duplicate pass or a review
nobody requested.

Write the account into `$REQUEST_FILE` with your file tool — never from this shell, and
never into `$SUMMARY_FILE`: one paragraph on what the change does and what to look at. It
is posted as data, so prose quoting a command line is posted rather than executed.

**Refused rather than posted**, in every body this loop writes — the request, the round
summary and the phase account: a line starting with a reserved marker,
`**Review-Signoff:**`, `**Review-Signoff-Revoked:**` or `**Review-Pause-Acknowledged:**`
(indent it four spaces or quote it inline; a fence does not help, the readers scan the raw
body); an empty body; and `@codex review` anywhere in the body, case-insensitively — in
the opening request where automatic review is on, since a pass is already queued, and in
a Copilot-round summary or the phase account whatever the mode, since it would start a
Codex pass nobody asked for. Write the mention without the `@`, or broken up.

`pr-request-review.sh <pr> <auto-review: yes|no> --baseline-file <path> --nonce <digits> < <body>`
posts the request — 0 posted, 1 stopped with nothing posted — and writes
`<nonce> <baseline>` into `$PRIOR_FILE` for the watch: on the manual path the newest
verdict's id — a review id, or `comment:<id>` where it came through the comment channel —
and on the automatic path `none`, where the trigger preceded us and there is nothing to
capture. The nonce is generated fresh before every request, as below, and the watch
refuses a baseline that carries any other.

```bash
AUTO_REVIEW=no   # or `yes`, per the repo's Codex Code review settings
if ( WHO="RbProbe$$$RANDOM$RANDOM"; [[ $WHO = RbProbe* ]] \
     && [[ -z ${!WHO:-} ]] ) 2>/dev/null \
   && { WHO="$CODEX_BOT"; [[ $WHO = "$CODEX_BOT" ]]; }
then
    RB_NONCE=
    RB_NONCE="$(/usr/bin/env -i PATH="$PATH" perl -e 'printf "%010d%07d%06d\n", time, $$ % 10000000, int(rand 1e6)')"
    [[ $RB_NONCE = *[!0-9]* || ${#RB_NONCE} -ne 23 ]] && RB_NONCE=
    [[ -n $RB_NONCE ]] && RB_NONCE="$RB_NONCE$((RB_NONCE_SEQ+1))"
    RB_NONCE_SEQ=$((RB_NONCE_SEQ+1))
    [[ ${RB_NONCE%"$RB_NONCE_SEQ"} = "${RB_NONCE:0:23}" ]] || RB_NONCE=
    RB_NONCE="${RB_NONCE:?the request nonce did not take — a name this shell needs is readonly or transforming, and the watch could not tell this round's baseline from the last one's}"

    if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-request-review.sh N "$AUTO_REVIEW" --baseline-file "$PRIOR_FILE" --nonce "$RB_NONCE" < "$REQUEST_FILE"; then
        [[ -n x ]]
    else
        echo "ABORT: no review was requested; the reason is above. Do not enter the wait step."
        exit 0
        [[ -n "" ]]
    fi
else
    echo "ABORT: WHO is readonly, value-transforming, or aimed at another name, so every stage below would be addressed to the wrong reviewer — or would overwrite whatever WHO points at. Nothing has been posted."
    exit 1
    [[ -n "" ]]
fi
```

Either way the wait step is next: a pass is in flight, or one has just been asked for.

## 3. Wait for the verdict

`$WHO` is the active reviewer — set and proven in step 2, switched in step 7 — and
`$PRIOR_FILE` and `$RB_NONCE` are what the step that made the request left; none of them
is re-assigned here. Do not poll by hand: `pr-watch.sh` blocks until there is something
to act on and prints one line per state change.

```bash
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-watch.sh N "$WHO" --after-review-file "$PRIOR_FILE" --require-nonce "$RB_NONCE"; WATCH_RC=$?
```

**Claude Code** — run it as this session's **Monitor**, so the verdict surfaces into the
chat by itself:

- `command`: `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-watch.sh N "$WHO" --after-review-file "$PRIOR_FILE" --require-nonce "$RB_NONCE"`
- `description`: `Review verdict for PR N` · `timeout_ms`: `3600000` · `persistent`: `true`

**Arm it as part of the round, and re-arm it the same way — do not ask.** One arming
covers one verdict, so every request needs its own, for the reviewer `$WHO` names. It
reads no secrets and changes nothing; a harness that prompts anyway is a permissions gap,
which `README.md § Watching without prompts` answers.

```
PR_REVIEW_WATCH pr=10 reviewer=chatgpt-codex-connector[bot] state=pending waited_s=120
PR_REVIEW_READY  pr=10 reviewer=chatgpt-codex-connector[bot] state=reviewed verdict=findings findings=5
```

| `WATCH_RC` | meaning | what to do |
| --- | --- | --- |
| `0` | terminal state reached, verdict on the last line | step 4 |
| `1` | timed out — the review is still in flight | **re-arm the same watch.** Do not re-request: that queues a duplicate pass on the same head. Do not ask. |
| `2` | the state could not be read | **fail closed** — never "no findings" |
| `4` | the review carried comments and **every one was a reply** | **STOP. Do not go to step 4.** Nothing to list and not a signoff: no round to fix, none to close. Put the comment to the operator. |

States: `none` no review on this head · `pending` a draft is open · `reviewed` a
submitted APPROVED/COMMENTED review · `blocked` CHANGES_REQUESTED — findings, plus its
body in step 4 · `dismissed` the signoff was withdrawn — request again.

**On `4` the operator's answer must become state**, or the stop is a deadlock: the watch
returns 4 for as long as that review is the newest, there is no thread to resolve, and
re-requesting is forbidden.

- **It was a clean verdict** — record the signoff, the same `**Review-Signoff:**` line
  step 7 writes: reviewer and head in backticks, and the verdict's time as a third field
  whenever you have it, since that is what a later revocation is ordered against. Record
  it AFTER reading: it must be newer than the later of that review and its newest reply,
  or the merge gate and `pr-phase-state.sh` refuse it, naming both times. If a reply lands
  while you decide, read it and record again. The gate accepts the record for this shape
  only — `source=replies-only` plus a signoff naming that head — and says so.
- **It was a finding** — fix it and push. The head moves and the round is ordinary again.

Absence is not permission: with no signoff recorded, the gate refuses and names what to do.

## 4. Read the findings

Inline review comments are the findings. The review body is the non-blocking channel and
does not gate the merge, with one exception below.

```bash
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-findings.sh list N; FIND_RC=$?
```

- `0` — the printed threads are the complete set of unresolved findings, each with its
  full body under its `thread=`/`comment=` line.
- `2` — the read could not be trusted. **Stop.** Do not reply, resolve or summarise.

When the state is `blocked`, read the review body too: a `CHANGES_REQUESTED` review can
carry its whole argument there with no inline comment, and the merge gate then refuses
while `list` shows nothing to fix.

```bash
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-findings.sh blocked-body N "$WHO"; BODY_RC=$?
```

`BODY_RC` carries the same contract: `2` is a stop, and empty output from a failed read is
"could not read", not "no body". The head argument is omitted on purpose — the helper
resolves the head itself, and a stale `CHANGES_REQUESTED` on an older commit is not an
active finding.

### Read each finding whole, not just its title

`list` prints one line per thread so the set is countable. **That line is not the
finding.** The argument is in the body printed under it. Read it there and nowhere else:
`pulls/N/comments` has no resolution filter and returns every comment the PR ever had, so
it hands you findings answered rounds ago. Three things in a body change what you do:

- **A code suggestion** — a fenced suggestion block, or a patch in the prose. Treat it as
  a proposal rather than an instruction: it was written without your context. Where you
  disagree, implement the correct fix and say on the thread why the suggestion was not
  taken.
- **A stated consequence** — "…so the merge proceeds with no trusted checks result" is
  what the test asserts. A test of the mechanism alone leaves it unproven.
- **A scope hint** — "apply the same rule in the other parsers" is part of the finding,
  for the copies this PR changes.

Reply to each thread with what changed and why, not "fixed".

## 5. Fix, then close the round

Fix the findings; where you disagree, say so on the thread rather than resolving it
silently. Then, in this order:

1. **commit** — `fix(review): <what changed>`. In the Copilot phase add a
   `Review-Phase: copilot` trailer: it tells the merge gate the head advanced only through
   Copilot fixes, so Codex's signoff still covers it. `git` reads trailers from the
   LAST paragraph only, so it goes in the same block as `Co-Authored-By:` with no blank
   line above it:

   ```
   fix(x): what changed

   Why it changed.

   Review-Phase: copilot
   Co-Authored-By: …
   ```

   A blank line above it makes it invisible to the gate, which reports `untagged_commit`;
   `pr-merge-range.sh` names that case `trailer_not_in_trailer_block`;
2. **run the self-check — step 5a — and fix what it finds**, before anything leaves the
   machine;
3. **check the round boundary — step 6.** Both this and the self-check precede the push:
   with automatic review on the push itself requests the next review, so a check after it
   stops nothing. **The push is not here** — `gate` below pushes, because the checks on
   what it pushes decide whether the round may close at all;
4. **run `pr-close-round.sh gate`** — the recipe below — and only then reply to each
   thread with what changed, react to it, resolve it, and verify the resolve succeeded:
   `resolveReviewThread` returns `thread{isResolved}`; read it. A resolve cannot be taken
   back, so it follows the pushed, green head.

   The reaction is the only signal the reviewer gets about whether a review was worth
   making. `list` prints `comment=<id>` beside `thread=<id>` for it: the thread id
   resolves over GraphQL, the comment id reacts over REST.

   ```bash
   # 👍 acted on, or correct and recorded as accepted; 👎 only when wrong on the facts
   gh api --hostname "$HOST" --silent -X POST "repos/$OWNER/$REPO/pulls/comments/<comment-id>/reactions" \
       -f content='+1' || echo "note: reaction failed for <comment-id>"
   ```

   A failed reaction is a note, not an abort;
5. **run `pr-close-round.sh post`** — it re-proves that head, posts the summary and
   re-requests `$WHO`. The irreversible parts of a round come last.

### 5a. Self-check before the push

Rounds are the expensive part of this loop; a finding a script can make in a second must
not cost a review pass.

```bash
"$RB_SCRIPTS"/pr-selfcheck.sh; SELF_RC=$?
```

- `0` — the mechanical checks pass. Continue with the list below.
- `1` — findings. Fix them now.
- `2` — the check could not run. Fail closed.
- `3` — **not applicable**: this repository is not a `watch-pr-skill` checkout, so nothing
  was in scope. Normal in every other project, and a separate status from `0` on purpose:
  nothing was verified, so say so in the summary rather than claiming a clean check.

Then read your own diff against the classes that produced the rounds:

- Did I fix the instance or the class, within this diff? Before fixing a finding, search
  for the same shape **everywhere else this PR already changes** and fix those together.
- Did I widen something — a validator, a contract — without rechecking what consumes it?
- Did I trace every identifier and ordering I touched, end to end?
- Can each new assertion actually fail, for the reason it names?
- Did I answer the finding, or just silence it?

Write what this pass changed into the round summary; if it found nothing, say so.

### The order depends on what triggers the review

The reviewer reads the newest round summary before the diff, so the summary has to exist
before the pass starts — and what starts it differs. With automatic review OFF the mention
is the trigger and the push is inert. With it ON the push starts the pass, so the order is
decided by what is irreversible: push, prove the checks, close afterwards. That pass reads
open threads and no summary, so it may re-report what this round answered; the explicit
request `post` makes supersedes it. A wasted pass is recoverable; a round closed on a red
head is not. `pr-close-round.sh` takes `$AUTO_REVIEW` and holds both orders:

```bash
if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-close-round.sh gate N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW" "$HEAD_FILE" "$PRIOR_FILE"; then
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
if [[ $HEAD_FILE != "$SUMMARY_FILE" ]] && [[ ! $HEAD_FILE -ef $SUMMARY_FILE ]] \
   && /usr/bin/env bash -p -c 'rb_handoff_is_sha() { return 127; }; . "$1"/writelib.sh 2>/dev/null || exit 9; rb_handoff_is_sha "$2"' \
      _ "$RB_SCRIPTS" "$HEAD_FILE"; then
    [[ -n x ]]
else
    if [[ $HEAD_FILE = "$SUMMARY_FILE" ]] || [[ $HEAD_FILE -ef $SUMMARY_FILE ]]; then
        echo "ABORT: $HEAD_FILE and $SUMMARY_FILE are the same file, so the gate refused before it could write and what is there is the summary. Do not resolve any thread."
    else
        echo "ABORT: $HEAD_FILE does not hold a commit id, is not a plain regular file, or could not be read. No gate has proven a head. Do not resolve any thread."
    fi
    exit 1
    [[ -n "" ]]
fi
```

`gate` pushed, proved the head green and wrote it into `$HEAD_FILE`; the read above proves
the file holds it. **Now answer the threads** — reply, react, resolve, per item 4 above.
Then, and only then:

```bash
RB_NONCE=
RB_NONCE="$(/usr/bin/env -i PATH="$PATH" perl -e 'printf "%010d%07d%06d\n", time, $$ % 10000000, int(rand 1e6)')"
[[ $RB_NONCE = *[!0-9]* || ${#RB_NONCE} -ne 23 ]] && RB_NONCE=
[[ -n $RB_NONCE ]] && RB_NONCE="$RB_NONCE$((RB_NONCE_SEQ+1))"
RB_NONCE_SEQ=$((RB_NONCE_SEQ+1))
[[ ${RB_NONCE%"$RB_NONCE_SEQ"} = "${RB_NONCE:0:23}" ]] || RB_NONCE=
RB_NONCE="${RB_NONCE:?the request nonce did not take; see step 2}"
if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-close-round.sh post N "$WHO" "$SUMMARY_FILE" "$AUTO_REVIEW" "$HEAD_FILE" "$PRIOR_FILE" "$RB_NONCE"; then
    exit 0   # the script printed the head it closed on
    [[ -n "" ]]
else
    case $? in
        3) echo "Stopping here: the pass left only replies, so there is nothing to fix and no signoff. Read it with the operator."
           exit 3
           [[ -n "" ]] ;;
        *) echo "The threads are answered but the round did not close: no summary was posted and no pass was requested. The reason is above; do not retry it blind."
           exit 1
           [[ -n "" ]] ;;
    esac
    [[ -n "" ]]
fi
```

In the Copilot phase the request is `gh pr edit --add-reviewer @copilot`, which no push
triggers, so the summary goes first — Copilot starts reading within seconds.
Re-request **only the active reviewer**, unless automatic review already has; the
boundary was checked before the push, so this step cannot outrun it.

### Write the summary as a record, never as a work order

State only what was done, in the past tense. A `@codex` mention whose body describes an
unfixed defect — its file, its consequence, what it would take to close — is read as a
task: Codex then edits and commits in an environment with no remote, the commit exists
nowhere, the review never happens and the round is spent. That happened here once.
Anything still open is a GitHub issue, linked by number and nothing more; a thread reply
is not a review request, so the argument lives there. A resolved thread is not a record of
a fix — the summary is.

## 6. Round check-in

Runs inside step 5, before the request-triggering command; counting afterwards would make
the pause a notification. Steps 7 and 8 check the same boundary.

```bash
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-round-count.sh N "$WHO"; ROUNDS_RC=$?
```

The count is per reviewer: a round is a distinct PR head that received a submitted review,
derived from GitHub each time, so it survives a new session.

- `0` — carry on.
- `2` — the count could not be established. Fail closed: do not re-request as if it were
  round one.
- `3` — **stop and decide with the operator.** Say what the rounds have been about, not
  only how many, and put all four options: **continue**; **merge now**; **leave it open**
  — the signoffs are on the PR and a later session resumes from them; **close it and
  start over with a better approach** — ten rounds is evidence about the approach, and
  this is the option a loop never proposes for itself. When the operator says continue,
  record it on the PR before requesting the next review, or every later call pauses on
  the same count. The count comes from the gate, not retyped, and its status must be the
  distinguished 3 — permission is never inferred from unreadable output:

  ```bash
  ROUNDS_OUT="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-round-count.sh N "$WHO" 2>/dev/null)"; ROUNDS_RC=$?
  if [[ $ROUNDS_RC == 3 ]]; then
      if ROUNDS="$(printf '%s\n' "$ROUNDS_OUT" \
                   | sed -n 's/^PR_ROUND_PAUSE .*rounds=\([0-9][0-9]*\).*/\1/p')"; then
          # 0 and non-digits are not counts: no pause happens at zero rounds
          case "$ROUNDS" in
              ""|0|*[!0-9]*)
                  echo "ABORT: could not read a round count to acknowledge; nothing was recorded." ;;
              *)
                  # the footer names the reviewer, because the count is per reviewer
                  gh pr comment N --repo "$HOST/$OWNER/$REPO" \
                      --body "$(printf 'Continuing after the round check-in.\n\n**Review-Pause-Acknowledged:** `%s` `%s`\n' "$WHO" "$ROUNDS")" \
                      || echo "ABORT: could not record the acknowledgement; do not request another review." ;;
          esac
      else
          echo "ABORT: could not parse the round count; nothing was recorded."
      fi
  else
      echo "ABORT: the round counter did not report a pause (rc=$ROUNDS_RC); nothing was recorded."
  fi
  ```

  Only OWNER, MEMBER and COLLABORATOR comments are read as acknowledgements, and one
  naming a round that has not happened yet is refused. `REVIEW_ROUND_THRESHOLD=0` disables
  the check-in entirely.

**Unattended:** continue — where the 3 is this boundary, which the stage's output says
with a `PR_ROUND_PAUSE` line. `gate`'s `PAUSE: the pass the push started left only replies`
is step 3's status 4 by another route, carries no such line, and stays a stop. Wherever a
stage reports the boundary — this counter, `gate`, `record`, `open` or the merge gate — it
belongs to the reviewer that stage counted: `$WHO` at the counter and `gate`, Codex at
`record` and `open`, Copilot at the merge gate; the template line the counter prints names
it. Record the acknowledgement above with that login in place of `$WHO`, say in the round
summary what the rounds have been about, and run the stage again — except `record`, which
pauses after its signoff is written and read back: go on to step 7's answer, since
running it twice records two signoffs. The count stays on the PR, where
`REVIEW_ROUND_THRESHOLD=0` would leave no record that the loop ran long.

## 7. Codex is clean — now the Copilot phase

When `pr-review-state.sh verdict N "$CODEX_BOT"` exits 0, the Codex loop is done. That
verdict counts every comment on the newest review, replies included: a retraction is a
paragraph after the verdict line, so no reading of the text separates them.
`source=replies-only` is neither answer — nothing to fix, and not a signoff. Stop and put
it to the operator; do not re-request, and do not treat it as clean. A malformed
`in_reply_to_id` is a stop too.

`pr-copilot-phase.sh` is the phase, in three stages with the operator's decision between
them. First write one paragraph into `$SUMMARY_FILE` — what the PR does and what the Codex
phase changed; say so if Codex approved on the first pass — under the body rules of step 2.
`record` proves Codex clean on an exact head, proves that head's checks, re-proves both
immediately before writing, orders any revocation against the verdict, and writes the
Codex signoff onto the PR:

```bash
cat > "$SUMMARY_FILE" <<'EOF' || { echo "ABORT: could not write the phase body."; exit 1; }
<what the PR does, and what the Codex phase changed — one paragraph>
EOF
if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-copilot-phase.sh record N "$SUMMARY_FILE" "$HEAD_FILE"; then
    if { [[ -f /dev/fd/9 ]] && CODEX_SHA="$(<"/dev/fd/9")" \
         && [[ ${#CODEX_SHA} -eq 40 ]] && [[ $CODEX_SHA != *[!0-9a-f]* ]]; } 9<"$HEAD_FILE"; then
        [[ -n x ]]
    else
        echo "ABORT: no usable Codex signoff sha could be read back for this phase; step 8 would have nothing to gate on."
        exit 1
        [[ -n "" ]]
    fi
else
    case $? in
        3) if { [[ -f /dev/fd/9 ]] && CODEX_SHA="$(<"/dev/fd/9")" \
                && [[ ${#CODEX_SHA} -eq 40 ]] && [[ $CODEX_SHA != *[!0-9a-f]* ]]; } 9<"$HEAD_FILE"; then
               echo "Stopping here: the operator decides at a round boundary. Codex is signed off on $CODEX_SHA, so merging on that signoff is one of the answers."
               exit 3
               [[ -n "" ]]
           else
               echo "ABORT: the phase paused but no usable signoff sha could be read back; step 8 would have nothing to gate on."
               exit 1
               [[ -n "" ]]
           fi ;;
        *) echo "The phase did not advance and no signoff was recorded. The reason is above; do not retry it blind."
           exit 1
           [[ -n "" ]] ;;
    esac
    [[ -n "" ]]
fi
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
# only when the operator chose the Copilot phase
RB_NONCE=
RB_NONCE="$(/usr/bin/env -i PATH="$PATH" perl -e 'printf "%010d%07d%06d\n", time, $$ % 10000000, int(rand 1e6)')"
[[ $RB_NONCE = *[!0-9]* || ${#RB_NONCE} -ne 23 ]] && RB_NONCE=
[[ -n $RB_NONCE ]] && RB_NONCE="$RB_NONCE$((RB_NONCE_SEQ+1))"
RB_NONCE_SEQ=$((RB_NONCE_SEQ+1))
[[ ${RB_NONCE%"$RB_NONCE_SEQ"} = "${RB_NONCE:0:23}" ]] || RB_NONCE=
RB_NONCE="${RB_NONCE:?the request nonce did not take; see step 2}"
if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-copilot-phase.sh open N "$CODEX_SHA" "$PRIOR_FILE" "$RB_NONCE"; then
    if ( WHO="RbProbe$$$RANDOM$RANDOM"; [[ $WHO = RbProbe* ]] \
         && [[ -z ${!WHO:-} ]] ) 2>/dev/null \
       && { WHO="$COPILOT_BOT"; [[ $WHO = "$COPILOT_BOT" ]]; }; then
        [[ -n x ]]
    else
        echo "ABORT: WHO is readonly or value-transforming in this shell, so the rounds below would poll the wrong reviewer. The phase IS open and Copilot HAS been requested; do not re-open it."
        exit 1
        [[ -n "" ]]
    fi
else
    case $? in
        3) echo "The phase stopped at a round boundary. This is not permission to skip the pass: decide with the operator."
           exit 3
           [[ -n "" ]] ;;
        *) echo "The Copilot phase did not open. This is not permission to skip the pass: decide with the operator."
           exit 1
           [[ -n "" ]] ;;
    esac
    [[ -n "" ]]
fi
```

Keep `$CODEX_SHA` for step 8: it is the only record of what Codex approved. Then run steps
3–6 again with `$WHO` set to Copilot until its verdict is clean, every fix commit carrying
`Review-Phase: copilot`. **Codex is not re-requested during this phase**: the merge gate
proves the head advanced only through Copilot fixes, and a commit without the trailer fails
the range check — correctly, since unreviewed work reached the head. `gh pr edit
--add-reviewer` failing because Copilot is unavailable to the repository is not permission
to skip the pass: report it and decide with the operator.

## 8. Merge gate

Run every check immediately before merging — an earlier check answered about an earlier
head.

### First: record the Copilot signoff, then STOP and ask

A clean Copilot verdict is the end of the review work, not the start of a merge. Record
it, then put the decision to the operator, as at the end of the Codex phase.

```bash
# only when there was a Copilot phase
REVIEWERS=both   # or `codex-only`
/usr/bin/env bash -p "$RB_SCRIPTS"/pr-copilot-phase.sh close N "$CODEX_SHA" "$REVIEWERS"
CLOSE_RC=$?
if [[ $CLOSE_RC -ne 0 ]]; then
    echo "The Copilot phase did not close and no signoff was recorded. The reason is above; do not retry it blind."
    exit "$CLOSE_RC"
    [[ -n "" ]]
fi
```

It prints the record it made, then the stop:

```
PR_COPILOT_PHASE_CLOSED pr=N reviewer=<copilot> copilot-sha=<sha> codex-sha=<sha>
```

**On the two-reviewer path, STOP. MERGING IS THE OPERATOR'S DECISION.** The stage prints
a menu and asks; do not run the merge gate until the operator has answered. `close` is
given `$CODEX_SHA` because whether the two shas are equal decides which menu it prints:
equal means Codex reviewed exactly what is being merged and no fault-tolerance pass is
offered — one would cost a revocation, a round and a reopened phase for a verdict that
cannot differ; different means the Codex signoff is carried forward only if the gate
proves every commit between them is a `Review-Phase: copilot` fix.

**Unattended:** on the first menu, merge, with `REVIEWERS=both`. On the second, the
fault-tolerance pass: post the revocation the menu describes, write the account of the
Copilot-phase commits into `$REQUEST_FILE`, and run steps 2–6 — step 2's block proves
`$WHO` as `$CODEX_BOT` again, and this one request is made with the auto-review argument
`no` whatever `$AUTO_REVIEW` is, since no push precedes it: the mention is its only trigger
and the baseline must be the verdict before the revocation — until Codex is clean; then
`record` from step 7 once more,
with a body saying what the pass changed, which writes the replacement signoff and reads
back the new `$CODEX_SHA`. Merge with `REVIEWERS=codex-only` where the pass moved the head
and `both` where it did not: Copilot's verdict is on the head the pass started from, and a
third phase over the pass's own fixes would restart the cycle. The pass runs once.

**In `codex-only` there is no second question.** No Copilot review was requested, so the
stage records nothing and prints no menu, and the decision was taken at the Codex stop.
Go straight to the merge gate.

### Resuming after a stop

A later session has none of the variables the stop was reached with. Run this before step
8, or before continuing into the Copilot phase. `pr-phase-state.sh` reads the phase off the
PR's own records and re-validates the one that has to stand: 0 readable and standing;
1 stopped — no signoff, a moved head, or a verdict that no longer stands, and its record
says which; 2 unreadable, which is not "no signoff".

```bash
if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-phase-state.sh N; then
    CODEX_SHA="$(/usr/bin/env bash -p "$RB_SCRIPTS"/pr-signoff.sh sha N "$CODEX_BOT")"; SIGNOFF_RC=$?
    RX_SHA40='^[0-9a-f]{40}$'
    if [[ $SIGNOFF_RC -ne 0 ]] || ! [[ "$CODEX_SHA" =~ $RX_SHA40 ]]; then
        echo "ABORT: the recorded Codex signoff did not read back as a sha (rc=$SIGNOFF_RC, sha='$CODEX_SHA')"
        exit 0
        [[ -n "" ]]
    fi
else
    # $? is the condition's; read it before anything else can change it
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

`pr-merge-gate.sh <pr> <codex-sha> <auto-review: yes|no> <reviewers: both|codex-only>`
evaluates every gate immediately before the merge and pins the merge to one head: 0
merged, and the head it names is on the base branch; 1 blocked, with the reason on
stdout; 3 paused at a round boundary, which is not a refusal; 4 queued — a merge queue
took the request without landing it, and `gh` calls that success. `$CODEX_SHA` is the full
40-hex head Codex signed off on, already in this session from step 7 or the resume above;
in the Copilot phase the head moves past it and Codex is deliberately not re-run, so that
is what Codex's verdict is checked against. `$REVIEWERS` is `both` unless the operator
chose otherwise at the Codex stop.

```bash
(cd "$REPO_DIR" && /usr/bin/env bash -p "$RB_SCRIPTS"/pr-merge-gate.sh N "$CODEX_SHA" "$AUTO_REVIEW" "$REVIEWERS")
MERGE_RC=$?
case "$MERGE_RC" in
    0) ;;   # merged; the script printed the head it pinned
    3) echo "Stopping here: the operator decides whether to merge at a round boundary." ;;
    4) echo "NOT merged: the request was accepted but the PR is not MERGED — a merge queue takes the request without landing it. Do not close this out; confirm on the PR." ;;
    *) echo "Not merged. The reason is above; do not retry it blind." ;;
esac
exit "$MERGE_RC"
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
