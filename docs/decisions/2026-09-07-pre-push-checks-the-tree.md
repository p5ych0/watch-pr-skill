# Decision: the pre-push hook checks the working tree

**Date:** 2026-09-07
**Status:** accepted
**Decided by:** the repository operator, in session, on the measurement below
**Raised in:** #316, attempted in #322

`.claude/hooks/pre-push.sh` runs `pr-selfcheck.sh` over the working tree before a command
that contains a `git … push` or a `pr-close-round.sh … gate`. A push sends commits, so the
tree and what is sent are the same thing only while they agree.

## What is accepted

- **A tree that differs from the pushed commit is checked instead of it.** A dirty tree can
  block a clean head, and a clean tree can pass a head it no longer matches.
- **An explicit refspec sends what the tree never was.** `git push origin HEAD~1:refs/heads/x`
  sends a commit no check read.
- **The check reads what the push does not send.** An untracked file under
  `skills/watch-prs/scripts/` is parsed by the self-check and can block a clean head.

## What it cost to learn

#322 tried to close the first of these by refusing while a tracked file differed from the
commit. The matcher that decides whether the hook runs is deliberately conservative — it is a
text match, and a mention inside an argument costs a self-check run — so the refusal also
fired on a commit whose message mentioned a push, making that commit impossible exactly when
the tree was dirty. The rule it broke, that a mention costs a run and nothing more, is the one
the loop depends on. The other two cases it did not close at all.

Closing all three means checking out the pushed commit into a temporary work tree and running
the check there, on every push. That cost is paid by every push in exchange for cases the loop
does not produce: `pr-close-round.sh gate` commits and pushes in one step, and the driver
never writes an explicit refspec.

## What does not change

- The hook still fails closed on everything it can see, and a regression in one of those
  guards is a finding.
- An operator who pushes by hand from a dirty tree, or with an explicit refspec, is outside
  what this hook checks. `pr-selfcheck.sh` run directly is the answer there, and the loop's
  own gate is unaffected.
