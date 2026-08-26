# Decision: the transport reservation races are accepted limits

**Date:** 2026-08-26
**Status:** accepted
**Decided by:** the repository operator, after the measurement in PR #187
**Closes:** #160, #162

Two races in the transport the driver uses to read `origin` are accepted rather
than fixed. This record is what a reviewer should be pointed at when either is
raised again, and it exists because `AGENTS.md` makes a dated decision record the
only thing that can accept a limitation — a comment in a diff cannot.

## What is accepted

**#160 — the candidate name is published in argv before it is reserved.**
`pr-origin.sh` reserves with `/usr/bin/env mkdir -m 700 "$RB_DIR"`, an external
command, so the path is in that process's argv. `/proc/<pid>/cmdline` is mode
444, so any account on the machine can read it in the window between the `exec`
and the `mkdir` syscall, and create the name first.

**#162 — the reservation is an inference, not a handoff.** The helper decides
whether a directory found after a signal is one this run created from two
recorded facts: `RB_OWNED`, set after a successful `mkdir`, and `RB_PREEXISTED`,
a `[[ -e ]]` taken before the traps are armed. Two same-UID interleavings defeat
them — a process creating the name between the test and the `mkdir` makes the
cleanup remove a directory this run did not create, and one removing an observed
entry before the `mkdir` succeeds leaks this run's directory if a signal lands
before `RB_OWNED=yes`.

## Why they are acceptable, measured rather than asserted

**The cost of #160 is a denial of service, never a forged identity**, and that is
what took it from an unweighable race to an accepted one. `test-pr-skill-contract.sh`
stages it against the real helper and a real checkout:

| Staged | Measured outcome |
| --- | --- |
| one parent squatted | the retry recovers; the session is pinned to the **real** origin; the parent that worked becomes the one everything after it uses |
| both parents squatted | setup **refuses**, non-zero — nothing pinned, nothing forged, and no value written through a name the helper did not take |

The exclusion is what makes that true. `mkdir -m 700` refuses a name somebody
else holds, so a squatter cannot put a value where setup will read it;
`test-pr-origin.sh` proves that half on the helper, including that an existing
directory, file or symlink is refused, never written through, and left where it
was. So the worst an attacker achieves is blocking a session, and #161's retry
means blocking one costs them **both** candidate names rather than one.

**#162's two interleavings need a same-UID process** to hit a window on a name
carrying this session's pid and three `$RANDOM` draws. The realistic occupant of
that class is another session of this same loop, which has a different pid.

## What the fix would have been, and why it is not proportionate

Reserve, then publish: `mktemp -d "$parent/watch-pr.XXXXXXXXXX"` puts only the
TEMPLATE in argv, chooses the leaf inside the process, and creates it atomically —
so no watcher sees the final name until it exists and is ours, and
`RB_PREEXISTED` stops being an inference because `mktemp` returns only names it
created.

Three attempts were made in this area and all three were closed: #176 (three
driver-side authentications of a guessed directory, each refuted), #180
(recording the gap as a limit while it was still fixable — the wrong answer, and
the reason this record insists on the measurement above), and #186 (moving the
name from argv into the environment, which only moves the publication point,
since `mkdir`'s own argv still carries it).

What defeats the remaining shape is the return channel. The driver must learn the
name, and every channel is either poisoned or fragile:

- **stdout.** Measured on bash 5: with `BASH_XTRACEFD=1`, `V="$(cmd)"` captures
  its own trace line. Taking the LAST line recovers the value, and survives a
  hostile `PS4` that runs a command of its own — but a traced command *after* the
  producer inside the same substitution becomes the last line. That makes it a
  rule about how the call site is written rather than a property of the channel,
  which is the shape this repository has paid for and deleted before.
- **a fixed descriptor.** Removed once already: whichever descriptor carries the
  value, a caller tracing to it writes its trace into the value, and moving
  `BASH_XTRACEFD` aside closed fd 2 when it was restored.
- **a path the driver names.** That is the current design, and it is what #160 is
  about.

Against a bounded denial of service, that is a protocol change to the most
heavily defended file in the tree, on a channel with a known fragility, plus most
of `test-pr-origin.sh` — which is about the exclusion that would move.

## What would reopen this

Any of these raises the price and makes the rework proportionate again:

- a shared multi-user machine entering the supported set, so the cross-account
  squat stops being theoretical;
- a second consumer of the transport, so a blocked session costs more than a
  rerun;
- a return channel whose correctness does not depend on how the call site is
  written.

Until then: raising #160 or #162 against a pull request is answered by this
record. Raising a *new* defect in the same area is not — this accepts two named
races and nothing else.
