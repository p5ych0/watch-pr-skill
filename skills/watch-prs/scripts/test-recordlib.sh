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
want accept valid_comment_record "$(crec '{created_at:null}')"   "a comment with no created_at is accepted"
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
        FILENAME ~ /recordlib\.sh$/ { next }
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
        /\^\[0-9\]\{4\}-\[0-9\]\{2\}-\[0-9\]\{2\}T/ { print FILENAME ":" FNR ": timestamp shape" }
        /length == 0 then error\("no pages"\)/ { print FILENAME ":" FNR ": page shape" }
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
{ [ "$drc" -eq 0 ] && printf '%s' "$seen" | grep -q 'pr-drifted.sh'; } \
    && pass "…and the scan catches a helper that re-implements one" \
    || die "the drift guard did not catch a planted inline rule (rc=$drc out='$seen')"
# …in the SHELL spelling too. This is the case the first version of the guard
# missed: three helpers already validated a SHA with `case` plus a length test,
# and the scan reported clean because it only knew the jq regex.
{ printf '#!/usr/bin/env bash\n'
  printf 'case "$h" in *[!0-9a-f]*|"") return 1 ;; esac\n'
  printf '[ "${#h}" -eq 40 ] || return 1\n'
} > "$DRIFT/pr-shelldrift.sh"
seen="$(scan_inline_rules "$DRIFT")"; drc2=$?
{ [ "$drc2" -eq 0 ] && printf '%s' "$seen" | grep -q 'pr-shelldrift.sh.*shell'; } \
    && pass "…including the shell spelling of the SHA rule" \
    || die "the drift guard missed a shell-spelled SHA check (rc=$drc2 out='$seen')"
rm -f "$DRIFT/pr-shelldrift.sh"
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
    grep -q 'recordlib.sh' "$f" \
        && pass "$b sources the shared validators" \
        || die "$b no longer sources recordlib.sh"
    grep -q 'RECORDLIB_JQ' "$f" \
        && pass "…and uses them in its jq programs" \
        || die "$b sources the library but never uses RECORDLIB_JQ"
done
grep -q 'recordlib.sh' "$SELF_DIR/pr-watch.sh" \
    && pass "pr-watch.sh sources the shared shape rules" \
    || die "pr-watch.sh no longer sources recordlib.sh"
grep -q 'is_full_sha' "$SELF_DIR/pr-watch.sh" \
    && pass "…and uses is_full_sha rather than its own regex" \
    || die "pr-watch.sh sources the library but validates its own SHAs"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
