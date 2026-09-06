# CLAUDE.md

Authoring rules for this plugin. `AGENTS.md` restates the subset a review is judged
against, kept in step by hand: a rule changed here that a reviewer applies changes there in
the same PR. Copilot reads only `.github/copilot-instructions.md`, generated from the body
of `AGENTS.md`: edit `AGENTS.md`, run
`.github/build-copilot-instructions.sh > .github/copilot-instructions.md`, commit both. The
contract test refuses a copy that is behind, and the generator prints nothing for a
malformed body, so a refused regeneration leaves an empty file for `git checkout` to
restore. Both reviewer files are read from the PR's base ref, so a pull request cannot
rewrite the rules it is judged by.

## Working rules

**Stack.** bash — 3.2.57 (macOS) and 5 (Linux). Every `pr-*.sh` helper is started
`bash -p` by its caller, with two exceptions the tests pin: `pr-selfcheck.sh`, which
re-execs into a clean shell itself, and `pr-origin.sh`, which is not executable and is
always started by a caller naming the interpreter. Runtime executables: `perl` (hard
requirement), `jq`, `gh`, `git`, GNU or BSD coreutils. No Node, no Python at runtime. Two
reviewers: Codex and Copilot, both GitHub apps; no daemon.

**Structure.** `skills/watch-prs/SKILL.md` drives; `skills/watch-prs/scripts/pr-*.sh` are
the helpers, `*lib.sh` the shared libraries, `test-*.sh` the fixtures; `docs/decisions/`
holds accepted limits; `README.md` is the only document written for a person.

**Naming — for NEW names only.** Established names keep their spelling whatever it is.
Files under `skills/watch-prs/scripts/` are `pr-<stage>.sh`, `<area>lib.sh`,
`test-<area>.sh`; a function a shared library exports `rb_*`, its private implementation
`_rb_*`; a helper's own function a plain name; a driver variable the setup fence assigns
or probes `RB_*`; machine records `PR_<STAGE> status=… reason=…`; decision records
`docs/decisions/YYYY-MM-DD-<slug>.md`.

**Code style.** Match the file: its strict-mode category (§ Bash conventions), its
spellings, its refusal shape. Do not "fix" a script into a stricter mode or a newer idiom
while you are in it for something else.

**Abstractions.** A shared library or a new helper exists only for a rule that was written
more than once and then found missing from a copy — a measured defect. None in
anticipation. No wrapper that only delegates, except an interface wrapper whose public
symbol is the load verification (`rb_write_handoff`/`rb_empty_handoff` delegate to
`_rb_handoff` and are defined last, so a truncated library leaves the public name undefined
for the stub to refuse). Three similar lines beat a premature abstraction.

**Comments.** Default to none. Write one only where the code looks wrong and is not — the
non-obvious WHY, one or two lines, sentence case. Never say WHAT the code does. Never put an
issue number, a review round, a measurement or a history in a comment: those go to
`CHANGELOG.md` where the change is release-bearing, to the commit message and PR body where
it is not, and to `docs/decisions/` where a limit is accepted rather than closed. A comment
that contradicts the code beside it will be followed as an instruction, so a stale comment
is a defect to delete, never prose to preserve. Fixture comments follow the same rule.

**Tests.** Never weaken an existing test to make a change pass: where the behaviour it
covers is meant to stay, a failing test means the change is wrong. A test that encodes a
contract the change intentionally replaces is updated in the same PR, together with the
fixture for the new contract. A behaviour change ships its test in the same PR, and a new
test is proved to fail against the unfixed code for the reason it names. Assert the
invariant, not the version's
route to it, wherever the invariant can be staged; where a required mechanism cannot be
reproduced portably, a source assertion of the mechanism is the check, beside the
behavioural case.

**Scope.** Exactly what was asked. No adjacent improvement, no unbroken refactor, no
unasked feature. A defect found on the way is filed, not fixed — unless this change
introduced it.

**Boundaries.** Validate at this project's boundaries — argv, every file handed across a
process, `gh` and `git` output — and trust a helper's stated contract inside them and the
operator's shell around them (§ Driving shell). What "cannot happen" is decided by
measurement, and where a case is accepted rather than closed, by a record in
`docs/decisions/`; not by intuition in either direction.

**Dependencies.** No new runtime dependency without a measured defect only it removes
(`perl` is the precedent). None where an existing one covers the case.

**Security.** Never commit tokens, credentials or `.env` files. Never echo or log them,
including into records or abort messages. None in fixtures — the suite stubs `gh` and runs
with no credentials, and a test that reaches GitHub is broken.

**Driving shell.** Trusted, per `docs/decisions/2026-09-05-driving-shell-trusted.md`:
`SKILL.md`'s bash runs in the operator's own session and defends against nothing in it. One
invocation per fence, every status acted on, values crossing in files a helper wrote, read
as data and validated, never sourced. No name probe, containment arm, descriptor read, trace
diversion or driver-side nonce bookkeeping; the helpers stay privileged.

**Verification.** `pr-selfcheck.sh` clean before anything is claimed done or pushed. A
failure is fixed first, never worked around and never explained away in prose.

**Communication.** A round summary or a report says what changed, what was skipped (a
past-tense disposition and an issue number, never the unfixed defect), and any judgment
call — in a few sentences. Say what was unexpected.

## What ships

This table locates; it does not specify. Each helper's contract is its fixture,
`test-<area>.sh`, which pins every invariant it carries; the rules a reviewer holds a change
to are in `AGENTS.md`; the argument for each design is in `CHANGELOG.md` and the commit
history; an accepted limit is in `docs/decisions/`.

| Path | Role |
| --- | --- |
| `skills/watch-prs/SKILL.md` | The driver contract, read on every invocation: one helper invocation per step, statuses in prose, an **Unattended:** answer at each decision stop. |
| `scripts/pr-setup.sh` | Session start: the reservation, the origin, the four working files, the mode. |
| `scripts/pr-request-review.sh` | The opening Codex request, and the baseline the watch is given. |
| `scripts/pr-review-state.sh` | A reviewer's verdict on a head, and the replies-only escape. |
| `scripts/pr-merge-range.sh` | Whether every commit since the reviewed sha is a Copilot-phase fix. |
| `scripts/pr-findings.sh` | The unresolved findings, and a blocking review's body. |
| `scripts/pr-round-count.sh` | Rounds per reviewer, the check-in boundary, the acknowledgements. |
| `scripts/pr-signoff.sh` | The recorded signoffs and revocations, ordered. |
| `scripts/pr-ci-state.sh` | A head's checks, and the base branch's required set. |
| `scripts/pr-ci-gate.sh` | Waits for the pushed head's checks. |
| `scripts/pr-close-round.sh` | `gate` and `post`, with the thread replies between them. |
| `scripts/pr-copilot-phase.sh` | `record`, `open` and `close`. |
| `scripts/pr-merge-gate.sh` | Every merge gate, then the merge pinned to one head. |
| `scripts/pr-watch.sh` | Blocks until a reviewer's verdict is actionable. |
| `scripts/pr-origin.sh` | Reads and pins the checkout's origin; not executable, started by an interpreter named by its caller. |
| `scripts/pr-phase-state.sh` | Which phase a PR is in, from its own records. |
| `scripts/pr-selfcheck.sh` | The pre-push check; re-execs into a clean shell; the one helper not started privileged. |
| `scripts/recordlib.sh` | What a well-formed GitHub record is, and what a review request is. |
| `scripts/writelib.sh` | How a value crosses in a caller-named file. |
| `scripts/clocklib.sh` | One clock reader, so a fixture can own time. |
| `scripts/identitylib.sh` | Which repository this checkout is: `rb_identity`, one definition. |
| `scripts/loadlib.sh` | How a library is loaded and proven loaded. |
| `scripts/testlib.sh` | The portable watchdog and the validated scratch directory; ships at runtime inside `pr-ci-state.sh`. |
| `scripts/test-*.sh` | The suite, one file per helper and per library. |
| `.claude-plugin/` | Plugin and marketplace manifests. |

`scripts/` is `skills/watch-prs/scripts/`; the other paths are as written. Everything else
is documentation.

## The helpers are started privileged

- Every `pr-*.sh` except `pr-selfcheck.sh` and `pr-origin.sh` begins
  `#!/usr/bin/env -S bash -p` and refuses if `$-` lacks `p`. Privileged mode sources no
  startup file, imports no function and ignores `SHELLOPTS`, so no builtin a helper uses is
  a name the environment can replace.
- **The caller supplies it**: `SKILL.md` and every helper that calls another invoke
  `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-x.sh`, never a bare name, since a bare call leaves
  the shebang to the kernel and needs an `env -S` some platforms lack. The suite runs
  helpers directly and so needs `env -S` (GNU coreutils 8.30 or later, or BSD).
- `$-` is a last resort: it reports the mode, not how the shell got there. `bash pr-x.sh`
  is unsupported rather than defended; do not add a check that claims otherwise.
- `pr-origin.sh` is not executable, so a shebang would state a protection it cannot
  enforce; `test-pr-identity.sh` asserts both exceptions.
- A fixture that sources a helper needs `bash -p -c`, since `$-` when sourced is the
  caller's.
- **A poisoned `PATH` is settled**: nothing inside a process can distinguish the honest
  version of something it inherited, `command -p` holds neither `git` nor `gh`, and a
  `PATH` check in one helper is a defect, not a fix (#91).

## Bash conventions

| Mode | Scripts | Why |
| --- | --- | --- |
| `set -euo pipefail` | one-shot commands | abort on the first failed step |
| `set -uo pipefail` | every `pr-*.sh`, `pr-selfcheck.sh` included | **`-e` is forbidden**: statuses are control flow, `gh` probes fail as normal operation, and a `grep` matching nothing exits 1 as its answer |

- **An intentional no-op branch uses `return 0`**: a bare `return` inherits the failed
  test's status. Enforced by review, deliberately — six structural checkers were each
  defeated by legal bash. Read every `return` in a diff.
- **Every fetch, parse and diff step fails closed.** A failure is never indistinguishable
  from "no findings", "clean" or "zero unresolved": propagate a non-zero status where the
  caller branches, emit a distinguished sentinel where it reads stdout.
- **Anything a `gh` call prints before failing is not data**: check the status and the
  shape.

### Already paid for

Each of these was found, fixed and made again. Read before writing a defence or a fixture.

- **A list of names is wrong by omission.** Enumerate everything, or change the shape so no
  list is needed.
- **A defence written for a shell means nothing where no shell runs**: `xargs` execs its
  program.
- **Assert the concrete outcome, and keep absence checks beside it**: "not clean" alone has
  passed against a hang, a malformed record and a crash; a run that emits the right sentinel
  and a stray `status=clean` is caught only by the absence check.
- **A forger in a fixture is narrow and otherwise works**: one that forges every call breaks
  the harness, one that produces a malformed result is rejected by a different check.
- **Combine states.** Two harmless states together can skip a guard; separate cases cannot
  see it.
- **"Bash rejects this spelling" is a fact about a parser, not about every route into a
  process**: `function 'a*b'` is rejected and `env 'BASH_FUNC_a*b%%=…'` is imported.
- **An assignment's status cannot be taken**: a failed readonly assignment written as
  `VAR=value || abort` does not fire the `||`. Prove an assignment by reading the variable
  back.
- **A stale comment is followed as an instruction.** Delete a comment whose argument has
  moved on; do not extend it.
- **Never pipe a value into a reader that exits early.** `printf … | grep -q` is racy under
  `pipefail`: use a herestring, and where the value comes from a command capture it and its
  status first, emptying it on failure. `pr-selfcheck.sh` gates the `printf` form by three
  substring questions and parses nothing; a line carrying the spelling as data says
  `racy-pipeline-ok`. Any other producer is review's job, since telling a pipe from `||` or
  a `case` pattern needs a shell parser.
- **Do not build a text scanner** for shell semantics. One cost 2,200 lines and fifty-two
  rounds; every narrowing was one fact about shell syntax behind. Pin by running.

## Repo-agnostic invariant

- No hard-coded owner, repository or branch in the scripts or `SKILL.md`: the same installed
  copy serves every project.
- **No repository but this one is named anywhere, prose included.** A measurement taken
  elsewhere is evidence for its count and shape, never for whose repository it was. Not
  mentions: this plugin's own metadata and install commands, a dependency coordinate such as
  `uses: actions/checkout@v4`, an API path in its generic form, and the placeholder identity
  a fixture supplies as a value — the suite uses one placeholder pair throughout, keyed by
  `test-pr-identity.sh` on the owner and the shape, and this paragraph does not spell it.
- Identity derives from `git remote get-url origin` in one place, `rb_identity` in
  `identitylib.sh`, which sets `HOST`, `OWNER` and `REPO` rather than printing them.
  `REVIEW_BUS_REMOTE`, `REVIEW_BUS_OWNER` and `REVIEW_BUS_REPO` override it; `SKILL.md`
  exports `REVIEW_BUS_REMOTE` once at setup to pin the session, so a `cd` retargets nothing.
  A second copy of the parser is a defect, and the contract test fails if `SKILL.md` grows
  one.

## Tests

- One `test-<area>.sh` per `pr-*.sh` and per library; `pr-selfcheck.sh` enforces it.
- **A rule that applies to more than one helper lives in a shared library.** `recordlib.sh`
  holds record shapes, `identitylib.sh` identity, `writelib.sh` handoffs, `loadlib.sh`
  loading; each exists because a copy was found missing. `test-recordlib.sh` carries a drift
  guard against an inline re-implementation.
- **Runtime scripts load libraries through `rb_load`**, which takes the kind and the
  caller's error prefix. The lines loading `loadlib.sh` itself are clear, take the clear's
  status, define a refusing stub, source: the first load is the verification. Two exceptions
  source `writelib.sh` directly in a `bash -p -c` child, each behind a refusing stub, since
  `run_limited` bounds a command and the loader is a function in the parent. `SKILL.md`
  sources `identitylib.sh` by hand, since the loader lives where it has yet to look.
- **Runtime is hardened; fixtures are not.** `pr-selfcheck.sh` re-execs into a clean shell,
  clears every inherited function and refuses if one cannot be cleared, so a shadowable name
  in a `test-*.sh` is not a finding. Three limits: CI runs `bash "$t"` on a runner clean by
  construction; the gate clears functions and hook variables, not exported values, so a
  fixture whose subject is an env override clears it itself; that clearing cannot live in
  `testlib.sh`, which ships at runtime.
- Self-contained: throwaway repositories under the validated scratch helper, `gh` stubbed,
  no network.
- **Portable, proved by running.** Both CI jobs run on every push to `main` and every pull
  request. The `macos-shell` job runs the suite on bash 3.2.57 with a `PATH` built from what
  a Mac has, so a post-3.2 construct or a GNU-only tool on an executed path fails there; GNU-only flags, `\s` in a `grep` pattern and unexecuted
  branches are review's job, tabled in the reviewer files. **Assert the invariant, not the
  version's route to it**: attack fixtures differ in route between bash 5 and 3.2.57 while
  the defence holds on both. Pin the inner interpreters, not only the outer shell.
- `SKILL.md`'s bash is covered only where `test-pr-skill-contract.sh` lifts it: the setup
  fence against the real helper and stub setups, the head-proof and signoff-read fences
  against staged files. The rest of the document is pinned by text, and no Markdown parser
  is built for it.
- Every behaviour change ships its test in the same PR, proved to fail against the unfixed
  code for the reason it names.
- Run the suite as CI does:

  ```bash
  cd skills/watch-prs/scripts
  fail=0; for t in test-*.sh; do bash "$t" || { echo "FAIL $t"; fail=1; }; done; exit $fail
  ```

  `pr-selfcheck.sh` runs the files four at a time (`RB_SUITE_JOBS`), since they are
  independent; CI keeps the loop for its per-file grouping.
- **A shadowed `type` inside `rb_load` is accepted** (#96): the loader has nothing to fall
  back on, and calling the symbol would run it.

## Documentation sync

Three layers, one reader each, and a behaviour change updates the ones that describe it:
`SKILL.md` for the driving model, `AGENTS.md` for the reviewers (the Copilot copy is
generated from it), `README.md` for the person. Script comments are not a layer. A
user-visible change with no `README.md` update is incomplete.

## Release

Bump `version` in `.claude-plugin/plugin.json` and add a `CHANGELOG.md` entry in the same
PR whenever an installed file changes — the scripts, `SKILL.md`, the manifests. A change
confined to `test-*.sh`, to authoring documentation, or to the reviewer files bumps nothing:
the reviewer files are read from the base ref and nothing installs them.

**The size of the bump.** MINOR (x.Y.0) only for a new capability: a switch, a command, a
stop, a knob an operator did not have before. PATCH (x.y.Z) for everything else — a fix,
however visible, a tightening, a compression, a comment or a prose change. A fix is a patch
even when the loop behaves differently afterwards; "behaves differently" is not "can do
something new".

The entry explains the failure fixed and how it manifested, or, for a text-only change,
what the text now records and which misreading it prevents. A comment-only change to an
installed script is a release, because the installed bytes changed and a comment there is
followed as an instruction.

## One change per pull request

A PR closes one issue, with the smallest change that closes it: no opportunistic hardening,
no generalising, no second concern because the file is open. An unrelated or pre-existing
defect found mid-work is filed. A defect this PR or one of its review fixes introduced is
this round's work. Split complex work into sequential sub-issues; a helper change a fix
needs lands first as its own PR.

## One change per review round

- Fix what the finding names, and nothing else; a broader change is an issue and a line in
  the round summary.
- Prefer removing the dependency over guarding it, and say on the thread which was taken and
  why.
- Read the thread and the previous round's diff before writing.
- The fault-tolerance pass runs only if the Copilot phase produced commits, once, and is
  bound by every rule above; its own commits do not restart the cycle.

## Stating the task

- The PR body states what the change sets out to do; the reviewers judge relevance against
  it.
- Every round summary states what was addressed and what was skipped as a past-tense
  disposition with a bare issue number, never a description of the unfixed defect: the
  summary shares a comment with the review request, and a mention describing work to be done
  is read as a work order.
- Neither can waive a finding. An accepted limitation is a dated record in
  `docs/decisions/`, landed on the base ref by its own PR, resting on a fixture that fails if
  the bound moves, and named in both reviewer files — the contract test derives that
  requirement from the directory, skipping superseded records. Accept a limitation only after
  its cost is measured and its fix priced, never as the first answer to a defect.

## Repo arming

`.claude/settings.json` enables this plugin for the checkout and is committed. The Codex
connector is account-level (`chatgpt.com/codex/cloud/settings/connectors`); per-repository
review behaviour lives on the Codex **Code review** settings page.
