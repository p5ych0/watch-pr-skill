#!/usr/bin/env -S bash -p
# A last-resort refusal: `$-` proves the mode, not how the shell got there.
if [[ $- != *p* ]]; then
    echo "PR_SIGNOFF status=error reason=not_privileged" >&2
    exit 2
fi

# No `-e`: statuses are control flow here.
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_SIGNOFF status=error reason=lib_dir_unresolvable" >&2; exit 2; }
unset -f rb_load 2>/dev/null || {
    echo "PR_SIGNOFF status=error reason=loadlib_stale_definition" >&2; exit 2; }
# The bootstrap cannot use the loader. The refusing stub is what stops an empty `loadlib.sh` from
# leaving `rb_load` to `PATH`, and the first load's 127 is the stub's rather than the loader's.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_SIGNOFF status=error reason=loadlib_unreadable" >&2; exit 2; }
rb_load "$_RB_SELF_DIR" recordlib sha_reason "PR_SIGNOFF status=error" || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "PR_SIGNOFF status=error reason=loadlib_empty" >&2
    exit 2; }
rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_SIGNOFF status=error" || exit 2
rb_identity || { echo "PR_SIGNOFF status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }

# A mode is a leading word and a PR number is digits, so an unknown word is refused by the digits check.
MODE=record
case "${1:-}" in
    sha) MODE=sha; shift ;;
esac
PR="${1:-}"; WHO="${2:-}"
case "$PR" in
    ""|*[!0-9]*) echo "usage: $0 [sha] <pr> <reviewer-login>" >&2; exit 2 ;;
esac
[ -n "$WHO" ] || { echo "usage: $0 [sha] <pr> <reviewer-login>" >&2; exit 2; }

# Paginated, because `comments(last:100)` loses the record it exists to find; every cursor is
# remembered so a cycle of any length stops, and an incomplete traversal is an error, not the answer so far.
SHA=""; SIGNED_AT=""; SIGNED_ID=""; VERDICT_AT=""; REVOKED_AT=""; REVOKED_ID=""; CURSOR=null; RS=$(printf '\036'); SEEN="${RS}null${RS}"; OK=1
while :; do
    PAGE=$(gh api --hostname "$HOST" graphql -F number="$PR" -f owner="$OWNER" -f repo="$REPO" \
        -F cursor="$CURSOR" -f query='query($owner:String!,$repo:String!,$number:Int!,$cursor:String){
          repository(owner:$owner,name:$repo){ pullRequest(number:$number){
            comments(first:100, after:$cursor){ pageInfo{hasNextPage endCursor}
              nodes{ body authorAssociation createdAt databaseId } }}}}' 2>/dev/null) || { OK=0; break; }
    # A 200 can carry `errors` beside structurally valid, partial `data`.
    printf '%s' "$PAGE" | jq -e 'has("errors") | not' >/dev/null 2>&1 || { OK=0; break; }
    # Every node is validated before any is filtered: a discarded malformed node turns "not
    # trustworthy" into "no signoff", and `createdAt` is second-resolution, so the id breaks ties.
    FOUND=$(printf '%s' "$PAGE" | jq -r --arg who "$WHO" "$RECORDLIB_JQ"'
        .data.repository.pullRequest.comments.nodes as $n
        | if ($n | type) != "array"
             or any($n[]; type != "object"
                          or (.body | type) != "string"
                          or (.authorAssociation | type) != "string"
                          or ((.createdAt | canonical_utc) | not)
                          or (.databaseId | type) != "number")
          then error("malformed nodes")
          else [ $n[]
                 | select(.authorAssociation | IN("OWNER","MEMBER","COLLABORATOR"))
                 | .createdAt as $c
                 | .databaseId as $i
                 # Anchored at both ends, both markers in one scan so their order decides, and an
                 # optional third field for the verdict time, since every record before it lacks one.
                 | (.body | [scan("(?m)^\\*\\*Review-Signoff(-Revoked)?:\\*\\* `([^`\n]{1,200})`(?: `([0-9a-f]{40})`)?(?: `([^`\n]*)`)?[[:space:]]*$")]
                          | last // ["","","",""])
                 | select(.[1] == $who)
                 | . as $m
                 # `none` is the absent case; a present value that is not a time is unreadable, and a
                 # sha capture on a revocation is such a value landed in the wrong field.
                 | (if $m[3] == null then "none"
                    elif ($m[3] | canonical_utc) then $m[3]
                    else "unreadable" end) as $v
                 | (if $m[0] != null and ($m[2] | type) == "string" then "unreadable" else $v end) as $v
                 | if $m[0] != null then "REVOKED\t" + $c + "\t" + ($i | tostring) + "\t" + $v
                   elif ($m[2] | type) == "string" then $m[2] + "\t" + $c + "\t" + ($i | tostring) + "\t" + $v
                   # A signoff without a sha but with a third field failed to parse; skipped, an
                   # older signoff would be returned with status 0.
                   elif ($m[3] | type) == "string" then "BADREC\t" + $c + "\t" + ($i | tostring) + "\t" + $v
                   else empty end
               ] as $recs
             # The last record by position, and the newest revocation apart from it, since one can
             # sit under a later signoff; separated by a unit separator no field can contain.
             | ($recs | last // "") + "\u001f" + ([ $recs[] | select(startswith("REVOKED")) ] | last // "")
          end') || { OK=0; break; }
    _us=$(printf '\037')
    _last="${FOUND%%"$_us"*}"
    _lastrev="${FOUND#*"$_us"}"
    [ -n "$_last" ] && {
        SHA="${_last%%$'\t'*}"
        _rest="${_last#*$'\t'}"
        SIGNED_AT="${_rest%%$'\t'*}"
        _rest="${_rest#*$'\t'}"
        SIGNED_ID="${_rest%%$'\t'*}"
        VERDICT_AT="${_rest#*$'\t'}"
    }
    # A page with no revocation leaves the previous page's: pages run oldest to newest.
    [ -n "$_lastrev" ] && {
        _rest="${_lastrev#*$'\t'}"
        REVOKED_AT="${_rest%%$'\t'*}"
        _rest="${_rest#*$'\t'}"
        REVOKED_ID="${_rest%%$'\t'*}"
    }
    HAS_NEXT=$(printf '%s' "$PAGE" | jq -r '.data.repository.pullRequest.comments.pageInfo.hasNextPage') || { OK=0; break; }
    case "$HAS_NEXT" in
        false) break ;;
        true)  ;;
        *) OK=0; break ;;
    esac
    NEXT=$(printf '%s' "$PAGE" | jq -r '.data.repository.pullRequest.comments.pageInfo.endCursor') || { OK=0; break; }
    { [ -n "$NEXT" ] && [ "$NEXT" != "null" ]; } || { OK=0; break; }
    case "$SEEN" in *"$RS$NEXT$RS"*) OK=0; break ;; esac
    SEEN="$SEEN$NEXT$RS"
    CURSOR="$NEXT"
done
if [ "$OK" -ne 1 ]; then
    echo "PR_SIGNOFF pr=$PR reviewer=$WHO status=error reason=unreadable" >&2
    exit 2
fi
# Decided before the `sha` mode and the revocation branch return: `sha` would hand a malformed
# record back as a closed phase, and a revocation would exit 1 as an ordinary one.
if [ "$VERDICT_AT" = unreadable ]; then
    if [ "$MODE" = sha ]; then
        echo "PR_SIGNOFF pr=$PR reviewer=$WHO status=error reason=bad_verdict_at" >&2
    else
        echo "PR_SIGNOFF pr=$PR reviewer=$WHO status=error reason=bad_verdict_at" >&2
    fi
    exit 2
fi
# A signoff stands only if no revocation is newer than the verdict it answers; equal reopens, since
# second-resolution times from different resources cannot be tie-broken. With nothing to compare, position decides.
if [ "$SHA" != REVOKED ] && [ "$SHA" != BADREC ] && [ -n "$SHA" ]; then
    case "$VERDICT_AT" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
            case "$REVOKED_AT" in
                [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
                    if [ ! "$REVOKED_AT" \< "$VERDICT_AT" ]; then
                        # The revocation is the record now, so its time and its id are what is printed.
                        SHA=REVOKED
                        SIGNED_AT="$REVOKED_AT"
                        SIGNED_ID="$REVOKED_ID"
                    fi ;;
            esac ;;
    esac
fi
# A marker that parsed as neither was the newest record, so skipping it hands the answer to an older signoff.
if [ "$SHA" = BADREC ]; then
    echo "PR_SIGNOFF pr=$PR reviewer=$WHO status=error reason=signoff_without_sha" >&2
    exit 2
fi
# In `sha` mode a non-value goes to stderr: stdout is the value's stream, and "none" is not a value.
if [ "$SHA" = REVOKED ]; then
    if [ "$MODE" = sha ]; then
        echo "PR_SIGNOFF pr=$PR reviewer=$WHO verdict-at=$VERDICT_AT at=$SIGNED_AT id=$SIGNED_ID sha=none reason=revoked" >&2
    else
        echo "PR_SIGNOFF pr=$PR reviewer=$WHO verdict-at=$VERDICT_AT at=$SIGNED_AT id=$SIGNED_ID sha=none reason=revoked"
    fi
    exit 1
fi
if [ -z "$SHA" ]; then
    if [ "$MODE" = sha ]; then
        echo "PR_SIGNOFF pr=$PR reviewer=$WHO sha=none" >&2
    else
        echo "PR_SIGNOFF pr=$PR reviewer=$WHO sha=none"
    fi
    exit 1
fi
# Through `sha_reason` although the pattern already demands forty hex: the shape rule stays
# enforced where it is defined if that pattern is ever loosened.
_why="$(sha_reason "$SHA")" || {
    echo "PR_SIGNOFF pr=$PR reviewer=$WHO status=error reason=$_why sha=$SHA" >&2
    exit 2; }
# `verdict-at=` and `at=` before `sha=`: callers read the sha with `${line##*sha=}` and the time
# with `${line#* at=}`, which the hyphen before `verdict-at` keeps distinct.
if [ "$MODE" = sha ]; then
    echo "$SHA"
    exit 0
fi
echo "PR_SIGNOFF pr=$PR reviewer=$WHO verdict-at=$VERDICT_AT at=$SIGNED_AT id=$SIGNED_ID sha=$SHA"
exit 0
