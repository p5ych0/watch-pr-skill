#!/usr/bin/env -S bash -p
# A last-resort refusal: `$-` proves the mode, not how the shell got there.
if [[ $- != *p* ]]; then
    echo "PR_REVIEW_STATE status=error reason=not_privileged" >&2
    exit 2
fi

# No `-e`: statuses are control flow here.
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_REVIEW_STATE status=error reason=lib_dir_unresolvable" >&2; exit 2; }
# The bootstrap cannot use the loader. The refusing stub is what stops an empty `loadlib.sh` from
# leaving `rb_load` to `PATH`, and the first load's 127 is the stub's rather than the loader's.
unset -f rb_load 2>/dev/null || {
    echo "PR_REVIEW_STATE status=error reason=loadlib_stale_definition" >&2; exit 2; }
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_REVIEW_STATE status=error reason=loadlib_unreadable" >&2; exit 2; }
rb_load "$_RB_SELF_DIR" recordlib RECORDLIB_JQ "PR_REVIEW_STATE status=error" var || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "PR_REVIEW_STATE status=error reason=loadlib_empty" >&2
    exit 2; }

rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_REVIEW_STATE status=error" || exit 2
rb_identity || {
    echo "PR_REVIEW_STATE status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }
REPO_SLUG="$HOST/$OWNER/$REPO"

pr_head_oid() {
    local out
    out="$(gh pr view "$1" --repo "$REPO_SLUG" --json headRefOid --jq '.headRefOid' 2>/dev/null)" || return 1
    is_full_sha "$out" || return 1
    printf '%s' "$out"
}

reviewer_reviews() {
    local pr="$1" who="$2" raw
    if ! raw=$(gh api --hostname "$HOST" "repos/$OWNER/$REPO/pulls/$pr/reviews" --paginate 2>/dev/null); then
        return 2
    fi
    printf '%s' "$raw" | jq -s --arg who "$who" "$RECORDLIB_JQ"'
        pages_or_error
        | [ .[][] ] as $all
          | if any($all[]; valid_review_record | not)
            then error("malformed review record")
            else [ $all[] | select(.user.login == $who) ]
            end' 2>/dev/null || return 2
}

# Codex reports a clean pass as an issue comment and creates no review for it, so the comment channel
# is read too; two signals are required, since the footer hash alone or the phrase alone accepts the wrong comment.
clean_comment_for_head() {
    local pr="$1" who="$2" head="$3" raw out
    if ! raw=$(gh api --hostname "$HOST" "repos/$OWNER/$REPO/issues/$pr/comments" --paginate 2>/dev/null); then
        return 2
    fi
    out="$(printf '%s' "$raw" | jq -s -r --arg who "$who" --arg h "${head:0:10}" "$RECORDLIB_JQ"'
        pages_or_error
        | [ .[][] ] as $all
          | if any($all[]; valid_comment_record | not)
            then error("malformed comment record")
            else ( [ $all[]
                     | select(.user.login == $who)
                     | select((.body | type) == "string")
                     | select(.body | test("[Dd]idn.t find any major issues"))
                     # The footer line, the last one, extracted and compared exactly: prose that
                     # mentions the prefix, or an earlier footer-shaped line, is not the footer.
                     | select((.body | [scan("(?m)^\\*\\*Reviewed commit:\\*\\* `([0-9a-f]{10})`")] | last // [""] | .[0]) == $h)
                   ] | sort_by(.id) | last ) as $c
              | if $c == null then ""
                else (($c.id | tostring) + "\t" + $c.created_at) end
            end' 2>/dev/null)" || return 2
    case "$out" in
        "") return 1 ;;
    esac
    case "${out%%$'\t'*}" in
        ""|*[!0-9]*) return 2 ;;
    esac
    printf '%s' "$out"
}

# One snapshot for all three values: taken from separate fetches they can describe different
# reviews, and the id is what proves they describe one.
head_review_snapshot() {
    local pr="$1" who="$2" head="$3" reviews out cid
    reviews=$(reviewer_reviews "$pr" "$who") || return 2
    out="$(printf '%s' "$reviews" | jq -r --arg h "$head" "$RECORDLIB_JQ"'
        if type != "array" then error("bad shape")
        else
          [ .[] | select(.commit_id == $h) ] as $mine
          | ( [ $mine[] | select(.submitted_at != null) ]
              | sort_by(.submitted_at) | last ) as $latest
          | ( if ($mine | length) == 0 then "none"
              # An unsubmitted draft dominates, and DISMISSED or any unaccepted state reads as
              # dismissed, which is what removes a signoff.
              elif any($mine[]; .state == "PENDING" or .submitted_at == null) then "pending"
              elif $latest == null then "dismissed"
              elif $latest.state == "CHANGES_REQUESTED" then "blocked"
              elif $latest.state == "APPROVED" or $latest.state == "COMMENTED" then "reviewed"
              else "dismissed"
              end ) as $st
          | $st + "\t" + (if ($st == "reviewed" or $st == "blocked" or $st == "dismissed")
                              and $latest != null
                           then ($latest.id | tostring) else "" end)
               + "\t" + (if $latest != null and ($latest.submitted_at | canonical_utc)
                          then $latest.submitted_at else "" end)
        end' 2>/dev/null)" || return 2
    # Both channels, placed in time: a clean re-review on an unchanged head arrives as a comment, so
    # the newer wins unless a draft is pending, and equal times are unreadable rather than a decision.
    local latest_ts cinfo cid cts
    cinfo="$(clean_comment_for_head "$pr" "$who" "$head")"; crc=$?
    case "$crc" in
        0|1) ;;
        *) return 2 ;;            # unreadable: never "no comment"
    esac
    if [ "$crc" -eq 0 ]; then
        cid="${cinfo%%$'\t'*}"; cts="${cinfo#*$'\t'}"
        latest_ts="$(printf '%s' "$reviews" | jq -r --arg h "$head" '
            [ .[] | select(.commit_id == $h) | select(.submitted_at != null) | .submitted_at ]
            | sort | last // ""' 2>/dev/null)" || return 2
        case "${out%%$'\t'*}" in
            pending) ;;
            *) if [ -n "$latest_ts" ] && [ "$cts" = "$latest_ts" ]; then
                   echo "PR_REVIEW_STATE pr=$pr status=error reason=ambiguous_verdict_order ts=$cts" >&2
                   return 2
               elif [ -z "$latest_ts" ] || [ "$cts" \> "$latest_ts" ]; then
                   out="reviewed"$'\t'"comment:$cid"$'\t'"$cts"
               fi ;;
        esac
    fi
    case "${out%%$'\t'*}" in
        none|pending|blocked|dismissed|reviewed) printf '%s' "$out" ;;
        *) return 2 ;;
    esac
}

# Every comment counts, replies included, and the answer says when they were all replies: a reply
# can retract a verdict, and no reading of the text tells that from a verdict followed by its explanation.
review_comment_count() {
    local pr="$1" id="$2" raw n
    case "$id" in
        ""|*[!0-9]*) return 2 ;;
    esac
    if ! raw=$(gh api --hostname "$HOST" "repos/$OWNER/$REPO/pulls/$pr/reviews/$id/comments" --paginate 2>/dev/null); then
        return 2
    fi
    n=$(printf '%s' "$raw" | jq -s -r "$RECORDLIB_JQ"'
        pages_or_error
        | [.[][]] as $rows
        | if any($rows[]; valid_review_comment | not)
          then error("malformed review comment")
          else "\([$rows[]] | length):\([$rows[] | select(opens_a_thread)] | length)"
          end' 2>/dev/null) || return 2
    case "$n" in
        *[!0-9:]*|*:*:*|:*|*:|"") return 2 ;;
        *:*) ;;
        *) return 2 ;;
    esac
    printf '%s' "$n"
}

# A clean answer is merge permission, so the snapshot is read again after the count: a draft
# opened, a dismissal or a newer review in between makes the count describe a stale review.
clean_verdict() {
    local pr="$1" who="$2" head="$3" snap1 snap2 st id n _r at
    snap1="$(head_review_snapshot "$pr" "$who" "$head")" || return 2
    st="${snap1%%$'\t'*}"; _r="${snap1#*$'\t'}"; id="${_r%%$'\t'*}"; at="${_r#*$'\t'}"
    case "$st" in
        reviewed) ;;
        *) printf '%s' "$st"; return 1 ;;
    esac
    # A comment-sourced signoff has no review to count comments against.
    case "$id" in
        comment:*) n="0:0" ;;
        *) n="$(review_comment_count "$pr" "$id")" || return 2 ;;
    esac
    snap2="$(head_review_snapshot "$pr" "$who" "$head")" || return 2
    if [ "$snap2" != "$snap1" ]; then
        printf 'changed'
        return 1
    fi
    # All replies is neither answer: nothing to fix, and not a signoff.
    local total="${n%%:*}" opens="${n##*:}"
    [ "$total" -eq 0 ] 2>/dev/null || {
        if [ "$opens" -eq 0 ] 2>/dev/null; then
            printf 'findings:%s:replies-only' "$total"
        else
            printf 'findings:%s' "$total"
        fi
        return 1
    }
    # The time comes from the same snapshot; `verdict` ignores the tail and `clean-at` is the tail.
    printf 'clean\t%s' "$at"
    return 0
}

main() {
    local cmd="${1:-}" pr="${2:-}" who="${3:-}" head="${4:-}"
    case "$cmd" in
        state|verdict|head|review-id|clean-at|escape-snapshot) ;;
        *) echo "usage: $0 {state|verdict|head|review-id|clean-at|escape-snapshot} <pr> <reviewer-login> [head-oid]" >&2; exit 2 ;;
    esac
    case "$pr" in
        ""|*[!0-9]*) echo "PR_REVIEW_STATE status=error reason=bad_pr" >&2; exit 2 ;;
    esac
    if [ "$cmd" != "head" ]; then
        [ -n "$who" ] || { echo "PR_REVIEW_STATE status=error reason=no_reviewer" >&2; exit 2; }
    fi

    if [ -z "$head" ]; then
        head="$(pr_head_oid "$pr")" || {
            echo "PR_REVIEW_STATE pr=$pr status=error reason=head_lookup_failed"
            exit 2
        }
    fi
    # Length as well as alphabet, for the explicit argument too: an all-hex non-sha would match no
    # commit_id and read as `state=none`, which callers take as "not judged" rather than "nonsense".
    if ! _sha_why="$(sha_reason "$head")"; then
        echo "PR_REVIEW_STATE pr=$pr status=error reason=$_sha_why" >&2
        exit 2
    fi

    if [ "$cmd" = "head" ]; then
        printf '%s\n' "$head"
        return 0
    fi

    if [ "$cmd" = "escape-snapshot" ]; then
        # One GraphQL response rather than two REST reads, which no ordering makes one snapshot;
        # a truncated page is unreadable, since the reviews are the last hundred.
        local epage eanswer
        epage=$(gh api --hostname "$HOST" graphql -F number="$pr" -f owner="$OWNER" -f repo="$REPO" \
            -f query='query($owner:String!,$repo:String!,$number:Int!){
              repository(owner:$owner,name:$repo){ pullRequest(number:$number){
                reviews(last:100){ pageInfo{hasPreviousPage}
                  nodes{ databaseId submittedAt state
                         author{login} commit{oid}
                         comments(first:100){ pageInfo{hasNextPage}
                           nodes{ databaseId createdAt replyTo{databaseId} } } } }}}}' 2>/dev/null) || {
            echo "PR_REVIEW_STATE pr=$pr status=error reason=unreadable" >&2
            return 2
        }
        printf '%s' "$epage" | jq -e 'has("errors") | not' >/dev/null 2>&1 || {
            echo "PR_REVIEW_STATE pr=$pr status=error reason=unreadable" >&2
            return 2
        }
        # No apostrophe inside this program: it is a single-quoted shell string.
        eanswer="$(printf '%s' "$epage" | jq -r --arg h "$head" --arg who "$who" "$RECORDLIB_JQ"'
            .data.repository.pullRequest.reviews as $r
            | if ($r | type) != "object" or ($r.nodes | type) != "array"
                 or ($r.pageInfo.hasPreviousPage | type) != "boolean"
              then error("bad shape")
              elif $r.pageInfo.hasPreviousPage then error("truncated reviews")
              # Every node is validated before any is filtered: a discarded newer review leaves an
              # older replies-only one as the latest, and a sortable non-time sorts somewhere.
              elif any($r.nodes[];
                       type != "object"
                       or (.author | type) != "object" or (.author.login | type) != "string"
                       or (.commit | type) != "object" or (.commit.oid | full_sha | not)
                       or (.state | type) != "string"
                       or (.submittedAt != null and (.submittedAt | canonical_utc | not)))
              then error("bad review node")
              else
                [ $r.nodes[]
                  | select(.author.login == $who)
                  | select(.commit.oid == $h) ] as $mine
                | if ($mine | length) == 0 then "none"
                  elif any($mine[]; .state == "PENDING" or .submittedAt == null) then "none"
                  else
                    ( [ $mine[] | select(.submittedAt != null) ]
                      | sort_by(.submittedAt) | last ) as $latest
                    | if $latest == null then "none"
                      elif ($latest.state != "APPROVED" and $latest.state != "COMMENTED") then "none"
                      elif ($latest.submittedAt | canonical_utc | not) then error("bad review time")
                      elif ($latest.databaseId | type) != "number" then error("bad review id")
                      elif ($latest.comments | type) != "object"
                           or ($latest.comments.nodes | type) != "array"
                           or ($latest.comments.pageInfo.hasNextPage | type) != "boolean"
                      then error("bad comments")
                      elif $latest.comments.pageInfo.hasNextPage then error("truncated comments")
                      else
                        $latest.comments.nodes as $c
                        # A `replyTo` that is not null and not an object is a row nothing classified,
                        # and a comment that opens a thread is a finding rather than a reply.
                        | if any($c[];
                                 type != "object"
                                 or (.createdAt | canonical_utc | not)
                                 or (.replyTo != null
                                     and ((.replyTo | type) != "object"
                                          or (.replyTo.databaseId | type) != "number")))
                          then error("bad comment row")
                          elif ($c | length) == 0 then "none"
                          elif any($c[]; .replyTo == null) then "none"
                          else (($latest.databaseId | tostring) + "\t" + $latest.submittedAt
                                + "\t" + ([ $c[] | .createdAt ] | sort | last))
                          end
                      end
                    end
              end' 2>/dev/null)" || {
            echo "PR_REVIEW_STATE pr=$pr status=error reason=unreadable" >&2
            return 2
        }
        [ -n "$eanswer" ] || {
            echo "PR_REVIEW_STATE pr=$pr status=error reason=unreadable" >&2
            return 2
        }
        [ "$eanswer" != none ] || return 1
        printf '%s\n' "$eanswer"
        return 0
    fi

    if [ "$cmd" = "clean-at" ]; then
        local cvout cvrc=0 cvat
        cvout="$(clean_verdict "$pr" "$who" "$head")" || cvrc=$?
        case "$cvrc" in
            0) ;;
            1) return 1 ;;
            *) echo "PR_REVIEW_STATE pr=$pr status=error reason=unreadable" >&2; return 2 ;;
        esac
        cvat="${cvout#*$'\t'}"
        # A clean verdict this cannot place in time is unreadable: every consumer compares it as a string.
        case "$cvat" in
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
            *) echo "PR_REVIEW_STATE pr=$pr status=error reason=unreadable" >&2; return 2 ;;
        esac
        printf '%s\n' "$cvat"
        return 0
    fi

    if [ "$cmd" = "review-id" ]; then
        local snap _r
        snap="$(head_review_snapshot "$pr" "$who" "$head")" || {
            echo "PR_REVIEW_STATE pr=$pr status=error reason=unreadable" >&2
            return 2
        }
        _r="${snap#*$'\t'}"
        printf '%s\n' "${_r%%$'\t'*}"
        return 0
    fi

    local short="${head:0:7}" out rc=0
    if [ "$cmd" = "state" ]; then
        out="$(head_review_snapshot "$pr" "$who" "$head")" || {
            echo "PR_REVIEW_STATE pr=$pr sha=$short reviewer=$who status=error reason=unreadable"
            exit 2
        }
        echo "PR_REVIEW_STATE pr=$pr sha=$short reviewer=$who state=${out%%$'\t'*}"
        return 0
    fi

    out="$(clean_verdict "$pr" "$who" "$head")" || rc=$?
    case "$rc" in
        0) echo "PR_REVIEW_STATE pr=$pr sha=$short reviewer=$who verdict=clean findings=0"; return 0 ;;
        2) echo "PR_REVIEW_STATE pr=$pr sha=$short reviewer=$who verdict=error reason=unreadable"; return 2 ;;
    esac
    case "$out" in
        findings:*:replies-only)
            _f="${out#findings:}"; _f="${_f%%:*}"
            # Named apart, so the driver reads it as neither answer.
            echo "PR_REVIEW_STATE pr=$pr sha=$short reviewer=$who verdict=findings findings=$_f source=replies-only" ;;
        findings:*) echo "PR_REVIEW_STATE pr=$pr sha=$short reviewer=$who verdict=findings findings=${out#findings:}" ;;
        changed)    echo "PR_REVIEW_STATE pr=$pr sha=$short reviewer=$who verdict=none reason=review_state_changed" ;;
        *)          echo "PR_REVIEW_STATE pr=$pr sha=$short reviewer=$who verdict=none reason=$out" ;;
    esac
    return 1
}

if [ -z "${PR_REVIEW_STATE_LIB_ONLY:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
