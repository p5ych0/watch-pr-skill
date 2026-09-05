#!/usr/bin/env bash
# A refusal rather than a re-exec: a `BASH_ENV` hook has already run by the time an unprivileged shell reaches
# this line, and the file is not executable, so `bash -p` is the caller's to supply.
if [[ $- != *p* ]]; then
    echo "ABORT: this shell is not privileged; invoke as /usr/bin/env bash -p pr-origin.sh <mode> <path>" >&2
    exit 1
fi
# No `-e`: statuses are control flow here.
set -uo pipefail

MODE="${1-}"
case "$MODE" in
    read|pin) ;;
    "") echo "ABORT: a mode is required: 'read' (origin's URL) or 'pin' (REVIEW_BUS_REMOTE as a child sees it)" >&2; exit 1 ;;
    *)  echo "ABORT: '$MODE' is not a mode; expected 'read' or 'pin'" >&2; exit 1 ;;
esac
# A directory this script creates, not a file the caller made a place for: the exclusion has to run where no
# function of the caller's, and no readonly, nameref, integer or case-converting attribute on the name, reaches it.
RB_DIR="${2-}"
[[ -n $RB_DIR ]] \
    || { echo "ABORT: pr-origin.sh writes its value into a directory it creates; invoke it as /usr/bin/env bash -p pr-origin.sh $MODE <dir>" >&2; exit 1; }
# Refused by name: a third argument dropped in silence would leave its caller believing it was honoured.
[[ $# -le 2 ]] \
    || { echo "ABORT: pr-origin.sh takes a mode and ONE directory; the optional fallback directory of 2.0.62 was removed in 2.0.63, and the caller retries with a second call instead" >&2; exit 1; }
# Named here, so there is no path the caller can be talked into passing.
case "$MODE" in
    read) OUT="$RB_DIR/origin" ;;
    pin)  OUT="$RB_DIR/pin" ;;
esac
# `set -C` makes each `>` below refuse a path that resolves to an existing regular file; `>|` is never
# used, since it overrides that. `umask 077` says who may write what the create makes.
umask 077
set -C
[[ $RB_DIR = /* ]] \
    || { echo "ABORT: the output directory must be absolute; '$RB_DIR' cannot be checked to the root" >&2; exit 1; }
# The walk starts one level up: the directory itself is trusted only through the exclusive `mkdir` below.
_rb_dir="${RB_DIR%/*}"
[[ -n $_rb_dir ]] || _rb_dir=/
# Every component to the root, by ownership as well as mode: an account that can rename anything on the way
# can replace the subtree, root is trusted, and a sticky world-writable directory is how `/tmp` passes.
_rb_walk() {
    local p="$1" bad frc next
    while : ; do
        # The probe's status is taken: a component renamed mid-probe makes `find` print nothing, which would read
        # as safe. `! -type l` on the mode clause only, since a symlink's own mode is `0777` everywhere.
        bad="$(find "$p" -prune \( \( ! -uid "$EUID" -a ! -uid 0 \) -o \( ! -type l -a \( -perm -g+w -o -perm -o+w \) -a ! -perm -1000 \) \) -print 2>/dev/null)"
        frc=$?
        if [[ $frc -ne 0 ]]; then
            echo "ABORT: could not examine '$p' on the way to the transport; refusing rather than assuming it is safe" >&2
            return 1
        fi
        if [[ -n $bad ]]; then
            echo "ABORT: '$p' is owned by another account, or writable by one and not sticky; the transport could be replaced between this write and the caller's read" >&2
            return 1
        fi
        # An ACL is a permission the mode bits do not show, and `ls -l` marks one with `+`; on macOS an `@` can
        # hide it, so either mark refuses.
        acl="$(ls -ld "$p" 2>/dev/null)"
        arc=$?
        if [[ $arc -ne 0 ]]; then
            echo "ABORT: could not read the permissions of '$p'; refusing rather than assuming it is safe" >&2
            return 1
        fi
        case "${acl%% *}" in
            *+|*@) echo "ABORT: '$p' is marked as carrying an access-control list or extended attributes, which the mode bits do not show; refusing rather than trusting a permission this cannot read" >&2
                return 1 ;;
        esac
        [[ $p = / ]] && break
        next="${p%/*}"
        [[ -n $next ]] || next=/
        [[ $next = "$p" ]] && break
        p="$next"
    done
    return 0
}
# Two facts, since `RB_OWNED` is set only after the `mkdir` returns and a signal during it is handled before that;
# `RB_PREEXISTED` records what `-e` saw at the name first, which a dangling symlink escapes.
RB_OWNED=no
RB_PREEXISTED=no
[[ -e $RB_DIR ]] && RB_PREEXISTED=yes
# `rmdir` alone, on every path out: it refuses a symlink and a non-empty directory, so a replaced reservation costs
# at most somebody else's empty directory, and a failed write leaves its leaf while the reservation stays non-empty.
rb_cleanup() {
    # `-O` refuses a resolved directory another account owns, which neither flag can see; a symlink is `rmdir`'s to refuse.
    [[ $RB_OWNED = yes ]] \
        || { [[ $RB_PREEXISTED = no ]] && [[ -d $RB_DIR ]] && [[ -O $RB_DIR ]]; } \
        || return 0
    [[ -d $RB_DIR ]] && [[ -O $RB_DIR ]] || return 0
    /usr/bin/env rmdir "$RB_DIR" 2>/dev/null
    return 0
}
rb_refuse() {
    [[ -n ${1-} ]] && echo "$1" >&2
    exit "${2:-1}"
}
# A trap replaces a signal's terminating action, so each handler re-raises after cleaning up; the traps are
# ignored before it, since a reset would leave the cleanup interruptible and one still armed would re-enter it.
rb_on_signal() {
    trap '' EXIT HUP INT TERM
    rb_cleanup
    trap - "$1"
    kill -s "$1" "$$"
}

# Armed before the `mkdir`, or a signal during that external command leaves the directory it created.
trap 'trap "" EXIT HUP INT TERM; rb_cleanup' EXIT
trap 'rb_on_signal HUP' HUP
trap 'rb_on_signal INT' INT
trap 'rb_on_signal TERM' TERM

# Reserved before it is walked, since the name is public in argv from exec and a watcher could take it during
# the walks. What this ordering does not close: the name taken before the `mkdir`, a refusal that fails closed.
/usr/bin/env mkdir -m 700 "$RB_DIR" 2>/dev/null && RB_OWNED=yes \
    || { _rb_walk "$_rb_dir" || exit 1
         # The resolved path too: a symlinked ancestor is the case the lexical walk cannot answer.
         _rb_fail_real="$(cd -P "$_rb_dir" 2>/dev/null && pwd -P)"
         [[ -n $_rb_fail_real ]] \
             || { echo "ABORT: could not resolve '$_rb_dir' to a physical path; refusing rather than checking a name that may not be where it leads" >&2; exit 1; }
         [[ $_rb_fail_real != "$_rb_dir" ]] \
             && { _rb_walk "$_rb_fail_real" || exit 1; }
         # Both walks passed, so the ancestry is sound and only the storage or the moment is implicated.
         echo "ABORT: could not create '$RB_DIR' exclusively; it already exists, or its parent refuses" >&2
         exit 2; }
# As written, where the symlinks live, and then as it resolves, where the file lives; symlinks cannot simply
# be refused, since macOS reaches its temporary directories through them.
_rb_walk "$_rb_dir" || rb_refuse
_rb_real="$(cd -P "$_rb_dir" 2>/dev/null && pwd -P)"
[[ -n $_rb_real ]] \
    || rb_refuse "ABORT: could not resolve '$_rb_dir' to a physical path; refusing rather than checking a name that may not be where it leads"
[[ $_rb_real = "$_rb_dir" ]] || _rb_walk "$_rb_real" || rb_refuse

# `env -i`, since `bash -p` keeps ordinary variables and a `GIT_DIR` would read another checkout's origin;
# `HOME`, `XDG_CONFIG_HOME` and every `GIT_CONFIG_*` are carried, because `insteadOf` rewrites live in global config.
_rb_env=( PATH="$PATH" HOME="${HOME-}" )
[[ -n ${XDG_CONFIG_HOME+x} ]] && _rb_env+=( XDG_CONFIG_HOME="$XDG_CONFIG_HOME" )
# By prefix, not by name, so the indexed runtime family arrives too; a set-but-empty value is carried as set,
# which is how git reads it.
for _rb_n in ${!GIT_CONFIG_@}; do
    _rb_env+=( "$_rb_n=${!_rb_n}" )
done
# One ordinary `git remote get-url origin` under the operator's own config, since re-deriving any part of that
# resolution diverges from git's. The fetch url is the identity `gh` is addressed by; the push url is not asked.
rb_read_origin() {
# The `x` keeps every byte `git` wrote, since command substitution strips trailing newlines and a remote can
# end in one; the status travels with it.
_rb_origin="$(/usr/bin/env -i "${_rb_env[@]}" \
    git remote get-url origin 2>/dev/null; _rb_s=$?; printf x; exit "$_rb_s")" || {
    rb_refuse "ABORT: could not read origin in $(command pwd 2>/dev/null)"; }
_rb_origin="${_rb_origin%x}"
# A literal newline in the pattern: `$(printf '\n')` strips its own and would match nothing.
_rb_origin="${_rb_origin%'
'}"
[[ -n $_rb_origin ]] || rb_refuse "ABORT: origin is empty; there is no repository to pin this session to"
# One line leaves this process: a remote holding a newline would cross as a multiline value, which is not one identity.
if [[ $_rb_origin != "${_rb_origin%%'
'*}" ]]; then
    rb_refuse "ABORT: origin contains a newline; it cannot be a single value"
fi
}

# A remote can carry `https://user:token@host/…` or a token in its query, and this goes to scrollback and logs;
# `%q` on the way out, since a planted remote can carry a carriage return or an escape that rewrites the diagnostic.
rb_redact() {
    local _u="$1" _scheme _rest _auth _path _out
    case "$_u" in
        *[?#]*) _u="${_u%%[?#]*}?***" ;;
    esac
    case "$_u" in
        *://*)
            _scheme="${_u%%://*}"; _rest="${_u#*://}"
            _path=""
            case "$_rest" in
                */*) _path="/${_rest#*/}"; _auth="${_rest%%/*}" ;;
                *)   _auth="$_rest" ;;
            esac
            case "$_auth" in
                # The last `@`: a password may contain one.
                *@*) _auth="***@${_auth##*@}" ;;
            esac
            _out="$_scheme://$_auth$_path" ;;
        # An SCP-like value keeps its login, which holds no secret.
        *)  _out="$_u" ;;
    esac
    printf '%q' "$_out"
}

if [[ $MODE = pin ]]; then
    # An empty pin is a real answer, "the export did not take", and needs no verification.
    if [[ -n ${REVIEW_BUS_REMOTE-} ]]; then
        # Compared with the checkout, not with the file setup wrote, which a racer may have replaced along with the value.
        rb_read_origin
        [[ $REVIEW_BUS_REMOTE = "$_rb_origin" ]] \
            || rb_refuse "ABORT: the pinned remote is not this checkout's origin (pinned '$(rb_redact "$REVIEW_BUS_REMOTE")', origin '$(rb_redact "$_rb_origin")'); the value the driver exported did not come from this repository"
    fi
    # The status is all there is: a target can open and then reject data, leaving zero bytes, which the caller
    # reads as the same empty value an unset pin gives, or a prefix that looks like a value.
    printf '%s\n' "${REVIEW_BUS_REMOTE-}" > "$OUT" \
        || rb_refuse "ABORT: could not create '$OUT' exclusively and write the pin; the name is already taken or is a symlink, or the storage refused the write" 2
    # Only `EXIT` is reset, since a successful run leaves the reservation for the caller.
    trap - EXIT
    exit 0
fi

rb_read_origin
printf '%s\n' "$_rb_origin" > "$OUT" \
    || rb_refuse "ABORT: could not create '$OUT' exclusively and write the origin; the name is already taken or is a symlink, or the storage refused the write" 2
trap - EXIT
exit 0
