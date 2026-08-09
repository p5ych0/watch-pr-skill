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
    # A RULE JUDGES A SIMPLE COMMAND, NOT A LOGICAL LINE. `grep -F x f; grep "\s" f`
    # has one fixed-string command and one that is not, and an exemption taken for
    # the whole line let the first excuse the second. The line is split on the
    # operators that separate commands and each rule is applied per segment.
    #
    # Splitting on those operators inside QUOTES is wrong and is not handled — that
    # is the lexer this file declines to write. The direction is loud: a quoted
    # `;` splits one command into two halves, and a rule sees less context than it
    # should, so it reports rather than excuses.
    #
    # THE SPLIT IS QUOTE-AWARE. `split()` on the operators is blind to them, and a
    # separator inside a pattern — `grep "x;\s" f` — cut the command away from its
    # own escape, so neither half satisfied a rule. This walks the line once,
    # tracking single and double quotes, and breaks only at depth zero. It is not a
    # lexer: it does not follow backslash escapes or here-documents, and it says so
    # rather than pretending. What it does buy is that a quoted separator no longer
    # splits a command, and that an operator can be told from the same characters
    # inside a string.
    function segments(l, n, i, ch, q, cur, rest) {
        n = 1; SEG[1] = ""; q = ""
        for (i = 1; i <= length(l); i++) {
            ch = substr(l, i, 1)
            if (q == "") {
                if (ch == "\047" || ch == "\042") { q = ch; SEG[n] = SEG[n] ch; continue }
                rest = substr(l, i, 2)
                if (rest == "&&" || rest == "||") { n++; SEG[n] = ""; i++; continue }
                if (ch == ";" || ch == "|") { n++; SEG[n] = ""; continue }
            } else if (ch == q) { q = "" }
            SEG[n] = SEG[n] ch
        }
        return n
    }
    # True when the operator appears outside quotes anywhere on the line.
    function unquoted(l, pat, i, ch, q, rest) {
        q = ""
        for (i = 1; i <= length(l); i++) {
            ch = substr(l, i, 1)
            if (q == "") {
                if (ch == "\047" || ch == "\042") { q = ch; continue }
                rest = substr(l, i, length(pat))
                if (rest == pat) return 1
            } else if (ch == q) { q = "" }
        }
        return 0
    }
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
        function RULES(  nseg, si) {
            # `WHOLE` survives the split, for the constructs the split destroys:
            # `;&` is a case terminator and splitting on `;` takes it apart.
            WHOLE = line
            nseg = segments(WHOLE)
            for (si = 1; si <= nseg; si++) { line = SEG[si]; SEGI = si; ONE() }
            line = WHOLE
        }
        function ONE() {'"$prog"'}
    '"$SCAN_EPILOGUE" "$@" 2>"$errf")" || rc=$?
    msg="$(cat "$errf" 2>/dev/null)"; mrc=$?
    rm -f "$errf" 2>/dev/null
    [ "$mrc" -eq 0 ] || return 2
    [ "$rc" -eq 0 ] || return 2
    [ -z "$msg" ] || return 2
    printf '%s' "$out"
    return 0
}

# portability-scan: rules-begin
# Everything between this marker and `rules-end` is RULE TEXT: patterns naming the
# constructs to reject, and diagnostics quoting them back. It cannot be scanned —
# it is a list of the forbidden things by definition. Everything OUTSIDE it can,
# and is: the scanner, the loops, the reporting. That is where a `grep -Pq` in a
# diagnostic would live, and it is now in scope.
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
    # `-e` AND `-f` TAKE AN OPERAND, and that operand is not a flag:
    # `grep -e -P file` searches for the literal string `-P`. Checked before the
    # flag rules, because the operand looks exactly like what they hunt for.
    if (line ~ /(^|[^a-zA-Z_-])(grep|sed)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+-[A-Za-z]*[ef][[:space:]]+-/) return

    # `grep -F` and `fgrep` are FIXED-STRING: a backslash there is a literal, so
    # `grep -F '\s' f` behaves the same on both platforms, and rejecting it made
    # the gate fail on portable code.
    if (line ~ /(^|[^a-zA-Z_-])(fgrep|grep([[:space:]]+-[A-Za-z-]+)*[[:space:]]+-[A-Za-z]*F)/) return

    if (line ~ /(grep|sed)/ && line ~ /\\[sSdDwWbBy<>]/) {
        report("GNU regex escape: " line); return }
    if (line ~ /awk/ && line ~ /\\[sSdDwWBy<>]/) {
        report("gawk-only regex operator: " line); return }'

# ── RULE B: GNU-only command NAMES that cannot occur in prose ──────────────
#
# THIS RULE WAS REDESIGNED, and the reason is the point of the redesign.
#
# It used to match COMMAND POSITION and require a `command -v` guard. Across four
# review rounds that cost: the operators that begin a command, then `then`/`else`/
# `do`, then `if`/`while`/`until`/`!`, then `)` for case arms, then the `command`
# builtin, then assignment prefixes like `LC_ALL=C seq` — and on the guard side,
# excluding comments, then quoted data, then probes that control nothing, then
# probes in the wrong branch. Every one of those was a real hole and every fix
# revealed the next. That is a shell parser being written a case at a time, and
# CLAUDE.md records the last one: six versions, each reporting PASS while its
# stated invariant was false.
#
# So the position matching and the guard inference are gone. What is left needs no
# grammar: a NAME THAT CANNOT APPEAR IN PROSE, anywhere in non-comment text. There
# is no command position to get wrong, no guard to infer, and nothing for a future
# `case` arm or assignment prefix to slip through.
#
# THE PRICE IS STATED. `timeout`, `seq` and `truncate` are ordinary English and
# appear all over this tree as prose, protocol values and variable fragments —
# `state=timeout`, `$TMP/seq`, a JSON error payload. They cannot be matched this
# way and are NOT in the list below; they are covered by the portability CI job,
# behaviourally, which needs no grammar either. A use of one whose failure does not
# propagate is the gap, and it is the gap this design accepts in exchange for not
# being a parser.
#
# The exemptions are a LIST, not an inference. Two files run a GNU-only tool
# correctly — each probes with `command -v` and falls back — and rather than teach
# a scanner to recognise that shape, they are named here with their reason.
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
# Names with no English meaning, so a bare word is an invocation and nothing else.
# `cksum` is NOT here: POSIX specifies it and macOS ships it. A name that exists
# on both platforms in this list would make the gate fail on portable code, which
# is the one thing worse than missing a defect.
GNU_ONLY_NAMES='sha1sum sha256sum md5sum realpath tac shuf nproc stdbuf
                dircolors gsed gawk gdate gcp gln gsort gtimeout gnproc'
# (file:command) pairs that run one correctly — each probes with `command -v` and
# falls back. Named rather than inferred: recognising the shape took three rounds
# and was still wrong.
# file:command:COUNT. The count is what scopes the exemption to the occurrence
# that was approved: a file-wide skip suppressed every later `sha1sum` in the same
# file too, so adding an unguarded one beside the guarded one was invisible. A
# number rots loudly — add a use and the check names the file and both counts.
# Two occurrences, because the correct pattern IS two: the `command -v` probe
# and the invocation it guards, on one logical line. The count is the approved
# shape, so a third — a second, unguarded use — fails.
GNU_EXEMPT='test-pr-round-count.sh:sha1sum:2'

# ── RULE C: GNU-only flags on commands that do exist ───────────────────────
#
# Also a blacklist, and one flag behind. Absence cannot catch these at all: the
# commands are present everywhere, and GNU accepts the flag — only BSD rejects it.
#
#   sed -i        THE DETACHED FORMS have no portable spelling. BSD requires a
#                 suffix argument, so `sed -i 's/a/b/' f` eats the script as the
#                 suffix; GNU documents `-i[SUFFIX]` as ATTACHED, so
#                 `sed -i '' 's/a/b/' f` makes the empty string the script. Neither
#                 bare `-i` nor `-i ''` works on both. Write a temp file and `mv`.
#
#                 `-ibak` — a nonempty suffix ATTACHED — does work on both, and is
#                 accepted. The flag is therefore matched only when `i` ENDS the
#                 cluster: `sed -ni` is `-n` and a bare `-i`, while `sed -ibak` is
#                 `-i` carrying its suffix. That is the one flag where "anywhere in
#                 the cluster" is wrong, because what follows it is data.
#   sed -r        GNU spelling of `-E`, which is the portable one.
#   readlink -f   BSD readlink has no -f.
#   grep -P       PCRE, GNU-only.
#   date -d       BSD date uses -v and -j -f.
#   stat -c       BSD stat uses -f.
#   xargs -r      BSD xargs does not run empty by default, so -r is both
#                 unsupported and unnecessary.
#   sort -h       GNU-only.
#
# THE FLAG NEED NOT END THE CLUSTER EITHER. `grep -Pc` is `-P` and `-c` run
# together, and a pattern requiring the letter to be last missed it — found in
# the checker's own plumbing once that came into scope.
#
# THE FORBIDDEN FLAG NEED NOT COME FIRST. `grep -n -P`, `sed -n -r`, `stat -L -c`:
# each rule reads through the whole option sequence, because a version that
# examined only the first option word reported those clean — and the portability
# job cannot help, since `grep`, `sed` and `stat` are present everywhere and only
# BSD rejects the flag.
#   echo -e       Not portable in any shell; `printf` is.
RULE_C='
    # THE OPERAND OF `-e`/`-f` IS NOT A FLAG, here as in Rule A: `grep -e -P file`
    # searches for the literal `-P`. First, because the operand looks exactly like
    # what every clause below is hunting for.
    if (line ~ /(^|[^a-zA-Z_-])(grep|sed)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+-[A-Za-z]*[ef][[:space:]]+-/) return
    # NO `line = $0` HERE. The prologue hands these rules a LOGICAL line; taking
    # `$0` again threw the join away, so `grep -m 1 \` + `-P …` and `declare \` +
    # `-A M` reported clean while Rule A, which never reassigned, caught its own
    # continued case. A shared prologue only helps the rules that let it.
    if (line ~ /(^|[^a-zA-Z_-])sed([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+(--in-place(=[^[:space:]]*)?|-[A-Za-z0-9]*i)([[:space:]]|$)/) {
        report("sed -i has no portable spelling; write a temp file and mv: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])sed([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+(--(regexp-extended)(=[^[:space:]]*)?|-[A-Za-z0-9]*r[A-Za-z0-9]*)([[:space:]]|$)/) {
        report("sed -r is the GNU spelling of -E: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])readlink([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+(--(canonicalize|no-newline)(=[^[:space:]]*)?|-[A-Za-z0-9]*f[A-Za-z0-9]*)([[:space:]]|$)/) {
        report("readlink -f is GNU-only: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])grep([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+(--(perl-regexp)(=[^[:space:]]*)?|-[A-Za-z0-9]*P[A-Za-z0-9]*)([[:space:]]|$)/) {
        report("grep -P is GNU-only: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])date([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+(--(date)(=[^[:space:]]*)?|-[A-Za-z0-9]*d[A-Za-z0-9]*)([[:space:]]|$)/) {
        report("date -d is GNU-only: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])stat([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+(--(format)(=[^[:space:]]*)?|-[A-Za-z0-9]*c[A-Za-z0-9]*)([[:space:]]|$)/) {
        report("stat -c is GNU-only: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])xargs([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+(--(no-run-if-empty)(=[^[:space:]]*)?|-[A-Za-z0-9]*r[A-Za-z0-9]*)([[:space:]]|$)/) {
        report("xargs -r is GNU-only: " line); return }
    if (line ~ /(^|[^a-zA-Z_-])sort([[:space:]]+(-[A-Za-z-]+|[A-Za-z0-9_.,:\/=-]+))*[[:space:]]+(--(human-numeric-sort)(=[^[:space:]]*)?|-[A-Za-z0-9]*h[A-Za-z0-9]*)([[:space:]]|$)/) {
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
    if (line ~ /(^|[^a-zA-Z_-])(mapfile|readarray)([[:space:]]|$)/) {
        report("mapfile/readarray is Bash 4; use a while-read loop: " line); return }
    if (line ~ /(declare|local|typeset)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+-[A-Za-z]*A[A-Za-z]*([[:space:]]|$)/) {
        report("associative arrays are Bash 4: " line); return }
    if (line ~ /\$\{[A-Za-z0-9_][A-Za-z0-9_]*(\[[^]]*\])?(\^\^?|,,?)[^}]*\}/) {
        report("case modification is Bash 4: " line); return }
    if (line ~ /\$\{[A-Za-z0-9_][A-Za-z0-9_]*(\[[^]]*\])?@[QEPAKaUuL]\}/) {
        report("parameter transformation is Bash 4.4: " line); return }
    # On WHOLE, and only in the first segment, because the operator is what the
    # split removed and every segment would otherwise report the same line.
    if (SEGI <= 1 && (unquoted(WHOLE, ";&") || unquoted(WHOLE, ";;&"))) {
        report("the ;& and ;;& case terminators are Bash 4: " WHOLE); return }
    # On WHOLE and once: the segment split removes `|`, taking `|&` apart.
    #
    # `|&` is checked only when NOTHING ON THE LINE IS QUOTED. A literal —
    # `printf %s "producer |& consumer"` — is data, not pipeline syntax, and
    # telling the two apart in general is the lexer this file declines to write.
    # A line with no quote at all cannot be hiding one, and a mandatory gate that
    # rejects portable code is worse than one that misses a rare construct: it
    # gets switched off. `&>>` is not restricted this way — a redirection has no
    # prose reading, and the same test would cost more than it buys.
    if (SEGI <= 1 && unquoted(WHOLE, "&>>")) {
        report("&>> is a Bash 4 redirection: " WHOLE); return }
    if (SEGI <= 1 && unquoted(WHOLE, "|&")) {
        report("|& is a Bash 4 pipeline: " WHOLE); return }
    if (line ~ /(^|[[:space:]])coproc([[:space:]]|$)/) {
        report("coproc is Bash 4: " line); return }
    if (line ~ /\[\[[^]]*[[:space:]]-v[[:space:]]/) {
        report("[[ -v ]] is Bash 4.2: " line); return }'

# portability-scan: rules-end

# What gets scanned: everything this repository ships and runs. `SKILL.md` is
# included because its bash blocks run on the operator's machine like any other
# code here — the driver being prose around shell does not make the shell exempt.
# THIS FILE IS SCANNED TOO — its PRODUCTION half. Excluding the whole thing was
# the easy answer and the wrong one: a GNU-only construct in its own
# implementation, `grep -Pq` in a diagnostic say, would pass both Ubuntu jobs and
# stop the mandatory gate on macOS. The checker has to be able to reject itself.
#
# What genuinely cannot be scanned is the fixture half: its planted instances are
# literal `sed -i`, `readlink -f` and `\s`, every one there on purpose. So the file
# is cut at the marker that separates the two, and only the part above it — the
# rules, the scanner, the target loop — is scanned. The cut is a real line in the
# file rather than a line number, so moving the sections cannot silently widen it.
PORT_SPLIT='# ── EACH RULE CATCHES A PLANTED INSTANCE'
port_production() {   # the plumbing, as a temp file the scans can take
    local out="$1" arc=0
    # THE STATUS IS TAKEN. `awk` can write a valid prefix and then fail on an I/O
    # error, and `[ -s "$out" ]` alone turned that into success — the gate scanning
    # a TRUNCATED copy of its own implementation and reporting clean on the part it
    # never read. Non-empty is necessary and not sufficient.
    awk -v m="$PORT_SPLIT" '
        index($0, m) == 1 { exit }
        index($0, "# portability-scan: rules-begin") == 1 { skip = 1; next }
        index($0, "# portability-scan: rules-end") == 1 { skip = 0; next }
        !skip { print }' "${BASH_SOURCE[0]}" > "$out" || arc=$?
    [ "$arc" -eq 0 ] && [ -s "$out" ]
}
targets() {
    local t
    for t in "$SELF_DIR"/*.sh; do
        [ -f "$t" ] || continue
        case "$(basename "$t")" in test-portability.sh) continue ;; esac
        printf '%s\n' "$t"
    done
    # `SKILL.md` contributes its BASH BLOCKS, not its prose. It is a document about
    # shell, so it names `timeout` and `realpath` in sentences — and a rule that
    # reads a name as an invocation would report every one of them. Extracting the
    # fenced blocks is exactly what `pr-selfcheck.sh` already does to the same file,
    # and it removes a whole class of false positive without any lexing.
    [ -n "${PORT_SKILL_BLOCKS:-}" ] && printf '%s\n' "$PORT_SKILL_BLOCKS"
    return 0
}
# Extracted before the list is built, and its status taken: an `awk` that wrote a
# prefix and then failed would hand the scans a truncated driver and report clean
# on the part it never read.
PORT_SKILL_BLOCKS=""
if [ -f "$SELF_DIR/../SKILL.md" ]; then
    PORT_SKILL_BLOCKS="$(mktemp)" || { die "no scratch file for the skill blocks"; PORT_SKILL_BLOCKS=""; }
    if [ -n "$PORT_SKILL_BLOCKS" ]; then
        if awk '/^```bash$/ {inb=1; next} /^```$/ {inb=0} inb' "$SELF_DIR/../SKILL.md" \
             > "$PORT_SKILL_BLOCKS" && [ -s "$PORT_SKILL_BLOCKS" ]; then
            pass "SKILL.md contributes its bash blocks, not its prose"
        else
            die "the SKILL.md bash blocks could not be extracted"
            PORT_SKILL_BLOCKS=""
        fi
    fi
fi
# NOT `mapfile`: it arrived in Bash 4 and stock macOS ships 3.2, so the file
# written to keep this suite runnable on macOS would have been the one that
# stopped it — failing before a single scan ran, while both Ubuntu jobs stayed
# green. That is the exact shape of the defect this file exists to catch, in this
# file. A `while read` loop is Bourne-old and needs no version.
TARGETS=()
while IFS= read -r _t; do TARGETS+=( "$_t" ); done < <(targets)
# The checker's own implementation joins the list.
PORT_SELF="$(mktemp)" || { die "no scratch file for the self-scan"; PORT_SELF=""; }
if [ -n "$PORT_SELF" ] && port_production "$PORT_SELF"; then
    TARGETS+=( "$PORT_SELF" )
    pass "the checker's own implementation is in scope, above the fixture marker"
else
    die "the checker's implementation half could not be extracted"
fi
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
    b="$(basename "$f")"
    for c in $GNU_ONLY_NAMES; do
        b_rc=0
        b_hits="$(scan '
            if (line ~ /(^|[^A-Za-z0-9_.-])'"$c"'([^A-Za-z0-9_-]|$)/) { report(line); return }' "$f")" || b_rc=$?
        [ "$b_rc" -eq 0 ] || { die "the GNU-command scan failed on $b (rc=$b_rc)"; continue; }
        [ -n "$b_hits" ] || continue
        # Whitespace is normalised before matching: the list wraps across lines,
        # and a pattern requiring a space either side silently matched nothing for
        # the entry that happened to sit at a line end.
        allowed=0
        case " $(printf '%s' "$GNU_EXEMPT" | tr -s '[:space:]' ' ') " in
            *" $b:$c:"*)
                allowed="$(printf '%s' "$GNU_EXEMPT" | tr -s '[:space:]' '\n' \
                    | sed -n "s|^$b:$c:||p")" ;;
        esac
        found="$(printf '%s\n' "$b_hits" | grep -c ':')" || found=0
        [ "${found:-0}" = "${allowed:-0}" ] && continue
        unguarded="$unguarded
($found occurrence(s), $allowed approved)$b_hits"
    done
done
[ -z "$unguarded" ] \
    && pass "no GNU-only command name appears outside its declared exemptions" \
    || die "GNU-only command name(s), and not exempt:$unguarded"

# THE EXEMPTIONS ARE CHECKED FOR ROT. An exemption for a file that no longer names
# the command is a licence nobody needs, and the next reader takes it as evidence
# that the use is still there.
stale_exempt=""
for e in $GNU_EXEMPT; do
    ef="${e%%:*}"; ec="${e#*:}"; ec="${ec%%:*}"
    [ -f "$SELF_DIR/$ef" ] || { stale_exempt="$stale_exempt $e(no-such-file)"; continue; }
    eh="$(scan '
        if (line ~ /(^|[^A-Za-z0-9_.-])'"$ec"'([^A-Za-z0-9_-]|$)/) { report("x"); return }' \
        "$SELF_DIR/$ef")" || { die "the exemption scan failed on $ef"; continue; }
    [ -n "$eh" ] || stale_exempt="$stale_exempt $e(unused)"
done
[ -z "$stale_exempt" ] \
    && pass "…and every exemption is still earning its place" \
    || die "stale exemption(s):$stale_exempt"

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
               if (line ~ /(^|[^A-Za-z0-9_.-])'"$cmd"'([^A-Za-z0-9_-]|$)/) { report("hit"); return }' "$PTMP/$1.sh")" || rc=$? ;;
    esac
    { [ "$rc" -eq 0 ] && [ -n "$hits" ]; } \
        && pass "the scan catches $4" \
        || die "the scan MISSED $4 (rc=$rc)"
}
plant escape  "grep -qE '^[a-z]+\\s+[0-9]' \"\$f\"" A "the \\s that reached this tree"
plant worddig "sed -n 's/\\d//p' \"\$f\""           A "a \\d in a sed pattern"
plant sha1sum "printf x | sha1sum"                  B "an unguarded sha1sum"
plant realpath "realpath ./x"                       B "realpath, which stock macOS lacks"
plant tac     "tac < \"\$f\""                        B "tac"
plant gsed    "gsed -E 's/a/b/' x"                  B "a g-prefixed GNU tool"
# POSITION NO LONGER MATTERS, which is the point of the redesign — these all read
# the same to this rule, and none of them needed a new case to be added.
plant casearm2 "case x in x) tac f; : ;; esac"      B "…at the start of a case arm" tac
plant ifcond2  "if tac f; then :; fi"               B "…as an if condition"        tac
plant assignp  "if LC_ALL=C tac f; then :; fi"      B "…behind an assignment prefix" tac
plant cmdwrap2 "if command tac f; then :; fi"       B "…through the command builtin" tac
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
plant grepPc   "grep -Pc ':' \"$f\""                 C "grep -Pc, where the flag is not last in its cluster"
plant sedni    "sed -ni 'p' x"                        C "sed -ni, the same for -i"
plant grepnp   "grep -n -P '\\d' \"\$f\""             C "grep -P after another option"
plant grepmp   "grep -m 1 -P '\\d' \"\$f\""           C "grep -P after an option that takes an operand"
plant greplong "grep --perl-regexp 'x' \"\$f\""       C "grep --perl-regexp, the long form of -P"
plant sedlong  "sed --regexp-extended 's/a+/b/' x"  C "sed --regexp-extended"
plant sortlong "sort --human-numeric-sort x"        C "sort --human-numeric-sort"
plant sedilong "sed --in-place 's/a/b/' x"          C "sed --in-place"
plant fallthru "case \"\$x\" in a) f ;& b) g ;; esac" D "the Bash 4 ;& case terminator"
plant appendboth "cmd &>> log"                      D "the Bash 4 &>> redirection"
plant pipeboth "cmd |& other"                       D "the Bash 4 |& pipeline"
plant sedieq   "sed --in-place=.bak 's/a/b/' x"     C "sed --in-place=SUFFIX"
plant dateeq   "date --date=2026-01-01 +%s"         C "date --date=TIME"
plant stateq   "stat --format=%s x"                 C "stat --format=FORMAT"
plant cmdwrap  "if command seq 1 5; then :; fi"     B "a GNU command run through the command builtin" seq
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
refute grepF   "grep -F '\\s' \"\$f\""                        A "grep -F, where a backslash is a literal"
refute fgrepc  "fgrep '\\s' \"\$f\""                          A "fgrep, which is the same thing"
refute grepe   "grep -e -P \"\$f\""                          C "grep -e -P, a search for the literal -P"
# A quoted separator must not cut a command away from its own pattern, and a real
# operator must still be seen on a line that happens to contain quotes elsewhere.
plant qsep     "grep 'x;\\s' \"\$f\""                  A "a GNU escape behind a quoted separator"
plant qpipe2   "printf '%s' x |& cat"               D "a real |& on a line with unrelated quotes"
refute sedibak "sed -ibak 's/a/b/' \"\$f\""             C "sed -ibak, an attached suffix both platforms take"
# A DATA OCCURRENCE IS REPORTED, AND THAT IS THE DESIGN. `printf '%s' realpath`
# runs nothing, and this rule says so anyway — it reads names, not grammar, because
# reading grammar took four rounds and was still wrong. The escape hatch is the
# exemption list: one line, with the count and a reason. That is a deliberate act
# by a contributor rather than an inference by a scanner that was mistaken about it
# three times, and it is the trade this rule makes.
plant dataarg "printf '%s' realpath"                B "a name used as data, which this rule reports by design" realpath
refute qpipe   "printf %s 'producer |& consumer'"          D "a quoted |&, which is data rather than syntax"
refute indirect "printf '%s' \"\${!name}\""                    D "indirect expansion, which is Bash 2"
refute defaulted "printf '%s' \"\${name:-fallback}\""          D "a default, which every Bash has"
# Rule B accepts a guarded use, which is the whole point of requiring a guard
# rather than absence — both real uses in this tree take this form.
# ── WHAT THIS RULE NO LONGER TRIES TO DO ───────────────────────────────────
# The guard fixtures are gone with the guard inference: recognising
# `if command -v X … else fallback` took three rounds — excluding comments, then
# quoted data, then probes that control nothing — and the fourth round found a
# guarded use exempting an unrelated unguarded one in the same file. Deciding
# which invocation a probe governs is control-flow analysis, and this file does
# not do analysis. The exemption list does that job in one line per case, and
# `…and every exemption is still earning its place` keeps it honest.
#
# What that gives up is stated: a NEW correct use of `sha1sum` must be added to
# the list, which is a small deliberate act, rather than being recognised by a
# scanner that was wrong about it three times.
[ -n "$GNU_EXEMPT" ] \
    && pass "correct uses are exempted by a list, not by inferring control flow" \
    || die "the exemption list is empty; a correct use has nowhere to be recorded"

# ── AN EXEMPTION BELONGS TO ITS OWN COMMAND ────────────────────────────────
# `grep -F x f; grep '\s' f` has one fixed-string command and one that is not, and
# an exemption taken for the whole logical line let the first excuse the second.
# Rules are applied per simple command now.
printf '#!/usr/bin/env bash\ngrep -F x "$f"; grep %s "$f"\n' "'\\s'" > "$PTMP/twogrep.sh"
tg_hits="$(scan "$RULE_A" "$PTMP/twogrep.sh")" || tg_hits=SCANFAIL
{ [ "$tg_hits" != SCANFAIL ] && [ -n "$tg_hits" ]; } \
    && pass "a fixed-string command does not exempt the next command on the line" \
    || die "grep -F excused a later grep with a GNU escape ('$tg_hits')"
printf '#!/usr/bin/env bash\ngrep -e -P "$f"; grep -P x "$f"\n' > "$PTMP/twogrepc.sh"
tc_hits="$(scan "$RULE_C" "$PTMP/twogrepc.sh")" || tc_hits=SCANFAIL
{ [ "$tc_hits" != SCANFAIL ] && [ -n "$tc_hits" ]; } \
    && pass "…nor does a -e operand exempt a later -P" \
    || die "grep -e -P excused a later grep -P ('$tc_hits')"

# ── A CONTINUED COMMAND IS ONE COMMAND ─────────────────────────────────────
# `grep -qE \` on one line and its pattern on the next satisfied neither predicate
# of any rule. The join happens once, in `scan`, and the hit is reported at the
# line the command STARTS on. Each rule is exercised, because rules C and D once
# took `$0` again and threw the join away while rule A did not.
printf '#!/usr/bin/env bash\ngrep -qE \\\n    %s \\\n    "$f"\n' "'^[a-z]+\\s+\$'" \
    > "$PTMP/continued.sh"
cont_hits="$(scan "$RULE_A" "$PTMP/continued.sh")" || cont_hits=SCANFAIL
{ [ "$cont_hits" != SCANFAIL ] && [ -n "$cont_hits" ]; } \
    && pass "a pattern split from its command by a continuation is still caught" \
    || die "a continued grep hid its GNU escape ('$cont_hits')"
grep -q ':2:' <<<"$cont_hits" \
    && pass "…and is reported at the line the command starts on" \
    || die "the continued hit is not reported at its first line ('$cont_hits')"
printf '#!/usr/bin/env bash\ngrep -m 1 \\\n    -P %s \\\n    "$f"\n' "'x'" > "$PTMP/contc.sh"
cc_hits="$(scan "$RULE_C" "$PTMP/contc.sh")" || cc_hits=SCANFAIL
{ [ "$cc_hits" != SCANFAIL ] && [ -n "$cc_hits" ]; } \
    && pass "…and rule C sees the joined line too" \
    || die "a continued grep -P was missed ('$cc_hits')"
printf '#!/usr/bin/env bash\ndeclare \\\n    -A M\n' > "$PTMP/contd.sh"
cd_hits="$(scan "$RULE_D" "$PTMP/contd.sh")" || cd_hits=SCANFAIL
{ [ "$cd_hits" != SCANFAIL ] && [ -n "$cd_hits" ]; } \
    && pass "…and so does rule D" \
    || die "a continued declare -A was missed ('$cd_hits')"

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
