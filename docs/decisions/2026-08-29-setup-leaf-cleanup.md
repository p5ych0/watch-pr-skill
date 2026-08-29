# Decision: the setup cleanup removing leaves by name is an accepted limit

**Date:** 2026-08-29
**Status:** accepted
**Decided by:** the repository operator, after the measurement in this record's own PR
**Raised in:** #229, rounds 13 and 14

`pr-setup.sh` gives its reservation back on a failure path. It proves first that the
name still resolves to the object its `mkdir` made — a descriptor held open on that
object, so the inode cannot be reused, and the recorded number compared against the
path's — and then removes the leaves it created by NAME. A same-UID process that
substitutes the tree between the check and the removals is not refused.

That is accepted rather than fixed. This record is what a reviewer should be pointed at
when it is raised again.

**It accepts this and nothing else.** The reservation race on the candidate name is
`2026-08-26-transport-candidate-in-argv.md`; the reservation being an inference is
`2026-08-26-reservation-inference.md`. Neither covers a substitution after a successful
`mkdir`, which is why this record exists rather than an extension of one of those.

## Why there is no fix rather than a deferred one

Unlinking relative to a held descriptor is not something shell can do: there is no
`unlinkat` and no `openat`, so every removal resolves a PATH. Holding a descriptor per
leaf and comparing its inode before each unlink moves the same check-then-use one level
down — the substitution can happen between that comparison and the `rm`, exactly as it
can now.

The alternative is not removing the leaves at all, and that is worse by the record above:
`rmdir "$RB_DIR"` cannot give the reservation back with children in the way, so a refusal
would leave a NON-empty published directory where `2026-08-26-reservation-inference.md`
accounts for one empty one.

## What it costs, measured rather than argued

`test-pr-setup.sh` stages the substitution at exactly the described moment — patched into
a copy of the helper immediately after the identity comparison, because the window is
inside one function and no external process can be scheduled into it. Everything else is
the real code.

| What the racer leaves at the substituted path | Measured outcome |
| --- | --- |
| a file at a name this run HAD ALREADY CREATED — `origin`, `work/summary.md` | **removed** |
| a file at a name this run creates LATER, or never | **survives, untouched** |
| a file at any other name | **survives, untouched** |

The middle row is a separate case and a separate fixture. The cleanup used to remove
every name this helper ever creates, so a `pr-origin.sh` that planted `$RB_DIR/origin`
and then refused had that file deleted by a run which never wrote it. Each creation is
recorded as it happens now, and only what is on that list comes out.

**So the loss is bounded by the names this session had already taken.** The victim is a
same-UID process that chose to write at one of them, which is the same class of victim
`2026-08-26-reservation-inference.md` accepts: another process of this loop losing a
reservation and taking a retry.

**An arbitrary file of the operator's is not reachable**, and that is a separate
property rather than a restatement. Every one of those names is created under `set -C`
with `umask 077`, so the open is `O_EXCL` and refuses a symlink whether or not its target
exists — a name this session took cannot be made to point somewhere else. That guard is
what makes the table above the whole of it.

## What is NOT accepted here

The origin file the driver reads is a different question: it is about which object was
bound rather than which was removed, and its consequence is a session acting on another
repository rather than a racer losing a file. That is #230, open.
