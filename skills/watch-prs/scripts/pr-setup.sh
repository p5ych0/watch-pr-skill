#!/usr/bin/env -S bash -p
# Everything the driving session needs to start a run, done in a process and handed
# back as ONE VALUE in a file the driver READS.
#
#   pr-setup.sh <dir>
#
#   0  <dir>/origin holds the remote and <dir>/work holds the session's four files
#   1  stopped — the reason is on stderr; nothing was written
#   2  the STORAGE would not take it — the directory could not be created
#      exclusively, or a write inside it failed. The caller retries under a second
#      parent; every other refusal is terminal, because another parent fixes none
#      of them. This is `pr-origin.sh`'s distinction and it is the same one.
#
# WHY THIS IS A SCRIPT AND NOT A FENCE IN `SKILL.md`.
#
# It was 178 executable lines of the document, read on every invocation of the
# skill — 18,450 characters, about a fifth of the whole thing — and nothing
# executed them. #26 closed on the finding that they could not move, because setup
# EXPORTS into the driving session and a child cannot export into its parent. That is
# true of a child's ENVIRONMENT, and it settles less than it looks: what has to cross
# is a VALUE, and a value can cross in a file.
#
# WHAT STAYS IN THE DOCUMENT is what this cannot do for it: finding the scripts at
# all, choosing the parent directory to hand over, the READ itself, and the checks and
# assignments that follow it. See `SKILL.md` § Derive identity.
#
# WHAT THE CALLER MUST STILL DO, and the reason it is not done here:
#
#   - VALIDATE WHAT IT READ. This writes the file; it cannot prove the file the driver
#     reads is the one it wrote. The driver re-derives the identity from what it read,
#     and assigns and proves every other value itself. WHICH object it opened is not
#     something either side can settle today — see #230.
#   - REMOVE THE DIRECTORY. It is the caller's, by construction: this helper is
#     given a name and creates it, and it must survive the call for the read to happen
#     at all — and for the working files inside it to be there when a round needs them. A helper that removed it would be removing the thing it was
#     asked to produce.
#   - PROVE THE PIN. `pr-origin.sh pin` asks whether a CHILD sees this repository,
#     and the child that matters is one the driver starts. Proving it here would
#     prove that this process exports, which is true by construction.
#
# NOTHING HERE IS EXECUTED BY THE CALLER, and that is the whole safety of the
# arrangement. This wrote a file of assignments the driver SOURCED, which made `.` —
# a NAME, in the one shell that cannot re-exec out of its operator's functions — the
# thing carrying the session's identity. It hands back the ORIGIN alone now, in a
# file read with `$(<…)`, so the worst a replaced file can do is give a wrong string,
# which `rb_identity` and the child pin then disagree with.
#
# THE OTHER ELEVEN VALUES WERE NEVER INFORMATION. `OWNER`, `REPO` and `HOST` are what
# `rb_identity` derives from the origin, and the driver runs it anyway; the two
# reviewer logins are constants it proves against their literals; the working
# directory and its four files are a literal suffix under a directory it named
# itself. See `SKILL.md` § Derive identity, which assigns each of them and proves it.
set -uo pipefail

case "$-" in
    *p*) ;;
    *) echo "PR_SETUP status=error reason=not_privileged" >&2; exit 1 ;;
esac

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_SETUP status=error reason=self_dir_unreadable" >&2; exit 1; }

unset -f rb_load 2>/dev/null || {
    echo "PR_SETUP status=error reason=rb_load_uncleared" >&2; exit 1; }
# THE REFUSING STUB, spelled the way every other helper spells it. It is what stops
# `PATH` answering in the loader's place: an undefined `rb_load` is looked up as a
# command, and an executable by that name exiting 0 reports every load successful
# with nothing cleared and no library sourced. The FIRST LOAD is the verification —
# calling an empty `loadlib.sh` leaves this stub, and calling it fails. `return` is
# a builtin nothing can shadow here, because a privileged shell imports no
# functions. #88.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" 2>/dev/null || {
    echo "PR_SETUP status=error reason=loadlib_unreadable" >&2; exit 1; }
rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_SETUP status=error" || exit 1

# WHAT IS REFUSED IS THE SHAPE, NOT THE CHARACTERS. A character class was here —
# `*[!/A-Za-z0-9._-]*` — and it was a regression against the inline setup it
# replaced: the driver builds this name under `$TMPDIR` or `$HOME`, an operator's
# home directory can contain a SPACE, and `bad_dir` is TERMINAL, so a usable second
# parent was never tried and the session ended on a path that works. `pr-origin.sh`
# takes the same kind of argument and restricts no character, which is the shape to
# match. Nothing here ever evaluates the value: it is quoted in the `mkdir`, in
# every redirection and in every `printf`, so an ordinary filesystem character is
# data. What is left is what the checks were for — a value that is missing, one that
# is relative, and one carrying a `..` component.
RB_DIR="${1-}"
case "$RB_DIR" in
    "" | */../* | */..)
        echo "PR_SETUP status=error reason=bad_dir" >&2; exit 1 ;;
    /*) ;;
    *)  echo "PR_SETUP status=error reason=dir_not_absolute" >&2; exit 1 ;;
esac
[ "$#" -eq 1 ] || { echo "PR_SETUP status=error reason=usage" >&2; exit 1; }

# ── the reservation, and giving it back ────────────────────────────────────
#
# EVERYTHING HERE IS `pr-origin.sh`'s SHAPE, and that is deliberate rather than
# convenient: the two helpers take the same kind of argument, publish it in argv the
# same way, and rest on the same accepted record — so a second answer to one question
# would be a second thing to keep true. What that file worked out, and what
# `docs/decisions/2026-08-26-reservation-inference.md` accepts, is reproduced below
# with its reasoning kept short; the long form is there.
#
# THE CLEANUP IS ARMED BEFORE THE RESERVATION IS ATTEMPTED, because `mkdir` is an
# external command: a signal delivered while it runs is handled once it RETURNS, and
# arming afterwards leaves a window where this shell dies with the directory made.
#
# WHICH MEANS THE CLEANUP CAN RUN WHEN THE NAME IS NOT OURS, so it proves that first
# and three facts are needed. `RB_OWNED` is certain and late — set after a successful
# `mkdir`. `RB_PREEXISTED` covers the window before that: a name that held nothing
# when this run began is one this run made. And `-O` refuses a name another ACCOUNT
# holds, which neither flag can see — that is what stops a replacement's own `origin`
# or `o/origin` being unlinked through a path this run no longer owns.
RB_PHASE=reserved
RB_OWNED=no
RB_PREEXISTED=no
RB_INO=
[[ -e $RB_DIR ]] && RB_PREEXISTED=yes
# AND THE OBJECT ITSELF IS HELD, because ownership is not identity. `-O` refuses a
# name another ACCOUNT holds and that is the boundary the record is about — but a
# replacement made by this same account passes every test above, and the cleanup would
# then unlink `env` and `o/origin` THROUGH a path that no longer names what this run
# created.
#
# AN OPEN DESCRIPTOR IS WHAT MAKES THE INODE A DURABLE IDENTITY. A bare inode number
# is not one: an inode freed by a `rmdir` can be handed straight back to the next
# `mkdir`, and the comparison would then accept a different object. While a descriptor
# on the original is open the inode cannot be freed, so it cannot be reused, and the
# number is an identity for as long as this run needs it. Measured: bash opens a
# directory read-only on both platforms this suite runs on.
#
# AND THE LEAF REMOVALS ARE GATED ON HAVING IT. Where the open fails there is no
# durable identity to compare against, so the cleanup falls back to `rmdir` ALONE —
# which cannot unlink anything and leaves a directory behind at worst, the cost the
# accepted record already covers. Nothing unsafe happens on a platform this has not
# been measured on; something is left behind instead.
#
# AND IT IS READ THROUGH THE DESCRIPTOR, NOT THROUGH THE NAME. Recording it as
# `rb_setup_ino "$RB_DIR"` reopened the window one level down: a swap between the
# `exec` and that read records the REPLACEMENT's inode, after which the comparison
# below is replacement against replacement, agrees, and the cleanup unlinks the
# replacement's own files. `/dev/fd/8` names the object this run holds however the
# path has been rearranged since — measured: with the directory removed and recreated
# under it, the held inode is unchanged and the path's is not.
#
# `-L`, AND IT IS LOAD-BEARING. On Linux `/dev/fd/8` is a symlink into `/proc`, so
# without it `ls -di` reports the LINK's inode — a number that has nothing to do with
# the directory and would never match the path's.
#
# `ls -di`, NOT `stat`. `stat -c` is GNU and `stat -f` is BSD, and the `macos-shell`
# job runs this suite with the GNU tools taken off `PATH`. `ls -di` prints the inode
# first on both, and the value is taken by word splitting rather than by `read`.
rb_setup_ino() {   # <path> ; its inode number, or nothing
    set -- $(/usr/bin/env ls -di "$1" 2>/dev/null)
    printf '%s' "${1-}"
    return 0
}
rb_setup_ino_held() {   # the inode of the object descriptor 8 holds, or nothing
    set -- $(/usr/bin/env ls -diL /dev/fd/8 2>/dev/null)
    printf '%s' "${1-}"
    return 0
}
# `[[`, NOT `[`, in every one of these. The condition decides whether files are
# DELETED, and `[` is a name; `[[` is a reserved word the parser handles and nothing
# can stand in for.
#
# `RB_PHASE` PICKS BETWEEN TWO SHAPES. Until a write has happened nothing can be
# inside, so `rmdir` ALONE is correct — it refuses a symlink outright, and it is what
# the accepted record describes when it says the cost is one EMPTY directory. Once a
# write has happened `rmdir` necessarily fails on a directory holding its leaf, so
# the leaves this run named go first. Never `rm -rf`: a recursive removal on a
# replaced name deletes whatever is under it, which is past what any record accepts.
rb_setup_give_back() {   # give back what this run created, for the phase it is in
    [[ $RB_OWNED = yes ]] \
        || { [[ $RB_PREEXISTED = no ]] && [[ -d $RB_DIR ]] && [[ -O $RB_DIR ]]; } \
        || return 0
    [[ -d $RB_DIR ]] && [[ -O $RB_DIR ]] || return 0
    # THE SAME OBJECT, or there is nothing here this run made. Where the inode was
    # never recorded the `mkdir` had not reported success, and the three tests above
    # are what stands; where it was, the name must still resolve to it — and the held
    # descriptor is what makes that number mean the same object rather than one that
    # inherited its inode.
    if [[ -n $RB_INO ]]; then
        [[ "$(rb_setup_ino "$RB_DIR")" = "$RB_INO" ]] || return 0
    fi
    # LEAVES ONLY WHERE THE IDENTITY IS DURABLE, AND THAT NEEDS BOTH HALVES. The held
    # descriptor is what stops the inode being reused; the recorded NUMBER is what the
    # comparison is against, and `ls -di` can fail or print nothing — after which the
    # comparison above is skipped entirely and `RB_HELD=yes` alone would let the leaf
    # removals run against a name this run cannot vouch for. So an empty record is the
    # same answer as a failed open: fall back to `rmdir` alone, which cannot unlink
    # anything and leaves a directory behind at worst.
    if [[ $RB_PHASE = written ]] && [[ $RB_HELD = yes ]] && [[ -n $RB_INO ]]; then
        # THE PIN PROBE'S DIRECTORY FIRST, by one `rmdir`. A refusal between creating
        # it and removing it leaves an empty child under `$RB_DIR`, which the final
        # `rmdir` then trips over — the caller is left a NON-empty published directory
        # where the accepted bound is one empty one.
        /usr/bin/env rmdir "$RB_DIR/pinprobe" 2>/dev/null
        /usr/bin/env rm -f "$RB_DIR/origin" "$RB_DIR/o/origin" 2>/dev/null
        /usr/bin/env rmdir "$RB_DIR/o" 2>/dev/null
        for _g in summary.md request.md prior.txt head.txt; do
            /usr/bin/env rm -f "$RB_DIR/work/$_g" 2>/dev/null
        done
        /usr/bin/env rmdir "$RB_DIR/work" 2>/dev/null
    fi
    /usr/bin/env rmdir "$RB_DIR" 2>/dev/null
    return 0
}
# THE HANDLERS RE-RAISE. A trap REPLACES a signal's terminating action, so one that
# merely returned would leave this shell resuming the work it was killed during — and,
# after a successful write, reporting 0 for a run somebody killed. All four traps are
# IGNORED before the first removal, in one statement: `trap -` restores the DEFAULT,
# which for these is to terminate, so a second signal between two removals would kill
# the shell mid-cleanup; and disarming after the cleanup rather than before leaves it
# re-entrant.
#
# WHAT THEY ADD OVER THE `EXIT` TRAP ALONE IS SMALL, AND SAYING SO IS THE POINT.
# Measured on bash 5: an untrapped fatal `TERM` still runs the `EXIT` trap and still
# reports 143, so on these paths the two shapes are indistinguishable — and
# `test-pr-setup.sh` asserts the INVARIANT, that nothing is left behind and the run
# does not report success, rather than which route produced it. They are here because
# `pr-origin.sh` has them and the two helpers should not differ on a question this
# file has already answered once. Do not read this as a claim that removing them
# changes an outcome.
rb_setup_on_signal() {   # <signal-name> ; give the reservation back and die of it
    trap '' EXIT HUP INT TERM
    rb_setup_give_back
    trap - "$1"
    kill -s "$1" "$$"
}
# SO THE REFUSALS ONLY SAY WHY AND STOP. Cleaning up in them as well meant a refusal
# cleaned and then `exit` fired the trap and cleaned again — and the second pass is
# the dangerous one, because an account watching the published path can recreate it
# between the two.
rb_setup_stop() {   # <reason> <status>
    echo "PR_SETUP status=error reason=$1" >&2
    exit "$2"
}
trap 'trap "" EXIT HUP INT TERM; rb_setup_give_back' EXIT
trap 'rb_setup_on_signal HUP' HUP
trap 'rb_setup_on_signal INT' INT
trap 'rb_setup_on_signal TERM' TERM

# THE DIRECTORY IS THE RESERVATION. `mkdir` without `-p` fails if anything is
# already at the name — a file, a symlink or another account's directory — so the
# exclusion is the create, not a test before it. Same rule as `pr-origin.sh`, and
# for the same reason: a check-then-use here is a window somebody else can stand in.
/usr/bin/env mkdir -m 700 "$RB_DIR" 2>/dev/null && RB_OWNED=yes \
    || { echo "PR_SETUP status=error reason=dir_not_reserved dir=$RB_DIR" >&2; exit 2; }
# HELD OPEN FOR THE LIFE OF THIS PROCESS, which is what stops the inode being reused.
# The descriptor is never read from; it exists so the object cannot be freed.
# THE `2>/dev/null` IS ON A GROUP, NOT ON THE `exec`. Written as
# `exec 8<"$RB_DIR" 2>/dev/null` the redirection has no command to apply to, so it
# applies to THIS SHELL and permanently: every refusal below then printed its reason
# into `/dev/null` and the caller got a status with no line to read. Around a group,
# the stderr redirection is restored when the group ends and the descriptor the `exec`
# opened is not.
RB_HELD=no
{ exec 8<"$RB_DIR"; } 2>/dev/null && RB_HELD=yes
# RECORDED FROM THE DESCRIPTOR, and only where there is one: without the hold there is
# nothing to record an identity FROM, and an inode read through the name would be the
# number of whatever is there now.
[[ $RB_HELD = yes ]] && RB_INO="$(rb_setup_ino_held)"

# ── the origin, through the helper that reads it privileged ────────────────
# NOT `git remote get-url` HERE. `pr-origin.sh` is where that read is hardened, and
# a second copy of it is the duplication `CLAUDE.md` records paying for four times.
# THE PHASE FLIPS BEFORE THE CALL, not after it: `pr-origin.sh` creates `$RB_DIR/o`
# and leaves it for this caller, so from the moment it is started something can be
# inside — and a refusal between the two is exactly when the cleanup has to know.
RB_PHASE=written
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-origin.sh read "$RB_DIR/o" || {
    _rc=$?
    [ "$_rc" -eq 2 ] && rb_setup_stop origin_storage 2
    rb_setup_stop origin_unreadable 1
}
RB_REMOTE=""
RB_REMOTE="$(cat "$RB_DIR/o/origin" 2>/dev/null)" || rb_setup_stop origin_transport 1
# BY NAME AND THEN `rmdir`, for the reason the cleanup gives: this path is inside a
# directory whose name was published in argv, and a recursive removal on it deletes
# whatever a replacement holds.
/usr/bin/env rm -f "$RB_DIR/o/origin" 2>/dev/null
/usr/bin/env rmdir "$RB_DIR/o" 2>/dev/null

[ -n "$RB_REMOTE" ] || rb_setup_stop origin_empty 1
# `$'\n'`, NOT `"$(printf '\n')"`. Command substitution strips trailing newlines, so
# that spelling is the EMPTY string and the pattern `*""*` matches every value —
# which reported every origin multi-line. Caught by running this against a real
# checkout before it had a fixture.
[[ $RB_REMOTE == *$'\n'* ]] && rb_setup_stop origin_multiline 1

# THE IDENTITY IS PROVEN HERE, so the driver reads a value that already parses. It
# re-derives it anyway — see the header — but a remote that cannot be an identity should
# never reach a file the driver will act on.
REVIEW_BUS_REMOTE="$RB_REMOTE" rb_identity || {
    echo "PR_SETUP status=error reason=origin_unusable detail=${RB_IDENTITY_REASON:-}" >&2
    exit 1
}

# THE PIN IS NOT PROVEN HERE, AND CANNOT BE. `pr-origin.sh pin` answers "does a
# child see this repository as its identity", and the child that matters is one the
# DRIVER starts — every stage of the loop is a process the driving shell forks. A
# pin proved inside this helper would be proving that THIS process exports, which is
# true by construction and says nothing about the shell that reads the file.
#
# So it stays in `SKILL.md`, immediately after the export it is about, which that shell
# makes itself. It is one call and one comparison there rather than the
# probe-and-retry it used to be, because this helper has already made the directory
# it needs.

# ── the working files ──────────────────────────────────────────────────────
# FOUR FILES, FROM ONE ALLOCATION, and files rather than shell variables: the text
# is long, contains backticks and quotes, and passing it inline mangles it — while a
# variable is a name a startup file can have made readonly. They are created fresh
# per session, because a reused path is how a stale summary from another round, or
# another pull request, gets posted as if it were this one's.
#
# ONE DIRECTORY AND FOUR PATHS DERIVED FROM IT, not four `mktemp` calls: those would
# be four separate answers, and `mktemp` is a NAME — a function returning the same
# existing empty path each time passes every validation and leaves all four aliased.
#
# WHY THEY ARE FOUR AND NOT FEWER:
#
#   - the round summary must be EMPTY until the round writes it. Sharing one file
#     with the opening account meant a first round whose summary write did not
#     happen left the opening account sitting there — non-empty, well-formed and
#     about the right PR — so `pr-close-round.sh` posted it as the round summary and
#     requested the next pass instead of refusing to close;
#   - the gated head travels in a file because it used to travel in an assignment
#     the driver made AFTER the push, and a readonly name fails that silently —
#     `post` was then handed a head the gate never reported (#202);
#   - the review baseline is a file for the same reason.
#
# CREATED EMPTY BY REDIRECTION ALONE — no command name, so there is none to shadow,
# and a redirection that cannot be made reports it. Each is then proven present and
# empty: a missing one fails closed later anyway, but "fails closed later" is not a
# reason to be unable to say so here.
#
# `set -C` MAKES EVERY ONE OF THOSE OPENS EXCLUSIVE, and it is the difference between
# losing a reservation and destroying somebody's file. A plain `>` opens with O_TRUNC
# and FOLLOWS SYMLINKS: this directory's name is published in argv, so an account that
# can reach it may put a symlink at `work/summary.md` pointing anywhere the operator can
# write, and the redirection would truncate THAT. With noclobber the open is O_EXCL,
# which refuses a regular file and refuses a symlink whether or not its target exists.
# Nothing legitimate is lost — `work/` was created exclusively two lines up, so none of
# these paths can already be there. `>|` is deliberately not used anywhere below; that
# is the spelling that overrides noclobber, and it is what a later edit reaches for when
# this refuses something.
#
# `umask 077` GOES WITH IT: O_EXCL says who may replace the object, the mode says who
# may write it once created, and the caller's umask is whatever the operator's shell
# had. Same pair, same reason, as `pr-origin.sh`.
umask 077
set -C
RB_WORK_DIR="$RB_DIR/work"
/usr/bin/env mkdir -m 700 "$RB_WORK_DIR" 2>/dev/null || rb_setup_stop work_dir 2
for _f in summary.md request.md prior.txt head.txt; do
    : > "$RB_WORK_DIR/$_f" || rb_setup_stop work_files 2
    { [ -f "$RB_WORK_DIR/$_f" ] && [ ! -s "$RB_WORK_DIR/$_f" ]; } \
        || rb_setup_stop work_files_not_empty 2
done

# ── the storage the pin will need ──────────────────────────────────────────
#
# THE DRIVER CALLS `pr-origin.sh pin` AFTER THIS RETURNS, and that call creates a
# directory under the one reserved here. It reports 2 where the storage would not take
# it — and the driver cannot act on that: `work/` and its four files are already
# allocated on THIS parent, so pinning under the other one would leave a session whose
# files are on a filesystem that has just refused a directory, which dies at its first
# round summary rather than here.
#
# SO THE QUESTION IS ASKED INSIDE THE UNIT THAT RETRIES. A parent that cannot take
# another directory fails here, with status 2, and the driver's existing retry moves
# the WHOLE session — files and all — to the second parent. That is the recovery the
# pin used to have on its own, back when the work allocation came after it.
#
# WHAT IT DOES NOT CLOSE is a filesystem that fills between this probe and the pin,
# and nothing can: the two are in different processes. The abort the driver prints
# there says to re-run, which relocates the session as a whole.
# ONE DIRECTORY, CREATED AND REMOVED BY ONE `mkdir` AND ONE `rmdir`, and the shape is
# what matters rather than the count. `docs/decisions/2026-08-26-reservation-inference.md`
# accepts a same-UID race on these names, and the whole of what it accepts rests on one
# sentence: "no data is destroyed, because `rmdir` refuses anything with contents in it".
# A single `rmdir` on a single name keeps that true — a replacement carrying anything
# survives intact, and a replacement that is empty costs the empty directory the record
# already accounts for.
#
# A PAIR BREAKS IT, WHICH IS WHY THERE ISN'T ONE. Probing the pin's leaf as well meant
# creating `pinprobe/leaf` and removing both, and a two-step removal EMPTIES a
# replacement before it removes it: `rmdir leaf` takes the racer's leaf, after which
# `rmdir pinprobe` succeeds on a directory that had contents a moment earlier. Two
# objects destroyed, where the record permits one empty one lost. A file leaf is worse
# still — it needs `rm -f`, which resolves a nested name the held descriptor says
# nothing about.
#
# SO THE LEAF IS NOT PROBED, AND THAT IS A TRADE RATHER THAN AN OVERSIGHT. What goes
# undetected is a filesystem with room for exactly one more inode: it passes here and
# fails the pin's second object. What precedes this probe is `work/` and four files and
# — a few lines below — the origin, six allocations that a filesystem that tight fails
# first. Buying that last case costs the guarantee a base-ref record rests on, and the
# record wins.
/usr/bin/env mkdir -m 700 "$RB_DIR/pinprobe" 2>/dev/null || rb_setup_stop pin_storage 2
/usr/bin/env rmdir "$RB_DIR/pinprobe" 2>/dev/null || rb_setup_stop pin_storage 2

# ── the one value that has to cross ────────────────────────────────────────
#
# THE ORIGIN, AND NOTHING ELSE. This wrote twelve assignments into a file the driver
# SOURCED, and the source was the defect: `.` is a NAME, and `SKILL.md`'s bash runs in
# the operator's long-lived shell where a function by that name can delegate the load,
# read the genuine assignments and hand back a different origin — after which the
# identity derivation and the child pin both agree with the forged value, because both
# are computed from it.
#
# WHAT MADE THE SOURCE UNNECESSARY is that eleven of those twelve values were never
# information: `OWNER`, `REPO` and `HOST` are what `rb_identity` derives from the
# origin and the driver runs it anyway; the two reviewer logins are constants the
# driver already proves against their literals; the working directory and its four
# files are a literal suffix under a directory the driver named. Only the ORIGIN
# crosses a boundary the driver cannot see across — and a single value comes back the
# way `pr-origin.sh` has always sent one, in a file the caller reads with `$(<…)`,
# which is an expansion with no command in it to shadow.
#
# SO THERE IS NO QUOTING HERE, and that whole class is gone with it. The value is
# written raw and read as data; nothing evaluates it, so a remote carrying a quote, a
# `$(…)` or a backtick is a string rather than a thing that must be escaped into
# safety. `pr-origin.sh` writes its answer the same way and for the same reason.
printf '%s\n' "$RB_REMOTE" > "$RB_DIR/origin" || rb_setup_stop origin_write 2

# THE WRITE'S STATUS IS TAKEN AND THE RESULT IS READ BACK. `printf` can report
# success and the write fail at the flush when the redirection is closed, so the
# status alone does not prove the file holds the value; and a caller reading an empty
# or truncated origin would pin the session to it.
[ -s "$RB_DIR/origin" ] || rb_setup_stop origin_write 2
[ "$(cat "$RB_DIR/origin" 2>/dev/null)" = "$RB_REMOTE" ] || rb_setup_stop origin_write 2

# THE EXIT TRAP IS RESET AND THE SIGNAL HANDLERS ARE NOT. Success means the caller
# gets the directory, so the cleanup must not fire on the way out — but a `TERM`
# arriving before the ready line is printed means the caller never reads anything, and
# giving the reservation back is still the right answer there. `pr-origin.sh`
# resets `EXIT` alone for the same reason: disarming the signals too left a window
# where the helper was terminated with no cleanup at all.
trap - EXIT

echo "PR_SETUP status=ready origin=$RB_DIR/origin work=$RB_WORK_DIR"
exit 0
