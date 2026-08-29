#!/usr/bin/env bash
# Doc-regression for the v2 driver contract.
#
# Every assertion here exists because the contract and the behaviour drifted
# apart at least once in v1: a documented command that could not run, a merge
# that was not pinned to the head its gates checked, a "cannot tell" the driver
# was never told to stop on.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$SCRIPT_DIR/../SKILL.md"
ROOT="$SCRIPT_DIR/../../.."
# The shared fixture helpers. This was the one test file in the suite that never
# sourced them, and it was the one still holding a bare `mktemp -d`.
. "$SCRIPT_DIR/testlib.sh"

# THE IDENTITY OVERRIDES ARE CLEARED. `SKILL.md`'s setup exports
# `REVIEW_BUS_REMOTE`, and step 5a runs this suite, so the documented flow reaches
# here with the session pin already set — and the pin cases below forge an
# `export` whose assignment to an ALREADY-EXPORTED name keeps the export
# attribute, inverting the case that exists to catch assign-without-export. Not in
# `testlib.sh`: that library ships at runtime inside `pr-ci-state.sh`, where an
# unset would wipe the driver's pin. See `test-pr-identity.sh` for the long form.
unset REVIEW_BUS_REMOTE REVIEW_BUS_OWNER REVIEW_BUS_REPO

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }


if [ ! -f "$SKILL" ]; then
    echo "ok   - skill not present in this checkout; contract checks skipped"
    echo "RESULT: PASS"
    exit 0
fi

# THE COUNTER FIXTURE'S SCRATCH DIRECTORY IS TAKEN HERE, at the top, and it is the
# FIRST `mktemp_d` in this file. Its guard is what the scratch probe far below
# re-runs this file to observe, and where the acquisition sat beside its fixtures
# each of those two children executed four thousand lines before reaching it —
# eighty-eight seconds of the file's runtime spent arriving at a guard that fires
# in a tenth of one. Nothing between here and there uses `$TMP_CL`, and the words
# the probe greps for are the same words.
#
# AFTER THE MISSING-SKILL SKIP, THOUGH. A checkout without `../SKILL.md` reports a
# skipped PASS and exits, and nothing on that path needs a scratch directory — put
# ahead of it, a `$TMPDIR` that cannot hold one turned that skip into a FAIL. The
# skip does not allocate, so this is still the first `mktemp_d` the scratch probe
# sees wherever the skill exists, which is every checkout the probe runs in.
# The scratch directory for the fixtures below — through the VALIDATED helper,
# and stopping rather than recording.
#
# This was a bare `mktemp -d` guarded by `die`, and `die` RETURNS 0: it records a
# failure and lets the file carry on. So a full or read-only $TMPDIR left
# `TMP_CL` empty, `CNTB` below became `/bin`, and the `mkdir -p` and `ln -sf`
# that build the fixture wrote symlinks over the system binaries they were meant
# to be shadowing inside a scratch tree.
#
# `die` is right for an assertion — every remaining check should still run — and
# wrong here, because everything after this point dereferences the path. And a
# status check alone is not enough: `mktemp` can print a plausible path and then
# fail, or print one it never created, and command substitution keeps the output
# either way. `mktemp_d` is the definition of "a path that was actually created".
TMP_CL="$(mktemp_d)" || {
    die "no scratch directory for the counter fixture"
    echo "RESULT: FAIL"
    exit 1
}
# …and it is removed. There was no cleanup here at all, so every run of the suite
# left a scratch tree behind. Safe as an unquoted-free `rm -rf` only because
# `mktemp_d` has already established the path is non-empty, absolute and not `/`.
trap 'rm -rf "$TMP_CL"' EXIT

# ── EVERY HELPER THE DRIVER RUNS IS STARTED PRIVILEGED ─────────────────────
#
# `/usr/bin/env bash -p` before each one, and that is where the guarantee lives.
# The helpers also carry a privileged shebang, but that needs `env -S` and only
# covers direct execution; this invocation starts a fresh privileged interpreter
# whatever the driving shell is and whatever that platform's `env` supports.
#
# WHAT IT BUYS is that no `BASH_ENV` hook, no inherited function and no exported
# `SHELLOPTS` reaches a helper — the class that produced `type`, `return`, `set`,
# `echo` and `exit` findings one per review round. The helpers' own `$-` check
# cannot establish this: a hook that runs `set -p` before the script's first line
# passes it, which is why the CALLER is asserted here rather than the callee.
# ONE CLASSIFIER, USED BY THE SCAN AND BY THE REGRESSION CASE BELOW. Written
# twice, the case reimplemented the corrected logic — so a regression in the real
# scanner left `_unpriv` empty while the copy still reported the synthetic line,
# and the guard passed on exactly the state it exists to catch.
#
# A COMMENT IS NOT AN INVOCATION. The block in `SKILL.md` explains why the path
# matters and quotes it while doing so, and the scan read that as a bare call — a
# finding against prose.
#
# THE FIRST NON-BLANK CHARACTER, NOT "CONTAINS A `#`". Written as `' '*'#'*` this
# skipped any indented line with a `#` ANYWHERE, so an indented invocation with a
# trailing comment was removed and the guard reported clean on a call that had
# lost its `bash -p`. The exemption was wider than the thing it exempted. The trim
# happens BEFORE the case, because a `${var%%…}` written as part of a case PATTERN
# is not the test it looks like.
#
# `pr-selfcheck.sh` IS THE EXEMPTION, named rather than allowed to slip through a
# pattern. It is the one helper not started privileged: it re-execs into a clean
# shell, clears every inherited function and refuses if one cannot be cleared — a
# stronger boundary than `-p`. Putting `bash -p` in front of it would state the
# same property twice and differently, which is how two copies come to disagree.
rb_bare_invocations() {   # stdin: candidate lines ; stdout: those not started privileged
    local line bare
    while IFS= read -r line; do
        bare="${line#"${line%%[![:space:]]*}"}"
        case "$bare" in '#'*) continue ;; esac
        case "$line" in
            *'"$RB_SCRIPTS"/pr-selfcheck.sh'*) ;;
            *'/usr/bin/env bash -p "$RB_SCRIPTS"/pr-'*) ;;
            *) printf '%s\n' "$line" ;;
        esac
    done
}
_unpriv="$(grep -F '"$RB_SCRIPTS"/pr-' "$SKILL" | rb_bare_invocations)"
# …AND THE COMMENT EXEMPTION IS NOT A LOOPHOLE, asserted through THE SAME
# classifier the scan above uses. An indented invocation with a trailing comment
# is the shape that slipped through the first version; a second copy of the logic
# would go on reporting it after the real one regressed, which is how a guard
# comes to pass on the state it exists to catch.
_probe_hit="$(printf '%s\n' '    "$RB_SCRIPTS"/pr-watch.sh N "$WHO"   # rationale' | rb_bare_invocations)"
[ -n "$_probe_hit" ] \
    && pass "…and an indented invocation with a trailing comment is still caught" \
    || die "the comment exemption swallows an indented call with a trailing comment"
[ -z "$_unpriv" ] \
    && pass "every helper the driver runs is started with /usr/bin/env bash -p" \
    || die "helper invocation(s) not started privileged:$_unpriv"
# …AND THE EXEMPTION IS ASSERTED, not just tolerated. A blanket prefix put
# `bash -p` in front of `pr-selfcheck.sh` too, which contradicted the contract in
# `CLAUDE.md` that names it the one helper started otherwise — two statements
# about one file, in different places, disagreeing. This fails if the driver ever
# starts it privileged, so the disagreement cannot come back silently.
# THE COMPLETE LINE, with `-x`. As a substring this needle is CONTAINED IN the
# regression it exists to catch: `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-selfcheck.sh;
# SELF_RC=$?` still matches it, and the scan above exempts every self-check line,
# so restoring the prefix would have left this file green — the assertion passing
# on the state it was written to reject.
#
# THE FILE, NOT `$skill_flat`: this block runs before that variable is built, and
# an empty haystack fails every case in it for a reason nobody would look for.
grep -qxF '"$RB_SCRIPTS"/pr-selfcheck.sh; SELF_RC=$?' "$SKILL" \
    && pass "…and pr-selfcheck.sh is invoked directly, as its own re-exec requires" \
    || die "pr-selfcheck.sh is not invoked directly; its clean-shell re-exec is the boundary, not bash -p"

# ── the reviewers are the GitHub apps, not a local process ─────────────────
grep -q 'chatgpt-codex-connector\[bot\]' "$SKILL" \
    && pass "skill names the Codex bot login" \
    || die "skill does not name chatgpt-codex-connector[bot]"
grep -q 'copilot-pull-request-reviewer\[bot\]' "$SKILL" \
    && pass "skill names the Copilot bot login" \
    || die "skill does not name copilot-pull-request-reviewer[bot]"
grep -q '@codex review' "$SKILL" \
    && pass "skill documents the @codex mention as the Codex trigger" \
    || die "skill does not document the @codex trigger"
grep -q 'add-reviewer @copilot' "$SKILL" \
    && pass "skill documents the Copilot review request" \
    || die "skill does not document requesting Copilot"

# v1's daemons must not come back by reference: a contract that still tells the
# driver to start a watcher would leave it waiting for a bus that no longer
# exists.
for gone in review-bus-codex-start review-bus-codex-watcher review-bus-response-monitor \
            review-bus-request review-bus-close-round 'systemd --user'; do
    grep -q -- "$gone" "$SKILL" \
        && die "skill still references the removed v1 machinery: $gone" \
        || pass "no reference to removed machinery ($gone)"
done

# ── the connector prerequisite is stated ───────────────────────────────────
# Without it @codex answers with a setup link, which is easy to misread as a
# review that found nothing.
grep -qi 'connect' "$SKILL" && grep -q 'connectors' "$SKILL" \
    && pass "skill states the one-time connector prerequisite" \
    || die "skill does not tell the operator to link the Codex connector"

# ── the round rules keep their polarity ────────────────────────────────────
# `SKILL.md` binds the SIZE of a round elsewhere; this is the one that binds its
# SHAPE, and it is the rule that ended each long run of rounds in this repository
# while every added check merely raised the cost of the next attempt. A later edit
# that drops it — or reverses it into a preference for guarding — leaves the
# driver with no instruction at all on the choice that matters most.
#
skill_flat="$(tr '\n' ' ' < "$SKILL" | tr -s ' ')" \
    || die "could not flatten SKILL.md"
# ANCHORED TO THE START OF THE LINE, which is the only place a negation cannot be
# put in front of. This took three attempts and each one was a substring the
# negation still contained:
#
#   `removing the dependency over guarding it`   ← `**Do not prefer …**` contains it
#   `**Prefer removing …**`                      ← `Do not **Prefer …**` contains it
#   `^**Prefer removing …**`                     ← nothing can precede it
#
# The lesson is not about this pattern. Twice I reasoned about what a reversal
# would look like instead of writing the one someone would actually write, and
# twice the reasoning was the thing that produced the hole.
#
# WHAT THIS CANNOT DO, so nobody mistakes it for more. It catches the instruction
# being DELETED or INVERTED IN PLACE, which is what a maintainer edit looks like.
# It cannot catch a negation added elsewhere — `… guarding it.** Do not follow
# this rule.` later in the same paragraph, or a contradiction in the next one.
# There is no anchor for that: every heading in this file is inline with its
# prose, so an end anchor would have to match the sentence that follows, which
# will legitimately be reworded; and the mutation simply moves to the next line.
# Establishing that prose does not contradict itself is reading, not grepping,
# and this repository has already built and deleted a 2,200-line scanner over
# exactly that boundary.
grep -q '^\*\*Prefer removing the dependency over guarding it\.\*\*' "$SKILL" \
    && pass "skill states the preference for removing a dependency over guarding it" \
    || die "skill no longer tells the driver to prefer removal over a guard"
# …AND THE HALF THAT MAKES THE CHOICE REVIEWABLE. Deleting the sentence that
# requires the reason, while leaving the preference heading in place, leaves a
# driver that still chooses correctly and never says why — and a finding thread
# without the reason is one nobody can check the choice against. `README.md`
# promises this behaviour too, so it is a separate assertion rather than an
# extension of the one above.
# THE LOCATION IS PART OF THE RULE, and this check did not carry it: rewriting
# `Say on the thread` to `Say in the round summary` left the trailing fragment
# intact and the check green. That edit puts the rationale in the comment that
# carries the `@codex review` mention, where a description of work still to be
# done is read as a work order — the incident this file records elsewhere — and
# it desynchronises the driver from the reviewer copies, whose own assertions
# were strengthened for this a round earlier while the shipped contract was left
# behind. FLATTENED and VERBATIM, because the clause wraps and because a
# fragment is what failed.
grep -qF 'Say on the thread which of the two you took and why' <<<"$skill_flat" \
    && pass "skill requires the choice to be explained, on the thread" \
    || die "skill no longer requires the driver to say on the thread which fix shape it took, and why"

# ── the fault-tolerance pass needs something to review ─────────────────────
#
# #55 was raised because it ran when the Copilot phase had produced no commits:
# both signoffs name one sha, the pass re-reviews what Codex already signed off,
# and it costs a revocation and a reopened phase for a verdict that cannot
# differ — a session resuming into that reopened phase reads it as a Copilot
# phase to run again.
#
# THE BRANCH IS NO LONGER HERE, and that is the fix rather than a gap. It moved
# into `pr-copilot-phase.sh close` in #78, where `test-pr-copilot-phase.sh` RUNS
# both halves and reads what each one offers — including the whitelist of option
# lines this file used to carry, which came with it. What was an anchored match on
# the spelling of a condition, allowed only because `SKILL.md`'s bash had no other
# coverage at all, is now an executed assertion. See CLAUDE.md § Tests.
#
# WHAT IS ASSERTED HERE INSTEAD is that the driver still DELEGATES. A `SKILL.md`
# that quietly grew the block back — or that dropped the call and left the phase
# closing by hand — would pass every check in the other file, because that file
# only ever sees the script.
#
# THE WHOLE LINE, UNFLATTENED, and that is not a style choice. Four assertions
# across this file depend on this call's arguments, and every one of them was
# satisfied by a USAGE COMMENT nine hundred lines earlier: `$skill_flat` is built
# with `tr -s ' '`, which squeezes that comment's aligned double space into
# exactly the substring they searched for. The driver could have passed the
# current head, or hard-coded `both`, with all four green. Matching the complete
# line in the raw file removes the dependency on the flattening AND on the
# substring, rather than guarding either — see CLAUDE.md § One change per review
# round.
RB_CLOSE_CALL='/usr/bin/env bash -p "$RB_SCRIPTS"/pr-copilot-phase.sh close N "$CODEX_SHA" "$REVIEWERS"'
rb_close_call_present() { grep -qxF "$RB_CLOSE_CALL" "$SKILL"; }
rb_close_call_present \
    && pass "the post-Copilot close is delegated to the phase script" \
    || die "SKILL.md does not call the close stage as: $RB_CLOSE_CALL"
# …AND EVERY STAGE ACTS ON THE REPOSITORY THIS SESSION STARTED IN, which is now a
# property of the SETUP rather than of each call site.
#
# `pr-copilot-phase.sh` and every helper it drives derive their identity by
# running `git remote get-url origin` in their own process, from the current
# directory. A `cd` into a second checkout — an ordinary thing for a driving
# session to do — therefore pointed the stages at whatever PR of THAT repository
# shares this number, and each of them POSTS: `record` a signoff, `open` a
# revocation and a review request, and `close` the second signoff on the
# two-reviewer path — `codex-only` records nothing, having no Copilot review to
# re-check.
#
# THE DEPENDENCY IS REMOVED, NOT GUARDED. The guard was `(cd "$REPO_DIR" && …)`
# around each call, and it had two defects that are the same defect: `cd` is a
# NAME, so a function named `cd` returning 0 without moving leaves the subshell
# reporting success from the wrong tree; and a rule applied per-call-site is a
# list, so a fourth stage would be added unwrapped and this file would have said
# every stage was covered. Exporting `REVIEW_BUS_REMOTE` once, from a value read
# once, has neither property — `rb_identity` documents it as the caller STATING
# the identity rather than deriving it, no name in the chain can be shadowed, and
# a stage added tomorrow inherits it without anyone remembering to.
#
# `$REPO_DIR` REMAINS, for a different question: `pr-merge-range.sh` inspects
# HISTORY, which is a tree and not an identity, so the merge gate keeps its `cd`.
# ── the session is pinned out of the setup helper's own file ──────────────
#
# THE EXPORT MOVED, and this is where that shows. It was
# `export REVIEW_BUS_REMOTE="$RB_REMOTE"` in the document; since #228 the helper
# writes both the assignment and the `export` into the file this shell SOURCES, so
# the grep that used to find it in `SKILL.md` finds nothing and would have to be
# deleted rather than moved. What replaced it is stronger: the pin is proved by a
# CHILD further down, which is the question the export exists to answer.
grep -qF '. "$RB_SETUP_DIR/env"' <<<"$skill_flat" \
    && pass "the session's values arrive by sourcing the helper's file" \
    || die "SKILL.md does not source the setup helper's environment file"
if [ -f "$SCRIPT_DIR/pr-setup.sh" ]; then
    { grep -qF 'rb_setup_put REVIEW_BUS_REMOTE' "$SCRIPT_DIR/pr-setup.sh" \
      && grep -qF "printf 'export REVIEW_BUS_REMOTE" "$SCRIPT_DIR/pr-setup.sh"; } \
        && pass "…and that file carries the pin as an assignment and an export" \
        || die "pr-setup.sh does not write REVIEW_BUS_REMOTE and its export"
fi
# …AND THE HELPER IS REACHED BY PATH AND STARTED PRIVILEGED, with its status taken.
# `pr-setup.sh` reached bare would leave the kernel to process its shebang, putting
# the `env -S` requirement back through the side door — and a helper that writes a
# plausible env file and then fails must not be sourced.
grep -qF '/usr/bin/env bash -p "$RB_SCRIPTS"/pr-setup.sh "$RB_SETUP_DIR"' <<<"$skill_flat" \
    && pass "…from a helper reached by path and started privileged" \
    || die "the setup helper is not invoked as /usr/bin/env bash -p by pathname"
# THE DIRECTORY NAME IS BUILT BY EXPANSION, so no command answers for it, and the
# `:?` is what refuses where neither parent was usable.
grep -qF 'RB_SETUP_DIR="${RB_TMPPARENT:?neither TMPDIR nor HOME is an absolute directory this session can write to}/watch-pr-setup.$$.$RANDOM$RANDOM$RANDOM"' "$SKILL" \
    && pass "…and the setup directory is named by expansion, not by a command" \
    || die "SKILL.md does not build the setup directory name by expansion"
# AND THE NAMES THE HELPER NOW OWNS ARE GONE, not merely unused. `RB_ORIGIN_DIR`,
# `RB_ORIGIN_OUT`, `RB_PIN_DIR`, `RB_TMPDIR` and the candidate loop were the driver's
# transport machinery; every state this file used to stage was about one of them, and
# a survivor means the region came back.
_rb_gone=""
_rb_gone="$(grep -v '^[[:space:]]*#' "$SKILL" | grep -nE 'RB_ORIGIN_DIR|RB_ORIGIN_OUT|RB_PIN_DIR|\$\{RB_TMPDIR|RB_TRY=|for RB_TMPPARENT in' || true)"
[ -z "$_rb_gone" ] \
    && pass "…and the driver's old transport names are gone from the document" \
    || die "a name the helper now owns is back in SKILL.md: $_rb_gone"
# WHAT WAS READ IS REMOVED AND THE WORK DIRECTORY IS NOT. The env file and the pin
# leaf are transports whose contents are in this shell the moment they are read; the
# setup directory holds `work/`, which is the session's four working files and the
# thing the call was made to produce. Removing it would be removing the product.
grep -qF '/usr/bin/env rm -f "$RB_SETUP_DIR/env"' <<<"$skill_flat" \
    && pass "…the env file is removed once it has been sourced" \
    || die "the sourced env file is left on disk"
# BY NAME AND THEN `rmdir`, NEVER RECURSIVELY. `$RB_SETUP_DIR` is published in argv,
# so a `rm -rf` on a leaf under it deletes whatever a replacement holds — the same
# regression `pr-setup.sh` already fixed, arriving by the other route, and past what
# `docs/decisions/2026-08-26-reservation-inference.md` accepts.
{ grep -qF '/usr/bin/env rm -f "$RB_SETUP_DIR/pin/pin"' <<<"$skill_flat" \
  && grep -qF '/usr/bin/env rmdir "$RB_SETUP_DIR/pin"' <<<"$skill_flat"; } \
    && pass "…and the pin leaf once its descriptor has been read, by name and then rmdir" \
    || die "the pin directory is left on disk, or is removed recursively"
case "$skill_flat" in
    *'rm -rf "$RB_SETUP_DIR'*) die "SKILL.md removes something under the setup directory recursively" ;;
    *) pass "…with no recursive removal anywhere under the published setup path" ;;
esac
case "$skill_flat" in
    *'rm -rf "$RB_SETUP_DIR"'[!/]*|*'rm -rf "$RB_SETUP_DIR"')
        die "SKILL.md removes the setup directory, which holds the session's working files" ;;
    *)  pass "…while the setup directory itself is kept, being the session's own" ;;
esac

# THE BLOCK LIFTS OUT WHOLE, from the probe that opens it to the `fi` that closes
# it. One range, whole by construction: every refusal in it is an `else` arm, so a
# lift that stopped short would drop the arms it is here to test.
#
# WITH THE LIBRARY THE SURROUNDING SETUP SOURCES. `rb_identity` is loaded above this
# range, so the lift calls a function it does not carry; prepending the load is the
# lift's own scaffolding, and `$RB_SCRIPTS` is where each case below points anyway.
_setup_body=""
_setup_body="$(awk '/^if \( RB_TMPPARENT="RbProbe/, /^fi$/' "$SKILL")" || _setup_body=""
[ -z "$_setup_body" ] || _setup_body='. "$RB_SCRIPTS/identitylib.sh"
'"$_setup_body"
{ [ -n "$_setup_body" ] \
  && case "$_setup_body" in *'/pr-setup.sh "$RB_SETUP_DIR"'*) true ;; *) false ;; esac \
  && case "$_setup_body" in *'. "$RB_SETUP_DIR/env"'*) true ;; *) false ;; esac \
  && case "$_setup_body" in *'REVIEW_BUS_REMOTE="$RB_REMOTE" rb_identity'*) true ;; *) false ;; esac \
  && case "$_setup_body" in *'/pr-origin.sh pin "$RB_SETUP_DIR/pin"'*) true ;; *) false ;; esac; } \
    && pass "…and the setup block lifts out with the call, the source and the pin" \
    || die "the setup block is truncated or has lost what it is about: '$_setup_body'"
printf '%s\n' "$_setup_body" | bash -n 2>/dev/null \
    && pass "…and the lift parses on its own" \
    || die "the lifted setup block does not parse; SKILL.md's nesting changed and the lift did not"

# ── whether this shell has a case-transforming attribute ──────────────────
# `declare -l` is bash 4.0+, and the cases below use it to prove that a probe
# reading only an assignment's STATUS is not enough. On the 3.2.57 path the
# attribute line itself fails, and under this file's `set -e` a case would die
# before reaching any refusal — reporting a probe broken on a shell where the
# attribute it tests does not exist. So the shell is ASKED, and the skip is
# announced by name rather than being silent.
#
# ASKED WITH AN `if`, NOT AN `&&` LIST. Written as `( declare -l … ) && _rb_has_l=yes`
# the list itself reports 1 on a shell without the attribute, and under `set -e`
# that ends the run — on exactly the path the probe exists to accommodate.
_rb_has_l=no
if ( declare -l _rb_probe_l=A ) 2>/dev/null; then _rb_has_l=yes; fi
# AND `declare -n`, WHICH IS 4.3+. The alias cases below need it, and they need it
# named here rather than where the first of them runs — a capability asked for
# twice is a capability two answers can disagree about.
_rb_has_n=no
if ( declare -n _rb_probe_n=_rb_probe_target ) 2>/dev/null; then _rb_has_n=yes; fi
[ "$_rb_has_l" = yes ] \
    && pass "this shell has declare -l, so the case-transforming states run" \
    || pass "this shell has no declare -l, so those states are skipped by name"

# ── ONE GENERIC PROBE OVER THE THREE NAMES ────────────────────────────────
#
# It used to be an enumeration tied to `pr-selfcheck.sh`'s `KNOWN` list, and that was
# the wrong inventory: `KNOWN` is what the DRIVER reads, `GIT_DIR` is read by `git`
# inside the helpers, and `CDPATH` is consulted by the shell itself. Three
# inventories, the last growing with the shell version — a list that cannot be
# completed.
#
# `${!name}` REPLACES ALL OF IT. For a NAMEREF it expands to the target's NAME; for
# an ordinary variable it is indirect expansion, the value of the variable NAMED by
# this one. Assign a legal-but-unset variable name and require `${!name}` to be
# empty: an ordinary variable names nothing, a nameref names whatever it points at.
#
# THE PREFIX MATCH IS THE OTHER HALF, and it is what catches a readonly or a
# transforming attribute — MIXED CASE, because an all-caps sentinel survives
# `declare -u` unchanged and that attribute got through once.
for _tn in RB_TMPPARENT RB_TMPPARENT2 RB_SETUP_DIR; do
    grep -q "( $_tn=\"RbProbe\$\$\$RANDOM\$RANDOM\"; \[\[ \$$_tn = RbProbe\* \]\]" <<<"$_setup_body" \
        || die "the setup probe does not assign a random RbProbe sentinel to \$$_tn and match it"
    grep -q "\[\[ -z \${!$_tn:-} \]\]" <<<"$_setup_body" \
        || die "the setup probe does not test \${!$_tn} for a nameref"
done
pass "the setup probe detects an alias generically, and an attribute by the prefix match"
# …AND `unset RANDOM` DOES NOT MAKE THE SENTINEL FIXED. `unset RANDOM` removes its
# special behaviour, so every later `$RANDOM` is empty — and a sentinel built from
# `$RANDOM` alone becomes the literal `RbProbe`, which an operator can hold, after
# which `${!name}` reads THEIR variable and a valid shell is refused. `$$` is the
# shell's own pid and cannot be unset, so it is in every sentinel.
# COUNTED OVER THE CODE, NOT THE PROSE. The comment beside the probes discusses
# `RbProbe$$` as the attacker's pre-seed, and a file-wide count read that as a
# sentinel spelled without the pid.
_ur_src=""; _ur_src="$(grep -v '^[[:space:]]*#' "$SKILL")" || _ur_src=""
_ur=0; _ur="$(grep -c 'RbProbe\$\$\$RANDOM\$RANDOM' <<<"$_ur_src")" || _ur=0
_ur_all=0; _ur_all="$(grep -c 'RbProbe\$' <<<"$_ur_src")" || _ur_all=0
{ [ "$_ur" -gt 0 ] && [ "$_ur" = "$_ur_all" ]; } \
    && pass "every probe sentinel carries the pid, so unset RANDOM cannot make it fixed" \
    || die "a probe sentinel is built from \$RANDOM alone (with-pid=$_ur total=$_ur_all)"
# …AND NO FIXED SENTINEL SURVIVES. A fixed value COLLIDES: with two fixed pairs and
# an operator holding one value from each, both pairs failed and a shell nothing had
# corrupted was refused.
case "$_setup_body" in
    *Probe-A*|*Probe-B*|*Probe-C*|*Probe-D*)
        die "a fixed probe sentinel remains; an operator holding that value is refused" ;;
    *) pass "…with no fixed sentinel left to collide with an operator's own value" ;;
esac

# ── the forged helpers, and the states they let a case reach ──────────────
_forge_dir=""
_forge_dir="$(mktemp_d)" || die "no scratch directory for the setup probes"
# EVERY SETUP DIRECTORY THESE CASES MAKE LANDS UNDER IT. The lifted block creates
# its own, as setup does, and the cleanup probe near the end of this file runs the
# whole fixture with `TMPDIR` pointed at a scratch tree and fails if anything is left
# in it — so a `mktemp -d` taking the ambient `TMPDIR` here is reported as the leak
# it is.
[ -n "$_forge_dir" ] && export RB_TMPBASE="$_forge_dir"
if [ -n "$_forge_dir" ]; then
    cp "$SCRIPT_DIR/identitylib.sh" "$_forge_dir/" 2>/dev/null || true
    # AN INHERITED FORGE VARIABLE IS CLEARED FIRST. `pr-selfcheck.sh` clears
    # inherited FUNCTIONS and the hook variables; it deliberately does not clear
    # arbitrary exported values, because `SKILL.md` pins the session by exporting
    # one. So a fixture whose subject is an env-driven override clears it ITSELF.
    #
    # ALL OF THEM, not the one that bit. `FORGE_SETUP_RC` exported as 1 turns every
    # case that expects the helper to SUCCEED into a refusal — including the controls
    # whose whole job is to stop the refusal cases passing vacuously — and an
    # exported `FORGE_VALUE` makes every case comparing against the forged origin
    # compare against something else.
    #
    # THE POISON IS SEEDED HERE, so the clearing is what removes it. Left to the
    # invoking environment, the proof below observes the defaults on a clean machine
    # whether the names are cleared or not.
    _fe_log="$_forge_dir/forge-log-that-must-not-exist"
    export FORGE_LOG="$_fe_log" FORGE_RC=1 FORGE_VALUE='git@github.com:squatter/other.git' \
           FORGE_LEAF_DIR=1 FORGE_PIN_ECHO=1 FORGE_PIN_VALUE=x FORGE_PIN_EXTRA=1 FORGE_SETUP_RC=1 FORGE_SETUP_LOG="$_fe_log" \
           FORGE_NOENV=1 FORGE_PATHS=elsewhere FORGE_NONEMPTY=1 FORGE_ENV_EXTRA=x
    unset FORGE_LOG FORGE_RC FORGE_VALUE FORGE_LEAF_DIR FORGE_PIN_ECHO FORGE_PIN_VALUE FORGE_PIN_EXTRA FORGE_SETUP_RC \
          FORGE_SETUP_LOG FORGE_NOENV FORGE_PATHS FORGE_NONEMPTY FORGE_ENV_EXTRA
    cat > "$_forge_dir/pr-origin.sh" <<'FORGE'
#!/usr/bin/env bash
[ -n "${FORGE_LOG:-}" ] && printf '%s %s\n' "$1" "$2" >> "$FORGE_LOG"
mkdir -m 700 "$2" || exit 1
case "$1" in pin) _leaf=pin ;; *) _leaf=origin ;; esac
# THE LEAF CAN BE MADE SOMETHING THE READ-BACK REJECTS, which is the only way to
# reach the arm that refuses it. A DIRECTORY is what this uses: the caller's `9<`
# opens it, `[[ -O ]]` passes because this run made it, and `[[ -f ]]` is false — so
# the rejection comes from the check the arm exists for rather than from a missing
# file, which any earlier step would have refused first.
# AND IT CAN LEAVE MORE THAN THE LEAF, which is what a REPLACEMENT of the published
# pin directory looks like from the caller's side: the name it removes is one another
# process may have put its own contents at.
if [ -n "${FORGE_PIN_EXTRA:-}" ] && [ "$1" = pin ]; then
    mkdir "$2/squatter-subdir" || exit 1
    printf 'not the drivers\n' > "$2/witness" || exit 1
fi
if [ -n "${FORGE_LEAF_DIR:-}" ]; then
    mkdir "$2/$_leaf" || exit 1
else
    # AND `pin` CAN ANSWER WITH WHAT A CHILD ACTUALLY SEES, which is what the real
    # helper does. Writing `FORGE_VALUE` there instead makes the pin proof compare
    # the driver's value against a constant, so a case where the DRIVER's value was
    # replaced sees a mismatch and reports a refused pin — fail-closed, but for the
    # wrong reason, and it hides the outcome the case is about.
    if [ -n "${FORGE_PIN_ECHO:-}" ] && [ "$1" = pin ]; then
        printf '%s\n' "${REVIEW_BUS_REMOTE-}" > "$2/$_leaf"
    else
        printf '%s\n' "${FORGE_PIN_VALUE-${FORGE_VALUE-git@github.com:acme/widget.git}}" > "$2/$_leaf"
    fi
fi
exit "${FORGE_RC:-0}"
FORGE
    # AND THE SETUP FORGE, which follows `pr-setup.sh`'s contract: one directory it
    # creates, an `env` file inside it, and `work/` holding the four files created
    # empty. Its own names throughout — a forge sharing `FORGE_RC` with the pin one
    # cannot express "setup succeeded and the pin failed", which is a case below.
    cat > "$_forge_dir/pr-setup.sh" <<'FORGE'
#!/usr/bin/env bash
[ -n "${FORGE_SETUP_LOG:-}" ] && printf '%s\n' "$1" >> "$FORGE_SETUP_LOG"
# A COUNTER, so a case can make the FIRST call fail and the second succeed — which is
# the retry, and the only way to reach the second arm of the call. The status is the
# case's to choose, because the driver retries only on 2.
if [ -n "${FORGE_SETUP_FAIL_FIRST:-}" ]; then
    _n=0; [ -f "$FORGE_SETUP_FAIL_FIRST" ] && _n="$(cat "$FORGE_SETUP_FAIL_FIRST")"
    _n=$((_n + 1)); printf '%s\n' "$_n" > "$FORGE_SETUP_FAIL_FIRST"
    [ "$_n" = 1 ] && exit "${FORGE_SETUP_FIRST_RC:-2}"
fi
mkdir -m 700 "$1" || exit 1
mkdir -m 700 "$1/work" || exit 1
for _f in summary.md request.md prior.txt head.txt; do
    if [ -n "${FORGE_NONEMPTY:-}" ]; then printf 'stale\n' > "$1/work/$_f"; else : > "$1/work/$_f"; fi
done
if [ -z "${FORGE_NOENV:-}" ]; then
    _w="$1/work"
    [ -n "${FORGE_PATHS:-}" ] && _w="${FORGE_PATHS}"
    # QUOTED THE WAY THE REAL HELPER QUOTES, because a forge that writes its values
    # more naively is testing its own escaping rather than the driver's source: a
    # value carrying `'` would break out of the assignment here and the case would
    # report the document executing something the helper would never have written.
    _q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
    _fv="${FORGE_VALUE-git@github.com:acme/widget.git}"
    {
        printf 'REVIEW_BUS_REMOTE=%s\n' "$(_q "$_fv")"
        printf 'export REVIEW_BUS_REMOTE\n'
        printf 'RB_REMOTE=%s\n'    "$(_q "$_fv")"
        printf "OWNER='%s'\n"        "${FORGE_OWNER-acme}"
        printf "REPO='%s'\n"         "${FORGE_REPO-widget}"
        printf "HOST='%s'\n"         "${FORGE_HOST-github.com}"
        printf "SUMMARY_FILE='%s'\n" "$_w/summary.md"
        printf "REQUEST_FILE='%s'\n" "$_w/request.md"
        printf "PRIOR_FILE='%s'\n"   "$_w/prior.txt"
        printf "HEAD_FILE='%s'\n"    "$_w/head.txt"
        [ -n "${FORGE_ENV_EXTRA:-}" ] && printf '%s\n' "$FORGE_ENV_EXTRA"
    } > "$1/env"
fi
exit "${FORGE_SETUP_RC:-0}"
FORGE
    # …AND THE CLEARING IS PROVEN, by asking both forges what their environment says.
    # An inherited `FORGE_SETUP_RC=1` shows up as the refusal every success case would
    # have got, and an inherited `FORGE_VALUE` as a value no case expects — which is
    # what makes this a proof rather than a restatement of the `unset` above it.
    _fe_dir="$_forge_dir/envproof"
    _fe_rc=0; bash "$_forge_dir/pr-setup.sh" "$_fe_dir" || _fe_rc=$?
    _fe_val=""; _fe_val="$(grep '^RB_REMOTE=' "$_fe_dir/env" 2>/dev/null)" || _fe_val=""
    { [ "$_fe_rc" -eq 0 ] && [ "$_fe_val" = "RB_REMOTE='git@github.com:acme/widget.git'" ] \
      && [ ! -e "$_fe_log" ]; } \
        && pass "the forged helpers inherit none of the FORGE_ names this file seeds" \
        || die "a forge saw an inherited value (rc=$_fe_rc value='$_fe_val' log-exists=$([ -e "$_fe_log" ] && echo yes || echo no))"
    rm -rf "$_fe_dir"

    # THE ORDINARY CASE FIRST, or every refusal below passes against a block that
    # refuses unconditionally and starts no session at all.
    _su_ok=0
    _su_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _su_ok=$?
    { [ "$_su_ok" -eq 0 ] \
      && case "$_su_out" in *'OWNER=acme REPO=widget'*) true ;; *) false ;; esac \
      && case "$_su_out" in *'PINNED=[git@github.com:acme/widget.git]'*) true ;; *) false ;; esac; } \
        && pass "a good setup sources its values, proves the pin and announces itself" \
        || die "the setup block refused a good run (rc=$_su_ok out='$_su_out')"
    # …AND THE FOUR WORKING PATHS REACH THE DRIVER. They are what every later stage
    # is handed, and a block that sourced them and then lost them would satisfy the
    # case above — the success line names only one of the four.
    _su_p="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
            printf "P=[%s][%s][%s][%s]\n" "${SUMMARY_FILE-}" "${REQUEST_FILE-}" "${PRIOR_FILE-}" "${HEAD_FILE-}"
        ' 2>&1)" || true
    case "$_su_p" in
        *'P=['*'/work/summary.md]['*'/work/request.md]['*'/work/prior.txt]['*'/work/head.txt]'*)
            pass "…and all four working paths arrive in the driving shell" ;;
        *)  die "the working paths did not arrive: '$_su_p'" ;;
    esac
    # …AND A HELPER THAT WRITES A USABLE FILE AND THEN FAILS PINS NOTHING. This is
    # the shape the status check exists for: one that failed to write would be refused
    # by the source, and the block would look correct with no handler at all.
    _su_rc=0
    _su_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_SETUP_RC=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _su_rc=$?
    { [ "$_su_rc" -ne 0 ] \
      && case "$_su_out" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "…while a helper that writes a usable file and then fails pins nothing" \
        || die "setup pinned from a failed helper (rc=$_su_rc out='$_su_out')"
    # …AND THE ABORT POINTS AT THE HELPER'S OWN LINES rather than counting attempts.
    # Reaching that arm means the first call failed and the second either was not made
    # or failed too, and the three reasons differ — no second candidate, a TERMINAL
    # first refusal the status gate skipped, or a second refusal.
    case "$_su_out" in
        *'each ABORT line above is one attempt and its reason'*)
            pass "…and the abort points at the helper's lines rather than counting attempts" ;;
        *)  die "the setup abort does not point at the helper's lines: '$_su_out'" ;;
    esac
    # …AND IT SURVIVES A SHADOWED `echo`. The refusal is an arm the block cannot walk
    # past; a silenced `echo` costs the operator the reason, never the refusal.
    _su_e=0
    _su_eo="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_SETUP_RC=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            echo() { :; }
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _su_e=$?
    { [ "$_su_e" -ne 0 ] \
      && case "$_su_eo" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "…and a shadowed echo does not turn the refusal into a session" \
        || die "a shadowed echo let setup continue (rc=$_su_e out='$_su_eo')"
    # …AND A NEUTRALISED `exit` DOES NOT WALK PAST IT EITHER. Every refusal is an
    # `else` arm whose success path is the other arm, so containment is POSITION and
    # not the `exit` — which is the one thing a startup file can neutralise.
    _su_x=0
    _su_xo="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_SETUP_RC=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" \
        'BASH_FUNC_exit%%=() { return 0; }' bash -c '
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _su_x=$?
    case "$_su_xo" in
        *'PINNED=[git@'*) die "a neutralised exit let setup pin the session: '$_su_xo'" ;;
        *)                pass "…and a neutralised exit reaches no pin, because the refusal is an arm" ;;
    esac
    # …AND THE SAME INTERACTIVELY, where `:?` abandons the enclosing compound command
    # instead of ending the shell. The `if` the block opens IS that compound command,
    # so setup stops either way — but only because the success path is inside it.
    _su_i=0
    _su_io="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_SETUP_RC=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" \
        'BASH_FUNC_exit%%=() { return 0; }' bash -i -c '
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _su_i=$?
    case "$_su_io" in
        *'PINNED=[git@'*) die "the interactive neutralised-exit case pinned the session: '$_su_io'" ;;
        *)                pass "…and interactively too, where the shell does not end" ;;
    esac

    # …AND A PARENT CONTAINING A SPACE IS AN ORDINARY PARENT. The driver builds the
    # setup directory's name under `$TMPDIR` or `$HOME`, and an operator's home
    # directory can contain one — this is the driver-to-helper half of that, because
    # the name crosses a process boundary in argv and comes back inside a sourced
    # path. A character class in the helper refused it once, terminally, so the
    # second parent was never tried and the session ended on a path that works.
    _sp_dir="$_forge_dir/parent with space"
    mkdir -p "$_sp_dir"
    _sp=0
    _sp_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 TMPDIR="$_sp_dir" HOME="$_sp_dir" bash -c '
            '"$_setup_body"'
            printf "S=[%s]\n" "${SUMMARY_FILE-}"
        ' 2>&1)" || _sp=$?
    { [ "$_sp" -eq 0 ] \
      && case "$_sp_out" in *'OWNER=acme REPO=widget'*) true ;; *) false ;; esac \
      && case "$_sp_out" in *"S=[$_sp_dir/"*'/work/summary.md]'*) true ;; *) false ;; esac; } \
        && pass "a parent containing a space starts a session and the paths survive the source" \
        || die "a spaced parent was refused or its paths were mangled (rc=$_sp out='$_sp_out')"
    rm -rf "$_sp_dir"

    # ── the retry, and what it is gated on ────────────────────────────────
    # A STORAGE REFUSAL IS RETRIED UNDER THE OTHER PARENT. Status 2 means both
    # ancestry walks passed and the STORAGE would not take what was asked; another
    # parent is exactly what fixes that.
    _su_cnt="$_forge_dir/setup-calls"
    # BOTH PARENTS EXIST AND ARE DISTINCT, so the selection has two candidates to
    # choose between: a missing directory is refused by the `-d` test, and the case
    # would then be measuring the empty-parent refusal instead of the retry.
    mkdir -p "$_forge_dir/t1" "$_forge_dir/t2"
    rm -f "$_su_cnt" "$_forge_dir/setup-log"
    _su_r=0
    _su_ro="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 FORGE_SETUP_FAIL_FIRST="$_su_cnt" FORGE_SETUP_FIRST_RC=2 \
        FORGE_SETUP_LOG="$_forge_dir/setup-log" \
        TMPDIR="$_forge_dir/t1" HOME="$_forge_dir/t2" bash -c '
            '"$_setup_body"'
            printf "PARENT=[%s]\n" "$RB_TMPPARENT"
        ' 2>&1)" || _su_r=$?
    _su_n=0; _su_n="$(grep -c . "$_forge_dir/setup-log" 2>/dev/null)" || _su_n=0
    { [ "$_su_r" -eq 0 ] && [ "$_su_n" -eq 2 ]; } \
        && pass "a storage refusal is retried under the second parent" \
        || die "the setup call did not retry (rc=$_su_r calls=$_su_n out='$_su_ro')"
    # …AND `RB_TMPPARENT` FOLLOWS THE PARENT THAT WORKED. The working directory is
    # built from it, and a retry that read the setup from `HOME` while leaving the name
    # on `TMPDIR` then died allocating under the full filesystem it had just left.
    case "$_su_ro" in
        *"PARENT=[$_forge_dir/t2]"*) pass "…and RB_TMPPARENT follows the parent that worked" ;;
        *) die "the retry left RB_TMPPARENT on the parent that refused: '$_su_ro'" ;;
    esac
    # …AND A TERMINAL REFUSAL IS NOT RETRIED. Status 1 is about the path or the
    # checkout, and another parent fixes none of that: retrying it is a second failure
    # and an operator who is told about neither.
    rm -f "$_su_cnt" "$_forge_dir/setup-log"
    _su_t=0
    _su_to="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_SETUP_FAIL_FIRST="$_su_cnt" FORGE_SETUP_FIRST_RC=1 \
        FORGE_SETUP_LOG="$_forge_dir/setup-log" \
        TMPDIR="$_forge_dir/t1" HOME="$_forge_dir/t2" bash -c '
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _su_t=$?
    _su_tn=0; _su_tn="$(grep -c . "$_forge_dir/setup-log" 2>/dev/null)" || _su_tn=0
    { [ "$_su_t" -ne 0 ] && [ "$_su_tn" -eq 1 ] \
      && case "$_su_to" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "…while a terminal refusal is not retried" \
        || die "a terminal refusal was retried (rc=$_su_t calls=$_su_tn out='$_su_to')"
    # …AND THE TWO CANDIDATE NAMES DIFFER. Both are built from `$$` and `$RANDOM`, and
    # a retry under a second parent that produced the SAME leaf name would meet the
    # directory the first attempt left behind and be refused by the exclusion.
    _su_d1=""; _su_d1="$(grep -c . "$_forge_dir/setup-log" 2>/dev/null)" || _su_d1=0
    rm -f "$_su_cnt" "$_forge_dir/setup-log"
    env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 FORGE_SETUP_FAIL_FIRST="$_su_cnt" FORGE_SETUP_FIRST_RC=2 \
        FORGE_SETUP_LOG="$_forge_dir/setup-log" \
        TMPDIR="$_forge_dir/t1" HOME="$_forge_dir/t2" bash -c "$_setup_body" >/dev/null 2>&1 || true
    _su_a=""; _su_a="$(head -1 "$_forge_dir/setup-log" 2>/dev/null)" || _su_a=""
    _su_b=""; _su_b="$(sed -n '2p' "$_forge_dir/setup-log" 2>/dev/null)" || _su_b=""
    { [ -n "$_su_a" ] && [ -n "$_su_b" ] && [ "$_su_a" != "$_su_b" ]; } \
        && pass "…and the two attempts name different directories" \
        || die "the two candidates collided (first='$_su_a' second='$_su_b')"
    # …AND THE RETRY IS GATED ON THE STATUS, IN THE CONDITION ITSELF. `$?` is taken
    # FIRST inside the `elif`-shaped arm, because a command between would replace it,
    # and the read-back stays inside that arm's own success path — so nothing becomes
    # a statement after a guard.
    grep -qF '{ [[ $? -eq 2 ]] && [[ -n $RB_TMPPARENT2 ]]' <<<"$_setup_body" \
        && pass "…with the retry gated on the reservation status in the condition itself" \
        || die "the setup retry does not gate on the reservation status"

    # ── the parents, and what makes one usable ────────────────────────────
    # A RELATIVE `TMPDIR` IS NOT SELECTED. The name is published in argv and the
    # helper resolves it against its own working directory, so a relative parent is a
    # directory neither side agrees on.
    _rel=0
    _rel_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 TMPDIR=.tmp HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
            printf "PARENT=[%s]\n" "$RB_TMPPARENT"
        ' 2>&1)" || _rel=$?
    { [ "$_rel" -eq 0 ] && case "$_rel_out" in *"PARENT=[$_forge_dir]"*) true ;; *) false ;; esac; } \
        && pass "a relative TMPDIR is passed over for HOME rather than used" \
        || die "a relative TMPDIR was selected or refused (rc=$_rel out='$_rel_out')"
    # …AND AN UNWRITABLE ONE IS NOT COMMITTED TO EITHER. `-w` and `-x` as well as
    # `-d`, because "can hold a directory" is what the fallback is for.
    _unw_dir="$_forge_dir/unwritable"
    mkdir -p "$_unw_dir" && chmod 500 "$_unw_dir"
    _unw=0
    _unw_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 TMPDIR="$_unw_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
            printf "PARENT=[%s]\n" "$RB_TMPPARENT"
        ' 2>&1)" || _unw=$?
    chmod 700 "$_unw_dir" 2>/dev/null || true
    { [ "$_unw" -eq 0 ] && case "$_unw_out" in *"PARENT=[$_forge_dir]"*) true ;; *) false ;; esac; } \
        && pass "…and an unwritable TMPDIR is passed over for HOME" \
        || die "an unwritable TMPDIR was committed to (rc=$_unw out='$_unw_out')"
    # …AND A RELATIVE `HOME` IS NOT ACCEPTED AS THE SECOND EITHER.
    _relh=0
    _relh_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 TMPDIR="$_forge_dir" HOME=rel bash -c '
            '"$_setup_body"'
            printf "SECOND=[%s]\n" "${RB_TMPPARENT2-}"
        ' 2>&1)" || _relh=$?
    { [ "$_relh" -eq 0 ] && case "$_relh_out" in *'SECOND=[]'*) true ;; *) false ;; esac; } \
        && pass "…while a relative HOME leaves no second candidate at all" \
        || die "a relative HOME was accepted (rc=$_relh out='$_relh_out')"
    # …AND WITH NEITHER USABLE, THE EXPANSION REFUSES AND SAYS SO. That refusal is the
    # `${RB_TMPPARENT:?…}`: the shell declining to expand, with no command in it to
    # shadow, and no helper is ever called.
    rm -f "$_forge_dir/setup-log"
    _ep=0
    _ep_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_SETUP_LOG="$_forge_dir/setup-log" TMPDIR=rel1 HOME=rel2 bash -c '
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _ep=$?
    { [ "$_ep" -ne 0 ] && [ ! -s "$_forge_dir/setup-log" ] \
      && case "$_ep_out" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "…and with neither parent usable no helper is called and nothing is pinned" \
        || die "an empty parent was walked past (rc=$_ep out='$_ep_out' log=$(cat "$_forge_dir/setup-log" 2>/dev/null))"
    grep -q 'neither TMPDIR nor HOME is an absolute directory' <<<"$_ep_out" \
        && pass "…refusing by the expansion's own message" \
        || die "the empty-parent refusal is silent: '$_ep_out'"

    # ── what the source brings in is re-proved ────────────────────────────
    # A MISSING ENV FILE IS A REFUSAL, not a session with no values. The helper
    # reported success here, which is the state a source can be the only thing to
    # catch.
    _ne=0
    _ne_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_NOENV=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _ne=$?
    { [ "$_ne" -ne 0 ] && case "$_ne_out" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "a helper that reports success with no env file is refused" \
        || die "a missing env file was walked past (rc=$_ne out='$_ne_out')"
    # …AN EMPTY ORIGIN IS REFUSED. `rb_identity` falls back to `git remote get-url`
    # with an empty `REVIEW_BUS_REMOTE`, so this is the state where the session looks
    # entirely successful while every child routes by the current directory.
    _mt=0
    _mt_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_VALUE= TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _mt=$?
    { [ "$_mt" -ne 0 ] && case "$_mt_out" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "…and a sourced origin that is empty is refused" \
        || die "an empty sourced origin was accepted (rc=$_mt out='$_mt_out')"
    # …A MULTI-LINE ONE IS REFUSED. An interior newline means something wrote to that
    # file between the helper and this shell; the value is not an origin.
    _ml=0
    _ml_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_VALUE='git@github.com:acme/widget.git
git@github.com:squatter/other.git' TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _ml=$?
    { [ "$_ml" -ne 0 ] && case "$_ml_out" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "…and one spanning more than one line is refused" \
        || die "a multi-line sourced origin was accepted (rc=$_ml out='$_ml_out')"
    # …AND ONE THAT IS NOT AN IDENTITY IS REFUSED BY THE PARSER, which is the check
    # the helper already made — made again here because a file is not a promise.
    _bd=0
    _bd_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_VALUE='not-a-remote' TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _bd=$?
    { [ "$_bd" -ne 0 ] && case "$_bd_out" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "…and a sourced value the identity parser refuses stops the session" \
        || die "an unusable sourced origin was accepted (rc=$_bd out='$_bd_out')"
    # …AND THE VALUES ARRIVE AS DATA, WHATEVER IS IN THEM. A remote URL is not this
    # repository's text: a `git` config nobody read can put a quote, a `$(…)` or a
    # backtick in it, and the helper's single-quoting is what makes the sourced line
    # an assignment rather than a command. Asserted through the REAL quoting, since
    # the forge writes its values the same way the helper does.
    _inj="$_forge_dir/injected-file-that-must-not-exist"
    rm -f "$_inj"
    _iv='git@github.com:acme/w'"'"'$(touch '"$_inj"')`touch '"$_inj"'`.git'
    _ij=0
    _ij_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_VALUE="$_iv" TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
        ' 2>&1)" || _ij=$?
    [ ! -e "$_inj" ] \
        && pass "a hostile origin round-trips through the source as data and executes nothing" \
        || die "a value in the env file was executed by the source"
    # …AND THE HELPER'S OWN QUOTING IS WHAT THAT RESTS ON, so it is asserted at the
    # source: `'` closed, escaped and reopened, which is the one sequence single
    # quotes cannot hold.
    if [ -f "$SCRIPT_DIR/pr-setup.sh" ]; then
        # BOTH HALVES, on one line: the single-quoted format, and the substitution
        # that closes, escapes and reopens. Either alone is a quoting that a value
        # carrying `'` walks straight out of.
        _q_line=""
        _q_line="$(grep -F "printf \"'%s'\"" "$SCRIPT_DIR/pr-setup.sh")" || _q_line=""
        { [ -n "$_q_line" ] && case "$_q_line" in *'${_v//'*) true ;; *) false ;; esac; } \
            && pass "…and pr-setup.sh writes every value single-quoted with ' escaped" \
            || die "pr-setup.sh does not single-quote its values with ' escaped: '$_q_line'"
    fi

    # ── the four working paths are proved to be the ones setup made ───────
    # A PATH POINTING SOMEWHERE ELSE IS REFUSED. The env file is a file, and a file
    # is not a promise: one tampered with between the helper and this shell would hand
    # every later stage a summary file under somebody else's directory.
    _elsewhere="$_forge_dir/elsewhere"
    mkdir -p "$_elsewhere"
    for _f in summary.md request.md prior.txt head.txt; do : > "$_elsewhere/$_f"; done
    _pw=0
    _pw_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 FORGE_PATHS="$_elsewhere" TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _pw=$?
    { [ "$_pw" -ne 0 ] && case "$_pw_out" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "a working path pointing outside the setup directory is refused" \
        || die "a working path outside the setup directory was accepted (rc=$_pw out='$_pw_out')"
    grep -q 'the sourced working paths are not the four empty files' <<<"$_pw_out" \
        && pass "…by the check that is about exactly that" \
        || die "the path refusal came from somewhere else: '$_pw_out'"
    # …AND SO IS ONE THAT IS NOT EMPTY. A round summary that already holds text is a
    # stale one from another round, or another pull request, and `pr-close-round.sh`
    # would post it as this round's.
    _nz=0
    _nz_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 FORGE_NONEMPTY=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _nz=$?
    { [ "$_nz" -ne 0 ] && case "$_nz_out" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "…and a working file that is not empty is refused" \
        || die "a non-empty working file was accepted (rc=$_nz out='$_nz_out')"

    # ── the pin, which is the postcondition the export exists for ─────────
    # THE PIN GOES THROUGH THE HELPER, and the helper is a real child: that is what
    # makes its answer the one that matters. A grep cannot answer whether the export
    # took — a `readonly REVIEW_BUS_REMOTE` already in the driving shell makes it fail
    # while setup carries on, and if that readonly value is EMPTY `rb_identity` falls
    # back to `git remote get-url origin` and setup looks entirely successful.
    _ro=0
    _ro_out="$(cd "$_forge_dir" && env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            readonly REVIEW_BUS_REMOTE=""
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || _ro=$?
    case "$_ro_out" in
        *'OWNER=acme REPO=widget'*) die "setup continued with an empty readonly pin: '$_ro_out'" ;;
        *) pass "an empty readonly REVIEW_BUS_REMOTE stops setup rather than looking successful" ;;
    esac
    # …AND A PIN NO CHILD CAN SEE IS REFUSED. With the export neutralised the values
    # are all correct in this shell and no child inherits any of them.
    _px=0
    _px_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" \
        'BASH_FUNC_export%%=() { return 0; }' bash -c '
            '"$_setup_body"'
        ' 2>&1)" || _px=$?
    case "$_px_out" in
        *'OWNER=acme REPO=widget'*) die "the pin passed while no child could see it: '$_px_out'" ;;
        *) pass "…and a pin no child can see is refused" ;;
    esac
    # …AND A PIN THE CHILD ANSWERS DIFFERENTLY IS REFUSED. `FORGE_PIN_VALUE` makes the
    # child answer with another repository while everything the driver sourced is
    # correct, which is the mismatch this comparison exists for — and it is a separate
    # name from `FORGE_VALUE` because a forge that answered the pin with the value it
    # wrote into the env file could never disagree with it.
    _pm=0
    _pm_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_VALUE='git@github.com:acme/other.git' TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
        ' 2>&1)" || _pm=$?
    { [ "$_pm" -ne 0 ] \
      && case "$_pm_out" in *'the repository pin did not take'*) true ;; *) false ;; esac; } \
        && pass "…and a child answering with another repository stops the session" \
        || die "a mismatched pin was accepted (rc=$_pm out='$_pm_out')"
    # …AND A READONLY `RB_PIN_SEEN` DOES NOT CERTIFY ONE. Pre-seeded empty it takes
    # the comparison's own refusal; pre-seeded with the right value it would certify a
    # pin no child ever answered, so the assertion is that neither reaches success.
    _sn=0
    _sn_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            readonly RB_PIN_SEEN="git@github.com:acme/widget.git"
            '"$_setup_body"'
        ' 2>&1)" || _sn=$?
    case "$_sn_out" in
        *'OWNER=acme REPO=widget'*) die "a pre-seeded readonly RB_PIN_SEEN certified a pin: '$_sn_out'" ;;
        *) pass "…and a pre-seeded readonly RB_PIN_SEEN certifies nothing" ;;
    esac

    # …AND THE PIN TRANSPORT IS REMOVED WITHOUT TOUCHING WHAT IT DID NOT PUT THERE.
    # `$RB_SETUP_DIR` is published in argv, so the pin directory under it is a name
    # another process can act on. A `rm -rf` there deletes a replacement's contents,
    # which is past what `docs/decisions/2026-08-26-reservation-inference.md` accepts
    # — its bound is one EMPTY directory, and it rests on `rmdir` refusing anything
    # with contents in it.
    _px_dir=""
    _px_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 FORGE_PIN_EXTRA=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
            printf "D=[%s]\n" "$RB_SETUP_DIR"
        ' 2>&1)" || true
    _px_dir="${_px_out#*D=[}"; _px_dir="${_px_dir%%]*}"
    { [ -n "$_px_dir" ] && [ -d "$_px_dir" ]; } \
        && pass "the pin case ran and its setup directory can be inspected" \
        || die "the pin-extra case did not report a setup directory: '$_px_out'"
    if [ -n "$_px_dir" ] && [ -d "$_px_dir" ]; then
        { [ -f "$_px_dir/pin/witness" ] && [ -d "$_px_dir/pin/squatter-subdir" ]; } \
            && pass "…and a replacement's contents under the pin name survive the removal" \
            || die "the pin removal destroyed contents it did not create"
        [ ! -e "$_px_dir/pin/pin" ] \
            && pass "…while the leaf the driver read is gone" \
            || die "the pin leaf was left on disk"
        rm -rf "$_px_dir"
    fi

    # ── the probed names, attacked ────────────────────────────────────────
    # A NAMEREF ONTO ONE OF THEM IS REFUSED. This is what `${!name}` is for: the
    # assignment succeeds and lands somewhere else entirely, so a probe reading only
    # the status passes while the setup directory is built at a name the operator
    # chose.
    if [ "$_rb_has_n" = yes ]; then
        for _nr in RB_TMPPARENT RB_TMPPARENT2 RB_SETUP_DIR; do
            _nr_rc=0
            _nr_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
                FORGE_PIN_ECHO=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
                    _rb_target=
                    declare -n '"$_nr"'=_rb_target
                    '"$_setup_body"'
                ' 2>&1)" || _nr_rc=$?
            { [ "$_nr_rc" -ne 0 ] \
              && case "$_nr_out" in *'OWNER=acme'*) false ;; *) true ;; esac; } \
                || die "a nameref onto $_nr was accepted (rc=$_nr_rc out='$_nr_out')"
        done
        pass "a nameref onto any of the three probed names is refused"
    else
        pass "this shell has no declare -n, so the alias states are skipped by name"
    fi
    # …AND SO IS A VALUE-TRANSFORMING OR READONLY ATTRIBUTE, which the prefix match is
    # what catches. `declare -i` is the one that matters most: it makes the sentinel
    # arithmetic, so a clear stores `0` and every later `${VAR:?…}` passes on a value
    # nothing set.
    _rb_attrs="readonly RB_TMPPARENT=x|readonly RB_TMPPARENT2=x|readonly RB_SETUP_DIR=x|declare -i RB_SETUP_DIR=1"
    if [ "$_rb_has_l" = yes ]; then
        _rb_attrs="$_rb_attrs|declare -l RB_SETUP_DIR=x|declare -u RB_SETUP_DIR=x"
    fi
    # IN BOTH MODES, because the ROUTE differs and the invariant does not. Under
    # `errexit` a failed readonly assignment on a line of its own ends the shell
    # where it stands, with bash's own complaint and before any refusal here is
    # reached; without it the shell carries on into the probe. What must hold in
    # both is that no session starts, which is what is asserted — not which of the
    # two messages came out. That is `assert the invariant, not the version's route
    # to it`, and it is why the errexit half is a mode rather than a second harness.
    _saveifs="$IFS"; IFS='|'
    for _at in $_rb_attrs; do
        IFS="$_saveifs"
        for _ee in '' 'set -e'; do
            _at_rc=0
            _at_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
                FORGE_PIN_ECHO=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
                    '"$_ee"'
                    '"$_at"'
                    '"$_setup_body"'
                ' 2>&1)" || _at_rc=$?
            case "$_at_out" in
                *'OWNER=acme REPO=widget'*) die "the attribute state '$_at' reached a session (${_ee:-no errexit}): '$_at_out'" ;;
            esac
        done
        IFS='|'
    done
    IFS="$_saveifs"
    pass "…and every readonly or value-transforming attribute on those names is refused, under errexit and without it"
    # …AND AN ORDINARY SHELL IS NOT REFUSED BY ANY OF IT, or the loop above would
    # pass against a probe that rejects every state it is given.
    _ctl=0
    _ctl_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_PIN_ECHO=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            set -e
            RB_TMPPARENT=
            '"$_setup_body"'
        ' 2>&1)" || _ctl=$?
    { [ "$_ctl" -eq 0 ] && case "$_ctl_out" in *'OWNER=acme REPO=widget'*) true ;; *) false ;; esac; } \
        && pass "…while an ordinary shell under errexit still starts a session" \
        || die "the probe refused an ordinary shell under errexit (rc=$_ctl out='$_ctl_out')"
    # …AND THE PROBE'S REFUSAL IS AN ARM WITH ITS OWN ABORT, asserted structurally: on
    # this bash a failed readonly assignment inside the subshell is contained, so the
    # condition simply reports false — but with the arm deleted the branch would fall
    # through to the call, where a transformed `RB_SETUP_DIR` names a directory the
    # operator chose.
    case "$_setup_body" in
        *'ABORT: one of RB_TMPPARENT, RB_TMPPARENT2 and RB_SETUP_DIR is readonly'*)
            pass "…and the probe's refusal is an arm that says which names it is about" ;;
        *)  die "the probe refusal is not an arm with an abort" ;;
    esac
    # …AND A PRE-SEEDED SENTINEL SLOT FAILS CLOSED, which is the limit rather than a
    # defence. A startup file runs IN THE DRIVER'S SHELL, so it knows `$$` and can read
    # this source: with `RANDOM` unset it can pre-seed `RbProbe$$` and the probe reads
    # their value through `${!name}` and concludes "nameref". No mechanism here can
    # close that — every input to the sentinel is public or unsettable by the same file
    # — so what is asserted is the CONSEQUENCE: setup refuses, and nothing is pinned.
    _ps_out="$(cd "$_forge_dir" && env -u SHELLOPTS -u BASH_ENV -u ENV \
        RB_SCRIPTS="$_forge_dir" FORGE_PIN_ECHO=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" \
        bash -c '
            unset RANDOM
            eval "RbProbe$$=occupied"
            '"$_setup_body"'
            printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"
        ' 2>&1)" || true
    case "$_ps_out" in
        *'PINNED=[git@'*) die "a pre-seeded probe slot let setup pin the session: '$_ps_out'" ;;
        *) pass "a pre-seeded probe slot fails closed — setup refuses and pins nothing" ;;
    esac
    grep -q 'readonly, value-transforming, or aimed at another' <<<"$_ps_out" \
        && pass "…refusing by the probe's own message, so an operator is told which names it is about" \
        || die "the pre-seeded case refused for some other reason: '$_ps_out'"

    # ── the success line, and where it may appear ─────────────────────────
    # IN THE INNERMOST ARM AND NOWHERE ELSE. Every refusal above it is an `else`, so
    # the only route to the announcement is through all of them — that is what
    # containment by POSITION means, and it is what survives a neutralised `exit`.
    _su_n_ok=0; _su_n_ok="$(grep -c 'echo "OWNER=' <<<"$_setup_body")" || _su_n_ok=0
    [ "$_su_n_ok" -eq 1 ] \
        && pass "setup announces itself from exactly one place" \
        || die "setup's success line appears $_su_n_ok times, so a refusal can reach one of them"
    # AND EVERY REFUSAL CARRIES ITS CONTAINMENT. `exit` is a name a startup file can
    # neutralise; the `[[ -n "" ]]` after it is a reserved word that cannot be, and it
    # is what stops a neutralised `exit` falling through into the arm's own tail.
    _su_ab=0; _su_ab="$(grep -c '^[[:space:]]*echo "ABORT' <<<"$_setup_body")" || _su_ab=0
    _su_cn=0; _su_cn="$(grep -c '^[[:space:]]*\[\[ -n "" \]\]$' <<<"$_setup_body")" || _su_cn=0
    { [ "$_su_ab" -gt 0 ] && [ "$_su_ab" -eq "$_su_cn" ]; } \
        && pass "…and every abort in the block is followed by its containment" \
        || die "an abort has no containment after it (aborts=$_su_ab contained=$_su_cn)"
    # …AND A REFUSED RUN DOES NOT REMOVE WHAT THE HELPER LEFT BEHIND. The contract is
    # a directory the helper created, so a refusal here cannot know whether it is
    # looking at that one or at something an operator's transformed name pointed at.
    _pex="$_forge_dir/preexisting"
    rm -rf "$_pex"; mkdir -p "$_pex"; : > "$_pex/witness"
    env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" \
        FORGE_SETUP_RC=1 TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            '"$_setup_body"'
        ' >/dev/null 2>&1 || true
    [ -e "$_pex/witness" ] \
        && pass "…and a refused run removes nothing it did not create" \
        || die "a refused setup deleted what it did not create"
    rm -rf "$_pex" "$_elsewhere" "$_unw_dir"
fi
[ -n "$_forge_dir" ] && rm -rf "$_forge_dir"
unset RB_TMPBASE
grep -qF 'CLOSE_RC=$?' <<<"$skill_flat" \
    && pass "…and its status is taken" \
    || die "SKILL.md runs the close stage without reading its status"
# …AND THE GUARD OVER IT SURVIVES A SHADOWED BUILTIN. This block runs in the
# driving session's own shell, which is long-lived and where a function named `[`
# can already exist — it shadows the builtin and the `command`/`builtin` prefixes
# alike. One returning success turned a failed close into a successful one and the
# driver carried on with no signoff recorded and no operator stop; a shadowed
# `exit` neutralised the abort the same way.
#
# LIFTED AND RUN, not described. Greps agreed with every wrong version of the
# phase parser above, and they would agree here: the question is what the block
# DOES when both names lie, and only running it answers that.
_close_guard="$(awk '/^if \[\[ \$CLOSE_RC -ne 0 \]\]; then$/, /^fi$/' "$SKILL")"
[ -n "$_close_guard" ] \
    && pass "the close-status guard lifts out of SKILL.md" \
    || die "the close-status guard is missing or no longer starts with a reserved conditional"
# `2>/dev/null` because a shadowed `exit` leaves bash complaining on the way out;
# the STATUS is the assertion. `CLOSE_RC=1` is a close that stopped.
_cg_rc=0
env -u SHELLOPTS -u BASH_ENV -u ENV CLOSE_RC=1 \
    'BASH_FUNC_[%%=() { return 0; }' \
    'BASH_FUNC_exit%%=() { return 0; }' \
    bash -c '
        RB_SCRIPTS=/nonexistent; REPO_DIR=/nonexistent
        '"$_close_guard"'
    ' >/dev/null 2>&1 || _cg_rc=$?
[ "$_cg_rc" -ne 0 ] \
    && pass "…and a failed close still ends non-zero with [ and exit both shadowed" \
    || die "a shadowed [ and exit turned a failed close into a successful one"
# …AND IT DOES NOT REFUSE A CLOSE THAT WORKED. A guard that ends non-zero
# unconditionally passes the case above while stopping every successful phase.
_cg_ok=0
env -u SHELLOPTS -u BASH_ENV -u ENV CLOSE_RC=0 bash -c '
        RB_SCRIPTS=/nonexistent; REPO_DIR=/nonexistent
        '"$_close_guard"'
    ' >/dev/null 2>&1 || _cg_ok=$?
[ "$_cg_ok" -eq 0 ] \
    && pass "…while a close that succeeded passes through it" \
    || die "the close-status guard refuses a successful close (rc=$_cg_ok)"

# ── every 'cannot tell' is a stop ──────────────────────────────────────────
grep -qi 'fail closed' "$SKILL" \
    && pass "skill states the fail-closed rule" \
    || die "skill does not state that an unreadable state fails closed"
grep -q 'pr-review-state.sh' "$SKILL" \
    && pass "skill drives pr-review-state.sh" \
    || die "skill does not use pr-review-state.sh"
grep -q 'pr-merge-range.sh' "$SKILL" \
    && pass "skill drives pr-merge-range.sh" \
    || die "skill does not use pr-merge-range.sh"
# The round check-in must have an implementation, not just a promise: v1's
# guarantee lived in a /tmp counter that vanished with the file.
grep -q 'pr-round-count.sh' "$SKILL" \
    && pass "the round check-in is enforced by a script, not only described" \
    || die "skill promises a round check-in with nothing implementing it"

# ── THE MERGE GATE'S OWN DECISIONS ARE TESTED IN `test-pr-merge-gate.sh` ───
#
# Twenty-four assertions used to live here, each a `grep` for the spelling of one
# line of a 291-line block in `SKILL.md` — because a fenced block cannot be run,
# and a grep was the only thing available. Forty-two cases now EXECUTE the gate
# against stubbed helpers: every refusal path, the pause, and the merge itself.
# That is a strictly stronger claim, and it is why these are gone rather than
# retargeted at the script — a spelling grep beside an executed case tests the
# spelling, not the behaviour.
#
# What stays here is what belongs here: that the driver CALLS the gate, with the
# arguments it needs, and distinguishes the three answers it can give.

# THE FALLBACK IS THE PHASE HELPER'S NOW (#123). The resume recipe was 112 lines
# in this document and this asserted one of them; `pr-phase-state.sh` holds the
# same check and `test-pr-phase-state.sh` RUNS it, on both arms and on every
# refusal. A grep over `SKILL.md` would find nothing and would have to be deleted
# or made vacuous — so it is the same invariant, asserted where it now lives.
[ -x "$SCRIPT_DIR/pr-phase-state.sh" ] \
    && grep -qF 'pr-review-state.sh verdict "$PR" "$RB_CODEX_BOT" "$CODEX_SHA"' "$SCRIPT_DIR/pr-phase-state.sh" \
    && pass "…and falls back to the recorded signoff when it has not" \
    || die "there is no fallback to \$CODEX_SHA — the gate cannot pass after a Copilot fix"
# CODEX_SHA has to be captured before the head moves; nothing else records it.
#
# THE PHASE RECORD SPECIFICALLY, not any assignment to that name. This matched
# `CODEX_SHA="$(printf`, and there are two producers of that variable — the phase
# record here and the recorded signoff the resume path reads. When the phase one
# was rewritten to run under `pipefail`, this kept passing on the OTHER one: an
# assertion whose message names the phase record, satisfied by a line about
# something else, which is a check that has stopped checking without saying so.
grep -q 'codex-sha=' "$SKILL" \
    && pass "the Codex-signed-off head is read back out of the phase record" \
    || die "CODEX_SHA is required by the gate but never read from the phase record"
# With auto-review on, the PUSH requests the next review — so the boundary check
# has to precede it, not merely precede the explicit re-request.
# A fragment that fits on ONE line — the file is wrapped and `grep` is line
# oriented, so a phrase spanning a line break silently never matches. Fourth time.
grep -qi 'precede the push' "$SKILL" \
    && pass "the round boundary is checked before the push" \
    || die "the boundary check runs after the push, which auto-review has already acted on"
# EXACTLY FORTY HEX, not "only hex". `[0-9a-f]*` matches the empty string and it
# matches `a`, so `codex-sha=a` survived the emptiness test below it and step 8
# was gated on something that is not a commit. The resume parser at the bottom of
# the same file has always required `\{40\}` — one rule, two copies, one of them
# wrong, which is the shape `CLAUDE.md` says belongs in a single place. #39.
# ── THE HEAD IS ASKED FOR, NOT PARSED ──────────────────────────────────────
#
# This was ~90 lines of expansion-only parsing in `SKILL.md`, lifted and executed
# here against fourteen record shapes — a truncated record that could not
# overwrite a stale candidate, `xcodex-sha=` matching as the field, a greedy
# `##*codex-sha=` reading a later substring, and so on. Every one of those was a
# rule about what a well-formed record is, and that rule now lives in
# `pr-signoff.sh` and `recordlib.sh`, where `test-pr-signoff.sh` covers it against
# the same shapes and `pr-selfcheck.sh` gates it. Issue #89.
#
# WHAT REMAINS TO ASSERT HERE IS THE WIRING, which is this file's job: that the
# driver ASKS, that it takes the status, that it checks the shape anyway, and that
# no copy of the parser grew back. The behavioural coverage did not shrink — it
# moved to the file that can run it, which is the whole point of the removal.
# TWO, SINCE #123: the phase record in step 7 and the sha the gate is pinned to in
# the resume path. The resume recipe's own two reads moved into
# `pr-phase-state.sh`, which asks through the same helper and is covered by a
# fixture that runs it.
_sha_reads="$(grep -c 'pr-signoff.sh sha N' "$SKILL" || true)"
[ "$_sha_reads" -eq 2 ] \
    && pass "both head reads ask pr-signoff.sh for the sha alone" \
    || die "expected two 'pr-signoff.sh sha' reads in SKILL.md, found $_sha_reads"
# NO RECORD PARSING LEFT, IN ANY SHAPE. A `sed` over `PR_SIGNOFF` was the second
# form this took, and `sed` is a name: one that prints a plausible forty hex and
# exits 0 pins a merge to whatever it says.
#
# OVER THE CODE, NOT THE PROSE. The comments explain at length which parsing was
# removed and name the constructs to do it, so a scan of the raw file finds the
# argument against the defect and reports the defect — the same trap the setup
# block's `set +x` scan fell into.
_skill_code="$(awk '/^```bash$/{f=1;next} /^```$/{f=0;next} f && !/^[[:space:]]*#/' "$SKILL")"
case "$_skill_code" in
    *'##*codex-sha='*|*"sed -n 's/^PR_SIGNOFF"*|*"sed -n 's/^PR_PHASE"*)
        die "SKILL.md parses a signoff or phase record again; the head is asked for, not parsed" ;;
    *) pass "…and no code in SKILL.md parses a record line for a head any more" ;;
esac
# THE STATUS IS TAKEN AT EVERY ONE OF THEM. `sha` prints nothing on stdout when
# there is no signoff, so a caller that ignored the status would carry an empty
# string into a merge gate.
_sha_unchecked="$(grep -F 'pr-signoff.sh sha N' "$SKILL" | grep -vc 'RC=\$?' || true)"
[ "$_sha_unchecked" -eq 0 ] \
    && pass "…and every one of them takes the status on the same line" \
    || die "$_sha_unchecked head reads ignore the helper's status"
# AND THE SHAPE IS CHECKED AS WELL AS THE STATUS, in both the phase block and the
# resume path: this value is what every gate in step 8 is pinned to, and it is not
# left resting on one helper's promise.
# ONE SHAPE CHECK PER READ, not "at least two". The Copilot read had none, and a
# `-ge 2` bound was satisfied by the two Codex ones — so the assertion passed
# while the value that SELECTS the post-Copilot arm was unchecked. A count tied to
# the number of reads cannot do that.
_sha_shapes="$(grep -c '=~ \$RX_SHA40\|=~ \$RX_PHASE_SHA40' "$SKILL" || true)"
[ "$_sha_shapes" -eq "$_sha_reads" ] \
    && pass "…and every one of the $_sha_reads reads shape-checks its value before using it" \
    || die "$_sha_reads head reads but $_sha_shapes shape checks; one is used unvalidated"


# ── the pushed head is checked before the round is closed ─────────────────
# CI was red for four consecutive commits and nothing noticed: every round was
# closed on a local suite run, and `pr-selfcheck.sh` runs BEFORE the push, so it
# cannot see a failure that only happens on the runner. "The suite passes here"
# and "the checks pass there" are different claims. Issue #16.
# THE GATE IS A SCRIPT, so what is asserted here is that the driver calls it.
# It was a function defined in this document; `test-pr-ci-gate.sh` now runs the
# script itself, which is why the behavioural cases moved out of this file.
# EVERY CALL SITE IS IN A SCRIPT NOW, so this asserts the callers rather than the
# document: the two paths that can close a round or a phase both gate on the
# head's checks. A grep over `SKILL.md` would find nothing and would have to be
# either deleted or made vacuous; this is the same invariant where it now lives.
[ -x "$SCRIPT_DIR/pr-ci-gate.sh" ] \
    && grep -qF 'pr-ci-gate.sh "$PR"' "$SCRIPT_DIR/pr-close-round.sh" \
    && grep -qF 'pr-ci-gate.sh "$PR" "$CODEX_SHA"' "$SCRIPT_DIR/pr-copilot-phase.sh" \
    && pass "every path that closes a round or a phase gates on the head's checks" \
    || die "nothing checks whether the pushed head is green"
# EVERY push site calls it. One that does not is a round closed on an unknown
# state, and the two sites exist precisely because the ordering differs — which is
# how one of them comes to be missing a step the other has.
# `|| …=0`: `grep -c` exits 1 when nothing matches, and this file runs under `-e`,
# so an unguarded count terminated the suite at the first call-form change instead
# of reporting the mismatch it exists to report.
# EVERY push site, and every other point that accepts a head. A PR whose reviews
# were clean from the start never pushes anything, so gating only the push sites
# left it never checked at all — through both phases and into a merge gate that
# looks at REQUIRED checks only, which a failing optional one is not.
pushes="$(grep -c '^git push ||' "$SKILL")" || pushes=0
gates="$(grep -cE '^(if ! )?"\$RB_SCRIPTS"/pr-ci-gate\.sh N ' "$SKILL")" || gates=0
# ── THE DRIVER CALLS THE ROUND-CLOSER, IN BOTH MODES ───────────────────────
# What only this file can answer: that the document reaches the script at all,
# tells it which ordering to use, and reads the three answers it can give. A
# driver that hard-codes `no` would close every automatic-review round in the
# wrong order — pushing after it had already posted — and nothing in the script's
# own tests would notice, because the script would be doing exactly as it was told.
[ -x "$SCRIPT_DIR/pr-close-round.sh" ] \
    && pass "the round-closer ships" \
    || die "the round-closer is missing"
grep -q 'pr-close-round.sh gate N "\$WHO" "\$SUMMARY_FILE" "\$AUTO_REVIEW" "\$HEAD_FILE"' "$SKILL" \
    && pass "…and the recipe gates on the mode this PR is actually in" \
    || die "the recipe does not run the gate with \$AUTO_REVIEW and the head file"
# BOTH STAGES ARE GIVEN THE SAME PATH, and that is the whole of the handoff since
# #202: `gate` writes the head it proved into it and `post` reads it back, so the
# value never enters the driving shell. A recipe that passed a captured head here
# would be back to an assignment made after the push.
grep -q 'pr-close-round.sh post N "\$WHO" "\$SUMMARY_FILE" "\$AUTO_REVIEW" "\$HEAD_FILE"' "$SKILL" \
    && pass "…and posts against the head file the gate wrote" \
    || die "the recipe does not post with the head file"
grep -q 'GATED_HEAD=' "$SKILL" \
    && die "the driver assigns GATED_HEAD again; the head is meant to travel in a file (#202)" \
    || pass "…and the driver holds the head in no name of its own"
# AND THE POST STEP REFUSES AN EMPTY HEAD FILE. The gate's refusal arms end in a
# reserved word, which gives their `if` a non-zero status that nothing reads —
# and the thread replies sit between the two stages, so no `if` can span them.
# What stops a driver whose `exit` returns is the STATE: `gate` empties the file
# before it does anything and writes it only on success, so a refusal leaves it
# empty and this guard is what the next step meets.
#
# AND IT ASKS FOR A COMMIT ID, NOT FOR A NON-EMPTY FILE. `gate` refuses a head
# file that IS the summary file, and it refuses BEFORE it empties anything — it
# has to, or the refusal would destroy the account it is protecting — so on that
# one path the file is left holding the summary, which a `-s` guard accepts.
# BEFORE THE REPLIES, WHICH IS THE BOUNDARY THAT MATTERS. A guard in the post
# fence alone is reached only after the threads have been resolved, so it stops
# `post` and not the irreversible part. The proof sits in the gate's success arm,
# and the ordering is what this asserts.
# THE TWO GUARDS ARE ANCHORED ON DIFFERENT LINES, because they are no longer the
# same shape: the one before the replies asks the file IDENTITY first and has the
# shape test as its success arm, since `gate` refuses an aliased head file before
# it clears anything and a summary that is forty hex characters satisfies the
# shape test exactly. The post step's is the shape test alone, and by then the
# identity question has been settled or the round never got here.
_hf_guard_ln="$(grep -n '^if \[\[ ! \$HEAD_FILE -ef \$SUMMARY_FILE \]\]; then' "$SKILL" | head -1 | cut -d: -f1)" || true
_hf_res_ln="$(grep -n 'Now answer the threads' "$SKILL" | head -1 | cut -d: -f1)" || true
_hf_post_ln="$(grep -n '^POST_OUT="\$(/usr/bin/env bash -p "\$RB_SCRIPTS"/pr-close-round.sh post N' "$SKILL" | head -1 | cut -d: -f1)" || true
{ [ -n "$_hf_guard_ln" ] && [ -n "$_hf_res_ln" ] && [ "$_hf_guard_ln" -lt "$_hf_res_ln" ]; } \
    && pass "…and the head is proven, identity first, after the gate and before the replies" \
    || die "the head is not proven before the replies (guard=$_hf_guard_ln replies=$_hf_res_ln)"
_hf_post_guard_ln="$(grep -n '^case "\$(<"\$HEAD_FILE")" in' "$SKILL" | sed -n '1p' | cut -d: -f1)" || true
{ [ -n "$_hf_post_guard_ln" ] && [ -n "$_hf_post_ln" ] \
    && [ "$_hf_post_guard_ln" -gt "$_hf_res_ln" ] && [ "$_hf_post_guard_ln" -lt "$_hf_post_ln" ]; } \
    && pass "…and the post step asks again, for a session that resumes into it" \
    || die "the post step does not guard on the head file (guard=$_hf_post_guard_ln post=$_hf_post_ln)"
# THE MODE IS PASSED, NOT WRITTEN IN. A driver that hard-codes `no` would close
# every automatic-review round in the wrong order — pushing after it had already
# posted — and nothing in the script's own tests would notice, because the script
# would be doing exactly as it was told.
grep -qE 'pr-close-round\.sh (gate|post) N "\$WHO" "\$SUMMARY_FILE" (yes|no)' "$SKILL" \
    && die "a recipe hard-codes the auto-review mode instead of passing \$AUTO_REVIEW" \
    || pass "…and neither stage hard-codes the mode"
# THE THREAD WORK IS BETWEEN THE STAGES, and the document is the only place that
# ordering is stated — the script cannot check what its caller did between two
# invocations. A resolve before the gate records findings as answered on a commit
# that may never land.
# ANCHORED ON THE INVOCATIONS, not on the usage comment that lists both stages a
# few lines above them — matching that comment put `post` before `gate` and the
# ordering this asserts was read off the documentation of itself.
# THE ORDERING ASSERTIONS GUARD THEIR OWN LOOKUPS. Under `set -e` an unmatched
# `grep` in a command substitution ABORTS THE WHOLE FILE, so a document that
# dropped the very line being checked killed the run instead of failing it: no
# FAIL, no RESULT, and a caller grepping for failures saw none.
_gate_ln="$(grep -n '^if /usr/bin/env bash -p "\$RB_SCRIPTS"/pr-close-round.sh gate N' "$SKILL" | head -1 | cut -d: -f1)" || true
_post_ln="$(grep -n '^POST_OUT="\$(/usr/bin/env bash -p "\$RB_SCRIPTS"/pr-close-round.sh post N' "$SKILL" | head -1 | cut -d: -f1)" || true
_res_ln="$(grep -n 'Now answer the threads' "$SKILL" | head -1 | cut -d: -f1)" || true
{ [ -n "$_gate_ln" ] && [ -n "$_post_ln" ] && [ -n "$_res_ln" ] \
    && [ "$_gate_ln" -lt "$_res_ln" ] && [ "$_res_ln" -lt "$_post_ln" ]; } \
    && pass "…and the threads are answered between the two stages" \
    || die "the document does not put the thread replies between gate and post (gate=$_gate_ln replies=$_res_ln post=$_post_ln)"
# THE THREE ANSWERS ARE DISTINGUISHED. A pause read as a stop loses the operator's
# decision; a stop read as success closes a round that did not close.
[ "$(grep -c 'ROUND_RC' "$SKILL")" -ge 4 ] \
    && grep -q 'exit "\$ROUND_RC"' "$SKILL" \
    && pass "…and both recipes pass the round-closer's status on" \
    || die "a recipe swallows the round-closer's status"

# ── THE DRIVER READS THE BASELINE BACK ─────────────────────────────────────
# The script reads the review id immediately before it requests the pass, and
# step 3's watch needs exactly that value. A child cannot assign a variable in its
# parent, so it reports the value instead — and without this the watch keeps the
# OLDER baseline, against which the terminal review this round just handled is
# newer, and is therefore accepted at once as the answer to a request nobody has
# answered yet.
# COUNTING THE TOKEN IS NOT ENOUGH: the value has to be ASSIGNED, and an empty one
# has to stop the round. A recipe that echoes the record and carries on satisfies a
# count while step 3 still watches against the parent's older baseline — which is
# the defect, not the spelling.
# ONE recipe now, not two: the mode is an argument to the script rather than the
# thing that chooses which block to copy, so there is one site to satisfy.
[ "$(grep -c 'PRIOR_REVIEW="${CLOSED_REC##\* prior-review=}"' "$SKILL")" -ge 1 ] \
    && pass "the recipe assigns the baseline the round-closer reported" \
    || die "a recipe prints the closing record without reading the baseline out of it"
[ "$(grep -c 'the round reported no closing record' "$SKILL")" -ge 1 ] \
    && pass "…and an absent RECORD stops the round rather than watching on a stale id" \
    || die "a missing closing record is accepted and step 3 watches against a stale one"
# AN EMPTY BASELINE IS AN ANSWER, NOT A FAILURE. `pr-review-state.sh review-id`
# returns nothing when the current head has no review — every round that pushes a
# new commit, and every Copilot round — and `pr-watch.sh` takes an empty value as
# "wait on any terminal review". Testing the VALUE aborted on all of those AFTER
# the summary was posted and the pass requested, so the watch was never armed and
# a retry posted both a second time.
grep -qF '[ -n "$PRIOR_REVIEW" ]' "$SKILL" \
    && die "the driver tests the baseline VALUE for emptiness; an empty baseline is legitimate and the request has already been made by then" \
    || pass "…while an empty baseline is carried through rather than rejected"
# The FIELD is what distinguishes the two, so the driver has to look for it.
grep -qF "*' prior-review='*)" "$SKILL" \
    && pass "…told apart by the field's presence, not by what is in it" \
    || die "the driver cannot tell a record missing the baseline field from one whose field is empty"
# THE EXPANSION ITSELF IS EXECUTED, against both answers it must keep apart. The
# greps above prove `SKILL.md` uses this expansion; only running it proves the
# expansion is right, and a `##` that ate one character too many would satisfy
# every grep here.
_rec_full='PR_ROUND_CLOSED pr=7 reviewer=x[bot] head=abc mode=mention prior-review=42'
_rec_none='PR_ROUND_CLOSED pr=7 reviewer=x[bot] head=abc mode=mention prior-review='
{ [ "${_rec_full##* prior-review=}" = 42 ] && [ -z "${_rec_none##* prior-review=}" ]; } \
    && pass "…and the expansion keeps a present baseline and an empty one apart" \
    || die "the baseline expansion reads '${_rec_full##* prior-review=}' and '${_rec_none##* prior-review=}'"

# ── THE ROUND-CLOSING ORDER IS TESTED IN `test-pr-close-round.sh` ──────────
#
# Twenty-nine assertions lived here, each a `grep` or an `awk` over two recipes in
# `SKILL.md` — 56 and 191 lines doing the same job in different ORDERS, which a
# document cannot run. 27 cases now EXECUTE `pr-close-round.sh` against stubbed
# `gh` and `git`, with every call logged in sequence, so "did it post the summary"
# became "did it post the summary before or after it knew the head was green".
#
# That is a strictly stronger claim and it is why these are gone rather than
# retargeted: a spelling grep beside an executed case tests the spelling.
#
# What stays here is what only this file can answer — that the driver CALLS the
# script, in both modes, and reads the three answers it can give.

# The two paths that accept a verdict WITHOUT a push: the Codex→Copilot phase
# transition, and the merge gate. Named individually, because a count alone is
# satisfied by two gates on the same site.
# …AND EVERY ONE IS ASKED ABOUT A COMMIT. `gh pr checks` is addressed by PR number
# and the API can still be serving the previous head for a moment after a push, so
# an unpinned call can return the previous round's green as this round's answer.
# …AFTER the push and BEFORE the review is requested. Asking before the push reads
# the previous head's result, which is the last round's answer to this round's
# question; asking after the request means the pass is already running.
# THE MANUAL PATH GATES BEFORE ANYTHING IS CLOSED. Where the mention is the
# trigger, nothing has been resolved or posted when the gate runs, so a red head
# leaves the round genuinely open — that ordering is the whole value and it is the
# one a later edit would most easily invert.
# AND SO DOES THE AUTOMATIC PATH. It used to close first and push last, so that
# the pass the push starts would find the summary already there — an ordering that
# cannot be gated, because by the time the checks can be consulted the threads are
# resolved and the summary is posted. A later "this round is not closed" comment is
# a record, not a retraction, and is itself a call that can fail. The push moved
# ahead of the closure; what that costs is a pass reading open threads, and that is
# recoverable in a way a closed round is not.
# THE GATE'S OWN BEHAVIOUR IS TESTED IN `test-pr-ci-gate.sh`, against the script.
# It used to be tested here, by `sed`-ing the function body back out of `SKILL.md`
# and running that — the only way to execute shell that lives in a Markdown file.
# What stays here is what belongs here: that the driver CALLS the gate, at every
# site that accepts a head, pinned to an OID, in the right order.

# ── the loop is PHASED: Codex to clean, then Copilot ───────────────────────
# Asking both every round buys a Copilot pass on every intermediate commit and
# mixes its findings into a round that was not about them.
grep -q 'Request the review — Codex first' "$SKILL" \
    && pass "the request step asks Codex first" \
    || die "the request step does not establish the Codex-first phase"
grep -qi 'do \*\*not\*\* request copilot yet' "$SKILL" \
    && pass "Copilot is explicitly deferred out of the Codex phase" \
    || die "nothing stops the driver requesting Copilot in the Codex phase"
grep -q 'Codex is clean — now the Copilot phase' "$SKILL" \
    && pass "there is a distinct Copilot phase, entered on a clean Codex verdict" \
    || die "no Copilot phase — the loop cannot be Codex-first without one"
grep -qi 'Re-request \*\*only the active reviewer\*\*' "$SKILL" \
    && pass "the close-round step re-requests only the active reviewer" \
    || die "the close-round step may re-request both reviewers"
grep -qi 'Codex is not re-requested during this phase' "$SKILL" \
    && pass "Codex is not re-run during the Copilot phase" \
    || die "the Copilot phase does not say Codex stays out of it"
# The round counter must be per-reviewer, or a shared count trips a pause neither
# phase reached.
grep -q 'pr-round-count.sh N "\$WHO"' "$SKILL" \
    && pass "rounds are counted for the ACTIVE reviewer" \
    || die "the round count is not scoped to the active reviewer"
# `$WHO` must be a variable throughout, so the Copilot phase gets the same
# treatment rather than leaving a hole for whichever login was hard-coded.
grep -q 'WHO="\$CODEX_BOT"' "$SKILL" && grep -q 'WHO="\$COPILOT_BOT"' "$SKILL" \
    && pass "the active reviewer is a variable, set per phase" \
    || die "the active reviewer is not parameterised across phases"
# The findings read is a SCRIPT, not a snippet. Three rounds of fail-open bugs
# lived in the inline version because no test executed it.
# The verdict must arrive by itself. v2 removed v1's response monitor along with
# the bus; without a replacement the driver hand-polls, which is what the operator
# noticed.
grep -q 'pr-watch.sh' "$SKILL" \
    && pass "the wait is delegated to pr-watch.sh, not hand-polled" \
    || die "nothing surfaces a finished review — the driver would poll by hand"
grep -qi 'Monitor' "$SKILL" \
    && pass "Claude Code is told to run the watch as a Monitor" \
    || die "the skill does not say how to surface the verdict automatically"
grep -q 'WATCH_RC' "$SKILL" \
    && pass "the driver branches on the watch's status" \
    || die "the watch's exit status is not acted on"
# EVERY STATUS THE WATCH CAN EXIT WITH IS IN THE TABLE. `4` — the review carried
# comments and every one was a reply — was added to the script and to step 7 and
# not to the table the driver reads at step 3, so the driver went on to the fix
# round, found nothing to fix, closed it on nothing and requested another pass:
# the loop the status exists to end.
for _rc in 0 1 2 4; do
    grep -q "^| \`$_rc\` |" "$SKILL" \
        && pass "…including status $_rc" \
        || die "the watch can exit $_rc and the driver's table does not say what to do"
done
# …and `4` does not send the driver into the round.
_rc4="$(grep -n '^| `4` |' "$SKILL" | head -1 | cut -d: -f1)" || true
[ -n "$_rc4" ] && sed -n "${_rc4}p" "$SKILL" | grep -qi 'stop' \
    && pass "…and status 4 stops rather than continuing into the fix round" \
    || die "status 4 does not tell the driver to stop"

grep -q 'pr-findings.sh list' "$SKILL" \
    && pass "the findings read is delegated to a tested script" \
    || die "the findings read is inline again — no test can execute it"
grep -q 'pr-findings.sh blocked-body' "$SKILL" \
    && pass "the blocked-review body is delegated to the same script" \
    || die "the blocked-body fetch is inline again"
grep -q 'FIND_RC=\$?' "$SKILL" \
    && pass "the driver captures the findings read's status" \
    || die "the findings read's status is not captured"
# The blocked-body read needs the same contract: it is the ONLY path that can
# surface a body-only request, so an unreadable one must not read as "no body".
# The ASSIGNMENT, not the prose: the paragraph below the command also names
# BODY_RC, so a bare grep for the word passes even when the status is not
# captured at all.
grep -q 'BODY_RC=\$?' "$SKILL" \
    && pass "the driver captures the blocked-body read's status" \
    || die "the blocked-body read's status is not captured"

# The round boundary must be checked BEFORE the re-request, or the next review is
# already sent by the time the operator is asked.
# Matched on the ordering STATEMENT rather than on the two commands' line
# numbers: the checklist item wraps, so a line-order test silently never matched
# and reported failure regardless of the text.
{ grep -q 'check the round boundary' "$SKILL" && grep -q 'only then' "$SKILL"; } \
    && pass "the close-round checklist checks the boundary before re-requesting" \
    || die "the checklist does not order the boundary check before the re-request"
grep -qi 'push itself' "$SKILL" \
    && pass "and says why the order matters (auto-review acts on the push)" \
    || die "the ordering is stated without its reason"

# The README is the first thing a user reads, so v1's architecture must not
# survive in it: someone told about a "file-based bus" goes looking for daemons
# and bus state that this release deletes.
if [ -f "$ROOT/README.md" ]; then
    # Blockquotes are excluded: the "Upgrading from 1.x" note legitimately
    # describes what v1 WAS, and a blunt grep would forbid explaining the thing
    # this release removes.
    readme_now="$(grep -v '^[[:space:]]*>' "$ROOT/README.md")"
    for gone in 'file-based bus' 'systemd --user' 'response monitor'; do
        grep -qi -- "$gone" <<<"$readme_now" \
            && die "README still presents removed v1 machinery as current: $gone" \
            || pass "README does not present removed machinery as current ($gone)"
    done
fi

# The README carries the same flow for users who never open SKILL.md, so the
# ordering has to hold there too — it did not, one round after the skill was
# fixed.
README="$ROOT/README.md"
if [ -f "$README" ]; then
    # Matched on fragments that survive the line wrap: "check the round" and
    # "boundary" sit on different lines, and a phrase-spanning regex silently
    # never matches — which is how a line-order assertion reports failure
    # regardless of the text.
    # THE WALKTHROUGH NO LONGER SPELLS OUT A PUSH — it hands the closing to
    # `pr-close-round.sh`, which is the point. What must still be ordered is the
    # boundary check before that handoff, for the same reason: with automatic
    # review on the push inside that script IS the request.
    readme_order=$(awk '/check the round/{if(!b)b=NR} /pr-close-round\.sh/{if(!p)p=NR} END{print (b && p && b<p) ? "ok" : "bad"}' "$README")
    [ "$readme_order" = "ok" ] \
        && pass "README checks the round boundary before the push" \
        || die "README still tells users to push before the boundary check"
    # …and it must carry BOTH orderings, since the push is the trigger with
    # automatic review on. One round after the skill was fixed the README still
    # described only the auto-review-off flow.
    grep -q 'automatic review on' "$README" \
        && pass "README describes the auto-review ordering too" \
        || die "README documents only one review mode; the other starts a pass with no summary"
else
    pass "README not present; flow-order check skipped"
fi

# A failed Copilot request must not start the phase: --add-reviewer IS the
# request, so a failure means there is no pass to wait for.
# The @codex comment IS the request, so the same rule applies to it.
#
# THE POST MOVED INTO `pr-request-review.sh` (#144, under #26), and with it the
# branch on whether it succeeded — where `test-pr-request-review.sh` EXECUTES
# both failure paths rather than matching their text. What stays asserted here is
# the driver's half: the status has to be taken and refused on before the wait
# step, or a stopped request is followed by a poll for a review nobody asked for.
grep -q 'pr-request-review.sh N "$AUTO_REVIEW" < "$REQUEST_FILE" > "$PRIOR_FILE"' "$SKILL" \
    && pass "the opening request is made through the helper the suite covers" \
    || die "the initial Codex request is not made through pr-request-review.sh"
# AND ITS BODY GOES IN AS A REDIRECTION, not through a name. This bash runs in
# the operator's shell, where `cat` is a NAME: a function by that name receives
# the heredoc and writes what it likes to the redirection, so the account posted
# would be the function's text — and one that writes nothing and succeeds stops a
# request that was fine. `CLAUDE.md`: prefer REMOVING the dependency over guarding
# it. Counted rather than forbidden outright, because the Copilot phase still
# writes a file this way and that block is its own extraction; what must not
# happen is a SECOND one appearing here.
_rb_cat_n="$(grep -c 'cat > "\$SUMMARY_FILE"' "$SKILL")"
[ "$_rb_cat_n" -le 1 ] \
    && pass "…with its body redirected in, so no shadowable name writes it" \
    || die "SKILL.md writes a body with cat $_rb_cat_n times; the opening request takes its body on stdin"
# AND THE BODY IS NOT SPLICED INTO SHELL SOURCE AT ALL. A heredoc puts it there,
# and an account containing a line that is exactly the delimiter ENDS the
# heredoc — whatever follows is then parsed by the operator's long-lived shell.
# `EOF` is a line this loop's own accounts quote, out of a diff or a finding, and
# a rarer delimiter narrows that without closing it: the body is not known when
# the delimiter is chosen. The driver's file tool writes the file instead, which
# does not go through that shell.
grep -q 'pr-request-review.sh N "$AUTO_REVIEW" <<' "$SKILL" \
    && die "the opening request takes its body from a heredoc; an account containing the delimiter would end it and the rest would be parsed as shell" \
    || pass "…and its body is never spliced into shell source"
# AND THE OPENING ACCOUNT DOES NOT SHARE THE ROUND-SUMMARY FILE. A first round
# whose summary write did not happen would otherwise find the opening account
# still there — non-empty, well-formed and about the right PR — and
# `pr-close-round.sh` would post it as the round summary and request the next
# pass instead of refusing to close.
grep -q 'pr-request-review.sh N "$AUTO_REVIEW" < "$SUMMARY_FILE"' "$SKILL" \
    && die "the opening account is written into the round-summary file; a first round that fails to write its summary would post it as one" \
    || pass "…and the opening account has a file of its own"
# AND NO WRITABLE NAME CARRIES ITS ANSWER BACK. A capture written as
# `PRIOR_REVIEW="$(helper …)"` inside the condition is an ASSIGNMENT, and a
# startup file that has already made that name readonly makes it fail — which
# abandons the `if` with NEITHER branch running, so a refused request falls
# through into the wait. A plain command with its output redirected has no
# assignment to fail. Same question, same answer as `pr-origin.sh`: a path rather
# than a name.
grep -q 'if ! PRIOR_REVIEW=' "$SKILL" \
    && die "the request's answer is captured into a variable in the condition; a readonly name there abandons the if with neither branch running" \
    || pass "…and its answer comes back in a file, not a name"
# AND ITS VALIDATOR IS A LITERAL. A pattern held in a variable is a second name a
# startup file can seed readonly, and a seeded pattern accepting a seeded value is
# a check that agrees with itself.
grep -q 'RX_PRIOR' "$SKILL" \
    && die "the baseline is validated against a pattern held in a variable; use a literal" \
    || pass "…and is validated against a literal pattern"
# AND THE READ-BACK IS PROVEN AGAINST THE FILE. `CLAUDE.md` says to prove an
# assignment by reading the variable back, and the usual difficulty is that
# nothing else knows what the value should have been. Here the file does: if the
# name was already readonly the assignment fails and the two disagree, which is
# the one case a pattern check on the variable alone cannot see — the helper
# SUCCEEDED and the baseline is somebody else's.
grep -qF 'if [[ $PRIOR_REVIEW != "$(<"$PRIOR_FILE")" ]]; then' "$SKILL" \
    && pass "…and the read-back is proven against the file it came from" \
    || die "the baseline is not proven against the file; a readonly PRIOR_REVIEW keeps its own value silently"
# AND NO STATUS VARIABLE HOLDS ITS ANSWER. Written as `…; REQ_RC=$?` the status is
# lost twice: with `errexit` on, a documented refusal ends the shell at the
# assignment before anything reads it; without it, a startup file that has already
# made the name readonly `0` leaves the assignment failing silently at the benign
# value, and a request that never happened is followed by a wait for it. A command
# run as a condition is exempt from `errexit`, and there is no name left to seed.
grep -q '^[^#]*REQ_RC=' "$SKILL" \
    && die "the opening request's status goes through a variable; take it at the invocation" \
    || pass "…and its status is taken at the invocation, with no variable to seed"
# THE CONTINUATION IS THE `then` BRANCH, which is structural rather than a
# refusal. `exit` is a builtin a startup file can replace with one that RETURNS,
# so an abort arm prints and carries straight on — into the read-back, and from
# there into the wait for a review that was never requested. Ending the arm in a
# reserved word makes the LIST report non-zero, which nothing there reads. What
# holds is that the work sits inside the branch a refusal does not take.
grep -q 'if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-request-review.sh' "$SKILL" \
    && pass "the Codex request is branched on before the wait begins" \
    || die "a failed @codex request still enters the wait step"
grep -q 'PRIOR_REVIEW="$(<"$PRIOR_FILE")"' "$SKILL" \
    && pass "…and the read-back is inside that branch, not after it" \
    || die "the baseline read-back is not inside the request's success branch; a shadowed exit reaches it"
# AND THE NAME IT READS INTO IS PROVEN ASSIGNABLE BEFORE THE REQUEST GOES OUT.
# That read-back is a simple command: with `errexit` on and `PRIOR_REVIEW` already
# readonly it fails and ends the shell — after the request has been POSTED, so the
# pass is in flight and no watch is ever armed. Nothing after a mutation can undo
# that; the question has to be asked before it, where the same failure costs a
# stop and nothing else.
#
# A SUBSHELL WITH THE COMPARISON INSIDE IT. An assignment read back HERE is an
# assignment in the operator's shell, and a failed readonly one under `errexit` is
# fatal — that would end the session in the state the probe exists to REPORT. One
# probe is enough there, because a readonly pre-seeded with the probe's own value
# makes the subshell's assignment fail outright and the comparison is never
# reached; and the comparison is what catches a TRANSFORMING attribute such as
# `declare -i PRIOR_REVIEW`, where the assignment SUCCEEDS and stores something
# else — a status-only probe accepts that, and the request goes out with the
# baseline rewritten. #148.
_rb_prp_ln="$(grep -n '( PRIOR_REVIEW="RbProbe\$\$\$RANDOM\$RANDOM"; \[\[ $PRIOR_REVIEW = RbProbe\* \]\]' "$SKILL" | head -1 | cut -d: -f1)" || _rb_prp_ln=""
_rb_req_ln="$(grep -n 'pr-request-review.sh N "$AUTO_REVIEW" < "$REQUEST_FILE"' "$SKILL" | head -1 | cut -d: -f1)" || _rb_req_ln=""
{ [ -n "$_rb_prp_ln" ] && [ -n "$_rb_req_ln" ] && [ "$_rb_prp_ln" -lt "$_rb_req_ln" ]; } \
    && pass "…and PRIOR_REVIEW is proven assignable BEFORE the request is posted" \
    || die "PRIOR_REVIEW is not probed before the request (probe=$_rb_prp_ln request=$_rb_req_ln)"
grep -q '^PRIOR_REVIEW=[Pp]robe-' "$SKILL" \
    && die "PRIOR_REVIEW is probed with a bare assignment; under errexit that ends the operator's shell" \
    || pass "…and not with a bare assignment, which errexit makes fatal"
# AND ITS REFUSAL NAMES BOTH ATTRIBUTES. The other two probes have runtime cases
# that read their message; this one cannot, because exercising it means POSTING a
# request — so the wording is asserted textually, or reverting it to "readonly"
# alone would leave every assertion here green while the operator was sent looking
# for an attribute that is not there.
grep -qF 'ABORT: PRIOR_REVIEW is readonly or value-transforming in this shell' "$SKILL" \
    && pass "…and its refusal names both attributes the probe rejects" \
    || die "the PRIOR_REVIEW refusal does not name the transforming attribute; a declare -i name reads as a readonly"

# …AND THE OTHER TWO ARE RUN RATHER THAN MATCHED, ONE HARNESS UP. `PRIOR_REVIEW`
# is the one that cannot be: exercising it means POSTING a request, so what it
# shares with the other two is the RULE, and the rule is what those runs prove.
#
# WHERE THOSE RUNS LIVE MOVED WITH THE CODE. The transport-parent probe is now the
# setup block's own, exercised against the lifted block in § the probed names,
# attacked — readonly, `declare -i`, `declare -l`, `declare -u`, a nameref, a
# shadowed `echo`, a neutralised `exit` and an interactive shell, each asserted on
# the CONSEQUENCE rather than on the message. The working-directory allocation is
# no longer in this document at all: `pr-setup.sh` makes the directory and the four
# files, and `test-pr-setup.sh` is where a readonly or transforming name is staged
# against it. TWO HARNESSES FOR ONE PROBE was what this file had while the second
# lift still resolved, and the duplicate is what let the first one rot unnoticed
# through a redesign — the lift kept matching a `fi` that had moved.
# AND THE REQUEST IS THE PROBES' SUCCESS ARM, not a statement after them. Written
# as standalone guards they detect the readonly name and then cannot act on it —
# `exit` is a builtin a startup file can replace with one that RETURNS, and a
# trailing reserved word only gives the `if` a false status nothing consumes, so
# execution reached the request and posted it anyway.
grep -q '^if { ( PRIOR_REVIEW="RbProbe\$\$\$RANDOM\$RANDOM"; \[\[ $PRIOR_REVIEW = RbProbe\* \]\]' "$SKILL" \
    && pass "…and the probe is a condition whose success arm holds the request" \
    || die "the PRIOR_REVIEW probe is a standalone guard; a shadowed exit walks past it into the request"
grep -q '^    if /usr/bin/env bash -p "$RB_SCRIPTS"/pr-request-review.sh' "$SKILL" \
    && pass "…with the request nested inside it" \
    || die "the request is not nested inside the probes' success arm"


# ── the round summary and the review request are ONE comment ───────────────
# The mention IS the request, so splitting them divides the record the reviewer
# is told to read and sends the request half with no account of what changed.
# The assertion is on the REQUEST BODY, not on the file appearing somewhere in the
# document. Matching `SUMMARY_FILE` anywhere passed while the round-closing
# request interpolated nothing: the file was still created and read, and Codex
# received a bare mention with no account of what changed — which the review
# policy makes it read first. The definition and the use are separate things, and
# only the use reaches the reviewer.
#
# The FIRST request is exempt and identified by its placeholder: it opens the PR,
# so there is no prior round to summarise. Every other one closes a round.
summary_req="$(awk '
    /--body "@codex review/ { want = 3; body = ""; next }
    want > 0 { body = body $0 "\n"; want--
               if (want == 0) {
                   if (body ~ /<one paragraph:/) { opening++ }
                   else if (body ~ /\$SUMMARY/) { withsum++ }
                   else { bare++ }
               }
             }
    END { printf "opening=%d withsum=%d bare=%d", opening, withsum, bare }
' "$SKILL")"; sreq_rc=$?
[ "$sreq_rc" -eq 0 ] || die "could not scan SKILL.md for the review requests (rc=$sreq_rc)"
case "$summary_req" in
    *"bare=0"*) pass "every round-closing @codex request carries \$SUMMARY in its body" ;;
    *) die "a round-closing @codex request has no summary in its body ($summary_req)" ;;
esac
case "$summary_req" in
    *) pass "…and the summary reaches the reviewer in the same comment as the mention" ;;
esac

# A mention describing an UNFIXED defect is read as a task, not as context: Codex
# then edits and commits in an environment with no remote and no credentials, so
# the commit exists nowhere and the review never happens. This cost a whole round
# once already.
grep -qi 'never as a work order' "$SKILL" \
    && pass "the skill warns that an open defect in a mention is read as a task" \
    || die "nothing stops a round summary restating an unfixed defect to the reviewer"

# Resolving is checked, not assumed: a round reported as fully resolved when it
# was not sends the next review back over findings that were already answered.
#
# Matched on the rule's own words, not on `isResolved` — that token also appears
# in the merge gate's GraphQL query further down the file, so a grep for it
# passed against a SKILL.md with the rule deleted.
#
# A FRAGMENT that fits on one line, not the whole phrase: this file is wrapped,
# `grep` is line-oriented, and an assertion spanning a line break silently never
# matches. That has now happened three times in this suite.
grep -qi 'resolve succeeded' "$SKILL" \
    && pass "the skill says to verify each resolve succeeded" \
    || die "thread resolution is assumed rather than verified"

# The watch is armed as part of the round, not put to the operator as a question.
grep -qi 'do not ask' "$SKILL" \
    && pass "the watch is armed and re-armed without asking the operator" \
    || die "the skill leaves arming the watch as a question for the operator"



# ── the Copilot summary is posted BEFORE the request ───────────────────────
# In the Codex phase the mention carries the summary, so the order is settled by
# construction. Here it is not: --add-reviewer is a separate call and Copilot can
# start reading within seconds, so requesting first means a fast pass reviews
# against the PREVIOUS round's summary.
# THE ORDINARY PATH LEAVES THE BLOCK SUCCEEDING. The last command in a block IS
# the block's status, and `[ "$PHASE_RC" -eq 3 ] && …` is FALSE when the phase
# recorded normally — so a driver saw a step that did everything right exit 1, and
# would stop or retry instead of reaching the operator decision. Executed rather
# than grepped: the shape of the last statement is the whole defect.
_tail_ok=0
( PHASE_RC=0; CODEX_SHA=abc
  if [ "$PHASE_RC" -eq 3 ]; then echo "pause"; exit 3; fi ) >/dev/null 2>&1 && _tail_ok=1
[ "$_tail_ok" -eq 1 ] \
    && pass "the record block's ordinary path leaves it succeeding" \
    || die "the record block exits non-zero when the phase recorded normally"
# …and the document uses that shape rather than the trailing `&&` that did not.
grep -q 'if \[\[ \$PHASE_RC -eq 3 \]\]; then' "$SKILL" \
    && pass "…and SKILL.md branches with an if, not a trailing &&" \
    || die "the record block ends in a test whose false value becomes the block's status"

# THE TRANSITION'S TWO STAGES ARE IN ORDER, with the operator's decision between
# them — `record` proves and posts, the document stops and asks, and only the
# answer runs `open`. Anchored on the invocations, not on the usage comment that
# lists both a few lines above them.
_rec_ln="$(grep -n 'PHASE_OUT="\$(/usr/bin/env bash -p "\$RB_SCRIPTS"/pr-copilot-phase.sh record N' "$SKILL" | head -1 | cut -d: -f1)" || true
_stop_ln="$(grep -n 'STOP — the next phase is the operator' "$SKILL" | head -1 | cut -d: -f1)" || true
_open_ln="$(grep -n 'OPEN_OUT="\$(/usr/bin/env bash -p "\$RB_SCRIPTS"/pr-copilot-phase.sh open N' "$SKILL" | head -1 | cut -d: -f1)" || true
{ [ -n "$_rec_ln" ] && [ -n "$_stop_ln" ] && [ -n "$_open_ln" ] \
    && [ "$_rec_ln" -lt "$_stop_ln" ] && [ "$_stop_ln" -lt "$_open_ln" ]; } \
    && pass "the Copilot phase opens only after the stop the operator answers" \
    || die "Copilot can be requested before the round summary exists (record=$_rec_ln stop=$_stop_ln open=$_open_ln)"

# ── the self-check runs BEFORE the push ────────────────────────────────────
# Rounds are the expensive part of the loop, so a finding a script can make in a
# second must not cost a whole review pass.
grep -q 'pr-selfcheck.sh' "$SKILL" \
    && pass "the contract runs the self-check" \
    || die "nothing runs pr-selfcheck.sh before a round is pushed"
# The ORDER IN THE NUMBERED PROCEDURE, not merely the order of the two lines in
# the file. The previous version matched a self-check line appearing anywhere
# before any later `git push` code block, which stayed true while the checklist
# told the driver to push in step 2 and self-check in step 3 — so a driver
# following the sequence pushed before running the check meant to prevent it.
self_step="$(grep -nE '^[0-9]+\. \*\*run the self-check' "$SKILL" | head -1 | cut -d: -f1)"
push_step="$(grep -nE '^[0-9]+\. \*\*check the round boundary' "$SKILL" | head -1 | cut -d: -f1)"
{ [ -n "$self_step" ] && [ -n "$push_step" ] && [ "$self_step" -lt "$push_step" ]; } \
    && pass "…and the numbered procedure runs it before the step that pushes" \
    || die "the checklist pushes before the self-check that is meant to prevent it"
grep -q 'SELF_RC' "$SKILL" \
    && pass "…and its exit status is branched on" \
    || die "the self-check output is not checked"

# ── the first request respects the review mode too ─────────────────────────
# With auto-review on, opening or pushing the PR has already queued a pass, so an
# unconditional mention queues a SECOND review of the same head.
# NO COMMAND, FOR THE SAME REASON THE PARSER IT CHECKS HAS NONE. Under
# `set -Eeuo pipefail` a `grep` that matches nothing aborts the assignment and
# takes the whole file with it — before the `die` below and before `RESULT:` is
# printed at all, which is the silent pass this file exists to make impossible.
# Issue #39.
#
# `|| true` fixes that and creates another: it discards the difference between
# "no match" and a lookup that PRINTED a plausible line number and then failed,
# which command substitution keeps. `awk` in one process fixed that in turn, and
# `awk` is a command a function can shadow — an exported one returning forged
# line numbers makes the ordering below agree about lines that are not there.
#
# `$(<file)` is a redirection and `${…}` is expansion; `while`, `if` and `[[` are
# reserved words. Nothing here can be replaced by a function, so the answer can
# only come from the file. Empty means absent, which the emptiness test handles.
# THE RESULT IS AN ASSIGNMENT, NOT SOMETHING PRINTED. Returning the number
# through `printf` inside `$( )` put one last shadowable builtin in the path: a
# `printf()` that delegates ordinary output and forges these numeric calls hands
# back line numbers the file does not have, and the ordering below agrees. An
# assignment is one of the two things `CLAUDE.md` says cannot be taken over.
RB_SKILL_BODY="$(<"$SKILL")"
RB_LINE=""
# ONE CUT, AND THE ANSWER IS THE OFFSET. This walked the document a line at a
# time, peeling the front off a 140 KB string on every iteration — quadratic, and
# nine seconds for two lookups. Cutting at the needle is one expansion.
#
# AN OFFSET RATHER THAN A LINE NUMBER, because the caller compares two of them
# and nothing else. Turning the prefix into a line count needs
# `${_pre//$'\n'/}`, and a global substitution over a 140 KB string is fast on
# bash 5 and pathological on the 3.2.57 the `macos-shell` job builds — the same
# expansion in `rb_occurrences` below ran for ten minutes there and was killed.
# Byte offsets order the two needles exactly as line numbers do, so the count was
# not buying anything.
#
# ABSENCE IS A LENGTH, not a second search. `%%` returns the string UNCHANGED
# when the needle is not in it, so the prefix being the whole body is what
# "absent" means — asking `[[ $body == *"$1"* ]]` first is a second full match
# over the same string for an answer the cut already gave.
rb_line_of() {   # rb_line_of <needle> ; sets RB_LINE to its offset, empty when absent
    local _pre
    RB_LINE=""
    _pre="${RB_SKILL_BODY%%"$1"*}"
    [ "${#_pre}" -eq "${#RB_SKILL_BODY}" ] && return 0
    RB_LINE=$(( ${#_pre} + 1 ))
    return 0
}
rb_line_of 'AUTO_REVIEW=no';                    sel="$RB_LINE"
rb_line_of 'Request the review — Codex first';  req="$RB_LINE"
# …AND A FORGED `awk` CANNOT ANSWER FOR THE FILE. An exported function returning
# plausible line numbers made this ordering agree about lines that had been
# deleted; the lookup uses no command now, so the case asserts that directly.
# THE LOOKUPS THEMSELVES GO THROUGH IT, which the probe below cannot show: that
# probe exercises `rb_line_of`, so reverting the two assignments to `awk` leaves
# it passing while the lookups trust a command again. Both halves are needed —
# one says the helper is command-free, the other says the lookups use the helper.
# COUNTED, BECAUSE A CHECK THAT GREPS ITS OWN FILE FINDS ITSELF. The first
# version searched this file for the lookup's text — which this very line
# contains, so reverting the lookup to `awk` left the check matching its own
# source and passing. Each needle must appear TWICE: once here and once as the
# lookup, so losing the lookup drops the count.
_rb_self="$(<"$0")"
# TWO CUTS, AND WHETHER THEY LAND IN THE SAME PLACE. What the assertion below
# needs is "at least twice", not a count — and asking for a count is what made
# this expensive three times running. The loop it started as ran a `*needle*`
# match over 330 KB per occurrence, twenty-nine seconds. The global substitution
# that replaced it cost nothing on bash 5 and was killed after ten minutes on the
# bash 3.2.57 the `macos-shell` job builds. A prefix-strip loop is quadratic on
# BOTH — fifteen seconds per `#*needle` here.
#
# `%%` cuts at the FIRST occurrence and `%` at the LAST. If those two prefixes
# are different lengths there is more than one occurrence; if the needle is
# absent both are the whole string. Two suffix operations, no loop, and a second
# each on the shell this file has to be fast on.
#
# AN EMPTY NEEDLE STILL NEEDS ITS GUARD, and for a different reason than before:
# `*` matches empty, so `%` removes nothing while `%%` removes everything, and
# the two lengths differ — which would report "twice" for a needle that is not
# there at all.
rb_appears_twice() {   # sets RB_TWICE=yes when $1 occurs at least twice in this file
    local _first _last
    RB_TWICE=no
    [ -n "$1" ] || return 0
    _first="${_rb_self%%"$1"*}"
    _last="${_rb_self%"$1"*}"
    [ "${#_first}" -ne "${#_last}" ] && RB_TWICE=yes
    return 0
}
rb_line_of 'a needle this document does not contain anywhere at all'
[ -z "$RB_LINE" ] \
    && pass "a needle the document does not carry reports no line rather than its last" \
    || die "an absent needle reported line '$RB_LINE'"
# …AND A NEEDLE OF NO LENGTH IS NOT "TWICE". `*` matches empty, so without the
# guard `%` removes nothing while `%%` removes everything and the two lengths
# differ — reporting a needle that is not there at all as present twice, which is
# the fail-open direction for the assertion below.
rb_appears_twice ""
[ "$RB_TWICE" = no ] \
    && pass "…and a needle of no length is not found twice" \
    || die "an empty needle was reported as appearing twice"
rb_appears_twice "rb_line_of 'AUTO_REVIEW=no'";                   _rb_sel_n="$RB_TWICE"
rb_appears_twice "rb_line_of 'Request the review — Codex first'"; _rb_req_n="$RB_TWICE"
{ [ "$_rb_sel_n" = yes ] && [ "$_rb_req_n" = yes ]; } \
    && pass "the contract lookups read the file through the command-free helper" \
    || die "a contract lookup went back to a command a function can shadow ($_rb_sel_n/$_rb_req_n)"
# In its own shell, with the function spliced in and `SHELLOPTS` cleared — an
# inherited `onecmd` would stop a `-c` script after one command and the probe
# would measure the truncation instead of the lookup.
# THE PATH TRAVELS, NOT THE BODY. `SKILL.md` passed through the environment as a
# single value, and Linux caps ONE environment string at 128 KiB — the document
# reached that in this PR, and `env` then failed with 126, which `set -e` turned
# into a silent stop of this whole file after 150 assertions. The child reads the
# file itself with `$(<…)`, a redirection rather than a name, so the probe still
# proves what it was written to prove.
_rb_forged="$(env -u SHELLOPTS RB_SKILL_PATH="$SKILL" bash -c '
    printf() { builtin printf "%s\n" 999; }
    awk() { builtin printf "%s\n" 999; }
    grep() { builtin printf "%s\n" 999; }
    sed() { builtin printf "%s\n" 999; }
    RB_SKILL_BODY="$(<"$RB_SKILL_PATH")"
    '"$(declare -f rb_line_of)"'
    rb_line_of "AUTO_REVIEW=no"
    # Restored only to REPORT the answer: the lookup itself has already run, and
    # what is being asserted is that none of the above could reach it.
    unset -f printf
    printf "%s\n" "$RB_LINE"' 2>/dev/null)"
[ "$_rb_forged" = "$sel" ] \
    && pass "shadowed printf, awk, grep and sed cannot supply a line number" \
    || die "a forged builtin changed a lookup: got '$_rb_forged', wanted '$sel'"
{ [ -n "$sel" ] && [ -n "$req" ] && [ "$sel" -gt "$req" ]; } \
    && pass "the review mode is established in the request step, before the mention" \
    || die "the first @codex mention is posted before the review mode is known"
# THE BRANCH IS THE HELPER'S NOW (#144, under #26), so what the driver must do
# is HAND IT OVER: a mode established here and not passed on leaves the helper
# with no way to tell the two orderings apart, and it has no default — every
# unrecognised value is refused by name, which `test-pr-request-review.sh`
# executes. Asserted as the argument rather than as the branch, because the
# branch is somewhere the suite can run it.
grep -q 'pr-request-review.sh N "\$AUTO_REVIEW" <' "$SKILL" \
    && pass "…and the initial request is given it" \
    || die "the initial request does not branch on the review mode"

# ── the numbered checklist does not push ──────────────────────────────────
# The push belongs to the mode-specific recipe: with auto-review on it must come
# after the threads are resolved and the summary posted, or the pass it triggers
# reads the previous round's account against threads that are still open.
grep -qE '^3\. \*\*check the round boundary — step 6\.\*\*' "$SKILL" \
    && pass "the boundary step no longer carries the push" \
    || die "the checklist still pushes in the boundary step"
grep -q 'The push is not' "$SKILL" \
    && pass "…and says where the push actually belongs" \
    || die "the checklist does not say where the push belongs"

# ── the self-check's third outcome is handled ─────────────────────────────
# `not_applicable` shares no exit status with "checks passed": the same code
# would have let the driver report a clean check when none ran.
grep -q 'not applicable\*\*: this repository is not a' "$SKILL" \
    && pass "the contract documents the not-applicable outcome" \
    || die "SKILL.md defines no handling for a run where nothing was in scope"

# ── findings get a reaction ────────────────────────────────────────────────
# Every Codex finding ends with "Useful? React with thumbs", and that reaction is
# the only signal the reviewer gets about whether a review was worth making.
grep -q 'pulls/comments/<comment-id>/reactions' "$SKILL" \
    && pass "the contract reacts to each finding" \
    || die "findings are resolved without the reaction the reviewer asks for"
grep -q 'comment=' "$ROOT/skills/watch-prs/scripts/pr-findings.sh" \
    && pass "…and list prints the comment id the reaction needs" \
    || die "pr-findings.sh does not print a comment id to react to"

# ── a timeout re-arms; it never re-requests and never asks ────────────────
# Re-requesting queues a duplicate pass on the same head, and asking turns the
# automatic loop back into the manual one it replaces.
grep -q 're-arm the same watch' "$SKILL" \
    && pass "a watch timeout re-arms the same watch" \
    || die "the timeout action is ambiguous; it may re-request or prompt"
grep -q 'timed out | re-request, or ask the operator' "$SKILL" \
    && die "the timeout row still offers re-requesting or prompting" \
    || pass "…and neither re-requests nor prompts"

# ── the helper discovery is checked and its result validated ──────────────
# `ls` can print one candidate and then fail on an unreadable cache entry, and
# `head` masks that status — so an unchecked pipeline selects a partial or stale
# path and every later call runs a different version of the helpers.
grep -q 'ABORT: could not enumerate installed plugin copies' "$SKILL" \
    && pass "the cached-helper discovery branches on its status" \
    || die "the helper discovery pipeline is unchecked"
grep -q 'ABORT: could not locate the plugin helper scripts' "$SKILL" \
    && pass "…and the selected directory is validated before it is used" \
    || die "the discovered helper directory is used without validation"

# ── every gh pr call names the repository ─────────────────────────────────
# `GH_REPO` overrides the repository `gh` infers from the checkout, so an
# unpinned call can act on the same-numbered PR somewhere else while every gate
# inspects this one. Enforced mechanically by pr-selfcheck.sh; asserted here so
# the contract itself cannot drift.
# A COMPARISON, not a magic number: the count changes whenever a call is added,
# and a fixed expectation fails for that reason rather than for an unpinned call.
comment_calls="$(grep -c 'gh pr comment N' "$SKILL")"
comment_pinned="$(grep -c 'gh pr comment N --repo "$HOST/$OWNER/$REPO"' "$SKILL")"
# THE SLUG IS QUOTED AT EVERY SITE, and this assertion used to pin the UNQUOTED
# spelling — so it was enforcing the defect rather than catching it. Nothing in
# `identitylib.sh` constrains what an owner or repo may contain (its shape checks
# are on the remote and the host), and the suite covers an owner with a space in
# it, so an unquoted slug splits into two arguments and the call targets something
# else or fails. The runtime scripts fixed this in #28; the document had nineteen
# sites still carrying it.
unquoted_slug="$(grep -c -- '--repo \$HOST/\$OWNER/\$REPO' "$SKILL")" || unquoted_slug=0
[ "${unquoted_slug:-0}" -eq 0 ] \
    && pass "every --repo in the document quotes the derived slug" \
    || die "$unquoted_slug --repo call(s) would split an owner containing a space"
[ "$comment_calls" -eq "$comment_pinned" ] \
    && pass "every gh pr comment call is pinned to the derived repository" \
    || die "$((comment_calls - comment_pinned)) gh pr comment call(s) do not pass --repo"

# ── THE REFUSED MARKERS ARE DOCUMENTED WHERE AN AUTHOR WILL LOOK ──────────
# The set lives in `recordlib.sh`; `SKILL.md` and `README.md` tell an author which
# lines their body may not start with. This has drifted twice in this PR alone —
# once by documenting a marker the rule had stopped refusing, once by offering a
# fenced block as a way round it — so the forward direction is checked here.
#
# WHAT THIS CANNOT DO: it cannot tell that prose lists a marker the rule does NOT
# refuse. That is the drift that happened, and catching it means parsing an inline
# enumeration out of Markdown, which this repository has twice paid for and
# deleted. So the count is PINNED instead: adding or removing a marker fails here
# with a message naming both documents, and the prose is then read by a human.
# DERIVED FROM THE CASE ARMS, NOT COUNTED BY LINE. The first version counted
# SOURCE LINES and looped over three hard-coded names: deleting one marker from a
# line that carries two left the count at 2 and the loop still found all three
# names in the documents, so the suite passed while the runtime accepted a marker
# the docs said it refused — the exact drift this exists to prevent. The set is
# read out of the `case` arms now, so membership and cardinality both come from
# the rule.
# READ FROM THE `for` LIST THAT DEFINES THEM, which is where the rule moved when
# the scan stopped peeling line by line. Anchored on the quoted marker literals
# rather than on the loop's shape, so a reformat does not silently empty this.
_mk_set="$(grep -o "'\*\*[A-Za-z:-]*\*\*'" "$SCRIPT_DIR/recordlib.sh" \
    | sed "s/^'\*\*//; s/\*\*'$//" | sort -u)" || true
_mk_n="$(grep -c . <<<"$_mk_set")" || _mk_n=0
[ "$_mk_n" -eq 3 ] \
    && pass "the reserved-marker set is the size SKILL.md and README.md describe" \
    || die "the reserved-marker set changed ($_mk_n markers, expected 3: $(printf '%s' "$_mk_set" | tr '\n' ' ')) — update SKILL.md and README.md, then this count"
# SCOPED TO THE REFUSAL PASSAGE, not to the file. Both documents name these
# markers elsewhere — `README.md` documents the acknowledgement's own format in the
# round-boundary section — so a whole-file `grep` is satisfied by a mention that
# has nothing to do with what an author may write. That is the "the token also
# appears elsewhere" trap, and the first version of this check fell into it: a
# marker deleted from the refusal list still passed.
_skill_pass="$(awk '/^# THE RESERVED MARKERS MUST NOT START A LINE IN THIS BODY:/{c=5} c-->0' "$SKILL")" || true
_readme_pass="$(awk '/^   The body you supply is prose/{c=12} c-->0' "$ROOT/README.md")" || true
{ [ -n "$_skill_pass" ] && [ -n "$_readme_pass" ]; } \
    && pass "…and both layers still carry the passage that tells an author about them" \
    || die "the refusal passage is gone from SKILL.md or README.md (skill=${#_skill_pass} readme=${#_readme_pass})"
for _m in $_mk_set; do
    { grep -qF "**$_m**" <<<"$_skill_pass" \
        && grep -qF "**$_m**" <<<"$_readme_pass"; } \
        && pass "…and $_m is named in both layers an author reads" \
        || die "$_m is refused by the rule but missing from the refusal passage in SKILL.md or README.md"
done

# ── the shipping manifest lists every runtime helper ──────────────────────
# CLAUDE.md calls everything unlisted "documentation", so an incomplete table is
# not a cosmetic gap — it tells a maintainer that four executable helpers are
# prose. Derived from the directory, so adding a helper without listing it fails.
CLAUDEMD="$ROOT/CLAUDE.md"
if [ -f "$CLAUDEMD" ]; then
    # Scoped to the What-ships TABLE, not the whole file. Every helper is also
    # named in the strict-mode table further down, so a whole-file grep passed
    # against a manifest with a helper deleted — the same "the token appears
    # elsewhere" trap that made an earlier assertion here vacuous.
    manifest="$(awk '/^## What ships/{inb=1; next} /^## /{inb=0} inb' "$CLAUDEMD")"
    manifest_missing=""
    for h in "$SCRIPT_DIR"/pr-*.sh; do
        [ -e "$h" ] || continue
        b="$(basename "$h")"
        grep -q "$b" <<<"$manifest" || manifest_missing="$manifest_missing $b"
    done
    [ -z "$manifest_missing" ] \
        && pass "CLAUDE.md's What-ships table lists every runtime helper" \
        || die "runtime helpers missing from the shipping manifest:$manifest_missing"
    # ── AND THE STRICT-MODE TABLE, for the same reason and by the same means ──
    # That table is the repository's source of truth for which mode a script is
    # in, and `-e` is FORBIDDEN in the `set -uo pipefail` row: every helper there
    # uses non-zero statuses as control flow, so a later cleanup applying `-e` on
    # the table's authority would terminate them before a status could be handled.
    # A helper missing from it is not a documentation gap, it is a script the
    # table implicitly consents to being "fixed".
    #
    # DERIVED FROM THE DIRECTORY, like the manifest above, because #124 added a
    # helper to one table and not the other — and a hand-kept list is missing the
    # next one by construction.
    #
    # SCOPED TO THE ROW, not the section: every helper is named in the What-ships
    # table too, so a section-wide grep passes against a row with a helper deleted.
    strict_row="$(awk '/^\| .set -uo pipefail. \|/' "$CLAUDEMD")"
    [ -n "$strict_row" ] || die "CLAUDE.md has no 'set -uo pipefail' row to check"
    strict_missing=""
    for h in "$SCRIPT_DIR"/pr-*.sh; do
        [ -e "$h" ] || continue
        b="$(basename "$h")"
        grep -q "$b" <<<"$strict_row" || strict_missing="$strict_missing $b"
    done
    [ -z "$strict_missing" ] \
        && pass "…and its strict-mode table says which mode each of them is in" \
        || die "runtime helpers missing from the strict-mode table:$strict_missing"
fi

# ── every git probe takes its status ──────────────────────────────────────
# Third time this class appeared: the origin lookups, then the self-check's root
# lookup, then these two. `|| true` on a probe is the opposite of failing closed.
grep -q 'ABORT: could not resolve the repository root' "$SKILL" \
    && pass "the identity block branches on the repo-root probe" \
    || die "the repo-root probe is unchecked; a failed read becomes the merge tree"
if [ -f "$SCRIPT_DIR/pr-merge-range.sh" ]; then
    grep -q 'rev-parse --show-toplevel 2>/dev/null || true' "$SCRIPT_DIR/pr-merge-range.sh" \
        && die "pr-merge-range.sh still swallows its root probe status with || true" \
        || pass "pr-merge-range.sh does not swallow its root probe status"
fi

# ── the phase summary WRITE is checked, not only the read ─────────────────
# A truncated write leaves a non-empty partial body that the guarded read
# returns; a failed open leaves the previous round's contents to be read as this
# round's. Either posts an invalid summary and requests Copilot against it.

# ── the summary file's creation is checked ────────────────────────────────
# `mktemp` can print a plausible path and then fail, and every later write and
# guarded read would then point at an existing file — a stale summary read back
# as this round's, which is what the guarded read was added to prevent.
# THE DOCUMENT'S OWN WRITE IS BRANCHED ON. The phase body is written HERE and read
# by `pr-copilot-phase.sh`, so an unchecked redirection is a gap between them: a
# `cat` that truncates and then fails leaves a FRAGMENT that passes the script's
# non-empty test and is posted as the phase's account, and a failed open leaves
# the previous round's contents to be posted as this one's. The script cannot see
# either — by the time it reads, the file looks like a body.
grep -qF "cat > \"\$SUMMARY_FILE\" <<'EOF' || {" "$SKILL" \
    && grep -q 'ABORT: could not write the phase body' "$SKILL" \
    && pass "the phase body write is branched on before the script is asked to read it" \
    || die "the phase summary is written without checking the write"
# THE ALLOCATION ITSELF IS NO LONGER IN THIS DOCUMENT. `mktemp` being a name, the
# four suffixes being pairwise distinct, the `mkdir -m 700` exclusion and the files
# being created empty were all asserted here while the driver did that work; since
# #228 `pr-setup.sh` does it, and `test-pr-setup.sh` is where those live — against
# the code rather than against a grep of the prose describing it.
#
# WHAT STAYS HERE IS THE DRIVER'S HALF, and it is asserted where the source is: the
# four paths are proved against their literals under `$RB_SETUP_DIR` and proved to
# be empty files, in § the four working paths are proved to be the ones setup made,
# and the completion line is proved to be the innermost arm's alone. A grep for the
# allocation's shape would now be a grep for a paraphrase of a helper's source.

# ── the watch deadline is absolute ────────────────────────────────────────
# Accumulating only the sleeps excluded the time spent inside the probes, so slow
# GitHub reads made a one-hour watch run far past an hour.
if [ -f "$SCRIPT_DIR/pr-watch.sh" ]; then
    grep -q 'elapsed_s()' "$SCRIPT_DIR/pr-watch.sh" \
        && pass "pr-watch.sh measures elapsed time against the clock" \
        || die "pr-watch.sh accumulates sleeps, so probe time escapes --timeout"
    grep -q 'waited=\$((waited + nap))' "$SCRIPT_DIR/pr-watch.sh" \
        && die "pr-watch.sh still accumulates the nap instead of reading the clock" \
        || pass "…rather than accumulating the naps"
fi

# ── the Codex signoff is re-validated on the sha it records ───────────────
# A push between the clean verdict and this lookup recorded the new, unreviewed
# head as the signoff, and the gate only noticed after the whole Copilot phase.

# ── every gh call names the host as well as the repository ────────────────
# `GH_HOST` supplies the hostname when a command gives none, so an unpinned call
# can act on the same-numbered PR on another GitHub host.
# THE ASSERTION FOLLOWS THE RULE, not the text that used to state it. This was
# `grep -q 'HOST='` over SKILL.md, which held only while the parser was written
# out there; the parser is `identitylib.sh` now, and a text check left pointing at
# SKILL.md would have gone on passing against a driver that derived nothing at
# all. So: the driver must DELEGATE, and the parser must derive.
grep -q '^[[:space:]]*REVIEW_BUS_REMOTE="$RB_REMOTE" rb_identity || RB_REMOTE=$' "$SKILL" \
    && pass "the driver derives its identity through the shared parser" \
    || die "SKILL.md does not call rb_identity; the identity comes from somewhere else"
grep -q 'HOST=' "$SCRIPT_DIR/identitylib.sh" \
    && pass "…and the parser derives the host from origin" \
    || die "the host is not derived; GH_HOST can redirect every call"
# …and the parser is sourced only after the helper directory is known. Written the
# other way round the `.` reads an unset path, which under this driver's rules is
# an abort — but a driver that aborts at step zero on every repository is a tool
# nobody can run, and it would be found by trying rather than by reading.
awk '/^RB_SCRIPTS=/ {r=NR}
     /^\. "\$RB_SCRIPTS\/identitylib\.sh"/ {if (r && r < NR) {print "ok"; exit}}' "$SKILL" \
    | grep -q ok \
    && pass "…and the helpers are located before the parser is loaded from them" \
    || die "SKILL.md sources identitylib.sh before RB_SCRIPTS is resolved"
# …and any INHERITED definition is cleared before that source. Bash exports
# functions through the environment, so a session that had already defined
# `rb_identity` leaves one here — and an empty or truncated library still sources
# successfully, at which point the `type -t` guard finds the inherited function,
# reports the parser loaded, and every call is addressed by whatever it derives.
awk '/^unset -f rb_identity/ {u=NR}
     /^\. "\$RB_SCRIPTS\/identitylib\.sh"/ {if (u && u < NR) {print "ok"; exit}}' "$SKILL" \
    | grep -q ok \
    && pass "…and a stale parser definition is cleared before the library loads" \
    || die "an inherited rb_identity would satisfy SKILL.md's parser-load check"
# …and the clearing's own status is taken. `readonly -f rb_identity` makes the
# unset FAIL and leaves the function installed, so a discarded status made a
# definition that could not be cleared indistinguishable from one that was never
# there.
#
# ASSERTED AS A COUPLING, NOT AS THE ABSENCE OF ONE SPELLING. The first version
# forbade the literal `|| true` — a blacklist, and a blacklist is always one
# spelling behind: `|| :`, or deleting the handler outright, passed it while the
# defect returned in full. This repository has already replaced a lexical
# blacklist with a whitelist once, for exactly that reason. So the requirement is
# positive: the unset must be joined to a branch that EXITS. Continuations are
# flattened first, because the branch is on the next line.
#
# AND IT IS RUN, not matched. A regex requiring the token `exit 1` accepts
# `|| echo "exit 1"` — the exit inside quoted data, the handler printing a word and
# the driver carrying on with the stale parser. That is the whitelist repeating the
# blacklist's mistake at one remove: recognising the SPELLING of the guarantee
# instead of the guarantee. So the setup block is extracted from SKILL.md and
# EXECUTED against the state it is supposed to refuse — a readonly `rb_identity`
# that cannot be cleared, and an `identitylib.sh` that is empty.
#
# The block is run in a throwaway git checkout with `CLAUDE_PLUGIN_ROOT` pointed at
# a scripts directory holding an empty parser and an executable `pr-review-state.sh`
# — the two things its own validation looks for — so everything before the parser
# load succeeds and the refusal under test is the only thing that can stop it.
setup_block="$(awk '/^## Derive identity$/ {sec=1}
                    sec && /^```bash$/ {inb=1; next}
                    inb && /^```$/ {exit}
                    inb' "$SKILL")"
[ -n "$setup_block" ] || die "the Derive identity block could not be extracted"
SETUPTMP="$(mktemp_d)" || { die "no scratch directory for the setup probe"; SETUPTMP=""; }
if [ -n "$SETUPTMP" ] && [ -n "$setup_block" ]; then
    mkdir -p "$SETUPTMP/repo" "$SETUPTMP/plugin/skills/watch-prs/scripts"
    : > "$SETUPTMP/plugin/skills/watch-prs/scripts/identitylib.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' \
        > "$SETUPTMP/plugin/skills/watch-prs/scripts/pr-review-state.sh"
    chmod +x "$SETUPTMP/plugin/skills/watch-prs/scripts/pr-review-state.sh"
    # THE REAL `pr-origin.sh`, not a stub. The setup block reads origin and proves
    # the pin through it, and both answers are what the rest of the block is then
    # asserted on — a stub printing a fixed string would make these cases pass
    # against a setup that never consulted the checkout at all.
    cp "$SCRIPT_DIR/pr-origin.sh" "$SETUPTMP/plugin/skills/watch-prs/scripts/pr-origin.sh"
    chmod +x "$SETUPTMP/plugin/skills/watch-prs/scripts/pr-origin.sh"
    # AND THE REAL `pr-setup.sh`, WITH THE LIBRARIES IT LOADS. It is the block's
    # first call and everything after it is inside its success arm, so a stub — or
    # an absent file — turns every case below into the same refusal, about the
    # staging rather than about its subject.
    for _rb_cp in pr-setup.sh loadlib.sh; do
        cp "$SCRIPT_DIR/$_rb_cp" "$SETUPTMP/plugin/skills/watch-prs/scripts/$_rb_cp"
    done
    chmod +x "$SETUPTMP/plugin/skills/watch-prs/scripts/pr-setup.sh"
    ( cd "$SETUPTMP/repo" && git init -q && git remote add origin git@github.com:acme/widget.git ) \
        >/dev/null 2>&1 || die "the setup probe's checkout could not be created"
    # ── THE CI BOUNDS SURVIVE THE PROCESS BOUNDARY ─────────────────────────
    #
    # The gate is a child process now, and that is exactly where a documented knob
    # can be lost in silence. `PR_CI_TIMEOUT=3600` ASSIGNED in the operator's shell
    # was read by the function it replaced; a child sees nothing unless the value
    # is exported, so the gate would have used its 1800-second default while the
    # terminal showed the value that was set. `README.md` tells people to set these.
    #
    # ASSIGNED, NOT EXPORTED, and the probe is a CHILD — passing it through `env`
    # would test the harness rather than the setup block, which is how the
    # behaviour reached review uncovered in the first place.
    #
    # `TMPDIR` points into the probe's own tree: the setup block allocates the
    # round's summary file with `mktemp -t`, and two more runs of it would leave
    # two more files wherever that points — which the leak check at the end of this
    # file would report, correctly, against a probe that is not about that.
    cat "$SCRIPT_DIR/identitylib.sh" \
        > "$SETUPTMP/plugin/skills/watch-prs/scripts/identitylib.sh"
    knob_out="$(cd "$SETUPTMP/repo" && run_limited 60 env -u PR_CI_TIMEOUT \
        CLAUDE_PLUGIN_ROOT="$SETUPTMP/plugin" TMPDIR="$SETUPTMP" \
        bash -c 'PR_CI_TIMEOUT=3600
                 eval "$1" >/dev/null
                 bash -c '"'"'printf "child=%s" "${PR_CI_TIMEOUT-unset}"'"'"'' _ "$setup_block" 2>&1)" \
        || knob_out="FAILED:$knob_out"
    case "$knob_out" in
        *child=3600*) pass "a CI bound set without export still reaches the gate's process" ;;
        *) die "the setup block does not export the CI bounds (got '$knob_out')" ;;
    esac
    # …AND `REVIEW_MERGE_STRICT` WITH THEM, which is the one where losing it does
    # not fail but silently makes the merge LESS safe: unset, the gate keeps
    # `--admin` and bypasses the branch protection the operator set this to hand
    # over to GitHub. Asserted separately from the CI bounds because it is a
    # different kind of loss — those degrade a wait, this degrades a gate.
    strict_out="$(cd "$SETUPTMP/repo" && run_limited 60 env -u REVIEW_MERGE_STRICT \
        CLAUDE_PLUGIN_ROOT="$SETUPTMP/plugin" TMPDIR="$SETUPTMP" \
        bash -c 'REVIEW_MERGE_STRICT=1
                 eval "$1" >/dev/null
                 bash -c '"'"'printf "child=%s" "${REVIEW_MERGE_STRICT-unset}"'"'"'' _ "$setup_block" 2>&1)" \
        || strict_out="FAILED:$strict_out"
    case "$strict_out" in
        *child=1*) pass "…and strict merge mode reaches it too, rather than silently restoring --admin" ;;
        *) die "REVIEW_MERGE_STRICT does not survive into the merge gate (got '$strict_out')" ;;
    esac
    # …AND `RB_SUITE_JOBS`, which crosses the same boundary at step 5a. The gate
    # runs the suite concurrently and reads its degree from that name; without the
    # export an operator who lowers it here watches the gate go on running four at
    # a time while their terminal shows the value they set.
    jobs_out="$(cd "$SETUPTMP/repo" && run_limited 60 env -u RB_SUITE_JOBS \
        CLAUDE_PLUGIN_ROOT="$SETUPTMP/plugin" TMPDIR="$SETUPTMP" \
        bash -c 'RB_SUITE_JOBS=1
                 eval "$1" >/dev/null
                 bash -c '"'"'printf "child=%s" "${RB_SUITE_JOBS-unset}"'"'"'' _ "$setup_block" 2>&1)" \
        || jobs_out="FAILED:$jobs_out"
    case "$jobs_out" in
        *child=1*) pass "…and the suite concurrency reaches the pre-push gate's process" ;;
        *) die "RB_SUITE_JOBS does not survive into pr-selfcheck.sh (got '$jobs_out')" ;;
    esac
    # …AND THE LOOP VARIABLE DOES NOT LEAK INTO THE OPERATOR'S SHELL. This block
    # runs in the driving session, so a name it forgets to clean up is written into
    # that session and stays there — the same class the CI gate's `local`
    # declarations used to guard, which is now the process boundary's job
    # everywhere EXCEPT here, because this block genuinely does run in your shell.
    #
    # Two things are deliberately NOT asserted, because neither can fail:
    # `export FOO` on an unset name puts nothing in the environment, so a child
    # cannot tell that spelling from the guarded one; and the loop cannot abort a
    # `set -e` session, because bash exempts a `&&` list whose left side fails.
    # A fixture for either would be a green tick over an unverifiable claim.
    knob_leak="$(cd "$SETUPTMP/repo" && run_limited 60 env \
        CLAUDE_PLUGIN_ROOT="$SETUPTMP/plugin" TMPDIR="$SETUPTMP" \
        bash -c 'eval "$1" >/dev/null
                 printf "leak=%s" "${_rb_knob-clean}"' _ "$setup_block" 2>&1)" \
        || knob_leak="FAILED:$knob_leak"
    case "$knob_leak" in
        *leak=clean*) pass "…and the export loop leaves no name behind in that shell" ;;
        *) die "the setup block leaks its loop variable into the session (got '$knob_leak')" ;;
    esac

    # A readonly definition, in the SAME shell the block runs in — which is the
    # driver's situation, and the only place the case is reachable. `readonly -f`
    # does not survive a process boundary.
    # The status is captured at the point it is produced. This file runs under
    # `-e`, and the probe is EXPECTED to fail — that is the assertion — so an
    # unguarded assignment terminates the suite here instead of asserting anything.
    setup_rc=0
    # THE PARSER IS THE ONLY FUNCTION LEFT TO CLEAR. `ci_gate` was the other one,
    # and it is a script now — a process cannot be shadowed by a `readonly -f`
    # definition in the driver's shell, so the case it needed this guard for does
    # not exist. That is the argument of issue #26 as a deletion: the guard was
    # never the point, the function-in-a-document was.
    #
    # THE ABORT MESSAGE IS ASSERTED, not merely a non-zero status. Written with a
    # shared empty `identitylib.sh`, a second case here once passed while proving
    # nothing — the block aborted at the empty parser long before reaching what was
    # under test, and "the driver stopped" was true for the wrong reason.
    for stale_case in 'rb_identity:empty:could not be cleared'; do
        stale_fn="${stale_case%%:*}"; stale_rest="${stale_case#*:}"
        stale_lib="${stale_rest%%:*}"; stale_msg="${stale_rest#*:}"
        if [ "$stale_lib" = empty ]; then
            : > "$SETUPTMP/plugin/skills/watch-prs/scripts/identitylib.sh"
        else
            cat "$SCRIPT_DIR/identitylib.sh" \
                > "$SETUPTMP/plugin/skills/watch-prs/scripts/identitylib.sh"
        fi
        setup_rc=0
        setup_out="$(cd "$SETUPTMP/repo" && run_limited 60 env CLAUDE_PLUGIN_ROOT="$SETUPTMP/plugin" \
            bash -c 'eval "$1() { HOST=github.com; OWNER=someone-else; REPO=other-repo; }"
                     readonly -f "$1"
                     eval "$2"
                     echo "CONTINUED:$OWNER"' _ "$stale_fn" "$setup_block" 2>&1)" || setup_rc=$?
        case "$setup_out" in
            *CONTINUED*) die "the driver continued past a $stale_fn it could not clear ($setup_out)" ;;
            *) pass "…and a $stale_fn that cannot be cleared stops the driver" ;;
        esac
        grep -qF "$stale_msg" <<<"$setup_out" \
            && pass "…stopping for that reason and not another" \
            || die "$stale_fn stopped the driver, but not as '$stale_msg' (out='$setup_out')"
        [ "$setup_rc" -ne 0 ] \
            && pass "…reporting a failure rather than an abort message alone" \
            || die "the setup block refused $stale_fn but exited 0 (out='$setup_out')"
    done
    # ── WHAT A SQUATTER ON THE PUBLISHED CANDIDATE ACTUALLY COSTS ─────────
    #
    # #160: the transport candidate is an argv entry, published at `exec` — mode
    # 444 in `/proc/<pid>/cmdline` — so another account on a shared parent can read
    # it before the `mkdir` reserves it and create the name first. What that BUYS
    # them is the question this region answers, and it is answered by running the
    # whole setup block against the real helper rather than by argument.
    #
    # THE ANSWER IS A REFUSAL, NEVER A FORGED ORIGIN. The helper reserves with
    # `mkdir -m 700`, which is an exclusion: a name somebody else holds is refused
    # and never written through, so a squatter cannot put a value where setup will
    # read it. `test-pr-origin.sh` proves that half on the helper. What is left is
    # what the DRIVER does with it, and these two cases are that.
    #
    # WHAT IS MODELLED IS THE `mkdir` FAILING, and nothing else. Staging a real
    # squat means pre-creating a name built from `$$` and three `$RANDOM` draws
    # inside a shell this fixture has not started yet — unknowable in advance,
    # which is precisely why a squatter has to READ it. A `mkdir` on `PATH` that
    # refuses one parent and otherwise execs the real one reproduces the same
    # `EEXIST` deterministically; everything downstream — the status, the retry,
    # the parent swap, the pin — is the real code.
    # AN UNAVAILABLE FIXTURE IS A FAILURE, NOT A SKIP. Written
    # `_sq_root="$(mktemp_d)" || _sq_root=""` with an `if` around it, a `TMPDIR`
    # that is full or read-only turned every case below into silence and the file
    # still reported PASS — a green tick over evidence nobody collected, which is
    # the shape this repository keeps deleting.
    # AND `die` DOES NOT TERMINATE — it prints and sets `fail=1`. So `|| die` here
    # left `_sq_root` EMPTY and carried on into `mkdir -p "$_sq_root/a"`, which is
    # `/a`, `/b` and `/bin` — and then wrote `/bin/mkdir`, which in a root CI
    # container overwrites the system one. The allocation terminates, as `TMP_CL`
    # above does, and the postcondition is checked rather than the status alone.
    _sq_root=""
    _sq_root="$(mktemp_d)" || {
        die "no scratch tree for the squat cases"
        echo "RESULT: FAIL"
        exit 1
    }
    { [ -n "$_sq_root" ] && [ -d "$_sq_root" ]; } || {
        die "the squat scratch tree was not created ('$_sq_root')"
        echo "RESULT: FAIL"
        exit 1
    }
    if [ -n "$setup_block" ]; then
        cat "$SCRIPT_DIR/identitylib.sh" \
            > "$SETUPTMP/plugin/skills/watch-prs/scripts/identitylib.sh"
        mkdir -p "$_sq_root/a" "$_sq_root/b" "$_sq_root/bin"
        # THE REAL `mkdir` IS CAPTURED BY PATH, not spelled. `/usr/bin/mkdir` is
        # not where every platform keeps it, and the mac-shaped job builds its own
        # PATH out of what stock macOS has.
        _sq_real=""; _sq_real="$(command -v mkdir)" || _sq_real=""
        if [ -n "$_sq_real" ]; then
            # THE REAL `mkdir` TRAVELS IN THE ENVIRONMENT, never interpolated into
            # this script. Written `exec $_sq_real "$@"` the path is emitted
            # unquoted, so a `PATH` entry carrying a space or a glob character
            # splits or expands and the stub cannot delegate — after which both
            # cases below test a broken fixture rather than setup.
            cat > "$_sq_root/bin/mkdir" <<'SQUAT'
#!/bin/sh
# NARROW, AND OTHERWISE WORKING: only a target under $SQUAT_PARENT is refused,
# and the diagnostic is the one a taken name produces. Everything else execs the
# real mkdir, so the rest of setup — the working directory included — is untouched.
for _a; do :; done
case "$_a" in
    "$SQUAT_PARENT"/*)
        # THE REFUSAL IS LOGGED, so a case can require that the first candidate was
        # actually ATTEMPTED. Without it, setup regressing to pick HOME directly —
        # never touching the squatted TMPDIR at all — produces the same remote and
        # the same working parent, and the recovery assertions pass with the retry
        # arm never run.
        [ -n "${SQUAT_LOG:-}" ] && echo "$_a" >> "$SQUAT_LOG"
        echo "mkdir: cannot create directory '$_a': File exists" >&2; exit 1 ;;
esac
[ -n "${SQUAT_REAL_MKDIR:-}" ] || {
    echo "squat stub: SQUAT_REAL_MKDIR is unset; refusing to guess" >&2
    exit 127
}
exec "$SQUAT_REAL_MKDIR" "$@"
SQUAT
            chmod +x "$_sq_root/bin/mkdir"
            # ONE PARENT SQUATTED: the retry recovers, and the session is pinned to
            # the REAL origin. This is the #161 retry doing the work #160 costs.
            _sq_rc=0; _sq_rc2=0
            _sq_out="$(cd "$SETUPTMP/repo" && run_limited 60 env \
                CLAUDE_PLUGIN_ROOT="$SETUPTMP/plugin" \
                TMPDIR="$_sq_root/a" HOME="$_sq_root/b" XDG_CONFIG_HOME="$_sq_root/b" \
                GIT_CONFIG_NOSYSTEM=1 SQUAT_PARENT="$_sq_root/a" \
                SQUAT_LOG="$_sq_root/refusals" SQUAT_REAL_MKDIR="$_sq_real" \
                PATH="$_sq_root/bin:$PATH" \
                bash -c 'eval "$1"
                         printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"' _ "$setup_block" 2>&1)" \
                || _sq_rc=$?
            # THE PROBE'S OWN STATUS FIRST. `run_limited`s portable fallback can
            # report a failure AFTER the markers were emitted, and a case that
            # reads the output without checking would call that successful
            # evidence. Requiring ZERO here excludes the watchdog's own 124 and 125
            # by construction; the both-squatted case below wants a non-zero status
            # and has to name them.
            [ "${_sq_rc:-0}" -eq 0 ] \
                || die "the one-parent squat probe failed (rc=$_sq_rc out='$_sq_out')"
            # AND THE FIRST CANDIDATE WAS ATTEMPTED. Setup regressing to choose
            # `HOME` directly gives the same remote and the same working parent
            # with the retry arm never run, so the recovery claim needs the stub
            # to have refused something under `a`.
            # COUNTED AS A LITERAL PREFIX. `grep -c "^$_sq_root/a/"` interpolates
            # the scratch path into a REGULAR EXPRESSION, so a `TMPDIR` carrying
            # `[`, `.` or `*` — `/tmp/build[1]` is a real shape — fails to match
            # the literal path the stub logged, and the case then reports that the
            # retry never ran. A quoted `case` pattern is literal by construction.
            _sq_tried=0
            if [ -f "$_sq_root/refusals" ]; then
                while IFS= read -r _sq_line; do
                    case "$_sq_line" in "$_sq_root/a/"*) _sq_tried=$((_sq_tried + 1)) ;; esac
                done < "$_sq_root/refusals"
            fi
            [ "${_sq_tried:-0}" -ge 1 ] \
                && pass "the squatted parent was attempted before the retry ($_sq_tried refusal(s))" \
                || die "no candidate under the squatted parent was attempted; the retry claim is unproved"
            case "$_sq_out" in
                *'PINNED=[git@github.com:acme/widget.git]'*)
                    pass "a squatter on the first candidate costs a retry, not the session" ;;
                *) die "a squat on one parent was not recovered from: '$_sq_out'" ;;
            esac
            # AND THE SESSION MOVED TO THE PARENT THAT WORKED, which is the half a
            # pin check alone cannot see: the working files are built from
            # `RB_TMPPARENT`, and a retry that read the origin under `HOME` while
            # leaving that name on the squatted `TMPDIR` dies one step later.
            case "$_sq_out" in
                *"SUMMARY_FILE=$_sq_root/b/"*)
                    pass "…and the parent that worked becomes the one the session uses" ;;
                *) die "the session kept the squatted parent for its working files: '$_sq_out'" ;;
            esac
            # BOTH PARENTS SQUATTED: setup REFUSES. Nothing is pinned and nothing
            # is forged — which is the whole severity claim for #160, and the
            # reason it is a denial of service rather than a compromise.
            _sq_out2="$(cd "$SETUPTMP/repo" && run_limited 60 env \
                CLAUDE_PLUGIN_ROOT="$SETUPTMP/plugin" \
                TMPDIR="$_sq_root/a" HOME="$_sq_root/b" XDG_CONFIG_HOME="$_sq_root/b" \
                GIT_CONFIG_NOSYSTEM=1 SQUAT_PARENT="$_sq_root" \
                SQUAT_REAL_MKDIR="$_sq_real" \
                PATH="$_sq_root/bin:$PATH" \
                bash -c 'eval "$1"
                         printf "PINNED=[%s]\n" "${REVIEW_BUS_REMOTE-}"' _ "$setup_block" 2>&1)" \
                || _sq_rc2=$?
            # ANY `PINNED=[` IS A CONTINUATION, not just one carrying an SSH
            # remote. The line after the block runs only if setup did NOT stop, so
            # its presence is the failure whatever it carries — an empty value, or
            # an HTTPS remote, which `rb_identity` accepts exactly as readily.
            case "$_sq_out2" in
                *'PINNED=['*) die "setup continued past the refusal with both parents squatted: '$_sq_out2'" ;;
                *) pass "…and a squatter on both parents stops the session rather than steering it" ;;
            esac
            # AND IT STOPPED NON-ZERO. A refusal that exits 0 is the state
            # `CLAUDE.md` records shipping twice: the caller cannot tell it from a
            # setup that finished.
            # NON-ZERO IS NOT ENOUGH: the watchdog reports 124 when it kills a
            # bounded command and 125 when its own setup or read fails, and either
            # satisfies a bare `-ne 0` while the markers above were replayed from a
            # capture. A broken probe would then read as evidence that setup
            # refused. Both are rejected by name, as the bounded probe further down
            # this file already does.
            { [ "${_sq_rc2:-0}" -ne 0 ] && [ "${_sq_rc2:-0}" -ne 124 ] \
              && [ "${_sq_rc2:-0}" -ne 125 ]; } \
                && pass "…reporting a failure rather than a diagnostic alone" \
                || die "the both-squatted run gave rc=$_sq_rc2, which is not a refusal (out='$_sq_out2')"
            # AND THE REASON IS NAMED BY THE SIDE THAT KNOWS IT. The driver cannot
            # tell a squatted name from a full filesystem — it handed over a name and
            # got a status — so its own line says only that each attempt above
            # carries its reason, and the helper's says which reason this was. Both
            # halves are asserted, because either alone is an operator looking in the
            # wrong place: the driver's line without the helper's is a refusal with
            # no cause, and the helper's without the driver's is a diagnostic from a
            # run that might have carried on.
            case "$_sq_out2" in
                *'PR_SETUP status=error reason=dir_not_reserved'*)
                    pass "…with the helper naming the reservation as the reason" ;;
                *) die "the both-squatted case did not reach the helper's refusal: '$_sq_out2'" ;;
            esac
            case "$_sq_out2" in
                *'each ABORT line above is one attempt and its reason'*)
                    pass "…and the driver refusing on the status it was given" ;;
                *) die "the both-squatted case did not reach the driver's refusal: '$_sq_out2'" ;;
            esac
            # AND NO VALUE WAS WRITTEN ANYWHERE UNDER EITHER PARENT, which is the
            # exclusion holding on this side of the call: a squatted name is
            # refused, so there is nothing for a later read to pick up.
            # THE SCAN'S STATUS IS TAKEN. `|| _sq_left=""` overwrote a failed
            # traversal with the answer the case wants, so a `find` that could not
            # read either tree reported that nothing survived.
            _sq_left=""; _sq_find_rc=0
            _sq_left="$(find "$_sq_root/a" "$_sq_root/b" \( -name origin -o -name pin \) 2>&1)" || _sq_find_rc=$?
            [ "$_sq_find_rc" -eq 0 ] \
                || die "the survivor scan failed (rc=$_sq_find_rc out='$_sq_left'); it proves nothing"
            [ -z "$_sq_left" ] \
                && pass "…and nothing was written through a name it did not take" \
                || die "a transport value survives a squatted run: '$_sq_left'"
        else
            echo "ok   - (mkdir is not on PATH; the squat cases did not run)"
        fi
        rm -rf "$_sq_root"
    fi
    rm -rf "$SETUPTMP"
fi

# ── the accepted merge-mode limitation is recorded on the base ref ────────
# AGENTS.md makes a dated decision record the only thing that can accept a
# limitation; a comment in the diff cannot.
if [ -d "$ROOT/docs/decisions" ]; then
    grep -rql 'REVIEW_MERGE_STRICT' "$ROOT/docs/decisions" >/dev/null 2>&1 \
        && pass "the merge-mode trade-off has a decision record" \
        || die "the --admin default is accepted nowhere a reviewer can weigh it"
    grep -rql 'transport candidate being published in argv is an accepted limit' \
        "$ROOT/docs/decisions" >/dev/null 2>&1 \
        && pass "the argv-publication limit has a decision record" \
        || die "#160 is accepted nowhere a reviewer can weigh it"
    grep -rql 'the reservation being an inference is an accepted limit' \
        "$ROOT/docs/decisions" >/dev/null 2>&1 \
        && pass "the reservation inference has a decision record" \
        || die "#162 is accepted nowhere a reviewer can weigh it"
    # AND THE TWO TRANSPORT RECORDS MUST NOT CONTRADICT EACH OTHER. The #160 one
    # was written while #162 was still unaccepted and said so; left that way, a
    # reviewer following it reaches the opposite verdict from one following the
    # #162 record, and both are base-ref authorities.
    grep -q 'reservation-inference' \
        "$ROOT/docs/decisions/2026-08-26-transport-candidate-in-argv.md" \
        && pass "the argv record points at the later reservation decision" \
        || die "the two decision records disagree about whether #162 is accepted"
    # ── EVERY ACCEPTED RECORD IS NAMED IN BOTH REVIEWER FILES ─────────────
    #
    # Codex reads the repository and can follow a pointer; Copilot reads only
    # `.github/copilot-instructions.md` and follows none, which is why that file
    # restates the policy inline. So an acceptance living in `docs/decisions/`
    # alone is invisible to one of the two required reviewers, and it can re-raise
    # what the operator already accepted. That is the doc-sync rule applied to a
    # waiver.
    #
    # DERIVED FROM THE DIRECTORY, NOT LISTED. A list of two went stale the moment
    # a third record was written — which is how the 2026-08-06 `--admin` waiver
    # sat unreferenced in both files for twenty days. #189.
    #
    # ACCEPTED ONES ONLY. A record whose status is superseded or rejected is
    # history rather than authority, and requiring a reviewer file to name it
    # would be requiring the opposite of what it says.
    # …AND THE `--admin` BOUNDS ARE SPELLED OUT FOR COPILOT, not deferred to the
    # record. Naming the file is enough for Codex, which reads the repository;
    # Copilot is configured from its own instructions and follows no pointers, so
    # a waiver that says "read that record" leaves it unable to notice that a
    # bound the waiver DEPENDS ON has been removed — and it would sign off a
    # newly unsafe `--admin` path. The bypass is waived; its bounds are not.
    # EVERY CONCRETE CONDITION, NOT FOUR BROAD LABELS. A loop over `40-hex`,
    # `match-head-commit`, `REVIEW_MERGE_STRICT` and `review-state probe` stayed
    # green while an edit removed the head re-read entirely, or reduced the
    # review-state probe to a phrase with no states in it, or dropped that strict
    # mode must be `=1` and EXPORTED — each of which leaves Copilot not knowing a
    # bound the waiver depends on, which is the regression this exists to stop.
    #
    # SEMANTIC TOKENS, NOT STYLISTIC ONES: each names a condition rather than a
    # turn of phrase, so rewording the prose around them does not fail the case
    # while removing the condition does.
    #
    # `re-read and compared immediately before merging` WAS ONE OF THESE AND IS
    # NOT ANY MORE, because the gate does not do it: the head is resolved ONCE and
    # the merge is pinned to that OID with `--match-head-commit`, which is what
    # makes the comparison atomic. Asserting a bound the code does not have taught
    # a reviewer to accept the waiver on the strength of a check that is not there.
    # The atomicity token below is the one that carries this.
    for _bd in 'full 40-hex SHA' \
               '7-character prefix' \
               'atomic with the merge' \
               'match-head-commit' \
               'review-state probe' \
               'all-checks gate is addressed by that head' \
               'required-checks gate is' \
               'addressed by it too' \
               'BASE BRANCH requires' \
               'protection cannot be' \
               'blocked' \
               'dismissed review' \
               'body-only' \
               'REVIEW_MERGE_STRICT=1' \
               'exported, not merely assigned' \
               'requires a merge queue' \
               'no merge-queue probe'; do
        grep -qF "$_bd" "$ROOT/.github/copilot-instructions.md" \
            && pass "copilot-instructions.md states the '$_bd' bound on the --admin waiver" \
            || die "the --admin bounds are deferred to a record Copilot cannot read: '$_bd' is missing"
    done
    # AND THE POST-MERGE CONFIRMATION, ASSERTED SEPARATELY BECAUSE IT IS NOT A
    # BOUND. It runs after `gh pr merge` has been issued, so it cannot justify the
    # bypass — but removing it is still a finding, because the driver then acts on
    # a merge that did not happen. Listing it with the bounds taught a reviewer to
    # count a reporting safeguard as a reason the merge was allowed.
    for _pm in 'NOT a bound' \
               'read back after the merge command' \
               'reported as queued rather than merged'; do
        grep -qF "$_pm" "$ROOT/.github/copilot-instructions.md" \
            && pass "…and states '$_pm' as a post-merge confirmation rather than a bound" \
            || die "the post-merge confirmation is missing from copilot-instructions.md: '$_pm'"
    done
    # …AND A PROBE THAT ERRORS IS NOT AN INACTIVE RECORD. `grep -q … || continue`
    # treats rc 2 — unreadable, vanished between the `-f` and the read — exactly
    # like rc 1, "this record is not accepted", so an accepted waiver nobody can
    # read is silently skipped and the contract reports success without checking
    # it. Only the ordinary no-match status continues; anything else fails.
    # ONE DECISION TABLE, USED BY THE SCAN AND BY THE CASES THAT PROVE IT. The
    # malformed-status cases used to re-implement the parse and the `case` arms,
    # so a regression in the real scanner left them green while a live waiver
    # dropped out of both reviewer-file checks — a copy of a rule proving the copy.
    #
    # STDERR IS DISCARDED, THE STATUS IS NOT: the caller names the file itself, so
    # grep's own complaint would only land in the middle of the suite's output.
    # THE NAME IS MATCHED LITERALLY, AND WHOLE. Two defects, one function.
    #
    # A derived basename is a BASIC REGULAR EXPRESSION to `grep`, so a record
    # legitimately named `2026-09-01-bash-3.2` is satisfied by the text
    # `bash-3x2`; `-F` is that half.
    #
    # And `-F` is a SUBSTRING search, which the path alone does not bound. With
    # `2026-09-01-bash-3.2` accepted, `docs/decisions/2026-09-01-bash-3.2.md` is
    # contained by `2026-09-01-bash-3.2-portability.md`, by
    # `old-docs/decisions/2026-09-01-bash-3.2.md`, and by that same path with a
    # `.bak` after it — none of which names the accepted record.
    #
    # SO THE MATCH CARRIES THE DELIMITERS THE PROSE USES. Both reviewer files
    # write these as inline code, and a backtick on each side is a real boundary:
    # nothing can precede the opening one inside a longer path, and nothing can
    # follow the closing one inside a longer filename. Matching the delimiter the
    # document actually uses is what ends this class, rather than a third guess at
    # where a path stops.
    _dr_named_in() {   # _dr_named_in <reviewer-file> <record-basename>
        grep -qF "\`docs/decisions/$2.md\`" "$1"
    }
    _dr_action() {   # _dr_action <file> ; prints require | skip | refuse
        local _l _rc=0 _st
        _l="$(grep -i '^\*\*Status:\*\*' "$1" 2>/dev/null)" || _rc=$?
        # rc 1 is "no such line", which is a malformed record; anything above it
        # is a read error, and both are refusals rather than silent skips.
        [ "$_rc" -le 1 ] || { printf refuse; return 0; }
        _st="${_l#*\*\*Status:\*\* }"
        _st="${_st%% *}"
        # LOWERCASED WITH `tr`, not `declare -l`: the mac-shaped job runs bash 3.2.
        #
        # THREE VALUES, AND THIS REPOSITORY USES ALL THREE. A fourth was carried
        # here uncovered, which is a table arm no case could have caught
        # regressing — anything not on this list is REFUSED, so a record reaching
        # for a new word fails loudly and somebody decides what it means.
        _st="$(printf '%s' "$_st" | tr '[:upper:]' '[:lower:]')"
        case "$_st" in
            accepted)             printf require ;;
            superseded|rejected)  printf skip ;;
            *)                    printf refuse ;;
        esac
        return 0
    }
    for _dr in "$ROOT"/docs/decisions/*.md; do
        [ -f "$_dr" ] || continue
        # THE SCAN ASKS THE TABLE. Nothing is parsed here, so the cases below
        # that prove the classification are proving THIS behaviour.
        case "$(_dr_action "$_dr")" in
            require) ;;
            skip)    continue ;;
            *) die "$(basename "$_dr") has no usable Status; a live waiver would be skipped as inactive"
               continue ;;
        esac
        _drn="$(basename "$_dr" .md)"
        for _wv in "$ROOT/AGENTS.md" "$ROOT/.github/copilot-instructions.md"; do
            _dr_named_in "$_wv" "$_drn" \
                && pass "$(basename "$_wv") names the $_drn waiver" \
                || die "$(basename "$_wv") does not name $_drn; that reviewer can re-raise an accepted limit"
        done
    done
    # …AND THAT DISTINCTION IS RUN, not merely written. A record whose status
    # cannot be read must fail the fixture rather than be skipped as inactive.
    #
    # SKIPPED BY NAME WHERE THE PROBE CAN READ IT ANYWAY: a run as root, or a
    # filesystem ignoring the mode, makes the unreadable file readable and the
    # case would assert nothing.
    # …AND THE TABLE IS EXERCISED, through the same function the scan calls.
    #
    # AN UNREADABLE RECORD IS A REFUSAL, not "not accepted". Skipped by name where
    # the probe can read it anyway — a root run, or a filesystem ignoring the
    # mode, would leave the case asserting nothing.
    _dr_un="$TMP_CL/unreadable-record.md"
    printf '# Decision: a probe\n\n**Status:** accepted\n' > "$_dr_un" 2>/dev/null
    chmod 000 "$_dr_un" 2>/dev/null || true
    if [ -f "$_dr_un" ] && ! grep -qi 'Status' "$_dr_un" 2>/dev/null; then
        [ "$(_dr_action "$_dr_un")" = refuse ] \
            && pass "…and an unreadable record is refused rather than treated as inactive" \
            || die "an unreadable record classified as '$(_dr_action "$_dr_un")'"
    else
        echo "ok   - (this run can read a mode-000 file; the unreadable-record case did not run)"
    fi
    chmod 644 "$_dr_un" 2>/dev/null || true
    rm -f "$_dr_un"
    # AND A MALFORMED STATUS IS REFUSED RATHER THAN SKIPPED, which is the shape
    # that matters: a status deleted, misspelled or reformatted must not pass for
    # `superseded` and take a live waiver out of the check with it.
    _dr_mal="$TMP_CL/malformed-record.md"
    for _dr_bad in '' '**Status:** acccepted' '**Status:** pending' '**Status:**'; do
        printf '# Decision: a probe\n\n%s\n' "$_dr_bad" > "$_dr_mal"
        [ "$(_dr_action "$_dr_mal")" = refuse ] \
            && pass "…and a record whose status is '${_dr_bad:-absent}' is refused, not skipped" \
            || die "the status '${_dr_bad:-absent}' classified as '$(_dr_action "$_dr_mal")'"
    done
    # …AND THE THREE LIVE VALUES CLASSIFY THE WAY THE SCAN NEEDS, so the refusals
    # above are not passing because the table refuses everything.
    for _dr_ok in 'accepted:require' 'Accepted:require' 'superseded:skip' 'rejected:skip' 'withdrawn:refuse'; do
        printf '# Decision: a probe\n\n**Status:** %s\n' "${_dr_ok%%:*}" > "$_dr_mal"
        [ "$(_dr_action "$_dr_mal")" = "${_dr_ok##*:}" ] \
            && pass "…and '${_dr_ok%%:*}' classifies as ${_dr_ok##*:}" \
            || die "'${_dr_ok%%:*}' classified as '$(_dr_action "$_dr_mal")', not ${_dr_ok##*:}"
    done
    rm -f "$_dr_mal"
    # …AND THE NAMING CHECK IS LITERAL, exercised through the same function the
    # scan calls. A metacharacter in a record's basename is legitimate — a bash
    # version in it is the obvious case — and as a regular expression it matches
    # text that does not name the record at all.
    _dr_nm="$TMP_CL/reviewer-probe.md"
    printf 'this file mentions `docs/decisions/2026-09-01-bash-3x2.md` and nothing else\n' > "$_dr_nm"
    _dr_named_in "$_dr_nm" '2026-09-01-bash-3.2' \
        && die "the naming check matched '2026-09-01-bash-3.2' against 'bash-3x2'; it is a regular expression" \
        || pass "…and a record name carrying a metacharacter is matched literally"
    # …AND A LONGER NAME DOES NOT ANSWER FOR A SHORTER ONE. `-F` is still a
    # SUBSTRING search, so without the `.md` the accepted `…-bash-3.2` record
    # reports as named by a file that mentions only `…-bash-3.2-portability`.
    printf 'this file names `docs/decisions/2026-09-01-bash-3.2-portability.md` only\n' > "$_dr_nm"
    _dr_named_in "$_dr_nm" '2026-09-01-bash-3.2' \
        && die "a longer record name satisfied the check for a shorter one; the match is a substring" \
        || pass "…and a longer record name does not answer for a shorter one"
    # …AND NEITHER SIDE OF THE PATH IS OPEN. Without the delimiters the prose
    # uses, a mention of a DIFFERENT directory or of a backup of the file contains
    # the searched string and answers for the record.
    for _dr_near in 'old-docs/decisions/2026-09-01-bash-3.2.md' \
                    'docs/decisions/2026-09-01-bash-3.2.md.bak'; do
        printf 'this file mentions `%s` and nothing else\n' "$_dr_near" > "$_dr_nm"
        _dr_named_in "$_dr_nm" '2026-09-01-bash-3.2' \
            && die "'$_dr_near' answered for the accepted record; the path is unbounded" \
            || pass "…and '$_dr_near' does not answer for it"
    done
    printf 'this file names `docs/decisions/2026-09-01-bash-3.2.md` properly\n' > "$_dr_nm"
    _dr_named_in "$_dr_nm" '2026-09-01-bash-3.2' \
        && pass "…while the record it does name is still found" \
        || die "the naming check missed a record the file names"
    rm -f "$_dr_nm"
else
    die "docs/decisions/ is missing; accepted limitations have nowhere to live"
fi

# ── the re-request id is captured and passed, not merely available ────────
# A flag nothing invokes is inert: `--after-review` shipped and the driver never
# called `review-id` nor passed the option, so a same-head re-request still
# accepted the previous terminal review immediately.
grep -q 'pr-watch.sh N "$WHO" --after-review "$PRIOR_REVIEW"' "$SKILL" \
    && pass "the watch is invoked with the pre-request review id" \
    || die "--after-review is documented but never passed"

grep -q 'ERRF' "$SCRIPT_DIR/pr-ci-state.sh" \
    && pass "…using stderr, so the message does not pollute the compared value" \
    || die "the checks probe does not capture stderr separately"

# ── a clean pass arrives as a comment, not a review ───────────────────────
# Codex submits a review only when it has findings, so `pulls/N/reviews` is empty
# on a clean head and the phase could never complete.
if [ -f "$SCRIPT_DIR/pr-review-state.sh" ]; then
    grep -q 'clean_comment_for_head' "$SCRIPT_DIR/pr-review-state.sh" \
        && pass "pr-review-state.sh reads the clean-pass comment channel" \
        || die "a clean Codex pass is invisible; the phase cannot complete"
    grep -q 'Reviewed commit:' "$SCRIPT_DIR/pr-review-state.sh" \
        && pass "…bound to the head the comment names" \
        || die "the clean comment is not bound to a commit"
fi

# ── the boundary gates the phase transitions, not only the re-request ─────
# A phase ending on the threshold-th head went from a clean verdict straight into
# the next phase — skipping the pause in exactly the case it exists for.
# TWO SITES LEFT IN THE DOCUMENT: step 6 and the resume recipe. The round-closing
# and phase-transition checks moved into `pr-close-round.sh` and
# `pr-copilot-phase.sh`, where both are EXECUTED — each has a case asserting the
# boundary pauses before anything irreversible happens.
[ "$(grep -c 'pr-round-count.sh N' "$SKILL")" -ge 2 ] \
    && pass "the round boundary is checked in the document's own steps too" \
    || die "a clean verdict on the boundary skips the operator pause"
grep -q 'before merging' "$SKILL" \
    && pass "…and before merging" \
    || die "the merge does not check the boundary"

# ── EVERY documented watch invocation carries the baseline ────────────────
# The shell example passed --after-review while the Monitor command beside it did
# not, leaving the feature inert in the mode Claude Code is told to use.
# The baseline is a VARIABLE now, not one name: the automatic path waits out the
# pass its own push started, and that wait's baseline is the id from before the
# push rather than the one for the request that follows. What must never happen is
# a watch with no baseline at all.
watch_calls="$(grep -c 'pr-watch.sh N "\$WHO"' "$SKILL")"
watch_pinned="$(grep -cE 'pr-watch.sh N "\$WHO" --after-review "\$[A-Z_]+"' "$SKILL")"
[ "$watch_calls" -eq "$watch_pinned" ] \
    && pass "every documented watch invocation passes a review baseline" \
    || die "$((watch_calls - watch_pinned)) watch invocation(s) omit --after-review"
# ── the operator instructions match the workflow ──────────────────────────
# README told operators that with automatic review on the summary must precede the
# push and that no mention may be sent, which is the opposite of what the driver
# does now. A settings page is the one place a user decides this, and a
# contradiction there is not a stale note — it is instructions that cannot be
# followed. `SKILL.md` and README are separate files with no mechanism keeping
# them in step, which is what this assertion is.
if [ -f "$ROOT/README.md" ]; then
    grep -q 'no mention may be sent' "$ROOT/README.md" \
        && die "README still says automatic mode sends no mention; the driver always does" \
        || pass "README does not contradict the automatic-mode ordering"
    grep -q 'two Codex passes' "$ROOT/README.md" \
        && pass "…and says what automatic review actually costs" \
        || die "README does not tell the operator that automatic mode costs a second pass"
fi

# ── the automatic path has no pre-request baseline ────────────────────────
# The trigger preceded the skill, so a lookup can capture the very pass being
# waited for — and the watch would reject the only terminal review as stale.
#
# THE RULE MOVED INTO `pr-request-review.sh` (#144, under #26), where
# `test-pr-request-review.sh` asserts the concrete outcome — an empty baseline
# AND no lookup at all — instead of matching an assignment. What is asserted here
# is that the driver did not keep a second copy: a `PRIOR_REVIEW=` of its own
# beside the capture would decide the question in the one place nothing executes,
# and the helper's answer would be overwritten by it.
grep -q 'PRIOR_REVIEW=""' "$SKILL" \
    && die "SKILL.md decides the automatic path's baseline itself; that rule lives in pr-request-review.sh, where the suite runs it" \
    || pass "the baseline is decided once, by the helper the suite runs"
grep -q 'the trigger preceded us' "$SKILL" \
    && pass "…and the driver says why that path has none" \
    || die "the driver does not record why the automatic path carries no baseline"

# ── the checks diagnostic is read with its status ─────────────────────────
# A `cat` that emitted text containing "no required checks" and then failed would
# be classified as the benign none-configured case, letting the default admin
# merge proceed with no trusted checks result at all.
grep -q 'MSG_RC' "$SCRIPT_DIR/pr-ci-state.sh" \
    && pass "the checks diagnostic read takes its own status" \
    || die "a failed diagnostic read can be classified as 'no required checks'"
grep -q 'reason=diagnostic_unreadable' "$SCRIPT_DIR/pr-ci-state.sh" \
    && pass "…and reports an error rather than a verdict" \
    || die "a failed diagnostic read does not block"

# ── automatic mode asks EXPLICITLY, whatever the push did ─────────────────
# A round that ends without a new commit — a dismissal, or a finding answered
# rather than coded around — leaves the push a no-op, so nothing is queued and
# `--after-review` rejects the old record forever. That used to be handled by
# comparing three heads and asking only when they matched, which is a condition
# that can be got wrong; and it became insufficient anyway once the push moved
# ahead of the summary, because the pass a moving push starts now reads open
# threads and no summary. An unconditional ask covers both, and there is no
# condition left to invert.
#
# The CONDITION is what is asserted, not the presence of a mention: a mention
# inside a branch is not an unconditional ask, and the branch is exactly what was
# removed.
# ── the fetched heads are validated, not merely fetched ───────────────────
# An rc-0 call yielding empty or `null` makes every unchanged-head comparison
# false, so automatic mode assumes the no-op push queued a review.
# NO `PRIOR_HEAD` AT ALL. It existed to decide whether the push had moved
# anything, so a mention could be sent only when it had not; the request is
# unconditional now and nothing reads it. Left in place it is a `gh pr view` whose
# transient failure aborts a step before any context is posted — a call that can
# only cost. The assertion is that there are ZERO assignments, because "one is
# still validated" is what a half-finished removal looks like.
[ "$(grep -c '^PRIOR_HEAD=' "$SKILL")" -eq 0 ] \
    && pass "the obsolete head baseline is gone, not merely unused" \
    || die "a PRIOR_HEAD baseline is still fetched and can abort a step for nothing"
# ── THE SUMMARY IS POSTED ONCE, AND THAT IS EXECUTED TOO ───────────────────
# The automatic path once posted the summary standalone AND again inside the
# `@codex review` mention, leaving two identical round-summary comments — and the
# contract makes the NEWEST summary the one read before the diff, so a duplicate is
# a record with two answers to the same question. `test-pr-close-round.sh` asserts
# it from the call log: a Codex round makes exactly one comment carrying the
# mention, a Copilot round exactly one comment plus `--add-reviewer`.

# ── THE BOUNDARY-BEFORE-REQUEST ORDER IS EXECUTED, NOT READ ────────────────
# `in_range` and the OFF/ON span walk existed to ask, of two recipes in a
# document, whether the round count came before every way a review can start.
# `pr-close-round.sh` answers that by running: the boundary check precedes the
# push in push mode — where the push IS the request — and precedes the comment in
# mention mode, and both orderings are asserted from the call log.

# ── AND SO IS THE PUSH LANDING ON THIS PR ──────────────────────────────────
# A successful `git push` from the wrong worktree leaves the PR head untouched,
# and the local head then matches nothing that was queued. The executed case
# drives exactly that: the API keeps reporting the previous head, the retries run
# out, and the round stops rather than closing.

# …against the SHA it pushed, not a fresh read of mutable local HEAD. A checkout
# reset after the push would otherwise satisfy the comparison with a commit that
# never reached the PR.
awk '/^if \[ "\$HEAD_BEFORE" != "\$HEAD_AFTER" \]; then$/ {inb=1}
     inb && /^fi$/ {inb=0}
     inb && /git rev-parse HEAD/ {print "bad"; exit}' "$SKILL" | grep -q bad \
    && die "the push confirmation re-reads mutable local HEAD" \
    || pass "…comparing against the pushed SHA rather than re-reading HEAD"

# ── a hostless origin is refused, not defaulted to GitHub ─────────────────
grep -q 'origin_has_no_host' "$SCRIPT_DIR/identitylib.sh" \
    && pass "an origin with no network authority is refused" \
    || die "a local-path origin would be treated as github.com"
# THE RE-DRIFT GUARD. Four copies of this parser is what issue #18 was about, and
# nothing stops a later edit writing the rules back into the driver "for clarity"
# — at which point the two disagree silently, which is how both the hostless and
# the file-transport rules came to exist in some copies and not others.
grep -qE 'refusing to guess one|origin_transport_unsupported' "$SKILL" \
    && die "SKILL.md has grown its own copy of the origin parser again" \
    || pass "…and the driver carries no second copy of the rule"

# ── the helper selection takes its pipeline status ────────────────────────
# `head` can emit a plausible path and then fail; if that directory holds
# executables the validation below passes and every gate runs helpers chosen by a
# failed read. Asserted on the guard, not on the abort message — the message
# survives the defect.
grep -q 'RB_CANDIDATES" | head -1)" \\' "$SKILL" \
    && pass "the helper selection branches on its pipeline status" \
    || die "the helper selection pipeline status is unchecked"

# ── the reviewers review; they do not implement ────────────────────────────
# Ignoring this is not a no-op: a summary mentioning an unfixed defect was read
# as a work order, and the run edited files and committed from an environment
# with no remote — so the commit existed nowhere and no review was produced.
for f in "$ROOT/AGENTS.md" "$ROOT/.github/copilot-instructions.md"; do
    [ -f "$f" ] || continue
    grep -qi 'You do not implement' "$f" \
        && pass "$(basename "$f") states that the reviewer never writes code" \
        || die "$(basename "$f") does not forbid the reviewer from implementing"
done

# ── v2 ships to Claude Code only ───────────────────────────────────────────
# Both reviewers run in GitHub's cloud, so nothing is installed for them; the
# driver needs a watch tool, which is why there is one manifest and not two.
[ -e "$ROOT/.codex-plugin" ] \
    && die "the Codex plugin manifest is back; v2 ships to Claude Code only" \
    || pass "no Codex plugin manifest"
[ -e "$ROOT/.agents" ] \
    && die "the Codex marketplace metadata is back" \
    || pass "no Codex marketplace metadata"
if [ -f "$ROOT/README.md" ]; then
    grep -q 'codex plugin' "$ROOT/README.md" \
        && die "README still documents installing this plugin into Codex" \
        || pass "README does not document a Codex install"
fi


# THE README AND THE GATE MUST AGREE ABOUT COPILOT. This assertion used to demand
# the words "required, not optional", because the gate demanded a clean verdict
# from both reviewers and there was no way around it — a user installing for a
# repository without Copilot would have found out at merge time that the loop
# could not finish.
#
# THAT CHANGED, and the assertion changes with it rather than being deleted: the
# gate now supports `codex-only`, chosen at the stop that closes the Codex phase.
# What must still be true is that the README describes the SAME arrangement the
# gate implements — that codex-only is a decision rather than a switch, and that
# it is narrower rather than looser, because a reader who believes otherwise will
# reach for it to get around a review.
if [ -f "$SCRIPT_DIR/../../../README.md" ]; then
    README="$SCRIPT_DIR/../../../README.md"
    grep -qi 'codex-only' "$README" \
        && pass "README documents the Codex-only merge the gate supports" \
        || die "README contradicts the gate: it knows nothing of codex-only"
    grep -qiE 'narrower|not looser' "$README" \
        && pass "…and says it is narrower rather than a way around a reviewer" \
        || die "README presents codex-only as a skip switch"
    grep -qi 'no switch for is skipping a reviewer' "$README" \
        && pass "…while still ruling out skipping a reviewer silently" \
        || die "README no longer rules out a silent skip"
fi



# ── WHY THERE IS NO MARKDOWN PARSER, AND NO LIFTED FRAGMENT, HERE ──────────
#
# A sweep that extracted every fenced block and `bash -n`'d it was built and
# deleted: reaching the code meant parsing Markdown, and four review rounds went
# to fence spellings — two of whose defects rejected valid source (#25).
#
# What replaced it was narrower: two anchored `grep`s lifted the head-state
# condition out of `SKILL.md` and executed it, because that condition was the one
# bash 3.2 could not parse. THAT IS GONE TOO, and for the better reason: the
# condition is no longer in `SKILL.md`. It moved into `pr-merge-gate.sh` with the
# rest of the merge decision, where the suite runs it directly and forty-two cases
# in `test-pr-merge-gate.sh` drive it. Lifting shell out of a document is a
# workaround for the shell being in a document; #26 is the fix.

# ── portability: no GNU-only tools on the path that must work on macOS ─────
# Comment lines are excluded on purpose: the skill EXPLAINS why `sort -V` is not
# used, and matching that explanation would make the assertion unfalsifiable.
# THE READ'S STATUS IS TAKEN, and this one failed OPEN without it: an unreadable
# `$SKILL` yields no lines, the search finds no `sort -V`, and the assertion reports
# the skill portable on a file it never read.
_nocomment=""
_nocomment="$(grep -vE '^[[:space:]]*#' "$SKILL")" \
    || die "could not read the skill to check it for GNU-only tools"
if grep -q 'sort -V' <<<"$_nocomment"; then
    die "skill uses GNU-only 'sort -V' while README advertises portability"
else
    pass "no GNU-only sort in the script-resolution fallback"
fi

# ── THE RESUME RECIPE'S OWN DECISIONS ARE TESTED IN `test-pr-phase-state.sh` ──
#
# Ten assertions used to live here, and six of them worked by LIFTING two branch
# headers out of the document and executing them with trivial bodies under
# shadowed builtins — because a fenced block cannot be run, and that was the
# closest thing to running it available. Twenty-two cases now execute the helper
# against stubbed signoffs, verdicts and heads: both arms, the malformed-sha arm,
# the stale-Copilot selection, every unreadable status, and the two dismissals.
# That is a strictly stronger claim, and it is why these are gone rather than
# retargeted at the script. Issues #123 and #26.
#
# WHAT STAYS HERE IS THE WIRING: that the driver ASKS, and that it distinguishes
# the three answers the helper can give. A resumed session that read `2` as `1`
# would treat "could not tell" as "no signoff" and re-run a phase that is closed.
resume_blk="$(awk '/^### Resuming after a stop$/ {sec=1}
                   sec && /^```bash$/ {inb=1; next}
                   inb && /^```$/ {exit}
                   inb' "$SKILL")"
[ -n "$resume_blk" ] || die "the resume recipe could not be extracted"
grep -qF 'pr-phase-state.sh N' <<<"$resume_blk" \
    && pass "the resume recipe reads the phase off the PR through pr-phase-state.sh" \
    || die "the resume recipe does not call pr-phase-state.sh"
# NO STATUS VARIABLE HOLDS THE ANSWER, and that is not a style point. Written as
# `if …; then RC=0; else RC=$?; fi` with a `case "$RC"` after it, a startup file
# that had already made that name readonly with the value 0 made BOTH assignments
# fail while leaving it at 0 — and a helper that returned 1 or 2 was sent through
# the continuation into the merge flow. `CLAUDE.md` records that a failed
# assignment does not even fire an `||`, so there is no status to take: the answer
# is to have no variable, and this asserts the absence rather than a guard.
case "$resume_blk" in
    *PHASE_RC*) die "the resume recipe holds the phase status in a variable, which a readonly pre-seed defeats" ;;
    *) pass "…with no status variable between the helper and the decision" ;;
esac
# THE THREE ANSWERS, EACH ITS OWN BRANCH: the `then` continues, and the `else`
# reads the condition's `$?` into a `case` that tells 1 from anything else. A
# `case` with only the first arm would fall through to the continue.
_ph_else="$(printf '%s' "$resume_blk" | awk '/^else$/{f=1; next} /^fi$/{if(f)exit} f')"
{ grep -qF 'case $? in' <<<"$_ph_else" \
    && grep -qE '^ *1\)' <<<"$_ph_else" \
    && grep -qE '^ *\*\)' <<<"$_ph_else"; } \
    && pass "…and tells stopped from unreadable where the status is produced" \
    || die "the resume recipe does not distinguish the phase helper's refusals: '$_ph_else'"

# ── REOPENING A PHASE REVOKES ITS SIGNOFF FIRST ────────────────────────────
# Entering the Copilot phase a second time — after a Codex pass that came back
# clean without moving the head — leaves the previous Copilot signoff naming that
# same head. Until the new pass reports, GitHub still exposes the old clean
# verdict, so a resumed or concurrent session takes the post-Copilot path and
# merges the phase that was just reopened.
awk '/--add-reviewer @copilot/ {print NR": "$0}' "$SKILL" | head -1 >/dev/null

# ── THE CODEX-ONLY PATH REACHES THE GATE ───────────────────────────────────
# The gate supports the mode; the DOCUMENTED PATH to it did not. Step 8 opened
# with a Copilot recheck that runs unconditionally, and in codex-only there is no
# Copilot review for it to find — so the driver exited before the gate it had just
# been taught to call.
#
# THE SKIP IS THE SCRIPT'S NOW (#78), and `test-pr-copilot-phase.sh` runs it: the
# `codex-only` case there asserts nothing is posted and no Copilot verdict is
# re-checked. What has to hold HERE is that the driver still passes the mode
# through — a call that hard-coded `both`, or dropped the argument, would take the
# script's default and reach the recheck that cannot pass, with the fixture none
# the wiser because it calls the script directly.
rb_close_call_present \
    && pass "the reviewers mode is passed to the close stage" \
    || die "codex-only is not passed through; the driver would take the two-reviewer path"

# ── THE PHASE TRANSITIONS ARE THE OPERATOR'S, NOT THE LOOP'S ───────────────
#
# A loop that decides for itself how much review a change is worth will always
# decide "more": it has no view of urgency, cost, or what the change is for. Both
# transitions therefore stop and ask — after Codex is clean, and after Copilot is.
# The failure this prevents is not a wrong merge; it is a session that quietly
# spends another phase of somebody's attention because continuing was the
# direction it happened to be facing.
grep -q 'STOP — the next phase is the operator' "$SKILL" \
    && pass "a clean Codex verdict stops for the operator rather than opening the Copilot phase" \
    || die "the driver opens the Copilot phase on its own"
grep -q 'MERGING IS THE OPERATOR' "$SKILL" \
    && pass "…and a clean Copilot verdict stops before the merge gate" \
    || die "the driver walks a clean Copilot verdict straight into a merge"
# THE OTHER HALF OF THAT STOP MOVED (#78). `pr-copilot-phase.sh close` prints the
# menu and `test-pr-copilot-phase.sh` reads it — both branches, and the whitelist
# of option lines. What stays the driver's is the instruction not to run the gate
# on its own: the script stopping means nothing if the prose around the call sends
# the driver straight on to the gate anyway.
grep -qF 'do not run the merge gate until the operator has answered' <<<"$skill_flat" \
    && pass "…and the driver is told not to run the gate until it is answered" \
    || die "SKILL.md does not tell the driver to wait for the operator after the close"
# …ON THE TWO-REVIEWER PATH ONLY. In `codex-only` no Copilot review was ever
# requested, so `close` records nothing and prints NO menu — and the decision this
# stop collects was already taken at the Codex stop, where "merge now on Codex's
# signoff alone" is what selected the mode. An unconditional stop leaves that flow
# waiting for an answer to a question nobody was asked, which is the same
# dead-letter shape as the codex-only merge option that could not be taken.
grep -qF 'In `codex-only` there is no second question' <<<"$skill_flat" \
    && pass "…and codex-only is exempted from it by name" \
    || die "the post-close stop is unconditional; codex-only waits for a menu that was never printed"
grep -qF 'Go straight to the merge gate' <<<"$skill_flat" \
    && pass "…and is sent to the gate instead" \
    || die "codex-only is exempted from the stop without being told where to go"
# BOTH OPTIONS ARE NAMED AT EACH STOP. "Decide with the operator" without naming
# the choices is a notification: the operator has to reconstruct what the
# alternatives even were.
awk '/STOP — the next phase is the operator/ {c=1} c {print} c && /^```bash$/ {exit}' "$SKILL" \
    | grep -q 'merge now' \
    && pass "…naming merging as an alternative to the Copilot phase" \
    || die "the Codex-clean stop does not offer merging"
# …AND THAT OFFER IS REACHABLE. The gate required a clean COPILOT record on the
# head, so "merge on Codex's signoff alone" was a menu item that could never be
# chosen. The mode has to be named where it is offered AND passed where the gate
# is run, or the offer is a dead letter again.
awk '/STOP — the next phase is the operator/ {c=1} c {print} c && /^```bash$/ {exit}' "$SKILL" \
    | grep -q 'codex-only' \
    && pass "…and names the mode that makes it reachable" \
    || die "the Codex-only offer does not say how to take it"
# THE MENU ITSELF IS `pr-copilot-phase.sh close`'s, and asserting it here as well
# would be the second copy CLAUDE.md § Tests forbids — one that drifts, because
# only one of the two is executed. `test-pr-copilot-phase.sh` covers what it
# offers on an unchanged head and on a moved one, that the moved-head menu names
# the revocation, that it reports the two signed heads separately rather than as
# one, and that it says the delta check has not run yet.
#
# WHAT THIS FILE KEEPS is the sha the driver hands over, because the script cannot
# check it: `close` decides which of the two menus to print by comparing the head
# it reads against the Codex sha it is GIVEN. A driver passing the current head
# instead would make every phase look unchanged, the fault-tolerance pass would
# never be offered, and the fixture would still be green.
rb_close_call_present \
    && pass "…and the close is given the Codex-signed head to compare against" \
    || die "the close stage is not given \$CODEX_SHA; it cannot tell a moved head from an unchanged one"
# THE SIGNOFF IS RECORDED BEFORE EITHER STOP, which is what makes the stop
# resumable rather than a dead end. A decision that arrives tomorrow must not cost
# the phase that was already finished.
# ONE IN THE DOCUMENT — the Copilot phase's. The Codex one is composed by
# `pr-copilot-phase.sh`, in the form `pr-signoff.sh` scans for, and
# `test-pr-copilot-phase.sh` asserts that form against what was actually posted.
[ "$(grep -c '\*\*Review-Signoff:\*\*' "$SKILL")" -ge 1 ] \
    && grep -qF '**Review-Signoff:** `%s` `%s`' "$SCRIPT_DIR/pr-copilot-phase.sh" \
    && pass "both phases record their signoff on the PR before stopping" \
    || die "a phase closes without writing down which head it closed on"
[ -x "$SCRIPT_DIR/pr-signoff.sh" ] \
    && grep -q 'pr-signoff.sh' "$SKILL" \
    && pass "…and the driver knows how to read one back in a later session" \
    || die "nothing reads the recorded signoff back"

# ── THE CHECK-IN OFFERS STARTING OVER ──────────────────────────────────────
# Ten rounds is evidence about the APPROACH, not only about the defects left. The
# option a loop will never propose for itself is abandoning its own work, and it
# is the one this repository has the strongest evidence for: fifty-two rounds on a
# text scanner, then eleven on the thing that replaced it.
grep -qi 'start over with a better approach' "$SKILL" \
    && pass "the round check-in offers closing the PR and starting over" \
    || die "the check-in never raises the approach itself as the problem"
# EVERY PLACE THAT ANNOUNCES A BOUNDARY OFFERS IT, wherever that place now lives.
# Two of these messages moved into `pr-close-round.sh` with the recipes they
# belonged to, so counting only the document would have passed while the scripts
# said nothing about starting over — the assertion has to follow the code.
# THREE QUOTED ARGUMENTS, not one string split on whitespace. A checkout path
# containing a space — `/tmp/watch pr` — split every name into fragments that do
# not exist; the first `grep` then failed into `continue` for all of them, and this
# reported that every boundary message was checked while checking none. A
# mandatory pre-push gate that passes vacuously is worse than one that is absent.
bnd_missing=""
for _f in "$SKILL" "$SCRIPT_DIR/pr-close-round.sh" "$SCRIPT_DIR/pr-merge-gate.sh"; do
    [ -f "$_f" ] || { bnd_missing="$bnd_missing $(basename "$_f")(missing)"; continue; }
    grep -q 'round boundary reached' "$_f" || continue
    grep -q 'start over' "$_f" || bnd_missing="$bnd_missing $(basename "$_f")"
done
[ -z "$bnd_missing" ] \
    && pass "…and every file that announces a boundary offers starting over" \
    || die "a boundary message omits the start-over option:$bnd_missing"

# ── THE DRIVER CALLS THE GATE, AND READS ALL THREE ANSWERS ─────────────────
# The gate's own decisions are executed in `test-pr-merge-gate.sh`. What has to be
# true HERE is that the document invokes it with what it needs and does not
# collapse its three outcomes into two — a pause read as a refusal loses the
# operator's decision, and a refusal read as a pause invites a blind retry.
[ -x "$SCRIPT_DIR/pr-merge-gate.sh" ] \
    && grep -q 'pr-merge-gate.sh N ' "$SKILL" \
    && pass "the driver invokes the merge gate" \
    || die "nothing in the driver reaches the merge gate"
# AUTO-REVIEW IS PASSED, and as an argument. Read from the environment it would be
# invisible to the child unless exported, and it decides whether an in-flight Codex
# pass may be ignored — a silent default there is a merge on a verdict nobody read.
grep -q 'pr-merge-gate.sh N "\$CODEX_SHA" "\$AUTO_REVIEW"' "$SKILL" \
    && pass "…passing the auto-review setting as an argument" \
    || die "the merge gate is not told whether auto-review is on"
# …AND THE SHA REACHES IT AS A VARIABLE, not as a placeholder in argument
# position. `<…>` there is a redirection: `<full` opens a file and every later
# word shifts into the wrong parameter, so a driver that did not substitute it
# would run the gate with the wrong arguments rather than failing. The placeholder
# belongs on the assignment above the call.
# ── THE MERGE BLOCK PARSES, WHICH IS NOT WHAT A GREP CAN TELL YOU ──────────
#
# This assertion replaces two greps about WHERE a `<…>` placeholder sat. Both were
# reasoning about tokenisation from the outside and both were wrong: `<` opens a
# redirection in argument position AND after an `=`, so an unsubstituted
# placeholder never reaches the validation it was supposed to reach — the block
# fails to parse instead. `bash -n` settles it.
#
# `$CODEX_SHA` is captured and validated in step 7; there is nothing here for the
# driver to fill in, and the block must be runnable as written.
# THE BLOCK THAT RUNS THE GATE, not simply the first one under the heading.
# Step 8 opens with a block that records the Copilot signoff and stops for the
# operator; taking "the first fenced block after the heading" silently switched
# targets the moment that was added, and every assertion below then described a
# different piece of code.
merge_blk="$(awk '/^## 8\. Merge gate$/ {sec=1}
                  sec && /^```bash$/ {inb=1; buf=""; next}
                  inb && /^```$/ {inb=0; if (buf ~ /pr-merge-gate\.sh/) {printf "%s", buf; exit}; next}
                  inb {buf = buf $0 "\n"}' "$SKILL")"
[ -n "$merge_blk" ] || die "the merge-gate block could not be extracted"
if [ -n "$merge_blk" ]; then
    blk_err="$(printf '%s\n' "$merge_blk" | bash -n 2>&1)" \
        && pass "the merge-gate block parses as written, with nothing to substitute" \
        || die "the merge-gate block does not parse ($blk_err)"
fi
# …AND IT USES THE SHA THE SESSION ALREADY HAS, rather than asking for one again.
grep -q 'pr-merge-gate.sh N "\$CODEX_SHA" "\$AUTO_REVIEW"' <<<"$merge_blk" \
    && pass "…passing the sha captured when the Codex phase closed" \
    || die "the merge gate is not given the validated Codex sha"
# …AND WHICH REVIEWERS THIS MERGE RESTS ON. The stop above offers merging on the
# Codex signoff alone; without this argument that offer is a menu item the gate
# rejects, because it demands a clean Copilot record on the head regardless.
#
# ASSERTED WHERE `merge_blk` EXISTS. Written higher up the file it ran against an
# unset variable — `-u` was not in force for it, so it silently compared nothing
# and reported the gate untold.
# AND THE SIGNATURE LINE MATCHES THE CALL. The usage comment said three arguments
# while the call passed four, so a driver reading the signature alone would have
# left `pr-merge-gate.sh` on its default reviewers mode rather than the one the
# operator chose at the Codex stop. #197.
grep -qF 'pr-merge-gate.sh <pr> <codex-sha> <auto-review: yes|no> <reviewers: both|codex-only>' "$SKILL" \
    && pass "…and the documented signature names the reviewers argument the call passes" \
    || die "SKILL.md's merge-gate usage line does not name every argument the call passes"
grep -q 'pr-merge-gate.sh N "\$CODEX_SHA" "\$AUTO_REVIEW" "\$REVIEWERS"' <<<"$merge_blk" \
    && pass "…which the gate is actually told" \
    || die "the merge gate is never told which reviewers this merge rests on"
# …AND THE GATE'S STATUS LEAVES THE BLOCK. Every arm of the dispatch ends in an
# `echo`, whose status is 0, so a block that just falls off the end reports success
# for a merge that was blocked, paused or queued — and whatever runs it next
# carries on as though the PR had landed. EXECUTED rather than grepped: the block
# is run with a stub gate that returns each status, and the block's own status is
# what is asserted.
mg_stub="$(mktemp_d)" || { die "no scratch directory for the merge-block probe"; mg_stub=""; }
[ -n "$mg_stub" ] && for mg_rc in 0 1 3 4; do
    printf '#!/usr/bin/env bash\nexit %s\n' "$mg_rc" > "$mg_stub/pr-merge-gate.sh"
    chmod +x "$mg_stub/pr-merge-gate.sh"
    # THE STATUS IS CAPTURED AT THE POINT IT IS PRODUCED. This file runs under
    # `-e`, and three of these four probes are EXPECTED to fail — that is the
    # assertion — so an unguarded assignment ends the suite on the first one
    # instead of reporting anything.
    mg_got=0
    mg_out="$(cd "$mg_stub" && run_limited 20 env \
        bash -c 'RB_SCRIPTS="$1"; REPO_DIR="$2"; CODEX_SHA=x; AUTO_REVIEW=no
                 eval "$3" >/dev/null 2>&1' _ "$mg_stub" "$mg_stub" "$merge_blk" 2>&1)" || mg_got=$?
    [ "$mg_got" -eq "$mg_rc" ] \
        && pass "the merge block reports the gate's own status ($mg_rc)" \
        || die "the merge block turned gate status $mg_rc into $mg_got ('$mg_out')"
done
[ -n "$mg_stub" ] && rm -rf "$mg_stub"
# ANCHORED TO THE `MERGE_RC` DISPATCH ITSELF. A bare `3)` matches three unrelated
# arms elsewhere in this document — the round-count checks — so the assertion
# passed with the merge gate's pause arm deleted, and the driver would have
# collapsed an operator decision into its generic refusal branch while the suite
# stayed green.
merge_case="$(awk '/^case "\$MERGE_RC" in/ {c=1} c {print} c && /^esac/ {exit}' "$SKILL")"
{ [ -n "$merge_case" ] && grep -qE '^[[:space:]]*3\)' <<<"$merge_case"; } \
    && pass "…and the round-boundary pause is distinguished from a refusal" \
    || die "the driver does not tell a merge-gate pause from a block"
# …AND A QUEUED MERGE FROM A COMPLETED ONE. `gh pr merge` reports success for
# ADDING a PR to a merge queue, and the PR can leave that queue without landing.
# Treating rc 4 as success ends the session with the head not on the base branch.
{ [ -n "$merge_case" ] && grep -qE '^[[:space:]]*4\)' <<<"$merge_case"; } \
    && pass "…and a queued merge is not read as a completed one" \
    || die "the driver treats a queued merge as merged"
# THE GATE RUNS IN THE REPOSITORY THIS SESSION STARTED IN. It derives identity and
# the range-check root from the current directory, so a `cd` into another checkout
# between setup and the merge would point every gate — and the admin merge — at
# whatever PR of THAT repository shares this number.
grep -q 'cd "\$REPO_DIR" && /usr/bin/env bash -p "\$RB_SCRIPTS"/pr-merge-gate.sh' "$SKILL" \
    && pass "…and the gate is invoked from the captured repository root" \
    || die "a cd between setup and the merge would repoint every gate"

# ── thread pagination ──────────────────────────────────────────────────────
# A truncated thread list reads exactly like a shorter review. `SKILL.md` fetches
# threads in ONE place now — step 4, where findings are read — because the merge
# gate's own walk went into `pr-merge-gate.sh`, where a cursor cycle, a malformed
# `hasNextPage` and a partial response are each an executed case.
[ "$(grep -c 'hasNextPage' "$SKILL")" -ge 1 ] \
    && pass "the thread fetch that remains in the document is paginated" \
    || die "a thread fetch is not paginated"

# ── the instruction files carry the scope + issue policy ───────────────────
# These are what reach the reviewers; the loop depends on them, so a missing
# clause is a behaviour change, not a doc nit.
for doc in "$ROOT/AGENTS.md" "$ROOT/.github/copilot-instructions.md"; do
    name="$(basename "$(dirname "$doc")")/$(basename "$doc")"
    [ -f "$doc" ] || { die "$name is missing"; continue; }
    grep -qi 'set out to do' "$doc" \
        && pass "$name: reviewers judge the PR against its stated goal" \
        || die "$name: no scope rule"
    grep -qi 'untrusted context' "$doc" \
        && pass "$name: PR narrative is untrusted" \
        || die "$name: does not mark the PR narrative untrusted"
    grep -qi 'issue' "$doc" \
        && pass "$name: out-of-scope problems can be filed as issues" \
        || die "$name: no issue-filing route for out-of-scope problems"
    grep -qi 'review body' "$doc" \
        && pass "$name: names the non-blocking channel" \
        || die "$name: does not name the review body as the non-blocking channel"
    grep -qi 'fail-closed\|fail closed' "$doc" \
        && pass "$name: fail-closed is a review criterion" \
        || die "$name: does not state the fail-closed criterion"
    grep -qi 'hard-code' "$doc" \
        && pass "$name: the repo-agnostic invariant is a blocking finding" \
        || die "$name: does not tell the reviewer to block a hard-coded identity"
    grep -qi 'base ref\|base-ref' "$doc" \
        && pass "$name: only a base-ref authority waives a finding" \
        || die "$name: no waiver authority rule"
    # A reviewer that installs dependencies and runs the suite turns a
    # three-minute read into a twenty-minute one, and the author is blocked on it
    # either way. The instruction files are the only lever on that.
    grep -qi 'do not set up an environment' "$doc" \
        && pass "$name: the review is read-only (no env setup, no test runs)" \
        || die "$name: does not tell the reviewer to review statically"
    grep -qi 'run the test suite' "$doc" \
        && pass "$name: running the suite is ruled out explicitly" \
        || die "$name: does not rule out running the tests"
    # ── THE PORTABILITY CLASSES CI CANNOT SEE ──────────────────────────────
    #
    # The `macos-shell` job covers absent commands and post-3.2 constructs by
    # running the suite, which #93 restored it to doing. It is still a reviewer's
    # job to read for them, because a workflow can be turned off — the operator
    # disabled `tests` outright while this loop was being worked on — and a class
    # nobody is assigned is a class nobody checks. Three more stay invisible to
    # that job even when it runs, and the ONLY thing assigning them
    # to a reviewer is this table. Copilot reads its own copy and
    # follows no pointers, so an edit that weakens either file silently restores
    # the gap — and every check above would stay green, because none of them looks
    # at this.
    #
    # THE EXCEPTIONS ARE ASSERTED TOO, and that is not symmetry for its own sake:
    # a table that says "report `\b`" without saying "except in awk, where it is
    # backspace" produces BLOCKING FALSE FINDINGS, which cost the author a round
    # each and teach the reviewer to distrust the rule.
    while IFS='|' read -r pat what; do
        [ -n "$pat" ] || continue
        grep -qi "$pat" "$doc" \
            && pass "$name: $what" \
            || die "$name: $what — no line matching '$pat'"
    done <<'PORTCLASSES'
sed -i|GNU-only flags are the reviewer's, not CI's
readlink -f|…and the flag list names the ones that have reached this tree
matches a literal|the silent half of the escape rule is stated: BSD grep does not fail on it
oniguruma|jq's engine is exempt, so a jq program is not a false finding
backspace|awk's backslash-b is backspace, not a word boundary
builtin|echo -e is the Bash builtin here, not the external command
guarded|a command-v-guarded use with a fallback is correct
branch the suite never executes|the unexecuted-branch gap is stated as a gap
PORTCLASSES
done

# ── the phase summary is written by a QUOTED heredoc ───────────────────────
# `SKILL.md` is executed by the driver verbatim, so an unquoted heredoc around
# prose is a live substitution site: the summary body is composed from the round
# and routinely contains Markdown code spans holding shell text, including text
# copied out of an untrusted PR description or a reviewer comment. The assertion
# is structural rather than on the abort message, because a message survives the
# defect it names.
hd="$(grep -n 'cat >>\{0,1\} "\$SUMMARY_FILE" <<' "$SKILL" || true)"
if [ -z "$hd" ]; then
    die "no summary heredoc found in SKILL.md — has the recipe moved?"
else
    bad="$(grep -v "<<'EOF'" <<<"$hd" || true)"
    [ -z "$bad" ] \
        && pass "every summary heredoc is quoted, so prose is written, not executed" \
        || die "an unquoted summary heredoc executes the prose it writes: $bad"
fi
# …and the one value it needs still reaches the file, or the quoting silently
# turned the SHA into the literal text $CODEX_SHA in every summary. The two parts
# are matched separately because the printf and its argument are on separate
# continued lines, and a single-line pattern would fail on correct code.

# ── the required-checks payload is shape-checked before `all` ──────────────
# `all(.[]; …)` over an empty stream is `true`, so an object, a null, or an empty
# array from a SUCCESSFUL read came out as "every required check passed" and the
# default administrator merge proceeded on a payload nothing had read.
grep -q 'if type != "array" or length == 0 then "malformed"' "$SCRIPT_DIR/pr-ci-state.sh" \
    && pass 'the checks payload must be a non-empty array before all() runs' \
    || die 'the checks jq computes all() without validating its container'
grep -q 'any(.\[\]; type != "object" or (.bucket | type) != "string")' "$SCRIPT_DIR/pr-ci-state.sh" \
    && pass "…and each element must actually carry a bucket string" \
    || die "the checks jq does not validate the bucket records"

# ── EVERY CLAIM HAS ITS ARGUMENT, AND EVERY ARGUMENT ITS CLAIM ─────────────
#
# The lifted blocks' argument lives in `SKILL-RATIONALE.md` beside them — one
# section per claim, tokens that used to be read on every invocation of a skill
# whose reader needs the COMMANDS. What stayed beside the code is the CLAIM: one
# complete line, then a `# WHY:` naming the document.
#
# NO COUNT IS GIVEN HERE. A block lands per pull request, and a number written
# into this comment is one that goes stale on the next one — the totals the
# checks below compare are read from the two files.
#
# THE SEPARATION IS THE RISK, AND THIS IS WHAT PAYS FOR IT. `CLAUDE.md` records
# that a comment arguing against the code beside it is an instruction and will be
# followed; moving the argument away from the code weakens exactly that. A claim
# whose argument has gone leaves the next session deleting a shape for looking
# gratuitous.
#
# SO WHAT IS CHECKED IS THE BIJECTION, by exact string comparison and nothing
# else: every claim beside the code has a section, every section has a claim,
# neither side repeats, and the totals agree. The rationale's own Markdown shape
# is NOT checked — see the note further down for what that gives up and why two
# answers to it were removed rather than extended.
# THE CHECK IS A FUNCTION SO A STAGED PAIR CAN BE PUT THROUGH THE REAL ONE. It
# takes the two paths and nothing else; the caller below runs it on the shipped
# files, and then on a staged rationale carrying the shapes this deliberately no
# longer rejects. Both go through the same code, which is the only way the second
# run says anything about the first.
_wy_contract() {
local SKILL="$1"
local _wy_doc="$2"
local _wy_all _wy_all_rc _wy_bad_ptr _wy_bp_rc _wy_stale _wy_st_rc
local _wy_claims _wy_rc _wy_n _wy_sent_rc _wy_float _wy_heads _wy_hrc
local _wy_empty _wy_e_rc _wy_cdupe _wy_cd_rc _wy_hdupe _wy_h _wy_heads_n _wy_bad _wy_c
if [ -f "$_wy_doc" ]; then
    # 1. EVERY MENTION, however malformed — the denominator nothing may shrink
    #    silently — and every one well formed, inside a bash fence, under a claim,
    #    and annotating code. One equality closes a filename typo, a stray
    #    character, a pointer outside every fence, and a pointer under code.
    _wy_all=0; _wy_all_rc=0
    _wy_all="$(grep -c '# WHY:' "$SKILL")" || _wy_all_rc=$?
    [ "$_wy_all_rc" -le 1 ] || die "SKILL.md could not be scanned for pointers (rc=$_wy_all_rc)"
    [ "$_wy_all" -gt 0 ] \
        && pass "the lifted blocks point at their rationale ($_wy_all pointers)" \
        || die "no # WHY: pointers in SKILL.md; the rationale is unreachable from the code"

    # THE POINTER NAMES THE INSTALLED PLUGIN, not a path relative to wherever the
    # driver happens to be standing — the shell stays in the project under review
    # — and not `$CLAUDE_PLUGIN_ROOT`, which is UNSET in setup's second discovery
    # mode. `RB_SCRIPTS` is set and validated in both.
    _wy_bad_ptr=0; _wy_bp_rc=0
    _wy_bad_ptr="$(grep -c '# WHY: \(docs/\|\$CLAUDE_PLUGIN_ROOT\)' "$SKILL")" || _wy_bp_rc=$?
    [ "$_wy_bp_rc" -le 1 ] || die "SKILL.md could not be scanned for unresolvable pointers (rc=$_wy_bp_rc)"
    [ "$_wy_bad_ptr" -eq 0 ] \
        && pass "…and none resolves from the working directory or an unset plugin root" \
        || die "$_wy_bad_ptr pointers are unresolvable in one of setup's two discovery modes"

    # 2. THE CLAIMS, from the bash fences, each paired with the pointer beneath it.
    #    The status is taken: fed straight into a comparison, a failed `awk` yields
    #    nothing and every check below passes vacuously.
    #
    #    EVERY FENCE, NOT ONE NAMED SECTION. This was restricted to `## Derive
    #    identity` while that was the only block whose argument had been lifted,
    #    and the restriction was doing nothing the count below does not: a pointer
    #    outside every fence is already caught, because `_wy_all` counts the whole
    #    file and this counts only what a fence contains. Naming the sections here
    #    would mean editing this awk for each block that lands, which is a list
    #    that goes one entry stale exactly when someone forgets it.
    _wy_claims=""; _wy_rc=0
    #
    #    INDENTED FENCES COUNT. Two of this document's bash blocks sit inside list
    #    items, and a column-anchored scan does not see them — so a claim in one
    #    was refused: `_wy_all` counts the whole file and this counted only the
    #    fences at column zero, and the totals could not agree. That was
    #    fail-closed rather than blind, which is why it surfaced the moment #224
    #    put a claim in the round check-in block, but it made those two blocks the
    #    only ones that could carry no argument at all.
    _wy_claims="$(awk '/^[[:space:]]*```bash$/ && !f {f=1; prev=""; next}
       f && /^[[:space:]]*```$/{f=0; next}
       f { if ($0 ~ /^[[:space:]]*# WHY: \$RB_SCRIPTS\/\.\.\/SKILL-RATIONALE\.md$/) {
               if (prev ~ /^[[:space:]]*#/) { c=prev; sub(/^[[:space:]]*#[[:space:]]?/, "", c); print c }
               else print "!!POINTER-NOT-UNDER-A-CLAIM!!" }
           prev=$0 }' "$SKILL")" || _wy_rc=$?
    [ "$_wy_rc" -eq 0 ] \
        || die "the claim list could not be built (rc=$_wy_rc); pointer rot would go unchecked"
    _wy_n=0; _wy_n="$(grep -c . <<<"$_wy_claims")" || _wy_n=0
    [ "$_wy_n" -eq "$_wy_all" ] \
        && pass "…and all $_wy_all sit under a claim, inside a bash fence, in the documented form" \
        || die "$((_wy_all - _wy_n)) of $_wy_all # WHY: lines are malformed, outside every bash fence, or not under a claim"
    _wy_sent_rc=0
    grep -qF '!!POINTER-NOT-UNDER-A-CLAIM!!' <<<"$_wy_claims" || _wy_sent_rc=$?
    case "$_wy_sent_rc" in
        0) die "a # WHY: pointer follows code rather than the claim it belongs to" ;;
        1) pass "…each directly under the claim it belongs to" ;;
        *) die "the claim list could not be scanned for the sentinel (rc=$_wy_sent_rc)" ;;
    esac

    # …AND EVERY PAIR HAS CODE AFTER IT, before its fence closes. Not IMMEDIATELY
    # after it, which is what this asked until #198 — and that stricter rule was
    # the thing forcing claims to be MERGED. A claim sitting above a helper's usage
    # table has code below the table and none on the next line, so it could carry
    # no pointer; the only way to give it one was to fold it into the neighbouring
    # claim, and folding lost a clause three times in three pull requests. The
    # rationale kept the argument each time, so the bijection stayed green over
    # exactly the drift it exists to catch.
    #
    # SO THE DEPENDENCY IS REMOVED RATHER THAN GUARDED. Pairs may STACK above one
    # code line, and a usage table may sit between a pair and the code it belongs
    # to. One claim per invariant is then always available, and nothing has to be
    # merged to be pointed at.
    #
    # WHAT IS STILL CAUGHT is the pair that annotates nothing at all: one with no
    # code anywhere after it before the fence ends. What is NOT caught is a pair
    # moved from one code line to another — the pair is intact and still annotates
    # code, it is annotating the wrong code. Catching that means the fixture
    # knowing which line each claim belongs to, which couples the contract to the
    # block's shape, and every legitimate refactor would then fail it. A relocated
    # claim is visible in the diff as code losing its annotation; a contract that
    # breaks on every refactor is not. Found once that way, in review, which is the
    # disposition this assumes.
    _wy_float=0
    #
    # THE CLOSING LINE IS TESTED ON `prev` AS WELL AS ON `pend`, and that is not
    # belt and braces. The fence-close rule runs BEFORE the body rule that sets
    # `pend`, so a pair whose pointer is the LAST line of the fence never sets it —
    # which is the most obvious way to write a pair that annotates nothing, and the
    # first version of this check passed against exactly that.
    #
    # INDENTED FENCES HERE TOO, for the reason the claim scan above takes them: two
    # of this document's blocks sit inside list items, and a column-anchored scan
    # would let a pair at the END of one satisfy the bijection while annotating
    # nothing — the pair is counted there and floats here.
    _wy_float="$(awk '/^[[:space:]]*```bash$/ && !f {f=1; prev=""; pend=0; next}
       f && /^[[:space:]]*```$/{ if (pend || prev ~ /# WHY: \$RB_SCRIPTS/) n++
                     f=0; prev=""; pend=0; next }
       f { if (prev ~ /# WHY: \$RB_SCRIPTS/) pend=1
           if (pend && $0 !~ /^[[:space:]]*#/ && NF > 0) pend=0
           prev=$0 }
       END{ if (pend || prev ~ /# WHY: \$RB_SCRIPTS/) n++; print n+0 }' "$SKILL")" || _wy_float=99
    [ "$_wy_float" -eq 0 ] \
        && pass "…and every claim and pointer has code after it before its fence closes" \
        || die "$_wy_float claim/pointer pairs annotate nothing; no code follows them in their fence"

    # 3. THE HEADINGS, by exact prefix and nothing else: every `## ` line in the
    #    rationale is taken as a claim, and the failure says how to satisfy it.
    #
    # WHAT THE RATIONALE'S OWN SHAPE IS NOT CHECKED FOR, AND WHY IT STOPPED BEING.
    #
    # The heading list below comes from `grep '^## '`, and Markdown can make that
    # lie: a comment or a fence hides a section, a setext underline makes one this
    # cannot match, an indented `## ` is a heading at column three, and `## ` alone
    # is a heading with no text. Each was caught in review here, and each was
    # answered — first with a parser, then with five greps forbidding the forms.
    #
    # BOTH ANSWERS GREW WITHOUT CONVERGING. The parser needed fenced code, tilde
    # fences, indented fences, info strings, HTML comments and their ordering; the
    # greps then needed HTML blocks, indented headings, a second title, and a hash
    # run that is not a heading at all. Twelve rounds, and the next construct was
    # always one round away. `CLAUDE.md` records the shape and the 2,200-line
    # scanner it cost this repository once already.
    #
    # SO IT IS NOT CHECKED, ON THE OPERATOR'S INSTRUCTION, and what remains is the
    # BIJECTION: every claim beside the code has a section, every section has a
    # claim, neither side repeats, and the totals agree. All exact string
    # comparison, no grammar anywhere.
    #
    # WHAT THAT GIVES UP: a rationale edited so that a heading is hidden or faked.
    # That is a person mangling a document — visible in the diff as the mangling
    # it is — and it is not the rot the separation risks, which is a claim and its
    # argument drifting apart. Every one of those forms was found by a reviewer
    # READING the file, which is the disposition this now assumes.


    _wy_heads=""; _wy_hrc=0
    _wy_heads="$(grep '^## ' "$_wy_doc" | sed 's/^## //')" || _wy_hrc=$?
    { [ "$_wy_hrc" -eq 0 ] && [ -n "$_wy_heads" ]; } \
        || die "the rationale's headings could not be read (rc=$_wy_hrc); an orphaned section would pass"

    # …AND NO SECTION IS EMPTY. The bijection compares HEADINGS, so a section whose
    #    argument is deleted while its heading stays passes every check above: the
    #    claim still has a section, the section still has a claim, and the totals
    #    still agree. That is the one way an argument can vanish without the
    #    contract seeing it, and it costs one `awk` with no grammar in it — a
    #    heading followed by nothing but blank lines before the next heading.
    #
    #    IT DOES NOT ASK WHETHER THE ARGUMENT IS STILL COMPLETE. A section that
    #    loses a paragraph, or a claim that loses a clause, reads as well-formed to
    #    anything mechanical; that is #198's settled answer and it is stated in the
    #    rationale's own preamble. This catches the wholesale case only, and says
    #    so rather than implying more.
    _wy_empty=""; _wy_e_rc=0
    _wy_empty="$(awk '/^## /{ if (h != "" && body == 0) print h; h=substr($0,4); body=0; next }
       h != "" && NF > 0 { body=1 }
       END{ if (h != "" && body == 0) print h }' "$_wy_doc")" || _wy_e_rc=$?
    { [ "$_wy_e_rc" -eq 0 ] && [ -z "$_wy_empty" ]; } \
        && pass "…and no section is a heading with no argument under it" \
        || die "these sections have no argument under them (rc=$_wy_e_rc): $_wy_empty"

    # 4. BIJECTION. No claim twice, no heading twice, every claim a heading, every
    #    heading a claim, and the totals equal. Five string comparisons.
    _wy_cdupe=""; _wy_cd_rc=0
    _wy_cdupe="$(sort <<<"$_wy_claims" | uniq -d)" || _wy_cd_rc=$?
    { [ "$_wy_cd_rc" -eq 0 ] && [ -z "$_wy_cdupe" ]; } \
        && pass "…and no claim is made at two sites, so the mapping is one to one" \
        || die "a claim is made at two sites (rc=$_wy_cd_rc): '$_wy_cdupe'; a relocation between them would be invisible"
    _wy_hdupe=""; _wy_hdupe="$(sort <<<"$_wy_heads" | uniq -d)" || _wy_hdupe="THE_SCAN_FAILED"
    [ -z "$_wy_hdupe" ] \
        && pass "…and no two sections carry the same claim" \
        || die "two sections carry the same claim, so one is unreachable: '$_wy_hdupe'"
    while IFS= read -r _wy_h; do
        [ -n "$_wy_h" ] || continue
        grep -qxF "$_wy_h" <<<"$_wy_claims" \
            || die "the rationale has a '## ' line that no claim matches: '$_wy_h'. Every one must be a claim; indent a transcript line by four spaces so it is not a heading."
    done <<EOWH
$_wy_heads
EOWH
    pass "…and every '## ' line in the rationale is one of them"
    _wy_heads_n=0; _wy_heads_n="$(grep -c . <<<"$_wy_heads")" || _wy_heads_n=0
    [ "$_wy_all" -eq "$_wy_heads_n" ] \
        && pass "…and the $_wy_all claims in SKILL.md match the rationale's $_wy_heads_n arguments" \
        || die "$_wy_all claims against $_wy_heads_n arguments; one was added or dropped without the other"
    _wy_bad=0
    while IFS= read -r _wy_c; do
        [ -n "$_wy_c" ] || continue
        grep -qxF "## $_wy_c" "$_wy_doc" \
            || { die "no section for the claim '$_wy_c'; it is asserted beside the code and argued nowhere"
                 _wy_bad=$((_wy_bad + 1)); }
    done <<EOWY
$_wy_claims
EOWY
    [ "$_wy_bad" -eq 0 ] \
        && pass "…so every claim beside the code has its argument" \
        || die "$_wy_bad claims have no section"
else
    die "SKILL-RATIONALE.md is missing from beside SKILL.md; the argument has nowhere to live"
fi
}

_wy_contract "$SKILL" "$SCRIPT_DIR/../SKILL-RATIONALE.md"

# ── AND THE TREE AROUND THE PAIR ─────────────────────────────────────────────
# These two ask about the CHECKOUT rather than about the two files handed in, so
# they run once, outside the function. Inside it they ran again on the staged
# pair — where they say nothing new, and where a failure reported itself as "a
# rationale-shape guard has come back", which is a diagnosis of the wrong thing.
[ -f "$SCRIPT_DIR/../SKILL-RATIONALE.md" ] \
    && pass "the rationale is where \$RB_SCRIPTS/.. puts it, beside SKILL.md" \
    || die "there is no SKILL-RATIONALE.md beside SKILL.md; the pointers name nothing"

# …AND NO LAYER STILL NAMES EITHER OLD PATH. The document has been moved twice
# — out of `docs/`, and then renamed once a second block's argument landed in
# it and `SETUP-` stopped being true — and each move leaves pointers behind in
# documents nothing executes. Through `git grep`, whose status is the one this
# needs: 0 found, 1 not found, above that an error. `git ls-files | xargs grep`
# reports 123 on the ordinary no-match, and `grep -r` over the tree reaches
# untracked scratch.
#
# `CHANGELOG.md` IS EXCLUDED, and only it. A changelog records what a release
# shipped, and 2.0.67 shipped a file under the old name; rewriting that entry
# to match today's tree would make the record say something that was never
# true. Nothing follows a changelog to find a file, which is what this check
# is for.
_wy_stale=""; _wy_st_rc=0
_wy_stale="$(git -C "$ROOT" grep -lE 'docs/skill-setup-rationale|SETUP-RATIONALE' \
    -- '*.md' ':!CHANGELOG.md' 2>/dev/null)" || _wy_st_rc=$?
[ "$_wy_st_rc" -le 1 ] \
    || die "the checkout's documents could not be scanned for the old paths (rc=$_wy_st_rc)"
[ -z "$_wy_stale" ] \
    && pass "…and nothing still names a path the document has been moved off" \
    || die "these name a path the rationale no longer has: $_wy_stale"


# ── THE OPEN STAGE'S ORDERING IS NAMED BESIDE THE CALL ───────────────────────
# The lift moved block 7's arguments into the rationale, which a driver reaches
# only by following a pointer. This one decides WHICH review the request waits
# for: with the Copilot baseline taken before the request, a pass landing in
# between is accepted as the answer to a request made after it. `open` enforces
# the order, and the claim beside the call is what stops a later session
# reordering the stage without reading why it is that way — so the ordering is
# in the claim rather than only behind the pointer.
#
# ONE ANCHORED SUBSTRING, no grammar. It asks whether the four steps are named
# in that order on a line of `SKILL.md`, which is what the finding asked to pin;
# it does not parse the block, and `CLAUDE.md` is explicit that a scanner is what
# this contract must not grow.
grep -qF 'revoke, prove, baseline, request' "$SKILL" \
    && pass "the open stage's ordering is named beside the call, not only in the rationale" \
    || die "block 7 no longer names the revoke/prove/baseline/request order; a reordering would read as ordinary"

# ── AND THE TWO PLACEMENT BRANCHES ARE STAGED, ACCEPT AND REJECT ─────────────
#
# `_wy_contract` ran on the shipped pair and on the accepted-shapes rationale, and
# both of those PASS — so every branch that REFUSES was unexercised. Measured: the
# relaxed placement check shipped with its fence-close arm reading only the flag
# the body rule sets, which the close line never reaches, and a pair whose pointer
# was the last line of its fence passed. Deleting either half again, or breaking
# the empty-section scan, would have left this file green.
#
# SYNTHETIC PAIRS, NOT COPIES OF THE SHIPPED ONES. Each case is a four-line skill
# and a two-line rationale, so what it asserts is visible in the case itself rather
# than depending on what block 8 happens to look like this month. `_wy_contract`
# is the real one; nothing here re-implements a check.
_wy_ptr='# WHY: $RB_SCRIPTS/../SKILL-RATIONALE.md'
_wy_case() {   # <label> <expect: pass|fail> <skill-body> <doc-body> [indent]
    local _c_label="$1" _c_expect="$2" _c_skill="$3" _c_doc="$4" _c_dir _c_out
    _c_dir="$(mktemp_d)" || { die "no scratch directory for the '$_c_label' case"; return 0; }
    # AN INDENTED FENCE IS STAGEABLE, because two of this document's blocks are
    # inside list items and both scans have to reach them. Without this every case
    # here is a column-zero fence, so the indentation handling in the two awks
    # would be uncovered — and a pair at the end of an indented fence would satisfy
    # the bijection while annotating nothing.
    if [ -n "${5:-}" ]; then
        { printf '## S\n\n- a list item:\n\n  ```bash\n'
          printf '%s\n' "$_c_skill" | sed 's/^/  /'
          printf '  ```\n'; } > "$_c_dir/SKILL.md"
    else
        printf '## S\n\n```bash\n%s\n```\n' "$_c_skill" > "$_c_dir/SKILL.md"
    fi
    printf '%s\n' "$_c_doc" > "$_c_dir/doc.md"
    _c_out="$(_wy_contract "$_c_dir/SKILL.md" "$_c_dir/doc.md" 2>&1)" \
        || _c_out="FAIL - the case run ended non-zero: $_c_out"
    case "$_c_out" in
        *"FAIL - "*) [ "$_c_expect" = fail ] \
                        && pass "…and $_c_label is refused" \
                        || die "$_c_label was refused and should not be: $_c_out" ;;
        *)           [ "$_c_expect" = pass ] \
                        && pass "…and $_c_label is accepted" \
                        || die "$_c_label was accepted and should not be" ;;
    esac
    rm -rf "$_c_dir"
}

# ACCEPTED — the two shapes the old rule forbade, which is why it forced merging.
_wy_case "two claims stacked above one line of code" pass \
"# CLAIM ONE.
$_wy_ptr
# CLAIM TWO.
$_wy_ptr
x=1" \
"## CLAIM ONE.

first argument

## CLAIM TWO.

second argument"

_wy_case "a usage table between a pair and its code" pass \
"# CLAIM ONE.
$_wy_ptr
#   helper.sh <pr>
#     0  fine
x=1" \
"## CLAIM ONE.

first argument"

# REFUSED — a pair that annotates nothing, by each of the two routes into it. The
# second is the one the first version of the relaxed check passed.
_wy_case "a pointer followed only by comments before the fence closes" fail \
"# CLAIM ONE.
$_wy_ptr
# a trailing note, and no code after it" \
"## CLAIM ONE.

first argument"

_wy_case "a pointer that is the last line of its fence" fail \
"x=1
# CLAIM ONE.
$_wy_ptr" \
"## CLAIM ONE.

first argument"

# REFUSED IN AN INDENTED FENCE TOO, which is where the two scans could disagree:
# the claim scan counts a pair inside one, so the float scan has to see the same
# fence or a pair at its end annotates nothing and still balances.
_wy_case "a pointer that is the last line of an INDENTED fence" fail \
"x=1
# CLAIM ONE.
$_wy_ptr" \
"## CLAIM ONE.

first argument" indented
# …AND ACCEPTED THERE WHEN CODE FOLLOWS IT, so the case above is refusing the
# floating pair rather than the indentation.
_wy_case "a pair inside an INDENTED fence with code after it" pass \
"# CLAIM ONE.
$_wy_ptr
x=1" \
"## CLAIM ONE.

first argument" indented

# REFUSED — a heading whose argument was deleted while the heading stayed. TWICE,
# because the scan has two arms and the two are reached by different documents: the
# `END` arm fires on the LAST section, and the heading-transition arm on any
# earlier one. Staging only the last section left the transition arm unexercised,
# so a non-final argument could have vanished with every case still green.
_wy_case "a section that is a heading with nothing under it, at the end" fail \
"# CLAIM ONE.
$_wy_ptr
x=1" \
"## CLAIM ONE."

_wy_case "an empty section followed by another heading" fail \
"# CLAIM ONE.
$_wy_ptr
# CLAIM TWO.
$_wy_ptr
x=1" \
"## CLAIM ONE.

## CLAIM TWO.

second argument"

# ── AND THE REMOVAL ITSELF IS PINNED, so it cannot be undone by accident ──────
#
# The guards above were removed on the operator's instruction, and a removal has
# no witness: the shipped rationale carries none of the forms they rejected, so
# re-adding any one of them would leave this file green while the decision above
# had been reversed.
#
# So a STAGED rationale carries all five, and the contract must ACCEPT it. It is
# the shipped document plus an HTML comment, a heading indented to column three,
# a setext-underlined heading, a bare `##` and a fenced block — chosen because
# none of them changes what `grep '^## '` matches, so the bijection is untouched
# and the only thing that can reject this pair is a guard that came back.
#
# THE FENCE IS THE EMPTY-OF-HEADINGS KIND, and that distinction is the whole of
# why it is here. A fence carrying a column-zero `## example` needs no guard:
# `grep` DOES match it, so it becomes one more heading with no claim and the
# bijection rejects it unaided — staging that one would assert the opposite. A
# fence with no such line inside changes nothing the bijection can see, so the
# deleted delimiter guard is the only thing that ever rejected it, and without it
# staged the guard could come back green.
#
# The staged run's own `ok` lines are captured rather than printed — it is one
# assertion, not a second copy of the suite — and `die` sets a flag rather than
# exiting, so what is looked for is a `FAIL - ` line in what it wrote.
_wy_stage=""
_wy_stage="$(mktemp_d)" || { die "no scratch directory for the staged-rationale probe"; _wy_stage=""; }
if [ -n "$_wy_stage" ]; then
cp "$SKILL" "$_wy_stage/SKILL.md" || die "the staged skill could not be written"
cp "$SCRIPT_DIR/../SKILL-RATIONALE.md" "$_wy_stage/doc.md" \
    || die "the staged rationale could not be written"
cat >>"$_wy_stage/doc.md" <<'EOSTAGE'

<!-- an HTML comment, which one removed guard rejected outright -->

  ## a heading at column three, which `^## ` does not match

A setext heading, which has no hash run at all
---

##

```text
a fenced transcript, whose delimiter one removed guard rejected; nothing in
it begins a line with a hash, so `^## ` matches exactly what it did before
```
EOSTAGE
_wy_staged=""
_wy_staged="$(_wy_contract "$_wy_stage/SKILL.md" "$_wy_stage/doc.md" 2>&1)" \
    || _wy_staged="FAIL - the staged run ended non-zero: $_wy_staged"
case "$_wy_staged" in
    *"FAIL - "*) die "a rationale-shape guard has come back; the staged pair was rejected: $_wy_staged" ;;
    *)           pass "…and a rationale using the accepted shapes still passes, so the removal holds" ;;
esac
# …and the tree is given back. Safe unquoted-free only because `mktemp_d` is the
# definition of a path that was actually created, and the `if` above is what
# stops this running on an empty one.
rm -rf "$_wy_stage"
fi

# ── the identity parser rejects transports that reach no GitHub server ─────
# The rule is `identitylib.sh`'s and `test-identitylib.sh` executes it. What is
# asserted here is that the DRIVER's own documentation says so, because a reader
# who does not know the refusal exists writes a remote the parser will reject and
# has nothing to read about why.
#
# IN THE RATIONALE DOCUMENT, NOT IN `SKILL.md`. That argument moved out of the
# setup block with the rest of that block's `# WHY:` material; the assertion moved
# with it rather than being dropped, which is the coupling this file is here to
# keep honest.
grep -q 'ssh://\*|git://\*|https://\*|http://\*|git+ssh://\*' "$SCRIPT_DIR/identitylib.sh" \
    && pass "the identity parser accepts only GitHub network transports" \
    || die "the parser reads any URL scheme as a GitHub identity"
grep -q 'reaches no GitHub server' "$SCRIPT_DIR/../SKILL-RATIONALE.md" \
    && pass "…and refuses the rest rather than guessing a host" \
    || die "the rationale has no rejection path for an unsupported transport"

# ── acknowledging a check-in takes the gate's status, and names the reviewer ─
# The acknowledgement is the one place the driver records the OPERATOR's
# permission. Reading it out of a pipeline hid the helper's status: a run that
# printed a plausible pause line and then died some other way still yielded
# digits, `sed` still succeeded, and permission was recorded from an unreadable
# probe. And the count is per reviewer, so an unscoped footer acknowledging 41
# Codex rounds is read by a Copilot invocation with 5, trips its ahead-of-count
# guard and blocks that phase for good.
grep -qF 'if [[ $ROUNDS_RC == 3 ]]; then' "$SKILL" \
    && pass "the acknowledgement requires the gate's distinguished pause status" \
    || die "the driver acknowledges a check-in without checking the gate exited 3"
grep -q 'Review-Pause-Acknowledged:\*\* `%s` `%s`' "$SKILL" \
    && pass "the acknowledgement footer names the reviewer and the count" \
    || die "the acknowledgement footer is unscoped and will cross between phases"

# ── THE ACKNOWLEDGEMENT, LIFTED AND RUN ────────────────────────────────────
# The three greps above are ABOUT this block and cannot execute it, which is what
# #222 was: `grep -q 'ROUNDS_RC" -eq 3'` passes against
# `[ "$ROUNDS_RC" -eq 3 ] || true`, and against a version whose parse succeeds on a
# body from a probe that died. The block posts a MUTATION recording the operator's
# permission to continue past a check-in, and its own comment says permission must
# never be inferred from unreadable output — so it is the one place in this file
# where a described-but-unexecuted check is worth the most.
_rb_ack=""
_rb_ack="$(mktemp_d)" || _rb_ack=""
{ [ -n "$_rb_ack" ] && [ -d "$_rb_ack" ]; } \
    || die "no scratch directory for the acknowledgement cases; the block was never run"
if [ -n "$_rb_ack" ] && [ -d "$_rb_ack" ]; then
mkdir -p "$_rb_ack/bin" "$_rb_ack/scripts" "$_rb_ack/sedbin" "$_rb_ack/sedfail"
# LIFTED WITH ITS OWN INDENT STRIPPED. It sits inside step 6's `3` bullet, two
# spaces in, and the cases below set their own state at column 0.
awk '/^  ROUNDS_OUT="\$\(/,/^  fi$/' "$SKILL" | sed 's/^  //' > "$_rb_ack/ack.sh"
# THE EXCERPT HAS TO CONTAIN ALL THREE PARTS, or the cases prove nothing. A range
# that stopped early would leave a lift that never posts, and every "did not post"
# case below would pass against it.
_rb_ack_src="$(cat "$_rb_ack/ack.sh")"
case "$_rb_ack_src" in
    *'if [[ $ROUNDS_RC == 3 ]]; then'*) ;;
    *) die "the lifted acknowledgement has no status proof; the cases below prove nothing" ;;
esac
case "$_rb_ack_src" in
    *'sed -n'*) ;;
    *) die "the lifted acknowledgement has no parse; the cases below prove nothing" ;;
esac
case "$_rb_ack_src" in
    *'gh pr comment N'*) ;;
    *) die "the lifted acknowledgement does not reach the post; every case below would pass" ;;
esac
pass "the round check-in acknowledgement lifts out whole"
# THE HELPER AND `gh` ARE BOTH STUBS, and the log is what every case reads. The
# block ends its refusal arms with `exit 0`, so the STATUS says nothing here —
# exactly as the setup-probe harness above records.
printf '%s\n' 'cat "$RB_ACK_DIR/count.out"; exit "$(cat "$RB_ACK_DIR/count.rc")"' \
    > "$_rb_ack/scripts/pr-round-count.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$RB_ACK_DIR/gh.log"\n' > "$_rb_ack/bin/gh"
chmod +x "$_rb_ack/bin/gh"
# A `sed` THAT PRINTS SOMETHING THAT IS NOT A COUNT, for the case that exercises
# the shape guard rather than the parse. It lives in its own directory so only the
# case that asks for it gets it.
printf '#!/bin/sh\nprintf "not-a-count\\n"\n' > "$_rb_ack/sedbin/sed"
chmod +x "$_rb_ack/sedbin/sed"
# A `sed` THAT PRINTS A PLAUSIBLE COUNT AND THEN FAILS, which is the case the parse
# status exists for: command substitution keeps what a command printed before it
# died, so the digits are there and only the status says they mean nothing.
printf '#!/bin/sh\nprintf "41\\n"\nexit 1\n' > "$_rb_ack/sedfail/sed"
chmod +x "$_rb_ack/sedfail/sed"
rb_ack_run() {   # rb_ack_run <helper stdout> <helper rc> [extra PATH dir] [shell attack] ; prints the driver's output
    printf '%s' "$1" > "$_rb_ack/count.out"
    printf '%s' "$2" > "$_rb_ack/count.rc"
    : > "$_rb_ack/gh.log"
    : > "$_rb_ack/attack.log"
    local _p="$_rb_ack/bin:$PATH"
    [ -n "${3:-}" ] && _p="$3:$_p"
    # THE ATTACK IS DEFINED IN THE CHILD, before the block is sourced, because that
    # is where the driver's own bash runs: `SKILL.md` executes in the operator's
    # shell and cannot re-exec, so a function defined there is in scope for it.
    run_limited 25 env PATH="$_p" RB_ACK_DIR="$_rb_ack" RB_ACK_ATTACK="${4:-}" \
        bash --noprofile --norc -c '
HOST=github.com; OWNER=acme; REPO=widget
WHO="chatgpt-codex-connector[bot]"
eval "${RB_ACK_ATTACK:-}"
RB_SCRIPTS="$RB_ACK_DIR/scripts"
. "$RB_ACK_DIR/ack.sh"
' 2>&1 || true
}
_rb_ack_pause='PR_ROUND_PAUSE pr=7 rounds=41 threshold=10 acknowledged=0'
# THE CONTROL FIRST, so every refusal below is refusing something this harness can
# otherwise carry all the way to the post.
_rb_ack_out="$(rb_ack_run "$_rb_ack_pause" 3)"
case "$(cat "$_rb_ack/gh.log")" in
    *'pr comment N'*) pass "a genuine pause is acknowledged on the PR" ;;
    *) die "the control never posted; every refusal case below proves nothing ('$_rb_ack_out')" ;;
esac
# …WITH THE COUNT THE GATE REPORTED, not one retyped into the body. An
# acknowledgement naming the wrong number pauses again at once or skips a later
# check-in, and both are silent.
#
# TWO COUNTS, because ONE proves nothing about propagation: with a single
# successful pause the body could carry that number as a LITERAL and every case
# here would still pass — the refusal cases never post, so they cannot tell. Two
# different counts through the same block is what makes it dynamic.
for _rb_ack_n in 41 7; do
    _rb_ack_out="$(rb_ack_run "PR_ROUND_PAUSE pr=7 rounds=$_rb_ack_n threshold=10 acknowledged=0" 3)"
    case "$(cat "$_rb_ack/gh.log")" in
        *"\`$_rb_ack_n\`"*) pass "…carrying the count the gate itself reported ($_rb_ack_n)" ;;
        *) die "the acknowledgement does not carry the gate's count $_rb_ack_n: $(cat "$_rb_ack/gh.log")" ;;
    esac
done
_rb_ack_out="$(rb_ack_run "$_rb_ack_pause" 3)"
# …AND THE REVIEWER, because the count is per reviewer: an unscoped acknowledgement
# of 41 Codex rounds is read by a Copilot invocation with 5.
case "$(cat "$_rb_ack/gh.log")" in
    *'chatgpt-codex-connector[bot]'*) pass "…and the reviewer it is about" ;;
    *) die "the acknowledgement is unscoped: $(cat "$_rb_ack/gh.log")" ;;
esac
# A SHADOWED `echo` AND `exit` TOGETHER DO NOT REACH THE POST, which is what #224
# was. `SKILL.md` runs in the operator's own shell, where both are NAMES: with the
# refusals written as `|| { echo …; exit 0; }` the arm ran, `exit` RETURNED instead
# of terminating, execution continued into the parse — which succeeds, because the
# forged line is well-formed — and a failed probe's output became the operator's
# recorded permission. Measured then: an ordinary shell no, `echo` alone no, both
# together YES.
#
# SUCCESS-ARM CONTAINMENT HAS NO SUCH GAP: a refusal is an arm NOT TAKEN rather
# than a statement that has to terminate, so there is nothing to walk past. The
# assertions are in three parts because each alone would pass for the wrong reason.
# The attack writes a marker WHEN IT IS INJECTED, so a case that stopped staging it
# is not silently green; nothing is posted, which is the property; and `exit` is
# never reached, which is what the old shape needed and this one does not use.
#
# `echo` IS STILL REACHED, deliberately: the diagnostics are `echo`, so a shadowed
# one is called and silences them. That is why the third assertion names `exit`
# alone — the guarantee here is about a refusal PATH, not about every name.
_rb_ack_attack='printf "INSTALLED\n" >> "$RB_ACK_DIR/attack.log"
echo() { printf "ECHO\n" >> "$RB_ACK_DIR/attack.log"; }
exit() { printf "EXIT\n" >> "$RB_ACK_DIR/attack.log"; return 0; }'
_rb_ack_out="$(rb_ack_run "$_rb_ack_pause" 1 "" "$_rb_ack_attack")"
grep -q INSTALLED "$_rb_ack/attack.log" \
    && pass "the shadowed \`echo\` and \`exit\` are installed in the child" \
    || die "the attack was never injected; the two cases below stage nothing"
case "$(cat "$_rb_ack/gh.log")" in
    *'pr comment'*) die "a failed probe was acknowledged past a shadowed echo and exit: $(cat "$_rb_ack/gh.log")" ;;
    *) pass "…and a failed probe is not acknowledged past them" ;;
esac
# `exit` IS NEVER REACHED, which is the half that matters. The diagnostics are
# still `echo`, so a shadowed one is reached and silences them — harmlessly, since
# nothing but a message depends on it. What the old shape needed was `exit` to
# TERMINATE, and this one does not use it at all.
grep -q EXIT "$_rb_ack/attack.log" \
    && die "the refusal still depends on exit: $(cat "$_rb_ack/attack.log")" \
    || pass "…because nothing in the refusal path calls \`exit\` at all"

# A PARSER THAT PRINTED AND THEN FAILED IS NOT A COUNT. Command substitution keeps
# what it printed, so the digits reach the shape check and pass it — only the
# status says they mean nothing, which is why the parse is the `if`'s own condition
# rather than an assignment followed by a check.
_rb_ack_out="$(rb_ack_run "$_rb_ack_pause" 3 "$_rb_ack/sedfail")"
case "$(cat "$_rb_ack/gh.log")" in
    *'pr comment'*) die "a count from a parser that failed was acknowledged: $(cat "$_rb_ack/gh.log")" ;;
    *) pass "…and a plausible count from a parser that then failed is not acknowledged" ;;
esac
case "$_rb_ack_out" in
    *'could not parse'*) pass "…saying which step refused" ;;
    *) die "the failed parse was refused silently ('$_rb_ack_out')" ;;
esac
# A PARSER THAT SUCCEEDS AND PRINTS SOMETHING THAT IS NOT A COUNT is refused by
# shape rather than by status — the arm the parse itself can never reach, since its
# own pattern only ever yields digits, so it exists for a `sed` that is not the one
# this block means.
_rb_ack_out="$(rb_ack_run "$_rb_ack_pause" 3 "$_rb_ack/sedbin")"
case "$(cat "$_rb_ack/gh.log")" in
    *'pr comment'*) die "a count that is not digits was acknowledged: $(cat "$_rb_ack/gh.log")" ;;
    *) pass "…and a count that is not digits is refused by shape" ;;
esac
case "$_rb_ack_out" in
    *'could not read a round count'*) pass "…saying so" ;;
    *) die "the non-numeric count was refused silently ('$_rb_ack_out')" ;;
esac
# A COUNT OF `0` IS NOT A COUNT. No pause happens at zero rounds — and under a
# `declare -i` inherited from the operator's shell an empty parse becomes exactly
# that, so without this the block acknowledges `0` on output it could not read.
_rb_ack_out="$(rb_ack_run 'PR_ROUND_PAUSE pr=7 threshold=10' 3 "" 'declare -i ROUNDS')"
case "$(cat "$_rb_ack/gh.log")" in
    *'pr comment'*) die "an unparseable count became 0 and was acknowledged: $(cat "$_rb_ack/gh.log")" ;;
    *) pass "…and an empty parse under \`declare -i\` is refused rather than acknowledged as 0" ;;
esac

# AND THE SAME HOLDS INTERACTIVELY, which is a separate question and the reason the
# first version of this fix needed a brace group: an expansion-based refusal stops a
# non-interactive shell outright and abandons only the current compound command in
# an interactive one. Containment by position does not depend on the mode at all —
# the post is inside arms that were never taken — but that is a claim about a shell,
# so it is run rather than argued.
#
# THE MARKER IS SPELLED DIFFERENTLY IN THE SOURCE THAN IN ITS OUTPUT, because an
# interactive shell ECHOES its input: a line that prints `REACHED-THE-END` appears
# in the transcript whether or not it ran. The source carries a format, the output
# carries the value.
rb_ack_interactive() {   # rb_ack_interactive <attack> ; prints what an interactive shell did
    : > "$_rb_ack/gh.log"
    : > "$_rb_ack/attack.log"
    { printf '%s\n' "${1:-}"; cat "$_rb_ack/ack.sh"
      printf '%s\n' 'printf "REACHED-%s-END\n" THE'; } > "$_rb_ack/int.in"
    run_limited 25 env -u SHELLOPTS -u BASH_ENV -u ENV \
            PATH="$_rb_ack/bin:$PATH" RB_ACK_DIR="$_rb_ack" \
            HOST=github.com OWNER=acme REPO=widget WHO='chatgpt-codex-connector[bot]' \
            RB_SCRIPTS="$_rb_ack/scripts" \
            bash --noprofile --norc -i < "$_rb_ack/int.in" 2>&1 || true
}
printf '%s' "$_rb_ack_pause" > "$_rb_ack/count.out"; printf '1' > "$_rb_ack/count.rc"
_rb_ack_out="$(rb_ack_interactive "$_rb_ack_attack")"
grep -q INSTALLED "$_rb_ack/attack.log" \
    && pass "the attack is installed in the interactive session too" \
    || die "the interactive attack was never injected; the case below stages nothing"
case "$(cat "$_rb_ack/gh.log")" in
    *'pr comment'*) die "an interactive session acknowledged a failed probe: $(cat "$_rb_ack/gh.log")" ;;
    *) pass "…and an interactive session acknowledges nothing either" ;;
esac
# …AND THE SESSION IS STILL THERE, so that absence is the arms and not a dead shell.
case "$_rb_ack_out" in
    *REACHED-THE-END*) pass "…with the session still running afterwards" ;;
    *) die "the interactive session did not reach the line after the block ('$_rb_ack_out')" ;;
esac
# …AND A GENUINE PAUSE STILL POSTS THERE, so the two above are not passing because
# an interactive run can never reach the post at all.
printf '3' > "$_rb_ack/count.rc"
_rb_ack_out="$(rb_ack_interactive "")"
case "$(cat "$_rb_ack/gh.log")" in
    *'pr comment'*) pass "…while a genuine pause is acknowledged interactively" ;;
    *) die "no interactive run can reach the post; the two cases above prove nothing ('$_rb_ack_out')" ;;
esac

rm -rf "$_rb_ack"
fi

# ── the none-configured checks message is matched whole, not searched ──────
# ── the none-configured diagnostic is matched WHOLE ───────────────────────
# `gh` has no dedicated status for "nothing to report", so the message is the only
# signal — and a substring test accepted it inside a LARGER failure: a run that
# printed the benign line and then failed for an unrelated reason was classified
# as benign, and the default administrator merge proceeded with no trusted checks
# result at all.
#
# The six cases that prove it moved to `test-pr-ci-state.sh` with the helper, and
# they are EXECUTED there rather than read. The question of whether the MERGE GATE
# reaches that helper at all moved too — into `test-pr-merge-gate.sh`, which runs
# the gate against a stubbed `pr-ci-state.sh` and asserts each of rc 1, 2, 3 and 4
# by its consequence rather than by the presence of a line.

# ── `none` is not permission while auto-review has a pass in flight ────────
# With auto-review on, every Copilot-fix push queues a Codex pass, and Codex
# exposes no review record while that pass is queued — which the merge gate read as
# the same `none` that means "nothing asked Codex about this head". It then fell
# back to the pre-Copilot signoff and could merge before the in-flight pass
# reported, including a body-only CHANGES_REQUESTED that leaves no unresolved
# thread for the other gates to catch.
#
# THAT CASE IS NOW EXECUTED, in `test-pr-merge-gate.sh`: the gate is run with
# auto-review on, a head Codex has not judged, and a clean signoff on the older
# sha — and it must refuse. Reading the `CODEX_STATE` dispatch out of a document
# with `awk` was what this file could do while the code lived there.

# ── the phase trailer has to be documented as a TRAILER ────────────────────
# `git` parses trailers from the last paragraph only, so `Review-Phase: copilot`
# written with a blank line above it is not a trailer — the commit looks correct
# to a reader and is invisible to the merge gate. The contract told the driver to
# "carry the trailer" without saying where, and following it produced exactly that
# commit while developing this plugin.
grep -q 'LAST paragraph' "$SKILL" \
    && pass "the contract says where the phase trailer has to go" \
    || die "the contract asks for a trailer without saying it must be in the trailer block"
grep -q 'trailer_not_in_trailer_block' "$SKILL" \
    && pass "…and names the status the gate reports when it is misplaced" \
    || die "the contract does not mention the misplaced-trailer status"

# ── the driver's working discipline is stated, not assumed ─────────────────
# The failure mode of an automated fix loop is not laziness, it is enthusiasm:
# fixing more than was asked, building more than the finding requires, and
# bundling both into a commit whose summary says "closing review comments". Each
# of these rules exists because breaking it lengthened a real PR here, so each is
# asserted rather than left to be inferred from the surrounding prose.
# EVERY clause this contract declares binding, not a sample of them. The first
# version asserted five of six, so deleting "every change must be reviewable as a
# fix" left the suite green — a contract can lose a rule silently exactly as a
# helper can lose a field check.
for rule in \
    'Fix what the finding names' \
    'Do not build more than the finding requires' \
    'Every change you make must be reviewable as a fix' \
    'Validate a finding before you act on it' \
    'Prove a fix can fail' \
    'Say what you did not do'; do
    grep -qF "$rule" "$SKILL" \
        && pass "the contract states: $rule" \
        || die "the contract no longer states: $rule"
done

# ── the driver is told to read a finding whole ─────────────────────────────
# `list` prints one line per thread so the set is countable; that line is not the
# finding. Acting on the title alone produces a fix aimed at a paraphrase, which
# is how a round ends with the thread resolved and the finding still true.
grep -q 'Read each finding whole' "$SKILL" \
    && pass "the contract tells the driver to read the finding body" \
    || die "the contract does not tell the driver to read past the title"
grep -q 'suggestion' "$SKILL" \
    && pass "…including any code suggestion attached to it" \
    || die "the contract never mentions code suggestions"
grep -q 'proposal rather than an instruction' "$SKILL" \
    && pass "…and that a suggestion is a proposal, not an instruction" \
    || die "the contract does not say how to weigh a code suggestion"
# The bodies come from the helper, which filters to UNRESOLVED threads. The REST
# comments endpoint has no such filter and returns every review comment the PR has
# ever had, so fetching bodies there hands the driver findings answered three
# rounds ago — and fixing an already-answered comment is the scope expansion these
# same rules forbid. The contract said so only after a review round said it first.
# The endpoint is NAMED — the contract warns against it — so what must be absent
# is a CALL to it, not the string. FLATTENED, because `gh api` calls in this file
# routinely span continuation lines: a line-based match saw only one token of a
# split invocation and reported clean. Third time line-wrapping has defeated a
# check in this PR, which is why the flattened copy is taken once and reused.
# The scans below use herestrings rather than a piped `printf`: under `pipefail`,
# `grep -q` exiting at the first match SIGPIPEs the producer and the pipeline
# reports the match as ABSENT — the fail-open direction. The fixture demonstrating
# that hazard, and the counting machinery for CHANGELOG consistency, are held back
# for a follow-up PR: both are hardening of this file rather than tests of the
# documentation this change delivers, and both were the source of most of the
# review churn on it.
# A POSITIVE CONSTRAINT, not a blacklist of route spellings.
#
# Three versions of this guard tried to recognise the forbidden call by its shape
# — `[^|]*` treated a jq pipe as a pipeline boundary, `{0,200}` was a ceiling a
# long filter walks past, and the route regex was defeated in turn by `$PR`,
# quotes, and a backslash continuation. Each fix was correct and each was one
# spelling behind, because a lexical blacklist can always be evaded: the last
# evasion found was `PULLS="repos/…/pulls/$PR"; gh api "$PULLS/comments"`, where no
# contiguous route substring exists at all.
#
# The invariant was never really about that string. It is that the findings are
# read through the HELPER, which filters to unresolved threads — so the check is
# now that the findings-reading section executes `pr-findings.sh` and calls no
# `gh api` at all. No composition of variables satisfies that, because the
# constraint is on what the section may invoke rather than on how a URL is spelt.
#
# `gh api` remains legitimate elsewhere in the file — reactions and thread
# resolution use it — so the constraint is scoped to the section that reads
# findings.
findings_code="$(awk '
    /^## 4\. Read the findings/ { insec = 1 }
    insec && /^## 5\./ { insec = 0 }
    !insec { next }
    /^[ ]{0,3}(```+|~~~+)/ {
        line = $0; sub(/^[ ]+/, "", line)
        ch = substr(line, 1, 1); n = 0
        while (substr(line, n + 1, 1) == ch) n++
        if (!inb) { inb = 1; fch = ch; fn = n; next }
        if (ch == fch && n >= fn && substr(line, n + 1) ~ /^[[:space:]]*$/) { inb = 0; next }
        next
    }
    inb { print; next }
    # AN INDENTED BLOCK IS ALSO CODE. Markdown treats four spaces at the top level
    # as a code block, and a fenced helper call elsewhere in the section kept
    # `findings_code` non-empty — so a recipe hidden in an indented block was
    # omitted while the whitelist reported clean. It never had to defeat the
    # check, only to sit outside what the extractor looked at.
    # TABS FIRST. A leading tab indents a Markdown code block exactly as four
    # spaces do, and an extractor that knew only spaces omitted it — the third
    # narrowing of this same extractor, so the fix normalises rather than adding
    # one more accepted shape.
    { gsub(/\t/, "    ") }
    /^[ ]{4,}[^[:space:]]/ { sub(/^[ ]+/, ""); print }' "$SKILL")" \
    || die "could not extract the findings-reading section from SKILL.md"
[ -n "$findings_code" ] \
    || die "the findings-reading section has no executable block; has it moved?"
# A WHITELIST, which is where this had to end up. Blacklisting the route was
# defeated by five spellings; blacklisting `gh api` was still lexical and is
# defeated by `gh  api`, `"gh" api`, or a continuation between the two words.
# Every blacklist is one spelling behind because the space of ways to write a
# command is open.
#
# So the section is constrained to what it MAY run rather than what it may not:
# every executable line here has to be a `pr-findings.sh` invocation. Anything
# else fails however it is spelt, because the check is not looking at how a
# command is written — it is looking for anything that is not the one permitted
# command. That closes the sequence rather than extending it.
#
# If this section ever legitimately needs a second command, this guard fails and
# is updated deliberately. That is the correct cost: adding a call here is exactly
# the change that should not happen quietly.
findings_stmts=0 findings_bad=""
while IFS= read -r line; do
    # A COMMENT IS DECIDED BY THE FIRST NON-BLANK CHARACTER. The glob `' '*'#'*`
    # matched any indented line containing a `#` ANYWHERE, so
    # `    gh api …/comments # fetch bodies` was discarded as a comment and never
    # reached the whitelist at all — a bypass that did not need to defeat the
    # check, only to avoid it.
    _t="${line#"${line%%[![:space:]]*}"}"
    case "$_t" in
        ''|'#'*) continue ;;
    esac
    findings_stmts=$((findings_stmts + 1))
    # ANCHORED to the whole statement. An unanchored glob only asked that the
    # permitted call appear SOMEWHERE, so `gh api …; "$RB_SCRIPTS"/pr-findings.sh
    # list N` satisfied it — a whitelist carrying a blacklist's hole. The statement
    # is split on `;`: the first command must BE the helper, and every following
    # segment must be a status capture, which is the only other thing these lines
    # do.
    stmt="${line#"${line%%[![:space:]]*}"}"
    first="${stmt%%;*}"; rest="${stmt#"$first"}"
    ok=1
    # The permitted segment must be the helper call and NOTHING ELSE. Splitting on
    # `;` alone left `… list N && gh api …` intact in `first`, where a prefix glob
    # accepted it — the anchor was on the start of a segment rather than on the
    # whole command. Control operators and command substitution chain a second
    # command without a semicolon, so they are refused here.
    case "$first" in
        # `>(`/`<(` are process substitution: `… list N > >(gh api …)` runs a second
        # command with none of the tokens above in it. `<` and `>` are refused
        # outright — these statements have no business redirecting.
        *'&&'*|*'||'*|*'|'*|*'&'*|*'$('*|*'`'*|*'>('*|*'<('*|*'>'*|*'<'*) ok=0 ;;
        '/usr/bin/env bash -p "$RB_SCRIPTS"/pr-findings.sh '*) ;;
        *) ok=0 ;;
    esac
    while [ -n "$rest" ] && [ "$ok" -eq 1 ]; do
        rest="${rest#;}"; seg="${rest%%;*}"; rest="${rest#"$seg"}"
        seg="${seg#"${seg%%[![:space:]]*}"}"; seg="${seg%"${seg##*[![:space:]]}"}"
        # A COMPLETE IDENTIFIER ASSIGNMENT, character by character. The glob
        # `[A-Za-z_]*'=$?'` reads as "one identifier character, then anything,
        # then =$?" — so `gh api repos/…/comments && FIND_RC=$?` satisfied it.
        # `*` in a glob is not `*` in a regex, and that difference was the hole.
        case "$seg" in
            '') ;;
            *'=$?')
                _name="${seg%'=$?'}"
                case "$_name" in
                    ''|[!A-Za-z_]*) ok=0 ;;
                    *[!A-Za-z0-9_]*) ok=0 ;;
                esac ;;
            *) ok=0 ;;
        esac
    done
    [ "$ok" -eq 1 ] || findings_bad="$findings_bad
       $line"
done <<<"$findings_code"
[ "$findings_stmts" -gt 0 ] \
    && pass "the findings-reading section has executable statements to check" \
    || die "the findings-reading section executes nothing; has it moved?"
if [ -z "$findings_bad" ]; then
    pass "…and every one of them is a pr-findings.sh call, whatever else could be spelt"
else
    die "the findings-reading section runs something other than pr-findings.sh:"
    printf '%s\n' "$findings_bad"
fi
grep -q 'no resolution filter' "$SKILL" \
    && pass "…and says why that endpoint cannot be used for findings" \
    || die "the contract does not explain why the REST endpoint is wrong here"
# The deferral rule must not contradict the work-order rule: a mention describing
# an UNFIXED defect is read as a task, and Codex then commits in an environment
# with no remote. The disposition belongs in the summary; the description does not.
# Mutation proof is mandatory in this repository, so the contract must not offer
# disclosure as a way out of it: a summary is untrusted context, not authority,
# and closing a round on "no mutant is claimed" leaves an assertion that passed
# before the fix while the suite reports green.
# The body-reading rule needs the SENTENCE, not just the heading above it:
# reversing the prose to "the title is sufficient" left that heading intact and
# every other check satisfied. Asserted here rather than beside the heading
# because the sentence wraps in the file and is only contiguous once flattened.
# The README must describe the operator stop, because it is the one rule a user
# MEETS rather than reads about: a loop that will not close, with the reason only
# in a summary. Documenting the behaviour without documenting the decision that
# unblocks it leaves them stuck with no way to know what is being asked.
rd_flat="$(tr '\n' ' ' < "$SCRIPT_DIR/../../../README.md" | tr -s ' ')" \
    || die "could not flatten README.md"
grep -qF 'stops for you' <<<"$rd_flat" \
    && pass "the README says the loop stops for the operator when a mutation cannot be built" \
    || die "a user could meet a loop that will not close with no user-facing explanation"
grep -qF 'a dated record landed on the base branch by its own PR' <<<"$rd_flat" \
    && pass "…and says what decision unblocks it" \
    || die "the README does not tell the operator how to accept the limitation"

grep -qF 'That line is not the finding.' <<<"$skill_flat" \
    && pass "the contract says explicitly that the printed line is not the finding" \
    || die "the body-reading rule could be reversed under an unchanged heading"
grep -q 'not waivable by disclosure' <<<"$skill_flat" \
    && pass "mutation proof cannot be waived by saying so in the summary" \
    || die "the contract lets a summary line stand in for an unproven fixture"
grep -qi 'write the limitation as a comment \*\*at the site\*\*' <<<"$skill_flat" \
    && pass "…an unprovable case is written at the site" \
    || die "the contract does not say where an unprovable limitation is recorded"
# …and does NOT pretend that comment is authority. A comment added in this PR
# arrives WITH the change, so it is untrusted context exactly like the summary —
# calling it a base-ref record would let the round converge on the author's own
# say-so, which is the thing the rule above exists to forbid.
grep -qi 'It explains; it does not accept' <<<"$skill_flat" \
    && pass "…and that comment explains rather than accepts" \
    || die "the contract treats a comment added in this PR as an accepted limitation"
grep -qi 'landed on the \*\*base ref by its own pull request\*\*' <<<"$skill_flat" \
    && pass "…with acceptance requiring a separately landed base-ref record" \
    || die "the contract does not say how a limitation actually becomes authority"
# The OUTCOME, not only the prohibition. Recording the limitation and carrying on
# is still closing a round on an unproven fixture — the stop is what makes the
# rule bite, and it was the one clause the previous pair of assertions missed.
grep -qE '\*\*stop for the operator\*\*' <<<"$skill_flat" \
    && pass "…and the round stops for the operator rather than closing" \
    || die "the contract records an unprovable case but lets the round close anyway"

# The scope rule and the class-wide self-check must not contradict each other:
# one says fix only what was named, the other says find every occurrence of the
# same shape. They are reconciled by scope, not left for the driver to pick.
grep -q 'is the DEFECT, not the line' <<<"$skill_flat" \
    && pass "the scope rule and the class-wide self-check are reconciled" \
    || die "the contract gives the driver two incompatible scope instructions"
grep -q 'outside this PR' <<<"$skill_flat" \
    && pass "…and a same-shape defect outside the diff is recorded, not pulled in" \
    || die "the contract does not bound class-wide fixing to the PR's own diff"
# The DECISIVE clause: when a finding states its scope, that scope governs — but
# only over copies this PR already changes. Without the first half the driver has
# no rule for an explicit "fix the other parsers"; without the second half it
# contradicts the outside-diff boundary directly above.
grep -q 'states its scope' <<<"$skill_flat" \
    && pass "a finding's stated scope governs the class-wide fix" \
    || die "the contract has no rule for a finding that states its own scope"
grep -q 'that scope governs \*\*for the copies this PR already changes\*\*' <<<"$skill_flat" \
    && pass "…bounded to the copies this PR already changes" \
    || die "stated scope is unbounded and contradicts the outside-diff rule"
# `[[:space:]]`, never `\s`. `\s` is a GNU extension: BSD grep on stock macOS —
# which README lists as supported — reads it as a literal `s`, so this searched for
# "evens*when", failed, and called `die` on correct text. The whole suite is a
# mandatory pre-push gate, so a macOS contributor could not close a round while CI
# stayed green. Same class as the `timeout`, `sha1sum` and `seq` findings before it.
#
# The flattened text has already collapsed runs of whitespace to single spaces, so
# a plain space would do; the class is used anyway because the next person to copy
# this line may not be matching flattened text.
# THE SELF-CHECK BULLET SPECIFICALLY. The bounded wording appears in the scope
# rules, so an assertion that merely finds it somewhere in the file stayed green
# while the self-check thirty lines later still said "search for the same shape
# everywhere else and fix them together" — the two halves of the contract giving
# opposite instructions, which is what this whole PR keeps being about.
grep -qF 'search for the same shape **everywhere else this PR already changes** and fix those together' <<<"$skill_flat" \
    && pass "the class-wide self-check carries the diff boundary too" \
    || die "the self-check would have the driver widen the PR into untouched code"
grep -q 'even[[:space:]]*when the finding names it' <<<"$skill_flat" \
    && pass "…and a named PRE-EXISTING copy outside the diff is still not pulled in" \
    || die "a finding naming an untouched file could still widen the PR"
# …but an untouched file this PR BROKE is not an unrelated problem. A validator
# loosened or a producer altered can break a consumer the diff never touched, and
# repairing it finishes the change rather than widening it. Without this the rule
# told the driver to leave a regression it had just caused, because the file
# happened to sit outside the diff.
grep -qF 'repairing that consumer is not widening the PR, it is' <<<"$skill_flat" \
    && pass "…while repairing a consumer this PR broke stays in scope" \
    || die "the contract would leave a regression it caused in an untouched file"
# A REGRESSION THE FIX CAUSED BELONGS TO THIS ROUND. The rule said a different
# defect found while fixing is "never in scope", which would have the driver defer
# a defect it had just introduced — part of what this PR changed, and on its way to
# a merge if the next reviewer misses it. The line is drawn at pre-existing, not at
# "was it the defect the finding named".
# THE OUTCOME, not the subject. Matching only "a regression the fix itself
# introduces" passed when the sentence was negated — the contract could say such a
# regression is NOT this round's work and this check would still be green.
grep -q 'regression the fix itself introduces' <<<"$skill_flat" \
    && pass "the contract addresses a regression the fix introduces" \
    || die "the contract no longer addresses a regression the fix causes"
grep -q 'it is part of what this PR changed, so it is this round' <<<"$skill_flat" \
    && pass "…and says it is this round's work" \
    || die "the contract does not say a fix-introduced regression is this round's work"
# BOTH qualifiers. "pre-existing" alone still excluded the same defect in a copy
# this PR changes, which the bullets above require fixing together — the driver
# could leave an in-diff twin and collect the same finding next round.
# Subject AND outcome. `A *different* pre-existing defect` alone passed with the
# sentence reversed to "is in scope", which is the opposite instruction.
grep -q 'A \*different\* pre-existing defect' <<<"$skill_flat" \
    && pass "…and only a DIFFERENT pre-existing defect is out of scope" \
    || die "the out-of-scope rule would exclude an in-diff twin of the same defect"
grep -qE 'A \*different\* pre-existing defect found while fixing this one is not in scope' <<<"$skill_flat" \
    && pass "…and that defect is stated to be OUT of scope" \
    || die "the contract does not state the out-of-scope outcome"
# ── the SIGPIPE hazard these scans avoid, demonstrated ────────────────────
# Every scan in this file uses a herestring rather than a piped `printf`. This is
# the fixture that shows why, and it was held back from the documentation PR
# because it tests THIS FILE's idiom rather than anything the contract says.
#
# With `pipefail` on, `grep -q` exits at the first match and the producer takes
# SIGPIPE, so the pipeline reports the match as ABSENT — the fail-open direction,
# where a guard reports clean exactly when it should fire.
#
# MEASURED, and the measurement bounds the claim: the race needs the match on an
# early LINE with more lines behind it, so `grep` can exit before draining the
# writer. Multi-line input reproduces it 5 runs out of 5; single-line input 0 out
# of 5 at the same size, because `grep` must read the whole line before it can
# match at all. The flattened variables here are single-line by construction, so
# the pipeline form was not losing matches — the herestring removes the class
# rather than relying on an invariant one edit could break.
#
# The construction reports separately from the result: `set -uo pipefail` has no
# `-e`, so a failing `head`/`base64` would leave `multi` holding just "EARLYMATCH"
# and both forms would match it, reporting success having built nothing. Exit 9 is
# reserved for that.
sigpipe_probe='set -uo pipefail
    body="$(head -c 300000 /dev/urandom | base64)" || exit 9
    [ "${#body}" -ge 200000 ] || exit 9
    case "$body" in *"
"*) ;; *) exit 9 ;; esac
    multi="EARLYMATCH
$body"'
# PIPESTATUS, not the aggregate: on a runner where SIGPIPE is ignored `printf`
# receives EPIPE and returns 1 rather than dying with 141 — the same phenomenon,
# a different number — and a check accepting only 141 failed CI for four commits.
# The producer losing while the consumer MATCHED is the race, whatever the
# platform reports; a consumer that failed is something else and is not proof.
#   0 no race · 9 unbuildable · 20 producer lost, consumer matched · 21 consumer failed
sigpipe_rc=0
bash -c "$sigpipe_probe"'
    printf "%s" "$multi" | grep -q EARLYMATCH   # racy-pipeline-ok: this IS the race
    rcs=("${PIPESTATUS[@]}")
    prod=${rcs[0]}; cons=${rcs[1]}
    [ "$cons" -eq 0 ] || exit 21
    [ "$prod" -eq 0 ] && exit 0
    exit 20' || sigpipe_rc=$?
case "$sigpipe_rc" in
    9)  die "the SIGPIPE probe could not be built; this case proves nothing" ;;
    0)  pass "SKIPPED: the producer pipeline did not race on this platform" ;;
    20) pass "a producer pipeline loses an early match under pipefail, on multi-line input" ;;
    21) die "the probe consumer failed; the race was not what this case observed" ;;
    *)  die "the SIGPIPE probe returned an unexpected status ($sigpipe_rc)" ;;
esac
here_rc=0
bash -c "$sigpipe_probe"'
    grep -q EARLYMATCH <<<"$multi"' || here_rc=$?
case "$here_rc" in
    9) die "the SIGPIPE probe could not be built; the herestring case proves nothing" ;;
    0) pass "…and the herestring form finds it, which is why these scans use it" ;;
    *) die "the herestring form lost an early match; every scan here is unsafe" ;;
esac

# ── the release entry does not teach a rejected account ────────────────────
# The counting machinery, held back from the documentation PR and restored here.
# Four stale claims were found in this one entry across three rounds, and the
# reason each survived was the same: a check for the PRESENCE of a qualified form
# is satisfied by whichever mention still carries it, while another states the
# rule the old way two paragraphs down.
# PINNED to the entry that introduced these rules, not to whichever is on top: the
# next release prepends its own, every count below would then find zero claims in
# it, and this suite would fail while the 2.0.2 documentation stayed correct. A
# guard that breaks on the next release is a guard that gets deleted rather than
# fixed. Everything below that entry is history, and a release note has to be able
# to quote a superseded rule to explain what was fixed.
cl_202="$(awk -v want='## [2.0.2]' '
    index($0, want) == 1 { inb = 1; next }
    /^## \[/ { inb = 0 }
    inb { print }' "$SCRIPT_DIR/../../../CHANGELOG.md" | tr '\n' ' ' | tr -s ' ')" \
    || die "could not extract the 2.0.2 CHANGELOG entry"
[ -n "$cl_202" ] || die "the 2.0.2 CHANGELOG entry is missing or empty"
# …and the scope account must carry the regression exception, which the entry
# contradicted after SKILL.md gained it — the same instance-not-class miss, one
# file over, for the second round running.
# No-match is a count of ZERO, not a failed command: under this file's `-e` a grep
# that matches nothing exits 1, and the assignment took the whole suite down —
# so deleting a claim entirely terminated the run instead of reaching the branch
# that names it. A real grep error (status > 1) is still a failure.
count_claims() {   # count_claims <pattern> <text> ; prints the count, 2 on error
    local out rc=0
    out="$(grep -oiE "$1" <<<"$2")" || rc=$?
    case "$rc" in
        0) ;;
        1) printf '0'; return 0 ;;
        *) return 2 ;;
    esac
    # COUNTED IN THE SHELL, with no pipeline and no external command. `wc` or `tr`
    # can emit a plausible number and then exit non-zero, and
    # `printf "%s" "$( … | wc -l | tr -d ' ')"` swallowed that status — a failed
    # parse returning success with a bogus count, which is the "a call that printed
    # before failing is not data" rule one layer in.
    #
    # Guarding that status would have worked only because this file sets
    # `pipefail`: without it the pipeline reports `tr`'s success and the failure is
    # invisible again. Counting here removes the failure mode instead of detecting
    # it, and cannot be reintroduced by copying the function somewhere with
    # different shell options.
    local n=0 _line
    while IFS= read -r _line; do n=$((n + 1)); done <<<"$out"
    printf '%s' "$n"
}
# EVERY mention must carry the qualifier, so the two counts have to match. A
# presence check passed while one of two bullets had lost it — the "somewhere in
# the file" weakness reproduced inside a single entry.
cl_count() {   # cl_count <claim-pattern> <qualified-pattern> <label>
    local total qualified
    total="$(count_claims "$1" "$cl_202")" \
        || { die "the claim scan failed for: $3"; return 0; }
    qualified="$(count_claims "$2" "$cl_202")" \
        || { die "the qualifier scan failed for: $3"; return 0; }
    [ "$total" -gt 0 ] || { die "the release entry no longer states: $3"; return 0; }
    [ "$total" = "$qualified" ] \
        && pass "every mention in the release entry is qualified: $3 ($qualified/$total)" \
        || die "the release entry states $3 unqualified in $((total - qualified)) of $total places"
}

# ── THE RESUME RECIPE'S PHASE BRANCH, EXECUTED ─────────────────────────────
# The assertions beside the recipe itself are about SHAPE. These run the
# document's own lines — lifted whole, so a regression arrives in the probe — with
# a stubbed helper, and check what actually happens for each status it can return.
#
# TO THE END OF THE BLOCK, not to the first `fi`. The shape this replaced put the
# decision in a `case` AFTER the `if`, and a lift that stopped at the `fi` took
# only the half that reads the status — so the continuation was unreachable in the
# probe and every case below passed vacuously against exactly the regression they
# exist to catch. This is the last thing in the fenced block, so there is nothing
# after it to take by accident.
#
# HERE RATHER THAN BESIDE THEM, because a stub directory is a scratch directory,
# and the `mktemp` probe further down re-runs this whole file expecting it to stop
# at the counter fixture's guard above with that guard's words. `TMP_CL` is that
# guard's directory, so nothing new is taken.
_ph_blk="$(awk '/^### Resuming after a stop$/ {sec=1}
                sec && /^```bash$/ {inb=1; next}
                inb && /^```$/ {exit}
                inb' "$SKILL" \
    | awk '/^if \/usr\/bin\/env bash -p "\$RB_SCRIPTS"\/pr-phase-state\.sh/{f=1} f{print}')"
[ -n "$_ph_blk" ] || die "the phase branch could not be lifted from the resume recipe"
_ph_dir="$TMP_CL/phase"; mkdir -p "$_ph_dir"
# ON STDERR, because the continuation CAPTURES this helper's stdout into
# `CODEX_SHA` — a marker printed there is assigned, not observed.
printf '#!/usr/bin/env bash\nprintf "CONTINUED\\n" >&2\n' > "$_ph_dir/pr-signoff.sh"
chmod +x "$_ph_dir/pr-signoff.sh"
ph_run() {   # ph_run <helper status> <extra shell prelude> ; prints the output
    printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$_ph_dir/pr-phase-state.sh"
    chmod +x "$_ph_dir/pr-phase-state.sh"
    RB_SCRIPTS="$_ph_dir" CODEX_BOT=somebody bash -c "$2"'
    '"$_ph_blk" 2>&1 || true
}
# THE CONTROL FIRST, because "the marker never appeared" is also what a probe that
# cannot reach the continuation at all looks like — and that passes against any
# structure, including every broken one below.
case "$(ph_run 0 ':')" in
    *CONTINUED*) pass "the phase branch reaches the sha read when the helper says the phase stands" ;;
    *) die "the phase-branch probe never reaches the continuation, so it proves nothing" ;;
esac
for _ph_rc in 1 2; do
    # WITH `exit` SHADOWED, which is what a refusal falling through looks like:
    # one that RETURNS leaves the branch running on into whatever came after it.
    case "$(ph_run "$_ph_rc" 'exit() { return 0; }; echo() { return 0; }')" in
        *CONTINUED*) die "with exit shadowed, status $_ph_rc reached the continuation" ;;
        *) pass "…and status $_ph_rc does not reach it even with exit shadowed" ;;
    esac
    # UNDER `errexit`, where a simple command's non-zero status ends the shell
    # before anything can read it.
    case "$(ph_run "$_ph_rc" 'set -e')" in
        *"the phase"*) pass "…and an errexit shell still reaches the refusal for status $_ph_rc" ;;
        *) die "under set -e, status $_ph_rc never reached the refusal" ;;
    esac
    # AND WITH THE STATUS NAME ALREADY READONLY. The shape this replaced held the
    # answer in `PHASE_RC`, and a startup file that had made that name readonly
    # with the value 0 made both assignments fail while leaving it at 0 — sending a
    # refused phase through the continuation. With no variable there is nothing to
    # pre-seed, and this is what says so.
    case "$(ph_run "$_ph_rc" 'readonly PHASE_RC=0')" in
        *CONTINUED*) die "a readonly PHASE_RC=0 sent status $_ph_rc through the continuation" ;;
        *) pass "…and a readonly PHASE_RC=0 cannot send status $_ph_rc through it" ;;
    esac
done

# The stop is exercised, not merely written. The dangerous case is not "mktemp
# failed" — a plain failure is caught by any status check — it is a `mktemp` that
# PRINTS a plausible path, because command substitution keeps that output, so an
# unvalidated caller proceeds with a directory that does not exist. Both shapes
# are replayed, and each has to leave the filesystem untouched.
MTP="$TMP_CL/mtprobe"; mkdir -p "$MTP/bin"
mt_probe() {   # mt_probe <stub exit status> <what the case is>
    local canary out rc
    canary="$TMP_CL/canary$1"; rc=0
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit %s\n' "$canary" "$1" \
        > "$MTP/bin/mktemp"
    chmod +x "$MTP/bin/mktemp"
    out="$(PATH="$MTP/bin:$PATH" bash -c '
set -Eeuo pipefail
'"$(declare -f mktemp_d)"'
d="$(mktemp_d)" || { echo STOPPED; exit 1; }
mkdir -p "$d/bin"; echo "CONTINUED:$d"' 2>&1)" || rc=$?
    { [ "$out" = STOPPED ] && [ "$rc" -eq 1 ]; } \
        && pass "a mktemp that $2 stops the fixture setup" \
        || die "a mktemp that $2 did not stop the setup (rc=$rc, '$out')"
    [ ! -e "$canary" ] \
        && pass "…and nothing is written under the path it printed" \
        || die "the setup wrote under a path a mktemp that $2 merely printed"
}
mt_probe 1 'prints a plausible path and then fails'
mt_probe 0 'prints a path it never created'
rm -f "$MTP/bin/mktemp"

# The CALL SITE, not just the helper. Everything above still passes if the two
# lines that acquire `TMP_CL` are put back the way they were, because a working
# `mktemp` never reaches the guard — the helper is proven and the caller is not.
# So the guard is exercised where it lives: this file is re-run against a `mktemp`
# it cannot trust, and it has to stop before anything is written.
#
# BOTH untrustworthy shapes, because only one of them separates the two
# regressions. A `mktemp` that FAILS is rejected by a bare `mktemp -d` with a
# status guard just as well as by `mktemp_d`, so that case alone leaves the
# status-guarded bare form indistinguishable from the fix. A `mktemp` that prints
# an absolute path it never created and returns 0 is the one only validation
# catches — and it is not hypothetical, it is what a `mktemp` racing a cleaner or
# a broken $TMPDIR does.
#
# `mkdir` and `ln` are stubbed to RECORD rather than act. What the unfixed form
# does is write fixture symlinks into `/bin`, and performing that in order to
# detect it is not a trade this suite can make; an empty record is the same
# evidence at no risk. The child skips this block, so a regression that lets it
# past the guard cannot recurse.
if [ -z "${CONTRACT_SCRATCH_PROBE-}" ]; then
    SPB="$TMP_CL/probe/bin"; mkdir -p "$SPB"
    sp_probe() {   # sp_probe <stub exit status> <what the case is>
        local wit out rc
        wit="$TMP_CL/probe/writes$1"; rc=0
        printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$wit" \
            > "$SPB/mkdir"
        cp "$SPB/mkdir" "$SPB/ln"
        # The path the stub prints is absolute, plausible, and NEVER CREATED —
        # the whole point of the second case.
        printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit %s\n' \
            "$TMP_CL/probe/never-made" "$1" > "$SPB/mktemp"
        chmod +x "$SPB/mkdir" "$SPB/ln" "$SPB/mktemp"
        # `run_limited <secs> env …`, so the stub PATH reaches the SUBJECT and not
        # the watchdog. Written the other way round first, and `test-testlib.sh`
        # caught it: `run_limited`'s own fallback shells out to `mktemp`, which
        # here is a stubbed one — the watchdog would have returned 125 without
        # running this file at all, and the guard would have been asserting about
        # nothing. The environment belongs to the thing under test.
        out="$(run_limited 300 env CONTRACT_SCRATCH_PROBE=1 PATH="$SPB:$PATH" \
            bash "${BASH_SOURCE[0]}" 2>&1)" || rc=$?
        { [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 125 ] \
            && grep -qF 'no scratch directory for the counter fixture' <<<"$out" \
            && grep -qF 'RESULT: FAIL' <<<"$out"; } \
            && pass "a mktemp that $2 stops this file rather than being recorded" \
            || die "a mktemp that $2 did not stop this file (rc=$rc)"
        # The whole point: `die` would have let it carry on with an unusable
        # `TMP_CL`, and every `$TMP_CL/…` under it then resolves somewhere else.
        [ ! -s "$wit" ] \
            && pass "…and it creates nothing under a path it was handed" \
            || die "the run wrote after a mktemp that $2: $(tr '\n' ';' <"$wit")"
    }
    sp_probe 1 'prints a plausible path and then fails'
    sp_probe 0 'prints a path it never created and succeeds'

    # THE CLEANUP, observed rather than assumed. Nothing above looks at `$TMP_CL`
    # after the process is gone, so deleting the EXIT trap — or making it a no-op —
    # left the suite green while every run leaked a scratch tree again. Cleanup was
    # a deliberate change in this commit, so it gets an assertion like any other.
    #
    # The child is given its own $TMPDIR, which is the only way to learn where its
    # scratch went without the child having to report it: whatever `mktemp` gave it
    # is under this directory, so "the trap ran" and "this directory is empty" are
    # the same statement. It runs to completion with a real `mktemp` — that is the
    # path where a leak actually happens.
    CTD="$TMP_CL/tdir"; mkdir -p "$CTD"
    cln_rc=0
    run_limited 300 env CONTRACT_SCRATCH_PROBE=1 TMPDIR="$CTD" \
        bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 || cln_rc=$?
    # THREE ways this can go wrong, reported apart, and the scan has its own.
    #
    # Folded into one condition, a child that failed for a reason of its own — any
    # other assertion in this file — was announced as a LEAK. Splitting the child
    # out left the scan still folded in: `|| cln_left='THE_SCAN_FAILED'` turns an
    # unreadable directory into an ENTRY, so a scan that could not run was reported
    # as a leak of a file by that name, sending the reader to the EXIT trap instead
    # of to the scanner. A substituted sentinel is only a sentinel if the branch
    # reading it treats it as one; consumed as data it is a plausible value, which
    # is the failure this whole file is about.
    #
    # `report_cleanup` returns the verdict, so every branch can be EXERCISED. The
    # branch nobody runs is the branch that breaks — the same reason
    # `test-testlib.sh` made its own reporting a function.
    scan_scratch() {   # scan_scratch <dir> ; prints the entries, 2 if it could not
        local out
        out="$(ls -A "$1" 2>/dev/null)" || return 2
        printf '%s' "$out"
        return 0
    }
    report_cleanup() {   # <child rc> <dir> ; 0 clean, 1 leaked, 2 child failed, 3 scan failed
        local rc="$1" left srx
        [ "$rc" -eq 0 ] || return 2
        srx=0
        left="$(scan_scratch "$2")" || srx=$?
        [ "$srx" -eq 0 ] || return 3
        [ -n "$left" ] || return 0
        printf '%s' "$left"
        return 1
    }
    # THE DIAGNOSTIC IS THE PRODUCT, so it is what gets asserted. A numeric verdict
    # checked in isolation leaves the dispatch below untested: swap the scan-failure
    # text for the leak text and every status still matches, while an unreadable
    # directory once again sends the author to the EXIT trap. The whole point of
    # this round's split was WHICH CAUSE IS NAMED — so the fixture reads the name.
    cleanup_diagnostic() {   # <verdict> <child rc> <entries> ; the message, 0 if clean
        case "$1" in
            0) printf 'a completed run removes its scratch tree rather than leaking it'
               return 0 ;;
            1) printf "a run left its scratch tree behind ('%s')" "$3"; return 1 ;;
            2) printf "the cleanup probe's own run failed (rc=%s); the leak check proves nothing" "$2"
               return 1 ;;
            *) printf 'the scratch directory could not be scanned; the leak check proves nothing'
               return 1 ;;
        esac
    }
    # One entry point, used by the fixture and by the real check alike — otherwise
    # the fixture exercises a copy of the dispatch rather than the dispatch.
    cleanup_verdict() {   # <child rc> <dir> ; prints the diagnostic, 0 if clean
        local v left
        v=0
        left="$(report_cleanup "$1" "$2")" || v=$?
        cleanup_diagnostic "$v" "$1" "$left"
    }
    mkdir -p "$TMP_CL/probe/leaky/tmp.XXXXXX" "$TMP_CL/probe/emptied"
    while IFS='|' read -r want crc where needle what; do
        [ -n "$want" ] || continue
        got=0; msg="$(cleanup_verdict "$crc" "$TMP_CL/probe/$where")" || got=$?
        { [ "$got" = "$want" ] && grep -qF "$needle" <<<"$msg"; } \
            && pass "$what is named as itself, not as another cause" \
            || die "$what reported rc=$got '$msg' (wanted $want naming '$needle')"
    done <<'CLCASES'
0|0|emptied|removes its scratch tree|a run that cleaned up
1|0|leaky|left its scratch tree behind ('tmp.XXXXXX')|a directory holding a leaked tree
1|1|tdir|own run failed (rc=1)|a child run that failed
1|0|never-scanned|could not be scanned|a directory that cannot be scanned
CLCASES
    cln_msg="$(cleanup_verdict "$cln_rc" "$CTD")" && pass "$cln_msg" || die "$cln_msg"
fi
cl_req() {   # cl_req <fixed-string> <what it guarantees> <what its absence means>
    grep -qF "$1" <<<"$cl_202" \
        && pass "the release entry $2" \
        || die "the release entry $3"
}
cl_absent() {   # cl_absent <pattern> <what its presence means>
    local rc=0
    grep -qiE "$1" <<<"$cl_202" || rc=$?
    case "$rc" in
        0) die "the release entry $2" ;;
        1) pass "…and does not $2" ;;
        *) die "the scan for '$2' could not be completed" ;;
    esac
}
# …and that guard is exercised, not merely written. A counter that prints a
# plausible number before failing is the shape that made this fail open, so the
# fixture runs `count_claims` under exactly that.
CNTB="$TMP_CL/bin"; mkdir -p "$CNTB"
for b in bash sh grep printf cat rm; do
    _p="$(command -v "$b" 2>/dev/null)" && ln -sf "$_p" "$CNTB/$b"
done
# The class is REMOVED, so the fixture proves independence rather than detection:
# with no `wc` and no `tr` on the PATH at all, the count must still be right. A
# guard against a failing counter would only have held under `pipefail`; not
# needing the counter holds everywhere.
cnt_out="$(PATH="$CNTB" bash -c '
'"$(declare -f count_claims)"'
count_claims "defect" "a defect and another defect"; echo "|rc=$?"' 2>&1)"
case "$cnt_out" in
    '2|rc=0') pass "the count needs no external counter, so a failing one cannot corrupt it" ;;
    *) die "count_claims depends on an external counter ('$cnt_out')" ;;
esac
# The control: with a working counter the same call must still count.
cnt_ok="$(bash -c '
'"$(declare -f count_claims)"'
count_claims "defect" "a defect and another defect"' 2>&1)"
[ "$cnt_ok" = "2" ] \
    && pass "…while a working counter still counts both mentions" \
    || die "count_claims miscounted a known input ('$cnt_ok')"

cl_req 'repairing a consumer a changed validator or producer breaks is finishing the change' \
    'keeps the regression exception to the scope rule' \
    'would have a reader reject a required regression repair'
cl_req 'explains rather than accepts' \
    'says the at-the-site comment explains rather than accepts' \
    'still teaches that an author-created comment is authority'
# The claims stated TWICE in this entry, counted rather than merely present.
# THE TOTAL RECOGNISES THE CLAIM BY ITS SUBJECT, NEVER BY ITS OUTCOME. This is the
# counting equivalent of the polarity trap the whitelists replaced: a total pattern
# reading `defect … stays out of scope` stops matching the moment the entry says
# `stays IN scope`, so the reversed mention leaves BOTH counts, the survivors stay
# equal, and the suite reports clean on a release note that now directs the session
# to widen the PR. The total asks only "is the claim mentioned here"; the qualifier
# asks "does this mention still say the right thing". A total that embeds the
# answer cannot see the mention that got it wrong.
#
# Three mentions of the pre-existing boundary, not two — the `copy in an untouched
# file` form was outside both patterns, so reversing that one counted as nothing.
cl_count '\*{0,2}different pre-existing\*{0,2} (defect|copy)[^.]{0,60}' \
         '\*{0,2}different pre-existing\*{0,2} (defect stays out of scope|copy in an untouched file stays out|defect found nearby is not in scope)' \
         'a different pre-existing defect is OUT of scope'
# THREE mentions, not two. The third — "the same defect in another copy is the
# same finding" — was outside both patterns, so it counted as neither claim nor
# qualifier and the two recognised mentions stayed equal: removing or reversing
# that boundary left the entry stating an unbounded scope rule with the mandatory
# suite reporting clean. A count only guards the occurrences it can see, which is
# the same "somewhere in the file" weakness one level up.
# …and the qualifier requires the POSITIVE OUTCOME, not merely the boundary. Every
# form here named where the copy is and none named what happens to it, so "is part
# of the finding" flipping to "is NOT part of the finding" left the diff bound
# intact, the counts equal at 3/3, and the entry telling the driver to skip an
# in-diff twin — the one thing this rule exists to require.
cl_count '(same defect in a copy|copy of the same defect|same defect in another copy)[^.]{0,80}' \
         '(same defect in a copy this PR also changes is part of the finding and gets fixed with it|A finding names[^.]{0,150}second copy of the same defect \*\*that this PR also changes\*\*|same defect in another copy is the same finding[^.]{0,40}only within what this PR already changes)' \
         'the second-copy requirement is bounded to the diff AND in it'
# The same polarity-free total here. `is a finding` embedded the outcome, so
# `is not a finding` was invisible to the count — the identical defect one call
# down, in a line this PR adds, which makes it part of this finding rather than a
# separate one to defer.
cl_count 'a wrong reply (on an old thread )?is[^.]{0,20}finding[^.]{0,80}' \
         'a wrong reply (on an old thread )?is a finding \*{0,2}only when (its error means )?the (changed )?code is still[[:space:]]*defective' \
         'a wrong reply is a finding only when the CODE is still defective'
# …and the superseded wordings must be absent, because a qualifier present in one
# bullet says nothing about another two paragraphs down.
cl_absent 'defect found nearby is never in scope' 'still says a nearby defect is never in scope'
cl_absent 'a wrong reply is itself a finding'     'still says a wrong reply is itself a finding'
cl_absent 'any second copy of the same defect[.,]( |$)' 'still requires naming a copy outside the diff'
# THE POSITIVE ACCOUNT. Forbidding one phrasing is a blacklist, and "No operational
# behavior changes; this only updates documentation" evades it while making exactly
# the claim that was wrong. The entry has to SAY both halves: which layer is
# unchanged, and that session behaviour is not.
grep -qF 'No **shell-script logic** changes' <<<"$cl_202" \
    && pass "the release entry names the layer that is unchanged" \
    || die "the release entry does not say what is actually unchanged"
grep -qF 'so this release does change how a session behaves' <<<"$cl_202" \
    && pass "…and states that session behaviour does change" \
    || die "the release entry does not say the driver contract changed behaviour"

grep -q 'disposition, never as a description' "$SKILL" \
    && pass "deferrals are recorded as a disposition, not a description" \
    || die "the contract invites a summary that reads as a work order"
# …and NO copy of the summary rule may ask for the reasoning. "what was skipped,
# and why" invites the unfixed defect into the mention, which is the work order.
# Three files carried that wording; fixing one and not the others is how a rule
# survives being reconciled.
# CHANGELOG.md is NOT in this list, and adding it was a mistake I made and am
# undoing: a changelog has to be able to QUOTE a superseded directive in order to
# explain the failure that was fixed — "the old contract said the summary explains
# why" is exactly the sentence a release note needs — and a whole-file ban would
# fail the mandatory suite for describing history correctly. Its current entry is
# checked below instead, positively and scoped to that entry.
for doc in "$SKILL" "$SCRIPT_DIR/../../../CLAUDE.md" "$SCRIPT_DIR/../../../README.md"; do
    [ -f "$doc" ] || { die "missing instruction file: $doc"; continue; }
    dname="$(basename "$doc")"
    dflat="$(tr '\n' ' ' < "$doc" | tr -s ' ')" || { die "$dname: could not read"; continue; }
    # A SET of phrasings, not one literal. The first version matched only
    # `intentionally skipped, and why`, and a third copy of the rule was worded
    # differently — "the summary explains why" — so the check could not see it.
    # Three rounds of this PR each found one more copy; the pattern list is what
    # each of them added, and a new phrasing belongs here rather than being
    # noticed by a reviewer for a fourth time.
    # The pattern set grew again: a fourth copy asked the summary to argue for a
    # BROADER FIX — a design proposal rather than a reason for a skip, different
    # wording, same outcome, because anything in the mention that describes work
    # to be done is read as a work order.
    #
    # Deliberately NOT matched: "say so in the summary" where what is said is a
    # past-tense fact about this round's own checks — the self-check reporting it
    # had nothing in scope. That cannot become a work order, and widening the
    # pattern to catch it would forbid the summary from doing its job.
    dir_rc=0
    grep -qiE \
        'skipped, and why|summary explains why|explains? why it was (skipped|deferred|left)|and why it was (skipped|deferred|left)|(warranted|broader fix)[^.]{0,60}say so in the summary|(the )?(reason|rationale)[^.]{0,40}(not applied|was skipped|for skipping|it was left)' \
        <<<"$dflat" || dir_rc=$?
    case "$dir_rc" in
        0) die "$dname: still asks the summary to explain something that was not done" ;;
        1) pass "$dname: does not invite the deferred defect into the summary" ;;
        *) die "$dname: the summary-directive scan could not be completed" ;;
    esac
done

# ── both reviewer files carry the same context and finding-quality rules ───
# `.github/copilot-instructions.md` restates the policy inline because Copilot
# reads only that file and does not follow pointers, so a rule added to AGENTS.md
# alone reaches one reviewer of two. That asymmetry is the documented reason the
# duplicate exists, which makes it exactly the thing that drifts.
for doc in "$SCRIPT_DIR/../../../AGENTS.md" "$SCRIPT_DIR/../../../.github/copilot-instructions.md"; do
    [ -f "$doc" ] || { die "missing reviewer instruction file: $doc"; continue; }
    name="$(basename "$doc")"
    # DISTINGUISHING text, not a phrase the file already contained. `resolved
    # threads` matched `AGENTS.md`'"'"'s "zero unresolved threads" and the Copilot
    # file'"'"'s "Waivers and resolved threads" heading, so this pair of assertions
    # passed with the reply-context paragraph deleted from both — a guard for
    # duplicate drift that could not see the duplicate drift.
    # FLATTENED before matching. These files are wrapped prose, so a phrase that
    # spans a line break is invisible to line-based grep — the first version of
    # these assertions failed on correct text for exactly that reason.
    flat="$(tr '\n' ' ' < "$doc" | tr -s ' ')" || { die "$name: could not read"; continue; }
    grep -qi 'replies on .*resolved threads' <<<"$flat" \
        && pass "$name: earlier-round replies are named as context" \
        || die "$name: does not tell the reviewer to read earlier thread replies"
    # The PREDICATE, not the phrase: "changed code is still" alone is satisfied by
    # "…is still correct", which reverses the rule while matching the check.
    grep -qi 'changed code is still[[:space:]]*defective' <<<"$flat" \
        && pass "$name: a wrong reply is a finding only if the code is still DEFECTIVE" \
        || die "$name: would have the reviewer block a merge to correct the record"
    # THE CANONICAL CLAUSE, VERBATIM — the prose analogue of the whitelist that
    # settled the endpoint guard.
    #
    # Positive patterns plus negation scans do not converge here. "Include the
    # triggering input" was defeated by "do not include…", then by "include
    # neither… nor…", and "naming any second copy" by "avoid naming…" and then by
    # "omit naming…". Each fix enumerated one more way to negate, and English has
    # no bounded list of those — the same wall the route and command blacklists
    # hit, with no whitelist of commands available because the subject is meaning.
    #
    # What IS bounded is the sentence itself. Requiring the exact clause makes any
    # alteration fail — negated, reworded, or weakened — and the cost is precisely
    # the property wanted for contract text: changing it is a deliberate act that
    # updates this list, not a quiet edit that still satisfies a pattern.
    #
    # THE FIX-SHAPE RULE IS IN THIS LIST FOR BOTH OF THOSE REASONS AT ONCE. It
    # arrived as two substring greps, and each fell to the wall above: `guard where
    # a removal would do` survives "…is **not** a finding", and `which of the two
    # they took and why` survives moving the explanation back to the round summary
    # — which is the regression this round fixed, passing its own check. The two
    # clauses below carry the polarity and the location inside the matched text,
    # so neither edit can be made without failing here.
    case "$name" in
        AGENTS.md)
            req_clauses=(
                '**The loop trusts the `PATH` of the shell it was started from**'
                'A `PATH` check in one helper is a defect, not a fix'
                'the input or state that triggers it** — the concrete case, not the category'
                '**the consequence** — what ends up wrong, in terms of what this tool does'
                'The author is expected to assert the consequence in a test, and can only do that if you state it'
                'if the same defect exists in a second copy **that this PR also changes**, say so'
                '**The fault-tolerance pass needs commits to review.**'
                'A change that offers the pass on an equal-sha head, or that removes the'
                '**A guard where a removal would do is a finding.**'
                'The author is required to say **on the thread** which of the two they took and why'
            ) ;;
        copilot-instructions.md)
            req_clauses=(
                '**The loop trusts the `PATH` of the shell it was started from**'
                'A `PATH` check in one helper is a defect, not a fix'
                'Include the input or state that triggers it — **the concrete case, not the category**'
                'the **consequence** in terms of what this tool does'
                'the author is expected to assert that consequence in a test'
                'naming any second copy of the same defect **that this PR also changes**'
                '**The fault-tolerance pass needs commits to review.**'
                'A change that offers the pass on an equal-sha head, or that removes the'
                '**A guard where a removal would do is a finding.**'
                'The author is required to say **on the thread** which of the two they took and why'
            ) ;;
        *) req_clauses=() ;;
    esac
    for clause in ${req_clauses+"${req_clauses[@]}"}; do
        grep -qF "$clause" <<<"$flat" \
            && pass "$name: states verbatim — ${clause:0:52}…" \
            || die "$name: this required clause is altered or missing — ${clause:0:52}…"
    done
    grep -qi 'proposal, not the finding' <<<"$flat" \
        && pass "$name: a code suggestion is a proposal, not the finding" \
        || die "$name: does not say a code suggestion is only a proposal"
done

# ── A DRIVER TRACING TO STDOUT DOES NOT REACH A CAPTURE ────────────────────
#
# `BASH_XTRACEFD=1` sends xtrace to file descriptor 1, and inside `X="$(cmd)"` fd
# 1 IS the capture — so the trace of `cmd` is assigned to `X` with its output.
# Every substitution in setup was affected: the repository root, the plugin
# discovery, the `mktemp`, the `type -t` probe. The validations then rejected the
# corrupted values, so it failed closed and aborted a session that had nothing
# wrong with it. Issue #92.
#
# STRUCTURAL FIRST: the guard has to precede every substitution in the block, not
# merely exist somewhere in it.
_setup_block="$(awk '/^## Derive identity$/{s=1} s&&/^```bash$/{f=1;next} f&&/^```$/{exit} f' "$SKILL")"     || _setup_block=""
[ -n "$_setup_block" ]     && pass "the setup block lifts out of SKILL.md"     || die "the setup block could not be lifted"
# ONE READER OVER THE FILE, NOT A PIPELINE ENDING IN `head`. `head -1` closes the
# pipe after the first line while the upstream still has ~500 to write; the writer
# takes EPIPE, `pipefail` makes the assignment non-zero, and `set -e` ends the
# whole fixture before any of these assertions run. `awk` reading `$SKILL`
# directly has no pipe to break.
_first_exec="$(awk '/^## Derive identity$/{s=1} s&&/^```bash$/{f=1;next} f&&/^```$/{exit} f&&!/^[[:space:]]*#/&&NF{print;exit}' "$SKILL")"
[ "$_first_exec" = 'if [[ -n "$( RB_TRACE_PROBE=1 )" ]] && ( BASH_XTRACEFD=2 ) 2>/dev/null; then' ] \
    && pass "…and its first executable line moves the trace off the capture" \
    || die "setup runs a substitution before moving the trace (first line: '$_first_exec')"
# AN ASSIGNMENT AND A RESERVED WORD, NOT `set +x`. `set` is a builtin and a
# function shadows it, so a guard written that way is absent in the one shell
# state it exists for. And it must MOVE the trace rather than end it: the operator
# keeps their diagnostics, on the descriptor bash sends them to by default.
# THE CODE, NOT THE COMMENTS. The block explains at length why `set +x` was not
# used, so a scan over the raw text finds that spelling in the prose arguing
# against it and reports the defect the prose exists to prevent.
_setup_code="$(grep -v '^[[:space:]]*#' <<<"$_setup_block")"
# ANY `set +…`, NOT ONE SPELLING. `set +x` and `set +o xtrace` do the same thing,
# and a check for the first stays green for the second — while every behavioural
# case here lifts the guard alone and would miss a disabling line placed after it.
# UNANCHORED, because `set` need not begin the line: `[[ 1 ]] && set +o xtrace`
# and `if x; then set +x; fi` both turn tracing off from the middle of one.
tr_no_set_minus() {   # tr_no_set_minus <code> ; 0 if no `set +…` appears
    local _n
    # `grep -E`, NOT `\b`. Word boundaries are a GNU extension: BSD `grep` can
    # match `\b` literally, so the pattern would find nothing and the check would
    # pass everything — fail-open, on the platform the suite exists to cover.
    _n="$(grep -cE '(^|[^[:alnum:]_])set[[:space:]]*\+' <<<"$1" || true)"
    [ "$_n" -eq 0 ]
}
tr_no_set_minus "$_setup_code" \
    || die "setup turns a shell option off; disabling tracing is what this forbids"
# THE MUTATION IT IS MEANT TO CATCH, run against the check itself.
tr_no_set_minus "$_setup_code
[[ 1 ]] && set +o xtrace" \
    && die "the scan passes a block that disables tracing mid-line; it proves nothing" \
    || pass "…and a 'set +o xtrace' anywhere on a line does fail that scan"
case "$_setup_code" in
    *'set +x'*) die "setup disables tracing through a shadowable name" ;;
    *'BASH_XTRACEFD=2'*) pass "…and moves the trace by assignment rather than disabling it" ;;
    *) die "setup does not move the trace off the capture" ;;
esac
# `BASH_XTRACEFD=` EMPTY IS THE ONE SPELLING THAT MUST NOT APPEAR: bash closes the
# descriptor the variable referred to when it is unset or emptied, so that form
# closes fd 1 outright. Measured — the shell produces no further output at all.
# BOTH SPELLINGS THAT CLOSE THE DESCRIPTOR. `unset BASH_XTRACEFD` and
# `BASH_XTRACEFD=` do the same thing — bash closes the descriptor the variable
# named — and a scan for one of them stays green for the other, which is the
# regression this check exists to stop. The pattern matches an assignment whose
# value does not begin with a digit, so `BASH_XTRACEFD=2` passes and
# `BASH_XTRACEFD=` and `BASH_XTRACEFD=$x` do not.
case "$_setup_code" in
    *'unset BASH_XTRACEFD'*) die "setup unsets BASH_XTRACEFD, which closes the descriptor it named" ;;
    *'BASH_XTRACEFD='[!0-9]*|*'BASH_XTRACEFD=') die "setup assigns BASH_XTRACEFD a non-literal or empty value; empty closes the descriptor it named" ;;
    *) pass "…and never unsets or empties it, either of which closes that descriptor" ;;
esac

# BEHAVIOURAL, ON THE REAL LINES: the repository-root read and the helper-path
# validation, lifted and run under an inherited trace aimed at stdout. Without the
# guard `REPO_DIR` holds a trace line and the path; with it, the path alone.
_tr_block="$(printf '%s\n' "$_setup_block" | sed -n '/^REPO_DIR="\$(git rev-parse/,/could not locate the plugin helper scripts/p')"     || _tr_block=""
case "$_tr_block" in
    *'git rev-parse --show-toplevel'*) pass "…and the repository-root read lifts with it" ;;
    *) die "the repository-root read could not be lifted: '$_tr_block'" ;;
esac
# `die` RECORDS A FAILURE AND RETURNS; it does not end the file. Without the guard
# below, an empty `_tr_dir` sent every path here to `/plug`, so the probe built
# files outside its own scratch tree — or died at an unguarded `mkdir` before
# `RESULT:` was printed at all.
_tr_dir=""
_tr_dir="$(mktemp_d)" || _tr_dir=""
if [ -z "$_tr_dir" ] || [ ! -d "$_tr_dir" ]; then
    die "no scratch directory for the tracing probe"
else
    ( cd "$_tr_dir" && git init -q . ) >/dev/null 2>&1 || die "could not build the tracing probe checkout"
    mkdir -p "$_tr_dir/plug/skills/watch-prs/scripts"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$_tr_dir/plug/skills/watch-prs/scripts/pr-review-state.sh"
    chmod +x "$_tr_dir/plug/skills/watch-prs/scripts/pr-review-state.sh"
    # WITHOUT THE GUARD FIRST, or the case below passes against a shell that never
    # traced anything and proves nothing about the guard.
    _tr_bare="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV CLAUDE_PLUGIN_ROOT="$_tr_dir/plug" \
        SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c '
            '"$_tr_block"'
            printf "REPO_DIR=[%s]\n" "$REPO_DIR"' 2>/dev/null)" || _tr_bare=""
    # THE ASSERTION IS ON THE VARIABLE, not on the run's whole output. `set +x` is
    # itself traced before it takes effect, so the block's stdout legitimately carries
    # one `+ set +x` line — that goes to the operator's terminal, which is where the
    # trace belongs. What must never carry it is a captured value.
    _tr_bare_v="$(printf '%s\n' "$_tr_bare" | awk '/^REPO_DIR=\[/ && !seen {print; seen=1}')"
    # THIS SHELL MAY NOT HAVE THE ROUTE AT ALL, and that is not a failure. bash 3.2.57
    # — which the `macos-shell` job builds and puts first on `PATH` — has no
    # `BASH_XTRACEFD`, so xtrace stays on stderr and nothing can contaminate a
    # capture. Requiring the contamination there would turn that job red over a
    # variable the shell does not implement. The invariant below is asserted either
    # way; only the proof that the route is live is conditional, and which of the two
    # happened is named rather than hidden.
    _tr_route=no
    case "$_tr_bare_v" in
        *'rev-parse'*) _tr_route=yes; pass "…where an inherited trace really does reach the capture" ;;
        *) pass "…(this bash has no BASH_XTRACEFD route to a capture; that half did not run)" ;;
    esac
    # THE GUARD AS SETUP WRITES IT, lifted rather than retyped — a retyped copy proves
    # that some line works, not that the one that ships does.
    _tr_guard="$(printf '%s\n' "$_setup_block" | sed -n '/^if \[\[ -n "\$( RB_TRACE_PROBE=1 )" \]\] &&/,/^fi$/p')"
    case "$_tr_guard" in
        *'BASH_XTRACEFD=2'*) pass "…and the guard lifts out of the block with it" ;;
        *) die "the guard could not be lifted: '$_tr_guard'" ;;
    esac
    _tr_fixed="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV CLAUDE_PLUGIN_ROOT="$_tr_dir/plug" \
        SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c '
            '"$_tr_guard"'
            '"$_tr_block"'
            printf "REPO_DIR=[%s]\n" "$REPO_DIR"' 2>/dev/null)" || _tr_fixed=""
    _tr_fixed_v="$(printf '%s\n' "$_tr_fixed" | awk '/^REPO_DIR=\[/ && !seen {print; seen=1}')"
    { [ "$_tr_fixed_v" = "REPO_DIR=[$(cd "$_tr_dir" && pwd -P)]" ] || [ "$_tr_fixed_v" = "REPO_DIR=[$_tr_dir]" ]; } \
        && pass "…and with the guard the capture holds the path and nothing else" \
        || die "the capture was still corrupted with the guard in place ('$_tr_fixed_v')"
    # AND THE TRACE IS STILL PRODUCED, on stderr. `set +x` would satisfy the line
    # above by taking the operator's diagnostics away for the rest of their session,
    # so this absence check is what separates moving the trace from ending it. Only
    # where the route exists: on a shell without `BASH_XTRACEFD` it was never
    # anywhere else to begin with.
    if [ "$_tr_route" = yes ]; then
        _tr_err="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV CLAUDE_PLUGIN_ROOT="$_tr_dir/plug" \
            SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c '
                '"$_tr_guard"'
                '"$_tr_block"'
                printf "REPO_DIR=[%s]\n" "$REPO_DIR"' 2>&1 >/dev/null)" || _tr_err=""
        case "$_tr_err" in
            *'rev-parse'*) pass "…while the operator's trace still arrives, on stderr" ;;
            *) die "the trace was silenced rather than moved ('$_tr_err')" ;;
        esac
        # AND TRACING IS STILL ON AFTERWARDS, which is the behavioural half of
        # the structural scan above: `set +x`, `set +o xtrace` and anything else
        # that turns the option off all show up here as a missing `x` in `$-`, so
        # no spelling has to be enumerated.
        _tr_still="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV CLAUDE_PLUGIN_ROOT="$_tr_dir/plug" \
            SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c '
                '"$_tr_guard"'
                '"$_tr_block"'
                case $- in *x*) builtin printf "TRACING=[on]\n" ;; *) builtin printf "TRACING=[off]\n" ;; esac' 2>/dev/null)" || _tr_still=""
        case "$_tr_still" in
            *'TRACING=[on]'*) pass "…and the x option is still set after the block runs" ;;
            *) die "setup turned the operator's tracing off ('$_tr_still')" ;;
        esac
        # AND A SHADOWED `set` CHANGES NOTHING, which is the whole reason the guard is
        # an assignment. `set +x` in this position would be a call to that function,
        # leaving the trace on fd 1 and the capture corrupted — in exactly the shell
        # state the guard exists for. `[[` is a reserved word and an assignment is
        # handled by the parser, so neither has a name to take.
        _tr_shadow="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV CLAUDE_PLUGIN_ROOT="$_tr_dir/plug" \
            SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c '
                set() { return 0; }
                unset() { return 0; }
                '"$_tr_guard"'
                '"$_tr_block"'
                printf "REPO_DIR=[%s]\n" "$REPO_DIR"' 2>/dev/null)" || _tr_shadow=""
        _tr_shadow_v="$(printf '%s\n' "$_tr_shadow" | awk '/^REPO_DIR=\[/ && !seen {print; seen=1}')"
        { [ "$_tr_shadow_v" = "REPO_DIR=[$(cd "$_tr_dir" && pwd -P)]" ] || [ "$_tr_shadow_v" = "REPO_DIR=[$_tr_dir]" ]; } \
            && pass "…and a shadowed 'set' does not reach it" \
            || die "a shadowed 'set' left the capture corrupted ('$_tr_shadow_v')"
    # AND THE DRIVING SHELL'S STDOUT SURVIVES IT. bash closes the descriptor
    # `BASH_XTRACEFD` referred to when it is UNSET or emptied; a reassignment is
    # documented to close nothing, and this asserts it on whatever bash runs the
    # suite rather than on the one it was measured against. If some build closes
    # fd 1 here, ordinary output after the guard disappears and this goes red —
    # which is the point: the claim is about a shell, so a shell has to answer it.
    #
    # ORDINARY OUTPUT AND A DUP, because they fail differently: a closed fd 1
    # loses the `printf` while `exec 3>&1` errors, and one case has passed with
    # the other broken.
    _tr_fd="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV CLAUDE_PLUGIN_ROOT="$_tr_dir/plug" \
        SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c '
            '"$_tr_guard"'
            printf "ORDINARY\n"
            exec 3>&1 && printf "DUP\n" >&3' 2>/dev/null)" || _tr_fd=""
    case "$_tr_fd" in
        *ORDINARY*DUP*) pass "…and the driving shell's stdout survives the reassignment" ;;
        *) die "the reassignment closed the shell's stdout ('$_tr_fd')" ;;
    esac
    # EVERY SPELLING BASH RESOLVES TO DESCRIPTOR 1, not just the digit. bash reads
    # `01`, `+1` and ` 1` as fd 1 and a string compare against `1` missed all
    # three — which is why the guard tests the effect instead of the value.
    for _tr_spell in 01 '+1' ' 1'; do
        _tr_alt="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV CLAUDE_PLUGIN_ROOT="$_tr_dir/plug" \
            SHELLOPTS=xtrace BASH_XTRACEFD="$_tr_spell" bash -c '
                '"$_tr_guard"'
                '"$_tr_block"'
                printf "REPO_DIR=[%s]\n" "$REPO_DIR"' 2>/dev/null)" || _tr_alt=""
        _tr_alt_v="$(printf '%s\n' "$_tr_alt" | awk '/^REPO_DIR=\[/ && !seen {print; seen=1}')"
        { [ "$_tr_alt_v" = "REPO_DIR=[$(cd "$_tr_dir" && pwd -P)]" ] || [ "$_tr_alt_v" = "REPO_DIR=[$_tr_dir]" ]; } \
            && pass "…and BASH_XTRACEFD='$_tr_spell' is caught as the descriptor it is" \
            || die "BASH_XTRACEFD='$_tr_spell' left the capture corrupted ('$_tr_alt_v')"
    done
    # ── WHAT A HOSTILE SHELL CAN PUT IN THAT CAPTURE, AND WHAT IS ACCEPTED.
    # The probe runs inside a substitution, so an inherited `DEBUG` trap can write
    # into it and look exactly like a trace that arrived. A shadowed command
    # cannot — the probe is an assignment and runs nothing — which is why that
    # case is asserted strictly above and these are not.
    # Marker schemes were tried against each — the probe's own text, then a pid
    # delivered through `PS4` — and each was forged by the next trap, while every
    # sharper marker added a way to MISS, which is the direction that aborts a
    # valid session. A save-and-restore was tried next and is worse: a startup
    # file pre-seeds the saved value, or the flag validating it, as `readonly`,
    # and the restore then aims the trace wherever that file chose.
    #
    # So the accepted outcome in those shells is that the trace ends on fd 2 —
    # where bash sends xtrace by default, so every line still arrives. Their
    # captures are corrupted by the trap regardless — a shadowed function cannot
    # reach an assignment-only probe, which is why its case above is the strict
    # one — and setup refuses further down. What is asserted here is that NOTHING WORSE happens:
    # the trace is never silenced, and it never lands on a descriptor nobody
    # named.
    tr_hostile() {   # tr_hostile <label> <shell-preamble>
        local _label="$1" _pre="$2" _out
        _out="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV -u SHELLOPTS bash -c '
                exec 7>/dev/null
                BASH_XTRACEFD=7
                '"$_pre"'
                set -x
                '"$_tr_guard"'
                trap - DEBUG 2>/dev/null
                set +x
                builtin printf "FD=[%s]\n" "${BASH_XTRACEFD-unset}"' 2>/dev/null)" || _out=""
        case "$_out" in
            *'FD=[7]'*|*'FD=[2]'*) pass "$_label" ;;
            *) die "$_label — the trace landed somewhere nobody named ('$_out')" ;;
        esac
    }
    # A SHADOWED COMMAND CANNOT REACH THIS PROBE AT ALL, so its case is the
    # strict one: the probe runs no command, and an assignment supplies no name
    # for a function to take, so the target must be untouched rather than merely
    # named.
    _tr_shadow_only="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV -u SHELLOPTS bash -c '
            exec 7>/dev/null
            BASH_XTRACEFD=7
            set -x
            :() { builtin printf marker; }
            printf() { builtin printf marker; }
            '"$_tr_guard"'
            set +x
            builtin printf "FD=[%s]\n" "${BASH_XTRACEFD-unset}"' 2>/dev/null)" || _tr_shadow_only=""
    case "$_tr_shadow_only" in
        *'FD=[7]'*) pass "a shadowed command cannot reach the probe, so the target is untouched" ;;
        *) die "a shadowed command reached the assignment-only probe ('$_tr_shadow_only')" ;;
    esac
    tr_hostile "…and so does a DEBUG trap printing a marker" \
        'set -T; trap "builtin printf marker" DEBUG'
    tr_hostile "…and one echoing \$BASH_COMMAND, which reproduces the probe exactly" \
        'set -T; trap "builtin printf \"%s\n\" \"\$BASH_COMMAND\"" DEBUG'
    tr_hostile "…and one printing the pid, which no marker scheme can outrun" \
        'set -T; trap "builtin printf \"%s:\" \"\$\$\"" DEBUG'
    tr_hostile "…and a readonly PS4, which made the marker schemes blind" \
        'readonly PS4="+ "'
    # NO STATE MEANS NO COLLISION. A startup file that pre-seeds readonly
    # variables named like this block's own — which is what defeated the
    # save-and-restore, three rounds running — must have nothing here to seize.
    #
    # THE WHOLE SHAPE IS ASSERTED, not two retired names. A list of spellings is
    # wrong the first time a new one is written: `RB_TRACE_SAVED` would pass a
    # scan for `RB_XTRACE_SAVED` while reintroducing exactly what it forbids. The
    # guard is three lines; requiring it to BE those three lines admits no fourth.
    _tr_shape="$(grep -v '^[[:space:]]*#' <<<"$_tr_guard" | grep -v '^[[:space:]]*$')"
    [ "$_tr_shape" = 'if [[ -n "$( RB_TRACE_PROBE=1 )" ]] && ( BASH_XTRACEFD=2 ) 2>/dev/null; then
    BASH_XTRACEFD=2
fi' ] \
        && pass "…and the guard is exactly those three lines, so it keeps no state to seize" \
        || die "the guard has grown beyond moving the trace: '$_tr_shape'"
    # AND ACROSS THE WHOLE BLOCK, not only those three lines. A save added after
    # the `fi` and a restore near the end of setup would leave the guard's own
    # shape untouched while reintroducing exactly the collision this removed. Any
    # restore must write `BASH_XTRACEFD` a SECOND time, whatever it names the
    # variable it remembers — so the count is the invariant, and it needs no list
    # of names.
    # THE COUNT IS COMPARED WITH THE GUARD'S OWN, not fixed at one: the guard
    # names `BASH_XTRACEFD` twice, in its writability probe and in the move it
    # gates. What must hold is that NOTHING ELSE in the block names it — a restore
    # has to write it again, wherever it puts the value it remembers.
    _tr_guard_names="$(grep -c 'BASH_XTRACEFD' <<<"$_tr_guard" || true)"
    tr_writes_once() {   # tr_writes_once <block-code> ; 0 if only the guard names it
        local _n
        _n="$(grep -c 'BASH_XTRACEFD' <<<"$1" || true)"
        [ "$_n" -eq "$_tr_guard_names" ]
    }
    tr_writes_once "$_setup_code" \
        && pass "…and only the guard names BASH_XTRACEFD, so nothing restores it" \
        || die "the setup block names BASH_XTRACEFD outside the guard; a restore is back"
    # THE MUTATION IT IS MEANT TO CATCH, run against the check itself: the exact
    # save-and-restore three rounds of review removed.
    tr_writes_once "$_setup_code
RB_TRACE_SAVED=\"\${BASH_XTRACEFD-}\"
BASH_XTRACEFD=\$RB_TRACE_SAVED" \
        && die "the check passes a block that saves and restores the trace target; it proves nothing" \
        || pass "…where a save-and-restore under a new name does fail that check"
    # A READONLY TARGET UNDER `errexit` MUST NOT KILL THE SHELL. A readonly
    # `BASH_XTRACEFD` makes the assignment a FATAL error rather than an ordinary
    # failure — `||` does not catch it and neither does an `if` around it,
    # measured — so under `set -e` an unguarded move ended the operator's
    # long-lived shell where the documented outcome is a refusal further down.
    # The subshell probe confines that, and its status is read in a condition,
    # which `errexit` exempts.
    _tr_roerrexit="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV -u SHELLOPTS bash -c '
            set -e
            export BASH_XTRACEFD=1
            set -x
            readonly BASH_XTRACEFD
            '"$_tr_guard"'
            set +x
            builtin printf "REACHED FD=[%s]\n" "${BASH_XTRACEFD-unset}"' 2>/dev/null)" || _tr_roerrexit=""
    case "$_tr_roerrexit" in
        *'REACHED FD=[1]'*) pass "…and a readonly target under errexit leaves the shell alive and untouched" ;;
        *) die "a readonly BASH_XTRACEFD under errexit ended the shell ('$_tr_roerrexit')" ;;
    esac
    # THE PROBE IS WHAT DOES THAT: the same shell with a bare assignment in that
    # position never reaches the next line.
    _tr_bare_ro="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV -u SHELLOPTS bash -c '
            set -e
            export BASH_XTRACEFD=1
            set -x
            readonly BASH_XTRACEFD
            if [[ -n "$( RB_TRACE_PROBE=1 )" ]]; then BASH_XTRACEFD=2; fi
            set +x
            builtin printf "REACHED\n"' 2>/dev/null)" || _tr_bare_ro=""
    case "$_tr_bare_ro" in
        *REACHED*) die "a bare assignment survived a readonly target under errexit; the case above proves nothing" ;;
        *) pass "…where a bare assignment in the same shell does end it" ;;
    esac
    # A SHELL WITH NO STDERR IS OUT OF REACH, AND FAILS CLOSED. With fd 2 closed
    # bash rejects `BASH_XTRACEFD=2` as an invalid descriptor, so the trace stays
    # on stdout and the captures are contaminated exactly as before — there is no
    # other target to choose, since the one place a trace belongs is the standard
    # error that shell does not have. What must hold is that the corrupted value
    # cannot pass for a path: it is not a directory, so the first use of it
    # refuses.
    _tr_noerr="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV CLAUDE_PLUGIN_ROOT="$_tr_dir/plug" \
        SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c '
            exec 2>&-
            '"$_tr_guard"'
            REPO_DIR="$(git rev-parse --show-toplevel)"
            if [ -d "$REPO_DIR" ]; then builtin printf "USABLE\n"; else builtin printf "REFUSED\n"; fi')" || _tr_noerr=""
    case "$_tr_noerr" in
        *REFUSED*) pass "…and with stderr closed the guard cannot help, but the corrupted value is not a path" ;;
        *) die "a shell with no stderr produced a usable REPO_DIR from a contaminated capture ('$_tr_noerr')" ;;
    esac
    # AND UNDER A READONLY `PS4` THE GUARD STILL PROTECTS THE CAPTURE, which is
    # the direction that actually matters: the pid scheme went blind there,
    # leaving the trace on stdout and aborting a valid checkout.
    _tr_ropstr="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV CLAUDE_PLUGIN_ROOT="$_tr_dir/plug" \
        SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c '
            readonly PS4="+ "
            '"$_tr_guard"'
            '"$_tr_block"'
            printf "REPO_DIR=[%s]\n" "$REPO_DIR"' 2>/dev/null)" || _tr_ropstr=""
    _tr_ropstr_v="$(printf '%s\n' "$_tr_ropstr" | awk '/^REPO_DIR=\[/ && !seen {print; seen=1}')"
    { [ "$_tr_ropstr_v" = "REPO_DIR=[$(cd "$_tr_dir" && pwd -P)]" ] || [ "$_tr_ropstr_v" = "REPO_DIR=[$_tr_dir]" ]; } \
        && pass "…while a readonly PS4 does not blind it to a trace on stdout" \
        || die "a readonly PS4 left the capture corrupted ('$_tr_ropstr_v')"

    # AND A SESSION THAT IS NOT TRACING KEEPS ITS CHOSEN TARGET. `BASH_XTRACEFD=1`
    # with the `x` option off contaminates nothing, and the operator may have set
    # it ready for a later `set -x`; moving it would redirect diagnostics they had
    # not yet asked for.
    _tr_off="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV -u SHELLOPTS CLAUDE_PLUGIN_ROOT="$_tr_dir/plug" \
        BASH_XTRACEFD=1 bash -c '
            '"$_tr_guard"'
            printf "FD=[%s]\n" "${BASH_XTRACEFD-unset}"' 2>/dev/null)" || _tr_off=""
    case "$_tr_off" in
        *'FD=[1]'*) pass "…and an untraced session keeps the target it chose" ;;
        *) die "the guard moved the trace target of a session that was not tracing ('$_tr_off')" ;;
    esac
    # THE SPELLING THAT DOES CLOSE IT, so the case above is not passing because
    # nothing here can close a descriptor at all. `BASH_XTRACEFD=` empties the
    # variable, and the shell's stdout goes with it.
    _tr_empty="$(cd "$_tr_dir" && env -u BASH_ENV -u ENV \
        SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c 'BASH_XTRACEFD=; printf "ORDINARY\n"' 2>/dev/null)" || _tr_empty=""
    case "$_tr_empty" in
        *ORDINARY*) die "emptying BASH_XTRACEFD did not close stdout here; the case above proves nothing" ;;
        *) pass "…where emptying it instead does close that descriptor" ;;
    esac
    fi
fi
[ -n "$_tr_dir" ] && [ -d "$_tr_dir" ] && rm -rf "$_tr_dir"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
