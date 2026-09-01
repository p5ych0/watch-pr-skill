# The pre-bootstrap clearings open a path they cannot bound

**Date:** 2026-09-01
**Status:** accepted
**Decided by:** the repository operator, after the measurement in this record's own PR
**Scope:** `pr-copilot-phase.sh`, the clearings above the bootstrap — `record`'s sha file
and `open`'s baseline file
**Raised in:** review of #244, filed as #245

## The window

Both clearings run at the top of the file, before the bootstrap and before any argument is
looked at. Each is guarded by `[[ -f ${4} ]]` and then opens the path with `>`. That is a
check-then-use: a same-UID process can replace the path with a FIFO between the test and
the open, and `>` on a FIFO blocks for a reader that never arrives.

## Why it cannot be bounded where it is

Every bounded open in this tree goes through `run_limited`, which arrives with the
bootstrap. These clearings run above the bootstrap deliberately — so that a refusal from
the bootstrap itself cannot leave the previous run's value for the caller to read as this
one's. Bounding them therefore means loading the library first, which is the same thing as
moving the clearing below the bootstrap. Hand-rolling a second watchdog above it is the
duplication `run_limited` exists to prevent, and this repository has removed that shape
before.

## What moving it would cost, measured against the driver

#245 asked whether a stale value after a bootstrap failure is reachable by any reader. It
is, for one of the two, and the answer differs per stage:

| stage | is the file read after a refusal? |
| --- | --- |
| `record` | **No.** The driver reads `$HEAD_FILE` in the success arm and in the `3` arm; a bootstrap failure exits 1 and takes the `*)` arm, which reads nothing. With `exit` shadowed to return, execution falls past the fence with `CODEX_SHA` never assigned, and the next stage refuses an empty sha. |
| `open` | **Yes.** With `exit` shadowed, a refusal falls past the fence into the wait step, which passes `$PRIOR_FILE` to `pr-watch.sh --after-review-file`. A stale baseline that is a well-formed review id is accepted there, and the watch then waits past a review that has already happened. |

So the clearing is defensive depth for `record` and load-bearing for `open`. Moving both
below the bootstrap would weaken the one that matters; moving only `record`'s would leave
two clearings in one file differing for a reason no reader could see from the code.

## What is accepted

A same-UID process that replaces either path with a FIFO between the `[[ -f ]]` and the
`>` blocks the stage. It is a denial of service: the opens are before any mutation, so
nothing is posted, no phase is half advanced, and the operator kills a stuck process.

**Not accepted, and unchanged:** no value is forged, and nothing is read as current that a
previous run wrote — which is what the clearings are for and what keeping them above the
bootstrap preserves.

## What pins the bound

`test-pr-copilot-phase.sh` asserts that a refusal before either write leaves no stale
value, including one that cannot bootstrap, and that a refused `open` leaves no baseline
for the caller to read. Those are what make the residue a stall rather than a wrong value.
If either fails, this record's bound has moved and the acceptance no longer holds.
