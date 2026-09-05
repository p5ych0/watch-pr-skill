#!/usr/bin/env bash
# No `-e`: statuses are control flow here.
set -uo pipefail

# Re-exec once with the hook variables removed, guarded by a marker rather than by the evidence: a hook can
# `unset BASH_ENV` on its way out and leave a `readonly -f` function nothing here can clear.
if [[ -z ${RB_SELFCHECK_CLEAN-} ]]; then
    RB_SELFCHECK_CLEAN=1 exec env -u BASH_ENV -u ENV -u SHELLOPTS -u BASH_XTRACEFD bash "$0" "$@"
fi
# Or every child inherits the marker and skips its own re-exec.
unset -v RB_SELFCHECK_CLEAN 2>/dev/null || true

# Every inherited function, not a list of names; the enumerators and `read` first, without a prefix, since a
# prefix is one more name to trust. `unset` itself can be shadowed, and that regress has no terminator.
unset -f unset builtin command compgen declare read 2>/dev/null || true
# Read from a quoted here-string, with no `IFS=` prefix: a glob-shaped name imports and would expand unquoted,
# a readonly `IFS` fails the assignment, and a function name cannot contain whitespace.
while read -r _rb_f; do
    [ -n "$_rb_f" ] || continue
    builtin unset -f -- "$_rb_f" 2>/dev/null || true
done <<< "$(builtin compgen -A function 2>/dev/null)"
# After the clearing rather than before it, since an inherited `SHELLOPTS=xtrace` with `BASH_XTRACEFD=1` puts
# the trace on stdout inside every substitution below.
set +x

# One call through the prefix and one direct, so a forged `builtin` has to cover `declare` consistently too.
_rb_left="$(builtin compgen -A function 2>/dev/null)$(declare -F 2>/dev/null)"
if [[ -n $_rb_left ]]; then
    echo "PR_SELFCHECK status=error reason=inherited_function name=${_rb_left%%$'\n'*}" >&2
    # Functions are known to have survived here, so the name doing the refusing may be one of them.
    builtin exit 2
    exit 2
fi
unset -v _rb_f _rb_left 2>/dev/null || true
# Cleared here so the tests the workers run are clean too; it can fail under a readonly `BASH_ENV`, which the
# workers' `env -u` covers. Not `BASH_XTRACEFD`: unsetting it when it names fd 1 closes stdout.
unset -v BASH_ENV ENV 2>/dev/null || true
# Again, because the first ran before the clearing and an exported `set` would have swallowed it.
set -uo pipefail

# The root lookup takes its status: `git rev-parse` can print a plausible directory and exit non-zero.
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

# Most repositories are not this plugin, and "not applicable" is its own status, since printed beside exit 0
# it reads as a clean run. Not resolved relative to this script, which would check the installed copy.
if [ ! -f "$SKILL" ] || [ ! -d "$SCRIPTS" ]; then
    echo "PR_SELFCHECK status=not_applicable reason=not_a_watch_pr_skill_checkout root=$ROOT"
    exit 3
fi

findings=0
note() { printf 'PR_SELFCHECK finding=%s %s\n' "$1" "$2"; findings=$((findings + 1)); }
ok()   { printf 'ok   - %s\n' "$1"; }

if [ -f "$SKILL" ]; then
    # Listed, not inferred, so adding a driver input is deliberate; `TMPDIR` and `RANDOM` are the shell's own.
    KNOWN='HOME|PATH|PWD|SECONDS|TMPDIR|RANDOM|BASH_SOURCE|CLAUDE_PLUGIN_ROOT|REVIEW_BUS_REMOTE|REVIEW_BUS_OWNER|REVIEW_BUS_REPO|REVIEW_ROUND_THRESHOLD|REVIEW_MERGE_STRICT|WATCH_PR_AUTONOMOUS|PR_WATCH_INTERVAL|PR_WATCH_TIMEOUT|PR_CI_INTERVAL|PR_CI_TIMEOUT|PR_CI_GRACE|PR_CI_PROBE_TIMEOUT|1|2|3|4|5|6|7|8|9|0|@|\*|\?|#|!|_'

    # One strict checker: `nomatch` turns a single grep's "no matches" 1 into 0 where the exception is, so any
    # non-zero anywhere in a pipeline is a broken read rather than an empty answer.
    chk() {
        if [ "$2" -ne 0 ]; then
            echo "PR_SELFCHECK status=error reason=extraction_failed step=$1 rc=$2" >&2
            exit 2
        fi
    }
    nomatch() {
        "$@" || [ "$?" -eq 1 ]
    }

    blocks="$(awk '/^```bash$/{inb=1; next} /^```$/{inb=0} inb' "$SKILL")"; chk blocks $?
    if [ -z "$blocks" ]; then
        echo "PR_SELFCHECK status=error reason=no_bash_blocks_in_skill" >&2
        exit 2
    fi
    # Full-line comments are dropped first, since prose read as shell silences the check.
    code="$(printf '%s\n' "$blocks" | nomatch grep -vE '^[[:space:]]*#')"; chk strip_comments $?
    # Only where an assignment can occur, since `NAME=` after any whitespace credits `echo "NAME=$NAME"`; a `{` counts
    # only after a separator, and a `;` inside a quoted string still matches.
    assigned="$(printf '%s\n' "$code" \
        | nomatch grep -oE '(^|;|&&|\|\|)[[:space:]]*(\{[[:space:]]+)?(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' \
        | sed -E 's/^[;&|{[:space:]]*(local[[:space:]]+)?//; s/^[{[:space:]]*//; s/=$//' | sort -u)"; chk assigned $?
    # Discovered from the `.` lines, never listed: a stale list silences findings indistinguishably from a clean run.
    sourced="$(printf '%s\n' "$code" \
        | nomatch grep -oE '^\.[[:space:]]+"\$RB_SCRIPTS/[A-Za-z0-9_.-]+"' \
        | sed -E 's#^.*/##; s/"$//' | sort -u)"; chk sourced $?
    for lib in $sourced; do
        if [ ! -f "$SCRIPTS/$lib" ]; then
            echo "PR_SELFCHECK status=error reason=sourced_lib_missing lib=$lib" >&2
            exit 2
        fi
        # The library declares what it assigns: inferring it from the body credits assignments sourcing never runs, and
        # a wrong answer there reads as "this variable is fine". No declaration is an error for the same reason.
        libassigned="$(nomatch grep -oE '^# rb-assigns:[A-Za-z0-9_ ]*' "$SCRIPTS/$lib" \
            | sed -E 's/^# rb-assigns:[[:space:]]*//' | tr ' ' '\n' \
            | nomatch grep -vE '^$' | sort -u)"; chk lib_assigned $?
        if [ -z "$libassigned" ]; then
            echo "PR_SELFCHECK status=error reason=lib_declares_no_assignments lib=$lib" >&2
            exit 2
        fi
        assigned="$(printf '%s\n%s\n' "$assigned" "$libassigned" | sort -u)"; chk merge_lib $?
    done
    # Only `for NAME in` at the start of a line: any wider pattern matches inside prose and quoted strings, and
    # the cost is a loud false positive rather than a silent false negative.
    forvars="$(printf '%s\n' "$code" \
        | nomatch grep -oE '^[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in([[:space:]]|$)' \
        | awk '{print $2}' | sort -u)"; chk forvars $?
    assigned="$(printf '%s\n%s\n' "$assigned" "$forvars" | sort -u)"; chk merge_assigned $?
    # Uppercase names only: jq's and GraphQL's `$name`s live in multi-line single-quoted programs, and telling
    # them apart otherwise needs a lexer. A lowercase shell variable used and never assigned slips past.
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

parse_bad=0
for f in "$SCRIPTS"/*.sh; do
    [ -e "$f" ] || continue
    bash -n "$f" 2>/dev/null || { note syntax_error "$(basename "$f") does not parse"; parse_bad=1; }
done
[ "$parse_bad" -eq 0 ] && ok "every script under scripts/ parses"

# Built and its status taken before the loop: an empty list from a failed pipeline passes every helper as present.
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

unpinned=0
# Over `$code` rather than the file, so a command quoted in prose is not a call; continuations are joined
# first, since `--repo` on a second physical line is pinned.
joined="$(printf '%s\n' "$code" | sed -e :a -e '/\\$/N; s/\\\n//; ta')"
chk join_continuations $?
gh_lines="$(printf '%s\n' "$joined" | nomatch grep -E 'gh pr (comment|view|edit|merge|checks|close|ready)[[:space:]]')"
chk gh_lines $?
if [ -n "$gh_lines" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # Every occurrence on the line, judged on its own three tokens by position: an assignment beside a call
        # cannot vouch for it, and splitting the line into commands needs a quote-aware parser.
        occ="$(printf '%s\n' "$line" \
            | nomatch grep -oE 'gh pr (comment|view|edit|merge|checks|close|ready)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+')"
        chk gh_occurrences $?
        # Fewer occurrences than verbs means a call too short to examine, which is not one that passed.
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

untested=0
# The libraries too, discovered by glob: a list of covered files goes stale silently.
for f in "$SCRIPTS"/pr-*.sh "$SCRIPTS"/*lib.sh; do
    [ -e "$f" ] || continue
    # `*lib.sh` also matches `test-testlib.sh`.
    case "$(basename "$f")" in test-*) continue ;; esac
    b="$(basename "$f" .sh)"
    [ -f "$SCRIPTS/test-$b.sh" ] || { note untested_script "$b.sh has no test-$b.sh"; untested=1; }
done
[ "$untested" -eq 0 ] && ok "every helper and shared library has a matching test"

# `printf … | grep -q` races under `pipefail`: `grep -q` exits on its match, `printf` takes SIGPIPE, and 141
# becomes the pipeline's status, so a present line reads as missing. A scan that cannot run is an error, not a clean result.
pipeq=0
for f in "$SCRIPTS"/test-*.sh; do
    [ -e "$f" ] || continue
    hits="$(awk '
        { line = $0; n = FNR
          # A trailing pipe continues a line as legally as a trailing backslash.
          while ((sub(/\\$/, "", line) || line ~ /\|[ \t]*$/) && (getline nxt) > 0)
              line = line " " nxt
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
        # The scan reads raw text, so a line carrying the spelling as data says so with the marker.
        case "$hit" in *racy-pipeline-ok*) continue ;; esac
        note racy_pipeline "$(basename "$f"): $(printf '%s' "$hit" | cut -c1-120)"
        pipeq=1
    done <<EOF
$hits
EOF
done

[ "$pipeq" -eq 0 ] && ok "no fixture pipes a printf into grep, which pipefail can turn into a false failure"

suite_fail=0
# Not derived from the core count: `nproc` is unreachable on the macOS job.
suite_jobs="${RB_SUITE_JOBS:-4}"
# A leading zero is refused: `xargs -P 0` is unlimited parallelism.
case "$suite_jobs" in ""|0*|*[!0-9]*|??????*) suite_jobs=4 ;; esac
suite_files=0
# Captured in an array before anything runs: a test that renames or deletes itself must still be named by
# the index that failed.
suite_names=()
for t in "$SCRIPTS"/test-*.sh; do
    [ -e "$t" ] || continue
    suite_files=$((suite_files + 1))
    suite_names[$suite_files]="$t"
done
if [ "$suite_files" -gt 0 ]; then
    # `builtin printf` and `command` on every external, since a shadowed `sort` or `printf` can rewrite a failing record
    # into a passing one; nothing on what `xargs` runs, which execs it without a shell; `-n 1`, as BSD `xargs -I` caps at 255 bytes.
    suite_out="$(n=0
        while [ "$n" -lt "$suite_files" ]; do
            n=$((n + 1))
            builtin printf '%s:%s\0' "$n" "${suite_names[$n]}"
        done | command xargs -0 -P "$suite_jobs" -n 1 \
            env -u BASH_ENV -u ENV -u SHELLOPTS -u BASH_XTRACEFD bash -c '
            rec="$1"
            i="${rec%%:*}"
            p="${rec#*:}"
            # Gone between the listing and here is neither a pass nor a failure.
            [ -e "$p" ] || { builtin printf "M %s\n" "$i"; exit 0; }
            if command bash "$p" >/dev/null 2>&1; then builtin printf "P %s\n" "$i"
            else builtin printf "F %s\n" "$i"; fi
            exit 0
        ' _)"; suite_rc=$?
    [ "$suite_rc" -eq 0 ] || {
        echo "PR_SELFCHECK status=error reason=suite_runner_failed rc=$suite_rc jobs=$suite_jobs" >&2
        exit 2
    }
    # Numerically, or 10 sorts before 2.
    suite_sorted="$(builtin printf '%s\n' "$suite_out" | command sort -k2 -n)" || {
        echo "PR_SELFCHECK status=error reason=suite_sort_failed" >&2
        exit 2
    }
    # Every index exactly once: a total is satisfied by `P 1` printed twice, and a status check by an `xargs`
    # that runs nothing and exits 0.
    suite_seen=0
    suite_failed=()
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
    # The check above cannot see a missing tail.
    [ "$suite_seen" -eq "$suite_files" ] || {
        echo "PR_SELFCHECK status=error reason=suite_incomplete ran=$suite_seen of=$suite_files" >&2
        exit 2
    }
    # Guarded expansion: bash 3.2 treats an empty array as unbound under `set -u`.
    for idx in ${suite_failed[@]+"${suite_failed[@]}"}; do
        t="${suite_names[$idx]-}"
        [ -n "$t" ] || {
            echo "PR_SELFCHECK status=error reason=suite_failure_unnamed index=$idx" >&2
            exit 2
        }
        b="$(command basename "$t")"
        # One line per finding, whatever the name contains.
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
