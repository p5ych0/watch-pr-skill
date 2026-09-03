# Decision: a hook that runs between the driver's fences owns every value the driver holds, and that is an accepted limit

**Date:** 2026-09-03
**Status:** accepted
**Decided by:** the repository operator, after Codex's round-five review of PR #277
**Closes:** the between-fences half of the #264 review; #264 itself is closed by that PR

`SKILL.md`'s bash runs in the operator's own long-lived shell, one fence per step, and
between two fences that shell returns to a prompt. Anything armed to run there — a
`PROMPT_COMMAND` a startup file installed, a `DEBUG` trap under `extdebug`, a
`RETURN` trap — runs with the driver's variables in scope and can rewrite any of them:
`RB_NONCE` and `RB_NONCE_SEQ`, but equally `CODEX_SHA`, `PRIOR_FILE`, `HEAD_FILE`,
`WHO`, `RB_SCRIPTS`. This record accepts that no value the driver holds ACROSS a fence
boundary is defended against such a hook, and it is what a reviewer should be pointed at
when one is raised again.

## What is accepted

Codex's review of #277 measured three shapes against the request nonce, each correct:

- a hook that resets `RB_NONCE_SEQ=0` between request fences, so every request's counter
  is `1` and, with the external prefix also replaced, every nonce is the same;
- a hook that assigns the previous nonce to `RB_NONCE` and makes it readonly after setup,
  so every clearing and reassignment in the generation block fails in silence and the
  `:?` sees a retained value;
- a hook that reads the nonce back out of the baseline file into `RB_NONCE` between the
  writer's fence and the watch's, so the watch requires whatever the file already holds.

Each has the same premise and the same power: code of the operator's choosing running
in the driving shell between steps, with every variable writable. The same hook rewrites
`CODEX_SHA` before the merge gate, or `WHO` before a round, or `PRIOR_FILE` before the
watch. No value the driver carries from one fence to the next is more exposed than any
other, and none is more exposed than the merge itself.

## Why it is accepted rather than fixed

**What the driver DOES defend, and how far it reaches.** Startup-time state is probed:
every name the block assigns is proved assignable and unset before setup, so a startup
file that made one readonly or transforming stops the session before a request is made.
Computed values are proved by read-back within the fence that computes them: a nonce
source frozen by `unset RANDOM`, a source replaced by a `DEBUG` trap's output, a counter
whose increment did not take — each is measured in `test-pr-skill-contract.sh` and each
is refused. Those defences answer state that exists BEFORE the driver starts and values
that go wrong INSIDE a fence. They cannot answer a hook that acts BETWEEN fences, because
the fence that would check is itself the hook's to rewrite: a probe re-run before every
generation is a statement the hook runs after, and a comparison against a saved value is
a comparison against a name the hook can also set.

**Every defence is one more name.** Rounds one to four of #277 each closed the shape the
previous round measured and each opened the next: `$RANDOM` to a `perl` child, a repeated
constant to a remembered previous nonce, an alternation to a fixed-width prefix with a
counter, a stuck counter to a read-back. `CLAUDE.md` records that chain by name — "each
fix was correct and each introduced the next name" — and its rule for it: prefer removing
the dependency over guarding it. The dependency here is that the driver holds a value
across a fence at all, and it cannot be removed without restructuring the loop so that
no value crosses a step: the request and the watch would have to run in one fence, with
the watch blocking for up to an hour inside it. That is a different driver, not a change
to this one.

**The pin re-derives; the nonce cannot.** The one value the driver holds that IS proved
against a between-fences rewrite is `REVIEW_BUS_REMOTE`, and it is proved by the child
re-reading the checkout's origin — an independent source the hook does not control. A
request nonce has no independent source by definition: its whole content is "this
request and no other", and the only holder of that fact is the shell that made the
request.

## What bounds the limit

A hook in the driving shell is code the operator's own startup files installed, running
as the operator. It is not a same-UID racer on the working directory and not another
account: it is the operator's environment. The loop already trusts that environment's
`PATH`, its `gh` credentials, and its checkout, for the stated reason that nothing inside
a process can distinguish the honest version of something it inherited. This record adds
that the same trust extends to the shell's own variables between steps, and states the
consequence for the nonce: a hook that repeats or re-reads it makes a previous round's
baseline match, and the watch can announce a review nobody requested this round — the
#264 fail-open, reachable only by a hook the operator installed.

## The measurement

`test-pr-skill-contract.sh` pins the limit: two lifted generation blocks run in one child
under a constant-injecting `DEBUG` trap with `RB_NONCE_SEQ=0` re-assigned between them —
the `PROMPT_COMMAND` shape — and the case asserts the two nonces are EQUAL. If a later
change makes them differ, the case fails and this record is revisited rather than
silently outliving the limit it accepts. The three in-fence defences beside it — frozen
source, replaced source, stuck counter — keep their own cases, which assert refusal; this
one is the boundary between them and what is not defended.
