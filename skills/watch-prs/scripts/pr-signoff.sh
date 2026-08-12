#!/usr/bin/env bash
# Which head has a reviewer signed off clean on, according to the PR itself?
#
#   pr-signoff.sh <pr> <reviewer-login>
#
#   0  a signoff was found — `PR_SIGNOFF … sha=<40-hex>` on stdout
#   1  none recorded — `PR_SIGNOFF … sha=none`. Not an error: most PRs, most days
#   2  could not be established — fail closed, do NOT treat as "none"
#
# WHY THIS EXISTS
#
# The driver captured the Codex-signed head in a shell variable and PRINTED it to
# the operator's terminal. Nothing wrote it down. So the one fact the whole
# phasing rests on — "Codex is clean on this exact commit" — lived only in a
# session: close the terminal, move to another machine, come back tomorrow, and
# the loop has no way to know the Codex phase is finished. It would re-request a
# review it already has, or worse, treat the current head as the reviewed one.
#
# That is the v1 mistake this repository already records: the round counter lived
# in a `/tmp` file, so the pause it promised disappeared whenever the file did.
# A guarantee that only holds while a process survives is not a guarantee.
#
# SO THE RECORD LIVES ON THE PULL REQUEST, in a comment, in the same shape the
# round-count acknowledgement uses:
#
#     **Review-Signoff:** `chatgpt-codex-connector[bot]` `<40-hex sha>`
#
# It is repo-local, survives machines and sessions, is readable by a human
# scrolling the thread, and can be revoked by posting a newer one. `SKILL.md`
# writes it when a phase closes; this reads it back.
#
# ONLY THE REPOSITORY'S OWN PEOPLE MAY WRITE ONE. The association is checked
# exactly as the acknowledgement's is: a signoff is permission to skip a review
# phase, so a comment from a passer-by must not grant it.
#
# `set -uo pipefail`, NOT `-e`: `gh` probes fail as normal operation and the
# result is control flow. See CLAUDE.md § Bash conventions.
set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_SIGNOFF status=error reason=lib_dir_unresolvable" >&2; exit 2; }
unset -f rb_load 2>/dev/null || {
    echo "PR_SIGNOFF status=error reason=loadlib_stale_definition" >&2; exit 2; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_SIGNOFF status=error reason=loadlib_unreadable" >&2; exit 2; }
[ "$(type -t rb_load 2>/dev/null)" = function ] || {
    echo "PR_SIGNOFF status=error reason=loadlib_empty" >&2; exit 2; }
rb_load "$_RB_SELF_DIR" recordlib sha_reason "PR_SIGNOFF status=error" || exit 2
rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_SIGNOFF status=error" || exit 2
rb_identity || { echo "PR_SIGNOFF status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }

PR="${1:-}"; WHO="${2:-}"
case "$PR" in
    ""|*[!0-9]*) echo "usage: $0 <pr> <reviewer-login>" >&2; exit 2 ;;
esac
[ -n "$WHO" ] || { echo "usage: $0 <pr> <reviewer-login>" >&2; exit 2; }

# THE LOGIN IS MATCHED AS A STRING, never interpolated into a pattern. These are
# `…[bot]` logins, where `[` and `]` are regex metacharacters that would silently
# match something else entirely — the same rule the round counter records.
SHA=$(gh api --hostname "$HOST" graphql -F number="$PR" -f owner="$OWNER" -f repo="$REPO" \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){
      pullRequest(number:$number){ comments(last:100){ nodes{ body authorAssociation } } }}}' 2>/dev/null \
    | jq -r --arg who "$WHO" '
        if has("errors") then error("graphql errors") else . end
        | .data.repository.pullRequest.comments.nodes as $all
        | if ($all | type) != "array" then error("malformed comments") else
          [ $all[]
            | select((.authorAssociation | type) == "string")
            | select(.authorAssociation | IN("OWNER","MEMBER","COLLABORATOR"))
            | select((.body | type) == "string")
            # ANCHORED, AND THE LAST ONE WINS. A field-shaped line quoted inside
            # prose — the documentation in this very file, pasted into a comment —
            # must not be read as a signoff nobody made, and a later record
            # supersedes an earlier one so a phase can be reopened by saying so.
            | (.body | [scan("(?m)^\\*\\*Review-Signoff:\\*\\* `([^`\n]{1,200})` `([0-9a-f]{40})`")]
                     | last // ["",""])
            | select(.[0] == $who)
          ] | map(.[1]) | last // ""
          end' 2>/dev/null) || {
    echo "PR_SIGNOFF pr=$PR reviewer=$WHO status=error reason=unreadable" >&2
    exit 2
}
# EMPTY IS "NONE", AND NONE IS NOT AN ERROR — but it is also not a signoff, and
# the caller must not be able to confuse the two. The status carries that: 1 says
# "asked and answered, there is none", 2 says "could not ask".
if [ -z "$SHA" ]; then
    echo "PR_SIGNOFF pr=$PR reviewer=$WHO sha=none"
    exit 1
fi
# THROUGH `sha_reason`, like everything else that asks what a commit is. The jq
# pattern already demands 40 hex, so this cannot currently fail — which is the
# point: if that pattern is ever loosened, the shape rule is still enforced in
# the one place it is defined, rather than silently becoming whatever the regex
# now admits.
_why="$(sha_reason "$SHA")" || {
    echo "PR_SIGNOFF pr=$PR reviewer=$WHO status=error reason=$_why sha=$SHA" >&2
    exit 2; }
echo "PR_SIGNOFF pr=$PR reviewer=$WHO sha=$SHA"
exit 0
