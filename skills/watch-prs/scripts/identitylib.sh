#!/usr/bin/env bash
# Which repository this checkout is, for the `gh` calls every helper makes.
# Sourced, never executed.
#
# NOT named `test-*.sh`: `pr-selfcheck.sh` and CI both run every `test-*.sh` as a
# test, and a library that ran as one would report a vacuous pass. Same reason as
# `recordlib.sh` and `testlib.sh`.
#
# WHY THIS EXISTS
#
# This block lived in four files — `pr-findings.sh`, `pr-review-state.sh`,
# `pr-round-count.sh` and `SKILL.md` — byte-identical in the three scripts apart
# from the sentinel in their error lines. That is the shape issue #11 was opened
# for, and `test-pr-identity.sh` already recorded the cost in a comment:
#
#     The hostless and file-transport rules landed in all four, but the only
#     behavioural fixtures were in `test-pr-review-state.sh` — so reverting the
#     branch in `pr-findings.sh` or `pr-round-count.sh` left the suite green and
#     quietly restored the wrong-repository path.
#
# Both of those rules had to be written four times, and the fixtures proving them
# had to be built a second time afterwards to cover the copies. One definition
# removes the mechanism rather than the instances. Issue #18.
#
# WHAT A DRIFTED COPY COSTS. An origin whose host cannot be derived, defaulted to
# github.com while the path split still yields a plausible `acme/widget`, points
# every `gh` call at the unrelated PUBLIC repository of that name — reading,
# commenting on and merging there. The failure is not an error; it is silent
# success against the wrong project.

# Derive the identity from `origin`.
#
#   rb_identity || { echo "PR_X status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }
#   REPO_SLUG="$HOST/$OWNER/$REPO"
#
# On success: sets HOST, OWNER and REPO, and returns 0.
# On failure: sets RB_IDENTITY_REASON to the caller's `reason=` text and returns 2.
#
# IT SETS VARIABLES RATHER THAN PRINTING THEM. The obvious signature —
# `id="$(rb_identity)"` — runs in a subshell, so it has to serialise three values
# through one string and the caller has to split them back. Any delimiter is then
# a value a remote can contain, and a remote carrying it silently shifts the
# fields: OWNER read as a host, REPO read as an owner, every `gh` call addressed
# somewhere else. That is the exact failure this parser exists to prevent, so the
# transport does not get to reintroduce it. The reason travels the same way, in
# `RB_IDENTITY_REASON`, because a failing call has no stdout to use either.
#
# `REVIEW_BUS_REMOTE`, `REVIEW_BUS_OWNER` and `REVIEW_BUS_REPO` override the
# derivation so tests can supply an identity without a real remote. See CLAUDE.md
# § Repo-agnostic invariant.
rb_identity() {
    local remote p h
    RB_IDENTITY_REASON=''
    # The STATUS is taken, not just the output. `git remote get-url origin` can
    # print a plausible URL and then exit non-zero — a partially-configured
    # remote, a permissions error mid-read — and command substitution keeps
    # whatever it wrote. Every `gh` call is addressed by the identity derived
    # here, so an untrusted one sends this project's review traffic elsewhere.
    #
    # Only the DERIVED lookup is guarded this way: an explicit REVIEW_BUS_REMOTE
    # is the caller stating the identity, and has no status to check.
    if [ -n "${REVIEW_BUS_REMOTE:-}" ]; then
        remote="$REVIEW_BUS_REMOTE"
    else
        remote="$(git remote get-url origin 2>/dev/null)" || remote=""
    fi
    if [ -z "$remote" ]; then
        RB_IDENTITY_REASON='no_origin'
        return 2
    fi
    p="${remote%.git}"; REPO="${REVIEW_BUS_REPO:-${p##*/}}"; p="${p%/*}"
    OWNER="${REVIEW_BUS_OWNER:-${p##*[:/]}}"
    # The HOST is derived from origin too, and passed explicitly to every call.
    # `gh` takes the hostname from `GH_HOST` when a command supplies none, so
    # with that set these calls could read the same-numbered PR from a different
    # GitHub host while the local origin identifies another project entirely —
    # the same class as the `GH_REPO` hole, one level up.
    #
    # The AUTHORITY is parsed, then compared. Matching `github.com` anywhere in
    # the URL sent an enterprise origin such as
    # `git@ghe.example:org/github.com-mirror.git` to the public host, and a
    # userless SCP-style enterprise origin fell through to the same default — so
    # every pinned command would act on the wrong GitHub entirely.
    #
    # A remote with NO NETWORK AUTHORITY is not an identity, and must not be
    # given one. A local-path origin such as `/srv/mirrors/acme/widget.git` or
    # `../acme/widget.git` has no host, and defaulting it to github.com while the
    # path split still yields `acme/widget` pointed every `gh` call at the
    # unrelated PUBLIC repository of that name.
    #
    # The TRANSPORT is checked, not only the authority.
    # `file://github.com/srv/acme/widget.git` is a file-transport remote that
    # carries an authority, so parsing it as a URL yielded HOST=github.com while
    # the path split yielded `acme/widget` — the same wrong-public-repository
    # outcome as a bare local path, reached through the arm that was supposed to
    # be the safe one. Only transports that actually reach a GitHub server are
    # accepted; anything else names no reviewable identity.
    case "$remote" in
        ssh://*|git://*|https://*|http://*|git+ssh://*)
                h="${remote#*://}"; h="${h#*@}"; HOST="${h%%[:/]*}" ;;
        *://*)
            RB_IDENTITY_REASON="origin_transport_unsupported remote=$remote"
            return 2 ;;
        *@*:*)  h="${remote#*@}";   HOST="${h%%:*}" ;;
        /*|.*|~*)
            RB_IDENTITY_REASON="origin_has_no_host remote=$remote"
            return 2 ;;
        *:*/*)  HOST="${remote%%:*}" ;;
        *)
            RB_IDENTITY_REASON="origin_has_no_host remote=$remote"
            return 2 ;;
    esac
    case "$HOST" in
        ""|*/*|*:*)
            RB_IDENTITY_REASON="origin_host_unparseable remote=$remote"
            return 2 ;;
    esac
    return 0
}
