# lib-bare-return-scan.awk — find `return` statements that carry no argument.
#
# Input is the output of `declare -f`, i.e. Bash's own re-rendering of a parsed
# function: comments are already gone and quoting is normalised. What remains
# that a plain regex still cannot handle is (a) `return` appearing inside a
# quoted string, and (b) an IO-number redirection such as `return 2> /dev/null`,
# where the `2` belongs to the redirection and NOT to return — the statement is
# bare and inherits the previous command's status.
#
# So this is a small tokenizer rather than a pattern: quoted spans are blanked
# out first, then `return` is located as a word, then the following token is
# classified as an argument or as a terminator/redirection.
#
# Prints one line per bare return: "<line-number>:<original line>".

# Replace the CONTENTS of quoted spans with X, preserving length and the quote
# characters, so column positions stay meaningful and nothing inside a string
# can ever be read as code. Handles \' and \" escapes inside double quotes.
function blank_quotes(s,   out, i, c, q, esc) {
    out = ""; q = ""; esc = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q == "") {
            if (c == "'" || c == "\"") { q = c; out = out c; continue }
            out = out c
        } else {
            if (esc) { out = out "X"; esc = 0; continue }
            if (q == "\"" && c == "\\") { out = out "X"; esc = 1; continue }
            if (c == q) { q = ""; out = out c; continue }
            out = out "X"
        }
    }
    return out
}

# A `return` is bare when the next token is nothing, a command terminator, a
# control operator, or a redirection — including one introduced by an IO number.
function tail_is_bare(rest) {
    sub(/^[ \t]+/, "", rest)
    if (rest == "")                      return 1   # end of line
    if (rest ~ /^[;}&|)]/)               return 1   # ; } & | ) and && ||
    if (rest ~ /^[<>]/)                  return 1   # > /dev/null, >&2, <file
    if (rest ~ /^[0-9]+[<>]/)            return 1   # IO number: 2> /dev/null
    return 0                                        # anything else is an argument
}

{
    line = $0
    scan = blank_quotes(line)
    pos = 1
    while (1) {
        idx = match(substr(scan, pos), /(^|[ \t;{}&|(])return([ \t]|$|[;}&|)<>])/)
        if (idx == 0) break
        start = pos + idx - 1
        # Locate the keyword itself within the matched span, then classify what
        # follows it.
        kw = index(substr(scan, start, RLENGTH), "return")
        after = start + kw - 1 + length("return")
        if (tail_is_bare(substr(scan, after))) {
            printf "%d:%s\n", FNR, line
            break
        }
        pos = after
    }
}
