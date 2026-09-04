#!/usr/bin/env -S bash -p
# A last-resort refusal: `$-` proves the mode, not how the shell got there.
if [[ $- != *p* ]]; then
    echo "PR_CI_STATE status=error reason=not_privileged" >&2
    exit 2
fi

# No `-e`: statuses are control flow here.
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_CI_STATE status=error reason=lib_dir_unresolvable" >&2; exit 2; }
# The bootstrap cannot use the loader. The refusing stub is what stops an empty `loadlib.sh` from
# leaving `rb_load` to `PATH`, and the first load's 127 is the stub's rather than the loader's.
unset -f rb_load 2>/dev/null || {
    echo "PR_CI_STATE status=error reason=loadlib_stale_definition" >&2; exit 2; }
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_CI_STATE status=error reason=loadlib_unreadable" >&2; exit 2; }
# `run_limited` ships at runtime here: a `gh` call that hangs would make the caller's bound no bound.
rb_load "$_RB_SELF_DIR" testlib run_limited "PR_CI_STATE status=error" || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "PR_CI_STATE status=error reason=loadlib_empty" >&2
    exit 2; }
rb_load "$_RB_SELF_DIR" recordlib sha_reason "PR_CI_STATE status=error" || exit 2
rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_CI_STATE status=error" || exit 2
rb_identity || {
    echo "PR_CI_STATE status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }

PR="${1:-}"
case "$PR" in
    ""|*[!0-9]*) echo "usage: $0 <pr> [--required] [--head <oid>]" >&2; exit 2 ;;
esac
shift
REQUIRED=""; WANT_HEAD=""; DEADLINE="${PR_CI_PROBE_TIMEOUT:-60}"
# A bad bound falls back to the default rather than removing the watchdog; a leading zero is octal.
case "$DEADLINE" in ""|0|0*|*[!0-9]*|??????*) DEADLINE=60 ;; esac
# One deadline for the whole run rather than per call, and an expired one is not a short one:
# clamping it up would grant each remaining call a fresh second plus the watchdog's escalation.
_RB_T0=$SECONDS
rb_left() {
    local left=$((DEADLINE - (SECONDS - _RB_T0)))
    [ "$left" -ge 1 ] || return 1
    printf '%s' "$left"
    return 0
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --required) REQUIRED="--required"; shift ;;
        --head)
            # `shift 2` on a one-element list would leave the check silently unpinned.
            [ "$#" -ge 2 ] || { echo "usage: $0 <pr> [--required] [--head <oid>]" >&2; exit 2; }
            WANT_HEAD="$2"; shift 2 ;;
        *) echo "usage: $0 <pr> [--required] [--head <oid>]" >&2; exit 2 ;;
    esac
done
if [ -n "$WANT_HEAD" ]; then
    # Confirmed before the read and again after it; a mismatch is `stale`, which the caller re-runs.
    _reason="$(sha_reason "$WANT_HEAD")" || {
        echo "PR_CI_STATE pr=$PR status=error reason=$_reason head=$WANT_HEAD" >&2; exit 2; }
    _left_head="$(rb_left)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=deadline_exhausted" >&2; exit 2; }
    HEAD_NOW="$(run_limited "$_left_head" gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" \
                  --json headRefOid --jq '.headRefOid' 2>/dev/null)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=head_unreadable" >&2; exit 2; }
    _reason="$(sha_reason "$HEAD_NOW")" || {
        echo "PR_CI_STATE pr=$PR status=error reason=$_reason head=$HEAD_NOW" >&2; exit 2; }
    if [ "$HEAD_NOW" != "$WANT_HEAD" ]; then
        echo "PR_CI_STATE pr=$PR status=stale head=$HEAD_NOW want=$WANT_HEAD"
        exit 5
    fi
fi

# `gh pr checks` exits non-zero with only a message when nothing is configured; the whole message
# is matched, so a benign line inside a larger failure falls through to the blocking branch.
checks_msg_is_none_configured() {
    case "$1" in
        *"
"*) return 1 ;;                       # more than one line is more than one thing
    esac
    case "$1" in
        "no checks reported on the '"*"' branch"|"no required checks reported on the '"*"' branch")
            return 0 ;;
    esac
    return 1
}

# One rollup addressed by the OID, over check runs and legacy statuses both, since two paginated
# REST reads are not a snapshot. `EXPECTED` is pending; a null rollup is `none`, a null object an error.
commit_checks_verdict() {   # <oid> ; prints green|failed|pending|none|malformed
    local oid="$1" _left _out
    _left="$(rb_left)" || return 2
    # `-f`, not `-F`: `--field` sends a numeric-looking value as a JSON number, and the variables are
    # `String!` and `GitObjectID!`.
    _out="$(run_limited "$_left" gh api graphql --hostname "$HOST" \
        -f query='query($o:String!,$r:String!,$oid:GitObjectID!){repository(owner:$o,name:$r){object(oid:$oid){... on Commit{statusCheckRollup{state}}}}}' \
        -f o="$OWNER" -f r="$REPO" -f oid="$oid" 2>/dev/null)" || return 2
    # Walked with `has`, not `//`: a default hides an error body behind "nothing to report".
    printf '%s' "$_out" | jq -r '
        if type != "object" or (has("errors")) then "malformed"
        elif (.data | type) != "object" then "malformed"
        elif (.data.repository | type) != "object" then "malformed"
        elif (.data.repository | has("object") | not) then "malformed"
        elif (.data.repository.object | type) != "object" then "malformed"
        elif (.data.repository.object | has("statusCheckRollup") | not) then "malformed"
        elif .data.repository.object.statusCheckRollup == null then "none"
        elif (.data.repository.object.statusCheckRollup | type) != "object" then "malformed"
        elif (.data.repository.object.statusCheckRollup.state | type) != "string" then "malformed"
        else ( .data.repository.object.statusCheckRollup.state
               | if IN("FAILURE","ERROR") then "failed"
                 elif IN("PENDING","EXPECTED") then "pending"
                 elif . == "SUCCESS" then "green"
                 else "malformed" end )
        end' 2>/dev/null || return 2
    return 0
}

# The union of the branch object's classic protection and the ruleset, both readable with the `repo`
# scope, since either can be the whole answer; `strict` is readable only on a ruleset, so the classic half is unenforced.
required_contexts() {   # <base ref> ; prints {contexts: [{context, app}], strict: bool}
    local base="$1" _left _branch _rules
    _left="$(rb_left)" || return 2
    _branch="$(run_limited "$_left" gh api --hostname "$HOST" \
        "repos/$OWNER/$REPO/branches/$base" 2>/dev/null)" || return 2
    _left="$(rb_left)" || return 2
    _rules="$(run_limited "$_left" gh api --hostname "$HOST" \
        "repos/$OWNER/$REPO/rules/branches/$base" --paginate 2>/dev/null)" || return 2
    # Every field is typed before it is used: an odd shape read as "no contexts" opens the gate.
    printf '%s\n%s\n' "$_branch" "$_rules" | jq -c -s --argjson strict \
        "$(if [ "${REVIEW_MERGE_STRICT:-}" = "1" ]; then printf 'true'; else printf 'false'; fi)" '
        if length < 2 then error("a branch and at least one rules page are expected")
        elif (.[0] | type) != "object" then error("the branch is not an object")
        elif (.[0].protected | type) != "boolean" then error("protected is not a boolean")
        elif any(.[1:][]; type != "array") then error("a rules page is not an array")
        else
          ( .[0] as $b
            | if ($b.protection | type) == "object" then
                if ($b.protection.required_status_checks | type) == "null"
                   or ($b.protection | has("required_status_checks") | not) then []
                elif ($b.protection.required_status_checks | type) != "object"
                  then error("required_status_checks is not an object")
                elif ($b.protection.required_status_checks | has("checks"))
                     and ($b.protection.required_status_checks.checks != null)
                     and (($b.protection.required_status_checks.checks | type) != "array")
                  then error("the classic checks are not an array")
                elif ($b.protection.required_status_checks.checks | type) == "array" then
                  [ $b.protection.required_status_checks.checks[]
                    | if type != "object" or (.context | type) != "string"
                      then error("a classic check has no context")
                      elif (.app_id | type) | IN("number","null") | not
                      then error("a classic app_id is not a number")
                      else {context: .context,
                            app: (if .app_id == -1 then null else .app_id end)} end ]
                elif ($b.protection.required_status_checks.contexts | type) != "array"
                  then error("the classic contexts are not an array")
                elif any($b.protection.required_status_checks.contexts[]; type != "string")
                  then error("a classic context is not a string")
                else [ $b.protection.required_status_checks.contexts[] | {context: ., app: null} ] end
              elif $b.protected then error("the branch is protected and its protection is unreadable")
              else [] end ) as $classic
          | ( [ .[1:][][]
                | if type != "object" then error("a rule is not an object")
                  elif (.type | type) != "string" then error("a rule has no type")
                  elif .type == "required_status_checks" then
                       if (.parameters | type) != "object" then error("a rule has no parameters")
                       elif (.parameters.required_status_checks | type) != "array"
                         then error("the ruleset checks are not an array")
                       elif (.parameters | has("strict_required_status_checks_policy"))
                            and ((.parameters.strict_required_status_checks_policy | type) != "boolean")
                         then error("the ruleset strict policy is not a boolean")
                       else .parameters.required_status_checks[]
                            | if type != "object" or (.context | type) != "string"
                              then error("a ruleset context is not a string")
                              elif (.integration_id | type) | IN("number","null") | not
                              then error("a ruleset integration_id is not a number")
                              else {context: .context,
                                    app: (if .integration_id == -1 then null
                                          else .integration_id end)} end
                       end
                  # The list is of what cannot name a check, so an unrecognised type refuses by name;
                  # `merge_queue` under strict is the one configuration the admin-merge record recommends.
                  elif .type | IN(
                      "creation","update","deletion","non_fast_forward",
                      "required_linear_history","required_signatures","pull_request",
                      "required_review_thread_resolution","copilot_code_review",
                      "authorization","tag","lock_branch","merge_queue_locked_ref",
                      "max_ref_updates","workflow_updates",
                      "commit_message_pattern","commit_author_email_pattern",
                      "committer_email_pattern","branch_name_pattern","tag_name_pattern",
                      "file_path_restriction","max_file_size","max_file_path_length",
                      "file_extension_restriction"
                    ) then empty
                  elif .type == "merge_queue" and $strict then empty
                  else error("a rule type this cannot evaluate: " + .type)
                  end ] ) as $ruleset
          | ( [ .[1:][][]
                | select((.type? // "") == "required_status_checks")
                | .parameters.strict_required_status_checks_policy == true ]
              | any ) as $strict_policy
          | { contexts: ($classic + $ruleset | unique), strict: $strict_policy }
        end' 2>"$ERRF" || return 2
    return 0
}

# Both sources are read twice and unioned, since the reads are not one snapshot and a requirement
# that moved between them would vanish; over-requiring costs a rerun, under-requiring is the merge.
required_checks_verdict() {   # <oid> <base> ; prints green|failed|behind|pending|none|malformed
    local oid="$1" base="$2" _left _req _req2 _strict _cmp _ctx_verdict _out
    _req="$(required_contexts "$base")" || return 2
    _req2="$(required_contexts "$base")" || return 2
    _strict="$(printf '%s\n%s\n' "$_req" "$_req2" | jq -r -s '
        if length != 2 or any(.[]; type != "object") then error("two objects are expected")
        elif any(.[]; (.contexts | type) != "array" or (.strict | type) != "boolean")
          then error("a required-set answer is not the shape it should be")
        else (any(.[]; .strict) | tostring) end' 2>/dev/null)" || return 2
    _req="$(printf '%s\n%s\n' "$_req" "$_req2" | jq -c -s '
        if length != 2 or any(.[]; type != "object") then error("two objects are expected")
        else (.[0].contexts + .[1].contexts | unique) end' 2>/dev/null)" || return 2
    # Being behind is not something waiting fixes, so it is asked first.
    case "$_strict" in
        true)
            _left="$(rb_left)" || return 2
            _cmp="$(run_limited "$_left" gh api --hostname "$HOST" \
                "repos/$OWNER/$REPO/compare/$base...$oid" 2>/dev/null)" || return 2
            _cmp="$(printf '%s' "$_cmp" | jq -r '
                if type != "object" then "malformed"
                elif (.behind_by | type) != "number" then "malformed"
                # A count is a whole number and not negative: -1 passes a type test.
                elif .behind_by < 0 or (.behind_by | floor) != .behind_by then "malformed"
                elif (.status | type) != "string" then "malformed"
                elif (.status | IN("identical","ahead","behind","diverged") | not) then "malformed"
                elif .behind_by > 0 then "behind"
                elif .status | IN("behind","diverged") then "behind"
                else "current" end' 2>/dev/null)" || return 2
            case "$_cmp" in
                behind)    printf '%s\n' behind; return 0 ;;
                current)   ;;
                *)         return 2 ;;
            esac ;;
        false) ;;
        *)     return 2 ;;
    esac
    case "$_req" in
        '[]') printf '%s\n' none; return 0 ;;
        '['*) ;;
        *)    return 2 ;;
    esac
    _left="$(rb_left)" || return 2
    _out="$(run_limited "$_left" gh api graphql --hostname "$HOST" \
        -f query='query($o:String!,$r:String!,$oid:GitObjectID!){repository(owner:$o,name:$r){object(oid:$oid){... on Commit{statusCheckRollup{contexts(first:100){pageInfo{hasNextPage}nodes{__typename ... on CheckRun{name status conclusion checkSuite{app{databaseId}}} ... on StatusContext{context state}}}}}}}}' \
        -f o="$OWNER" -f r="$REPO" -f oid="$oid" 2>/dev/null)" || return 2
    # A record is matched by the identifier its kind has, every record sharing the name is evaluated,
    # a bound requirement is matched on the app too, and a name that is not there is pending.
    printf '%s' "$_out" | jq -r --argjson req "$_req" '
        if type != "object" or (has("errors")) then "malformed"
        elif (.data | type) != "object" then "malformed"
        elif (.data.repository | type) != "object" then "malformed"
        elif (.data.repository | has("object") | not) then "malformed"
        elif (.data.repository.object | type) != "object" then "malformed"
        elif (.data.repository.object | has("statusCheckRollup") | not) then "malformed"
        else ( if .data.repository.object.statusCheckRollup == null then []
               elif (.data.repository.object.statusCheckRollup | type) != "object" then null
               elif (.data.repository.object.statusCheckRollup.contexts | type) != "object" then null
               elif (.data.repository.object.statusCheckRollup.contexts.pageInfo.hasNextPage | type) != "boolean" then null
               elif .data.repository.object.statusCheckRollup.contexts.pageInfo.hasNextPage then null
               elif (.data.repository.object.statusCheckRollup.contexts.nodes | type) != "array" then null
               else .data.repository.object.statusCheckRollup.contexts.nodes end ) as $ctx
          | if $ctx == null then "malformed"
            elif any($ctx[]; type != "object"
                             or (.__typename | type) != "string"
                             or (.__typename == "CheckRun" and (.name | type) != "string")
                             or (.__typename == "StatusContext" and (.context | type) != "string")) then "malformed"
            else [ $req[] as $want
                   | ( [ $ctx[]
                         | select(if .__typename == "CheckRun" then .name == $want.context
                                  elif .__typename == "StatusContext" then .context == $want.context
                                  else false end)
                         | select($want.app == null
                                  or (.__typename == "CheckRun"
                                      and (.checkSuite.app.databaseId == $want.app))) ] ) as $cs
                   | ( [ $cs[]
                         | if .__typename == "CheckRun" then
                             if (.status | type) != "string" then "malformed"
                             elif .status != "COMPLETED" then "pending"
                             elif (.conclusion | type) != "string" then "malformed"
                             elif .conclusion | IN("FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","STALE") then "failed"
                             elif .conclusion | IN("SUCCESS","NEUTRAL","SKIPPED") then "green"
                             else "malformed" end
                           elif .__typename == "StatusContext" then
                             if (.state | type) != "string" then "malformed"
                             elif .state | IN("FAILURE","ERROR") then "failed"
                             elif .state | IN("PENDING","EXPECTED") then "pending"
                             elif .state == "SUCCESS" then "green"
                             else "malformed" end
                           else "malformed" end ] ) as $each
                   | if ($each | length) == 0 then "pending"
                     elif any($each[]; . == "malformed") then "malformed"
                     elif any($each[]; . == "failed") then "failed"
                     elif any($each[]; . == "pending") then "pending"
                     else "green" end ] as $v
              | if any($v[]; . == "malformed") then "malformed"
                elif any($v[]; . == "failed") then "failed"
                elif any($v[]; . == "pending") then "pending"
                else "green" end
            end
        end' 2>/dev/null || return 2
    return 0
}

ERRF="$(mktemp 2>/dev/null)" || {
    echo "PR_CI_STATE pr=$PR status=error reason=no_scratch_file" >&2; exit 2; }
RC=0
# A call with no `--head` goes to `gh pr checks`, since there is no commit to address.
if [ -n "$WANT_HEAD" ] && [ -z "$REQUIRED" ]; then
    OUT="$(commit_checks_verdict "$WANT_HEAD")" || RC=$?
    MSG=""
    if [ "$RC" -ne 0 ]; then
        echo "PR_CI_STATE pr=$PR status=error reason=commit_checks_unreadable rc=$RC head=$WANT_HEAD" >&2
        rm -f "$ERRF" 2>/dev/null
        exit 2
    fi
    rm -f "$ERRF" 2>/dev/null
elif [ -n "$WANT_HEAD" ]; then
    # The PR's own base, since the working tree may be on any branch or none.
    _left_base="$(rb_left)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=deadline_exhausted" >&2; exit 2; }
    BASE_REF="$(run_limited "$_left_base" gh pr view "$PR" --repo "$HOST/$OWNER/$REPO"                   --json baseRefName --jq '.baseRefName' 2>/dev/null)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=base_unreadable" >&2; exit 2; }
    # Encoded, not refused: `#` and `%` are legal in a ref. `..` is refused, since `.` stays itself
    # under encoding and would traverse into another repository's branch.
    case "$BASE_REF" in
        ""|*..*)
            echo "PR_CI_STATE pr=$PR status=error reason=bad_base base=$BASE_REF" >&2; exit 2 ;;
    esac
    BASE_ENC="$(jq -rn --arg s "$BASE_REF" '$s|@uri' 2>/dev/null)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=base_unencodable" >&2; exit 2; }
    # An empty encoding would ask about `branches/`, which is the list.
    [ -n "$BASE_ENC" ] || {
        echo "PR_CI_STATE pr=$PR status=error reason=base_unencodable" >&2; exit 2; }
    OUT="$(required_checks_verdict "$WANT_HEAD" "$BASE_ENC")" || RC=$?
    MSG=""
    if [ "$RC" -ne 0 ]; then
        # The unsupported rule type is lifted onto the line, filtered to what a type can contain:
        # it comes out of an API body, and this line is parsed.
        REQ_DETAIL=""
        REQ_MSG="$(cat "$ERRF" 2>/dev/null)" || REQ_MSG=""
        case "$REQ_MSG" in
            *"a rule type this cannot evaluate: "*)
                REQ_DETAIL="${REQ_MSG##*a rule type this cannot evaluate: }"
                REQ_DETAIL="${REQ_DETAIL//[!A-Za-z0-9_-]/}"
                [ -n "$REQ_DETAIL" ] && REQ_DETAIL=" rule=$REQ_DETAIL" ;;
        esac
        echo "PR_CI_STATE pr=$PR status=error reason=required_checks_unreadable rc=$RC head=$WANT_HEAD$REQ_DETAIL" >&2
        rm -f "$ERRF" 2>/dev/null
        exit 2
    fi
    rm -f "$ERRF" 2>/dev/null
else
_left_checks="$(rb_left)" || {
    echo "PR_CI_STATE pr=$PR status=error reason=deadline_exhausted" >&2; exit 2; }
OUT="$(run_limited "$_left_checks" gh pr checks "$PR" --repo "$HOST/$OWNER/$REPO" $REQUIRED --json bucket \
         --jq 'if type != "array" or length == 0 then "malformed"
               elif any(.[]; type != "object" or (.bucket | type) != "string") then "malformed"
               elif any(.[]; .bucket | IN("fail","cancel")) then "failed"
               elif any(.[]; .bucket == "pending") then "pending"
               elif all(.[]; .bucket | IN("pass","skipping")) then "green"
               else "malformed" end' 2>"$ERRF")" || RC=$?
# The read has its own status, taken before `rm` overwrites it.
MSG="$(cat "$ERRF" 2>/dev/null)"; MSG_RC=$?
rm -f "$ERRF" 2>/dev/null
[ "$MSG_RC" -eq 0 ] || {
    echo "PR_CI_STATE pr=$PR status=error reason=diagnostic_unreadable rc=$MSG_RC" >&2; exit 2; }
fi

# Confirmed again after the read, and the base too under `--required`: a retargeted pull request
# keeps its head, so the requirements just read would be the old base's.
if [ -n "$WANT_HEAD" ]; then
    _left_after="$(rb_left)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=deadline_exhausted" >&2; exit 2; }
    HEAD_AFTER="$(run_limited "$_left_after" gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" \
                    --json headRefOid --jq '.headRefOid' 2>/dev/null)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=head_unreadable_after" >&2; exit 2; }
    _reason="$(sha_reason "$HEAD_AFTER")" || {
        echo "PR_CI_STATE pr=$PR status=error reason=$_reason head=$HEAD_AFTER" >&2; exit 2; }
    if [ "$HEAD_AFTER" != "$WANT_HEAD" ]; then
        echo "PR_CI_STATE pr=$PR status=stale head=$HEAD_AFTER want=$WANT_HEAD moved=during_checks"
        exit 5
    fi
    if [ -n "$REQUIRED" ]; then
        _left_base2="$(rb_left)" || {
            echo "PR_CI_STATE pr=$PR status=error reason=deadline_exhausted" >&2; exit 2; }
        BASE_AFTER="$(run_limited "$_left_base2" gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" \
                        --json baseRefName --jq '.baseRefName' 2>/dev/null)" || {
            echo "PR_CI_STATE pr=$PR status=error reason=base_unreadable_after" >&2; exit 2; }
        if [ "$BASE_AFTER" != "$BASE_REF" ]; then
            echo "PR_CI_STATE pr=$PR status=stale head=$HEAD_AFTER want=$WANT_HEAD moved=base"
            exit 5
        fi
    fi
fi

case "$OUT" in
    # Green requires a clean status: `gh` can emit a complete green result and then exit non-zero.
    green)
        [ "$RC" -eq 0 ] || {
            echo "PR_CI_STATE pr=$PR status=error reason=green_from_failed_probe rc=$RC" >&2
            exit 2
        }
        echo "PR_CI_STATE pr=$PR status=green";   exit 0 ;;
    failed)  echo "PR_CI_STATE pr=$PR status=failed";  exit 1 ;;
    # Neither pending, since waiting fixes nothing, nor failed, since the operator rebases rather
    # than looks for a broken check.
    behind)
        [ "$RC" -eq 0 ] || {
            echo "PR_CI_STATE pr=$PR status=error reason=behind_from_failed_probe rc=$RC" >&2
            exit 2
        }
        echo "PR_CI_STATE pr=$PR status=behind"; exit 6 ;;
    pending) echo "PR_CI_STATE pr=$PR status=pending"; exit 3 ;;
    # `none` is a value on the commit-addressed path; on the PR-addressed path it is a message and
    # status 1 below, and a probe that printed the message and then died carries the same text.
    none)
        [ "$RC" -eq 0 ] || {
            echo "PR_CI_STATE pr=$PR status=error reason=none_from_failed_probe rc=$RC" >&2
            exit 2
        }
        echo "PR_CI_STATE pr=$PR status=none"; exit 4 ;;
esac
if checks_msg_is_none_configured "$MSG" && [ "$RC" -eq 1 ]; then
    echo "PR_CI_STATE pr=$PR status=none"
    exit 4
fi
echo "PR_CI_STATE pr=$PR status=error reason=unreadable rc=$RC out=$OUT err=$MSG" >&2
exit 2
