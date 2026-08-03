#!/usr/bin/env bash
# Regression test for issue #3 — the watcher crash-loop.
#
# Trigger: CODEX_REVIEW_AUTO_OPEN_PRS=1, an open PR passes auto_preflight_ready,
# and responses/resp-<current-head>.json already exists with a TERMINAL,
# non-error status (`approved`, `comments_posted`). write_auto_request must treat
# that as a SUCCESSFUL no-op and leave the response alone.
#
# The defect was a bare `return` after a failed test: `[ "$prev_status" = "error" ]
# || return` inherits the failed test's exit status 1. Because the function is
# called unguarded under `set -Eeuo pipefail`, the intentional no-op terminated
# the daemon, which systemd then restarted every few seconds. Observed live on
# this repository's own PR #4 (NRestarts=6) and originally on p5ych0/strumok#176.
#
# handle() carries the identical pattern at its `[ -f "$req" ] || return` guard —
# a request file that vanishes between detection and handling would kill the
# daemon the same way — so it is covered here too.
#
# Self-contained: throwaway git repo + BUS_DIR under a temp dir. No network, no
# gh, no codex.

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SELF_DIR/review-bus-codex-watcher.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

REPO_DIR="$TMP/repo"; mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email t@example.com
git -C "$REPO_DIR" config user.name test
echo seed > "$REPO_DIR/f.txt"
git -C "$REPO_DIR" add -A; git -C "$REPO_DIR" commit -qm init
HEAD_OID="$(git -C "$REPO_DIR" rev-parse HEAD)"
SHORT="${HEAD_OID:0:7}"

export REPO_DIR BUS_DIR="$TMP/bus" REVIEW_BUS_REMOTE="git@github.com:test/demo.git"
mkdir -p "$BUS_DIR/requests" "$BUS_DIR/responses" "$BUS_DIR/.codex-seen"

# shellcheck disable=SC1090
source "$WATCHER"
set +e   # the watcher's own set -e must not govern these assertions

# ── 1. Terminal non-error response for the current head → successful no-op ────
# One case per terminal status the watcher can write, since the bug was keyed on
# "not error" rather than on any single status value.
for st in comments_posted approved; do
    resp="$BUS_DIR/responses/resp-${SHORT}.json"
    printf '{"pr":4,"sha":"%s","status":"%s","findings":0}\n' "$SHORT" "$st" > "$resp"
    rm -f "$BUS_DIR/requests/req-${SHORT}.json"

    ( write_auto_request 4 main "$HEAD_OID" ) >/dev/null 2>&1
    rc=$?

    [ "$rc" -eq 0 ] \
        && pass "write_auto_request: status=$st is a no-op with rc=0 (not $rc)" \
        || die  "write_auto_request: status=$st returned $rc — this kills the daemon under set -e"

    [ ! -f "$BUS_DIR/requests/req-${SHORT}.json" ] \
        && pass "write_auto_request: status=$st wrote no request (terminal response left alone)" \
        || die  "write_auto_request: status=$st rewrote a request over a terminal response"
done

# ── 2. The unguarded caller must survive it ──────────────────────────────────
# auto_enqueue_open_pr_heads calls write_auto_request unguarded, and main() calls
# auto_enqueue_open_pr_heads unguarded. Asserting the callee's rc is not enough:
# the daemon death happened at the call site. Re-run under `set -e` in a subshell
# that continues afterwards — if the no-op returns non-zero, `after` never prints.
out="$( set -Eeuo pipefail
        write_auto_request 4 main "$HEAD_OID" >/dev/null 2>&1
        echo after )"
[ "$out" = "after" ] \
    && pass "no-op does not abort an enclosing 'set -e' caller" \
    || die  "enclosing set -e caller aborted on the no-op (daemon would exit)"

# ── 3. handle(): a request that vanishes before handling is also a no-op ──────
# Same defect class: `[ -f "$req" ] || return` inherits 1 from the failed test,
# and handle() is likewise called unguarded from the main loop.
out2="$( set -Eeuo pipefail
         handle "$BUS_DIR/requests/req-doesnotexist.json" >/dev/null 2>&1
         echo after )"
[ "$out2" = "after" ] \
    && pass "handle(): missing request file is a successful no-op" \
    || die  "handle(): missing request file returned non-zero (daemon would exit)"

# ── 4. An ERROR response is still retried (the no-op must not over-apply) ─────
# Guards the obvious wrong fix — returning 0 unconditionally — which would strand
# every transient failure instead of reprocessing it.
resp="$BUS_DIR/responses/resp-${SHORT}.json"
printf '{"pr":4,"sha":"%s","status":"error","findings":0}\n' "$SHORT" > "$resp"
rm -f "$BUS_DIR/requests/req-${SHORT}.json"
( write_auto_request 4 main "$HEAD_OID" ) >/dev/null 2>&1
[ -f "$BUS_DIR/requests/req-${SHORT}.json" ] \
    && pass "error response is still re-requested (no-op did not over-apply)" \
    || die  "error response was treated as terminal — transient failures would stall"

# ── 5. STRUCTURAL: no bare no-op returns anywhere in the watcher ─────────────
# Behavioural cases can only cover the branches someone thought to enumerate.
# Two rounds of this review found bare returns that a hand-built list had missed,
# so the durable guard is structural: every `return` in the daemon states its
# status. This catches the next one at the point it is written, in any function,
# without needing a fixture that reaches that branch.
#
# `return $rc`, `return 1` and similar are untouched — only a naked `return`,
# whose value is whatever the previous command happened to leave behind.
#
# HOW, and why not a regex over the source. Three successive regex versions were
# defeated by legal Bash: one anchored on end-of-line missed `{ ...; return; }`;
# adding `;`/`}` missed `|| return # why`; adding `#` was still defeated by a
# `#` inside a quoted string (which disqualified the line) and by `return
# >/dev/null`. Each time the suite reported PASS while the invariant was false.
# A regex cannot tell a comment from a `#` in a string, so the tool was wrong.
#
# Bash itself is the oracle. Sourcing the script defines its functions (the
# source guard keeps main() from running), and `declare -f` re-renders each one
# from the PARSED form: comments are gone entirely, quoting is normalised, and
# each command sits on its own line. Scanning that output cannot be fooled by
# quoting or comments, because neither survives the parse.
#
# A `return` is bare when the next token is a command terminator, a redirection,
# or a control operator — never an argument.
BARE_RETURN_RE='(^|[[:space:]]|[;{&|])return[[:space:]]*($|[;}<>&|])'

# Prints "<function>: <line>" for every bare return. Sourcing happens in a
# subshell so the watcher's globals and traps cannot leak into the test.
detect_bare_returns() {
    local target="$1"
    (
        set +eu
        REPO_DIR="$REPO_DIR" BUS_DIR="$BUS_DIR" \
        REVIEW_BUS_REMOTE="${REVIEW_BUS_REMOTE:-git@github.com:test/demo.git}"
        # shellcheck disable=SC1090
        source "$target" >/dev/null 2>&1
        while read -r _ _ fn; do
            declare -f "$fn" 2>/dev/null \
                | grep -E "$BARE_RETURN_RE" \
                | sed "s/^[[:space:]]*/$fn: /"
        done < <(declare -F)
    ) || true
}

# Negative control FIRST: a detector that cannot fail is worse than no detector,
# and this one already shipped once with a hole in it. Every form below must be
# caught before the real scan is allowed to mean anything.
# Every BAD form is named bad_*, every GOOD form good_*, so the assertion is
# "exactly the bad ones, and nothing else" rather than a count that drifts as
# forms are added. bad_quoted_hash and bad_redirect are the two that defeated
# the final regex version; the rest defeated earlier ones.
probe="$TMP/bare-return-forms.sh"
cat > "$probe" <<'PROBE'
bad_eol()         { [ -f x ] || return
}
bad_brace()       { cmd || { printf 'x'; return; }
}
bad_if()          { if x; then return; fi
}
bad_comment()     { [ -f x ] || return # trailing comment still leaves it bare
}
bad_quoted_hash() { printf 'PR #4' || return
}
bad_redirect()    { false || return >/dev/null
}
good_var()        { return $rc; }
good_zero()       { return 0; }
good_one()        { return 1; }
good_prose()      {
    # a comment mentioning a bare return
    printf 'x #4 return'
    return 0
}
PROBE
probe_hits="$(detect_bare_returns "$probe")"
missed=""; spurious=""
for f in bad_eol bad_brace bad_if bad_comment bad_quoted_hash bad_redirect; do
    printf '%s' "$probe_hits" | grep -q "^$f:" || missed="$missed $f"
done
for f in good_var good_zero good_one good_prose; do
    printf '%s' "$probe_hits" | grep -q "^$f:" && spurious="$spurious $f"
done
if [ -z "$missed" ] && [ -z "$spurious" ]; then
    pass "detector flags every bare form (incl. quoted '#' and redirection) and spares every valued return"
else
    die "detector is unsound — missed:${missed:- none} spurious:${spurious:- none}"
fi

# And prove the comment form is genuinely dangerous, not merely untidy: under
# `set -e` an unguarded caller dies on it, which is issue #3 exactly.
#
# No `|| fallback` on this assignment. Putting it in an `||` list disables
# errexit for the whole command, and that suppression reaches INTO the command
# substitution — the first version of this fixture printed "survived" and proved
# the opposite of what it claimed. `set +e` is already active here, so a non-zero
# substitution is harmless.
danger="$( set -Eeuo pipefail
           noop() { [ -f /nonexistent ] || return # intentional no-op
           }
           noop
           echo survived )" 2>/dev/null
[ "$danger" != "survived" ] \
    && pass "'|| return # comment' does abort a set -e caller (the form is a real defect)" \
    || die  "fixture no longer reproduces the hazard — the assertion above proves nothing"

# Same proof for the two forms that defeated the final regex. Detecting them is
# only worth doing if they are genuinely fatal, and a reader should not have to
# take that on trust for any form the detector claims to catch.
danger2="$( set -Eeuo pipefail
            noop() { printf 'PR #4' >/dev/null; [ -f /nonexistent ] || return
            }
            noop
            echo survived )" 2>/dev/null
[ "$danger2" != "survived" ] \
    && pass "quoted-'#' form aborts a set -e caller" \
    || die  "quoted-'#' fixture does not reproduce the hazard"

danger3="$( set -Eeuo pipefail
            noop() { [ -f /nonexistent ] || return >/dev/null
            }
            noop
            echo survived )" 2>/dev/null
[ "$danger3" != "survived" ] \
    && pass "redirected form ('return >/dev/null') aborts a set -e caller" \
    || die  "redirect fixture does not reproduce the hazard"

strays="$(detect_bare_returns "$WATCHER")"
if [ -z "$strays" ]; then
    pass "watcher contains no bare returns (every no-op states its status)"
else
    die "bare return(s) inherit the previous command's status:"
    printf '        %s\n' "$strays"
fi

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
