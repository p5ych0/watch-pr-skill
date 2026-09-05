#!/usr/bin/env bash
# Copilot follows no pointers, so its file is generated from the body of `AGENTS.md` rather than kept by hand.
#
#   build-copilot-instructions.sh [source] [destination]
set -euo pipefail
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
body="$(emit)"
# The handoff library refuses a destination that is not a regular file or a link to one, creates its
# temporary exclusively and renames exactly; a second copy of that rule here would be the defect it removes.
rb_write_handoff() { return 127; }
. "$root/skills/watch-prs/scripts/writelib.sh"
rb_write_handoff "$dst" "$body" >&2
