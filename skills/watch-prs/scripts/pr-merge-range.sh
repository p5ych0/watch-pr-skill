#!/usr/bin/env -S bash -p
# A last-resort refusal: `$-` proves the mode, not how the shell got there.
if [[ $- != *p* ]]; then
    echo "MERGE_RANGE status=error reason=not_privileged" >&2
    exit 2
fi

# No `-e`: statuses are control flow here.
set -uo pipefail

REVIEWED="${1:-}"
HEAD_OID="${2:-}"
# A root the caller names has no status to take; a derived one does.
if [ -n "${3:-}" ]; then
    REPO_DIR="$3"
else
    REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "PR_MERGE_RANGE status=error reason=repo_root_lookup_failed" >&2
        exit 2
    }
fi

if [ -z "$REVIEWED" ] || [ -z "$HEAD_OID" ] || [ -z "$REPO_DIR" ]; then
    echo "MERGE_RANGE status=error reason=usage" >&2
    exit 2
fi

for ref in "$REVIEWED" "$HEAD_OID"; do
    if ! git -C "$REPO_DIR" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1; then
        echo "MERGE_RANGE status=error reason=unresolved_ref ref=${ref}" >&2
        exit 2
    fi
done

# Ancestry first: after a force-push a commit count says nothing about reachability.
if ! git -C "$REPO_DIR" merge-base --is-ancestor "$REVIEWED" "$HEAD_OID" 2>/dev/null; then
    echo "MERGE_RANGE status=blocked reason=not_an_ancestor reviewed=${REVIEWED:0:7} head=${HEAD_OID:0:7}"
    exit 1
fi

if ! TOTAL="$(git -C "$REPO_DIR" rev-list --count "${REVIEWED}..${HEAD_OID}" 2>/dev/null)"; then
    echo "MERGE_RANGE status=error reason=rev_list_failed" >&2
    exit 2
fi
if ! [[ "$TOTAL" =~ ^[0-9]+$ ]]; then
    echo "MERGE_RANGE status=error reason=bad_count value=${TOTAL}" >&2
    exit 2
fi

if [ "$TOTAL" -eq 0 ]; then
    echo "MERGE_RANGE status=ok commits=0"
    exit 0
fi

if ! TRAILERS="$(git -C "$REPO_DIR" log --format='%(trailers:key=Review-Phase,valueonly,separator=%x2C)' \
                     "${REVIEWED}..${HEAD_OID}" 2>/dev/null)"; then
    echo "MERGE_RANGE status=error reason=log_failed" >&2
    exit 2
fi

# `grep -c` exits 1 for a real zero; anything else is a failed inspection.
grep_rc=0
TAGGED="$(printf '%s\n' "$TRAILERS" | grep -c '^copilot$')" || grep_rc=$?
case "$grep_rc" in
    0) ;;
    1) TAGGED=0 ;;
    *) echo "MERGE_RANGE status=error reason=count_failed rc=$grep_rc" >&2; exit 2 ;;
esac
if ! [[ "$TAGGED" =~ ^[0-9]+$ ]]; then
    echo "MERGE_RANGE status=error reason=count_unreadable" >&2
    exit 2
fi

if [ "$TOTAL" -eq "$TAGGED" ]; then
    echo "MERGE_RANGE status=ok commits=$TOTAL tagged=$TAGGED"
    exit 0
fi

# A trailer written in the body but not in the last paragraph is invisible to git's parser
# and needs a different fix, so it is named apart.
body_rc=0
INBODY="$(git -C "$REPO_DIR" log --format='%B' "${REVIEWED}..${HEAD_OID}" 2>/dev/null \
          | grep -c '^Review-Phase:[[:space:]]*copilot[[:space:]]*$')" || body_rc=$?
case "$body_rc" in
    0) ;;
    1) INBODY=0 ;;
    *) echo "MERGE_RANGE status=error reason=body_scan_failed rc=$body_rc" >&2; exit 2 ;;
esac
if [ "$INBODY" -gt "$TAGGED" ]; then
    echo "MERGE_RANGE status=blocked reason=trailer_not_in_trailer_block commits=$TOTAL tagged=$TAGGED in_body=$INBODY"
    echo "A commit writes 'Review-Phase: copilot' in its message but not as a trailer." >&2
    echo "git reads trailers from the LAST paragraph only, so it must sit in the same" >&2
    echo "block as Co-Authored-By and friends, with no blank line before it." >&2
    exit 1
fi
echo "MERGE_RANGE status=blocked reason=untagged_commit commits=$TOTAL tagged=$TAGGED"
exit 1
