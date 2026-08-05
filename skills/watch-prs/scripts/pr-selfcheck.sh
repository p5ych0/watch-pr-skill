#!/usr/bin/env bash
# Check the plugin's own sources before a push. 0 = clean · 1 = findings · 2 = the
# check itself could not run.
#
#   pr-selfcheck.sh [repo-root]
#
# WHY THIS EXISTS
#
# PR #10 took nineteen review rounds. Almost none of the findings were subtle;
# they were the same handful of mistakes, made repeatedly, and every one of them
# reached a reviewer because nothing looked at the change before it was pushed.
# The classes, from that PR's own history:
#
#   1. An identifier used and never defined. `$SUMMARY_FILE` was written into two
#      places in SKILL.md and assigned in none. It shipped, and came back as a P1.
#   2. A fix that closed one instance of a class and left the rest — head
#      validation, then non-zero statuses, then record identity, each swept
#      script-by-script across three rounds instead of once.
#   3. A validator widened without rechecking what consumes it. Accepting ISO
#      offsets reopened a lexical-sort hole that an earlier round had closed.
#   4. An ordering assumed rather than traced. With Codex auto-review on, the
#      push is what starts the pass, so a summary posted afterwards is too late.
#
# Only some of that is mechanical. This script does the mechanical part, because
# a check that runs beats a checklist that is read: (1) is caught outright here,
# and (3) and (4) are what the prose checklist in `SKILL.md § Self-check` is for.
#
# It deliberately does NOT try to be a linter. Every check here is one where a
# failure is unambiguous and a pass means something — this repository has already
# built and deleted a structural checker whose stated invariant was false while it
# reported PASS, and that is worse than no check at all.
#
# `set -uo pipefail`, NOT `-e`: the checks use exit status as control flow and
# several probes fail as normal operation. See CLAUDE.md § Bash conventions.
set -uo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
    echo "PR_SELFCHECK status=error reason=no_repo_root" >&2
    exit 2
fi
SKILL="$ROOT/skills/watch-prs/SKILL.md"
SCRIPTS="$ROOT/skills/watch-prs/scripts"

# THIS CHECK IS ABOUT THIS PLUGIN'S OWN SOURCES, and most repositories are not
# it. One installed copy drives every project on a machine, so the working repo
# is usually some consumer with no `skills/watch-prs/` tree at all — and treating
# that as "could not run" made a mandatory pre-push gate exit 2 in every one of
# them, blocking every review round outside this checkout.
#
# A distinguished status rather than an error, and rather than silence: the
# domain of these checks is empty here, which is a different fact from "the
# checks failed" and from "the checks passed". Nothing is fail-open about it —
# there is genuinely nothing in scope — but the caller is told so explicitly so
# it can never be read as a clean bill for code that was never looked at.
#
# It is NOT resolved relative to this script instead. Doing that would check the
# installed plugin, which is not what anyone is about to push, and would report a
# confident PASS about a tree the operator never touched.
if [ ! -f "$SKILL" ] || [ ! -d "$SCRIPTS" ]; then
    echo "PR_SELFCHECK status=not_applicable reason=not_a_watch_pr_skill_checkout root=$ROOT"
    exit 0
fi

findings=0
note() { printf 'PR_SELFCHECK finding=%s %s\n' "$1" "$2"; findings=$((findings + 1)); }
ok()   { printf 'ok   - %s\n' "$1"; }

# ── 1. every $VAR used in SKILL.md's bash blocks is assigned in one ─────────
#
# This is the check that would have caught the P1. Variables the driver is
# expected to supply from outside a block are listed explicitly rather than
# inferred, so adding a new one is a deliberate act.
if [ -f "$SKILL" ]; then
    KNOWN='HOME|PATH|PWD|BASH_SOURCE|CLAUDE_PLUGIN_ROOT|REVIEW_BUS_REMOTE|REVIEW_BUS_OWNER|REVIEW_BUS_REPO|REVIEW_ROUND_THRESHOLD|REVIEW_MERGE_STRICT|PR_WATCH_INTERVAL|PR_WATCH_TIMEOUT|1|2|3|4|5|6|7|8|9|0|@|\*|\?|#|!|_'
    blocks="$(awk '/^```bash$/{inb=1; next} /^```$/{inb=0} inb' "$SKILL")"
    if [ -z "$blocks" ]; then
        echo "PR_SELFCHECK status=error reason=no_bash_blocks_in_skill" >&2
        exit 2
    fi
    # Assignments, ONLY where an assignment can actually occur: at the start of a
    # line or after a `;`, optionally preceded by `local`.
    #
    # Accepting `NAME=` after any whitespace looked equivalent and was not: the
    # identity block ends with
    #   echo "OWNER=$OWNER REPO=$REPO ... SUMMARY_FILE=$SUMMARY_FILE"
    # and every one of those names then read as assigned — including the one whose
    # missing assignment was the P1 this check exists to catch. A checker that
    # cannot catch the bug it was written for is the failure this repository has
    # already deleted one checker over, so this is verified by a fixture that
    # removes the real assignment and requires the finding.
    assigned="$(printf '%s\n' "$blocks" \
        | grep -oE '(^|;)[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' \
        | sed -E 's/^[;[:space:]]*(local[[:space:]]+)?//; s/=$//' | sort -u)"
    # Loop variables, ONLY where a `for` command can actually start: at the
    # beginning of a line or after `;`/`do`/`then`/`else`, and followed by `in`.
    #
    # `for +NAME` anywhere was a false negative waiting to happen, and precisely
    # the class this checker exists to prevent: a comment reading
    # `# wait for SUMMARY_FILE` registered SUMMARY_FILE as a loop variable, so the
    # undefined-variable check went quiet about a variable still defined nowhere.
    # A checker that a passing comment can switch off is worse than none.
    forvars="$(printf '%s\n' "$blocks" \
        | grep -oE '(^|;|[[:space:]](do|then|else)[[:space:]])[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in([[:space:]]|$)' \
        | grep -oE 'for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
        | awk '{print $2}' | sort -u)"
    assigned="$(printf '%s\n%s\n' "$assigned" "$forvars" | sort -u)"
    # Uses: $NAME and ${NAME...}, restricted to UPPERCASE names.
    #
    # THE BOUND IS DELIBERATE, and stating it is the point. The obvious version —
    # every `$name` — reports jq's `$n`, `$who`, `$latest` and GraphQL's `$owner`,
    # `$cursor` as undefined shell variables, because they live inside
    # single-quoted programs that span several lines. Stripping those spans needs
    # a Bash lexer that also understands double quotes, comments and heredocs;
    # this repository has already built and deleted a structural checker for
    # exactly that reason, after six versions each reported PASS while their
    # stated invariant was false.
    #
    # So the check covers what it can actually prove: SKILL.md's own shell
    # variables are uppercase by convention, jq's and GraphQL's are not, and the
    # separation needs no parsing. A LOWERCASE shell variable used and never
    # assigned would slip past — that is a real hole, and a stated one is worth
    # more than a lexer that quietly has a different one.
    used="$(printf '%s\n' "$blocks" \
        | grep -oE '\$\{?[A-Z][A-Z0-9_]*' \
        | grep -oE '[A-Z][A-Z0-9_]*' | sort -u)"
    undef=""
    for v in $used; do
        case "$v" in
            BASH_REMATCH) continue ;;
        esac
        printf '%s\n' "$v" | grep -qE "^($KNOWN)$" && continue
        printf '%s\n' "$assigned" | grep -qx "$v" || undef="$undef $v"
    done
    if [ -n "$undef" ]; then
        for v in $undef; do
            note undefined_variable "SKILL.md uses \$$v but never assigns it"
        done
    else
        ok "every variable used in SKILL.md's bash blocks is assigned in one"
    fi
else
    echo "PR_SELFCHECK status=error reason=no_skill_md" >&2
    exit 2
fi

# ── 2. every shell script parses ───────────────────────────────────────────
parse_bad=0
for f in "$SCRIPTS"/*.sh; do
    [ -e "$f" ] || continue
    bash -n "$f" 2>/dev/null || { note syntax_error "$(basename "$f") does not parse"; parse_bad=1; }
done
[ "$parse_bad" -eq 0 ] && ok "every script under scripts/ parses"

# ── 3. every helper SKILL.md drives actually exists ────────────────────────
#
# A contract naming a script that is not shipped fails at the point the driver
# needs it most, and `$RB_SCRIPTS` resolving to an empty string turns that into a
# confusing path error rather than a missing-file one.
missing=0
for s in $(grep -oE '\$RB_SCRIPTS"?/pr-[a-z-]+\.sh' "$SKILL" | grep -oE 'pr-[a-z-]+\.sh' | sort -u); do
    [ -f "$SCRIPTS/$s" ] || { note missing_script "SKILL.md drives $s, which is not in scripts/"; missing=1; }
done
[ "$missing" -eq 0 ] && ok "every helper SKILL.md drives is present"

# ── 4. every script has a test ─────────────────────────────────────────────
untested=0
for f in "$SCRIPTS"/pr-*.sh; do
    [ -e "$f" ] || continue
    b="$(basename "$f" .sh)"
    [ -f "$SCRIPTS/test-$b.sh" ] || { note untested_script "$b.sh has no test-$b.sh"; untested=1; }
done
[ "$untested" -eq 0 ] && ok "every pr-*.sh has a matching test"

# ── 5. the suite passes ────────────────────────────────────────────────────
suite_fail=0
for t in "$SCRIPTS"/test-*.sh; do
    [ -e "$t" ] || continue
    bash "$t" >/dev/null 2>&1 || { note failing_test "$(basename "$t") fails"; suite_fail=1; }
done
[ "$suite_fail" -eq 0 ] && ok "the whole suite passes"

if [ "$findings" -gt 0 ]; then
    echo "PR_SELFCHECK status=findings count=$findings"
    exit 1
fi
echo "PR_SELFCHECK status=clean count=0"
exit 0
