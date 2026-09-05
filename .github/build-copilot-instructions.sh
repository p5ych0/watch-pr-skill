#!/usr/bin/env bash
# Copilot follows no pointers, so its file is generated from the body of `AGENTS.md` rather than kept by hand.
#
#   build-copilot-instructions.sh [source] > .github/copilot-instructions.md
set -euo pipefail
if [ "$#" -gt 1 ]; then
    echo "$0: takes one optional source, not $# arguments" >&2
    exit 1
fi
# An empty source is a wrapper's variable that did not take, not a request for the default.
if [ "$#" -eq 1 ] && [ -z "$1" ]; then
    echo "$0: the source argument is empty" >&2
    exit 1
fi
# `CDPATH` would search elsewhere for a relative operand and print where it landed.
root="$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
src="${1:-$root/AGENTS.md}"
# A relative name beginning with `-` is an option to awk, and `-` alone is its stdin.
case "$src" in /*) ;; *) src="./$src" ;; esac
# A source rewritten between two opens must not be validated as one thing and emitted as another.
awk '
    { line[NR] = $0 }
    $0 == "<!-- copilot-body-start -->" { s++; if (s > 1 || e > 0) bad = 1; start = NR }
    $0 == "<!-- copilot-body-end -->"   { e++; if (e > 1 || s == 0) bad = 1; stop = NR }
    END {
        if (bad || s != 1 || e != 1) exit 1
        print "# Copilot review instructions"
        print ""
        print "Copilot reads this file and follows no pointers, so the review policy Codex reads in"
        print "`AGENTS.md` is generated into it by `.github/build-copilot-instructions.sh`; the contract"
        print "test refuses a copy that is behind."
        print ""
        for (i = start + 1; i < stop; i++) print line[i]
    }
' "$src"
