#!/usr/bin/env bash
# Unit tests for pr-selfcheck.sh.
#
# A pre-push checker that cannot catch the bug it was written for is worse than
# none: it converts an unverified assumption into a green tick. So the first case
# here reproduces the actual P1 — `$SUMMARY_FILE` used in SKILL.md and assigned
# nowhere — and requires the finding.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# `mktemp_d`: a bare `mktemp -d` that fails leaves $TMP empty and the cleanup
# trap then runs `rm -rf` over paths at the filesystem root.
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-selfcheck.sh"
TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# A throwaway plugin tree: SKILL.md plus a scripts/ directory.
mkroot() {   # mkroot <skill-body>
    local r="$TMP/root"
    rm -rf "$r"; mkdir -p "$r/skills/watch-prs/scripts"
    printf '%s\n' "$1" > "$r/skills/watch-prs/SKILL.md"
    printf '%s\n' "$r"
}
addscript() {  # addscript <root> <name> <body>
    printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/skills/watch-prs/scripts/$2"
    chmod +x "$1/skills/watch-prs/scripts/$2"
}
# A passing test so the suite check is satisfied unless a case breaks it.
addtest() {    # addtest <root> <name>
    printf '#!/usr/bin/env bash\nexit 0\n' > "$1/skills/watch-prs/scripts/$2"
    chmod +x "$1/skills/watch-prs/scripts/$2"
}

OK_SKILL='# skill
```bash
OWNER=acme
REPO=widget
RB_SCRIPTS=/tmp/s
SUMMARY_FILE="$(mktemp)"
echo "$OWNER/$REPO $RB_SCRIPTS $SUMMARY_FILE"
```
'

# ── the clean case is clean ────────────────────────────────────────────────
R="$(mkroot "$OK_SKILL")"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'status=clean'; } \
    && pass "a well-formed tree reports clean" \
    || die "clean tree gave rc=$rc out='$out'"

# ── THE CASE IT EXISTS FOR: a variable used and never assigned ─────────────
# This is the P1 from round 19 of PR #10, reduced.
R="$(mkroot '# skill
```bash
OWNER=acme
echo "$OWNER"
gh pr comment N --body "$(cat "$SUMMARY_FILE")"
```
')"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'undefined_variable'; } \
    && pass "a variable used and never assigned is a finding" \
    || die "undefined \$SUMMARY_FILE was not caught (rc=$rc out='$out')"
printf '%s' "$out" | grep -q 'SUMMARY_FILE' \
    && pass "…and the finding names it" \
    || die "the finding does not name the variable: $out"

# An assignment mentioned INSIDE a quoted string is not an assignment. The first
# version of this check accepted `NAME=` after any whitespace, so the identity
# block's own `echo "… SUMMARY_FILE=$SUMMARY_FILE"` made every name in it look
# assigned — including the one the check was written to catch.
R="$(mkroot '# skill
```bash
OWNER=acme
echo "OWNER=$OWNER SUMMARY_FILE=$SUMMARY_FILE"
```
')"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'SUMMARY_FILE'; } \
    && pass "a name appearing only inside an echo string is not an assignment" \
    || die "echo-string mention counted as an assignment (rc=$rc out='$out')"

# ── jq and GraphQL variables are not shell variables ───────────────────────
# They live in single-quoted programs spanning several lines. Reporting them
# would make the checker noise, and noise is how a checker gets ignored.
R="$(mkroot '# skill
```bash
OWNER=acme
gh api graphql -f query='"'"'
  query($owner:String!,$cursor:String){repository(owner:$owner){x(after:$cursor){y}}}'"'"' \
  | jq '"'"'.data as $n | if ($n | type) != "array" then error("x") else [ $n[] ] end'"'"'
echo "$OWNER"
```
')"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
    && pass "jq and GraphQL variables are not reported as undefined shell variables" \
    || die "jq/GraphQL variables were reported (rc=$rc out='$out')"

# ── a script that does not parse ───────────────────────────────────────────
R="$(mkroot "$OK_SKILL")"
addscript "$R" pr-broken.sh 'if [ 1 -eq 1 ]; then echo yes'   # no fi
addtest "$R" test-pr-broken.sh
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'syntax_error'; } \
    && pass "a script that does not parse is a finding" \
    || die "unparseable script not caught (rc=$rc out='$out')"

# ── a variable assigned by a SOURCED library is assigned ───────────────────
# `rb_identity` SETS `HOST`, `OWNER` and `REPO` rather than printing them, so
# after SKILL.md moved to the shared parser those names had no assignment in the
# skill's own text and every one of them was reported undefined. The check was
# wrong about the skill, not the skill about itself — and a check that fires on
# correct code is a check that gets switched off.
LIB_SKILL='# skill
```bash
RB_SCRIPTS=/tmp/s
. "$RB_SCRIPTS/identitylib.sh"
rb_identity
echo "$HOST/$OWNER/$REPO"
```
'
R="$(mkroot "$LIB_SKILL")"
# Written as a real library is: assignments at the start of a line and after a
# `;`, which are the two positions the scan recognises. A `{ HOST=h; … }`
# one-liner would be missed — the same deliberate narrowness as the skill's own
# scan, and in the same safe direction, since the result is a loud false finding
# rather than a silent gap.
addscript "$R" identitylib.sh '# rb-assigns: HOST OWNER REPO
rb_identity() {
    HOST=h; OWNER=o
    REPO=r
}'
addtest "$R" test-identitylib.sh
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'status=clean'; } \
    && pass "a variable assigned by a sourced library is not reported undefined" \
    || die "a sourced library assignment was not seen (rc=$rc out=$out)"

# …and the reach is BOUNDED to what the library actually assigns. A branch that
# simply suppressed every unassigned name once any library was sourced would pass
# the case above while removing the check this whole script exists for.
BOUND_SKILL='# skill
```bash
RB_SCRIPTS=/tmp/s
. "$RB_SCRIPTS/identitylib.sh"
rb_identity
echo "$HOST $SUMMARY_FILE"
```
'
R="$(mkroot "$BOUND_SKILL")"
addscript "$R" identitylib.sh '# rb-assigns: HOST
rb_identity() { HOST=h; }'
addtest "$R" test-identitylib.sh
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'SUMMARY_FILE'; } \
    && pass "…and a name no library assigns is still a finding" \
    || die "sourcing a library suppressed an unrelated undefined variable (rc=$rc out=$out)"

# …and ONLY WHAT THE LIBRARY DECLARES. Sourcing defines a library's functions; it
# does not run their bodies, and within a body an assignment can sit after a
# `return` or inside a branch nothing takes. Every attempt to infer which ones a
# call actually performs was wrong in the quiet direction — `$TOKEN` looked
# assigned and the gate reported clean over a value the driver expands and nothing
# sets. The library states what it sets instead, and the body is not consulted:
# the fixture below assigns `TOKEN` in a called function and still expects the
# finding, because `TOKEN` is not declared.
UNCALLED_SKILL='# skill
```bash
RB_SCRIPTS=/tmp/s
. "$RB_SCRIPTS/identitylib.sh"
rb_identity
echo "$HOST $TOKEN"
```
'
R="$(mkroot "$UNCALLED_SKILL")"
addscript "$R" identitylib.sh '# rb-assigns: HOST
rb_identity() {
    HOST=h
    return 0
    TOKEN=x
}
unused() {
    TOKEN=x
}'
addtest "$R" test-identitylib.sh
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'TOKEN'; } \
    && pass "an undeclared name is not credited, wherever the body assigns it" \
    || die "a never-executed assignment was credited (rc=$rc out=$out)"
# …and the called function's assignment still is, so the rule is about reachability
# and not about being inside a function at all.
printf '%s' "$out" | grep -q 'uses \$HOST' \
    && die "an assignment in a function the skill DOES call was dropped: $out" \
    || pass "…while a called function's assignment still is"

# ── a sourced library that DECLARES NOTHING is an error ────────────────────
# Crediting nothing would reinstate exactly the false findings the declaration
# removes, and report them as defects in the skill rather than in the library that
# forgot to say what it sets.
R="$(mkroot "$LIB_SKILL")"
addscript "$R" identitylib.sh 'rb_identity() {
    HOST=h; OWNER=o; REPO=r
}'
addtest "$R" test-identitylib.sh
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'reason=lib_declares_no_assignments'; } \
    && pass "a sourced library that declares no assignments is an error" \
    || die "an undeclared library did not fail closed (rc=$rc out=$out)"

# ── a sourced library that is not there is an ERROR, not an empty set ──────
# An unreadable library yielding "no assignments" reinstates exactly the false
# findings the branch above removes, and reports them as defects in the skill.
# Wrong in both directions and silent in both, so it fails closed instead.
R="$(mkroot "$LIB_SKILL")"
addtest "$R" test-identitylib.sh
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'reason=sourced_lib_missing'; } \
    && pass "a library SKILL.md sources but does not ship is an error" \
    || die "a missing sourced library did not fail closed (rc=$rc out=$out)"

# ── a shared library with no matching test ────────────────────────────────
# The gate listed the libraries it covered, so `identitylib.sh` — added after that
# list was written, and the file that decides which repository every `gh` call
# addresses — sat outside it: deleting its test left the check reporting that
# every shared library has one. The libraries are discovered now, and this is the
# fixture that says so.
LIBTEST_SKILL='# skill
```bash
OWNER=acme
REPO=widget
RB_SCRIPTS=/tmp/s
echo "$OWNER/$REPO $RB_SCRIPTS"
```
'
R="$(mkroot "$LIBTEST_SKILL")"
addscript "$R" widgetlib.sh 'true'
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'untested_script.*widgetlib'; } \
    && pass "a shared library with no matching test is a finding" \
    || die "an untested library was not reported (rc=$rc out=$out)"
# …and adding the test clears it, so the finding tracks the missing test rather
# than the mere presence of a library.
addtest "$R" test-widgetlib.sh
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'status=clean'; } \
    && pass "…and shipping its test clears the finding" \
    || die "an untested-library finding survived its test being added (rc=$rc out=$out)"

# ── a helper SKILL.md drives but does not ship ─────────────────────────────
R="$(mkroot '# skill
```bash
RB_SCRIPTS=/tmp/s
"$RB_SCRIPTS"/pr-nonexistent.sh 7
```
')"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'missing_script'; } \
    && pass "a helper driven but not shipped is a finding" \
    || die "missing helper not caught (rc=$rc out='$out')"

# ── a script with no test ──────────────────────────────────────────────────
R="$(mkroot "$OK_SKILL")"
addscript "$R" pr-lonely.sh 'exit 0'
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'untested_script'; } \
    && pass "a script with no matching test is a finding" \
    || die "untested script not caught (rc=$rc out='$out')"

# ── the SHARED LIBRARIES need tests too ────────────────────────────────────
# The check globbed only `pr-*.sh`, so `testlib.sh` and `recordlib.sh` — the two
# highest-leverage files in the tree — were the ones it could not see. A bug in
# either is a bug in every helper at once, which is the argument for extracting
# them and exactly why they cannot be the untested part.
#
# Asserted per library and in both directions: without its test the run must
# report `untested_script`, and adding the test must clear it. Without the second
# half, a check that flagged everything would satisfy the first.
for lib in testlib.sh recordlib.sh; do
    base="${lib%.sh}"
    R="$(mkroot "$OK_SKILL")"
    printf '#!/usr/bin/env bash\n: \n' > "$R/skills/watch-prs/scripts/$lib"
    out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
    { [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'untested_script'; } \
        && pass "$lib with no matching test is a finding" \
        || die "$lib was not required to have a test (rc=$rc out='$out')"
    printf '%s' "$out" | grep -q "$base" \
        && pass "…and the finding names it" \
        || die "the finding did not name $lib: $out"
    printf '#!/usr/bin/env bash\necho "RESULT: PASS"\n' > "$R/skills/watch-prs/scripts/test-$base.sh"
    chmod +x "$R/skills/watch-prs/scripts/test-$base.sh"
    out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
    printf '%s' "$out" | grep -q 'untested_script' \
        && die "$lib still reported untested after its test was added: $out" \
        || pass "…and adding test-$base.sh clears it"
done

# ── a failing test ─────────────────────────────────────────────────────────
R="$(mkroot "$OK_SKILL")"
addscript "$R" pr-thing.sh 'exit 0'
printf '#!/usr/bin/env bash\nexit 1\n' > "$R/skills/watch-prs/scripts/test-pr-thing.sh"
chmod +x "$R/skills/watch-prs/scripts/test-pr-thing.sh"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'failing_test'; } \
    && pass "a failing test is a finding" \
    || die "failing test not caught (rc=$rc out='$out')"
# AND IT NAMES THE FILE. The suite runs concurrently now, so the name no longer
# comes from the loop variable of the thing being run — it is carried back out of
# a runner that is writing several files' results into one stream. A finding that
# says only "a test fails" would satisfy the assertion above.
printf '%s' "$out" | grep -q 'test-pr-thing.sh' \
    && pass "…and the finding names which one" \
    || die "the finding did not name test-pr-thing.sh: $out"

# ── two failing tests, both reported ───────────────────────────────────────
# The runner writes each failure as one whole record, which is what makes
# concurrent output safe to read back. One failing file cannot show that.
R="$(mkroot "$OK_SKILL")"
for n in alpha omega; do
    addscript "$R" "pr-$n.sh" 'exit 0'
    printf '#!/usr/bin/env bash\nexit 1\n' > "$R/skills/watch-prs/scripts/test-pr-$n.sh"
    chmod +x "$R/skills/watch-prs/scripts/test-pr-$n.sh"
done
out="$(run_limited 60 "$SCRIPT" "$R" 2>&1)"; rc=$?
{ printf '%s' "$out" | grep -q 'test-pr-alpha.sh' \
    && printf '%s' "$out" | grep -q 'test-pr-omega.sh'; } \
    && pass "two failing tests are both reported" \
    || die "not both failures were reported (rc=$rc out='$out')"

# ── …and reported in the glob's order, not the runner's ────────────────────
# THE RUNNER IS MADE TO REPORT BACKWARDS, rather than the tests being made to
# finish backwards. Two earlier versions tried the latter and neither was sound:
# with both tests exiting immediately the scheduler produced the sorted order by
# itself, and making `alpha` wait on a marker `omega` writes only proves omega's
# SCRIPT got that far — its worker still has to return from `bash` and reach the
# `printf` that emits the record, so alpha's worker can still emit first.
#
# Every one of those attempts was trying to control a race. This does not have
# one: a stub `xargs` consumes the index stream and reports every index as failed
# in DESCENDING order, so the only thing that can put `alpha` before `omega` in
# the output is the gate's own `sort -n`.
REVSTUB="$TMP/revstub"; rm -rf "$REVSTUB"; mkdir -p "$REVSTUB"
cat > "$REVSTUB/xargs" <<'REVSH'
#!/usr/bin/env bash
# The input is read and discarded: what this stub asserts is the PARENT's
# ordering, so what the workers would have done is not part of the question.
# It still reports one record per index, because the parent counts them.
cat >/dev/null
n="$RB_REV_COUNT"
while [ "$n" -ge 1 ]; do printf 'F %s\n' "$n"; n=$((n - 1)); done
exit 0
REVSH
chmod +x "$REVSTUB/xargs"
# The environment goes INSIDE the watchdog, via `env`, rather than being
# prefixed onto it. Where GNU `timeout` is missing — the portable fallback
# this suite exists to support — the watchdog polls with its own `sleep`, so
# a stub directory prefixed onto the caller lands on the watchdog's search
# path as well as the subject's. `test-testlib.sh` enforces that, and
# enforced it against this very line while it was written the other way.
out="$(run_limited 60 env PATH="$REVSTUB:$PATH" RB_REV_COUNT=2 "$SCRIPT" "$R" 2>&1)"; rc=$?
{ printf '%s' "$out" | grep -q 'test-pr-alpha.sh' \
    && printf '%s' "$out" | grep -q 'test-pr-omega.sh'; } \
    && pass "a runner reporting backwards still names both files" \
    || die "the reversed runner lost a failure (rc=$rc out='$out')"
{ printf '%s' "$out" | grep -n 'test-pr-alpha.sh\|test-pr-omega.sh' | head -2 \
    | sed -n '1p' | grep -q 'alpha'; } \
    && pass "…in the glob's order rather than the order they were reported in" \
    || die "the failures were not ordered: $out"
rm -rf "$REVSTUB"

# ── the runner failing is not an empty suite ───────────────────────────────
# THE FAIL-OPEN THIS SECTION IS MOST EXPOSED TO. `xargs` writes the failures to
# stdout, so a runner that cannot start writes NOTHING — and nothing is exactly
# what a clean suite looks like. Unchecked, the gate reports `status=clean` on a
# suite it never ran, which is the outcome every rule in CLAUDE.md § Bash
# conventions exists to make impossible.
#
# The same for the sort: it consumes the failure list, so a sort that dies having
# written nothing erases findings that were already in hand.
BROKEN="$TMP/broken"; mkdir -p "$BROKEN"
REAL_SORT="$(command -v sort)" || die "no sort on PATH"
# THE STUBS ARE SCOPED TO THE STEP UNDER TEST, and that is not fussiness. This
# script sorts and greps in section 1 as well, so a tool that fails for everyone
# aborts long before the suite runs and the case then passes on the wrong `exit 2`
# entirely — which is what the first version of this fixture did.
#
# `xargs` needs no scoping: nothing else here runs it.
printf '#!/usr/bin/env bash\nexit 3\n' > "$BROKEN/xargs"
# `sort` does. It is given the failure list, whose every line is an INDEX — digits
# and nothing else; section 1 sorts variable names, which are not. So the stub
# reads its input and fails only for the one it is aimed at.
cat > "$BROKEN/sort" <<SORTSH
#!/usr/bin/env bash
# NOT \`exec\` INSIDE THE PIPELINE. That replaces the subshell, not this script, so
# the parent went on to the refusal below and every sort failed — including the
# one this stub is meant to let through.
in="\$(cat)"
# The gate's own sort is handed one record per test: a verdict letter, a space,
# and an index. Section 1 sorts variable names, which are not that. Empty input
# passes through, since the clean-tree case sorts an empty list there.
if [ -z "\$in" ] || printf '%s' "\$in" | grep -qv '^[PFM] [0-9][0-9]*\$'; then
    printf '%s' "\$in" | "$REAL_SORT" "\$@"
    exit \$?
fi
exit 3
SORTSH
chmod +x "$BROKEN/xargs" "$BROKEN/sort"

broken_case() {   # broken_case <tool> <expected reason> <make the suite fail?>
    local tool="$1" reason="$2" failing="$3" only out rc
    only="$TMP/only-$tool"; rm -rf "$only"; mkdir -p "$only"
    ln -sf "$BROKEN/$tool" "$only/$tool"
    R="$(mkroot "$OK_SKILL")"
    addscript "$R" pr-thing.sh 'exit 0'
    addtest "$R" test-pr-thing.sh
    # The sort only runs when there IS a failure list to sort.
    [ "$failing" = yes ] && printf '#!/usr/bin/env bash\nexit 1\n' \
        > "$R/skills/watch-prs/scripts/test-pr-thing.sh"
    out="$(PATH="$only:$PATH" "$SCRIPT" "$R" 2>&1)"; rc=$?
    { [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "$reason"; } \
        && pass "a broken $tool fails the check closed rather than reporting clean" \
        || die "a broken $tool did not fail closed (rc=$rc out='$out')"
    printf '%s' "$out" | grep -q 'the whole suite passes' \
        && die "a broken $tool still reported the suite as passing: $out" \
        || pass "…and does not claim the suite passed"
}
broken_case xargs suite_runner_failed no
broken_case sort  suite_sort_failed   yes
rm -rf "$BROKEN"

# ── a checkout path that xargs would rewrite ───────────────────────────────
# `xargs` strips backslashes and quotes from its input unless the records are
# NUL-delimited. A checkout under `watch\prs` then hands every worker a path that
# does not exist, and the gate BLOCKS THE PUSH claiming those tests failed rather
# than admitting it never ran them. The wrong answer and the confident one.
BSROOT="$TMP/back\\slash"
mkdir -p "$BSROOT/skills/watch-prs/scripts" \
    && printf '%s\n' "$OK_SKILL" > "$BSROOT/skills/watch-prs/SKILL.md"
addscript "$BSROOT" pr-thing.sh 'exit 0'
addtest "$BSROOT" test-pr-thing.sh
out="$("$SCRIPT" "$BSROOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'the whole suite passes'; } \
    && pass "a checkout path containing a backslash still runs its tests" \
    || die "the backslash path was not preserved (rc=$rc out='$out')"

# ── a checkout path containing a newline, with a FAILING test in it ────────
# The NUL-delimited input protects the path on the way IN. On the way back the
# channel is the worker's stdout, and a newline in a directory name splits one
# path into two records there — so the gate invents a test name and reports two
# findings where there is one. That is why the runner carries an index rather than
# a path: digits survive every parser on both sides.
#
# It has to be a FAILING test, because a passing one never travels that channel.
NLROOT="$TMP/two
lines"
mkdir -p "$NLROOT/skills/watch-prs/scripts" \
    && printf '%s\n' "$OK_SKILL" > "$NLROOT/skills/watch-prs/SKILL.md"
addscript "$NLROOT" pr-thing.sh 'exit 0'
printf '#!/usr/bin/env bash\nexit 1\n' > "$NLROOT/skills/watch-prs/scripts/test-pr-thing.sh"
chmod +x "$NLROOT/skills/watch-prs/scripts/test-pr-thing.sh"
out="$("$SCRIPT" "$NLROOT" 2>&1)"; rc=$?
nfind="$(printf '%s\n' "$out" | grep -c 'finding=failing_test')" || nfind=0
{ [ "$rc" -eq 1 ] && [ "$nfind" -eq 1 ]; } \
    && pass "a newline in the checkout path is one finding, not two" \
    || die "the newline split the failure record (rc=$rc findings=$nfind out='$out')"
printf '%s' "$out" | grep -q 'test-pr-thing.sh fails' \
    && pass "…and the one it reports is the test that actually failed" \
    || die "the reported name was fabricated: $out"

# ── the degree that actually reaches the runner ────────────────────────────
# OBSERVED, NOT TIMED. The first version of this ran eight one-second files and
# asserted on elapsed seconds. `$SECONDS` has one-second resolution, so an
# unbounded run crossing two ticks reports 2 and passes — the mutant survives
# intermittently, which is worse than no case. And the margin was never there to
# begin with: eight files four-at-a-time is about two seconds, not four.
#
# So the stub records the argument list `xargs` was called with and answers the
# question directly: which `-P` did the gate ask for?
JOBSTUB="$TMP/jobstub"; mkdir -p "$JOBSTUB"
REAL_XARGS="$(command -v xargs)" || die "no xargs on PATH"
cat > "$JOBSTUB/xargs" <<XARGSSH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$RB_JOBS_LOG"
exec "$REAL_XARGS" "\$@"
XARGSSH
chmod +x "$JOBSTUB/xargs"
jobs_case() {   # jobs_case <RB_SUITE_JOBS or "" for unset> <expected -P> <label>
    local want="$2" label="$3" log rc out got
    log="$TMP/jobs.log"; : > "$log"
    R="$(mkroot "$OK_SKILL")"
    addscript "$R" pr-thing.sh 'exit 0'
    addtest "$R" test-pr-thing.sh
    if [ -n "$1" ]; then
        out="$(PATH="$JOBSTUB:$PATH" RB_JOBS_LOG="$log" RB_SUITE_JOBS="$1" "$SCRIPT" "$R" 2>&1)"; rc=$?
    else
        # `env -u`, NOT merely "do not set it". This file runs inside a suite the
        # operator may have started with a degree of their own, and an inherited
        # value would make this case assert THEIR number while claiming to prove
        # the default.
        out="$(PATH="$JOBSTUB:$PATH" RB_JOBS_LOG="$log" env -u RB_SUITE_JOBS "$SCRIPT" "$R" 2>&1)"; rc=$?
    fi
    got="$(grep -o -- '-P [0-9]*' "$log" | head -1)"
    { [ "$rc" -eq 0 ] && [ "$got" = "-P $want" ]; } \
        && pass "$label" \
        || die "$label — got '$got', wanted '-P $want' (rc=$rc out='$out')"
}
jobs_case ""   4 "the default degree is four"
# THE OPERATOR CONTROL IS EXERCISED, not merely exported. Nothing else here would
# notice `suite_jobs` being hard-coded: the fallback case only proves the bound
# stays bounded, and the contract case only proves the name crosses the process
# boundary.
jobs_case 1    1 "…and a valid override reaches the runner"
# `xargs -P 00` is UNLIMITED, and `00` passes any digits-only validation. What
# that defeats is not tidiness — the degree is a load bound, and the cases it
# protects are the timing-sensitive ones this suite has already been bitten by.
jobs_case 00   4 "…while every spelling of zero falls back to the bound"
jobs_case 01   4 "…and so does a leading-zero one, which the documented grammar refuses"
jobs_case soon 4 "…and a value that is not a number at all"
rm -rf "$JOBSTUB"

# ── a TMPDIR containing xargs' replacement token ───────────────────────────
# `-I{}` rewrites its token in EVERY initial argument. The scratch directory was
# passed as one, so a `TMPDIR` of `/tmp/cache{}` handed each worker a path that
# does not exist and the gate refused with `suite_runner_failed` over tests that
# were fine — a mandatory pre-push gate blocking on its own plumbing.
BRACEDIR="$TMP/cache{}"
mkdir -p "$BRACEDIR"
R="$(mkroot "$OK_SKILL")"
addscript "$R" pr-thing.sh 'exit 0'
addtest "$R" test-pr-thing.sh
out="$(TMPDIR="$BRACEDIR" "$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'the whole suite passes'; } \
    && pass "a TMPDIR containing {} does not break the runner" \
    || die "the replacement token in TMPDIR reached the workers (rc=$rc out='$out')"

# ── a runner or sorter that succeeds and says nothing ──────────────────────
# THE SHAPE A STATUS CHECK CANNOT SEE. An inherited `xargs() { return 0; }`
# consumes no input, exits 0 and prints nothing; a no-op `sort` does the same to
# the record list. Both produce EXACTLY what a suite in which nothing failed
# produces, so "no failures reported" and "nothing ran" become the same
# observation — and the gate reports clean having run no tests at all.
#
# What separates them is counting: every worker reports pass or fail, and the
# parent requires one record per file.
noop_case() {   # noop_case <tool> <label>
    local tool="$1" label="$2" only out rc
    only="$TMP/noop-$tool"; rm -rf "$only"; mkdir -p "$only"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$only/$tool"
    chmod +x "$only/$tool"
    R="$(mkroot "$OK_SKILL")"
    addscript "$R" pr-thing.sh 'exit 0'
    addtest "$R" test-pr-thing.sh
    out="$(PATH="$only:$PATH" "$SCRIPT" "$R" 2>&1)"; rc=$?
    { [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'suite_incomplete'; } \
        && pass "$label" \
        || die "$label — rc=$rc out='$out'"
    printf '%s' "$out" | grep -q 'the whole suite passes' \
        && die "$label — it reported the suite as passing: $out" \
        || pass "…and does not claim the suite passed"
    rm -rf "$only"
}
noop_case xargs "a runner that succeeds without running anything is not a clean suite"
noop_case sort  "…and neither is a sorter that discards the records"

# ── a runner that answers for the same file twice ──────────────────────────
# A TOTAL IS NOT A SET. Counting records and comparing the total to the file count
# accepted `P 1` twice with two files — neither test needed to run, and the gate
# reported clean. The records arrive sorted, so the nth must BE index n, which
# rejects a duplicate, a gap, and an out-of-range index with one comparison.
DUPSTUB="$TMP/dupstub"; rm -rf "$DUPSTUB"; mkdir -p "$DUPSTUB"
cat > "$DUPSTUB/xargs" <<'DUPSH'
#!/usr/bin/env bash
cat >/dev/null
printf 'P 1\nP 1\n'
exit 0
DUPSH
chmod +x "$DUPSTUB/xargs"
R="$(mkroot "$OK_SKILL")"
for n in alpha omega; do
    addscript "$R" "pr-$n.sh" 'exit 0'
    addtest "$R" "test-pr-$n.sh"
done
out="$(PATH="$DUPSTUB:$PATH" "$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'suite_record_unexpected'; } \
    && pass "two answers for one file are not two files having run" \
    || die "a duplicated index satisfied the count (rc=$rc out='$out')"
printf '%s' "$out" | grep -q 'the whole suite passes' \
    && die "…and it reported the suite as passing: $out" \
    || pass "…and does not claim the suite passed"
rm -rf "$DUPSTUB"

# ── a failing test that removes itself ─────────────────────────────────────
# The names used to come from a SECOND walk of the directory, taken after the run.
# A test that deletes itself and then fails — `rm "$0"; exit 1` — made that walk
# one entry shorter, so the failing index matched nothing, no finding was
# recorded, and the gate printed clean over a test it had just watched fail.
# Capturing the names before anything runs is what makes the index always
# resolvable.
R="$(mkroot "$OK_SKILL")"
addscript "$R" pr-alpha.sh 'exit 0'
addtest "$R" test-pr-alpha.sh
addscript "$R" pr-zulu.sh 'exit 0'
printf '#!/usr/bin/env bash\nrm "$0"\nexit 1\n' > "$R/skills/watch-prs/scripts/test-pr-zulu.sh"
chmod +x "$R/skills/watch-prs/scripts/test-pr-zulu.sh"
out="$(run_limited 60 "$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'test-pr-zulu.sh fails'; } \
    && pass "a failing test that deleted itself is still reported, by name" \
    || die "a self-deleting failure went unreported (rc=$rc out='$out')"

# ── a test that renames itself while the suite is running ──────────────────
# THE WORKER USED TO RESOLVE AN INDEX AGAINST A FRESH GLOB, which is a second walk
# of the directory and carries the same failure the naming walk did. Run one at a
# time, if the first test renames itself so it sorts after the second and then
# passes, worker 2 re-globs and runs the RENAMED FIRST TEST again: it reports a
# pass, the second test never runs, and a complete set of passes reports clean
# over the failing test nobody executed.
#
# The second test therefore FAILS. A version that skips it reports clean; a
# version that runs the path it was handed reports the failure.
R="$(mkroot "$OK_SKILL")"
addscript "$R" pr-aaa.sh 'exit 0'
addscript "$R" pr-bbb.sh 'exit 0'
cat > "$R/skills/watch-prs/scripts/test-pr-aaa.sh" <<AAASH
#!/usr/bin/env bash
mv "\$0" "\$(dirname "\$0")/test-pr-zzz.sh"
exit 0
AAASH
printf '#!/usr/bin/env bash\nexit 1\n' > "$R/skills/watch-prs/scripts/test-pr-bbb.sh"
chmod +x "$R/skills/watch-prs/scripts/test-pr-aaa.sh" \
         "$R/skills/watch-prs/scripts/test-pr-bbb.sh"
out="$(run_limited 60 env RB_SUITE_JOBS=1 "$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'test-pr-bbb.sh fails'; } \
    && pass "a test that renames itself does not make another one vanish" \
    || die "the renamed test displaced the failing one (rc=$rc out='$out')"

# ── an index that names no file ────────────────────────────────────────────
# The worker finds its own file by walking the same glob the parent walked, so if
# the directory changes in between an index can name nothing. That is neither a
# pass nor a failure, and the only honest answer is that the result cannot be
# attributed. A stub reports the record the worker would emit.
OFFSTUB="$TMP/offstub"; rm -rf "$OFFSTUB"; mkdir -p "$OFFSTUB"
cat > "$OFFSTUB/xargs" <<'OFFSH'
#!/usr/bin/env bash
cat >/dev/null
# IN RANGE. An index outside it is rejected by the range check first, which is
# correct but is a different case — this one is about an index that is expected
# and still names nothing.
printf 'M 1\n'
exit 0
OFFSH
chmod +x "$OFFSTUB/xargs"
R="$(mkroot "$OK_SKILL")"
addscript "$R" pr-thing.sh 'exit 0'
addtest "$R" test-pr-thing.sh
out="$(PATH="$OFFSTUB:$PATH" "$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'suite_index_unmapped'; } \
    && pass "an index that names no file is an error, not a pass" \
    || die "an unmapped index was not refused (rc=$rc out='$out')"
rm -rf "$OFFSTUB"

# ── a repository that is not this plugin is NOT an error ──────────────────
# One installed copy drives every project, so the working repo is usually a
# consumer with no `skills/watch-prs/` tree. Reporting rc 2 there made a
# mandatory pre-push gate block every review round outside this checkout.
UNRELATED="$TMP/unrelated"
mkdir -p "$UNRELATED"; git -C "$UNRELATED" init -q 2>/dev/null
printf 'print("hi")\n' > "$UNRELATED/app.py"
out="$("$SCRIPT" "$UNRELATED" 2>&1)"; rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'status=not_applicable'; } \
    && pass "a repo with no plugin sources reports not_applicable" \
    || die "unrelated repo gave rc=$rc out='$out'"
# EXIT STATUS, not just a line. A distinguished record printed with exit 0 was
# not distinguished at all: the caller branches on the status, so a run that
# checked nothing was identical in control flow to one that checked everything.
[ "$rc" -ne 0 ] \
    && pass "…with its own exit status, not the one that means \"checks passed\"" \
    || die "not_applicable exits 0, which the caller cannot tell from clean"
[ "$rc" -ne 2 ] \
    && pass "…and not the one that means \"could not run\"" \
    || die "not_applicable is indistinguishable from a broken check"

# Run from INSIDE that repo with no argument, which is how SKILL.md invokes it.
out="$(cd "$UNRELATED" && "$SCRIPT" 2>&1)"; rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'status=not_applicable'; } \
    && pass "…and the same holds for the no-argument invocation the contract uses" \
    || die "no-arg run from an unrelated repo gave rc=$rc out='$out'"

# ── a comment cannot switch the check off, whatever keyword it contains ────
# Widening the loop-variable pattern to accept `do|then|else` positions reopened
# the same false negative one round after closing it, because those alternatives
# match inside prose too.
KEYWORD_SKILL='# skill
```bash
OWNER=acme
# then for SUMMARY_FILE in prose
echo "$OWNER"
gh pr comment N --body "$(cat "$SUMMARY_FILE")"
```
'
R="$(mkroot "$KEYWORD_SKILL")"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'SUMMARY_FILE'; } \
    && pass "a comment containing a shell keyword does not define a loop variable" \
    || die "a keyword-bearing comment silenced the check (rc=$rc out='$out')"

# ── a broken extraction is not an empty one ───────────────────────────────
# `set -uo pipefail` does not stop an unchecked assignment, so a failed pipeline
# left the variable empty and the consuming loop found nothing to report —
# status=clean from a run that never established what was used.
BROKEN_BIN="$TMP/brokenbin"; mkdir -p "$BROKEN_BIN"
printf '#!/usr/bin/env bash\nprintf "plausible output\\n"\nexit 2\n' > "$BROKEN_BIN/grep"
chmod +x "$BROKEN_BIN/grep"
R="$(mkroot "$OK_SKILL")"
out="$(PATH="$BROKEN_BIN:$PATH" "$SCRIPT" "$R" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "an extraction that prints and then fails => 2, not clean" \
    || die "broken extraction gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'status=clean' \
    && die "a run whose extraction failed reported clean: $out" \
    || pass "…and never reports clean"

# ── a comment must not be able to switch the check off ────────────────────
# `for NAME` matched anywhere counted NAME as a loop variable, so prose such as
# `# wait for SUMMARY_FILE` silenced the undefined-variable finding — recreating
# the exact false-negative class this checker exists to prevent.
COMMENT_SKILL='# skill
```bash
OWNER=acme
# wait for SUMMARY_FILE to settle before posting
echo "$OWNER"
gh pr comment N --body "$(cat "$SUMMARY_FILE")"
```
'
R="$(mkroot "$COMMENT_SKILL")"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'SUMMARY_FILE'; } \
    && pass "a comment reading for-NAME does not count as defining NAME" \
    || die "a comment silenced the undefined-variable check (rc=$rc out='$out')"

# A real loop variable is still recognised, so the guard does not become noise.
LOOP_SKILL='# skill
```bash
OWNER=acme
for THING in a b c; do echo "$THING $OWNER"; done
```
'
R="$(mkroot "$LOOP_SKILL")"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
printf '%s' "$out" | grep -q 'THING' \
    && die "a real for-loop variable was reported as undefined: $out" \
    || pass "a real for-loop variable is recognised as assigned"
[ "$rc" -eq 0 ] && pass "…and that tree is otherwise clean" || die "loop fixture gave rc=$rc out='$out'"

# ── status 1 is only "no matches" where a grep produced it ────────────────
# One tolerant checker for every pipeline was too broad: `awk`, `sed` and `sort`
# also exit 1 on real errors, and the `blocks` extraction has no grep in it at
# all — so an awk that printed a plausible block and then failed was waved
# through as "nothing matched", and the run continued on partial input.
AWKBIN="$TMP/awkbin"; mkdir -p "$AWKBIN"
printf '#!/usr/bin/env bash\nprintf "OWNER=plausible\\n"\nexit 1\n' > "$AWKBIN/awk"
chmod +x "$AWKBIN/awk"
R="$(mkroot "$OK_SKILL")"
out="$(PATH="$AWKBIN:$PATH" "$SCRIPT" "$R" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "an awk that prints and then exits 1 => 2, not treated as no-matches" \
    || die "awk exiting 1 gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'status=clean' \
    && die "a run whose block extraction failed reported clean: $out" \
    || pass "…and never reports clean"

# ── the helper-discovery list is established before it is trusted ─────────
# Discovering helpers inline in `for ... $(pipeline)` meant a failed pipeline
# produced an empty list, the loop ran zero iterations, and the check reported
# every helper present without establishing which helpers the skill drives.
HELPBIN="$TMP/helpbin"; mkdir -p "$HELPBIN"
REAL_GREP="$(command -v grep)"
cat > "$HELPBIN/grep" <<GREPSH
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in
        *RB_SCRIPTS*) printf 'pr-plausible.sh\n'; exit 2 ;;
    esac
done
exec "$REAL_GREP" "\$@"
GREPSH
chmod +x "$HELPBIN/grep"
R="$(mkroot "$OK_SKILL")"
out="$(PATH="$HELPBIN:$PATH" "$SCRIPT" "$R" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a failed helper-discovery pipeline => 2, not an empty helper list" \
    || die "helper discovery failure gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'status=clean' \
    && die "a run whose helper discovery failed reported clean: $out" \
    || pass "…and never reports clean"

# ── a DOWNSTREAM stage exiting 1 is not "grep found no matches" ───────────
# Under `pipefail` the pipeline status is the rightmost non-zero, so tolerating 1
# for a whole pipeline could not tell whose 1 it was: a `sort` that emitted
# plausible partial output and exited 1 read exactly like grep matching nothing.
SORTBIN="$TMP/sortbin"; mkdir -p "$SORTBIN"
printf '#!/usr/bin/env bash\nprintf "OWNER\\n"\nexit 1\n' > "$SORTBIN/sort"
chmod +x "$SORTBIN/sort"
R="$(mkroot "$OK_SKILL")"
out="$(PATH="$SORTBIN:$PATH" "$SCRIPT" "$R" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a downstream sort that prints and exits 1 => 2, not no-matches" \
    || die "downstream status 1 gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'status=clean' \
    && die "a run whose sort failed reported clean: $out" \
    || pass "…and never reports clean"

# A grep that genuinely matches nothing is still fine — the exception has to
# survive being narrowed, or the check becomes noise on every empty result.
NOMATCH_SKILL='# skill
```bash
OWNER=acme
echo "$OWNER"
```
'
R="$(mkroot "$NOMATCH_SKILL")"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
    && pass "a grep matching nothing is still a clean run" \
    || die "an empty match set was treated as a failure (rc=$rc out='$out')"

# ── a repo-root lookup that prints and THEN fails is not a root ───────────
# `git rev-parse --show-toplevel` can print a plausible directory and then exit
# non-zero, and command substitution keeps it — so the check would scan a tree
# the probe never vouched for and could report clean off a failed read.
ROOTBIN="$TMP/rootbin"; mkdir -p "$ROOTBIN"
REAL_GIT2="$(command -v git)"
cat > "$ROOTBIN/git" <<GITSH
#!/usr/bin/env bash
if [ "\$1" = "rev-parse" ]; then
    printf '%s\n' "\$FAKE_ROOT"
    exit 1
fi
exec "$REAL_GIT2" "\$@"
GITSH
chmod +x "$ROOTBIN/git"
R="$(mkroot "$OK_SKILL")"
# Run with NO argument, which is the invocation the contract uses, from a
# directory whose lookup fails while naming a tree that would otherwise pass.
out="$(cd "$TMP" && PATH="$ROOTBIN:$PATH" FAKE_ROOT="$R" "$SCRIPT" 2>&1)"; rc=$?
# The REASON, not just the status. Without the guard the script still exits 2 —
# it just gets there differently — so an rc-only assertion passes on the
# unguarded code and proves nothing. `repo_root_lookup_failed` is reachable only
# when the lookup's status was actually taken. This is the second fixture in two
# rounds to need this correction.
{ [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'reason=repo_root_lookup_failed'; } \
    && pass "a repo-root lookup that prints and then fails => 2, on its own reason" \
    || die "failed root lookup gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'status=clean' \
    && die "a failed root lookup produced a clean report: $out" \
    || pass "…and never reports clean"

# ── a gh pr call that does not name the repository ────────────────────────
# `GH_REPO` overrides the repository `gh` infers from the checkout, so an
# unpinned call acts on the same-numbered PR somewhere else while every gate
# inspects this one.
UNPINNED_SKILL='# skill
```bash
OWNER=acme
REPO=widget
gh pr comment 7 --body "hello"
```
'
R="$(mkroot "$UNPINNED_SKILL")"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'unpinned_gh_call'; } \
    && pass "a gh pr call without --repo is a finding" \
    || die "unpinned gh call not caught (rc=$rc out='$out')"

PINNED_SKILL='# skill
```bash
OWNER=acme
REPO=widget
gh pr comment 7 --repo $OWNER/$REPO --body "hello"
```
'
R="$(mkroot "$PINNED_SKILL")"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
    && pass "a pinned gh pr call is clean" \
    || die "a pinned gh call was reported (rc=$rc out='$out')"

# Prose quoting a command in backticks is documentation, not a call. Reporting it
# would make the check noise, and noise is how a checker gets ignored.
PROSE_SKILL='The request is `gh pr edit --add-reviewer @copilot`, which is not a comment.

```bash
OWNER=acme
REPO=widget
gh pr edit 7 --repo $OWNER/$REPO --add-reviewer @copilot
```
'
R="$(mkroot "$PROSE_SKILL")"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
    && pass "prose quoting a gh command is not treated as a call" \
    || die "a backticked command in prose was reported (rc=$rc out='$out')"

# A pinned call split across a backslash continuation is still pinned. A per-line
# check reported it as unpinned — and this check gates the push, so a false
# positive here blocks the round rather than merely annoying.
CONT_SKILL='# skill
```bash
OWNER=acme
REPO=widget
gh pr comment 7 \
    --repo $OWNER/$REPO \
    --body "hello"
```
'
R="$(mkroot "$CONT_SKILL")"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
    && pass "a pinned gh call split across a continuation is not reported" \
    || die "a continued pinned call was flagged unpinned (rc=$rc out='$out')"

# …and an UNPINNED continued call is still caught, so joining lines did not
# simply switch the check off.
CONT_BAD='# skill
```bash
OWNER=acme
REPO=widget
gh pr comment 7 \
    --body "hello"
```
'
R="$(mkroot "$CONT_BAD")"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'unpinned_gh_call'; } \
    && pass "an unpinned continued call is still a finding" \
    || die "joining continuations hid an unpinned call (rc=$rc out='$out')"

# `--repo` has to be an ARGUMENT, not text anywhere on the line. A substring test
# passed a call whose BODY merely mentioned it, so `gh` received no repository
# selector while the mandatory gate reported the call pinned.
MISLEADING_SKILL='# skill
```bash
OWNER=acme
REPO=widget
gh pr comment 7 --body "remember --repo when posting"
```
'
R="$(mkroot "$MISLEADING_SKILL")"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'unpinned_gh_call'; } \
    && pass "a body merely mentioning --repo does not count as pinning" \
    || die "a misleading body passed the pin check (rc=$rc out='$out')"

# A pinned call in an ASSIGNMENT must not vouch for an unpinned call beside it.
# A whole-line check found the text and passed the real command, which has no
# selector at all.
MASKING_SKILL='# skill
```bash
OWNER=acme
REPO=widget
BODY="gh pr comment 7 --repo $OWNER/$REPO"; gh pr comment 7 --body "$BODY"
```
'
R="$(mkroot "$MASKING_SKILL")"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'unpinned_gh_call'; } \
    && pass "a pinned assignment does not vouch for an unpinned call on the same line" \
    || die "same-line masking passed the pin check (rc=$rc out='$out')"

# A pinned assignment must not vouch for an unpinned call joined by `&&` either.
# A `;`-only splitter walked straight past this one.
AND_SKILL='# skill
```bash
OWNER=acme
REPO=widget
BODY="gh pr comment 7 --repo $OWNER/$REPO" && gh pr comment 7 --body "$BODY"
```
'
R="$(mkroot "$AND_SKILL")"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'unpinned_gh_call'; } \
    && pass "an && between a pinned assignment and an unpinned call is caught" \
    || die "&& masking passed the pin check (rc=$rc out='$out')"

# The occurrence COUNT is guarded too. A `wc` that printed a plausible number and
# then failed left the count trusted, so a failed parse could vouch for every
# `gh pr` call on the line.
# It fails on the SECOND call only. The verb count is taken first and has its own
# guard, so a wc that always fails exits there and the occurrence-count guard is
# never reached — the fixture would pass without it and prove nothing.
WCBIN="$TMP/wcbin"; mkdir -p "$WCBIN"
REAL_WC="$(command -v wc)"
cat > "$WCBIN/wc" <<WCSH
#!/usr/bin/env bash
n=\$(cat "\$WC_N" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$WC_N"
if [ "\$n" -ge 2 ]; then printf '1\n'; exit 1; fi
exec "$REAL_WC" "\$@"
WCSH
chmod +x "$WCBIN/wc"
R="$(mkroot "$PINNED_SKILL")"
rm -f "$TMP/wc.n"
out="$(PATH="$WCBIN:$PATH" WC_N="$TMP/wc.n" "$SCRIPT" "$R" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a wc that prints and then fails => 2, not a trusted count" \
    || die "failing wc gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'status=clean' \
    && die "a failed occurrence count reported clean: $out" \
    || pass "…and never reports clean"

# ── the check itself failing is not "clean" ───────────────────────────────
# rc 2 is "could not run", and it must never be confused with rc 0.
out="$("$SCRIPT" "$TMP/does-not-exist" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "a missing root => 2, not clean" || die "missing root gave rc=$rc"
R="$(mkroot '# skill with no bash blocks at all')"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a SKILL.md with no bash blocks => 2 (nothing was actually checked)" \
    || die "empty skill gave rc=$rc out='$out'"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
