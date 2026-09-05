# Decision: the driving shell is trusted

**Date:** 2026-09-05
**Status:** accepted
**Decided by:** the repository operator, in session, on the measurement below
**Raised in:** #305

`SKILL.md`'s bash runs in the operator's own session, and it defends against nothing in
that session. No probe for a readonly or transforming name, no containment arm after an
`exit`, no value read through a held descriptor, no trace diversion, no nonce bookkeeping
on the driver's own account. One invocation per step, every status acted on, values
crossing in files a helper wrote.

## What is accepted

A startup file, an exported function, a readonly or nameref name, or a traced descriptor
in the driving shell can misdirect the driver: make it skip a step, stop, or read a value
wrongly. That is accepted, because it is bounded:

- every gate, and every mutation but two, runs inside a privileged helper, started by
  path under `/usr/bin/env bash -p` (`pr-selfcheck.sh` excepted, which is run directly and
  re-execs into a clean shell itself), against GitHub's own records. The two the driver
  posts itself are the reaction on a finding, a signal to the reviewer that nothing reads,
  and the check-in acknowledgement, a control record `pr-round-count.sh` honours: forged,
  it costs the operator a skipped check-in and nothing a gate refuses, since the round
  boundary is the one gate that reads it. A misdirected driver can stop a loop or skip a
  check-in; it cannot make a helper merge what the helper refuses;
- the operator owns the session. A shell hostile enough to redefine `exit` can edit the
  helpers on disk or alias `gh`. The defences protected against an adversary who owns the
  shell but not the filesystem, which is nobody;
- what a defence caught in practice was an accident — a `cat` alias, a readonly `IFS` —
  and an accident fails loudly as an abort or a helper refusal.

## What it cost

| | before |
| --- | --- |
| `SKILL.md` | 880 lines, 320 of them in fences, 138 in the setup block alone |
| fence lines that are hostile-shell defence | 92 |
| `test-pr-skill-contract.sh` | 6,418 lines, most of them lifting fences to run against readonly names, namerefs, a shadowed `exit`, a neutralised `echo` and a forged helper |

Each defence was built across review rounds, and each introduced the next name to defend.
The document is read on every invocation.

## What does not change

- The helpers stay privileged, and every helper is still started by path under
  `/usr/bin/env bash -p`, `pr-selfcheck.sh` excepted as before: it costs nothing and the
  fixtures pin it.
- A poisoned `PATH` stays settled as it was (#91).
- The head, the baseline and the signoff sha still cross in files written through
  `writelib.sh` on the helper's side, and the origin in a directory `pr-setup.sh` created
  exclusively, because that is the shape a child and its parent can share; the driver
  reads them plainly.

## What remains a finding in `SKILL.md`

A helper invoked by name rather than by path, `pr-selfcheck.sh` excepted; a status not
acted on; a value cut out of a record where a file carries it, or a handoff file sourced
rather than read as data and validated; a step out of order; a request, summary or phase
body posted with a reserved marker or a mention — the check-in acknowledgement is the one
body the driver writes with a marker on purpose.

## Supersedes

`docs/decisions/2026-09-03-driver-state-rewritten-by-hooks.md`, which accepted that a hook
between the driver's statements owns every value the driver holds while describing the
startup probes and read-backs as retained: this record trusts the whole shell, hooks
included, so that limit is subsumed and those defences go with #306. The driver-side rules
in `AGENTS.md` § The driving shell and the "yes in `SKILL.md`'s own bash" clause of
§ Shadowable names, both rewritten in #305. And, as history, `CLAUDE.md`'s accounts of the
driver defences built under #102, #178, #181 and #183, which #306 removes from the document.

**Pinned by:** `test-pr-skill-contract.sh` after #306, which asserts that each fence in
`SKILL.md` is one invocation and that no hostile-shell shape is left in the document.
