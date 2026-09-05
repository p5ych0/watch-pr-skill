#!/usr/bin/env bash
# The handoff write: `rb_write_handoff` and `rb_empty_handoff` in writelib.sh.
#
# These rules were written out at every call site instead of once — a
# `printf … > "$CALLER_NAMED_PATH"` or a bare `>`, every one of them following a symlink.
# Counted from the tree there are TEN call sites in THREE helpers: six in
# `pr-close-round.sh` (two pre-bootstrap emptyings, two `gate` emptyings, the head write,
# the baseline write), three in `pr-copilot-phase.sh`, and one in `pr-request-review.sh` —
# the last found only in review, because its unsafe open was in `SKILL.md` rather than in a
# helper. They are proven against the definition here, and
# `test-pr-identity.sh` proves each caller is wired to it. Issue #263.
set -Eeuo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
. "$SELF_DIR/writelib.sh"

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

for _sym in rb_write_handoff rb_empty_handoff; do
    [ "$(type -t "$_sym" 2>/dev/null)" = function ] \
        || { die "writelib.sh does not define $_sym"; echo "RESULT: FAIL"; exit 1; }
done
TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ── THE ORDINARY WRITE ─────────────────────────────────────────────────────
: > "$TMP/plain"
out="$(rb_write_handoff "$TMP/plain" "a value")" \
    && pass "a value crosses into an existing regular file" \
    || die "the ordinary write refused: '$out'"
[ "$(cat "$TMP/plain")" = "a value" ] \
    && pass "…and reads back as what was written" \
    || die "the target holds '$(cat "$TMP/plain")'"
# THE TERMINATOR IS PART OF THE CONTRACT — #264 made the trailing newline a completion
# delimiter, and `pr-watch.sh` refuses a baseline without one. Asserted on RAW BYTES,
# because `$(…)` strips exactly the byte in question.
printf '%s' 'a value
' > "$TMP/expect"
cmp -s "$TMP/plain" "$TMP/expect" \
    && pass "…terminated with one newline, which the readers require" \
    || die "the target is not byte-for-byte the value plus a newline: $(od -c "$TMP/plain" | head -2)"

# ── AND THE EMPTYING, WHICH IS ZERO BYTES AND NOT A NEWLINE ────────────────
# `gate` is not handing over a value, it is removing a claim, and it wants a file with
# nothing in it. A lone newline would be a different thing that happens to be refused the
# same way today, and encoding it here would make that coincidence load-bearing.
printf 'stale\n' > "$TMP/toempty"
out="$(rb_empty_handoff "$TMP/toempty")" \
    && pass "an emptying replaces a stale value" \
    || die "the emptying refused: '$out'"
{ [ -f "$TMP/toempty" ] && [ ! -s "$TMP/toempty" ]; } \
    && pass "…leaving a zero-byte regular file" \
    || die "the emptied target is not zero bytes: $(od -c "$TMP/toempty" | head -1)"

# ── A SYMLINK AT THE TARGET LOSES THE LINK, NEVER THE FILE ─────────────────
#
# THIS IS THE WHOLE OF #263. `>` follows a symlink, so every one of the ten handoff sites
# this library replaced would truncate whatever the link pointed at — an arbitrary file of the
# operator's, outside the session's working directory, on every invocation that got that
# far. `rename(2)` replaces the NAME, so the link goes and its target does not.
printf 'PRECIOUS\n' > "$TMP/victim"
ln -s "$TMP/victim" "$TMP/link"
out="$(rb_write_handoff "$TMP/link" "replacement")" \
    && pass "a write onto a symlink succeeds" \
    || die "the symlink write refused: '$out'"
[ "$(cat "$TMP/victim")" = "PRECIOUS" ] \
    && pass "…and the file the link pointed at is UNTOUCHED" \
    || die "the symlink's target was written through: '$(cat "$TMP/victim")'"
{ [ -f "$TMP/link" ] && [ ! -L "$TMP/link" ] && [ "$(cat "$TMP/link")" = replacement ]; } \
    && pass "…with a regular file at the name, holding the value" \
    || die "the name is not a regular file holding the value"
# AND THE CONTRAST IS MEASURED RATHER THAN ASSERTED, so the case cannot pass on a
# filesystem where a redirection would not have followed the link either — which would make
# the assertion above true for a reason that has nothing to do with this library.
printf 'PRECIOUS2\n' > "$TMP/victim2"
ln -s "$TMP/victim2" "$TMP/link2"
printf 'through\n' > "$TMP/link2"
[ "$(cat "$TMP/victim2")" = "through" ] \
    && pass "…and a plain redirection on this filesystem DOES write through a symlink" \
    || die "a redirection did not follow the symlink here, so the case above proves nothing"

# ── A TARGET THAT IS NOT A REGULAR FILE IS REFUSED, AND SURVIVES ───────────
#
# The old writes OPENED the caller's path FOR WRITING, so a FIFO blocked for a reader that
# never came and a device or socket was written into. Nothing writes to the target now — the
# value postcondition opens it to READ, past the rename, which is a different question — and
# nothing renames over it either, because `mv -f` replaces every non-directory inode it can, which
# would turn `/dev/null` named as a handoff path into a regular file. The type is refused
# before anything is created.
#
# EACH SHAPE IS ASSERTED TO SURVIVE, not merely to be refused: the point is that the inode
# is still there and still what it was, which a status alone does not say.
if command -v mkfifo >/dev/null 2>&1; then
    rm -f "$TMP/fifo"
    if mkfifo "$TMP/fifo" 2>/dev/null; then
        # CAPTURED WITHOUT LETTING `set -e` END THE FILE. A refusal is the expected
        # outcome here, and a bare `out="$(…)"` whose command fails IS a failed assignment,
        # which under `set -Eeuo pipefail` exits the script — silently, with every case
        # below it unrun and the file reporting nothing.
        rc=0
        out="$(run_limited 10 bash -c '. "$1"; rb_write_handoff "$2" fifo-value' _ "$SELF_DIR/writelib.sh" "$TMP/fifo")" || rc=$?
        case "$rc" in
            1) pass "a FIFO at the target is refused rather than blocked on" ;;
            124|125) die "the write blocked on the FIFO and the watchdog stopped it" ;;
            *) die "a FIFO target gave rc=$rc: '$out'" ;;
        esac
        [ -p "$TMP/fifo" ] \
            && pass "…and the FIFO is still a FIFO" \
            || die "the FIFO target was replaced"
    else
        pass "(mkfifo refused on this filesystem; the FIFO target is skipped by name)"
    fi
else
    pass "(no mkfifo on this platform; the FIFO target is skipped by name)"
fi

# A CHARACTER DEVICE, which is the case that made this a refusal rather than a replacement.
# `mv -f` renames over any non-directory inode the caller may rename, so a run with
# permission — root in a container — replaced the device with a regular file. The assertion
# is on the INODE TYPE, because a status saying "refused" would hold just as well after the
# damage.
#
# ON A DEVICE OF ITS OWN, NEVER `/dev/null`. This case is written to fail if the refusal
# regresses, and under root that failure MODE is the damage: the rename would replace a
# process-wide device with a regular file, taking out concurrently running fixtures and
# whatever else in the container reads from it. A fixture whose failure breaks the machine
# is not self-contained, and this is the one place where the distinction is not academic —
# the suite runs as root in containers. `mknod` needs privilege that a developer machine
# does not have, so the case skips by name where it cannot stage its own device rather than
# reaching for the system's.
_wl_dev="$TMP/nulldev"; rm -f "$_wl_dev"
if command -v mknod >/dev/null 2>&1 && mknod "$_wl_dev" c 1 3 2>/dev/null && [ -c "$_wl_dev" ]; then
    out="$(rb_write_handoff "$_wl_dev" "nope")" \
        && die "a character device target was accepted" \
        || pass "a character device at the target is refused"
    [ -c "$_wl_dev" ] \
        && pass "…and the device is still a character device" \
        || die "the device target was replaced by the handoff write"
    rm -f "$_wl_dev"
else
    pass "(no mknod privilege here; the device target is skipped by name)"
fi

# A SYMLINK TO A DIRECTORY, WHICH ONLY THE TYPE TEST REFUSES. `rename(2)` never follows a
# final symlink, so the exact rename would REPLACE the link and succeed — safe for the
# directory, but not what a caller naming that path meant, and it costs them a link. This is
# the one shape where the test is doing the work rather than arriving earlier: an actual
# directory the rename refuses on its own. Refused by type here, since `-f` follows the link.
rm -rf "$TMP/realdir" "$TMP/dirlink"; mkdir -p "$TMP/realdir"
printf 'KEEPME\n' > "$TMP/realdir/occupied"
ln -s "$TMP/realdir" "$TMP/dirlink"
out="$(rb_write_handoff "$TMP/dirlink" "nope")" \
    && die "a symlink-to-directory target was accepted" \
    || pass "a symlink to a directory is refused"
[ "$(cat "$TMP/realdir/occupied")" = KEEPME ] \
    && pass "…and nothing was moved into the directory it pointed at" \
    || die "the directory the link pointed at was written into"
_wl_stray="$(find "$TMP/realdir" -name '*.rb-write.*' 2>/dev/null | head -1)"
[ -z "$_wl_stray" ] \
    && pass "…leaving no temporary inside it" \
    || die "a temporary was left in the linked directory: $_wl_stray"

# ── A DIRECTORY AT THE TARGET IS A REFUSAL, AND THE RENAME IS WHAT REFUSES IT ──
#
# THE EXACT RENAME REFUSES A DIRECTORY DESTINATION ON ITS OWN — `rename(2)` will not put a
# file over one — so the type test below is an EARLIER refusal with no temporary created,
# not the thing that makes this safe. The two-operand `mv` would move the source INSIDE the
# directory and report success, which is why the rename must stay exact and why this case
# asserts the reason as well as the outcome.
rm -rf "$TMP/adir"; mkdir -p "$TMP/adir"
out="$(rb_write_handoff "$TMP/adir" "nope")" \
    && die "a directory target was accepted" \
    || pass "a directory at the target is refused"
case "$out" in
    *"is not a regular file; a handoff target must be"*)
        pass "…by the type test, before anything is created" ;;
    *) die "the directory refusal gave another reason: '$out'" ;;
esac
# AND NOTHING WAS CREATED BESIDE IT, which is what refusing by TYPE buys over refusing by
# postcondition: the earlier draft ran the rename first and only then noticed, leaving the
# temporary inside the directory.
# A GLOB RATHER THAN `find -maxdepth`, which is GNU-only: BSD `find` on stock macOS
# rejects it as a usage error, and with the error discarded the `||` fallback turned that
# into "no temporary exists" — the assertion passing without ever running. A pattern that
# matches nothing expands to itself, which `-e` refuses, so no `nullglob` is needed.
_wl_stray2=""
for _wl_c in "$TMP"/adir.rb-write.*; do
    [ -e "$_wl_c" ] && _wl_stray2="$_wl_c"
done
[ -z "$_wl_stray2" ] \
    && pass "…leaving no temporary beside the directory" \
    || die "a temporary was left beside the refused directory: $_wl_stray2"

# ── THE TEMPORARY'S NAME IS UNGUESSABLE, WHICH BOUNDS RESIDUE AND COLLISIONS ──
#
# AND NOT THE DIRECTORY SWAP, which this used to claim. A racer who WAITS for the temporary
# to appear reads its basename out of the directory and can seed exactly that name before
# the rename: the name is unguessable, not unobservable. What prevents the loss there is the
# EXACT-DESTINATION rename, which refuses a directory destination outright — the four
# swapped-target cases above are what prove that, and this assertion must not be read as a
# second line of defence for the same thing.
#
# WHAT IT DOES BUY is the case the racer has NOT seen: an accidental collision between two
# runs, and a name pre-placed before it exists. Both would be refused by the exclusive
# create anyway, so this bounds how often that refusal happens rather than whether it is
# safe.
#
# THIS IS ASSERTED ON THE SOURCE, because a behavioural case would have to PREDICT the name
# and the whole point is that it cannot be predicted from outside the process.
#
# `$RANDOM` IS A BASH BUILTIN, so no `PATH` entry can answer for it — which is why the name
# is built from it rather than from `mktemp`, a command a caller's environment could shadow.
_wl_src="$(grep -v '^[[:space:]]*#' "$SELF_DIR/writelib.sh")" || _wl_src=""
case "$_wl_src" in
    *'_rb_wh_tmp="$1.rb-write.$$.${RANDOM}${RANDOM}"'*)
        pass "the temporary's name carries two \$RANDOM draws, so it cannot be predicted before it exists" ;;
    *) die "the temporary's name is not built from \$RANDOM; a racer could predict it" ;;
esac
# AND THE CREATE IS `O_CREAT|O_EXCL` RATHER THAN NOCLOBBER, which is the difference between
# refusing a collision and refusing SOME collisions. Bash's `set -C` does what POSIX says —
# the redirection fails if the file exists and is a REGULAR file — so a FIFO pre-placed at
# the temporary's name was opened and the write blocked. The behavioural case below proves
# the outcome; this asserts the mechanism, because a change back to a redirection would look
# harmless and the FIFO case is the only thing that would catch it.
case "$_wl_src" in
    *'set -C'*) die "the create is back to noclobber, which does not refuse a non-regular inode" ;;
    *'O_WRONLY|O_CREAT|O_EXCL'*) pass "…and the create is a real O_EXCL open, so any collision refuses" ;;
    *) die "the value write is not an exclusive create" ;;
esac
# AND THE READ-BACK IS NON-BLOCKING, WITH THE TYPE TAKEN FROM THE HANDLE. This is the half
# no behavioural case can reach: the `[ -f ]` before the read catches every FIFO a fixture
# can plant, and the interleaving the fix is for is between that test and the open. A revert
# to `read < "$1"` would leave every behavioural case green and reintroduce the hang, so the
# mechanism is what is asserted — `O_NONBLOCK` so the open of a FIFO returns instead of
# waiting, and `stat($h)` with `-f _` so the type comes from the inode that was opened
# rather than from a test that preceded it.
# ALL THREE READERS ARE COUNTED, NOT MATCHED ONCE. A substring match on the whole source is
# satisfied by any one reader, so stripping `O_NONBLOCK`, `O_NOFOLLOW` or the handle `stat`
# from the EMPTYING reader alone left the check green — and the behavioural emptying case
# swaps its FIFO before the cheap pathname tests, so it could not see that either. A FIFO
# arriving between those tests and the emptying's open would then block a pre-bootstrap
# clearing that has no watchdog. Three readers: the value read-back, the emptying's size
# check, and `rb_handoff_is_sha`.
_wl_opens="$(grep -c 'O_RDONLY|O_NONBLOCK|O_NOFOLLOW' <<<"$_wl_src")" || _wl_opens=0
[ "$_wl_opens" -eq 3 ] \
    && pass "…and all three readers open non-blocking and no-follow, so a FIFO or a link cannot hang or redirect them" \
    || die "$_wl_opens of the three readers open with O_RDONLY|O_NONBLOCK|O_NOFOLLOW; the others resolve the name unsafely"
_wl_fstats="$(grep -c 'stat(\$h)' <<<"$_wl_src")" || _wl_fstats=0
[ "$_wl_fstats" -eq 3 ] \
    && pass "…with all three taking the type from the handle rather than from a preceding test" \
    || die "$_wl_fstats of the three readers fstat the handle they opened"
# AND THE EMPTYING ASKS THE SAME WAY. `[ ! -s "$1" ]` resolves the name a THIRD time after
# `[ ! -L ]` and `[ -f ]`, so a symlink to an empty file or a FIFO swapped in before it was
# measured instead of the file the rename put there — and the call returned 0 with the target
# not the zero-byte regular file it promised. Only the source can see this: the tests above it
# catch every swap a fixture can plant.
case "$_wl_src" in
    *'[ ! -s "$1" ]'*) die "the emptying still asks the size of the NAME; a swap before it is measured instead" ;;
    *'$s[7] == 0'*)   pass "…and the emptying takes its size from the same handle it opened" ;;
    *) die "the emptying does not verify zero bytes from an opened handle" ;;
esac

# ── AN UNWRITABLE DIRECTORY IS A REFUSAL, AND THE TARGET IS UNCHANGED ──────
if [ "$(id -u)" != 0 ]; then
    rm -rf "$TMP/ro"; mkdir -p "$TMP/ro"
    printf 'keep\n' > "$TMP/ro/target"
    chmod 500 "$TMP/ro"
    out="$(rb_write_handoff "$TMP/ro/target" "nope")" \
        && die "an unwritable directory was accepted" \
        || pass "an unwritable containing directory is refused"
    chmod 700 "$TMP/ro"
    [ "$(cat "$TMP/ro/target")" = "keep" ] \
        && pass "…and the target still holds what it did" \
        || die "the target changed: '$(cat "$TMP/ro/target")'"
else
    pass "(running as root, so the unwritable directory is skipped by name)"
fi

# ── NOTHING IS REMOVED, INCLUDING THE TEMPORARY ON A FAILURE ───────────────
#
# `docs/decisions/2026-08-29-setup-leaf-cleanup.md` convicts the removal class: a removal
# resolves a name a same-UID process may have substituted since. So a refusal leaves the
# temporary behind, and that residue is deliberate — asserted here so a later change that
# adds a cleanup has to argue with this case rather than with a comment.
# NON-COMMENT LINES ONLY. The file EXPLAINS that it removes nothing, so an unanchored
# scan finds the explanation and reports the thing it forbids — the prose-for-code
# confusion this suite has paid for more than once.
_wl_code="$(grep -v '^[[:space:]]*#' "$SELF_DIR/writelib.sh")" || _wl_code=""
grep -qE '(^|[^a-z_])(rm|rmdir|unlink)([[:space:]]|$)' <<<"$_wl_code" \
    && die "writelib.sh removes something; the decision record convicts that class" \
    || pass "the library contains no removal of any kind"

# ── A RACER THAT SWAPS THE TARGET AFTER THE TYPE TEST ──────────────────────
#
# THE TWO-OPERAND `mv` IS NOT A RENAME, and that is what this case is about. `mv SRC DEST`
# STATS `DEST` first and, where it resolves to a DIRECTORY, moves the source INSIDE it —
# following a symlink to get there. `rename(2)` never follows a symlink in the final
# component of either operand, so the directory behaviour belongs to the UTILITY.
#
# THE ATTACK NEEDS NO GUESSWORK, which is why the unguessable temporary is not the answer
# here: the racer READS the name out of the directory once it exists, points the target at
# a directory of their own, and puts a file worth keeping there under that name. `mv -f`
# then overwrites it, and the postcondition sees it afterwards — after the loss.
#
# STAGED THROUGH AN `mv` SHIM, which is the only hook between the type test and the rename:
# everything the write does in between is a builtin. The shim receives the temporary's real
# path as its source operand, so it can seed the racer's directory under exactly the right
# basename and swap the target — which is the race, run deterministically rather than hoped
# for.
# BOTH SWAPS AND BOTH RENAME PATHS, which is four cases and not one. A SYMLINK to a
# directory and an ACTUAL directory are different destinations to `mv`, and BSD `mv -h`
# covers only the first — its contract is "if the target is a symbolic link to a directory,
# do not follow it", so a real directory takes the ordinary two-operand path and the loss
# happens behind a flag that reads as if it had been covered. `rename(2)` refuses both, and
# `perl`'s `rename` is that call.
#
# THE BSD PATH IS STAGED BY REJECTING `-T` IN THE SHIM, exactly as a `mv` that does not know
# the option does. Without that this fixture only ever exercises the GNU branch, and the
# `perl` fallback — which is what every non-GNU platform actually runs — would be uncovered.
if command -v mv >/dev/null 2>&1 && command -v perl >/dev/null 2>&1; then
    mkdir -p "$TMP/rbin"
    { printf '#!/bin/sh\n'
      # The source operand is the last-but-one argument; the target is the last.
      printf 'for a in "$@"; do _s="$_t"; _t="$a"; done\n'
      printf 'if [ ! -e "$RB_SWAPPED" ]; then\n'
      printf '  : > "$RB_SWAPPED"\n'
      printf '  if [ "$RB_SWAP" = dir ]; then\n'
      printf '    rm -f "$_t"; mkdir -p "$_t"; _seed="$_t/${_s##*/}"\n'
      printf '  else\n'
      printf '    mkdir -p "$RB_ATTACK"; _seed="$RB_ATTACK/${_s##*/}"\n'
      printf '  fi\n'
      printf '  cp "$RB_KEEP" "$_seed"\n'
      printf '  [ "$RB_SWAP" = dir ] || { rm -f "$_t" && ln -s "$RB_ATTACK" "$_t"; }\n'
      printf 'fi\n'
      # A `mv` THAT DOES NOT KNOW `-T` FAILS ON THE OPTION, having moved nothing.
      printf '[ -n "$RB_NO_T" ] && [ "$1" = -T ] && { echo "mv: illegal option -- T" >&2; exit 1; }\n'
      printf 'exec "$RB_MV_REAL" "$@"\n'; } > "$TMP/rbin/mv"
    chmod +x "$TMP/rbin/mv"
    for _wl_mode in native no-T; do
        for _wl_swap in link dir; do
            _wr="$TMP/racer"; rm -rf "$_wr"; mkdir -p "$_wr/session"
            printf 'the file the racer wants destroyed\n' > "$_wr/keep"
            : > "$_wr/session/handoff"
            _wl_noT=""; [ "$_wl_mode" = no-T ] && _wl_noT=1
            _wl_pathsave="$PATH"
            RB_MV_REAL="$(command -v mv)" RB_KEEP="$_wr/keep" RB_ATTACK="$_wr/attacker" \
                RB_SWAP="$_wl_swap" RB_SWAPPED="$_wr/done" RB_NO_T="$_wl_noT" \
                PATH="$TMP/rbin:$PATH" \
                rb_write_handoff "$_wr/session/handoff" "a value" >/dev/null 2>&1 \
                && _wl_rc=0 || _wl_rc=$?
            PATH="$_wl_pathsave"
            # THE SEEDED FILE SURVIVES IN EVERY COMBINATION, which is the invariant. Where it
            # was seeded differs — inside the racer's own directory for the symlink swap, and
            # inside the directory that replaced the target for the real one — so the search
            # is over both rather than over the one this platform happened to take.
            _wl_seen=""
            for _wl_c in "$_wr/attacker/"* "$_wr/session/handoff/"*; do
                [ -f "$_wl_c" ] && _wl_seen="$_wl_seen$(cat "$_wl_c")"
            done
            [ "$_wl_seen" = 'the file the racer wants destroyed' ] \
                && pass "a $_wl_swap swapped in under $_wl_mode mv does not cost the file the racer seeded" \
                || die "the $_wl_swap swap under $_wl_mode mv left '$_wl_seen' where the racer's file was"
            # AND THE OUTCOME DIFFERS BY SWAP, which asserting survival alone would not see: a
            # symlink to a directory is replaced by the rename and the value crosses, while an
            # actual directory is a destination `rename(2)` refuses, so the write refuses too.
            if [ "$_wl_swap" = link ]; then
                { [ "$_wl_rc" = 0 ] && [ ! -L "$_wr/session/handoff" ] \
                    && [ "$(cat "$_wr/session/handoff")" = "a value" ]; } \
                    && pass "…the link being what the rename replaced, with the value across" \
                    || die "the link swap under $_wl_mode mv gave rc=$_wl_rc"
            else
                { [ "$_wl_rc" != 0 ] && [ -d "$_wr/session/handoff" ]; } \
                    && pass "…and a real directory is refused rather than written into" \
                    || die "the dir swap under $_wl_mode mv gave rc=$_wl_rc"
            fi
            rm -rf "$_wr"
        done
    done
    rm -rf "$TMP/rbin"
else
    pass "…(the swapped-target cases are skipped: this platform has no mv or no perl)"
fi

# ── A HOSTILE PERL ENVIRONMENT IS REMOVED, NOT SURVIVED ────────────────────
#
# `perl` READS ITS ENVIRONMENT BEFORE IT READS THE PROGRAM. `PERL5OPT=-MDefinitelyMissing`
# makes it exit before the first statement, and `PERL5LIB` and `PERLLIB` redirect where it
# finds modules — so an inherited value could stop every handoff in the loop, and while a
# plain-`mv` fallback stood behind the rename it could steer one into the two-operand form
# the exact rename exists to refuse.
#
# `env -i` IS WHY THIS PASSES RATHER THAN REFUSES. The variables are cleared rather than
# listed, so the case asserts the ordinary outcome under sabotage: the value crosses. A
# denylist would need this case per variable and would be one behind the next one.
if command -v perl >/dev/null 2>&1; then
    _wp="$TMP/perlenv"; rm -rf "$_wp"; mkdir -p "$_wp"
    printf 'the previous value\n' > "$_wp/handoff"
    out="$(PERL5OPT=-MDefinitelyMissingModuleForThisTest PERL5LIB=/nonexistent-for-this-test \
        rb_write_handoff "$_wp/handoff" "a value" 2>&1)" && _wl_rc=0 || _wl_rc=$?
    { [ "$_wl_rc" = 0 ] && [ "$(cat "$_wp/handoff")" = "a value" ]; } \
        && pass "a hostile PERL5OPT and PERL5LIB are cleared, so the value still crosses" \
        || die "a sabotaged perl environment reached the handoff: rc=$_wl_rc '$out'"
    rm -rf "$_wp"
else
    pass "…(the perl-environment case is skipped: no perl on this platform)"
fi

# ── A FIFO SWAPPED IN AFTER THE RENAME REFUSES RATHER THAN BLOCKING ────────
#
# THE READ-BACK IS THE ONE OPEN THIS LIBRARY MAKES, so it is the one place a racer can cost
# the caller a HANG rather than a refusal. `[ -f ]` answers before the open, and a FIFO
# swapped in between the two had `read` waiting for a writer that never comes — of the six
# TEN handoffs reach an open of the target now, and seven have no watchdog, and in the round-closing baseline path that hang lands
# AFTER the thread replies are resolved, leaving the round half-closed.
#
# STAGED THROUGH THE `mv` SHIM, which performs the real rename and then replaces the target.
# A shell FUNCTION cannot be the hook: the library invokes `/usr/bin/env`, which resolves
# `mv` on `PATH` and never sees one.
#
# AND THIS CASE ALONE DOES NOT PROVE THE FIX, which is worth saying rather than implying.
# The swap lands before the `[ -f ]` that precedes the read, so that test catches this
# instance whichever open follows it — the interleaving the fix is FOR is between that test
# and the open, which is sub-instruction and cannot be staged from a fixture. What this
# proves is the OUTCOME: a refusal, promptly, with the FIFO still there. The mechanism is
# asserted on the source below, and that is the half that fails if the read goes back to a
# shell redirection.
#
# BOUNDED, AND THE BOUND IS PART OF THE ASSERTION: against a blocking read it never returns,
# so a `124` here is the defect and not a slow machine.
if command -v mkfifo >/dev/null 2>&1 && command -v mv >/dev/null 2>&1 \
   && { : > "$TMP/probe-t"; mv -T -f -- "$TMP/probe-t" "$TMP/probe-t2" 2>/dev/null; }; then
    mkdir -p "$TMP/qbin"
    { printf '#!/bin/sh\n'
      printf 'for a in "$@"; do _t="$a"; done\n'
      printf '"$RB_MV_REAL" "$@" || exit $?\n'
      printf 'rm -f "$_t"; mkfifo "$_t"\n'
      printf 'exit 0\n'; } > "$TMP/qbin/mv"
    chmod +x "$TMP/qbin/mv"
    _wr2="$TMP/postfifo"; rm -rf "$_wr2"; mkdir -p "$_wr2"; : > "$_wr2/handoff"
    rc=0
    # THE ENVIRONMENT GOES ON THE SUBJECT, NOT ON `run_limited`. Prefixing it onto the
    # watchdog puts the shimmed `PATH` in front of the watchdog's own lookup of `timeout`,
    # which `test-testlib.sh` fails the suite for.
    out="$(run_limited 10 env RB_MV_REAL="$(command -v mv)" PATH="$TMP/qbin:$PATH" \
        bash -c '. "$1"; rb_write_handoff "$2" "a value"' \
        _ "$SELF_DIR/writelib.sh" "$_wr2/handoff")" || rc=$?
    case "$rc" in
        124|125) die "the read-back BLOCKED on a FIFO swapped in after the rename" ;;
        0)       die "a FIFO at the target after the rename was reported as a successful handoff" ;;
        *)       pass "a FIFO swapped in after the rename refuses rather than blocking" ;;
    esac
    [ -p "$_wr2/handoff" ] \
        && pass "…and the shim really did leave a FIFO there, so the case proves what it says" \
        || die "the post-rename shim did not leave a FIFO; the refusal came from something else"
    rm -rf "$_wr2" "$TMP/qbin"
else
    pass "…(the post-rename FIFO case is skipped: no mkfifo, or this mv has no -T)"
fi

# ── A FIFO PRE-PLACED AT THE TEMPORARY'S NAME REFUSES RATHER THAN BLOCKING ─
#
# THIS IS WHAT NOCLOBBER COULD NOT DO. `set -C` fails the redirection only when the existing
# file is REGULAR — POSIX says so and bash implements it — so a same-UID watcher that
# predicted the name and left a FIFO there had the open BLOCK, waiting for a reader that
# never comes. Two of the call sites have no watchdog, so that is a hang rather than a
# refusal. `O_CREAT|O_EXCL` has no such exemption.
#
# BOUNDED, because the point of the case is that it does NOT hang: an unbounded call against
# the unfixed library never returns and the file reports nothing at all.
if command -v mkfifo >/dev/null 2>&1; then
    _wq="$TMP/tmpfifo"; rm -rf "$_wq"; mkdir -p "$_wq"
    : > "$_wq/handoff"
    # THE NAME IS THE ONE THE LIBRARY WILL DERIVE, which needs the pid and the two draws it
    # will use — so the FIFO is planted by a child that computes them the same way and then
    # calls the library in that same process. Assigning to `RANDOM` SEEDS the generator, so
    # doing it twice with the same value makes the second pair equal the first: that is how
    # the fixture predicts a name it is the whole point of the design that a racer cannot.
    rc=0
    out="$(run_limited 10 bash -c '
        . "$1"
        RANDOM=1; _t="$2.rb-write.$$.${RANDOM}${RANDOM}"
        mkfifo "$_t" 2>/dev/null || exit 9
        RANDOM=1; rb_write_handoff "$2" "a value"
    ' _ "$SELF_DIR/writelib.sh" "$_wq/handoff")" || rc=$?
    case "$rc" in
        124|125) die "the write BLOCKED on a FIFO at the temporary's name; noclobber does not refuse one" ;;
        9)       pass "(the temporary-FIFO case is skipped: mkfifo refused on this filesystem)" ;;
        0)       die "a FIFO at the temporary's name was accepted: '$out'" ;;
        *)       pass "a FIFO pre-placed at the temporary's name refuses rather than blocking" ;;
    esac
    rm -rf "$_wq"
else
    pass "…(the temporary-FIFO case is skipped: no mkfifo on this platform)"
fi

# ── A SPECIAL TARGET INSTALLED AFTER THE TYPE TEST IS REPLACED, AND THAT IS THE LIMIT ──
#
# THE TYPE TEST ANSWERS WHAT THE CALLER NAMED, ONCE. `rename(2)` takes any non-directory
# destination and no shell-reachable rename can be made conditional on the destination's
# type, so a FIFO a racer installs between the test and the rename is REPLACED rather than
# refused — and a re-check before the rename is the same race one instruction later.
#
# THIS CASE EXISTS TO PIN THAT, not to hide it. The bound is who can be hurt: the inode is
# in the session's own working directory, so anything appearing there mid-write was put
# there by a process that already writes that directory, and what it loses is its own. An
# operator's FIFO at the path was there when the test was asked and IS refused, which the
# case further up proves. If a later change makes the late swap a refusal, this case fails
# and the limit gets re-read rather than silently widened.
if command -v mv >/dev/null 2>&1 && command -v mkfifo >/dev/null 2>&1; then
    mkdir -p "$TMP/fbin"
    { printf '#!/bin/sh\n'
      printf 'for a in "$@"; do _s="$_t"; _t="$a"; done\n'
      printf 'if [ ! -e "$RB_SWAPPED" ]; then : > "$RB_SWAPPED"; rm -f "$_t"; mkfifo "$_t"; fi\n'
      printf 'exec "$RB_MV_REAL" "$@"\n'; } > "$TMP/fbin/mv"
    chmod +x "$TMP/fbin/mv"
    _wf="$TMP/fiforace"; rm -rf "$_wf"; mkdir -p "$_wf"; : > "$_wf/handoff"
    _wl_pathsave="$PATH"
    RB_MV_REAL="$(command -v mv)" RB_SWAPPED="$_wf/done" PATH="$TMP/fbin:$PATH" \
        rb_write_handoff "$_wf/handoff" "a value" >/dev/null 2>&1 \
        && _wl_rc=0 || _wl_rc=$?
    PATH="$_wl_pathsave"
    { [ "$_wl_rc" = 0 ] && [ -f "$_wf/handoff" ] && [ "$(cat "$_wf/handoff")" = "a value" ]; } \
        && pass "a FIFO installed after the type test is replaced, and the value still crosses" \
        || die "the late-swapped FIFO gave rc=$_wl_rc and '$(cat "$_wf/handoff" 2>/dev/null)'"
    rm -rf "$_wf" "$TMP/fbin"
else
    pass "…(the late-swapped FIFO case is skipped: no mv or no mkfifo here)"
fi

# ── A SYMLINK INSTALLED BETWEEN THE TYPE TEST AND THE READ-BACK ────────────
#
# `[ ! -L "$1" ]` IS A TEST AND THE READ-BACK IS AN OPEN, so a racer between the two can
# point the handoff path at a regular file of their own holding exactly the requested bytes:
# `fstat` on the referent says regular, the comparison says equal, and the call returns 0
# with a LINK at the handoff path — after which the driver reads through a path the racer
# controls. `O_NOFOLLOW` refuses the symlink at the open itself.
#
# THE HOOK IS `perl`, NOT `mv`, AND THAT IS WHAT MAKES THE CASE REAL. An `mv` shim swaps
# before the shell tests, so `[ ! -L ]` catches it and the case passes whether or not the
# open follows links — it was written that way first and proved nothing. The read-back'S OWN
# process is the one thing that starts after those tests, so a `perl` shim runs at exactly
# the instant the racer would.
#
# IT SELECTS THE READ-BACK BY ITS PROGRAM. `perl` is invoked twice here — the exclusive
# create and this — and only the read-back's program names `O_RDONLY`, which is true with
# and without `O_NOFOLLOW` so the staging does not depend on the fix being present.
#
# AND THE SHIM CARRIES ITS PATHS INLINE, because `env -i` strips the environment it would
# otherwise read them from — which is the same clearing that makes `PERL5OPT` harmless.
if command -v perl >/dev/null 2>&1; then
    _wn2="$TMP/nofollow"; rm -rf "$_wn2"; mkdir -p "$_wn2"; : > "$_wn2/handoff"
    mkdir -p "$TMP/nfbin"
    { printf '#!/bin/sh\n'
      printf 'case "$*" in\n'
      printf '  *O_RDONLY*)\n'
      printf '    printf "%%s\\n" "a value" > "%s"\n' "$_wn2/decoy"
      printf '    rm -f "%s"; ln -s "%s" "%s" ;;\n' "$_wn2/handoff" "$_wn2/decoy" "$_wn2/handoff"
      printf 'esac\n'
      printf 'exec "%s" "$@"\n' "$(command -v perl)"; } > "$TMP/nfbin/perl"
    chmod +x "$TMP/nfbin/perl"
    rc=0
    out="$(run_limited 10 env PATH="$TMP/nfbin:$PATH" \
        bash -c '. "$1"; rb_write_handoff "$2" "a value"' \
        _ "$SELF_DIR/writelib.sh" "$_wn2/handoff")" || rc=$?
    { [ "$rc" != 0 ] && [ "$rc" != 124 ] && [ "$rc" != 125 ]; } \
        && pass "a symlink installed between the type test and the read-back is refused, even holding the right bytes" \
        || die "a symlinked handoff path with the requested content was accepted (rc=$rc): '$out'"
    [ -L "$_wn2/handoff" ] \
        && pass "…and the shim really did install one, so the case proves what it says" \
        || die "the no-follow shim did not leave a symlink; the refusal came from something else"
    rm -rf "$_wn2" "$TMP/nfbin"
else
    pass "…(the no-follow case is skipped: no perl on this platform)"
fi

# ── A DANGLING SYMLINK IS AN ENTRY, NOT AN ABSENCE ─────────────────────────
#
# `-e` FOLLOWS THE LINK, so a symlink whose referent has gone answers FALSE and the type test
# read it as an absent path — after which the rename replaced the link and reported success.
# The contract accepts an absent path, a regular file, or a symlink resolving to one; a
# dangling link is none of those, and destroying it is destroying something the caller made.
# `-L` is true for a link whatever its referent, so the pair asks "is there an entry here"
# rather than "does this name resolve".
_wd="$TMP/dangling"; rm -rf "$_wd"; mkdir -p "$_wd"
ln -s "$_wd/gone" "$_wd/link"
out="$(rb_write_handoff "$_wd/link" "a value")" \
    && die "a dangling symlink was accepted and replaced" \
    || pass "a dangling symlink at the target is refused"
[ -L "$_wd/link" ] \
    && pass "…and the link is still there" \
    || die "the dangling symlink was replaced by the handoff write"
# AND THE REFERENT WAS NOT CREATED EITHER, which a write through the link would have done.
[ ! -e "$_wd/gone" ] \
    && pass "…with nothing written through it" \
    || die "the handoff write created the dangling link's referent"
rm -rf "$_wd"

# ── A RACER THAT REPLACES THE SOURCE, NOT THE TARGET ───────────────────────
#
# THE TEMPORARY'S NAME IS PUBLISHED THE MOMENT IT EXISTS, and everything above is about the
# TARGET being swapped. The other end is raceable in the same window: a same-UID process can
# replace the temporary's own path with a regular file of its own, and the exact rename then
# moves that inode onto the handoff path faithfully. A type-only postcondition is satisfied —
# a regular file is exactly what arrives — so the helper reports success and the driver reads
# a head this run never gated as though it had.
#
# STAGED THROUGH THE SAME `mv` SHIM, which receives the temporary's real path and can replace
# it before the real rename runs.
if command -v mv >/dev/null 2>&1; then
    mkdir -p "$TMP/sbin"
    { printf '#!/bin/sh\n'
      printf 'for a in "$@"; do _s="$_t"; _t="$a"; done\n'
      printf 'rm -f "$_s"; printf "%%s\\n" "$RB_FORGED" > "$_s"\n'
      printf 'exec "$RB_MV_REAL" "$@"\n'; } > "$TMP/sbin/mv"
    chmod +x "$TMP/sbin/mv"
    _ws="$TMP/srcrace"; rm -rf "$_ws"; mkdir -p "$_ws"
    : > "$_ws/handoff"
    _wl_pathsave="$PATH"
    RB_MV_REAL="$(command -v mv)" RB_FORGED=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
        PATH="$TMP/sbin:$PATH" \
        rb_write_handoff "$_ws/handoff" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        >/dev/null 2>&1 && _wl_rc=0 || _wl_rc=$?
    PATH="$_wl_pathsave"
    [ "$_wl_rc" != 0 ] \
        && pass "a temporary replaced before the rename is refused rather than handed over" \
        || die "a forged source was reported as a successful handoff"
    # AND THE CALLER IS NOT LEFT READING THE FORGERY AS A SUCCESS. The refusal is what the
    # caller branches on, so the assertion above is the contract — this one names what would
    # otherwise reach the driver.
    [ "$(cat "$_ws/handoff")" != aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] \
        && pass "…the value this call asked for having demonstrably not crossed" \
        || die "the forging shim did not actually replace the source, so the case proves nothing"
    rm -rf "$_ws" "$TMP/sbin"
else
    pass "…(the swapped-source case is skipped: no mv on this platform)"
fi

# AND A FORGERY THAT IS THE REQUESTED VALUE FOLLOWED BY A NUL. This is the one shape the
# byte comparison could not see WHILE THE READ STOPPED AT A DELIMITER. `read -d ''` stops AT
# the NUL, so the variable held exactly the expected bytes and the comparison passed — the
# driver's `$(<…)` then drops the trailing NUL and accepts the 40-hex prefix, the gate reports
# success, and the threads are resolved on a head this call never handed over.
#
# THE READ RUNS TO A CLEAN EOF NOW — a `sysread` loop, not a slurp, since a slurp returns
# what arrived before an I/O error — so this is caught by the COMPARISON: the extra bytes come back with the
# rest and the strings differ. The case is kept because the state is still reachable and the
# outcome still matters — and because a reader that stops at a delimiter is an easy thing to
# reintroduce, at which point this goes red rather than the driver going wrong.
if command -v mv >/dev/null 2>&1; then
    mkdir -p "$TMP/nbin"
    { printf '#!/bin/sh\n'
      printf 'for a in "$@"; do _s="$_t"; _t="$a"; done\n'
      printf 'rm -f "$_s"; printf "%%s\\n\\000trailing" "$RB_WANTED" > "$_s"\n'
      printf 'exec "$RB_MV_REAL" "$@"\n'; } > "$TMP/nbin/mv"
    chmod +x "$TMP/nbin/mv"
    _wn="$TMP/nulrace"; rm -rf "$_wn"; mkdir -p "$_wn"; : > "$_wn/handoff"
    _wl_pathsave="$PATH"
    RB_MV_REAL="$(command -v mv)" RB_WANTED=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        PATH="$TMP/nbin:$PATH" \
        rb_write_handoff "$_wn/handoff" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        >/dev/null 2>&1 && _wl_rc=0 || _wl_rc=$?
    PATH="$_wl_pathsave"
    [ "$_wl_rc" != 0 ] \
        && pass "a source carrying the requested value and then a NUL is refused" \
        || die "a NUL-suffixed forgery passed the byte comparison"
    # THE SHIM REALLY DID WRITE THE PREFIX, or the case above passes for the wrong reason.
    # A 40-hex prefix is what the driver's shape check would accept.
    case "$(cat "$_wn/handoff" 2>/dev/null)" in
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa*)
            pass "…and the forgery it refused would have satisfied the driver's shape check" ;;
        *)  die "the NUL shim did not write the expected prefix, so the case proves nothing" ;;
    esac
    rm -rf "$_wn" "$TMP/nbin"
else
    pass "…(the NUL-suffixed source case is skipped: no mv on this platform)"
fi

# ── A HANDOFF PATH THAT BEGINS WITH A DASH ─────────────────────────────────
#
# THE PATH IS THE CALLER'S AND A RELATIVE ONE MAY START WITH `-`. The temporary derived from
# it does too, so without `--` the source reads as an option bundle to `mv` and as a switch
# to `perl`: every attempt fails on the option and a perfectly writable path takes the stage
# down. Run from inside the directory, because that is the only way a path can begin with a
# dash at all.
# THE NAME IS PASSED BARE AND READ BACK AS `./-dashed`, which is the same file by two
# spellings. Passing `./-dashed` to the helper would prove nothing — the leading `.` is what
# stops any of this — and reading it back bare would break the fixture's own commands rather
# than the subject's.
(
    cd "$TMP" || exit 1
    : > ./-dashed
    out="$(rb_write_handoff -dashed "a value")" || { printf 'FAIL - a dash-leading path was refused: %s\n' "$out"; exit 1; }
    [ "$(cat ./-dashed)" = "a value" ] || { printf 'FAIL - a dash-leading path did not receive the value\n'; exit 1; }
    out="$(rb_empty_handoff -dashed)" || { printf 'FAIL - a dash-leading path could not be emptied: %s\n' "$out"; exit 1; }
    [ ! -s ./-dashed ] || { printf 'FAIL - a dash-leading path was not emptied\n'; exit 1; }
) && pass "a handoff path beginning with a dash is a path, not an option" \
  || die "the dash-leading path case failed"

# ── THE READ SIDE: `rb_handoff_is_sha` ────────────────────────────────────
#
# THE DRIVER'S READ LIVES HERE FOR THE REASON THE WRITE DOES. `SKILL.md` asked
# `[[ -f $HEAD_FILE ]]` and then `case "$(<"$HEAD_FILE")"`, which is a test and then a
# separate open of the same name — a FIFO swapped in between them BLOCKS a shell that has no
# watchdog and no non-blocking read, before the thread-resolution step. One `sysopen` with
# `O_NOFOLLOW|O_NONBLOCK`, the type from `fstat` on that handle, and the bytes read by a
# `sysread` loop to a zero-length read and
# matched whole is the only shape that answers about the inode it read.
[ "$(type -t rb_handoff_is_sha 2>/dev/null)" = function ] \
    || die "writelib.sh does not define rb_handoff_is_sha"
_wh="$TMP/sharead"; rm -rf "$_wh"; mkdir -p "$_wh"
_wh_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# THE VALUE THE WRITER PRODUCES IS ACCEPTED, which is the case that has to pass or the driver
# never proceeds — and it is written by the library rather than by hand, so the two halves
# cannot drift apart on the terminator.
_wh_out=""
rb_write_handoff "$_wh/head" "$_wh_sha" >/dev/null 2>&1 \
    && _wh_out="$(rb_handoff_is_sha "$_wh/head")" && [ "$_wh_out" = "$_wh_sha" ] \
    && pass "a head file written by rb_write_handoff is accepted by rb_handoff_is_sha, which hands the value back from the read that validated it" \
    || die "the value this library writes is not accepted by its own reader, or does not come back from it"
# The status travels with the value: a reader that printed the sha and failed is a refusal.
_wh_lying() { printf '%s\n' "$_wh_sha"; return 1; }
_wh_out=""
{ _wh_out="$(_wh_lying)" && [ "$_wh_out" = "$_wh_sha" ]; } \
    && die "a reader that prints the value and returns non-zero passed the value assertion" \
    || pass "…and the assertion refuses a value that arrives with a non-zero status"
# AND THE SHAPES THAT MUST NOT BE. A short id, a long one, uppercase, non-hex, empty, and a
# 40-hex value with anything after it — the last being what a stopping reader would accept.
for _wh_bad in "" "aaaaaaaa" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
               "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
               "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaag" ; do
    printf '%s\n' "$_wh_bad" > "$_wh/bad"
    rb_handoff_is_sha "$_wh/bad" \
        && die "rb_handoff_is_sha accepted '$_wh_bad'" \
        || _wh_ok=1
done
[ "${_wh_ok:-0}" = 1 ] \
    && pass "…and a short, long, uppercase, non-hex or empty value is refused" \
    || die "the bad-shape loop did not run"
# A 40-HEX PREFIX FOLLOWED BY A NUL is the forgery a reader that stops at the delimiter
# accepts, and it is the exact shape the driver's own `$(<…)` would have swallowed.
printf '%s\n\000trailing' "$_wh_sha" > "$_wh/nul"
rb_handoff_is_sha "$_wh/nul" \
    && die "a 40-hex prefix followed by a NUL was accepted as a commit id" \
    || pass "…and a 40-hex prefix followed by a NUL is refused"
# A MISSING TERMINATOR is refused too: every writer here emits one, so its absence means the
# bytes are not what this library wrote.
printf '%s' "$_wh_sha" > "$_wh/noterm"
rb_handoff_is_sha "$_wh/noterm" \
    && die "a head file with no terminating newline was accepted" \
    || pass "…and a value with no terminating newline is refused"
# A SYMLINK TO A GOOD VALUE IS REFUSED AT THE OPEN, which is `O_NOFOLLOW`: the driver must
# read the file the gate wrote, not one a racer pointed the name at.
ln -s "$_wh/head" "$_wh/link"
rb_handoff_is_sha "$_wh/link" \
    && die "a symlink to a valid head file was followed" \
    || pass "…and a symlink is refused at the open rather than followed"
# A FIFO RETURNS INSTEAD OF BLOCKING, which is the whole reason this is not a shell read.
# Bounded, because against a blocking open the case never returns.
if command -v mkfifo >/dev/null 2>&1 && mkfifo "$_wh/fifo" 2>/dev/null; then
    rc=0
    run_limited 10 bash -c '. "$1"; rb_handoff_is_sha "$2"' _ "$SELF_DIR/writelib.sh" "$_wh/fifo" || rc=$?
    case "$rc" in
        124|125) die "rb_handoff_is_sha BLOCKED on a FIFO; the open is not non-blocking" ;;
        0)       die "a FIFO was accepted as a head file" ;;
        *)       pass "…and a FIFO is refused promptly rather than waited on" ;;
    esac
else
    pass "…(the FIFO reader case is skipped: no mkfifo, or this filesystem refused one)"
fi
# AND A MISSING PATH IS A REFUSAL, not an error the caller has to distinguish.
rb_handoff_is_sha "$_wh/absent" \
    && die "an absent path was accepted as a head file" \
    || pass "…and an absent path is refused"
rm -rf "$_wh"

# ── A SUBSTITUTED PARENT DIRECTORY IS FOLLOWED, WHICH IS THE ACCEPTED LIMIT #272 ──
#
# The read resolves the parent of the head file by NAME. A same-UID process that renames
# `work` away and puts a directory holding a FORGED head at the name has that forged head read
# and accepted — the driver's post-gate CONFIRMATION is corrupted, and `CODEX_SHA` (read from
# the same file) carries the forged value forward. It is NOT a completed merge: the merge gate
# reads the durable signoff and the reviewer's verdict, not the work directory, and refuses a
# forged `CODEX_SHA` the reviewer never signed. It is ACCEPTED rather than fixed:
# `docs/decisions/2026-09-03-workdir-parent-substitution.md` measures the bound and prices
# the fix (a file-based `(dev, ino)` is substitutable and ABA-reusable, and a held descriptor
# is not safely acquirable in the driver's bash), and the attacker is a same-UID process that
# already has arbitrary code execution as the operator.
#
# The original head is not a commit id and the substituted one is, so the status alone says
# which inode was read, whatever the reader prints.
_wl_p="$TMP/parentsub"; rm -rf "$_wl_p"; mkdir -p "$_wl_p/work"
printf '%s\n' 'not-a-commit-id' > "$_wl_p/work/head.txt"
mkdir -p "$_wl_p/attacker"
printf '%s\n' 'ffffffffffffffffffffffffffffffffffffffff' > "$_wl_p/attacker/head.txt"
mv "$_wl_p/work" "$_wl_p/work.real"
if ln -s "$_wl_p/attacker" "$_wl_p/work" 2>/dev/null; then
    rb_handoff_is_sha "$_wl_p/work/head.txt" \
        && pass "a substituted work directory is followed to a forged head, not the original invalid one (accepted limit #272)" \
        || die "the parent-substitution limit no longer holds; re-read docs/decisions/2026-09-03-workdir-parent-substitution.md"
else
    pass "(the parent-substitution limit case is skipped: no symlink support here)"
fi
rm -rf "$_wl_p"

# ── THE EMPTYING POSTCONDITION ASKS ONE DESCRIPTOR TOO ─────────────────────
#
# `[ ! -L ]`, `[ -f ]` and `[ ! -s ]` are three separate resolutions of the name, so a racer
# between any two of them is answered about a different inode each time: a symlink to an
# empty file swapped in before the size test made `-s` examine the REPLACEMENT and the call
# return 0 with the target not the zero-byte regular file it promised.
#
# STAGED THROUGH THE `mv` SHIM, WHICH PROVES THE OUTCOME AND NOT THE MECHANISM. The swap
# lands before the `[ ! -L ]` and `[ -f ]` that precede the size question, so those catch it
# whichever way the size is asked — the interleaving the fix is FOR is between them and the
# size test, which is sub-instruction and cannot be staged. What this asserts is that the
# call refuses, promptly, with no hang. The mechanism is asserted on the source below, and
# that is the half that fails if the size goes back to `[ ! -s ]`.
if command -v mv >/dev/null 2>&1 && command -v mkfifo >/dev/null 2>&1 \
   && { : > "$TMP/probe-e"; mv -T -f -- "$TMP/probe-e" "$TMP/probe-e2" 2>/dev/null; }; then
    mkdir -p "$TMP/ebin"
    { printf '#!/bin/sh\n'
      printf 'for a in "$@"; do _t="$a"; done\n'
      printf '"$RB_MV_REAL" "$@" || exit $?\n'
      printf 'rm -f "$_t"; mkfifo "$_t"\n'
      printf 'exit 0\n'; } > "$TMP/ebin/mv"
    chmod +x "$TMP/ebin/mv"
    _we="$TMP/emptyrace"; rm -rf "$_we"; mkdir -p "$_we"; printf 'seed\n' > "$_we/handoff"
    rc=0
    out="$(run_limited 10 env RB_MV_REAL="$(command -v mv)" PATH="$TMP/ebin:$PATH" \
        bash -c '. "$1"; rb_empty_handoff "$2"' \
        _ "$SELF_DIR/writelib.sh" "$_we/handoff")" || rc=$?
    case "$rc" in
        124|125) die "the emptying postcondition BLOCKED on a FIFO at the target" ;;
        0)       die "a FIFO at the target after the rename was reported as a successful emptying: '$out'" ;;
        *)       pass "an emptying whose target is replaced after the rename is refused" ;;
    esac
    rm -rf "$_we" "$TMP/ebin"
else
    pass "…(the emptying-race case is skipped: no mv with -T, or no mkfifo)"
fi

# ── A PARTIAL LIBRARY DOES NOT HAND `_rb_handoff` TO `PATH` ────────────────
#
# The refusing stubs and `rb_load` both check the PUBLIC name. A library truncated after the
# wrappers but before `_rb_handoff` defined the public name and not the private one, passed
# both checks, and then resolved `_rb_handoff` on `PATH` — an executable by that name exiting
# 0 reported a write or a clearing done with nothing touched. The wrappers are defined LAST
# now, so any truncation leaves the public names undefined and the stub refuses.
#
# STAGED AS THE OLD SHAPE WOULD HAVE BEEN CUT: the library up to the line before `_rb_handoff`
# begins, with a logging `_rb_handoff` forger on `PATH`, called through a stubbed child exactly
# as the helpers call it.
_pl="$TMP/partial"; rm -rf "$_pl"; mkdir -p "$_pl/bin"
_pl_cut="$(grep -n '^_rb_handoff() {' "$SELF_DIR/writelib.sh" | head -1 | cut -d: -f1)"
[ -n "$_pl_cut" ] || die "could not find _rb_handoff's definition to cut the library at"
head -n "$((_pl_cut - 1))" "$SELF_DIR/writelib.sh" > "$_pl/writelib.sh"
: > "$_pl/forger.log"
{ printf '#!/bin/sh\n'; printf 'echo forged >> "%s"\n' "$_pl/forger.log"; printf 'exit 0\n'; } > "$_pl/bin/_rb_handoff"
chmod +x "$_pl/bin/_rb_handoff"
printf 'stale\n' > "$_pl/target"
rc=0
run_limited 10 env PATH="$_pl/bin:$PATH" bash -p -c \
    'rb_write_handoff() { return 127; }; . "$1"/writelib.sh 2>/dev/null || exit 9; rb_write_handoff "$2" "new"' \
    _ "$_pl" "$_pl/target" >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] \
    && pass "a library cut before _rb_handoff is refused by the stubbed child" \
    || die "a partial library reported a write done (rc=$rc)"
[ ! -s "$_pl/forger.log" ] \
    && pass "…and the PATH executable named _rb_handoff was never run" \
    || die "the wrapper resolved _rb_handoff on PATH"
[ "$(cat "$_pl/target")" = stale ] \
    && pass "…with the target untouched" \
    || die "a partial library changed the target"
# AND THE ORDER IS ASSERTED ON THE SOURCE, since it is the order that makes the cut above
# leave the public name undefined rather than the private one.
_pl_impl="$(grep -n '^_rb_handoff() {' "$SELF_DIR/writelib.sh" | head -1 | cut -d: -f1)"
_pl_wrap="$(grep -n '^rb_write_handoff() {' "$SELF_DIR/writelib.sh" | head -1 | cut -d: -f1)"
_pl_wrap2="$(grep -n '^rb_empty_handoff() {' "$SELF_DIR/writelib.sh" | head -1 | cut -d: -f1)"
{ [ -n "$_pl_impl" ] && [ -n "$_pl_wrap" ] && [ -n "$_pl_wrap2" ] \
  && [ "$_pl_impl" -lt "$_pl_wrap" ] && [ "$_pl_impl" -lt "$_pl_wrap2" ]; } \
    && pass "…because _rb_handoff is defined before both public wrappers" \
    || die "a public wrapper is defined before _rb_handoff (impl=$_pl_impl write=$_pl_wrap empty=$_pl_wrap2)"
rm -rf "$_pl"

# ── BOTH READERS ESTABLISH CLEAN EOF RATHER THAN ASSUMING IT ─────────────
#
# `local $/` and `<$h>` return the bytes accumulated BEFORE an I/O error, so on a failing
# network or FUSE filesystem a read that delivered the expected value and then failed came
# back looking complete and compared equal. No portable fixture can make a regular file fail
# mid-read, so the mechanism is asserted on the source: both readers loop on `sysread`,
# refuse an undefined return, and end only on a zero-length read.
_wl_readers="$(grep -c 'my \$n = sysread(\$h, my \$buf, 65536);' "$SELF_DIR/writelib.sh")" || _wl_readers=0
[ "$_wl_readers" -eq 2 ] \
    && pass "both readers read with sysread rather than a slurp" \
    || die "$_wl_readers reader(s) use a sysread loop; a slurp returns a matching prefix before an I/O error as success"
_wl_undef="$(grep -c 'exit 6 unless defined \$n;' "$SELF_DIR/writelib.sh")" || _wl_undef=0
[ "$_wl_undef" -eq 2 ] \
    && pass "…and both refuse a read that returned an error" \
    || die "$_wl_undef reader(s) refuse an undefined sysread"
grep -q 'local \$/;' "$SELF_DIR/writelib.sh" \
    && die "a slurp is back in writelib.sh; it returns what arrived before an I/O error" \
    || pass "…and no slurp remains"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
