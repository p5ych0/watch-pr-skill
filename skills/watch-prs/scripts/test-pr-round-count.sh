#!/usr/bin/env bash
# Unit tests for pr-round-count.sh.
#
# The v1 pause lived in a /tmp counter file, so the guarantee quietly evaporated
# on a new machine or after a cleanup. These cases pin the two properties that
# matter: the count is derived from GitHub every time, and anything unreadable
# stops rather than reading as "no rounds yet" — which is the direction that
# skips the pause.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# `mktemp_d`: a bare `mktemp -d` that fails leaves $TMP empty and the cleanup
# trap then runs `rm -rf` over paths at the filesystem root.
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-round-count.sh"
TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

CODEX='chatgpt-codex-connector[bot]'
COPILOT='copilot-pull-request-reviewer[bot]'

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"/issues/"*"/comments"*)
    # A clean pass leaves no review, only this comment — so the round count has
    # to read both endpoints. Defaults to an empty list so the pre-existing
    # cases behave exactly as before.
    [ -n "${GH_ICOMMENTS_RC:-}" ] && exit "$GH_ICOMMENTS_RC"
    if [ -n "${GH_ICOMMENTS:-}" ]; then cat "$GH_ICOMMENTS"; else printf '[]'; fi ;;
  *"/reviews"*) [ -n "${GH_RC:-}" ] && exit "$GH_RC"; cat "${GH_REVIEWS:-/dev/null}" ;;
  *) printf '{}' ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
run() { REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" "$@"; }

# Expand a short tag into a 40-hex SHA. `commit_id` is validated as a real SHA,
# so fixtures must look like commits: a short tag would be rejected as malformed
# and every case would pass for the wrong reason.
#
# sha1sum, not zero-padding: padding "c1" and "c10" to 40 characters produces the
# SAME string, which silently merged two rounds into one and made the boundary
# fixtures off by one.
# NOT `sha1sum`: stock macOS ships `shasum`, not the GNU name, and the suite is a
# mandatory pre-push gate — the same portability trap `timeout` was. Falls back
# through the available hashers, then to a pure-shell expansion that needs none.
sha() {
    if command -v sha1sum >/dev/null 2>&1; then printf '%s' "$1" | sha1sum | cut -c1-40
    elif command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum | cut -c1-40
    elif command -v openssl >/dev/null 2>&1; then printf '%s' "$1" | openssl dgst -sha1 | awk '{print $NF}' | cut -c1-40
    else
        # Deterministic and distinct per input, which is all the fixtures need.
        local acc="" ch i=0
        while [ "${#acc}" -lt 40 ]; do
            i=$((i + 1))
            ch=$(printf '%s%s' "$1" "$i" | cksum | cut -d" " -f1)
            acc="$acc$(printf '%08x' $((ch % 4294967296)))"
        done
        printf '%s' "${acc:0:40}"
    fi
}

# `submitted_at != null` is what makes a record count as a submitted review, and
# the script now requires a well-formed ISO timestamp before believing that — so
# the fixtures have to carry real ones. The tag in a spec only has to be
# non-null; this turns it into a valid, distinct timestamp. `RAW:<json>` passes a
# value through untouched, for the cases that feed a deliberately bad one.
iso() { printf '"2026-01-%02dT00:00:00Z"' "$(( ($1 - 1) % 28 + 1 ))"; }

# Build a reviews list. Each argument is
#   "<login>|<commit-tag>|<submitted_at|null>[|<state-json>]"
# where the optional fourth field is the raw JSON for `state` — it defaults to a
# plain submitted review, and the state cases below override it.
mk() {
    local first=1 n=0 who c sub st
    { printf '['
      for spec in "$@"; do
          IFS='|' read -r who tag sub st <<<"$spec"
          c="$(sha "$tag")"
          n=$((n + 1))
          case "$sub" in
              null)   ;;
              RAW:*)  sub="${sub#RAW:}" ;;
              *)      sub="$(iso "$n")" ;;
          esac
          [ -n "$st" ] || st='"COMMENTED"'
          [ "$first" -eq 1 ] || printf ','
          first=0
          printf '{"user":{"login":"%s"},"commit_id":"%s","submitted_at":%s,"state":%s,"id":1}' \
              "$who" "$c" "$sub" "$st"
      done
      printf ']'
    } > "$TMP/reviews.json"
}

# ── a round is a distinct reviewed HEAD ────────────────────────────────────
mk "$CODEX|aaa|\"t1\"" "$COPILOT|aaa|\"t1\""
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=1'; } \
    && pass "two reviewers on one head is ONE round" \
    || die "same-head reviews counted twice (rc=$rc out='$out')"

mk "$CODEX|aaa|\"t1\"" "$CODEX|aaa|\"t2\""
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
printf '%s' "$out" | grep -q 'rounds=1' \
    && pass "a re-review of an unchanged head does not inflate the count" \
    || die "re-review inflated the count: $out"

mk "$CODEX|aaa|\"t1\"" "$CODEX|bbb|\"t2\"" "$CODEX|ccc|\"t3\""
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=3'; } \
    && pass "three distinct heads is three rounds" \
    || die "distinct-head count wrong (rc=$rc out='$out')"

# An UNSUBMITTED draft is not a round: the pass has not happened yet.
mk "$CODEX|aaa|\"t1\"" "$CODEX|bbb|null"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"
printf '%s' "$out" | grep -q 'rounds=1' \
    && pass "a draft review is not a round" \
    || die "a draft counted as a round: $out"

# Reviews by anyone else are not rounds.
mk "$CODEX|aaa|\"t1\"" "somebody|bbb|\"t2\""
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"
printf '%s' "$out" | grep -q 'rounds=1' \
    && pass "a human review is not a round" \
    || die "a non-reviewer counted: $out"

# ── the boundary pauses, and only ON the boundary ──────────────────────────
specs=(); for ((i=1; i<=9; i++)); do specs+=("$CODEX|c$i|\"t$i\""); done
mk "${specs[@]}"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "9 rounds: no pause" || die "paused early at 9 (rc=$rc)"

specs+=("$CODEX|c10|\"t10\""); mk "${specs[@]}"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'PR_ROUND_PAUSE'; } \
    && pass "10 rounds: pause (exit 3)" \
    || die "no pause at the boundary (rc=$rc out='$out')"

specs+=("$CODEX|c11|\"t11\""); mk "${specs[@]}"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
# THE PAUSE STICKS UNTIL IT IS ANSWERED. It used to clear itself at 11 — the
# count simply stopped being a multiple of ten — so a driver that ignored the
# pause was un-blocked by the very next round, and a count that JUMPED over the
# multiple was never blocked at all. That is how this repository's own PR #10
# went 35 → 41 with the check-in at 40 never firing.
[ "$rc" -eq 3 ] && pass "11 rounds: the pause STICKS until acknowledged" \
    || die "the pause cleared itself at 11 without an answer (rc=$rc)"

# N distinct reviewed heads, for the cases below that care only about the count.
mkreviews() {
    local i sp=(); for ((i=1; i<=$1; i++)); do sp+=("$CODEX|c$i|\"t$i\""); done
    mk "${sp[@]}"
}
# …and an acknowledgement from the operator clears it, for exactly one interval.
mkack() { # <count> [association] [reviewer]
    jq -n --arg n "$1" --arg a "${2:-OWNER}" --arg w "${3:-$CODEX}" \
       '[{user:{login:"operator"},author_association:$a,id:901,created_at:"2026-01-01T00:00:00Z",
          body:("Continuing.\n\n**Review-Pause-Acknowledged:** `" + $w + "` `" + $n + "`\n")}]' \
       > "$TMP/ack.json"
}
mkack 11
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/ack.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'acknowledged=11'; } \
    && pass "an acknowledgement at 11 clears the pause" \
    || die "the acknowledgement did not clear the pause (rc=$rc out='$out')"

# The next check-in is a full interval PAST the acknowledged count, not the next
# multiple of ten — otherwise acknowledging at 11 would pause again at 20, nine
# rounds later instead of ten.
mkreviews 21; mkack 11
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/ack.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && pass "the next check-in is one interval past the acknowledgement" \
    || die "no pause at 21 after acknowledging 11 (rc=$rc out='$out')"
mkreviews 20; mkack 11
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/ack.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "…and not before it" \
    || die "paused at 20 after acknowledging 11 (rc=$rc out='$out')"

# A COUNT THAT JUMPS OVER THE BOUNDARY still pauses. This is the whole defect:
# a single round can contribute several countable heads, so equality against a
# multiple is a test a large enough step walks straight past.
mkreviews 41
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'rounds=41'; } \
    && pass "a count that stepped over the boundary (41) still pauses" \
    || die "41 rounds sailed past the check-in (rc=$rc out='$out')"

# ── an acknowledgement belongs to ONE reviewer's count ────────────────────
# The Codex and Copilot phases are separate loops with separate counts — that is
# why this script takes a reviewer list at all — and an unscoped acknowledgement
# crossed between them. Acknowledging 41 Codex rounds was then read by a Copilot
# invocation with 5, tripped the ahead-of-count guard, and returned status 2 for
# good: the Copilot phase and the merge gate behind it were blocked permanently.
# This is not hypothetical. It happened on this repository's own PR #10, within
# the hour, to the acknowledgement that had just cleared the Codex pause.
mkreviews 41
mkack 41 OWNER "$CODEX"
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/ack.json" run 7 "$CODEX" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'acknowledged=41'; } \
    && pass "a Codex acknowledgement clears the Codex pause" \
    || die "the scoped acknowledgement did not apply to its own reviewer (rc=$rc out='$out')"
# The other phase has its own, smaller count. The Codex acknowledgement must be
# invisible to it — not merely harmless, invisible: `ack=41` against 5 rounds is
# the ahead-of-count error, so a leak here is a hard block rather than a wrong
# number, and it fails the whole phase.
mk "$COPILOT|k1|\"t1\"" "$COPILOT|k2|\"t2\"" "$COPILOT|k3|\"t3\""
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/ack.json" run 7 "$COPILOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'acknowledged=0'; } \
    && pass "…and is invisible to the Copilot count, which has its own" \
    || die "a Codex acknowledgement leaked into the Copilot phase (rc=$rc out='$out')"
# The converse, so the rule is not satisfied by a parser that drops every
# acknowledgement whose reviewer is not the first in the list.
mkack 3 OWNER "$COPILOT"
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/ack.json" run 7 "$COPILOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'acknowledged=3'; } \
    && pass "a Copilot acknowledgement applies to the Copilot count" \
    || die "the Copilot acknowledgement was not read (rc=$rc out='$out')"
# An unscoped footer is not an acknowledgement at all. There is no legacy form:
# accepting one would reintroduce exactly the cross-phase block above.
jq -n '[{user:{login:"operator"},author_association:"OWNER",id:902,created_at:"2026-01-01T00:00:00Z",
         body:"Continuing.\n\n**Review-Pause-Acknowledged:** `3`\n"}]' > "$TMP/ack.json"
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/ack.json" run 7 "$COPILOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'acknowledged=0'; } \
    && pass "a footer naming no reviewer is not an acknowledgement" \
    || die "an unscoped footer was accepted (rc=$rc out='$out')"
# The login is COMPARED, not interpolated into a pattern: `[bot]` is a character
# class, so a regex-built matcher would accept a login sharing one of those
# characters and reject the real one.
mkack 41 OWNER 'chatgpt-codex-connector[b]'
mkreviews 41
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/ack.json" run 7 "$CODEX" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && pass "a login that only matches Codex as a regex does not acknowledge" \
    || die "a bracket-class near-miss acknowledged the pause (rc=$rc out='$out')"

# ── the default invocation instructs per reviewer, not per combined count ──
# Invoked with no arguments the helper counts BOTH reviewers, and the pause
# instruction is followed literally. Printing the combined count beside every
# login told the operator to write a Copilot acknowledgement of 41 when Copilot
# had 5 rounds — which a later Copilot-only call reads as ahead of its count and
# refuses permanently. That is the cross-phase block the reviewer-scoped footer
# exists to remove, recreated one layer out, through the message rather than the
# parser.
specs=(); for ((i=1; i<=41; i++)); do specs+=("$CODEX|x$i|\"t$i\""); done
for ((i=1; i<=5; i++)); do specs+=("$COPILOT|y$i|\"u$i\""); done
mk "${specs[@]}"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && pass "the default invocation pauses on the combined count" \
    || die "no pause on 46 combined heads (rc=$rc out='$out')"
printf '%s' "$out" | grep -qF "**Review-Pause-Acknowledged:** \`$CODEX\` \`41\`" \
    && pass "…and instructs the Codex acknowledgement with Codex's own 41" \
    || die "the Codex instruction did not carry 41: '$out'"
printf '%s' "$out" | grep -qF "**Review-Pause-Acknowledged:** \`$COPILOT\` \`5\`" \
    && pass "…and the Copilot acknowledgement with Copilot's own 5" \
    || die "the Copilot instruction did not carry 5: '$out'"
# The consequence, asserted rather than inferred: following the emitted
# instruction must leave BOTH phases working. An instruction that wedges the
# phase it names is worse than none, because it looks like the documented path.
printf '%s' "$out" | grep -qF "\`$COPILOT\` \`46\`" \
    && die "the Copilot instruction carried the combined count, which wedges that phase" \
    || pass "…so following the instruction cannot wedge either phase"

# ── who may acknowledge, and what they may claim ──────────────────────────
# Anyone can comment on a pull request. An unrestricted marker would let a
# reviewer bot — or a passer-by — switch the operator pause off permanently.
for assoc in NONE CONTRIBUTOR FIRST_TIME_CONTRIBUTOR; do
    mkack 41 "$assoc"
    out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/ack.json" run 7 2>&1)"; rc=$?
    [ "$rc" -eq 3 ] && pass "a $assoc comment cannot acknowledge the pause" \
        || die "$assoc acknowledged the pause (rc=$rc out='$out')"
done
# An acknowledgement of a round that has not happened is the disable-forever
# shape, reachable by a typo as easily as by an attacker.
mkack 999999999
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/ack.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'ack_ahead_of_count'; } \
    && pass "an acknowledgement ahead of the count is refused, not obeyed" \
    || die "a future acknowledgement disabled the pause (rc=$rc out='$out')"
# ── ONE COMMENT, A LINE PER REVIEWER, WHICH IS WHAT THE PAUSE ASKS FOR ─────
# The instruction reads "post a comment containing, for each reviewer counted
# here:" and then prints one line per login. Following it literally used to leave
# the FIRST login unacknowledged: the scan took the last match in the body, so a
# later call for that reviewer saw nothing and paused again — with the operator
# having done exactly what the tool asked. Issue #59.
#
# The Codex line is first here on purpose: it is the one that was discarded.
mkreviews 11
jq -n --arg c "$CODEX" --arg p "$COPILOT" \
   '[{user:{login:"operator"},author_association:"OWNER",id:903,created_at:"2026-01-01T00:00:00Z",
      body:("Continuing.\n\n**Review-Pause-Acknowledged:** `" + $c + "` `11`\n**Review-Pause-Acknowledged:** `" + $p + "` `0`\n")}]' \
   > "$TMP/ack.json"
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/ack.json" run 7 "$CODEX" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'acknowledged=11'; } \
    && pass "one comment acknowledges the reviewer named FIRST in it" \
    || die "the first login in a multi-reviewer acknowledgement was dropped (rc=$rc out='$out')"
# …and the one named last, which is what used to work by accident.
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/ack.json" run 7 "$COPILOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'acknowledged=0'; } \
    && pass "…and the one named last, from the same comment" \
    || die "the last login in a multi-reviewer acknowledgement was dropped (rc=$rc out='$out')"

# A field-shaped line quoted in prose — this script's own documentation, pasted
# into a comment — is not an acknowledgement. Same anchoring rule as the
# reviewed-commit footer.
jq -n '[{user:{login:"operator"},author_association:"OWNER",id:902,created_at:"2026-01-01T00:00:00Z",
         body:"To continue, post **Review-Pause-Acknowledged:** `41` in a comment."}]' \
   > "$TMP/ack.json"
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/ack.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && pass "a marker quoted mid-sentence does not acknowledge" \
    || die "an inline mention was read as an acknowledgement (rc=$rc out='$out')"
mkreviews 11
# The pause re-arms for the next multiple.
for ((i=12; i<=20; i++)); do specs+=("$CODEX|c$i|\"t$i\""); done
mk "${specs[@]}"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && pass "20 rounds: the pause re-arms" || die "no pause at the second boundary (rc=$rc)"

# ── threshold handling ─────────────────────────────────────────────────────
mk "$CODEX|aaa|\"t1\"" "$CODEX|bbb|\"t2\""
out="$(REVIEW_ROUND_THRESHOLD=2 GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && pass "an explicit threshold is honoured" || die "threshold=2 did not pause (rc=$rc)"
out="$(REVIEW_ROUND_THRESHOLD=0 GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'threshold=0'; } \
    && pass "threshold=0 disables the check-in" || die "threshold=0 still paused (rc=$rc)"
# A typo must not silently disable a safety pause.
specs2=(); for ((i=1; i<=10; i++)); do specs2+=("$CODEX|d$i|\"t$i\""); done
mk "${specs2[@]}"
out="$(REVIEW_ROUND_THRESHOLD=abc GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'threshold=10'; } \
    && pass "a malformed threshold falls back to 10, never to disabled" \
    || die "a typo disabled the check-in (rc=$rc out='$out')"

# Leading zeros are OCTAL to Bash arithmetic: `00` silently disabled the safety
# pause and `08`/`09` aborted with an undocumented exit 1 — neither being the
# documented fallback to 10.
#
# These existed once and were lost when the file was reverted to fix an unrelated
# fixture bug, so the guard shipped without them. That is exactly the regression
# this block prevents.
specs_lz=(); for ((i=1; i<=10; i++)); do specs_lz+=("$CODEX|lz$i|\"t$i\""); done
mk "${specs_lz[@]}"
for bad in 00 08 09 012; do
    out="$(REVIEW_ROUND_THRESHOLD="$bad" GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
    { [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'threshold=10'; } \
        && pass "threshold '$bad' falls back to 10, not to disabled or an error" \
        || die "threshold '$bad' gave rc=$rc out='$out'"
done
# Exactly `0` still disables the check-in.
out="$(REVIEW_ROUND_THRESHOLD=0 GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'threshold=0'; } \
    && pass "a bare 0 still disables the check-in" || die "0 no longer disables (rc=$rc)"

# ── a CLEAN pass is a round, and leaves no review ─────────────────────────
# Codex submits a review only when it has findings, so a clean head appears
# nowhere in `pulls/N/reviews`. Counting reviews alone reported nine heads for
# nine-plus-a-clean-tenth, and the phase-transition checks that consult this
# number then skipped the operator pause at exactly the boundary.
mk_clean_icomment() {   # <sha10>… ; one clean-pass comment per argument
    local first=1
    { printf '['
      for sha in "$@"; do
          [ "$first" -eq 1 ] || printf ','
          first=0
          jq -n -c --arg login "$CODEX" --arg sha "$sha" \
            '{id: 700, created_at: "2026-01-01T00:00:00Z", user: {login: $login}, body: ("Codex Review: Didn'"'"'t find any major issues.\n\n**Reviewed commit:** `" + $sha + "`\n")}'
      done
      printf ']'
    } > "$TMP/icomments.json"
}

# Nine finding-bearing heads plus a clean tenth is TEN rounds, and a boundary.
specs=(); for ((i=1; i<=9; i++)); do specs+=("$CODEX|k$i|t"); done
mk "${specs[@]}"
mk_clean_icomment "$(sha k10 | cut -c1-10)"
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'rounds=10'; } \
    && pass "nine reviewed heads plus a clean tenth is ten rounds, and pauses" \
    || die "clean-comment head not counted (rc=$rc out='$out')"

# A clean comment on a head that ALREADY has a review is not a second round.
specs=(); for ((i=1; i<=9; i++)); do specs+=("$CODEX|k$i|t"); done
mk "${specs[@]}"
mk_clean_icomment "$(sha k9 | cut -c1-10)"
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=9'; } \
    && pass "a clean comment on an already-counted head is not a new round" \
    || die "double-counted a head (rc=$rc out='$out')"

# A comment from another account, or without the clean phrasing, is not a round.
specs=(); for ((i=1; i<=9; i++)); do specs+=("$CODEX|k$i|t"); done
mk "${specs[@]}"
jq -n -c --arg sha "$(sha k10 | cut -c1-10)" \
    '[{id: 701, created_at: "2026-01-01T00:00:00Z", user: {login: "somebody"}, body: ("Codex Review: Didn'"'"'t find any major issues.\n\n**Reviewed commit:** `" + $sha + "`\n")}]' \
    > "$TMP/icomments.json"
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=9'; } \
    && pass "a clean comment from another account is not a round" \
    || die "another account added a round (rc=$rc out='$out')"

# An unreadable comment fetch is NOT "no clean passes".
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS_RC=1 run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "an unreadable comment fetch => 2, never a lower count" \
    || die "comment fetch failure gave rc=$rc"

# A short hash in the footer cannot be deduplicated against the 10-char prefix
# taken from a full review SHA, so accepting one would add a PHANTOM round — and
# ten real heads plus a phantom reports 11, sailing past the modulo-10 pause.
specs=(); for ((i=1; i<=10; i++)); do specs+=("$CODEX|m$i|t"); done
mk "${specs[@]}"
jq -n -c --arg login "$CODEX" --arg sha "$(sha m10 | cut -c1-8)" \
    '[{id: 702, created_at: "2026-01-01T00:00:00Z", user: {login: $login}, body: ("Codex Review: Didn'"'"'t find any major issues.\n\n**Reviewed commit:** `" + $sha + "`\n")}]' \
    > "$TMP/icomments.json"
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'rounds=10'; } \
    && pass "a short-hash footer adds no phantom round; the boundary still pauses" \
    || die "short hash changed the count (rc=$rc out='$out')"

# A clean-pass comment with no `created_at` is not a round. This helper never
# reads that field — it counts on the footer and the phrasing — so a malformed
# record was countable, and an extra round pushes the count past the operator
# check-in. That is the unsafe direction, and it is the consequence the shared
# validator's `created_at` rule exists to prevent, asserted where the consequence
# lands rather than only where the rule is written.
specs=(); for ((i=1; i<=9; i++)); do specs+=("$CODEX|m$i|t"); done
mk "${specs[@]}"
jq -n -c --arg login "$CODEX" --arg sha "$(sha m10 | cut -c1-10)" \
    '[{id: 705, user: {login: $login},
       body: ("Codex Review: Didn'"'"'t find any major issues.\n\n**Reviewed commit:** `" + $sha + "`\n")}]' \
    > "$TMP/icomments.json"
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a clean-pass comment with no created_at fails closed, rather than counting" \
    || die "a comment without created_at was counted (rc=$rc out='$out')"
printf '%s' "$out" | grep -q 'rounds=10' \
    && die "…and it inflated the count to 10, which is what skips the check-in: $out" \
    || pass "…so it cannot inflate the count past the operator check-in"

# The footer anchoring is enforced HERE too. The parser change was applied to
# both helpers but fixtured in only one, so regressing this line to first-match
# extraction would have left the suite green while counting the decoy SHA —
# turning a 10-round boundary into 11 and skipping the operator pause.
specs=(); for ((i=1; i<=10; i++)); do specs+=("$CODEX|n$i|t"); done
mk "${specs[@]}"
jq -n -c --arg login "$CODEX" --arg decoy "$(sha n99 | cut -c1-10)" --arg real "$(sha n10 | cut -c1-10)" \
    '[{id: 703, created_at: "2026-01-01T00:00:00Z", user: {login: $login},
       body: ("Codex Review: Didn'"'"'t find any major issues.\n\nEarlier:\n**Reviewed commit:** `" + $decoy + "`\n\n**Reviewed commit:** `" + $real + "`\n")}]' \
    > "$TMP/icomments.json"
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'rounds=10'; } \
    && pass "a decoy footer adds no round; the genuine last footer is the one counted" \
    || die "decoy footer changed the count (rc=$rc out='$out')"

# …and when the LAST footer names an uncounted head, it is a real eleventh round.
jq -n -c --arg login "$CODEX" --arg decoy "$(sha n1 | cut -c1-10)" --arg real "$(sha n99 | cut -c1-10)" \
    '[{id: 704, created_at: "2026-01-01T00:00:00Z", user: {login: $login},
       body: ("Codex Review: Didn'"'"'t find any major issues.\n\nEarlier:\n**Reviewed commit:** `" + $decoy + "`\n\n**Reviewed commit:** `" + $real + "`\n")}]' \
    > "$TMP/icomments.json"
out="$(GH_REVIEWS="$TMP/reviews.json" GH_ICOMMENTS="$TMP/icomments.json" run 7 2>&1)"; rc=$?
printf '%s' "$out" | grep -q 'rounds=11' \
    && pass "…and a genuine last footer on a new head does add one" \
    || die "the real footer was not counted (rc=$rc out='$out')"

# A threshold beyond Bash arithmetic wraps, possibly to zero — silently taking
# the disable path that only a literal `0` is meant to take.
specs=(); for ((i=1; i<=10; i++)); do specs+=("$CODEX|w$i|t"); done
mk "${specs[@]}"
for huge in 99999999999999999999 18446744073709551616 100000000000000000000000; do
    out="$(REVIEW_ROUND_THRESHOLD="$huge" GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
    { [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'threshold=10'; } \
        && pass "an out-of-range threshold ($huge) falls back to 10, not to disabled" \
        || die "threshold $huge gave rc=$rc out='$out'"
done
# A large-but-sane cadence is still honoured.
out="$(REVIEW_ROUND_THRESHOLD=999 GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'threshold=999'; } \
    && pass "a large but representable threshold is honoured" \
    || die "threshold 999 gave rc=$rc out='$out'"

# ── everything unreadable fails closed ─────────────────────────────────────
out="$(GH_RC=1 run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "fetch failure => 2" || die "fetch failure gave rc=$rc"
: > "$TMP/empty.json"
out="$(GH_REVIEWS="$TMP/empty.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "empty output => 2 (zero pages is not zero rounds)" || die "empty output gave rc=$rc"
printf '{"message":"Not Found"}' > "$TMP/bad.json"
out="$(GH_REVIEWS="$TMP/bad.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "object-shaped page => 2" || die "object page gave rc=$rc"
printf '[{}]' > "$TMP/rec.json"
out="$(GH_REVIEWS="$TMP/rec.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "empty review records => 2" || die "[{}] gave rc=$rc"

# ── a malformed submitted_at is not one more round ─────────────────────────
# `submitted_at != null` decides whether a record counts as a submitted review,
# so any old string satisfied it. One extra matching-reviewer record with a junk
# timestamp and a full-SHA commit_id was counted as another distinct head — and
# at a real boundary that inflates `rounds` past the multiple and SKIPS the
# operator pause, which is the direction that loses the safety check.
for bad in '"zzzz"' '""' '"2026-01-02"' '"2026-01-02T00:00:00zzzz"' '"not a timestamp"'; do
    mk "$CODEX|aaa|RAW:$bad"
    out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "submitted_at $bad => 2, not a counted round" \
        || die "malformed submitted_at $bad gave rc=$rc out='$out'"
done

# The exact case that skips the pause: 10 real rounds plus one junk-timestamp
# record must NOT report 11 and sail past the boundary.
specs=(); for ((i=1; i<=10; i++)); do specs+=("$CODEX|c$i|t"); done
specs+=("$CODEX|junk|RAW:\"zzzz\"")
mk "${specs[@]}"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a junk timestamp at the boundary fails closed instead of skipping the pause" \
    || die "junk timestamp at the boundary gave rc=$rc out='$out' (0 = the pause was skipped)"

# CANONICAL UTC only. Numeric offsets and fractional seconds are valid ISO 8601
# but do not sort chronologically under the LEXICAL sort the review helpers use —
# `03:00:00+02:00` is 01:00 UTC yet sorts after `02:30:00Z`, and `03:00:00.5Z`
# sorts before `03:00:00Z`. The same rule is applied in all three scripts so they
# cannot disagree about what a timestamp is. GitHub returns `Z` here.
mk "$CODEX|aaa|RAW:\"2026-01-02T03:04:05Z\""
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=1'; } \
    && pass "a canonical UTC submitted_at is a real round" \
    || die "canonical UTC timestamp was rejected (rc=$rc out='$out')"
for nonc in '"2026-01-02T03:04:05.123Z"' '"2026-01-02T03:04:05+01:00"' \
            '"2026-01-02T03:04:05-0500"' '"2026-01-02T03:04:05+00:00"'; do
    mk "$CODEX|aaa|RAW:$nonc"
    out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "non-canonical timestamp $nonc => 2" \
        || die "non-canonical $nonc was accepted (rc=$rc out='$out')"
done

# ── `state` decides whether a record is a finished pass ────────────────────
# Counting on `submitted_at` alone meant a record with a null or unrecognised
# state was still a reviewed head. One of those on a distinct full SHA turns a
# true boundary of 10 into 11 and skips the operator pause.
for badstate in 'null' '"WIBBLE"' '""' '123' '"approved"'; do
    mk "$CODEX|aaa|t|$badstate"
    out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] \
        && pass "review state $badstate => 2, not a counted round" \
        || die "state $badstate gave rc=$rc out='$out'"
done

# Every state GitHub actually returns for a submitted review is still a round.
for goodstate in '"APPROVED"' '"CHANGES_REQUESTED"' '"COMMENTED"' '"DISMISSED"'; do
    mk "$CODEX|aaa|t|$goodstate"
    out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
    { [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=1'; } \
        && pass "state $goodstate is a round" \
        || die "valid state $goodstate was rejected (rc=$rc out='$out')"
done

# PENDING is a draft in flight, which is what pr-review-state.sh refuses to read
# as a signoff — so it is not a round however its timestamp reads. Readable, so
# it is a zero rather than an error.
mk "$CODEX|aaa|t|\"PENDING\""
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=0'; } \
    && pass "a PENDING draft is not a round" \
    || die "PENDING counted as a round (rc=$rc out='$out')"

# The case with the consequence: ten real rounds plus one bad-state record must
# not report eleven and sail past the boundary.
specs=(); for ((i=1; i<=10; i++)); do specs+=("$CODEX|c$i|t"); done
specs+=("$CODEX|rogue|t|null")
mk "${specs[@]}"
out="$(GH_REVIEWS="$TMP/reviews.json" run 7 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "a null-state record at the boundary fails closed instead of skipping the pause" \
    || die "null-state record at the boundary gave rc=$rc out='$out' (0 = the pause was skipped)"

# A genuinely empty list is a readable zero, not an error.
printf '[]' > "$TMP/none.json"
out="$(GH_REVIEWS="$TMP/none.json" run 7 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'rounds=0'; } \
    && pass "no reviews yet is a readable zero" || die "empty list gave rc=$rc out='$out'"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
