#!/usr/bin/env bash
# Unit tests for recordlib.sh — the shared record validators.
#
# These rules used to live in three places, and every one of them was found
# missing from at least one of those places by review (issue #11). The point of
# the library is that a rule proven here is a rule all three helpers have; the
# point of THIS file is that the rules are actually proven, rather than merely
# centralised.
#
# The second half is a DRIFT GUARD: it fails if a helper re-implements a rule
# inline instead of using the shared definition. Centralising is not a one-time
# act — the same rules were re-added by hand four times before this file existed,
# and nothing but a check stops that happening again.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
. "$SELF_DIR/recordlib.sh" || { echo "FAIL - recordlib.sh could not be sourced"; echo "RESULT: FAIL"; exit 1; }
TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

[ -n "${RECORDLIB_JQ:-}" ] \
    && pass "the library defines RECORDLIB_JQ" \
    || die "RECORDLIB_JQ is empty after sourcing"

SHA40="$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0)"
[ "${#SHA40}" -eq 40 ] || { echo "FAIL - the fixture SHA is ${#SHA40} chars"; echo "RESULT: FAIL"; exit 1; }

# Evaluate one record against one definition. Prints `true`, `false`, or `ERR`.
#
# The STATUS is taken: a jq that fails prints nothing, and an empty result
# compared against "false" would pass every rejection case for the wrong reason —
# a validator suite that accepts a broken validator.
check() {   # check <jq-def> <record-json>
    local out rc
    out="$(printf '%s' "$2" | jq -r "$RECORDLIB_JQ"" $1" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then printf 'ERR'; return 0; fi
    case "$out" in true|false) printf '%s' "$out" ;; *) printf 'ERR' ;; esac
}

want() {    # want <accept|reject> <jq-def> <record-json> <label>
    local got; got="$(check "$2" "$3")"
    case "$1:$got" in
        accept:true)  pass "$4" ;;
        reject:false) pass "$4" ;;
        *:ERR)        die "$4 — the check itself failed (def='$2')" ;;
        accept:false) die "$4 — a valid record was rejected" ;;
        reject:true)  die "$4 — an invalid record was accepted" ;;
    esac
}

rec() {     # rec <field-overrides-as-jq> -> a review record
    jq -c -n --arg sha "$SHA40" '{user:{login:"bot"},id:1,commit_id:$sha,
                                 state:"APPROVED",submitted_at:"2026-01-01T00:00:00Z",
                                 body:"text"} + '"$1"
}

# ── valid_review_record ───────────────────────────────────────────────────
want accept valid_review_record "$(rec '{}')" "a well-formed review record is accepted"
want reject valid_review_record '"not an object"'                  "a non-object is rejected"
want reject valid_review_record "$(rec '{user:"notanobject"}')"    "a non-object user is rejected"
want reject valid_review_record "$(rec '{user:{login:123}}')"      "a non-string login is rejected"
want reject valid_review_record "$(rec '{id:"1"}')"                "a non-numeric id is rejected"
want reject valid_review_record "$(rec '{id:null}')"               "a missing id is rejected"
want reject valid_review_record "$(rec '{commit_id:"abc1234"}')"   "an abbreviated commit_id is rejected"
want reject valid_review_record "$(rec '{commit_id:null}')"        "a null commit_id is rejected"
want reject valid_review_record "$(rec '{commit_id:"ZZZ"}')"       "a non-hex commit_id is rejected"

# The state set. This is the rule that reached two scripts and stopped, so it is
# asserted in both directions rather than only in the direction that was broken.
for st in PENDING APPROVED CHANGES_REQUESTED COMMENTED DISMISSED; do
    want accept valid_review_record "$(rec "{state:\"$st\"}")" "the documented state $st is accepted"
done
for st in '"WIBBLE"' '"approved"' '"APPROVED "' 'null' '123' '""'; do
    want reject valid_review_record "$(rec "{state:$st}")" "the state $st is rejected"
done

# submitted_at: null is a draft in flight and legal; a non-null value must be a
# real instant, because `submitted_at != null` is what makes a record count as a
# submitted review.
want accept valid_review_record "$(rec '{submitted_at:null,state:"PENDING"}')" \
    "a null submitted_at (a draft) is accepted"
for ts in '"zzzz"' '"2026-01-02T00:00:00zzzz"' '"2026-01-02"' '"2026-01-02T00:00:00+01:00"' '123'; do
    want reject valid_review_record "$(rec "{submitted_at:$ts}")" "the timestamp $ts is rejected"
done

want accept valid_review_record "$(rec '{body:null}')"  "a null body is accepted"
want reject valid_review_record "$(rec '{body:123}')"   "a non-string body is rejected"

# ── valid_comment_record ──────────────────────────────────────────────────
crec() { jq -c -n '{user:{login:"bot"},id:2,body:"hello",
                    created_at:"2026-01-01T00:00:00Z"} + '"$1"; }
want accept valid_comment_record "$(crec '{}')"                  "a well-formed comment record is accepted"
want accept valid_comment_record "$(crec '{body:null}')"         "a comment with no body is accepted"
want reject valid_comment_record "$(crec '{created_at:null}')"   "a comment with no created_at is rejected"
want reject valid_comment_record "$(crec '{created_at:"zzzz"}')" "a comment with a junk created_at is rejected"
want reject valid_comment_record "$(crec '{created_at:123}')"    "a comment with a numeric created_at is rejected"
want reject valid_comment_record "$(crec '{id:null}')"           "a comment without an id is rejected"
want reject valid_comment_record "$(crec '{body:123}')"          "a non-string comment body is rejected"
want reject valid_comment_record "$(crec '{created_at:"zzzz"}')" "a junk comment timestamp is rejected"
want reject valid_comment_record '"not an object"'               "a non-object comment is rejected"

# ── pages_or_error ────────────────────────────────────────────────────────
# `jq -s` slurps into an array of PAGES. Empty input slurps to ZERO pages, and
# `.[][]` over an object iterates its VALUES rather than failing — so an errored
# body or an empty read produced "no records", which every caller reads as "no
# findings" or "no rounds yet". Both skip a gate.
# The STATUS is what the callers branch on, so the status is what is asserted.
# Checking only that nothing was printed passes when `error(...)` is replaced by
# `empty` — jq then exits 0 with no output, and `pr-findings.sh blocked-body`
# reads that as an ordinary empty result rather than a failed fetch. Absence of
# output is the symptom; a non-zero exit is the guard.
pages() {   # prints "<rc>:<output>"
    local out rc
    # `-s`, exactly as every caller runs it. Without the slurp this helper did
    # not model the thing under test at all: jq on empty input produces nothing
    # and exits 0, so the "an empty read is an error" case passed on the absence
    # of output while the status it claimed to check was 0 the whole time.
    out="$(printf '%s' "$1" | jq -s -c "$RECORDLIB_JQ"'pages_or_error | [.[][]] | length' 2>/dev/null)"; rc=$?
    printf '%s:%s' "$rc" "$out"
}
# The inputs are PRE-SLURP, exactly what `gh --paginate` writes: one JSON value
# per page, concatenated. My first version passed already-slurped shapes, so an
# error body arrived wrapped in a list and looked like a valid page — the fixture
# testing something the caller never sees.
[ "$(pages '[{"a":1}]')" = "0:1" ] \
    && pass "a well-formed page is counted, with a success status" \
    || die "a valid page gave '$(pages '[{"a":1}]')'"
case "$(pages '')" in
    0:*) die "an empty read exited 0 — a caller reads that as zero records" ;;
    *)   pass "an empty read exits non-zero, not zero records" ;;
esac
case "$(pages '{"message":"Not Found"}')" in
    0:*) die "an error body exited 0 — a caller reads that as zero records" ;;
    *)   pass "an error body exits non-zero, not zero records" ;;
esac
case "$(pages '[] {"message":"Not Found"}')" in
    0:*) die "a mixed page set exited 0 — the non-array page was ignored" ;;
    *)   pass "one non-array page among valid ones still exits non-zero" ;;
esac
[ "$(pages '[]')" = "0:0" ] \
    && pass "a genuinely empty page is zero records, with a success status" \
    || die "an empty page gave '$(pages '[]')'"

# ── is_full_sha, the same rule for shell ──────────────────────────────────
# `pr-watch.sh` validates helper OUTPUT rather than API records, but a head that
# is not a real SHA is the input to every subsequent probe — the same consequence
# by a different route, and it was written out twice there as a Bash regex.
sha_case() {   # <value> <accept|reject> <label>
    if is_full_sha "$1"; then got=accept; else got=reject; fi
    [ "$got" = "$2" ] && pass "is_full_sha: $3" || die "is_full_sha: $3 (got $got, want $2)"
}
sha_case "$SHA40"                                          accept "a 40-hex value"
sha_case "$(printf '0%.0s' 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0)" \
                                                           accept "all zeroes, which is still 40 hex"
sha_case ""                                                reject "an empty value"
sha_case "abc1234"                                         reject "an abbreviation"
sha_case "${SHA40}a"                                       reject "41 characters"
sha_case "${SHA40%?}"                                      reject "39 characters"
sha_case "${SHA40%?}Z"                                     reject "a non-hex character"
sha_case "${SHA40%?}A"                                     reject "uppercase hex, which git does not emit here"
# The value is DATA, not a pattern: `case` with a length test cannot be steered
# by a caller the way an unquoted `[[ =~ ]]` right-hand side can.
sha_case '*'                                               reject "a glob"
sha_case '[0-9a-f]'                                        reject "a bracket expression"

# ── valid_review_comment and opens_a_thread ───────────────────────────────
# The rows hanging off `pulls/N/reviews/<id>/comments`. `in_reply_to_id` says
# whether a comment OPENS a thread or continues one, and that decides whether
# `pr-review-state.sh` counts it as a finding — so its SHAPE decides a merge.
crec() {   # crec <field-overrides-as-jq> -> a review-comment record
    jq -c -n '{user:{login:"bot"},id:1,body:"text",
               created_at:"2026-01-01T00:00:00Z"} + '"$1"
}
want accept valid_review_comment "$(crec '{}')" \
    "a top-level review comment, with no in_reply_to_id, is accepted"
want accept valid_review_comment "$(crec '{in_reply_to_id:42}')" \
    "…and a reply carrying a numeric one is accepted"
# THE MALFORMED SPELLINGS ARE THE POINT. A presence-only test read every one of
# these as "this is a reply" and discarded the row, so a page of them counted zero
# findings — which is `clean`, on a payload nothing could read.
# NULL IS "NO PARENT", NOT A MALFORMED RECORD. github.com omits the key today, so
# a first version rejected null as unreadable — and a host that serialises its
# nullable fields would then have made every ordinary finding page unreadable,
# stopping the watch with rc 2 on every review.
want accept valid_review_comment "$(crec '{in_reply_to_id:null}')" \
    "…and an explicit null, which is the same statement in another serialisation"
want accept opens_a_thread "$(crec '{in_reply_to_id:null}')" \
    "…which opens a thread, exactly as an absent key does"
want reject valid_review_comment "$(crec '{in_reply_to_id:"7"}')" \
    "…and so is a string"
want reject valid_review_comment "$(crec '{in_reply_to_id:{}}')" \
    "…and an object"
want reject valid_review_comment "$(crec '{in_reply_to_id:[42]}')" \
    "…and an array"
# It still inherits everything a comment record must have.
want reject valid_review_comment "$(crec '{created_at:null}')" \
    "…and a review comment with no timestamp is still malformed"
want reject valid_review_comment "$(crec '{user:"notanobject"}')" \
    "…and so is one with no actor"

want accept opens_a_thread "$(crec '{}')" \
    "a comment with no in_reply_to_id opens a thread"
want reject opens_a_thread "$(crec '{in_reply_to_id:42}')" \
    "…and one with a numeric in_reply_to_id does not"

# ── WHAT A READER HONOURS AS A RECORD ─────────────────────────────────────
# Three markers on a PR are control, not prose, and the bodies this loop posts are
# composed from untrusted text — findings, PR descriptions, reviewer comments. A
# body reproducing one publishes it under an identity the readers trust and
# CREATES the record it was describing.
for _mk in '**Review-Signoff:** `who` `sha`' \
           '**Review-Signoff-Revoked:** `who`' \
           '**Review-Pause-Acknowledged:** `who` `10`'; do
    out="$(rb_reserved_marker_line "before
$_mk
after")"; rc=$?
    { [ "$rc" -eq 0 ] && [ "$out" = "$_mk" ]; } \
        && pass "a line the readers honour is named: ${_mk%% *}" \
        || die "${_mk%% *} was not reported (rc=$rc out='$out')"
done
# ANCHORED, LIKE THE READERS. They match at the start of a line, so an indented or
# inline mention is prose — refusing it would stop an author saying what a finding
# was about, which is most of what a round summary is for.
for _ok in '    **Review-Signoff:** `who` `sha`' \
           'see `**Review-Signoff:** x` inline' \
           'Review-Signoff: without the bold' \
           '> **Review-Pause-Acknowledged:** quoted'; do
    out="$(rb_reserved_marker_line "$_ok")"; rc=$?
    [ "$rc" -ne 0 ] \
        && pass "…and prose that only mentions one is left alone: ${_ok:0:24}" \
        || die "prose was refused as a record: '$_ok' -> '$out'"
done
out="$(rb_reserved_marker_line "ordinary prose
across two lines")"; rc=$?
[ "$rc" -ne 0 ] \
    && pass "…and a clean body reports nothing" \
    || die "a clean body was refused: '$out'"
# …AND IT CANNOT SAY "NO MARKER" WITHOUT HAVING LOOKED. The body was read through
# a heredoc, and a heredoc is backed by a TEMPORARY FILE: when one cannot be
# created the redirection fails, the loop never runs, and `return 1` answers
# "clean" about text nothing has scanned. Both callers read that as permission to
# post, so a control line would be published because a filesystem filled up.
# Issue #111.
#
# EVERY VERSION, NOT JUST 3.2. From the sources: 4.4 has no pipe path and always
# writes a temporary file; 5.2 and 5.3 use a pipe only while the body fits the
# system pipe capacity — 4096 bytes here — and fall back to a temporary file above
# it, which a round summary routinely exceeds.
#
# STRUCTURAL, BECAUSE THE FAILURE CANNOT BE STAGED FROM A FIXTURE. An unwritable
# `TMPDIR` does not do it: bash falls back to `/tmp` when `TMPDIR` is unusable,
# measured on 4.4, 5.2 and 5.3 at 100 bytes and at 200 kB. Reproducing it means
# making temp-file creation fail everywhere, which is not something a test may do
# to the machine it runs on. So the property asserted is the one that removes the
# dependency: no redirection at all.
case "$(declare -f rb_reserved_marker_line)" in
    *'<<'*) die "the marker scan reads its input through a redirection, which can fail and answer 'clean'" ;;
    *)      pass "…and the scan uses no redirection, so no temporary file can fail underneath it" ;;
esac
case "$(declare -f rb_reserved_marker_line)" in
    *read*) die "the marker scan uses 'read', a name that can be shadowed" ;;
    *)      pass "…and no 'read', so nothing in the caller's shell can answer for it" ;;
esac
# AND IT SCANS A LARGE BODY IN LINEAR TIME. Peeling a line at a time was the
# first shape and it is quadratic — each iteration copies the whole remaining
# suffix twice — so a newline-heavy phase body stalled the round before anything
# could be posted, which is a worse failure than the one this function exists for.
# Measured before the rewrite: 1,000 lines 0.7s, 5,000 lines 19s, 20,000 lines
# 295s. After it: 2ms, 9ms, 39ms.
#
# A CLEAN BODY IS THE CASE THAT MATTERS, because that is the one every round takes
# and the one peeling was slowest on. The bound is generous — this is a timing
# assertion on a shared machine, and what it has to catch is a return to
# quadratic, not a regression of a few milliseconds.
_big=""
_big="$(_i=0; while [ "$_i" -lt 5000 ]; do printf 'line %s of ordinary prose\n' "$_i"; _i=$((_i+1)); done)"
_t0=$(date +%s)
out="$(rb_reserved_marker_line "$_big")"; rc=$?
_t1=$(date +%s)
[ "$rc" -ne 0 ] \
    && pass "…and a five-thousand-line clean body still reports nothing" \
    || die "a large clean body was refused: '$out'"
[ $((_t1 - _t0)) -lt 10 ] \
    && pass "…in linear time, not the 19 seconds the peeling shape took" \
    || die "the scan took $((_t1 - _t0))s on 5,000 lines; it is quadratic again"

# AND IT STILL FINDS A MARKER WITH `TMPDIR` POINTING NOWHERE. That does not stage
# the failure — bash would fall back to `/tmp` — but it does show the scan needs
# no scratch directory of its own, which a redirection-free implementation gets
# for free and a heredoc never could.
out="$(TMPDIR=/nonexistent-$$-marker-scan rb_reserved_marker_line "prose
**Review-Signoff:** \`who\` \`sha\`")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = '**Review-Signoff:** `who` `sha`' ]; } \
    && pass "…and finds a marker with TMPDIR pointing nowhere" \
    || die "the scan failed with no usable TMPDIR (rc=$rc out='$out')"

# `**Reviewed commit:**` IS NOT IN THE SET, and that is deliberate rather than an
# omission. `pr-round-count.sh` reads it only from a comment whose `.user.login` is
# a reviewer bot and whose body also says it found no major issues, so a body these
# callers post cannot create one — refusing it would stop an author describing the
# footer while preventing nothing.
out="$(rb_reserved_marker_line '**Reviewed commit:** `0123456789`')"; rc=$?
[ "$rc" -ne 0 ] \
    && pass "…and a marker no caller-posted body can create is left alone" \
    || die "the reviewed-commit footer was refused: '$out'"

# THE FIRST ONE IS REPORTED, so the author is told which line to fix rather than
# that something somewhere is wrong.
out="$(rb_reserved_marker_line "**Review-Signoff:** \`who\` \`sha\`
**Review-Pause-Acknowledged:** \`who\` \`10\`")"
[ "$out" = '**Review-Signoff:** `who` `sha`' ] \
    && pass "…and the earlier line wins whichever marker it is, not the first in the list" \
    || die "the list order decided instead of the body order: '$out'"
out="$(rb_reserved_marker_line "**Review-Pause-Acknowledged:** \`who\` \`10\`
**Review-Signoff:** \`who\` \`sha\`")"
[ "$out" = '**Review-Pause-Acknowledged:** `who` `10`' ] \
    && pass "…naming the first offending line, not merely that there was one" \
    || die "the reported line was '$out'"

# A FENCE IS NOT A WAY ROUND IT, and the advice must not pretend otherwise. The
# readers scan the raw comment body, where a line inside a fence still starts at
# column 0 — the fence is markup to a renderer and nothing to a regex.
out="$(rb_reserved_marker_line '```
**Review-Signoff:** `who` `sha`
```')"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = '**Review-Signoff:** `who` `sha`' ]; } \
    && pass "…and a marker inside a fence is still refused, since the readers never see the fence" \
    || die "a fenced marker was allowed through (rc=$rc out='$out')"

# ── WHAT REQUESTS A REVIEW ────────────────────────────────────────────────
# A comment CONTAINING `@codex review` is a Codex request — anywhere in it, not
# only at the start of a line. Two callers post a body with no request intended,
# so a quoted mention starts a pass nobody asked for.
for _t in 'please @codex review this' \
          'the finding said to post `@codex review` afterwards' \
          'and then @CODEX REVIEW happens' \
          'trailing @Codex Review'; do
    rb_review_trigger "$_t"; rc=$?
    [ "$rc" -eq 0 ] \
        && pass "text that would request a pass is reported: ${_t:0:28}" \
        || die "a trigger was missed (rc=$rc): '$_t'"
done
for _t in 'codex review without the at' \
          'ordinary prose about the loop' \
          '@codex, review this later' \
          '@codexreview'; do
    rb_review_trigger "$_t"; rc=$?
    [ "$rc" -eq 1 ] \
        && pass "…and text that would not is left alone: ${_t:0:28}" \
        || die "a non-trigger was reported (rc=$rc): '$_t'"
done
# THE THREE ANSWERS ARE DISTINGUISHED, because a caller that cannot tell must stop
# rather than post. `0` requests, `1` does not, and anything else is unknown.
rb_review_trigger ""; rc=$?
[ "$rc" -eq 1 ] \
    && pass "…and empty text requests nothing" \
    || die "empty text gave rc=$rc"

# ── the drift guard ───────────────────────────────────────────────────────
# Centralising is not a one-time act. Each of these rules was re-implemented by
# hand in a second and third script before this library existed, and every one of
# those copies was found missing a rule the others had. A comment asking people
# not to do it again is not a check.
#
# One `awk` pass, one status: a `grep` pipeline here could fail with no output,
# and no output is exactly what "no helper re-implements a rule" looks like.
scan_inline_rules() {   # <dir> ; prints offenders; 2 if the scan failed
    local dir="$1" errf out rc msg mrc
    errf="$(mktemp)" || return 2
    rc=0
    out="$(awk '
        # EXACT basename, not a suffix. `/recordlib\.sh$/` also matches a helper
        # named `pr-recordlib.sh` — which the `pr-*.sh` glob below feeds straight
        # into this scan — so such a file could re-implement every shared rule
        # while the guard reported clean. The exemption is for one file, so it
        # names one file.
        { _base = FILENAME; sub(/^.*\//, "", _base) }
        _base == "recordlib.sh" { next }
        /^[[:space:]]*#/ { next }
        /IN\("PENDING","APPROVED"/          { print FILENAME ":" FNR ": state set" }
        /\^\[0-9a-f\]\{40\}\$/              { print FILENAME ":" FNR ": commit_id shape (jq)" }
        # …and the SHELL spelling of the same rule. The first version of this
        # guard recognised only the jq regex, and reported success while three
        # helpers re-implemented the SHA check as a `case` plus a length test —
        # the very duplication it exists to remove, invisible because it was
        # written a different way. A guard that matches one spelling of a
        # duplicated rule has not found the duplication.
        /\*\[!0-9a-f\]\*/                    { print FILENAME ":" FNR ": commit_id shape (shell case)" }
        /\$\{#[A-Za-z_]+\}" -(eq|ne) 40/      { print FILENAME ":" FNR ": commit_id length (shell)" }
        # …and the reply/finding distinction. A helper asking this inline is one
        # that has stopped VALIDATING the field, which is exactly how a malformed
        # value became a silent "clean".
        /has\("in_reply_to_id"\)/           { print FILENAME ":" FNR ": reply shape" }
        /\^\[0-9\]\{4\}-\[0-9\]\{2\}-\[0-9\]\{2\}T/ { print FILENAME ":" FNR ": timestamp shape" }
        /length == 0 then error\("no pages"\)/ { print FILENAME ":" FNR ": page shape" }
        # …and the reserved-marker rule. Two scripts post caller-written bodies,
        # which is exactly the shape that ends up present in one and missing from
        # the other.
        #
        # MATCHED ON THE SPELLING A COPY WOULD ACTUALLY USE — the quoted literal
        # followed by the glob, as a `case` arm. The first version of this line
        # required the closing `**` to be followed by a single character and then
        # `)`, which the real spelling never is: after `**` comes a quote, then a
        # `*`, then `|` or `)`. It matched nothing, so the guard reported clean
        # against any copy at all — a guard proving its own pattern, not the rule.
        # `pr-round-count.sh` PRINTS the acknowledgement marker as guidance, in
        # double quotes and with no glob, which is why the quote-and-glob shape is
        # what this looks for.
        /'"'"'\*\*(Review-Signoff|Review-Signoff-Revoked|Review-Pause-Acknowledged|Reviewed commit):\*\*'"'"'\*/ { print FILENAME ":" FNR ": reserved marker set" }
        # …and the review trigger. Two callers must refuse it and a third writes
        # it deliberately, which is exactly the split that ends up wrong in one.
        /\*'"'"'@codex review'"'"'\*\)/ { print FILENAME ":" FNR ": review trigger" }
        # …and the `PR_REVIEW_STATE` record shape. It was written out in
        # `pr-merge-gate.sh` and `pr-watch.sh` and was MISSING from
        # `pr-phase-state.sh`, which re-validated a recorded signoff on the exit
        # status alone — so an rc-0 answer that was empty, or about another PR,
        # reviewer or head, read as "the phase still stands". #126.
        /\^PR_REVIEW_STATE pr=/          { print FILENAME ":" FNR ": review record shape" }
        # …AND THE SAME RULE WRITTEN AS A STRING. `pr-merge-gate.sh` did not carry
        # a regex: it REBUILT the line it expected — `local prefix="PR_REVIEW_STATE
        # pr=$PR sha=${2:0:7} …"` — and compared against that. A scan for a regex
        # never sees it, and it pinned the sha to seven hex where every other
        # caller accepted seven to forty.
        #
        # AN ASSIGNMENT, NOT AN EMISSION, and that is the whole of what this can
        # tell apart: `pr-review-state.sh` PRODUCES these lines with `echo` and
        # must keep doing so. Separating a producer from a reconstructor by reading
        # text is the unbounded scanner CLAUDE.md records twice; this catches the
        # shape that actually occurred, in both places it occurred, and does not
        # claim to catch a reconstruction spelled some other way.
        /="PR_REVIEW_STATE pr=/           { print FILENAME ":" FNR ": review record rebuilt as a string" }
        # …and the replies-only shape. Only the merge gate had it, and
        # `pr-phase-state.sh` reported the same review as a dismissal — the
        # deadlock the escape exists to end, one stage earlier. NO APOSTROPHE in
        # this comment: the awk program is a single-quoted shell string, and one
        # here ends it, leaving the rest of the scanner to the shell.
        #
        # The producer PRINTS this field and its line ends `" ;;`; a copy MATCHES
        # it and ends `")`, which is what this looks for.
        / source=replies-only["]\)/       { print FILENAME ":" FNR ": replies-only shape" }
    ' "$dir"/pr-*.sh 2>"$errf")" || rc=$?
    msg="$(cat "$errf" 2>/dev/null)"; mrc=$?
    rm -f "$errf" 2>/dev/null
    [ "$mrc" -eq 0 ] || return 2
    [ "$rc" -eq 0 ] || return 2
    [ -z "$msg" ] || return 2
    printf '%s' "$out"
    return 0
}
inline="$(scan_inline_rules "$SELF_DIR")"; iscan_rc=$?
if [ "$iscan_rc" -ne 0 ]; then
    die "the inline-rule scan could not be completed (rc=$iscan_rc)"
elif [ -n "$inline" ]; then
    die "a helper re-implements a rule recordlib.sh already defines:"
    printf '%s\n' "$inline" | sed 's/^/       /'
else
    pass "no helper re-implements a rule the library defines"
fi
# …and the scan must be able to SEE one, or it is a guard proven on nothing.
DRIFT="$TMP/drift"; mkdir -p "$DRIFT"
printf '#!/usr/bin/env bash\njq %s.state | IN("PENDING","APPROVED","X")%s\n' "'" "'" > "$DRIFT/pr-drifted.sh"
seen="$(scan_inline_rules "$DRIFT")"; drc=$?
{ [ "$drc" -eq 0 ] && grep -q 'pr-drifted.sh' <<<"$seen"; } \
    && pass "…and the scan catches a helper that re-implements one" \
    || die "the drift guard did not catch a planted inline rule (rc=$drc out='$seen')"
# THE MARKER RULE IS PROVED THE SAME WAY. The planted copy uses the same `case`
# spelling `recordlib.sh` does, which is what a helper re-implementing it would
# write — and what the first version of the pattern failed to see.
{ printf '#!/usr/bin/env bash\n'
  printf 'case "$_l" in\n'
  printf "    '**Review-Signoff:**'*|'**Review-Pause-Acknowledged:**'*) return 0 ;;\n"
  printf 'esac\n'
} > "$DRIFT/pr-marker-copy.sh"
seen="$(scan_inline_rules "$DRIFT")"; drc4=$?
{ [ "$drc4" -eq 0 ] && grep -q 'pr-marker-copy.sh' <<<"$seen"; } \
    && pass "…and catches a helper that re-implements the reserved-marker set" \
    || die "the drift guard did not catch a planted marker copy (rc=$drc4 out='$seen')"
rm -f "$DRIFT/pr-marker-copy.sh"
{ printf '#!/usr/bin/env bash\n'
  printf 'case "$_b" in\n'
  printf "    *'@codex review'*) return 0 ;;\n"
  printf 'esac\n'
} > "$DRIFT/pr-trigger-copy.sh"
seen="$(scan_inline_rules "$DRIFT")"; drc5=$?
{ [ "$drc5" -eq 0 ] && grep -q 'pr-trigger-copy.sh' <<<"$seen"; } \
    && pass "…and catches a helper that re-implements the review trigger" \
    || die "the drift guard did not catch a planted trigger copy (rc=$drc5 out='$seen')"
rm -f "$DRIFT/pr-trigger-copy.sh"
{ printf '#!/usr/bin/env bash\n'
  printf "rx='^PR_REVIEW_STATE pr=([0-9]+) sha=([0-9a-f]{7,40}) reviewer=([^[:space:]]+) state=([a-z]+)\$'\n"
} > "$DRIFT/pr-record-copy.sh"
seen="$(scan_inline_rules "$DRIFT")"; drc6=$?
{ [ "$drc6" -eq 0 ] && grep -q 'pr-record-copy.sh' <<<"$seen"; } \
    && pass "…and catches a helper that re-implements the review-record shape" \
    || die "the drift guard did not catch a planted record copy (rc=$drc6 out='$seen')"
rm -f "$DRIFT/pr-record-copy.sh"
{ printf '#!/usr/bin/env bash\n'
  printf 'want="PR_REVIEW_STATE pr=$PR sha=${2:0:7} reviewer=$1 verdict=clean findings=0"\n'
} > "$DRIFT/pr-rebuild-copy.sh"
seen="$(scan_inline_rules "$DRIFT")"; drc7=$?
{ [ "$drc7" -eq 0 ] && grep -q 'pr-rebuild-copy.sh' <<<"$seen"; } \
    && pass "…and one that rebuilds the record as a string rather than a regex" \
    || die "the drift guard did not catch a planted rebuild (rc=$drc7 out='$seen')"
rm -f "$DRIFT/pr-rebuild-copy.sh"
# THE PRODUCER IS NOT A COPY. `pr-review-state.sh` writes these lines with `echo`
# and must keep doing so; a guard that could not tell the two apart would be
# unusable rather than strict.
{ printf '#!/usr/bin/env bash\n'
  printf 'echo "PR_REVIEW_STATE pr=$pr sha=$short reviewer=$who verdict=clean findings=0"\n'
} > "$DRIFT/pr-producer.sh"
seen="$(scan_inline_rules "$DRIFT")"; drc8=$?
{ [ "$drc8" -eq 0 ] && ! grep -q 'pr-producer.sh' <<<"$seen"; } \
    && pass "…while a helper that PRINTS a record is left alone" \
    || die "the drift guard flagged the producer (rc=$drc8 out='$seen')"
rm -f "$DRIFT/pr-producer.sh"
{ printf '#!/usr/bin/env bash\n'
  printf 'case "$rest" in\n'
  printf '    *" source=replies-only") ;;\n'
  printf 'esac\n'
} > "$DRIFT/pr-replies-copy.sh"
seen="$(scan_inline_rules "$DRIFT")"; drc9=$?
{ [ "$drc9" -eq 0 ] && grep -q 'pr-replies-copy.sh' <<<"$seen"; } \
    && pass "…and a helper that re-implements the replies-only shape" \
    || die "the drift guard did not catch a planted replies-only copy (rc=$drc9 out='$seen')"
rm -f "$DRIFT/pr-replies-copy.sh"

# A helper whose name merely ENDS in the library's name is scanned, not exempted.
# `pr-recordlib.sh` is matched by the `pr-*.sh` glob and would have been skipped
# by a suffix exemption.
{ printf '#!/usr/bin/env bash\n'
  printf 'case "$h" in *[!0-9a-f]*|"") return 1 ;; esac\n'
} > "$DRIFT/pr-recordlib.sh"
seen="$(scan_inline_rules "$DRIFT")"; drc3=$?
{ [ "$drc3" -eq 0 ] && grep -q 'pr-recordlib.sh' <<<"$seen"; } \
    && pass "a helper merely named like the library is still scanned" \
    || die "pr-recordlib.sh was exempted by a suffix match (rc=$drc3 out='$seen')"
rm -f "$DRIFT/pr-recordlib.sh"

# …in the SHELL spelling too. This is the case the first version of the guard
# missed: three helpers already validated a SHA with `case` plus a length test,
# and the scan reported clean because it only knew the jq regex.
{ printf '#!/usr/bin/env bash\n'
  printf 'case "$h" in *[!0-9a-f]*|"") return 1 ;; esac\n'
  printf '[ "${#h}" -eq 40 ] || return 1\n'
} > "$DRIFT/pr-shelldrift.sh"
seen="$(scan_inline_rules "$DRIFT")"; drc2=$?
{ [ "$drc2" -eq 0 ] && grep -q 'pr-shelldrift.sh.*shell' <<<"$seen"; } \
    && pass "…including the shell spelling of the SHA rule" \
    || die "the drift guard missed a shell-spelled SHA check (rc=$drc2 out='$seen')"
rm -f "$DRIFT/pr-shelldrift.sh"
# …and the reply-shape rule, planted the way a helper would actually write it.
{ printf '#!/usr/bin/env bash\n'
  printf 'jq %s[.[] | select(has("in_reply_to_id") | not)] | length%s\n' "'" "'"
} > "$DRIFT/pr-reply-copy.sh"
seen="$(scan_inline_rules "$DRIFT")"; drc6=$?
{ [ "$drc6" -eq 0 ] && grep -q 'pr-reply-copy.sh' <<<"$seen"; } \
    && pass "…and catches a helper that asks the reply question inline" \
    || die "the drift guard did not catch a planted reply-shape copy (rc=$drc6 out='$seen')"
rm -f "$DRIFT/pr-reply-copy.sh"
# An unreadable file is a failed scan, not a clean one — the same rule the
# library itself encodes, applied to the guard that enforces it.
printf '#!/usr/bin/env bash\n: \n' > "$DRIFT/pr-unreadable.sh"
chmod 000 "$DRIFT/pr-unreadable.sh"
if cat "$DRIFT/pr-unreadable.sh" >/dev/null 2>&1; then
    pass "SKIPPED: this user can read a mode-000 file, so the unreadable case cannot be built"
else
    scan_inline_rules "$DRIFT" >/dev/null 2>&1
    [ "$?" -eq 2 ] \
        && pass "…and a file it cannot read fails the scan rather than passing it" \
        || die "an unreadable helper was reported as carrying no inline rules"
fi

# ── every helper that reads the API actually sources the library ──────────
# A helper that stopped sourcing it would silently go back to whatever its own
# jq happens to do with undefined functions — per call, not here.
for f in "$SELF_DIR"/pr-review-state.sh "$SELF_DIR"/pr-findings.sh "$SELF_DIR"/pr-round-count.sh; do
    b="$(basename "$f")"
    grep -qE 'rb_load .* recordlib ' "$f" \
        && pass "$b sources the shared validators" \
        || die "$b no longer sources recordlib.sh"
    grep -q 'RECORDLIB_JQ' "$f" \
        && pass "…and uses them in its jq programs" \
        || die "$b sources the library but never uses RECORDLIB_JQ"
done
grep -qE 'rb_load .* recordlib ' "$SELF_DIR/pr-watch.sh" \
    && pass "pr-watch.sh sources the shared shape rules" \
    || die "pr-watch.sh no longer sources recordlib.sh"
grep -q 'is_full_sha' "$SELF_DIR/pr-watch.sh" \
    && pass "…and uses is_full_sha rather than its own regex" \
    || die "pr-watch.sh sources the library but validates its own SHAs"

# ── A TRUNCATED LIBRARY MUST NOT LEAVE THE SECOND CONSTANT INHERITABLE ──────
# `rb_load` clears before it sources, and it is called once PER SYMBOL. A caller
# that verified only `RB_CODEX_BOT` accepted a `recordlib.sh` truncated after that
# definition — and an exported `RB_COPILOT_BOT` from the environment was then
# taken for library data, so a merge gate would validate a signoff from whatever
# account that variable named.
trunc="$(mktemp_d)" || { die "no scratch directory for the truncated-library probe"; trunc=""; }
if [ -n "$trunc" ]; then
    cp "$SELF_DIR/loadlib.sh" "$trunc/"
    # Everything up to and including the Codex login, and nothing after it.
    awk '/^RB_CODEX_BOT=/ { print; exit } { print }' "$SELF_DIR/recordlib.sh" > "$trunc/recordlib.sh"
    tr_out="$(run_limited 15 env RB_COPILOT_BOT='attacker[bot]' bash -c '
        . "$1/loadlib.sh"
        rb_load "$1" recordlib RB_COPILOT_BOT "PR_X status=error" var || exit 2
        printf "%s" "$RB_COPILOT_BOT"' _ "$trunc" 2>&1)"; tr_rc=$?
    { [ "$tr_rc" -ne 0 ] && ! grep -q 'attacker' <<<"$tr_out"; } \
        && pass "a library truncated before the second constant is refused, not inherited" \
        || die "an inherited RB_COPILOT_BOT survived a truncated library (rc=$tr_rc '$tr_out')"
    rm -rf "$trunc"
fi

# ── WHAT A `PR_REVIEW_STATE` ANSWER IS ─────────────────────────────────────
# The shape and the identity check were written out in `pr-merge-gate.sh` and
# `pr-watch.sh` and were missing from `pr-phase-state.sh`. #126.
H40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
O40=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
BOT='chatgpt-codex-connector[bot]'
rb_review_record "PR_REVIEW_STATE pr=7 sha=aaaaaaa reviewer=$BOT state=reviewed" state \
    && [ "$RB_REC_PR" = 7 ] && [ "$RB_REC_SHA" = aaaaaaa ] \
    && [ "$RB_REC_WHO" = "$BOT" ] && [ "$RB_REC_VALUE" = reviewed ] && [ -z "$RB_REC_TAIL" ] \
    && pass "a state record parses into its five parts" \
    || die "a well-formed state record did not parse (pr='$RB_REC_PR' sha='$RB_REC_SHA' who='$RB_REC_WHO' val='$RB_REC_VALUE' tail='$RB_REC_TAIL')"
# THE TAIL IS RETURNED, NOT ACCEPTED: what may follow differs per question, so
# each caller states its own rule. A library that swallowed it would accept any
# field anyone ever appends.
rb_review_record "PR_REVIEW_STATE pr=7 sha=aaaaaaa reviewer=$BOT verdict=clean findings=0" verdict \
    && [ "$RB_REC_VALUE" = clean ] && [ "$RB_REC_TAIL" = " findings=0" ] \
    && pass "…and a verdict record hands its tail back rather than accepting it" \
    || die "the verdict tail was not returned (val='$RB_REC_VALUE' tail='$RB_REC_TAIL')"
# THE FIELD IS NAMED BY THE CALLER, because the two questions have different ones
# and a caller that got the other has asked something it is not about to read.
rb_review_record "PR_REVIEW_STATE pr=7 sha=aaaaaaa reviewer=$BOT state=reviewed" verdict \
    && die "a state record was accepted as a verdict" \
    || pass "…and a record of the other field is refused"
# ANCHORED AT BOTH ENDS. rc-0 noise such as `warning: cached state=none` passes a
# substring match and takes a fallback path nobody's answer selected.
rb_review_record "warning: cached PR_REVIEW_STATE pr=7 sha=aaaaaaa reviewer=$BOT state=none" state \
    && die "a record with text before it was accepted" \
    || pass "…and noise before the record is refused"
rb_review_record "" state \
    && die "an empty line parsed as a record" \
    || pass "…and an empty line is refused"
# AND THE PARSE LEAVES NOTHING BEHIND when it fails: a caller that checked the
# status and then read the variables would otherwise act on the PREVIOUS record.
{ [ -z "$RB_REC_PR" ] && [ -z "$RB_REC_SHA" ] && [ -z "$RB_REC_WHO" ] \
    && [ -z "$RB_REC_VALUE" ] && [ -z "$RB_REC_TAIL" ]; } \
    && pass "…with every field cleared, so a failed parse cannot leave the last one standing" \
    || die "a failed parse left values behind (pr='$RB_REC_PR' sha='$RB_REC_SHA')"
# A WELL-FORMED LINE IS NOT AN ANSWER. The head is passed WHOLE and compared
# against the record's own width, so the `${head:0:7}` every caller wrote is gone.
rb_review_record "PR_REVIEW_STATE pr=7 sha=aaaaaaa reviewer=$BOT verdict=clean findings=0" verdict \
    || die "the identity fixture's record did not parse"
rb_review_record_is_about 7 "$BOT" "$H40" \
    && pass "a record is about the pr, reviewer and head it names" \
    || die "a matching record was rejected"
rb_review_record_is_about 8 "$BOT" "$H40" \
    && die "a record for another PR was accepted" \
    || pass "…and not about another PR"
rb_review_record_is_about 7 'copilot-pull-request-reviewer[bot]' "$H40" \
    && die "a record for another reviewer was accepted" \
    || pass "…nor another reviewer, compared as a string since the login ends in [bot]"
rb_review_record_is_about 7 "$BOT" "$O40" \
    && die "a record for another head was accepted" \
    || pass "…nor another head"
# THE FULL WIDTH IS COMPARED WHERE THE RECORD CARRIES IT, so a record that grew to
# forty hex is not matched on its first seven.
rb_review_record "PR_REVIEW_STATE pr=7 sha=$H40 reviewer=$BOT verdict=clean findings=0" verdict \
    && rb_review_record_is_about 7 "$BOT" "$H40" \
    && pass "…and a forty-hex record is compared at forty" \
    || die "a forty-hex record did not match its own head"
rb_review_record "PR_REVIEW_STATE pr=7 sha=aaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb reviewer=$BOT verdict=clean findings=0" verdict \
    && rb_review_record_is_about 7 "$BOT" "$H40" \
    && die "a forty-hex record matched on its first seven" \
    || pass "…and one that only shares its first seven does not"

# ── THE ONE VERDICT AN OPERATOR CAN ANSWER FOR ─────────────────────────────
# The shape and the ordering were the merge gate's alone, and `pr-phase-state.sh`
# reported the same review as a dismissal. #125.
RO="PR_REVIEW_STATE pr=7 sha=aaaaaaa reviewer=$BOT verdict=findings findings=1 source=replies-only"
rb_replies_only_line "$RO" 7 "$BOT" "$H40" \
    && pass "a replies-only record is recognised" \
    || die "a well-formed replies-only record was not recognised"
rb_replies_only_line "$RO" 8 "$BOT" "$H40" \
    && die "a replies-only record for another PR was accepted" \
    || pass "…and not one about another PR"
rb_replies_only_line "$RO" 7 "$BOT" "$O40" \
    && die "a replies-only record for another head was accepted" \
    || pass "…nor another head"
# MATCHED IN FULL. A `*` between `findings=` and the suffix accepted an empty
# count and any field anyone appended, and this shape can authorise a merge.
for _bad in "verdict=findings findings= source=replies-only" \
            "verdict=findings findings=1 extra=x source=replies-only" \
            "verdict=findings findings=0 source=replies-only" \
            "verdict=findings findings=1 source=replies-only trailing" \
            "verdict=clean findings=0"; do
    rb_replies_only_line "PR_REVIEW_STATE pr=7 sha=aaaaaaa reviewer=$BOT $_bad" 7 "$BOT" "$H40" \
        && die "the replies-only shape accepted '$_bad'" \
        || pass "…and refuses '$_bad'"
done
# A HEAD IS NOT A MOMENT: the signoff must be NEWER than the review it answers,
# or one recorded for an earlier clean review vouches for a later replies-only one.
SO="PR_SIGNOFF pr=7 reviewer=$BOT verdict-at=none at=2026-01-02T00:00:00Z id=901 sha=$H40"
rb_signoff_answers "$SO" 2026-01-01T00:00:00Z 7 "$BOT" "$H40" \
    && pass "a signoff recorded after the review answers it" \
    || die "a newer signoff did not vouch (reason='$RB_VOUCH_REASON')"
rb_signoff_answers "$SO" 2026-01-03T00:00:00Z 7 "$BOT" "$H40" \
    && die "a signoff older than the review vouched for it" \
    || { [ "$RB_VOUCH_REASON" = not_after ] \
        && pass "…and one recorded before it does not, saying so" \
        || die "an older signoff gave reason '$RB_VOUCH_REASON'"; }
# EQUAL IS NOT NEWER: second-resolution timestamps cannot order a tie, and this is
# permission to merge.
rb_signoff_answers "$SO" 2026-01-02T00:00:00Z 7 "$BOT" "$H40" \
    && die "a same-second signoff was ordered" \
    || pass "…and a tie cannot be ordered, so it refuses"
# THE WHOLE RECORD IS PARSED, NOT ITS SUFFIX. Reading the sha with `${line##*sha=}`
# and looking for a shaped `at=` accepts any rc-0 line that ENDS in the right
# commit, so a truncated, cached or misrouted record for another PR or another
# reviewer authorised the merge.
rb_signoff_answers "$SO" 2026-01-01T00:00:00Z 7 "$BOT" "$O40" \
    && die "a signoff naming another head vouched" \
    || { [ "$RB_VOUCH_REASON" = other_head ] \
        && pass "…and one naming another head does not" \
        || die "another head gave reason '$RB_VOUCH_REASON'"; }
rb_signoff_answers "$SO" 2026-01-01T00:00:00Z 8 "$BOT" "$H40" \
    && die "a signoff for another PR vouched" \
    || { [ "$RB_VOUCH_REASON" = other_pr ] \
        && pass "…nor one for another PR" \
        || die "another PR gave reason '$RB_VOUCH_REASON'"; }
rb_signoff_answers "$SO" 2026-01-01T00:00:00Z 7 'copilot-pull-request-reviewer[bot]' "$H40" \
    && die "a signoff for another reviewer vouched" \
    || { [ "$RB_VOUCH_REASON" = other_reviewer ] \
        && pass "…nor one for another reviewer with the same head" \
        || die "another reviewer gave reason '$RB_VOUCH_REASON'"; }
rb_signoff_answers "$SO" "" 7 "$BOT" "$H40" \
    && die "a signoff vouched with no review to answer" \
    || { [ "$RB_VOUCH_REASON" = no_review ] \
        && pass "…and there must be a review for it to answer" \
        || die "an absent review gave reason '$RB_VOUCH_REASON'"; }
# A LINE MISSING A FIELD IS NOT A RECORD. `${line#*at=}` on one WITHOUT `at=`
# returns the whole line, and `%% *` then takes its first word — a value that is
# not a time; parsing the record instead refuses it as unreadable.
for _badrec in "PR_SIGNOFF pr=7 reviewer=$BOT verdict-at=none id=901 sha=$H40" \
               "PR_SIGNOFF pr=7 reviewer=$BOT verdict-at=none at=yesterday id=901 sha=$H40" \
               "PR_SIGNOFF pr=7 reviewer=$BOT verdict-at=none at=2026-01-02T00:00:00Z sha=$H40" \
               "PR_SIGNOFF pr=7 reviewer=$BOT verdict-at=none at=2026-01-02T00:00:00Z id=901 sha=aaaaaaa" \
               "warning PR_SIGNOFF pr=7 reviewer=$BOT verdict-at=none at=2026-01-02T00:00:00Z id=901 sha=$H40" \
               "PR_SIGNOFF pr=7 reviewer=$BOT verdict-at=none at=2026-01-02T00:00:00Z id=901 sha=none reason=revoked" \
               "PR_SIGNOFF pr=7 reviewer=$BOT at=2026-01-02T00:00:00Z id=901 sha=$H40" \
               "PR_SIGNOFF pr=7 reviewer=$BOT verdict-at=whenever at=2026-01-02T00:00:00Z id=901 sha=$H40"; do
    rb_signoff_answers "$_badrec" 2026-01-01T00:00:00Z 7 "$BOT" "$H40" \
        && die "a malformed signoff vouched: '$_badrec'" \
        || { [ "$RB_VOUCH_REASON" = signoff_malformed ] \
            && pass "…and refuses a record it cannot read: '${_badrec#PR_SIGNOFF }'" \
            || die "'$_badrec' gave reason '$RB_VOUCH_REASON'"; }
done
# CANONICAL UTC ON THE REVIEW'S SIDE TOO, because these are compared as STRINGS
# and that is the time order only for this shape.
rb_signoff_answers "$SO" tomorrow 7 "$BOT" "$H40" \
    && die "a review time of another shape was compared" \
    || { [ "$RB_VOUCH_REASON" = review_untimed ] \
        && pass "…and a review time of another shape refuses rather than sorting somewhere" \
        || die "an unshaped review time gave reason '$RB_VOUCH_REASON'"; }

# ── WHAT A SIGNOFF HAS TO BE NEWER THAN ────────────────────────────────────
# The review is one moment and the newest reply is another, and either can be the
# last thing that happened. Ordering against the review alone let a signoff
# recorded between it and a retracting reply vouch over a reply nobody read. #129.
rb_answer_at 2026-01-01T00:00:00Z 2026-01-03T00:00:00Z \
    && [ "$RB_ANSWER_AT" = 2026-01-03T00:00:00Z ] \
    && pass "the later of a review and a reply is what a signoff must answer" \
    || die "the reply did not win when it was later (got '$RB_ANSWER_AT')"
rb_answer_at 2026-01-05T00:00:00Z 2026-01-03T00:00:00Z \
    && [ "$RB_ANSWER_AT" = 2026-01-05T00:00:00Z ] \
    && pass "…in both directions, so the reply is not simply preferred" \
    || die "the review did not win when it was later (got '$RB_ANSWER_AT')"
rb_answer_at 2026-01-05T00:00:00Z "" \
    && [ "$RB_ANSWER_AT" = 2026-01-05T00:00:00Z ] \
    && pass "…and an absent reply leaves the review" \
    || die "an absent reply lost the review (got '$RB_ANSWER_AT')"
# A REPLY WITHOUT A REVIEW IS A CONTRADICTION, NOT AN ANSWER. Replies hang off a
# SUBMITTED review and every submitted review has a validated `submitted_at`, so
# the reader that answered with a reply time selected a review the other reader
# must also have found. Taking the reply as the whole deadline is what hides the
# later review: a signoff posted after that reply but before the review was
# submitted would be accepted as answering it.
rb_answer_at "" 2026-01-03T00:00:00Z
[ "$?" -eq 2 ] && [ -z "$RB_ANSWER_AT" ] \
    && pass "…while a reply with no review is unreadable, not a deadline of its own" \
    || die "a reply without a review produced '$RB_ANSWER_AT'"
# BOTH ABSENT IS A REFUSAL, because there is then nothing for a signoff to answer.
rb_answer_at "" ""
[ "$?" -eq 1 ] && [ -z "$RB_ANSWER_AT" ] \
    && pass "…and with neither there is nothing to answer" \
    || die "two absent times produced '$RB_ANSWER_AT'"
# A SHAPE IT CANNOT PLACE IS A DIFFERENT STATUS AGAIN, because the comparison is a
# STRING one: a value of another shape sorts somewhere arbitrary, and one sorting
# low would let a signoff older than the conversation vouch for it.
rb_answer_at yesterday 2026-01-03T00:00:00Z
[ "$?" -eq 2 ] && pass "…and a review time of another shape is refused, not sorted" \
    || die "an unshaped review time was accepted"
rb_answer_at 2026-01-01T00:00:00Z tomorrow
[ "$?" -eq 2 ] && pass "…on the reply's side too" \
    || die "an unshaped reply time was accepted"

# ── WHAT AN ESCAPE SNAPSHOT IS ─────────────────────────────────────────────
# Both callers read the same answer, and peeling it with `${…#…}` alone assigned
# the SECOND value to both times when a field was missing, hid one when there was
# an extra, and dropped a non-numeric id in silence — the id being what proves the
# two times describe one review. #133.
SNAP="$(printf '77\t2026-01-01T00:00:00Z\t2026-01-05T00:00:00Z')"
rb_escape_snapshot "$SNAP" \
    && [ "$RB_SNAP_ID" = 77 ] \
    && [ "$RB_SNAP_REVIEW_AT" = 2026-01-01T00:00:00Z ] \
    && [ "$RB_SNAP_REPLY_AT" = 2026-01-05T00:00:00Z ] \
    && pass "an escape snapshot parses into its three fields" \
    || die "a well-formed snapshot did not parse (id='$RB_SNAP_ID' review='$RB_SNAP_REVIEW_AT' reply='$RB_SNAP_REPLY_AT')"
for _badsnap in "$(printf '2026-01-01T00:00:00Z\t2026-01-05T00:00:00Z')" \
                "$(printf '77\t2026-01-01T00:00:00Z')" \
                "$(printf '77\t2026-01-01T00:00:00Z\t2026-01-05T00:00:00Z\textra')" \
                "$(printf 'warning\t2026-01-01T00:00:00Z\t2026-01-05T00:00:00Z')" \
                "$(printf '77\t2026-01-01T00:00:00Z\t')" \
                "$(printf '77\t\t2026-01-05T00:00:00Z')" \
                "$(printf '77\t2026-01-01T00:00:00Z\twhenever')" \
                "77 2026-01-01T00:00:00Z 2026-01-05T00:00:00Z" \
                ""; do
    rb_escape_snapshot "$_badsnap" \
        && die "a malformed snapshot parsed: '$_badsnap'" \
        || pass "…and one without three fields, a numeric id and two canonical times does not"
done
# AND A FAILED PARSE LEAVES NOTHING BEHIND, so a caller that checked the status
# and then read the fields cannot act on the previous snapshot.
{ [ -z "$RB_SNAP_ID" ] && [ -z "$RB_SNAP_REVIEW_AT" ] && [ -z "$RB_SNAP_REPLY_AT" ]; } \
    && pass "…with every field cleared" \
    || die "a failed snapshot parse left values behind (id='$RB_SNAP_ID')"


if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
