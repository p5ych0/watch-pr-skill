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
# IT ANSWERS WHAT THE CALLER NAMED, AND IT IS ASKED ONCE. A special inode a RACER installs
# after this test is REPLACED by the rename rather than refused: `rename(2)` takes any
# non-directory destination, and no rename reachable from a shell can be made conditional on
# the destination's type — a re-check before the rename is the same race one instruction
# later. That is a bounded outcome rather than a hole, and the bound is who can be hurt: the
# inode is in the session's own working directory, so anything appearing there mid-write was
# put there by a process that already writes that directory, and what it loses is its own.
# An operator's FIFO or device at the path was there when this was asked, and IS refused.
# Do not add the re-check; state the limit.
#
# A SQUATTER ON THE TEMPORARY COSTS A REFUSAL, NOT A TRUNCATION. The name carries the
# caller's path and this shell's pid, and a same-UID process that gets there first makes the
# exclusive create fail — including where what it left is a symlink, since `set -C` refuses
# any existing path. The run stops with nothing written and nothing renamed.
#
# NO BOUND HERE, AND THE CALLERS KEEP THEIRS. This library sets no watchdog of its own: it
# is a shell function, and `run_limited` bounds a COMMAND. That is a fact about where the
# bound can live, NOT a claim that none is needed — read the other way it invites a
# maintainer to drop the three that exist and recreate a hang with the phase half-open.
#
# WHAT THE EXCLUSIVE CREATE SETTLES IS THE FIFO AND ONLY THE FIFO. A plain `>` on a
# caller-named path waits for a reader that never comes; `set -C` makes that open fail
# instead. It does not make this function non-blocking: pathname resolution, the write and
# the `mv` can each stall on an unresponsive filesystem. So the three call sites that were
# bounded still are, with `run_limited` moved around a CHILD that sources this library —
# `pr-copilot-phase.sh`'s readiness, baseline and sha writes, the second of which stands
# after the Copilot-signoff revocation, where a hang leaves the phase half-open with no
# diagnostic. The read-backs beside them keep theirs for a reason of their own: they open
# the target by name, where a FIFO can still be waiting.
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
    # AND AN EXACT-DESTINATION `mv`, BECAUSE THE TWO-OPERAND FORM IS NOT A RENAME. `mv SRC
    # DEST` STATS `DEST` FIRST and, where it resolves to a DIRECTORY, moves the source
    # INSIDE it — following a symlink to do so. `rename(2)` does neither: it never follows a
    # symlink in the final component of either operand, so the link is what it replaces.
    # The directory behaviour is the UTILITY's, and it is the whole of the attack: a racer
    # reads the temporary's name out of the directory once it exists — randomness makes a
    # name unguessable, not unobservable — points the target at a directory of their own,
    # and puts a file worth keeping there under that name for `mv -f` to overwrite. The
    # postcondition sees it afterwards, which is after the loss.
    #
    # SO AN EXACT-DESTINATION RENAME IS ASKED FOR FIRST. `-T` is the GNU spelling, and it is
    # attempted as THE REAL OPERATION rather than probed: a `mv` that does not know an option
    # fails on the option, having moved nothing, so the next attempt is safe to make. Probing
    # with `--version` would ask a different question and answer it wrongly, which is #269;
    # probing with a scratch directory would need that directory REMOVED, which is the class
    # `docs/decisions/2026-08-29-setup-leaf-cleanup.md` convicts.
    #
    # BSD `mv -h` IS NOT THE OTHER HALF OF THAT, and it was written here as if it were. Its
    # contract is narrower than `-T`: "if the target is a symbolic link to a directory, do
    # not follow it". A racer who swaps in an ACTUAL DIRECTORY is not a symlink, so `-h`
    # takes the ordinary two-operand path and moves the source inside it — which is the same
    # loss by the other route, behind a flag that reads as if it had been covered.
    #
    # `perl`'s `rename` IS rename(2), and that is the one primitive that covers both: it
    # never follows a symlink in a final component, and it refuses a directory destination
    # outright. Measured both ways. It is second rather than first because `mv` is already a
    # dependency of this loop and `perl` is one more process to justify — and it is reached
    # on every platform whose `mv` lacks `-T`, macOS included, where the CI job already keeps
    # `perl` on its mac-shaped PATH because macOS ships it.
    #
    # A GENUINE REFUSAL IS NOT A REASON TO FALL BACK, which is the whole point of the exit
    # code below. `rename` failing because the destination is a directory is the exact answer
    # this wants, and dropping through to the plain form there would perform the very move
    # the exact form just refused. So `3` means "the rename was made and refused" and stops;
    # anything else means `perl` itself did not run.
    #
    # AND THERE IS NO PLAIN-`mv` FALLBACK, WHICH IS A REMOVAL RATHER THAN A GAP. One was
    # kept, so that a platform with neither spelling still worked — and it turned every way
    # `perl` can fail into the unsafe path. An inherited `PERL5OPT=-MDefinitelyMissing` makes
    # `perl` exit 2 before it reaches `rename`, and the fallback then performed the move the
    # exact form exists to refuse. Telling "perl aborted" from "perl is not installed" means
    # reading an exit status the environment controls; having no fallback needs no such
    # reading. So: `mv -T`, or `perl`, or a refusal. The cost is that a platform with
    # neither cannot run this loop — loudly, with the reason named — and neither platform
    # this project builds and tests on is that platform. `README.md` states the requirement.
    #
    # AND `--` BEFORE THE OPERANDS, ON BOTH. A handoff path is the CALLER'S, and a relative
    # one may begin with `-`: the temporary derived from it does too, so `mv` reads the
    # source as an option bundle and `perl` reads it as a switch. Both attempts then fail on
    # the option, the write refuses, and a path that was perfectly writable takes the stage
    # down. `--` is where each of them stops parsing.
    /usr/bin/env mv -T -f -- "$_rb_wh_tmp" "$1" 2>/dev/null \
        || /usr/bin/env perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' -- "$_rb_wh_tmp" "$1" 2>/dev/null \
        || { echo "could not rename '$_rb_wh_tmp' onto '$1' — it is unchanged and the temporary is left behind. An exact-destination rename is required: 'mv -T' or a working 'perl'"; return 1; }
    # AND THE POSTCONDITION ASKS WHAT IS AT THE TARGET, NOT MERELY WHAT KIND OF THING IT IS.
    # It runs after the rename rather than before it, so it asks what actually happened —
    # which catches the interleaving the type test cannot, a racer making the target a
    # directory after that test. The temporary is inside that directory in that case, under
    # its unguessable name, and is left there: nothing here removes.
    #
    # THE SOURCE IS RACEABLE TOO, and a type check alone cannot see it. The temporary's name
    # is published in the directory the moment it exists, so a same-UID process can replace
    # THAT path — with a symlink, or with a regular file of its own carrying another 40-hex
    # OID — and the exact rename then moves the substituted inode onto the handoff path,
    # faithfully. `[ -f ]` is satisfied, the helper returns 0, and the driver reads a head
    # this run never gated as though it had.
    #
    # SO THE VALUE IS PROVEN, AND A SYMLINK AT THE TARGET IS REFUSED OUTRIGHT. An exact
    # rename leaves a regular file at that name; a link there means what arrived is not what
    # this call put there.
    { [ ! -L "$1" ] && [ -f "$1" ]; } \
        || { echo "'$1' is not a plain regular file after the write; it was replaced while the value was crossing, and the value did not cross"; return 1; }
    if [ "$2" = value ]; then
        # THE RAW BYTES, TERMINATOR INCLUDED, READ WITH A BUILTIN. `$(<…)` strips trailing
        # newlines, so it cannot see the delimiter every reader of these files requires, and
        # `cat` is a name. `read -d ''` reads to the first NUL — which is end of file here —
        # and reports 1 at EOF whether or not it read anything, so the STATUS is not the
        # answer and the comparison is.
        #
        # AND A SUCCESSFUL READ IS A REFUSAL, WHICH IS THE OPPOSITE OF HOW IT LOOKS.
        # `read -d ''` returns 0 only when it FOUND the delimiter, and the delimiter is
        # NUL — so success here means the file carries one. Without this a racer's file
        # holding the requested value followed by a NUL and anything at all compares EQUAL,
        # because the read stopped at the NUL: the value looks like it crossed, the driver's
        # `$(<…)` drops the trailing NUL and accepts the 40-hex prefix, and the round is
        # resolved on a head this call did not hand over. The downstream raw-byte read-backs
        # already treat a delimiter this way.
        _rb_wh_back=
        if IFS= read -r -d '' _rb_wh_back < "$1"; then
            echo "'$1' contains a NUL, so it is not a value this call wrote; the temporary was replaced before the rename, or the target was"
            return 1
        fi
        [ "$_rb_wh_back" = "$3
" ] || { echo "'$1' does not hold what this call wrote; the temporary was replaced before the rename, or the target was, and the value did not cross"; return 1; }
    else
        # ZERO BYTES, ASKED WITHOUT AN OPEN. An emptying has no value to compare, and `-s`
        # answers it from the inode — so this path never opens the target at all, which
        # matters because the pre-bootstrap clearing in `pr-close-round.sh` is unbounded.
        [ ! -s "$1" ] \
            || { echo "'$1' is not empty after the emptying; it was replaced while the claim was being removed"; return 1; }
    fi
    return 0
}
