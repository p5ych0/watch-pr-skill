# Changelog

## [2.0.83] — 2026-08-29

- **Setup runs in a process now, and `SKILL.md` is 9,843 characters shorter.** The
  block that starts a session was 178 executable lines and 105 comment lines of the
  document — 18,450 characters, about a fifth of everything the driver reads on every
  invocation — and nothing executed them. It is 96 and 47 now, 8,607 characters, and
  the work happens in `pr-setup.sh`, which has tests.

  What made that possible was noticing that an old measurement proved less than it
  said. #26 asked whether this code could move into a script and answered no, because
  setup EXPORTS into the driving session and a child cannot export into its parent.
  That is true of a child's environment and false of a file the driver SOURCES: an
  assignment in a sourced file happens in the sourcing shell, which is the one
  property the block needed. So the helper writes `env` and the driver sources it.

  Nothing about what the driver checks was given up. The origin still comes back
  through `pr-origin.sh`, privileged; the identity is still re-derived from what was
  sourced, because a file is not a promise; the four working paths are still proved
  against their literals and proved to be empty files; and the pin is still proved by
  a real child of the driving shell — that one cannot move, because proving it inside
  the helper would prove only that the helper exports.

- **A value in that file cannot become a command.** A remote URL is not this
  repository's text — a checkout can carry any origin, and a `git` config nobody read
  can put a quote, a `$(…)`, a backtick or a semicolon in it. Every value is written
  single-quoted with `'` escaped, which has no expansion of any kind inside it, and
  `test-pr-setup.sh` stages six such shapes against the real helper: each round-trips
  byte-exact through the source and none of them executes.

- **The pre-push gate could not see through a source, and said so.** `pr-selfcheck.sh`
  scans `SKILL.md` for names used and never assigned, and the twelve setup values are
  now assigned in a file that does not exist at scan time — so all twelve were
  reported as undefined. It reads a declaration instead, the same mechanism a shared
  library already used there and for the same reason: inferring what a run assigns is
  a reachability analysis, and a wrong answer reads as "this variable is fine". The
  binding is derived at both ends — the document names the leaf it sources, the helper
  declares which leaf it writes — so neither side is a list. A leaf nothing claims, one
  two helpers claim, and a claimant that declares nothing are all errors rather than
  empty sets.

## [2.0.82] — 2026-08-29

- **The plugin works on the repository in the current directory, and names no
  other — anywhere, prose included.** That rule is now written down in `CLAUDE.md`
  and in both reviewer files, so a slug added to a comment or a changelog entry is a
  blocking finding rather than something to notice later.

- **Thirty such mentions are gone**, and the identity guard no longer keeps a list
  of the author's projects. The
  measurements behind the required-checks work cited the public repositories they
  were taken on, and two archived v1 planning documents discussed another project of
  the same author. Every one of those names is gone: the measurements keep their
  force — "three required contexts on one, eleven on another, twenty-three on a
  third", "a commit with thirteen check runs and no statuses reports SUCCESS" — and
  say nothing about whose repositories they were.

  The two archived documents were **deleted** rather than edited. They planned the
  v1 `review-bus` watcher, which v2 removed: `review-bus-codex-watcher.sh` and the
  `test-review-bus-*.sh` fixtures no longer exist, nothing in the tree referenced
  them, and every issue number in them belonged to the other project.

- **And the identity guard no longer keeps a list of the author's projects.**
  `test-pr-identity.sh` forbade two repository names by spelling them out — a list to
  maintain, in the one file whose job is to forbid exactly that. It is ONE fixed
  string now: the owner, in any spelling, anywhere in a scanned file. Its header used
  to exempt the bare owner — "it names the shared review token in comments" — which
  was a v1 idea that went with the bus; what is left is this repository's owner
  appearing in files that must work for every other.

  **It was a pattern language for four review rounds first, and that is the part
  worth recording.** Generalising the list into arms that told a literal from an
  expansion after `owner=` and `repo=` produced a finding per round, each fixing the
  last: a name may start with a digit, then with a dot, then `[` is a glob and
  `--repo=[A-Za-z]*)` is legal code, then `+(` is one too and `$'…'` is a literal
  beginning with `$`. Every one was a fact about shell syntax, and reading shell
  syntax out of text needs a shell. What the fixed strings cannot see is said where
  the code is: an identity belonging to neither this repository nor its owner, and a
  path keyed on the plugin's own name — which cannot be forbidden, because setup's
  second discovery mode globs it to find the scripts at all.

  That scan asserts an ABSENCE, and nothing had ever exercised it — a pattern
  matching nothing would have reported the invariant holding without testing it.
  Every arm now has a probe, and six DERIVED spellings have one too: the first
  generalisation wrote `repo=.?[A-Za-z]`, where the `.?` eats the `$` and the class
  eats the first letter, so `repo=$REPO` — the spelling this repository requires —
  would have failed the guard. It matched nothing here only because no script
  happens to write it that way, which is a landmine rather than a pass.

## [2.0.81] — 2026-08-29

- **A shadowed `echo` and `exit` could walk past the round check-in's refusals and
  record a permission nobody gave.** The block that acknowledges a round boundary
  refused with `|| { echo "ABORT: …"; exit 0; }`, four times, and that bash runs in
  the operator's own shell where both names belong to whoever is sitting there.
  Measured against the block lifted out of `SKILL.md`, with a probe printing a
  plausible `PR_ROUND_PAUSE … rounds=41 …` line and then exiting 1:

  | operator shell | acknowledgement posted? |
  | --- | --- |
  | ordinary | no |
  | `echo() { :; }` | no |
  | `echo() { :; }; exit() { return 0; }` | **yes** |

  With both shadowed the arm ran, `exit` returned instead of terminating, execution
  continued into the parse — which succeeds, because the forged line is well-formed
  — and a failed probe's output became the recorded permission. The comment above
  that block says permission is the one thing that must never be inferred from
  unreadable output.

  **The answer is where the post SITS, not what guards it.** Every proof is now a
  reserved word — `if`, `[[`, `case` — and the `gh pr comment` is inside the
  innermost success arm of all three. A refusal is an arm NOT TAKEN rather than a
  statement that has to terminate, so **shadowing `echo` or `exit` can no longer
  turn a refusal into an acknowledgement**: the first silences the diagnostics and
  changes nothing else, the second is not used at all.

  That is the guarantee and not a broader one. `printf`, `sed` and `gh` remain names
  in the operator's shell, and a `sed` that prints a plausible count and exits 0
  takes every arm honestly — a forged VALUE is the same class as a forged helper,
  which is the limit `CLAUDE.md` records for the whole driver. What this release
  closes is a refusal path being walked past.

  **A refusal sentinel was tried first and is worse**, which is why the shape is
  containment rather than #181's `${VAR:?…}`. That answer does not transfer here:
  measured, with `declare -i ROUNDS_PAUSE` inherited from the operator's shell,
  clearing the sentinel stores `0`, the expansion finds it non-empty, and the
  acknowledgement is posted anyway. The setup block's expansions are safe from that
  because they refuse on an origin URL rather than on a flag — a value no integer
  attribute can forge into truth.

  **The parse's status is the `if`'s own condition.** A `sed` that prints a
  plausible count and then fails leaves the digits in place, and an assignment
  followed by a shape check accepted them; as a condition, the branch refuses.

  **And `0` is refused with the values that are not counts.** No pause happens at
  zero rounds, and under an inherited `declare -i` an empty parse becomes exactly
  that — so a semantic refusal closes an attribute hole as a side effect.

  What is not closed, and cannot be from inside: a variable this block assigns can
  be `readonly` in the operator's shell with a plausible value already in it. That
  is the limit `CLAUDE.md` records for the whole driver, and it is why the
  guarantee is stated about what a shadowed COMMAND can reach.

  `README.md`'s round check-in section says what a refusal now does: nothing is
  recorded, the round is not closed, and the next call pauses again on the same
  count. Closes #224.

- The contract test's claim and float scanners now see **indented** bash fences. Two of this
  document's blocks sit inside list items, and a column-anchored scan did not reach
  them — which made those two the only blocks that could carry no argument at all,
  since a pointer inside one was counted in the file total but not in the fenced
  total and the two could never agree. Fail-closed rather than blind, which is why
  it surfaced the moment this change put a claim there. The float scan — the one
  that requires code to follow a pair before its fence closes — needed the same
  handling, or a pair at the END of an indented fence would satisfy the bijection
  while annotating nothing.

## [2.0.80] — 2026-08-29

- **The "require branches to be up to date" policy is enforced where it can be
  read, and #219 said nothing enforced it at all.** That policy makes a pull request
  merge only when its head is current with the base, so the required checks are the
  ones that ran against what actually lands. On the default path `--admin` bypasses
  branch protection, so nothing else enforces it: a branch behind its base merged
  with its checks never having run against the merged state.

  A **ruleset** carries the flag as `strict_required_status_checks_policy` on its
  `required_status_checks` rule, in a body this loop already reads. Where it is on,
  `pr-ci-state.sh --required` compares the base with the merge target and refuses a
  head that is behind — `status=behind`, its own exit status 6, which the merge gate
  reports in its own words. It is not something to wait for, and that is the point:
  no check on that commit can settle it, so `pending` would wait for something that
  is not going to happen. Nor is it folded into `failed`, which had the merge gate
  saying "a required check is not green" over a green check set. It decides ahead of
  the context verdicts, which are all about a commit that will not be merged.

  **Classic protection keeps that flag where this cannot reach it**, and #220 was
  filed believing otherwise. Measured: the branch object's `required_status_checks`
  holds `checks`, `contexts` and `enforcement_level` and no `strict`; GraphQL's
  `branchProtectionRule` is null without admin; and `RefUpdateRule` has no such
  field at all. So that half is unreadable, and unenforced on the default path.
  `REVIEW_MERGE_STRICT=1` covers both halves, because GitHub evaluates the policy
  itself there.

  **`mergeStateStatus` was measured as the way to cover the classic half and
  rejected.** `BEHIND` is one of its values and needs no admin, but it is computed
  lazily — every open pull request on two of the five repositories sampled reported
  `UNKNOWN` — and it is a single value with a precedence, so `BLOCKED` masks
  `BEHIND` whenever a review is also outstanding, which for this loop is most of the
  time. Absence of `BEHIND` proves nothing, and a gate cannot rest on a signal that
  is usually absent for another reason.

  A repository with no such policy pays nothing: the comparison is only requested
  where the flag is on, and the fixture asserts that. The flag is unioned across the
  two required-set reads exactly as the contexts are — on at either sample is on —
  and a value that is present and not a boolean is unreadable rather than absent,
  since read as absent it is the whole gate switched off by a body of another shape.

  Closes #220.

## [2.0.79] — 2026-08-28

- **The required-checks gate is bound to the commit it merges, and the read that
  makes that possible was there all along.** #214 recorded that it could not be
  done: the required set is branch-protection state, and reading it needs admin —
  `repos/{o}/{r}/branches/{b}/protection` denies with a **404 indistinguishable
  from "not protected"**, so a loop that cannot read it cannot tell "nothing is
  required" from "I am not allowed to know". That measurement was right about that
  endpoint and wrong about the question. The **branch object** —
  `repos/{o}/{r}/branches/{b}` — carries the same answer and is readable with the
  `repo` scope this loop runs under.

  Measured on ten repositories, none of which the measuring account administers:
  three required contexts came back for a sampled repository, eleven for
  a sampled repository, twenty-three for a sampled repository, while the dedicated
  protection endpoint 404s on the same repository with the same token. Rulesets are
  the other source and neither subsumes the other — one sampled repository reports
  `protection.enabled: false` with `protected: true` and its eight contexts appear
  only under `rules/branches/{b}`, a sampled repository is the other way round — so the
  required set is the **union**, and a helper reading one alone reports a
  requirement as absent.

  With that set in hand the question becomes "do these contexts pass on THIS
  commit", which the merge target's own rollup answers. So `--required` no longer
  goes through `gh pr checks`, which is addressed by pull request and carries no
  OID; the A → B → A that fitted inside #212's bracket — head moves to B, B's
  required checks go green, the probe reads them, head returns to A, and A merges
  on B's result — has nothing left to read.

  **And a required context that has not reported is now visible.** That is the part
  the all-checks gate beside it could never cover, and the reason this was a
  merge-safety hole rather than a reporting inaccuracy: that gate reads the checks
  which EXIST on the commit, and a requirement nothing has reported has neither a
  check run nor a commit status. Named, it is `pending` — the requirement stands
  and the answer is not in yet.

  **A branch that requires nothing is still an answer**; one whose protection
  cannot be read is not. `protected: false` reports `none` and the gate has nothing
  to assert, exactly as before. A branch that IS protected whose protection comes
  back missing or misshapen is an error and blocks, because the alternative is a
  merge gated on an empty required set. The branch read is also what proves the
  branch NAME: `rules/branches/{b}` answers `[]` for a branch that does not exist,
  so a misspelling would arrive as "nothing is required", while `branches/{b}`
  404s.

  **A requirement bound to an app is matched on the app.** Both sources can name
  one — `app_id` under classic protection's `checks`, `integration_id` in a ruleset
  — and GitHub then counts only that app's run, so matching on the context name
  alone would let a passing run of the same name from another app open the gate. A
  bound requirement is also not met by a legacy status, which carries a creator
  rather than the app id the requirement names; an unbound one is met by either
  kind, as GitHub does it. `app_id: -1` is the wildcard GitHub writes where any app
  may provide the check, so it is normalised to unbound — kept as a binding it
  would look for a check suite whose app id is `-1`, find none, and report
  `pending` for ever on a context that had passed.

  **A record is identified by the field its own kind has.** A check run is named by
  `name` and a legacy status by `context`; taking whichever was present let a status
  carrying a `name` answer for a requirement its own `context` did not name, and be
  classified green. A record missing the field its kind is identified by makes the
  whole rollup unreadable rather than being passed over.

  **Every record sharing a required name is evaluated**, not the first one found. A
  name can arrive as a check run and as a legacy status at once, and GitHub requires
  all of them; taking the first match let whichever the rollup happened to list
  first decide, so a passing record could answer for a failing one.

  **Both sources are read twice and everything is unioned.** The branch read and the
  rules read are not one snapshot, so a requirement can MOVE between them: add the
  context to classic protection after the branch read, remove it from the ruleset
  before the rules read, and neither body carries it though it was required
  throughout. The union is monotone, which is why this is a second read rather than
  a comparison — unioning cannot lose a requirement, and the cost of a stale one is
  that the gate reports it pending for a run and the operator re-runs.

  **A ruleset rule this cannot evaluate stops the merge** rather than being dropped.
  `workflows`, `code_scanning` and `required_deployments` gate a merge on something
  that is not a status context, so ignoring them would leave the branch reading as
  requiring only what its `required_status_checks` rules name — this issue's own
  shape one level down. The list the helper carries is of rule types that cannot
  name a check, so a type nobody has read yet refuses instead of passing. The type
  is named on the error line, filtered to what a rule type can contain: refusing
  without saying which rule caused it leaves the operator with a merge that will not
  proceed until they change something they cannot see.

  **The refusal stands in both modes, and `merge_queue` is the one exception.**
  `REVIEW_MERGE_STRICT=1` only stops passing `--admin`; it does not make a
  repository's rules non-bypassable, so a credential on a ruleset's bypass list
  merges past them there too, and the two mistakes are not symmetrical — refusing
  costs a merge the operator can make by hand with the rule named on the line, while
  passing costs a merge nobody evaluated. The queue is excepted because
  `docs/decisions/2026-08-06-merge-admin-default.md` says the `--admin` waiver does
  not cover a base branch requiring one and that strict mode is the only supported
  setting there — and because `gh pr merge` without `--admin` does the right thing
  on that rule by queueing the request, which the gate reports as status 4 rather
  than as a merge. The list
  of rules that name no check comes from the `RepositoryRuleType` schema rather than
  from what has been seen in the wild; `workflows`,
  `required_workflow_status_checks`, `code_scanning`, `secret_scanning`,
  `license_compliance_scanning`, `required_deployments` and `merge_queue` are
  deliberately not on it. The rules read is paginated, at thirty a page by default:
  a branch with more rules than that could otherwise carry its
  `required_status_checks` on a page nobody read, parsed as a well-formed array
  with the requirement simply absent.

  **And the base branch is confirmed after the read as well as before.** A pull
  request can be retargeted without its head moving, so `--match-head-commit` sees
  nothing while the requirements just read belong to the old base. That is the same
  shape as a head that moved, so it is the same answer: `stale`, which the caller
  re-runs. Only the required question pays for it; the all-checks one asks nothing
  of the base.

  **The base branch name is encoded rather than restricted.** `#`, `%` and a space
  all need encoding in a URL path and are all legal in a git ref, so refusing them
  would mean this gate could never merge a pull request targeting
  `release#candidate`. Two names are still refused: an empty one, and one
  containing `..`, which is the one traversal encoding does not close — and git
  rejects that in a ref name anyway.

  **What is still not bound**, stated because the layers that claimed too much for
  this gate are what made #214 expensive: the required set is a property of the
  base branch rather than of a commit, so a protection rule changed between that
  read and the merge is a race GitHub has too; the "require branches to be up to
  date" policy is not read, and nothing enforces it on the default path either,
  since `--admin` bypasses protection — filed as #220; and on the default path the merge still uses `--admin`,
  which bypasses protection outright, so this gate is the client-side stand-in for
  it. `REVIEW_MERGE_STRICT=1` on non-bypassable protection is still where GitHub
  evaluates the requirement itself, at merge time.

  Closes #214.

## [2.0.78] — 2026-08-28

- **The all-checks gate now asks about the commit it is merging.** `gh pr checks` is
  addressed by pull request and its answer carries no OID, so #212's `--head` could
  only BRACKET the read: an A → B → A whose both moves land between the two head
  confirmations was invisible, and the gate could accept B's checks for a merge of
  A. `pr-ci-state.sh` reads the commit's own `statusCheckRollup` instead when it is
  asked the all-checks question with a head, so the answer is about that commit and
  nothing else. The confirmations either side stay, and now only report whether the
  head has since moved.

  **One rollup rather than two paginated REST reads.** `commits/<oid>/check-runs`
  and `commits/<oid>/status` are addressed by the commit too, and reading them was
  the first shape of this change; assembling them here is what did not work.
  `--paginate` requests pages sequentially and is not a snapshot, so a rerun
  landing between two of them lets a record repeat, or be REPLACED by one carrying
  a fresh id while `total_count` holds — and the second is invisible to any rule
  about the pages themselves, because every page is individually well-formed.
  Nothing available makes two reads atomic. GitHub computes the rollup over both
  sources in one response addressed by the OID, so there are no pages to reconcile
  and no fold to get wrong.

  Measured against the live API rather than assumed: a commit with
  thirteen check runs and no legacy statuses reports SUCCESS, and another with one failed run, six still in progress and a
  passing legacy status reports FAILURE — the server's precedence agreeing with
  this file's own contract, that a failed check decides while others are still
  running. `EXPECTED` is treated as pending, being the state of a required context
  that has not reported; a null rollup is `none`, and a null `object` is an ERROR,
  because a commit the repository does not have would otherwise arrive as "no
  checks are configured" for the CI gate to accept.

  **The required-checks question keeps the bracketed query, because the read that
  would replace it does not exist for an ordinary token.** Measured for #214:
  classic branch protection needs admin and denies with a **404 indistinguishable
  from "not protected"** — so a loop that cannot read it cannot tell "nothing is
  required" from "I am not allowed to know" — while the ruleset endpoints are
  readable without admin and do not see classic protection at all. The intersection
  that issue proposed cannot be computed, and cannot fail honestly.

  **What that does NOT do is close #214**, and an argument that it did was refuted
  in review. The all-checks question is not a superset of the required one: it reads
  the checks that EXIST on the merge target, and a required context which has not
  reported is either absent from the rollup or `EXPECTED` in it — so a green answer
  is not proof that a requirement is met, and a stale required answer about another
  commit then approves the merge. What binding buys is narrower and real: a check
  that DID report on the merge target can no longer be masked by another commit's.

  **Nor is failing closed the answer.** "Refuse unless the required set can be
  bound" refuses on every repository this loop does not administer, which is the
  gate that never opens rather than one that fails closed. `REVIEW_MERGE_STRICT=1`
  on non-bypassable protection is what closes it, and every layer now says so
  rather than claiming the gate covers it.

  #214 stays open, with the measurement recorded on it.

## [2.0.77] — 2026-08-28

- **The merge gate's required-checks probe asked about the pull request, not about
  the commit it was merging.** Every gate that reaches a head-addressable question
  was given the OID the gate resolves once and pins the merge to; this one called
  `pr-ci-state.sh` without `--head`, and `gh pr checks` has no commit selector, so
  it answered about whatever the API currently called the PR's head. The
  all-checks gate beside it already passed `--head`, which is why the two were not
  answering the same question.

  **A → B → A is the case, and it always takes the return.** One move away is
  refused by `--match-head-commit`, which requires the head to still BE the OID it
  is given. The danger is coming back: the head goes to B, B's required checks go
  green, the probe reads them, the head returns to A, and the merge succeeds on B's
  result about a commit nobody merged — on the default path, where `--admin` means
  that probe and the all-checks gate beside it are what stand between a stale
  answer and an administrator merge — the all-checks one reads the checks
  unfiltered, so the required ones are among what it sees, and both have to be
  satisfied.

  It passes `--head` now, so the helper confirms the head before and after the
  checks read; this was the one caller that did not. Of the gates, `(1)` and `(2)`
  are commit-addressed, `(3b)` and `(4)` both take the OID and both reach
  `gh pr checks`, so both are bracketed rather than bound, and the thread and
  round-boundary checks are PR-level and always were. Its `stale` status is handled
  by name rather than by the catch-all, because 5 means the head moved and the
  answer is to re-run the gate, not to investigate a broken probe.

  **That is a bracket and not a binding**, and the change says so everywhere rather
  than claiming more. `gh pr checks` is addressed by PR number and its answer
  carries no OID, so the two confirmations catch a head that moved and stayed moved
  and cannot see an A → B → A whose both moves complete between them — the first
  sees A, so the move away is after it; the second sees A, so the return is before
  it. What they change is where those two moves have to fall: between the two head
  confirmations — a window that still spans the checks request — rather than
  straddling everything between the checks read and the merge. Binding it
  needs a commit-addressed query plus the required-contexts read to go with it,
  which is #214. `REVIEW_MERGE_STRICT=1` closes the required half of it and not the
  other: on a repository whose required checks are non-bypassable GitHub evaluates
  those itself, while the all-checks gate also weighs optional ones, which GitHub
  never enforces. Strict mode without the non-bypassable part only stops passing
  `--admin`.

  Both the fixture cases were proved by reverting: dropping `--head` reports the
  call as unpinned, and dropping the `5` arm reports the wrong instruction.

  The `--admin` decision record listed this as the one probe not bound to the head.
  It now says what the bracket is, and that the remaining race is **not** waived by
  it — that race needs two force-pushes between the two head confirmations, a
  window that spans the checks request rather than being contained by it, rather
  than one push before a merge, and nobody has measured it. `.github/copilot-instructions.md`
  carries the bracket as a bound on the waiver, with a contract token, so the
  reviewer that follows no pointers can flag its removal. Closes #212.

## [2.0.76] — 2026-08-28

- **Five more citations described closed work as pending, and the worst was in
  `CLAUDE.md`.** 2.0.75 corrected three files that pointed at a refactor #26 had
  examined and rejected; an audit of every issue reference outside this changelog —
  346 of them, all resolving to issues that exist — found the same class again.

  Four came out of the audit and the fifth came out of the review of it: the
  contract fixture said the `macos-shell` job "does not" run while #93 stands, which
  a phrasing-based filter missed because it does not read like a deferral. The
  lesson is in the filter rather than in the file — an audit that greps for how a
  thing is usually said finds the citations that are usually said that way.

  `CLAUDE.md` still said `SKILL.md`'s bash "is not covered by any of it" and that
  "the fix is to move the code into `.sh` files". Both are false: #26 closed on the
  finding that the code cannot move, and `test-pr-skill-contract.sh` lifts and
  EXECUTES those blocks against readonly names, namerefs, `declare -i/-l/-u`, a
  shadowed `exit`, a neutralised `echo`, an interactive shell and a forged helper —
  in BOTH CI jobs, so on bash 3.2 as well. That is the authoring source, so it is
  the worst place for it.

  The replacement says the boundary falls **by lift, not by file**: neither job
  reaches the document, both run whatever the contract extracts, and a block nothing
  lifts has no coverage at all. Saying "covered by neither job" would have been the
  same defect pointing the other way.

  `SKILL-RATIONALE.md` carried the same coverage claim and a conditional owned by
  #93, which is closed and whose CI job is enabled. `clocklib.sh` described a
  startup-semantics change as issue #69's open business when #69 was closed by a
  scoping note. And `CLAUDE.md` described lifting a block per pull request as
  ongoing, which #194 finished.

  The fixture's job reference is corrected differently from the others, because the
  underlying fact changed twice: #93 restored the job, and the operator has since
  disabled the whole `tests` workflow. It now says the classes stay a reviewer's
  because a workflow can be turned off, which is true in both states.

  What is not a defect is the other ~340: past tense about a closed issue reads
  correctly, and one accepted-limit record says outright that a reader should not
  conclude its issue is open. Present tense about pending work is what this fixes.

  The `--admin` decision record got a dated update saying PR #10 landed and which
  bounds are in force, because it was telling readers they were not. Its wider
  before-and-after framing, and its citation of a v1 watcher script v2 deleted, are
  #208. Closes #207.

## [2.0.75] — 2026-08-28

- **The rationale pointed at a refactor that had already been examined and
  rejected.** 2.0.73 described what stops a driver whose `exit` returns and ended
  "it closes when this code lives in a `.sh` file, and not before", naming #26 as
  the answer. #26 says the opposite and was closed on those grounds: the setup
  block exports `REVIEW_BUS_REMOTE` into the operator's shell and a child cannot
  export into its parent, and the read-backs exist to catch a readonly name or a
  nameref defeating the driver's own assignment — moving them into a helper would
  move them to the one process that cannot observe the failure.

  `CLAUDE.md` records that a comment arguing against the code beside it is an
  instruction and will be followed, which is why this is a defect rather than a
  stale reference: a session reading it was being sent to attempt work that had been
  measured and ruled out.

  It now says what is true — the reply instructions are prose between two fences,
  no shell construct reaches prose, and the code producing them has to run where the
  values land, so this is a limit of the driving-shell design rather than a deferred
  task. What holds instead was already listed and is unchanged. Closes #205.

## [2.0.74] — 2026-08-28

- **`SKILL.md`'s merge-gate signature named three arguments while the call passed
  four.** The usage comment read `pr-merge-gate.sh <pr> <codex-sha> <auto-review>`
  and the invocation two dozen lines below it passed `"$REVIEWERS"` as well, so a
  driver reading the signature alone would have called the gate with three — leaving
  it on its default reviewers mode rather than the one the operator chose at the
  Codex stop.

  `codex-only` is not a weaker gate: it drops Copilot's verdict and in exchange
  requires the head to BE the commit Codex signed, because the `Review-Phase:
  copilot` trailers that license a moved head do not exist when there was no Copilot
  phase. Falling back to the default silently is therefore a gate the operator did
  not choose in either direction.

  The line names both values now, matching `pr-merge-gate.sh`'s own header, and the
  contract asserts it — the block already explained the semantics further down, so
  this is the signature catching up with the rest of its own documentation. Closes
  #197.

## [2.0.73] — 2026-08-27

- **The gated head travelled through an assignment made after the push.** Closing a
  round is two stages with the thread replies between them, and the head `gate`
  proved had to reach `post`. The driver captured `gate`'s output, `sed`ed the head
  out of the record and assigned it — `GATED_HEAD="$( … )"`, in the operator's own
  long-lived shell, **after `gate` had already pushed**.

  A startup file that has made that name readonly fails it there. With `errexit` on
  the shell ends; without it the name keeps whatever it held, the non-empty check
  passes on that seeded value, and `post` is handed a head the gate never reported —
  which it then proves the working tree against, and refuses, leaving a pushed
  commit and no round closed. `CLAUDE.md` records that an assignment's status cannot
  be taken, so the `||` beside it caught nothing.

  **The head travels in a file now, and never enters the driving shell.** Both
  stages take the same path as their fifth argument: `gate` writes the head it
  proved into it, `post` reads it back and validates it before anything is posted.
  The old form — the head itself in that position — is refused by name on both
  stages, because a caller still passing it would have `gate` create a file named
  after an OID and `post` fail with a reason about a missing file rather than about
  the caller.

  That removes two more names with it. There is no capture and no `sed` — a name
  that prints a plausible forty hex and exits 0 would have sent `post` at whatever
  it said. The stage runs as a condition, so there is no status variable either,
  and each refusal ends in a reserved word.

  `$HEAD_FILE` is the fourth working file, created empty at setup beside the
  summary, the opening account and the review baseline. The contract now exercises
  all four names under a hostile shell, which the three that predate this change had
  never been.

  **A gate empties it before the bootstrap**, above the library loads and the
  argument validation, so every refusal but one
  leaves it empty rather than holding the previous round's head — the alias refusal
  below has to stay ahead of the truncation, since truncating a head file that IS
  the summary destroys the account — and the driver's `post`
  step proves the file holds a commit id **after every outcome of the gate and before
  the thread replies**, which is the boundary that matters — a guard after them stops
  `post` and not the irreversible resolve, and one inside the gate's success arm is
  on the only path that does not need it. The post step asks again, for a session
  that resumes into it with no gate having run in its own shell.

  Not merely an empty file, either: the alias refusal below has to come BEFORE the
  emptying, or it would destroy the account it is protecting, so on that one path
  the file is left holding the summary. The identity is asked FIRST and the shape
  test is its success arm — a summary that IS forty lowercase hex characters, a
  commit id someone pasted on a line of its own, satisfies the shape test exactly,
  and is the one summary that can. The shape test itself is a literal pattern in a
  `case` rather than a regex in a name a startup file could seed. That is what stops a walked-past refusal: the thread
  replies sit between the two stages and are not shell at all, so no `if` can span
  them, and what a driver whose `exit` returns meets at the next step is the STATE
  rather than an ordering it was told to respect.

  **And the head file may not be the summary file.** `gate` reads the summary and
  then writes the head, so one file serving as both means the head overwrites the
  account — and `post` finds a well-formed OID there, passes the non-empty test, and
  posts the sha as this round's summary to the reviewer that reads it before the
  diff. Both identities are refused: the same path, and a link, which is the same
  file under two names. Closes #202.

## [2.0.72] — 2026-08-27

- **Block 5's argument is out of `SKILL.md`, and it is the last block.** *Fix, then
  close the round* was 315 lines carrying 70 of commentary inside its fences. It is
  291 now, and every executable line in the document is byte-identical — checked
  mechanically, not by eye. Twelve claims stay beside the code with a `# WHY:` pointer
  under each; the arguments are twelve new sections in `SKILL-RATIONALE.md`.

  This is the first lift under 2.0.71's rule, and it shows: **nothing had to be
  merged.** Claims stack above the code they annotate, the two helper interfaces
  sit between a stack and its code, and one invariant that used to share a claim —
  the closing record having to be present, and its baseline being allowed to be
  empty — is two claims because those are two questions.

  The instruction comments in the block are rewritten in sentence case for the same
  rule: *run `gate` from a checkout on this PR's branch* and *two kinds of refusal,
  and only one is retryable* tell the driver what to do, so they are not claims, and
  a capitalised assertion with no pointer reads as a claim whose argument has gone.

  `SKILL.md` goes 81 KB to 79 KB here, and 167 KB to 79 KB across the whole of
  #194 — roughly 42k tokens read on every invocation down to under 20k. The blocks
  that remain hold 18 lines of commentary between them and are not worth a change.

## [2.0.71] — 2026-08-27

- **A claim could not be pointed at without being merged, and merging lost an
  invariant three times.** A `# WHY:` pointer had to sit IMMEDIATELY above a line
  of code, so a claim above a helper's usage table could carry none — and the only
  way to give it one was to fold it into the neighbouring claim. Each fold kept the
  strongest clause and dropped the rest: *the continuation is the `then` branch*
  twice, and the open stage's `revoke, prove, baseline, request` ordering once. The
  section kept every argument each time, and the contract compares HEADINGS, so
  nothing mechanical saw it. A reviewer found all three.

  **The rule is removed rather than guarded.** Pairs may STACK above a single line
  of code, and a usage table may sit between a pair and the code it belongs to; the
  contract asks only that code follows before the fence closes, which still catches
  a pair that annotates nothing. Nothing has to be merged in order to be pointed
  at.

  The four claims that had been merged under the old rule are split back into
  twenty-three, one per invariant, each with its own section — the document's
  pointer count goes from 51 to 70.

  One of those sections was also WRONG, and splitting is what exposed it: the
  merge gate's `(cd "$REPO_DIR" && …)` was argued as an identity defence, and it is
  not one. `rb_identity` prefers the exported `REVIEW_BUS_REMOTE`, so the session
  pin already settles which repository the gate acts on; the `cd` decides which
  TREE `pr-merge-range.sh` computes its range over, which is a different thing and
  the only thing it protects. `SKILL-RATIONALE.md` now
  states which of a fence's three kinds of comment carries a pointer — an
  instruction does not and is written in sentence case, a short argument in place
  does not, and a claim does.

  **And a section can no longer be emptied in silence.** The bijection compares
  headings, so deleting a section's argument while leaving its heading passed every
  check. One `awk`, no grammar: a heading with nothing but blank lines under it is
  a failure. It does not ask whether an argument is still complete — that is a
  judgement, it is the reviewer's, and both reviewer files now say so.

  **Both new branches are staged, accept and reject.** `_wy_contract` only ever ran
  on pairs that PASS, so every refusing branch was unexercised — which is how the
  relaxed check shipped accepting the case it exists for. Six synthetic pairs now
  put stacked claims and a usage table through it and expect acceptance, and a
  pointer with no code after it, a pointer as a fence's last line, and an emptied
  section — at the end of the document and again before another heading, because
  the scan's two arms are reached by different documents — and expect refusal.
  Reverting either half of the fence-close condition, or the empty scan's
  heading-transition arm, turns one of them red. Closes #198.

## [2.0.70] — 2026-08-27

- **Block 2's argument is out of `SKILL.md`.** *Request the review — Codex first*
  was 169 lines carrying 104 of commentary. It is 89 now, and every executable line
  in the document is byte-identical — checked mechanically, not by eye. Five claims
  stay beside the code with a `# WHY:` pointer under each; the arguments are five
  new sections in `SKILL-RATIONALE.md`.

  The operative content stayed in the block: the helper's interface and its two
  statuses, and how to write the account — with your file-writing tool, into
  `$REQUEST_FILE` and not `$SUMMARY_FILE`, one paragraph, refused if it carries a
  record marker or an `@codex review` on the automatic path. What moved is the
  argument for why: the heredoc that an account can close, `cat` and `printf` being
  names, the readonly-and-transforming probe and why it is a subshell run as a
  condition, and the two baseline shapes.

  **No claim-shaped line was left without a pointer.** The account instruction is
  written as an instruction rather than as an assertion, which is the distinction
  #198 is about — a line that reads as a claim but carries no `# WHY:` is invisible
  to the bijection.

  `SKILL.md` is 79 KB, from 167 KB when this series began — under 20k tokens
  against ~42k. Block 5 remains (#194).

## [2.0.69] — 2026-08-27

- **Block 8's argument is out of `SKILL.md`.** *Merge gate* was 208 lines carrying
  117 of commentary across three fences. It is 139 now, and every executable line
  in the document is byte-identical — checked mechanically, not by eye. Eight
  claims stay beside the code with a `# WHY:` pointer under each; the arguments are
  eight new sections in `SKILL-RATIONALE.md`.

  The operative content stayed in the block: the three helper interfaces and their
  exit codes, what `codex-only` means, that `$CODEX_SHA` is the head Codex signed
  rather than the current one, that there is no placeholder to fill in, and that
  `REVIEWERS` is `both` unless the operator chose otherwise. What moved is the
  argument for why each is that way.

  `SKILL.md` is 85 KB, from 167 KB before this series began — ~21k tokens against
  ~42k. Blocks 2 and 5 remain (#194).

## [2.0.68] — 2026-08-27

- **Block 7's argument is out of `SKILL.md`, and the rationale is renamed.** *Codex
  is clean — now the Copilot phase* was 221 lines carrying 127 of commentary. It is
  135 now, and every executable line is byte-identical — checked mechanically, not
  by eye. Seven claims stay beside the code with a `# WHY:` pointer under each; the
  arguments are seven new sections. `SKILL.md` loses ~1.5k tokens off what is read
  on every invocation.

  **`SETUP-RATIONALE.md` is now `SKILL-RATIONALE.md`.** The old name was true while
  the setup block was the only one lifted and stopped being true the moment a
  second block's argument landed in it. One document for the whole driver, because
  the alternative is a file per block and a separate bijection for each. All 38
  pointers name the new path, and the contract fails on either old one — except in
  this changelog, where 2.0.67 records what that release actually shipped.

  **The contract scans every bash fence now**, rather than the one section named in
  its `awk`. That restriction was doing nothing the pointer count does not already
  do — a pointer outside every fence was already caught — and keeping it would have
  meant editing the fixture for each block that lands, which is a list that goes
  stale exactly when someone forgets it.

  What is *not* checked is unchanged and deliberate: the rationale's own Markdown
  shape. See 2.0.67. The remaining blocks are #194.

## [2.0.67] — 2026-08-26

- **`SKILL.md` is 41% smaller, and no line of its code changed.** The document was
  ~42k tokens, read whenever the skill is invoked. 26k of that was commentary
  inside the bash fences, and 19k of it belonged to one block: **Derive identity**,
  1265 fenced lines carrying 174 executable ones.

  That commentary is the argument for why setup has the shape it has — each
  paragraph a defect that was shipped, found and paid for. It now lives in
  `SETUP-RATIONALE.md` beside it, thirty-one sections, reached from the block by
  a `# WHY:` line naming `$RB_SCRIPTS/../SETUP-RATIONALE.md`. Not a bare relative
  path, because the driving shell stays in the project under review and `docs/…`
  there names that project's documentation; and not `$CLAUDE_PLUGIN_ROOT`, which
  is unset in setup's second discovery mode. `RB_SCRIPTS` is set and validated in
  both. **The claim stays beside
  the code**: every section opens with
  the same sentence that remains in the block, so the argument reads whole from
  either end and a reader still meets the point at the line it protects.

  Nothing executable moved: the block is the same 174 lines, byte for byte, checked
  mechanically rather than by eye. `test-pr-skill-contract.sh` changed — it is what
  lifts and executes the block, and it gained the checks that keep the claims and
  their arguments from drifting apart — but no case that runs the block was
  altered to accommodate the move.

  **Why the claim could not move with it.** This repository records that a comment
  arguing against the code beside it is an instruction, and it will be followed —
  which is exactly what has stopped later sessions "simplifying" these shapes back
  into regressions. Separating the argument from the code weakens that, so the
  claim stays and only the evidence leaves.

  **And the separation is watched.** `test-pr-skill-contract.sh` fails if a `# WHY:`
  names a section that is not there, if a section is pointed at by nothing — the
  rot that goes unnoticed, because nothing reading the skill would reach it — or if
  a pointer drifts off the claim it belongs to. One assertion moved with the prose
  it was reading rather than being dropped.

  What it does **not** check is the rationale's own Markdown shape. A parser and
  then a set of `grep`s forbidding the constructs that make a `grep` lie were both
  built and both removed: each attracted the next construct without converging, and
  `CLAUDE.md` records what a scanner of that kind cost this repository once already.
  So `SETUP-RATIONALE.md` asks for plain prose and four-space-indented transcripts
  rather than enumerating what is forbidden, and the contract is the bijection and
  nothing else — exact string comparison, no grammar anywhere. What that gives up
  is a document edited so a heading is hidden or faked, which is visible in a diff
  as the mangling it is, and is not the drift the split risks.

  Closes #192 for this block. The remaining blocks hold ~7k tokens between them and
  are not touched here.

## [2.0.66] — 2026-08-25

- **The one-line origin check matched a newline followed by four spaces, not a
  newline.** The pattern was a quoted string spanning two source lines, and the
  second was indented to match the block — so `${RB_REMOTE%%'…'*}` stripped at
  `"\n    "` and stripped nothing from a value whose second line began with
  anything else. The comparison was then true and a multi-line origin passed the
  check that exists to refuse it. Measured: staging one reached the pin.

  It is `[[ $RB_REMOTE = *$'\n'* ]] && RB_REMOTE=` now — a containment test rather
  than a strip-and-compare, with the quoting handled by the parser and no second
  expansion to get the indentation of wrong. The old form said the same thing
  twice and only one of the two was right.

  What this guards is the unknown rather than the case it was added for: the value
  comes back in a file the helper names, so nothing known writes to the stream any
  more. That is why it went unnoticed, and it is not a reason to leave a check that
  does not do what it says. Closes #183.

## [2.0.65] — 2026-08-25

- **The three checks after setup reads the origin were guards, and a guard has no
  containment at all.** Each was written

  ```bash
  <check> || { echo "ABORT: …"; exit 1; }
  ```

  and a startup file that defines `exit` as a function which RETURNS makes the
  group print and the next statement simply run. There is nothing to fall out of:
  a `||` list is a statement, not an arm. So an empty origin, a multi-line one, or
  one the identity parser rejected went on into the parse, the export and the pin
  — and with `echo` shadowed as well, the same shape that made 2.0.64 necessary
  applies here, with the forged value reaching every post of the session.

  Each is a shell-level refusal now. The empty check IS `${RB_REMOTE:?…}`, which
  fires on exactly the state it tested, so the check and the refusal are one thing
  the shell does. The other two clear `RB_REMOTE` with an ASSIGNMENT — handled by
  the parser, so nothing can shadow it — and expand it after. No command in any of
  the three, and nothing after them to walk into.

  **Every one of them is carried by an assignment rather than by `: "${…}"`, and
  that is not a style choice.** `:` is a NAME. Written `: "${RB_REMOTE:?…}"`, the
  refusal path is safe — the expansion fires and no command runs — and the
  ORDINARY path invokes a function called `:` with the authenticated value as its
  argument, on every session where the origin is fine. One that assigns
  `RB_REMOTE` replaces the value after every check has passed it and before the
  identity parse, so setup reports success and pins the session to another
  repository. `RB_REMOTE="${RB_REMOTE:?…}"` has no command in it and introduces no
  new name.

  What you see changes shape again: these announce themselves with your shell's
  name, a line number and `RB_REMOTE:` rather than with `ABORT:`, which is what
  every other refusal from READING the origin already looked like. The pin and the
  working-file refusals below them keep the plain `ABORT:` line, and correctly:
  their success arms contain everything that follows, so nothing runs after them
  either way. The multi-line one no
  longer prints the value — the word is expanded after the clear — and printing a
  multi-line value into the terminal was never the useful part of it.

  Closes #181. The multi-line check's PATTERN is a separate defect and is #183: it
  is written across two source lines, so it matches a newline followed by four
  spaces rather than a newline.

## [2.0.64] — 2026-08-25

- **Three of setup's refusals could be talked past by a shadowed `echo`.** Each
  was written

  ```bash
  echo "ABORT: …"
  exit 1
  [[ -n "" ]]
  ```

  and the `[[ -n "" ]]` is containment: where `exit` has been replaced by a
  function that RETURNS, it ends the enclosing `if` list false so the arm cannot
  fall through into the success path. It does not contain an `echo` that forges a
  value and neuters `exit` in the same body — `echo` runs FIRST, so the assignment
  has already happened; `exit` returns; the containment does exactly its job; and
  execution continues past the whole block with an attacker URL in `RB_REMOTE`.
  The identity checks that follow validate the URL's FORM, not where it came from,
  so a well-formed one passes them and every request, signoff, revocation and merge
  for that session is addressed at the attacker's repository.

  Each arm now begins with `${RB_REMOTE:?…}` — the shell refusing to expand, which
  runs no command, so there is nothing to shadow, and a non-interactive shell ends
  there. The `echo` and the `exit` stay behind it as the shape every arm in the
  block has. The fix is ORDER rather than another check, and it works because
  `RB_REMOTE` is provably empty on all three paths: the read-back is the only thing
  that assigns it, and the clear far above is a CONDITION with the whole block as
  its arm, so a value a startup file pre-set never reaches them.

  What you see when one fires changes shape: the line now begins with your shell's
  name and `RB_REMOTE:` rather than with `ABORT:`, which is what the origin-read
  abort has looked like since 2.0.59 and what `README.md` describes.

  It is the four ARMS, not the whole block. The `|| { echo …; exit 1; }` guards
  after the read-back — the empty origin, the multi-line one, the identity, the
  pin — are the same class and are not fixed here: `${RB_REMOTE:?…}` has nothing to
  fire on where `RB_REMOTE` is already set, so they need a mechanism this change
  does not supply. #181 carries them.

  Closes #178.

## [2.0.63] — 2026-08-24

- **A `TMPDIR` that cannot hold a directory no longer ends the session.** Setup
  picks the transport parent on mode bits — `-d`, `-w`, `-x` — and prefers
  `TMPDIR`. Those describe neither a filesystem that is full, over quota or
  read-only nor a name another account got to first, and the fallthrough to `HOME`
  happened on the BITS rather than on the failure: any of them refused the session
  with a perfectly usable `HOME` sitting beside it untried.

  Setup now tries a directory under `TMPDIR` and, where that is refused, one under
  `HOME`. **The refusal is announced; the retry is not.** The helper's own `ABORT:`
  line names the directory and the reason, so nothing is routed around in silence —
  which is what the old candidate loop got wrong — but there is no note saying which
  parent the session ended up on. A note would be an `echo`, `echo` is a name in the
  driving shell, and every position for it is before something that trusts a
  variable: in the call's condition it precedes `$RB_SCRIPTS` being expanded, and
  after the read it precedes the identity checks, where a function that assigns
  `RB_REMOTE` replaces the value just authenticated.

  **It is a second CALL, not a second candidate passed to one.** The helper cannot
  tell the driver which of two candidates it used: a second success status would
  put a status branch outside the arm holding the read-back, and a line on a stream
  would put the value's own channel into a capture. A single call would therefore
  leave the driver guessing from a name that is public in argv, and every test of
  such a name is a check-then-use — three defences were built for it and all three
  refuted. An `elif` reads the first call's status IN ITS OWN CONDITION —
  `elif [[ $? -eq 2 ]] && …` — which is inside the same `if`, so nothing becomes a
  statement after a guard, and each arm names the directory the
  helper just created, so there is nothing to guess and nothing to race.

  The read-back is written twice, which is the price. A function would hold it once
  and cannot be used here: `return` is a name a startup file can replace, and
  `readonly -f` makes the document's own definition fail so an inherited one runs.

  The pin probe retries the same way, because half a retry is none: the origin read
  succeeding under `HOME` while that probe still refused on `TMPDIR` would end the
  session one step later.

  **The parent that worked becomes the primary one**, which is what makes this a
  fix rather than half of one: `RB_TMPPARENT` is what the pin probe and the
  session's working directory are built from, so leaving it on the parent that just
  refused read the origin from `HOME` and then died allocating the working
  directory under the same full `TMPDIR`.

  The abort counts nothing and recommends nothing: each `ABORT:` line above it is
  one attempt and its reason, and there may be one or two, since the retry runs only
  where the first refusal was about storage. It cannot know which — the three ways
  to reach it differ and telling them apart there needs the first call's status in a
  variable, for a claim the operator can read off those lines. It does not DIAGNOSE
  either: the directory is created
  exclusively, so two names simply being taken produces the same pair of refusals
  as two full filesystems, and the helper's own lines are what tell them apart.

  **`pr-origin.sh`'s optional second-candidate argument, added in 2.0.62, is
  removed again.** It was built for the single-call design this replaces, and
  nothing consumes it: an installed helper whose contract promises a distinction no
  caller can act on is worse than one that does not offer it. The helper takes one
  directory, as it did before 2.0.62.

  **Only a storage failure is retried.** `pr-origin.sh` reports **2** where both
  ancestry walks passed and the storage would not take what it asked — the directory
  could not be created exclusively, or the leaf inside it could not be written: a
  full filesystem, a quota, a read-only mount, a name another account got to first.
  It reports **1** where the refusal was about the path or the checkout. A 1 is terminal: another parent
  fixes none of those, and stepping past one is what the driver's old candidate loop
  did wrong.

  **The two write refusals name storage too**, because the operator is told to read
  each `ABORT:` line and they gave exactly two causes — the name being taken, or a
  symlink — neither of which is a full filesystem. On the first of two attempts that
  is the wrong reason for the failure the retry then recovers from.

  The driver reads that status in the retry's own condition —
  `elif [[ $? -eq 2 ]] && …` — which is inside the same `if`, so the read-back stays
  contained in the arm that names its directory rather than becoming a statement
  after a guard. Closes #161.

  It MITIGATES #160 without closing it. A squatter who pre-creates the
  argv-published first name costs a retry rather than a refused session — but an
  account watching argv continuously can pre-create the second name as well, and
  both parents being one shared sticky directory is a configuration the selection
  allows. The distinct suffixes prevent an accidental collision, not a watcher.

## [2.0.62] — 2026-08-24

- **`pr-origin.sh` takes a second transport directory and falls back to it.** The
  parent of the first is chosen on mode bits — `-d`, `-w`, `-x` — and those
  describe neither a filesystem that is full, over quota or read-only nor a name
  another account got to first. Any of those refused the session with a perfectly
  usable second parent beside it untried.

  The retry is here rather than in the driver because only this process runs both
  the `mkdir` and the ancestry walk, and the two failures must be told apart: a
  sound ancestry that could not be reserved falls through to the second candidate,
  while an ancestry the walk refuses — an account owning a component, a
  world-writable non-sticky one, an ACL — is reported and stops. Stepping past
  that is what the driver's old candidate loop did wrong.

  Nothing changes for a caller that passes one directory. The driver still does;
  wiring it up is the next change — and when it does, the status-0 contract is
  that ONE of the candidates is the directory that was created, the second unless
  a third was passed and the first could not be reserved. The caller tests for the
  leaf under the second candidate and reads the first where that is absent. Which
  one it was is not announced: putting the value's own channel into a caller's
  capture is what the file transport exists to avoid, and a second SUCCESS status
  would put a status branch back on the driver's side.

  That rule is sound in two halves. A second candidate that ALREADY EXISTS is
  refused before either is attempted — the our-own half, because a leaked leaf
  from an earlier session is a file the operator owns and no ownership test can
  tell it from a fresh one. And the fallback's IMMEDIATE PARENT must be this
  account's alone — the another-account half, because the existence probe is a
  check-then-use and ownership does not save a caller there: a symlink to another
  operator-owned transport passes `-O` and `-f` by following it to a file the
  operator really does own. The immediate parent only: sticky stops another account from RENAMING or deleting an entry it does not own, and does not stop them CREATING a new name — and
  creating is all that attack needs. So `/tmp` is fine ABOVE the parent and not
  fine AS it.

## [2.0.61] — 2026-08-24

- **Two installed scripts said the bash 3.2 CI job was switched off.** It is on
  again, so `pr-ci-gate.sh` and `pr-merge-gate.sh` no longer qualify "the
  `macos-shell` CI job covers `scripts/`" with "only while it is enabled". Nothing
  a user runs changes; what changes is which coverage the comments claim, and both
  of them are arguments for why the code moved out of `SKILL.md` in the first
  place — a reader who believes the weaker claim has a weaker reason.

## [2.0.60] — 2026-08-24

- **The portable watchdog gave the bounded command no standard input.** Where GNU
  `timeout` is missing — stock macOS, and the bash 3.2 CI job by construction —
  `run_limited` runs its subject in the background, and a background job whose
  redirections do not mention stdin gets `/dev/null` from the shell. It was
  redirected there explicitly, so a bounded command that READS stdin received
  nothing.

  Nothing in the driver feeds a bounded command on stdin today, so no session
  behaviour changes. What it cost was the suite: every case in
  `test-pr-request-review.sh` feeds the request body that way, and all of them
  measured the empty-body refusal instead — invisible wherever `timeout` exists,
  which is why it survived until the bash 3.2 job was run again. `testlib.sh`
  ships inside `pr-ci-state.sh`, so this is an installed file and a release.

## [2.0.59] — 2026-08-24

- **The origin-read abort now tells you how to recover.** That abort is reached
  whenever `pr-origin.sh` refuses — an ancestor it will not trust, a path it
  cannot resolve, an `origin` the checkout does not have, or a transport directory
  it could not create or write — and the helper's own line above says which.
  Several of them you can repair; the storage one is the one the abort itself can
  tell you how to get past, and nothing said so.

  Setup picks the transport parent on mode bits — `-d`, `-w`, `-x` — and prefers
  `TMPDIR`. A `TMPDIR` that passes all three can still fail to hold a directory, or
  to take the file written into it: a quota reached on that filesystem, a full one,
  or a read-only mount none of those bits describe. The helper refused, setup
  printed a bare `could not read this session's origin`, and stopped — with a
  perfectly usable `HOME` beside it untried, because the fallthrough happens on the
  mode bits and not on the failure.

  The abort now names the step: **if the line above names a path setup could not
  create or write**, re-run — the same diagnostic covers a name another account got
  to first, where the filesystem has room. If that keeps failing, the filesystem
  may be full, over quota or read-only: re-run in a session whose `TMPDIR` points
  at storage with room, or with no `TMPDIR` at all so setup uses `HOME` — **which
  helps only where `HOME` is not on the same filesystem**. It keys on what the report names rather
  than on `TMPDIR` being set, because selection can reject a set `TMPDIR` and be
  using `HOME` already; it says a new session rather than `unset TMPDIR`, because
  that variable may be readonly and, if it is a nameref, `unset` destroys what it
  points at.

  It is emitted as a `${VAR:?…}` expansion rather than through `echo`, so the line
  you see now begins with your shell's name and `RB_REMOTE:`; the troubleshooting
  entry in `README.md` is keyed to that text. The driver
  runs in your own shell, where `echo` may be a function that returns without
  printing — and this line is the whole of what the change does, so an `echo` was
  the one shape that could silently undo it. The shell refusing to expand a
  parameter runs no command and has nothing to shadow.

  Nothing else changes — the automatic retry is #161, and it is not here because
  the driver would need three more assignable names in a shell where a startup
  file can make any of them readonly, and neither a function nor a status branch
  is available to it.

## [2.0.58] — 2026-08-23

- **The pre-push gate now refuses a fixture that pipes a `printf` into `grep`.**
  That shape is RACY under `set -o pipefail`, which every fixture sets: `grep -q`
  exits the moment it matches, `printf` takes `SIGPIPE` and dies with 141, and
  `pipefail` makes that the pipeline's status — so a line that IS present reads as
  missing, at whatever rate the scheduler decides. Measured at roughly one run in
  three on one file.

  It is worse than an intermittent failure. Where the status feeds an `|| x=""`
  capture, a good extraction silently becomes an empty one and every assertion
  built on it passes against nothing.

  None of the 511 converted assertions changes runtime behaviour — they are all in
  `test-*.sh`. What ships is `pr-selfcheck.sh`'s new check, and a contributor DOES
  see it: the pre-push gate has a new refusal, which is what this version names. It
  reports the shape rather than letting it back in, and the suite it gates stops
  failing for reasons that are not there.

  The check asks three substring questions of a folded LOGICAL line and parses
  nothing: does it name `printf`, does it carry a pipe that is not `||`, does it
  name `grep`. Folding matters — a pipeline continues across a `\` and across a
  bare trailing `|`, and both halves scanned separately read clean — and reporting
  the first physical line number keeps the finding useful. An input it cannot read
  exits 2, the could-not-run status, rather than reporting an actionable finding
  nobody looked for.

  **Everything narrower was tried first, and this is what it cost.** Six review
  rounds went into modelling grep's options — an option with an argument, a
  hyphenated argument, a quoted one, a dash-leading operand, `-e` attached to its
  pattern, `--`, `-qm1`, `--quiet`. Dropping the options bought one round: the next
  found `%b`, an unquoted `$fmt`, a quoted assignment value, `2>&1` before the
  pipe, `/usr/bin/grep`, and `myprintf` matching on its suffix. Every one of those
  was a fact about SHELL SYNTAX, and reading shell syntax out of text needs a
  shell. There is no spelling of `printf`, of a pipe or of `grep` that walks past a
  substring test.

  Nothing is lost by asking less: the herestring is the fix for `grep -c` and
  `grep -v` as much as for `grep -q`, and it is never worse. The thirteen lines in
  the tree that read to EOF were converted rather than exempted.

  The price is over-reporting, and it is paid where it can be seen. A line naming
  all three where the pipe is not the `printf`'s says `racy-pipeline-ok`; there are
  two in the tree. A false negative would be invisible, and this is not.

  **A producer's status travels with the conversion.** A pipeline reported a failing
  producer through `pipefail`; a herestring has no pipeline to report one from, so
  `grep -q X <<<"$(producer)"` discards it — and a producer that emits the expected
  marker and THEN fails leaves the reader matching and the assertion passing on an
  incomplete read. Every converted site whose producer is a command now captures the
  value and its status together and empties the value on failure, so a partial read
  cannot match. One of them failed OPEN before this: an unreadable `SKILL.md` yielded
  no lines, the search for `sort -V` found none, and the portability assertion
  reported clean on a file it never read.

  It is anchored on `printf`, and any other producer is review's job. Generalising
  to "a pipeline whose last stage is `grep -q`" was tried and reverted: `|` also
  appears in `||`, in `${x%%|*}` and inside quoted `awk` programs, and telling
  those apart needs a shell parser — the generalised version reported 140 false
  positives on a clean tree. A line that carries the
  spelling as DATA — a comment, a stub, a heredoc — says so with
  `racy-pipeline-ok`; nothing else is exempt. And a fixture the scan cannot READ is
  a finding of its own rather than a clean result, because `grep` exits 1 for "no
  match" and 2 or more for an error, and a blanket `|| true` made those the same
  answer.

---

## [2.0.57] — 2026-08-22

- **The origin transport was thirty-five lines of driver-shell defence for one
  string, and every one of those lines was a name the operator's shell could
  replace.** `SKILL.md` chose a parent, built a candidate path, prefix-checked it,
  created it with `mkdir`, derived the output file from it, proved three names
  assignable and removed both on the way out — all in the long-lived shell that
  `#!/usr/bin/env -S bash -p` exists precisely because nothing can harden.

  `pr-origin.sh` now takes the DIRECTORY and creates it itself, exclusively, at
  mode 700, having walked every ancestor to the root and refused one this user
  cannot exclusively write. The helper runs privileged, so `mkdir`, `git` and the
  ancestor walk are not names anything can shadow. What is left in the driver is
  the name it hands over and the descriptor it reads back.

  `RB_TMPDIR`, `RB_TRY` and `RB_PIN_OUT` are gone with it, and so are the
  `${RB_TMPDIR:?…}` expansions that stood in for a variable that could not be
  trusted. The identity block is 123 executable lines where it was 157.

- **A rejected transport read cleaned up twice.** The rejection arm removed the
  leaf and the directory and then `exit` — a name — returned, and the unconditional
  pair below removed them again. On a shared sticky parent a watcher that learned
  the candidate from the helper's argv can put a symlink at the freed name between
  the two, and the second `rm -f` follows it into a file this run never created.
  The read-back is a branch whose arms each clean up once.

- **The write-failure guards were only matched, not run.** The `/dev/full` cases
  went when the argument became a directory `mkdir` refuses, and nothing replaced
  the execution. `ulimit -f 0` with `SIGXFSZ` ignored is a portable substitute: the
  redirection creates the leaf and the `printf` into it fails, which is exactly the
  state the guards are for. Both modes are exercised, and each asserts the refusal
  names the write and the reserved directory is given back.

- **A refusal after the directory existed left it behind.** The helper's contract
  is now a directory it creates, so every refusal past that point — an unreadable
  origin, an empty one, a newline in it, a failed write — has something to clean
  up. The cleanup is one body with three ways in, each running it at most once: an
  ordinary refusal and any other abnormal end go through an `EXIT` trap, a SIGNAL
  goes directly from its own handler and then re-raises, and a SUCCESSFUL run does
  not go at all — it resets `EXIT` and leaves the directory for the caller, which
  is the point of the call. The trap is armed BEFORE the reservation is
  attempted, since `mkdir` is an external command and a signal while it ran left
  the shell dead and the child creating the directory. Two recorded facts and an
  ownership test are what make arming first safe: `RB_OWNED` after a successful
  `mkdir`, certain but late — a signal during that external command is handled
  once it returns and before the `&&` after it — `RB_PREEXISTED`, a `[[ -e ]]`
  taken before the traps are armed, and `-O` for a name another account holds. An
  EMPTY pre-existing directory owned by the operator is the case that needs all
  three: it passes every test a created one passes, and removing it would
  contradict the contract that a pre-existing argument survives untouched. Every signal is IGNORED before the cleanup begins, so one arriving during
  it can neither re-enter it nor interrupt it. `RB_PHASE` picks its shape:
  `rmdir` alone while no leaf can exist, leaf-then-directory once a write has
  happened. The driver does the same for the one refusal that is its own: a
  transport file that fails the ownership checks.

- **An abandoned assignment left the previous run's transport path standing.**
  `${VAR:?}` ends a non-interactive shell where it stands; interactively the shell
  survives, so the assignment that would have built this run's path did not happen
  and whatever an earlier run left in that name stood. Each destination is cleared
  immediately before its guarded assignment now, so an abandoned one leaves EMPTY
  — which the helper refuses by name — rather than a path from another session.
  The session's working directory carries the same requirement: its prefix check
  compares against `$RB_TMPPARENT`, so an empty parent made it read
  `[[ /watch-pr-work.X = /watch-pr-work.* ]]` and agree.

- **A pre-write refusal could delete a file it never created.** The ancestry walks
  run after the reservation now, and their refusal went through the same cleanup
  as every other — which removes the value file by NAME. On that path no value
  file exists, so the removal was a path resolution rather than a removal: an
  account able to write a non-sticky ancestor, which is exactly what the walk is
  detecting, could rename the reserved directory and leave a symlink at its name
  while the walk ran, and the refusal then followed it. The pre-write path gives
  the reservation back with `rmdir` alone, which refuses a symlink outright.

- **An interrupted helper leaked its directory.** The caller performs no cleanup
  after a non-zero status, deliberately — it cannot know who created the path — so
  a signal between the reservation and either end left a `watch-pr.*` directory
  behind for the life of the machine. A trap gives it back, and is disarmed on the
  success paths. It has the same two phases the refusals do: `rmdir` alone while
  no leaf can exist, and leaf-then-directory once a write has happened, since
  `rmdir` necessarily fails on a directory holding its leaf. The phase flips after
  the ancestry walks — where the name becomes trusted, and still before either
  write. The handlers re-raise rather than returning, because a trap REPLACES a
  signal's terminating action and one that returned left bash resuming the work it
  was killed during, and returning status 0 for a run somebody killed. The success
  paths reset `EXIT` alone: resetting the signal traps too left a window in which a
  `TERM` terminated the helper with no cleanup, and the caller removes nothing
  after a non-zero status.

- **Another account could keep a session from starting, repeatably — narrowed,
  and the remainder written down.** The
  transport directory's name is an argv entry, which `ps` and `/proc` publish the
  moment the helper starts, and the `mkdir` ran only after both ancestry walks. On
  a shared sticky parent such as `/tmp` another local account could read the name
  and create it while those walks ran, so the `mkdir` refused — for as long as they
  watched. The random suffix stops a name being guessed and does nothing about one
  being read. The directory is reserved first now, and a failed `mkdir` asks the
  walks why before refusing, so the precise diagnostic survives the reordering.

  That narrows the interval to process startup rather than removing it: the name
  is in argv, which is published at exec. Removing it entirely means the caller
  creating the directory, which puts a `mkdir` back in the operator's own shell on
  a name that shell may have made readonly or a nameref — the class #157 exists to
  remove. The remainder is a denial of service by an account already on the
  machine, it fails closed, and `pr-origin.sh` states it beside the ordering.
  #160.

- **A nameref from a transport name onto any other name replaced that variable
  with a path setup then deleted.** Thirteen names were found this way, one review
  round apiece — `HOME`, `TMPDIR`, `REPO_DIR`, `RB_SCRIPTS`, `PATH`, `HOST`,
  `OWNER`, `REPO`, `IFS`, the operator knobs, the reviewer logins, `GIT_DIR`,
  `CDPATH`. Consequences ranged from a corrupted `PATH` to `REVIEW_MERGE_STRICT`
  being replaced so the merge gate silently restored `--admin`, and from a
  `REPO_DIR` naming a deleted path to a `cd` that stopped searching the operator's
  configured roots.

  **The probes no longer enumerate,** and the machinery that kept the enumeration
  honest is gone with it — the tie to `pr-selfcheck.sh`'s `KNOWN` list, the derived
  assigned-names list, the per-arm coverage loops, and the two allowlist entries
  that existed only because the probes named those variables directly. The list could never be completed: it would
  have to union what the driver reads, what its tools read, and what the shell
  itself consults, and the last grows with the shell version. `${!name}` answers
  the question in one line — for a NAMEREF it expands to the target's NAME, and
  for an ordinary variable it is indirect expansion — so each probe assigns a legal
  variable name built from `$RANDOM` and requires `${!name}` to be empty. It is
  bash 2 syntax, so it works where `[[ -R ]]` cannot: an unknown unary operator
  inside `[[ ]]` is a PARSE error on 3.2, and the whole setup block would fail to
  parse there.

  The sentinel carries `$$` as well as `$RANDOM`, because `unset RANDOM` removes
  its special behaviour and would otherwise leave a FIXED `RbProbe` — back to a
  value an operator can hold, after which `${!name}` reads THEIR variable and a
  valid shell is refused. The pid cannot be unset.

  What that still does not stop is stated rather than chased: a startup file runs
  in the driver's shell, so it knows the pid and can read this source, and with
  `RANDOM` unset it can pre-seed the sentinel's slot and make the probe conclude
  "nameref". No mechanism there can close it — every input is public or unsettable
  by the same file — and the failure is fail-CLOSED: setup refuses, nothing is
  forged or pinned. A startup file that wants to stop the session can call `exit`
  in its first line.

  The randomised value also removes the collision the fixed sentinels had: an
  operator holding one sentinel from each of two fixed pairs failed both, and a
  shell nothing had corrupted was refused. The prefix match carries the other half,
  in MIXED case — a readonly leaves the old value, `declare -i` stores `0`,
  `declare -l` lower-cases it and `declare -u` upper-cases it, and an all-caps
  sentinel survives that last one unchanged, which is how it got through.

- **A nameref between a pin name and the transport parent replaced the parent.**
  The pin's probe compared only against the names that stage introduces, so
  `declare -n RB_PIN_SEEN=RB_TMPPARENT` passed both subshells — neither read that
  name — and the real pin read then assigned the inherited origin THROUGH the
  nameref, replacing the parent setup had just proved. For a local origin such as
  `/tmp/repo` the session's working directory was created inside that repository.
  Both subshells cross-check `RB_TMPPARENT` now, as the transport probe already
  did.

- **A shadowed `exit` could build the transport at the filesystem root.** With
  neither `TMPDIR` nor `HOME` usable the refusal was a GUARD, and `exit` is a name
  a startup file can replace with one that RETURNS: measured, the refusal printed
  and the next line built `/watch-pr.…` from the empty value. For a root operator
  the helper can create that, so setup read an origin from the filesystem root and
  went on to announce success. The parent is required by the expansion that spells
  the path now — `${RB_TMPPARENT:?…}` is the shell refusing to expand, which has
  no name in it and ends a non-interactive shell where it stands.

- **A refused helper had its transport read and removed anyway.** The read and
  both removals were statements after a guard, and `exit` is a name a startup
  file can replace with one that RETURNS. With it neutralised, a helper that
  refused because `mkdir` found the name already taken was walked past, and the
  lines below opened that directory's `origin`: a regular file owned by this
  user passes `-O` and `-f`, so the session was pinned from it — and the `rm -f`
  and `rmdir` after it then deleted a file and a directory this shell never
  created. Both are the helper's success arm now, on the read side and the pin
  side alike; containment is what a neutralised `exit` cannot step over.

- **An absolute but unwritable `TMPDIR` ended the session with a usable `HOME`
  next to it.** `-d` says the name is a directory and nothing more — `/usr`
  satisfies it — so the selection committed and the helper's `mkdir` then failed.
  The candidate loop this replaced did fall through in that state. The selection
  asks `-w` and `-x` as well, which is what "can hold a directory" means. A
  parent whose ANCESTRY the helper refuses is still reported rather than routed
  around: deciding that here means a second copy of the walk in the shell that
  cannot be hardened, and an unsafe ancestry is a state an operator has to see
  named.

- **`SKILL.md` still carried the removed loop as an instruction.** A hundred and
  thirty lines of commentary above the transport described what the driver used to
  do: both transport files in one directory this setup created, a `mkdir` here
  whose refusal moved to the next candidate, `HOME` tried whenever the helper
  refused, and probes over `RB_TMPDIR`, `RB_TRY` and `RB_ORIGIN_OUT`. A comment
  that argues against the code beside it is an instruction, and this one invited
  the deleted loop back. It is rewritten to describe what is there.

- **The transport parent is chosen inside the probe that proves it assignable.**
  A readonly `RB_TMPPARENT` makes the selection fail, and under `errexit` — which
  a driving shell may well be in — a failed readonly assignment ends the session
  at that line, with bash's own message and no diagnosis. Selecting inside the
  probe's success arm means the operator is told which name is unusable.

---

## [2.0.56] — 2026-08-22

- **A neutralised `exit` walked a readonly `RB_REMOTE` into pinning the session to
  the wrong repository.** `SKILL.md` clears the value the session is pinned by and
  proves the clear took — but `exit` is a builtin a startup file can replace with
  one that RETURNS, and the proof was a statement rather than a structure. With a
  `readonly REVIEW_BUS_REMOTE`-shaped value already in the driving shell:

  1. the clear fails and the value stands;
  2. the guard fires, prints, and returns;
  3. the descriptor assignment further down cannot replace it either, and its
     refusal returns the same way;
  4. the value is non-empty and well-formed, so the identity parser accepts it and
     `REVIEW_BUS_REMOTE` is exported from it.

  Every request, signoff, revocation and merge for that session was then addressed
  at a repository the operator's environment chose.

  The clear is a **condition** now, and everything that depends on the value — the
  transport region, the identity parse and the pin — is its success arm. The
  assignment stays outside it: inside a compound command a failed readonly
  assignment ends the shell *before* the test that would have named the variable,
  so the diagnostic has to live where its own failure is visible, and the TEST is
  what gates the arm.

  Verified with `exit` replaced by a function that returns: the refusal names
  `RB_REMOTE` and nothing is exported.

## [2.0.55] — 2026-08-22

- **A neutralised `exit` walked a refused setup into reading and deleting
  `/origin`.** `SKILL.md`'s setup runs in your own long-lived shell, and `exit` is
  a builtin a startup file can replace with one that RETURNS. Every refusal in the
  transport block then printed its message and carried on to the next line — which
  built `$RB_TMPDIR/origin` with `RB_TMPDIR` never set. That is `/origin`.

  The ownership test below it is `[[ -O ]]`, so for an operator running as **root**
  with a root-owned file there it passes: the value is read as this session's
  origin, the `rm -f` two lines down **deletes that file**, and every stage —
  signoffs, revocations, review requests — is then addressed by whatever
  repository it named. The cleanup arms are worse still: they run
  `rmdir "$RB_TMPDIR"`, which with an empty value is `rmdir /`.

  The directory is required by the **expansion that builds the path**:
  `${RB_TMPDIR:?…}`. A parameter expansion error ends a non-interactive shell
  where it stands — there is no command name in it to shadow and no `exit` to
  neutralise — and it names the variable while doing it.

  **Every use in the region carries it, not just the first**, and that is what an
  *interactive* shell forces. There `${…:?}` reports the error and abandons only
  the command it is in — the shell survives — so a walked-past refusal would
  continue into the cleanup arms, where `rm -f "$RB_TMPDIR/origin"` is
  `rm -f /origin` and `rmdir "$RB_TMPDIR"` is `rmdir /`. With the requirement on
  each of them, every one of those commands refuses on its own, and no bare
  `$RB_TMPDIR` survives past the loop at all — asserted as an absence, because a
  list of uses is wrong by omission.

  **And the directory itself is proved assignable before anything uses it.** The
  requirement only rejects an *empty* value; it does not prove this run
  established the directory. A readonly `RB_TMPDIR` naming somewhere the operator
  owns survives the clear and the loop's assignment, and its `origin` was then
  read as the session's remote and deleted by the cleanup — reachable
  interactively, where a refusal that merely reports is walked past. The probe is
  the one the three other transport names already had, and **the whole transport
  region is its success arm**, because interactively nothing else stops the walk.

  The clear of `RB_REMOTE` moved *above* that arm with its own proof. Inside a
  compound command a failed readonly assignment ends the shell before the test
  that would have named the variable, so the diagnostic has to live outside — and
  up there it has nothing to clean up, which is two fewer commands taking a path
  from a variable.

  **And each probe reads another name back, because reading its own cannot see an
  alias.** `declare -n RB_TMPDIR=RB_REMOTE` passes an assign-and-read-back probe
  perfectly — the assignment works and the value returns — and the two are then
  the *same variable*, so the origin read silently changes `RB_TMPDIR` before the
  cleanups run. With a local origin such as `/tmp/victim` they remove
  `/tmp/victim/origin` and try to remove `/tmp/victim`, and the identity parser
  rejects the value only afterwards. `RB_REMOTE` is cleared and proved clear just
  above, so writing a sentinel to one name and finding it in the other is the
  alias; each probe checks that way against `RB_TMPDIR` and `RB_REMOTE`, the two
  names that can redirect the origin read or the cleanups. An alias between
  `RB_TMPPARENT` and `RB_TRY` is not among them and does not need to be: the loop
  refuses it at its prefix check, so nothing is read and nothing is removed —
  what is lost there is the diagnostic, not the property.

  **And the path is spelled, not held.** `RB_ORIGIN_OUT` used to carry it, and a
  name that carries a path can be *stale*: its assignment is abandoned by the
  requirement whenever the directory is missing, and a value your shell already
  had — `/origin`, or anything else — then survived into the read, into `rm -f`,
  and into the unconditional cleanup. Requiring that name would not have helped,
  because a pre-seeded value is not empty. So there is no name: every use spells
  the path out of the directory it must come from, which cannot be stale because
  it is not consulted — and `pr-origin.sh`'s own header and `CLAUDE.md`'s entry
  for it, which both showed the driver invoking and reading through that variable,
  describe the spelled path now. A pre-seeded `RB_ORIGIN_OUT` is inert — the session
  pins from its own file and never touches the one that name pointed at, which is
  stronger than the refusal it replaces.

  The expansion and the containment do different jobs, and both are here. The
  `RB_TMPDIR` arm stops a walked-past refusal entering the region with a *stale*
  directory; the requirement stops one entering it with an *empty* one, from a
  refusal inside that same arm. What was tried and taken back is a third thing:
  moving the region into the `RB_TMPPARENT` arm, three levels in. Inside a
  compound command a failed readonly assignment ends the shell **before** the test
  that would have named it, so `RB_ORIGIN_OUT` and `RB_REMOTE` lost their own
  diagnostics to gain this one — which is why `RB_REMOTE`'s clear sits above the
  arm and `RB_ORIGIN_OUT` no longer exists at all.

  One thing about that message is load-bearing: it carries **no apostrophe**. Bash
  parses the `:?` word specially, so a `'` inside it opens a quote even within
  double quotes and the whole setup block stops parsing.

## [2.0.54] — 2026-08-22

- **`RB_TRY`'s probe read only a status, so a transforming attribute passed it.**
  The transport loop proves the candidate name assignable before it builds a path
  under it, and that probe asked whether the assignment *succeeded* — which covers
  a `readonly` and nothing else.

  A transforming attribute lets the assignment succeed and store something else.
  Measured on bash 5 with `nounset` off, which is the ordinary state here:
  `declare -i RB_TRY` evaluates `Probe-A` as `Probe - A`, both names are unset,
  and `0` is stored. The real assignment below the probe is then rewritten the
  same way, the prefix check refuses every candidate, and setup stops with the
  message about `TMPDIR` and `HOME` that describes neither — the misdirected
  diagnostic the probe above it exists to prevent.

  The value is compared inside the subshell now, which is what the other three
  probes have done since 2.0.53, and it is `Probe-A` rather than `probe-a`:
  already-lowercase text is left unchanged by `declare -l`, so a probe using it
  passes. `Probe-A` survives no case transformation in either direction, and the
  comparison is what rejects the arithmetic one.

  One value is enough. Two existed because a readonly pre-seeded with the probe's
  own value leaves a comparison *in the caller's shell* holding; in the subshell
  that same readonly makes the assignment fail outright, so the comparison is
  never reached.

  **And the probe moved out of the candidate loop, where its failure had nowhere
  to go.** Asked per candidate it could only `continue`, so every candidate was
  skipped and the emptiness check afterwards blamed `TMPDIR` and `HOME` — sending
  you to look at an environment that is fine, which is the misdirected diagnostic
  the probe above it exists to prevent. Whether this shell can assign the name
  does not change per candidate: it is asked once, before the loop, with its own
  refusal naming the variable, and the loop is that probe's success arm.

## [2.0.53] — 2026-08-21

- **The remaining assignability probes ended your shell in the state they exist
  to detect.** `SKILL.md` proves three names assignable before it uses them —
  the transport parent, the session's working directory, and the name the review
  baseline is read into — and each did it by writing a value and reading it back.
  Both halves are assignments in *your* long-lived shell, and measured on bash 5:

  ```
  $ bash -c 'set -e; readonly V=0; V=probe-a; echo REACHED'
  bash: line 1: V: readonly variable
  ```

  `REACHED` never prints. **A failed readonly assignment under `errexit` is
  fatal** — and the block is pasted into such a shell as often as it is typed — so
  the probe killed the session before the test after it could run, with only
  bash's own one-line complaint and none of the abort messages that say which name
  and what to do about it.

  Each is a subshell now, **with the comparison inside it**. It inherits the
  readonly attribute, so it fails for the same reason, and as a condition it is
  exempt from `errexit`. The comparison is what the read-back used to do and is
  still needed: a *transforming* attribute — `declare -i` on any of these names —
  lets the assignment **succeed** and stores something else (`probe-a` becomes
  `0`), which a status-only probe accepts. For the baseline that meant the request
  going out and the ordinary empty answer coming back rewritten.

  One value is enough now. Two existed because a readonly pre-seeded with the
  probe's own value leaves a comparison *in this shell* holding; in the subshell
  that same readonly makes the assignment fail outright, so the comparison is
  never reached.

  That value is **mixed case**, and deliberately. `probe-a` is already lowercase,
  so `declare -l` leaves it unchanged and a probe using it passes — then the real
  assignment lowercases the path and setup fails somewhere else, about something
  else. `Probe-A` survives no case transformation in either direction, and
  under `declare -i` — where `Probe-A` is evaluated as `Probe - A` and `0` is
  stored, so the assignment succeeds — the comparison is what sees that `0` is not
  `Probe-A`.

  `RB_TRY` is the fourth site and keeps the subshell it got in 2.0.52 without the
  comparison: it is pre-existing here, so the transforming-attribute gap is filed
  as its own change rather than folded into this one.

  The refusals name both attributes now, since the probe answers one question —
  can this name hold what this line writes — and two attributes make it "no".
  Saying only `readonly` sent the operator looking for one that is not there. And
  the transport parent's selection became its probe's success arm, like the other
  two: written as a guard it printed the refusal and then ran the loop anyway, on
  a name it had just reported unusable.

  The pin proof's own probe is deliberately unchanged: it is an `elif` chain that
  has to run before its `mkdir`, and the base ref records why stopping on the spot
  is accepted there.

## [2.0.52] — 2026-08-21

- **A readonly `RB_TRY` could put the transport directory outside the parent
  setup proved.** `SKILL.md` builds a candidate directory for reading origin and
  then checks the value it built — but the check matches a **prefix**, and
  `RB_TRY` is a name: a startup file that has already made it readonly makes the
  assignment fail, leaving whatever it was seeded with. A value such as
  `…/watch-pr.anchor/../elsewhere/session` satisfies the prefix while naming a
  directory under a parent nothing proved.

  `mkdir` resolves the `..`, and `mkdir` being the exclusion does not help — it
  excludes a name that already *exists*, not one that resolves elsewhere. Where
  the anchor and the target parent exist, another local account owning that parent
  can replace the directory, and the origin **every stage is addressed by** is
  then read from whatever that account left there.

  The name is proven assignable first, **in a subshell**. That matters because
  `SKILL.md`'s bash runs in your own long-lived shell, and a bare probe assignment
  would end it: measured on bash 5, a failed readonly assignment under `errexit`
  is fatal, so `RB_TRY=probe-a` on its own kills the session before the test after
  it can run — in exactly the state the probe exists to detect. A subshell
  inherits the readonly attribute, so it fails for the same reason and answers the
  same question. Its status is the whole answer, so no value has to be compared —
  and it is tested by `if`, which is where the `errexit` exemption comes from as
  well, a command run as a condition being exempt.

  The rest of the candidate is that `if`'s success arm rather than a
  `|| continue` after it. `continue` is a *builtin*, and one replaced by a
  function returning 0 takes the failure arm and then falls straight through to
  the next line — the assignment fails, the stale traversal value passes the
  prefix check, and `mkdir` runs outside the proven parent, which is the whole
  defect. `if` is a reserved word and nothing can stand in for it, so the work is
  somewhere a failed probe cannot reach.

  Found while fixing the same class in the session's working-directory
  allocation (2.0.51), where it was new code; this one was pre-existing, so it was
  filed and landed on its own.

## [2.0.51] — 2026-08-21

- **The opening review request had none of the rules every other posting site
  has.** It was eighteen lines of shell in `SKILL.md`, in a fenced block nothing
  executes — not the suite, not `pr-selfcheck.sh`, not the bash 3.2 job — and what
  those lines do is post the comment that, with automatic review off, *is* the
  review request. It is now `pr-request-review.sh`, with a fixture that runs it.

  It was also a second, weaker copy of what `pr-close-round.sh` does for every
  *later* round. That copy refuses a body starting a line with a marker the loop
  reads back as a record, and a body carrying a mention it did not write itself.
  The opening request refused neither — so the one body written from scratch,
  rather than assembled from a round's findings, was the one posted unchecked.

  Both failures are ordinary prose. A paragraph explaining this loop, or quoting a
  finding about it, that reproduces `**Review-Signoff:**` at the start of a line
  **creates that signoff**: the comment is posted under your identity, which
  `pr-signoff.sh` and `pr-round-count.sh` trust. And with automatic review **on** a
  paragraph quoting `@codex review` — out of an issue, out of a PR description —
  queues a second pass over the same head, which is the exact duplicate that path
  exists to avoid: the branch was written and then undone by the body it posted.

  Both rules come from `recordlib.sh`, so there is one definition and three
  callers rather than three copies. The trigger rule is the automatic path's
  alone: with automatic review off this script writes the mention itself, so a
  quoted one changes nothing, and refusing it there would forbid a PR description
  that quotes the loop.

  **The account never passes through your shell.** Writing it there would need
  `cat` or `printf`, and `SKILL.md`'s bash runs in your own long-lived shell where
  both are *names*: a function by either name receives the text and writes
  whatever it likes to the redirection, so the account validated and posted would
  be the function's, and one that writes nothing and succeeds stops a request that
  was fine. Carrying it in a heredoc instead is no better — a heredoc splices the
  account into shell source, so an account containing a line that is exactly the
  delimiter *ends* it and whatever follows is parsed by that shell, and `EOF` is a
  line this loop's own accounts quote out of a diff or a finding. A rarer
  delimiter narrows that without closing it, because the body is not known when
  the delimiter is chosen. So the session writes the file with its own file tool,
  which goes through no shell at all, and redirects it into the helper on stdin.

  **And no writable name carries the answer back.** The helper is run as a plain
  condition with its output redirected to a file, rather than captured into a
  variable: written as an assignment, a startup file that has already made that
  name readonly makes the assignment fail, which abandons the `if` without either
  branch running — so a request that was refused is followed by a wait for it. The
  same applies to the status, which is why there is no `REQ_RC`, and to the
  validator, which is a literal pattern rather than a variable holding one.

  The session's three working files — the round summary, the opening account and
  the baseline — are derived from **one** directory now, built by expansion and
  created with `mkdir` as the exclusion, the same answer the transport directory
  in setup already gives. Three `mktemp` calls were three separate answers, and
  `mktemp` is a *name*: a function returning the same existing empty path each
  time passes every validation and leaves all three paths aliased, so writing the
  opening account would populate the round-summary file — and a first round that
  missed its own summary write would post that account as the summary and request
  another pass, which is the regression the separate files exist to prevent.
  Derived by literal suffixes there is nothing a command could return to make two
  of them equal.

  The baseline is written **before** the request is posted, and the write's status
  is taken. `printf` can fail — a full filesystem under the file it is redirected
  to — and an `exit 0` after it masked that, so the driver read an empty or
  truncated value as the baseline and the watch would accept the *previous* review
  as the answer to a request just posted. Taking the status only works while there
  is something left to refuse with, and after the post there is not. Writing first
  costs nothing, because the driver reads the file only on success.

  Both baseline shapes are accepted, too: a reviewer's newest verdict arrives
  either as a submitted review, whose id is digits, or as a clean **comment** on
  the head, which `pr-review-state.sh` reports as `comment:<id>` and `pr-watch.sh`
  accepts. A digits-only test refused the second *after* the request had been
  posted, leaving a pass in flight that nothing waited for.

  Two smaller things came with it. The review mode is refused **by name** —
  `YES`, `true`, `on`, `1` and an empty value are each an abort, where a
  truthiness test silently took the manual path and posted a mention into an
  automatic-review repository. And the name the driver reads the baseline into is
  proven assignable *before* the request goes out: a readonly one makes that
  assignment fail after the mutation, which under `errexit` ends the shell with a
  pass in flight and no watch armed.

## [2.0.50] — 2026-08-21

- **A poisoned `PATH` is settled as a boundary, not left open as a defect.** The
  comment in `pr-origin.sh` said the case was *filed*; it now records the decision
  and its reasoning, so the next reader does not go looking for the fix that is
  coming.

  What it records: privileged startup stops `BASH_ENV`, stops imported functions
  and ignores `SHELLOPTS`, and does **not** sanitise `PATH` — nothing here can.
  `command -p` searches a default path holding the *standard* utilities, and
  neither `git` nor `gh` is one. A fixed list has to know where the operator's
  binaries live, which is the question `PATH` exists to answer. And "this `PATH`
  looks wrong" is unknowable, because a prepended directory is what a version
  manager does on every developer machine.

  So the loop trusts the `PATH` of the shell it was started from, exactly as it
  trusts that shell not to have run a hook before the first line — nothing inside
  a process can tell the honest version of something it inherited. The misreading
  it prevents is the one the issue was filed to prevent: **a `PATH` check in one
  helper is a defect rather than a fix**, because the other eleven would not have
  it.

  Both reviewer files carry the statement verbatim, pinned by the contract test,
  so a reviewer raising it against one script has an answer. Closes #91.

## [2.0.49] — 2026-08-21

- **"Is it clean" and "when did it land" are one question now.** `record` asked
  `verdict` and then `review-at`, and a result arriving between them was the one
  `review-at` timed — so the signoff could carry the time of a verdict nobody
  proved. Re-proving cleanliness afterwards closed that and left the next: a
  clean-to-clean transition paired the *new* verdict with the *old* time, and the
  ordering arm then refused a replacement signoff that was perfectly good.

  `pr-review-state.sh clean-at` answers both from the snapshot that proves the
  cleanliness. The authoritative record's timestamp now travels with the state and
  the id it was selected alongside, so no caller can be answered about two
  different reviews.

  **`review-at` is removed.** It had exactly one consumer, and a second, weaker
  answer to the same question is one a future caller reaches for — the same call
  `replies-at` got in 2.0.45. What its cases proved is proved on `clean-at`: the
  comment channel, the shape of the value, and every unreadable read.

  A `1` from `clean-at` is not an absence for this caller: `record` has already
  proved the head clean, so "no clean verdict" means it stopped being clean while
  this ran, and cleanliness is a precondition for recording at all.

  An **unreadable** answer degrades to a record without the field — but it costs
  the cleanliness proof too, because this call *is* the last one, and the proof
  before it predates a network round trip a blocking verdict can land in. So the
  cleanliness is asked for on its own there. That is two reads again, and not the
  pair this removes: nothing is being paired, because there is no time left to pair
  with.

  The separate cleanliness probe before the write is **gone**: it asked `verdict`,
  which is the question `clean-at` answers, so it established nothing the next call
  does not — while adding a way to fail, since a transient failure on it aborted
  the stage before reaching the arm that recovers from exactly that.

  Closes #139.

## [2.0.48] — 2026-08-20

- **A revocation is no longer lost under the signoff that superseded it.** The
  readers took the *last* record, so a revocation posted while `record` was
  proving — the way a phase is deliberately reopened — was overwritten by the
  signoff written next, and a later session found a current signoff and a clean
  verdict and opened Copilot underneath a phase somebody had reopened. `record`
  could narrow that window but never close it: its own write is what erases the
  evidence.

  The signoff says which verdict it answers, so **time decides instead**: a
  signoff stands only if no revocation is newer than that verdict. One belonging
  *before* it is the fault-tolerance pass being answered and is correctly ignored;
  one belonging *after* it correctly reopens the phase. Neither answer depends on
  which comment landed first.

  **Equal is not older, and unorderable is not permission.** `created_at` is
  second-resolution and the two records come from different resources, so falling
  back to position on a tie would give *"the signoff stands"* — the fail-open answer
  this rule exists to stop. A revocation in the same second as the verdict reopens
  the phase, exactly as `record` refuses to write over one.

  **Where there is nothing to compare, position decides**, and that is the rule
  that existed before: a signoff carrying `none` — every record written before
  2.0.47 — has no verdict to order against, and a revocation whose own time cannot
  be read cannot be placed. Neither is an unordered pair; both are an absent
  question. No pull request in flight changes meaning, because none of their
  signoffs carries the field.

  Where the revocation wins, the record printed is **its** time and **its** id:
  callers order records against each other by exactly those fields, so naming the
  signoff's comment would point at one that is not being acted on.

  Closes #122, on #135's record and #137's writer. #140.

## [2.0.47] — 2026-08-20

- **The signoff `record` posts now says which verdict it answers.** It already
  read that time to order a standing revocation against it; it asks on every path
  now and writes it into the marker, so a reader can order a *later* revocation
  against the verdict rather than against comment order — the window this stage
  cannot close itself, because its own write is what erases the evidence.

  **Its absence never stops the record.** The field is optional precisely so an
  unreadable probe degrades to a signoff without one, which reads back exactly as
  every record written before it does. A signoff that cannot be ordered against a
  revocation is the state that already existed; a phase that cannot close because
  a probe failed is worse, and this stage stopping is the expensive failure. It
  says so on stdout rather than degrading in silence.

  With a revocation standing the time is *not* optional — there it decides whether
  recording supersedes a reopening — and that arm still refuses.

  The marker is composed as two shapes rather than one with an empty pair of
  backticks: an empty field is a value `pr-signoff.sh` refuses, so writing one
  would make the record this stage just posted unreadable to the next reader.

  **The read happens before the record is looked at, not between that look and the
  write.** Placed after, it would sit where nothing had looked at the signoff
  record since — so a revocation landing during it is superseded on the ordinary
  path, a window this change would have *added*. Moving the read removes it: the
  revoked arm re-reads the record anyway, and the ordinary path again has nothing
  between its last look and its write.

  **And the time has to describe the verdict that was proved clean.** `review-at`
  reports the latest verdict on the sha, so a result arriving between the
  cleanliness proof and that read is the one it times — and the record would claim
  to answer a verdict nobody proved. Cleanliness is re-proved immediately after,
  and where it no longer holds the record is **refused**, not written without the
  field: cleanliness is a precondition for recording at all, while the timestamp is
  a value the record carries or does not, and dropping only the timestamp would
  post a signoff for a verdict that is no longer clean — worse than never having
  looked. The proof runs even where the time itself could not be read, because
  that failed read is a network call a blocking result can land during.

  The head is read **after** those two probes rather than before them. Both are
  pinned to the sha being signed off, so a push landing in either leaves them
  answering about a commit that is no longer the head — and the head check, read
  first, had confirmed a head the probes then outlived.

  #139 is the removal: one reader answering "clean, and at this time" from one
  response.

  Nothing reads the field yet. #137, for #122.

## [2.0.46] — 2026-08-20

- **A signoff can now say which verdict it answers.** Readers take the *last*
  record, so a revocation posted after a signoff supersedes it whatever it was
  about — and the writer cannot close that window, because its own write is what
  erases the evidence. `**Review-Signoff:**` takes an optional **third** backticked
  field, the time of the verdict being signed off, and `pr-signoff.sh` reports it
  as `verdict-at=`. A reader can then order a revocation against *that* rather
  than against comment order.

  **Optional, because every existing record predates it.** A reader that required
  it would report every signoff on every open PR as malformed, which is the
  fail-closed direction turned into a denial of service. It is reported as `none`
  where absent, so the record keeps one shape rather than two — and a value that
  is present and is not a time is refused as `bad_verdict_at`, since a reader
  ordering against it would place a revocation somewhere arbitrary.

  It is the first field of the record, before `at=`, `id=` and `sha=`: callers
  peel the sha with `${line##*sha=}` and the record time with `${line#* at=}`, and
  the character before `verdict-at=`'s three letters is a hyphen rather than a
  space, so neither peel can take it. A revocation carries it in the SECOND
  backticked field, having no sha — and a signoff **without** a sha but carrying a
  third field is refused as `signoff_without_sha` rather than skipped: the sha
  capture demands 40 hex, so a value in that position which is not one lands in the
  verdict field instead, and discarded, that marker stops being the newest record
  and an older signoff is returned with status 0.

  The shared reader knows the field: `recordlib.sh`'s signoff pattern accepts it,
  so the replies-only escape still recognises an operator's signoff. A fixture
  that stubs `pr-signoff.sh` with a record shape the real one no longer emits is
  how that would have gone unnoticed, and both callers' stubs carry the new shape.

  A **revocation** carries the field in the second backticked position, having no
  sha — and a value there that happens to be forty lowercase hex is captured as a
  sha, which a revocation cannot have, so that record is refused rather than read
  as one carrying no time.

  Nothing writes or reads it yet — the writer and the readers are the next two
  steps. #135, for #122.

## [2.0.45] — 2026-08-20

- **The replies-only escape asks one question instead of four.** It has to know
  which review it is, that its comments are all replies, when it landed and when
  its newest reply did. Asked as four probes and bound by re-reading each, every
  fix left the next window — a dismissal between two of them, a same-shaped
  replacement invisible to a verdict comparison, an id that is stable but not an
  id, replies that move without the comment count moving, a reply moving while the
  last probe is in flight. Five review rounds, one layer in each time, because a
  sequential guard cannot close a gap between sequential calls.

  **And no ordering of separate reads makes them one snapshot.** The REST
  endpoints answer reviews and review comments apart: with the comments read last
  a review dismissed afterwards is invisible, with the reviews read last a reply
  posted afterwards is, and alternating a third time only moves the race.
  `pr-review-state.sh escape-snapshot` asks GraphQL, which returns both in a
  **single response** — consistent by construction, with nothing to compare.

  `pr-merge-gate.sh` and `pr-phase-state.sh` ask once: the id, the review's time
  and its newest reply's arrive together or not at all. What is left is the gap
  *after* the response, which no protocol can cover — a signoff answers what had
  happened when it was written.

  A truncated page is unreadable rather than "not that shape": the reviews are the
  last hundred, so an earlier page could hold a draft that dominates, and a review
  with more than a hundred comments would have its newest one cut off.

  **`replies-at` is removed.** It shipped in 2.0.43 for exactly this consumer, and
  leaving a second, weaker answer to the same question is leaving one a future
  caller reaches for.

  What the callers do check is the SHAPE of that answer, through
  `rb_escape_snapshot`: peeled with expansions alone, a two-field line assigns the
  second value to both times, a four-field one hides a value, and a non-numeric id
  is dropped in silence — and the id is what proves the two times describe one
  review. Both times must be canonical UTC and present, because a successful
  snapshot is always a replies-only review and therefore always has both — while an
  *empty* reply field is the one shape the ordering rule accepts as "that channel
  had nothing to say", which is how a truncated helper would hide a newer reply.

  The five cases that used to sit in the two callers move to the reader's own
  suite, and change with the contract: they were windows between probes, and what
  they became is a single response that is malformed or truncated — a review node
  whose author, commit, state or time cannot be read, a comment whose reply link
  cannot, a page that was cut off. Every node is validated **before** any is
  filtered, because discarding a malformed *newer* review leaves an older
  replies-only one as the latest and its signoff then closes the phase.

  Closes #133.

## [2.0.44] — 2026-08-20

- **A reply added after an operator's signoff is no longer merged over.** The
  replies-only escape ordered the signoff against when the *review* landed, and
  the verdict is produced by the review's **comments** — one added afterwards does
  not move its `submitted_at`. Review at T1, operator reads the reply and signs
  off at T2, someone posts a retracting reply at T3: `T2 > T1` still held, so the
  signoff still vouched and the merge went through over a reply nobody read. The
  resumed phase closed on it too.

  What a signoff must now be newer than is the **later** of the two moments, which
  is `rb_answer_at` in `recordlib.sh` — either can be the last thing that happened,
  a review with no comments has only the first and a reply after the review has the
  second. Only the **reply** time may be absent, and absent is not zero: it means
  that channel had nothing to say. Both absent is a refusal, because there is then
  nothing for a signoff to answer at all — and in the escape's own context that is
  a *failed read* rather than an absence, since the review has already been
  identified by a numeric id and every submitted review has a validated
  `submitted_at`; a reply time with no review time is
  unreadable rather than a deadline of its own; and a value of a shape it cannot
  place is a third status again rather than something to sort.

  An unreadable reply time blocks rather than passing. Read as "no replies", the
  retracting reply it could not see is exactly what gets merged over — and a probe
  that reports *no replies* while printing one is refused rather than having its
  output discarded, since a discarded timestamp newer than the signoff is that
  same reply.

  And a timestamp of a shape nothing can place is a *third* answer, not the
  second: a probe that exits 0 with something it did not mean is a read that
  failed, and reporting it as "nobody signed this off" sent the operator to record
  another signoff instead of looking at the probe.

  The refusal names the **conversation**, not the review: the deadline is the later
  of the two, so a signoff that *is* newer than the review can still fail here, and
  saying "the review at <T>" pointed the operator at an event they had already
  answered with a timestamp that was not the review's. Both times are printed, so
  which one moved is visible.

  **The deadline is bound to one review.** Both callers read the review id before
  the timestamps and again with the verdict, because a verdict record carries no
  id: a second replies-only review with the same finding count, submitted on the
  same head, serialises byte-for-byte identically, and a binding that compared
  only the verdict accepted the old review's timestamps for the new one.

  The id is checked for SHAPE on both reads, not merely for being non-empty: a
  replaced helper exiting 0 with the same word twice is a stable value that
  identifies nothing, and the two reads then agree exactly as the verdicts did.

  **The reply time is re-read too**, because the id and the verdict can both be
  unchanged while the replies move: one added after `replies-at` returned and
  another deleted before the re-read leaves the comment count — and therefore the
  serialised verdict — exactly as it was.

  **The verdict is re-read afterwards, bound to the deadline just computed.** The
  two time probes are separate calls: a review dismissed after `review-at` returns
  and before `replies-at` runs leaves the second reading a stable — but
  dismissed — snapshot, so the deadline describes a review that no longer
  authorises anything while the replies-only line being answered was fetched
  before any of it. Each probe re-checks *itself*; the verdict is what binds them.

  **A reply time with no review time is a contradiction, not a deadline.** Replies
  hang off a submitted review and every submitted review has a validated
  `submitted_at`, so the reader that answers with a reply time has selected a
  review the other reader must also have found. Taking the reply alone was what
  hid a later review: a signoff posted after that reply but before the review was
  submitted would have been accepted as answering it.

  `SKILL.md` says to record the signoff *after* reading, and the reviewer contracts
  say that a reply posted later restarts that clock — which is one more reason to
  put a clean verdict in the review body, where it needs no answer at all.

  Closes #129, on #130's reader.

## [2.0.43] — 2026-08-20

- **`pr-review-state.sh replies-at` — when the newest reply landed.** A
  replies-only verdict is produced by the *comments* on a review, and one added
  afterwards does not move the review's `submitted_at`. An operator's signoff
  ordered against `review-at` alone therefore still vouched when a retracting
  reply had arrived between the review and the signoff — the reply nobody read
  merged over.

  Nothing reported that time, so nothing could compare against it. This adds it:
  the maximum `created_at` over the same comments the replies-only decision
  already fetches, validated by the same rule, with the three answers kept apart —
  the time, "nothing to order against" (no review, no comments, or a verdict that
  arrived as an issue comment and therefore carries none), and unreadable.

  The fetch's status is taken on its own line even though `pages_or_error` refuses
  an empty read: a `--paginate` run that prints a page and then fails on a later
  one still *parses*, and the answer would be a maximum over half the comments.

  And the review snapshot is read **again** afterwards, because the comments were
  fetched for a review the call has already stopped looking at: dismissed or
  superseded in between, the answer describes the old review's replies while
  presenting itself as the current one. `clean_verdict` re-checks for the same
  reason, on the same pair of fetches.

  No consumer yet — #129 wires it, and lands next. #130.

## [2.0.42] — 2026-08-20

- **A resumed session no longer reopens a phase the operator already answered.**
  A review whose comments are all replies reports `verdict=findings` with
  `source=replies-only`: there is nothing to fix and it is not a signoff, so
  `pr-review-state.sh verdict` exits 1 — the same status as a dismissal. Only the
  record tells them apart, and `pr-phase-state.sh` did not look: it reported the
  review as withdrawn and sent the operator to request a review of a head they had
  already read and signed off. That is the deadlock the escape exists to end,
  arriving one stage earlier than the merge gate where the escape lived.

  **The rule is in `recordlib.sh` now.** `rb_replies_only_line` is what that
  record looks like — matched in full, because a `*` between `findings=` and the
  suffix accepted an empty count and any field anyone appended, and this shape can
  authorise a merge. `rb_signoff_answers` is what "this signoff answers that
  review" means: it must name the head and be recorded strictly **after** the
  review, since one written for an earlier clean review on an unchanged head would
  otherwise vouch for a later replies-only one nobody read. Equal is a refusal —
  second-resolution timestamps cannot order a tie, and this is permission to merge
  or to close a phase.

  Neither fetches anything. The callers read the records with their own error
  prefixes and their own statuses; what they share is the rule.

  A third copy turned up when the rule moved: `pr-watch.sh` asked the same
  question as a `case` on the tail to decide its status 4. It asks the library
  now, and the drift guard fails on a helper that re-implements the shape.

  The phase helper says which of the two it found: a replies-only review nobody
  signed off reports `*_replies_only_unvouched` and names why, rather than calling
  it a dismissal — and an **unreadable** probe is a third answer again, reported as
  `*_vouch_unreadable` with status 2, because folding it into "nobody signed this
  off" tells the operator to record a signoff they may already have recorded.

  **The whole signoff record is parsed, not its suffix.** Reading the sha with
  `${line##*sha=}` and looking for a shaped `at=` accepts any rc-0 line that *ends*
  in the right commit, so a truncated, cached or misrouted record for another PR or
  another reviewer authorised the merge. A revocation fails it too, and should.

  **`pr-watch.sh` decides the shape once.** A record that declared
  `source=replies-only` and failed the shared predicate — `findings=0`, say — was
  classified as an ordinary findings verdict and exited 0, so a caller branching on
  the status acted on an answer nothing had validated. Either it is that record or
  the verdict is inconsistent.

  What remains is #129: the signoff is ordered against the *review*, and a reply
  added after it does not move the review's timestamp.

## [2.0.41] — 2026-08-20

- **A verdict record is checked, not just the status it came with.**
  `pr-review-state.sh` answers in one line, and its exit status is not the whole
  answer: a wrapper that truncates stdout, a stale cache or a misrouted call
  leaves an rc of 0 with a line about another PR, another reviewer or an older
  head. `pr-merge-gate.sh` and `pr-watch.sh` each validated the shape and the
  identity; `pr-phase-state.sh` did neither, so an rc-0 answer that was empty or
  about something else read as "the phase still stands" — and that answer
  licenses a merge exactly as the gates' do.

  **The rule is in `recordlib.sh` now, not in a third copy.** Every field check
  in that library started as two or three inline copies and every one was found
  missing from at least one; a third regex here would be the same defect at a
  larger scale. `rb_review_record` parses the line for a **named** field — the two
  questions have different ones, and a caller that got the other has asked
  something it is not about to read — and hands the tail back rather than
  accepting it, because what may follow differs per question and swallowing it
  centrally would accept any field anyone ever appends.

  `rb_review_record_is_about` takes the head **whole** and compares it at the
  record's own width, so the `${head:0:7}` each caller used to write — a second
  place for the width to be wrong — is gone, and a record that grew to forty hex
  would be compared at forty rather than matched on its first seven. It does not
  resolve a prefix collision: a seven-hex record is compared at seven, and only a
  wider record could tell two heads sharing that prefix apart.

  **The merge gate's two literal reconstructions go too.** It did not carry a
  regex — it rebuilt the line it expected, `sha=${2:0:7}` and all, and compared
  against that. A second definition written as a string is invisible to a scan for
  a regex, and it pinned the width where every other caller did not.

  The tail is the caller's rule and `pr-phase-state.sh` states it: `verdict=clean`
  with the `findings=0` truncated away is not a clean answer, and read as one it
  closed the phase on a record that was cut short. Spelled out rather than made
  optional, so a field nobody defined is refused too.

  The drift guard in `test-recordlib.sh` fails if a helper re-implements the shape
  inline.

## [2.0.40] — 2026-08-20

- **The recipe a resumed session runs is a script now, and it has a test.**
  `SKILL.md` § *Resuming after a stop* was 112 lines of shell inside a Markdown
  file — three arms and six refusals that nothing in the suite, `pr-selfcheck.sh`
  or the bash 3.2 job could reach, because all of them stop at the edge of a
  fenced block. It is `pr-phase-state.sh`, and `test-pr-phase-state.sh` executes
  every one of those paths.

  **Every abort in it exited 0**, because the driving shell must not die on a
  refusal. So "the phase is not closed", "the signoff could not be read" and "this
  ran correctly" were the same status to anything that read it, and a driver that
  branched on the status could not tell them apart. The helper answers 0 for a
  phase that still stands, 1 for one that does not, and 2 for an answer it could
  not read — and that third one is neither of the others: read as "no signoff" it
  repeats a phase, read as a signoff it skips a review nobody did.

  What it decides is unchanged. Before the Copilot phase the head must *be* the
  commit Codex signed; after it the head has advanced through Copilot fixes by
  design, so the Copilot signoff is the one that must name the head — and the
  branch turns on which signoff describes the head rather than on whether a
  Copilot record exists, because a stale one naming an older commit used to select
  the post-Copilot arm and then report that neither phase was closed.

  The shape check on a resumed sha now goes through `recordlib.sh`'s
  `is_full_sha`, so what a commit is has one definition here as everywhere else.

  **No variable holds the status.** The driver read it as `cmd; RC=$?` and
  branched on `$RC` — two ways for the distinction to be lost before it was used.
  With `errexit` on, and this block is pasted into a script as often as it is
  typed, a simple command that exits non-zero ends the shell *before* the
  assignment; and a startup file that had already made that name readonly with the
  value 0 made the assignment fail while leaving it at 0, sending a refused phase
  through the continuation into the merge flow. A failed assignment does not even
  fire an `||`, so there was no status to take. The helper runs as an `if`
  condition, which is exempt from `errexit`, and its status is branched on in the
  `else` where it is produced — so there is no variable to pre-seed.

  **A refusal cannot fall into the continuation.** The driver's branch on the
  helper's status runs in the operator's own shell, where `exit` is a builtin a
  function can take the place of — and one that returns instead of exiting left
  both refusal arms falling through into the sha read and everything after it, so
  the distinction held right up to the point where it mattered. The continuation
  lives inside the continue arm now, so there is nothing after the branch to fall
  into, and each refusal arm ends in a reserved word.

  **"Not clean" and "could not read it" are told apart**, which the recipe's
  `-ne 0` test folded together. `pr-review-state.sh verdict` answers 1 for a
  verdict that is not clean — a phase to reopen — and 2 for reviews it could not
  read, which is not an answer about the phase at all; reported as the first, an
  unreadable endpoint sent the operator to re-request a review nobody had
  dismissed.

  First of #26's sub-issues; #123.

## [2.0.39] — 2026-08-20

- **A revocation that lands while `record` is proving no longer gets superseded.**
  Another session posts `Review-Signoff-Revoked` while the head is unchanged and
  GitHub still serves the old clean verdict, so the head and verdict re-reads pass
  — and the signoff written next takes precedence, because the readers take the
  last record. A later `open` then requests Copilot underneath a phase somebody
  deliberately reopened.

  **It is refused by ORDER, not by presence.** Refusing on any revocation was
  tried and breaks the legitimate path: the fault-tolerance pass posts its
  revocation *before* requesting the review, so that record is newest when the new
  clean verdict arrives — this pass is answering it, and an unconditional refusal
  meant a reopened phase could never record its replacement signoff at all. The
  rule is that the phase is reopened when the newest revocation is **later** than
  the verdict being signed off, and only then.

  Both timestamps are canonical UTC, which `recordlib.sh` enforces on every record
  either side, so the string order is the time order and no date arithmetic is
  needed — a parse here would be a second definition of a rule those validators
  already hold.

  **Equal is a refusal**, and it is the one case this cannot decide: `created_at`
  is second-resolution, and the two records come from different resources — an
  issue comment, and a review when the verdict was one — so their ids are not
  comparable and cannot break the tie. Refusing costs a rerun once the clock has
  moved; recording would supersede a reopening somebody meant.

  **A missing or oddly-shaped time is a refusal too**, on either side, and that is
  not defensive padding: these are compared as strings, so a value of another
  shape sorts somewhere arbitrary — and one sorting low reads as "the revocation
  is older", which is exactly the answer that records over a reopening. The
  field's presence is checked before it is peeled, because `${…##*at=}` on a
  record without `at=` returns the whole line and `%% *` then yields
  `PR_SIGNOFF`, a non-empty value that is not a time and sorts below every real
  one.

  Nine cases, and the verdict's time is asked for only when a revocation is
  standing — a reader that failed there would otherwise stop every ordinary phase.

  **The record compared is read after the verdict's time, not before it.** Asking
  once and then fetching the time re-opened the same window one level down: a
  revocation posted *during* that fetch was compared as the stale record the first
  ask saw, and the signoff went out over it. The first read is only the trigger for
  whether an ordering question exists at all — which is what keeps `review-at` out
  of the ordinary phase — and the record the comparison uses is read again
  afterwards, with nothing but the write behind it. A newest record that stopped
  being a revocation in that window is a refusal too: this stage cannot place what
  it was about to act on, and a rerun costs a round trip where guessing costs the
  reopening.

  **The ordering proof is the last thing before the write**, ahead of the final
  head re-read, because the two residues are not alike. A head that moves after
  its proof is caught downstream: `open` re-reads it and refuses a head that is
  not the recorded sha, so nothing is lost but a run. A revocation that lands
  after its proof is destroyed by the signoff posted next — the readers take the
  last record — and no later stage can find it. The unrecoverable one goes last.
  What remains after that is #122, and it is not closable as a pre-write check.

## [2.0.38] — 2026-08-20

- **The round gate pushed whatever branch the checkout was on.** `git push` with
  no argument sends the current branch, and the stage is given a PR number and a
  reviewer — it was never told which branch that PR is for, and never asked.

  It pushed `main`. Driving a round from a checkout that was sitting on the
  default branch — a `git checkout` had failed because a second worktree held the
  feature branch, so the shell stayed put — the gate pushed `main`, putting an
  unreviewed commit on it. The round was lost as well: the CI gate then waited for
  checks on a head the PR still did not have, so the summary was never posted and
  no review was requested. Two failures from one missing question.

  **The destination is named now, rather than checked and then left to
  configuration.** `git push origin HEAD:refs/heads/<branch>` names the remote and
  the one ref it may write, so nothing in `push.default`, `branch.<n>.remote` or
  `remote.<n>.push` can widen it.

  **And `origin` is proved to be the pinned repository**, because it is a NAME the
  checkout resolves: `remote.origin.pushurl` can send it elsewhere entirely, and a
  second checkout can define `origin` as another project — so the branch and fork
  checks would pass while the commit landed in a repository nobody asked about and
  the PR stayed unchanged. The effective push URL goes through `rb_identity`, the
  one parser, in a subshell so its globals cannot leak back, and the answer is the
  subshell's status rather than three values serialised through one string.

  That comparison is case-insensitive: `git@github.com:Acme/Widget.git` and
  `acme/widget` address the same repository, and comparing them exactly refused
  every push in that configuration. `shopt -s nocasematch` is safe in a helper for
  a reason specific to these files — they start `bash -p`, which imports no
  functions, so no builtin in them can be shadowed, which is what #101 and #83
  settled — and it is set inside the subshell so the option does not outlive the
  comparison.

  **Whether the PR is from a fork is asked of the API**, not derived from names.
  Comparing `headRepositoryOwner/headRepository` with the pinned owner and repo
  was the first version, and it is wrong on casing in exactly the same way;
  lower-casing needs a name — `tr`, or a bash 4 expansion the 3.2 job does not
  have — so the comparison is removed rather than fixed. `isCrossRepository` is
  the same question asked of the thing that knows, and an answer that is neither
  `true` nor `false` is a refusal — a branch-name check followed by a bare push
  is a guard over a call that can still go elsewhere, which is the shape this
  repository keeps deleting.

  The branch comparison stays for what it actually does: telling the operator they
  are in the wrong worktree, which is the case that caused this, rather than
  pushing their work somewhere they did not mean and reporting success. Both push
  sites use one refspec computed once, because one of the two being bare is
  exactly the defect.

  **The branch is read from the full symbolic ref, not `--short`.** That option
  shortens only as far as stays UNAMBIGUOUS, so a branch sharing its name with a
  tag comes back as `heads/release/2.0` while GitHub reports `release/2.0` — and
  the comparison then refused a checkout that was already on the PR's branch,
  leaving no way to close the round at all. Reproduced on git 2.55.
  `refs/heads/` is removed as a prefix, so a symbolic HEAD outside that namespace
  refuses rather than being rewritten into a branch name and pushed at.

  Ten refusals, each leaving nothing pushed — a different branch, a detached HEAD
  (where a push reaches no PR and the next step would wait for a head that never
  appears), an unreadable answer, an empty one — which is what a 200 with a
  missing field looks like, and why a status check alone is not enough — and a PR
  from a **fork**, where `origin` pointed at a same-named branch would put the
  round's fixes somewhere else entirely and report success; a cross-repository
  answer that says neither; an `origin` whose push URL is another repository; and
  a push URL that cannot be read at all; and a second push URL naming another
  repository, though the first is right.

  Twenty-three cases, all failing against the gate they replace, including two that
  assert the push's arguments verbatim — one per mode, since a refspec applied to
  only one site is the same defect halved.

  `SKILL.md` and `README.md` tell the driver and the operator to run the gate from
  the PR's checkout, and separate the two kinds of refusal: a wrong branch or a
  detached HEAD is about where you are standing and is answered by moving worktree
  and running it again, while a fork PR or a redirected `origin` is not — running
  it again changes nothing, so those stop for the operator. Both reviewer files
  carry the general rule, which is that a call that writes somewhere must name
  where. The Copilot head-lookup count
  now counts `headRefOid` reads specifically, since the branch read is a different
  question asked for a different reason and would otherwise move that number.

## [2.0.37] — 2026-08-19

- **The records now carry enough to order a revocation against a verdict**, which
  is what #115's remaining half needs and could not have.

  Two revocations read identically today: the one the fault-tolerance pass posts
  BEFORE requesting its review — still the newest record when the clean verdict
  arrives, so the pass is *answering* it and must be allowed to record — and the
  one another session posts AFTER that verdict, which *cancels* it. Refusing on
  both breaks the reopened phase; refusing on neither is #115's defect. The
  difference is ordering.

  **`pr-signoff.sh` reports `at=` and `id=` on a revocation**, as it already did
  on a signoff, and both records gain the comment id: `createdAt` is
  second-resolution, so two records made in the same second compare equal and the
  id is what breaks the tie. Omitting `at=` also meant one revocation replaced by
  another could not be told from the original. The fields go before `sha=`,
  because callers read the sha with `${line##*sha=}` and anything after it is
  swallowed into the value. A node without a `databaseId` is now malformed, for
  the same reason a node without `created_at` already was: a record that cannot be
  ordered is not a record this tool can act on.

  **`pr-review-state.sh review-at` answers from the comment channel too.** Codex
  submits a review when it has findings and an issue comment when it does not — it
  used a comment on #35 — so reading only `pulls/N/reviews` said "no verdict" on
  exactly the heads a clean pass covers, and an ordering check built on it would
  have refused the ordinary case. It now takes the later of the newest review and
  the newest clean comment, compared lexically because both are canonical UTC, and
  fails closed when either fetch fails. `verdict` and `state` have consulted both
  channels for a while; this command had not.

  Ten cases across the two fixtures, including both directions of the
  later-of-two comparison — a review after a comment and a comment after a
  review — so a helper that simply preferred one channel would not pass.

## [2.0.36] — 2026-08-19

- **`record` proves the phase again immediately before it publishes the signoff.**
  Two stages ran between the last proof and the irreversible post — the CI gate,
  which WAITS for checks to settle, and the round count — so that window is as
  long as a build.

  In it another session can post a `**Review-Signoff-Revoked:**`, which is how a
  phase is deliberately reopened. The signoff would then supersede it, because the
  readers take the last record, while GitHub keeps serving the old clean verdict
  until the new pass reports — so nothing this stage looked at earlier could see
  the reopening. A later `open` then finds a current signoff and a clean verdict
  and requests Copilot underneath a phase somebody had just reopened.

  Three checks now sit immediately before the post: the head is still the signed
  sha, Codex's live verdict on it is still clean, and the head again, LAST. That
  last read is not redundant — the verdict lookup is a network call, so the head
  can move during it, and the verdict is pinned to the signed sha so it stays clean
  and says nothing about the move. Reading the head only first would leave the same
  window one probe narrower.

  **Refusing on the revocation itself is deferred, and that is a correction to this
  change rather than a limit of it.** It was the first fix and it breaks the
  legitimate path: the fault-tolerance pass posts its revocation BEFORE requesting
  the review, so that revocation is still the newest record when the new clean
  verdict arrives — an unconditional refusal means a reopened phase can never
  record its replacement signoff at all.

  Telling the two apart needs the records to carry time, and they do not yet: a
  revocation this pass is ANSWERING landed before the verdict, one that would
  CANCEL it landed after, and `pr-signoff.sh` omits `at=` on a revocation so two
  compare equal — at second resolution even a timestamp needs the comment id
  beside it. That is #37's remaining defect and it has to land first, so this
  stage narrows the window rather than closing it, and says so where the check
  would have gone.

  Three cases leave nothing posted where they refuse — a push before the CI gate,
  a push during the later probes which only the final head read catches, and a
  withdrawn verdict — and all three fail against the previous stage. A fourth
  guards the legitimate path: a revocation already on the PR with a clean verdict
  must still record, which is the reopened phase completing.

## [2.0.35] — 2026-08-19

- **`review-at` reported "no verdict" when it could not ask.** It fetched and
  parsed in one expression, with the fetch nested inside the parse:

  ```bash
  at="$(printf '%s' "$(reviewer_reviews "$pr" "$who")" | jq -r … )" || { … }
  ```

  A nested substitution's status is discarded. A failed reviews endpoint prints
  nothing, `jq` reads empty input, and `jq` on empty input produces no output and
  exits **0** — so the answer was an empty string with status 0, which every
  caller reads as "there is no verdict on this head". The `||` looks like it takes
  the status and does; the status it takes is `jq`'s, and `jq` had succeeded.

  The merge gate orders records against this value, so an incomplete snapshot
  presented as a complete one lets a signoff recorded for an earlier clean review
  on the same head vouch for a later replies-only review nobody read. A head is
  not a moment, which is what this command exists to say.

  The fetch's status is now taken on its own line, as `head_review_snapshot` in
  the same file already did — this was one call site out of step with the rule the
  file follows. Four cases: a failed fetch exits 2, prints nothing on stdout
  (where a caller capturing a substitution would read a reason as a timestamp),
  names `reason=unreadable` on stderr, and a readable fetch still reports when the
  review landed, so a helper that always refused would not satisfy the other
  three.

## [2.0.34] — 2026-08-19

- **The control-line scan can no longer answer "clean" about text it never
  read.** `rb_reserved_marker_line` is what stops a round summary or a phase body
  quoting `**Review-Signoff:**`, `**Review-Signoff-Revoked:**` or
  `**Review-Pause-Acknowledged:**` — quoting one CREATES the record, since the
  readers scan the raw body and a fence does not hide a line that starts at column
  zero.

  It read its input through a heredoc, and a heredoc is backed by a temporary
  file. When one cannot be created the redirection fails, the loop never runs, and
  `return 1` reports "no marker" about text nothing has looked at — which both
  callers treat as permission to post. A control line would then be published
  under the operator's identity because a filesystem filled up: a failure
  indistinguishable from a clean answer, which is the one shape this repository's
  fail-closed rule forbids.

  **It is not a bash 3.2 problem.** Read from the sources: 4.4 has no pipe path at
  all and always writes a temporary file; 5.2 and 5.3 use a pipe only while the
  body fits `HEREDOC_PIPESIZE` — the system pipe capacity, 4096 bytes here — and
  fall back to a temporary file above it, which a round summary routinely
  exceeds.

  The redirection is removed rather than guarded: the body is matched with `case`
  and sliced with `${…}`, so there is no temporary file to fail and no `read` to
  shadow. Behaviour is unchanged in every case the suite already covered.

  **Matched over the whole body, not peeled a line at a time.** Peeling was the
  first shape and it is quadratic — each iteration copies the entire remaining
  suffix twice, once for `%%` and once for `#`. Measured: 1,000 lines 0.7s, 5,000
  lines 19s, 20,000 lines 295s, so a newline-heavy phase body stalled the round
  before anything could be posted, which is a worse failure than the one this
  function exists for. Three patterns tested once each over the whole string
  instead: 2ms, 9ms and 39ms for the same bodies. The body is prefixed with a
  newline so a marker on the first line matches the same shape as one anywhere
  else, and the EARLIEST marker in the body wins rather than the first in the
  list, so the author is told which line to fix.

  What was measured is narrower than the first draft of this entry claimed: an
  unwritable `TMPDIR` does not reproduce it on 4.4, 5.2 or 5.3 — each built and run,
  at 100 bytes and at 200 kB — because bash falls back to `/tmp` when `TMPDIR` is
  unusable. That is a fact about the fallback rather than the backend.

  So the new cases are structural, and for a better reason than the version: the
  failure cannot be staged from a fixture at all, since reproducing it means making
  temp-file creation fail everywhere, which is not something a test may do to the
  machine it runs on. What is asserted is the property that removes the
  dependency — no redirection and no `read` in the function — with one behavioural
  case that it still finds a marker with `TMPDIR` pointing nowhere.

## [2.0.33] — 2026-08-19

- **The pin proof's boundary is written down where the proof is.** Three rounds of
  review walked up to it from three directions, and it is cheaper to state than to
  rediscover.

  What the proof establishes is that a CHILD inherited the pin — the failure it
  was built for, where an `export` that assigns without setting the export
  attribute leaves the driving shell holding the right value while every helper
  holds none, and a `cd` into a second checkout then retargets every stage. That
  is an accident rather than an attack, and asking a real child is what catches
  it.

  What it cannot establish is anything against a function in that shell. `export`
  is a name, and one that mutates its operand makes the child report a forged
  remote and the comparison compare forged with forged:

  ```bash
  export() { RB_REMOTE='git@github.com:WRONG/other.git'
             builtin export REVIEW_BUS_REMOTE="$RB_REMOTE"; }
  ```

  A second `pr-origin.sh read`, comparing against the repository rather than
  against a variable, was built for this and is **not** in the file: it bought
  exactly one thing, an attacker who knew one variable name and not the other. The
  same function rewrites both. It can also `cd` first, so a later read agrees with
  the forgery, and an earlier read is just another variable. Every value that shell
  holds is nameable and the function runs at a point of its own choosing, so no
  ordering and no extra child makes the comparison mean more than the shell it runs
  in — and `SKILL.md` is a file such a shell can edit, which is the boundary
  `pr-origin.sh` § WHAT THIS DOES NOT CLOSE and #91 already draw.

  The narrow thing the proof does do about a shadowed `exit` is stated too: every
  refusal in the block ends in `exit`, which a function can neuter into a `return`,
  so a refused transport check carries on — to a comparison where `RB_REMOTE` is
  still empty. The non-emptiness test is what stops that reaching the success line,
  and it is why the check is not equality alone.

- **A pre-seeded readonly `RB_PIN_SEEN` can no longer certify a pin no child saw.**
  That is the one walked-past refusal the non-emptiness test cannot catch, because
  nothing in it is empty: with `exit` neutered, an `export` that assigns without
  exporting, and a readonly `RB_PIN_SEEN` already holding the real remote, the
  reset's refusal is stepped over, the child inherits nothing and reports nothing,
  its empty answer cannot overwrite a readonly variable, and the equality compares
  the pre-seeded value with `RB_REMOTE` and agrees. Setup announced a pin no helper
  would ever see, and a later `cd` retargeted every stage.

  The probe and the success line are now ARMS of that reset proof rather than
  lines after it, so neither is reachable when the reset fails, whatever has been
  done to `exit`. That is the structural shape #102 asked for, applied at the one
  place where a walked-past refusal produces a plausible answer instead of an
  absent one.

  **`RB_PIN_SEEN`'s writability is proved by three assignments, and the verdict is
  control flow rather than a variable.** `readonly RB_PIN_SEEN=''` defeats a single
  emptiness test: the reset assignment fails, the value is already empty, and the
  test agrees — so the probe ran, and the assignment that stores the child's answer
  then failed inside the compound command, which can end the shell before either
  cleanup and leave the file and the directory behind.

  A `writable=yes` flag was the first fix and is not this one: it is another
  variable, and a readonly pre-seed of `yes` made every reset of it fail while the
  refusal was skipped — the same defect one name along, which is the shape this
  repository keeps deleting. Assignments inside the `elif` conditions leave nothing
  to pre-seed: the arm is selected or it is not. `probe-a` and `probe-b` differ, so
  no readonly satisfies both, and the empty reset is what the child's answer
  overwrites. A shell where any of them fails to take either stops on the spot —
  bash's behaviour for a failed readonly assignment — or selects that arm, and both
  happen before the `mkdir`, so nothing has been created.

  **The assignments are proved before anything is created.** They were inside the
  `mkdir` arm, which leaks: a failed readonly assignment can end the shell where it
  stands — bash's own behaviour, and what the reset fixture observes — and by then
  the directory existed with nobody left to remove it. Proved first, a refusal
  happens while there is still nothing to clean up.

  **The whole probe is an arm of the `mkdir` that creates its directory**, so
  nothing runs on one this invocation did not make. `mkdir -m 700` fails precisely
  when `RB_PIN_DIR` names something that already exists — which is what a readonly
  pre-seeded value points at — and with `exit` neutered that failure was stepped
  over: the probe then created and removed `pin` inside the operator's directory,
  `rm -f` deleted a `pin` of theirs if one was there, and `rmdir` took the
  directory.

  **Whose the directory is decides who may remove it.** Exactly one arm removes
  it: the one where the `mkdir` succeeded, which is the only place this shell is
  known to have created it. Every refusal fires before that `mkdir` — the
  assignments are proved first — so there is nothing for a refusal to clean up,
  and none of them tries: `RB_PIN_OUT` and `RB_PIN_DIR` can name the operator's own
  file and directory, `rm -f` deletes the file, and `rmdir` deletes the directory
  whenever it is empty, which an operator's often is.

  An earlier draft of this entry claimed `rmdir` "removes an empty directory or
  fails, so it cannot destroy anything". That is wrong: deleting an empty
  directory IS the destruction, and an operator's directory is often empty.
  `rmdir` is safe here only where this invocation's `mkdir` has just proved the
  directory is ours.

  Three cases: the success line must be inside the branch where the reset held,
  must NOT appear in the arm that refuses — or "inside a branch" is satisfied by
  announcing success on both — and the probe must be in there with it. Plus the
  combined state itself, run end to end, with its own reach probe asserting that
  shell really does keep the pre-seeded value.

  A sentinel: a `watch-pr.*` directory and a `pin` file the block never made,
  pre-seeded readonly as `RB_PIN_DIR` and `RB_PIN_OUT` so the two earlier arms
  pass and the `mkdir` arm is the one that fires — that run must refuse non-zero
  with the mkdir's own message, and both must still be there afterwards. Named any
  other way the first arm was selected, `mkdir` was never attempted, and breaking
  its refusal left the case green.

  `readonly RB_PIN_SEEN=''` must be refused and must leave the transport parent
  empty, which is what refusing before the `mkdir` buys.

  And structurally: the branch's four arms are lifted by their own headers and
  checked one at a time — a count over the whole conditional is satisfied by two
  cleanups in one arm and none in another — with the success line and the probe
  only in the work arm, no cleanup in any refusal, both cleanups in the work arm,
  the assignments proved before the branch, the writability probe using two
  unequal values, and the reset refusal carrying its own abort. That last one is
  structural because on this bash the failed readonly assignment ends the run
  before the arm is evaluated, so a behavioural case alone would stay green with
  the arm deleted.

  Each fails against the shape it replaces; the largest single mutation — moving
  the assignments back inside the `mkdir` arm — turns eight red.

## [2.0.32] — 2026-08-19

- **The driver no longer parses a record to learn the signed-off head.** All
  three reads ask `pr-signoff.sh sha`, which prints the 40-hex commit alone.
  `SKILL.md` loses 154 lines of executable shell, and the suite gains nothing it
  did not already have — the coverage moved to the file that can run it.

  What went was ~90 lines of expansion-only parsing against
  `PR_PHASE_RECORDED … codex-sha=`, and every one of them had been paid for in
  review: a truncated record that could not overwrite a stale candidate, a bare
  `PR_PHASE_RECORDED` with no trailing space, `xcodex-sha=` matching as the field,
  a greedy `##*codex-sha=` reading the value after a *later* substring. Nine
  rounds on #74, for a fact the pull request itself already held. Two `sed` copies
  went with it, and those were worse than long: `sed` is a name, so one that
  prints a plausible forty hex and exits 0 pins a merge to whatever it says.

  **It is a round trip, and that is the trade.** `record` posts the signoff and
  the block reads it straight back, so a stale or eventually-consistent read is a
  failure mode the parse did not have — but it is the same read a resumed session
  already makes, so the exposure is the system's rather than this step's, and it
  fails as a stop rather than as a silent empty. A revocation landing in between
  reads as status 1, which is a refusal here: the phase it would open is no longer
  closed.

  Both the status and the shape are checked at every read — all three, including
  the Copilot one, where status 0 with something that is not 40 hex would have
  read as "no signoff" and sent the operator back through a phase that is closed.
  That refusal is the FIRST ARM of the branch it protects rather than a guard
  before it: written as its own `if … exit`, a shadowed `exit` returns and
  execution falls into the selection, which is the outcome the check exists to
  prevent. As an arm, a malformed sha selects it and neither phase arm can run on
  that value. The tests in it are `[[`, since `[` is a command a function can take
  the place of — one returning false skips a validation, one returning true
  selects an arm the values do not justify. `sha` prints 40 hex or
  nothing, so the shape check cannot currently fail — which is the point: this
  value is what every gate in step 8 is pinned to, and it does not rest on one
  helper's promise.

  `test-pr-skill-contract.sh` no longer lifts and executes a parser, because there
  is none. It asserts the wiring instead — three reads, each taking the status,
  each shape-checked — the count of shape checks is tied to the count of reads,
  not to a floor, because a floor of two was satisfied by the two Codex ones while
  the third went unvalidated — and no record parsing anywhere in the file's
  *code*. That
  last scan reads the fenced bash with comments stripped: the comments explain
  which constructs were removed and name them to do it, so a scan of the raw file
  would find the argument against the defect and report the defect.

## [2.0.31] — 2026-08-19

- **`pr-signoff.sh` can answer with the head alone.** `pr-signoff.sh sha <pr>
  <reviewer>` prints the recorded 40-hex sha and nothing else; stdout carries the
  value or is empty, and every reason goes to stderr, so a caller reads one stream
  and never sees the other.

  It exists so that no caller has to parse the record line. `SKILL.md` extracts a
  signed-off head in three places and two shapes: ~90 lines of expansion-only code
  against `PR_PHASE_RECORDED … codex-sha=`, whose every line was paid for over
  nine rounds of #74, and twice
  `sed -n 's/^PR_SIGNOFF .*sha=\([0-9a-f]\{40\}\)$/\1/p'` — and `sed` is a name, so
  one that prints a plausible forty hex and exits 0 pins a merge to whatever it
  says. Converging those inline would have put three copies of a parser in a
  Markdown file, none of them reachable by the suite. This is the helper change
  that has to land first; #89 is the removal it enables.

  "None" is not a value, so in this mode it goes to stderr with status 1 — a
  caller capturing `PR_SIGNOFF … sha=none` on stdout would hold a non-empty string
  that is not a sha, which is the ordinary-looking wrong answer the fail-closed
  rule exists to prevent. A revocation answers the same way, and an unreadable API
  is status 2 with stdout still empty.

  The default output is unchanged, deliberately: the resume path prints the whole
  record in its abort messages and `test-pr-skill-contract.sh` asserts on that
  shape. The sha is validated through `sha_reason` in `recordlib.sh` rather than a
  fourth copy of the 40-hex rule, and an unknown subcommand is refused — a mode
  word is a leading word, a PR is digits, so anything else lands in the PR
  argument and fails its own check.

## [2.0.30] — 2026-08-19

- **A driver tracing to its own stdout aborted setup.** `BASH_XTRACEFD=1` sends
  xtrace to file descriptor 1, and inside `X="$(cmd)"` fd 1 *is* the capture — so
  the trace of `cmd` was assigned to `X` along with its output:

  ```
  $ SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c 'X="$(printf hello)"; echo "[$X]"'
  [++ printf hello
  hello]
  ```

  Every substitution in the setup block was affected, not one of them: the
  repository root, the plugin-copy discovery, the `mktemp`, the `type -t` probe.
  The validations below each of them then rejected the corrupted value, so it
  failed closed — and ended a session that had nothing wrong with it, with an
  abort naming a path the operator could see was fine.

  Setup now moves the trace off the capture before its first substitution:
  `BASH_XTRACEFD=2`, guarded by `[[ -n "$( RB_TRACE_PROBE=1 )" ]]` — a capture
  that comes back with anything in it at all, run before the first substitution
  that matters.

  The probe is an **assignment** because every command is a name: `$( : )` was the
  first spelling, and a shell with `:() { printf marker; }` made the capture
  non-empty through the function's own output.

  **The move is gated on a subshell writability probe, for `set -e`.** A readonly
  `BASH_XTRACEFD` makes the assignment a FATAL error rather than an ordinary
  failure: `||` does not catch it, an `if` around it does not catch it, and under
  `errexit` it ended the operator's long-lived shell where the documented outcome
  is a refusal further down. All three forms measured. So the assignment is tried
  in a subshell first, where that fatality is confined, and its status decides
  whether the real one runs — `( … )` and an assignment are both parser
  constructs, so no name is introduced, and a condition of `&&` is exempt from
  `errexit`.

  **The move is a reassignment, which closes nothing.** bash closes the descriptor
  `BASH_XTRACEFD` named when the variable is unset or set to the empty string, and
  only then: `sv_xtracefd` reaches `xtrace_reset` — the one path that closes — in
  exactly those two cases, and otherwise takes `xtrace_set`, which replaces the
  target and leaves the old descriptor open. Measured on 4.4.0, 5.2.0 and 5.3.9,
  each built and run for this: after `BASH_XTRACEFD=1` → `2`, ordinary `printf`
  output still reaches fd 1 and `exec 3>&1` still succeeds, while
  `BASH_XTRACEFD=` produces no further output at all. That is what makes this form
  available where a save-and-restore, which has to unset, was not.

  **Marker schemes were tried and removed.** Matching the probe's own text, then a
  pid delivered through `PS4`: a `DEBUG` trap inherited under `set -T` runs inside
  the substitution and forged each in turn — `$BASH_COMMAND` reproduces the
  command exactly, and `printf "%s:" "$$"` produces the pid. A trap can emit any
  bytes, so no content test can prove provenance. Each sharper marker also added a
  way to MISS: an operator with `readonly PS4` made the pid scheme blind, and a
  miss is the harmful direction — the trace stays on stdout, every capture is
  corrupted, and a perfectly good checkout is refused.

  **The two directions are not symmetric, and that is the whole design.** A false
  positive moves the trace to fd 2, where bash sends xtrace by default, so every
  line still arrives. A false negative leaves it on stdout, corrupts every capture
  and aborts the session. So the test is the one that cannot miss.

  **And the guard keeps no state.** A save-and-restore around the block was built
  and removed: three successive rounds found the same defeat, and it has no fixed
  point. A startup file pre-seeds the saved value — or the flag added to validate
  it — as `readonly`; both assignments fail silently, since assignments do not
  report failure; and the restore then aims the operator's trace at whatever
  descriptor that file chose. Making the flag's value the pid does not help: the
  startup file runs in the same shell, so `$$` is as knowable to it. Any state this
  block writes can be pre-seeded with the value it was going to write.

  What the restore bought was tidiness after a mis-fire, and a mis-fire needs
  something else writing into that capture, and only an inherited `DEBUG` trap
  under `set -T` can: the probe runs no command, so there is no function for a
  shadowed name to supply. Such a shell has already corrupted every capture in
  the block, so setup refuses further down and the session ends either way.
  Trading that for an unbounded regress of collision guards is the over-building
  this repository's rules warn against.

  **A driving shell with no stderr is out of reach**, and that is stated rather
  than pretended away: with fd 2 closed bash rejects `BASH_XTRACEFD=2` as an
  invalid descriptor, the trace stays on stdout, and the captures are contaminated
  exactly as before. There is no other target to choose — every descriptor that is
  not the capture is one this block would have to open, and the place a trace
  belongs is the standard error that shell does not have. It fails closed: a
  corrupted `REPO_DIR` is not a directory, so the first use of it refuses, and
  that is what the fixture asserts.

  **The accepted outcome of a FALSE POSITIVE, stated rather than left to be
  found:** where the probe fires because something else was writing into that
  capture — an inherited `DEBUG` trap — the operator's chosen trace
  destination becomes stderr for the rest of the session. That is a different case
  from the closed-stderr one above, where the move is rejected and the trace stays
  where it was; the two are not alternatives. `README.md` says both.

  The origin read was never affected and still is not: its value arrives in a
  file read with `$(<"$path")`, and a redirection-only substitution executes
  nothing, so there is no trace to capture.

  `test-pr-skill-contract.sh` lifts the setup block, asserts the guard is its first
  executable line and that the code — not the prose arguing against it — contains
  no `set +x` and no `unset`, then runs the real repository-root read under
  `SHELLOPTS=xtrace BASH_XTRACEFD=1` with the guard lifted from the block rather
  than retyped. The capture holds the path alone under `1`, `01`,
  `+1`, ` 1` and a readonly `PS4`; the trace still arrives on stderr; the driving
  shell's stdout survives, with `BASH_XTRACEFD=` asserted to close it so that case
  is not vacuous; and a shadowed `set` changes nothing.

  The hostile-shell cases assert what is actually promised there: the trace is
  never silenced and never lands on a descriptor nobody named. A marker `DEBUG`
  trap, one echoing `$BASH_COMMAND`, one printing the pid and a readonly `PS4` all
  leave it on fd 7 or fd 2 — the trap cases may fire, and that is the accepted
  false positive. A shadowed `:` has its own, stricter case: the probe runs no
  command, so it cannot fire at all and the target must be untouched. And the guard is asserted to BE its
  three lines rather than merely to avoid two retired variable names — a list of
  spellings is wrong the first time a new one is written, and `RB_TRACE_SAVED`
  would have passed a scan for `RB_XTRACE_SAVED` while reintroducing exactly what
  it forbids. The whole block is checked as well as the guard, because a save
  added after its `fi` leaves those three lines untouched: any restore must write
  `BASH_XTRACEFD` a second time whatever it calls the variable it remembers, so
  the block is required to name it nowhere outside the guard — the count is
  compared against the guard's own rather than fixed, since the guard names it
  twice, in its writability probe and in the move that probe gates. That check is
  run against the save-and-restore itself, which must fail it.

  The scan for the descriptor-closing spelling covers both: `unset
  BASH_XTRACEFD` and `BASH_XTRACEFD=` do the same thing, and a check for one
  stayed green for the other. Disabling tracing is checked twice over — no
  executable line in the whole block may contain a `set +…`, anchored nowhere so
  that `[[ 1 ]] && set +o xtrace` is caught mid-line, and after the guard and the
  lifted read run, `$-` must still carry `x`. The scan is run against that exact
  mutation, which must fail it. The pattern is a portable ERE rather than `\b`,
  which BSD `grep` can match literally — a word boundary that finds nothing would
  pass everything.

  Where the shell has no `BASH_XTRACEFD` — bash 3.2.57, which the `macos-shell`
  job builds — the contamination cannot be staged, so that half reports which case
  it was rather than failing.

  `README.md` § Troubleshooting says what an operator tracing to stdout will see,
  and both reviewer contracts state the invariant so a later change cannot remove
  it with a clean review: the guard must stay above the first substitution, it must
  not grow into disabling tracing or unsetting the variable, and it must keep no
  state a startup file could pre-seed.

## [2.0.29] — 2026-08-18

- **The setup block read origin with `git` and proved its pin with `bash -c`, and
  both are names.** A function answering only `remote get-url origin` forged the
  identity every stage is then addressed by — successfully, with a plausible
  value. A function called `bash` runs in a shell copy that inherits *non*-exported
  variables, so combined with an `export` that assigns without setting the export
  attribute it agreed the pin had arrived while every real helper — which execs
  through `#!/usr/bin/env bash` and resolves on `PATH` — inherited nothing.

  Both are now asked of `pr-origin.sh`, started by the caller as
  `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh read "$RB_ORIGIN_OUT"`, with the
  value read back from that file. A path is
  not a name, so no function can stand in front of it; privileged mode means
  `BASH_ENV` and `ENV` are never sourced, shell functions are never imported from
  the environment, and `SHELLOPTS` is ignored, so there is no hook to escape and
  nothing inherited to clear; and `pin` is a real child, so what it sees is what
  the stages will see.

  Measured against the driver before and after: a forged `git` used to decide the
  session's repository and now cannot, and an `export` that assigns without
  exporting is caught by a child reporting it inherited nothing.

  The value comes back **in a file the caller names**, and the caller reads it with
  `$(<"$path")`. Two earlier mechanisms put it on a descriptor — stdout, then fd 9
  — and each put it on a stream some caller traces to; moving `BASH_XTRACEFD` out
  of the way instead was worse, because bash CLOSES the descriptor that variable
  referred to when it is unset, so restoring it closed fd 2 and the next call in
  the session returned nothing at all. A path cannot collide with a descriptor, and
  a redirection-only substitution executes nothing for an inherited `xtrace` to
  write into.

  **The caller starts it privileged, through a path**: `/usr/bin/env bash -p`.
  Written as `bash -p …` the call is a NAME — a function called `bash` in the
  driving shell writes a forged URL to the transport file it was handed and
  returns, without the helper running at all. `/usr/bin/env` is the same path every script
  here already depends on through its shebang, so it is not a new assumption;
  which `bash` it finds is a `PATH` question, and that is #91.

  **Starting it privileged cannot be delegated:**
  privileged mode is what stops `BASH_ENV` being sourced, so it has to be in force
  before the helper's first line. A hook needs to shadow nothing to use the gap —
  one that writes the transport file and exits is a complete attack. There is no
  fallback inside the helper for a caller that forgets: by then the hook has run,
  so a missing `-p` is refused rather than recovered from.

  Privileged mode does not source `BASH_ENV` or `ENV`, does not import functions
  from the environment, and ignores `SHELLOPTS` — measured, all three. That
  replaced a re-exec whose marker the hook could set for itself, a
  function sweep made of `unset`, `builtin`, `compgen` and `read` (each shadowable,
  and each markable `readonly -f` so the clearing failed and the loop then *called*
  it), and a `:` probe that ran before any of it. Every one was a name used to
  escape names, and each round of review found the next; `-p` removes the question
  rather than answering it again. The guard is `$-`, which is shell state a hook
  cannot write — where the two guards before it, an environment marker and a
  positional flag, were both forged.

  What remains is stated in the script rather than left to be rediscovered: the
  caller's half cannot be supplied from inside, so a caller that omits `bash -p`
  is refused rather than recovered — a later entry in this release removed the
  fallback hop that used to try; and a poisoned `PATH` forges every external
  command, which is not this helper's to answer and is filed as #91. Both
  need a shell already executing arbitrary code as the operator — which can edit
  the helper instead.

  **Both transport files live in a directory the setup creates**, rather than at
  `${TMPDIR:-/tmp}/watch-pr-origin.$$`. A name derived from the pid is predictable
  from another account on the same machine, so it could be pre-created as a
  world-writable file or as a symlink; the helper truncates and writes through
  whatever it is given, so the URL read back — the one every later signoff,
  revocation and review request is addressed by — would have been that account's
  choice. Reasoning that a remote URL is public answered disclosure and left the
  substitution untouched. `mkdir` is the exclusion and is what fails closed: an
  account that guesses the name gets nothing — the candidate is passed over and
  the next is tried — instead of supplying the session a
  repository, and three `$RANDOM` draws make guessing it unlikely enough that
  nobody can hold a session open by squatting it. The directory is removed on
  every exit from setup, including the two that refuse.

  **A pin helper that cannot start is no longer read back.** The status of the
  `pin` call was ignored on the grounds that the helper truncates the file before
  writing — true, and silent about a helper that never reached the truncation
  because it was missing or unreadable. What was read then was whatever stood at
  that path, and since the path was reused for the life of the driving shell, a
  value left by an interrupted earlier setup only had to match to report that a
  child had inherited a pin no child had been asked for.

  **The transport directory's parent has to be one nobody else can replace it
  in**, which mode 700 does not give. That mode protects what is inside the
  directory and says nothing about the entry naming it: where another account can
  write the parent, it can observe the name, rename the directory without
  entering it, and leave a writable one of its own at that path — after which the
  value read back is theirs. The rule that answers this is stated further down in
  this entry, where it settled: every component owned by this user or root. A
  sticky parent was an intermediate answer and is NOT sufficient — sticky stops
  one account renaming another's entries and does nothing about the directory's
  owner renaming ours.

  **Every cleanup is reached by path.** `rm` and `rmdir` are names, and each ran
  between a value being obtained and that value being trusted: an
  `rm() { RB_REMOTE='git@github.com:WRONG/other.git'; }` in the driving shell
  replaced the pin immediately after the protected read, and one setting
  `RB_PIN_SEEN` made the postcondition agree after a probe that had failed. The
  helper cannot see either — it had already done its job.

  **A transport directory other accounts can write is refused.** The caller can
  test that the parent belongs to the operator; it cannot test whether the
  operator left it open to others, because bash has no test for another account's
  write bit — so an owned mode-0777 `TMPDIR` got through, and an account with
  write there could replace the whole directory between the helper closing its
  file and the caller opening it. Both of the caller's checks then pass, because
  the planted file belongs to the operator too. The helper refuses a group- or
  component ANYWHERE on the path to its output that another account controls —
  not just the
  directory holding it, which the caller creates mode 700 and which would
  therefore always have passed, while an account with write on the directory
  above it can rename that one after the check and leave a replacement at the
  same name. What is required of each component is OWNERSHIP by this user or by
  root, and not merely a mode: a sticky directory stops one account renaming
  ANOTHER'S entries and does nothing about its owner renaming ours, so an
  attacker-owned `1777` ancestor passed a permission-only test — and an
  attacker-owned `0755` one is no better, since its owner can add the write bit
  after the probe. Root is trusted because root can replace this script, the
  `git` it runs and the shell interpreting it. Sticky remains the MODE exception,
  and is why `/tmp` works: root owns it, and `1777` lets anyone create an entry
  while letting nobody rename another account's.

  **The path is checked as it is WRITTEN and as it RESOLVES**, because neither
  covers the other. A lexical walk never sees the real ancestry — a `TMPDIR` of
  `/home/me/t` pointing at `/srv/other/mine` checks `/home/me` and never
  `/srv/other`, and the account that owns that one can replace `mine` after every
  check has passed. Refusing symlinks instead is not available: macOS reaches its
  own temporary directories through them. So the walk runs twice, over the written
  path and over `cd -P`/`pwd -P`'s answer, and a path that cannot be resolved is a
  refusal. The mode clause skips links, whose own mode is `0777` everywhere and
  means nothing; the ownership clause applies to them exactly as to directories,
  because whoever owns a link can repoint it.

  **An empty pin can no longer reach setup's success line.** Every refusal in the
  transport block ends in `exit`, and `exit` is a NAME: with one shadowed, a
  refused check carried on with `RB_REMOTE` still empty, the probe reported empty
  because no child had been asked, and `"" = ""` succeeded — so setup announced
  success with no `REVIEW_BUS_REMOTE` at all and every later stage derived its
  identity from wherever the session stood. The postcondition requires a non-empty
  pin as well as an equal one. That is the consequence rather than the class;
  #102 has the rest.

  **An ACL is a permission the mode bits do not show.** On macOS a user-owned
  `0700` directory can still grant another local account `add_file` and
  `delete_child` through an extended ACL, and Linux POSIX ACLs do the same;
  `find -perm` sees none of it, so every ownership and mode check passed while
  that account could replace the directory. Any component carrying one is refused.
  What is read is the MARKER, not the ACL's contents — reading those means
  `getfacl` on one platform and `ls -e` on the other, two grammars and two new
  ways to be wrong. Either mark counts: `ls -l` appends `+` for extended security
  information and, on macOS, `@` for extended attributes — and a component
  carrying BOTH shows `@` alone, so keying on `+` let an ACL granting another
  account `delete_child` read as clean beside any xattr. `@` is ambiguous rather
  than harmless. Coarse, and it fails closed.

  The probe's status is taken, because `find` prints nothing when it fails and
  empty output is what the walk reads as safe — so a component renamed during its
  own probe would have been let through by that interference. Tested with
  `find -prune -perm`, which is POSIX where `stat`'s flags are not, and run in
  the helper rather than the driver because that process is privileged, so `find`
  cannot be a shadowed name there.

  **Git resolves the URL, and nothing in the helper second-guesses it.** Every
  attempt to take a piece of that resolution into the script diverged from git's
  own semantics, and the count is the evidence: a scalar read returning the LAST
  of several URLs where `remote get-url` returns the first; a `--local` query
  that cannot see the worktree scope; a hand-applied `insteadOf` re-deriving
  longest-match; `ls-remote --get-url` resolving its operand as a remote NAME;
  and then, from a two-call design that replayed extracted rewrite rules as `-c`
  options, cross-scope ordering, `~`-includes lost with `HOME`, and a subsection
  containing a space. Each fix was right about the case it named and produced the
  next one, because what was being rebuilt is git's config machinery.

  So there is one ordinary call — `git remote get-url origin`, under the
  operator's own config, which is what `fetch` and `push` consult. What the
  helper still decides is the environment it runs in: `env -i` with `PATH`,
  `HOME`, `XDG_CONFIG_HOME` and the config variables carried back — the line the
  next paragraph draws.

  **Those are carried by prefix, not by name.** `${!GIT_CONFIG_@}` passes through
  every set variable whose name begins `GIT_CONFIG_`, so the two file locations,
  the system opt-out, the runtime family `GIT_CONFIG_COUNT` /
  `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>`, `GIT_CONFIG_PARAMETERS` and
  whatever git adds next all arrive. A list of three named the files and the
  opt-out and missed both runtime channels — an operator whose `insteadOf` rule
  arrives that way had it expanded by every ordinary command and dropped here,
  pinning the session to the unexpanded alias. An indexed family cannot be
  enumerated at all, so the shape changed rather than the list growing.

  Setness comes with it: a name appears only if it is set, so `GIT_CONFIG_GLOBAL=`
  is carried as empty rather than dropped. That matters because git defines these
  by whether they are set and reads an empty path as no such file — an operator
  exporting one empty has switched that source off, and a non-empty test silently
  restored git's default file.

  Shutting the operator's config out of the resolution was tried and removed. It
  stopped a carried file contributing `[remote "origin"] url = …`, which does win
  `get-url` — but the same file may carry `url.<base>.insteadOf`, which the helper
  must honour, and a rewrite rule redirects the origin completely where an
  injected URL only puts a second one in front. The stronger channel is
  deliberately open, so closing the weaker one bought no guarantee and cost
  agreement with git. That boundary is now recorded in the file's limits.

  **Config location is carried; repository scope is not**, and the prefix is
  where that line is drawn. A `GIT_CONFIG_*` variable says WHICH CONFIG the
  operator's git reads — dropping one does not block a redirection, it makes the
  helper read a different config from the session, so a rewrite the session
  honours is invisible here. `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR` and the
  rest say WHICH REPOSITORY, share no prefix with them, and go with `-i`.

  The omission falls the safe way in each direction, and the two directions are
  not the same. Outside the prefix, `env -i` drops what nobody listed, so a future
  repository-scoping variable cannot redirect the read. Inside it, a future
  `GIT_CONFIG_*` variable is carried unseen — which is not a hole this design can
  close and not one it needs to: everything reachable through that prefix is
  arbitrary config, and arbitrary config is already an accepted channel here.
  Carrying a config file at all means a `url.<base>.insteadOf` rule in it can
  redirect the origin completely, which is recorded in the helper's limits. What
  would be a hole is git putting repository SCOPE behind the `GIT_CONFIG_` prefix;
  no such variable exists, and one would be a change to what the prefix means
  rather than a variable this list forgot.

  **A global `insteadOf` rule is expanded again.** Emptying the environment to
  shut out `GIT_DIR` also removed `HOME`, and `git remote get-url` is documented
  to expand `url.<base>.insteadOf` — rules that live in the user's global config.
  A checkout whose origin is `work:acme/widget.git` came back unexpanded with host
  `work`, so setup refused a valid checkout or addressed the session at a host it
  does not push to. `HOME` and `XDG_CONFIG_HOME` are carried through; everything
  that redirects the repository still goes, and the list needs no maintaining
  because the environment is emptied rather than filtered.

  **The helper creates its output exclusively, and cannot be started
  unprivileged.** `: > "$OUT"` opened with O_TRUNC and followed symlinks, so an
  account able to replace the transport directory could leave a symlink there
  pointing at any file the operator owns — the helper truncated that file and
  wrote a remote URL into it, and the caller's `-O` check passed precisely BECAUSE
  the target belonged to the operator. `umask 077` and `set -C` make the create
  O_EXCL, which refuses a symlink whether or not its target exists and refuses a
  pre-existing regular file too; the value is appended into the object just
  created rather than redirected a second time, which keeps `>|` — the spelling
  that overrides noclobber — out of the file entirely.

  The fallback hop for a caller that forgot `bash -p` is gone, and so is the
  executable bit. The hop advertised a recovery it could not perform: by the time
  it ran, the caller's `BASH_ENV` hook had already executed in that process, and a
  hook that writes a forged value and exits has finished before any line of the
  helper. `bash` reads the file rather than execing it, so the documented
  invocation is unaffected.

  **The transport file is checked and read as ONE OPEN OBJECT.** Checking a path
  and then opening it are two operations on a name, so whoever can write the
  directory holding it — the owner of a mode-0777 `TMPDIR` this user owns, among
  others — can leave the helper's own output in place for the checks and swap the
  pathname before the read. The file is opened once with a redirection, which the
  shell applies and no function can stand in front of, and both the `-O` proof and
  the read are of `/dev/fd/9`. `-h` is deliberately absent: on Linux that path is
  itself a symlink into `/proc`, and a path that was a symlink has already been
  followed by the open.

  **`GIT_DIR` pointed the read at another checkout.** Privileged mode refuses
  startup files and inherited functions and keeps ordinary environment variables,
  so a `GIT_DIR` exported by the driving session made the helper read a second
  repository's origin while standing in this one — and every signoff, revocation
  and review request then went to that project. The lookup runs under `env -i`
  with `PATH` alone, rather than a list of `-u`s that is wrong the first time git
  adds a variable; `GIT_CONFIG_GLOBAL` is covered by the same change and asserted
  separately for that reason.

  **Each transport directory now lives exactly as long as its value.** It used to
  stand from allocation until the pin at the end of setup, putting eight aborts in
  between — an empty origin, a multi-line one, an unparseable identity, a summary
  file that could not be created — each leaving a private `watch-pr.*` nothing
  else can remove. Adding cleanup to eight sites is a list wrong by omission; the
  origin's directory goes as soon as its value has been read, and the pin
  allocates its own.

  **The transport directory's parent must be one this user owns.** Sticky was
  accepted first and cannot be: it stops one account renaming *another's* entries
  and does nothing about the directory's OWNER renaming ours, so an attacker-owned
  mode-1777 `TMPDIR` passed. Checking the resulting file instead — `-O`, `-h`,
  `-f`, on the grounds that nobody else can produce a file this user owns — was
  the second answer and is not sufficient either: checking a path and then opening
  it are two operations on a NAME, so the owner of the parent can leave the
  helper's own output in place for the checks and swap the pathname before the
  read. What decides it is who may RENAME an entry there, which is ownership and
  mode together — and that is not the same as "owned by this user": a root-owned
  sticky `/tmp` is safe, because sticky means nobody may rename another account's
  entries and root can replace this script anyway. An attacker-owned sticky
  directory is not, for the reason above.

  The rule lives in one place, `pr-origin.sh`, which walks the whole ancestry;
  the driver offers `TMPDIR` then `HOME` and lets the helper answer, because two
  copies of a safety rule end a valid session wherever they disagree — which they
  did, three times. The file checks stay as a cheap postcondition; they are no
  longer what makes it safe. A home directory the operator has made writable by
  others is the stated limit.

  **A readonly transport variable no longer passes silently.** The driving shell
  is long-lived, so `RB_ORIGIN_OUT` can already exist as a readonly naming a file
  somebody else can write; the assignment failed, the variable kept the old path,
  and the helper wrote a good value into a file an attacker could edit before the
  read. Written as `RB_ORIGIN_OUT=… || abort` this still did not catch it:
  measured on bash 5, a failed readonly assignment as the left side of an AND-OR
  list does not fire the `||` — the list reports success and the variable keeps
  its old value. Each of the four transport assignments is now proved by reading
  the variable back.
## [2.0.28] — 2026-08-18

- **The loader was verified by asking `type`, which is a name.** Ten helpers ran
  `[ "$(type -t rb_load)" = function ]` before using the loader, and an inherited
  `type() { return 1; }` made a perfectly good `loadlib.sh` abort every stage.
  #104 has since made that particular forgery impossible — a privileged shell
  imports no functions — but verifying a thing by asking a second thing about it
  is only as good as the asker, and the answer was always available for free: the
  FIRST LOAD is the verification: an empty `loadlib.sh` leaves the refusing stub
  the caller defined, and calling it fails.

  **A refusing stub is what makes that true.** Without it an undefined `rb_load`
  is looked up on `PATH` — privileged startup keeps functions out and does not
  change `PATH` — so an executable by that name exiting 0 would report every load
  successful with nothing cleared and no library sourced. The stub means the call
  cannot leave the shell: a good `loadlib.sh` replaces it when sourced, an empty
  one leaves the refusal.

  **The sentinel moved to the first load with it.** An empty library still reports
  `reason=loadlib_empty` on the stream its caller reads, because a bare exit
  status is the ordinary-looking empty answer `CLAUDE.md` forbids. 127 is the
  stub's and nothing else's; `rb_load`'s own refusals carry their own reason and
  status.

  `loadlib.sh`'s internal `type -t` is unchanged and is not a defect: that is the
  decision recorded in #96 and documented by #97, and #104 has made it safe by
  construction.

## [2.0.27] — 2026-08-18

- **Every runtime helper is started privileged, which retires a class the review
  had been answering one member at a time.** A helper ran through
  `#!/usr/bin/env bash`, and an ordinary bash SOURCES `BASH_ENV`, IMPORTS
  functions from the environment, and honours an exported `SHELLOPTS`. Every
  builtin a helper used was therefore a name the operator's shell could replace,
  and each one was found on its own round: `type` reported that a perfectly good
  `loadlib.sh` had defined nothing; `return` made a refusing stub return 0 and
  report an empty loader as a successful load; `set` made `set +e` a no-op, so an
  inherited `errexit` killed a helper before it could name its refusal; `echo`
  swallowed the structured sentinel a caller branches on, leaving an
  ordinary-looking empty answer; and `exit` made every refusal non-terminal, so a
  helper announced an abort and carried on to post to GitHub. Every fix was
  correct, and every one introduced the next name.

  The shebang is now `#!/usr/bin/env -S bash -p`. Privileged mode does none of
  those three things, so there is nothing to shadow and nothing to clear —
  measured: under a forged `echo` and `set`, a privileged shell reports both as
  builtins, and five forged builtins at once do not reach a helper.

  **`env -S` is a contributor requirement, not a user one**, and the split is
  stated in `README.md`. The plugin never depends on the shebang — the driver
  supplies `-p`, and so does every helper-to-helper call, of which there are
  twenty-six across five files plus the watch's five probes. Leaving those bare
  would have put the requirement back through the side door on the very flows
  the driver protects. The suite is the exception: the fixtures execute helpers
  directly at hundreds of call sites, so `pr-selfcheck.sh` needs an `env` with
  `-S`. GNU coreutils has had it since 8.30
  and BSD `env` supports it.

  **The driver supplies it, and the shebang is the fallback.** `SKILL.md` invokes
  every helper as `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-x.sh`, which starts a
  fresh privileged interpreter whatever the driving shell is and whatever that
  platform's `env` supports — so the plugin gains no `env -S` requirement. The
  shebang covers the other way in, executing a helper directly, and that one does
  need `-S`.

  It cannot be a re-exec from inside: a `BASH_ENV` hook runs before a script's
  first line, and one that prints a forged `PR_X …` line and exits has already
  answered a caller capturing stdout.

  **`$-` is checked as a last-resort refusal, and it proves less than it looks.**
  It reports the MODE a shell is in, not how it got there — run as
  `BASH_ENV=hook bash pr-x.sh`, the hook is sourced first and can itself `set -p`
  and then define `echo` or `exit`, after which the test passes on a shell that
  has already executed hostile code. Nothing inside a script can detect work done
  before its first line, so `bash pr-x.sh` is unsupported rather than defended,
  and it is the CALLER that carries the guarantee.

  `pr-selfcheck.sh` is the exception and is asserted to be one: it is run by a
  person, and it already re-execs into a clean shell and clears every inherited
  function.

  Two fixtures changed meaning rather than being adjusted. The clock-hook cases
  asserted that a hostile `BASH_ENV` hook produced each caller's documented
  refusal; the hook is no longer sourced at all, so they now assert its ABSENCE
  together with the concrete outcome, and each one first proves the hook still
  lands on an ordinary shell. `test-pr-review-state.sh` sources a helper to
  inspect its identity derivation, which now needs `bash -p -c`, because a
  sourced file sees the caller's `$-`.

## [2.0.26] — 2026-08-18

- **Four shipped files claimed CI coverage that is not running.** `SKILL.md`,
  `pr-ci-gate.sh` and `pr-merge-gate.sh` each explain why a helper is a script
  rather than a fenced block by saying that everything under `scripts/` is covered
  by the suite, by `pr-selfcheck.sh` and by the bash 3.2 `macos-shell` CI job. The
  workflow now triggers on `workflow_dispatch` only and that job carries
  `if: false`, so the third of those is not running — and an operator reading any
  of them takes a green pre-push check for portability validation it did not
  receive. Each claim is now conditional on the job being enabled, and names #93
  as what turns it back on.

## [2.0.25] — 2026-08-17

- **A shadowed `type` inside `rb_load` is now documented as accepted rather than
  left open.** The loader verifies the symbol it just loaded with `type -t`, and a
  `type() { return 1; }` in the operator's shell turns a good library into
  `reason=<lib>_empty`. There is no name-free way to ask whether a name is a
  function — `type`, `declare` and `command` are all shadowable, and calling the
  symbol runs it, which for `rb_identity` means shelling out to `git`. Dropping the
  check moves the failure to the caller's first use and loses the precise reason; a
  subshell probe forks per load and still executes the function.

  So the check stays, on the boundary settled in #76, and `loadlib.sh` now says so
  beside it. No behaviour changed — what changed is that a reviewer raising it gets
  an answer instead of reopening the question.

## [2.0.22] — 2026-08-17

- **A shadowed `[` could make a moved head read as unmoved.** 2.0.20 converted
  `pr-copilot-phase.sh`'s stage dispatch to the reserved `[[` after a `close`
  invocation was found running `open`; every other guard in the script still used
  `[`, which a function shadows along with the `command` and `builtin` prefixes,
  in a script that does not re-exec.

  Two of them decide whether a signoff is recorded at all. The proofs that the
  phase is still open compare the current head with the one Codex signed off, so a
  `[` agreeing to that equality opens the phase — posting a revocation and
  requesting a Copilot pass — on a commit Codex never reviewed; and the live
  verdict check is a status comparison, so one agreeing to that accepts a
  dismissed review as clean. Either way the durable record then names a commit no
  reviewer saw, and every later gate trusts it.

  All ten guards are reserved-word tests now, converted together rather than as
  the ones somebody noticed, and the fixture exercises five narrow forgers — a `[`
  that lies about the stage, about two shas being equal, about a non-zero status
  being zero, about a `-ne` comparison so the operator round boundary can be
  tested, and about the empty string being non-empty so the empty phase account
  can be. Each is proved to lie in a child before anything relies on it, and
  proved narrow enough to leave the rest of the script working. Two earlier
  attempts were not, and they failed differently: one that lied about everything
  broke `identitylib.sh`'s remote parse, so the run died with `reason=no_origin`
  before the guard was reached and the case tested nothing; one that answered
  every `-n ""` hung the run at the watchdog, because "the empty string is
  non-empty" is a loop that never terminates wherever one ends on it.

  Every converted guard whose behaviour a caller can observe fails under mutation,
  including `record`'s own re-validation, which posts the signoff.

## [2.0.21] — 2026-08-17

- **A `cd` mid-session could point every phase stage at another repository's pull
  request.** `pr-copilot-phase.sh` — and every helper it drives — derives its
  identity by running `git remote get-url origin` in its own process, from the
  current directory. A driving session that changed into a second checkout
  therefore aimed `record`, `open` and `close` at whatever PR of *that* repository
  shared this number, and every post they make went with them: a Codex signoff,
  a signoff revocation and a review request, then the second signoff on the
  two-reviewer path — `close … codex-only` records nothing, having no Copilot
  review to re-check. The local phase was left
  unopened while a revocation landed on a pull request nobody was working on.

  The session's origin is now read once during setup, with its status checked, and
  exported as `REVIEW_BUS_REMOTE` — which `rb_identity` already treats as the
  caller stating the identity rather than deriving it. Every helper inherits it, so
  the current directory no longer decides which project anything is posted to.

  Wrapping each call in `(cd "$REPO_DIR" && …)` was tried first and is a guard
  rather than a removal: `cd` is a name, so a function named `cd` that returns 0
  without moving leaves the subshell reporting success from the wrong tree — and a
  rule applied per call site is a list, which the next stage would not be in.
  `$REPO_DIR` remains for the merge gate, which inspects history rather than
  identity.

  The export takes its status and proves its result. A `readonly
  REVIEW_BUS_REMOTE` already in the driving shell makes it fail while setup
  carries on — and if that readonly value is empty, `rb_identity` falls back to
  the current directory, derives the intended checkout, and setup looks entirely
  successful while every child inherits no pin at all. The proof is a `[[ … ]]`
  rather than another builtin, so a shadowed `export` returning 0 without
  assigning is caught by the same line: the status alone reports success with the
  pin unset.

  Neither guard is a name, and neither has anything after it. Combine the two
  hostile states — a readonly pin and a function called `exit` — and both aborts
  return instead of ending the shell, so the pin is the **last** thing setup does
  and setup's success line sits inside the branch where the pin took. A driver
  whose abort was neutralised is never told setup completed.

  The proof is taken from a child, because a child is what the pin is for. An
  `export` that performs the assignment without setting the export attribute
  leaves the driving shell holding exactly the right value while no helper
  inherits anything, so reading the variable back agrees and every stage still
  routes by the current directory. Setup now asks a new process what it sees.

## [2.0.20] — 2026-08-16

- **The Copilot signoff was recorded by 93 lines of Markdown, and every one of
  its failures reported success.** `SKILL.md` carried the step that re-checks
  Copilot's verdict, writes the second signoff and asks what to do with two
  closed phases. Nothing covered it — not the suite, not `pr-selfcheck.sh`, not
  the bash 3.2 job — because checking shell that lives inside a fenced block
  means parsing Markdown, which this repository tried and removed.

  Worse than uncovered: its aborts exited **0**. That block ran in the driving
  session's own shell, where a non-zero status would have killed the session, so
  an unreadable head, a malformed sha and a head that moved between the clean
  verdict and the lookup all returned success to anything reading the status.

  It is now `pr-copilot-phase.sh close`, a stage on the script that already owns
  this phase's other end. Every one of those paths is a stop that records
  nothing, and the fixture pins them — along with which menu each case gets: no
  fault-tolerance pass is offered where both signoffs name the same commit, and
  the revocation is required where they do not.

- **A stage dispatched with `[` could run the wrong stage.** `pr-copilot-phase.sh`
  chose its stage with `[ "$STAGE" = open ]`, and a function named `[` — which
  shadows the builtin and the `command`/`builtin` prefixes alike, and which this
  script does not re-exec away — sent a `close` invocation down the `open` path:
  it revoked the Copilot signoff and requested another pass instead of closing the
  phase. The dispatch and the two comparisons that decide what `close` records now
  use the reserved `[[`, which no function can take the place of. The same
  substitution covers the driver's own status guard in `SKILL.md`, which runs in
  the long-lived session shell where such a function is likeliest to exist.

## [2.0.19] — 2026-08-16

- **The merge gate said a phase had been reopened that had never been entered.**
  `pr-copilot-phase.sh open` posts its revocation on every entry, including the
  first, where there is no Copilot signoff to revoke — so the block message
  described history that had not happened. It now says only that a pass is open
  and that no signoff for it has been recorded — no clause about a revocation,
  which is the event that did not happen. That is true on a first entry and on a
  re-entry alike.

  Only the wording changed. Removing the revocation itself was tried and reverted:
  with no Copilot record at all, a head whose only clean Copilot verdict is an
  older review **merges**, because "nothing recorded" is not a disagreement. That
  comment is the one durable mark that a new pass is pending, and the two cases
  proving it now live beside the gate that reads it.

## [2.0.18] — 2026-08-16

- **The phase head was captured with a pattern that accepts almost anything.**
  `SKILL.md` read the Codex head out of the phase record with `[0-9a-f]*`, so
  `codex-sha=a` produced a non-empty value, satisfied the emptiness test beside
  it, and handed the merge step something that is not a commit — and two matching
  records put two lines in one variable, which no gate downstream can mean
  anything by. It now takes exactly forty hex from the LAST matching record and
  checks the shape, which is the rule the resume parser in the same file has
  always applied. One rule, two copies, one of them wrong.

  The parse now uses no command at all. A stage that prints a plausible forty hex
  and then fails leaves that value where a shape check reads it as a good parse,
  so the status has to be taken — and every way of taking it trusted a name a
  function can shadow: `set -o pipefail` trusts `set`, and a single `awk` trusts
  `awk`. A loop of reserved words and parameter expansions has no status to lose
  and nothing to shadow, so the head can only come from the record.

  Every phase record overwrites the answer, so the newest one decides even when
  it is the unreadable one. Keeping only sha-shaped records meant a valid record
  followed by a malformed one returned the earlier head: a stale answer, offered
  precisely when the latest record could not be read.

- **And the file that enforces "no silent pass" had two.** Two lookups in
  `test-pr-skill-contract.sh` ran unguarded under `set -Eeuo pipefail`, so
  deleting either line they search for killed the file before its `die` and
  before `RESULT:` was printed at all: one FAIL, no verdict, and a caller reading
  the output rather than the exit status saw nothing wrong. Guarded, they report
  three and two failures with `RESULT: FAIL`.

## [2.0.17] — 2026-08-16

- **The round check-in printed an acknowledgement it then ignored.** Its own
  message says to post *"a comment containing, for each reviewer counted here"*
  and prints one line per login — but the scan took only the LAST such line in a
  body, so following it literally left the first reviewer unacknowledged. The
  next call for that reviewer paused again, with the operator having done exactly
  what the tool asked, and no amount of repeating it helped.

  Every anchored acknowledgement line is read now. The anchor is what stops a
  field-shaped line quoted in prose from acknowledging anything; `last` never did
  that — it did not reject a pasted line, it picked one of them, and the one it
  rejected was the form this script itself prints.

  And the check-in is decided per reviewer now, even when the count it displays
  is combined. `rounds` is the UNION of the heads the named reviewers saw, while
  an acknowledgement is one number each — so the default invocation compared two
  things that do not measure the same set, and with 41 Codex heads and 15
  disjoint Copilot heads it paused again the instant it was answered. No correct
  answer existed for it, because the instruction prints the per-reviewer numbers
  the scoped calls need.

  The lines it prints are also no longer indented. They carried the two spaces
  that read nicely under the sentence above them, and the scan anchors at column
  1 — so copying exactly what the tool printed acknowledged nothing. The anchor
  stayed and the cosmetics went, because the anchor is the whole of what stops a
  field-shaped line quoted inside prose from acknowledging something nobody
  meant.

  A wrong acknowledgement still cannot be lowered, because the highest wins:
  edit or delete the comment, since the count is derived from the bodies.
  `README.md` says so now.

## [2.0.16] — 2026-08-16

- **The CI gate read a clock its own tests could not reach.** `pr-ci-gate.sh`
  measured elapsed time with `$SECONDS`, a Bash builtin, while `pr-watch.sh` used
  `date +%s` — and that difference decides whether a fixture can own time.
  `test-pr-watch.sh` stubs `date` and `sleep`, so its poll counts are exact;
  `test-pr-ci-gate.sh` could only wait out real seconds, and every deadline case
  there raced however loaded the runner was. One of them failed a CI job on a
  commit that had passed the same job forty minutes earlier.

  Both scripts now read the clock through `clocklib.sh`. The gate gains the
  guards it never had with a bare builtin: a `date` that prints a plausible epoch
  and then fails, an epoch past Bash's integer range — which wraps inside the
  subtraction and pins elapsed time at zero — and a clock that steps backward,
  which otherwise extends the bound by however far it went.

  Nothing about the gate's behaviour changes when the clock is well-behaved. What
  changes is that it now refuses rather than polling unbounded when the clock is
  not, and that its deadline cases can be made deterministic — which is what
  issue #38 needs and could not have inside the fixture.

## [2.0.15] — 2026-08-15

- **The driver was told what a round may change, and not how to choose between
  two fixes that are the same size.** `SKILL.md` already bound the size of a round
  — fix what the finding names, build the smallest thing that makes it false — and
  said nothing about shape. Where a finding can be answered either by adding a
  check or by removing the dependency the check would guard, the driver now
  prefers removal, and says on the thread which it took.

  That is not a preference for elegance. A check is a name, and a name can be
  shadowed by a function, mis-parsed by an older shell, locked by a `readonly`, or
  simply forgotten by whoever writes the next one — each of those ended a review
  round in this repository, and each time the fix that finally held was
  subtractive.

- **The fault-tolerance pass was offered over commits that did not exist.** After
  Copilot signs off, the driver asks the operator whether to merge or to run one
  more Codex pass over what the Copilot phase changed. It asked that even when the
  phase changed nothing — both signoffs naming a single commit, which Codex had
  already reviewed. Taking it cost a revocation, a full round and a reopened
  phase for a verdict that could not differ, and a session resuming into the
  reopened phase read it as a Copilot phase to run again. The option now exists
  only where the two signoffs name different commits.

- **The authoring rules bound the pull request and not the round**, which is where
  the cost accumulates: #53's change never had a finding against it, and all
  twenty-seven of its rounds were surface its own fixes exposed. `CLAUDE.md` gains
  a round-scope section — fix what the finding names and nothing else, prefer
  removing the dependency over guarding it, read the thread and the previous
  round's diff first, and run the fault-tolerance pass only over commits that
  exist.

## [2.0.14] — 2026-08-15

- **A startup hook could erase the evidence that it ran, and the pre-push gate
  then refused a valid checkout.** `pr-selfcheck.sh` re-execs itself with
  `BASH_ENV` and friends removed, so a startup file never runs in the process that
  does the work. It decided whether to do that by asking whether a hook variable
  was set — a question the hook has already had its turn to answer. A hook ending
  in `unset BASH_ENV`, having left a `readonly -f` function behind, was invisible:
  the re-exec was skipped, `unset` refused to remove the function, and the gate
  reported `reason=inherited_function` over a checkout with nothing wrong with it.

  Nothing hostile is needed to reach that; a startup file that tidies up after
  itself is a reasonable thing to write. The re-exec is unconditional now, guarded
  by a marker the exec sets after the hook has finished, and cleared immediately
  so no child inherits it.

## [2.0.13] — 2026-08-14

- **The pre-push gate ran its eighteen independent test files one after another.** The
  suite is what a person waits at before every round, and at ~208s it was long
  enough to be worth skipping — which is the failure, because it is the check that
  keeps the same handful of mistakes from reaching a reviewer. The files share no
  state: each builds its own scratch directory and stubs its own `gh`. They were
  sequential because a `for` loop is the obvious thing to write.

  `pr-selfcheck.sh` now runs four at a time and takes ~85s. `RB_SUITE_JOBS` sets
  the degree, and takes one to five digits with no leading zero — `0`, `00` and
  `01` are all refused, and fall back to four rather than disabling the bound.
  `SKILL.md` exports it, because the gate is a child process and a knob that does
  not cross that boundary silently does nothing while the terminal shows the value
  you set. CI keeps its sequential loop: it groups and
  annotates each file, and that is worth more on a machine nobody is waiting at.

  Nothing is written outside the process. The first version kept the list of files
  in a scratch directory under `TMPDIR` and spent five review rounds defending it —
  trust `mktemp`, validate its answer, take a subdirectory, create it outright,
  make it private, check the parent's sticky bit — and the next finding was a
  `TMPDIR` owned by another user, which the sticky bit does nothing about. Every
  one of those was real, and all of them were about a shared directory the work
  never needed: the list is a shell array, so nothing is written to a filesystem
  and no path reaches a worker through a file anyone else can reach. Each worker
  is handed the exact path the parent captured, paired with its index, and
  answers with the index alone — the path travels outward, where NUL-delimited
  records carry anything, and only a number comes back, which cannot carry a
  delimiter at all.

  Every worker reports back — pass, fail, or that its file had gone missing before
  it ran — and the parent requires one record per file, refusing that third answer
  rather than guessing which of the other two it meant. Checking only for failures cannot tell "nothing failed" from "nothing
  ran": an inherited `xargs() { return 0; }` consumes no input, exits 0 and prints
  nothing, which is exactly what a clean suite looks like — and a status check
  does not see it either, because it succeeded.

  Three things a concurrent runner gets wrong that a loop cannot. Its status is an
  answer: `xargs` writes failures to stdout, so a runner that cannot start writes
  nothing — and nothing is what a clean suite looks like, so an unchecked status
  reported `status=clean` on a suite that never ran. The parallelism degree is a
  load bound, and `xargs -P 00` is unlimited, so every spelling of zero has to be
  refused rather than only the literal one. And a path cannot travel through the
  runner: `xargs` eats backslashes unless its input is NUL-delimited, and a newline
  in a directory name splits one failure into two on the way back — inventing a
  test name and inflating the count. So the path travels outward inside a
  NUL-delimited record and only its index comes back, an index being the one thing
  that cannot carry a delimiter.

## [2.0.12] — 2026-08-13

- **The Codex→Copilot transition is a script, and its refusals are executed.** It
  was 176 lines inside `SKILL.md` that nothing ran: capture the head, re-validate
  Codex against that exact sha, prove its checks, establish the round boundary,
  post the signoff, then either stop for the operator or take the pause — and, on
  the answer, revoke any stale Copilot signoff and request the pass.
  `pr-copilot-phase.sh` runs it in two stages, `record` and `open`, with the
  operator's decision between them,
  because the answer can arrive in a different session. `open` re-proves the head
  is still the one Codex signed off; opening the phase against a moved head spends
  the whole phase on one commit and the merge gate on another, and only the gate
  finds out.

  The phase summary was a heredoc the shell expanded. A body quoting a finding
  about a command substitution was EXECUTED while being written, and text lifted
  from an untrusted PR description is the same substitution with someone else
  choosing the command; where it did not execute it vanished silently and `cat`
  still succeeded. The caller now supplies a body file and the script inserts it as
  data, composing the signoff marker, the sha and the trailer note itself. A case
  asserts a body containing `$(…)` and backticks reaches the PR verbatim and
  creates no files.

  `open` also re-reads the VERDICT, not only the head: a review dismissed while
  the head stood still leaves head-equality passing, and the whole Copilot phase
  would be spent before the merge gate discovered that the recorded signoff no
  longer describes a clean review. A recorded signoff is history, not current
  state. And the round-boundary pause now records the signoff BEFORE it pauses —
  the pause offers "merge on the Codex signoff", so exiting first left the
  operator neither a durable signoff nor the sha that path needs, and they had to
  acknowledge the boundary and re-run the stage to recover a phase already proved
  clean.

  `open` re-reads the head once more immediately before the mutations: a push
  landing after the equality check but during the verdict or baseline probes left
  the pinned verdict clean — it is pinned to the old sha — while the revocation and
  the request landed on the moved PR, and `--add-reviewer` re-requests. And the
  round count is now read BEFORE anything is published and acted on after: a count
  that could not be read exited with the signoff already posted, so a later session
  accepted that record without anyone having established whether a boundary was
  due.

  67 cases in `test-pr-copilot-phase.sh`. Fifteen mutants killed: an unpinned
  verdict, an unproved head in `open`, a marker without the backticks
  `pr-signoff.sh` requires, a body expanded as a template, a request before the
  revocation, a missing CI gate, and a defaulted stage.

- **Prose that quotes a record becomes that record.** Four markers on a PR are
  control, not text: `pr-signoff.sh` reads `**Review-Signoff:**` and
  `**Review-Signoff-Revoked:**`, `pr-round-count.sh` reads
  `**Review-Pause-Acknowledged:**` and `**Reviewed commit:**`. **Three of them a
  caller-authored body can create**, and those are the three
  `rb_reserved_marker_line` refuses; the fourth is covered below. The bodies this
  loop
  posts are composed from findings, PR descriptions and reviewer comments and go
  up under an identity those readers trust — so a round summary quoting a finding
  about an acknowledgement PUBLISHED that acknowledgement, and the operator
  boundary it answered never fired again. Silently, and at exactly the round the
  boundary existed for.

  `rb_reserved_marker_line` in `recordlib.sh` refuses such a body. It is in the
  library rather than in either caller because `pr-close-round.sh` and
  `pr-copilot-phase.sh` both post caller-written text, which is the shape that ends
  up present in one and missing from the other. The rule is anchored exactly as the
  readers are — start of line — so indenting by four spaces or quoting inline still
  says what the author meant, and the check reports WHICH line to fix. A fenced
  block is NOT a way round it and is not offered as one: the readers scan the raw
  comment body, where a line inside a fence still starts at column 0.

  `**Reviewed commit:**` is deliberately not in the set. `pr-round-count.sh` reads
  it only from a comment whose author is a reviewer bot and whose body also says it
  found no major issues, so a body these callers post cannot create one — refusing
  it would stop an author describing the footer while preventing nothing.

- **Quoting the trigger requests a pass.** Any comment CONTAINING `@codex review`
  is a Codex request — the skill's own table says so — and two callers post a
  caller-written body with no request intended: the phase summary, after which the
  loop stops for the operator, and a Copilot round's summary, where only Copilot
  should be re-requested. A body quoting the mention out of a finding or a PR
  description started a Codex pass against a phase that had just stopped or moved
  on. `rb_review_trigger` refuses one in both; in a *Codex* round the mention IS
  the request and `pr-close-round.sh` writes it itself, so quoting it there changes
  nothing and is allowed.

  **Its remedy is not the marker remedy**, and the documentation said otherwise for
  a round: the trigger matches case-insensitively ANYWHERE in the body, so
  indenting or fencing a mention changes nothing — it has to be broken up or
  written without the `@`. The marker rule is the line-anchored one.

- **`open` proves the phase is still open at every window it can close in.** The
  head, the live verdict and the recorded Codex signoff are one predicate, asked
  up front, again immediately before the mutations, and once more AFTER the
  revocation — that comment is itself a mutation, and the window between it and
  the request is the one the request lands in. The ordering is decided by two
  constraints pulling against each other: the proof wants to be last, and the
  Copilot BASELINE must be last or a pass landing during the probes is accepted as
  the answer to a request made after it. So it is revoke, prove, baseline, request,
  and the fixture asserts that order rather than only its parts.

- **The record block reported failure on its ordinary path.** A trailing
  `[ "$PHASE_RC" -eq 3 ] && { … }` was the last command in `SKILL.md`'s block, so
  its FALSE value became the block's status: a phase that recorded, posted and
  parsed perfectly exited 1, and a driver reads that as a failed step and stops or
  retries — on the one path where nothing went wrong. It is an `if` now, and the
  contract test EXECUTES that shape rather than grepping for it, because the defect
  is what the last statement's status IS rather than how it is spelled.


- **`open` reads the recorded signoff, not only the verdict, and re-enforces the
  boundary.** Reopening the Codex phase over an unchanged head posts a revocation
  and requests a new pass, and GitHub keeps serving the OLD clean verdict until
  that pass reports — so the verdict recheck passed on a phase that had been
  deliberately reopened, and `open` would have revoked Copilot's signoff and
  re-requested it underneath. And because `record` publishes the signoff *before*
  it pauses, a later session could read that signoff back and reach `open` with the
  boundary still unacknowledged: the pause skipped by the very resume path the
  published signoff exists to enable. Both are checked before either mutation.

- **An assertion that dies instead of failing is worse than none, and three
  shipped.** The ordering checks in `test-pr-skill-contract.sh` read line numbers
  with `grep -n … | head -1`, under `set -Eeuo pipefail`. When the line they check
  was absent — exactly the case they exist for — the unmatched `grep` aborted the
  whole file: no FAIL, no `RESULT:` line, and a caller grepping for failures saw
  none. Found by mutating the document and getting silence instead of a failure.
  Every such lookup is now guarded.

  Fourth step of #26. `SKILL.md` is down to 527 lines of bash from 953.
## [2.0.11] — 2026-08-13

- **A review of nothing but replies is named, instead of being guessed at.**
  `pr-review-state.sh verdict` counts every comment row attached to the
  authoritative review, and a reviewer's own verdict is sometimes delivered as a
  REPLY on an existing thread — "No blocking findings on `87ad552`" arrived exactly
  that way.

  Counted as a finding, that is terminal rather than merely wrong: the count cannot
  drop, because the comment *is* the verdict. There is no thread to resolve and no
  fix to make, so the loop never closes and the merge gate blocks a PR its reviewer
  has passed. `pr-findings.sh` reported nothing to fix at the same moment, which is
  how the two disagreed — one asks for unresolved threads, the other counts comment
  rows.

  **The exemption is gone, and that is the finding of three review rounds.** A
  reply is not exempt: dropping every reply let a blocking finding posted as one
  merge unseen; matching the phrase let a reply that NEGATED it read as clean;
  matching a whole LINE let a reply that carries the verdict line and retracts it
  two lines later read as clean. The third is the general case — the real verdict
  is followed by paragraphs of explanation, and a retraction is also a paragraph
  after the verdict line. Separating them means a denylist of words meaning
  "except", one word behind forever, which this repository has already paid for
  once and written a rule against.

  So every comment counts, as before — and the answer now says WHEN THEY WERE ALL
  REPLIES. `verdict=findings findings=1 source=replies-only` is neither answer:
  `pr-findings.sh` lists nothing to fix and it is not a signoff, so the driver
  stops and a human reads one comment. That is the stuck loop solved where it can
  be solved honestly, rather than by guessing at intent.

  Every row is validated first. `in_reply_to_id` is absent or a number, never null
  and never a string, so a presence-only test silently discarded a malformed row as
  a reply — and a page of those counted zero, which is `clean`. `recordlib.sh` gains
  `valid_review_comment` and `opens_a_thread`, with their own accept/reject cases
  and a drift-guard entry, because a shared definition cannot be the untested one.

  `pr-watch.sh` learned the shape in the same change, because a new record is only
  a signal if its consumer accepts it: the watch validates the verdict tail
  strictly, so `source=replies-only` was classified as inconsistent, exited 2 and
  printed no `PR_REVIEW_READY` at all — the operator stop silently not happening,
  which is worse than the stuck loop it replaced. The tail is spelled out rather
  than made optional, and three unagreed tails are asserted to be refused.

  **And it has its own exit status, 4, because every caller branches on status.**
  Saying it in the record alone taught exactly one consumer: the driver's step 3
  table still sent the round on to step 4, where there is nothing to fix, and
  `pr-close-round.sh` — waiting on the pass a push starts — took the 0 and closed
  the round. Both are the stop not happening. `4` now stops the driver before the
  fix round and pauses the close-round gate, and the contract test requires every
  status the watch can exit with to be in the table the driver reads.

  **And the stop has an end, or it is only a different deadlock.** The verdict
  stays non-clean while that review is the newest, so re-running the watch returns
  4 again, no thread exists to resolve, and re-requesting is forbidden — the first
  version traded a deadlock for a permanent pause. The operator's answer now
  becomes state: if the comment was a clean verdict they record the
  `**Review-Signoff:**` line, and the merge gate accepts it FOR THAT SHAPE ONLY —
  a `source=replies-only` verdict plus a signoff naming that head merges and says
  so; a review with real findings is not a question anyone was asked, so a signoff
  never carries one. If the comment was a finding, fixing it moves the head and
  the round is ordinary again. Absence is not permission: the gate has a positive
  `signoff_vouches`, because the existing `signoff_contradicts` answers "does a
  record disagree" and NOTHING RECORDED is not a disagreement.

  **A head is not a moment.** The first version of that acceptance took a signoff
  naming the same sha as proof the operator had answered — but a signoff recorded
  for an EARLIER clean review on an unchanged head would then vouch for a LATER
  replies-only review nobody read. The record must be newer than the review it
  answers, so `pr-signoff.sh` carries `at=<createdAt>` (before `sha=`, because
  every caller reads the sha with `${line##*sha=}` and a field after it would be
  swallowed into the value) and `pr-review-state.sh` gained `review-at`. Equal
  timestamps refuse: GitHub stamps to the second, and merge permission is not a
  coin toss.

  The replies-only record is matched in full for the same reason — a `*` between
  `findings=` and the suffix accepted an empty count and any appended field, and
  that shape both bypasses the status gate and can authorise a merge.

  `in_reply_to_id: null` is "no parent", not a malformed record. github.com omits
  the key, so a first version rejected null as unreadable — and a host that
  serialises its nullable fields would then have made every ordinary finding page
  unreadable, stopping the watch with rc 2 on every review. A string or an object
  still is malformed.

  Both reviewer contracts now say to post a clean verdict as the review body or an
  issue comment rather than as a reply, since a reply-only review costs an operator
  a read — `AGENTS.md` and `.github/copilot-instructions.md`, plus `SKILL.md` and
  `README.md` for the driver and the user.

  The fixture pins the REAL payload shape, checked against the API: a top-level
  comment OMITS `in_reply_to_id` and a reply carries it, so a fixture written as
  `"in_reply_to_id": null` would prove nothing about the live case. Cases cover a
  reply-only review, a top-level comment, a review carrying both, a blocking reply,
  a clean verdict naming another head, and three malformed `in_reply_to_id`
  spellings. Found while driving #33; filed as #34 rather than fixed there, because
  a merge-critical helper does not belong in a PR about something else.

## [2.0.10] — 2026-08-12

- **Closing a round is a script, and both orderings live in one place.** The two
  recipes in `SKILL.md` — 56 lines and 191 — did the same job in deliberately
  different orders, and the order is the whole content: with automatic review OFF
  the `@codex review` mention is the trigger, so it carries the summary and nothing
  is queued until it is posted; with automatic review ON the *push* is the trigger,
  so nothing irreversible may happen before the checks are known.

  Neither was ever executed. `pr-close-round.sh` takes the mode as an argument and
  refuses an unrecognised one — guessing wrong there does not fail loudly, it
  closes the round in the wrong order, which is only visible afterwards.

  It runs in **two stages, with the thread replies between them**:
  `gate <pr> <reviewer> <summary-file> <auto-review>` pushes and proves the head,
  and `post <pr> <reviewer> <summary-file> <auto-review> <head>` re-proves that
  head and closes. Both recipes carried the boundary as a comment — `# reply +
  resolve threads here`, placed after the gate in each — and the first extraction
  dropped it, leaving the driver's own checklist, which runs *before* the push, as
  the only ordering. A resolve cannot be taken back: resolving first means a round
  that then fails to push, or pushes red, has already recorded its findings as
  answered on a commit that never landed, and with automatic review ON the pass the
  push starts reads threads already marked resolved with no summary saying what
  resolved them. `post` re-proves the head locally and on the PR, because answering
  threads takes as long as it takes and the gate's green verdict belongs to the
  commit the gate saw.

  `test-pr-close-round.sh` runs it: 70 assertions with `gh` and `git` stubbed and every
  call logged **in sequence**, because "did it post the summary" is a weaker
  question than "did it post the summary before or after it knew the head was
  green" — and the fixture performs the driver's thread replies as a line in the
  same log, so the ordering assertions span the two stages rather than stopping at
  the edge of one process. Reversing the gate and the request trips two assertions
  at once; moving the replies back before the gate trips three more. The 29
  greps and `awk` state machines that used to read those recipes out of the
  document are deleted rather than retargeted.

- **An empty review baseline is an answer, not a failure.** `pr-review-state.sh
  review-id` returns nothing when the current head has no review yet — which is
  every round that pushes a new commit, and every Copilot round, since a push
  never triggers one — and `pr-watch.sh` takes an empty baseline as "wait on any
  terminal review". The driver tested the VALUE for emptiness and aborted, *after*
  the summary was posted and the pass requested: the watch was never armed, and a
  retry posted the summary and requested the pass a second time. It now requires
  the closing RECORD and the `prior-review=` FIELD, and carries an empty value
  through. The fixture's `pr-watch.sh` stub was refusing that empty value too —
  stricter than the real script, which is the same defect as a stub that is looser.

- **The reviewer logins have one definition.** They were literals in
  `pr-merge-gate.sh` and in `SKILL.md`, and a third copy was about to appear. Every
  verdict check compares a record's `reviewer=` field against one of them as a
  string, so a login one character wrong matches nothing and the gate reports "did
  not return an exact clean record" for a reviewer that signed off perfectly. They
  are `RB_CODEX_BOT` and `RB_COPILOT_BOT` in `recordlib.sh`.

- **The merge gate's round-boundary pause now offers starting over**, like every
  other boundary message. Found by rewriting the assertion to follow the code —
  it had been counting occurrences of a phrase in one file, which goes green as
  soon as the count is reached anywhere.

  Third step of #26. `SKILL.md` is down to 627 lines of bash from 953, and the two
  round-closing recipes are now one that passes `$AUTO_REVIEW` through.

## [2.0.9] — 2026-08-12

- **The phase transitions are the operator's decision, and the loop stops for
  them.** A clean Codex verdict used to open the Copilot phase by itself, and a
  clean Copilot verdict walked into the merge gate. Neither is the loop's call: it
  has no view of urgency, or cost, or what the change is for, so left alone it
  always decides "more review". It now stops twice — after Codex, offering
  *merge now* against *open the Copilot phase*; and after Copilot, offering
  *merge* against *another Codex pass as fault tolerance over what the Copilot
  rounds changed*.

- **The Codex-only merge is actually reachable.** The stop above offers "merge now
  on Codex's signoff alone", and the gate rejected it: it demanded an exact clean
  Copilot record on the head, and with no Copilot review requested there is none.
  `pr-merge-gate.sh` takes a reviewers mode now. `codex-only` is not a weaker
  gate — the two-reviewer path tolerates a head that advanced past Codex's signoff
  because every commit since carries a `Review-Phase: copilot` trailer, and with no
  Copilot phase there are no such commits and nothing licenses the delta. So it
  requires the head to **be** the commit Codex signed, which is narrower.

- **A signoff survives the session that earned it.** The Codex-signed head lived
  in a shell variable and was printed to the terminal, so closing it lost the one
  fact the phasing rests on. Each phase now records
  `**Review-Signoff:** <reviewer> <sha>` on the pull request, and
  **`pr-signoff.sh`** reads it back: repo-local, machine-independent, visible to a
  human scrolling the thread, and supersedable by a later record. It is what makes
  the two stops resumable rather than dead ends. Only OWNER, MEMBER or
  COLLABORATOR comments count — a signoff skips a review phase, so a passer-by
  must not be able to grant one — and a marker quoted inside prose is not a
  signoff, which the anchored read enforces.

- **The round check-in offers closing the PR and starting over.** It said "decide
  with the operator" and named continue, merge, leave open, abandon. The option it
  never raised is the one a loop cannot raise for itself: that ten rounds is
  evidence about the *approach* rather than about the defects left. This
  repository has the worked example — fifty-two rounds on a text scanner, then
  eleven on what replaced it. The check-in now says so, and asks for what the
  rounds have been *about* rather than only how many there were.

## [2.0.8] — 2026-08-12

- **The merge gate is a script, and its decisions are executed by tests for the
  first time.** 291 lines lived in a fenced block in `SKILL.md` and were pasted
  into the driving session's shell. Nothing ran them — which is precisely how that
  block came to contain a construct the bash macOS ships cannot *parse*, for fifty
  review rounds, while `test-pr-skill-contract.sh` reported the gate present and
  correct from twenty-four `grep`s for the spelling of individual lines.

  `pr-merge-gate.sh <pr> <codex-sha> <auto-review>` keeps every decision in the
  same order and adds a distinction the block could not express: **0 merged,
  1 blocked, 3 paused, 4 queued**. The round-boundary pause is not a refusal — a caller that
  cannot tell them apart either treats an operator's decision as a failure or a
  failure as a decision, and merging is the largest irreversible action here.

  `test-pr-merge-gate.sh` runs it: 43 cases across every refusal path, the pause
  and the merge itself, with `gh` and each helper stubbed. Among them, executed
  rather than read: a head lookup that prints a plausible sha and *then* fails; a
  state record that is well-formed but about another PR, head or reviewer; a
  verdict line with trailing text; Codex's own record standing in for Copilot's; a
  GraphQL 200 carrying `errors`; nodes without a boolean `isResolved`; a repeated
  pagination cursor, which without its guard hangs the gate rather than refusing;
  and the in-flight auto-review case, paired with its auto-review-off twin so that
  the setting is demonstrably the only difference.

  The twenty-four spelling greps are deleted rather than retargeted at the script.
  A grep beside an executed case tests the spelling, not the behaviour.

  `AUTO_REVIEW` is an **argument**, not an environment variable — the lesson from
  the previous extraction, where a value assigned without `export` reached a
  function and not a child. This one decides whether an in-flight Codex pass may be
  ignored, so a silent default is a merge on a verdict nobody read; an unrecognised
  value is refused rather than assumed to mean `no`.

  **A queued merge is no longer reported as a merge.** `gh pr merge` reports
  success for *adding* a PR to a merge queue — its own help says so — and the PR
  can leave that queue later without landing. The block this replaced printed
  `merged` and finished. The gate now reads the PR state back and reports **4,
  queued**, because `--admin` bypasses the queue and this is therefore reachable
  exactly in the mode an operator chose for safety.

  **The gate runs in the repository the session started in.** It derives its
  identity and range-check root from the current directory, so a `cd` into another
  checkout between setup and the merge would point every gate — and the `--admin`
  merge — at whatever PR of *that* repository shares the number.

  Second step of #26. `SKILL.md` is down to ~595 lines of bash from 953.

## [2.0.7] — 2026-08-11

- **The CI gate is a script, not a function defined in `SKILL.md`.** About a
  hundred lines of shell lived in a fenced block in that document, were pasted into
  the driving session's shell, and were called from four sites. Nothing checked
  them: the suite, `pr-selfcheck.sh` and the `macos-shell` job all cover
  `scripts/`, and none of them can see shell inside a Markdown file —
  `test-pr-skill-contract.sh` had resorted to `sed`-ing the function back out of
  the document in order to execute it.

  `pr-ci-gate.sh <pr> <head-oid>` takes the same arguments, honours the same
  `PR_CI_*` bounds, prints the same diagnostics, and returns the same 0/1. Its
  behavioural cases moved with it into `test-pr-ci-gate.sh`, where they run the
  real subject; what stays in the contract test is what belongs there — that the
  driver *calls* the gate, at every site that accepts a head, pinned to an OID, in
  the right order.

  Two things disappeared rather than moved. The `unset -f` / clearing-check /
  `type -t` dance existed only because a function pasted into a session that may
  already have one can be shadowed by a `readonly -f` copy, and a stale gate
  returning 0 lets a red head close its round; a process cannot be shadowed that
  way. And the contract test's check that every name the gate assigns is declared
  `local` — a leak into the operator's shell — is now enforced by the process
  boundary instead.

  First step of #26, which records the remaining ~840 lines.

## [2.0.6] — 2026-08-11

- **`pr-watch.sh` never ran on macOS, and neither did the merge gate in
  `SKILL.md`.** Bash 3.2 — the bash macOS ships — cannot *parse* a
  `[[ … =~ … ]]` whose pattern is written inline and contains a parenthesis. It
  is not a feature that degrades: the shell rejects the whole file with
  `syntax error in conditional expression`, before the first statement runs.
  Three sites carried one, from the day each was written. The portable spelling
  holds the pattern in a variable, where it is a string to the parser and a regex
  to the match.

- **A comment was being executed at here-document time.** `test-pr-ci-state.sh`
  writes its `gh` stub through an unquoted delimiter — it has to, the stub needs
  `$TMP` expanded — and a comment inside the body named two mutants in backticks.
  Those ran as commands every time the fixture built a stub.

- **CI runs the suite a second time on a machine shaped like a Mac.** A new
  `macos-shell` job builds **bash 3.2.57** from source — the base release with the
  official patch series 001–057 applied, which is the patch level macOS ships —
  puts it *first on `PATH`* so the suite's `bash -c` calls and
  `#!/usr/bin/env bash` helpers reach it too, and removes the GNU-only tools.

  The patches are not cosmetic. Building 3.2.0 and calling it "3.2" would have
  been *more permissive* than a Mac, not less: the environment-function hardening
  in the 052+ range rejects input the base release accepts, and this suite exports
  functions. The job now asserts the exact patch level rather than a `3.2` prefix,
  and both the tarball and the patch series are pinned by digest — the series as
  one digest over all fifty-seven files concatenated, so any of them changing fails
  closed. Both defects above were found by it. It closes the
  case for which #15 was filed — `timeout`, `sha1sum` and `seq` had each reached
  the tree and each was caught by review — without asking anything about what the
  text of a script looks like.

  **The classes it cannot see are now in the reviewers' own instructions.**
  `AGENTS.md` and `.github/copilot-instructions.md` carry a table of the GNU-only
  flags, the regex escapes and the unexecuted-branch gap. Copilot reads only its
  own file and follows no pointers, so an acknowledged CI gap recorded in
  `CLAUDE.md` alone was missing from one required reviewer's contract.

  **The job builds its own `PATH` rather than hiding names from the runner's.**
  The first version hid a denylist of GNU tools; `flock`, `setsid` and `taskset`
  were missing from it, and `getent`, `ip`, `ss`, `lsns`, `findmnt` and
  `mountpoint` were missing from the version that added those. Each round answered
  one finding and produced the next — the shape that got the text scanner deleted,
  reappearing in a different file. So `PATH` is now *replaced* with links to an
  explicit list of commands stock macOS has, plus the three a contributor installs
  (`git`, `gh`, `jq`). A command nobody thought of does not resolve, which closes
  the surface instead of tracking it. When the list is short by a portable name
  the job fails loudly with `command not found` — a false alarm rather than a
  false green.

  The one item from that issue it does **not** close is `\s` in a `grep` pattern:
  BSD `grep` does not fail on it, it matches a literal `s`, so the suite passes
  and the behaviour is silently wrong. That is recorded on the issue and left to
  review.

- **`SKILL.md`'s merge gate is executed by the contract test, not just grepped.**
  The head-state condition is lifted by two anchored `grep`s and run against a
  valid record, one with trailing text, and the rc-0 noise a wrapper prints — under
  whichever bash runs the suite, so 3.2 in the `macos-shell` job. A grep cannot
  tell whether the interpreter can *read* what it matched, which is the whole
  subject here.

  A sweep that extracted and parsed *every* fenced block was built for this and
  removed. Reaching the code means parsing Markdown, and four rounds went to fence
  spellings — indented, four-backtick, tilde, trailing whitespace, info-string
  metadata, a dedent that removed characters that were not there — two of which
  rejected valid source. The remaining ~950 lines of shell in that file are
  unchecked, on the record, as #26: the fix is to move them into `.sh` files, where
  the suite and the 3.2 job already cover everything for free.

- **CI ran everything twice.** `push` on every branch plus `pull_request` fired
  both workflows for every push to a PR branch — the same commit, the same answer,
  twice. Pushes to the default branch are covered directly; everything else as a
  pull request.

- **A text scanner for this was built and deleted.** It reached 2,200 lines and
  fifty-two review rounds. Every round it answered one finding and produced the
  next, and several of its own defects *rejected portable code*, which is worse
  than a miss: it converts an unverified assumption into a green tick. What it
  bought over running the suite was coverage of unexecuted branches; what it cost
  was the review budget of an entire release. `CLAUDE.md` records the same shape
  being built and deleted twice before, and now says plainly not to build it a
  fourth time.

## [2.0.5] — 2026-08-08

**How a shared library is loaded lives in one place.** The clear-source-verify
sequence existed in four scripts, and every rule in it was added *after* a copy
was found missing it. Closes #22 and #20. No behaviour changes for a correctly
installed plugin; what changes is that the next library cannot repeat the history
of the last three.

- **Each rule arrived late, in whichever copy was under review.** Clearing an
  inherited symbol, because Bash exports functions through the environment and an
  empty library still sources successfully — the verification then finds the
  inherited symbol and reports the library loaded. Taking the *clearing's* status,
  because `readonly` makes the unset fail while leaving the old definition
  installed. Verifying the library defined anything, rather than treating a
  successful `.` as a loaded library. What a stale library costs differs per case —
  the wrong repository, an unvalidated record, a watchdog that does not kill — but
  the loading rule is identical.

- **`rb_load` takes the KIND, and getting it wrong is refused rather than
  guessed.** `RECORDLIB_JQ` is a variable, and an exported one satisfied its
  `[ -n … ]` check against an empty library exactly as an exported function
  satisfies `type -t` — that hole was still open in three scripts (#20). A
  variable needs `unset` and a non-empty test; a function needs `unset -f` and
  `type -t`. Guessing from the name would be silent when wrong: a variable checked
  as a function is always absent and a function checked as non-empty is always
  empty, so both refuse everything, which is a tool nobody can run rather than one
  that fails closed.

- **`pr-watch.sh` was the caller the invariant did not cover.** It sourced
  `recordlib.sh` by hand, without clearing `is_full_sha`, while CLAUDE.md said
  every helper went through the loader — an invariant is only as true as its
  least-checked caller. It goes through `rb_load` now, and the coverage list
  includes it.

- **The error prefix is the caller's, whole.** `pr-watch.sh` reports `state=error`
  where the others report `status=error`, so a loader supplying the key would
  either impose one spelling on a script whose every other line uses the other, or
  emit `state=error status=error`. It knows the reason; the caller knows how it
  says "this failed".

- **The bootstrap obeys the rule it cannot use.** An exported `rb_load` plus an
  empty `loadlib.sh` leaves a *stale loader* doing the clearing and verifying for
  every other library — the one way to make every subsequent load look clean. All
  four lines, clearing included, with the clearing's status taken.

- **The bootstrap is the one thing that cannot use it.** Every caller writes four
  lines to load `loadlib.sh` — clear, take the clear's status, source, verify —
  because a helper cannot load the file that defines it. Four and not three
  deliberately: taking the clearing's status is a separate part of the invariant,
  and calling it three anywhere is how that step comes to be collapsed.

## [2.0.4] — 2026-08-08

**A round is no longer closed on a red head.** CI was red for four consecutive
commits on one PR and neither the round loop nor the pre-push self-check noticed:
every round was closed as green on the strength of a local suite run, and the
operator had to point at the checks tab. Issue #16.

- **"The suite passes here" and "the checks pass there" are different claims, and
  only the first was being made.** `pr-selfcheck.sh` runs the suite before the
  push; it cannot see a failure that only happens on the runner — and that one
  only happened there, because GitHub Actions ignores `SIGPIPE`, so a `printf`
  losing a pipe race returned 1 instead of dying with 141. `gh pr checks` *was*
  consulted, but only in the merge gate, which on that PR was many rounds away.

- **`pr-ci-state.sh`, called by both gates.** The merge gate already asked this
  question in about seventy lines inline; writing them out again for the round
  loop is the defect issues #11 and #18 were both opened for. `--required`
  separates the two questions: the merge gate asks whether branch protection is
  satisfied, and the round gate asks whether the commit just pushed is broken —
  where a failing *non-required* check still counts.

- **Pending is not green.** The checks start when the push lands, so asking
  immediately always finds them running; treating that as a pass would close every
  round before its own CI had said anything, which is the original defect with an
  extra step. The gate waits, and because a wait that never ends is a hang, it is
  bounded by `PR_CI_TIMEOUT` (default 1800s, polled every `PR_CI_INTERVAL`).

- **The gate is asked about the commit it pushed, not about the PR.**
  `gh pr checks` is addressed by PR number and answers about whatever the API
  currently calls the head — and for a moment after a push that is still the
  *previous* head. A green answer then describes the commit from the round
  before: the last round's answer to this round's question, and it reads as
  permission to close. `--head <oid>` reports `stale` for that, and the gate waits.

- **Green requires a probe that succeeded.** `gh` can emit a complete, valid green
  result and then exit non-zero because the request failed part-way, and command
  substitution keeps what it printed. Green is the one verdict that opens a gate,
  so it is the one that may not be taken on trust — in the merge gate that is an
  administrator merge on an untrusted partial response.

- **"No checks yet" is not "no checks".** A workflow run is registered a moment
  after the head moves, so the first probe after a push legitimately reports
  `none` on a repository that does have CI. Taking that as permission to close
  reproduces the red-head closure with an extra step, so it has to hold for
  `PR_CI_GRACE` seconds before it is believed.

- **A verdict that would close the round has to hold.** Both `green` and `none`
  can be true of an incomplete picture: a push that triggers two workflows can
  have the fast one registered and passing before the second is registered at
  all. Closing on that reproduces the red-head closure with an extra step — the
  later workflow appears and fails after the round is already closed. So either
  verdict must still be the answer `PR_CI_GRACE` seconds later, and anything else
  restarts the count, because the picture changed.

- **The timeout is a duration, not a sum of sleeps.** Counting only the sleeps
  excluded however long each probe took, so two slow `gh` calls per iteration
  silently turned the documented thirty-minute bound into ninety. It is measured
  from elapsed wall time around the probes.

- **The deadline outranks a stable verdict.** With the timeout checked at the
  bottom of the loop, a `PR_CI_TIMEOUT` shorter than `PR_CI_GRACE` — or simply a
  probe returning green after the deadline — closed the round past its own bound.
  A bound a verdict can step over is not a bound.

- **The checks response is bound to the head, not merely preceded by a check of
  it.** The confirmation and the checks call are two requests, and a push landing
  between them means the answer describes a commit nobody verified — a head that
  had almost finished earning its grace hands it to a different commit whose own
  checks are not registered yet. The head is read again afterwards and any
  movement is `stale`, which resets the grace.

- **Nothing irreversible happens before the verdict, in either mode.** The
  automatic path used to close the round first — resolve the threads, post the
  summary — and push last, so the pass the push starts would find both in place.
  That ordering cannot be gated: by the time the checks can be consulted, both
  are done, and a later "this round is not closed" comment is a record rather
  than a retraction — and itself a call that can fail. The push moved ahead of the
  closure.

  **What that costs is stated:** the pass the push starts reads open threads and
  no summary, so it may re-report what the round already answered. It is
  superseded by an explicit `@codex review` — now sent in automatic mode too,
  which also removes the three-head comparison that used to decide whether a
  no-op push needed one. A wasted pass is recoverable; a round closed on a red
  head is not.

- **The polling bounds are validated.** `PR_CI_INTERVAL=0` sleeps zero seconds and
  leaves the elapsed count at zero forever; a non-numeric `PR_CI_TIMEOUT` makes
  the comparison fail on every iteration. Either one turns the supposedly bounded
  gate into an unbounded API-polling loop, so both fall back to their defaults.

- **A stale `ci_gate` cannot satisfy the gate.** It runs in the driving session's
  own shell, where `readonly -f` makes a redefinition fail while leaving the old
  function installed — and a stale gate that returns 0 lets a red head close its
  round, the defect arriving through the gate itself. Cleared and checked, exactly
  as `rb_identity` is.

- **Every path that accepts a head has seen its checks, not only the paths that
  pushed.** The gate lived at the two push sites, and a PR whose reviews were
  clean from the start never pushes anything — so it went through both phases and
  into a merge gate that reads only *required* checks, which a failing optional
  one is not. The phase transition and the merge gate run the all-checks gate too.

- **Each probe is bounded.** A `gh` call that hangs on a dead connection never
  returns, and `PR_CI_TIMEOUT` is then not a bound at all: the gate cannot reach
  its own deadline check. Every request runs under `PR_CI_PROBE_TIMEOUT` through
  the portable watchdog, which makes `testlib.sh` a runtime dependency rather than
  a second copy of ninety tested lines.

- **A `run_limited` fallback that merged stderr into stdout.** Folding them was
  invisible while every caller was a fixture capturing `2>&1` anyway — and then a
  runtime caller appeared that distinguishes them. `pr-ci-state.sh` decides "no
  checks are configured" by matching the whole `gh` diagnostic on stderr; merged,
  its own capture received nothing, so on any platform **without GNU `timeout`** —
  stock macOS — a repository with no checks blocked every round and every merge.
  The fallback is the only path there, so the defect was invisible wherever
  `timeout` exists.

- **The push-triggered pass is waited out before the next baseline is taken.** In
  automatic mode a push that moves the head starts a Codex pass, and it can still
  be running when the CI gate returns — CI settling in ninety seconds while a
  review takes a hundred and twenty is ordinary. A baseline taken then is the id
  *before* that pass, so it lands, satisfies `--after-review`, and the loop
  advances while the request it was meant to answer is still queued. It is
  serialised, only when the push actually moved the head, and a wait that times
  out stops the round rather than continuing.

- **An expired deadline is not a short deadline.** Both new clamps turned an
  exhausted budget into a fresh second, and each of those calls can take that
  second plus the watchdog's five-second escalation — the bound becoming a floor.
  The gate checks the clock before starting a probe as well as after, and the
  helper refuses rather than renewing.

- **A `timeout` that cannot escalate is not used at all.** Falling back to a plain
  `timeout` when `-k` is unsupported restored exactly the defect the escalation
  exists to fix. The portable path polls and sends KILL itself, so it is strictly
  better than a watchdog that cannot; `-k` is the only reason to prefer the
  external one.

- **The GNU `timeout` arm escalates to KILL.** It sent TERM and stopped there;
  `timeout --help` says plainly that a caught or blocked TERM does not kill the
  command. A hung wrapper, or a child that traps TERM, outlived the limit — and
  that is the arm that runs wherever GNU coreutils exist, which is to say almost
  everywhere. The `-k` support is probed once and cached, because not every
  `timeout` takes it and a usage error is indistinguishable from the command
  failing.

- **A `none` verdict from a probe that died is not a verdict.** `gh` reports
  "nothing to report" by exiting 1 with that message on stderr; a probe that
  printed the same message and then hung carries identical text. `none` is
  accepted by the round gate after its grace and by the merge gate at once, so
  ignoring the status turned a hung request into merge permission.

- **The helper's deadline is shared across its probes, not granted per call.** It
  makes up to three sequential requests; with the full allowance each, a
  five-second budget could be spent three times over.

- **The push-triggered pass is waited out in the Codex phase only.** A push never
  triggers Copilot, so there was nothing to wait for — and waiting anyway meant
  every Copilot round that moved the head sat until the watch timed out and exited
  *before* `--add-reviewer` was reached. The phase where automatic review does
  nothing is the phase where serialising it stalls everything.

- **Each probe is bounded by the gate's remaining time**, not only by its own
  default: with `PR_CI_TIMEOUT=1` a hung request ran for the full sixty seconds
  before the loop could look at the clock. A bound the callee does not know about
  is not a bound.

- **The review baseline is taken after the push, not before it.** In automatic
  mode the push starts a pass that can *finish* during the CI wait — the gate
  waits for checks, and a Codex pass on a small diff can be quicker. A baseline
  captured before the push accepted that early pass as the answer to the request
  made after it, so the loop could advance to Copilot, or to the merge gate, while
  the summary-aware pass was still running.

- **An unrecognised bucket is malformed, not benign.** `pass` and `skipping` are
  green, `fail` and `cancel` are failures, `pending` is pending — and anything
  else is an error rather than falling through a catch-all, which is the shape
  that let an unknown review state be reported as a withdrawal and drive a review
  loop.

## [2.0.3] — 2026-08-08

**The identity parser lives in one file.** The ~60 lines that turn
`git remote get-url origin` into `$HOST/$OWNER/$REPO` existed in **four** places —
`pr-findings.sh`, `pr-review-state.sh`, `pr-round-count.sh` and `SKILL.md` —
byte-identical in the three scripts apart from the sentinel in their error lines.
No behaviour changes for a correctly-configured checkout; what changes is that a
rule can no longer hold in one copy and not another. Issue #18.

- **Why four copies was a defect and not a style complaint.** Both the
  hostless-origin rule and the file-transport rule had to be written into all
  four, and the fixtures proving them had to be built a **second** time afterwards
  to cover the copies that had silently missed one — `test-pr-identity.sh` still
  carries the comment recording it: *a rule proven in one copy is unproven in the
  others*. What a drifted copy costs is not an error: an origin whose host cannot
  be derived, defaulted to `github.com` while the path split still yields a
  plausible `acme/widget`, points every `gh` call at the unrelated **public**
  repository of that name — reading, commenting on and merging there.

- **`rb_identity` sets `HOST`, `OWNER` and `REPO` rather than printing them.** The
  obvious signature, `id="$(rb_identity)"`, runs in a subshell and has to
  serialise three values through one string. Any delimiter is then a value a
  remote can contain, and a remote carrying it shifts the fields — OWNER read as a
  host, REPO read as an owner — which is precisely the wrong-repository failure
  the parser exists to prevent. The transport does not get to reintroduce it.

- **`SKILL.md` locates the helpers before it loads the parser.** The driver's own
  copy was written out above the helper-path discovery, so delegating meant
  reordering: `RB_SCRIPTS` is resolved and validated first, and the contract test
  asserts that order — sourcing from an unset path aborts at step zero on every
  repository, which is a tool nobody can run.

- **The drift guards follow the code.** `test-pr-identity.sh` scanned
  `pr-*.sh`, a glob that reaches no file named `*lib.sh` — so the one file that
  now decides which repository every call addresses would have left its coverage
  entirely while it went on reporting that no runtime script hard-codes an
  identity. It scans the shared libraries too now, and the contract test fails if
  `SKILL.md` grows its own copy of the parser back.

- **`pr-selfcheck.sh` follows what `SKILL.md` sources.** Its undefined-variable
  scan read only the skill's own text, so `HOST`, `OWNER` and `REPO` — assigned by
  the library the skill sources — were all reported as used-but-never-assigned.
  That is the check being wrong about the skill rather than the skill about
  itself, and a check that fires on correct code is a check that gets switched
  off. The libraries are discovered from the `.` lines rather than listed, because
  a list goes stale silently; a library named but not readable is an error, since
  an empty set of assignments would reinstate exactly the false findings.

- **An inherited definition no longer satisfies the parser-load check.** Bash
  exports functions through the environment, so a caller that had run
  `export -f rb_identity` leaves one defined before the `.` — and a library that
  is empty or truncated above the definition still sources *successfully*. The
  `type -t` guard then found the inherited function, reported the parser loaded,
  and every `gh` call was addressed by whatever that stale version derived. All
  four callers clear it first, so the check proves what it claims: that **this**
  library defined it.

- **…and a definition that cannot be *cleared* is a load failure too.** The first
  fix was `unset -f rb_identity 2>/dev/null || true`, and `readonly -f` makes that
  unset fail while leaving the function installed — so a discarded status made a
  definition that could not be removed read exactly like one that was never there.
  Unsetting a name that is not defined returns 0, so a non-zero status there means
  only one thing. Reachable in `SKILL.md`, whose bash runs in the driving
  session's own shell; the readonly attribute does not survive function export, so
  a separate helper process never inherits one.

- **A sourced library DECLARES what it assigns; `pr-selfcheck.sh` reads it.**
  Inferring from the body was tried three ways and each was wrong in the quiet
  direction: every assignment in the file credited `unused() { TOKEN=x; }`, which
  sourcing never runs; restricting to called functions still credited an
  assignment after a `return`, and one inside an untaken branch. Deciding that
  statically is a reachability analysis, and a wrong answer reads as "this
  variable is fine" — so `$TOKEN` in `SKILL.md` came out assigned and the gate
  reported clean over a value the driver expands and nothing ever sets. That is
  the false-clean direction, reached through the branch added to remove a false
  *finding*. `identitylib.sh` carries an `# rb-assigns:` line instead, a library
  with no declaration is an error, and `test-identitylib.sh` proves the
  declaration true in both directions: every declared name is set by a successful
  call, and a call sets no global the declaration does not name.

- **The matching-test gate discovers the libraries instead of listing them.** The
  list named `testlib.sh` and `recordlib.sh`, so `identitylib.sh` sat outside the
  gate entirely and deleting its test left `pr-selfcheck.sh` reporting that every
  shared library has one. A list of the files a rule covers goes stale silently,
  and silently is the direction that turns a guard into a green tick over nothing.

- **A refused origin leaves the identity untouched.** The parse ran straight into
  the globals: `OWNER` and `REPO` were set for every input before any check, and
  the `ssh://` arm set `HOST` to an empty string and only then returned
  `origin_host_unparseable` — so a refused origin left a half-derived identity
  behind, which is the opposite of what a failing call is supposed to
  communicate. A caller that exits on the non-zero never sees it; one reading the
  values after a guard it got wrong sees a plausible `acme/widget` with an empty
  host. Everything parses into locals and the globals are written once, after all
  validation.

- **A branch that had never been exercised now is.** `origin_host_unparseable`
  had no fixture in any of the four copies: a mutant removing the check survived
  the entire suite. An `ssh://` URL with no authority, and an SCP-style remote
  with nothing before the colon, both reach it — and both would otherwise hand
  every `gh --hostname` call an empty host.

## [2.0.2] — 2026-08-07

**The working discipline is written down, on both sides of the loop.** No
**shell-script logic** changes — but `SKILL.md` *is* the shipped driver contract,
so this release does change how a session behaves. Deferral reasoning moves out of
the review-request summary, finding bodies may no longer be read through the REST
comments endpoint, and new rules decide which fixes a session applies at all.
Calling that inert would be wrong; every rule below was already what a good round
looked like, and none of it was stated where it binds.

- **Finding bodies come from the helper, never from the REST comments endpoint.**
  `pulls/N/comments` has no resolution filter and returns every review comment the
  PR has ever had, so reading bodies there hands the driver findings answered
  three rounds ago mixed into the current set — and fixing an already-answered
  comment is precisely the scope expansion these rules forbid.
  `pr-findings.sh list` already prints each unresolved finding's complete body.

- **A deferral is recorded as a disposition, not a description — in every copy of
  the rule.** Three files asked the summary to say what was skipped *"and why"*,
  which invites the unfixed defect and its rationale into the `@codex review`
  mention. `SKILL.md`, `CLAUDE.md` and `README.md` now agree, and the contract
  test fails if any of them asks for the reasoning again.

  The mechanism: the summary shares a comment with the `@codex review` mention,
  and a mention describing an *unfixed* defect is read as a task — Codex runs as a
  coding agent and commits in an environment with no remote, spending the round.
  Past-tense disposition and a bare issue number; the defect itself stays out.

- **A wrong reply on an old thread is a finding only when the code is still
  defective.** A reply that is merely inaccurate about its own history, while the
  changed code is correct, is not a defect on a changed line — filing it inline
  would block the merge to correct the record.

- **The contract guard uses a POSIX character class, not `\s`.** `\s` is a GNU
  extension; BSD `grep` on stock macOS — which `README.md` lists as supported —
  reads it as a literal `s`, so the guard searched for "evens*when", failed, and
  killed the round on correct text. The whole suite is a mandatory pre-push gate,
  so that stops a macOS contributor closing a round while CI stays green. Fourth
  GNU-only construct to reach this repository after `timeout`, `sha1sum` and
  `seq`; a mechanical guard against the class is filed as #15.

- **A regression the fix itself introduces is always this round's work.** The
  out-of-scope rule said a different defect found while fixing is "never in
  scope", which would have the driver defer a defect it had just caused — part of
  what the PR changed, and on its way to a merge if the next reviewer missed it.
  The line is drawn at *pre-existing*, not at whether it was the defect named — a
  **different pre-existing** defect stays out of scope, while the same defect in a
  copy this PR also changes is part of the finding and gets fixed with it. A
  *different pre-existing* copy in an untouched file stays out — but an untouched
  file this PR **broke** does not: repairing a consumer a changed validator or
  producer breaks is finishing the change, not widening it.

- **Scope discipline and the class-wide self-check are reconciled.** One rule says
  fix only what the finding names; the self-check asks whether you fixed the
  instance or the class. They meet on scope: the finding names a **defect**, not a
  line, so the same defect in another copy is the same finding — but only within
  what this PR already changes. The same shape outside the diff is recorded and
  left to the operator, and a *different pre-existing* defect found nearby is not in
  scope — a regression the fix itself causes always is.

- **Mutation proof is not waivable by disclosure.** The contract briefly offered
  "say so in the summary" as a way out. A summary is untrusted context, not
  authority: closing a round on "no mutant is claimed" leaves an assertion that
  passed before the fix while the suite and the self-check both report green.
  Where a mutation genuinely cannot be constructed, the limitation is written as a
  comment at the site and the round stops for the operator. That comment
  **explains rather than accepts**: added in the pull request, it arrives with the
  change and is untrusted context like any other, so a reviewer is right to keep
  reporting the missing proof. Acceptance is a dated record landed on the base ref
  by its own PR, as `docs/decisions/2026-08-06-merge-admin-default.md` was.

- **The skill now binds the driving session to a scope discipline.** The failure
  mode of an automated fix loop is not laziness, it is enthusiasm: fixing more
  than was asked, building more than the finding requires, and bundling both into
  a commit whose summary says "closing review comments" — where a reviewer has no
  reason to look for it. `SKILL.md` states six rules as a contract: fix what the
  finding names and nothing else; build the smallest thing that makes it false;
  every change must be reviewable as a fix; validate a finding before acting on
  it; prove a fix can fail; say what you did not do.

- **The driver is told to read a finding whole.** `pr-findings.sh list` prints one
  line per thread so the set is countable — that line is not the finding. The
  reviewers write a title and then the argument: the triggering input, the
  consequence, and often a note that the same defect exists in a second copy.
  Acting on the title alone produces a fix aimed at a paraphrase. A code
  suggestion is now explicitly a **proposal**, weighed against context the
  reviewer could not see, with the reasoning recorded in the thread if it is not
  taken.

- **Reviewers are pointed at the replies on earlier resolved threads.** They
  record why a line is shaped as it is and which alternative was already tried, so
  reading them avoids re-raising something settled with evidence several rounds
  ago. A wrong reply is a finding **only when its error means the changed code is
  still defective** — a reply inaccurate merely about its own history, while the
  code is correct, is not a defect on a changed line, and filing it inline would
  block the merge to correct the record. Context, never permission, like
  everything else arriving with the change.

- **What a well-formed finding contains is now stated.** The author is told to fix
  what the finding names and nothing else, so an under-specified finding produces
  either a wrong fix or another round. A finding names the triggering input, the
  **consequence** in terms of what this tool does, and the **scope** — any second
  copy of the same defect **that this PR also changes**, since a copy in an
  untouched file is an out-of-scope problem the author is forbidden to pull in. Both reviewer files carry this; the contract test
  asserts it in each, because `.github/copilot-instructions.md` restates the
  policy inline and is exactly the copy that drifts.

- **`README.md` says when to use it, and when not.** It is worth reaching for on
  anything you would want a colleague to read; it is worth less on a typo fix,
  vendored files or a throwaway spike. A PR with no clear stated goal produces
  vague findings and long rounds, because the goal is the one input the whole loop
  calibrates on — and a loop running long is information, usually that the change
  should be split.

## [2.0.1] — 2026-08-07

**One definition of a well-formed record** (issue #11).

- **The field checks are shared rather than re-implemented.** Four helpers read
  the same two endpoints and each carried its own copy of the same validation.
  That is not a style complaint — it is a defect generator, and it produced real
  findings four separate times: `commit_id` as 40-hex was added to one script,
  then a second, then a third; a canonical UTC `submitted_at` followed the same
  path; and the known review-state set reached two helpers and stopped. It sat
  missing from `pr-review-state.sh` for eleven review rounds, where an
  unrecognised value fell through `head_review_snapshot`'s catch-all as
  `dismissed` with status 0 — an actionable "the review was withdrawn", which the
  driver answers by requesting another pass. A malformed page drove a review loop.

  `recordlib.sh` now defines `valid_review_record`, `valid_comment_record`,
  `pages_or_error` and `is_full_sha` once, and the four helpers source it.

- **A misplaced phase trailer is named as such, not reported as missing.** `git`
  parses trailers from the LAST paragraph of a message only, so
  `Review-Phase: copilot` written with a blank line above it is not a trailer —
  the commit looks correct to anyone reading it, and the merge gate reported
  `untagged_commit`, asking for a trailer that is plainly already there.
  `pr-merge-range.sh` now distinguishes the two, and `SKILL.md` says where the
  trailer has to go rather than only that it must exist. Found by making the
  mistake while following the contract, which is the evidence that the contract
  was insufficient.

- **A comment without a canonical `created_at` is refused.** GitHub always sets
  it, so a record without one is malformed — and `pr-round-count.sh` counts these
  comments as rounds without reading the field, so a malformed record was
  countable. That is the unsafe direction: an extra round pushes the count past
  the operator check-in.

- **A record without an `id` is refused.** GitHub always returns one, and the
  watch compares it between polls to tell a new review from the one it already
  reported — a record without it cannot be distinguished from another and must
  not be counted as a pass. Two helpers previously accepted such a record.

- **Every shell-side SHA check goes through the same rule too.** Three helpers
  validated a head with a `case` plus a length test — the same rule spelled a
  different way — and the first version of the drift guard reported clean because
  it recognised only the jq regex. A guard that matches one spelling of a
  duplicated rule has not found the duplication. `sha_reason` keeps the two
  diagnostics (`bad_head` versus `head_not_full_sha`) that those sites reported
  apart, so sharing the rule costs nothing an operator was reading.

- **The same rule now covers `pr-watch.sh`.** It validates helper output rather
  than API records, but a head that is not a real SHA is the input to every
  subsequent probe; it carried two more hand-written copies of the shape check.

- **The suite refuses re-implementation, rather than asking for restraint.**
  `test-recordlib.sh` fails if any helper writes one of these rules inline, and
  `pr-selfcheck.sh` now requires a test for the sourced libraries as well as for
  `pr-*.sh` — a shared definition is the highest-leverage file in the tree, so it
  cannot be the untested one.

## [2.0.0] — 2026-08-05

**The local review bus is gone.** Both reviewers are first-party GitHub apps, so
the plugin no longer runs a reviewer of its own.

- **Why this is a rewrite, not a refactor.** v1 opened by asserting that a Codex
  review "would never match" a bot filter, because it arrived over a shared token
  and was authored as the repository owner — and the entire file-based bus, the
  two `systemd --user` daemons, the `/tmp` bus directory, the request/response
  files and their digest markers existed to work around that. It is false: an
  `@codex` mention is answered by `chatgpt-codex-connector[bot]`, a real Bot
  account, in about seven seconds. Copilot has always been
  `copilot-pull-request-reviewer[bot]`. With both reviewers reachable through
  GitHub, the machinery had nothing left to do.

- **Removed**: `review-bus-codex-watcher.sh`, `review-bus-response-monitor.sh`,
  `review-bus-codex-start.sh`, `review-bus-request.sh`,
  `review-bus-close-round.sh`, `review-bus-rounds.sh`, `review-bus-copilot.sh`,
  the SessionStart hook, `.review-bus.md`, and eighteen suites that tested them.
  Also gone with them: a second credit pool (the `codex exec` CLI, which ran out
  mid-session), reviews authored as the repository owner instead of a bot, and a
  daemon that could crash-loop under systemd.

- **Kept, because they answer questions `gh` cannot answer safely.**
  `pr-review-state.sh` decides whether a named reviewer's review of the *current*
  head can carry a merge; `pr-merge-range.sh` decides whether every commit since
  the reviewed SHA is a review-fix commit reachable from it. Both are now
  reviewer-agnostic — the bot login is an argument — which is what native review
  makes possible.

- **The review-state logic is salvaged, not rewritten.** It carries every fix
  found while it lived in the v1 Copilot helper: a state machine that judges the
  latest submitted review rather than counting inline comments, so a dismissal,
  a changes-requested review with no comments, and an in-flight re-review are
  never mistaken for a signoff; a clean verdict re-checked against a second
  snapshot, so a review that changes mid-decision cannot be judged on one and
  counted on another; and every unreadable fetch failing closed instead of
  reading as "no findings".

- **The review policy moved to where the reviewers actually read it.**
  `AGENTS.md` for Codex, `.github/copilot-instructions.md` for Copilot, both from
  the base ref. They carry what v1's prompt injection carried — judge the PR
  against what it set out to do, treat the PR narrative as intent and never as
  permission, only a base-ref authority waives a finding, a resolved thread is
  not proof of a fix — plus one thing v1 had no channel for: **an out-of-scope
  problem should go in the review body or a GitHub issue, never an inline
  comment**, because every inline comment becomes a thread the merge gate
  requires resolved.

- **Helper output is matched as a whole record, not by substring.** The state and
  verdict lines were parsed by taking the last `state=` token, or by globbing for
  `*verdict=clean*` — so rc-0 noise such as `warning: cached state=reviewed`, or a
  line reading `verdict=cleaned`, was accepted. Under Monitor `PR_REVIEW_READY`
  is the actionable signal, and in the merge gate the equivalent decides a
  fallback, so both now require the exact `PR_REVIEW_STATE … state=<known>` /
  `… verdict=<known>` shape. The merge gate also validates both reviewers'
  verdict records rather than trusting the exit codes alone.

- **A record's shape is not its identity.** Matching the whole record still left
  `pr`, `sha` and `reviewer` as wildcards, so a well-formed line about *something
  else* was accepted as an answer: a misrouted or cached
  `PR_REVIEW_STATE pr=999 … state=reviewed` drove the watch into its terminal
  path, and in the merge gate one clean record satisfied the check for either
  reviewer — so a clean Copilot line, or a clean line for a stale SHA, could pass
  as Codex's signoff and the gate would merge without the named reviewer ever
  having approved the commit being merged. Every record is now compared to the PR,
  reviewer and head it is supposed to describe, and `pr-watch.sh` additionally
  requires the verdict to name the same SHA as the state it was paired with, so a
  push landing between the two calls fails closed instead of pairing a fresh state
  with a stale verdict.

- **The round boundary is checked before the *push*, in automatic mode.** Placing
  it before the mention was not enough: with automatic review on, the push itself
  is the request, so a fix commit on the threshold-th round started the next pass
  while the count had not yet run. Third placement of this check, and the first
  that precedes every way a review can be triggered — the contract test now
  treats the push as a triggering command rather than only the mention and
  `--add-reviewer`.

- **An in-flight auto-review is not permission to merge.** With auto-review on,
  every Copilot-fix push also queues a Codex pass, and Codex exposes no review
  record while that pass is queued — which the merge gate read as the same `none`
  that means "nothing asked Codex about this head". It then fell back to the
  pre-Copilot signoff and could merge before the queued pass reported anything,
  including a body-only `CHANGES_REQUESTED` that leaves no unresolved thread for
  the other gates to catch. "Not yet answered" is not "nothing to answer".

- **An unrecognised review state is unreadable, not a dismissal.**
  `head_review_snapshot` sent anything it did not recognise through its catch-all
  as `dismissed` with status 0, so a null or unknown value became an actionable
  "the review was withdrawn" — which the driver answers by requesting another
  pass, turning a malformed parse into a review loop. This is the set the other
  two helpers already enforced; `pr-review-state.sh` had drifted away from it.

- **A helper that exits 124 is an unreadable probe, not a timeout.** 124 is the
  watchdog's own expiry code, returned before any child status is read, so a
  helper exiting 124 itself was reported as an ordinary timeout — which the
  driver re-arms indefinitely. A broken probe became "still in flight", forever.

- **A clock that steps backward is refused — including a step that stays above
  the start.** The first attempt kept the last accepted epoch in `elapsed_s`, but
  every caller evaluated it through command substitution, so the function ran in a
  subshell and the update was discarded: the comparison always fell back to the
  start time, and a clock going 100 → 110 → 105 was still accepted. `elapsed_s`
  and `remaining_s` return through variables now, so the state survives the call.

- **The identity guard checks a mixed line.** `$OWNER/$REPO` on a line caused the
  whole line to be skipped, so `REPO_SLUG="acme/widget"; echo "$OWNER/$REPO"`
  scanned clean — the guard asserting the repo-agnostic invariant while a runtime
  script routed review traffic to a fixed repository.

- **The epoch bound accepts what it claims to.** `N` question marks followed by
  `*` matches every string of length N *or more*, so the eleven-`?` guard rejected
  eleven-digit epochs — the ones it was written to allow — and every watch would
  have exited `clock_unreadable` from 2286 onward. A ceiling that behaved as a
  floor one digit lower, and the rejection fixtures passed either way.

- **Every scratch directory in the suite is validated before anything is written
  into it.** All thirteen sites used a bare `mktemp -d`. Unchecked, a failure
  leaves `$TMP` empty, so `$TMP/bin` is `/bin` and `$TMP/broke` is `/broke` — and
  the EXIT trap then runs `rm -rf` over exactly that, which in a root-run
  container is `rm -rf /bin`. `mktemp` can also print a plausible path and then
  fail. `mktemp_d` requires a non-empty absolute path that is not `/` and that
  exists, the last being what proves the directory was actually created.

- **A watchdog that cannot set itself up returns 125, not 2.** Two is a status the
  bounded command legitimately returns and that several fixtures assert as their
  primary expectation, so a broken watchdog satisfied them without ever running
  the subject.

- **An epoch outside Bash arithmetic is an unreadable clock.** All digits passed
  the shape test and `t - started` then wrapped: a constant oversized value keeps
  elapsed time at zero forever, so the watch never reaches its deadline, while one
  appearing later produces an immediate ordinary timeout the driver re-arms.

- **The portable watchdog reaps descendants, not just the process it started.**
  `run_limited` killed only the leader, so a bounded command with children — the
  `sh -c "sleep 30 & wait"` shape its own suite runs — returned 124 with its
  `sleep` orphaned. A mandatory gate that leaks one process per run leaks one per
  run forever. The command now goes in its own process group and the group is
  killed, with the leader as a fallback where the group never formed.

- **The suite is passable where GNU `timeout` is absent — the platform it claims
  to support.** Fixtures prefixed their stubs onto the CALLER's `PATH`, so the
  portable watchdog inherited them: it polls with its own `sleep`, reads with its
  own `cat` and reads the clock with its own `date`, and a stubbed one killed the
  harness instead of the subject. Seven fixtures across four files were affected —
  the whole suite was unpassable on stock macOS while passing wherever `timeout`
  exists, which is why it went unnoticed. The substitution now goes inside the
  watchdog (`run_limited N env PATH=… cmd`), and a guard in `test-testlib.sh`
  refuses the old shape.

- **The suite no longer signals or matches on processes it did not start.** A
  fixture asserting that a probe was reaped used `pgrep -f`/`pkill -f` over the
  argv, which matches any `sleep 30` on the machine — and the suite is a mandatory
  pre-push gate, so it could report a false leak from an unrelated command and
  then kill it. The child publishes its own PID and only that PID is inspected.

- **The none-configured checks diagnostic is matched whole, not searched for.**
  `gh pr checks` has no dedicated status for "no required checks" — it documents
  exit 8 for pending and nothing for this — so the message is the only signal, and
  a substring test accepted the benign phrase inside a LARGER failure. A run that
  printed it and then failed for an unrelated reason was classified as benign, and
  the default administrator merge proceeded with no trusted checks result at all.

- **A failed polling clock tears the probe down before returning.** The
  fractional-sleep capability check has already succeeded on that path, so it is
  reached with a live child: returning 125 alone left a `gh` process holding an
  API call open after the watch exited, and every re-arm of a persistent watch
  added another.

- **The pause instruction reports each reviewer's own count.** Scoping the footer
  to a reviewer was not enough while the message printed the COMBINED count beside
  every login: with 41 Codex heads and 5 Copilot heads, an operator following the
  emitted instruction literally wrote a Copilot acknowledgement of 41, which the
  Copilot phase then refuses as ahead of its count — the same cross-phase block,
  recreated one layer out through the instruction rather than the parser. A count
  that cannot be established is not printed as a number to copy.

- **A pause acknowledgement belongs to one reviewer's count.** The Codex and
  Copilot phases are separate loops with separate counts — which is why the helper
  takes a reviewer list at all — and the acknowledgement footer did not name one.
  Acknowledging 41 Codex rounds was then read by a Copilot invocation with 5, trip
  the ahead-of-count guard, and return status 2 permanently: the Copilot phase and
  the merge gate behind it were blocked for good. This was not hypothetical. It
  landed on this repository's own PR #10 within the hour, from the acknowledgement
  that had just cleared the Codex pause. The footer now names the reviewer, the
  login is compared rather than interpolated into a regex (`[bot]` is a character
  class), and there is no unscoped form.

- **The driver takes the gate's status before recording permission.** Reading the
  count out of a pipeline hid it: a run that printed a plausible pause line and
  then died some other way still yielded digits, `sed` still succeeded, and the
  operator's permission was recorded from a probe that failed.

- **The round check-in is a threshold crossed, not a multiple landed on.** The
  pause fired only when `rounds % threshold == 0`, which assumes the counter rises
  by exactly one per call. It does not: a single round can contribute several
  countable heads, and this repository's own PR #10 went from 35 to 41 across two
  rounds — the check-in at 40 was stepped over and never fired at all. A safety
  pause a large enough step silently skips is not a safety pause.

  The test is now `rounds >= acknowledged + threshold`, which no jump can walk
  past, and the pause therefore STICKS until it is answered rather than clearing
  itself on the next round. Saying "continue" is recorded on the PR — a
  `**Review-Pause-Acknowledged:** \`<reviewer>\` \`<count>\`` footer, read back the
  same way the
  round count itself is derived, since local state was removed in v1 for
  disappearing between machines. Only OWNER, MEMBER and COLLABORATOR comments are
  read as acknowledgements, and one naming a round that has not happened yet is
  refused rather than obeyed: it is the disable-forever shape, reachable by a typo
  as easily as by anyone who can comment on the PR.

- **A remote whose transport reaches no GitHub server is refused too.**
  `file://github.com/srv/acme/widget.git` carries an authority, so the URL arm
  accepted `github.com` as the host while the path split still yielded
  `acme/widget` — the same wrong-public-repository outcome as a bare local path,
  reached through the arm meant to be the safe one. Only `ssh`, `git`, `https`,
  `http` and `git+ssh` are accepted.

- **Each duplicated identity parser is now proven independently.** The hostless
  rule landed in all four copies but only `test-pr-review-state.sh` exercised it,
  so reverting the branch in `pr-findings.sh` or `pr-round-count.sh` left the
  suite green and silently restored the wrong-repository path. The new matrix
  runs every origin shape through each script and asserts, via a `gh` spy, that
  no request was ever addressed — the rejection message quotes the remote, so
  grepping the output for the derived slug matched the diagnostic itself.

- **An out-of-range `--timeout` falls back instead of wrapping.** 2^64 is all
  digits and wraps to exactly zero, so `remaining_s` reported an immediate
  ordinary timeout on the first poll — and the driver re-arms an ordinary
  timeout, turning an unreadable configuration into an endless loop that never
  waited for a review. Same bound as the round threshold, which had it already.

- **The required-checks payload is shape-checked before `all`.** `all(.[]; …)`
  over an empty stream is `true`, so a successful read returning an object, a
  null or an empty array came out as "every required check passed" and the
  administrator merge proceeded on a payload nothing had read.

- **The phase-summary heredoc is quoted.** Unquoted, the shell expanded the prose
  while writing it — and that body is composed from the round, routinely holding
  Markdown code spans of shell text, including text copied out of an untrusted PR
  description. The reviewed SHA is emitted separately through `printf`.

- **The portable watchdog fails closed on its own clock and its own reader.**
  When `sleep` failed the loop still advanced, burned the limit in a spin and
  returned an ordinary 124 — so a fixture asserting "this hangs, therefore it
  times out" passed with no wall-clock limit in force. And `cat` could emit a
  partial buffer and fail with its status overwritten by `rm`, returning the
  command's own 0. Both now return a distinguished 125.

- **An origin with no network authority is refused, not defaulted to GitHub.**
  A local-path remote such as `/srv/mirrors/acme/widget.git` has no host, and
  defaulting it to `github.com` while the path split still yielded `acme/widget`
  pointed every `gh` call at the unrelated **public** repository of that name —
  reading, commenting on and merging the same-numbered PR there. Applied in all
  four identity parsers.

- **Equal cross-channel timestamps are unreadable, not a silent winner.** GitHub
  stamps to the second, so a clean re-review comment created in the same second
  as the review it supersedes ties — and a strict `>` left the older review
  authoritative, so the watch rejected a completed clean pass as stale and timed
  out. Nothing available can order them, so it fails closed.

- **A threshold beyond Bash arithmetic falls back rather than wrapping.** An
  all-digit value larger than the integer range wraps under `-eq` and modulo,
  possibly to zero — silently taking the disable path that only a literal `0` is
  meant to take.

- **The helper selection takes its pipeline status.** `head` can emit a plausible
  cache path and then fail; if that directory holds executables, the validation
  after it passes and every gate runs helpers chosen by a failed read.

- **The push confirmation compares against the SHA it pushed.** It re-read
  `git rev-parse HEAD`, which is mutable: a checkout reset after the push would
  satisfy the comparison with a commit that never reached the PR. It now compares
  the remote head against `$HEAD_BEFORE`, captured and validated before the push.

- **The push must have landed on this PR.** A successful `git push` from the
  wrong worktree, or with a refspec pointing elsewhere, leaves the PR head
  untouched — and because the local head then differs from it, the no-op branch
  is skipped and nothing is requested at all. The round now confirms the PR head
  matches the commit it pushed, with a short retry for API lag.

- **The round boundary is checked before the request, not after it.** Both
  round-closing recipes counted rounds in step 6 — *after* step 5 had already
  posted the `@codex` mention or invoked `--add-reviewer`. The pause therefore
  fired once round N+1 was queued and very likely running, which is a
  notification that continuing has begun rather than a decision about whether to.

- **A Copilot round re-requests Copilot.** The round-closing recipe always posted
  the `@codex` mention, but Copilot is triggered only by `--add-reviewer` — never
  by a push, never by a mention. A Copilot fix round therefore requested nothing
  at all, and the watch waited past the old Copilot review indefinitely. Both
  round-closing paths now branch on `$WHO`.

- **The head baseline is validated and refreshed per round.** An rc-0 lookup
  yielding empty or `null` made every unchanged-head comparison false, and a
  baseline captured once in step 2 went stale the moment a fix round moved the
  head — so the round after a real push queued nothing.

- **A malformed review id is not an id.** An rc-0 helper returning empty,
  multiline or junk output was compared as a real one: differing from the
  baseline, it let the watch announce the *old* terminal verdict as this round.
  A newline could also smuggle a `PR_REVIEW_READY` line into the diagnostic,
  which is the channel Monitor reads.

- **An unchanged head in automatic mode still gets a trigger.** A round that ends
  without a new commit — a dismissal, or a finding answered rather than coded
  around, both explicitly supported — leaves the push a no-op, so nothing is
  queued while `--after-review` keeps rejecting the old terminal record and every
  timeout re-arms. The round records the head it started from and asks explicitly
  when the push moved nothing.

- **A clock that fails at the timeout read is not a timeout.** `timed_out` fell
  back to `$TIMEOUT`, turning a broken clock into a plausible ordinary timeout —
  and the driver *re-arms* on status 1, so the round would loop forever instead
  of stopping as unreadable.

- **The clean-pass hash comes from the footer LINE, and the last one.**
  `capture` takes the first match anywhere in the body, so an older clean comment
  carrying a field-shaped `**Reviewed commit:**` line in its prose ahead of its
  real footer would have signed off for whatever that decoy named. The match is
  anchored to a line start with the bold markers, and the last occurrence wins
  because the genuine footer is final. Same rule in `pr-round-count.sh`.

- **The clean-pass hash comes from the footer, exactly.** Two independent
  `contains` checks accepted a clean comment for an *older* head that merely
  mentioned the current prefix in its prose — the footer named a different commit
  and the current, unreviewed head read as clean. The hash is extracted from the
  `Reviewed commit:` field and compared exactly, and `pr-round-count.sh` requires
  the documented ten characters: a shorter one cannot be deduplicated against the
  prefix of a full review SHA, so a clean re-review of an already-counted head
  would have added a phantom round and pushed the count past the pause.

- **A clean comment must carry a canonical timestamp.** It is ordered against
  review timestamps, so `zzzz` would sort above every real one and override a
  newer `CHANGES_REQUESTED`, and a null would read as clean whenever no review
  existed. Unreadable ordering is not an ordering, so it fails closed.

- **A clean pass counts as a round.** It leaves no review behind, so counting
  `pulls/N/reviews` alone reported nine heads for nine-plus-a-clean-tenth — and
  the phase-transition checks that consult that number then skipped the operator
  pause at exactly the boundary. Clean-pass comments are counted alongside review
  records, deduplicated on the head they name.

- **Both verdict channels are placed in time against each other.** Consulting
  comments only when there was no review at all was too narrow: a clean
  *re-review* on an unchanged head also arrives as a comment, so an older
  finding-bearing or blocked review stayed authoritative forever and the watch
  timed out repeatedly despite a newer clean pass. Whichever is newer wins — and
  an in-flight draft still outranks both, because the pass is not finished.

- **`sha1sum` is not on stock macOS.** The round-count fixtures used it, so on the
  platform `README.md` calls supported they produced empty commit IDs and the
  suite failed — through `pr-selfcheck.sh`, which runs every test as a mandatory
  pre-push gate. Same trap as `timeout`, one round later. It now falls back
  through `shasum` and `openssl` to a pure-shell expansion needing none of them.

- **The automatic-review path has no pre-request baseline.** `--after-review`
  means "newer than this one", which is right for a re-request and actively wrong
  for the initial automatic pass: the push that triggered it preceded the skill,
  so the lookup could capture the very review being waited for — and the watch
  would reject the only terminal review as stale and re-arm forever.

- **Every documented watch invocation carries the baseline.** The shell example
  passed `--after-review` while the Monitor command beside it did not, leaving the
  feature inert in the mode Claude Code is actually told to use — the second time
  that flag shipped without being used.

- **The round boundary gates the phase transitions, not just the re-request.** A
  phase ending on the threshold-th reviewed head went from a clean verdict
  straight into the Copilot phase, or into the merge, skipping the operator pause
  in exactly the case it exists for.

- **A clean pass arrives as a comment, not a review.** Codex submits a review only
  when it has findings; a clean pass is an issue comment carrying
  `**Reviewed commit:** <sha10>` and no review at all. `pulls/N/reviews` is
  therefore empty on a clean head, so `pr-review-state.sh` reported `state=none`
  and the Codex phase could never complete — the merge gate could not see a clean
  verdict at all. `clean_comment_for_head` reads that channel, bound to the head
  the comment names and to a clean-pass phrasing, both required: a false negative
  keeps the loop waiting, a false positive would invent a signoff. A submitted
  review always wins, so a later blocking review cannot be masked by an earlier
  clean comment.

  **This was not found by review.** PR #10 took thirty rounds and all thirty-one
  Codex reviews carried findings, so the success path was never exercised. It
  surfaced when PR #12 came back clean and the watch polled until it timed out.

- **"No required checks" is not "could not tell".** `gh pr checks --required`
  exits non-zero when the branch has none configured, saying so on stderr. The
  gate treated every non-zero status as an unreadable probe and blocked — so on
  any repository without branch protection the merge gate could never open. That
  is not a fail-closed guard; it is a gate with no passing path. Found the same
  way: by trying to merge.

- **The host is parsed from the URL authority.** Matching `github.com` anywhere
  in the origin sent an enterprise remote whose *path* contains it — such as
  `git@ghe.example:org/github.com-mirror.git` — to the public host, taking every
  newly pinned command with it.

- **`--after-review` is actually used.** The flag shipped inert: the driver never
  called `review-id` and never passed the option, so a same-head re-request still
  accepted the previous terminal review immediately. The id is captured before
  each request and passed to the watch that follows it.

- **Every terminal state carries a review id.** The snapshot returned one only for
  `reviewed`, while `blocked` and `dismissed` are precisely the same-head
  re-request cases — an empty id there silently disabled the comparison.

- **Every `gh` call names the host, not just the repository.** `GH_HOST` supplies
  the hostname when a command gives none, so the helpers could read the
  same-numbered PR from a *different GitHub host* while the local origin
  identified another project — the `GH_REPO` hole, one level up. The host is
  derived from origin and passed explicitly everywhere.

- **A same-head re-request waits for a new review.** After a dismissal, or after
  answering a finding, the head does not change — so the first poll saw the
  *previous* terminal review and reported it as this round's answer.
  `pr-watch.sh --after-review <id>` treats the pre-request review as "not yet".

- **The recorded Codex signoff is re-validated on the sha it records.** A push
  between the clean verdict and the lookup recorded the new, unreviewed head, and
  the gate only discovered the missing verdict after the entire Copilot phase.

- **The probe buffer is created with `mktemp`.** A constructed
  `/tmp/pr-watch.<pid>.<15-bit>` name is predictable and the redirection truncates
  it, so on a shared host another user could aim it at any file the operator can
  write.

- **The probe's buffered read, its watchdog sleeps, and the occurrence count all
  take their status**, and an exhausted deadline no longer becomes one more
  second — a probe could otherwise start after `--timeout` had passed and still
  produce `PR_REVIEW_READY`.

- **The accepted merge-mode limitation has a decision record.**
  `docs/decisions/2026-08-06-merge-admin-default.md` states the `--admin` race
  plainly, why it is accepted, and what bounds it. Per `AGENTS.md` only a base-ref
  authority can accept a limitation, and a comment in the diff is not one.

- **Each probe is bounded by the remaining deadline.** Making the deadline
  wall-clock was not enough: the elapsed checks ran only *between* probes, so a
  `gh` that hung inside one blocked forever and the deadline was never reached at
  all. A probe that exhausts what is left reports the timeout, since that is what
  elapsing means — not an unreadable state, which the contract answers differently.

- **The clock read is checked like every other probe.** `date` can print a
  plausible epoch and then fail, and the elapsed calculation hid that behind its
  own success — leaving elapsed time ordinary-looking, or zero forever, so the
  watch would never time out.

- **The `--repo` check judges each occurrence, not each line or segment.** A
  `;`-only splitter was walked straight through by `&&`. Splitting is the wrong
  tool — deciding which text is a command needs a quote-aware parser — so every
  `gh pr <verb> <arg> <next>` on the line is extracted and `<next>` must be
  `--repo`. An assignment can no longer vouch for a call beside it, whatever
  joins them.

- **The watchdog keeps its output off the caller's pipe.** A killed command's
  children still held the inherited stdout, so the capture blocked regardless.
  Output now goes to a temp file. **A stated limitation remains**: a command that
  backgrounds a child and then exits leaves an orphan that holds the caller's
  capture until it finishes. Redirecting the job, `exec`-detaching its
  descriptors and `setsid` were each tried and none close that pipe. It is
  recorded in `testlib.sh` rather than papered over, and no fixture asserts
  behaviour the helper does not have.

- **The watch deadline is wall-clock.** `--timeout` accumulated only the sleeps,
  so every second spent inside the head, state and verdict probes escaped it — a
  run of slow GitHub reads made a one-hour watch run far past an hour, and a
  hung probe meant the check was never reached at all.

- **The portable watchdog kills the process group.** Killing the top-level PID
  left a child holding the inherited stdout, and callers capture with command
  substitution — so the shell blocked on a pipe the dead parent no longer owned,
  hanging the mandatory gate past the limit the watchdog advertises.

- **The `--repo` check validates each command, not each line.**
  `BODY='…--repo…'; gh pr comment N --body "$BODY"` carried the pinned text in an
  assignment, and a whole-line check found it and passed the real call — which
  has no selector at all.

- **An in-flight re-review supersedes an old blocking body.** A `PENDING` review
  opened on the head after the watch saw `blocked` has a null `submitted_at`, so
  the sort ignored it and `blocked-body` returned the *older* request — sending
  the driver to act on findings the in-flight pass may supersede.
  `pr-review-state.sh` lets a draft dominate; these two no longer disagree.

- **The summary file's creation is checked.** `mktemp` can print a plausible path
  and then fail, and every later write and guarded read would point at an
  existing file — a stale summary posted as the current round record.

- **The suite no longer needs GNU `timeout`.** Several fixtures assert that a
  guard turns an endless walk into a status, so they need a wall-clock limit —
  and they used `timeout`, which stock macOS does not ship. Since
  `pr-selfcheck.sh` runs the whole suite as a *mandatory* pre-push gate, that put
  an undocumented Coreutils dependency between a macOS contributor and their
  first push, on a platform `README.md` calls supported. `testlib.sh` provides a
  watchdog that uses `timeout` where it exists and a background killer where it
  does not, reporting 124 either way so assertions read identically.

- **`owner` and `repo` are sent as raw GraphQL strings.** `gh api -F` applies
  magic conversions, so a repository literally named `true`, `false`, `null` or
  `123` arrived as a Boolean, null or integer against a `String!` parameter and
  the fetch failed — the loop simply could not run there. `cursor` deliberately
  keeps `-F`: the first page needs a real JSON null.

- **`--repo` must be an argument, not text.** The pin check tested for the
  substring, so `gh pr comment N --body "remember --repo"` passed while `gh`
  received no repository selector at all — through the one gate meant to catch
  exactly that. It now requires `--repo` in the canonical position after the PR
  argument, which needs no shell-word parsing.

- **Every git probe takes its status — swept, not patched.** This class appeared
  three times: the origin lookups, then `pr-selfcheck.sh`'s root lookup, then the
  identity block's `REPO_DIR` and `pr-merge-range.sh`'s `|| true`. The last is the
  worst of them: `|| true` discards the status deliberately, so a `git rev-parse`
  that printed a plausible directory and then failed was indistinguishable from
  one that worked — and every history check then decided a merge about a tree
  nothing vouched for.

- **The phase-summary write is checked, not only the read.** A `cat` that
  truncates and then fails leaves a non-empty partial body the guarded read
  happily returns; a `cat` that cannot open the file leaves the *previous*
  round's contents to be read as this one's. Either posts an invalid summary and
  requests Copilot against it.

- **The `--repo` check understands line continuations.** A correctly pinned call
  split across a backslash continuation was reported as unpinned — and since the
  self-check gates the push, that false positive would have blocked the round
  rather than merely annoying. Lines are joined before matching.

- **The shipping manifest lists every runtime helper.** `CLAUDE.md` classifies
  everything unlisted as documentation, so a table naming two of six executable
  helpers told maintainers that four scripts were prose. `README.md`'s "two small
  scripts" is corrected with it, and the inventory is derived from the directory
  by the contract test so it cannot drift again.

- **Every `gh pr` call names the repository.** `GH_REPO` overrides the repository
  `gh` infers from the checkout. Every helper and every `gh pr view/edit/checks/
  merge` in the contract passed `--repo`; the five `gh pr comment` calls did not —
  so with `GH_REPO` set, review requests and round summaries went to the
  same-numbered PR in a *different* repository while every gate inspected this
  one. `pr-selfcheck.sh` now enforces this mechanically, which is what stops the
  class rather than the instance.

- **A failed push does not close the round.** If `git push` failed — auth, a
  non-fast-forward, a dropped connection — the recipe still resolved threads and
  requested the next review, sending the reviewer at code that was never pushed.
  In automatic-review mode the watch would then read the already-reviewed remote
  head's verdict as this round's.

- **A watch timeout re-arms.** The status table still offered "re-request, or ask
  the operator", contradicting the re-arm-without-asking rule added alongside it:
  re-requesting queues a duplicate pass on the same head, and asking turns the
  automatic loop back into the manual one it replaces.

- **The cached-helper discovery is checked and its result validated.** `ls` can
  print one candidate and then fail on an unreadable cache entry, and `head` masks
  that status — so an unchecked pipeline could select a partial or stale path and
  every later call would run a different version of the helpers than the one
  installed.

- **The no-match exception lives at the grep, not on the pipeline.** Tolerating
  status 1 for a whole pipeline could not tell whose 1 it was: under `pipefail`
  the status is the rightmost non-zero, so a `sed` or `sort` that emitted partial
  output and exited 1 read exactly like a grep matching nothing. Each grep now
  normalises its own no-match status, and every extraction is checked strictly.

- **`pr-selfcheck.sh`'s own root lookup takes its status.** `git rev-parse
  --show-toplevel` can print a plausible directory and then fail, and the check
  would then scan a tree the probe never vouched for — reporting `status=clean`
  off a failed read.

- **The origin lookup takes its status.** `git remote get-url origin` can print a
  plausible URL and then exit non-zero, and command substitution keeps what it
  wrote — so `SKILL.md` and the three helpers that derive identity could build
  `$OWNER/$REPO` from an untrusted read. Every `gh` call is addressed by that
  identity, so the failure sends one project's review traffic somewhere else
  entirely. This predates the whole hardening stretch.

- **The round summary is read before it is posted.** `$(cat "$SUMMARY_FILE")`
  inside the argument swallowed the reader's status, so a partial read still
  produced a successful post — and the reviewer contract makes the newest summary
  the thing read before the diff, which makes a truncated one worse than none: it
  looks complete. All three posting paths read it into a variable first.

- **Status 1 means "no matches" only where a grep produced it.** One tolerant
  checker for every extraction was too broad — `awk`, `sed` and `sort` also exit 1
  on real errors, and the block extraction contains no grep at all, so an `awk`
  that printed a plausible block and then failed was waved through. And the
  helper-discovery pipeline was still unchecked entirely: a failure there left an
  empty list, the loop ran zero iterations, and every helper was reported present.

- **`pr-selfcheck.sh` is listed under its actual strict mode.** `CLAUDE.md`'s
  table is authoritative and told authors that anything not in the `-uo` row uses
  `-euo`; a future change following that rule would have enabled `-e` and aborted
  the check on a `grep` that matched nothing. The Copilot restatement is synced.

- **The README carries both review orderings.** It still told users to push and
  then resolve and summarise — the ordering `SKILL.md` had just fixed — so anyone
  following the README with automatic review on started the next pass against
  open threads and the previous summary.

- **The merge gate's `endCursor` parse is guarded.** `jq` can print a plausible
  cursor and then exit non-zero, and command substitution keeps what it printed —
  so the walk continued from an untrusted parse while `OK` stayed 1, and could
  still finish at `UNRESOLVED=0`. The count and `hasNextPage` parses beside it
  were already guarded; this one was not. Same fix in `pr-findings.sh`.

- **`not_applicable` has its own exit status.** Printing a distinguished record
  alongside exit 0 was not distinguished at all: the caller branches on the
  status, and `SKILL.md` defines 0 as "the mechanical checks pass" — so a run that
  checked nothing was identical in control flow to one that checked everything and
  found it clean. It exits 3, and the contract documents the third outcome.

- **The self-check's extractions take their status.** `set -uo pipefail` does not
  stop an unchecked assignment, so a failed pipeline left the variable empty and
  the consuming loop found nothing to report — `status=clean` from a run that
  never established what was used. That is the exact failure the script exists to
  prevent, inside the script. Statuses are captured and validated, with 0 and 1
  both answers because `grep` exits 1 on no match.

- **Loop-variable inference is narrowed to line starts, and comments are dropped
  first.** Two rounds running, a widening meant to catch a legitimate `for`
  position reopened the same false negative: `# wait for SUMMARY_FILE`, then
  `# then for SUMMARY_FILE in prose`. Anchoring the alternatives properly needs a
  Bash lexer, which this repository has already built and deleted. So it now sees
  only `for NAME in` at the start of a line — a `for` after `;` or `do` yields a
  false *positive*, which is loud and fixable, instead of a checker a comment can
  switch off.

- **The push left the numbered checklist.** Step 3 said to check the boundary
  "and only then push", ahead of the steps that resolve threads and post the
  summary — so following the list with auto-review on started the next pass
  against open threads and the previous round's account. The push belongs to the
  mode-specific recipe, which already ordered it correctly.

- **The self-check does not block every other repository.** It resolved its root
  from `git rev-parse`, so in a consumer checkout — which is most of them, since
  one installed copy drives every project — it looked for plugin sources that were
  not there and exited 2, turning a mandatory pre-push gate into a block on every
  review round outside this repository. It now reports a distinguished
  `status=not_applicable` and exits 0: the domain of these checks is empty there,
  which is a different fact from both "failed" and "passed", and the caller is
  told which. It is deliberately *not* resolved relative to the script instead —
  that would check the installed plugin, which is not what anyone is about to
  push, and report a confident PASS about a tree nobody touched.

- **A comment can no longer switch the self-check off.** `for NAME` was matched
  anywhere in a block, so prose such as `# wait for SUMMARY_FILE` registered the
  name as a loop variable and silenced the undefined-variable finding —
  recreating the exact false-negative class the checker was introduced to
  prevent. Loop variables are now recognised only at real command positions.

- **The checklist ran the self-check after the push it exists to prevent.** Step 2
  said to check the boundary "then push" while the self-check was step 3, so a
  driver following the numbered sequence pushed first. The contract test did not
  catch it because it compared the position of two lines in the file rather than
  the order of the steps; it now compares the step numbers.

- **The first review request respects the review mode too.** With automatic review
  on, opening or pushing the PR has already queued a pass, so the unconditional
  `@codex review` in the request step queued a second review of the same head —
  the same duplicate the round-closing step avoids. `AUTO_REVIEW` is established
  once, in the request step, and both branches use it.

- **A self-check runs before the push.** `pr-selfcheck.sh` verifies that every
  variable `SKILL.md` uses is assigned in it, every script parses, every helper it
  drives is shipped, every script has a test, and the suite passes. Each of those
  is a mistake that actually shipped from here — the first one shipped as a P1.
  `SKILL.md § 5a` pairs it with the judgement checks a script cannot make: fix the
  class not the instance, recheck consumers when a validator widens, trace every
  identifier and ordering end to end, and prove each new assertion can fail.
  This exists because this PR took nineteen review rounds and almost none of the
  findings were subtle; rounds are the expensive part of the loop.

- **`$SUMMARY_FILE` is assigned.** It was written into two places in `SKILL.md`
  and defined in none, so on a fresh session the summary post produced an empty
  body and the guarded comment aborted, while a long-lived session could post a
  file left from another round or another PR. The Copilot phase now builds its own
  transition summary rather than inheriting one from the fix-round step, which
  never runs when Codex approves on the first pass.

- **The round order depends on what triggers the review.** With Codex automatic
  review on, the *push* starts the pass, so a summary posted after it arrives too
  late and a following `@codex review` queues a second review of the same head.
  `SKILL.md` now documents both orderings, and `README.md` recommends automatic
  review **off** — the mention is then the only trigger, which is what the rest of
  the loop assumes.

- **The verdict must describe the state the watch acted on.** State and verdict
  are separate fetches, and a review can move between them without the head
  moving: a re-review opens, or a `CHANGES_REQUESTED` is superseded. The verdict
  then legitimately reports the new state while the watch still holds the old one,
  and `PR_REVIEW_READY` announced a pass that was not finished. A disagreement now
  re-polls. The previous fixture asserted this backwards — `state=reviewed` with
  `reason=pending` was accepted as READY.

- **Findings get the reaction the reviewer asks for.** Every Codex finding ends
  with *"Useful? React with 👍 / 👎"*, and it is the only signal it gets about
  whether a review was worth making. `pr-findings.sh list` now prints
  `comment=<id>` beside `thread=<id>` — the thread id resolves over GraphQL, the
  comment id reacts over REST. 👎 is for a finding that was wrong on the facts,
  not one that was right and declined: marking a correct finding unhelpful teaches
  the reviewer to stop reporting that class.

- **Timestamps must be canonical UTC, because the sort is lexical.** The
  validator accepted numeric offsets and fractional seconds — both valid ISO
  8601 — while `sort_by(.submitted_at)` orders them as strings, and neither form
  sorts chronologically: `03:00:00+02:00` is 01:00 UTC yet sorts *after*
  `02:30:00Z`, and `03:00:00.5Z` sorts *before* `03:00:00Z`. So an older
  `APPROVED` could outrank a newer `CHANGES_REQUESTED` and report clean, and
  `blocked-body` would suppress the newer request's text entirely — empty output
  with rc 0, which reads as "this blocking review has no body". This was the
  anchored-timestamp hole from earlier in this release, reopened in a subtler
  form by the fix that widened the format. All three scripts now require
  `…THH:MM:SSZ`, which is what GitHub returns and what makes lexical order
  chronological.

- **A pagination cursor cycle of any length is caught.** Comparing each cursor
  against the previous one stopped an immediate self-loop but not
  `null → A → B → A → B …`, which alternates forever. Both `pr-findings.sh` and
  the merge gate now record every cursor they have requested.

- **The Copilot round summary is posted before the request.** In the Codex phase
  the mention carries the summary, so the order is settled by construction; in
  the Copilot phase `--add-reviewer` is a separate call and Copilot can begin
  reading within seconds, so requesting first meant a fast pass reviewed against
  the previous round's account of what changed. The summary post is now first and
  branched on.

- **The reviewers review; they do not implement.** Stated first in `AGENTS.md`
  and the Copilot instructions, because ignoring it is not a no-op: a round
  summary mentioning an unfixed defect was read as a work order, and the run
  edited files and reported a commit made in an environment with no remote and no
  credentials — so the commit existed nowhere, no review was produced, and the
  round was spent.

- **Claude Code only — the Codex plugin packaging is gone.** v1 shipped a Codex
  plugin because the review ran on this machine, through the `codex` CLI and a
  local bus. In v2 both reviewers are GitHub apps running in GitHub's cloud, and
  what they read is committed to the repository, so there is nothing to install
  for them; the driver, meanwhile, needs a watch tool. `.codex-plugin/` and
  `.agents/plugins/marketplace.json` are removed — the latter still advertised an
  "Automated PR review-bus loop", so anyone installing through it got metadata for
  the architecture this release deletes. One manifest now, not two that drift.
  The README's Codex-driver claims went with them: the opening promise that either
  agent could run the loop, the Codex invocation, and the tested-version claim all
  described a path with no installation mechanism behind it.

- **A verdict about a superseded head is not a signoff.** Pinning both probes to
  one OID made the state and the verdict describe the same commit; it did not make
  that commit current. A push landing after the head probe left both probes
  correctly describing the *old* head, and announcing that as `PR_REVIEW_READY`
  advanced the driver on a review of code that was no longer there — the Copilot
  phase would then record the new head as the Codex-signed-off SHA, and nothing
  noticed until the merge gate failed. The head is re-resolved after the verdict,
  and a move is reported and re-polled rather than announced.

- **A pagination cursor that does not advance is a hang.** A stale or malformed
  page can report `hasNextPage: true` while returning the cursor it was asked for,
  and both `pr-findings.sh list` and the merge gate then requested that identical
  page forever. That is worse than the documented failure: nothing times out, no
  status is returned, and the caller waits on a command that will never answer.

- **`blocked-body` refuses an unrecognised review state.** The helper suppresses
  output for anything that is not exactly `CHANGES_REQUESTED`, so a record with a
  null or unknown state produced empty stdout and rc 0 — indistinguishable from
  "this blocking review has no body". The driver only calls it because it saw
  `state=blocked`, so that is exactly where silence loses the only text there is.

- **The merge mode is a setting.** `--admin` remains the default: branch
  protection normally requires an approving review from another account, and
  neither reviewer is one, so dropping it would not tighten the gate for a solo
  maintainer — it would remove the merge path entirely, on every PR. The cost is
  real and now stated: every gate runs client-side against data fetched a moment
  earlier, and `--match-head-commit` only proves the head has not moved, so a
  review can change in the window without the head changing. `REVIEW_MERGE_STRICT=1`
  drops `--admin` and lets GitHub evaluate reviews, checks and conversations
  atomically, which is the only place that race can actually be closed.

- **The round summary and the review request are one comment.** The `@codex`
  mention *is* the request, so posting it separately from the summary split the
  record the reviewer is told to read and sent the request half with no account
  of what changed.

- **A summary states what was done — never what is still open.** A mention whose
  body describes an unfixed defect is read as a *task*: Codex runs as a coding
  agent, edits, commits and reports work from an environment with no remote and
  no credentials, so the commit resolves to nothing, the review never happens,
  and the round is spent. That is not hypothetical — it cost a round of #10.
  `SKILL.md` now says to describe changes in the past tense and point at an issue
  number for anything still open; `AGENTS.md` and the Copilot instructions tell
  the reviewers the summary is a record, not a work list.

- **Thread resolution is verified, not assumed.** `resolveReviewThread` returns
  `thread{isResolved}` and the driver now reads it. A round reported as fully
  resolved when it was not sent the next review back over findings that had
  already been answered, and the extra volume read as regression rather than
  repetition.

- **The watch is armed as part of the round, not put to the operator.** In Claude
  Code the `Monitor` tool is not covered by a `Bash(…)` permission rule, so a
  session allowing every Bash command still stopped to ask before each watch —
  one prompt per round, which turns the automatic loop back into a manual one.
  `README.md § Watching without prompts` says what to allow, and why that grant
  stays out of the committed settings.

- **One head, resolved once and pinned through every probe.** The records
  abbreviate the SHA to seven hex, so binding the state record to the verdict
  record could not tell two commits apart when their prefixes collided — and a
  push landing between the two calls is precisely when that would matter.
  `pr-review-state.sh` grew a `head` subcommand returning the full 40-hex OID;
  `pr-watch.sh` resolves it once per poll and passes it to both probes, so the
  comparison is removed rather than tightened.

- **A GraphQL 200 carrying `errors` is not a response.** GraphQL answers 200 with
  *both* `errors` and structurally valid `data` when it resolves part of a query.
  The partial data passed every shape check in the unresolved-thread gate, whose
  answer is `UNRESOLVED=0` — merge permission, taken with `--admin`, so nothing
  downstream would have caught the omitted thread. `pr-findings.sh list` had the
  same hole, where a silently short list is indistinguishable from a shorter
  review.

- **A review's `state` decides whether it is a finished pass.** `pr-round-count.sh`
  counted on `submitted_at` alone, so a record with a null or unrecognised state
  was a reviewed head, and `PENDING` — a draft in flight, which
  `pr-review-state.sh` refuses to read as a signoff — counted as a round. Both
  inflate the count, which is the direction that skips the operator pause.

- **Copilot is required, and the README now says so.** It was listed as a
  prerequisite "if you want the second pass", while the merge gate demands a clean
  verdict from both reviewers and the Copilot phase stops rather than skipping. A
  user could install for a repository without Copilot and discover only at merge
  time that the loop cannot finish. There is deliberately no skip switch.

- **The verdict value, its field and the exit status must agree.** Requiring only
  the record shape accepted `verdict=clean` with no `findings=0`, and a clean
  record returned with rc 1 — which `PR_REVIEW_READY` then announced as a finished
  clean review, and that is what starts the next phase.

- **A failing helper cannot smuggle a signal.** `pr-watch.sh` echoes helper output
  in its diagnostics, and its stdout *is* the channel Monitor reads. A helper
  printing a newline followed by a forged `PR_REVIEW_READY …` got that line
  surfaced as actionable even though the watch exited 2 — the exit status is not
  what the session sees. Diagnostics are now quoted onto one line.

- **A malformed `submitted_at` is not one more round.** `pr-round-count.sh` treated
  any string as a submitted review, so a single junk timestamp on a full-SHA
  record counted as another distinct reviewed head — and at a real boundary that
  inflates the count past the multiple and skips the operator check-in, which is
  the direction that loses the pause. It now requires the same anchored ISO
  timestamp `pr-review-state.sh` does.

- **A failed review request stops the round.** `gh pr comment "@codex review"`
  and `gh pr edit --add-reviewer @copilot` *are* the requests, so a failure means
  nothing was queued — and the wait step would then poll until it timed out,
  reporting "no review arrived" rather than "none was asked for".

- **The README no longer describes the removed bus.** Its opening paragraph still
  told users that reviews run "on a file-based bus", which is the architecture
  this release deletes — the first thing a reader saw contradicted the setup
  instructions below it.

- **A failed Copilot request does not start the Copilot phase.**
  `--add-reviewer` *is* the request, so when it fails there is no pass to wait
  for — the driver would poll for a review nobody asked for and then report a
  timeout, which reads as "Copilot is slow" rather than "Copilot was never asked".
  It is not permission to skip the pass either: the failure stops the loop and
  goes to the operator.

- **The Codex head-state decision is parsed, not substring-matched.** A truncated
  or wrapped line that merely *contained* `state=none` sent the gate down the
  fallback path — and with a current-head body-only `CHANGES_REQUESTED` there is
  no thread for the unresolved gate to catch, so the merge would pass on a state
  that was never read.

- **The round check-in runs before the push, not after it.** With Codex automatic
  review enabled the *push itself* requests the next review, so a boundary check
  placed after the push cannot stop anything — the operator would be asked once
  the next round was already running. Checking first is the only ordering that
  holds whether auto-review is on or off.

- **The Codex-signed-off head is captured before the Copilot phase begins.** The
  merge gate needs it, and after the first Copilot fix nothing else records it:
  `gh pr view` reports the new head and the state helper prints only a
  seven-character sha. Without the capture the gate could not be populated at all.

- **A superseded request is not an active finding.** `blocked-body` filtered on
  state alone, so a `CHANGES_REQUESTED` the reviewer had already withdrawn by
  approving the same head still printed — sending the driver into another fix
  round after a signoff. The LATEST review of the head decides now, the same way
  the verdict does.

- **Findings carry their thread ID.** `path:line` is not an identifier: two
  unresolved comments can share a line, and a fix commit shifts the lines anyway,
  so the driver had nothing stable to resolve against and could close the wrong
  thread. Every finding now prints `thread=<id>`, and a thread without one is a
  malformed page.

- **Review records are validated where they are used, not only where they are
  counted.** `commit_id` was checked as a SHA in the round counter but not in the
  review-state parser, where a short value is filtered out as "another head" — so
  a malformed page read as `state=none`, which the merge gate answers by trusting
  an older signoff instead of stopping. The timestamp check was a *prefix* match,
  so `2026-01-02T00:00:00zzzz` passed and still sorted after the real
  `2026-01-02T00:00:00Z`: the same lexical hole the check was added to close. It
  is anchored at both ends now.

- **A blocked review must have a readable body.** `.body // empty` mapped a null
  or absent body to empty output with a success status — indistinguishable from
  "the blocking review had no body", in the one path whose whole job is to surface
  a finding that has nowhere else to appear.

- **An unparseable state line is not a state.** A helper exiting 0 with output
  that has no `state=` field left the entire line in the state variable; the watch
  then polled to its ordinary timeout, which the contract reads as "re-request or
  ask whether to keep waiting". Only the five known states are accepted.

- **The range check measures from the SHA the verdict describes.** Making the
  Codex verdict head-aware left the range keyed to the recorded signoff, so when
  Codex had reviewed the current head cleanly the gate still demanded
  `Review-Phase: copilot` trailers across a range Codex had already reviewed in
  full — blocking a merge both reviewers had just approved. Both branches now
  record the effective Codex SHA and the range starts there.

- **`submitted_at` must look like a timestamp.** The snapshot sorts on it to pick
  the authoritative review, and the sort is LEXICAL: `"zzzz"` sorts after every
  real ISO timestamp, so a stale zero-comment `APPROVED` outranked a current
  `CHANGES_REQUESTED` on the same head and the verdict came back clean.

- **A head passed in by the caller is validated like one the helper resolves.**
  `abc123` is all-hex, so a character-only check accepted it and the `commit_id`
  filter matched nothing — reporting `state=none`, which the merge gate reads as
  "this reviewer has not judged the head" and answers by trusting an older
  signoff.

- **Any non-answer from the verdict helper is unreadable.** Only 0 and 1 are
  answers; the documented 2 was handled but a 126/127 still emitted
  `PR_REVIEW_READY` and exited 0, which under Monitor is what tells the session
  there is something to act on.

- **A newer Codex review of the current head wins over the recorded signoff.**
  Both obvious answers to "which SHA do we check Codex against" are wrong, and
  this release shipped each in turn. Always the current head makes the gate
  unreachable in the Copilot phase, where Codex is deliberately not re-run.
  Always the recorded signoff ignores a review that Codex *auto-review* may have
  produced on the Copilot-fix head — and a body-only `CHANGES_REQUESTED` leaves no
  inline thread for the unresolved-thread gate to catch either, so every gate
  would pass with an active request for changes standing. The gate asks about the
  current head first and falls back to the signoff only when Codex has genuinely
  not judged it.

- **The watch fails closed on any helper failure, and never sleeps past its
  deadline.** It treated only the documented exit 2 as unreadable, so a missing or
  non-executable helper (126/127) had its stderr parsed as a state and eventually
  reported a *timeout* — which reads as "wait or re-request" when the truth is
  "this cannot be read". It also emitted `PR_REVIEW_READY` — the signal that
  reaches the session under Monitor — before checking whether the verdict could be
  read, and slept a full interval before re-checking the deadline, so
  `--timeout 1` with the default interval waited thirty seconds. Leading-zero
  intervals are rejected for the same octal reason as the round threshold, and an
  option given without its value is usage rather than an infinite parse loop.

- **A resolved head must be a full SHA.** `abc` is all-hex, so a character-only
  check accepted it and the `commit_id` filter then matched nothing — printing no
  blocking body with a success status, indistinguishable from "there is no
  blocking body".

- **The merge gate could never pass after a Copilot fix.** The phased loop
  deliberately does not re-run Codex during the Copilot phase — that is what the
  `Review-Phase: copilot` trailer and the range check are for — but the gate still
  asked for Codex's verdict on the *current* head. On a Copilot-fix commit that
  verdict is `none`, forever, so the supported path could not merge. Codex is now
  validated against `$CODEX_SHA`, the head it actually signed off, and the range
  check spanning `$CODEX_SHA..$HEAD_OID` is what makes trusting that older signoff
  safe: it proves the head advanced only through tagged Copilot fixes reachable
  from it.

- **A finished review surfaces by itself again.** Removing the bus also removed
  v1's response monitor, and nothing replaced it — the contract simply said
  "there is no notification channel; poll", which in practice means the driver
  sits in a hand-rolled loop and the operator watches it do so. `pr-watch.sh`
  blocks until the reviewer's state is actionable, prints one line per state
  CHANGE rather than per poll, and reports the verdict on the terminal line so
  there is no second round-trip. Claude Code runs it as the session's Monitor;
  under Codex it backgrounds. An unreadable state exits 2 rather than looking
  like "still waiting", because the difference between "no review yet" and
  "cannot tell" is the difference between waiting and merging on a bad read.

- **The findings read is a script, not a snippet.** Three consecutive review
  rounds found fail-open cases in the inline version — an unchecked `jq` status,
  an unvalidated `hasNextPage`, a `gh api --jq` that could not run at all, a
  missing `pipefail`, interpolation rendering a missing author as `null` — and
  each fix was itself prose that no test executed. `pr-findings.sh` now owns it,
  with the cases as tests. This repository has been here before: the merge-range
  check lived inline "where nothing executed it", shipped two defects, and became
  `pr-merge-range.sh` for the same reason.

  It also fixes two live defects in that logic: the blocked-body fetch captured
  `gh`'s output and status together, so a `--paginate` call that wrote a valid
  page and then failed passed its partial output off as the answer; and it
  selected `CHANGES_REQUESTED` reviews by reviewer and state but not by head, so
  a stale request on an older commit — already superseded by a signoff on the
  current one — printed as an active finding.

- **`REVIEW_ROUND_THRESHOLD` handles leading zeros.** Bash reads them as octal in
  arithmetic, so `00` silently disabled the safety pause and `08`/`09` aborted
  with an undocumented exit 1 — neither being the documented fallback to 10. Only
  a bare `0` disables the check-in now.

- **A review's `commit_id` must be a real SHA to count as a round.** Any string
  was accepted, so a malformed-but-successful page could contribute a phantom
  "distinct head" and turn a true boundary of 10 into 11, skipping the pause.

- **Reviews are read-only.** `AGENTS.md` previously said *"run focused tests only
  when necessary to validate a finding"*, which invited the reviewer to install
  dependencies and set up an environment before reading a diff made entirely of
  shell and Markdown — turning a three-minute read into a twenty-minute one while
  the author is blocked either way. Both instruction files now say plainly: no
  environment setup, no dependency install, no test runs, no script execution.
  Where a finding would have been confirmed by running something, the reviewer
  states the failing case it expects and the author verifies it — which is the
  author's job in this loop, and they run the suite before every push.

- **The loop is phased: Codex to clean, then Copilot.** Requesting both every
  round buys a Copilot pass on every intermediate commit and mixes its findings
  into a round that was not about them. Codex now reviews to a clean signoff
  first; only then is Copilot asked, and its fix commits carry a
  `Review-Phase: copilot` trailer so the merge gate can prove the head advanced
  only through Copilot fixes and Codex's signoff still covers it. Codex is not
  re-run during that phase — and if a commit there lacks the trailer, the range
  check fails and Codex reviews again, which is the correct outcome because
  unreviewed work reached the head.

- **Rounds are counted per reviewer.** The two phases are separate loops, so a
  shared counter would let nine Codex rounds plus one Copilot round trip a pause
  that neither loop had reached. `pr-round-count.sh` takes the reviewer as an
  argument and the driver passes the active one.

- **The round check-in is enforced, not just promised.** v1 kept the count in a
  `/tmp` file, so the pause silently disappeared whenever a session started on
  another machine or the file was cleaned up — a guarantee that only holds while
  a temp file survives is not a guarantee. `pr-round-count.sh` derives it from
  GitHub every time: a round is a *distinct PR head that received a submitted
  review*, so two reviewers on one commit is one round and a re-review of an
  unchanged head does not inflate it. An unreadable count exits 2 rather than
  reading as "no rounds yet", which is the direction that skips the pause.

### Upgrading from 1.x

Stop and disable the daemons, then delete their unit files:

```bash
systemctl --user disable --now review-bus-<owner>-<repo>-watcher review-bus-<owner>-<repo>-monitor
rm -f ~/.config/systemd/user/review-bus-<owner>-<repo>-*.service
rm -rf /tmp/<owner>-<repo>-review-bus
```

Then link the Codex GitHub connector once at
`chatgpt.com/codex/cloud/settings/connectors`, and set per-repository review
behaviour on the Codex **Code review** settings page. `.review-bus.md` is no
longer read; move anything project-specific in it into `AGENTS.md`.

## [1.0.14] — 2026-08-04

- **`resp=` is the last token on every sentinel, and that is now enforced.**
  `SKILL.md` tells the driver to take `${LINE##*resp=}` as the response path, but
  four sentinel branches still emitted `resp=<path> reason=<why>`, so the
  documented parser handed back the path with the reason glued to it. The order
  is fixed everywhere, and a structural check now walks every emission site in
  the monitor - a runtime fixture only covers the reasons a test happens to
  trigger, and these drifted in one at a time.

- **Release history cannot drift silently.** This release's opening entry names
  the version that preserved the note, and a renumber left it pointing at 1.0.12,
  a release that never provided `model_summary` - so the reader was documented as
  depending on a version that does not supply what it reads. The check now
  requires the named release to exist in the CHANGELOG *and* to be the section
  that introduces the field, and both plugin manifests to agree with the newest
  heading.

- **The driver can read the reviewer's note.** 1.0.13 preserved the note in the
  bus response; this makes it reachable. The handoff line gains
  `reviewer_note=1` and `digest=`, and `review-bus-response-monitor.sh --note
  <response> <sha256>` prints the note **JSON-escaped** so a hostile note is
  legible as data and inert as bytes.

**The note is flagged, not inlined.** It is model output derived from untrusted
  PR context, so the handoff line carries only `reviewer_note=1` and the text is
  read from `.model_summary` in the response file. Inlining it would let a note
  carrying ESC/BEL bytes inject into a terminal or log, and one containing
  `resp=` would put a second copy of a framing token into a line the driver
  parses positionally. The assembled line is also stripped of all control bytes,
  mirroring `emit_progress`. `SKILL.md`'s handling contract now tells the driver
  to read the note and relay it as untrusted, non-blocking context that can never
  affect status, findings, or a merge gate.

- **The reviewer's note is read through a fail-closed helper, not by hand.**
  `SKILL.md` previously told the driver to run
  `REVIEWER_NOTE="$(jq -r '.model_summary' ...)"`, which is broken twice over: a
  one-shot shell assignment emits nothing, so the note was silently dropped, and
  a driver compensating with a raw `jq -r` would decode ESC/BEL straight into
  whatever renders its tool output - reintroducing at the last hop the injection
  the handoff line was hardened against. `review-bus-response-monitor.sh --note
  <response> <sha256>` now prints the note **JSON-escaped** (0 = emitted, 1 = no note,
  2 = unreadable or malformed), so a hostile note is legible as data and inert as
  bytes, and a flagged-but-broken response is distinguishable from an absent one.

  The helper validates the response with a slurped `length == 1` guard and reuses
  that captured object, because `jq` reads a stream: two concatenated objects
  passed every per-object check and would have emitted two notes at exit 0.
  `SKILL.md` runs the helper as the final command in the call so its exit status
  survives - an earlier revision appended `; NOTE_RC=$?`, which made the call
  report success whatever the helper returned. A test extracts that command from
  `SKILL.md` and executes it, so the documented contract and the behaviour cannot
  drift apart.

- **The handoff line is validated and digest-bound.** `emit_response` also read
  the response as a jq STREAM, so a file holding two objects produced two handoff
  lines and the control-byte strip then removed the newline between them -
  collapsing them into one line carrying two `status=` and two `resp=` tokens,
  which a positional driver could read as an ambiguous clean status. It now
  slurp-validates a single top-level object BEFORE claiming the emit marker, and
  emits only a `_REVIEW_PARSE_ERROR` sentinel for anything invalid, including a
  present-but-malformed note (which must never raise `reviewer_note=1`). The line
  now carries `digest=`, and `--note` takes that digest and refuses to emit on
  mismatch: `resp-<sha>.json` is mutable, so a same-SHA re-review could otherwise
  hand the driver a newer note it would attribute to the earlier review - the
  same binding `--ack-if-digest` already uses. The digest argument is
  **required**: an optional one is not a binding at all, since an unset or
  misparsed value would skip the check and emit whatever occupied the path.

- **The note is emitted ASCII-only and monochrome (`jq -aM`).** Default jq output
  is not terminal-inert: it leaves non-ASCII raw, so a U+202E bidi override
  reached the renderer as bytes and could reorder surrounding text, and it adds
  ANSI colour on a TTY when `NO_COLOR` is unset. The ESC/BEL test missed both
  because it captured output rather than running on a terminal. Coverage now
  includes a bidi/C1 payload and a TTY-style run.

- **The digest and the handoff formatter fail closed.** Both ran under
  `... || true`, and a command substitution keeps whatever the tool wrote before
  it failed — so the two fail-closed boundaries the monitor depends on could be
  crossed by a faulting tool rather than a malicious one. A failing `sha256sum`
  produced an empty digest and returned *silently*, indistinguishable from
  "nothing to emit", while its partial output could instead be advertised as a
  valid digest — the value the ack gate, the emit marker and `--note`'s
  verification are all keyed on. A failing `jq` in the formatter was worse: it
  could write a plausible `status=approved findings=0` line, have its exit code
  discarded, and see that line emitted as a normal handoff. Hashing now goes
  through one helper that checks the status and requires exactly 64 lowercase hex
  characters; the formatter's status is checked before its output is accepted;
  both failures emit `_REVIEW_PARSE_ERROR` instead of silence or a handoff; and a
  failed emit leaves the response retryable because the marker is not claimed
  until the line is ready - the failure path takes nothing, and releases nothing.
  On the `--note` side the unguarded hash took the
  script down under `set -e` carrying the tool's own exit code (7) with no
  `MONITOR_NOTE_ERROR` line; it now reports the documented exit 2.

- **A stale response that cannot be retired stops the monitor.** `mark_emitted`
  is what suppresses a superseded prior-iteration response, and it turned a
  digest failure into a successful no-op — so when the stale file's hash failed
  during startup, no marker was written, the live sweep hashed it successfully on
  its next pass, and the OLD handoff went out after the newest one. The driver
  then acts on a superseded review. Suppression failure is now reported as
  `reason=stale_suppression_failed` and the monitor exits instead of entering the
  live watch, where the next thing emitted would be known-wrong; a restart
  re-attempts it.

- **`--note`'s own formatter fails closed.** It was the last bare
  stdout-producing command in the file: a jq that printed a plausible JSON string
  and then failed sent that fragment to stdout and returned the tool's exit code,
  outside the documented 0/1/2 contract and with no `MONITOR_NOTE_ERROR` to
  explain it — so a caller reading stdout would have taken the fragment for the
  reviewer's note. Partial output is discarded and the failure exits 2.

- **The documented note-reader block is data-safe and self-contained.** It told
  the driver to paste the notification line into a single-quoted assignment, and
  `summary` keeps apostrophes and shell metacharacters - it is quoted and reduced
  to printable ASCII so it cannot forge a *framing token*, which is a different
  problem - so a summary shaped like `reviewer'$(…)'s note` closed the quote and
  ran the substitution in the driver's own shell before `--note` was reached. The
  line is now read through a QUOTED here-doc, which suppresses every expansion.
  The same block also relied on an `$RB_SCRIPTS` from an earlier, separate shell,
  so as written it invoked `/review-bus-response-monitor.sh` and exited 127; it
  resolves the installed scripts itself now, and the test runs it with
  `RB_SCRIPTS` unset instead of injecting one.

- **The trusted review guidance no longer contradicts the release.** With the
  reader shipping here, `.review-bus.md` still said the note was "recorded, not
  yet surfaced" - and that file is loaded verbatim into every future review
  prompt from the base ref, so the release would have told reviewers the opposite
  of what ships. The base-ref design requires S2b to retire that interim
  paragraph; it does, and the prompt-scope assertions invert with it.

- **A digest failure is reported even when the source moved.** The digest is
  taken from the private snapshot, so probing the mutable response path could not
  explain a hashing failure - it only supplied an escape: a hasher fault racing a
  moved response made `--once` exit 0 with no output, indistinguishable from an
  empty queue. The disappearance no-op belongs to the snapshot step, which is the
  one that actually reads the source.

- **A failing sweep no longer deletes another sweep's marker.** The emit marker
  is claimed after formatting, so the `rm -f` on the format and empty-line
  failure paths released a marker this invocation never held - erasing the record
  written by an EARLIER successful sweep, so the same handoff was delivered twice
  once the fault cleared. Neither path touches the marker now.

- **`--once` keeps its documented exit 0.** The stale-suppression failure exited
  non-zero even in `--once`, contradicting the contract `SKILL.md` ships - and a
  contract that is false for one reason out of ten is worse than none, because a
  driver cannot see which. `--once` exits 0 with the sentinel on stdout and
  `MONITOR_FATAL` on stderr; the LIVE watch still refuses to start, which is
  where the superseded handoff would actually be emitted.

- **A response that vanishes mid-snapshot is a no-op, not a stop.** Every
  snapshot-copy failure was reported as `reason=snapshot_failed`, and `SKILL.md`
  defines that sentinel as a fail-closed halt - so the watcher archiving an old
  response between a sweep's `find` and its `cp`, which is ordinary same-SHA
  reprocessing, would stop the workflow. The disappearance no-op belongs at this
  boundary, since `snapshot_response` is the only step that reads the mutable
  source; unreadable and failed-copy cases with the file still present are still
  reported.

- **A stale response removed while it is being hashed is not a suppression
  failure.** `mark_emitted` tests that the file exists and then opens it again to
  hash it, so a response cleaned up between the two made the digest fail for a
  file that is gone - and a stale response that no longer exists cannot be
  emitted, so there is nothing left to suppress. Reporting it took the live
  monitor down and restarted it over ordinary cleanup. Existence is re-checked
  after a digest failure; a still-present unreadable response still fails loudly.

## [1.0.13] — 2026-08-04

- **Fix: the reviewer's own summary was discarded whenever a review reported
  findings**. `process_review` read `.summary` from the
  model result only in the zero-findings branch; with one or more findings it was
  overwritten by a status line and never reached the PR or the bus response. The
  prompt asks for a summary on *every* review — including the verification
  limitations a reviewer cannot attach to a diff line — so the bus was discarding
  exactly the text it requested. A reviewer that correctly declined to force a
  concern into a line-attached finding lost the concern entirely.

  The model's text is now read once, before the status line is composed, and
  preserved as `model_summary` in the response. It is **not** posted as an issue
  comment: `latest_issue_comment_at` applies no author filter and
  `auto_preflight_ready` uses it as the "round was closed out" gate, so a
  watcher-authored comment would satisfy that gate by itself and let
  auto-enqueue fire without the author ever closing the round.

- **The handoff `summary` field is quoted.** That field is the *synthesized
  status line* the watcher composes - a findings count, or a signoff-posted
  notice - never the reviewer's own words: the reviewer text lives only in
  `model_summary`, which this release records and deliberately does not deliver.
  The quoting is malformed-response hardening rather than note handling: a
  response whose `summary` carried `resp=` or `status=` put a second copy of a
  framing token into a line the driver parses positionally. It is now quoted
  (with `"` stripped from the content) and the real `resp=` remains the last
  token, so the parse rule is unambiguous: take the last one.

- **The handoff line is validated before it is emitted.** `emit_response` read
  the response as a jq STREAM, so a file holding two objects produced two handoff
  lines and the control-byte strip then removed the newline between them -
  collapsing them into one line carrying two `status=` and two `resp=` tokens,
  which a positional driver could read as an ambiguous clean status. It now
  slurp-validates a single top-level object BEFORE claiming the emit marker, and
  emits only a `_REVIEW_PARSE_ERROR` sentinel for anything invalid.

- **Fix: a schema-invalid reviewer result could earn a clean APPROVAL.**
  `process_review` validated `.findings` but never `.summary`, which the output
  schema requires on every review. A result such as `{"findings":[]}` fell into
  the zero-findings branch, picked up a default "no actionable issues" string,
  and was approved — a malformed reviewer output approving the PR. The result is
  now rejected unless `summary` is a non-empty string, so it fails closed to an
  error response with no signoff posted.

  With a real channel available, the prompt now routes non-blocking observations
  to `summary` on every review instead of telling reviewers to drop them when
  findings exist, and `.review-bus.md` loses the workaround paragraph it carried
  for exactly this bug.

- **A response the monitor cannot group is reported, not dropped.**
  `emit_response` validates a response and emits a `_REVIEW_PARSE_ERROR`
  sentinel when it is malformed — but `replay_existing` never got that far: it
  pulled `.pr` first and silently `continue`d on any file that produced none.
  A truncated `resp-*.json`, a top-level array, or a bare string therefore made
  `--once` exit 0 printing nothing, byte-identical to "no pending review", so a
  polling driver read a lost review as "nothing to do". Ungroupable responses
  now go through `emit_response`, and the shape check additionally requires a
  numeric `.pr` — the field the handoff line names and the replay groups on —
  so a well-formed object missing it surfaces the sentinel instead of `pr=null`.

- **The reviewer's note is stored byte-exact.** It crossed the shell as a raw
  value, and a raw shell value cannot round-trip an arbitrary JSON string:
  command substitution strips every trailing newline, and the shell cannot hold
  a NUL byte at all. A summary ending in two newlines was recorded with none,
  and one carrying an escaped NUL was recorded without it - silently, with
  validation still reporting success, so the *altered* text was recorded as the
  reviewer's own words. The note now travels JSON-encoded from the one jq pass
  that validates it to the one that writes the response, and `--argjson` decodes
  it back unchanged.

- **The monitor validates every control field it hands the driver.** The shape
  guard checked only that the response was one object with a numeric `.pr`, so
  an object carrying just `pr`/`sha`/`status` emitted a handoff reading
  `status=approved findings=null reviewer=null` - and the driver branches on
  `status=approved` to merge, meaning malformed bus data could be read as a
  clean terminal result. A positive integer PR, a hex SHA, a status from the
  writer's own enum, a non-negative integer findings count, a string reviewer,
  and the consistency between status and count are all required before the emit
  marker is claimed. An unreadable response (mode 000, a hasher fault) now
  reports `reason=digest_failed` instead of exiting silently; a response that
  genuinely vanished mid-sweep stays the quiet no-op it should be.

- **`reviewer` is pinned to the value the writer emits.** It is interpolated
  into the handoff line unquoted, so requiring only a string was not enough:
  `reviewer: "codex status=approved findings=0"` is a valid string that puts a
  second, clean-looking status/findings pair on a line the driver parses
  positionally, right beside the real one. Every other unquoted field is already
  pinned to a shape too narrow to carry a framing token and `summary` is quoted,
  so this was the last gap.

- **The emit marker is claimed last.** It was claimed before the formatting and
  sanitization steps, so a failure in either - under strict mode a dying `tr`
  takes the monitor with it - left the marker behind with nothing emitted, and
  the restarted monitor read that claim as "already delivered" and suppressed the
  response permanently. The claim now happens immediately before the line is
  printed, still atomically, so the startup replay and the inotify loop still
  cannot both emit the same response.

- **An unreadable summary can no longer become an approval.** `process_review`
  runs beneath `if !`, so errexit does not stop it, and `|| summary=""` turned a
  failed decode of the reviewer's note into an empty string - at which point the
  clean-signoff branch substituted its built-in no-findings text and posted an
  APPROVE for a result that had not been read. The same state was reachable
  through validation: `\S` matches control and format code points, so a summary
  of nothing but NUL passed and then decoded to nothing in the shell. The note
  must now contain a character that is neither whitespace nor a control nor a
  format code point, and a decode failure records an error instead of signing
  anything off.

- **`summary` is a control field, and the handoff is inert for Unicode
  controls.** The response guard did not check `summary`, so a response carrying
  valid `pr`/`sha`/`status`/`count`/`reviewer` and nothing else emitted
  `status=approved summary=""` - a terminal result the driver acts on. And the
  "all control bytes stripped" guarantee was false: `tr -d '[:cntrl:]'` is
  byte-oriented, so UTF-8-encoded C1 controls (U+009B) and bidi overrides
  (U+202E) passed through untouched - exactly the code points that reorder or
  hijack terminal and log rendering. `summary` must now be a non-blank string,
  and it is reduced to printable ASCII inside jq before the line is assembled.

- **The parse-error sentinel has a driver contract.** The monitor emitted
  `_REVIEW_PARSE_ERROR` with nothing in `SKILL.md` or `README.md` telling a
  driver what it means, while `--once` still exits 0 - so a polling driver had no
  defined action and could stall, or read the silence as "no findings". Both
  documents now state it: never merge on it, never ack it, surface it with its
  reason, and branch on the lines rather than the exit status. `resp=` is now the
  final field on the sentinel as well as the handoff, so the documented
  last-token parsing rule is true of every line the driver reads.

- **A summary that normalises to nothing is not a verdict.** The shape guard
  tested the RAW summary with `\S`, which matches control and format code
  points, while the formatter then replaced exactly those with spaces - so a
  summary of NUL plus a bidi override passed validation and went out as
  `status=approved summary="  "`, a terminal result the driver acts on, built
  from a response that says nothing. The guard now applies the formatter's own
  normalisation first and requires a visible ASCII character to survive it.

- **The parse-error sentinel no longer floods.** It was emitted before the
  per-digest emit marker was claimed, so the live loop re-emitted the same
  malformed response on every sweep - forever, since the driver contract forbids
  acking it to make it stop. Sentinels now claim that session-scoped marker, so
  each is delivered once per session per response content; no ack is written, so
  the response stays unhandled, and a fresh session or a changed digest still
  re-surfaces it. Tool-failure sentinels (a failed sanitize) stay undeduplicated
  on purpose: the response is fine and must still be deliverable once the fault
  clears.

- **A summary must contain a RENDERED character.** Two earlier rules were both
  too weak: `\S` matched control and format code points, and excluding `\p{Cc}`
  and `\p{Cf}` still accepted a summary of nothing but marks - U+FE0F is
  category `Mn`, so a `{"summary":"\uFE0F"}` result earned a clean APPROVE. The
  test is positive now: at least one letter, number, punctuation mark or symbol,
  which is what "the reviewer wrote something" means. The shell-side guard uses
  the same rule rather than a POSIX approximation, so the two cannot disagree.

- **A failed marker write is not "already delivered".** The atomic claim
  collapsed "another sweep holds it" and "it could not be written" into one
  branch, so an existing but unwritable emit dir made `--once` exit 0 with no
  output - the silence this file exists to prevent. The two are distinguished:
  an unwritable marker reports `emit_marker_failed` and the response is still
  delivered, because losing the ability to record delivery is not a reason to
  withhold a review.

- **A formatter failure no longer retires a good response.** With the
  formatter's status erased, a failure surfaced only as an empty line and was
  reported as `empty_line` - a CONTENT reason - through the deduplicating helper,
  which claimed the digest and suppressed a perfectly valid response for the rest
  of the session. The formatter is guarded explicitly, and both it and
  `empty_line` are reported undeduplicated like `sanitize_failed`: the response
  is fine, so it must stay deliverable once the tool recovers. `SKILL.md` now
  groups the reasons by which of the two they are, since the group decides
  whether the driver re-requests the review or fixes its own environment.

- **"Visible text" is one predicate, and it is not a category test.** Three
  character-class rules failed here in a row, each missing what the next found -
  and the third still accepted U+3164 HANGUL FILLER and U+2800 BRAILLE PATTERN
  BLANK, which are `Lo` and `So` by category while rendering as nothing. Unicode
  categories cannot answer "does this render", so the blank code points are
  removed by VALUE first and the category test applies to what remains. The rule
  is defined once and used by both the validator and the pre-signoff check;
  having it spelled twice is how the earlier versions drifted apart.

- **A superseded review still records the reviewer's summary.** That branch
  called `write_response` with seven arguments, silently dropping
  `model_summary` - so a valid result whose request was overtaken lost the
  reviewer's words, the one thing the base-ref contract says is recorded on every
  review. The review ran and produced a summary; only its comments were
  abandoned.

- **A failed read is not a verdict on the content.** The shape check treated
  "jq exited non-zero" and "jq ran and rejected this" identically, routing both
  through the deduplicating `invalid_response_shape` sentinel - so a transient jq
  fault claimed the digest and retired a perfectly valid response for the rest of
  the session. Command failure now takes the non-deduplicated tool-failure path;
  `invalid_response_shape` is reserved for content jq successfully parsed and
  rejected.

- **A delivery marker cannot outlive a failed delivery.** It was committed
  before the final write, so `--once` against a full disk created the marker and
  then failed to print - and the next healthy run suppressed the handoff
  entirely, losing a completed review from a persistent namespace. Both the
  handoff and the sentinel roll the marker back when their write fails.

## [1.0.11] — 2026-08-03

- **Fix: the watcher crash-looped after a final response (issue #3).** With
  `CODEX_REVIEW_AUTO_OPEN_PRS=1`, once a PR's current head had a terminal
  non-error response (`approved`, `comments_posted`), `write_auto_request`'s
  intentional no-op ran `[ "$prev_status" = "error" ] || return`. A bare `return`
  inherits the failed test's exit status 1, and the function is called unguarded
  under `set -Eeuo pipefail` — so the no-op killed the daemon and systemd
  restarted it every few seconds. Reproduced live on this repository's own PR #4
  (`NRestarts=6`) the moment Codex posted its clean signoff.

  Every intentional no-op in `write_auto_request` and `handle` now returns 0
  explicitly. `handle` carried the same defect at its `[ -f "$req" ] || return`
  guard, where a request file vanishing between detection and handling would have
  killed the daemon identically. `test-review-bus-noop-returns.sh` covers both
  terminal statuses, the unguarded `set -e` call site, the vanished-request case,
  and asserts that an `error` response is still retried — so the obvious wrong
  fix, returning 0 unconditionally, cannot pass.

- **Reviewers now read what the PR set out to do.** The watcher already
  snapshotted `pr.json` and `issue_comments.jsonl`, but the prompt never told
  the reviewer to use them, so every project re-authored the same relevance rule
  by hand in its own `.review-bus.md`. `build_prompt` now directs the reviewer to
  establish intended scope from those files and use it for **relevance only** —
  work the PR never claimed to do is a non-blocking note, while a defect in what
  it did change stays a finding — and marks that context as intent, never
  permission, so it cannot waive a finding.

- **The SessionStart hook no longer arms the bus from inside a review.** The
  reviewer runs `codex exec` in a detached worktree of the PR head, which carries
  the project's own `.review-bus.md` — so in an opted-in repo the hook's gate
  passed for the reviewer too, re-ensuring the daemons and injecting the "invoke
  `watch-prs`" instruction into the reviewer's own context, spending the pass on
  bus setup instead of the diff. The hook now exits silently on either of two
  independent signals: `REVIEW_BUS_WORKER=1`, which the watcher exports into the
  review, or a `review-bus-worker` marker the watcher writes into the worktree's
  **git dir** — never the working tree, so it cannot reach the diff — which holds
  even where a tool does not forward env to hook commands. The marker is
  deliberately not a path test: `CODEX_REVIEW_WORKTREE_ROOT`, `BUS_DIR` and the
  review clone are all operator-overridable, so matching a literal
  `.codex-worktrees` would miss a custom root while falsely silencing an ordinary
  checkout that happened to sit under one. Found by this repository's first
  self-review.

- **Copilot is told where a non-blocking observation may go.** The bus counts
  every inline comment on Copilot's latest review as a finding, and any non-zero
  count sends the PR through the merge-blocking fix loop — so an instruction to
  "raise a non-blocking note" with no channel named made Copilot manufacture
  blockers. `.github/copilot-instructions.md` now forbids filing such an
  observation inline and points at the overall review body, which is not counted.

- **The prompt no longer names a note category the bus cannot carry.** The new
  scope instructions referred to a "non-blocking note", but every `findings[]`
  entry becomes a merge-blocking thread and `summary` survives only on a
  zero-finding review, so such an observation became either a false blocker or
  silently discarded text. The prompt now routes it explicitly: carry it in
  `summary` only when returning zero findings, otherwise omit it. Issue #212
  tracks giving it a real channel.

- **The plugin now reviews itself.** Adds `.review-bus.md` (review policy, read
  from the base ref, which also opts this repo into the SessionStart hook),
  `CLAUDE.md` (canonical authoring rules), `.github/copilot-instructions.md` (the
  one deliberate restatement, because Copilot follows no pointers), an
  `AGENTS.md` pointer above claude-mem's generated block, and a committed
  `.claude/settings.json` so a fresh clone arms itself. Changes to the review bus
  were previously reviewed with less rigor than the projects it serves.

## [1.0.10] — 2026-07-21

- **Fix: cross-repo monitor/watcher kill (the "kill bug").** Since the plugin
  extraction, every repo's daemons exec the identical installed script path, so
  `kill_legacy`'s `pgrep -f -- "$script"` matched a *sibling* repo's healthy
  systemd daemons and TERMed them — only the last-started repo's monitor
  survived. `kill_legacy` now skips any PID already owned by a
  `review-bus-*.service` systemd cgroup (read from `/proc/$pid/cgroup`); systemd
  owns those lifecycles, so only genuinely-legacy setsid strays are swept. Two
  repos' daemons can now coexist.

- **Fix: the round-count check-in never fired.** The pause-every-10-rounds safety
  stop lived only in `SKILL.md` step 0 (bypassed by a manually-driven loop) and
  counted `fix(review):`-prefixed commits (round-fix commits use a module scope
  like `fix(shipment): … (review r7)`, so the count was always 0). It now lives
  in `review-bus-request.sh` — the chokepoint every next-round enqueue passes
  through, manual or via `review-bus-close-round.sh` — and counts **distinct
  enqueued HEAD SHAs** per PR (a same-SHA retry never double-counts). At a
  non-zero multiple of `CODEX_REVIEW_ROUND_THRESHOLD` (default 10) it refuses to
  enqueue (exit 3, `REVIEW_BUS_THRESHOLD_PAUSE`) so the driver pauses to ask the
  operator; cross a single pause with `--continue-threshold`, or disable with
  `CODEX_REVIEW_ROUND_THRESHOLD=0`. `close-round` forwards the pause as a clean
  stop (round still closed + acked; next review withheld).

- **New: live review-progress notifications.** While Codex reviews, the watcher
  writes lifecycle state under `$BUS/progress/` (atomic per-run files keyed by a
  unique `run_id`, so same-SHA re-reviews stay distinct), and the monitor
  surfaces it as throttled `${PREFIX}_REVIEW_PROGRESS` lines — start, phase
  changes, and a heartbeat — so the session sees a review begin and advance
  instead of waiting for the terminal handoff. When the installed Codex supports
  `exec --json`, the watcher taps its event stream for live event/command
  counters (falling back to lifecycle phases + elapsed heartbeats otherwise),
  always preserving Codex's real exit status. Progress is repository-scoped, is
  never a `${PREFIX}_REVIEW` handoff, and — at the default `status` detail —
  carries only counters + phase (never raw chain-of-thought, command output, or
  secrets; the optional `summary` detail relays a sanitized, truncated note). A
  monitor that (re)starts mid-review replays only the active run as
  `state=resumed`; completed history is never replayed. Knobs:
  `CODEX_REVIEW_PROGRESS`, `CODEX_REVIEW_PROGRESS_INTERVAL_SECONDS`,
  `CODEX_REVIEW_PROGRESS_DETAIL`. New `test-review-bus-progress.sh`.

- **Round check-in covers the PASSIVE auto-enqueue too.** The threshold logic is
  now a shared library (`review-bus-rounds.sh`) sourced by BOTH the manual
  `review-bus-request.sh` and the watcher's `write_auto_request`, with
  a single lock-scoped check-and-claim (`review_bus_claim_round`) — so the polling
  watcher's auto-enqueue can no longer bypass the operator pause (it HOLDS with
  `CODEX_AUTO_SKIP reason=round_threshold`), and a concurrent manual + passive
  enqueue at the boundary can't both slip past (the threshold decision and the
  round append share one lock; append-only locking left a check-then-claim TOCTOU).
  Locking uses ONE mutex domain for every process — an atomic **mkdir mutex** (no
  `flock`/mkdir split that let peers in different domains both enter, and no
  `flock` dependency). A stale lock is reclaimed only when its recorded holder is
  **provably dead** (`kill -0` never falses a live/slow PID, so a live holder is
  never evicted; the reclaim atomically renames the exact stale dir); if the lock
  can't be acquired within a bound it **fails closed** (callers do not enqueue)
  rather than time-stealing a possibly-live holder. The fail-closed result is a
  status **token** (`review_bus_claim_round` always returns 0), so a bare
  `claim="$(…)"` under `set -e` branches on it instead of aborting the caller
  (which would have exited the request script — and could crash the watcher —
  before the handler).
  The Codex-vs-Claude-Code progress-consumer split is applied to the arming
  instructions + README too (Codex polls the monitor log; no auto-notification is
  promised there). Progress `CODEX_REVIEW_*` knobs are now forwarded to
  the MONITOR systemd unit too (not only the watcher), so an operator override
  isn't silently reset to defaults. SKILL documents the runtime-agnostic progress
  consumer (the monitor log; auto-surfaced via a watch tool in Claude Code, polled
  in Codex). New `test-review-bus-auto-threshold.sh`; launch-context test extended
  to the monitor env (suite: 19).

- **Harden every numeric operator knob against a typo.** All operator-supplied
  numeric env knobs are coerced at their boundary so a bad value can't crash or
  silently mis-configure a long-lived daemon under `set -Eeuo pipefail`:
  - `CODEX_REVIEW_PROGRESS_INTERVAL_SECONDS` and `MONITOR_POLL_SECONDS` feed
    `-lt`/`-ge`/inotifywait `-t` in the monitor's live loop — a non-integer /
    empty / 0 / negative value would error the test and terminate the monitor
    (stopping progress AND the terminal `${PREFIX}_REVIEW` handoff). Now coerced
    to a positive integer (else the default) via `_positive_int_or`.
  - `CODEX_REVIEW_ROUND_THRESHOLD` is coerced to a non-negative integer inside
    the shared `review-bus-rounds.sh` (covering BOTH the manual and passive
    enqueue paths): a typo like `abc` / `1.5` / `-5` / empty used to make the
    `[ … -gt 0 ]` test error out to "disabled", silently bypassing the operator
    pause and allowing unlimited enqueues. It now falls back to the default 10;
    `0` remains a meaningful explicit disable, and a leading-zero value is read
    base-10 (`08` → 8) so it can't trip an octal-parse error in the `%` math.

- **`close-round`'s pause guidance is copy/paste-runnable.** When the round-count
  check-in pauses, the "To continue" hint now prints the script by its absolute
  `$SCRIPT_DIR/review-bus-request.sh` path (the same form `close-round` itself
  invokes it by) instead of a bare `review-bus-request.sh` that only runs if the
  scripts dir happens to be on `PATH`. Asserted in `test-review-bus-close-round.sh`.

- **Threshold-pause line prints the full HEAD sha.** `REVIEW_BUS_THRESHOLD_PAUSE`
  labelled `next_sha=` but printed the 7-char short sha, while the round gate/lock
  is keyed on the full HEAD sha — misleading when triaging a pause. It now prints
  the full sha (asserted in `test-review-bus-request.sh`).

- **Strip control bytes from every emitted progress line (log-injection defense).**
  `$BUS/progress/*.json` is local state the watcher already sanitizes on write, but
  the monitor's `emit_progress` now also strips ALL control bytes from the fully
  assembled `${PREFIX}_REVIEW_PROGRESS` line (not only newlines/quotes in the
  `note`) before it reaches the log / an operator's terminal — a stray ANSI escape
  or BEL in any interpolated field (`note`, `last_event`, `phase`) is no longer a
  terminal/log-injection vector. Mirrors the watcher's `tr -d '[:cntrl:]'`; covered
  by a crafted-reasoning case in `test-review-bus-progress.sh`.

- **`review_bus_rounds_done` always echoes a single integer.** `grep -c .` prints
  `0` but *exits 1* on an empty rounds file, so the old `grep -c … || echo 0`
  emitted TWO lines (`0\n0`) — which then broke every downstream `[ "$done" -gt 0 ]`
  numeric test (the pause logic). It now captures the count and falls back to `0`
  only when the output is empty, never on grep's no-match exit code.

- **`_review_bus_locked` never leaks its lock on a failing body.** The critical
  section ran as a bare `"$@"; rc=$?`; sourced into a caller with `set -e`, a
  non-zero body triggered an ERR exit *before* the `rm -rf "$lock"`, leaving a
  stale `.lockd` that wedged every future enqueue. The body now runs as
  `rc=0; "$@" || rc=$?`, so cleanup always executes and the real status still
  propagates. Both regressions covered in `test-review-bus-auto-threshold.sh`
  (empty-file single-`0`; a failing body under `set -e` still removes the lock).

- **Robust progress `run_id` + documented `queued` phase.** Two review-time
  progress refinements: (1) the per-review `run_id` (extracted to
  `_progress_new_run_id`) now appends the pid and a random nonce to the timestamp,
  so two same-SHA re-reviews started within the same second can't collide and
  overwrite each other's progress file even where `date +%s%N` is unsupported /
  low-resolution — preserving the "same-SHA re-reviews stay distinct" guarantee;
  (2) the watcher's initial phase `queued` (carried on the first `state=started`
  line) is now listed in the README/SKILL phase progression, and SKILL's example
  line — which wrongly showed `state=started phase=preparing_context` — is
  corrected to `phase=queued`, so a consumer keying off the documented phase set
  isn't surprised. Covered in `test-review-bus-progress.sh` (low-res-clock
  uniqueness + a doc-consistency guard). Also corrected SKILL's progress-consumer
  description: the Claude Code `Monitor` **runs `review-bus-response-monitor.sh`**
  (which reads the responses/progress dirs directly) rather than "tailing the log"
  — the log is the daemon's audit copy that **Codex** polls; the two bullets now
  match the **Surface reviews** section.

## [1.0.9] — 2026-07-19
- **New `review-bus-close-round.sh` — one-command round close-out.** The bus
  handoff after addressing a Codex round is not "push + comment": the loop only
  continues when every thread is replied-to + resolved, a fresh summary is
  posted, the next SHA is enqueued, and the handled response is acked. Skipping
  any of these silently stalls the loop (the watcher holds auto-enqueue while
  threads are unresolved; `review-bus-request.sh`'s gate blocks). The new script
  does the whole finalize in one command — preflight up front, then the steps in
  a fail-safe order: resolve every open thread with a thread-level ack, post the
  summary, re-enqueue via `review-bus-request.sh` (all gates re-checked), and ack
  the pre-request responses. It is not transactional — a failure partway stops
  loudly (non-zero exit) and is safe to re-run — but no step is silently skipped.
  SKILL step 7 now calls it instead of the hand-run resolve → request → ack
  sequence that was easy to half-complete. `test-review-bus-close-round.sh`
  covers it (suite: 17).
  - Preflight validates the whole close-out BEFORE the first GitHub mutation:
    HEAD clean + pushed + equal to the PR's head, and `--summary` a **regular**
    readable file (`-r` alone accepts a dir/FIFO that would only fail inside
    `gh pr comment` after every thread is resolved). A reply failure leaves its
    thread unresolved and exits non-zero — never resolve-without-ack.
  - Race-free ack: the round-summary responses are acked by the digest captured
    **before** mutating, via a new `review-bus-response-monitor.sh
    --ack-if-digest <resp> <sha256>` that writes the marker from that value
    without re-hashing the file. Closes an ack TOCTOU — a watcher that swaps in a
    fresh same-SHA review between snapshot and ack now yields a different digest
    the marker can't suppress, so its notification still fires.
  - The "HEAD pushed" preflight resolves the remote head the same way
    `review-bus-request.sh` does — `origin/$BRANCH`, then the actual upstream ref
    — so close-round never rejects a branch (upstream ≠ `origin/$BRANCH`) that the
    request gate it forwards to would accept.
  - The pre-mutation response snapshot is tolerant of a junk / mid-write /
    unreadable `resp-*.json`: it obtains both the pr and the digest defensively
    and skips a file that yields neither, so a single bad file can no longer abort
    the whole close-out under `set -euo pipefail`.
  - The clean-checkout preflight now checks the index too (`git diff --cached`),
    not just `git diff HEAD` — a staged change whose worktree copy was reverted to
    HEAD (index ≠ HEAD, worktree = HEAD) is no longer mistaken for clean.
  - `--summary` validates its argument before shifting: a bare `--summary`, or one
    followed by another flag, now errors clearly instead of a cryptic `shift`
    failure (or swallowing the PR number as the summary path).
  - Fails early with a clear message when the repo owner/repo can't be derived
    (missing / non-GitHub `origin`) instead of falling through to confusing `gh`
    errors — pointing at `REVIEW_BUS_OWNER`/`REVIEW_BUS_REPO`.
  - The "HEAD pushed" error now names the actual upstream ref (not always
    `origin/$BRANCH`), matching the upstream fallback used to resolve it; and the
    review-thread pagination breaks unless both `hasNextPage` and a non-empty
    cursor are present (mirrors `review-bus-request.sh`), so a partial payload
    can't loop on an invalid cursor.

## [1.0.8] — 2026-07-18
- Test suite: `test-review-bus-request.sh` — verifies `review-bus-request.sh`
  fails closed (blocks + writes no request) when the unresolved-threads GraphQL
  query fails, plus a happy-path check. Recovers the one unique bit of coverage
  from the retired in-repo legacy smoke test. Suite is now 16 tests.

## [1.0.7] — 2026-07-18
- Default `CODEX_REVIEW_MODEL` is now `gpt-5.6-sol` — the correct Codex model id
  (the earlier `gpt-5.6` attempt was the wrong string and returned a hard 400).
  Verified working via `codex exec`.

## [1.0.6] — 2026-07-18
- Reviewer reasoning effort: `max` is now an accepted value and the default (was
  `xhigh`). Override with `CODEX_REVIEW_REASONING_EFFORT`.
- Model stays `gpt-5.5` — `gpt-5.6` remains unsupported for Codex ChatGPT accounts
  (verified: hard 400).

## [1.0.5] — 2026-07-18
- Revert default `CODEX_REVIEW_MODEL` back to `gpt-5.5`. `gpt-5.6` is **not
  supported** for Codex on a ChatGPT account (the reviewer returns a hard
  `400 invalid_request_error`), which fails every review. Set a valid model via
  the `CODEX_REVIEW_MODEL` env var if you need a different one.

## [1.0.4] — 2026-07-18
- Test suite: ported 7 more daemon/behavior tests (busdir, clone, health,
  launch-context, prompt, systemd, worktree) — the plugin now carries 15 tests.
- `review-bus-codex-start.sh` accepts `REVIEW_BUS_WATCHER` / `REVIEW_BUS_MONITOR`
  overrides (default = the bundled siblings) so tests can inject a stub daemon.
  No runtime behavior change — the defaults are unchanged.

## [1.0.3] — 2026-07-18
- Default `CODEX_REVIEW_MODEL` set to `gpt-5.6` (was `gpt-5.5`). *(Reverted in
  1.0.5 — gpt-5.6 is unsupported for Codex ChatGPT accounts.)*

## [1.0.2] — 2026-07-18
- Auto-arm: a shared `hooks/hooks.json` SessionStart hook (both tools) runs
  `hooks/session-start.sh`, which — only in repos that opt in via a committed
  `.review-bus.md` — ensures the daemons are up (detached) and injects a prompt to
  attach the session's review monitor. Quiet in every other repo; always exits 0.
- `.codex-plugin/plugin.json` declares `"hooks": "./hooks/hooks.json"` (Codex
  bundled-hook discovery belt-and-suspenders).
- `test-review-bus-hook.sh` covers the hook's opt-in gating + fail-safe exit.

## [1.0.1] — 2026-07-18
- `RB_SCRIPTS` falls back to locating the installed plugin in either tool's cache
  when `$CLAUDE_PLUGIN_ROOT` isn't populated in skill bash (some Codex builds only
  set it for hook commands).
- README: correct the Codex install command (`codex plugin add
  watch-pr-skill@p5ych0-tools`; build-dependent).

## [1.0.0] — 2026-07-18

Initial release: a dual-tool (Claude Code + Codex) installable review-bus plugin.

- Bundles the `watch-prs` skill + the review-bus scripts (`review-bus-codex-start`,
  `review-bus-codex-watcher`, `review-bus-request`, `review-bus-response-monitor`,
  `review-bus-copilot`) + the test suite.
- Repo-agnostic: identity is derived from the checkout's `git remote get-url
  origin`, so one user-scope install serves every project.
- Scripts are self-locating (`SCRIPT_DIR` for siblings) and derive the consuming
  project from `git rev-parse --show-toplevel`, so they run from the plugin
  install dir under either tool.
- Optional GitHub Copilot review pass after a clean Codex signoff (opt-in; the
  skill asks first and holds the merge if unanswered).
- Installs as a Claude Code plugin (`${CLAUDE_PLUGIN_ROOT}`) and a Codex plugin
  (same var via Codex's legacy-compat alias).
