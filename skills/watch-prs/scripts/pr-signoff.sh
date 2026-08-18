#!/usr/bin/env -S bash -p
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
# …and a phase can be REOPENED, which needs a record of its own:
#
#     **Review-Signoff-Revoked:** `chatgpt-codex-connector[bot]`
#
# Both are scanned together so their ORDER decides. Without the second, choosing
# "another Codex pass" on an unchanged head left the old signoff standing and a
# resumed session read the deliberately reopened phase as closed.
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
# ── STARTED PRIVILEGED, OR NOT STARTED ─────────────────────────────────────
#
# The shebang above is `env -S bash -p`, and that is the defence this block
# exists to state. An ordinary `#!/usr/bin/env bash` SOURCES `BASH_ENV`, IMPORTS
# functions from the environment, and honours an exported `SHELLOPTS` — so every
# builtin this script uses is a name the operator's shell can replace, and each
# one found took a review round of its own: `type`, `return`, `set`, `echo`,
# `exit`. Privileged mode does none of the three, so there is nothing to shadow
# and nothing to clear. Measured: under `BASH_FUNC_echo%` and `BASH_FUNC_set%`,
# a privileged shell reports both as builtins.
#
# THE HOOK CANNOT BE OUT-RUN FROM IN HERE, which is why this is the shebang and
# not a re-exec. A `BASH_ENV` hook runs before this file's first line, and one
# that prints a forged `PR_SIGNOFF status=error` line and exits has already answered the
# caller — no later re-exec takes that back. The interpreter has to be privileged
# from the start, which only the shebang or the caller can arrange.
#
# `$-` IS THE GUARD because it is shell state a hook cannot write, and it is not
# belt-and-braces for the shebang: an `env` without `-S` fails loudly, but a
# caller that runs this file through its own interpreter — `bash pr-x.sh` —
# skips the shebang entirely, and this is what stops that being a silent
# downgrade to an unprotected shell.
if [[ $- != *p* ]]; then
    echo "PR_SIGNOFF status=error reason=not_privileged" >&2
    exit 2
fi

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
#
# PAGINATED, because `comments(last:100)` loses the record it exists to find. A
# hundred comments after a signoff is an ordinary long review loop — this
# repository has PRs well past it — and the marker then falls off the window,
# `sha=none` comes back, and a resumed session either repeats a finished phase or
# cannot finish one. A durable record that expires after a hundred comments is not
# durable.
#
# The walk is the merge gate's, for the same reasons: every cursor already
# requested is remembered so a cycle of any length stops rather than hanging, and
# any incomplete traversal is an ERROR rather than the answer so far.
SHA=""; SIGNED_AT=""; CURSOR=null; RS=$(printf '\036'); SEEN="${RS}null${RS}"; OK=1
while :; do
    PAGE=$(gh api --hostname "$HOST" graphql -F number="$PR" -f owner="$OWNER" -f repo="$REPO" \
        -F cursor="$CURSOR" -f query='query($owner:String!,$repo:String!,$number:Int!,$cursor:String){
          repository(owner:$owner,name:$repo){ pullRequest(number:$number){
            comments(first:100, after:$cursor){ pageInfo{hasNextPage endCursor}
              nodes{ body authorAssociation createdAt } }}}}' 2>/dev/null) || { OK=0; break; }
    # A 200 CAN CARRY BOTH `errors` AND A STRUCTURALLY VALID `data`. The partial
    # data passes every shape check below while omitting comments, and the answer
    # taken from it would be "no signoff" — which is the safe direction only until
    # somebody uses it to decide a phase was never finished.
    printf '%s' "$PAGE" | jq -e 'has("errors") | not' >/dev/null 2>&1 || { OK=0; break; }
    # EVERY NODE IS VALIDATED BEFORE ANY IS FILTERED. Discarding a malformed node
    # silently turns "this response is not trustworthy" into "there is no signoff",
    # and those are the two answers this helper exists to keep apart. A node
    # without a string body, or without a readable association, means the response
    # could not be read — status 2 — not that the record is absent.
    FOUND=$(printf '%s' "$PAGE" | jq -r --arg who "$WHO" "$RECORDLIB_JQ"'
        .data.repository.pullRequest.comments.nodes as $n
        | if ($n | type) != "array"
             or any($n[]; type != "object"
                          or (.body | type) != "string"
                          or (.authorAssociation | type) != "string"
                          # WHEN the record was made. A signoff answers a review,
                          # and a merge gate cannot tell an answer from a leftover
                          # without knowing which came first — so a comment with no
                          # timestamp is a malformed record here, not one with an
                          # unknown date.
                          or ((.createdAt | canonical_utc) | not))
          then error("malformed nodes")
          else [ $n[]
                 | select(.authorAssociation | IN("OWNER","MEMBER","COLLABORATOR"))
                 | .createdAt as $c
                 # ANCHORED AT BOTH ENDS. A marker with prose after it — "…is the
                 # format we use" — is documentation, not a signoff, and a
                 # start-anchored pattern accepted it. The line must BE the record.
                 # BOTH MARKERS, IN ONE SCAN, so their ORDER decides. A phase
                 # that is deliberately reopened — "another Codex pass" on an
                 # unchanged head — leaves the old signoff standing, and a resumed
                 # session would read the reopened phase as closed. A revocation
                 # is a record too, and the last record wins.
                 | (.body | [scan("(?m)^\\*\\*Review-Signoff(-Revoked)?:\\*\\* `([^`\n]{1,200})`(?: `([0-9a-f]{40})`)?[[:space:]]*$")]
                          | last // ["","",""])
                 | select(.[1] == $who)
                 # A revocation carries no sha and a signoff must; anything else
                 # is a malformed line rather than either.
                 | . as $m
                 | if $m[0] != null then "REVOKED\t" + $c
                   elif ($m[2] | type) == "string" then $m[2] + "\t" + $c
                   else empty end
               ] | last // ""
          end') || { OK=0; break; }
    # THE LAST RECORD ANYWHERE WINS, so a later page supersedes an earlier one and
    # a phase can be reopened by saying so.
    # `<sha-or-REVOKED>\t<createdAt>`; the timestamp travels with the record so the
    # caller never has to guess which of two comments it is holding.
    [ -n "$FOUND" ] && { SHA="${FOUND%%$'\t'*}"; SIGNED_AT="${FOUND#*$'\t'}"; }
    HAS_NEXT=$(printf '%s' "$PAGE" | jq -r '.data.repository.pullRequest.comments.pageInfo.hasNextPage') || { OK=0; break; }
    case "$HAS_NEXT" in
        false) break ;;
        true)  ;;
        *) OK=0; break ;;
    esac
    NEXT=$(printf '%s' "$PAGE" | jq -r '.data.repository.pullRequest.comments.pageInfo.endCursor') || { OK=0; break; }
    { [ -n "$NEXT" ] && [ "$NEXT" != "null" ]; } || { OK=0; break; }
    case "$SEEN" in *"$RS$NEXT$RS"*) OK=0; break ;; esac
    SEEN="$SEEN$NEXT$RS"
    CURSOR="$NEXT"
done
if [ "$OK" -ne 1 ]; then
    echo "PR_SIGNOFF pr=$PR reviewer=$WHO status=error reason=unreadable" >&2
    exit 2
fi
# EMPTY IS "NONE", AND NONE IS NOT AN ERROR — but it is also not a signoff, and
# the caller must not be able to confuse the two. The status carries that: 1 says
# "asked and answered, there is none", 2 says "could not ask".
# A REVOCATION IS AN ANSWER, and the answer is "no signoff". It is reported as
# such rather than as an error: the phase is open, which is a fact about the PR
# and not a failure to read it.
if [ "$SHA" = REVOKED ]; then
    echo "PR_SIGNOFF pr=$PR reviewer=$WHO sha=none reason=revoked"
    exit 1
fi
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
# `at=` COMES BEFORE `sha=`, and that is not cosmetic: every caller reads the sha
# with `${line##*sha=}`, so a field appended after it would be swallowed into the
# value and the gate would compare a sha against a sha-plus-timestamp.
echo "PR_SIGNOFF pr=$PR reviewer=$WHO at=$SIGNED_AT sha=$SHA"
exit 0
