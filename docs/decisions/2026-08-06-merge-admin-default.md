# Decision: `--admin` is the default merge mode

**Date:** 2026-08-06
**Status:** accepted
**Decided by:** the repository operator, during review of PR #10

## The limitation, stated plainly

`gh pr merge --admin` merges with administrator privileges *because* the pull
request does not meet GitHub's requirements. It therefore discards GitHub's own
evaluation of the mutable conditions at merge time.

Every gate in this plugin runs client-side, against data fetched a moment
earlier, and `--match-head-commit` only proves the head has not moved. So there
is a window between the last probe and the merge in which a review can be
submitted or dismissed, a body-only `CHANGES_REQUESTED` can arrive, or a check
can fail — none of which changes the head, and none of which `--admin` lets
GitHub act on.

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

## What bounds it

- The window is between the final probe and the merge call — seconds, on a PR
  the operator is actively driving.
- Every gate that *can* be checked client-side is, and each fails closed.
- `REVIEW_MERGE_STRICT=1` drops `--admin` entirely. Set it wherever the
  repository's protection rules are ones the loop can satisfy — a team repo, or
  required checks with no required human approval. GitHub then evaluates reviews,
  checks and conversations itself, atomically, which is the only place the race
  can genuinely be closed.

## For reviewers

This file is the base-ref authority for that limitation. Per `AGENTS.md`, raising
the cost you think was underweighted as a **non-blocking note** is welcome; the
default itself is a decision, not an unaddressed defect.

If the reasoning above stops holding — for example if GitHub gains a way for an
app review to satisfy required approvals — reopen it.
