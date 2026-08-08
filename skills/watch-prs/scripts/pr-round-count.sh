#!/usr/bin/env bash
# How many review rounds has this PR had, and is this a check-in boundary?
#
#   pr-round-count.sh <pr> [reviewer-login ...]
#
#   0  below the boundary — carry on
#   3  boundary reached: PAUSE and decide with the operator
#   2  the count could not be established — fail closed, do NOT silently continue
#
# A round is a DISTINCT PR head that received a submitted review. Counting heads
# rather than reviews means two reviewers on the same commit is one round, and a
# re-review of an unchanged head does not inflate the count.
#
# The count is derived from GitHub every time, never from local state: the v1
# counter lived in a `/tmp` file, so the pause it promised silently disappeared
# whenever a session started on a different machine or the file was cleaned up.
# A guarantee that only holds while a temp file survives is not a guarantee.
#
# `set -uo pipefail`, NOT `-e`: `gh` probes fail as normal operation and the
# result is control flow. See CLAUDE.md § Bash conventions.
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
    echo "PR_ROUND_COUNT status=error reason=lib_dir_unresolvable" >&2; exit 2; }
# shellcheck source=recordlib.sh
. "$_RB_SELF_DIR/recordlib.sh" || {
    echo "PR_ROUND_COUNT status=error reason=recordlib_unreadable" >&2; exit 2; }
[ -n "${RECORDLIB_JQ:-}" ] || {
    echo "PR_ROUND_COUNT status=error reason=recordlib_empty" >&2; exit 2; }

THRESHOLD="${REVIEW_ROUND_THRESHOLD:-10}"
# A malformed threshold falls back to the default rather than disabling the
# check-in: a typo must not silently remove a safety pause. `0` disables it, but
# only when written EXACTLY that way.
#
# Leading zeros are rejected rather than accepted as digits, because Bash reads
# them as octal in arithmetic: `00` silently disabled the pause, and `08`/`09`
# aborted the script with an undocumented exit 1 — neither of which is the
# documented fallback.
case "$THRESHOLD" in
    0)           ;;              # explicitly disabled
    0*)          THRESHOLD=10 ;; # 00, 08, 012 … not a plain decimal
    ""|*[!0-9]*) THRESHOLD=10 ;;
esac
# An all-digit value can still be beyond Bash's fixed-width arithmetic, where it
# wraps — possibly to zero, silently taking the disable path that only a literal
# `0` is meant to take. Length is the cheap bound: anything this long is a typo,
# not a cadence.
case "$THRESHOLD" in
    0) ;;
    ??????????*) THRESHOLD=10 ;;
esac

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
    echo "PR_ROUND_COUNT status=error reason=identitylib_stale_definition" >&2; exit 2; }
# shellcheck source=identitylib.sh
. "$_RB_SELF_DIR/identitylib.sh" || {
    echo "PR_ROUND_COUNT status=error reason=identitylib_unreadable" >&2; exit 2; }
[ "$(type -t rb_identity 2>/dev/null)" = function ] || {
    echo "PR_ROUND_COUNT status=error reason=identitylib_empty" >&2; exit 2; }
rb_identity || {
    echo "PR_ROUND_COUNT status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }
REPO_SLUG="$HOST/$OWNER/$REPO"

PR="${1:-}"
case "$PR" in
    ""|*[!0-9]*) echo "usage: $0 <pr> [reviewer-login ...]" >&2; exit 2 ;;
esac
shift || true

# Default to the two native reviewers; any logins given override that.
if [ "$#" -gt 0 ]; then
    REVIEWERS=("$@")
else
    REVIEWERS=('chatgpt-codex-connector[bot]' 'copilot-pull-request-reviewer[bot]')
fi
WHO_JSON="$(printf '%s\n' "${REVIEWERS[@]}" | jq -R . | jq -s -c .)" || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=reviewer_list_unreadable" >&2
    exit 2
}

raw=$(gh api --hostname "$HOST" "repos/$OWNER/$REPO/pulls/$PR/reviews" --paginate 2>/dev/null) || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=fetch_failed"
    exit 2
}

# A CLEAN pass is a round, and it leaves no review behind.
#
# Codex submits a review only when it has findings, so a clean head appears
# nowhere in `pulls/N/reviews`. Counting reviews alone made nine finding-bearing
# heads plus a clean tenth report `rounds=9` — and the phase-transition checks
# that consult this number would skip the operator pause at exactly the boundary
# it exists for.
icraw=$(gh api --hostname "$HOST" "repos/$OWNER/$REPO/issues/$PR/comments" --paginate 2>/dev/null) || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=comments_fetch_failed"
    exit 2
}

# Same page-shape discipline as pr-review-state.sh: `jq -s` slurps into an array
# of PAGES, empty input slurps to zero pages, and `.[][]` over an object iterates
# its values — so an errored body or an empty read would otherwise count as
# "no rounds yet", which is the direction that skips the pause.
# The count, for one reviewer list. Extracted into a function because the pause
# below has to report EACH reviewer's own count, not the combined one: the
# instruction it prints is followed literally, and telling the operator to
# acknowledge 41 for a reviewer with 5 rounds recreates the cross-phase block
# through the message instead of through the parser. Same defect, one layer out.
#
# Echoes the count and returns 0; echoes a status line and returns 2 otherwise.
count_for() {
local _rounds _clean
    _rounds=$(printf '%s' "$raw" | jq -s --argjson who "$1" "$RECORDLIB_JQ"'
    pages_or_error
    | [ .[][] ] as $all
    # THE SHARED VALIDATOR, not a local copy. Every rule it applies used to be
    # written out here and again in two other scripts, so a fix reached one and
    # not the others — `state` reached two and stopped, and the third then read an
    # unrecognised value as a withdrawn review. See recordlib.sh and issue #11.
    | if any($all[]; valid_review_record | not)
      then error("malformed review record")
      # A round is a FINISHED pass. PENDING is a draft in flight — the same thing
      # pr-review-state.sh refuses to read as a signoff — so it is not a round
      # however its submitted_at reads.
      else [ $all[]
             | select((.user.login | IN($who[]))
                      and .submitted_at != null
                      and .state != "PENDING")
             | .commit_id ] | unique
      end' 2>/dev/null) || {
        echo "PR_ROUND_COUNT pr=$PR status=error reason=unreadable"
        return 2
    }

_clean=$(printf '%s' "$icraw" | jq -s --argjson who "$1" "$RECORDLIB_JQ"'
    pages_or_error
    | [ .[][] ] as $all
      | if any($all[]; valid_comment_record | not)
        then error("malformed comment record")
        else [ $all[]
               | select((.user.login | IN($who[])) and ((.body | type) == "string"))
               | select(.body | test("(?m)^\\*\\*Reviewed commit:\\*\\* `[0-9a-f]{10}`"))
               | select(.body | test("[Dd]idn.t find any major issues"))
               # EXACTLY ten hex characters, the documented footer width. A
               # shorter hash cannot be deduplicated against the 10-char prefix
               # taken from a full review SHA, so a clean re-review of an
               # already-counted head would add a phantom round — and ten real
               # heads plus that phantom reports 11, skipping the modulo pause.
               # Same parsing rule as pr-review-state.sh: the anchored footer
               # line, last occurrence. A field-shaped line in prose would
               # otherwise name a head this comment never reviewed.
               | (.body | [scan("(?m)^\\*\\*Reviewed commit:\\*\\* `([0-9a-f]{10})`")] | last // [""] | .[0])
             ] | map(select(. != "")) | unique
        end' 2>/dev/null) || {
        echo "PR_ROUND_COUNT pr=$PR status=error reason=comments_unreadable"
        return 2
    }

    jq -n --argjson r "$_rounds" --argjson c "$_clean" '
    ($r | map(.[0:10])) as $rp
    | ($rp + ($c | map(.[0:10]))) | unique | length' 2>/dev/null || {
        echo "PR_ROUND_COUNT pr=$PR status=error reason=count_unreadable"
        return 2
    }
}


rounds="$(count_for "$WHO_JSON")" || exit 2
case "$rounds" in
    ""|*[!0-9]*) echo "PR_ROUND_COUNT pr=$PR status=error reason=bad_count"; exit 2 ;;
esac

if [ "$THRESHOLD" -eq 0 ]; then
    echo "PR_ROUND_COUNT pr=$PR rounds=$rounds threshold=0 pause=0"
    exit 0
fi

# THE BOUNDARY IS CROSSED, NOT LANDED ON.
#
# This was `rounds % THRESHOLD -eq 0`, which assumes the counter advances by
# exactly one per call. It does not: a single round can contribute more than one
# countable head — a fix commit reviewed and then a clean re-review comment on a
# later head both land between two invocations — and the count observed here went
# 35 → 41 across two rounds. The multiple of ten in between was stepped OVER, the
# equality never held, and the operator pause the threshold exists to trigger
# never fired at all. A safety pause that a large enough step silently skips is
# not a safety pause.
#
# So the test is an inequality against the last count the OPERATOR acknowledged,
# which cannot be stepped over however far the counter jumps.
#
# The acknowledgement lives on the PR, like the round count itself. Local state
# was tried in v1 and removed: a pause that only holds while a `/tmp` file
# survives disappears on another machine. Its shape is an anchored footer line,
# the same convention as the clean-pass footer above:
#
#     **Review-Pause-Acknowledged:** `chatgpt-codex-connector[bot]` `41`
#
# IT NAMES THE REVIEWER, because the count does. The Codex and Copilot phases are
# separate loops with separate counts — that is the whole reason this script takes
# a reviewer list — and an unscoped acknowledgement crossed between them: an
# acknowledgement of 41 Codex rounds was read by a Copilot invocation with 5, hit
# the ahead-of-count guard, and returned status 2 forever, blocking the Copilot
# phase and the merge gate behind it. Landing that took under an hour: the
# acknowledgement that cleared the Codex pause on this very PR immediately bricked
# its Copilot phase. There is no unscoped form; a footer without a reviewer is
# not an acknowledgement.
#
# WHO may write it is part of the rule. Anyone can comment on a pull request, so
# an unrestricted marker would let a reviewer bot — or a passer-by — disable the
# operator pause permanently by naming a large number. Only OWNER, MEMBER and
# COLLABORATOR comments are read, which is the same "a finding is waived only by
# an authority, never by the PR" line the review contract already draws.
ack=$(printf '%s' "$icraw" | jq -s -r --argjson who "$WHO_JSON" "$RECORDLIB_JQ"'
    pages_or_error
    | [ .[][] ] as $all
      # Deliberately NOT `valid_comment_record` here. An unread acknowledgement
      # causes an EXTRA pause, which is the safe direction, so a record this scan
      # cannot read is skipped below rather than failing the whole count — one odd
      # comment must not be able to take the round counter down. The container is
      # still checked, because a page that is not a page is a failed read.
      | if any($all[]; type != "object")
        then error("malformed comment record")
        else [ $all[]
               # A record that does not carry a readable association is simply
               # not an acknowledgement. Erroring on it would be the WRONG
               # direction of fail-closed here: an unread acknowledgement causes
               # an EXTRA pause, which is safe, while erroring lets one odd
               # comment take down the whole count.
               | select((.author_association | type) == "string")
               | select(.author_association | IN("OWNER","MEMBER","COLLABORATOR"))
               | select((.body | type) == "string")
               # Anchored and taken LAST, exactly as the reviewed-commit footer
               # is: a field-shaped line quoted inside prose — this script'"'"'s own
               # documentation, pasted into a comment — must not be read as an
               # acknowledgement nobody made.
               | (.body | [scan("(?m)^\\*\\*Review-Pause-Acknowledged:\\*\\* `([^`\n]{1,200})` `([0-9]{1,9})`")]
                        | last // ["",""])
               # The login is COMPARED, never interpolated into a pattern: these
               # are `…[bot]` logins, where `[` and `]` are regex metacharacters
               # that would silently match something else entirely.
               | select(.[0] | IN($who[]))
             ] | map(.[1]) | map(select(. != "")) | map(tonumber) | max // 0
        end' 2>/dev/null) || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=ack_unreadable"
    exit 2
}
case "$ack" in
    ""|*[!0-9]*) echo "PR_ROUND_COUNT pr=$PR status=error reason=bad_ack ack=$ack"; exit 2 ;;
esac
# An acknowledgement of a round that has not happened yet is not an
# acknowledgement — it is the disable-forever shape, reachable by a typo as
# easily as by an attacker. Unreadable, not permissive.
if [ "$ack" -gt "$rounds" ]; then
    echo "PR_ROUND_COUNT pr=$PR status=error reason=ack_ahead_of_count ack=$ack rounds=$rounds"
    exit 2
fi

if [ "$rounds" -ge $((ack + THRESHOLD)) ]; then
    echo "PR_ROUND_PAUSE pr=$PR rounds=$rounds threshold=$THRESHOLD acknowledged=$ack"
    echo "Decide with the operator: continue / stop & merge / stop & leave open / abandon." >&2
    # EACH REVIEWER'S OWN COUNT, never the combined one. This loop used to print
    # `$rounds` beside every login, and with 41 Codex heads and 5 Copilot heads an
    # operator following it literally wrote a Copilot acknowledgement of 41 — which
    # a later Copilot-only call reads as ahead of its count and refuses forever.
    # That is the cross-phase block this change exists to remove, recreated through
    # the instruction instead of through the parser.
    echo "To continue, post a comment containing, for each reviewer counted here:" >&2
    for _w in "${REVIEWERS[@]}"; do
        _wj="$(printf '%s' "$_w" | jq -R . | jq -s -c .)" || {
            echo "PR_ROUND_COUNT pr=$PR status=error reason=reviewer_list_unreadable" >&2
            exit 2
        }
        # A count that cannot be established is not printed as a number to copy.
        # `count_for` writes its own status line, and the pause has already been
        # announced, so the operator sees which reviewer could not be counted
        # rather than an instruction that would wedge that phase.
        _wr="$(count_for "$_wj")" || exit 2
        echo "  **Review-Pause-Acknowledged:** \`$_w\` \`$_wr\`" >&2
    done
    exit 3
fi

echo "PR_ROUND_COUNT pr=$PR rounds=$rounds threshold=$THRESHOLD acknowledged=$ack pause=0"
exit 0
