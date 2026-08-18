#!/usr/bin/env -S bash -p
# pr-merge-range.sh — may the head be merged on a review signoff that was given
# for an EARLIER commit?
#
#   pr-merge-range.sh <reviewed_sha> <head_oid> [repo_dir]
#
#   0  every commit in reviewed..head carries a `Review-Phase: copilot` trailer,
#      so the head advanced only through the review fix loop.
#   1  an intervening commit carries no such trailer, or the reviewed SHA is not
#      an ancestor of the head — unreviewed work reached this head. Do NOT merge.
#   2  the range could not be inspected. Callers MUST fail closed.
#
# This lived inline in SKILL.md, where it had two defects that no test could
# reach because nothing executed it:
#
#   * It classified commits by a `^fix(review):` SUBJECT. Any commit can carry
#     that subject, so unrelated work could merge without Codex ever seeing it.
#     Classification is now by trailer, read through git's own `%(trailers:...)`
#     parser — a mention in a subject or body is not a trailer and must not pass.
#   * `git log ... | grep -c` hid a failing `git log` behind a successful `grep`,
#     and `TOTAL=$(git rev-list ...)` was checked for text but not exit status.
#     If the log emitted the expected number of lines before failing, TAGGED
#     equalled TOTAL and the merge proceeded on an inspection that had failed.
#     Both git commands are now captured and guarded separately.
#
# NOTE: `set -uo pipefail` WITHOUT -e on purpose — the exit codes above are
# control flow, and several git probes "fail" as normal operation.
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
# that prints a forged `MERGE_RANGE status=error` line and exits has already answered the
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
    echo "MERGE_RANGE status=error reason=not_privileged" >&2
    exit 2
fi

set -uo pipefail

REVIEWED="${1:-}"
HEAD_OID="${2:-}"
# `|| true` here did the opposite of failing closed: it discarded the probe's
# status so a `git rev-parse` that printed a plausible directory and then failed
# was indistinguishable from one that worked, and every history check below then
# ran against a tree nothing vouched for — deciding a merge about the wrong repo.
#
# An explicit third argument is the caller naming the root and has no status.
if [ -n "${3:-}" ]; then
    REPO_DIR="$3"
else
    REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "PR_MERGE_RANGE status=error reason=repo_root_lookup_failed" >&2
        exit 2
    }
fi

if [ -z "$REVIEWED" ] || [ -z "$HEAD_OID" ] || [ -z "$REPO_DIR" ]; then
    echo "MERGE_RANGE status=error reason=usage" >&2
    exit 2
fi

# Both endpoints must resolve, or the range means nothing.
for ref in "$REVIEWED" "$HEAD_OID"; do
    if ! git -C "$REPO_DIR" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1; then
        echo "MERGE_RANGE status=error reason=unresolved_ref ref=${ref}" >&2
        exit 2
    fi
done

# Ancestry FIRST. After a force-push the range can be divergent, where a commit
# count says nothing about whether the reviewed SHA is reachable at all — the
# signoff simply does not cover this head.
if ! git -C "$REPO_DIR" merge-base --is-ancestor "$REVIEWED" "$HEAD_OID" 2>/dev/null; then
    echo "MERGE_RANGE status=blocked reason=not_an_ancestor reviewed=${REVIEWED:0:7} head=${HEAD_OID:0:7}"
    exit 1
fi

if ! TOTAL="$(git -C "$REPO_DIR" rev-list --count "${REVIEWED}..${HEAD_OID}" 2>/dev/null)"; then
    echo "MERGE_RANGE status=error reason=rev_list_failed" >&2
    exit 2
fi
if ! [[ "$TOTAL" =~ ^[0-9]+$ ]]; then
    echo "MERGE_RANGE status=error reason=bad_count value=${TOTAL}" >&2
    exit 2
fi

# Identical heads: nothing intervened.
if [ "$TOTAL" -eq 0 ]; then
    echo "MERGE_RANGE status=ok commits=0"
    exit 0
fi

# Captured separately from the count so a failing `git log` cannot be masked by
# a successful `grep` further down the pipeline.
if ! TRAILERS="$(git -C "$REPO_DIR" log --format='%(trailers:key=Review-Phase,valueonly,separator=%x2C)' \
                     "${REVIEWED}..${HEAD_OID}" 2>/dev/null)"; then
    echo "MERGE_RANGE status=error reason=log_failed" >&2
    exit 2
fi

# `|| true` masked EVERY non-zero status, not just grep's rc 1 for "no matches" -
# and command substitution keeps whatever was printed before a failure, so a
# counter that printed the expected number and then exited 2 still satisfied
# TAGGED == TOTAL and this returned status=ok. Take the status explicitly: 0 is a
# real count, 1 is a real zero, anything else is a failed inspection and must
# fail closed.
grep_rc=0
TAGGED="$(printf '%s\n' "$TRAILERS" | grep -c '^copilot$')" || grep_rc=$?
case "$grep_rc" in
    0) ;;
    1) TAGGED=0 ;;
    *) echo "MERGE_RANGE status=error reason=count_failed rc=$grep_rc" >&2; exit 2 ;;
esac
if ! [[ "$TAGGED" =~ ^[0-9]+$ ]]; then
    echo "MERGE_RANGE status=error reason=count_unreadable" >&2
    exit 2
fi

if [ "$TOTAL" -eq "$TAGGED" ]; then
    echo "MERGE_RANGE status=ok commits=$TOTAL tagged=$TAGGED"
    exit 0
fi

# WHICH KIND of untagged, because the two need different fixes and the message is
# the only thing the operator gets. `Review-Phase: copilot` written into the body
# but separated from the final block by a blank line is NOT a trailer — git parses
# only the last paragraph — so the commit looks correct to a human reading it and
# is invisible here. That happened while developing this plugin, following this
# plugin's own instructions, and cost a rewrite of an already-pushed commit.
#
# The status is taken: `grep -c` returns 1 for no matches, which is a real zero,
# and anything else is a failed inspection that must not read as "none of them".
body_rc=0
INBODY="$(git -C "$REPO_DIR" log --format='%B' "${REVIEWED}..${HEAD_OID}" 2>/dev/null \
          | grep -c '^Review-Phase:[[:space:]]*copilot[[:space:]]*$')" || body_rc=$?
case "$body_rc" in
    0) ;;
    1) INBODY=0 ;;
    *) echo "MERGE_RANGE status=error reason=body_scan_failed rc=$body_rc" >&2; exit 2 ;;
esac
if [ "$INBODY" -gt "$TAGGED" ]; then
    echo "MERGE_RANGE status=blocked reason=trailer_not_in_trailer_block commits=$TOTAL tagged=$TAGGED in_body=$INBODY"
    echo "A commit writes 'Review-Phase: copilot' in its message but not as a trailer." >&2
    echo "git reads trailers from the LAST paragraph only, so it must sit in the same" >&2
    echo "block as Co-Authored-By and friends, with no blank line before it." >&2
    exit 1
fi
echo "MERGE_RANGE status=blocked reason=untagged_commit commits=$TOTAL tagged=$TAGGED"
exit 1
