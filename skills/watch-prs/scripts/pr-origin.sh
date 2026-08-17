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
# called `bash` if the caller has one, and such a function can write a forged URL
# to fd 9 and return — which is the caller's capture. A path cannot be shadowed.
#
# `bash -p` IS THE CALLER'S PART AND CANNOT BE DELEGATED. Privileged mode is what
# stops `BASH_ENV` being sourced, so it has to be in force before this file's first
# line — the hop below reaches it a moment too late, and a hook needs to shadow
# nothing to use that moment: a hook that writes the value file and exits is
# enough, and when the value travelled on a descriptor it was shorter still —
# `printf '…' >&9; exit 0`, because fd 9 was the caller's capture by then. The hop stays for a caller that forgets, and it is
# the difference between a defence and a default.
#
# THE BRACES AND THE DESCRIPTORS ARE THE INVOCATION, not decoration around it —
# see the block on fd 9 below. A usage line teaching the simple form is a usage
# line teaching a session that refuses itself under an inherited xtrace, so both
# copies of it say the same thing.
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
# intercepted. If `exec` or `env` is shadowed the hop silently does not happen and
# this file runs on unprotected — the regress recorded at the bottom, unchanged
# and unclosable from inside a process.
# STRICT MODE IS SET HERE, AFTER THE HOP, AND THAT POSITION IS FORCED. `bash -p`
# ignores an inherited `SHELLOPTS`, which is most of why it is used — so a strict
# calling shell cannot supply these, and setting them before the hop would not
# survive it either. `CLAUDE.md` classifies this file in the `set -uo pipefail`
# row; an earlier draft deleted the line along with the block it lived in and the
# script ran with none of it.
#
# `-e` IS EXCLUDED, as in every other helper here: the probes below report their
# answers as exit statuses. See CLAUDE.md § Bash conventions.
#
# AND THE HOP IS BOUNDED, because a guard on shell state loops forever if the hop
# does not change that state — a `bash` that ignores `-p`, or an `env` that never
# reaches one. Removing `-p` from the line below hangs this script rather than
# failing it, which is how the bound was found.
#
# FORGING THE BOUND COSTS A REFUSAL, NOT A VALUE. A hook can set this variable, and
# then this script aborts instead of hopping — no read happens, nothing is
# captured, and the driver stops. That is the difference between the bound and the
# guard: the bound may be forged into a stop, the guard may not be forged at all.
if [[ $- != *p* ]]; then
    if [[ -n ${RB_ORIGIN_HOP-} ]]; then
        echo "ABORT: this shell did not honour 'bash -p'; refusing to read origin unprotected" >&2
        exit 1
    fi
    RB_ORIGIN_HOP=1 exec /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS -u BASH_XTRACEFD bash -p "$0" "$@"
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
# TRUNCATED BEFORE ANYTHING ELSE, so a refusal cannot leave a previous run's value
# behind for the caller to read back as this one's.
: > "$OUT" || { echo "ABORT: could not write to '$OUT'" >&2; exit 1; }

if [[ $MODE = pin ]]; then
    # NO VALIDATION HERE. The caller is asking what a child inherits, and "nothing"
    # is a real answer it needs — the one that says the export did not take. An
    # empty line and status 0 says exactly that; refusing would make the two
    # failures indistinguishable from this side.
    printf '%s\n' "${REVIEW_BUS_REMOTE-}" > "$OUT"
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
printf '%s\n' "$_rb_origin" > "$OUT"
exit 0

# ── WHAT THIS DOES NOT CLOSE ───────────────────────────────────────────────
#
# Written here rather than left for a reader to rediscover, and referenced from
# the fallback hop above. Both need a shell that is already executing arbitrary
# code as the operator — and such a shell can edit this file, or the commit,
# instead of out-arguing it.
#
# `exec` AND `env`, IN THE FALLBACK HOP. When the caller starts this file the
# documented way — `/usr/bin/env bash -p …` — the hop never runs and neither name
# is reached. It exists for a caller that forgets, and there it is made of names:
# a shadowed `exec` leaves the process where it was, unprivileged, with the hook
# already sourced. That is a default failing to engage rather than a defence
# failing, and the difference is why the caller's part is asserted by
# `test-pr-skill-contract.sh` rather than assumed.
#
# A POISONED `PATH`, WHICH IS NOT THIS FILE'S TO ANSWER. A directory prepended to
# `PATH` — readonly, so the hook's own shell cannot undo it — supplies a forged
# `git` here and a forged `gh` in every other helper. It is not specific to the
# origin read, and a defence belonging to one helper would be the narrow guard
# this repository keeps having to delete. Filed as #91, with the three candidate
# fixes and why each trades a hostile-shell exposure for routine breakage.
