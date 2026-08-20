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
for h in pr-review-state.sh pr-merge-range.sh pr-ci-gate.sh pr-ci-state.sh pr-round-count.sh pr-signoff.sh; do
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
    *" --json state "*) cat "$STUB_DIR/gh.state.out" 2>/dev/null
                        exit "$(cat "$STUB_DIR/gh.state.rc" 2>/dev/null || echo 0)" ;;
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
    printf 'MERGED\n' > "$STUB_DIR/gh.state.out"
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
    # NOTHING RECORDED is the default world: most merges predate the signoff
    # record, and the gate must not start demanding one.
    printf '1' > "$STUB_DIR/pr-signoff.rc"
    printf 'PR_SIGNOFF pr=7 reviewer=%s sha=none\n' "$CODEXBOT" > "$STUB_DIR/pr-signoff.out"
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
        "$GATEDIR/pr-merge-gate.sh" "${1-7}" "${2-$HEAD40}" "${3-no}" ${4+"$4"} 2>&1)" || rc=$?
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
case_line() {   # case_line <want rc> <the WHOLE diagnostic line> <label>
    # `grep -xF`, not the substring match above. The defect this answers was a
    # message whose opening clause was true and whose remainder named an event
    # that had not happened, and a substring assertion on the true clause matched
    # it exactly as it matches the corrected one. Asserting the line ENTIRE is
    # what makes a false remainder visible.
    local got rc body
    got="$(run_gate "${4:-7}" "${5:-$HEAD40}" "${6:-no}")"; rc="${got%%|*}"; body="${got#*|}"
    { [ "$rc" = "$1" ] && printf '%s\n' "$body" | grep -qxF "$2"; } \
        && pass "$3" \
        || die "$3 — rc=$rc (wanted $1) out='$body'"
}

# ── EVERY FIXTURE IS DEFINED HERE, ABOVE EVERY CASE ────────────────────────
#
# Bash defines a function when it EXECUTES the definition, so a call from higher
# up the file is an external command lookup that fails with 127 — and with no
# `-e` here the case then runs against whatever state the PREVIOUS case left.
# That happened twice in this file, in two different places, and both times the
# assertion passed while testing something other than what it named. Keeping the
# definitions together, before anything calls them, is what stops it recurring.

# ── CODEX-ONLY: THE OPTION `SKILL.md` OFFERS MUST BE REACHABLE ─────────────
#
# The stop after a clean Codex phase offers "merge now on Codex's signoff alone".
# That offer was a dead letter: this gate demanded an exact clean COPILOT record
# on the head, and with no Copilot review requested there is none.
#
# What makes it safe is a STRICTER check, not a skipped one. The two-reviewer path
# tolerates a head that advanced past Codex's signoff because every commit since
# carries a `Review-Phase: copilot` trailer; with no Copilot phase there are no
# such commits and nothing licenses the delta, so the head must BE the reviewed
# commit.
codex_only_world() {
    world
    # No Copilot verdict exists at all — the state this mode is entered from.
    printf '2' > "$STUB_DIR/pr-review-state.$COPILOTBOT.rc"
    : > "$STUB_DIR/pr-review-state.$COPILOTBOT.out"
}

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

codex_only_world
got="$(run_gate 7 "$HEAD40" no)"; rc="${got%%|*}"; body="${got#*|}"
{ [ "$rc" = 1 ] && printf '%s' "$body" | grep -qF 'copilot=2'; } \
    && pass "the default gate still requires Copilot, so codex-only is a real choice" \
    || die "the default gate merged without a Copilot verdict (rc=$rc '$body')"
codex_only_world
got="$(run_gate 7 "$HEAD40" no codex-only)"; rc="${got%%|*}"; body="${got#*|}"
{ [ "$rc" = 0 ] && printf '%s' "$body" | grep -qF "merged $HEAD40"; } \
    && pass "…and codex-only merges on the Codex signoff alone" \
    || die "codex-only could not merge (rc=$rc '$body')"
# THE HEAD MUST BE THE COMMIT CODEX SIGNED. This is the check that replaces
# Copilot's: without it, codex-only would merge a head nobody reviewed.
codex_none_world
got="$(run_gate 7 "$OLD40" no codex-only)"; rc="${got%%|*}"; body="${got#*|}"
{ [ "$rc" = 1 ] && printf '%s' "$body" | grep -qF 'pinned to the reviewed commit'; } \
    && pass "…and refuses when the head has moved past the signoff" \
    || die "codex-only merged a head Codex never saw (rc=$rc '$body')"
codex_only_world; printf '1' > "$STUB_DIR/pr-review-state.$CODEXBOT.rc"
got="$(run_gate 7 "$HEAD40" no codex-only)"; rc="${got%%|*}"; body="${got#*|}"
[ "$rc" = 1 ] \
    && pass "…and a non-clean Codex verdict still blocks it" \
    || die "codex-only merged without a clean Codex verdict (rc=$rc '$body')"
# AN UNRECOGNISED MODE IS REFUSED, not read as the permissive one.
world
got="$(run_gate 7 "$HEAD40" no everyone)"; rc="${got%%|*}"; body="${got#*|}"
{ [ "$rc" = 1 ] && printf '%s' "$body" | grep -qF "reviewers must be"; } \
    && pass "…and an unrecognised reviewers mode is refused" \
    || die "an unknown reviewers mode was accepted (rc=$rc '$body')"

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

# ── A REPLIES-ONLY VERDICT IS THE ONE AN OPERATOR CAN ANSWER ──────────────
# A review whose comments are ALL replies is neither answer: nothing for
# `pr-findings.sh` to list, and not a signoff, because a verdict followed by
# explanation reads exactly like one followed by a retraction. The loop stops for
# a human — and without this the stop was where it ENDED: the verdict could never
# become clean, so this gate blocked forever. A deadlock traded for a permanent
# pause is not a fix.
replies_only() {   # replies_only <bot> ; that reviewer left only replies on the head
    printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=findings findings=1 source=replies-only' \
        "${HEAD40:0:7}" "$1" > "$STUB_DIR/pr-review-state.$1.out"
    printf '1' > "$STUB_DIR/pr-review-state.$1.rc"
}
# `at=` COMES BEFORE `sha=` in the real record, because every caller reads the sha
# with `${line##*sha=}` and a field after it would be swallowed into the value.
# The fixture carries the real order so it proves the real parse.
vouched() {   # vouched <bot> [signed-at] ; an operator answered THIS review
    printf '0' > "$STUB_DIR/pr-signoff.rc"
    printf 'PR_SIGNOFF pr=7 reviewer=%s at=%s sha=%s\n' \
        "$1" "${2:-2026-01-02T00:00:00Z}" "$HEAD40" > "$STUB_DIR/pr-signoff.out"
    # WHEN THE REVIEW LANDED, so "newer than" can be decided at all.
    printf '2026-01-01T00:00:00Z\n' > "$STUB_DIR/pr-review-state.review-at.out"
}
world; replies_only "$COPILOTBOT"; vouched "$COPILOTBOT"
case_is 0 "left only replies" "a replies-only verdict merges on the signoff an operator recorded"

# ── A FULL-WIDTH RECORD IS ACCEPTED, THROUGH THIS GATE ─────────────────────
# The gate used to REBUILD the line it expected with `sha=${…:0:7}`, so a record
# carrying the forty-hex OID — which every other caller accepts — was refused
# here. `test-recordlib.sh` proves the library accepts it; that says nothing about
# the two tail rules this file owns, and a regression in either would leave a
# valid merge blocked with the suite green. #126.
world
printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0' "$HEAD40" "$CODEXBOT" \
    > "$STUB_DIR/pr-review-state.$CODEXBOT.out"
printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0' "$HEAD40" "$COPILOTBOT" \
    > "$STUB_DIR/pr-review-state.$COPILOTBOT.out"
case_is 0 "merged" "a clean verdict carrying the full forty-hex head merges"
# AND THE OTHER TAIL RULE, on the path that can authorise a merge on an operator's
# word rather than on a clean verdict.
world
printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=findings findings=1 source=replies-only' \
    "$HEAD40" "$COPILOTBOT" > "$STUB_DIR/pr-review-state.$COPILOTBOT.out"
printf '1' > "$STUB_DIR/pr-review-state.$COPILOTBOT.rc"
vouched "$COPILOTBOT"
case_is 0 "left only replies" "…and a full-width replies-only record still merges on the recorded signoff"
# THE IDENTITY IS STILL CHECKED AT FULL WIDTH. A forty-hex record for another
# commit must not pass merely because the comparison grew wider.
world
printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=clean findings=0' "$OLD40" "$CODEXBOT" \
    > "$STUB_DIR/pr-review-state.$CODEXBOT.out"
case_is 1 "did not return an exact clean record" "…while a full-width record for another head is refused"

# WITHOUT THAT RECORD IT REFUSES. `signoff_contradicts` answers "does a record
# disagree", and nothing recorded is not a disagreement — so reusing it here would
# have merged a replies-only head that no human ever read.
world; replies_only "$COPILOTBOT"
case_is 1 "no operator has recorded a signoff" "…and refuses when nobody has recorded one"

# THE RECORD IS MATCHED IN FULL. A `*` between `findings=` and the suffix accepts
# an empty count and any field anyone appends — and this shape bypasses the status
# gate and can authorise a merge, so it is the last place to be relaxed about a
# wildcard. Each of these must fall through to the ordinary refusal.
for _bad in 'verdict=findings findings= source=replies-only' \
            'verdict=findings findings=1 extra=x source=replies-only' \
            'verdict=findings findings=0 source=replies-only' \
            'verdict=findings findings=1x source=replies-only'; do
    world; vouched "$COPILOTBOT"
    printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s %s' "${HEAD40:0:7}" "$COPILOTBOT" "$_bad" \
        > "$STUB_DIR/pr-review-state.$COPILOTBOT.out"
    printf '1' > "$STUB_DIR/pr-review-state.$COPILOTBOT.rc"
    got="$(run_gate)"; rc="${got%%|*}"; body="${got#*|}"
    { [ "$rc" = 1 ] && printf '%s' "$body" | grep -qv 'merging on the signoff'; } \
        && pass "a near-miss replies-only record is not authorised: ${_bad#verdict=findings }" \
        || die "a loose record was authorised: '$_bad' rc=$rc out='$body'"
done

# A HEAD IS NOT A MOMENT. A signoff recorded for an EARLIER clean review on the
# same head must not vouch for a LATER replies-only review that nobody read —
# naming the same sha says nothing about which came first.
world; replies_only "$COPILOTBOT"; vouched "$COPILOTBOT" '2025-12-31T00:00:00Z'
case_is 1 "cannot be an answer to it" "a signoff older than the review does not answer it"
# EQUAL IS NOT NEWER: GitHub stamps to the second, so a tie cannot be ordered, and
# merge permission is not a coin toss.
world; replies_only "$COPILOTBOT"; vouched "$COPILOTBOT" '2026-01-01T00:00:00Z'
case_is 1 "cannot be an answer to it" "…and one recorded in the same second does not either"
# A record with no usable timestamp is a refusal, not a pass.
world; replies_only "$COPILOTBOT"; vouched "$COPILOTBOT"
printf 'PR_SIGNOFF pr=7 reviewer=%s sha=%s\n' "$COPILOTBOT" "$HEAD40" > "$STUB_DIR/pr-signoff.out"
case_is 1 "no usable timestamp" "…and a record with no timestamp is refused"
# And a head with no submitted review has nothing for a signoff to answer.
world; replies_only "$COPILOTBOT"; vouched "$COPILOTBOT"
: > "$STUB_DIR/pr-review-state.review-at.out"
case_is 1 "nothing for a signoff to answer" "…and a head with no review cannot be vouched for"

# ── WHY THE COPILOT REVOCATION IS POSTED UNCONDITIONALLY ───────────────────
# `pr-copilot-phase.sh open` revokes on EVERY entry, including the first, where
# there is no signoff to revoke. That looks like a comment recording something
# that never happened, and #36 proposed skipping it. These two cases are why it
# is not skipped, and they are here rather than there because the reason lives in
# this gate.
#
# With no Copilot record at all, a head whose only clean Copilot verdict is an
# OLD review merges: `signoff_contradicts` treats "nothing recorded" as "no
# disagreement", which is right where a signoff is a cross-check, and the verdict
# probe answers with the review that is already there. So on a first entry the
# revocation is the only durable mark that a NEW pass is pending, and without it a
# concurrent or resumed gate merges on the review the new pass was requested to
# replace.
world
printf '0' > "$STUB_DIR/pr-signoff.$CODEXBOT.rc"
printf 'PR_SIGNOFF pr=7 reviewer=%s sha=%s\n' "$CODEXBOT" "$HEAD40" > "$STUB_DIR/pr-signoff.$CODEXBOT.out"
printf '1' > "$STUB_DIR/pr-signoff.$COPILOTBOT.rc"
printf 'PR_SIGNOFF pr=7 reviewer=%s sha=none\n' "$COPILOTBOT" > "$STUB_DIR/pr-signoff.$COPILOTBOT.out"
case_is 0 "merged" "with no Copilot record, a stale clean verdict is enough to merge"
# …AND THE REVOCATION IS WHAT STOPS IT. Same world, same verdict, one comment
# different. Removing the unconditional revocation removes this refusal.
printf 'PR_SIGNOFF pr=7 reviewer=%s sha=none reason=revoked\n' "$COPILOTBOT" \
    > "$STUB_DIR/pr-signoff.$COPILOTBOT.out"
case_line 1 "merge blocked: a $COPILOTBOT pass is open on this PR and no signoff for it has been recorded" \
    "…and the revocation is the only thing that refuses it"

# …AND THE RECORD HAS TO NAME THIS HEAD.
world; replies_only "$COPILOTBOT"
printf '0' > "$STUB_DIR/pr-signoff.rc"
printf 'PR_SIGNOFF pr=7 reviewer=%s sha=%s\n' "$COPILOTBOT" "$OLD40" > "$STUB_DIR/pr-signoff.out"
case_is 1 "signoff names" "…and refuses when the record names another head"

# THE EXEMPTION IS FOR THAT SHAPE ONLY. A review with real findings is not a
# question an operator was asked, so a recorded signoff must not carry it.
world; vouched "$COPILOTBOT"
printf 'PR_REVIEW_STATE pr=7 sha=%s reviewer=%s verdict=findings findings=2' "${HEAD40:0:7}" "$COPILOTBOT" \
    > "$STUB_DIR/pr-review-state.$COPILOTBOT.out"
printf '1' > "$STUB_DIR/pr-review-state.$COPILOTBOT.rc"
# It refuses at the status gate rather than the record comparison, which is
# earlier and equally final — so what this asserts is the OUTCOME and the absence
# of the note, not which line said no.
got="$(run_gate)"; rc="${got%%|*}"; body="${got#*|}"
{ [ "$rc" = 1 ] && printf '%s' "$body" | grep -qv 'merging on the signoff'; } \
    && pass "…while a signoff does not carry a review that has findings" \
    || die "a signoff carried a review with findings — rc=$rc out='$body'"

# ── WHAT THE GATE ASKS, NOT ONLY WHAT IT IS TOLD ───────────────────────────
#
# PLACED AFTER `codex_none_world` IS DEFINED. Bash defines a function when it
# EXECUTES the definition, so calling it from higher up the file is an external
# command lookup that fails with 127 — and with no `-e` here, the `:` that follows
# overwrote that status and the case ran against whatever world was left over.
# A setup that fails must not be able to become green coverage.
#
# The cases below vary each helper's exit STATUS, and the stubs ignore their
# arguments — so a gate that asked the right helper the wrong question would
# satisfy all of them. These two assertions are the ones the deleted contract
# greps used to make, and they have to be made SOMEWHERE: this file claimed to
# cover them and did not.
# THE ALL-CHECKS GATE IS ASKED ABOUT THE CURRENT HEAD. Handed `$CODEX_SHA`
# instead, it would validate the older clean head while the required-checks probe
# stays blind to a failing OPTIONAL check on the head actually being merged.
#
# IN A WORLD WHERE THE TWO DIFFER. Asserted against the clean world it proved
# nothing: there `$CODEX_SHA` IS the head, so a gate asking about the wrong one
# asks the same question and the fixture cannot tell.
#
# THE LOG IS CLEARED IMMEDIATELY BEFORE THE RUN. `world` clears it, but a helper
# that reads it after any later `run_gate` is reading two runs at once — and one
# of them was the clean world, whose `$CODEX_SHA` IS the head, so the wrong
# argument still produced a matching line and this assertion passed under its own
# mutant.
codex_none_world; : > "$TMP/calls"; run_gate 7 "$OLD40" no >/dev/null
grep -qxF "pr-ci-gate.sh 7 $HEAD40" "$TMP/calls" \
    && pass "the all-checks gate is asked about the PR and the CURRENT head" \
    || die "the all-checks gate was not pinned to the current head ($(grep pr-ci-gate "$TMP/calls" | head -1))"
# …AND THE THREAD QUERY IS BOUND TO THE DERIVED HOST, OWNER, REPO AND PR. Every
# world here uses a github.com remote, so a gate that dropped `--hostname` would
# look identical — on an enterprise host it would follow `GH_HOST` or the CLI
# default and read threads from the wrong server, immediately before an admin
# merge.
world
GATE_REMOTE='git@github.example.com:acme/widget.git' run_gate >/dev/null
gql="$(grep -F 'api --hostname' "$TMP/calls" | head -1)"
{ printf '%s' "$gql" | grep -qF -- '--hostname github.example.com' \
    && printf '%s' "$gql" | grep -qF -- 'number=7' \
    && printf '%s' "$gql" | grep -qF -- 'owner=acme' \
    && printf '%s' "$gql" | grep -qF -- 'repo=widget'; } \
    && pass "the thread query names the derived host, owner, repo and PR" \
    || die "the thread query is not bound to the derived identity ('$gql')"

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

# ── A REOPENED PHASE IS NOT MERGEABLE FROM A STALE SESSION ─────────────────
# "Another Codex pass" on an unchanged head leaves GitHub still exposing the old
# clean verdict until the replacement reports. The revocation is the only record
# of the reopening, so a session holding the old sha would otherwise satisfy every
# verdict check and merge the phase that was deliberately reopened.
world; printf '1' > "$STUB_DIR/pr-signoff.rc"
printf 'PR_SIGNOFF pr=7 reviewer=%s sha=none reason=revoked\n' "$CODEXBOT" > "$STUB_DIR/pr-signoff.out"
case_line 1 "merge blocked: a $CODEXBOT pass is open on this PR and no signoff for it has been recorded" \
    "a revoked Codex signoff blocks the merge"
# …AND A RECORD NAMING ANOTHER COMMIT IS A CONTRADICTION TOO. The caller's sha and
# the PR's record disagreeing means one of them is stale, and merging is the wrong
# way to find out which.
world; printf '0' > "$STUB_DIR/pr-signoff.rc"
printf 'PR_SIGNOFF pr=7 reviewer=%s sha=%s\n' "$CODEXBOT" "$OLD40" > "$STUB_DIR/pr-signoff.out"
case_is 1 "names bbbbbbb" "…and a signoff naming a different head blocks it"
# ABSENT IS NOT A CONTRADICTION. Requiring a record would refuse every merge on a
# PR older than the record itself.
world; case_is 0 "merged" "…while nothing recorded leaves the caller's sha alone"
# AND AN UNREADABLE RECORD FAILS CLOSED, like every other read here.
world; printf '2' > "$STUB_DIR/pr-signoff.rc"
: > "$STUB_DIR/pr-signoff.out"
case_is 1 "could not read the" "…and an unreadable record blocks"

# …AND THE SAME HOLDS FOR COPILOT, whose phase can be reopened the same way. The
# Codex half of this landed a round before the Copilot half, which is what a rule
# written out twice looks like: one copy.
world; printf '1' > "$STUB_DIR/pr-signoff.$COPILOTBOT.rc"
printf 'PR_SIGNOFF pr=7 reviewer=%s sha=none reason=revoked\n' "$COPILOTBOT" \
    > "$STUB_DIR/pr-signoff.$COPILOTBOT.out"
case_line 1 "merge blocked: a $COPILOTBOT pass is open on this PR and no signoff for it has been recorded" \
    "a revoked Copilot signoff blocks the merge too"
# …and it is NOT consulted in codex-only, where there is no Copilot phase to
# reopen — a stale Copilot revocation must not block a merge it has nothing to do
# with.
codex_only_world; printf '1' > "$STUB_DIR/pr-signoff.$COPILOTBOT.rc"
printf 'PR_SIGNOFF pr=7 reviewer=%s sha=none reason=revoked\n' "$COPILOTBOT" \
    > "$STUB_DIR/pr-signoff.$COPILOTBOT.out"
got="$(run_gate 7 "$HEAD40" no codex-only)"; rc="${got%%|*}"; body="${got#*|}"
[ "$rc" = 0 ] \
    && pass "…and a Copilot revocation does not block a codex-only merge" \
    || die "a codex-only merge was blocked by a Copilot record (rc=$rc '$body')"

# ── (5) the merge itself ───────────────────────────────────────────────────
world; printf '1' > "$STUB_DIR/gh.merge.rc"
case_is 1 "head moved after the gates ran" "a refused merge is reported, not assumed"
# A SUCCESSFUL `gh pr merge` IS NOT NECESSARILY A MERGE. On a base branch with a
# merge queue, `gh` reports success for ADDING the PR to the queue — and the PR can
# leave it later without landing. Saying `merged` there tells the driver the work
# is done while the head is not on the base branch. `--admin` bypasses the queue,
# so this is reachable exactly in the mode chosen for safety.
world; printf 'OPEN\n' > "$STUB_DIR/gh.state.out"
case_is 4 "merge queued" "a queued merge is not reported as a merge"
world; printf '1' > "$STUB_DIR/gh.state.rc"
case_is 4 "unconfirmed" "…and a state that cannot be read is not assumed to be merged"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
