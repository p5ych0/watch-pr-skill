#!/usr/bin/env -S bash -p
# No `-e`: statuses are control flow here.
set -uo pipefail

# A last-resort refusal: `$-` proves the mode, not how the shell got there.
case "$-" in
    *p*) ;;
    *) echo "PR_SETUP status=error reason=not_privileged" >&2; exit 1 ;;
esac

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_SETUP status=error reason=self_dir_unreadable" >&2; exit 1; }

unset -f rb_load 2>/dev/null || {
    echo "PR_SETUP status=error reason=rb_load_uncleared" >&2; exit 1; }
# The bootstrap cannot use the loader. The refusing stub is what stops an empty `loadlib.sh` from
# leaving `rb_load` to `PATH`, and the first load's 127 is the stub's rather than the loader's.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" 2>/dev/null || {
    echo "PR_SETUP status=error reason=loadlib_unreadable" >&2; exit 1; }
rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_SETUP status=error" || exit 1

# Only the shape is refused: a missing name, or a relative one, which is not stable across processes
# that need not share a working directory; any character is data, quoted everywhere and never evaluated.
RB_DIR="${1-}"
case "$RB_DIR" in
    "") echo "PR_SETUP status=error reason=bad_dir" >&2; exit 1 ;;
    /*) ;;
    *)  echo "PR_SETUP status=error reason=dir_not_absolute" >&2; exit 1 ;;
esac
[ "$#" -eq 1 ] || { echo "PR_SETUP status=error reason=usage" >&2; exit 1; }

# Nothing is removed on any path (`docs/decisions/2026-08-29-setup-leaf-cleanup.md`), and only `INT`
# is trapped: delivered while this waits on a child it is survived, and a stopped session would report ready.
trap 'trap - INT; kill -INT "$$"' INT

rb_setup_stop() {
    echo "PR_SETUP status=error reason=$1" >&2
    exit "$2"
}

/usr/bin/env mkdir -m 700 "$RB_DIR" 2>/dev/null \
    || { echo "PR_SETUP status=error reason=dir_not_reserved dir=$RB_DIR" >&2; exit 2; }
# Through `pr-origin.sh`, the one place the origin read is hardened.
/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-origin.sh read "$RB_DIR/o" || {
    _rc=$?
    [ "$_rc" -eq 2 ] && rb_setup_stop origin_storage 2
    rb_setup_stop origin_unreadable 1
}
RB_REMOTE=""
RB_REMOTE="$(cat "$RB_DIR/o/origin" 2>/dev/null)" || rb_setup_stop origin_transport 1

[ -n "$RB_REMOTE" ] || rb_setup_stop origin_empty 1
# `$'\n'`, not `"$(printf '\n')"`: a substitution strips the newline and the pattern then matches everything.
[[ $RB_REMOTE == *$'\n'* ]] && rb_setup_stop origin_multiline 1

# Proven here so the driver reads a value that already parses; it re-derives the identity anyway.
REVIEW_BUS_REMOTE="$RB_REMOTE" rb_identity || {
    echo "PR_SETUP status=error reason=origin_unusable detail=${RB_IDENTITY_REASON:-}" >&2
    exit 1
}

# `set -C` refuses a working-file path that resolves to an existing regular file, so a planted link cannot
# have one truncated through it; `umask 077` says who may write what the open created. `>|` is never used.
umask 077
set -C
RB_WORK_DIR="$RB_DIR/work"
/usr/bin/env mkdir -m 700 "$RB_WORK_DIR" 2>/dev/null || rb_setup_stop work_dir 2
for _f in summary.md request.md prior.txt head.txt; do
    : > "$RB_WORK_DIR/$_f" || rb_setup_stop work_files 2
    { [ -f "$RB_WORK_DIR/$_f" ] && [ ! -s "$RB_WORK_DIR/$_f" ]; } \
        || rb_setup_stop work_files_not_empty 2
done

# The origin alone crosses, written raw and read as data: nothing evaluates it, so there is no quoting.
printf '%s\n' "$RB_REMOTE" > "$RB_DIR/origin" || rb_setup_stop origin_write 2

# `printf` can report success and the write fail at the flush, so the file is read back and compared,
# with the read's own status taken apart from the comparison.
[ -s "$RB_DIR/origin" ] || rb_setup_stop origin_write 2
_rb_back=""
_rb_back="$(cat "$RB_DIR/origin" 2>/dev/null)" || rb_setup_stop origin_write 2
[ "$_rb_back" = "$RB_REMOTE" ] || rb_setup_stop origin_write 2


_mode=attended
[ "${WATCH_PR_AUTONOMOUS:-}" = 1 ] && _mode=unattended
echo "PR_SETUP status=ready origin=$RB_DIR/origin work=$RB_WORK_DIR mode=$_mode"
exit 0
