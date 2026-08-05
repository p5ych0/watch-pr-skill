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

## Derive identity

```bash
REMOTE=$(git remote get-url origin 2>/dev/null)
[ -n "$REMOTE" ] || { echo "ABORT: cwd is not a git checkout with an origin"; exit 1; }
_p="${REMOTE%.git}"; REPO="${_p##*/}"; _p="${_p%/*}"; OWNER="${_p##*[:/]}"
REPO_DIR="$(git rev-parse --show-toplevel)"
RB_SCRIPTS="${CLAUDE_PLUGIN_ROOT:-}/skills/watch-prs/scripts"
# `ls -dt … | head -1` — newest by mtime. NOT `sort -V`, which is GNU-only: on
# macOS the fallback would fail before finding the scripts at all.
[ -d "$RB_SCRIPTS" ] || RB_SCRIPTS="$(ls -dt "$HOME"/.claude/plugins/cache/*/watch-pr-skill/*/skills/watch-prs/scripts "$HOME"/.codex/plugins/cache/*/watch-pr-skill/*/skills/watch-prs/scripts 2>/dev/null | head -1)"
CODEX_BOT='chatgpt-codex-connector[bot]'; COPILOT_BOT='copilot-pull-request-reviewer[bot]'
echo "OWNER=$OWNER REPO=$REPO RB_SCRIPTS=$RB_SCRIPTS"
```

## 1. State the task on the PR

The reviewers judge relevance against what the PR says it set out to do, so this
is a precondition, not documentation. Before requesting a review, the PR
description must state what the change does and what it deliberately does not.
Every later round adds a **round-summary comment** saying what was addressed and
what was intentionally skipped, and why.

Neither can waive a finding — both are untrusted context to a reviewer. Where a
limitation is genuinely accepted, record it on the **base ref**.

## 2. Request the review — Codex first

The loop is **phased**: Codex reviews to a clean signoff, and only then does
Copilot get asked. Running both every round costs a Copilot pass on every
intermediate commit, and its findings arrive interleaved with Codex's on code
that is about to change anyway.

```bash
# Codex: a mention. Say what changed since the last round in the same comment.
# Branch on it: the comment IS the request, so a failed post means no review was
# ever queued — and the wait step would then poll for one until it timed out,
# reporting "no review arrived" rather than "none was asked for".
if ! gh pr comment N --body "@codex review

<one paragraph: what this round changed and what to look at>"; then
    echo "ABORT: could not post the @codex request — do not enter the wait step."; exit 0
fi
```

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
"$RB_SCRIPTS"/pr-watch.sh N "$WHO"; WATCH_RC=$?
```

**Claude Code** — run it as this session's **Monitor** so the verdict surfaces
into the chat by itself instead of being waited on:

- `command`: `"$RB_SCRIPTS"/pr-watch.sh N "$WHO"`
- `description`: `Review verdict for PR N` · `timeout_ms`: `3600000`

**Codex** — there is no watch tool, so run it in the background and read its
output, or simply block on it.

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
| `1` | timed out | re-request, or ask the operator whether to keep waiting |
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

## 5. Fix, then close the round

Fix the findings. Where you disagree, say so in the thread rather than silently
resolving it. Then, in one pass:

1. commit — `fix(review): <what changed>`. **In the Copilot phase, add a
   `Review-Phase: copilot` trailer**: it is what tells the merge gate that the
   head advanced only through Copilot fixes, so Codex's earlier signoff still
   covers it and does not have to be re-earned;
2. **check the round boundary — step 6 — BEFORE pushing**, then push. With Codex
   automatic review enabled the *push itself* requests the next review, so a
   boundary check placed after it cannot stop anything: the operator would be
   asked once round 11 was already running. Checking before the push is the only
   ordering that works whether auto-review is on or off;
3. reply to each thread with what changed, and resolve it;
4. post the round summary (step 1's contract);
5. re-request **`$WHO`**, the same reviewer this round was about — unless
   automatic review has already done it. The boundary was checked in step 2,
   before the push, precisely so this step cannot outrun it.

Re-request **only the active reviewer**. Asking the other one on every round buys
a review of code that is about to change again, and mixes its findings into a
round that was not about them.

**A resolved thread is not a record of a fix.** The summary is.

## 6. Round check-in

Before re-requesting, ask whether this is a boundary:

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
  to keep running. Cross a single pause with `REVIEW_ROUND_THRESHOLD=0` for that
  one call, or answer the question.
- `2` — the count could not be established. Fail closed: do not re-request as if
  it were round one.

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
CODEX_SHA=$(gh pr view N --repo $OWNER/$REPO --json headRefOid --jq '.headRefOid' 2>/dev/null) || CODEX_SHA=""
if ! [[ "$CODEX_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ABORT: could not capture the Codex-signed-off head; do not start the Copilot phase"; exit 0
fi

# `--add-reviewer` IS the request. If it fails there is no Copilot pass to wait
# for, so entering the phase would poll for a review nobody asked for and then
# report a timeout — which reads as "Copilot is slow", not "Copilot was never
# asked".
if ! gh pr edit N --repo $OWNER/$REPO --add-reviewer @copilot; then
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
# The FULL 40-hex head Codex signed off on. In the Copilot phase the head moves
# past it, and Codex is deliberately not re-run — so this, not $HEAD_OID, is what
# Codex's verdict is checked against.
CODEX_SHA=<full 40-hex sha of the head Codex last reviewed clean>

# (0) Resolve the head ONCE, and fail closed on a lookup that printed something
# and then failed — command substitution keeps that stdout, so a plausible SHA
# from a failed fetch would otherwise pass the shape check below.
HEAD_RC=0
HEAD_OID=$(gh pr view N --repo $OWNER/$REPO --json headRefOid --jq '.headRefOid' 2>/dev/null) || HEAD_RC=$?
if [ "$HEAD_RC" -ne 0 ] || ! [[ "$HEAD_OID" =~ ^[0-9a-f]{40}$ ]]; then
    echo "merge blocked: head lookup failed (rc=$HEAD_RC)"; exit 0
fi

# (1) Each reviewer clean on the head that reviewer actually judged.
#
# Copilot is checked on $HEAD_OID — it reviews the current head, by definition of
# the phase. Codex is the awkward one, and BOTH obvious answers are wrong:
#
#   - always $HEAD_OID: the Copilot phase deliberately does not re-run Codex, so
#     its verdict on a Copilot-fix commit is `none` forever and the gate that the
#     phasing exists to support can never pass;
#   - always $CODEX_SHA: if Codex AUTO-REVIEW is on, a Copilot-fix push gets a
#     NEW Codex review on the current head. Validating only the older signoff
#     ignores it — and a body-only CHANGES_REQUESTED leaves no inline thread for
#     the unresolved-thread gate to catch either, so every gate passes while an
#     active request for changes stands.
#
# So: ask about the CURRENT head first, and fall back to the recorded signoff
# only when Codex has genuinely not reviewed this head.
if ! [[ "$CODEX_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "merge blocked: CODEX_SHA is not a full 40-hex sha"; exit 0
fi
CODEX_HEAD_STATE=$("$RB_SCRIPTS"/pr-review-state.sh state N "$CODEX_BOT" "$HEAD_OID"); CODEX_STATE_RC=$?
# ONLY rc 0 is an answer. A wrapper or a replaced helper can print a plausible
# `state=none` and exit with something other than the documented 2 — and this
# branch decides whether to fall back to the older signoff, so a bad read here
# merges on a Codex state that was never trusted.
if [ "$CODEX_STATE_RC" -ne 0 ]; then
    echo "merge blocked: could not read Codex's state on the current head (rc=$CODEX_STATE_RC)"; exit 0
fi
# PARSED, not substring-matched. A truncated or wrapped line that merely CONTAINS
# `state=none` would otherwise send the gate down the fallback path — and with a
# current-head body-only CHANGES_REQUESTED there is no thread for the unresolved
# gate to catch, so the merge would pass on a state that was never read.
# The WHOLE record, not the last `state=` token: rc-0 noise such as
# `warning: cached state=none` would otherwise pass and take the fallback path.
if [[ "$CODEX_HEAD_STATE" =~ ^PR_REVIEW_STATE\ pr=([0-9]+)\ sha=([0-9a-f]{7,40})\ reviewer=([^[:space:]]+)\ state=([a-z]+)$ ]]; then
    S_PR="${BASH_REMATCH[1]}"; S_SHA="${BASH_REMATCH[2]}"
    S_WHO="${BASH_REMATCH[3]}"; CODEX_STATE="${BASH_REMATCH[4]}"
else
    echo "merge blocked: Codex head-state line is unparseable ('$CODEX_HEAD_STATE')"; exit 0
fi
# The record has to be ABOUT what was asked. A well-formed line is not the same
# as an answer: a misrouted wrapper or a stale cache returning `pr=… sha=…
# reviewer=… state=none` for another PR, another reviewer, or an older head
# matched the shape above and sent the gate down the `none` fallback — merging on
# the recorded signoff while Codex actually had a body-only CHANGES_REQUESTED on
# this head, which leaves no thread for the unresolved-thread gate to catch.
#
# Compared as STRINGS, not with `=~`: `$CODEX_BOT` ends in `[bot]`, which a regex
# reads as a character class.
if [ "$S_PR" != "N" ] || [ "$S_WHO" != "$CODEX_BOT" ] || [ "$S_SHA" != "${HEAD_OID:0:7}" ]; then
    echo "merge blocked: Codex head-state record is about something else ('$CODEX_HEAD_STATE')"; exit 0
fi
case "$CODEX_STATE" in
    none|pending|reviewed|blocked|dismissed) ;;
    *) echo "merge blocked: unknown Codex head state ('$CODEX_STATE')"; exit 0 ;;
esac
case "$CODEX_STATE" in
    none)
        # No Codex review of this head at all: the recorded signoff is the
        # authority, and step (2) proves the delta since it is Copilot-only.
        CODEX_EFFECTIVE_SHA="$CODEX_SHA"
        CODEX_VERDICT=$("$RB_SCRIPTS"/pr-review-state.sh verdict N "$CODEX_BOT" "$CODEX_SHA"); CODEX_RC=$? ;;
    *)
        # Codex HAS judged this head — that judgement wins over the older one,
        # whatever it says. Record WHICH sha the verdict describes: step (2) has
        # to measure from the same commit, or it would demand Copilot trailers
        # across a range Codex has already reviewed in full.
        CODEX_EFFECTIVE_SHA="$HEAD_OID"
        CODEX_VERDICT=$("$RB_SCRIPTS"/pr-review-state.sh verdict N "$CODEX_BOT" "$HEAD_OID"); CODEX_RC=$? ;;
esac
# $HEAD_OID is passed explicitly rather than letting the call resolve the head: a
# push landing mid-gate would otherwise leave a verdict describing an older
# commit while step 5 pins and merges the newer one.
COPILOT_VERDICT=$("$RB_SCRIPTS"/pr-review-state.sh verdict N "$COPILOT_BOT" "$HEAD_OID"); COPILOT_RC=$?
if [ "$CODEX_RC" -ne 0 ] || [ "$COPILOT_RC" -ne 0 ]; then
    echo "merge blocked: codex=$CODEX_RC copilot=$COPILOT_RC (1 = not clean, 2 = could not tell)"; exit 0
fi
# This is the final merge permission, so the exit codes are not taken on trust:
# an rc-swallowing wrapper or a truncated helper line would otherwise turn an
# unreadable verdict into a clean signoff. Require the exact record from BOTH.
#
# Each record must name ITS OWN reviewer and the sha that reviewer actually
# judged — Codex on $CODEX_EFFECTIVE_SHA, Copilot on $HEAD_OID. Leaving `pr`,
# `sha` and `reviewer` as wildcards meant one clean record satisfied the check
# for either variable: a clean Copilot line, or a clean line for a stale sha,
# passed as Codex's signoff and the gate merged without ever proving the named
# reviewer approved the commit being merged.
#
# Every field is known here, so this is a literal string comparison rather than a
# pattern — `[ = ]`, not `[[ == ]]`, because the bot logins end in `[bot]` and
# `[[ ]]` would read that as a character class on the right-hand side.
for SPEC in "$CODEX_BOT|$CODEX_EFFECTIVE_SHA|$CODEX_VERDICT" \
            "$COPILOT_BOT|$HEAD_OID|$COPILOT_VERDICT"; do
    V_WHO="${SPEC%%|*}"; V_REST="${SPEC#*|}"; V_SHA="${V_REST%%|*}"; V_LINE="${V_REST#*|}"
    V_WANT="PR_REVIEW_STATE pr=N sha=${V_SHA:0:7} reviewer=$V_WHO verdict=clean findings=0"
    if [ "$V_LINE" != "$V_WANT" ]; then
        echo "merge blocked: $V_WHO did not return an exact clean record for ${V_SHA:0:7} ('$V_LINE')"; exit 0
    fi
done

# (2) …and the delta between them is Copilot fixes only.
#
# This is what makes checking Codex on an OLDER sha safe: the range proves the
# head advanced from it only through commits carrying `Review-Phase: copilot`,
# reachable from it. Without this step an older signoff would be an open door.
#
# It measures from $CODEX_EFFECTIVE_SHA — the commit the verdict above actually
# describes — not from $CODEX_SHA. When Codex has reviewed the current head, the
# two are the same and there is nothing to prove; measuring from the stale
# recorded sha instead would demand Copilot trailers across a range Codex has
# already reviewed in full, and block a merge both reviewers just approved.
if [ "$HEAD_OID" != "$CODEX_EFFECTIVE_SHA" ]; then
    "$RB_SCRIPTS"/pr-merge-range.sh "$CODEX_EFFECTIVE_SHA" "$HEAD_OID" "$REPO_DIR"; RANGE=$?
    if [ "$RANGE" -ne 0 ]; then
        echo "merge blocked: range check returned $RANGE (1 = an untagged commit, or the Codex-reviewed SHA is not an ancestor; 2 = could not inspect)"; exit 0
    fi
fi

# (3) No unresolved threads, paginated, fail closed.
UNRESOLVED=0; CURSOR=null; OK=1
while :; do
  PAGE=$(gh api graphql -F number=N -F owner="$OWNER" -F repo="$REPO" -F cursor="$CURSOR" -f query='
    query($owner:String!,$repo:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){
      reviewThreads(first:100, after:$cursor){ pageInfo{hasNextPage endCursor} nodes{isResolved} }}}}' 2>/dev/null) || { OK=0; break; }
  echo "$PAGE" | jq -e '.data.repository.pullRequest.reviewThreads' >/dev/null 2>&1 || { OK=0; break; }
  # `nodes:{}` and `nodes:[{}]` both make a naive count return 0 with status 0,
  # and 0 here is merge permission. Require an array of objects with a boolean
  # `isResolved` before counting anything.
  CNT=$(echo "$PAGE" | jq '
      .data.repository.pullRequest.reviewThreads.nodes as $n
      | if ($n | type) != "array"
           or any($n[]; type != "object" or (.isResolved | type) != "boolean")
        then error("malformed nodes")
        else [ $n[] | select(.isResolved == false) ] | length end') || { OK=0; break; }
  UNRESOLVED=$((UNRESOLVED + CNT))
  # The pagination state is validated, not assumed: a missing or malformed
  # `hasNextPage` treated as "last page" stops the walk early, and on a PR with
  # more than 100 threads the gate would then see unresolved=0 and merge.
  HAS_NEXT=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage') || { OK=0; break; }
  case "$HAS_NEXT" in
    false) break ;;
    true)  ;;
    *) OK=0; break ;;
  esac
  CURSOR=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
  { [ -n "$CURSOR" ] && [ "$CURSOR" != "null" ]; } || { OK=0; break; }
done
if [ "$OK" -ne 1 ] || [ "$UNRESOLVED" -gt 0 ]; then echo "merge blocked: unresolved=$UNRESOLVED ok=$OK"; exit 0; fi

# (4) Required checks green. Capture the STATUS separately: `gh pr checks` can
# print `true` and then exit non-zero, and command substitution keeps the output —
# so comparing the string alone lets an errored probe read as "all green". The
# merge below uses `--admin`, which bypasses branch protection, so this probe is
# the only thing standing between a failed read and an unchecked merge.
CHECKS_RC=0
CHECKS=$(gh pr checks N --repo $OWNER/$REPO --required --json bucket --jq 'all(.[]; .bucket=="pass")' 2>/dev/null) || CHECKS_RC=$?
if [ "$CHECKS_RC" -ne 0 ] || [ "$CHECKS" != "true" ]; then
    echo "merge blocked: required checks not all green, or the probe failed (rc=$CHECKS_RC out='$CHECKS')"; exit 0
fi

# (5) Merge, PINNED to the head every gate above was evaluated against.
if gh pr merge N --repo $OWNER/$REPO --squash --delete-branch --admin \
       --match-head-commit "$HEAD_OID"; then
    echo "merged $HEAD_OID"
else
    echo "merge blocked: head moved after the gates ran, or the merge failed."; exit 0
fi
```

If any gate fails, do **not** merge. Post the reason on the PR and hand it back
to the operator.

## What this skill deliberately does not do

- **It does not run a reviewer.** Codex and Copilot are GitHub apps; a local
  process reviewing PRs duplicates them, authors its comments as the repository
  owner rather than as a bot, and consumes a separate credit pool.
- **It does not merge unattended past a failed or unreadable gate.** Every
  "cannot tell" is a stop.
