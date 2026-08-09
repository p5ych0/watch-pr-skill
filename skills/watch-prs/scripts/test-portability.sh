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
scan() {   # scan <awk-program> <file…> ; prints hits, 2 if the scan failed
    local prog="$1"; shift
    local errf out rc msg mrc
    errf="$(mktemp)" || return 2
    rc=0
    out="$(awk "$prog" "$@" 2>"$errf")" || rc=$?
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
# THIS ONE TERMINATES, and the argument is worth stating: POSIX BRE and ERE define
# no backslash-class escapes at all, so `\s \S \d \D \w \W \b \B` is the COMPLETE
# set of what GNU and PCRE add. A ninth cannot appear. That is what makes a
# blacklist adequate here and inadequate for a command name.
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
RULE_A='
    { line = $0; sub(/^[[:space:]]*#.*$/, "", line) }
    line ~ /(grep|sed|awk)/ && line ~ /\\[sSdDwWbB]/ {
        print FILENAME ":" FNR ": " $0
    }'

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
CMD_POS='(^|[|;&({]|\$\(|&&|\|\|| exec | env | then | else | do |run_limited [0-9]+ )[[:space:]]*'

# ── RULE C: GNU-only flags on commands that do exist ───────────────────────
#
# Also a blacklist, and one flag behind. Absence cannot catch these at all: the
# commands are present everywhere, and GNU accepts the flag — only BSD rejects it.
#
#   sed -i        BSD requires a suffix argument; `sed -i` alone eats the next
#                 word as the suffix and silently edits nothing expected.
#   sed -r        GNU spelling of `-E`, which is the portable one.
#   readlink -f   BSD readlink has no -f.
#   grep -P       PCRE, GNU-only.
#   date -d       BSD date uses -v and -j -f.
#   stat -c       BSD stat uses -f.
#   xargs -r      BSD xargs does not run empty by default, so -r is both
#                 unsupported and unnecessary.
#   sort -h       GNU-only.
#   echo -e       Not portable in any shell; `printf` is.
RULE_C='
    { line = $0; sub(/^[[:space:]]*#.*$/, "", line) }
    line ~ /(^|[^a-zA-Z_-])sed[[:space:]]+-i([[:space:]]|$)/ &&
        line !~ /sed[[:space:]]+-i[[:space:]]*(""|'"''"')/ {
            print FILENAME ":" FNR ": sed -i without a suffix argument: " $0; next }
    line ~ /(^|[^a-zA-Z_-])sed[[:space:]]+-[a-zA-Z]*r/ {
        print FILENAME ":" FNR ": sed -r is the GNU spelling of -E: " $0; next }
    line ~ /(^|[^a-zA-Z_-])readlink[[:space:]]+-[a-zA-Z]*f/ {
        print FILENAME ":" FNR ": readlink -f is GNU-only: " $0; next }
    line ~ /(^|[^a-zA-Z_-])grep[[:space:]]+-[a-zA-Z]*P/ {
        print FILENAME ":" FNR ": grep -P is GNU-only: " $0; next }
    line ~ /(^|[^a-zA-Z_-])date[[:space:]]+-d([[:space:]]|$)/ {
        print FILENAME ":" FNR ": date -d is GNU-only: " $0; next }
    line ~ /(^|[^a-zA-Z_-])stat[[:space:]]+-[a-zA-Z]*c([[:space:]]|$)/ {
        print FILENAME ":" FNR ": stat -c is GNU-only: " $0; next }
    line ~ /(^|[^a-zA-Z_-])xargs[[:space:]]+-[a-zA-Z]*r([[:space:]]|$)/ {
        print FILENAME ":" FNR ": xargs -r is GNU-only: " $0; next }
    line ~ /(^|[^a-zA-Z_-])sort[[:space:]]+-[a-zA-Z]*h([[:space:]]|$)/ {
        print FILENAME ":" FNR ": sort -h is GNU-only: " $0; next }
    line ~ /(^|[^a-zA-Z_-])echo[[:space:]]+-e([[:space:]]|$)/ {
        print FILENAME ":" FNR ": echo -e is not portable; use printf: " $0; next }'

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
mapfile -t TARGETS < <(targets)
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
            { line = $0; sub(/^[[:space:]]*#.*$/, "", line) }
            line ~ /'"$CMD_POS$c"'([[:space:]]|$)/ { print FILENAME ":" FNR ": " $0 }' "$f")" || b_rc=$?
        [ "$b_rc" -eq 0 ] || { die "the GNU-command scan failed on $(basename "$f") (rc=$b_rc)"; continue; }
        [ -n "$b_hits" ] || continue
        # The guard, in the same file. `command -v` is the probe this tree uses;
        # a use with no probe anywhere in the file is unguarded.
        grep -q "command -v $c" "$f" && continue
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
plant() {   # plant <name> <line> <rule> <label>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$PTMP/$1.sh"
    local hits rc=0
    case "$3" in
        A) hits="$(scan "$RULE_A" "$PTMP/$1.sh")" || rc=$? ;;
        C) hits="$(scan "$RULE_C" "$PTMP/$1.sh")" || rc=$? ;;
        B) hits="$(scan '
               { line = $0; sub(/^[[:space:]]*#.*$/, "", line) }
               line ~ /'"$CMD_POS$1"'([[:space:]]|$)/ { print FILENAME ":" FNR }' "$PTMP/$1.sh")" || rc=$? ;;
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

# ── …and does NOT fire on the correct forms ────────────────────────────────
# A scan that rejects the portable spelling is worse than none: it teaches the
# contributor that the check is noise, and the next real hit is ignored with it.
refute() {   # refute <name> <line> <rule> <label>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$PTMP/$1.sh"
    local hits rc=0
    case "$3" in
        A) hits="$(scan "$RULE_A" "$PTMP/$1.sh")" || rc=$? ;;
        C) hits="$(scan "$RULE_C" "$PTMP/$1.sh")" || rc=$? ;;
    esac
    { [ "$rc" -eq 0 ] && [ -z "$hits" ]; } \
        && pass "…and accepts $4" \
        || die "the scan rejected the PORTABLE form of $4 ('$hits')"
}
refute posix   "grep -qE '^[a-z]+[[:space:]]+[0-9]' \"\$f\"" A "a POSIX character class"
refute jqline  "gh api x --jq 'test(\"^\\\\s+\$\")'"          A "a \\s inside a jq program"
refute sedsuf  "sed -i '' 's/a/b/' \"\$f\""                   C "sed -i with an empty suffix"
refute sedE    "sed -E 's/a+/b/' \"\$f\""                     C "sed -E, the portable spelling"
# Rule B accepts a guarded use, which is the whole point of requiring a guard
# rather than absence — both real uses in this tree take this form.
printf '#!/usr/bin/env bash\nif command -v timeout >/dev/null 2>&1; then timeout 5 true; else :; fi\n' \
    > "$PTMP/guarded.sh"
g_hits="$(scan '
    { line = $0; sub(/^[[:space:]]*#.*$/, "", line) }
    line ~ /'"$CMD_POS"'timeout([[:space:]]|$)/ { print FILENAME ":" FNR }' "$PTMP/guarded.sh")" || g_hits="SCANFAIL"
{ [ "$g_hits" != SCANFAIL ] && [ -n "$g_hits" ] && grep -q 'command -v timeout' "$PTMP/guarded.sh"; } \
    && pass "…and a guarded timeout is found but not reported, because it has a probe" \
    || die "the guarded form was not recognised as guarded ('$g_hits')"

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
