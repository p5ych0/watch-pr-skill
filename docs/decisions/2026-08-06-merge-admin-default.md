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
| That comparison uses the **full** 40-hex SHA | **absent** (7-char prefix) | present |
| That comparison is **atomic** with the merge (`--match-head-commit`) | **absent** | present |
| A review-state probe (`blocked` / dismissed / body-only `CHANGES_REQUESTED`) | **absent** | present |
| `REVIEW_MERGE_STRICT=1` to drop `--admin` entirely | **absent** | present |

### The head exposure is two separate things

**A race.** The base ref *does* re-read `headRefOid` immediately before merging
and refuses when it no longer matches. A push is therefore caught unless it lands
between that check and the `gh pr merge` call a few lines later — a TOCTOU race
with a small window, not an unbounded gap. `--match-head-commit`, which #10 adds,
closes it by making the comparison part of the merge itself.

**A prefix-only comparison, which is not a race at all.** `MERGE_SHA` is a
seven-character abbreviation and the check compares `${HEAD_OID:0:7}` against it,
so a commit constructed to share those seven hex characters matches whenever it
is pushed — before the check, not merely between it and the merge. No timing
window bounds that one, and `--admin` then merges it. #10 compares the full
40-hex SHA and pins the merge to it; until then this is a missing bound in its
own right, listed separately above because calling it part of the race would
understate it.

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

For the case this plugin is built around — a solo maintainer opening a pull
request and reviewing it through the same `gh` credential — no available review
satisfies that. GitHub refuses a self-approval, which is why the watcher on this
branch attempts `APPROVE` and falls back to `COMMENT`
(`skills/watch-prs/scripts/review-bus-codex-watcher.sh`). Where an approval is
genuinely required, dropping `--admin` does not tighten the gate; it removes the
merge path entirely, on every pull request. A tool whose happy path cannot
complete is a worse failure than a seconds-wide race in a repository where nobody
else is reviewing.

**That rationale holds only where an approval is actually required.** It is
narrower than it first appears, and narrower than the default it justifies:

- On a branch with **no protection at all**, nothing is being bypassed and
  `--admin` is doing nothing.
- On a branch configured as this record recommends — checks and conversation
  resolution on, **required approvals zero** — there is no missing approval, so a
  normal merge is available once those conditions pass. `--admin` is unnecessary
  there, and an operator who has configured it should set
  `REVIEW_MERGE_STRICT=1`.
- The default earns its keep only where an approval **is** required and the
  reviewing credential cannot supply one.

So the default is the **permissive** fallback, not a safe one. The distinction
matters: it is chosen so the happy path completes on a repository whose
protection is unknown, and "unknown" includes configurations it silently bypasses
— a required merge queue is skipped outright, and any protection the credential
can bypass is ignored. Calling that safe would be the same overstatement this
record has already had to remove elsewhere.

**Where the configuration is unknown, strict mode is the safer choice**, at the
cost of a merge that may be refused until the operator looks at the rules. The
default is the right one only where the protection is known and known to require
an approval the reviewing credential cannot give. If your rules are ones this
loop can satisfy, strict mode is better and this record is not an argument
against it.

**This rationale is narrower than "every PR".** Where the pull request is
authored by a *different* account from the one `gh` is authenticated as — a
dependency bot, or a worker running as a separate maintainer — that `APPROVE`
succeeds and can satisfy a one-approval rule, so a normal merge is available and
`--admin` is not buying anything. Prefer `REVIEW_MERGE_STRICT=1` for those
repositories once it exists.

## What bounds it — once #10 has landed

- The window is between the final probe and the merge call — seconds, on a PR
  the operator is actively driving.
- Every gate this plugin checks client-side fails closed. That is not the same as
  every condition GitHub can enforce: notably there is **no merge-queue probe**
  anywhere in this repository, and `gh pr merge --admin` bypasses a required
  merge queue outright rather than racing it. **This record does not cover
  repositories whose base branch requires a merge queue** — there the exposure is
  not a seconds-wide window but a skipped queue, and `REVIEW_MERGE_STRICT=1` is
  the only supported setting.
- `REVIEW_MERGE_STRICT=1` drops `--admin` — which closes a race only where the
  repository's protections are configured *and* non-bypassable; see below.

**What strict mode does and does not do.** Omitting `--admin` restores the
repository's *configured* protection rules; it does not create requirements that
were never configured. So it closes a race only for conditions the repository
actually enforces server-side.

Concretely, the combination worth having is:

- **required status checks** — on;
- **require conversation resolution before merging** — on;
- **required approvals** — zero;
- **do not allow bypassing the above settings** — on (or an equivalent
  non-bypassable ruleset, or a `gh` credential without bypass permission).

That last one is not optional decoration. GitHub's protected-branch rules do
**not** apply to administrators or roles with bypass permission unless bypassing
is explicitly disallowed — and in the solo-maintainer case this record is about,
the operator *is* the administrator. Omitting `--admin` from the command
therefore does not make these gates binding by itself: the credential can still
merge a pull request whose requirements are unmet. Without this setting, strict
mode changes which flag is passed and nothing about what GitHub enforces.

Conversation resolution belongs in the list. The workflow already satisfies it:
the base contract makes zero unresolved threads a hard rule and its merge block
paginates every review thread and refuses while any is unresolved. So enabling
the corresponding protection costs nothing the loop was not already doing, and
in strict mode it becomes atomic — closing the case where a thread is opened
after the final client-side probe. Recommending checks only would have pointed
operators at a weaker configuration than the one they can actually run.

Required approvals stay at zero because that is the single condition this
plugin's reviewers cannot satisfy for a same-credential PR, and it is exactly
what the accepted trade-off is about. The base contract already draws that line
itself: `--admin` is permitted to bypass a missing approval, and explicitly
**must not** be used to bypass `required_review_thread_resolution`.

**No user-facing instructions for setting this up exist in this repository yet**;
they belong with the `REVIEW_MERGE_STRICT` implementation and arrive with #10.
Until then, treat the list above as a description of what to configure, not a
pointer to instructions.

**Which of those already hold here.** The first does: the base ref re-reads the
head immediately before merging, so the window really is the seconds between that
check and the merge call — that is the race described at the top, and saying
otherwise would contradict this record's own classification. The second does not:
the client-side gate set is incomplete on this branch, missing the review-state
probe and comparing only a seven-character prefix. The third does not either —
`REVIEW_MERGE_STRICT` is **not implemented here**, and setting it changes
nothing.

## For reviewers

This file is the base-ref authority for the accepted trade-off. The rule it
relies on — that only a base-ref authority can waive a finding, and that an
underweighted cost should be raised as a **non-blocking note** — is in
`.review-bus.md` on the base ref. (`AGENTS.md` deliberately does not carry review
policy and says so; PR #10 moves that policy into `AGENTS.md`, at which point this
citation should follow it.)

It is not authority for anything else. The prefix-only head comparison, its
non-atomicity, and the absent review-state probe on the current base ref are
defects, not accepted limitations — #10 fixes all three, and a reviewer should
keep reporting them anywhere else they appear.

If the reasoning above stops holding — for example if GitHub gains a way for an
app review to satisfy required approvals — reopen it.
