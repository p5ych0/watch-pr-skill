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
# ── STDOUT IS NOT OPEN UNTIL THERE IS A VALUE ──────────────────────────────
#
# The caller assigns this script's stdout to the variable every `gh` call is
# addressed by, so anything else reaching that stream is data corruption rather
# than noise. An operator with `SHELLOPTS=xtrace` and `BASH_XTRACEFD=1` exported
# traces this process from its FIRST command — before any `set +x` can run, and
# before the re-exec that drops those variables — and every one of those lines
# lands in the captured value. Measured: the clearing loop alone put fifteen trace
# lines in front of the URL.
#
# Re-execing cannot retract bytes already written, so the answer is not to write
# them: the real stdout is parked on fd 9 and fd 1 becomes stderr for the whole
# body. Traces follow fd 1 and go to stderr with everything else; the value, and
# the reasons for refusing to produce one, are the only things written to fd 9.
#
# ONCE, NOT ONCE PER PROCESS, AND THE DESCRIPTOR IS ASKED RATHER THAN INFERRED.
# The re-exec below replaces this process and file descriptors survive it, so a
# child parking again would point fd 9 at what is by then already stderr — the
# value written to stderr while the caller captured nothing. That was the first
# version, and the driver captured `+ exec` and no URL.
#
# The second version keyed it on the re-exec marker, which is wrong in the other
# direction: a caller that already has that marker in its environment skips the
# parking, fd 9 is never opened, and every write to it fails with `Bad file
# descriptor`. The fixture said so immediately. So the question asked is the one
# that matters — is fd 9 already ours — and it is asked OF the descriptor.
#
# `exec` IS A NAME, and a shadowed one makes this a no-op, which leaves the stream
# exactly as it was without this line. The redirect can fail without making
# anything worse; that is the whole of what it promises.
{ : >&9; } 2>/dev/null || exec 9>&1 1>&2

# `set -uo pipefail`, NOT `-e`: the probes below report their answers as exit
# statuses. See CLAUDE.md § Bash conventions.
set -uo pipefail


# ── EVERY INHERITED FUNCTION IS CLEARED FIRST, BEFORE ANY NAME IS USED ─────
#
# BEFORE THE RE-EXEC, SO THE HOP IS MADE BY THE BUILTIN. `exec` is a name, and a
# hook defining `exec() { return 0; }` turns the hop below into a no-op: the guard
# falls through as though the marker had been set.
#
# THE ORDER IS DEFENCE IN DEPTH, NOT A FIX, and measuring said so. With `exec`
# shadowed and the clearing AFTER the hop, the read is still correct — the hook's
# `git` is removed by the sweep either way. What a skipped hop actually costs is
# the hook VARIABLES, and `SHELLOPTS` is readonly in a shell, so `set +x` below
# answers the one that matters. This order is kept because a builtin-made hop is
# strictly better and costs nothing, not because it changes an outcome.
#
# An exported function is inherited through the environment and survives a
# re-exec, which only drops the hook variables. It shadows the name it is
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
#
# EVERY NAME ON THIS LINE IS A BUILTIN OR CLEARED BY NOW — `exec`, `env` and
# `unset` above it — because the clearing runs first. See the block above.
if [[ -z ${RB_ORIGIN_CLEAN-} ]]; then
    RB_ORIGIN_CLEAN=1 exec env -u BASH_ENV -u ENV -u SHELLOPTS -u BASH_XTRACEFD bash "$0" "$@"
fi
unset -v RB_ORIGIN_CLEAN 2>/dev/null || true

# THIS DOES NOT CLOSE THE CLASS, and saying so is the point. The clearing above is
# itself made of names — `unset`, `builtin`, `compgen` — and so is the hop, which
# needs `exec`. A hook defining no-ops for `unset`, `builtin` and `exec`, plus a
# `command` that answers with a forged URL, walks through all of it: the clear is
# a no-op, the enumeration returns nothing, the hop does not happen, and the read
# takes the forged value. Reproduced, not theorised.
#
# There is no terminator inside a process. `set -o posix` would make special
# builtins outrank functions, and it is reached through `set`. `pr-selfcheck.sh`
# records the identical limit for the identical reason, and this file inherits it
# rather than pretending otherwise.
#
# What the regress needs is a parent already executing arbitrary code as the
# operator — and such a shell can edit this file, or the commit, instead of
# out-arguing its bootstrap. That is the boundary #76 settled: hardening buys the
# versions of the attack that do NOT own the shell outright, and this file buys
# every one of them that a single forged name reaches.
#
# AND A POISONED `PATH` IS NOT CLOSED HERE EITHER, which is a different exposure
# from the ones above and worth separating. A hook that prepends a directory
# holding a forged `git` — and makes `PATH` readonly so its own shell cannot undo
# it — is not answered by clearing functions or by the re-exec: the value survives
# as an ordinary inherited variable, and this process has no way to know which
# `PATH` was the honest one. It is also not specific to this helper. Every `gh`
# call in every script resolves the same way, so a `PATH` the operator does not
# control compromises the whole loop rather than this read. Filed as its own
# issue; see the header for what this file DOES answer.

MODE="${1-}"
case "$MODE" in
    read|pin) ;;
    "") echo "ABORT: a mode is required: 'read' (print origin's URL) or 'pin' (print REVIEW_BUS_REMOTE as a child sees it)" >&9; exit 1 ;;
    *)  echo "ABORT: '$MODE' is not a mode; expected 'read' or 'pin'" >&9; exit 1 ;;
esac

if [[ $MODE = pin ]]; then
    # NO VALIDATION HERE. The caller is asking what a child inherits, and "nothing"
    # is a real answer it needs — the one that says the export did not take. An
    # empty line and status 0 says exactly that; refusing would make the two
    # failures indistinguishable from this side.
    printf '%s\n' "${REVIEW_BUS_REMOTE-}" >&9
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
_rb_origin="$(command git remote get-url origin 2>/dev/null; _rb_s=$?; printf x; exit "$_rb_s")" || {
    echo "ABORT: could not read origin in $(command pwd 2>/dev/null)" >&9; exit 1; }
_rb_origin="${_rb_origin%x}"
# `git` TERMINATES ITS OUTPUT WITH ONE NEWLINE, and that one is not data. Anything
# after it is — and the newline in this pattern is written literally for the same
# reason as the one below: `$(printf '\n')` strips its own newline, so the pattern
# would be empty, nothing would be removed, and every valid origin would be refused
# for carrying `git`'s own terminator. That is the second time this exact
# substitution has been wrong in this file.
_rb_origin="${_rb_origin%'
'}"
[[ -n $_rb_origin ]] || { echo "ABORT: origin is empty; there is no repository to pin this session to" >&9; exit 1; }
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
    echo "ABORT: origin contains a newline; it cannot be a single value" >&9; exit 1
fi
printf '%s\n' "$_rb_origin" >&9
exit 0
