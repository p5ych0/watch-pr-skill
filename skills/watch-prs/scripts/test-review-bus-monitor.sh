#!/usr/bin/env bash
# Focused tests for review-bus-response-monitor.sh.
#
# Covers:
#   1. startup replay emits only the latest response per PR (stale suppressed)
#   2. dedup — a second --once run re-emits nothing
#   2b. same resp path with NEW content (same-SHA re-request) re-emits (digest)
#   2c. MONITOR_EMITTED_DIR gives an independent, session-local dedup namespace
#   2d. --ack marks a response handled; not re-emitted even under a fresh emit dir
#   2e. ack is digest-specific — same-path new content re-emits despite prior ack
#   2f. --ack-if-digest keys the marker on a caller-captured digest (rejects a
#       malformed digest; a same-path swap after ack still notifies) — the ack
#       TOCTOU fix
#   3. live watch emits a response created AFTER startup, exactly once
#   4. deterministic safety net — a response written while inotifywait is slow to
#      arm is still emitted by the per-iteration sweep (no fixed-sleep race)
#   5. no orphaned inotifywait after the monitor is killed
#
# Self-contained: throwaway BUS_DIR under a temp dir. No network, no gh.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MONITOR="$SCRIPT_DIR/review-bus-response-monitor.sh"
REAL_INOTIFY="$(command -v inotifywait || true)"

TMP="$(mktemp -d)"
trap 'pkill -f "inotifywait.*$TMP" 2>/dev/null || true; [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null || true; [ -n "${SLOW_PID:-}" ] && kill "$SLOW_PID" 2>/dev/null || true; rm -rf "$TMP"; true' EXIT

export BUS_DIR="$TMP/bus"
export REVIEW_BUS_PREFIX="BUSTEST"
RESP="$BUS_DIR/responses"
mkdir -p "$RESP"

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# Write a response file. Args: name pr sha status findings
resp() {
    cat > "$RESP/resp-$1.json" <<JSON
{"pr":$2,"sha":"$3","status":"$4","findings_count":$5,"reviewer":"codex","summary":"test $1"}
JSON
}

# ── Test 1 + 2: replay emits latest-per-PR only, then dedups ────────────────
resp aaaa 50 aaaaaaa comments_posted 1
sleep 1.1                        # ensure mtime ordering (find -nt resolution)
resp bbbb 50 bbbbbbb approved 0  # newer for the SAME pr=50 → "latest"
resp cccc 51 ccccccc approved 0  # different pr → emitted

out1="$("$MONITOR" --once 2>/dev/null)"

echo "$out1" | grep -q "sha=bbbbbbb" && pass "latest-per-PR response emitted" || die "latest response not emitted"
echo "$out1" | grep -q "sha=aaaaaaa" && die "stale (older same-PR) response was emitted" || pass "stale response suppressed"
echo "$out1" | grep -q "sha=ccccccc" && pass "other-PR response emitted" || die "other-PR response not emitted"

out2="$("$MONITOR" --once 2>/dev/null || true)"
[ -z "$(echo "$out2" | grep -E 'BUSTEST_REVIEW ' || true)" ] && pass "second --once re-emits nothing (dedup)" || die "dedup failed: second run re-emitted"

# ── Test 2b: same resp path, NEW content (same-SHA re-request) re-emits ──────
# The watcher rewrites resp-<sha>.json in place when a round is re-reviewed
# without a code change; dedup is by content DIGEST, so a genuinely new response
# for an already-seen path must emit again — a path-only dedup would suppress it
# and stall the fix/merge loop.
resp cccc 51 ccccccc comments_posted 3   # same file as the pr=51 resp above, new content
out3="$("$MONITOR" --once 2>/dev/null || true)"
echo "$out3" | grep -q "findings=3" && pass "same-path new-content response re-emitted (digest dedup)" || die "same-path new-content response suppressed"

# ── Test 2c: MONITOR_EMITTED_DIR is an independent dedup namespace ───────────
# The session Monitor runs this script with its own emitted dir so it never
# races the daemon's .monitor-emitted. A fresh namespace must re-emit responses
# the default dir already marked; a second run under that namespace dedups.
SESS_EMIT="$TMP/sess-emit"
out4="$(MONITOR_EMITTED_DIR="$SESS_EMIT" "$MONITOR" --once 2>/dev/null || true)"
echo "$out4" | grep -q "sha=bbbbbbb" && pass "MONITOR_EMITTED_DIR re-emits under a fresh namespace (daemon-independent)" || die "MONITOR_EMITTED_DIR did not isolate its dedup dir"
out5="$(MONITOR_EMITTED_DIR="$SESS_EMIT" "$MONITOR" --once 2>/dev/null || true)"
[ -z "$(echo "$out5" | grep -E 'BUSTEST_REVIEW ' || true)" ] && pass "MONITOR_EMITTED_DIR dedups within its own namespace" || die "MONITOR_EMITTED_DIR second run re-emitted"

# ── Test 2d: --ack marks a response handled; NOT re-emitted even under a FRESH
#            per-session emit dir (crash-safe handled dedup) ─────────────────
# A fresh emit dir re-surfaces a crash-after-emit response (Test 2c); --ack,
# written after close-out/merge, is what stops an already-handled one re-firing.
"$MONITOR" --ack "$RESP/resp-bbbb.json" >/dev/null
out6="$(MONITOR_EMITTED_DIR="$TMP/sess6" "$MONITOR" --once 2>/dev/null || true)"
echo "$out6" | grep -q "sha=bbbbbbb" && die "acked response re-emitted under a fresh session (must be suppressed)" || pass "acked response stays suppressed across a fresh session"

# ── Test 2e: ack is digest-specific — a same-path NEW-content response re-emits
resp bbbb 50 bbbbbbb comments_posted 9    # rewrite resp-bbbb.json: same path, new content
out7="$(MONITOR_EMITTED_DIR="$TMP/sess7" "$MONITOR" --once 2>/dev/null || true)"
echo "$out7" | grep -q "findings=9" && pass "same-path new content re-emits despite prior ack (digest-keyed)" || die "new content wrongly suppressed by a stale ack"

# ── Test 2f: --ack-if-digest keys the marker on a CALLER-CAPTURED digest ─────
# close-round.sh captures the digest BEFORE mutating, then acks by that value so
# a watcher swap can't be re-hashed into the marker. Prove: (a) a malformed
# digest is rejected without writing a marker; (b) acking captured digest D
# suppresses the D-content response; (c) a same-path swap to different content
# (digest D') is NOT suppressed — its notification still fires.
resp dddd 60 ddddddd comments_posted 4
DIG_D="$(sha256sum "$RESP/resp-dddd.json" | awk '{print $1}')"
"$MONITOR" --ack-if-digest "$RESP/resp-dddd.json" "not-a-sha" >/dev/null 2>&1 \
    && die "ack-if-digest: accepted a malformed digest" || pass "ack-if-digest: rejects a malformed digest"
ls "$BUS_DIR/.monitor-acked"/resp-dddd.json.* >/dev/null 2>&1 && die "ack-if-digest: wrote a marker on a rejected digest" || pass "ack-if-digest: no marker on rejection"
"$MONITOR" --ack-if-digest "$RESP/resp-dddd.json" "$DIG_D" >/dev/null
out8="$(MONITOR_EMITTED_DIR="$TMP/sess8" "$MONITOR" --once 2>/dev/null || true)"
echo "$out8" | grep -q "sha=ddddddd" && die "ack-if-digest: captured-digest response re-emitted (must be suppressed)" || pass "ack-if-digest: captured-digest response suppressed"
# Swap same path to NEW content — the captured-digest marker must not cover it.
resp dddd 60 ddddddd comments_posted 7
DIG_DPRIME="$(sha256sum "$RESP/resp-dddd.json" | awk '{print $1}')"
[ -e "$BUS_DIR/.monitor-acked/resp-dddd.json.$DIG_DPRIME" ] && die "ack-if-digest: fresh content's digest wrongly marked" || pass "ack-if-digest: fresh content not pre-suppressed"
out9="$(MONITOR_EMITTED_DIR="$TMP/sess9" "$MONITOR" --once 2>/dev/null || true)"
echo "$out9" | grep -q "findings=7" && pass "ack-if-digest: same-path swap after ack still notifies" || die "ack-if-digest: swap suppressed by the captured-digest marker"

# ── Test 3: live watch emits a response created AFTER startup, exactly once ──
rm -rf "$BUS_DIR"; mkdir -p "$RESP"
OUT="$TMP/live.out"
MONITOR_POLL_SECONDS=1 "$MONITOR" > "$OUT" 2>/dev/null &
WATCH_PID=$!

sleep 1.5
resp dddd 60 ddddddd comments_posted 2

emitted=0
for _ in $(seq 1 30); do
    grep -q "sha=ddddddd" "$OUT" 2>/dev/null && { emitted=1; break; }
    sleep 0.2
done
[ "$emitted" -eq 1 ] && pass "response created after startup is emitted (no dropped handoff)" || die "post-startup response was dropped"

count="$(grep -c "sha=ddddddd" "$OUT" 2>/dev/null || true)"
[ "$count" = "1" ] && pass "post-startup response emitted exactly once" || die "post-startup response emitted $count times (expected 1)"

# ── Test 5: no orphaned inotifywait after shutdown ──────────────────────────
kill "$WATCH_PID" 2>/dev/null || true
sleep 0.8
if pgrep -f "inotifywait.*$RESP" >/dev/null 2>&1; then
    die "inotifywait orphaned after the monitor was killed"
    pkill -f "inotifywait.*$TMP" 2>/dev/null || true
else
    pass "no orphaned inotifywait after monitor shutdown"
fi
WATCH_PID=""

# ── Test 4: deterministic safety net when inotifywait is slow to arm ─────────
# Shim a slow inotifywait; a response written during the arm gap must still be
# emitted by the per-iteration sweep (which does not depend on the watch being
# ready). This is the race the fixed-sleep approach could lose.
if [ -n "$REAL_INOTIFY" ]; then
    rm -rf "$BUS_DIR"; mkdir -p "$RESP"
    SHIM="$TMP/bin"; mkdir -p "$SHIM"
    cat > "$SHIM/inotifywait" <<SH
#!/usr/bin/env bash
sleep 2
exec "$REAL_INOTIFY" "\$@"
SH
    chmod +x "$SHIM/inotifywait"

    OUT2="$TMP/slow.out"
    PATH="$SHIM:$PATH" MONITOR_POLL_SECONDS=1 "$MONITOR" > "$OUT2" 2>/dev/null &
    SLOW_PID=$!

    sleep 1                       # write inside the 2s arm gap
    resp eeee 70 eeeeeee approved 0

    emitted=0
    for _ in $(seq 1 40); do
        grep -q "sha=eeeeeee" "$OUT2" 2>/dev/null && { emitted=1; break; }
        sleep 0.2
    done
    [ "$emitted" -eq 1 ] && pass "response written during slow inotify arm is still emitted (deterministic sweep)" || die "slow-arm gap dropped the response"

    kill "$SLOW_PID" 2>/dev/null || true
    SLOW_PID=""
else
    pass "slow-arm test skipped (inotifywait not found)"
fi


# ── emit path: a multi-object or malformed response must not become a handoff ─
# jq reads a STREAM, so a two-object file produced one _REVIEW line per object,
# and the control-byte strip then removed the newline between them - collapsing
# them into a single line with two `status=` and two `resp=` tokens. A driver
# parsing positionally could read an ambiguous clean status instead of a
# fail-closed sentinel.
EMIT_BUS="$TMP/emitbus"; mkdir -p "$EMIT_BUS/responses"
printf '{"pr":80,"sha":"1111111","status":"comments_posted","findings_count":2,"reviewer":"codex","summary":"a"}{"pr":80,"sha":"1111111","status":"approved","findings_count":0,"reviewer":"codex","summary":"b"}\n' \
    > "$EMIT_BUS/responses/resp-1111111.json"
out_multi="$(BUS_DIR="$EMIT_BUS" MONITOR_EMITTED_DIR="$TMP/em1" "$MONITOR" --once 2>/dev/null || true)"
printf '%s' "$out_multi" | grep -q 'BUSTEST_REVIEW_PARSE_ERROR' \
    && pass "emit: concatenated objects => PARSE_ERROR sentinel" \
    || die "emit: multi-object response did not produce a parse error: $out_multi"
printf '%s' "$out_multi" | grep -qE 'BUSTEST_REVIEW (pr|.*status=)' \
    && die "emit: multi-object response still produced a handoff line: $out_multi" \
    || pass "emit: no handoff line from a multi-object response"
[ "$(printf '%s' "$out_multi" | grep -c 'status=')" -le 1 ] \
    && pass "emit: no line carries two status= tokens" \
    || die "emit: a line carried multiple status= tokens"

# ── replay path: a response that cannot be GROUPED must still be reported ────
# The concatenated case above reaches emit_response only because `.pr` happens to
# parse (twice). Anything jq cannot pull a `.pr` from - a truncated write, a
# top-level array, a bare string - was `continue`d in replay_existing BEFORE the
# fail-closed guard ran, so `--once` exited 0 printing nothing: byte-identical to
# "no pending review". A driver polling the monitor reads that as "nothing to do"
# and the review is lost. Each of these must surface the sentinel instead.
i=0
for bad in \
    '{"pr":81,"sha":"2222222","status":"comments_posted","findings_c' \
    '[{"pr":82,"sha":"3333333","status":"approved","findings_count":0}]' \
    '"just a string"' \
    '{"sha":"4444444","status":"approved","findings_count":0,"reviewer":"codex"}' \
    '{"pr":"85","sha":"5555555","status":"approved","findings_count":0,"reviewer":"codex"}'
do
    i=$((i + 1))
    BAD_BUS="$TMP/badbus$i"; mkdir -p "$BAD_BUS/responses"
    printf '%s' "$bad" > "$BAD_BUS/responses/resp-999999$i.json"
    out_bad="$(BUS_DIR="$BAD_BUS" MONITOR_EMITTED_DIR="$TMP/embad$i" "$MONITOR" --once 2>/dev/null || true)"
    printf '%s' "$out_bad" | grep -q 'BUSTEST_REVIEW_PARSE_ERROR' \
        && pass "replay: ungroupable response #$i surfaces the PARSE_ERROR sentinel" \
        || die "replay: ungroupable response #$i produced silence (out='$out_bad')"
    printf '%s' "$out_bad" | grep -qE 'BUSTEST_REVIEW pr=' \
        && die "replay: ungroupable response #$i produced a handoff line: $out_bad" \
        || pass "replay: ungroupable response #$i produced no handoff line"
done

# A well-formed response in the SAME dir as an ungroupable one must still be
# delivered - the sentinel reports the broken file, it does not suppress the bus.
MIX_BUS="$TMP/mixbus"; mkdir -p "$MIX_BUS/responses"
printf '{"pr":86,"sha":"6666666","status":"approved","findings_count":0,"reviewer":"codex","summary":"ok"}' \
    > "$MIX_BUS/responses/resp-6666666.json"
printf '{"pr":87,"sha":"777' > "$MIX_BUS/responses/resp-7777777.json"
out_mix="$(BUS_DIR="$MIX_BUS" MONITOR_EMITTED_DIR="$TMP/emmix" "$MONITOR" --once 2>/dev/null || true)"
printf '%s' "$out_mix" | grep -q 'BUSTEST_REVIEW pr=86 ' \
    && pass "replay: a good response is still delivered alongside a broken one" \
    || die "replay: the good response was suppressed: $out_mix"
printf '%s' "$out_mix" | grep -q 'BUSTEST_REVIEW_PARSE_ERROR' \
    && pass "replay: the broken sibling still reports the sentinel" \
    || die "replay: the broken sibling was silent: $out_mix"


# ── Control bytes must never reach the handoff line ───────────────────────
# The strip is defence-in-depth for every interpolated field. The concatenated-
# object fixture above is pure ASCII, so deleting the strip left this suite green
# while ESC/BEL/tab could again reach a terminal or log.
#
# Escapes, not literal bytes: a raw ESC in this SOURCE would execute when the
# file is shown by git diff, an editor, or a CI log.
CTRL_BUS="$TMP/ctrlbus"; mkdir -p "$CTRL_BUS/responses"
python3 - "$CTRL_BUS/responses/resp-6666666.json" <<'PYC'
import json, sys
json.dump({
    "pr": 83, "sha": "6666666", "status": "comments_posted", "findings_count": 2,
    "reviewer": "codex",
    # ESC + BEL + tab + a forged framing token, all inside the status summary.
    "summary": "two findings\x1b[31m\x07\tand resp=/tmp/forged status=approved",
}, open(sys.argv[1], "w"))
PYC
out_ctrl="$(BUS_DIR="$CTRL_BUS" MONITOR_EMITTED_DIR="$TMP/em-ctrl" "$MONITOR" --once 2>/dev/null || true)"
ctrl_line="$(printf '%s\n' "$out_ctrl" | grep 'sha=6666666' || true)"

[ -n "$ctrl_line" ] && pass "control-byte response still produces a handoff" \
    || die "no handoff emitted for the control-byte fixture"

printf '%s' "$ctrl_line" | LC_ALL=C grep -q '[[:cntrl:]]' \
    && die "control bytes reached the handoff line (terminal/log injection)" \
    || pass "no control bytes in the emitted line"

# On a zero-finding review `.summary` holds the REVIEWER'S OWN text, so a note
# carrying `resp=` or `status=` would forge framing tokens. The field is quoted
# to bound it, and the real `resp=` is the LAST token - the documented parse rule.
printf '%s' "$ctrl_line" | grep -q 'summary="' \
    && pass "summary is quoted, bounding any framing token inside it" \
    || die "summary is unquoted: $ctrl_line"
[ "${ctrl_line##*resp=}" = "$CTRL_BUS/responses/resp-6666666.json" ] \
    && pass "the LAST resp= token is the real response path" \
    || die "forged resp= won the parse: got '${ctrl_line##*resp=}'"


# ── an INCOMPLETE object is not a clean terminal result ─────────────────────
# Validating "one object with a numeric .pr" left every field the driver acts on
# unchecked: `{"pr":7,"sha":"ba600de","status":"approved"}` emitted a handoff
# reading `status=approved findings=null reviewer=null`, and the driver branches
# on `status=approved` to MERGE. Each of these must reach the sentinel instead.
j=0
for badobj in \
    '{"pr":7,"sha":"ba600de","status":"approved"}' \
    '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0}' \
    '{"pr":0,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex"}' \
    '{"pr":7.5,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex"}' \
    '{"pr":7,"sha":"zzzzzzz","status":"approved","findings_count":0,"reviewer":"codex"}' \
    '{"pr":7,"sha":"ba600de","status":"merged","findings_count":0,"reviewer":"codex"}' \
    '{"pr":7,"sha":"ba600de","status":"approved","findings_count":-1,"reviewer":"codex"}' \
    '{"pr":7,"sha":"ba600de","status":"approved","findings_count":3,"reviewer":"codex"}' \
    '{"pr":7,"sha":"ba600de","status":"comments_posted","findings_count":0,"reviewer":"codex"}'
do
    j=$((j + 1))
    OBJ_BUS="$TMP/objbus$j"; mkdir -p "$OBJ_BUS/responses"
    printf '%s' "$badobj" > "$OBJ_BUS/responses/resp-888888$j.json"
    out_obj="$(BUS_DIR="$OBJ_BUS" MONITOR_EMITTED_DIR="$TMP/emobj$j" "$MONITOR" --once 2>/dev/null || true)"
    printf '%s' "$out_obj" | grep -q 'BUSTEST_REVIEW_PARSE_ERROR' \
        && pass "invalid response #$j reaches the sentinel" \
        || die "invalid response #$j was accepted (out='$out_obj')"
    printf '%s' "$out_obj" | grep -q 'status=approved' \
        && die "invalid response #$j emitted a clean terminal handoff: $out_obj" \
        || pass "invalid response #$j emitted no approved handoff"
done

# The complete, consistent object still goes through - the guard rejects what is
# malformed, not what is merely terse.
GOOD_BUS="$TMP/goodbus"; mkdir -p "$GOOD_BUS/responses"
printf '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex","summary":"clean"}' \
    > "$GOOD_BUS/responses/resp-ba600de.json"
out_good="$(BUS_DIR="$GOOD_BUS" MONITOR_EMITTED_DIR="$TMP/emgood" "$MONITOR" --once 2>/dev/null || true)"
printf '%s' "$out_good" | grep -q 'BUSTEST_REVIEW pr=7 .*status=approved' \
    && pass "a complete, consistent response still emits its handoff" \
    || die "the guard rejected a valid response: $out_good"

# ── an UNREADABLE response is reported, not passed over ─────────────────────
# Delegating an ungroupable file to emit_response is not enough: it hashes before
# it parses, and a digest failure returned 0 silently - so a mode-000 response
# made `--once` exit successfully with zero output, still indistinguishable from
# "no pending review".
UNREAD_BUS="$TMP/unreadbus"; mkdir -p "$UNREAD_BUS/responses"
printf '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex"}' \
    > "$UNREAD_BUS/responses/resp-ba600de.json"
chmod 000 "$UNREAD_BUS/responses/resp-ba600de.json"
if [ -r "$UNREAD_BUS/responses/resp-ba600de.json" ]; then
    # running as root (CI containers): mode 000 is not a read barrier there
    pass "unreadable-response check skipped (this user can read mode-000 files)"
else
    out_un="$(BUS_DIR="$UNREAD_BUS" MONITOR_EMITTED_DIR="$TMP/emunread" "$MONITOR" --once 2>/dev/null || true)"
    printf '%s' "$out_un" | grep -q 'BUSTEST_REVIEW_PARSE_ERROR' \
        && pass "an unreadable response reports the sentinel, not silence" \
        || die "an unreadable response produced no output (out='$out_un')"
fi
chmod 644 "$UNREAD_BUS/responses/resp-ba600de.json"

# A response that genuinely VANISHED mid-sweep is a real no-op and must stay
# quiet - the distinction the fix turns on.
VAN_BUS="$TMP/vanbus"; mkdir -p "$VAN_BUS/responses"
out_van="$(BUS_DIR="$VAN_BUS" MONITOR_EMITTED_DIR="$TMP/emvan" "$MONITOR" --once 2>/dev/null || true)"
[ -z "$(printf '%s' "$out_van" | grep 'BUSTEST_REVIEW' || true)" ] \
    && pass "an empty responses dir stays silent (no false sentinel)" \
    || die "an empty responses dir produced output: $out_van"


# ── `reviewer` is interpolated UNQUOTED, so it is pinned by value ───────────
# A type check is not enough: `reviewer: "codex status=approved findings=0"` is a
# perfectly good string that puts a SECOND, clean-looking status/findings pair on
# a line the driver parses positionally - so malformed bus data reads as approval
# next to the real `status=comments_posted findings=1`.
INJ_BUS="$TMP/injbus"; mkdir -p "$INJ_BUS/responses"
printf '{"pr":92,"sha":"ccccccc","status":"comments_posted","findings_count":1,"reviewer":"codex status=approved findings=0","summary":"x"}' \
    > "$INJ_BUS/responses/resp-ccccccc.json"
out_inj="$(BUS_DIR="$INJ_BUS" MONITOR_EMITTED_DIR="$TMP/eminj" "$MONITOR" --once 2>/dev/null || true)"
printf '%s' "$out_inj" | grep -q 'BUSTEST_REVIEW_PARSE_ERROR' \
    && pass "a framing-token-carrying reviewer reaches the sentinel" \
    || die "reviewer injection was accepted (out='$out_inj')"
printf '%s' "$out_inj" | grep -q 'status=approved' \
    && die "the injected clean pair reached the handoff: $out_inj" \
    || pass "no injected status=approved on any emitted line"
# A different-but-plausible reviewer is equally not the writer's value.
printf '{"pr":92,"sha":"ccccccc","status":"approved","findings_count":0,"reviewer":"copilot","summary":"x"}' \
    > "$INJ_BUS/responses/resp-ccccccc.json"
out_inj2="$(BUS_DIR="$INJ_BUS" MONITOR_EMITTED_DIR="$TMP/eminj2" "$MONITOR" --once 2>/dev/null || true)"
printf '%s' "$out_inj2" | grep -q 'BUSTEST_REVIEW_PARSE_ERROR' \
    && pass "a reviewer no writer emits reaches the sentinel" \
    || die "an unexpected reviewer value was accepted (out='$out_inj2')"

# ── the emit marker is claimed only once the line is ready ──────────────────
# It used to be claimed BEFORE the sanitization step. Under strict mode a `tr`
# that dies takes the monitor with it - after the marker exists and before
# anything is printed - so the restarted monitor saw the claim and suppressed
# that response permanently. First run: dies, no output. Second run (no fault):
# still no output. The response was simply lost.
TR_BUS="$TMP/trbus"; mkdir -p "$TR_BUS/responses"
printf '{"pr":93,"sha":"eeeeeee","status":"approved","findings_count":0,"reviewer":"codex","summary":"ok"}' \
    > "$TR_BUS/responses/resp-eeeeeee.json"
TR_BIN="$TMP/trbin"; mkdir -p "$TR_BIN"
cat > "$TR_BIN/tr" <<'SH'
#!/usr/bin/env bash
# Faults ONLY the control-byte strip. Scoped by ARGS on purpose: the monitor also
# runs `tr` while deriving its own identity, and a blanket fault killed it before
# emit_response ever ran - which made this test pass without exercising anything.
if [ -n "${FAULT_TR:-}" ] && [ "$1" = "-d" ] && [ "$2" = "[:cntrl:]" ]; then
    exit 9
fi
exec /usr/bin/tr "$@"
SH
chmod +x "$TR_BIN/tr"

TR_EMIT="$TMP/emtr"
PATH="$TR_BIN:$PATH" FAULT_TR=1 BUS_DIR="$TR_BUS" MONITOR_EMITTED_DIR="$TR_EMIT" \
    "$MONITOR" --once >/dev/null 2>&1 || true
[ -z "$(ls -A "$TR_EMIT" 2>/dev/null)" ] \
    && pass "a sanitization failure leaves no emit marker behind" \
    || die "the marker was claimed before the line was ready (response would be lost)"

# And with the fault cleared the SAME session dir still delivers it - proof the
# first run did not consume the response.
out_tr="$(BUS_DIR="$TR_BUS" MONITOR_EMITTED_DIR="$TR_EMIT" "$MONITOR" --once 2>/dev/null || true)"
printf '%s' "$out_tr" | grep -q 'BUSTEST_REVIEW pr=93 ' \
    && pass "after the sanitization fault clears, the response is delivered" \
    || die "the response was permanently suppressed by the failed run: $out_tr"
rm -f "$TR_BIN/tr"


# ── `.summary` is a control field too ──────────────────────────────────────
# A response with valid pr/sha/status/count/reviewer but NO summary passed the
# shape guard and emitted `status=approved summary=""` - a terminal result the
# driver branches on, assembled from a response that was missing a field every
# writer supplies.
k=0
for nosum in \
    '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex"}' \
    '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex","summary":null}' \
    '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex","summary":false}' \
    '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex","summary":""}' \
    '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex","summary":"   "}'
do
    k=$((k + 1))
    SUM_BUS="$TMP/sumbus$k"; mkdir -p "$SUM_BUS/responses"
    printf '%s' "$nosum" > "$SUM_BUS/responses/resp-ba600de.json"
    out_sum="$(BUS_DIR="$SUM_BUS" MONITOR_EMITTED_DIR="$TMP/emsum$k" "$MONITOR" --once 2>/dev/null || true)"
    printf '%s' "$out_sum" | grep -q 'BUSTEST_REVIEW_PARSE_ERROR' \
        && pass "summary case #$k reaches the sentinel" \
        || die "summary case #$k was accepted (out='$out_sum')"
    printf '%s' "$out_sum" | grep -q 'status=approved' \
        && die "summary case #$k emitted a clean terminal handoff: $out_sum" \
        || pass "summary case #$k emitted no approved handoff"
done

# ── The handoff must be inert for UNICODE controls, not just C0 bytes ───────
# `tr -d '[:cntrl:]'` is byte-oriented: under C and C.UTF-8 it passes UTF-8
# encoded C1 (U+009B = c2 9b) and bidi (U+202E = e2 80 ae) straight through, so
# the "all control bytes stripped" guarantee was false for exactly the code
# points that reorder or hijack rendering. Asserted at the BYTE level - the
# earlier ESC/BEL check greps a byte class that misses both.
UNI_BUS="$TMP/unibus"; mkdir -p "$UNI_BUS/responses"
python3 - "$UNI_BUS/responses/resp-ba600de.json" <<'PYU'
import json, sys
json.dump({"pr": 7, "sha": "ba600de", "status": "approved", "findings_count": 0,
           "reviewer": "codex",
           "summary": "start\u009bmiddle\u202eend\u200bzw"}, open(sys.argv[1], "w"))
PYU
out_uni="$(BUS_DIR="$UNI_BUS" MONITOR_EMITTED_DIR="$TMP/emuni" "$MONITOR" --once 2>/dev/null || true)"
uni_line="$(printf '%s\n' "$out_uni" | grep -m1 'BUSTEST_REVIEW pr=7' || true)"
[ -n "$uni_line" ] \
    && pass "a response carrying Unicode controls still emits its handoff" \
    || die "the Unicode-control response produced no handoff: $out_uni"
uni_hex="$(printf '%s' "$uni_line" | od -An -tx1 | tr -d ' \n')"
printf '%s' "$uni_hex" | grep -q 'c29b' \
    && die "C1 U+009B (c2 9b) reached the handoff line" \
    || pass "C1 U+009B is not in the emitted bytes"
printf '%s' "$uni_hex" | grep -q 'e280ae' \
    && die "bidi U+202E (e2 80 ae) reached the handoff line" \
    || pass "bidi U+202E is not in the emitted bytes"
printf '%s' "$uni_hex" | grep -q 'e2808b' \
    && die "zero-width U+200B reached the handoff line" \
    || pass "zero-width U+200B is not in the emitted bytes"
printf '%s' "$uni_line" | grep -q 'start' && printf '%s' "$uni_line" | grep -q 'end' \
    && pass "the printable parts of the summary survive" \
    || die "the summary was destroyed rather than reduced: $uni_line"


# ── The sentinel needs a shipping DRIVER CONTRACT, not just an implementation ─
# `--once` deliberately exits 0 after printing _REVIEW_PARSE_ERROR, and SKILL.md
# branched only on status=approved|comments_posted|error - so a polling driver
# had no defined action for it and could stall or, worse, read the silence as
# "no findings". The behaviour and the documents must move together.
SKILL_DOC="$SCRIPT_DIR/../SKILL.md"
README_DOC="$SCRIPT_DIR/../../../README.md"
if [ -f "$SKILL_DOC" ]; then
    grep -q '_REVIEW_PARSE_ERROR' "$SKILL_DOC" \
        && pass "SKILL.md documents the parse-error sentinel" \
        || die "SKILL.md never mentions _REVIEW_PARSE_ERROR (no driver contract)"
    grep -qi 'do \*\*not\*\* ack\|do not ack' "$SKILL_DOC" \
        && pass "SKILL.md forbids acking a sentinel" \
        || die "SKILL.md does not say a sentinel must not be acked"
    grep -qi 'exits \*\*0\*\*\|still exits' "$SKILL_DOC" \
        && pass "SKILL.md states --once exits 0 despite the sentinel" \
        || die "SKILL.md does not warn that the exit status is not the signal"
    grep -q 'LAST `resp=`\|last `resp=`' "$SKILL_DOC" \
        && pass "SKILL.md states the last-resp= parsing rule" \
        || die "SKILL.md does not state which resp= token to take"
else
    pass "SKILL.md not present beside the scripts; sentinel-contract checks skipped"
fi
if [ -f "$README_DOC" ]; then
    grep -q 'REVIEW_PARSE_ERROR' "$README_DOC" \
        && pass "README documents the user-visible sentinel outcome" \
        || die "README does not describe what a failed response looks like"
else
    pass "README not present; sentinel-outcome check skipped"
fi

# And the exact driver-facing flow: a bad response yields the sentinel, exit 0,
# no handoff, and a path that survives taking the LAST resp= token.
FLOW_BUS="$TMP/flowbus"; mkdir -p "$FLOW_BUS/responses"
printf '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex"}' \
    > "$FLOW_BUS/responses/resp-ba600de.json"
flow_rc=0
out_flow="$(BUS_DIR="$FLOW_BUS" MONITOR_EMITTED_DIR="$TMP/emflow" "$MONITOR" --once 2>/dev/null)" || flow_rc=$?
[ "$flow_rc" -eq 0 ] \
    && pass "driver flow: --once exits 0 even when it emitted only a sentinel" \
    || die "driver flow: --once exited $flow_rc (the docs promise 0)"
sent_line="$(printf '%s\n' "$out_flow" | grep -m1 'BUSTEST_REVIEW_PARSE_ERROR' || true)"
[ -n "$sent_line" ] && pass "driver flow: the sentinel line is present" \
    || die "driver flow: no sentinel emitted"
printf '%s' "$sent_line" | grep -q 'reason=' \
    && pass "driver flow: the sentinel names a reason" \
    || die "driver flow: sentinel carries no reason=: $sent_line"
[ "${sent_line##*resp=}" = "$FLOW_BUS/responses/resp-ba600de.json" ] \
    && pass "driver flow: the last resp= token is the response path" \
    || die "driver flow: last-resp= parsing gave '${sent_line##*resp=}'"
printf '%s' "$out_flow" | grep -q 'BUSTEST_REVIEW pr=' \
    && die "driver flow: a handoff was emitted alongside the sentinel: $out_flow" \
    || pass "driver flow: no handoff line accompanies the sentinel"


# ── a summary that normalises to nothing is not a verdict ──────────────────
# The guard validated the RAW summary with `\S`, which matches control and format
# code points - so a summary of NUL plus a bidi override passed, the formatter
# then replaced both with spaces, and the line went out as
# `status=approved summary="  "`: a terminal verdict the driver acts on, built
# from a response that says nothing.
n=0
for blank in \
    '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex","summary":"\u0000\u202e"}' \
    '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex","summary":"\u202e\u200b"}' \
    '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex","summary":"\u0000"}' \
    '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex","summary":"\u00a0\u00a0"}'
do
    n=$((n + 1))
    BLANK_BUS="$TMP/blankbus$n"; mkdir -p "$BLANK_BUS/responses"
    printf '%s' "$blank" > "$BLANK_BUS/responses/resp-ba600de.json"
    out_blank="$(BUS_DIR="$BLANK_BUS" MONITOR_EMITTED_DIR="$TMP/emblank$n" "$MONITOR" --once 2>/dev/null || true)"
    printf '%s' "$out_blank" | grep -q 'BUSTEST_REVIEW_PARSE_ERROR' \
        && pass "normalises-to-blank summary #$n reaches the sentinel" \
        || die "normalises-to-blank summary #$n was accepted (out='$out_blank')"
    printf '%s' "$out_blank" | grep -q 'status=approved' \
        && die "normalises-to-blank summary #$n emitted a terminal handoff: $out_blank" \
        || pass "normalises-to-blank summary #$n emitted no approved handoff"
done
# Control: a summary that is non-ASCII but has visible ASCII left is fine.
MIXOK_BUS="$TMP/mixokbus"; mkdir -p "$MIXOK_BUS/responses"
# `printf '%s' "<json>"`, never the JSON as printf's FORMAT string: printf
# interprets \uXXXX itself, which writes a raw NUL and produces a file jq cannot
# parse - the fixture would then "pass" by failing for the wrong reason.
printf '%s' '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex","summary":"\u202eok\u0000"}' \
    > "$MIXOK_BUS/responses/resp-ba600de.json"
out_mixok="$(BUS_DIR="$MIXOK_BUS" MONITOR_EMITTED_DIR="$TMP/emmixok" "$MONITOR" --once 2>/dev/null || true)"
printf '%s' "$out_mixok" | grep -q 'BUSTEST_REVIEW pr=7 .*status=approved' \
    && pass "a summary with visible ASCII left still emits its handoff" \
    || die "the guard rejected a summary that does normalise to something: $out_mixok"

# ── the sentinel must not repeat on every sweep ────────────────────────────
# The sentinel paths returned BEFORE claiming the per-digest emit marker, so the
# live loop re-emitted the same malformed response every MONITOR_POLL_SECONDS -
# forever, since the contract forbids acking it to make it stop.
REPEAT_BUS="$TMP/repeatbus"; mkdir -p "$REPEAT_BUS/responses"
printf '{"pr":7,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex"}' \
    > "$REPEAT_BUS/responses/resp-ba600de.json"
REPEAT_EMIT="$TMP/emrepeat"
c1="$(BUS_DIR="$REPEAT_BUS" MONITOR_EMITTED_DIR="$REPEAT_EMIT" "$MONITOR" --once 2>/dev/null | grep -c 'BUSTEST_REVIEW_PARSE_ERROR' || true)"
c2="$(BUS_DIR="$REPEAT_BUS" MONITOR_EMITTED_DIR="$REPEAT_EMIT" "$MONITOR" --once 2>/dev/null | grep -c 'BUSTEST_REVIEW_PARSE_ERROR' || true)"
c3="$(BUS_DIR="$REPEAT_BUS" MONITOR_EMITTED_DIR="$REPEAT_EMIT" "$MONITOR" --once 2>/dev/null | grep -c 'BUSTEST_REVIEW_PARSE_ERROR' || true)"
[ "$c1" -eq 1 ] && pass "the sentinel is emitted once" || die "first sweep emitted $c1 sentinels"
{ [ "$c2" -eq 0 ] && [ "$c3" -eq 0 ]; } \
    && pass "repeated sweeps do not repeat the sentinel (no flood)" \
    || die "the sentinel repeated on later sweeps ($c2, $c3)"
# No ACK may have been written - the response is unhandled, just not repeated.
ls "$REPEAT_BUS/.monitor-acked"/* >/dev/null 2>&1 \
    && die "the sentinel wrote an ack (the contract forbids it)" \
    || pass "the sentinel wrote no ack"
# A FRESH session still surfaces it.
c4="$(BUS_DIR="$REPEAT_BUS" MONITOR_EMITTED_DIR="$TMP/emrepeat2" "$MONITOR" --once 2>/dev/null | grep -c 'BUSTEST_REVIEW_PARSE_ERROR' || true)"
[ "$c4" -eq 1 ] \
    && pass "a fresh session re-surfaces the sentinel" \
    || die "a fresh session did not re-surface the sentinel ($c4)"
# And so does a CHANGED response, in the same session.
printf '{"pr":8,"sha":"ba600de","status":"approved","findings_count":0,"reviewer":"codex"}' \
    > "$REPEAT_BUS/responses/resp-ba600de.json"
c5="$(BUS_DIR="$REPEAT_BUS" MONITOR_EMITTED_DIR="$REPEAT_EMIT" "$MONITOR" --once 2>/dev/null | grep -c 'BUSTEST_REVIEW_PARSE_ERROR' || true)"
[ "$c5" -eq 1 ] \
    && pass "a changed response re-surfaces the sentinel in the same session" \
    || die "a changed malformed response did not re-surface ($c5)"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
