#!/usr/bin/env bash
# Copilot follows no pointers, so its file is generated from the body of `AGENTS.md` rather than kept by hand.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:-$root/AGENTS.md}"
# The marker layout is validated before anything is printed, so a malformed source exits non-zero
# with nothing on stdout rather than leaving a partial policy for a redirection to install.
awk '
    $0 == "<!-- copilot-body-start -->" { s++; if (s > 1 || e > 0) bad = 1 }
    $0 == "<!-- copilot-body-end -->"   { e++; if (e > 1 || s == 0) bad = 1 }
    END { if (bad || s != 1 || e != 1) exit 1 }
' "$src"
printf '%s\n' \
    '# Copilot review instructions' \
    '' \
    'Copilot reads this file and follows no pointers, so the review policy Codex reads in' \
    '`AGENTS.md` is generated into it by `.github/build-copilot-instructions.sh`; the contract' \
    'test refuses a copy that is behind.' \
    ''
awk '
    /^<!-- copilot-body-start -->$/ { p = 1; next }
    /^<!-- copilot-body-end -->$/   { p = 0; next }
    p { print }
' "$src"
