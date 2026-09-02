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

# ── A FIFO IS REPLACED, NOT OPENED ─────────────────────────────────────────
# The old writes blocked here, waiting for a reader that never came, which is why three
# call sites carried a watchdog. Nothing opens the target now, so there is nothing to wait
# on — and the watchdogs went with the shape that needed them.
if command -v mkfifo >/dev/null 2>&1; then
    rm -f "$TMP/fifo"
    if mkfifo "$TMP/fifo" 2>/dev/null; then
        out="$(run_limited 10 bash -c '. "$1"; rb_write_handoff "$2" fifo-value' _ "$SELF_DIR/writelib.sh" "$TMP/fifo")"; rc=$?
        case "$rc" in
            0) pass "a FIFO at the target is replaced rather than blocked on" ;;
            124|125) die "the write blocked on the FIFO and the watchdog stopped it" ;;
            *) die "a FIFO target gave rc=$rc: '$out'" ;;
        esac
        { [ -f "$TMP/fifo" ] && [ ! -p "$TMP/fifo" ] && [ "$(cat "$TMP/fifo")" = fifo-value ]; } \
            && pass "…leaving a regular file holding the value" \
            || die "the FIFO target is not a regular file holding the value"
    else
        pass "(mkfifo refused on this filesystem; the FIFO target is skipped by name)"
    fi
else
    pass "(no mkfifo on this platform; the FIFO target is skipped by name)"
fi

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
    *"not a regular file after the write"*) pass "…by the postcondition, which names what it found" ;;
    *) die "the directory refusal gave another reason: '$out'" ;;
esac

# ── A SQUATTER ON THE TEMPORARY COSTS A REFUSAL, NOT A TRUNCATION ──────────
#
# The temporary's name carries the caller's path and this shell's pid, so it is guessable.
# What that buys is a refusal: `set -C` makes the create exclusive, so an existing entry at
# that name — a regular file, or a SYMLINK to something precious — fails the open instead
# of being written through.
printf 'PRECIOUS3\n' > "$TMP/victim3"
: > "$TMP/squat"
ln -s "$TMP/victim3" "$TMP/squat.rb-write.$$"
out="$(rb_write_handoff "$TMP/squat" "nope")" \
    && die "a squatted temporary was accepted" \
    || pass "a squatter on the temporary is refused"
[ "$(cat "$TMP/victim3")" = "PRECIOUS3" ] \
    && pass "…and what the squatter's symlink pointed at is untouched" \
    || die "the squatter's symlink was written through: '$(cat "$TMP/victim3")'"
[ ! -s "$TMP/squat" ] \
    && pass "…with the target left as it was" \
    || die "the target was changed despite the refusal"
rm -f "$TMP/squat.rb-write.$$"

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

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
