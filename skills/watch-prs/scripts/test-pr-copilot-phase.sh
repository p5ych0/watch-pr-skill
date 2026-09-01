#!/usr/bin/env bash
# Unit tests for pr-copilot-phase.sh.
#
# This is the Codex→Copilot transition, which lived in `SKILL.md` as 176 lines of
# prose-embedded shell that nothing executed. What it does is mostly ORDERING and
# REFUSING — prove the verdict on an exact sha, prove that sha's checks, record
# the signoff, and only then ask — so `gh` and the helpers are stubbed and every
# call is logged in sequence.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-copilot-phase.sh"

TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

HEAD40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER40=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
CODEXBOT='chatgpt-codex-connector[bot]'
COPILOTBOT='copilot-pull-request-reviewer[bot]'

# ── the harness ────────────────────────────────────────────────────────────
DIR="$TMP/s"; mkdir -p "$DIR" "$TMP/bin"
# `testlib.sh` IS STAGED TOO, because it is a RUNTIME dependency of this helper and
# not only the fixture watchdog: `open` bounds its baseline writes with `run_limited`,
# since opening a FIFO for writing blocks for a reader that never arrives. Same
# reason `pr-ci-state.sh` loads it. #243.
cp "$SCRIPT" "$SELF_DIR/loadlib.sh" "$SELF_DIR/recordlib.sh" "$SELF_DIR/identitylib.sh" \
   "$SELF_DIR/testlib.sh" "$DIR/" \
    || { die "the subject could not be staged"; echo "RESULT: FAIL"; exit 1; }
# `pr-review-state.sh` ANSWERS TWO DIFFERENT QUESTIONS HERE — `verdict` and
# `review-id` — and they fail independently, so the stub keys on the subcommand
# rather than serving one answer to both.
cat > "$DIR/pr-review-state.sh" <<'STATESH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$CALLS"
# A PUSH CAN LAND WHILE A PROBE RUNS. When the case asks for it, this moves the
# head during the lookup — which is exactly the window the re-read before the
# mutations exists to close.
[ -f "$W/move-head-on-probe" ] && cat "$W/move-head-on-probe" > "$W/head.out"
case "${1:-}" in
    verdict)   _n=$(( $(cat "$W/verdict.n" 2>/dev/null || echo 0) + 1 )); printf '%s' "$_n" > "$W/verdict.n"
               # A PUSH CAN LAND DURING A LATER PROBE TOO, after the first head
               # re-read has already passed — which is the window the read before
               # the post exists for.
               [ "$_n" -ge 2 ] && [ -f "$W/move-head-late" ] && cat "$W/move-head-late" > "$W/head.out"
               # `.3` IS THE READ THAT BINDS THE TIME TO A CLEAN VERDICT, after
               # the recheck and the re-proof — a result landing between the
               # cleanliness proof and the time read is what it exists to catch.
               if [ "$_n" -ge 3 ] && [ -f "$W/verdict.3.rc" ]; then
                   cat "$W/verdict.3.out" 2>/dev/null; exit "$(cat "$W/verdict.3.rc")"
               fi
               if [ "$_n" -ge 2 ] && [ -f "$W/verdict.2.rc" ]; then
                   cat "$W/verdict.2.out" 2>/dev/null; exit "$(cat "$W/verdict.2.rc")"
               fi
               cat "$W/verdict.out" 2>/dev/null
               exit "$(cat "$W/verdict.rc" 2>/dev/null || echo 0)" ;;
    clean-at)  # A PUSH CAN LAND DURING THIS PROBE, which is the window the head
               # read AFTER it exists for: this call is pinned to the sha being
               # signed off, so a head that moved while it ran leaves it answering
               # about a commit that is no longer the head.
               [ -f "$W/move-head-late" ] && cat "$W/move-head-late" > "$W/head.out"
               # CLEAN, AND WHEN, FROM ONE SNAPSHOT. `record` asked `verdict` and
               # then `review-at`, and a result arriving between them was the one
               # `review-at` timed. 0 the time, 1 no clean verdict on this head,
               # 2 unreadable. #139.
               cat "$W/clean-at.out" 2>/dev/null
               exit "$(cat "$W/clean-at.rc" 2>/dev/null || echo 0)" ;;
    review-at) # WHEN THE VERDICT LANDED, which is what a revocation is ORDERED
               # against: one posted BEFORE it is the pass answering it, one
               # posted after would cancel it. #115.
               cat "$W/review-at.out" 2>/dev/null
               exit "$(cat "$W/review-at.rc" 2>/dev/null || echo 0)" ;;
    review-id) # THE BASELINE IS READ ONCE, LAST. A pass that lands during the
               # probes must not be the value handed to `--after-review`, so the
               # fixture can change what this returns after the revocation.
               [ -f "$W/posted" ] && [ -f "$W/review-id.after.out" ] \
                   && { cat "$W/review-id.after.out"; exit 0; }
               cat "$W/review-id.out" 2>/dev/null
               exit "$(cat "$W/review-id.rc" 2>/dev/null || echo 0)" ;;
esac
exit 2
STATESH
chmod +x "$DIR/pr-review-state.sh"
cat > "$DIR/pr-signoff.sh" <<'SIGNSH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$CALLS"
# A SECOND ANSWER, FOR THE SECOND ASK. The phase is proved twice — once up front
# and once immediately before the mutations — and the whole question is what
# happens when another session changes something in between. `.2` is that change.
_n=$(( $(cat "$W/signoff.n" 2>/dev/null || echo 0) + 1 )); printf '%s' "$_n" > "$W/signoff.n"
# `.3` is the state changing DURING THE REVOCATION — the phase is proved a third
# time between that comment and the request, because the revocation is itself a
# mutation and the window after it is the one the request lands in.
if [ "$_n" -ge 3 ] && [ -f "$W/signoff.3.out" ]; then
    cat "$W/signoff.3.out"; exit "$(cat "$W/signoff.3.rc" 2>/dev/null || echo 0)"
fi
if [ "$_n" -ge 2 ] && [ -f "$W/signoff.2.out" ]; then
    cat "$W/signoff.2.out"; exit "$(cat "$W/signoff.2.rc" 2>/dev/null || echo 0)"
fi
[ -f "$W/signoff.out" ] && cat "$W/signoff.out"
exit "$(cat "$W/signoff.rc" 2>/dev/null || echo 0)"
SIGNSH
chmod +x "$DIR/pr-signoff.sh"
for h in pr-ci-gate.sh pr-round-count.sh; do
    cat > "$DIR/$h" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$0")" "\$*" >> "\$CALLS"
_n="\$(basename "\$0" .sh)"
[ -f "\$W/\${_n}.out" ] && cat "\$W/\${_n}.out"
exit "\$(cat "\$W/\${_n}.rc" 2>/dev/null || echo 0)"
STUB
    chmod +x "$DIR/$h"
done
# THE COMMENT BODY IS KEPT, not just the fact of the call. A summary that posts
# the signoff marker mangled, or the caller's paragraph expanded as shell, is a
# successful `gh pr comment` — so the fixture reads what was actually sent.
cat > "$TMP/bin/gh" <<'GHSH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$CALLS"
case " $* " in
    *" pr view "*)    # COUNTED, so a case can fail the SECOND or the LAST head read
                      # rather than the first. `head.rc` alone aborts at the
                      # initial capture and never reaches the later handlers, so a
                      # status-swallowing regression in either would go unseen.
                      _hn=$(( $(cat "$W/head.n" 2>/dev/null || echo 0) + 1 ))
                      printf '%s' "$_hn" > "$W/head.n"
                      cat "$W/head.out" 2>/dev/null
                      if [ -f "$W/head.rc.$_hn" ]; then exit "$(cat "$W/head.rc.$_hn")"; fi
                      exit "$(cat "$W/head.rc" 2>/dev/null || echo 0)" ;;
    *" pr comment "*) _b=""
                      while [ $# -gt 0 ]; do
                          [ "$1" = --body ] && { _b="$2"; break; }
                          shift
                      done
                      printf '%s' "$_b" >> "$W/posted"
                      exit "$(cat "$W/comment.rc" 2>/dev/null || echo 0)" ;;
    *" pr edit "*)    exit "$(cat "$W/edit.rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
GHSH
chmod +x "$TMP/bin/gh"

world() {   # world ; the state in which the phase advances cleanly
    W="$TMP/w"; rm -rf "$W"; mkdir -p "$W"; : > "$TMP/calls"
    printf '%s\n' "$HEAD40" > "$W/head.out"
    printf 'PR_REVIEW_STATE verdict=clean findings=0\n' > "$W/verdict.out"
    printf '42\n' > "$W/review-id.out"
    printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=2026-01-01T00:00:00Z id=901 sha=%s\n' \
        "$CODEXBOT" "$HEAD40" > "$W/signoff.out"
    # THE VERDICT LANDED AFTER THE REVOCATION IN `world`, which is the LEGITIMATE
    # shape: the fault-tolerance pass posts its revocation and then requests the
    # review, so a pass that comes back clean is answering it. #115.
    printf '2026-02-02T00:00:00Z\n' > "$W/review-at.out"
    printf '2026-02-02T00:00:00Z\n' > "$W/clean-at.out"
    printf 'the paragraph about what changed\n' > "$TMP/body.md"
}
run() {   # run <stage> [args…] ; prints "<rc>|<output>"
    local out rc=0
    # THE SHA FILE IS SUPPLIED FOR `record` WHEN THE CALLER GAVE ONLY THE BODY, which is
    # what the driver does with one of the working files setup creates. A case about the
    # argument itself passes its own third argument and this does nothing. #239.
    if [ "${1:-}" = record ] && [ "$#" -eq 3 ]; then set -- "$@" "$TMP/sha.txt"; fi
    # AND THE BASELINE FILE FOR `open`, on the same terms and for the same reason: the
    # driver hands `open` one of setup's working files, and a case about that argument
    # itself passes a third and this does nothing. #243.
    if [ "${1:-}" = open ] && [ "$#" -eq 3 ]; then set -- "$@" "$TMP/prior.txt"; fi
    out="$(cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        "$DIR/pr-copilot-phase.sh" "$@" 2>&1)" || rc=$?
    printf '%s|%s' "$rc" "$out"
}
posted() { cat "$W/posted" 2>/dev/null; }
# A PRODUCER'S STATUS IS NOT THE READER'S. `grep -q X <<<"$(producer)"` discards the
# substitution's status, so a producer that emits the expected marker and THEN fails
# — a truncated write, a missing file read halfway — leaves the reader matching and
# the assertion passing on an incomplete read. The pipeline this replaced took that
# status through `pipefail`; a herestring has no pipeline to take it from, so the
# capture has to. `_cap` takes it, reports it, and EMPTIES the value, because a
# partial read that still matches is the failure being guarded against.
_cap() { _CAP="$("$@")" || { die "producer failed: $*"; _CAP=; }; return 0; }

# DEFINED BESIDE `posted`, NOT BESIDE ITS FIRST USE. This file runs under
# `set -uo pipefail` WITHOUT `-e`, so a call before the definition prints
# `command not found` and carries on — the case then asserts nothing and the run
# can still end PASS, which is the "a failing probe looks like a clean phase"
# shape the whole file exists to catch.
nothing_posted() {   # nothing_posted <label>
    [ -s "$W/posted" ] \
        && die "$1 — but the signoff was posted anyway" \
        || pass "$1"
}
# `before <a> <b>` — a happened earlier in the call log than b.
before() {
    local la lb
    la="$(grep -n -- "$1" "$TMP/calls" | head -1 | cut -d: -f1)"
    lb="$(grep -n -- "$2" "$TMP/calls" | head -1 | cut -d: -f1)"
    { [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; }
}
# `last_before <a> <b>` — the LAST a in the log is earlier than the FIRST b. The
# plain `before` above cannot express this one: the head is read three times and
# every read logs the same text, so its first match is the read at the top of the
# stage and a probe that moved back ahead of the LAST read would still pass.
last_before() {
    local la lb
    la="$(grep -n -- "$1" "$TMP/calls" | tail -1 | cut -d: -f1)"
    lb="$(grep -n -- "$2" "$TMP/calls" | head -1 | cut -d: -f1)"
    { [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; }
}
# `last_after <a> <b>` — the LAST a in the log is later than the LAST b. The probe
# that decides the ordering is read twice and both reads log the same text, so
# only the last of them says which side of the verdict's time it fell on.
last_after() {
    local la lb
    la="$(grep -n -- "$1" "$TMP/calls" | tail -1 | cut -d: -f1)"
    lb="$(grep -n -- "$2" "$TMP/calls" | tail -1 | cut -d: -f1)"
    { [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -gt "$lb" ]; }
}

# ── the phase advances at all ──────────────────────────────────────────────
world; got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 0 ] && grep -qF "PR_PHASE_RECORDED pr=7 reviewer=$CODEXBOT codex-sha=$HEAD40" <<<"${got#*|}"; } \
    && pass "a clean Codex verdict records the phase" \
    || die "record gave '${got}'"

# ── AND `record` READS ITS SHA BACK THE SAME WAY ──────────────────────────
#
# The sha read-back gained the bounded open, its own status and the child-side comparison
# in #246, and none of its branches had a case: a regression removing the bound would hang
# `record` on a substituted path, and one mishandling the status would post the signoff
# after a transport that failed. The signoff is the irreversible part of this stage, so
# "did not post" is the assertion that matters.
#
# Staged through the same `timeout` hook as the baseline case — it stands between the
# bounded write and the bounded read — emptying the sha file so the read-back sees bytes
# that are not the ones written.
if command -v timeout >/dev/null 2>&1; then
    _rl_real2="$(command -v timeout)"
    world
    _rbs="$TMP/rbsha"; rm -rf "$_rbs"; mkdir -p "$_rbs"; : > "$_rbs/sha.txt"
    cat > "$TMP/bin/timeout" <<RLS
#!/usr/bin/env bash
"$_rl_real2" "\$@"; _rc=\$?
case "\$*" in *printf*) : > "\$RB_ZERO_TARGET" 2>/dev/null ;; esac
exit "\$_rc"
RLS
    chmod +x "$TMP/bin/timeout"
    # A NAME OF ITS OWN. `got` is still holding the ordinary `record` run that the
    # resume-command assertion below reads, and reusing it here made that assertion read
    # this refusal instead — a case failing on another case's evidence.
    _sha_got="$(RB_ZERO_TARGET="$_rbs/sha.txt" run record 7 "$TMP/body.md" "$_rbs/sha.txt")"
    rm -f "$TMP/bin/timeout"
    [ "${_sha_got%%|*}" = 1 ] \
        && pass "a sha that did not survive being written stops record" \
        || die "an emptied sha file gave '${_sha_got}'"
    nothing_posted "the sha did not survive the write"
    rm -rf "$_rbs"
else
    pass "no timeout on this platform, so the emptied-sha state is skipped by name"
fi

# ── AND THE RESUME COMMAND IT PRINTS IS ONE THAT RUNS ─────────────────────
#
# `record` stops and asks, and the whole point of stopping is that the answer can
# arrive in a LATER SESSION — which reaches `open` through this printed command and
# nothing else. When the baseline file became required, the command still showed two
# arguments, so following it aborted every time and the documented resume path was
# dead. A stage that prints its own successor has to print one that works.
# THE HEREDOC EXPANDS, so what is matched is the command an operator would COPY —
# the PR and the sha resolved, the baseline a literal placeholder. Matching the
# source spelling instead passes while the printed line says something else.
_menu="${got#*|}"
grep -qF "pr-copilot-phase.sh open 7 $HEAD40 <baseline-file>" <<<"$_menu" \
    && pass "…and the resume command it prints carries the baseline file it now requires" \
    || die "record advertises an open command that would abort: $_menu"
# ASSERTED AGAINST THE STAGE'S OWN ARGUMENT COUNT, not against the text alone. A
# renamed placeholder keeps the grep above green while the count moves underneath it.
_open_args="$(grep -c 'PRIOR_FILE="${3:-}"' "$DIR/pr-copilot-phase.sh")"
[ "$_open_args" = 1 ] \
    && pass "…and that third argument is the one open reads" \
    || die "open does not read a third argument; the printed command names one anyway"

# ── AND THE SIGNED-OFF SHA IS HANDED BACK IN A FILE ───────────────────────
# #239. The driver read it back with `pr-signoff.sh sha` and then validated the result
# with a regex and a status check — a second round-trip to the API, and eleven lines of
# the one shell nothing can harden, for a value this stage proved and holds.
[ "$(cat "$TMP/sha.txt" 2>/dev/null)" = "$HEAD40" ] \
    && pass "…and writes the signed-off sha into the file the caller named" \
    || die "the sha file holds '$(cat "$TMP/sha.txt" 2>/dev/null)', not $HEAD40"
# …AND NO REFUSAL CLEARS IT, WHICH IS #245. There were two clearings and neither protected
# a read that can happen: the driver reads `$HEAD_FILE` in the success arm and in the `3`
# arm, every refusal exits 1 into the `*)` arm which reads nothing, and on success or pause
# the WRITE has already replaced the file. Both were unbounded truncating opens on a
# caller-named path — `>` follows a symlink and truncates its target — so they could destroy
# an operator's file to protect nothing.
#
# What is pinned here is that the previous value is LEFT, on a refusal after the bootstrap
# and on one before it, so a later change restoring either clearing has to say why. The
# consequence they used to stand for is asserted where it lives, in
# `test-pr-skill-contract.sh`: a refused record fence assigns no `CODEX_SHA` and disturbs no
# retained one.
world; printf '%s\n' 'STALE-SHA' > "$TMP/sha.txt"
got="$(run record 7 "$TMP/nope.md")"
{ [ "${got%%|*}" != 0 ] && [ "$(cat "$TMP/sha.txt")" = 'STALE-SHA' ]; } \
    && pass "…and a refusal after the bootstrap leaves the sha file alone" \
    || die "a refused record did something other than leave the sha file alone (got '$got', sha=[$(cat "$TMP/sha.txt" 2>/dev/null)])"
world; printf '%s\n' 'STALE-SHA' > "$TMP/sha.txt"
got="$(run record notanumber "$TMP/body.md")"
{ [ "${got%%|*}" != 0 ] && [ "$(cat "$TMP/sha.txt")" = 'STALE-SHA' ]; } \
    && pass "…and so does one refusing before the arguments are checked" \
    || die "an argument refusal did something other than leave the sha file alone (got '$got', sha=[$(cat "$TMP/sha.txt" 2>/dev/null)])"
world; printf '%s\n' 'STALE-SHA' > "$TMP/sha.txt"
rm -rf "$TMP/broken"; cp -R "$DIR" "$TMP/broken" || die "could not copy the scripts for the bootstrap case"
: > "$TMP/broken/recordlib.sh"
_bs_rc=0
_bs_out="$(cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    "$TMP/broken/pr-copilot-phase.sh" record 7 "$TMP/body.md" "$TMP/sha.txt" 2>&1)" || _bs_rc=$?
{ [ "$_bs_rc" != 0 ] && [ "$(cat "$TMP/sha.txt")" = 'STALE-SHA' ]; } \
    && pass "…and so does one that cannot bootstrap at all" \
    || die "a bootstrap refusal did something other than leave the sha file alone (rc=$_bs_rc out='$_bs_out')"

# AND A FIFO AT THE SHA PATH STOPS THE STAGE RATHER THAN HANGING IT. With the clearings
# gone the WRITE is the only open on that path, and it is bounded — so this now proves the
# bound on the write, with nothing posted, since the write precedes the signoff.
if command -v mkfifo >/dev/null 2>&1; then
    world; rm -f "$TMP/shafifo"
    mkfifo "$TMP/shafifo" 2>/dev/null && {
        _sf_got="$(run record 7 "$TMP/body.md" "$TMP/shafifo")"
        # THE HELPER'S OWN REFUSAL, NOT THE HARNESS WATCHDOG'S. `run` wraps every call in
        # `run_limited 25`, so an UNBOUNDED write would block on the FIFO until that fired
        # and come back 124 — which "not zero" accepts, and the case would report the write
        # as bounded precisely when it is not. Status 1 is the helper refusing; 124 and 125
        # are the harness saying it never did.
        case "${_sf_got%%|*}" in
            1) pass "…and a FIFO at the sha path stops record instead of hanging it" ;;
            124|125) die "record hung on the FIFO and the harness watchdog stopped it: '${_sf_got}'" ;;
            *) die "a FIFO sha path gave '${_sf_got}'" ;;
        esac
        nothing_posted "the sha path was a FIFO"
    }
    rm -f "$TMP/shafifo"
else
    pass "no mkfifo on this platform, so the FIFO sha path is skipped by name"
fi
# AND IT REFUSED FOR THE REASON THIS CASE IS ABOUT, not for an argument it never reached.
case "$_bs_out" in
    *reason=recordlib_empty*|*reason=loadlib_*)
        pass "…having refused in the bootstrap, before any argument was looked at" ;;
    *)  die "the bootstrap case refused for another reason: '$_bs_out'" ;;
esac

# …AND THE BODY FILE SURVIVES THE ALIAS REFUSAL. There is no clearing left to protect it
# from; what can destroy it is the WRITE, which opens `$SHA_FILE` truncating, so the alias
# has to be refused BEFORE anything is written. Staged as the alias: the account must
# survive to be refused properly.
world; printf 'the account\n' > "$TMP/body.md"
got="$(run record 7 "$TMP/body.md" "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && [ -s "$TMP/body.md" ]; } \
    && pass "…and the alias is refused before the write, so the account is still there" \
    || die "the alias refusal emptied the account: '$(cat "$TMP/body.md" 2>/dev/null)'"
# …AND THE FILE IS NOT THE BODY FILE, by path and under another name.
world; got="$(run record 7 "$TMP/body.md" "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'overwrite the account' <<<"${got#*|}"; } \
    && pass "…and a sha file that IS the body file is refused" \
    || die "the sha/body alias gave '$got'"
world; ln -sf "$TMP/body.md" "$TMP/salias.txt"
got="$(run record 7 "$TMP/body.md" "$TMP/salias.txt")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'overwrite the account' <<<"${got#*|}"; } \
    && pass "…and so is a symlink to it" \
    || die "the symlinked sha/body alias gave '$got'"
rm -f "$TMP/salias.txt"
# …AND A SHA FILE THAT CANNOT BE WRITTEN STOPS THE STAGE BEFORE THE POST, which is the
# ordering that matters: after the comment the signoff is on the PR and the stage cannot
# be un-run. A DIRECTORY at the path takes neither the truncation nor the write.
world; rm -rf "$TMP/shadir"; mkdir -p "$TMP/shadir"
got="$(run record 7 "$TMP/body.md" "$TMP/shadir")"
{ [ "${got%%|*}" = 1 ] && grep -qF "$TMP/shadir" <<<"${got#*|}"; } \
    && pass "…and a sha file it cannot write stops the stage" \
    || die "the unwritable sha file gave '$got'"
grep -q 'gh pr comment' "$TMP/calls" \
    && die "the stage posted the signoff before handing the sha back" \
    || pass "…before the signoff was posted"
rm -rf "$TMP/shadir"
# BACK TO A CLEAN RECORD for the assertions below, which read this run's output.
world; got="$(run record 7 "$TMP/body.md")"
grep -qF "pr-copilot-phase.sh open 7 $HEAD40" <<<"${got#*|}" \
    && pass "…and the stop names the command that opens the phase" \
    || die "the operator stop does not say how to resume: '${got#*|}'"

# ── WHAT IT POSTS IS THE RECORD SOMETHING LATER READS BACK ─────────────────
# AND IT HAS TO DESCRIBE THE VERDICT THAT WAS PROVED CLEAN. `review-at` reports
# the LATEST verdict on this sha, so a result landing between the cleanliness
# proof and that read is the one it times — and the record would claim to answer
# a verdict nobody proved. Re-proving cleanliness binds them; where it no longer
# holds the RECORD IS REFUSED, because cleanliness is a precondition for recording
# at all rather than a value the record carries.
# A PUSH DURING THE TIME PROBES IS CAUGHT, because the head read comes after
# them. Both are pinned to `$CODEX_SHA`, so a head that moved while they ran
# leaves them answering about a commit that is no longer the head — and the record
# would name it.
world; printf '%s\n' "$OTHER40" > "$W/move-head-late"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'the head moved to' <<<"${got#*|}"; } \
    && pass "a push landing during the verdict-time probes stops the record" \
    || die "a push during the time probes gave '${got}'"
nothing_posted "…with no signoff naming the commit it outlived"

# CLEANLINESS IS A PRECONDITION, NOT A VALUE THE RECORD CARRIES. Dropping only
# the timestamp would post a signoff for a verdict that is no longer clean, which
# is worse than never having looked.
# A `1` IS NOT AN ABSENCE HERE. `clean-at` answers 1 when there is no clean
# verdict on this head, and this stage has already proved there is one — so a `1`
# means it stopped being clean while this ran. Cleanliness is a precondition for
# recording at all, not a value the record carries.
world; printf '1\n' > "$W/clean-at.rc"; : > "$W/clean-at.out"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'no longer clean' <<<"${got#*|}"; } \
    && pass "a verdict that stopped being clean while its time was read stops the record" \
    || die "a moved verdict gave '${got}'"
nothing_posted "…with no signoff recorded for it"
# AN UNREADABLE ANSWER COSTS THE CLEANLINESS PROOF, NOT ONLY THE TIME. This call
# IS the last proof, so degrading to "no timestamp" would record a signoff whose
# newest evidence predates the probe that failed — and a blocking verdict can land
# in exactly that round trip. The cleanliness is asked for on its own, and the
# record still carries no time.
world; printf '2\n' > "$W/clean-at.rc"; : > "$W/clean-at.out"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 0 ] && grep -qF 'will not carry one' <<<"${got#*|}"; } \
    && pass "…while an unreadable one records without the field rather than stopping" \
    || die "an unreadable clean-at gave '${got}'"
# AND THAT RE-PROOF IS A REFUSAL WHERE IT COMES BACK NON-CLEAN.
world; printf '2\n' > "$W/clean-at.rc"; : > "$W/clean-at.out"
printf '1\n' > "$W/verdict.2.rc"
printf 'PR_REVIEW_STATE verdict=findings findings=1\n' > "$W/verdict.2.out"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'no longer clean' <<<"${got#*|}"; } \
    && pass "…and a blocking verdict landing during that failed read still stops it" \
    || die "an unreadable clean-at skipped the cleanliness re-proof: '${got}'"
nothing_posted "…with no signoff recorded for it"

# THE MARKER CARRIES THE VERDICT TIME, as its third backticked field: a reader can
# then order a revocation against the VERDICT rather than against comment order,
# which is the window this stage cannot close itself — its own write is what
# erases the evidence. #137, for #122.
world; got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 0 ] || die "the ordinary record did not post: '${got}'"
_cap posted
grep -qF "**Review-Signoff:** \`$CODEXBOT\` \`$HEAD40\` \`2026-02-02T00:00:00Z\`" <<<"$_CAP" \
    && pass "the signoff marker carries the time of the verdict it answers" \
    || die "the marker does not carry the verdict time: '$(posted)'"

# The marker's format is `pr-signoff.sh`'s: the name and the sha in backticks, on
# a line of their own. Composed here rather than left to the caller's prose,
# because a marker one character off signs nothing off and still looks posted.
_cap posted
grep -qF "**Review-Signoff:** \`$CODEXBOT\` \`$HEAD40\`" <<<"$_CAP" \
    && pass "the summary carries the signoff marker in the form pr-signoff.sh reads" \
    || die "the posted marker was: $(posted | head -3)"
_cap posted
grep -qF 'the paragraph about what changed' <<<"$_CAP" \
    && pass "…and the caller's account of the phase" \
    || die "the caller's body is not in what was posted"
_cap posted
grep -qF 'Review-Phase: copilot' <<<"$_CAP" \
    && pass "…and the trailer the merge gate depends on" \
    || die "the trailer note is missing from the summary"

# THE BODY IS DATA, NOT A TEMPLATE. This was a heredoc the shell expanded: a
# summary quoting a finding about a command substitution EXECUTED it while being
# written, and text lifted from an untrusted PR description is the same
# substitution with someone else choosing the command. Where it did not execute it
# vanished silently, which is worse — `cat` still succeeded.
world; printf 'before $(touch %s/PWNED) `touch %s/PWNED2` after\n' "$W" "$W" > "$TMP/body.md"
run record 7 "$TMP/body.md" >/dev/null
{ [ ! -f "$W/PWNED" ] && [ ! -f "$W/PWNED2" ]; } \
    && pass "a body containing shell substitutions is not executed while being written" \
    || die "the body was executed: $(ls "$W")"
_cap posted
grep -qF '$(touch' <<<"$_CAP" \
    && pass "…and reaches the PR verbatim rather than silently emptied" \
    || die "the substitution vanished from the posted body: $(posted)"

# ── THE VERDICT AND THE CHECKS ARE ABOUT THE CAPTURED SHA ──────────────────
# Not about "whatever the API calls the head now". A push landing between the
# verdict and this lookup records an unreviewed head as the signoff, and the merge
# gate only discovers the missing verdict after the whole Copilot phase has run.
world; run record 7 "$TMP/body.md" >/dev/null
grep -qF "pr-review-state.sh verdict 7 $CODEXBOT $HEAD40" "$TMP/calls" \
    && pass "the verdict is re-validated against the sha being recorded" \
    || die "the verdict was not pinned to the captured sha: $(grep review-state "$TMP/calls")"
grep -qF "pr-ci-gate.sh 7 $HEAD40" "$TMP/calls" \
    && pass "…and the checks are asked about that same sha" \
    || die "the CI gate was not pinned to the captured sha: $(grep ci-gate "$TMP/calls")"
# NOTHING IS PUBLISHED UNTIL ALL THREE HAVE ANSWERED — the verdict, the checks
# and the round count. Establishing the boundary and ACTING on it are separate:
# the count is read before the post so an unreadable one leaves nothing behind,
# and the pause is taken after it, because the pause offers "merge on the Codex
# signoff" and that signoff has to exist by then. Nothing in this stage requests a
# review, so publishing before the pause queues nothing.
{ before 'pr-review-state.sh verdict' 'pr-ci-gate' \
    && before 'pr-ci-gate' 'pr-round-count' \
    && before 'pr-round-count' 'gh pr comment'; } \
    && pass "…and nothing is published until the head and the boundary are both established" \
    || die "the phase posted before it had proved the head: $(cat "$TMP/calls")"

# ── EVERY PROOF IS A STOP, AND NOTHING IS RECORDED WHEN ONE FAILS ──────────
# A failed probe must never be indistinguishable from a clean phase: the signoff
# is what a later session trusts, so recording one that was not proven is the
# failure this whole file exists to prevent.
world; printf '1\n' > "$W/verdict.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'Codex is not clean on the sha being recorded' <<<"${got#*|}"; } \
    && pass "a verdict that is not clean stops the phase" \
    || die "an unclean verdict gave '${got}'"
nothing_posted "…with no signoff recorded"

world; printf '1\n' > "$W/pr-ci-gate.rc"
got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 1 ] \
    && pass "a head whose checks are not green stops the phase" \
    || die "a failing CI gate gave '${got}'"
nothing_posted "…with no signoff recorded"

world; printf '1\n' > "$W/head.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'could not capture the Codex-signed-off head' <<<"${got#*|}"; } \
    && pass "an unreadable head stops the phase" \
    || die "an unreadable head gave '${got}'"
nothing_posted "…with no signoff recorded"

world; printf 'not-a-sha\n' > "$W/head.out"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'is not a full OID' <<<"${got#*|}"; } \
    && pass "a head that is not a full OID stops the phase" \
    || die "a malformed head gave '${got}'"
nothing_posted "…with no signoff recorded"

# ── `record` RE-PROVES THE PHASE IMMEDIATELY BEFORE IT PUBLISHES ──────────
#
# The CI gate WAITS for checks to settle and the round count is a network read, so
# the window between the last proof and the irreversible post is as long as a
# build. In it another session can post a `**Review-Signoff-Revoked:**` — how a
# phase is deliberately reopened — and this stage's signoff would SUPERSEDE it,
# because the readers take the last record, while GitHub keeps serving the old
# clean verdict until the new pass reports. A later `open` then finds a current
# signoff and a clean verdict and requests Copilot underneath a reopened phase.
# #115.
#
# A REVOCATION IN THAT WINDOW IS REFUSED BY ORDER, NOT BY PRESENCE. The first fix
# refused on any revocation and broke the legitimate path: the fault-tolerance pass
# posts its revocation BEFORE requesting the review, so it is still the newest
# record when the new clean verdict arrives — an unconditional refusal means a
# reopened phase can never record its replacement signoff.
#
# TELLING THEM APART IS ORDERING, and the records carry it — #117 landed `at=` and
# `id=` on a revocation and taught `review-at` the comment channel; #115 compares
# them. The cases below cover both sides of that comparison and every shape it
# cannot order. This first one is the legitimate case: a revocation already on the
# PR, OLDER than the clean verdict, still records.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=2026-01-01T00:00:00Z id=901 sha=none reason=revoked\n' \
    "$CODEXBOT" > "$W/signoff.out"
printf '1\n' > "$W/signoff.rc"
got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 0 ] \
    && pass "a reopened phase with a clean verdict records its replacement signoff" \
    || die "a pre-existing revocation blocked the reopened phase: '${got}'"
# ── AND THE ORDERING PROOF IS THE LAST THING BEFORE THE WRITE ──────────────
# WHICH OF THE TWO FINAL PROOFS GOES LAST IS ITSELF THE INVARIANT, and no case
# above can see it: each asserts an ANSWER, and every one of them stays green with
# the ordering probe moved back ahead of the final head read — which is where it
# was written first.
#
# THE TWO POSITIONS ARE NOT INTERCHANGEABLE. A head that moves after its proof is
# caught downstream: `open` re-reads it and refuses a head that is not the recorded
# sha, so nothing is lost but a run. A revocation that lands after its proof is
# destroyed by the signoff posted next, because the readers take the last record,
# and no later stage can find it. The unrecoverable one goes last, and the window
# it leaves is #122.
#
# THIS RUN IS THE ONE THAT REACHES BOTH PROBES: `world`'s revocation is older than
# the verdict, so the ordering branch runs in full rather than short-circuiting.
last_before 'gh pr view' 'pr-signoff.sh' \
    && pass "…the final head read having come before the ordering probe" \
    || die "the ordering probe ran before the last head read: $(cat "$TMP/calls")"
last_after 'gh pr view' 'pr-review-state.sh clean-at' \
    && pass "…and after the verdict's time was read, which it is pinned past" \
    || die "the last head read came before the verdict time probes: $(cat "$TMP/calls")"
before 'pr-signoff.sh' 'gh pr comment' \
    && pass "…with the ordering probe itself immediately before the write" \
    || die "the signoff was posted before the ordering was proved: $(cat "$TMP/calls")"
before 'pr-review-state.sh clean-at' 'gh pr comment' \
    && pass "…and the verdict's time read before it too" \
    || die "the signoff was posted before the verdict's time was read: $(cat "$TMP/calls")"

# …AND A REVOCATION LANDING AFTER THE VERDICT CANCELS IT, which is the state #115
# is about: another session reopens the phase while the head is unchanged and
# GitHub still serves the old clean verdict, so both head reads and the verdict
# check pass. Recording here would SUPERSEDE that revocation, because the readers
# take the last record, and a later `open` would request Copilot underneath a
# phase somebody had deliberately reopened.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=2026-03-03T00:00:00Z id=902 sha=none reason=revoked\n' \
    "$CODEXBOT" > "$W/signoff.out"
printf '1\n' > "$W/signoff.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'this phase was reopened' <<<"${got#*|}"; } \
    && pass "a revocation newer than the verdict stops the record" \
    || die "a cancelling revocation was recorded over: '${got}'"
nothing_posted "…with no signoff recorded, so it cannot supersede the revocation"
# EQUAL IS A REFUSAL, and it is the one case this cannot decide: `created_at` is
# second-resolution and the two records come from different resources, so their
# ids are not comparable. Refusing costs a rerun once the clock has moved.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=2026-02-02T00:00:00Z id=903 sha=none reason=revoked\n' \
    "$CODEXBOT" > "$W/signoff.out"
printf '1\n' > "$W/signoff.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'this phase was reopened' <<<"${got#*|}"; } \
    && pass "…and one at the same second refuses, since nothing here can order them" \
    || die "a same-second revocation was recorded over: '${got}'"
nothing_posted "…with no signoff recorded"
# A REVOCATION WITH NO TIME CANNOT BE ORDERED, and a record this stage cannot
# place is not one to record over. `pr-signoff.sh` has carried `at=` on one since
# #117, so this is a record from something else.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s sha=none reason=revoked\n' "$CODEXBOT" > "$W/signoff.out"
printf '1\n' > "$W/signoff.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'carries no time' <<<"${got#*|}"; } \
    && pass "…and an untimed revocation refuses rather than being assumed older" \
    || die "an untimed revocation was recorded over: '${got}'"
nothing_posted "…with no signoff recorded"
# …AND A TIME OF ANOTHER SHAPE IS REFUSED RATHER THAN COMPARED. These are ordered
# as STRINGS, which is the time order only for canonical UTC — a value of another
# shape sorts somewhere arbitrary, and one sorting low reads as "the revocation is
# older", which is the answer that records over a reopening.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=yesterday id=906 sha=none reason=revoked\n' \
    "$CODEXBOT" > "$W/signoff.out"
printf '1\n' > "$W/signoff.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'its time is unreadable' <<<"${got#*|}"; } \
    && pass "…and a revocation time of another shape refuses rather than sorting low" \
    || die "an unshaped revocation time was compared: '${got}'"
nothing_posted "…with no signoff recorded"
world; printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=2026-01-01T00:00:00Z id=907 sha=none reason=revoked\n' \
    "$CODEXBOT" > "$W/signoff.out"
printf '1\n' > "$W/signoff.rc"; printf 'soon\n' > "$W/clean-at.out"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'readable time' <<<"${got#*|}"; } \
    && pass "…and the same on the verdict's side" \
    || die "an unshaped verdict time was compared: '${got}'"
nothing_posted "…with no signoff recorded"

# AND AN UNREADABLE OR UNTIMED VERDICT IS A REFUSAL TOO: with a revocation
# standing, "no verdict on this head has a time" is exactly the state that must
# not record.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=2026-01-01T00:00:00Z id=904 sha=none reason=revoked\n' \
    "$CODEXBOT" > "$W/signoff.out"
printf '1\n' > "$W/signoff.rc"; printf '2\n' > "$W/clean-at.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'no verdict on' <<<"${got#*|}"; } \
    && pass "…and an unreadable verdict time refuses with a revocation standing" \
    || die "an unreadable verdict time was recorded over: '${got}'"
nothing_posted "…with no signoff recorded"
world; printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=2026-01-01T00:00:00Z id=905 sha=none reason=revoked\n' \
    "$CODEXBOT" > "$W/signoff.out"
printf '1\n' > "$W/signoff.rc"; : > "$W/clean-at.out"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'readable time' <<<"${got#*|}"; } \
    && pass "…and an empty one, which is 'no verdict on this head at all'" \
    || die "an untimed verdict was recorded over: '${got}'"
nothing_posted "…with no signoff recorded"
# AND WITH NO REVOCATION ITS ABSENCE DOES NOT STOP THE RECORD. The time is asked
# for on every path now, because the signoff CARRIES it — but the field is
# optional, so an unreadable probe degrades to a record without one, which reads
# back exactly as every record written before #135 does. A signoff that cannot be
# ordered against a revocation is the state we already live in; a phase that
# cannot close because a probe failed is worse. #137.
world; printf '2\n' > "$W/clean-at.rc"
got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 0 ] \
    && pass "…while an unreadable verdict time does not stop an ordinary phase" \
    || die "an unreadable verdict time stopped the record: '${got}'"
grep -qF 'will not carry one' <<<"${got#*|}" \
    && pass "…and it says the signoff carries none, rather than degrading in silence" \
    || die "the record was posted without a verdict time and did not say so: '${got#*|}'"
_cap posted
grep -qF '**Review-Signoff:**' <<<"$_CAP" \
    && pass "…with the marker still posted" \
    || die "no signoff marker was posted: '$(posted)'"
_cap posted
grep -qE '\*\*Review-Signoff:\*\* `[^`]+` `[0-9a-f]{40}` `' <<<"$_CAP" \
    && die "…but it carried an empty verdict field, which pr-signoff.sh refuses" \
    || pass "…and no empty third field, which the reader would refuse"

# ── THE RECORD COMPARED IS READ AFTER THE VERDICT'S TIME, NOT BEFORE IT ────
# ASKING ONCE AND THEN FETCHING THE TIME RE-OPENED THE WINDOW ONE LEVEL DOWN. The
# first ask is the TRIGGER — whether there is an ordering question at all, which
# is what keeps `review-at` out of the ordinary phase — and it is stale the moment
# the fetch begins. A revocation posted DURING that fetch is the case: compared as
# the record the first ask saw, it is ordered as the older one and the signoff
# goes out over it.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=2026-01-01T00:00:00Z id=910 sha=none reason=revoked\n' \
    "$CODEXBOT" > "$W/signoff.out"
printf '1\n' > "$W/signoff.rc"
printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=2026-03-03T00:00:00Z id=911 sha=none reason=revoked\n' \
    "$CODEXBOT" > "$W/signoff.2.out"
printf '1\n' > "$W/signoff.2.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'this phase was reopened' <<<"${got#*|}"; } \
    && pass "a revocation landing while the verdict's time is read is the one compared" \
    || die "a revocation posted during the fetch was ordered as the stale one: '${got}'"
nothing_posted "…with no signoff recorded over it"
# AND IF THE NEWEST RECORD IS NO LONGER A REVOCATION, this stage cannot place what
# it was about to act on. A rerun costs one round trip; guessing costs the
# reopening. The ordinary phase never comes through here — it did not enter the
# branch.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=2026-01-01T00:00:00Z id=912 sha=none reason=revoked\n' \
    "$CODEXBOT" > "$W/signoff.out"
printf '1\n' > "$W/signoff.rc"
printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=2026-03-03T00:00:00Z id=913 sha=%s\n' \
    "$CODEXBOT" "$HEAD40" > "$W/signoff.2.out"
printf '0\n' > "$W/signoff.2.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'the newest record changed' <<<"${got#*|}"; } \
    && pass "…and a newest record that stopped being a revocation refuses" \
    || die "a changed record was acted on anyway: '${got}'"
nothing_posted "…with no signoff recorded"
# THE POSITION ITSELF, which no answer above asserts: both reads log the same
# text, so only the LAST one distinguishes the order this case exists for.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=2026-01-01T00:00:00Z id=914 sha=none reason=revoked\n' \
    "$CODEXBOT" > "$W/signoff.out"
printf '1\n' > "$W/signoff.rc"
got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 0 ] || die "the ordering case did not record: '${got}'"
last_after 'pr-signoff.sh' 'pr-review-state.sh clean-at' \
    && pass "…the record compared having been read after the verdict's time" \
    || die "the compared record was read before the verdict's time: $(cat "$TMP/calls")"
last_before 'pr-signoff.sh' 'gh pr comment' \
    && pass "…and nothing but the write behind it" \
    || die "the signoff was posted before the record was re-read: $(cat "$TMP/calls")"

# ── AND NEITHER READ MAY FAIL QUIETLY ──────────────────────────────────────
# AN UNREADABLE SIGNOFF PROBE IS NOT "NO REVOCATION". Both reads are checked,
# because they fail independently: the trigger decides whether the ordering
# question is asked at all, and the re-read decides the answer.
world; printf '2\n' > "$W/signoff.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'could not read the signoff record' <<<"${got#*|}"; } \
    && pass "an unreadable signoff probe stops the record rather than reading as no revocation" \
    || die "an unreadable signoff probe gave '${got}'"
nothing_posted "…with no signoff recorded"
world; printf 'PR_SIGNOFF pr=7 reviewer=%s verdict-at=none at=2026-01-01T00:00:00Z id=915 sha=none reason=revoked\n' \
    "$CODEXBOT" > "$W/signoff.out"
printf '1\n' > "$W/signoff.rc"
printf '2\n' > "$W/signoff.2.rc"; : > "$W/signoff.2.out"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'could not re-read the signoff record' <<<"${got#*|}"; } \
    && pass "…and so does an unreadable re-read, which is the one the comparison uses" \
    || die "an unreadable re-read gave '${got}'"
nothing_posted "…with no signoff recorded"

# A PUSH IN THE SAME WINDOW, which the head re-read catches. `move-head-on-probe`
# fires on the FIRST verdict call, so this is a push landing before the CI gate.
world; printf '%s\n' "$OTHER40" > "$W/move-head-on-probe"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'the head moved to' <<<"${got#*|}"; } \
    && pass "…and a push landing in that window stops it too" \
    || die "a moved head gave '${got}'"
nothing_posted "…with no signoff recorded"
# AND EITHER LATE HEAD READ FAILING STOPS IT. `head.rc` alone aborts at the first
# capture, so neither of the new handlers was ever reached: a regression that
# swallowed one of their statuses would publish a signoff with every case green.
# The stub counts its calls, so a case can fail exactly the second or the third —
# each printing a plausible `$HEAD40` first, which is what makes a swallowed
# status look like success.
for _n in 2 3; do
    world; printf '1\n' > "$W/head.rc.$_n"
    got="$(run record 7 "$TMP/body.md")"
    { [ "${got%%|*}" = 1 ] && grep -qF 'could not re-read the head' <<<"${got#*|}"; } \
        && pass "…and head read #$_n failing after printing a plausible sha stops it" \
        || die "head read #$_n failing gave '${got}'"
    nothing_posted "…with no signoff recorded"
done

# A PUSH DURING THE LATER PROBES, which the FIRST re-read cannot catch: it has
# already passed, and the verdict is pinned to `$CODEX_SHA` so it stays clean and
# says nothing about the move. Only re-reading the head last closes it. The
# verdict stub moves it on its SECOND call — the one after the CI gate — so the
# change lands after the first head check and before the post.
world; printf '%s\n' "$OTHER40" > "$W/move-head-late"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'the head moved to' <<<"${got#*|}"; } \
    && pass "…and one landing during the later probes stops it as well" \
    || die "a head moved during the signoff probe gave '${got}'"
nothing_posted "…with no signoff recorded"
# A DISMISSAL IN THE SAME WINDOW, which `clean-at` catches: the check before the
# CI gate is one call, and the one before the post is `clean-at` — which answers
# 1 for "no clean verdict on this head", and this stage has already proved there
# was one. #139 folded the separate re-read into it.
world; printf '1\n' > "$W/clean-at.rc"; : > "$W/clean-at.out"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'no longer clean on' <<<"${got#*|}"; } \
    && pass "…and a verdict withdrawn in that window stops it" \
    || die "a withdrawn verdict gave '${got}'"
nothing_posted "…with no signoff recorded"

# THE ABBREVIATED SHA IS THE ONE THAT MATTERS. `pr-review-state.sh` prints seven
# characters and the merge gate needs forty, so a phase recorded from the short
# form populates the gate with something it cannot match.
world; printf '%s\n' "${HEAD40:0:7}" > "$W/head.out"
got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 1 ] \
    && pass "…and so does an abbreviated one" \
    || die "a 7-character head gave '${got}'"

# ── THE BOUNDARY PAUSES THE TRANSITION ─────────────────────────────────────
# A phase that ends on the threshold-th reviewed head went straight from a clean
# verdict into the next phase, so the pause was skipped in exactly the case it
# exists for: long enough to reach the boundary AND about to commit to more work.
world; printf '3\n' > "$W/pr-round-count.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 3 ] && grep -qF 'round boundary reached' <<<"${got#*|}"; } \
    && pass "a round boundary pauses the transition" \
    || die "a boundary gave '${got}'"
# THE RECORD SURVIVES THE PAUSE. The boundary message offers "merge on the Codex
# signoff" and "leave it open", so a pause that exited before posting left the
# operator neither a durable signoff for a later session nor the sha the
# codex-only merge needs — they had to acknowledge the boundary and re-run this
# stage to recover a phase that was already proved clean.
_cap posted
grep -qF "**Review-Signoff:** \`$CODEXBOT\` \`$HEAD40\`" <<<"$_CAP" \
    && pass "…with the signoff recorded, since the pause offers merging on it" \
    || die "the pause discarded the signoff it offers to merge on: $(posted)"
grep -qF "codex-sha=$HEAD40" <<<"${got#*|}" \
    && pass "…and the sha reported, so the codex-only merge path has it" \
    || die "the pause reported no sha: '${got#*|}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "the pause opened the Copilot phase anyway" \
    || pass "…and nothing requested, which is what the pause is for"

# AN UNREADABLE COUNT IS A STOP, AND A STOP LEAVES NOTHING BEHIND. Establishing
# the boundary before publishing and acting on it after are two requirements: with
# only the second, a count that could not be read exited with the signoff already
# posted, and a later session's `pr-signoff.sh` accepted that record without
# anyone having established whether a boundary was due.
world; printf '2\n' > "$W/pr-round-count.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'nothing recorded' <<<"${got#*|}"; } \
    && pass "an unreadable round count is a stop, not a pause and not a pass" \
    || die "an unreadable count gave '${got}'"
nothing_posted "…with no signoff a later session could act on"
before 'pr-round-count' 'gh pr comment' \
    || pass "…the boundary having been established before anything was published"

# ── THE CALLER'S ACCOUNT IS REQUIRED ───────────────────────────────────────
world; got="$(run record 7)"
{ [ "${got%%|*}" = 1 ] && grep -qF 'a body file is required' <<<"${got#*|}"; } \
    && pass "the phase body is required" \
    || die "a missing body argument gave '${got}'"
world; got="$(run record 7 "$TMP/nope.md")"
[ "${got%%|*}" = 1 ] \
    && pass "…and a body file that is not there is a stop" \
    || die "a missing body file gave '${got}'"
world; : > "$TMP/empty.md"; got="$(run record 7 "$TMP/empty.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'the phase body is empty' <<<"${got#*|}"; } \
    && pass "…and an empty one is too" \
    || die "an empty body gave '${got}'"
grep -q 'gh pr view' "$TMP/calls" \
    && die "it read the head before reading its own body" \
    || pass "…refused before any of the proving is done"

# A POST THAT FAILED RECORDED NOTHING, and the message has to say so: the signoff
# is the thing the next session reads, so "the phase advanced" and "the comment
# failed" must not look alike.
world; printf '1\n' > "$W/comment.rc"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'the signoff is not recorded' <<<"${got#*|}"; } \
    && pass "a failed post stops the phase and says the signoff is not recorded" \
    || die "a failed post gave '${got}'"

# ── PROSE MUST NOT BECOME A RECORD ────────────────────────────────────────
# The body quotes findings, PR descriptions and reviewer comments, and this
# comment is posted under an identity `pr-signoff.sh` and `pr-round-count.sh`
# trust. A line reproducing one of their markers CREATES the record it describes:
# a quoted finding about an acknowledgement becomes the acknowledgement, and the
# boundary it answers never fires again.
for _mk in '**Review-Pause-Acknowledged:** `chatgpt-codex-connector[bot]` `10`' \
           '**Review-Signoff:** `copilot-pull-request-reviewer[bot]` `deadbeef`' \
           '**Review-Signoff-Revoked:** `chatgpt-codex-connector[bot]`'; do
    world; printf 'the finding said it should read:\n%s\nand that is why\n' "$_mk" > "$TMP/body.md"
    got="$(run record 7 "$TMP/body.md")"
    { [ "${got%%|*}" = 1 ] && grep -qF 'reads as a record' <<<"${got#*|}"; } \
        && pass "a body line that is a control marker is refused: ${_mk%% *}" \
        || die "a body carrying ${_mk%% *} gave '${got}'"
    nothing_posted "…and nothing was published under the operator's identity"
done
# A QUOTED `@codex review` REQUESTS A PASS. A comment CONTAINING it is the
# trigger, and this summary is posted standalone with the loop stopping right
# after — so the quoted mention starts a Codex pass that answers nobody.
world; printf 'the finding said to post `@codex review` afterwards\n' > "$TMP/body.md"
got="$(run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF "contains '@codex review'" <<<"${got#*|}"; } \
    && pass "a body quoting the Codex trigger is refused" \
    || die "a body quoting @codex review gave '${got}'"
nothing_posted "…and nothing was posted to request that pass"
world; printf 'and then @CODEX REVIEW is posted\n' > "$TMP/body.md"
got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 1 ] \
    && pass "…in any case, since the trigger is not case-sensitive" \
    || die "an upper-case trigger gave '${got}'"

# `**Reviewed commit:**` IS NOT REFUSED: `pr-round-count.sh` reads it only from a
# reviewer bot's own comment, so a body posted here cannot create one.
world; printf 'the footer reads:\n**Reviewed commit:** `0123456789`\n' > "$TMP/body.md"
got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 0 ] \
    && pass "…while a marker no caller-posted body can create is left alone" \
    || die "the reviewed-commit footer was refused: '${got}'"

# INDENTED OR INLINE IS STILL PROSE, because the readers anchor these markers to
# the start of a line. Refusing those too would stop an author saying what a
# finding was about. A FENCE IS NOT one of those ways: the readers scan the raw
# body, where a line inside a fence still starts at column 0.
world; printf 'the finding said:\n\n    **Review-Signoff:** `x` `y`\n\nwhich is why\n' > "$TMP/body.md"
got="$(run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 0 ] \
    && pass "…while an indented one is prose and passes, as the readers see it" \
    || die "an indented marker was refused: '${got}'"

# ── open: THE PHASE OPENS ON THE HEAD THAT WAS SIGNED OFF ──────────────────
world; got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 0 ] && grep -qF "PR_COPILOT_PHASE_OPENED pr=7 head=$HEAD40 prior-review=42" <<<"${got#*|}"; } \
    && pass "the operator's answer opens the Copilot phase" \
    || die "open gave '${got}'"
grep -q -- '--add-reviewer @copilot' "$TMP/calls" \
    && pass "…by --add-reviewer, which is the only thing that requests Copilot" \
    || die "Copilot was not requested: $(cat "$TMP/calls")"
_cap posted
grep -qF "**Review-Signoff-Revoked:** \`$COPILOTBOT\`" <<<"$_CAP" \
    && pass "…and any earlier Copilot signoff is revoked" \
    || die "no revocation was posted: $(posted)"
before 'gh pr comment' 'gh pr edit' \
    && pass "…before the request, so no window exists where a stale signoff describes a reopened phase" \
    || die "the request preceded the revocation: $(cat "$TMP/calls")"

# THE HEAD IS RE-PROVEN, because the operator's answer can arrive in a later
# session. Opening the phase against a moved head spends it on one commit and the
# merge gate on another, and only the gate finds out.
world; printf '%s\n' "$OTHER40" > "$W/head.out"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && grep -qF "the head is $OTHER40, not the $HEAD40" <<<"${got#*|}"; } \
    && pass "a head that moved since the signoff stops the phase from opening" \
    || die "a moved head gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested against a head Codex never signed off" \
    || pass "…with Copilot not requested"
[ -s "$W/posted" ] \
    && die "…but the previous signoff was revoked anyway" \
    || pass "…and nothing revoked, since the phase did not open"

# A RECORDED SIGNOFF IS HISTORY, NOT CURRENT STATE. A review dismissed while the
# head stood still leaves the head-equality check passing, so without re-reading
# the verdict the whole Copilot phase is spent before the merge gate discovers the
# signoff no longer describes a clean review.
world; printf '1\n' > "$W/verdict.rc"; got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && grep -qF "Codex is no longer clean on $HEAD40" <<<"${got#*|}"; } \
    && pass "a Codex review dismissed on an unchanged head stops the phase from opening" \
    || die "a same-head dismissal gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested on a signoff that no longer holds" \
    || pass "…with Copilot not requested"
[ -s "$W/posted" ] \
    && die "…but the previous Copilot signoff was revoked anyway" \
    || pass "…and nothing revoked, since the phase did not open"
grep -qF "pr-review-state.sh verdict 7 $CODEXBOT $HEAD40" "$TMP/calls" \
    && pass "…the verdict being re-read against the recorded sha, not the current head" \
    || die "open did not re-validate the verdict: $(cat "$TMP/calls")"

world; printf '1\n' > "$W/head.rc"; got="$(run open 7 "$HEAD40")"
[ "${got%%|*}" = 1 ] \
    && pass "an unreadable head stops the phase from opening" \
    || die "an unreadable head gave '${got}'"

# THE BASELINE IS READ BEFORE THE REQUEST, and a failed read is fatal: without it
# the watch cannot tell the new pass from the old one on an unchanged head.
world; printf '1\n' > "$W/review-id.rc"; got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'do not request a review blind' <<<"${got#*|}"; } \
    && pass "an unreadable review id stops the phase from opening" \
    || die "an unreadable review id gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested with no baseline to wait past" \
    || pass "…with Copilot not requested"

# AN EMPTY BASELINE IS AN ANSWER: a head with no Copilot review yet has no id, and
# `pr-watch.sh` takes that as "wait on any terminal review".
world; : > "$W/review-id.out"; got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 0 ] && grep -q 'PR_COPILOT_PHASE_OPENED .* prior-review=$' <<<"${got#*|}"; } \
    && pass "a head with no Copilot review yet opens, reporting an empty baseline" \
    || die "an empty baseline gave '${got}'"

# A DISMISSAL OR A REVOCATION DURING THE PROBES. Neither moves the head, so the
# head check alone passes — and the phase is proved twice for exactly this: once
# up front, once immediately before the mutations.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s sha=none\n' "$CODEXBOT" > "$W/signoff.2.out"
printf '1\n' > "$W/signoff.2.rc"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'no current Codex signoff' <<<"${got#*|}"; } \
    && pass "a Codex signoff revoked while the phase was being proved stops it" \
    || die "a mid-probe revocation gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested underneath a phase reopened mid-probe" \
    || pass "…with Copilot not requested"

world; printf '1\n' > "$W/verdict.2.rc"
printf 'PR_REVIEW_STATE verdict=none reason=dismissed\n' > "$W/verdict.2.out"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'no longer clean' <<<"${got#*|}"; } \
    && pass "…and so does a verdict dismissed while it was being proved" \
    || die "a mid-probe dismissal gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested on a verdict withdrawn mid-probe" \
    || pass "…with Copilot not requested"

# THE BASELINE IS THE LAST THING READ BEFORE THE REQUEST. A Copilot pass already
# in flight on this unchanged head can finish during the probes or the revocation,
# and a baseline captured earlier would let `--after-review` accept that
# pre-request review as the answer to a request made after it.
world; printf '7\n' > "$W/review-id.out"; printf '99\n' > "$W/review-id.after.out"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 0 ] && grep -q 'prior-review=99' <<<"${got#*|}"; } \
    && pass "the baseline is read after the revocation, so a pass landing meanwhile is waited past" \
    || die "the baseline was captured before the revocation: '${got}'"
before 'gh pr comment' 'pr-review-state.sh review-id' \
    && pass "…and the call order says so" \
    || die "the baseline was read before the revocation: $(cat "$TMP/calls")"

# AND THE STATE CHANGING DURING THE REVOCATION ITSELF. The revocation is a
# mutation and two calls used to follow it, so a check placed before it is not
# "immediately before the request": the phase can be reopened in the window the
# request lands in, and Copilot would be asked underneath it.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s sha=none\n' "$CODEXBOT" > "$W/signoff.3.out"
printf '1\n' > "$W/signoff.3.rc"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'no current Codex signoff' <<<"${got#*|}"; } \
    && pass "a phase reopened during the revocation stops the request" \
    || die "a revocation-window reopen gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested after the phase was reopened mid-revocation" \
    || pass "…with Copilot not requested"

# ── `open` HANDS THE BASELINE BACK IN A FILE ───────────────────────────────
#
# The value used to reach the driver only through the `PR_COPILOT_PHASE_OPENED`
# record, which meant the driving shell captured this stage's output and cut the
# field out of it. It writes the file now, and these cases are about the file
# rather than the record. #243.
world; run open 7 "$HEAD40" "$TMP/prior.txt" >/dev/null
[ "$(cat "$TMP/prior.txt")" = 42 ] \
    && pass "open writes the captured baseline into the file the caller named" \
    || die "open wrote '$(cat "$TMP/prior.txt")' as the baseline, not the id it captured"
# AND WRITES IT BEFORE THE REQUEST. After `--add-reviewer` there is nothing left to
# refuse with: the pass is in flight, and a caller reading a truncated id would arm
# the watch against a review that is not the one it is waiting for.
before 'pr-review-state.sh review-id' 'gh pr edit' \
    && pass "…and captures it before Copilot is requested" \
    || die "the baseline is captured after the request: $(cat "$TMP/calls")"

# AN EMPTY BASELINE IS WRITTEN, NOT SKIPPED. No prior Copilot review is the ordinary
# first pass, and `pr-watch.sh` reads empty as "there is nothing to wait past" — so
# the file must exist and be empty rather than be left as it was.
world; : > "$W/review-id.out"; printf 'stale-from-a-previous-round\n' > "$TMP/prior.txt"
run open 7 "$HEAD40" "$TMP/prior.txt" >/dev/null
# ASSERTED ON THE VALUE A READER GETS, not on the file's size. `printf '%s\n' ""`
# leaves one byte, so `-s` is true on a file that every reader sees as empty —
# `$(<…)` strips trailing newlines, which is how `pr-watch.sh` reads it.
{ [ -f "$TMP/prior.txt" ] && [ -z "$(cat "$TMP/prior.txt")" ]; } \
    && pass "…and an empty baseline is written over a stale one, not left behind" \
    || die "a stale baseline survived an empty capture: '$(cat "$TMP/prior.txt")'"

# A REFUSAL AFTER THE BOUNDED CLEARING LEAVES THE FILE EMPTY, and that clearing is the one
# #245 did NOT remove. It is below the bootstrap, `run_limited` bounds it, and it is the
# readiness proof for the exact operation the write performs — standing before the only
# mutation this stage makes, so an unusable path is found before the signoff is revoked
# rather than after.
#
# EMPTY IS THE WEAKER BASELINE AND IT IS PAID FOR KNOWINGLY. `test-pr-watch.sh` measures
# that: the watch holds a verdict back only when the id it reads equals the baseline, and
# skips the comparison entirely when the baseline is empty. So where the value emptied here
# would have EQUALLED the current terminal review, the cost is PREMATURE ACCEPTANCE — the
# watch announces `PR_REVIEW_READY` for a review no new request was made for, where the
# stale id would have held it back as `awaiting_new_review`. Not a waiting cycle.
#
# It is still the trade to take, because removing the clearing costs a phase that reports
# "did not open" after revoking a signoff — which is what two review rounds found — and that
# one is unconditional while this is narrow. `SKILL-RATIONALE.md` carries the argument.
world; printf 'stale-from-a-previous-round\n' > "$TMP/prior.txt"
printf '1\n' > "$W/head.rc"
run open 7 "$HEAD40" "$TMP/prior.txt" >/dev/null
{ [ -f "$TMP/prior.txt" ] && [ -z "$(cat "$TMP/prior.txt")" ]; } \
    && pass "…and a refusal after the bounded clearing leaves no stale baseline" \
    || die "a refused open left '$(cat "$TMP/prior.txt")' in the baseline file"
# AND IT REQUESTED NOTHING, which is what every refusal guarantees — unlike "posts nothing",
# which is false once the revocation has been written. NOT "no watch is armed": the driver
# reaches the wait step after a refusal whenever `exit` returns, which is what the open-window
# case in `test-pr-skill-contract.sh` proves. What is true here is only that Copilot was never
# asked, so nothing new is coming for that watch to find.
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested by a refused open" \
    || pass "…with Copilot not requested, so nothing new is coming for the watch to find"

# A FIFO AT THAT PATH DOES NOT HANG THE PHASE. Opening a path for WRITING blocks waiting
# for a reader, and what meets this FIFO is the BOUNDED CLEARING, before the revocation —
# the top-of-file arm that used to run first is gone, and it would have skipped a FIFO
# anyway, testing `-f`. So this case exercises the clearing and the refusal it produces,
# which is why it can assert that nothing was posted.
#
# REACHING THE WRITE WITH A FIFO NEEDS A REPLACEMENT RACE, not a FIFO standing at the path,
# and that is the separate case below. A type check before an open is not the answer to
# either: the open is what blocks, and a check it precedes can be raced by whoever put the
# FIFO there. Every open here runs under the runtime watchdog. Bounded by the harness as
# well, so a regression hangs the case rather than the suite.
if command -v mkfifo >/dev/null 2>&1; then
    world; rm -f "$TMP/fifo.txt"
    mkfifo "$TMP/fifo.txt" 2>/dev/null && {
        got="$(run open 7 "$HEAD40" "$TMP/fifo.txt")"
        [ "${got%%|*}" = 1 ] \
            && pass "a FIFO baseline path stops the phase instead of hanging it" \
            || die "a FIFO baseline path gave '${got}'"
        grep -q -- '--add-reviewer' "$TMP/calls" \
            && die "Copilot was requested despite the blocked baseline write" \
            || pass "…with Copilot not requested"
        # AND THE SIGNOFF WAS NOT REVOKED, which is the half that made removing the
        # bounded clearing a regression rather than a subtraction. That clearing is
        # also the READINESS proof on this path, and it stands BEFORE the revocation:
        # without one, a FIFO here is not discovered until the write far below, by
        # which time `gh pr comment` has already revoked the previous Copilot signoff
        # — so the stage reports that the phase did not open while having mutated the
        # PR. Asserting only `--add-reviewer` could not see that: the request comes
        # after the write either way.
        grep -q 'gh pr comment' "$TMP/calls" \
            && die "the previous Copilot signoff was revoked before the unusable baseline path was found" \
            || pass "…and with the previous signoff not revoked, so the PR is untouched"
    }
    rm -f "$TMP/fifo.txt"
else
    pass "no mkfifo on this platform, so the FIFO state is skipped by name"
fi

# AND THE READ-BACK IS BOUNDED TOO, which is a SEPARATE window from the write. The
# write finishing does not make the next open safe: the path is named in argv, and a
# same-UID process can put a FIFO there between the two. Staged by substituting the
# path after the write, through a `mkfifo` shim on PATH that runs when the helper's
# own bounded writer exits — the closest a self-contained case gets to that window
# without a second process. Both opens are on the same side of the revocation, so a
# hang at either leaves the phase half advanced.
if command -v mkfifo >/dev/null 2>&1; then
    world; rm -rf "$TMP/rbdir"; mkdir -p "$TMP/rbdir"
    _rb_path="$TMP/rbdir/prior.txt"
    # A DIRECTORY WHERE THE READ EXPECTS A FILE is the substitution this can stage
    # deterministically: the write creates the file, and the read then meets something
    # it cannot read. What is asserted is that the stage REFUSES rather than continuing.
    got="$(run open 7 "$HEAD40" "$TMP/rbdir")"
    [ "${got%%|*}" = 1 ] \
        && pass "a baseline path that cannot be written or read back stops the phase" \
        || die "a directory baseline path gave '${got}'"
    grep -q -- '--add-reviewer' "$TMP/calls" \
        && die "Copilot was requested despite the unusable baseline path" \
        || pass "…with Copilot not requested"
    rm -rf "$TMP/rbdir"
else
    pass "no mkfifo on this platform, so the read-back substitution is skipped by name"
fi

# A WRITABLE NON-REGULAR PATH IS REFUSED BEFORE COPILOT IS ASKED. `/dev/null` takes
# both writes and reads back EMPTY — which is the legitimate "no earlier Copilot
# review" — so the equality check passed and the phase opened against a path no watch
# can use. `pr-watch.sh` rejects the same path, but only after the revocation and the
# request have gone out. The `-f` question is asked on the BOUND DESCRIPTOR here, so
# it is about the file that was actually read.
if [ -c /dev/null ]; then
    world; : > "$W/review-id.out"
    got="$(run open 7 "$HEAD40" /dev/null)"
    [ "${got%%|*}" = 1 ] \
        && pass "a writable non-regular baseline path stops the phase before Copilot is asked" \
        || die "a /dev/null baseline path gave '${got}'"
    grep -q -- '--add-reviewer' "$TMP/calls" \
        && die "Copilot was requested with a baseline path no watch can read" \
        || pass "…with Copilot not requested"
else
    pass "no /dev/null on this platform, so the device-path state is skipped by name"
fi

# AND A READ THAT FAILS IS NOT AN EMPTY BASELINE. `printf "%s" "$(<…)"` exits 0
# whatever the substitution did, so a path the read-back cannot open came back as
# SUCCESS with empty output — and where there is legitimately no earlier Copilot
# review the baseline IS empty, so the comparison passed and the phase opened against
# a file nothing can read. The watch then refuses, after the revocation and the request
# have gone out.
#
# STAGED WITH A WRITE-ONLY FILE rather than by racing the window. `chmod 222` is the
# same state a mid-window removal produces for the reader — both writes succeed and
# the read cannot open — and it happens on every run instead of when the scheduler
# allows. A timing case here passed against the unfixed helper, because the helper is
# faster than any sleep the fixture can place.
if [ "$(id -u)" != 0 ]; then
    world; : > "$W/review-id.out"
    _rbw="$TMP/rbwin"; rm -rf "$_rbw"; mkdir -p "$_rbw"
    printf 'seed\n' > "$_rbw/prior.txt"; chmod 222 "$_rbw/prior.txt"
    got="$(run open 7 "$HEAD40" "$_rbw/prior.txt")"
    chmod 600 "$_rbw/prior.txt" 2>/dev/null
    [ "${got%%|*}" = 1 ] \
        && pass "…a baseline the read-back cannot open stops the phase, empty or not" \
        || die "an unreadable baseline read-back gave '${got}'"
    grep -q -- '--add-reviewer' "$TMP/calls" \
        && die "Copilot was requested on a baseline the read-back could not read" \
        || pass "…with Copilot not requested"
    rm -rf "$_rbw"
else
    pass "running as root, so the unreadable read-back is skipped by name"
fi

# AND A READ THAT RETURNS NOTHING IS NOT AN EMPTY BASELINE. This is the case the
# read-back could not see before #246: `read` reports ordinary EOF and a read that failed
# part-way with the SAME status, so a child that hands its bytes back leaves the caller
# comparing "" against "" and passing. An empty baseline is LEGITIMATE — no earlier
# Copilot review is the ordinary first pass — which is why this one collided and the
# forty-character sha never did.
#
# STAGED BY EMPTYING THE FILE BETWEEN THE WRITE AND THE READ, which is the state a failed
# read produces for the comparison: the bytes that come back are not the bytes that went
# in. The hook is `timeout` — `run_limited` is a FUNCTION and cannot be shadowed on PATH,
# but it invokes `timeout`, which is an ordinary lookup, and that call is what stands
# between the helper's bounded write and its bounded read.
# NO ROOT GUARD. The neighbouring cases carry one because they revoke permissions and root
# ignores that; this one only truncates a file the fixture itself made, so skipping it under
# UID 0 recorded a pass for a scenario that had not run — and a self-check as root could
# have reverted the child-side comparison with the suite green.
if command -v timeout >/dev/null 2>&1; then
    _rl_real="$(command -v timeout)"
    world; : > "$W/review-id.out"          # an EMPTY baseline: the collision case
    _rbz="$TMP/rbzero"; rm -rf "$_rbz"; mkdir -p "$_rbz"
    cat > "$TMP/bin/timeout" <<RLZ
#!/usr/bin/env bash
"$_rl_real" "\$@"; _rc=\$?
# After the WRITE — the invocation carrying a printf — leave the target empty, so the
# read-back that follows sees a file that is not what was written.
case "\$*" in *printf*) : > "\$RB_ZERO_TARGET" 2>/dev/null ;; esac
exit "\$_rc"
RLZ
    chmod +x "$TMP/bin/timeout"
    got="$(RB_ZERO_TARGET="$_rbz/prior.txt" run open 7 "$HEAD40" "$_rbz/prior.txt")"
    rm -f "$TMP/bin/timeout"
    [ "${got%%|*}" = 1 ] \
        && pass "a baseline that is not what was written stops the phase, even when empty" \
        || die "an emptied baseline gave '${got}'"
    grep -q -- '--add-reviewer' "$TMP/calls" \
        && die "Copilot was requested on a baseline that did not survive the write" \
        || pass "…with Copilot not requested"
    rm -rf "$_rbz"
else
    pass "no timeout on this platform, so the emptied-baseline state is skipped by name"
fi

# AND AN `open` THAT CANNOT BOOTSTRAP LEAVES THE FILE ALONE TOO. This is the refusal only
# the pre-bootstrap clearing could ever have covered — a library emptied in a copy of the
# tree, which `rb_load` refuses before any argument is looked at — so it is the case that
# would go red if the clearing came back.
#
# The reader after this refusal IS real, unlike `record`'s: with the driver's `exit` shadowed
# to return, execution falls past the fence into the wait step. What that reader gets is the
# previous round's id rather than an empty file, and per `test-pr-watch.sh` that is the safer
# of the two — an empty baseline suppresses nothing, while a stale one at least suppresses
# the review it names.
world; printf '%s\n' '99' > "$TMP/prior.txt"
rm -rf "$TMP/brokeno"; cp -R "$DIR" "$TMP/brokeno" || die "could not copy the scripts for the open bootstrap case"
: > "$TMP/brokeno/recordlib.sh"
_bo_rc=0
_bo_out="$(cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    "$TMP/brokeno/pr-copilot-phase.sh" open 7 "$HEAD40" "$TMP/prior.txt" 2>&1)" || _bo_rc=$?
{ [ "$_bo_rc" != 0 ] && [ "$(cat "$TMP/prior.txt" 2>/dev/null)" = 99 ]; } \
    && pass "an open that cannot bootstrap leaves the caller's baseline file untouched" \
    || die "an open bootstrap refusal altered the baseline file to '$(cat "$TMP/prior.txt" 2>/dev/null)' (rc=$_bo_rc out='$_bo_out')"
rm -rf "$TMP/brokeno"

# AND THE FILE IS REQUIRED. A caller that omits it would have the phase opened —
# Copilot requested, the revocation posted — with no baseline anywhere, and the
# watch would take the previous terminal review as this round's answer.
world; got="$(run open 7 "$HEAD40" "")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'a baseline file is required' <<<"${got#*|}"; } \
    && pass "…and an omitted baseline file stops the phase before anything is posted" \
    || die "open without a baseline file gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested despite the missing baseline file" \
    || pass "…with Copilot not requested"

# THE THREE CONSTRAINTS TOGETHER, in the order they have to hold: the phase is
# proved after the revocation, and the baseline is still the LAST thing read
# before the request. Neither can be satisfied by moving the other.
world; run open 7 "$HEAD40" >/dev/null
{ before 'gh pr comment' 'pr-review-state.sh review-id' \
    && before 'pr-review-state.sh review-id' 'gh pr edit'; } \
    && pass "the baseline is read after the revocation and last before the request" \
    || die "the baseline is not last: $(cat "$TMP/calls")"
_rev="$(grep -n 'gh pr comment' "$TMP/calls" | head -1 | cut -d: -f1)"
_base="$(grep -n 'pr-review-state.sh review-id' "$TMP/calls" | head -1 | cut -d: -f1)"
_proof="$(awk -v a="$_rev" -v b="$_base" 'NR>a && NR<b && /pr-signoff.sh/ {print NR; exit}' "$TMP/calls")"
[ -n "$_proof" ] \
    && pass "…with the phase proved again between the two" \
    || die "no phase proof between the revocation and the baseline: $(cat "$TMP/calls")"

# A PUSH DURING THE PROBES. The equality check passed, and the verdict is pinned
# to the recorded sha so it stays clean — while the revocation and the request
# would land on the moved PR, and `--add-reviewer` re-requests, so Copilot spends
# the phase on a head Codex never signed off.
world; printf '%s\n' "$OTHER40" > "$W/move-head-on-probe"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && grep -qF "the head moved to $OTHER40" <<<"${got#*|}"; } \
    && pass "a push landing while the phase is being proved stops it from opening" \
    || die "a head moving mid-probe gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested against a head that moved during the probes" \
    || pass "…with Copilot not requested"
[ -s "$W/posted" ] \
    && die "…but the previous Copilot signoff was revoked against the moved head" \
    || pass "…and nothing revoked"

# A REVOKED CODEX SIGNOFF MEANS THE PHASE WAS REOPENED. Reopening the Codex phase
# over an unchanged head posts a revocation and requests a new pass, and GitHub
# keeps serving the OLD clean verdict until that pass reports — so the verdict
# check passes and only the recorded signoff says what happened.
world; printf '1\n' > "$W/signoff.rc"; printf 'PR_SIGNOFF pr=7 reviewer=%s sha=none\n' "$CODEXBOT" > "$W/signoff.out"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'no current Codex signoff' <<<"${got#*|}"; } \
    && pass "a revoked Codex signoff stops the phase from opening" \
    || die "a revoked signoff gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested underneath a reopened Codex phase" \
    || pass "…with Copilot not requested"
[ -s "$W/posted" ] \
    && die "…but Copilot's signoff was revoked anyway" \
    || pass "…and nothing revoked"

# …AND A SIGNOFF FOR A DIFFERENT HEAD IS NOT THIS ONE.
world; printf 'PR_SIGNOFF pr=7 reviewer=%s sha=%s\n' "$CODEXBOT" "$OTHER40" > "$W/signoff.out"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'not for' <<<"${got#*|}"; } \
    && pass "a recorded signoff naming another head stops the phase from opening" \
    || die "a mismatched signoff gave '${got}'"

# THE BOUNDARY IS ENFORCED AGAIN WHEN OPENING. `record` publishes the signoff
# before it pauses, so a later session can read that signoff back and arrive here
# with the boundary still unacknowledged — the pause skipped by the very resume
# path the published signoff exists to enable.
world; printf '3\n' > "$W/pr-round-count.rc"
got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 3 ] && grep -qF 'not acknowledged' <<<"${got#*|}"; } \
    && pass "an unacknowledged round boundary pauses the phase from opening" \
    || die "an unacknowledged boundary gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested past an unacknowledged boundary" \
    || pass "…with Copilot not requested"
[ -s "$W/posted" ] \
    && die "…but Copilot's signoff was revoked anyway" \
    || pass "…and nothing revoked"
world; printf '2\n' > "$W/pr-round-count.rc"
got="$(run open 7 "$HEAD40")"
[ "${got%%|*}" = 1 ] \
    && pass "…and an unreadable count there is a stop, not a pass" \
    || die "an unreadable count on open gave '${got}'"

world; printf '1\n' > "$W/comment.rc"; got="$(run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'could not revoke' <<<"${got#*|}"; } \
    && pass "a failed revocation stops the phase from opening" \
    || die "a failed revocation gave '${got}'"
grep -q -- '--add-reviewer' "$TMP/calls" \
    && die "Copilot was requested while a stale signoff still described the head" \
    || pass "…with Copilot not requested"

world; printf '1\n' > "$W/edit.rc"
printf 'stale-from-a-previous-round\n' > "$TMP/prior.txt"
got="$(run open 7 "$HEAD40" "$TMP/prior.txt")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'not permission to skip the pass' <<<"${got#*|}"; } \
    && pass "a failed request stops, and says so rather than reading as a slow reviewer" \
    || die "a failed --add-reviewer gave '${got}'"
# AND THE FILE HOLDS THE CAPTURED ID — the residue of a refusal PAST the write, because the
# write has already replaced the file. It is compared against `42`, the id the stub captured,
# and not merely tested for being numeric: a regression writing some OTHER number in the
# failure arm passes a shape test, and the driver would then reach the watch with a baseline
# naming a review nobody captured — accepting an old verdict or waiting past the wrong one,
# while this case reported the outcome asserted.
_ar="$(cat "$TMP/prior.txt" 2>/dev/null)"
case "$_ar" in
    42) pass "…and a refusal past the write leaves the captured id, not an empty file" ;;
    stale-from-a-previous-round) die "the baseline write did not happen before the failed request" ;;
    "") die "a refusal past the write left the baseline empty, not the captured id" ;;
    *) die "the baseline file holds '$_ar', which is not the captured id 42" ;;
esac

world; got="$(run open 7)"
{ [ "${got%%|*}" = 1 ] && grep -qF "'open' needs the head" <<<"${got#*|}"; } \
    && pass "open without the signed-off head is refused" \
    || die "open with no sha gave '${got}'"
world; got="$(run open 7 "${HEAD40:0:7}")"
{ [ "${got%%|*}" = 1 ] && grep -qF 'is not a full OID' <<<"${got#*|}"; } \
    && pass "…and an abbreviated one is refused, since the merge gate needs forty" \
    || die "open with a short sha gave '${got}'"

# ── THE STAGE IS NAMED, AND HAS NO DEFAULT ─────────────────────────────────
# The two halves have an operator decision between them: a caller that gets one
# when it meant the other has either skipped that decision or re-asked a question
# already answered.
world; got="$(run)"
{ [ "${got%%|*}" = 1 ] && grep -qF 'a stage is required' <<<"${got#*|}"; } \
    && pass "an absent stage is refused" \
    || die "no stage gave '${got}'"
world; got="$(run 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF "'7' is not a stage" <<<"${got#*|}"; } \
    && pass "a PR number in stage position is refused by name" \
    || die "a stageless call gave '${got}'"
world; got="$(run start 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && grep -qF "'start' is not a stage" <<<"${got#*|}"; } \
    && pass "an unknown stage is refused by name" \
    || die "an unknown stage gave '${got}'"
world; got="$(run record x "$TMP/body.md")"
[ "${got%%|*}" = 1 ] \
    && pass "a PR number that is not a number is refused" \
    || die "a non-numeric PR gave '${got}'"

# ── `close`: the other end of the phase ────────────────────────────────────
#
# This was 93 lines of `SKILL.md`, covered by nothing — see #78. Every case below
# is one the Markdown copy could not have had.

# WHICH QUESTION THE STOP ASKS IS THE POINT OF THE STAGE. Where the two shas are
# the same commit, Codex has already reviewed exactly what is being merged and the
# fault-tolerance pass must NOT be offered: taking it costs a revocation, a round
# and a reopened phase for a verdict that cannot differ (#55).
world; got="$(run close 7 "$HEAD40")"
{ [ "${got%%|*}" = 0 ] && grep -qF "PR_COPILOT_PHASE_CLOSED pr=7 reviewer=$COPILOTBOT copilot-sha=$HEAD40 codex-sha=$HEAD40" <<<"${got#*|}"; } \
    && pass "a clean Copilot verdict closes the phase and names both shas" \
    || die "close on a matching head gave '${got}'"
grep -qF 'stop and leave the PR open' <<<"${got#*|}" \
    && pass "…and the stop offers merge or stop" \
    || die "the matching-head stop did not offer to leave it open: ${got#*|}"
# THE ABSENCE AS WELL AS THE PRESENCE. "Offers merge" is true of both stops, so
# only asserting what must NOT be there tells them apart.
grep -qF 'another Codex pass' <<<"${got#*|}" \
    && die "a fault-tolerance pass was offered over a head Codex already reviewed: ${got#*|}" \
    || pass "…and offers no fault-tolerance pass over an unchanged head"
# …AND THE MENU IS A WHITELIST, not one forbidden phrase. Carried over from the
# contract test, which asserted this while the block lived in `SKILL.md`. The
# first version of it rejected the wording `another Codex pass`, which rephrasing
# option (b) to `run the fault-tolerance pass first` walks straight past — the
# pass is reoffered over commits that do not exist and the check stays green.
# Every option line is matched against the exact allowed set, so a reworded (b)
# and an added (c) both fail.
_ft_opts="$(grep '^    ([a-z]) ' <<<"${got#*|}")"
[ "$_ft_opts" = "    (a) merge — run pr-merge-gate.sh
    (b) stop and leave the PR open" ] \
    && pass "…and the unchanged-head menu is merge or stop, and nothing else" \
    || die "the unchanged-head options are not merge-or-stop (got: $_ft_opts)"

# THE MARKER IS THE RECORD, in the shape `pr-signoff.sh` scans for: the login and
# the sha in backticks on a line of their own. A stage that posted a paragraph
# saying the same thing in prose would satisfy every assertion above and leave
# nothing a later session can read back.
_cap posted
grep -qF "**Review-Signoff:** \`$COPILOTBOT\` \`$HEAD40\`" <<<"$_CAP" \
    && pass "…and the posted body carries the signoff marker for Copilot" \
    || die "no Copilot signoff marker in the posted body: $(posted)"

# WHERE THE PHASE PRODUCED COMMITS the head has moved past the Codex signoff, and
# the pass IS offered — with the revocation that has to precede it.
world; got="$(run close 7 "$OTHER40")"
{ [ "${got%%|*}" = 0 ] && grep -qF "copilot-sha=$HEAD40 codex-sha=$OTHER40" <<<"${got#*|}"; } \
    && pass "a moved head closes the phase naming both commits" \
    || die "close on a moved head gave '${got}'"
grep -qF 'another Codex pass' <<<"${got#*|}" \
    && pass "…and the stop offers the fault-tolerance pass" \
    || die "no fault-tolerance option after a phase that moved the head: ${got#*|}"
grep -qF 'Review-Signoff-Revoked' <<<"${got#*|}" \
    && pass "…and requires the revocation before it" \
    || die "the fault-tolerance option omitted the revocation: ${got#*|}"
# …AND IT DOES NOT CLAIM BOTH REVIEWERS READ THE HEAD. Once Copilot's fixes have
# moved it, only Copilot signed the current commit; Codex signed an older one and
# the trailer range carrying it forward has not been validated yet. Saying "both
# signed off on <head>" at the merge-versus-another-pass decision is a false
# two-reviews-on-this-commit assurance at precisely the moment it matters. Carried
# over from the contract test with the block.
grep -qi 'has not run yet' <<<"${got#*|}" \
    && pass "…and says the delta check has not run yet" \
    || die "the stop presents an unvalidated delta as though it were checked: ${got#*|}"

# `codex-only` HAS NOTHING TO RECORD, and saying so is not the same as doing it.
# Running the rest in that mode is how a previous round's fix stayed unreachable.
world; got="$(run close 7 "$HEAD40" codex-only)"
{ [ "${got%%|*}" = 0 ] && grep -qF 'mode=codex-only copilot-sha=none' <<<"${got#*|}"; } \
    && pass "codex-only closes with nothing recorded" \
    || die "codex-only gave '${got}'"
grep -q 'pr comment' "$TMP/calls" \
    && die "codex-only posted a Copilot signoff: $(cat "$TMP/calls")" \
    || pass "…and posted no comment"
grep -q 'pr-review-state.sh verdict' "$TMP/calls" \
    && die "codex-only re-checked a Copilot verdict that cannot exist" \
    || pass "…and re-checked no Copilot verdict"

world; got="$(run close 7 "$HEAD40" neither)"
{ [ "${got%%|*}" = 1 ] && grep -qF "'neither' is not a reviewers mode" <<<"${got#*|}"; } \
    && pass "an unknown reviewers mode is refused by name" \
    || die "an unknown mode gave '${got}'"

# ── every failure is a stop, and leaves nothing behind ─────────────────────
#
# In `SKILL.md` each of these exited 0, because that block ran in the driver's own
# shell where a non-zero status would have killed the session. A caller branching
# on the status was told the phase had closed.
close_stops() {   # close_stops <label> ; the world is already broken by the caller
    local got="$1" label="$2"
    { [ "${got%%|*}" = 1 ] && [ -z "$(posted)" ]; } \
        && pass "$label" \
        || die "$label — rc=${got%%|*} posted='$(posted)' out='${got#*|}'"
}
world; close_stops "$(run close 7)" "close without the Codex head is a stop"
world; close_stops "$(run close 7 not-a-sha)" "…and a malformed Codex head is a stop"
world; close_stops "$(run close 7 "${HEAD40:0:7}")" "…and an abbreviated one is too"
world; printf '1\n' > "$W/head.rc"
close_stops "$(run close 7 "$HEAD40")" "…and an unreadable head records nothing"
world; printf 'not-a-sha\n' > "$W/head.out"
close_stops "$(run close 7 "$HEAD40")" "…and a head that is not an OID records nothing"
world; printf '1\n' > "$W/verdict.rc"
close_stops "$(run close 7 "$HEAD40")" "…and a Copilot verdict that is not clean records nothing"

# A FAILED POST IS A STOP TOO, and the record line must not be printed for it: a
# caller that scraped `PR_COPILOT_PHASE_CLOSED` out of the output would carry a
# signoff that is not on the PR.
world; printf '1\n' > "$W/comment.rc"
got="$(run close 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && ! grep -q 'PR_COPILOT_PHASE_CLOSED' <<<"${got#*|}"; } \
    && pass "a failed post is a stop and announces no closed phase" \
    || die "a failed post gave '${got}'"

# THE VERDICT IS RE-CHECKED BEFORE THE POST, not after. Reversed, a head that
# moved between the clean verdict and the lookup is recorded as Copilot-signed and
# the re-check then reports on a commit already written down.
world; run close 7 "$HEAD40" >/dev/null
before 'pr-review-state.sh verdict' 'pr comment' \
    && pass "the verdict is re-checked before the signoff is posted" \
    || die "the post preceded the re-check: $(cat "$TMP/calls")"

# ── AN INHERITED `[` MUST NOT PICK THE STAGE ───────────────────────────────
#
# A function named `[` shadows the builtin and the `command`/`builtin` prefixes
# alike, this script does not re-exec, and it arrives through the environment
# rather than through this fixture's own shell. One that returns success sent a
# `close` invocation down the `open` path — revoking the Copilot signoff and
# requesting another pass instead of closing the phase, on an invocation that
# asked for the opposite.
#
# IMPORTED, NOT DEFINED. `BASH_FUNC_[%%=` is how the environment carries it, and
# it is the route that matters: a definition in this shell would not survive the
# `env` below.
#
# NARROW, AND OTHERWISE WORKING. The first version returned 0 for everything and
# the case failed with `reason=no_origin` — `identitylib.sh` parses the remote
# with `[`, so a `[` that lied about all of it broke the harness before the stage
# dispatch was reached, and a broad forger would have been rejected by a different
# check while the case passed either way. This one lies about exactly the
# comparison the finding names and delegates everything else to the builtin.
_RB_SHADOW_BRACKET='BASH_FUNC_[%%=() { if [[ "$1 $2 $3" == "close = open" ]]; then return 0; fi; builtin [ "$@"; }'
# THE OTHER LIE THIS SCRIPT HAS TO SURVIVE (#81): a `[` that says two shas are
# EQUAL. Every proof that the phase is still open compares the current head with
# the one Codex signed off, so a `[` agreeing to that makes a MOVED head read as
# unmoved — and the phase then opens, or records a signoff, on a commit no
# reviewer saw. That record is what every later gate trusts.
#
# Narrow, again, and for the reason recorded in CLAUDE.md: a `[` that lied about
# everything broke `identitylib.sh`'s remote parse, and the case failed with
# `reason=no_origin` rather than exercising the comparison. This one answers only
# a two-sha equality — forty hex either side — and delegates everything else.
_RB_SHADOW_EQ='BASH_FUNC_[%%=() { if [[ $2 = "=" && $1 =~ ^[0-9a-f]{40}$ && $3 =~ ^[0-9a-f]{40}$ ]]; then return 0; fi; builtin [ "$@"; }'
# AND THE THIRD LIE: a `[` that says a non-zero status is zero. The head being
# unmoved does not mean the VERDICT is unmoved — a review dismissed while the head
# stood still leaves the equality passing — so `open` re-checks Codex's live
# verdict, and that check is `[ "$rc" -eq 0 ]`. A `[` agreeing to it opens the
# phase on a signoff that is history rather than a current verdict.
#
# Narrower still: only `<non-zero> -eq 0` is answered, so every other numeric test
# in the run — and there are several — behaves.
_RB_SHADOW_RC='BASH_FUNC_[%%=() { if [[ $2 = "-eq" && $3 = "0" && $1 != "0" ]]; then return 0; fi; builtin [ "$@"; }'
# THE FOURTH: a `[` that succeeds for `3 -ne 3`. `record` pauses at an operator
# round boundary with `[[ $ROUNDS_RC -ne 3 ]] || { PAUSE; exit 3; }`, so a `[`
# agreeing to that short-circuits the `||` — the pause never happens and the
# stage exits 0. Narrow to that one comparison, since `-ne` appears elsewhere.
_RB_SHADOW_NE='BASH_FUNC_[%%=() { if [[ $2 = "-ne" && $1 = "$3" ]]; then return 0; fi; builtin [ "$@"; }'
# AND THE FIFTH, WHICH LIES ONCE AND THE FIRST ATTEMPT IS WHY. A `[` that answered
# every `-n ""` with success hung the run at the watchdog: "the empty string is
# non-empty" is a loop that never terminates wherever one ends on it. So this lies
# exactly once and delegates afterwards — narrow enough to leave the harness
# working, which is the property every forger here has to have.
_RB_SHADOW_N='BASH_FUNC_[%%=() { if [[ $1 = "-n" && -z $2 && ! -f $W/n.fired ]]; then : > "$W/n.fired"; return 0; fi; builtin [ "$@"; }'
shadow_run() {   # shadow_run <stage> [args…] ; run with an inherited lying `[`
    local out rc=0
    if [ "${1:-}" = record ] && [ "$#" -eq 3 ]; then set -- "$@" "$TMP/sha.txt"; fi
    # AND THE BASELINE FILE FOR `open`, on the same terms and for the same reason: the
    # driver hands `open` one of setup's working files, and a case about that argument
    # itself passes a third and this does nothing. #243.
    if [ "${1:-}" = open ] && [ "$#" -eq 3 ]; then set -- "$@" "$TMP/prior.txt"; fi
    out="$(cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        "${_RB_SHADOW:-$_RB_SHADOW_BRACKET}" \
        "$DIR/pr-copilot-phase.sh" "$@" 2>&1)" || rc=$?
    printf '%s|%s' "$rc" "$out"
}
# ── EVERY FORGER IS PROVED TO LIE, BEFORE ANYTHING RELIES ON IT ────────────
#
# The narrowness checks below run `record`, which never performs a two-sha
# equality through `[` — so they prove an ordinary run works and nothing more. And
# the moved-head cases refuse through the converted `[[` guards whether or not the
# forger was imported at all. Between them, an import that silently stopped
# working would leave every case in this section green while exercising no
# defence: "the attack was repelled" and "the attack never happened" look
# identical from the outside.
#
# So each entry is handed to a child that performs exactly the comparison it lies
# about, with operands the REAL `[` answers false. Seeing the lie is what makes
# the cases downstream mean anything.
forger_lies() {   # forger_lies <label> <BASH_FUNC entry> <operands…>
    local label="$1" entry="$2"; shift 2
    local out=""
    out="$(run_limited 10 env -u SHELLOPTS "$entry" W="$W" \
        bash -c 'if [ "$@" ]; then printf LIED; fi' _ "$@" 2>/dev/null)" || true
    [ "$out" = LIED ] \
        && pass "$label" \
        || die "$label — the forger did not lie, so every case using it proves nothing"
}
world
forger_lies "the stage forger lies about 'close = open'" \
    "$_RB_SHADOW_BRACKET" close = open
forger_lies "…the equality forger lies about two different shas" \
    "$_RB_SHADOW_EQ" "$HEAD40" = "$OTHER40"
forger_lies "…the status forger lies about 1 -eq 0" \
    "$_RB_SHADOW_RC" 1 -eq 0
forger_lies "…the boundary forger lies about 3 -ne 3" \
    "$_RB_SHADOW_NE" 3 -ne 3
world
forger_lies "…and the empty-string forger lies about -n ''" \
    "$_RB_SHADOW_N" -n ""

# THE FIXTURE'S OWN REACH IS ASSERTED FIRST, in both directions. An import that
# silently failed would make the cases below pass while testing nothing; a forger
# that broke the identity parse would fail them for a reason that is not the
# defect. So: the lie lands, and the rest of the run still works.
world; got="$(shadow_run notastage 7)"
grep -qF "'notastage' is not a stage" <<<"${got#*|}" \
    && pass "the inherited [ reaches the script at all" \
    || die "the [ import did not take effect: '${got}'"
world; got="$(shadow_run record 7 "$TMP/body.md")"
grep -qF 'PR_PHASE_RECORDED' <<<"${got#*|}" \
    && pass "…and is narrow enough that the rest of the script still runs" \
    || die "the shadowed [ broke the harness rather than the dispatch: '${got}'"

world; got="$(shadow_run close 7 "$HEAD40")"
grep -qF 'PR_COPILOT_PHASE_CLOSED' <<<"${got#*|}" \
    && pass "an inherited [ does not divert close into another stage" \
    || die "close with a shadowed [ gave '${got}'"
# THE CONSEQUENCE, NOT JUST THE STATUS. `open`'s mutations are a revocation and a
# review request; either landing on a `close` invocation is the failure, and a
# status assertion alone does not see them.
grep -q 'pr edit' "$TMP/calls" \
    && die "close with a shadowed [ requested a Copilot pass: $(cat "$TMP/calls")" \
    || pass "…and requests no Copilot pass"
_cap posted
grep -qF 'Review-Signoff-Revoked' <<<"$_CAP" \
    && die "close with a shadowed [ revoked a signoff: $(posted)" \
    || pass "…and revokes nothing"

# ── A LYING `[` MUST NOT MAKE A MOVED HEAD READ AS UNMOVED (#81) ───────────
#
# The proofs that the phase is still open all compare the current head with the
# one Codex signed off. With a `[` that agrees to any two-sha equality, a head
# that has MOVED reads as unmoved — and the phase opens, or records a signoff, on
# a commit no reviewer saw. Everything downstream trusts that record.
#
# The world here is the one where the head has genuinely moved, so a correct run
# refuses on its own. The forger is what makes the refusal load-bearing: without
# the reserved-word conversion it accepts, and these cases fail.
world; printf '%s\n' "$OTHER40" > "$W/head.out"
_RB_SHADOW="$_RB_SHADOW_EQ" got="$(shadow_run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && [ -z "$(posted)" ]; } \
    && pass "a lying [ cannot open the phase on a head that moved" \
    || die "open with a moved head and an equality-forging [ gave '${got}' posted='$(posted)'"
grep -q 'pr edit' "$TMP/calls" \
    && die "a Copilot pass was requested against a head Codex never signed off" \
    || pass "…and requests no Copilot pass for it"

# …AND A DISMISSED VERDICT ON AN UNMOVED HEAD IS REFUSED TOO. The head is right
# here; what has changed is the verdict, which is the case the second proof exists
# for. With the status forger, `[ "$rc" -eq 0 ]` accepts a dismissal.
world; printf '1\n' > "$W/verdict.rc"
printf 'PR_REVIEW_STATE verdict=none reason=dismissed\n' > "$W/verdict.out"
_RB_SHADOW="$_RB_SHADOW_RC" got="$(shadow_run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && [ -z "$(posted)" ]; } \
    && pass "a lying [ cannot open the phase on a verdict that is no longer clean" \
    || die "open with a dismissed verdict and a status-forging [ gave '${got}' posted='$(posted)'"
world; _RB_SHADOW="$_RB_SHADOW_RC" got="$(shadow_run record 7 "$TMP/body.md")"
grep -qF 'PR_PHASE_RECORDED' <<<"${got#*|}" \
    && pass "…and the status forger is narrow enough that the script still runs" \
    || die "the status forger broke the harness rather than the check: '${got}'"
# …AND `record` HAS ITS OWN COPY OF THAT CHECK, which the case above does not
# reach: it runs a CLEAN world, so it proves the forger is narrow and nothing
# else. `record` re-validates Codex on the exact sha before writing the signoff,
# and that guard is the one with a durable record behind it — a signoff posted for
# a dismissed or findings-bearing verdict is what every later gate trusts.
world; printf '1\n' > "$W/verdict.rc"
printf 'PR_REVIEW_STATE verdict=findings findings=2\n' > "$W/verdict.out"
_RB_SHADOW="$_RB_SHADOW_RC" got="$(shadow_run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 1 ] && [ -z "$(posted)" ]; } \
    && pass "a lying [ cannot record a Codex signoff for a verdict with findings" \
    || die "record with findings and a status-forging [ gave '${got}' posted='$(posted)'"

# ── AND THE ROUND BOUNDARY STILL FIRES UNDER A LYING `[` ───────────────────
#
# `record` publishes the signoff and then pauses when the round count says a
# boundary is due — `[[ $ROUNDS_RC -ne 3 ]] || { PAUSE; exit 3; }`. A `[` that
# succeeds for `3 -ne 3` short-circuits the `||`, so the pause never happens and
# the stage exits 0: the operator check-in the count exists to force is silently
# skipped, and a caller branching on the status is told to carry straight on.
#
# Narrow to that one comparison, since `-ne` appears elsewhere in the run —
# defined with the other forgers above.
world; printf '3\n' > "$W/pr-round-count.rc"
_RB_SHADOW="$_RB_SHADOW_NE" got="$(shadow_run record 7 "$TMP/body.md")"
[ "${got%%|*}" = 3 ] \
    && pass "a lying [ cannot skip the operator round boundary" \
    || die "record at a boundary with an -ne-forging [ gave '${got}'"
grep -qF 'PAUSE' <<<"${got#*|}" \
    && pass "…and the pause is still reported" \
    || die "the boundary pause was not announced: '${got#*|}'"
# THE SIGNOFF IS STILL PUBLISHED BEFORE THE PAUSE, which is the whole point of
# that ordering: a later session reads it back rather than re-proving the phase.
_cap posted
grep -qF 'Review-Signoff' <<<"$_CAP" \
    && pass "…while the signoff was published before pausing" \
    || die "the pause swallowed the signoff: $(posted)"
world; _RB_SHADOW="$_RB_SHADOW_NE" got="$(shadow_run record 7 "$TMP/body.md")"
{ [ "${got%%|*}" = 0 ] && grep -qF 'PR_PHASE_RECORDED' <<<"${got#*|}"; } \
    && pass "…and the -ne forger is narrow enough that the script still runs" \
    || die "the -ne forger broke the harness rather than the boundary: '${got}'"

# ── THE HEAD IS PROVED TWICE, SO BOTH COPIES NEED THE FORGER ───────────────
#
# The equality cases above start with an already-moved head, so they stop at the
# FIRST proof and never reach the re-proof immediately before the mutations. That
# second copy exists for the window where the head moves WHILE the probes run —
# `move-head-on-probe` is the fixture's way of opening it — and reverting it alone
# left the suite green.
#
# Both together is the case: the first read agrees, the head moves mid-probe, and
# a `[` forging the equality would accept the moved head and go on to revoke the
# signoff and request Copilot on a commit Codex never reviewed.
#
# WHAT THIS CASE PINS IS THE PAIR, and that is a fact about the code rather than a
# limit of the fixture. `phase_still_open` runs immediately after the `HEAD_STILL`
# guard and asks the same equality again, so reverting either copy alone changes
# nothing observable — measured, not assumed. Reverting BOTH fails this case and
# the already-moved one above, which is the reachable regression; a fixture that
# claimed to catch one copy in isolation would be asserting something untrue.
world; printf '%s\n' "$OTHER40" > "$W/move-head-on-probe"
_RB_SHADOW="$_RB_SHADOW_EQ" got="$(shadow_run open 7 "$HEAD40")"
{ [ "${got%%|*}" = 1 ] && [ -z "$(posted)" ]; } \
    && pass "a lying [ cannot accept a head that moved while the phase was being proved" \
    || die "open with a mid-probe move and an equality-forging [ gave '${got}' posted='$(posted)'"
grep -q 'pr edit' "$TMP/calls" \
    && die "a Copilot pass was requested after a mid-probe move" \
    || pass "…and requests no Copilot pass after it"

# ── AND AN EMPTY PHASE ACCOUNT IS STILL REFUSED ────────────────────────────
#
# `[[ -n $BODY ]]` is the only `-n` guard here with nothing behind it: an empty
# `$CODEX_SHA` is caught by `sha_reason` and an empty `$BODY_FILE` by the read
# that follows, but an empty BODY posts the durable signoff with the account of
# the phase missing — the one thing the reviewer contract says is read before the
# diff. The existing empty-body case runs with no forger, and every forger above
# delegates `-n`, so this conversion had no coverage.
world; : > "$TMP/empty.md"
_RB_SHADOW="$_RB_SHADOW_N" got="$(shadow_run record 7 "$TMP/empty.md")"
{ [ "${got%%|*}" = 1 ] && [ -z "$(posted)" ]; } \
    && pass "a lying [ cannot record a signoff with no account of the phase" \
    || die "record with an empty body and an -n-forging [ gave '${got}' posted='$(posted)'"
world; _RB_SHADOW="$_RB_SHADOW_N" got="$(shadow_run record 7 "$TMP/body.md")"
grep -qF 'PR_PHASE_RECORDED' <<<"${got#*|}" \
    && pass "…and the -n forger is narrow enough that the script still runs" \
    || die "the -n forger broke the harness rather than the guard: '${got}'"

# THE FIXTURE'S OWN REACH, in both directions again: the equality forger has to
# LAND, and it has to leave the rest of the script working. Without this, both
# cases above would pass against a forger that never took effect.
world; _RB_SHADOW="$_RB_SHADOW_EQ" got="$(shadow_run record 7 "$TMP/body.md")"
grep -qF 'PR_PHASE_RECORDED' <<<"${got#*|}" \
    && pass "the equality forger is narrow enough that the script still runs" \
    || die "the equality forger broke the harness rather than the comparison: '${got}'"
world; printf '%s\n' "$OTHER40" > "$W/head.out"
got="$(run open 7 "$HEAD40")"
[ "${got%%|*}" = 1 ] \
    && pass "…while an unforged run refuses the moved head on its own" \
    || die "the moved-head world does not refuse without the forger: '${got}'"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
