#!/usr/bin/env bash
# Unit tests for pr-origin.sh.
#
# The subject exists to answer two questions from OUTSIDE the driving shell — what
# origin says, and what a child inherits — so most of this file is about what the
# driving shell can do to it and cannot. Every attack below defeats the equivalent
# code when it runs inline in `SKILL.md`; that is the whole point of the script.
#
# THE CONTRACT UNDER TEST: the caller starts it with `/usr/bin/env bash -p` and
# names a file; the VALUE goes to that file and every REASON goes to stderr, and
# nothing is ever written to stdout. `run` below joins the two only so a single
# assertion can look at both.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-origin.sh"

# THIS FIXTURE'S SUBJECT IS AN ENVIRONMENT-DRIVEN OVERRIDE, so it clears the
# environment itself. The subject now carries EVERY set `GIT_CONFIG_*` variable
# through to git, so a contributor who exports one — `GIT_CONFIG_PARAMETERS` from
# a `git -c` wrapper, a `GIT_CONFIG_COUNT` rewrite of their own — has it added to
# each case's controlled entries: the deliberately unrewritten probe comes back
# rewritten, and ordinary cases fail for a reason that is not their subject.
#
# `pr-selfcheck.sh` cannot do this. It clears inherited FUNCTIONS and the startup
# hooks, and it must not clear arbitrary exported values: `SKILL.md` pins the
# session by exporting `REVIEW_BUS_REMOTE`, and the suite runs with that pin in
# the environment. Nor can it live in `testlib.sh`, which ships at runtime inside
# `pr-ci-state.sh` — an `unset` there would strip the operator's own git config
# out of a live session. It belongs here, in the file whose subject it is.
for _n in ${!GIT_CONFIG_@}; do unset "$_n"; done
unset _n

TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

REAL='git@github.com:acme/widget.git'
FORGED='git@github.com:WRONG/other.git'

# ── a checkout whose origin is known ───────────────────────────────────────
mkdir -p "$TMP/nohome"
REPO="$TMP/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q . && git remote add origin "$REAL" ) >/dev/null 2>&1 \
    || { die "could not build the scratch checkout"; echo "RESULT: FAIL"; exit 1; }

# THE VALUE GOES TO A FILE AND THE REASONS GO TO STDERR, which is the documented
# contract and the reason there is no descriptor in it. Three mechanisms were
# tried: stdout, then fd 9 with the redirections on a group, then moving
# `BASH_XTRACEFD` out of the way. Each put the value on a stream a caller might be
# tracing to, and the last one closed fd 2 when it restored the variable.
run() {   # run <mode> [env-entries…] ; prints "<rc>|<output>"
    local mode="$1"; shift
    local out rc=0
    # `bash -p` AS THE CALLER, which is the documented invocation. Privileged mode
    # has to be in force before the subject's first line, and only the caller can
    # arrange that: there is no hop inside the file and it is not executable. A
    # hook needs to shadow nothing to use the gap — one that writes the transport
    # file it can see as `$2` and exits has already answered.
    # A DIRECTORY THE HELPER CREATES, and a fresh name per run. Since #157 the
    # argument is the DIRECTORY: the helper `mkdir`s it — which is the exclusion,
    # since `mkdir` refuses an existing name whatever it holds — and names the file
    # inside it itself. The caller reads `<dir>/origin` or `<dir>/pin`.
    #
    # A FRESH NAME PER CALL, AND `mktemp` IS WHAT GIVES ONE. A path this fixture
    # has already handed to one case is one `mkdir` refuses for the next, which is
    # the contract working — so every call needs a name of its own, and two earlier
    # attempts did not give it.
    #
    # A COUNTER CANNOT: `run` is always called inside a command substitution, so the
    # increment happens in a subshell and never reaches the next call.
    #
    # NOR CAN `$$` AND `$RANDOM`: on bash 3.2.57 a subshell inherits the parent's
    # random state UNADVANCED, so successive command substitutions taken from the
    # same parent state produce the same value — and `$$` is the parent's pid in
    # both. Two calls then name one path, the first leaves a directory behind, and
    # the second is refused by the exclusion. The `macos-shell` job is where that
    # shows, which is the difference in BEHAVIOUR this repository records as the
    # half a feature list does not contain.
    #
    # `mktemp -d` ASKS THE KERNEL, and the child under it is what the helper is
    # given: the parent exists and is this run's, the child does not exist at all,
    # which is exactly the contract. Under `$TMP`, so the EXIT trap collects it.
    local vp vd vf diag
    # AND THE ALLOCATION'S FAILURE STOPS THIS CALL. `die` records the failure and
    # RETURNS — it does not end the fixture — so a `die` alone left `vp` empty and
    # the function carried on with `vd=/dir`: a root-run fixture then creates
    # `/dir/origin` outside `$TMP`, and every later case collides with that same
    # path and stops exercising its own state. The value is read back too, because
    # a `mktemp` that succeeds and prints nothing is the same empty variable by
    # another route.
    vp=""
    vp="$(mktemp -d "$TMP/run.XXXXXX")" || vp=""
    if [ -z "$vp" ] || [ ! -d "$vp" ]; then
        die "mktemp could not allocate a scratch parent for a run; this call is abandoned rather than aimed at /dir"
        return 1
    fi
    vd="$vp/dir"
    case "$mode" in read) vf="$vd/origin" ;; *) vf="$vd/pin" ;; esac
    # A CONTROLLED `HOME`, so these cases do not read the contributor's git
    # config. The helper carries `HOME` through on purpose — global
    # `url.<base>.insteadOf` rules are part of what `git remote get-url` answers —
    # and a contributor with a rule matching `git@github.com:` would see every
    # ordinary case here return the rewritten URL instead of `$REAL`, failing the
    # suite for a reason that has nothing to do with the subject. The dedicated
    # `IOHOME` case below tests rewrites deliberately, with its own `HOME`.
    #
    # AND A CONTROLLED SYSTEM CONFIG, for exactly the same reason one step further
    # out: `HOME` and `XDG_CONFIG_HOME` cover the USER's config only, and an
    # `/etc/gitconfig` carrying a rule that matches `$REAL` would rewrite the
    # answer here just as surely. `GIT_CONFIG_NOSYSTEM=1` is the documented way to
    # switch that source off, and the cases whose subject IS the opt-out set it
    # themselves.
    diag="$(cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_NOSYSTEM=1 \
        "$@" /usr/bin/env bash -p "$SCRIPT" "$mode" "$vd" 2>&1)" || rc=$?
    # THE VALUE AND THE DIAGNOSTICS ARE SEPARATE STREAMS, which is the point of the
    # file: the caller reads one and never sees the other. They are joined here
    # only so a single assertion can look at both.
    # ABSENT IS A VALUE HERE: a refusal before the create leaves no file at all,
    # and reading a missing one would put the shell's own error into the result.
    out=""
    [ -f "$vf" ] && out="$(<"$vf")"
    [ -n "$diag" ] && out="$out$diag"
    printf '%s|%s' "$rc" "$out"
}

# ── it reads what origin says ──────────────────────────────────────────────
got="$(run read)"
{ [ "${got%%|*}" = 0 ] && [ "${got#*|}" = "$REAL" ]; } \
    && pass "read prints the checkout's origin" \
    || die "read gave '${got}'"

# ── AND A FORGED `git` DOES NOT REACH IT ───────────────────────────────────
#
# This is the attack the script exists for. An unexported function is not the
# threat — it does not cross a process boundary — so the fixture uses the route
# that does: `BASH_FUNC_git%%`, which bash imports into the child before the first
# line runs. Inline in `SKILL.md` this succeeds; here the re-exec and the clearing
# are ahead of it.
got="$(run read 'BASH_FUNC_git%%=() { printf "'"$FORGED"'\n"; }')"
{ [ "${got%%|*}" = 0 ] && [ "${got#*|}" = "$REAL" ]; } \
    && pass "…and an inherited git function cannot forge the identity" \
    || die "a forged git reached the read: '${got}'"
# THE CONSEQUENCE, not just the status: the forged value must not appear at all.
case "${got#*|}" in
    *WRONG*) die "…the forged remote leaked into the output: '${got#*|}'" ;;
    *)       pass "…and its value appears nowhere in the output" ;;
esac

# ── THE FIXTURE'S OWN REACH, so the case above cannot pass vacuously ───────
#
# If `BASH_FUNC_git%%` were not imported — a typo, a bash that stopped accepting
# the form — the assertion would still pass, because the real `git` answers
# correctly. So the same entry is proved to work against a plain child first.
probe="$(run_limited 10 env 'BASH_FUNC_git%%=() { printf "'"$FORGED"'\n"; }' \
    bash -c 'git remote get-url origin' 2>&1)" || true
[ "$probe" = "$FORGED" ] \
    && pass "the forged git entry does take effect in an ordinary child" \
    || die "the git forgery never landed, so the case above proves nothing: '$probe'"

# ── A STARTUP HOOK IS AHEAD OF THE FIRST LINE, AND STILL DOES NOT WIN ──────
#
# `BASH_ENV` is sourced before the script body of an ordinary bash, so a hook
# defining `git` would be in place before anything in the file could defend
# itself. `bash -p` at the call site is what answers it — privileged mode does not
# source the hook at all.
printf 'git() { printf "%s\\n" "%s"; }\n' "$FORGED" > "$TMP/hook.sh"
got="$(run read BASH_ENV="$TMP/hook.sh")"
{ [ "${got%%|*}" = 0 ] && [ "${got#*|}" = "$REAL" ]; } \
    && pass "…and a BASH_ENV hook defining git is stepped out of" \
    || die "a BASH_ENV hook reached the read: '${got}'"
# …AND THE HOOK IS PROVED TO FIRE, for the same reason as above.
probe="$(run_limited 10 env BASH_ENV="$TMP/hook.sh" bash -c 'git remote get-url origin' 2>&1)" || true
[ "$probe" = "$FORGED" ] \
    && pass "the hook does fire in an ordinary child" \
    || die "the hook never fired, so the case above proves nothing: '$probe'"

# …AND THE HOOK CANNOT HIDE ITSELF. It can `unset BASH_ENV` on its way out, which
# defeated every guard that tested for that variable to decide whether it had
# escaped yet. Under `bash -p` there is nothing to decide: the file is never
# sourced, so erasing the evidence buys nothing.
printf 'git() { printf "%s\\n" "%s"; }\nunset BASH_ENV\n' "$FORGED" > "$TMP/sneaky.sh"
got="$(run read BASH_ENV="$TMP/sneaky.sh")"
{ [ "${got%%|*}" = 0 ] && [ "${got#*|}" = "$REAL" ]; } \
    && pass "…and one that unsets BASH_ENV on the way out is stepped out of too" \
    || die "a self-erasing hook reached the read: '${got}'"

# ── EVERY OTHER HOOK SHAPE IS ONE CASE, AND IT LIVES BELOW ─────────────────
#
# A hook that shadows `exec`, one that forges the old re-exec marker, one that
# marks `read` or `set` readonly so a sweep could not remove them — each defeated
# a version of this script that tried to escape the hook from inside a shell that
# had already run it. None of them is a separate defence now: the caller starts
# this file with `bash -p`, so `BASH_ENV` is never sourced and the hook never runs.
#
# They are exercised together, in one loop further down, because treating them as
# five cases is what produced five rounds of answering them one at a time. What is
# NOT here any more are the cases about `RB_ORIGIN_CLEAN` and the clearing sweep:
# the script reads no such variable and clears nothing, so those assertions passed
# without touching anything they named.

# ── `pin` REPORTS WHAT A CHILD SEES, WHICH IS THE POINT ────────────────────
got="$(run pin REVIEW_BUS_REMOTE="$REAL")"
{ [ "${got%%|*}" = 0 ] && [ "${got#*|}" = "$REAL" ]; } \
    && pass "pin prints the value a child inherits" \
    || die "pin gave '${got}'"
# …AND ABSENCE IS AN ANSWER, NOT A REFUSAL. "The export did not take" is exactly
# what the caller needs to distinguish, so it is an empty line and status 0 rather
# than an abort, which would look like every other failure from that side.
rm -rf "$TMP/pin.value"
run_limited 20 env -u REVIEW_BUS_REMOTE HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" pin "$TMP/pin.value" >/dev/null 2>&1; pin_rc=$?
pin_out="$(<"$TMP/pin.value/pin")"
{ [ "$pin_rc" = 0 ] && [ -z "$pin_out" ]; } \
    && pass "…and an unset pin is an empty answer, not an error" \
    || die "an unset pin gave rc=$pin_rc out='$pin_out'"

# ── MODES ARE NAMED, AND AN UNKNOWN ONE IS REFUSED ─────────────────────────
got="$(run '')"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF 'a mode is required'; } \
    && pass "a missing mode is refused by name" \
    || die "a missing mode gave '${got}'"
got="$(run sideways)"
{ [ "${got%%|*}" = 1 ] && printf '%s' "${got#*|}" | grep -qF "'sideways' is not a mode"; } \
    && pass "…and an unknown one says which it was" \
    || die "an unknown mode gave '${got}'"

# ── EVERY REFUSAL IS A REFUSAL, AND PRINTS NO VALUE ────────────────────────
#
# The caller assigns this script's stdout to the variable every `gh` call is
# addressed by. A refusal that also printed something plausible would be captured
# and used, so the absence is asserted as well as the status.
BARE="$TMP/bare"; mkdir -p "$BARE"
( cd "$BARE" && git init -q . ) >/dev/null 2>&1
rm -rf "$TMP/v";  out="$(cd "$BARE" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$TMP/v" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'ABORT:'; } \
    && pass "a checkout with no origin is refused" \
    || die "a checkout with no origin gave rc=$rc '$out'"
case "$out" in
    *github.com*|*git@*) die "…and the refusal printed something that reads as a remote: '$out'" ;;
    *)                   pass "…and prints no value with it" ;;
esac

# NOT A REPOSITORY AT ALL is the same answer, since `git` fails rather than
# printing an empty remote.
NOTREPO="$TMP/notrepo"; mkdir -p "$NOTREPO"
rm -rf "$TMP/v";  out="$(cd "$NOTREPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$TMP/v" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'ABORT:'; } \
    && pass "…and so is a directory that is not a checkout" \
    || die "a non-checkout gave rc=$rc '$out'"

# ── A REMOTE THAT PRINTS AND THEN FAILS IS NOT A VALUE ─────────────────────
#
# `git remote get-url origin` can write a plausible URL and exit non-zero, and
# command substitution keeps what it wrote. Taking the status is what separates
# them, and this is the case that proves the status is taken.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/git" <<GITSH
#!/usr/bin/env bash
# THE RULE QUERY AND THE RESOLUTION ARE TWO CALLS. The helper asks for the
# rewrite rules first and resolves second; a stub that answers both with the same
# thing makes the rule parser refuse before the case is reached.
printf '%s\n' "$FORGED"
exit 1
GITSH
chmod +x "$STUB/git"
rm -rf "$TMP/v";  out="$(cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 PATH="$STUB:$PATH" /usr/bin/env bash -p "$SCRIPT" read "$TMP/v" 2>&1)"; rc=$?
out="$( [ -f "$TMP/v/origin" ] && cat "$TMP/v/origin" )$out"
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'ABORT:'; } \
    && pass "a remote read that prints and then fails is refused" \
    || die "a printing-then-failing git gave rc=$rc '$out'"
case "$out" in
    *WRONG*) die "…and what it printed was kept anyway: '$out'" ;;
    *)       pass "…and what it printed is not passed on" ;;
esac

# ── ONE VALUE LEAVES, WHATEVER THE REMOTE CONTAINS ─────────────────────────
#
# A remote holding a newline would arrive at the caller as two values, the second
# being whatever the tail happened to be. `git remote get-url` returns ONE URL, so
# two lines here are one value containing a newline — and multi-URL remotes are
# git's own business now that git does the resolution, since it returns the first
# of them itself.
cat > "$STUB/git" <<'GITSH'
#!/usr/bin/env bash
printf 'git@github.com:acme/widget.git\ngit@github.com:WRONG/other.git\n'
GITSH
chmod +x "$STUB/git"
rm -rf "$TMP/v";  out="$(cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 PATH="$STUB:$PATH" /usr/bin/env bash -p "$SCRIPT" read "$TMP/v" 2>&1)"; rc=$?
out="$( [ -f "$TMP/v/origin" ] && cat "$TMP/v/origin" )$out"
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'newline'; } \
    && pass "a multi-line remote is refused rather than split" \
    || die "a two-line remote gave rc=$rc '$out'"

# ── A TRAILING NEWLINE IS DATA, AND THE BOUNDARY IS PRESERVED ──────────────
#
# Command substitution strips ALL trailing newlines and cannot tell `git`'s output
# terminator from a byte that was in the value. The read therefore keeps the
# boundary with a sentinel — `printf x` inside the substitution, removed after —
# and drops exactly ONE terminator, so anything beyond it survives to be checked.
#
# MEASURED FIRST, because the obvious way to provoke this does not work: a remote
# configured as `git@…:acme/widget.git` followed by a newline produces output
# byte-identical to one without it. `git` consumes the configured newline as its
# terminator, so the case cannot be reached through the config read on this
# version. The sentinel is kept so the read does not DEPEND on that, and the stub
# below is what holds it there.

cat > "$STUB/git" <<'GITSH'
#!/usr/bin/env bash
printf 'git@github.com:acme/widget.git\n\n'
GITSH
chmod +x "$STUB/git"
rm -rf "$TMP/v";  out="$(cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 PATH="$STUB:$PATH" /usr/bin/env bash -p "$SCRIPT" read "$TMP/v" 2>&1)"; rc=$?
out="$( [ -f "$TMP/v/origin" ] && cat "$TMP/v/origin" )$out"
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'newline'; } \
    && pass "a trailing data newline is refused, not stripped into a valid slug" \
    || die "a trailing data newline gave rc=$rc '$out'"
# …AND PLAIN COMMAND SUBSTITUTION WOULD HAVE ACCEPTED IT, which is what makes the
# sentinel load-bearing rather than decorative.
naive="$(cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 PATH="$STUB:$PATH" bash -c 'git remote get-url origin' 2>&1)" || true
[ "$naive" = 'git@github.com:acme/widget.git' ] \
    && pass "…where a bare capture would have taken the truncated value" \
    || die "the comparison case did not reproduce the naive result: '$naive'"

# ── AN INHERITED xtrace CANNOT REACH THE VALUE, WHATEVER IT TRACES TO ──────
#
# Three mechanisms were tried before this one and each failed here. On stdout, a
# caller tracing to fd 1 wrote its trace into the capture. On fd 9 with the
# redirections on a group, a caller tracing to fd 9 had that target pointed at the
# capture by the `9>&1`. Moving `BASH_XTRACEFD` out of the way fixed one target and
# broke the other depending on where the assignment sat — and restoring it closed
# fd 2, because bash closes the descriptor the variable referred to.
#
# A path has none of those properties: the caller's tracing goes wherever it
# already went, and the subject writes where it was told. So the case is the same
# for every trace target, and both are run.
cat > "$TMP/tr.sh" <<TRSH
cd "$REPO" || exit 1
rm -rf "$TMP/tr.value"
/usr/bin/env bash -p "$SCRIPT" read "$TMP/tr.value" || printf 'CALL_FAILED\n' >&2
printf 'VALUE=%s\n' "\$(<"$TMP/tr.value/origin")" >&2
TRSH
for _fd in 1 9; do
    tr_out="$(run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 SHELLOPTS=xtrace BASH_XTRACEFD="$_fd" bash "$TMP/tr.sh" \
        9>>"$TMP/tr.trace" 2>&1 >/dev/null)" || true
    case "$tr_out" in
        *"VALUE=$REAL"*) pass "a caller tracing to fd $_fd gets the value alone" ;;
        *)               die "tracing to fd $_fd reached the value: '$tr_out'" ;;
    esac
done
# …AND THE TRACING IS PROVED TO BE ON, or both cases pass on runs never traced.
tprobe="$(run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c ':' 2>&1)" || true
case "$tprobe" in
    *'+ :'*) pass "…and the exported xtrace does trace an ordinary child" ;;
    *)       die "the xtrace never took effect, so the cases above prove nothing: '$tprobe'" ;;
esac

# ── A `bash` FUNCTION IN THE CALLER CANNOT STAND IN FOR THE INTERPRETER ────
#
# The call says `/usr/bin/env bash -p` because `bash -p` alone is a NAME: a
# function called `bash` runs instead, and it can write the value file itself and
# return without the subject running at all.
rm -rf "$TMP/fn.value"
run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 bash -c '
    bash() { printf "%s\n" "'"$FORGED"'" > "'"$TMP/fn.value"'"; return 0; }
    cd "'"$REPO"'" || exit 1
    /usr/bin/env bash -p "'"$SCRIPT"'" read "'"$TMP/fn.value"'"' >/dev/null 2>&1 || true
[ "$(<"$TMP/fn.value/origin")" = "$REAL" ] \
    && pass "a bash function in the caller does not stand in for the interpreter" \
    || die "a shadowed bash wrote the value: '$(<"$TMP/fn.value")'"
# …AND THE SAME CALL WITHOUT THE PATH IS TAKEN BY IT, so the path is load-bearing.
rm -f "$TMP/fn2.value"
run_limited 20 bash -c '
    bash() { printf "%s\n" "'"$FORGED"'" > "'"$TMP/fn2.value"'"; return 0; }
    cd "'"$REPO"'" || exit 1
    bash -p "'"$SCRIPT"'" read "'"$TMP/fn2.value"'"' >/dev/null 2>&1 || true
[ "$(<"$TMP/fn2.value")" = "$FORGED" ] \
    && pass "…where the unpathed form calls the function instead" \
    || die "the comparison did not reproduce the shadowed-bash attack: '$(<"$TMP/fn2.value")'"

# ── A HOOK THAT SHADOWS NOTHING AT ALL ─────────────────────────────────────
#
# It does not have to defeat a guard; it only has to run first. `BASH_ENV` is
# sourced inside the script's own shell, so the hook can see the transport path as
# `$2` — writing a plausible URL there and exiting is a complete attack against
# any defence that lives inside this file. `bash -p` at the CALL SITE is the
# answer, because privileged mode is what stops the hook being sourced at all, and
# nothing inside the file can undo work that happened before its first line.
# THE HOOK FOLLOWS THE HELPER'S CONTRACT, whose argument it can see as `$2` — it
# is sourced inside the script's own shell, so the script's arguments are its
# arguments. Since #157 that argument is a DIRECTORY, so the hook creates it and
# writes the leaf inside; one that still wrote a FILE at `$2` left the caller
# reading `<file>/origin`, which is absent whatever happened — so the unprivileged
# comparison below saw nothing and took its "this bash cannot reach the arguments"
# branch on a shell where the attack lands perfectly.
# AND IT REFUSES AN EMPTY ARGUMENT BEFORE BUILDING A LEAF FROM IT. On bash 3.2.57
# a `BASH_ENV` hook does not get the script's positional parameters, so `$2` is
# EMPTY there — `mkdir -p ""` fails, and the redirection after it still expands to
# `/origin`. Run as root that creates or truncates a file at the filesystem root;
# run unprivileged it fails silently and the case reads the absent value as the
# version-dependent result. Either way the write escapes `$TMP` and the EXIT trap
# cannot collect it. Exiting on the empty argument produces exactly the outcome
# that shell should have — the hook writes nothing and the helper never runs —
# and the `mkdir` status is taken for the same reason.
printf "[ -n \"\${2:-}\" ] || exit 0\nmkdir -p \"\$2\" 2>/dev/null || exit 0\nprintf '%%s\\n' '%s' > \"\$2/origin\"\nexit 0\n" "$FORGED" > "$TMP/hook-direct.sh"
got="$(run read BASH_ENV="$TMP/hook-direct.sh")"
{ [ "${got%%|*}" = 0 ] && [ "${got#*|}" = "$REAL" ]; } \
    && pass "a hook that writes the value file and exits never runs" \
    || die "a hook needing no shadowed name reached the value: '${got}'"
# …AND WITHOUT `-p` AT THE CALL SITE IT WOULD HAVE WON, which is what makes the
# caller's part load-bearing rather than belt-and-braces.
#
# THROUGH AN ORDINARY `bash`, NOT BY EXECUTING THE FILE. The helper is no longer
# executable, so `"$SCRIPT" …` fails before any shell starts — the hook is never
# sourced, the value file stays absent, and the empty branch below accepted that
# as "the attack did not land on this version". It proved nothing and would have
# stayed green with the attack setup broken. An interpreter has to be started for
# the comparison to mean anything.
rm -rf "$TMP/unprot.value"
( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 BASH_ENV="$TMP/hook-direct.sh" \
    /usr/bin/env bash "$SCRIPT" read "$TMP/unprot.value" ) >/dev/null 2>&1 || true
unprot=""
[ -f "$TMP/unprot.value/origin" ] && unprot="$(<"$TMP/unprot.value/origin")"
# REPORTED, NOT REQUIRED, because the ROUTE is version-dependent. This hook writes
# the value file whose path it reads as `$2` — the script's own arguments, since
# `BASH_ENV` is sourced inside the script's shell. bash 5 gives it those arguments;
# bash 3.2.57 does not, so on that shell the hook cannot find the file and the
# attack does not land at all.
#
# What is REQUIRED is the case above: under the documented invocation the hook
# never runs. This one exists to show the caller's `bash -p` is load-bearing where
# the attack is reachable, and `CLAUDE.md` § Portability records why requiring one
# version's route turns the job red for a change that is correct — twice already in
# this pull request.
case "$unprot" in
    "$FORGED") pass "…where the same hook takes the value from an unprivileged first shell" ;;
    "")        pass "…and on this bash the hook cannot reach the script's arguments at all" ;;
    *)         die "the unprivileged comparison gave neither the forged value nor nothing: '$unprot'" ;;
esac

# ── AN OUTPUT THAT IS A SYMLINK IS REFUSED, AND ITS TARGET IS UNTOUCHED ────
#
# `: > "$OUT"` opened with O_TRUNC and FOLLOWED SYMLINKS. An account that can
# replace the directory this path names puts a symlink there pointing at any file
# the operator owns, and the helper truncates that file and writes a remote URL
# into it — with the caller's `-O` check passing precisely BECAUSE the target
# belongs to the operator. The earlier symlink case pointed at root-owned
# `/etc/hostname`, which the caller refuses for the wrong reason; this one points
# at a file this user owns, which is the case that reached the truncation.
SYMDIR="$TMP/symcase"
mkdir -p "$SYMDIR"
printf 'PRECIOUS\n' > "$SYMDIR/victim"
ln -s "$SYMDIR/victim" "$SYMDIR/out"
sym_rc=0
sym_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$SYMDIR/out" 2>&1 )" || sym_rc=$?
{ [ "$sym_rc" -ne 0 ] \
  && case "$sym_diag" in *exclusively*) true ;; *) false ;; esac; } \
    && pass "an output that is a symlink to an owned file is refused" \
    || die "the symlink output was accepted (rc=$sym_rc diag='$sym_diag')"
# THE CONSEQUENCE, which is the finding: the target must be untouched.
[ "$(cat "$SYMDIR/victim")" = PRECIOUS ] \
    && pass "…and the file it pointed at is not truncated" \
    || die "the symlink target was overwritten: '$(cat "$SYMDIR/victim")'"
# …AND A PRE-EXISTING REGULAR FILE IS REFUSED TOO, which is the same open. The
# caller allocates a fresh directory per run, so nothing legitimate collides here.
printf 'STALE\n' > "$SYMDIR/plain"
plain_rc=0
plain_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$SYMDIR/plain" 2>&1 )" || plain_rc=$?
{ [ "$plain_rc" -ne 0 ] && [ "$(cat "$SYMDIR/plain")" = STALE ]; } \
    && pass "…and a path that already exists is refused rather than truncated" \
    || die "an existing output was truncated (rc=$plain_rc)"
# …AND THE OBJECT IT DOES CREATE IS PRIVATE. O_EXCL says who may replace it; the
# mode says who may write it once it is there.
rm -f "$TMP/modecheck.marker"
rm -rf "$TMP/modecheck"
( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$TMP/modecheck" ) >/dev/null 2>&1
mode="$(ls -l "$TMP/modecheck/origin" 2>/dev/null | cut -c1-10)"
case "$mode" in
    -rw-------) pass "…and the object it creates is readable only by this user" ;;
    *)          die "the transport was created with mode '$mode'" ;;
esac

# ── A GLOBAL `insteadOf` RULE IS STILL EXPANDED ────────────────────────────
#
# `git remote get-url` expands `url.<base>.insteadOf`, and those rules live in the
# user's GLOBAL config — so emptying the environment to shut out `GIT_DIR` also
# hid them, and a checkout whose origin is `work:acme/widget.git` came back
# unexpanded with host `work`. `rb_identity` then refuses a valid checkout, or
# addresses the session at a host it does not push to.
IOHOME="$TMP/insteadof-home"
mkdir -p "$IOHOME"
printf '[url "git@ghe.example:"]\n\tinsteadOf = work:\n' > "$IOHOME/.gitconfig"
IOREPO="$TMP/insteadof-repo"
mkdir -p "$IOREPO"
( cd "$IOREPO" && git init -q . && git remote add origin 'work:acme/widget.git' ) >/dev/null 2>&1 \
    || die "could not build the insteadOf checkout"
rm -rf "$TMP/io.value"
( cd "$IOREPO" && run_limited 20 env HOME="$IOHOME" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$TMP/io.value" ) >/dev/null 2>&1
io_got="$(cat "$TMP/io.value/origin" 2>/dev/null)"
[ "$io_got" = 'git@ghe.example:acme/widget.git' ] \
    && pass "a global insteadOf rule is expanded, not returned as the alias" \
    || die "insteadOf was not expanded (got '$io_got')"
# THE FIXTURE'S OWN REACH: the rule must actually apply to a bare `git` here, or
# the case above passes on a checkout that never needed it.
io_reach="$(cd "$IOREPO" && HOME="$IOHOME" git remote get-url origin 2>/dev/null)"
[ "$io_reach" = 'git@ghe.example:acme/widget.git' ] \
    && pass "…where the same rule applies to a bare git" \
    || die "the insteadOf rule does not apply here (got '$io_reach'); the case above proves nothing"
# …AND `GIT_DIR` IS STILL SHUT OUT with `HOME` carried through, which is the
# combination the emptied environment existed for.
IOOTHER="$TMP/insteadof-other"
mkdir -p "$IOOTHER"
( cd "$IOOTHER" && git init -q . && git remote add origin "$FORGED" ) >/dev/null 2>&1 \
    || die "could not build the second insteadOf checkout"
rm -rf "$TMP/io2.value"
( cd "$IOREPO" && run_limited 20 env HOME="$IOHOME" GIT_CONFIG_NOSYSTEM=1 GIT_DIR="$IOOTHER/.git" \
    /usr/bin/env bash -p "$SCRIPT" read "$TMP/io2.value" ) >/dev/null 2>&1
io2_got="$(cat "$TMP/io2.value/origin" 2>/dev/null)"
[ "$io2_got" = 'git@ghe.example:acme/widget.git' ] \
    && pass "…while GIT_DIR still cannot redirect the read" \
    || die "GIT_DIR reached the read once HOME was carried (got '$io2_got')"

# ── A DIRECTORY OTHER ACCOUNTS CAN WRITE IS REFUSED ────────────────────────
#
# Everything above protects the OBJECT; this protects the NAME. The caller can
# test that the parent belongs to the operator and cannot test whether the
# operator left it open to others — bash has no test for another account's write
# bit — so an owned mode-0777 `TMPDIR` got through, and an account with write
# there can replace the whole transport directory between this script closing its
# file and the caller opening it. Both of the caller's checks then pass, because
# the planted file belongs to the operator too.
OPENDIR="$TMP/open"
mkdir -p "$OPENDIR"
chmod 777 "$OPENDIR"
open_rc=0
open_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$OPENDIR/dir" 2>&1 )" || open_rc=$?
{ [ "$open_rc" -ne 0 ] \
  && case "$open_diag" in *"could be replaced between this write"*) true ;; *) false ;; esac \
  && [ ! -e "$OPENDIR/dir" ]; } \
    && pass "a transport directory other accounts can write is refused" \
    || die "the helper wrote into a world-writable directory (rc=$open_rc diag='$open_diag')"
# …AND A GROUP-WRITABLE ONE TOO, which is the shape a shared machine actually has.
chmod 770 "$OPENDIR"
open_rc=0
open_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$OPENDIR/dir" 2>&1 )" || open_rc=$?
{ [ "$open_rc" -ne 0 ] \
  && case "$open_diag" in *"could be replaced between this write"*) true ;; *) false ;; esac \
  && [ ! -e "$OPENDIR/dir" ]; } \
    && pass "…and so is a group-writable one" \
    || die "the helper wrote into a group-writable directory (rc=$open_rc diag='$open_diag')"
# …AND SO IS AN ANCESTOR, which is the case the first version of this check
# missed. The directory holding the file is created mode 700 by the caller, so
# checking only that one always passed — while an account with write on the
# directory ABOVE it can rename it after the check and leave a writable
# replacement at the same name. What must be refused is a writable component
# anywhere on the way to the file.
chmod 700 "$OPENDIR"
ANCESTOR="$TMP/anc"
mkdir -p "$ANCESTOR/mid/leaf"
chmod 777 "$ANCESTOR/mid"
chmod 700 "$ANCESTOR/mid/leaf"
anc_rc=0
anc_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$ANCESTOR/mid/leaf/dir" 2>&1 )" || anc_rc=$?
{ [ "$anc_rc" -ne 0 ] \
  && case "$anc_diag" in *"could be replaced between this write"*) true ;; *) false ;; esac \
  && [ ! -e "$ANCESTOR/mid/leaf/dir/origin" ]; } \
    && pass "…and a writable ANCESTOR is refused, not just the directory itself" \
    || die "an ancestor that can rename the transport directory was accepted (rc=$anc_rc diag='$anc_diag')"
# …WHILE STICKY IS ACCEPTED, which is why `/tmp` still works: anyone may create an
# entry there and nobody may rename another account's. Without this the check
# would refuse the directory it was written for.
chmod 1777 "$ANCESTOR/mid"
rm -rf "$ANCESTOR/mid/leaf/dir"
( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$ANCESTOR/mid/leaf/dir" ) >/dev/null 2>&1
[ "$(cat "$ANCESTOR/mid/leaf/dir/origin" 2>/dev/null)" = "$REAL" ] \
    && pass "…while a sticky ancestor is accepted, as /tmp is" \
    || die "a sticky ancestor was refused; this would refuse every ordinary session"

# …AND AN ANCESTOR OWNED BY SOMEBODY ELSE IS REFUSED WHATEVER ITS MODE, which is
# the case a permission-only test cannot see: a sticky directory stops one account
# renaming ANOTHER'S entries and does nothing about its OWNER renaming ours, and a
# mode-0755 one owned by somebody else can have the write bit added after the
# probe.
#
# THE CANDIDATE IS SEARCHED FOR, because the fixture cannot create one: a
# directory owned by a THIRD account — not the operator, not root — needs
# privileges the suite does not have. Pointing at a root-owned path instead was
# the first attempt and was invalid, since the helper TRUSTS root and the refusal
# never came. Where no such directory exists the case says so rather than
# asserting something it cannot stage.
# THE CANDIDATE MUST BE OWNED BY NEITHER, and `! -O` is not that test: it is
# false for a root-owned directory too, and the helper TRUSTS root — so pointing
# at `/lost+found` selected a path the rule accepts by design, the refusal never
# came, and the case died later on an unwritable output while never reaching the
# clause it names. The search asks the same question the helper does.
FOREIGN=""
for _cand in /lost+found /run/user/* /var/lib/* /home/*; do
    [ -d "$_cand" ] || continue
    if [ -n "$(find "$_cand" -prune ! -uid "$EUID" ! -uid 0 -print 2>/dev/null)" ]; then
        FOREIGN="$_cand"; break
    fi
done
if [ -n "$FOREIGN" ]; then
    foreign_rc=0
    foreign_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$FOREIGN/dir" 2>&1 )" || foreign_rc=$?
    { [ "$foreign_rc" -ne 0 ] \
      && case "$foreign_diag" in *"could be replaced between this write"*) true ;; *) false ;; esac; } \
        && pass "…and a component owned by another account is refused ($FOREIGN)" \
        || die "a foreign-owned component was accepted (rc=$foreign_rc diag='$foreign_diag')"
else
    # NAMED, NOT WAVED THROUGH. Staging this needs a directory owned by a THIRD
    # account — not the operator, not root — and creating one needs privileges the
    # suite does not have. What goes untested is the `! -uid $EUID -a ! -uid 0`
    # clause; the mode clause beside it is covered by the cases above, and the
    # root-owned components on the way to any real transport exercise the
    # trusted-owner branch on every run of this file.
    echo "ok   - (no third-account directory exists here; the foreign-owner clause is untested on this machine)"
fi
# …AND A SYMLINK DOES NOT HIDE THE REAL ANCESTRY. A lexical walk checks the path
# as WRITTEN: `TMPDIR=/home/me/t` pointing at a third account's tree checks
# `/home/me` and never that tree, so the account owning it can replace the
# directory after every check has passed. Symlinks cannot be refused outright
# instead — macOS reaches its own temporary directories through them.
if [ -n "$FOREIGN" ]; then
    LINKDIR="$TMP/linkcase"
    mkdir -p "$LINKDIR"
    ln -sfn "$FOREIGN" "$LINKDIR/t"
    link_rc=0
    link_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$LINKDIR/t/dir" 2>&1 )" || link_rc=$?
    { [ "$link_rc" -ne 0 ] \
      && case "$link_diag" in *"could be replaced between this write"*|*"could not examine"*|*"could not resolve"*) true ;; *) false ;; esac; } \
        && pass "…and a symlink into a third account's tree is refused, not walked lexically" \
        || die "a symlinked ancestor hid the real tree (rc=$link_rc diag='$link_diag')"
else
    echo "ok   - (no third-account directory here; the symlinked-ancestry case did not run)"
fi
# …WHILE A SYMLINK TO SOMEWHERE SAFE IS STILL FOLLOWED, which is the case macOS
# depends on: refusing every symlink would refuse that platform.
SAFELINK="$TMP/safelink"
mkdir -p "$SAFELINK"
ln -sfn "$OPENDIR" "$SAFELINK/t"
chmod 700 "$OPENDIR"
rm -rf "$OPENDIR/dir"
( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$SAFELINK/t/dir" ) >/dev/null 2>&1
[ "$(cat "$SAFELINK/t/dir/origin" 2>/dev/null)" = "$REAL" ] \
    && pass "…while a symlink to a directory this user owns is followed as before" \
    || die "a safe symlinked path was refused; macOS reaches its temporary directories this way"

# …AND AN ACL IS REFUSED, because the mode bits do not show it. A user-owned
# `0700` directory can still grant another account write through an extended ACL
# on macOS or a POSIX ACL on Linux, and `find -perm` sees none of it — every
# ownership and mode check passes while that account can replace the directory.
# What is asserted is the refusal, not the ACL's contents: reading those means
# `getfacl` on one platform and `ls -e` on the other.
if command -v setfacl >/dev/null 2>&1; then
    ACLDIR="$TMP/aclcase"
    mkdir -p "$ACLDIR"
    chmod 700 "$ACLDIR"
    # A READ-AND-EXECUTE ACL, so the MODE stays `0700` and the ACL branch is what
    # refuses. A writable one raises the visible group bits and the ownership
    # check fires first — a correct refusal for the wrong reason, which is what
    # the first version of this case asserted.
    if setfacl -m u:nobody:r-x "$ACLDIR" >/dev/null 2>&1; then
        acl_rc=0
        acl_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$ACLDIR/dir" 2>&1 )" || acl_rc=$?
        { [ "$acl_rc" -ne 0 ] \
          && case "$acl_diag" in *"access-control list"*) true ;; *) false ;; esac \
          && [ ! -e "$ACLDIR/dir" ]; } \
            && pass "…and a component carrying an ACL is refused" \
            || die "an ACL-bearing directory was accepted (rc=$acl_rc diag='$acl_diag')"
        # THE FIXTURE'S OWN REACH: the ACL must actually be there, or the case
        # passes because nothing was ever granted.
        case "$(ls -ld "$ACLDIR" | cut -d' ' -f1)" in
            *+) pass "…where the ACL is really present on it" ;;
            *)  die "setfacl reported success but left no ACL; the case above proves nothing" ;;
        esac
    else
        echo "ok   - (setfacl could not set an ACL here; that case did not run)"
    fi
else
    echo "ok   - (no setfacl on this machine; the ACL case did not run)"
fi
# THE `@` CASE NEEDS NO ACL TOOL, so it sits outside that conditional. Inside it,
# a platform without `setfacl` — stock macOS, the one whose behaviour this case is
# about — skipped the synthetic marker too, and a regression to accepting `@`
# would have stayed green exactly there.
# …AND THE `@` MARK IS REFUSED TOO, which is the one that matters on macOS:
# there `ls -l` marks extended ATTRIBUTES with `@` and security information
# with `+`, and a component carrying BOTH shows `@` ALONE — so an ACL granting
# another account `delete_child` reads as clean beside any xattr. This machine
# cannot stage that pairing, so the mark is staged directly: what is asserted
# is that the refusal keys on either mark, not on `+` alone.
XADIR="$TMP/xattrcase"
mkdir -p "$XADIR"
chmod 700 "$XADIR"
XASTUB="$TMP/xastub"
mkdir -p "$XASTUB"
printf '#!/usr/bin/env bash\n[ "$1" = -ld ] && printf "drwx------@ 2 x y 40 Jan 1 00:00 %%s\\n" "$2" && exit 0\nexec /usr/bin/ls "$@"\n' > "$XASTUB/ls"
chmod +x "$XASTUB/ls"
xa_rc=0
xa_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 PATH="$XASTUB:$PATH" \
    /usr/bin/env bash -p "$SCRIPT" read "$XADIR/dir" 2>&1 )" || xa_rc=$?
{ [ "$xa_rc" -ne 0 ] \
  && case "$xa_diag" in *"access-control list or extended attributes"*) true ;; *) false ;; esac \
  && [ ! -e "$XADIR/dir" ]; } \
    && pass "…and a component marked '@' is refused, which is how macOS shows an ACL beside an xattr" \
    || die "an '@'-marked component was accepted (rc=$xa_rc diag='$xa_diag')"

# …AND THE ACL PROBE FAILS CLOSED TOO. It is the second status-sensitive probe on
# this path and the `find` case below does not cover it: the `ls` stub used for
# `@` always succeeds. If `ls -ld` fails — the component vanished, or became
# unreadable — its empty output is indistinguishable from an unmarked safe
# component, which is the shape that let a renamed directory through before.
LSFAIL="$TMP/lsfail"
mkdir -p "$LSFAIL"
printf '#!/usr/bin/env bash\nexit 3\n' > "$LSFAIL/ls"
chmod +x "$LSFAIL/ls"
rm -rf "$OPENDIR/dir"
chmod 700 "$OPENDIR"
lsf_rc=0
lsf_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 PATH="$LSFAIL:$PATH" \
    /usr/bin/env bash -p "$SCRIPT" read "$OPENDIR/dir" 2>&1 )" || lsf_rc=$?
{ [ "$lsf_rc" -ne 0 ] \
  && case "$lsf_diag" in *"could not read the permissions"*) true ;; *) false ;; esac \
  && [ ! -e "$OPENDIR/dir" ]; } \
    && pass "…and an ACL probe that cannot run refuses rather than reading empty as unmarked" \
    || die "a failing ls was treated as a clean result (rc=$lsf_rc diag='$lsf_diag')"

# …AND A PROBE THAT CANNOT RUN IS A REFUSAL, NOT A PASS. `find` prints nothing
# when it fails, and empty output is what the walk reads as safe — so an attacker
# renaming a component mid-probe would have been let through by their own
# interference. A `find` stub that exits non-zero and prints nothing stands in for
# that race, which a fixture cannot stage for real.
FINDSTUB="$TMP/findstub"
mkdir -p "$FINDSTUB"
printf '#!/usr/bin/env bash\nexit 2\n' > "$FINDSTUB/find"
chmod +x "$FINDSTUB/find"
rm -rf "$OPENDIR/dir"
probe_rc=0
probe_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 PATH="$FINDSTUB:$PATH" \
    /usr/bin/env bash -p "$SCRIPT" read "$OPENDIR/dir" 2>&1 )" || probe_rc=$?
{ [ "$probe_rc" -ne 0 ] \
  && case "$probe_diag" in *"could not examine"*) true ;; *) false ;; esac \
  && [ ! -e "$OPENDIR/dir" ]; } \
    && pass "…and a probe that cannot run refuses rather than reading empty as safe" \
    || die "a failing probe was treated as a clean result (rc=$probe_rc diag='$probe_diag')"

# …WHILE A PRIVATE ONE IS THE ORDINARY CASE, or this would refuse every session.
chmod 700 "$OPENDIR"
rm -rf "$OPENDIR/dir"
( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$OPENDIR/dir" ) >/dev/null 2>&1
[ "$(cat "$OPENDIR/dir/origin" 2>/dev/null)" = "$REAL" ] \
    && pass "…while a private directory is written as before" \
    || die "a private directory was refused"

# ── THE HELPER CANNOT BE STARTED UNPRIVILEGED AT ALL ───────────────────────
#
# The fallback hop advertised a recovery it could not perform: by the time it ran,
# the caller's `BASH_ENV` hook had already executed in this process, and a hook
# that writes a forged value to `$2` and exits has finished before any line of
# this file. The hop is gone and so is the executable bit — `./pr-origin.sh` and
# the shebang are no longer an entry point, and the documented invocation is
# unaffected because `bash` READS the file rather than execing it.
[ ! -x "$SCRIPT" ] \
    && pass "the helper is not executable, so there is no unprivileged entry point" \
    || die "the helper is executable; ./pr-origin.sh reaches a hook-run shell"
unpriv_rc=0
unpriv_out="$( cd "$REPO" && run_limited 20 "$SCRIPT" read "$TMP/unpriv.value" 2>&1 )" || unpriv_rc=$?
[ "$unpriv_rc" -ne 0 ] \
    && pass "…and executing it directly fails rather than running unprotected" \
    || die "the helper ran when executed directly (out='$unpriv_out')"
# …AND AN UNPRIVILEGED `bash` READING IT STILL REFUSES, which is the guard rather
# than the file mode: `$-` is shell state a hook cannot write.
rm -f "$TMP/nop.value"
nop_rc=0
nop_diag="$( cd "$REPO" && run_limited 20 /usr/bin/env bash "$SCRIPT" read "$TMP/nop.value" 2>&1 )" || nop_rc=$?
{ [ "$nop_rc" -ne 0 ] \
  && case "$nop_diag" in *"not privileged"*) true ;; *) false ;; esac \
  && [ ! -s "$TMP/nop.value" ]; } \
    && pass "…and an unprivileged bash reading it refuses with nothing written" \
    || die "an unprivileged bash was accepted (rc=$nop_rc diag='$nop_diag')"

# ── A CARRIED CONFIG IS ANSWERED EXACTLY AS GIT ANSWERS IT ─────────────────
#
# A global or system config may contain `[remote "origin"] url = …`, and
# `git remote get-url origin` PREFERS it over the repository's own — measured, and
# for a while this helper read `--local` to shut that out. It no longer does, and
# the reason is that the lockout defended nothing: the same file may carry
# `url.<base>.insteadOf`, which this helper must honour, and a rewrite rule
# redirects the origin COMPLETELY where an injected URL only puts a second one in
# front (`git push origin` still contacts both). The stronger channel is
# deliberately open, so closing the weaker one bought no guarantee and cost
# agreement with git — which is what the pin needs.
#
# SO THE ASSERTION IS AGREEMENT, not a value: whatever the operator's own
# `git remote get-url origin` answers here is what the session pushes and fetches
# against, and the helper must say the same thing.
HOSTILE="$TMP/hostile-global"
printf '[url "git@ghe.example:"]\n\tinsteadOf = work:\n[remote "origin"]\n\turl = %s\n' "$FORGED" > "$HOSTILE"
rm -rf "$TMP/hg1.value"
( cd "$IOREPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL="$HOSTILE" /usr/bin/env bash -p "$SCRIPT" read "$TMP/hg1.value" ) >/dev/null 2>&1
hg_got="$(cat "$TMP/hg1.value/origin" 2>/dev/null)"
hg_git="$(cd "$IOREPO" && env HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$HOSTILE" git remote get-url origin 2>/dev/null)"
[ -n "$hg_git" ] && [ "$hg_got" = "$hg_git" ] \
    && pass "under a carried config the helper answers exactly as git remote get-url does" \
    || die "the helper and git disagree under a carried config (helper '$hg_got', git '$hg_git')"
# THE FIXTURE'S OWN REACH: that config must really change the answer, or the case
# above passes against a file with no effect and proves only that git is
# deterministic.
[ "$hg_git" = "$FORGED" ] \
    && pass "…where that config does override the repository's own origin" \
    || die "the hostile config has no effect here (git said '$hg_git'); the case above proves nothing"

# ── A LOCAL ORIGIN THAT IS ALSO A REMOTE NAME ──────────────────────────────
#
# `git ls-remote --get-url <x>` takes a URL **or the name of a remote**, so an
# origin of `mirror` beside a carried `[remote "mirror"]` resolved to the config's
# repository — the attack the local read had just closed, reopened by the command
# that was applying the rewrite. There is no git interface that applies
# `insteadOf` to a value without that ambiguity, so the rewrite is applied here by
# git's own documented rule and no name is ever resolved.
NAMEREPO="$TMP/namecollide"
mkdir -p "$NAMEREPO"
( cd "$NAMEREPO" && git init -q . && git remote add origin 'work:acme/widget.git' ) >/dev/null 2>&1 \
    || die "could not build the name-collision checkout"
NAMECFG="$TMP/namecollide.gitconfig"
printf '[url "git@ghe.example:"]\n\tinsteadOf = work:\n[remote "work:acme/widget.git"]\n\turl = %s\n' "$FORGED" > "$NAMECFG"
rm -rf "$TMP/nc.value"
( cd "$NAMEREPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL="$NAMECFG" /usr/bin/env bash -p "$SCRIPT" read "$TMP/nc.value" ) >/dev/null 2>&1
nc_got="$(cat "$TMP/nc.value/origin" 2>/dev/null)"
nc_git="$(cd "$NAMEREPO" && env HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$NAMECFG" git remote get-url origin 2>/dev/null)"
{ [ "$nc_got" = 'git@ghe.example:acme/widget.git' ] && [ "$nc_got" = "$nc_git" ]; } \
    && pass "an origin that also names a carried remote is rewritten, not resolved" \
    || die "the origin was resolved as a remote name (helper '$nc_got', git '$nc_git')"
# THE FIXTURE'S OWN REACH: that name must really resolve through the interface
# this replaced, or the case above passes because nothing was ever ambiguous.
nc_reach="$(cd "$NAMEREPO" && env HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$NAMECFG" \
    git ls-remote --get-url 'work:acme/widget.git' 2>/dev/null)"
[ "$nc_reach" = "$FORGED" ] \
    && pass "…where ls-remote --get-url does resolve that same name to the config's repository" \
    || die "the name does not resolve here (got '$nc_reach'); the case above proves nothing"

# ── A LINKED WORKTREE ANSWERS AS GIT ANSWERS ───────────────────────────────
#
# `extensions.worktreeConfig` lets a linked worktree hold its own
# `remote.origin.url`, and `git config --get` reports it — but `git remote get-url`
# does NOT: the remote machinery reads the repository's config, and that is what
# `fetch` and `push` use. Measured on git 2.55:
#
#     git config --worktree --get remote.origin.url   -> the worktree's value
#     git config --get remote.origin.url              -> the worktree's value
#     git remote get-url origin                       -> the REPOSITORY's value
#
# So there is nothing here for the helper to decide. What must hold is that it
# agrees with `git remote get-url` wherever it is run, including inside a linked
# worktree — the helper asks git the same question the session's own operations
# ask, and a scope-picking read of its own is exactly what diverged from that.
WTMAIN="$TMP/wtmain"
mkdir -p "$WTMAIN"
( cd "$WTMAIN" && git init -q . && git remote add origin "$REAL" \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
    && git worktree add -q "$TMP/wtlinked" -b wtbranch \
    && git config extensions.worktreeConfig true \
    && cd "$TMP/wtlinked" && git config --worktree remote.origin.url "$FORGED" ) >/dev/null 2>&1
if [ -d "$TMP/wtlinked" ] && [ -n "$(cd "$TMP/wtlinked" && git config --worktree --get remote.origin.url 2>/dev/null)" ]; then
    wt_git="$(cd "$TMP/wtlinked" && env HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 git remote get-url origin 2>/dev/null)"
    rm -rf "$TMP/wt.value"
    ( cd "$TMP/wtlinked" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 \
        /usr/bin/env bash -p "$SCRIPT" read "$TMP/wt.value" ) >/dev/null 2>&1
    wt_got="$(cat "$TMP/wt.value/origin" 2>/dev/null)"
    [ -n "$wt_got" ] && [ "$wt_got" = "$wt_git" ] \
        && pass "inside a linked worktree the helper answers exactly as git remote get-url does" \
        || die "the helper and git disagree in a worktree (helper '$wt_got', git '$wt_git')"
else
    echo "ok   - (this git could not stage a worktree-scoped origin; that case did not run)"
fi

# ── EVERY `GIT_CONFIG_*` VARIABLE IS CARRIED, BY PREFIX ────────────────────
#
# Git takes config from the environment through several channels, and a helper
# that names them one at a time is wrong the first time it misses one. It did:
# `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM` and `GIT_CONFIG_NOSYSTEM` were carried
# and the RUNTIME family was not, so an operator whose `insteadOf` arrives as
# `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` — or as
# `GIT_CONFIG_PARAMETERS` — had it expanded by every ordinary command and dropped
# here, pinning the session to the unexpanded alias.
#
# THE FIRST TWO CASES ARE REAL GIT, not a stub, and each asserts AGREEMENT: the
# checkout's origin is an alias, the variables carry the rule that expands it, and
# the helper must answer what `git remote get-url origin` answers beside it.
RTREPO="$TMP/runtimecfg"
mkdir -p "$RTREPO"
( cd "$RTREPO" && git init -q . && git remote add origin 'work:acme/widget.git' ) >/dev/null 2>&1 \
    || die "could not build the runtime-config checkout"
rt_case() {   # rt_case <label> <expect-pass-text> [env-entries…]
    local _label="$1" _text="$2"; shift 2
    local _got _git
    rm -rf "$TMP/rt.value"
    ( cd "$RTREPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" \
        GIT_CONFIG_NOSYSTEM=1 "$@" /usr/bin/env bash -p "$SCRIPT" read "$TMP/rt.value" ) >/dev/null 2>&1
    _got="$(cat "$TMP/rt.value/origin" 2>/dev/null)"
    _git="$(cd "$RTREPO" && env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" \
        GIT_CONFIG_NOSYSTEM=1 "$@" git remote get-url origin 2>/dev/null)"
    # THE PROBE'S OWN REACH FIRST: the rule must really expand for git here, or the
    # agreement below holds because nothing happened.
    [ "$_git" = 'git@ghe.example:acme/widget.git' ] \
        || die "$_label: the rule does not reach git here (git said '$_git'); the case proves nothing"
    [ "$_got" = "$_git" ] \
        && pass "$_text" \
        || die "$_label: the helper dropped the rule (helper '$_got', git '$_git')"
}
rt_case 'count-family' 'a rewrite supplied through GIT_CONFIG_COUNT reaches the helper' \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0='url.git@ghe.example:.insteadOf' GIT_CONFIG_VALUE_0='work:'
rt_case 'parameters' '…and one supplied through GIT_CONFIG_PARAMETERS reaches it too' \
    GIT_CONFIG_PARAMETERS="'url.git@ghe.example:.insteadOf'='work:'"
# AND WITHOUT THEM THE ALIAS COMES BACK, or the two cases above pass against a
# checkout that was never aliased.
rm -rf "$TMP/rt.value"
( cd "$RTREPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" \
    GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$TMP/rt.value" ) >/dev/null 2>&1
[ "$(cat "$TMP/rt.value/origin" 2>/dev/null)" = 'work:acme/widget.git' ] \
    && pass "…while with no rule at all the alias is what comes back" \
    || die "the alias did not survive an unrewritten read; the cases above prove nothing"

# ── …AND SETNESS COMES WITH THE PREFIX ─────────────────────────────────────
#
# A name appears in `${!GIT_CONFIG_@}` only if it is SET, which is exactly the
# distinction git draws: it reads an empty path as no such file, so an operator
# exporting `GIT_CONFIG_GLOBAL=` has switched that source OFF. A `[[ -n … ]]` test
# dropped it, the emptied environment restored git's default file, and a rule in
# that file reached this helper alone. Only a stub can see which variables
# arrived: the effect needs config files the fixture cannot write.
NSSTUB="$TMP/nsstub"
mkdir -p "$NSSTUB"
cat > "$NSSTUB/git" <<'NSSH'
#!/usr/bin/env bash
printf 'nosystem=[%s] global=[%s] system=[%s] count=[%s]
' "${GIT_CONFIG_NOSYSTEM-unset}" "${GIT_CONFIG_GLOBAL-unset}" "${GIT_CONFIG_SYSTEM-unset}" \
  "${GIT_CONFIG_COUNT-unset}" >> "${BASH_SOURCE[0]}.log"
printf 'git@github.com:seen/repo.git
'
NSSH
chmod +x "$NSSTUB/git"
ns_env() {   # ns_env [env-entries…] ; prints what the subject's git saw
    rm -rf "$TMP/ns.value"; rm -f "$NSSTUB/git.log"
    ( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" \
        PATH="$NSSTUB:$PATH" "$@" /usr/bin/env bash -p "$SCRIPT" read "$TMP/ns.value" ) >/dev/null 2>&1
    cat "$NSSTUB/git.log" 2>/dev/null
}
# BOTH DIRECTIONS. Unset must arrive unset, or the case passes against a helper
# that hard-codes a value rather than carrying the operator's decision.
ns_none="$(ns_env)"
case "$ns_none" in
    *"nosystem=[unset] global=[unset] system=[unset] count=[unset]"*)
        pass "a session that set no GIT_CONFIG_ variable passes none on" ;;
    *) die "a GIT_CONFIG_ variable appeared from nowhere ('$ns_none')" ;;
esac
ns_set="$(ns_env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/g.cfg" GIT_CONFIG_SYSTEM="$TMP/s.cfg" GIT_CONFIG_COUNT=0)"
case "$ns_set" in
    *"nosystem=[1] global=[$TMP/g.cfg] system=[$TMP/s.cfg] count=[0]"*)
        pass "…and the operator's chosen sources reach it when they set them" ;;
    *) die "a GIT_CONFIG_ variable was dropped ('$ns_set')" ;;
esac
# THE DISTINCTION THE PREFIX MAKES FOR FREE: set-but-empty is not unset.
ns_empty="$(ns_env GIT_CONFIG_NOSYSTEM= GIT_CONFIG_GLOBAL= GIT_CONFIG_SYSTEM= GIT_CONFIG_COUNT=)"
case "$ns_empty" in
    *"nosystem=[] global=[] system=[] count=[]"*)
        pass "…and an explicitly EMPTY one is carried as empty, not dropped" ;;
    *) die "an empty GIT_CONFIG_ variable was dropped, restoring git's default file ('$ns_empty')" ;;
esac

# ── A SECOND CHECKOUT NAMED BY `GIT_DIR` IS NOT THIS ONE ───────────────────
#
# `bash -p` refuses startup files and inherited functions; it keeps ordinary
# environment variables, and `GIT_DIR` is one. Exported at a second checkout it
# makes the real `git` here read THAT repository's origin while standing in this
# one — the wrong-repository failure this file exists to prevent, arriving by a
# route that has nothing to do with shadowing. `env -i` is the answer rather than
# a list of `-u`s, because the list is wrong the first time git adds a variable.
OTHER="$TMP/other"
mkdir -p "$OTHER"
( cd "$OTHER" && git init -q . && git remote add origin "$FORGED" ) >/dev/null 2>&1 \
    || die "could not build the second checkout"
got="$(run read "GIT_DIR=$OTHER/.git")"
{ [ "${got%%|*}" = 0 ] && [ "${got#*|}" = "$REAL" ]; } \
    && pass "an exported GIT_DIR cannot redirect the read to another checkout" \
    || die "GIT_DIR reached the read: '${got}'"
case "${got#*|}" in
    *WRONG*) die "…the second checkout's remote leaked into the output: '${got#*|}'" ;;
    *)       pass "…and the other repository's remote appears nowhere in the output" ;;
esac
# THE FIXTURE'S OWN REACH: the same variable must actually redirect a bare `git`,
# or the case above passes because nothing was ever pointed anywhere.
reach="$(cd "$REPO" && env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 GIT_DIR="$OTHER/.git" git remote get-url origin 2>/dev/null)"
[ "$reach" = "$FORGED" ] \
    && pass "…where the same GIT_DIR redirects a bare git" \
    || die "GIT_DIR does not redirect git here (got '$reach'); the case above proves nothing"
# …AND THE LINE IS CONFIG LOCATION VERSUS REPOSITORY SCOPE, not "every GIT_*".
# `GIT_CONFIG_GLOBAL` says WHICH CONFIG the operator's git reads, and dropping it
# does not block a redirection — it makes this helper read a DIFFERENT config
# from the session, so an `insteadOf` rule the session honours is invisible here
# and a valid checkout comes back as its unexpanded alias. It is carried, and a
# rule supplied through it must therefore apply.
IOGLOBAL="$TMP/insteadof-global"
printf '[url "git@ghe.example:"]\n\tinsteadOf = work:\n' > "$IOGLOBAL"
rm -rf "$TMP/iog.value"
( cd "$IOREPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL="$IOGLOBAL" /usr/bin/env bash -p "$SCRIPT" read "$TMP/iog.value" ) >/dev/null 2>&1
iog_got="$(cat "$TMP/iog.value/origin" 2>/dev/null)"
[ "$iog_got" = 'git@ghe.example:acme/widget.git' ] \
    && pass "…and a GIT_CONFIG_GLOBAL the operator chose is honoured, as their own git honours it" \
    || die "GIT_CONFIG_GLOBAL was dropped; the helper read a different config from the session (got '$iog_got')"

# ── THE DIRECTORY IS THIS SCRIPT'S TO CREATE, AND CREATING IT IS THE EXCLUSION ─
#
# Since #157 the argument is a directory rather than a file, and `mkdir` is what
# refuses a name somebody else got to first. That moved the exclusion off the
# CALLER, where it took three shell names, a probe apiece and a containment arm
# — every one of them a thing the operator's shell could have made readonly,
# value-transforming or a nameref. Here the name is this process's own.
#
# EVERY KIND OF EXISTING NAME, because `mkdir` refuses the lot and a reader should
# not have to know that: a directory, a regular file, and a symlink — which
# `mkdir` does not follow on the last component, so a link aimed at somewhere the
# operator owns is refused rather than written through.
_ex_base="$TMP/excl"; mkdir -p "$_ex_base"
for _ex_kind in dir file link; do
    _ex_path="$_ex_base/$_ex_kind"
    rm -rf "$_ex_path"
    # WITH CONTENTS, so their SURVIVAL can be asserted and not only the absence of
    # a write. A refusal before the `mkdir` created nothing, so it must remove
    # nothing — and a child-absence check alone passes just as well if the helper
    # deleted the whole argument, which is the opposite failure.
    case "$_ex_kind" in
        dir)  mkdir "$_ex_path"; printf 'DO NOT DELETE\n' > "$_ex_path/keepme" ;;
        file) printf 'DO NOT DELETE\n' > "$_ex_path" ;;
        link) mkdir -p "$_ex_base/linktarget"
              printf 'DO NOT DELETE\n' > "$_ex_base/linktarget/keepme"
              ln -s "$_ex_base/linktarget" "$_ex_path" ;;
    esac
    _ex_rc=0
    _ex_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" \
        GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$_ex_path" 2>&1 )" || _ex_rc=$?
    { [ "$_ex_rc" -ne 0 ] \
      && case "$_ex_diag" in *"could not create"*) true ;; *) false ;; esac; } \
        && pass "read refuses a transport directory that already exists as a $_ex_kind" \
        || die "an existing $_ex_kind was accepted as the transport directory (rc=$_ex_rc diag='$_ex_diag')"
    [ ! -e "$_ex_path/origin" ] \
        && pass "…and writes nothing through it" \
        || die "an existing $_ex_kind was written through"
    # …AND LEAVES IT WHERE IT WAS, which the child-absence check above cannot see:
    # a helper that deleted the argument outright satisfies it perfectly. The
    # refusal happens BEFORE the `mkdir`, so this script created nothing and must
    # remove nothing — a name somebody else got to first is theirs.
    case "$_ex_kind" in
        dir)  { [ -d "$_ex_path" ] && [ -s "$_ex_path/keepme" ]; } \
                  && pass "…and leaves the existing directory and its contents alone" \
                  || die "an existing directory or its contents were removed" ;;
        file) { [ -f "$_ex_path" ] && [ -s "$_ex_path" ]; } \
                  && pass "…and leaves the existing file alone" \
                  || die "an existing file was removed or truncated" ;;
        # A DEDICATED TARGET WITH A MARKER IN IT, because the symlink pointed at the
        # shared `$_ex_base` and the check asked only whether that still existed.
        # A regression that FOLLOWED the link and deleted entries inside the target,
        # leaving the link and the directory in place, passed — which is precisely
        # the write-through this case is here to refuse, and the "contents included"
        # half of the guarantee went unasserted for links alone.
        link) { [ -L "$_ex_path" ] && [ -d "$_ex_base/linktarget" ] \
                && [ -s "$_ex_base/linktarget/keepme" ]; } \
                  && pass "…and leaves the symlink, its target and the target's contents alone" \
                  || die "an existing symlink, its target or the target's contents were removed" ;;
    esac
done
# …AND THE ORDINARY CASE STILL CREATES IT, so the three above are not passing
# because every path is refused.
rm -rf "$_ex_base/fresh"
( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" \
    GIT_CONFIG_NOSYSTEM=1 /usr/bin/env bash -p "$SCRIPT" read "$_ex_base/fresh" ) >/dev/null 2>&1
[ "$(cat "$_ex_base/fresh/origin" 2>/dev/null)" = "$REAL" ] \
    && pass "…while a name nobody has taken is created and written" \
    || die "the ordinary create-and-write case failed"
# AND THE DIRECTORY IS PRIVATE, which is the other half of what the caller's
# `mkdir -m 700` used to do: `-m` is applied by `mkdir` itself, so there is no
# interval between the name existing and being closed.
_ex_mode="$(ls -ld "$_ex_base/fresh" 2>/dev/null | cut -c1-10)"
case "$_ex_mode" in
    drwx------) pass "…at mode 700, with no interval where it is not" ;;
    *)          die "the transport directory was created with mode '$_ex_mode'" ;;
esac

# ── AN OUTPUT THAT OPENS AND THEN REJECTS THE WRITE ────────────────────────
#
# BOTH WRITES STILL TAKE THEIR STATUS, and nothing here exercises it any more.
# That is a loss and it is recorded rather than quietly dropped.
#
# WHAT THE GUARDS ARE FOR: a target can open and then reject data. Without the
# status, `pin` leaves an empty file and exits 0 — byte-for-byte what a
# legitimately unset pin leaves — and `read` leaves an empty file and exits 0,
# which the caller reads back as an origin.
#
# WHY THE CASE IS GONE: it drove `/dev/full` in as the output PATH, and since #157
# the argument is a DIRECTORY this script creates. `mkdir /dev/full` refuses
# before any write is attempted, and there is no directory a fixture can make
# whose creation succeeds and whose writes then fail — that needs a full or
# quota'd filesystem, which is the same "making it fail means making it fail
# everywhere" this repository already records for heredoc temporary files.
#
# WHAT REPLACES IT IS A STRUCTURAL ASSERTION OVER BOTH WRITES, and that is
# weaker than running them — stated plainly, because the first version of this
# paragraph said `pr-selfcheck.sh` would not miss the guards' removal and that is
# simply untrue: it has no check for these writes, and every other case here
# drives a `printf` that succeeds, so deleting either `|| rb_refuse` left the
# whole suite green. A claim that a gap is covered elsewhere is worse than the
# gap, because it stops anyone looking.
#
# What the check can see is that each write still HAS a refusal attached, and that
# the refusal is `rb_refuse` rather than a bare `exit` — the difference being
# whether the directory this script created goes with it. Both are matched whole,
# with the redirection and the guard on one logical line, so a guard moved onto a
# line of its own or replaced with `|| true` fails here.
_wr_n=0
_wr_n="$(grep -c '> "\$OUT" *\\$' "$SCRIPT")" || _wr_n=0
[ "$_wr_n" = 2 ] \
    && pass "both transport writes are continued onto their guard" \
    || die "expected two guarded writes in the helper, found $_wr_n"
_wr_g=0
_wr_g="$(grep -c '^ *|| rb_refuse "ABORT: could not create .\$OUT. exclusively and write' "$SCRIPT")" || _wr_g=0
[ "$_wr_g" = 2 ] \
    && pass "…and each takes its status through rb_refuse, so a failed write removes the directory too" \
    || die "expected two rb_refuse guards on the writes, found $_wr_g"

# ── THE NAME IS RESERVED BEFORE THE WALKS, NOT AFTER THEM ──────────────────
#
# The candidate is an argv entry, which `ps` and `/proc` publish to every account
# on the machine the moment this process starts. With the `mkdir` after both
# ancestry walks, another local account on a shared sticky parent could read it and
# create the name while those walks ran; `mkdir` then refused, repeatably, for as
# long as they watched. The random suffix stops a name being GUESSED and does
# nothing about one being READ.
#
# ASSERTED ON THE ORDER IN THE SOURCE, because the race is a race: staging it means
# winning a window this fixture cannot make deterministic. What CAN be checked is
# that the create precedes the walks, which is the property that closes it — and
# that a walk refusal after the create still removes the directory, which the case
# below the exclusions already proves behaviourally.
_res_mk=0; _res_mk="$(grep -n 'env mkdir -m 700 "\$RB_DIR"' "$SCRIPT" | head -1 | cut -d: -f1)" || _res_mk=0
_res_w1=0; _res_w1="$(grep -n '^_rb_walk "\$_rb_dir"' "$SCRIPT" | head -1 | cut -d: -f1)" || _res_w1=0
{ [ "$_res_mk" -gt 0 ] && [ "$_res_w1" -gt 0 ] && [ "$_res_mk" -lt "$_res_w1" ]; } \
    && pass "the transport directory is reserved before the ancestry walks run" \
    || die "the mkdir does not precede the walks (mkdir=$_res_mk walk=$_res_w1); the name is observable while they run"
# …AND THE WALKS STILL REFUSE AFTER IT, which is what makes reserving first safe
# rather than merely earlier. Both walk refusals go through `rb_refuse`, so the
# reservation is given back.
_res_g=0; _res_g="$(grep -c '_rb_walk "\$_rb_\(dir\|real\)" || rb_refuse$' "$SCRIPT")" || _res_g=0
[ "$_res_g" = 2 ] \
    && pass "…and both walk refusals give the reservation back through rb_refuse" \
    || die "expected both walks to refuse through rb_refuse, found $_res_g"

# ── AN ALLOCATION THAT FAILS ABANDONS THE CALL, RATHER THAN AIMING AT `/` ──
#
# `die` records a failure and returns, so a `die` with nothing after it left `run`
# carrying on with an empty parent and `vd=/dir`. Under a root-run fixture that
# creates `/dir/origin` outside `$TMP`, and every later case collides with it.
#
# RUN IN A SUBSHELL WITH ITS OWN `die`, so exercising the failure does not record
# one: the point is what `run` DOES next, not that the allocation failed.
#
# AND THE INVOCATION IS RECORDED UNDER `$TMP`, not asked of the filesystem root.
# `[ ! -e /dir ]` was the first shape and it made the case HOST-DEPENDENT: a
# machine with a legitimate `/dir` failed it against code that returned before
# invoking anything. `run` reaches the helper through `env`, which is a name, so a
# function by that name logs what it was asked to run and refuses — and the
# assertion is that this case's own log was never written.
rm -f "$TMP/alloccalls"
_alloc_out="$( { mktemp() { return 1; }
                 env() { printf '%s\n' "$*" >> "$TMP/alloccalls"; return 1; }
                 die() { printf 'DIED[%s]\n' "$1" >&2; }   # stderr, or it lands IN the value
                 _r=0
                 _v="$(run read)" || _r=$?
                 printf 'RC=%s VALUE=[%s]\n' "$_r" "$_v"
               } 2>&1 )"
case "$_alloc_out" in
    *DIED*) pass "a failed scratch allocation is recorded" ;;
    *)      die "a failed scratch allocation was not recorded: '$_alloc_out'" ;;
esac
case "$_alloc_out" in
    *'RC=1 VALUE=[]'*) pass "…and the call is abandoned rather than continuing with an empty parent" ;;
    *)                 die "run continued past a failed allocation: '$_alloc_out'" ;;
esac
[ ! -e "$TMP/alloccalls" ] \
    && pass "…so the helper is never invoked, and nothing is aimed at /dir" \
    || die "a failed allocation still reached the helper: '$(cat "$TMP/alloccalls")'"

# ── A REFUSAL AFTER THE DIRECTORY EXISTS TAKES THE DIRECTORY WITH IT ───────
#
# Since #157 this script creates the transport directory, so every refusal PAST
# that `mkdir` — the git read, an empty origin, a newline in it, a failed write —
# owns something nothing else will collect. `rb_refuse` is what removes it, and
# nothing observed the directory after such a failure: the cases above assert
# status and output, and each `run` now takes a fresh name, so removing the
# `rmdir` from `rb_refuse` left every one of them green while each refused read
# leaked a `watch-pr.*` directory into the operator's `TMPDIR` for the life of the
# machine.
#
# SELF-CONTAINED, AND NOT THROUGH `run`. The assertion is about the DIRECTORY, and
# `run` builds its name inside a command substitution where this shell cannot see
# it. The failure is staged by running the helper from a directory that is not a
# git checkout, so `git remote get-url origin` fails on its own — a forged `git`
# would not do it, because `bash -p` is what stops an imported function being seen
# at all, which is the property half this file exists to prove.
_leak_dir="$TMP/leak.$$.$RANDOM$RANDOM"
mkdir -p "$TMP/notarepo"
_leak_rc=0
_leak_out="$(cd "$TMP/notarepo" && run_limited 20 env HOME="$TMP/nohome" \
    XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 \
    /usr/bin/env bash -p "$SCRIPT" read "$_leak_dir" 2>&1)" || _leak_rc=$?
# THE REFUSAL FIRST, or the absence below means the directory was never made and
# the case passes against a script that cannot create one at all.
{ [ "$_leak_rc" -ne 0 ] && printf '%s' "$_leak_out" | grep -qF 'could not read origin'; } \
    && pass "a read outside a checkout is refused after the directory exists" \
    || die "the post-mkdir refusal case did not refuse (rc=$_leak_rc out='$_leak_out')"
[ ! -e "$_leak_dir" ] \
    && pass "…and the directory it created is gone, not left for nobody to collect" \
    || die "a refusal after the mkdir leaked '$_leak_dir' ($(ls -A "$_leak_dir" 2>&1))"
# AND THE ORDINARY READ STILL LEAVES THE DIRECTORY FOR ITS CALLER, which is the
# other half: a script that removed the directory on every path would satisfy the
# line above and hand back nothing to read.
_keep_dir="$TMP/keep.$$.$RANDOM$RANDOM"
_keep_rc=0
_keep_out="$(cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" \
    XDG_CONFIG_HOME="$TMP/nohome" GIT_CONFIG_NOSYSTEM=1 \
    /usr/bin/env bash -p "$SCRIPT" read "$_keep_dir" 2>&1)" || _keep_rc=$?
{ [ "$_keep_rc" -eq 0 ] && [ -s "$_keep_dir/origin" ]; } \
    && pass "…while a successful read leaves the directory and its file for the caller" \
    || die "a successful read left nothing to read (rc=$_keep_rc out='$_keep_out')"
rm -rf "$_keep_dir" "$TMP/notarepo"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
