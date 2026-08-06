# Decision: `--admin` is the default merge mode

**Date:** 2026-08-06
**Status:** accepted
**Decided by:** the repository operator, during review of PR #10

## Read this first: which merge path it describes

This record accepts a trade-off in the merge gate. Part of what bounds that
trade-off arrives with PR #10 and is **not on this branch yet**, and the two
exposures on the current base ref are of different kinds. An operator who
conflates them would draw the wrong conclusion about both.

| Bound | On the base ref today | After #10 |
| --- | --- | --- |
| The head is re-read and compared immediately before merging | present | present |
| That comparison is **atomic** with the merge (`--match-head-commit`) | **absent** | present |
| A review-state probe (`blocked` / dismissed / body-only `CHANGES_REQUESTED`) | **absent** | present |
| `REVIEW_MERGE_STRICT=1` to drop `--admin` entirely | **absent** | present |

### The head exposure is a race

The base ref *does* re-read `headRefOid` immediately before merging and refuses
when it no longer matches the reviewed SHA. A push is therefore caught unless it
lands between that check and the `gh pr merge` call a few lines later. That is a
TOCTOU race with a small window — not an unbounded gap. `--match-head-commit`,
which #10 adds, closes it by making the comparison part of the merge itself.

### The review-state exposure is a missing gate

There is no probe for `blocked`, dismissed, or body-only `CHANGES_REQUESTED` on
the base ref at all. A changes-requested review that has stood for hours passes
the client-side gate and is then bypassed by `--admin`. That is not a race, and
no window bounds it. #10 adds the probe.

**Until #10 lands, read the bounds below as reasoning behind the default, not as
protections in force.**

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
- `REVIEW_MERGE_STRICT=1` drops `--admin`.

**What strict mode does and does not do.** Omitting `--admin` restores the
repository's *configured* protection rules; it does not create requirements that
were never configured. So it closes a race only for conditions the repository
actually enforces server-side. In the "required checks with no required human
approval" configuration suggested elsewhere in this plugin's documentation, checks
become atomic — while reviews and conversation resolution do not, because nothing
is requiring them. Strict mode is worth setting where the protection rules cover
the conditions you care about, and it is not a general closure of every race
described above.

Before #10, none of the three bullets apply. `REVIEW_MERGE_STRICT` in particular
is **not implemented on this branch**: setting it changes nothing.

## For reviewers

This file is the base-ref authority for the accepted trade-off. The rule it
relies on — that only a base-ref authority can waive a finding, and that an
underweighted cost should be raised as a **non-blocking note** — is in
`.review-bus.md` on the base ref. (`AGENTS.md` deliberately does not carry review
policy and says so; PR #10 moves that policy into `AGENTS.md`, at which point this
citation should follow it.)

It is not authority for anything else. The non-atomic head comparison and the
absent review-state probe on the current base ref are defects, not accepted
limitations — #10 fixes both, and a reviewer should keep reporting them anywhere
else they appear.

If the reasoning above stops holding — for example if GitHub gains a way for an
app review to satisfy required approvals — reopen it.
