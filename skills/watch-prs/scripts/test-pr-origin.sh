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
    local vf="$TMP/value.out" diag
    # REMOVED, NOT TRUNCATED. The helper creates its output with `set -C`, which
    # is O_EXCL — a pre-created file is refused, symlink or not, and that is the
    # point of it. A caller hands over a path in a directory it just made; it does
    # not hand over a file. Truncating here made every case in this file fail with
    # `cannot overwrite existing file`, which is the contract working.
    rm -f "$vf"
    # A CONTROLLED `HOME`, so these cases do not read the contributor's git
    # config. The helper carries `HOME` through on purpose — global
    # `url.<base>.insteadOf` rules are part of what `git remote get-url` answers —
    # and a contributor with a rule matching `git@github.com:` would see every
    # ordinary case here return the rewritten URL instead of `$REAL`, failing the
    # suite for a reason that has nothing to do with the subject. The dedicated
    # `IOHOME` case below tests rewrites deliberately, with its own `HOME`.
    diag="$(cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" \
        "$@" /usr/bin/env bash -p "$SCRIPT" "$mode" "$vf" 2>&1)" || rc=$?
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
rm -f "$TMP/pin.value"
run_limited 20 env -u REVIEW_BUS_REMOTE HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" pin "$TMP/pin.value" >/dev/null 2>&1; pin_rc=$?
pin_out="$(<"$TMP/pin.value")"
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
rm -f "$TMP/v"; out="$(cd "$BARE" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$TMP/v" 2>&1)"; rc=$?
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
rm -f "$TMP/v"; out="$(cd "$NOTREPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$TMP/v" 2>&1)"; rc=$?
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
rm -f "$TMP/v"; out="$(cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" PATH="$STUB:$PATH" /usr/bin/env bash -p "$SCRIPT" read "$TMP/v" 2>&1)"; rc=$?
out="$(<"$TMP/v")$out"
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
rm -f "$TMP/v"; out="$(cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" PATH="$STUB:$PATH" /usr/bin/env bash -p "$SCRIPT" read "$TMP/v" 2>&1)"; rc=$?
out="$(<"$TMP/v")$out"
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
rm -f "$TMP/v"; out="$(cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" PATH="$STUB:$PATH" /usr/bin/env bash -p "$SCRIPT" read "$TMP/v" 2>&1)"; rc=$?
out="$(<"$TMP/v")$out"
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'newline'; } \
    && pass "a trailing data newline is refused, not stripped into a valid slug" \
    || die "a trailing data newline gave rc=$rc '$out'"
# …AND PLAIN COMMAND SUBSTITUTION WOULD HAVE ACCEPTED IT, which is what makes the
# sentinel load-bearing rather than decorative.
naive="$(cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" PATH="$STUB:$PATH" bash -c 'git remote get-url origin' 2>&1)" || true
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
rm -f "$TMP/tr.value"
/usr/bin/env bash -p "$SCRIPT" read "$TMP/tr.value" || printf 'CALL_FAILED\n' >&2
printf 'VALUE=%s\n' "\$(<"$TMP/tr.value")" >&2
TRSH
for _fd in 1 9; do
    tr_out="$(run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" SHELLOPTS=xtrace BASH_XTRACEFD="$_fd" bash "$TMP/tr.sh" \
        9>>"$TMP/tr.trace" 2>&1 >/dev/null)" || true
    case "$tr_out" in
        *"VALUE=$REAL"*) pass "a caller tracing to fd $_fd gets the value alone" ;;
        *)               die "tracing to fd $_fd reached the value: '$tr_out'" ;;
    esac
done
# …AND THE TRACING IS PROVED TO BE ON, or both cases pass on runs never traced.
tprobe="$(run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c ':' 2>&1)" || true
case "$tprobe" in
    *'+ :'*) pass "…and the exported xtrace does trace an ordinary child" ;;
    *)       die "the xtrace never took effect, so the cases above prove nothing: '$tprobe'" ;;
esac

# ── A `bash` FUNCTION IN THE CALLER CANNOT STAND IN FOR THE INTERPRETER ────
#
# The call says `/usr/bin/env bash -p` because `bash -p` alone is a NAME: a
# function called `bash` runs instead, and it can write the value file itself and
# return without the subject running at all.
rm -f "$TMP/fn.value"
run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" bash -c '
    bash() { printf "%s\n" "'"$FORGED"'" > "'"$TMP/fn.value"'"; return 0; }
    cd "'"$REPO"'" || exit 1
    /usr/bin/env bash -p "'"$SCRIPT"'" read "'"$TMP/fn.value"'"' >/dev/null 2>&1 || true
[ "$(<"$TMP/fn.value")" = "$REAL" ] \
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
# THE HOOK WRITES THE VALUE FILE, whose path it can see as `$2` — it is sourced
# inside the script's own shell, so the script's arguments are its arguments.
printf "printf '%%s\\n' '%s' > \"\$2\"\nexit 0\n" "$FORGED" > "$TMP/hook-direct.sh"
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
rm -f "$TMP/unprot.value"
( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" BASH_ENV="$TMP/hook-direct.sh" \
    /usr/bin/env bash "$SCRIPT" read "$TMP/unprot.value" ) >/dev/null 2>&1 || true
unprot=""
[ -f "$TMP/unprot.value" ] && unprot="$(<"$TMP/unprot.value")"
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
sym_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$SYMDIR/out" 2>&1 )" || sym_rc=$?
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
plain_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$SYMDIR/plain" 2>&1 )" || plain_rc=$?
{ [ "$plain_rc" -ne 0 ] && [ "$(cat "$SYMDIR/plain")" = STALE ]; } \
    && pass "…and a path that already exists is refused rather than truncated" \
    || die "an existing output was truncated (rc=$plain_rc)"
# …AND THE OBJECT IT DOES CREATE IS PRIVATE. O_EXCL says who may replace it; the
# mode says who may write it once it is there.
rm -f "$TMP/modecheck.marker"
rm -f "$TMP/modecheck"
( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$TMP/modecheck" ) >/dev/null 2>&1
mode="$(ls -l "$TMP/modecheck" 2>/dev/null | cut -c1-10)"
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
rm -f "$TMP/io.value"
( cd "$IOREPO" && run_limited 20 env HOME="$IOHOME" /usr/bin/env bash -p "$SCRIPT" read "$TMP/io.value" ) >/dev/null 2>&1
io_got="$(cat "$TMP/io.value" 2>/dev/null)"
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
rm -f "$TMP/io2.value"
( cd "$IOREPO" && run_limited 20 env HOME="$IOHOME" GIT_DIR="$IOOTHER/.git" \
    /usr/bin/env bash -p "$SCRIPT" read "$TMP/io2.value" ) >/dev/null 2>&1
io2_got="$(cat "$TMP/io2.value" 2>/dev/null)"
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
open_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$OPENDIR/origin" 2>&1 )" || open_rc=$?
{ [ "$open_rc" -ne 0 ] \
  && case "$open_diag" in *"could be replaced between this write"*) true ;; *) false ;; esac \
  && [ ! -e "$OPENDIR/origin" ]; } \
    && pass "a transport directory other accounts can write is refused" \
    || die "the helper wrote into a world-writable directory (rc=$open_rc diag='$open_diag')"
# …AND A GROUP-WRITABLE ONE TOO, which is the shape a shared machine actually has.
chmod 770 "$OPENDIR"
open_rc=0
open_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$OPENDIR/origin" 2>&1 )" || open_rc=$?
{ [ "$open_rc" -ne 0 ] \
  && case "$open_diag" in *"could be replaced between this write"*) true ;; *) false ;; esac; } \
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
anc_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$ANCESTOR/mid/leaf/origin" 2>&1 )" || anc_rc=$?
{ [ "$anc_rc" -ne 0 ] \
  && case "$anc_diag" in *"could be replaced between this write"*) true ;; *) false ;; esac \
  && [ ! -e "$ANCESTOR/mid/leaf/origin" ]; } \
    && pass "…and a writable ANCESTOR is refused, not just the directory itself" \
    || die "an ancestor that can rename the transport directory was accepted (rc=$anc_rc diag='$anc_diag')"
# …WHILE STICKY IS ACCEPTED, which is why `/tmp` still works: anyone may create an
# entry there and nobody may rename another account's. Without this the check
# would refuse the directory it was written for.
chmod 1777 "$ANCESTOR/mid"
rm -f "$ANCESTOR/mid/leaf/origin"
( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$ANCESTOR/mid/leaf/origin" ) >/dev/null 2>&1
[ "$(cat "$ANCESTOR/mid/leaf/origin" 2>/dev/null)" = "$REAL" ] \
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
    foreign_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$FOREIGN/origin" 2>&1 )" || foreign_rc=$?
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
    link_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$LINKDIR/t/origin" 2>&1 )" || link_rc=$?
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
rm -f "$OPENDIR/origin"
( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$SAFELINK/t/origin" ) >/dev/null 2>&1
[ "$(cat "$OPENDIR/origin" 2>/dev/null)" = "$REAL" ] \
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
        acl_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$ACLDIR/origin" 2>&1 )" || acl_rc=$?
        { [ "$acl_rc" -ne 0 ] \
          && case "$acl_diag" in *"access-control list"*) true ;; *) false ;; esac \
          && [ ! -e "$ACLDIR/origin" ]; } \
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
xa_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" PATH="$XASTUB:$PATH" \
    /usr/bin/env bash -p "$SCRIPT" read "$XADIR/origin" 2>&1 )" || xa_rc=$?
{ [ "$xa_rc" -ne 0 ] \
  && case "$xa_diag" in *"access-control list or extended attributes"*) true ;; *) false ;; esac \
  && [ ! -e "$XADIR/origin" ]; } \
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
rm -f "$OPENDIR/origin"
chmod 700 "$OPENDIR"
lsf_rc=0
lsf_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" PATH="$LSFAIL:$PATH" \
    /usr/bin/env bash -p "$SCRIPT" read "$OPENDIR/origin" 2>&1 )" || lsf_rc=$?
{ [ "$lsf_rc" -ne 0 ] \
  && case "$lsf_diag" in *"could not read the permissions"*) true ;; *) false ;; esac \
  && [ ! -e "$OPENDIR/origin" ]; } \
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
rm -f "$OPENDIR/origin"
probe_rc=0
probe_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" PATH="$FINDSTUB:$PATH" \
    /usr/bin/env bash -p "$SCRIPT" read "$OPENDIR/origin" 2>&1 )" || probe_rc=$?
{ [ "$probe_rc" -ne 0 ] \
  && case "$probe_diag" in *"could not examine"*) true ;; *) false ;; esac \
  && [ ! -e "$OPENDIR/origin" ]; } \
    && pass "…and a probe that cannot run refuses rather than reading empty as safe" \
    || die "a failing probe was treated as a clean result (rc=$probe_rc diag='$probe_diag')"

# …WHILE A PRIVATE ONE IS THE ORDINARY CASE, or this would refuse every session.
chmod 700 "$OPENDIR"
rm -f "$OPENDIR/origin"
( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read "$OPENDIR/origin" ) >/dev/null 2>&1
[ "$(cat "$OPENDIR/origin" 2>/dev/null)" = "$REAL" ] \
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
reach="$(cd "$REPO" && env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" GIT_DIR="$OTHER/.git" git remote get-url origin 2>/dev/null)"
[ "$reach" = "$FORGED" ] \
    && pass "…where the same GIT_DIR redirects a bare git" \
    || die "GIT_DIR does not redirect git here (got '$reach'); the case above proves nothing"
# …AND `GIT_CONFIG_GLOBAL` IS NOT A SECOND LIST ENTRY TO ADD LATER. `env -i`
# clears whatever git reads, so a variable nobody enumerated is cleared too. This
# one is checked because it reaches the same answer by a different file.
cat > "$TMP/forged-config" <<CFG
[remote "origin"]
	url = $FORGED
CFG
got="$(run read "GIT_CONFIG_GLOBAL=$TMP/forged-config")"
{ [ "${got%%|*}" = 0 ] && [ "${got#*|}" = "$REAL" ]; } \
    && pass "…and a forged GIT_CONFIG_GLOBAL does not reach it either" \
    || die "GIT_CONFIG_GLOBAL reached the read: '${got}'"

# ── AN OUTPUT THAT OPENS AND THEN REJECTS THE WRITE ────────────────────────
#
# Both writes take their status, and until now nothing exercised the state that
# distinguishes taking it from not. The truncation succeeds — `/dev/full` opens
# and accepts `: >` — so the script reaches its `printf` believing the target is
# usable, and only the write fails. Without the status, `pin` leaves an empty file
# and exits 0, which is byte-for-byte what a legitimately unset pin leaves, and
# `read` leaves an empty file and exits 0, which the caller reads back as an
# origin. A refactor that dropped either guard would keep every other case here
# green.
#
# `/dev/full` IS A LINUX DEVICE and stock macOS does not have it, so its absence
# is announced rather than passed over: a case that quietly does not run is the
# green tick this repository has paid for twice.
if [ -c /dev/full ] && [ -w /dev/full ]; then
    _full_rc=0
    _full_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" /usr/bin/env bash -p "$SCRIPT" read /dev/full 2>&1 )" \
        || _full_rc=$?
    { [ "$_full_rc" -ne 0 ] \
      && case "$_full_diag" in *"write the origin"*) true ;; *) false ;; esac; } \
        && pass "read refuses an output that opens and then rejects the write" \
        || die "read accepted a rejected write (rc=$_full_rc diag='$_full_diag')"

    _full_rc=0
    _full_diag="$( cd "$REPO" && run_limited 20 env HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/nohome" REVIEW_BUS_REMOTE="$REAL" \
        /usr/bin/env bash -p "$SCRIPT" pin /dev/full 2>&1 )" || _full_rc=$?
    { [ "$_full_rc" -ne 0 ] \
      && case "$_full_diag" in *"write the pin"*) true ;; *) false ;; esac; } \
        && pass "…and pin refuses it too, rather than reporting an unset pin" \
        || die "pin reported success on a rejected write (rc=$_full_rc diag='$_full_diag')"
else
    echo "NOTE: /dev/full is absent; the rejecting-write cases did not run"
fi

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
