#!/usr/bin/env bash
# Unit tests for pr-setup.sh.
#
# THE CONTRACT UNDER TEST: the caller starts it with `/usr/bin/env bash -p` and
# names a DIRECTORY that must not exist. The helper creates it exclusively at mode
# 700, reads the origin through `pr-origin.sh`, proves it parses, allocates
# `work/` and the four working files, and writes `<dir>/env` — a file of
# single-quoted assignments the DRIVER sources. Statuses: 0 ready, 1 stopped, 2 the
# storage would not take it, which is the only one the caller retries.
#
# WHAT THIS FILE IS ABOUT, and what `test-pr-skill-contract.sh` is about, are two
# ends of one arrangement. The contract file runs the DRIVER's block against a
# forged helper: whether a refusal is walked past, whether the source is what
# brings the values in, whether the pin is proved. This file runs the REAL helper:
# whether the directory is a reservation, whether a value carrying `$(…)` comes
# back as data, whether a refusal leaves anything behind. Neither can answer the
# other's question, and putting both in one file was tried in `SKILL.md` — the 178
# lines #228 moved out.
#
# THE QUOTING IS THE PART TO READ FIRST. A remote URL is not this repository's
# text: a checkout can carry any origin, and a `git` config nobody read can put a
# quote, a `$(…)`, a backtick or a semicolon in it. The env file is SOURCED, so a
# value that escapes its quoting is a command in the driving shell. Every shape is
# staged here against the real helper and asserted to round-trip byte-exact and to
# execute nothing.
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
  && case "$(out_of "$r")" in *"PR_SETUP status=ready env=$ok_dir/env"*) true ;; *) false ;; esac; } \
    && pass "a good checkout gives status=ready and names the file to source" \
    || die "the ordinary run failed: '$r'"
# THE DIRECTORY SURVIVES THE CALL, which is the whole point of it: the caller
# sources the file and then uses `work/` for the rest of the session. A helper that
# cleaned up on success would be removing what it was asked to produce.
{ [ -d "$ok_dir" ] && [ -f "$ok_dir/env" ]; } \
    && pass "…and the directory it made is left for the caller" \
    || die "the successful run did not leave its directory behind"
# AT MODE 700, because the env file inside it carries the session's origin and the
# work files carry the round's account before it is posted.
_mode="$(ls -ld "$ok_dir" 2>/dev/null | cut -c1-10)" || _mode=""
case "$_mode" in
    drwx------) pass "…at mode 700, so nothing else on the machine reads the session's files" ;;
    *) die "the setup directory is $_mode, not drwx------" ;;
esac

# ── what the driver gets by sourcing it ────────────────────────────────────
# SOURCED IN A CHILD, AND EVERY VALUE READ BACK. This is the driver's own use of
# the file, and the assertion is on the values rather than on the text: a `grep`
# for `OWNER=` passes against a line the shell would refuse to parse.
_src="$(env -u REVIEW_BUS_REMOTE bash -c '
    . "$1/env" || exit 9
    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" "$RB_REMOTE" "$OWNER" "$REPO" "$HOST" \
        "$CODEX_BOT" "$COPILOT_BOT" "$SUMMARY_FILE" "$REQUEST_FILE" "$PRIOR_FILE" "$HEAD_FILE"
' _ "$ok_dir" 2>&1)" || _src="SOURCE_FAILED:$_src"
case "$_src" in
    "$REAL|acme|widget|github.com|chatgpt-codex-connector[bot]|copilot-pull-request-reviewer[bot]|$ok_dir/work/summary.md|$ok_dir/work/request.md|$ok_dir/work/prior.txt|$ok_dir/work/head.txt")
        pass "…and sourcing it yields the identity, both bot names and the four working paths" ;;
    *)  die "the sourced values are not what the helper wrote: '$_src'" ;;
esac
# THE FOUR PATHS ARE PAIRWISE DISTINCT, which is where the no-aliasing invariant is
# actually established. Two names given the same suffix would alias every later
# check into agreement — `pr-close-round.sh` refuses a head file that IS the
# summary file, and that refusal is only meaningful if the literals differ.
_four="$(env -u REVIEW_BUS_REMOTE bash -c '
    . "$1/env" || exit 9
    printf "%s\n%s\n%s\n%s\n" "$SUMMARY_FILE" "$REQUEST_FILE" "$PRIOR_FILE" "$HEAD_FILE"
' _ "$ok_dir" 2>/dev/null)" || _four=""
_fn="$(grep -c . <<<"$_four")" || _fn=0
_fu="$(sort -u <<<"$_four" | grep -c .)" || _fu=0
{ [ "$_fn" -eq 4 ] && [ "$_fu" -eq 4 ]; } \
    && pass "…and the four are pairwise distinct paths" \
    || die "the working paths are not four distinct names ($_fn found, $_fu distinct)"
# AND EACH IS A FILE THAT EXISTS AND IS EMPTY. The round summary must be empty
# until the round writes it: sharing one file with the opening account meant a
# first round whose summary write did not happen left the opening account there —
# non-empty, well-formed and about the right PR — and it was posted as the summary.
_wf_bad=""
for _f in summary.md request.md prior.txt head.txt; do
    { [ -f "$ok_dir/work/$_f" ] && [ ! -s "$ok_dir/work/$_f" ]; } || _wf_bad="$_wf_bad $_f"
done
[ -z "$_wf_bad" ] \
    && pass "…each created as a file that exists and is empty" \
    || die "a working file is missing or not empty:$_wf_bad"
# AND `HEAD_FILE` IS THE LAST LINE, which is what the helper's own truncation check
# rests on: `printf` can fail part-way through a redirection that reports success
# overall, and a truncated env file is one whose last assignment is missing — which
# the driver would source without noticing, ending up with a path it never set.
_last="$(tail -1 "$ok_dir/env" 2>/dev/null)" || _last=""
case "$_last" in
    HEAD_FILE=*) pass "…and HEAD_FILE is the file's last line, which is what the truncation check reads" ;;
    *) die "the env file does not end with HEAD_FILE; the helper's truncation check no longer proves the write completed: '$_last'" ;;
esac
# AND THE `rb-assigns:` DECLARATION MATCHES WHAT WAS ACTUALLY WRITTEN. That line is
# what `pr-selfcheck.sh` credits when it scans `SKILL.md` for names used and never
# assigned — the file being sourced does not exist at scan time, so the declaration
# is the only thing there is to read. A declaration that drifts widens what the scan
# accepts, silently, in the direction that reports a real defect as fine; comparing
# it against the keys of a real run is what stops that.
#
# BOTH DIRECTIONS. A missing name reinstates a false finding, which is loud; an
# EXTRA one is the quiet half — it credits `SKILL.md` with a variable nothing
# assigns, which is exactly the P1 that scan exists to catch.
_decl="$(grep -oE '^# rb-assigns:[A-Za-z0-9_ ]*' "$SCRIPT" \
    | sed -E 's/^# rb-assigns:[[:space:]]*//' | tr ' ' '\n' | grep -v '^$' | sort -u)" || _decl=""
_keys="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$ok_dir/env" | sed 's/=$//' | sort -u)" || _keys=""
{ [ -n "$_decl" ] && [ "$_decl" = "$_keys" ]; } \
    && pass "…and its rb-assigns declaration is exactly the set of names it wrote" \
    || die "the rb-assigns declaration has drifted from the env file: declared='$(tr '\n' ' ' <<<"$_decl")' written='$(tr '\n' ' ' <<<"$_keys")'"
# AND IT DECLARES THE LEAF, which is what binds a `. "$X/env"` in the document to
# this helper rather than to a list somebody has to keep in the scanner.
grep -qxE '# rb-writes:[[:space:]]*env' "$SCRIPT" \
    && pass "…and declares that it is the helper writing 'env'" \
    || die "pr-setup.sh does not declare the leaf it writes; pr-selfcheck.sh cannot bind the source to it"
# AND THE PIN IS BOTH AN ASSIGNMENT AND AN EXPORT. The assignment is what the
# driver's own re-derivation reads; the export is what every child inherits. The
# driver cannot supply the export itself — a child cannot export into its parent,
# and that is the whole reason this file is sourced rather than captured.
_child="$(env -u REVIEW_BUS_REMOTE bash -c '
    . "$1/env" || exit 9
    bash -c '"'"'printf "child=[%s]" "${REVIEW_BUS_REMOTE-unset}"'"'"'
' _ "$ok_dir" 2>&1)" || _child="FAILED:$_child"
[ "$_child" = "child=[$REAL]" ] \
    && pass "…and a grandchild of the sourcing shell inherits the pin" \
    || die "the pin does not survive into a child: '$_child'"

# ── a value is data, whatever is in it ─────────────────────────────────────
# EVERY SHAPE THAT ESCAPES A NAIVE QUOTING, against the real helper. The env file
# is SOURCED, so a value that breaks out of its quotes is a command in the driving
# shell — and a remote is not this repository's text.
#
# THE WITNESS IS A FILE, not a marker in the output: a substitution that ran would
# leave its trace whether or not anything printed, and a case reading only stdout
# would miss `$(rm …)` entirely.
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
    _w="$TMP/witness.$_inj_i"
    rm -f "$_w"
    ( cd "$REPO" && git remote set-url origin "$_bad" ) 2>/dev/null \
        || { die "git would not hold the staged remote #$_inj_i"; continue; }
    r="$(run --)"
    _d="$(dir_of "$r")"
    if [ "$(rc_of "$r")" != 0 ]; then
        die "the helper refused a legal-if-hostile remote #$_inj_i: '$r'"
        continue
    fi
    # SOURCED WITH THE WITNESS NAME IN SCOPE, so a substitution that escaped the
    # quoting creates the file this case then looks for.
    _got="$(env -u REVIEW_BUS_REMOTE WITNESS="$_w" bash -c '
        cd "$2" || exit 9
        . "$1/env" || exit 9
        printf "%s" "$RB_REMOTE"
    ' _ "$_d" "$TMP" 2>&1)" || _got="SOURCE_FAILED:$_got"
    { [ "$_got" = "$_bad" ] && [ ! -e "$TMP/WITNESS" ]; } \
        && pass "a remote carrying #$_inj_i round-trips byte-exact and executes nothing" \
        || die "remote #$_inj_i came back as '$_got' (witness-exists=$([ -e "$TMP/WITNESS" ] && echo yes || echo no))"
    rm -f "$TMP/WITNESS"
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
    case "$_kind" in
        dir)     { [ -f "$_t/canary" ] && [ ! -e "$_t/env" ]; } \
                     && pass "…and the directory that was there is untouched" \
                     || die "the pre-existing directory was written into" ;;
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
{ [ "$_sp_rc" -eq 0 ] && [ -f "$_sp_d/env" ] && [ -f "$_sp_d/work/summary.md" ]; } \
    && pass "…while a parent containing a space is set up rather than refused" \
    || die "a path with a space was refused (rc=$_sp_rc out='$_sp_out')"
# AND THE VALUES IN IT SURVIVE THE SOURCE, which is the half a shape check cannot
# see: the paths are written into the env file and read back by the driver.
_sp_got="$(env -u REVIEW_BUS_REMOTE bash -c '. "$1/env" || exit 9; printf "%s" "$SUMMARY_FILE"' _ "$_sp_d" 2>&1)" || _sp_got="SOURCE_FAILED:$_sp_got"
[ "$_sp_got" = "$_sp_d/work/summary.md" ] \
    && pass "…and the spaced path round-trips through the source intact" \
    || die "the spaced working path came back as '$_sp_got'"
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
[ ! -e "$_nr_d" ] \
    && pass "…and the directory it had reserved is given back" \
    || die "a refused run left its directory behind"
# AND A REMOTE THAT IS NOT AN IDENTITY IS REFUSED BY THE PARSER, with the parser's
# own reason carried through — the helper proves the origin parses before it writes
# it, so a value that cannot be an identity never reaches a file the driver sources.
( cd "$REPO" && git remote set-url origin 'not-a-remote' ) 2>/dev/null || true
_bd_d="$(mktemp -d "$TMP/bd.XXXXXX")/dir"
_bd=0
_bd_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$SCRIPT" "$_bd_d" 2>&1)" || _bd=$?
{ [ "$_bd" -eq 1 ] \
  && case "$_bd_out" in *'reason=origin_unusable'*) true ;; *) false ;; esac \
  && case "$_bd_out" in *'detail='*) true ;; *) false ;; esac; } \
    && pass "…and an origin the identity parser refuses stops the run, carrying its reason" \
    || die "the unusable-origin case gave rc=$_bd '$_bd_out'"
[ ! -e "$_bd_d" ] \
    && pass "…and that refusal gives its directory back too" \
    || die "the unusable-origin refusal left its directory behind"
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
# THE THIRD ARGUMENT IS WHAT THE CLEANUP IS EXPECTED TO DO, and it is not always
# "removed". The give-back takes objects away one at a time and uses `rmdir` for the
# directories, so anything it did not create REFUSES to go — which is the property,
# not a shortfall: the name is published in argv, and a recursive removal would
# delete whatever an account that replaced the directory had put in it.
_stagecase() {   # _stagecase <reason> <status> <gone|kept>
    local want="$1" wrc="$2" fate="$3" d o=0 oo
    d="$(mktemp -d "$TMP/st.XXXXXX")/dir"
    oo="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$d" 2>&1)" || o=$?
    { [ "$o" -eq "$wrc" ] && case "$oo" in *"reason=$want"*) true ;; *) false ;; esac; } \
        && pass "…$want is reported, with status $wrc" \
        || die "the $want case gave rc=$o '$oo'"
    if [ "$fate" = gone ]; then
        [ ! -e "$d" ] \
            && pass "…and its directory is given back" \
            || die "the $want case left its directory behind"
    else
        { [ -d "$d" ] && [ ! -f "$d/env" ]; } \
            && pass "…and the directory is left, because rmdir refuses what it holds" \
            || die "the $want case did not leave the unexpected object alone"
    fi
    return 0
}
# THE STAGED COPY STILL WORKS, or every case below passes against a broken staging
# rather than against the state it means to reach.
_forge_origin 'printf "%s\n" "git@github.com:acme/widget.git" > "$2/origin"'
_sd="$(mktemp -d "$TMP/sok.XXXXXX")/dir"
_so=0
_so_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$_sd" 2>&1)" || _so=$?
{ [ "$_so" -eq 0 ] && [ -f "$_sd/env" ]; } \
    && pass "the staged copy with a working reader is ready, so the cases below reach their states" \
    || die "the staged copy failed on a good read (rc=$_so out='$_so_out')"
_forge_origin ': > "$2/origin"'
_stagecase origin_empty 1 gone
_forge_origin 'printf "a\nb\n" > "$2/origin"'
_stagecase origin_multiline 1 gone
_forge_origin 'mkdir "$2/origin"'
_stagecase origin_transport 1 kept
# AND THE READER'S OWN STORAGE REFUSAL IS CARRIED THROUGH AS ONE. `pr-origin.sh`
# reports 2 where the storage would not take what it asked, and that is the status
# the DRIVER retries on — folding it into 1 would turn a full filesystem into a
# session that stops instead of one that moves to the other parent.
printf '#!/usr/bin/env bash\nexit 2\n' > "$_stage/pr-origin.sh"; chmod +x "$_stage/pr-origin.sh"
_stagecase origin_storage 2 gone
# …WHILE THE READER'S TERMINAL REFUSAL STAYS TERMINAL.
printf '#!/usr/bin/env bash\nexit 1\n' > "$_stage/pr-origin.sh"; chmod +x "$_stage/pr-origin.sh"
_stagecase origin_unreadable 1 gone

# ── the cleanup removes what this run made, and nothing else ──────────────
# THE NAME IS PUBLISHED IN ARGV BEFORE THE `mkdir` RESERVES IT, and under a parent
# without the sticky bit another account can replace the directory AFTER the
# reservation. A recursive removal on a later failure then deletes the replacement
# and everything in it — which is far past what
# `docs/decisions/2026-08-26-reservation-inference.md` accepts, and that record rests
# on `rmdir` REFUSING anything with contents in it.
#
# STAGED DETERMINISTICALLY, by having the forged reader do the replacing: it is
# handed `<dir>/o`, so its parent is the directory under test, and it swaps that for
# one of its own carrying a witness before refusing. No timing, no race to lose.
_forge_origin 'p="$(dirname "$2")"
rm -rf "$p"
mkdir -m 700 "$p"
mkdir -m 700 "$p/squatter-subdir"
printf "not this runs\n" > "$p/witness"
printf "not this runs\n" > "$p/env"
exit 1'
_rr="$(mktemp -d "$TMP/rr.XXXXXX")/dir"
_rr_rc=0
_rr_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$_rr" 2>&1)" || _rr_rc=$?
[ "$_rr_rc" -ne 0 ] \
    && pass "a directory replaced after the reservation still ends in a refusal" \
    || die "the replacement case did not refuse (out='$_rr_out')"
{ [ -f "$_rr/witness" ] && [ -d "$_rr/squatter-subdir" ]; } \
    && pass "…and the cleanup leaves what it did not create" \
    || die "the cleanup destroyed a replacement's contents (witness=$([ -e "$_rr/witness" ] && echo yes || echo no) subdir=$([ -e "$_rr/squatter-subdir" ] && echo yes || echo no))"
# THE DIRECTORY ITSELF SURVIVES TOO, because `rmdir` refuses one with contents. That
# is the bound the record describes, reached from the other end: at most an empty
# directory goes.
[ -d "$_rr" ] \
    && pass "…and the replacement directory itself, which rmdir refuses to take" \
    || die "the replacement directory was removed although it had contents"
rm -rf "$_rr"
# THE HELD DESCRIPTOR IS WHAT MAKES THE INODE AN IDENTITY, so its absence is asserted
# to change the outcome rather than being taken on trust. A bare inode number can be
# handed back to the next `mkdir` once the original is freed; a descriptor held on the
# original stops it being freed at all. Where the open fails there is no durable
# identity, and the cleanup falls back to `rmdir` alone rather than unlinking through
# a name it cannot vouch for — asserted here by removing the `exec` from a copy of the
# subject and requiring the leaves to survive anyway.
grep -qF 'exec 8<"$RB_DIR"' "$SCRIPT" \
    && pass "the reservation is held open, so its inode cannot be reused" \
    || die "pr-setup.sh does not hold a descriptor on the directory it reserved"
# AND THE RECORDED NUMBER IS THE OTHER HALF. The descriptor stops the inode being
# reused; the number is what the comparison is against, and `ls -di` can fail or print
# nothing — after which the comparison is skipped and the held descriptor alone would
# let the leaf removals run against a name this run cannot vouch for. An empty record
# is the same answer as a failed open.
for _c in pr-setup.sh loadlib.sh identitylib.sh; do cp "$SELF_DIR/$_c" "$_stage/$_c"; done
_forge_origin 'p="$(dirname "$2")"
rm -rf "$p"
mkdir -m 700 "$p"
mkdir -m 700 "$p/o"
printf "not this runs\n" > "$p/env"
printf "not this runs\n" > "$p/o/origin"
exit 1'
grep -vF 'RB_INO="$(rb_setup_ino "$RB_DIR")"' "$SELF_DIR/pr-setup.sh" > "$_stage/pr-setup.sh"
grep -qF 'RB_INO="$(rb_setup_ino' "$_stage/pr-setup.sh" \
    && die "the no-inode stage did not patch pr-setup.sh; the case proves nothing" \
    || pass "the no-inode stage is patched"
_ni="$(mktemp -d "$TMP/ni.XXXXXX")/dir"
_ni_rc=0
_ni_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$_ni" 2>&1)" || _ni_rc=$?
{ [ -f "$_ni/env" ] && [ -f "$_ni/o/origin" ]; } \
    && pass "…and with no recorded inode the cleanup unlinks nothing either" \
    || die "a cleanup with no recorded inode still unlinked leaves (rc=$_ni_rc out='$_ni_out')"
rm -rf "$_ni"
cp "$SELF_DIR/pr-setup.sh" "$_stage/pr-setup.sh"
# AND WITHOUT IT NOTHING IS UNLINKED, which is the fallback rather than a weaker
# version of the same removal.
for _c in pr-setup.sh loadlib.sh identitylib.sh; do cp "$SELF_DIR/$_c" "$_stage/$_c"; done
_forge_origin 'p="$(dirname "$2")"
rm -rf "$p"
mkdir -m 700 "$p"
mkdir -m 700 "$p/o"
printf "not this runs\n" > "$p/env"
printf "not this runs\n" > "$p/o/origin"
exit 1'
grep -vF 'exec 8<"$RB_DIR"' "$SELF_DIR/pr-setup.sh" > "$_stage/pr-setup.sh"
grep -qF 'exec 8<"$RB_DIR"' "$_stage/pr-setup.sh" \
    && die "the no-descriptor stage did not patch pr-setup.sh; the case proves nothing" \
    || pass "the no-descriptor stage is patched"
_nh="$(mktemp -d "$TMP/nh.XXXXXX")/dir"
_nh_rc=0
_nh_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$_nh" 2>&1)" || _nh_rc=$?
{ [ -f "$_nh/env" ] && [ -f "$_nh/o/origin" ]; } \
    && pass "…and with no held descriptor the cleanup unlinks nothing at all" \
    || die "a cleanup with no durable identity still unlinked leaves (rc=$_nh_rc out='$_nh_out')"
rm -rf "$_nh"
cp "$SELF_DIR/pr-setup.sh" "$_stage/pr-setup.sh"

# …AND A REPLACEMENT CARRYING THE SAME NAMES IS NOT UNLINKED THROUGH EITHER. The
# case above used witnesses this run never names, so it passed on a cleanup that
# still removed `env` and `o/origin` by path. `-O` refuses a directory another
# ACCOUNT holds — which is the boundary the record is about — but a fixture runs as
# one account, so what this reaches is the other guard: the inode recorded when the
# `mkdir` reported success, which a replacement does not carry.
_forge_origin 'p="$(dirname "$2")"
rm -rf "$p"
mkdir -m 700 "$p"
mkdir -m 700 "$p/o"
printf "not this runs\n" > "$p/env"
printf "not this runs\n" > "$p/o/origin"
exit 1'
_rc2="$(mktemp -d "$TMP/rc.XXXXXX")/dir"
_rc2_rc=0
_rc2_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$_rc2" 2>&1)" || _rc2_rc=$?
[ "$_rc2_rc" -ne 0 ] \
    && pass "a replacement carrying the declared leaf names still ends in a refusal" \
    || die "the name-collision case did not refuse (out='$_rc2_out')"
{ [ -f "$_rc2/env" ] && [ -f "$_rc2/o/origin" ]; } \
    && pass "…and neither declared leaf is unlinked through the replaced path" \
    || die "the cleanup unlinked a replacement's own leaf (env=$([ -e "$_rc2/env" ] && echo yes || echo no) origin=$([ -e "$_rc2/o/origin" ] && echo yes || echo no))"
rm -rf "$_rc2"

# ── an incomplete env file is refused ─────────────────────────────────────
# `{ a; b; c; } > f` REPORTS ONLY C'S STATUS. A `printf` that failed in the middle
# while a later one succeeded was a group that reported success, and checking for the
# LAST line could not see it either — `HEAD_FILE=` is that line. Losing `CODEX_BOT`
# that way lets setup announce ready with no reviewer login, after which the watch
# polls for a bot nobody named.
#
# STAGED BY REMOVING ONE WRITE from a copy of the subject, which is the state a
# part-way failure leaves: the declaration still names the key and the file does not.
# A flush that fails at close produces the same shape and no status in the chain sees
# it, which is why the read-back is a key SET rather than a last line.
for _c in pr-setup.sh loadlib.sh identitylib.sh; do cp "$SELF_DIR/$_c" "$_stage/$_c"; done
_forge_origin 'printf "%s\n" "git@github.com:acme/widget.git" > "$2/origin"'
grep -v 'rb_setup_put CODEX_BOT' "$SELF_DIR/pr-setup.sh" > "$_stage/pr-setup.sh"
_mw="$(mktemp -d "$TMP/mw.XXXXXX")/dir"
_mw_rc=0
_mw_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$_mw" 2>&1)" || _mw_rc=$?
{ [ "$_mw_rc" -eq 2 ] && case "$_mw_out" in *'reason=env_truncated'*) true ;; *) false ;; esac; } \
    && pass "an env file missing a declared key is refused, not announced ready" \
    || die "a missing middle key was announced ready (rc=$_mw_rc out='$_mw_out')"
[ ! -e "$_mw" ] \
    && pass "…and that refusal gives its directory back" \
    || die "the incomplete-env refusal left its directory behind"
cp "$SELF_DIR/pr-setup.sh" "$_stage/pr-setup.sh"

# ── a signal after the env write gives the reservation back ───────────────
# THE DEFAULT ACTION FOR `HUP`, `INT` AND `TERM` IS TO TERMINATE, so without a
# handler a signal arriving after `work/` and `env` exist leaves a non-empty
# published directory behind — carrying the session's origin — and the driver
# deliberately performs no cleanup after a non-zero helper status, because it cannot
# know who created the path. So the helper arms the cleanup before the reservation is
# attempted and disarms only on success.
#
# SELF-DELIVERED, so there is no timing in the fixture. The staged copy sends itself
# the signal at exactly the point the case is about — after the env write, before the
# `trap - EXIT` that a successful run reaches — which no `sleep`-and-`kill` can pin
# down as precisely.
for _c in pr-setup.sh loadlib.sh identitylib.sh; do cp "$SELF_DIR/$_c" "$_stage/$_c"; done
_forge_origin 'printf "%s\n" "git@github.com:acme/widget.git" > "$2/origin"'
for _sig in HUP INT TERM; do
    sed "s|^trap - EXIT\$|kill -s $_sig \"\$\$\"|" "$SELF_DIR/pr-setup.sh" > "$_stage/pr-setup.sh"
    grep -q "kill -s $_sig" "$_stage/pr-setup.sh" \
        || { die "the $_sig stage did not patch pr-setup.sh; the case proves nothing"; continue; }
    _sg="$(mktemp -d "$TMP/sg.XXXXXX")/dir"
    _sg_rc=0
    _sg_out="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$_stage/pr-setup.sh" "$_sg" 2>&1)" || _sg_rc=$?
    # THE STATUS SAYS IT DIED OF THE SIGNAL rather than returning from a handler. A
    # trap REPLACES a signal's terminating action, so one that merely returned would
    # leave the shell finishing the work it was killed during and reporting 0.
    [ "$_sg_rc" -ne 0 ] \
        && pass "a $_sig after the env write does not report success" \
        || die "the $_sig case returned 0 (out='$_sg_out')"
    [ ! -e "$_sg" ] \
        && pass "…and the reservation is given back rather than left with the origin in it" \
        || die "a $_sig left the published directory behind: $(ls -A "$_sg" 2>/dev/null | tr '\n' ' ')"
    rm -rf "$_sg"
done
cp "$SELF_DIR/pr-setup.sh" "$_stage/pr-setup.sh"

# ── the streams are separate ───────────────────────────────────────────────
# NOTHING BUT THE READY LINE ON STDOUT, and every reason on stderr. The driver
# reads one stream and never sees the other, which is what lets a caller capture
# the ready line without a refusal's diagnostics landing in the value.
_od="$(mktemp -d "$TMP/od.XXXXXX")/dir"
_out_only="$(cd "$REPO" && run_limited 25 /usr/bin/env bash -p "$SCRIPT" "$_od" 2>/dev/null)" || true
case "$_out_only" in
    "PR_SETUP status=ready env=$_od/env") pass "stdout carries the ready line and nothing else" ;;
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
# AND THE FILE IS NOT EXECUTABLE, so nothing can start it but a caller naming an
# interpreter. A privileged shebang would state a protection the file does not rely
# on and cannot enforce — the same exception `pr-origin.sh` carries, for the same
# reason, and `test-pr-identity.sh` asserts that one.
[ -x "$SCRIPT" ] \
    && pass "pr-setup.sh is executable, so its own privileged shebang is what starts it" \
    || die "pr-setup.sh is not executable; its #!/usr/bin/env -S bash -p shebang is inert"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
