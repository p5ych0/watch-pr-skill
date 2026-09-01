#!/usr/bin/env -S bash -p
# Close a review round: push the fixes, prove the head is green, post the summary
# and request the next pass.
#
#   pr-close-round.sh gate <pr> <reviewer-login> <summary-file> <auto-review: yes|no> <head-file> <prior-file>
#   pr-close-round.sh post <pr> <reviewer-login> <summary-file> <auto-review> <head-file> <prior-file>
#
# BOTH STAGES TAKE THE SAME <head-file>: `gate` writes the head it proved into it,
# `post` reads it back. The head itself in that position is the pre-#202 form and
# is refused by name.
#
# AND THE SAME <prior-file>, WHICH IS THE OTHER VALUE THAT HAS TO CROSS. `post`
# writes the review baseline into it, and the driver's watch reads it back. It
# travelled in the `PR_ROUND_CLOSED` record before, which meant the driving shell
# captured this script's stdout, ran `sed` over it, checked the record was there,
# checked it carried the field, and cut the value out with `${rec##* prior-review=}`
# — twelve executable lines in the one shell nothing can harden, to receive a value
# the file mechanism beside it already hands over. The driver reads the FILE now and
# nothing else; the record still carries the baseline, for whoever is reading the
# terminal, and it is no longer parsed by anything. #234, #235.
#
#   0  gated/closed — `gate`: the head is pushed and green, and the threads may
#                     now be answered. `post`: the summary is posted and the next
#                     review is requested
#   1  stopped  — the reason is on stdout; the round is NOT closed
#   3  paused   — a round boundary. NOT a refusal: the operator decides
#
# WHY TWO STAGES, AND WHY THE THREADS GO BETWEEN THEM
#
# Answering and RESOLVING the threads belongs after the checks on the pushed head
# and before the summary — and that is not a detail of presentation, it is the
# same irreversibility rule the auto-review ordering below is built on. A resolved
# thread cannot be taken back. Resolve before the gate and a round that then fails
# to push, or pushes red, has already recorded findings as answered on a commit
# that never landed or never built; and with auto-review ON the pass the push
# starts reads threads that are already resolved, so it re-reviews with the
# findings marked handled and no summary saying what handled them.
#
# THE MODEL WRITES THOSE REPLIES, so this cannot be one process: the replies are
# per-finding prose, the reaction is a judgement (👍/👎), and neither can be
# derived from anything on this command line. `gate` runs the half that must
# precede them, `post` runs the half that must follow, and `post` re-proves the
# head has not moved in between rather than trusting that it did not.
#
# The recipes this replaced carried the boundary as a comment — `# reply + resolve
# threads here`, placed after the gate in BOTH of them. Extracting them without
# the marker left the driver's own checklist as the only ordering, and that runs
# before the push. Restoring it is what this split is for.
#
# WHY THIS EXISTS AS A SCRIPT
#
# It was two recipes in `SKILL.md`, 56 and 191 lines, doing the same job in
# different ORDERS — and the ordering is the whole content. Nothing executed
# either of them. Issue #26.
#
# THE TWO ORDERS, AND WHY THEY DIFFER:
#
#   auto-review OFF — the `@codex review` mention is the trigger, so it can carry
#     the summary in one comment. Nothing is queued until that comment is posted,
#     which means the round can be closed before anything is requested.
#
#   auto-review ON — the PUSH is the trigger, so a pass starts before anything
#     here can post or resolve. The ordering is then decided by what is
#     IRREVERSIBLE: push first, prove the checks, and close afterwards.
#
#     This sequence used to close first and push last, so the pass the push
#     started would find the threads resolved and the summary in place. That
#     cannot be gated: by the time the checks on the pushed commit can be
#     consulted, the threads are resolved and the summary posted, and neither can
#     be taken back. A later "this round is not closed" comment is a record, not a
#     retraction — and is itself a call that can fail.
#
#     THE COST IS REAL AND IS NOT HIDDEN: the pass the push starts reads open
#     threads and no summary, so it can re-report findings this round already
#     answered. It is superseded by the explicit request at the end. The trade is
#     a wasted pass against a round that closes on a red head, and only one of
#     those can be undone by the next round.
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

# ── THE STALE HEAD IS CLEARED BEFORE THE BOOTSTRAP, not after the arguments are
# parsed. Everything below this — the library loads, the identity, the argument
# validation — can refuse, and a refusal that happens before the file is emptied
# leaves the PREVIOUS round's OID in it. The driver proves the head before it
# resolves any thread, so a stale OID passing that proof is a resolve on a round
# that never gated. Measured: emptying an inline `recordlib.sh` makes this stage
# exit at `reason=recordlib_empty`, which is above every line that parses `$5`.
#
# WITH NOTHING BUT RESERVED WORDS AND A REDIRECTION, because no library has been
# loaded yet and none is needed. It is deliberately BEFORE `shift`, so `$1` is the
# stage and `$6` is the head file.
#
# ONLY A FILE THAT ALREADY EXISTS, and only a path with a `/` in it. A shape test
# here would be a second copy of the rule `recordlib.sh` owns — `sha_reason` is not
# loaded yet, so there would be no way to ask it — and the pre-#202 form puts the
# head ITSELF in that position. A commit id contains no `/`, and every head file
# this loop names is a path under the session's working directory, so the slash
# tells the two apart without knowing what an OID looks like. Without it, a file
# named after a sha in the current directory would be truncated by a call that is
# about to be refused for passing the old form.
#
# AND NOT THE SUMMARY, because truncating a head file that IS the summary destroys
# the account this stage is about to post. That refusal is below too, and this must
# not commit the damage it exists to prevent.
#
# AND THE TRUNCATION'S STATUS IS TAKEN. A head file that cannot be truncated — its
# permissions changed, its filesystem gone read-only — keeps the PREVIOUS round's
# OID, and a bootstrap refusal after that leaves exactly the state this block
# exists to prevent. Refusing here is safe in a way it is not further down: nothing
# has been loaded, nothing pushed, nothing posted.
if [[ ${1:-} = gate ]] && [[ -n ${6:-} ]] && [[ -f ${6} ]] && [[ ${6} = */* ]] \
   && [[ -n ${4:-} ]] && [[ ! ${6} -ef ${4} ]]; then
    > "${6}" || {
        echo "ABORT: the head file '${6}' exists and cannot be emptied; a stale head would be left for the driver to accept."
        exit 1
    }
fi
# AND THE PRIOR FILE HERE TOO, FOR THE SAME REASON AND WITH THE SAME EXCEPTIONS. A
# bootstrap refusal above the truncation further down leaves the PREVIOUS round's
# baseline in place, and the driver's watch takes what it finds: a review that
# predates this round, accepted as the answer to a request this round never made.
# The exceptions are the summary — truncating it destroys the account — and the head
# file, which the arm above has already emptied and whose emptiness must not be
# mistaken for this one's. Both are refused properly further down; this only
# declines to do damage before that refusal can be reached. #234.
if [[ ${1:-} = gate ]] && [[ -n ${7:-} ]] && [[ -f ${7} ]] && [[ ${7} = */* ]] \
   && [[ -n ${4:-} ]] && [[ ! ${7} -ef ${4} ]] \
   && { [[ -z ${6:-} ]] || [[ ! ${7} -ef ${6} ]]; }; then
    > "${7}" || {
        echo "ABORT: the prior file '${7}' exists and cannot be emptied; a stale baseline would be left for the driver to accept."
        exit 1
    }
fi

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
rb_load "$_RB_SELF_DIR" recordlib sha_reason "ABORT:" 2>&1 || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "ABORT: reason=loadlib_empty"
    exit 1; }
# BOTH CONSTANTS, EACH THROUGH `rb_load`. Verifying only one leaves the other
# inheritable: a `recordlib.sh` truncated after the first definition passes the
# check, and an exported `RB_COPILOT_BOT` from the environment is then accepted
# as library data — so this would validate a signoff from whatever account that
# variable named. `rb_load` clears before it sources, which is the whole point.
rb_load "$_RB_SELF_DIR" recordlib rb_reserved_marker_line "ABORT:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib rb_review_trigger "ABORT:" 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "ABORT:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" recordlib RB_COPILOT_BOT "ABORT:" var 2>&1 || exit 1
rb_load "$_RB_SELF_DIR" identitylib rb_identity "ABORT:" 2>&1 || exit 1
rb_identity || { echo "ABORT: reason=$RB_IDENTITY_REASON"; exit 1; }
# THE SESSION'S IDENTITY IS KEPT, because `rb_identity` runs again below against
# origin's PUSH url and overwrites these. Copied here once, before anything can
# move them, so the comparison is against what this session was pinned to rather
# than against whatever the last parse produced.
RB_PIN_HOST="$HOST"; RB_PIN_OWNER="$OWNER"; RB_PIN_REPO="$REPO"
{ [ "$RB_PIN_HOST" = "$HOST" ] && [ "$RB_PIN_OWNER" = "$OWNER" ] && [ "$RB_PIN_REPO" = "$REPO" ]; } \
    || { echo "ABORT: the pinned identity could not be captured; one of RB_PIN_HOST/OWNER/REPO is readonly."; exit 1; }
COPILOT_BOT="$RB_COPILOT_BOT"

# THE STAGE IS FIRST AND HAS NO DEFAULT. A default is the whole defect back: a
# caller that forgets which half it is running would silently get one, and the one
# it got would be the one that skips the threads. The old four-argument form
# lands here as a PR number in stage position and is refused by name.
STAGE="${1:-}"
case "$STAGE" in
    gate|post) ;;
    "") echo "ABORT: a stage is required: 'gate' (push and prove the head) or 'post' (summarise and request), with the thread replies in between"; exit 1 ;;
    *) echo "ABORT: '$STAGE' is not a stage; expected 'gate' or 'post' — the thread replies go between them"; exit 1 ;;
esac
shift

PR="${1:-}"; WHO="${2:-}"; SUMMARY_FILE="${3:-}"; AUTO_REVIEW="${4:-}"; HEAD_FILE="${5:-}"; PRIOR_FILE="${6:-}"
# THE GATED HEAD IS THE HANDOFF BETWEEN THE STAGES, AND IT TRAVELS IN A FILE. Both
# stages take the same path: `gate` writes the head it proved into it, and `post`
# reads it back out. The value never enters the driving shell.
#
# IT WAS A STRING, AND THAT IS WHAT #202 WAS. The driver captured `gate`'s output,
# `sed`ed the head out of the record and assigned it — `GATED_HEAD="$( … )"`, an
# ASSIGNMENT, in the operator's own long-lived shell, AFTER `gate` had already
# pushed. A startup file that has made that name readonly fails it there: with
# `errexit` the shell ends, and without it the name keeps whatever it held, so the
# non-empty check passes on a seeded value and `post` is handed a head the gate
# never reported. `CLAUDE.md` records that an assignment's status cannot be taken,
# so a `||` on it catches nothing.
#
# A FILE HAS NO SUCH FAILURE, and it removes two more names with it: the driver no
# longer needs a capture, and it no longer needs `sed` — which is a NAME, and one
# that prints a plausible forty hex and exits 0 sends `post` at whatever it says.
# It is the shape `pr-request-review.sh` uses for the review baseline and
# `pr-origin.sh` for the origin: a path rather than a name.
#
# THE OLD FORM IS REFUSED BY NAME rather than ignored, because a caller still
# passing the sha would have `gate` try to create a file called `a8ec960…` and
# `post` try to read one — the first would succeed and the second would fail with a
# reason about the file rather than about the caller.
[ -n "$HEAD_FILE" ] \
    || { echo "ABORT: a head file is required: 'gate' writes the head it proved into it and 'post' reads it back."; exit 1; }
if sha_reason "$HEAD_FILE" >/dev/null 2>&1; then
    echo "ABORT: the fifth argument is now the head FILE, not the head itself (got what looks like an OID: '$HEAD_FILE'). 'gate' writes the head into that file and 'post' reads it back."
    exit 1
fi
# AND IT IS NOT THE SUMMARY. `gate` reads the summary and then writes the head, so
# one file serving as both means the head OVERWRITES the account: `post` then finds
# a well-formed OID in the summary file, passes the non-empty test, and posts the
# sha as this round's summary to the reviewer that reads it before the diff.
#
# BOTH IDENTITIES, because neither covers the other. Equal strings catch the plain
# case, including before either file exists; `-ef` catches a hard link or a symlink,
# which is the same file under two names and is what an operator with a tidy
# scratch directory can produce by accident.
if [[ $HEAD_FILE = "$SUMMARY_FILE" ]] || [[ $HEAD_FILE -ef $SUMMARY_FILE ]]; then
    echo "ABORT: the head file and the summary file are the same file ('$HEAD_FILE'); the head would overwrite the account and be posted as this round's summary."
    exit 1
fi
# AND A GATE EMPTIES IT BEFORE ANY OTHER REFUSAL CAN HAPPEN — before the PR number
# and the reviewer are validated, and before the summary is read — so that EVERY
# refusal but the aliased one leaves it empty rather than holding the PREVIOUS
# round's head. It sat below all of those and was reached by none of them: a
# readonly `WHO` holding an invalid reviewer, or a library that would not load, left
# a stale OID in place for a driver to accept. That is what lets
# the driver's `post` step guard on the file being non-empty and have the guard
# mean something: the STATE says whether a gate succeeded, rather than the driver's
# obedience to an ordering.
#
# A STALE HEAD PASSES THE DRIVER'S GUARD, which is what makes the position matter
# rather than being tidiness: it is refused only later, by `post`'s own re-proof —
# after the threads have been resolved, which cannot be taken back.
#
# THE ALIAS CHECK STAYS AHEAD OF IT, and that ordering is forced: truncating a head
# file that IS the summary destroys the account this stage is about to post. The
# driver asks the file identity first for the same reason.
# THE PRIOR FILE IS THE SAME KIND OF ARGUMENT AND GETS THE SAME CHECKS. Aliasing it
# to the summary would have the baseline overwrite the account this stage posts;
# aliasing it to the head file would have it overwrite the head `post` re-proves
# against. Both are the accident an operator with a tidy scratch directory produces,
# and both are silent without this.
[ -n "$PRIOR_FILE" ] \
    || { echo "ABORT: a prior file is required: 'post' writes the review baseline into it and the driver reads it back."; exit 1; }
if [ "$PRIOR_FILE" = "$SUMMARY_FILE" ] || [ "$PRIOR_FILE" -ef "$SUMMARY_FILE" ] 2>/dev/null; then
    echo "ABORT: the prior file and the summary file are the same file ('$PRIOR_FILE'); the baseline would overwrite the account."
    exit 1
fi
if [ "$PRIOR_FILE" = "$HEAD_FILE" ] || [ "$PRIOR_FILE" -ef "$HEAD_FILE" ] 2>/dev/null; then
    echo "ABORT: the prior file and the head file are the same file ('$PRIOR_FILE'); the baseline would overwrite the head 'post' re-proves against."
    exit 1
fi
# EMPTIED BY THE GATE, ALONGSIDE THE HEAD. A `post` that fails after a previous
# round wrote a baseline would otherwise leave the OLD value readable, and the
# driver's watch would take it — accepting a review that predates this round as the
# answer to the request this round did not make.
#
# AND SINCE #264 AN EMPTIED FILE IS A REFUSAL, WHICH IS STRONGER THAN WHAT THIS WAS FOR.
# Empty used to be a legitimate baseline, so emptying here removed the stale claim and
# left "no floor" in its place — better than the stale value and still a value the watch
# accepts. The watch refuses an empty file now, so a `post` that fails after this gate
# stops the round with `empty_after_review_file` instead of arming a watch against
# nothing. Do not "fix" this by writing the `none` token here: the token means there was
# no prior review, which this gate has not established and must not claim.
if [ "$STAGE" = gate ]; then
    > "$HEAD_FILE" || { echo "ABORT: could not empty the head file '$HEAD_FILE'."; exit 1; }
    > "$PRIOR_FILE" || { echo "ABORT: could not empty the prior file '$PRIOR_FILE'."; exit 1; }
fi

case "$PR" in
    ""|*[!0-9]*) echo "ABORT: a PR number is required (got '$PR')"; exit 1 ;;
esac
# THE REVIEWER IS ONE OF THE TWO THIS LOOP KNOWS. Every branch below asks "is
# this Copilot?" and treats everything else as Codex, so a typo or a third login
# silently took the Codex path: the mention was posted, Copilot was never
# requested, and the round waited on a pass nobody asked for.
case "$WHO" in
    "$RB_CODEX_BOT"|"$RB_COPILOT_BOT") ;;
    "") echo "ABORT: a reviewer login is required"; exit 1 ;;
    *) echo "ABORT: '$WHO' is not a reviewer this loop drives (expected $RB_CODEX_BOT or $RB_COPILOT_BOT)"; exit 1 ;;
esac
[ -n "$SUMMARY_FILE" ] || { echo "ABORT: a summary file is required"; exit 1; }
# WHAT `git push` WOULD PUSH IS NOT THIS PR UNLESS SOMEBODY CHECKS. A bare
# `git push` sends whatever branch the checkout happens to be on, and this stage
# is given a PR number and a reviewer — it was never told which branch that PR is
# for, and never asked.
#
# IT PUSHED `main`. Driving #118's round from a checkout sitting on `main` — a
# `git checkout` had failed because a second worktree held the feature branch, so
# the shell stayed put — the gate pushed the default branch. An unreviewed commit
# went straight to `main`, and the round was lost besides: the CI gate then waited
# for checks on a head the PR still did not have. Two failures from one missing
# question. #119.
#
# ASKED OF THE PR, ANSWERED FROM THE CHECKOUT, AND COMPARED WITH A RESERVED WORD.
# A DETACHED HEAD HAS NO BRANCH and is refused too: `git push` from one pushes
# nothing useful, and "nothing useful" is not a state to guess about when the next
# step waits for a head to appear.
# THE REFSPEC IS THE PROTECTION; THE BRANCH CHECK IS THE EXPLANATION. A bare
# `git push` leaves BOTH destination inputs to configuration: `push.default` and
# `branch.<n>.remote` decide the repository, and `remote.<n>.push` can supply
# refspecs that update other refs — an ahead `main` among them — however the
# current branch is named. So checking the name and then pushing bare is a guard
# over a call that can still go elsewhere, which is the shape this repository
# keeps deleting.
#
# `git push origin HEAD:refs/heads/<branch>` names the repository and the one ref
# it may write, so no configuration can widen it. The branch comparison stays
# because it is what TELLS THE OPERATOR they are in the wrong worktree — the case
# that caused #119 — rather than pushing their work to a branch they did not mean
# and reporting success.
#
# `RB_PUSH_REFSPEC` IS SET HERE AND USED AT BOTH PUSH SITES, so the two cannot
# drift: one of them being bare is exactly the defect, and a value computed once
# cannot be half-applied.
rb_push_is_the_prs() {
    local _want _cross _pair _pushurl _have
    # ONE CALL FOR BOTH FACTS, joined by a TAB. A git ref name cannot contain a
    # space or any control character — `git check-ref-format` forbids them — so a
    # tab cannot appear in `headRefName` and cannot shift the field. That is the
    # test this repository applies to any delimiter, and it is why two values may
    # share one line here where three identity fields may not.
    _pair=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefName,isCrossRepository \
        --jq '.headRefName + "\t" + (.isCrossRepository | tostring)' 2>/dev/null) \
        || { echo "ABORT: could not read the PR's head branch; refusing to push blind."; return 1; }
    _want="${_pair%%$'\t'*}"
    _cross="${_pair#*$'\t'}"
    [ -n "$_want" ] || { echo "ABORT: the PR reports no head branch; refusing to push blind."; return 1; }
    # THE API SAYS WHETHER IT IS A FORK; THIS DOES NOT COMPARE NAMES. Comparing
    # `headRepositoryOwner/headRepository` with `$OWNER/$REPO` was the first
    # version and it is wrong on casing: a pinned origin whose owner or repository
    # differs in case from what the API returns addresses the same repository, and
    # a case-sensitive test called every such PR a fork and refused every push.
    # Lower-casing needs a name — `tr`, or a bash 4 expansion this suite's 3.2 job
    # does not have — so the comparison is removed rather than fixed:
    # `isCrossRepository` is the same question asked of the thing that knows.
    case "$_cross" in
        false) ;;
        true) echo "ABORT: PR $PR is from a fork; this loop does not push to forks."; return 1 ;;
        *) echo "ABORT: could not tell whether PR $PR is from a fork (got '$_cross'); refusing to push blind."; return 1 ;;
    esac
    # AND `origin` HAS TO BE THE PINNED REPOSITORY, because it is a NAME the
    # checkout resolves. `remote.origin.pushurl` can send it somewhere else
    # entirely, and a second checkout can define `origin` as another project — so
    # the branch and fork checks above would pass while the commit landed in a
    # repository nobody asked about and the PR stayed unchanged.
    #
    # PARSED BY THE ONE PARSER, not by a second copy. `rb_identity` is what turns
    # a remote into HOST/OWNER/REPO, and a second implementation here is the
    # duplication this repository has already deleted four times. It runs in a
    # SUBSHELL with the push URL pinned, so its globals cannot leak back, and the
    # answer comes out as the subshell's STATUS rather than as three values
    # serialised through one string — which is the delimiter problem `CLAUDE.md`
    # records for exactly this parser.
    # EVERY PUSH URL, NOT THE FIRST. `origin` may carry several `pushurl` entries
    # and `git push origin` sends to ALL of them — so validating one and pushing to
    # the name put the commit in every other configured repository too, which is
    # the hole this check was added to close, reached by the second entry.
    # `--all` is what returns them; the loop below refuses unless every one is the
    # pinned repository, so a mirror of it still works and a mixed destination
    # does not.
    _pushurl=$(git remote get-url --push --all origin 2>/dev/null) \
        || { echo "ABORT: could not read origin's push URLs; refusing to push blind."; return 1; }
    [ -n "$_pushurl" ] || { echo "ABORT: origin has no push URL; refusing to push blind."; return 1; }
    #
    # COMPARED CASE-INSENSITIVELY, because casing is not a different repository: two
    # spellings of one owner-and-repository pair differing only in case address the
    # same thing, and a fetch URL and a push URL written with different capitalisation are one
    # operator's inconsistency rather than a redirection. Comparing them exactly
    # refused every push in that configuration — the same defect this round
    # removed from the fork check, one level over.
    #
    # `shopt` IS SAFE HERE, and that is a fact about this file rather than a
    # general licence: every helper starts `bash -p`, which imports no functions,
    # so no builtin in it can be shadowed. That is what #101 and #83 settled. It
    # is set inside the SUBSHELL, so the option does not outlive the comparison.
    # PEELED WITH EXPANSIONS, so there is no `read` and no redirection: `--all`
    # prints one URL per line, and a heredoc here is a temporary file that can
    # fail — the fail-open shape #111 removed from the marker scan.
    local _rest="$_pushurl" _u _nl='
'
    while [ -n "$_rest" ]; do
        case "$_rest" in
            *"$_nl"*) _u="${_rest%%"$_nl"*}"; _rest="${_rest#*"$_nl"}" ;;
            *)        _u="$_rest"; _rest="" ;;
        esac
        [ -n "$_u" ] || continue
        ( shopt -s nocasematch
          REVIEW_BUS_REMOTE="$_u"; REVIEW_BUS_OWNER=''; REVIEW_BUS_REPO=''
          rb_identity && [[ $HOST == "$RB_PIN_HOST" ]] && [[ $OWNER == "$RB_PIN_OWNER" ]] && [[ $REPO == "$RB_PIN_REPO" ]] ) \
            || { echo "ABORT: origin pushes to '$_u', which is not $RB_PIN_HOST/$RB_PIN_OWNER/$RB_PIN_REPO; refusing to push elsewhere."; return 1; }
    done
    # THE FULL REF, STRIPPED HERE. `--short` is not the branch name: it shortens
    # only as far as stays UNAMBIGUOUS, so a branch that shares its name with a tag
    # comes back as `heads/release/2.0` while GitHub reports `release/2.0` — and
    # the comparison below then refused a checkout that was already on the PR's
    # branch, with no way to close the round at all. Reproduced on git 2.55.
    #
    # `refs/heads/` IS REMOVED AS A PREFIX, not matched loosely: `${_have#refs/heads/}`
    # takes it only from the front, so a branch legitimately called
    # `refs/heads/something` is not silently rewritten.
    _have=$(git symbolic-ref --quiet HEAD 2>/dev/null) \
        || { echo "ABORT: this checkout is not on a branch (detached HEAD); a push here would not reach PR $PR."; return 1; }
    case "$_have" in
        refs/heads/*) _have="${_have#refs/heads/}" ;;
        *) echo "ABORT: HEAD points at '$_have', which is not a branch; a push here would not reach PR $PR."; return 1 ;;
    esac
    [[ $_have = "$_want" ]] \
        || { echo "ABORT: this checkout is on '$_have' and PR $PR is for '$_want'; refusing to push the wrong branch."; return 1; }
    RB_PUSH_REFSPEC="HEAD:refs/heads/$_want"
    [[ $RB_PUSH_REFSPEC = "HEAD:refs/heads/$_want" ]] \
        || { echo "ABORT: RB_PUSH_REFSPEC is readonly in this shell; the push destination cannot be pinned."; return 1; }
    return 0
}

# AUTO-REVIEW DECIDES THE ORDERING, so an unrecognised value is refused rather
# than assumed. Guessing wrong here does not fail loudly — it closes the round in
# the wrong order, which is only visible afterwards.
case "$AUTO_REVIEW" in
    yes|no) ;;
    *) echo "ABORT: auto-review must be 'yes' or 'no' (got '$AUTO_REVIEW')"; exit 1 ;;
esac
if [ "$AUTO_REVIEW" = no ]; then _MODE=mention; else _MODE=push; fi

# THE SUMMARY IS READ WITH ITS STATUS TAKEN, before anything is posted or pushed.
# `$(cat …)` inside the argument swallows the reader's status, so a partial read
# still produced a successful `gh pr comment` — and the reviewer contract makes the
# newest summary the thing read before the diff, so a truncated one is worse than
# none: it looks complete. A round that cannot produce its own summary should not
# push either.
SUMMARY="$(cat "$SUMMARY_FILE")" || { echo "ABORT: could not read the round summary."; exit 1; }
[ -n "$SUMMARY" ] || { echo "ABORT: the round summary is empty."; exit 1; }
# THE SUMMARY IS PROSE, AND MUST NOT BECOME A RECORD. It quotes findings, PR
# descriptions and reviewer comments, and it is posted under an identity
# `pr-signoff.sh` and `pr-round-count.sh` trust — so a line reproducing one of
# their markers CREATES the record it was describing: a summary quoting a finding
# about an acknowledgement becomes that acknowledgement, and the round boundary it
# answers never fires again. The rule is `recordlib.sh`'s because
# `pr-copilot-phase.sh` posts a caller-written body too.
# AND IN A COPILOT ROUND IT MUST NOT REQUEST A CODEX PASS. A comment CONTAINING
# `@codex review` is the trigger, and a Copilot round posts its summary on its
# own — so a summary quoting the mention out of a finding or a PR description
# requests Codex in the middle of the Copilot phase, which is the phase ordering
# this loop exists to keep. In a CODEX round the mention is the request and this
# script writes it itself, so a body that also carries one changes nothing.
if [ "$WHO" = "$COPILOT_BOT" ]; then
    rb_review_trigger "$SUMMARY"; _trig_rc=$?
    case "$_trig_rc" in
        1) ;;
        0) echo "ABORT: this is a Copilot round and the summary contains '@codex review', which requests a Codex pass on its own."
           echo "Only Copilot should be re-requested here. Break the mention up, or describe it without the @."
           exit 1 ;;
        *) echo "ABORT: could not tell whether the round summary requests a review (rc=$_trig_rc)"; exit 1 ;;
    esac
fi
if _marker="$(rb_reserved_marker_line "$SUMMARY")"; then
    echo "ABORT: the round summary starts a line with a marker the loop reads as a record: $_marker"
    echo "It would be posted under your identity and honoured. Indent it by four spaces, or quote it inline with backticks — either still says what you meant. A fenced block does NOT help: the line inside it still starts at column 0, which is all the readers look at."
    exit 1
fi

# THE BOUNDARY IS CHECKED BEFORE ANY WAY A REVIEW CAN BE REQUESTED — which in
# auto-review mode means before the PUSH, because there the push IS the request.
# Placing it before the mention was not enough: a fix commit on the threshold-th
# round moved the head and started the next review while the count had not yet
# run, so the pause fired after the round it was meant to precede was queued.
#
# IN `gate` ONLY. By `post` the push has happened and the threads are answered, so
# a pause there would stop a round that is already irreversibly half-closed — and
# the count it would be pausing on was checked before any of that.
if [ "$STAGE" = gate ]; then
    /usr/bin/env bash -p "$_RB_SELF_DIR"/pr-round-count.sh "$PR" "$WHO"; ROUNDS_RC=$?
    case "$ROUNDS_RC" in
        0) ;;
        3) echo "PAUSE: round boundary reached. Decide with the operator before requesting the next pass: continue, merge, leave it open, or close this PR and start over with a better approach. Say what the rounds have been ABOUT, not just how many"
           exit 3 ;;
        *) echo "ABORT: could not establish the round count (rc=$ROUNDS_RC)"; exit 1 ;;
    esac
fi

report_gated() {   # report_gated <head> ; writes the head to $HEAD_FILE, then reports it
    # THE WRITE COMES FIRST AND ITS STATUS IS TAKEN. `printf` can fail on a full
    # filesystem, and a record printed after an unchecked write leaves `post`
    # reading a truncated or absent value while the driver has already been told
    # the round was gated. Reporting only after the write means the record and the
    # file agree or neither exists.
    #
    # IT IS NOT READ BACK HERE, and that is deliberate. `post` reads this file and
    # validates what it finds with `sha_reason` before anything is posted, so a
    # write that succeeded on a file that holds something else is caught there —
    # by the stage that depends on it, at no cost, and on the read that matters. A
    # second check here would be a branch no fixture can stage.
    printf '%s\n' "$1" > "$HEAD_FILE" \
        || { echo "ABORT: could not write the gated head to '$HEAD_FILE'; 'post' would have nothing to read."; return 1; }
    echo "PR_ROUND_GATED pr=$PR reviewer=$WHO head=$1 mode=$_MODE"
    return 0
}

request_review() {   # request_review ; posts the summary and asks for the pass
    # THE BASELINE IS READ IMMEDIATELY BEFORE THE REQUEST, never earlier. A
    # baseline captured before the push accepts a pass that FINISHED during the CI
    # wait as the answer to a request made after it — and a Codex pass on a small
    # diff can beat the checks.
    local prior _back
    prior=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh review-id "$PR" "$WHO") \
        || { echo "ABORT: could not read the current review id; do not request a review blind."; return 1; }
    # AND IT IS HANDED OVER BEFORE THE REQUEST, with the write's status taken and the
    # value read back. `printf` can report success and the write fail at the flush when
    # the redirection closes, and a driver reading a truncated baseline watches against
    # a value no request was made with. Taking the status only works while there is
    # something left to refuse WITH: after the request there is not, and the round is
    # irreversibly half-closed. So the file is written here — the read above is still
    # immediately before the request, which is what that ordering is for — and a failure
    # stops the stage with nothing posted and nothing queued.
    # THE NO-FLOOR VALUE IS SPELLED `none`, NOT LEFT EMPTY — #264. An empty file used to
    # mean "no prior review", so a failure between this truncation and this write produced
    # the legal value, and a driver whose `exit` returns then armed its watch with no floor
    # at all. `gate` still EMPTIES this file, and that is now a refusal rather than a
    # no-floor: an emptied baseline reaching the watch is `state=error`, which is the
    # direction that stops a round instead of announcing a pass nobody requested.
    prior="${prior:-none}"
    printf '%s\n' "$prior" > "$PRIOR_FILE" \
        || { echo "ABORT: could not write the review baseline to '$PRIOR_FILE'; nothing has been posted."; return 1; }
    _back="$(<"$PRIOR_FILE")" \
        || { echo "ABORT: could not read back the review baseline from '$PRIOR_FILE'; nothing has been posted."; return 1; }
    [ "$_back" = "$prior" ] \
        || { echo "ABORT: the review baseline did not survive being written to '$PRIOR_FILE'; nothing has been posted."; return 1; }
    # WHICH REVIEWER THE ROUND WAS ABOUT DECIDES HOW IT IS RE-REQUESTED. Copilot is
    # never triggered by a mention and never by a push — only by `--add-reviewer` —
    # so a Copilot round that posted the Codex mention requested nothing at all,
    # and the watch then waited past the old review indefinitely.
    if [ "$WHO" = "$COPILOT_BOT" ]; then
        gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "$SUMMARY" \
            || { echo "ABORT: could not post the round summary."; return 1; }
        gh pr edit "$PR" --repo "$HOST/$OWNER/$REPO" --add-reviewer @copilot \
            || { echo "ABORT: could not re-request Copilot."; return 1; }
    else
        # ONE COMMENT, because the mention IS the trigger: the summary posted
        # separately is a summary the pass may not have read.
        gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "@codex review

$SUMMARY" \
            || { echo "ABORT: could not request the review that carries this round's summary."; return 1; }
    fi
    # THE BASELINE GOES BACK TO THE CALLER, in the success record. It is read
    # here, immediately before the request, and the driver's watch in step 3 needs
    # exactly this value: without it the watch keeps the parent's OLDER baseline,
    # and the terminal review this round just handled is newer than that — so it
    # is accepted at once as the answer to a request that has not been answered.
    # A child process cannot assign a variable in its parent; it can only say what
    # the value was.
    RB_PRIOR_REVIEW="$prior"
    return 0
}

if [ "$STAGE" = post ]; then
    # ── THE THREADS ARE ANSWERED; CLOSE THE ROUND ──────────────────────────
    # THE GATED HEAD COMES OUT OF THE FILE `gate` WROTE, with a redirection rather
    # than a command: `$(<file)` is handled by the parser, so there is no `cat` to
    # shadow. An unreadable or empty file is a refusal, not an empty head — this
    # runs before anything is posted, so a refusal here costs a rerun of `post`
    # and nothing else.
    GATED_HEAD="$(<"$HEAD_FILE")" \
        || { echo "ABORT: could not read the gated head from '$HEAD_FILE'; run 'gate' first."; exit 1; }
    _why="$(sha_reason "$GATED_HEAD")" \
        || { echo "ABORT: the gated head read back from '$HEAD_FILE' is not a full OID ($_why: '$GATED_HEAD')."; exit 1; }
    # THE HEAD IS RE-PROVEN RATHER THAN ASSUMED. Answering threads takes as long
    # as it takes, and a commit made in between — an afterthought fix, an amend —
    # leaves the summary describing one commit while the reviewer reads another.
    # The gate's green verdict belongs to the commit the gate saw, and only that
    # one; carrying it forward silently is how a round closes on unproven code.
    HEAD_NOW=$(git rev-parse HEAD) || { echo "ABORT: could not read the local head."; exit 1; }
    [ "$HEAD_NOW" = "$GATED_HEAD" ] \
        || { echo "ABORT: the local head is $HEAD_NOW, not the gated $GATED_HEAD; re-run the gate for what is here now."; exit 1; }
    # AND ON THE PR, because the local head agreeing proves only that this
    # checkout did not move. A force-push from elsewhere, or a merge into the
    # branch, moves the head the reviewer will read while this one stands still.
    HEAD_API=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
        || { echo "ABORT: could not confirm the head before posting."; exit 1; }
    _why="$(sha_reason "$HEAD_API")" \
        || { echo "ABORT: the confirmed head is not a full OID ($_why: '$HEAD_API')."; exit 1; }
    [ "$HEAD_API" = "$GATED_HEAD" ] \
        || { echo "ABORT: the PR head is $HEAD_API, not the gated $GATED_HEAD; the round would close on a commit that was never proven."; exit 1; }
    request_review || exit 1
    echo "PR_ROUND_CLOSED pr=$PR reviewer=$WHO head=$GATED_HEAD mode=$_MODE prior-review=$RB_PRIOR_REVIEW"
    exit 0
fi

if [ "$AUTO_REVIEW" = no ]; then
    # ── THE MENTION IS THE TRIGGER ─────────────────────────────────────────
    # Nothing is queued until the comment is posted, so the push can be proven
    # green first and the threads answered afterwards, with nothing yet requested.
    HEAD_PUSHED=$(git rev-parse HEAD) || { echo "ABORT: could not read the local head."; exit 1; }
    rb_push_is_the_prs || exit 1
    git push origin "$RB_PUSH_REFSPEC" || { echo "ABORT: push failed; the fixes are not on the PR."; exit 1; }
    /usr/bin/env bash -p "$_RB_SELF_DIR"/pr-ci-gate.sh "$PR" "$HEAD_PUSHED" || exit 1
    report_gated "$HEAD_PUSHED" || exit 1
    exit 0
fi

# ── THE PUSH IS THE TRIGGER ────────────────────────────────────────────────
HEAD_BEFORE=$(git rev-parse HEAD) || { echo "ABORT: could not read the local head."; exit 1; }
# ONLY WHERE IT IS USED. `PUSH_FROM` answers one question — did the push move the
# head, and therefore did it start a pass — and a push never starts a Copilot pass.
# Read unconditionally, a transient failure of this lookup aborted a Copilot round
# before the push AND before the `--add-reviewer` that is the only thing such a
# round needs: a stall with no upside, which is the same defect the baseline guard
# below exists for. The post-push confirmation is NOT guarded: that one is about
# whether the push landed on this PR at all, which matters for every reviewer.
PUSH_FROM=""
if [ "$WHO" != "$COPILOT_BOT" ]; then
    PUSH_FROM=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
        || { echo "ABORT: could not read the head this push starts from."; exit 1; }
    _why="$(sha_reason "$PUSH_FROM")" \
        || { echo "ABORT: the pre-push head is not a full OID ($_why: '$PUSH_FROM')."; exit 1; }
fi

# THE BASELINE IS READ BEFORE THE PUSH, and this is the one ordering in the whole
# script that runs the other way round from everything else.
#
# Everywhere else, later is safer: read the state as close as possible to the
# decision that uses it. Here later is WRONG. The push starts a pass; a fast one
# finishes while the CI gate is still settling; and a baseline taken after that
# captures the completed pass as the thing to wait past — so `pr-watch.sh` waits
# for a newer pass that nobody requested, times out, and the round never closes
# despite being clean.
#
# Only for reviewers a push can trigger. Copilot is not one, and reading it there
# put a `gh` call that can fail transiently in front of the `--add-reviewer` that
# is the only thing a Copilot round needs — a stall with no upside.
PUSH_BASE=""
if [ "$WHO" != "$COPILOT_BOT" ]; then
    PUSH_BASE=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh review-id "$PR" "$WHO") \
        || { echo "ABORT: could not read the review id before the push."; exit 1; }
fi
rb_push_is_the_prs || exit 1
git push origin "$RB_PUSH_REFSPEC" || { echo "ABORT: push failed; no review was queued and the fixes are not on the PR."; exit 1; }
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-ci-gate.sh "$PR" "$HEAD_BEFORE" || exit 1

# THE PUSHED HEAD IS CONFIRMED, WITH RETRIES. The API can serve the previous head
# for a moment after a push, and every check below is about the commit that was
# pushed rather than the one the API happens to be reporting.
HEAD_AFTER=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
    || { echo "ABORT: could not confirm the pushed head."; exit 1; }
_why="$(sha_reason "$HEAD_AFTER")" \
    || { echo "ABORT: the pushed head is not a full OID ($_why: '$HEAD_AFTER')."; exit 1; }
if [ "$HEAD_BEFORE" != "$HEAD_AFTER" ]; then
    for _try in 1 2 3; do
        [ "$HEAD_AFTER" = "$HEAD_BEFORE" ] && break
        sleep 2
        HEAD_AFTER=$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null) \
            || { echo "ABORT: could not re-read the head after pushing."; exit 1; }
        _why="$(sha_reason "$HEAD_AFTER")" \
            || { echo "ABORT: the re-read head is not a full OID ($_why: '$HEAD_AFTER')."; exit 1; }
    done
    [ "$HEAD_AFTER" = "$HEAD_BEFORE" ] \
        || { echo "ABORT: the PR head is $HEAD_AFTER, not the $HEAD_BEFORE just pushed."; exit 1; }
fi

# THE PASS THE PUSH STARTED MUST FINISH FIRST — but only when there WAS one. A
# round that ends without a new commit (a dismissal, or a finding answered rather
# than coded around) leaves the push a no-op, so nothing was queued and waiting
# for it would re-arm every timeout forever. Copilot is never triggered by a push
# at all.
if [ "$WHO" != "$COPILOT_BOT" ] && [ "$PUSH_FROM" != "$HEAD_AFTER" ]; then
    /usr/bin/env bash -p "$_RB_SELF_DIR"/pr-watch.sh "$PR" "$WHO" --after-review "$PUSH_BASE"; PUSHPASS_RC=$?
    case "$PUSHPASS_RC" in
        0) ;;
        1) echo "ABORT: the pass the push started has not finished; its result would answer the next request."; exit 1 ;;
        # THE PASS SAID NOTHING ANYONE CAN ACT ON. Every comment it left was a
        # reply, so there is nothing for `pr-findings.sh` to list and it is not a
        # signoff. Closing the round here would resolve the previous round's
        # threads, post a summary and request another pass — past the one thing
        # that needs to happen, which is a human reading that comment. Paused
        # rather than aborted: nothing is wrong, a decision is owed.
        4) echo "PAUSE: the pass the push started left only replies — nothing to fix and no signoff. Read it with the operator before closing this round."
           exit 3 ;;
        *) echo "ABORT: could not observe the pass the push started (rc=$PUSHPASS_RC)"; exit 1 ;;
    esac
fi

report_gated "$HEAD_AFTER" || exit 1
exit 0
