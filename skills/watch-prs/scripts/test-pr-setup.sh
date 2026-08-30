#!/usr/bin/env bash
# Unit tests for pr-setup.sh.
#
# THE CONTRACT UNDER TEST: the caller starts it with `/usr/bin/env bash -p` and names a
# DIRECTORY that must not exist. The helper creates it exclusively at mode 700, reads
# the origin through `pr-origin.sh`, proves it parses, allocates `work/` and the four
# working files, and writes the origin into `<dir>/origin` — ONE VALUE, which the driver
# READS with `$(<…)`. Statuses: 0 ready, 1 stopped, 2 the storage would not take it,
# which is the only one the caller retries.
#
# IT USED TO HAND BACK TWELVE ASSIGNMENTS IN A FILE THE DRIVER SOURCED, and that is
# worth knowing here because half these cases were written against it. `.` is a name,
# and in the driving shell a function by that name could read the genuine assignments
# and hand back a different origin — after which everything agreed with it. Eleven of
# the twelve were never information: three the identity parser derives from the origin,
# two are constants, and the working paths are a literal suffix under a directory the
# driver named. So the transport is one value now, nothing the helper writes is
# evaluated, and the quoting that made a sourced line an assignment is gone with it.
#
# WHAT THIS FILE IS ABOUT, and what `test-pr-skill-contract.sh` is about, are two ends
# of one arrangement. The contract file runs the DRIVER's block against a forged helper:
# whether a refusal is walked past, whether the value is read rather than sourced,
# whether the pin is proved. This file runs the REAL helper: whether the directory is a
# reservation, whether a hostile origin comes back byte-exact, whether a refusal leaves
# anything behind. Neither can answer the other's question.
#
# THAT THE HELPER REMOVES NOTHING IS THE PART TO READ FIRST, and it is a contract rather
# than an omission. This directory's name is published in argv, so every removal shape
# resolves a name a same-UID process may have substituted in the meantime — and shell has
# no descriptor-relative removal to reach past that. `docs/decisions/2026-08-29-setup-leaf-cleanup.md`
# carries what each shape destroyed; several cases here exist to keep the no-removal
# contract true, and one counts the removals in the file itself.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-setup.sh"

# THIS FIXTURE'S SUBJECT READS THE CHECKOUT'S IDENTITY, so it clears the
# environment itself. `SKILL.md` pins the session by exporting `REVIEW_BUS_REMOTE`
# and the suite runs with that pin in the environment — `rb_identity` prefers it
# over the remote, so every case below would read the CONTRIBUTOR's repository
# rather than the scratch checkout it built. `pr-selfcheck.sh` cannot clear this:
# it deliberately does not clear arbitrary exported values, for exactly that pin's
# sake. It belongs in the file whose subject it is.
unset REVIEW_BUS_REMOTE REVIEW_BUS_OWNER REVIEW_BUS_REPO
for _n in ${!GIT_CONFIG_@}; do unset "$_n"; done
unset _n

TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# WHETHER THIS RUN CAN BE STOPPED BY A PERMISSION BIT AT ALL. Root bypasses the
# discretionary checks, so a `chmod 500` stage does not make a directory unwritable for
# it: the helper succeeds, the case reports a failure, and what failed is the STAGING
# rather than the subject. CI runs unprivileged, but a root container is a normal way to
# run a suite, and a fixture that goes red there against correct code is worse than one
# that says why it did not run — which is the shape this file already uses for
# `declare -l` and `declare -n`.
_rb_uid=1
_rb_uid="$(id -u 2>/dev/null)" || _rb_uid=1
if [ "$_rb_uid" = 0 ]; then
    pass "this run is UID 0, so the cases staged with a permission bit are skipped by name"
fi

REAL='git@github.com:acme/widget.git'

# ── a checkout whose origin is known ───────────────────────────────────────
REPO="$TMP/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q . && git remote add origin "$REAL" ) >/dev/null 2>&1 \
    || { die "could not build the scratch checkout"; echo "RESULT: FAIL"; exit 1; }

# A FRESH DIRECTORY NAME PER CALL, AND `mktemp` IS WHAT GIVES ONE. A path this
# fixture has already handed to one case is one `mkdir` refuses for the next —
# which is the contract working, and would make the second case fail for a reason
# that is not its subject. A counter cannot do it: `run` is called inside a command
# substitution, so the increment happens in a subshell. Nor can `$$`/`$RANDOM`: on
# bash 3.2.57 a subshell inherits the parent's random state unadvanced, so
# successive substitutions from the same parent produce the same value.
run() {   # run [env-entries…] -- [args…] ; prints "<rc>|<dir>|<output>"
    local out rc=0 vp vd
    local -a envs=() args=()
    local seen=0 a
    for a in "$@"; do
        if [ "$seen" = 0 ] && [ "$a" = -- ]; then seen=1; continue; fi
        if [ "$seen" = 0 ]; then envs+=("$a"); else args+=("$a"); fi
    done
    vp=""
    vp="$(mktemp -d "$TMP/run.XXXXXX")" || vp=""
    # AND THE ALLOCATION'S FAILURE STOPS THIS CALL. `die` records a failure and
    # RETURNS, so a `die` alone would leave `vp` empty and the call would go on to
    # name `/dir` — which a root-run fixture creates outside `$TMP`, after which
    # every later case collides with it and stops exercising its own state.
    if [ -z "$vp" ] || [ ! -d "$vp" ]; then
        die "mktemp could not allocate a scratch parent; this call is abandoned rather than aimed at /dir"
        printf '125||\n'
        return 1
    fi
    vd="$vp/dir"
    if [ "${#args[@]}" -eq 0 ]; then args=("$vd"); fi
    # `bash -p` AS THE CALLER, which is the documented invocation: privileged mode
    # has to be in force before the subject's first line, and only the caller can
    # arrange that — there is no hop inside the file and it is not executable.
    #
    # BOTH STREAMS JOINED, so one assertion can look at the ready line and the
    # reason together. The separation itself is asserted by its own case below.
    out="$(cd "$REPO" && run_limited 25 env "${envs[@]}" \
        /usr/bin/env bash -p "$SCRIPT" "${args[@]}" 2>&1)" || rc=$?
    printf '%s|%s|%s\n' "$rc" "$vd" "$out"
}
rc_of()  { printf '%s' "${1%%|*}"; }
dir_of() { local r="${1#*|}"; printf '%s' "${r%%|*}"; }
out_of() { local r="${1#*|}"; printf '%s' "${r#*|}"; }

# ── the ordinary run ───────────────────────────────────────────────────────
r="$(run --)"
ok_dir="$(dir_of "$r")"
{ [ "$(rc_of "$r")" = 0 ] \
  && case "$(out_of "$r")" in *"PR_SETUP status=ready origin=$ok_dir/origin work=$ok_dir/work"*) true ;; *) false ;; esac; } \
    && pass "a good checkout gives status=ready and names what it wrote" \
    || die "the ordinary run failed: '$r'"
# THE DIRECTORY SURVIVES THE CALL, which is the whole point of it: the caller
# reads the origin out of it and then uses `work/` for the rest of the session. A helper that
# cleaned up on success would be removing what it was asked to produce.
{ [ -d "$ok_dir" ] && [ -f "$ok_dir/origin" ]; } \
    && pass "…and the directory it made is left for the caller" \
    || die "the successful run did not leave its directory behind"
# AT MODE 700, because the file inside it carries the session's origin and the
# work files carry the round's account before it is posted.
_mode="$(ls -ld "$ok_dir" 2>/dev/null | cut -c1-10)" || _mode=""
case "$_mode" in
    drwx------) pass "…at mode 700, so nothing else on the machine reads the session's files" ;;
    *) die "the setup directory is $_mode, not drwx------" ;;
esac

# ── what the driver gets back ──────────────────────────────────────────────
# ONE VALUE, READ AS DATA. This wrote a file of twelve assignments the driver SOURCED,
# and `.` is a NAME — in the operator's long-lived shell a function by that name could
# hand back a different origin, after which the identity derivation and the child pin
# both agree with it because both are computed FROM it. Eleven of the twelve were
# never information: three the identity parser derives, two are constants, and the
# working paths are a literal suffix under a directory the driver named.
_got="$(cat "$ok_dir/origin" 2>/dev/null)" || _got="READ_FAILED"
[ "$_got" = "$REAL" ] \
    && pass "…and the origin it hands back is the remote of the checkout it read" \
    || die "the origin file does not carry the remote: '$_got'"
# RAW, NOT QUOTED, because nothing evaluates it. The quoting existed to make a sourced
# line an assignment rather than a command; with no source there is nothing to escape
# into safety, and a value that arrived escaped would be a value the driver has to
# unescape.
case "$_got" in
    *"'"*) die "the origin file carries quoting the driver would have to undo: '$_got'" ;;
    *) pass "…written raw, because the caller reads it rather than evaluating it" ;;
esac
# AND THE FOUR WORKING FILES EXIST AND ARE EMPTY. The driver builds their paths from a
# literal suffix under the directory it named, so what the helper owes it is the files
# themselves: the round summary must be EMPTY until the round writes it, or a first
# round whose summary write did not happen posts whatever was there.
_wf_bad=""
for _f in summary.md request.md prior.txt head.txt; do
    { [ -f "$ok_dir/work/$_f" ] && [ ! -s "$ok_dir/work/$_f" ]; } || _wf_bad="$_wf_bad $_f"
done
[ -z "$_wf_bad" ] \
    && pass "…and each working file is created as a file that exists and is empty" \
    || die "a working file is missing or not empty:$_wf_bad"
# AND THE WORK DIRECTORY IS WHERE THE DRIVER WILL LOOK, which is the one thing about
# it the helper must agree with: a literal `work` under the directory it was given.
[ -d "$ok_dir/work" ] \
    && pass "…under the literal the driver builds its paths from" \
    || die "the helper did not create work/ under the directory it was given"

# ── a hostile origin is a string ───────────────────────────────────────────
# EVERY SHAPE THAT USED TO NEED ESCAPING, against the real helper. While the driver
# SOURCED this file, a value carrying `\'`, a `$(…)` or a backtick had to be
# single-quoted into safety and the escape was load-bearing — one mistake in it was a
# command in the operator's shell. Nothing evaluates the value now, so what these
# cases assert is that it arrives BYTE-EXACT and that nothing ran on the way.
_inj_i=0
for _bad in \
    "git@github.com:acme/w'x.git" \
    'git@github.com:acme/w$(touch WITNESS)x.git' \
    'git@github.com:acme/w`touch WITNESS`x.git' \
    'git@github.com:acme/w;touch WITNESS;x.git' \
    'git@github.com:acme/w x"y'"'"'z.git' \
    'git@github.com:acme/w${IFS}x.git'
do
    _inj_i=$((_inj_i + 1))
    rm -f "$TMP/WITNESS"
    ( cd "$REPO" && git remote set-url origin "$_bad" ) 2>/dev/null \
        || { die "git would not hold the staged remote #$_inj_i"; continue; }
    r="$(run --)"
    _d="$(dir_of "$r")"
    if [ "$(rc_of "$r")" != 0 ]; then
        die "the helper refused a legal-if-hostile remote #$_inj_i: '$r'"
        continue
    fi
    _got="$(cat "$_d/origin" 2>/dev/null)" || _got="READ_FAILED"
    { [ "$_got" = "$_bad" ] && [ ! -e "$TMP/WITNESS" ]; } \
        && pass "a remote carrying #$_inj_i comes back byte-exact and executes nothing" \
        || die "remote #$_inj_i came back as '$_got' (witness-exists=$([ -e "$TMP/WITNESS" ] && echo yes || echo no))"
done
( cd "$REPO" && git remote set-url origin "$REAL" ) 2>/dev/null || true

# ── the directory is the reservation ───────────────────────────────────────
# `mkdir` WITHOUT `-p` IS THE EXCLUSION, so anything already at the name is a
# refusal rather than something written through — a file, a symlink, or another
# account's directory. A check-then-use here is a window somebody else can stand
# in, which is why there is no test before the create.
for _kind in dir file symlink; do
    _pre="$(mktemp -d "$TMP/pre.XXXXXX")"
    _t="$_pre/dir"
    case "$_kind" in
        dir)     mkdir "$_t"; : > "$_t/canary" ;;
        file)    : > "$_t" ;;
        symlink) mkdir "$_pre/elsewhere"; ln -s "$_pre/elsewhere" "$_t" ;;
    esac
    _o=0
    _oo="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$SCRIPT" "$_t" 2>&1)" || _o=$?
    { [ "$_o" -eq 2 ] \
      && case "$_oo" in *'reason=dir_not_reserved'*) true ;; *) false ;; esac; } \
        && pass "an existing $_kind at the name is refused with the storage status" \
        || die "an existing $_kind was not refused as a reservation failure (rc=$_o out='$_oo')"
    # AND NOTHING WAS WRITTEN THROUGH IT. The symlink case is the one that matters:
    # a helper that fell back to `mkdir -p` would follow it and allocate under a
    # directory the caller never named.
    #
    # THE DIRECTORY CASE ASKS WHAT IS IN THERE, not whether some named leaf is absent.
    # It named one, and a named leaf is a list: the name it held was the transport this
    # helper stopped writing, so a regression that allocated `origin`, `o` or `work`
    # inside a directory it never reserved passed the assertion with the canary intact.
    # `ls -A` returning exactly the canary needs no list and cannot go stale.
    case "$_kind" in
        dir)     { [ -f "$_t/canary" ] && [ "$(ls -A "$_t" 2>/dev/null)" = canary ]; } \
                     && pass "…and the directory that was there holds nothing but its canary" \
                     || die "the pre-existing directory was written into: $(ls -A "$_t" 2>/dev/null | tr '\n' ' ')" ;;
        symlink) { [ -L "$_t" ] && [ -z "$(ls -A "$_pre/elsewhere" 2>/dev/null)" ]; } \
                     && pass "…and the symlink's target is still empty" \
                     || die "the helper wrote through the symlink" ;;
        file)    [ ! -s "$_t" ] \
                     && pass "…and the file that was there is unchanged" \
                     || die "the pre-existing file was written to" ;;
    esac
    rm -rf "$_pre"
done

# ── the arguments ──────────────────────────────────────────────────────────
# EACH REFUSAL BY NAME, because the caller branches on the STATUS and an operator
# reads the reason: a run refused for the wrong reason sends them to the wrong
# place, and `1` versus `2` decides whether the driver retries at all.
_argcase() {   # _argcase <reason> <args…>
    local want="$1"; shift
    local o=0 oo
    oo="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$SCRIPT" "$@" 2>&1)" || o=$?
    { [ "$o" -eq 1 ] && case "$oo" in *"reason=$want"*) true ;; *) false ;; esac; } \
        && pass "…$want is refused terminally, by name" \
        || die "the $want case gave rc=$o '$oo'"
    return 0
}
_argcase bad_dir
_argcase dir_not_absolute rel/ative
_argcase bad_dir "$TMP/a/../b"
_argcase usage "$TMP/one" "$TMP/two"
# …AND AN ORDINARY FILESYSTEM CHARACTER IS NOT A REFUSAL. A character class was here
# and it was a regression: the driver builds this name under `$TMPDIR` or `$HOME`, an
# operator's home directory can contain a SPACE, and `bad_dir` is TERMINAL — so the
# second parent was never tried and the session ended on a path that works. Nothing
# evaluates the value; it is quoted in the `mkdir`, in every redirection and in every
# `printf`.
_sp="$TMP/parent with space"; mkdir -p "$_sp"
_sp_d="$_sp/dir"
_sp_rc=0
_sp_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$SCRIPT" "$_sp_d" 2>&1)" || _sp_rc=$?
{ [ "$_sp_rc" -eq 0 ] && [ -f "$_sp_d/origin" ] && [ -f "$_sp_d/work/summary.md" ]; } \
    && pass "…while a parent containing a space is set up rather than refused" \
    || die "a path with a space was refused (rc=$_sp_rc out='$_sp_out')"
# AND WHAT IT WROTE IS USABLE, which is the half a shape check cannot see: the origin
# has to be readable out of the spaced path, and the working files have to be where the
# driver builds their paths.
_sp_got="$(cat "$_sp_d/origin" 2>/dev/null)" || _sp_got="READ_FAILED"
{ [ "$_sp_got" = "$REAL" ] && [ -f "$_sp_d/work/head.txt" ]; } \
    && pass "…and the origin and the working files under it are where the driver will look" \
    || die "the spaced setup did not produce a usable directory: origin='$_sp_got'"
# A TERMINAL REFUSAL IS `1` AND NOT `2`, and that distinction is the one the driver
# acts on: it retries a `2` under a second parent and stops on a `1`, because
# another parent fixes none of these.

# ── the checkout, read through pr-origin.sh ────────────────────────────────
# NO SECOND `git remote get-url` HERE. `pr-origin.sh` is where that read is
# hardened, and a second copy of it is the duplication `CLAUDE.md` records paying
# for four times — so what this asserts is that the helper's answers come from
# there, by staging states only that reader produces.
_noremote="$TMP/noremote"; mkdir -p "$_noremote"
( cd "$_noremote" && git init -q . ) >/dev/null 2>&1 || die "could not build the remoteless checkout"
_nr_d="$(mktemp -d "$TMP/nr.XXXXXX")/dir"
_nr=0
_nr_out="$(cd "$_noremote" && run_limited 25 /usr/bin/env bash -p "$SCRIPT" "$_nr_d" 2>&1)" || _nr=$?
{ [ "$_nr" -eq 1 ] && case "$_nr_out" in *'reason=origin_unreadable'*) true ;; *) false ;; esac; } \
    && pass "a checkout with no origin is refused terminally" \
    || die "the remoteless checkout gave rc=$_nr '$_nr_out'"
[ -d "$_nr_d" ] \
    && pass "…and the directory it had reserved is left, since this helper removes nothing" \
    || die "a refused run removed the directory it had reserved"
# AND A REMOTE THAT IS NOT AN IDENTITY IS REFUSED BY THE PARSER, with the parser's
# own reason carried through — the helper proves the origin parses before it writes
# it, so a value that cannot be an identity never reaches a file the driver reads.
( cd "$REPO" && git remote set-url origin 'not-a-remote' ) 2>/dev/null || true
_bd_d="$(mktemp -d "$TMP/bd.XXXXXX")/dir"
_bd=0
_bd_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$SCRIPT" "$_bd_d" 2>&1)" || _bd=$?
{ [ "$_bd" -eq 1 ] \
  && case "$_bd_out" in *'reason=origin_unusable'*) true ;; *) false ;; esac \
  && case "$_bd_out" in *'detail='*) true ;; *) false ;; esac; } \
    && pass "…and an origin the identity parser refuses stops the run, carrying its reason" \
    || die "the unusable-origin case gave rc=$_bd '$_bd_out'"
# THE TRANSPORT `pr-origin.sh` LEFT IS STILL THERE, and that is the design rather than
# a leak: this helper removes nothing, so a refusal leaves whatever had been made. What
# that buys is that nothing of anyone ELSE's can be taken either, which is what the
# removals that used to be here could not promise.
{ [ -d "$_bd_d" ] && [ -f "$_bd_d/o/origin" ]; } \
    && pass "…and leaves its own transport rather than resolving a name to remove it" \
    || die "the unusable-origin refusal removed something inside the reservation"
( cd "$REPO" && git remote set-url origin "$REAL" ) 2>/dev/null || true

# ── the transport's own failure modes ──────────────────────────────────────
# STAGED WITH A FORGED `pr-origin.sh` BESIDE A REAL COPY OF THE SUBJECT, because
# these states are ones the real reader refuses first: it declines a multi-line
# origin itself, so the helper's own newline check is defence against a transport
# tampered with between the two — and defence nothing exercises is defence nobody
# knows is broken.
_stage="$TMP/stage"; mkdir -p "$_stage"
for _c in pr-setup.sh loadlib.sh identitylib.sh; do cp "$SELF_DIR/$_c" "$_stage/$_c"; done
_forge_origin() {   # _forge_origin <body>
    printf '#!/usr/bin/env bash\nmkdir -m 700 "$2" || exit 1\n%s\nexit 0\n' "$1" \
        > "$_stage/pr-origin.sh"
    chmod +x "$_stage/pr-origin.sh"
    return 0
}
# WHAT EVERY CASE BELOW ASSERTS IS THAT THE REFUSAL TOOK NOTHING WITH IT. Nothing is
# given back at any stage, an empty reservation included: the name is published in argv,
# and every removal shape resolved a name a same-UID process may have substituted. That is
# the property rather than a shortfall, so there is no per-case expectation to pass in.
_stagecase() {   # _stagecase <reason> <status>
    local want="$1" wrc="$2" d o=0 oo
    d="$(mktemp -d "$TMP/st.XXXXXX")/dir"
    oo="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$d" 2>&1)" || o=$?
    { [ "$o" -eq "$wrc" ] && case "$oo" in *"reason=$want"*) true ;; *) false ;; esac; } \
        && pass "…$want is reported, with status $wrc" \
        || die "the $want case gave rc=$o '$oo'"
    # WHAT IS ASSERTED IS THAT NOTHING WAS DESTROYED, not that the directory went. The
    # reservation is always left, because this helper removes nothing — the argument is
    # beside `rb_setup_stop`, and the cost is in
    # `docs/decisions/2026-08-29-setup-leaf-cleanup.md`. Requiring a removal here would be
    # requiring back the deletions that six rounds of review took out.
    [ -d "$d" ] \
        && pass "…and what it had made is left where it is" \
        || die "the $want case removed a directory this run made"
    return 0
}
# THE STAGED COPY STILL WORKS, or every case below passes against a broken staging
# rather than against the state it means to reach.
_forge_origin 'printf "%s\n" "git@github.com:acme/widget.git" > "$2/origin"'
_sd="$(mktemp -d "$TMP/sok.XXXXXX")/dir"
_so=0
_so_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$_sd" 2>&1)" || _so=$?
{ [ "$_so" -eq 0 ] && [ -f "$_sd/origin" ]; } \
    && pass "the staged copy with a working reader is ready, so the cases below reach their states" \
    || die "the staged copy failed on a good read (rc=$_so out='$_so_out')"
_forge_origin ': > "$2/origin"'
_stagecase origin_empty 1
_forge_origin 'printf "a\nb\n" > "$2/origin"'
_stagecase origin_multiline 1
_forge_origin 'mkdir "$2/origin"'
_stagecase origin_transport 1
# AND THE READER'S OWN STORAGE REFUSAL IS CARRIED THROUGH AS ONE. `pr-origin.sh`
# reports 2 where the storage would not take what it asked, and that is the status
# the DRIVER retries on — folding it into 1 would turn a full filesystem into a
# session that stops instead of one that moves to the other parent.
printf '#!/usr/bin/env bash\nexit 2\n' > "$_stage/pr-origin.sh"; chmod +x "$_stage/pr-origin.sh"
_stagecase origin_storage 2
# …WHILE THE READER'S TERMINAL REFUSAL STAYS TERMINAL.
printf '#!/usr/bin/env bash\nexit 1\n' > "$_stage/pr-origin.sh"; chmod +x "$_stage/pr-origin.sh"
_stagecase origin_unreadable 1

# ── a replacement survives a refusal, contents and all ────────────────────
# THE NAME IS PUBLISHED IN ARGV BEFORE THE `mkdir` RESERVES IT, and under a parent
# without the sticky bit another account can replace the directory AFTER the
# reservation. A recursive removal on a later failure then deletes the replacement
# and everything in it — which is far past what
# `docs/decisions/2026-08-26-reservation-inference.md` accepts, and is why the shapes
# that removed anything are gone.
#
# STAGED DETERMINISTICALLY, by having the forged reader do the replacing: it is
# handed `<dir>/o`, so its parent is the directory under test, and it swaps that for
# one of its own carrying a witness before refusing. No timing, no race to lose.
_forge_origin 'p="$(dirname "$2")"
rm -rf "$p"
mkdir -m 700 "$p"
mkdir -m 700 "$p/squatter-subdir"
printf "not this runs\n" > "$p/witness"
printf "not this runs\n" > "$p/origin"
exit 1'
_rr="$(mktemp -d "$TMP/rr.XXXXXX")/dir"
_rr_rc=0
_rr_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$_rr" 2>&1)" || _rr_rc=$?
[ "$_rr_rc" -ne 0 ] \
    && pass "a directory replaced after the reservation still ends in a refusal" \
    || die "the replacement case did not refuse (out='$_rr_out')"
{ [ -f "$_rr/witness" ] && [ -d "$_rr/squatter-subdir" ] && [ -s "$_rr/origin" ]; } \
    && pass "…and the cleanup leaves what it did not create" \
    || die "the cleanup destroyed a replacement's contents (witness=$([ -e "$_rr/witness" ] && echo yes || echo no) subdir=$([ -e "$_rr/squatter-subdir" ] && echo yes || echo no))"
# THE DIRECTORY ITSELF SURVIVES TOO, which is the same assertion read from the other
# end: a shape that took the empty directory would take a replaced one just as readily,
# the name being all either has to go on.
[ -d "$_rr" ] \
    && pass "…and the replacement directory itself, which no shape here resolves" \
    || die "the replacement directory was removed although it had contents"
rm -rf "$_rr"
# ── a signal kills the helper and takes nothing with it ───────────────────
# THE HELPER ARMS ONE TRAP, AND IT REMOVES NOTHING. The cleanup handlers went with the
# cleanup, so `TERM` and `HUP` are bash's own default disposition here — the shell dies of
# them and nothing runs on the way out. `INT` is not: without a handler the run continues
# past it, which is what the second case below is for. The scan further down can see how
# many `trap` lines there are and that none of them removes anything; it cannot see what a
# signal actually does to a run in progress, which is what these cases are.
#
# STAGED DETERMINISTICALLY, with no timing at all: the forged reader signals its own
# parent, which IS the helper, and the reader has already created the transport by then.
# Measured: bash terminates while waiting on the foreground child rather than deferring
# to its return, so the run dies partway through with the reservation and the transport
# in place and the later files never written.
#
# AND `INT` IS WHAT MADE THIS SECTION NECESSARY. Non-interactively bash does not die of it
# here: with no handler the run CONTINUES past the signal, writes every working file and
# publishes `status=ready`, so a caller reads a session somebody stopped as one that
# succeeded. `TERM` needs no handler and `INT` does, which is why both run rather than one
# standing for the other.
_sigcase() {   # _sigcase <signal> <status>
    local sig="$1" want="$2" d rc=0 out
    _forge_origin 'printf "%s\n" "git@github.com:acme/widget.git" > "$2/origin"
kill -'"$sig"' "$PPID"'
    d="$(mktemp -d "$TMP/sg.XXXXXX")/dir"
    out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$d" 2>&1)" || rc=$?
    [ "$rc" -eq "$want" ] \
        && pass "a $sig ends the helper with $want" \
        || die "the $sig case gave rc=$rc '$out'"
    # THE READY LINE IS ASSERTED ABSENT AS WELL AS THE STATUS, because the failure this
    # case exists for is a run that carries on to the end: with `INT` unhandled the status
    # was 0 AND `status=ready` was published, and a caller branches on both.
    case "$out" in
        *'status=ready'*) die "the $sig case published a ready line for a run that was stopped" ;;
        *) pass "…with no ready line, so nothing downstream reads it as a session that started" ;;
    esac
    # AND WHAT HAD BEEN MADE IS STILL THERE, which is the half a text scan cannot reach: a
    # handler that removed the reservation would leave this true only for the transport,
    # and one that removed the tree would leave neither.
    { [ -d "$d" ] && [ -f "$d/o/origin" ]; } \
        && pass "…and the reservation and the transport inside it are left where they are" \
        || die "the $sig case took something with it (dir=$([ -d "$d" ] && echo yes || echo no) transport=$([ -f "$d/o/origin" ] && echo yes || echo no))"
    return 0
}
_sigcase TERM 143
_sigcase INT 130

# ── nothing is removed at all, which is the whole cleanup contract ────────
# EVERY SHAPE THAT REMOVED ANYTHING NEEDED A NAME, and shell has no descriptor-relative
# removal — no `unlinkat`, no `rmdir` on a held directory. The last shape standing was one
# `rmdir` on the reservation gated by an inode compared against a held descriptor, and it
# is a CHECK-THEN-USE: `rmdir` resolves the name again after the comparison, so a racer
# replacing the directory in that window has its replacement taken.
#
# So this helper removes nothing, and the descriptor and the inode went with the cleanup
# they gated. The CLEANUP traps went with it too — there was nothing left for those to do —
# and the `INT` re-raise that stays is not one of them: it removes nothing, which is what
# the second count below asserts of every handler in the file.
# `docs/decisions/2026-08-29-setup-leaf-cleanup.md` carries the table of what each earlier
# shape destroyed.
_rm_n=0; _rm_n="$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'rmdir\|rm -f\|rm -rf')" || _rm_n=0
[ "$_rm_n" -eq 0 ] \
    && pass "pr-setup.sh removes nothing at all, so no name it resolves can take another's object" \
    || die "pr-setup.sh has $_rm_n removals; it is meant to have none"
# THE TRAPS ARE COUNTED THE SAME WAY, and one is expected: `INT` is not fatal here without
# a handler, so the run would otherwise continue and publish a ready line. What is asserted
# of it is that no handler REMOVES anything — a body that did would put the whole class
# back behind a signal, which is where it is hardest to see.
_tr_n=0; _tr_n="$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c '^trap ')" || _tr_n=0
[ "$_tr_n" -eq 1 ] \
    && pass "…and one trap, which is the INT re-raise the measured behaviour needs" \
    || die "pr-setup.sh arms $_tr_n traps; it is meant to arm exactly the INT one"
_trb_n=0; _trb_n="$(grep '^trap ' "$SCRIPT" | grep -c 'rmdir\|rm -f\|rm -rf\|unlink')" || _trb_n=0
[ "$_trb_n" -eq 0 ] \
    && pass "…and no handler removes anything, so the class cannot come back behind a signal" \
    || die "$_trb_n of pr-setup.sh's traps remove something"

# ── the creates are exclusive, so nothing is truncated through them ───────
# A PLAIN `>` OPENS WITH O_TRUNC AND FOLLOWS SYMLINKS. This directory's name is
# published in argv, so an account that can reach it may put a symlink at one of these
# paths pointing anywhere the operator can write — and the redirection would truncate
# THAT, which is destroying somebody's file rather than losing a reservation. With
# `set -C` the open is O_EXCL: it refuses a regular file, and it refuses a symlink
# whether or not the target exists.
grep -qx 'set -C' "$SCRIPT" \
    && pass "the helper opens its outputs under noclobber" \
    || die "pr-setup.sh does not set -C; a symlink at a working path is followed and truncated"
grep -qx 'umask 077' "$SCRIPT" \
    && pass "…with a umask that says who may write what it created" \
    || die "pr-setup.sh does not set umask 077 alongside noclobber"
# COUNTED OVER THE CODE, NOT THE PROSE. The comment beside the creates names `>|` as
# the spelling a later edit reaches for, and a whole-file scan read its own subject as
# the defect.
case "$(grep -v '^[[:space:]]*#' "$SCRIPT")" in
    *'>|'*) die "pr-setup.sh uses >|, which overrides the noclobber the creates rely on" ;;
    *) pass "…and never uses >|, which is what overrides it" ;;
esac
# THE ORIGIN WRITE, STAGED. The forged reader runs before that write, so it can plant
# the symlink in the window the case is about.
_vic="$TMP/victim-origin"
printf 'PRECIOUS\n' > "$_vic"
for _c in pr-setup.sh loadlib.sh identitylib.sh; do cp "$SELF_DIR/$_c" "$_stage/$_c"; done
_forge_origin 'printf "%s\n" "git@github.com:acme/widget.git" > "$2/origin"
ln -s '"$_vic"' "$(dirname "$2")/origin"'
_sy="$(mktemp -d "$TMP/sy.XXXXXX")/dir"
_sy_rc=0
_sy_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$_sy" 2>&1)" || _sy_rc=$?
[ "$_sy_rc" -ne 0 ] \
    && pass "a symlink planted at the origin name is refused rather than written through" \
    || die "the helper wrote through a planted symlink (out='$_sy_out')"
[ "$(cat "$_vic" 2>/dev/null)" = "PRECIOUS" ] \
    && pass "…and the file it pointed at is untouched" \
    || die "the symlink target was truncated: '$(cat "$_vic" 2>/dev/null)'"
rm -rf "$_sy"
# AND A WORKING LEAF, STAGED BY PATCHING THE COPY UNDER TEST — the plant has to happen
# between `work/` being created and the loop that fills it, which nothing outside the
# process can reach.
printf 'PRECIOUS\n' > "$_vic"
_forge_origin 'printf "%s\n" "git@github.com:acme/widget.git" > "$2/origin"'
sed 's|^for _f in summary.md request.md prior.txt head.txt; do|ln -s '"$_vic"' "$RB_WORK_DIR/summary.md"; &|' \
    "$SELF_DIR/pr-setup.sh" > "$_stage/pr-setup.sh"
grep -qF 'ln -s' "$_stage/pr-setup.sh" \
    && pass "the working-leaf symlink stage is patched" \
    || die "the working-leaf stage did not patch pr-setup.sh; the case proves nothing"
_sw="$(mktemp -d "$TMP/sw.XXXXXX")/dir"
_sw_rc=0
_sw_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$_sw" 2>&1)" || _sw_rc=$?
[ "$_sw_rc" -ne 0 ] \
    && pass "a symlink planted at a working path is refused rather than written through" \
    || die "the helper wrote through a planted working-path symlink (out='$_sw_out')"
[ "$(cat "$_vic" 2>/dev/null)" = "PRECIOUS" ] \
    && pass "…and that target is untouched too" \
    || die "the working-path symlink target was truncated: '$(cat "$_vic" 2>/dev/null)'"
rm -rf "$_sw"
cp "$SELF_DIR/pr-setup.sh" "$_stage/pr-setup.sh"

# ── there is no probe for the pin's storage, and that is deliberate ───────
# A PROBE HAS TO RELEASE WHAT IT TOOK, AND RELEASING MEANS REMOVING A NAME. Keeping the
# objects answers nothing — two inodes taken and held is two the pin then cannot have, so
# a filesystem with exactly enough for setup and the pin passes and the call still fails.
# Removing them puts back the class this file spent six review rounds getting out of: two
# `rmdir`s on two names lose two of a watcher's empty directories, where
# `docs/decisions/2026-08-26-reservation-inference.md` bounds the cost at one.
#
# SO THE PIN'S STORAGE FAILURE IS TERMINAL and the recovery is a re-run, which is what it
# was before the probe existed. What is still handled is the SQUAT — the case an accepted
# record bounds — by the driver's retry under a second fixed name, which
# `test-pr-skill-contract.sh` stages.
case "$(grep -v '^[[:space:]]*#' "$SCRIPT")" in
    *pinprobe*) die "the pin-storage probe is back; it cannot release what it took without removing a name" ;;
    *) pass "there is no pin-storage probe, so nothing has to be released" ;;
esac

# ── the streams are separate ───────────────────────────────────────────────
# NOTHING BUT THE READY LINE ON STDOUT, and every reason on stderr. The driver
# reads one stream and never sees the other, which is what lets a caller capture
# the ready line without a refusal's diagnostics landing in the value.
_od="$(mktemp -d "$TMP/od.XXXXXX")/dir"
_out_only="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$SCRIPT" "$_od" 2>/dev/null)" || true
case "$_out_only" in
    "PR_SETUP status=ready origin=$_od/origin work=$_od/work") pass "stdout carries the ready line and nothing else" ;;
    *) die "stdout carried something other than the ready line: '$_out_only'" ;;
esac
_err_d="$(mktemp -d "$TMP/ed.XXXXXX")/dir"
_err_only="$(cd "$_noremote" && run_limited 25 /usr/bin/env bash -p "$SCRIPT" "$_err_d" 2>/dev/null)" || true
[ -z "$_err_only" ] \
    && pass "…and a refusal puts nothing on stdout at all" \
    || die "a refusal wrote to stdout: '$_err_only'"

# ── privileged mode ────────────────────────────────────────────────────────
# THE HELPER REFUSES A SHELL THAT IS NOT PRIVILEGED, which is the last-resort check
# rather than the defence: `$-` reports the MODE and not how the shell got there,
# so a `BASH_ENV` hook that sets `-p` itself passes it. What it catches is the
# ordinary mistake — a caller that forgot `-p` — and `CLAUDE.md` records that
# `bash pr-x.sh` is unsupported rather than defended.
_np=0
_np_out="$(cd "$REPO" && run_limited 25 bash "$SCRIPT" "$TMP/never" 2>&1)" || _np=$?
{ [ "$_np" -eq 1 ] && case "$_np_out" in *'reason=not_privileged'*) true ;; *) false ;; esac \
  && [ ! -e "$TMP/never" ]; } \
    && pass "an unprivileged caller is refused before anything is created" \
    || die "the unprivileged case gave rc=$_np '$_np_out'"
# AND THE FILE IS EXECUTABLE, which is the rule rather than the exception. Every
# `pr-*.sh` begins `#!/usr/bin/env -S bash -p` and is started that way; the two files
# excused from it are `pr-selfcheck.sh`, which re-execs into a clean shell of its own,
# and `pr-origin.sh`, which is NOT executable at all so that only a caller naming an
# interpreter can start it. `test-pr-identity.sh` asserts both halves of that exception,
# and this helper is on neither side of it — a maintainer reading the opposite here would
# take the mode bit off and turn the shebang into a comment.
[ -x "$SCRIPT" ] \
    && pass "pr-setup.sh is executable, so its own privileged shebang is what starts it" \
    || die "pr-setup.sh is not executable; its #!/usr/bin/env -S bash -p shebang is inert"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
