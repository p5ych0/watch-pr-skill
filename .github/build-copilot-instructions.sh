#!/usr/bin/env bash
# Prints `.github/copilot-instructions.md` from the body of `AGENTS.md`: Copilot reads only its own
# file and follows no pointers, so the policy is generated into it rather than kept by hand.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
printf '%s\n' \
    '# Copilot review instructions' \
    '' \
    'Copilot reads this file and follows no pointers, so the review policy Codex reads in' \
    '`AGENTS.md` is generated into it by `.github/build-copilot-instructions.sh`. Edit' \
    '`AGENTS.md`, regenerate, and commit both; the contract test refuses a copy that is behind.' \
    ''
awk '/^<!-- copilot-body-start -->$/ { p = 1; next } /^<!-- copilot-body-end -->$/ { p = 0 } p' "$root/AGENTS.md"
