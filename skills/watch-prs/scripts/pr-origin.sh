#!/usr/bin/env bash
# The session's repository, read where the driving shell's names cannot reach.
#
#   /usr/bin/env bash -p pr-origin.sh read "$RB_ORIGIN_DIR" || abort
#   { [[ -O /dev/fd/9 ]] && [[ -f /dev/fd/9 ]] \
#     && RB_REMOTE="$(<"/dev/fd/9")"; } 9<"$RB_ORIGIN_DIR/origin" || abort
#
# THE DIRECTORY IS THIS SCRIPT'S TO CREATE, and the file inside it is this
# script's to name. The caller passes a path that must NOT exist; `mkdir` here is
# what makes it this run's. It used to pass a file inside a directory it had built
# itself, and building it took a two-candidate loop, three names, three
# assignability probes with cross-variable alias checks and two cleanup arms — in
# the operator's own shell, where every one of those names can be readonly,
# value-transforming or a nameref aimed at another. #146, #148, #150, #151 and
# half of #155 are all that block. None of it is needed on this side of the
# `bash -p`: no functions are imported, no `BASH_ENV` is sourced, and these names
# are this process's. #157.
#
# THE VALUE GOES TO A FILE, IN A DIRECTORY THE CALLER NAMES AND THIS SCRIPT
# CREATES, and that is the third mechanism this script has used. The first two put it on a descriptor — stdout, then fd 9 — and
# both spent rounds of review on the same problem from different angles: whichever
# descriptor carries the value, a caller tracing to it has its trace written into
# the value, and the redirections that would move one out of the way move the
# other into place. Moving the trace target instead closed fd 2 when it was
# restored, so the second call of a session returned nothing at all.
#
# A path has none of those properties. The caller's tracing goes wherever it
# already went, this script writes inside the directory it was told to make, and
# there is no descriptor for the two to collide over.
#
# `/usr/bin/env`, A PATH, BECAUSE `bash` IS A NAME. `bash -p …` calls a function
# called `bash` if the caller has one, and such a function creates the directory
# it was handed, writes a forged URL into it and returns, without this script
# running at all. A path cannot be shadowed.
#
# `bash -p` IS THE CALLER'S PART AND CANNOT BE DELEGATED. Privileged mode is what
# stops `BASH_ENV` being sourced, so it has to be in force before this file's first
# line. A hook needs to shadow nothing to use the gap: one that creates the
# directory it sees as `$2`, writes the value file inside it and exits is a
# complete attack, finished before this script's first line.
# There is no fallback for a caller that forgets — see the block above the guard
# for why one cannot work — so a missing `-p` is refused, not recovered from.
#
# THERE ARE NO BRACES AND NO DESCRIPTORS LEFT TO GET WRONG, which is the point of
# the file. An earlier version of this header required both, and required them for
# a real reason — bash traces a simple command before applying its redirections, so
# the trace landed inside a substitution that was already the capture. Nothing is
# captured now: the usage above is the whole invocation, and a maintainer reading
# the old paragraph would have reintroduced the failure it described.
#
#   0  the second argument is a DIRECTORY this script created, and the value is in
#      its leaf: `<dir>/origin` for `read`, `<dir>/pin` for `pin`. The argument
#      itself is the directory, never the file — a caller that opens it directly
#      opens a directory.
#   1  refused — the reason is on STDERR, and this script does NOT create a value
#      file. The leaf is written by the single redirection that creates it, so
#      nothing here ever leaves a half-written or empty one.
#
#      THAT IS NOT THE SAME AS "THE LEAF IS ABSENT", and the difference is the
#      pre-existing case: where `<dir>` was already there and already held an
#      `origin` or a `pin`, the `mkdir` refuses before anything is written and that
#      leaf — the caller's, or somebody else's — is still there afterwards. Absence
#      is guaranteed only for a refusal AFTER this script created the directory,
#      where the EXIT cleanup, in its post-write phase, removes the leaf and the
#      directory together.
#
#      WHAT IS AT THE ARGUMENT ON STATUS 1 DEPENDS ON WHICH SIDE OF THE `mkdir`
#      the refusal happened, and the two are opposite:
#
#        - BEFORE it — a bad mode, a relative path, or the `mkdir` itself failing
#          because the name is ALREADY TAKEN — nothing here created anything, so
#          nothing here removes anything. A pre-existing directory, file or symlink
#          at that name survives untouched, contents included. That is the
#          exclusion working: a name somebody else got to first is theirs, and a
#          refusal that tidied it up would be this script deleting what it just
#          refused to trust.
#        - AFTER it — an UNSAFE ANCESTOR, the git read, an empty origin, a newline
#          in it, a failed write — this script created the directory, so it gives
#          the directory back before stopping. Nothing is left at the argument and
#          there is nothing for the caller to collect.
#
#          THE CLEANUP HAS ONE BODY AND THREE WAYS IN, and they are not the same
#          thing. An ordinary refusal and any other abnormal end reach it through
#          the `EXIT` trap. A SIGNAL reaches it directly from its own handler,
#          which then re-raises — going through `EXIT` there would mean handling
#          the signal by RETURNING, which is what made the helper resume the work
#          it was killed during. And a SUCCESSFUL run reaches it not at all: it
#          resets `EXIT` and leaves the directory for the caller, which is the
#          point of the call. "The EXIT trap cleans up on every path" invites both
#          halves of the mistake — removing the direct signal cleanup, and cleaning
#          up a successful result.
#
#          THE BODY HAS TWO SHAPES, chosen by `RB_PHASE` — by whether a leaf can
#          exist yet. BEFORE either write, which is the two ancestry walks and the
#          unresolvable-path refusal, it is `rmdir` ALONE: there is no leaf to
#          remove, and removing one by NAME would resolve a path the walk has just
#          decided not to trust, which is a symlink an attacker can substitute
#          while it runs. AFTER the writes it removes the leaf and then the
#          directory. The refusals themselves clean up nothing — they say why and
#          stop — so the removal happens at most once, whichever way the run ends.
#
#      THE ANCESTRY IS ON THE SECOND LIST, and it moved there with the `mkdir`.
#      The walks used to run first, so an unsafe component was refused before
#      anything existed; the reservation ordering put the create in front of them,
#      so that refusal now has a directory of its own to remove. A maintainer
#      reading the old classification would expect the opposite cleanup semantics
#      for a path that runs on every unsafe parent.
#
#      THE FAILED-`mkdir` DIAGNOSTIC PATH IS SEPARATE AND STILL PRE-CREATION: a
#      `mkdir` that fails runs the walks itself, purely to name the cause, and
#      nothing was created there either.
#
#      A caller cannot tell the two apart from the status, and does not need to:
#      the rule it follows is that it removes only what a status 0 gave it.
#
# NOTHING IS EVER WRITTEN TO STDOUT. The value goes to the file and the reasons go
# to stderr, so a caller reads one and never sees the other — which is what lets
# the value be read with `$(<"$path")` whatever the shell happens to be tracing.
#
# WHY THIS EXISTS
#
# `SKILL.md`'s setup block runs in the operator's own shell, which nothing
# controls, and it needed two things that shell cannot be trusted to give it: the
# origin URL, read with `git`, and proof that the pin it exported reaches a child,
# taken with `bash -c`. Both are NAMES. A function called `git` that answers only
# `remote get-url origin` forges the identity every stage is then addressed by; a
# function called `bash` runs in a shell copy that inherits non-exported
# variables, so it agrees the pin arrived while the real helpers — which exec
# through `#!/usr/bin/env bash` and resolve on `PATH` — inherit nothing.
#
# Neither is reachable here, and the reason is the whole design: the caller starts
# this file with `/usr/bin/env bash -p` — a PATH rather than a name, so no function
# can stand in front of it, and PRIVILEGED, so `BASH_ENV` and `ENV` are never
# sourced, shell functions are never imported from the environment, and
# `SHELLOPTS` is ignored. There is no hook to escape and nothing inherited to
# clear. See issues #84 and #83.
#
# `pin` IS NOT A CONVENIENCE MODE. It exists because "a child sees the pin" is the
# property the export has to have, and asking it from inside the driving shell
# asks a different question — an `export` that assigns without setting the export
# attribute leaves that shell holding the right value and every helper holding
# none. This process is a real child, reached without a name, so its answer is the
# one that matters.
#
# ── THE STARTUP HOOK IS NOT ESCAPED; IT IS NEVER RUN ───────────────────────
#
# `bash -p` does three things this file used to spend fifty lines failing to do
# from inside an ordinary shell — measured, all three at once:
#
#   · `BASH_ENV` and `ENV` are not sourced, so a startup hook never executes;
#   · shell functions are NOT imported from the environment, so `BASH_FUNC_…`
#     entries arrive and are ignored;
#   · `SHELLOPTS` is ignored, so an exported `xtrace` never turns on.
#
# WHAT THAT REPLACED, and why every one of them was a defect waiting to be found:
# a re-exec whose guard the hook could set for itself; a function sweep made of
# `unset`, `builtin`, `compgen` and `read`, each of which the hook could shadow or
# mark `readonly -f` so the clearing failed and the loop then CALLED it; a `:`
# probe that ran before any of it. Each was a name used to escape names, and each
# round of review found the next one. `-p` removes the question instead of
# answering it again.
#
# THE GUARD IS `$-`, WHICH IS SHELL STATE. A hook can set any variable, replace
# the positional parameters with `set --`, and define any function — it cannot
# make `$-` claim a `p` that is not there. Both were the previous two guards, and
# both were forged.
#
# `[[` and `!=` are reserved-word syntax, so the guard itself cannot be
# intercepted.
# STRICT MODE IS SET HERE, AFTER THE GUARD, AND THAT POSITION IS FORCED. `bash -p`
# ignores an inherited `SHELLOPTS`, which is most of why it is used — so a strict
# calling shell cannot supply these. `CLAUDE.md` classifies this file in the `set -uo pipefail`
# row; an earlier draft deleted the line along with the block it lived in and the
# script ran with none of it.
#
# `-e` IS EXCLUDED, as in every other helper here: the probes below report their
# answers as exit statuses. See CLAUDE.md § Bash conventions.
#
# THERE IS NO HOP, AND THE FILE IS NOT EXECUTABLE. Both were removed together, and
# for the same reason: neither could work. The hop re-execed into `bash -p` for a
# caller that had forgotten it — but by then the caller's `BASH_ENV` hook had
# already run in this process, and a hook that writes a forged value to `$2` and
# exits has finished the job before any line of this file executes. Advertising a
# recovery that cannot recover is worse than refusing, because a caller may rely
# on it. Removing the executable bit removes the invocation that reaches that
# state at all: `./pr-origin.sh …` and `#!/usr/bin/env bash` are gone, and the
# documented `/usr/bin/env bash -p pr-origin.sh …` is unaffected — `bash` reads
# the file, it does not exec it.
#
# WHAT IS LEFT IS A REFUSAL, and it is the guard rather than a bound: `$-` is
# shell state a hook cannot write, so an unprivileged shell that reaches here
# stops, with nothing read and nothing captured.
if [[ $- != *p* ]]; then
    echo "ABORT: this shell is not privileged; invoke as /usr/bin/env bash -p pr-origin.sh <mode> <path>" >&2
    exit 1
fi
set -uo pipefail

# ── THE OUTPUT PATH IS REQUIRED, AND IS THE SECOND ARGUMENT ────────────────
#
# Diagnostics go to stderr; the VALUE goes only to this file. Keeping them on
# different streams is what lets the caller read the value with `$(<…)` and never
# see anything else, whatever the shell is tracing.
MODE="${1-}"
case "$MODE" in
    read|pin) ;;
    "") echo "ABORT: a mode is required: 'read' (origin's URL) or 'pin' (REVIEW_BUS_REMOTE as a child sees it)" >&2; exit 1 ;;
    *)  echo "ABORT: '$MODE' is not a mode; expected 'read' or 'pin'" >&2; exit 1 ;;
esac
# THE ARGUMENT IS A DIRECTORY THIS SCRIPT CREATES, not a file the caller made a
# place for. It was a file path, and the caller had to build a private directory
# around it first — a two-candidate loop, three names of its own, three
# assignability probes with cross-variable alias checks, an exclusive `mkdir`, and
# two cleanup arms, all in the OPERATOR's shell where every one of those names can
# be readonly, value-transforming or a nameref aimed at another. That is the whole
# subject of #146, #148, #150, #151 and half of #155.
#
# NONE OF IT IS NEEDED HERE. This process is privileged: it imports no functions,
# sources no `BASH_ENV`, and `RB_DIR` below is its own. Creating the directory
# where the exclusion can actually be relied on deletes the thing those guards
# were guarding rather than adding another. #157.
RB_DIR="${2-}"
[[ -n $RB_DIR ]] \
    || { echo "ABORT: pr-origin.sh writes its value into a directory it creates; invoke it as /usr/bin/env bash -p pr-origin.sh $MODE <dir>" >&2; exit 1; }
# THE FILE IS THIS SCRIPT'S TO NAME. The caller reads `<dir>/origin` or
# `<dir>/pin`, and naming it here rather than taking it means there is no path
# the caller can be talked into passing.
case "$MODE" in
    read) OUT="$RB_DIR/origin" ;;
    pin)  OUT="$RB_DIR/pin" ;;
esac
# CREATED, NOT TRUNCATED, AND THE DIFFERENCE IS THE WHOLE POINT. `: > "$OUT"`
# opens with O_TRUNC and FOLLOWS SYMLINKS: an account that can replace the
# directory this path names can put a symlink there pointing at any file the
# operator owns, and this helper then truncates that file and writes a remote URL
# into it. The caller's `-O` check passes precisely BECAUSE the target belongs to
# the operator, so nothing downstream sees it. A world-writable target is worse
# still — the account edits it afterwards and the session pins what it likes.
#
# `set -C` MAKES `>` EXCLUSIVE. With noclobber, `> file` fails if the path exists
# at all, and that is O_EXCL: it refuses a regular file, and it refuses a symlink
# whether or not the target exists, because O_CREAT|O_EXCL fails on a symlink by
# definition. Nothing legitimate is lost — this script creates the directory
# exclusively a few lines above, so this path never pre-exists. `>|` is deliberately NOT used;
# that is the spelling that overrides noclobber, and it is what a later edit
# reaches for when this refuses something.
#
# `umask 077` GOES WITH IT, because O_EXCL says who may replace the object and the
# mode says who may write it once created. The caller's umask is whatever the
# operator's shell had.
#
# THE CREATE AND THE WRITE ARE ONE OPEN, and that is the whole reason there is no
# separate truncation here any more. Creating the file and then appending to it
# by NAME is two opens: `set -C` governs the first and not the second, so an
# account able to replace the directory could wait for the exclusive create to
# close, put a symlink at the same name, and have the `>>` follow it into a file
# the operator owns. The value is written by the single redirection that creates
# the object, below, so there is no interval and no second lookup.
#
# NOTHING IS LEFT BEHIND ON A REFUSAL EITHER, which is what the truncation was
# for: a run that refuses before its write creates no file at all, and a refusal
# AFTER the directory exists is given back by the EXIT cleanup, which removes the
# file and the directory before the process ends. The caller opens the result once to check and
# read it, and sees the open fail rather than an empty file.
umask 077
set -C
# AND THE DIRECTORY IT SITS IN MUST BE ONE NOBODY ELSE CAN WRITE. Everything
# above protects the object; this protects the NAME. An `-O` test in the caller —
# which is where this used to be — says the parent belongs to the operator and
# cannot say whether the operator has left it open to others — bash has no test for another account's write bit — so an
# owned mode-0777 `TMPDIR` passed it, and an account with write there can replace
# the whole transport directory between this script closing its file and the
# caller opening it. Both `-O` and `-f` then pass on the planted file, because the
# planted file belongs to the operator too.
#
# `find -prune -perm` IS THE TEST, and it is POSIX rather than `stat`, whose flags
# differ between GNU and BSD. It runs HERE and not in the caller because this
# process is privileged: `find` is a name, and in the driving shell a function by
# that name would answer instead. What remains is `PATH`, which is #91.
# EVERY DIRECTORY UP TO THE ROOT, not just the one holding the file. Checking the
# file's own directory is not enough and was the first shape of this: it is
# created mode 700 below, so it was always going to pass — while an account
# with write on the directory ABOVE it can rename it after the check and put a
# writable replacement at the same name. The question is not "can they write where
# the file goes" but "can they rename anything on the way to it", and that is
# every component.
#
# OWNERSHIP AS WELL AS MODE, because a mode is only what the owner has chosen so
# far. A sticky directory stops one account renaming ANOTHER'S entries and does
# nothing about its OWNER renaming ours — so an attacker-owned `1777` ancestor
# passed a permission-only test while its owner could replace the subtree
# underneath it. An attacker-owned `0755` one is no better: its owner can add the
# write bit after the probe. What has to be true is not "nobody may write it now"
# but "nobody hostile decides", and that is ownership.
#
# THIS USER OR ROOT, and nothing else. Root is trusted here because root can
# replace this script, the `git` it runs and the shell interpreting it, so
# refusing a root-owned `/` or `/home` would buy nothing and reject every machine.
#
# STICKY IS STILL THE MODE EXCEPTION, and is why `/tmp` works: root owns it, and
# `1777` lets anyone create entries while letting nobody rename another account's.
# `0777` without the bit is refused even when we own it.
#
# `$EUID` IS AN EXPANSION, so the identity this compares against costs no command;
# `-uid` is understood by both GNU and BSD `find`, like the rest of this test.
[[ $RB_DIR = /* ]] \
    || { echo "ABORT: the output directory must be absolute; '$RB_DIR' cannot be checked to the root" >&2; exit 1; }
# THE ANCESTORS ARE WHAT THE WALK IS ABOUT, and the directory itself does not
# exist yet — it is created below, exclusively, which is what makes IT safe. So
# the walk starts one level up.
_rb_dir="${RB_DIR%/*}"
[[ -n $_rb_dir ]] || _rb_dir=/
# THE WALK IS A FUNCTION BECAUSE IT RUNS TWICE. A path is checked as it is
# WRITTEN and as it RESOLVES, and neither covers the other.
_rb_walk() {   # _rb_walk <dir> ; 0 safe, 1 refused (reason on stderr)
    local p="$1" bad frc next
    while : ; do
        # THE PROBE'S STATUS IS TAKEN, and that is the fail-closed rule rather
        # than tidiness. If a component is renamed while its turn is being
        # probed, `find` fails and prints NOTHING — and empty output is what this
        # loop reads as safe, so the attacker's own interference would have been
        # the thing that let them through. An unreadable component is a refusal.
        # `! -type l` ON THE MODE CLAUSE ONLY. A symlink's own mode is `0777` on
        # every system that has them, so asking whether it is world-writable
        # refuses every path that goes through one — which is every macOS
        # temporary directory. What a link's mode means is nothing; what its
        # OWNER means is everything, because that account can repoint it, so the
        # ownership clause applies to links exactly as it does to directories.
        bad="$(find "$p" -prune \( \( ! -uid "$EUID" -a ! -uid 0 \) -o \( ! -type l -a \( -perm -g+w -o -perm -o+w \) -a ! -perm -1000 \) \) -print 2>/dev/null)"
        frc=$?
        if [[ $frc -ne 0 ]]; then
            echo "ABORT: could not examine '$p' on the way to the transport; refusing rather than assuming it is safe" >&2
            return 1
        fi
        if [[ -n $bad ]]; then
            echo "ABORT: '$p' is owned by another account, or writable by one and not sticky; the transport could be replaced between this write and the caller's read" >&2
            return 1
        fi
        # AND AN ACL IS A PERMISSION THE MODE BITS DO NOT SHOW. On macOS a
        # user-owned `0700` directory can still grant another local account
        # `add_file`/`delete_child` through an extended ACL, and Linux POSIX ACLs
        # do the same — `find -perm` sees none of it, so every check above passes
        # while that account can replace this directory.
        #
        # THE MARKER, NOT THE CONTENTS. `ls -l` appends `+` to the mode field of
        # anything carrying an ACL, on both platforms; reading WHAT the ACL grants
        # means `getfacl` on one and `ls -e` on the other, with different grammars
        # to parse and a new way to be wrong on each. Refusing any component that
        # carries one is coarse and fails closed, and the message says which
        # component so an operator can look.
        acl="$(ls -ld "$p" 2>/dev/null)"
        arc=$?
        if [[ $arc -ne 0 ]]; then
            echo "ABORT: could not read the permissions of '$p'; refusing rather than assuming it is safe" >&2
            return 1
        fi
        # `@` COUNTS AS WELL AS `+`, and on macOS it is the one that hides an ACL.
        # There, `ls -l` marks extended ATTRIBUTES with `@` and extended security
        # information with `+` — and a component carrying BOTH shows `@` alone, so
        # a directory with an ACL granting another account `delete_child` and any
        # xattr at all read as clean. `@` is ambiguous rather than harmless, and
        # this cannot tell the two apart without asking a platform-specific tool,
        # so it refuses on either mark.
        case "${acl%% *}" in
            *+|*@) echo "ABORT: '$p' is marked as carrying an access-control list or extended attributes, which the mode bits do not show; refusing rather than trusting a permission this cannot read" >&2
                return 1 ;;
        esac
        [[ $p = / ]] && break
        next="${p%/*}"
        [[ -n $next ]] || next=/
        [[ $next = "$p" ]] && break
        p="$next"
    done
    return 0
}
# THE HANDLERS ARE DEFINED BEFORE THE RESERVATION AND ARMED IMMEDIATELY AFTER IT.
# Defining them afterwards left an interval between the `mkdir` succeeding and the
# traps existing — a phase assignment and three function definitions wide — in
# which a signal took its DEFAULT action and terminated the helper with the
# directory already created. The caller performs no cleanup after a non-zero
# status, so that directory stayed for the life of the machine. Nothing in these
# definitions needs the reservation to exist; the arming is what does, and it is
# the first thing after it.
#
# THE CLEANUP EXISTS ONCE AND RUNS ONCE, and both halves of that are the fix. It
# used to live in two refusal functions AND an EXIT trap, so a refusal cleaned up
# and then `exit` fired the trap, which cleaned up again — and the second pass is
# the dangerous one: on a shared sticky parent an account watching the published
# path can recreate it as a symlink between the two, and the second `rm -f "$OUT"`
# follows the replacement into a file this run never created.
#
# SO THE REFUSALS ONLY SAY WHY AND STOP. The EXIT trap is what gives the
# reservation back, on every path out — a refusal, a signal, or a fall off the end
# — and there is nothing left to do twice.
#
# THE PHASE IS WHAT PICKS THE SHAPE, and it replaces the two refusal functions
# exactly: `rmdir` alone while no leaf can exist, and leaf-then-directory once a
# write has happened. `rmdir` refuses a symlink outright, which is what makes the
# pre-write shape safe on a name the ancestry walks have not approved yet; and
# `rmdir` NECESSARILY fails on a directory holding its leaf, which is why the
# post-write shape has to remove the leaf first.
#
# THE PHASE FLIPS WHERE THE NAME BECOMES TRUSTED, after both walks — which is also
# before either write, so the leaf-removing shape is never the one running on an
# unapproved path.
RB_PHASE=pre
# WHAT THIS RUN CREATED IS RECORDED IN TWO FACTS, because one is not enough and
# neither is signal-safe alone.
#
# `RB_OWNED` IS THE CERTAIN ONE and it is set after a successful `mkdir` — but not
# in time for every signal. Measured on bash 5: a `TERM` delivered while an
# external `mkdir` runs is handled once that command RETURNS and BEFORE the `&&`
# after it, so the handler sees the directory created and the flag still `no`.
#
# `RB_PREEXISTED` IS WHAT COVERS THAT WINDOW. It is a `[[ -e ]]` taken before the
# traps are armed — a reserved word, no command, nothing to be interrupted between
# — and it says whether anything stood at the name when this run began. If nothing
# did, then a directory there afterwards is one this run made, whatever the flag
# has had time to say.
#
# AND AN OWNED, EMPTY, PRE-EXISTING DIRECTORY IS THE CASE THAT MAKES BOTH
# NECESSARY. `-O` alone cannot see it: the operator own empty directory at that
# name passes every test a created one passes, and removing it contradicts the
# status-1 contract that a pre-existing argument survives untouched. The `keepme`
# file in the exclusion fixtures hid it, because `rmdir` refuses a non-empty
# directory and the removal failed for the wrong reason.
RB_OWNED=no
RB_PREEXISTED=no
[[ -e $RB_DIR ]] && RB_PREEXISTED=yes
rb_cleanup() {   # give back what this run created, for the phase it is in
    # THIS RUN'S, OR IT IS NOT OURS TO REMOVE. The traps are armed before the
    # `mkdir`, so this can run at a moment when the `mkdir` had already failed
    # because the name was taken. `-O` is kept as well as the two facts above: it
    # is what refuses a name another ACCOUNT holds, which neither flag can see.
    [[ $RB_OWNED = yes ]] \
        || { [[ $RB_PREEXISTED = no ]] && [[ -d $RB_DIR ]] && [[ -O $RB_DIR ]]; } \
        || return 0
    [[ -d $RB_DIR ]] && [[ -O $RB_DIR ]] || return 0
    [[ $RB_PHASE = post ]] && /usr/bin/env rm -f "$OUT"
    /usr/bin/env rmdir "$RB_DIR" 2>/dev/null
    return 0
}
rb_refuse() {   # rb_refuse [message] ; say why and stop; the EXIT trap cleans up
    [[ -n ${1-} ]] && echo "$1" >&2
    exit 1
}
# AND A SIGNAL BETWEEN THE RESERVATION AND EITHER END LEAVES NOTHING BEHIND. The
# caller performs no cleanup after a non-zero status, deliberately — it cannot know
# who created the path — so an interrupted run used to leak its `watch-pr.*`
# directory for the life of the machine. The obligation moved here with the
# creation, and a signal is a way out no refusal sees.
#
# THE HANDLERS RE-RAISE, WHICH IS NOT DECORATION. A trap on a signal REPLACES its
# default terminating action: handled and returned from, bash resumes the
# interrupted work — a `TERM` arriving while `git` runs left this process waiting
# for that child, and one arriving between a successful write and the disarm let it
# return status 0, reporting success for a run somebody killed. Each handler cleans
# up, removes its own trap, and kills this process with the same signal, so the
# caller sees the true cause and the true status.
#
# `kill` AND `$$` ARE THE SHELL'S OWN, and this process is privileged, so neither
# is a name anything can stand in for. `EXIT` is removed with the signal's trap in
# the same statement: without that the re-raise runs the EXIT handler as well,
# which is the second pass this whole block exists to prevent.
# AND THE SIGNALS ARE IGNORED WHILE IT RUNS, NOT RESET TO THEIR DEFAULTS. `trap -`
# restores the DEFAULT action, which for `HUP`, `INT` and `TERM` is to terminate:
# it stops the cleanup being re-entered and makes it INTERRUPTIBLE instead, so a
# second signal during `rb_on_signal`, or one during the EXIT handler on an
# ordinary refusal, kills the shell between the `rm` and the `rmdir` — and the
# caller removes nothing after a non-zero status. `trap ''` ignores them, which
# stops both. The original signal is restored to its default immediately before
# the re-raise, and only that one.
#
# AND EVERY TRAP IS DISARMED BEFORE THE CLEANUP RUNS, NOT AFTER IT. Disarming
# afterwards leaves the cleanup RE-ENTRANT: a signal arriving while it runs — or a
# second signal arriving while the first handler is between its two statements —
# invokes it again, and the second pass is the dangerous one for the reason the
# refusals gave up their own cleanup. After the first pass has freed the candidate,
# an account watching that path on a shared parent can recreate it as a symlink
# before the second `rm -f "$OUT"` resolves it.
#
# ALL FOUR IN ONE STATEMENT, in both exit paths, and BEFORE the first removal.
# Removing only the signal that fired leaves the other two armed; removing them
# after `rb_cleanup` leaves the whole window open.
rb_on_signal() {   # rb_on_signal <signal-name> ; give the reservation back and die of it
    trap '' EXIT HUP INT TERM
    rb_cleanup
    trap - "$1"
    kill -s "$1" "$$"
}

# ── THE NAME IS RESERVED BEFORE IT IS WALKED ───────────────────────────────
#
# WHAT THIS ORDERING DOES NOT CLOSE, STATED HERE BECAUSE IT CANNOT BE CLOSED FROM
# INSIDE. The candidate is an ARGV ENTRY, published by `ps` and `/proc` at exec —
# before this script's first line. Moving the `mkdir` ahead of the walks narrows
# the interval to process startup; it does not remove it. A local account watching
# `/proc` continuously can still win that interval and make an otherwise valid
# setup abort.
#
# THE ONLY PROTOCOL THAT REMOVES IT PUTS THE `mkdir` BACK IN THE CALLER, and that
# is the trade rather than an oversight. For the name never to be published, the
# directory in argv has to be one the caller ALREADY created private — nobody else
# can create anything inside a mode-700 directory — and then the caller is doing
# the `mkdir`, in the operator's own long-lived shell, on a name that shell may
# have made readonly, `declare -i`, `declare -l` or a nameref aimed at another
# transport variable. That is #146, #148, #150, #151 and half of #155: five issues
# and dozens of review rounds, and removing it is what #157 is.
#
# The exposure that remains is a DENIAL OF SERVICE by an account already on the
# machine, and it fails CLOSED: setup refuses, nothing is forged, and the
# directory is 700 so nothing is read. Trading that for the class above is not a
# trade worth making silently, so it is written down instead — the same shape as
# the `PATH` limit at the foot of this file and #91. #160.
#
# THE `mkdir` COMES FIRST, and that ordering is a fix rather than an accident. It
# used to run AFTER both ancestry walks, and the candidate is visible to every
# account on the machine the moment this process starts: it is an argv entry, which
# `ps` and `/proc` publish. On a shared sticky parent such as `/tmp`, another local
# account could read it, create the name while the walks ran, and this `mkdir`
# would then refuse — repeatably, for as long as they watched. The random suffix
# stops a name being GUESSED and does nothing about one being READ. The caller's
# `mkdir` had reserved the name before the helper was invoked at all, so #157 lost
# that property by moving the create without moving it far enough.
#
# `mkdir` FAILS IF THE NAME EXISTS, and that is the exclusion the caller used to
# perform. It refuses a directory, a file and a symlink alike — `mkdir` does not
# follow the last component — so an account that gets there first gets a refusal
# rather than a path this script then writes through.
#
# `-m 700` IS APPLIED BY `mkdir` ITSELF, so there is no interval between the
# directory existing and being private. The `umask 077` above governs the file;
# this governs the name it sits under, and together they say who may replace the
# object and who may write it.
#
# WALKING AFTERWARDS IS NOT WEAKER. The walk asks who may rename the components on
# the way; creating a private child first does not change any of their answers, and
# NOTHING IS WRITTEN into the child until the walk has passed. A refusal from the
# walk removes the directory again — the EXIT cleanup does it, in its pre-write
# phase — so the reservation is given back rather than left behind.
#
# HERE RATHER THAN IN THE CALLER, which is the whole of #157. In the driving shell
# this was `mkdir -m 700 "$RB_TRY"` with `RB_TRY` a name that shell may have made
# readonly, `declare -i`, `declare -l` or a nameref aimed at another transport
# variable — each of which took a probe, and each probe a containment arm once
# `exit` turned out to be replaceable. Here the name is this process's own.
# AND A FAILED `mkdir` ASKS THE WALK WHY, BEFORE REFUSING. Reserving first costs
# the DIAGNOSTIC otherwise: `mkdir` reports `Permission denied` where the real
# answer is that a component belongs to another account, and an operator reading
# that has nothing to act on. The walk runs on the failure path to produce the
# precise reason, and its refusal is the one that comes out; the generic message
# is what remains when the ancestry is fine and the name was simply taken. Nothing
# was created on this path, so nothing is removed on it.
# THE TRAPS ARE ARMED BEFORE THE `mkdir`, NOT AFTER IT. Armed afterwards they
# protected only what follows the command RETURNING: a signal arriving while the
# external `mkdir` ran terminated this shell while the child went on to create
# the directory, and the caller — which removes nothing after a non-zero status —
# was left with it. The window is small and it is not zero, and it is the one
# window the ordering fixture could not see.
#
# WHICH MAKES `rb_cleanup`'S THREE-PART DECISION LOAD-BEARING RATHER THAN
# BELT-AND-BRACES. Arming first means the cleanup can now run at a moment when this
# run has NOT created the directory — when the `mkdir` had already failed because
# the name was taken. What tells those apart is the combination stated above it:
# `RB_OWNED` where the `mkdir` has already reported success, `RB_PREEXISTED` for
# the window where it has not reported anything yet, and `-O` for a name another
# ACCOUNT holds. No one of the three is sufficient — an EMPTY pre-existing
# directory owned by the operator passes `-O` exactly as a created one does, and
# `RB_OWNED` is not yet set when a signal is handled straight out of the `mkdir`.
# `rmdir` refuses a symlink and a non-empty directory besides.
trap 'trap "" EXIT HUP INT TERM; rb_cleanup' EXIT
trap 'rb_on_signal HUP' HUP
trap 'rb_on_signal INT' INT
trap 'rb_on_signal TERM' TERM

/usr/bin/env mkdir -m 700 "$RB_DIR" 2>/dev/null && RB_OWNED=yes \
    || { _rb_walk "$_rb_dir" || exit 1
         # AND THE RESOLVED PATH TOO, because a symlinked ancestor is exactly the
         # case the lexical walk cannot answer: the link's own owner is fine and
         # what it points at is not, so `mkdir` fails and only this pass can say
         # why. Both walks run here for the same reason they both run below.
         _rb_fail_real="$(cd -P "$_rb_dir" 2>/dev/null && pwd -P)"
         # A PATH THAT WILL NOT RESOLVE IS ITS OWN REFUSAL, and it is the answer for
         # a link into a tree this account cannot enter: the lexical walk sees only
         # the link, which we own, and `cd -P` is what fails. Reporting the generic
         # message there would hide the one fact the operator needs.
         [[ -n $_rb_fail_real ]] \
             || { echo "ABORT: could not resolve '$_rb_dir' to a physical path; refusing rather than checking a name that may not be where it leads" >&2; exit 1; }
         [[ $_rb_fail_real != "$_rb_dir" ]] \
             && { _rb_walk "$_rb_fail_real" || exit 1; }
         echo "ABORT: could not create '$RB_DIR' exclusively; it already exists, or its parent refuses" >&2
         exit 1; }
# AND WHAT THIS SCRIPT CREATES, THIS SCRIPT REMOVES. Every refusal from here on
# happens AFTER the directory exists — the two ancestry walks, the git read, an
# empty origin, a newline in it, a write that opens and then fails — and each used
# to leave nothing behind because the CALLER owned the directory and cleaned up in
# its own arms. It does not own it any more, so the obligation moved with the
# creation.
#
# `rmdir`, NOT `rm -rf`. This removes only what it made and only while empty: a
# path this script created cannot legitimately hold anything else, and a recursive
# delete on a variable is the shape that turns a refusal into data loss when the
# variable is not what anyone thought.
#
# AN EMPTY MESSAGE PRINTS NOTHING, for the callers whose own refusal has already
# said why — the ancestry walks name the component and the reason, and a second
# line after them would say less.
# THE PATH AS WRITTEN, which is where the SYMLINKS live. `find` without `-L`
# examines the link rather than what it points at, so this pass asks who owns each
# link on the way — an account that owns one can repoint it.
_rb_walk "$_rb_dir" || rb_refuse
# …AND THE PATH AS IT RESOLVES, which is where the FILE lives. A lexical walk
# never sees the real ancestry: `TMPDIR=/home/me/t` pointing at `/srv/other/mine`
# checks `/home/me` and never `/srv/other`, and the account that owns that one can
# replace `mine` after every check has passed. Symlinks cannot simply be refused
# instead — macOS reaches its own temporary directories through them, so refusing
# would refuse that platform.
#
# `cd -P` AND `pwd -P` ARE BUILTINS, and this process is privileged, so no
# function can stand in front of either. In the driving shell they would be names.
_rb_real="$(cd -P "$_rb_dir" 2>/dev/null && pwd -P)"
[[ -n $_rb_real ]] \
    || rb_refuse "ABORT: could not resolve '$_rb_dir' to a physical path; refusing rather than checking a name that may not be where it leads"
[[ $_rb_real = "$_rb_dir" ]] || _rb_walk "$_rb_real" || rb_refuse
# THE NAME IS TRUSTED FROM HERE, and that is what the phase says. Every write is
# below this line and every walk above it, so a signal arriving from now on gets
# the shape that removes the leaf as well — and never gets it while the ancestry
# is still unproven.
RB_PHASE=post


if [[ $MODE = pin ]]; then
    # NO VALIDATION HERE. The caller is asking what a child inherits, and "nothing"
    # is a real answer it needs — the one that says the export did not take. An
    # empty line and status 0 says exactly that; refusing would make the two
    # failures indistinguishable from this side.
    # THE WRITE'S STATUS IS TAKEN. An output target can open and then reject data —
    # `/dev/full`, or a quota reached after the truncation above — and in `pin` mode
    # a failed write leaves exactly what a legitimately unset pin leaves: an empty
    # file and success. The caller could not tell them apart, so this one says.
    printf '%s\n' "${REVIEW_BUS_REMOTE-}" > "$OUT" \
        || rb_refuse "ABORT: could not create '$OUT' exclusively and write the pin; it already exists, or is a symlink"
    # ONLY `EXIT` IS RESET, AND THAT IS THE WHOLE POINT OF RESETTING IT HERE. The
    # EXIT handler would remove the leaf this run just wrote, so it has to go. The
    # SIGNAL handlers stay armed through the final command: resetting them too left
    # a window in which a `TERM` terminated the helper by default, with no cleanup
    # — and the caller, seeing a non-zero status, removes nothing, so a completed
    # directory leaked.
    trap - EXIT
    exit 0
fi

# THE STATUS IS TAKEN, NOT JUST THE OUTPUT. `git remote get-url origin` can print
# a plausible URL and then exit non-zero — a partially configured remote, a
# permissions error part-way through a read — and command substitution keeps
# whatever it wrote. Every `gh` call in the session is addressed by this value, so
# accepting output from a failed read sends one project's review traffic
# somewhere else.
# A SENTINEL, BECAUSE COMMAND SUBSTITUTION STRIPS TRAILING NEWLINES and cannot
# tell `git`'s output terminator from data. `git remote add origin $'…\n'` is
# accepted — measured — so a configured remote can genuinely END in a newline, and
# without the sentinel it arrives here identical to the well-formed URL. The
# session would then post against a slug the operator never configured, which is
# the wrong-repository failure this file exists to prevent, reached from the other
# direction. The `x` is appended inside the substitution and removed after, so
# every byte `git` wrote survives to be checked.
# `env -i` BECAUSE `GIT_DIR` IS NOT A NAME AND `bash -p` DOES NOT TOUCH IT.
# Privileged mode refuses startup files and inherited functions; it keeps ordinary
# environment variables, and `GIT_DIR` pointing at a second checkout makes this
# real `git` read that repository's origin while running in this one. Every later
# signoff, revocation and review request then goes to the wrong project — which is
# the failure this whole file exists to prevent, arriving by a route that has
# nothing to do with shadowing.
#
# `-i` RATHER THAN A LIST OF `-u`s. `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`,
# `GIT_CONFIG`, `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`,
# `GIT_CEILING_DIRECTORIES`, `GIT_DISCOVERY_ACROSS_FILESYSTEM` … a list is wrong
# by omission the first time git adds one, and this repository has a rule about
# that. An empty environment needs no list.
#
# WHAT IS CARRIED BACK IN is `PATH`, because that is how `git` is found at all
# (#91); `HOME` and `XDG_CONFIG_HOME`; and every `GIT_CONFIG_*` variable, by
# prefix rather than by name — see the block just above the list. They say WHICH
# CONFIG the operator's git reads, and a different one loses the rewrites the
# session honours.
# `HOME` SURVIVES `-i`, AND THAT IS NOT A WEAKENING. `git remote get-url` is
# documented to expand `url.<base>.insteadOf`, and those rules live in the user's
# GLOBAL config — so an emptied environment returned the UNEXPANDED alias, and a
# checkout whose origin is `work:acme/widget.git` came back with host `work`.
# `rb_identity` then refused a valid checkout, or addressed the session somewhere
# that is not where it pushes. Measured both ways.
#
# WHAT IS EXCLUDED IS EVERYTHING THAT SCOPES THE REPOSITORY: `GIT_DIR`,
# `GIT_WORK_TREE`, `GIT_COMMON_DIR`, `GIT_OBJECT_DIRECTORY` and the rest go with
# `-i`, and the list needs no maintaining because the environment is emptied
# rather than filtered. The `GIT_CONFIG_*` variables are CARRIED, not excluded —
# see the block above the list — because they say which config the operator's git
# reads, and reading a different one loses the rewrites the session honours.
# `XDG_CONFIG_HOME` is carried for the same reason: git reads
# `$XDG_CONFIG_HOME/git/config` as global config too.
#
# A CARRIED CONFIG CAN CHOOSE THE REPOSITORY, and that is accepted rather than
# guarded — see the block above the resolution below, and the limits at the
# bottom. It is the same capability as a forged `HOME`, through a weaker channel.
#
# A FORGED `HOME` CAN STILL REWRITE URLS, and that is the operator's own shell
# lying about the operator's own home — the boundary this file already records at
# the bottom, not a new one.
#
# THE CONFIG VARIABLES ARE CARRIED BY PREFIX, NOT BY NAME. `${!GIT_CONFIG_@}`
# lists every set variable whose name starts with `GIT_CONFIG_`, and each is
# passed through with the value it has. That is `GIT_CONFIG_GLOBAL`,
# `GIT_CONFIG_SYSTEM`, `GIT_CONFIG_NOSYSTEM`, the runtime family
# `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>`,
# `GIT_CONFIG_PARAMETERS`, and whatever git adds next.
#
# A LIST OF THREE WAS WRONG BY OMISSION, which is the failure this repository has
# already paid for twice. It named the two file locations and the opt-out, and
# missed both runtime channels — so an operator whose rewrite arrives as
# `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.…insteadOf` had it expanded by every
# ordinary command and dropped here, and the session was pinned to the unexpanded
# alias. Both channels measured on git 2.55. An indexed family cannot be
# enumerated at all, so the shape changes instead: no list, no omission.
#
# SETNESS COMES FREE WITH IT. A name only appears in `${!GIT_CONFIG_@}` if it is
# set, so `GIT_CONFIG_GLOBAL=` is carried as empty rather than dropped — and that
# matters, because git defines these by whether they are SET and reads an empty
# path as no such file. An operator exporting one empty has switched that source
# off; a `[[ -n … ]]` test silently restored git's default file, and a rule in it
# reached this helper alone.
#
# NOTHING THAT SCOPES THE REPOSITORY SHARES THE PREFIX. `GIT_DIR`,
# `GIT_WORK_TREE`, `GIT_COMMON_DIR`, `GIT_OBJECT_DIRECTORY`,
# `GIT_CEILING_DIRECTORIES` and the rest are dropped by `-i` and cannot arrive
# through this loop, which is the whole point of matching on `GIT_CONFIG_` rather
# than on `GIT_`.
_rb_env=( PATH="$PATH" HOME="${HOME-}" )
[[ -n ${XDG_CONFIG_HOME+x} ]] && _rb_env+=( XDG_CONFIG_HOME="$XDG_CONFIG_HOME" )
for _rb_n in ${!GIT_CONFIG_@}; do
    _rb_env+=( "$_rb_n=${!_rb_n}" )
done
# GIT RESOLVES THE URL, AND NOTHING HERE SECOND-GUESSES IT. Every attempt to take
# a piece of that resolution into this file has produced a divergence from git's
# own semantics, and the count is the evidence: a scalar read returning the LAST
# of several URLs where `remote get-url` returns the first; a `--local` query that
# cannot see the worktree scope; a hand-applied `insteadOf` re-deriving
# longest-match; `ls-remote --get-url` resolving its operand as a remote NAME; and
# then, from the two-call design that replayed extracted rewrite rules as `-c`
# options, cross-scope ordering, `~`-includes lost with `HOME`, and a subsection
# containing a space. Each fix was correct about the case it named and produced
# the next one, because the thing being rebuilt is git's config machinery.
#
# So there is ONE call and it is the ordinary one. `git remote get-url origin`,
# under the operator's own config, is what `fetch` and `push` consult; agreeing
# with it is the property this file needs, and re-deriving it is how that property
# was repeatedly lost.
#
# THE LOCKOUT THAT USED TO BE HERE DEFENDED NOTHING. It shut the operator's global
# and system config out of the resolution so a carried file could not contribute
# `[remote "origin"] url = …` — which does win `get-url`, measured. But the same
# file may contain `url.<base>.insteadOf`, which this helper must honour or it
# pins the session to an unexpanded alias, and a rewrite rule redirects the origin
# COMPLETELY where an injected URL only adds a second one. The channel left open
# is strictly the stronger of the two, so closing the weaker one bought no
# guarantee and cost agreement with git in every case above. That boundary is
# recorded at the bottom of this file, where it already was.
_rb_origin="$(/usr/bin/env -i "${_rb_env[@]}" \
    git remote get-url origin 2>/dev/null; _rb_s=$?; printf x; exit "$_rb_s")" || {
    rb_refuse "ABORT: could not read origin in $(command pwd 2>/dev/null)"; }
_rb_origin="${_rb_origin%x}"
# `git` TERMINATES ITS OUTPUT WITH ONE NEWLINE, and that one is not data. Anything
# after it is — and the newline in this pattern is written literally for the same
# reason as the one below: `$(printf '\n')` strips its own newline, so the pattern
# would be empty, nothing would be removed, and every valid origin would be refused
# for carrying `git`'s own terminator. That is the second time this exact
# substitution has been wrong in this file.
_rb_origin="${_rb_origin%'
'}"
[[ -n $_rb_origin ]] || rb_refuse "ABORT: origin is empty; there is no repository to pin this session to"
# ONE LINE, AND NOTHING THAT CAN BECOME TWO. A remote containing a newline would
# otherwise arrive at the caller as two values, and the second is whatever the
# first line's tail happened to be. `identitylib.sh` parses the URL itself; what
# has to hold HERE is that exactly one value leaves this process.
# A LITERAL NEWLINE IN THE PATTERN, not one produced by a command. The first
# attempt used `*"$(printf '\n')"*`, and command substitution strips trailing
# newlines — so the needle was the EMPTY string, the pattern matched every input,
# and a perfectly good origin was refused. Caught on the first run; it would have
# refused every session.
if [[ $_rb_origin != "${_rb_origin%%'
'*}" ]]; then
    rb_refuse "ABORT: origin contains a newline; it cannot be a single value"
fi
printf '%s\n' "$_rb_origin" > "$OUT" \
    || rb_refuse "ABORT: could not create '$OUT' exclusively and write the origin; it already exists, or is a symlink"
# ONLY `EXIT`, for the reason the pin path above gives: the signal handlers have to
# stay armed through the final command.
trap - EXIT
exit 0

# ── WHAT THIS DOES NOT CLOSE ───────────────────────────────────────────────
#
# Written here rather than left for a reader to rediscover. What remains needs a
# shell that is already executing arbitrary code as the operator — and such a
# shell can edit this file, or the commit, instead of out-arguing it.
#
# THE CALLER'S HALF, WHICH THIS FILE CANNOT SUPPLY. `bash -p` has to be in force
# before the first line, so a caller that omits it gets a refusal rather than a
# recovery: a hook that writes the value file and exits has already answered by
# then. That is why the invocation is asserted by `test-pr-skill-contract.sh`
# rather than assumed, and why there is no fallback hop here to be shadowed.
#
# THE OPERATOR'S OWN GIT CONFIG, WHICH THIS HELPER REPRODUCES RATHER THAN JUDGES.
# `HOME`, `XDG_CONFIG_HOME`, `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` are
# carried, so a config file the operator's git reads is a config file this helper
# reads. Such a file can redirect the origin — with `url.<base>.insteadOf`
# completely, with `[remote "origin"] url = …` by putting a second URL in front of
# the repository's own. Locking the second one out was tried for three rounds and
# is why this note exists: it left the FIRST channel open, which is the stronger
# of the two, so it closed nothing while making this helper disagree with
# `git remote get-url` over `~`-includes, cross-scope rule order and subsections
# containing a space. Agreement with the operator's git is the property the pin
# needs. Setting one of those variables means owning the shell that starts this
# session, which is the boundary the paragraph above already draws.
#
# A POISONED `PATH`, WHICH IS NOT THIS FILE'S TO ANSWER. A directory prepended to
# `PATH` — readonly, so the hook's own shell cannot undo it — supplies a forged
# `git` here and a forged `gh` in every other helper. It is not specific to the
# origin read, and a defence belonging to one helper would be the narrow guard
# this repository keeps having to delete.
#
# SETTLED IN #91, AND NOT AS A FIX: `command -p` searches a default path holding
# the STANDARD utilities, and neither `git` nor `gh` is one; a fixed list has to
# know where the operator's binaries live, which is what `PATH` answers; and a
# prepended directory is what a version manager does on every machine, so "wrong"
# is unknowable. The loop trusts the `PATH` of the shell it was started from, as
# it trusts that shell not to have run a hook first — nothing inside a process can
# tell the honest version of something it inherited. `CLAUDE.md` § the helpers are
# started privileged carries the statement, and both reviewer files carry it
# verbatim, so nobody builds the narrow version here.
