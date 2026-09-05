#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$SCRIPT_DIR/../SKILL.md"
ROOT="$SCRIPT_DIR/../../.."
README="$ROOT/README.md"
. "$SCRIPT_DIR/testlib.sh"

# Step 5a runs this suite with the session pin exported; the identity cases below need it clear.
unset REVIEW_BUS_REMOTE REVIEW_BUS_OWNER REVIEW_BUS_REPO

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

if [ ! -f "$SKILL" ]; then
    echo "ok   - skill not present in this checkout; contract checks skipped"
    echo "RESULT: PASS"
    exit 0
fi

TMP="$(mktemp_d)" || { die "no scratch directory"; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

fences="$(awk '/^```bash$/{f=1; next} /^```$/{f=0} f' "$SKILL")" \
    || { die "SKILL.md could not be read"; echo "RESULT: FAIL"; exit 1; }
[ -n "$fences" ] || { die "SKILL.md has no bash fences"; echo "RESULT: FAIL"; exit 1; }
flat="$(tr '\n' ' ' < "$SKILL" | tr -s ' ')" \
    || { die "SKILL.md could not be flattened"; echo "RESULT: FAIL"; exit 1; }
line_of() { grep -n -F -- "$1" "$SKILL" | head -1 | cut -d: -f1 || true; }
before() {
    local a b
    a="$(line_of "$1")"; b="$(line_of "$2")"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
has()  { grep -q -F -- "$1" "$SKILL"; }
hasf() { grep -q -F -- "$1" <<<"$flat"; }

bad="$(grep -oE '[^ ]*pr-[a-z-]+\.sh"?' <<<"$fences" | grep -vE '^"\$RB_SCRIPTS"?/pr-[a-z-]+\.sh"?$' || true)"
[ -z "$bad" ] \
    && pass "every helper is named through \$RB_SCRIPTS" \
    || die "a helper is named some other way: $bad"
bad="$(grep -F '"$RB_SCRIPTS"/pr-' <<<"$fences" | grep -v 'pr-selfcheck.sh' | grep -v -F '/usr/bin/env bash -p "$RB_SCRIPTS"/pr-' || true)"
[ -z "$bad" ] \
    && pass "…and every helper but the self-check is started as /usr/bin/env bash -p" \
    || die "a helper is started unprivileged: $bad"
grep -qxF '"$RB_SCRIPTS"/pr-selfcheck.sh' <<<"$fences" \
    && pass "…and the self-check is run directly, since it re-execs itself" \
    || die "the self-check is not run as \"\$RB_SCRIPTS\"/pr-selfcheck.sh"
for h in setup request-review watch findings close-round round-count copilot-phase phase-state signoff merge-gate selfcheck; do
    grep -q "pr-$h.sh" <<<"$fences" \
        && pass "…pr-$h.sh is invoked" \
        || die "pr-$h.sh is never invoked by the document"
done
grep -qF '. "$RB_SCRIPTS/identitylib.sh"' <<<"$fences" && grep -qF '&& rb_identity' <<<"$fences" \
    && pass "the identity is derived by the shipped parser, not a copy" \
    || die "the driver does not prove the origin through identitylib.sh"
[ "$(grep -c 'rb_identity()' "$SKILL")" -eq 0 ] \
    && pass "…and the document carries no parser of its own" \
    || die "SKILL.md defines rb_identity"

# `docs/decisions/2026-09-05-driving-shell-trusted.md` is pinned here.
big="$(awk '/^```bash$/{f=1; n=0; s=NR; next} /^```$/{ if (f && n > 15) print s ": " n; f=0 } f{n++}' "$SKILL")"
[ -z "$big" ] \
    && pass "no fence is longer than the setup block's fifteen lines" \
    || die "a fence has grown past one invocation per step (start: lines): $big"
shape="$(grep -nE 'RbProbe|\[\[ -n "" \]\]|\[\[ -n x \]\]|9<|/dev/fd/9|readonly|:\?|BASH_XTRACEFD|RB_NONCE_SEQ|declare |nameref' <<<"$fences" || true)"
[ -z "$shape" ] \
    && pass "…and no hostile-shell shape is left in a fence" \
    || die "a driving-shell defence is back: $shape"
n="$(grep -c '^```bash$' "$SKILL")"
[ "$n" -le 20 ] \
    && pass "…and the document holds $n fences" \
    || die "the document has grown to $n fences"
i=0
while IFS= read -r ln; do
    case "$ln" in
        '```bash') i=$((i + 1)); : > "$TMP/fence.$i" ;;
        '```') ;;
        *) [ "$i" -gt 0 ] && printf '%s\n' "$ln" >> "$TMP/fence.$i" ;;
    esac
done < <(awk '/^```bash$/{f=1; print; next} /^```$/{ if (f) print; f=0; next } f' "$SKILL")
for f in "$TMP"/fence.*; do
    bash -n "$f" 2>/dev/null \
        || die "fence ${f##*.} does not parse: $(bash -n "$f" 2>&1 | head -1)"
    # One helper per fence, so a status is never another invocation's; setup's two retries are the exception.
    c="$(grep -c 'bash -p "$RB_SCRIPTS"/pr-' "$f" || true)"
    lim=1; [ "${f##*.}" -eq 1 ] && lim=4
    [ "$c" -le "$lim" ] || die "fence ${f##*.} invokes $c helpers; one per step"
done
pass "every fence parses, and none but setup invokes more than one helper"

before 'pr-setup.sh "$RB_SETUP_DIR"' 'pr-request-review.sh N' \
    && pass "setup precedes the request" || die "the request precedes setup"
before 'pr-request-review.sh N' 'pr-watch.sh N' \
    && pass "the request precedes the watch" || die "the watch precedes the request"
before '"$RB_SCRIPTS"/pr-selfcheck.sh' 'pr-close-round.sh gate N' \
    && pass "the self-check precedes the push" || die "the push precedes the self-check"
before '**check the round boundary — step 6.**' '**run `gate`**' \
    && pass "the round boundary is checked before the push, in the numbered procedure" || die "the push precedes the boundary check"
before 'pr-close-round.sh gate N' 'resolveReviewThread' \
    && before 'resolveReviewThread' 'pr-close-round.sh post N' \
    && pass "gate, then the thread replies, then post" || die "the round-closing order is wrong"
before 'pr-copilot-phase.sh record N' 'STOP — the next phase is the operator' \
    && before 'STOP — the next phase is the operator' 'pr-copilot-phase.sh open N' \
    && pass "the Copilot phase opens only after the stop the operator answers" || die "open precedes the Codex stop"
before 'pr-copilot-phase.sh close N' 'MERGING IS THE OPERATOR' \
    && before 'MERGING IS THE OPERATOR' 'pr-merge-gate.sh N' \
    && pass "the merge gate runs only after the stop the operator answers" || die "the gate precedes the Copilot stop"
before 'pr-phase-state.sh N' 'pr-merge-gate.sh N' \
    && pass "a resumed session re-reads the phase before the gate" || die "the resume recipe follows the gate"
hasf 'do not run the merge gate until the operator has answered' \
    && pass "…and the driver is told not to run the gate until answered" || die "the post-close stop is not stated"
hasf 'In `codex-only` there is no second question' && hasf 'Go straight to the merge gate' \
    && pass "…with codex-only exempted by name and sent to the gate" || die "codex-only waits for a menu never printed"

for row in '| `0` |' '| `1` |' '| `2` |' '| `4` |'; do
    has "$row" && pass "the watch status $row is tabled" || die "the watch table lacks $row"
done
has 'fail closed' && has 're-arm the same watch' \
    && pass "…a 2 fails closed and a 1 re-arms" || die "the watch's 1 or 2 is not acted on"
has 'STOP. Do not go to step 4' \
    && pass "…and a 4 is a stop" || die "a replies-only review is not a stop"
hasf '3: the operator decides at a round boundary' \
    && pass "gate's 3 is the boundary" || die "gate's 3 is not named"
hasf '3: the pass left only replies' \
    && pass "post's 3 is the replies-only stop" || die "post's 3 is not named"
hasf '3: recorded, then paused at a round boundary' \
    && pass "record's 3 is a recorded signoff at the boundary" || die "record's 3 is not named"
hasf 'not permission to skip the pass' \
    && pass "open's refusals are not permission to skip Copilot" || die "an open refusal reads as permission"
hasf '0 merged' && hasf '1 blocked' && hasf '3 paused at a round boundary' && hasf '4 queued' \
    && pass "the merge gate's four answers are named" || die "a merge-gate status is unnamed"
hasf '3: **not applicable**' && hasf '2: the check could not run' \
    && pass "the self-check's four answers are named" || die "a self-check status is unnamed"
hasf '2: the read could not be trusted' \
    && pass "an untrusted findings read is a stop" || die "findings' 2 is not a stop"
has 'It does not merge unattended past a failed or unreadable gate' \
    && pass "no failed or unreadable gate is merged past" || die "the fail-closed promise is gone"
has 'It does not run a reviewer' \
    && pass "the loop runs no reviewer of its own" || die "the no-local-reviewer promise is gone"

for m in '**Review-Signoff:**' '**Review-Signoff-Revoked:**' '**Review-Pause-Acknowledged:**'; do
    has "$m" && pass "the marker $m is named as refused" || die "the marker $m is not documented"
done
hasf '`@codex review` anywhere in the body' && has 'Write the mention without the `@`' \
    && pass "a mention in a body is refused, and the author is told how to avoid one" \
    || die "the mention refusal is not documented"
has 'Review-Pause-Acknowledged:** `%s` `%s`' \
    && pass "the acknowledgement names the reviewer and the count" || die "the acknowledgement template is gone"
ack="$(grep -F 'Review-Pause-Acknowledged:** `%s` `%s`' <<<"$fences" || true)"
grep -q 'ABORT: the acknowledgement was not recorded' <<<"$ack" \
    && pass "…and a failed acknowledgement is a stop before any request or retry" || die "a failed acknowledgement has no stop"
has 'as a past-tense disposition' \
    && pass "the summary is a record, not a work order" || die "the disposition rule is gone"
has 'never as a work order' \
    && pass "…and says why" || die "the incident behind the disposition rule is gone"

grep -q '/replies" -f body=' <<<"$fences" && grep -q "/reactions\" -f content='+1'" <<<"$fences" \
    && grep -q 'resolveReviewThread' <<<"$fences" && grep -q 'isResolved' <<<"$fences" \
    && pass "reply, react and resolve are commands, and the resolve is read back" \
    || die "the thread answer is not spelled out"

trailer="$(grep -A1 -F 'Review-Phase: copilot' "$SKILL" || true)"
grep -q 'Co-Authored-By' <<<"$trailer" \
    && pass "the trailer sits in the last paragraph beside Co-Authored-By" \
    || die "the trailer is not shown in a trailer block"

bad="$(grep -F 'pr-watch.sh N' <<<"$fences" | grep -v -F -- '--after-review-file "$PRIOR_FILE" --require-nonce "$RB_NONCE"' || true)"
[ -z "$bad" ] && pass "every watch carries the baseline file and the nonce" || die "a watch runs without its baseline or nonce: $bad"
[ "$(grep -c -F 'RB_NONCE="$(perl -e' <<<"$fences")" -ge 3 ] \
    && pass "…and the nonce is generated afresh before each request" || die "a request reuses a nonce"
odd="$(grep -F -- '--nonce' <<<"$fences" | grep -v -F -- '--nonce "$RB_NONCE"' | grep -v -F -- '--require-nonce "$RB_NONCE"' || true)"
[ -n "$odd" ] \
    && die "a nonce is passed as something other than \$RB_NONCE: $odd" \
    || pass "…and only \$RB_NONCE is ever passed"

grep -qF 'export REVIEW_BUS_REMOTE="$(<"$RB_SETUP_DIR/origin")"' <<<"$fences" \
    && pass "the origin is read as data and exported as the pin" || die "the pin is not read from setup's origin file"
grep -qE '^\[ -n "\$REVIEW_BUS_REMOTE" \] && \[\[ \$REVIEW_BUS_REMOTE != \*\$'"'"'\\n'"'"'\* \]\] && rb_identity' <<<"$fences" \
    && pass "…and validated as one line by the parser before anything uses it" || die "the origin is used unvalidated, or a second line is not refused"
grep -qE '(^|[^a-z])(source|\.) "\$RB_SETUP_DIR' <<<"$fences" \
    && die "a setup handoff is sourced" || pass "…and no handoff file is sourced"
has 'mode=unattended' && has 'mode=attended' \
    && pass "setup's record says which mode the session runs in" || die "the mode is not read off setup's record"
has 'Nothing under `$RB_SETUP_DIR` is ever removed' \
    && pass "…and nothing under the setup directory is removed" || die "the no-removal promise is gone"

# `docs/decisions/2026-08-26-transport-candidate-in-argv.md` bounds a squat at that retry,
# so the setup fence is the one fence executed here, against the real helper.
setup_fence="$(awk '/^```bash$/{f=1; n++; next} /^```$/{f=0} f && n == 1' "$SKILL")" || setup_fence=
if [ "$(id -u)" -eq 0 ]; then
    pass "the setup retry case is skipped as root, whom no directory mode refuses"
elif [ -z "$setup_fence" ]; then
    die "the setup fence could not be lifted"
elif _sr="$(mktemp_d)" && _ro="$(mktemp_d)" && _home="$(mktemp_d)" \
     && git -C "$_sr" init -q && git -C "$_sr" remote add origin 'git@github.com:acme/widget.git' \
     && chmod 500 "$_ro"; then
    _srrc=0
    _srout="$(cd "$_sr" && CLAUDE_PLUGIN_ROOT="$ROOT" TMPDIR="$_ro" HOME="$_home" \
        run_limited 60 bash -c "$setup_fence"$'\n''printf "%s\n" "$RB_SETUP_DIR"' 2>&1)" || _srrc=$?
    _srdir="${_srout##*$'\n'}"
    case "$_srrc|$_srdir" in
        "0|$_home/watch-pr-setup-2."*)
            [ -f "$_srdir/origin" ] \
                && pass "a first parent that refuses costs one retry under HOME, and the session goes on" \
                || die "the retry reported success without a setup directory: '$_srout'" ;;
        *) die "with the first parent refusing, the setup fence exited $_srrc with: '$_srout'" ;;
    esac
    chmod 700 "$_ro"; rm -rf "$_sr" "$_ro" "$_home"
else
    die "could not stage the setup retry case"
fi

if [ -z "$setup_fence" ]; then
    die "the setup fence could not be lifted for the relative-TMPDIR case"
elif _sr3="$(mktemp_d)" && _home3="$(mktemp_d)" \
     && git -C "$_sr3" init -q && git -C "$_sr3" remote add origin 'git@github.com:acme/widget.git'; then
    _rrc=0
    _rout="$(cd "$_sr3" && CLAUDE_PLUGIN_ROOT="$ROOT" TMPDIR=relative/dir HOME="$_home3" \
        run_limited 60 bash -c "$setup_fence"$'\n''printf "%s\n" "$RB_SETUP_DIR"' 2>&1)" || _rrc=$?
    _rdir="${_rout##*$'\n'}"
    case "$_rrc|$_rdir" in
        "0|$_home3/watch-pr-setup."*) pass "a relative TMPDIR sends setup under HOME on the first attempt" ;;
        *) die "with a relative TMPDIR the setup fence exited $_rrc with: '$_rout'" ;;
    esac
    rm -rf "$_sr3" "$_home3"
else
    die "could not stage the relative-TMPDIR case"
fi

if [ -z "$setup_fence" ]; then
    die "the setup fence could not be lifted for the altered-handoff case"
elif _st="$(mktemp_d)" && mkdir -p "$_st/skills/watch-prs/scripts" \
     && cp "$SCRIPT_DIR/identitylib.sh" "$_st/skills/watch-prs/scripts/" \
     && printf '%s\n' '#!/usr/bin/env bash' 'mkdir -p "$1/work" && printf "%s\n" "git@github.com:acme/widget.git" "git@github.com:acme/other.git" > "$1/origin"' \
        > "$_st/skills/watch-prs/scripts/pr-setup.sh" \
     && chmod +x "$_st/skills/watch-prs/scripts/pr-setup.sh" \
     && _sh="$(mktemp_d)" && _sr2="$(mktemp_d)" && git -C "$_sr2" init -q; then
    _mrc=0
    _mout="$(cd "$_sr2" && CLAUDE_PLUGIN_ROOT="$_st" TMPDIR="$_sh" HOME="$_sh" \
        run_limited 60 bash -c "$setup_fence"$'\n''printf "PINNED %s\n" "$REVIEW_BUS_REMOTE"' 2>&1)" || _mrc=$?
    case "$_mrc|$_mout" in
        0*) die "a two-line origin handed over was pinned: '$_mout'" ;;
        *'not a usable identity'*) pass "a two-line origin handed over is refused before anything is pinned" ;;
        *) die "a two-line origin gave rc=$_mrc with: '$_mout'" ;;
    esac
    rm -rf "$_st" "$_sh" "$_sr2"
else
    die "could not stage the altered-handoff case"
fi

if [ -z "$setup_fence" ]; then
    die "the setup fence could not be lifted for the replaced-origin case"
elif _sw="$(mktemp_d)" && mkdir -p "$_sw/skills/watch-prs/scripts" \
     && cp "$SCRIPT_DIR"/*lib.sh "$SCRIPT_DIR/pr-origin.sh" "$_sw/skills/watch-prs/scripts/" \
     && printf '%s\n' '#!/usr/bin/env bash' 'mkdir -p "$1/work" && printf "%s\n" "git@github.com:acme/other.git" > "$1/origin"' \
        > "$_sw/skills/watch-prs/scripts/pr-setup.sh" \
     && chmod +x "$_sw/skills/watch-prs/scripts/pr-setup.sh" \
     && _swh="$(mktemp_d)" && _swr="$(mktemp_d)" && git -C "$_swr" init -q \
     && git -C "$_swr" remote add origin 'git@github.com:acme/widget.git'; then
    _wrc=0
    _wout="$(cd "$_swr" && CLAUDE_PLUGIN_ROOT="$_sw" TMPDIR="$_swh" HOME="$_swh" \
        run_limited 60 bash -c "$setup_fence"$'\n''printf "PINNED %s\n" "$REVIEW_BUS_REMOTE"' 2>&1)" || _wrc=$?
    case "$_wrc|$_wout" in
        0*) die "an origin that is not this checkout's was pinned: '$_wout'" ;;
        *'not this checkout'*) pass "a valid origin that is not this checkout's is refused by the pin" ;;
        *) die "a replaced origin gave rc=$_wrc with: '$_wout'" ;;
    esac
    rm -rf "$_sw" "$_swh" "$_swr"
else
    die "could not stage the replaced-origin case"
fi

hp="$(grep -F 'rb_handoff_is_sha "$2"' <<<"$fences" | grep -v 'CODEX_SHA=' || true)"
if [ -z "$hp" ]; then
    die "the gated head is not proved through rb_handoff_is_sha before the thread replies"
elif ! grep -qF 'rb_handoff_is_sha() { return 127; }' <<<"$hp"; then
    die "the head proof sources writelib.sh with no refusing stub ahead of it"
elif before 'rb_handoff_is_sha' 'resolveReviewThread' && _hd="$(mktemp_d)"; then
    pass "the head proof precedes the thread replies, behind a refusing stub"
    mkdir "$_hd/lib" && : > "$_hd/lib/writelib.sh"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$_hd/good"
    _hrc=0; run_limited 10 bash -c "RB_SCRIPTS=\"$_hd/lib\"; HEAD_FILE=\"$_hd/good\"; $hp" >/dev/null 2>&1 || _hrc=$?
    [ "$_hrc" -ne 0 ] \
        && pass "…an emptied writelib.sh refuses rather than passing a proven head" || die "an emptied library passed the head proof"
    printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' > "$_hd/bad"
    _hrc=0; run_limited 10 bash -c "RB_SCRIPTS=\"$SCRIPT_DIR\"; HEAD_FILE=\"$_hd/bad\"; $hp" >/dev/null 2>&1 || _hrc=$?
    [ "$_hrc" -ne 0 ] \
        && pass "…a head file of forty non-hex bytes is refused" || die "a corrupt head file passed the proof"
    if mkfifo "$_hd/fifo" 2>/dev/null; then
        _hrc=0; run_limited 10 bash -c "RB_SCRIPTS=\"$SCRIPT_DIR\"; HEAD_FILE=\"$_hd/fifo\"; $hp" >/dev/null 2>&1 || _hrc=$?
        { [ "$_hrc" -ne 0 ] && [ "$_hrc" -ne 124 ]; } \
            && pass "…a FIFO at the head path is refused rather than waited on" || die "a FIFO at the head path gave rc=$_hrc (124 = hung)"
    fi
    _hrc=0; run_limited 10 bash -c "RB_SCRIPTS=\"$SCRIPT_DIR\"; HEAD_FILE=\"$_hd/good\"; $hp" >/dev/null 2>&1 || _hrc=$?
    [ "$_hrc" -eq 0 ] \
        && pass "…while a proven head passes" || die "a 40-hex head was refused (rc=$_hrc)"
    sp="$(grep -F 'CODEX_SHA="$(<"$HEAD_FILE")"' <<<"$fences" || true)"
    if [ -z "$sp" ] || ! grep -qF 'rb_handoff_is_sha() { return 127; }' <<<"$sp"; then
        die "the signoff sha is read from the head file without the head proof ahead of it"
    else
        _src=0; _sout="$(run_limited 10 bash -c "RB_SCRIPTS=\"$SCRIPT_DIR\"; HEAD_FILE=\"$_hd/bad\"; $sp; printf '%s' \"\${CODEX_SHA-unset}\"" 2>/dev/null)" || _src=$?
        { [ "$_src" -ne 0 ] && [ "$_sout" != "$(cat "$_hd/bad")" ]; } \
            && pass "…and a head file corrupted after record is refused before the decision stop" \
            || die "a corrupt head file was taken as the signoff sha (rc=$_src, '$_sout')"
        _src=0; _sout="$(run_limited 10 bash -c "RB_SCRIPTS=\"$SCRIPT_DIR\"; HEAD_FILE=\"$_hd/good\"; $sp; printf '%s' \"\$CODEX_SHA\"" 2>/dev/null)" || _src=$?
        { [ "$_src" -eq 0 ] && [ "$_sout" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]; } \
            && pass "…while a proven head is taken as the signoff sha" || die "a proven head was not taken (rc=$_src, '$_sout')"
    fi
    rm -rf "$_hd"
else
    die "the head proof does not precede the thread replies, or the case could not be staged"
fi

has 'WATCH_PR_AUTONOMOUS=1' && pass "the unattended switch is named" || die "WATCH_PR_AUTONOMOUS=1 is not named"
_rc=0; _n="$(grep -c '^\*\*Unattended:\*\*' "$SKILL")" || _rc=$?
{ [ "$_rc" -le 1 ] && [ "$_n" -eq 4 ]; } \
    && pass "…and exactly four stops carry an unattended answer" || die "expected four unattended answers, found '$_n'"
section() { awk -v a="$1" -v b="$2" 'index($0, a) == 1 { c = 1; next } index($0, b) == 1 { c = 0 } c' "$SKILL"; }
at() {
    local s; s="$(section "$1" "$2")" || { die "the $3 could not be read"; return 0; }
    [ "$(grep -c '^\*\*Unattended:\*\*' <<<"$s" || true)" -eq 1 ] \
        && pass "…one at the $3" || die "the $3 carries no unattended answer"
}
at '## 6. ' '## 7. ' 'round check-in'
at '**STOP — the next phase is the operator' '```bash' 'Codex-clean stop, before the Copilot phase is opened'
at '**On the two-reviewer path, STOP.' '### Resuming after a stop' 'Copilot-clean stop'
at '### Then: the gate' '## What this skill' 'merge gate'
s="$(section '## 6. ' '## 7. ')" || s=
grep -q 'PR_ROUND_PAUSE' <<<"$s" && grep -q 'left only replies' <<<"$s" && grep -q 'running it twice records two signoffs' <<<"$s" \
    && pass "…the check-in answer keys on the pause record, leaves gate's replies-only 3 a stop, and does not re-run record" \
    || die "the unattended check-in answer is incomplete"
s="$(section '**STOP — the next phase is the operator' '```bash')" || s=
grep -q 'findings=0' <<<"$s" && grep -q 'session resumed at this' <<<"$s" && grep -q 'a second review costs rounds' <<<"$s" \
    && grep -q 'signoff already stands' <<<"$s" && grep -q 'counter of step 6' <<<"$s" && grep -q 'open nothing' <<<"$s" \
    && pass "…the Codex-clean answer reads the opening verdict, resumes to Copilot, and merges after a fault-tolerance signoff" \
    || die "the unattended Codex-clean answer is incomplete"
grep -q 'pr-round-count' <<<"$s" \
    && die "the Codex-only decision reads the distinct-head count" || pass "…and not the reviewed-head count"
s="$(section '**On the two-reviewer path, STOP.' '### Resuming after a stop')" || s=
grep -q 'fault-tolerance pass' <<<"$s" && grep -q 'auto-review argument' <<<"$s" && grep -q 'no push precedes it' <<<"$s" \
    && pass "…the Copilot-clean answer runs the fault-tolerance pass, requested by mention" \
    || die "the unattended Copilot-clean answer is incomplete"
s="$(grep '^| `4` |' "$SKILL")" || s=
grep -qi 'unattended\|AUTONOMOUS' <<<"$s" && die "the replies-only stop is answered unattended" || pass "…the replies-only stop is not answered unattended"
s="$(section '**On `4`' '## 4.')" || s=; [ -n "$s" ] || die "the status-4 paragraph is empty"
grep -qi 'unattended\|AUTONOMOUS' <<<"$s" && die "the replies-only answer is taken unattended" || pass "…nor is its answer"
s="$(awk 'index($0, "**Prove a fix can fail.**") == 1 { c = 1 } /^$/ { c = 0 } c' "$SKILL")" || s=; [ -n "$s" ] || die "the prove-a-fix paragraph is empty"
grep -qi 'unattended\|AUTONOMOUS' <<<"$s" && die "an untestable limitation is accepted unattended" || pass "…nor the untestable limitation"
hasf 'Copilot is unavailable to the repository is not permission' \
    && pass "…and an unavailable Copilot is not permission to skip the pass" || die "the unavailable-reviewer stop is gone"
has 'answers none of them' \
    && pass "…and no failed gate is answered by the switch" || die "the switch's limit is not stated"

if [ -f "$README" ]; then
    grep -qi 'codex-only' "$README" && grep -qiE 'narrower|not looser' "$README" && grep -qi 'no switch for is skipping a reviewer' "$README" \
        && pass "README documents the Codex-only merge as narrower, and rules out a silent skip" \
        || die "README's account of codex-only drifted"
    grep -q 'two Codex passes' "$README" && grep -q 'automatic review on' "$README" \
        && pass "README says what automatic review costs" || die "README's account of automatic review drifted"
    grep -q '^### Running unattended' "$README" && grep -q 'WATCH_PR_AUTONOMOUS' "$README" \
        && grep -q 'It answers decisions, never readings' "$README" \
        && pass "README documents running unattended and what it leaves alone" || die "README's unattended section drifted"
    grep -q 'Review-Pause-Acknowledged' "$README" \
        && pass "README names the record markers a body may not carry" || die "README no longer names the markers"
    grep -q 'PR_WATCH_PROBE_TIMEOUT' "$README" \
        && pass "README documents the watch's probe bound" || die "README lacks PR_WATCH_PROBE_TIMEOUT"
    grep -q 'Watching without prompts' "$README" \
        && pass "README explains the Monitor permission SKILL.md points at" || die "README's Monitor section is gone"
fi

# ── the accepted merge-mode limitation is recorded on the base ref ────────
# AGENTS.md makes a dated decision record the only thing that can accept a
# limitation; a comment in the diff cannot.
if [ -d "$ROOT/docs/decisions" ]; then
    grep -rql 'REVIEW_MERGE_STRICT' "$ROOT/docs/decisions" >/dev/null 2>&1 \
        && pass "the merge-mode trade-off has a decision record" \
        || die "the --admin default is accepted nowhere a reviewer can weigh it"
    grep -rql 'transport candidate being published in argv is an accepted limit' \
        "$ROOT/docs/decisions" >/dev/null 2>&1 \
        && pass "the argv-publication limit has a decision record" \
        || die "#160 is accepted nowhere a reviewer can weigh it"
    grep -rql 'the reservation being an inference is an accepted limit' \
        "$ROOT/docs/decisions" >/dev/null 2>&1 \
        && pass "the reservation inference has a decision record" \
        || die "#162 is accepted nowhere a reviewer can weigh it"
    # AND THE TWO TRANSPORT RECORDS MUST NOT CONTRADICT EACH OTHER. The #160 one
    # was written while #162 was still unaccepted and said so; left that way, a
    # reviewer following it reaches the opposite verdict from one following the
    # #162 record, and both are base-ref authorities.
    grep -q 'reservation-inference' \
        "$ROOT/docs/decisions/2026-08-26-transport-candidate-in-argv.md" \
        && pass "the argv record points at the later reservation decision" \
        || die "the two decision records disagree about whether #162 is accepted"
    # ── EVERY ACCEPTED RECORD IS NAMED IN BOTH REVIEWER FILES ─────────────
    #
    # Codex reads the repository and can follow a pointer; Copilot reads only
    # `.github/copilot-instructions.md` and follows none, which is why that file
    # restates the policy inline. So an acceptance living in `docs/decisions/`
    # alone is invisible to one of the two required reviewers, and it can re-raise
    # what the operator already accepted. That is the doc-sync rule applied to a
    # waiver.
    #
    # DERIVED FROM THE DIRECTORY, NOT LISTED. A list of two went stale the moment
    # a third record was written — which is how the 2026-08-06 `--admin` waiver
    # sat unreferenced in both files for twenty days. #189.
    #
    # ACCEPTED ONES ONLY. A record whose status is superseded or rejected is
    # history rather than authority, and requiring a reviewer file to name it
    # would be requiring the opposite of what it says.
    # …AND THE `--admin` BOUNDS ARE SPELLED OUT FOR COPILOT, not deferred to the
    # record. Naming the file is enough for Codex, which reads the repository;
    # Copilot is configured from its own instructions and follows no pointers, so
    # a waiver that says "read that record" leaves it unable to notice that a
    # bound the waiver DEPENDS ON has been removed — and it would sign off a
    # newly unsafe `--admin` path. The bypass is waived; its bounds are not.
    # EVERY CONCRETE CONDITION, NOT FOUR BROAD LABELS. A loop over `40-hex`,
    # `match-head-commit`, `REVIEW_MERGE_STRICT` and `review-state probe` stayed
    # green while an edit removed the head re-read entirely, or reduced the
    # review-state probe to a phrase with no states in it, or dropped that strict
    # mode must be `=1` and EXPORTED — each of which leaves Copilot not knowing a
    # bound the waiver depends on, which is the regression this exists to stop.
    #
    # SEMANTIC TOKENS, NOT STYLISTIC ONES: each names a condition rather than a
    # turn of phrase, so rewording the prose around them does not fail the case
    # while removing the condition does.
    #
    # `re-read and compared immediately before merging` WAS ONE OF THESE AND IS
    # NOT ANY MORE, because the gate does not do it: the head is resolved ONCE and
    # the merge is pinned to that OID with `--match-head-commit`, which is what
    # makes the comparison atomic. Asserting a bound the code does not have taught
    # a reviewer to accept the waiver on the strength of a check that is not there.
    # The atomicity token below is the one that carries this.
    for _bd in 'full 40-hex SHA' \
               '7-character prefix' \
               'atomic with the merge' \
               'match-head-commit' \
               'review-state probe' \
               'all-checks gate is addressed by that head' \
               'required-checks gate is' \
               'addressed by it too' \
               'BASE BRANCH requires' \
               'protection cannot be' \
               'blocked' \
               'dismissed review' \
               'body-only' \
               'REVIEW_MERGE_STRICT=1' \
               'exported, not merely assigned' \
               'requires a merge queue' \
               'no merge-queue probe'; do
        grep -qF "$_bd" "$ROOT/.github/copilot-instructions.md" \
            && pass "copilot-instructions.md states the '$_bd' bound on the --admin waiver" \
            || die "the --admin bounds are deferred to a record Copilot cannot read: '$_bd' is missing"
    done
    # AND THE POST-MERGE CONFIRMATION, ASSERTED SEPARATELY BECAUSE IT IS NOT A
    # BOUND. It runs after `gh pr merge` has been issued, so it cannot justify the
    # bypass — but removing it is still a finding, because the driver then acts on
    # a merge that did not happen. Listing it with the bounds taught a reviewer to
    # count a reporting safeguard as a reason the merge was allowed.
    for _pm in 'NOT a bound' \
               'read back after the merge command' \
               'reported as queued rather than merged'; do
        grep -qF "$_pm" "$ROOT/.github/copilot-instructions.md" \
            && pass "…and states '$_pm' as a post-merge confirmation rather than a bound" \
            || die "the post-merge confirmation is missing from copilot-instructions.md: '$_pm'"
    done
    # …AND A PROBE THAT ERRORS IS NOT AN INACTIVE RECORD. `grep -q … || continue`
    # treats rc 2 — unreadable, vanished between the `-f` and the read — exactly
    # like rc 1, "this record is not accepted", so an accepted waiver nobody can
    # read is silently skipped and the contract reports success without checking
    # it. Only the ordinary no-match status continues; anything else fails.
    # ONE DECISION TABLE, USED BY THE SCAN AND BY THE CASES THAT PROVE IT. The
    # malformed-status cases used to re-implement the parse and the `case` arms,
    # so a regression in the real scanner left them green while a live waiver
    # dropped out of both reviewer-file checks — a copy of a rule proving the copy.
    #
    # STDERR IS DISCARDED, THE STATUS IS NOT: the caller names the file itself, so
    # grep's own complaint would only land in the middle of the suite's output.
    # THE NAME IS MATCHED LITERALLY, AND WHOLE. Two defects, one function.
    #
    # A derived basename is a BASIC REGULAR EXPRESSION to `grep`, so a record
    # legitimately named `2026-09-01-bash-3.2` is satisfied by the text
    # `bash-3x2`; `-F` is that half.
    #
    # And `-F` is a SUBSTRING search, which the path alone does not bound. With
    # `2026-09-01-bash-3.2` accepted, `docs/decisions/2026-09-01-bash-3.2.md` is
    # contained by `2026-09-01-bash-3.2-portability.md`, by
    # `old-docs/decisions/2026-09-01-bash-3.2.md`, and by that same path with a
    # `.bak` after it — none of which names the accepted record.
    #
    # SO THE MATCH CARRIES THE DELIMITERS THE PROSE USES. Both reviewer files
    # write these as inline code, and a backtick on each side is a real boundary:
    # nothing can precede the opening one inside a longer path, and nothing can
    # follow the closing one inside a longer filename. Matching the delimiter the
    # document actually uses is what ends this class, rather than a third guess at
    # where a path stops.
    _dr_named_in() {   # _dr_named_in <reviewer-file> <record-basename>
        grep -qF "\`docs/decisions/$2.md\`" "$1"
    }
    _dr_action() {   # _dr_action <file> ; prints require | skip | refuse
        local _l _rc=0 _st
        _l="$(grep -i '^\*\*Status:\*\*' "$1" 2>/dev/null)" || _rc=$?
        # rc 1 is "no such line", which is a malformed record; anything above it
        # is a read error, and both are refusals rather than silent skips.
        [ "$_rc" -le 1 ] || { printf refuse; return 0; }
        _st="${_l#*\*\*Status:\*\* }"
        _st="${_st%% *}"
        # LOWERCASED WITH `tr`, not `declare -l`: the mac-shaped job runs bash 3.2.
        #
        # THREE VALUES, AND THIS REPOSITORY USES ALL THREE. A fourth was carried
        # here uncovered, which is a table arm no case could have caught
        # regressing — anything not on this list is REFUSED, so a record reaching
        # for a new word fails loudly and somebody decides what it means.
        _st="$(printf '%s' "$_st" | tr '[:upper:]' '[:lower:]')"
        case "$_st" in
            accepted)             printf require ;;
            superseded|rejected)  printf skip ;;
            *)                    printf refuse ;;
        esac
        return 0
    }
    for _dr in "$ROOT"/docs/decisions/*.md; do
        [ -f "$_dr" ] || continue
        # THE SCAN ASKS THE TABLE. Nothing is parsed here, so the cases below
        # that prove the classification are proving THIS behaviour.
        case "$(_dr_action "$_dr")" in
            require) ;;
            skip)    continue ;;
            *) die "$(basename "$_dr") has no usable Status; a live waiver would be skipped as inactive"
               continue ;;
        esac
        _drn="$(basename "$_dr" .md)"
        for _wv in "$ROOT/AGENTS.md" "$ROOT/.github/copilot-instructions.md"; do
            _dr_named_in "$_wv" "$_drn" \
                && pass "$(basename "$_wv") names the $_drn waiver" \
                || die "$(basename "$_wv") does not name $_drn; that reviewer can re-raise an accepted limit"
        done
    done
    # …AND THAT DISTINCTION IS RUN, not merely written. A record whose status
    # cannot be read must fail the fixture rather than be skipped as inactive.
    #
    # SKIPPED BY NAME WHERE THE PROBE CAN READ IT ANYWAY: a run as root, or a
    # filesystem ignoring the mode, makes the unreadable file readable and the
    # case would assert nothing.
    # …AND THE TABLE IS EXERCISED, through the same function the scan calls.
    #
    # AN UNREADABLE RECORD IS A REFUSAL, not "not accepted". Skipped by name where
    # the probe can read it anyway — a root run, or a filesystem ignoring the
    # mode, would leave the case asserting nothing.
    _dr_un="$TMP/unreadable-record.md"
    printf '# Decision: a probe\n\n**Status:** accepted\n' > "$_dr_un" 2>/dev/null
    chmod 000 "$_dr_un" 2>/dev/null || true
    if [ -f "$_dr_un" ] && ! grep -qi 'Status' "$_dr_un" 2>/dev/null; then
        [ "$(_dr_action "$_dr_un")" = refuse ] \
            && pass "…and an unreadable record is refused rather than treated as inactive" \
            || die "an unreadable record classified as '$(_dr_action "$_dr_un")'"
    else
        echo "ok   - (this run can read a mode-000 file; the unreadable-record case did not run)"
    fi
    chmod 644 "$_dr_un" 2>/dev/null || true
    rm -f "$_dr_un"
    # AND A MALFORMED STATUS IS REFUSED RATHER THAN SKIPPED, which is the shape
    # that matters: a status deleted, misspelled or reformatted must not pass for
    # `superseded` and take a live waiver out of the check with it.
    _dr_mal="$TMP/malformed-record.md"
    for _dr_bad in '' '**Status:** acccepted' '**Status:** pending' '**Status:**'; do
        printf '# Decision: a probe\n\n%s\n' "$_dr_bad" > "$_dr_mal"
        [ "$(_dr_action "$_dr_mal")" = refuse ] \
            && pass "…and a record whose status is '${_dr_bad:-absent}' is refused, not skipped" \
            || die "the status '${_dr_bad:-absent}' classified as '$(_dr_action "$_dr_mal")'"
    done
    # …AND THE THREE LIVE VALUES CLASSIFY THE WAY THE SCAN NEEDS, so the refusals
    # above are not passing because the table refuses everything.
    for _dr_ok in 'accepted:require' 'Accepted:require' 'superseded:skip' 'rejected:skip' 'withdrawn:refuse'; do
        printf '# Decision: a probe\n\n**Status:** %s\n' "${_dr_ok%%:*}" > "$_dr_mal"
        [ "$(_dr_action "$_dr_mal")" = "${_dr_ok##*:}" ] \
            && pass "…and '${_dr_ok%%:*}' classifies as ${_dr_ok##*:}" \
            || die "'${_dr_ok%%:*}' classified as '$(_dr_action "$_dr_mal")', not ${_dr_ok##*:}"
    done
    rm -f "$_dr_mal"
    # …AND THE NAMING CHECK IS LITERAL, exercised through the same function the
    # scan calls. A metacharacter in a record's basename is legitimate — a bash
    # version in it is the obvious case — and as a regular expression it matches
    # text that does not name the record at all.
    _dr_nm="$TMP/reviewer-probe.md"
    printf 'this file mentions `docs/decisions/2026-09-01-bash-3x2.md` and nothing else\n' > "$_dr_nm"
    _dr_named_in "$_dr_nm" '2026-09-01-bash-3.2' \
        && die "the naming check matched '2026-09-01-bash-3.2' against 'bash-3x2'; it is a regular expression" \
        || pass "…and a record name carrying a metacharacter is matched literally"
    # …AND A LONGER NAME DOES NOT ANSWER FOR A SHORTER ONE. `-F` is still a
    # SUBSTRING search, so without the `.md` the accepted `…-bash-3.2` record
    # reports as named by a file that mentions only `…-bash-3.2-portability`.
    printf 'this file names `docs/decisions/2026-09-01-bash-3.2-portability.md` only\n' > "$_dr_nm"
    _dr_named_in "$_dr_nm" '2026-09-01-bash-3.2' \
        && die "a longer record name satisfied the check for a shorter one; the match is a substring" \
        || pass "…and a longer record name does not answer for a shorter one"
    # …AND NEITHER SIDE OF THE PATH IS OPEN. Without the delimiters the prose
    # uses, a mention of a DIFFERENT directory or of a backup of the file contains
    # the searched string and answers for the record.
    for _dr_near in 'old-docs/decisions/2026-09-01-bash-3.2.md' \
                    'docs/decisions/2026-09-01-bash-3.2.md.bak'; do
        printf 'this file mentions `%s` and nothing else\n' "$_dr_near" > "$_dr_nm"
        _dr_named_in "$_dr_nm" '2026-09-01-bash-3.2' \
            && die "'$_dr_near' answered for the accepted record; the path is unbounded" \
            || pass "…and '$_dr_near' does not answer for it"
    done
    printf 'this file names `docs/decisions/2026-09-01-bash-3.2.md` properly\n' > "$_dr_nm"
    _dr_named_in "$_dr_nm" '2026-09-01-bash-3.2' \
        && pass "…while the record it does name is still found" \
        || die "the naming check missed a record the file names"
    rm -f "$_dr_nm"
else
    die "docs/decisions/ is missing; accepted limitations have nowhere to live"
fi


# ── both reviewer files carry the same context and finding-quality rules ───
# A clause outside the generated body of AGENTS.md reaches one reviewer of two.
for doc in "$SCRIPT_DIR/../../../AGENTS.md" "$SCRIPT_DIR/../../../.github/copilot-instructions.md"; do
    [ -f "$doc" ] || { die "missing reviewer instruction file: $doc"; continue; }
    name="$(basename "$doc")"
    # DISTINGUISHING text, not a phrase the file already contained. `resolved
    # threads` matched `AGENTS.md`'"'"'s "zero unresolved threads" and the Copilot
    # file'"'"'s "Waivers and resolved threads" heading, so this pair of assertions
    # passed with the reply-context paragraph deleted from both — a guard for
    # duplicate drift that could not see the duplicate drift.
    # FLATTENED before matching. These files are wrapped prose, so a phrase that
    # spans a line break is invisible to line-based grep — the first version of
    # these assertions failed on correct text for exactly that reason.
    flat="$(tr '\n' ' ' < "$doc" | tr -s ' ')" || { die "$name: could not read"; continue; }
    grep -qi 'replies on .*resolved threads' <<<"$flat" \
        && pass "$name: earlier-round replies are named as context" \
        || die "$name: does not tell the reviewer to read earlier thread replies"
    # The PREDICATE, not the phrase: "changed code is still" alone is satisfied by
    # "…is still correct", which reverses the rule while matching the check.
    grep -qi 'changed code is still[[:space:]]*defective' <<<"$flat" \
        && pass "$name: a wrong reply is a finding only if the code is still DEFECTIVE" \
        || die "$name: would have the reviewer block a merge to correct the record"
    # THE CANONICAL CLAUSE, VERBATIM — the prose analogue of the whitelist that
    # settled the endpoint guard.
    #
    # Positive patterns plus negation scans do not converge here. "Include the
    # triggering input" was defeated by "do not include…", then by "include
    # neither… nor…", and "naming any second copy" by "avoid naming…" and then by
    # "omit naming…". Each fix enumerated one more way to negate, and English has
    # no bounded list of those — the same wall the route and command blacklists
    # hit, with no whitelist of commands available because the subject is meaning.
    #
    # What IS bounded is the sentence itself. Requiring the exact clause makes any
    # alteration fail — negated, reworded, or weakened — and the cost is precisely
    # the property wanted for contract text: changing it is a deliberate act that
    # updates this list, not a quiet edit that still satisfies a pattern.
    #
    # THE FIX-SHAPE RULE IS IN THIS LIST FOR BOTH OF THOSE REASONS AT ONCE. It
    # arrived as two substring greps, and each fell to the wall above: `guard where
    # a removal would do` survives "…is **not** a finding", and `which of the two
    # they took and why` survives moving the explanation back to the round summary
    # — which is the regression this round fixed, passing its own check. The two
    # clauses below carry the polarity and the location inside the matched text,
    # so neither edit can be made without failing here.
    req_clauses=(
                '**The loop trusts the `PATH` of the shell it was started from**'
                'A `PATH` check in one helper is a defect, not a fix'
                'the input or state that triggers it** — the concrete case, not the category'
                '**the consequence** — what ends up wrong, in terms of what this tool does'
                'The author is expected to assert the consequence in a test, and can only do that if you state it'
                'if the same defect exists in a second copy **that this PR also changes**, say so'
                '**The fault-tolerance pass needs commits to review.**'
                'A change that offers the pass on an equal-sha head, or that removes the'
                '**A guard where a removal would do is a finding.**'
                'The author is required to say **on the thread** which of the two they took and why'
                'asserts the invariant, not the version'
    )
    for clause in ${req_clauses+"${req_clauses[@]}"}; do
        grep -qF "$clause" <<<"$flat" \
            && pass "$name: states verbatim — ${clause:0:52}…" \
            || die "$name: this required clause is altered or missing — ${clause:0:52}…"
    done
    grep -qi 'proposal, not the finding' <<<"$flat" \
        && pass "$name: a code suggestion is a proposal, not the finding" \
        || die "$name: does not say a code suggestion is only a proposal"
done

# ── THE COPILOT COPY IS GENERATED, AND IS CURRENT ──────────────────────────
# Compared against the generator's output, since the header is the generator's and not AGENTS.md's.
_gen="$ROOT/.github/build-copilot-instructions.sh"
if [ ! -f "$_gen" ]; then
    die "the Copilot copy generator is missing: .github/build-copilot-instructions.sh"
elif _gen_tmp="$(mktemp_d)"; then
    # Files and `cmp`, never a command substitution: an assignment drops a NUL.
    _gen_rc=0
    "$_gen" > "$_gen_tmp/out.md" 2>/dev/null || _gen_rc=$?
    { [ "$_gen_rc" -eq 0 ] && [ -s "$_gen_tmp/out.md" ]; } \
        && pass "the Copilot copy generator runs" \
        || die "the Copilot copy generator failed or printed nothing"
    cmp -s "$_gen_tmp/out.md" "$ROOT/.github/copilot-instructions.md" \
        && pass "…and .github/copilot-instructions.md is byte-for-byte what it generates from AGENTS.md" \
        || die "the Copilot copy is behind AGENTS.md; regenerate it as CLAUDE.md says"
    { cat "$_gen_tmp/out.md"; printf '\0'; } > "$_gen_tmp/nul.md"
    _gen_rc=0
    cmp -s "$_gen_tmp/out.md" "$_gen_tmp/nul.md" || _gen_rc=$?
    case "$_gen_rc" in
        1) pass "…and a copy differing only by an embedded NUL is behind" ;;
        0) die "a copy differing from the generated one only by an embedded NUL passes the currentness check" ;;
        *) die "the currentness check could not read the NUL candidate (rc=$_gen_rc); the case proves nothing" ;;
    esac
    _gen_rc=0
    "$_gen" "$ROOT/AGENTS.md" extra > "$_gen_tmp/two.out" 2>/dev/null || _gen_rc=$?
    { [ "$_gen_rc" -ne 0 ] && [ ! -s "$_gen_tmp/two.out" ]; } \
        && pass "…and a second argument is refused with nothing emitted" \
        || die "a two-argument call exited $_gen_rc with output on stdout"
    _gen_rc=0
    "$_gen" "" > "$_gen_tmp/empty.out" 2>/dev/null || _gen_rc=$?
    { [ "$_gen_rc" -ne 0 ] && [ ! -s "$_gen_tmp/empty.out" ]; } \
        && pass "…and an empty source operand is refused rather than read as the default" \
        || die "an empty source operand exited $_gen_rc with output on stdout"
    mkdir -p "$_gen_tmp/dash" && cp "$ROOT/AGENTS.md" "$_gen_tmp/dash/-"
    _gen_rc=0
    (cd "$_gen_tmp/dash" && "$_gen" - > "$_gen_tmp/dash.out" 2>/dev/null) || _gen_rc=$?
    { [ "$_gen_rc" -eq 0 ] && cmp -s "$_gen_tmp/out.md" "$_gen_tmp/dash.out"; } \
        && pass "…and a source named - is read as a file, never as stdin" \
        || die "a source named - exited $_gen_rc or emitted something other than the copy"
    mkdir -p "$_gen_tmp/cdtrap/.github"
    _gen_rc=0
    (cd "$ROOT" && CDPATH="$_gen_tmp/cdtrap" .github/build-copilot-instructions.sh > "$_gen_tmp/cdpath.out" 2>/dev/null) || _gen_rc=$?
    { [ "$_gen_rc" -eq 0 ] && cmp -s "$_gen_tmp/out.md" "$_gen_tmp/cdpath.out"; } \
        && pass "…and the documented relative invocation survives a CDPATH holding another .github" \
        || die "under a CDPATH holding another .github the relative invocation exited $_gen_rc or emitted something else"
    printf '%s\n' 'a' '<!-- copilot-body-start -->' 'b' '<!-- copilot-body-end -->' 'c' \
        '<!-- copilot-body-start -->' 'd' '<!-- copilot-body-end -->' > "$_gen_tmp/twice.md"
    printf '%s\n' 'a' '<!-- copilot-body-start -->' 'b' > "$_gen_tmp/unclosed.md"
    printf '%s\n' 'a' '<!-- copilot-body-end -->' 'b' '<!-- copilot-body-start -->' 'c' > "$_gen_tmp/reversed.md"
    for _gen_bad in twice unclosed reversed; do
        _gen_rc=0
        "$_gen" "$_gen_tmp/$_gen_bad.md" > "$_gen_tmp/$_gen_bad.out" 2>/dev/null || _gen_rc=$?
        { [ "$_gen_rc" -ne 0 ] && [ ! -s "$_gen_tmp/$_gen_bad.out" ]; } \
            && pass "…and a $_gen_bad marker layout is refused with nothing emitted" \
            || die "a $_gen_bad marker layout exited $_gen_rc with output on stdout; redirected, that overwrites the Copilot copy with a partial policy"
    done
    # A second open of the pathname cannot reproduce the one-open output, and a single read never makes one.
    if mkfifo "$_gen_tmp/once.a" "$_gen_tmp/once.b" 2>/dev/null && ln -s "$_gen_tmp/once.a" "$_gen_tmp/once"; then
        ( printf '%s\n' '<!-- copilot-body-start -->' 'one open' '<!-- copilot-body-end -->' > "$_gen_tmp/once.a"
          ln -sf "$_gen_tmp/once.b" "$_gen_tmp/once"
          printf '%s\n' 'second open' > "$_gen_tmp/once.b" ) 2>/dev/null &
        _gen_w=$!
        _gen_rc=0
        run_limited 20 "$_gen" "$_gen_tmp/once" > "$_gen_tmp/once.out" 2>/dev/null || _gen_rc=$?
        kill "$_gen_w" 2>/dev/null || true; wait "$_gen_w" 2>/dev/null || true
        _gen_second=0
        grep -q 'second open' "$_gen_tmp/once.out" || _gen_second=$?
        { [ "$_gen_rc" -eq 0 ] && grep -q 'one open' "$_gen_tmp/once.out" && [ "$_gen_second" -eq 1 ]; } \
            && pass "…and the source is read once, so a source that changes between opens is emitted as validated" \
            || die "the generator read its source more than once, or the probe could not read its output (rc=$_gen_rc, second-open grep rc=$_gen_second)"
    else
        die "could not stage a FIFO source; the single-read case did not run"
    fi
    rm -rf "$_gen_tmp"
else
    die "could not stage the generator cases; none of them ran"
fi


if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
