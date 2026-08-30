# Decision: a failed setup leaves what it made

**Date:** 2026-08-29
**Status:** accepted
**Decided by:** the repository operator, after the measurement in this record's own PR
**Raised in:** #229, rounds 13 through 28

`pr-setup.sh` removes NOTHING. Not the files it wrote, not the transport it read the
origin out of, and not the reservation itself — so a refusal leaves whatever it had made
at that point, and nothing collects it.

That is accepted rather than fixed. This record is what a reviewer should be pointed at
when it is raised again.

**It accepts this and nothing else.** The reservation race on the candidate name is
`2026-08-26-transport-candidate-in-argv.md`; the reservation being an inference is
`2026-08-26-reservation-inference.md`. Those bound what `pr-origin.sh` can LOSE. This one
is about what `pr-setup.sh` LEAVES.

## Why nothing is removed

Every shape that removed something needed a NAME, and a name inside — or at — a directory
a same-UID process can write to is one that may have been substituted between being
created and being removed. Each was tried in turn, and each destroyed something a reviewer
then found:

| shape | what it took |
| --- | --- |
| `rm -rf "$RB_DIR"` | a replacement's entire tree |
| named `rm -f` per leaf | a replacement's file at one of this run's names |
| a ledger of what this run created | nothing — but it missed whatever a signal landed in front of, leaving the tree anyway |
| `rmdir` on every directory name unconditionally | a watcher's empty directory at a name this run never reached |
| one `rmdir` on the reservation, ungated | a racer's empty reservation, where no inode had been recorded |
| one `rmdir` on the reservation, gated on a held descriptor and a recorded inode | a replacement substituted between the comparison and the `rmdir` — the comparison reads the name, and so does the removal |

The last row is the one that ends it. Shell has no descriptor-relative removal: no
`unlinkat`, and no `rmdir` on a directory a descriptor holds. **Every removal resolves a
name after whatever check preceded it**, so there is no shape that removes anything here
and cannot take something a same-UID process substituted.

**The cleanup traps went with the cleanup**, because there was nothing left for a handler
to run. Measured on bash 5: an untrapped `TERM` ends the run with status 143 and an
untrapped `HUP` with 129, which is what a caller should see.

**`INT` is the exception, and it removes nothing either.** Measured the same way, a
non-interactive shell does not die of `INT` delivered to it while it waits on a child: the
run continues, writes every working file and publishes `status=ready`, so a caller reads a
session somebody stopped as one that succeeded. The handler disarms itself and re-raises —
that is the whole of it — and the reservation is left exactly as any other refusal leaves
it.

## What is accepted, measured rather than argued

| situation | measured outcome |
| --- | --- |
| the `mkdir` never succeeded | there is no directory of this run's, and none is left |
| a refusal after the reservation | the directory is **left**, with whatever had been written in it |
| a refusal from `pr-origin.sh read` itself | the directory is left and is **empty** — that helper creates its own transport and gives it back on its own refusal path (#157), which is the one removal this contract does not cover and does not own |
| a signal at any point | **whatever had been written by then is left** — `TERM` and `HUP` terminate by bash's own default with no handler at all, `INT` is re-raised by the one handler there is, and neither path removes anything, so a signal after the reader wrote `o/origin` leaves the reservation AND that transport |
| anything a same-UID process placed at or inside that name | **untouched by this helper** — with one exception it does not own: an object at `<dir>/o/origin` is removed by `pr-origin.sh`'s own cleanup, which resolves that name (`rm -f "$OUT"`), so a replacement planted there between its write and its refusal goes with it |

`test-pr-setup.sh` stages these against the real helper — `TERM`, `INT` and `HUP` all
delivered mid-run — and asserts that the file contains NO removal of any kind and that no
handler it arms removes anything, so a shape that resolves a name for removal cannot come
back, behind a signal or otherwise, without a case failing. What it does NOT stage is the
exception in the last row: that removal is `pr-origin.sh`'s, governed by its own contract
and its own fixture, and this record neither owns it nor accepts it on that helper's
behalf.

## What it costs

One directory per refused attempt, under `TMPDIR` or `HOME`, holding at most the four
working files, the origin and the transport leaf. Nothing collects it. **Litter rather
than loss**, which is the trade this record accepts.

## What is NOT accepted here

The origin file the driver reads is a different question — about which object was BOUND
rather than which was removed, with a session acting on another repository rather than a
racer losing a file. That is #230, open.
