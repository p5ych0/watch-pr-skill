#!/usr/bin/env bash
# What a well-formed GitHub API record looks like. Sourced, never executed.
#
# NOT named `test-*.sh`: `pr-selfcheck.sh` and CI both run every `test-*.sh` as a
# test, and a library that ran as one would report a vacuous pass.
#
# WHY THIS EXISTS
#
# Three scripts read the same two endpoints and each re-implemented the same
# record validation. That is not a style complaint — it is a defect generator, and
# issue #11 was opened because the same rule kept having to be added a third and
# fourth time:
#
#   * `commit_id` as 40-hex was added to one script, then a second, then a third.
#   * A canonical UTC `submitted_at` followed the same path.
#   * `state` against the known set reached two scripts and stopped. It sat
#     missing from `pr-review-state.sh` for eleven rounds, where an unrecognised
#     value fell through `head_review_snapshot`'s catch-all as `dismissed` with
#     status 0 — an actionable "the review was withdrawn", which the driver
#     answers by requesting another pass. A malformed page drove a review loop.
#
# Each of those was a real finding, and each was found separately in a different
# script. One definition removes the mechanism rather than the instances.
#
# THE RULE THESE ENCODE, from CLAUDE.md: a failure must never be
# indistinguishable from "no findings", "clean", or "zero unresolved". A record
# that is malformed but arrived with a 200 is exactly that failure wearing a
# success, so every field a decision is taken on has to be checked before the
# decision is taken.

# The jq preamble. Prepend it to a program:
#
#   jq -s --argjson who "$WHO_JSON" "$RECORDLIB_JQ"'
#       [ .[][] ] | map(select(valid_review_record)) | …'
#
# It is a STRING rather than a file so the helpers stay single-file-invocable and
# no jq `--from-file`/`include` path has to be resolved at runtime — the helpers
# already resolve one path (their own directory) and a second would be one more
# thing to get wrong in an installed plugin copy.
#
# Defensive note on `IN`: `null | IN("A","B")` is `false`, so a null `state`
# fails `valid_review_record` through that clause even without the explicit type
# test. The type test is kept anyway, because relying on that is exactly the kind
# of implicit reasoning this file exists to stop.
RECORDLIB_JQ='
# The states GitHub documents for a review. A value outside this set is not a
# state this tool can act on — notably it must NOT be treated as a dismissal,
# which is an actionable verdict the driver responds to by re-requesting.
def known_review_states: ["PENDING","APPROVED","CHANGES_REQUESTED","COMMENTED","DISMISSED"];

# A canonical UTC instant: anchored at BOTH ends. A prefix-only test let
# `2026-01-02T00:00:00zzzz` through, and these values are compared LEXICALLY to
# decide which review is authoritative — so a value sorting after every real
# timestamp let a stale record outrank a current one.
def canonical_utc: type == "string"
    and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");

def full_sha: type == "string" and test("^[0-9a-f]{40}$");

# The author of a record. A missing or non-string login cannot be matched against
# the requested reviewer, and an unmatched record is silently skipped — so a
# malformed one reads as "this reviewer said nothing", which is the direction that
# lets a blocking review disappear.
def valid_actor: (.user | type) == "object" and (.user.login | type) == "string";

# A review record from `pulls/N/reviews`.
#
# `id` is required because it is the identity the watch compares between polls to
# tell a new review from the one it already reported; a record without it cannot
# be distinguished from another and must not be counted as a pass.
#
# `submitted_at` may be null — that is a draft in flight, which `state` reports as
# PENDING — but a non-null value must be a real timestamp, because `submitted_at
# != null` is what makes a record count as a submitted review.
def valid_review_record:
    type == "object"
    and valid_actor
    and (.id | type) == "number"
    and (.commit_id | full_sha)
    and (.state | type) == "string"
    and (.state | IN(known_review_states[]))
    and (.submitted_at == null or (.submitted_at | canonical_utc))
    # `body` is checked here rather than at one call site, because the one place
    # that reads it is the one place where silence is indistinguishable from an
    # answer: `pr-findings.sh blocked-body` SUPPRESSES output for anything that is
    # not exactly CHANGES_REQUESTED, so a malformed body produced empty stdout and
    # rc 0 — "this blocking review has no text", which is the only text there is.
    # A missing key is `null` in jq, so requiring string-or-null costs the other
    # two callers nothing.
    and (.body == null or (.body | type) == "string");

# An issue comment from `issues/N/comments`. Codex reports a CLEAN pass here and
# submits no review at all, so this endpoint is load-bearing: a clean verdict is
# invisible to anything that reads only `pulls/N/reviews`.
#
# `body` may be null — GitHub returns that for a comment with no text — but a
# non-null body must be a string, since it is scanned for the footer and the
# clean-pass phrasing.
#
# `created_at` is REQUIRED, not string-or-null. GitHub always sets it, so a record
# without one is malformed — and `pr-round-count.sh` counts these comments as
# rounds without reading the field, so a malformed record was countable. That is
# the unsafe direction: an extra round pushes the count past the operator
# check-in. `pr-review-state.sh` also orders a clean comment against the newest
# review by this timestamp, and a null there is not an ordering.
def valid_comment_record:
    type == "object"
    and valid_actor
    and (.id | type) == "number"
    and (.body == null or (.body | type) == "string")
    and (.created_at | canonical_utc);

# A REVIEW comment — the rows hanging off `pulls/N/reviews/<id>/comments`.
#
# Same fields as a review-thread comment plus the one that says whether it OPENS a
# thread or continues one: `in_reply_to_id` is a NUMBER on a reply, and on a
# top-level comment it is absent — or `null`, which is the same statement in a
# different serialisation.
#
# NULL IS "NO PARENT", NOT A MALFORMED RECORD. github.com omits the key today, so
# a first version rejected null as unreadable; a host that serialises its nullable
# fields would then have made every ordinary finding page unreadable, and the watch
# would stop with rc 2 on every review. A string or an object still is malformed:
# those are not an absent parent, they are a payload this code cannot read.
#
# That distinction decides a merge. `pr-review-state.sh` treats a reply as
# continuing a thread its opener already accounts for, so a presence-only test
# silently discarded any row carrying a malformed value — and a page of those
# counted as zero findings, which is `clean`. A field whose shape decides a gate
# has to be validated, not merely looked for.
def valid_review_comment:
    valid_comment_record
    and ((has("in_reply_to_id") | not)
         or (.in_reply_to_id == null)
         or ((.in_reply_to_id | type) == "number"));

# Whether a review comment OPENS a thread. One definition, because "is this a
# finding" is asked in more than one place and the answer is this field — and
# because absent and null are the same answer, which is easy to get wrong twice.
def opens_a_thread: ((has("in_reply_to_id") | not) or (.in_reply_to_id == null));

# A page from a `--paginate` read, slurped with `-s`.
#
# `jq -s` slurps into an array of PAGES. Empty input slurps to ZERO pages, and
# `.[][]` over an object iterates its values rather than failing — so an errored
# body or an empty read produced "no records", which every caller reads as "no
# findings" or "no rounds yet". Both are the direction that skips a gate.
def pages_or_error:
    if length == 0 then error("no pages")
    elif any(.[]; type != "array") then error("non-array page")
    else . end;

# THE SAME RULE FOR THE ENDPOINTS THAT PAGE AS OBJECTS. `/commits/{oid}/check-runs`
# and `/commits/{oid}/status` return an OBJECT per page with the records under a
# named key, so `pages_or_error` — which requires every page to be an array —
# refuses them, and reaching for `.[][]` instead would iterate an error body`s
# VALUES exactly as it did before that rule existed. The key is named rather than
# assumed, because a page that came back without it is a fetch that told us
# nothing and must not read as an empty list of checks.
# AND THE BODY SAYS HOW MANY RECORDS THERE ARE, so a read that lost some can be
# caught rather than believed. Both endpoints carry `total_count`; MEASURED, it is
# the grand total repeated identically on every page — 302 on each of the four
# pages of a `cli/cli` commit whose arrays hold 100, 100, 100 and 2, and 6 on each
# page of a `scipy/scipy` combined status read two at a time. So a body claiming
# records while carrying none, or a `--paginate` that stopped early, disagrees with
# its own count. Unchecked, `{"total_count":1,"check_runs":[]}` reads as `none`,
# which the CI gate accepts as "no checks are configured" — a truncated fetch
# arriving as a benign verdict, which is the one outcome this rule exists to stop.
# Pages disagreeing with EACH OTHER is refused too: that is a body from a different
# read, and taking either one is a guess.
#
# AND THE COUNT ALONE IS NOT ENOUGH, because `--paginate` is not a snapshot. It
# requests the pages one after another, so a rerun landing between two of them
# REORDERS the result: an offset that has shifted returns a record already seen and
# skips the one that moved past it. The total still matches, and what was dropped
# can be the failing run while what repeated is a passing one — `green` on a red
# commit, which is the direction nothing else here would catch. Records are
# therefore identified rather than counted: every one carries a numeric `id` — both
# endpoints supply it — and an id seen twice means the read is inconsistent and
# says nothing about the commit.
def object_pages_or_error($k):
    if length == 0 then error("no pages")
    elif any(.[]; type != "object") then error("non-object page")
    elif any(.[]; has($k) | not) then error("page lacks " + $k)
    elif any(.[]; .[$k] | type != "array") then error($k + " is not an array")
    elif any(.[]; .total_count | type != "number") then error("total_count is not a number")
    elif ([ .[].total_count ] | unique | length) != 1 then error("total_count differs across pages")
    elif .[0].total_count != ([ .[][$k][] ] | length) then error("total_count disagrees with the records")
    elif any(.[][$k][]; type != "object" or (.id | type) != "number") then error("a record has no numeric id")
    elif ([ .[][$k][].id ] | unique | length) != ([ .[][$k][] ] | length) then error("a record is repeated across pages")
    else . end;
'

# The SAME rule, for shell rather than jq. `pr-watch.sh` does not read the API —
# it validates what a helper printed — but "a full commit SHA" has to mean one
# thing across the plugin, and it was written out twice more there as a Bash
# regex. A head that is not a real SHA is the input to every subsequent probe, so
# it is the same consequence by a different route.
#
#   is_full_sha "$head" || …
#
# No `[[ =~ ]]`: the pattern is data there, and a caller could pass one. `case`
# with a length test says the same thing without giving anything a chance to be
# interpreted.
# Why a value is not a full SHA, for the callers that report the two apart. They
# each spelled this out themselves — the same `case` plus length test, three more
# times — and the first drift guard did not see them, because it only recognised
# the jq REGEX spelling of the rule. A guard that matches one spelling of a
# duplicated rule leaves the duplication it was built to remove.
#
#   reason="$(sha_reason "$head")" || { echo "… reason=$reason"; return 2; }
#
# Prints nothing and returns 0 when the value is a full SHA.
sha_reason() {
    case "${1-}" in
        ""|*[!0-9a-f]*) printf 'bad_head'; return 1 ;;
    esac
    [ "${#1}" -eq 40 ] || { printf 'head_not_full_sha'; return 1; }
    return 0
}

# The predicate, defined in terms of the same rule so there is exactly one place
# it lives. `pr-watch.sh` wants a yes/no; the helpers above want the reason.
is_full_sha() {
    sha_reason "${1-}" >/dev/null
}

# ── WHO THE REVIEWERS ARE ──────────────────────────────────────────────────
#
# Two logins, one definition. They were written out in `pr-merge-gate.sh` and in
# `SKILL.md`, and a third copy was about to appear in `pr-close-round.sh` — which
# is the point at which this repository's own rule applies: a value that more than
# one caller needs lives in one place, because the copy that drifts is never the
# one you are looking at.
#
# The drift here would be quiet and total. Every verdict check compares a record's
# `reviewer=` field against one of these as a STRING; a login that is one character
# wrong matches nothing, so the gate reports "did not return an exact clean record"
# for a reviewer that signed off perfectly. `test-pr-skill-contract.sh` asserts
# that `SKILL.md`'s copies still say the same thing, because the document cannot
# source a shell library.
#
# `[bot]` IS NOT A PATTERN. These end in brackets, which a regex reads as a
# character class — every comparison against them is `[ = ]`, never `[[ =~ ]]`.
RB_CODEX_BOT='chatgpt-codex-connector[bot]'
RB_COPILOT_BOT='copilot-pull-request-reviewer[bot]'

# ── WHAT A READER HONOURS AS A RECORD ──────────────────────────────────────
#
# Three markers on this PR are CONTROL, not prose, AND ARE REACHABLE FROM A BODY
# THESE CALLERS POST: `pr-signoff.sh` reads `**Review-Signoff:**` and
# `**Review-Signoff-Revoked:**`, and `pr-round-count.sh` reads
# `**Review-Pause-Acknowledged:**`. Each is anchored to the start of a line, and
# each is trusted because the comment carrying it came from an OWNER, MEMBER or
# COLLABORATOR — which the operator driving this loop is.
#
# `**Reviewed commit:**` IS NOT IN THAT SET, deliberately. `pr-round-count.sh`
# reads it only from a comment whose `.user.login` is one of the reviewer bots AND
# whose body also says it found no major issues, so a body posted by these callers
# cannot create one. Refusing it here would stop an author describing the footer
# while preventing nothing.
#
# THE BODIES THIS LOOP POSTS ARE COMPOSED FROM UNTRUSTED TEXT. A round summary or
# a phase account quotes findings, PR descriptions and reviewer comments — so a
# body reproducing one of these lines publishes it under the operator's identity
# and CREATES the record it was only describing. A finding that says "the
# acknowledgement should read `**Review-Pause-Acknowledged:** …`" becomes that
# acknowledgement: the boundary at round 10 stops firing, silently, because the
# pause it promised has already been answered by prose.
#
# Rejecting is the fail-closed answer, and it is not an obstacle: these markers
# are only honoured at the START of a line, so indenting one or quoting it inline
# still says what the author meant. Rewriting the author's text instead would be a
# silent edit to a record someone is about to be held to.
#
# A FENCED BLOCK IS NOT A WAY ROUND IT, and must not be offered as one. The
# readers scan the comment's raw body, where a line inside a fence still starts at
# column 0 — the fence is markup to a renderer and nothing at all to a regex. So a
# fenced marker is honoured, is refused here, and the advice says four spaces.
#
# ONE DEFINITION, because two scripts post caller-written bodies —
# `pr-close-round.sh` and `pr-copilot-phase.sh` — and this is precisely the rule
# that must not be present in one of them and missing from the other.
rb_reserved_marker_line() {   # <text> ; prints the first reserved line, 0 if there is one
    # NO REDIRECTION, BECAUSE A REDIRECTION CAN FAIL AND THIS ANSWERS "CLEAN".
    # The body was read through `<<EOF`, and a heredoc is backed by a TEMPORARY
    # FILE: when one cannot be created the redirection fails, the loop never runs,
    # and `return 1` says "no marker" about text nothing has looked at. Both
    # callers read that as permission to post, so a control line would be
    # published under the operator's identity because a filesystem filled up — the
    # fail-open shape this repository forbids, where a failure is
    # indistinguishable from a clean answer.
    #
    # IT IS NOT A BASH 3.2 PROBLEM, and saying so was wrong. Read from the
    # sources: 4.4 has no pipe path at all and always writes a temporary file; 5.2
    # and 5.3 use a pipe only while the body fits `HEREDOC_PIPESIZE` — the system
    # pipe capacity, 4096 bytes on this machine — and fall back to a temporary
    # file above it. A round summary is routinely larger than that.
    #
    # WHAT WAS MEASURED, AND WHAT IT SHOWED: an unwritable `TMPDIR` does not
    # reproduce it on 4.4, 5.2 or 5.3, at 100 bytes or at 200 kB — because bash
    # falls back to `/tmp` when `TMPDIR` is unusable (`get_sys_tmpdir`). That is a
    # fact about the fallback, not about the backend, and it is why no fixture
    # stages this: making temp-file creation fail means making it fail everywhere.
    #
    # MATCHED OVER THE WHOLE BODY, NOT PEELED A LINE AT A TIME. Peeling was the
    # first shape and it is QUADRATIC: each iteration copies the entire remaining
    # suffix twice, once for `%%` and once for `#`. Measured on this machine —
    # 100 lines 8ms, 1,000 lines 0.7s, 5,000 lines 19s, 20,000 lines 295s — so a
    # newline-heavy phase body stalls the round before anything can be posted,
    # which is a worse failure than the one this function is for.
    #
    # THREE PATTERNS, EACH TESTED ONCE. `case` matches over the whole string, so
    # the common answer — no marker — costs one pass per pattern and nothing else.
    # The body is prefixed with a newline so a marker on the first line matches the
    # same `\n<marker>` shape as one anywhere else, which is what makes "at the
    # start of a line" a single pattern rather than a special case.
    #
    # STILL NO REDIRECTION AND NO `read`: `case` and `${…}` are handled by the
    # parser, so there is no temporary file to fail underneath this and no name to
    # shadow.
    local _b="$1" _m _pre _hit="" _best="" _len _rest
    local _nl='
'
    for _m in '**Review-Signoff:**' '**Review-Signoff-Revoked:**' \
              '**Review-Pause-Acknowledged:**'; do
        case "$_nl$_b" in
            *"$_nl$_m"*) ;;
            *) continue ;;
        esac
        # THE EARLIEST OCCURRENCE OF THIS MARKER, by the length of what precedes
        # it — `%%` is the shortest match, so this is the first one in the body.
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
    # THE FIRST ONE IN THE BODY WINS, not the first in the list: the author is told
    # which line to fix, and a body carrying two must name the earlier.
    [ -n "$_hit" ] || return 1
    printf '%s\n' "$_hit"
    return 0
}

# ── WHAT REQUESTS A REVIEW ─────────────────────────────────────────────────
#
# A comment CONTAINING `@codex review` is a request for a Codex pass — the skill's
# own table says so, and that is the whole trigger. It does not have to be at the
# start of a line, and nothing else about the comment matters.
#
# So a caller-written body that QUOTES the mention — out of a PR description, a
# finding, or this repository's own documentation — requests a pass when it is
# posted. Two places post such a body with no Codex request intended: the phase
# summary, which stops for the operator immediately afterwards, and a Copilot
# round's summary, where only Copilot should be re-requested. In both the quoted
# mention starts a Codex pass nobody asked for, against a phase that has either
# stopped or moved on.
#
# Matched case-insensitively and anywhere in the text, which is broader than the
# marker rule deliberately: a marker is only honoured at the start of a line, and
# this is not.
rb_review_trigger() {   # <text> ; 0 requests a pass, 1 does not, 2 could not tell
    local _lc
    _lc="$(printf '%s' "${1-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')" || return 2
    case "$_lc" in
        *'@codex review'*) return 0 ;;
    esac
    return 1
}

# ── WHAT A `PR_REVIEW_STATE` ANSWER IS ─────────────────────────────────────
#
# `pr-review-state.sh` answers on stdout in one line, and its exit STATUS is not
# the whole answer: a wrapper that truncates stdout, a stale cache, or a misrouted
# call leaves an rc of 0 with a line about another PR, another reviewer or an
# older head — and each of the three callers acts on it as though it were about
# what they asked.
#
# THE SHAPE AND THE IDENTITY WERE WRITTEN OUT TWICE, in `pr-merge-gate.sh` and
# `pr-watch.sh`, and MISSING FROM THE THIRD: `pr-phase-state.sh` re-validated a
# recorded signoff on the status alone. That is the shape this library exists
# for — every field check in it started as two or three copies and every one was
# found missing from at least one. #126.
#
# THEY SET RATHER THAN PRINT, like `rb_identity`: five values through one string
# makes any delimiter a value can contain, and a reviewer login is arbitrary text.
RB_REC_PR=''
RB_REC_SHA=''
RB_REC_WHO=''
RB_REC_VALUE=''
RB_REC_TAIL=''
# THE PATTERN LIVES IN A VARIABLE. Bash 3.2 cannot parse a `[[ =~ ]]` whose
# pattern contains a parenthesis written inline, and one of these callers runs in
# the operator's own shell — which on macOS is that bash.
RB_REC_RX_HEAD='^PR_REVIEW_STATE pr=([0-9]+) sha=([0-9a-f]{7,40}) reviewer=([^[:space:]]+) '

# rb_review_record <line> <field> ; 0 parsed, 1 not a record of that shape
#
# THE WHOLE RECORD, ANCHORED AT BOTH ENDS, not the last `<field>=` token: rc-0
# noise such as `warning: cached state=none` passes a substring match and takes a
# fallback path nobody's answer selected. The FIELD IS NAMED by the caller because
# the two questions have different fields — `state=` and `verdict=` — and a caller
# that got the other one has asked something it is not about to interpret.
#
# THE TAIL IS RETURNED, NOT ACCEPTED. What may follow the value differs per
# question, so each caller states its own rule: `state` allows nothing after it,
# and `verdict` has a grammar of its own. Swallowing it here would accept any
# field anyone ever appends, which is what these checks exist to catch.
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
#
# A WELL-FORMED LINE IS NOT AN ANSWER. A record for another PR, another reviewer
# or an older head matches the shape above perfectly, and the failure it causes is
# silent: the merge gate took the `none` fallback and merged on a recorded signoff
# while the reviewer actually had a body-only CHANGES_REQUESTED on the head, which
# leaves no thread for the unresolved-thread gate to catch.
#
# THE HEAD IS PASSED WHOLE and compared against the record's own width. The field
# is a seven-hex prefix today; every caller wrote `${head:0:7}` at the call site,
# which is a second place for the width to be wrong — and a record that grew to
# forty hex would have been matched on its first seven.
#
# WHAT THAT DOES NOT DO IS RESOLVE A PREFIX COLLISION. A seven-hex record is
# compared at seven, so two heads sharing that prefix both satisfy it; only a
# record carrying more can tell them apart, and none does today. The comparison is
# as strong as the record, and no stronger.
#
# WHAT IT DOES FIX is the other collision: comparing a record to ANOTHER RECORD's
# field cannot tell two commits apart at all when their prefixes agree, while
# comparing both to the one resolved oid this call pinned at least measures them
# against the same thing.
#
# COMPARED AS STRINGS, never with `=~`: a reviewer login ends in `[bot]`, which a
# regex reads as a character class.
rb_review_record_is_about() {   # <pr> <reviewer> <head-oid>
    [ -n "$RB_REC_SHA" ] || return 1
    [ "$RB_REC_PR" = "${1-}" ] || return 1
    [ "$RB_REC_WHO" = "${2-}" ] || return 1
    [ "$RB_REC_SHA" = "${3:0:${#RB_REC_SHA}}" ] || return 1
    return 0
}

# ── THE ONE VERDICT AN OPERATOR CAN ANSWER FOR ─────────────────────────────
#
# A review whose comments are ALL replies reports `verdict=findings` with
# `source=replies-only`: there is nothing for `pr-findings.sh` to list and it is
# not a signoff, because a verdict followed by explanation and a verdict followed
# by a retraction are the same text to anything that reads it. The loop stops and
# a human reads the comment.
#
# WITHOUT AN ESCAPE THAT STOP IS THE END. The verdict can never become clean, so
# no round closes and the merge gate blocks forever — a deadlock traded for a
# permanent pause. The escape is the operator's own record: `pr-signoff.sh`
# carries a head-bound statement from an OWNER, MEMBER or COLLABORATOR.
#
# IT WAS THE MERGE GATE'S ALONE, and `pr-phase-state.sh` reported the same review
# as a dismissal and sent a resumed session to reopen a phase the operator had
# already answered — the deadlock back, one stage earlier. #125.

# rb_replies_only_line <line> <pr> <reviewer> <head-oid> ; 0 if that exact shape
#
# MATCHED IN FULL. A `*` between `findings=` and the suffix accepted an empty
# count and any field anyone appended — `findings= source=replies-only`, or
# `findings=1 extra=x` — and this shape bypasses the status gate and can authorise
# a merge, so it is the last place to be relaxed about a wildcard.
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
    # A replies-only review HAS comments; a zero count is a different record.
    [ "$_n" -ge 1 ] 2>/dev/null || return 1
    return 0
}

# rb_signoff_answers <signoff-line> <answer-deadline> <pr> <reviewer> <head-oid>
#
# A HEAD IS NOT A MOMENT. The signoff has to answer THIS review, and naming the
# same sha does not say that: one recorded for an earlier CLEAN review on an
# unchanged head would vouch for a later replies-only review that nobody read. So
# the record must be NEWER than the review it is answering.
#
# EQUAL IS NOT NEWER. GitHub timestamps are second-resolution, so a tie cannot be
# ordered — and this is permission to merge or to close a phase, so an unorderable
# pair is a refusal rather than a coin toss.
#
# AND THE WHOLE RECORD IS PARSED, not just its suffix. Reading the sha with
# `${line##*sha=}` and looking for a shaped `at=` accepts any rc-0 line that ENDS
# in the right commit — a truncated, cached or misrouted record for another PR or
# another reviewer authorises the merge, which is the same "a well-formed line is
# not an answer" failure `rb_review_record_is_about` exists for.
#
# NEITHER SIDE IS FETCHED HERE. The two callers read the records with their own
# error prefixes and their own statuses; what they share is the RULE, and a
# library that made the network calls would be answering a different question in
# each of them.
#
# THE REASON IS SET RATHER THAN PRINTED, so each caller says it in its own words.
RB_VOUCH_REASON=''
# `verdict-at=` IS PART OF THE SHAPE, and `none` is one of its values: the field
# is always present and says `none` where the record does not carry a time, so
# this reader has one shape to match rather than two. #135.
RB_SIGNOFF_RX='^PR_SIGNOFF pr=([0-9]+) reviewer=([^[:space:]]+) verdict-at=(none|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) at=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) id=([0-9]+) sha=([0-9a-f]{40})$'
rb_signoff_answers() {   # <signoff-line> <answer-deadline> <pr> <reviewer> <head-oid>
    RB_VOUCH_REASON=''
    local _at
    # CANONICAL UTC IS PART OF THE SHAPE, because the comparison below is a STRING
    # one and that is the time order only for this spelling. A value of another
    # shape sorts somewhere arbitrary, and one sorting high would vouch for a
    # review it never saw. A REVOCATION fails here too, and should: `sha=none`
    # is not a commit, and a revocation vouches for nothing.
    [[ "${1-}" =~ $RB_SIGNOFF_RX ]] || { RB_VOUCH_REASON=signoff_malformed; return 1; }
    _at="${BASH_REMATCH[4]}"
    [ "${BASH_REMATCH[1]}" = "${3-}" ] || { RB_VOUCH_REASON=other_pr; return 1; }
    # COMPARED AS A STRING, never with `=~`: a reviewer login ends in `[bot]`,
    # which a regex reads as a character class.
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
#
# WHAT AN OPERATOR'S SIGNOFF HAS TO BE NEWER THAN. A replies-only verdict is
# produced by the COMMENTS on a review, and a reply added afterwards does not move
# the review's `submitted_at` — so ordering against the review alone let a signoff
# recorded between the review and a retracting reply vouch over a reply nobody
# read. Review at T1, signoff at T2, retraction at T3: `T2 > T1` still holds.
#
# THE LATER OF THE TWO, because the signoff has to answer the whole conversation
# and either can be the last thing that happened — a review with no comments has
# only the first, and a reply after the review has the second.
#
# ONLY THE REPLY TIME MAY BE ABSENT, and absent is not zero: it means that
# channel had nothing to say. Both absent is a refusal, because there is then
# nothing for a signoff to answer at all — and a reply time with NO review time is
# unreadable rather than a deadline of its own, for the reason given below.
#
# CANONICAL UTC, CHECKED HERE, because the comparison is a STRING one and that is
# the time order only for this shape. A value of another shape sorts somewhere
# arbitrary, and one sorting low would let a signoff older than the conversation
# vouch for it.
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
    # A REPLY WITHOUT A REVIEW IS NOT A SNAPSHOT, IT IS A CONTRADICTION. Replies
    # hang off a SUBMITTED review, and every submitted review has a validated
    # `submitted_at` — so the reader that answers with a reply time has, by
    # construction, selected a review the other reader must also have found. An
    # empty review time beside a present reply time therefore means one of them
    # was truncated or replaced, and taking the reply as the whole deadline is
    # what hides the later review: a signoff posted after that reply but before
    # the review was submitted would be accepted as answering it.
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
#
# WHAT `pr-review-state.sh escape-snapshot` ANSWERS, read once and read the same
# way by both callers. Peeled with `${…#…}` alone, a line with two fields assigns
# the SECOND value to both times and a line with four hides one — and a non-numeric
# first field is silently discarded, which is the id that proves the two times
# describe one review.
#
# EXACTLY THREE FIELDS, and the tab is what separates them, so the count is
# checked rather than assumed. `[[ =~ ]]` with the pattern in a variable, because
# bash 3.2 cannot parse one containing a parenthesis written inline.
#
# AND BOTH TIMES ARE CANONICAL UTC, not merely present. A successful snapshot is
# always a replies-only review, so it always has both — and an EMPTY reply field
# is the one shape `rb_answer_at` accepts as "that channel had nothing to say",
# which is how a truncated helper hides a newer reply and lets the signoff vouch
# on the review time alone.
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
