#!/usr/bin/env bash
# Copilot follows no pointers, so its file is generated from the body of `AGENTS.md` rather than kept by hand.
#
#   build-copilot-instructions.sh [source] [destination]
#
# With no destination the copy goes to stdout. With one, it is written whole into a temporary beside
# the destination and renamed over it only after the layout is accepted, so a refusal leaves the
# existing copy as it was.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:-$root/AGENTS.md}"
dst="${2:-}"
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
# `mv` moves a file inside a directory it resolves the destination to and reports success; `rename(2)`
# refuses a directory, so the exact rename is asked of `perl` and a directory is refused before that.
if [ -d "$dst" ]; then
    echo "$0: destination '$dst' is a directory" >&2
    exit 1
fi
tmp="$(mktemp "$(dirname -- "$dst")/.copilot-instructions.XXXXXX")"
# `mktemp` creates the temporary 0600, which the rename would carry onto a tracked file.
if emit > "$tmp" && [ -s "$tmp" ] && chmod 644 -- "$tmp" && perl -e 'rename $ARGV[0], $ARGV[1] or exit 1' -- "$tmp" "$dst"; then
    exit 0
fi
rm -f -- "$tmp"
exit 1
