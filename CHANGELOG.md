# Changelog

## [1.0.12] — 2026-08-03

- **The Copilot-phase hold now proves the range before trusting it.** The hold
  counted the commits in one `compare` response, which is unsafe twice over: the
  endpoint describes BASE..HEAD, so a force-pushed `diverged` range can return a
  fully tagged list none of which is reachable from the signed-off SHA; and its
  unpaginated list is capped at 250, so a longer range comes back truncated and
  an untagged commit beyond the cap is invisible. It now requires `status` to be
  `ahead`, `total_commits` to equal the returned list length, and every listed
  commit to carry the trailer - otherwise it reviews. (`identical` was accepted
  here at first and is not: this branch is reached only when the signed-off SHA
  differs from the head, so the pair is a contradiction. See the later entry.)
  Marker cleanup is best-effort and logged: an unguarded `rm` failure under
  `set -Eeuo pipefail` would have exited `write_auto_request` and taken the
  watcher down with it.

- **The merge-range check is a script, not inline prose.** It lived in
  `SKILL.md`, where nothing executed it, so two defects survived review: it
  classified intervening commits by a `fix(review):` SUBJECT (any commit can
  carry one, so unrelated work could merge unreviewed), and `git log | grep -c`
  masked a failing `git log` behind a successful `grep` while the commit count
  was checked for text but not exit status. `review-bus-merge-range.sh` now owns
  it — ancestry first, classification by git's own trailer parser, both git calls
  captured and guarded separately, and inspection failures returning 2 so the
  caller fails closed. `test-review-bus-merge-range.sh` covers the subject-only
  commit, a marker-shaped body line, divergent history, and every inspection
  failure.

- **Markers are validated, not repaired.** Both the watcher and
  `review-bus-copilot.sh` read SHA markers with `tr -cd '0-9a-f'`, which
  sanitises corrupt content into something valid-looking: a marker holding
  `x<40-hex>x` became a usable SHA, so damaged state could authorise a phase hold
  or satisfy the merge gate with no signoff, decline, or unavailability ever
  recorded. Each marker must now match `^[0-9a-f]{40}$` exactly, or it is treated
  as absent.

- **The compare response is parsed once, and only trusted when the parse
  succeeds.** Four separate `jq ... || echo ""` substitutions accepted a PARTIAL
  parse as evidence: with valid JSON followed by trailing garbage, jq emits the
  values and then exits non-zero, and the fallback appended only a blank line
  that command substitution strips. The trailer test also matched any line in the
  message, so `subject / Review-Phase: copilot / ordinary body` — which git
  reports as having no trailer — suppressed Codex for an untagged commit. Both
  are fixed: one guarded `jq` whose output is discarded unless it exits zero, and
  a trailer test scoped to the final block of the message.

- **The merge gate classifies by trailer and checks ancestry.** It previously
  accepted any commit whose subject began `fix(review):`, so unrelated work with
  that subject could merge without Codex ever seeing it, and a force-pushed
  divergent range passed the count check. It now requires
  `git merge-base --is-ancestor` and a real `Review-Phase: copilot` trailer on
  every intervening commit, read via `%(trailers:...)` so a mention in a subject
  or body cannot pass.

- **`request` records Copilot unavailability head-scoped.** The documented rc 3
  path was unreachable: the skill says to merge on the Codex signoff when Copilot
  is positively unavailable, but with no review and no decline the gate returned
  1 and the merge always aborted. `request` now records the fact for that head
  and `gate` reports `status=unavailable`; a later push re-opens the question.

- **Codex no longer re-reviews during the Copilot pass.** `SKILL.md` already
  said Codex is not re-run on Copilot-fix commits, but the watcher had no way to
  honour it: auto-enqueue saw each fix commit as a fresh head, so every one burned
  a review, consumed a round against the check-in threshold, and fired a
  notification. A clean signoff now records the signed-off SHA in
  `.codex-clean-<pr>`, and auto-enqueue holds while **every** commit since it
  carries a `Review-Phase: copilot` trailer. The key is a trailer, not a
  commit-subject prefix, because subject-prefix counting already failed here
  (see 1.0.10). Any untagged commit invalidates the phase and is reviewed
  normally, and every uncertainty — unreadable marker, failed compare, empty
  commit list — falls through to a review, since a wrong hold means a commit is
  never reviewed while a wrong review costs one redundant pass.

- **The Copilot pass can no longer be skipped by omission.** It previously
  existed only as `SKILL.md` prose with no bus state behind it, so a session
  could reach merge having never asked — which happened repeatedly downstream.
  `review-bus-copilot.sh` gains `gate <PR>` (0 = clean review on the current head
  or a decline recorded for it, 1 = pass owed, 2 = cannot tell → caller fails
  closed) and `decline <PR>`, and `SKILL.md`'s merge block runs the gate first.
  Declines are scoped to the head they were made for, so a later push re-opens
  the question instead of inheriting the waiver.

- **The clean-signoff response carries `next_phase: "copilot"`,** which the
  response monitor surfaces in its handoff line. A session told only `approved`
  had nothing pointing it at the Copilot pass.

- **The merge is pinned to the head the gates were evaluated against.** Every
  check in the merge block — Copilot gate, head match, reviewed-range,
  unresolved threads, required checks — was a SNAPSHOT, and `gh pr merge` then
  took whatever the head was at execution time. A push landing in that window
  merged unreviewed. The merge now passes `--match-head-commit "$HEAD_OID"`, so
  GitHub rejects a moved head instead of the window merely being narrow, and the
  response is acked only after the merge actually succeeds — acking a rejected
  merge marked the round handled, so it never re-emitted and the PR was silently
  stranded.

- **A head lookup that prints and then fails is a failure.** `pr_head_oid`
  masked `gh pr view`'s exit status with `|| true`, which preserved whatever
  stdout had already been emitted — so a call that printed a plausible SHA
  before erroring was indistinguishable from success. With a matching decline or
  unavailability marker the merge gate returned 0 instead of its documented
  fail-closed 2. The status is now checked, the result must be exactly 40 hex
  characters, and every caller branches on it.

- **A recorded unavailability is revoked when Copilot becomes available.** The
  marker was written on a positively-unavailable request and never cleared, and
  the gate consults it BEFORE live review state. So on a repository that gained
  Copilot mid-loop, a successful retry on the same head left the stale marker in
  place and the very next gate returned `status=unavailable` and merged while the
  pass it had just requested was still running. A successful request now revokes
  it, and failing to revoke fails closed rather than reporting a clean request.

- **Markers are validated whole, not by their first line.** Both marker readers
  truncated at the first newline, so `<valid-sha>\njunk` satisfied the exact-
  contents contract that the phase hold and the merge gate depend on. A
  partially-overwritten or concatenated marker could therefore authorise a hold
  or carry a merge. The whole file must now match `^[0-9a-f]{40}$`.

- **Phase classification uses git's trailer parser, not a last-paragraph
  regex.** `git interpret-trailers` reports NO trailer for a final block that
  mixes prose with a trailer-shaped line, while the regex matched it — so a
  commit git considers untagged suppressed the Codex review it was owed. Trailer
  detection now runs each commit message through `git interpret-trailers
  --parse`, and the compare response is shape-checked in a single guarded `jq`.

- **Shape checks reach the fields that are read.** Three parses validated only
  their outer container. The `compare` parse checked the top-level object, but an
  OBJECT-shaped `.commits` still answers `length` and still iterates under
  `.commits[]`, so `status=ahead` + `total_commits=1` + one trailer-bearing value
  produced `tagged=1` and suppressed Codex on a payload that proved nothing about
  the range; it now requires the array, a numeric count, and a string message on
  every element. Both paginated Copilot readers slurp with `jq -s` into an array
  of PAGES and then flattened with `.[][]`, which over an object iterates its
  VALUES — so a single `{}` page (a 200-with-error body, or a truncated write)
  made the comment count return 0 with a success status, and a genuine
  current-head review plus that page reported `findings=0` and let the merge gate
  answer `status=clean`. Any non-array page now fails closed.

- **Every proof of Copilot's availability revokes the recorded unavailability.**
  The revocation ran only after `gh pr edit` succeeded, but `request` returns
  earlier — rc 4 — when Copilot has already submitted a review on the current
  head. That exit left the marker in place, and the gate reads it *before* live
  review state, so it answered `status=unavailable` (merge) without ever looking
  at that review's findings. Both paths now revoke, and a failed revocation is
  reported as an error rather than a clean result.

- **A live Copilot review outranks any recorded marker.** The merge gate read
  the decline and unavailability markers before consulting live review state, but
  a review can reach a head without `request` ever running - Copilot picking the
  PR up itself, a human re-requesting, an automation - so a marker plus a
  current-head review carrying findings returned "may merge" without that review
  ever being read. The live state is now consulted first and overrides the
  marker, and an unreadable live state blocks instead of falling back on it.
  `request` also stopped recording unavailability when the reviews fetch failed:
  the marker asserts "Copilot has done nothing here" on a question it never got
  an answer to.

- **Zero pages is not zero comments.** `jq -s` turns empty or whitespace-only
  input into an empty array of pages, and `any([]; ...)` is false - so a comments
  fetch that exited 0 emitting no JSON passed the page-shape guard and returned a
  count of 0, which the gate reads as a clean signoff. Both paginated readers now
  require at least one page.

- **The phase hold accepts only `ahead`.** It also accepted `identical`, but the
  branch is reached only when the signed-off SHA differs from the head and the
  hold additionally requires a non-empty commit list - so a truthful compare
  cannot report `identical` there. The pair is a contradiction, and the only
  payloads producing it were malformed ones that then suppressed Codex.

- **The unavailability marker is re-derived, not trusted.** It is the one
  permissive piece of bus state, and it can outlive its truth: if the bus
  directory was briefly unsearchable when a successful request tried to revoke
  it, the request correctly failed closed but the marker survived - and the gate
  later honoured it, merging while the requested review was still pending.
  `[ -e ]` was part of the problem, since it cannot tell an absent marker from a
  failed probe and so reported "nothing to revoke" for a marker that was still
  there. Revocation now attempts the unlink unconditionally and proves the
  result, and the gate checks whether Copilot is currently a requested reviewer
  before honouring the marker - a pending request exists only because the
  request succeeded. An unreadable check fails closed.

- **The merge-range trailer count fails closed.** `|| true` masked every
  non-zero status from the counting pipeline, not only grep's rc 1 for "no
  matches", and command substitution keeps output written before a failure - so
  a counter that printed the expected number and then failed still satisfied
  `TAGGED == TOTAL` and the range was declared Codex-vetted. The status is now
  taken explicitly: 0 is a count, 1 is a real zero, anything else is a failed
  inspection and returns 2.

- **Every input to the Copilot merge gate is validated, not just its
  container.** Three separate reads turned unusable data into merge permission,
  each by looking like an ordinary "nothing here" answer. A successful `[{}]`
  review page passed the array-shape check and produced an empty list, which
  every caller reads as "no live review", so a matching unavailability marker
  carried the merge. The requested-reviewer probe flattened its result to a
  string, collapsing a missing field, a null, an object and a zero-output call
  all into `""` = "no request pending" - again handing the stale marker its
  permission. And a current-head PENDING draft, which `head_review_findings`
  deliberately ignores because a draft is not a completed review, is decisive for
  the marker question in the other direction: Copilot cannot be drafting a review
  where it is unavailable, and the draft can arrive with no reviewer request
  listed at all. Review records must now carry the fields their callers read, the
  probe parses raw JSON and requires a well-formed array, and a current-head
  draft revokes the marker and holds the gate.

- **The Copilot gate reads review STATE, not an inline-comment count.** A count
  cannot tell a clean signoff from a review that was dismissed, one that
  requested changes with no inline comments, or a re-review that is still a
  draft - and `head_review_findings` discards PENDING records, so an older clean
  review beside a new same-head draft read as clean and merged while that
  re-review was running. The verdict is now derived from the current-head review
  set: a draft or a dismissed review means the pass is owed, changes-requested
  blocks, and only an accepted submitted review with zero findings is clean.

- **Markers are validated as raw bytes.** Command substitution silently drops
  NUL, so a marker of `<40-hex>\0` arrived at the validator as a clean SHA and
  satisfied the exact-contents contract the merge gate depends on - the same hole
  as the earlier newline truncation, one layer down. The file's size and an
  anchored match on its bytes are checked before any substitution sees them.

- **Two more reads stopped answering "nothing here" when they failed.** The
  review selector masked its own status with `|| true`, so an id printed before a
  failure survived and an empty comments page turned it into `findings=0`; and
  the requested-reviewer validator accepted an empty or whitespace-only login as
  a readable "no request pending", which with a matching marker was merge
  permission. Both fail closed now.

- **The marker path judges review STATE too.** The gate's unmarked path was made
  state-aware, but the branch taken when a decline or unavailability marker
  exists still went straight to a comment count - so on that path an old
  zero-comment review beside a new draft, and zero-comment DISMISSED or
  CHANGES_REQUESTED reviews, still read as clean. Both paths now run the same
  state machine, and any live review revokes the marker on the way.

- **The LATEST submitted review is authoritative.** The state reducer answered
  "reviewed" whenever any accepted record existed anywhere in the list, so an
  old COMMENTED review followed by a later DISMISSED one counted as a signoff -
  and the comment count then came from the dismissed review, which has none. It
  now judges the latest submitted review, with an unsubmitted draft dominating.

- **A dismissed review has a way out.** `status` reduced it to a comment count
  and reported `findings=0` (rc 0), while `request` treated every submitted
  review including DISMISSED as `already_reviewed_head` - so the driver headed
  for a merge the gate refused, and re-running `request` never asked Copilot
  again. Both are state-aware: `status` reports it as unusable with a reason, and
  `request` re-requests, while an accepted or changes-requested review is still
  `already_reviewed_head`.

- **The watcher's marker reader validates raw bytes.** It kept the command
  substitution the Copilot helper had already moved away from, so `<sha>\0`
  reached its regex as a clean SHA - and a fully tagged compare then emitted
  `CODEX_AUTO_SKIP` off a corrupt marker, writing no review request at all.

- **The gate's clean answer comes from one snapshot, re-read before it is
  trusted.** `head_review_state` and `head_review_findings` each fetched the
  review list independently, so a review that changed between the two calls let
  the gate judge one snapshot and count another - a COMMENTED read followed by a
  DISMISSED one counted the withdrawn review's zero comments and returned clean.
  `clean_verdict` now derives the state and the authoritative review id from a
  single snapshot, counts that review's comments, and re-reads the snapshot
  before returning clean; if it moved, the count describes a review that is no
  longer authoritative and the gate says so. The gate no longer takes a separate
  state reading either - a second source of truth is how the two diverged.

- **`poll` branches on review state.** It still polled a bare comment count, so
  the moment `request` re-requested a dismissed review the still-submitted
  DISMISSED record made it report `status=commented findings=0` instead of
  waiting for the replacement; the same path misread a zero-comment
  changes-requested review and an older clean review sitting beside a draft. Each
  iteration now judges the state: only an accepted review is counted, a
  changes-requested one is reported as the finished review it is, and a draft or
  a dismissal is waited past.

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
