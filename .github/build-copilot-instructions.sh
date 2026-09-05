#!/usr/bin/env bash
# Copilot follows no pointers, so its file is generated from the body of `AGENTS.md` rather than kept by hand.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:-$root/AGENTS.md}"
printf '%s\n' \
    '# Copilot review instructions' \
    '' \
    'Copilot reads this file and follows no pointers, so the review policy Codex reads in' \
    '`AGENTS.md` is generated into it by `.github/build-copilot-instructions.sh`; the contract' \
    'test refuses a copy that is behind.' \
    ''
# Exactly one start marker, exactly one end marker, in that order; anything else exits non-zero
# rather than emitting a body with a silent gap.
awk '
    /^<!-- copilot-body-start -->$/ { s++; if (s > 1 || e > 0) bad = 1; p = 1; next }
    /^<!-- copilot-body-end -->$/   { e++; if (e > 1 || s == 0) bad = 1; p = 0; next }
    p { print }
    END { if (bad || s != 1 || e != 1) exit 1 }
' "$src"
