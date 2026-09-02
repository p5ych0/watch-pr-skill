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
    # THE TARGET MUST BE ABSENT OR A REGULAR FILE, AND THIS IS NOT THE CONVICTED SHAPE.
    # #245 convicted a check that PRECEDES AN OPEN OF THE SAME NAME, where the race changes
    # what the open hits. Nothing here ever opens the target — not before this test and not
    # after it — so the rename's safety does not rest on the answer. What this refuses is a
    # caller naming something that is not a handoff file, early and with nothing written:
    #
    #   * a DIRECTORY, or a symlink to one. `mv` onto a directory moves the source INSIDE it
    #     and reports success, so without this the temporary lands in a directory the caller
    #     did not mean and only the postcondition below notices.
    #   * a DEVICE or a SOCKET. `mv -f` replaces every non-directory inode it can rename
    #     over, so a run with permission — root in a container, with `/dev/null` named as
    #     the handoff path — would replace the character device with a regular file.
    #   * a FIFO, which is refused rather than replaced. Replacing it is safe and was
    #     briefly the behaviour; refusing keeps the promise `README.md` already makes and
    #     leaves one fewer thing about this handoff that changed.
    #
    # A SYMLINK TO A REGULAR FILE PASSES, and must: `-f` follows the link, and that case is
    # the whole of #263 — the rename then replaces the LINK and leaves the file it pointed
    # at untouched, which is what a plain `>` did not do.
    #
    # WHERE A RACER CHANGES THE ANSWER AFTERWARDS, the postcondition is what catches it and
    # the residue is bounded below. That is the case this test does not close, and does not
    # claim to.
    if [ -e "$1" ] && [ ! -f "$1" ]; then
        echo "'$1' is not a regular file; a handoff target must be a regular file or absent"
        return 1
    fi
    # THE TEMPORARY IS BESIDE THE TARGET, because `mv` must not cross a filesystem: a
    # rename that becomes a copy is no longer atomic, and a reader could see a partial file
    # at the target. The caller's own directory is the one place guaranteed to be on the
    # same filesystem as the caller's own file.
    #
    # AND ITS NAME IS UNPREDICTABLE, which bounds the one residue this library can leave.
    # A racer that turns the target into a directory between the test above and the rename
    # has the temporary land INSIDE that directory under its own basename — so a name built
    # only from the caller's path and this pid could be pre-placed there by the racer as a
    # file worth keeping, and `mv -f` would overwrite it. Two `$RANDOM` draws make the name
    # unguessable at the moment it matters, which turns that from a loss into litter: a
    # file with a name nobody chose, in a directory the racer picked themselves.
    _rb_wh_tmp="$1.rb-write.$$.${RANDOM}${RANDOM}"
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
    # `set -C` MAKES IT O_CREAT|O_EXCL, so an entry already at that name — a regular file, a
    # symlink to something precious, a FIFO — fails the open instead of being written
    # through or waited on. THAT IS NOT THE SAME AS "CANNOT BLOCK": pathname resolution and
    # the write itself can still stall on an unresponsive filesystem, which is why the
    # callers that were bounded before still are.
    if [ "$2" = value ]; then
        ( set -C; printf '%s\n' "$3" > "$_rb_wh_tmp" ) 2>/dev/null \
            || { echo "could not create '$_rb_wh_tmp' exclusively and write it; the name is taken, its directory is unwritable, or the storage refused the bytes"; return 1; }
    else
        ( set -C; > "$_rb_wh_tmp" ) 2>/dev/null \
            || { echo "could not create '$_rb_wh_tmp' exclusively; the name is taken, or its directory is unwritable"; return 1; }
    fi
    # `mv` RATHER THAN `cp`: the point is the rename, and a copy would open the target for
    # writing and be exactly the truncation this exists to remove.
    #
    # NOT `mv -T`, WHICH WOULD SETTLE THE DIRECTORY CASE OUTRIGHT. It is a GNU extension
    # and this suite runs against stock BSD tools on the mac-shaped job, where it is a
    # usage error — so a helper written around it would refuse every write on that
    # platform. The test above is what stands in for it, and the postcondition below is
    # what covers the race the test cannot.
    /usr/bin/env mv -f "$_rb_wh_tmp" "$1" \
        || { echo "could not move '$_rb_wh_tmp' onto '$1'; '$1' is unchanged and the temporary is left behind"; return 1; }
    # AND THE TARGET IS A REGULAR FILE AFTERWARDS, WHICH IS A POSTCONDITION AND NOT A GUARD.
    # It asks what actually happened rather than what was true a moment ago, so a racer that
    # made the target a directory after the test above — the one interleaving that test
    # cannot close — is caught here rather than reported as a successful handoff.
    #
    # The temporary is inside that directory in that case, under its unguessable name, and
    # is left there: nothing in this library removes, for the reason at the top.
    [ -f "$1" ] \
        || { echo "'$1' is not a regular file after the write; it was replaced while the value was crossing, and the value did not cross"; return 1; }
    return 0
}
