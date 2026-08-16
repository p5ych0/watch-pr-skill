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

# The SHARED LIBRARIES are in this list too. The glob below is `pr-*.sh`, which
# reaches no file named `*lib.sh` — so when the identity parser moved out of the
# three helpers and into `identitylib.sh`, the one file that now decides which
# repository every `gh` call addresses would have left the guard's coverage
# entirely, and the guard would have gone on reporting that no runtime script
# hard-codes an identity. A rule that follows the code has to follow it here too.
FILES=( "$ROOT"/pr-review-state.sh
        "$ROOT"/pr-ci-state.sh
        "$ROOT"/pr-ci-gate.sh
        "$ROOT"/pr-merge-gate.sh
        "$ROOT"/pr-merge-range.sh
        "$ROOT"/pr-round-count.sh
        "$ROOT"/pr-signoff.sh
        "$ROOT"/pr-close-round.sh
        "$ROOT"/pr-copilot-phase.sh
        "$ROOT"/pr-findings.sh
        "$ROOT"/pr-watch.sh
        "$ROOT"/pr-selfcheck.sh
        "$ROOT"/identitylib.sh
        "$ROOT"/loadlib.sh
        "$ROOT"/recordlib.sh
        "$ROOT"/clocklib.sh
        "$ROOT"/testlib.sh )
# Every RUNTIME script sits beside this test, and SKILL.md is one level up. Guard
# the skill only when present (robust if a consumer strips it); in the plugin it
# is always there, so it is always linted.
SKILL="$ROOT/../SKILL.md"
[ -f "$SKILL" ] && FILES+=( "$SKILL" )

# THE LIBRARIES, AND WHAT THEY DEFINE, read off the tree rather than listed. Both
# alternations below were hand-written lists and `clocklib.sh` landed missing from
# each, which is the omission this derivation removes for every future one.
# `loadlib.sh` is excluded: it is the bootstrap, and every caller loads it by hand
# because a helper cannot load the file that defines it.
_LIB_NAMES="$(ls "$ROOT" 2>/dev/null | sed -n 's/^\([a-z][a-z]*lib\)\.sh$/\1/p' \
    | grep -v '^loadlib$' | tr '\n' '|' | sed 's/|$//')"
[ -n "$_LIB_NAMES" ] || { echo "FAIL - no shared libraries found; the hand-load guard would assert nothing"; exit 1; }
# FROM THE NAMED FILES, NOT A GLOB. `*lib.sh` also matches `test-recordlib.sh`,
# which dragged in every fixture helper — and `loadlib.sh`, whose `rb_load` every
# caller clears BY DESIGN in the four-line bootstrap, so the guard reported all
# nine runtime scripts as carrying their own copy of the loading rule.
_LIB_SYMS="$(for _l in $(printf '%s' "$_LIB_NAMES" | tr '|' ' '); do
        sed -n 's/^\([a-zA-Z_][a-zA-Z0-9_]*\)() *{.*$/\1/p' "$ROOT/$_l.sh" 2>/dev/null
    done | sort -u | tr '\n' '|' | sed 's/|$//')"
[ -n "$_LIB_SYMS" ] || { echo "FAIL - no library symbols found; the hand-load guard would assert nothing"; exit 1; }

# The list above must not go stale: a new runtime script that talks to GitHub is
# exactly where a hard-coded owner/repo would appear, and a guard that silently
# omits it reports PASS while its stated invariant is unverified.
# What the guard must cover, derived rather than listed: every runtime helper and
# every shared library, and NOT the test files. `*lib.sh` also matches
# `test-testlib.sh`, and a test file is where a concrete `acme/widget` is supposed
# to appear — sweeping those in would make the scan below fail on its own
# fixtures, which is a guard that has to be deleted rather than one that holds.
RUNTIME=()
for f in "$ROOT"/pr-*.sh "$ROOT"/*lib.sh; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in test-*) continue ;; esac
    RUNTIME+=( "$f" )
done
[ "${#RUNTIME[@]}" -gt 0 ] || { echo "FAIL - no runtime scripts found to guard"; echo "RESULT: FAIL"; exit 1; }
missing=""
for f in "${RUNTIME[@]}"; do
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
IDTMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
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
# ── ONE DEFINITION OF HOW EACH CALLER IS INVOKED, AND WHAT REFUSING LOOKS LIKE ──
# `pr-merge-gate.sh` was added to the literal scan and to none of the loops below,
# which is coverage that reads as coverage without being any. It refuses with 1
# rather than 2 — it is a gate, and its statuses mean merged/blocked/paused — so
# the expected status is per-script rather than assumed.
id_args() {   # id_args <script> ; sets "$@" for that caller
    case "$1" in
        pr-review-state.sh) set -- state 7 somebody ;;
        pr-findings.sh)     set -- list 7 ;;
        pr-watch.sh)        set -- 7 somebody --interval 1 --timeout 3 ;;
        pr-merge-gate.sh)   set -- 7 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa no ;;
        pr-signoff.sh)      set -- 7 somebody ;;
        pr-close-round.sh) set -- gate 7 somebody /dev/null no ;;
        pr-copilot-phase.sh) set -- record 7 /dev/null ;;
        *)                  set -- 7 ;;
    esac
    ID_ARGV=( "$@" )
}
id_rc() {   # id_rc <script> ; the status that script uses to refuse
    case "$1" in
        pr-merge-gate.sh) printf 1 ;;   # 0 merged, 1 blocked, 3 paused
        pr-close-round.sh) printf 1 ;;   # 0 closed, 1 stopped, 3 paused
        pr-copilot-phase.sh) printf 1 ;;   # 0 recorded/opened, 1 stopped, 3 paused
        *)                printf 2 ;;   # the helpers' documented error status
    esac
}
ID_CALLERS="pr-review-state.sh pr-findings.sh pr-round-count.sh pr-ci-state.sh pr-merge-gate.sh pr-signoff.sh pr-close-round.sh pr-copilot-phase.sh"
for sc in $ID_CALLERS; do
    [ -f "$ROOT/$sc" ] || continue
    id_args "$sc"; set -- "${ID_ARGV[@]}"
    # `env` inside the watchdog, never a PATH on its caller: where GNU `timeout`
    # is missing, `run_limited` polls with its own `sleep` and would inherit it.
    out="$(run_limited 20 env PATH="$IDTMP/bin:$PATH" "$ROOT/$sc" "$@" 2>&1)"
    rc=$?
    # The REASON, not just the status. Without the guard these scripts still exit
    # 2 — they simply fail further downstream, at the first `gh` call made against
    # the wrong repository — so an rc-only assertion passes on the unguarded code
    # and proves nothing. `no_origin` is reachable only when the lookup's status
    # was actually taken.
    if [ "$rc" -eq "$(id_rc "$sc")" ] && printf '%s' "$out" | grep -q 'reason=no_origin'; then
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

# ── a STALE parser definition does not satisfy the load check ──────────────
# Bash exports functions through the environment. A caller that had run
# `export -f rb_identity` leaves one defined in the helper's shell before it
# sources the library — and a library that is empty, or truncated above the
# definition, still sources SUCCESSFULLY. The `type -t` guard then finds the
# inherited function, reports the parser loaded, and every `gh` call is addressed
# by whatever that stale version derives. The exported stub here derives
# `someone-else/other-repo`, so the assertion is that no request carries it.
set +e
STALETMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
mkdir -p "$STALETMP/lib" "$STALETMP/bin"
: > "$STALETMP/lib/identitylib.sh"          # sources cleanly, defines nothing
cat > "$STALETMP/bin/gh" <<'GHSH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_SPY"
exit 1
GHSH
chmod +x "$STALETMP/bin/gh"
for sc in $ID_CALLERS; do
    [ -f "$ROOT/$sc" ] || continue
    id_args "$sc"; set -- "${ID_ARGV[@]}"
    # The helper is run from a copy whose identitylib.sh is empty, with a stale
    # `rb_identity` exported into its environment. `recordlib.sh` and the helper
    # itself are symlinked in, so the ONLY thing this changes is the parser.
    rm -rf "$STALETMP/run"; mkdir -p "$STALETMP/run"
    for g in "$ROOT"/*.sh; do ln -sf "$g" "$STALETMP/run/$(basename "$g")"; done
    ln -sf "$STALETMP/lib/identitylib.sh" "$STALETMP/run/identitylib.sh"
    : > "$STALETMP/spy"
    : > "$STALETMP/spy"
    out="$(run_limited 20 env GH_SPY="$STALETMP/spy" PATH="$STALETMP/bin:$PATH" \
             bash -c 'rb_identity() { HOST=github.com; OWNER=someone-else; REPO=other-repo; }
                      export -f rb_identity
                      exec "$1" "${@:2}"' _ "$STALETMP/run/$sc" "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq "$(id_rc "$sc")" ] && printf '%s' "$out" | grep -q 'reason=identitylib_empty'; then
        echo "ok   - $sc refuses an empty library even with a parser already defined"
    else
        echo "FAIL - $sc accepted an inherited parser (rc=$rc out='$out')"; idfail=1
    fi
    if [ -s "$STALETMP/spy" ]; then
        echo "FAIL - $sc addressed a request from a stale parser: $(tr '\n' ';' < "$STALETMP/spy")"
        idfail=1
    else
        echo "ok   - …and addressed no request with what it derived"
    fi
done

# ── a definition that CANNOT be cleared is a load failure ──────────────────
# `readonly -f rb_identity` makes `unset -f` fail and leaves the function
# installed, so `unset -f … || true` made a definition that could not be removed
# read exactly like one that was never there.
#
# WHERE THIS IS REACHABLE, stated rather than implied. The readonly attribute does
# NOT survive function export: a child process receives the definition and can
# unset it, which is why the three helpers above are exercised with an EXPORTED
# parser and not a readonly one — a fixture marking it readonly would prove
# nothing about them, because they never see it. The case is real for `SKILL.md`,
# whose bash runs in the driving session's own shell, where an earlier block or
# the session itself may have marked it readonly.
#
# So the mechanism is proven directly, in one shell, and the contract test
# asserts SKILL.md branches on the status. Both halves are needed: the mechanism
# alone does not say the callers adopted it, and the text alone does not say it
# works.
mech="$(bash -c 'rb_identity() { :; }; readonly -f rb_identity
    unset -f rb_identity 2>/dev/null || { echo REFUSED; exit 2; }
    echo "CLEARED:$(type -t rb_identity)"' 2>&1)"; mech_rc=$?
{ [ "$mech_rc" -eq 2 ] && [ "$mech" = REFUSED ]; } \
    && echo "ok   - a readonly parser definition cannot be cleared, and the status says so" \
    || { echo "FAIL - clearing a readonly definition did not report failure (rc=$mech_rc '$mech')"; idfail=1; }
# …and the unchecked form is what it was: the function survives and the shell
# carries on, which is the whole defect in one line.
mech2="$(bash -c 'rb_identity() { :; }; readonly -f rb_identity
    unset -f rb_identity 2>/dev/null || true
    echo "CONTINUED:$(type -t rb_identity)"' 2>&1)"
[ "$mech2" = "CONTINUED:function" ] \
    && echo "ok   - …and discarding that status leaves the stale definition installed" \
    || { echo "FAIL - the unchecked form did not reproduce the defect ('$mech2')"; idfail=1; }
# EVERY caller branches on it. The mechanism above is about Bash; this is about
# whether the four files that clear the parser actually take the status.
# THE RULE MOVED, SO THE ASSERTION FOLLOWS IT. Each script used to write the
# clear-source-verify sequence out for itself, and this checked that each one
# branched on its own `unset`. They call `rb_load` now, so what has to hold is
# that they call it — and that `rb_load` is the thing that takes the status.
# Checking the scripts for an `unset` they no longer contain would pass by
# vacuity, which is the failure mode this file exists to avoid.
# `pr-watch.sh` is in this list too. It loads `recordlib.sh` rather than the
# identity parser, so the identity clause skips it — but the BOOTSTRAP rule is
# about loading anything at all, and `pr-watch.sh` is the caller the invariant was
# written to cover and did not: it sourced `recordlib.sh` by hand, without
# clearing `is_full_sha`, while CLAUDE.md said every helper went through the
# loader. An invariant is only as true as its least-checked caller.
for sc in pr-review-state.sh pr-findings.sh pr-round-count.sh pr-ci-state.sh pr-watch.sh; do
    [ -f "$ROOT/$sc" ] || continue
    if [ "$sc" = pr-watch.sh ]; then
        # It loads `recordlib.sh`, not the parser — the message says which, because
        # a fixture that reports the wrong thing passing is how a gap hides.
        if grep -q 'rb_load "\$_RB_SELF_DIR" recordlib is_full_sha' "$ROOT/$sc"; then
            echo "ok   - $sc loads the shape rules through the shared loader"
        else
            echo "FAIL - $sc loads recordlib some other way"; idfail=1
        fi
    elif grep -q 'rb_load "\$_RB_SELF_DIR" identitylib rb_identity' "$ROOT/$sc"; then
        echo "ok   - $sc loads the identity parser through the shared loader"
    else
        echo "FAIL - $sc loads identitylib some other way"; idfail=1
    fi
    # …and nowhere writes the sequence out again. A copy re-introduced beside the
    # call is how the four copies happened the first time.
    # NOT ANCHORED AT COLUMN ONE. The source line was matched with `^\.`, so a
    # re-introduced load indented by so much as one space — inside an `if`, or
    # simply reformatted — walked past the guard and the duplication came back
    # with the check still green. Leading whitespace is allowed, and `source` is
    # matched as well as `.`: the rule is about loading a library by hand, not
    # about which of the two spellings was used.
    #
    # THE TWO ALTERNATIONS ARE DERIVED, NOT WRITTEN OUT. They were lists — of
    # library basenames and of the symbols a hand-load clears — and `clocklib.sh`
    # arrived missing from both, so a script could source it by hand and this
    # check stayed green. That is the shape `CLAUDE.md` names: a list of names is
    # wrong by omission, so change the shape until no list is needed. The
    # libraries ARE the `*lib.sh` files beside this test, and their symbols are
    # the functions they define; `loadlib.sh` is excluded because it is the
    # bootstrap every caller must load by hand.
    # THE PATTERN STAYS IN SINGLE QUOTES, with the derived names spliced in. The
    # first version put the whole thing in double quotes so the variables would
    # expand — and `\$_RB_SELF_DIR` then reached `grep` as `$_RB_SELF_DIR`, where
    # `$` is an end-of-line anchor. The pattern matched NOTHING, both fixtures
    # below passed, and the guard reported an invariant it no longer had.
    if grep -qE 'unset -f ('"$_LIB_SYMS"')' "$ROOT/$sc" \
       || grep -qE '^[[:space:]]*(\.|source)[[:space:]]+"?\$_RB_SELF_DIR/('"$_LIB_NAMES"')\.sh' "$ROOT/$sc"; then
        echo "FAIL - $sc has its own copy of the loading rule again"; idfail=1
    else
        echo "ok   - …and carries no second copy of the loading rule"
    fi
    # THE BOOTSTRAP OBEYS THE RULE TOO. The loader cannot load itself, so those
    # lines are written out — and that is not a licence to load it carelessly. An
    # exported `rb_load` plus an empty `loadlib.sh` leaves a STALE LOADER doing
    # the clearing and verifying for every other library, which is the one way to
    # make every subsequent load look clean.
    bs="$(awk '
        /unset -f rb_load/ { j = $0; n = 2; next }
        n > 0 { j = j " " $0; n--; if (n == 0) print j; next }
    ' "$ROOT/$sc" | grep -cE '\|\|.*exit 2')"
    if [ "${bs:-0}" -ge 1 ]; then
        echo "ok   - …and clears the loader itself, with the status taken"
    else
        echo "FAIL - $sc sources loadlib.sh over whatever it inherited"; idfail=1
    fi
done
# The loader is where the clearing and its status now live, and it is joined to a
# branch that returns. Read positively: forbidding one spelling is a blacklist.
coupled="$(awk '
    /unset -f "\$sym"/ { j = $0; n = 2; next }
    n > 0 { j = j " " $0; n--; if (n == 0) print j; next }
' "$ROOT/loadlib.sh" | grep -cE '\|\|.*return 2')"
if [ "${coupled:-0}" -ge 1 ]; then
    echo "ok   - the loader couples the clear to a failing load branch"
else
    echo "FAIL - the loader does not branch on the unset status"; idfail=1
fi
rm -rf "$STALETMP"
set -e

# ── EVERY bootstrap, at the outcome level ──────────────────────────────────
# The structural check above recognises each caller's `unset` branch, and
# `pr-ci-state.sh` is exercised end-to-end — which leaves the other four bootstraps
# with no evidence of what they DO when the loader is stale. They are duplicated
# code by necessity (a helper cannot load the file that defines it), and
# duplicated code needs duplicated coverage: that is the comment this file already
# carries about the identity parser, and it applies to its own bootstrap.
#
# The state is the dangerous one: an exported PERMISSIVE `rb_load` that returns 0
# without loading anything, plus an empty `loadlib.sh`. Every library after it is
# then unloaded and unchecked.
set +e
BSTMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
mkdir -p "$BSTMP/bin" "$BSTMP/run"
cat > "$BSTMP/bin/gh" <<'GHSH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_SPY"
exit 1
GHSH
chmod +x "$BSTMP/bin/gh"
for g in "$ROOT"/*.sh; do ln -sf "$g" "$BSTMP/run/$(basename "$g")"; done
rm -f "$BSTMP/run/loadlib.sh"; : > "$BSTMP/run/loadlib.sh"
for sc in $ID_CALLERS pr-watch.sh; do
    [ -f "$ROOT/$sc" ] || continue
    id_args "$sc"; set -- "${ID_ARGV[@]}"
    : > "$BSTMP/spy"
    bs_out="$(run_limited 20 env GH_SPY="$BSTMP/spy" PATH="$BSTMP/bin:$PATH" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        bash -c 'rb_load() { return 0; }
                 export -f rb_load
                 exec "$1" "${@:2}"' _ "$BSTMP/run/$sc" "$@" 2>&1)"; bs_rc=$?
    if [ "$bs_rc" -eq "$(id_rc "$sc")" ] && printf '%s' "$bs_out" | grep -q 'reason=loadlib_empty'; then
        echo "ok   - $sc refuses an empty loader even with rb_load already defined"
    else
        echo "FAIL - $sc accepted an inherited loader (rc=$bs_rc out='$bs_out')"; idfail=1
    fi
    # THE CALLER'S OWN SENTINEL, because that is what its consumers branch on: a
    # refusal addressed as somebody else's is a failure nobody is listening for.
    case "$sc" in
        pr-watch.sh) bs_want='PR_REVIEW_WATCH state=error' ;;
        pr-review-state.sh) bs_want='PR_REVIEW_STATE status=error' ;;
        pr-findings.sh) bs_want='PR_FINDINGS status=error' ;;
        pr-round-count.sh) bs_want='PR_ROUND_COUNT status=error' ;;
        # The gate's sentinel is prose, not a `PR_X status=` line: its consumer is
        # the operator reading why a merge did not happen, and every refusal it can
        # make begins the same way.
        pr-merge-gate.sh) bs_want='merge blocked:' ;;
        pr-close-round.sh) bs_want='ABORT:' ;;
        pr-copilot-phase.sh) bs_want='ABORT:' ;;
        pr-signoff.sh) bs_want='PR_SIGNOFF status=error' ;;
        *) bs_want='PR_CI_STATE status=error' ;;
    esac
    if printf '%s' "$bs_out" | grep -qF "$bs_want"; then
        echo "ok   - …addressed in its own words"
    else
        echo "FAIL - $sc did not report as '$bs_want' (out='$bs_out')"; idfail=1
    fi
    # …and the consequence: nothing was asked, and nothing was reported ready. An
    # rc-only assertion passes on a script that acted first and failed afterwards.
    if [ -s "$BSTMP/spy" ]; then
        echo "FAIL - $sc addressed a request after a failed load: $(tr '\n' ';' < "$BSTMP/spy")"
        idfail=1
    else
        echo "ok   - …and addressed no request"
    fi
    if printf '%s' "$bs_out" | grep -q 'PR_REVIEW_READY'; then
        echo "FAIL - $sc reported a verdict ready after a failed load"; idfail=1
    else
        echo "ok   - …and reported nothing ready"
    fi
done
rm -rf "$BSTMP"
set -e

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
SHAPETMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
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
    for sc in $ID_CALLERS; do
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
        if [ "$rc" -eq "$(id_rc "$sc")" ] && printf '%s' "$out" | grep -q "reason=$want"; then
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
echo "ok   - every runtime script and shared library is covered by the guard"

# A RUNTIME script must derive identity even for THIS repository. CLAUDE.md
# exempts the plugin's own metadata and install docs from the invariant - that is
# about `.claude-plugin/`, `README.md` and friends - but one installed copy serves
# every project, so `p5ych0/watch-pr-skill` baked into a script would send another
# project's PR reviews here. The shared PAT below cannot express that, because the
# same literal is legitimate in the files it also scans.
SCRIPT_PAT='p5ych0/|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"[[:space:]]*$'
# A SCAN THAT CANNOT READ ITS INPUT IS NOT A CLEAN SCAN. This was a `grep` piped
# through two filters with `|| true` on the end: an unreadable script, or any
# stage failing with no output, produced an empty result — and empty is exactly
# what "no runtime script hard-codes an identity" looks like, so the guard could
# report its invariant held without having read anything.
#
# One `awk` pass, one status. `awk` has no "no match" exit code, so any non-zero
# is a real failure and there is nothing to normalise away.
scan_hardcoded_identity() {   # <file...> ; prints hits; 2 if the scan failed
    local errf out rc msg mrc
    errf="$(mktemp)" || return 2
    rc=0
    out="$(awk '
        /^[[:space:]]*#/ { next }
        # The derived reference is REMOVED, not used to skip the line. `next`
        # threw away every line containing `$OWNER/$REPO`, so
        # `REPO_SLUG="acme/widget"; echo "$OWNER/$REPO"` scanned clean — the guard
        # asserting the repo-agnostic invariant while a runtime script routed
        # the review traffic of another project to a fixed repository.
        # (No apostrophe in this comment: the awk program is single-quoted in
        # the shell, and one would terminate it.)
        { line = $0; gsub(/\$OWNER\/\$REPO/, "", line) }
        line ~ /REPO_SLUG=("|'"'"')[A-Za-z0-9_.-]+\// ||
        line ~ /--repo[= ]"?[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/ ||
        line ~ /p5ych0\// { print FILENAME ":" FNR ":" $0 }
    ' "$@" 2>"$errf")" || rc=$?
    msg="$(cat "$errf" 2>/dev/null)"; mrc=$?
    rm -f "$errf" 2>/dev/null
    [ "$mrc" -eq 0 ] || return 2
    [ "$rc" -eq 0 ] || return 2
    [ -z "$msg" ] || return 2
    printf '%s' "$out"
    return 0
}
sh_rc=0
script_hits="$(scan_hardcoded_identity "${RUNTIME[@]}")" || sh_rc=$?
if [ "$sh_rc" -ne 0 ]; then
    echo "FAIL - the hard-coded-identity scan could not be completed (rc=$sh_rc)"
    echo "RESULT: FAIL"
    exit 1
fi
if [ -n "$script_hits" ]; then
    echo "FAIL - a runtime script hard-codes an owner/repo (identity must be derived):"
    printf '%s' "$script_hits" | sed 's/^/  /'
    echo "RESULT: FAIL"
    exit 1
fi
echo "ok   - no runtime script hard-codes an owner/repo, this plugin's own included"

# Same rule for the shared-pattern scan. `grep` exits 1 for no-match and >1 for
# a real error; collapsing both with `|| true` made an unreadable file read as a
# clean bill of health.
pat_errf="$(mktemp)" || { echo "FAIL - no scratch file for the identity scan"; echo "RESULT: FAIL"; exit 1; }
# `|| pat_rc=$?` rather than `|| true`: this file runs under `-e`, so a no-match
# grep (status 1) would abort the script outright — which is why the suppression
# was there. The status is captured instead of discarded, so "nothing matched"
# and "could not read" stay distinguishable.
pat_rc=0
hits="$(grep -nHE "$PAT" "${FILES[@]}" 2>"$pat_errf")" || pat_rc=$?
pat_msg="$(cat "$pat_errf" 2>/dev/null)"; pat_msg_rc=$?
rm -f "$pat_errf" 2>/dev/null
if [ "$pat_msg_rc" -ne 0 ] || [ "$pat_rc" -gt 1 ] || [ -n "$pat_msg" ]; then
    echo "FAIL - the identity-literal scan could not be completed (rc=$pat_rc): $pat_msg"
    echo "RESULT: FAIL"
    exit 1
fi
if [ -n "$hits" ]; then
    echo "FAIL - hard-coded identity literal(s) found (identity must be derived):"
    printf '%s\n' "$hits" | sed 's/^/  /'
    echo "RESULT: FAIL"
    exit 1
fi
echo "ok   - no hard-coded owner/repo/bus identity in scripts or skill"

# ── the scan itself fails closed on an input it cannot read ────────────────
# The invariant this file owns is "no runtime script hard-codes an identity", and
# an unreadable script used to yield the same empty result as a clean one — so the
# guard could report the invariant held without having read the script at all.
# Exercised against the production function rather than asserted about.
set +e
UNREAD="$(mktemp -d)" || { echo "FAIL - no scratch dir for the scan fixture"; echo "RESULT: FAIL"; exit 1; }
printf '#!/usr/bin/env bash\n: \n' > "$UNREAD/pr-fake.sh"
chmod 000 "$UNREAD/pr-fake.sh"
if cat "$UNREAD/pr-fake.sh" >/dev/null 2>&1; then
    # Root, or a filesystem that ignores the mode. Said out loud: the case did
    # not run, so it proved nothing.
    echo "ok   - SKIPPED: this user can read a mode-000 file, so the case cannot be built"
else
    scan_hardcoded_identity "$UNREAD"/pr-*.sh >/dev/null 2>&1
    if [ "$?" -eq 2 ]; then
        echo "ok   - a script the scan cannot read is a failure, not a clean result"
    else
        echo "FAIL - an unreadable runtime script was reported as carrying no identity"
        rm -rf "$UNREAD"; echo "RESULT: FAIL"; exit 1
    fi
fi
# The control, so "always fails" cannot satisfy the case above — and the positive
# direction, so a scan that finds nothing anywhere is not mistaken for a guard.
rm -f "$UNREAD/pr-fake.sh"
printf '#!/usr/bin/env bash\nREPO_SLUG="acme/widget"\n' > "$UNREAD/pr-offender.sh"
# A MIXED line: the derived reference and a literal identity together. Skipping
# the whole line on `$OWNER/$REPO` reported this clean, so the guard could assert
# the repo-agnostic invariant while a runtime script routed review traffic to a
# fixed repository. The derived token is removed from the line, not used to
# discard it.
printf '#!/usr/bin/env bash\nREPO_SLUG="acme/widget"; echo "$OWNER/$REPO"\n' > "$UNREAD/pr-mixed.sh"
found="$(scan_hardcoded_identity "$UNREAD"/pr-*.sh)"; frc=$?
if [ "$frc" -eq 0 ] && printf '%s' "$found" | grep -q 'pr-offender.sh' \
   && printf '%s' "$found" | grep -q 'pr-mixed.sh'; then
    echo "ok   - …and a script that does hard-code one is caught, even beside \$OWNER/\$REPO"
else
    echo "FAIL - a hard-coded REPO_SLUG was not caught (rc=$frc out='$found')"
    rm -rf "$UNREAD"; echo "RESULT: FAIL"; exit 1
fi
rm -rf "$UNREAD"
set -e
echo "RESULT: PASS"
