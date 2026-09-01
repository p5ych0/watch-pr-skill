# Decision: the leaf cleanup's two races are accepted

**Date:** 2026-09-01
**Status:** accepted
**Decided by:** the repository operator, after the measurement in this record's own PR
**Raised in:** review of #255; filed as #257 rather than waived there, because a record
cannot waive a finding in the pull request that introduces the behaviour — #256 tried and
was closed for it.

`pr-origin.sh` flips `RB_PHASE` inside each write's own redirection, so the leaf is OPEN
before the assignment that marks it as this run's. Two races survive that shape, and both
are accepted rather than fixed. This record is what a reviewer should be pointed at when
either is raised again.

**It accepts these two and nothing else.** The candidate name being public in argv is
`2026-08-26-transport-candidate-in-argv.md`; the reservation being an inference is
`2026-08-26-reservation-inference.md`; what `pr-setup.sh` LEAVES is
`2026-08-29-setup-leaf-cleanup.md`, which explicitly declines to accept the replacement
case on `pr-origin.sh`'s behalf. This record is what accepts it, here, with its cost
measured.

## Race A — a pre-phase refusal with a leaf present leaves the transport

A `TERM`, `HUP` or `INT` delivered between the redirection opening the leaf and
`RB_PHASE=post` executing runs the cleanup while the phase is still `pre`, which is
`rmdir` alone — and `rmdir` necessarily fails on a directory that now holds a leaf. The
same residue is reached by any refusal that fires while a same-UID process has planted a
leaf of its own: the mismatch refusal, the origin read's, the walks'.

**Cost: one directory and the one leaf inside it, left behind under a parent the caller
named.** Litter, never loss. Which leaf depends on the variant — the one this run opened,
where a signal landed in the window; the racer's own, where a refusal fired with a foreign
leaf already present — and in neither case is anything outside that directory touched. The
caller performs no cleanup after a non-zero status, deliberately, because it cannot know
who created the path, so nothing collects it.

**Measured**, not argued: `test-pr-origin.sh` stages a same-UID racer that plants a leaf
the moment the directory exists, drives the pin mismatch refusal, and asserts both that
the foreign leaf survives and that the directory is left behind. If the bound changes —
if a pre-phase refusal starts removing something — the case fails.

## Race B — after the flip, a replacement at the leaf is removed by name

Once the phase is `post`, `rb_cleanup` runs `rm -f "$OUT"`. It removes by NAME, and there
is no check that the object at that name is the one this run wrote. A same-UID process
that unlinks our leaf and puts its own there between the write and the cleanup has its
object removed instead.

The cleanup reaches that state on two paths and no others: the write's own `|| rb_refuse`,
where the leaf opened exclusively and the storage then rejected the bytes; and a signal
delivered between the flip and the `trap - EXIT` that follows the write, which is two
shell instructions.

**Cost: one object, and only one a same-UID process placed inside a directory this run
created with `mkdir -m 700`.** Not an arbitrary path: the name is `<dir>/origin` or
`<dir>/pin` under a directory this helper created exclusively, in a mode no other account
can enter. The exposure is a same-UID process that has deliberately entered this run's own
reservation, which is the same actor every other record here is bounded against.

**Measured**: `test-pr-origin.sh` drives the open-then-fail write with a zero file-size
limit — the redirection creates the leaf, the `printf` into it fails — with a racer on
`PATH` that replaces the leaf with a foreign object before the real removal runs, and
asserts the replacement is gone. If the cleanup ever stops removing by name, the case
fails and this record is what should be revisited.

## Why neither is fixed

Marking the leaf as this run's requires knowing we opened it, and the only durable evidence
is the descriptor — while shell has no descriptor-relative removal. That is the same
limitation `2026-08-29-setup-leaf-cleanup.md` convicts the whole removal class on. Every
alternative placement of the flip was tried, and each is worse:

| shape | residue |
| --- | --- |
| flip inside the redirection (today) | a signal in a two-instruction window leaves one directory and its leaf |
| flip before the redirection | a signal in the window **deletes a foreign leaf** — loss, not litter |
| flip at the walks | every refusal between the walks and the write runs the leaf-removing shape for a leaf the run never created |
| flip after the write | every refusal between the open and the write leaks, over a longer interval |
| record the leaf's inode and compare before removing | check-then-use: the removal resolves the name again after the comparison, and `stat` is a name |
| ignore signals across the write | trades a bounded litter for a write that cannot be interrupted — worse on a blocking target |
| a descriptor-relative unlink in the handler | not available in shell |

The current shape is the only one whose worst case is litter rather than loss on the wider
window, and it shrinks that window to two adjacent operations.

## What would change this

A shell with descriptor-relative removal, or moving the transport to a helper that is not
a shell. Either makes race B closable and race A's residue collectable. Until then, both
are accepted with the costs measured above.
