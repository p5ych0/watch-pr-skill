#!/usr/bin/env bash
# pr-merge-range.sh — may a head be merged on a signoff given earlier?
#
# This logic used to live inline in SKILL.md, where nothing executed it, so both
# of its defects survived review: it classified intervening commits by a
# `^fix(review):` SUBJECT (any commit can carry one, so unrelated work could
# merge unreviewed), and `git log | grep -c` masked a failing `git log` behind a
# successful `grep`. Extracting it is what makes these cases testable at all.
#
# Self-contained: throwaway git repos under mktemp -d. No network, no gh.

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Portable watchdog: stock macOS ships no GNU `timeout`, and the suite is a
# mandatory pre-push gate.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
SCRIPT="$SELF_DIR/pr-merge-range.sh"

TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name test

commit() {  # <message>
    echo "$RANDOM$RANDOM" > "$REPO/f.txt"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m "$1"
}

run() { rc=0; out="$("$SCRIPT" "$@" "$REPO" 2>&1)" || rc=$?; }

commit "base"
BASE="$(git -C "$REPO" rev-parse HEAD)"

# ── Identical heads: nothing intervened ────────────────────────────────────
run "$BASE" "$BASE"
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'commits=0'; } \
    && pass "identical reviewed/head => 0" || die "identical heads: rc=$rc out=$out"

# ── Every intervening commit properly tagged ───────────────────────────────
commit "fix(review): first Copilot fix

Review-Phase: copilot"
commit "fix(review): second Copilot fix

Review-Phase: copilot"
TAGGED_HEAD="$(git -C "$REPO" rev-parse HEAD)"
run "$BASE" "$TAGGED_HEAD"
[ "$rc" -eq 0 ] && pass "all intervening commits tagged => 0 (safe to merge past)" \
    || die "fully tagged range blocked: rc=$rc out=$out"

# ── A `fix(review):` SUBJECT without the trailer must NOT pass ─────────────
# This is the defect the old inline gate had: subject-matching let any commit
# with that subject through, so unrelated work could merge unreviewed.
commit "fix(review): looks like a Copilot fix but carries no trailer"
SUBJ_HEAD="$(git -C "$REPO" rev-parse HEAD)"
run "$BASE" "$SUBJ_HEAD"
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'untagged_commit'; } \
    && pass "fix(review): subject without the trailer => 1 (blocked)" \
    || die "a bare fix(review): subject passed the gate: rc=$rc out=$out"

# ── A marker-shaped BODY line is not a trailer ────────────────────────────
# git looks for trailers in the final block; this message has none.
git -C "$REPO" reset -q --hard "$TAGGED_HEAD"
commit "subject line

Review-Phase: copilot

ordinary body paragraph"
BODY_HEAD="$(git -C "$REPO" rev-parse HEAD)"
run "$BASE" "$BODY_HEAD"
[ "$rc" -eq 1 ] \
    && pass "marker-shaped body line is not a trailer => 1 (blocked)" \
    || die "a body line counted as a trailer: rc=$rc out=$out"

# ── Divergent history: the signoff does not cover this head ───────────────
git -C "$REPO" checkout -q -b side "$BASE"
commit "fix(review): on a divergent branch

Review-Phase: copilot"
SIDE="$(git -C "$REPO" rev-parse HEAD)"
run "$TAGGED_HEAD" "$SIDE"
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'not_an_ancestor'; } \
    && pass "divergent history => 1, even fully tagged" \
    || die "divergent range was not blocked: rc=$rc out=$out"

# ── Inspection failures fail CLOSED (2), never 0 ──────────────────────────
run "$BASE" "0000000000000000000000000000000000000000"
[ "$rc" -eq 2 ] && pass "unresolvable head => 2 (caller fails closed)" \
    || die "unresolvable head did not return 2: rc=$rc out=$out"

run "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$TAGGED_HEAD"
[ "$rc" -eq 2 ] && pass "unresolvable reviewed sha => 2" \
    || die "unresolvable reviewed sha did not return 2: rc=$rc out=$out"

rc=0; out="$("$SCRIPT" "$BASE" "$TAGGED_HEAD" "$TMP/not-a-repo" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && pass "non-repo directory => 2" || die "non-repo did not return 2: rc=$rc"

rc=0; out="$("$SCRIPT" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && pass "missing arguments => 2" || die "missing args did not return 2: rc=$rc"

# ── SKILL.md must call the script, not re-implement the range check ───────
# The inline version is what escaped review; a copy drifting back in would
# reintroduce both defects with this suite still green.
SKILL_MD="$SELF_DIR/../SKILL.md"
if [ -f "$SKILL_MD" ]; then
    grep -q 'pr-merge-range.sh' "$SKILL_MD" \
        && pass "SKILL.md delegates the range check to the script" \
        || die "SKILL.md no longer calls pr-merge-range.sh"
    grep -q "grep -c '\^fix(review):'" "$SKILL_MD" \
        && die "SKILL.md still classifies intervening commits by subject" \
        || pass "SKILL.md no longer classifies by fix(review): subject"
else
    pass "SKILL.md not present beside the scripts; delegation check skipped"
fi


# ── A counter that PRINTS and then fails is a failed inspection ────────────
# `|| true` masked every non-zero status from the counting pipeline, not just
# grep's rc 1 for "no matches" - and command substitution keeps whatever was
# written before the failure. So a counter printing the expected number and then
# exiting 2 still satisfied TAGGED == TOTAL and this returned status=ok, letting
# a range be declared Codex-vetted on the strength of a count that failed.
COUNT_BIN="$TMP/countbin"; mkdir -p "$COUNT_BIN"
cat > "$COUNT_BIN/grep" <<'SH'
#!/usr/bin/env bash
# Faults ONLY the trailer count (-c '^copilot$'); every other grep is real, so
# the script still reaches the counting step normally.
if [ -n "${FAULT_COUNT:-}" ] && [ "$1" = "-c" ] && [ "$2" = '^copilot$' ]; then
    printf '%s\n' "${FAULT_COUNT_VALUE:-1}"
    exit 2
fi
exec /usr/bin/grep "$@"
SH
chmod +x "$COUNT_BIN/grep"

# One tagged commit past the base: the honest count is 1, and the shim prints 1
# too - so only the STATUS distinguishes them.
git -C "$REPO" checkout -q -B countcase "$BASE"
commit "fix(review): tagged

Review-Phase: copilot"
COUNT_HEAD="$(git -C "$REPO" rev-parse HEAD)"

rc=0
out="$(PATH="$COUNT_BIN:$PATH" FAULT_COUNT=1 FAULT_COUNT_VALUE=1 "$SCRIPT" "$BASE" "$COUNT_HEAD" "$REPO" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] \
    && pass "counter that prints then fails => 2 (inspection failed)" \
    || die "stdout-plus-failure count accepted: rc=$rc out=$out"
printf '%s' "$out" | grep -q 'status=ok' \
    && die "a failed count still reported status=ok: $out" \
    || pass "no status=ok from a failed count"

# The same range without the fault is genuinely ok - so the assertion above
# cannot pass by the range being blocked for an unrelated reason.
run "$BASE" "$COUNT_HEAD"
[ "$rc" -eq 0 ] \
    && pass "the same range passes when the count actually succeeds" \
    || die "control failed: rc=$rc out=$out"

# grep's rc 1 (no matches) is still an honest ZERO, not a failure - an untagged
# range must block with status=blocked, never error.
git -C "$REPO" checkout -q -B zerocase "$BASE"
commit "chore: no trailer here"
ZERO_HEAD="$(git -C "$REPO" rev-parse HEAD)"
run "$BASE" "$ZERO_HEAD"
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'tagged=0'; } \
    && pass "no matches is a real zero (blocked, not error)" \
    || die "zero-match count did not block cleanly: rc=$rc out=$out"

# ── a root probe that prints and THEN fails is not a root ─────────────────
# `|| true` discarded the probe's status, so a `git rev-parse` that printed a
# plausible directory and then failed was indistinguishable from one that
# worked — and every history check then ran against a tree nothing vouched for.
MRTMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }; mkdir -p "$MRTMP/bin"
MR_REAL_GIT="$(command -v git)"
cat > "$MRTMP/bin/git" <<GITSH
#!/usr/bin/env bash
if [ "\$1" = "rev-parse" ] && [ "\$2" = "--show-toplevel" ]; then
    printf '%s\n' "/nonexistent-but-plausible"
    exit 1
fi
exec "$MR_REAL_GIT" "\$@"
GITSH
chmod +x "$MRTMP/bin/git"
# `set +e` around the probe: this file runs strict, and the probe is EXPECTED to
# fail — that is the assertion. Without it the assignment aborts the script,
# which then reports nothing at all.
set +e
# `env` inside the watchdog rather than a PATH on its caller: where GNU `timeout`
# is missing, `run_limited` polls with its own `sleep` and reads with its own
# `cat`, so a stub prefixed here breaks the harness instead of the subject.
out="$(cd "$MRTMP" && run_limited 20 env PATH="$MRTMP/bin:$PATH" "$SCRIPT" \
        1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 2>&1)"
rc=$?
set -e
{ [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'repo_root_lookup_failed'; } \
    && pass "a repo-root probe that prints then fails => 2, on its own reason" \
    || die "failed root probe gave rc=$rc out='$out'"
rm -rf "$MRTMP"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
