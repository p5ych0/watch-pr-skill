# Decision: the reservation being an inference is an accepted limit

**Date:** 2026-08-26
**Status:** accepted
**Decided by:** the repository operator, after the measurement in this record's own PR
**Closes:** #162

`pr-origin.sh` decides whether a directory found after a signal is one this run
created from two recorded facts rather than from a handoff. That is accepted
rather than fixed. This record is what a reviewer should be pointed at when it is
raised again, and it exists because `AGENTS.md` makes a dated decision record the
only thing that can accept a limitation — a comment in a diff cannot.

**It accepts #162 and nothing else.** #160 — the candidate name being published
in argv before the `mkdir` reserves it — is a different race, accepted separately
in `2026-08-26-transport-candidate-in-argv.md`.

## What is accepted

- `RB_OWNED` is set after a successful `mkdir`. It is certain and LATE: measured,
  a signal delivered while that external command runs is handled once it RETURNS
  and before the `&&` that sets the flag.
- `RB_PREEXISTED` is a `[[ -e ]]` taken before the traps are armed, so a
  directory at a name that held nothing when this run began is one this run made.

Both are inferences, and two same-UID interleavings defeat them.

## What each one costs, measured rather than argued

`test-pr-origin.sh` stages both against the real helper, with `mkdir` on `PATH`
acting as the racer at exactly the moment each interleaving describes. Everything
else — the traps, the flags, the cleanup — is the real code.

| Interleaving | Measured outcome |
| --- | --- |
| a racer creates the name between the `[[ -e ]]` and the `mkdir`, and its directory is **empty** | this run's cleanup **removes it** — `RB_PREEXISTED` is `no`, `-O` passes because the racer is the same account |
| the same, but the racer's directory **holds anything** | it **survives**, contents intact: `rmdir` refuses a non-empty directory |
| the observed entry is removed before this run's `mkdir` succeeds, and a signal lands before `RB_OWNED=yes` | this run's directory **leaks**, and what leaks is **empty** |

**That is the whole of it: an empty directory is lost, or an empty directory is
left behind.** No data is destroyed, because `rmdir` refuses anything with
contents in it. No value is forged, no origin is misread, and no session is
pinned to the wrong repository. The victim of the first is another same-UID
process that loses an empty reservation and takes a retry — the same class of
cost as #160, which is accepted on the same grounds.

**And the occupant of that class is narrow.** Both interleavings need a same-UID
process to hit a window on a name carrying this session's pid and three `$RANDOM`
draws. The realistic candidate is another session of this same loop, which has a
different pid.

## What the fix would have been, and why it is not proportionate

`mktemp -d "$parent/watch-pr.XXXXXXXXXX"` chooses the leaf inside the process and
creates it atomically, so `RB_PREEXISTED` stops being an inference — `mktemp`
returns only names it created. That closes the first interleaving outright.

It does not close the second. A signal delivered while `mktemp` runs still lands
before the assignment that records the path, and nothing recovers a name only a
dead command substitution held.

And it costs the return channel. The helper would know the name and the driver
would not, and every channel is poisoned or fragile — measured on bash 5, with
`BASH_XTRACEFD=1` a command substitution captures its own trace line; taking the
LAST line recovers the value and survives a hostile `PS4`, but a traced command
after the producer inside the same substitution becomes the last line, which
makes it a rule about how the call site is written rather than a property of the
channel. `2026-08-26-transport-candidate-in-argv.md` sets that out in full, along
with the three closed attempts (#176, #180, #186).

So: a protocol change to the most heavily defended file in the tree, on a
fragile channel, closing one of two interleavings, against a cost of one empty
directory.

## What would reopen this

- either bound changing — a racer's directory with contents being destroyed, or
  a leaked directory carrying a value. `test-pr-origin.sh` fails if either does,
  which is what keeps this record honest;
- a return channel whose correctness does not depend on how the call site is
  written, which would make the rework cheap enough to take anyway;
- a second consumer of the transport, so a lost reservation costs more than a
  rerun.

Until then: raising #162 against a pull request is answered by this record.
Raising a *new* defect in the same area is not — this accepts one named race and
nothing else.
