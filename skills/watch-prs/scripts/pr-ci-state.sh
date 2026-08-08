#!/usr/bin/env bash
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
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_CI_STATE status=error reason=lib_dir_unresolvable" >&2; exit 2; }
# The stale definition is cleared first and the clearing is checked: an exported
# `rb_identity` survives into this shell, an empty library still sources cleanly,
# and `readonly -f` makes the clearing fail while leaving the function installed.
# See identitylib.sh.
unset -f rb_identity 2>/dev/null || {
    echo "PR_CI_STATE status=error reason=identitylib_stale_definition" >&2; exit 2; }
# `run_limited` — the portable watchdog. A `gh` call that hangs on a dead
# connection never returns, and the caller's `PR_CI_TIMEOUT` is then not a bound at
# all: the round gate waits forever on a probe that is the thing being bounded.
# Stock macOS ships no GNU `timeout`, which is why this is a shared helper rather
# than a one-line wrapper.
#
# `testlib.sh` is the fixture watchdog by history and is a runtime dependency now.
# The alternative was a second copy of ninety lines that already exist and are
# already tested, which is the duplication issues #11 and #18 were opened for.
# Cleared first and the clearing checked, exactly as for `rb_identity`: an
# exported `run_limited` survives into this shell, an empty library still sources
# cleanly, and `readonly -f` makes the clearing fail while leaving the old one
# installed. A stale watchdog without the kill behaviour lets a hung `gh` outlive
# every bound here.
unset -f run_limited 2>/dev/null || {
    echo "PR_CI_STATE status=error reason=testlib_stale_definition" >&2; exit 2; }
# shellcheck source=testlib.sh
. "$_RB_SELF_DIR/testlib.sh" || {
    echo "PR_CI_STATE status=error reason=testlib_unreadable" >&2; exit 2; }
[ "$(type -t run_limited 2>/dev/null)" = function ] || {
    echo "PR_CI_STATE status=error reason=testlib_empty" >&2; exit 2; }
# `sha_reason` — one definition of "a full commit SHA" across the plugin, used
# below to validate both the OID asked about and the one the API returns.
unset -f sha_reason 2>/dev/null || {
    echo "PR_CI_STATE status=error reason=recordlib_stale_definition" >&2; exit 2; }
# shellcheck source=recordlib.sh
. "$_RB_SELF_DIR/recordlib.sh" || {
    echo "PR_CI_STATE status=error reason=recordlib_unreadable" >&2; exit 2; }
[ "$(type -t sha_reason 2>/dev/null)" = function ] || {
    echo "PR_CI_STATE status=error reason=recordlib_empty" >&2; exit 2; }
# shellcheck source=identitylib.sh
. "$_RB_SELF_DIR/identitylib.sh" || {
    echo "PR_CI_STATE status=error reason=identitylib_unreadable" >&2; exit 2; }
[ "$(type -t rb_identity 2>/dev/null)" = function ] || {
    echo "PR_CI_STATE status=error reason=identitylib_empty" >&2; exit 2; }
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
# What is left, never less than one — a zero or negative limit makes `timeout`
# either refuse or run unbounded, and both are worse than one last short attempt.
rb_left() {
    local left=$((DEADLINE - (SECONDS - _RB_T0)))
    [ "$left" -lt 1 ] && left=1
    printf '%s' "$left"
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
    # THE CHECKS ARE ASKED ABOUT A PR, NOT A COMMIT. `gh pr checks` takes a PR
    # number and answers about whatever the API currently calls its head — and
    # for a moment after a push that is still the PREVIOUS head. A green answer
    # then describes the commit from the round before, which is the last round's
    # answer to this round's question and reads as permission to close.
    #
    # So the head is confirmed first, and a mismatch is its own verdict rather
    # than an error: the caller's correct response is to wait, not to stop.
    _reason="$(sha_reason "$WANT_HEAD")" || {
        echo "PR_CI_STATE pr=$PR status=error reason=$_reason head=$WANT_HEAD" >&2; exit 2; }
    HEAD_NOW="$(run_limited "$(rb_left)" gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" \
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
OUT="$(run_limited "$(rb_left)" gh pr checks "$PR" --repo "$HOST/$OWNER/$REPO" $REQUIRED --json bucket \
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

# `gh pr checks` exits non-zero when a check FAILED as well as when it is pending
# or absent, so the status alone does not classify anything — the parsed value
# does, and the status only matters where there is no value to trust.
# THE RESPONSE IS BOUND TO THE HEAD, not merely preceded by a check of it. The
# confirmation above and the checks call are two requests, and a push landing
# between them means the answer describes a commit nobody verified — in the round
# loop, a head that had almost finished earning its grace hands that grace to a
# different commit, whose own checks have not been registered yet.
#
# So the head is read once more and must still be the one asked about. This cannot
# close the window entirely — a push can always land after the last read — but it
# bounds it to the moment rather than to the whole checks request, and any movement
# is reported as `stale`, which the caller waits on and which resets the grace.
if [ -n "$WANT_HEAD" ]; then
    HEAD_AFTER="$(run_limited "$(rb_left)" gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" \
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
