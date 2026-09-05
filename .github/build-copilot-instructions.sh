#!/usr/bin/env bash
# Copilot follows no pointers, so its file is generated from the body of `AGENTS.md` rather than kept by hand.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:-$root/AGENTS.md}"
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
