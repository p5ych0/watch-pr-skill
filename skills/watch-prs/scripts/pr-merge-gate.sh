#!/usr/bin/env -S bash -p
# The merge decision: every gate, evaluated immediately before merging, against
# the head that is merged.
#
#   pr-merge-gate.sh <pr> <codex-sha> <auto-review: yes|no> [reviewers: both|codex-only]
#
# `codex-only` merges on the Codex signoff alone, and requires the head to BE the
# commit Codex signed — a narrower gate than the default, not a looser one.
#
#   0  merged   — the head named in the output is on the base branch
#   1  blocked  — a gate refused; the reason is on stdout
#   3  paused   — a round boundary; the operator decides, this is not a refusal
#   4  queued   — the merge command succeeded but the PR is not MERGED. A merge
#                 queue accepts the request without landing it, and `gh` reports
#                 that as success; the head is not on the base branch yet
#
# WHY THIS EXISTS AS A SCRIPT
#
# It was 291 lines of shell inside a fenced block in `SKILL.md`, pasted into the
# driving session's own shell. Nothing checked it — the suite, `pr-selfcheck.sh`
# and the `macos-shell` CI job all cover `scripts/`, the last of them only while it
# is enabled (#93), and none of them can see shell inside a Markdown file. That is not theoretical here: this block could not
# be PARSED by the bash macOS ships, for fifty review rounds, because an inline
# `[[ … =~ … ]]` pattern containing a parenthesis is a syntax error there. It was
# found by running the suite under bash 3.2, not by reading the document. Issue
# #26, and the second helper moved out of it after `pr-ci-gate.sh`.
#
# WHAT IT DECIDES, in order, each one able to stop the merge on its own:
#
#   (0) the head is resolved ONCE, and everything below is pinned to it
#   (1) each reviewer is clean on the head THAT reviewer judged
#   (2) the delta between those two heads is Copilot fixes only
#   (3) no unresolved review threads, paginated, fail closed
#  (3b) every check on the head is green, not only the required ones
#   (4) the required checks satisfy branch protection
#  (4b) the round boundary has not been reached
#   (5) merge, pinned to the head every gate above was evaluated against
#
# THE PAUSE IS NOT A REFUSAL, and that is why it has its own status. A caller that
# cannot tell 3 from 1 either treats an operator decision as a failure or treats a
# failure as a decision; the round boundary exists precisely so that a human is
# asked before the largest irreversible action this tool takes.
#
# `set -uo pipefail`, NOT `-e`: nearly every probe below reports its answer as an
# exit status, and several of them fail as ordinary operation. See CLAUDE.md
# § Bash conventions.
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
# that prints a forged `merge blocked:` line and exits has already answered the
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
    echo "merge blocked: reason=not_privileged"
    exit 1
fi

set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "merge blocked: reason=lib_dir_unresolvable"; exit 1; }
# THE BOOTSTRAP FAILURES CARRY `reason=` TOKENS, the same ones every other helper
# uses. They were prose here, which reads well and is unreadable to the fixtures:
# `test-pr-identity.sh` asserts the REASON rather than the status, because without
# the guard a script still fails — just further downstream, against the wrong
# repository — and an rc-only assertion passes on the unguarded code.
#
# The loader, loaded the one way it cannot load itself: clear, take that clear's
# status, define a refusing stub, source. An
# exported `rb_load` survives into this shell and an empty `loadlib.sh` still
# sources successfully, so without the clear the first load runs the INHERITED
# function — and a stale loader is what makes every other load look clean.
unset -f rb_load 2>/dev/null || {
    echo "merge blocked: reason=loadlib_stale_definition"; exit 1; }
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
    echo "merge blocked: reason=loadlib_unreadable"; exit 1; }
# `2>&1` on both: `rb_load` reports on stderr, and every diagnostic this gate
# produces is documented as stdout — a caller capturing it would otherwise get
# nothing at all for the failures that happen before anything else can.
# THE FIRST LOAD CARRIES THE SENTINEL, because it is what the preflight used to
# say. An empty `loadlib.sh` leaves the stub, the stub returns 127, and without
# this arm the only trace is a bare exit status — the ordinary-looking empty
# answer `CLAUDE.md` forbids. 127 is the stub's and nothing else's: `rb_load`'s
# own refusals report their own reason and their own status.
rb_load "$_RB_SELF_DIR" recordlib sha_reason "merge blocked:" 2>&1 || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "merge blocked: reason=loadlib_empty"
    exit 1; }
rb_load "$_RB_SELF_DIR" identitylib rb_identity "merge blocked:" 2>&1 || exit 1
# `reason=` LIKE EVERY OTHER HELPER. The identity fixtures read that token rather
# than an exit status, because without the guard these scripts still fail — just
# further downstream, at the first `gh` call made against the wrong repository —
# and an rc-only assertion passes on the unguarded code.
rb_identity || { echo "merge blocked: reason=$RB_IDENTITY_REASON"; exit 1; }

PR="${1:-}"; CODEX_SHA="${2:-}"; AUTO_REVIEW="${3:-}"
case "$PR" in
    ""|*[!0-9]*) echo "merge blocked: the gate needs a PR number (got '$PR')"; exit 1 ;;
esac
# THE CODEX SHA IS VALIDATED HERE AS WELL AS BELOW, because the check below is
# reached only after a successful head lookup — a network round trip made on an
# argument that was never going to be usable.
_why="$(sha_reason "$CODEX_SHA")" || {
    echo "merge blocked: CODEX_SHA is not a full 40-hex sha ($_why: '$CODEX_SHA')"; exit 1; }
# AUTO-REVIEW IS AN ARGUMENT, NOT AN ENVIRONMENT VARIABLE, and that is a lesson
# from the previous extraction rather than a preference: a value ASSIGNED in the
# driving shell without `export` reaches a function and not a child, so a knob
# read from the environment here would silently take its default while the
# operator's terminal showed the value they set. This one decides whether an
# in-flight Codex pass can be ignored, so a silent default is a merge on a verdict
# nobody read. It is required, and an unrecognised value is refused rather than
# assumed to mean `no`.
case "$AUTO_REVIEW" in
    yes|no) ;;
    *) echo "merge blocked: the gate needs auto-review as 'yes' or 'no' (got '$AUTO_REVIEW')"; exit 1 ;;
esac
# WHICH REVIEWERS THIS MERGE RESTS ON. `both` is the default and the norm; the
# operator chooses `codex-only` at the stop that follows a clean Codex phase, and
# it is REFUSED rather than assumed, because "merge on one reviewer" is a decision
# somebody makes and not a state a script drifts into.
REVIEWERS="${4:-both}"
case "$REVIEWERS" in
    both|codex-only) ;;
    *) echo "merge blocked: reviewers must be 'both' or 'codex-only' (got '$REVIEWERS')"; exit 1 ;;
esac
# THE REVIEWER LOGINS COME FROM `recordlib.sh`, which is the one place they are
# written. They were literals here until a second script needed them; the copy that
# drifts is never the one you are looking at, and a login one character wrong
# matches no record at all — so this gate would report "did not return an exact
# clean record" for a reviewer that signed off perfectly.
# BOTH CONSTANTS, EACH THROUGH `rb_load`. Verifying only one leaves the other
# inheritable: a `recordlib.sh` truncated after the first definition passes the
# check, and an exported `RB_COPILOT_BOT` from the environment is then accepted
# as library data — so this would validate a signoff from whatever account that
# variable named. `rb_load` clears before it sources, which is the whole point.
rb_load "$_RB_SELF_DIR" recordlib rb_review_record "merge blocked:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_replies_only_line "merge blocked:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_signoff_answers "merge blocked:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_answer_at "merge blocked:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_review_record_is_about "merge blocked:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "merge blocked:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_COPILOT_BOT "merge blocked:" var 2>&1 || exit 1
CODEX_BOT="$RB_CODEX_BOT"; COPILOT_BOT="$RB_COPILOT_BOT"
# WHERE THE RANGE CHECK LOOKS. The driver derived this once and passed it in; a
# script derives it for itself, and takes the status — a directory retained from a
# failed probe is a merge decision made about the wrong tree.
REPO_DIR="$(git rev-parse --show-toplevel)" || {
    echo "merge blocked: could not resolve the repository root"; exit 1; }

# (0) Resolve the head ONCE, and fail closed on a lookup that printed something
# and then failed — command substitution keeps that stdout, so a plausible SHA
# from a failed fetch would otherwise pass the shape check below.
HEAD_RC=0
HEAD_OID=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) || HEAD_RC=$?
# THROUGH `sha_reason`, like every other place in the plugin that asks what a
# commit SHA is. The shape was written out here as an inline `=~` pattern, which
# duplicated `recordlib.sh` — and the version of that spelling further down could
# not be parsed by bash 3.2 at all.
if [ "$HEAD_RC" -ne 0 ] || ! _head_why="$(sha_reason "$HEAD_OID")"; then
    echo "merge blocked: head lookup failed (rc=$HEAD_RC ${_head_why:-})"; exit 1
fi

# (1) Each reviewer clean on the head that reviewer actually judged.
#
# Copilot is checked on $HEAD_OID — it reviews the current head, by definition of
# the phase. Codex is the awkward one, and BOTH obvious answers are wrong:
#
#   - always $HEAD_OID: the Copilot phase deliberately does not re-run Codex, so
#     its verdict on a Copilot-fix commit is `none` forever and the gate that the
#     phasing exists to support can never pass;
#   - always $CODEX_SHA: if Codex AUTO-REVIEW is on, a Copilot-fix push gets a
#     NEW Codex review on the current head. Validating only the older signoff
#     ignores it — and a body-only CHANGES_REQUESTED leaves no inline thread for
#     the unresolved-thread gate to catch either, so every gate passes while an
#     active request for changes stands.
#
# So: ask about the CURRENT head first, and fall back to the recorded signoff
# only when Codex has genuinely not reviewed this head.
CODEX_HEAD_STATE=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh state "$PR" "$CODEX_BOT" "$HEAD_OID"); CODEX_STATE_RC=$?
# ONLY rc 0 is an answer. A wrapper or a replaced helper can print a plausible
# `state=none` and exit with something other than the documented 2 — and this
# branch decides whether to fall back to the older signoff, so a bad read here
# merges on a Codex state that was never trusted.
if [ "$CODEX_STATE_RC" -ne 0 ]; then
    echo "merge blocked: could not read Codex's state on the current head (rc=$CODEX_STATE_RC)"; exit 1
fi
# PARSED, not substring-matched. A truncated or wrapped line that merely CONTAINS
# `state=none` would otherwise send the gate down the fallback path — and with a
# current-head body-only CHANGES_REQUESTED there is no thread for the unresolved
# gate to catch, so the merge would pass on a state that was never read.
# The WHOLE record, not the last `state=` token: rc-0 noise such as
# `warning: cached state=none` would otherwise pass and take the fallback path.
# THE PATTERN LIVES IN A VARIABLE: Bash 3.2 cannot parse a `[[ =~ ]]` whose pattern
# contains a parenthesis written inline, and this block runs in the operator's own
# shell — which on macOS is that bash.
# THROUGH `recordlib.sh`, because this shape was written out here and in
# `pr-watch.sh` and was missing from `pr-phase-state.sh` — the duplication that
# library exists to end. #126.
if rb_review_record "$CODEX_HEAD_STATE" state; then
    CODEX_STATE="$RB_REC_VALUE"
else
    echo "merge blocked: Codex head-state line is unparseable ('$CODEX_HEAD_STATE')"; exit 1
fi
# NOTHING MAY FOLLOW THE VALUE on this question. The library returns the tail
# rather than accepting it, because what may follow differs per question — a
# `verdict` has a grammar of its own — and swallowing it centrally would accept
# any field anyone ever appends.
if [ -n "$RB_REC_TAIL" ]; then
    echo "merge blocked: Codex head-state line has trailing text ('$CODEX_HEAD_STATE')"; exit 1
fi
# The record has to be ABOUT what was asked. A well-formed line is not the same
# as an answer: a misrouted wrapper or a stale cache returning `pr=… sha=…
# reviewer=… state=none` for another PR, another reviewer, or an older head
# matched the shape above and sent the gate down the `none` fallback — merging on
# the recorded signoff while Codex actually had a body-only CHANGES_REQUESTED on
# this head, which leaves no thread for the unresolved-thread gate to catch.
#
# Compared as STRINGS, not with `=~`: `$CODEX_BOT` ends in `[bot]`, which a regex
# reads as a character class.
if ! rb_review_record_is_about "$PR" "$CODEX_BOT" "$HEAD_OID"; then
    echo "merge blocked: Codex head-state record is about something else ('$CODEX_HEAD_STATE')"; exit 1
fi
case "$CODEX_STATE" in
    none|pending|reviewed|blocked|dismissed) ;;
    *) echo "merge blocked: unknown Codex head state ('$CODEX_STATE')"; exit 1 ;;
esac
case "$CODEX_STATE" in
    none)
        # `none` MEANS TWO DIFFERENT THINGS, and only one of them is permission.
        #
        # With auto-review OFF, nothing asked Codex about this head, so the
        # recorded signoff is the authority and step (2) proves the delta is
        # Copilot-only. That is the case this branch was written for.
        #
        # With auto-review ON, every Copilot-fix push ALSO queues a Codex pass —
        # and Codex exposes no review record while that pass is queued or running,
        # which reads here as exactly the same `none`. So the gate fell back to
        # the pre-Copilot signoff and could merge before the in-flight pass
        # reported anything, including a body-only CHANGES_REQUESTED that leaves
        # no unresolved thread for the other gates to catch. "Not yet answered" is
        # not "nothing to answer".
        if [ "$AUTO_REVIEW" = yes ]; then
            echo "merge blocked: auto-review queues a Codex pass on every push and this head has no verdict yet — wait for it rather than falling back to the signoff on $CODEX_SHA"
            exit 1
        fi
        CODEX_EFFECTIVE_SHA="$CODEX_SHA"
        CODEX_VERDICT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$CODEX_BOT" "$CODEX_SHA"); CODEX_RC=$? ;;
    *)
        # Codex HAS judged this head — that judgement wins over the older one,
        # whatever it says. Record WHICH sha the verdict describes: step (2) has
        # to measure from the same commit, or it would demand Copilot trailers
        # across a range Codex has already reviewed in full.
        CODEX_EFFECTIVE_SHA="$HEAD_OID"
        CODEX_VERDICT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$CODEX_BOT" "$HEAD_OID"); CODEX_RC=$? ;;
esac
# $HEAD_OID is passed explicitly rather than letting the call resolve the head: a
# push landing mid-gate would otherwise leave a verdict describing an older
# commit while step 5 pins and merges the newer one.
# ── A REOPENED PHASE MUST NOT BE MERGEABLE FROM A STALE SESSION ────────────
#
# When the operator asks for another Codex pass on an unchanged head, the durable
# revocation is the ONLY thing that records it: GitHub still exposes the old clean
# verdict until the replacement pass reports. A session that kept the old
# `CODEX_SHA` — or a second one running concurrently — would satisfy every verdict
# check below and merge the phase that was explicitly reopened.
#
# So the record is consulted, and it is consulted for a CONTRADICTION rather than
# for permission. Absent is not a contradiction: plenty of merges predate the
# record and the caller's sha came from somewhere. What blocks is the record
# saying something ELSE — revoked, or naming a different commit — and a record
# that cannot be read at all.
# ONE CHECK, BOTH REVIEWERS. Written out twice it was written out once: the Codex
# half landed and the Copilot half did not, and the hole it leaves is identical —
# a Copilot phase reopened on an unchanged head leaves its old signoff naming that
# same head, so a resumed or concurrent session merges on a verdict that was
# withdrawn. See CLAUDE.md § Tests on rules that apply to more than one caller.
signoff_contradicts() {   # signoff_contradicts <reviewer> <sha the merge will use>
    local who="$1" want="$2" line rc=0 got
    line=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$who" 2>&1) || rc=$?
    case "$rc" in
        0) got="${line##*sha=}"
           if [ "$got" != "$want" ]; then
               echo "merge blocked: the recorded $who signoff names ${got:0:7}, not the ${want:0:7} this merge was asked to use"
               return 1
           fi
           return 0 ;;
        1) case "$line" in
               *reason=revoked*)
                   # "OPEN", NOT "REOPENED". `pr-copilot-phase.sh open` posts this
                   # revocation on every entry, including the first, where there
                   # was no signoff to revoke — so on a first entry the record
                   # said a phase had been reopened that had never been entered.
                   # The BEHAVIOUR is right either way and is load-bearing: see
                   # the case in `test-pr-merge-gate.sh` where a head with no
                   # Copilot record and a stale clean verdict merges. Only the
                   # wording was false. #36.
                   #
                   # SAY THE OPEN PASS AND NOTHING ELSE. The first attempt kept a
                   # second clause naming the revocation, which is the very event
                   # that did not happen on a first entry — a true opening clause
                   # does not make the sentence true.
                   echo "merge blocked: a $who pass is open on this PR and no signoff for it has been recorded"
                   return 1 ;;
               *) return 0 ;;   # nothing recorded; the caller's sha is not contradicted
           esac ;;
        *) echo "merge blocked: could not read the $who signoff record (rc=$rc): $line"; return 1 ;;
    esac
}
# THE OTHER DIRECTION, AND IT IS NOT THE SAME QUESTION. `signoff_contradicts`
# answers "does a record disagree with this sha", and NOTHING RECORDED is not a
# disagreement — so it passes. That is right where a signoff is a cross-check, and
# wrong where one is the authority: the replies-only path below merges BECAUSE an
# operator vouched, so absence there must refuse.
# A NON-ZERO STATUS THAT IS STILL AN ANSWER. `verdict` exits 1 for a review whose
# comments are all replies, the same as for one with findings — the STATUS cannot
# tell them apart, only the record can. The rc gate below would refuse it before
# the record is ever compared, so it asks this instead; the PROOF that an operator
# vouched stays where the records are checked in full.
replies_only_line() {   # replies_only_line <reviewer> <sha> <line> ; 0 if that shape
    # THE RULE IS `recordlib.sh`'s. It lived here alone, and `pr-phase-state.sh`
    # reported the same review as a dismissal — sending a resumed session to
    # reopen a phase the operator had already answered, which is the deadlock this
    # escape exists to end, one stage earlier. #125.
    rb_replies_only_line "$3" "$PR" "$1" "$2"
}
rc_answered() {   # rc_answered <reviewer> <sha> <rc> <line> ; 0 if the gate may read on
    [ "$3" -eq 0 ] && return 0
    [ "$3" -eq 1 ] && replies_only_line "$1" "$2" "$4" && return 0
    return 1
}
signoff_vouches() {   # signoff_vouches <reviewer> <sha> <verdict-line> ; 0 only on a positive record
    # THE RECORDS ARE READ HERE AND THE RULE IS THE LIBRARY'S. Both callers of the
    # escape fetch with their own error prefixes and their own statuses; what they
    # share is what "this signoff answers that review" MEANS. #125.
    local who="$1" want="$2" verdict_line="$3" line rc=0 rat arc=0
    line=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-signoff.sh "$PR" "$who" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || return 1
    # WHICH REVIEW THIS IS, BEFORE ANY OF ITS TIMES ARE READ. A verdict record
    # carries no review id, so a SECOND replies-only review with the same finding
    # count, submitted on the same head, serialises byte-for-byte identically to
    # the first — and a binding that compares only the verdict accepts the old
    # review's timestamps for the new one, letting a signoff that predates it
    # merge. Dismissal is the visible case; a same-shaped replacement is not.
    local rid1 ridrc=0
    rid1=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh review-id "$PR" "$who" "$want") || ridrc=$?
    # THE SHAPE, NOT JUST NON-EMPTY. A replaced or wrapped helper exiting 0 with
    # the same word on both reads is a STABLE value that identifies nothing — the
    # two reads then agree and a same-shaped replacement is invisible again, which
    # is the defect this id exists to close.
    case "$rid1" in
        ""|*[!0-9]*) echo "merge blocked: could not read which $who review is authoritative on ${want:0:7} (rc=$ridrc, id='$rid1')"; return 1 ;;
    esac
    [ "$ridrc" -eq 0 ] || {
        echo "merge blocked: could not read which $who review is authoritative on ${want:0:7} (rc=$ridrc)"; return 1; }
    rat=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh review-at "$PR" "$who" "$want") || arc=$?
    [ "$arc" -eq 0 ] || { echo "merge blocked: could not read when $who's review landed (rc=$arc)"; return 1; }
    # AND WHEN THE NEWEST REPLY LANDED, which is a different moment. This verdict
    # is produced by the COMMENTS on that review, and one added afterwards does not
    # move the review's `submitted_at` — so ordering against the review alone let a
    # signoff recorded between the review and a retracting reply vouch over a reply
    # nobody read. #129.
    #
    # 1 IS AN ANSWER: no review, no comments, or a verdict that arrived as an issue
    # comment and carries none. Only 2 is a read that failed.
    local pat prc=0
    pat=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh replies-at "$PR" "$who" "$want") || prc=$?
    # ABSENCE HAS TO BE SILENT. A wrapper that prints a partial answer and then
    # returns the documented absence status leaves a timestamp on stdout that this
    # arm would discard — and if it is newer than the signoff, discarding it is
    # exactly the reply that gets merged over.
    case "$prc" in
        0) ;;
        1) [ -z "$pat" ] || {
               echo "merge blocked: $who's reply probe reported no replies and printed one anyway ('$pat')"; return 1; }
           pat="" ;;
        *) echo "merge blocked: could not read when $who's newest reply landed (rc=$prc)"; return 1 ;;
    esac
    # THE TWO REFUSALS ARE DIFFERENT ANSWERS, and both block here — but they do not
    # say the same thing. `1` is "neither channel has anything for a signoff to
    # answer"; `2` is a timestamp of a shape nothing can place, which is a probe
    # that exited 0 with something it did not mean, and telling the operator there
    # is nothing to answer sends them looking in the wrong place.
    local aarc=0
    # BOTH ABSENT IS IMPOSSIBLE HERE, not merely uninformative. The id above is a
    # numeric one, so a submitted review exists — and every submitted review has a
    # validated `submitted_at`, which `review-at` reports. Two silent probes in
    # THIS context therefore mean a read failed, and saying "there is nothing to
    # answer" sends the operator to look at a review that is plainly there.
    rb_answer_at "$rat" "$pat" || aarc=$?
    case "$aarc" in
        0) ;;
        1) echo "merge blocked: $who's review on ${want:0:7} is recorded but neither its time nor its newest reply could be read"; return 1 ;;
        *) echo "merge blocked: when $who's review or newest reply landed could not be placed in time ('$rat' / '$pat')"; return 1 ;;
    esac
    # AND THE VERDICT AGAIN, BOUND TO THE DEADLINE JUST COMPUTED. The two time
    # probes are separate calls: a review dismissed after `review-at` returns and
    # before `replies-at` runs leaves the second reading a stable — but dismissed —
    # snapshot, so the deadline describes a review that no longer authorises
    # anything while the replies-only line this vouch is answering was fetched
    # before any of it. Each probe re-checks ITSELF; nothing bound them together.
    #
    # THE VERDICT IS WHAT BINDS THEM, because it is the thing the escape acts on:
    # identical means the review that produced it is still the authoritative one.
    local vagain vgrc=0
    vagain=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$who" "$want"); vgrc=$?
    # AND THE REPLY TIME AGAIN. The id and the verdict can BOTH be unchanged while
    # the replies move: a reply added after `replies-at` returned and another
    # deleted before this read leaves the comment count — and therefore the
    # serialised verdict — exactly as it was. Only the reply time itself shows it.
    local pat2 pat2rc=0
    pat2=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh replies-at "$PR" "$who" "$want") || pat2rc=$?
    case "$pat2rc" in
        0) ;;
        1) [ -z "$pat2" ] || { echo "merge blocked: $who's reply probe reported no replies and printed one anyway ('$pat2')"; return 1; }
           pat2="" ;;
        *) echo "merge blocked: could not re-read when $who's newest reply landed (rc=$pat2rc)"; return 1 ;;
    esac
    if [ "$pat2" != "$pat" ]; then
        echo "merge blocked: $who's replies on ${want:0:7} moved while its timestamps were being read ('$pat' then '$pat2')"
        return 1
    fi
    local rid2 rid2rc=0
    rid2=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh review-id "$PR" "$who" "$want") || rid2rc=$?
    case "$rid2" in
        ""|*[!0-9]*) rid2="" ;;
    esac
    if [ "$vgrc" -ne 1 ] || [ "$vagain" != "$verdict_line" ] \
       || [ "$rid2rc" -ne 0 ] || [ -z "$rid2" ] || [ "$rid2" != "$rid1" ]; then
        echo "merge blocked: $who's review on ${want:0:7} changed while its timestamps were being read"
        return 1
    fi
    rb_signoff_answers "$line" "$RB_ANSWER_AT" "$PR" "$who" "$want" && return 0
    case "$RB_VOUCH_REASON" in
        other_head|other_pr|other_reviewer) ;;   # a record about something else; not this gate's to explain
        signoff_malformed) echo "merge blocked: the $who signoff record is not one this gate can read ('$line')" ;;
        no_review)         echo "merge blocked: $who has no submitted review on ${want:0:7}, so there is nothing for a signoff to answer" ;;
        review_untimed)    echo "merge blocked: when $who's review landed could not be read ('$rat')" ;;
        # NAMED AS THE CONVERSATION, not as the review. The deadline is the LATER
        # of the two, so a signoff that IS newer than the review can still fail
        # here — and saying "the review at <T>" then points the operator at an
        # event they have already answered, with a timestamp that is not the
        # review's. Both are printed, so which one moved is visible.
        not_after)         echo "merge blocked: the $who signoff was not recorded after ${RB_ANSWER_AT} — the latest of that review (${rat:-none}) and its newest reply (${pat:-none}), so it cannot be an answer to it" ;;
        *)                 echo "merge blocked: the $who signoff does not answer the review on ${want:0:7}" ;;
    esac
    return 1
}
signoff_contradicts "$CODEX_BOT" "$CODEX_SHA" || exit 1

# ── CODEX-ONLY IS A REAL OPTION, AND IT COSTS SOMETHING ────────────────────
#
# `SKILL.md` offers "merge now on Codex's signoff alone" when the Codex phase
# closes. That offer was not reachable: this gate required an exact clean COPILOT
# record on the head, and with no Copilot review requested there is none — so the
# menu item existed and could never be chosen.
#
# What makes it safe is not skipping a check but replacing it with a stricter one.
# The two-reviewer path allows the head to have advanced past Codex's signoff,
# because step (2) proves every commit since carries a `Review-Phase: copilot`
# trailer. With no Copilot phase there are no such commits, and nothing else
# licenses the delta — so THE HEAD MUST BE EXACTLY THE COMMIT CODEX SIGNED. That
# is a narrower gate than the two-reviewer one, not a looser one.
if [ "$REVIEWERS" = codex-only ]; then
    if [ "$HEAD_OID" != "$CODEX_SHA" ]; then
        echo "merge blocked: codex-only merges must be pinned to the reviewed commit, and the head has moved past it (head=${HEAD_OID:0:7} signed=${CODEX_SHA:0:7}). Request a review of this head, or open the Copilot phase."
        exit 1
    fi
    if ! rc_answered "$CODEX_BOT" "$CODEX_EFFECTIVE_SHA" "$CODEX_RC" "$CODEX_VERDICT"; then
        echo "merge blocked: codex=$CODEX_RC (1 = not clean, 2 = could not tell)"; exit 1
    fi
    COPILOT_VERDICT=""; COPILOT_RC=0
else
    # …AND COPILOT'S RECORD, ON THE HEAD BEING MERGED. Only in this mode: there is
    # no Copilot phase to reopen in the other one.
    signoff_contradicts "$COPILOT_BOT" "$HEAD_OID" || exit 1
    COPILOT_VERDICT=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh verdict "$PR" "$COPILOT_BOT" "$HEAD_OID"); COPILOT_RC=$?
    if ! rc_answered "$CODEX_BOT" "$CODEX_EFFECTIVE_SHA" "$CODEX_RC" "$CODEX_VERDICT" \
       || ! rc_answered "$COPILOT_BOT" "$HEAD_OID" "$COPILOT_RC" "$COPILOT_VERDICT"; then
        echo "merge blocked: codex=$CODEX_RC copilot=$COPILOT_RC (1 = not clean, 2 = could not tell)"; exit 1
    fi
fi
# This is the final merge permission, so the exit codes are not taken on trust:
# an rc-swallowing wrapper or a truncated helper line would otherwise turn an
# unreadable verdict into a clean signoff. Require the exact record from BOTH.
#
# Each record must name ITS OWN reviewer and the sha that reviewer actually
# judged — Codex on $CODEX_EFFECTIVE_SHA, Copilot on $HEAD_OID. Leaving `pr`,
# `sha` and `reviewer` as wildcards meant one clean record satisfied the check
# for either variable: a clean Copilot line, or a clean line for a stale sha,
# passed as Codex's signoff and the gate merged without ever proving the named
# reviewer approved the commit being merged.
#
# THE SHAPE COMES FROM `recordlib.sh` AND THE COMPARISONS ARE LITERAL. This used
# to REBUILD the expected line and compare against it, which is a second
# definition of what a record is — written as a string, so no scan for a regex
# would ever find it — and it pinned the sha to seven hex where every other caller
# accepts seven to forty. The parse and the identity check are the library's now;
# what stays here is the VALUE and the TAIL, because what may follow a value
# differs per question and this gate is the last place to be relaxed about it.
#
# Every comparison that remains is a literal string one — `[ = ]`, not
# `[[ == ]]` — because the bot logins end in `[bot]` and `[[ ]]` would read that
# as a character class on the right-hand side.
# Copilot's record is required in the two-reviewer mode and absent by definition
# in the other; the LIST changes rather than the checking.
#
# POSITIONAL PARAMETERS, NOT A PIPELINE. `printf … | while read` puts the loop in
# a SUBSHELL, where the `exit 1` below would end the subshell and let the gate
# carry on to the merge — a refusal that does not refuse. The arguments were read
# into variables at the top, so `set --` has nothing left to clobber.
set -- "$CODEX_BOT|$CODEX_EFFECTIVE_SHA|$CODEX_VERDICT"
[ "$REVIEWERS" = codex-only ] || set -- "$@" "$COPILOT_BOT|$HEAD_OID|$COPILOT_VERDICT"
for SPEC in "$@"; do
    V_WHO="${SPEC%%|*}"; V_REST="${SPEC#*|}"; V_SHA="${V_REST%%|*}"; V_LINE="${V_REST#*|}"
    # THROUGH `recordlib.sh` RATHER THAN REBUILT. Comparing against a line this
    # gate assembled is a second definition of what a record is — one written as a
    # string, so no scan for a regex would ever find it — and it pinned the sha to
    # seven hex, which every other caller does not.
    V_OK=1
    rb_review_record "$V_LINE" verdict || V_OK=0
    [ "$V_OK" -eq 0 ] || rb_review_record_is_about "$PR" "$V_WHO" "$V_SHA" || V_OK=0
    [ "$V_OK" -eq 0 ] || [ "$RB_REC_VALUE" = clean ] || V_OK=0
    # THE TAIL IS THIS GATE'S RULE, spelled out rather than made optional: a
    # trailing `.*` accepts any field anyone ever appends.
    [ "$V_OK" -eq 0 ] || [ "$RB_REC_TAIL" = " findings=0" ] || V_OK=0
    if [ "$V_OK" -ne 1 ]; then
        # THE ONE VERDICT AN OPERATOR CAN ANSWER FOR. A review whose comments are
        # ALL replies says `source=replies-only`: there is nothing for
        # `pr-findings.sh` to list and it is not a signoff, because a verdict
        # followed by explanation and a verdict followed by a retraction read the
        # same. The loop stops and a human reads the comment — and until now that
        # was where it ENDED. The verdict could never become clean, no round could
        # close, and this gate blocked forever: a deadlock traded for a permanent
        # pause.
        #
        # So the operator's own record answers it. `pr-signoff.sh` already carries
        # a head-bound statement from an OWNER, MEMBER or COLLABORATOR, and
        # `signoff_contradicts` has already proved that record names THIS sha —
        # the check runs above, for every reviewer, before this loop.
        #
        # NARROW ON PURPOSE. It applies only to `source=replies-only`, never to a
        # review with findings, an unreadable state, or a missing verdict: those
        # are not questions an operator was asked. A signoff is not a way to merge
        # past a reviewer.
        if replies_only_line "$V_WHO" "$V_SHA" "$V_LINE"; then
            # AND THE RECORD MUST BE THERE. Absence is not permission.
            if signoff_vouches "$V_WHO" "$V_SHA" "$V_LINE"; then
                echo "note: $V_WHO left only replies on ${V_SHA:0:7}; merging on the signoff an operator recorded for that head after reading them"
            else
                echo "merge blocked: $V_WHO left only replies on ${V_SHA:0:7} and no operator has recorded a signoff for that head — read the reply and record one, or fix what it says and push"
                exit 1
            fi
        else
            echo "merge blocked: $V_WHO did not return an exact clean record for ${V_SHA:0:7} ('$V_LINE')"; exit 1
        fi
    fi
done

# (2) …and the delta between them is Copilot fixes only.
#
# This is what makes checking Codex on an OLDER sha safe: the range proves the
# head advanced from it only through commits carrying `Review-Phase: copilot`,
# reachable from it. Without this step an older signoff would be an open door.
#
# It measures from $CODEX_EFFECTIVE_SHA — the commit the verdict above actually
# describes — not from $CODEX_SHA. When Codex has reviewed the current head, the
# two are the same and there is nothing to prove; measuring from the stale
# recorded sha instead would demand Copilot trailers across a range Codex has
# already reviewed in full, and block a merge both reviewers just approved.
if [ "$HEAD_OID" != "$CODEX_EFFECTIVE_SHA" ]; then
    /usr/bin/env bash -p "$_RB_SELF_DIR"/pr-merge-range.sh "$CODEX_EFFECTIVE_SHA" "$HEAD_OID" "$REPO_DIR"; RANGE=$?
    if [ "$RANGE" -ne 0 ]; then
        echo "merge blocked: range check returned $RANGE (1 = an untagged commit, or the Codex-reviewed SHA is not an ancestor; 2 = could not inspect)"; exit 1
    fi
fi

# (3) No unresolved threads, paginated, fail closed.
# SEEN holds every cursor already requested, RS-delimited, so a cycle of any
# length is caught. Comparing only against the previous cursor caught an
# immediate self-loop but not `null → A → B → A → B …`, which alternates forever.
UNRESOLVED=0; CURSOR=null; OK=1; RS=$'\x1e'; SEEN="${RS}null${RS}"
while :; do
  PAGE=$(gh api --hostname "$HOST" graphql -F number="$PR" -f owner="$OWNER" -f repo="$REPO" -F cursor="$CURSOR" -f query='
    query($owner:String!,$repo:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){
      reviewThreads(first:100, after:$cursor){ pageInfo{hasNextPage endCursor} nodes{isResolved} }}}}' 2>/dev/null) || { OK=0; break; }
  # A GraphQL 200 can carry BOTH `errors` and a structurally valid `data`. The
  # partial data passes every shape check below while silently omitting threads,
  # and this gate's answer is `UNRESOLVED=0` — merge permission, taken with
  # `--admin`. So a response carrying errors is not a response.
  echo "$PAGE" | jq -e 'has("errors") | not' >/dev/null 2>&1 || { OK=0; break; }
  echo "$PAGE" | jq -e '.data.repository.pullRequest.reviewThreads' >/dev/null 2>&1 || { OK=0; break; }
  # `nodes:{}` and `nodes:[{}]` both make a naive count return 0 with status 0,
  # and 0 here is merge permission. Require an array of objects with a boolean
  # `isResolved` before counting anything.
  CNT=$(echo "$PAGE" | jq '
      .data.repository.pullRequest.reviewThreads.nodes as $n
      | if ($n | type) != "array"
           or any($n[]; type != "object" or (.isResolved | type) != "boolean")
        then error("malformed nodes")
        else [ $n[] | select(.isResolved == false) ] | length end') || { OK=0; break; }
  UNRESOLVED=$((UNRESOLVED + CNT))
  # The pagination state is validated, not assumed: a missing or malformed
  # `hasNextPage` treated as "last page" stops the walk early, and on a PR with
  # more than 100 threads the gate would then see unresolved=0 and merge.
  HAS_NEXT=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage') || { OK=0; break; }
  case "$HAS_NEXT" in
    false) break ;;
    true)  ;;
    *) OK=0; break ;;
  esac
  # The STATUS is taken, like the count and hasNextPage parses above it. `jq` can
  # print a plausible cursor and then exit non-zero, and command substitution
  # keeps that output — so an untrusted parse would have driven the next page
  # request while OK stayed 1, and the walk could still end at UNRESOLVED=0.
  NEXT=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor') || { OK=0; break; }
  { [ -n "$NEXT" ] && [ "$NEXT" != "null" ]; } || { OK=0; break; }
  # The cursor must be one this walk has NEVER requested. A stale or malformed
  # page can report `hasNextPage: true` while returning a cursor already used,
  # and the gate then walks that cycle forever. A hang is worse than a blocked
  # merge: nothing times out and the operator waits on a gate that never answers.
  case "$SEEN" in *"$RS$NEXT$RS"*) OK=0; break ;; esac
  SEEN="$SEEN$NEXT$RS"
  CURSOR="$NEXT"
done
if [ "$OK" -ne 1 ] || [ "$UNRESOLVED" -gt 0 ]; then echo "merge blocked: unresolved=$UNRESOLVED ok=$OK"; exit 1; fi

# (3b) EVERY check on the head being merged, not only the required ones.
#
# The round loop's gate lives at the push sites, and a PR whose reviews were clean
# from the start never pushed anything — so nothing had looked at its checks by
# the time it arrived here, and the required-checks probe below is blind to a
# failing OPTIONAL check. A repository with no branch protection has no required
# checks at all, which makes that probe blind to everything.
#
# The same gate, on the head the merge is pinned to.
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-ci-gate.sh "$PR" "$HEAD_OID" || { echo "merge blocked: the head's checks are not green"; exit 1; }

# (4) Required checks green — through the same helper the round loop uses.
#
# This was about seventy lines inline here, and the round loop needed the same
# question answered. A second copy is the defect issues #11 and #18 were both
# opened for, so both call `pr-ci-state.sh` and `--required` is what separates the
# two questions: this gate asks whether branch protection is satisfied; the round
# gate asks whether the commit just pushed is broken, where a failing
# non-required check still counts.
#
# In the default mode the merge below uses `--admin`, which bypasses branch
# protection, so this probe is the only thing standing between a failed read and
# an unchecked merge — which is why anything that is not an explicit green or an
# explicit "nothing configured" blocks.
#
# "NONE CONFIGURED" IS NOT "COULD NOT TELL". `gh pr checks --required` exits
# non-zero when the branch has no required checks at all, not because anything
# failed. Treating that as unreadable blocked the merge on every repository
# without branch protection, permanently — not a fail-closed guard but a gate that
# never opens, and it was found by trying to merge rather than by reading the
# code. The helper distinguishes the two and reports 4 for it.
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-ci-state.sh "$PR" --required; CHECKS_RC=$?
case "$CHECKS_RC" in
    0) ;;
    4) echo "note: no required checks configured on this branch; the checks gate has nothing to assert" ;;
    1) echo "merge blocked: a required check is not green"; exit 1 ;;
    3) echo "merge blocked: the required checks have not finished"; exit 1 ;;
    *) echo "merge blocked: the required-checks probe failed (rc=$CHECKS_RC)"; exit 1 ;;
esac

# (4b) The round boundary, once more. A clean Copilot verdict on the threshold-th
# head would otherwise walk straight into a merge without the operator being
# asked at all — the pause is about committing to an outcome, and merging is the
# largest one available.
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-round-count.sh "$PR" "$COPILOT_BOT"; MERGE_ROUNDS_RC=$?
case "$MERGE_ROUNDS_RC" in
    0) ;;
    3) echo "PAUSE: round boundary reached. Decide with the operator before merging: merge now, leave it open, or close this PR and start over with a better approach. Say what the rounds have been ABOUT, not just how many"
       exit 3 ;;
    *) echo "merge blocked: could not establish the round count (rc=$MERGE_ROUNDS_RC)"; exit 1 ;;
esac

# (5) Merge, PINNED to the head every gate above was evaluated against.
#
# `--admin` by default, and that is a deliberate trade rather than an oversight.
#
# What it costs: every gate above is evaluated by this script, at a point in
# time, against data fetched a moment earlier, and `--match-head-commit` only
# proves the HEAD has not moved since. It says nothing about the *mutable*
# conditions — a review can be submitted, dismissed, or turned into a body-only
# CHANGES_REQUESTED in the window between the last probe and this call, none of
# which changes the head. `--admin` merges with administrator privileges
# *because* the PR does not meet requirements, so it is exactly what discards
# GitHub's own evaluation of those conditions at merge time. That window stays
# open in the default mode.
#
# Why it is still the default: branch protection normally requires an approving
# review from another account, and neither reviewer here is one — a Codex or
# Copilot review does not satisfy "required approvals". For the solo maintainer
# this plugin is built around, dropping `--admin` does not tighten the gate, it
# removes the merge path entirely, on every PR. A tool whose happy path cannot
# complete is a worse failure than a seconds-wide race in a repository where
# nobody else is reviewing.
#
# The trade is recorded on the base ref, in
# `docs/decisions/2026-08-06-merge-admin-default.md`, so it is a decision a
# reviewer can weigh rather than an unaddressed defect.
#
# REVIEW_MERGE_STRICT=1 takes the other side: GitHub evaluates reviews, checks
# and conversations itself, atomically, which is the only place that race can
# actually be closed. Set it where the repository has protection rules that the
# loop can genuinely satisfy — a team repo, or required checks with no required
# human approval. If GitHub then refuses, the merge does not happen and the
# operator decides, which is the point.
ADMIN=--admin
[ "${REVIEW_MERGE_STRICT:-}" = "1" ] && ADMIN=""
# THE SLUG IS QUOTED, and `$ADMIN` deliberately is not. The slug is one word that
# must stay one word whatever an origin URL contains; `$ADMIN` is either `--admin`
# or NOTHING, and quoting it would pass an empty argument to `gh` in strict mode.
# The two look alike and want opposite treatment, which is why this says so.
if ! gh pr merge "$PR" --repo "$HOST/$OWNER/$REPO" --squash --delete-branch $ADMIN \
       --match-head-commit "$HEAD_OID"; then
    echo "merge blocked: head moved after the gates ran, branch protection refused (strict mode), or the merge failed."; exit 1
fi
# A SUCCESSFUL `gh pr merge` IS NOT NECESSARILY A MERGE. Where the base branch
# uses a merge queue, `gh` reports success for ADDING the PR to that queue — its
# own help says so — and the PR can leave the queue later without ever landing.
# Printing `merged` there tells the driver the work is finished while the head is
# not on the base branch, which is the one claim this script exists to make
# truthfully. `--admin` bypasses the queue, so this is reachable exactly in the
# mode an operator chose for SAFETY.
#
# So the state is read back rather than inferred from an exit status.
MERGED_STATE=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json state --jq '.state' 2>/dev/null); STATE_RC=$?
if [ "$STATE_RC" -ne 0 ]; then
    echo "merge queued or unconfirmed: the merge command succeeded but the PR state could not be read (rc=$STATE_RC); confirm before treating $HEAD_OID as merged"
    exit 4
fi
case "$MERGED_STATE" in
    MERGED) echo "merged $HEAD_OID" ;;
    *) echo "merge queued: the merge command succeeded but the PR is $MERGED_STATE, not MERGED — a merge queue accepts the request without landing it. Do not treat $HEAD_OID as merged."
       exit 4 ;;
esac