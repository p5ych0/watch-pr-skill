#!/usr/bin/env bash
# What a well-formed GitHub API record is, which lines a reader honours as a control record,
# what text requests a review, and what a `PR_REVIEW_STATE` answer is — one definition each.
# Sourced, never executed. A record that is malformed but arrived with a 200 is a failure
# wearing a success, so every field a decision is taken on is checked before the decision.

# The jq preamble. Prepend it to a program:
#
#   jq -s --argjson who "$WHO_JSON" "$RECORDLIB_JQ"'
#       [ .[][] ] | map(select(valid_review_record)) | …'
#
# A string rather than a file, so the helpers stay single-file-invocable.
RECORDLIB_JQ='
# A state outside this set must not be read as a dismissal, which is an actionable verdict.
def known_review_states: ["PENDING","APPROVED","CHANGES_REQUESTED","COMMENTED","DISMISSED"];

# Anchored at both ends: these values are compared lexically to decide which review is
# authoritative, and a trailing-garbage value sorts after every real one.
def canonical_utc: type == "string"
    and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");

def full_sha: type == "string" and test("^[0-9a-f]{40}$");

def valid_actor: (.user | type) == "object" and (.user.login | type) == "string";

# `submitted_at` may be null for a draft; `body` is string-or-null because `blocked-body`
# suppresses output for anything but CHANGES_REQUESTED, so a malformed body read as no text.
def valid_review_record:
    type == "object"
    and valid_actor
    and (.id | type) == "number"
    and (.commit_id | full_sha)
    and (.state | type) == "string"
    and (.state | IN(known_review_states[]))
    and (.submitted_at == null or (.submitted_at | canonical_utc))
    and (.body == null or (.body | type) == "string");

# `created_at` is required: `pr-round-count.sh` counts these comments as rounds, and
# `pr-review-state.sh` orders a clean comment against the newest review by it.
def valid_comment_record:
    type == "object"
    and valid_actor
    and (.id | type) == "number"
    and (.body == null or (.body | type) == "string")
    and (.created_at | canonical_utc);

# `in_reply_to_id` absent or null is "no parent" — a host that serialises nullable fields
# must not make every page unreadable — while a string or an object is malformed.
def valid_review_comment:
    valid_comment_record
    and ((has("in_reply_to_id") | not)
         or (.in_reply_to_id == null)
         or ((.in_reply_to_id | type) == "number"));

def opens_a_thread: ((has("in_reply_to_id") | not) or (.in_reply_to_id == null));

# `jq -s` slurps empty input to zero pages, and `.[][]` over an object iterates its values,
# so either would read as "no records".
def pages_or_error:
    if length == 0 then error("no pages")
    elif any(.[]; type != "array") then error("non-array page")
    else . end;

'

# sha_reason <value> ; prints `bad_head` or `head_not_full_sha` and returns 1, or nothing and 0
# `case` with a length test rather than `[[ =~ ]]`, where the pattern would be data.
sha_reason() {
    case "${1-}" in
        ""|*[!0-9a-f]*) printf 'bad_head'; return 1 ;;
    esac
    [ "${#1}" -eq 40 ] || { printf 'head_not_full_sha'; return 1; }
    return 0
}

# is_full_sha <value> ; 0 if it is
is_full_sha() {
    sha_reason "${1-}" >/dev/null
}

# The two logins. They end in `[bot]`, which a regex reads as a character class, so every
# comparison against them is `[ = ]`, never `[[ =~ ]]`.
RB_CODEX_BOT='chatgpt-codex-connector[bot]'
RB_COPILOT_BOT='copilot-pull-request-reviewer[bot]'

# rb_reserved_marker_line <text> ; prints the first reserved line, 0 if there is one
# The three markers are control records when they start a line of an OWNER, MEMBER or
# COLLABORATOR comment, and the bodies this loop posts quote untrusted text — so a body
# carrying one is refused rather than published as a record. `**Reviewed commit:**` is not in
# the set: `pr-round-count.sh` honours it only from a reviewer bot's own comment.
rb_reserved_marker_line() {   # <text> ; prints the first reserved line, 0 if there is one
    # No redirection and no `read`: a heredoc is backed by a temporary file, and a failed one
    # would answer "clean" about text nothing looked at. Matched over the whole body with
    # `case`, since peeling a line at a time is quadratic; the newline prefix makes a marker
    # on the first line the same shape as one anywhere else.
    local _b="$1" _m _pre _hit="" _best="" _len _rest
    local _nl='
'
    for _m in '**Review-Signoff:**' '**Review-Signoff-Revoked:**' \
              '**Review-Pause-Acknowledged:**'; do
        case "$_nl$_b" in
            *"$_nl$_m"*) ;;
            *) continue ;;
        esac
        # The earliest occurrence in the body wins, so the author is told the first line to fix.
        _pre="$_nl$_b"
        _pre="${_pre%%"$_nl$_m"*}"
        _len=${#_pre}
        if [ -z "$_best" ] || [ "$_len" -lt "$_best" ]; then
            _best=$_len
            _rest="$_nl$_b"
            _rest="${_rest#*"$_nl$_m"}"
            _hit="$_m${_rest%%"$_nl"*}"
        fi
    done
    [ -n "$_hit" ] || return 1
    printf '%s\n' "$_hit"
    return 0
}

# rb_review_trigger <text> ; 0 requests a pass, 1 does not, 2 could not tell
# A comment containing `@codex review` anywhere, in any case, requests a Codex pass — so a
# body that quotes the mention requests one when posted.
rb_review_trigger() {   # <text> ; 0 requests a pass, 1 does not, 2 could not tell
    local _lc
    _lc="$(printf '%s' "${1-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')" || return 2
    case "$_lc" in
        *'@codex review'*) return 0 ;;
    esac
    return 1
}

# What a `PR_REVIEW_STATE` answer is. Set rather than printed, like `rb_identity`: five values
# through one string make any delimiter a value a reviewer login can contain.
RB_REC_PR=''
RB_REC_SHA=''
RB_REC_WHO=''
RB_REC_VALUE=''
RB_REC_TAIL=''
# In a variable: bash 3.2 cannot parse an inline `[[ =~ ]]` pattern containing a parenthesis.
RB_REC_RX_HEAD='^PR_REVIEW_STATE pr=([0-9]+) sha=([0-9a-f]{7,40}) reviewer=([^[:space:]]+) '

# rb_review_record <line> <field> ; 0 parsed, 1 not a record of that shape
# The whole record, anchored at both ends, for the field the caller names. The tail is
# returned rather than accepted: what may follow the value differs per question.
rb_review_record() {   # <line> <field>
    RB_REC_PR=''; RB_REC_SHA=''; RB_REC_WHO=''; RB_REC_VALUE=''; RB_REC_TAIL=''
    local _rx
    case "${2-}" in
        ""|*[!a-z]*) return 1 ;;
    esac
    _rx="$RB_REC_RX_HEAD${2}"'=([a-z]+)(.*)$'
    [[ "${1-}" =~ $_rx ]] || return 1
    RB_REC_PR="${BASH_REMATCH[1]}"
    RB_REC_SHA="${BASH_REMATCH[2]}"
    RB_REC_WHO="${BASH_REMATCH[3]}"
    RB_REC_VALUE="${BASH_REMATCH[4]}"
    RB_REC_TAIL="${BASH_REMATCH[5]}"
    return 0
}

# rb_review_record_is_about <pr> <reviewer> <head-oid> ; 0 yes, 1 no
# A well-formed line about another PR, reviewer or head is not an answer. The head is passed
# whole and compared at the record's own width; as strings, never `=~`, because of `[bot]`.
rb_review_record_is_about() {   # <pr> <reviewer> <head-oid>
    [ -n "$RB_REC_SHA" ] || return 1
    [ "$RB_REC_PR" = "${1-}" ] || return 1
    [ "$RB_REC_WHO" = "${2-}" ] || return 1
    [ "$RB_REC_SHA" = "${3:0:${#RB_REC_SHA}}" ] || return 1
    return 0
}

# rb_replies_only_line <line> <pr> <reviewer> <head-oid> ; 0 if that exact shape
# The one verdict an operator can answer for: a review whose comments are all replies. Matched
# in full, because this shape bypasses the status gate and can authorise a merge.
rb_replies_only_line() {   # <line> <pr> <reviewer> <head-oid>
    rb_review_record "${1-}" verdict || return 1
    rb_review_record_is_about "${2-}" "${3-}" "${4-}" || return 1
    [ "$RB_REC_VALUE" = findings ] || return 1
    case "$RB_REC_TAIL" in
        " findings="*" source=replies-only") ;;
        *) return 1 ;;
    esac
    local _n="${RB_REC_TAIL# findings=}"
    _n="${_n% source=replies-only}"
    case "$_n" in
        ""|*[!0-9]*) return 1 ;;
    esac
    # A replies-only review has comments; a zero count is a different record.
    [ "$_n" -ge 1 ] 2>/dev/null || return 1
    return 0
}

# rb_signoff_answers <signoff-line> <answer-deadline> <pr> <reviewer> <head-oid>
# Whether an operator signoff answers a given review: it must name the head and be recorded
# strictly after the deadline. Equal is not newer — timestamps are second-resolution and this
# is permission to merge. The reason is set in RB_VOUCH_REASON rather than printed.
RB_VOUCH_REASON=''
# `verdict-at=` is always present, `none` where the record carries no time, so there is one shape.
RB_SIGNOFF_RX='^PR_SIGNOFF pr=([0-9]+) reviewer=([^[:space:]]+) verdict-at=(none|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) at=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) id=([0-9]+) sha=([0-9a-f]{40})$'
rb_signoff_answers() {   # <signoff-line> <answer-deadline> <pr> <reviewer> <head-oid>
    RB_VOUCH_REASON=''
    local _at
    # Canonical UTC is part of the shape because the comparison below is a string one. A
    # revocation fails here too: `sha=none` is not a commit.
    [[ "${1-}" =~ $RB_SIGNOFF_RX ]] || { RB_VOUCH_REASON=signoff_malformed; return 1; }
    _at="${BASH_REMATCH[4]}"
    [ "${BASH_REMATCH[1]}" = "${3-}" ] || { RB_VOUCH_REASON=other_pr; return 1; }
    [ "${BASH_REMATCH[2]}" = "${4-}" ] || { RB_VOUCH_REASON=other_reviewer; return 1; }
    [ "${BASH_REMATCH[6]}" = "${5-}" ] || { RB_VOUCH_REASON=other_head; return 1; }
    case "${2-}" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
        "") RB_VOUCH_REASON=no_review; return 1 ;;
        *) RB_VOUCH_REASON=review_untimed; return 1 ;;
    esac
    [ "$_at" \> "${2-}" ] || { RB_VOUCH_REASON=not_after; return 1; }
    return 0
}

# rb_answer_at <review-time> <newest-reply-time> ; sets RB_ANSWER_AT to the later
# A replies-only verdict is produced by the comments, and a reply does not move the review's
# `submitted_at`, so a signoff has to be newer than the later of the two. Only the reply may
# be absent; both absent is a refusal, and a reply with no review is a contradiction (2).
RB_ANSWER_AT=''
rb_answer_at() {   # <review-time> <newest-reply-time>
    RB_ANSWER_AT=''
    case "${1-}" in
        ""|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
        *) return 2 ;;
    esac
    case "${2-}" in
        ""|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
        *) return 2 ;;
    esac
    if [ -z "${1-}" ] && [ -z "${2-}" ]; then
        return 1
    fi
    if [ -z "${1-}" ]; then
        return 2
    fi
    if [ -z "${2-}" ]; then
        RB_ANSWER_AT="${1-}"
    elif [ "${1-}" \> "${2-}" ]; then
        RB_ANSWER_AT="${1-}"
    else
        RB_ANSWER_AT="${2-}"
    fi
    return 0
}

# rb_escape_snapshot <line> ; 0 parsed, 1 not that shape
# What `pr-review-state.sh escape-snapshot` answers: exactly three tab-separated fields, the
# id and two canonical UTC times, so a truncated line cannot assign one value to both times.
RB_SNAP_ID=''
RB_SNAP_REVIEW_AT=''
RB_SNAP_REPLY_AT=''
RB_SNAP_UTC='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
RB_SNAP_RX='^([0-9]+)'$'\t'"($RB_SNAP_UTC)"$'\t'"($RB_SNAP_UTC)\$"
rb_escape_snapshot() {   # <line>
    RB_SNAP_ID=''; RB_SNAP_REVIEW_AT=''; RB_SNAP_REPLY_AT=''
    [[ "${1-}" =~ $RB_SNAP_RX ]] || return 1
    RB_SNAP_ID="${BASH_REMATCH[1]}"
    RB_SNAP_REVIEW_AT="${BASH_REMATCH[2]}"
    RB_SNAP_REPLY_AT="${BASH_REMATCH[3]}"
    return 0
}
