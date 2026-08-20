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
        # `databaseId` TOO, and for the same reason one step finer: `createdAt` is
        # second-resolution, so two records made in the same second compare equal
        # and a caller ordering a revocation against a verdict cannot tell which
        # came first. The id breaks that tie, and it counts up, so a later node in
        # this list is a later record. #117.
        _cid=$(( ${_cid:-100} + 1 ))
        nodes="$nodes$(printf '{"authorAssociation":"%s","createdAt":"%s","databaseId":%s,"body":%s},' \
            "$assoc" "${SIGNED_AT_FIXTURE:-2026-01-02T00:00:00Z}" "$_cid" "$(printf '%s' "$body" | jq -Rs .)")"
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
# ── A SIGNOFF STANDS ONLY IF NO REVOCATION IS NEWER THAN ITS VERDICT ───────
# Position alone says the last record wins, which is why a revocation landing
# while `record` was proving is superseded by the signoff written next — the
# signoff is posted AFTER it. The writer cannot close that window, because its own
# write erases the evidence. The record says which verdict it answers, so time can
# decide instead. #140, closing #122.
world; comments "OWNER|**Review-Signoff-Revoked:** \`$BOT\`" \
                "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\` \`2026-01-01T00:00:00Z\`" > "$TMP/out"
case_is 1 "reason=revoked" "a revocation newer than the verdict reopens the phase, though a signoff followed it"
# AND THE RECORD PRINTED IS THE REVOCATION'S, id included: callers order records
# against each other by exactly those fields, so naming the signoff's comment
# would point at one that is not being acted on.
case_is 1 "id=101" "…and the record it prints is the revocation's, not the signoff's"
# AND ONE OLDER THAN THE VERDICT IS THE PASS THIS SIGNOFF IS ANSWERING. The
# fault-tolerance pass posts its revocation BEFORE requesting the review, so that
# record is older than the verdict that comes back — refusing there would stop a
# reopened phase recording its replacement signoff at all.
world; comments "OWNER|**Review-Signoff-Revoked:** \`$BOT\`" \
                "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\` \`2026-02-02T00:00:00Z\`" > "$TMP/out"
case_is 0 "sha=$SHA" "…while one older than the verdict is the pass it answers, and the signoff stands"
# EQUAL CANNOT BE ORDERED, so position decides — which is the answer that existed
# before this rule.
world; comments "OWNER|**Review-Signoff-Revoked:** \`$BOT\`" \
                "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\` \`2026-01-02T00:00:00Z\`" > "$TMP/out"
case_is 0 "sha=$SHA" "…and one made in the same second falls back to position"
# A SIGNOFF WITH NO VERDICT TIME KEEPS TODAY'S RULE EXACTLY. Every record written
# before #137 is one, and inventing an answer would be worse than position.
world; comments "OWNER|**Review-Signoff-Revoked:** \`$BOT\`" \
                "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" > "$TMP/out"
case_is 0 "sha=$SHA" "…and a signoff carrying no verdict time is decided by position, as before"
# THE NEWEST REVOCATION IS THE ONE COMPARED, even where an older one sits under it.
world; comments "OWNER|**Review-Signoff-Revoked:** \`$BOT\`" \
                "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\` \`2026-01-01T00:00:00Z\`" \
                "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\` \`2026-01-01T00:00:00Z\`" > "$TMP/out"
case_is 1 "reason=revoked" "…and a revocation under two signoffs still reopens the phase"

# ── a signoff is found ─────────────────────────────────────────────────────
# THE VERDICT TIME THE SIGNOFF ANSWERS, as a THIRD backticked field. Readers take
# the LAST record, so a revocation posted after a signoff supersedes it whatever
# it was about — and the writer cannot close that window, because its own write is
# what erases the evidence. A signoff saying WHICH verdict it answers lets a
# reader order a revocation against that rather than against comment order. #135,
# for #122.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\` \`2026-01-01T00:00:00Z\`" > "$TMP/out"
case_is 0 "verdict-at=2026-01-01T00:00:00Z" "a signoff carrying the verdict time reports it"
case_is 0 "sha=$SHA" "…and still reports the sha it signs off"
# OPTIONAL, BECAUSE EVERY EXISTING RECORD PREDATES IT. A reader that required it
# would report every signoff on every open PR as malformed, which is the
# fail-closed direction turned into a denial of service.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" > "$TMP/out"
case_is 0 "verdict-at=none" "…and one without it says so rather than being malformed"
# A VALUE THAT IS NOT A TIME IS NEITHER. A reader ordering a revocation against it
# would place that revocation somewhere arbitrary, and the low end of arbitrary is
# "the revocation is older", which is the answer that records over a reopening.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\` \`whenever\`" > "$TMP/out"
case_is 2 "reason=bad_verdict_at" "…while one that is not a time is refused, not compared"
# THE FIELD ORDER SURVIVES THE TWO PEELS EVERY CALLER USES: the sha is read with
# `${line##*sha=}` and the record time with `${line#* at=}`, and `verdict-at=`
# must be mistakeable for neither. The character before those three letters is a
# hyphen rather than a space, which is what keeps the second one honest.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\` \`2026-01-01T00:00:00Z\`" > "$TMP/out"
got="$(run "$BOT")"; line="${got#*|}"
[ "${line##*sha=}" = "$SHA" ] \
    && pass "…and the sha still peels off the end cleanly" \
    || die "the sha peel took '${line##*sha=}'"
# ASSERTED AS AN EQUALITY, not as "it is not the verdict time": if the record ever
# loses its space-delimited ` at=` field, that peel returns the WHOLE line and
# `%% *` reduces it to `PR_SIGNOFF` — which is also not the verdict time, so an
# inequality passes while the ordering `pr-copilot-phase.sh` depends on is broken.
_at="${line#* at=}"; _at="${_at%% *}"
[ "$_at" = 2026-01-02T00:00:00Z ] \
    && pass "…and the record time peel takes the record time, not the verdict time" \
    || die "'\${line#* at=}' took '$_at'"
# A REVOCATION CARRIES IT TOO, since a phase reopened by one is a record a reader
# has to place in time exactly as it places a signoff — and it CARRIES NO SHA, so its verdict time is the SECOND backticked field
# rather than the third — the sha group is optional and a time is not 40 hex, so
# the pattern falls through to the field that holds one.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" \
                "OWNER|**Review-Signoff-Revoked:** \`$BOT\` \`2026-02-02T00:00:00Z\`" > "$TMP/out"
case_is 1 "reason=revoked" "a revocation is still a revocation with a verdict time on it"
case_is 1 "verdict-at=2026-02-02T00:00:00Z" "…and reports the verdict time it carries"
# AN OVERLONG VALUE MUST BE VISIBLE IN ORDER TO BE REFUSED. Bounded, the field
# makes the WHOLE marker fail to match — the line then matches nothing, `last`
# returns an OLDER record, and a deliberately reopened phase reads as closed.
# `seq` IS ABSENT ON STOCK macOS, and this file runs without `-e`: a failed inner
# substitution leaves `printf` with no operands and produces a SINGLE `x`, so the
# case still gets `bad_verdict_at` while exercising nothing. `%065d` needs no
# command at all, and the length is asserted rather than assumed.
_long="$(printf '%065d' 0 | tr 0 x)"
[ "${#_long}" -eq 65 ] \
    && pass "the overlong fixture is actually longer than the bound it tests" \
    || die "the overlong fixture is ${#_long} characters, not 65"
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" \
                "OWNER|**Review-Signoff-Revoked:** \`$BOT\` \`$_long\`" > "$TMP/out"
case_is 2 "reason=bad_verdict_at" "…and an overlong verdict time is refused, not skipped past"
# AN EMPTY VALUE IS THE SAME DEFECT AT THE OTHER END. A minimum in the capture
# makes it fail the whole marker, so `last` returns the older signoff and the
# reopened phase reads as closed.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" \
                "OWNER|**Review-Signoff-Revoked:** \`$BOT\` \`\`" > "$TMP/out"
case_is 2 "reason=bad_verdict_at" "…and so is an empty one"
# A SIGNOFF WITHOUT A SHA is a record that failed to parse, not one to look past.
# The sha capture demands 40 hex, so a value in that position which is not one
# lands in the verdict field instead — and discarded, the marker stops being the
# newest record and an OLDER signoff is returned with status 0.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" \
                "OWNER|**Review-Signoff:** \`$BOT\` \`2026-01-02T00:00:00Z\`" > "$TMP/out"
case_is 2 "reason=signoff_without_sha" "a signoff with no sha is refused, not skipped past"
# AND A VALUE THERE THAT IS FORTY LOWERCASE HEX is captured as the optional SHA
# rather than as the time, and the revocation branch ignores a sha — so the record
# would read as one carrying no time at all, and a present but unplaceable value
# would be accepted as a legacy record.
world; comments "OWNER|**Review-Signoff-Revoked:** \`$BOT\` \`$SHA\`" > "$TMP/out"
case_is 2 "reason=bad_verdict_at" "…while a revocation carrying a sha-shaped value is refused"
# THE CHECK RUNS BEFORE EITHER EARLY RETURN. `sha` mode handed the head back with
# status 0, so `SKILL.md` and `pr-phase-state.sh` read a malformed record as a
# closed phase; a revocation exited 1 as an ordinary one.
# `sha` MODE IS ASSERTED FURTHER DOWN, where its runner is defined.


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
world; printf '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"authorAssociation":"OWNER","createdAt":"2026-01-02T00:00:00Z","databaseId":1,"body":7}]}}}}}' > "$TMP/out"
case_is 2 "unreadable" "…and so is a body that is not a string"
world; printf '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"authorAssociation":null,"createdAt":"2026-01-02T00:00:00Z","databaseId":1,"body":"x"}]}}}}}' > "$TMP/out"
case_is 2 "unreadable" "…and an association that is not a string"
# …AND A NODE WITH EVERY OTHER FIELD BUT NO USABLE `databaseId`. The `{}` case
# above already fails several older checks, so it says nothing about this one:
# removing the id rule left the suite green. A record that cannot be ORDERED is
# not a record this tool can act on — a revocation has to be placed against a
# verdict, and `createdAt` alone is second-resolution. #117.
world; printf '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"authorAssociation":"OWNER","createdAt":"2026-01-02T00:00:00Z","body":"x"}]}}}}}' > "$TMP/out"
case_is 2 "unreadable" "…and a node carrying everything but an id cannot be ordered"
world; printf '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"authorAssociation":"OWNER","createdAt":"2026-01-02T00:00:00Z","databaseId":"9001","body":"x"}]}}}}}' > "$TMP/out"
case_is 2 "unreadable" "…nor one whose id is a string rather than a number"

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
# …AND IT CARRIES ITS TIME AND ITS ID, exactly as a signoff does. Without them a
# caller cannot ORDER it: the fault-tolerance pass posts a revocation BEFORE
# requesting its review, so that revocation is newest when the clean verdict
# arrives and the pass is ANSWERING it; another session reopening the phase posts
# one AFTER the verdict, and that one CANCELS it. The two read identically until
# the record says when. Omitting `at=` also made two revocations compare equal, so
# one replaced by another could not be told from the original. #117.
case_is 1 "at=" "…and says when it was made, so it can be ordered against a verdict"
case_is 1 "id=" "…and which comment it is, since createdAt is second-resolution"
# THE FIELD ORDER MATTERS, and it is not cosmetic: every caller reads the sha with
# a suffix expansion on `sha=`, so a field appended after it is swallowed into the
# value and a gate compares a sha against a sha-plus-something.
got="$(run "$BOT")"; _body="${got#*|}"
case "$_body" in
    *at=*id=*sha=*) pass "…with at= and id= before sha=, where a suffix read cannot swallow them" ;;
    *) die "the revocation's fields are ordered so a suffix read would swallow one: '$_body'" ;;
esac
# AND A SIGNOFF CARRIES THE SAME TWO, or ordering one against the other compares a
# record that has them with one that does not.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" > "$TMP/out"
got="$(run "$BOT")"; _body="${got#*|}"
case "$_body" in
    *at=*id=*sha="$SHA"*) pass "…and a signoff carries both as well, in the same order" ;;
    *) die "a signoff is missing a field the revocation has: '$_body'" ;;
esac
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" \
                "OWNER|**Review-Signoff-Revoked:** \`$BOT\`" > "$TMP/out"
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
        # `databaseId` TOO, and for the same reason one step finer: `createdAt` is
        # second-resolution, so two records made in the same second compare equal
        # and a caller ordering a revocation against a verdict cannot tell which
        # came first. The id breaks that tie, and it counts up, so a later node in
        # this list is a later record. #117.
        _cid=$(( ${_cid:-100} + 1 ))
        nodes="$nodes$(printf '{"authorAssociation":"%s","createdAt":"%s","databaseId":%s,"body":%s},' \
            "$assoc" "${SIGNED_AT_FIXTURE:-2026-01-02T00:00:00Z}" "$_cid" "$(printf '%s' "$body" | jq -Rs .)")"
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

# ── `sha` ANSWERS WITH THE HEAD ALONE ──────────────────────────────────────
#
# It exists so no caller has to parse the record line: `SKILL.md` did it in three
# places and two shapes, one of them ~90 lines of expansion-only code and two of
# them a `sed` — a NAME, and one that prints a plausible forty hex and exits 0
# pins a merge to whatever it says.
#
# THE TWO STREAMS ARE SEPARATE, which is what makes an empty answer safe: stdout
# carries the sha or nothing, every reason goes to stderr, so a caller reads one
# and never sees the other.
sha_run() {   # sha_run [reviewer] ; prints "<rc>|<stdout>|<stderr>"
    local rc=0 o e
    o="$(run_limited 15 env PATH="$TMP/bin:$PATH" GH_OUT="$TMP/out" GH_RC="$TMP/rc" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" sha 7 "${1:-$BOT}" 2>"$TMP/sha.err")" || rc=$?
    e="$(cat "$TMP/sha.err" 2>/dev/null)"
    printf '%s|%s|%s' "$rc" "$o" "$e"
}
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" > "$TMP/out"
got="$(sha_run)"
{ [ "${got%%|*}" = 0 ] && [ "$(printf '%s' "$got" | cut -d'|' -f2)" = "$SHA" ]; } \
    && pass "sha prints the recorded head and nothing else" \
    || die "sha gave '$got'"
# AND IT REFUSES AN UNREADABLE VERDICT TIME, which the check must run BEFORE this
# mode returns: handing the head back with status 0 makes `SKILL.md` and
# `pr-phase-state.sh` read a malformed record as a closed phase.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\` \`whenever\`" > "$TMP/out"
got="$(sha_run)"
{ [ "${got%%|*}" = 2 ] && printf '%s' "$got" | cut -d'|' -f3 | grep -qF 'reason=bad_verdict_at'; } \
    && pass "…and refuses a record whose verdict time is not a time" \
    || die "sha accepted a malformed verdict time: '$got'"
[ -z "$(printf '%s' "$got" | cut -d'|' -f2)" ] \
    && pass "…printing no head at all" \
    || die "sha printed a head for a malformed record: '$got'"
# NOTHING OF THE RECORD SHAPE REACHES STDOUT, or a caller shape-checking the
# result would still be parsing a line — which is the whole point of the mode.
case "$(printf '%s' "$got" | cut -d'|' -f2)" in
    *PR_SIGNOFF*|*reviewer=*|*sha=*) die "the record's own shape reached stdout in sha mode ('$got')" ;;
    *) pass "…with no field name, login or record prefix on that stream" ;;
esac
# NONE IS NOT A VALUE, so it goes to stderr. A caller that captured
# `PR_SIGNOFF … sha=none` on stdout would hold a non-empty string that is not a
# sha — the ordinary-looking wrong answer the fail-closed rule exists to prevent.
world; comments "OWNER|nothing to see here" > "$TMP/out"
got="$(sha_run)"
{ [ "${got%%|*}" = 1 ] && [ -z "$(printf '%s' "$got" | cut -d'|' -f2)" ]; } \
    && pass "…and with none recorded stdout is empty, with status 1" \
    || die "sha printed something with no signoff recorded ('$got')"
case "$(printf '%s' "$got" | cut -d'|' -f3)" in
    *sha=none*) pass "…while the reason is on stderr, where the caller is not reading" ;;
    *) die "the 'none' answer was not reported at all ('$got')" ;;
esac
# A REVOCATION IS THE SAME ANSWER by a different route, and must not differ here.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" "OWNER|**Review-Signoff-Revoked:** \`$BOT\`" > "$TMP/out"
got="$(sha_run)"
{ [ "${got%%|*}" = 1 ] && [ -z "$(printf '%s' "$got" | cut -d'|' -f2)" ]; } \
    && pass "…and a revoked signoff answers the same way" \
    || die "a revoked signoff printed a sha ('$got')"
# AN UNREADABLE ANSWER IS 2 AND STILL PRINTS NOTHING, so a caller cannot read a
# failure as an answer on either stream.
printf '1' > "$TMP/rc"; : > "$TMP/out"
got="$(sha_run)"
{ [ "${got%%|*}" = 2 ] && [ -z "$(printf '%s' "$got" | cut -d'|' -f2)" ]; } \
    && pass "…and an unreadable API leaves stdout empty with status 2" \
    || die "an unreadable API produced output on stdout ('$got')"
# THE DEFAULT SHAPE IS UNCHANGED, which the resume path's abort messages and
# `test-pr-skill-contract.sh` both depend on.
world; comments "OWNER|**Review-Signoff:** \`$BOT\` \`$SHA\`" > "$TMP/out"
case_is 0 "PR_SIGNOFF pr=7 reviewer=$BOT" "…while the default mode still prints the whole record"
# AND AN UNKNOWN SUBCOMMAND IS REFUSED rather than silently taken as a mode: it
# lands in the PR argument, which is validated as digits.
got="$(run_limited 15 env PATH="$TMP/bin:$PATH" GH_OUT="$TMP/out" GH_RC="$TMP/rc" \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' "$SCRIPT" head 7 "$BOT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$got" | grep -q usage; } \
    && pass "…and an unknown subcommand is refused" \
    || die "an unknown subcommand gave rc=$rc '$got'"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
