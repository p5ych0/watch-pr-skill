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
# `sha_reason` — one definition of "a full commit SHA" across the plugin, used
# below to validate both the OID asked about and the one the API returns.
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
REQUIRED=""; WANT_HEAD=""
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
    HEAD_NOW="$(gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" --json headRefOid \
                  --jq '.headRefOid' 2>/dev/null)" || {
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
OUT="$(gh pr checks "$PR" --repo "$HOST/$OWNER/$REPO" $REQUIRED --json bucket \
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
if checks_msg_is_none_configured "$MSG"; then
    echo "PR_CI_STATE pr=$PR status=none"
    exit 4
fi
echo "PR_CI_STATE pr=$PR status=error reason=unreadable rc=$RC out=$OUT err=$MSG" >&2
exit 2
