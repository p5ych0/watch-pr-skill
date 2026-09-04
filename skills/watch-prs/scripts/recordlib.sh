#!/usr/bin/env bash

# A string rather than a file, so the helpers stay single-file-invocable.
RECORDLIB_JQ='
# A state outside this set must not be read as a dismissal, which is an actionable verdict.
def known_review_states: ["PENDING","APPROVED","CHANGES_REQUESTED","COMMENTED","DISMISSED"];

# Anchored at both ends: these values are compared lexically to decide which review is
# authoritative, and a trailing-garbage value would sort after every real one.
def canonical_utc: type == "string"
    and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");

def full_sha: type == "string" and test("^[0-9a-f]{40}$");

def valid_actor: (.user | type) == "object" and (.user.login | type) == "string";

# `submitted_at` may be null for a draft. `body` is string-or-null because `blocked-body` suppresses
# output for anything but CHANGES_REQUESTED, where a malformed body would otherwise read as no text.
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

# `case` with a length test rather than `[[ =~ ]]`, where the pattern would be data.
sha_reason() {
    case "${1-}" in
        ""|*[!0-9a-f]*) printf 'bad_head'; return 1 ;;
    esac
    [ "${#1}" -eq 40 ] || { printf 'head_not_full_sha'; return 1; }
    return 0
}

is_full_sha() {
    sha_reason "${1-}" >/dev/null
}

# These end in `[bot]`, which a regex reads as a character class: compare them literally, never with `=~`.
RB_CODEX_BOT='chatgpt-codex-connector[bot]'
RB_COPILOT_BOT='copilot-pull-request-reviewer[bot]'

# A body this loop posts quotes untrusted text, so a line starting with a control marker is refused
# rather than published as a record. `**Reviewed commit:**` is not one: it is honoured only from a bot.
rb_reserved_marker_line() {   # <text> ; prints the first reserved line, 0 if there is one
    # No redirection and no `read`: a heredoc's temporary file can fail and answer "clean". `case` over
    # the whole body (peeling is quadratic), prefixed with a newline so a first-line marker has the same shape.
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

# Anywhere and in any case: the mention is the trigger wherever it sits, so a body quoting it requests a pass.
rb_review_trigger() {   # <text> ; 0 requests a pass, 1 does not, 2 could not tell
    local _lc
    _lc="$(printf '%s' "${1-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')" || return 2
    case "$_lc" in
        *'@codex review'*) return 0 ;;
    esac
    return 1
}

# Set rather than printed: five values through one string make any delimiter a value a login can contain.
RB_REC_PR=''
RB_REC_SHA=''
RB_REC_WHO=''
RB_REC_VALUE=''
RB_REC_TAIL=''
# In a variable: bash 3.2 cannot parse an inline `[[ =~ ]]` pattern containing a parenthesis.
RB_REC_RX_HEAD='^PR_REVIEW_STATE pr=([0-9]+) sha=([0-9a-f]{7,40}) reviewer=([^[:space:]]+) '

# The tail is returned rather than accepted: what may follow the value differs per question.
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

# Compared at the record's own width, and literally rather than with `=~`, because of `[bot]`.
rb_review_record_is_about() {   # <pr> <reviewer> <head-oid>
    [ -n "$RB_REC_SHA" ] || return 1
    [ "$RB_REC_PR" = "${1-}" ] || return 1
    [ "$RB_REC_WHO" = "${2-}" ] || return 1
    [ "$RB_REC_SHA" = "${3:0:${#RB_REC_SHA}}" ] || return 1
    return 0
}

# Matched in full: this shape bypasses the status gate and can authorise a merge.
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

# Strictly after the deadline: equal is not newer, timestamps being second-resolution and this
# being permission to merge. The reason is set in RB_VOUCH_REASON rather than printed.
RB_VOUCH_REASON=''
# `verdict-at=` is always present, `none` where the record carries no time, so there is one shape.
RB_SIGNOFF_RX='^PR_SIGNOFF pr=([0-9]+) reviewer=([^[:space:]]+) verdict-at=(none|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) at=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) id=([0-9]+) sha=([0-9a-f]{40})$'
rb_signoff_answers() {   # <signoff-line> <answer-deadline> <pr> <reviewer> <head-oid>
    RB_VOUCH_REASON=''
    local _at
    # Canonical UTC is part of the shape because the comparison below is a string one; a
    # revocation's `sha=none` fails here too.
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

# A reply does not move the review's `submitted_at`, so the later of the two; both absent is a
# refusal, and a reply with no review is a contradiction rather than a deadline.
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

# Exactly three tab-separated fields, so a truncated line cannot assign one value to both times.
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
