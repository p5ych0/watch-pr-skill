#!/usr/bin/env bash
# Copilot follows no pointers, so its file is generated from the body of `AGENTS.md` rather than kept by hand.
#
#   build-copilot-instructions.sh [source] [destination]
set -euo pipefail
if [ "$#" -gt 2 ]; then
    echo "$0: takes a source and an optional destination, not $# arguments" >&2
    exit 1
fi
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:-$root/AGENTS.md}"
dst="${2:-}"
# A relative name beginning with `-` is an option to awk, and `-` alone is its stdin.
case "$src" in /*) ;; *) src="./$src" ;; esac
# A source rewritten between two opens must not be validated as one thing and emitted as another.
emit() {
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
}
if [ -z "$dst" ]; then
    emit
    exit 0
fi
# Installed over its own source, the copy would strip the markers the next generation needs.
if [ "$src" = "$dst" ] || [ "$src" -ef "$dst" ]; then
    echo "$0: the destination '$dst' is the source" >&2
    exit 1
fi
# The value crosses in a shell variable, which cannot carry a NUL and drops trailing newlines: a
# source holding a NUL is refused, and the trailing newline the library appends is the one kept back.
if ! tr -d '\000' < "$src" | cmp -s - "$src"; then
    echo "$0: the source holds a NUL byte, which the destination form cannot carry" >&2
    exit 1
fi
body="$(emit && printf x)"
body="${body%x}"
body="${body%$'\n'}"
# A second copy of the handoff rule here would be the defect the library exists to remove.
rb_write_handoff() { return 127; }
. "$root/skills/watch-prs/scripts/writelib.sh"
rb_write_handoff "$dst" "$body" >&2
