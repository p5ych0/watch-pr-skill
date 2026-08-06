#!/usr/bin/env bash
# Read a PR's findings, and the blocking review body when there is one.
#
#   pr-findings.sh list <pr>
#   pr-findings.sh blocked-body <pr> <reviewer-login> [head-oid]
#
#   0  output printed (possibly empty: no unresolved threads / no blocking body)
#   2  the read could not be trusted — the caller MUST NOT act on a partial answer
#
# WHY THIS IS A SCRIPT AND NOT A SNIPPET IN SKILL.md
#
# It was a snippet. Three consecutive review rounds found fail-open cases in it —
# an unchecked `jq` status, an unvalidated `hasNextPage`, a `gh api --jq` that
# could not run at all, a missing `pipefail`, interpolation rendering a missing
# author as `null` — and each fix was itself prose that no test executed. This
# repository has been here before: the merge-range check lived inline in SKILL.md
# "where nothing executed it", shipped two defects, and became
# `pr-merge-range.sh`. Code that decides whether the driver has read the findings
# belongs where a test can run it.
#
# `set -uo pipefail`, NOT `-e`: `gh` probes fail as normal operation and the
# result is control flow. `pipefail` matters here in particular — `gh --paginate`
# can write a valid page and THEN fail, and without it the pipeline would report
# jq's success and the partial page would pass for the whole answer.
set -uo pipefail

# The STATUS is taken, not just the output. `git remote get-url origin` can print
# a plausible URL and then exit non-zero — a partially-configured remote, a
# permissions error mid-read — and command substitution keeps whatever it wrote.
# `$OWNER/$REPO` derived from that drives every `gh` call below, so an untrusted
# identity here sends one project's review traffic somewhere else entirely.
#
# Only the DERIVED lookup is guarded this way: an explicit REVIEW_BUS_REMOTE is
# the caller stating the identity, and has no status to check.
if [ -n "${REVIEW_BUS_REMOTE:-}" ]; then
    REMOTE="$REVIEW_BUS_REMOTE"
else
    REMOTE="$(git remote get-url origin 2>/dev/null)" || REMOTE=""
fi
if [ -z "$REMOTE" ]; then
    echo "PR_FINDINGS status=error reason=no_origin" >&2
    exit 2
fi
_p="${REMOTE%.git}"; REPO="${REVIEW_BUS_REPO:-${_p##*/}}"; _p="${_p%/*}"
OWNER="${REVIEW_BUS_OWNER:-${_p##*[:/]}}"
# The HOST is derived from origin too, and passed explicitly. `gh` takes the
# hostname from `GH_HOST` when a command supplies none, so with that set these
# calls could read the same-numbered PR from a different GitHub host while the
# local origin identifies another project entirely — the same class as the
# `GH_REPO` hole, one level up.
# The AUTHORITY is parsed, then compared. Matching `github.com` anywhere in the
# URL sent an enterprise origin such as
# `git@ghe.example:org/github.com-mirror.git` to the public host, and a userless
# SCP-style enterprise origin fell through to the same default — so every pinned
# command would act on the wrong GitHub entirely.
# A remote with NO NETWORK AUTHORITY is not an identity, and must not be given
# one. A local-path origin such as `/srv/mirrors/acme/widget.git` or
# `../acme/widget.git` has no host, and defaulting it to github.com while the
# path split still yields `acme/widget` pointed every `gh` call at the unrelated
# PUBLIC repository of that name — reading, commenting on, and merging the
# same-numbered PR there.
case "$REMOTE" in
    *://*)  _h="${REMOTE#*://}"; _h="${_h#*@}"; HOST="${_h%%[:/]*}" ;;
    *@*:*)  _h="${REMOTE#*@}";   HOST="${_h%%:*}" ;;
    /*|.*|~*)
        echo "PR_FINDINGS status=error reason=origin_has_no_host remote=$REMOTE" >&2
        exit 2 ;;
    *:*/*)  HOST="${REMOTE%%:*}" ;;
    *)
        echo "PR_FINDINGS status=error reason=origin_has_no_host remote=$REMOTE" >&2
        exit 2 ;;
esac
case "$HOST" in
    ""|*/*|*:*) echo "PR_FINDINGS status=error reason=origin_host_unparseable remote=$REMOTE" >&2; exit 2 ;;
esac
REPO_SLUG="$HOST/$OWNER/$REPO"

# Every unresolved thread, paginated, with the page shape validated before any
# of it is formatted.
cmd_list() {
    # `seen` is a record separator-delimited set of every cursor this walk has
    # requested, so a cycle of ANY length is caught rather than only a cursor
    # repeating itself immediately. RS (0x1E) cannot occur in a base64 GraphQL
    # cursor, so it cannot make two different cursors look like one.
    local pr="$1" cursor="null" page nodes has_next next
    local RS=$'\x1e' seen
    seen="${RS}null${RS}"
    while :; do
        page=$(gh api --hostname "$HOST" graphql -F number="$pr" -f owner="$OWNER" -f repo="$REPO" -F cursor="$cursor" -f query='
            query($owner:String!,$repo:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){
              reviewThreads(first:100, after:$cursor){ pageInfo{hasNextPage endCursor}
                nodes{id isResolved path line comments(first:1){nodes{databaseId author{login} body}}} }}}}' 2>/dev/null) || {
            echo "PR_FINDINGS pr=$pr status=error reason=fetch_failed" >&2
            return 2
        }
        # The shape is checked before anything is printed. `jq -e` alone is not
        # enough: string interpolation renders a missing author or body as `null`
        # and still exits 0, so a malformed page would produce "null" finding text
        # that the driver would reply to, resolve, and summarise against.
        # A GraphQL 200 can carry BOTH `errors` and a structurally valid `data`.
        # The partial data satisfies every shape check below while silently
        # omitting threads, so a short findings list would be indistinguishable
        # from a shorter review — and the driver replies to, resolves and
        # summarises against exactly that list.
        printf '%s' "$page" | jq -e 'has("errors") | not' >/dev/null 2>&1 || {
            echo "PR_FINDINGS pr=$pr status=error reason=graphql_errors" >&2
            return 2
        }
        nodes=$(printf '%s' "$page" | jq -e -r '
            .data.repository.pullRequest.reviewThreads.nodes as $n
            | if ($n | type) != "array"
                 or any($n[];
                        type != "object"
                        or (.id | type) != "string"
                        or (.isResolved | type) != "boolean"
                        or (.comments.nodes | type) != "array"
                        or (select(.isResolved == false)
                            | (.comments.nodes | length) == 0
                              or (.comments.nodes[0].author.login | type) != "string"
                              or (.comments.nodes[0].databaseId | type) != "number"
                              or (.comments.nodes[0].body | type) != "string"))
              then error("malformed thread node")
              # The thread ID is printed with every finding. path:line is not an
              # identifier: two unresolved comments can share a line, and a fix
              # commit shifts the lines anyway — so the driver had nothing stable
              # to resolve against and could close the wrong thread.
              #
              # The COMMENT id is printed alongside it: resolving takes the
              # thread id over GraphQL, a reaction takes the REST id of the
              # comment, and neither substitutes for the other. Codex asks for a
              # thumbs reaction on every finding, and that is the only signal it
              # gets about whether a review was worth making.
              else ( [ $n[] | select(.isResolved == false) ]
                     | map("### \(.path):\(.line) [\(.comments.nodes[0].author.login)]\nthread=\(.id) comment=\(.comments.nodes[0].databaseId)\n\(.comments.nodes[0].body)\n")
                     | join("\n") )
              end' 2>/dev/null) || {
            echo "PR_FINDINGS pr=$pr status=error reason=malformed_page" >&2
            return 2
        }
        [ -n "$nodes" ] && printf '%s\n' "$nodes"

        # The pagination state is validated, not assumed: a missing or malformed
        # `hasNextPage` read as "last page" would silently truncate the findings,
        # and a truncated list is indistinguishable from a shorter review.
        has_next=$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage') || {
            echo "PR_FINDINGS pr=$pr status=error reason=pageinfo_unreadable" >&2
            return 2
        }
        case "$has_next" in
            false) return 0 ;;
            true)  ;;
            *) echo "PR_FINDINGS pr=$pr status=error reason=hasnextpage_not_boolean" >&2; return 2 ;;
        esac
        # The status is taken here for the same reason it is taken for
        # hasNextPage: `jq` can print a plausible cursor and then fail, and
        # command substitution keeps what it printed.
        next=$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor') || {
            echo "PR_FINDINGS pr=$pr status=error reason=cursor_unreadable" >&2
            return 2
        }
        { [ -n "$next" ] && [ "$next" != "null" ]; } || {
            echo "PR_FINDINGS pr=$pr status=error reason=missing_cursor" >&2
            return 2
        }
        # The cursor must be one this walk has NEVER requested — not merely
        # different from the last one. Comparing against the previous cursor
        # alone caught only an immediate self-loop: a sequence like
        # `null → A → B → A → B …` passes that check on every step and alternates
        # forever. A cycle of any length is still a hang, and a hang is worse
        # than the documented failure, because nothing times out, no status is
        # returned, and the caller waits on a command that will never answer.
        case "$seen" in
            *"$RS$next$RS"*)
                echo "PR_FINDINGS pr=$pr status=error reason=cursor_cycle" >&2
                return 2 ;;
        esac
        seen="$seen$next$RS"
        cursor="$next"
    done
}

# The body of a CHANGES_REQUESTED review by $2 ON THIS HEAD.
#
# A reviewer can put the whole request in the body with no inline comment, in
# which case the merge gate blocks while `list` shows nothing to fix — a stuck
# loop rather than a request. Scoped to the head on purpose: a stale
# CHANGES_REQUESTED on an older commit, already superseded by a signoff on the
# current one, would otherwise be printed as an active finding.
cmd_blocked_body() {
    local pr="$1" who="$2" head="${3:-}" raw out
    if [ -z "$head" ]; then
        head=$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefOid --jq '.headRefOid' 2>/dev/null) || {
            echo "PR_FINDINGS pr=$pr status=error reason=head_lookup_failed" >&2
            return 2
        }
    fi
    # Length as well as alphabet: `abc` is all-hex and would pass a character
    # check, then match no commit_id at all — printing nothing with rc 0, which is
    # indistinguishable from "no blocking body". pr_head_oid validates the same
    # way for the same reason.
    case "$head" in
        *[!0-9a-f]*|"") echo "PR_FINDINGS pr=$pr status=error reason=bad_head" >&2; return 2 ;;
    esac
    [ "${#head}" -eq 40 ] || { echo "PR_FINDINGS pr=$pr status=error reason=head_not_full_sha" >&2; return 2; }

    # Captured separately from the parse. `gh --paginate` can write a valid page
    # and then exit non-zero, and a pipeline would report jq's success while the
    # partial page passed for the whole answer.
    raw=$(gh api --hostname "$HOST" "repos/$OWNER/$REPO/pulls/$pr/reviews" --paginate 2>/dev/null) || {
        echo "PR_FINDINGS pr=$pr status=error reason=reviews_fetch_failed" >&2
        return 2
    }
    # The LATEST review of this head decides, not "any CHANGES_REQUESTED record".
    # Filtering on state alone printed a request the reviewer had already
    # SUPERSEDED with an approval on the same head, sending the driver into
    # another fix round after a signoff. This mirrors how pr-review-state.sh picks
    # the authoritative review.
    #
    # commit_id and submitted_at are validated as a full SHA and a complete ISO
    # timestamp because this helper FILTERS and SORTS on them: a short commit_id
    # is silently filtered away as another head, and a junk timestamp sorts above
    # a real one and returns stale text.
    #
    # The record SHAPE is validated before anything is selected. The optional
    # selectors below would otherwise map a malformed page away and exit 0, making
    # a parse failure indistinguishable from "this body-only CHANGES_REQUESTED has
    # no text" — and that is the one finding the driver has to act on.
    out=$(printf '%s' "$raw" | jq -s -r --arg who "$who" --arg head "$head" '
        if length == 0 or any(.[]; type != "array") then error("bad page")
        else [ .[][] ] as $all
          | if any($all[];
                   type != "object"
                   or (.user | type) != "object"
                   or (.user.login | type) != "string"
                   or (.commit_id | type) != "string"
                   or (.commit_id | test("^[0-9a-f]{40}$") | not)
                   # The known set, not merely "a string or null". This helper
                   # SUPPRESSES output for anything that is not exactly
                   # CHANGES_REQUESTED, so a record with a null or unrecognised
                   # state produced empty stdout and rc 0 — indistinguishable
                   # from "this blocking review has no body". The driver reaches
                   # here precisely because it saw `state=blocked`, so that is
                   # the one case where silence loses the only text there is.
                   or (.state | IN("PENDING","APPROVED","CHANGES_REQUESTED","COMMENTED","DISMISSED") | not)
                   or ((.submitted_at | type) != "string" and .submitted_at != null)
                   or (.submitted_at != null
                       and (.submitted_at
                            | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
                            | not))
                   or ((.body | type) != "string" and .body != null))
            then error("malformed review record")
            else [ $all[] | select(.user.login == $who and .commit_id == $head) ] as $mine
              # An unsubmitted draft DOMINATES, exactly as it does in the
              # snapshot pr-review-state.sh takes. A PENDING re-review on this
              # head after the watch saw `blocked` has a null `submitted_at`, so
              # the sort below ignores it and returns the OLDER request — sending
              # the driver to act on findings the in-flight pass may supersede.
              # The two must not disagree about what a pending review means.
              | if any($mine[]; .state == "PENDING" or .submitted_at == null)
                then error("re-review in flight")
                else . end
              | ( [ $mine[] ] | sort_by(.submitted_at) | last ) as $latest
              | if $latest == null or $latest.state != "CHANGES_REQUESTED"
                then empty
                elif ($latest.body | type) != "string"
                then error("blocked review without a readable body")
                else $latest.body
                end
            end
        end' 2>/dev/null) || {
        echo "PR_FINDINGS pr=$pr status=error reason=reviews_unreadable" >&2
        return 2
    }
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
}

main() {
    local cmd="${1:-}" pr="${2:-}"
    case "$pr" in
        ""|*[!0-9]*) echo "usage: $0 {list <pr>|blocked-body <pr> <reviewer> [head]}" >&2; exit 2 ;;
    esac
    case "$cmd" in
        list)         cmd_list "$pr" ;;
        blocked-body) [ -n "${3:-}" ] || { echo "usage: $0 blocked-body <pr> <reviewer> [head]" >&2; exit 2; }
                      cmd_blocked_body "$pr" "$3" "${4:-}" ;;
        *) echo "usage: $0 {list <pr>|blocked-body <pr> <reviewer> [head]}" >&2; exit 2 ;;
    esac
}

if [ -z "${PR_FINDINGS_LIB_ONLY:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
