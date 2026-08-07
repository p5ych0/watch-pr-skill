#!/usr/bin/env bash
# Re-drift guard: the review-bus scripts + skill must stay repo-agnostic —
# identity is derived from `git remote get-url origin`, never hard-coded. Fails
# if a concrete owner/repo slug or bus path appears. (Bare `p5ych0` is allowed —
# it names the shared review token in comments, not an identity to derive.)
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Portable watchdog: stock macOS ships no GNU `timeout`, and the suite is a
# mandatory pre-push gate.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"

# Concrete-identity patterns that must never be hard-coded: a repo slug
# (p5ych0/pulse), a unit slug (p5ych0-pulse), or any concrete /tmp path keyed on
# the repo name (…/pulse-review-bus, …/pulse-claude-worktrees, …).
PAT='p5ych0/(pulse|strumok)|p5ych0-(pulse|strumok)|/tmp/(p5ych0-)?(pulse|strumok)-|/home/[^ ]*/(pulse|strumok)\b|owner=.?p5ych0|repo=.?(pulse|strumok)|(PULSE|STRUMOK)_REVIEW'

FILES=( "$ROOT"/pr-review-state.sh
        "$ROOT"/pr-merge-range.sh
        "$ROOT"/pr-round-count.sh
        "$ROOT"/pr-findings.sh
        "$ROOT"/pr-watch.sh
        "$ROOT"/pr-selfcheck.sh )
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
# ── an origin lookup that prints and THEN fails is not an identity ────────
# `git remote get-url origin` can write a plausible URL and exit non-zero, and
# command substitution keeps what it wrote. Every `gh` call is addressed by the
# identity derived from it, so accepting that output sends one project's review
# traffic somewhere else.
#
# `set +e` around the block: this file runs under `-Eeuo pipefail`, and these
# probes are EXPECTED to fail — that is the assertion. Without it the first stub
# invocation aborts the script, which then reports nothing at all.
idfail=0
set +e
IDTMP="$(mktemp -d)"
mkdir -p "$IDTMP/bin"
REAL_GIT="$(command -v git)"
cat > "$IDTMP/bin/git" <<GITSH
#!/usr/bin/env bash
if [ "\$1" = "remote" ]; then
    printf 'git@github.com:someone-else/other-repo.git\n'
    exit 1
fi
exec "$REAL_GIT" "\$@"
GITSH
chmod +x "$IDTMP/bin/git"
# `gh` is stubbed too, so the UNGUARDED path cannot reach the network — CI has no
# credentials — and so that its failure is distinguishable from the guarded one.
printf '#!/usr/bin/env bash\nexit 1\n' > "$IDTMP/bin/gh"
chmod +x "$IDTMP/bin/gh"
for sc in pr-review-state.sh pr-findings.sh pr-round-count.sh; do
    [ -f "$ROOT/$sc" ] || continue
    case "$sc" in
        pr-review-state.sh) set -- state 7 somebody ;;
        pr-findings.sh)     set -- list 7 ;;
        *)                  set -- 7 ;;
    esac
    # `env` inside the watchdog, never a PATH on its caller: where GNU `timeout`
    # is missing, `run_limited` polls with its own `sleep` and would inherit it.
    out="$(run_limited 20 env PATH="$IDTMP/bin:$PATH" "$ROOT/$sc" "$@" 2>&1)"
    rc=$?
    # The REASON, not just the status. Without the guard these scripts still exit
    # 2 — they simply fail further downstream, at the first `gh` call made against
    # the wrong repository — so an rc-only assertion passes on the unguarded code
    # and proves nothing. `no_origin` is reachable only when the lookup's status
    # was actually taken.
    if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'reason=no_origin'; then
        echo "ok   - $sc rejects an origin lookup that printed before failing"
    else
        echo "FAIL - $sc accepted a failed origin lookup (rc=$rc out='$out')"; idfail=1
    fi
    if printf '%s' "$out" | grep -q 'someone-else'; then
        echo "FAIL - $sc used the untrusted remote it was given"; idfail=1
    else
        echo "ok   - $sc did not derive an identity from it"
    fi
done

# ── the origin SHAPE matrix, run against each parser independently ─────────
# The three scripts and `SKILL.md` each carry their own copy of the identity
# parser. The hostless and file-transport rules landed in all four, but the only
# behavioural fixtures were in `test-pr-review-state.sh` — so reverting the
# branch in `pr-findings.sh` or `pr-round-count.sh` left the suite green and
# quietly restored the wrong-repository path. Duplicated code needs duplicated
# coverage; a rule proven in one copy is unproven in the others.
#
# The dangerous shapes all derive a PLAUSIBLE `acme/widget` from the path while
# naming no GitHub server, so the failure they cause is not an error — it is
# every `gh` call landing on the unrelated PUBLIC repository of that name.
set +e
SHAPETMP="$(mktemp -d)"
mkdir -p "$SHAPETMP/bin"
# `gh` records what it was asked to do. The rejection message necessarily quotes
# the remote, so grepping the OUTPUT for the derived slug matches the diagnostic
# itself and proves nothing. What matters is whether a request was ever addressed
# with it — so the spy file, not the message, is the assertion.
cat > "$SHAPETMP/bin/gh" <<'GHSH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_SPY"
exit 1
GHSH
chmod +x "$SHAPETMP/bin/gh"
shape_case() { # <remote> <expected-reason|OK> <label>
    local remote="$1" want="$2" label="$3" sc rc out
    cat > "$SHAPETMP/bin/git" <<GITSH
#!/usr/bin/env bash
if [ "\$1" = "remote" ]; then printf '%s\n' '$remote'; exit 0; fi
exec "$REAL_GIT" "\$@"
GITSH
    chmod +x "$SHAPETMP/bin/git"
    for sc in pr-review-state.sh pr-findings.sh pr-round-count.sh; do
        [ -f "$ROOT/$sc" ] || continue
        case "$sc" in
            pr-review-state.sh) set -- state 7 somebody ;;
            pr-findings.sh)     set -- list 7 ;;
            *)                  set -- 7 ;;
        esac
        : > "$SHAPETMP/spy"
        out="$(run_limited 20 env GH_SPY="$SHAPETMP/spy" PATH="$SHAPETMP/bin:$PATH" \
                 "$ROOT/$sc" "$@" 2>&1)"; rc=$?
        if [ "$want" = "OK" ]; then
            # The negative control. A real GitHub remote must NOT be caught by
            # either rule — otherwise a matrix of rejections could be satisfied
            # by a parser that rejects everything, which is not the invariant.
            if printf '%s' "$out" | grep -qE 'reason=origin_(has_no_host|transport_unsupported)'; then
                echo "FAIL - $sc rejected a valid remote as $label (out='$out')"; idfail=1
            else
                echo "ok   - $sc accepts $label"
            fi
            continue
        fi
        if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "reason=$want"; then
            echo "ok   - $sc refuses $label"
        else
            echo "FAIL - $sc accepted $label (want reason=$want, rc=$rc out='$out')"; idfail=1
        fi
        # The consequence, asserted directly: no request may have been addressed
        # at all. An rc-only assertion passes on a parser that rejected for some
        # other reason downstream, having already read, commented on, or merged
        # in the wrong repository on its way there.
        if [ -s "$SHAPETMP/spy" ]; then
            echo "FAIL - $sc addressed a request from $label: $(tr '\n' ';' < "$SHAPETMP/spy")"
            idfail=1
        else
            echo "ok   - …and addressed no request from it"
        fi
    done
}
shape_case '/srv/mirrors/acme/widget.git' origin_has_no_host 'an absolute local path'
shape_case '../acme/widget.git'           origin_has_no_host 'a relative local path'
shape_case '~/mirrors/acme/widget.git'    origin_has_no_host 'a tilde local path'
shape_case 'file://github.com/srv/acme/widget.git' origin_transport_unsupported \
           'a file:// URL carrying a github.com authority'
shape_case 'git@github.com:acme/widget.git' OK 'an ordinary SCP-style GitHub remote'
shape_case 'https://github.com/acme/widget.git' OK 'an ordinary https GitHub remote'
rm -rf "$SHAPETMP"
set -e

rm -rf "$IDTMP"
set -e
if [ "$idfail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi

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
