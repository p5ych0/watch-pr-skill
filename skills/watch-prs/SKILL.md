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
gh pr comment N --body "@codex review

<one paragraph: what this round changed and what to look at>"
```

Do **not** request Copilot yet. Step 7 does that, once Codex is clean.

## 3. Wait for the verdict

There is no notification channel; poll. A review normally lands in a few minutes.

Poll the **active** reviewer — `$CODEX_BOT` in the Codex phase, `$COPILOT_BOT`
in the Copilot phase. Set `WHO` once at the top of the round and use it
throughout, so the round is fixed, summarised and re-requested for the same
reviewer it was waiting on.

```bash
WHO="$CODEX_BOT"        # or "$COPILOT_BOT" once step 8 has begun
"$RB_SCRIPTS"/pr-review-state.sh state N "$WHO"
```

prints one of:

| state | meaning | what to do |
| --- | --- | --- |
| `none` | no review on this head | keep waiting; re-request if it never arrives |
| `pending` | a draft is open — the pass is not finished | keep waiting |
| `reviewed` | a submitted APPROVED/COMMENTED review exists | go to step 4 |
| `blocked` | CHANGES_REQUESTED | treat as findings |
| `dismissed` | the signoff was withdrawn | request the review again |

Stay in this step until that reviewer reaches an actionable terminal state —
`reviewed`, `blocked` or `dismissed`. `none` and `pending` mean the pass is still
coming; keep waiting rather than moving on.

Exit status 2 means the state could not be read. **Fail closed** — never treat it
as "no findings".

## 4. Read the findings

Inline review comments are the findings. The review **body** is the reviewer's
non-blocking channel and does not gate the merge — with one exception, below.

**Paginate.** A truncated thread list reads exactly like a shorter review, and
here that is worse than at the merge gate: you would reply, resolve and summarise
against an incomplete set before any gate runs.

```bash
CURSOR=null
while :; do
  PAGE=$(gh api graphql -F number=N -F owner="$OWNER" -F repo="$REPO" -F cursor="$CURSOR" -f query='
    query($owner:String!,$repo:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){
      reviewThreads(first:100, after:$cursor){ pageInfo{hasNextPage endCursor}
        nodes{isResolved path line comments(first:1){nodes{author{login} body}}} }}}}' 2>/dev/null)     || { echo "ABORT: thread fetch failed — do not act on a partial read"; break; }
  echo "$PAGE" | jq -e '.data.repository.pullRequest.reviewThreads' >/dev/null 2>&1     || { echo "ABORT: thread page unreadable"; break; }
  # `jq -e`, and its status checked: a page whose `nodes` or comment shape is
  # malformed makes this projection exit non-zero, and an unchecked failure would
  # fall through to the pagination test and read as "no more findings".
  # The SHAPE is validated before anything is formatted. `jq -e` alone is not
  # enough: string interpolation renders a missing author or body as `null` and
  # still exits 0, so the driver would reply, resolve and summarise against
  # "null" text believing it had read the findings.
  echo "$PAGE" | jq -e -r '
      .data.repository.pullRequest.reviewThreads.nodes as $n
      | if ($n | type) != "array"
           or any($n[];
                  type != "object"
                  or (.isResolved | type) != "boolean"
                  or (.comments.nodes | type) != "array"
                  or (select(.isResolved == false)
                      | (.comments.nodes | length) == 0
                        or (.comments.nodes[0].author.login | type) != "string"
                        or (.comments.nodes[0].body | type) != "string"))
        then error("malformed thread node")
        else $n[] | select(.isResolved == false)
             | "### \(.path):\(.line) [\(.comments.nodes[0].author.login)]\n\(.comments.nodes[0].body)\n"
        end' \
    || { echo "ABORT: findings page malformed — do not act on a partial read"; break; }
  HAS_NEXT=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage') || { echo "ABORT: pageInfo unreadable"; break; }
  case "$HAS_NEXT" in
    false) break ;;
    true)  ;;
    *) echo "ABORT: hasNextPage is not a boolean ('$HAS_NEXT')"; break ;;
  esac
  CURSOR=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
  [ -n "$CURSOR" ] && [ "$CURSOR" != "null" ] || { echo "ABORT: hasNextPage=true with no cursor"; break; }
done
```

**When a reviewer's state is `blocked`, read its review body too.** A
`CHANGES_REQUESTED` review can carry its whole argument in the body with no
inline comment — the merge gate then refuses to pass while the findings fetch
above shows nothing to fix, which looks like a stuck loop rather than a request.

`$WHO` is the active reviewer from step 3 — written as a variable, not a literal,
so the Copilot phase gets the same treatment as the Codex phase rather than
leaving the hole open for whichever one was hard-coded.

```bash
  # Piped to `jq`, not `gh --jq`: that flag takes a single expression and cannot
  # accept `--arg`, so passing one makes gh exit with "accepts 1 arg(s)".
  # `-s` because --paginate emits one array per page.
  gh api "repos/$OWNER/$REPO/pulls/N/reviews" --paginate 2>/dev/null \
    | jq -s -r --arg who "$WHO" '
        if length == 0 or any(.[]; type != "array") then error("bad page")
        else [ .[][] ]
          | map(select(.user.login == $who and .state == "CHANGES_REQUESTED"))
          | sort_by(.submitted_at) | last | .body // empty
        end' \
    || echo "ABORT: could not read $WHO's blocking review body"
```

## 5. Fix, then close the round

Fix the findings. Where you disagree, say so in the thread rather than silently
resolving it. Then, in one pass:

1. commit — `fix(review): <what changed>`. **In the Copilot phase, add a
   `Review-Phase: copilot` trailer**: it is what tells the merge gate that the
   head advanced only through Copilot fixes, so Codex's earlier signoff still
   covers it and does not have to be re-earned;
2. push;
3. reply to each thread with what changed, and resolve it;
4. post the round summary (step 1's contract);
5. **check the round boundary — step 6 — and only then** re-request **`$WHO`**,
   the same reviewer this round was about. In that order: re-requesting first
   sends the next review past the boundary the check-in exists to stop at, so the
   operator is asked after the thing they were meant to decide about has already
   happened.

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
gh pr edit N --repo $OWNER/$REPO --add-reviewer @copilot
WHO="$COPILOT_BOT"
```

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
REVIEWED_SHA=<the sha the clean review was for>

# (0) Resolve the head ONCE, and fail closed on a lookup that printed something
# and then failed — command substitution keeps that stdout, so a plausible SHA
# from a failed fetch would otherwise pass the shape check below.
HEAD_RC=0
HEAD_OID=$(gh pr view N --repo $OWNER/$REPO --json headRefOid --jq '.headRefOid' 2>/dev/null) || HEAD_RC=$?
if [ "$HEAD_RC" -ne 0 ] || ! [[ "$HEAD_OID" =~ ^[0-9a-f]{40}$ ]]; then
    echo "merge blocked: head lookup failed (rc=$HEAD_RC)"; exit 0
fi

# (1) Both reviewers clean ON THAT EXACT HEAD. Pass $HEAD_OID explicitly: letting
# each verdict resolve the head itself means a push landing between the two calls
# leaves both verdicts describing an older commit while step 5 pins and merges the
# newer one — and if that commit carries a `Review-Phase: copilot` trailer, the
# range check below accepts it.
"$RB_SCRIPTS"/pr-review-state.sh verdict N "$CODEX_BOT"   "$HEAD_OID"; CODEX_RC=$?
"$RB_SCRIPTS"/pr-review-state.sh verdict N "$COPILOT_BOT" "$HEAD_OID"; COPILOT_RC=$?
if [ "$CODEX_RC" -ne 0 ] || [ "$COPILOT_RC" -ne 0 ]; then
    echo "merge blocked: codex=$CODEX_RC copilot=$COPILOT_RC (1 = not clean, 2 = could not tell)"; exit 0
fi

# (2) Everything since the reviewed SHA is a review-fix commit reachable from it.
if [ "${HEAD_OID:0:7}" != "$REVIEWED_SHA" ]; then
    "$RB_SCRIPTS"/pr-merge-range.sh "$REVIEWED_SHA" "$HEAD_OID" "$REPO_DIR"; RANGE=$?
    if [ "$RANGE" -ne 0 ]; then
        echo "merge blocked: range check returned $RANGE (1 = an untagged commit, or the reviewed SHA is not an ancestor; 2 = could not inspect)"; exit 0
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
