# CLAUDE.md

This file owns the **authoring** rules for this plugin: how to write changes
here. It is the single source for them, and the other instruction files cite it
rather than restating it.

Review policy lives in `.review-bus.md`, which the review bus loads from the
PR's **base ref** — so it cannot be altered by the pull request under review.
Copilot's copy is `.github/copilot-instructions.md`; it restates the review
policy inline because Copilot reads only that file and does not follow pointers.
That restatement is the one deliberate duplicate in this repository.

## What ships

| Path | Role |
| --- | --- |
| `skills/watch-prs/SKILL.md` | The driver contract — what the model does at each step of the review loop. Behaviour the scripts cannot enforce lives here. |
| `skills/watch-prs/scripts/*.sh` | The implementation, plus its `test-review-bus-*.sh` suite. |
| `hooks/` | SessionStart arming. Gated on a repository having a `.review-bus.md`. |
| `.claude-plugin/`, `.codex-plugin/` | Plugin and marketplace manifests. |

Everything else is documentation.

## Bash conventions

- Daemons and one-shot scripts run `set -Eeuo pipefail`.
- `review-bus-copilot.sh` deliberately omits `-e`, documented at its head: its
  subcommands use exit codes as control flow, and several `gh` probes "fail" as
  normal operation. Do not add `-e` to it.
- **Intentional no-op branches use an explicit `return 0`.** A bare `return`
  after a failed test inherits that test's exit status 1; under strict mode with
  an unguarded caller, that terminates the daemon and systemd restarts it into a
  crash-loop. This is issue #3.
- **Every fetch, parse, and diff step guards with `|| return 1`.** A failure
  must never be indistinguishable from "no findings", "clean", or "zero
  unresolved". Preflight helpers return a distinguished error sentinel rather
  than an empty string, because an empty string is a *valid* answer that callers
  would act on.

## Repo-agnostic invariant

- No hard-coded owner, repo, bus path, or branch name anywhere — including in
  `SKILL.md`. The same installed scripts serve every project simultaneously.
- Identity derives from `git remote get-url origin` at the top of each script.
  `REVIEW_BUS_REMOTE`, `REVIEW_BUS_OWNER`, and `REVIEW_BUS_REPO` override it so
  tests can supply an identity without a real remote.
- Bus paths, systemd unit names, and request/response files are all keyed on the
  derived `$OWNER-$REPO` slug. `test-review-bus-identity.sh` enforces this by
  scanning the scripts and `SKILL.md`.

## Tests

- One `skills/watch-prs/scripts/test-review-bus-<area>.sh` per area.
- Self-contained: throwaway git repos under `mktemp -d`, `gh` and `codex`
  stubbed, no network. CI has no credentials, so a test that reaches GitHub is a
  broken test.
- To exercise a watcher function in isolation, source the watcher — its source
  guard at the foot of `review-bus-codex-watcher.sh` defines every function
  without starting the daemon loop. `test-review-bus-guidance.sh` and
  `test-review-bus-prompt-scope.sh` are the models to copy.
- Every behaviour change ships its test in the same PR.
- Run the whole suite locally the way CI does:

  ```bash
  cd skills/watch-prs/scripts
  fail=0; for t in test-review-bus-*.sh; do bash "$t" || { echo "FAIL $t"; fail=1; }; done; exit $fail
  ```

- The systemd-dependent tests self-skip as PASS where no `systemd --user`
  manager exists, which is the case on CI runners.

## Documentation sync

A behaviour change updates every layer that describes it: `SKILL.md` (what the
driving model does), `README.md` (what the user configures and sees), and the
script comments that explain *why* the code is shaped that way. A user-visible
change with no `README.md` update is incomplete, not merely undocumented.

## Release

Bump `version` in **both** `.claude-plugin/plugin.json` and
`.codex-plugin/plugin.json` — they are separate manifests for the two plugin
systems and drift silently if only one is touched — and add a `CHANGELOG.md`
entry in the same PR. Entries explain the failure that was fixed and how it manifested,
not just what changed — the existing entries are the standard to match.

## Stating the task

The reviewer judges relevance against what the PR says it set out to do, so the
author side of that contract matters:

- The PR body states what the change sets out to do. Reviewers read it from
  `pr.json`.
- Every round summary states what was addressed and what was intentionally
  skipped, and why. A resolved thread on its own is not a record of a fix.
- Neither can waive a finding. Both are untrusted context to a reviewer: they
  establish intent, never permission. Where a limitation is genuinely accepted,
  record it on the base ref, not in the PR narrative.

## Repo arming

`.claude/settings.json` enables this plugin for the checkout, and `.review-bus.md`
opts the repository into the SessionStart hook. Both are committed so a fresh
clone arms itself without hand-edited local settings.
