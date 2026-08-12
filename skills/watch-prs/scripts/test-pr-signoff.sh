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
        nodes="$nodes$(printf '{"authorAssociation":"%s","body":%s},' \
            "$assoc" "$(printf '%s' "$body" | jq -Rs .)")"
    done
    printf '{"data":{"repository":{"pullRequest":{"comments":{"nodes":[%s]}}}}}' "${nodes%,}"
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

# ── the LAST one wins, so a phase can be reopened ──────────────────────────
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$OLD\`" \
                "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" > "$TMP/out"
case_is 0 "sha=$SHA" "a later signoff supersedes an earlier one"

# ── failing to ask is not "none" ───────────────────────────────────────────
# This is the whole reason for a separate status. Treating an unreadable answer
# as "no signoff" merely costs a round; treating it as a signoff would skip a
# review phase on a commit nobody approved.
world; printf '1' > "$TMP/rc"; : > "$TMP/out"
case_is 2 "unreadable" "a failed query is an error, never 'none'"
world; printf '{"errors":[{"message":"x"}],"data":{"repository":{"pullRequest":{"comments":{"nodes":[]}}}}}' > "$TMP/out"
case_is 2 "unreadable" "…and a 200 carrying errors is not an answer"
world; printf '{"data":{"repository":{"pullRequest":{"comments":{"nodes":"lots"}}}}}' > "$TMP/out"
case_is 2 "unreadable" "…nor a malformed node list"

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
