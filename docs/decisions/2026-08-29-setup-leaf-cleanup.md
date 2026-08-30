# Decision: a failed setup leaves its own tree behind

**Date:** 2026-08-29
**Status:** accepted
**Decided by:** the repository operator, after the measurement in this record's own PR
**Raised in:** #229, rounds 13 through 18

`pr-setup.sh` gives its reservation back with ONE `rmdir` and removes nothing inside it.
A refusal after anything has been created therefore leaves that directory in place,
holding files this run wrote.

That is accepted rather than fixed. This record is what a reviewer should be pointed at
when it is raised again.

**It accepts this and nothing else.** The reservation race on the candidate name is
`2026-08-26-transport-candidate-in-argv.md`; the reservation being an inference is
`2026-08-26-reservation-inference.md`. Those bound what can be LOST. This one is about
what is LEFT.

## Why the contents are not removed

Every shape that gave them back needed a NAME, and a name inside a directory a same-UID
process can write to is one that may have been substituted between being created and
being removed. Each was tried in turn and each destroyed something:

| shape | what it took |
| --- | --- |
| `rm -rf "$RB_DIR"` | a replacement's entire tree |
| named `rm -f` per leaf | a replacement's file at one of this run's names |
| a ledger of what this run created | nothing — but it missed whatever a signal landed in front of, leaving the tree anyway |
| `rmdir` on every directory name unconditionally | a watcher's empty directory at a name this run never reached |

Shell has no `unlinkat`, so every removal resolves a path; holding a descriptor per
object moves the same check-then-use one level down. There is no shape that removes the
contents and cannot destroy something.

## What is accepted, measured rather than argued

`rmdir` succeeds only on an EMPTY directory and refuses a symlink outright. So the
cleanup can destroy no CONTENTS whatever has happened at that name, and the cost moves
from loss to litter.

**One thing it can still take, and that is accepted elsewhere.** A racer which creates
the candidate between `RB_PREEXISTED=no` and this helper's `mkdir` has its EMPTY
reservation removed — the measured cost in
`docs/decisions/2026-08-26-reservation-inference.md`, which this record does not widen and
does not repeat.

| situation | measured outcome |
| --- | --- |
| a refusal before anything is created | the reservation is **given back** |
| a refusal after `work/`, the origin or the transport exists | this run's **own tree is left**, contents intact |
| a signal at any point | the same: given back if empty, left if not |
| anything a same-UID process placed inside, at any name | **untouched** |

`test-pr-setup.sh` stages each of those against the real helper, and asserts the cleanup
body contains exactly one `rmdir` and no `rm` at all — so a shape that resolves a name
inside the reservation cannot come back without a case failing.

## What it costs

One directory per refused attempt, under `TMPDIR` or `HOME`, holding at most the four
working files, the origin and the transport leaf. Nothing collects it. That is more
litter than `2026-08-26-reservation-inference.md` accounts for, and it is the trade this
record accepts: **litter rather than loss.**

## What is NOT accepted here

The origin file the driver reads is a different question — about which object was BOUND
rather than which was removed, with a session acting on another repository rather than a
racer losing a file. That is #230, open.
