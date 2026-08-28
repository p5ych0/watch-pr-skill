#!/usr/bin/env -S bash -p
# Are this PR's checks green on the head that was just pushed?
#
#   pr-ci-state.sh <pr> [--required]
#
#   pr-ci-state.sh <pr> [--required] [--head <oid>]
#
#   0  green    — every check considered passed
#   1  failed   — at least one failed or was cancelled
#   3  pending  — at least one is still running and none has failed
#   4  none     — no checks are configured; there is nothing to be green
#   5  stale    — the PR head is not the OID asked about; ask again shortly
#   2  error    — could not be established; fail closed
#
# WHY THIS EXISTS
#
# CI was red for four consecutive commits on PR #14 and neither the round loop nor
# the pre-push self-check noticed. Every one of those rounds was closed as green on
# the strength of a local suite run, and the operator had to point at the checks
# tab. `pr-selfcheck.sh` runs the suite HERE, before the push; it cannot see a
# failure that only happens on the runner — and that one only happened there,
# because GitHub Actions ignores SIGPIPE, so a `printf` losing a pipe race returned
# 1 instead of dying with 141.
#
# "the suite passes here" and "the checks pass there" are different claims, and
# only the first was ever made. Issue #16.
#
# NOT A SECOND COPY. The merge gate already asked this question, in about seventy
# lines inline in `SKILL.md`. Writing them out again for the round loop is the
# defect issues #11 and #18 were both opened for, so the gate calls this too and
# `--required` is what separates the two questions: the merge gate asks whether
# branch protection is satisfied, and the round loop asks whether the commit it
# just pushed is broken — a failing non-required check is still a broken push.
#
# `set -uo pipefail`, NOT `-e`: `gh` probes fail as normal operation and the
# result is control flow. See CLAUDE.md § Bash conventions.
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
# that prints a forged `PR_CI_STATE status=error` line and exits has already answered the
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
    echo "PR_CI_STATE status=error reason=not_privileged" >&2
    exit 2
fi

set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_CI_STATE status=error reason=lib_dir_unresolvable" >&2; exit 2; }
# The library loader — and it obeys its own rule. A helper cannot load the file
# that defines it, so this sequence is written out here; that asymmetry is
# irreducible, but it is not a licence to load the loader carelessly. An exported
# `rb_load` survives into this shell and an empty `loadlib.sh` still sources
# successfully, so without the clear the first load runs the INHERITED
# function — and a stale loader is the one thing that can make every OTHER load
# look clean. See loadlib.sh and issue #22.
unset -f rb_load 2>/dev/null || {
    echo "PR_CI_STATE status=error reason=loadlib_stale_definition" >&2; exit 2; }
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
    echo "PR_CI_STATE status=error reason=loadlib_unreadable" >&2; exit 2; }
# `run_limited` — the portable watchdog. A `gh` call that hangs on a dead
# connection never returns, and the caller's `PR_CI_TIMEOUT` is then not a bound at
# all: the round gate waits forever on a probe that is the thing being bounded.
# Stock macOS ships no GNU `timeout`, which is why this is a shared helper rather
# than a one-line wrapper.
#
# `testlib.sh` is the fixture watchdog by history and is a runtime dependency now.
# The alternative was a second copy of ninety lines that already exist and are
# already tested, which is the duplication issues #11 and #18 were opened for.
# THE FIRST LOAD CARRIES THE SENTINEL, because it is what the preflight used to
# say. An empty `loadlib.sh` leaves the stub, the stub returns 127, and without
# this arm the only trace is a bare exit status — the ordinary-looking empty
# answer `CLAUDE.md` forbids. 127 is the stub's and nothing else's: `rb_load`'s
# own refusals report their own reason and their own status.
rb_load "$_RB_SELF_DIR" testlib run_limited "PR_CI_STATE status=error" || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "PR_CI_STATE status=error reason=loadlib_empty" >&2
    exit 2; }
# `sha_reason` — one definition of "a full commit SHA" across the plugin, used
# below to validate both the OID asked about and the one the API returns.
rb_load "$_RB_SELF_DIR" recordlib sha_reason "PR_CI_STATE status=error" || exit 2
rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_CI_STATE status=error" || exit 2
rb_identity || {
    echo "PR_CI_STATE status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }

PR="${1:-}"
case "$PR" in
    ""|*[!0-9]*) echo "usage: $0 <pr> [--required] [--head <oid>]" >&2; exit 2 ;;
esac
shift
REQUIRED=""; WANT_HEAD=""; DEADLINE="${PR_CI_PROBE_TIMEOUT:-60}"
# A malformed bound falls back to the default rather than removing the watchdog:
# a typo must not turn a bounded probe into an unbounded one. Leading zeros are
# rejected because Bash reads them as octal in arithmetic.
case "$DEADLINE" in ""|0|0*|*[!0-9]*|??????*) DEADLINE=60 ;; esac
# ONE DEADLINE FOR THE WHOLE RUN, not one per call. This script makes up to three
# sequential requests, and giving each the full allowance meant a five-second
# budget could be spent three times over: a head lookup that took four seconds,
# then a checks request that hung for five, then a confirmation that hung for five
# more. The caller's bound is then not a bound at all.
_RB_T0=$SECONDS
# What is left — and NOTHING when the deadline has passed. Clamping an exhausted
# budget up to one second granted a fresh allowance to every remaining call, each
# of which can then take that second plus the watchdog's five-second escalation:
# the bound turned into a floor. An expired deadline is not a short deadline.
rb_left() {
    local left=$((DEADLINE - (SECONDS - _RB_T0)))
    [ "$left" -ge 1 ] || return 1
    printf '%s' "$left"
    return 0
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --required) REQUIRED="--required"; shift ;;
        --head)
            # A missing value is usage, not something to recover from: `shift 2`
            # on a one-element list leaves the flag consuming nothing and the
            # check silently unpinned.
            [ "$#" -ge 2 ] || { echo "usage: $0 <pr> [--required] [--head <oid>]" >&2; exit 2; }
            WANT_HEAD="$2"; shift 2 ;;
        *) echo "usage: $0 <pr> [--required] [--head <oid>]" >&2; exit 2 ;;
    esac
done
if [ -n "$WANT_HEAD" ]; then
    # THE HEAD IS CONFIRMED FIRST, and what that is worth depends on which
    # question follows. `--required` goes to `gh pr checks`, which takes a PR
    # number and answers about whatever the API currently calls its head — for a
    # moment after a push that is still the PREVIOUS head, so a green answer
    # describes the commit from the round before, which is the last round's answer
    # to this round's question and reads as permission to close. There this
    # confirmation is half of a bracket. The all-checks question is addressed by
    # the commit, so there it only reports whether the head has since moved.
    #
    # A MISMATCH IS ITS OWN VERDICT either way, rather than an error: the caller's
    # correct response is to wait, not to stop.
    _reason="$(sha_reason "$WANT_HEAD")" || {
        echo "PR_CI_STATE pr=$PR status=error reason=$_reason head=$WANT_HEAD" >&2; exit 2; }
    _left_head="$(rb_left)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=deadline_exhausted" >&2; exit 2; }
    HEAD_NOW="$(run_limited "$_left_head" gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" \
                  --json headRefOid --jq '.headRefOid' 2>/dev/null)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=head_unreadable" >&2; exit 2; }
    # Anything `gh` printed before failing is not data, and the shape is checked
    # rather than trusted: a partial read that happened to equal the wanted OID
    # would otherwise unpin the check it was added to pin.
    _reason="$(sha_reason "$HEAD_NOW")" || {
        echo "PR_CI_STATE pr=$PR status=error reason=$_reason head=$HEAD_NOW" >&2; exit 2; }
    if [ "$HEAD_NOW" != "$WANT_HEAD" ]; then
        echo "PR_CI_STATE pr=$PR status=stale head=$HEAD_NOW want=$WANT_HEAD"
        exit 5
    fi
fi
# The head is confirmed AGAIN after the checks are read, below. Confirming only
# before leaves a window: a push landing between the two calls means the checks
# describe a head nobody verified, and its first `none` inherits the grace the
# previous head had almost finished earning.

# "NONE CONFIGURED" IS NOT "COULD NOT TELL". `gh pr checks` exits NON-ZERO when
# there is nothing to report, saying so on stderr — not because anything failed.
# Treating every non-zero as unreadable blocked every repository without branch
# protection, permanently: not a fail-closed guard but a gate that never opens,
# and found by trying to merge rather than by reading the code.
#
# THE WHOLE DIAGNOSTIC IS MATCHED, not searched for a phrase. `gh` has no
# dedicated status for this case, so the message is the only signal, and a
# substring test accepted it inside a LARGER failure: a run that printed the
# benign line and then failed for an unrelated reason was classified as benign.
# Matching the entire message means an extra line, an extra sentence or a wrapped
# error all fall through to the blocking branch, which is the direction that
# cannot be wrong.
#
# Both wordings are accepted because `gh` drops "required" when the branch has no
# checks whatsoever, and both mean the same thing here: nothing to be green.
checks_msg_is_none_configured() {
    case "$1" in
        *"
"*) return 1 ;;                       # more than one line is more than one thing
    esac
    case "$1" in
        "no checks reported on the '"*"' branch"|"no required checks reported on the '"*"' branch")
            return 0 ;;
    esac
    return 1
}

# ── THE COMMIT-ADDRESSED READ, for the all-checks question ─────────────────
#
# `gh pr checks` is addressed by PULL REQUEST and its answer carries no OID, so
# bracketing it with head confirmations narrows when a head can move and never
# binds the answer to a commit. These two endpoints ARE addressed by a commit:
# what they return is about the OID in the path and nothing else.
#
# ONLY FOR THE ALL-CHECKS QUESTION. `--required` needs to know which contexts
# branch protection requires, and that read is not available: classic protection
# needs admin and denies with a 404 indistinguishable from "not protected", while
# the ruleset endpoints are readable without admin but do not see classic
# protection at all. Measured on #214. So `--required` keeps the bracketed PR-
# addressed query, and this one answers the question that needs no such read.
#
# IT IS NOT A SUPERSET OF WHAT IS REQUIRED, and an earlier version of this comment
# claimed it was. These endpoints report the checks that EXIST on the commit; a
# required context that has not reported has neither a check run nor a status, so
# this answer can be green while a requirement is unmet. What binding buys is that
# a check which DID report on the merge target cannot be masked by another
# commit's — not that the required set is covered. #214 stays open for that.
#
# BOTH SOURCES, because `gh pr checks` merges them and dropping one would make
# this laxer than what it replaces: check runs from the Checks API, and the legacy
# commit statuses that older integrations still post.
#
# AND `.statuses` RATHER THAN `.state` for the legacy read. That endpoint reports
# `state: "pending"` with an EMPTY `statuses` array when a commit has none — so
# taking the summary would make every commit without legacy statuses pending
# forever, which is a gate that never opens rather than one that fails closed.
commit_checks_verdict() {   # <oid> ; prints green|failed|pending|none|malformed
    local oid="$1" _left _runs _sts _v_runs _v_sts
    _left="$(rb_left)" || return 2
    _runs="$(run_limited "$_left" gh api --hostname "$HOST" \
        "repos/$OWNER/$REPO/commits/$oid/check-runs" --paginate 2>/dev/null)" || return 2
    _left="$(rb_left)" || return 2
    _sts="$(run_limited "$_left" gh api --hostname "$HOST" \
        "repos/$OWNER/$REPO/commits/$oid/status" --paginate 2>/dev/null)" || return 2
    # AN UNRECOGNISED CONCLUSION IS MALFORMED, not benign — the same rule the
    # bucket parse below follows, and for the reason `recordlib.sh` records: a
    # value outside the known set must not fall through a catch-all into green.
    _v_runs="$(printf '%s' "$_runs" | jq -r -s "$RECORDLIB_JQ"'
        object_pages_or_error("check_runs")
        | [ .[].check_runs[] ]
        | if length == 0 then "none"
          elif any(.[]; type != "object" or (.status | type) != "string") then "malformed"
          elif any(.[]; .status != "completed") then "pending"
          elif any(.[]; (.conclusion | type) != "string") then "malformed"
          elif any(.[]; .conclusion | IN("failure","cancelled","timed_out","action_required","startup_failure","stale")) then "failed"
          elif all(.[]; .conclusion | IN("success","neutral","skipped")) then "green"
          else "malformed" end' 2>/dev/null)" || return 2
    # THE NEWEST EVENT PER CONTEXT, not every event — a rule the check-run fold
    # above does NOT need, and the asymmetry is the endpoint's rather than ours:
    # `check-runs` filters to `latest` by default, so a re-run replaces what it
    # re-ran and there is nothing superseded to order. The combined-status endpoint
    # keeps the whole history: a context that reported `failure` and then `success`
    # on the same commit appears TWICE, and folding over all of them leaves the
    # commit failed forever — a rerun that went green could never reopen the round
    # or the merge gate. Only the latest event for a context is its current state.
    #
    # A TIE THAT DISAGREES IS MALFORMED. `created_at` is second-resolution and the
    # pages come back separately, so two events for one context at the same instant
    # cannot be ordered, and picking one is a guess about whether the commit is
    # green. Where they agree there is nothing to guess, which is why the newest
    # set is reduced with `unique` and only a set of more than one refuses.
    # `context` and `created_at` are validated for the same reason the state is:
    # this fold cannot group or order without them. The time is held to
    # `canonical_utc` rather than to being a string, because the ordering is
    # LEXICAL — a value like `zzzz` sorts after every real timestamp, so a junk
    # `created_at` on a `success` event would outrank the `failure` that really is
    # newest and report the commit green.
    _v_sts="$(printf '%s' "$_sts" | jq -r -s "$RECORDLIB_JQ"'
        object_pages_or_error("statuses")
        | [ .[].statuses[] ]
        | if length == 0 then "none"
          elif any(.[]; type != "object"
                        or (.state | type) != "string"
                        or (.context | type) != "string"
                        or (.created_at | canonical_utc | not)) then "malformed"
          else ( group_by(.context)
                 | map( (max_by(.created_at).created_at) as $t
                        | map(select(.created_at == $t))
                        | (map(.state) | unique) ) ) as $cur
            | if any($cur[]; length != 1) then "malformed"
              else ($cur | map(.[0])) as $st
                | if any($st[]; IN("failure","error")) then "failed"
                  elif any($st[]; . == "pending") then "pending"
                  elif all($st[]; . == "success") then "green"
                  else "malformed" end
              end
          end' 2>/dev/null)" || return 2
    # WORST-FIRST, and `none` only where BOTH said it. The tokens are disjoint, so
    # a substring test over the pair is the whole of the precedence.
    case "$_v_runs/$_v_sts" in
        *malformed*) printf '%s\n' malformed ;;
        *failed*)    printf '%s\n' failed ;;
        *pending*)   printf '%s\n' pending ;;
        *green*)     printf '%s\n' green ;;
        none/none)   printf '%s\n' none ;;
        *)           printf '%s\n' malformed ;;
    esac
    return 0
}

ERRF="$(mktemp 2>/dev/null)" || {
    echo "PR_CI_STATE pr=$PR status=error reason=no_scratch_file" >&2; exit 2; }
# THE CONTAINER IS VALIDATED BEFORE anything is concluded from it. `all(.[]; …)`
# over an empty stream is `true` by definition, so a successful read that returned
# an object, a null or an empty array came out as "everything passed".
#
# AND AN UNRECOGNISED BUCKET IS MALFORMED, not benign. `skipping` and `cancel` are
# documented today; a value outside the set this script knows must not fall
# through a catch-all into "green", which is the same shape as the review state
# that reached `dismissed` through a catch-all and drove a review loop. See
# recordlib.sh.
RC=0
# THE COMMIT-ADDRESSED PATH IS TAKEN WHERE IT CAN ANSWER, which is the all-checks
# question with a head to ask about. `--required` cannot use it — see the note on
# `commit_checks_verdict` — and neither can a call with no `--head`, because there
# is no commit to address.
if [ -n "$WANT_HEAD" ] && [ -z "$REQUIRED" ]; then
    OUT="$(commit_checks_verdict "$WANT_HEAD")" || RC=$?
    MSG=""
    if [ "$RC" -ne 0 ]; then
        echo "PR_CI_STATE pr=$PR status=error reason=commit_checks_unreadable rc=$RC head=$WANT_HEAD" >&2
        rm -f "$ERRF" 2>/dev/null
        exit 2
    fi
    rm -f "$ERRF" 2>/dev/null
else
_left_checks="$(rb_left)" || {
    echo "PR_CI_STATE pr=$PR status=error reason=deadline_exhausted" >&2; exit 2; }
OUT="$(run_limited "$_left_checks" gh pr checks "$PR" --repo "$HOST/$OWNER/$REPO" $REQUIRED --json bucket \
         --jq 'if type != "array" or length == 0 then "malformed"
               elif any(.[]; type != "object" or (.bucket | type) != "string") then "malformed"
               elif any(.[]; .bucket | IN("fail","cancel")) then "failed"
               elif any(.[]; .bucket == "pending") then "pending"
               elif all(.[]; .bucket | IN("pass","skipping")) then "green"
               else "malformed" end' 2>"$ERRF")" || RC=$?
# The READ has its own status, taken before `rm` overwrites it. A `cat` that
# emitted text containing "no checks" and then failed would otherwise be
# classified as the benign none-configured case — a failed probe reported as a
# repository with nothing to check.
MSG="$(cat "$ERRF" 2>/dev/null)"; MSG_RC=$?
rm -f "$ERRF" 2>/dev/null
[ "$MSG_RC" -eq 0 ] || {
    echo "PR_CI_STATE pr=$PR status=error reason=diagnostic_unreadable rc=$MSG_RC" >&2; exit 2; }
fi

# `gh pr checks` exits non-zero when a check FAILED as well as when it is pending
# or absent, so the status alone does not classify anything — the parsed value
# does, and the status only matters where there is no value to trust.
# THE READ IS BRACKETED BY THE HEAD, not merely preceded by a check of it. The
# confirmation above and the checks call are two requests, and a push landing
# between them means the answer describes a commit nobody verified — in the round
# loop, a head that had almost finished earning its grace hands that grace to a
# different commit, whose own checks have not been registered yet.
#
# So the head is read once more and must still be the one asked about.
#
# WHICH OF THE TWO QUESTIONS THIS IS DECIDES WHAT THE BRACKET IS WORTH. The
# all-checks question is answered by `commit_checks_verdict`, addressed by the OID
# in its path, so its answer is BOUND to the commit and this confirmation only
# reports whether the head has since moved. The `--required` question still goes
# through `gh pr checks`, which has no commit selector, so there the confirmations
# are a BRACKET: they catch a head that moves and stays moved, and an A → B → A
# whose both moves land between them is invisible to both. #214.
if [ -n "$WANT_HEAD" ]; then
    _left_after="$(rb_left)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=deadline_exhausted" >&2; exit 2; }
    HEAD_AFTER="$(run_limited "$_left_after" gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" \
                    --json headRefOid --jq '.headRefOid' 2>/dev/null)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=head_unreadable_after" >&2; exit 2; }
    _reason="$(sha_reason "$HEAD_AFTER")" || {
        echo "PR_CI_STATE pr=$PR status=error reason=$_reason head=$HEAD_AFTER" >&2; exit 2; }
    if [ "$HEAD_AFTER" != "$WANT_HEAD" ]; then
        echo "PR_CI_STATE pr=$PR status=stale head=$HEAD_AFTER want=$WANT_HEAD moved=during_checks"
        exit 5
    fi
fi

case "$OUT" in
    # GREEN REQUIRES A CLEAN STATUS. `gh` can emit a complete, valid green result
    # and then exit non-zero because the request failed part-way, and command
    # substitution keeps what it printed — so the one verdict that opens a gate
    # was the one being taken on trust. In the merge gate that is an
    # administrator merge on an untrusted partial response.
    #
    # `failed` and `pending` are accepted whatever the status, because both are
    # directions the caller stops or waits in: a wrong `failed` costs a round, a
    # wrong `green` costs the gate.
    green)
        [ "$RC" -eq 0 ] || {
            echo "PR_CI_STATE pr=$PR status=error reason=green_from_failed_probe rc=$RC" >&2
            exit 2
        }
        echo "PR_CI_STATE pr=$PR status=green";   exit 0 ;;
    failed)  echo "PR_CI_STATE pr=$PR status=failed";  exit 1 ;;
    pending) echo "PR_CI_STATE pr=$PR status=pending"; exit 3 ;;
    # `none` REACHES HERE AS A VALUE on the commit-addressed path, where this
    # script does the classifying and can say so directly. On the PR-addressed
    # path it arrives as a MESSAGE and a status, below, because that is the only
    # way `gh pr checks` reports it.
    none)
        [ "$RC" -eq 0 ] || {
            echo "PR_CI_STATE pr=$PR status=error reason=none_from_failed_probe rc=$RC" >&2
            exit 2
        }
        echo "PR_CI_STATE pr=$PR status=none"; exit 4 ;;
esac
# AND THE STATUS HAS TO BE THE ONE THAT MEANS IT. `gh` reports "nothing to
# report" by exiting 1 with that message on stderr; a probe that printed the
# message and then DIED — the watchdog's 124 for a hang, its 125 for a watchdog
# that could not do its job — carries the same text and means something else
# entirely. Ignoring the status there turned a failed probe into `none`, which the
# round gate accepts after its grace and the merge gate accepts at once: a hung
# request becoming merge permission.
#
# 1 is required rather than "not 124 and not 125", because the next unexpected
# status should block too. `gh pr checks` documents 8 for pending, which is
# handled above by its value; there is no documented third code for this case.
if checks_msg_is_none_configured "$MSG" && [ "$RC" -eq 1 ]; then
    echo "PR_CI_STATE pr=$PR status=none"
    exit 4
fi
echo "PR_CI_STATE pr=$PR status=error reason=unreadable rc=$RC out=$OUT err=$MSG" >&2
exit 2
