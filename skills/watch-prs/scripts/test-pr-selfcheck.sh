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
