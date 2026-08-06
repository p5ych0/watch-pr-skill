# Decision: `--admin` is the default merge mode

**Date:** 2026-08-06
**Status:** accepted
**Decided by:** the repository operator, during review of PR #10

## Read this first: which merge path it describes

This record accepts a trade-off in the merge gate. **Most of what bounds that
trade-off arrives with PR #10 and is not on this branch yet.** The distinction
matters, because an operator reading it against today's `main` would credit
protections that do not exist here.

| Bound | On the base ref today | After #10 |
| --- | --- | --- |
| `--match-head-commit` pins the merge to the reviewed head | **absent** | present |
| A review-state probe (`blocked` / dismissed / body-only `CHANGES_REQUESTED`) | **absent** | present |
| `REVIEW_MERGE_STRICT=1` to drop `--admin` entirely | **absent** | present |

Today `skills/watch-prs/SKILL.md` runs an unconditional

```
gh pr merge N --repo $OWNER/$REPO --squash --delete-branch --admin
```

with no head pin and no review-state gate. So on this branch the exposure is
**not** the seconds-wide arrival race described below: a concurrent push can
replace the reviewed head and still be merged, and a body-only
`CHANGES_REQUESTED` that has existed for hours is bypassed too. Those are missing
gates, not a race, and they are what #10 adds.

**Until #10 lands, treat this record as the reasoning behind the default, not as
a description of protections in force.**

## The limitation, stated plainly

`gh pr merge --admin` merges with administrator privileges *because* the pull
request does not meet GitHub's requirements. It therefore discards GitHub's own
evaluation of the mutable conditions at merge time.

With #10's gates in place, every check runs client-side against data fetched a
moment earlier, and `--match-head-commit` proves only that the head has not
moved. That leaves a window between the last probe and the merge in which a
review can be submitted or dismissed, a body-only `CHANGES_REQUESTED` can arrive,
or a check can fail — none of which changes the head, and none of which `--admin`
lets GitHub act on.

**That race is real and is accepted.** It is not an oversight, and a reviewer
raising it is raising something true.

## Why it is accepted

Branch protection normally requires an approving review **from another account**.
Neither reviewer this plugin drives is one: a Codex or Copilot review does not
count towards "required approvals". For the solo maintainer this plugin exists to
serve, dropping `--admin` does not tighten the gate — it removes the merge path
entirely, on every pull request.

A tool whose happy path cannot complete is a worse failure than a seconds-wide
race in a repository where nobody else is reviewing.

## What bounds it — once #10 has landed

- The window is between the final probe and the merge call — seconds, on a PR
  the operator is actively driving.
- Every gate that *can* be checked client-side is, and each fails closed.
- `REVIEW_MERGE_STRICT=1` drops `--admin` entirely. Set it wherever the
  repository's protection rules are ones the loop can satisfy — a team repo, or
  required checks with no required human approval. GitHub then evaluates reviews,
  checks and conversations itself, atomically, which is the only place the race
  can genuinely be closed.

Before #10, none of those three apply. `REVIEW_MERGE_STRICT` in particular is
**not implemented on this branch**: setting it changes nothing.

## For reviewers

This file is the base-ref authority for the accepted trade-off. Per `AGENTS.md`,
raising the cost you think was underweighted as a **non-blocking note** is
welcome; the default itself is a decision, not an unaddressed defect.

It is not authority for anything else. The missing head pin and review-state
probe on the current base ref are defects, not accepted limitations — #10 fixes
them, and a reviewer should keep reporting them anywhere else they appear.

If the reasoning above stops holding — for example if GitHub gains a way for an
app review to satisfy required approvals — reopen it.
