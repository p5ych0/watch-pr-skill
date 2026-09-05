#!/usr/bin/env -S bash -p
# A last-resort refusal: `$-` proves the mode, not how the shell got there.
if [[ $- != *p* ]]; then
    echo "PR_REVIEW_WATCH state=error reason=not_privileged" >&2
    exit 2
fi

# No `-e`: statuses are control flow here.
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_REVIEW_WATCH state=error reason=lib_dir_unresolvable" >&2; exit 2; }
# The bootstrap cannot use the loader. The refusing stub is what stops an empty `loadlib.sh` from
# leaving `rb_load` to `PATH`, and the first load's 127 is the stub's rather than the loader's.
unset -f rb_load 2>/dev/null || {
    echo "PR_REVIEW_WATCH state=error reason=loadlib_stale_definition" >&2; exit 2; }
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_REVIEW_WATCH state=error reason=loadlib_unreadable" >&2; exit 2; }
# `state=` rather than `status=`: the loader takes the prefix so each caller keeps its own shape.
rb_load "$_RB_SELF_DIR" recordlib is_full_sha "PR_REVIEW_WATCH state=error" || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "PR_REVIEW_WATCH state=error reason=loadlib_empty" >&2
    exit 2; }
rb_load "$_RB_SELF_DIR" recordlib rb_review_record "PR_REVIEW_WATCH state=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_replies_only_line "PR_REVIEW_WATCH state=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib rb_review_record_is_about "PR_REVIEW_WATCH state=error" || exit 2
rb_load "$_RB_SELF_DIR" clocklib rb_elapsed "PR_REVIEW_WATCH state=error" || exit 2
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "PR_REVIEW_WATCH state=error" var || exit 2
rb_load "$_RB_SELF_DIR" recordlib RB_COPILOT_BOT "PR_REVIEW_WATCH state=error" var || exit 2

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Started privileged at every call site rather than folded in here, since an override may name a stub.
STATE_SCRIPT="${PR_WATCH_STATE_SCRIPT:-$SELF_DIR/pr-review-state.sh}"

INTERVAL="${PR_WATCH_INTERVAL:-30}"
TIMEOUT="${PR_WATCH_TIMEOUT:-3600}"
PROBE_TIMEOUT="${PR_WATCH_PROBE_TIMEOUT:-60}"
PR=""
WHO=""
AFTER_REVIEW=""
AFTER_REVIEW_FILE=""
# Supplied-ness tracked apart from the value: an empty `--after-review ""` is legitimate, so
# emptiness cannot mean "not given".
AFTER_REVIEW_GIVEN=""
REQUIRE_NONCE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --require-nonce) [ "$#" -ge 2 ] || { echo "$0: --require-nonce needs a value" >&2; exit 2; }
                    case "$2" in
                        ""|*[!0-9]*) echo "$0: --require-nonce needs decimal digits, and was given '$2'" >&2; exit 2 ;;
                    esac
                    REQUIRE_NONCE="$2"; shift 2 ;;
        # A missing value is usage: `shift 2 || true` would leave the option in `$1` and spin.
        --interval) [ "$#" -ge 2 ] || { echo "$0: --interval needs a value" >&2; exit 2; }
                    INTERVAL="$2"; shift 2 ;;
        --timeout)  [ "$#" -ge 2 ] || { echo "$0: --timeout needs a value" >&2; exit 2; }
                    TIMEOUT="$2"; shift 2 ;;
        # The review id observed before the request: a re-request on an unchanged head has nothing
        # else to tell the new pass from the old one.
        --after-review) [ "$#" -ge 2 ] || { echo "$0: --after-review needs a value" >&2; exit 2; }
                    AFTER_REVIEW="$2"; AFTER_REVIEW_GIVEN=yes; shift 2 ;;
        # The same value for a caller that cannot hold one; an empty path is refused here, since an
        # empty value would skip the read and run the watch with no baseline at all.
        --after-review-file) [ "$#" -ge 2 ] || { echo "$0: --after-review-file needs a value" >&2; exit 2; }
                    [ -n "$2" ] || { echo "$0: --after-review-file needs a path, and was given an empty one" >&2; exit 2; }
                    AFTER_REVIEW_FILE="$2"; shift 2 ;;
        -*) echo "usage: $0 <pr> <reviewer-login> [--interval S] [--timeout S]" >&2; exit 2 ;;
        *) if [ -z "$PR" ]; then PR="$1"; elif [ -z "$WHO" ]; then WHO="$1"; fi; shift ;;
    esac
done

# Leading zeros are refused: records are matched against `$PR` as a string.
case "$PR" in
    ""|0|0*|*[!0-9]*) echo "usage: $0 <pr> <reviewer-login> [--interval S] [--timeout S]" >&2; exit 2 ;;
esac
[ -n "$WHO" ] || { echo "usage: $0 <pr> <reviewer-login> [--interval S] [--timeout S]" >&2; exit 2; }
# A bad value falls back to the default: a zero interval would spin, a leading zero is octal, and a
# value beyond the integer range wraps inside the arithmetic below; a zero timeout is kept and expires at once.
case "$INTERVAL" in 0|0*|*[!0-9]*|""|??????????*) INTERVAL=30 ;; esac
case "$TIMEOUT"  in 0) ;; 0*|*[!0-9]*|""|??????????*) TIMEOUT=3600 ;; esac
case "$PROBE_TIMEOUT" in 0|0*|*[!0-9]*|""|??????????*) PROBE_TIMEOUT=60 ;; esac

# `%q` folds newlines, so nothing a helper prints can forge a `PR_REVIEW_READY` line of its own.
q() { printf '%q' "$1"; }

# An unrecognised login would poll to the deadline and be re-armed as a slow reviewer, forever.
case "$WHO" in
    "$RB_CODEX_BOT"|"$RB_COPILOT_BOT") ;;
    *) echo "PR_REVIEW_WATCH pr=$PR reviewer=$(q "$WHO") state=error reason=unknown_reviewer" >&2
       exit 2 ;;
esac


# An absolute deadline through `clocklib.sh`, not the sum of the sleeps.
rb_elapsed start || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
# A variable rather than stdout: called through a substitution, the clock's monotonic state would
# live in a subshell and be lost.
ELAPSED=0
elapsed_s() {
    rb_elapsed || return 1
    ELAPSED="$RB_ELAPSED"
    return 0
}

# Bounded by the limit the caller took from the deadline and the per-probe bound, in its own process
# group so the kill reaches what `gh` spawned; `mktemp`, since a predictable name under `/tmp` can be pre-linked.
probe() {
    local limit="$1"; shift
    [ "$limit" -gt 0 ] || limit=1
    local out rc pid tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/pr-watch.XXXXXX")" || {
        echo "PR_REVIEW_WATCH state=error reason=no_probe_buffer" >&2
        return 125
    }
    set -m
    ( "$@" ) >"$tmp" 2>&1 &
    pid=$!
    set +m
    # Fractional ticks where the platform allows, so a fast answer does not cost a whole second.
    local tick ticks n=0
    if sleep 0.2 2>/dev/null; then tick=0.2; ticks=$(( limit * 5 ))
    else tick=1; ticks="$limit"; fi
    while [ "$n" -lt "$ticks" ]; do
        kill -0 -"$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null || break
        # A failed `sleep` kills and reaps the probe first; otherwise every re-arm leaves another `gh` open.
        sleep "$tick" || {
            kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            rm -f "$tmp" 2>/dev/null
            return 125
        }
        n=$((n + 1))
    done
    if kill -0 -"$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null; then
        kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rm -f "$tmp" 2>/dev/null
        return 124
    fi
    wait "$pid"; rc=$?
    # The child's own 124 or 125 is unreadable, not a timeout: status 1 is re-armed indefinitely.
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 125 ]; then
        rm -f "$tmp" 2>/dev/null
        echo "PR_REVIEW_WATCH state=error reason=probe_unreadable child_rc=$rc" >&2
        exit 2
    fi
    # The read has its own status, taken before `rm` overwrites it.
    local crc
    out="$(cat "$tmp" 2>/dev/null)"; crc=$?
    rm -f "$tmp" 2>/dev/null
    [ "$crc" -eq 0 ] || return 125
    printf '%s' "$out"
    return "$rc"
}

# A probe that hit the remaining deadline is the timeout, not an unreadable state; a clock this
# cannot read is, since status 1 would be re-armed.
timed_out() {
    elapsed_s || {
        echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=clock_unreadable" >&2
        exit 2
    }
    printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=timeout waited_s=%s\n' "$PR" "$WHO" "$ELAPSED"
    exit 1
}

# An exhausted remainder is the timeout, not one more second.
REMAINING=0
remaining_s() {
    elapsed_s || return 1
    local r=$(( TIMEOUT - ELAPSED ))
    [ "$r" -lt 1 ] && return 2
    REMAINING="$r"
    return 0
}

# The smaller of the deadline and the per-probe bound: bounded by the deadline alone, a `gh` stalled
# on a dead connection ran to it and the watch reported an ordinary timeout with the review already there.
LIM=0
probe_limit() {
    remaining_s || return $?
    LIM="$REMAINING"
    [ "$PROBE_TIMEOUT" -lt "$LIM" ] && LIM="$PROBE_TIMEOUT"
    return 0
}

# A probe that hit its own bound short of the deadline is retried on a fresh process; one that hit
# the deadline is the timeout.
stalled() {
    [ "$LIM" -lt "$REMAINING" ] || timed_out
    elapsed_s || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    waited="$ELAPSED"
    printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=probe_stalled probe=%s limit_s=%s waited_s=%s\n' \
        "$PR" "$WHO" "$1" "$LIM" "$waited"
    last=""
}

# Both spellings at once is a refusal rather than a precedence; the file form requires the nonce
# and the value form refuses it, since a hardened caller holding the id has nothing to bind.
if [ -n "$AFTER_REVIEW_FILE" ] && [ -n "$AFTER_REVIEW_GIVEN" ]; then
    echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=after_review_both_forms" >&2
    exit 2
fi
if [ -n "$AFTER_REVIEW_FILE" ] && [ -z "$REQUIRE_NONCE" ]; then
    echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=nonce_required detail=$(q "$AFTER_REVIEW_FILE")" >&2
    exit 2
fi
if [ -n "$REQUIRE_NONCE" ] && [ -z "$AFTER_REVIEW_FILE" ]; then
    echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=nonce_without_file" >&2
    exit 2
fi
# Bounded, since a FIFO at the path blocks before any test can run; `read -d ""` makes a NUL a
# refusal rather than a dropped byte, and the trailing newline is kept through a sentinel as the completion delimiter.
if [ -n "$AFTER_REVIEW_FILE" ]; then
    # A short limit capped by what is left, so a stuck open and an expired watch stay two answers;
    # an expired deadline still runs the read, since a bad argument is bad whatever the clock says.
    remaining_s; _bl_rrc=$?; _bl_rem="$REMAINING"
    _bl_expired=
    [ "$_bl_rrc" -eq 2 ] && { _bl_expired=yes; _bl_rem=0; }
    { [ "$_bl_rrc" -eq 0 ] || [ -n "$_bl_expired" ]; } \
        || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    _bl_lim=10
    [ "$_bl_rem" -lt "$_bl_lim" ] && _bl_lim="$_bl_rem"
    [ "$_bl_lim" -lt 1 ] && _bl_lim=1
    # Chained with `&&`, so a data write that failed part-way leaves no sentinel and the child exits non-zero.
    _bl_out="$(probe "$_bl_lim" /usr/bin/env bash -p -c '
        { [ -f /dev/fd/9 ] || exit 6
          IFS= read -r -d "" _r <&9
          _s=$?
        } 9<"$1" || exit 4
        [ "$_s" -eq 0 ] && exit 5
        printf %s "$_r" && printf x' _ "$AFTER_REVIEW_FILE")"; _bl_rc=$?
    [ "$_bl_rc" -eq 0 ] && _bl_out="${_bl_out%x}"
    case "$_bl_rc" in
        # An empty file is a refusal, "no prior review" being spelled `none`; a value without the writer's
        # newline is a truncated write, however well-formed it looks.
        0) case "$_bl_out" in
               "") echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=empty_after_review_file detail=$(q "$AFTER_REVIEW_FILE")" >&2
                   exit 2 ;;
               *"
")  while :; do
                       case "$_bl_out" in
                           *"
")  _bl_out="${_bl_out%
}" ;;
                           *) break ;;
                       esac
                   done ;;
               *) echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=unterminated_after_review_file detail=$(q "$AFTER_REVIEW_FILE")" >&2
                  exit 2 ;;
           esac
           # A file holding only the delimiter strips to nothing, which is not "no floor" either.
           case "$_bl_out" in
               "") echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=empty_after_review_file detail=$(q "$AFTER_REVIEW_FILE")" >&2
                   exit 2 ;;
           esac
           case "$_bl_out" in
               *" "*) ;;
               *) echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=baseline_without_nonce detail=$(q "$AFTER_REVIEW_FILE")" >&2
                  exit 2 ;;
           esac
           _bl_nonce="${_bl_out%% *}"
           _bl_out="${_bl_out#* }"
           [ "$_bl_nonce" = "$REQUIRE_NONCE" ] \
               || { echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=stale_baseline_nonce detail=$(q "$AFTER_REVIEW_FILE")" >&2
                    exit 2; }
           case "$_bl_out" in
               "") echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=empty_after_review_file detail=$(q "$AFTER_REVIEW_FILE")" >&2
                   exit 2 ;;
           esac
           case "$_bl_out" in
               none) AFTER_REVIEW="" ;;
               *) AFTER_REVIEW="$_bl_out" ;;
           esac ;;
        5) echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=after_review_file_nul detail=$(q "$AFTER_REVIEW_FILE")" >&2
           exit 2 ;;
        6) echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=after_review_file_not_regular detail=$(q "$AFTER_REVIEW_FILE")" >&2
           exit 2 ;;
        # An expiry is asked which deadline it hit: the watch's own is the ordinary timeout, a clock
        # it cannot read is unreadable, and otherwise the read itself is stuck.
        124) remaining_s; _bl_r3=$?
             [ "$_bl_r3" -eq 2 ] && timed_out
             [ "$_bl_r3" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
             echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=after_review_file_blocked detail=$(q "$AFTER_REVIEW_FILE")" >&2
             exit 2 ;;
        *) echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=after_review_file_unreadable detail=$(q "$AFTER_REVIEW_FILE")" >&2
           exit 2 ;;
    esac
    # Proved here rather than at the first terminal state, which may be an hour away.
    case "$AFTER_REVIEW" in
        ""|*[0-9]) ;;
        comment:*[0-9]) ;;
        *) echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=malformed_review_id detail=$(q "$AFTER_REVIEW")" >&2
           exit 2 ;;
    esac
    case "${AFTER_REVIEW#comment:}" in
        ""|*[!0-9]*) [ -z "$AFTER_REVIEW" ] || {
              echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=malformed_review_id detail=$(q "$AFTER_REVIEW")" >&2
              exit 2; } ;;
    esac
    # Reported after the baseline is proved, so a caller error is not re-armed as a slow reviewer.
    [ -n "$_bl_expired" ] && timed_out
fi
waited=0
last=""
while :; do
    # One head per poll, resolved first and passed to both probes: two heads can share a seven-hex
    # prefix, so the records' abbreviated fields cannot prove the probes answered about the same one.
    probe_limit; rrc=$?
    [ "$rrc" -eq 2 ] && timed_out
    [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    head="$(probe "$LIM" /usr/bin/env bash -p "$STATE_SCRIPT" head "$PR")"; hrc=$?
    [ "$hrc" -eq 124 ] && { stalled head; continue; }
    [ "$hrc" -eq 125 ] && { echo "PR_REVIEW_WATCH state=error reason=probe_unreadable" >&2; exit 2; }
    if [ "$hrc" -ne 0 ] || ! is_full_sha "$head"; then
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=head_unresolvable rc=%s detail=%s\n' \
            "$PR" "$WHO" "$hrc" "$(q "$head")"
        exit 2
    fi

    probe_limit; rrc=$?
    [ "$rrc" -eq 2 ] && timed_out
    [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    line="$(probe "$LIM" /usr/bin/env bash -p "$STATE_SCRIPT" state "$PR" "$WHO" "$head")"; rc=$?
    [ "$rc" -eq 124 ] && { stalled state; continue; }
    [ "$rc" -eq 125 ] && { echo "PR_REVIEW_WATCH state=error reason=probe_unreadable" >&2; exit 2; }
    # Any non-zero status is unreadable, not "still waiting": a missing helper exits 126 or 127.
    if [ "$rc" -ne 0 ]; then
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error rc=%s detail=%s\n' "$PR" "$WHO" "$rc" "$(q "$line")"
        exit 2
    fi

    # A line about another PR, reviewer or head, or one carrying an appended field, must not be read as this head's state.
    if rb_review_record "$line" state; then
        state="$RB_REC_VALUE"
    else
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=unparseable detail=%s\n' "$PR" "$WHO" "$(q "$line")"
        exit 2
    fi
    if [ -n "$RB_REC_TAIL" ]; then
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=unparseable detail=%s\n' "$PR" "$WHO" "$(q "$line")"
        exit 2
    fi
    if ! rb_review_record_is_about "$PR" "$WHO" "$head"; then
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=record_identity_mismatch detail=%s\n' \
            "$PR" "$WHO" "$(q "$line")"
        exit 2
    fi
    case "$state" in
        none|pending|reviewed|blocked|dismissed) ;;
        *) printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=unknown_state detail=%s\n' "$PR" "$WHO" "$(q "$line")"
           exit 2 ;;
    esac
    if [ "$state" != "$last" ]; then
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=%s waited_s=%s\n' "$PR" "$WHO" "$state" "$waited"
        last="$state"
    fi

    # A terminal state that is still the review to wait past is not this round's answer; an empty
    # current id is malformed, since a terminal state names a review, while an empty baseline is legal.
    if [ -n "$AFTER_REVIEW" ]; then
        case "$state" in
            reviewed|blocked|dismissed)
                probe_limit; rrc=$?
                [ "$rrc" -eq 2 ] && timed_out
                [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
                cur="$(probe "$LIM" /usr/bin/env bash -p "$STATE_SCRIPT" review-id "$PR" "$WHO" "$head")"; crc2=$?
                [ "$crc2" -eq 124 ] && { stalled review-id; continue; }
                [ "$crc2" -ne 0 ] && { echo "PR_REVIEW_WATCH state=error reason=review_id_unreadable" >&2; exit 2; }
                case "$cur" in
                    "") echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=empty_review_id" >&2
                        exit 2 ;;
                esac
                for _id in "$cur" "$AFTER_REVIEW"; do
                    case "$_id" in
                        ""|*[0-9]) ;;
                        comment:*[0-9]) ;;
                        *) echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=malformed_review_id detail=$(q "$_id")" >&2
                           exit 2 ;;
                    esac
                    case "${_id#comment:}" in
                        ""|*[!0-9]*) [ -z "$_id" ] || {
                              echo "PR_REVIEW_WATCH pr=$PR reviewer=$WHO state=error reason=malformed_review_id detail=$(q "$_id")" >&2
                              exit 2; } ;;
                    esac
                done
                if [ "$cur" = "$AFTER_REVIEW" ]; then
                    if [ "$last" != "stale" ]; then
                        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=awaiting_new_review after=%s waited_s=%s\n' \
                            "$PR" "$WHO" "$AFTER_REVIEW" "$waited"
                        last="stale"
                    fi
                    state="pending"
                fi ;;
        esac
    fi
    case "$state" in
        reviewed|blocked|dismissed)
            probe_limit; rrc=$?
            [ "$rrc" -eq 2 ] && timed_out
            [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
            verdict="$(probe "$LIM" /usr/bin/env bash -p "$STATE_SCRIPT" verdict "$PR" "$WHO" "$head")"; vrc=$?
            [ "$vrc" -eq 124 ] && { stalled verdict; continue; }
            [ "$vrc" -eq 125 ] && { echo "PR_REVIEW_WATCH state=error reason=probe_unreadable" >&2; exit 2; }
            # Only 0 and 1 are answers; `PR_REVIEW_READY` is the signal under Monitor, so it is
            # withheld on anything else, whatever the exit status says.
            if [ "$vrc" -ne 0 ] && [ "$vrc" -ne 1 ]; then
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error detail=%s\n' "$PR" "$WHO" "$(q "$verdict")"
                exit 2
            fi
            if rb_review_record "$verdict" verdict; then
                v_field="$RB_REC_VALUE"; v_tail="$RB_REC_TAIL"
            else
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=unparseable_verdict detail=%s\n' \
                    "$PR" "$WHO" "$(q "$verdict")"
                exit 2
            fi
            if ! rb_review_record_is_about "$PR" "$WHO" "$head"; then
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=verdict_identity_mismatch detail=%s\n' \
                    "$PR" "$WHO" "$(q "$verdict")"
                exit 2
            fi
            # Value, tail and status must agree: `clean` with rc 1 or without `findings=0` is inconsistent,
            # as is a tail declaring `replies-only` that the shared predicate rejects.
            v_replies=0
            case "$v_field/$vrc" in
                clean/0)    [ "$v_tail" = " findings=0" ] || v_field="" ;;
                findings/1) if [[ "$v_tail" =~ ^\ findings=[0-9]+$ ]]; then
                                v_replies=0
                            elif rb_replies_only_line "$verdict" "$PR" "$WHO" "$head"; then
                                v_replies=1
                            else
                                v_field=""
                            fi ;;
                none/1)     [[ "$v_tail" =~ ^\ reason=[a-z_]+$ ]] || v_field="" ;;
                *)          v_field="" ;;
            esac
            if [ -z "$v_field" ]; then
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=inconsistent_verdict rc=%s detail=%s\n' \
                    "$PR" "$WHO" "$vrc" "$(q "$verdict")"
                exit 2
            fi
            # The verdict must describe the state the branch was entered on; a mismatch means this
            # poll is stale, so the loop goes round again rather than announcing a finished pass.
            v_reason="${v_tail# reason=}"
            agree=1
            case "$state" in
                reviewed)  [ "$v_field" = "clean" ] || [ "$v_field" = "findings" ] || agree=0 ;;
                blocked)   { [ "$v_field" = "none" ] && [ "$v_reason" = "blocked" ]; } || agree=0 ;;
                dismissed) { [ "$v_field" = "none" ] && [ "$v_reason" = "dismissed" ]; } || agree=0 ;;
                *)         agree=0 ;;
            esac
            if [ "$agree" -eq 0 ]; then
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=moved_between_probes observed=%s verdict=%s%s waited_s=%s\n' \
                    "$PR" "$WHO" "$state" "$v_field" "$v_tail" "$waited"
                last=""
                elapsed_s || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
                waited="$ELAPSED"
                if [ "$waited" -ge "$TIMEOUT" ]; then
                    printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=timeout waited_s=%s\n' "$PR" "$WHO" "$waited"
                    exit 1
                fi
                nap="$INTERVAL"
                remaining=$((TIMEOUT - waited))
                [ "$nap" -gt "$remaining" ] && nap="$remaining"
    # A failed sleep would hammer the API until the clock expired and report an ordinary timeout.
    sleep "$nap" || { echo "PR_REVIEW_WATCH state=error reason=sleep_failed" >&2; exit 2; }
                elapsed_s || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
                waited="$ELAPSED"
                continue
            fi
            # Re-resolved after the verdict: a push landing after the head probe leaves both probes
            # describing the old head, and READY on it advances the driver on a review of code that is gone.
            probe_limit; rrc=$?
            [ "$rrc" -eq 2 ] && timed_out
            [ "$rrc" -eq 0 ] || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
            head_now="$(probe "$LIM" /usr/bin/env bash -p "$STATE_SCRIPT" head "$PR")"; nrc=$?
            [ "$nrc" -eq 124 ] && { stalled head; continue; }
            [ "$nrc" -eq 125 ] && { echo "PR_REVIEW_WATCH state=error reason=probe_unreadable" >&2; exit 2; }
            if [ "$nrc" -ne 0 ] || ! is_full_sha "$head_now"; then
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=error reason=head_recheck_failed rc=%s detail=%s\n' \
                    "$PR" "$WHO" "$nrc" "$(q "$head_now")"
                exit 2
            fi
            if [ "$head_now" != "$head" ]; then
                printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=head_moved from=%s to=%s waited_s=%s\n' \
                    "$PR" "$WHO" "${head:0:7}" "${head_now:0:7}" "$waited"
                last=""
            else
                printf 'PR_REVIEW_READY pr=%s reviewer=%s state=%s verdict=%s%s\n' \
                    "$PR" "$WHO" "$state" "$v_field" "$v_tail"
                printf '%s\n' "$verdict"
                [ "$v_replies" -eq 1 ] && exit 4
                exit 0
            fi
            ;;
    esac

    elapsed_s || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    waited="$ELAPSED"
    if [ "$waited" -ge "$TIMEOUT" ]; then
        printf 'PR_REVIEW_WATCH pr=%s reviewer=%s state=timeout waited_s=%s\n' "$PR" "$WHO" "$waited"
        exit 1
    fi
    nap="$INTERVAL"
    remaining=$((TIMEOUT - waited))
    [ "$nap" -gt "$remaining" ] && nap="$remaining"
    sleep "$nap" || { echo "PR_REVIEW_WATCH state=error reason=sleep_failed" >&2; exit 2; }
    elapsed_s || { echo "PR_REVIEW_WATCH state=error reason=clock_unreadable" >&2; exit 2; }
    waited="$ELAPSED"
done
