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
    echo "PR_ROUND_COUNT status=error reason=no_origin" >&2
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
# The TRANSPORT is checked, not only the authority. `file://github.com/srv/acme/widget.git`
# is a file-transport remote that carries an authority, so parsing it as a URL
# yielded HOST=github.com while the path split yielded `acme/widget` — the same
# wrong-public-repository outcome as a bare local path, reached through the arm
# that was supposed to be the safe one. Only transports that actually reach a
# GitHub server are accepted; anything else names no reviewable identity.
case "$REMOTE" in
    ssh://*|git://*|https://*|http://*|git+ssh://*)
            _h="${REMOTE#*://}"; _h="${_h#*@}"; HOST="${_h%%[:/]*}" ;;
    *://*)
        echo "PR_ROUND_COUNT status=error reason=origin_transport_unsupported remote=$REMOTE" >&2
        exit 2 ;;
    *@*:*)  _h="${REMOTE#*@}";   HOST="${_h%%:*}" ;;
    /*|.*|~*)
        echo "PR_ROUND_COUNT status=error reason=origin_has_no_host remote=$REMOTE" >&2
        exit 2 ;;
    *:*/*)  HOST="${REMOTE%%:*}" ;;
    *)
        echo "PR_ROUND_COUNT status=error reason=origin_has_no_host remote=$REMOTE" >&2
        exit 2 ;;
esac
case "$HOST" in
    ""|*/*|*:*) echo "PR_ROUND_COUNT status=error reason=origin_host_unparseable remote=$REMOTE" >&2; exit 2 ;;
esac
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
rounds=$(printf '%s' "$raw" | jq -s --argjson who "$WHO_JSON" '
    if length == 0 then error("no pages")
    elif any(.[]; type != "array") then error("non-array page")
    else [ .[][] ] as $all
      | if any($all[];
               type != "object"
               or (.user | type) != "object"
               or (.user.login | type) != "string"
               or (.commit_id | type) != "string"
               # A blank or non-SHA commit_id counted as its own "distinct head",
               # which can turn a true boundary of 10 into 11 and skip the pause.
               or (.commit_id | test("^[0-9a-f]{40}$") | not)
               # `state` decides whether a record is a finished pass, so it is
               # validated rather than ignored. A null or unrecognised state was
               # counted as a reviewed head on the strength of `submitted_at`
               # alone — one such record on a distinct full SHA turns a true
               # boundary of 10 into 11 and skips the operator pause. The known
               # set is the one pr-review-state.sh judges against, so the two
               # scripts cannot disagree about what a review is.
               or (.state | IN("PENDING","APPROVED","CHANGES_REQUESTED","COMMENTED","DISMISSED") | not)
               or ((.submitted_at | type) != "string" and .submitted_at != null)
               # `submitted_at != null` is what makes a record COUNT as a
               # submitted review below, so any old string satisfied it. A
               # malformed page carrying one extra matching-reviewer record with
               # `submitted_at:"zzzz"` and a full-SHA commit_id was counted as
               # another distinct reviewed head — and at a real 10-round boundary
               # that inflates `rounds` to 11, which is exactly the direction that
               # SKIPS the operator pause. Same anchored ISO test as
               # pr-review-state.sh, for the same reason: unreadable must not
               # read as one more round.
               or (.submitted_at != null
                   and (.submitted_at
                        | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
                        | not)))
        then error("malformed review record")
        # A round is a FINISHED pass. `PENDING` is a draft in flight — the same
        # thing pr-review-state.sh refuses to read as a signoff — so it is not a
        # round however its `submitted_at` reads.
        else [ $all[]
               | select((.user.login | IN($who[]))
                        and .submitted_at != null
                        and .state != "PENDING")
               | .commit_id ] | unique
        end
    end' 2>/dev/null) || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=unreadable"
    exit 2
}
# The clean-pass heads, as 10-char prefixes — that is all the comment carries.
# A prefix already covered by a counted review head is not a second round, so the
# union is taken on prefixes rather than on the two different shapes.
clean_shas=$(printf '%s' "$icraw" | jq -s --argjson who "$WHO_JSON" '
    if length == 0 then error("no pages")
    elif any(.[]; type != "array") then error("non-array page")
    else [ .[][] ] as $all
      | if any($all[];
               type != "object"
               or (.user | type) != "object"
               or (.user.login | type) != "string"
               or ((.body | type) != "string" and .body != null))
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
        end
    end' 2>/dev/null) || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=comments_unreadable"
    exit 2
}

rounds=$(jq -n --argjson r "$rounds" --argjson c "$clean_shas" '
    ($r | map(.[0:10])) as $rp
    | ($rp + ($c | map(.[0:10]))) | unique | length' 2>/dev/null) || {
    echo "PR_ROUND_COUNT pr=$PR status=error reason=count_unreadable"
    exit 2
}

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
#     **Review-Pause-Acknowledged:** `41`
#
# WHO may write it is part of the rule. Anyone can comment on a pull request, so
# an unrestricted marker would let a reviewer bot — or a passer-by — disable the
# operator pause permanently by naming a large number. Only OWNER, MEMBER and
# COLLABORATOR comments are read, which is the same "a finding is waived only by
# an authority, never by the PR" line the review contract already draws.
ack=$(printf '%s' "$icraw" | jq -s -r '
    if length == 0 then error("no pages")
    elif any(.[]; type != "array") then error("non-array page")
    else [ .[][] ] as $all
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
               | (.body | [scan("(?m)^\\*\\*Review-Pause-Acknowledged:\\*\\* `([0-9]{1,9})`")]
                        | last // [""] | .[0])
             ] | map(select(. != "")) | map(tonumber) | max // 0
        end
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
    echo "To continue, post a comment containing: **Review-Pause-Acknowledged:** \`$rounds\`" >&2
    exit 3
fi

echo "PR_ROUND_COUNT pr=$PR rounds=$rounds threshold=$THRESHOLD acknowledged=$ack pause=0"
exit 0
