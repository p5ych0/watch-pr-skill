#!/usr/bin/env -S bash -p
# A last-resort refusal: `$-` proves the mode, not how the shell got there.
if [[ $- != *p* ]]; then
    echo "PR_FINDINGS status=error reason=not_privileged" >&2
    exit 2
fi

# No `-e`: statuses are control flow here. `pipefail` matters: `gh --paginate` can write a
# valid page and then fail.
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_FINDINGS status=error reason=lib_dir_unresolvable" >&2; exit 2; }
# The bootstrap cannot use the loader. The refusing stub is what stops an empty `loadlib.sh` from
# leaving `rb_load` to `PATH`, and the first load's 127 is the stub's rather than the loader's.
unset -f rb_load 2>/dev/null || {
    echo "PR_FINDINGS status=error reason=loadlib_stale_definition" >&2; exit 2; }
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_FINDINGS status=error reason=loadlib_unreadable" >&2; exit 2; }
rb_load "$_RB_SELF_DIR" recordlib RECORDLIB_JQ "PR_FINDINGS status=error" var || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "PR_FINDINGS status=error reason=loadlib_empty" >&2
    exit 2; }

rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_FINDINGS status=error" || exit 2
rb_identity || {
    echo "PR_FINDINGS status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }
REPO_SLUG="$HOST/$OWNER/$REPO"

cmd_list() {
    # `seen` holds every cursor this walk has requested, RS-separated (RS cannot occur in a
    # base64 cursor), so a cycle of any length is a refusal rather than a hang.
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
        # A GraphQL 200 can carry `errors` beside structurally valid, partial `data`.
        printf '%s' "$page" | jq -e 'has("errors") | not' >/dev/null 2>&1 || {
            echo "PR_FINDINGS pr=$pr status=error reason=graphql_errors" >&2
            return 2
        }
        # The shape before anything is printed: interpolation renders a missing author or body
        # as `null` and still exits 0.
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
              # The thread id resolves over GraphQL and the comment id reacts over REST; path:line
              # is not an identifier, since two comments can share a line and a fix moves it.
              else ( [ $n[] | select(.isResolved == false) ]
                     | map("### \(.path):\(.line) [\(.comments.nodes[0].author.login)]\nthread=\(.id) comment=\(.comments.nodes[0].databaseId)\n\(.comments.nodes[0].body)\n")
                     | join("\n") )
              end' 2>/dev/null) || {
            echo "PR_FINDINGS pr=$pr status=error reason=malformed_page" >&2
            return 2
        }
        [ -n "$nodes" ] && printf '%s\n' "$nodes"

        # A missing or malformed `hasNextPage` read as "last page" would truncate the findings silently.
        has_next=$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage') || {
            echo "PR_FINDINGS pr=$pr status=error reason=pageinfo_unreadable" >&2
            return 2
        }
        case "$has_next" in
            false) return 0 ;;
            true)  ;;
            *) echo "PR_FINDINGS pr=$pr status=error reason=hasnextpage_not_boolean" >&2; return 2 ;;
        esac
        next=$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor') || {
            echo "PR_FINDINGS pr=$pr status=error reason=cursor_unreadable" >&2
            return 2
        }
        { [ -n "$next" ] && [ "$next" != "null" ]; } || {
            echo "PR_FINDINGS pr=$pr status=error reason=missing_cursor" >&2
            return 2
        }
        case "$seen" in
            *"$RS$next$RS"*)
                echo "PR_FINDINGS pr=$pr status=error reason=cursor_cycle" >&2
                return 2 ;;
        esac
        seen="$seen$next$RS"
        cursor="$next"
    done
}

# Scoped to the head: a stale CHANGES_REQUESTED on an older commit is not an active finding.
cmd_blocked_body() {
    local pr="$1" who="$2" head="${3:-}" raw out
    if [ -z "$head" ]; then
        head=$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefOid --jq '.headRefOid' 2>/dev/null) || {
            echo "PR_FINDINGS pr=$pr status=error reason=head_lookup_failed" >&2
            return 2
        }
    fi
    if ! _sha_why="$(sha_reason "$head")"; then
        echo "PR_FINDINGS pr=$pr status=error reason=$_sha_why" >&2
        return 2
    fi

    # Captured apart from the parse: `gh --paginate` can write a valid page and then fail.
    raw=$(gh api --hostname "$HOST" "repos/$OWNER/$REPO/pulls/$pr/reviews" --paginate 2>/dev/null) || {
        echo "PR_FINDINGS pr=$pr status=error reason=reviews_fetch_failed" >&2
        return 2
    }
    # The latest review of this head decides, and an unsubmitted draft dominates, as in
    # `pr-review-state.sh`; a malformed page is an error, because empty output here means "no body".
    out=$(printf '%s' "$raw" | jq -s -r --arg who "$who" --arg head "$head" "$RECORDLIB_JQ"'
        pages_or_error
        | [ .[][] ] as $all
          | if any($all[]; valid_review_record | not)
            then error("malformed review record")
            else [ $all[] | select(.user.login == $who and .commit_id == $head) ] as $mine
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
