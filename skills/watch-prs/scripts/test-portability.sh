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
# For `mktemp_d`, the VALIDATED scratch directory. This file allocated two of its
# own with a bare `mktemp -d`, which exits zero on a path it did not create — and
# every path built from one, including what the EXIT handler removes, is then
# somewhere unintended. The helper this suite already ships is the definition;
# a second, unvalidated allocation beside it is the copy that misses the rule.
. "$SELF_DIR/testlib.sh"

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
    # tracking single and double quotes, and breaks only at depth zero. It follows
    # backslash escapes inside double quotes, and here-document bodies are dropped
    # before it ever sees them. It is still not a lexer — it does not know about
    # `$(…)` nesting, `((…))`, or a quote spanning a continuation — and that list is
    # kept accurate rather than left as the one written when it did less. What it does buy is that a quoted separator no longer
    # splits a command, and that an operator can be told from the same characters
    # inside a string.
    function segments(l, n, i, ch, q, cur, rest) {
        n = 1; SEG[1] = ""; q = ""
        for (i = 1; i <= length(l); i++) {
            ch = substr(l, i, 1)
            # Inside DOUBLE quotes a backslash escapes the next character, so
            # `"a\"b"` closed at the escaped quote and reopened at the real one —
            # every operator after it read as quoted. Single quotes have no escape,
            # which is why this only applies to the double-quoted state.
            if (q == "\042" && ch == "\134") { SEG[n] = SEG[n] ch substr(l, i+1, 1); i++; continue }
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
    # WHERE the operator appears outside quotes, or 0. The here-document detector
    # needs the position and not merely the fact: a `<<` is only a redirection if
    # the shell sees it as one, and a quoted word carrying those characters is a
    # string, not a redirection.
    function unquoted_pos(l, pat, i, ch, q) {
        q = ""
        for (i = 1; i <= length(l); i++) {
            ch = substr(l, i, 1)
            if (q == "\042" && ch == "\134") { i++; continue }
            if (q == "") {
                if (ch == "\047" || ch == "\042") { q = ch; continue }
                if (substr(l, i, length(pat)) == pat) return i
            } else if (ch == q) { q = "" }
        }
        return 0
    }
    # True when the operator appears outside quotes anywhere on the line.
    function unquoted(l, pat) { return unquoted_pos(l, pat) > 0 }
    #
    # A HERE-DOCUMENT BODY IS DATA. `cat <<EOF` followed by prose is not shell, and
    # passing it to the rules made an ordinary mention of `grep -P` in a summary
    # block a reason to fail the mandatory gate — `SKILL.md` writes user-facing
    # text that way. The delimiter is taken from the redirection and the body is
    # skipped until it reappears alone on a line. `<<-` strips leading tabs from the
    # terminator, so that form is allowed for.
    { raw = $0; sub(/^[[:space:]]*#.*$/, "", raw)
      if (heredoc != "") {
          t = raw
          # ONLY `<<-` STRIPS INDENTATION, and only TABS. Stripping whitespace from
          # every terminator meant an indented `  EOF` inside an ordinary `<<EOF`
          # body ended the skip early — the rest of the document then read as
          # shell, so a `grep -P` written as example text failed the gate.
          if (hd_dash) sub(/^\t+/, "", t)
          if (t == heredoc) { heredoc = ""; hd_dash = 0 }
          next
      }
      # The delimiter can be any word — `END-MARK`, `_EOF_`, `EOF.1` — and matching
      # only an identifier took `END` from `END-MARK`, so the real terminator was
      # never recognised and everything to EOF was skipped: one document silently
      # excusing the rest of the file.
      # A `<<` INSIDE QUOTES IS NOT A REDIRECTION. A quoted word carrying those
      # characters — printf %s "<<EOF" — is a string, and matching the raw text
      # took it as one: the skip began, no
      # terminator ever arrived, and every following line to EOF was excused by a
      # here-document that was never opened. The operator is located outside quotes
      # first, and the delimiter is read from THERE rather than from anywhere on
      # the line.
      hp = unquoted_pos(raw, "<<")
      # `<<<` is a here-STRING and has no terminator. The pattern could begin at
      # the second `<` of one, take the word after it as a delimiter, and skip
      # every following line to EOF — a single `cat <<<EOF` excusing the file.
      if (hp > 0 && substr(raw, hp, 3) != "<<<") {
          tail = substr(raw, hp)
          if (match(tail, /^<<-?[[:space:]]*["'"'"']?[A-Za-z0-9_][A-Za-z0-9_.-]*["'"'"']?/)) {
              heredoc = substr(tail, RSTART, RLENGTH)
              hd_dash = (heredoc ~ /^<<-/)
              sub(/^<<-?[[:space:]]*/, "", heredoc)
              gsub(/["'"'"']/, "", heredoc)
              # `$(( 1 << 2 ))` IS ARITHMETIC. The left-shift operator is spelled
              # the same and its right operand is a number, so a numeric delimiter
              # is the shift rather than a document — and taking it started a skip
              # with no terminator, to EOF. A here-document delimiter that is only
              # digits is not a spelling anything here uses.
              if (heredoc ~ /^[0-9]+$/) { heredoc = ""; hd_dash = 0 }
          }
      }
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
    # THE ERROR FILE IS VALIDATED TOO, and it is the one that matters most: this
    # file is where a failed scan reports itself, and a path `mktemp` printed
    # without creating makes the `2>` redirection fail — the diagnostic is lost and
    # the scan reads as clean. `mktemp_d` covers directories; a file needs the same
    # check, which is three lines rather than a helper for one caller.
    errf="$(mktemp 2>/dev/null)" || return 2
    case "$errf" in /*) ;; *) return 2 ;; esac
    [ -f "$errf" ] && [ -w "$errf" ] || return 2
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
    # THE `-e`/`-f` OPERAND EXEMPTION IS GONE WITH RULE C. It existed so
    # `grep -e -P file` — which searches for the literal string `-P` — was not read
    # as the flag `-P`, and rule A does not look at `-P` or at any other flag. What
    # it left behind was an over-exemption: `grep -e -x -e '\s' "$f"` matched it on
    # the FIRST `-e`, whose operand really is `-x`, and the whole command was
    # excused — including the `\s` introduced by the second. An exemption that
    # cannot say where an operand ends is option parsing, which is the thing rule C
    # was deleted for; the rule it was protecting no longer exists, so it goes too.
    #
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
# `cksum`, `csplit`, `expand`, `unexpand`, `pathchk` and `ptx` are NOT here: POSIX
# specifies them and macOS ships them. Four were added in one round on the strength
# of being coreutils, which they are — and being in coreutils is not the test. The
# test is whether stock macOS has them, and a name that exists on both platforms in
# this list makes the gate fail on portable code, which is the one thing worse than
# missing a defect. A name that exists
# on both platforms in this list would make the gate fail on portable code, which
# is the one thing worse than missing a defect.
GNU_ONLY_NAMES='sha1sum sha256sum md5sum realpath tac shuf nproc stdbuf
                dircolors numfmt
                gsed gawk gdate gcp gln gsort gtimeout gnproc'
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

# ── RULE C WAS REMOVED, AND THIS RECORDS WHY ───────────────────────────────
#
# It rejected GNU-only FLAGS on commands that exist everywhere: `sed -i`,
# `readlink -f`, `grep -P`, `date -d`, `stat -c`, `xargs -r`, `sort -h`, `echo -e`.
# Absence cannot catch those — the command is present on both platforms and only
# BSD rejects the option — so it had to be read from the text.
#
# Reading an option from text means parsing one, and over eight review rounds that
# meant: the flag anywhere in a cluster (`grep -Pc`), after another option
# (`grep -n -P`), after an option taking an OPERAND (`grep -m 1 -P`), its long
# alias (`--perl-regexp`), the equals form (`--in-place=.bak`), the operand of `-e`
# which is not a flag at all (`grep -e -P`), fixed-string mode where the rule does
# not apply (`grep -F`), a quoted option word (`grep '-P'`), and an attached suffix
# that is portable where the bare form is not (`sed -ibak`). Each was a real hole,
# and each fix revealed the next.
#
# THE RULES THAT REMAIN HAVE CLOSED SURFACES. POSIX defines no backslash-class
# escapes, so rule A's set cannot grow. Bash 3.2's missing features are a finite
# list. A command name is a name. Rule C's surface was option syntax, which is not
# closed — and this repository already records a structural checker built and
# deleted six times for exactly that reason.
#
# WHAT THIS GIVES UP, plainly: nothing catches `sed -i`, `readlink -f`, `grep -P`,
# `date -d`, `stat -c`, `xargs -r`, `sort -h` or `echo -e` now. They are review's
# job. A real loss, traded for a check that terminates.


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
    # THE OPTION WORD MAY BE QUOTED. Shell quote removal happens before `declare`
    # sees its arguments, so a quoted option word — the dash and the letter
    # wrapped in quotes — declares an associative array
    # exactly as the bare form does — and the pattern, anchored on whitespace
    # immediately before the dash, saw the quote and passed it. One optional quote
    # character on each side, which is the whole of what quote removal does to an
    # option word; this is a pattern for a construct, not an option parser.
    if (line ~ /(declare|local|typeset)([[:space:]]+["'"'"']?-[A-Za-z-]+["'"'"']?)*[[:space:]]+["'"'"']?-[A-Za-z]*A[A-Za-z]*["'"'"']?([[:space:]]|$)/) {
        report("associative arrays are Bash 4: " line); return }
    if (line ~ /\$\{([A-Za-z0-9_][A-Za-z0-9_]*|[@*#?$!-])(\[[^]]*\])?(\^\^?|,,?)[^}]*\}/) {
        report("case modification is Bash 4: " line); return }
    if (line ~ /\$\{([A-Za-z0-9_][A-Za-z0-9_]*|[@*#?$!-])(\[[^]]*\])?@[QEPAKakUuL]\}/) {
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
    # THE STEP MAY BE SIGNED. `{5..1..-1}` counts down and is the same Bash 4
    # feature; an unsigned `[0-9]+` for the step read the `-` as not-a-step and let
    # the descending form through — the spelling a descending loop actually uses.
    if (line ~ /\{[0-9]+\.\.[0-9]+\.\.-?[0-9]+\}/ || line ~ /\{[A-Za-z]\.\.[A-Za-z]\.\.-?[0-9]+\}/) {
        report("a stepped brace expansion is Bash 4: " line); return }
    if (line ~ /(^|[[:space:]])(shopt[[:space:]]+(-[A-Za-z]+[[:space:]]+)*globstar|set[[:space:]]+-o[[:space:]]+globstar)/) {
        report("globstar is Bash 4: " line); return }
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
        index($0, "# portability-scan: rules-end") == 1 { skip = 0; seen = 1; next }
        !skip { print }
        END { if (!seen) exit 3 }' "${BASH_SOURCE[0]}" > "$out" || arc=$?
    # THE END MARKER HAS TO BE OBSERVED. Without it `skip` never clears, everything
    # after `rules-begin` is dropped, and the extract is a short prefix that scans
    # clean — the self-scan silently covering almost nothing.
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
# ALLOCATED BEFORE ANYTHING READS IT. This sat below both uses, so
# `${PORT_TMPDIR:+…}` expanded to nothing, the extraction branch never ran, and
# SKILL.md quietly left the target list — a GNU-only construct in the driver was
# invisible to the gate. Nothing failed, because the only check on the list was a
# count with no expected value.
# THROUGH `mktemp_d`, NOT A BARE `mktemp -d`. `mktemp` can print a path it did not
# create and still exit zero, and a relative or empty one then makes every path
# built from it land somewhere unintended — and the EXIT handler `rm -rf` it.
# `testlib.sh` already carries the validated helper; a second, unvalidated
# allocation beside it is the copy that misses the rule.
PORT_TMPDIR="$(mktemp_d)" || { die "no scratch directory for the extracts"; PORT_TMPDIR=""; }
# ONE TRAP, BOTH DIRECTORIES. `trap … EXIT` REPLACES the previous handler rather
# than adding to it, so the second one written silently dropped the first and that
# directory leaked on every run of the suite. Both paths are cleaned from a single
# handler, and an unset one expands to nothing rather than to `rm -rf ""`.
PTMP=""
trap 'rm -rf ${PORT_TMPDIR:+"$PORT_TMPDIR"} ${PTMP:+"$PTMP"}' EXIT

PORT_SKILL_BLOCKS=""
if [ -f "$SELF_DIR/../SKILL.md" ]; then
    PORT_SKILL_BLOCKS="${PORT_TMPDIR:+$PORT_TMPDIR/SKILL.md(bash blocks)}"
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
# NAMED, not a bare `mktemp` path. A hit in an extracted target is reported as its
# file, and `/tmp/tmp.AbCdEf:212:` tells a reader nothing about which file to open.
PORT_SELF="${PORT_TMPDIR:+$PORT_TMPDIR/test-portability.sh(implementation)}"
if [ -n "$PORT_SELF" ] && port_production "$PORT_SELF"; then
    TARGETS+=( "$PORT_SELF" )
    pass "the checker's own implementation is in scope, above the fixture marker"
    # AND IT REACHES PAST THE RULES REGION. If the end marker is never seen, `skip`
    # stays set, everything after `rules-begin` is dropped, and the extract is a
    # short prefix that scans clean — a self-scan covering almost nothing while
    # reporting that it covered the implementation.
    grep -qF 'count_hits() {' "$PORT_SELF" \
        && pass "…and reaches the plumbing below the rules, not just the header" \
        || die "the self-scan extract stops at the rules; the end marker was not seen"
else
    die "the checker's implementation half could not be extracted"
fi
# BY NAME, not by count. `there are N files to scan` passed at 25 exactly as it
# had at 26, so SKILL.md leaving the list was invisible. Every input this file
# claims to cover is named.
# WHOLE ENTRY, not substring. `grep -qF testlib.sh` finds it inside
# `test-testlib.sh`, so three of the five required names were satisfied by other
# files and the check would have survived their removal.
port_listed() { printf '%s\n' "${TARGETS[@]}" | sed 's|.*/||' | grep -qxF "$1"; }
[ "${#TARGETS[@]}" -gt 0 ] \
    && pass "there are ${#TARGETS[@]} files to scan" \
    || { die "no files found to scan"; echo "RESULT: FAIL"; exit 1; }
# The matcher is checked before it is trusted: as a substring test, `testlib.sh`
# was satisfied by `test-testlib.sh` and three of the five required names could
# have left the list unnoticed. A fragment that is a substring of several entries
# and a whole entry of none must not count as listed.
port_listed 'lib.sh' \
    && die "the target check matches substrings; a missing input would go unnoticed" \
    || pass "a required target is matched as a whole entry, not a substring"
for want in pr-ci-state.sh testlib.sh identitylib.sh 'SKILL.md(bash blocks)' \
            'test-portability.sh(implementation)'; do
    port_listed "$want" \
        && pass "…including $want" \
        || die "$want is not among the scanned inputs"
done

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

# Rule B is per file, because the guard it requires is per file.
# The count, as a function so the failing path can be reached. Inline, a stubbed
# counter could not be put in front of it, and the branch that treats a broken
# count as a clean answer would be unreachable code asserting nothing.
count_hits() {   # count_hits <text> ; prints the count, non-zero if it could not
    printf '%s\n' "$1" | grep -c ':'
}
unguarded=""
for f in "${TARGETS[@]}"; do
    b="$(basename "$f")"
    for c in $GNU_ONLY_NAMES; do
        b_rc=0
        b_hits="$(scan '
            n = 0; rest = line
            while (match(rest, /(^|[^A-Za-z0-9_.-])'"$c"'([^A-Za-z0-9_-]|$)/)) {
                n++
                rest = substr(rest, RSTART + RLENGTH - 1)
            }
            for (k = 0; k < n; k++) report(line)
            return' "$f")" || b_rc=$?
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
        # A COUNTER THAT FAILED IS NOT A COUNT OF ZERO. `|| found=0` turned a
        # broken count into the same value an ordinary unexempted command has —
        # `allowed` is 0 for those — so the equality below matched and the hit was
        # discarded. A failed parse must not look like a clean answer.
        fcount=0
        found="$(count_hits "$b_hits")" || fcount=$?
        if [ "$fcount" -ne 0 ]; then
            die "the occurrence count failed for $c in $b (rc=$fcount)"
            continue
        fi
        [ "${found:-x}" = "${allowed:-0}" ] && continue
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
PTMP="$(mktemp_d)" || { die "no scratch directory for the planted instances"; echo "RESULT: FAIL"; exit 1; }
# No second `trap` here: the handler above already names this path, and writing
# another would drop the first — which is how the extraction directory came to leak.
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
        D) hits="$(scan "$RULE_D" "$PTMP/$1.sh")" || rc=$? ;;
        # THROUGH THE PRODUCTION LIST, not a regex built from the fixture's own
        # name. Constructed fresh, a planted `realpath` reported a hit even if
        # `realpath` had been dropped from `GNU_ONLY_NAMES` — the fixture proving
        # the pattern works rather than that the rule covers the tool.
        B) hits=""
           for pc in $GNU_ONLY_NAMES; do
               [ "$pc" = "$cmd" ] || continue
               hits="$(scan '
                   if (line ~ /(^|[^A-Za-z0-9_.-])'"$pc"'([^A-Za-z0-9_-]|$)/) { report("hit"); return }' "$PTMP/$1.sh")" || rc=$?
           done ;;
    esac
    { [ "$rc" -eq 0 ] && [ -n "$hits" ]; } \
        && pass "the scan catches $4" \
        || die "the scan MISSED $4 (rc=$rc)"
}
plant escape  "grep -qE '^[a-z]+\\s+[0-9]' \"\$f\"" A "the \\s that reached this tree"
plant worddig "sed -n 's/\\d//p' \"\$f\""           A "a \\d in a sed pattern"
plant sha1sum "printf x | sha1sum"                  B "an unguarded sha1sum"
plant realpath "realpath ./x"                       B "realpath, which stock macOS lacks"
plant numfmt  "numfmt --from=iec 1K"                B "numfmt, a coreutils tool macOS does not ship"
plant tac     "tac < \"\$f\""                        B "tac"
plant gsed    "gsed -E 's/a/b/' x"                  B "a g-prefixed GNU tool"
# POSITION NO LONGER MATTERS, which is the point of the redesign — these all read
# the same to this rule, and none of them needed a new case to be added.
#
# They use `tac`, not `seq`. `seq` is deliberately outside this rule — it is
# ordinary English — so a plant naming it asserted a coverage the rule does not
# claim, and once the fixtures went through the production list those five cases
# failed for the right reason. Removed rather than repaired: the position they
# tested is covered here.
plant casearm2 "case x in x) tac f; : ;; esac"      B "…at the start of a case arm" tac
plant ifcond2  "if tac f; then :; fi"               B "…as an if condition"        tac
plant assignp  "if LC_ALL=C tac f; then :; fi"      B "…behind an assignment prefix" tac
plant cmdwrap2 "if command tac f; then :; fi"       B "…through the command builtin" tac
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
plant fallthru "case \"\$x\" in a) f ;& b) g ;; esac" D "the Bash 4 ;& case terminator"
plant appendboth "cmd &>> log"                      D "the Bash 4 &>> redirection"
plant pipeboth "cmd |& other"                       D "the Bash 4 |& pipeline"
plant awkbig   "awk '/foo\\Bbar/ { print }' \"\$f\""   A "gawk's uppercase \\B, which the backspace exemption must not cover"
plant declra   "declare -r -A M"                    D "an associative array declared with a separated option"
plant declar2  "declare -Ar M"                      D "…and with the options run together"
plant transk   "printf '%s' \"\${items[@]@k}\""      D "the lowercase @k transformation"
# The escape matters to the SPLIT as well as to the operator test: without it the
# walker closes at the escaped quote, the `;` inside the string reads as a
# separator, and the command is cut away from its own pattern.
plant bracestep "for i in {1..5..2}; do :; done"     D "a stepped brace expansion"
plant globst   "shopt -s globstar"                  D "globstar, a Bash 4 shell option"
plant setglob  "set -o globstar"                    D "…and its set -o spelling"
plant atq      "printf '%s' \"\${@@Q}\""              D "a transformation on the special parameter @"
plant atup     "printf '%s' \"\${@^^}\""              D "…and case modification on it"
plant qsep2    'grep "a\";\s" "$f"'                      A "a GNU escape behind an escaped quote"
plant escq     "printf '%s' \"a\\\"b\" |& cat"          D "a real |& after an escaped quote"
plant transU   "printf '%s' \"\${name@U}\""            D "the @U transformation"
plant transL   "printf '%s' \"\${name@L}\""            D "the @L transformation"
plant upperpat "printf '%s' \"\${name^^[a-z]}\""     D "case conversion with a pattern operand"

# ── …and does NOT fire on the correct forms ────────────────────────────────
# A scan that rejects the portable spelling is worse than none: it teaches the
# contributor that the check is noise, and the next real hit is ignored with it.
refute() {   # refute <name> <line> <rule> <label>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$PTMP/$1.sh"
    local hits rc=0
    case "$3" in
        A) hits="$(scan "$RULE_A" "$PTMP/$1.sh")" || rc=$? ;;
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
# `\b` IN AWK IS A BACKSPACE, not a word boundary — which is why gawk invented
# `\y`. Rejecting it made the mandatory gate fail on portable code.
refute awkbs   "awk 'BEGIN { printf \"\\b\" }'"               A "awk's portable backspace escape"
refute grepF   "grep -F '\\s' \"\$f\""                        A "grep -F, where a backslash is a literal"
refute fgrepc  "fgrep '\\s' \"\$f\""                          A "fgrep, which is the same thing"
# A quoted separator must not cut a command away from its own pattern, and a real
# operator must still be seen on a line that happens to contain quotes elsewhere.
plant qsep     "grep 'x;\\s' \"\$f\""                  A "a GNU escape behind a quoted separator"
plant qpipe2   "printf '%s' x |& cat"               D "a real |& on a line with unrelated quotes"
# A DATA OCCURRENCE IS REPORTED, AND THAT IS THE DESIGN. `printf '%s' realpath`
# runs nothing, and this rule says so anyway — it reads names, not grammar, because
# reading grammar took four rounds and was still wrong. The escape hatch is the
# exemption list: one line, with the count and a reason. That is a deliberate act
# by a contributor rather than an inference by a scanner that was mistaken about it
# three times, and it is the trade this rule makes.
plant dataarg "printf '%s' realpath"                B "a name used as data, which this rule reports by design" realpath
# A here-document BODY is data. `SKILL.md` writes user-facing summaries that way,
# and an ordinary mention of a forbidden spelling in one is not an invocation.
# Written directly, with REAL newlines: the helpers write their body with `%s`, so
# a `\n` in it stays two characters and the here-document never spans lines — the
# case passed while testing a single line that happened to contain no command.
{ printf '#!/usr/bin/env bash\n'
  printf "cat <<'EOF'\n"
  printf 'grep -P and \\s are unsupported on BSD\n'
  printf 'EOF\n'; } > "$PTMP/heredoc.sh"
hd_hits="$(scan "$RULE_A" "$PTMP/heredoc.sh")" || hd_hits=SCANFAIL
# …and a delimiter that is not a bare identifier still terminates. `END-MARK`
# matched only as `END`, so the real terminator was never seen and everything to
# EOF was skipped — one document excusing the rest of the file.
{ printf '#!/usr/bin/env bash\n'
  printf "cat <<'END-MARK'\n"
  printf 'harmless\n'
  printf 'END-MARK\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/dashdelim.sh"
dd_hits="$(scan "$RULE_A" "$PTMP/dashdelim.sh")" || dd_hits=SCANFAIL
{ [ "$dd_hits" != SCANFAIL ] && [ -n "$dd_hits" ]; } \
    && pass "…and a hyphenated here-document delimiter still terminates the skip" \
    || die "an END-MARK delimiter swallowed the rest of the file ('$dd_hits')"
{ [ "$hd_hits" != SCANFAIL ] && [ -z "$hd_hits" ]; } \
    && pass "…and accepts a forbidden spelling inside a here-document body" \
    || die "a here-document body was read as shell ('$hd_hits')"
# …and the rule still applies AFTER the body ends, or the skip would swallow the
# rest of the file.
{ printf '#!/usr/bin/env bash\n'
  printf "cat <<'EOF'\n"
  printf 'harmless text\n'
  printf 'EOF\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/afterheredoc.sh"
ah_hits="$(scan "$RULE_A" "$PTMP/afterheredoc.sh")" || ah_hits=SCANFAIL
{ [ "$ah_hits" != SCANFAIL ] && [ -n "$ah_hits" ]; } \
    && pass "…while code after the terminator is scanned again" \
    || die "the here-document skip swallowed the rest of the file ('$ah_hits')"
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

# ── A HERE-STRING IS NOT A HERE-DOCUMENT ───────────────────────────────────
# `<<<` has no terminator; treating it as a document skipped every following line
# to EOF — one `cat <<<EOF` excusing the whole file.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<<EOF\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/herestring.sh"
hs_hits="$(scan "$RULE_A" "$PTMP/herestring.sh")" || hs_hits=SCANFAIL
{ [ "$hs_hits" != SCANFAIL ] && [ -n "$hs_hits" ]; } \
    && pass "a here-string does not start a here-document skip" \
    || die "cat <<<EOF swallowed the rest of the file ('$hs_hits')"

# ── A TEMPORARY PATH IS VALIDATED BEFORE IT IS USED ────────────────────────
# `mktemp` can print a path it did not create and still exit zero. For the scan's
# stderr file that is not an abstract risk: a RELATIVE path is redirected into
# whatever the current directory happens to be, so a mandatory pre-push gate writes
# a file into the tree it is checking and then deletes it. The path is required to
# be absolute and to exist before anything is redirected into it.
mkdir -p "$PTMP/stub" "$PTMP/cwd"
printf '#!/usr/bin/env bash\ngrep -qE "\\s" "$f"\n' > "$PTMP/needstmp.sh"
# A RELATIVE path that EXISTS. Only the absolute-path test rejects this one: the
# file is there and writable, so a check for those alone is satisfied — and the
# gate then writes its diagnostics into whatever directory it was run from.
printf '#!/usr/bin/env bash\n: > relative-errfile\nprintf %%s relative-errfile\n' > "$PTMP/stub/mktemp"
chmod +x "$PTMP/stub/mktemp"
mk_rc=0
( cd "$PTMP/cwd" && PATH="$PTMP/stub:$PATH" scan "$RULE_A" "$PTMP/needstmp.sh" >/dev/null 2>&1 ) || mk_rc=$?
[ "$mk_rc" -eq 2 ] \
    && pass "a relative path from mktemp is refused, even when it exists" \
    || die "the scan redirected into a relative temporary path (rc=$mk_rc)"
# An ABSOLUTE path that was NOT created — the failure shape `mktemp` actually has.
# Only the existence test rejects this one, because `2>` would create the file and
# the scan would run as if nothing were wrong.
printf '#!/usr/bin/env bash\nprintf %%s "%s/uncreated-errfile"\n' "$PTMP" > "$PTMP/stub/mktemp"
mk_rc=0
( PATH="$PTMP/stub:$PATH" scan "$RULE_A" "$PTMP/needstmp.sh" >/dev/null 2>&1 ) || mk_rc=$?
[ "$mk_rc" -eq 2 ] \
    && pass "…and so is an absolute path mktemp printed without creating" \
    || die "the scan used a path mktemp never created (rc=$mk_rc)"

# ── AN OPERAND EXEMPTION THAT CANNOT SAY WHERE THE OPERAND ENDS ────────────
# `grep -e -x -e PATTERN f` passes TWO patterns. The exemption that used to cover
# `-e`'s operand matched on the first one, whose operand really is `-x`, and
# excused the whole command — including the GNU escape introduced by the second.
# Rule C is what that exemption existed for, and rule C is gone, so an operand
# beginning with a dash is now just another word to this rule.
printf '#!/usr/bin/env bash\ngrep -e -x -e %s "$f"\n' "'\\s'" > "$PTMP/twoe.sh"
te_hits="$(scan "$RULE_A" "$PTMP/twoe.sh")" || te_hits=SCANFAIL
{ [ "$te_hits" != SCANFAIL ] && [ -n "$te_hits" ]; } \
    && pass "a first -e operand no longer excuses a later GNU escape" \
    || die "grep -e -x excused the escape after the second -e ('$te_hits')"
# …and the portable spelling it used to protect is still accepted, because this
# rule never looked at a flag: `-x` is not an escape and there is nothing to report.
refute eoperand 'grep -e -x -- "$f"' A "a dash-prefixed -e operand, which carries no escape"

# ── A QUOTED OPTION WORD IS STILL THE OPTION ───────────────────────────────
# Quote removal happens before `declare` sees its arguments, so the quoted form
# declares an associative array exactly as the bare one does — and the pattern,
# anchored on the whitespace before the dash, stopped at the quote.
plant quotedassoc "if declare '-A' M; then :; fi" D "an associative array whose option word is quoted"

# ── A DESCENDING RANGE IS STILL A STEPPED RANGE ────────────────────────────
# `{5..1..-1}` is the spelling a countdown uses, and an unsigned step operand read
# the minus as not-a-step and let it through.
plant signedstep "for i in {5..1..-1}; do :; done" D "a stepped brace expansion with a negative step"

# ── ONLY <<- STRIPS THE TERMINATOR, AND ONLY TABS ──────────────────────────
# An indented `  EOF` inside an ordinary `<<EOF` body is DATA: bash requires the
# terminator at column one. Stripping indentation from every terminator ended the
# skip there, and the rest of the document was read as shell — a forbidden
# spelling written as example text then failed the mandatory gate.
{ printf '#!/usr/bin/env bash\n'
  printf "cat <<'EOF'\n"
  printf '  EOF\n'
  printf 'grep -qE "\\s" "$f"\n'
  printf 'EOF\n'; } > "$PTMP/indentterm.sh"
it_hits="$(scan "$RULE_A" "$PTMP/indentterm.sh")" || it_hits=SCANFAIL
{ [ "$it_hits" != SCANFAIL ] && [ -z "$it_hits" ]; } \
    && pass "an indented terminator does not end an ordinary here-document" \
    || die "an indented EOF ended a <<EOF body early ('$it_hits')"
# …and `<<-` DOES strip leading tabs, so a tab-indented terminator ends that form
# and the code after it is scanned again. Refusing to strip for both forms would
# swallow the file from a legitimate `<<-` onward.
{ printf '#!/usr/bin/env bash\n'
  printf "cat <<-'EOF'\n"
  printf '\tharmless\n'
  printf '\tEOF\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/dashterm.sh"
dt_hits="$(scan "$RULE_A" "$PTMP/dashterm.sh")" || dt_hits=SCANFAIL
{ [ "$dt_hits" != SCANFAIL ] && [ -n "$dt_hits" ]; } \
    && pass "…while <<- ends on a tab-indented terminator, as bash does" \
    || die "a <<- here-document never ended ('$dt_hits')"

# ── A << INSIDE QUOTES IS NOT A REDIRECTION ────────────────────────────────
# A quoted word carrying the characters is a string. Matching the raw text took it
# as a redirection, the skip began, no terminator ever arrived, and every line to
# EOF was excused by a document that was never opened.
{ printf '#!/usr/bin/env bash\n'
  printf 'printf %s "<<EOF"\n' "'%s'"
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/quotedhd.sh"
qh_hits="$(scan "$RULE_A" "$PTMP/quotedhd.sh")" || qh_hits=SCANFAIL
{ [ "$qh_hits" != SCANFAIL ] && [ -n "$qh_hits" ]; } \
    && pass "a quoted << marker does not start a here-document skip" \
    || die "a quoted <<EOF swallowed the rest of the file ('$qh_hits')"
# …and neither does the arithmetic left shift, whose operator is spelled the same
# and whose right operand is a number.
{ printf '#!/usr/bin/env bash\n'
  printf 'n=$(( 1 << 2 ))\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/shift.sh"
sh_hits="$(scan "$RULE_A" "$PTMP/shift.sh")" || sh_hits=SCANFAIL
{ [ "$sh_hits" != SCANFAIL ] && [ -n "$sh_hits" ]; } \
    && pass "…and neither does an arithmetic left shift" \
    || die "1 << 2 was read as a here-document ('$sh_hits')"

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
printf '#!/usr/bin/env bash\ndeclare \\\n    -A M\n' > "$PTMP/contd.sh"
cd_hits="$(scan "$RULE_D" "$PTMP/contd.sh")" || cd_hits=SCANFAIL
{ [ "$cd_hits" != SCANFAIL ] && [ -n "$cd_hits" ]; } \
    && pass "…and so does rule D" \
    || die "a continued declare -A was missed ('$cd_hits')"

# ── A COUNTER THAT WRITES AND THEN FAILS IS NOT A COUNT ────────────────────
# `|| found=0` turned a broken count into the same value an ordinary unexempted
# command has, so the equality that follows matched and the hit was discarded — the
# gate reporting clean after its own counter failed.
CNTMP="$PTMP/counter"; mkdir -p "$CNTMP/bin"
printf '#!/usr/bin/env bash\nprintf "5\\n"\nexit 1\n' > "$CNTMP/bin/grep"
chmod +x "$CNTMP/bin/grep"
cnt_fn="$(sed -n '/^count_hits() {/,/^}/p' "${BASH_SOURCE[0]}")"
cnt_rc=0
cnt_out="$(PATH="$CNTMP/bin:$PATH" bash -c '
    set -o pipefail
    '"$cnt_fn"'
    count_hits "a:b"' 2>&1)" || cnt_rc=$?
{ [ "$cnt_rc" -ne 0 ] && [ -n "$cnt_out" ]; } \
    && pass "a counter that printed a plausible number and then failed is not a count" \
    || die "a failed counter was accepted (rc=$cnt_rc out='$cnt_out')"
# …AND THE CALL SITE TAKES THAT STATUS. The mechanism above is behavioural; this is
# the adoption, and it is a spelling check because the branch cannot be reached
# from here — stubbing `grep` for the production loop would break every other scan
# in the same run. Both halves are needed: the mechanism alone does not say the
# loop reads the status, and the spelling alone does not say a failure propagates.
# Against the PRODUCTION half, not the whole file: this assertion's own line
# contains the literal it looks for, so grepping the file it lives in it found
# itself and passed no matter what the loop did — a check whose subject is its own
# text. `$PORT_SELF` is everything above the fixture marker.
grep -qF 'found="$(count_hits "$b_hits")" || fcount=$?' "$PORT_SELF" \
    && pass "…and the counting loop captures that status rather than defaulting" \
    || die "the count's status is not taken where it is produced"

# ── AN EXTRACTOR THAT WRITES AND THEN FAILS IS NOT AN EXTRACTOR ────────────
# `awk` can emit a valid prefix and then fail on an I/O error, and a non-empty test
# alone turned that into success — this file scanning a TRUNCATED copy of its own
# implementation and reporting clean on the part it never read.
EXTMP="$PTMP/extractor"; mkdir -p "$EXTMP/bin"
printf '#!/usr/bin/env bash\nprintf "a partial prefix\\n"\nexit 1\n' > "$EXTMP/bin/awk"
chmod +x "$EXTMP/bin/awk"
ex_fn="$(sed -n '/^port_production() {/,/^}/p' "${BASH_SOURCE[0]}")"
ex_out="$(PATH="$EXTMP/bin:$PATH" bash -c '
    PORT_SPLIT="x"
    '"$ex_fn"'
    if port_production "'"$EXTMP"'/out"; then echo ACCEPTED; else echo REFUSED; fi
    printf " wrote=%s" "$(wc -c < "'"$EXTMP"'/out" | tr -d " ")"' 2>&1)"
case "$ex_out" in
    REFUSED*wrote=0) die "the extractor fixture wrote nothing; non-empty was never in question" ;;
    REFUSED*) pass "an extractor that wrote a prefix and then failed is refused" ;;
    *) die "a failed extractor was accepted ('$ex_out')" ;;
esac

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
