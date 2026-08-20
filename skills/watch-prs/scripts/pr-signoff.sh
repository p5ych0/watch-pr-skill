#!/usr/bin/env -S bash -p
# Which head has a reviewer signed off clean on, according to the PR itself?
#
#   pr-signoff.sh <pr> <reviewer-login>
#   pr-signoff.sh sha <pr> <reviewer-login>
#
#   0  a signoff was found — `PR_SIGNOFF … sha=<40-hex>` on stdout
#   1  none recorded — `PR_SIGNOFF … sha=none`. Not an error: most PRs, most days
#   2  could not be established — fail closed, do NOT treat as "none"
#
# `sha` ANSWERS WITH THE HEAD ALONE, and it exists so that no caller has to parse
# this line. `SKILL.md` extracted a signed-off head from a record in three places
# and two shapes: ~90 lines of expansion-only code against
# `PR_PHASE_RECORDED … codex-sha=`, whose every line was paid for over nine
# rounds of #74, and twice `sed -n 's/^PR_SIGNOFF .*sha=\([0-9a-f]\{40\}\)$/\1/p'`
# — and `sed` is a NAME, so one that prints a plausible forty hex and exits 0
# pins a merge to whatever it says. Converging those inline would have put three
# copies of a parser in a Markdown file, none of them reachable by this suite.
#
# IN THAT MODE STDOUT CARRIES THE SHA OR NOTHING. Every reason goes to stderr, so
# a caller reads one stream and never sees the other, and an empty answer cannot
# be mistaken for a value: it is not 40 hex, and the status says why. The statuses
# are unchanged, because they are what the callers already branch on.
#
# THE DEFAULT OUTPUT IS THE WHOLE RECORD:
#
#   PR_SIGNOFF pr=<n> reviewer=<login> verdict-at=<utc|none> at=<utc> id=<n> sha=<40hex>
#
# and a revocation is the same line with `sha=none reason=revoked`. `verdict-at=`
# is the time of the VERDICT the signoff answers, and it is always present — as
# `none` where the record does not carry one, which every record written before
# #135 does not. The field order is load-bearing: callers peel the sha with
# `${line##*sha=}` and the record time with `${line#* at=}`, so nothing may follow
# the sha and nothing preceded by a SPACE may spell `at=` before the real one.
# `verdict-at=` cannot, because the character before those three letters is a
# hyphen.
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
# WHAT STARTS IT PRIVILEGED IS THE CALLER, AND THE SHEBANG IS THE FALLBACK.
# `SKILL.md` invokes every helper as `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-x.sh`,
# which starts a fresh privileged interpreter whatever the driving shell is and
# whatever that platform's `env` supports. The shebang covers the other way in —
# executing the file directly — and needs `env -S`, which is why it is not the
# thing relied on.
#
# `$-` IS A LAST-RESORT REFUSAL AND PROVES LESS THAN IT LOOKS. It reports the
# MODE this shell is in, not how it got there: run as `BASH_ENV=hook bash
# pr-x.sh`, the hook is sourced BEFORE this line and can itself run `set -p` and
# then define `echo` or `exit`, after which `$-` contains `p` and this test
# passes on a shell that has already executed hostile code. Nothing inside a
# script can detect work done before its first line — so this catches the honest
# mistake, and `bash pr-x.sh` is UNSUPPORTED rather than defended. Measured:
# `BASH_ENV=/tmp/h bash -c 'printf "%s %s" "$-" "$(type -t echo)"'` with a hook
# running `set -p; echo() { :; }` prints `hpBc function`.
if [[ $- != *p* ]]; then
    echo "PR_SIGNOFF status=error reason=not_privileged" >&2
    exit 2
fi

set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_SIGNOFF status=error reason=lib_dir_unresolvable" >&2; exit 2; }
unset -f rb_load 2>/dev/null || {
    echo "PR_SIGNOFF status=error reason=loadlib_stale_definition" >&2; exit 2; }
# NO `type -t rb_load` PREFLIGHT. It verified the loader by asking `type`, which
# is a NAME — and while a privileged interpreter means no function by that name
# can be imported, verifying a thing by asking a second thing about it is the
# shape #88 is about: the answer is only as good as the asker. The FIRST LOAD is
# the verification instead: the stub below is what an empty `loadlib.sh` leaves
# behind, and calling it fails. Nothing is asked ABOUT the loader — the load
# itself is the answer.
#
# THE REFUSING STUB IS WHAT MAKES THAT TRUE. Without it, an `rb_load` that is not
# a function is looked up on `PATH` — privileged mode does not change `PATH` —
# and an executable by that name exiting 0 would report every load successful
# with nothing cleared and no library sourced. Defining it means the call cannot
# leave this shell: a good `loadlib.sh` replaces the stub when sourced, an empty
# one leaves the refusal. `return` is a builtin and nothing can shadow it here,
# because a privileged shell imports no functions. #88.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_SIGNOFF status=error reason=loadlib_unreadable" >&2; exit 2; }
# THE FIRST LOAD CARRIES THE SENTINEL, because it is what the preflight used to
# say. An empty `loadlib.sh` leaves the stub, the stub returns 127, and without
# this arm the only trace is a bare exit status — the ordinary-looking empty
# answer `CLAUDE.md` forbids. 127 is the stub's and nothing else's: `rb_load`'s
# own refusals report their own reason and their own status.
rb_load "$_RB_SELF_DIR" recordlib sha_reason "PR_SIGNOFF status=error" || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "PR_SIGNOFF status=error reason=loadlib_empty" >&2
    exit 2; }
rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_SIGNOFF status=error" || exit 2
rb_identity || { echo "PR_SIGNOFF status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }

# THE MODE IS A LEADING WORD, and a PR number is digits, so the two cannot be
# confused. Anything else in that position is the PR argument and is validated as
# one — an unknown subcommand is therefore refused by the digits check rather
# than silently taken as a mode nobody implemented.
MODE=record
case "${1:-}" in
    sha) MODE=sha; shift ;;
esac
PR="${1:-}"; WHO="${2:-}"
case "$PR" in
    ""|*[!0-9]*) echo "usage: $0 [sha] <pr> <reviewer-login>" >&2; exit 2 ;;
esac
[ -n "$WHO" ] || { echo "usage: $0 [sha] <pr> <reviewer-login>" >&2; exit 2; }

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
SHA=""; SIGNED_AT=""; SIGNED_ID=""; VERDICT_AT=""; REVOKED_AT=""; REVOKED_ID=""; CURSOR=null; RS=$(printf '\036'); SEEN="${RS}null${RS}"; OK=1
while :; do
    PAGE=$(gh api --hostname "$HOST" graphql -F number="$PR" -f owner="$OWNER" -f repo="$REPO" \
        -F cursor="$CURSOR" -f query='query($owner:String!,$repo:String!,$number:Int!,$cursor:String){
          repository(owner:$owner,name:$repo){ pullRequest(number:$number){
            comments(first:100, after:$cursor){ pageInfo{hasNextPage endCursor}
              nodes{ body authorAssociation createdAt databaseId } }}}}' 2>/dev/null) || { OK=0; break; }
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
                          or ((.createdAt | canonical_utc) | not)
                          # AND WHICH RECORD IT IS. `createdAt` is
                          # second-resolution, so two records made in the same
                          # second compare equal; the id breaks that tie and a
                          # node without one cannot be ordered at all. #117.
                          or (.databaseId | type) != "number")
          then error("malformed nodes")
          else [ $n[]
                 | select(.authorAssociation | IN("OWNER","MEMBER","COLLABORATOR"))
                 | .createdAt as $c
                 # THE COMMENT ID TRAVELS WITH THE TIMESTAMP, because `createdAt`
                 # is second-resolution: two records posted in the same second
                 # compare equal, and a caller ordering a revocation against a
                 # verdict then cannot tell which came first. The id is unique and
                 # monotonic on this API, so it breaks that tie. #117.
                 | .databaseId as $i
                 # ANCHORED AT BOTH ENDS. A marker with prose after it — "…is the
                 # format we use" — is documentation, not a signoff, and a
                 # start-anchored pattern accepted it. The line must BE the record.
                 # BOTH MARKERS, IN ONE SCAN, so their ORDER decides. A phase
                 # that is deliberately reopened — "another Codex pass" on an
                 # unchanged head — leaves the old signoff standing, and a resumed
                 # session would read the reopened phase as closed. A revocation
                 # is a record too, and the last record wins.
                 # A THIRD BACKTICKED FIELD, OPTIONAL, carrying WHEN THE VERDICT LANDED
                 # that this signoff answers. Readers take the LAST record, so a
                 # revocation posted after a signoff supersedes it whatever it was
                 # about — and the writer cannot close that window, because its own
                 # write is what erases the evidence. A signoff that says which
                 # verdict it answers lets a reader order a revocation against THAT
                 # rather than against comment order. #135, for #122.
                 #
                 # OPTIONAL BECAUSE EVERY EXISTING RECORD PREDATES IT. A reader
                 # that required it would report every signoff on every open PR as
                 # malformed, which is the fail-closed direction turned into a
                 # denial of service.
                 | (.body | [scan("(?m)^\\*\\*Review-Signoff(-Revoked)?:\\*\\* `([^`\n]{1,200})`(?: `([0-9a-f]{40})`)?(?: `([^`\n]*)`)?[[:space:]]*$")]
                          | last // ["","","",""])
                 | select(.[1] == $who)
                 # A revocation carries no sha and a signoff must; anything else
                 # is a malformed line rather than either.
                 | . as $m
                 # AND A VERDICT TIME THAT IS PRESENT MUST BE READABLE. `none` is
                 # the absent case and travels as itself; anything that is neither
                 # is a record this cannot place, which is not one to act on.
                 #
                 # CAPTURED WITHOUT A LENGTH BOUND AND WITHOUT A MINIMUM, and
                 # judged afterwards. Either restriction makes a value the pattern
                 # dislikes fail the WHOLE marker rather than classify it — the
                 # line then matches nothing, `last` returns an OLDER record, and a
                 # deliberately reopened phase reads as closed. An overlong value
                 # and an EMPTY one are the same defect twice, and a value this
                 # cannot place has to be visible in order to be refused.
                 | (if $m[3] == null then "none"
                    elif ($m[3] | canonical_utc) then $m[3]
                    else "unreadable" end) as $v
                 # A REVOCATION HAS NO SHA, so its verdict time is the SECOND
                 # backticked field rather than the third — and a value there that happens to be forty
                 # lowercase hex is captured as the SHA instead, which the
                 # revocation branch ignores. The record then reads as one carrying
                 # no time at all, so a present but unplaceable value is accepted
                 # as a legacy record. A sha capture ON A REVOCATION is that value.
                 | (if $m[0] != null and ($m[2] | type) == "string" then "unreadable" else $v end) as $v
                 | if $m[0] != null then "REVOKED\t" + $c + "\t" + ($i | tostring) + "\t" + $v
                   elif ($m[2] | type) == "string" then $m[2] + "\t" + $c + "\t" + ($i | tostring) + "\t" + $v
                   # A SIGNOFF WITHOUT A SHA BUT WITH A THIRD FIELD is a record
                   # that failed to parse, not one to pass over: the sha capture
                   # demands 40 hex, so a value in that position which is not one
                   # lands in the verdict field instead. Discarded, the marker
                   # stops being the newest record and an OLDER signoff is returned
                   # with status 0 — a phase reading as closed on stale evidence.
                   elif ($m[3] | type) == "string" then "BADREC\t" + $c + "\t" + ($i | tostring) + "\t" + $v
                   else empty end
               ] as $recs
             # TWO ANSWERS, NOT ONE. The last record is what position gives; the
             # last REVOCATION is what time needs, and it can sit UNDER a later
             # signoff — which is exactly the record #122 is about: a revocation
             # posted while `record` was proving, then superseded by the signoff it
             # was meant to stop. Both travel back, separated by a unit separator,
             # which no field here can contain.
             | ($recs | last // "") + "\u001f" + ([ $recs[] | select(startswith("REVOKED")) ] | last // "")
          end') || { OK=0; break; }
    # THE LAST RECORD ANYWHERE WINS, so a later page supersedes an earlier one and
    # a phase can be reopened by saying so.
    # `<sha-or-REVOKED>\t<createdAt>`; the timestamp travels with the record so the
    # caller never has to guess which of two comments it is holding.
    _us=$(printf '\037')
    _last="${FOUND%%"$_us"*}"
    _lastrev="${FOUND#*"$_us"}"
    [ -n "$_last" ] && {
        SHA="${_last%%$'\t'*}"
        _rest="${_last#*$'\t'}"
        SIGNED_AT="${_rest%%$'\t'*}"
        _rest="${_rest#*$'\t'}"
        SIGNED_ID="${_rest%%$'\t'*}"
        VERDICT_AT="${_rest#*$'\t'}"
    }
    # THE NEWEST REVOCATION ANYWHERE, kept even where a later signoff outranks it
    # by position. A page with none leaves the previous page's, because pages run
    # oldest to newest and the answer is the newest one seen.
    [ -n "$_lastrev" ] && {
        _rest="${_lastrev#*$'\t'}"
        REVOKED_AT="${_rest%%$'\t'*}"
        _rest="${_rest#*$'\t'}"
        REVOKED_ID="${_rest%%$'\t'*}"
    }
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
# IN `sha` MODE THE ANSWER GOES TO STDERR, because stdout is the value's stream
# and "none" is not a value. A caller that captured this line would hold a
# non-empty string that is not a sha, which is the ordinary-looking wrong answer
# this repository's fail-closed rule exists to prevent.
# A REVOCATION CARRIES ITS TIME AND ITS ID, exactly as a signoff does. Without
# them a caller cannot ORDER it: the fault-tolerance pass posts a revocation
# BEFORE requesting its review, so that revocation is the newest record when the
# clean verdict arrives and the pass is ANSWERING it; another session reopening
# the phase posts one AFTER the verdict, and that one CANCELS it. The two read
# identically until the record says when. Omitting `at=` also made two revocations
# compare equal, so one replaced by another could not be told from the original.
# #117.
#
# THE FIELD ORDER IS `verdict-at=`, `at=`, `id=`, THEN `sha=`, and it is not
# cosmetic: every caller reads the sha with `${line##*sha=}`, so a field appended
# after it would be swallowed into the value — and `at=` is peeled with
# `${line#* at=}`, which `verdict-at=` cannot be mistaken for, because the
# character before those three letters is a hyphen rather than a space.
#
# `verdict-at=` IS ALWAYS PRESENT, as `none` where the record does not carry one.
# A field that is sometimes absent makes the record two shapes, and every reader
# would need to know which one it was holding.
# A VERDICT TIME THIS COULD NOT READ IS NOT A RECORD TO ACT ON, AND THAT IS
# DECIDED BEFORE ANY MODE RETURNS. `none` says the signoff does not carry one,
# which every record written before #135 does not; `unreadable` says it carries
# something that is not a time, and a reader ordering a revocation against that
# would place it somewhere arbitrary.
#
# BEFORE THE `sha` MODE AND BEFORE THE REVOCATION BRANCH, both of which return
# early: `sha` handed the head back with status 0, so `SKILL.md` and
# `pr-phase-state.sh` read a malformed record as a closed phase, and a revocation
# exited 1 as an ordinary one.
if [ "$VERDICT_AT" = unreadable ]; then
    if [ "$MODE" = sha ]; then
        echo "PR_SIGNOFF pr=$PR reviewer=$WHO status=error reason=bad_verdict_at" >&2
    else
        echo "PR_SIGNOFF pr=$PR reviewer=$WHO status=error reason=bad_verdict_at" >&2
    fi
    exit 2
fi
# ── A SIGNOFF STANDS ONLY IF NO REVOCATION IS NEWER THAN ITS VERDICT ───────
#
# Position alone says the last record wins, and that is why a revocation landing
# while `record` was proving is superseded by the signoff written next: the
# signoff is posted AFTER it, so it is last. The writer cannot close that window,
# because its own write is what erases the evidence — #115 and #121 narrowed it and
# neither could remove it.
#
# THE RECORD SAYS WHICH VERDICT IT ANSWERS, so time can decide instead: a
# revocation NEWER than that verdict reopened the phase, and one older is the
# fault-tolerance pass this signoff is answering. Neither answer depends on which
# comment landed first. #140, closing #122.
#
# EQUAL IS NOT OLDER, AND UNORDERABLE IS NOT PERMISSION. `created_at` is
# second-resolution and the two records come from different resources, so their ids
# cannot break the tie — and falling back to position there gives "the signoff
# stands", which is the fail-OPEN answer this rule exists to stop. A revocation in
# the same second as the verdict reopens the phase, exactly as `record` refuses to
# write over one. The cost is a rerun where the phase legitimately answered a
# same-second revocation; the cost the other way is a merge on a withdrawn review.
#
# WHERE THERE IS NOTHING TO COMPARE, POSITION DECIDES, and that is today's rule
# unchanged: a signoff carrying `none` — every record written before #137 — has no
# verdict to order against, and a revocation whose own time cannot be read cannot
# be placed. Neither is an unordered pair; both are an absent question, and
# inventing an answer would be worse than position. No pull request in flight
# changes meaning, because none of their signoffs carries the field.
if [ "$SHA" != REVOKED ] && [ "$SHA" != BADREC ] && [ -n "$SHA" ]; then
    case "$VERDICT_AT" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
            case "$REVOKED_AT" in
                [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
                    if [ ! "$REVOKED_AT" \< "$VERDICT_AT" ]; then
                        # THE REVOCATION IS THE RECORD NOW, so the record printed is
                        # ITS time and ITS id. Reporting the signoff's would name a
                        # comment that is not the one being acted on, and callers
                        # order records against each other by exactly these fields.
                        SHA=REVOKED
                        SIGNED_AT="$REVOKED_AT"
                        SIGNED_ID="$REVOKED_ID"
                    fi ;;
            esac ;;
    esac
fi
# A MARKER THAT PARSED AS NEITHER is not a record to look past. It was the newest
# one on the PR, so skipping it hands the answer to an older signoff.
if [ "$SHA" = BADREC ]; then
    echo "PR_SIGNOFF pr=$PR reviewer=$WHO status=error reason=signoff_without_sha" >&2
    exit 2
fi
if [ "$SHA" = REVOKED ]; then
    if [ "$MODE" = sha ]; then
        echo "PR_SIGNOFF pr=$PR reviewer=$WHO verdict-at=$VERDICT_AT at=$SIGNED_AT id=$SIGNED_ID sha=none reason=revoked" >&2
    else
        echo "PR_SIGNOFF pr=$PR reviewer=$WHO verdict-at=$VERDICT_AT at=$SIGNED_AT id=$SIGNED_ID sha=none reason=revoked"
    fi
    exit 1
fi
if [ -z "$SHA" ]; then
    if [ "$MODE" = sha ]; then
        echo "PR_SIGNOFF pr=$PR reviewer=$WHO sha=none" >&2
    else
        echo "PR_SIGNOFF pr=$PR reviewer=$WHO sha=none"
    fi
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
# `verdict-at=` AND `at=` COME BEFORE `sha=`, and that is not cosmetic: every
# caller reads the sha with `${line##*sha=}`, so a field appended after it would be
# swallowed into the value and the gate would compare a sha against a
# sha-plus-timestamp.
# THE SHA ALONE, VALIDATED, AND ON ITS OWN LINE. It has been through
# `sha_reason` above, so what leaves here in this mode is 40 hex or nothing at
# all — there is no record shape left for a caller to get wrong.
if [ "$MODE" = sha ]; then
    echo "$SHA"
    exit 0
fi
echo "PR_SIGNOFF pr=$PR reviewer=$WHO verdict-at=$VERDICT_AT at=$SIGNED_AT id=$SIGNED_ID sha=$SHA"
exit 0
