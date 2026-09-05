#!/usr/bin/env bash
# Copilot follows no pointers, so its file is generated from the body of `AGENTS.md` rather than kept by hand.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:-$root/AGENTS.md}"
# One read of the source, buffered, and nothing printed until the marker layout has been accepted:
# a malformed source exits non-zero with an empty stdout, and a source rewritten between two opens
# cannot be validated as one thing and emitted as another.
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
