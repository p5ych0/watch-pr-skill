#!/usr/bin/env -S bash -p
# The Copilot phase, end to end: record what Codex signed off, and — if the
# operator asks for it — open the Copilot pass on that same head, then close it on
# Copilot's own clean verdict.
#
#   pr-copilot-phase.sh record <pr> <body-file> <sha-file>
#   pr-copilot-phase.sh open   <pr> <codex-sha> <baseline-file>
#   pr-copilot-phase.sh close  <pr> <codex-sha> [both|codex-only]
#
#   0  recorded / opened / closed
#   1  stopped  — the reason is on stdout; the phase did NOT advance
#   3  paused   — a round boundary. NOT a refusal: the operator decides
#
# WHY SEPARATE STAGES
#
# Each boundary between them is a decision that is not the loop's to make. `record` proves Codex
# clean on an exact head, proves that head's checks, posts the account of the
# phase and writes the signoff onto the PR; then it STOPS and asks. Merging on one
# reviewer's signoff is a legitimate answer, and every Copilot pass costs a round
# of somebody's attention — so the loop must not drift into the second phase just
# because it was pointed that way.
#
# `open` runs only on the answer "open the Copilot phase". It is a separate
# invocation because the operator's answer can arrive in a different session:
# `record` puts the signoff on the PR precisely so a later session can read it
# back with `pr-signoff.sh` and pass the sha here.
#
# `close` is the same shape at the other end: Copilot's verdict came back clean,
# so the second signoff is written down and the operator is asked what to do with
# two closed phases. It takes the Codex head as well as reading the current one,
# because whether those two shas are EQUAL is what decides which question gets
# asked — the fault-tolerance pass is offered only where the phase produced
# commits. It also takes the reviewers mode, since `codex-only` means no Copilot
# review was ever requested and there is nothing here to record.
#
# WHAT THE CALLER WRITES AND WHAT THIS WRITES
#
# The body file is the model's paragraph about the change and what the Codex phase
# did with it. Everything a machine can be held to — the signoff marker, the sha,
# the trailer note — is composed here, because those are the parts something later
# reads back and none of them can be left to prose. The marker's format is the one
# `pr-signoff.sh` scans for: the name and the sha in backticks, on a line of their
# own, anchored at both ends when read.
#
# `set -uo pipefail`, NOT `-e`: every probe here reports its answer as an exit
# status and several fail as ordinary operation. See CLAUDE.md § Bash conventions.
# ── STARTED PRIVILEGED, OR NOT STARTED ─────────────────────────────────────
#
# The shebang above is `env -S bash -p`, and that is the defence this block
# exists to state. An ordinary `#!/usr/bin/env bash` SOURCES `BASH_ENV`, IMPORTS
# functions from the environment, and honours an exported `SHELLOPTS` — so every
# builtin this script uses is a name the operator's shell can replace, and each
# one found took a review round of its own: `type`, `return`, `set`, `echo`,
# `exit`. Privileged mode does none of the three, so there is nothing to shadow
# and nothing to clear. Measured: under `BASH_FUNC_echo%` and `BASH_FUNC_set%`,
# a privileged shell reports both as builtins.
#
# THE HOOK CANNOT BE OUT-RUN FROM IN HERE, which is why this is the shebang and
# not a re-exec. A `BASH_ENV` hook runs before this file's first line, and one
# that prints a forged `ABORT:` line and exits has already answered the
# caller — no later re-exec takes that back. The interpreter has to be privileged
# from the start, which only the shebang or the caller can arrange.
#
# WHAT STARTS IT PRIVILEGED IS THE CALLER, AND THE SHEBANG IS THE FALLBACK.
# `SKILL.md` invokes every helper as `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-x.sh`,
# which starts a fresh privileged interpreter whatever the driving shell is and
# whatever that platform's `env` supports. The shebang covers the other way in —
# executing the file directly — and needs `env -S`, which is why it is not the
# thing relied on.
#
# `$-` IS A LAST-RESORT REFUSAL AND PROVES LESS THAN IT LOOKS. It reports the
# MODE this shell is in, not how it got there: run as `BASH_ENV=hook bash
# pr-x.sh`, the hook is sourced BEFORE this line and can itself run `set -p` and
# then define `echo` or `exit`, after which `$-` contains `p` and this test
# passes on a shell that has already executed hostile code. Nothing inside a
# script can detect work done before its first line — so this catches the honest
# mistake, and `bash pr-x.sh` is UNSUPPORTED rather than defended. Measured:
# `BASH_ENV=/tmp/h bash -c 'printf "%s %s" "$-" "$(type -t echo)"'` with a hook
# running `set -p; echo() { :; }` prints `hpBc function`.
if [[ $- != *p* ]]; then
    echo "ABORT: reason=not_privileged"
    exit 1
fi

set -uo pipefail

# ── `record` CLEARS NOTHING; `open` KEEPS THE BOUNDED CLEARING AND NOT THIS ONE ─
# `open` had two clearings, and the reader they were written for IS real: with the driver's
# `exit` shadowed to return, a refusal falls past its fence into the wait step, which hands
# `$PRIOR_FILE` to `pr-watch.sh --after-review-file`. That is what makes `open` different
# from `record`, and it is why its clearings outlived `record`'s by one change.
#
# ONLY THE ONE ABOVE THE BOOTSTRAP IS GONE — the arm this comment used to introduce. The
# bounded one below survives, and its argument is beside it rather than here: five review
# rounds went into restating this in four files, and every round one of the copies had
# drifted. `skills/watch-prs/SKILL-RATIONALE.md` carries the whole account under
# **THE FILE WAS EMPTIED TWICE AND IS NOW WRITTEN ONCE BEFORE THE CAPTURE**; what is here is
# THIS arm did.
#
# AND NOT THE SYMLINK. The surviving clearing opens this path with `>`, so a symlink a
# same-UID process leaves at that name still has its target truncated — removing the
# clearing would not change that, since the WRITE beside it opens the same name the same
# way. Truncating through a path the caller named is what this handoff IS. What comes out
# here is narrower: an open that was UNBOUNDED and stood where nothing could bound it.
#
# EMPTYING WAS NEVER THE PROTECTION. `pr-watch.sh` holds a terminal verdict back on ONE
# condition — the id it finds equals the baseline — and the whole comparison is guarded by
# `[ -n "$AFTER_REVIEW" ]`, so an EMPTY baseline holds nothing back. This arm therefore did
# not prevent the harm its own comment named.
#
# WHAT IT DID COST is a `>` on a caller-named path before the bootstrap, where `run_limited`
# does not exist yet. Its `[[ -f ]]` guard makes the blocking case a CHECK-TO-OPEN RACE: a
# FIFO already at the path was refused by the guard and never opened, and what could block
# is a same-UID process replacing the path between the test and the open. The symlink case
# needs no race, `[[ -f ]]` following one to a regular file the open then truncated. That is
# the whole of #245, and removing the arm removes it.
#
# `record` HAS NO CLEARING, HERE OR ANYWHERE, and #245 is why: it had two and neither
# protected a read that can happen. Its file is read only in the driver's success arm and
# `3` arm, both of which the WRITE has already reached, and every refusal exits 1 into an
# arm that reads nothing. Two unbounded truncating opens were destroying to protect that.
#
# GUARDED, AND ONE STAGE ONLY. `close` takes a sha as an argument and writes no file, so
# truncating a third argument there would destroy whatever the caller named. The path
# must exist, be a regular file and contain a `/` — a bare name is not the driver's
# handoff.
# THE POSITIONS ARE THE PRE-`shift` ONES, which is where this runs: `$1` is the stage,
# `$2` the PR, and after that the stages differ — `record` takes `$3` the body file and
# `$4` the sha file, `open` takes `$3` the codex sha and `$4` the baseline file. Reading
# them as the post-`shift` ones truncated the BODY — caught at once by the fixture, and
# worth naming here because the two numberings differ only by this statement's position.
#
# `record` also refuses to truncate its BODY file, whose account this stage is about to
# post and which the alias check below refuses properly. `open` needs no such pairing:
# its `$3` is a sha, not a path.
# `record` HAS NO ARM HERE, AND THAT IS MEASURED RATHER THAN ASSUMED. It had one, for a
# refusal above the later clearing — an unreadable library, a PR number that is not a
# number — on the reasoning that such a refusal would leave the previous run's sha for the
# caller to read as this one's. The driver does not read it there: `$HEAD_FILE` is read in
# the success arm and in the `3` arm, and a bootstrap failure exits 1 into the `*)` arm,
# which reads nothing. With `exit` shadowed to return, execution falls past that fence
# carrying whatever `CODEX_SHA` already held — which after a completed Codex phase is the
# retained sha from step 7, not anything this file wrote — so the stale FILE is not what
# reaches the next stage.
#
# Removing it removes an unbounded truncating open on a caller-named path, which is worth
# more than the depth it was giving: `>` follows a symlink and truncates its target, so an
# arm that cannot be reached by a reader was still able to destroy a file. `record` has NO
# clearing now, here or after the bootstrap — the second one protected nothing either, for
# the same reason — and what makes a stale value impossible is the WRITE: bounded, its
# status taken, and compared in the child. #245.
_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "ABORT: reason=lib_dir_unresolvable"; exit 1; }
unset -f rb_load 2>/dev/null || { echo "ABORT: reason=loadlib_stale_definition"; exit 1; }
# NO `type -t rb_load` PREFLIGHT. It verified the loader by asking `type`, which
# is a NAME — and while a privileged interpreter means no function by that name
# can be imported, verifying a thing by asking a second thing about it is the
# shape #88 is about: the answer is only as good as the asker. The FIRST LOAD is
# the verification instead: the stub below is what an empty `loadlib.sh` leaves
# behind, and calling it fails. Nothing is asked ABOUT the loader — the load
# itself is the answer.
#
# THE REFUSING STUB IS WHAT MAKES THAT TRUE. Without it, an `rb_load` that is not
# a function is looked up on `PATH` — privileged mode does not change `PATH` —
# and an executable by that name exiting 0 would report every load successful
# with nothing cleared and no library sourced. Defining it means the call cannot
# leave this shell: a good `loadlib.sh` replaces the stub when sourced, an empty
# one leaves the refusal. `return` is a builtin and nothing can shadow it here,
# because a privileged shell imports no functions. #88.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || { echo "ABORT: reason=loadlib_unreadable"; exit 1; }
# `2>&1` on each: `rb_load` reports on stderr, and everything this script says is
# documented as stdout — a caller capturing it would otherwise get nothing for the
# failures that happen before anything else can.
# THE FIRST LOAD CARRIES THE SENTINEL, because it is what the preflight used to
# say. An empty `loadlib.sh` leaves the stub, the stub returns 127, and without
# this arm the only trace is a bare exit status — the ordinary-looking empty
# answer `CLAUDE.md` forbids. 127 is the stub's and nothing else's: `rb_load`'s
# own refusals report their own reason and their own status.
# `run_limited` — the portable watchdog, for the baseline WRITES below. Opening a
# path for writing can BLOCK: a FIFO at that name waits for a reader that never
# arrives, and the second write happens after the Copilot-signoff revocation has been
# posted, so a hang there leaves the phase partially advanced with no way to say so.
# A `[[ -f ]]` test before the open does not answer it — the open is what blocks, and
# a check it precedes can be raced by the same-UID process that put the FIFO there.
# `pr-ci-state.sh` loads the same helper for the same reason; stock macOS ships no
# GNU `timeout`, which is why it is shared rather than a one-line wrapper.
rb_load "$_RB_SELF_DIR" testlib run_limited "ABORT:" 2>&1 || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "ABORT: reason=loadlib_empty"
    exit 1; }
rb_load "$_RB_SELF_DIR" recordlib sha_reason "ABORT:" 2>&1 || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "ABORT: reason=loadlib_empty"
    exit 1; }
# AFTER THE FIRST LOAD, DELIBERATELY. The load above carries the `loadlib_empty`
# diagnostic, and it does so because it is FIRST — an inherited or emptied loader is
# named there and nowhere else. Putting this one ahead of it made that report come
# from a bare `|| exit 1`, so the helper refused in silence and
# `test-pr-identity.sh` caught it.
rb_load "$_RB_SELF_DIR" writelib rb_write_handoff "ABORT:" 2>&1 || exit 1
# BOTH CONSTANTS, EACH THROUGH `rb_load`. Verifying only one leaves the other
# inheritable: a `recordlib.sh` truncated after the first definition passes the
# check, and an exported `RB_COPILOT_BOT` from the environment is then accepted as
# library data — so this would sign off, or revoke, under whatever account that
# variable named.
rb_load "$_RB_SELF_DIR" recordlib rb_reserved_marker_line "ABORT:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_review_trigger "ABORT:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "ABORT:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_COPILOT_BOT "ABORT:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" identitylib rb_identity "ABORT:" 2>&1 || exit 1
rb_identity || { echo "ABORT: reason=$RB_IDENTITY_REASON"; exit 1; }

# THE STAGE IS FIRST AND HAS NO DEFAULT. The two halves have an operator decision
# between them, so a caller that gets one when it meant the other has either
# skipped the decision or re-asked a question already answered.
STAGE="${1:-}"
case "$STAGE" in
    record|open|close) ;;
    "") echo "ABORT: a stage is required: 'record' (prove and record the Codex signoff, then ask), 'open' (start the Copilot pass the operator asked for) or 'close' (record Copilot's signoff and ask)"; exit 1 ;;
    *) echo "ABORT: '$STAGE' is not a stage; expected 'record', 'open' or 'close'"; exit 1 ;;
esac
shift

PR="${1:-}"
case "$PR" in
    ""|*[!0-9]*) echo "ABORT: a PR number is required (got '$PR')"; exit 1 ;;
esac

# `[[`, A RESERVED WORD, NOT `[` — HERE AND IN EVERY GUARD BELOW. A function named
# `[` is inheritable through `export -f`, this script does not re-exec, and it
# shadows the builtin and the `command`/`builtin` prefixes alike. The parser
# handles `[[`, so no function can take its place. See CLAUDE.md § Already paid
# for, and § Tests for why this matters in a runtime script and not in a fixture.
#
# THE DISPATCH WAS THE FIRST ONE CONVERTED and the rest followed as #81, because
# the argument does not stop at the dispatch and a list of the ones that had been
# noticed is the shape this repository keeps paying for. What each lying `[` buys:
#
#   the dispatch      a `close` invocation runs `open` — revoking the Copilot
#                     signoff and requesting a pass instead of closing the phase
#   head = CODEX_SHA  a MOVED head reads as unmoved, so the phase opens on a
#                     commit Codex never signed off (twice: the up-front proof
#                     and the re-proof immediately before the mutations)
#   verdict rc        a dismissed or findings verdict reads as clean
#   ROUNDS_RC         the operator round boundary never fires
#
# The middle two are the ones with a merge behind them: a signoff recorded for a
# commit no reviewer saw is what every later gate then trusts.
if [[ $STAGE = open ]]; then
    # ── THE OPERATOR ASKED FOR THE COPILOT PHASE ───────────────────────────
    CODEX_SHA="${2:-}"
    [[ -n $CODEX_SHA ]] \
        || { echo "ABORT: 'open' needs the head Codex signed off, which 'record' reported and pr-signoff.sh reads back."; exit 1; }
    _why="$(sha_reason "$CODEX_SHA")" \
        || { echo "ABORT: the Codex-signed-off head is not a full OID ($_why: '$CODEX_SHA')."; exit 1; }

    # THE BASELINE CROSSES IN A FILE, as the gated head does from `pr-close-round.sh
    # gate` and the signed-off sha from `record`. It used to travel only in the
    # `PR_COPILOT_PHASE_OPENED` record, which meant the driving shell captured this
    # stage's stdout and cut the value out with `${OPEN_REC##* prior-review=}` — a
    # parse, in the one shell nothing can harden, of a line whose field order is
    # this file's to change. The record still carries it for whoever reads the
    # terminal; nothing parses it. #243.
    PRIOR_FILE="${3:-}"
    [[ -n $PRIOR_FILE ]] \
        || { echo "ABORT: a baseline file is required: 'open' writes the review id it captured into it, and pr-watch.sh --after-review-file reads it back."; exit 1; }
    # THIS READINESS WRITE STAYS, AND IT IS NOT WHAT #245 IS ABOUT. #245 is the UNBOUNDED
    # truncating open above the bootstrap, where `run_limited` does not exist yet: its
    # `[[ -f ]]` guard refused a FIFO already at the path, so what could block it was a
    # same-UID process replacing the path between the test and the open — while the symlink
    # half needed no race, `[[ -f ]]` following one to a regular file it then truncated.
    # This one is below the bootstrap and bounded, and it was removed for a round on the
    # argument that emptying buys nothing: the watch holds a verdict back only when the id
    # it reads equals the baseline, and skips the comparison entirely when the baseline is
    # empty, so an empty baseline holds nothing back.
    #
    # THAT ARGUMENT IS TRUE AND IT IS NOT THE WHOLE TRADE. Removing this was a regression,
    # found twice in two rounds, because the clearing is also the READINESS PROOF for the
    # exact operation the write performs, and it stands before ANY mutation this stage makes
    # — it has two, the revocation comment and the reviewer request. Without it a baseline
    # path that cannot take this write — a directory, a FIFO, an unwritable or append-only
    # file — is not found until the write far below, which is AFTER `gh pr comment` has
    # revoked the previous Copilot signoff: the stage then reports that the phase did not
    # open while having mutated the PR.
    #
    # AND NOTHING WEAKER PROVES IT, WHICH IS WHY IT IS THE REAL WRITE. The proof has to be
    # the operation the later write performs, or it answers a different question: since #263
    # that operation is `rb_write_handoff` — a type refusal, an exclusive create in the
    # target's directory, and an exact rename — so this runs it. A path that cannot take
    # that, for whatever reason, is found HERE. This settles more than the truncation it
    # replaced did: the type refusal reaches `/dev/null`, a socket and a FIFO, which the old
    # probe accepted and left to a read-back on the far side of the revocation.
    #
    # IT WRITES A SENTINEL RATHER THAN EMPTYING, and that is what stopped the readiness
    # proof from being a fail-open. Emptying looked free because an empty baseline WAS legal
    # when this was written — it meant "no prior review to wait past", which is a real
    # answer this stage can produce when Copilot has never reviewed. That is exactly why it
    # was dangerous: a refusal between here and the write left a value the watch ACCEPTED,
    # and falling through the driver's shadowed `exit` the watch skipped its equality check
    # and announced `PR_REVIEW_READY` for a review no request was made for.
    #
    # SINCE #264 AN EMPTY BASELINE IS REFUSED and "no prior review" is spelled `none`, so
    # that emptying would now be caught by the watch on its own account. The sentinel stays:
    # a value written on purpose is what a reader can trust, and it names the reason rather
    # than leaving the watch to infer one.
    #
    # A SENTINEL IS NOT A REVIEW ID, so `pr-watch.sh` refuses it — `reason=malformed_review_id`,
    # status 2 — and the driver stops instead of accepting a pass that never happened. The
    # same refusal that used to fail open now fails closed, and the readiness proof still
    # stands ahead of the revocation, so a path that cannot take this write is found before
    # anything is posted. What is NO LONGER an exception is the class that used to be one:
    # `/dev/null`, a socket and a FIFO passed a truncating probe and were caught only by the
    # read-back on the far side of the revocation. `rb_write_handoff` refuses them here, by
    # type, before anything is created. The read-back keeps its own job — proving the bytes
    # that crossed are the bytes asked for — rather than standing in for this one.
    #
    # IT MUST NOT BE EMPTY AND MUST NOT PARSE AS AN ID. Empty is the legal "no floor" value
    # above; digits, or `comment:` and digits, are the two shapes the watch accepts. Anything
    # else is refused, and this is spelled so a reader of the file sees why it is there.
    #
    # AND THE WINDOW IT ONCE NARROWED IS CLOSED FROM BOTH ENDS NOW. This write truncated
    # before it wrote, so a failure between the two — ENOSPC, a quota — left the file empty,
    # which the watch then accepted as "no floor"; the sentinel narrowed that and could not
    # close it, because no shell redirection truncates and writes atomically. #264 made an
    # EMPTY file a refusal rather than a no-floor value, and #263 made the write a RENAME:
    # the value is complete in a temporary before the caller's name refers to it at all, so
    # a failure part-way leaves the previous contents and never a half-written value.
    # WRITTEN THROUGH `rb_write_handoff`, WHICH RENAMES RATHER THAN TRUNCATING — #263. A
    # plain `>` on this path follows a symlink, so a same-UID process that replaced it had
    # the file it pointed at truncated instead.
    # BOUNDED, AND THE BOUND IS NOT ABOUT FIFOs ANY MORE. The temporary is created with
    # `perl`'s `sysopen` and `O_CREAT|O_EXCL`, so an entry already at that name fails
    # instead of being waited on — `set -C` did NOT do that, since bash's noclobber exempts
    # everything but a regular file — but pathname resolution, the write and the rename can
    # all still stall on an unresponsive filesystem, so the watchdog stays, around the
    # library rather than around a raw redirection.
    #
    # THIS ONE IS THE READINESS WRITE AND STANDS BEFORE BOTH MUTATIONS, which is what its
    # bound is for: a hang here costs a stage that did nothing, and the whole point of
    # proving the path this early is that a path which cannot take the write is found before
    # the revocation. The half-open consequence belongs to the BASELINE write further down,
    # which stands after the revocation and before the request — saying it here misplaces
    # the risk and would make this bound look like the important one to keep.
    #
    # RUN IN A CHILD BECAUSE `run_limited` BOUNDS A COMMAND, not a shell function. The
    # child sources the library by absolute path from `$_RB_SELF_DIR`; an emptied library
    # leaves `rb_write_handoff` undefined, the child exits non-zero, and this refuses —
    # which is the same direction `rb_load` fails in, reached without it.
    _rb_wh="$(run_limited 10 /usr/bin/env bash -p -c \
        'rb_write_handoff() { return 127; }; . "$1"/writelib.sh 2>/dev/null || exit 9; rb_write_handoff "$2" "$3"' \
        _ "$_RB_SELF_DIR" "$PRIOR_FILE" refused-no-baseline)" \
        || { echo "ABORT: could not write the baseline file '$PRIOR_FILE'. Nothing has been posted: $_rb_wh"; exit 1; }
    # THE PHASE OPENS ON THE HEAD THAT WAS SIGNED OFF, and the answer can arrive
    # a session later, so this is re-proven rather than assumed. Requesting
    # Copilot while the head has moved past the signoff spends the entire phase
    # on one commit and the merge gate on another, and only the gate finds out.
    # WHETHER THE CODEX PHASE IS STILL OPEN ON THIS COMMIT — one definition, asked
    # TWICE. Every one of these can change while the probes below run without the
    # head moving: another session dismisses the verdict, or posts a Codex
    # revocation to reopen the phase. Checking once at the top proves a state that
    # may not survive to the mutations, so this runs again immediately before them.
    phase_still_open() {
        local head recheck rc record
        head=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
            || { echo "ABORT: could not read the current head; do not open the phase blind."; return 1; }
        _why="$(sha_reason "$head")" \
            || { echo "ABORT: the current head is not a full OID ($_why: '$head')."; return 1; }
        [[ $head = "$CODEX_SHA" ]] \
            || { echo "ABORT: the head is $head, not the $CODEX_SHA Codex signed off; re-run the Codex phase for what is there now."; return 1; }

        # THE VERDICT, because an unchanged head does not mean an unchanged
        # verdict: a review dismissed while the head stood still leaves the
        # equality passing and the recorded signoff describing a phase that is no
        # longer clean.
        recheck=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); rc=$?
        [[ $rc -eq 0 ]] \
            || { echo "ABORT: Codex is no longer clean on $CODEX_SHA ($recheck) — the signoff is history, not a current verdict; do not open the Copilot phase"; return 1; }

        # AND THE RECORDED SIGNOFF, which is the only thing that says the phase was
        # deliberately REOPENED. Reopening posts a revocation and requests a new
        # pass, and GitHub keeps serving the old clean verdict until that pass
        # reports — so the verdict alone still passes on a reopened phase.
        record=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$RB_CODEX_BOT"); rc=$?
        case "$rc" in
            0) ;;
            1) echo "ABORT: there is no current Codex signoff on this PR ($record) — it was revoked or never recorded; do not open the Copilot phase"; return 1 ;;
            *) echo "ABORT: could not read the recorded Codex signoff (rc=$rc)"; return 1 ;;
        esac
        case "$record" in
            *" sha=$CODEX_SHA"*) ;;
            *) echo "ABORT: the recorded Codex signoff is not for $CODEX_SHA ($record); do not open the Copilot phase"; return 1 ;;
        esac
        return 0
    }
    # Once here, so a phase that is already closed costs one round-trip rather than
    # the whole probe sequence.
    phase_still_open || exit 1

    # AND THE BOUNDARY IS ENFORCED AGAIN HERE. `record` publishes the signoff
    # before it pauses, deliberately — so a later session can read that signoff
    # back and arrive here with the boundary still unacknowledged. Checking only in
    # `record` meant the pause was skipped by the very resume path the published
    # signoff exists to enable.
    /usr/bin/env bash -p "$_RB_SELF_DIR"/pr-round-count.sh "$PR" "$RB_CODEX_BOT"; OPEN_ROUNDS_RC=$?
    case "$OPEN_ROUNDS_RC" in
        0) ;;
        3) echo "PAUSE: round boundary reached and not acknowledged. Decide with the operator before opening the Copilot phase: continue, merge on the Codex signoff, leave it open, or close this PR and start over"
           exit 3 ;;
        *) echo "ABORT: could not establish the round count (rc=$OPEN_ROUNDS_RC); nothing revoked or requested"; exit 1 ;;
    esac

    # AND RE-READ ONCE MORE, IMMEDIATELY BEFORE THE MUTATIONS. The probes above
    # take time: a push landing after the equality check but during the verdict or
    # baseline lookup leaves the pinned verdict still clean — it is pinned to the
    # old sha — while the revocation and the request land on the moved PR, and
    # `--add-reviewer` re-requests, so Copilot spends the phase on a head Codex
    # never signed off. The window cannot be closed entirely; it can be made as
    # small as the last check before the call.
    HEAD_STILL=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
        || { echo "ABORT: could not re-confirm the head before opening the phase."; exit 1; }
    _why="$(sha_reason "$HEAD_STILL")" \
        || { echo "ABORT: the re-read head is not a full OID ($_why: '$HEAD_STILL')."; exit 1; }
    [[ $HEAD_STILL = "$CODEX_SHA" ]] \
        || { echo "ABORT: the head moved to $HEAD_STILL while this phase was being proved; nothing was revoked or requested."; exit 1; }

    # …AND SO IS EVERYTHING ELSE THAT CAN CHANGE WITHOUT IT. A dismissal or a Codex
    # revocation posted while the probes above ran leaves the head where it was, so
    # the head check alone would pass and this would revoke Copilot's signoff and
    # request a pass underneath a phase somebody had just reopened.
    phase_still_open || exit 1

    # ANY EXISTING COPILOT SIGNOFF IS REVOKED FIRST. Entering this phase a second
    # time — after a Codex pass that returned clean without moving the head —
    # leaves the previous Copilot signoff naming that same head. Until the new pass
    # reports, GitHub still exposes the old clean verdict, so a resumed or
    # concurrent session takes the post-Copilot path and merges the phase that was
    # just reopened. The revocation is the only record that it WAS reopened.
    #
    # Unconditional: revoking a signoff that does not exist costs one comment, and
    # the branch that decides whether to bother is a branch that can be wrong.
    gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" \
        --body "$(printf '**Review-Signoff-Revoked:** `%s`\n\nOpening a Copilot pass on this head; any earlier Copilot signoff no longer describes it.\n' "$RB_COPILOT_BOT")" \
        || { echo "ABORT: could not revoke the previous Copilot signoff — do not request the pass without it"; exit 1; }

    # AND ONCE MORE, AFTER THE REVOCATION. The check above sits before a mutation
    # and two network calls, so it is not "immediately before the request" — the
    # revocation comment and the baseline lookup are both windows in which Codex's
    # verdict can be dismissed, its signoff revoked, or the head moved. The
    # baseline still has to be read LAST, so this is as close to the request as the
    # two constraints allow.
    phase_still_open || exit 1

    # THE BASELINE IS READ HERE, after the revocation and immediately before the
    # request. Read earlier, a Copilot pass already in flight on this unchanged head
    # could finish during the probes or the revocation — and `pr-watch.sh
    # --after-review` would then accept that pre-request review as the answer to a
    # request made after it, advancing the phase on a pass nobody asked for.
    #
    # Empty is a legitimate answer (no review yet); only a failed read is fatal.
    PRIOR_REVIEW=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh review-id "$PR" "$RB_COPILOT_BOT") \
        || { echo "ABORT: could not read the current review id; do not request a review blind."; exit 1; }

    # WRITTEN BEFORE THE REQUEST, WITH ITS STATUS TAKEN. The write is `rb_write_handoff`,
    # which creates a temporary exclusively, writes into that handle, renames it onto this
    # path and reads the raw bytes back before returning — so a `0` means the value crossed
    # and a non-zero one means this handoff did not happen. After the request there is
    # nothing left to refuse with: the phase would be irreversibly half-opened, with Copilot
    # asked and the caller reading whatever is at that path as the baseline. Writing first
    # costs nothing, because the driver reads the file only when this stage succeeds.
    # BOUNDED FOR THE SAME REASON, and it matters more here: the revocation is already
    # posted, so a hang leaves the phase half-advanced with nothing said about it.
    # THE NO-FLOOR VALUE IS SPELLED `none` — #264, for the reason `pr-request-review.sh`
    # gives: an empty file used to be the legal no-floor value, so a truncation that then
    # failed produced it by accident. Copilot has usually not reviewed this head when the
    # phase opens, so this is the ordinary case rather than an edge one.
    PRIOR_REVIEW="${PRIOR_REVIEW:-none}"
    _rb_wh="$(run_limited 10 /usr/bin/env bash -p -c \
        'rb_write_handoff() { return 127; }; . "$1"/writelib.sh 2>/dev/null || exit 9; rb_write_handoff "$2" "$3"' \
        _ "$_RB_SELF_DIR" "$PRIOR_FILE" "$PRIOR_REVIEW")" \
        || { echo "ABORT: could not write the review baseline to '$PRIOR_FILE'; Copilot has NOT been requested: $_rb_wh"; exit 1; }
    # THIS IS THE WRITE THE HALF-OPEN RISK BELONGS TO. It stands after the revocation and
    # before the request, so a hang here leaves the phase reopened with no pass asked for
    # and no diagnostic — which is why this bound is the one that matters most of the three.
    #
    # THERE IS NO SECOND READ-BACK HERE, AND ITS REMOVAL IS THE POINT. This stage used to
    # re-prove the baseline itself, in a bounded child, on a descriptor — because the write
    # above it was a `printf` that proved nothing. Since #263 the write IS the proof:
    # `rb_write_handoff` reads the target back before it returns and compares the raw bytes
    # INCLUDING the terminator, which is the property #246 built this for — a read failing
    # at the FIFTH byte still returns `none`, and only a comparison on the whole bytes sees
    # it. The library's read is the stronger one besides: `O_NOFOLLOW` refuses a symlink at
    # the open, `O_NONBLOCK` and `fstat` on the handle refuse a FIFO rather than waiting.
    #
    # AND A SECOND PROOF HERE COULD ONLY MAKE THINGS WORSE. This point is past the
    # revocation, so a racer who swaps the path after the library returns turns a proven
    # handoff into a refusal with the phase already reopened — a cost with nothing bought,
    # since the question was answered before the swap. #246's finding was that two
    # read-backs in two shapes let one of them be weaker; one read-back, in the library,
    # is that finding taken to its end.

    # `--add-reviewer` IS the request. If it fails there is no Copilot pass to wait
    # for, so entering the phase would poll for a review nobody asked for and then
    # report a timeout — which reads as "Copilot is slow", not "Copilot was never
    # asked".
    gh pr edit "$PR" --repo "$HOST/$OWNER/$REPO" --add-reviewer @copilot || {
        echo "ABORT: could not request Copilot — do not enter the Copilot phase."
        echo "This is not permission to skip the pass: decide with the operator."
        exit 1; }

    echo "PR_COPILOT_PHASE_OPENED pr=$PR head=$CODEX_SHA prior-review=$PRIOR_REVIEW"
    exit 0
fi

if [[ $STAGE = close ]]; then
    # ── THE OTHER END OF THE PHASE `open` STARTED ──────────────────────────
    #
    # Copilot's verdict came back clean, so the second signoff is written down
    # too and the operator is asked what to do with two clean phases. This was 93
    # lines of `SKILL.md`, where nothing covered it — see #78. The move is what
    # buys it the suite, `pr-selfcheck.sh` and the bash 3.2 job.
    #
    # ITS ABORTS EXIT NON-ZERO. In `SKILL.md` they exited 0, because that block
    # ran in the driver's own shell where a non-zero status would have killed the
    # session — so a failed head read, a malformed sha and a moved head all
    # returned success to anything reading the status. Here the caller branches on
    # it, and every one of them is a stop.
    CODEX_SHA="${2:-}"
    [[ -n $CODEX_SHA ]] \
        || { echo "ABORT: 'close' needs the head Codex signed off, so the record can say whether the two phases closed on the same commit."; exit 1; }
    _why="$(sha_reason "$CODEX_SHA")" \
        || { echo "ABORT: the Codex-signed-off head is not a full OID ($_why: '$CODEX_SHA')."; exit 1; }

    # `codex-only` MEANS THERE IS NOTHING HERE TO DO, and saying so is not the
    # same as doing it. No Copilot review was ever requested, so there is no
    # verdict to re-check and no second signoff to record — and running the rest
    # anyway is how a previous round's fix stayed unreachable: the merge gate had
    # learned the mode while the documented path to it still exited on a Copilot
    # recheck that could not pass.
    REVIEWERS="${3:-both}"
    case "$REVIEWERS" in
        both) ;;
        codex-only)
            echo "PR_COPILOT_PHASE_CLOSED pr=$PR mode=codex-only copilot-sha=none codex-sha=$CODEX_SHA"
            exit 0 ;;
        *) echo "ABORT: '$REVIEWERS' is not a reviewers mode; expected 'both' or 'codex-only'"; exit 1 ;;
    esac

    COPILOT_SHA=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
        || { echo "ABORT: could not read the head to record the Copilot signoff"; exit 1; }
    _why="$(sha_reason "$COPILOT_SHA")" \
        || { echo "ABORT: the head is not a full OID ($_why: '$COPILOT_SHA'); do not record a signoff for it"; exit 1; }

    # THE VERDICT IS RE-CHECKED AGAINST EXACTLY THIS SHA before it is written
    # down. Only the SHAPE of the head was checked above, so a push landing
    # between the clean verdict and this lookup — or while the operator had the
    # stop parked — recorded the NEW, unreviewed head as Copilot-signed. The
    # durable record would then say both phases closed on a commit neither
    # reviewer saw, and every later session would believe it.
    COPILOT_RECHECK=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_COPILOT_BOT" "$COPILOT_SHA"); COPILOT_RECHECK_RC=$?
    [[ $COPILOT_RECHECK_RC -eq 0 ]] \
        || { echo "ABORT: Copilot is not clean on the sha being recorded ($COPILOT_RECHECK) — the head moved; do not record a signoff for it"; exit 1; }

    # COMPOSED HERE, for the reason `record`'s marker is: the caller writes no
    # part of this. Both shas are validated OIDs and the logins are library
    # constants, so there is no caller text to insert and nothing to quote out of.
    CLOSE_BODY="$(printf '**Review-Signoff:** `%s` `%s`\n\nCopilot signed off on `%s`. Codex signed off on `%s`; if those differ, the older Codex result carries only if the merge gate validates that every commit between them is a Review-Phase: copilot fix.\n' \
        "$RB_COPILOT_BOT" "$COPILOT_SHA" "$COPILOT_SHA" "$CODEX_SHA")" \
        || { echo "ABORT: could not compose the Copilot signoff."; exit 1; }
    gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "$CLOSE_BODY" \
        || { echo "ABORT: could not record the Copilot signoff"; exit 1; }

    echo "PR_COPILOT_PHASE_CLOSED pr=$PR reviewer=$RB_COPILOT_BOT copilot-sha=$COPILOT_SHA codex-sha=$CODEX_SHA"

    # ── STOP. MERGING IS THE OPERATOR'S DECISION ───────────────────────────
    #
    # Both reviewers are clean and both signoffs are on the PR. Merging is the
    # largest irreversible action this tool takes, and "every gate passed" is an
    # input to that decision rather than the decision itself.
    #
    # WHICH QUESTION IS ASKED DEPENDS ON WHETHER THE PHASE PRODUCED COMMITS, and
    # the two shas are how that is known. Where they differ, Copilot's fixes moved
    # the head after Codex looked at it, and a fault-tolerance pass over those
    # commits is a real option. Where they are the SAME, Codex has already
    # reviewed exactly what is being merged: offering the pass there costs a
    # revocation, a round and a reopened phase for a verdict that cannot differ —
    # and a session resuming into the reopened phase reads it as a Copilot phase
    # to run again. That is not hypothetical; it is what #55 was raised for.
    if [[ $COPILOT_SHA = "$CODEX_SHA" ]]; then
        cat <<EOF

Copilot signed off on $COPILOT_SHA, and so did Codex — one commit, both
reviewers, and it is the head being merged. Nothing has changed since either
looked, so there is no fault-tolerance pass to run over it.

  Decide, and say which:
    (a) merge — run pr-merge-gate.sh
    (b) stop and leave the PR open

Nothing further happens until you say.
EOF
    else
        cat <<EOF

Copilot signed off on $COPILOT_SHA. Codex signed off on $CODEX_SHA.

Those differ, so Copilot's fixes moved the head after Codex looked at it — the
older Codex result is carried forward ONLY if the merge gate validates that every
commit between them is a Review-Phase: copilot fix, and it refuses if any is not.
That check has not run yet.

  Decide, and say which:
    (a) merge — run pr-merge-gate.sh
    (b) another Codex pass first, as fault tolerance over the Copilot changes.
        POST A REVOCATION BEFORE REQUESTING IT — a comment whose only content is
        the line **Review-Signoff-Revoked:** followed by the Codex login in
        backticks. Without it the old signoff still stands, and a session resumed
        while the new pass is running reads the reopened phase as closed.

Nothing further happens until you say.
EOF
    fi
    exit 0
fi

# ── RECORD WHAT CODEX SIGNED OFF, THEN ASK ─────────────────────────────────
BODY_FILE="${2:-}"
[[ -n $BODY_FILE ]] \
    || { echo "ABORT: a body file is required: the paragraph saying what the PR does and what the Codex phase changed."; exit 1; }
# AND A FILE TO HAND THE SIGNED-OFF SHA BACK IN, because the caller needs it and asking
# the API a second time is a second answer. This stage PROVES that sha, records it and
# knows it; `pr-close-round.sh gate` has handed the head over the same way since #202 and
# `post` the baseline since #234. The driver read it back with `pr-signoff.sh sha`, then
# validated the result with a regex and a status check — a round-trip and eleven lines of
# the one shell nothing can harden, for a value this process already holds. #239.
SHA_FILE="${3:-}"
[[ -n $SHA_FILE ]] \
    || { echo "ABORT: a sha file is required: 'record' writes the signed-off commit into it for the caller to read back."; exit 1; }
# NOT THE BODY FILE, by path and by `-ef`. The sha would overwrite the account this stage
# is about to post, and a caller with a tidy scratch directory produces that by accident.
if [[ $SHA_FILE = "$BODY_FILE" ]] || [[ $SHA_FILE -ef $BODY_FILE ]] 2>/dev/null; then
    echo "ABORT: the sha file and the body file are the same file ('$SHA_FILE'); the sha would overwrite the account."
    exit 1
fi
# THE SHA FILE IS NOT CLEARED AT ALL, and that is #245. There were two clearings — one
# above the bootstrap, one here — and NEITHER protected a read that can happen. The driver
# reads `$HEAD_FILE` in the success arm and in the `3` arm; every refusal exits 1 into the
# `*)` arm, which reads nothing, and with `exit` shadowed to return execution falls past
# that fence carrying whatever `CODEX_SHA` already held — the value retained for step 8,
# not anything this file wrote. On success and on the pause alike, the WRITE below has
# already replaced the file before either read.
#
# So the clearings were destroying to protect nothing. `>` follows a symlink and truncates
# its target, and a FIFO at the name blocks; an arm no reader depends on could still take
# an operator's file. What replaces them is the write itself, which is bounded, takes its
# status, and is compared in the child — a stale value cannot survive it, and a refusal
# before it leaves a file the driver never opens.
#
# THE BODY FILE IS STILL REFUSED, above, and that guard is unaffected: it is about the sha
# and the account naming one file, which is wrong however the file is opened.
# READ WITH ITS STATUS TAKEN, before anything is posted. A partial read still
# produces a successful `gh pr comment`, and the reviewer contract makes the newest
# summary the thing read before the diff — so a truncated one is worse than none:
# it looks complete.
BODY="$(cat "$BODY_FILE")" || { echo "ABORT: could not read the phase body."; exit 1; }
[[ -n $BODY ]] || { echo "ABORT: the phase body is empty; say what the Codex phase changed."; exit 1; }
# THE BODY IS PROSE, AND MUST NOT BECOME A RECORD. It is composed from findings,
# PR descriptions and reviewer comments, and this comment is posted under an
# identity `pr-signoff.sh` and `pr-round-count.sh` trust — so a line reproducing
# one of their markers CREATES the record it was describing. A quoted finding
# about an acknowledgement becomes the acknowledgement, and the round boundary it
# answers never fires again.
# AND MUST NOT REQUEST A REVIEW EITHER. This summary is posted on its own and the
# script stops for the operator immediately afterwards, so a body quoting
# `@codex review` — out of a PR description, a finding, or this repository's own
# documentation — starts a Codex pass against a phase that has just stopped.
rb_review_trigger "$BODY"; _trig_rc=$?
case "$_trig_rc" in
    1) ;;
    0) echo "ABORT: the phase body contains '@codex review', which requests a Codex pass on its own."
       echo "This summary is posted standalone and the loop stops after it, so that pass would answer nobody. Break the mention up, or describe it without the @."
       exit 1 ;;
    *) echo "ABORT: could not tell whether the phase body requests a review (rc=$_trig_rc)"; exit 1 ;;
esac
if _marker="$(rb_reserved_marker_line "$BODY")"; then
    echo "ABORT: the phase body starts a line with a marker the loop reads as a record: $_marker"
    echo "It would be posted under your identity and honoured. Indent it by four spaces, or quote it inline with backticks — either still says what you meant. A fenced block does NOT help: the line inside it still starts at column 0, which is all the readers look at."
    exit 1
fi

# THE HEAD THE CLEAN VERDICT DESCRIBED, re-read and then re-validated — not
# whatever `gh pr view` reports now. If a push lands between the verdict and this
# lookup, recording the new, unreviewed head as the Codex signoff requests Copilot
# against it, and the final gate only discovers the missing Codex verdict after the
# whole Copilot phase has run.
CODEX_SHA=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not capture the Codex-signed-off head; do not start the Copilot phase"; exit 1; }
_why="$(sha_reason "$CODEX_SHA")" \
    || { echo "ABORT: the captured head is not a full OID ($_why: '$CODEX_SHA'); do not start the Copilot phase"; exit 1; }

# RE-VALIDATED ON EXACTLY THAT SHA. If it is not clean, the head moved and the
# phase must not advance.
CODEX_RECHECK=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); CODEX_RECHECK_RC=$?
[[ $CODEX_RECHECK_RC -eq 0 ]] \
    || { echo "ABORT: Codex is not clean on the sha being recorded ($CODEX_RECHECK) — the head moved; do not start the Copilot phase"; exit 1; }

# THE CHECKS ON THAT HEAD, TOO. The CI gate lives at the push sites in step 5, and
# a PR whose first review is clean never enters step 5 at all — so a head with a
# failing check could pass through both phases untouched, and the merge gate looks
# only at REQUIRED checks, which a failing optional one is not. Every path that
# accepts a verdict as phase-completing has to have seen the checks, not just the
# paths that pushed something.
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-ci-gate.sh "$PR" "$CODEX_SHA" || exit 1


# THE SIGNOFF IS WRITTEN DOWN, not just printed. This line is the record the next
# session reads: `pr-signoff.sh` scans the PR's comments for it, so closing the
# terminal, changing machine or coming back tomorrow no longer loses the one fact
# the phasing rests on — that Codex is clean on this exact commit. A value that
# only exists in a shell variable is the `/tmp` counter mistake v1 made.
#
# COMPOSED HERE, with `printf` and a validated sha, rather than in the caller's
# prose. The marker is a line of its own and anchored when read, so quoting it
# inside prose signs nothing off — and the caller's body is inserted as data, not
# as a template: a summary that quotes a finding about `$(gh pr view …)`, or lifts
# a backtick-delimited command line out of an untrusted PR description, was
# EXECUTED while being written when this was a heredoc the shell expanded.
# THE BOUNDARY IS ESTABLISHED BEFORE ANYTHING IS PUBLISHED, and acted on after.
# These are two different requirements and the first attempt met only the second:
# a count that could not be read exited 1 with the signoff already posted, so a
# later session's `pr-signoff.sh` accepted that record and could open Copilot or
# take the codex-only merge without anyone having established whether an operator
# boundary was due. An unreadable count is a stop, and a stop must leave nothing
# behind.
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-round-count.sh "$PR" "$RB_CODEX_BOT"; ROUNDS_RC=$?
case "$ROUNDS_RC" in
    0|3) ;;
    *) echo "ABORT: could not establish the round count (rc=$ROUNDS_RC); nothing recorded"; exit 1 ;;
esac

# PROVED AGAIN, IMMEDIATELY BEFORE THE POST, because the two stages above are not
# instant and the post is irreversible. The CI gate WAITS for checks to settle, so
# the window between the proof and the write is as long as a build — and in it
# another session can post a `**Review-Signoff-Revoked:**`, which is how a phase is
# deliberately reopened. The signoff below would then SUPERSEDE that revocation,
# because the readers take the last record, while GitHub keeps serving the old
# clean verdict until the new pass reports. A later `open` finds a current signoff
# and a clean verdict and requests Copilot underneath a phase somebody had
# reopened.
#
# THE HEAD, THE VERDICT, THE HEAD AGAIN, AND THE ORDERING. Not the same set `open`
# makes — that one reads the recorded signoff and takes the last record, which is
# the wrong question here: the record this stage must not supersede may be older
# than a signoff already on the PR. The head is read twice because the verdict
# lookup between them is a network call. #115.
RECHECK_HEAD=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not re-read the head before recording; nothing posted"; exit 1; }
[[ $RECHECK_HEAD = "$CODEX_SHA" ]] \
    || { echo "ABORT: the head moved to $RECHECK_HEAD while the checks were proving; nothing posted"; exit 1; }
# NO SEPARATE CLEANLINESS PROBE HERE ANY MORE. It asked `verdict` and the
# `clean-at` read below asks the same question — so it established nothing the
# next call does not, while adding a way to fail: a transient failure on it
# aborted the stage before reaching the arm that recovers from exactly that. #139.

# AND THE ORDERING LAST, IMMEDIATELY BEFORE THE WRITE. A revocation landing in
# this window is the case #115 was filed for, and refusing on ANY revocation was
# the first fix — it is not what this does, because it breaks the legitimate
# path: the fault-tolerance pass posts its revocation BEFORE requesting the
# review, so that revocation is still the newest record when the new clean
# verdict arrives, and an unconditional refusal means a reopened phase can never
# record its replacement signoff at all.
#
# WHEN THE VERDICT LANDED, FROM THE SNAPSHOT THAT PROVED IT CLEAN. The signoff
# carries it, so a reader can order a revocation against the VERDICT rather than
# against comment order — this stage cannot close that window itself, because its
# own write is what erases the evidence. #137, for #122.
#
# ONE QUESTION, NOT TWO. This asked `verdict` and then `review-at`, and a result
# arriving between them was the one `review-at` timed — so the record could claim
# to answer a verdict nobody proved. Re-proving cleanliness afterwards closed the
# named window and left the next: a clean-to-clean transition paired the NEW
# verdict with the OLD time. `clean-at` answers both from one snapshot, so there is
# no second question to answer differently. #139.
#
# BEFORE THE TRIGGER, NOT BETWEEN IT AND THE WRITE. Read after it, this call sits
# between the last look at the signoff record and the post — so a revocation
# landing during it is superseded on the ORDINARY path, where nothing had looked
# since. That is a window this change would have ADDED, and moving the read
# removes it: the revoked arm below re-reads the record anyway.
#
# AND ITS ABSENCE NEVER STOPS THE RECORD. The field is optional precisely so an
# unreadable probe degrades to a record without it, which reads back exactly as
# every record written before #135 does. A signoff that cannot be ordered against
# a revocation is the state we already live in; a phase that cannot close because
# of a transient API failure is worse.
#
# A `1` IS NOT AN ABSENCE HERE, THOUGH. `clean-at` answers 1 when there is no
# clean verdict on this head — and this stage has already proved there is one, so
# a `1` means it stopped being clean while this ran, exactly as the separate
# re-proof used to catch. Cleanliness is a precondition for recording at all.
RB_VERDICT_AT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh clean-at "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); RB_CLEAN_AT_RC=$?
case "$RB_CLEAN_AT_RC" in
    0) ;;
    1) echo "ABORT: Codex is no longer clean on $CODEX_SHA; nothing posted"; exit 1 ;;
    # AN UNREADABLE ANSWER COSTS THE CLEANLINESS PROOF, NOT ONLY THE TIME. This
    # call IS the last proof — the one before it predates a network round trip a
    # blocking verdict can land in — so degrading to "no timestamp" would record
    # a signoff whose newest evidence is older than the probe that failed.
    #
    # SO THE CLEANLINESS IS ASKED FOR ON ITS OWN. That is two reads again, but not
    # the pair this change removed: nothing is being PAIRED here, because there is
    # no time left to pair with. It answers one question — is it still clean — and
    # the record carries no verdict time either way.
    *) RB_VERDICT_AT=""
       echo "note: when the verdict on $CODEX_SHA landed could not be read; the signoff will not carry one"
       RB_STILL_CLEAN=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); RB_STILL_CLEAN_RC=$?
       [[ $RB_STILL_CLEAN_RC -eq 0 ]] \
           || { echo "ABORT: Codex is no longer clean on $CODEX_SHA ($RB_STILL_CLEAN); nothing posted"; exit 1; } ;;
esac
case "$RB_VERDICT_AT" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) RB_VERDICT_AT="" ;;
esac
[[ -n $RB_VERDICT_AT ]] || echo "note: no readable verdict time for $CODEX_SHA; the signoff will not carry one, and a later revocation cannot be ordered against it"

# AND THE HEAD AGAIN, AFTER THE TIME PROBES. Each probe above is a network call,
# so the head can move DURING one of them — and the two added for the verdict time
# are pinned to `$CODEX_SHA`, so a push landing in either leaves them answering
# about a commit that is no longer the head. Read before them, this check confirmed
# a head that the probes then outlived. Every remote read that can be outlived is
# now behind it, and the signoff-record read that follows is the last of all — and the verdict is pinned to `$CODEX_SHA`, so it stays
# clean and says nothing about the move.
#
# THE ORDERING PROOF GOES AFTER THIS ONE, and which of the two is last is not
# arbitrary. Both leave a window between the proof and the write, and the two
# residues are not alike: a head that moves in it is caught downstream, because
# `open` re-reads the head and refuses when it is not the recorded sha — nothing
# is lost but a run. A revocation that lands in it is NOT, because the signoff
# posted next supersedes it and the readers take the last record: the evidence
# that the phase was reopened is gone, and no later stage can find it. The
# unrecoverable one is therefore the one proved last. #122 is the residue that
# remains.
FINAL_HEAD=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not re-read the head before posting; nothing posted"; exit 1; }
[[ $FINAL_HEAD = "$CODEX_SHA" ]] \
    || { echo "ABORT: the head moved to $FINAL_HEAD while the phase was being proved; nothing posted"; exit 1; }

# TELLING THE TWO APART IS ORDERING: a revocation this pass is ANSWERING landed
# before the verdict, and one that would CANCEL it landed after.
#
# THE RECORDS SAY WHICH, since #117: `pr-signoff.sh` reports `at=` on a revocation
# and `pr-review-state.sh clean-at` reports when the verdict landed, answering
# from the comment channel as well as the reviews — Codex delivers a clean pass
# either way. That value is already in hand, read above with the cleanliness it
# describes; this arm does not ask again. #139.
#
# SO THE RULE IS: the phase is reopened when the newest revocation is LATER than
# the verdict being signed off, and only then. Earlier, and this pass is the
# answer to it — refusing there is what stopped a reopened phase recording its
# replacement signoff at all.
#
# BOTH TIMESTAMPS ARE CANONICAL UTC, which `recordlib.sh` enforces on every record
# either side, so the string order is the time order and no date arithmetic is
# needed. A parse here would be a second definition of a rule those validators
# already hold.
#
# EQUAL IS A REFUSAL, and it is the one case this cannot decide: `created_at` is
# second-resolution, and the two records come from DIFFERENT resources — an issue
# comment, and a review when the verdict was one — so their ids are not comparable
# and cannot break the tie. Refusing costs a rerun once the clock has moved;
# recording would supersede a reopening somebody meant.
# THE READ THAT DECIDES IT IS THE LAST REMOTE READ THERE IS. Asking once and then
# fetching the verdict's time re-opened the window one level down: a March
# revocation posted while the time was being fetched was compared as the January
# one the first ask saw, and the signoff went out over it. So the first ask is
# only the TRIGGER — whether an ordering question exists at all — and the record
# COMPARED is read again afterwards, with nothing but the write behind it.
RB_TRIGGER=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$RB_CODEX_BOT" 2>&1); RB_TRIGGER_RC=$?
case "$RB_TRIGGER_RC" in
    0|1) ;;
    *) echo "ABORT: could not read the signoff record before recording (rc=$RB_TRIGGER_RC); nothing posted"; exit 1 ;;
esac
case "$RB_TRIGGER" in
*reason=revoked*)
    # WITH A REVOCATION STANDING THE TIME IS NOT OPTIONAL. Above it is a value the
    # record carries or does not; here it is what decides whether recording
    # supersedes a reopening, and an empty answer means no verdict on this head
    # was found at all. Either, with a revocation standing, is the state that must
    # not record.
    [[ -n $RB_VERDICT_AT ]] \
        || { echo "ABORT: a revocation is the newest record and no verdict on $CODEX_SHA has a readable time; nothing posted"; exit 1; }
    SIGNOFF_NOW=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$RB_CODEX_BOT" 2>&1); SIGNOFF_NOW_RC=$?
    case "$SIGNOFF_NOW_RC" in
        0|1) ;;
        *) echo "ABORT: could not re-read the signoff record before recording (rc=$SIGNOFF_NOW_RC); nothing posted"; exit 1 ;;
    esac
    # AND IT HAS TO STILL BE A REVOCATION. If the newest record changed to
    # something else while the verdict's time was being fetched, this stage
    # cannot place what it was about to act on — and a rerun costs one round trip,
    # where guessing costs the reopening. The ordinary phase does not come through
    # here at all: it never entered this branch.
    case "$SIGNOFF_NOW" in
        *reason=revoked*) ;;
        *) echo "ABORT: the newest record changed while the verdict's time was read ('$SIGNOFF_NOW'); nothing posted"; exit 1 ;;
    esac
    # THE FIELD HAS TO BE THERE BEFORE IT IS PEELED. `${…##*at=}` on a record
    # WITHOUT `at=` returns the whole line, and `%% *` then takes its first
    # word — `PR_SIGNOFF` — which is a non-empty value that is not a time, and
    # sorts below every real timestamp. That reads as "the revocation is older
    # than the verdict", which is the one answer that records over a reopening.
    case "$SIGNOFF_NOW" in
        *" at="*) ;;
        *) echo "ABORT: a revocation is the newest record and carries no time ('$SIGNOFF_NOW'); nothing posted"; exit 1 ;;
    esac
    # PEELED FROM THE RECORD, whose field order `pr-signoff.sh` fixes as `at=`,
    # `id=`, `sha=` — so `at=` is followed by a space and the next field, and this
    # takes exactly that value.
    RB_REVOKED_AT="${SIGNOFF_NOW##* at=}"
    RB_REVOKED_AT="${RB_REVOKED_AT%% *}"
    # AND IT HAS TO BE A TIME. These are compared as STRINGS, which is the time
    # order only for canonical UTC — a value of another shape sorts somewhere
    # arbitrary, and one sorting low is again the answer that records over a
    # reopening. `recordlib.sh` enforces the shape on the way in; this is the
    # caller refusing to act on one it cannot place.
    case "$RB_REVOKED_AT" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
        *) echo "ABORT: a revocation is the newest record and its time is unreadable ('$RB_REVOKED_AT'); nothing posted"; exit 1 ;;
    esac
    [[ $RB_REVOKED_AT < $RB_VERDICT_AT ]] \
        || { echo "ABORT: this phase was reopened — the revocation at $RB_REVOKED_AT is not older than the verdict at $RB_VERDICT_AT. Recording a signoff now would supersede it; nothing posted"; exit 1; } ;;
esac

# THE MARKER CARRIES THE VERDICT TIME WHERE THERE IS ONE, as its third backticked
# field. Composed as two shapes rather than one with an empty pair of backticks:
# an empty field is a value `pr-signoff.sh` refuses, so writing one would make the
# record this stage just posted unreadable to the next reader. #137.
if [[ -n $RB_VERDICT_AT ]]; then
    RB_MARKER="$(printf '**Review-Signoff:** `%s` `%s` `%s`' "$RB_CODEX_BOT" "$CODEX_SHA" "$RB_VERDICT_AT")" \
        || { echo "ABORT: could not compose the signoff marker."; exit 1; }
else
    RB_MARKER="$(printf '**Review-Signoff:** `%s` `%s`' "$RB_CODEX_BOT" "$CODEX_SHA")" \
        || { echo "ABORT: could not compose the signoff marker."; exit 1; }
fi
SUMMARY="$(printf '## Codex phase complete\n\n%s\n\nCodex signed off on `%s`.\n\n%s\n\nFix commits from here carry a `Review-Phase: copilot` trailer, which is how the merge gate knows the head advanced only through Copilot fixes and that Codex'"'"'s signoff still covers it.\n' \
    "$RB_MARKER" "$CODEX_SHA" "$BODY")" \
    || { echo "ABORT: could not compose the phase summary."; exit 1; }

# THE SHA IS HANDED BACK BEFORE THE POST, with the write's status taken and the value
# read back. `printf` can report success and fail at the flush, and taking the status only
# works while there is something left to refuse WITH: after the comment is posted the
# signoff is on the PR and this stage cannot be un-run.
# BOUNDED, LIKE `open`'S WRITES, AND NO LONGER BECAUSE OF FIFOs. The write opens nothing at
# this path: `rb_write_handoff` creates a temporary with `O_CREAT|O_EXCL` — which refuses a
# FIFO rather than waiting on it — and renames. What can still stall is pathname resolution,
# the write and the rename, on an unresponsive filesystem, and this write is the one
# immediately before the signoff is posted, so a hang here stalls the stage with the phase
# half decided. `open` has bounded both of its writes since #230; this was the copy left
# plain, which is the same way its read-back ended up the weaker of the two. #246.
_rb_wh="$(run_limited 10 /usr/bin/env bash -p -c \
    'rb_write_handoff() { return 127; }; . "$1"/writelib.sh 2>/dev/null || exit 9; rb_write_handoff "$2" "$3"' \
    _ "$_RB_SELF_DIR" "$SHA_FILE" "$CODEX_SHA")" \
    || { echo "ABORT: could not write the signed-off sha to '$SHA_FILE'; nothing has been posted."; exit 1; }
# AND NOT READ BACK AGAIN HERE, for the reason `open` gives at its own write: since #263
# `rb_write_handoff` proves the raw bytes before it returns, with a no-follow non-blocking
# open and the type from `fstat` on the handle. This stage's copy was the weaker of the two
# even when both existed — a truncated read can never equal a forty-character sha, so it was
# never exposed the way the baseline was — and #246's finding was precisely that two
# read-backs proving the same kind of thing in two shapes let one of them rot. One, in the
# library, is that finding taken to its end.

gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "$SUMMARY" \
    || { echo "ABORT: could not post the phase summary — the signoff is not recorded; do not request Copilot."; exit 1; }

echo "PR_PHASE_RECORDED pr=$PR reviewer=$RB_CODEX_BOT codex-sha=$CODEX_SHA"

# AND ACTED ON AFTER IT. The pause offers "merge on the Codex signoff" and "leave
# it open", so exiting before the record was posted left the operator neither a
# durable signoff for a later session nor the sha the codex-only merge needs.
# Nothing in this stage requests a review, so publishing before the pause queues
# nothing — the boundary still precedes everything that commits to more work.
[[ $ROUNDS_RC -ne 3 ]] || {
    echo "PAUSE: round boundary reached. Decide with the operator before opening the Copilot phase: continue, merge on the Codex signoff, leave it open, or close this PR and start over"
    exit 3; }

# ── STOP. THE NEXT PHASE IS THE OPERATOR'S DECISION ────────────────────────
# Codex is clean and that is now recorded on the PR. What happens next is not the
# loop's call: merging on one reviewer's signoff is a legitimate place to stop,
# and the phase this would open can run as long as the one just finished.
cat <<EOF

Codex has signed off on $CODEX_SHA, and the signoff is recorded on the PR.

  Decide, and say which:
    (a) merge now on Codex's signoff alone — the merge gate with
        REVIEWERS=codex-only, which requires the head to BE this commit and is
        therefore a narrower gate than the two-reviewer one, not a looser one
    (b) open the Copilot phase on the same head —
        pr-copilot-phase.sh open $PR $CODEX_SHA <baseline-file>
        where <baseline-file> is a writable path this session will hand to
        pr-watch.sh --after-review-file; the driver uses its own \$PRIOR_FILE

Nothing further happens until you say. This is resumable: the signoff is on the
PR, so a later session can read it back with pr-signoff.sh.
EOF
exit 0
