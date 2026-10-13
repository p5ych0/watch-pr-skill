# Decision: the plugin ships one hooks module, and it gates nothing

**Date:** 2026-10-13
**Status:** accepted
**Decided by:** the repository operator, in session, on the measurements below
**Raised in:** #365

The plugin may ship one function-hooks module at its root, named by `hooks/hooks.json`. It
exists to pick the model and effort of the loop's own subagents, the cold reviewer and a
delegated fix pass, from the size of the work. It runs in the session of every operator who
installs the plugin, which is what
`docs/decisions/2026-09-07-authoring-tools-not-boundaries.md` ruled out when it said no hook
installs. That rule was written about the checkout's hooks and still holds for them. This
record is the one exception to it, and the exception's bounds.

## What is accepted

- **A hook runs in every installing session.** It is the plugin's own module, not one of the
  checkout's authoring hooks. Nothing under `.claude/hooks/` ships, so the text match the
  2026-09-07 record accepts as evadable stays in this checkout.
- **It fails open.** The module rewrites two arguments of an Agent call, `model` and
  `effort`, and gates nothing: every proof, mutation and gate of the loop is a privileged
  helper's. A hook that throws is skipped and the call goes through as its caller made it,
  and so does a call the module cannot size. Losing the module costs a subagent run at the
  model and effort it would have had with no module, which is what every run cost before one
  existed. A module that failed closed would stop a cold read on a fault that is not the
  change's.
- **The API under it is early access.** Function hooks may change between releases of the
  CLI. A module that no longer loads is the fail-open case above, and the loop runs untiered.
- **The suite pins its shape, not its behaviour.** The module is TypeScript run by the CLI's
  own engine. It needs nothing installed on the operator's machine, and CI has no CLI to run
  it with. `test-hooks.sh` holds the bounds below as source assertions, and the module's own
  cases run under `claude plugin test` wherever the CLI is present.

## The bounds, each held by `test-hooks.sh`

- `hooks/` is a directory, not a link, holding `hooks.json` and the one module it names and
  nothing else.
- `hooks.json` is exactly an empty `hooks` record and one `modules` entry, a `.ts` file
  beside it. No command hook can ship through it.
- The module registers one hook, `tool.call` for `Agent`. It never refuses a call and names
  nothing under `.claude/`.
- Neither manifest declares hooks, and no Markdown file's frontmatter does.

A plugin root with no `hooks/` at all passes too.

## What it cost to learn

The empty `hooks` record is not decoration. A staged plugin root, validated by four builds
of the CLI:

| `hooks/hooks.json` | 2.0.76 | 2.1.100 | 2.1.200 | 2.1.296 |
| --- | --- | --- | --- | --- |
| `{ "modules": ["./tiering.ts"] }` | not read | fails, `hooks: Invalid input: expected record, received undefined` | fails, the same | passes |
| `{ "hooks": {}, "modules": ["./tiering.ts"] }` | not read | passes | passes | passes, and the module is read |

Without the record, every install on a build that predates function hooks carries a hooks
file that build rejects. With it those builds read an empty record and run no module.

Staged under `claude plugin test` on 2.1.296, a hook that throws is skipped and the call
reaches the tool with the model and effort its caller set.

## What does not change

- No command hook installs, from this checkout or anywhere else. A `hooks` key in either
  manifest, a `hooks` record in `hooks.json` that is not empty, or a `hooks:` line in a
  Markdown file's frontmatter is a finding.
- A second module, a second hook in the module, a hook on anything but an Agent call, or a
  hook that refuses one, is outside this record and needs its own.
- The helpers stay the only thing that proves, mutates or gates. A change that moves a
  decision of the loop into the module is a finding whatever this record says.
