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

# The shared record validators. Three scripts read the same two endpoints, and
# each used to re-implement the same field checks — which is why the same rule
# kept having to be added a third and fourth time, and why `state` reached two
# scripts and stopped. See recordlib.sh and issue #11.
#
# The status is taken: a helper whose validators failed to load would fall back
# to whatever the jq programs below happen to do with undefined functions, which
# is an error per call rather than a clear refusal here.
_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_FINDINGS status=error reason=lib_dir_unresolvable" >&2; exit 2; }
# shellcheck source=recordlib.sh
. "$_RB_SELF_DIR/recordlib.sh" || {
    echo "PR_FINDINGS status=error reason=recordlib_unreadable" >&2; exit 2; }
[ -n "${RECORDLIB_JQ:-}" ] || {
    echo "PR_FINDINGS status=error reason=recordlib_empty" >&2; exit 2; }

# The shared identity parser. This 60-line block sat here byte-identical to the
# copies in the other two helpers and in SKILL.md, so both the hostless-origin
# and file-transport rules had to be written four times and proven twice. See
# identitylib.sh and issue #18.
#
# The status is taken, like recordlib above: a helper whose identity parser
# failed to load would fall through to an undefined function per call rather
# than refusing clearly here.
# THE STALE DEFINITION IS CLEARED FIRST, AND THE CLEARING IS CHECKED. Bash
# exports functions through the environment, so a caller that had run
# `export -f rb_identity` leaves one defined in this shell before the `.` — and a
# library that is empty or truncated ABOVE the definition still sources
# successfully. The `type -t` check then finds the inherited function and reports
# the parser loaded, and the driver goes on addressing `gh` calls with whatever
# that stale version derives.
#
# `|| true` on the `unset` reopened exactly that: `readonly -f rb_identity` makes
# the unset FAIL and leaves the function installed, and the discarded status made
# a definition that could not be cleared indistinguishable from one that never
# existed. An `unset -f` of a name that is not defined returns 0, so the only
# thing a non-zero status here means is that a definition survived — which is the
# one condition this line exists to rule out.
unset -f rb_identity 2>/dev/null || {
    echo "PR_FINDINGS status=error reason=identitylib_stale_definition" >&2; exit 2; }
# shellcheck source=identitylib.sh
. "$_RB_SELF_DIR/identitylib.sh" || {
    echo "PR_FINDINGS status=error reason=identitylib_unreadable" >&2; exit 2; }
[ "$(type -t rb_identity 2>/dev/null)" = function ] || {
    echo "PR_FINDINGS status=error reason=identitylib_empty" >&2; exit 2; }
rb_identity || {
    echo "PR_FINDINGS status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }
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
    if ! _sha_why="$(sha_reason "$head")"; then
        echo "PR_FINDINGS pr=$pr status=error reason=$_sha_why" >&2
        return 2
    fi

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
    out=$(printf '%s' "$raw" | jq -s -r --arg who "$who" --arg head "$head" "$RECORDLIB_JQ"'
        pages_or_error
        | [ .[][] ] as $all
          # THE SHARED VALIDATOR. This helper suppresses output for anything that
          # is not exactly CHANGES_REQUESTED, so a record it cannot read produced
          # empty stdout and rc 0 — indistinguishable from "this blocking review
          # has no body", which is the one case where silence loses the only text
          # there is. Every field it checks was also written out in two other
          # scripts; see recordlib.sh and issue #11.
          | if any($all[]; valid_review_record | not)
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
