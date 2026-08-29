#!/usr/bin/env -S bash -p
# Everything the driving session needs to start a run, done in a process and handed
# back as a file the driver SOURCES.
#
#   pr-setup.sh <dir>
#
#   0  <dir>/env is written and can be sourced
#   1  stopped — the reason is on stderr; nothing was written
#   2  the STORAGE would not take it — the directory could not be created
#      exclusively, or a write inside it failed. The caller retries under a second
#      parent; every other refusal is terminal, because another parent fixes none
#      of them. This is `pr-origin.sh`'s distinction and it is the same one.
#
# WHY THIS IS A SCRIPT AND NOT A FENCE IN `SKILL.md`.
#
# It was 178 executable lines of the document, read on every invocation of the
# skill — 18,450 characters, about a fifth of the whole thing — and nothing
# executed them. #26 closed on the finding that they could not move, because setup
# EXPORTS into the driving session and a child cannot export into its parent. That
# is true of a child's environment. It is not true of a file the driver sources: an
# assignment in a sourced file happens in the sourcing shell, which is the one
# property the block needed.
#
# WHAT STAYS IN THE DOCUMENT is what this cannot do for it: finding the scripts at
# all, choosing the parent directory to hand over, and the sourcing itself with the
# checks that follow it. See `SKILL.md` § Derive identity.
#
# WHAT THE CALLER MUST STILL DO, and the reason it is not done here:
#
#   - VALIDATE AFTER SOURCING. This writes the file; it cannot prove the file the
#     driver reads is the one it wrote. The driver re-derives the identity from the
#     sourced value and checks the shape of every path, so a file tampered with in
#     between is refused rather than trusted.
#   - REMOVE THE DIRECTORY. It is the caller's, by construction: this helper is
#     given a name and creates it, and it must survive the call for the source to
#     happen at all. A helper that removed it would be removing the thing it was
#     asked to produce.
#   - PROVE THE PIN. `pr-origin.sh pin` asks whether a CHILD sees this repository,
#     and the child that matters is one the driver starts. Proving it here would
#     prove that this process exports, which is true by construction.
#
# WHAT THE SOURCED FILE ASSIGNS IS DECLARED, not deduced. `pr-selfcheck.sh` scans
# `SKILL.md` for names it uses and never assigns, and since the setup values arrive
# by SOURCING they are assigned nowhere in that document — every one of them was
# reported as undefined. The declaration is the same mechanism a shared library
# uses there and for the same reason: reading a body and inferring what a
# successful run sets is a reachability analysis, and a wrong answer reads as "this
# variable is fine", which is the quiet direction. `rb-writes:` names the LEAF, so
# the scan binds a `. "$X/env"` in the document to this file rather than to a list
# somebody has to keep. `test-pr-setup.sh` proves the declaration matches the keys
# this actually writes, so a drifted one fails the suite instead of silently
# widening what the scan accepts.
#
# rb-writes: env
# rb-assigns: REVIEW_BUS_REMOTE RB_REMOTE OWNER REPO HOST CODEX_BOT COPILOT_BOT RB_WORK_DIR SUMMARY_FILE REQUEST_FILE PRIOR_FILE HEAD_FILE
#
# THE VALUES ARE QUOTED, and that is the whole safety of the arrangement. A remote
# URL is not this repository's text — a checkout can carry any origin, and a `git`
# config a driver never read can put a quote, a `$(…)`, a backtick or a newline in
# it. Every value is written single-quoted with `'` escaped as `'\''`, which has no
# expansion of any kind inside it, so the sourced line is an assignment and cannot
# be a command. `test-pr-setup.sh` stages each of those shapes against the real
# helper and asserts that what comes back through the source is the bytes that went
# in.
set -uo pipefail

case "$-" in
    *p*) ;;
    *) echo "PR_SETUP status=error reason=not_privileged" >&2; exit 1 ;;
esac

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_SETUP status=error reason=self_dir_unreadable" >&2; exit 1; }

unset -f rb_load 2>/dev/null || {
    echo "PR_SETUP status=error reason=rb_load_uncleared" >&2; exit 1; }
# THE REFUSING STUB, spelled the way every other helper spells it. It is what stops
# `PATH` answering in the loader's place: an undefined `rb_load` is looked up as a
# command, and an executable by that name exiting 0 reports every load successful
# with nothing cleared and no library sourced. The FIRST LOAD is the verification —
# calling an empty `loadlib.sh` leaves this stub, and calling it fails. `return` is
# a builtin nothing can shadow here, because a privileged shell imports no
# functions. #88.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" 2>/dev/null || {
    echo "PR_SETUP status=error reason=loadlib_unreadable" >&2; exit 1; }
rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_SETUP status=error" || exit 1

# WHAT IS REFUSED IS THE SHAPE, NOT THE CHARACTERS. A character class was here —
# `*[!/A-Za-z0-9._-]*` — and it was a regression against the inline setup it
# replaced: the driver builds this name under `$TMPDIR` or `$HOME`, an operator's
# home directory can contain a SPACE, and `bad_dir` is TERMINAL, so a usable second
# parent was never tried and the session ended on a path that works. `pr-origin.sh`
# takes the same kind of argument and restricts no character, which is the shape to
# match. Nothing here ever evaluates the value: it is quoted in the `mkdir`, in
# every redirection and in every `printf`, so an ordinary filesystem character is
# data. What is left is what the checks were for — a value that is missing, one that
# is relative, and one carrying a `..` component.
RB_DIR="${1-}"
case "$RB_DIR" in
    "" | */../* | */..)
        echo "PR_SETUP status=error reason=bad_dir" >&2; exit 1 ;;
    /*) ;;
    *)  echo "PR_SETUP status=error reason=dir_not_absolute" >&2; exit 1 ;;
esac
[ "$#" -eq 1 ] || { echo "PR_SETUP status=error reason=usage" >&2; exit 1; }

# THE DIRECTORY IS THE RESERVATION. `mkdir` without `-p` fails if anything is
# already at the name — a file, a symlink or another account's directory — so the
# exclusion is the create, not a test before it. Same rule as `pr-origin.sh`, and
# for the same reason: a check-then-use here is a window somebody else can stand in.
/usr/bin/env mkdir -m 700 "$RB_DIR" 2>/dev/null || {
    echo "PR_SETUP status=error reason=dir_not_reserved dir=$RB_DIR" >&2; exit 2; }

# FROM HERE A FAILURE TAKES THE DIRECTORY WITH IT. The caller retries under another
# parent on status 2 and stops on 1; either way what this leaves behind must not be
# a half-written env file that a later source would read.
#
# NOT `rm -rf`, AND THAT IS THE WHOLE SHAPE OF THIS FUNCTION. The name is published
# in argv before the `mkdir` reserves it, and under a parent without the sticky bit
# another account can replace the directory AFTER the reservation. A recursive
# removal then deletes the replacement and everything in it — which is far past what
# `docs/decisions/2026-08-26-reservation-inference.md` accepts, and that record rests
# on `rmdir` REFUSING anything with contents in it. So this removes the objects this
# run named, one at a time, and takes directories away with `rmdir` alone: a
# replacement carrying anything else survives, and is left for its owner.
#
# `RB_PHASE` PICKS BETWEEN TWO SHAPES, as `pr-origin.sh` does and for the same
# reason. Until a write has happened nothing can be inside, so `rmdir` ALONE is
# correct and is what the accepted record describes — it refuses a symlink outright,
# which is what makes it safe on a name this run may no longer own. Once a write has
# happened `rmdir` necessarily fails on a directory holding its leaf, so the leaves
# go first, by name.
RB_PHASE=reserved
rb_setup_give_back() {
    if [ "$RB_PHASE" = written ]; then
        /usr/bin/env rm -f "$RB_DIR/env" "$RB_DIR/o/origin" 2>/dev/null
        /usr/bin/env rmdir "$RB_DIR/o" 2>/dev/null
        for _g in summary.md request.md prior.txt head.txt; do
            /usr/bin/env rm -f "$RB_DIR/work/$_g" 2>/dev/null
        done
        /usr/bin/env rmdir "$RB_DIR/work" 2>/dev/null
    fi
    /usr/bin/env rmdir "$RB_DIR" 2>/dev/null
    return 0
}
rb_setup_stop() {   # <reason> <status>
    echo "PR_SETUP status=error reason=$1" >&2
    rb_setup_give_back
    exit "$2"
}

# ── the origin, through the helper that reads it privileged ────────────────
# NOT `git remote get-url` HERE. `pr-origin.sh` is where that read is hardened, and
# a second copy of it is the duplication `CLAUDE.md` records paying for four times.
# THE PHASE FLIPS BEFORE THE CALL, not after it: `pr-origin.sh` creates `$RB_DIR/o`
# and leaves it for this caller, so from the moment it is started something can be
# inside — and a refusal between the two is exactly when the cleanup has to know.
RB_PHASE=written
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-origin.sh read "$RB_DIR/o" || {
    _rc=$?
    [ "$_rc" -eq 2 ] && rb_setup_stop origin_storage 2
    rb_setup_stop origin_unreadable 1
}
RB_REMOTE=""
RB_REMOTE="$(cat "$RB_DIR/o/origin" 2>/dev/null)" || rb_setup_stop origin_transport 1
# BY NAME AND THEN `rmdir`, for the reason the cleanup gives: this path is inside a
# directory whose name was published in argv, and a recursive removal on it deletes
# whatever a replacement holds.
/usr/bin/env rm -f "$RB_DIR/o/origin" 2>/dev/null
/usr/bin/env rmdir "$RB_DIR/o" 2>/dev/null

[ -n "$RB_REMOTE" ] || rb_setup_stop origin_empty 1
# `$'\n'`, NOT `"$(printf '\n')"`. Command substitution strips trailing newlines, so
# that spelling is the EMPTY string and the pattern `*""*` matches every value —
# which reported every origin multi-line. Caught by running this against a real
# checkout before it had a fixture.
[[ $RB_REMOTE == *$'\n'* ]] && rb_setup_stop origin_multiline 1

# THE IDENTITY IS PROVEN HERE, so the driver sources a value that already parses.
# It re-derives it anyway — see the header — but a remote that cannot be an identity
# should never reach a file the driver will source.
REVIEW_BUS_REMOTE="$RB_REMOTE" rb_identity || {
    echo "PR_SETUP status=error reason=origin_unusable detail=${RB_IDENTITY_REASON:-}" >&2
    rb_setup_give_back
    exit 1
}

# THE PIN IS NOT PROVEN HERE, AND CANNOT BE. `pr-origin.sh pin` answers "does a
# child see this repository as its identity", and the child that matters is one the
# DRIVER starts — every stage of the loop is a process the driving shell forks. A
# pin proved inside this helper would be proving that THIS process exports, which is
# true by construction and says nothing about the shell that sources the file.
#
# So it stays in `SKILL.md`, immediately after the source, where the export it is
# about has just happened. It is one call and one comparison there rather than the
# probe-and-retry it used to be, because this helper has already made the directory
# it needs.

# ── the working files ──────────────────────────────────────────────────────
# FOUR FILES, FROM ONE ALLOCATION, and files rather than shell variables: the text
# is long, contains backticks and quotes, and passing it inline mangles it — while a
# variable is a name a startup file can have made readonly. They are created fresh
# per session, because a reused path is how a stale summary from another round, or
# another pull request, gets posted as if it were this one's.
#
# ONE DIRECTORY AND FOUR PATHS DERIVED FROM IT, not four `mktemp` calls: those would
# be four separate answers, and `mktemp` is a NAME — a function returning the same
# existing empty path each time passes every validation and leaves all four aliased.
#
# WHY THEY ARE FOUR AND NOT FEWER:
#
#   - the round summary must be EMPTY until the round writes it. Sharing one file
#     with the opening account meant a first round whose summary write did not
#     happen left the opening account sitting there — non-empty, well-formed and
#     about the right PR — so `pr-close-round.sh` posted it as the round summary and
#     requested the next pass instead of refusing to close;
#   - the gated head travels in a file because it used to travel in an assignment
#     the driver made AFTER the push, and a readonly name fails that silently —
#     `post` was then handed a head the gate never reported (#202);
#   - the review baseline is a file for the same reason.
#
# CREATED EMPTY BY REDIRECTION ALONE — no command name, so there is none to shadow,
# and a redirection that cannot be made reports it. Each is then proven present and
# empty: a missing one fails closed later anyway, but "fails closed later" is not a
# reason to be unable to say so here.
RB_WORK_DIR="$RB_DIR/work"
/usr/bin/env mkdir -m 700 "$RB_WORK_DIR" 2>/dev/null || rb_setup_stop work_dir 2
for _f in summary.md request.md prior.txt head.txt; do
    : > "$RB_WORK_DIR/$_f" || rb_setup_stop work_files 2
    { [ -f "$RB_WORK_DIR/$_f" ] && [ ! -s "$RB_WORK_DIR/$_f" ]; } \
        || rb_setup_stop work_files_not_empty 2
done

# ── the file the driver sources ────────────────────────────────────────────
# SINGLE QUOTES WITH `'` ESCAPED, and nothing else. Inside single quotes bash
# expands nothing at all — no `$`, no backtick, no backslash — so a value containing
# any of them is data. The escape is the one sequence single quotes cannot hold:
# close, an escaped quote, reopen.
rb_setup_q() {   # <value> ; prints it single-quoted for a shell to read back
    local _v="${1-}"
    printf "'%s'" "${_v//\'/\'\\\'\'}"
    return 0
}
# EVERY WRITE'S STATUS IS PRESERVED, and that needs the `&&` chain rather than a
# list of commands in a group. `{ a; b; c; } > f` reports only C's status: a
# `printf` that failed in the middle while a later one succeeded was a group that
# reported SUCCESS, and the read-back below could not see it either, because the
# line it checks for is the last one. Losing `CODEX_BOT` that way lets setup
# announce ready with no reviewer login, after which the watch polls for a bot
# nobody named.
rb_setup_put() {   # <name> <value> ; one assignment line, with its status
    printf '%s=%s\n' "$1" "$(rb_setup_q "$2")" || return 1
    return 0
}
{
    rb_setup_put REVIEW_BUS_REMOTE "$RB_REMOTE" \
    && printf 'export REVIEW_BUS_REMOTE\n' \
    && rb_setup_put RB_REMOTE    "$RB_REMOTE" \
    && rb_setup_put OWNER        "$OWNER" \
    && rb_setup_put REPO         "$REPO" \
    && rb_setup_put HOST         "$HOST" \
    && rb_setup_put CODEX_BOT    'chatgpt-codex-connector[bot]' \
    && rb_setup_put COPILOT_BOT  'copilot-pull-request-reviewer[bot]' \
    && rb_setup_put RB_WORK_DIR  "$RB_WORK_DIR" \
    && rb_setup_put SUMMARY_FILE "$RB_WORK_DIR/summary.md" \
    && rb_setup_put REQUEST_FILE "$RB_WORK_DIR/request.md" \
    && rb_setup_put PRIOR_FILE   "$RB_WORK_DIR/prior.txt" \
    && rb_setup_put HEAD_FILE    "$RB_WORK_DIR/head.txt"
} > "$RB_DIR/env" || rb_setup_stop env_write 2

# AND THE COMPLETE KEY SET IS READ BACK, because taking the statuses is not enough
# on its own: stdio buffers, so a `printf` can report success and the write fail at
# the flush when the redirection is closed — which no status in the chain sees.
# Checking for the LAST line alone was the previous shape and it has the same hole
# from the other end: any earlier line can be missing while `HEAD_FILE=` is present.
#
# THE EXPECTED SET IS THE `rb-assigns:` DECLARATION IN THIS FILE, not a list written
# out a second time. That declaration is already the contract `pr-selfcheck.sh`
# credits `SKILL.md` with, and `test-pr-setup.sh` proves it equals the keys a real
# run writes — so a name added to the writes above and not to the declaration fails
# the suite, and one added to neither is a name the driver was never promised.
[ -s "$RB_DIR/env" ] || rb_setup_stop env_empty 2
_want="$(grep -oE '^# rb-assigns:[A-Za-z0-9_ ]*' "${BASH_SOURCE[0]}" 2>/dev/null \
    | sed -E 's/^# rb-assigns:[[:space:]]*//' | tr ' ' '\n' | grep -vE '^$' | sort -u)" \
    || _want=""
[ -n "$_want" ] || rb_setup_stop env_undeclared 1
_got="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$RB_DIR/env" 2>/dev/null \
    | sed 's/=$//' | sort -u)" || _got=""
[ "$_want" = "$_got" ] || rb_setup_stop env_truncated 2

echo "PR_SETUP status=ready env=$RB_DIR/env"
exit 0
