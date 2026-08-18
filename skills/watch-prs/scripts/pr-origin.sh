#!/usr/bin/env bash
# The session's repository, read where the driving shell's names cannot reach.
#
#   /usr/bin/env bash -p pr-origin.sh read "$RB_ORIGIN_OUT" || abort
#   RB_REMOTE="$(<"$RB_ORIGIN_OUT")"
#
# THE VALUE GOES TO A FILE THE CALLER NAMES, and that is the third mechanism this
# script has used. The first two put it on a descriptor — stdout, then fd 9 — and
# both spent rounds of review on the same problem from different angles: whichever
# descriptor carries the value, a caller tracing to it has its trace written into
# the value, and the redirections that would move one out of the way move the
# other into place. Moving the trace target instead closed fd 2 when it was
# restored, so the second call of a session returned nothing at all.
#
# A path has none of those properties. The caller's tracing goes wherever it
# already went, this script writes where it was told, and there is no descriptor
# for the two to collide over.
#
# `/usr/bin/env`, A PATH, BECAUSE `bash` IS A NAME. `bash -p …` calls a function
# called `bash` if the caller has one, and such a function writes a forged URL to
# the file it was handed and returns, without this script running at all. A path
# cannot be shadowed.
#
# `bash -p` IS THE CALLER'S PART AND CANNOT BE DELEGATED. Privileged mode is what
# stops `BASH_ENV` being sourced, so it has to be in force before this file's first
# line. A hook needs to shadow nothing to use the gap: one that writes the value
# file and exits is a complete attack, finished before this script's first line.
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
#   0  the value is in the file named by the second argument
#   1  refused — the reason is on STDERR, and the file is NOT created. The value
#      is written by the single redirection that creates it, so a refusal before
#      that point leaves the path ABSENT rather than empty; a caller that opens it
#      sees the open fail, which is what `SKILL.md` branches on.
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
OUT="${2-}"
[[ -n $OUT ]] \
    || { echo "ABORT: pr-origin.sh writes its value to a file; invoke it as /usr/bin/env bash -p pr-origin.sh $MODE <path>" >&2; exit 1; }
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
# definition. Nothing legitimate is lost — the caller allocates a fresh private
# directory per run, so this path never pre-exists. `>|` is deliberately NOT used;
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
# for: a run that refuses before its write creates no file at all, and the
# caller — which allocates a fresh directory per run and opens the result once
# to check and read it — sees the open fail rather than an empty file.
umask 077
set -C
# AND THE DIRECTORY IT SITS IN MUST BE ONE NOBODY ELSE CAN WRITE. Everything
# above protects the object; this protects the NAME. The caller's `-O` test says
# the parent belongs to the operator and cannot say whether the operator has left
# it open to others — bash has no test for another account's write bit — so an
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
# file's own directory is not enough and was the first shape of this: the caller
# creates that one mode 700, so it was always going to pass — while an account
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
[[ $OUT = /* ]] \
    || { echo "ABORT: the output path must be absolute; '$OUT' cannot be checked to the root" >&2; exit 1; }
_rb_dir="${OUT%/*}"
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
# THE PATH AS WRITTEN, which is where the SYMLINKS live. `find` without `-L`
# examines the link rather than what it points at, so this pass asks who owns each
# link on the way — an account that owns one can repoint it.
_rb_walk "$_rb_dir" || exit 1
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
    || { echo "ABORT: could not resolve '$_rb_dir' to a physical path; refusing rather than checking a name that may not be where it leads" >&2; exit 1; }
[[ $_rb_real = "$_rb_dir" ]] || _rb_walk "$_rb_real" || exit 1

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
        || { echo "ABORT: could not create '$OUT' exclusively and write the pin; it already exists, or is a symlink" >&2; exit 1; }
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
# `GIT_CONFIG`, `GIT_CONFIG_GLOBAL`, `GIT_OBJECT_DIRECTORY`,
# `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_CEILING_DIRECTORIES`,
# `GIT_DISCOVERY_ACROSS_FILESYSTEM` … a list is wrong by omission the first time
# git adds one, and this repository has a rule about that. An empty environment
# needs no list. `PATH` is carried because that is how `git` is found at all —
# which is #91 — and nothing else is, so the lookup sees the working directory and
# the repository it stands in.
# `HOME` SURVIVES `-i`, AND THAT IS NOT A WEAKENING. `git remote get-url` is
# documented to expand `url.<base>.insteadOf`, and those rules live in the user's
# GLOBAL config — so an emptied environment returned the UNEXPANDED alias, and a
# checkout whose origin is `work:acme/widget.git` came back with host `work`.
# `rb_identity` then refused a valid checkout, or addressed the session somewhere
# that is not where it pushes. Measured both ways.
#
# WHAT IS EXCLUDED IS STILL EVERYTHING THAT REDIRECTS THE REPOSITORY: `GIT_DIR`,
# `GIT_WORK_TREE`, `GIT_CONFIG`, `GIT_CONFIG_GLOBAL` and the rest go with `-i`,
# and the list needs no maintaining because the environment is emptied rather
# than filtered. `XDG_CONFIG_HOME` is carried when set, because git reads
# `$XDG_CONFIG_HOME/git/config` as global config too and omitting it would lose
# the same rewrites for anyone who uses it.
#
# A FORGED `HOME` CAN STILL REWRITE URLS, and that is the operator's own shell
# lying about the operator's own home — the boundary this file already records at
# the bottom, not a new one.
_rb_env=( PATH="$PATH" HOME="${HOME-}" )
[[ -n ${XDG_CONFIG_HOME-} ]] && _rb_env+=( XDG_CONFIG_HOME="$XDG_CONFIG_HOME" )
# `GIT_CONFIG_NOSYSTEM` IS AN OPT-OUT, NOT A REDIRECTION, and dropping it turns
# one on. The operator sets it to make git ignore the system-wide config, and an
# emptied environment silently restored that file — so a `url.*.insteadOf` rule in
# it would rewrite the origin THIS helper reads while every ordinary git command
# in the session, still honouring the opt-out, used the unexpanded one. The pin
# and the session would disagree about the repository, which is the failure this
# file exists to prevent.
#
# THE TEST IS THAT IT WAS SET, not what it says: git treats any non-empty value as
# "skip the system config", so carrying the operator's value through is exactly
# reproducing their decision.
[[ -n ${GIT_CONFIG_NOSYSTEM-} ]] && _rb_env+=( GIT_CONFIG_NOSYSTEM="$GIT_CONFIG_NOSYSTEM" )
_rb_origin="$(/usr/bin/env -i "${_rb_env[@]}" git remote get-url origin 2>/dev/null; _rb_s=$?; printf x; exit "$_rb_s")" || {
    echo "ABORT: could not read origin in $(command pwd 2>/dev/null)" >&2; exit 1; }
_rb_origin="${_rb_origin%x}"
# `git` TERMINATES ITS OUTPUT WITH ONE NEWLINE, and that one is not data. Anything
# after it is — and the newline in this pattern is written literally for the same
# reason as the one below: `$(printf '\n')` strips its own newline, so the pattern
# would be empty, nothing would be removed, and every valid origin would be refused
# for carrying `git`'s own terminator. That is the second time this exact
# substitution has been wrong in this file.
_rb_origin="${_rb_origin%'
'}"
[[ -n $_rb_origin ]] || { echo "ABORT: origin is empty; there is no repository to pin this session to" >&2; exit 1; }
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
    echo "ABORT: origin contains a newline; it cannot be a single value" >&2; exit 1
fi
printf '%s\n' "$_rb_origin" > "$OUT" \
    || { echo "ABORT: could not create '$OUT' exclusively and write the origin; it already exists, or is a symlink" >&2; exit 1; }
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
# A POISONED `PATH`, WHICH IS NOT THIS FILE'S TO ANSWER. A directory prepended to
# `PATH` — readonly, so the hook's own shell cannot undo it — supplies a forged
# `git` here and a forged `gh` in every other helper. It is not specific to the
# origin read, and a defence belonging to one helper would be the narrow guard
# this repository keeps having to delete. Filed as #91, with the three candidate
# fixes and why each trades a hostile-shell exposure for routine breakage.
