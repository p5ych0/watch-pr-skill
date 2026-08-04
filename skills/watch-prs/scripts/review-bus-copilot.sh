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
    printf '%s' "$raw" | jq -s --arg bot "$COPILOT_BOT" '[.[][] | select(.user.login==$bot)]' 2>/dev/null || return 2
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

# 40-hex head OID of a PR (empty on failure).
pr_head_oid() {
    gh pr view "$1" --repo "$REPO_SLUG" --json headRefOid --jq '.headRefOid' 2>/dev/null || true
}

# 0 requested · 4 already-reviewed-current-head · 3 unavailable
cmd_request() {
    local pr="$1" head reviews reviewed_head
    head=$(pr_head_oid "$pr")
    if [ -z "$head" ]; then   # head lookup failed (transient) → fail closed, not "unavailable"
        echo "COPILOT_REQUEST pr=$pr status=error detail=head_unresolved" >&2; return 2
    fi
    reviews=$(copilot_reviews "$pr")
    # "Already reviewed the current head" means a SUBMITTED review on it — a
    # PENDING draft is not a completed review, so it must not suppress a request.
    reviewed_head=$(printf '%s' "$reviews" | jq -r --arg h "$head" \
        'any(.[]; .commit_id==$h and .state!="PENDING" and .submitted_at!=null)' 2>/dev/null || echo false)
    if [ "$reviewed_head" = "true" ]; then
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
    found=$(printf '%s' "$reviews" | jq -r --arg h "$head" \
        '[.[] | select(.commit_id==$h and .state!="PENDING" and .submitted_at!=null)] | sort_by(.submitted_at) | last | .id // empty' 2>/dev/null || true)
    [ -n "$found" ] || return 1
    if ! raw=$(gh api "repos/$REPO_SLUG/pulls/$pr/reviews/$found/comments" --paginate 2>/dev/null); then
        return 2
    fi
    n=$(printf '%s' "$raw" | jq -s '[.[][]] | length' 2>/dev/null) || return 2
    printf '%s' "$n"
    return 0
}

# One-shot, head-aware check (no wait): has Copilot reviewed the CURRENT head?
#   0 → yes (status=commented, findings=K) · 1 → no review for this head
#   (status=none) · 2 → found but comment fetch failed (status=error, fail closed).
cmd_status() {
    local pr="$1" head short findings rc
    head=$(pr_head_oid "$pr")
    if [ -z "$head" ]; then   # head lookup failed (transient) → fail closed, not "none"
        echo "COPILOT_REVIEW pr=$pr sha=unknown findings=0 status=error reviewer=copilot"; return 2
    fi
    short="${head:0:7}"
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
    head=$(pr_head_oid "$pr")
    if [ -z "$head" ]; then   # head lookup failed (transient) → fail closed, not "timeout"
        echo "COPILOT_REVIEW pr=$pr sha=unknown findings=0 status=error reviewer=copilot"; return 2
    fi
    short="${head:0:7}"
    while [ "$waited" -lt "$COPILOT_TIMEOUT" ]; do
        findings=$(head_review_findings "$pr" "$head"); rc=$?
        if [ "$rc" -eq 0 ]; then
            echo "COPILOT_REVIEW pr=$pr sha=$short findings=${findings:-0} status=commented reviewer=copilot"
            return 0
        elif [ "$rc" -eq 2 ]; then
            echo "COPILOT_REVIEW pr=$pr sha=$short findings=0 status=error reviewer=copilot"
            return 2
        fi
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
    head=$(pr_head_oid "$pr")
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
    head=$(pr_head_oid "$pr")
    if [ -z "$head" ]; then
        echo "COPILOT_GATE pr=$pr sha=unknown status=error reason=head_lookup_failed"
        return 2
    fi
    short="${head:0:7}"

    # Copilot positively unavailable for THIS head, recorded by `request` rc 3.
    marker="$BUS_DIR/.copilot-unavailable-${pr}"
    if [ -f "$marker" ] && [ "$(tr -cd '0-9a-f' < "$marker" 2>/dev/null)" = "$head" ]; then
        echo "COPILOT_GATE pr=$pr sha=$short status=unavailable"
        return 0
    fi

    marker="$BUS_DIR/.copilot-declined-${pr}"
    if [ -f "$marker" ]; then
        recorded="$(tr -cd '0-9a-f' < "$marker" 2>/dev/null)"
        if [ "$recorded" = "$head" ]; then
            echo "COPILOT_GATE pr=$pr sha=$short status=declined"
            return 0
        fi
        echo "COPILOT_GATE pr=$pr sha=$short status=decline_stale recorded=${recorded:0:7}"
    fi

    findings=$(head_review_findings "$pr" "$head"); rc=$?
    case "$rc" in
        0)  if [ "${findings:-1}" -eq 0 ] 2>/dev/null; then
                echo "COPILOT_GATE pr=$pr sha=$short status=clean findings=0"
                return 0
            fi
            echo "COPILOT_GATE pr=$pr sha=$short status=findings findings=$findings"
            return 1 ;;
        2)  echo "COPILOT_GATE pr=$pr sha=$short status=error reason=fetch_failed"
            return 2 ;;
        *)  echo "COPILOT_GATE pr=$pr sha=$short status=none"
            return 1 ;;
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
