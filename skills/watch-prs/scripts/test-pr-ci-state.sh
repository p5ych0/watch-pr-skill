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
# PRODUCES that verdict entirely uncovered — mutants turning `pending` into
# `green`, and the unknown-bucket catch-all into `green`, both survived the whole
# suite. The mapping is the part with the consequences, so the mapping is run.
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
mkgh_head() {   # mkgh_head <headRefOid> <checks verdict>
    printf '%s' "$1" > "$TMP/head"
    printf '%s' "$2" > "$TMP/gh.out"
    printf '' > "$TMP/gh.err"; printf '0' > "$TMP/gh.rc"; : > "$TMP/gh.json"
    cat > "$TMP/bin/gh" <<GHSH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/args"
case "\$2" in
    view) cat "$TMP/head" ;;
    *)    cat "$TMP/gh.out" ;;
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
grep -q 'checks' "$TMP/args" \
    && die "the checks were read for a head that does not match: $(cat "$TMP/args")" \
    || pass "…without reading the checks of the head it found"
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
