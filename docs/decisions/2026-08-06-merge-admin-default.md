# Decision: `--admin` is the default merge mode

**Date:** 2026-08-06
**Status:** accepted
**Decided by:** the repository operator, during review of PR #10
**Revised:** 2026-08-28 — rewritten as a description of the gate as it is. It was
framed throughout as before-and-after PR #10, which has since merged (`b7e61f3`,
the v2 commit that created this tree), so every "after #10" bound below is simply
in force. The decision is unchanged; only the framing was stale. #208.

## What this record is authority for

The merge gate merges with `--admin` by default, which bypasses branch protection
deliberately, and every gate it checks runs client-side. **Two things are accepted
here and nothing else**: the bypass itself, and the race between the last probe
and the merge.

## The bounds that are in force

`pr-merge-gate.sh` does all of these before it merges:

- resolves the head ONCE, as the **full 40-hex OID** rather than an abbreviation,
  and fails closed on a lookup that printed something and then failed;
- pins the merge to that OID with `--match-head-commit`, which is what makes the
  comparison atomic: GitHub refuses the merge unless the PR head still matches, so
  there is no client-side re-read to race and none is performed. Every gate below
  is evaluated against that snapshot;
- probes the reviewer's state and verdict against that head through
  `pr-review-state.sh`, so a `blocked`, dismissed or body-only
  `CHANGES_REQUESTED` review is seen rather than walked past;
- reads the PR state back **after** the merge command and reports status 4 rather
  than `merged` when the PR is not `MERGED` — because a merge queue accepts the
  request without landing it and `gh` calls that success;
- honours `REVIEW_MERGE_STRICT=1`, which drops `--admin` entirely.

## The limitation, stated plainly

`gh pr merge --admin` merges with administrator privileges *because* the pull
request does not meet GitHub's requirements. It therefore discards GitHub's own
evaluation of the mutable conditions at merge time.

With those gates in place, every check runs client-side against data fetched a
moment earlier, and `--match-head-commit` proves only that the head has not moved.
That leaves a window between the last probe and the merge in which a review can be
submitted or dismissed, a body-only `CHANGES_REQUESTED` can arrive, or a check can
fail — none of which changes the head, and none of which `--admin` lets GitHub act
on.

**That race is real and is accepted.** It is not an oversight, and a reviewer
raising it is raising something true.

## Why it is accepted

Branch protection normally requires an approving review **from another account**.

For the case this plugin is built around — a solo maintainer opening a pull
request and driving it through their own `gh` credential — no available review
satisfies that, for two separate reasons. **Neither reviewer is another account in
the sense the rule means**: Codex and Copilot are GitHub Apps, and their reviews do
not count towards required approvals. **And the operator cannot supply one
either**: GitHub refuses a self-approval on your own pull request.

Where an approval is genuinely required, dropping `--admin` therefore does not
tighten the gate; it removes the merge path entirely, on every pull request. A tool
whose happy path cannot complete is a worse failure than a seconds-wide race in a
repository where nobody else is reviewing.

**That rationale holds only where an approval is actually required.** It is
narrower than it first appears, and narrower than the default it justifies:

- On a branch with **no protection at all**, nothing is being bypassed and
  `--admin` is doing nothing.
- On a branch configured as this record recommends — checks and conversation
  resolution on, **required approvals zero** — there is no missing approval, so a
  normal merge is available once those conditions pass. `--admin` is unnecessary
  there, and an operator who has configured it should set `REVIEW_MERGE_STRICT=1`.
- The default earns its keep only where an approval **is** required and the
  reviewing credential cannot supply one.

So the default is the **permissive** fallback, not a safe one. The distinction
matters: it is chosen so the happy path completes on a repository whose protection
is unknown, and "unknown" includes configurations it silently bypasses — a
required merge queue is skipped outright, and any protection the credential can
bypass is ignored. Calling that safe would be the same overstatement this record
has already had to remove elsewhere.

**Where the configuration is unknown, strict mode is the safer choice**, at the
cost of a merge that may be refused until the operator looks at the rules. The
default is the right one only where the protection is known and known to require
an approval the reviewing credential cannot give. If your rules are ones this loop
can satisfy, strict mode is better and this record is not an argument against it.

**This rationale is narrower than "every PR".** Where the pull request is authored
by a *different* account from the one `gh` is authenticated as — a dependency bot,
or a worker running as a separate maintainer — the operator's own approval is
available and can satisfy a one-approval rule, so a normal merge works and
`--admin` is not buying anything. Prefer `REVIEW_MERGE_STRICT=1` for those
repositories.

## What bounds it

- The window is between the final probe and the merge call — seconds, on a PR the
  operator is actively driving.
- Every gate this plugin checks client-side fails closed. That is not the same as
  every condition GitHub can enforce: there is **no merge-queue probe before the
  merge**, and `gh pr merge --admin` bypasses a required queue outright rather
  than racing it. What the gate does have is the read-back afterwards, so a queued
  PR is reported as queued rather than as merged — which stops the driver acting
  on a merge that did not happen, and does not stop the bypass. **This record does
  not cover repositories whose base branch requires a merge queue**: there the
  exposure is a skipped queue rather than a seconds-wide window, and
  `REVIEW_MERGE_STRICT=1` is the only supported setting.
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
the operator *is* the administrator. Omitting `--admin` from the command therefore
does not make these gates binding by itself: the credential can still merge a pull
request whose requirements are unmet. Without this setting, strict mode changes
which flag is passed and nothing about what GitHub enforces.

Conversation resolution belongs in the list. The workflow already satisfies it:
`pr-merge-gate.sh` paginates every review thread and refuses while any is
unresolved, before it reaches the merge. So enabling the
corresponding protection costs nothing the loop was not already doing, and in
strict mode it becomes atomic — closing the case where a thread is opened after
the final client-side probe. Recommending checks only would have pointed operators
at a weaker configuration than the one they can actually run.

Required approvals stay at zero because that is the single condition this plugin's
reviewers cannot satisfy for a same-credential PR, and it is exactly what the
accepted trade-off is about. The gate draws that line itself: `--admin` is
permitted to bypass a missing approval, and the unresolved-thread refusal above it
means it is never reached with a thread open.

`README.md` documents the variable itself under its own heading. **It does not yet
carry this four-part configuration**, and the two parts an operator is most likely
to miss — conversation resolution, and disallowing bypass — are the two that decide
whether strict mode enforces anything at all. Until the README carries it, the list
above is the only place it is written down. Recorded as #211.

## For reviewers

This file is the base-ref authority for the accepted trade-off. The rule it relies
on — that only a base-ref authority can waive a finding, and that an underweighted
cost should be raised as a **non-blocking note** — is in `AGENTS.md` on the base
ref, and in `.github/copilot-instructions.md` for the reviewer that follows no
pointers.

**It is authority for two things and no others**: merging with `--admin` by
default, and the race between the final client-side probe and the merge. It is not
authority for a weaker head comparison, a missing review-state probe, a merge
reported without reading the PR state back, or anything else that resembles them —
those were real defects, they were fixed, and a reviewer should keep reporting
them anywhere they appear.

If the reasoning above stops holding — for example if GitHub gains a way for an
app review to satisfy required approvals — reopen it.
