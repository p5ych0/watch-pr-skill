#!/usr/bin/env bash
# Check the plugin's own sources before a push.
#
#   pr-selfcheck.sh [repo-root]
#
#   0  clean
#   1  findings — fix them before pushing
#   2  the check itself could not run — fail closed
#   3  not applicable: this repository is not a watch-pr-skill checkout, so
#      there was nothing in scope to check
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

# The root lookup takes its STATUS, like every other probe in this plugin.
# `git rev-parse --show-toplevel` can print a plausible directory and then exit
# non-zero, and command substitution keeps it — so the check would scan a tree
# the probe never actually vouched for, and if that tree happened to satisfy
# everything it would report `status=clean` off a failed read.
#
# An explicit argument is the caller stating the root and has no status to check.
if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    ROOT="$1"
else
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "PR_SELFCHECK status=error reason=repo_root_lookup_failed" >&2
        exit 2
    }
fi
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
# Its OWN EXIT STATUS, not 0. A distinguished line printed alongside exit 0 was
# not actually distinguished: the caller captures a status, `SKILL.md` defines 0
# as "the mechanical checks pass", and nothing parsed the record — so a run that
# checked nothing at all was indistinguishable in control flow from a run that
# checked everything and found it clean. "Distinct" has to mean distinct to the
# code that branches on it, not just to a human reading the output.
#
# It is NOT resolved relative to this script instead. Doing that would check the
# installed plugin, which is not what anyone is about to push, and would report a
# confident PASS about a tree the operator never touched.
if [ ! -f "$SKILL" ] || [ ! -d "$SCRIPTS" ]; then
    echo "PR_SELFCHECK status=not_applicable reason=not_a_watch_pr_skill_checkout root=$ROOT"
    exit 3
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
    KNOWN='HOME|PATH|PWD|BASH_SOURCE|CLAUDE_PLUGIN_ROOT|REVIEW_BUS_REMOTE|REVIEW_BUS_OWNER|REVIEW_BUS_REPO|REVIEW_ROUND_THRESHOLD|REVIEW_MERGE_STRICT|PR_WATCH_INTERVAL|PR_WATCH_TIMEOUT|PR_CI_INTERVAL|PR_CI_TIMEOUT|1|2|3|4|5|6|7|8|9|0|@|\*|\?|#|!|_'

    # Every extraction below has its STATUS taken. `set -uo pipefail` does not
    # stop an unchecked assignment, so a failed pipeline left the variable empty
    # and the loop that consumes it simply found nothing to complain about —
    # `status=clean` from a run that never established what was used. That is the
    # precise failure this whole script exists to prevent, in the script itself.
    #
    # 0 and 1 are both ANSWERS: `grep` exits 1 when nothing matches, which is a
    # legitimate result here. Anything else is a broken read.
    # Checked on the CAPTURED status of each pipeline, not with `|| exit`. Under
    # `pipefail` a pipeline reports the rightmost non-zero status, and `grep`
    # exits 1 when nothing matches — a legitimate answer — so `||` fired on every
    # empty result and aborted the whole check.
    #
    # ONE strict checker, and the grep stages normalise their own status.
    #
    # Two checkers was still wrong. A "tolerant of 1" check applied to a whole
    # PIPELINE cannot tell whose 1 it is: under `pipefail` the status is the
    # rightmost non-zero, so a `sed` or `sort` that emitted plausible partial
    # output and exited 1 was read as "grep found no matches" — the same
    # ambiguity, one stage further down.
    #
    # So the exception lives where the exception actually is. `nomatch` wraps a
    # single grep and turns ITS 1 into 0, leaving every other status non-zero;
    # after that, any non-zero anywhere in the pipeline is a broken read and
    # `chk` can be strict everywhere.
    chk() {   # chk <label> <status> — no non-zero is acceptable
        if [ "$2" -ne 0 ]; then
            echo "PR_SELFCHECK status=error reason=extraction_failed step=$1 rc=$2" >&2
            exit 2
        fi
    }
    nomatch() {   # run a grep; 1 ("no matches") becomes 0, everything else stays
        "$@" || [ "$?" -eq 1 ]
    }

    blocks="$(awk '/^```bash$/{inb=1; next} /^```$/{inb=0} inb' "$SKILL")"; chk blocks $?
    if [ -z "$blocks" ]; then
        echo "PR_SELFCHECK status=error reason=no_bash_blocks_in_skill" >&2
        exit 2
    fi
    # Full-line comments are dropped before anything is inferred from the text.
    # A comment is not code, and every false negative this check has had came
    # from prose being read as shell: `# wait for SUMMARY_FILE`, then
    # `# then for SUMMARY_FILE in prose`.
    code="$(printf '%s\n' "$blocks" | nomatch grep -vE '^[[:space:]]*#')"; chk strip_comments $?
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
    assigned="$(printf '%s\n' "$code" \
        | nomatch grep -oE '(^|;)[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' \
        | sed -E 's/^[;[:space:]]*(local[[:space:]]+)?//; s/=$//' | sort -u)"; chk assigned $?
    # …plus the variables a SOURCED library assigns. SKILL.md loads
    # `identitylib.sh` and calls `rb_identity`, which SETS `HOST`, `OWNER` and
    # `REPO` rather than printing them — so those names are assigned, just not in
    # this file. Reading only the skill's own text reported the driver's identity
    # variables as undefined, which is this check being wrong about the skill
    # rather than the skill being wrong.
    #
    # The libraries are DISCOVERED from the `.` lines, never listed here. A list
    # goes stale the first time another library is sourced, and it goes stale
    # SILENTLY: the findings it stops reporting are indistinguishable from a clean
    # run, which is the one direction this script may not fail in.
    #
    # A library named but not readable is an ERROR, not an empty set of
    # assignments — an empty set would silently reinstate the false findings this
    # branch exists to remove, and a missing library is a broken install besides.
    sourced="$(printf '%s\n' "$code" \
        | nomatch grep -oE '^\.[[:space:]]+"\$RB_SCRIPTS/[A-Za-z0-9_.-]+"' \
        | sed -E 's#^.*/##; s/"$//' | sort -u)"; chk sourced $?
    for lib in $sourced; do
        if [ ! -f "$SCRIPTS/$lib" ]; then
            echo "PR_SELFCHECK status=error reason=sourced_lib_missing lib=$lib" >&2
            exit 2
        fi
        # THE LIBRARY DECLARES WHAT IT ASSIGNS; nothing is inferred from its body.
        #
        # Three inferences were tried and each was wrong in the QUIET direction.
        # Every assignment in the file credited `unused() { TOKEN=x; }`, which
        # sourcing never runs. Restricting to called functions still credited an
        # assignment after a `return`, and one inside an untaken branch. Deciding
        # that statically is a reachability analysis, and a wrong answer here reads
        # as "this variable is fine" — the false-clean direction this script exists
        # to close, reached through the branch added to remove a false finding.
        #
        # A declaration has no such failure mode: it is read, not deduced. The
        # library's own test proves the declaration matches what a successful call
        # sets, so a drifted one fails the suite rather than quietly widening what
        # is accepted here.
        #
        # A sourced library with NO declaration is an ERROR. Crediting nothing
        # would reinstate exactly the false findings this branch removes, and
        # report them as defects in the skill.
        libassigned="$(nomatch grep -oE '^# rb-assigns:[A-Za-z0-9_ ]*' "$SCRIPTS/$lib" \
            | sed -E 's/^# rb-assigns:[[:space:]]*//' | tr ' ' '\n' \
            | nomatch grep -vE '^$' | sort -u)"; chk lib_assigned $?
        if [ -z "$libassigned" ]; then
            echo "PR_SELFCHECK status=error reason=lib_declares_no_assignments lib=$lib" >&2
            exit 2
        fi
        assigned="$(printf '%s\n%s\n' "$assigned" "$libassigned" | sort -u)"; chk merge_lib $?
    done
    # Loop variables, ONLY at the START OF A LINE. This is the third version, and
    # the narrowness is the point.
    #
    #   `for +NAME` anywhere          -> `# wait for SUMMARY_FILE` silenced it
    #   ...plus `(do|then|else)` too  -> `# then for SUMMARY_FILE in prose` did
    #
    # Each widening to catch a legitimate position reopened the same false
    # negative, because the alternatives match inside prose and quoted strings and
    # anchoring them properly needs a Bash lexer — which this repository has
    # already built and deleted once.
    #
    # So it recognises only `for NAME in` at the beginning of a line. A `for`
    # after `;` or `do` on the same line is therefore NOT seen, and its variable
    # is reported as undefined. That is a false POSITIVE: loud, obvious, and
    # fixable in one line — the opposite direction from a checker that a comment
    # can switch off, which is silent and indistinguishable from a clean run.
    forvars="$(printf '%s\n' "$code" \
        | nomatch grep -oE '^[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in([[:space:]]|$)' \
        | awk '{print $2}' | sort -u)"; chk forvars $?
    assigned="$(printf '%s\n%s\n' "$assigned" "$forvars" | sort -u)"; chk merge_assigned $?
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
    used="$(printf '%s\n' "$code" \
        | nomatch grep -oE '\$\{?[A-Z][A-Z0-9_]*' \
        | nomatch grep -oE '[A-Z][A-Z0-9_]*' | sort -u)"; chk used $?
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
# The list is built and its STATUS taken BEFORE the loop. Discovering the helpers
# inline in `for ... $(pipeline)` meant a failed pipeline produced an empty or
# partial list, the loop ran zero or too few iterations, `missing` stayed 0, and
# the check reported that every helper was present without ever establishing
# which helpers the skill drives.
# The grep stages normalise their own no-match status, so any remaining non-zero
# — including a `sort` that printed partial output and exited 1 — is a broken
# read rather than "the skill drives no helpers".
helpers="$(nomatch grep -oE '\$RB_SCRIPTS"?/pr-[a-z-]+\.sh' "$SKILL" \
    | nomatch grep -oE 'pr-[a-z-]+\.sh' | sort -u)"
hstat=$?
if [ "$hstat" -ne 0 ]; then
    echo "PR_SELFCHECK status=error reason=extraction_failed step=helpers rc=$hstat" >&2
    exit 2
fi
missing=0
for s in $helpers; do
    [ -f "$SCRIPTS/$s" ] || { note missing_script "SKILL.md drives $s, which is not in scripts/"; missing=1; }
done
[ "$missing" -eq 0 ] && ok "every helper SKILL.md drives is present"

# ── 3b. every `gh pr` call names the repository ────────────────────────────
#
# `gh` resolves the repository from the local checkout — or from `GH_REPO`, which
# overrides it. Every helper passes `--repo`, and every `gh pr view/edit/checks/
# merge` in the contract did too; the five `gh pr comment` calls did not. With
# `GH_REPO` set, those posted review requests and round summaries to the
# same-numbered PR in a DIFFERENT repository while every gate inspected this one.
#
# Mechanical and unambiguous: a `gh pr <verb> N` line either carries `--repo` or
# it does not.
# Scoped to the bash blocks with comments already stripped — `$code`, not the
# whole file. Prose quoting a command in backticks ("the request is `gh pr edit
# --add-reviewer @copilot`") is documentation, not a call, and reporting it makes
# the check noise.
# Backslash continuations are JOINED first. A correctly pinned call written as
#     gh pr comment N \
#         --repo "$OWNER/$REPO" --body "…"
# has `--repo` on the second physical line, so a per-line check reported it as
# unpinned — and this check is mandatory before the push, so a false positive
# here does not just annoy, it blocks the round. `sed` joins any line ending in a
# backslash with the next before anything is matched.
unpinned=0
joined="$(printf '%s\n' "$code" | sed -e :a -e '/\\$/N; s/\\\n//; ta')"
chk join_continuations $?
gh_lines="$(printf '%s\n' "$joined" | nomatch grep -E 'gh pr (comment|view|edit|merge|checks|close|ready)[[:space:]]')"
chk gh_lines $?
if [ -n "$gh_lines" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # EVERY OCCURRENCE on the line, checked by POSITION rather than by
        # splitting the line into commands.
        #
        # This check has had four holes: a substring test, a position test
        # applied to the whole line, and a `;`-only splitter that `&&` walked
        # straight through. Splitting is the wrong tool — deciding which text is
        # a command needs a quote-aware parser, and a half-parser that reports
        # `clean` is what this repository has already deleted one checker over.
        #
        # Instead: pull out every `gh pr <verb> <arg> <next>` on the line and
        # require <next> to be `--repo`. An assignment can no longer vouch for a
        # call beside it, because each call is judged on its own three tokens —
        #     BODY='gh pr comment 7 --repo OWNER-SLASH-REPO' && gh pr comment 7 --body "$B"
        # yields two occurrences, and the second one fails on its own.
        occ="$(printf '%s\n' "$line" \
            | nomatch grep -oE 'gh pr (comment|view|edit|merge|checks|close|ready)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+')"
        chk gh_occurrences $?
        # A call whose line ends before the third token matches nothing above, so
        # the counts are compared: fewer occurrences than verbs means one was not
        # examined, which is not the same as one that passed.
        n_verbs="$(printf '%s\n' "$line" \
            | nomatch grep -oE 'gh pr (comment|view|edit|merge|checks|close|ready)[[:space:]]' | wc -l)"
        chk gh_verbs $?
        n_occ=0
        if [ -n "$occ" ]; then
            n_occ="$(printf '%s\n' "$occ" | wc -l)"; chk gh_occ_count $?
        fi
        if [ "$n_occ" -ne "$n_verbs" ]; then
            note truncated_gh_call "SKILL.md: a gh pr call is too short to check:$(printf '%s' "$line" | cut -c1-60)"
            unpinned=1
            continue
        fi
        while IFS= read -r one; do
            [ -n "$one" ] || continue
            case "$one" in
                *" --repo"|*" --repo="*) ;;
                *) note unpinned_gh_call "SKILL.md: a gh pr call without --repo:$(printf '%s' "$one" | cut -c1-60)"
                   unpinned=1 ;;
            esac
        done <<INNER
$occ
INNER
    done <<EOF
$gh_lines
EOF
fi
[ "$unpinned" -eq 0 ] && ok "every gh pr call in SKILL.md names the repository"

# ── 4. every script has a test ─────────────────────────────────────────────
#
# The SOURCED LIBRARIES count too. They are not `pr-*.sh`, so the original glob
# missed them — and they are the highest-leverage files in the tree: `testlib.sh`
# bounds every fixture in the suite, and `recordlib.sh` now defines what a
# well-formed record is for all four helpers at once. A bug in either is a bug
# everywhere, which is exactly the argument for extracting them and exactly why
# they cannot be the untested part.
# …and they are DISCOVERED, not listed. The list named `testlib.sh` and
# `recordlib.sh`, so `identitylib.sh` — added later, and the file that decides
# which repository every `gh` call addresses — was outside the gate entirely:
# deleting `test-identitylib.sh` left this reporting that every shared library has
# a matching test. A list of the files a rule covers goes stale silently, and
# silently is the direction that turns a guard into a green tick over nothing.
untested=0
for f in "$SCRIPTS"/pr-*.sh "$SCRIPTS"/*lib.sh; do
    [ -e "$f" ] || continue
    # `*lib.sh` also matches `test-testlib.sh`, and a test does not need a test.
    case "$(basename "$f")" in test-*) continue ;; esac
    b="$(basename "$f" .sh)"
    [ -f "$SCRIPTS/test-$b.sh" ] || { note untested_script "$b.sh has no test-$b.sh"; untested=1; }
done
[ "$untested" -eq 0 ] && ok "every helper and shared library has a matching test"

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
