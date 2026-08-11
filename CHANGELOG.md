# Changelog

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

  The one item from that issue it does **not** close is `\s` in a `grep` pattern:
  BSD `grep` does not fail on it, it matches a literal `s`, so the suite passes
  and the behaviour is silently wrong. That is recorded on the issue and left to
  review.

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
  findings** (p5ych0/strumok#212). `process_review` read `.summary` from the
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
