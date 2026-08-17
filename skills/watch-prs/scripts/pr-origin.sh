#!/usr/bin/env bash
# The session's repository, read where the driving shell's names cannot reach.
#
#   pr-origin.sh read   # print origin's URL, from THIS directory
#   pr-origin.sh pin    # print REVIEW_BUS_REMOTE as a child process sees it
#
#   0  the value is on stdout
#   1  refused — the reason is on stdout, and no value was printed
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
# Neither is reachable here, and the reason is the whole design: this file is
# invoked as `"$RB_SCRIPTS"/pr-origin.sh`, a PATH rather than a name, so no
# function can stand in front of it; and it re-execs into a shell with the startup
# hooks removed and every inherited function cleared before it calls anything. See
# issues #84 and #83.
#
# `pin` IS NOT A CONVENIENCE MODE. It exists because "a child sees the pin" is the
# property the export has to have, and asking it from inside the driving shell
# asks a different question — an `export` that assigns without setting the export
# attribute leaves that shell holding the right value and every helper holding
# none. This process is a real child, reached without a name, so its answer is the
# one that matters.
#
# `set -uo pipefail`, NOT `-e`: the probes below report their answers as exit
# statuses. See CLAUDE.md § Bash conventions.
set -uo pipefail

# ── THE STARTUP HOOK RUNS BEFORE THIS FILE DOES ────────────────────────────
#
# A non-interactive bash sources `$BASH_ENV` before the script body, so anything
# it defines is already in place by the time the first line here runs. The re-exec
# steps out of that, and `ENV`, `SHELLOPTS` and `BASH_XTRACEFD` travel with it for
# the same reason — an exported `SHELLOPTS=xtrace` traces this process and writes
# to stdout when `BASH_XTRACEFD=1`, which is the stream the caller reads a value
# from.
#
# GUARDED BY A MARKER, NOT BY THE EVIDENCE. The hook can `unset BASH_ENV` on its
# way out, so a guard that tests for it skips the re-exec exactly when it is most
# needed.
#
# AND THE MARKER IS CLEARED, or every child of this process inherits it and stands
# in the hook it was meant to step out of.
#
# `[[`, NOT `[`: the hook runs first and can define a `[` function, which would
# intercept this guard and skip the re-exec that exists to escape it.
if [[ -z ${RB_ORIGIN_CLEAN-} ]]; then
    RB_ORIGIN_CLEAN=1 exec env -u BASH_ENV -u ENV -u SHELLOPTS -u BASH_XTRACEFD bash "$0" "$@"
fi
unset -v RB_ORIGIN_CLEAN 2>/dev/null || true

# ── AND EVERY INHERITED FUNCTION IS CLEARED BEFORE A NAME IS USED ──────────
#
# An exported function is inherited through the environment and survives the
# re-exec above, which only drops the hook variables. It shadows the name it is
# called by, builtin or external alike — and `command` and `builtin`, the prefixes
# used to reach past one, are themselves ordinary builtins and shadowable in
# exactly the same way. Clearing those first is what makes the rest mean anything.
#
# EVERY FUNCTION, NOT A LIST. `CLAUDE.md` records that a list of names is wrong by
# omission; this process defines none of its own, so clearing all of them costs
# nothing.
#
# THE NAMES ARE READ, NOT EXPANDED. `a*b` is rejected as a definition and imported
# from the environment without complaint, and unquoted it would glob against the
# working directory. A quoted here-string neither splits nor globs.
unset -f unset builtin command compgen declare read 2>/dev/null || true
while read -r _rb_f; do
    [ -n "$_rb_f" ] || continue
    builtin unset -f -- "$_rb_f" 2>/dev/null || true
done <<< "$(builtin compgen -A function 2>/dev/null)"
# AFTER the clearing, so `set` is the builtin. `SHELLOPTS` is readonly in a shell
# and cannot be unset from inside, but `set +x` turns tracing off regardless.
set +x

# THIS DOES NOT CLOSE THE CLASS, and saying so is the point. `unset` can itself be
# shadowed, and `set -o posix` — which would make special builtins outrank
# functions — is reached through `set`, which is shadowable too. What is left
# needs a parent already executing arbitrary code as the operator, and such a
# shell can edit this file. That is a limitation, written here rather than left
# for a reader to rediscover.

MODE="${1-}"
case "$MODE" in
    read|pin) ;;
    "") echo "ABORT: a mode is required: 'read' (print origin's URL) or 'pin' (print REVIEW_BUS_REMOTE as a child sees it)"; exit 1 ;;
    *)  echo "ABORT: '$MODE' is not a mode; expected 'read' or 'pin'"; exit 1 ;;
esac

if [[ $MODE = pin ]]; then
    # NO VALIDATION HERE. The caller is asking what a child inherits, and "nothing"
    # is a real answer it needs — the one that says the export did not take. An
    # empty line and status 0 says exactly that; refusing would make the two
    # failures indistinguishable from this side.
    printf '%s\n' "${REVIEW_BUS_REMOTE-}"
    exit 0
fi

# THE STATUS IS TAKEN, NOT JUST THE OUTPUT. `git remote get-url origin` can print
# a plausible URL and then exit non-zero — a partially configured remote, a
# permissions error part-way through a read — and command substitution keeps
# whatever it wrote. Every `gh` call in the session is addressed by this value, so
# accepting output from a failed read sends one project's review traffic
# somewhere else.
_rb_origin="$(command git remote get-url origin 2>/dev/null)" || {
    echo "ABORT: could not read origin in $(command pwd 2>/dev/null)"; exit 1; }
[[ -n $_rb_origin ]] || { echo "ABORT: origin is empty; there is no repository to pin this session to"; exit 1; }
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
    echo "ABORT: origin contains a newline; it cannot be a single value"; exit 1
fi
printf '%s\n' "$_rb_origin"
exit 0
