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
| `skills/watch-prs/scripts/pr-request-review.sh` | The OPENING Codex request: the account of what to look at, posted, and the baseline the watch is given. Two things make it a script rather than the eighteen lines it was in `SKILL.md` § 2. It posts the comment that on the manual path IS the request — the mutation everything after it depends on — and nothing executed those lines. And it was a second, WEAKER copy of `pr-close-round.sh`'s `request_review`, which refuses a body starting a line with a marker the loop honours and a body carrying a mention it did not write; this one refused neither, so the one posting site whose body is written from scratch rather than assembled from a round's findings was the one with no rules. Both rules come from `recordlib.sh`, which is where a rule with three callers belongs. The trigger check is the AUTOMATIC path's alone: there a pass is already queued and a quoted `@codex review` queues a second over the same head, which is the duplicate the branch exists to prevent, while on the manual path this script writes the mention itself and a quoted one changes nothing. The mode is refused by name rather than tested for truthiness — the two wrong answers are a duplicate pass and a review nobody asked for, and neither is a branch an unrecognised value may fall into. The body comes in on STDIN, not in a file the driver wrote first: writing one meant `cat > "$FILE" <<EOF` in `SKILL.md`, whose bash runs in the operator's own shell where `cat` is a NAME — a function by that name receives the heredoc and writes what it likes to the redirection, so the account validated and posted would be the function's text, and one that writes nothing and succeeds stops a request that was fine. Nor from a heredoc in the driver, which was the first answer: a heredoc splices the account into shell source, so an account containing a line that is exactly the delimiter ENDS it and whatever follows is parsed by that long-lived shell — and `EOF` is a line this loop's own accounts quote, out of a diff or a finding, while a rarer delimiter narrows it without closing it because the body is not known when the delimiter is chosen. The driver writes the file with its own file tool, which goes through no shell, and redirects it in — a redirection the parser handles, with no name in it to take — and into a file of its OWN rather than the round-summary one, since a first round whose summary write did not happen would otherwise find the opening account there, non-empty and well-formed, and post it as the round summary. The three working files are derived from ONE directory, built by expansion and created with `mkdir` as the exclusion — the answer the transport directory already gives: three `mktemp` calls were three separate answers, and a function by that name returning the same existing empty path each time passes every validation and leaves all three ALIASED, which is that same regression by another route. Nothing on the driver's side is an assignment either: the helper runs as a plain condition with its output redirected to a file, because a capture written as `PRIOR_REVIEW="$(…)"` is an assignment, and a name a startup file has already made readonly makes it fail — which abandons the `if` with NEITHER branch running, so a refused request falls through into the wait. `pr-origin.sh` settled the same question the same way: a path rather than a name. An EMPTY baseline is an answer on both paths — on the manual one Codex has usually not reviewed the head yet, which is the ordinary first request — so what the driver refuses is a value that is not a review id, against a LITERAL pattern rather than one held in a second seedable name. The old three-argument form is refused rather than ignored, since a caller still passing a path would have it dropped while the body came from whatever stdin happened to be. The baseline is EMPTY on the automatic path and not looked up at all: `--after-review` means "newer than this one", and the trigger preceded the loop, so a lookup can capture the very pass being waited for and the watch would then reject the only terminal review as stale. It comes back on stdout ALONE with every reason on stderr, and is written BEFORE the post with the write's status taken: `printf` can fail on a full filesystem, and an `exit 0` after it masks that, leaving the driver to read a truncated value as the baseline — taking the status only works while there is something left to refuse with, and after the post there is not. Writing first costs nothing because the driver reads the file only on success. BOTH baseline shapes travel through: digits for a submitted review, and `comment:<id>` where the newest verdict came through the comment channel, which `pr-watch.sh` accepts and a digits-only test refused after the request had been posted. 0 posted, 1 stopped. #144, under #26. |
| `skills/watch-prs/scripts/pr-review-state.sh` | Whether a named reviewer's review of the current head can carry a merge. EVERY comment counts as a finding, replies included: a verdict followed by explanation and a verdict followed by a retraction are the same text to anything that reads it, so no exemption is safe. A review whose comments are ALL replies reports `source=replies-only` — nothing to fix and not a signoff — and the driver stops for the operator. `clean-at` answers WHETHER the head's verdict is clean and WHEN it landed from ONE snapshot: `record` asked `verdict` and then `review-at`, and a result arriving between them was the one `review-at` timed — so the signoff could carry the time of a verdict nobody proved, and binding them by re-proving afterwards left a clean-to-clean transition pairing the new verdict with the old time. The time comes back from the snapshot that proved the cleanliness, so there is no second question to answer differently. `review-at` was removed with it, as `replies-at` was: it had one consumer and a second, weaker answer to the same question is one a future caller reaches for. #139. `escape-snapshot` is the replies-only escape's whole question in ONE GraphQL response: which review it is, that its comments are all replies, when it landed and when its newest reply did. It exists because the REST endpoints answer reviews and review comments separately, and no ordering of separate reads makes them one snapshot — with the comments read last a review dismissed afterwards is invisible, with the reviews read last a reply posted afterwards is, and alternating a third time only moves the race. #132 spent five rounds discovering that one layer at a time. A truncated page is unreadable rather than "not that shape": the reviews are the LAST hundred, so an earlier page could hold a draft that dominates. 0 the three values, 1 not that shape, 2 unreadable. #133. `replies-at` was removed with it — it existed for exactly this consumer, and a second, weaker answer to the same question is one a future caller reaches for. |
| `skills/watch-prs/scripts/pr-merge-range.sh` | Whether every commit since the reviewed SHA is a review-fix commit reachable from it. |
| `skills/watch-prs/scripts/pr-findings.sh` | The unresolved findings, paginated and shape-validated, and the body of a blocking review. |
| `skills/watch-prs/scripts/pr-round-count.sh` | How many rounds this PR has had, and whether this is an operator check-in boundary. |
| `skills/watch-prs/scripts/pr-signoff.sh` | Which head a reviewer has signed off clean on, read back from the PR itself. The record is a comment, so it survives the session that made it. Every record carries `at=` and `id=` before `sha=` — a REVOCATION as well as a signoff, because a caller has to ORDER one against a verdict: the fault-tolerance pass posts its revocation before requesting the review, so that record is newest when the clean verdict arrives and the pass is answering it, while one posted after a verdict cancels it. Omitting `at=` on a revocation also made two of them compare equal. The id is there because `createdAt` is second-resolution. The field order is not cosmetic: callers read the sha with `${line##*sha=}`, so anything appended after it is swallowed into the value. #117. `verdict-at=` is a THIRD backticked field on the marker and the first field of the record, saying WHICH verdict a signoff answers: readers take the last record, so a revocation posted after a signoff supersedes it whatever it was about, and the writer cannot close that window because its own write erases the evidence. Carrying the verdict time lets a reader order a revocation against THAT rather than against comment order. It is OPTIONAL — every record written before it would otherwise read as malformed — and reported as `none` where absent, so the record has one shape rather than two; a value that is present and is not a time is `status=error reason=bad_verdict_at`, because a reader ordering against it would place a revocation somewhere arbitrary. A revocation carries it in the SECOND backticked field, having no sha. `pr-copilot-phase.sh record` writes it, and its ABSENCE never stops the record: the time is asked for on every path now, but the field is optional, so an unreadable probe degrades to a record without one — a signoff that cannot be ordered against a revocation is the state that existed before, while a phase that cannot close because a probe failed is worse. With a revocation standing it is a different question and the ordering arm still refuses. And the reader ORDERS BY IT: a signoff stands only if no revocation is newer than the verdict it answers. Position alone says the last record wins, which is why a revocation landing while `record` was proving is superseded by the signoff written next — the writer cannot close that window, because its own write erases the evidence. EQUAL IS NOT OLDER: `created_at` is second-resolution and the two records come from different resources, so falling back to position there would give "the signoff stands", which is the fail-OPEN answer the rule exists to stop — a revocation in the same second as the verdict reopens the phase, as `record` refuses to write over one. Where there is nothing to compare, position decides and that is today's rule unchanged: a signoff carrying `none` has no verdict to order against, and a revocation whose own time cannot be read cannot be placed. No pull request in flight changes meaning, because none of their signoffs carries the field. Where the revocation wins, the record printed is ITS time and ITS id. #135, #137 and #140, closing #122. |
| `skills/watch-prs/scripts/pr-ci-state.sh` | Whether the pushed head's checks are green, still running, failing, or absent. |
| `skills/watch-prs/scripts/pr-ci-gate.sh` | Waits until those checks have settled on the head just pushed, and says whether the round may close. Was a function in `SKILL.md`, where nothing could test it — see #26. |
| `skills/watch-prs/scripts/pr-close-round.sh` | Closes a review round in two stages with the thread replies between them. Both push sites prove the checkout is on the PR's branch first — `git push` with no argument sends whatever branch you are on, and this stage is given a PR number, not a branch. It pushed `main` once, from a checkout that had stayed there because a `git checkout` failed, putting an unreviewed commit on the default branch and losing the round besides. A detached HEAD is refused too. #119. The stages: `gate` pushes and proves the head green, `post` re-proves that head, posts the summary and requests the next pass. Both orderings — the mention as trigger, and the push as trigger — in one place. 0 gated/closed, 1 stopped, 3 paused. Was 247 lines in `SKILL.md` — see #26. |
| `skills/watch-prs/scripts/pr-copilot-phase.sh` | The Copilot phase end to end, in three stages with the operator's decision between them: `record` proves Codex clean on an exact head, proves that head's checks, re-proves the head and, through `clean-at`, the live verdict IMMEDIATELY BEFORE writing — the CI gate waits, so a push or a dismissal can land between the first proof and the post, and either stops the record with nothing published — reads the head once more, since the verdict lookup is itself a network call, and writes the signoff onto the PR, then stops and asks. A REVOCATION landing in that window is refused by ORDER, not by presence: the phase is reopened when the newest revocation is LATER than the verdict being signed off, and only then. Earlier means the fault-tolerance pass is ANSWERING it — that pass posts its revocation before requesting the review, so an unconditional refusal stopped a reopened phase recording its replacement signoff at all. Both timestamps are canonical UTC, so the string order is the time order; equal is a refusal, because `created_at` is second-resolution and the two records come from different resources, so their ids cannot break the tie. A time missing or of another shape on either side is a refusal too — these are compared as strings, and a value that sorts low reads as "the revocation is older", which is the answer that records over a reopening. The record COMPARED is read after the verdict's time, not before it: the first read is only the trigger for whether an ordering question exists at all, and asking once and then fetching the time re-opened the window one level down, since a revocation posted DURING that fetch was ordered as the stale record the first ask saw. A newest record that stopped being a revocation in that window is a refusal too, for the same reason equal times are. That ordering proof is the LAST thing before the write, ahead of the head re-read, because the two residues differ: a head that moves after its proof is caught by `open`, which refuses a head that is not the recorded sha, while a revocation landing after its proof is destroyed by the signoff posted next and no later stage can find it — the unrecoverable one goes last. What remained after that — a revocation landing between the last proof and the write, which this stage's own post erases — is closed on the READER's side, not here: `pr-signoff.sh` orders a revocation against the verdict a signoff answers, which the signoff now carries. This stage still refuses on the pre-write ordering, because a refusal costs a rerun and a record costs a reopened phase, but it is no longer the only thing standing between the two. #122, closed by #140. #115, on #117's records; `open` runs only on the answer, and proves the phase is STILL open before it touches anything: the head is unmoved, Codex's live verdict on that sha is clean, and the recorded Codex signoff still names it — a revocation is how a phase is deliberately reopened, and GitHub serves the old clean verdict until the new pass reports. It re-enforces the round boundary too, because `record` publishes the signoff before pausing and a later session can resume straight into here; that is why `open` can return 3. All of it runs THREE times — up front, before the revocation, and again after it — because none of these need the head to move and the revocation is itself a mutation with the request still to come. The order is revoke, prove, baseline, request: the proof as late as it can be while the Copilot baseline stays last, which it must be or a pass landing meanwhile answers a request made after it. `close` is the other end: Copilot's verdict came back clean, so the second signoff is written down and the operator is asked what to do with two closed phases. It takes the Codex head as well as reading the current one, because whether those two shas are EQUAL is what decides which question gets asked — the fault-tolerance pass is offered only where the phase produced commits. It takes the reviewers mode too, since `codex-only` means no Copilot review was ever requested and there is nothing to record; saying so is not the same as skipping it. 0 recorded/opened/closed, 1 stopped, 3 paused. Every guard in it is a reserved-word test, not `[`: the stage dispatch decides which of three mutations runs, and the head-equality and verdict-status proofs decide whether a signoff is recorded at all — see #81. Was 176 lines in `SKILL.md`, and `close` a further 93 whose aborts all exited 0 — see #26, #78. |
| `skills/watch-prs/scripts/pr-merge-gate.sh` | Every merge gate, evaluated immediately before merging and pinned to the head it checked. Takes a reviewers mode: `both`, or `codex-only` which requires the head to BE the reviewed commit. 0 merged, 1 blocked, 3 paused for the operator, 4 queued — a merge queue takes the request without landing it, and `gh` calls that success. Was 291 lines in `SKILL.md` — see #26. |
| `skills/watch-prs/scripts/pr-watch.sh` | Blocks until a reviewer's verdict on the current head is actionable. 0 verdict in hand, 1 timed out, 2 unreadable, **4 the review carried only replies** — nothing to fix and no signoff, so the driver stops for the operator. That one has its own status because every caller branches on status: saying it in the record alone left `pr-close-round.sh` taking the 0 and closing the round. |
| `skills/watch-prs/scripts/pr-origin.sh` | The session's repository, read where the driving shell's names cannot reach. `read` writes origin's URL into a DIRECTORY the caller names and this helper creates. IT TAKES ONE DIRECTORY, and an optional SECOND was added in #174 and removed again in #177: it carried the same distinction the STATUS now carries, and carried it in the one shape the driver cannot use — a single call whose result the driver must then GUESS between two candidates. #176 built three authentications of that guess and had all three refuted, the last by alternating an entry between a directory and a symlink across two sequential probes. A status read by a branch OUTSIDE the arm holding the read-back is the other shape that does not work, being the walked-past-guard form #155 and #158 removed. The driver retries with a SECOND CALL, which names the directory in each arm and reads the FIRST call's status in the second's own condition — `elif [[ $? -eq 2 ]] && …`, inside the same `if`, so nothing becomes a statement after a guard. Leaving the unused interface here was worse than removing it: an installed helper whose contract promises a distinction nothing consumes. `pin` writes `REVIEW_BUS_REMOTE` as a child process sees it into the same, under its own leaf. Nothing goes to stdout and every reason goes to stderr, so a caller reads one stream and never sees the other — which is what lets the value be read with `$(<"$path")` whatever the shell is tracing. It exists because `SKILL.md`'s setup needed `git` and `bash -c`, and both are NAMES: a function answering only `remote get-url origin` forges the identity every stage is addressed by, and a function called `bash` runs in a shell copy that inherits NON-exported variables, so it agrees the pin arrived while the real helpers inherit nothing. Invoked as `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh read "$RB_ORIGIN_DIR"`, with the value read back from `"$RB_ORIGIN_DIR/origin"` — and again on `"$RB_ORIGIN_DIR2"` in an `elif` where the first was refused, which is how a `TMPDIR` that cannot hold a directory stops ending the session. TWO CALLS RATHER THAN ONE TAKING BOTH: the helper cannot tell the driver which of two candidates it used without a status branch outside the arm holding the read-back or a line on the value's own channel, so one call would leave the driver GUESSING from a name that is public in argv — a check-then-use that #176 built three defences for and had all three refuted (the leaf existing, `-O` on the leaf descriptor, `[[ ! -L ]] && [[ -d ]] && [[ -O ]]` on the directory). An `elif` reads that call's status in its own condition — inside the same `if`, so nothing becomes a statement after a guard — and each arm names the directory the helper just created. The read-back is written TWICE, which is the price: a function would hold it once and cannot be used, because `return` is a name and `readonly -f` defeats the driver's own definition. THE PARENT THAT WORKED BECOMES PRIMARY in both retry arms, because `RB_TMPPARENT` is what the pin probe and the working directory are built from — a retry that read the origin from `HOME` and left it on `TMPDIR` then died allocating the working directory under the same full filesystem. #161. It MITIGATES #160 rather than closing it: a squatter on the argv-published first name costs a retry rather than a session, but an account watching argv continuously can pre-create the second name as well, and both parents naming one shared sticky directory is a configuration the selection allows. **THE RETRY IS GATED ON THE HELPER'S STATUS, which is what lets it exist at all.** `pr-origin.sh` reports 2 where both ancestry walks passed and the STORAGE would not take what it asked — the directory could not be created exclusively, or the leaf inside it could not be written, which is the same failure one step later — and 1 where the refusal was about the PATH or the checkout. Only a 2 is retried; a 1 is terminal, because another parent fixes none of those and an operator has to see the state named. `elif [[ $? -eq 2 ]] && helper …; then` IS NOT A BRANCH OUTSIDE THE ARM, which is the objection this shape was almost rejected on: `$?` after a failed `if` condition is that command's status, `[[` is a reserved word nothing can shadow, and the read-back stays contained in the `elif`'s own success arm — so nothing is a statement after a guard, which is the shape #155 and #158 removed. `$?` is taken FIRST in the condition, because a command between would replace it. Codex raised the missing distinction four times before that shape appeared; the intermediate answer — recording it as an accepted limit on the base ref — was wrong, and #180 was closed for it. — a path rather than a name, because `bash -p …` alone is a name a function can take. The caller SPELLS the leaf rather than holding it in a second name: `RB_ORIGIN_OUT` used to, and a name carrying a path can be stale, since its assignment is abandoned whenever the directory is missing and a value the operator's shell already had then survives into the read and the removals. #151. **The DIRECTORY is the argument, and this helper makes it.** It was a file path the driver had already created, which meant `SKILL.md` chose a parent, built a candidate, prefix-checked it, ran `mkdir`, derived the leaf and removed both — thirty-five lines of defence in the one shell nothing can harden, over names an operator's startup file can make readonly or transforming. Here the ancestor walk, the `mkdir -m 700` exclusion and the write all run privileged, where `mkdir` is not a name anything can shadow; the driver's part is the name it hands over and the descriptor it reads back. The exclusion is what makes an existing directory, file or symlink at that name a REFUSAL rather than something written through. And the directory is given back by ONE cleanup body with THREE ways in, each of which runs it at most once: an ordinary refusal and any other abnormal end reach it through an `EXIT` trap, a SIGNAL reaches it directly from its own handler and then re-raises — going through `EXIT` there would mean handling the signal by returning, which is what made the helper resume the work it was killed during — and a SUCCESSFUL run reaches it not at all, resetting `EXIT` and leaving the directory for the caller, which is the point of the call. The trap is armed BEFORE the reservation is attempted — `mkdir` is an external command, and armed after it returned a signal while the child ran left this shell dead and that child creating the directory. What makes arming first safe rather than merely earlier is TWO recorded facts and an ownership test, and each covers what the others cannot: `RB_OWNED` is set after a successful `mkdir` and is certain but late — measured, a signal delivered while that external command runs is handled once it RETURNS and before the `&&` after it; `RB_PREEXISTED` is a `[[ -e ]]` taken before the traps are armed, so a directory at a name that held nothing when this run began is one this run made; and `-O` refuses a name another ACCOUNT holds. Both flags are inferences rather than a handoff, and #162 carries the protocol change that removes them. The refusals only say why and stop — cleaning up in them as well meant a refusal cleaned and then `exit` fired the trap and cleaned again, and the second pass is the dangerous one, because an account watching the published path can recreate it as a symlink between the two and a second `rm -f` follows the replacement. `RB_PHASE` picks the shape: `rmdir` ALONE while no leaf can exist — it refuses a symlink outright, which is what makes it safe on a name the ancestry walks have not approved — and leaf-then-directory once a write has happened, since `rmdir` necessarily fails on a directory holding its leaf. The phase flips after the walks, which is where the name becomes trusted and is still before either write, so the leaf-removing shape never runs on an unapproved path. Every trap is IGNORED — `trap ''`, not `trap -` — before the first removal, in one statement, on both exit paths. `trap -` restores the DEFAULT action, which for `HUP`, `INT` and `TERM` is to terminate: it stops re-entry and makes the cleanup interruptible instead, so a second signal between the `rm` and the `rmdir` kills the shell and the caller removes nothing. Ignoring stops both. Doing it after the cleanup rather than before leaves it RE-ENTRANT: a signal arriving while it runs invokes it again, and after the first pass has freed the candidate an account watching a shared parent can put a symlink there before the second `rm -f` resolves it. A signal is the third way out: each handler disarms all four traps, cleans up, and RE-RAISES, because a trap REPLACES a signal's terminating action and one that merely returned left bash resuming the work it was killed during — and, between a successful write and the disarm, returning status 0 for a run somebody killed. The success paths reset `EXIT` alone and leave the signal handlers armed through the final command, since resetting those too left a window where a `TERM` terminated the helper with no cleanup at all. The contract is a directory this helper created, so a refusal or a signal that left it behind would be a leak nothing else would collect: the caller performs no cleanup after a non-zero status, deliberately, because it cannot know who created the path. #157. **Privileged mode is what does the work**: it stops `BASH_ENV` and `ENV` being sourced, stops shell functions being imported from the environment, and makes `SHELLOPTS` ignored — so there is no hook to escape and nothing inherited to clear. It has to be the FIRST interpreter, since entering it from inside a shell that has already run the hook is too late and a hook needs to shadow nothing to use that gap. The value comes back in a file THIS SCRIPT names, inside the directory the caller names — `<dir>/origin` or `<dir>/pin` — read back with `$(<…)`: it travelled on stdout and then on fd 9, and each put it on a stream some caller traces to — and moving `BASH_XTRACEFD` aside instead closed fd 2 when it was restored, since bash closes the descriptor that variable referred to. `pin` is a real child, which is why its answer is the one that matters. Limits, stated in the file: a caller that omits `bash -p` is refused rather than recovered — there is no fallback hop and the file is not executable — and a poisoned `PATH` (#91). See #84. |
| `skills/watch-prs/scripts/pr-phase-state.sh` | Which phase a pull request is in, read back from the records on it rather than from what a session remembers: the two signoffs and the head select which stop is being resumed from, and the record that has to still stand is re-validated — the head must BE the Codex commit before the Copilot phase and the COPILOT one after it, where the head has advanced through Copilot fixes by design. The malformed-sha case is an ARM of that branch rather than a guard before it, so a value of another shape cannot be read as "no Copilot signoff" and send the operator back through a phase that is closed. A `1` from the verdict is TWO answers, and it tells them apart: a dismissal reopens the phase, while a review carrying only replies does not when an operator has recorded a signoff answering it — the escape the merge gate had and this did not (#125). Its clean-verdict re-read validates the RECORD and not only the status, through `recordlib.sh` like the two gates beside it — an rc-0 answer that is empty, or about another PR, reviewer or head, is not permission to continue. 0 readable and standing, 1 stopped, 2 unreadable — and "could not tell" is neither of the first two: read as no signoff it repeats a phase, read as a signoff it skips a review nobody did. Was 112 lines in `SKILL.md` whose aborts all exited 0, so "the phase is not closed" and "this ran correctly" were the same status — see #123, #26. |
| `skills/watch-prs/scripts/pr-selfcheck.sh` | The pre-push check over this plugin's own sources. The one helper NOT started privileged — see § The helpers are started privileged. |
| `skills/watch-prs/scripts/recordlib.sh` | What a well-formed GitHub record is, which lines a reader honours as a control record, and what text requests a review, and what a `PR_REVIEW_STATE` answer is, and what the replies-only escape means — one definition each, sourced by every helper that reads the API or posts a caller-written body. The last of those is `rb_review_record`, which parses the line for a NAMED field and hands the tail back rather than accepting it — what may follow differs per question, and swallowing it centrally would accept any field anyone ever appends — and `rb_review_record_is_about`, which takes the head WHOLE and compares it at the record's own width, so the `${head:0:7}` each caller used to write is gone. A well-formed line is not an answer: a record about another PR, reviewer or head matched the shape perfectly and sent the merge gate down its `none` fallback. #126. The escape is `rb_replies_only_line`, which is the record shape a review carrying ONLY replies has, and `rb_signoff_answers`, which is what "this operator signoff answers that review" means — the signoff must name the head AND be recorded strictly after the review, since one written for an earlier clean review on an unchanged head would otherwise vouch for a later replies-only one nobody read. Equal is a refusal, because `created_at` is second-resolution and this is permission to merge or to close a phase. What it must be newer than is `rb_answer_at`'s answer: the LATER of when the review landed and when the newest reply did, since the verdict is produced by the comments and one added afterwards does not move the review's `submitted_at` — review at T1, signoff at T2, retraction at T3, and ordering against the review alone left `T2 > T1` true. Only the REPLY may be absent, and absent is not zero; both absent is a refusal, a reply time with no review time is unreadable — replies hang off a submitted review and every submitted review has a validated `submitted_at`, so that pair is a contradiction and taking the reply alone hides the later review — and a shape it cannot place is a third status again. The deadline is bound to ONE review, and that binding is the READER's: `pr-review-state.sh escape-snapshot` answers the id and both times together or not at all, so neither caller compares anything. What they do check is the SHAPE of that answer, through `rb_escape_snapshot` — peeled with expansions alone, a two-field line assigns the second value to both times and a non-numeric id is dropped in silence, and the id is what proves the two times describe one review. #129, #133. Neither fetches anything: each caller reads the records with its own error prefix and its own statuses, and what they share is the rule. What a signoff must answer comes from `pr-review-state.sh escape-snapshot`, so neither caller compares anything: the id, the review's time and its newest reply's arrive together or not at all. It lived in `pr-merge-gate.sh` alone while `pr-phase-state.sh` reported the same review as a dismissal and `pr-watch.sh` carried a third copy of the shape. #125. |
| `skills/watch-prs/scripts/clocklib.sh` | What "how much time has passed" means — one clock reader, with the guards a bare read has not got, sourced by `pr-watch.sh` and `pr-ci-gate.sh`. It exists because the gate used `$SECONDS`, a builtin no fixture can reach, so every deadline case in its suite raced real time; `date` is a command, so a fixture owns it. See #66. |
| `skills/watch-prs/scripts/identitylib.sh` | Which repository this checkout is — one definition, sourced by every helper and by `SKILL.md`. |
| `skills/watch-prs/scripts/loadlib.sh` | How a shared library is loaded and proven loaded — clear, take that clear's status, source, and prove the symbol arrived — in one place. The BOOTSTRAP that loads this file cannot use it, and is clear, take the clear's status, define a refusing stub, source: the first load is what verifies it, and the stub is what stops `PATH` answering in its place. |
| `skills/watch-prs/scripts/testlib.sh` | The portable watchdog and the validated scratch directory. Every fixture runs under it, and `pr-ci-state.sh` bounds its `gh` calls with it — so it ships at runtime too, not only in the suite. |
| `skills/watch-prs/scripts/test-*.sh` | The suite. |
| `.claude-plugin/` | Plugin and marketplace manifests. |

Everything else is documentation. **v2 runs no reviewer of its own**: Codex and
Copilot are first-party GitHub apps, so there is no watcher, no response
monitor, no bus directory, and no systemd unit.

## The helpers are started privileged

Every `pr-*.sh` except `pr-selfcheck.sh` and `pr-origin.sh` begins
`#!/usr/bin/env -S bash -p`, and every one of them refuses if `$-` does not
contain `p`.

`pr-origin.sh` is the narrower of the two exceptions: it is **not executable**,
so a shebang is inert — nothing can start it but a caller naming an interpreter,
and the documented caller names `/usr/bin/env bash -p`. Giving it a privileged
shebang would state a protection the file does not rely on and cannot enforce.
`test-pr-identity.sh` asserts both halves, so the exception cannot quietly become
an executable entry point.

**This is the answer to a whole class, and it replaces answering it one name at a
time.** An ordinary `#!/usr/bin/env bash` SOURCES `BASH_ENV`, IMPORTS functions
from the environment, and honours an exported `SHELLOPTS` — so every builtin a
helper uses is a name the operator's shell can replace. Found one per review
round before this: `type` said a good library defined nothing; `return` made a
refusing stub succeed; `set` made `set +e` a no-op; `echo` swallowed a structured
sentinel; `exit` made a refusal non-terminal, so a helper announced an abort and
went on to post. Each fix was correct and each introduced the next name.
Privileged mode does none of the three things, so there is nothing to shadow.

- **The suite needs `env -S`; the plugin does not.** The fixtures execute helpers
  directly — hundreds of call sites across twelve files — so they go through the
  shebang, and `pr-selfcheck.sh` cannot pass on an `env` that predates `-S`.
  Routing every fixture invocation through `/usr/bin/env bash -p` was considered
  and refused: it is a mechanical rewrite far larger than the change it would
  serve, on a requirement met by GNU coreutils since 8.30 and by BSD `env`.
  `README.md` states which side of the line a reader is on.
- **The CALLER supplies it — including when the caller is another helper.**
  `SKILL.md` invokes every helper as `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-x.sh`,
  and the gate, the round close, the phase, the merge gate and the watch each call
  other helpers the same way. A nested call reaching one by pathname alone would
  leave the kernel to process its shebang and put the `env -S` requirement back
  through the side door — `test-pr-identity.sh` fails if any helper calls another
  bare, and `test-pr-skill-contract.sh` asserts the driver's eighteen.
- **It cannot be a re-exec from inside.** A `BASH_ENV` hook runs before the
  script's first line; one that prints a forged `PR_X …` line and exits has
  already answered a caller capturing stdout, and no later re-exec takes that
  back.
- **`$-` proves less than it looks, and is a last-resort refusal.** It reports the
  MODE, not how the shell got there: run as `BASH_ENV=hook bash pr-x.sh`, the hook
  is sourced first and can `set -p` and then define `echo` or `exit`, after which
  the test passes on a shell that has already run hostile code. Nothing inside a
  script can detect work done before its first line — so `bash pr-x.sh` is
  UNSUPPORTED rather than defended. Do not add a check that claims otherwise.
- **`pr-selfcheck.sh` is exempt, deliberately.** It is run by a person rather than
  by the driver, and it already re-execs into a clean shell and clears every
  inherited function — the guarantee it makes for the whole suite.
  `test-pr-identity.sh` asserts the exemption as well as the rule, so neither can
  drift silently.
- **A fixture that sources a helper needs `bash -p -c`.** When sourced, `$-` is
  the *caller's* flags, so an unprivileged shell is refused — which is correct,
  because the library half would otherwise run somewhere a hook can reach.
- **What it does NOT cover**: `SKILL.md`'s own bash, which runs in the operator's
  shell and cannot re-exec itself, so the driver keeps every name it has (#102) —
  which is why every refusal that comes from READING the origin is a
  `${RB_REMOTE:?…}` and, in the four abort ARMS, an `echo` second. The pin and the
  working-file refusals below them keep the plain `echo`, and correctly: their
  success arms contain everything that follows, so POSITION is their containment
  and there is nothing after them to walk into. Containment (`exit 1` then `[[ -n "" ]]`) stops an
  arm falling through into the success path; it does not stop an `echo` that
  forges a value and neuters `exit` in the same body, because that one has already
  run. The expansion is the shell refusing to expand, so no command runs and there
  is nothing to shadow — and the ORDER is what makes it work, not the presence of
  the check. Non-interactively the shell ends there; interactively it abandons the
  whole enclosing compound command, which is the same `if` the clear opens, so
  setup stops either way. #178.

  **The three checks AFTER the read-back are the same rule reached another way.**
  They were `|| { echo …; exit 1; }` guards, which have no containment at all — a
  `||` list is a statement, so a returning `exit` lets the next statement run. The
  empty check is now `${RB_REMOTE:?…}` outright, since that fires on exactly the
  state it tested; the multi-line and identity ones CLEAR `RB_REMOTE` with an
  assignment — the parser handles assignments, so nothing can shadow one — and
  expand it after. #181. Their conditions are a separate question from their
  refusals: the multi-line one matches a newline followed by four spaces rather
  than a newline, which is #183. And a poisoned `PATH`.

  **The `PATH` one is settled rather than open.** Privileged startup stops
  `BASH_ENV`, stops imported functions and ignores `SHELLOPTS`. It does not
  sanitise `PATH`, and nothing here can: `command -p` searches a default path
  guaranteed to hold the STANDARD utilities and neither `git` nor `gh` is one; a
  fixed list has to know where the operator's binaries live, which is the question
  `PATH` exists to answer; and "this `PATH` looks wrong" is unknowable, because a
  prepended directory is what a version manager does on every developer machine.
  A hook can prepend a directory and mark `PATH` readonly, so its own shell cannot
  undo it — the attribute does not survive the re-exec but the VALUE does.

  So the loop trusts the `PATH` of the shell it was started from, exactly as it
  trusts that shell not to have run a hook before the first line — and for the
  same reason: nothing inside a process can distinguish the honest version of
  something it inherited. **A `PATH` check in one helper is a defect rather than a
  fix**, because the other eleven would not have it and the narrow guard is the
  shape this file already records having to delete twice. Both reviewer files
  carry it verbatim, so a reviewer raising it against one script has an answer.
  #91.

## Bash conventions

Strict mode is chosen per script category, not applied uniformly. Match the
category; do not "fix" a script into a stricter mode.

| Mode | Scripts | Why |
| --- | --- | --- |
| `set -euo pipefail` | one-shot commands | Abort on the first failed step. |
| `set -uo pipefail` | `pr-review-state.sh`, `pr-merge-range.sh`, `pr-round-count.sh`, `pr-findings.sh`, `pr-watch.sh`, `pr-ci-state.sh`, `pr-ci-gate.sh`, `pr-merge-gate.sh`, `pr-signoff.sh`, `pr-close-round.sh`, `pr-copilot-phase.sh`, `pr-phase-state.sh`, `pr-request-review.sh`, `pr-origin.sh`, `pr-selfcheck.sh` | **`-e` is forbidden here.** Subcommands use exit codes as control flow and several `gh` probes "fail" as normal operation; `pr-selfcheck.sh` is in this row because a `grep` that matches nothing exits 1 as its normal answer. |

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

  **`:` is one of those names**, which is why `${VAR:?…}` is carried by an
  assignment and never by `: "${VAR:?…}"`. The refusal path is safe either way —
  the expansion fires and no command runs — and the SUCCESS path invokes `:` with
  the value as its argument, on every ordinary run. A function by that name then
  replaces the value after every check has passed it. Measured; #181.
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
- **An assignment's status cannot be taken.** Measured on bash 5: a failed
  readonly assignment written as `VAR=value || { abort; }` does not fire the `||`
  — it prints its complaint and the list reports SUCCESS, with the variable
  keeping its old value. So the form that looks like it takes the status is the
  one case where there is no status to take, and the guard reads correctly while
  catching nothing. Prove an assignment by reading the variable back with `[[`.

  Whether the shell then CONTINUES is a separate question with a surprising
  answer, and it is not the one to build on: the same failure ends the script when
  the assignment shares a line with what follows it (`readonly V=a; V=b; echo`
  exits 1 and never echoes) and does not when they are on separate lines. Neither
  the `||` nor the standalone form is what decides it. Do not write a guard that
  depends on either behaviour; write the postcondition, which holds in every
  case.
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
  lines that load `loadlib.sh` itself are the one thing that cannot use it, and
  they are **clear, take the clear's status, define a refusing stub, source** —
  no `type -t` verification, because the FIRST LOAD is the verification: calling
  an empty `loadlib.sh` leaves the refusing stub the caller defined, calling it
  fails, and the handler on that first call carries `reason=loadlib_empty` so the
  failure is still named. The stub is what makes it true rather than optional — without it
  an undefined `rb_load` is looked up on `PATH`, and an executable by that name
  exiting 0 reports every load successful with nothing cleared and no library
  sourced. The clear is still there because a stale loader is what makes every
  other load look clean. #88. `test-pr-identity.sh` fails if a `pr-*.sh` script
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

  **Both jobs run again**, on every push to `main` and every pull request. A push
  to a branch with no pull request open still produces no check at all, because
  `push` is `main` only.

  They were off together and came back separately. The normal one returned in #167
  once its cost came down; it had never gone red on a correct change. `macos-shell`
  had, three times, each on a fixture requiring the ROUTE bash 5 takes to a
  defence — so #93's first criterion was auditing every fixture against *assert the
  invariant, not the version's route to it*. **That audit was done by running the
  job rather than by reading twenty-two files**: nineteen passed, and the three
  that did not were real defects rather than route artefacts — the portable
  watchdog gave its bounded command no stdin, a global substitution over 330 KB
  does not finish on 3.2.57, and two cases that forbid writing to regular files
  cannot be captured through the watchdog's own regular files. #171 fixed them and
  the job is green.

  It costs about twenty-five minutes a run against the normal job's three, and a
  hang there used to cost six: the job carries `timeout-minutes: 60` and bounds
  each file at ten minutes with the runner's own `timeout`, captured by absolute
  path before the mac-shaped `PATH` removes it. The failure message reports the
  status, the elapsed time and the bound, and classifies none of them: `-k 30`
  makes a file that ignores `TERM` report 137 rather than 124, a fixture may exit
  124 for reasons of its own, and a branch deciding between them in a YAML file is
  logic no fixture can reach.

  **`SKILL.md`'s bash is not covered by any of it**, and that is issue #26 rather
  than an oversight: ~950 lines of executable shell live in a Markdown file, and
  reaching it means parsing Markdown. That was tried and removed — four rounds of
  fence spellings, two of which rejected valid source. The fix is to move the code
  into `.sh` files, where every existing check covers it for free. Until then one
  narrow lift, by anchored `grep` and with no grammar, covers the merge-gate
  condition that made the gap visible.

  **Behavioural differences count too, not only parsing, and this one recurs.**
  Three examples from a single pull request: bash 5 traces a simple command BEFORE
  applying its redirections while bash 3.2.57 applies them first; a hook's `set --`
  reaches a script's positional parameters on bash 5 but not on 3.2.57; and a
  `BASH_ENV` hook can read those parameters as `$2` on bash 5 and cannot on 3.2.57.
  Both times a fixture written from the newer behaviour alone passed locally and
  turned `macos-shell` red on a change that was correct — the second and third
  times *after* this paragraph existed. Attack fixtures are the recurring shape:
  the defence holds on both shells, and only the attack's ROUTE differs.

  So: **assert the invariant, not the version's route to it.** "The forged value
  never comes out" holds on both; "the run refuses" holds on one. Where the two
  genuinely differ, accept either outcome by name and say which happened, rather
  than requiring the one the local shell produces.

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

- **Never pipe a value into a reader that exits early.** `printf … | grep -q` is
  RACY under `set -o pipefail`, which every fixture sets: `grep -q` exits the
  moment it matches, `printf` takes `SIGPIPE` and dies with 141, and `pipefail`
  makes that the pipeline's status — so a line that IS present reads as missing, at
  whatever rate the scheduler decides. Measured at roughly one run in three on one
  file, and it cost three review rounds on `test-pr-skill-contract.sh` before the
  cause was found rather than the symptom.

  Use a herestring: `grep -q PATTERN <<<"$value"` is a redirection, not a pipeline,
  so there is no second process to kill. **Where the value comes from a COMMAND,
  capture it and its status first** — `v="$(producer)" || die` — because the
  pipeline reported a failing producer through `pipefail` and a herestring has
  nothing to report one from: `grep -q X <<<"$(producer)"` discards the status, and
  a producer that emits the marker and then fails leaves the assertion passing on a
  partial read. Empty the value on failure, or the partial read still matches. `case … in` works too where the pattern is
  a glob. Only the EARLY-EXITING readers matter — `grep -c`, `sed` and `awk`
  without an `exit` read to end of input, so their pipelines never signal.

  `pr-selfcheck.sh` gates the `printf`-produced form, because the failure is
  intermittent and a green run proves nothing about the next one. A line carrying
  the spelling as DATA says so with `racy-pipeline-ok`.

  **The gate asks three substring questions of a folded line and parses nothing:**
  does it name `printf`, does it carry a pipe that is not `||`, does it name
  `grep`. It does not ask which options make `grep` quiet, which spelling of
  `printf` this is, or whose pipe it is.

  Everything narrower was tried first. Six rounds went into modelling grep's
  options — an option with an argument, a hyphenated argument, a quoted one, a
  dash-leading operand, `-e` attached to its pattern, `--`, `-qm1`, `--quiet`.
  Dropping the options bought one round: the next found `%b`, an unquoted `$fmt`,
  a quoted assignment value, `2>&1` before the pipe, `/usr/bin/grep`, and
  `myprintf` matching on its suffix. Every one was a fact about SHELL SYNTAX, and
  reading shell syntax out of text needs a shell — which is this file's own
  scanner warning, arrived at a second time.

  The herestring is the fix for `grep -c` and `grep -v` as much as for `grep -q`
  and is never worse, so there is nothing the narrower rule bought. The thirteen
  lines in the tree that read to EOF were converted rather than exempted.

  **The price is over-reporting, and it is paid where it can be seen.** A line
  naming all three where the pipe is not the `printf`'s says `racy-pipeline-ok`;
  there are two in the tree. A false negative would be invisible, and this is not.
  Do not narrow this rule to remove a marker.

  **Any other producer is review's job, and that boundary is deliberate.** `bodies
  | grep -qF …` races identically — every producer does — and generalising the scan
  to "a pipeline whose last stage is `grep -q`" was tried and reverted in one
  round: `|` is not only a pipe. It appears in `||`, in `${x%%|*}`, inside quoted
  `awk` programs and inside `case` patterns, and telling those apart needs a shell
  PARSER. This file already records paying for one of those, and the generalised
  version reported 140 false positives on a tree with no defect in it — a gate
  nobody can push past rather than one that catches anything. #152.

- **A shadowed `type` inside `rb_load` is accepted, not fixed.** The loader
  verifies the symbol it just loaded with `type -t`, and a `type() { return 1; }`
  in the operator's shell turns a good library into `reason=<lib>_empty`. #88
  removed the same call from the ten helpers that wrap the loader, because there
  the check had somewhere to go: a refusing stub, and a first load whose failure
  is the verification. That does not transfer: asking whether a name is a function
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

**A comment-only change to an installed script IS a release**, and that is the
one case the two sentences above pull in opposite directions on. Two required
reviewers reached opposite verdicts on the same file in #97 — Codex reading "a
change to what is installed", Copilot reading "a change nobody can observe" — so
the rule now says which wins, and why.

The installed bytes are what decides it. A comment in a shipped script is not
decoration here: this file records that *a comment that argues against the code
beside it is an instruction, and it will be followed*, and the helpers are
commented as arguments for why the code has the shape it has. A user who diffs
their installed plugin sees a changed file, and every changed installed file must
have a version that names it. "Observable" is also not decidable at review time,
which is what turned #97 into two rounds; "did an installed file change" is.

The entry then has no failure to explain, and it must not invent one. Say what
the comment now records and which misreading it prevents — that is the
user-facing content of a comment-only change, and it is why this case is on the
release side while a faster fixture is not: the fixture changes nothing a user
installs.

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
