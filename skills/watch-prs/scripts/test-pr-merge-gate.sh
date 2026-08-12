#!/usr/bin/env bash
# Unit tests for pr-merge-gate.sh.
#
# THE MERGE DECISION HAD NEVER BEEN EXECUTED BY ANYTHING. It was 291 lines inside
# a fenced block in `SKILL.md`, and every assertion about it was a `grep` for the
# spelling of a line — which is how it came to hold a construct bash 3.2 cannot
# parse, for fifty rounds, while the contract test reported the gate present and
# correct. These cases RUN it: the helpers it calls are stubbed as siblings, `gh`
# is stubbed on `PATH`, and each case drives one decision to its conclusion.
#
# It is the last gate before the largest irreversible action this tool takes, so
# the cases are about REFUSING: every one of them checks that a specific defect
# stops the merge, and the merge-succeeds case exists to prove the others are not
# passing because nothing can ever merge.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-merge-gate.sh"

TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

HEAD40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD40=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
CODEXBOT='chatgpt-codex-connector[bot]'
COPILOTBOT='copilot-pull-request-reviewer[bot]'

# ── the harness ────────────────────────────────────────────────────────────
# A directory holding the gate, the libraries it loads, and a stub for every
# helper it calls. The gate finds all of them beside itself, which is what makes
# this possible at all — the function it replaced had to be told where they were.
GATEDIR="$TMP/g"; mkdir -p "$GATEDIR" "$TMP/bin" "$TMP/repo"
cp "$SCRIPT" "$SELF_DIR/loadlib.sh" "$SELF_DIR/recordlib.sh" "$SELF_DIR/identitylib.sh" "$GATEDIR/" \
    || { die "the gate could not be staged"; echo "RESULT: FAIL"; exit 1; }
( cd "$TMP/repo" && git init -q && git config user.email t@e && git config user.name t \
    && git commit -q --allow-empty -m init ) >/dev/null 2>&1 \
    || { die "the probe repository could not be created"; echo "RESULT: FAIL"; exit 1; }

# Each stub answers from a file, so a case sets the world and then runs the gate.
for h in pr-review-state.sh pr-merge-range.sh pr-ci-gate.sh pr-ci-state.sh pr-round-count.sh; do
    cat > "$GATEDIR/$h" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$0")" "\$*" >> "\$STUB_CALLS"
_n="\$(basename "\$0" .sh)"
_out="\$STUB_DIR/\${_n}.out"; _rc="\$STUB_DIR/\${_n}.rc"
# THE ARGUMENTS SELECT THE ANSWER where a case needs two different ones from the
# same helper — the gate asks \`pr-review-state.sh\` about two reviewers and about
# two shas, and a single canned reply cannot tell those apart.
for _k in "\$@"; do
    [ -f "\$STUB_DIR/\${_n}.\${_k}.out" ] && { _out="\$STUB_DIR/\${_n}.\${_k}.out"; _rc="\$STUB_DIR/\${_n}.\${_k}.rc"; break; }
done
[ -f "\$_out" ] && cat "\$_out"
exit "\$(cat "\$_rc" 2>/dev/null || echo 0)"
STUB
    chmod +x "$GATEDIR/$h"
done

cat > "$TMP/bin/gh" <<'GHSH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_CALLS"
# EACH ARGUMENT ON ITS OWN LINE, as well. `"$*"` joins them, so a slug that was
# split into two words by a missing pair of quotes looks identical to one that
# was not — which is exactly the defect this file has to be able to see.
for _a in "$@"; do printf '%s\n' "$_a"; done >> "$STUB_ARGV"
# DISPATCHED ON THE WHOLE COMMAND LINE, not on the first two words: the real call
# is `gh api --hostname <host> graphql …`, so `$2` is an option and a positional
# match silently fell through to "no output, exit 0" — which the gate reads as a
# failed page and every case then failed for the same wrong reason.
_all=" $* "
case "$_all" in
    *" pr view "*)   cat "$STUB_DIR/gh.head.out" 2>/dev/null; exit "$(cat "$STUB_DIR/gh.head.rc" 2>/dev/null || echo 0)" ;;
    *" graphql "*)
        # The threads query, paged: each call takes the next answer file.
        _i="$(cat "$STUB_DIR/page.n" 2>/dev/null || echo 1)"
        printf '%s' "$((_i + 1))" > "$STUB_DIR/page.n"
        cat "$STUB_DIR/threads.$_i.out" 2>/dev/null || cat "$STUB_DIR/threads.1.out" 2>/dev/null
        exit "$(cat "$STUB_DIR/threads.rc" 2>/dev/null || echo 0)" ;;
    *" pr merge "*)  cat "$STUB_DIR/gh.merge.out" 2>/dev/null; exit "$(cat "$STUB_DIR/gh.merge.rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
GHSH
chmod +x "$TMP/bin/gh"

CLEAN_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":true}]}}}}}'

world() {   # world ; a world in which the merge SHOULD go through
    STUB_DIR="$TMP/w"; rm -rf "$STUB_DIR"; mkdir -p "$STUB_DIR"
    : > "$TMP/calls"; : > "$TMP/argv"
    printf '%s\n' "$HEAD40" > "$STUB_DIR/gh.head.out"
    printf '%s' "$CLEAN_THREADS" > "$STUB_DIR/threads.1.out"
    # Codex has judged this head, so the gate takes the current-head branch and
    # both verdicts describe $HEAD40.
    printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s state=reviewed\n' "${HEAD40:0:7}" "$CODEXBOT" \
        > "$STUB_DIR/pr-review-state.state.out"
    printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0' "${HEAD40:0:7}" "$CODEXBOT" \
        > "$STUB_DIR/pr-review-state.$CODEXBOT.out"
    printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0' "${HEAD40:0:7}" "$COPILOTBOT" \
        > "$STUB_DIR/pr-review-state.$COPILOTBOT.out"
    printf '0' > "$STUB_DIR/pr-ci-gate.rc"
    printf '0' > "$STUB_DIR/pr-ci-state.rc"
    printf '0' > "$STUB_DIR/pr-round-count.rc"
    printf '0' > "$STUB_DIR/pr-merge-range.rc"
}
run_gate() {   # run_gate [pr] [codex-sha] [auto] ; prints "<rc>|<output>"
    # `${x-default}`, not `${x:-default}`: an argument that is present and EMPTY is
    # the case the gate must refuse, and `:-` would quietly replace it with the
    # default — the fixture would then assert the refusal of a value it never sent.
    local out rc=0
    out="$(cd "$TMP/repo" && run_limited 25 env PATH="$TMP/bin:$PATH" \
        STUB_DIR="$STUB_DIR" STUB_CALLS="$TMP/calls" STUB_ARGV="$TMP/argv" \
        REVIEW_BUS_REMOTE="${GATE_REMOTE:-git@github.com:acme/widget.git}" \
        ${GATE_OWNER:+REVIEW_BUS_OWNER="$GATE_OWNER"} \
        "$GATEDIR/pr-merge-gate.sh" "${1-7}" "${2-$HEAD40}" "${3-no}" 2>&1)" || rc=$?
    printf '%s|%s' "$rc" "$out"
}
case_is() {   # case_is <want rc> <needle> <label>
    local got rc body
    # `EMPTY` rather than an empty word: the defaulting below would turn a genuine
    # empty argument into `no`, and the case that matters is the empty one.
    local auto="${6:-no}"; [ "$auto" = EMPTY ] && auto=""
    got="$(run_gate "${4:-7}" "${5:-$HEAD40}" "$auto")"; rc="${got%%|*}"; body="${got#*|}"
    { [ "$rc" = "$1" ] && printf '%s' "$body" | grep -qF "$2"; } \
        && pass "$3" \
        || die "$3 — rc=$rc (wanted $1) out='$body'"
}

# ── the merge happens at all ───────────────────────────────────────────────
# FIRST, because every other case here asserts a refusal — and a gate that can
# never merge would satisfy all of them while being useless. This is the case that
# makes the rest mean something.
world
case_is 0 "merged $HEAD40" "a fully clean world merges, pinned to the head it checked"
grep -qF -- "--match-head-commit $HEAD40" "$TMP/calls" \
    && pass "…and the merge is pinned with --match-head-commit" \
    || die "the merge was not pinned to the head the gates ran against"
grep -qF -- "--admin" "$TMP/calls" \
    && pass "…with --admin by default, the documented trade" \
    || die "the default merge dropped --admin"

# REVIEW_MERGE_STRICT hands the decision to GitHub, which is the only place the
# window between the last probe and the merge can actually be closed.
world
STRICT=1 run_gate >/dev/null 2>&1 || :
out="$(cd "$TMP/repo" && run_limited 25 env PATH="$TMP/bin:$PATH" STUB_DIR="$STUB_DIR" \
    STUB_CALLS="$TMP/calls" STUB_ARGV="$TMP/argv" \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' REVIEW_MERGE_STRICT=1 "$GATEDIR/pr-merge-gate.sh" 7 "$HEAD40" no 2>&1)" || :
grep -qF -- "--squash --delete-branch --match-head-commit" "$TMP/calls" \
    && pass "REVIEW_MERGE_STRICT=1 drops --admin and lets GitHub evaluate" \
    || die "strict mode still merged with --admin ('$out')"

# THE REPO SLUG IS ONE ARGUMENT, whatever an origin URL puts in it. It came out of
# `SKILL.md` unquoted — harmless in a document nobody runs, a word-splitting bug in
# a script — so an owner containing a space must still reach `gh` as a single
# `--repo` operand. `$*` cannot see this, which is why the stub also records each
# argument on its own line.
#
# THE ASSERTION IS THAT NO FRAGMENT EXISTS, not that the whole slug appears
# somewhere. `argv` accumulates across every `gh` call in the run, so one properly
# quoted call further down supplied a matching line and the first version of this
# passed with the defect present — a fixture reporting on a call it was not
# looking at.
world
GATE_OWNER='ac me' run_gate >/dev/null
{ grep -qxF 'github.com/ac me/widget' "$TMP/argv" \
    && ! grep -qxF 'github.com/ac' "$TMP/argv" \
    && ! grep -qxF 'me/widget' "$TMP/argv"; } \
    && pass "the repo slug reaches gh as one argument, spaces and all" \
    || die "a gh call split the repo slug into words ($(grep -c . "$TMP/argv") argv lines)"

# ── the arguments ──────────────────────────────────────────────────────────
world
case_is 1 "needs a PR number" "a non-numeric PR is refused, by name" seven
case_is 1 "not a full 40-hex" "a short Codex sha is refused before any lookup" 7 abc123
case_is 1 "auto-review" "an unrecognised auto-review value is refused" 7 "$HEAD40" maybe
# AND IT IS REFUSED RATHER THAN ASSUMED. `AUTO_REVIEW` decides whether an
# in-flight Codex pass may be ignored; defaulting an unknown value to `no` is a
# merge on a verdict nobody read.
case_is 1 "auto-review" "…including an empty one" 7 "$HEAD40" EMPTY

# ── (0) the head lookup ────────────────────────────────────────────────────
world; printf '1' > "$STUB_DIR/gh.head.rc"
case_is 1 "head lookup failed" "a failed head lookup blocks"
# A LOOKUP THAT PRINTS AND THEN FAILS. Command substitution keeps the output, so a
# plausible sha from a failed fetch would otherwise pass the shape check.
world; printf '%s\n' "$HEAD40" > "$STUB_DIR/gh.head.out"; printf '1' > "$STUB_DIR/gh.head.rc"
case_is 1 "head lookup failed" "…even when it printed a plausible sha first"
world; printf 'not-a-sha\n' > "$STUB_DIR/gh.head.out"
case_is 1 "head lookup failed" "…and a malformed head is not a head"

# ── (1) each reviewer clean on the head that reviewer judged ───────────────
world; printf '2' > "$STUB_DIR/pr-review-state.state.rc"
case_is 1 "could not read Codex's state" "an unreadable Codex state blocks"
# ONLY rc 0 IS AN ANSWER: a helper can print a plausible record and exit non-zero.
world; printf '1' > "$STUB_DIR/pr-review-state.state.rc"
case_is 1 "could not read Codex's state" "…whatever it printed while failing"
world; printf 'warning: cached state=none\n' > "$STUB_DIR/pr-review-state.state.out"
case_is 1 "unparseable" "rc-0 noise ending in a state token is not a record"
# THE RECORD MUST BE ABOUT WHAT WAS ASKED. A well-formed line for another PR,
# another reviewer or an older head once took the `none` fallback and merged on a
# stale signoff while Codex had an active request for changes on this head.
world; printf 'PR_REVIEW_STATE pr=9 sha=%s reviewer=%s state=none\n' "${HEAD40:0:7}" "$CODEXBOT" \
    > "$STUB_DIR/pr-review-state.state.out"
case_is 1 "about something else" "a state record for another PR is refused"
world; printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s state=none\n' "${OLD40:0:7}" "$CODEXBOT" \
    > "$STUB_DIR/pr-review-state.state.out"
case_is 1 "about something else" "…and one for another head"
world; printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s state=none\n' "${HEAD40:0:7}" "$COPILOTBOT" \
    > "$STUB_DIR/pr-review-state.state.out"
case_is 1 "about something else" "…and one from another reviewer"
world; printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s state=elsewhere\n' "${HEAD40:0:7}" "$CODEXBOT" \
    > "$STUB_DIR/pr-review-state.state.out"
case_is 1 "unknown Codex head state" "an unrecognised state is refused, not treated as none"

# A WORLD IN WHICH CODEX HAS NOT JUDGED THIS HEAD, and its recorded signoff on the
# older sha is clean. Two cases below turn on exactly this shape: the auto-review
# pair, and the range check that makes trusting an older signoff safe.
codex_none_world() {
    world
    printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s state=none\n' "${HEAD40:0:7}" "$CODEXBOT" \
        > "$STUB_DIR/pr-review-state.state.out"
    printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0' "${OLD40:0:7}" "$CODEXBOT" \
        > "$STUB_DIR/pr-review-state.$CODEXBOT.out"
}

# NOT YET ANSWERED IS NOT NOTHING TO ANSWER. With auto-review on, every push
# queues a Codex pass and Codex exposes no record while it runs — which reads
# exactly like `none`. Falling back to the older signoff there merges before the
# in-flight pass has said anything.
# ISOLATED: the world is otherwise one that MERGES on the recorded signoff — the
# older sha carries a clean Codex verdict and the delta is Copilot-only — so the
# auto-review setting is the only thing standing between this and a merge. Written
# without that, the case blocked because the verdict record did not match, and it
# passed while the branch it names did nothing.
codex_none_world
case_is 1 "auto-review queues a Codex pass" "with auto-review on, a head with no verdict blocks" \
    7 "$OLD40" yes
# …and the same world with auto-review OFF is exactly the fallback this gate was
# written for, so it merges. The pair is what makes the assertion above about
# auto-review rather than about anything else in the world.
codex_none_world
case_is 0 "merged" "…while with it off, the recorded signoff is the authority" 7 "$OLD40" no

# THE VERDICT RECORDS ARE COMPARED IN FULL, not trusted as exit codes: this is the
# final merge permission, and an rc-swallowing wrapper would otherwise turn an
# unreadable verdict into a signoff.
world; printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0 extra' "${HEAD40:0:7}" "$CODEXBOT" \
    > "$STUB_DIR/pr-review-state.$CODEXBOT.out"
case_is 1 "did not return an exact clean record" "a verdict line with trailing text is refused"
world; printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0' "${HEAD40:0:7}" "$CODEXBOT" \
    > "$STUB_DIR/pr-review-state.$COPILOTBOT.out"
case_is 1 "did not return an exact clean record" "…and Codex's own record does not stand in for Copilot's"
world; printf '1' > "$STUB_DIR/pr-review-state.$COPILOTBOT.rc"
case_is 1 "copilot=1" "a non-clean Copilot verdict blocks"

# ── (2) the delta is Copilot fixes only ────────────────────────────────────
# This is what makes checking Codex on an OLDER sha safe. Codex has NOT judged
# this head here, so the gate falls back to the recorded signoff and must prove
# the range.
codex_none_world; printf '1' > "$STUB_DIR/pr-merge-range.rc"
case_is 1 "range check returned 1" "an untagged commit in the delta blocks" 7 "$OLD40" no
codex_none_world; printf '2' > "$STUB_DIR/pr-merge-range.rc"
case_is 1 "range check returned 2" "…and so does a range that could not be inspected" 7 "$OLD40" no
codex_none_world
case_is 0 "merged $HEAD40" "a Copilot-only delta merges on the recorded signoff" 7 "$OLD40" no
grep -qF "pr-merge-range.sh $OLD40 $HEAD40" "$TMP/calls" \
    && pass "…and the range is measured from the sha the verdict describes" \
    || die "the range was not measured from the Codex-reviewed sha"
# …AND IT IS NOT MEASURED AT ALL when Codex judged this head: demanding Copilot
# trailers across a range Codex has already reviewed in full blocks a merge both
# reviewers just approved.
world; case_is 0 "merged" "no range is demanded when Codex judged this head"
grep -q 'pr-merge-range.sh' "$TMP/calls" \
    && die "the range check ran for a head Codex had already reviewed" \
    || pass "…so the range check does not run at all"

# ── (3) unresolved threads, paginated, fail closed ─────────────────────────
world; printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false}]}}}}}' \
    > "$STUB_DIR/threads.1.out"
case_is 1 "unresolved=1" "an unresolved thread blocks"
# A 200 CARRYING `errors` IS NOT A RESPONSE. The partial data passes every shape
# check while silently omitting threads, and the answer this gate takes from it is
# merge permission.
world; printf '{"errors":[{"message":"x"}],"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' \
    > "$STUB_DIR/threads.1.out"
case_is 1 "ok=0" "a GraphQL response carrying errors is refused"
world; printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{}]}}}}}' \
    > "$STUB_DIR/threads.1.out"
case_is 1 "ok=0" "…and nodes without a boolean isResolved are not counted as zero"
world; printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":"maybe","endCursor":"a"},"nodes":[]}}}}}' \
    > "$STUB_DIR/threads.1.out"
case_is 1 "ok=0" "…nor a malformed hasNextPage read as the last page"
world; printf '1' > "$STUB_DIR/threads.rc"
case_is 1 "ok=0" "…and a query that fails outright blocks"
# A CURSOR CYCLE MUST NOT HANG. A stale page can report another page while handing
# back a cursor already used; the walk would follow it forever, and a gate that
# never answers is worse than one that refuses.
world
printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"A"},"nodes":[]}}}}}' \
    > "$STUB_DIR/threads.1.out"
printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"A"},"nodes":[]}}}}}' \
    > "$STUB_DIR/threads.2.out"
case_is 1 "ok=0" "a repeated pagination cursor stops the walk instead of looping"

# ── (3b) and (4) the checks ────────────────────────────────────────────────
world; printf '1' > "$STUB_DIR/pr-ci-gate.rc"
case_is 1 "the head's checks are not green" "a head whose checks are not green blocks"
world; printf '1' > "$STUB_DIR/pr-ci-state.rc"
case_is 1 "a required check is not green" "a failing required check blocks"
world; printf '3' > "$STUB_DIR/pr-ci-state.rc"
case_is 1 "have not finished" "…and unfinished required checks block"
world; printf '2' > "$STUB_DIR/pr-ci-state.rc"
case_is 1 "required-checks probe failed" "…and an unreadable probe blocks"
# NONE CONFIGURED IS NOT COULD NOT TELL. Treating "no branch protection" as
# unreadable blocked every repository without it, permanently.
world; printf '4' > "$STUB_DIR/pr-ci-state.rc"
case_is 0 "merged" "a repository with no required checks still merges"

# ── (4b) the round boundary is a PAUSE, not a refusal ──────────────────────
world; printf '3' > "$STUB_DIR/pr-round-count.rc"
case_is 3 "PAUSE" "a round boundary pauses for the operator, with its own status"
world; printf '2' > "$STUB_DIR/pr-round-count.rc"
case_is 1 "could not establish the round count" "…while an unreadable count blocks"

# ── (5) the merge itself ───────────────────────────────────────────────────
world; printf '1' > "$STUB_DIR/gh.merge.rc"
case_is 1 "head moved after the gates ran" "a refused merge is reported, not assumed"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
