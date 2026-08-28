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

## The bounds that are in force before the merge

`pr-merge-gate.sh` does all of these before it merges:

- resolves the head ONCE, as the **full 40-hex OID** rather than an abbreviation,
  and fails closed on a lookup that printed something and then failed;
- pins the merge to that OID with `--match-head-commit`, which is what makes the
  comparison atomic: GitHub refuses the merge unless the PR head still matches, so
  there is no client-side re-read to race and none is performed;
- probes each reviewer's state and verdict through `pr-review-state.sh`, against
  the head THAT reviewer judged — Copilot's is the merge head, Codex's is the head
  it signed — so a `blocked`, dismissed or body-only `CHANGES_REQUESTED` review is
  seen rather than walked past;
- proves every commit between those two heads is a Copilot fix, which is what
  licenses the delta;
- checks that every check on that head is green, not only the required ones,
  through `pr-ci-gate.sh` — addressed by the commit, so that answer is about the
  merge target;
- reads what the base branch requires and asks the merge target's own rollup
  whether those contexts passed on it, through `pr-ci-state.sh --required --head`,
  and reports `stale` if the head moved;
- refuses while any review thread is unresolved, paginated — a PR-level question,
  as is the round-boundary check beside it: neither takes the OID, and neither ever
  did;
- honours `REVIEW_MERGE_STRICT=1`, which drops `--admin` entirely.

**Every gate that can be addressed by a commit now is.** The reviewer verdicts and
the reviewed range are commit-addressed — though the Codex verdict is asked about
the head Codex signed rather than the merge head, with the range gate licensing the
delta. The all-checks gate reads the merge target's own rollup. The required-checks
gate reads what the base branch requires and asks that same rollup about those
contexts, which is #214 and closed. The thread and round-boundary gates do not take
an OID at all, and are about the pull request by nature.

**#214 IS CLOSED, and this record used to say it could not be.** It said the read
that would bind the required set needs administrator access and denies with a 404
indistinguishable from "not protected". That was measured on
`repos/{o}/{r}/branches/{b}/protection`, which does behave that way. The BRANCH
OBJECT — `repos/{o}/{r}/branches/{b}` — carries the same answer and is readable
with the `repo` scope this loop runs under: measured on ten repositories none of
which the measuring account administers, three required contexts came back for
`cli/cli`, eleven for `kubernetes/kubernetes`, twenty-three for `microsoft/vscode`,
while the dedicated endpoint 404s on the same repository with the same token. A
ruleset's contexts come from `repos/{o}/{r}/rules/branches/{b}`, and the required
set is the union: `home-assistant/core` requires eight contexts through a ruleset
with `protection.enabled` false, `cli/cli` the other way round.

**What that leaves for this record.** Nothing about the required set — it is bound.
What is still bounded rather than closed is the `--admin` bypass itself, below,
and two smaller things named where the code is: protection changed between the
required-set read and the merge, which is a race GitHub has too because protection
is a property of a branch rather than of a commit, and the "require branches to be
up to date" policy, which is not read.

**Strict mode is what closes it.** With `REVIEW_MERGE_STRICT=1` on a repository
whose required checks are non-bypassable — configured, and with bypassing
disallowed or the credential lacking that permission — GitHub evaluates those
itself at merge time, server-side and addressed by the commit it is merging. Strict
mode without the non-bypassable part only stops passing `--admin`, which is the
same condition the strict-mode list below turns on.

**The optional checks need nothing from GitHub**, which was not true until the
all-checks gate was bound to the merge target: GitHub never enforces an optional
check, and that gate now reads the merged commit's own, so a failing optional check
on it is caught by the gate rather than surviving into the merge.

## What is confirmed after the merge

This is not a bound on the bypass and does not constrain it: by the time it runs,
the merge command has already been issued.

- the PR state is read back **after** `gh pr merge`, and a PR that is not `MERGED`
  is reported as status 4 rather than `merged` — because a merge queue accepts the
  request without landing it and `gh` calls that success.

What it buys is that the driver does not act on a merge that did not happen. What
it cannot do is stop the merge, which is why it is listed apart from the gates
above.

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
- **required approvals** — zero only where no eligible approver exists; see below;
- **do not allow bypassing the above settings** — on (or an equivalent
  non-bypassable ruleset, or a `gh` credential without bypass permission).

**The last one is what makes the enforcement atomic, and it is not what makes
strict mode do anything at all.** Dropping `--admin` already refuses a merge whose
requirements are unmet when GitHub evaluates it — that is the flag's whole purpose
— so strict mode tightens the gate on any branch with rules configured.

What bypassing being disallowed adds is that GitHub's evaluation BINDS. Its
protected-branch rules do **not** apply to administrators or roles with bypass
permission unless bypassing is explicitly disallowed, and in the solo-maintainer
case this record is about the operator *is* the administrator — so without it the
credential can still merge past rules that were unmet, and nothing closes the
window between the last client-side probe and the merge. That window is the race
this record accepts, and this setting is the only thing that closes it.

**Conversation resolution decides something narrower**: whether unresolved threads
are one of the protections GitHub enforces at all. With bypass disallowed and this
off, strict mode still enforces the required status checks — it is not inert. What
is missing is the thread gate becoming server-side and atomic, which is the case
below.

Conversation resolution belongs in the list even so. The workflow already
satisfies it: `pr-merge-gate.sh` paginates every review thread and refuses while
any is unresolved, before it reaches the merge. So enabling the
corresponding protection costs nothing the loop was not already doing, and in
strict mode it becomes atomic — closing the case where a thread is opened after
the final client-side probe. Recommending checks only would have pointed operators
at a weaker configuration than the one they can actually run.

Required approvals is a BRANCH setting, applied to every PR targeting the branch
with no author condition. What decides the right value is not who authored a pull
request but whether ANYONE CAN APPROVE IT.

Codex and Copilot are GitHub Apps whose reviews do not count, and GitHub refuses a
self-approval — so the requirement is unsatisfiable only where there is no other
eligible approver at all. That is the case this record is about, and it is what the
accepted trade-off turns on. Where another maintainer exists they can approve the
operator's pull requests too, so the requirement costs a wait rather than the merge
path.

**Where the requirement stays but some pull requests cannot satisfy it, vary the
MODE.** `REVIEW_MERGE_STRICT` is per invocation rather than per branch, so those
that can get an approval run strict and the rest fall back to this record's
default. Zero is right only on a repository with no eligible approver; setting it
where one exists throws away real human review. The gate draws that line itself: `--admin` is
permitted to bypass a missing approval, and the unresolved-thread refusal above it
means it is never reached with a thread open.

`README.md` carries this configuration under its own `REVIEW_MERGE_STRICT`
heading, with the same two distinctions: disallowing bypass is what makes GitHub's
enforcement binding and atomic with the merge — dropping `--admin` already refuses
requirements that are unmet when GitHub evaluates them — and conversation
resolution decides whether unresolved threads are among the protections at all.
That is where an operator is told how; this list is here because the record has to
say what the trade-off rests on. #211.

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
