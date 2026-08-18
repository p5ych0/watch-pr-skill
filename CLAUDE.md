# CLAUDE.md

This file owns the **authoring** rules for this plugin: how to write changes
here. It is the single source for them, and the other instruction files cite it
rather than restating it.

Review policy lives in `AGENTS.md`, which Codex reads natively — including in its
GitHub PR review. Copilot's copy is `.github/copilot-instructions.md`; it
restates the policy inline because Copilot reads only that file and does not
follow pointers. That restatement is the one deliberate duplicate in this
repository. Both are read from the PR's **base ref** by the reviewers, so a pull
request cannot rewrite the rules it is judged by.

## What ships

| Path | Role |
| --- | --- |
| `skills/watch-prs/SKILL.md` | The driver contract — how the model requests reviews from the native GitHub reviewers, reads findings, closes rounds, and gates the merge. |
| `skills/watch-prs/scripts/pr-review-state.sh` | Whether a named reviewer's review of the current head can carry a merge. EVERY comment counts as a finding, replies included: a verdict followed by explanation and a verdict followed by a retraction are the same text to anything that reads it, so no exemption is safe. A review whose comments are ALL replies reports `source=replies-only` — nothing to fix and not a signoff — and the driver stops for the operator. |
| `skills/watch-prs/scripts/pr-merge-range.sh` | Whether every commit since the reviewed SHA is a review-fix commit reachable from it. |
| `skills/watch-prs/scripts/pr-findings.sh` | The unresolved findings, paginated and shape-validated, and the body of a blocking review. |
| `skills/watch-prs/scripts/pr-round-count.sh` | How many rounds this PR has had, and whether this is an operator check-in boundary. |
| `skills/watch-prs/scripts/pr-signoff.sh` | Which head a reviewer has signed off clean on, read back from the PR itself. The record is a comment, so it survives the session that made it. |
| `skills/watch-prs/scripts/pr-ci-state.sh` | Whether the pushed head's checks are green, still running, failing, or absent. |
| `skills/watch-prs/scripts/pr-ci-gate.sh` | Waits until those checks have settled on the head just pushed, and says whether the round may close. Was a function in `SKILL.md`, where nothing could test it — see #26. |
| `skills/watch-prs/scripts/pr-close-round.sh` | Closes a review round in two stages with the thread replies between them: `gate` pushes and proves the head green, `post` re-proves that head, posts the summary and requests the next pass. Both orderings — the mention as trigger, and the push as trigger — in one place. 0 gated/closed, 1 stopped, 3 paused. Was 247 lines in `SKILL.md` — see #26. |
| `skills/watch-prs/scripts/pr-copilot-phase.sh` | The Copilot phase end to end, in three stages with the operator's decision between them: `record` proves Codex clean on an exact head, proves that head's checks and writes the signoff onto the PR, then stops and asks; `open` runs only on the answer, and proves the phase is STILL open before it touches anything: the head is unmoved, Codex's live verdict on that sha is clean, and the recorded Codex signoff still names it — a revocation is how a phase is deliberately reopened, and GitHub serves the old clean verdict until the new pass reports. It re-enforces the round boundary too, because `record` publishes the signoff before pausing and a later session can resume straight into here; that is why `open` can return 3. All of it runs THREE times — up front, before the revocation, and again after it — because none of these need the head to move and the revocation is itself a mutation with the request still to come. The order is revoke, prove, baseline, request: the proof as late as it can be while the Copilot baseline stays last, which it must be or a pass landing meanwhile answers a request made after it. `close` is the other end: Copilot's verdict came back clean, so the second signoff is written down and the operator is asked what to do with two closed phases. It takes the Codex head as well as reading the current one, because whether those two shas are EQUAL is what decides which question gets asked — the fault-tolerance pass is offered only where the phase produced commits. It takes the reviewers mode too, since `codex-only` means no Copilot review was ever requested and there is nothing to record; saying so is not the same as skipping it. 0 recorded/opened/closed, 1 stopped, 3 paused. Every guard in it is a reserved-word test, not `[`: the stage dispatch decides which of three mutations runs, and the head-equality and verdict-status proofs decide whether a signoff is recorded at all — see #81. Was 176 lines in `SKILL.md`, and `close` a further 93 whose aborts all exited 0 — see #26, #78. |
| `skills/watch-prs/scripts/pr-merge-gate.sh` | Every merge gate, evaluated immediately before merging and pinned to the head it checked. Takes a reviewers mode: `both`, or `codex-only` which requires the head to BE the reviewed commit. 0 merged, 1 blocked, 3 paused for the operator, 4 queued — a merge queue takes the request without landing it, and `gh` calls that success. Was 291 lines in `SKILL.md` — see #26. |
| `skills/watch-prs/scripts/pr-watch.sh` | Blocks until a reviewer's verdict on the current head is actionable. 0 verdict in hand, 1 timed out, 2 unreadable, **4 the review carried only replies** — nothing to fix and no signoff, so the driver stops for the operator. That one has its own status because every caller branches on status: saying it in the record alone left `pr-close-round.sh` taking the 0 and closing the round. |
| `skills/watch-prs/scripts/pr-selfcheck.sh` | The pre-push check over this plugin's own sources. The one helper NOT started privileged — see § The helpers are started privileged. |
| `skills/watch-prs/scripts/recordlib.sh` | What a well-formed GitHub record is, which lines a reader honours as a control record, and what text requests a review — one definition each, sourced by every helper that reads the API or posts a caller-written body. |
| `skills/watch-prs/scripts/clocklib.sh` | What "how much time has passed" means — one clock reader, with the guards a bare read has not got, sourced by `pr-watch.sh` and `pr-ci-gate.sh`. It exists because the gate used `$SECONDS`, a builtin no fixture can reach, so every deadline case in its suite raced real time; `date` is a command, so a fixture owns it. See #66. |
| `skills/watch-prs/scripts/identitylib.sh` | Which repository this checkout is — one definition, sourced by every helper and by `SKILL.md`. |
| `skills/watch-prs/scripts/loadlib.sh` | How a shared library is loaded and proven loaded — clear, source, verify — in one place. |
| `skills/watch-prs/scripts/testlib.sh` | The portable watchdog and the validated scratch directory. Every fixture runs under it, and `pr-ci-state.sh` bounds its `gh` calls with it — so it ships at runtime too, not only in the suite. |
| `skills/watch-prs/scripts/test-*.sh` | The suite. |
| `.claude-plugin/` | Plugin and marketplace manifests. |

Everything else is documentation. **v2 runs no reviewer of its own**: Codex and
Copilot are first-party GitHub apps, so there is no watcher, no response
monitor, no bus directory, and no systemd unit.

## The helpers are started privileged

Every `pr-*.sh` except `pr-selfcheck.sh` begins `#!/usr/bin/env -S bash -p`, and
refuses if `$-` does not contain `p`.

**This is the answer to a whole class, and it replaces answering it one name at a
time.** An ordinary `#!/usr/bin/env bash` SOURCES `BASH_ENV`, IMPORTS functions
from the environment, and honours an exported `SHELLOPTS` — so every builtin a
helper uses is a name the operator's shell can replace. Found one per review
round before this: `type` said a good library defined nothing; `return` made a
refusing stub succeed; `set` made `set +e` a no-op; `echo` swallowed a structured
sentinel; `exit` made a refusal non-terminal, so a helper announced an abort and
went on to post. Each fix was correct and each introduced the next name.
Privileged mode does none of the three things, so there is nothing to shadow.

- **The shebang, not a re-exec.** A `BASH_ENV` hook runs before the script's first
  line; one that prints a forged `PR_X …` line and exits has already answered a
  caller capturing stdout, and no later re-exec takes that back. The interpreter
  has to be privileged from the start, which only the shebang or the caller can
  arrange.
- **`$-` is the guard, and it is not redundant.** An `env` without `-S` fails
  loudly, but `bash pr-x.sh` skips the shebang entirely; without the guard that is
  a silent downgrade to an unprotected shell.
- **`pr-selfcheck.sh` is exempt, deliberately.** It is run by a person rather than
  by the driver, and it already re-execs into a clean shell and clears every
  inherited function — the guarantee it makes for the whole suite.
  `test-pr-identity.sh` asserts the exemption as well as the rule, so neither can
  drift silently.
- **A fixture that sources a helper needs `bash -p -c`.** When sourced, `$-` is
  the *caller's* flags, so an unprivileged shell is refused — which is correct,
  because the library half would otherwise run somewhere a hook can reach.
- **What it does NOT cover**: `SKILL.md`'s own bash, which runs in the operator's
  shell and cannot re-exec itself, so the driver keeps every name it has (#102);
  and a poisoned `PATH`, which is #91.

## Bash conventions

Strict mode is chosen per script category, not applied uniformly. Match the
category; do not "fix" a script into a stricter mode.

| Mode | Scripts | Why |
| --- | --- | --- |
| `set -euo pipefail` | one-shot commands | Abort on the first failed step. |
| `set -uo pipefail` | `pr-review-state.sh`, `pr-merge-range.sh`, `pr-round-count.sh`, `pr-findings.sh`, `pr-watch.sh`, `pr-ci-state.sh`, `pr-ci-gate.sh`, `pr-merge-gate.sh`, `pr-signoff.sh`, `pr-close-round.sh`, `pr-copilot-phase.sh`, `pr-selfcheck.sh` | **`-e` is forbidden here.** Subcommands use exit codes as control flow and several `gh` probes "fail" as normal operation; `pr-selfcheck.sh` is in this row because a `grep` that matches nothing exits 1 as its normal answer. |

- **Intentional no-op branches use an explicit `return 0`.** A bare `return`
  after a failed test inherits that test's exit status 1; under strict mode with
  an unguarded caller that terminates the script.

  **This one is enforced by review, not by a test, and deliberately so.** A
  structural "no bare returns anywhere" check was built and removed: six
  successive versions were each defeated by legal Bash — `{ ...; return; }`,
  `|| return # why`, a `#` inside a quoted string, `return >/dev/null`,
  `return 2>/dev/null` (the `2` is an IO number, not an argument),
  `return {fd}>/dev/null`, and a `return` inside a `$( )`, which executes even
  within double quotes. Each version reported PASS while its stated invariant was
  false, which is worse than no check: it converts an unverified assumption into
  a green tick. So when reviewing a diff here, read every `return` and check it
  states a value.
- **Every fetch, parse, and diff step must fail closed.** The invariant is about
  the *outcome*: a failure must never be indistinguishable from "no findings",
  "clean", or "zero unresolved". Propagate a non-zero status where the caller
  branches on it; emit a distinguished sentinel where the caller consumes stdout,
  since a non-zero exit would be swallowed while empty output looked like a valid
  answer. What is a violation is any path where a failure yields an
  ordinary-looking value.
- **Anything a `gh` call prints before failing is not data.** Command
  substitution keeps it, so a call that emitted a plausible SHA and then errored
  reads as success unless the status is checked and the shape validated.

### Already paid for

Each of these was found, fixed, and then made again in a later round of the same
pull request. Read it before writing a defence or a fixture; it is cheaper than
rediscovering them.

- **A shell function shadows any name** — external, builtin, or the `command` and
  `builtin` prefixes used to bypass one. Prefer a **reserved word** (`[[`, `if`)
  or an **assignment**: the parser handles those and no function can take their
  place. A postcondition cannot be written with the thing it checks for, and two
  checks behind one prefix are one check.
- **A list of names is wrong by omission.** Clearing "the names the verdict
  depends on" missed `read` and `[`. Enumerate everything, or change the shape so
  no list is needed.
- **A defence written for a shell means nothing where no shell runs.** `xargs`
  execs its program, so `command env …` asks for a program *called* `command` —
  which exists on some machines and not on CI.
- **The startup hook runs before the script does**, and only some of what it
  leaves can be undone from inside. A `readonly IFS` or a `readonly -f` function
  cannot: re-exec with `BASH_ENV` and `ENV` removed instead, and guard that
  re-exec with a marker rather than with the evidence, since the hook can `unset
  BASH_ENV` on its way out. Inherited tracing CAN be undone — `set +x`, after
  clearing any shadowing function — so it needs no re-exec of its own, and neither
  does a plain `IFS=`, which another assignment answers. Reaching for the re-exec
  where a one-line fix exists is the over-building this section is here to stop. The hook can also erase the
  evidence that it ran, so guard that re-exec with a marker rather than with the
  evidence — and clear the marker, or every child inherits it.
- **Assert the concrete outcome, and keep absence checks as well as — never
  instead of — that.** "Not clean" alone has passed against a hang, a malformed
  record and a crash. But where forbidden output is part of the contract, its
  absence still has to be asserted: a run that emits the right error sentinel AND
  a stray `status=clean` has violated fail-closed, and only the absence check
  sees it.
- **A forger in a fixture must be narrow and must otherwise work.** One that
  forges every call breaks the harness; one that produces a malformed result is
  rejected by a different check, and the case then passes either way.
- **Combine states.** A readonly helper is harmless; a shadowed `[` is harmless;
  together they skip a re-exec. Separate cases cannot see it.
- **"Bash rejects this spelling" is a fact about a parser; "this cannot be
  inherited" is a claim about every route into the process.** `function 'a*b'` is
  rejected and `env 'BASH_FUNC_a*b%%=…'` is imported. Never remove a guard on the
  strength of one route.
- **A comment that argues against the code beside it is an instruction**, and it
  will be followed.

## Repo-agnostic invariant

- No hard-coded owner, repo, or branch name in the scripts or in `SKILL.md`. The
  same installed copy serves every project, so a literal identity there would
  leak one project's state into another's.
- It does **not** cover this repository's own metadata or its installation
  documentation. `.claude-plugin/` and the install commands in `README.md`
  necessarily name `p5ych0/watch-pr-skill` — that is this plugin's own identity.
- Identity derives from `git remote get-url origin`, in **one place**:
  `rb_identity` in `identitylib.sh`, which every helper and `SKILL.md` sources.
  It sets `HOST`, `OWNER` and `REPO` rather than printing them — serialising three
  values through one string makes any delimiter a value a remote can contain, and
  a remote carrying it shifts the fields, which is the wrong-repository failure
  the parser exists to prevent. `REVIEW_BUS_REMOTE`, `REVIEW_BUS_OWNER`, and
  `REVIEW_BUS_REPO` override it — the caller stating the identity rather than the
  library deriving it. Tests use that to supply an identity without a real remote;
  `SKILL.md` uses it to **pin the session**, exporting `REVIEW_BUS_REMOTE` once at
  setup from a status-checked `git remote get-url origin`. Every helper runs
  `rb_identity` in its own process against the current directory, so without the
  pin a `cd` into a second checkout retargeted every stage that posts — a signoff,
  a revocation, a review request — at whatever PR of that repository shared the
  number. Wrapping each call in `(cd "$REPO_DIR" && …)` was tried and is a guard
  rather than a removal: `cd` is a name, and a list of call sites is missing the
  next one. `$REPO_DIR` survives for `pr-merge-range.sh`, which inspects history —
  a tree, not an identity. `test-identitylib.sh` proves the parser's rules; `test-pr-identity.sh`
  proves every caller is wired to it and scans the scripts, the libraries and
  `SKILL.md` for a hard-coded identity.
- **A second copy of the parser is a defect, not a convenience.** It lived in
  four files, both the hostless-origin and file-transport rules had to be written
  into all four, and the fixtures proving them had to be built a second time to
  cover the copies that had silently missed one. The contract test fails if
  `SKILL.md` grows its own copy back.

## Tests

- One `skills/watch-prs/scripts/test-<area>.sh` per area. `pr-selfcheck.sh`
  enforces this for every `pr-*.sh` **and for the sourced libraries** — a shared
  definition is the highest-leverage file in the tree, so it cannot be the
  untested one.

- **A rule that applies to more than one helper lives in a shared library, not
  in each of them.** `recordlib.sh` holds what a well-formed API record is;
  `identitylib.sh` holds which repository this checkout is; `loadlib.sh` holds how
  a library is loaded at all. Each exists because the rule was written out three
  or four times and then found missing from at least one copy.

  Every field check in `recordlib.sh` was originally written out in two or three
  scripts, and every one of them was found missing from at least one — the known
  review-state set reached two helpers and sat missing from the third for eleven
  review rounds, where an unrecognised value was reported as a *withdrawn review*.
  `test-recordlib.sh` carries a drift guard that fails if a helper re-implements a
  rule inline; when you need a new field check, add it there.

- **Runtime scripts load libraries through `rb_load`, never by hand.** Clearing an inherited
  symbol, taking the *clearing's* status, and verifying the library defined
  anything were each added after a copy was found missing them. `rb_load` takes
  the KIND, because a variable and a function need different clears and different
  verifications, and an exported value satisfies a `[ -n … ]` test exactly as an
  exported function satisfies `type -t`. It takes the caller's whole error prefix
  too: `pr-watch.sh` says `state=error` where the others say `status=error`. The
  four lines that load `loadlib.sh` itself are the one thing that cannot use it —
  and they still clear, source and verify, because a stale loader is what makes
  every other load look clean. `test-pr-identity.sh` fails if a `pr-*.sh` script
  loads a library by hand.

  **`SKILL.md` is the exception, and it is deliberate.** Its bash runs in the
  driving session's own shell and aborts with prose rather than a
  `PR_X status=error` line, so it does not share the callers' contract — and
  `rb_load` lives in a directory the driver has to locate before it can source
  anything at all. It clears, sources and verifies `identitylib.sh` by hand, and
  `test-pr-skill-contract.sh` requires that block and executes it against a
  readonly definition and an empty library. Do not "fix" it into a `rb_load`
  call.
- **The shadowed-command boundary runs between the runtime scripts and the
  fixtures, and `pr-selfcheck.sh` is what draws it.** This is the settled answer
  to #76, and it exists so that a reviewer flagging a shadowable name inside a
  fixture has one to point at.

  **Runtime is hardened; the fixtures are not.** `SKILL.md` and the `pr-*.sh`
  helpers run in the operator's own shell, which nothing controls — a startup
  file, an exported function, whatever the environment carries — so a name they
  depend on is load-bearing, and reserved words (`[[`, `if`), assignments and
  expansions are the answer there. The fixtures run under `pr-selfcheck.sh`,
  which re-execs into a clean shell with `BASH_ENV`, `ENV`, `SHELLOPTS` and
  `BASH_XTRACEFD` removed, clears every inherited function, and refuses to
  continue if one cannot be cleared. That guarantee is made once, in one file,
  with its own test.

  Hardening the fixtures too was considered and refused: **every fixture in the
  tree contains at least one** of `local`, `awk`, `[`, `read`, `cat`, `mktemp`,
  `grep`, `sort`, `jq` and `timeout`, each of them a name, and doing it a finding
  at a time is the unbounded list this file already warns about — a second, worse
  copy of a guarantee the gate makes properly. No count is given on purpose: one
  would go stale with the next fixture, which is the same defect at a smaller
  scale. Nor is the claim that every name appears everywhere — `timeout` is in
  twelve of them — because that would be a second overclaim in the same sentence. **So a shadowable name in a `test-*.sh` is
  not a finding.** In a runtime script it is.

  **Three limits, because the guarantee is the gate's and not the file's:**

  - a fixture run **directly** — `bash test-pr-watch.sh` — has no clean shell.
    The gate is what makes the guarantee, and **CI is that path**: both jobs in
    `.github/workflows/tests.yml` loop over `bash "$t"` rather than going through
    `pr-selfcheck.sh`, so what protects them is the runner's environment being
    clean by construction, not the re-exec. The exemption is about where a
    reviewer should spend a finding, and it survives that — a hostile shell is
    an operator's machine, not a fresh container — but it is the gate and the
    runner that carry it, never the fixture;
  - the gate clears inherited **functions** and the hook variables. It does not
    clear arbitrary exported values, and it must not: `SKILL.md` pins the
    session's repository by exporting `REVIEW_BUS_REMOTE`, and the suite runs at
    step 5a with that pin in the environment. A fixture whose subject is an
    env-driven override therefore clears it **itself** — `test-pr-identity.sh`
    and `test-pr-skill-contract.sh` do, and both were red without it;
  - that clearing cannot live in a shared library. `testlib.sh` looks like the
    right place and is not: it **ships at runtime** inside `pr-ci-state.sh`,
    where an `unset` would wipe the pin the driver just set. It was written there
    first, and `test-pr-ci-state.sh` caught it.

- Self-contained: throwaway git repos under `mktemp -d`, `gh` stubbed, no
  network. CI has no credentials, so a test that reaches GitHub is a broken test.
- **Portable, and proven by running rather than by reading.** The `macos-shell` CI
  job runs the whole suite on a bash 3.2.57 built from source and first on `PATH`,
  with the GNU-only tools removed. Post-3.2 constructs fail there, and so do the
  differences in PARSING that no feature list contains — an inline `[[ … =~ … ]]`
  pattern with a parenthesis is a syntax error on 3.2, and `pr-watch.sh` carried
  one from the day it was written. Absence covers the other half: a command name
  assembled at runtime is invisible to text and dies at once here.

  **That job is switched off, and so is the workflow that would run the normal
  one.** `.github/workflows/tests.yml` triggers on `workflow_dispatch` only and
  `macos-shell` carries `if: false`; a push produces no check, and the gates read
  `none`, which they document as nothing to assert. The paragraph above therefore
  describes what CI *is for*, not what it is doing — while this stands, the suite
  is proven only by `pr-selfcheck.sh` on the contributor's own machine, and a
  regression that needs the second shell to see can merge. It came off because the
  suite was the largest fixed cost per round and several of the assertions doing
  the blocking were themselves wrong; #93 owns restoring the triggers and the job
  alike — both are named in its acceptance criteria — after the fixtures
  are audited against *assert the invariant, not the version's route to it*.

  **`SKILL.md`'s bash is not covered by any of it**, and that is issue #26 rather
  than an oversight: ~950 lines of executable shell live in a Markdown file, and
  reaching it means parsing Markdown. That was tried and removed — four rounds of
  fence spellings, two of which rejected valid source. The fix is to move the code
  into `.sh` files, where every existing check covers it for free. Until then one
  narrow lift, by anchored `grep` and with no grammar, covers the merge-gate
  condition that made the gap visible.

  **Do not build a text scanner for this.** One was, and it is why this bullet is
  short: 2,200 lines and fifty-two review rounds, every round answering one finding
  and producing the next, with several of its own defects rejecting portable code.
  It is the shape this file records twice more. What it bought over running the
  suite was unexecuted branches; what it cost was the review budget of an entire
  release.

  **The job builds its own `PATH`; it does not hide names from the runner's.** A
  denylist of Linux-only commands was tried and was one name behind on every
  round — the same shape as the scanner. `PATH` is replaced with links to the
  commands stock macOS has, so anything nobody listed simply does not resolve. What
  goes on that list is what a MAC has, not what a developer machine has: `make`,
  `cc` and `python3` arrive with the Xcode Command Line Tools, which `README.md`
  does not ask a contributor for, so their absence is asserted too. If
  the job fails with `command not found` for something portable, add it to that
  list; that direction of failure is the safe one.

  **The classes it cannot see belong to the reviewers, so they live in the
  reviewer files.** `AGENTS.md` and `.github/copilot-instructions.md` carry the
  GNU-only flags, the regex escapes and the unexecuted-branch gap as a table —
  Copilot reads only its own file and follows no pointers, so an acknowledged CI
  gap recorded here alone is a gap in one required reviewer's contract. That is
  the doc-sync rule applied to this file's own limits.

  Pin the inner interpreters, not only the outer one — the suite runs `bash -c` and
  `#!/usr/bin/env bash` helpers throughout, and pinning only the outer shell proves
  almost nothing. A tool stock macOS lacks is still usable: probe it with
  `command -v` and provide a fallback, as `testlib.sh` does for `timeout`. GNU-only
  FLAGS and `\s` in a `grep` pattern are review's job — the command exists on both
  platforms, and BSD `grep` does not fail on `\s`, it matches a literal `s`.
- Every behaviour change ships its test in the same PR.
- Prove a new test can fail: revert the fix and confirm the test fails for the
  reason it names. A fixture that passes against the unfixed code is worse than
  no fixture.
- Run the whole suite the way CI does:

  ```bash
  cd skills/watch-prs/scripts
  fail=0; for t in test-*.sh; do bash "$t" || { echo "FAIL $t"; fail=1; }; done; exit $fail
  ```

  **`pr-selfcheck.sh` does not run it that way, and the difference is deliberate.**
  The files are independent — each builds its own scratch directory and stubs its
  own `gh` — so the pre-push gate runs four at a time and takes ~85s where the
  loop above takes ~208s. CI keeps the loop because it wraps each file in a
  `::group::` and reports failures with `::error file=`, and that structure is
  worth more on a machine nobody is waiting at. `RB_SUITE_JOBS` sets the degree;
  it is not derived from the core count, because the `macos-shell` job asserts
  `nproc` is unreachable. See issue #52.

- **A shadowed `type` inside `rb_load` is accepted, not fixed.** The loader
  verifies the symbol it just loaded with `type -t`, and a `type() { return 1; }`
  in the operator's shell turns a good library into `reason=<lib>_empty`. #88
  removes the same call from the ten helpers that wrap the loader — a separate
  change, in flight alongside this one — because there the check has somewhere to go — calling an undefined `rb_load` exits 127, which
  has no name in it. That does not transfer: asking whether a name is a function
  needs `type`, `declare` or `command`, all shadowable, or calling the symbol,
  which for `rb_identity` means shelling out to `git`. Dropping the check moves
  the failure to the caller's first use and loses the precise reason; a subshell
  probe forks per load and still runs the function. It stays, on this boundary,
  and `loadlib.sh` says so beside it. #96.

## Documentation sync

A behaviour change updates every layer that describes it: `SKILL.md` (what the
driving model does), `AGENTS.md` and `.github/copilot-instructions.md` (what the
reviewers are told), `README.md` (what the user configures and sees), and the
script comments that explain *why* the code is shaped that way. A user-visible
change with no `README.md` update is incomplete, not merely undocumented.

## Release

Bump `version` in `.claude-plugin/plugin.json` and add a `CHANGELOG.md` entry in
the same PR. There is one manifest: v2 ships to Claude Code only, because the
driver needs a watch tool and both reviewers run in GitHub's cloud rather than
from anything installed here. Entries explain the failure that was fixed and how it
manifested, not just what changed.

**A release accompanies a change to what is installed** — the scripts, `SKILL.md`,
or the manifests. A change confined to `skills/watch-prs/scripts/test-*.sh`, to
authoring documentation, or to the reviewer instruction files produces no
release, and must not bump the version.

The reviewer files are on the no-release side despite being contract rather than
prose: `AGENTS.md` and `.github/copilot-instructions.md` are read by Codex and
Copilot **from the pull request's base ref**, which is why a PR cannot rewrite
the rules it is judged by — and it is also why nothing installs them. A user who
updates the plugin receives no part of them, so a release for a change to one
would be exactly the unobservable release this boundary exists to prevent.

That is the settled practice, not a new allowance: #42, #44 and #47 were
test-only and #40 was documentation-only, all four merged with no bump and clean
from both reviewers. It is written down because the rule above, read alone, says
to bump for a fixture that got faster — and a version identifies what ships, so
bumping for a change nobody can observe turns the changelog into a commit log.
An entry is required to explain the failure that was fixed and how it manifested;
a faster fixture has no failure to explain to a user.

## One change per pull request

**A PR closes one issue.** Build the smallest thing that closes it: no
opportunistic hardening, no generalising a specific fix, no second concern
because the file is already open. An **unrelated or pre-existing** defect found
mid-work gets filed, not fixed — even when the fix is small.

**A defect this PR introduced is not deferrable**, and neither is one introduced
by a review fix: those are this round's work and must be repaired before merge.
Filing a regression you just caused would ship it behind an issue number, which
is the opposite of what one-change-per-PR is for. `README.md` states the same
rule from the author's side — a regression the fix itself introduces is always
this round's work.

**Split complex work into sequential sub-issues** and land them one after
another. If a fix needs a behaviour change in a helper, that helper change is its
own PR first — `pr-review-state.sh`'s reply counting had to land as #35 before
#33 could reach a signoff at all.

This is written down because breaking it cost a release. #33 set out to extract
the Codex→Copilot transition and grew concurrency hardening on the way; the
review then found defects in the FIXES rather than in the change — two of them
introduced by the previous round's fix — and the loop narrowed without
converging. Four commits were dropped from the PR and re-filed as #37 and #39.

`README.md` states the reader-facing half of this: rounds that keep finding
defects in the fixes usually mean the change is too large, and splitting the PR
is the faster route.

## One change per review round

The rule above bounds what a **pull request** may contain. This one bounds what a
**round** may contain, and that is where the cost actually accumulates: #53's
change — running the suite four files at a time — never had a finding against it.
Every one of its twenty-seven rounds was surface the fixes exposed.

- **Fix what the finding names, and nothing else.** The PR-scope rule already
  forbids the second concern because the file is open; at round scope nothing did,
  and a round that answers a finding with more than the finding named is how a
  review starts converging on the fixes instead of on the change. A broader change
  is an issue and a line in the round summary, exactly as at PR scope.
- **Prefer removing the dependency over guarding it.** A guard is a name, and
  names can be shadowed, mis-parsed or forgotten; a removed dependency stays
  removed. This is the single rule that ended each class in #53, and reaching for
  another check is what extended them. `SKILL.md` carries the driver-facing copy,
  including the requirement to say on the finding thread which of the two was
  taken and why.
- **Read the thread and the previous round's diff before writing.** A finding
  answered without reading what the last round did is how the same defect is
  fixed, re-broken and re-found — three rounds of #58 were a check that passed
  against the edit it existed to stop, each one written without re-reading the
  one before it.
- **The fault-tolerance pass runs only if the Copilot phase produced commits**,
  and is bound by every rule above. It reviews those commits; it is not an
  opening to revisit the design. Where the phase produced none, both signoffs
  name the same commit and the pass would re-review something Codex has already
  signed off — which costs a revocation, a round, and a reopened phase, for a
  verdict that cannot differ.

## Stating the task

The reviewers judge relevance against what the PR says it set out to do, so the
author side of that contract matters:

- The PR body states what the change sets out to do.
- Every round summary states what was addressed and what was intentionally
  skipped. A resolved thread on its own is not a record of a fix.

  The skipped part is a past-tense **disposition** and a bare issue number — "one
  finding was answered on its thread rather than applied", "one is deferred to
  #11" — never a description of the unfixed defect or the reasoning for leaving
  it. The summary shares a comment with the `@codex review` mention, and a mention
  describing work still to be done is read as a work order rather than as context:
  Codex then commits in an environment with no remote and the round is spent. That
  is not hypothetical; `skills/watch-prs/SKILL.md` records the incident.
- Neither can waive a finding. Both are untrusted context to a reviewer: they
  establish intent, never permission. Where a limitation is genuinely accepted,
  record it on the base ref.

## Repo arming

`.claude/settings.json` enables this plugin for the checkout and is committed, so
a fresh clone arms itself. There is nothing else to arm: v2 starts no daemon.

The Codex GitHub connector is account-level, linked once at
`chatgpt.com/codex/cloud/settings/connectors`; per-repository review behaviour
lives on the Codex **Code review** settings page.
