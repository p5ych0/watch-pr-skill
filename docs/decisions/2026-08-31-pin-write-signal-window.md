# A signal between opening the leaf and marking it leaves the transport behind

**Date:** 2026-08-31
**Status:** accepted
**Decided by:** the repository operator, after the measurement in this record's own PR
**Scope:** `pr-origin.sh`, both writes — `read`'s origin and `pin`'s value
**Raised in:** review of #255, closing #230

## The window

Each write is `{ RB_PHASE=post; printf …; } > "$OUT"`. A redirection on a group is applied
before the group runs, so the leaf is **open** before the assignment executes. Between
those two events a delivered `TERM`, `HUP` or `INT` runs the cleanup while `RB_PHASE` is
still `pre` — the shape that runs `rmdir` alone — and `rmdir` cannot remove a directory
that now holds a leaf. The run exits non-zero and the transport is left behind, which no
caller collects.

## Why the obvious fix is worse

Flipping the phase first inverts the failure rather than removing it. Then a signal
delivered *before* the redirection opens anything runs `rm -f "$OUT"` with nothing written
— harmless where the name is empty, and a **deletion of a foreign leaf** where a same-UID
process has put one there. That is the direction this repository has already refused:
`2026-08-29-setup-leaf-cleanup.md` records four removal shapes, each of which destroyed
something a reviewer then found, and settles on litter over loss.

The two events cannot be made one. Marking the leaf as ours requires knowing we opened it,
and the only durable evidence is the descriptor — while shell has no descriptor-relative
removal, which is the same limitation `2026-08-29` records. Every arrangement is one of:

| shape | residue |
| --- | --- |
| flip inside the redirection (this one) | a signal in the window leaves one directory and its leaf |
| flip before the redirection | a signal in the window **deletes a foreign leaf** |
| flip after the write | every refusal between the open and the write leaks the same way, over a longer interval |
| a descriptor-relative unlink in the handler | not available in shell |

## What is accepted, and what bounds it

**Accepted:** a signal delivered inside that interval leaves the transport directory with
one leaf in it. It is litter, in a directory named with `$$` and three `$RANDOM`s under
`TMPDIR` or `HOME`, and the caller collects nothing after a non-zero status by design —
it cannot know who created the path.

**Not accepted, and still true:** nothing this helper does removes an object it did not
write. That is what the phase protects and it is unchanged by this record.

## What pins the bound

`test-pr-origin.sh` stages signals against the real helper at the points that CAN be
staged — during the reservation, and after it — and asserts what is left each time. The
interval in this record is between two adjacent operations and cannot be hit
deterministically: a fixture aiming at it would pass on scheduling rather than on the
code. What is asserted instead is the property that makes the residue litter rather than
loss — a refusal before a write never removes a foreign leaf, staged with one present —
and the structural assertion that the flip lives inside the redirection, which is what
keeps the window at its minimum rather than at the length of a refusal path.

If either of those fails, this record's bound has moved and the acceptance no longer
holds.
