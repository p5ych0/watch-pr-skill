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
    # PEELED WITH EXPANSIONS, which is the same removal `SKILL.md`'s phase parser
    # used: `${…%%…}` and `${…#…}` are handled by the parser, so there is no
    # redirection to fail and no `read` to shadow. The empty-input case returns 1
    # having looked at everything there was.
    local _rest="$1" _line _nl='
'
    while [ -n "$_rest" ]; do
        case "$_rest" in
            *"$_nl"*) _line="${_rest%%"$_nl"*}"; _rest="${_rest#*"$_nl"}" ;;
            *)        _line="$_rest"; _rest="" ;;
        esac
        case "$_line" in
            '**Review-Signoff:**'*|'**Review-Signoff-Revoked:**'*|\
            '**Review-Pause-Acknowledged:**'*)
                printf '%s\n' "$_line"
                return 0 ;;
        esac
    done
    return 1
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
