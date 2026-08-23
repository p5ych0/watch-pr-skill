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

# ── THE STARTUP HOOK RUNS BEFORE THIS FILE DOES, SO STEP OUT OF IT ─────────
#
# A non-interactive bash sources `$BASH_ENV` before the script body, and what it
# leaves behind cannot always be undone from in here: `helper() { :; };
# readonly -f helper` is a function `unset` REFUSES to remove, so the clearing
# below cannot clear it and the postcondition would refuse a run over something
# entirely harmless. `readonly BASH_ENV` in the same hook makes the variable
# itself unsettable. Both are the failure direction an operator feels — a
# mandatory gate blocking a valid checkout.
#
# Re-exec once, with the hook variables removed, so it never runs at all. `env -u`
# rather than `env -i`: the whole environment is carried through minus those two
# names, so there is no allowlist to leave something out of — and an allowlist is
# a shape that has already been wrong twice in this file.
#
# THE GUARD IS A MARKER, AND CONDITIONING ON THE HOOK VARIABLES WAS WRONG. That
# asks a question the hook has already had the chance to answer — it can `unset
# BASH_ENV` on its way out, leaving a `readonly -f` function nothing can clear and
# no evidence anything ran. A marker set by the exec cannot be erased that way,
# because the hook has finished by the time it exists.
#
# Its two costs are real and are handled below rather than denied: it is inherited
# by children unless cleared, which the suite caught when it was not; and a caller
# who exports it skips the re-exec, which is the boundary this file already
# concedes.
#
# If `exec` or `env` is itself shadowed the re-exec silently does not happen, and
# the clearing and postcondition below are still there; this is the cheap layer,
# not the only one.
#
# Exported functions do NOT need this: one arrives non-readonly however it was
# marked in the shell that exported it, so the clearing reaches those.
# `[[`, NOT `[`. The hook has already run when this line is reached, so a `[`
# function it defined would intercept the guard and skip the very re-exec that
# exists to escape it. `[[` is a reserved word: the parser handles it and no
# function can take its place.
# `SHELLOPTS` AND `BASH_XTRACEFD` TRAVEL WITH THEM, for the same reason. An
# exported `SHELLOPTS=xtrace` turns tracing on in this process and every worker,
# and `BASH_XTRACEFD=1` puts that trace on stdout — inside every command
# substitution. The postcondition below then reads its own trace as a leftover
# function name and refuses a valid checkout before the records are even reached.
# `SHELLOPTS` is readonly in a shell, so it cannot be unset from in here either;
# `env -u` removes it from the child's environment regardless.
#
# UNCONDITIONALLY, AND GUARDED BY A MARKER RATHER THAN BY THE EVIDENCE. Asking
# whether a hook variable is set asks the wrong question: the hook has already run
# by the time the question is put, and it can answer it itself —
#
#     helper() { :; }; readonly -f helper; unset BASH_ENV
#
# leaves a function `unset` REFUSES to remove and no sign that anything ran, so
# the re-exec was skipped and the postcondition refused a valid checkout. Nothing
# hostile is needed for that; a hook that tidies up after itself is a reasonable
# thing to write.
#
# A marker cannot be erased that way, because the exec sets it after the hook has
# had its turn. The cost is one extra `exec` per invocation — milliseconds against
# a gate that takes eighty-five seconds.
#
# THE `unset` ON THE NEXT LINE IS NOT OPTIONAL. Without it the marker is in the
# environment of every child: the workers, the tests they run, and the nested
# copies of this script the fixtures invoke would each skip their own re-exec and
# stand in the hook they were meant to step out of. An earlier version did exactly
# that and the suite caught it — a case passing standalone and failing inside the
# gate.
#
# A caller who exports the marker skips the re-exec. That is the boundary already
# recorded above rather than a new hole: a shell running arbitrary code as the
# developer can edit the tests or amend the commit instead.
# `[[`, NOT `[` — the hook runs first and can define a `[` function, which would
# intercept this guard and skip the re-exec that exists to escape it. That is the
# same slip made when this guard was a condition on `BASH_ENV`, and the suite
# caught it both times.
if [[ -z ${RB_SELFCHECK_CLEAN-} ]]; then
    RB_SELFCHECK_CLEAN=1 exec env -u BASH_ENV -u ENV -u SHELLOPTS -u BASH_XTRACEFD bash "$0" "$@"
fi
unset -v RB_SELFCHECK_CLEAN 2>/dev/null || true

# ── INHERITED FUNCTIONS ARE CLEARED BEFORE ANYTHING DEPENDS ON A NAME ──────
#
# An exported shell function is inherited by this process and shadows the name it
# is called by — builtin or external, it makes no difference. That is not
# hypothetical here: an exported `umask` function defeated a mode narrowing
# earlier in this PR's history, and an exported `sort` can rewrite a failing test
# record into a passing one, which forges the verdict this whole script exists to
# produce.
#
# `command` and `builtin` are the prefixes everything below uses to reach the real
# thing, and they are ordinary builtins, so they are shadowable in exactly the
# same way. Clearing them first is what makes the rest of the file mean anything.
#
# THIS DOES NOT CLOSE THE CLASS, AND SAYING SO IS THE POINT. `unset` can itself be
# shadowed; `set -o posix` would make special builtins outrank functions and fix
# that, except a function named `set` defeats the `set`. Verified, not assumed —
# the regress has no terminator inside the process.
#
# What it does close is every version of the attack that does not also shadow
# `unset`. What is left needs a parent shell that is already executing arbitrary
# code as the developer, and such a shell can edit the tests, this script, or the
# commit — so a gate defending its own arithmetic against it is defending the
# wrong thing. That is a limitation rather than a hole, and it is written here
# rather than left for a reader to rediscover.
# EVERY INHERITED FUNCTION, NOT A LIST OF NAMES. The first version named the
# commands the verdict depends on, and a list like that is wrong by omission: it
# had `printf` and `sort` and not `read`, which parses the records, nor `[`, which
# decides every comparison in the count check. Both are builtins and both are
# shadowable, as are `test`, `exit`, `declare`, `local`, `shift` and `eval` —
# checked, not assumed. Enumerating names is a ladder with no top.
#
# So nothing inherited survives, whatever it is called. Clearing a benign exported
# function costs this process nothing: it does not use any.
# `--`, BECAUSE A FUNCTION NAME IS NOT AN OPTION. `unset -f -v` reads `-v` as a
# flag and clears nothing, so the function survives and the postcondition below
# refuses a run that was fine. `function -v { …; }` is a name bash accepts.
#
# NOTHING HERE READS `IFS` ANY MORE, and that is deliberate. The names are read
# from a quoted here-string and the failure list is an array, so the two places an
# inherited separator once reached are gone. A normalising assignment stood here
# until a hook declared `readonly IFS=-`, which no assignment can undo — a guard
# that can be locked out is worse than no dependency at all.
# THE NAMES ARE READ, NOT EXPANDED. An unquoted `$(compgen …)` needs protecting
# from two separate things — word splitting, which `IFS` covers, and globbing,
# which needs `set -f`, which is itself a shadowable name someone can neutralise.
# A quoted here-string does neither: `a*b` arrives as `a*b` whatever the working
# directory holds, and there is no `set` to swallow.
#
# That matters because a glob-shaped name IS reachable. Bash rejects
# `function 'a*b'` as "not a valid identifier", but imports one from the
# environment without complaint — `env 'BASH_FUNC_a*b%%=() { :; }' bash …` arrives
# with it defined, and unquoted it expanded against the working directory. A name
# containing whitespace is NOT reachable: bash refuses that on import too.
#
# `read` and the enumerators are cleared before anything depends on them, without
# a prefix, because a prefix is one more name to trust.
unset -f unset builtin command compgen declare read 2>/dev/null || true
# NO `IFS=` PREFIX ON THE READ. Assigning to a readonly `IFS` fails, and bash 3.2
# and bash 5 do not agree on what happens next — one reads the line anyway, the
# other mangles the record enough to fail its own grammar. Neither matters here:
# a function name cannot contain whitespace, because bash rejects such a name on
# import as well as on definition, so there is nothing for `read` to trim.
while read -r _rb_f; do
    [ -n "$_rb_f" ] || continue
    builtin unset -f -- "$_rb_f" 2>/dev/null || true
done <<< "$(builtin compgen -A function 2>/dev/null)"
# …AND TRACING IS TURNED OFF HERE TOO, because the re-exec above can be swallowed
# by an `exec` function — even a benign one — and then `SHELLOPTS=xtrace` is still
# in force. Every `$( )` below writes its trace to stdout when `BASH_XTRACEFD=1`,
# including the two that feed the postcondition, which then reads its own trace as
# a leftover function name and refuses a valid checkout.
#
# AFTER the clearing, so `set` is the builtin rather than whatever the caller
# exported. `SHELLOPTS` is readonly in the child and cannot be unset, but `set +x`
# turns the option off regardless — checked, because "readonly" suggested
# otherwise.
set +x

# …AND THE POSTCONDITION DOES NOT SHARE A PREFIX WITH ITSELF. Asking twice through
# `builtin compgen` and `builtin declare` is one question, not two: a single
# forged `builtin` answers both. One call goes through the prefix and one goes
# direct, so a forgery has to cover `builtin` AND `declare` consistently to keep
# them agreeing.
#
# It still does not terminate the regress, and nothing here pretends otherwise.
# Each layer costs an attacker another name that must be replaced consistently;
# what remains needs a parent shell already executing arbitrary code as the
# developer, which can edit the tests or amend the commit instead.
#
# `[[` and `if` are reserved words: the parser handles them and no function can
# take their place, which is why the refusal is written with them rather than
# with `[`.
_rb_left="$(builtin compgen -A function 2>/dev/null)$(declare -F 2>/dev/null)"
if [[ -n $_rb_left ]]; then
    echo "PR_SELFCHECK status=error reason=inherited_function name=${_rb_left%%$'\n'*}" >&2
    # `builtin exit` with a bare `exit` behind it: in THIS branch functions are
    # known to have survived, so the name doing the refusing may be one of them.
    builtin exit 2
    exit 2
fi
unset -v _rb_f _rb_left 2>/dev/null || true
# `BASH_ENV` GOES TOO — and the tracing variables with it — because a
# non-interactive `bash -c` SOURCES it and the
# workers report their verdict on stdout: a startup file that prints anything
# lands in the record stream and the parser refuses a run in which every test
# passed. Cleared in the parent so the tests the workers run are clean as well,
# and `ENV` with it for a shell invoked as `sh`.
#
# THIS CAN FAIL, and the workers do not depend on its having succeeded. A startup
# hook containing `readonly BASH_ENV` makes the variable unsettable here; the
# workers are launched through `env -u` instead, which removes it from their
# environment whatever this shell's attributes say.
# `BASH_XTRACEFD` IS NOT UNSET HERE, and that is not an omission. When it names
# fd 1, unsetting it makes bash CLOSE that descriptor — stdout — and every write
# after it fails with EBADF, which is a far worse outcome than the trace it was
# meant to stop. `set +x` above already turned tracing off, and the workers are
# launched with `env -u BASH_XTRACEFD`, so nothing downstream needs it gone from
# this shell.
unset -v BASH_ENV ENV 2>/dev/null || true
# …AND STRICT MODE IS APPLIED AGAIN, because the `set -uo pipefail` at the top of
# this file ran BEFORE the clearing and an exported `set() { return 0; }` would
# have swallowed it. The options were then off for the whole run: `pipefail` off
# is the dangerous half, since a middle stage that emits its normal output and
# then fails is invisible — `chk` sees the last stage's 0 and the gate reports a
# verdict from an extraction that did not complete.
#
# Cheap and unconditional rather than conditional on having detected anything: the
# cost is one builtin call, and deciding whether it is needed means trusting the
# same names again.
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
#
# `TMPDIR` AND `RANDOM` ARE THE SHELL'S OWN, in the same class as `HOME`, `PWD`
# and `SECONDS`: nothing in `SKILL.md` assigns them and nothing should. `TMPDIR`
# arrived with the transport file and was a standing finding from the round that
# added it — the gate was red on a name it had no way to be right about. Listing
# them keeps the finding meaning what it says: a variable the driver reads and
# nothing supplies.
if [ -f "$SKILL" ]; then
    KNOWN='HOME|PATH|PWD|SECONDS|TMPDIR|RANDOM|BASH_SOURCE|CLAUDE_PLUGIN_ROOT|REVIEW_BUS_REMOTE|REVIEW_BUS_OWNER|REVIEW_BUS_REPO|REVIEW_ROUND_THRESHOLD|REVIEW_MERGE_STRICT|PR_WATCH_INTERVAL|PR_WATCH_TIMEOUT|PR_CI_INTERVAL|PR_CI_TIMEOUT|PR_CI_GRACE|PR_CI_PROBE_TIMEOUT|1|2|3|4|5|6|7|8|9|0|@|\*|\?|#|!|_'

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

# ── 4b. no fixture pipes a value into an early-exiting reader ──────────────
#
# `printf … | grep -q PATTERN` is RACY under `set -o pipefail`, which every fixture
# sets. `grep -q` exits the moment it matches; `printf` is still writing, takes
# `SIGPIPE`, and dies with 141 — and `pipefail` makes that the PIPELINE's status.
# So a line that IS present reads as missing, at whatever rate the scheduler
# decides. Measured at roughly one run in three on one file.
#
# THAT IS WHY IT IS A GATE AND NOT A CONVENTION. The failure is intermittent, so a
# green run proves nothing about the next one, and every occurrence is a case that
# can report a defect that is not there — or, on an `|| x=""` capture, silently
# read as "nothing found". `test-pr-skill-contract.sh` spent three review rounds
# chasing one before the cause was found.
#
# A HERESTRING IS THE FIX: `grep -q PATTERN <<<"$value"` is a redirection, not a
# pipeline, so there is no second process to kill. `case … in` works too where the
# pattern is a glob.
#
# ONLY THE EARLY-EXITING READERS MATTER. `grep -c`, `sed` and `awk` without an
# `exit` read to end of input, so their pipelines never signal.
# THE SPELLINGS IT RECOGNISES, AND WHY THEY ARE NOT A LIST OF ONE. Two rounds of
# review were spent widening this, each finding an equivalent spelling the previous
# version reported clean: `printf "%s\n" …` with DOUBLE quotes, `grep -Fq` with the
# `q` second, `builtin printf … | command grep -q` — which twenty-four assertions
# in `test-pr-selfcheck.sh` used — and `grep -F -q` with the options split.
#
# WHAT IT DOES NOT DETECT IS THE PRODUCER BEING ANYTHING ELSE, and that is a
# stated limit rather than an oversight. `bodies | grep -qF …` races identically —
# any producer does — and generalising the pattern to "a pipeline whose last stage
# is `grep -q`" was tried and reverted in one round: `|` is not only a pipe. It
# appears in `||`, in `${got%%|*}`, inside quoted `awk` programs and inside `case`
# patterns, and telling those apart needs a shell PARSER. This repository has paid
# for one of those already — 2,200 lines and fifty-two review rounds — and the
# generalised version reported 140 false positives on a tree with no defect in it,
# which is a gate that cannot be pushed past rather than one that catches anything.
#
# SO THE GATE IS ANCHORED ON `printf`, which is the shape every occurrence in this
# suite actually had, and the OTHER producers are review's job — the reviewer files
# carry the rule. The sites Codex found by hand are converted; what is not
# guaranteed is that a new one is caught automatically.
#
# SO IT TAKES THE SHAPE, NOT A LIST: either quoting of the format string, any
# `command`/`builtin` prefix on EITHER side — the producer takes them too, which
# `command printf … | grep -q` walked past — any number of separate option words
# before the one carrying `q`, any number of INTERMEDIATE filters between the
# producer and the reader — `printf … | cut … | grep -qF` raced exactly the same
# way, with `cut` taking the signal instead of `printf` — and free spacing
# throughout. What it still cannot
# see is a pipeline assembled at runtime, which is the limit of reading text and is
# why this is a gate rather than a proof.
#
# AND WHAT IS EXEMPT IS MARKED, not guessed. This scans raw text, so a comment, a
# stub or a heredoc containing the spelling AS DATA cannot be told from code — and
# the fixture proving this gate works has to contain it. A line carrying
# `racy-pipeline-ok` is data by declaration; nothing else is exempt, and the marker
# is deliberately ugly so it is not reached for casually.
#
# THE SCAN'S OWN FAILURE IS NOT A CLEAN RESULT. A blanket `|| true` turned an
# unreadable fixture into an empty hit stream and a green gate. `awk` reports 0
# whether or not it matched anything, and non-zero only when it could not read the
# file or could not run — so any non-zero is a finding of its own.
pipeq=0
for f in "$SCRIPTS"/test-*.sh; do
    [ -e "$f" ] || continue
    hits="$(awk '
        { line = $0; n = FNR
          # A CONTINUED LINE AND A LINE ENDING IN A PIPE ARE BOTH ONE COMMAND.
          # `\` at the end is the obvious one; a trailing `|` continues just as
          # legally and needs no backslash, and the two halves scanned separately
          # were reported clean.
          while ((sub(/\\$/, "", line) || line ~ /\|[ \t]*$/) && (getline nxt) > 0)
              line = line " " nxt
          # WHITESPACE CLASSES, NOT LITERAL SPACES. `printf\t'"'"'%s'"'"'\t"$x"\t|\tgrep\t-q y` is
          # a legal fixture line and walked past a pattern written with ` +`.
          #
          # `||` IS NOT A PIPE, and it consumed the mandatory bar: `printf … || grep
          # -q y` has no pipeline and no risk, and was reported. Replacing it before
          # the test is safe HERE, where the match is anchored on `printf`, in a way
          # it was not for the generalised version.
          #
          # AND ANY WORD MAY SIT BETWEEN `grep` AND THE OPTION CARRYING `q`, rather
          # than a modelled option-and-argument grammar. Four rounds were spent
          # widening that grammar one legal spelling at a time — an option with an
          # argument, an argument with a hyphen in it, a quoted argument, a
          # THE SCAN ASKS THREE SUBSTRING QUESTIONS AND PARSES NOTHING. Does the
          # logical line name `printf`, does it carry a pipe, does it name `grep`.
          #
          # EVERYTHING ELSE WAS TRIED FIRST, and this is what it cost. Six review
          # rounds went into modelling grep'"'"'s options — an option with an argument,
          # a hyphenated argument, a quoted argument, a dash-leading operand, `-e`
          # attached to its pattern, `--`, `-qm1`, `--quiet` — each round widening a
          # grammar by one legal spelling and producing the next. Dropping the
          # options bought one round: the next found `%b`, an unquoted `$fmt`, a
          # quoted assignment value, `2>&1` before the pipe, `/usr/bin/grep`, and
          # `myprintf` matching on its suffix. Every one of those was a fact about
          # SHELL SYNTAX, and reading shell syntax out of text needs a shell.
          #
          # So the rule stops trying. There is no spelling of `printf`, of a pipe or
          # of `grep` that walks past a substring test, which is the whole class of
          # finding that took those seven rounds. `CLAUDE.md` records the same
          # treadmill costing 2,200 lines and fifty-two rounds once already.
          #
          # THE PRICE IS OVER-REPORTING, and it is paid in a form that is visible.
          # A line naming all three where the pipe is not the printf'"'"'s — a `printf`
          # inside a process substitution beside an unrelated pipeline, say — says
          # `racy-pipeline-ok`, which is the escape this check already had. There
          # are two in the tree. A false negative would be invisible and this is
          # not, which is why the price is paid in this direction.
          #
          # `||` IS NOT A PIPE, and that is the one thing still worth spelling: it
          # is replaced with a character that cannot be one, so
          # `printf '"'"'%s'"'"' "$x" || grep -q y` has no pipeline and no race.
          t = line; gsub(/\|\|/, ")", t)
          if (t ~ /printf/ && t ~ /\|/ && t ~ /grep/)
              printf "%d:%s\n", n, line
        }' "$f")"
    grc=$?
    if [ "$grc" -ne 0 ]; then
        echo "PR_SELFCHECK status=error reason=racy_scan_failed file=$(basename "$f") rc=$grc" >&2
        exit 2
    fi
    [ -n "$hits" ] || continue
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        case "$hit" in *racy-pipeline-ok*) continue ;; esac
        note racy_pipeline "$(basename "$f"): $(printf '%s' "$hit" | cut -c1-120)"
        pipeq=1
    done <<EOF
$hits
EOF
done

[ "$pipeq" -eq 0 ] && ok "no fixture pipes a printf into grep, which pipefail can turn into a false failure"

# ── 5. the suite passes ────────────────────────────────────────────────────
#
# RUN CONCURRENTLY, because the files are independent and this is the gate a
# person waits at. Each builds its own scratch directory under `mktemp -d`, stubs
# its own `gh`, and shares no state with any other — so the `for` loop this
# replaced was sequential for no reason beyond being the obvious thing to write.
# One after another it is ~208s; four at a time it is ~85s. See issue #52.
#
# ONLY HERE. The CI workflow keeps its loop: it wraps each file in a `::group::`
# and reports a failure with `::error file=`, and that structure is worth more on
# a machine nobody is waiting at than the wall clock is.
#
# THE DEGREE IS NOT DERIVED FROM THE MACHINE. `nproc` is one of the commands the
# `macos-shell` job asserts is UNREACHABLE, so sizing this from the core count
# would fail precisely where portability is being proven. Four is enough on any
# machine: the floor is the slowest single file, and that is most of the wall
# clock at four already.
#
# `xargs -P` rather than background jobs and `wait`, because `wait -n` is bash
# 4.3 and this suite runs on 3.2.57 in CI. `xargs` is on the mac-shaped PATH.
#
# NOTHING IS WRITTEN OUTSIDE THIS PROCESS. An earlier version put the list of
# files into a scratch directory under `TMPDIR` and spent five review rounds
# defending it: trust `mktemp`, validate its answer, take a subdirectory, create
# it outright, make it private, check the parent's sticky bit — and the next
# finding was a `TMPDIR` owned by another user, for which the sticky bit does
# nothing. Every one of those was real, and all of them were about a shared
# directory that this work never needed. The list is a shell array here: nothing
# is written to a filesystem, and each path reaches its worker as an argument
# rather than through a file anyone else can reach.
#
# THE PATH TRAVELS OUTWARD AND ONLY THE INDEX COMES BACK. Each worker is handed
# the exact path the parent captured, paired with its index; it runs that path and
# answers with the index. Nothing is resolved twice — an intermediate version had
# the worker re-glob to find its own file, and a test that renamed itself then
# made one index name a different file, so one test ran twice and another never
# ran while every record still came back a pass. Outward the path is safe because
# the records are NUL-delimited; inward an index is safe because it cannot carry
# a delimiter at all.
suite_fail=0
suite_jobs="${RB_SUITE_JOBS:-4}"
# THE SAME VALIDATION SHAPE THE CI GATE USES, and for the same reason: a bad value
# falls back rather than disabling the bound. Leading zeros are rejected rather
# than read as digits — `xargs -P 0` is UNLIMITED parallelism, so `00` satisfying
# a digits-only test would start every file at once and defeat the load bound
# this degree exists to be. Six digits or more is refused for the same reason a
# bound is refused anywhere here: it is not a degree, it is a typo.
case "$suite_jobs" in ""|0*|*[!0-9]*|??????*) suite_jobs=4 ;; esac
# THE NAMES ARE CAPTURED BEFORE ANYTHING RUNS, in this process, in an array. The
# first version globbed a second time to turn a failing index back into a name,
# and a test that deletes itself — `rm "$0"; exit 1` — made that second walk one
# entry shorter: the failing index matched nothing, no finding was recorded, and
# the gate printed `status=clean` over a test it had just watched fail. An array
# also means the parent's copy is authoritative: what travels to a worker is a
# NUL-delimited record, which carries any path, but what NAMES a failure here is
# the array entry captured before anything ran.
suite_files=0
suite_names=()
for t in "$SCRIPTS"/test-*.sh; do
    [ -e "$t" ] || continue
    suite_files=$((suite_files + 1))
    suite_names[$suite_files]="$t"
done
if [ "$suite_files" -gt 0 ]; then
    # `builtin` FOR `printf`, `command` FOR THE REST. A function shadows any name,
    # builtin or external, so the records themselves are as forgeable as the tools
    # that carry them: an exported `printf` that rewrites `F %s` to `P %s` turns a
    # failing worker's record into a passing one at the moment it is written, and
    # everything downstream sees a complete, correctly ordered, all-passing set.
    #
    # The two bypasses are not interchangeable. `command printf` would run
    # `/usr/bin/printf`, a different program with its own quirks; `builtin xargs`
    # does not exist. Each name takes the one that means "the real thing" for what
    # it is.
    #
    # `note` and `ok` are deliberately NOT hardened. A shadowed `printf` there
    # changes the TEXT of a finding, not whether one was recorded — the counter
    # still increments and the gate still exits non-zero — so it cannot forge a
    # clean verdict, which is the property being defended.
    #
    # `command` ON EVERY EXTERNAL HERE, because an exported shell function is
    # inherited by this process and shadows the name. That is not hypothetical in
    # this file: an exported `umask` function defeated the scratch directory's
    # narrowing two rounds before the directory itself was removed. Here the stakes
    # are the verdict — `sort() { sed 's/^F /P /'; }` turns a failing record into a
    # passing one and the validator sees a complete, correctly ordered set, and an
    # `xargs` function can print a whole passing set without running anything.
    #
    # `command` bypasses functions and keeps ordinary PATH resolution, which is
    # exactly the distinction wanted: a stub earlier on PATH is how this suite
    # TESTS the gate, so those must still work.
    #
    # `bash` inside the worker is on this list too. `xargs` execs it directly, so
    # that one is resolved by PATH — but the `bash "$p"` inside the worker's own
    # script is not, and a function there chooses what runs instead of the test.
    #
    # EVERY WORKER REPORTS, PASS OR FAIL, and the parent requires one record per
    # index. Checking only for failures cannot tell "nothing failed" from "nothing
    # ran": an inherited `xargs() { return 0; }` consumes no input, exits 0 and
    # prints nothing, and so does a no-op `sort` handed the failure list — both
    # produce exactly what a clean suite produces. A status check does not see it
    # either, because they SUCCEED. Only counting the answers does.
    #
    # `M` is the third answer: the index no longer names a file, which means the
    # directory changed under the run. It is not a failing test and not a passing
    # one, and it is the only honest thing to say about a result that cannot be
    # attributed.
    # THE WORKER RUNS THE PATH IT WAS GIVEN. It used to receive an index and
    # resolve it against a fresh glob, which is a second walk of the directory
    # with the same failure as the first one had: a test that renames itself so it
    # sorts elsewhere makes index n name a DIFFERENT file, so one test runs twice
    # and another never runs at all — and a complete set of passes then reports
    # clean over a test nobody executed.
    #
    # Each record is `<index>:<path>`, NUL-delimited so the path survives `xargs`
    # whatever it contains, and split on the FIRST colon so a path may contain one.
    # The index is what comes back, because an index cannot carry a delimiter; the
    # path only ever travels outward.
    #
    # `-n 1` RATHER THAN `-I`, and that is a portability rule, not a style. BSD
    # `xargs` caps a replacement string at 255 bytes (`-S replsize`), so with `-I`
    # a checkout nested deeply enough to push a path past that would fail this
    # gate on stock macOS while GNU CI stayed green — the exact class of defect
    # that is invisible on the machine that writes it. Appending the record as an
    # argument has no such limit.
    # NO `command` PREFIX ON WHAT `xargs` RUNS, and the reason is not style. `xargs`
    # execs its program itself — there is no shell in between — so `command env …`
    # asks it to run a program CALLED `command`. That is a shell builtin, not a
    # file, on nearly every system: this machine happens to have a 35-byte
    # `/usr/bin/command`, so it worked here and every fixture failed on CI with
    # `suite_runner_failed`. Function shadowing cannot reach an `execvp` anyway,
    # so the prefix bought nothing even where it resolved.
    suite_out="$(n=0
        while [ "$n" -lt "$suite_files" ]; do
            n=$((n + 1))
            builtin printf '%s:%s\0' "$n" "${suite_names[$n]}"
        done | command xargs -0 -P "$suite_jobs" -n 1 \
            env -u BASH_ENV -u ENV -u SHELLOPTS -u BASH_XTRACEFD bash -c '
            rec="$1"
            i="${rec%%:*}"
            p="${rec#*:}"
            # The file going missing between the parent listing it and this worker
            # reaching it is the one thing left that the parent cannot see. It is
            # neither a pass nor a failure.
            [ -e "$p" ] || { builtin printf "M %s\n" "$i"; exit 0; }
            if command bash "$p" >/dev/null 2>&1; then builtin printf "P %s\n" "$i"
            else builtin printf "F %s\n" "$i"; fi
            exit 0
        ' _)"; suite_rc=$?
    # The runner's status is still taken. It is no longer the only thing taken,
    # but a runner that fails outright should say so with its own reason rather
    # than arriving at the count check as a mystery.
    [ "$suite_rc" -eq 0 ] || {
        echo "PR_SELFCHECK status=error reason=suite_runner_failed rc=$suite_rc jobs=$suite_jobs" >&2
        exit 2
    }
    # Sorted numerically — these are numbers, and a lexical sort puts 10 before 2 —
    # so the findings come out in the glob's order rather than the order the
    # machine happened to finish in. A gate whose output reshuffles between runs is
    # a gate people stop reading.
    suite_sorted="$(builtin printf '%s\n' "$suite_out" | command sort -k2 -n)" || {
        echo "PR_SELFCHECK status=error reason=suite_sort_failed" >&2
        exit 2
    }
    # EVERY INDEX EXACTLY ONCE, WHICH A TOTAL DOES NOT ESTABLISH. Counting records
    # and comparing the total was not the rule this comment claimed: a runner that
    # printed `P 1` twice satisfied it with two files, so neither test needed to
    # run and the gate reported clean. The records arrive sorted by index, so the
    # nth of them must BE index n — one comparison that rejects a duplicate, a
    # gap, and an index outside the range alike.
    suite_seen=0
    suite_failed=()
    # No `IFS=` prefix here either, for the same reason: these records are
    # `<letter> <digits>`, generated by this file, with nothing at either end for
    # `read` to trim — and a prefix that a readonly `IFS` can fail is a dependency
    # this loop does not need.
    while read -r rec; do
        [ -n "$rec" ] || continue
        suite_seen=$((suite_seen + 1))
        case "$rec" in
            "P "*|"F "*|"M "*) ;;
            *) echo "PR_SELFCHECK status=error reason=suite_record_malformed" >&2
               exit 2 ;;
        esac
        idx="${rec#? }"
        case "$idx" in
            ""|*[!0-9]*) echo "PR_SELFCHECK status=error reason=suite_record_malformed" >&2
                         exit 2 ;;
        esac
        [ "$idx" = "$suite_seen" ] || {
            echo "PR_SELFCHECK status=error reason=suite_record_unexpected index=$idx want=$suite_seen" >&2
            exit 2
        }
        case "$rec" in
            "F "*) suite_failed[${#suite_failed[@]}]="$idx" ;;
            "M "*) echo "PR_SELFCHECK status=error reason=suite_index_unmapped index=$idx" >&2
                   exit 2 ;;
        esac
    done <<EOF
$suite_sorted
EOF
    # …and the last index seen must be the last file. The check above catches a
    # gap or a duplicate anywhere before the end; this catches the tail simply
    # being absent.
    [ "$suite_seen" -eq "$suite_files" ] || {
        echo "PR_SELFCHECK status=error reason=suite_incomplete ran=$suite_seen of=$suite_files" >&2
        exit 2
    }
    # The names come from the list captured before the run, so a failing index
    # ALWAYS resolves to the file that failed.
    # AN ARRAY, SO NOTHING SPLITS IT. This was a space-separated string, and the
    # only unquoted expansion left in the verdict path: `IFS=-` from a startup
    # hook turned the whole list into one subscript, and two failing tests went
    # unreported. Normalising `IFS` fixed that until a hook declared it `readonly`,
    # which no assignment can undo — so the dependency is gone rather than guarded.
    #
    # Subscripted by count rather than `+=`, and guarded by the count rather than
    # expanded blind: bash 3.2 treats `"${arr[@]}"` on an empty array as an unbound
    # variable under `set -u`, and CI runs 3.2.
    for idx in ${suite_failed[@]+"${suite_failed[@]}"}; do
        t="${suite_names[$idx]-}"
        [ -n "$t" ] || {
            echo "PR_SELFCHECK status=error reason=suite_failure_unnamed index=$idx" >&2
            exit 2
        }
        b="$(command basename "$t")"
        # ONE LINE PER FINDING, whatever the name contains. A newline inside a
        # filename would otherwise print as two findings to anything reading this
        # output.
        b="$(builtin printf '%s' "$b" | command tr '\n' ' ')"
        note failing_test "$b fails"; suite_fail=1
    done
fi
[ "$suite_fail" -eq 0 ] && ok "the whole suite passes"

if [ "$findings" -gt 0 ]; then
    echo "PR_SELFCHECK status=findings count=$findings"
    exit 1
fi
echo "PR_SELFCHECK status=clean count=0"
exit 0
