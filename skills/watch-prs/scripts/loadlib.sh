#!/usr/bin/env bash

# The prefix is the caller's whole error line (`pr-watch.sh` says `state=`), and the kind is
# taken rather than guessed: an exported value passes a non-empty test as an exported function passes `type -t`.
rb_load() {
    local dir="$1" lib="$2" sym="$3" prefix="$4" kind="${5:-func}"
    case "$kind" in
        func|var) ;;
        *) echo "$prefix reason=${lib}_bad_kind kind=$kind" >&2; return 2 ;;
    esac
    # A non-zero status from `unset` means a readonly definition survived the clear.
    if [ "$kind" = func ]; then
        unset -f "$sym" 2>/dev/null || {
            echo "$prefix reason=${lib}_stale_definition" >&2; return 2; }
    else
        unset "$sym" 2>/dev/null || {
            echo "$prefix reason=${lib}_stale_definition" >&2; return 2; }
    fi
    # shellcheck disable=SC1090
    . "$dir/$lib.sh" || {
        echo "$prefix reason=${lib}_unreadable" >&2; return 2; }
    # `type` is a name a shell function can shadow, and that is accepted here: every way of
    # asking whether a name is a function is one, and calling the symbol instead would run it.
    if [ "$kind" = func ]; then
        [ "$(type -t "$sym" 2>/dev/null)" = function ] || {
            echo "$prefix reason=${lib}_empty" >&2; return 2; }
    else
        [ -n "${!sym:-}" ] || {
            echo "$prefix reason=${lib}_empty" >&2; return 2; }
    fi
    return 0
}
