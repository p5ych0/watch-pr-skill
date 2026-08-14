#!/usr/bin/env bash
# Unit tests for pr-signoff.sh.
#
# A signoff is permission to SKIP a review phase, so the cases here are mostly
# about refusing to find one: a record from a passer-by, a record quoted inside
# prose, a record for the other reviewer, a response that cannot be read. The one
# case that finds a signoff exists so the refusals are not passing because nothing
# is ever found.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-signoff.sh"

TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
BOT='chatgpt-codex-connector[bot]'
OTHER='copilot-pull-request-reviewer[bot]'

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GHSH'
#!/usr/bin/env bash
cat "$GH_OUT" 2>/dev/null
exit "$(cat "$GH_RC" 2>/dev/null || echo 0)"
GHSH
chmod +x "$TMP/bin/gh"

# The payload shape the script actually parses, built from comment bodies so a
# case reads as the thread would.
comments() {   # comments <assoc>|<body> …
    local nodes="" spec assoc body
    for spec in "$@"; do
        assoc="${spec%%|*}"; body="${spec#*|}"
        # `createdAt` IS PART OF THE RECORD, not decoration: a signoff answers a
        # review, and the merge gate cannot tell an answer from a leftover without
        # knowing which came first. A node without one is malformed.
        _cid=$(( ${_cid:-0} + 1 ))
        nodes="$nodes$(printf '{"id":"IC_%s","authorAssociation":"%s","createdAt":"%s","body":%s},' \
            "$_cid" "$assoc" "${SIGNED_AT_FIXTURE:-2026-01-02T00:00:00Z}" "$(printf '%s' "$body" | jq -Rs .)")"
    done
    printf '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s]}}}}}' "${nodes%,}"
}
run() {   # run <reviewer> ; prints "<rc>|<stdout+stderr>"
    local out rc=0
    out="$(run_limited 15 env PATH="$TMP/bin:$PATH" GH_OUT="$TMP/out" GH_RC="$TMP/rc" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" 7 "$1" 2>&1)" || rc=$?
    printf '%s|%s' "$rc" "$out"
}
case_is() {   # case_is <want rc> <needle> <label> [reviewer]
    local got rc body
    got="$(run "${4:-$BOT}")"; rc="${got%%|*}"; body="${got#*|}"
    { [ "$rc" = "$1" ] && printf '%s' "$body" | grep -qF "$2"; } \
        && pass "$3" \
        || die "$3 — rc=$rc (wanted $1) out='$body'"
}
world() { printf '0' > "$TMP/rc"; }

# ── a signoff is found ─────────────────────────────────────────────────────
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" > "$TMP/out"
case_is 0 "sha=$SHA" "a signoff from the repository's owner is read back"
world; comments "COLLABORATOR|**Review-Signoff:** \`$BOT\` \`$SHA\`" > "$TMP/out"
case_is 0 "sha=$SHA" "…and from a collaborator"

# ── none recorded is an ANSWER, not an error ───────────────────────────────
# The distinction matters at the call site: 1 says "asked, there is none" and 2
# says "could not ask". A caller that cannot tell them apart either re-runs a
# review it already has or skips one it does not.
world; comments "OWNER|nothing to see here" > "$TMP/out"
case_is 1 "sha=none" "a PR with no signoff says so, and says it is not an error"

# ── who wrote it decides whether it counts ─────────────────────────────────
# A signoff skips a review phase. A drive-by comment must not grant that.
world; comments "NONE|**Review-Signoff:** \`$BOT\` \`$SHA\`" > "$TMP/out"
case_is 1 "sha=none" "a signoff from a passer-by is not a signoff"
world; comments "CONTRIBUTOR|**Review-Signoff:** \`$BOT\` \`$SHA\`" > "$TMP/out"
case_is 1 "sha=none" "…nor from a first-time contributor"

# ── it is about ONE reviewer ───────────────────────────────────────────────
world; comments "OWNER|**Review-Signoff:** \`$OTHER\` \`$SHA\`" > "$TMP/out"
case_is 1 "sha=none" "Copilot's signoff does not answer for Codex"
world; comments "OWNER|**Review-Signoff:** \`$OTHER\` \`$SHA\`" > "$TMP/out"
case_is 0 "sha=$SHA" "…and is found when Copilot is who was asked about" "$OTHER"

# ── anchored, so prose cannot sign anything off ────────────────────────────
# This file's own documentation shows the marker's shape. Pasting a round summary
# that quotes it must not record a signoff nobody made.
world; comments "OWNER|The marker looks like **Review-Signoff:** \`$BOT\` \`$SHA\` in the docs." > "$TMP/out"
case_is 1 "sha=none" "a marker quoted mid-sentence signs nothing off"

# …AND SO DOES A MARKER WITH PROSE AFTER IT. "`**Review-Signoff:** … is the
# format" is somebody explaining the mechanism, not using it, and a
# start-anchored pattern accepted it as a signoff. The line must BE the record.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\` is the marker format" > "$TMP/out"
case_is 1 "sha=none" "…and one with prose trailing it does not sign off either"

# ── A MALFORMED RECORD IS "COULD NOT TELL", NOT "NONE" ─────────────────────
# Silently discarding a node that cannot be read turns an untrustworthy response
# into the answer "there is no signoff" — and those are precisely the two answers
# this helper exists to keep apart. One costs a repeated phase; the other skips a
# review nobody did.
world; printf '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{}]}}}}}' > "$TMP/out"
case_is 2 "unreadable" "a node missing its fields is unreadable, not absent"
world; printf '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"IC_x","authorAssociation":"OWNER","createdAt":"2026-01-02T00:00:00Z","body":7}]}}}}}' > "$TMP/out"
case_is 2 "unreadable" "…and so is a body that is not a string"
world; printf '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"IC_x","authorAssociation":null,"createdAt":"2026-01-02T00:00:00Z","body":"x"}]}}}}}' > "$TMP/out"
case_is 2 "unreadable" "…and an association that is not a string"

# ── the LAST one wins, so a phase can be reopened ──────────────────────────
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$OLD\`" \
                "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" > "$TMP/out"
case_is 0 "sha=$SHA" "a later signoff supersedes an earlier one"

# ── A PHASE CAN BE REOPENED, AND THE RECORD HAS TO SAY SO ──────────────────
# Choosing "another Codex pass" on an unchanged head leaves the old signoff
# standing: every newer signoff must name a sha, so on an unchanged head there is
# nothing to supersede it with. A resumed session then reads the deliberately
# reopened phase as closed and merges on a review that was withdrawn.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" \
                "OWNER|**Review-Signoff-Revoked:** \`$BOT\`" > "$TMP/out"
case_is 1 "reason=revoked" "a revocation after a signoff reopens the phase"
# THE REVOCATION CARRIES ITS TIMESTAMP TOO. A caller comparing two snapshots to
# see whether anything moved underneath it got `sha=none reason=revoked` both
# times when one revocation had been REPLACED by another — the records compared
# equal, so the second reopening was invisible and a signoff went up over it. And
# `pr-copilot-phase.sh` needs it to tell a revocation its verdict answers from one
# the verdict predates.
case_is 1 "at=" "…and says when, so two revocations are distinguishable"
# TIME ALONE IS NOT AN IDENTITY. GitHub stamps to the second, so a revocation
# REPLACED by another in the same second produced two identical records and a
# caller comparing snapshots read the second reopening as no change at all.
case_is 1 "id=" "…and carries the identity of the comment, which a second cannot"
# …AND ORDER DECIDES, both ways. A signoff after a revocation closes it again,
# which is what happens when the new pass comes back clean on the same head.
world; comments "OWNER|**Review-Signoff-Revoked:** \`$BOT\`" \
                "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" > "$TMP/out"
case_is 0 "sha=$SHA" "…and a later signoff closes it again"
# A revocation is about ONE reviewer, like the signoff it revokes.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" \
                "OWNER|**Review-Signoff-Revoked:** \`$OTHER\`" > "$TMP/out"
case_is 0 "sha=$SHA" "…and revoking Copilot's does not revoke Codex's"
# It obeys the same authorship rule: reopening a phase is as consequential as
# closing one.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" \
                "NONE|**Review-Signoff-Revoked:** \`$BOT\`" > "$TMP/out"
case_is 0 "sha=$SHA" "…and a passer-by cannot revoke one"

# ── failing to ask is not "none" ───────────────────────────────────────────
# This is the whole reason for a separate status. Treating an unreadable answer
# as "no signoff" merely costs a round; treating it as a signoff would skip a
# review phase on a commit nobody approved.
world; printf '1' > "$TMP/rc"; : > "$TMP/out"
case_is 2 "unreadable" "a failed query is an error, never 'none'"
world; printf '{"errors":[{"message":"x"}],"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' > "$TMP/out"
case_is 2 "unreadable" "…and a 200 carrying errors is not an answer"
world; printf '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":"lots"}}}}}' > "$TMP/out"
case_is 2 "unreadable" "…nor a malformed node list"

# ── THE RECORD DOES NOT EXPIRE AFTER A HUNDRED COMMENTS ────────────────────
# `comments(last:100)` loses the marker as soon as a long review loop posts past
# it — and this repository has PRs well past a hundred. A durable record that
# vanishes after a hundred comments is not durable, so the walk is paginated.
# Here the signoff is on page ONE and the summaries that buried it on page two.
page() {   # page <hasNext> <endCursor> <assoc>|<body> …
    local has="$1" cur="$2" nodes="" spec assoc body
    shift 2
    for spec in "$@"; do
        assoc="${spec%%|*}"; body="${spec#*|}"
        # `createdAt` IS PART OF THE RECORD, not decoration: a signoff answers a
        # review, and the merge gate cannot tell an answer from a leftover without
        # knowing which came first. A node without one is malformed.
        _cid=$(( ${_cid:-0} + 1 ))
        nodes="$nodes$(printf '{"id":"IC_%s","authorAssociation":"%s","createdAt":"%s","body":%s},' \
            "$_cid" "$assoc" "${SIGNED_AT_FIXTURE:-2026-01-02T00:00:00Z}" "$(printf '%s' "$body" | jq -Rs .)")"
    done
    printf '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":%s,"endCursor":%s},"nodes":[%s]}}}}}' \
        "$has" "$cur" "${nodes%,}"
}
cat > "$TMP/bin/gh" <<'GHPAGE'
#!/usr/bin/env bash
# THE COUNTER DEFAULTS WHEN THE FILE IS ABSENT *OR* EMPTY. `cat` on an empty
# file succeeds with no output, so `|| echo 1` never fired and the stub looked
# for "$GH_OUT." — falling back to whatever payload the previous case left.
_i="$(cat "$GH_PAGE" 2>/dev/null)"; [ -n "$_i" ] || _i=1
printf '%s' "$((_i + 1))" > "$GH_PAGE"
# AN EXHAUSTED SCRIPT REPEATS ITS LAST PAGE, which is what a cycling API does —
# falling back to a stale payload from another case made the cursor-cycle probe
# pass because the response became unreadable, not because the cycle was caught.
if [ -f "$GH_OUT.$_i" ]; then cat "$GH_OUT.$_i"
else cat "$GH_OUT.$LAST_PAGE" 2>/dev/null || cat "$GH_OUT" 2>/dev/null; fi
exit "$(cat "$GH_RC" 2>/dev/null || echo 0)"
GHPAGE
chmod +x "$TMP/bin/gh"
world; rm -f "$TMP/page"
# THE MARKER IS ON PAGE TWO. With it on page one the case passed against a walk
# that stops after the first page, which is the defect it exists to catch.
page true '"c1"' "OWNER|round 13 summary" > "$TMP/out.1"
page false 'null' "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" > "$TMP/out.2"
got="$(run_limited 15 env PATH="$TMP/bin:$PATH" GH_OUT="$TMP/out" GH_RC="$TMP/rc" \
    GH_PAGE="$TMP/page" LAST_PAGE=2 REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    "$SCRIPT" 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$got" | grep -qF "sha=$SHA"; } \
    && pass "a signoff buried under a page of later comments is still found" \
    || die "the walk stopped at one page (rc=$rc '$got')"
# A CURSOR CYCLE STOPS RATHER THAN HANGING. A stale page can claim another page
# while handing back a cursor already used; a gate that never answers is worse
# than one that refuses.
world; rm -f "$TMP/page"
page true '"c1"' "OWNER|one" > "$TMP/out.1"
page true '"c1"' "OWNER|two" > "$TMP/out.2"
got="$(run_limited 15 env PATH="$TMP/bin:$PATH" GH_OUT="$TMP/out" GH_RC="$TMP/rc" \
    GH_PAGE="$TMP/page" LAST_PAGE=2 REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    "$SCRIPT" 7 "$BOT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
    && pass "…and a repeated cursor is an error rather than a loop" \
    || die "a cursor cycle gave rc=$rc '$got'"
rm -f "$TMP/out.1" "$TMP/out.2"
cat > "$TMP/bin/gh" <<'GHSH'
#!/usr/bin/env bash
cat "$GH_OUT" 2>/dev/null
exit "$(cat "$GH_RC" 2>/dev/null || echo 0)"
GHSH
chmod +x "$TMP/bin/gh"

# ── the arguments ──────────────────────────────────────────────────────────
world; comments "OWNER|x" > "$TMP/out"
got="$(run_limited 15 env PATH="$TMP/bin:$PATH" GH_OUT="$TMP/out" GH_RC="$TMP/rc" \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" seven "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$got" | grep -q usage; } \
    && pass "a non-numeric PR is refused" \
    || die "a non-numeric PR gave rc=$rc '$got'"
got="$(run_limited 15 env PATH="$TMP/bin:$PATH" GH_OUT="$TMP/out" GH_RC="$TMP/rc" \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" 7 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$got" | grep -q usage; } \
    && pass "…and a missing reviewer" \
    || die "a missing reviewer gave rc=$rc '$got'"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
