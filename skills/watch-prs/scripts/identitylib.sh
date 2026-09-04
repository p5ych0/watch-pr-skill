#!/usr/bin/env bash
# Which repository this checkout is, derived from `origin`. Sourced, never executed.

# rb_identity ; 0 with HOST, OWNER and REPO set — 2 with RB_IDENTITY_REASON set and the three
# untouched. It sets rather than prints: three values through one string make any delimiter
# a value a remote can contain. `REVIEW_BUS_REMOTE`, `REVIEW_BUS_OWNER` and
# `REVIEW_BUS_REPO` override the derivation — the caller stating the identity.
#
# The declaration below is read by `pr-selfcheck.sh` and proved by `test-identitylib.sh`.
# rb-assigns: HOST OWNER REPO RB_IDENTITY_REASON
rb_identity() {
    local remote p h _host _owner _repo
    RB_IDENTITY_REASON=''
    # The derived lookup takes its status: `git` can print a plausible URL and then fail.
    if [ -n "${REVIEW_BUS_REMOTE:-}" ]; then
        remote="$REVIEW_BUS_REMOTE"
    else
        remote="$(git remote get-url origin 2>/dev/null)" || remote=""
    fi
    if [ -z "$remote" ]; then
        RB_IDENTITY_REASON='no_origin'
        return 2
    fi
    p="${remote%.git}"; _repo="${REVIEW_BUS_REPO:-${p##*/}}"; p="${p%/*}"
    _owner="${REVIEW_BUS_OWNER:-${p##*[:/]}}"
    # Only a transport that reaches a GitHub server names an identity: a local path, a
    # `file://` remote or a bare host defaulted to github.com would address the unrelated
    # public repository of that name.
    case "$remote" in
        ssh://*|git://*|https://*|http://*|git+ssh://*)
                h="${remote#*://}"; h="${h#*@}"; _host="${h%%[:/]*}" ;;
        *://*)
            RB_IDENTITY_REASON="origin_transport_unsupported remote=$remote"
            return 2 ;;
        *@*:*)  h="${remote#*@}";   _host="${h%%:*}" ;;
        /*|.*|~*)
            RB_IDENTITY_REASON="origin_has_no_host remote=$remote"
            return 2 ;;
        *:*/*)  _host="${remote%%:*}" ;;
        *)
            RB_IDENTITY_REASON="origin_has_no_host remote=$remote"
            return 2 ;;
    esac
    case "$_host" in
        ""|*/*|*:*)
            RB_IDENTITY_REASON="origin_host_unparseable remote=$remote"
            return 2 ;;
    esac
    # Assigned only once everything above has passed, so a refused origin leaves nothing behind.
    HOST="$_host"; OWNER="$_owner"; REPO="$_repo"
    return 0
}
