# Decision: the transport candidate being published in argv is an accepted limit

**Date:** 2026-08-26
**Status:** accepted
**Decided by:** the repository operator, after the measurement in PR #187
**Closes:** #160

One race in the transport the driver uses to read `origin` is accepted rather
than fixed. This record is what a reviewer should be pointed at when it is raised
again, and it exists because `AGENTS.md` makes a dated decision record the only
thing that can accept a limitation — a comment in a diff cannot.

**It accepts #160 and nothing else.** #162 — the reservation being an inference
rather than a handoff — is a different race with a different trigger, and it is
NOT accepted here: its interleavings have not been measured, and this record's own
standard is that a limitation is accepted only after its cost is measured. It
stays open.

## What is accepted

`pr-origin.sh` reserves with `/usr/bin/env mkdir -m 700 "$RB_DIR"`, an external
command, so the path is in that process's argv. `/proc/<pid>/cmdline` is mode
444, so any account on the machine can read it in the window between the `exec`
and the `mkdir` syscall, and create the name first.

## Why it is acceptable, measured rather than asserted

**The cost is a denial of service, never a forged identity**, and that is what
took it from an unweighable race to an accepted one. `test-pr-skill-contract.sh`
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

What those cases model is the `mkdir` failing, and nothing else. Staging a real
squat means pre-creating a name built from `$$` and three `$RANDOM` draws inside
a shell the fixture has not started yet — unknowable in advance, which is
precisely why a squatter has to READ it. Everything downstream of the `mkdir` is
the real code.

## What the fix would have been, and why it is not proportionate

Reserve, then publish: `mktemp -d "$parent/watch-pr.XXXXXXXXXX"` puts only the
TEMPLATE in argv, chooses the leaf inside the process, and creates it atomically —
so no watcher sees the final name until it exists and is ours.

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

Until then: raising #160 against a pull request is answered by this record.
Raising a *new* defect in the same area is not — this accepts one named race and
nothing else, #162 included.
