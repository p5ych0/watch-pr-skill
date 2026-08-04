# Changelog

## [1.0.14] — 2026-08-04

- **The driver can read the reviewer's note.** 1.0.12 preserved the note in the
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
  failed emit releases its marker so a later sweep retries rather than treating
  the response as delivered. On the `--note` side the unguarded hash took the
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
