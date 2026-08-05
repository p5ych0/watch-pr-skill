#!/usr/bin/env bash
# Unit tests for pr-selfcheck.sh.
#
# A pre-push checker that cannot catch the bug it was written for is worse than
# none: it converts an unverified assumption into a green tick. So the first case
# here reproduces the actual P1 — `$SUMMARY_FILE` used in SKILL.md and assigned
# nowhere — and requires the finding.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/pr-selfcheck.sh"
TMP="$(mktemp -d)"
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

# ── a failing test ─────────────────────────────────────────────────────────
R="$(mkroot "$OK_SKILL")"
addscript "$R" pr-thing.sh 'exit 0'
printf '#!/usr/bin/env bash\nexit 1\n' > "$R/skills/watch-prs/scripts/test-pr-thing.sh"
chmod +x "$R/skills/watch-prs/scripts/test-pr-thing.sh"
out="$("$SCRIPT" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'failing_test'; } \
    && pass "a failing test is a finding" \
    || die "failing test not caught (rc=$rc out='$out')"

# ── a repository that is not this plugin is NOT an error ──────────────────
# One installed copy drives every project, so the working repo is usually a
# consumer with no `skills/watch-prs/` tree. Reporting rc 2 there made a
# mandatory pre-push gate block every review round outside this checkout.
UNRELATED="$TMP/unrelated"
mkdir -p "$UNRELATED"; git -C "$UNRELATED" init -q 2>/dev/null
printf 'print("hi")\n' > "$UNRELATED/app.py"
out="$("$SCRIPT" "$UNRELATED" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'status=not_applicable'; } \
    && pass "a repo with no plugin sources reports not_applicable, not an error" \
    || die "unrelated repo gave rc=$rc out='$out'"
printf '%s' "$out" | grep -q 'status=clean' \
    && die "not_applicable was reported as clean, which reads as a pass" \
    || pass "…and is distinguishable from a clean result"

# Run from INSIDE that repo with no argument, which is how SKILL.md invokes it.
out="$(cd "$UNRELATED" && "$SCRIPT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'status=not_applicable'; } \
    && pass "…and the same holds for the no-argument invocation the contract uses" \
    || die "no-arg run from an unrelated repo gave rc=$rc out='$out'"

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
