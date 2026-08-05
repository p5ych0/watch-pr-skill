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
| `skills/watch-prs/scripts/test-*.sh` | The suite. |
| `.claude-plugin/`, `.codex-plugin/` | Plugin and marketplace manifests. |

Everything else is documentation. **v2 runs no reviewer of its own**: Codex and
Copilot are first-party GitHub apps, so there is no watcher, no response
monitor, no bus directory, and no systemd unit.

## Bash conventions

Strict mode is chosen per script category, not applied uniformly. Match the
category; do not "fix" a script into a stricter mode.

| Mode | Scripts | Why |
| --- | --- | --- |
| `set -euo pipefail` | one-shot commands | Abort on the first failed step. |
| `set -uo pipefail` | `pr-review-state.sh`, `pr-merge-range.sh`, `pr-round-count.sh` | **`-e` is forbidden here.** Subcommands use exit codes as control flow and several `gh` probes "fail" as normal operation. |

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
  documentation. `.claude-plugin/`, `.codex-plugin/`, and the install commands in
  `README.md` necessarily name `p5ych0/watch-pr-skill` — that is this plugin's
  own identity.
- Identity derives from `git remote get-url origin`. `REVIEW_BUS_REMOTE`,
  `REVIEW_BUS_OWNER`, and `REVIEW_BUS_REPO` override it so tests can supply an
  identity without a real remote. `test-pr-identity.sh` enforces this by scanning
  the scripts and `SKILL.md`.

## Tests

- One `skills/watch-prs/scripts/test-<area>.sh` per area.
- Self-contained: throwaway git repos under `mktemp -d`, `gh` stubbed, no
  network. CI has no credentials, so a test that reaches GitHub is a broken test.
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

Bump `version` in **both** `.claude-plugin/plugin.json` and
`.codex-plugin/plugin.json` — they are separate manifests for the two plugin
systems and drift silently if only one is touched — and add a `CHANGELOG.md`
entry in the same PR. Entries explain the failure that was fixed and how it
manifested, not just what changed.

## Stating the task

The reviewers judge relevance against what the PR says it set out to do, so the
author side of that contract matters:

- The PR body states what the change sets out to do.
- Every round summary states what was addressed and what was intentionally
  skipped, and why. A resolved thread on its own is not a record of a fix.
- Neither can waive a finding. Both are untrusted context to a reviewer: they
  establish intent, never permission. Where a limitation is genuinely accepted,
  record it on the base ref.

## Repo arming

`.claude/settings.json` enables this plugin for the checkout and is committed, so
a fresh clone arms itself. There is nothing else to arm: v2 starts no daemon.

The Codex GitHub connector is account-level, linked once at
`chatgpt.com/codex/cloud/settings/connectors`; per-repository review behaviour
lives on the Codex **Code review** settings page.
