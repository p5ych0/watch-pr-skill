# Decision: the checkout's authoring tools are not boundaries

**Date:** 2026-09-07
**Status:** accepted
**Decided by:** the repository operator, in session, on the measurement below
**Raised in:** #314

`.claude/hooks/` and `.claude/agents/` run inside the operator's own Claude Code session,
on the operator's own checkout. They exist to make a mistake expensive, not to withstand an
adversary: the pre-push hook runs the self-check before a push, the post-edit hook parses a
shell file that was just written, and the cold reviewer reads a change before a review round
is bought.

## What is accepted

- **A spelling built to evade the hook's match is the session evading its own guard.** The
  match is a text match on the command, with quotes and backslashes removed. A command
  constructed to miss it — through an expansion the hook cannot evaluate, a name assembled
  at run time, an interpreter invoked by another name — is not defended against. This rests
  on the argument `docs/decisions/2026-09-05-driving-shell-trusted.md` already carries: the
  operator owns the session, and a session hostile enough to construct such a spelling can
  edit the hook on disk.
- **The cold reviewer sees what the session sees.** It is a subagent of the same session,
  with the same filesystem. Its brief keeps it away from a path whose name marks it as
  holding secrets, and that is a guard against an accident, not a containment: a copy of
  such a file under another name, a link, an ignored original, all remain readable by the
  session itself whether the subagent reads them or not. **The cost is a disclosure, not a
  wasted round.** A secret reached by one of those routes enters the subagent's transcript,
  which is a real cost the name filter does not bound, and it is accepted here: the session
  that runs the subagent can already read the same bytes, and no filter written in prose
  distinguishes a copy from an original. An operator who needs that bound does not run the
  cold reviewer on a checkout holding live credentials.
- **Neither is installed.** Nothing under `.claude/` ships with the plugin, so a defect
  here costs this checkout a wasted round, never a user of the skill.

## What it cost to learn

Nineteen review rounds on #314, sixteen to thirty-four, narrowed the cold reviewer's brief case by case — rename
endpoints, then copies, then ignored files, then devices and queues, then a missing source,
then the shape of every record those enumerations return. The brief reached ninety-nine
lines, each narrowing one fact behind the next, which is the shape
`CLAUDE.md` § Already paid for names: *do not build a text scanner for shell semantics;
every narrowing was one fact about shell syntax behind*. The brief is twenty-three lines
again.

## What does not change

- The hooks still fail closed on everything they can see: an unreadable envelope, a missing
  or unparseable self-check, a bound outside the deadline, a run the deadline cut short.
  A regression in one of those is a defect, not an accepted limit.
- `test-hooks.sh` stays in the suite and runs on both CI jobs, once #314 lands it; until
  then this record accepts a limit of tools that are not yet on this branch, and if that
  change does not land there is nothing here to accept.
- A finding that names a fail-closed guard going open, in a hook or anywhere else, is still
  a finding whatever this record says.
