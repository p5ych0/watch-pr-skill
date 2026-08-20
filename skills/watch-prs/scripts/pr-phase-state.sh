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
rb_load "$_RB_SELF_DIR" recordlib rb_review_record "PR_PHASE status=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_replies_only_line "PR_PHASE status=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_signoff_answers "PR_PHASE status=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_answer_at "PR_PHASE status=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_escape_snapshot "PR_PHASE status=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_review_record_is_about "PR_PHASE status=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "PR_PHASE status=error" var || exit 2
rb_load "$_RB_SELF_DIR" recordlib RB_COPILOT_BOT "PR_PHASE status=error" var || exit 2
rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_PHASE status=error" || exit 2
rb_identity || { echo "PR_PHASE status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }

# THE ONE VERDICT AN OPERATOR CAN ANSWER FOR. A review whose comments are ALL
# replies reports `verdict=findings` with `source=replies-only`: nothing to fix
# and not a signoff. Reported as a dismissal it sends a resumed session to reopen
# a phase the operator has already answered — which is the deadlock the escape
# exists to end, one stage earlier than the merge gate. #125.
#
# THE RULE IS `recordlib.sh`'s AND THE FETCHING IS HERE, because the two callers
# read these records with their own error prefixes and their own statuses; what
# they share is what "this signoff answers that review" means.
# 0 vouched · 1 no record answers it · 2 a probe could not be read
#
# THE THIRD STATUS IS NOT THE SECOND. Folding an unreadable probe into "nobody
# signed this off" tells the operator to record a signoff they may already have
# recorded, and hides a broken read behind an ordinary-looking refusal — which is
# the fail-closed rule this helper states everywhere else.
RB_VOUCH_REVIEW_AT=''
RB_VOUCH_REPLIES_AT=''
# 0 vouched · 1 no record answers it · 2 a probe could not be read
#
# THE THIRD STATUS IS NOT THE SECOND. Folding an unreadable probe into "nobody
# signed this off" tells the operator to record a signoff they may already have
# recorded, and hides a broken read behind an ordinary-looking refusal — which is
# the fail-closed rule this helper states everywhere else.
#
# AND WHAT THE SIGNOFF HAS TO ANSWER COMES FROM ONE RESPONSE. This used to ask
# which review it was, when it landed, when its newest reply did and what the
# verdict was, as four probes bound by re-reading each — and every fix left the
# next window, because a sequential guard cannot close a gap between sequential
# calls, and no ordering of separate REST reads makes reviews and their comments
# one snapshot. `escape-snapshot` asks GraphQL, which returns both in a SINGLE
# response — consistent by construction — so nothing here compares anything. #133.
RB_VOUCH_REVIEW_AT=''
RB_VOUCH_REPLIES_AT=''
rb_phase_vouched() {   # rb_phase_vouched <reviewer> <sha>
    local _line _rc=0 _snap _src=0 _rat _pat
    # CLEARED HERE TOO, not only inside the library predicate: the early returns
    # below never reach it, and a stale value from a previous call would be
    # printed as this call's reason.
    RB_VOUCH_REASON=""
    RB_VOUCH_REVIEW_AT=""
    RB_VOUCH_REPLIES_AT=""
    _line=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$1" 2>&1) || _rc=$?
    # 1 IS AN ANSWER — nothing is recorded, so nothing vouches. Anything else is a
    # read that failed.
    case "$_rc" in
        0) ;;
        # AND IT SAYS SO. The reason is what the stop below prints, and the
        # commonest unvouched case — nothing recorded at all — reached it having
        # set nothing, so the message named an empty pair of brackets.
        1) RB_VOUCH_REASON=no_signoff; return 1 ;;
        *) RB_VOUCH_REASON=unreadable; return 2 ;;
    esac
    _snap=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh escape-snapshot "$PR" "$1" "$2") || _src=$?
    case "$_src" in
        0) ;;
        1) RB_VOUCH_REASON=not_the_escape_shape; return 1 ;;
        *) RB_VOUCH_REASON=snapshot_unreadable; return 2 ;;
    esac
    # `<id>TAB<review-at>TAB<newest-reply-at>`, PARSED rather than peeled. Peeling
    # with `${…#…}` alone assigns the second value to both times when a field is
    # missing and hides one when there is an extra, and drops a non-numeric id in
    # silence — the id being what proves the two times describe ONE review.
    rb_escape_snapshot "$_snap" || { RB_VOUCH_REASON=snapshot_malformed; return 2; }
    _rat="$RB_SNAP_REVIEW_AT"; _pat="$RB_SNAP_REPLY_AT"
    rb_answer_at "$_rat" "$_pat"; _src=$?
    case "$_src" in
        0) ;;
        1) RB_VOUCH_REASON=no_times_for_a_recorded_review; return 2 ;;
        *) RB_VOUCH_REASON=answer_time_unreadable; return 2 ;;
    esac
    # THE TIMES TRAVEL WITH THE ANSWER, because the stop below is what the operator
    # reads and "it does not answer this review" without saying WHEN leaves them
    # comparing timestamps by hand. `SKILL.md` promises both.
    RB_VOUCH_REVIEW_AT="$_rat"
    RB_VOUCH_REPLIES_AT="$_pat"
    rb_signoff_answers "$_line" "$RB_ANSWER_AT" "$PR" "$1" "$2"
}

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
    # THE THREE STATUSES ARE KEPT APART, because `-ne 0` folded two answers into
    # one: `1` is "the verdict is not clean", which is a phase to reopen, and `2`
    # is "the reviews could not be read", which is not an answer about the phase at
    # all. Told apart only by that test, an unreadable API sent the operator to
    # re-request a review that may never have been dismissed — and this helper's
    # own contract says 2 means unreadable everywhere else in it.
    VERDICT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_COPILOT_BOT" "$COPILOT_SHA"); VERDICT_RC=$?
    case "$VERDICT_RC" in
        0) # THE RECORD, NOT ONLY THE STATUS. A probe that exits 0 while printing
           # nothing, or a line about another PR, reviewer or head, is not an
           # answer about this phase — and acting on the status alone turns a
           # malformed probe into permission to continue. The two gates beside
           # this one validate; this did not. #126.
           if ! rb_review_record "$VERDICT" verdict; then
               echo "PR_PHASE pr=$PR status=error reason=copilot_verdict_unparseable" >&2; exit 2
           fi
           if ! rb_review_record_is_about "$PR" "$RB_COPILOT_BOT" "$COPILOT_SHA"; then
               echo "PR_PHASE pr=$PR status=error reason=copilot_verdict_misaddressed" >&2; exit 2
           fi
           if [[ $RB_REC_VALUE != clean ]]; then
               echo "PR_PHASE pr=$PR status=error reason=copilot_verdict_not_clean" >&2; exit 2
           fi
           # AND THE TAIL, which the library hands back rather than accepting —
           # what may follow a value differs per question, so the rule is the
           # caller's. `verdict=clean` with the `findings=0` truncated away is not
           # a clean answer, and read as one it closes the phase on a record that
           # was cut short. Spelled out rather than made optional: a trailing
           # `.*` accepts any field anyone ever appends.
           if [[ $RB_REC_TAIL != " findings=0" ]]; then
               echo "PR_PHASE pr=$PR status=error reason=copilot_verdict_truncated" >&2; exit 2
           fi ;;
        1) # `1` IS TWO ANSWERS. A dismissal reopens the phase; a review whose
           # comments are all replies does not, when the operator has recorded a
           # signoff that answers it.
           if rb_replies_only_line "$VERDICT" "$PR" "$RB_COPILOT_BOT" "$COPILOT_SHA"; then
               rb_phase_vouched "$RB_COPILOT_BOT" "$COPILOT_SHA"; RB_VOUCH_RC=$?
               if [ "$RB_VOUCH_RC" -eq 2 ]; then
                   echo "PR_PHASE pr=$PR status=error reason=copilot_vouch_unreadable" >&2; exit 2
               fi
               if [ "$RB_VOUCH_RC" -ne 0 ]; then
                   echo "PR_PHASE pr=$PR status=stopped reason=copilot_replies_only_unvouched"
                   echo "Copilot's review of $COPILOT_SHA carried only replies, and no signoff of yours answers it ($RB_VOUCH_REASON)."
                   # ONLY WHERE A DEADLINE WAS COMPUTED. `rb_phase_vouched` returns
                   # before reading either time when nothing is recorded at all —
                   # the commonest case — and printing `newer than ? … (none) …
                   # (none)` there is noise where the line above already said it.
                   [ -n "$RB_ANSWER_AT" ] && echo "It has to be newer than $RB_ANSWER_AT — the latest of that review (${RB_VOUCH_REVIEW_AT:-none}) and its newest reply (${RB_VOUCH_REPLIES_AT:-none})."
                   echo "Read the comment and record a signoff for that head, or request a review."
                   exit 1
               fi
           else
               echo "PR_PHASE pr=$PR status=stopped reason=copilot_verdict_withdrawn"
               echo "Copilot's recorded signoff no longer stands ($VERDICT) — a review can be dismissed after it was written."
               echo "Treat the Copilot phase as open: request a review before merging."
               exit 1
           fi ;;
        *) echo "PR_PHASE pr=$PR status=error reason=copilot_verdict_unreadable rc=$VERDICT_RC" >&2; exit 2 ;;
    esac
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
    # THE SAME THREE, for the same reason.
    VERDICT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"); VERDICT_RC=$?
    case "$VERDICT_RC" in
        0) # THE SAME THREE, on the other arm.
           if ! rb_review_record "$VERDICT" verdict; then
               echo "PR_PHASE pr=$PR status=error reason=codex_verdict_unparseable" >&2; exit 2
           fi
           if ! rb_review_record_is_about "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"; then
               echo "PR_PHASE pr=$PR status=error reason=codex_verdict_misaddressed" >&2; exit 2
           fi
           if [[ $RB_REC_VALUE != clean ]]; then
               echo "PR_PHASE pr=$PR status=error reason=codex_verdict_not_clean" >&2; exit 2
           fi
           # AND THE TAIL, which the library hands back rather than accepting —
           # what may follow a value differs per question, so the rule is the
           # caller's. `verdict=clean` with the `findings=0` truncated away is not
           # a clean answer, and read as one it closes the phase on a record that
           # was cut short. Spelled out rather than made optional: a trailing
           # `.*` accepts any field anyone ever appends.
           if [[ $RB_REC_TAIL != " findings=0" ]]; then
               echo "PR_PHASE pr=$PR status=error reason=codex_verdict_truncated" >&2; exit 2
           fi ;;
        1) # THE SAME TWO ANSWERS, on the other arm.
           if rb_replies_only_line "$VERDICT" "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"; then
               rb_phase_vouched "$RB_CODEX_BOT" "$CODEX_SHA"; RB_VOUCH_RC=$?
               if [ "$RB_VOUCH_RC" -eq 2 ]; then
                   echo "PR_PHASE pr=$PR status=error reason=codex_vouch_unreadable" >&2; exit 2
               fi
               if [ "$RB_VOUCH_RC" -ne 0 ]; then
                   echo "PR_PHASE pr=$PR status=stopped reason=codex_replies_only_unvouched"
                   echo "Codex's review of $CODEX_SHA carried only replies, and no signoff of yours answers it ($RB_VOUCH_REASON)."
                   # ONLY WHERE A DEADLINE WAS COMPUTED. `rb_phase_vouched` returns
                   # before reading either time when nothing is recorded at all —
                   # the commonest case — and printing `newer than ? … (none) …
                   # (none)` there is noise where the line above already said it.
                   [ -n "$RB_ANSWER_AT" ] && echo "It has to be newer than $RB_ANSWER_AT — the latest of that review (${RB_VOUCH_REVIEW_AT:-none}) and its newest reply (${RB_VOUCH_REPLIES_AT:-none})."
                   echo "Read the comment and record a signoff for that head, or request a review."
                   exit 1
               fi
           else
               echo "PR_PHASE pr=$PR status=stopped reason=codex_verdict_withdrawn"
               echo "The recorded signoff no longer stands ($VERDICT) — a review can be dismissed after it was written."
               echo "Treat the Codex phase as open: request a review before merging or opening the Copilot phase."
               exit 1
           fi ;;
        *) echo "PR_PHASE pr=$PR status=error reason=codex_verdict_unreadable rc=$VERDICT_RC" >&2; exit 2 ;;
    esac
    echo "PR_PHASE pr=$PR state=before-copilot codex-sha=$CODEX_SHA head=$HEAD"
    exit 0
fi
