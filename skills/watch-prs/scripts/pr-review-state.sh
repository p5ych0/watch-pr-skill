#!/usr/bin/env bash
# Answer, for one PR head and one reviewer, whether that reviewer's review can
# carry a merge — and never confuse "I could not tell" with "nothing to worry
# about".
#
# Both reviewers are first-party GitHub apps now (`chatgpt-codex-connector[bot]`
# and `copilot-pull-request-reviewer[bot]`), so this is deliberately
# reviewer-agnostic: the bot login is an argument. The 1.x bus needed a separate
# Copilot helper only because Codex reviews arrived out-of-band, authored as the
# repository owner rather than as a bot.
#
# Usage:
#   pr-review-state.sh state  <pr> <reviewer-login> [head-oid]
#   pr-review-state.sh verdict <pr> <reviewer-login> [head-oid]
#   pr-review-state.sh head   <pr> [reviewer-login]      -> the full 40-hex head
#
# `head` exists so a caller making more than one probe can pin them all to ONE
# commit. The records print an abbreviated `sha=`, which is enough to read but
# not enough to compare: two heads can share a seven-hex prefix, so a caller that
# checked one record against another would accept two different commits.
#
# Both print ONE structured line, `PR_REVIEW_STATE pr=… sha=… reviewer=… …`:
#
#   state    …  state=none|pending|blocked|dismissed|reviewed
#   verdict  …  verdict=clean findings=0
#            …  verdict=findings findings=<n>
#            …  verdict=none reason=<pending|dismissed|blocked|review_state_changed>
#            …  verdict=error reason=<unreadable|head_lookup_failed>
#
# Exit codes: 0 = clean, or the state line was printed · 1 = not clean ·
# 2 = cannot tell. Callers branch on the STATUS; the `reason=` field says why,
# and is diagnostic rather than something to parse for control flow.
#
# `set -uo pipefail`, NOT `-e`: several `gh` probes fail as normal operation and
# the subcommands use exit status as control flow. See CLAUDE.md § Bash
# conventions.
set -uo pipefail

REMOTE="${REVIEW_BUS_REMOTE:-$(git remote get-url origin 2>/dev/null)}"
if [ -z "$REMOTE" ]; then
    echo "PR_REVIEW_STATE status=error reason=no_origin" >&2
    exit 2
fi
_p="${REMOTE%.git}"; REPO="${REVIEW_BUS_REPO:-${_p##*/}}"; _p="${_p%/*}"
OWNER="${REVIEW_BUS_OWNER:-${_p##*[:/]}}"
REPO_SLUG="$OWNER/$REPO"

# 40-hex head OID of a PR. Prints nothing and returns non-zero on failure.
#
# The status is checked and the shape validated because command substitution
# keeps whatever a command printed BEFORE failing: a `gh` call that emitted a
# plausible SHA and then errored was otherwise indistinguishable from success.
pr_head_oid() {
    local out
    out="$(gh pr view "$1" --repo "$REPO_SLUG" --json headRefOid --jq '.headRefOid' 2>/dev/null)" || return 1
    case "$out" in
        *[!0-9a-f]*|"") return 1 ;;
    esac
    [ "${#out}" -eq 40 ] || return 1
    printf '%s' "$out"
}

# Every review by $2 on this PR, as a JSON array. Fails (2) rather than
# returning an empty list when anything about the read is untrustworthy.
reviewer_reviews() {
    local pr="$1" who="$2" raw
    if ! raw=$(gh api "repos/$REPO_SLUG/pulls/$pr/reviews" --paginate 2>/dev/null); then
        return 2
    fi
    # `jq -s` slurps the paginated stream into an ARRAY OF PAGES. Nothing
    # guarantees each page is an array, and `.[][]` over an object iterates its
    # VALUES - so a `{"message":"Not Found"}` page (a 200-with-error body) flowed
    # through as data. Empty input slurps to ZERO pages, where `any([]; ...)` is
    # false, so that needs its own check: no pages is not "no reviews", it is a
    # fetch that told us nothing.
    #
    # The RECORDS matter as much as the containers: a successful `[{}]` page
    # produced `[]`, which every caller reads as "no review", so a marker or a
    # stale assumption could carry the merge off a payload that proved nothing.
    printf '%s' "$raw" | jq -s --arg who "$who" '
        if length == 0 then error("no pages")
        elif any(.[]; type != "array") then error("non-array page")
        else [ .[][] ] as $all
          | if any($all[];
                   type != "object"
                   or (.user | type) != "object"
                   or (.user.login | type) != "string"
                   or (.id | type) != "number"
                   or (.commit_id | type) != "string"
                   # A short or non-SHA commit_id is filtered out as "another
                   # head", so a malformed page reads as `state=none` — which the
                   # merge gate answers by trusting an older signoff instead of
                   # stopping.
                   or (.commit_id | test("^[0-9a-f]{40}$") | not)
                   or ((.state | type) != "string" and .state != null)
                   # Not merely a string: `head_review_snapshot` sorts on this to
                   # decide which review is authoritative, and the sort is
                   # LEXICAL. `submitted_at:"zzzz"` sorts after every real ISO
                   # timestamp, so a stale APPROVED record could outrank a current
                   # CHANGES_REQUESTED and report clean.
                   or ((.submitted_at | type) != "string" and .submitted_at != null)
                   # ANCHORED at both ends: a prefix check let
                   # `2026-01-02T00:00:00zzzz` through, and it sorts after the
                   # real `2026-01-02T00:00:00Z` — the same lexical-sort hole the
                   # prefix check was added to close.
                   or (.submitted_at != null
                       and (.submitted_at
                            | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})$")
                            | not)))
            then error("malformed review record")
            else [ $all[] | select(.user.login == $who) ]
            end
        end' 2>/dev/null || return 2
}

# Print "<state>\t<review-id>" for THIS head from ONE reviews fetch, or fail (2).
# The id is the authoritative latest submitted review the state was derived from,
# and is empty unless the state is `reviewed`.
#
# State and id must come from the SAME snapshot. Deriving them from separate
# fetches let a review that changed in between be judged on one snapshot and
# counted on another - a COMMENTED read followed by a DISMISSED one counted the
# withdrawn review's zero comments and reported clean.
head_review_snapshot() {
    local pr="$1" who="$2" head="$3" reviews out
    reviews=$(reviewer_reviews "$pr" "$who") || return 2
    out="$(printf '%s' "$reviews" | jq -r --arg h "$head" '
        if type != "array" then error("bad shape")
        else
          [ .[] | select(.commit_id == $h) ] as $mine
          | ( [ $mine[] | select(.submitted_at != null) ]
              | sort_by(.submitted_at) | last ) as $latest
          | ( if ($mine | length) == 0 then "none"
              # An unsubmitted draft dominates: a re-review in flight means the
              # pass is not finished, whatever an older submitted review says.
              elif any($mine[]; .state == "PENDING" or .submitted_at == null) then "pending"
              elif $latest == null then "dismissed"
              elif $latest.state == "CHANGES_REQUESTED" then "blocked"
              elif $latest.state == "APPROVED" or $latest.state == "COMMENTED" then "reviewed"
              # DISMISSED, or any state we do not accept. Dismissal is what
              # REMOVES a signoff, so it cannot read as one.
              else "dismissed"
              end ) as $st
          | $st + "\t" + (if $st == "reviewed" then ($latest.id | tostring) else "" end)
        end' 2>/dev/null)" || return 2
    case "${out%%$'\t'*}" in
        none|pending|blocked|dismissed|reviewed) printf '%s' "$out" ;;
        *) return 2 ;;
    esac
}

# Count the inline comments of ONE known review id. 0 = count printed · 2 = fail.
review_comment_count() {
    local pr="$1" id="$2" raw n
    case "$id" in
        ""|*[!0-9]*) return 2 ;;
    esac
    if ! raw=$(gh api "repos/$REPO_SLUG/pulls/$pr/reviews/$id/comments" --paginate 2>/dev/null); then
        return 2
    fi
    n=$(printf '%s' "$raw" | jq -s '
        if length == 0 then error("no pages")
        elif any(.[]; type != "array") then error("non-array page")
        else [.[][]] | length end' 2>/dev/null) || return 2
    case "$n" in
        ""|*[!0-9]*) return 2 ;;
    esac
    printf '%s' "$n"
}

# The merge decision, derived and then RE-CHECKED.
#   0 = clean (prints `clean`) · 1 = not clean (prints why) · 2 = cannot tell
#
# A clean answer is merge permission, so it is the one place that pays for a
# second look: state and review id come from one snapshot, the comments are
# counted for THAT id, and the snapshot is read again afterwards. If it moved -
# a draft opened, the review was dismissed, a newer one landed - the count
# describes a review that is no longer authoritative.
clean_verdict() {
    local pr="$1" who="$2" head="$3" snap1 snap2 st id n
    snap1="$(head_review_snapshot "$pr" "$who" "$head")" || return 2
    st="${snap1%%$'\t'*}"; id="${snap1#*$'\t'}"
    case "$st" in
        reviewed) ;;
        *) printf '%s' "$st"; return 1 ;;
    esac
    n="$(review_comment_count "$pr" "$id")" || return 2
    snap2="$(head_review_snapshot "$pr" "$who" "$head")" || return 2
    if [ "$snap2" != "$snap1" ]; then
        printf 'changed'
        return 1
    fi
    [ "$n" -eq 0 ] 2>/dev/null || { printf 'findings:%s' "$n"; return 1; }
    printf 'clean'
    return 0
}

main() {
    local cmd="${1:-}" pr="${2:-}" who="${3:-}" head="${4:-}"
    case "$cmd" in
        state|verdict|head) ;;
        *) echo "usage: $0 {state|verdict|head} <pr> <reviewer-login> [head-oid]" >&2; exit 2 ;;
    esac
    case "$pr" in
        ""|*[!0-9]*) echo "PR_REVIEW_STATE status=error reason=bad_pr" >&2; exit 2 ;;
    esac
    # `head` asks about the PR, not about a reviewer, so it needs no login.
    if [ "$cmd" != "head" ]; then
        [ -n "$who" ] || { echo "PR_REVIEW_STATE status=error reason=no_reviewer" >&2; exit 2; }
    fi

    if [ -z "$head" ]; then
        head="$(pr_head_oid "$pr")" || {
            echo "PR_REVIEW_STATE pr=$pr status=error reason=head_lookup_failed"
            exit 2
        }
    fi
    # Length as well as alphabet, and for the EXPLICIT argument too. `abc123` is
    # all-hex, so a character-only check accepted it and the commit_id filter then
    # matched nothing — reporting `state=none`, which callers read as "this
    # reviewer has not judged the head" rather than "you passed me nonsense". The
    # gate uses exactly that distinction to decide whether to fall back to the
    # recorded signoff.
    case "$head" in
        *[!0-9a-f]*|"") echo "PR_REVIEW_STATE pr=$pr status=error reason=bad_head" >&2; exit 2 ;;
    esac
    if [ "${#head}" -ne 40 ]; then
        echo "PR_REVIEW_STATE pr=$pr status=error reason=head_not_full_sha" >&2
        exit 2
    fi

    # Printed bare and in full: this is the value a caller pins its other probes
    # to, so an abbreviation would put back the ambiguity it exists to remove.
    if [ "$cmd" = "head" ]; then
        printf '%s\n' "$head"
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
        findings:*) echo "PR_REVIEW_STATE pr=$pr sha=$short reviewer=$who verdict=findings findings=${out#findings:}" ;;
        changed)    echo "PR_REVIEW_STATE pr=$pr sha=$short reviewer=$who verdict=none reason=review_state_changed" ;;
        *)          echo "PR_REVIEW_STATE pr=$pr sha=$short reviewer=$who verdict=none reason=$out" ;;
    esac
    return 1
}

# Sourcing defines the helpers without running anything, so tests can exercise
# them in isolation.
if [ -z "${PR_REVIEW_STATE_LIB_ONLY:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
