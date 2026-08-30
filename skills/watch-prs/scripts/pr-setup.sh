#!/usr/bin/env -S bash -p
# Everything the driving session needs to start a run, done in a process and handed
# back as ONE VALUE in a file the driver READS.
#
#   pr-setup.sh <dir>
#
#   0  <dir>/origin holds the remote and <dir>/work holds the session's four files
#   1  stopped — the reason is on stderr
#   2  the STORAGE would not take it — the directory could not be created
#      exclusively, or a write inside it failed. The caller retries under a second
#      parent; every other refusal is terminal, because another parent fixes none
#      of them. This is `pr-origin.sh`'s distinction and it is the same one.
#
# NEITHER REFUSAL IS SIDE-EFFECT-FREE, and a caller should not read one as though it
# were. THIS FILE REMOVES NOTHING — not the reservation, not the transport, not the files
# written inside it — so a refusal at any point leaves whatever THIS process had made by
# then, INCLUDING one that came immediately after the `mkdir` and made only an empty
# directory.
#
# ONE THING CAN STILL DISAPPEAR, AND IT IS NOT THIS FILE'S. `pr-origin.sh read` creates
# `<dir>/o` itself and gives it back on its OWN refusal path — its contract is a directory
# it created, and a refusal that left it would be a leak nothing else collects (#157). So a
# checkout with no readable origin ends with the reservation present and EMPTY: the
# transport was made by that helper and taken back by it. Measured, and the fixture stages
# both sides — an origin that helper cannot READ leaves an empty reservation, while one it
# reads and this file then refuses to PARSE leaves `o/origin` where it is. The scan for
# removals reads this file, so it is the behavioural cases that hold the distinction.
#
# That is the trade:
# `docs/decisions/2026-08-29-setup-leaf-cleanup.md` carries what each attempt at removing
# the contents destroyed. A caller that must not accumulate those is a caller that has to
# collect them itself; the driver does not, because it retries under a second parent and
# an operator can see what is left.
#
# WHY THIS IS A SCRIPT AND NOT A FENCE IN `SKILL.md`.
#
# It was 177 executable lines of the document, read on every invocation of the
# skill — 18,446 characters, about a fifth of the whole thing — and nothing
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
#   - KEEP THE DIRECTORY. It is the caller's, by construction: this helper is given a
#     name and creates it, and it must outlive the call — for the read, and for the four
#     working files inside it that every later stage writes into. The driver removes
#     nothing under it, deliberately: unlinking through a name published in argv can take
#     what replaced it, and THIS file removes nothing for the same reason. A helper that
#     removed the directory would in any case be removing the thing it was asked to
#     produce.
#   - PROVE THE PIN. `pr-origin.sh pin` asks whether a CHILD sees this repository,
#     and the child that matters is one the driver starts. Proving it here would
#     prove that this process exports, which is true by construction.
#
# NOTHING HERE IS EXECUTED BY THE CALLER, and that is what this arrangement buys. This
# wrote a file of assignments the driver SOURCED, which made `.` — a NAME, in the one
# shell that cannot re-exec out of its operator's functions — the thing carrying the
# session's identity. It hands back the ORIGIN alone now, in a file read with `$(<…)`,
# so a replaced file yields a STRING rather than commands running in that shell.
#
# WHICH IS NOT THE SAME AS THE STRING BEING CHECKED, and this comment used to imply it
# was. `rb_identity` asks whether the value IS a usable identity, not whether it is THIS
# checkout's, and the child pin does not re-read the checkout either — `pr-origin.sh
# pin` reports `REVIEW_BUS_REMOTE` as a child sees it, which is the value the driver
# just exported. A planted-but-valid remote therefore agrees with both, because both are
# computed FROM it. That is #230, and it is a property of this handoff on `main` as much
# as here; nothing below closes it, and a reader should not be told otherwise.
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
# data. What is left is what the checks are for — a value that is MISSING, and one that
# is RELATIVE, which cannot be a stable handoff between two processes.
#
# A `..` COMPONENT IS NOT ONE OF THEM, and refusing it was a defect. `pr-origin.sh` takes
# the same kind of argument and restricts nothing, so this refused a directory the helper
# it delegates to would accept — and the driver builds this path from `TMPDIR`, which is
# the operator's to set. `/tmp/base/a/../b` is an ordinary writable directory; refusing it
# ended the session TERMINALLY, since the driver retries a 2 and not a 1, so a usable
# `HOME` was never tried. The path is never evaluated and the components resolve at the
# syscall like any other path's, so there was nothing the check bought.
RB_DIR="${1-}"
case "$RB_DIR" in
    "") echo "PR_SETUP status=error reason=bad_dir" >&2; exit 1 ;;
    /*) ;;
    *)  echo "PR_SETUP status=error reason=dir_not_absolute" >&2; exit 1 ;;
esac
[ "$#" -eq 1 ] || { echo "PR_SETUP status=error reason=usage" >&2; exit 1; }

# ── the reservation, which is never given back ─────────────────────────────
#
# THIS HELPER REMOVES NOTHING. Not the leaves it wrote, not the transport, and not the
# reservation itself — so a refusal leaves whatever it had made at that point, and a
# successful run leaves the directory for the caller, which is the point of the call.
#
# THAT IS WHERE SEVERAL REVIEW ROUNDS ENDED, one shape at a time, and each shape was
# removed because it destroyed something. `docs/decisions/2026-08-29-setup-leaf-cleanup.md`
# carries the table: `rm -rf` took a replacement's whole tree; a named `rm -f` per leaf
# took a replacement's file; a ledger of what this run had created missed whatever a
# signal landed in front of; removing the directories unconditionally took a watcher's
# empty directory at a name this run never reached; and the last shape — one `rmdir` on
# the reservation, gated on an inode compared against a held descriptor — is a
# CHECK-THEN-USE, because `rmdir` resolves the NAME again after the comparison. A racer
# that replaces the directory in that window has its replacement taken.
#
# EVERY ONE OF THOSE NEEDED A NAME, and shell has no descriptor-relative removal: no
# `unlinkat`, no `rmdir` on a held directory. There is no shape that removes anything here
# and cannot take something a same-UID process substituted. So nothing is removed.
#
# WHAT IT COSTS is a directory per refused attempt, under `TMPDIR` or `HOME`, holding
# whatever this run had written. Nothing collects it. That is litter, and the record
# accepts it, because the alternative is loss.
#
# THE CLEANUP TRAPS GO WITH IT, and `INT` alone stays for a reason that is not cleanup.
# `EXIT`, `HUP`, `INT` and `TERM` were armed to run that cleanup and there is nothing left
# for them to do: measured on bash 5, an untrapped `HUP` ends the run with 129 and an
# untrapped `TERM` with 143, which is what a caller should see.
#
# `INT` IS NOT ONE OF THOSE. Measured the same way, `kill -INT` at this process while it
# waits on `pr-origin.sh` does not end it — the run continues, creates every working file,
# exits 0 and prints the ready line, so the caller's `if` takes its success arm on a
# session somebody stopped and whoever is watching the terminal is told it started. This
# handler removes NOTHING: it disarms itself and re-raises, which is the whole of it, and
# the caller then sees 130 with whatever had been made left exactly where a refusal leaves
# it. Where `INT` was ignored on entry bash installs no handler at all and the run carries
# on, which is what a process started with `INT` ignored should do.
#
# ARMED HERE RATHER THAN AT THE TOP OF THE FILE, and that placement was tried and taken
# back out. The only child before this point is the substitution that finds this
# directory, and measured with no handler at all an `INT` delivered THERE ends the run
# with 130 — bash treats the two waits differently, and the earlier one needs nothing. So
# arming above it protects no window that can be demonstrated, and a fixture for it passed
# against both placements. `CLAUDE.md` § Tests: prove a fix can fail, or stop.
trap 'trap - INT; kill -INT "$$"' INT

# THE REFUSALS SAY WHY AND STOP, and that is all they do. They used to clean up as well,
# and then the `EXIT` trap cleaned up again behind them — the second pass being the
# dangerous one, since an account watching the published path can recreate it between the
# two. There is no cleanup at all now, so there is nothing to do twice.
rb_setup_stop() {   # <reason> <status>
    echo "PR_SETUP status=error reason=$1" >&2
    exit "$2"
}

/usr/bin/env mkdir -m 700 "$RB_DIR" 2>/dev/null \
    || { echo "PR_SETUP status=error reason=dir_not_reserved dir=$RB_DIR" >&2; exit 2; }
# ── the origin, through the helper that reads it privileged ────────────────
# NOT `git remote get-url` HERE. `pr-origin.sh` is where that read is hardened, and
# a second copy of it is the duplication `CLAUDE.md` records paying for four times.
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-origin.sh read "$RB_DIR/o" || {
    _rc=$?
    [ "$_rc" -eq 2 ] && rb_setup_stop origin_storage 2
    rb_setup_stop origin_unreadable 1
}
RB_REMOTE=""
RB_REMOTE="$(cat "$RB_DIR/o/origin" 2>/dev/null)" || rb_setup_stop origin_transport 1
# AND IT IS LEFT WHERE IT IS, like everything else this helper makes. Removing it meant
# `rm -f` on a nested name followed by `rmdir` on its parent, and that pair destroys a
# REPLACEMENT: the first takes a racer's leaf, after which the second succeeds on a
# directory that had contents a moment ago. What the removal was for does not survive
# examination either — the leaf holds the same origin as the file written below it, the
# directory is mode 700, and it is inside a tree this session keeps for its working files
# anyway. The general rule and its table are beside `rb_setup_stop`.

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
# makes itself. It is one call and one comparison there rather than the probe-and-retry
# it used to be, because this helper has already made the directory it needs — with one
# exception: `pin` creates its own leaf directory under that name, so a same-UID process
# can pre-create it and make the call report 2. The driver retries that once, under a
# second fixed name, which is the cost
# `docs/decisions/2026-08-26-transport-candidate-in-argv.md` bounds an argv squat at.

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
# THE READ-BACK'S OWN STATUS IS TAKEN, and separately from the comparison. Written as
# `[ "$(cat …)" = "$RB_REMOTE" ]` the substitution's status is DISCARDED — the `[`
# supplies its own — so a read that printed the right bytes and then failed was accepted
# as proof the write had landed. `CLAUDE.md` records the same shape for `gh`: anything a
# command prints before failing is not data.
_rb_back=""
_rb_back="$(cat "$RB_DIR/origin" 2>/dev/null)" || rb_setup_stop origin_write 2
[ "$_rb_back" = "$RB_REMOTE" ] || rb_setup_stop origin_write 2

# ── why there is no probe for the storage the pin needs ────────────────────
#
# THERE WAS ONE, AND IT COULD NOT ANSWER ITS OWN QUESTION. `pr-origin.sh pin` creates a
# directory and writes a leaf, and it reports 2 where the storage will not take them —
# which the DRIVER cannot act on, because `work/` and the four files are already on this
# parent by then. So the question was asked here instead, where a refusal is inside the
# unit the driver retries.
#
# A PROBE HAS TO RELEASE WHAT IT TOOK, AND RELEASING MEANS REMOVING A NAME. Keeping the
# objects answers nothing: two inodes taken and held is two the pin then cannot have, so
# a filesystem with exactly enough for setup and the pin passes the probe and fails the
# call — the probe made the very state it was meant to detect. Removing them puts back
# the only class this file has spent six review rounds getting out of: two `rmdir`s on
# two names lose two of a watcher's empty directories, where
# `docs/decisions/2026-08-26-reservation-inference.md` bounds the cost at one, and every
# cleverer shape destroyed something. `docs/decisions/2026-08-29-setup-leaf-cleanup.md`
# carries that table.
#
# SO THE PIN'S STORAGE FAILURE IS TERMINAL, and the recovery is a re-run. That is what it
# was before the probe existed and the reasoning has not changed: pinning under the second
# parent while the round summary and the gated head stay on a filesystem that has just
# refused produces a session which looks set up and dies at its first write, after posting.
# A re-run relocates the session as a whole — `pr-setup.sh` is offered the failing parent
# first, reports 2 for the same reason, and the retry that already exists moves everything.
# `SKILL.md`'s abort says so.
#
# WHAT IS STILL HANDLED IS THE SQUAT, which is the case an accepted record actually bounds:
# a same-UID process pre-creating `$RB_SETUP_DIR/pin` makes the call report 2, and the
# driver retries once under a second fixed name.


echo "PR_SETUP status=ready origin=$RB_DIR/origin work=$RB_WORK_DIR"
exit 0
