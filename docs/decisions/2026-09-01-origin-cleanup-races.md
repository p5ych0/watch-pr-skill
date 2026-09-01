# Decision: a refusal may leave the reservation, and that litter is accepted

**Date:** 2026-09-01
**Status:** accepted
**Decided by:** the repository operator, after the measurement in this record's own PR
**Raised in:** review of #255; filed as #257 rather than waived there, because a record
cannot waive a finding in the pull request that introduces the behaviour — #256 tried and
was closed for it.

`pr-origin.sh` used to flip `RB_PHASE` inside each write's own redirection, so the leaf was
OPEN before the assignment that marked it as this run's. #257 named two consequences of that
shape and asked for both to be measured. **They were, and the measurement separated them:
one is accepted here and the other is a defect.** This record is what a reviewer should be
pointed at when the accepted one is raised again.

**It accepts one race and nothing else.** The candidate name being public in argv is
`2026-08-26-transport-candidate-in-argv.md`; the reservation being an inference is
`2026-08-26-reservation-inference.md`; what `pr-setup.sh` LEAVES is
`2026-08-29-setup-leaf-cleanup.md`, which explicitly declines to accept the replacement
case on `pr-origin.sh`'s behalf. It was right to decline: measured, that case is worse than
it looked, and it is not accepted here either.

## Accepted — a refusal leaves a reservation that is not empty

The cleanup is `rmdir` alone, and `rmdir` necessarily fails on a directory that is not
empty. So any refusal that fires while a same-UID process has put something in the
directory leaves it: the mismatch refusal, the origin read's, the walks'. When this was
written the cleanup had a second, leaf-removing shape and this race was the window before
the flag selecting it flipped; #266 removed that shape, which widens the residue to every
refusal and narrows what a refusal can touch to nothing.

**Cost: the reservation directory and whatever it contains, left behind under a parent the
caller named.** The contents are RACER-CONTROLLED and there is no upper bound on them:
once the mode-700 directory exists, a same-UID process can create any number of files and
subdirectories in it, and the `rmdir` leaves all of them. An earlier draft of this record
said "one directory and one leaf" and that was an example rather than a bound; the fixture
now plants a leaf, a sibling and a nested subtree, and asserts every one survives.

**What makes it acceptable is not the size, it is the KIND.** Nothing is destroyed. The
cleanup in this phase removes only an empty directory, so a refusal leaves litter under a
path the caller named and takes nothing of anybody else's. The caller performs no cleanup
after a non-zero status, deliberately, because it cannot know who created the path — so
nothing collects it, and that is the whole of the cost.

**Measured**, not argued: `test-pr-origin.sh` stages a same-UID racer that populates the
directory the moment it exists, drives the pin mismatch refusal — asserting it reached the
MISMATCH and not the exclusion, which would be a directory this run never made and a
vacuous pass — and asserts the directory and every planted object are still there. If a
refusal ever starts removing something from the reservation, the case fails.

## NOT accepted — the leaf removal, which reached outside the reservation

#257's second gap is a defect rather than a limit, and measuring it is what settled that.

Once the phase was `post`, `rb_cleanup` ran `rm -f "$OUT"`. It removed by NAME, and every
check above it — `[[ -d $RB_DIR ]]`, `[[ -O $RB_DIR ]]` — FOLLOWS SYMLINKS. So a same-UID
process that renames the reservation and leaves a symlink to another directory in its place
has that directory's `pin` or `origin` removed instead. Measured: with the write failing
under a zero file-size limit and the swap performed between the write and the cleanup, a
file in an unrelated directory was unlinked.

That is not "one object inside a directory this run created", which is what an earlier
draft of this record claimed and what #257 warned against asserting. It is an arbitrary
same-UID file at a path the racer chooses, and it is the same class
`2026-08-29-setup-leaf-cleanup.md` convicted for `pr-setup.sh`, which now removes nothing
at all. The consistent answer is the same one, and it is a REMOVAL rather than a guard: a
further symlink check before the `rm` is a check-then-use, since the removal resolves the
name again afterwards.

It was not fixed in this change because it is a behaviour change to a helper, which this
repository lands as its own pull request. **It is #266, and it is now fixed**: the leaf
removal is gone and the cleanup is `rmdir` alone throughout the run, which refuses a symlink
outright. The residue that fix leaves is a post-write refusal keeping the directory and its
leaf — the litter this record accepts, and of the same kind, nothing destroyed.

**This record still accepts only the litter.** What #266 removed was a defect; what remains
is that a refusal leaves the reservation behind, whatever phase it happens in, and that is
the cost accepted above.

## Why the flip is not moved instead

The window existed because the flip was inside the redirection. Every other placement was
tried, and each was worse — this is the comparison the reviewer files point at, kept as the
record of what a name-based removal cost to place:

| placement | residue |
| --- | --- |
| inside the redirection (what shipped) | a signal in a two-instruction window leaves the reservation as it found it — litter |
| before the redirection | a signal in the window runs the leaf-removing shape with nothing written: **loss**, not litter |
| at the walks | every refusal between the walks and the write runs the leaf-removing shape for a leaf the run never created |
| after the write | every refusal between the open and the write leaks, over a longer interval |
| record the leaf's inode and compare before removing | check-then-use: the removal resolves the name again after the comparison, and `stat` is a name |
| ignore signals across the write | trades a bounded litter for a write that cannot be interrupted — worse on a blocking target |
| a descriptor-relative unlink in the handler | not available in shell |

The shape that shipped was the only one whose worst case was litter rather than loss, and
it shrank the interval to two adjacent operations.

**Since #266 this table is history rather than a live comparison.** Every row naming a
leaf-removing shape describes a removal that no longer exists: the cleanup is `rmdir` alone
throughout the run, and the flag that selected the removing shape went with it — so there is no
placement left to choose. It is kept because it records what was tried and why each
placement failed, which a later change proposing to reintroduce a name-based removal has to
answer.

## What would change the accepted half

A shell with descriptor-relative removal, or a transport that is not a shell — either would
let the reservation be given back on a refusal instead of left. Until then a refusal leaves
what it found, and that is the accepted cost.
