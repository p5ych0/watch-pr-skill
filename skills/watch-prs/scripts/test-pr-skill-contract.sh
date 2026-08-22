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
grep -qF 'export REVIEW_BUS_REMOTE="$RB_REMOTE"' <<<"$skill_flat" \
    && pass "the session's repository is pinned into the environment every helper reads" \
    || die "SKILL.md does not export REVIEW_BUS_REMOTE; a cd mid-session retargets every stage"
# …FROM A HELPER REACHED BY PATH, AND WITH ITS STATUS TAKEN. This was
# `git remote get-url origin` inline, which is a NAME: a function answering only
# that subcommand forged the identity every stage is then addressed by. The helper
# cannot be shadowed and steps out of the startup hooks; `test-pr-origin.sh` runs
# both attacks against it. The status still matters — a read that prints and then
# fails would otherwise pin the session to whatever it emitted. #84.
grep -qF '/usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh read "$RB_TRY/origin"' <<<"$skill_flat" \
    && pass "…from a helper reached by path, with its status taken" \
    || die "the pinned remote is not read through pr-origin.sh, or its status is unchecked"
# …AND THAT IS ASSERTED BY RUNNING IT, because the line above finds the call and
# not the handler after it. Deleting the `||` arm leaves this grep matching and
# leaves the claim "with its status taken" false, and what gets through is the
# case the whole helper exists for: a read that writes a plausible URL and then
# fails is accepted, and the session is pinned to it.
_read_block=""
_read_block="$(awk '/^RB_TMPDIR=$/, /there is no repository to pin this session to/' "$SKILL")" \
    || _read_block=""
{ [ -n "$_read_block" ] \
  && case "$_read_block" in *'/pr-origin.sh read "$RB_TRY/origin"'*) true ;; *) false ;; esac \
  && case "$_read_block" in *'mkdir -m 700'*) true ;; *) false ;; esac \
  && case "$_read_block" in *'for RB_TMPPARENT in'*) true ;; *) false ;; esac; } \
    && pass "…and the read lifts out of SKILL.md with its transport directory" \
    || die "the read block is truncated or has lost its directory: '$_read_block'"
# ── the transport path cannot be built without a directory ────────────────
# `exit` is a builtin the operator's shell can replace with one that RETURNS, and
# every refusal in the block above then prints its message and CARRIES ON — to the
# line that builds `$RB_TMPDIR/origin`, which with an empty value is `/origin`.
# The ownership test is `[[ -O ]]`, so a root operator with a root-owned file
# there reads it as this session's origin, the `rm -f` below DELETES it, and the
# cleanup arms run `rmdir "$RB_TMPDIR"` — `rmdir /`. #151.
#
# AN EXPANSION, NOT AN `if`. A parameter expansion error ends a non-interactive
# shell where it stands: no command name to shadow, no `exit` to neutralise, and
# it names the variable. The `if` was tried and taken back, because inside a
# compound command a failed readonly assignment ends the shell BEFORE the guard
# that would have named it — `RB_ORIGIN_OUT` and `RB_REMOTE` lost their own
# diagnostics to gain this one, which the cases below this file already prove.
grep -qF 'RB_ORIGIN_OUT="${RB_TMPDIR:?' "$SKILL" \
    && pass "the transport path requires its directory through the expansion that builds it" \
    || die "SKILL.md builds \$RB_TMPDIR/origin without requiring the directory; an emptied one is /origin"
# AND THE MESSAGE CARRIES NO APOSTROPHE. Bash parses the `:?` word specially, so a
# `'` inside it opens a quote even within double quotes and the whole block stops
# parsing — measured, `X="${V:?a session's origin}/o"` is `unexpected EOF`. A
# fixture is the only thing that would notice, because the block that stops
# parsing is the one nothing here executes.
_rb_qm="$(grep -o 'RB_ORIGIN_OUT="${RB_TMPDIR:?[^}]*}' "$SKILL" || true)"
case "$_rb_qm" in
    *"'"*) die "the transport path's :? message contains an apostrophe; the setup block will not parse" ;;
    *)     pass "…and that requirement's message cannot break the block it lives in" ;;
esac
# AND IT IS RUN. The lift already in hand is the block itself; with no usable
# parent and `exit` neutralised, what must come out is the expansion's refusal
# naming RB_TMPDIR, and what must NOT is any sign of the read continuing.
_rb_ex=""
_rb_ex="$(mktemp_d)" || _rb_ex=""
{ [ -n "$_rb_ex" ] && [ -d "$_rb_ex" ]; } \
    || die "no scratch directory for the transport-path case; it proves nothing"
if [ -n "$_rb_ex" ] && [ -d "$_rb_ex" ]; then
    printf '%s\n' "$_read_block" > "$_rb_ex/blk.sh"
    _rb_ex_out="$(run_limited 25 env -u SHELLOPTS -u BASH_ENV -u ENV \
        RB_SCRIPTS="$_rb_ex" TMPDIR="$_rb_ex" bash --noprofile --norc -c '
exit() { return 0; }
readonly RB_TMPPARENT=/nonexistent-parent-for-this-case
. "$1"
printf "REACHED origin_out=[%s]\\n" "${RB_ORIGIN_OUT:-unset}"' _ "$_rb_ex/blk.sh" 2>&1 || true)"
    printf '%s' "$_rb_ex_out" | grep -qF 'RB_TMPDIR: no transport directory was established' \
        && pass "…so a walked-past refusal stops at the expansion, naming the directory it lacks" \
        || die "the transport-path case gave '$_rb_ex_out'"
    printf '%s' "$_rb_ex_out" | grep -qF 'REACHED' \
        && die "…but the block carried on past it: '$_rb_ex_out'" \
        || pass "…and nothing after it runs"
    rm -rf "$_rb_ex" 2>/dev/null || true
fi
# THE FORGED HELPER WRITES A USABLE VALUE AND THEN CHOOSES ITS STATUS, which is
# the only shape that separates the two behaviours: one that failed to write would
# be refused by the emptiness check further down, and the block would look correct
# with no handler at all.
_forge_dir=""
_forge_dir="$(mktemp_d)" || die "no scratch directory for the read-status probe"
# EVERY TRANSPORT DIRECTORY THESE CASES MAKE LANDS UNDER IT. The lifted blocks
# create their own, as setup does, and the cleanup probe near the end of this file
# runs the whole fixture with `TMPDIR` pointed at a scratch tree and fails if
# anything is left in it — so a `mktemp -d` taking the ambient `TMPDIR` here is
# reported as the leak it is.
[ -n "$_forge_dir" ] && export RB_TMPBASE="$_forge_dir"
if [ -n "$_forge_dir" ]; then
    cat > "$_forge_dir/pr-origin.sh" <<'FORGE'
#!/usr/bin/env bash
printf '%s\n' "git@github.com:acme/widget.git" > "$2"
exit "${FORGE_RC:-0}"
FORGE
    _rs_rc=0
    _rs_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=1 TMPDIR="$_forge_dir" bash -c '
            '"$_read_block"'
            echo "PINNED=$RB_REMOTE"
        ' 2>&1)" || _rs_rc=$?
    { [ "$_rs_rc" -ne 0 ] \
      && case "$_rs_out" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "…so a helper that writes a URL and then fails does not pin the session" \
        || die "setup pinned the session from a failed read (rc=$_rs_rc out='$_rs_out')"
    # THE ORDINARY CASE STILL PASSES THROUGH, or a block that aborted on every
    # read would satisfy the case above while starting no session at all.
    _rs_rc=0
    _rs_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=0 TMPDIR="$_forge_dir" bash -c '
            '"$_read_block"'
            echo "PINNED=$RB_REMOTE"
        ' 2>&1)" || _rs_rc=$?
    { [ "$_rs_rc" -eq 0 ] \
      && case "$_rs_out" in *'PINNED=git@github.com:acme/widget.git'*) true ;; *) false ;; esac; } \
        && pass "…while a helper that succeeds pins the value it wrote" \
        || die "the read block refused a good read (rc=$_rs_rc out='$_rs_out')"
    # …AND A SHADOWED `rm` CANNOT REWRITE THE VALUE BETWEEN THE READ AND THE
    # CHECK. `rm` is a name, and setup ran one immediately after the protected
    # read and before `$RB_REMOTE` was validated or exported — so a function by
    # that name in the driving shell replaced the pin the helper had just been
    # hardened to deliver, and everything the session posted went to the forged
    # repository. The helper cannot see this: it did its job.
    _rm_rc=0
    _rm_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=0 \
        TMPDIR="$_forge_dir" \
        'BASH_FUNC_rm%%=() { RB_REMOTE="git@github.com:WRONG/other.git"; return 0; }' bash -c '
            '"$_read_block"'
            echo "PINNED=$RB_REMOTE"
        ' 2>&1)" || _rm_rc=$?
    case "$_rm_out" in
        *WRONG/other*) die "a shadowed rm rewrote the pinned remote: '$_rm_out'" ;;
        *)             pass "…and a shadowed rm cannot rewrite the value it cleans up after" ;;
    esac
    # THE FIXTURE'S OWN REACH, so the case above cannot pass by the forger never
    # arriving. The same function, in front of a bare `rm`, must land.
    _rmreach="$(env -u SHELLOPTS -u BASH_ENV -u ENV \
        'BASH_FUNC_rm%%=() { RB_REMOTE="git@github.com:WRONG/other.git"; return 0; }' bash -c '
            RB_REMOTE="git@github.com:acme/widget.git"
            rm -f /dev/null
            printf %s "$RB_REMOTE"' 2>/dev/null)"
    [ "$_rmreach" = "git@github.com:WRONG/other.git" ] \
        && pass "…where the same function reaches an rm called by name" \
        || die "the rm forger does not arrive at all (got '$_rmreach'); the case above proves nothing"
    # …AND A TRANSPORT FILE THIS USER DID NOT CREATE IS REFUSED. This is what
    # makes a replaced transport directory harmless, and it is the assertion the
    # substitution cannot satisfy: an account that swaps the directory can put
    # anything at the path, but not a file THIS user owns, because a file belongs
    # to whoever created it. A symlink is the way that check gets satisfied by
    # something of ours, so `-h` is asserted with it — and it is also the only
    # form of the attack a fixture can stage without a second uid.
    cat > "$_forge_dir/pr-origin-swap.sh" <<'SWAP'
#!/usr/bin/env bash
rm -f "$2"
ln -s /etc/hostname "$2"
exit 0
SWAP
    mkdir -p "$_forge_dir/swap"
    cp "$_forge_dir/pr-origin-swap.sh" "$_forge_dir/swap/pr-origin.sh"
    if [ -e /etc/hostname ] && [ ! -O /etc/hostname ]; then
        _sw_rc=0
        _sw_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir/swap" \
            TMPDIR="$_forge_dir" bash -c '
                '"$_read_block"'
                echo "PINNED=$RB_REMOTE"
            ' 2>&1)" || _sw_rc=$?
        { [ "$_sw_rc" -ne 0 ] \
          && case "$_sw_out" in *'not the one this setup created'*) true ;; *) false ;; esac \
          && case "$_sw_out" in *PINNED=*) false ;; *) true ;; esac; } \
            && pass "…and a transport file this setup did not create is refused" \
            || die "setup pinned from a substituted transport file (rc=$_sw_rc out='$_sw_out')"
    else
        echo "ok   - (no unowned file to point a symlink at; the substituted-file case did not run)"
    fi
    # …AND A REFUSAL LEAVES THE PARENT EMPTY. The directory used to stand from its
    # allocation until the pin at the end of setup, with eight aborts in between —
    # an empty origin, a multi-line one, an unparseable identity, a summary file
    # that could not be created — each leaving a private `watch-pr.*` nothing else
    # can remove. It is removed as soon as its value has been read instead, so
    # what is asserted is not "the abort cleans up" but that there is nothing left
    # to clean up by then.
    #
    # A ONE-LINE LOCAL PATH IS THE VALUE USED, because it is the one that gets
    # furthest: `pr-origin.sh` accepts it and so does every check in this block,
    # and it is `rb_identity` — past the end of the lift — that refuses it. So
    # this asserts the state the rest of setup inherits: the block returns having
    # left nothing behind, whatever happens next.
    _lk_dir=""
    _lk_dir="$(mktemp_d)" || die "no scratch directory for the leftover probe"
    if [ -n "$_lk_dir" ]; then
        cat > "$_forge_dir/pr-origin-local.sh" <<'LOCAL'
#!/usr/bin/env bash
printf '%s
' "/home/somebody/a-checkout" > "$2"
exit 0
LOCAL
        mkdir -p "$_forge_dir/local"
        cp "$_forge_dir/pr-origin-local.sh" "$_forge_dir/local/pr-origin.sh"
        env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir/local" \
            TMPDIR="$_lk_dir" bash -c '
                '"$_read_block"'
                echo "PINNED=$RB_REMOTE"
            ' >/dev/null 2>&1
        _lk_left="$(ls -A "$_lk_dir" 2>/dev/null)"
        [ -z "$_lk_left" ] \
            && pass "…and a setup that refuses later leaves no transport directory behind" \
            || die "a refused setup left the transport directory: '$_lk_left'"
        rm -rf "$_lk_dir"
    fi
    # …AND A READONLY TRANSPORT VARIABLE STOPS SETUP RATHER THAN BEING IGNORED.
    # The driving session's shell is long-lived, so `RB_ORIGIN_OUT` can already
    # exist as a readonly naming a file somebody else can write. The assignment
    # then fails, the variable keeps the old path, and the helper writes a
    # perfectly good value into a file the attacker edits before the read.
    _ro_out=""
    _ro_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=0 \
        TMPDIR="$_forge_dir" bash -c '
            readonly RB_ORIGIN_OUT="'"$_forge_dir"'/elsewhere"
            '"$_read_block"'
            echo "PINNED=$RB_REMOTE"
        ' 2>&1)" || true
    case "$_ro_out" in
        *PINNED=*) die "a readonly RB_ORIGIN_OUT was ignored and setup pinned anyway: '$_ro_out'" ;;
        *)         pass "…and a readonly RB_ORIGIN_OUT stops setup rather than being ignored" ;;
    esac
    # …AND A READONLY `RB_REMOTE` IS REFUSED RATHER THAN KEPT. The driving shell
    # is long-lived and interactive; a readonly `RB_REMOTE` already in it survives
    # the assignment, and the checks that follow — non-empty, single-line,
    # parseable — all pass on the stale URL, which is then exported and addressed
    # by every later post. The comparison is against the same open descriptor the
    # value came from, so it cannot be satisfied by a second look at the path.
    _rr_out=""
    _rr_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=0 \
        TMPDIR="$_forge_dir" bash -c '
            readonly RB_REMOTE="git@github.com:WRONG/other.git"
            '"$_read_block"'
            echo "PINNED=$RB_REMOTE"
        ' 2>&1)" || true
    case "$_rr_out" in
        *WRONG/other*) die "a readonly RB_REMOTE survived and setup pinned it: '$_rr_out'" ;;
        *)             pass "…and a readonly RB_REMOTE is refused rather than pinned" ;;
    esac
    # …AND A RELATIVE CANDIDATE FALLS THROUGH RATHER THAN ABORTING THE SESSION.
    # The helper walks every component of the output path to the root, so it
    # refuses a relative one — and a relative but perfectly usable `TMPDIR` such
    # as `.tmp` was selected here and refused there, ending a session that had a
    # working fallback next to it.
    # THE RELATIVE DIRECTORY HAS TO EXIST AND BE OURS, or `-d` rejects it and the
    # fallback happens for the wrong reason — the case then passes against the
    # unfixed code, which is what it did on the first attempt.
    mkdir -p "$_forge_dir/.tmp"
    _rel_rc=0
    _rel_out="$(cd "$_forge_dir" && env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=0 \
        TMPDIR=.tmp HOME="$_forge_dir" bash -c '
            '"$_read_block"'
            echo "PARENT=$RB_TMPPARENT"
            echo "PINNED=$RB_REMOTE"
        ' 2>&1)" || _rel_rc=$?
    { [ "$_rel_rc" -eq 0 ] \
      && case "$_rel_out" in *"PARENT=$_forge_dir"*) true ;; *) false ;; esac; } \
        && pass "…and a relative TMPDIR falls through to HOME instead of ending the session" \
        || die "a relative TMPDIR was selected or refused (rc=$_rel_rc out='$_rel_out')"
    # …AND A RELATIVE `HOME` IS REFUSED HERE, in these words, rather than in the
    # helper's — the abort a reader can act on names the two variables it read.
    mkdir -p "$_forge_dir/.home"
    _relh_rc=0
    _relh_out="$(cd "$_forge_dir" && env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=0 \
        TMPDIR=.tmp HOME=.home bash -c '
            '"$_read_block"'
            echo "PINNED=$RB_REMOTE"
        ' 2>&1)" || _relh_rc=$?
    { [ "$_relh_rc" -ne 0 ] \
      && case "$_relh_out" in *"absolute directory this user owns"*) true ;; *) false ;; esac \
      && case "$_relh_out" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "…while a relative HOME is refused by name" \
        || die "a relative HOME was accepted (rc=$_relh_rc out='$_relh_out')"
    # …AND A READONLY `RB_TMPDIR` DOES NOT BECOME THE CHOSEN ONE. The loop reads
    # that variable to decide it succeeded, so a readonly one in the driving shell
    # survives the reset AND the assignment, the break happens anyway, and setup
    # opens the STALE directory's `origin` instead of the one it just verified —
    # which passes `-O`/`-f` if that directory is the operator's own.
    # THE STALE DIRECTORY HOLDS A PLAUSIBLE, OPERATOR-OWNED VALUE, which is the
    # whole point: an empty or absent one is refused by the open that follows, so
    # the case would pass with the postcondition removed and prove nothing. This
    # is the shape that gets through — the file is ours, so `-O` and `-f` accept
    # it and the forged remote is exported.
    mkdir -p "$_forge_dir/stale"
    printf '%s\n' 'git@github.com:WRONG/other.git' > "$_forge_dir/stale/origin"
    _st_rc=0
    _st_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=0 \
        TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            readonly RB_TMPDIR="'"$_forge_dir"'/stale"
            '"$_read_block"'
            echo "PINNED=$RB_REMOTE"
        ' 2>&1)" || _st_rc=$?
    { [ "$_st_rc" -ne 0 ] \
      && case "$_st_out" in *WRONG/other*) false ;; *) true ;; esac \
      && case "$_st_out" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "…and a readonly RB_TMPDIR stops setup rather than becoming the chosen directory" \
        || die "a readonly RB_TMPDIR was accepted (rc=$_st_rc out='$_st_out')"
    # …AND A READONLY `RB_TMPPARENT` IS NAMED, not left to look like a bad TMPDIR.
    # `for` cannot report that its control variable is unassignable: every
    # iteration fails silently, no candidate is tried, and the refusal at the end
    # blames `TMPDIR` and `HOME` — sending the operator to look at an environment
    # that is fine. A usable fallback is supplied here, so the only reason to stop
    # is the readonly itself.
    #
    # THE READONLY HOLDS THE PROBE'S OWN VALUE, which is the case a single
    # assignment IN THIS SHELL cannot see: the failed assignment leaves exactly
    # what the postcondition expects, so the guard passes and every `for`
    # assignment then fails silently. Two unequal probes ruled it out and are gone;
    # the SUBSHELL rules it out with one, because there the same readonly makes the
    # assignment fail outright and the comparison inside is never reached. That
    # comparison is what catches the other half — a TRANSFORMING attribute such as
    # `declare -i`, where the assignment succeeds and stores something else. #148,
    # and #150 for the fourth site.
    _rp2_rc=0
    _rp2_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=0 \
        TMPDIR="$_forge_dir" HOME="$_forge_dir" bash -c '
            readonly RB_TMPPARENT=probe-a
            '"$_read_block"'
            echo "PINNED=$RB_REMOTE"
        ' 2>&1)" || _rp2_rc=$?
    { [ "$_rp2_rc" -ne 0 ] \
      && case "$_rp2_out" in *'RB_TMPPARENT is readonly'*) true ;; *) false ;; esac \
      && case "$_rp2_out" in *PINNED=*) false ;; *) true ;; esac; } \
        && pass "…and a readonly RB_TMPPARENT is refused by name, not blamed on TMPDIR" \
        || die "a readonly RB_TMPPARENT was mis-reported (rc=$_rp2_rc out='$_rp2_out')"
    # …AND A PARENT THIS USER NEITHER OWNS NOR IS PROTECTED BY STICKY SEMANTICS IS
    # REFUSED BEFORE ANYTHING IS CREATED IN IT. Mode 700 protects what is inside
    # the directory and not the entry naming it: on a shared, non-sticky `TMPDIR`
    # another account can observe the name, rename the directory without entering
    # it, and leave a writable one of its own at that path — after which the value
    # read back is theirs.
    #
    # `/usr` IS THE NEGATIVE CASE because it is owned by root, so an ordinary user
    # fails `-O` against it. BOTH candidates are pointed at it: the rule tries
    # `TMPDIR` and then `HOME`, so leaving `HOME` alone would land the transport
    # in a directory the user does own and prove nothing. Running as root — or
    # anywhere `-O /usr` holds — there is no such directory to point at, and the
    # case says so rather than asserting something it cannot set up.
    if [ -d /usr ] && [ ! -O /usr ]; then
        _rp_rc=0
        _rp_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=0 \
            TMPDIR=/usr HOME=/usr bash -c '
                '"$_read_block"'
                echo "PINNED=$RB_REMOTE"
            ' 2>&1)" || _rp_rc=$?
        # THE REASON IS ASSERTED, NOT ONLY THE REFUSAL. `/usr` is unwritable as
        # well as unowned, so `mkdir` fails there on its own — a case that
        # accepted any non-zero status passed unchanged against a parent check
        # weakened to `[[ -d … ]]`, which is the whole defect. What must be true
        # is that setup stopped BEFORE creating anything, and only the check's
        # own words say that happened.
        { [ "$_rp_rc" -ne 0 ] \
          && case "$_rp_out" in *'directory this user owns'*) true ;; *) false ;; esac \
          && case "$_rp_out" in *'could not create a private directory'*) false ;; *) true ;; esac \
          && case "$_rp_out" in *PINNED=*) false ;; *) true ;; esac; } \
            && pass "…and a parent another account could replace the directory in is refused" \
            || die "setup built its transport in a replaceable parent (rc=$_rp_rc out='$_rp_out')"
    else
        echo "ok   - (no unowned non-sticky directory available; the replaceable-parent case did not run)"
    fi
    # …AND A SHARED STICKY `TMPDIR` FALLS BACK TO `HOME` RATHER THAN BEING USED.
    # `/tmp` IS SAFE AND IS USED, which is what distinguishes it from the case
    # above: root owns it and it is sticky, so nobody may rename another account's
    # entries there, and the components above belong to root — who can replace this
    # script anyway. An ATTACKER-owned sticky directory is the unsafe one, because
    # sticky says nothing about its owner renaming ours. A driver rule of
    # "owned by this user" refused `/tmp` and was stricter than the helper's own,
    # which is the mismatch that ended valid sessions.
    if [ -d /tmp ] && [ ! -O /tmp ]; then
        _sp_rc=0
        _sp_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=0 \
            TMPDIR=/tmp HOME="$_forge_dir" bash -c '
                '"$_read_block"'
                echo "PARENT=$RB_TMPPARENT"
                echo "PINNED=$RB_REMOTE"
            ' 2>&1)" || _sp_rc=$?
        { [ "$_sp_rc" -eq 0 ] \
          && case "$_sp_out" in *'PINNED=git@github.com:acme/widget.git'*) true ;; *) false ;; esac \
          && case "$_sp_out" in *'PARENT=/tmp'*) true ;; *) false ;; esac; } \
            && pass "…while a sticky TMPDIR nobody here owns is accepted, as /tmp is" \
            || die "a shared sticky TMPDIR was refused (rc=$_sp_rc out='$_sp_out')"
    else
        echo "ok   - (/tmp is absent or owned by this user; the fallback case did not run)"
    fi
    # …AND AN OWNED `TMPDIR` IS STILL USED, or the rule would move every session's
    # transport into the home directory whether or not it needed to.
    _op_rc=0
    _op_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=0 \
        TMPDIR="$_forge_dir" HOME=/usr bash -c '
            '"$_read_block"'
            echo "PARENT=$RB_TMPPARENT"
            echo "PINNED=$RB_REMOTE"
        ' 2>&1)" || _op_rc=$?
    { [ "$_op_rc" -eq 0 ] \
      && case "$_op_out" in *"PARENT=$_forge_dir"*) true ;; *) false ;; esac; } \
        && pass "…and a TMPDIR this user owns is used as it stands" \
        || die "an owned TMPDIR was not used (rc=$_op_rc out='$_op_out')"
    # …AND THE TRANSPORT DIRECTORY IS EXCLUSIVE. `mkdir` is what makes the name
    # being guessable a nuisance rather than a substitution: an account that
    # pre-creates it stops this session instead of supplying it a repository.
    _sq_rc=0
    _sq_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=0 \
        TMPDIR="$_forge_dir" bash -c '
            RANDOM=1
            _sq_seed="$TMPDIR/watch-pr.$$.$RANDOM$RANDOM$RANDOM"
            mkdir -p "$_sq_seed"
            printf '%s\n' "$_sq_seed" > "$TMPDIR/.sq-dir"
            RANDOM=1
            '"$_read_block"'
            echo "PINNED=$RB_REMOTE"
        ' 2>&1)" || _sq_rc=$?
    _sq_dir="$(cat "$_forge_dir/.sq-dir" 2>/dev/null)"
    # THE DIRECTORY IS NOT REUSED, AND THE SESSION IS NOT ENDED EITHER — a guessed
    # name is a reason to use a different directory, not to stop. `mkdir`
    # fails on a name that exists, which is what makes squatting useless; since
    # the loop offers candidates rather than deciding, that failure moves to the
    # next one instead of aborting. What must hold is that the pre-created
    # directory is not the one used — an account that guesses the name gets
    # nothing, and the operator keeps their session.
    { [ "$_sq_rc" -eq 0 ] \
      && case "$_sq_out" in *'PINNED=git@github.com:acme/widget.git'*) true ;; *) false ;; esac \
      && [ ! -e "$_sq_dir/origin" ]; } \
        && pass "…and a pre-created transport directory is passed over, not reused" \
        || die "setup reused a directory it did not create (rc=$_sq_rc out='$_sq_out')"
fi
# …AND THE PIN IS PROVED THROUGH THE SAME HELPER, for the same reason: `bash -c`
# is a name, and a function called `bash` inherits NON-exported variables, so it
# agrees the pin arrived while the real stages inherit nothing.
#
# THE VALUE COMES BACK IN A FILE, WHICH IS WHAT THE ASSERTIONS PIN. It travelled
# on stdout, then on fd 9, then on fd 9 with `BASH_XTRACEFD` moved out of the way —
# and each mechanism put the value on a stream some caller traces to. The last one
# was worse than a leak: bash CLOSES the descriptor `BASH_XTRACEFD` referred to
# when it is unset, so restoring it closed fd 2 and the next call in the session
# returned nothing at all. A path cannot collide with a descriptor.
#
# `/usr/bin/env` IS ASSERTED WITH IT, because `bash` is a name: written as
# `bash -p …` the call goes to a function called `bash` if the driving shell has
# one, and such a function writes a forged URL to the transport file it was handed
# and returns, without the helper running at all. A path cannot be shadowed.
#
# `bash -p` IS ASSERTED WITH THEM, and it is the caller's part of the defence:
# privileged mode is what stops `BASH_ENV` being sourced, so it has to be in force
# before the helper's first line. A hook needs to shadow nothing to use the gap —
# one that writes that same file and exits is a complete attack.
#
# WHAT IS ASSERTED IS THE WHOLE INVOCATION, AND THERE IS NO LONGER ANYTHING ELSE
# IN IT. Earlier versions of this comment required a brace group and `9>&1 1>&2`,
# and required them for a real reason: bash traces a simple command BEFORE
# applying its redirections, so inside a command substitution the trace landed in
# the value ahead of the URL, and the group took the redirections first. None of
# it survives the move to a file — the call is a plain command whose output nobody
# captures — and the paragraph is rewritten rather than left, because it described
# assertions these greps do not make and pointed a maintainer back at the design
# that produced the failure.
grep -qF '/usr/bin/env bash -p "$RB_SCRIPTS"/pr-origin.sh pin "$RB_PIN_OUT"' <<<"$skill_flat" \
    && pass "…and the pin is proved by a real child, not by a shell copy" \
    || die "the pin proof does not go through pr-origin.sh"
# …AND BEFORE THE IDENTITY IS DERIVED FROM IT. Exporting after `rb_identity` would
# leave the driver's OWN `$HOST/$OWNER/$REPO` derived from the current directory
# while every child used the pin — two identities in one session, agreeing
# whenever this defect is absent and disagreeing exactly when it is not.
# …AND THE DRIVER'S OWN IDENTITY COMES FROM THE SAME VALUE, through a command
# prefix rather than through the export. Deriving it separately would leave the
# driver's `$HOST/$OWNER/$REPO` from the current directory while the children used
# the pin — two identities agreeing whenever this defect is absent and disagreeing
# exactly when it is not — and taking it from the export would make it depend on
# the export having succeeded, which is the failure the guard exists for.
grep -qF 'REVIEW_BUS_REMOTE="$RB_REMOTE" rb_identity \' <<<"$skill_flat" \
    && pass "…and the driver derives its own identity from that same pinned value" \
    || die "rb_identity does not take the pinned remote; the driver and its children can disagree"
# …AND THE PIN IS THE LAST THING SETUP DOES. Either hostile state alone is caught:
# a readonly makes the export return 1, and a shadowed `export` leaves the value
# wrong for the postcondition. TOGETHER with a shadowed `exit` they are not, if
# anything follows — the guard ends the `if` non-zero and, with no `set -e`, the
# next statement runs anyway. Position is what makes the stop structural, so the
# position is asserted.
# EXACT, NOT A FILTER. The first version of this listed the shapes it would allow
# after the pin — and `echo` was on that list, because the guard itself contains
# two. An added `echo "one more setup step"` was therefore invisible to the check
# written to forbid exactly that, and the mutation passed. What is asked here is
# not "does anything unusual follow" but "does ANYTHING follow": the next
# meaningful line after the guard's `fi` must be the closing fence.
_pin_ln=""; _pin_ln="$(grep -n '^export REVIEW_BUS_REMOTE=' "$SKILL" | head -1 | cut -d: -f1)" || _pin_ln=""
_pin_fi=""
_pin_fi="$(awk -v n="${_pin_ln:-0}" 'NR>n && /^fi$/ {print NR; exit}' "$SKILL")" || _pin_fi=""
_next=""
_next="$(awk -v n="${_pin_fi:-0}" 'NR>n && NF && !/^#/ {print $0; exit}' "$SKILL")" || _next=""
{ [ -n "$_pin_ln" ] && [ -n "$_pin_fi" ] && [ "$_next" = '```' ]; } \
    && pass "…and nothing in setup runs after the pin, so a neutralised abort cannot be stepped over" \
    || die "setup continues past the repository pin (pin=$_pin_ln fi=$_pin_fi next='$_next')"
# …AND SETUP'S SUCCESS LINE IS INSIDE THE SUCCESSFUL BRANCH. Below the `fi` it
# would run whatever the pin did, once `exit` is shadowed — the driver would be
# told setup completed with no pin in place, which is the whole failure.
#
# TWO BRANCHES DEEP NOW, and the outer one is what a walked-past refusal cannot
# reach: a readonly `RB_PIN_SEEN` pre-seeded to the real remote survives the reset,
# so the probe's empty answer cannot overwrite it and the equality would agree on a
# pin no child ever saw. The refusal is the outer `if`'s FIRST arm, so the probe
# and the success line both sit in its `else` — unreachable whatever `exit` does.
_pin_body=""
_pin_body="$(awk -v a="${_pin_ln:-0}" -v b="${_pin_fi:-0}" 'NR>a && NR<b' "$SKILL")" || _pin_body=""
_pin_refuse=""
_pin_refuse="$(printf '%s\n' "$_pin_body" | sed -n '1,/^else$/p')" || _pin_refuse=""
_pin_then=""
_pin_then="$(printf '%s\n' "$_pin_body" | sed -n '/^else$/,$p')" || _pin_then=""
# THE PIN PROBE IS ONE BRANCH, AND EACH ARM IS EXTRACTED BY ITS OWN HEADER. Every
# refusal is an arm rather than a guard, because `exit` is a name: a guard a
# shadowed one walks past lands in the probe, where a pre-seeded readonly
# `RB_PIN_SEEN` certifies a pin no child ever saw. And the assignments are proved
# BEFORE the `mkdir`, so a refusal happens while there is still nothing to clean
# up — a failed readonly assignment can end the shell where it stands, which would
# otherwise leave the directory behind with nobody to remove it.
_arm_out=""
_arm_out="$(printf '%s\n' "$_pin_body" | sed -n '/^if \[\[ $RB_PIN_OUT != /,/^elif \[\[ $RB_PIN_SEEN != probe-a/p')" || _arm_out=""
_arm_seen=""
_arm_seen="$(printf '%s\n' "$_pin_body" | sed -n '/^elif \[\[ $RB_PIN_SEEN != probe-a/,/^elif ! /p')" || _arm_seen=""
_arm_mkdir=""
_arm_mkdir="$(printf '%s\n' "$_pin_body" | sed -n '/^elif ! .*mkdir /,/^else$/p')" || _arm_mkdir=""
_arm_work=""
_arm_work="$(printf '%s\n' "$_pin_body" | sed -n '/^else$/,$p')" || _arm_work=""
{ [ -n "$_arm_out" ] && [ -n "$_arm_seen" ] && [ -n "$_arm_mkdir" ] && [ -n "$_arm_work" ]; } \
    && pass "…and all four arms of the pin branch lift out separately" \
    || die "an arm of the pin branch could not be lifted (out=${#_arm_out} seen=${#_arm_seen} mkdir=${#_arm_mkdir} work=${#_arm_work})"
# THE ASSIGNMENTS COME BEFORE THE BRANCH, so nothing exists when a refusal fires.
_pin_pre=""
_pin_pre="$(printf '%s\n' "$_pin_body" | sed -n '1,/^if \[\[ $RB_PIN_OUT != /p')" || _pin_pre=""
{ case "$_pin_pre" in *'RB_PIN_OUT="$RB_PIN_DIR/pin"'*) true ;; *) false ;; esac \
  && case "$_pin_pre" in *'RB_PIN_SEEN='*) true ;; *) false ;; esac \
  && case "$(printf '%s\n' "$_pin_pre" | grep -v '^[[:space:]]*#')" in *mkdir*) false ;; *) true ;; esac; } \
    && pass "…with both assignments proved before anything is created" \
    || die "an assignment is proved after the directory exists, so its refusal leaks one: '$_pin_pre'"
# THE SUCCESS LINE IS IN THE WORK ARM AND NOWHERE ELSE.
case "$_arm_work" in
    *'echo "OWNER='*) pass "…and setup announces itself only from the arm where the directory was made" ;;
    *)               die "setup's success line is not in the work arm: '$_arm_work'" ;;
esac
for _a in out seen mkdir; do
    eval "_v=\"\$_arm_$_a\""
    case "$_v" in
        *'echo "OWNER='*) die "setup announces success from the $_a refusal too" ;;
    esac
done
pass "…and never from any of the three refusals"
# THE PROBE IS IN THERE WITH IT, which is what the arms exist for: a walked-past
# refusal must not reach the child.
case "$_arm_work" in
    *'pr-origin.sh pin "$RB_PIN_OUT"'*) pass "…with the pin probe inside that arm, not before it" ;;
    *) die "the pin probe runs outside the arm the mkdir guards: '$_arm_work'" ;;
esac
# AND EVERY CLEANUP IS IN THERE TOO. Outside it the directory is not this shell's
# to remove — `mkdir` fails precisely when the path already exists, which is what
# a readonly pre-seeded value points at — and `rm -f` and `rmdir` would then take
# the operator's file and directory.
for _a in out seen mkdir; do
    eval "_v=\"\$_arm_$_a\""
    case "$_v" in
        *'rm -f "$RB_PIN_OUT"'*|*'rmdir "$RB_PIN_DIR"'*)
            die "the $_a refusal cleans up a path this shell may not have created" ;;
    esac
done
pass "…and no refusal removes anything, because none of them created it"
{ case "$_arm_work" in *'rm -f "$RB_PIN_OUT"'*) true ;; *) false ;; esac \
  && case "$_arm_work" in *'rmdir "$RB_PIN_DIR"'*) true ;; *) false ;; esac; } \
    && pass "…while the arm that made the directory removes both" \
    || die "the work arm leaves its transport file or directory behind"
# THE RESET REFUSAL IS AN ARM WITH ITS OWN ABORT, asserted structurally: on this
# bash the failed readonly assignment ends the run before the arm is evaluated, so
# a behavioural case alone would stay green with the arm deleted — while a shell
# that CONTINUES past that assignment would reach the probe and certify the stale
# value.
case "$_arm_seen" in
    *'ABORT: RB_PIN_SEEN is readonly'*) pass "…and the reset refusal is an arm that says so before it stops" ;;
    *) die "the reset refusal is not an arm with an abort: '$_arm_seen'" ;;
esac

# …AND THE EXPORT IS PROVEN TO HAVE TAKEN, which a grep cannot answer. A `readonly
# REVIEW_BUS_REMOTE` already present in the driving shell makes the export fail
# while setup carries on; if that readonly value is EMPTY, `rb_identity` falls back
# to `git remote get-url origin`, derives the intended checkout, and setup looks
# entirely successful — while every child inherits no usable pin and routes by
# whichever checkout the session later enters. That is the original
# wrong-repository defect surviving its own fix.
#
# LIFTED AND RUN, in a child that already holds the readonly. Describing this was
# what let it through: the export reads correctly at a glance, and its failure is
# visible only in what the variable holds afterwards.
_pin_block=""
_pin_block="$(awk '/^export REVIEW_BUS_REMOTE=/, /^fi$/' "$SKILL")" || _pin_block=""
{ [ -n "$_pin_block" ] \
  && case "$_pin_block" in *'[[ $RB_PIN_SEEN = "$RB_REMOTE" ]]'*) true ;; *) false ;; esac \
  && case "$_pin_block" in *'exit 1'*) true ;; *) false ;; esac; } \
    && pass "the pin's export and its proof lift out of SKILL.md together" \
    || die "the pin block is truncated or has lost its postcondition: '$_pin_block'"
_ro_rc=0
env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$SCRIPT_DIR" bash -c '
        readonly REVIEW_BUS_REMOTE=""
        RB_REMOTE="git@github.com:acme/widget.git"
        RB_TMPPARENT="${RB_TMPBASE:?the pin cases need the fixture scratch tree}"
        '"$_pin_block"'
    ' >/dev/null 2>&1 || _ro_rc=$?
[ "$_ro_rc" -ne 0 ] \
    && pass "…and a readonly REVIEW_BUS_REMOTE aborts setup rather than pinning nothing" \
    || die "setup continued with an empty readonly pin; every stage would route by the current directory"
# …AND A SHADOWED `export` IS THE SAME FAILURE, caught by the same line. One that
# returns 0 without assigning leaves the variable untouched, which the status
# cannot see and the postcondition can — the reason the proof is a reserved word
# rather than another builtin.
_sh_rc=0
env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$SCRIPT_DIR" 'BASH_FUNC_export%%=() { return 0; }' bash -c '
        RB_REMOTE="git@github.com:acme/widget.git"
        RB_TMPPARENT="${RB_TMPBASE:?the pin cases need the fixture scratch tree}"
        '"$_pin_block"'
    ' >/dev/null 2>&1 || _sh_rc=$?
[ "$_sh_rc" -ne 0 ] \
    && pass "…and a shadowed export is caught by the postcondition" \
    || die "a shadowed export left the pin unset and setup carried on"
# …AND AN `export` THAT ASSIGNS WITHOUT EXPORTING IS THE CASE THE PARENT-SIDE
# CHECK CANNOT SEE. A narrow forger that performs the assignment and returns
# leaves this shell holding exactly the right value while no child inherits
# anything — so reading the variable back agrees, and every stage still derives
# from wherever the session later stands. Only asking a child separates them.
_noexp_rc=0
env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$SCRIPT_DIR" \
    'BASH_FUNC_export%%=() { eval "${1}"; return 0; }' bash -c '
        RB_REMOTE="git@github.com:acme/widget.git"
        RB_TMPPARENT="${RB_TMPBASE:?the pin cases need the fixture scratch tree}"
        '"$_pin_block"'
    ' >/dev/null 2>&1 || _noexp_rc=$?
[ "$_noexp_rc" -ne 0 ] \
    && pass "…and an export that assigns without exporting is caught by asking a child" \
    || die "the pin passed while no child could see it; every stage would route by the current directory"
# …AND A PRE-SEEDED READONLY `RB_PIN_SEEN` CANNOT CERTIFY A PIN NO CHILD SAW.
# This is the combined state, and it is the one the non-emptiness test cannot
# reach: `export` assigns without exporting, `exit` is neutered so the reset's
# refusal is walked past, and a readonly `RB_PIN_SEEN` already holding the real
# remote survives both the reset and the probe — the child inherits nothing,
# reports nothing, its empty answer cannot overwrite a readonly variable, and the
# equality compares the pre-seeded value with `$RB_REMOTE` and AGREES. Only making
# the probe and the success line arms of that refusal stops it.
_seed_out=""
_seed_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$SCRIPT_DIR" \
    'BASH_FUNC_export%%=() { eval "${1}"; return 0; }' \
    'BASH_FUNC_exit%%=() { return 0; }' bash -c '
        RB_REMOTE="git@github.com:acme/widget.git"
        RB_TMPPARENT="${RB_TMPBASE:?the pin cases need the fixture scratch tree}"
        readonly RB_PIN_SEEN="git@github.com:acme/widget.git"
        '"$_pin_block"'
    ' 2>&1)" || true
case "$_seed_out" in
    *'OWNER='*) die "a pre-seeded readonly RB_PIN_SEEN certified a pin no child saw: '$_seed_out'" ;;
    *)          pass "…and a pre-seeded readonly RB_PIN_SEEN cannot reach the success line" ;;
esac
# ITS REACH: the same shell must really keep the pre-seeded value, or the case
# above passes because the assignment overwrote it and the answer was empty.
# THE RESET ARM IS ASSERTED STRUCTURALLY AS WELL, and it has to be: on this bash
# the failed readonly assignment ends the `bash -c` before the arm is evaluated,
# so the behavioural case above passes on the shell's own refusal and would stay
# green with that arm deleted. A shell that CONTINUES past the failed assignment
# — the behaviour `CLAUDE.md` records as depending on where the assignment sits —
# would then reach the probe and certify the stale value.
# THE WRITABILITY PROBE IS TWO UNEQUAL VALUES, because `readonly RB_PIN_SEEN=''`
# defeats a single one: the reset fails, the value is already empty, and an
# emptiness test agrees — so the probe runs and the assignment that would store the
# child's answer fails inside the compound command, which can end the shell before
# either cleanup, leaving the file and the directory behind.
# THE VERDICT IS CONTROL FLOW, NOT A VARIABLE. A `RB_PIN_WRITABLE` flag was the
# first fix and is not this one: a readonly pre-seed of `yes` made every reset of
# it fail while the refusal was skipped — the same defect one name along. An
# assignment inside an `elif` list leaves nothing to pre-seed.
case "$_pin_body" in
    *RB_PIN_WRITABLE*) die "the writability verdict is held in a variable a pre-seed can hold" ;;
    *) pass "…and the writability verdict is control flow, not a pre-seedable variable" ;;
esac
for _v in 'elif \[\[ $RB_PIN_SEEN != probe-a \]\]; then' \
          'elif RB_PIN_SEEN=probe-b; \[\[ $RB_PIN_SEEN != probe-b \]\]; then' \
          'elif RB_PIN_SEEN=; \[\[ -n $RB_PIN_SEEN \]\]; then'; do
    printf '%s\n' "$_pin_body" | grep -q "^$_v\$" \
        || die "the writability probe is missing an arm: $_v"
done
pass "…proved by three assignments in the conditions, so no readonly satisfies them all"
# ITS REACH: that shell must really stop on the pre-seeded value. Either message
# counts — a failed readonly assignment inside a compound command can end the
# script before the arm's own abort prints, which is bash's behaviour and not a
# spelling to assert.
case "$_seed_out" in
    *'RB_PIN_SEEN is readonly'*|*'RB_PIN_SEEN: readonly variable'*)
        pass "…where that shell does refuse on the pre-seeded value" ;;
    *) die "the pre-seeded case did not refuse at all ('$_seed_out')" ;;
esac
# …AND A REFUSAL DESTROYS NOTHING ON ITS WAY OUT — not the file and not the
# directory. The refusing arm runs before the probe, so there is nothing it can
# have created; and reaching it at all means `RB_PIN_SEEN` was pre-seeded
# READONLY, which no ordinary shell does, so every postcondition above may equally
# have been walked past with `exit` neutered. `RB_PIN_OUT` and `RB_PIN_DIR` can
# then name the operator's own file and directory — `rm -f` deletes the file, and
# `rmdir` deletes the directory when it is empty, which an operator's directory
# often is.
# UNDER THE SCRATCH TREE THAT ALREADY EXISTS, not a fresh `mktemp_d`. The probe
# at the end of this file re-runs it with `mktemp` stubbed and asserts on the
# FIRST refusal's text; a new call here would refuse before that one and change
# which message comes out.
# GUARDED ON THE SCRATCH TREE EXISTING, like the forger cases: the probe at the
# end of this file re-runs it with `mktemp` stubbed, where there is no tree — and
# a `:?` here would kill the run with a message that probe does not expect.
# GUARDED ON `_forge_dir`, THE VALIDATED ALLOCATION, not on `RB_TMPBASE` — which
# this fixture exports FROM it and which an invoking environment may already
# carry. With `mktemp_d` failing and an inherited `RB_TMPBASE`, the guard passed
# and this block wrote into, and then `rm -rf`'d, a path nobody here allocated.
if [ -n "$_forge_dir" ] && [ -d "$_forge_dir" ]; then
# NAMED `watch-pr.*` UNDER THE TRANSPORT PARENT, and with a matching `RB_PIN_OUT`,
# so the two earlier arms pass their checks and the `mkdir` arm is the one that
# fires. Pre-seeded onto a mismatching path the FIRST arm was selected, `mkdir` was
# never attempted, and breaking its refusal left this case green.
_sentinel="$_forge_dir/watch-pr.sentinel"
mkdir -p "$_sentinel"
printf 'DO NOT DELETE\n' > "$_sentinel/pin"
_sent_rc=0
_sent_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$SCRIPT_DIR" \
    'BASH_FUNC_exit%%=() { return 0; }' bash -c '
        RB_REMOTE="git@github.com:acme/widget.git"
        RB_TMPPARENT="${RB_TMPBASE:?the pin cases need the fixture scratch tree}"
        readonly RB_PIN_DIR="'"$_sentinel"'"
        readonly RB_PIN_OUT="'"$_sentinel"'/pin"
        '"$_pin_block"'
    ' 2>&1)" || _sent_rc=$?
# THE REFUSAL ITSELF, not only the survival. `RB_PIN_DIR` names a directory that
# already exists, so `mkdir` fails and the outer `else` is the whole fail-closed
# path — delete it and both survival checks stay green while setup finishes with
# no diagnostic at all.
{ [ "$_sent_rc" -ne 0 ] \
  && case "$_sent_out" in *'ABORT: could not create a private directory'*) true ;; *) false ;; esac; } \
    && pass "…where a mkdir onto an existing directory takes the mkdir refusal, non-zero and saying so" \
    || die "a failed mkdir did not take its own refusal (rc=$_sent_rc out='$_sent_out')"
case "$_sent_out" in
    *'OWNER='*) die "a failed mkdir reached the success line ('$_sent_out')" ;;
    *) pass "…and never reaches the success line" ;;
esac
[ -s "$_sentinel/pin" ] \
    && pass "…and a refusal on a pre-seeded readonly path leaves the operator's file alone" \
    || die "the refusing arm deleted a file it never created"
# AND THE DIRECTORY TOO. `rmdir` removes an EMPTY directory, and an operator's
# directory often is one — so "it can only fail" was the wrong claim.
[ -d "$_sentinel" ] \
    && pass "…and their directory, which rmdir would have removed" \
    || die "the refusing arm removed a directory it never created"
rm -rf "$_sentinel"
fi
# …AND `readonly RB_PIN_SEEN=''` REFUSES BEFORE ANYTHING IS CREATED. The reset
# assignment fails and the value is already empty, so an emptiness test agreed and
# the probe ran — then the assignment that stores the child's answer failed inside
# the compound command, which can end the shell before either cleanup, leaving the
# file and the `watch-pr.*` directory behind. Two unequal probe values tell that
# state apart from a variable this shell just emptied.
if [ -n "$_forge_dir" ] && [ -d "$_forge_dir" ]; then
_emptyro="$_forge_dir/emptyro"
mkdir -p "$_emptyro"
_ero_rc=0
_ero_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$SCRIPT_DIR" bash -c '
        RB_REMOTE="git@github.com:acme/widget.git"
        RB_TMPPARENT="'"$_emptyro"'"
        readonly RB_PIN_SEEN=""
        '"$_pin_block"'
    ' 2>&1)" || _ero_rc=$?
# EITHER REFUSAL COUNTS. A failed readonly assignment inside a condition list can
# end the shell where it stands — bash's own behaviour — so the arm's own message
# may never print. What must hold is that the run refuses and creates nothing,
# which the next case asserts.
{ [ "$_ero_rc" -ne 0 ] \
  && case "$_ero_out" in
        *'ABORT: RB_PIN_SEEN is readonly'*|*'RB_PIN_SEEN: readonly variable'*) true ;;
        *) false ;;
     esac; } \
    && pass "…and an EMPTY readonly RB_PIN_SEEN is refused, not mistaken for a reset" \
    || die "readonly RB_PIN_SEEN='' was not refused (rc=$_ero_rc out='$_ero_out')"
case "$_ero_out" in
    *'OWNER='*) die "readonly RB_PIN_SEEN='' reached the success line ('$_ero_out')" ;;
    *) pass "…and never reaches the success line" ;;
esac
# AND IT LEFT NOTHING BEHIND, which is what refusing before the `mkdir` buys.
[ -z "$(ls -A "$_emptyro" 2>/dev/null)" ] \
    && pass "…leaving no transport directory behind, because it refused before creating one" \
    || die "the empty-readonly refusal left something in the transport parent: $(ls -A "$_emptyro")"
rm -rf "$_emptyro"
fi
# …AND THE ORDINARY CASE STILL PASSES THROUGH. A block that aborted unconditionally
# would satisfy both cases above while stopping every session.
_ok_rc=0
env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$SCRIPT_DIR" bash -c '
        RB_REMOTE="git@github.com:acme/widget.git"
        RB_TMPPARENT="${RB_TMPBASE:?the pin cases need the fixture scratch tree}"
        '"$_pin_block"'
    ' >/dev/null 2>&1 || _ok_rc=$?
[ "$_ok_rc" -eq 0 ] \
    && pass "…while an ordinary shell pins and continues" \
    || die "the pin block aborts a session with nothing wrong with it (rc=$_ok_rc)"
# …AND A READONLY `RB_PIN_OUT` STOPS SETUP TOO. Same shape as the read side, same
# long-lived shell, and the same reason the guard is a postcondition rather than a
# status: a failed readonly assignment on the left of an AND-OR list reports
# success.
if [ -n "$_forge_dir" ]; then
    _rp2_out=""
    _rp2_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$SCRIPT_DIR" bash -c '
            RB_REMOTE="git@github.com:acme/widget.git"
            RB_TMPPARENT="${RB_TMPBASE:?the pin cases need the fixture scratch tree}"
            readonly RB_PIN_OUT="${RB_TMPBASE:?}/elsewhere"
            '"$_pin_block"'
        ' 2>&1)" || true
    case "$_rp2_out" in
        *OWNER=*) die "a readonly RB_PIN_OUT was ignored and setup reported success: '$_rp2_out'" ;;
        *)        pass "…and a readonly RB_PIN_OUT stops setup rather than being ignored" ;;
    esac
fi
# …AND A READONLY `RB_PIN_SEEN` CANNOT ANSWER FOR THE CHILD. This is the state
# where the reset decides the verdict: a readonly one already holding the real
# origin survives both the reset and the assignment after it, so a child that
# inherited nothing reports nothing and the equality still agrees. Combined with
# an `export` that assigns without exporting — the case two blocks up — setup
# announces a pin that no helper will ever see.
if [ -n "$_forge_dir" ]; then
    _rps_out=""
    _rps_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$SCRIPT_DIR" \
        'BASH_FUNC_export%%=() { eval "${1}"; return 0; }' bash -c '
            RB_REMOTE="git@github.com:acme/widget.git"
            RB_TMPPARENT="${RB_TMPBASE:?}"
            readonly RB_PIN_SEEN="git@github.com:acme/widget.git"
            '"$_pin_block"'
        ' 2>&1)" || true
    case "$_rps_out" in
        *OWNER=*) die "a readonly RB_PIN_SEEN answered for the child and setup reported success: '$_rps_out'" ;;
        *)        pass "…and a readonly RB_PIN_SEEN cannot answer for the child" ;;
    esac
fi
# …AND AN EMPTY PIN CANNOT REACH THE SUCCESS LINE, whatever walked past the
# refusal that should have stopped it. Every refusal in this block ends in `exit`,
# and `exit` is a name: with one shadowed, a refused transport check carries on
# with `RB_REMOTE` still empty, the probe reports empty because no child was
# asked, and `"" = ""` succeeds — setup announcing success with no
# `REVIEW_BUS_REMOTE` at all. #102 has the rest of that class; this is its
# consequence, and it is closed on its own.
if [ -n "$_forge_dir" ]; then
    _mt_out=""
    _mt_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=1 \
        'BASH_FUNC_exit%%=() { return 0; }' bash -c '
            RB_REMOTE=
            RB_TMPPARENT="${RB_TMPBASE:?}"
            '"$_pin_block"'
        ' 2>&1)" || true
    case "$_mt_out" in
        *OWNER=*) die "setup announced success with an empty pin: '$_mt_out'" ;;
        *)        pass "…and an empty pin cannot reach the success line even with exit shadowed" ;;
    esac
fi
# …AND A SHADOWED `rm` ON THE PIN SIDE CANNOT SUPPLY THE ANSWER. The same name
# runs between the probe and the postcondition here, and the state it reaches is
# worse: a failed probe leaves `RB_PIN_SEEN` empty, so a function by that name
# setting it to `$RB_REMOTE` makes the equality agree and setup reports a pin that
# no child was ever asked about.
if [ -n "$_forge_dir" ]; then
    _pr_rc=0
    _pr_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=1 \
        'BASH_FUNC_rm%%=() { RB_PIN_SEEN="$RB_REMOTE"; return 0; }' bash -c '
            RB_REMOTE="git@github.com:acme/widget.git"
            RB_TMPPARENT="${RB_TMPBASE:?the pin cases need the fixture scratch tree}"
            '"$_pin_block"'
        ' 2>&1)" || _pr_rc=$?
    { [ "$_pr_rc" -ne 0 ] \
      && case "$_pr_out" in *OWNER=*) false ;; *) true ;; esac; } \
        && pass "…and a shadowed rm cannot supply the pin the probe failed to report" \
        || die "a shadowed rm satisfied the pin postcondition (rc=$_pr_rc out='$_pr_out')"
fi
# …AND A PIN HELPER THAT FAILS IS NOT READ BACK, which is the other half of the
# same status. The block used to run the helper and read the file whatever
# happened, on the grounds that the helper truncates before it writes — true, and
# it says nothing about a helper that never reached the truncation because it
# could not start. What was read then was whatever stood at that path, and it only
# had to equal `$RB_REMOTE` to report that a child inherited a pin no child had
# been asked for.
#
# THE FORGED HELPER WRITES THE MATCHING VALUE AND THEN FAILS, since a file left
# holding anything else would be refused by the equality check with no branch at
# all — the same reason the read probe above chooses its status separately from
# its output.
if [ -n "$_forge_dir" ]; then
    _pf_rc=0
    _pf_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$_forge_dir" FORGE_RC=1 bash -c '
            RB_REMOTE="git@github.com:acme/widget.git"
            RB_TMPPARENT="${RB_TMPBASE:?the pin cases need the fixture scratch tree}"
            '"$_pin_block"'
        ' 2>&1)" || _pf_rc=$?
    { [ "$_pf_rc" -ne 0 ] \
      && case "$_pf_out" in *OWNER=*) false ;; *) true ;; esac; } \
        && pass "…and a pin helper that writes the right value and then fails is not believed" \
        || die "setup accepted a pin from a helper that failed (rc=$_pf_rc out='$_pf_out')"
fi
# ── BOTH HOSTILE STATES AT ONCE, WHICH IS WHERE THE STATUS STOPS HELPING ────
#
# `readonly REVIEW_BUS_REMOTE=''` makes the export return 1 and a function named
# `exit` makes the abort return instead of exiting, so neither guard ends the
# shell — the `if` merely closes non-zero, and with no `set -e` whatever follows
# runs. CLAUDE.md § Already paid for: combine the states, because separate cases
# cannot see this.
#
# WHAT IS ASSERTED IS THE SIGNAL, NOT THE STATUS. A trailing marker stands in for
# a step someone adds after the pin later; it runs here, and that is the point —
# the protection is that setup's SUCCESS LINE is unreachable, so the driver is
# never told setup completed with no pin in place. The static check above is the
# other half: in `SKILL.md` there is nothing after the pin for a neutralised abort
# to step over.
_both_out=""
_both_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV RB_SCRIPTS="$SCRIPT_DIR" \
    'BASH_FUNC_exit%%=() { return 0; }' bash -c '
        readonly REVIEW_BUS_REMOTE=""
        RB_REMOTE="git@github.com:acme/widget.git"
        RB_TMPPARENT="${RB_TMPBASE:?the pin cases need the fixture scratch tree}"
        # RB_SCRIPTS IS NOT OVERRIDDEN HERE. The pin block calls
        # `"$RB_SCRIPTS"/pr-origin.sh pin` since #84, so pointing it at a
        # nonexistent directory made the helper fail before it could report what
        # the child inherited — and the resulting mismatch satisfied the
        # assertion, so the readonly-export guard under test could have been
        # deleted with this still green. The other two placeholders are values the
        # block only prints.
        OWNER=acme; REPO=widget; SUMMARY_FILE=/nonexistent
        '"$_pin_block"'
        printf "CONTINUED\n"' 2>/dev/null)" || true
case "$_both_out" in
    *OWNER=*) die "setup announced success with no pin in place: '$_both_out'" ;;
    *)        pass "…and a readonly pin with `exit` shadowed never announces setup as complete" ;;
esac
# …AND SAYS WHY, so an operator reading the terminal is not left with silence.
case "$_both_out" in
    *ABORT*) pass "…and says the pin did not take" ;;
    *)       die "the doubly-neutralised failure is silent: '$_both_out'" ;;
esac
# ── AND WITH `echo` FORGED TOO, WHICH IS WHERE THE OUTPUT STOPS MEANING ────
#
# A function replacing `echo` can print `OWNER=…` from the ABORT branch, so the
# success MARKER is not a property this shell can defend — that is why the comment
# beside the guard claims the failure path is not REACHED rather than that the line
# cannot be emitted, and why composing the message elsewhere is #84.
#
# WHAT SURVIVES IS THE STATUS, and that is what is asserted: with the pin readonly
# and `exit` and `echo` all replaced, the block still ends non-zero. A driver that
# takes the status — which the `CLOSE_RC` guard below and every helper caller do —
# still stops.
# EVERY `env` OPTION BEFORE THE FIRST ASSIGNMENT. Option parsing stops at the
# first operand, so `env -u A B=1 -u C cmd` treats `-u` as the UTILITY — GNU `env`
# answers 127, BSD the same. This case had `-u REVIEW_BUS_REMOTE` after
# `RB_SCRIPTS=…` and so never ran the block at all: 127 is non-zero, which is
# exactly what the assertion wanted, so it passed on its own breakage.
#
# AND THE PROBE SAYS IT RAN, which is the half that would have caught it. A status
# alone cannot tell "the guard refused" from "the command never started", and
# those are the two things this case sits between.
_forged_rc=0
_forged_out="$(env -u SHELLOPTS -u BASH_ENV -u ENV -u REVIEW_BUS_REMOTE RB_SCRIPTS="$SCRIPT_DIR" \
    'BASH_FUNC_exit%%=() { return 0; }' \
    'BASH_FUNC_echo%%=() { builtin printf "OWNER=acme REPO=widget\n"; }' bash -c '
        printf "PROBE_RAN\n" >&2
        readonly REVIEW_BUS_REMOTE=""
        RB_REMOTE="git@github.com:acme/widget.git"
        RB_TMPPARENT="${RB_TMPBASE:?the pin cases need the fixture scratch tree}"
        '"$_pin_block"'
    ' 2>&1 >/dev/null)" || _forged_rc=$?
case "$_forged_out" in
    *PROBE_RAN*) pass "the forged-echo probe reaches the pin block at all" ;;
    *)           die "the forged-echo probe never ran its block: '$_forged_out'" ;;
esac
[ "$_forged_rc" -ne 0 ] \
    && pass "…and a forged echo cannot make the pin's failure exit zero" \
    || die "with echo, exit and the pin all forged, setup reported success"
# THE FORGED HELPER AND EVERY TRANSPORT DIRECTORY UNDER IT GO HERE, after the last
# case that uses either. `rm -rf` on a variable is safe only because `mktemp_d`
# validates what it returns — an absolute path to a directory that exists — and
# because nothing between here and there reassigns it.
[ -n "$_forge_dir" ] && rm -rf "$_forge_dir"
unset RB_TMPBASE
# …AND THE STATUS IS TAKEN. A call whose failure is ignored closes nothing and
# says so to nobody, and the next step reads the missing signoff as absent rather
# than as failed.
# THE READ IS THROUGH THE OPEN DESCRIPTOR, not through the pathname a second
# time. `RB_REMOTE="$(<"$RB_ORIGIN_OUT")"` was the shape until a swap between the
# checks and the read was found; the redirection is what makes the object the one
# already validated, so the assertion names it rather than the variable alone.
grep -qF 'RB_REMOTE="$(<"/dev/fd/9")"' <<<"$skill_flat" \
    && pass "…and the value is read back from the open transport, not from a captured stream" \
    || die "the origin value is not read back from the descriptor the checks validated"
grep -qF '9<"$RB_ORIGIN_OUT"' <<<"$skill_flat" \
    && pass "…with the descriptor bound by a redirection, which is not a name" \
    || die "the origin transport is not opened by a redirection"
grep -qF 'rm -f "$RB_ORIGIN_OUT"' <<<"$skill_flat" \
    && pass "…and the file is removed once its value has been read" \
    || die "the origin file is left behind"
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
grep -q 'pr-close-round.sh gate N "\$WHO" "\$SUMMARY_FILE" "\$AUTO_REVIEW"' "$SKILL" \
    && pass "…and the recipe gates on the mode this PR is actually in" \
    || die "the recipe does not run the gate with \$AUTO_REVIEW"
grep -q 'pr-close-round.sh post N "\$WHO" "\$SUMMARY_FILE" "\$AUTO_REVIEW" "\$GATED_HEAD"' "$SKILL" \
    && pass "…and posts against the head the gate proved" \
    || die "the recipe does not post with the gated head"
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
_gate_ln="$(grep -n '^GATE_OUT="\$(/usr/bin/env bash -p "\$RB_SCRIPTS"/pr-close-round.sh gate N' "$SKILL" | head -1 | cut -d: -f1)" || true
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
        printf '%s' "$readme_now" | grep -qi -- "$gone" \
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
_rb_prp_ln="$(grep -n '( PRIOR_REVIEW=Probe-A; \[\[ $PRIOR_REVIEW = Probe-A \]\] )' "$SKILL" | head -1 | cut -d: -f1)" || _rb_prp_ln=""
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

# …AND TWO OF THE THREE ARE RUN, not only matched. `PRIOR_REVIEW` is not among
# them and that is stated rather than implied: exercising it means POSTING a
# request, so what it shares with these two is the rule, and the rule is what
# these runs prove. What the change claims is that
# a readonly or transforming name reaches setup's NAMED refusal instead of ending
# the operator's shell at a bare assignment, and neither half is visible in the
# text. Reverting any of these sites to the old shape has to turn something red.
#
# THE BLOCKS ALONE, extracted by their own headers. The allocation lives inside
# the pin's success arm, so it comes out with that arm; the probe under test is
# the first thing in it and every refusal below it is unreachable once the probe
# refuses, which is what makes the case self-contained.
# A SCRATCH DIRECTORY THAT CANNOT BE MADE IS A FAILURE, NOT A SKIP. Converted to
# an empty value and guarded, an unusable `TMPDIR` let this file finish
# `RESULT: PASS` having exercised neither probe — unavailable infrastructure
# reported as successful coverage, which is the fail-open shape this repository
# forbids. The guard stays as well, because the probe at the end of this file
# re-runs everything with `mktemp` stubbed, where an unguarded path under an empty
# variable writes to `/parent`.
_rb_pb=""
_rb_pb="$(mktemp_d)" || _rb_pb=""
{ [ -n "$_rb_pb" ] && [ -d "$_rb_pb" ]; } \
    || die "no scratch directory for the setup-probe cases; neither probe was exercised"
if [ -n "$_rb_pb" ] && [ -d "$_rb_pb" ]; then
mkdir -p "$_rb_pb/parent" "$_rb_pb/bin"
# A WORKING `pr-origin.sh` FOR THE CONTROL, because the parent selection is inside
# the probe's success arm now: without one, an ordinary shell reaches the loop,
# every candidate is refused by the helper, and the control would agree with the
# two refusal cases for a reason that has nothing to do with the probe.
printf '#!/bin/sh\nprintf "git@github.com:acme/widget.git\\n" > "$2"\nexit 0\n' > "$_rb_pb/bin/pr-origin.sh"
chmod +x "$_rb_pb/bin/pr-origin.sh"
awk '/^    if \[\[ -n \$RB_PIN_SEEN \]\]/,/^    fi$/' "$SKILL" > "$_rb_pb/alloc.sh"
awk '/^if \( RB_TMPPARENT=Probe-A;/,/^fi$/' "$SKILL" > "$_rb_pb/parent.sh"
# THE EXCERPT HAS TO CONTAIN THE SELECTION, or the cases below prove nothing. The
# range runs from the probe to the first `fi` at column 0 — which is the probe's
# own when the selection is its success arm, and the GUARD's if it is not. Revert
# the containment and the excerpt shrinks to the guard alone: the refusal cases
# still see their refusal and the control still prints SURVIVED, so every
# assertion below stays green while the real setup enters the loop with a name it
# has just reported unusable.
case "$(cat "$_rb_pb/parent.sh")" in
    *'for RB_TMPPARENT in'*)
        pass "…and the excerpt contains the selection, so the cases below can see it" ;;
    *)
        die "the extracted probe block stops before the parent selection; the runtime cases below would pass against a guard" ;;
esac
# ONE HARNESS, THREE STATES. `readonly` with `errexit` is the regression this
# change is about; `declare -i` is the half a status-only probe accepted, where
# the assignment SUCCEEDS and stores `0`; and the ordinary state is the control
# that keeps the other two from passing against a block that refuses everything.
rb_probe_case() {   # rb_probe_case <script> <attribute-line> <extra-env…>
    local _s="$1" _attr="$2"; shift 2
    # THE STATUS IS DISCARDED ON PURPOSE, and the OUTPUT is what every case reads.
    # A refusing block exits non-zero, and under this file's `set -e` a command
    # substitution that fails ends the fixture — silently, after 140 assertions.
    run_limited 25 env "$@" bash --noprofile --norc -c '
set -e
'"$_attr"'
OWNER=acme; REPO=widget; RB_SCRIPTS="${RB_PROBE_SCRIPTS:-/nonexistent-rb-scripts}"
RB_PIN_SEEN=same; RB_REMOTE=same
. "$1"
printf "SURVIVED\n"' _ "$_s" 2>&1 || true
}
# `declare -l` IS THE THIRD STATE, and it is why the probe value is mixed case.
# `probe-a` is already lowercase, so a lowercase-transforming attribute leaves it
# unchanged and a probe using it PASSES — then the real assignment lowercases the
# path and setup fails somewhere else, about something else.
#
# AND IT IS BASH 4.0+, so this shell is ASKED rather than assumed. On the 3.2.57
# path the attribute line itself fails, and under the harness's `set -e` the case
# would die before reaching any refusal — reporting the probe broken on a shell
# where the attribute it tests does not exist. The skip is announced rather than
# silent: a case that quietly does not run is the coverage this file exists to
# stop claiming.
# ASKED WITH AN `if`, NOT AN `&&` LIST. Written as `( declare -l … ) && _rb_has_l=yes`
# the list itself reports 1 on a shell without the attribute, and under this
# file's `set -e` that ends the run — on exactly the 3.2.57 path the probe exists
# to accommodate, which is the failure it was written to avoid.
_rb_has_l=no
if ( declare -l _rb_probe_l=A ) 2>/dev/null; then _rb_has_l=yes; fi
[ "$_rb_has_l" = yes ] \
    && pass "…and this shell has declare -l, so the lowercase-transforming state runs" \
    || pass "…and this shell has no declare -l, so that state is skipped by name"
_rb_attrs="readonly RB_TMPPARENT=Probe-A|declare -i RB_TMPPARENT=0"
if [ "$_rb_has_l" = yes ]; then _rb_attrs="$_rb_attrs|declare -l RB_TMPPARENT=x"; fi
_rb_rest="$_rb_attrs"
while [ -n "$_rb_rest" ]; do
    _rb_attr="${_rb_rest%%|*}"
    case "$_rb_rest" in *'|'*) _rb_rest="${_rb_rest#*|}" ;; *) _rb_rest="" ;; esac
    _rb_out="$(rb_probe_case "$_rb_pb/parent.sh" "$_rb_attr" TMPDIR="$_rb_pb/parent" HOME="$_rb_pb/parent")"
    printf '%s' "$_rb_out" | grep -qF 'ABORT: RB_TMPPARENT is readonly or value-transforming in this shell' \
        && pass "…the transport-parent probe reaches its named refusal under errexit ($_rb_attr)" \
        || die "the RB_TMPPARENT probe gave '$_rb_out' ($_rb_attr)"
done
# AND A SHADOWED `exit` CHANGES NOTHING ABOUT WHICH REFUSAL IS PRINTED. The
# selection being the probe's success arm is asserted STRUCTURALLY above, and that
# is deliberate: no state reaches the selection to be observed. Measured on bash 5
# against the guard form — a readonly ends the shell at the loop's first
# assignment, and `declare -i` makes that assignment an arithmetic error, which
# under `errexit` ends it too. So the loop's own misdirected abort about `TMPDIR`
# and `HOME` never follows in either shape, and an assertion demanding its absence
# would pass against the code it was written to reject. What is asserted here is
# what can be: the refusal that IS printed is the probe's own, naming the
# variable, whatever was done to `exit`.
_rb_out="$(rb_probe_case "$_rb_pb/parent.sh" 'exit() { return 0; }
declare -i RB_TMPPARENT=0' TMPDIR="$_rb_pb/parent" HOME="$_rb_pb/parent" RB_PROBE_SCRIPTS="$_rb_pb/bin")"
printf '%s' "$_rb_out" | grep -qF 'ABORT: RB_TMPPARENT is readonly or value-transforming in this shell' \
    && pass "…and a shadowed exit does not change which refusal is printed" \
    || die "the shadowed-exit case gave '$_rb_out'"
printf '%s' "$_rb_out" | grep -qF 'could not read origin into a transport directory' \
    && die "…but the selection ran anyway and added its own misdirected abort: '$_rb_out'" \
    || pass "…and no second, misdirected abort follows it (an absence check; see above for what it cannot see)"
_rb_out="$(rb_probe_case "$_rb_pb/parent.sh" 'RB_TMPPARENT=' TMPDIR="$_rb_pb/parent" HOME="$_rb_pb/parent" RB_PROBE_SCRIPTS="$_rb_pb/bin")"
printf '%s' "$_rb_out" | grep -qF 'SURVIVED' \
    && pass "…and an ordinary shell passes it, so the two above are not refusing everything" \
    || die "the RB_TMPPARENT probe refused an ordinary shell: '$_rb_out'"
_rb_attrs="readonly RB_WORK_DIR=/tmp|declare -i RB_WORK_DIR=0"
if [ "$_rb_has_l" = yes ]; then _rb_attrs="$_rb_attrs|declare -l RB_WORK_DIR=x"; fi
_rb_rest="$_rb_attrs"
while [ -n "$_rb_rest" ]; do
    _rb_attr="${_rb_rest%%|*}"
    case "$_rb_rest" in *'|'*) _rb_rest="${_rb_rest#*|}" ;; *) _rb_rest="" ;; esac
    _rb_out="$(rb_probe_case "$_rb_pb/alloc.sh" "$_rb_attr" TMPDIR="$_rb_pb/parent" RB_TMPPARENT="$_rb_pb/parent")"
    printf '%s' "$_rb_out" | grep -qF "ABORT: RB_WORK_DIR is readonly or value-transforming in this shell" \
        && pass "…the working-directory probe reaches its named refusal under errexit ($_rb_attr)" \
        || die "the RB_WORK_DIR probe gave '$_rb_out' ($_rb_attr)"
    printf '%s' "$_rb_out" | grep -qF 'OWNER=acme' \
        && die "…but setup still reported completion ($_rb_attr): '$_rb_out'" \
        || pass "…and setup's completion line is not reached ($_rb_attr)"
done
_rb_out="$(rb_probe_case "$_rb_pb/alloc.sh" 'RB_WORK_DIR=' TMPDIR="$_rb_pb/parent" RB_TMPPARENT="$_rb_pb/parent")"
printf '%s' "$_rb_out" | grep -qF 'OWNER=acme' \
    && pass "…and an ordinary shell reaches the completion line, so the two above are not refusing everything" \
    || die "the RB_WORK_DIR allocation refused an ordinary shell: '$_rb_out'"
rm -rf "$_rb_pb" 2>/dev/null || true
fi
# AND THE REQUEST IS THE PROBES' SUCCESS ARM, not a statement after them. Written
# as standalone guards they detect the readonly name and then cannot act on it —
# `exit` is a builtin a startup file can replace with one that RETURNS, and a
# trailing reserved word only gives the `if` a false status nothing consumes, so
# execution reached the request and posted it anyway.
grep -q '^if { ( PRIOR_REVIEW=Probe-A; \[\[ $PRIOR_REVIEW = Probe-A \]\] )' "$SKILL" \
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
rb_line_of() {   # rb_line_of <needle> ; sets RB_LINE, empty when absent
    local _rest="$RB_SKILL_BODY" _line _n=0
    RB_LINE=""
    while [[ -n $_rest ]]; do
        _line="${_rest%%$'\n'*}"
        if [[ $_rest == *$'\n'* ]]; then _rest="${_rest#*$'\n'}"; else _rest=""; fi
        _n=$((_n + 1))
        if [[ $_line == *"$1"* ]]; then RB_LINE="$_n"; return 0; fi
    done
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
rb_occurrences() {   # sets RB_N to how many times $1 appears in this file
    local _rest="$_rb_self"
    RB_N=0
    while [[ $_rest == *"$1"* ]]; do
        RB_N=$((RB_N + 1))
        _rest="${_rest#*"$1"}"
    done
}
rb_occurrences "rb_line_of 'AUTO_REVIEW=no'";                   _rb_sel_n="$RB_N"
rb_occurrences "rb_line_of 'Request the review — Codex first'"; _rb_req_n="$RB_N"
{ [ "$_rb_sel_n" -ge 2 ] && [ "$_rb_req_n" -ge 2 ]; } \
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
_mk_n="$(printf '%s\n' "$_mk_set" | grep -c . )" || _mk_n=0
[ "$_mk_n" -eq 3 ] \
    && pass "the reserved-marker set is the size SKILL.md and README.md describe" \
    || die "the reserved-marker set changed ($_mk_n markers, expected 3: $(printf '%s' "$_mk_set" | tr '\n' ' ')) — update SKILL.md and README.md, then this count"
# SCOPED TO THE REFUSAL PASSAGE, not to the file. Both documents name these
# markers elsewhere — `README.md` documents the acknowledgement's own format in the
# round-boundary section — so a whole-file `grep` is satisfied by a mention that
# has nothing to do with what an author may write. That is the "the token also
# appears elsewhere" trap, and the first version of this check fell into it: a
# marker deleted from the refusal list still passed.
_skill_pass="$(awk '/^# THE BODY IS PROSE AND MUST NOT BECOME A RECORD/{c=12} c-->0' "$SKILL")" || true
_readme_pass="$(awk '/^   The body you supply is prose/{c=12} c-->0' "$ROOT/README.md")" || true
{ [ -n "$_skill_pass" ] && [ -n "$_readme_pass" ]; } \
    && pass "…and both layers still carry the passage that tells an author about them" \
    || die "the refusal passage is gone from SKILL.md or README.md (skill=${#_skill_pass} readme=${#_readme_pass})"
for _m in $_mk_set; do
    { printf '%s' "$_skill_pass" | grep -qF "**$_m**" \
        && printf '%s' "$_readme_pass" | grep -qF "**$_m**"; } \
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
        printf '%s' "$manifest" | grep -q "$b" || manifest_missing="$manifest_missing $b"
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
        printf '%s' "$strict_row" | grep -q "$b" || strict_missing="$strict_missing $b"
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
grep -q "ABORT: could not create the session's working directory" "$SKILL" \
    && pass "the working directory's creation is branched on" \
    || die "mktemp is unchecked; a failed create still yields a path"
grep -q "ABORT: the session's working files were not created empty" "$SKILL" \
    && pass "…and each created file is validated as present and empty" \
    || die "the summary file is used without validating what was created"
# AND THE COMPLETION LINE IS THAT VALIDATION'S SUCCESS ARM, not a statement after
# it. `exit` is a builtin a startup file can replace with one that RETURNS, so an
# allocation that refused still reached the pin block below it and reported a
# finished setup naming paths that were unset or somebody else's. Position guards
# what follows a failure; only containment guards what follows a failure that
# could not stop the shell.
_rb_done_ln="$(grep -n 'echo "OWNER=$OWNER REPO=$REPO RB_SCRIPTS=$RB_SCRIPTS SUMMARY_FILE=$SUMMARY_FILE"' "$SKILL" | head -1 | cut -d: -f1)" || true
_rb_empty_ln="$(grep -n "ABORT: the session's working files were not created empty" "$SKILL" | head -1 | cut -d: -f1)" || true
{ [ -n "$_rb_done_ln" ] && [ -n "$_rb_empty_ln" ] && [ "$_rb_done_ln" -lt "$_rb_empty_ln" ]; } \
    && pass "…and setup's completion line is that check's success arm, which a refusal cannot reach" \
    || die "the completion line is not inside the working-file check (done=$_rb_done_ln empty=$_rb_empty_ln)"
# AND THERE IS NO `mktemp` LEFT TO SHADOW. Three calls were three separate
# answers, and `mktemp` is a NAME: a function returning the same existing empty
# path each time passes every validation and leaves all three paths ALIASED — so
# writing the opening account populates the round-summary file, and a first round
# that missed its own summary write posts that account as the summary. The
# directory is built by expansion and created with `mkdir`, which is the
# exclusion, and the three suffixes are literals under it — nothing a command
# returns can make two of them equal. Same answer the transport directory above
# already gives.
_rb_mk_n=0
grep -q '^[A-Z_][A-Z_]*="\$(mktemp' "$SKILL" && _rb_mk_n=1
[ "$_rb_mk_n" = 0 ] \
    && pass "…from a directory built by expansion, with no mktemp to shadow" \
    || die "SKILL.md allocates a working path with mktemp; a shadowed one aliases two of them"
grep -qF 'RB_WORK_DIR="$RB_TMPPARENT/watch-pr-work.$$.$RANDOM$RANDOM$RANDOM"' "$SKILL" \
    && pass "…under the parent the transport read already proved usable" \
    || die "the working directory is not built under the proven parent"
# AND SO IS THE TRANSPORT CANDIDATE — IN A SUBSHELL. `RB_TRY`'s own check matches
# a PREFIX, so a readonly value carrying `..` names a directory under a parent
# nothing proved, and the origin every stage is addressed by would be read from
# it. The probe is a subshell rather than a bare assignment because this bash runs
# in the operator's long-lived shell: measured on bash 5, a failed readonly
# assignment under `errexit` is fatal, so a standalone `RB_TRY=probe-a` ends the
# session before the test after it can run. A subshell inherits the attribute and
# fails for the same reason, and it is tested by `if` — which is where the
# `errexit` exemption comes from too, a command run as a condition being exempt —
# and whose success arm is the rest of the candidate, so a shadowed `continue`
# has nothing to walk past. #146.
_rb_try_ln="$(grep -n '^[[:space:]]*if ( RB_TRY=Probe-A; \[\[ $RB_TRY = Probe-A \]\] ); then$' "$SKILL" | head -1 | cut -d: -f1)" || _rb_try_ln=""
_rb_try_path_ln="$(grep -n 'RB_TRY="$RB_TMPPARENT/watch-pr.$$.$RANDOM$RANDOM$RANDOM"' "$SKILL" | head -1 | cut -d: -f1)" || _rb_try_path_ln=""
{ [ -n "$_rb_try_ln" ] && [ -n "$_rb_try_path_ln" ] && [ "$_rb_try_ln" -lt "$_rb_try_path_ln" ]; } \
    && pass "the transport candidate is probed in a subshell before its path is built" \
    || die "RB_TRY is not probed in a subshell before the path is built (probe=$_rb_try_ln path=$_rb_try_path_ln)"
grep -q '^[[:space:]]*RB_TRY=[Pp]robe-' "$SKILL" \
    && die "RB_TRY is probed with a bare assignment; under errexit that ends the operator's shell" \
    || pass "…and not with a bare assignment, which errexit makes fatal"
# THE FORBIDDEN SHAPE IS NAMED IN FULL, not approximated. Written as a character
# class after the probe — `( RB_TRY=Probe-A[;)]` — it read as though it could
# match the `if` form as well, and a reviewer said so; it cannot, because the
# pattern needs `(` immediately after the leading whitespace and the real line has
# `if ` there. A check whose scope has to be worked out from its regex is one that
# will be "fixed" by someone who works it out wrongly, so it says the whole thing.
grep -qF '( RB_TRY=Probe-A; [[ $RB_TRY = Probe-A ]] ) || continue' "$SKILL" \
    && die "the RB_TRY probe falls through on a shadowed continue; the loop is its success arm" \
    || pass "…and the loop is the probe's success arm, not a shadowable continue after it"

# …AND THE CONSEQUENCES ARE RUN, NOT ONLY MATCHED. The three greps above describe
# a shape; what the fix claims is that a readonly `RB_TRY` carrying a traversal
# value creates NOTHING under the parent it names, and that the operator's shell
# survives to say so. Neither is visible in the text, and `errexit` plus a
# shadowed `continue` is exactly the combination a syntax check cannot see.
#
# THE LOOP ALONE, extracted by its own header and `done`. Running the whole setup
# block would need an origin, a repository and a plugin root; the loop needs a
# parent directory and a `$RB_SCRIPTS` that refuses, which is what makes every
# candidate fall to the bottom.
# THE PROBE AND THE LOOP TOGETHER, since the probe sits BEFORE the loop now and
# the loop is its success arm. Extracting the loop alone leaves `RB_TRY` unprobed,
# so the readonly traversal value goes straight to the prefix check — the cases
# below would then be exercising the defect rather than the fix.
_rb_loop="$(awk '/^[[:space:]]*if \( RB_TRY=Probe-A;/,/^    fi$/' "$SKILL")" || _rb_loop=""
{ [ -n "$_rb_loop" ] \
  && case "$_rb_loop" in *'for RB_TMPPARENT in'*) true ;; *) false ;; esac; } \
    && pass "the RB_TRY probe and the loop it guards can be extracted together" \
    || die "the probe/loop excerpt is missing one of them; the behavioural cases below prove nothing"
# ITS OWN ALLOCATION, AND GUARDED ON IT. `$_forge_dir` looked like the tree to
# reuse and is removed long before this point, so the whole case was SKIPPED — it
# reported nothing and the mutation that should have turned it red turned nothing
# red at all, which is the failure `CLAUDE.md` calls worse than no fixture.
# The guard is on the validated allocation rather than on `RB_TMPBASE`, which this
# fixture exports and an invoking environment may already carry; and it is a guard
# rather than a `:?` because the probe at the end of this file re-runs everything
# with `mktemp` stubbed, where there is no tree and an unguarded path under an
# empty variable writes to `/parent`.
_rb_bt=""
_rb_bt="$(mktemp_d)" || _rb_bt=""
if [ -n "$_rb_bt" ] && [ -d "$_rb_bt" ]; then
mkdir -p "$_rb_bt/parent/watch-pr.anchor" "$_rb_bt/parent/attacker"
printf '%s\n' "$_rb_loop" > "$_rb_bt/loop.sh"
# `set -e` AND a shadowed `continue` AND the attribute, together — each alone is
# survivable and the combination is what the fix is about. `RB_SCRIPTS` names
# nothing, so a candidate that got as far as the helper would be rejected there;
# what must not happen is getting as far as `mkdir`.
#
# THREE ATTRIBUTES, because the probe answers one question and three states make
# it "no". The readonly carries a TRAVERSAL value, which is what #146 was about:
# it satisfies the prefix check the probe stands in front of. The transforming
# ones are #150: they let the subshell's assignment SUCCEED and store something
# else, so only the comparison inside it refuses them — and `declare -l` is
# bash 4.0+, so this shell is asked rather than assumed.
#
# WHAT EACH ASSERTION SEES. The diagnostic is the discriminating one: with the
# probe removed, or asked inside the loop where its failure had nowhere to go,
# `RB_TRY` is never named and the emptiness check's message about `TMPDIR` and
# `HOME` comes out instead. The creates-nothing line is an absence check beside
# it, and it discriminates only for the READONLY state, where the unprobed loop
# reaches `mkdir` — for the transforming ones the rewritten path fails the PREFIX
# check first, since `$RB_TMPPARENT` is not itself rewritten and this scratch root
# carries `mktemp`'s mixed case. Staging the case where a transformed path does
# reach `mkdir` needs an all-lowercase parent, which is a fixed path outside
# `mktemp` and not something a fixture may take.
_rb_bt_states="readonly RB_TRY=\"\$TMPDIR/watch-pr.anchor/../attacker/session\"|declare -i RB_TRY=0"
if [ "$_rb_has_l" = yes ]; then _rb_bt_states="$_rb_bt_states|declare -l RB_TRY=x"; fi
_rb_bt_rest="$_rb_bt_states"
while [ -n "$_rb_bt_rest" ]; do
    _rb_bt_attr="${_rb_bt_rest%%|*}"
    case "$_rb_bt_rest" in *'|'*) _rb_bt_rest="${_rb_bt_rest#*|}" ;; *) _rb_bt_rest="" ;; esac
    _rb_bt_out="$(run_limited 25 env TMPDIR="$_rb_bt/parent" bash --noprofile --norc -c '
set -e
continue() { return 0; }
'"$_rb_bt_attr"'
RB_SCRIPTS=/nonexistent-rb-scripts
. "$1"
printf "SURVIVED rb_tmpdir=[%s]\n" "${RB_TMPDIR:-}"' _ "$_rb_bt/loop.sh" 2>&1 || true)"; _rb_bt_rc=$?
    # THE DIAGNOSTIC IS THE ASSERTION. Asked inside the loop the probe's failure
    # had nowhere to go — every candidate was skipped and the emptiness check
    # afterwards blamed `TMPDIR` and `HOME`, which is an environment that is fine.
    # What must come out is this variable's own name.
    printf '%s' "$_rb_bt_out" | grep -qF 'ABORT: RB_TRY is readonly or value-transforming in this shell' \
        && pass "…an unusable RB_TRY is refused by name ($_rb_bt_attr)" \
        || die "the RB_TRY case gave rc=$_rb_bt_rc '$_rb_bt_out' ($_rb_bt_attr)"
    printf '%s' "$_rb_bt_out" | grep -qF 'could not read origin into a transport directory' \
        && die "…but the loop ran and blamed TMPDIR and HOME instead ($_rb_bt_attr): '$_rb_bt_out'" \
        || pass "…and the loop's message about TMPDIR and HOME does not follow it ($_rb_bt_attr)"
    _rb_bt_left="$(ls -A "$_rb_bt/parent/attacker" 2>/dev/null)" || _rb_bt_left='THE_SCAN_FAILED'
    [ -z "$_rb_bt_left" ] \
        && pass "…and creates nothing under the parent the traversal value named ($_rb_bt_attr)" \
        || die "the RB_TRY case created '$_rb_bt_left' under the attacker's parent ($_rb_bt_attr)"
done
rm -rf "$_rb_bt" 2>/dev/null || true
fi

grep -qF '/usr/bin/env mkdir -m 700 "$RB_WORK_DIR"' "$SKILL" \
    && pass "…created with mkdir as the exclusion, at mode 700" \
    || die "the working directory is not created with mkdir -m 700 by path"
for _rb_f in SUMMARY_FILE REQUEST_FILE PRIOR_FILE; do
    grep -q "^[[:space:]]*$_rb_f=\"\$RB_WORK_DIR/" "$SKILL" \
        && pass "…and \$$_rb_f is derived from it by a literal suffix" \
        || die "\$$_rb_f is not derived from the single working directory"
    grep -q "\[\[ \$$_rb_f = \"\$RB_WORK_DIR/" "$SKILL" \
        && pass "…and that assignment is read back against the literal" \
        || die "\$$_rb_f is assigned without proving the assignment arrived"
done

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
grep -q '^REVIEW_BUS_REMOTE="$RB_REMOTE" rb_identity \\$' "$SKILL" \
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
    rm -rf "$SETUPTMP"
fi

# ── the accepted merge-mode limitation is recorded on the base ref ────────
# AGENTS.md makes a dated decision record the only thing that can accept a
# limitation; a comment in the diff cannot.
if [ -d "$ROOT/docs/decisions" ]; then
    grep -rql 'REVIEW_MERGE_STRICT' "$ROOT/docs/decisions" >/dev/null 2>&1 \
        && pass "the merge-mode trade-off has a decision record" \
        || die "the --admin default is accepted nowhere a reviewer can weigh it"
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
if grep -vE '^[[:space:]]*#' "$SKILL" | grep -q 'sort -V'; then
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
printf '%s' "$resume_blk" | grep -qF 'pr-phase-state.sh N' \
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
{ printf '%s' "$_ph_else" | grep -qF 'case $? in' \
    && printf '%s' "$_ph_else" | grep -qE '^ *1\)' \
    && printf '%s' "$_ph_else" | grep -qE '^ *\*\)'; } \
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
printf '%s' "$merge_blk" | grep -q 'pr-merge-gate.sh N "\$CODEX_SHA" "\$AUTO_REVIEW"' \
    && pass "…passing the sha captured when the Codex phase closed" \
    || die "the merge gate is not given the validated Codex sha"
# …AND WHICH REVIEWERS THIS MERGE RESTS ON. The stop above offers merging on the
# Codex signoff alone; without this argument that offer is a menu item the gate
# rejects, because it demands a clean Copilot record on the head regardless.
#
# ASSERTED WHERE `merge_blk` EXISTS. Written higher up the file it ran against an
# unset variable — `-u` was not in force for it, so it silently compared nothing
# and reported the gate untold.
printf '%s' "$merge_blk" | grep -q 'pr-merge-gate.sh N "\$CODEX_SHA" "\$AUTO_REVIEW" "\$REVIEWERS"' \
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
{ [ -n "$merge_case" ] && printf '%s' "$merge_case" | grep -qE '^[[:space:]]*3\)'; } \
    && pass "…and the round-boundary pause is distinguished from a refusal" \
    || die "the driver does not tell a merge-gate pause from a block"
# …AND A QUEUED MERGE FROM A COMPLETED ONE. `gh pr merge` reports success for
# ADDING a PR to a merge queue, and the PR can leave that queue without landing.
# Treating rc 4 as success ends the session with the head not on the base branch.
{ [ -n "$merge_case" ] && printf '%s' "$merge_case" | grep -qE '^[[:space:]]*4\)'; } \
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
    # running the suite — when it runs, which it does not while #93 stands, so
    # those two classes are a reviewer's as well for now. Three more stay
    # invisible to that job even when it is on, and the ONLY thing assigning them
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
    bad="$(printf '%s\n' "$hd" | grep -v "<<'EOF'" || true)"
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

# ── the identity parser rejects transports that reach no GitHub server ─────
# `SKILL.md` carries its own copy of the parser, and it is the copy the driver
# runs. `test-pr-identity.sh` can execute the three scripts' copies but not this
# one, so the structural assertion is what covers it.
grep -q 'ssh://\*|git://\*|https://\*|http://\*|git+ssh://\*' "$SCRIPT_DIR/identitylib.sh" \
    && pass "the identity parser accepts only GitHub network transports" \
    || die "the parser reads any URL scheme as a GitHub identity"
grep -q 'reaches no GitHub server' "$SKILL" \
    && pass "…and refuses the rest rather than guessing a host" \
    || die "SKILL.md has no rejection path for an unsupported transport"

# ── acknowledging a check-in takes the gate's status, and names the reviewer ─
# The acknowledgement is the one place the driver records the OPERATOR's
# permission. Reading it out of a pipeline hid the helper's status: a run that
# printed a plausible pause line and then died some other way still yielded
# digits, `sed` still succeeded, and permission was recorded from an unreadable
# probe. And the count is per reviewer, so an unscoped footer acknowledging 41
# Codex rounds is read by a Copilot invocation with 5, trips its ahead-of-count
# guard and blocks that phase for good.
grep -q 'ROUNDS_RC" -eq 3' "$SKILL" \
    && pass "the acknowledgement requires the gate's distinguished pause status" \
    || die "the driver acknowledges a check-in without checking the gate exited 3"
grep -q 'Review-Pause-Acknowledged:\*\* `%s` `%s`' "$SKILL" \
    && pass "the acknowledgement footer names the reviewer and the count" \
    || die "the acknowledgement footer is unscoped and will cross between phases"

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
# The scans below use herestrings rather than `printf | grep`: under `pipefail`,
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
# Every scan in this file uses a herestring rather than `printf | grep`. This is
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
    printf "%s" "$multi" | grep -q EARLYMATCH
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
_setup_code="$(printf '%s\n' "$_setup_block" | grep -v '^[[:space:]]*#')"
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
    _n="$(printf '%s\n' "$1" | grep -cE '(^|[^[:alnum:]_])set[[:space:]]*\+' || true)"
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
    _tr_shape="$(printf '%s\n' "$_tr_guard" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')"
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
    _tr_guard_names="$(printf '%s\n' "$_tr_guard" | grep -c 'BASH_XTRACEFD' || true)"
    tr_writes_once() {   # tr_writes_once <block-code> ; 0 if only the guard names it
        local _n
        _n="$(printf '%s\n' "$1" | grep -c 'BASH_XTRACEFD' || true)"
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
