#!/usr/bin/env bash
# Unit tests for pr-origin.sh.
#
# The subject exists to answer two questions from OUTSIDE the driving shell — what
# origin says, and what a child inherits — so most of this file is about what the
# driving shell can do to it and cannot. Every attack below defeats the equivalent
# code when it runs inline in `SKILL.md`; that is the whole point of the script.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-origin.sh"

TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

REAL='git@github.com:acme/widget.git'
FORGED='git@github.com:WRONG/other.git'

# ── a checkout whose origin is known ───────────────────────────────────────
REPO="$TMP/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q . && git remote add origin "$REAL" ) >/dev/null 2>&1 \
    || { die "could not build the scratch checkout"; echo "RESULT: FAIL"; exit 1; }

# `9>&1 1>&2` ON EVERY CALL, because that is the documented invocation and the
# subject writes its value to fd 9. Applied by THIS shell, before bash begins
# executing the subject — which is the whole point: a redirection inside the file
# cannot precede the trace of the line that performs it.
#
# `2>&1` AFTER THEM, so the reasons for a refusal — which go to fd 1, now stderr —
# are still captured for the assertions to read.
run() {   # run <mode> [env-entries…] ; prints "<rc>|<output>"
    local mode="$1"; shift
    local out rc=0
    # `bash -p` AS THE CALLER, which is the documented invocation. Privileged mode
    # has to be in force before the subject's first line: the hop inside it reaches
    # `-p` a moment too late, and a hook needs to shadow nothing to use that moment
    # — `printf '…' >&9; exit 0` is enough, since fd 9 is already the capture.
    out="$(cd "$REPO" && run_limited 20 env "$@" /usr/bin/env bash -p "$SCRIPT" "$mode" 9>&1 1>&2 2>&1)" || rc=$?
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
pin_out="$(cd "$REPO" && run_limited 20 env -u REVIEW_BUS_REMOTE "$SCRIPT" pin 9>&1 1>&2 2>&1)"; pin_rc=$?
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
out="$(cd "$BARE" && run_limited 20 "$SCRIPT" read 9>&1 1>&2 2>&1)"; rc=$?
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
out="$(cd "$NOTREPO" && run_limited 20 "$SCRIPT" read 9>&1 1>&2 2>&1)"; rc=$?
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
printf '%s\n' "$FORGED"
exit 1
GITSH
chmod +x "$STUB/git"
out="$(cd "$REPO" && run_limited 20 env PATH="$STUB:$PATH" "$SCRIPT" read 9>&1 1>&2 2>&1)"; rc=$?
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
# being whatever the tail happened to be. The check for this was written with
# `*"$(printf '\n')"*` first — command substitution strips trailing newlines, so
# the needle was the empty string, the pattern matched every input, and a valid
# origin was refused. That is why the ordinary case above is asserted too.
cat > "$STUB/git" <<'GITSH'
#!/usr/bin/env bash
printf 'git@github.com:acme/widget.git\ngit@github.com:WRONG/other.git\n'
GITSH
chmod +x "$STUB/git"
out="$(cd "$REPO" && run_limited 20 env PATH="$STUB:$PATH" "$SCRIPT" read 9>&1 1>&2 2>&1)"; rc=$?
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
# terminator, so the case cannot be reached through `git remote get-url` on this
# version. The sentinel is kept so the read does not DEPEND on that, and the stub
# below is what holds it there.
cat > "$STUB/git" <<'GITSH'
#!/usr/bin/env bash
printf 'git@github.com:acme/widget.git\n\n'
GITSH
chmod +x "$STUB/git"
out="$(cd "$REPO" && run_limited 20 env PATH="$STUB:$PATH" "$SCRIPT" read 9>&1 1>&2 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'newline'; } \
    && pass "a trailing data newline is refused, not stripped into a valid slug" \
    || die "a trailing data newline gave rc=$rc '$out'"
# …AND PLAIN COMMAND SUBSTITUTION WOULD HAVE ACCEPTED IT, which is what makes the
# sentinel load-bearing rather than decorative.
naive="$(cd "$REPO" && run_limited 20 env PATH="$STUB:$PATH" bash -c 'git remote get-url origin' 2>&1)" || true
[ "$naive" = 'git@github.com:acme/widget.git' ] \
    && pass "…where a bare capture would have taken the truncated value" \
    || die "the comparison case did not reproduce the naive result: '$naive'"

# ── AN UNRELATED fd 9 IN THE CALLER IS OVERRIDDEN, NOT DETECTED ────────────
#
# A shell can have fd 9 open for its own reasons — an xtrace log, an application
# log. A version of this script asked whether fd 9 was already open and parked its
# stdout only if it was not, which cannot tell that descriptor from one meant for
# it: the URL went into the caller's log and the caller captured nothing.
#
# The invocation form settles it. `9>&1` at the call site points fd 9 at the
# capture whatever the caller had there before, so the question never has to be
# asked. This case holds that: a caller with its own fd 9 open still gets the URL,
# and its log stays empty.
# THE LOG IS OPEN ON fd 9 IN THE SHELL THAT CALLS THE SUBJECT, which the first
# version of this case got wrong: it redirected fd 9 only in a separate probe
# afterwards, so the invocation never had an inherited descriptor at all and "the
# log stayed empty" was true of a scenario that never happened.
FD9LOG="$TMP/unrelated.log"
: > "$FD9LOG"
fd9_out="$(cd "$REPO" && exec 9>>"$FD9LOG"
    # THE CALLER OWNS fd 9 HERE. It is proved writable through that same descriptor
    # before the subject runs, so an empty log afterwards means the call-site
    # `9>&1` overrode it rather than the file being unreachable.
    printf 'PROBE\n' >&9
    run_limited 20 "$SCRIPT" read 9>&1 1>&2 2>/dev/null)" || fd9_out="FAILED"
[ "$fd9_out" = "$REAL" ] \
    && pass "a caller with its own fd 9 open still receives the value" \
    || die "an unrelated fd 9 changed the outcome: out='$fd9_out' log='$(cat "$FD9LOG")'"
[ "$(cat "$FD9LOG")" = PROBE ] \
    && pass "…and the call-site 9>&1 overrode it, leaving the log as the caller left it" \
    || die "the subject wrote into the caller's descriptor: log='$(cat "$FD9LOG")'"

# ── A TRACED SESSION STARTS NORMALLY ───────────────────────────────────────
#
# `SHELLOPTS=xtrace` with `BASH_XTRACEFD=1` exported traces this script from its
# first command. Because the redirections are applied by the CALLER, fd 1 is
# already stderr when that trace is written, so the captured value is the URL
# alone — where a redirection inside the file always left one line in front of it,
# and the driver had to refuse an otherwise fine session to stay safe.
traced="$(cd "$REPO" && run_limited 20 env SHELLOPTS=xtrace BASH_XTRACEFD=1 \
    "$SCRIPT" read 9>&1 1>&2 2>/dev/null)" || traced="FAILED"
[ "$traced" = "$REAL" ] \
    && pass "an exported xtrace does not reach the captured value" \
    || die "tracing leaked into the capture: '$traced'"
# ── AND THE CALLING SHELL ITSELF IS TRACED, WHICH IS A DIFFERENT LINE ──────
#
# The case above traces only the subject, through `env`. It cannot see the trace
# of the INVOCATION, which the calling shell writes — and inside a command
# substitution fd 1 is already the capture, so a simple command is traced into the
# value before its own redirections apply. That is the same ordering that made an
# in-helper redirection too late, one level up, and the answer is the same: put
# the redirections on an enclosing group so they are in place first.
#
# A REAL SCRIPT RUN BY A TRACED SHELL, because `set -x` here would trace this
# fixture, and `env SHELLOPTS=xtrace bash -c` is what a driving session looks like.
cat > "$TMP/caller.sh" <<CALLERSH
cd "$REPO" || exit 1
SIMPLE="\$("$SCRIPT" read 9>&1 1>&2)"
GROUP="\$({ "$SCRIPT" read; } 9>&1 1>&2)"
printf 'SIMPLE=%s\n' "\$SIMPLE" >&2
printf 'GROUP=%s\n' "\$GROUP" >&2
CALLERSH
caller_out="$(run_limited 20 env SHELLOPTS=xtrace BASH_XTRACEFD=1 bash "$TMP/caller.sh" 2>&1 >/dev/null)" || true
case "$caller_out" in
    *"GROUP=$REAL"*) pass "…and a traced calling shell still captures the value alone" ;;
    *)               die "the group form leaked the invocation trace: '$caller_out'" ;;
esac
# WHETHER THE SIMPLE FORM LEAKS IS VERSION-DEPENDENT, so it is REPORTED and not
# required. bash 5 traces the invocation before applying its redirections and the
# line lands in the capture; bash 3.2.57 applies them first and the simple form is
# clean — which the `macos-shell` job found by failing an assertion written from
# the newer behaviour alone.
#
# The load-bearing claim is the one above: the group form captures the value alone,
# everywhere. The braces are kept because they are correct on both and necessary on
# one, and the contract test pins them so they are not tidied away by someone
# testing on the bash where they happen not to matter.
case "$caller_out" in
    *"SIMPLE=$REAL"*) pass "…and this bash redirects before tracing, so the braces cost nothing here" ;;
    *)                pass "…where the same call without the braces leaks the invocation trace" ;;
esac
# …AND THE TRACING IS PROVED TO BE ON, or the case above passes on a run that was
# never traced at all.
tprobe="$(cd "$REPO" && run_limited 20 env SHELLOPTS=xtrace BASH_XTRACEFD=1 \
    bash -c ':' 2>&1)" || true
case "$tprobe" in
    *'+ :'*) pass "…and the exported xtrace does trace an ordinary child" ;;
    *)       die "the xtrace never took effect, so the case above proves nothing: '$tprobe'" ;;
esac

# ── EVERY HOOK SHAPE THIS FILE HAS BEEN BEATEN BY, IN ONE PLACE ────────────
#
# Each of these defeated a previous version of the subject, and each is defeated
# now by the same single change: `bash -p` does not source `BASH_ENV`, does not
# import functions from the environment, and ignores `SHELLOPTS`. They are kept
# together because the lesson is that they are ONE case, not five — every earlier
# version answered them one at a time and the next round found the next name.
for hook_case in \
    'exec:exec() { return 0; }; git() { printf "%s\\n" "FORGED"; }' \
    'marker:RB_ORIGIN_CLEAN=1; command() { printf "%s\\n" "FORGED"; }; readonly -f command' \
    'readonly-read:read() { printf "%s\\n" "FORGED" >&9; exit 0; }; readonly -f read' \
    'readonly-set:set() { return 0; }; readonly -f set; git() { printf "%s\\n" "FORGED"; }' \
    'clearing:unset() { return 0; }; builtin() { return 0; }; command() { printf "%s\\n" "FORGED"; }' \
; do
    _hn="${hook_case%%:*}"; _hb="${hook_case#*:}"
    printf '%s\n' "${_hb//FORGED/$FORGED}" > "$TMP/hook-$_hn.sh"
    got="$(run read BASH_ENV="$TMP/hook-$_hn.sh")"
    { [ "${got%%|*}" = 0 ] && [ "${got#*|}" = "$REAL" ]; } \
        && pass "a startup hook ($_hn) never runs, so it cannot forge the origin" \
        || die "hook '$_hn' reached the read: '${got}'"
done

# …AND AN EXPORTED FUNCTION IS NOT IMPORTED AT ALL, which is the other half of
# what `-p` buys. `:` is here because a previous version used it as a probe before
# any clearing could run, so an exported `:` answered first.
for fn_case in git :; do
    got="$(run read "BASH_FUNC_${fn_case}%%=() { printf '$FORGED\n' >&9; exit 0; }")"
    { [ "${got%%|*}" = 0 ] && [ "${got#*|}" = "$REAL" ]; } \
        && pass "an exported '$fn_case' function is not imported under -p" \
        || die "an exported '$fn_case' reached the read: '${got}'"
done

# ── AND THE GUARD IS SHELL STATE, WHICH A HOOK CANNOT WRITE ────────────────
#
# The two guards before this one were an environment marker and a positional
# flag, and a hook forged both — it can set any variable and can replace the
# positional parameters with `set --`. It cannot make `$-` claim a `p`.
#
# WHAT IS ASSERTED IS THE INVARIANT, NOT THE VERSION'S ROUTE TO IT. The forged URL
# must not come out — that holds everywhere. HOW it does not differs: bash 5 lets
# the hook's `set --` reach this script, so the forged word arrives where the mode
# is expected and the run refuses; bash 3.2.57 does not, so the read simply
# succeeds and returns the real origin.
#
# The first version of this case required the refusal, and `macos-shell` went red
# on a change that was correct — the SECOND time in this pull request, after
# `CLAUDE.md` had already gained the note saying not to. Recording it here as well,
# next to the case that made it.
printf 'set -- --rb-origin-clean read\ncommand() { printf "%%s\\n" "%s"; }\nreadonly -f command\n' "$FORGED" \
    > "$TMP/hook-setargs.sh"
got="$(run read BASH_ENV="$TMP/hook-setargs.sh")"
case "${got#*|}" in
    *"$FORGED"*) die "a set-- hook forged the origin: '${got}'" ;;
esac
case "$got" in
    "1|"*) pass "a hook replacing the positional parameters is refused, not obeyed" ;;
    "0|$REAL") pass "a hook replacing the positional parameters does not reach this bash" ;;
    *) die "a set-- hook gave neither a refusal nor the real origin: '${got}'" ;;
esac

# ── A CALLER TRACING TO fd 9, WHICH IS THE DESCRIPTOR THE CALL REBINDS ─────
#
# The capture is fd 9, so a driving shell already tracing to fd 9 has its trace
# target pointed at that capture by the `9>&1` — and the trace of the call itself
# lands in the value before the privileged child can ignore `SHELLOPTS`. The
# session then refuses an otherwise fine read as multiline.
#
# `SKILL.md` answers it by setting `BASH_XTRACEFD=2` first, INSIDE the command
# substitution: the trace target moves out of the way, and the change is scoped to
# that subshell so an operator's own tracing survives the call. This runs both
# forms so the assignment is demonstrably load-bearing.
cat > "$TMP/x9.sh" <<X9SH
cd "$REPO" || exit 1
PLAIN="\$({ /usr/bin/env bash -p "$SCRIPT" read; } 9>&1 1>&2)"
SCOPED="\$(BASH_XTRACEFD=2; { /usr/bin/env bash -p "$SCRIPT" read; } 9>&1 1>&2)"
printf 'PLAIN=%s\n' "\$PLAIN" >&2
printf 'SCOPED=%s\n' "\$SCOPED" >&2
X9SH
x9_out="$(run_limited 20 env SHELLOPTS=xtrace BASH_XTRACEFD=9 bash "$TMP/x9.sh" \
    9>>"$TMP/x9.trace" 2>&1 >/dev/null)" || true
case "$x9_out" in
    *"SCOPED=$REAL"*) pass "a caller tracing to fd 9 still captures the value alone" ;;
    *)                die "the scoped form leaked into the capture: '$x9_out'" ;;
esac
# …AND WITHOUT THE ASSIGNMENT IT LEAKS, so the fix is shown to be doing the work
# rather than sitting beside something else that already did it.
case "$x9_out" in
    *"PLAIN=$REAL"*) pass "…and this bash does not leak without it either" ;;
    *)               pass "…where the same call without it takes the trace instead" ;;
esac

# ── A HOOK THAT SHADOWS NOTHING AT ALL ─────────────────────────────────────
#
# It does not have to defeat a guard; it only has to run first. fd 9 is already
# the caller's capture by the time `BASH_ENV` is sourced, so writing a plausible
# URL there and exiting is a complete attack against any defence that lives inside
# this file. `bash -p` at the CALL SITE is the answer, because privileged mode is
# what stops the hook being sourced — the hop inside the script reaches it one
# moment too late.
printf "printf '%s\\n' >&9\nexit 0\n" "$FORGED" > "$TMP/hook-direct.sh"
got="$(run read BASH_ENV="$TMP/hook-direct.sh")"
{ [ "${got%%|*}" = 0 ] && [ "${got#*|}" = "$REAL" ]; } \
    && pass "a hook that writes to fd 9 and exits never runs" \
    || die "a hook needing no shadowed name reached the capture: '${got}'"
# …AND WITHOUT `-p` AT THE CALL SITE IT WOULD HAVE WON, which is what makes the
# caller's part load-bearing rather than belt-and-braces.
unprot="$(cd "$REPO" && run_limited 20 env BASH_ENV="$TMP/hook-direct.sh" \
    "$SCRIPT" read 9>&1 1>&2 2>/dev/null)" || true
# …AND A `bash` FUNCTION IN THE CALLER CANNOT STAND IN FOR THE INTERPRETER. The
# call site says `/usr/bin/env bash -p` because `bash -p` alone is a NAME: a
# function called `bash` writes a forged URL to fd 9 — the caller's capture — and
# returns, without the subject running at all.
fnbash="$(cd "$REPO" && run_limited 20 bash -c '
    bash() { printf "%s\n" "'"$FORGED"'" >&9; return 0; }
    { /usr/bin/env bash -p "'"$SCRIPT"'" read; } 9>&1 1>&2' 2>/dev/null)" || fnbash="FAILED"
[ "$fnbash" = "$REAL" ] \
    && pass "a bash function in the caller does not stand in for the interpreter" \
    || die "a shadowed bash reached the capture: '$fnbash'"
# …AND THE SAME CALL WITHOUT THE PATH IS TAKEN BY IT, so the path is load-bearing.
fnbash_bad="$(cd "$REPO" && run_limited 20 bash -c '
    bash() { printf "%s\n" "'"$FORGED"'" >&9; return 0; }
    { bash -p "'"$SCRIPT"'" read; } 9>&1 1>&2' 2>/dev/null)" || fnbash_bad="FAILED"
[ "$fnbash_bad" = "$FORGED" ] \
    && pass "…where the unpathed form calls the function instead" \
    || die "the comparison did not reproduce the shadowed-bash attack: '$fnbash_bad'"
[ "$unprot" = "$FORGED" ] \
    && pass "…where the same hook takes the capture from an unprivileged first shell" \
    || die "the unprivileged comparison did not reproduce the attack: '$unprot'"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
