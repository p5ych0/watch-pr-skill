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

Strict mode is chosen per script category, not applied uniformly. Match the
category; do not "fix" a script into a stricter mode.

| Mode | Scripts | Why |
| --- | --- | --- |
| `set -Eeuo pipefail` | `review-bus-codex-watcher.sh`, `review-bus-codex-start.sh`, `review-bus-response-monitor.sh` | Long-running daemons and their launcher. `-E` so `ERR` traps survive into functions and subshells. |
| `set -euo pipefail` | `review-bus-request.sh`, `review-bus-close-round.sh` | One-shot commands that abort on the first failed step. No `ERR` trap to propagate, so no `-E`. |
| `set -uo pipefail` | `review-bus-copilot.sh`, `hooks/session-start.sh` | **`-e` is forbidden here.** `copilot.sh` subcommands use exit codes as control flow and several `gh` probes "fail" as normal operation. `session-start.sh` is a SessionStart hook: it must never block or fail a session, so it always reaches `exit 0`. |
| none | `review-bus-rounds.sh` | A sourced library — it inherits whatever mode its caller set. |
- **Intentional no-op branches use an explicit `return 0`.** A bare `return`
  after a failed test inherits that test's exit status 1; under strict mode with
  an unguarded caller, that terminates the daemon and systemd restarts it into a
  crash-loop. This is issue #3.

  **This one is enforced by review, not by a test, and deliberately so.** A
  structural "no bare returns anywhere" check was built and removed: six
  successive versions were each defeated by legal Bash — `{ ...; return; }`,
  `|| return # why`, a `#` inside a quoted string, `return >/dev/null`,
  `return 2>/dev/null` (the `2` is an IO number, not an argument),
  `return {fd}>/dev/null`, and a `return` inside a `$( )`, which executes even
  within double quotes. Each version reported PASS while its stated invariant was
  false, which is worse than no check: it converts an unverified assumption into a
  green tick. Sound detection needs a real Bash parser, and shellcheck has no rule
  for it. So when reviewing a diff here, read every `return` and check it states a
  value. The behavioural consequences are covered by
  `test-review-bus-noop-returns.sh`.
- **Every fetch, parse, and diff step must fail closed.** The invariant is about
  the *outcome*, not one idiom: a failure must never be indistinguishable from
  "no findings", "clean", or "zero unresolved". Two mechanisms satisfy it, and
  which one applies depends on how the caller consumes the result:
  - **Propagate non-zero** — `|| return 1` — where the caller branches on exit
    status. Most fetch and diff steps.
  - **Emit a distinguished sentinel and return 0** — where the caller consumes
    *stdout*, so a non-zero exit would be swallowed while the empty output looked
    like a valid answer. `latest_pull_comment_at`, `latest_issue_comment_at` and
    `unresolved_review_threads_count` print `$PREFLIGHT_ERR` this way, and every
    caller compares against it before using the value.

  Emitting the sentinel is not a violation of the rule; changing a sentinel
  helper to `return 1` would break its data contract with those callers. What
  *is* a violation is any path where a failure yields an ordinary-looking value.

## Repo-agnostic invariant

- The invariant covers **runtime bus identity**: no hard-coded owner, repo, bus
  path, or branch name in the scripts, in `hooks/`, or in `SKILL.md`. The same
  installed copy serves every project simultaneously, so a literal identity
  there would leak one project's bus into another's.
- It does **not** cover this repository's own metadata or its installation
  documentation. `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`,
  `.codex-plugin/plugin.json`, and the install and update commands in
  `README.md` necessarily name `p5ych0/watch-pr-skill` — that is this plugin's
  own identity, not a consumer project's, and changing it there is not a defect.
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
- **Commits that address Copilot findings carry a `Review-Phase: copilot`
  trailer** on its own line. After a clean Codex signoff the watcher holds
  auto-enqueue while every commit since it carries that trailer, so Copilot-fix
  work no longer drags Codex back through a round it has already passed. A
  commit without the trailer invalidates the phase and Codex reviews again —
  which is correct, since such a commit is not Copilot-fix work. Forgetting it
  costs one redundant review, never a missed one, which is why the trailer is
  the key rather than a commit-subject prefix: subject-prefix counting already
  failed here once (CHANGELOG 1.0.10).

## Repo arming

`.claude/settings.json` enables this plugin for the checkout, and `.review-bus.md`
opts the repository into the SessionStart hook. Both are committed so a fresh
clone arms itself without hand-edited local settings.
