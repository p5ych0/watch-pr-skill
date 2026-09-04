#!/usr/bin/env -S bash -p
# A last-resort refusal: `$-` proves the mode, not how the shell got there.
if [[ $- != *p* ]]; then
    echo "ABORT: the CI gate reason=not_privileged"
    exit 1
fi

# No `-e`: statuses are control flow here.
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "ABORT: the CI gate could not resolve its own directory"; exit 1; }
# The bootstrap cannot use the loader. The refusing stub is what stops an empty `loadlib.sh` from
# leaving `rb_load` to `PATH`, and the first load's 127 is the stub's rather than the loader's.
unset -f rb_load 2>/dev/null || {
    echo "ABORT: a pre-existing rb_load could not be cleared"; exit 1; }
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "ABORT: the library loader is unreadable"; exit 1; }
# `2>&1` because every diagnostic of this gate goes to stdout, and the loader reports on stderr.
rb_load "$_RB_SELF_DIR" recordlib sha_reason "ABORT: the CI gate" 2>&1 || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "ABORT: the CI gate reason=loadlib_empty"
    exit 1; }
rb_load "$_RB_SELF_DIR" clocklib rb_elapsed "ABORT: the CI gate" 2>&1 || exit 1

pr="${1:-}"; oid="${2:-}"
case "$pr" in
    ""|*[!0-9]*) echo "ABORT: the CI gate needs a PR number (got '$pr')"; exit 1 ;;
esac
_why="$(sha_reason "$oid")" || {
    echo "ABORT: the CI gate needs a head oid ($_why: '$oid')"; exit 1; }

iv="${PR_CI_INTERVAL:-30}" tmo="${PR_CI_TIMEOUT:-1800}" grace="${PR_CI_GRACE:-90}"
# A bad bound falls back to the default rather than removing the bound; a leading zero is octal.
case "$iv" in  ""|0|0*|*[!0-9]*|??????*) iv=30 ;; esac
case "$tmo" in ""|0*|*[!0-9]*|??????*)   tmo=1800 ;; esac
case "$grace" in ""|0*|*[!0-9]*|??????*) grace=90 ;; esac
probe="${PR_CI_PROBE_TIMEOUT:-60}"
case "$probe" in ""|0|0*|*[!0-9]*|??????*) probe=60 ;; esac

rc=0 elapsed=0 budget=0 nap=0 stable_rc="" stable_since=0
# Wall time through `clocklib.sh`: not the sum of the sleeps, which excludes the probes, and not
# `$SECONDS`, which no fixture can reach.
rb_elapsed start || { echo "ABORT: the CI gate could not read the clock; refusing to poll unbounded."; exit 1; }
while :; do
    rb_elapsed || { echo "ABORT: the CI gate lost the clock; refusing to poll unbounded."; exit 1; }
    elapsed="$RB_ELAPSED"
    # Checked before the probe as well as after it: an exhausted budget must not buy one more request.
    if [ "$elapsed" -ge "$tmo" ]; then
        echo "ABORT: the checks had not settled after ${tmo}s; do not close this round on an unknown state."
        exit 1
    fi
    # The remaining budget is passed down: a probe bounded only by its own default outlives a short timeout.
    budget=$((tmo - elapsed))
    [ "$budget" -gt "$probe" ] && budget="$probe"
    PR_CI_PROBE_TIMEOUT="$budget" /usr/bin/env bash -p "$_RB_SELF_DIR"/pr-ci-state.sh "$pr" --head "$oid"; rc=$?
    rb_elapsed || { echo "ABORT: the CI gate lost the clock; refusing to poll unbounded."; exit 1; }
    elapsed="$RB_ELAPSED"
    # A verdict that arrives after the deadline is not a verdict.
    if [ "$elapsed" -ge "$tmo" ]; then
        echo "ABORT: the checks had not settled after ${tmo}s; do not close this round on an unknown state."
        exit 1
    fi
    case "$rc" in
        0|4)
            # A closing answer must still hold `grace` seconds later: a second workflow can register
            # after the first has passed, and a run registers a moment after the head moves.
            if [ "$rc" = "$stable_rc" ] && [ $((elapsed - stable_since)) -ge "$grace" ]; then
                if [ "$rc" -eq 4 ]; then
                    echo "note: no checks are configured; the CI gate has nothing to assert"
                fi
                exit 0
            fi
            if [ "$rc" != "$stable_rc" ]; then stable_rc="$rc"; stable_since="$elapsed"; fi ;;
        1) echo "ABORT: the head you just pushed is RED. Fix it and push again; do not close this round."
           exit 1 ;;
        3|5) stable_rc=""; stable_since=0 ;;   # running, or the API has not caught up
        *) echo "ABORT: could not establish the check state (rc=$rc); do not close this round blind."
           exit 1 ;;
    esac
    # Capped at what is left, so the gate can report its own deadline in time.
    nap=$((tmo - elapsed))
    [ "$nap" -gt "$iv" ] && nap="$iv"
    sleep "$nap" || { echo "ABORT: the CI wait could not sleep; refusing to spin."; exit 1; }
done
