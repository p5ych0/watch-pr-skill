#!/usr/bin/env bash
# How a value crosses to the caller in a file the CALLER named. Sourced, never executed.
#
# NOT named `test-*.sh`: `pr-selfcheck.sh` and CI both run every `test-*.sh` as a test, and
# a library that ran as one would report a vacuous pass.
#
# WHY THIS EXISTS
#
# Three values cross from a helper to the driver in a file whose path the driver chose: the
# gated head from `pr-close-round.sh`, the review baseline from that helper and from
# `pr-copilot-phase.sh open`, and the signed-off sha from `pr-copilot-phase.sh record`.
# Every one of them was written as `printf … > "$THE_PATH"`, and `>` FOLLOWS A SYMLINK.
#
# So a same-UID process that replaced one of those paths with a symlink had the symlink's
# TARGET truncated — an arbitrary file of the operator's, outside the session's working
# directory entirely, on every invocation that got that far rather than only on a refusal.
# That is #263, and it was seven sites across two helpers, which is why the rule lives here
# rather than in each of them.
#
# WHAT THIS DOES INSTEAD: WRITE, THEN RENAME.
#
#   1. create a temporary beside the target, EXCLUSIVELY, under `set -C`
#   2. write the value into it and take the status
#   3. `mv` it over the target
#
# THE RENAME IS THE WHOLE POINT. `rename(2)` replaces the NAME, so where the target is a
# symlink it is the symlink that goes and never the file it points at. Measured both ways:
# `> target` on a symlink truncates the victim, and `mv src target` on the same symlink
# leaves the victim's bytes untouched and puts a regular file at the name.
#
# AND IT IS NOT A CHECK-THEN-OPEN GUARD, which #245 already convicted and which this must
# not reintroduce. Nothing here asks what is at the target before writing to it: the target
# is never opened at all. `set -C` on the TEMPORARY is not that shape either — it is the
# open itself refusing, not a test preceding one, so there is no window between the question
# and the answer.
#
# A SQUATTER ON THE TEMPORARY COSTS A REFUSAL, NOT A TRUNCATION. The name carries the
# caller's path and this shell's pid, and a same-UID process that gets there first makes the
# exclusive create fail — including where what it left is a symlink, since `set -C` refuses
# any existing path. The run stops with nothing written and nothing renamed.
#
# NO BOUND, AND THAT IS A REMOVAL RATHER THAN AN OVERSIGHT. Three of these sites ran under
# `run_limited` because a plain `>` on a caller-named path can BLOCK: a FIFO there waits for
# a reader that never comes. An exclusive create cannot block — if anything is at the name,
# including a FIFO, the open fails instead of waiting — so the reason for the watchdog is
# gone with the shape that needed it. The read-backs beside these writes keep theirs, and
# must: they open the target by name, where a FIFO can still be waiting.
#
# NOTHING IS REMOVED, INCLUDING ON FAILURE. A write or a rename that fails leaves the
# temporary behind, and this library does not unlink it — `docs/decisions/2026-08-29-setup-leaf-cleanup.md`
# convicts the whole class, because a removal resolves a name a same-UID process may have
# substituted since. The residue is one file in the session's own working directory, which
# is the litter `docs/decisions/2026-09-01-origin-cleanup-races.md` already accepts, and it
# is named so an operator reading the abort can see it.

# TWO ENTRY POINTS, ONE MECHANISM. A value and an emptying are different contents and the
# same problem, and a single function taking "" for both would have to decide what an empty
# value means — a zero-byte file or a lone newline. `gate` wants the first: it is not
# handing over a value, it is removing a claim, and `pr-watch.sh` refuses a zero-byte
# baseline and a newline-only one alike, so the distinction is the caller's to state rather
# than the library's to guess.
#
# rb_write_handoff <target> <content>
#   0  the target now holds <content> followed by one newline
#   1  refused; the reason is on stdout, and the target's CONTENT is unchanged
#
# rb_empty_handoff <target>
#   0  the target is now a zero-byte regular file
#   1  refused; the reason is on stdout, and the target's CONTENT is unchanged
#
# The caller supplies its own abort prose: these are three stages with three consequences,
# and a shared message would name none of them.
rb_write_handoff() { _rb_handoff "$1" value "$2"; }
rb_empty_handoff() { _rb_handoff "$1" empty; }

_rb_handoff() {   # _rb_handoff <target> value|empty [content]
    # THE TEMPORARY IS BESIDE THE TARGET, because `mv` must not cross a filesystem: a
    # rename that becomes a copy is no longer atomic, and a reader could see a partial file
    # at the target. The caller's own directory is the one place guaranteed to be on the
    # same filesystem as the caller's own file.
    _rb_wh_tmp="$1.rb-write.$$"
    # ONE EXCLUSIVE OPEN, AND THE WRITE GOES INTO IT. Creating the temporary and then
    # opening it AGAIN by name to write would be a check-then-open of its own: a same-UID
    # process can replace it between the two, and the second open — a plain `>` — would
    # follow a symlink or block on a FIFO, which is the whole defect this library exists to
    # remove, reproduced inside it. The redirection on the subshell is the only open.
    #
    # VIA A SUBSHELL, so `set -C` does not leak into the caller's shell — these helpers
    # clobber deliberately elsewhere, and turning noclobber on for the rest of the run would
    # be a change nobody asked for.
    #
    # AND THAT OPEN CANNOT BLOCK, which is why none of this needs a watchdog. `set -C`
    # makes it O_CREAT|O_EXCL: where the name is free it creates a regular file, and where
    # anything is there at all — a FIFO waiting for a reader included — it fails instead of
    # waiting. Three of these call sites used to run under `run_limited` for exactly that
    # risk, and the risk is gone with the shape that carried it.
    if [ "$2" = value ]; then
        ( set -C; printf '%s\n' "$3" > "$_rb_wh_tmp" ) 2>/dev/null \
            || { echo "could not create '$_rb_wh_tmp' exclusively and write it; the name is taken, its directory is unwritable, or the storage refused the bytes"; return 1; }
    else
        ( set -C; > "$_rb_wh_tmp" ) 2>/dev/null \
            || { echo "could not create '$_rb_wh_tmp' exclusively; the name is taken, or its directory is unwritable"; return 1; }
    fi
    # `mv` RATHER THAN `cp`: the point is the rename, and a copy would open the target for
    # writing and be exactly the truncation this exists to remove.
    /usr/bin/env mv -f "$_rb_wh_tmp" "$1" \
        || { echo "could not move '$_rb_wh_tmp' onto '$1'; '$1' is unchanged and the temporary is left behind"; return 1; }
    # AND THE TARGET IS A REGULAR FILE AFTERWARDS, WHICH IS A POSTCONDITION AND NOT A GUARD.
    # `mv` onto an existing DIRECTORY moves the source INSIDE it and reports success, so a
    # caller that named a directory would be told its value had crossed when it had not.
    # Asking BEFORE the rename would be the check-then-open shape #245 convicted; asking
    # after is a question about what actually happened, which no race can make stale in the
    # direction that matters — a target that is a regular file now is one the rename put
    # there, and anything else is a refusal.
    #
    # The temporary is inside that directory in this case, and is left there: nothing in
    # this library removes, for the reason at the top.
    [ -f "$1" ] \
        || { echo "'$1' is not a regular file after the write; it was a directory or was replaced, and the value did not cross"; return 1; }
    return 0
}
