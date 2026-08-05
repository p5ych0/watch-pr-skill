#!/usr/bin/env bash
# Re-drift guard: the review-bus scripts + skill must stay repo-agnostic —
# identity is derived from `git remote get-url origin`, never hard-coded. Fails
# if a concrete owner/repo slug or bus path appears. (Bare `p5ych0` is allowed —
# it names the shared review token in comments, not an identity to derive.)
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Concrete-identity patterns that must never be hard-coded: a repo slug
# (p5ych0/pulse), a unit slug (p5ych0-pulse), or any concrete /tmp path keyed on
# the repo name (…/pulse-review-bus, …/pulse-claude-worktrees, …).
PAT='p5ych0/(pulse|strumok)|p5ych0-(pulse|strumok)|/tmp/(p5ych0-)?(pulse|strumok)-|/home/[^ ]*/(pulse|strumok)\b|owner=.?p5ych0|repo=.?(pulse|strumok)|(PULSE|STRUMOK)_REVIEW'

FILES=( "$ROOT"/pr-review-state.sh
        "$ROOT"/pr-merge-range.sh
        "$ROOT"/pr-round-count.sh )
# Every RUNTIME script sits beside this test, and SKILL.md is one level up. Guard
# the skill only when present (robust if a consumer strips it); in the plugin it
# is always there, so it is always linted.
SKILL="$ROOT/../SKILL.md"
[ -f "$SKILL" ] && FILES+=( "$SKILL" )

# The list above must not go stale: a new runtime script that talks to GitHub is
# exactly where a hard-coded owner/repo would appear, and a guard that silently
# omits it reports PASS while its stated invariant is unverified.
missing=""
for f in "$ROOT"/pr-*.sh; do
    case "$f" in *"/pr-"*) ;; *) continue ;; esac
    covered=0
    for g in "${FILES[@]}"; do [ "$g" = "$f" ] && covered=1; done
    [ "$covered" -eq 1 ] || missing="$missing $(basename "$f")"
done
if [ -n "$missing" ]; then
    echo "FAIL - runtime script(s) not covered by the identity guard:$missing"
    echo "RESULT: FAIL"
    exit 1
fi
echo "ok   - every pr-*.sh runtime script is covered by the guard"

# A RUNTIME script must derive identity even for THIS repository. CLAUDE.md
# exempts the plugin's own metadata and install docs from the invariant - that is
# about `.claude-plugin/`, `README.md` and friends - but one installed copy serves
# every project, so `p5ych0/watch-pr-skill` baked into a script would send another
# project's PR reviews here. The shared PAT below cannot express that, because the
# same literal is legitimate in the files it also scans.
SCRIPT_PAT='p5ych0/|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"[[:space:]]*$'
script_hits=""
for f in "$ROOT"/pr-*.sh; do
    [ -f "$f" ] || continue
    h="$(grep -nHE 'REPO_SLUG=("|'"'"')[A-Za-z0-9_.-]+/|--repo[= ]"?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|p5ych0/' "$f" 2>/dev/null \
         | grep -v '\$OWNER/\$REPO' | grep -v '^\s*#' || true)"
    [ -n "$h" ] && script_hits="$script_hits$h
"
done
if [ -n "$script_hits" ]; then
    echo "FAIL - a runtime script hard-codes an owner/repo (identity must be derived):"
    printf '%s' "$script_hits" | sed 's/^/  /'
    echo "RESULT: FAIL"
    exit 1
fi
echo "ok   - no runtime script hard-codes an owner/repo, this plugin's own included"

hits="$(grep -nHE "$PAT" "${FILES[@]}" 2>/dev/null || true)"
if [ -n "$hits" ]; then
    echo "FAIL - hard-coded identity literal(s) found (identity must be derived):"
    printf '%s\n' "$hits" | sed 's/^/  /'
    echo "RESULT: FAIL"
    exit 1
fi
echo "ok   - no hard-coded owner/repo/bus identity in scripts or skill"
echo "RESULT: PASS"
