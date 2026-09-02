#!/usr/bin/env bash
# The handoff write: `rb_write_handoff` and `rb_empty_handoff` in writelib.sh.
#
# These rules were written seven times across `pr-close-round.sh` and
# `pr-copilot-phase.sh` — every one of them a `printf … > "$CALLER_NAMED_PATH"`, and every
# one of them following a symlink. They are proven against the definition here, and
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
# THIS IS THE WHOLE OF #263. `>` follows a symlink, so every one of the seven writes this
# library replaced would truncate whatever the link pointed at — an arbitrary file of the
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
# The old writes OPENED the caller's path, so a FIFO blocked for a reader that never came
# and a device or socket was written into. Nothing opens the target now — and nothing
# renames over it either, because `mv -f` replaces every non-directory inode it can, which
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
# permission — root in a container, with `/dev/null` named as the handoff path — replaced
# the device with a regular file. The assertion is on the INODE TYPE, because a status
# saying "refused" would hold just as well after the damage.
if [ -c /dev/null ]; then
    out="$(rb_write_handoff /dev/null "nope")" \
        && die "a character device target was accepted" \
        || pass "a character device at the target is refused"
    [ -c /dev/null ] \
        && pass "…and /dev/null is still a character device" \
        || die "/dev/null was replaced by the handoff write"
else
    pass "(/dev/null is not a character device here; the device target is skipped by name)"
fi

# A SYMLINK TO A DIRECTORY, which is the shape `mv` redirects INTO rather than over: the
# two-operand directory form moves the source inside, so without this refusal the temporary
# would land in a directory the caller never named — and, with a guessable name, could
# overwrite an entry already there. Refused by type, since `-f` follows the link.
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

# ── A DIRECTORY AT THE TARGET IS A REFUSAL, VIA THE POSTCONDITION ──────────
#
# `mv` onto an existing directory moves the source INSIDE it and reports SUCCESS, so the
# rename's status cannot see this: a caller that named a directory would be told its value
# had crossed when it had not. Asking before the rename would be the check-then-open shape
# #245 convicted; the postcondition asks what actually happened.
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

# ── THE TEMPORARY'S NAME IS UNGUESSABLE, WHICH BOUNDS THE ONE RESIDUE ──────
#
# THIS IS ASSERTED ON THE SOURCE, and the reason is the property itself: a behavioural case
# would have to PREDICT the name to squat it, and the whole point is that it cannot. What
# the randomness is for is the one interleaving the type test above cannot close — a racer
# turning the target into a directory after the test and before the rename, which lands the
# temporary inside a directory of their choosing. With a name built only from the caller's
# path and this pid they could pre-place a file worth keeping under it and have `mv -f`
# overwrite it; with two `$RANDOM` draws they cannot, so the residue is litter rather than
# loss.
#
# `$RANDOM` IS A BASH BUILTIN, so no `PATH` entry can answer for it — which is why the name
# is built from it rather than from `mktemp`, a command a caller's environment could shadow.
_wl_src="$(grep -v '^[[:space:]]*#' "$SELF_DIR/writelib.sh")" || _wl_src=""
case "$_wl_src" in
    *'_rb_wh_tmp="$1.rb-write.$$.${RANDOM}${RANDOM}"'*)
        pass "the temporary's name carries two \$RANDOM draws, so it cannot be pre-placed" ;;
    *) die "the temporary's name is not built from \$RANDOM; a racer could pre-place it" ;;
esac
# AND THE CREATE IS STILL EXCLUSIVE, which is what makes a COLLISION — guessed or accidental
# — a refusal rather than a write through whatever is there.
case "$_wl_src" in
    *'( set -C; printf'*) pass "…and the create is exclusive, so a collision refuses" ;;
    *) die "the value write is not an exclusive create" ;;
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
_wl_exact=""
if command -v mv >/dev/null 2>&1; then
    : > "$TMP/probe-a"
    mv -T -f "$TMP/probe-a" "$TMP/probe-b" 2>/dev/null && _wl_exact=-T
    if [ -z "$_wl_exact" ]; then
        : > "$TMP/probe-a"
        mv -h -f "$TMP/probe-a" "$TMP/probe-b" 2>/dev/null && _wl_exact=-h
    fi
fi
if [ -n "$_wl_exact" ]; then
    _wr="$TMP/racer"; rm -rf "$_wr"; mkdir -p "$_wr/session" "$_wr/attacker"
    printf 'the file the racer wants destroyed\n' > "$_wr/keep"
    : > "$_wr/session/handoff"
    _wl_pathsave="$PATH"; mkdir -p "$TMP/rbin"
    { printf '#!/bin/sh\n'
      # The source operand is the last-but-one argument; the target is the last.
      printf 'for a in "$@"; do _s="$_t"; _t="$a"; done\n'
      printf 'if [ ! -L "$_t" ]; then\n'
      # SEED FIRST, THEN SWAP: the racer's directory has to hold the victim under the
      # temporary's own basename before the rename can be misdirected onto it.
      printf '  ln "$RB_KEEP" "$RB_ATTACK/${_s##*/}" 2>/dev/null || cp "$RB_KEEP" "$RB_ATTACK/${_s##*/}"\n'
      printf '  rm -f "$_t" && ln -s "$RB_ATTACK" "$_t"\n'
      printf 'fi\n'
      printf 'exec "$RB_MV_REAL" "$@"\n'; } > "$TMP/rbin/mv"
    chmod +x "$TMP/rbin/mv"
    RB_MV_REAL="$(command -v mv)" RB_KEEP="$_wr/keep" RB_ATTACK="$_wr/attacker" \
        PATH="$TMP/rbin:$PATH" rb_write_handoff "$_wr/session/handoff" "a value" >/dev/null 2>&1 \
        && _wl_rc=0 || _wl_rc=$?
    PATH="$_wl_pathsave"
    [ "$(cat "$_wr/attacker/"* 2>/dev/null)" = 'the file the racer wants destroyed' ] \
        && pass "a target swapped for a symlink to the racer's directory does not cost the file inside it" \
        || die "the racer's file was overwritten by the rename: '$(cat "$_wr/attacker/"* 2>/dev/null)'"
    # AND THE VALUE STILL CROSSED, because an exact rename replaces the LINK: the swap costs
    # the racer their symlink and nothing else. Asserting only the survival would pass just
    # as well against a refusal that left the handoff empty.
    { [ "$_wl_rc" = 0 ] && [ ! -L "$_wr/session/handoff" ] \
        && [ "$(cat "$_wr/session/handoff")" = "a value" ]; } \
        && pass "…the link being what the rename replaced, with the value across" \
        || die "the swapped target gave rc=$_wl_rc and '$(cat "$_wr/session/handoff" 2>/dev/null)'"
    rm -rf "$_wr" "$TMP/rbin"
else
    pass "…(the swapped-target case is skipped: this mv has neither -T nor -h)"
fi

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
