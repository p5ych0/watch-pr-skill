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
    # THE FILE THE LINE CAME FROM, which is not always the one awk is reading.
    # A pending logical line is flushed at the NEXT file boundary, by which point
    # `FILENAME` has already moved on — the hit was reported against the wrong
    # target, with a line number belonging to the file before it.
    function report(msg) { print (OWNER != "" ? OWNER : FILENAME) ":" start ": " msg }
    # ── ONE MODEL OF SHELL QUOTING, NOT SIX ────────────────────────────────
    #
    # This was written out separately in the splitter, the operator finder, the
    # comment stripper, the arithmetic stripper, the ANSI-C decoder and the escape
    # counter — and every copy was missing a different rule. Four review rounds in
    # a row landed on that: an escaped quote, an escaped dollar, an escaped
    # parenthesis, a quoted arithmetic opener. Each was a hole in one copy that the
    # others did not have, which is the shape CLAUDE.md records for `recordlib.sh`
    # and `identitylib.sh`: a rule that applies to more than one helper belongs in
    # one place.
    #
    # `shell_scan` walks a line ONCE and records, for every source position, which
    # quoting context it is in and whether it is a character a backslash made
    # literal. It also builds SC_EFF: what the command would actually RECEIVE,
    # which is what an escape-parity question is really about.
    #
    # It is still not a lexer. `$( … )` nesting, `${ … }` and a quote spanning a
    # continuation are not modelled, and the direction of that is unchanged: a rule
    # sees less context than it should and therefore REPORTS rather than excuses.
    # `$( … )` STARTS A FRESH QUOTING CONTEXT, and not knowing that was the
    # limitation this file used to state and accept. It stopped being acceptable:
    # a command substitution containing quotes flips the OUTER state at every one
    # of them, so `"$(… "$x" … )"` left the scan unquoted where it is quoted — and
    # a `<<` written inside such a string was then read as a redirection, queued a
    # delimiter no line matches, and swallowed the rest of the file. That is the
    # swallow-the-file shape, this time in a real target rather than a fixture.
    #
    # The nesting is a STACK: the state at the `$(` is pushed and restored at the
    # matching `)`. Backticks are still not modelled, and that stays stated.
    # Where the `$(( … ))` beginning at `from` ends: one past its final `)`.
    #
    # QUOTED PARENTHESES ARE DATA. Counting them never reached depth zero and the
    # span swallowed the rest of the logical line, taking a real command with it.
    # Quoting is tracked here rather than assumed away, and a span that does not
    # close by the end of the line ends THERE — an indeterminate span consuming
    # everything after it is the swallow-the-file shape one more time.
    function arith_end(l, from, d, i, ch, q) {
        d = 2; i = from; q = ""
        while (i <= length(l) && d > 0) {
            ch = substr(l, i, 1)
            if (q == "") {
                if (ch == "\134") { i += 2; continue }
                if (ch == "\047" || ch == "\042") { q = ch; i++; continue }
                if (ch == "(") d++
                else if (ch == ")") d--
            } else if (q == "\042" && ch == "\134") {
                # INSIDE DOUBLE QUOTES A BACKSLASH ESCAPES the next character, so an
                # escaped quote does not close the string. Treating it as the closer
                # counted the following `)` as nesting and read the real closer as an
                # opener — after which the span ran to the end of the line.
                i += 2; continue
            } else if (ch == q) q = ""
            i++
        }
        return i
    }
    function shell_scan(l, q0, i, k, ch, q, nxt, en, word, saw, depth, wq) {
        delete SC_CTX; delete SC_ESC; delete SC_ARGV; delete SC_AOP; delete SC_SUB; delete QSTK; delete PSTK
        SC_EFF = ""; SC_ARGC = 0; word = ""; saw = 0; wq = 0; depth = 0; SC_BODIES = ""; delete SUBSTS; delete SC_WQ
        q = q0; i = 1
        while (i <= length(l)) {
            ch = substr(l, i, 1)
            SC_CTX[i] = q; SC_ESC[i] = 0
            if (q == "") {
                # An unquoted backslash makes the NEXT character literal, which is
                # what `\)#` and `\$'…'` turn on: the escaped character is not the
                # operator or opener it looks like.
                if (ch == "\134" && i < length(l)) {
                    SC_CTX[i + 1] = q; SC_ESC[i + 1] = 1
                    SC_EFF = SC_EFF substr(l, i + 1, 1)
                    # AN ESCAPED CHARACTER IS QUOTED. `\coproc` is not the reserved
                    # word for the same reason `'"'"'coproc'"'"'` is not: the quoting, of
                    # whatever form, prevents the reading.
                    word = word substr(l, i + 1, 1); saw = 1; wq = 1
                    i += 2; continue
                }
                # `$'…'` is ANSI-C quoting: the escapes inside are DECODED, and
                # what it contributes to the word is the decoded text.
                if (substr(l, i, 2) == "$\047") {
                    en = ansic_span_end(l, i + 2)
                    if (en > 0) {
                        for (k = i; k <= en; k++) { SC_CTX[k] = "$"; SC_ESC[k] = 0 }
                        SC_EFF = SC_EFF ansic_decode(substr(l, i + 2, en - i - 2))
                        word = word ansic_decode(substr(l, i + 2, en - i - 2)); saw = 1
                        i = en + 1; continue
                    }
                }
                # A quote CHARACTER contributes nothing itself, but it means a word
                # is present — which is how `cat <<''` differs from `cat <<`.
                # `$"…"` IS LOCALE TRANSLATION, and the dollar is not part of the
                # word: `$"grep"` invokes `grep`, and keeping it produced a command
                # named `$grep` that no rule recognises.
                if (substr(l, i, 2) == "$\042") { q = "\042"; saw = 1; i += 2; continue }
                if (ch == "\047" || ch == "\042") { q = ch; saw = 1; wq = 1; i++; continue }
                # Unquoted whitespace ENDS a word; an unquoted control operator ends
                # one and is a token of its own, so `(test -v x)` has `test` as a
                # command word rather than as part of `(test`.
                if (ch == " " || ch == "\t") {
                    if (saw) { SC_ARGC++; SC_ARGV[SC_ARGC] = word; SC_AOP[SC_ARGC] = 0; SC_WQ[SC_ARGC] = wq }
                    word = ""; saw = 0; wq = 0
                    SC_EFF = SC_EFF ch; i++; continue
                }
                # A SUBSTITUTION RUNS A COMMAND OF ITS OWN. `out=$(grep PATTERN f)`
                # invokes `grep`; appending the text to the assignment word left a
                # word called `out=$(grep` and no command at all. The delimiters are
                # marked as operators, so the words inside are a simple command and
                # the words outside are another.
                # `$((` IS ARITHMETIC, NOT A COMMAND. It shares the first two
                # characters, and treating it as a substitution made the operands of
                # `value=$((a + b))` look like an invoked command with arguments.
                # …AND THE WHOLE SPAN, not just the opener. Consuming three
                # characters left the expression to the ordinary word rules, so the
                # whitespace inside `$(( a + b ))` flushed the assignment and the
                # operands became words of their own — an invoked command again.
                if (substr(l, i, 3) == "$((") {
                    k = arith_end(l, i + 3)
                    SC_EFF = SC_EFF substr(l, i, k - i); word = word substr(l, i, k - i); saw = 1
                    i = k; continue
                }
                # `<( … )` AND `>( … )` RUN A COMMAND TOO. They are the same shape
                # as a substitution with a redirection character in front, and not
                # modelling them left the command inside as part of a word.
                if ((ch == "<" || ch == ">") && substr(l, i + 1, 1) == "(") {
                    depth++; QSTK[depth] = q; PSTK[depth] = 0; q = ""
                    SUBSTS[depth] = i + 2
                    if (saw) { SC_ARGC++; SC_ARGV[SC_ARGC] = word; SC_AOP[SC_ARGC] = 0; SC_WQ[SC_ARGC] = wq }
                    word = ""; saw = 0; wq = 0
                    SC_ARGC++; SC_ARGV[SC_ARGC] = "("; SC_AOP[SC_ARGC] = 1; SC_SUB[SC_ARGC] = 1
                    SC_EFF = SC_EFF substr(l, i, 2)
                    i += 2; continue
                }
                if (substr(l, i, 2) == "$(") {
                    depth++; QSTK[depth] = q; PSTK[depth] = 0; q = ""
                    SUBSTS[depth] = i + 2
                    if (saw) { SC_ARGC++; SC_ARGV[SC_ARGC] = word; SC_AOP[SC_ARGC] = 0; SC_WQ[SC_ARGC] = wq }
                    word = ""; saw = 0; wq = 0
                    SC_ARGC++; SC_ARGV[SC_ARGC] = "("; SC_AOP[SC_ARGC] = 1; SC_SUB[SC_ARGC] = 1
                    SC_EFF = SC_EFF substr(l, i, 2)
                    i += 2; continue
                }
                # A `(` INSIDE ONE IS A SUBSHELL, and its `)` is not the end of the
                # substitution. Closing at the first one restored the outer quoting
                # early, and every quote after that read inverted.
                if (ch == "(" && depth > 0) {
                    PSTK[depth]++
                    if (saw) { SC_ARGC++; SC_ARGV[SC_ARGC] = word; SC_AOP[SC_ARGC] = 0; SC_WQ[SC_ARGC] = wq }
                    word = ""; saw = 0; wq = 0
                    SC_ARGC++; SC_ARGV[SC_ARGC] = ch; SC_AOP[SC_ARGC] = 1
                    SC_EFF = SC_EFF ch; i++; continue
                }
                if (ch == ")" && depth > 0 && PSTK[depth] > 0) {
                    PSTK[depth]--
                    if (saw) { SC_ARGC++; SC_ARGV[SC_ARGC] = word; SC_AOP[SC_ARGC] = 0; SC_WQ[SC_ARGC] = wq }
                    word = ""; saw = 0; wq = 0
                    SC_ARGC++; SC_ARGV[SC_ARGC] = ch; SC_AOP[SC_ARGC] = 1
                    SC_EFF = SC_EFF ch; i++; continue
                }
                if (ch == ")" && depth > 0) {
                    # RECORDED AT EVERY DEPTH, not only the outermost: `$(cat
                    # <(grep …))` has the engine two levels in, and one level of
                    # extraction reached only the `cat`.
                    if (SUBSTS[depth] > 0) {
                        SC_BODIES = SC_BODIES (SC_BODIES == "" ? "" : "\n") substr(l, SUBSTS[depth], i - SUBSTS[depth])
                        SUBSTS[depth] = 0
                    }
                    q = QSTK[depth]; depth--
                    if (saw) { SC_ARGC++; SC_ARGV[SC_ARGC] = word; SC_AOP[SC_ARGC] = 0; SC_WQ[SC_ARGC] = wq }
                    word = ""; saw = 0; wq = 0
                    SC_ARGC++; SC_ARGV[SC_ARGC] = ")"; SC_AOP[SC_ARGC] = 1
                    SC_EFF = SC_EFF ch
                    i++; continue
                }
                # AN OPERATOR IS MARKED AS ONE. A quoted or escaped `(` is an
                # ordinary word — `test \( -v x \)` groups an expression and the
                # parenthesis is an ARGUMENT of `test` — and a list that recorded
                # only the character could not tell the two apart, so the simple
                # command ended at the group and never reached the operator.
                if (index("();&|<>", ch) > 0) {
                    if (saw) { SC_ARGC++; SC_ARGV[SC_ARGC] = word; SC_AOP[SC_ARGC] = 0; SC_WQ[SC_ARGC] = wq }
                    word = ""; saw = 0; wq = 0
                    SC_ARGC++; SC_ARGV[SC_ARGC] = ch; SC_AOP[SC_ARGC] = 1
                    SC_EFF = SC_EFF ch; i++; continue
                }
                SC_EFF = SC_EFF ch; word = word ch; saw = 1; i++; continue
            }
            if (q == "\047") {
                if (ch == "\047") { q = ""; i++; continue }
                SC_EFF = SC_EFF ch; word = word ch; i++; continue
            }
            # A SUBSTITUTION OPENS INSIDE DOUBLE QUOTES TOO — `"$(… "$x" …)"` is the
            # ordinary spelling, and handling it only in unquoted text left every
            # inner quote toggling the OUTER state.
            if (substr(l, i, 3) == "$((") {
                k = arith_end(l, i + 3)
                SC_EFF = SC_EFF substr(l, i, k - i); word = word substr(l, i, k - i)
                i = k; continue
            }
            if (substr(l, i, 2) == "$(") {
                depth++; QSTK[depth] = q; PSTK[depth] = 0; q = ""
                SUBSTS[depth] = i + 2
                # THE SAME FLUSH AS THE UNQUOTED BRANCH. `out="$(grep PATTERN f)"`
                # is the ordinary spelling, and appending the words to the
                # assignment left `out=grep` with no command in it.
                if (word != "") { SC_ARGC++; SC_ARGV[SC_ARGC] = word; SC_AOP[SC_ARGC] = 0 }
                word = ""; saw = 0
                SC_ARGC++; SC_ARGV[SC_ARGC] = "("; SC_AOP[SC_ARGC] = 1; SC_SUB[SC_ARGC] = 1
                SC_EFF = SC_EFF substr(l, i, 2)
                i += 2; continue
            }
            # Inside double quotes a backslash is literal EXCEPT before one of the
            # four characters it can escape there.
            if (ch == "\134" && i < length(l)) {
                nxt = substr(l, i + 1, 1)
                if (index("$\140\042\134", nxt) > 0) {
                    SC_CTX[i + 1] = q; SC_ESC[i + 1] = 1
                    SC_EFF = SC_EFF nxt; word = word nxt; i += 2; continue
                }
                SC_EFF = SC_EFF ch; word = word ch; i++; continue
            }
            if (ch == q) { q = ""; i++; continue }
            SC_EFF = SC_EFF ch; word = word ch; i++; continue
        }
        if (saw) { SC_ARGC++; SC_ARGV[SC_ARGC] = word }
        # WHERE THE QUOTING STOOD AT THE END, so the next physical line can start
        # from it: a word opened on one physical line and closed on the next is
        # ONE word, and a scan that restarted at every line read that closing
        # quote as an opener — the whole rest of the line then became data.
        # AN UNCLOSED SUBSTITUTION CARRIES NOTHING. If the line ends with a `$(`
        # still open, this model did not follow it — the text is as likely to be an
        # awk or jq program quoted inside the shell as it is to be shell. Carrying a
        # state derived from that made every such spot CONTAGIOUS: the next line was
        # read as quoted, its comment stopped being a comment, and two real targets
        # failed the gate for constructs they do not contain. Being unsure is a
        # reason to carry nothing, not a reason to carry a guess.
        SC_QEND = (depth > 0) ? "" : q
    }
    # ── WHERE THIS MODEL STOPS, AND WHY IT STOPS THERE ─────────────────────
    #
    # The rules that ask "which command is this" — the `shopt` option names, the
    # `-v` conditional, `declare -A`/`-g`, `wait -n`, and the regex engine — need a
    # notion of a simple command. Building one has taken nine review rounds and
    # roughly seventy findings, nearly all of them another production of the shell
    # grammar. That is the surface CLAUDE.md records a structural checker being
    # built and deleted six times for, and it is why rule C was deleted from this
    # very file.
    #
    # So the model has a stated edge rather than an open one, and the criterion is
    # asymmetric:
    #
    #   A FALSE POSITIVE IS A DEFECT. A mandatory gate that rejects portable code
    #   gets switched off, and this file has said so from the first round. Those are
    #   fixed whenever they are found, wherever they come from.
    #
    #   A MISS IN A FORM THIS MODEL DOES NOT FOLLOW IS A LIMITATION, recorded here
    #   rather than chased. The portability CI job and review are the other two
    #   layers, and neither of them needs this grammar.
    #
    # NOT FOLLOWED, as of this writing: a command substitution split across physical
    # lines inside a here-document BODY (the bodies are read a line at a time,
    # because that is how a terminator is recognised); a command name held in a
    # VARIABLE (`tool=grep; "$tool" …`), a BACKQUOTE substitution, a substitution
    # inside a compound-command HEADER, a word left open across physical lines, and
    # a shell spawned from inside another shell body. Each was measured, not assumed: the
    # header case was implemented and reverted, because reaching the command inside
    # it lost the header and rejected the list data after it.
    #
    # ── WHAT A SIMPLE COMMAND IS ───────────────────────────────────────────
    #
    # A rule about a BUILTIN is a rule about the command WORD, not about a word
    # appearing somewhere on the line: `printf %s shopt -s globstar` runs `printf`,
    # and rejecting it is rejecting portable code. CLAUDE.md records
    # command-position matching being built and deleted for rule B, four rounds
    # running — but that was a regex over raw text guessing where a command began.
    # This reads the WORD LIST the shared model already produces, where the
    # operators are tokens rather than characters to be spotted, and the whole rule
    # is: skip assignments, skip redirections and their targets, take the first
    # word that is left.
    function is_op(w)    { return length(w) == 1 && index("();&|", w) > 0 }
    function is_redir(w) { return w == "<" || w == ">" }
    # Fills CMDW (the command word) and CMDA[1..CMDN] (its remaining words) for the
    # simple command starting at `from`, and returns where the next one starts.
    #
    # A REDIRECTION DOES NOT END A COMMAND. `shopt >/dev/null -s globstar` still
    # passes `-s globstar` to `shopt`; treating `>` as a boundary lost the operands
    # and the construct reported clean — and with the output redirected, nothing
    # else would have shown it either.
    function simple_cmd(from, i, w, pd) {
        # CMDFNNEXT IS CONFINED TO ONE SIMPLE COMMAND. It is set by the reserved
        # word and consumed by the name after it; carrying it further declared a
        # command in the NEXT segment to be a function.
        CMDW = ""; CMDN = 0; CMDFN = 0; CMDFNNEXT = 0
        for (i = from; i <= SC_ARGC; i++) {
            w = SC_ARGV[i]
            # THE REDIRECTION FORMS ARE CHECKED FIRST, because `&` is both a
            # control operator and the first character of `&>`: deciding it ends the
            # command before looking at what follows lost every operand after it.
            if (SC_AOP[i] && w == "&" && i < SC_ARGC && SC_AOP[i + 1] && is_redir(SC_ARGV[i + 1])) { i += 2; continue }
            # A SUBSTITUTION DOES NOT END THE COMMAND IT SITS IN.
            # `printf %s "$(printf x)" shopt globstar` runs two printfs, and ending
            # the outer command at the `(` made the words after the `)` look like an
            # invocation of their own. The group is stepped over here and its
            # contents are scanned separately, the same way a shell body is.
            if (SC_AOP[i] && w == "(" && SC_SUB[i]) {
                pd = 1
                while (++i <= SC_ARGC && pd > 0) {
                    if (SC_AOP[i] && SC_ARGV[i] == "(") pd++
                    else if (SC_AOP[i] && SC_ARGV[i] == ")") pd--
                }
                i--
                continue
            }
            if (SC_AOP[i] && is_op(w)) return i + 1
            # AN IO NUMBER BELONGS TO THE REDIRECTION AFTER IT. `2>/dev/null shopt
            # -s globstar` invokes `shopt`; taking the `2` as the command word lost
            # the whole simple command, and with the output redirected nothing else
            # would have shown it.
            # A DESCRIPTOR DUPLICATION IS ONE REDIRECTION: `2>&1` is the IO number,
            # the operator, the `&` and the target, and consuming only the first two
            # left the `&` to end the command.
            if (w ~ /^[0-9]+$/ && (i < SC_ARGC) && SC_AOP[i + 1] && is_redir(SC_ARGV[i + 1])) {
                i++
                if (i < SC_ARGC && SC_AOP[i + 1] && SC_ARGV[i + 1] == "&") i++
                i++
                continue
            }
            if (SC_AOP[i] && is_redir(w)) {
                # `>>`, `<<` AND `<>` ARE ONE OPERATOR. Tokenised a character at a
                # time, the second `>` of `>>log` was consumed as the preceding
                # operator TARGET, and `log` then became the command word — the real
                # command after it was only an argument.
                # `>|` OVERRIDES NOCLOBBER and is part of the operator, not a pipe
                # after it — a bar in that position belongs to the redirection.
                while (i < SC_ARGC && SC_AOP[i + 1] &&
                       (is_redir(SC_ARGV[i + 1]) || SC_ARGV[i + 1] == "|")) i++
                if (i < SC_ARGC && SC_AOP[i + 1] && SC_ARGV[i + 1] == "&") i++
                i++
                continue
            }
            if (CMDW == "") {
                # `name+=value` IS AN ASSIGNMENT PREFIX TOO, and Bash 3.2 has it —
                # not recognising it made the prefix the command word and the real
                # command an operand.
                if (w ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) continue
                # RESERVED WORDS INTRODUCE a command rather than being one:
                # `if [ -v x ]` runs `[`, not `if`. The list is the shell grammar
                # and is closed — a leading `!` is one of them, while an `!` after
                # the command word is that command an operand.
                # A COMPOUND-COMMAND HEADER IS GRAMMAR, NOT A COMMAND. `for x in …`
                # names a loop VARIABLE, and skipping only the reserved word left
                # that name looking like an invoked command with the list as its
                # arguments — `for shopt in globstar` was reported as a Bash 4
                # option. The header runs to its `do` or `in`, and there is nothing
                # in it for these rules.
                # `case x in` ENDS AT `in`, and what follows is a pattern list and
                # then commands. Grouping it with `for` made the header search for a
                # `do` that never comes, so an entire arm was consumed as grammar.
                # A HEADER IS GRAMMAR, BUT A SUBSTITUTION INSIDE ONE STILL RUNS ITS
                # COMMAND. `for x in $(grep PATTERN f)` iterates over the OUTPUT of a
                # real `grep`, and consuming every token through `do` swallowed it.
                # The header skip stops at the `(` that opens one and lets the
                # ordinary walk take the command inside.
                if (w == "case") {
                    for (i = i + 1; i <= SC_ARGC; i++)
                        if (SC_ARGV[i] == "in") break
                    continue
                }
                if (w == "for" || w == "select") {
                    # THE LIST IS PART OF THE HEADER. `for x in a b c; do` names a
                    # variable and then a WORD LIST, and stopping at `in` handed that
                    # list to the next iteration as a command with arguments.
                    #
                    # `((` IS THE ARITHMETIC FORM, and everything between the two
                    # parentheses is an expression rather than a command. A LONE `(`
                    # opens a substitution whose command the list iterates over, and
                    # the skip stops there so that command is examined.
                    pd = 0
                    for (i = i + 1; i <= SC_ARGC; i++) {
                        # A SUBSTITUTION INSIDE THE LIST IS NOT EXAMINED, and that
                        # is the trade. Stopping the skip at its `(` reaches the
                        # command inside — and then the header is gone, so the list
                        # data AFTER the `)` reads as an invocation of its own:
                        # `for x in $(printf x) shopt globstar` was rejected. One
                        # direction misses a command, the other rejects portable
                        # code, and this file has said all along which of those is
                        # worse. The whole header is grammar.
                        if (SC_AOP[i] && SC_ARGV[i] == "(") { pd++; continue }
                        if (SC_AOP[i] && SC_ARGV[i] == ")") { pd--; continue }
                        if (pd > 0) continue
                        if (SC_AOP[i] && is_op(SC_ARGV[i]) && SC_ARGV[i] != ";") return i + 1
                        if (SC_ARGV[i] == "do") break
                    }
                    continue
                }
                # `time` TAKES OPTIONS OF ITS OWN, and they are not the command:
                # `time -p shopt -s globstar` runs `shopt`.
                if (w == "time") {
                    while (i < SC_ARGC && SC_ARGV[i + 1] ~ /^-[A-Za-z]+$/) i++
                    continue
                }
                # `function name { … }` DECLARES ONE TOO, and the reserved word is
                # skipped as grammar — so the name after it would have looked like a
                # command. The declaration is recorded here as well.
                # …AND ONLY WHEN IT IS THE RESERVED WORD. `'"'"'function'"'"'; mapfile …` has
                # a quoted first word, which is an ordinary command, and a flag that
                # outlived its simple command declared the NEXT one a function.
                if (w == "function" && !SC_WQ[i]) { CMDFNNEXT = 1; continue }
                if (index(" if then elif else fi while until do done esac { } ! ", " " w " ") > 0) continue
                CMDW = w
                CMDQ = SC_WQ[i]
                # A FUNCTION DECLARATION IS NOT AN INVOCATION. `mapfile() { … }`
                # names a function and runs nothing; the `()` after the name is what
                # tells them apart, and it is recorded here because the walk ends at
                # that parenthesis rather than carrying it as an operand.
                CMDFN = (i + 2 <= SC_ARGC && SC_AOP[i + 1] && SC_ARGV[i + 1] == "(" &&
                         SC_AOP[i + 2] && SC_ARGV[i + 2] == ")")
                if (CMDFNNEXT) { CMDFN = 1; CMDFNNEXT = 0 }
            } else { CMDN++; CMDA[CMDN] = w }
        }
        return SC_ARGC + 1
    }
    # `command X` AND `builtin X` INVOKE X. `command shopt -s globstar` enables the
    # option exactly as the bare spelling does, so the wrapper is unwrapped — but
    # `command -v X` and `-V` DESCRIBE X rather than running it, which is the guard
    # pattern this tree uses everywhere, so those are left alone.
    # Drop CMDA[1..upto] and make CMDA[upto+1] the new command word. Shifting by one
    # while consuming several left the earlier ones in place: `env LC_ALL=C grep …`
    # kept the ASSIGNMENT as the first operand, and the rule that reads the first
    # operand as a pattern read that.
    function take_after(upto, i) {
        CMDW = CMDA[upto]
        for (i = upto + 1; i <= CMDN; i++) CMDA[i - upto] = CMDA[i]
        CMDN -= upto
    }
    # THE WRAPPERS COMPOSE. `command env grep …` is both of them, and running each
    # loop once in a fixed order unwrapped `command` to `env` and then stopped.
    function unwrap(i, moved) {
        moved = 1
        while (moved) {
            moved = 0
            # `env` RUNS THE COMMAND AFTER ITS OPTIONS AND ASSIGNMENTS — the spelling
            # a script reaches for when it wants a clean environment.
            if (CMDW == "env") {
                i = 1
                while (i <= CMDN && (CMDA[i] ~ /^-/ || CMDA[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) {
                    if (CMDA[i] == "-u" || CMDA[i] == "--unset") i++
                    i++
                }
                if (i > CMDN) return 0
                take_after(i); moved = 1; continue
            }
            # `exec` REPLACES THE SHELL WITH THE COMMAND after its own options —
            # the command still runs, which is all these rules care about.
            if (CMDW == "exec") {
                i = 1
                # `-a name` REPLACES argv[0] and takes the word after it; skipping
                # only the option made that name the command.
                while (i <= CMDN && CMDA[i] ~ /^-/) {
                    if (CMDA[i] ~ /^-[cl]*a$/ && i < CMDN) i++
                    i++
                }
                if (i > CMDN) return 0
                take_after(i); moved = 1; continue
            }
            if (CMDW == "command" || CMDW == "builtin") {
                i = 1
                while (i <= CMDN && CMDA[i] ~ /^-/) {
                    if (CMDA[i] == "-v" || CMDA[i] == "-V") return 0
                    i++
                }
                if (i > CMDN) return 0
                take_after(i); moved = 1; continue
            }
        }
        return 1
    }
    # True when `cmd` is invoked with an option word carrying `letter`. Options
    # cluster, so `-Ag` counts for both — and quote removal has already happened, so
    # a quoted option word is the option.
    function cmd_opt(cmd, letter, i, j, cl) {
        i = 1
        while (i <= SC_ARGC) {
            i = simple_cmd(i)
            if (!unwrap()) continue
            if (CMDW != cmd) continue
            # AN OPTION OPERAND IS NOT AN OPTION. `read -p -N value` has `-N` as
            # the PROMPT that `-p` takes, and scanning every dash-prefixed word
            # independently read it as the post-3.2 option and rejected portable
            # source. The builtins with operand-taking options are few and named.
            for (j = 1; j <= CMDN; j++) {
                if (CMDA[j] !~ /^-/) continue
                # THE LETTERS AFTER AN OPERAND-TAKING ONE ARE ITS OPERAND, attached.
                # `read -pN` gives `-p` the prompt `N`, so that is not the `-N`
                # option — the cluster is read only up to the first such letter.
                #
                # ONLY THE ONES THAT TAKE AN OPERAND. `-s` suppresses echo and takes
                # nothing, and skipping the word after it stepped over a real `-N`.
                cl = CMDA[j]
                if (cmd == "read" && match(cl, /[pntuda]/)) cl = substr(cl, 1, RSTART)
                # AN ATTACHED COUNT IS STILL THE OPTION: `read -N1` is `-N` with its
                # argument, and an alphabetic-only cluster test missed it.
                sub(/[0-9]+$/, "", cl)
                if (cl ~ /^-[A-Za-z]*$/ && index(cl, letter) > 1) return 1
                if (cmd == "read" && CMDA[j] ~ /^-[A-Za-z]*[pntuda]$/) j++
            }
        }
        return 0
    }
    # The body of an invoked `bash -c` / `sh -c`, or "" when there is none. The
    # operand is already quote-removed, which is what makes it scannable as shell.
    # EVERY literal shell body on the line, in order, joined by newlines so each is
    # a logical line of its own when it is scanned. Returning at the first one left
    # a second `bash -c` on the same line unexamined — and the wrappers apply here
    # too, because `command bash -c …` and `env bash -c …` invoke the same shell.
    # The text inside each top-level `$( … )` / `<( … )` group, joined by newlines.
    # Stepping over a group keeps the command it sits in whole; scanning the text
    # here is what keeps the command INSIDE it visible.
    # The text inside each top-level `$( … )` / `<( … )` group, recorded while the
    # line is scanned — including the ones inside double quotes, which is where they
    # usually are. Stepping over a group keeps the command it sits in whole; this is
    # what keeps the command INSIDE it visible.
    # The Bash 4 EXPANSIONS, which are the only rules that apply inside a
    # here-document body: everything else there is text bash never executes.
    # AN ESCAPED DOLLAR IS NOT AN EXPANSION. In an unquoted body `\${name}` is the
    # literal text, and the same parity that decides an escape decides this.
    function expansion_hit(l, i, n) {
        for (i = 1; i <= length(l); i++) {
            if (substr(l, i, 1) != "$") continue
            n = 0
            while (i - n - 1 >= 1 && substr(l, i - n - 1, 1) == "\134") n++
            if (n % 2 == 1) continue
            if (substr(l, i) ~ /^\$\{([A-Za-z0-9_][A-Za-z0-9_]*|[@*#?$!-])(\[[^]]*\])?(\^\^?|,,?)[^}]*\}/) return 1
            if (substr(l, i) ~ /^\$\{([A-Za-z0-9_][A-Za-z0-9_]*|[@*#?$!-])(\[[^]]*\])?@[QEPAKakUuL]\}/) return 1
        }
        return 0
    }
    function subst_bodies(l) {
        shell_scan(l, SC_Q0)
        return SC_BODIES
    }
    function shell_c_body(l, i, j, base, out) {
        shell_scan(l, SC_Q0)
        out = ""
        i = 1
        while (i <= SC_ARGC) {
            i = simple_cmd(i)
            if (!unwrap()) continue
            base = CMDW; sub(/^.*\//, "", base)
            if (base != "bash" && base != "sh") continue
            for (j = 1; j < CMDN; j++)
                # `-c` ANYWHERE IN THE CLUSTER. `bash -cx BODY` is the documented
                # spelling with a trace flag after it, and requiring `c` last read
                # the body as an ordinary operand.
                if (CMDA[j] ~ /^-[A-Za-z]*c[A-Za-z]*$/) { out = out (out == "" ? "" : "\n") CMDA[j + 1]; break }
        }
        return out
    }
    # True when `cmd` is the command word of some simple command on this line.
    function cmd_is_unquoted(cmd, i) {
        i = 1
        while (i <= SC_ARGC) {
            i = simple_cmd(i)
            if (!unwrap()) continue
            if (CMDFN) continue
            if (CMDW == cmd && !CMDQ) return 1
        }
        return 0
    }
    function cmd_is(cmd, i) {
        i = 1
        while (i <= SC_ARGC) {
            i = simple_cmd(i)
            if (!unwrap()) continue
            if (CMDFN) continue
            if (CMDW == cmd) return 1
        }
        return 0
    }
    # True when `cmd` is invoked with `opt` immediately followed by `val`.
    function cmd_optval(cmd, opt, val, i, j) {
        i = 1
        while (i <= SC_ARGC) {
            i = simple_cmd(i)
            if (!unwrap()) continue
            if (CMDW != cmd) continue
            for (j = 1; j < CMDN; j++)
                if (CMDA[j] == opt && CMDA[j + 1] == val) return 1
        }
        return 0
    }
    function cmd_has(cmd, name, i, j) {
        i = 1
        while (i <= SC_ARGC) {
            i = simple_cmd(i)
            if (!unwrap()) continue
            if (CMDW != cmd) continue
            for (j = 1; j <= CMDN; j++) if (CMDA[j] == name) return 1
        }
        return 0
    }
    # `[ -v x ]` and `test -v x` evaluate the Bash 4.2 operator; `test -v` alone is
    # the ordinary one-argument string test that every bash has, so an operand is
    # required. A leading `!` negates and changes neither answer.
    function cond_v(i, j) {
        i = 1
        while (i <= SC_ARGC) {
            i = simple_cmd(i)
            if (!unwrap()) continue
            if (CMDW != "[" && CMDW != "test") continue
            # EVERY PRIMARY, not the first one. `test \( -v token \)` groups the
            # expression, and stopping at the leading `(` never reached the operator
            # — with the `if` around it masking the old shell, nothing saw it.
            # The operand is still required: `test -v` alone is the one-argument
            # string test, and `]` or `)` after it is the end of the expression
            # rather than an operand.
            # THE THREE-ARGUMENT FORM IS A BINARY COMPARISON. `test -v = token`
            # asks whether the string `-v` equals `token`, on every bash — the
            # operator is in the MIDDLE, and reading the first word as a unary
            # primary rejected portable code.
            # The `]` of the bracket form is not an argument of the expression, and
            # counting it made the three-argument comparison look like four.
            # THE EXPRESSION IS WHAT IS LEFT AFTER THE GRAMMAR. A bracket form
            # ends with `]`, a negation begins with `!`, and a grouped expression is
            # wrapped in parentheses — none of those are operands, and counting them
            # made a three-argument comparison look like four or six.
            vb = 1; vn = CMDN
            if (CMDW == "[" && vn > 0 && CMDA[vn] == "]") vn--
            while (vb <= vn && (CMDA[vb] == "(" || CMDA[vb] == "!")) vb++
            while (vn >= vb && CMDA[vn] == ")") vn--
            # THE THREE-ARGUMENT FORM IS A BINARY COMPARISON. `test -v = token` asks
            # whether the string `-v` equals `token`, on every bash — the operator is
            # in the MIDDLE, and reading the first word as a unary primary rejected
            # portable code.
            # `-a` AND `-o` JOIN TWO EXPRESSIONS, so the arity is per PART: in
            # `test -v = token -a x = x` each side is a three-argument comparison,
            # and measuring the whole thing found seven operands and no comparison.
            # A THREE-ARGUMENT COMPARISON IS ONE, WHATEVER ITS OPERANDS ARE CALLED.
            # `test -v = -a` compares two strings and the second happens to be `-a`;
            # splitting on it first left a two-word part and no comparison at all.
            if (vn - vb + 1 == 3 && CMDA[vb + 1] ~ /^(=|==|!=|-eq|-ne|-lt|-le|-gt|-ge|<|>)$/) continue
            vpart = 1; vok = 1; vs = vb
            # …AND EACH PART CARRIES ITS OWN GROUPING. `test \( -v = token \) -a
            # \( x = x \)` leaves a parenthesis on either side of the join, and a
            # part measured with them had four operands rather than three.
            for (j = vb; j <= vn + 1; j++) {
                if (j > vn || CMDA[j] == "-a" || CMDA[j] == "-o") {
                    ps = vs; pe = j - 1
                    while (ps <= pe && (CMDA[ps] == "(" || CMDA[ps] == "!")) ps++
                    while (pe >= ps && CMDA[pe] == ")") pe--
                    if (!(pe - ps + 1 == 3 && CMDA[ps + 1] ~ /^(=|==|!=|-eq|-ne|-lt|-le|-gt|-ge|<|>)$/)) vok = 0
                    vs = j + 1
                }
            }
            if (vok) continue
            for (j = 1; j <= CMDN; j++) {
                if (CMDA[j] != "-v") continue
                if (j < CMDN && CMDA[j + 1] != "]" && CMDA[j + 1] != ")") return 1
            }
        }
        return 0
    }
    function segments(l, n, i, ch, rest) {
        shell_scan(l, SC_Q0)
        # AN ARITHMETIC EXPRESSION IS NOT A LIST OF COMMANDS. `for (( i=0; c; i++ ))`
        # separates its three parts with `;`, and splitting there handed the middle
        # one to the rules as a command of its own. The same mask the redirection
        # scan uses says which positions are inside one.
        arith_mark(l)
        # EACH SEGMENT KEEPS ITS OWN STARTING STATE. The first inherits whatever
        # quoting the logical line began inside — a word opened on an earlier
        # physical line — and every later one starts unquoted, because the operator
        # that ended the previous segment was itself unquoted.
        n = 1; SEG[1] = ""; SEGQ[1] = SC_Q0
        for (i = 1; i <= length(l); i++) {
            ch = substr(l, i, 1)
            if (SC_CTX[i] == "" && !SC_ESC[i] && !SC_ARI[i]) {
                rest = substr(l, i, 2)
                if (rest == "&&" || rest == "||") { n++; SEG[n] = ""; SEGQ[n] = ""; i++; continue }
                # `>|` IS ONE REDIRECTION — the noclobber override — so the bar
                # there is not a pipe and splitting on it left the target looking
                # like the command.
                if (ch == "|" && i > 1 && substr(l, i - 1, 1) == ">") { SEG[n] = SEG[n] ch; continue }
                if (ch == ";" || ch == "|") { n++; SEG[n] = ""; SEGQ[n] = ""; continue }
                # A LONE `&` BACKGROUNDS AND ENDS A COMMAND, so a fixed-string
                # grep followed by an ampersand and a second grep is two commands,
                # and the exemption taken by the first was covering the second.
                #
                # The `&` OF A REDIRECTION — `2>&1`, `&>f` — splits here too, and
                # is left to: a redirection carries no pattern of its own, so the
                # extra segment is `1` or `>f` and no rule has anything to say
                # about it. A guard was written for that case and removed when no
                # fixture could make it matter, which is the same reason the word
                # separator went: a branch whose invariant cannot fail reads as
                # covered when it is not.
                # …EXCEPT IN A DESCRIPTOR DUPLICATION. `2>&1 shopt -s globstar`
                # splits into `2>` and `1 shopt …`, and neither half has `shopt` as
                # its command word. A guard for this was written once and removed
                # for want of a fixture that could fail; the command-position
                # matcher is what made it observable, so it is back with one.
                # …AND `&>` PUTS THE AMPERSAND FIRST. Bash 3.2 has that spelling
                # too, so `shopt &>/dev/null -s globstar` is one command and
                # splitting there left `shopt` without its operands.
                if (ch == "&" && ((i > 1 && substr(l, i - 1, 1) ~ /[<>]/) || substr(l, i + 1, 1) ~ /[<>]/)) { SEG[n] = SEG[n] ch; continue }
                if (ch == "&") { n++; SEG[n] = ""; SEGQ[n] = ""; continue }
            }
            SEG[n] = SEG[n] ch
        }
        return n
    }
    # WHERE the operator appears outside quotes, or 0.
    function unquoted_pos(l, pat, i) {
        shell_scan(l, SC_Q0)
        for (i = 1; i <= length(l); i++)
            if (SC_CTX[i] == "" && !SC_ESC[i] && substr(l, i, length(pat)) == pat) return i
        return 0
    }
    function unquoted(l, pat) { return unquoted_pos(l, pat) > 0 }
    # `$(( … ))` REMOVED, because its left-shift is spelled `<<` and its right
    # operand is a WORD. `mask=$((value << shift))` queued `shift` as a delimiter,
    # and unless some later line was exactly `shift`, every line to EOF was
    # skipped — one arithmetic expression excusing the rest of the file. Excluding
    # only a digit operand covered `1 << 2` and nothing symbolic.
    #
    # The span is replaced by a space rather than deleted, so nothing on either
    # side joins up. It is not a lexer: an arithmetic expansion containing a quote
    # would take its quoting out of the line with it, which is a direction that
    # makes a rule report rather than excuse.
    # BOTH SPELLINGS. `$(( … ))` is the expansion and `(( … ))` is the arithmetic
    # COMMAND — `(( mask = value << shift )) || :` — and stripping only the first
    # left the second queueing `shift` as a delimiter, which is the same
    # swallow-the-file failure with a different two characters in front of it.
    # AN INLINE COMMENT OPENS NOTHING. `: # <<EOF` is a comment to bash and a
    # here-document to a scanner that removed only FULL-LINE comments: `EOF` was
    # queued, no terminator ever came, and every following line was skipped — the
    # swallow-the-file shape again, from two characters of prose.
    #
    # Only the REDIRECTION scan is stripped this way, not the rules. A forbidden
    # spelling written in an inline comment is still reported, which is the safe
    # direction: a rule that excused everything after a `#` would be excused by any
    # line that ended in one.
    # A BACKSLASH ESCAPES OUTSIDE QUOTES TOO, and the boundary check reads the
    # previous SOURCE character rather than the previous word. In `\)#` the
    # parenthesis is an escaped literal, so the `#` continues the word instead of
    # starting a comment — and treating it as one stripped a real `<<EOF` and read
    # the document body as shell.
    function strip_comment(l, i, ch, prev) {
        shell_scan(l, SC_Q0)
        for (i = 1; i <= length(l); i++) {
            if (SC_CTX[i] != "" || SC_ESC[i]) continue
            if (substr(l, i, 1) != "#") continue
            # A `#` STARTS A COMMENT ONLY AT THE START OF A WORD. `x=a#b` is a
            # value and `${x#p}` is an expansion; both keep their `#`. The
            # character before it must be a boundary AND must not have been made
            # literal by a backslash — `\)#` is one word.
            #
            # The class is spelled with `&` before `;` deliberately: the other
            # order puts a literal `;&` in this file, and rule D reads that as the
            # Bash 4 case terminator it is elsewhere.
            if (i == 1) return ""
            prev = substr(l, i - 1, 1)
            if (SC_ESC[i - 1] || SC_CTX[i - 1] != "") continue
            if (prev ~ /[[:space:]&;|()]/) return substr(l, 1, i - 1)
        }
        return l
    }
    # MARKED, NOT REMOVED. The point is only that a `<<` INSIDE an arithmetic
    # expression is not a redirection — and deleting the text to achieve that also
    # deleted `cat <<$[EOF]`, whose delimiter word is quote-removed but NOT
    # arithmetically expanded, so its terminator really is the literal `$[EOF]`.
    # Marking the span leaves every other character where it was.
    #
    # THREE SPELLINGS: `$(( … ))` is the expansion, `(( … ))` the arithmetic
    # COMMAND, and `$[ … ]` the legacy expansion Bash 3.2 still accepts — which is
    # the one this tree must keep working on.
    #
    # Quoted, it is data: `printf '%s' "(("` has no arithmetic in it, and taking
    # the quoted characters as an opener consumed the rest of the line looking for
    # a close that never came.
    # …AND `${ … }` IS AN EXPANSION, NOT A REDIRECTION EITHER. `${value#<<EOF}` is
    # a removal pattern, and the two characters in it were queueing a document whose
    # terminator never comes. The span is marked with the arithmetic ones because
    # the redirection walk asks the same question of both: is this position code.
    function arith_mark(l, i, ch, d, opener, opens, closes, k) {
        delete SC_ARI
        pex_mark(l)
        i = 1
        while (i <= length(l)) {
            if (SC_CTX[i] == "" && !SC_ESC[i]) {
                opener = 0
                if (substr(l, i, 3) == "$((")     { opener = 3; opens = "("; closes = ")" }
                else if (substr(l, i, 2) == "((") { opener = 2; opens = "("; closes = ")" }
                else if (substr(l, i, 2) == "$[") { opener = 2; opens = "["; closes = "]" }
                if (opener > 0) {
                    # Two parens to close for either paren form, one bracket for
                    # the legacy one.
                    d = (opens == "(") ? 2 : 1
                    for (k = i; k < i + opener; k++) SC_ARI[k] = 1
                    i += opener
                    while (i <= length(l) && d > 0) {
                        ch = substr(l, i, 1)
                        if (SC_CTX[i] == "" && !SC_ESC[i]) {
                            if (ch == opens) d++
                            else if (ch == closes) d--
                        }
                        SC_ARI[i] = 1
                        i++
                    }
                    continue
                }
            }
            i++
        }
    }
    function hexdigits(s, maxn, out, k, ch) {
        out = ""
        for (k = 1; k <= maxn; k++) {
            ch = substr(s, k, 1)
            if (ch == "" || index("0123456789abcdefABCDEF", ch) == 0) break
            out = out ch
        }
        return out
    }
    function hexval(h, v, k, p) {
        v = 0
        for (k = 1; k <= length(h); k++) {
            p = index("0123456789abcdef", tolower(substr(h, k, 1))) - 1
            v = v * 16 + p
        }
        return v
    }
    function octdigits(s, maxn, out, k, ch) {
        out = ""
        for (k = 1; k <= maxn; k++) {
            ch = substr(s, k, 1)
            if (ch == "" || index("01234567", ch) == 0) break
            out = out ch
        }
        return out
    }
    function octval(o, v, k) {
        v = 0
        for (k = 1; k <= length(o); k++) v = v * 8 + (index("01234567", substr(o, k, 1)) - 1)
        return v
    }
    # The character `\cX` names: the letter uppercased, with bit 64 cleared.
    # Mark every position inside a `${ … }` expansion.
    function pex_mark(l, i, d, ch) {
        d = 0
        for (i = 1; i <= length(l); i++) {
            ch = substr(l, i, 1)
            if (SC_ESC[i]) continue
            if (SC_CTX[i] == "" && substr(l, i, 2) == "${") { d++; SC_ARI[i] = 1; SC_ARI[i + 1] = 1; i++; continue }
            if (d > 0) {
                # A QUOTED BRACE IS DATA. `${unset:-"}"<<EOF}` closes at the LAST
                # brace, and counting the quoted one closed it early — after which
                # the `<<EOF` was outside the expansion and queued a document.
                if (SC_CTX[i] == "") {
                    if (ch == "{") d++
                    else if (ch == "}") d--
                }
                SC_ARI[i] = 1
            }
        }
    }
    # The character `\cX` names: X uppercased, with bit 64 toggled. `\c[` is escape
    # and `\c?` is delete, so the letters are not the whole of it — a table built
    # once is what makes any printable operand answerable.
    function ord(c, i) {
        if (ORD["A"] == "") for (i = 32; i < 127; i++) ORD[sprintf("%c", i)] = i
        return ORD[c]
    }
    function ctrl_code(c, v) {
        v = ord(toupper(c))
        if (v == "") return 0
        return v >= 64 ? v - 64 : v + 64
    }
    function ansic_decode(seg, out, i, ch, nx, h, o, k) {
        if (ESCCODE[1] == "") {
            # `\a \b \e \E \f \n \r \t \v`, in that order — the codes bash gives them.
            split("7 8 27 27 12 10 13 9 11", ESCCODE, " ")
        }
        out = ""; i = 1
        while (i <= length(seg)) {
            ch = substr(seg, i, 1)
            if (ch != "\134") { out = out ch; i++; continue }
            nx = substr(seg, i + 1)
            if (nx == "") { out = out ch; i++; continue }
            # `\\` FIRST, so `$'\\134'` is a literal backslash and then digits
            # rather than an octal escape — which is what bash does with it.
            if (substr(nx, 1, 1) == "\134") { out = out "\134"; i += 2; continue }
            # The NUMERIC forms are decoded to their actual character rather than
            # to a placeholder: `$'\x5c\x73'` is a backslash and then an `s`, and a
            # placeholder for the second would hide the escape the first produces.
            if (substr(nx, 1, 1) == "x") {
                h = hexdigits(substr(nx, 2), 2)
                if (h != "") { out = out sprintf("%c", hexval(h)); i += 2 + length(h); continue }
            }
            if (substr(nx, 1, 1) == "u") {
                h = hexdigits(substr(nx, 2), 4)
                if (h != "") { out = out sprintf("%c", hexval(h)); i += 2 + length(h); continue }
            }
            if (substr(nx, 1, 1) == "U") {
                h = hexdigits(substr(nx, 2), 8)
                if (h != "") { out = out sprintf("%c", hexval(h)); i += 2 + length(h); continue }
            }
            o = octdigits(nx, 3)
            if (o != "") { out = out sprintf("%c", octval(o)); i += 1 + length(o); continue }
            # The single-character escapes bash RECOGNISES. `\b` is a BACKSPACE
            # here, not the word boundary it is in a `grep` pattern, and keeping it
            # as backslash-plus-letter reported portable code. `\c` takes the
            # character after it as well.
            # THE RECOGNISED ESCAPES DECODE TO THEIR REAL CHARACTERS. A placeholder
            # was enough while this only answered "is there a backslash before a
            # class letter" — and then the here-document delimiter started using the
            # same decoder, where `$'"'"'\t'"'"' names a TAB and a placeholder names nothing
            # any line will ever equal.
            if ((k = index("abeEfnrtv", substr(nx, 1, 1))) > 0) {
                out = out sprintf("%c", ESCCODE[k]); i += 2; continue
            }
            if (index("\047\042?", substr(nx, 1, 1)) > 0) { out = out substr(nx, 1, 1); i += 2; continue }
            # `\cX` IS CONTROL-X — `$'"'"'\cA'"'"' is control-A, and a fixed placeholder named
            # the same character for every one of them.
            if (substr(nx, 1, 1) == "c" && length(nx) >= 2) {
                out = out sprintf("%c", ctrl_code(substr(nx, 2, 1))); i += 3; continue
            }
            # An UNRECOGNISED escape is kept as backslash-plus-character, which is
            # what bash does — and is why `$'\s'` reaches the engine as `\s`.
            out = out ch substr(nx, 1, 1); i += 2
        }
        return out
    }
    # True when a decoded `$'…'` span escapes a letter from `set`. The span ends at
    # the first UNESCAPED quote: a span can carry an escaped one inside it, and a
    # pattern that stopped at the first quote of any kind cut the span in half and
    # left the tail unexamined — the walker deliberately ignores ANSI-C text, so
    # nothing judged it at all.
    function ansic_span_end(l, from, i, ch) {
        for (i = from; i <= length(l); i++) {
            ch = substr(l, i, 1)
            if (ch == "\134") { i++; continue }
            if (ch == "\047") return i
        }
        return 0
    }
    # THE OPENER IS ONLY AN OPENER OUTSIDE QUOTES. A command can carry those two
    # characters twice: once as data inside double quotes, once opening a real
    # span. Taking the first as an opener paired it with the opening quote of the
    # REAL span, which was then never decoded — and the walker deliberately
    # ignores ANSI-C text, so nothing judged the GNU escape at all. Quote state
    # is tracked here for the same reason it is tracked in the split.
    # WHAT THE ENGINE RECEIVES, not what the source looks like. The shared model
    # already built it: quote removal, ANSI-C decoding and backslash escapes are
    # all applied. Whitespace between two arguments survives into it as itself,
    # which is all that is needed to stop a run joining across them — a separator
    # was written for that and then had no case that could tell it from the space
    # it replaced, so it went.
    #
    # A WORD CAN BE ASSEMBLED FROM SEVERAL KINDS OF QUOTING. `grep \\$'\s' f` is an
    # unquoted escape and an ANSI-C span written next to each other, contributing
    # one backslash each — two in total, which is a literal backslash and an
    # ordinary letter. Judging either part on its own got that backwards, and
    # judging them separately is what the old pair of functions did.
    # The operands of a command are ALREADY quote-removed, so their parity is read
    # directly rather than by scanning them as source a second time.
    function esc_class_eff(eff, set, i, n, ch) {
        for (i = 1; i <= length(eff); i++) {
            if (substr(eff, i, 1) != "\134") continue
            n = 0
            while (substr(eff, i, 1) == "\134") { n++; i++ }
            ch = substr(eff, i, 1)
            if (n % 2 == 1 && ch != "" && index(set, ch) > 0) return 1
            i--
        }
        return 0
    }
    function esc_class(l, set, i, n, ch) {
        shell_scan(l, SC_Q0)
        for (i = 1; i <= length(SC_EFF); i++) {
            if (substr(SC_EFF, i, 1) != "\134") continue
            n = 0
            while (substr(SC_EFF, i, 1) == "\134") { n++; i++ }
            ch = substr(SC_EFF, i, 1)
            if (n % 2 == 1 && ch != "" && index(set, ch) > 0) return 1
            i--
        }
        return 0
    }

    #
    # A HERE-DOCUMENT BODY IS DATA. `cat <<EOF` followed by prose is not shell, and
    # passing it to the rules made an ordinary mention of `grep -P` in a summary
    # block a reason to fail the mandatory gate — `SKILL.md` writes user-facing
    # text that way. The delimiter is taken from the redirection and the body is
    # skipped until it reappears alone on a line. `<<-` strips leading tabs from the
    # terminator, so that form is allowed for.
    # NOTHING CARRIES ACROSS A FILE BOUNDARY. A target that ends while a document
    # is still open would otherwise consume the NEXT target as its body, and a real
    # violation in that file would be skipped — a multi-file scan reporting clean
    # because one file was truncated. The leftover state is a failure, not a
    # nuisance: it goes to stderr, which `scan` treats as a failed scan.
    # NOTHING CARRIES ACROSS A FILE BOUNDARY. A target that ends while a document
    # is still open would otherwise consume the NEXT target as its body, and a real
    # violation there would be skipped — a multi-file scan reporting clean because
    # one file was truncated.
    #
    # CONFINED RATHER THAN FATAL. An unterminated document is usually this model
    # reading a construct differently from bash rather than a broken target, and
    # failing the whole scan on that would take the gate down for something that is
    # not a portability defect. What matters is that it cannot reach the next file.
    FNR == 1 {
        # A PENDING LOGICAL LINE IS SCANNED BEFORE THE STATE GOES. A target whose
        # last line ends in a continuation leaves its text in `buf`, and clearing
        # that at the next file discarded it — the END hook only ever sees the last
        # file, and production hands many targets to one awk. The violation went
        # out with the buffer and the scan reported clean.
        if (buf != "") { OWNER = BUFFILE; line = buf; RULES(); OWNER = "" }
        hdn = 0; hdi = 0; buf = ""; CARRY = ""
    }
    { raw = $0
      # A COMMAND CAN OPEN MORE THAN ONE DOCUMENT. `cat <<ONE <<TWO` is two, read
      # in the order written, and recording only the first meant the SECOND body
      # was scanned as shell once the first terminator arrived. The delimiters are
      # a queue, and the head is what the current body ends on.
      #
      # THE TERMINATOR IS COMPARED AGAINST THE UNTOUCHED LINE. A quoted delimiter
      # may begin with a comment character, and stripping full-line comments before
      # this check turned that terminator into an empty line: the document never
      # drained and everything after it was skipped to end of file.
      #
      # A BODY LINE IS NEVER JOINED. It is data, so a trailing backslash in it
      # continues nothing.
      if (hdn > 0) {
          # AN UNQUOTED DELIMITER MEANS THE BODY EXPANDS, so a substitution in it
          # runs its command — the body is data for the RULES, but not for that.
          # THE TERMINATOR IS NOT EXPANDED. Bash performs quote removal on the
          # delimiter word and compares the line literally, so a body line that IS
          # the terminator is not a body line at all — running the expansion check
          # over it rejected a document whose delimiter is written as an
          # expansion, against its own terminator line.
          t = $0
          if (HDD[hdi]) sub(/^\t+/, "", t)
          if (HDX[hdi] && t != HDQ[hdi]) {
              # A PARAMETER EXPANSION IS ACTIVE THERE TOO. A case-modifying one in
              # an unquoted body is performed by bash, so the Bash 4 rules for it
              # apply — while the ordinary TEXT of the body is still
              # data, which is why the whole line is not handed to the rules.
              if (expansion_hit($0)) report("case modification is Bash 4: " $0)
              hdbody = subst_bodies($0)
              if (hdbody != "") {
                  hdn2 = split(hdbody, HDB, "\n")
                  hdsave = line
                  for (hdi2 = 1; hdi2 <= hdn2; hdi2++) { line = HDB[hdi2]; RULES() }
                  line = hdsave
              }
          }
          # ONLY `<<-` STRIPS INDENTATION, and only TABS.
          if (t == HDQ[hdi]) { hdi++; if (hdi > hdn) { hdn = 0; hdi = 0 } }
          next
      }
      # FULL-LINE COMMENTS GO BEFORE ANYTHING IS INFERRED FROM THE TEXT — but
      # AFTER the terminator check above, which compares against the untouched
      # line, because a quoted delimiter may begin with a comment character.
      #
      # AND ONLY WHERE THE LINE STARTS UNQUOTED. A word opened on an earlier line
      # can carry a `#` as data — the quote then closes and a command follows on
      # the same line — and deleting from that `#` deleted the closer and the
      # command with it. Mid-continuation the same applies: the `#` is inside a
      # line that is being assembled, not at the start of one.
      # …AND ONLY WHERE THE LINE STARTS UNQUOTED. A word opened on an earlier line
      # can carry a `#` as data — the quote then closes and a command follows on the
      # same line — and deleting from that `#` deleted the closer and the command
      # with it. Mid-continuation the same applies: the `#` is inside a line being
      # assembled, not at the start of one.
      if (buf == "" && CARRY == "") sub(/^[[:space:]]*#.*$/, "", raw)
      # THE LOGICAL LINE IS ASSEMBLED FIRST, and only then read for redirections.
      # A continuation can split ANYTHING, including a delimiter word: `cat <<E\`
      # and `OF` opens a document terminated by `EOF`, and extracting before the
      # join recorded `E` and waited for a terminator that never comes.
      if (buf == "") { start = FNR; SC_LINE_Q = CARRY; BUFFILE = FILENAME }
      # …AND ONLY WHEN THE TRAILING RUN IS ODD. Two backslashes at the end are a
      # literal backslash and the command ENDS there; joining anyway glued the next
      # line on, and an exemption taken by the first half then covered the second.
      # The same parity that decides an escape decides a continuation.
      #
      # A BACKSLASH-NEWLINE INSIDE SINGLE QUOTES IS DATA. Bash keeps both, so a
      # single-quoted value split across two lines keeps the backslash and the
      # newline as characters — and joining them ran the halves together into a
      # GNU-only tool name this scan then invented out of portable code. The
      # quoting at the END of the physical line decides, which is why the line is
      # scanned before the join rather than after it.
      shell_scan(raw, CARRY)
      nbs = 0
      while (nbs < length(raw) && substr(raw, length(raw) - nbs, 1) == "\134") nbs++
      if (nbs % 2 == 1 && SC_CTX[length(raw)] != "\047") {
          sub(/\\$/, "", raw); buf = buf raw; CARRY = SC_QEND; next }
      CARRY = SC_QEND
      # A WORD LEFT OPEN IS NOT JOINED TO THE NEXT LINE, AND THAT IS A CHOICE.
      # Bash would: a quote spanning physical lines is one command, so
      # `printf %s data` opened on one line and closed on the next takes the words
      # after the closing quote as ITS operands, not as a command of their own.
      #
      # Joining them was implemented and reverted. It requires quote fidelity this
      # model does not have — a jq or awk program embedded in a string is full of
      # quoting this scan reads differently from bash, and every such spot became
      # contagious, gluing unrelated lines together. Two real targets started
      # failing the gate for constructs they do not contain. A rule that rejects
      # portable code is worse than one that misses a rare construct, so the lines
      # stay separate and the carried quote state is all that crosses.
      #
      # What that costs: on the line after an unclosed quote, a command word cannot
      # be told from an operand of the command that opened it. The two spellings
      # are indistinguishable without the join, and this takes the reading that
      # reports a construct rather than the one that excuses it.
      line = buf raw; buf = ""

      # AN INLINE COMMENT OPENS NOTHING, and a `<<` inside an arithmetic expression
      # is not a redirection. Both are decided on the same string, through the
      # shared model, so the positions stay absolute and the delimiter word is read
      # from the line as written.
      SC_Q0 = SC_LINE_Q
      hdsrc = strip_comment(line)
      shell_scan(hdsrc, SC_Q0); arith_mark(hdsrc)
      # QUOTE STATE CARRIES TO THE NEXT LINE. `x='"'"'data` and then `'"'"'; shopt …` is one
      # word split across two physical lines, and a scan restarting at every line
      # read the closing quote as an opener — everything after it became data and
      # the rule saw nothing.
      CARRY = SC_QEND
      hp = 1
      while (hp < length(hdsrc)) {
          if (SC_CTX[hp] != "" || SC_ESC[hp] || SC_ARI[hp] || substr(hdsrc, hp, 2) != "<<") { hp++; continue }
          # `<<<` is a here-STRING and has no terminator.
          if (substr(hdsrc, hp, 3) == "<<<") { hp += 3; continue }
          hdk = hp + 2
          hddash = (substr(hdsrc, hdk, 1) == "-")
          if (hddash) hdk++
          while (substr(hdsrc, hdk, 1) == " " || substr(hdsrc, hdk, 1) == "\t") hdk++
          # THE DELIMITER IS A WHOLE WORD, and bash quote-removes it. What the word
          # may contain is for bash to say; it ends where an unquoted character
          # ends a word.
          #
          # A WORD THAT IS PRESENT BUT EMPTY IS STILL A WORD: a delimiter of two
          # quote characters and nothing between them reads to a blank terminator
          # line. `hdsaw` is what tells that from a `<<` with no word at all,
          # which an emptiness test alone could not.
          # A SUBSTITUTION-SHAPED DELIMITER IS TAKEN WHOLE. Bash does not expand the
          # delimiter word, so `<<$(printf EOF)` names that text — parentheses,
          # space and all — and stopping at the `(` recorded a prefix of it.
          hdw = ""; hdsaw = 0; hdquoted = 0
          while (hdk <= length(hdsrc)) {
              hdc = substr(hdsrc, hdk, 1)
              # A BACKSLASH THAT QUOTES SOMETHING IS NOT IN THE WORD, wherever it
              # sits: keeping it recorded a delimiter no line will ever equal.
              # AN ANSI-C SPAN CONTRIBUTES ITS DECODED TEXT. `cat <<$'"'"'EOF'"'"'` names
              # `EOF`; appending the characters as written recorded the dollar and
              # the quotes, and no line ever equals that.
              # EVERY QUOTING FORM SUPPRESSES EXPANSION, not only the two quote
              # characters: `<<\EOF` and `<<$'"'"'EOF'"'"'` are quoted delimiters as much as
              # `<<'"'"'EOF'"'"'` is, and the branches that consumed them were not saying so —
              # so their bodies were treated as expanding and portable source was
              # rejected.
              # `$"…"` IS LOCALE TRANSLATION, and a quoted delimiter like the rest:
              # the `$` is not part of the word, and appending it recorded a name no
              # line will ever equal.
              # …AND ONLY WHERE THE QUOTING IS ACTIVE. Inside single quotes the two
              # characters are literal text, so `<<'"'"'$"EOF"'"'"'` names `$"EOF"` — discarding
              # the dollar there recorded a word no line will ever equal.
              if (SC_CTX[hdk] == "" && !SC_ESC[hdk] && substr(hdsrc, hdk, 2) == "$\042") {
                  hdk++; hdsaw = 1; hdquoted = 1; continue }
              if (SC_CTX[hdk] == "$" && substr(hdsrc, hdk, 2) == "$\047") {
                  hdquoted = 1
                  hden = ansic_span_end(hdsrc, hdk + 2)
                  if (hden > 0) {
                      hdw = hdw ansic_decode(substr(hdsrc, hdk + 2, hden - hdk - 2))
                      hdsaw = 1; hdk = hden + 1; continue
                  }
              }
              # A SUBSTITUTION-SHAPED PART IS TAKEN WHOLE, WHEREVER IT SITS. The
              # delimiter word is not expanded, so `<<x$(printf EOF)` names that
              # text — parentheses and the space inside them included — and the
              # ordinary word loop would have stopped at the `(`.
              #
              # IT QUOTES NOTHING, THOUGH: none of its characters are quoted, so a
              # body under this delimiter still expands. Marking it quoted, which is
              # what the first version of this did, suppressed that.
              if (substr(hdsrc, hdk, 2) == "$(") {
                  # QUOTING COUNTS INSIDE IT TOO: a quoted parenthesis in the
                  # substitution closes nothing, and decrementing at every one
                  # recorded a prefix of the word.
                  hdp = 1; hdj = hdk + 2
                  while (hdj <= length(hdsrc) && hdp > 0) {
                      if (SC_CTX[hdj] == "" && !SC_ESC[hdj]) {
                          if (substr(hdsrc, hdj, 1) == "(") hdp++
                          else if (substr(hdsrc, hdj, 1) == ")") hdp--
                      }
                      hdj++
                  }
                  # QUOTE-REMOVED LIKE THE REST OF THE WORD. Bash applies quote
                  # removal to the whole delimiter, substitution-shaped part and
                  # all, so the terminator carries no quote characters — keeping
                  # them named a word no line will equal.
                  # FULL QUOTE REMOVAL, not only the quote characters: a
                  # BACKSLASH that quotes something is gone too, so `x$(printf E\OF)`
                  # names `x$(printf EOF)`.
                  for (hdq = hdk; hdq < hdj; hdq++) {
                      if (SC_CTX[hdq] == "" && (substr(hdsrc, hdq, 1) == "\047" ||
                                                substr(hdsrc, hdq, 1) == "\042")) continue
                      if (SC_CTX[hdq] != "" && !SC_ESC[hdq] && substr(hdsrc, hdq, 1) == SC_CTX[hdq]) continue
                      if (substr(hdsrc, hdq, 1) == "\134" && SC_ESC[hdq + 1]) continue
                      hdw = hdw substr(hdsrc, hdq, 1)
                  }
                  hdsaw = 1
                  hdk = hdj; continue
              }
              if (hdc == "\134" && SC_ESC[hdk + 1]) { hdk++; hdsaw = 1; hdquoted = 1; continue }
              if (SC_CTX[hdk] == "" && !SC_ESC[hdk]) {
                  # `&` before `;` again: the other order writes a literal `;&`
                  # into this file, which rule D reads as a case terminator.
                  if (hdc ~ /[[:space:]&;|<>()]/) break
                  if (hdc == "\047" || hdc == "\042") { hdk++; hdsaw = 1; hdquoted = 1; continue }
                  if (hdc == "\134") { hdk++; hdsaw = 1; hdquoted = 1; continue }
              # An ESCAPED quote inside a quoted delimiter is part of the word.
              } else if (SC_CTX[hdk] != "" && !SC_ESC[hdk] && hdc == SC_CTX[hdk]) { hdk++; hdsaw = 1; continue }
              hdw = hdw hdc; hdsaw = 1
              hdk++
          }
          # WHETHER THE DELIMITER WAS QUOTED DECIDES WHETHER THE BODY EXPANDS.
          # With an unquoted one bash performs substitution inside the body, so a
          # `$( … )` there really invokes its command — and the body was being
          # skipped whole.
          if (hdsaw) { hdn++; HDQ[hdn] = hdw; HDD[hdn] = hddash; HDX[hdn] = !hdquoted }
          hp = (hdk > hp) ? hdk : hp + 2
      }
      if (hdn > 0) hdi = 1 }
'
SCAN_EPILOGUE='
    END { if (buf != "") { line = buf; RULES() } }
'
scan() {   # scan <awk-rule-body> <file…> ; prints hits, 2 if the scan failed
    local prog="$1"; shift
    local errf out rc msg mrc
    # INSIDE THE SCRATCH DIRECTORY THIS FILE OWNS, not wherever `mktemp` points.
    # Existence and writability do not establish OWNERSHIP: a `mktemp` handing back
    # an existing writable path — a stub, a hostile `TMPDIR`, a collision — gives
    # the scan a file it truncates with `2>` and deletes on the way out, which
    # under root is somebody else's file. Validating the path was the wrong repair;
    # not asking for one is the right one. The directory is already allocated and
    # already validated, so a name inside it needs no second check.
    #
    # It is where a failed scan REPORTS ITSELF, which is why this fails closed
    # rather than falling back to the current directory: no diagnostics file means
    # a failure that looks like a clean result.
    [ -n "${PORT_TMPDIR:-}" ] && [ -d "$PORT_TMPDIR" ] || return 2
    errf="$PORT_TMPDIR/scan-stderr"
    : > "$errf" 2>/dev/null || return 2
    rc=0
    # The body is wrapped in a function so the END block can run it on a trailing
    # unterminated continuation — a file whose last line ends in a backslash would
    # otherwise never be examined at all.
    out="$(awk "$SCAN_PROLOGUE"'
        { RULES() }
        # `BA` IS A LOCAL ARRAY, and that matters: this function calls itself for
        # each substitution and each shell body, and a shared split target would be
        # overwritten by the nested call while the outer loop was still walking it.
        function RULES(  nseg, si, lq, body, saved, nb, BA) {
            # `WHOLE` survives the split, for the constructs the split destroys:
            # `;&` is a case terminator and splitting on `;` takes it apart.
            # AN INLINE COMMENT IS NOT CODE HERE EITHER. `: # note; mapfile` invokes
            # nothing after the `#`, and the splitter has no comment state — so the
            # `;` in the comment separated a command that does not exist.
            WHOLE = strip_comment(line)
            lq = SC_Q0
            nseg = segments(WHOLE)
            for (si = 1; si <= nseg; si++) { line = SEG[si]; SEGI = si; SC_Q0 = SEGQ[si]; ONE() }
            SC_Q0 = lq
            line = WHOLE
            # A LITERAL `bash -c` BODY IS SHELL. It arrives as ONE operand of
            # `bash`, so a rule about an invoked command never sees the command
            # inside it. The body is scanned as its own input, once: a body that
            # itself spawns another shell is not followed, and saying so is cheaper
            # than a recursion this file would then have to bound.
            # SUBSTITUTIONS ARE EXTRACTED AT EVERY LEVEL, including inside a shell
            # body: `bash -c '"'"'out=$(… | grep …)'"'"'` has the engine one level further in,
            # and the guard that stops a shell body spawning another shell was
            # stopping this too. Only the SHELL recursion is bounded.
            body = subst_bodies(WHOLE)
            if (body != "") {
                saved = WHOLE
                nb = split(body, BA, "\n")
                SC_Q0 = ""
                for (si = 1; si <= nb; si++) { line = BA[si]; RULES() }
                line = saved; WHOLE = saved; SC_Q0 = lq
            }
            if (!NESTED) {
                body = shell_c_body(WHOLE)
                if (body != "") {
                    saved = WHOLE
                    NESTED = 1; SC_Q0 = ""
                    nb = split(body, BA, "\n")
                    for (si = 1; si <= nb; si++) { line = BA[si]; RULES() }
                    NESTED = 0
                    line = saved; WHOLE = saved; SC_Q0 = lq
                }
            }
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
    # FIXED-STRING MODE AND THE ENGINE COME FROM THE WORDS. Quote removal happens
    # before the command sees either: `grep '-F' pat f` passes the ordinary option,
    # and `gr"ep"` IS `grep`. A raw-text test saw neither, so the first rejected
    # portable code and the second skipped the check entirely.
    # THE ENGINE IS THE INVOKED COMMAND, not a word that appears. `printf %s grep`
    # runs `printf`, and reading its operand as an engine reported the unrelated
    # pattern beside it — the same command-position rule rule D already uses.
    # EACH ENGINE IS JUDGED ON ITS OWN ARGUMENTS. A segment can hold more than one:
    # `grep -F x $(grep PATTERN f)` has a fixed-string outer command and an inner one
    # that is not, and accumulating the mode across both let the outer exempt the
    # inner. The operands of the command are what its own pattern is made of.
    shell_scan(line, SC_Q0)
    ai = 1
    while (ai <= SC_ARGC) {
        ai = simple_cmd(ai)
        if (!unwrap()) continue
        efixed = 0; egrepsed = 0
        # A PATH-QUALIFIED ENGINE IS THE SAME ENGINE. `/usr/bin/grep` is GNU grep on
        # one platform and BSD grep on the other, which is exactly the difference
        # this rule exists for, and the leading path hid it.
        ebase = CMDW; sub(/^.*\//, "", ebase)
        if (ebase == "fgrep") { efixed = 1; egrepsed = 1 }
        else if (ebase ~ /^(grep|egrep|sed)$/) egrepsed = 1
        else if (ebase !~ /^(awk|gawk)$/) continue
        # `-F` IS AN OPTION IN ITS OWN POSITION, and only for the grep family.
        # `awk -F ,` sets the field separator; `grep -e PATTERN -e -F` makes the
        # second `-F` a PATTERN, because `-e` takes the next word whatever it looks
        # like; and after `--` a leading dash is a filename. Each of those read as
        # fixed-string mode and exempted a command whose pattern is not.
        for (aj = 1; aj <= CMDN; aj++) {
            if (CMDA[aj] == "--") break
            if (CMDA[aj] ~ /^-[A-Za-z]*[ef]$/) { aj++; continue }
            if (!egrepsed) continue
            # `F` ANYWHERE IN THE CLUSTER. `grep -Fq PATTERN` has both options
            # active, and requiring `F` last read it as an ordinary option word.
            if (CMDA[aj] ~ /^-[A-Za-z]*F[A-Za-z]*$/ || CMDA[aj] == "--fixed-strings") efixed = 1
        }
        if (efixed) continue
        # ONLY THE OPERANDS THAT CARRY A PATTERN. `grep x '"'"'file\s'"'"'` searches for
        # `x` in a file whose NAME contains a backslash, which is the same search on
        # both platforms — concatenating every argument reported the filename.
        #
        # Which operand is the pattern is a small rule per engine and not an option
        # parser: for `grep` it is the operand of each `-e`, or else the first
        # non-option word; `sed` and `awk` take their script the same way. Anything
        # after `--` or after that first word is a FILE.
        eargs = ""; epat = 0
        for (aj = 1; aj <= CMDN; aj++) {
            if (CMDA[aj] == "--") { aj++; if (!epat && aj <= CMDN) { eargs = eargs " " CMDA[aj]; epat = 1 } break }
            # `-e` CARRIES A PATTERN; `-f` NAMES A FILE OF THEM. Appending the
            # filename read its name as a pattern — and `sed -f script` and
            # `awk -f prog` are files for the same reason.
            # AN OPTION THAT TAKES AN ARGUMENT CONSUMES IT, or the argument is
            # read as the pattern: `awk -F , PROGRAM` would otherwise make the comma
            # the program. The list is per engine and short — awk takes `-F` and
            # `-v`, and `-f` names a file for all three.
            # …and grep has its own: `-m NUM`, `-A`/`-B`/`-C` and `-d ACTION` all
            # take the next word, which was otherwise read as the pattern.
            if (egrepsed && CMDA[aj] ~ /^-[mABCd]$/ && aj < CMDN) { aj++; continue }
            # `awk -F PATTERN` IS A REGULAR EXPRESSION. gawk reads `\s` there as a
            # whitespace class and the awk macOS ships does not, so the field split
            # differs — discarding the operand hid that.
            # …ATTACHED OR SEPARATED. `awk -F'"'"'PATTERN'"'"'` is one word after quote
            # removal, and an exact-equality test saw only the separated spelling.
            if (!egrepsed && CMDA[aj] ~ /^-F.+$/) { eargs = eargs " " substr(CMDA[aj], 3); continue }
            if (!egrepsed && CMDA[aj] == "-F" && aj < CMDN) { aj++; eargs = eargs " " CMDA[aj]; continue }
            if (!egrepsed && CMDA[aj] ~ /^-[Fv]$/ && aj < CMDN) { aj++; continue }
            if (CMDA[aj] ~ /^-[A-Za-z]*f$/ && aj < CMDN) { aj++; epat = 1; continue }
            # …AND THE VALUE MAY BE ATTACHED. `grep -e'"'"'PATTERN'"'"'` is one word after
            # quote removal, and its suffix is the active pattern — this was on the
            # list of forms the model did not follow, and it comes off that list.
            # AN ATTACHED `-f` OPERAND IS A FILENAME, and it may contain an `e`:
            # `sed -f'engine\s'` names a file, and finding the later letter in the
            # same word read the filename as a pattern.
            # THE FIRST OPERAND-TAKING LETTER IN THE CLUSTER OWNS THE REST OF THE
            # WORD. `-efoo\s` is `-e` with the pattern `foo\s` — and it contains an
            # `f` further along, which a test looking anywhere in the word read as
            # `-f` and discarded. `-f` names a file and `-e` carries a pattern, so
            # which letter comes first decides.
            if (CMDA[aj] ~ /^-[A-Za-z]*[ef].+$/ && CMDA[aj] !~ /^--/) {
                if (match(CMDA[aj], /[ef]/)) {
                    if (substr(CMDA[aj], RSTART, 1) == "e") {
                        eargs = eargs " " substr(CMDA[aj], RSTART + 1)
                    }
                    # EITHER WAY THE PROGRAM IS SUPPLIED. `awk -f prog.awk file` takes
                    # its program from the FILE, so every later word is an input file
                    # and none of them is a pattern.
                    epat = 1
                    continue
                }
            }
            if (CMDA[aj] ~ /^-[A-Za-z]*e$/ && aj < CMDN) { aj++; eargs = eargs " " CMDA[aj]; epat = 1; continue }
            if (CMDA[aj] ~ /^-/) continue
            if (!epat) { eargs = eargs " " CMDA[aj]; epat = 1 }
        }
        if (egrepsed && esc_class_eff(eargs, "sSdDwWbBy<>")) {
            report("GNU regex escape: " line); return }
        if (!egrepsed && esc_class_eff(eargs, "sSdDwWBy<>")) {
            report("gawk-only regex operator: " line); return }
    }
    return'


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
                dircolors numfmt shred
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
# SINGLE-QUOTED TEXT IS STILL SCANNED, AND THAT IS THE CHOICE RATHER THAN AN
# OVERSIGHT. `printf '%s' '${name^^}'` is data, and this rule reports it. Skipping
# single-quoted text would fix that — and would excuse `bash -c 'mapfile -t a < f'`,
# which is not data but the ordinary way this tree runs code in a child shell:
# `test-loadlib.sh` is built on exactly that spelling. Telling the two apart is
# knowing whether the string is executed, which is the analysis this file does not
# do; the version that guessed would report PASS while its invariant was false,
# which CLAUDE.md records as worse than no check at all.
#
# So the trade is the same one `|&` already makes, and it is bounded on both
# sides. The cost is a false positive on a Bash 4 spelling quoted as data, which a
# contributor sees immediately and can spell around; nothing in this tree hits it,
# and the one place such text belongs — the planted fixtures — is below
# `PORT_SPLIT` and outside the self-scan by construction.
#
# `${!name}` is NOT here: indirect expansion is Bash 2, and only the Bash 4
# `${!prefix@}`/`${!array[@]}` name-listing forms would be — neither is used.
RULE_D='
    # THE WORD LIST IS BUILT FOR THIS SEGMENT FIRST. Every rule below asks about
    # the invoked command, and the list is a global — so a rule reading it before
    # anything had scanned THIS segment was answering about the previous one. It
    # showed up as a `mapfile` reported against a line containing only `:`.
    shell_scan(line, SC_Q0)
    # AS COMMAND WORDS, like every other builtin rule here. `printf '"'"'%s'"'"' mapfile`
    # runs `printf`, and a raw word pattern rejected it — the last of the Bash 4
    # rules that was still reading the line rather than the command.
    if (cmd_is("mapfile") || cmd_is("readarray")) {
        report("mapfile/readarray is Bash 4; use a while-read loop: " line); return }
    # THE OPTION WORD MAY BE QUOTED. Shell quote removal happens before `declare`
    # sees its arguments, so a quoted option word — the dash and the letter
    # wrapped in quotes — declares an associative array
    # exactly as the bare form does — and the pattern, anchored on whitespace
    # immediately before the dash, saw the quote and passed it. One optional quote
    # character on each side, which is the whole of what quote removal does to an
    # option word; this is a pattern for a construct, not an option parser.
    # AS A COMMAND WORD, for the same reason `-g` is: quote removal happens first,
    # so `de"clare" -A` invokes the ordinary builtin and a raw pattern could not see
    # it. `local` is a function-scope builtin and gets the same treatment.
    if (cmd_opt("declare", "A") || cmd_opt("typeset", "A") || cmd_opt("local", "A")) {
        report("associative arrays are Bash 4: " line); return }
    # `-g` DECLARES A GLOBAL FROM INSIDE A FUNCTION — Bash 4.2. Bash 3.2 rejects the
    # option and the variable is simply never set, which is a behaviour difference
    # rather than a failure, so nothing else would show it.
    #
    # AS A COMMAND WORD, like every other builtin rule here: `printf %s declare -g`
    # runs `printf`, and the raw pattern this arrived as reported it.
    if (cmd_opt("declare", "g") || cmd_opt("typeset", "g")) {
        report("declare -g is Bash 4.2: " line); return }
    # `wait -n` RETURNS WHEN THE FIRST JOB FINISHES — Bash 4.3. Bash 3.2 rejects the
    # option and returns at once, so what follows races rather than failing, which
    # is the shape nothing but text finds.
    if (cmd_opt("wait", "n")) {
        report("wait -n is Bash 4.3: " line); return }
    # `read -N` READS EXACTLY THAT MANY CHARACTERS and `-i` seeds the line editor —
    # both after 3.2, which rejects the option and leaves different state behind
    # rather than failing outright.
    # `declare -n` MAKES A NAMEREF — Bash 4.3. Bash 3.2 rejects the option and the
    # assignment through it goes somewhere else, which is a behaviour difference
    # rather than a failure.
    # `local -n` IS THE SAME OPTION on the function-scope builtin, and the spelling
    # a nameref is usually written with.
    if (cmd_opt("declare", "n") || cmd_opt("typeset", "n") || cmd_opt("local", "n")) {
        report("declare -n is Bash 4.3: " line); return }
    # `declare -u` AND `-l` CONVERT CASE ON ASSIGNMENT — Bash 4. Bash 3.2 rejects
    # the attribute and stores what it was given, which is a different value rather
    # than a failure.
    if (cmd_opt("declare", "u") || cmd_opt("declare", "l") ||
        cmd_opt("typeset", "u") || cmd_opt("typeset", "l") ||
        cmd_opt("local", "u")   || cmd_opt("local", "l")) {
        report("declare -u and -l are Bash 4: " line); return }
    if (cmd_opt("read", "N") || cmd_opt("read", "i")) {
        report("this read option is newer than Bash 3.2: " line); return }
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
    # `{fd}>file` ALLOCATES A DESCRIPTOR AND NAMES IT — Bash 4, and Bash 3.2 reads
    # the brace as an ordinary word. One more spelling in a finite list.
    # OUTSIDE QUOTES, AT THE POSITION THAT MATCHES. A quoted `{fd}>file` is data,
    # and testing "is there an unquoted `}>` somewhere" separately from "does the
    # shape appear somewhere" let one supply the position and the other the shape.
    shell_scan(line, SC_Q0)
    for (fdi = 1; fdi <= length(line); fdi++) {
        if (substr(line, fdi, 1) != "{") continue
        if (SC_CTX[fdi] != "" || SC_ESC[fdi]) continue
        # `${fd}>out` IS AN EXPANSION AND THEN A REDIRECTION, which Bash 3.2 has.
        # The brace of an allocation stands alone; a `$` in front makes it something
        # else entirely.
        # AT A WORD BOUNDARY. `x{fd}>out` is an ordinary argument and then a
        # redirection, and a `$` in front makes `${fd}>out` an expansion — an
        # allocation begins its word.
        # AT A LEXICAL WORD START. `x{fd}>out` and `$(printf x){fd}>out` are both
        # ordinary words followed by a redirection — a `)` ends a substitution and
        # the word CONTINUES through it, so it is not a boundary.
        # `(` OPENS A COMMAND, so `({fd}>file printf x)` really allocates — while
        # `)` ENDS a substitution and the word continues through it, which is why
        # the two brackets are not the same answer.
        if (fdi > 1 && substr(line, fdi - 1, 1) !~ /[[:space:];&|<(]/) continue
        if (substr(line, fdi) ~ /^\{[A-Za-z_][A-Za-z0-9_]*\}[<>]/) {
            report("a {varname} descriptor is Bash 4: " line); return }
    }
    if (SEGI <= 1 && unquoted(WHOLE, "&>>")) {
        report("&>> is a Bash 4 redirection: " WHOLE); return }
    if (SEGI <= 1 && unquoted(WHOLE, "|&")) {
        report("|& is a Bash 4 pipeline: " WHOLE); return }
    # THE STEP MAY BE SIGNED. `{5..1..-1}` counts down and is the same Bash 4
    # feature; an unsigned `[0-9]+` for the step read the `-` as not-a-step and let
    # the descending form through — the spelling a descending loop actually uses.
    # THE ENDPOINTS TAKE A SIGN TOO, not only the step: `{1..-1..-1}` counts down
    # through zero, and requiring unsigned endpoints let that spelling through.
    if (line ~ /\{-?[0-9]+\.\.-?[0-9]+\.\.-?[0-9]+\}/ || line ~ /\{[A-Za-z]\.\.[A-Za-z]\.\.-?[0-9]+\}/) {
        report("a stepped brace expansion is Bash 4: " line); return }
    # EVERY OPERAND, not the first one after the flags. `shopt -s nullglob
    # globstar` enables both, and a pattern allowing only flag words between the
    # two missed it — with the status masked by a `|| :`, the CI job passes as
    # well and nothing sees it.
    # JUDGED ON WHAT `shopt` RECEIVES, not on the source text: `shopt -s '"'"'globstar'"'"'`
    # passes the same operand and the quotes are gone by then. The shared model
    # already builds that string, and using it here is the same move as judging
    # escape parity on it.
    # JUDGED ON THE ARGUMENT LIST, not on a flattened string. A separator byte
    # written into one collides with the same byte produced by an ANSI-C escape —
    # `shopt -s $'"'"'nullglob\002globstar'"'"'` is ONE invalid operand — so the boundaries
    # are structural instead. `shopt -s '"'"'globstar'"'"'` still counts, because quote
    # removal happens before the words are built.
    shell_scan(line, SC_Q0)
    # THE OPTIONS ADDED AFTER 3.2, as a list rather than one name. Each changes
    # behaviour rather than failing: `lastpipe` keeps the last stage of a pipeline
    # in the current shell, `autocd` turns a directory name into a `cd`, and Bash
    # 3.2 simply rejects the option and carries on differently. A list because
    # `shopt` options are enumerated in the manual per release — not a pattern,
    # which would need to know what an option name looks like.
    for (si2 = 1; si2 <= split("globstar lastpipe autocd checkjobs dirspell direxpand globasciiranges inherit_errexit localvar_inherit compat32 compat40 compat41 compat42 compat43 compat44", SHOPT4, " "); si2++)
        if (cmd_has("shopt", SHOPT4[si2])) {
            report("the " SHOPT4[si2] " shell option is newer than Bash 3.2: " line); return }
    # THERE IS NO `set -o globstar` RULE, and there was one until this round.
    # `globstar` is a SHOPT option; `set -o` has its own list and does not include
    # it, so every bash rejects that command — the rule could only ever have fired
    # on source that fails everywhere. It is gone rather than narrowed.
    # AS AN UNQUOTED RESERVED WORD. `'coproc' true` is an ordinary command name on
    # every bash, because quoting prevents the reserved-word reading — and the word
    # list has already had the quotes removed by the time a rule sees it.
    # THE COMMAND WORD\'"'"'S OWN QUOTING DECIDES IT. `'"'"'coproc'"'"' coproc` has a quoted
    # first word — an ordinary command — and an unquoted one as its operand, and
    # asking whether the line contains an unquoted `coproc` anywhere conflated them.
    if (cmd_is_unquoted("coproc")) {
        report("coproc is Bash 4: " line); return }
    # `[ -v x ]` AND `test -v x` ARE THE SAME OPERATOR. Bash 4.2 added it to all
    # three spellings and 3.2 has none of them; recognising only the `[[ … ]]` form
    # let the other two through, and they are the ones a script written for
    # portability would reach for.
    if (line ~ /\[\[[^]]*[[:space:]]-v[[:space:]]/) {
        report("[[ -v ]] is Bash 4.2: " line); return }
    # NEGATED COUNTS. `[ ! -v token ]` and `test ! -v token` evaluate the same
    # Bash 4.2 operator, and a pattern requiring it immediately after the command
    # missed both — while the `if` around them masks the failure, so nothing else
    # sees it either.
    # …and the same for `-v`, which also needs `(` and `)` to be tokens of their
    # own: `(test -v token)` is a subshell running `test`, and a flattened string
    # left the parenthesis stuck to the command name.
    if (cond_v()) {
        report("the -v conditional is Bash 4.2: " line); return }'

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
# `set -o globstar` IS NOT A SPELLING OF IT. `globstar` is a shopt option; `set -o`
# has its own list and does not include it, so that command fails on every bash —
# the rule that reported it could only ever have fired on source that is broken
# everywhere, which is not a portability defect.
refute setglob "set -o globstar 2>/dev/null || :"   D "a set -o option that does not exist"
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

# ── AN ESCAPED BACKSLASH IS NOT AN ESCAPE ──────────────────────────────────
# `grep '\\s' "$f"` passes TWO backslashes and an `s`. Both engines read that as an
# escaped literal backslash followed by an ordinary `s`, so it means the same thing
# on either platform — and a pattern that started at the SECOND backslash reported
# it as a GNU class escape, making a mandatory pre-push gate reject correct code.
# That is the failure this file calls worse than missing a defect, because it is
# how a check gets switched off rather than obeyed.
# TWO backslashes in the file, built with a counted variable rather than a
# printf format, because the escaping of a backslash count is the thing under
# test and a format string adds a second layer of it.
one_bs='\'
bs="\\"; dq='"'; sq="'"
two_bs='\\'
printf '#!/usr/bin/env bash\ngrep %s%ss%s "$f"\n' "'" "$two_bs" "'" > "$PTMP/evenesc.sh"
ee_hits="$(scan "$RULE_A" "$PTMP/evenesc.sh")" || ee_hits=SCANFAIL
{ [ "$ee_hits" != SCANFAIL ] && [ -z "$ee_hits" ]; } \
    && pass "an escaped backslash before a class letter is accepted" \
    || die "the scan rejected a portable escaped backslash ('$ee_hits')"
# …and a THIRD backslash makes it an escape again: the literal backslash, then a
# `\s` that really is the GNU class. Parity, not pairing.
three_bs='\\\'
printf '#!/usr/bin/env bash\ngrep %s%ss%s "$f"\n' "'" "$three_bs" "'" > "$PTMP/oddesc.sh"
oe_hits="$(scan "$RULE_A" "$PTMP/oddesc.sh")" || oe_hits=SCANFAIL
{ [ "$oe_hits" != SCANFAIL ] && [ -n "$oe_hits" ]; } \
    && pass "…while an odd run of backslashes still escapes the letter" \
    || die "three backslashes before s were read as portable ('$oe_hits')"

# ── THE SHELL HALVES A RUN INSIDE DOUBLE QUOTES ────────────────────────────
# `grep "\\s" f` writes two backslashes and passes ONE, so the engine sees the GNU
# `\s` — the same command the single-quoted spelling of two backslashes does NOT
# produce. Counting the source run alone read this as portable and let a real
# incompatibility through: the gate reporting clean on a script BSD reads
# differently, which is the failure mode this whole file exists to remove.
printf '#!/usr/bin/env bash\ngrep "%ss" "$f"\n' "$two_bs" > "$PTMP/dqeven.sh"
de_hits="$(scan "$RULE_A" "$PTMP/dqeven.sh")" || de_hits=SCANFAIL
{ [ "$de_hits" != SCANFAIL ] && [ -n "$de_hits" ]; } \
    && pass "two backslashes inside DOUBLE quotes still reach the engine as one" \
    || die "a double-quoted \\\\s was read as portable ('$de_hits')"
# …and three inside double quotes become two, which is a literal backslash and an
# ordinary letter. Same arithmetic, opposite answer.
printf '#!/usr/bin/env bash\ngrep "%ss" "$f"\n' "$three_bs" > "$PTMP/dqodd.sh"
do_hits="$(scan "$RULE_A" "$PTMP/dqodd.sh")" || do_hits=SCANFAIL
{ [ "$do_hits" != SCANFAIL ] && [ -z "$do_hits" ]; } \
    && pass "…while three inside double quotes are a literal backslash" \
    || die "a double-quoted literal backslash was reported ('$do_hits')"
# UNQUOTED, a lone backslash is REMOVED rather than kept: `grep \\s f` searches for
# a plain `s` and is portable, so the counts differ again by context.
printf '#!/usr/bin/env bash\ngrep %ss "$f"\n' "$one_bs" > "$PTMP/bareone.sh"
bo_hits="$(scan "$RULE_A" "$PTMP/bareone.sh")" || bo_hits=SCANFAIL
{ [ "$bo_hits" != SCANFAIL ] && [ -z "$bo_hits" ]; } \
    && pass "…and an unquoted lone backslash is removed, not passed" \
    || die "an unquoted single backslash was reported ('$bo_hits')"

# ── THE TWO REMOVAL LISTS ARE KEPT IN STEP BY A CHECK, NOT BY A COMMENT ────
# The workflow said it was "KEPT IN STEP with GNU_ONLY_NAMES" and nothing verified
# it. A name in the scan but not in the job is covered by text alone and misses the
# runtime-assembled spelling; a name in neither is covered by nothing at all, which
# is how `shred` sat uncovered. This is the check that comment was standing in for.
PORT_WF="$SELF_DIR/../../../.github/workflows/tests.yml"
if [ -f "$PORT_WF" ]; then
    wf_tools="$(awk '/^ *tools="/{f=1} f{print} f && /"[[:space:]]*$/{exit}' "$PORT_WF")"
    if [ -z "$wf_tools" ]; then
        die "the portability job's tool list could not be read"
    else
        # NO EXEMPTIONS. The `g`-prefixed spellings were exempt for one round,
        # because hiding `gawk` on Ubuntu removed `awk` — the same file — and the
        # suite, which is written in awk, could not run. The job preserves a real
        # POSIX `awk` under its own name before hiding the GNU one now, so the
        # containment holds for every name and there is no list of which entries
        # it does not hold for.
        missing=""
        for n in $GNU_ONLY_NAMES; do
            # The quotes go first: the last name is adjacent to the closing one,
            # so `gnproc"` was a token that matched nothing — the check reporting a
            # gap in the list rather than in the code.
            printf '%s' "$wf_tools" | tr -d '"' | tr -s ' \n' '\n\n' | grep -qxF "$n" || missing="$missing $n"
        done
        [ -z "$missing" ] \
            && pass "every scanned GNU-only name is also removed by the CI job" \
            || die "in the scan but not hidden by the portability job:$missing"
    fi
else
    die "the portability workflow is not where this check expects it"
fi

# ── THE DIAGNOSTICS FILE IS ONE THIS RUN OWNS ──────────────────────────────
# The scan's stderr file is where a failed scan reports itself, and it is opened
# with `2>`, which TRUNCATES, and removed afterwards. Asking `mktemp` for it meant
# taking whatever it returned: an earlier repair required the path to be absolute
# and to exist, and neither establishes ownership — a stub, a hostile `TMPDIR` or
# a collision hands back a real file, and under root that is somebody else's.
#
# So the path is a name inside the scratch directory this run allocated. What is
# left to prove is that a scan with nowhere of its own to write FAILS rather than
# writing somewhere else: no diagnostics file means a failure indistinguishable
# from a clean result.
printf '#!/usr/bin/env bash\ngrep -qE "\\s" "$f"\n' > "$PTMP/needstmp.sh"
mk_rc=0
( PORT_TMPDIR="$PTMP/no-such-directory" scan "$RULE_A" "$PTMP/needstmp.sh" >/dev/null 2>&1 ) || mk_rc=$?
[ "$mk_rc" -eq 2 ] \
    && pass "a scan with no scratch directory of its own fails closed" \
    || die "the scan ran without owned scratch space (rc=$mk_rc)"
mk_rc=0
( PORT_TMPDIR="" scan "$RULE_A" "$PTMP/needstmp.sh" >/dev/null 2>&1 ) || mk_rc=$?
[ "$mk_rc" -eq 2 ] \
    && pass "…and an unset one is refused rather than defaulted" \
    || die "an empty PORT_TMPDIR was accepted (rc=$mk_rc)"
# …and nothing is written into the working directory in either case, which is what
# a relative path from an unvalidated `mktemp` used to do.
mkdir -p "$PTMP/cwd"
( cd "$PTMP/cwd" && PORT_TMPDIR="" scan "$RULE_A" "$PTMP/needstmp.sh" >/dev/null 2>&1 ) || true
[ -z "$(ls -A "$PTMP/cwd" 2>/dev/null)" ] \
    && pass "…and nothing is written into the working directory" \
    || die "a refused scan left files in the current directory"

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

# ── ANSI-C QUOTING LOOKS SINGLE-QUOTED AND IS NOT ──────────────────────────
# `grep $'\\s' f` collapses the pair the way double quotes do and hands the engine
# the GNU `\s`. Read as ordinary single quoting, both backslashes survived the
# count and the gate called an incompatible script clean.
printf '#!/usr/bin/env bash\ngrep $%s%ss%s "$f"\n' "'" "$two_bs" "'" > "$PTMP/ansic.sh"
ac_hits="$(scan "$RULE_A" "$PTMP/ansic.sh")" || ac_hits=SCANFAIL
{ [ "$ac_hits" != SCANFAIL ] && [ -n "$ac_hits" ]; } \
    && pass "ANSI-C quoting collapses the pair, like double quotes" \
    || die "a \$'..' escape was read as portable ('$ac_hits')"
# …and three backslashes inside it are a literal backslash again, so it is the
# arithmetic that differs from single quoting rather than the direction.
printf '#!/usr/bin/env bash\ngrep $%s%ss%s "$f"\n' "'" "$three_bs" "'" > "$PTMP/ansicodd.sh"
ao_hits="$(scan "$RULE_A" "$PTMP/ansicodd.sh")" || ao_hits=SCANFAIL
{ [ "$ao_hits" != SCANFAIL ] && [ -z "$ao_hits" ]; } \
    && pass "…while three inside it are a literal backslash" \
    || die "a literal backslash in \$'..' was reported ('$ao_hits')"

# ── A BACKSLASH CAN BE SYNTHESISED ─────────────────────────────────────────
# `grep $'\134s' f` contains no `\s` anywhere in its source: octal 134 IS the
# backslash, and ANSI-C quoting decodes it before grep sees the GNU `\s`. Counting
# literal backslashes saw `\1` and called the script clean.
printf '#!/usr/bin/env bash\ngrep $%s\\134s%s "$f"\n' "'" "'" > "$PTMP/ansicoct.sh"
oc_hits="$(scan "$RULE_A" "$PTMP/ansicoct.sh")" || oc_hits=SCANFAIL
{ [ "$oc_hits" != SCANFAIL ] && [ -n "$oc_hits" ]; } \
    && pass "an octal backslash inside \$'..' still escapes the letter" \
    || die "\$'\\134s' was read as portable ('$oc_hits')"
# …and the hex spelling of the same character.
printf '#!/usr/bin/env bash\ngrep $%s\\x5cs%s "$f"\n' "'" "'" > "$PTMP/ansichex.sh"
hx_hits="$(scan "$RULE_A" "$PTMP/ansichex.sh")" || hx_hits=SCANFAIL
{ [ "$hx_hits" != SCANFAIL ] && [ -n "$hx_hits" ]; } \
    && pass "…and the hex spelling of it" \
    || die "\$'\\x5cs' was read as portable ('$hx_hits')"
# …while `\\134` is a literal backslash followed by DIGITS, because the pair is
# consumed first — which is what bash does, and the reason the order matters.
printf '#!/usr/bin/env bash\ngrep $%s\\\\134s%s "$f"\n' "'" "'" > "$PTMP/ansicesc.sh"
ae_hits="$(scan "$RULE_A" "$PTMP/ansicesc.sh")" || ae_hits=SCANFAIL
{ [ "$ae_hits" != SCANFAIL ] && [ -z "$ae_hits" ]; } \
    && pass "…while an escaped backslash before the digits is not an octal escape" \
    || die "\$'\\\\134s' was read as an escape ('$ae_hits')"

# ── THE UNICODE ESCAPES TAKE A VARIABLE NUMBER OF DIGITS ───────────────────
# Bash accepts ONE to four hex digits after `\u` and one to eight after `\U`, so
# `$'\u5c'` is the same backslash as `$'\'`. Recognising only the padded
# spelling left the short one unread and the script called clean.
for spec in 'u5c' 'u05c' 'U5c' 'U0000005c'; do
    printf '#!/usr/bin/env bash\ngrep $%s\\%ss%s "$f"\n' "'" "$spec" "'" > "$PTMP/ansicw.sh"
    uw_hits="$(scan "$RULE_A" "$PTMP/ansicw.sh")" || uw_hits=SCANFAIL
    { [ "$uw_hits" != SCANFAIL ] && [ -n "$uw_hits" ]; } \
        && pass "\$'\\$spec' is a backslash, whatever its width" \
        || die "\$'\\${spec}s' was read as portable ('$uw_hits')"
done
# …and `\0134` is NOT one, which was this decoder's own false positive: bash reads
# it as `\013` followed by `4` — a vertical tab and a digit. Checked by running it.
printf '#!/usr/bin/env bash\ngrep $%s\\0134s%s "$f"\n' "'" "'" > "$PTMP/ansicvt.sh"
vt_hits="$(scan "$RULE_A" "$PTMP/ansicvt.sh")" || vt_hits=SCANFAIL
{ [ "$vt_hits" != SCANFAIL ] && [ -z "$vt_hits" ]; } \
    && pass "…while \$'\\0134' is a vertical tab and a digit, not a backslash" \
    || die "\$'\\0134s' was read as an escape ('$vt_hits')"
# …and a decoded character that is not a backslash is still the character it is:
# `$'\x5c\x73'` is a backslash and then an `s`, which is the GNU escape.
printf '#!/usr/bin/env bash\ngrep $%s\\x5c\\x73%s "$f"\n' "'" "'" > "$PTMP/ansicpair.sh"
ap_hits="$(scan "$RULE_A" "$PTMP/ansicpair.sh")" || ap_hits=SCANFAIL
{ [ "$ap_hits" != SCANFAIL ] && [ -n "$ap_hits" ]; } \
    && pass "…and a numerically spelled letter is still that letter" \
    || die "\$'\\x5c\\x73' was read as portable ('$ap_hits')"
# …and `\b` inside these quotes is a BACKSPACE, not the word boundary it is in a
# grep pattern, so the portable spelling is accepted.
printf '#!/usr/bin/env bash\ngrep $%s\\b%s "$f"\n' "'" "'" > "$PTMP/ansicbs.sh"
ab_hits="$(scan "$RULE_A" "$PTMP/ansicbs.sh")" || ab_hits=SCANFAIL
{ [ "$ab_hits" != SCANFAIL ] && [ -z "$ab_hits" ]; } \
    && pass "…and \$'\\b' is a backspace, which is portable" \
    || die "a backspace escape was reported ('$ab_hits')"

# ── THE SPAN ENDS AT THE FIRST UNESCAPED QUOTE ─────────────────────────────
# `$'x\'\134s'` carries an escaped quote. Stopping at the first quote of any kind
# cut the span in half and left the `\134s` unexamined — and the walker
# deliberately ignores ANSI-C text, so nothing judged it at all.
printf '#!/usr/bin/env bash\ngrep $%sx\\%s\\134s%s "$f"\n' "'" "'" "'" > "$PTMP/ansicq.sh"
aq_hits="$(scan "$RULE_A" "$PTMP/ansicq.sh")" || aq_hits=SCANFAIL
{ [ "$aq_hits" != SCANFAIL ] && [ -n "$aq_hits" ]; } \
    && pass "an escaped quote does not end the ANSI-C span" \
    || die "the span stopped at an escaped quote ('$aq_hits')"

# ── AN ESCAPED BOUNDARY CHARACTER IS PART OF THE WORD ──────────────────────
# In `printf … \)# <<EOF` the parenthesis is an escaped literal, so the `#`
# continues the word rather than starting a comment — and the redirection after it
# is REAL. Reading the previous source character alone stripped it, and the
# document body was then scanned as shell.
{ printf '#!/usr/bin/env bash\n'
  printf 'printf %s \\)# <<EOF\n' "'%s\\n'"
  printf 'grep -qE "\\s" is example text\n'
  printf 'EOF\n'; } > "$PTMP/escparen.sh"
ep_hits="$(scan "$RULE_A" "$PTMP/escparen.sh")" || ep_hits=SCANFAIL
{ [ "$ep_hits" != SCANFAIL ] && [ -z "$ep_hits" ]; } \
    && pass "an escaped boundary character does not start a comment" \
    || die "an escaped ) let the # strip a real redirection ('$ep_hits')"

# ── AN ANSI-C OPENER IS ONE ONLY OUTSIDE QUOTES ────────────────────────────
# A command can carry the two characters twice: once as data inside double quotes,
# once opening a real span. Taking the first as an opener paired it with the
# opening quote of the REAL span, which was then never decoded — and the walker
# deliberately ignores ANSI-C text, so nothing judged the GNU escape at all.
printf '#!/usr/bin/env bash\ngrep -e "$%s" -e $%s\\134s%s "$f"\n' "'" "'" "'" > "$PTMP/ansicdq.sh"
ad_hits="$(scan "$RULE_A" "$PTMP/ansicdq.sh")" || ad_hits=SCANFAIL
{ [ "$ad_hits" != SCANFAIL ] && [ -n "$ad_hits" ]; } \
    && pass "a quoted \$' is data, and the real span is still decoded" \
    || die "a quoted \$' consumed the real ANSI-C span ('$ad_hits')"

# ── A CONTINUATION IS REMOVED, NOT REPLACED ────────────────────────────────
# Bash deletes the backslash-newline and joins the halves directly, so a command
# split inside its own NAME is still that command. Joining with a space made
# `gaw\` and `k …` two words that are not the name — and in the portability job the
# missing tool was masked by a `|| :`, so both jobs read clean for code that fails
# on stock macOS.
{ printf '#!/usr/bin/env bash\n'
  printf 'gaw\\\n'
  printf "k 'BEGIN { exit 0 }' || :\n"; } > "$PTMP/splitname.sh"
sn_hits="$(scan '
    if (line ~ /(^|[^A-Za-z0-9_.-])gawk([^A-Za-z0-9_-]|$)/) { report("hit"); return }' "$PTMP/splitname.sh")" || sn_hits=SCANFAIL
{ [ "$sn_hits" != SCANFAIL ] && [ -n "$sn_hits" ]; } \
    && pass "a name split across a continuation is still that name" \
    || die "gaw\\ + k was not read as gawk ('$sn_hits')"
# …and the space that belongs between two words is the one already in the source,
# before the backslash, so a continued command does not run together either.
{ printf '#!/usr/bin/env bash\n'
  printf 'grep -qE \\\n'
  printf '"\\s" "$f"\n'; } > "$PTMP/contword.sh"
cw_hits="$(scan "$RULE_A" "$PTMP/contword.sh")" || cw_hits=SCANFAIL
{ [ "$cw_hits" != SCANFAIL ] && [ -n "$cw_hits" ]; } \
    && pass "…while a continuation between words keeps them apart" \
    || die "a continued command lost its word boundary ('$cw_hits')"

plant globstartwo "shopt -s nullglob globstar || :"          D "globstar as a second shopt operand"
plant vtest      "if [ -v token ]; then observed=yes; fi"    D "the -v conditional in single brackets"
plant vbuiltin   "if test -v token; then observed=yes; fi"   D "the -v conditional in the test builtin"
# …and the operand may be QUOTED, which `shopt` never sees: quote removal happens
# first, so the rule is applied to what the command receives.
plant globstarq  "shopt -s 'globstar' || :"                    D "a quoted globstar operand"
# …and the conditional may be NEGATED, in either command form. The `if` around it
# masks the failure, so nothing else sees these two either.
plant vneg       "if [ ! -v token ]; then observed=yes; fi"  D "a negated -v in single brackets"
plant vnegtest   "if test ! -v token; then observed=yes; fi" D "a negated -v in the test builtin"
# …and a QUOTED argument is one argument, whatever whitespace is inside it.
# `shopt -s "nullglob globstar"` passes a single invalid option name and enables
# nothing; `test "! -v token"` is a one-argument string test. Flattening quoted
# whitespace to ordinary whitespace read both as several words and rejected them.
refute globstarone "shopt -s \"nullglob globstar\" || :"       D "a quoted pair that is one invalid operand"
refute vstring     "if test \"! -v token\"; then :; fi"        D "a one-argument string test"
# …and the boundary is STRUCTURAL, so a decoded byte cannot be mistaken for one:
# `shopt -s $'"'"'nullglob\002globstar'"'"'` is a single invalid operand whichever byte a
# flattened representation happened to pick.
refute globstarbyte "shopt -s \$'"'"'nullglob\\002globstar'"'"' || :"       D "an operand carrying the separator byte"
# …and a control operator is a token of its own, so the command word beside it is
# still the command word.
plant vparen     "token=1; if (test -v token); then observed=yes; fi" D "a -v conditional inside a subshell"
plant globstarparen "(shopt -s globstar) || :"                D "globstar inside a subshell"
# …and a REDIRECTION does not end the command: `shopt >/dev/null -s globstar`
# still passes both operands, and with the output redirected nothing else would
# have shown it either.
plant globstarredir "shopt >/dev/null -s globstar || :"       D "globstar after a redirection"
plant vredir     "if test >/dev/null -v token; then :; fi"    D "a -v conditional after a redirection"
# …while the builtin has to be the COMMAND WORD. `printf %s shopt -s globstar`
# runs `printf`, and rejecting it is rejecting portable code.
refute globstardata "printf %s shopt -s globstar"             D "the name as an operand of another command"
refute vdata        "printf %s test -v token"                 D "the conditional as data"
# …and `-v` needs an OPERAND: alone it is the one-argument string test that every
# bash has.
refute vbare     "if test -v; then :; fi"                     D "a bare -v, which is a string test"
refute vbarebrk  "if [ -v ]; then :; fi"                      D "a bare -v in brackets"
# …and the grammar around a simple command: an IO number belongs to the redirection
# after it, `command` and `builtin` invoke what follows them, and a grouped test
# expression still has primaries inside it.
plant globstario  "2>/dev/null shopt -s globstar || :"        D "globstar behind an IO number"
plant globstarcmd "command shopt -s globstar || :"            D "globstar through the command builtin"
plant vgroup     "if test \( -v token \); then :; fi"            D "a -v primary inside a grouped expression"
plant fdvar      'exec {logfd}>/dev/null || :'                 D "a {varname} descriptor allocation"
# …while `command -v X` DESCRIBES X rather than running it, which is the guard
# pattern this tree uses everywhere.
refute vprobe    "command -v test -v token >/dev/null && :"   D "a command -v probe, which runs nothing"
# …and a descriptor duplication is one redirection, not a background operator:
# `2>&1 shopt -s globstar` is a single command with its stderr joined to stdout.
plant globstardup "2>&1 shopt -s globstar || :"               D "globstar behind a descriptor duplication"
# …and the shell options that arrived after 3.2 are a list, not one name.
plant lastpipe   "shopt -s lastpipe || :"                     D "lastpipe, a post-3.2 shell option"
plant declareg   "f() { declare -g observed=yes; }; f || :"   D "declare -g, which is Bash 4.2"
# …while the THREE-argument test is a binary comparison on every bash: the operator
# is in the middle and the first word is an operand.
refute vbinary   "if test -v = token; then :; fi"             D "a three-argument string comparison"
refute vbinbrk   "if [ -v = token ]; then :; fi"              D "the same comparison in brackets"
# …and `&>` puts the ampersand FIRST, a spelling Bash 3.2 also has.
plant globstarampfirst "shopt &>/dev/null -s globstar || :"   D "globstar behind an ampersand-first redirection"
# …while a compound-command HEADER is grammar: `for x in …` names a loop variable,
# and the words after it are a list, not a command with arguments.
refute forheader "for shopt in globstar; do :; done"          D "a loop variable that shares a builtin name"
refute declaredata "printf %s declare -g"                     D "declare -g as data"
# …and `compat31` is Bash 3.2 asking for 3.1 behaviour, so it is not newer than the
# platform this gate supports. It was listed by mistake.
refute compat31  "shopt -s compat31 || :"                     D "compat31, which Bash 3.2 provides"
# …and the rest of the header: the LIST after `in` belongs to it, and `time` takes
# options of its own before the command it measures.
refute forlist   "for x in shopt globstar; do :; done"        D "a for-list whose words share builtin names"
refute forlistA  "for x in grep '\\s'; do :; done"             A "a for-list carrying a pattern"
plant timeopt    "time -p shopt -s globstar || :"             D "globstar behind a timed prefix"
plant waitn      "sleep 0 & wait -n || :"                     D "wait -n, which is Bash 4.3"
# …and a literal `bash -c` body is shell: the command inside it is invoked, and a
# rule about an invoked command never saw it while it was one operand of `bash`.
plant nestedwait "bash -c 'wait -n || :'"                     D "wait -n inside a bash -c body"
plant nestedopt  "bash -c 'shopt -s globstar' || :"           D "globstar inside a bash -c body"
# …and the arithmetic FOR header is a header: the expression inside it is not a
# command, whatever its words are called.
refute arithfor  "for (( i=0; shopt + globstar; i++ )); do :; done" D "an arithmetic for header"
# …and the wrappers a command can arrive through, and the redirections it can sit
# behind, and the arms of a `case`.
plant envengine  "env grep -qE ${sq}${bs}s${sq} ${dq}\$f${dq} || :"        A "an engine invoked through env"
plant envshell   "env bash -c 'wait -n || :'"                 D "a shell body behind env"
plant cmdshell   "command bash -c 'wait -n || :'"             D "a shell body behind the command builtin"
plant twobodies  "bash -c ':'; bash -c 'wait -n || :'"        D "a second shell body on the same line"
plant appendred  ">>log shopt -s globstar || :"               D "globstar behind an appending redirection"
plant casearm    "case x in x) shopt -s globstar || : ;; esac" D "globstar inside a case arm"
plant procsub    "out=\$(cat <(grep -qE ${sq}${bs}s${sq} ${dq}\$f${dq})) || :" A "an engine inside a process substitution"
# …while `-F` is an option only in its own position and only for the grep family,
# and `-f` names a FILE of patterns rather than carrying one.
refute awkfs     "awk -F , '\''/x/'\'' \"$f\""                       A "awk -F, which sets a field separator"
# …and the same command WITH an escape must still report: if `-F` were read as
# fixed-string mode the whole command would be skipped, which is what the refute
# above cannot show on its own.
plant awkfspat   "awk -F , ${sq}/${bs}s/${sq} ${dq}\$f${dq}"                A "a gawk operator behind a field separator"
refute grepfile  "grep -f 'patterns\\s' \"$f\""                   A "a -f operand, which names a file"
# …and the rest of what a command can be written behind or through.
plant noclobber  ">|log shopt -s globstar || :"                D "globstar behind a noclobber redirection"
plant envassign  "env LC_ALL=C grep -qE ${sq}${bs}s${sq} ${dq}\$f${dq} || :" A "an engine behind an env assignment"
plant twowrap    "command env grep -qE ${sq}${bs}s${sq} ${dq}\$f${dq} || :" A "an engine behind two wrappers"
plant clusterc   "bash -cx 'wait -n || :'"                     D "a shell body behind a clustered -c"
# …and a substitution INSIDE a compound header is not examined. Stopping the skip
# at its `(` reaches the command and then loses the header, so the list data after
# the `)` reads as an invocation of its own — portable code rejected to catch a rare
# command. The whole header is grammar.
refute headerdata "for x in \$(printf x) shopt globstar; do :; done" D "list data after a substitution in a header"
plant grepmax    "grep -m 1 -E ${sq}${bs}s${sq} ${dq}\$f${dq} || :"       A "a pattern after an option that takes a number"
plant signedends "for i in {1..-1..-1}; do :; done"            D "a stepped expansion with signed endpoints"
plant assembled  "de\"clare\" -A values || :"                   D "an associative array whose name is assembled"
plant readn      "IFS= read -r -N 1 first < ${dq}\$f${dq} || :"      D "read -N, which is newer than Bash 3.2"
# …while a NEGATED three-argument comparison is still a comparison.
refute vnegbin   "if test ! -v = token; then :; fi"            D "a negated three-argument comparison"
# …and GROUPING is not an operand either: `test \( ! -v = token \)` is the same
# comparison wrapped in parentheses, and counting them made it six arguments.
refute vgroupbin "if test \( ! -v = token \); then :; fi"      D "a grouped negated comparison"
# …and an option OPERAND is not an option: `read -p -N value` has `-N` as the
# prompt that `-p` takes.
refute readprompt "IFS= read -p -N value < ${dq}\$f${dq}"           D "a prompt that looks like a newer option"
# …while `-s` takes NOTHING, so the option after it is still an option.
plant readsn     "IFS= read -s -N 1 value < ${dq}\$f${dq} || :"      D "read -N behind a flag that takes no operand"
# …and `-a`/`-o` join two expressions, so the arity is measured per PART.
refute vcompound "if test -v = token -a x = x; then :; fi"     D "a compound of two comparisons"
plant nameref    "target=value; declare -n ref=target || :"    D "declare -n, which is Bash 4.3"
# …and a substitution does not end the command it sits in: the words after the `)`
# belong to the command that opened it.
refute outerdata "printf %s ${dq}\$(printf x)${dq} shopt globstar"  D "words after a substitution in the same command"
# …and the remaining spellings of the same constructs.
plant localn     "f() { local -n ref=\$1 || :; }; f target"     D "local -n, the usual nameref spelling"
plant appendpfx  "prefix+=x shopt -s globstar || :"            D "globstar behind an append-assignment prefix"

# …while each part of a compound comparison carries its own grouping.
refute vgroupand "if test \( -v = token \) -a \( x = x \); then :; fi" D "two grouped comparisons joined by -a"
# …and a three-argument comparison is one whatever its operands are CALLED:
# `test -v = -a` compares two strings and the second happens to be an operator name.
refute vopname   "if test -v = -a; then :; fi"                 D "a comparison whose operand is named -a"
plant declareu   "value=abc; declare -u value || :"            D "declare -u, which converts case on assignment"
# …and `exec` replaces the shell with the command after its own options, which
# still runs it.
plant execengine "exec grep -qE ${sq}${bs}s${sq} ${dq}\$f${dq}"             A "an engine invoked through exec"
# …and `exec -a name` replaces argv[0], so the name is not the command.
plant execname   "exec -a alt grep -qE ${sq}${bs}s${sq} ${dq}\$f${dq}"      A "an engine behind exec -a"
# …while a quoted descriptor allocation is data.
refute fdquoted  "printf %s ${sq}{fd}>file${sq}"               D "a quoted descriptor allocation"
# …even when an unrelated `}>` appears unquoted elsewhere on the same line: the two
# tests were independent, so one supplied the position and the other the shape.
refute fdmixed   "printf %s ${sq}{fd}>file${sq} x}>out"        D "a quoted allocation beside an unquoted brace"
# …and `read -pN` attaches the prompt to `-p`, so it is not the `-N` option.
refute readattach "IFS= read -pN value < ${dq}\$f${dq}"            D "a prompt attached to its option"
# …while `-N1` attaches the COUNT to the option, which is still the option.
plant readcount  "IFS= read -N1 value < ${dq}\$f${dq} || :"          D "read -N with an attached count"
# …and `-e` may carry its pattern attached, which is the active regex.
plant grepattach "grep -e${sq}${bs}s${sq} ${dq}\$f${dq} || :"              A "a pattern attached to its option"
# …while a Bash 4 builtin NAME is a command word like any other.
refute mapdata   "printf %s mapfile coproc"                    D "Bash 4 builtin names used as data"
refute fdexpand  "fd=value; printf %s \${fd}>out"              D "an expansion followed by a redirection"
# …and an allocation begins its WORD: `x{fd}>out` is an argument and a redirection.
refute fdword    "printf %s x{fd}>out"                         D "a brace inside an ordinary word"
# …and `set -- globstar` sets a positional parameter rather than the option.
refute setdashdash "set -- globstar"                           D "globstar as a positional parameter"
# …and a quoted `coproc` is an ordinary command name on every bash.
refute coprocq   "${sq}coproc${sq} true || :"                  D "a quoted coproc, which is not the reserved word"
# …and a function DECLARATION is not an invocation.
refute mapfunc   "mapfile() { printf %s \"\$1\"; }"              D "a function that shares a builtin name"
# …while `awk -F PATTERN` is a regular expression, so an escape in it counts.
plant awkfsesc   "awk -F ${sq}${bs}s${sq} ${sq}{ print \$1 }${sq} ${dq}\$f${dq}" A "a gawk operator in a field separator"
# …while an attached `-f` operand is a FILENAME, whose backslash is not regex.
refute sedfile   "sed -f${sq}engine${bs}s${sq} input"          A "a filename attached to -f"
# …while `-e` attached carries the PATTERN, and the letter that comes first in the
# cluster owns the rest of the word — `-efoo\s` is `-e`, not `-f`.
plant grepefirst "grep -e${sq}foo${bs}s${sq} ${dq}\$f${dq} || :"           A "a pattern attached to -e that contains an f"
# …and an attached field separator is a pattern too.
plant awkfattach "awk -F${sq}${bs}s${sq} ${sq}{ print \$1 }${sq} ${dq}\$f${dq}" A "an attached gawk field separator"
# …and `function name { }` declares one as much as `name()` does.
refute funckw    "function mapfile { printf %s \"\$1\"; }"       D "a function declared with the reserved word"
# …and an allocation begins a WORD, which a substitution before it does not end.
refute fdafter   "printf %s \$(printf x){fd}>out"             D "a brace after a substitution in one word"
# …while a quoted command word is not the reserved word, whatever follows it.
refute coprocop  "${sq}coproc${sq} coproc || :"                D "a quoted coproc with an unquoted operand"
# …and an inline comment is not code: the splitter has no comment state of its own.
refute inlinecmd ": # note; mapfile"                           D "a builtin name inside an inline comment"
# …and an ESCAPED character is quoted for the same reason a quoted one is.
refute coprocesc "${bs}coproc true || :"                       D "an escaped coproc, which is not the reserved word"
# …and the declaration flag belongs to ONE simple command.
plant funcleak   "${sq}function${sq}; mapfile -t values < f || :" D "a builtin after a quoted function word"
# …and `(` opens a command, so a brace after it really allocates.
plant fdsubshell "({fd}>file printf x) || :"                   D "a descriptor allocation inside a subshell"
# …while `awk -f prog` takes its program from a FILE, so later words are inputs.
refute awkprog   "awk -f program.awk ${sq}file${bs}s${sq}"     A "an input file after a program file"
# …while `$"grep"` is locale translation and invokes `grep`.
plant localeword "LC_ALL=C \$${dq}grep${dq} -qE ${sq}${bs}s${sq} ${dq}\$f${dq}" A "an engine written as a locale-quoted word"

# ── THE LEGACY ARITHMETIC EXPANSION IS ARITHMETIC TOO ──────────────────────
# `$[ … ]` is the old spelling, and Bash 3.2 — the platform this whole file exists
# for — still accepts it. Its left shift is spelled `<<` like the others, so
# leaving it out queued the right operand as a delimiter and skipped to end of file
# waiting for a terminator that never comes.
{ printf '#!/usr/bin/env bash\n'
  printf 'n=$[1 << 2 ]\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/legacyarith.sh"
la_hits="$(scan "$RULE_A" "$PTMP/legacyarith.sh")" || la_hits=SCANFAIL
{ [ "$la_hits" != SCANFAIL ] && [ -n "$la_hits" ]; } \
    && pass "the legacy \$[ ] arithmetic opens no here-document" \
    || die "\$[1 << 2 ] swallowed the rest of the file ('$la_hits')"

# ── AN ARITHMETIC-LOOKING DELIMITER IS A DELIMITER ─────────────────────────
# `cat <<$[EOF]` names the literal `$[EOF]`: a delimiter word is quote-removed but
# NOT arithmetically expanded. Deleting arithmetic spans before looking for
# redirections took the word with them, so no document was queued and the body was
# read as shell. The spans are marked now, and everything else stays where it is.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<$[EOF]\n'
  printf 'grep -qE "\\s" is example text\n'
  printf '$[EOF]\n'; } > "$PTMP/arithdelim.sh"
ad2_hits="$(scan "$RULE_A" "$PTMP/arithdelim.sh")" || ad2_hits=SCANFAIL
{ [ "$ad2_hits" != SCANFAIL ] && [ -z "$ad2_hits" ]; } \
    && pass "an arithmetic-looking delimiter word survives the arithmetic mark" \
    || die "cat <<\$[EOF] queued no document ('$ad2_hits')"

# ── A TERMINATOR MAY BEGIN WITH A COMMENT CHARACTER ────────────────────────
# `cat <<'#EOF'` names `#EOF`. Stripping full-line comments before checking the
# terminator turned it into an empty line: the document never drained and a real
# violation after it was skipped to end of file.
{ printf '#!/usr/bin/env bash\n'
  printf "cat <<'#EOF'\n"
  printf 'body text\n'
  printf '#EOF\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/hashdelim.sh"
hd2_hits="$(scan "$RULE_A" "$PTMP/hashdelim.sh")" || hd2_hits=SCANFAIL
{ [ "$hd2_hits" != SCANFAIL ] && [ -n "$hd2_hits" ]; } \
    && pass "a terminator beginning with # still ends the document" \
    || die "a #EOF terminator was stripped to an empty line ('$hd2_hits')"

# ── A NUMERIC DELIMITER IS STILL A DELIMITER ───────────────────────────────
# `cat <<'123'` is a document. The numeric test was guarding against the arithmetic
# left shift, whose `<<` is marked as arithmetic before any of this runs — so it was
# covering a case that no longer arrives and rejecting a real one that does.
{ printf '#!/usr/bin/env bash\n'
  printf "cat <<'123'\n"
  printf 'grep -qE "\\s" is example text\n'
  printf '123\n'; } > "$PTMP/numdelim.sh"
nd_hits="$(scan "$RULE_A" "$PTMP/numdelim.sh")" || nd_hits=SCANFAIL
{ [ "$nd_hits" != SCANFAIL ] && [ -z "$nd_hits" ]; } \
    && pass "a numeric here-document delimiter is accepted" \
    || die "cat <<'123' was refused as a delimiter ('$nd_hits')"

# ── THE DELIMITER IS READ FROM THE JOINED LINE ─────────────────────────────
# A continuation can split ANYTHING, including the delimiter word. Extracting
# before the join recorded `E` from `cat <<E\` and waited for a terminator that
# never comes, so a later violation was skipped to end of file.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<E%s\n' "$one_bs"
  printf 'OF\n'
  printf 'body text\n'
  printf 'EOF\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/contdelim.sh"
cd2_hits="$(scan "$RULE_A" "$PTMP/contdelim.sh")" || cd2_hits=SCANFAIL
{ [ "$cd2_hits" != SCANFAIL ] && [ -n "$cd2_hits" ]; } \
    && pass "a delimiter split across a continuation is read whole" \
    || die "cat <<E\\ + OF recorded the wrong delimiter ('$cd2_hits')"
# …and a BODY line is never joined: it is data, so a trailing backslash in it
# continues nothing and the terminator after it still arrives.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<EOF\n'
  printf 'body ending in a backslash %s\n' "$one_bs"
  printf 'EOF\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/bodycont.sh"
bc_hits="$(scan "$RULE_A" "$PTMP/bodycont.sh")" || bc_hits=SCANFAIL
{ [ "$bc_hits" != SCANFAIL ] && [ -n "$bc_hits" ]; } \
    && pass "…while a trailing backslash in a body line joins nothing" \
    || die "a body line was joined to its terminator ('$bc_hits')"

# …and the engine has to be the INVOKED command: `printf %s grep PATTERN` runs
# `printf`, and reading its operand as an engine reported the pattern beside it.
printf '#!/usr/bin/env bash\nprintf %%s grep %s\n' "'\\s'" > "$PTMP/engdata.sh"
ed3_hits="$(scan "$RULE_A" "$PTMP/engdata.sh")" || ed3_hits=SCANFAIL
{ [ "$ed3_hits" != SCANFAIL ] && [ -z "$ed3_hits" ]; } \
    && pass "an engine name as an operand is not an engine" \
    || die "printf with a grep operand was reported ('$ed3_hits')"

# ── THE ENGINE AND THE MODE COME FROM THE WORDS ────────────────────────────
# Quote removal happens before the command sees either. `gr"ep" -qE PATTERN f` IS
# `grep`, and a raw-text test never saw the name — so the escape check was skipped
# on a command that runs GNU grep.
printf '#!/usr/bin/env bash\ngr"ep" -qE %s "$f" || :\n' "'\\s'" > "$PTMP/asmengine.sh"
ae2_hits="$(scan "$RULE_A" "$PTMP/asmengine.sh")" || ae2_hits=SCANFAIL
{ [ "$ae2_hits" != SCANFAIL ] && [ -n "$ae2_hits" ]; } \
    && pass "an assembled engine name is still the engine" \
    || die "gr\"ep\" was not recognised as grep ('$ae2_hits')"
# …and a QUOTED `-F` is the ordinary fixed-string option, where a backslash is a
# literal and the pattern means the same thing on both platforms.
printf '#!/usr/bin/env bash\ngrep %s-F%s %s "$f"\n' "'" "'" "'\\s'" > "$PTMP/quotedF.sh"
qf_hits="$(scan "$RULE_A" "$PTMP/quotedF.sh")" || qf_hits=SCANFAIL
{ [ "$qf_hits" != SCANFAIL ] && [ -z "$qf_hits" ]; } \
    && pass "…and a quoted -F is still fixed-string mode" \
    || die "a quoted -F was not recognised ('$qf_hits')"

# ── A LOCALE PREFIX ONLY COUNTS WHERE THE QUOTING IS ACTIVE ────────────────
# Inside single quotes the two characters are literal text, so `<<'$"EOF"'` names
# `$"EOF"` — discarding the dollar there recorded a word no line will ever equal.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<%s$%sEOF%s%s\n' "$sq" "$dq" "$dq" "$sq"
  printf 'body text\n'
  printf '$%sEOF%s\n' "$dq" "$dq"
  printf 'grep -qE "%ss" "$f"\n' "$bs"; } > "$PTMP/quotedlocale.sh"
ql_hits="$(scan "$RULE_A" "$PTMP/quotedlocale.sh")" || ql_hits=SCANFAIL
{ [ "$ql_hits" != SCANFAIL ] && [ -n "$ql_hits" ]; } \
    && pass "a quoted locale prefix is part of the delimiter word" \
    || die "the dollar was discarded inside single quotes ('$ql_hits')"
# …and `\c[` names ESCAPE, which is where a table beats a letter list: every
# control escape decoded to the same character while only the letters were
# answerable, so a delimiter built from one matched nothing.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<$%s%sc[%s\n' "$sq" "$bs" "$sq"
  printf 'body text\n'
  printf '\033\n'
  printf 'grep -qE "%ss" "$f"\n' "$bs"; } > "$PTMP/ctrldelim.sh"
cd3_hits="$(scan "$RULE_A" "$PTMP/ctrldelim.sh")" || cd3_hits=SCANFAIL
{ [ "$cd3_hits" != SCANFAIL ] && [ -n "$cd3_hits" ]; } \
    && pass "…and a control escape names the character it stands for" \
    || die "a control-escape delimiter did not end at its character ('$cd3_hits')"

# …and the parentheses inside it are balanced with the QUOTING in mind: a quoted
# one closes nothing, and decrementing at every parenthesis recorded a prefix of the
# delimiter word — after which the real terminator never arrived.
#
# The terminator here is the QUOTE-REMOVED form, because that is what bash compares
# against: the delimiter word loses its quote characters like any other word, so a
# line carrying them would not be the terminator at all.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<x$(printf %s)%s EOF)\n' "$sq" "$sq"
  printf 'body text\n'
  printf 'x$(printf ) EOF)\n'

  printf 'grep -qE "%ss" "$f"\n' "$bs"; } > "$PTMP/substquote.sh"
sq2_hits="$(scan "$RULE_A" "$PTMP/substquote.sh")" || sq2_hits=SCANFAIL
{ [ "$sq2_hits" != SCANFAIL ] && [ -n "$sq2_hits" ]; } \
    && pass "a quoted parenthesis does not close a delimiter substitution" \
    || die "the delimiter stopped at a quoted parenthesis ('$sq2_hits')"

# …and the quote removal is FULL: a backslash that quotes something is gone from the
# delimiter too, so `x$(printf E\OF)` names `x$(printf EOF)`.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<x$(printf E%sOF)\n' "$bs"
  printf 'body text\n'
  printf 'x$(printf EOF)\n'
  printf 'grep -qE "%ss" "$f"\n' "$bs"; } > "$PTMP/substesc.sh"
se_hits="$(scan "$RULE_A" "$PTMP/substesc.sh")" || se_hits=SCANFAIL
{ [ "$se_hits" != SCANFAIL ] && [ -n "$se_hits" ]; } \
    && pass "a quoting backslash is removed from the delimiter too" \
    || die "the delimiter kept its backslash ('$se_hits')"

# ── A SUBSTITUTION-SHAPED DELIMITER IS TAKEN WHOLE ─────────────────────────
# Bash does not expand the delimiter word, so `<<$(printf EOF)` names that text —
# parentheses, space and all. Stopping at the `(` recorded a prefix of it, and the
# real terminator never drained the queue.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<x$(printf EOF)\n'
  printf 'body text\n'
  printf 'x$(printf EOF)\n'
  printf 'grep -qE "%ss" "$f"\n' "$bs"; } > "$PTMP/substdelim.sh"
sd3_hits="$(scan "$RULE_A" "$PTMP/substdelim.sh")" || sd3_hits=SCANFAIL
{ [ "$sd3_hits" != SCANFAIL ] && [ -n "$sd3_hits" ]; } \
    && pass "a substitution-shaped delimiter is taken whole" \
    || die "the delimiter stopped at its parenthesis ('$sd3_hits')"

# …and it QUOTES NOTHING: none of the delimiter word's characters are quoted, so a
# body under it still expands, and a substitution there really invokes its command.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<x$(printf EOF)\n'
  printf 'text $(grep -qE "%ss" f) more\n' "$bs"
  printf 'x$(printf EOF)\n'; } > "$PTMP/substdelimx.sh"
sx_hits="$(scan "$RULE_A" "$PTMP/substdelimx.sh")" || sx_hits=SCANFAIL
{ [ "$sx_hits" != SCANFAIL ] && [ -n "$sx_hits" ]; } \
    && pass "…and a body under it still expands" \
    || die "a substitution-shaped delimiter suppressed expansion ('$sx_hits')"

# ── A QUOTED BRACE DOES NOT CLOSE AN EXPANSION ─────────────────────────────
# `${unset:-"}"<<EOF}` closes at the LAST brace, and counting the quoted one closed
# it early — after which the `<<EOF` was outside the expansion and queued a
# document whose terminator never comes.
{ printf '#!/usr/bin/env bash\n'
  printf 'value=${unset:-%s}%s<<EOF}\n' "$dq" "$dq"
  printf 'grep -qE "%ss" "$f"\n' "$bs"; } > "$PTMP/pexbrace.sh"
pb_hits="$(scan "$RULE_A" "$PTMP/pexbrace.sh")" || pb_hits=SCANFAIL
{ [ "$pb_hits" != SCANFAIL ] && [ -n "$pb_hits" ]; } \
    && pass "a quoted brace does not close a parameter expansion" \
    || die "an expansion closed at a quoted brace ('$pb_hits')"

# ── THE TERMINATOR IS COMPARED, NOT EXPANDED ───────────────────────────────
# Bash performs quote removal on the delimiter word and compares the line
# literally, so a body line that IS the terminator is not a body line at all.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<${name^^} || :\n'
  printf 'body text\n'
  printf '${name^^}\n'; } > "$PTMP/hdterm.sh"
ht_hits="$(scan "$RULE_D" "$PTMP/hdterm.sh")" || ht_hits=SCANFAIL
# ONE hit, not two. The OPENING line carries the expansion text and is reported —
# that is a separate question, and not the one this fixture is about. What the fix
# changes is whether the TERMINATOR line is reported as well, so the count is what
# distinguishes them.
ht_n="$(printf '%s' "$ht_hits" | grep -c 'case modification' || true)"
{ [ "$ht_hits" != SCANFAIL ] && [ "$ht_n" = 1 ]; } \
    && pass "a terminator is compared rather than expanded" \
    || die "the terminator line was scanned as a body ($ht_n hits)"

# ── `${ … }` IS AN EXPANSION, NOT A REDIRECTION ────────────────────────────
# `trimmed=${value#<<EOF}` is a removal pattern, and the two characters in it were
# queueing a document whose terminator never comes.
{ printf '#!/usr/bin/env bash\n'
  printf 'trimmed=${value#<<EOF}\n'
  printf 'grep -qE "%ss" "$f"\n' "$bs"; } > "$PTMP/pexheredoc.sh"
px_hits="$(scan "$RULE_A" "$PTMP/pexheredoc.sh")" || px_hits=SCANFAIL
{ [ "$px_hits" != SCANFAIL ] && [ -n "$px_hits" ]; } \
    && pass "a << inside a parameter expansion opens no document" \
    || die "a removal pattern swallowed the rest of the file ('$px_hits')"

# ── AN ESCAPED DOLLAR IS NOT AN EXPANSION ──────────────────────────────────
# In an unquoted body `\${name^^}` is the literal text — bash quotes the dollar and
# performs nothing. The same parity that decides an escape decides this.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<EOF || :\n'
  printf 'value %s${name^^} more\n' "$bs"
  printf 'EOF\n'; } > "$PTMP/hdescaped.sh"
hx_hits="$(scan "$RULE_D" "$PTMP/hdescaped.sh")" || hx_hits=SCANFAIL
{ [ "$hx_hits" != SCANFAIL ] && [ -z "$hx_hits" ]; } \
    && pass "an escaped dollar in a body is not an expansion" \
    || die "an escaped expansion was reported ('$hx_hits')"

# ── `$"…"` IS A QUOTED DELIMITER, AND `$'…'` NAMES ITS DECODED WORD ────────
# `cat <<$"EOF"` is locale translation: the `$` is not part of the word, and
# appending it recorded a name no line will ever equal — so a later violation was
# skipped to end of file.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<$%sEOF%s\n' "$dq" "$dq"
  printf 'body text\n'
  printf 'EOF\n'
  printf 'grep -qE "%ss" "$f"\n' "$bs"; } > "$PTMP/localedelim.sh"
ld_hits="$(scan "$RULE_A" "$PTMP/localedelim.sh")" || ld_hits=SCANFAIL
{ [ "$ld_hits" != SCANFAIL ] && [ -n "$ld_hits" ]; } \
    && pass "a locale-quoted delimiter names the word inside it" \
    || die "cat <<\$\"EOF\" recorded the dollar ('$ld_hits')"
# …and `$'\t'` names a TAB, which is what ends the document. The decoder used a
# placeholder for the escapes it recognised, which named nothing.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<$%s%st%s\n' "$sq" "$bs" "$sq"
  printf 'body text\n'
  printf '\t\n'
  printf 'grep -qE "%ss" "$f"\n' "$bs"; } > "$PTMP/tabdelim.sh"
td2_hits="$(scan "$RULE_A" "$PTMP/tabdelim.sh")" || td2_hits=SCANFAIL
{ [ "$td2_hits" != SCANFAIL ] && [ -n "$td2_hits" ]; } \
    && pass "…and an ANSI-C delimiter decodes to the character it names" \
    || die "cat <<\$'\\t' did not end at a tab ('$td2_hits')"

# ── EVERY QUOTING FORM ON THE DELIMITER SUPPRESSES EXPANSION ───────────────
# `cat <<\EOF` and `cat <<$'EOF'` are quoted delimiters as much as `<<'EOF'` is.
# The branches that consumed those spellings were not saying so, and their bodies
# were treated as expanding — portable source rejected.
for spec in 'bsdelim' 'ansicdelim'; do
    { printf '#!/usr/bin/env bash\n'
      case "$spec" in
          bsdelim)   printf 'cat <<%sEOF\n' "$bs" ;;
          ansicdelim) printf 'cat <<$%sEOF%s\n' "$sq" "$sq" ;;
      esac
      printf 'text $(grep -qE "%ss" f) more\n' "$bs"
      printf 'EOF\n'; } > "$PTMP/$spec-quoted.sh"
    dq2_hits="$(scan "$RULE_A" "$PTMP/$spec-quoted.sh")" || dq2_hits=SCANFAIL
    { [ "$dq2_hits" != SCANFAIL ] && [ -z "$dq2_hits" ]; } \
        && pass "a $spec delimiter suppresses expansion in its body" \
        || die "a $spec delimiter was read as expanding ('$dq2_hits')"
done

# ── AN EXPANSION IN AN UNQUOTED BODY IS PERFORMED ──────────────────────────
# The TEXT of a here-document body is data, which is why the rules do not see it —
# but bash performs the expansions in an unquoted one, so a case-modifying
# parameter expansion there is a Bash 4 construct that really runs.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<EOF || :\n'
  printf 'value ${name^^} more\n'
  printf 'EOF\n'; } > "$PTMP/hdparam.sh"
hp2_hits="$(scan "$RULE_D" "$PTMP/hdparam.sh")" || hp2_hits=SCANFAIL
{ [ "$hp2_hits" != SCANFAIL ] && [ -n "$hp2_hits" ]; } \
    && pass "a case-modifying expansion in an expanded body is reported" \
    || die "an active expansion in a here-document body was missed ('$hp2_hits')"
# …and a QUOTED delimiter suppresses it, so the same text is data again.
{ printf '#!/usr/bin/env bash\n'
  printf "cat <<'EOF' || :\n"
  printf 'value ${name^^} more\n'
  printf 'EOF\n'; } > "$PTMP/hdparamq.sh"
hpq_hits="$(scan "$RULE_D" "$PTMP/hdparamq.sh")" || hpq_hits=SCANFAIL
{ [ "$hpq_hits" != SCANFAIL ] && [ -z "$hpq_hits" ]; } \
    && pass "…while a quoted delimiter keeps that expansion data" \
    || die "an expansion in a quoted body was reported ('$hpq_hits')"

# ── AN UNQUOTED DELIMITER MEANS THE BODY EXPANDS ───────────────────────────
# The body is data for the rules, but bash still performs substitution in it, so a
# `$( … )` there really invokes its command. A quoted delimiter suppresses that, and
# the two must not be treated alike.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<EOF\n'
  printf 'text $(grep -qE "%ss" f) more\n' "$bs"
  printf 'EOF\n'; } > "$PTMP/hdexpand.sh"
he_hits="$(scan "$RULE_A" "$PTMP/hdexpand.sh")" || he_hits=SCANFAIL
{ [ "$he_hits" != SCANFAIL ] && [ -n "$he_hits" ]; } \
    && pass "a substitution in an expanded here-document body is scanned" \
    || die "an unquoted delimiter hid a command in its body ('$he_hits')"
# …while a QUOTED delimiter suppresses expansion, so the same text is data.
{ printf '#!/usr/bin/env bash\n'
  printf "cat <<'EOF'\n"
  printf 'text $(grep -qE "%ss" f) more\n' "$bs"
  printf 'EOF\n'; } > "$PTMP/hdquoted.sh"
hq_hits="$(scan "$RULE_A" "$PTMP/hdquoted.sh")" || hq_hits=SCANFAIL
{ [ "$hq_hits" != SCANFAIL ] && [ -z "$hq_hits" ]; } \
    && pass "…while a quoted delimiter keeps it data" \
    || die "a quoted here-document body was scanned ('$hq_hits')"

# ── A SUBSTITUTION INSIDE A SHELL BODY IS STILL ONE ────────────────────────
# The guard that stops a shell body from spawning another shell was stopping the
# substitution extraction there too, so `bash -c 'out=$(… | grep …)'` had the engine
# one level further in than anything looked.
#
# NO PIPE IN THE BODY, deliberately: the segment split would surface the engine on
# its own, and the fixture would pass with the substitution machinery removed
# entirely — which is what the first version of it did.
{ printf '#!/usr/bin/env bash\n'
  printf 'bash -c %sout=$(grep -qE "%ss" f) || :%s\n' "$sq" "$bs" "$sq"; } > "$PTMP/bodysubst.sh"
bs2_hits="$(scan "$RULE_A" "$PTMP/bodysubst.sh")" || bs2_hits=SCANFAIL
{ [ "$bs2_hits" != SCANFAIL ] && [ -n "$bs2_hits" ]; } \
    && pass "a substitution inside a shell body is scanned too" \
    || die "the shell-body guard suppressed the substitution ('$bs2_hits')"

# ── A QUOTED SUBSTITUTION IS STILL A COMMAND ───────────────────────────────
# `out="$(grep PATTERN f)"` is the ordinary spelling. The quoted branch appended the
# words to the assignment instead of flushing it, so the command word was `out=grep`
# and no engine was recognised.
printf '#!/usr/bin/env bash\nout="$(grep %s "$f")" || :\n' "'\\s'" > "$PTMP/qsubcmd.sh"
qs_hits="$(scan "$RULE_A" "$PTMP/qsubcmd.sh")" || qs_hits=SCANFAIL
{ [ "$qs_hits" != SCANFAIL ] && [ -n "$qs_hits" ]; } \
    && pass "a substitution inside double quotes is still a command" \
    || die "out=\"\$(grep …)\" hid the engine ('$qs_hits')"
# …while `$((` is ARITHMETIC and shares the first two characters. Reading it as a
# substitution made the operands of an ordinary sum look like an invoked command.
refute arithword 'value=$((shopt + globstar))'                D "arithmetic whose operands share builtin names"

# ── ONLY THE OPERANDS THAT CARRY A PATTERN ─────────────────────────────────
# `grep x 'file\s'` searches for `x` in a file whose NAME contains a backslash —
# the same search on both platforms. Concatenating every argument reported the
# filename as a GNU escape.
printf '#!/usr/bin/env bash\ngrep x %sfile%ss%s\n' "'" "$one_bs" "'" > "$PTMP/patfile.sh"
pt_hits="$(scan "$RULE_A" "$PTMP/patfile.sh")" || pt_hits=SCANFAIL
{ [ "$pt_hits" != SCANFAIL ] && [ -z "$pt_hits" ]; } \
    && pass "an escape in a FILENAME is not an escape in the pattern" \
    || die "a filename operand was read as a pattern ('$pt_hits')"
# …and `-Fq` has both options active, so the fixed-string exemption applies.
printf '#!/usr/bin/env bash\ngrep -Fq %s "$f"\n' "'\\s'" > "$PTMP/fcluster.sh"
fc_hits="$(scan "$RULE_A" "$PTMP/fcluster.sh")" || fc_hits=SCANFAIL
{ [ "$fc_hits" != SCANFAIL ] && [ -z "$fc_hits" ]; } \
    && pass "…and -F anywhere in a cluster is still fixed-string mode" \
    || die "a clustered -F was not recognised ('$fc_hits')"
# …while a PATH-QUALIFIED engine is the same engine: `/usr/bin/grep` is GNU on one
# platform and BSD on the other, which is the difference this rule exists for.
printf '#!/usr/bin/env bash\n/usr/bin/grep -E %s "$f" || :\n' "'\\s'" > "$PTMP/pathengine.sh"
pe_hits="$(scan "$RULE_A" "$PTMP/pathengine.sh")" || pe_hits=SCANFAIL
{ [ "$pe_hits" != SCANFAIL ] && [ -n "$pe_hits" ]; } \
    && pass "…and a path-qualified engine is still the engine" \
    || die "/usr/bin/grep was not recognised ('$pe_hits')"

# ── AN ARITHMETIC SPAN ENDS WHERE ITS QUOTING SAYS ─────────────────────────
# Quoted parentheses are data. Counting them never reached depth zero, and the span
# swallowed the rest of the logical line — taking a real command with it.
{ printf '#!/usr/bin/env bash\n'
  printf 'value=$(( ${x:-%s(%s} + 1 )); shopt -s globstar || :\n' "'" "'"; } > "$PTMP/arithquote.sh"
# …and an ESCAPED quote inside the span does not close the string it is in: taking
# it as the closer counted the `)` after it as nesting and read the real closer as
# an opener, after which the span ran to the end of the line.
#
# The command shares the SEGMENT with the expansion deliberately. With an operator
# between them the splitter would find the command whatever the span did, and the
# fixture would pass for a reason that is not the one it names.
{ printf '#!/usr/bin/env bash\n'
  printf 'value=$(( ${x:-%s%s%s)%s} + 1 )) shopt -s globstar\n' \
      "$dq" "$bs" "$dq" "$dq"; } > "$PTMP/aritharith.sh"
ae3_hits="$(scan "$RULE_D" "$PTMP/aritharith.sh")" || ae3_hits=SCANFAIL
{ [ "$ae3_hits" != SCANFAIL ] && [ -n "$ae3_hits" ]; } \
    && pass "…and an escaped quote inside a span does not end its string" \
    || die "an escaped quote ended the arithmetic span early ('$ae3_hits')"
aq2_hits="$(scan "$RULE_D" "$PTMP/arithquote.sh")" || aq2_hits=SCANFAIL
{ [ "$aq2_hits" != SCANFAIL ] && [ -n "$aq2_hits" ]; } \
    && pass "a command after an arithmetic span is still visible" \
    || die "the arithmetic span swallowed the command after it ('$aq2_hits')"

# ── `--` ENDS THE OPTIONS ──────────────────────────────────────────────────
# After it a word beginning with a dash is a filename: `grep -e PATTERN -- -F`
# searches a file called `-F` with the pattern still active. Reading that operand as
# fixed-string mode exempted a command whose pattern is not.
printf '#!/usr/bin/env bash\ngrep -e %s -- -F || :\n' "'\\s'" > "$PTMP/optterm.sh"
ot_hits="$(scan "$RULE_A" "$PTMP/optterm.sh")" || ot_hits=SCANFAIL
{ [ "$ot_hits" != SCANFAIL ] && [ -n "$ot_hits" ]; } \
    && pass "a -F after -- is a filename, not fixed-string mode" \
    || die "an operand after -- was read as an option ('$ot_hits')"

# ── AN ARITHMETIC SPAN IS DATA THROUGHOUT ──────────────────────────────────
# Consuming only the opener left the expression to the ordinary word rules, so the
# whitespace inside `$(( a + b ))` flushed the assignment and the operands became
# words of their own — an invoked command again.
refute arithspace 'value=$(( shopt + globstar ))'             D "arithmetic with spaces around its operands"

# ── FIXED-STRING MODE BELONGS TO ITS OWN COMMAND ───────────────────────────
# A segment can hold more than one engine. `grep -F x $(grep PATTERN f)` has a
# fixed-string outer command and an inner one that is not, and a mode accumulated
# across both let the outer exempt the inner.
printf '#!/usr/bin/env bash\ngrep -F x $(grep %s "$f")\n' "'\\s'" > "$PTMP/nestedF.sh"
nf_hits="$(scan "$RULE_A" "$PTMP/nestedF.sh")" || nf_hits=SCANFAIL
{ [ "$nf_hits" != SCANFAIL ] && [ -n "$nf_hits" ]; } \
    && pass "an outer -F does not exempt an inner grep" \
    || die "fixed-string mode leaked across commands ('$nf_hits')"

# ── A SUBSTITUTION RUNS A COMMAND OF ITS OWN ───────────────────────────────
# `out=$(grep PATTERN f)` invokes `grep`. Appending the text to the assignment word
# left a word called `out=$(grep` and no command at all, so the engine was never
# recognised and the escape went unreported.
printf '#!/usr/bin/env bash\nout=$(grep %s "$f") || :\n' "'\\s'" > "$PTMP/subcmd.sh"
sc_hits="$(scan "$RULE_A" "$PTMP/subcmd.sh")" || sc_hits=SCANFAIL
{ [ "$sc_hits" != SCANFAIL ] && [ -n "$sc_hits" ]; } \
    && pass "a command inside a substitution is a command" \
    || die "out=\$(grep …) hid the engine ('$sc_hits')"
# …and a `(` inside a substitution is a SUBSHELL, whose `)` does not end it.
# Closing at the first one restored the outer quoting early, and every quote after
# that read inverted — which exposed the text of a later string as a redirection.
{ printf '#!/usr/bin/env bash\n'
  printf 'x="$( (:) ; printf "%%s" "<<MISSING" )"\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/subshell.sh"
ss_hits="$(scan "$RULE_A" "$PTMP/subshell.sh")" || ss_hits=SCANFAIL
{ [ "$ss_hits" != SCANFAIL ] && [ -n "$ss_hits" ]; } \
    && pass "…and a subshell inside one does not close it early" \
    || die "an inner ) ended the substitution and swallowed the file ('$ss_hits')"

# ── A PENDING LOGICAL LINE SURVIVES THE FILE BOUNDARY ──────────────────────
# A target whose last line ends in a continuation leaves its text unscanned unless
# the boundary flushes it: the END hook only ever sees the last file, and
# production hands many targets to one awk.
{ printf '#!/usr/bin/env bash\n'
  printf 'grep -qE "\\s" "$f" %s\n' "$one_bs"; } > "$PTMP/pending.sh"
printf '#!/usr/bin/env bash\n:\n' > "$PTMP/after.sh"
pf_hits="$(scan "$RULE_A" "$PTMP/pending.sh" "$PTMP/after.sh")" || pf_hits=SCANFAIL
{ [ "$pf_hits" != SCANFAIL ] && [ -n "$pf_hits" ]; } \
    && pass "a continued last line is scanned before the next file starts" \
    || die "a pending logical line went out with the buffer ('$pf_hits')"
# …and it is reported against the file it came FROM. The flush happens at the next
# boundary, by which point awk has moved on, so the hit named the wrong target and
# sent the contributor to a line number in a file that does not have it.
case "$pf_hits" in
    *pending.sh*) pass "…and is attributed to the file it came from" ;;
    *)            die "the flushed line was blamed on the next file ('$pf_hits')" ;;
esac

# ── NOTHING CARRIES ACROSS A FILE BOUNDARY ─────────────────────────────────
# A target that ends while a document is still open must not consume the next one
# as its body: a real violation there would be skipped, and the multi-file scan
# would report clean because one file was truncated.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<UNTERMINATED\n'
  printf 'body text with no terminator\n'; } > "$PTMP/openfile.sh"
printf '#!/usr/bin/env bash\ngrep -qE "\\s" "$f"\n' > "$PTMP/nextfile.sh"
fb_hits="$(scan "$RULE_A" "$PTMP/openfile.sh" "$PTMP/nextfile.sh")" || fb_hits=SCANFAIL
{ [ "$fb_hits" != SCANFAIL ] && [ -n "$fb_hits" ]; } \
    && pass "an unterminated document does not consume the next target" \
    || die "a truncated file hid the one after it ('$fb_hits')"

# ── AN ANSI-C DELIMITER NAMES ITS DECODED WORD ─────────────────────────────
# `cat <<$'EOF'` names `EOF`. Appending the characters as written recorded the
# dollar and the quotes with them, and no line ever equals that — so a violation
# after the document was skipped to end of file.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<$%sEOF%s\n' "'" "'"
  printf 'body text\n'
  printf 'EOF\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/ansicdelim.sh"
an_hits="$(scan "$RULE_A" "$PTMP/ansicdelim.sh")" || an_hits=SCANFAIL
{ [ "$an_hits" != SCANFAIL ] && [ -n "$an_hits" ]; } \
    && pass "an ANSI-C delimiter names its decoded word" \
    || die "cat <<\$'EOF' recorded the undecoded word ('$an_hits')"

# ── A BACKSLASH-NEWLINE INSIDE SINGLE QUOTES IS DATA ───────────────────────
# Bash keeps both characters, so a single-quoted value split across two lines is
# not a continuation. Joining them ran the halves together into a GNU-only name
# that the source never contained.
{ printf '#!/usr/bin/env bash\n'
  printf "value='gaw%s\n" "$one_bs"
  printf "k'\n"; } > "$PTMP/quotedcont.sh"
qc_hits="$(scan '
    if (line ~ /(^|[^A-Za-z0-9_.-])gawk([^A-Za-z0-9_-]|$)/) { report("hit"); return }' "$PTMP/quotedcont.sh")" || qc_hits=SCANFAIL
{ [ "$qc_hits" != SCANFAIL ] && [ -z "$qc_hits" ]; } \
    && pass "a quoted trailing backslash joins nothing" \
    || die "a single-quoted split invented a GNU-only name ('$qc_hits')"

# ── A QUOTED # IS NOT A COMMENT, EVEN AT THE START OF A LINE ───────────────
# A word opened on an earlier line can carry a `#` as data; the quote then closes
# and a command follows on the same line. Deleting from that `#` deleted the closer
# and the command with it.
{ printf '#!/usr/bin/env bash\n'
  printf "x='data\n"
  printf "#'; shopt -s globstar || :\n"; } > "$PTMP/quotedhash.sh"
qh2_hits="$(scan "$RULE_D" "$PTMP/quotedhash.sh")" || qh2_hits=SCANFAIL
{ [ "$qh2_hits" != SCANFAIL ] && [ -n "$qh2_hits" ]; } \
    && pass "a # carried as data does not comment out the command after it" \
    || die "a quoted # deleted a real command ('$qh2_hits')"

# ── A PRESENT BUT EMPTY DELIMITER IS A DELIMITER ───────────────────────────
# `cat <<''` reads to a blank terminator line. Treating the empty value as though
# no word had been written queued nothing and the body was read as shell.
{ printf '#!/usr/bin/env bash\n'
  printf "cat <<''\n"
  printf 'grep -qE "\\s" is example text\n'
  printf '\n'; } > "$PTMP/emptydelim.sh"
ed2_hits="$(scan "$RULE_A" "$PTMP/emptydelim.sh")" || ed2_hits=SCANFAIL
{ [ "$ed2_hits" != SCANFAIL ] && [ -z "$ed2_hits" ]; } \
    && pass "a present but empty delimiter opens a document" \
    || die "cat <<'' queued nothing ('$ed2_hits')"

# ── QUOTE STATE CARRIES ACROSS PHYSICAL LINES ──────────────────────────────
# A word opened on one line and closed on the next is one word. A scan that
# restarted at every line read that closing quote as an OPENER, so the rest of the
# line became data and the rule saw nothing in it.
{ printf '#!/usr/bin/env bash\n'
  printf "x='data\n"
  printf "'; shopt -s globstar || :\n"; } > "$PTMP/multiline.sh"
ml_hits="$(scan "$RULE_D" "$PTMP/multiline.sh")" || ml_hits=SCANFAIL
{ [ "$ml_hits" != SCANFAIL ] && [ -n "$ml_hits" ]; } \
    && pass "a word closed on the next physical line does not quote the rest" \
    || die "a multiline word hid a Bash 4 option ('$ml_hits')"

# ── A CONTINUATION NEEDS AN ODD TRAILING RUN ───────────────────────────────
# Two backslashes at the end of a line are a literal backslash and the command ENDS
# there. Joining anyway glued the next line on, and the fixed-string exemption
# taken by the first half then covered a real GNU escape in the second.
{ printf '#!/usr/bin/env bash\n'
  printf 'grep -F x "$f" %s\n' "$two_bs"
  printf 'if grep %s /dev/null; then :; fi\n' "'\\s'"; } > "$PTMP/doublecont.sh"
dc_hits="$(scan "$RULE_A" "$PTMP/doublecont.sh")" || dc_hits=SCANFAIL
{ [ "$dc_hits" != SCANFAIL ] && [ -n "$dc_hits" ]; } \
    && pass "two trailing backslashes end the command rather than continue it" \
    || die "a doubled trailing backslash joined the next line ('$dc_hits')"

# ── THE DELIMITER IS A WHOLE WORD ──────────────────────────────────────────
# `cat <<E"OF"` is a document ending at `EOF`. Consuming only `<<E"` recorded `E`,
# and the terminator never came — so a real violation after the document was
# skipped to end of file.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<E"OF"\n'
  printf 'body text\n'
  printf 'EOF\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/splitdelim.sh"
sd2_hits="$(scan "$RULE_A" "$PTMP/splitdelim.sh")" || sd2_hits=SCANFAIL
{ [ "$sd2_hits" != SCANFAIL ] && [ -n "$sd2_hits" ]; } \
    && pass "a concatenated delimiter word is quote-removed whole" \
    || die "cat <<E\"OF\" swallowed the rest of the file ('$sd2_hits')"

# …and an ESCAPED quote inside a quoted delimiter is part of the word: `<<"E\"OF"`
# names `E"OF`. Dropping it because it matches its own context recorded `EOF`, and
# the real terminator never arrived.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<"E\\"OF"\n'
  printf 'body text\n'
  printf 'E"OF\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/escqdelim.sh"
eq_hits="$(scan "$RULE_A" "$PTMP/escqdelim.sh")" || eq_hits=SCANFAIL
{ [ "$eq_hits" != SCANFAIL ] && [ -n "$eq_hits" ]; } \
    && pass "…and an escaped quote inside a delimiter stays in the word" \
    || die "an escaped quote was dropped from the delimiter ('$eq_hits')"
# …and any quoted word is a delimiter, space included. An identifier-shaped
# whitelist refused `END MARK` and the body was read as shell.
{ printf '#!/usr/bin/env bash\n'
  printf "cat <<'END MARK'\n"
  printf 'grep -qE "\\s" is example text\n'
  printf 'END MARK\n'; } > "$PTMP/spacedelim.sh"
sp_hits="$(scan "$RULE_A" "$PTMP/spacedelim.sh")" || sp_hits=SCANFAIL
{ [ "$sp_hits" != SCANFAIL ] && [ -z "$sp_hits" ]; } \
    && pass "…and a delimiter containing a space is still a delimiter" \
    || die "a quoted delimiter with a space was refused ('$sp_hits')"

# ── A LONE & ENDS A COMMAND ────────────────────────────────────────────────
# `grep -F x f & grep '\s' f` is two commands: the first is backgrounded, and its
# fixed-string exemption was covering the second.
printf '#!/usr/bin/env bash\ngrep -F x "$f" & grep %s "$f"\n' "'\\s'" > "$PTMP/ampsplit.sh"
as_hits="$(scan "$RULE_A" "$PTMP/ampsplit.sh")" || as_hits=SCANFAIL
{ [ "$as_hits" != SCANFAIL ] && [ -n "$as_hits" ]; } \
    && pass "a backgrounded command does not exempt the next one" \
    || die "grep -F excused a later grep across an & ('$as_hits')"
# The `&` of a REDIRECTION splits too, deliberately: a redirection carries no
# pattern of its own, so the extra segment is `1` or `>f` and no rule has anything
# to say about it. There is no fixture for that, because there is nothing an
# implementation could do differently that any assertion would see — the fixture
# that used to sit here asserted the opposite of the production behaviour and
# passed anyway, on a `|` that separated the commands regardless.

# ── A WORD CAN BE ASSEMBLED FROM SEVERAL QUOTINGS ──────────────────────────
# `grep \\$'\s' f` is an unquoted escape and an ANSI-C span written next to each
# other: one backslash each, two in total, which is a literal backslash and an
# ordinary letter. Judging the span alone saw its single backslash and rejected a
# portable command — the parity question is about the assembled word.
printf '#!/usr/bin/env bash\ngrep %s$%s\\134s%s "$f"\n' "$two_bs" "'" "'" > "$PTMP/mixedword.sh"
mw_hits="$(scan "$RULE_A" "$PTMP/mixedword.sh")" || mw_hits=SCANFAIL
{ [ "$mw_hits" != SCANFAIL ] && [ -z "$mw_hits" ]; } \
    && pass "parity is judged across the whole assembled word" \
    || die "an adjacent unquoted escape was ignored ('$mw_hits')"
# …and the same escape beside a span carrying TWO leaves three, which is odd, so
# it still reports. One unquoted backslash instead would escape the dollar and
# leave no ANSI-C span at all, which is a different case and already covered.
printf '#!/usr/bin/env bash\ngrep %s$%s\\134\\134s%s "$f"\n' "$two_bs" "'" "'" > "$PTMP/mixedodd.sh"
mo_hits="$(scan "$RULE_A" "$PTMP/mixedodd.sh")" || mo_hits=SCANFAIL
{ [ "$mo_hits" != SCANFAIL ] && [ -n "$mo_hits" ]; } \
    && pass "…and an odd assembled count still escapes the letter" \
    || die "an odd assembled count was read as portable ('$mo_hits')"

# …and a run does not join across two ARGUMENTS. `grep -e '\' 'sub' f` searches for
# a lone backslash and then for `sub`; run them together and the text reads as the
# GNU `\s`, a rejection of portable code invented by the concatenation. The space
# between them is what prevents it, and it prevents it by being a character that
# is not a backslash.
printf '#!/usr/bin/env bash\ngrep -e %s%s%s %ssub%s "$f"\n' "'" "$one_bs" "'" "'" "'" > "$PTMP/wordsplit.sh"
ws_hits="$(scan "$RULE_A" "$PTMP/wordsplit.sh")" || ws_hits=SCANFAIL
{ [ "$ws_hits" != SCANFAIL ] && [ -z "$ws_hits" ]; } \
    && pass "…and a backslash run does not join across two arguments" \
    || die "two arguments were read as one word ('$ws_hits')"

# ── A QUOTED ARITHMETIC OPENER IS DATA ─────────────────────────────────────
# `printf '%s' "(("` has no arithmetic in it. Taking the quoted characters as an
# opener consumed the rest of the logical line looking for a `))` that never came,
# and a real here-document redirection after it went with it.
{ printf '#!/usr/bin/env bash\n'
  printf 'printf %s "(("; cat <<EOF\n' "'%s\\n'"
  printf 'grep -qE "\\s" is example text\n'
  printf 'EOF\n'; } > "$PTMP/quotedarith.sh"
qa_hits="$(scan "$RULE_A" "$PTMP/quotedarith.sh")" || qa_hits=SCANFAIL
{ [ "$qa_hits" != SCANFAIL ] && [ -z "$qa_hits" ]; } \
    && pass "a quoted arithmetic opener does not consume the line" \
    || die "a quoted (( ate a real redirection ('$qa_hits')"

# ── THE DELIMITER WORD IS QUOTE-REMOVED, BACKSLASH INCLUDED ────────────────
# `cat <<\EOF` is a document ending at `EOF`. A pattern taking only a single or
# double quote recorded no document at all, so the body was read as shell.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<\\EOF\n'
  printf 'grep -qE "\\s" is example text\n'
  printf 'EOF\n'; } > "$PTMP/bsdelim.sh"
bd_hits="$(scan "$RULE_A" "$PTMP/bsdelim.sh")" || bd_hits=SCANFAIL
{ [ "$bd_hits" != SCANFAIL ] && [ -z "$bd_hits" ]; } \
    && pass "a backslash-quoted here-document delimiter is recognised" \
    || die "cat <<\\EOF recorded no document ('$bd_hits')"

# ── AN ESCAPED QUOTE INSIDE AN ANSI-C WORD IS DATA ─────────────────────────
# The apostrophe escaped inside the word does not close it; the one after it does,
# so the redirection that follows is real. Modelling the span as ordinary single
# quoting closed it early, reopened it at the real closer, and read the redirection
# as quoted — the body then went through the rules as shell.
{ printf '#!/usr/bin/env bash\n'
  printf 'printf %s $%sx\\%s%s; cat <<EOF\n' "'%s\\n'" "'" "'" "'"
  printf 'grep -qE "\\s" is example text\n'
  printf 'EOF\n'; } > "$PTMP/ansicheredoc.sh"
ah2_hits="$(scan "$RULE_A" "$PTMP/ansicheredoc.sh")" || ah2_hits=SCANFAIL
{ [ "$ah2_hits" != SCANFAIL ] && [ -z "$ah2_hits" ]; } \
    && pass "an escaped quote in an ANSI-C word does not hide the redirection" \
    || die "an ANSI-C word swallowed a real here-document ('$ah2_hits')"

# ── AN ESCAPED DOLLAR IS NOT AN OPENER ─────────────────────────────────────
# In `grep \$'\\s' f` the dollar is an escaped literal, so the quote after it opens
# an ORDINARY single-quoted span: grep receives two backslashes, which is portable.
# Reading the pair as an ANSI-C opener decoded them to one and rejected it.
printf '#!/usr/bin/env bash\ngrep \\$%s%ss%s "$f"\n' "'" "$two_bs" "'" > "$PTMP/escdollar.sh"
ed_hits="$(scan "$RULE_A" "$PTMP/escdollar.sh")" || ed_hits=SCANFAIL
{ [ "$ed_hits" != SCANFAIL ] && [ -z "$ed_hits" ]; } \
    && pass "an escaped dollar opens no ANSI-C span" \
    || die "an escaped dollar was read as an opener ('$ed_hits')"

# ── AN INLINE COMMENT OPENS NOTHING ────────────────────────────────────────
# `: # <<EOF` is a comment to bash. Removing only FULL-LINE comments queued `EOF`,
# no terminator ever came, and every following line was skipped.
{ printf '#!/usr/bin/env bash\n'
  printf ': # <<EOF\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/inlinehd.sh"
ih_hits="$(scan "$RULE_A" "$PTMP/inlinehd.sh")" || ih_hits=SCANFAIL
{ [ "$ih_hits" != SCANFAIL ] && [ -n "$ih_hits" ]; } \
    && pass "a here-document marker in an inline comment opens nothing" \
    || die "an inline comment swallowed the rest of the file ('$ih_hits')"
# …and `)` is a control operator, so `(:)# <<EOF` is a comment with no space in
# front of it — the boundary class is the operators that END a word as well as the
# ones that begin one.
{ printf '#!/usr/bin/env bash\n'
  printf '(:)# <<EOF\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/parencomment.sh"
pc_hits="$(scan "$RULE_A" "$PTMP/parencomment.sh")" || pc_hits=SCANFAIL
{ [ "$pc_hits" != SCANFAIL ] && [ -n "$pc_hits" ]; } \
    && pass "…and a comment right after a closing parenthesis opens nothing" \
    || die "(:)# <<EOF swallowed the rest of the file ('$pc_hits')"
# …and a `#` that is NOT starting a word is data: `${v#pat}` and `a#b` keep theirs,
# so a real redirection after one is still tracked.
{ printf '#!/usr/bin/env bash\n'
  printf 'x=${v#pat}; cat <<EOF\n'
  printf 'grep -qE "\\s" is example text\n'
  printf 'EOF\n'; } > "$PTMP/hashword.sh"
hw_hits="$(scan "$RULE_A" "$PTMP/hashword.sh")" || hw_hits=SCANFAIL
{ [ "$hw_hits" != SCANFAIL ] && [ -z "$hw_hits" ]; } \
    && pass "…while a # inside a word is data, not a comment" \
    || die "a # inside a word ended the line early ('$hw_hits')"

# ── THE ARITHMETIC COMMAND IS ARITHMETIC TOO ───────────────────────────────
# `(( mask = value << shift ))` is the command form of the same expression, and
# stripping only `$(( … ))` left it queueing `shift` as a delimiter — the same
# swallow-the-file failure with two fewer characters in front of it.
{ printf '#!/usr/bin/env bash\n'
  printf '(( mask = value << shift )) || :\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/arithcmd.sh"
ax_hits="$(scan "$RULE_A" "$PTMP/arithcmd.sh")" || ax_hits=SCANFAIL
{ [ "$ax_hits" != SCANFAIL ] && [ -n "$ax_hits" ]; } \
    && pass "the arithmetic COMMAND form does not open a here-document either" \
    || die "(( … << … )) swallowed the rest of the file ('$ax_hits')"

# ── A SYMBOLIC SHIFT IS NOT A HERE-DOCUMENT ────────────────────────────────
# `mask=$((value << shift))` queued `shift` as a delimiter, and unless some later
# line was exactly `shift`, every line to EOF was skipped — one arithmetic
# expression excusing the rest of the file. Excluding only a digit operand covered
# `1 << 2` and nothing symbolic.
{ printf '#!/usr/bin/env bash\n'
  printf 'mask=$((value << shift))\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/symshift.sh"
ss_hits="$(scan "$RULE_A" "$PTMP/symshift.sh")" || ss_hits=SCANFAIL
{ [ "$ss_hits" != SCANFAIL ] && [ -n "$ss_hits" ]; } \
    && pass "a symbolic arithmetic shift does not open a here-document" \
    || die "a symbolic shift swallowed the rest of the file ('$ss_hits')"
# …and a real here-document on the SAME line as one still works, so the removal
# takes out the expansion rather than the line.
{ printf '#!/usr/bin/env bash\n'
  printf 'mask=$((value << shift)); cat <<EOF\n'
  printf 'grep -P is example text\n'
  printf 'EOF\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/shiftdoc.sh"
sd_hits="$(scan "$RULE_A" "$PTMP/shiftdoc.sh")" || sd_hits=SCANFAIL
{ [ "$sd_hits" != SCANFAIL ] && [ -n "$sd_hits" ]; } \
    && pass "…while a real document beside one is still tracked" \
    || die "a here-document beside a shift was lost ('$sd_hits')"

# …and what precedes the expansion survives it. Replacing the whole line rather
# than the span dropped a here-document opened BEFORE the shift, and its body was
# then read as shell — a fixture with the two in the other order is what tells the
# two spellings apart.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<EOF; mask=$((value << shift))\n'
  printf 'grep -qE "\\s" is example text\n'
  printf 'EOF\n'; } > "$PTMP/docthenshift.sh"
ds_hits="$(scan "$RULE_A" "$PTMP/docthenshift.sh")" || ds_hits=SCANFAIL
{ [ "$ds_hits" != SCANFAIL ] && [ -z "$ds_hits" ]; } \
    && pass "…and a document opened before the expansion is not lost with it" \
    || die "removing the expansion took the earlier redirection too ('$ds_hits')"

# ── ONE COMMAND, TWO DOCUMENTS ─────────────────────────────────────────────
# `cat <<ONE <<TWO` opens both, in the order written. Recording only the first
# meant the SECOND body was read as shell as soon as the first terminator arrived,
# so example text in it failed the gate — and the file resumed one document early,
# which is the mirror of the skip that never ends.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<ONE <<TWO\n'
  printf 'first body\n'
  printf 'ONE\n'
  printf 'grep -qE "\\s" is example text in the second body\n'
  printf 'TWO\n'; } > "$PTMP/twodocs.sh"
td_hits="$(scan "$RULE_A" "$PTMP/twodocs.sh")" || td_hits=SCANFAIL
{ [ "$td_hits" != SCANFAIL ] && [ -z "$td_hits" ]; } \
    && pass "a second here-document body on one command is data too" \
    || die "the body of the second document was scanned as shell ('$td_hits')"
# …and the queue drains: after BOTH terminators the file is code again, or a
# two-document command would excuse everything after it.
{ printf '#!/usr/bin/env bash\n'
  printf 'cat <<ONE <<TWO\n'
  printf 'first\n'
  printf 'ONE\n'
  printf 'second\n'
  printf 'TWO\n'
  printf 'grep -qE "\\s" "$f"\n'; } > "$PTMP/twodocsend.sh"
te2_hits="$(scan "$RULE_A" "$PTMP/twodocsend.sh")" || te2_hits=SCANFAIL
{ [ "$te2_hits" != SCANFAIL ] && [ -n "$te2_hits" ]; } \
    && pass "…and code after the second terminator is scanned again" \
    || die "a two-document command swallowed the rest of the file ('$te2_hits')"

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
