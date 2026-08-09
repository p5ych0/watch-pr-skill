#!/usr/bin/env bash
# GNU-only constructs must not reach this tree.
#
# Four have, and each was caught by review rather than by a check: `timeout`,
# `sha1sum`, `seq`, and `\s` in a `grep` pattern. The whole suite is a MANDATORY
# PRE-PUSH GATE, so any one of them stops a macOS contributor from closing a
# review round while Ubuntu CI stays green — the failure is invisible on the
# machine that introduces it, which is why review kept being the thing that caught
# it. Issue #15.
#
# WHAT THIS FILE CAN AND CANNOT DO, because the difference decides the design.
#
# Absence is testable by RUNNING: the `portability` CI job runs this whole suite
# with the GNU-only commands removed from `PATH`. It catches a name this file
# cannot see — `_a=sha1; _b=sum; "$_a$_b"` is invisible to any scan and dies there
# at once. It runs in PARALLEL with the normal job, so it does not double the
# time: measured, 9m15s against the normal 6m35s, and the job is the slower of the
# two precisely because `run_limited` falls back to polling with `sleep` when
# `timeout` is gone. Parallel is not free, it is the difference rather than the
# sum.
#
# BUT IT ONLY CATCHES A USE WHOSE FAILURE PROPAGATES, and that is measured rather
# than assumed. `for i in $(seq 1 5)` with `seq` gone yields an empty list and the
# loop simply does not run: the suite passes and the defect ships. So the job is
# not a superset of these scans, and neither is a superset of it — each catches
# cases the other cannot, which is why both exist.
#
# Behaviour differences are not testable by absence at all: GNU `grep` is present
# on the runner and happily accepts `\s`, GNU `sed` accepts `-i` with no suffix.
# Nothing fails until someone runs it on BSD. Those need text, and text is what
# this file does.
#
# A WHITELIST WAS ATTEMPTED AND ABANDONED, and the reason is recorded so it is not
# attempted again. The terminating form of this check would be "every command
# invoked must be on a permitted list" — a blacklist is always one name behind.
# Extracting command position from shell needs a lexer: measured over this tree,
# the words in apparent command position were about 40% English, from strings and
# from the embedded jq and awk programs — `the`, `and`, `see`, `was`. Filtering by
# "is this an executable here" makes the answer differ per machine, which is the
# exact failure this issue is about. CLAUDE.md records a structural checker built
# and deleted six times for this reason; this is not the seventh.
#
# So the split is: the CI job terminates the command class behaviourally, and the
# scans below cover what only text can — with each one's closure stated.
set -Eeuo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# Full-line comments are dropped before anything is inferred from the text. A
# comment is not code, and this file's own prose names every construct it forbids
# — scanning it unstripped would report itself. Inline comments are NOT stripped,
# because a `#` inside a quoted string is not a comment and telling them apart is
# the lexer this file declines to write; a construct named in an inline comment is
# a false positive, which is the loud direction.
#
# A SCAN THAT CANNOT READ ITS INPUT IS NOT A CLEAN SCAN. One `awk` pass, one
# status: `awk` has no "no match" exit code, so any non-zero is a real failure and
# anything on stderr is too.
#
# THE RULES SEE A LOGICAL LINE, NOT A PHYSICAL ONE. `grep -qE \` on one line and
# its pattern on the next satisfied neither predicate of any rule — the command was
# on one side of the backslash and the `\s` on the other, and the scan reported
# clean. Continuations are joined here, once, so every rule inherits it; `start`
# carries the FIRST physical line number, because that is where a reader has to
# look.
#
# Full-line comments are dropped BEFORE joining. A comment cannot continue a
# command, and stripping after the join would let a commented-out continuation
# glue two unrelated statements together.
SCAN_PROLOGUE='
    function report(msg) { print FILENAME ":" start ": " msg }
    { raw = $0; sub(/^[[:space:]]*#.*$/, "", raw)
      if (buf == "") start = FNR
      if (raw ~ /\\$/) { sub(/\\$/, " ", raw); buf = buf raw; next }
      line = buf raw; buf = "" }
'
SCAN_EPILOGUE='
    END { if (buf != "") { line = buf; RULES() } }
'
scan() {   # scan <awk-rule-body> <file…> ; prints hits, 2 if the scan failed
    local prog="$1"; shift
    local errf out rc msg mrc
    errf="$(mktemp)" || return 2
    rc=0
    # The body is wrapped in a function so the END block can run it on a trailing
    # unterminated continuation — a file whose last line ends in a backslash would
    # otherwise never be examined at all.
    out="$(awk "$SCAN_PROLOGUE"'
        { RULES() }
        function RULES() {'"$prog"'}
    '"$SCAN_EPILOGUE" "$@" 2>"$errf")" || rc=$?
    msg="$(cat "$errf" 2>/dev/null)"; mrc=$?
    rm -f "$errf" 2>/dev/null
    [ "$mrc" -eq 0 ] || return 2
    [ "$rc" -eq 0 ] || return 2
    [ -z "$msg" ] || return 2
    printf '%s' "$out"
    return 0
}

# ── RULE A: GNU regex escapes, on lines that run a regex engine ────────────
#
# THE CHARACTER-CLASS HALF TERMINATES, and the argument is worth stating: POSIX BRE
# and ERE define no backslash-class escapes at all, so `\s \S \d \D \w \W` and the
# `\b \B` boundaries are the COMPLETE set of what GNU and PCRE add there. A ninth
# cannot appear. That is what makes a blacklist adequate for this and inadequate
# for a command name.
#
# THE OPERATOR HALF DOES NOT TERMINATE, and pretending otherwise is how `\y` was
# missed on the first pass. gawk defines word-boundary operators of its own —
# `\y`, and `\<`/`\>` which BSD spells `[[:<:]]`/`[[:>:]]` — and a future gawk can
# define more. Those are a blacklist like the command list, and are stated as one.
#
# BSD `grep` reads `\s` as a literal `s`, so the pattern silently matches
# something else rather than failing — which is how the one in
# `test-pr-skill-contract.sh` survived: the guard reported PASS while its stated
# invariant went unchecked.
#
# Restricted to lines that mention `grep`, `sed` or `awk`, because jq's engine is
# Oniguruma and DOES support these — a jq program using `\s` is correct, and a
# scan that flagged it would be deleted rather than obeyed. That restriction is
# also this rule's hole: a pattern assembled into a variable and used with `grep`
# on another line is not seen. Stated, not silently accepted.
#
# `\b` IS SPLIT BY ENGINE, and this is why gawk invented `\y`. In `grep` and `sed`
# `\b` is the GNU word boundary; in awk it is the standard BACKSPACE escape, and
# `awk 'BEGIN { printf "\b" }'` is portable code that the first version of this
# rule rejected — a mandatory gate failing on something correct, which is how a
# check gets switched off. A line naming grep or sed takes the stricter rule, so a
# line naming both is judged by the boundary meaning.
#
# UPPERCASE `\B` STAYS IN THE awk SET. The backspace exemption is for lowercase
# `\b` only — gawk defines `\B` as a within-word operator, and exempting the pair
# together let `awk '/foo\Bbar/'` through.
RULE_A='
    if (line ~ /(grep|sed)/ && line ~ /\\[sSdDwWbBy<>]/) {
        report("GNU regex escape: " line); return }
    if (line ~ /awk/ && line ~ /\\[sSdDwWBy<>]/) {
        report("gawk-only regex operator: " line); return }'

# ── RULE B: GNU-only commands must be `command -v`-guarded ─────────────────
#
# A blacklist, and one name behind by construction — the CI job is what covers the
# class. What it buys is speed and precision in the pre-push gate for the names
# that have actually reached this tree.
#
# It requires a GUARD, not absence. `testlib.sh` runs `timeout` and
# `test-pr-round-count.sh` runs `sha1sum`, both correctly: each probes with
# `command -v` and has a fallback. That is the pattern a contributor reaching for
# any new tool should be using, so it is the pattern that passes.
#
# COMMAND POSITION, not word presence. `timeout` appears 132 times in this tree as
# a word — `state=timeout`, assertion prose, a JSON error payload — and a
# word-presence check would report all of it. The positions are line start and the
# operators that begin a command, plus the two wrappers this tree invokes commands
# through. `{` is among them because a one-line function body — `f() { seq 1 3; }`
# — puts the command straight after a brace, and that spelling walked past the
# first version of this list. `${name}` is not a false positive: the name there is
# followed by `}` or `_`, never by whitespace.
GNU_ONLY_COMMANDS='timeout sha1sum sha256sum md5sum seq realpath tac shuf nproc
                   stdbuf truncate dircolors gsed gawk gdate gcp gln gsort'
#
# A CONDITION IS A COMMAND POSITION. `if seq 1 5; then …; fi` runs `seq`, and with
# it absent the condition is merely false — an `if` whose branches all fail still
# returns 0, so the CI job stays green too and both checks miss it. `while`,
# `until`, `elif` and a leading `!` are the same shape.
# The keyword branch carries its OWN left boundary — `(^|[[:space:]])` — because a
# keyword can begin the line. Written as ` if ` it required a space in front, so
# `if seq 1 5; then …` at column one walked past while an indented one was caught:
# a position list that depends on indentation.
#
# `)` IS A COMMAND POSITION TOO: it ends a `case` pattern, and
# `case x in x) seq 1 5; : ;; esac` runs `seq` there. With the command gone the
# failed lookup is followed by `:`, so the arm returns 0 and the portability job
# passes as well — both checks missing it.
CMD_POS='(^|[|;&({!)]|\$\(|&&|\|\||(^|[[:space:]])(exec|env|then|else|do|if|elif|while|until|run_limited [0-9]+)[[:space:]])[[:space:]]*'

# ── RULE C: GNU-only flags on commands that do exist ───────────────────────
#
# Also a blacklist, and one flag behind. Absence cannot catch these at all: the
# commands are present everywhere, and GNU accepts the flag — only BSD rejects it.
#
#   sed -i        THERE IS NO PORTABLE SPELLING, which is why every form is
#                 rejected rather than one being recommended. BSD requires a
#                 suffix argument, so `sed -i 's/a/b/' f` eats the script as the
#                 suffix. GNU documents the option as `-i[SUFFIX]` — attached — so
#                 `sed -i '' 's/a/b/' f` makes the empty string the SCRIPT and the
#                 substitution an input filename. The two requirements cannot both
#                 be met by one command line. Write a temp file and `mv` it.
#   sed -r        GNU spelling of `-E`, which is the portable one.
#   readlink -f   BSD readlink has no -f.
#   grep -P       PCRE, GNU-only.
#   date -d       BSD date uses -v and -j -f.
#   stat -c       BSD stat uses -f.
#   xargs -r      BSD xargs does not run empty by default, so -r is both
#                 unsupported and unnecessary.
#   sort -h       GNU-only.
#
# THE FORBIDDEN FLAG NEED NOT COME FIRST. `grep -n -P`, `sed -n -r`, `stat -L -c`:
# each rule reads through the whole option sequence, because a version that
# examined only the first option word reported those clean — and the portability
# job cannot help, since `grep`, `sed` and `stat` are present everywhere and only
# BSD rejects the flag.
#   echo -e       Not portable in any shell; `printf` is.
RULE_C='
    { line = $0; sub(/^[[:space:]]*#.*$/, "", line) }
    if (line ~ /(^|[^a-zA-Z_-])sed[[:space:]]+-i([[:space:]]|$)/) {
        report("sed -i has no portable spelling; write a temp file and mv: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])sed([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+-[A-Za-z]*r([[:space:]]|$)/) {
        report("sed -r is the GNU spelling of -E: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])readlink([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+-[A-Za-z]*f([[:space:]]|$)/) {
        report("readlink -f is GNU-only: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])grep([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+-[A-Za-z]*P([[:space:]]|$)/) {
        report("grep -P is GNU-only: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])date([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+-[A-Za-z]*d([[:space:]]|$)/) {
        report("date -d is GNU-only: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])stat([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+-[A-Za-z]*c([[:space:]]|$)/) {
        report("stat -c is GNU-only: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])xargs([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+-[A-Za-z]*r([[:space:]]|$)/) {
        report("xargs -r is GNU-only: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])sort([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+-[A-Za-z]*h([[:space:]]|$)/) {
        report("sort -h is GNU-only: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])echo([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+-[A-Za-z]*e([[:space:]]|$)/) {
        report("echo -e is not portable; use printf: " line); return }'

# ── RULE D: Bash 4 constructs, on a platform whose /bin/bash is 3.2 ────────
#
# The same class as the rest and the one that was missed: this file used
# `mapfile`, which arrived in Bash 4, so the check written to keep the suite
# runnable on macOS would have been the thing that stopped it — failing before a
# single scan ran, with both Ubuntu jobs green. Caught by a reviewer, which is
# what this whole file exists to stop happening.
#
# Absence cannot catch these either: the runner has Bash 5 and accepts them all.
# Only text can, and like the flag list this one is open — a Bash 5 construct is
# equally unusable there, and the list grows when one is found.
#
# `${!name}` is NOT here: indirect expansion is Bash 2, and only the Bash 4
# `${!prefix@}`/`${!array[@]}` name-listing forms would be — neither is used.
RULE_D='
    { line = $0; sub(/^[[:space:]]*#.*$/, "", line) }
    if (line ~ /(^|[^a-zA-Z_-])(mapfile|readarray)([[:space:]]|$)/) {
        report("mapfile/readarray is Bash 4; use a while-read loop: " line); return }
    if (line ~ /(declare|local|typeset)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+-[A-Za-z]*A[A-Za-z]*([[:space:]]|$)/) {
        report("associative arrays are Bash 4: " line); return }
    if (line ~ /\$\{[A-Za-z0-9_][A-Za-z0-9_]*(\[[^]]*\])?(\^\^?|,,?)[^}]*\}/) {
        report("case modification is Bash 4: " line); return }
    if (line ~ /\$\{[A-Za-z0-9_][A-Za-z0-9_]*(\[[^]]*\])?@[QEPAKaUuL]\}/) {
        report("parameter transformation is Bash 4.4: " line); return }
    if (line ~ /(^|[[:space:]])coproc([[:space:]]|$)/) {
        report("coproc is Bash 4: " line); return }
    if (line ~ /\[\[[^]]*[[:space:]]-v[[:space:]]/) {
        report("[[ -v ]] is Bash 4.2: " line); return }'

# What gets scanned: everything this repository ships and runs. `SKILL.md` is
# included because its bash blocks run on the operator's machine like any other
# code here — the driver being prose around shell does not make the shell exempt.
# THIS FILE IS NOT IN ITS OWN TARGET LIST, and it cannot be. Its rules are written
# as patterns, its planted instances are literal `sed -i`, `readlink -f`, `\s` and
# the rest, and every one of them is there on purpose — scanning itself, it reports
# a dozen hits it created. That is the same exemption any linter's own test corpus
# needs, and the cost is stated rather than hidden: this file is the one the scans
# do not cover, so a GNU-only construct used for real IN HERE would be missed.
# What limits that is how little real work it does — it runs `awk`, `grep`,
# `mktemp`, `printf` and `chmod`, all portable, and the CI portability job runs it
# with the GNU tools gone like everything else.
targets() {
    local t
    for t in "$SELF_DIR"/*.sh; do
        [ -f "$t" ] || continue
        case "$(basename "$t")" in test-portability.sh) continue ;; esac
        printf '%s\n' "$t"
    done
    [ -f "$SELF_DIR/../SKILL.md" ] && printf '%s\n' "$SELF_DIR/../SKILL.md"
    return 0
}
# NOT `mapfile`: it arrived in Bash 4 and stock macOS ships 3.2, so the file
# written to keep this suite runnable on macOS would have been the one that
# stopped it — failing before a single scan ran, while both Ubuntu jobs stayed
# green. That is the exact shape of the defect this file exists to catch, in this
# file. A `while read` loop is Bourne-old and needs no version.
TARGETS=()
while IFS= read -r _t; do TARGETS+=( "$_t" ); done < <(targets)
[ "${#TARGETS[@]}" -gt 0 ] \
    && pass "there are ${#TARGETS[@]} files to scan" \
    || { die "no files found to scan"; echo "RESULT: FAIL"; exit 1; }

# ── the tree is clean ──────────────────────────────────────────────────────
a_rc=0; a_hits="$(scan "$RULE_A" "${TARGETS[@]}")" || a_rc=$?
[ "$a_rc" -eq 0 ] \
    && pass "the GNU-regex-escape scan completed" \
    || die "the GNU-regex-escape scan could not be completed (rc=$a_rc)"
[ -z "$a_hits" ] \
    && pass "no grep/sed/awk pattern uses a GNU regex escape" \
    || die "GNU regex escape(s) in a grep/sed/awk pattern:
$a_hits"

d_rc=0; d_hits="$(scan "$RULE_D" "${TARGETS[@]}")" || d_rc=$?
[ "$d_rc" -eq 0 ] \
    && pass "the Bash-4-construct scan completed" \
    || die "the Bash-4-construct scan could not be completed (rc=$d_rc)"
[ -z "$d_hits" ] \
    && pass "nothing uses a construct newer than the Bash 3.2 macOS ships" \
    || die "Bash 4+ construct(s):
$d_hits"

c_rc=0; c_hits="$(scan "$RULE_C" "${TARGETS[@]}")" || c_rc=$?
[ "$c_rc" -eq 0 ] \
    && pass "the GNU-flag scan completed" \
    || die "the GNU-flag scan could not be completed (rc=$c_rc)"
[ -z "$c_hits" ] \
    && pass "no command is given a GNU-only flag" \
    || die "GNU-only flag(s):
$c_hits"

# Rule B is per file, because the guard it requires is per file.
unguarded=""
for f in "${TARGETS[@]}"; do
    for c in $GNU_ONLY_COMMANDS; do
        b_rc=0
        b_hits="$(scan '
            if (line ~ /'"$CMD_POS$c"'([[:space:]]|$)/) { report(line); return }' "$f")" || b_rc=$?
        [ "$b_rc" -eq 0 ] || { die "the GNU-command scan failed on $(basename "$f") (rc=$b_rc)"; continue; }
        [ -n "$b_hits" ] || continue
        # The guard, in the same file — READ AS CODE, not as text. A raw `grep`
        # accepted `# use command -v seq` as the probe for an unguarded `seq` two
        # lines down, and in the portability job the absent command merely makes
        # an `if` false, so both checks passed and the macOS-only failure shipped.
        # A comment describing a guard is not a guard.
        # …AND THE PROBE ITSELF MUST BE IN COMMAND POSITION. Stripping comments
        # was not enough: `printf '%s' 'command -v seq'` is quoted DATA — a
        # diagnostic string naming the probe — and it satisfied the guard while an
        # unguarded `seq` two lines down went unreported. A probe that is not run
        # guards nothing.
        guard="$(scan '
            if (line ~ /'"$CMD_POS"'command[[:space:]]+-v[[:space:]]+'"$c"'/) {
                report("guard"); return }' "$f")" || {
                die "the guard scan failed on $(basename "$f")"; continue; }
        [ -n "$guard" ] && continue
        unguarded="$unguarded
$b_hits"
    done
done
[ -z "$unguarded" ] \
    && pass "every GNU-only command this tree runs is guarded by a command -v probe" \
    || die "GNU-only command(s) invoked without a command -v guard:$unguarded"

# ── EACH RULE CATCHES A PLANTED INSTANCE ───────────────────────────────────
# A scan reporting a clean tree proves nothing on its own: an empty result is what
# both "nothing is wrong" and "this never worked" look like. Every rule is given
# the construct it exists to reject.
#
# `\s` is the one that actually reached this tree, in `test-pr-skill-contract.sh`,
# and was fixed in 96bfae4 — so the planted instance below is the real historical
# defect rather than an invented one.
PTMP="$(mktemp -d)" || { die "no scratch directory for the planted instances"; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$PTMP"' EXIT
plant() {   # plant <name> <line> <rule> <label> [command, for rule B]
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$PTMP/$1.sh"
    # The command defaults to the fixture's NAME, which is right for the cases
    # named after the tool — and wrong for the ones that vary the POSITION rather
    # than the tool. `if seq 1 5` planted as `ifseq` scanned for a command called
    # `ifseq`, found nothing, and reported the scan had missed it: a fixture
    # failing for its own reason rather than the code's.
    local cmd="${5:-$1}"
    local hits rc=0
    case "$3" in
        A) hits="$(scan "$RULE_A" "$PTMP/$1.sh")" || rc=$? ;;
        C) hits="$(scan "$RULE_C" "$PTMP/$1.sh")" || rc=$? ;;
        D) hits="$(scan "$RULE_D" "$PTMP/$1.sh")" || rc=$? ;;
        B) hits="$(scan '
               if (line ~ /'"$CMD_POS$cmd"'([[:space:]]|$)/) { report("hit"); return }' "$PTMP/$1.sh")" || rc=$? ;;
    esac
    { [ "$rc" -eq 0 ] && [ -n "$hits" ]; } \
        && pass "the scan catches $4" \
        || die "the scan MISSED $4 (rc=$rc)"
}
plant escape  "grep -qE '^[a-z]+\\s+[0-9]' \"\$f\"" A "the \\s that reached this tree"
plant worddig "sed -n 's/\\d//p' \"\$f\""           A "a \\d in a sed pattern"
plant timeout "timeout 5 gh pr view 7"              B "an unguarded timeout"
plant seq     "for i in \$(seq 1 5); do :; done"    B "an unguarded seq"
plant sha1sum "printf x | sha1sum"                  B "an unguarded sha1sum"
plant inplace "sed -i 's/a/b/' \"\$f\""             C "sed -i with no suffix"
plant readl   "readlink -f \"\$f\""                 C "readlink -f"
plant pcre    "grep -P '\\t' \"\$f\""               C "grep -P"
plant echoe   "echo -e 'a\\tb'"                     C "echo -e"
plant sedr    "sed -r 's/a+/b/' \"\$f\""              C "sed -r, the GNU spelling of -E"
plant dated   "date -d '2026-01-01' +%s"            C "date -d"
plant statc   "stat -c '%s' \"\$f\""                 C "stat -c"
plant xargsr  "printf '' | xargs -r rm"             C "xargs -r"
plant sorth   "sort -h < \"\$f\""                    C "sort -h"
plant awky    "awk '/\\yfoo\\y/ { print }' \"\$f\""  A "gawk's \\y word boundary"
plant awklt   "awk '/\\<foo\\>/ { print }' \"\$f\""  A "gawk's \\< and \\> boundaries"
plant mapf     "mapfile -t X < <(printf 'a\\n')"     D "the mapfile that reached this very file"
plant readarr  "readarray -t X < \"\$f\""             D "readarray, its other name"
plant assoc    "declare -A M"                       D "an associative array"
plant upper    "printf '%s' \"\${x^^}\""              D "Bash 4 case modification"
plant upperpos "norm() { printf '%s' \"\${1^^}\"; }"   D "…on a positional parameter, the commonest spelling"
plant transf   "printf '%s' \"\${x@Q}\""              D "a Bash 4.4 parameter transformation"
plant coprocp  "coproc CAT { cat; }"                D "coproc"
plant isvar    "if [[ -v x ]]; then :; fi"          D "[[ -v ]]"
plant grepnp   "grep -n -P '\\d' \"\$f\""             C "grep -P after another option"
plant grepmp   "grep -m 1 -P '\\d' \"\$f\""           C "grep -P after an option that takes an operand"
plant sortkh   "sort -k 1 -h < \"\$f\""               C "sort -h after an option operand"
plant awkbig   "awk '/foo\\Bbar/ { print }' \"\$f\""   A "gawk's uppercase \\B, which the backspace exemption must not cover"
plant declra   "declare -r -A M"                    D "an associative array declared with a separated option"
plant declar2  "declare -Ar M"                      D "…and with the options run together"
plant transU   "printf '%s' \"\${name@U}\""            D "the @U transformation"
plant transL   "printf '%s' \"\${name@L}\""            D "the @L transformation"
plant casearm  "case x in x) seq 1 5; : ;; esac"    B "a GNU command at the start of a case arm" seq
plant sednr    "sed -n -r 's/a+/b/p' \"\$f\""        C "sed -r after another option"
plant statlc   "stat -L -c '%s' \"\$f\""             C "stat -c after another option"
plant upperpat "printf '%s' \"\${name^^[a-z]}\""     D "case conversion with a pattern operand"
plant ifseq    "if seq 1 5; then :; fi"             B "a GNU command as an if condition"     seq
plant whileseq "while seq 1 2; do break; done"      B "…and as a while condition"            seq
plant notseq   "! seq 1 2"                          B "…and after a leading !"                seq

# ── …and does NOT fire on the correct forms ────────────────────────────────
# A scan that rejects the portable spelling is worse than none: it teaches the
# contributor that the check is noise, and the next real hit is ignored with it.
refute() {   # refute <name> <line> <rule> <label>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$PTMP/$1.sh"
    local hits rc=0
    case "$3" in
        A) hits="$(scan "$RULE_A" "$PTMP/$1.sh")" || rc=$? ;;
        C) hits="$(scan "$RULE_C" "$PTMP/$1.sh")" || rc=$? ;;
        D) hits="$(scan "$RULE_D" "$PTMP/$1.sh")" || rc=$? ;;
    esac
    { [ "$rc" -eq 0 ] && [ -z "$hits" ]; } \
        && pass "…and accepts $4" \
        || die "the scan rejected the PORTABLE form of $4 ('$hits')"
}
refute posix   "grep -qE '^[a-z]+[[:space:]]+[0-9]' \"\$f\"" A "a POSIX character class"
refute jqline  "gh api x --jq 'test(\"^\\\\s+\$\")'"          A "a \\s inside a jq program"
# `sed -i ''` is NOT among the accepted forms, and that is the correction: it is
# portable to BSD and broken on GNU, where the detached empty argument becomes the
# script. Recommending it would have shipped a command that fails on the platform
# CI runs. It is planted as a rejection instead.
plant sedempty "sed -i '' 's/a/b/' \"\$f\""         C "sed -i '' , which GNU reads as the script"
refute sedE    "sed -E 's/a+/b/' \"\$f\""                     C "sed -E, the portable spelling"
# `\b` IN AWK IS A BACKSPACE, not a word boundary — which is why gawk invented
# `\y`. Rejecting it made the mandatory gate fail on portable code.
refute awkbs   "awk 'BEGIN { printf \"\\b\" }'"               A "awk's portable backspace escape"
refute indirect "printf '%s' \"\${!name}\""                    D "indirect expansion, which is Bash 2"
refute defaulted "printf '%s' \"\${name:-fallback}\""          D "a default, which every Bash has"
# Rule B accepts a guarded use, which is the whole point of requiring a guard
# rather than absence — both real uses in this tree take this form.
printf '#!/usr/bin/env bash\nif command -v timeout >/dev/null 2>&1; then timeout 5 true; else :; fi\n' \
    > "$PTMP/guarded.sh"
g_hits="$(scan '
    if (line ~ /'"$CMD_POS"'timeout([[:space:]]|$)/) { report("hit"); return }' "$PTMP/guarded.sh")" || g_hits="SCANFAIL"
{ [ "$g_hits" != SCANFAIL ] && [ -n "$g_hits" ] && grep -q 'command -v timeout' "$PTMP/guarded.sh"; } \
    && pass "…and a guarded timeout is found but not reported, because it has a probe" \
    || die "the guarded form was not recognised as guarded ('$g_hits')"

# ── A CONTINUED COMMAND IS ONE COMMAND ─────────────────────────────────────
# `grep -qE \` on one line and its pattern on the next satisfied neither predicate
# of any rule: the command was on one side of the backslash and the escape on the
# other. The join happens once, in `scan`, so every rule inherits it — and the hit
# is reported at the FIRST physical line, which is where a reader has to look.
printf '#!/usr/bin/env bash\ngrep -qE \\\n    %s \\\n    "$f"\n' "'^[a-z]+\\s+\$'" \
    > "$PTMP/continued.sh"
cont_hits="$(scan "$RULE_A" "$PTMP/continued.sh")" || cont_hits=SCANFAIL
{ [ "$cont_hits" != SCANFAIL ] && [ -n "$cont_hits" ]; } \
    && pass "a pattern split from its command by a continuation is still caught" \
    || die "a continued grep hid its GNU escape ('$cont_hits')"
grep -q ':2:' <<<"$cont_hits" \
    && pass "…and is reported at the line the command starts on" \
    || die "the continued hit is not reported at its first line ('$cont_hits')"

# ── A QUOTED PROBE IS NOT A PROBE ──────────────────────────────────────────
# Stripping comments was not enough: a diagnostic string NAMING the probe —
# `printf '%s' 'command -v seq'` — satisfied the guard while an unguarded `seq`
# went unreported. A probe that is not run guards nothing.
printf '#!/usr/bin/env bash\nprintf %%s %s\nif seq 1 5; then :; fi\n' "'command -v seq'" \
    > "$PTMP/quotedguard.sh"
qg_guard="$(scan '
    if (line ~ /'"$CMD_POS"'command[[:space:]]+-v[[:space:]]+seq/) { report("guard"); return }' \
    "$PTMP/quotedguard.sh")" || qg_guard=SCANFAIL
{ [ "$qg_guard" != SCANFAIL ] && [ -z "$qg_guard" ]; } \
    && pass "a quoted string naming the probe does not count as a guard" \
    || die "a quoted probe satisfied the guard check ('$qg_guard')"

# ── A COMMENT IS NOT A GUARD ───────────────────────────────────────────────
# The invocation scan strips comments; the guard check did not, so prose about a
# probe stood in for the probe. Both halves of a rule have to read the same text.
printf '#!/usr/bin/env bash\n# use command -v seq before calling it\nif seq 1 5; then :; fi\n' \
    > "$PTMP/commentguard.sh"
cg_inv="$(scan '
    if (line ~ /'"$CMD_POS"'seq([[:space:]]|$)/) { report("inv"); return }' "$PTMP/commentguard.sh")" || cg_inv=SCANFAIL
cg_guard="$(scan '
    if (line ~ /'"$CMD_POS"'command[[:space:]]+-v[[:space:]]+seq/) { report("guard"); return }' "$PTMP/commentguard.sh")" || cg_guard=SCANFAIL
{ [ "$cg_inv" != SCANFAIL ] && [ -n "$cg_inv" ] && [ "$cg_guard" != SCANFAIL ] && [ -z "$cg_guard" ]; } \
    && pass "a comment mentioning command -v does not count as a guard" \
    || die "a commented probe satisfied the guard check (inv='$cg_inv' guard='$cg_guard')"

# ── the scan fails closed on input it cannot read ──────────────────────────
# An unreadable file yielding no hits is indistinguishable from a clean one, which
# is the direction that turns this whole file into a green tick over nothing.
UNREAD="$PTMP/unreadable.sh"
printf '#!/usr/bin/env bash\ngrep -qE "\\\\s" x\n' > "$UNREAD"
chmod 000 "$UNREAD"
u_rc=0
scan "$RULE_A" "$UNREAD" >/dev/null 2>&1 || u_rc=$?
chmod 644 "$UNREAD"
if [ "$(id -u)" = 0 ]; then
    pass "…(running as root, which can read anything; the unreadable case is skipped)"
else
    [ "$u_rc" -eq 2 ] \
        && pass "a file the scan cannot read is a failure, not a clean result" \
        || die "an unreadable file scanned clean (rc=$u_rc)"
fi

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
