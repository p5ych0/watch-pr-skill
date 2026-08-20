#!/usr/bin/env -S bash -p
# Which phase is this pull request in, read back from the records on it.
#
#   pr-phase-state.sh <pr>
#
#   0  the phase is readable and the record it names STILL STANDS. One line:
#
#        PR_PHASE pr=<n> state=before-copilot codex-sha=<40hex> head=<40hex>
#        PR_PHASE pr=<n> state=after-copilot codex-sha=<40hex> copilot-sha=<40hex> head=<40hex>
#
#   1  stopped — the phase is NOT what a resumed session would assume. The record
#      says which, and the prose after it says what to do
#   2  unreadable — fail closed. An unreadable answer is not "no signoff": read as
#      one it repeats a phase, and read as a signoff it skips a review nobody did
#
# WHY THIS IS A SCRIPT
#
# A later session — tomorrow, another machine — has none of the variables the
# stop was reached with, and the recipe that restored them lived in `SKILL.md` as
# 112 lines the model retyped. Nothing covered it: the suite, `pr-selfcheck.sh`
# and the bash 3.2 job all stop at the edge of a Markdown file, and this block has
# three arms and six refusals none of which had ever been executed by a test.
# Every abort in it also exited 0, because the driving shell must not die on a
# refusal — so "the phase is not closed" and "this ran correctly" were the same
# status to anything that read it. #123, under #26.
#
# WHAT IT IS FOR
#
# `SKILL.md` tells the model to read the phase off the PR rather than from what it
# remembers, which is advice it could not enforce while the reading was prose. The
# records are the memory: `record` writes a signoff precisely so a later session
# can read it back.
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
# that prints a forged `PR_PHASE status=error` line and exits has already answered the
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
    echo "PR_PHASE status=error reason=not_privileged" >&2
    exit 2
fi

set -uo pipefail

# The shared record validators. Three scripts read the same two endpoints, and
# each used to re-implement the same field checks — which is why the same rule
# kept having to be added a third and fourth time, and why `state` reached two
# scripts and stopped. See recordlib.sh and issue #11.
#
# The status is taken: a helper whose validators failed to load would fall back
# to whatever the jq programs below happen to do with undefined functions, which
# is an error per call rather than a clear refusal here.
_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_PHASE status=error reason=lib_dir_unresolvable" >&2; exit 2; }
# The library loader — and it obeys its own rule. A helper cannot load the file
# that defines it, so this sequence is written out here; that asymmetry is
# irreducible, but it is not a licence to load the loader carelessly. An exported
# `rb_load` survives into this shell and an empty `loadlib.sh` still sources
# successfully, so without the clear the first load runs the INHERITED
# function — and a stale loader is the one thing that can make every OTHER load
# look clean. See loadlib.sh and issue #22.
unset -f rb_load 2>/dev/null || {
    echo "PR_PHASE status=error reason=loadlib_stale_definition" >&2; exit 2; }
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
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_PHASE status=error reason=loadlib_unreadable" >&2; exit 2; }
# THE FIRST LOAD CARRIES THE SENTINEL, because it is what the preflight used to
# say. An empty `loadlib.sh` leaves the stub, the stub returns 127, and without
# this arm the only trace is a bare exit status — the ordinary-looking empty
# answer `CLAUDE.md` forbids. 127 is the stub's and nothing else's: `rb_load`'s
# own refusals report their own reason and their own status.
rb_load "$_RB_SELF_DIR" recordlib is_full_sha "PR_PHASE status=error" || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "PR_PHASE status=error reason=loadlib_empty" >&2
    exit 2; }
# BOTH CONSTANTS, EACH THROUGH `rb_load`. Verifying only one leaves the other
# inheritable: a `recordlib.sh` truncated after the first definition passes the
# check, and an exported `RB_COPILOT_BOT` from the environment is then accepted as
# library data — so the phase would be read under whatever account that variable
# named, which is the wrong-reviewer answer with no sign that anything was wrong.
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "PR_PHASE status=error" var || exit 2
rb_load "$_RB_SELF_DIR" recordlib RB_COPILOT_BOT "PR_PHASE status=error" var || exit 2
rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_PHASE status=error" || exit 2
rb_identity || { echo "PR_PHASE status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }

PR="${1:-}"
case "$PR" in
    ""|*[!0-9]*) echo "PR_PHASE status=error reason=bad_pr" >&2; exit 2 ;;
esac

# THE STATUSES ARE DISTINGUISHED, because they mean different things and only one
# of them is permission to continue:
#
#   0  a signoff exists — use the sha it names
#   1  none recorded — the phase is NOT closed. Do not invent one; go and run it
#   2  could not tell — fail closed
#
# `sha` ASKS FOR THE HEAD ALONE, so nothing here parses a record line. It was a
# `sed` in the driver, and `sed` is a NAME: one that prints a plausible forty hex
# and exits 0 pins a merge to whatever it says, and a pipeline's status is lost
# besides. The helper owns the shape and its suite covers it. #89.
CODEX_SHA="$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh sha "$PR" "$RB_CODEX_BOT")"; CODEX_RC=$?
case "$CODEX_RC" in
    0) ;;
    1) echo "PR_PHASE pr=$PR status=stopped reason=codex_phase_open"
       echo "The Codex phase is not closed on this PR — there is no recorded signoff, or it was revoked. Run it before merging or opening the Copilot phase."
       exit 1 ;;
    *) echo "PR_PHASE pr=$PR status=error reason=signoff_unreadable rc=$CODEX_RC" >&2; exit 2 ;;
esac
# THE SHAPE, THROUGH `sha_reason`, like everything else here that asks what a
# commit is. `sha` prints 40 hex or nothing, so a value of any other shape cannot
# come from the helper — which is the point of checking it: what this prints is
# what the merge gate is pinned to, and it is not left resting on one helper's
# promise. The RULE lives in `recordlib.sh`, because a second copy of it is how
# three helpers came to disagree about what a commit is.
if ! is_full_sha "$CODEX_SHA"; then
    echo "PR_PHASE pr=$PR status=error reason=bad_codex_sha" >&2
    exit 2
fi

# THE RECORD IS HISTORY, NOT A CURRENT FACT. It says Codex was clean on that
# commit when it was written — not that the commit is still the head, nor that the
# review still stands. A dismissal, or a push while the stop was parked, leaves
# the marker exactly as it was; continuing on it opens a Copilot phase against a
# head Codex never approved, and the whole loop is spent before the merge gate
# finally refuses.
#
# So the resumed value is re-validated against the world as it is now, and BOTH
# halves matter: the head must still be that commit, and the verdict must still be
# clean on it.
HEAD=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "PR_PHASE pr=$PR status=error reason=head_unreadable" >&2; exit 2; }
if ! is_full_sha "$HEAD"; then
    # ANYTHING `gh` PRINTED BEFORE FAILING IS NOT DATA. Command substitution keeps
    # it, so a call that emitted a plausible sha and then errored reads as success
    # unless the shape is validated as well as the status.
    echo "PR_PHASE pr=$PR status=error reason=bad_head" >&2
    exit 2
fi

# WHICH STOP IS BEING RESUMED FROM decides what "still valid" means, and the two
# answers are opposite. Before the Copilot phase, the Codex signoff is the only
# thing licensing a merge, so the head must still BE that commit. AFTER it, the
# head has advanced through Copilot fixes BY DESIGN — the merge gate accepts that
# delta once it has checked the `Review-Phase: copilot` trailers — and demanding
# equality there rejects the very state the second stop exists in.
#
# A recorded COPILOT signoff is what tells the two apart, and it is a fact on the
# PR rather than a guess about the session.
#
# 1 IS AN ANSWER HERE, not a refusal: "no Copilot signoff" is exactly what the
# branch below is asking about, and `sha` leaves the value empty in that case.
COPILOT_SHA="$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh sha "$PR" "$RB_COPILOT_BOT")"; COPILOT_RC=$?
case "$COPILOT_RC" in
    0|1) ;;
    *) echo "PR_PHASE pr=$PR status=error reason=copilot_signoff_unreadable rc=$COPILOT_RC" >&2; exit 2 ;;
esac

# THE SHAPE IS CHECKED HERE TOO, ON STATUS 0. Status 1 leaves the value empty and
# that is an answer. Status 0 with something that is not 40 hex is not an answer,
# and without this it would be read as "no signoff" and send the operator back
# through a phase that is closed — or, if the head read were malformed the same
# way, SELECT the post-Copilot arm on two values that match only because both are
# wrong.
#
# IT IS THE FIRST ARM OF THE BRANCH, NOT A GUARD BEFORE IT, and that is the
# difference between a refusal and a wish. Written as its own `if … exit`, a
# shadowed `exit` returns and execution falls into the selection below, where a
# malformed value is read as "no Copilot signoff" — the outcome the check exists
# to prevent. As an arm it is structural: a malformed sha SELECTS this arm, so
# neither of the others can run on it whatever has been done to the builtins.
# Privileged mode already means no function can be imported here; the shape is
# kept because it costs nothing and states the reason.
#
# THE BRANCH TURNS ON WHICH SIGNOFF DESCRIBES THE HEAD, not on whether a Copilot
# record exists at all. After "another Codex pass" produced fixes, the NEW Codex
# signoff names the current head while an older Copilot signoff still names the
# previous one — and choosing the post-Copilot path merely because that historical
# record exists then reported that neither phase was closed, sending the operator
# through a review nobody needed.
if [[ $COPILOT_RC -eq 0 ]] && ! is_full_sha "$COPILOT_SHA"; then
    echo "PR_PHASE pr=$PR status=error reason=bad_copilot_sha" >&2
    exit 2
    # THE LAST WORD IS A RESERVED ONE. With `echo` and `exit` both taken away this
    # arm says nothing and returns 0, and the block's status is the only signal
    # left. `[[` is a reserved word, so it ends non-zero whatever was done to the
    # builtins.
    [[ -n "" ]]
elif [[ $COPILOT_RC -eq 0 ]] && [[ $COPILOT_SHA = "$HEAD" ]]; then
    # RESUMING AFTER THE COPILOT PHASE. The Codex signoff is deliberately older
    # than the head; the gate is what proves the delta is Copilot-only. What must
    # still hold is the COPILOT signoff, on the head being merged.
    VERDICT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_COPILOT_BOT" "$COPILOT_SHA"); VERDICT_RC=$?
    if [[ $VERDICT_RC -ne 0 ]]; then
        echo "PR_PHASE pr=$PR status=stopped reason=copilot_verdict_withdrawn"
        echo "Copilot's recorded signoff no longer stands ($VERDICT) — a review can be dismissed after it was written."
        echo "Treat the Copilot phase as open: request a review before merging."
        exit 1
    fi
    echo "PR_PHASE pr=$PR state=after-copilot codex-sha=$CODEX_SHA copilot-sha=$COPILOT_SHA head=$HEAD"
    exit 0
else
    # RESUMING BEFORE THE COPILOT PHASE — or in `codex-only`, where there will
    # never be one. Nothing licenses a delta here, so the head must still BE the
    # commit Codex signed.
    if [[ $HEAD != "$CODEX_SHA" ]]; then
        echo "PR_PHASE pr=$PR status=stopped reason=head_moved head=$HEAD codex-sha=$CODEX_SHA"
        echo "The head has moved since that signoff (head=$HEAD signed=$CODEX_SHA)."
        echo "The Codex phase is NOT closed on this head: request a review of it before merging or opening the Copilot phase."
        exit 1
    fi
    VERDICT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); VERDICT_RC=$?
    if [[ $VERDICT_RC -ne 0 ]]; then
        echo "PR_PHASE pr=$PR status=stopped reason=codex_verdict_withdrawn"
        echo "The recorded signoff no longer stands ($VERDICT) — a review can be dismissed after it was written."
        echo "Treat the Codex phase as open: request a review before merging or opening the Copilot phase."
        exit 1
    fi
    echo "PR_PHASE pr=$PR state=before-copilot codex-sha=$CODEX_SHA head=$HEAD"
    exit 0
fi
