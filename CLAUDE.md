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
| `skills/watch-prs/scripts/pr-review-state.sh` | Whether a named reviewer's review of the current head can carry a merge. |
| `skills/watch-prs/scripts/pr-merge-range.sh` | Whether every commit since the reviewed SHA is a review-fix commit reachable from it. |
| `skills/watch-prs/scripts/pr-findings.sh` | The unresolved findings, paginated and shape-validated, and the body of a blocking review. |
| `skills/watch-prs/scripts/pr-round-count.sh` | How many rounds this PR has had, and whether this is an operator check-in boundary. |
| `skills/watch-prs/scripts/pr-ci-state.sh` | Whether the pushed head's checks are green, still running, failing, or absent. |
| `skills/watch-prs/scripts/pr-watch.sh` | Blocks until a reviewer's verdict on the current head is actionable. |
| `skills/watch-prs/scripts/pr-selfcheck.sh` | The pre-push check over this plugin's own sources. |
| `skills/watch-prs/scripts/recordlib.sh` | What a well-formed GitHub record is — one definition, sourced by every helper that reads the API. |
| `skills/watch-prs/scripts/identitylib.sh` | Which repository this checkout is — one definition, sourced by every helper and by `SKILL.md`. |
| `skills/watch-prs/scripts/loadlib.sh` | How a shared library is loaded and proven loaded — clear, source, verify — in one place. |
| `skills/watch-prs/scripts/testlib.sh` | The portable watchdog and the validated scratch directory. Every fixture runs under it, and `pr-ci-state.sh` bounds its `gh` calls with it — so it ships at runtime too, not only in the suite. |
| `skills/watch-prs/scripts/test-*.sh` | The suite. |
| `.claude-plugin/` | Plugin and marketplace manifests. |

Everything else is documentation. **v2 runs no reviewer of its own**: Codex and
Copilot are first-party GitHub apps, so there is no watcher, no response
monitor, no bus directory, and no systemd unit.

## Bash conventions

Strict mode is chosen per script category, not applied uniformly. Match the
category; do not "fix" a script into a stricter mode.

| Mode | Scripts | Why |
| --- | --- | --- |
| `set -euo pipefail` | one-shot commands | Abort on the first failed step. |
| `set -uo pipefail` | `pr-review-state.sh`, `pr-merge-range.sh`, `pr-round-count.sh`, `pr-findings.sh`, `pr-watch.sh`, `pr-ci-state.sh`, `pr-selfcheck.sh` | **`-e` is forbidden here.** Subcommands use exit codes as control flow and several `gh` probes "fail" as normal operation; `pr-selfcheck.sh` is in this row because a `grep` that matches nothing exits 1 as its normal answer. |

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
  `REVIEW_BUS_REPO` override it so tests can supply an identity without a real
  remote. `test-identitylib.sh` proves the parser's rules; `test-pr-identity.sh`
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
- Self-contained: throwaway git repos under `mktemp -d`, `gh` stubbed, no
  network. CI has no credentials, so a test that reaches GitHub is a broken test.
- **Portable, and proven by running rather than by reading.** The `macos-shell` CI
  job runs the whole suite on a bash 3.2.57 built from source and first on `PATH`,
  with the GNU-only tools removed. Post-3.2 constructs fail there, and so do the
  differences in PARSING that no feature list contains — an inline `[[ … =~ … ]]`
  pattern with a parenthesis is a syntax error on 3.2, and `pr-watch.sh` carried
  one from the day it was written. Absence covers the other half: a command name
  assembled at runtime is invisible to text and dies at once here.

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
