#!/usr/bin/env -S bash -p
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
# ── STARTED PRIVILEGED, OR NOT STARTED ─────────────────────────────────────
#
# The shebang above is `env -S bash -p`, and that is the defence this block
# exists to state. An ordinary `#!/usr/bin/env bash` SOURCES `BASH_ENV`, IMPORTS
# functions from the environment, and honours an exported `SHELLOPTS` — so every
# builtin this script uses is a name the operator's shell can replace, and each
# one found took a review round of its own: `type`, `return`, `set`, `echo`,
# `exit`. Privileged mode does none of the three, so there is nothing to shadow
# and nothing to clear. Measured: under `BASH_FUNC_echo%` and `BASH_FUNC_set%`,
# a privileged shell reports both as builtins.
#
# THE HOOK CANNOT BE OUT-RUN FROM IN HERE, which is why this is the shebang and
# not a re-exec. A `BASH_ENV` hook runs before this file's first line, and one
# that prints a forged `PR_REVIEW_STATE status=error` line and exits has already answered the
# caller — no later re-exec takes that back. The interpreter has to be privileged
# from the start, which only the shebang or the caller can arrange.
#
# WHAT STARTS IT PRIVILEGED IS THE CALLER, AND THE SHEBANG IS THE FALLBACK.
# `SKILL.md` invokes every helper as `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-x.sh`,
# which starts a fresh privileged interpreter whatever the driving shell is and
# whatever that platform's `env` supports. The shebang covers the other way in —
# executing the file directly — and needs `env -S`, which is why it is not the
# thing relied on.
#
# `$-` IS A LAST-RESORT REFUSAL AND PROVES LESS THAN IT LOOKS. It reports the
# MODE this shell is in, not how it got there: run as `BASH_ENV=hook bash
# pr-x.sh`, the hook is sourced BEFORE this line and can itself run `set -p` and
# then define `echo` or `exit`, after which `$-` contains `p` and this test
# passes on a shell that has already executed hostile code. Nothing inside a
# script can detect work done before its first line — so this catches the honest
# mistake, and `bash pr-x.sh` is UNSUPPORTED rather than defended. Measured:
# `BASH_ENV=/tmp/h bash -c 'printf "%s %s" "$-" "$(type -t echo)"'` with a hook
# running `set -p; echo() { :; }` prints `hpBc function`.
if [[ $- != *p* ]]; then
    echo "PR_REVIEW_STATE status=error reason=not_privileged" >&2
    exit 2
fi

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
# successfully, so without the clear the first load runs the INHERITED
# function — and a stale loader is the one thing that can make every OTHER load
# look clean. See loadlib.sh and issue #22.
unset -f rb_load 2>/dev/null || {
    echo "PR_REVIEW_STATE status=error reason=loadlib_stale_definition" >&2; exit 2; }
# NO `type -t rb_load` PREFLIGHT. It verified the loader by asking `type`, which
# is a NAME — and while a privileged interpreter means no function by that name
# can be imported, verifying a thing by asking a second thing about it is the
# shape #88 is about: the answer is only as good as the asker. The FIRST LOAD is
# the verification instead: the stub below is what an empty `loadlib.sh` leaves
# behind, and calling it fails. Nothing is asked ABOUT the loader — the load
# itself is the answer.
#
# THE REFUSING STUB IS WHAT MAKES THAT TRUE. Without it, an `rb_load` that is not
# a function is looked up on `PATH` — privileged mode does not change `PATH` —
# and an executable by that name exiting 0 would report every load successful
# with nothing cleared and no library sourced. Defining it means the call cannot
# leave this shell: a good `loadlib.sh` replaces the stub when sourced, an empty
# one leaves the refusal. `return` is a builtin and nothing can shadow it here,
# because a privileged shell imports no functions. #88.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_REVIEW_STATE status=error reason=loadlib_unreadable" >&2; exit 2; }
# THE FIRST LOAD CARRIES THE SENTINEL, because it is what the preflight used to
# say. An empty `loadlib.sh` leaves the stub, the stub returns 127, and without
# this arm the only trace is a bare exit status — the ordinary-looking empty
# answer `CLAUDE.md` forbids. 127 is the stub's and nothing else's: `rb_load`'s
# own refusals report their own reason and their own status.
rb_load "$_RB_SELF_DIR" recordlib RECORDLIB_JQ "PR_REVIEW_STATE status=error" var || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "PR_REVIEW_STATE status=error reason=loadlib_empty" >&2
    exit 2; }

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
    local pr="$1" id="$2" raw n
    case "$id" in
        ""|*[!0-9]*) return 2 ;;
    esac
    if ! raw=$(gh api --hostname "$HOST" "repos/$OWNER/$REPO/pulls/$pr/reviews/$id/comments" --paginate 2>/dev/null); then
        return 2
    fi
    # EVERY COMMENT COUNTS, INCLUDING REPLIES — and the answer says when they were
    # ALL replies, so the caller can tell a review with findings from a review
    # whose only content is conversation.
    #
    # THREE ATTEMPTS AT EXEMPTING THE VERDICT ITSELF FAILED, and the third failed
    # for a reason that generalises. A reviewer's clean verdict is sometimes
    # delivered as a reply — "No blocking findings on <sha>" — and counting it as a
    # finding leaves the loop stuck: the count cannot drop, because the comment IS
    # the verdict. So the exemption looked necessary. But:
    #
    #   · dropping every reply let a blocking finding posted as one merge unseen;
    #   · matching the phrase let a reply that NEGATED it — "the prior verdict said
    #     no blocking findings on <sha>, but this is still broken" — read as clean;
    #   · matching a whole LINE let a reply that carries the verdict line and then
    #     retracts it two lines later read as clean.
    #
    # The third is the general case: the real verdict is followed by paragraphs of
    # explanation, and a retraction is also a paragraph after the verdict line.
    # Telling them apart means knowing which words mean "except" — a denylist, one
    # word behind forever, which this repository has already paid for once and
    # written a rule against.
    #
    # So the exemption is gone. A reply counts, the same as before this was ever
    # touched, and the stuck loop is solved where it can be solved honestly: this
    # says `replies-only`, `pr-findings.sh` shows nothing to fix, and the driver
    # stops for the operator instead of spinning. A human reads one comment.
    n=$(printf '%s' "$raw" | jq -s -r "$RECORDLIB_JQ"'
        # EVERY ROW IS VALIDATED FIRST. `in_reply_to_id` is absent or a number and
        # never null or a string, so anything else is a payload this cannot read —
        # and a presence-only test silently discarded such a row as a reply, so a
        # page of them counted zero, which is `clean`.
        pages_or_error
        | [.[][]] as $rows
        | if any($rows[]; valid_review_comment | not)
          then error("malformed review comment")
          else "\([$rows[]] | length):\([$rows[] | select(opens_a_thread)] | length)"
          end' 2>/dev/null) || return 2
    # `<total>:<that opened a thread>`, and BOTH have to be numbers. A partial
    # answer here is the one that decides a merge.
    case "$n" in
        *[!0-9:]*|*:*:*|:*|*:|"") return 2 ;;
        *:*) ;;
        *) return 2 ;;
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
        comment:*) n="0:0" ;;
        *) n="$(review_comment_count "$pr" "$id")" || return 2 ;;
    esac
    snap2="$(head_review_snapshot "$pr" "$who" "$head")" || return 2
    if [ "$snap2" != "$snap1" ]; then
        printf 'changed'
        return 1
    fi
    # THE SHAPE COMES BACK WITH THE COUNT. A review whose comments are ALL replies
    # carries no finding anyone can act on — `pr-findings.sh` lists nothing — but it
    # is not clean either: a reply can retract a verdict, and no reading of the text
    # can tell that from a verdict followed by its explanation. So it is reported as
    # what it is, and the driver stops for the operator rather than spinning.
    local total="${n%%:*}" opens="${n##*:}"
    [ "$total" -eq 0 ] 2>/dev/null || {
        if [ "$opens" -eq 0 ] 2>/dev/null; then
            printf 'findings:%s:replies-only' "$total"
        else
            printf 'findings:%s' "$total"
        fi
        return 1
    }
    printf 'clean'
    return 0
}

main() {
    local cmd="${1:-}" pr="${2:-}" who="${3:-}" head="${4:-}"
    case "$cmd" in
        state|verdict|head|review-id|review-at|escape-snapshot) ;;
        *) echo "usage: $0 {state|verdict|head|review-id|review-at|escape-snapshot} <pr> <reviewer-login> [head-oid]" >&2; exit 2 ;;
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
    # WHEN THE AUTHORITATIVE REVIEW LANDED. The merge gate needs it to tell an
    # operator's answer from a leftover: a signoff recorded for an earlier clean
    # review on the SAME HEAD would otherwise vouch for a later replies-only review
    # nobody read. A head is not a moment.
    if [ "$cmd" = "review-at" ]; then
        # THE FETCH'S STATUS IS TAKEN ON ITS OWN LINE, as `head_review_snapshot`
        # does. Nested inside the outer substitution it was DISCARDED: a failed
        # reviews endpoint prints nothing, `jq` reads empty input, and `jq` on
        # empty input produces no output and exits 0 — measured. So the answer was
        # an empty string with status 0, which every caller reads as "no verdict on
        # this head".
        #
        # WHAT THAT COSTS: the merge gate orders records against this value, so a
        # signoff recorded for an earlier clean review on the same head would vouch
        # for a later replies-only review nobody read. An incomplete snapshot
        # presented as a complete one — the fail-open shape this repository forbids.
        #
        # The `||` on the outer substitution looks like it takes the status and
        # does; the status it takes is `jq`'s, and `jq` succeeded. The failure was
        # one level in. #113.
        local at reviews
        reviews=$(reviewer_reviews "$pr" "$who") || {
            echo "PR_REVIEW_STATE pr=$pr status=error reason=unreadable" >&2
            return 2
        }
        at="$(printf '%s' "$reviews" | jq -r --arg h "$head" "$RECORDLIB_JQ"'
            if type != "array" then error("bad shape")
            else [ .[]
                   | select(.commit_id == $h)
                   | select(.submitted_at != null)
                   | select(.submitted_at | canonical_utc)
                   | .submitted_at ] | sort | last // ""
            end' 2>/dev/null)" || {
            echo "PR_REVIEW_STATE pr=$pr status=error reason=unreadable" >&2
            return 2
        }
        # A CLEAN VERDICT ARRIVES AS A COMMENT AS OFTEN AS A REVIEW, and reading
        # only `pulls/N/reviews` said "no verdict" on exactly those heads. Codex
        # submits a review when it has findings and an issue comment when it does
        # not — it used a comment on #35 — so a caller ordering a revocation
        # against "when the verdict landed" would have refused the ordinary case.
        # `verdict` and `state` have consulted both since; this one had not. #117.
        # 1 IS "NO CLEAN COMMENT", WHICH IS AN ANSWER; only 2 is a failed read.
        # Treating every non-zero as unreadable made the ordinary case — a head
        # whose verdict came as a review — report an error instead of the review's
        # timestamp.
        local cinfo crc=0
        cinfo="$(clean_comment_for_head "$pr" "$who" "$head")" || crc=$?
        case "$crc" in
            0|1) ;;
            *) echo "PR_REVIEW_STATE pr=$pr status=error reason=unreadable" >&2
               return 2 ;;
        esac
        # THE LATER OF THE TWO, compared lexically — both are canonical UTC, which
        # `valid_comment_record` and the `canonical_utc` filter above each enforce,
        # so the string order is the time order. An absent one is the empty string
        # and loses to any real timestamp.
        local cat_=""
        [ -n "$cinfo" ] && cat_="${cinfo#*$'\t'}"
        if [ -n "$cat_" ] && { [ -z "$at" ] || [ "$cat_" \> "$at" ]; }; then
            at="$cat_"
        fi
        printf '%s\n' "$at"
        return 0
    fi

    if [ "$cmd" = "escape-snapshot" ]; then
        # ONE SERVER RESPONSE, NOT A PROTOCOL OVER TWO. The REST endpoints answer
        # reviews and review comments separately, and no ordering of separate
        # reads makes them one snapshot: with the comments read last a review
        # dismissed afterwards is invisible, with the reviews read last a reply
        # posted afterwards is — and alternating a third time only moves the race.
        # #132 spent five rounds discovering that one layer at a time.
        #
        # GraphQL returns both in a SINGLE response, so the review, its state, its
        # time and its comments are consistent by construction and there is nothing
        # to compare. What is left is the gap after the response, which no protocol
        # can cover: a signoff answers what had happened when it was written.
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
        # A 200 CAN CARRY BOTH `errors` AND A STRUCTURALLY VALID `data`, and the
        # partial data passes every shape check below while omitting reviews — an
        # answer of "not that shape" taken from a response that failed.
        printf '%s' "$epage" | jq -e 'has("errors") | not' >/dev/null 2>&1 || {
            echo "PR_REVIEW_STATE pr=$pr status=error reason=unreadable" >&2
            return 2
        }
        # THE WHOLE ANSWER IN ONE PROGRAM, because splitting it into passes over
        # the same response is how two passes come to disagree about which rows
        # they are describing.
        #
        # `error` FOR EVERY UNREADABLE STATE and a bare `none` for "not that
        # shape": the two are different answers and only one of them is a failure.
        # A truncated page is unreadable — the reviews are the LAST hundred, so an
        # earlier page could hold a draft that dominates, and a review with more
        # than a hundred comments would have its newest one cut off.
        eanswer="$(printf '%s' "$epage" | jq -r --arg h "$head" --arg who "$who" "$RECORDLIB_JQ"'
            .data.repository.pullRequest.reviews as $r
            | if ($r | type) != "object" or ($r.nodes | type) != "array"
                 or ($r.pageInfo.hasPreviousPage | type) != "boolean"
              then error("bad shape")
              elif $r.pageInfo.hasPreviousPage then error("truncated reviews")
              # EVERY NODE IS VALIDATED BEFORE ANY IS FILTERED. A `select` over a
              # malformed node DISCARDS it, and discarding a newer review leaves an
              # older replies-only one as the latest — so a signoff newer than THAT
              # one closes the phase over a review nothing could read. "This
              # response is not trustworthy" and "that review is not mine" are the
              # two answers this must keep apart.
              elif any($r.nodes[];
                       type != "object"
                       or (.author | type) != "object" or (.author.login | type) != "string"
                       # AND THE OID IS A COMMIT, through the shared predicate. A
                       # string that is not one — a truncated head, say — passes a
                       # type check and is then DISCARDED by the head filter, which
                       # hands the decision to an older replies-only review.
                       or (.commit | type) != "object" or (.commit.oid | full_sha | not)
                       or (.state | type) != "string"
                       # THE CANONICAL SHAPE, NOT MERELY A STRING. The sort below
                       # decides which review is authoritative, and a string that
                       # is not a time sorts SOMEWHERE — "0000" sorts under every
                       # real timestamp, so a malformed newer review hands the
                       # decision to an older replies-only review, whose own time
                       # then passes the only shape check there was.
                       #
                       # NO APOSTROPHE IN THIS COMMENT: the jq program is a
                       # single-quoted shell string, and one here ends it.
                       or (.submittedAt != null and (.submittedAt | canonical_utc | not)))
              then error("bad review node")
              else
                [ $r.nodes[]
                  | select(.author.login == $who)
                  | select(.commit.oid == $h) ] as $mine
                | if ($mine | length) == 0 then "none"
                  # THE SAME DOMINANCE RULES the state snapshot applies: a draft in
                  # flight means the pass is not finished, whatever an older
                  # submitted review says.
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
                        # AND EVERY COMMENT ROW, INCLUDING ITS REPLY LINK. A
                        # `replyTo` that is a string or an array is not null, so a
                        # presence test reads it as a REPLY — and a set of rows
                        # nothing could classify then produces a valid snapshot,
                        # which is a merge on a finding/reply relationship that was
                        # never read.
                        | if any($c[];
                                 type != "object"
                                 or (.createdAt | canonical_utc | not)
                                 or (.replyTo != null
                                     and ((.replyTo | type) != "object"
                                          or (.replyTo.databaseId | type) != "number")))
                          then error("bad comment row")
                          # NO COMMENTS IS A DIFFERENT RECORD, and a comment that
                          # OPENS a thread is a finding rather than a reply — not a
                          # question an operator was asked.
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
        findings:*:replies-only)
            _f="${out#findings:}"; _f="${_f%%:*}"
            # NAMED, because the driver must not read it as either answer: there is
            # nothing to fix and it is not a signoff. A human reads the reply.
            echo "PR_REVIEW_STATE pr=$pr sha=$short reviewer=$who verdict=findings findings=$_f source=replies-only" ;;
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
