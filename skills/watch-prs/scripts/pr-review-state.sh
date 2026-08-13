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

# The shared record validators. Three scripts read the same two endpoints, and
# each used to re-implement the same field checks — which is why the same rule
# kept having to be added a third and fourth time, and why `state` reached two
# scripts and stopped. See recordlib.sh and issue #11.
#
# The status is taken: a helper whose validators failed to load would fall back
# to whatever the jq programs below happen to do with undefined functions, which
# is an error per call rather than a clear refusal here.
_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_REVIEW_STATE status=error reason=lib_dir_unresolvable" >&2; exit 2; }
# The library loader — and it obeys its own rule. A helper cannot load the file
# that defines it, so this sequence is written out here; that asymmetry is
# irreducible, but it is not a licence to load the loader carelessly. An exported
# `rb_load` survives into this shell and an empty `loadlib.sh` still sources
# successfully, so without the clear the type check below accepts the inherited
# function — and a stale loader is the one thing that can make every OTHER load
# look clean. See loadlib.sh and issue #22.
unset -f rb_load 2>/dev/null || {
    echo "PR_REVIEW_STATE status=error reason=loadlib_stale_definition" >&2; exit 2; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_REVIEW_STATE status=error reason=loadlib_unreadable" >&2; exit 2; }
[ "$(type -t rb_load 2>/dev/null)" = function ] || {
    echo "PR_REVIEW_STATE status=error reason=loadlib_empty" >&2; exit 2; }
rb_load "$_RB_SELF_DIR" recordlib RECORDLIB_JQ "PR_REVIEW_STATE status=error" var || exit 2

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
rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_REVIEW_STATE status=error" || exit 2
rb_identity || {
    echo "PR_REVIEW_STATE status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }
REPO_SLUG="$HOST/$OWNER/$REPO"

# 40-hex head OID of a PR. Prints nothing and returns non-zero on failure.
#
# The status is checked and the shape validated because command substitution
# keeps whatever a command printed BEFORE failing: a `gh` call that emitted a
# plausible SHA and then errored was otherwise indistinguishable from success.
pr_head_oid() {
    local out
    out="$(gh pr view "$1" --repo "$REPO_SLUG" --json headRefOid --jq '.headRefOid' 2>/dev/null)" || return 1
    is_full_sha "$out" || return 1
    printf '%s' "$out"
}

# Every review by $2 on this PR, as a JSON array. Fails (2) rather than
# returning an empty list when anything about the read is untrustworthy.
reviewer_reviews() {
    local pr="$1" who="$2" raw
    if ! raw=$(gh api --hostname "$HOST" "repos/$OWNER/$REPO/pulls/$pr/reviews" --paginate 2>/dev/null); then
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
    printf '%s' "$raw" | jq -s --arg who "$who" "$RECORDLIB_JQ"'
        pages_or_error
        | [ .[][] ] as $all
          # THE SHARED VALIDATOR. Every rule it applies was written out here and
          # again in two other scripts, and `state` against the known set reached
          # those two and never reached this one — for eleven rounds an
          # unrecognised value fell through `head_review_snapshot`'"'"'s catch-all
          # as `dismissed` with status 0, an actionable "the review was
          # withdrawn" that the driver answers by requesting another pass. One
          # definition, so the three cannot disagree about what a review is.
          | if any($all[]; valid_review_record | not)
            then error("malformed review record")
            else [ $all[] | select(.user.login == $who) ]
            end' 2>/dev/null || return 2
}

# A reviewer's clean-pass signal delivered as a PR COMMENT, bound to this head.
# Prints the comment id and returns 0 when one exists; 1 when none does; 2 when
# the read could not be trusted.
#
# WHY THIS EXISTS
#
# Codex does not submit a review when it finds nothing. A pass with findings
# arrives as a review with inline comments; a CLEAN pass arrives only as an issue
# comment reading "Codex Review: Didn't find any major issues", carrying
# `**Reviewed commit:** <sha10>`. `pulls/N/reviews` is therefore EMPTY on a clean
# head, so every caller here reported `state=none` and the Codex phase could
# never complete — the merge gate could not see a clean verdict at all.
#
# That was not a hypothetical: PR #10 took thirty review rounds and all thirty-one
# Codex reviews carried findings, so the success path was never once exercised
# until PR #12 came back clean and the watch polled until it timed out.
#
# TWO signals are required, not one. The commit binding alone would accept any
# comment that happens to quote this head, and the phrase alone would accept a
# clean pass on a DIFFERENT commit. A false negative here merely keeps the loop
# waiting; a false positive invents a signoff, so this is the direction to be
# conservative in.
clean_comment_for_head() {
    local pr="$1" who="$2" head="$3" raw out
    if ! raw=$(gh api --hostname "$HOST" "repos/$OWNER/$REPO/issues/$pr/comments" --paginate 2>/dev/null); then
        return 2
    fi
    # Prints "<id>\t<created_at>": the caller needs the timestamp to place this
    # against the newest submitted review on the same head.
    out="$(printf '%s' "$raw" | jq -s -r --arg who "$who" --arg h "${head:0:10}" "$RECORDLIB_JQ"'
        pages_or_error
        | [ .[][] ] as $all
          | if any($all[]; valid_comment_record | not)
            then error("malformed comment record")
            else ( [ $all[]
                     | select(.user.login == $who)
                     | select((.body | type) == "string")
                     | select(.body | test("[Dd]idn.t find any major issues"))
                     # The hash is EXTRACTED FROM THE FIELD and compared exactly.
                     # Two independent `contains` checks passed a clean comment
                     # for an OLDER head that merely mentioned the current
                     # prefix in its prose — the footer named a different
                     # commit, and the current unreviewed head read as clean.
                     # The FOOTER LINE, and the LAST one. `capture` takes the
                     # first match anywhere, so an older clean comment carrying a
                     # field-shaped `Reviewed commit:` line in its prose ahead of
                     # its real footer would be read as a signoff for whatever
                     # that prose named. Anchored to a line start with the bold
                     # markers, and the last occurrence wins, because the genuine
                     # footer is the final one.
                     | select((.body | [scan("(?m)^\\*\\*Reviewed commit:\\*\\* `([0-9a-f]{10})`")] | last // [""] | .[0]) == $h)
                   ] | sort_by(.id) | last ) as $c
              | if $c == null then ""
                # The timestamp is NOT re-checked here. `valid_comment_record`
                # above requires a canonical UTC `created_at` of every record on
                # the page, so nothing reaching this point can lack one — and a
                # second copy of the rule would be unreachable code shaped like a
                # guard, which reads as protection while proving nothing. The
                # reason the rule exists belongs with the rule: this value is
                # ordered LEXICALLY against review timestamps, so a `zzzz` would
                # sort above every real one and a null would read as clean
                # whenever no review existed.
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

# Print "<state>\t<review-id>" for THIS head from ONE reviews fetch, or fail (2).
# The id is the authoritative latest submitted review the state was derived from,
# and is empty unless the state is `reviewed`.
#
# State and id must come from the SAME snapshot. Deriving them from separate
# fetches let a review that changed in between be judged on one snapshot and
# counted on another - a COMMENTED read followed by a DISMISSED one counted the
# withdrawn review's zero comments and reported clean.
head_review_snapshot() {
    local pr="$1" who="$2" head="$3" reviews out cid
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
          # The id accompanies every TERMINAL state, not only `reviewed`.
          # `blocked` and `dismissed` are precisely the same-head re-request
          # cases, and an empty id there disabled the caller comparison that
          # exists to tell the new pass from the old one.
          | $st + "\t" + (if ($st == "reviewed" or $st == "blocked" or $st == "dismissed")
                              and $latest != null
                           then ($latest.id | tostring) else "" end)
        end' 2>/dev/null)" || return 2
    # BOTH CHANNELS, placed in time against each other.
    #
    # Consulting comments only when there was no review at all was too narrow: a
    # clean RE-review on an unchanged head also arrives as a comment, so an older
    # finding-bearing or blocked review stayed authoritative forever and the watch
    # timed out repeatedly despite a newer clean pass. Whichever is newer wins,
    # and a review with no timestamp cannot outrank anything.
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
        # A drafted re-review still dominates: `pending` means the pass is not
        # finished, whatever any comment says.
        case "${out%%$'\t'*}" in
            pending) ;;
            *) if [ -n "$latest_ts" ] && [ "$cts" = "$latest_ts" ]; then
                   # EQUAL is not "the review wins". GitHub timestamps are
                   # second-resolution, so a clean re-review comment created in
                   # the same second as the blocking review it supersedes ties —
                   # and a strict `>` silently left the older review
                   # authoritative, so the watch rejected the clean pass as stale
                   # and timed out despite the re-review having completed.
                   # Nothing here can order them, so this is unreadable, not a
                   # decision.
                   echo "PR_REVIEW_STATE pr=$pr status=error reason=ambiguous_verdict_order ts=$cts" >&2
                   return 2
               elif [ -z "$latest_ts" ] || [ "$cts" \> "$latest_ts" ]; then
                   out="reviewed"$'\t'"comment:$cid"
               fi ;;
        esac
    fi
    case "${out%%$'\t'*}" in
        none|pending|blocked|dismissed|reviewed) printf '%s' "$out" ;;
        *) return 2 ;;
    esac
}

# Count the inline comments of ONE known review id. 0 = count printed · 2 = fail.
review_comment_count() {
    local pr="$1" id="$2" head="$3" raw n
    case "$id" in
        ""|*[!0-9]*) return 2 ;;
    esac
    if ! raw=$(gh api --hostname "$HOST" "repos/$OWNER/$REPO/pulls/$pr/reviews/$id/comments" --paginate 2>/dev/null); then
        return 2
    fi
    # A REPLY IS NOT A FINDING — BUT ONLY WHEN IT IS THE VERDICT ITSELF.
    #
    # This counted every comment row, and a reviewer's verdict is sometimes
    # delivered as a REPLY on an existing thread — "No blocking findings on
    # <sha>" arrived that way — which counted as one finding. That is terminal:
    # the count cannot drop, because the comment IS the verdict, so the loop never
    # closes and the gate blocks a PR its reviewer passed.
    #
    # DROPPING ALL REPLIES WAS THE WRONG FIX, and this is the second attempt. A
    # blocking finding posted as a reply on an already-resolved thread would be
    # dropped too — and `pr-findings.sh` cannot surface a resolved thread, so BOTH
    # gates read clean and the PR merges with the finding unaddressed. The first
    # version documented that as an accepted limitation; it is not one, because it
    # trades a stuck loop for a wrong merge.
    #
    # So a reply is skipped only when it is RECOGNISABLY this reviewer's clean
    # verdict FOR THIS HEAD: it names the head and says it found nothing. Anything
    # else a reply says counts, which fails closed — an unrecognised phrasing
    # stalls the round, and a stalled round is visible and recoverable in a way a
    # merged finding is not.
    #
    # Head-bound on purpose: "no blocking findings on <old sha>" says nothing
    # about the commit being gated.
    n=$(printf '%s' "$raw" | jq -s --arg head "${head:0:7}" "$RECORDLIB_JQ"'
        # EVERY ROW IS VALIDATED FIRST. `in_reply_to_id` is absent or a number and
        # never null or a string, so anything else is a payload this cannot read —
        # and a presence-only test silently discarded such a row as a reply, so a
        # page of them counted zero, which is `clean`.
        pages_or_error
        | [.[][]] as $rows
        | if any($rows[]; valid_review_comment | not)
          then error("malformed review comment")
          else [ $rows[]
                 # THE WHOLE LINE, NOT A SUBSTRING. A reply that QUOTES or NEGATES
                 # the verdict — "the prior verdict said no blocking findings on
                 # <sha>, but this is still broken" — contains the phrase and the
                 # sha, so a substring test classified a blocking finding as the
                 # clean verdict and dropped it. On a resolved thread that is a
                 # merge with the finding unaddressed.
                 #
                 # So some LINE has to BE the verdict: optional heading marks and
                 # spaces, the canonical sentence, the head, and nothing else on
                 # it. Anything the reviewer adds goes on its own lines, which is
                 # what the real verdict looks like.
                 | select(opens_a_thread
                          or ((.body // "") | ascii_downcase | split("\n")
                              | any(.[]; test("^ *#{0,6} *no blocking findings on `?" + $head + "[0-9a-f]*`?\\.? *\r?$"))
                              | not)) ]
               | length
          end' 2>/dev/null) || return 2
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
    # A comment-sourced signoff carries no inline comments by construction:
    # there is no review to count them against. Counting is skipped rather than
    # faked, and the re-check below still guards against the state moving.
    case "$id" in
        comment:*) n=0 ;;
        *) n="$(review_comment_count "$pr" "$id" "$head")" || return 2 ;;
    esac
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
        state|verdict|head|review-id) ;;
        *) echo "usage: $0 {state|verdict|head|review-id} <pr> <reviewer-login> [head-oid]" >&2; exit 2 ;;
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
    if ! _sha_why="$(sha_reason "$head")"; then
        echo "PR_REVIEW_STATE pr=$pr status=error reason=$_sha_why" >&2
        exit 2
    fi

    # Printed bare and in full: this is the value a caller pins its other probes
    # to, so an abbreviation would put back the ambiguity it exists to remove.
    if [ "$cmd" = "head" ]; then
        printf '%s\n' "$head"
        return 0
    fi

    # The id of the authoritative review on this head, or empty when there is
    # none. A caller waiting for a re-request on an UNCHANGED head has nothing
    # else to tell the new pass from the old one.
    if [ "$cmd" = "review-id" ]; then
        local snap
        snap="$(head_review_snapshot "$pr" "$who" "$head")" || {
            echo "PR_REVIEW_STATE pr=$pr status=error reason=unreadable" >&2
            return 2
        }
        printf '%s\n' "${snap#*$'\t'}"
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
