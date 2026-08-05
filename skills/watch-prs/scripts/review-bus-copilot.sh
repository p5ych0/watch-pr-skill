#!/usr/bin/env bash
# review-bus-copilot.sh — optional GitHub Copilot review pass, driven by the
# watch-prs skill AFTER a clean Codex signoff. Subcommands:
#   available <PR>  best-effort probe Copilot review works here (0 yes, 2 unknown, 3 no)
#   request   <PR>  request/re-request a Copilot review for the current head
#                   (0 requested, 4 already-reviewed-head, 3 positively unavailable,
#                    2 transient/unknown failure → caller fails closed)
#   status    <PR>  one-shot, head-aware: has Copilot reviewed the CURRENT head?
#                   (0 commented+findings, 1 none, 2 error/fail-closed)
#   poll      <PR>  poll until Copilot reviews the current head, emit one
#                   COPILOT_REVIEW line (0), status=timeout (1), status=error (2)
#   gate      <PR>  MERGE GATE — may this PR merge as far as Copilot is concerned?
#                   (0 clean review on the current head, a decline recorded for
#                    it, or Copilot positively unavailable for it; 1 pass still
#                    owed; 2 cannot tell → caller fails closed)
#   decline   <PR>  record an operator decision to skip the pass for the CURRENT
#                   head (0 recorded, 2 could not record). Head-scoped: a later
#                   push re-opens the question rather than inheriting the waiver.
#
# Repo identity is derived from this checkout's origin (repo-agnostic), same as
# review-bus-request.sh. Sourcing with REVIEW_BUS_LIB_ONLY=1 exposes the helper
# functions without running main (unit tests). NOTE: set -uo pipefail WITHOUT -e
# on purpose — subcommands return meaningful exit codes and several gh probes
# "fail" as normal control flow, which -e would abort.
set -uo pipefail

COPILOT_BOT="copilot-pull-request-reviewer[bot]"
COPILOT_POLL_SECONDS="${CODEX_REVIEW_COPILOT_POLL_SECONDS:-15}"
COPILOT_TIMEOUT="${CODEX_REVIEW_COPILOT_TIMEOUT:-300}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)}"
REMOTE="${REVIEW_BUS_REMOTE:-$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)}"
if [ -n "$REMOTE" ]; then
    _p="${REMOTE%.git}"
    REPO="${REVIEW_BUS_REPO:-${_p##*/}}"
    _p="${_p%/*}"
    OWNER="${REVIEW_BUS_OWNER:-${_p##*[:/]}}"
else
    OWNER="${REVIEW_BUS_OWNER:-}"
    REPO="${REVIEW_BUS_REPO:-}"
fi
REPO_SLUG="$OWNER/$REPO"
# Same derivation as the watcher, so `gate`/`decline` read and write the markers
# in this project's own bus. Identity comes from origin — never hard-coded.
BUS_SLUG="$(printf '%s' "${OWNER:+${OWNER}-}${REPO}" | tr -c 'A-Za-z0-9._-' '-')"
BUS_DIR="${BUS_DIR:-/tmp/${BUS_SLUG:-review}-review-bus}"

# Prints Copilot's reviews on a PR (JSON array) and returns 0 on success.
# Returns 2 if the reviews endpoint cannot be fetched/parsed — callers MUST fail
# closed. (A swallowed failure that looked like "no reviews" could bypass an
# existing Copilot review with findings.) The fetch is split from the parse so a
# failed `gh api` is never masked by jq emitting `[]` on empty stdin.
copilot_reviews() {
    local pr="$1" raw
    if ! raw=$(gh api "repos/$REPO_SLUG/pulls/$pr/reviews" --paginate 2>/dev/null); then
        return 2
    fi
    # `jq -s` slurps the paginated stream into an ARRAY OF PAGES, and nothing
    # guaranteed each page is itself an array. `.[][]` over an object iterates its
    # VALUES, so a `{"message":"Not Found"}` page (a 200-with-error body, or a
    # truncated write) flowed through as data instead of failing. Reject any page
    # that is not an array before reading a single field.
    #
    # And the RECORDS matter as much as the containers: a successful `[{}]` page
    # passed the array check and produced `[]`, which every caller reads as "no
    # live review" - so with a matching unavailable marker the gate answered
    # `status=unavailable` off a payload that told us nothing. Each record must
    # carry the fields the callers go on to read.
    printf '%s' "$raw" | jq -s --arg bot "$COPILOT_BOT" '
        if length == 0 then error("no pages")
        elif any(.[]; type != "array") then error("non-array page")
        else [ .[][] ] as $all
          | if any($all[];
                   type != "object"
                   or (.user | type) != "object"
                   or (.user.login | type) != "string"
                   or (.id | type) != "number"
                   or (.commit_id | type) != "string"
                   or ((.state | type) != "string" and .state != null)
                   or ((.submitted_at | type) != "string" and .submitted_at != null))
            then error("malformed review record")
            else [ $all[] | select(.user.login==$bot) ]
            end
        end' 2>/dev/null || return 2
}


# Print "<state>\t<review-id>" for THIS head from ONE reviews fetch, or fail (2).
# The id is the authoritative latest submitted review the state was derived from,
# and is empty when there is none (states `none` and `pending`).
#
# state and id must come from the SAME snapshot: `head_review_state` and
# `head_review_findings` each fetched the list independently, so a review that
# changed between the two calls let the gate judge one snapshot and count another
# - a COMMENTED read followed by a DISMISSED one counted the withdrawn review's
# zero comments and returned clean. This result is merge permission, so it is
# derived once and re-checked before it is trusted.
head_review_snapshot() {
    local pr="$1" head="$2" reviews out
    reviews=$(copilot_reviews "$pr") || return 2
    out="$(printf '%s' "$reviews" | jq -r --arg h "$head" '
        if type != "array" then error("bad shape")
        else
          [ .[] | select(.commit_id == $h) ] as $mine
          | ( [ $mine[] | select(.submitted_at != null) ]
              | sort_by(.submitted_at) | last ) as $latest
          | ( if ($mine | length) == 0 then "none"
              elif any($mine[]; .state == "PENDING" or .submitted_at == null) then "pending"
              elif $latest == null then "dismissed"
              elif $latest.state == "CHANGES_REQUESTED" then "blocked"
              elif $latest.state == "APPROVED" or $latest.state == "COMMENTED" then "reviewed"
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

# Print the state of Copilot's review of THIS head, or fail (2).
#   pending  - an unsubmitted draft exists (review owed, not finished)
#   blocked  - a submitted review asks for changes
#   dismissed- the only submitted review on this head was dismissed (no signoff)
#   reviewed - an accepted submitted review exists (APPROVED / COMMENTED)
#   none     - no review on this head at all
#
# The gate used to collapse all of this into an inline-comment COUNT, which is
# not a verdict: `head_review_findings` discards PENDING records, so an older
# clean review plus a new same-head PENDING re-review read as clean and merged
# while that re-review was still running; and a DISMISSED or CHANGES_REQUESTED
# review with no inline comments read as clean too, because zero comments is what
# it counted. The state has to be derived from the review records themselves.
head_review_state() {
    local snap
    snap="$(head_review_snapshot "$1" "$2")" || return 2
    printf '%s' "${snap%%$'\t'*}"
}


# The gate's clean decision, derived and then RE-CHECKED.
#   0 = clean (prints the count) · 1 = not clean (prints the reason) · 2 = error
#
# A clean answer here is merge permission, so it is the one place that pays for a
# second look: the state and the review id come from one snapshot, the comments
# are counted for THAT id, and the snapshot is taken again afterwards. If it
# moved - a draft opened, the review was dismissed, a newer one landed - the
# count describes a review that is no longer authoritative and cannot authorise a
# merge.
clean_verdict() {
    local pr="$1" head="$2" snap1 snap2 st id n
    snap1="$(head_review_snapshot "$pr" "$head")" || return 2
    st="${snap1%%$'\t'*}"; id="${snap1#*$'\t'}"
    case "$st" in
        reviewed) ;;
        *) printf '%s' "$st"; return 1 ;;
    esac
    n="$(review_comment_count "$pr" "$id")" || return 2
    snap2="$(head_review_snapshot "$pr" "$head")" || return 2
    if [ "$snap2" != "$snap1" ]; then
        printf 'changed'
        return 1
    fi
    [ "$n" -eq 0 ] 2>/dev/null || { printf 'findings:%s' "$n"; return 1; }
    printf '0'
    return 0
}

# Is Copilot currently a REQUESTED reviewer on this PR?
#   0 = yes · 1 = no · 2 = cannot tell.
#
# This is the fact that outranks a recorded unavailability: a pending request
# exists only because `gh pr edit --add-reviewer` succeeded, which is proof
# Copilot is reachable here. The marker can survive a failed revocation (an
# unsearchable BUS_DIR at the moment we tried to remove it), so the gate must not
# treat it as cached permission - it re-derives from live state instead. A pure
# read, no side effect.
copilot_request_pending() {
    local pr="$1" raw out
    # RAW json, not a pre-flattened string. `.reviewRequests[]?` plus `join`
    # collapsed a missing field, a null, an object, and a zero-output call all
    # into the empty string, which then returned 1 = "no pending request" - so an
    # UNREADABLE probe handed the stale marker its merge permission. The field
    # must be an array, and every entry an object naming a reviewer; anything
    # else is 2.
    raw="$(gh pr view "$pr" --repo "$REPO_SLUG" --json reviewRequests 2>/dev/null)" || return 2
    [ -n "$raw" ] || return 2
    out="$(printf '%s' "$raw" | jq -r --arg bot "$COPILOT_BOT" '
        if (type != "object") or (has("reviewRequests") | not)
           or ((.reviewRequests | type) != "array") then error("bad shape")
        else
          if any(.reviewRequests[];
                 type != "object"
                 or (((.login // .name // .slug) | type) != "string")
                 or (((.login // .name // .slug) | test("\\S")) | not))
          then error("bad entry")
          else (if any(.reviewRequests[];
                       ((.login // .name // .slug) | ascii_downcase | test("copilot")))
                then "yes" else "no" end)
          end
        end' 2>/dev/null)" || return 2
    case "$out" in
        yes) return 0 ;;
        no)  return 1 ;;
        *)   return 2 ;;
    esac
}

revoke_unavailable() {
    local umark="$BUS_DIR/.copilot-unavailable-${1}"
    # No `[ -e ]` precondition: a test cannot tell an absent marker from a probe
    # that failed (an unsearchable BUS_DIR, a transient mount error). Reading
    # "false" as "nothing to revoke" reported success while the marker survived,
    # and once access recovered the gate honoured it as `status=unavailable`
    # while the requested review was still pending. `rm -f` is already a no-op on
    # an absent file, so attempt it unconditionally and trust its status.
    rm -f "$umark" 2>/dev/null || return 1
    # And confirm the removal: `rm -f` succeeds on an unlink it never had to do,
    # so the post-condition is what proves the marker is gone. An existence probe
    # that itself fails leaves the file readable as present, which is the
    # fail-closed direction here.
    [ -e "$umark" ] && return 1
    return 0
}

# 0 available (a prior Copilot review exists here) · 2 unknown → ASK.
# An empty search only proves this repo has no PRIOR Copilot reviews, NOT that
# Copilot is unavailable — so an empty or errored search returns 2 (ask), never a
# "skip Copilot" signal. Real unavailability is discovered by `request` (exit 3)
# when `gh pr edit --add-reviewer @copilot` actually fails.
cmd_available() {
    local pr="$1" reviews n hits
    if reviews=$(copilot_reviews "$pr"); then
        n=$(printf '%s' "$reviews" | jq 'length' 2>/dev/null || echo 0)
        [ "${n:-0}" -gt 0 ] 2>/dev/null && return 0   # a prior Copilot review on this PR
    fi
    if hits=$(gh search prs --repo "$REPO_SLUG" --reviewed-by "$COPILOT_BOT" \
                 --limit 1 --json number 2>/dev/null) \
       && [ "$(printf '%s' "$hits" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
        return 0   # a prior Copilot review on this repo — definitely available
    fi
    return 2       # no evidence either way → ASK (empty search ≠ unavailable)
}

# Read a marker that must hold exactly one 40-hex SHA. Prints it, or fails.
#
# Deliberately NOT `tr -cd '0-9a-f'`: that REPAIRS corrupt content instead of
# rejecting it - a marker containing `x<40-hex>x` would sanitise to a
# valid-looking SHA, so damaged state could satisfy the merge gate without any
# decline or unavailability having been recorded.
read_sha_marker() {
    local f="$1" v sz
    [ -f "$f" ] || return 1
    # The RAW BYTES are validated first, before any command substitution sees
    # them. `$( )` silently DROPS NUL, so a marker of `<40-hex>\0` arrived here as
    # a clean 40-character SHA and satisfied the exact-contents contract the merge
    # gate depends on - the same class of hole as the earlier newline truncation,
    # one layer down. Size plus an anchored line match rejects any trailing byte,
    # NUL included: 40 bytes bare, or 41 with a trailing newline, and nothing else.
    sz="$(wc -c < "$f" 2>/dev/null)" || return 1
    case "$sz" in
        40|41) ;;
        *) return 1 ;;
    esac
    LC_ALL=C grep -qaxE '[0-9a-f]{40}' "$f" 2>/dev/null || return 1
    v="$(cat "$f" 2>/dev/null)" || return 1
    case "$v" in
        *[!0-9a-f]*|"") return 1 ;;
    esac
    [ "${#v}" -eq 40 ] || return 1
    printf '%s' "$v"
}

# 40-hex head OID of a PR. Prints nothing and returns non-zero on failure.
#
# `|| true` used to preserve whatever stdout `gh` had emitted BEFORE exiting
# non-zero, so a call that printed a plausible SHA and then failed was
# indistinguishable from success — and with a matching decline/unavailable marker
# the merge gate returned 0 instead of its documented fail-closed 2. Capture,
# check the status, and validate the shape before handing anything back.
pr_head_oid() {
    local out
    out="$(gh pr view "$1" --repo "$REPO_SLUG" --json headRefOid --jq '.headRefOid' 2>/dev/null)" || return 1
    case "$out" in
        *[!0-9a-f]*|"") return 1 ;;
    esac
    [ "${#out}" -eq 40 ] || return 1
    printf '%s' "$out"
}

# 0 requested · 4 already-reviewed-current-head · 3 unavailable
cmd_request() {
    local pr="$1" head reviews reviewed_head
    head=$(pr_head_oid "$pr") || head=""
    if [ -z "$head" ]; then   # head lookup failed (transient) → fail closed, not "unavailable"
        echo "COPILOT_REQUEST pr=$pr status=error detail=head_unresolved" >&2; return 2
    fi
    local reviews_rc=0
    reviews=$(copilot_reviews "$pr") || reviews_rc=$?
    # "Already reviewed the current head" means a SUBMITTED review on it — a
    # PENDING draft is not a completed review, so it must not suppress a request.
    # A DISMISSED review is NOT "already reviewed": dismissal is what removes the
    # signoff, so treating it as one left the state with no way out - the gate
    # blocked, and re-running `request` answered rc 4 forever. Ask the state
    # machine, which judges the latest submitted review, instead of "any submitted
    # review exists".
    local head_state=""
    head_state="$(head_review_state "$pr" "$head")" || head_state=""
    case "$head_state" in
        reviewed|blocked) reviewed_head=true ;;
        *)                reviewed_head=false ;;
    esac
    if [ "$reviewed_head" = "true" ]; then
        # A submitted review ON THIS HEAD is proof of availability, and this exit
        # is taken BEFORE the `gh pr edit` that used to own the revocation - so
        # without this the marker survived, and the gate answered
        # `status=unavailable` (merge) from it instead of reading that very
        # review, whose findings it never looked at.
        if ! revoke_unavailable "$pr"; then
            echo "COPILOT_REQUEST pr=$pr status=error sha=${head:0:7} detail=stale_unavailable_marker_not_revoked" >&2
            return 2
        fi
        echo "COPILOT_REQUEST pr=$pr status=already_reviewed_head sha=${head:0:7}"
        return 4
    fi
    # First request and re-request both use the native @copilot handle. Re-review
    # reliability is the key runtime risk; the poll timeout (cmd_poll) is the
    # escape hatch and GraphQL botIds is the documented fallback if a re-review
    # stalls in practice. Capture stderr to distinguish a POSITIVELY-unavailable
    # Copilot (not a valid reviewer / not enabled → 3, caller merges on Codex)
    # from a transient/unknown failure (2 — caller MUST fail closed, never
    # silently skip the Copilot pass the user opted into).
    local err
    if err=$(gh pr edit "$pr" --repo "$REPO_SLUG" --add-reviewer "@copilot" 2>&1); then
        if ! revoke_unavailable "$pr"; then
            echo "COPILOT_REQUEST pr=$pr status=error sha=${head:0:7} detail=stale_unavailable_marker_not_revoked" >&2
            return 2
        fi
        echo "COPILOT_REQUEST pr=$pr status=requested sha=${head:0:7}"
        return 0
    fi
    if printf '%s' "$err" | grep -qiE 'not a collaborator|could not resolve to a user|reviews may only be requested|no such (user|reviewer)|not a valid reviewer'; then
        # Record it HEAD-SCOPED so `gate` has a legitimate success state for this
        # path. Without the marker the documented flow was unreachable: the skill
        # says to merge on the Codex signoff when Copilot is positively
        # unavailable, but no review and no decline exist, so the gate returned 1
        # and the merge always aborted. Head-scoped like a decline, because
        # availability is a fact about this repo now, not a permanent waiver.
        # Only record unavailability if we could actually READ the review state.
        # The marker short-circuits the gate ahead of any live lookup, so writing
        # one off a failed fetch asserts "Copilot has done nothing here" on the
        # strength of a question we never got an answer to - and a real review on
        # this head, findings and all, would then be skipped. Without the marker
        # the gate falls through to the live lookup and fails closed on its own.
        if [ "$reviews_rc" -ne 0 ]; then
            echo "COPILOT_REQUEST pr=$pr status=unavailable sha=${head:0:7} warn=reviews_unreadable_marker_not_recorded" >&2
            return 3
        fi
        local marker="$BUS_DIR/.copilot-unavailable-${pr}"
        mkdir -p "$BUS_DIR" 2>/dev/null
        if ! printf '%s\n' "$head" > "${marker}.tmp" 2>/dev/null || ! mv "${marker}.tmp" "$marker" 2>/dev/null; then
            rm -f "${marker}.tmp" 2>/dev/null
            echo "COPILOT_REQUEST pr=$pr status=unavailable sha=${head:0:7} warn=marker_write_failed" >&2
            return 3
        fi
        echo "COPILOT_REQUEST pr=$pr status=unavailable sha=${head:0:7} recorded=1" >&2
        return 3
    fi
    echo "COPILOT_REQUEST pr=$pr status=error sha=${head:0:7} detail=$(printf '%s' "$err" | tr '\n' ' ' | cut -c1-160)" >&2
    return 2
}

# Findings count of Copilot's review on a specific head SHA.
#   prints count + returns 0 → a review for $head exists;
#   returns 1           → NO Copilot review for $head (keep polling / status=none);
#   returns 2           → review found but its comments could NOT be fetched/parsed.
# Callers MUST fail closed on 2 — never treat a fetch failure as findings=0/clean.
# (The count fetch is split from the parse so a failed `gh api` cannot be masked
# by jq printing 0 on empty stdin.)
head_review_findings() {
    local pr="$1" head="$2" reviews found raw n
    reviews=$(copilot_reviews "$pr") || return 2   # reviews endpoint untrusted → fail closed
    # Only a SUBMITTED (non-PENDING, has submitted_at) review counts, and among
    # several on the same head take the LATEST by submitted_at — a PENDING draft
    # must not read as findings=0, and a same-SHA re-review must not leave us
    # counting the older review's comments.
    # `|| true` here masked the selector's own status, and command substitution
    # keeps what jq printed before failing - so a selector that emitted a review
    # ID and then died left that ID in place, and an empty comments page turned it
    # into findings=0, i.e. a clean signoff off a read that failed.
    found=$(printf '%s' "$reviews" | jq -r --arg h "$head" \
        '[.[] | select(.commit_id==$h and .state!="PENDING" and .submitted_at!=null)] | sort_by(.submitted_at) | last | .id // empty' 2>/dev/null) || return 2
    [ -n "$found" ] || return 1
    case "$found" in
        *[!0-9]*) return 2 ;;   # an id is a number; anything else is a failed read
    esac
    if ! raw=$(gh api "repos/$REPO_SLUG/pulls/$pr/reviews/$found/comments" --paginate 2>/dev/null); then
        return 2
    fi
    # Same page-shape trap, and here it is a merge-gate input: a successful
    # response whose page is `{}` made `[.[][]] | length` return 0 with status 0,
    # so a real current-head review plus one malformed page reported findings=0
    # and the gate reported `status=clean`. Any non-array page fails closed (2).
    # `jq -s` turns empty or whitespace-only input into ZERO pages, and
    # `any([]; ...)` is false - so a comments command that exited 0 emitting no
    # JSON slipped through the array guard and returned a count of 0, which the
    # gate reads as a clean signoff. No pages is not "no comments"; it is a fetch
    # that told us nothing.
    n=$(printf '%s' "$raw" | jq -s '
        if length == 0 then error("no pages")
        elif any(.[]; type != "array") then error("non-array page")
        else [.[][]] | length end' 2>/dev/null) || return 2
    case "$n" in
        ""|*[!0-9]*) return 2 ;;
    esac
    printf '%s' "$n"
    return 0
}

# One-shot, head-aware check (no wait): has Copilot reviewed the CURRENT head?
#   0 → yes (status=commented, findings=K) · 1 → no review for this head
#   (status=none) · 2 → found but comment fetch failed (status=error, fail closed).
cmd_status() {
    local pr="$1" head short findings rc state
    head=$(pr_head_oid "$pr") || head=""
    if [ -z "$head" ]; then   # head lookup failed (transient) → fail closed, not "none"
        echo "COPILOT_REVIEW pr=$pr sha=unknown findings=0 status=error reviewer=copilot"; return 2
    fi
    short="${head:0:7}"
    # STATE first, like the gate. Reducing this to a comment count reported a
    # zero-comment DISMISSED review as `status=commented findings=0` (rc 0), which
    # sends the driver toward a merge the gate then refuses - with no signal
    # anywhere that the way out is to request Copilot again.
    if ! state="$(head_review_state "$pr" "$head")"; then
        echo "COPILOT_REVIEW pr=$pr sha=$short findings=0 status=error reviewer=copilot"; return 2
    fi
    case "$state" in
        none)      echo "COPILOT_REVIEW pr=$pr sha=$short findings=0 status=none reviewer=copilot"; return 1 ;;
        pending)   echo "COPILOT_REVIEW pr=$pr sha=$short findings=0 status=none reason=review_in_progress reviewer=copilot"; return 1 ;;
        dismissed) echo "COPILOT_REVIEW pr=$pr sha=$short findings=0 status=none reason=review_dismissed reviewer=copilot"; return 1 ;;
        blocked)   echo "COPILOT_REVIEW pr=$pr sha=$short findings=0 status=commented reason=changes_requested reviewer=copilot"; return 0 ;;
    esac
    findings=$(head_review_findings "$pr" "$head"); rc=$?
    case "$rc" in
        0) echo "COPILOT_REVIEW pr=$pr sha=$short findings=${findings:-0} status=commented reviewer=copilot"; return 0 ;;
        2) echo "COPILOT_REVIEW pr=$pr sha=$short findings=0 status=error reviewer=copilot"; return 2 ;;
        *) echo "COPILOT_REVIEW pr=$pr sha=$short findings=0 status=none reviewer=copilot"; return 1 ;;
    esac
}

# Poll until Copilot reviews the current head, then emit one COPILOT_REVIEW line.
#   0 = found · 1 = timed out · 2 = review found but comment fetch failed (fail closed).
cmd_poll() {
    local pr="$1" waited=0 head short findings rc
    head=$(pr_head_oid "$pr") || head=""
    if [ -z "$head" ]; then   # head lookup failed (transient) → fail closed, not "timeout"
        echo "COPILOT_REVIEW pr=$pr sha=unknown findings=0 status=error reviewer=copilot"; return 2
    fi
    short="${head:0:7}"
    # Each iteration branches on STATE. Polling a bare comment count reported the
    # OLD record the moment `request` re-requested a dismissed review - the
    # DISMISSED review is still submitted, so the count was 0 and the poll
    # returned `status=commented findings=0` instead of waiting for the
    # replacement. The same path misread a zero-comment CHANGES_REQUESTED review,
    # and an older clean review sitting beside a PENDING re-review.
    local pstate
    while [ "$waited" -lt "$COPILOT_TIMEOUT" ]; do
        if ! pstate="$(head_review_state "$pr" "$head")"; then
            echo "COPILOT_REVIEW pr=$pr sha=$short findings=0 status=error reviewer=copilot"
            return 2
        fi
        case "$pstate" in
            reviewed)
                findings=$(head_review_findings "$pr" "$head"); rc=$?
                if [ "$rc" -eq 0 ]; then
                    echo "COPILOT_REVIEW pr=$pr sha=$short findings=${findings:-0} status=commented reviewer=copilot"
                    return 0
                elif [ "$rc" -eq 2 ]; then
                    echo "COPILOT_REVIEW pr=$pr sha=$short findings=0 status=error reviewer=copilot"
                    return 2
                fi ;;
            blocked)
                echo "COPILOT_REVIEW pr=$pr sha=$short findings=0 status=commented reason=changes_requested reviewer=copilot"
                return 0 ;;
        esac
        # none / pending / dismissed: the review we are waiting for has not
        # arrived yet, so keep waiting rather than reporting the stale one.
        sleep "$COPILOT_POLL_SECONDS"
        waited=$((waited + COPILOT_POLL_SECONDS))
    done
    echo "COPILOT_REVIEW pr=$pr sha=$short findings=0 status=timeout reviewer=copilot"
    return 1
}

# Record an operator decision to SKIP the Copilot pass. Head-scoped on purpose:
# a decline is a judgement about the code as it stood, so a later push must
# re-open the question rather than inherit the waiver — otherwise declining once
# would silently authorise merging everything pushed afterwards.
#   0 recorded · 2 could not record (caller fails closed)
cmd_decline() {
    local pr="$1" head marker
    head=$(pr_head_oid "$pr") || head=""
    if [ -z "$head" ]; then
        echo "COPILOT_DECLINE pr=$pr sha=unknown status=error reason=head_lookup_failed"
        return 2
    fi
    marker="$BUS_DIR/.copilot-declined-${pr}"
    mkdir -p "$BUS_DIR" 2>/dev/null
    if ! printf '%s\n' "$head" > "${marker}.tmp" 2>/dev/null || ! mv "${marker}.tmp" "$marker" 2>/dev/null; then
        rm -f "${marker}.tmp" 2>/dev/null
        echo "COPILOT_DECLINE pr=$pr sha=${head:0:7} status=error reason=write_failed"
        return 2
    fi
    echo "COPILOT_DECLINE pr=$pr sha=${head:0:7} status=recorded"
    return 0
}

# Merge gate for the Copilot pass. The skill's merge block must pass this, so
# skipping Copilot becomes an explicit recorded act (`decline`) instead of
# something a session can do by simply not asking.
#
# Unresolved Copilot THREADS are not re-checked here: the caller's merge gate
# already refuses to merge with any unresolved thread, whatever its author.
#   0 may merge (clean review on this head, or a decline for this head)
#   1 Copilot pass still owed
#   2 cannot tell — caller MUST fail closed
cmd_gate() {
    local pr="$1" head short findings rc marker recorded
    head=$(pr_head_oid "$pr") || head=""
    if [ -z "$head" ]; then
        echo "COPILOT_GATE pr=$pr sha=unknown status=error reason=head_lookup_failed"
        return 2
    fi
    short="${head:0:7}"

    # A marker is a statement about the PAST, and it used to short-circuit the
    # gate ahead of any live lookup. But a review can reach this head without
    # `cmd_request` ever running - Copilot picking the PR up itself, a human
    # re-requesting, an automation - so a marker plus a current-head review
    # carrying findings returned "may merge" without that review ever being read.
    # Consult the live state FIRST; a failure to read it blocks rather than
    # falling back on the marker.
    local live_state
    if [ -f "$BUS_DIR/.copilot-unavailable-${pr}" ] || [ -f "$BUS_DIR/.copilot-declined-${pr}" ]; then
        # The SAME state machine the unmarked path uses. Deciding this branch on a
        # bare comment count re-introduced, on the marker path only, exactly what
        # the state check exists to close: an old zero-comment review beside a new
        # draft, and zero-comment DISMISSED or CHANGES_REQUESTED reviews, all read
        # as clean. Any live review at all also proves the marker stale, so each
        # branch revokes best-effort before answering.
        if ! live_state="$(head_review_state "$pr" "$head")"; then
            echo "COPILOT_GATE pr=$pr sha=$short status=error reason=live_review_state_unreadable"
            return 2
        fi
        case "$live_state" in
            pending)
                revoke_unavailable "$pr" || true
                echo "COPILOT_GATE pr=$pr sha=$short status=none reason=stale_unavailable_review_pending"
                return 1 ;;
            blocked)
                revoke_unavailable "$pr" || true
                echo "COPILOT_GATE pr=$pr sha=$short status=findings reason=changes_requested source=live_review_overrides_marker"
                return 1 ;;
            dismissed)
                revoke_unavailable "$pr" || true
                echo "COPILOT_GATE pr=$pr sha=$short status=none reason=review_dismissed source=live_review_overrides_marker"
                return 1 ;;
            reviewed)
                revoke_unavailable "$pr" || true
                local mverdict mrc=0
                mverdict="$(clean_verdict "$pr" "$head")" || mrc=$?
                case "$mrc" in
                    0) echo "COPILOT_GATE pr=$pr sha=$short status=clean findings=0 source=live_review"
                       return 0 ;;
                    2) echo "COPILOT_GATE pr=$pr sha=$short status=error reason=live_review_state_unreadable"
                       return 2 ;;
                esac
                case "$mverdict" in
                    changed)    echo "COPILOT_GATE pr=$pr sha=$short status=none reason=review_state_changed"; return 1 ;;
                    findings:*) echo "COPILOT_GATE pr=$pr sha=$short status=findings findings=${mverdict#findings:} source=live_review_overrides_marker"; return 1 ;;
                    *)          echo "COPILOT_GATE pr=$pr sha=$short status=none reason=$mverdict source=live_review_overrides_marker"; return 1 ;;
                esac ;;
        esac
        # `none` = no review on this head at all; the markers may speak.
    fi

    # Copilot positively unavailable for THIS head, recorded by `request` rc 3.
    #
    # Re-derived, not trusted. The marker is the one PERMISSIVE piece of state
    # here, and it can outlive its truth: if the bus directory was briefly
    # unsearchable when a successful request tried to revoke it, the request
    # correctly failed closed but the marker survived - and honouring it later
    # would merge while the requested review was still pending. A pending request
    # is proof the marker is stale, so check for one first, and fail closed when
    # that check cannot be made.
    marker="$BUS_DIR/.copilot-unavailable-${pr}"
    if [ -f "$marker" ] && [ "$(read_sha_marker "$marker" || true)" = "$head" ]; then
        # A current-head draft was handled by the state machine above, which runs
        # for every marker; what remains here is the case with NO review at all.
        local pending_rc=0
        copilot_request_pending "$pr" || pending_rc=$?
        case "$pending_rc" in
            0)  revoke_unavailable "$pr" || true   # best effort; the verdict below does not depend on it
                echo "COPILOT_GATE pr=$pr sha=$short status=none reason=stale_unavailable_request_pending"
                return 1 ;;
            2)  echo "COPILOT_GATE pr=$pr sha=$short status=error reason=request_state_unreadable"
                return 2 ;;
        esac
        echo "COPILOT_GATE pr=$pr sha=$short status=unavailable"
        return 0
    fi

    marker="$BUS_DIR/.copilot-declined-${pr}"
    if [ -f "$marker" ]; then
        recorded="$(read_sha_marker "$marker" || true)"
        if [ "$recorded" = "$head" ]; then
            echo "COPILOT_GATE pr=$pr sha=$short status=declined"
            return 0
        fi
        echo "COPILOT_GATE pr=$pr sha=$short status=decline_stale recorded=${recorded:0:7}"
    fi

    # ONE decision, from clean_verdict: it derives the state and the authoritative
    # review id from a single snapshot, counts that review's comments, and re-reads
    # the snapshot before calling anything clean. A separate `head_review_state`
    # call here would be a THIRD fetch and a second source of truth - which is how
    # the state and the count came from different snapshots in the first place.
    local verdict vrc=0
    verdict="$(clean_verdict "$pr" "$head")" || vrc=$?
    case "$vrc" in
        0) echo "COPILOT_GATE pr=$pr sha=$short status=clean findings=0"; return 0 ;;
        2) echo "COPILOT_GATE pr=$pr sha=$short status=error reason=fetch_failed"; return 2 ;;
    esac
    case "$verdict" in
        none)        echo "COPILOT_GATE pr=$pr sha=$short status=none"; return 1 ;;
        pending)     echo "COPILOT_GATE pr=$pr sha=$short status=none reason=review_in_progress"; return 1 ;;
        dismissed)   echo "COPILOT_GATE pr=$pr sha=$short status=none reason=review_dismissed"; return 1 ;;
        blocked)     echo "COPILOT_GATE pr=$pr sha=$short status=findings reason=changes_requested"; return 1 ;;
        changed)     echo "COPILOT_GATE pr=$pr sha=$short status=none reason=review_state_changed"; return 1 ;;
        findings:*)  echo "COPILOT_GATE pr=$pr sha=$short status=findings findings=${verdict#findings:}"; return 1 ;;
        *)           echo "COPILOT_GATE pr=$pr sha=$short status=error reason=unexpected_verdict"; return 2 ;;
    esac
}

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        available) cmd_available "$@" ;;
        request)   cmd_request "$@" ;;
        status)    cmd_status "$@" ;;
        poll)      cmd_poll "$@" ;;
        gate)      cmd_gate "$@" ;;
        decline)   cmd_decline "$@" ;;
        --help|-h|"") sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "ERR: unknown subcommand: $sub" >&2; exit 64 ;;
    esac
}

if [ "${REVIEW_BUS_LIB_ONLY:-0}" != "1" ]; then
    main "$@"
fi
