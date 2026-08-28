#!/usr/bin/env bash
# The check-state helper: `pr-ci-state.sh`.
#
# Self-contained: `gh` is stubbed, `git` is not consulted (the identity comes
# through REVIEW_BUS_REMOTE), no network. CI has no credentials, so a test that
# reaches GitHub is a broken test.
set -Eeuo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-ci-state.sh"

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

TMP="$(mktemp_d)" || { die "could not create a scratch directory"; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# The stub answers as `gh pr checks … --json bucket --jq …` does: it prints what
# the jq program would have produced, and exits with the status `gh` would use.
# THE STATUS AND THE VALUE ARE SET INDEPENDENTLY, because that is the pairing that
# matters: `gh pr checks` exits non-zero when a check FAILED as well as when one is
# pending or none exists, so a helper that classified on the status alone would
# call a real failure "nothing configured".
#
# The payloads go through FILES rather than being interpolated into the stub. The
# real diagnostic contains single quotes — `no checks reported on the 'main'
# branch` — and embedding it in a quoted `printf` inside a heredoc silently
# dropped them, so the cases that exist to prove the exact message is recognised
# were being handed a message that was not it, and reported the opposite verdict.
mkgh() {   # mkgh <stdout> <stderr> <exit>
    printf '%s' "$1" > "$TMP/gh.out"
    printf '%s' "$2" > "$TMP/gh.err"
    printf '%s' "$3" > "$TMP/gh.rc"
    : > "$TMP/gh.json"
    cat > "$TMP/bin/gh" <<GHSH
#!/usr/bin/env bash
printf '%s' "\$*" >> "$TMP/args"
# THE REAL JQ PROGRAM, run against the payload, whenever one is supplied. A stub
# that simply echoed a verdict tested the script's dispatch and left the jq that
# PRODUCES that verdict entirely uncovered — mutants turning pending into green,
# and the unknown-bucket catch-all into green, both survived the whole suite. The
# mapping is the part with the consequences, so the mapping is run.
# The delimiter is unquoted because the stub needs \$TMP expanded, so nothing in
# this body may carry a backtick: the two that named those mutants were being RUN
# at heredoc time, and the bash 3.2 job is what printed the resulting
# "command not found".
if [ -s "$TMP/gh.json" ]; then
    prog=''
    while [ \$# -gt 0 ]; do
        case "\$1" in --jq) prog="\$2"; shift 2 ;; *) shift ;; esac
    done
    [ -n "\$prog" ] || { echo 'the call passed no --jq program' >&2; exit 99; }
    jq -r "\$prog" < "$TMP/gh.json" || exit 99
    exit "\$(cat "$TMP/gh.rc")"
fi
[ -s "$TMP/gh.out" ] && cat "$TMP/gh.out"
[ -s "$TMP/gh.err" ] && cat "$TMP/gh.err" >&2
exit "\$(cat "$TMP/gh.rc")"
GHSH
    chmod +x "$TMP/bin/gh"
}
# The payload form: the jq in the script decides, not the fixture.
bucket_is() {   # bucket_is <json> <gh exit> <want rc> <want status> <label>
    mkgh '' '' "$2"
    printf '%s' "$1" > "$TMP/gh.json"
    local got rc body
    got="$(run 7)"; rc="${got%%|*}"; body="${got#*|}"
    { [ "$rc" = "$3" ] && grep -qF "status=$4" <<<"$body"; } \
        && pass "$5" \
        || die "$5 — got rc=$rc '$body' (wanted $3 / status=$4)"
}
run() {   # run [args…] ; prints "<rc>|<stdout+stderr>"
    local out rc=0
    : > "$TMP/args"
    # `run_limited … env`, never a PATH on the watchdog. Where GNU `timeout` is
    # missing `run_limited` polls with its own `sleep` and shells out to `mktemp`,
    # and a stubbed PATH on the caller hands it the stubs — the watchdog failing
    # without ever running the subject, with every assertion below passing about
    # nothing. `test-testlib.sh` scans for exactly this, and caught it here.
    out="$(run_limited 30 env PATH="$TMP/bin:$PATH" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" "$@" 2>&1)" || rc=$?
    printf '%s|%s' "$rc" "$out"
}
case_is() {   # case_is <stdout> <stderr> <gh exit> <want rc> <want status> <label>
    mkgh "$1" "$2" "$3"
    local got="$(run 7)" rc body
    rc="${got%%|*}"; body="${got#*|}"
    { [ "$rc" = "$4" ] && grep -qF "status=$5" <<<"$body"; } \
        && pass "$6" \
        || die "$6 — got rc=$rc '$body' (wanted $4 / status=$5)"
}

# ── the buckets map to the verdicts ────────────────────────────────────────
# Run through the script's own jq, against payloads shaped like `gh`'s. `gh` exits
# non-zero for pending and for failure alike, so each case pairs a realistic status
# with a realistic payload.
bucket_is '[{"bucket":"pass"},{"bucket":"pass"}]'    0 0 green   'every check passing is green'
bucket_is '[{"bucket":"pass"},{"bucket":"skipping"}]' 0 0 green  'a skipped check does not withhold green'
bucket_is '[{"bucket":"pass"},{"bucket":"fail"}]'    1 1 failed  'one failing check makes the head red'
bucket_is '[{"bucket":"cancel"}]'                    1 1 failed  'a cancelled check is a failure, not a pass'
bucket_is '[{"bucket":"pass"},{"bucket":"pending"}]' 8 3 pending 'a check still running is pending, never green'
# A failure OUTRANKS a still-running check: waiting for the rest to finish before
# admitting one has already failed is a round closed later on the same red head.
bucket_is '[{"bucket":"pending"},{"bucket":"fail"}]' 8 1 failed  'a failure among pending checks is reported now'
# AN UNRECOGNISED BUCKET IS MALFORMED, not benign. A value outside the set this
# script knows must not reach a catch-all that means green — the shape that let an
# unknown review state be reported as a withdrawal and drive a review loop.
bucket_is '[{"bucket":"pass"},{"bucket":"reticulating"}]' 0 2 error \
        'an unrecognised bucket is an error, not a pass'
# `all(.[]; …)` over an empty stream is `true` by definition, so each of these
# came out as "everything passed" from a SUCCESSFUL read.
bucket_is '[]'               0 2 error 'an empty array is an error, not a pass'
bucket_is '{}'               0 2 error 'an object is an error, not a pass'
bucket_is 'null'             0 2 error 'a null payload is an error, not a pass'
bucket_is '[{"name":"test"}]' 0 2 error 'a record with no bucket is an error, not a pass'

# The same verdicts arriving as values, which is what the script dispatches on.
case_is green   ''  0 0 green   'a green verdict exits 0'
case_is failed  ''  1 1 failed  'a failing check is a failure, not an unreadable probe'
case_is pending ''  8 3 pending 'a pending verdict exits 3'

# ── a payload nothing can be concluded from is an ERROR ────────────────────
# `all(.[]; …)` over an empty stream is `true` by definition, so an object, a null
# or an empty array from a SUCCESSFUL read came out as "everything passed". The jq
# emits a distinguished `malformed` for those, and an unrecognised bucket value
# reaches the same branch rather than falling through a catch-all into green —
# the shape that let an unknown review state be reported as a withdrawal.
case_is malformed '' 0 2 error 'a malformed payload is an error, not a pass'
case_is ''        '' 0 2 error 'an empty answer is an error, not a pass'

# ── "none configured" is not "could not tell" ──────────────────────────────
# `gh pr checks` exits non-zero when there is nothing to report, saying so on
# stderr. Treating every non-zero as unreadable blocked every repository without
# branch protection, permanently: not a fail-closed guard but a gate that never
# opens.
case_is '' "no checks reported on the 'main' branch" 1 4 none \
        'no checks configured is its own verdict'
case_is '' "no required checks reported on the 'main' branch" 1 4 none \
        '…including the wording gh uses with --required'

# ── …and the whole diagnostic is matched, never searched for a phrase ──────
# `gh` has no dedicated status for this case, so the message is the only signal,
# and a substring test accepted it inside a LARGER failure: a run that printed the
# benign line and then failed for an unrelated reason was classified as benign,
# and in the merge gate the administrator merge proceeded with no trusted checks
# result at all.
case_is '' "no required checks reported on the 'main' branch
error: connection reset by peer" 1 2 error \
        'the benign phrase followed by a real error is an error'
case_is '' "warning: no required checks reported on the 'main' branch, and the API call failed" 1 2 error \
        '…and so is the phrase embedded in a larger message'
case_is '' 'some other failure entirely' 1 2 error 'an unrelated failure is an error'
case_is '' '' 1 2 error 'a silent failure is an error'

# ── the call is PINNED, and --required is passed through ───────────────────
# An unpinned `gh pr checks` takes its repository from the working directory or
# from `GH_REPO`, so the answer could come from a different project entirely — the
# gate reporting green about somebody else's checks.
mkgh green '' 0
run 7 >/dev/null
grep -qF -- '--repo github.com/acme/widget' "$TMP/args" \
    && pass "the checks call names the repository it was derived for" \
    || die "the checks call is unpinned: $(cat "$TMP/args")"
grep -qF -- '--required' "$TMP/args" \
    && die "the round-loop form passes --required; it would ignore a failing optional check" \
    || pass "…and without --required, so a failing optional check still counts"
: > "$TMP/args"; run 7 --required >/dev/null
grep -qF -- '--required' "$TMP/args" \
    && pass "…while --required is passed through for the merge gate" \
    || die "--required was dropped: $(cat "$TMP/args")"

# ── green is only green from a probe that SUCCEEDED ────────────────────────
# `gh` can emit a complete, valid green result and then exit non-zero because the
# request failed part-way, and command substitution keeps what it printed. Green
# is the one verdict that opens a gate, so it is the one that may not be taken on
# trust — in the merge gate that is an administrator merge on an untrusted partial
# response. `failed` and `pending` are accepted whatever the status, because both
# are directions the caller stops or waits in.
case_is green   '' 1 2 error   'green from a probe that then failed is an error'
case_is failed  '' 0 1 failed  'a failure verdict is trusted whatever the status'
case_is pending '' 0 3 pending 'a pending verdict is trusted whatever the status'

# ── the checks are asked about a COMMIT, not just a PR ─────────────────────
# `gh pr checks` is addressed by PR number and answers about whatever the API
# currently calls the head — and for a moment after a push that is still the
# PREVIOUS head. A green answer then describes the commit from the round before:
# the last round's answer to this round's question, and it reads as permission to
# close. A mismatch is its own verdict, because the caller's correct response is
# to wait rather than to stop.
WANT=0123456789abcdef0123456789abcdef01234567
OTHER=fedcba9876543210fedcba9876543210fedcba98
# The heads come from a QUEUE, one per `gh pr view`, so a push landing between the
# confirmation and the checks call can be replayed. A stub that answered the same
# head twice could never distinguish "verified before the request" from "bound to
# the request", which is the whole difference the second read exists to make.
mkgh_head() {   # mkgh_head <headRefOid…newline-separated> <rollup bucket | raw JSON>
    printf '%s\n' "$1" > "$TMP/heads"
    # THE ROLLUP IS WHAT THE COMMIT-ADDRESSED PATH READS. A bucket name is turned
    # into the response GitHub really sends, so the helper's own jq is what
    # classifies rather than the stub; a value starting with `{` is passed through
    # verbatim, which is how the malformed shapes below are staged.
    case "$2" in
        '{'*|'['*) printf '%s\n' "$2" > "$TMP/gh.gql" ;;
        green)   printf '{"data":{"repository":{"object":{"statusCheckRollup":{"state":"SUCCESS"}}}}}\n' > "$TMP/gh.gql" ;;
        failed)  printf '{"data":{"repository":{"object":{"statusCheckRollup":{"state":"FAILURE"}}}}}\n' > "$TMP/gh.gql" ;;
        pending) printf '{"data":{"repository":{"object":{"statusCheckRollup":{"state":"PENDING"}}}}}\n' > "$TMP/gh.gql" ;;
        none)    printf '{"data":{"repository":{"object":{"statusCheckRollup":null}}}}\n' > "$TMP/gh.gql" ;;
        *)       printf '{"data":{"repository":{"object":{"statusCheckRollup":{"state":"%s"}}}}}\n' "$2" > "$TMP/gh.gql" ;;
    esac
    printf '' > "$TMP/gh.err"; printf '0' > "$TMP/gh.rc"; : > "$TMP/gh.json"
    cat > "$TMP/bin/gh" <<GHSH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/args"
case "\$*" in
    *graphql*)
        # A COMPLETE-LOOKING ANSWER AND THEN A FAILURE is the case the guard on
        # this read exists for: command substitution keeps what a command printed
        # before it died, so a green body from a failed request would be classified
        # as green without it.
        cat "$TMP/gh.gql"
        if [ -f "$TMP/gh.gql.fail" ]; then
            exit 1
        fi
        exit 0 ;;
    *)
        case "\$2" in
            view)
                h="\$(head -1 "$TMP/heads")"
                # An exhausted queue repeats its last answer; \`tail -n +2\`, not
                # \`sed -i\`, which is GNU-only without a suffix argument.
                if [ "\$(wc -l < "$TMP/heads")" -gt 1 ]; then
                    tail -n +2 "$TMP/heads" > "$TMP/heads.next" && mv "$TMP/heads.next" "$TMP/heads"
                fi
                printf '%s\n' "\$h" ;;
            *)  cat "$TMP/gh.out" ;;
        esac ;;
esac
exit 0
GHSH
    chmod +x "$TMP/bin/gh"
}
mkgh_head "$WANT" green
got="$(run 7 --head "$WANT")"
{ [ "${got%%|*}" = 0 ] && grep -qF 'status=green' <<<"${got#*|}"; } \
    && pass "the checks are read when the PR head is the OID asked about" \
    || die "a matching head was not accepted ('$got')"
mkgh_head "$OTHER" green
got="$(run 7 --head "$WANT")"
{ [ "${got%%|*}" = 5 ] && grep -qF 'status=stale' <<<"${got#*|}"; } \
    && pass "…and a head the API has not caught up with is stale, not green" \
    || die "a green answer about a different head was accepted ('$got')"
# …and the checks were never asked. Reporting stale while still consulting the
# previous head's result leaves the wrong answer available to anything that reads
# stdout rather than the status.
grep -qE 'checks|check-runs|statusCheckRollup|graphql' "$TMP/args" \
    && die "the checks were read for a head that does not match: $(cat "$TMP/args")" \
    || pass "…without reading the checks of the head it found"

# ── THE ALL-CHECKS READ IS ADDRESSED BY THE COMMIT ─────────────────────────
# `gh pr checks` takes a PR number and has no commit selector, so bracketing it
# with head confirmations narrows WHEN a head can move and never binds the answer
# to a commit: an A → B → A completing between the two reads is invisible to both.
# The rollup is addressed by the OID it is asked for, so the answer is about that
# commit and nothing else. #214.
#
# THE ARGUMENT IS ASSERTED, not the verdict alone: a regression to `gh pr checks`
# would still answer green here, and the whole point is WHICH question was asked.
mkgh_head "$WANT" green; : > "$TMP/args"
got="$(run 7 --head "$WANT")"
{ [ "${got%%|*}" = 0 ] && grep -qF 'status=green' <<<"${got#*|}"; } \
    && pass "the all-checks question is answered for a matching head" \
    || die "the commit-addressed read did not report green ('$got')"
grep -qF "statusCheckRollup" "$TMP/args" \
    && pass "…by asking the rollup of that commit rather than the checks of the PR" \
    || die "the all-checks read is not the rollup: $(cat "$TMP/args")"
grep -qF "oid=$WANT" "$TMP/args" \
    && pass "…for the OID it was pinned to" \
    || die "the rollup was not addressed by the commit: $(cat "$TMP/args")"
# …AND FOR THE RIGHT REPOSITORY, ON THE RIGHT SERVER. The stub answers the same
# rollup whatever it is asked, so none of these is covered by the verdict: dropping
# `--hostname` sends an Enterprise checkout to github.com, and a wrong owner or
# repository reads the rollup of a FORK that has the same commit — a green answer
# about a commit nobody is merging.
grep -qF -- '--hostname github.com' "$TMP/args" \
    && pass "…on the host the origin names" \
    || die "the rollup was not pinned to a host: $(cat "$TMP/args")"
grep -qF 'o=acme' "$TMP/args" \
    && pass "…for the owner the origin names" \
    || die "the rollup was not pinned to an owner: $(cat "$TMP/args")"
grep -qF 'r=widget' "$TMP/args" \
    && pass "…and the repository it names" \
    || die "the rollup was not pinned to a repository: $(cat "$TMP/args")"
# …AND THE THREE ARE SENT AS STRINGS. `--field` performs magic conversion, so a
# repository named `123` would be sent as a JSON number against a `String!`
# variable and rejected by the server — this helper reporting the round unreadable
# for that repository alone. An OID of forty digits is the same trap.
grep -qE -- '-F (o|r|oid)=' "$TMP/args" \
    && die "a GraphQL variable is sent with magic conversion: $(cat "$TMP/args")" \
    || pass "…each as a raw string, which is the only shape they can have"
# …AND A NUMERIC REPOSITORY NAME IS THE CASE THAT PROVES IT. `acme/123` is a legal
# repository, and with magic conversion its name reaches a `String!` variable as a
# number: the server rejects the query and this helper reports every round on that
# repository unreadable, while every other repository is fine.
mkgh_head "$WANT" green; : > "$TMP/args"
_num_rc=0
_num_out="$(run_limited 30 env PATH="$TMP/bin:$PATH" \
    REVIEW_BUS_REMOTE='git@github.com:acme/123.git' "$SCRIPT" 7 --head "$WANT" 2>&1)" || _num_rc=$?
{ [ "$_num_rc" = 0 ] && grep -qF 'status=green' <<<"$_num_out"; } \
    && pass "…so a repository whose name is a number is read like any other" \
    || die "a numeric repository name was not readable: rc=$_num_rc '$_num_out'"
grep -qF -- '-f r=123' "$TMP/args" \
    && pass "…with its name sent as the string it is" \
    || die "a numeric repository name was not sent raw: $(cat "$TMP/args")"
# …AND IT IS ONE READ. The two REST endpoints it replaces had to be reconciled
# here, and `--paginate` is not a snapshot: a rerun landing between two pages lets
# a record repeat, or be replaced by one with a fresh id while the count holds.
# Nothing available makes two reads atomic, so a helper that still made them would
# still have that class however well each page validated.
grep -qE 'commits/[0-9a-f]+/(check-runs|status)' "$TMP/args" \
    && die "a paginated commit endpoint is still read: $(cat "$TMP/args")" \
    || pass "…and neither paginated commit endpoint is read at all"
grep -qE '^pr checks|^checks' "$TMP/args" \
    && die "the PR-addressed query is still used for the all-checks question" \
    || pass "…nor the PR-addressed query"

# `--required` KEEPS THE PR-ADDRESSED QUERY, because neither the rollup nor the
# commit endpoints can say which contexts branch protection requires: classic
# protection needs admin and denies with a 404 indistinguishable from "not
# protected", and the ruleset endpoints do not see classic protection at all.
# Measured on #214.
mkgh_head "$WANT" green; : > "$TMP/args"
run 7 --head "$WANT" --required >/dev/null
# THE POSITIVE ASSERTION AS WELL AS THE ABSENCE. "It did not ask for the rollup" is
# also true of an implementation that called a commit endpoint, which cannot
# identify a required context either — so what the call WAS is asserted, with the
# repository it was pinned to.
grep -q "pr checks 7 --repo github.com/acme/widget --required" "$TMP/args" \
    && pass "…while --required asks the PR-addressed query, pinned to the repository" \
    || die "--required did not use the PR-addressed query: $(cat "$TMP/args")"
grep -qF 'statusCheckRollup' "$TMP/args" \
    && die "--required used the rollup, which cannot answer it: $(cat "$TMP/args")" \
    || pass "…and not the rollup, which does not know what is required"

# EVERY VERDICT COMES THROUGH THE HELPER'S OWN CLASSIFIER on this path, so the stub
# returns the response GitHub really sends and the jq is what decides. The states
# are the `StatusState` enum, read from the schema rather than assumed.
for _cv in FAILURE:1:failed ERROR:1:failed PENDING:3:pending EXPECTED:3:pending SUCCESS:0:green; do
    _state="${_cv%%:*}"; _rest="${_cv#*:}"; _rc="${_rest%%:*}"; _st="${_rest#*:}"
    mkgh_head "$WANT" "$_state"
    got="$(run 7 --head "$WANT")"
    { [ "${got%%|*}" = "$_rc" ] && grep -qF "status=$_st" <<<"${got#*|}"; } \
        && pass "…and a $_state rollup is $_st" \
        || die "a $_state rollup gave '$got'"
done
# `EXPECTED` IS PENDING RATHER THAN GREEN, and that is the one above whose direction
# matters most: it is the state of a context branch protection requires that has not
# reported, so reading it as green would merge on a check that never ran.
mkgh_head "$WANT" EXPECTED
got="$(run 7 --head "$WANT")"
grep -qF 'status=green' <<<"${got#*|}" \
    && die "an unreported required context was read as green: '$got'" \
    || pass "…and never green, since that context has not reported"
# AN UNRECOGNISED STATE IS MALFORMED, not benign — the rule `recordlib.sh` records,
# applied to the value this path parses itself.
mkgh_head "$WANT" SURPRISING
got="$(run 7 --head "$WANT")"
[ "${got%%|*}" = 2 ] \
    && pass "…and a state outside the enum is unreadable, not green" \
    || die "an unknown rollup state gave '$got'"

# ── A NULL ROLLUP IS `none`; A NULL OBJECT IS AN ERROR ─────────────────────
# They arrive the same way, with status 0 and no message: a commit with no checks
# at all answers `statusCheckRollup: null`, and an OID this repository does not
# have answers `object: null`. Both were measured against the live API. Reading the
# second as `none` would hand the CI gate "no checks are configured" for a commit
# nobody could find, which is a failed lookup arriving as a benign verdict.
mkgh_head "$WANT" none
got="$(run 7 --head "$WANT")"
{ [ "${got%%|*}" = 4 ] && grep -qF 'status=none' <<<"${got#*|}"; } \
    && pass "a commit with no checks at all is none" \
    || die "a null rollup gave '$got'"
mkgh_head "$WANT" '{"data":{"repository":{"object":null}}}'
got="$(run 7 --head "$WANT")"
{ [ "${got%%|*}" = 2 ] && grep -qF 'status=error' <<<"${got#*|}"; } \
    && pass "…while a commit the repository does not have is an error" \
    || die "an unknown commit was read as an answer: '$got'"
grep -qF 'status=none' <<<"${got#*|}" \
    && die "…and it emitted the benign verdict anyway: '$got'" \
    || pass "…and did not emit the benign verdict beside the refusal"
# …AND EVERY OTHER SHAPE THAT IS NOT AN ANSWER. A GraphQL error body arrives with
# HTTP 200, and a truncated one parses; each of these would otherwise walk a path
# that is absent and come out as the benign verdict.
for _bad in \
    '{"errors":[{"message":"Something went wrong"}],"data":null}' \
    '{"data":null}' \
    '{"data":{}}' \
    '{"data":{"repository":null}}' \
    '{"data":{"repository":{}}}' \
    '{"data":{"repository":{"object":{}}}}' \
    '{"data":{"repository":{"object":{"statusCheckRollup":{}}}}}' \
    '{"data":{"repository":{"object":{"statusCheckRollup":{"state":null}}}}}' \
    '[]' ; do
    mkgh_head "$WANT" "$_bad"
    got="$(run 7 --head "$WANT")"
    # THE CLASSIFIER NAMED IT, rather than jq dying on the way. Both come out as
    # status 2, so asserting the status alone would pass against a walk that
    # crashed on a shape it does not handle — and a crash is one refactor away
    # from being caught and read as something benign.
    { [ "${got%%|*}" = 2 ] && grep -qF 'out=malformed' <<<"${got#*|}"; } \
        && pass "…and a body that answers nothing is refused by name" \
        || die "'$_bad' was read as an answer: '$got'"
    grep -qE 'status=(none|green)' <<<"${got#*|}" \
        && die "…and a verdict was emitted beside the refusal: '$got'" \
        || pass "…with no verdict beside the refusal"
done

# ── A GREEN ANSWER FROM A FAILED REQUEST IS NOT GREEN ──────────────────────
# `gh` can print a complete, valid body and then exit non-zero because the request
# failed part-way, and command substitution keeps what it printed. The read takes
# its status for that reason, and without this case deleting that guard leaves the
# suite green while a failed fetch opens the merge gate.
mkgh_head "$WANT" green
: > "$TMP/gh.gql.fail"
got="$(run 7 --head "$WANT")"
rm -f "$TMP/gh.gql.fail"
{ [ "${got%%|*}" = 2 ] && grep -qF 'status=error' <<<"${got#*|}"; } \
    && pass "…and a green body from a failed request is an error, not green" \
    || die "a failed request that printed green gave '$got'"

# …AND A PUSH LANDING DURING THE CHECKS REQUEST IS CAUGHT. Confirming the head only
# BEFORE the request leaves a window: the answer then describes a commit nobody
# verified, and in the round loop a head that had almost finished earning its grace
# hands that grace to a different commit whose own checks are not registered yet.
mkgh_head "$WANT
$OTHER" green
got="$(run 7 --head "$WANT")"
{ [ "${got%%|*}" = 5 ] && grep -qF 'moved=during_checks' <<<"${got#*|}"; } \
    && pass "a head that moves during the checks request is stale, not green" \
    || die "a green answer about a head that moved mid-request was accepted ('$got')"

# A head that is not a full OID is an error either way round: one the caller
# supplied, and one `gh` printed before failing.
mkgh_head "$WANT" green
got="$(run 7 --head not-a-sha)"
[ "${got%%|*}" = 2 ] \
    && pass "an OID the caller supplied is shape-checked" \
    || die "a malformed --head value was accepted ('$got')"
mkgh_head 'deadbeef' green
got="$(run 7 --head "$WANT")"
[ "${got%%|*}" = 2 ] \
    && pass "…and so is the one the API returned" \
    || die "a malformed head from the API was accepted ('$got')"
got="$(run 7 --head)"
[ "${got%%|*}" = 2 ] \
    && pass "…and --head with no value is usage, not an unpinned check" \
    || die "--head with no value silently unpinned the check ('$got')"

# ── the diagnostic survives the NO-`timeout` path ──────────────────────────
# Every case above runs wherever GNU `timeout` exists, which is the arm of
# `run_limited` that hands stdout and stderr straight through. Stock macOS has no
# `timeout`, and the fallback used to fold the bounded command's stderr into its
# stdout — so this script's own `2>` capture received nothing, the exact-message
# branch could never fire, and a repository with no checks blocked every round and
# every merge on that platform alone.
#
# The PATH is reduced to a directory with no `timeout` in it, which is the only
# way to reach that arm on a machine that has one.
NOTO="$TMP/noto"; mkdir -p "$NOTO"
# `dirname`, `jq` and the rest are here because the script resolves its own
# directory and parses with them — a PATH missing those fails long before the
# branch under test, which is a fixture proving the fixture.
for b in bash sh sleep date true false kill sed grep printf env mktemp rm cat head tail wc dirname jq pwd; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$NOTO/$b"
done
[ ! -e "$NOTO/timeout" ] \
    && pass "the no-timeout fixture really has no timeout to find" \
    || die "the fixture linked a timeout in; it would test the wrong arm"
mkgh '' "no checks reported on the 'main' branch" 1
ln -sf "$TMP/bin/gh" "$NOTO/gh"
noto_rc=0
noto_out="$(run_limited 30 env PATH="$NOTO" REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    "$SCRIPT" 7 2>&1)" || noto_rc=$?
{ [ "$noto_rc" -eq 4 ] && grep -qF 'status=none' <<<"$noto_out"; } \
    && pass "…and 'no checks configured' is still recognised without GNU timeout" \
    || die "the none-configured diagnostic was lost on the fallback path (rc=$noto_rc '$noto_out')"

# ── a probe that hangs is stopped, not waited on ───────────────────────────
# A `gh` call that never returns on a dead connection makes the CALLER's timeout
# meaningless: the round gate cannot reach its own deadline check, so the
# documented bound is not a bound and both round-closing paths hang. Each probe
# runs under its own watchdog.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nsleep 300\n' "$TMP/args" > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
hang_rc=0
hang_out="$(run_limited 30 env PATH="$TMP/bin:$PATH" PR_CI_PROBE_TIMEOUT=2 \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" 7 2>&1)" || hang_rc=$?
# 124 is the fixture's OWN watchdog killing the run — which is the failure, not
# the result: it means the script never stopped by itself.
{ [ "$hang_rc" -eq 2 ] && grep -q 'status=error' <<<"$hang_out"; } \
    && pass "a probe that hangs is stopped by the script's own watchdog" \
    || die "a hung probe was waited on (rc=$hang_rc '$hang_out')"
# …and the same holds for the head lookup, which is a separate call.
: > "$TMP/args"
hang_rc=0
hang_out="$(run_limited 30 env PATH="$TMP/bin:$PATH" PR_CI_PROBE_TIMEOUT=2 \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" 7 \
    --head 0123456789abcdef0123456789abcdef01234567 2>&1)" || hang_rc=$?
{ [ "$hang_rc" -eq 2 ] && grep -q 'reason=head_unreadable' <<<"$hang_out"; } \
    && pass "…including the head lookup that precedes it" \
    || die "a hung head lookup was waited on (rc=$hang_rc '$hang_out')"
# A malformed bound falls back to the default rather than removing the watchdog.
# THE WATCHDOG ONLY HAS TO OUTLAST THE BOUND THE BAD VALUE WOULD HAVE SET.
#
# Being killed by the fixture's watchdog is the correct outcome: the default is
# 60s, so a run that is still going when the watchdog fires proves the bad value
# did not become the bound. But the watchdog was 20s for every case and the cases
# waited all of it — eighty seconds of the suite spent proving four fallbacks.
#
# What each case has to outlast is the bound its own value WOULD have set if the
# guard were removed:
#
#   0, notanumber → arithmetic reads them as zero or errors, so the deadline is
#                    already spent and the script reports it AT ONCE. Three seconds
#                    is far more than enough to tell that from a run still going.
#   ''             → defended by a DIFFERENT line, and the case is here for that
#                    one. `${PR_CI_PROBE_TIMEOUT:-60}` substitutes on empty, so
#                    the guard below never sees it and removing the guard leaves a
#                    sixty-second deadline untouched. Its mutation is `:-` to `-`;
#                    with that, the empty value reaches arithmetic, reads as zero,
#                    and the case fails at three seconds like the others.
#   007              → Bash reads it as octal SEVEN, so the failure mode returns
#                       at about seven seconds. A three-second watchdog could not
#                       tell that from the fallback, so this one keeps ten.
# TWO LOOPS, EACH WITH A LITERAL BOUND. `run_limited` takes its seconds as a
# literal — `test-testlib.sh` scans for anything else as environment prefixed onto
# the watchdog rather than onto the subject, which is a real defect it exists to
# catch, so the bound is not lifted into a variable to save three lines.
for bad in 0 '' notanumber; do
    : > "$TMP/args"
    b_rc=0
    b_out="$(run_limited 3 env PATH="$TMP/bin:$PATH" PR_CI_PROBE_TIMEOUT="$bad" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" 7 2>&1)" || b_rc=$?
    [ "$b_rc" -eq 124 ] \
        && pass "PR_CI_PROBE_TIMEOUT='$bad' falls back rather than becoming the bound" \
        || die "PR_CI_PROBE_TIMEOUT='$bad' was used as the bound (rc=$b_rc)"
done
# `007` NEEDS THE LONGER ONE. Bash reads it as octal SEVEN, so if the guard were
# removed the run would end at about seven seconds on its own — and a three-second
# watchdog could not tell that from the sixty-second fallback still running.
: > "$TMP/args"
b_rc=0
b_out="$(run_limited 10 env PATH="$TMP/bin:$PATH" PR_CI_PROBE_TIMEOUT=007 \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" 7 2>&1)" || b_rc=$?
[ "$b_rc" -eq 124 ] \
    && pass "PR_CI_PROBE_TIMEOUT='007' falls back rather than becoming the bound" \
    || die "PR_CI_PROBE_TIMEOUT='007' was used as the bound (rc=$b_rc)"

# ── a `none` diagnostic from a probe that DIED is not a verdict ────────────
# `gh` reports "nothing to report" by exiting 1 with that message on stderr. A
# probe that printed the same message and then HUNG carries identical text and
# means something else entirely — and `none` is accepted by the round gate after
# its grace and by the merge gate at once, so ignoring the status turned a hung
# request into merge permission.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nprintf "no checks reported on the '"'"'main'"'"' branch\\n" >&2\nsleep 300\n' \
    "$TMP/args" > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
dh_rc=0
dh_out="$(run_limited 30 env PATH="$TMP/bin:$PATH" PR_CI_PROBE_TIMEOUT=2 \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" 7 2>&1)" || dh_rc=$?
{ [ "$dh_rc" -eq 2 ] && ! grep -qF 'status=none' <<<"$dh_out"; } \
    && pass "the no-checks message from a probe that then hung is an error, not 'none'" \
    || die "a hung probe was read as 'no checks configured' (rc=$dh_rc '$dh_out')"

# ── the helper's deadline is shared, not granted per call ──────────────────
# Up to three sequential requests are made. Given the full allowance each, a
# five-second budget could be spent three times over — a slow-but-successful head
# lookup, then a checks request that hangs, then a confirmation that hangs — and
# the caller's bound is not a bound. One deadline, decremented.
#
# The stub is slow on its FIRST call and hangs afterwards, so a per-call limit
# would let the run last far longer than the budget. The fixture's own watchdog is
# what would catch that, and being caught by it is the failure.
printf '#!/usr/bin/env bash\nn=0\n[ -f "%s" ] && read -r n < "%s"\nn=$((n + 1))\nprintf "%%s\\n" "$n" > "%s"\nif [ "$n" -eq 1 ]; then sleep 3; printf "0123456789abcdef0123456789abcdef01234567\\n"; exit 0; fi\nsleep 300\n' \
    "$TMP/ghn" "$TMP/ghn" "$TMP/ghn" > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"; : > "$TMP/ghn"
sd_rc=0
# The watchdog is chosen to SEPARATE the two behaviours, not merely to be
# generous: shared, the run ends around six seconds (three slow, then whatever is
# left of the budget); per-call, it would be three plus six and get killed here. A
# twenty-second watchdog let both finish and the case proved nothing.
sd_out="$(run_limited 8 env PATH="$TMP/bin:$PATH" PR_CI_PROBE_TIMEOUT=6 \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" 7 \
    --head 0123456789abcdef0123456789abcdef01234567 2>&1)" || sd_rc=$?
{ [ "$sd_rc" -ne 124 ] && [ "$sd_rc" -ne 0 ]; } \
    && pass "a slow probe followed by a hung one still finishes inside one deadline" \
    || die "the per-call limit outlasted the helper's own budget (rc=$sd_rc)"

# ── an exhausted deadline is refused, not renewed ──────────────────────────
# Clamping a non-positive remainder up to one second granted a fresh allowance to
# every remaining call, each of which can then take that second plus the
# watchdog's five-second escalation: the bound became a floor.
#
# TESTED AS ARITHMETIC, because it cannot be reached through the CLI. Every call
# is already bounded by the remainder, so a call that SUCCEEDS always returns
# before the deadline and leaves something behind — the branch exists for the
# boundary instant, which no stub can land on reliably. A racy fixture that passes
# most of the time is worse than one that says what it covers. The function is
# extracted and driven with a baseline placed in the past.
rb_left_fn="$(sed -n '/^rb_left() {/,/^}/p' "$SCRIPT")"; rbl_rc=$?
{ [ "$rbl_rc" -eq 0 ] && [ -n "$rb_left_fn" ]; } \
    && pass "the remaining-time helper could be extracted" \
    || die "rb_left could not be read out of the script (rc=$rbl_rc)"
for rbl_case in '10:5:refused' '10:20:granted'; do
    age="${rbl_case%%:*}"; rest="${rbl_case#*:}"
    dl="${rest%%:*}"; want="${rest##*:}"
    got="$(bash -c "$rb_left_fn"'
        DEADLINE='"$dl"'
        _RB_T0=$((SECONDS - '"$age"'))
        v="$(rb_left)" && echo "granted:$v" || echo "refused"' 2>&1)"
    case "$got" in
        "$want"*) pass "a deadline $age s old against a ${dl}s budget is $want" ;;
        *) die "a deadline $age s old against a ${dl}s budget gave '$got', wanted $want" ;;
    esac
done

# ── an inherited definition does not satisfy a load check ──────────────────
# Bash exports functions through the environment, so a caller that had run
# `export -f run_limited` leaves one defined here before the `.` — and a library
# that is empty or truncated above the definition still sources SUCCESSFULLY. The
# `type -t` guard then finds the inherited function and reports the library
# loaded: a stale watchdog without the kill behaviour lets a hung `gh` outlive
# every bound this script advertises. The same holds for `sha_reason`.
mkgh green '' 0
# `loadlib.sh` is in this list because the LOADER obeys its own rule. A stale
# loader is the one that can make every other load look clean: it is what clears
# and verifies the rest, so an inherited one satisfying its own check leaves every
# library after it unchecked.
for lib_case in 'loadlib.sh:rb_load:loadlib_empty' \
                'testlib.sh:run_limited:testlib_empty' \
                'recordlib.sh:sha_reason:recordlib_empty'; do
    lib="${lib_case%%:*}"; rest="${lib_case#*:}"
    fn="${rest%%:*}"; want="${rest##*:}"
    rm -rf "$TMP/run"; mkdir -p "$TMP/run"
    for g in "$SELF_DIR"/*.sh; do ln -sf "$g" "$TMP/run/$(basename "$g")"; done
    rm -f "$TMP/run/$lib"; : > "$TMP/run/$lib"
    : > "$TMP/args"
    li_rc=0
    li_out="$(run_limited 30 env PATH="$TMP/bin:$PATH" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        bash -c 'eval "$1() { printf stale; }"
                 export -f "$1"
                 exec "$2" 7' _ "$fn" "$TMP/run/pr-ci-state.sh" 2>&1)" || li_rc=$?
    { [ "$li_rc" -eq 2 ] && grep -qF "reason=$want" <<<"$li_out"; } \
        && pass "an empty $lib is refused even with $fn already defined" \
        || die "an inherited $fn satisfied the $lib load check (rc=$li_rc '$li_out')"
    [ ! -s "$TMP/args" ] \
        && pass "…and nothing was asked with it" \
        || die "a request was made after an inherited $fn: $(cat "$TMP/args")"
done

# ── usage, and an identity that cannot be derived ──────────────────────────
for bad in '' abc 7x --required; do
    got="$(run "$bad")"; rc="${got%%|*}"
    [ "$rc" = 2 ] \
        && pass "'$bad' is refused as usage" \
        || die "'$bad' was accepted (rc=$rc)"
done
mkgh green '' 0
badid="$(run_limited 30 env PATH="$TMP/bin:$PATH" \
    REVIEW_BUS_REMOTE='/srv/mirrors/acme/widget.git' "$SCRIPT" 7 2>&1)" && badid_rc=0 || badid_rc=$?
{ [ "${badid_rc:-0}" -eq 2 ] && grep -q 'origin_has_no_host' <<<"$badid"; } \
    && pass "an origin that names no host is refused before any call is made" \
    || die "a hostless origin was not refused (rc=${badid_rc:-?} '$badid')"
# …and the consequence, not just the status: nothing was asked.
[ ! -s "$TMP/args" ] \
    && pass "…and no request was addressed with it" \
    || die "a request was addressed from a refused identity: $(cat "$TMP/args")"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
