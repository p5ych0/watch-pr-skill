#!/usr/bin/env bash
# Re-drift guard: the helper scripts + skill must stay repo-agnostic — identity is
# derived from `git remote get-url origin`, never hard-coded. Fails if a concrete
# owner/repo slug appears, in code or in a comment.
#
# THE BARE OWNER IS NOT EXEMPT, and this header said it was until #227. The
# exemption read "it names the shared review token in comments, not an identity to
# derive", which was a v1 idea: that token went with the bus, and what is left is
# the owner of this repository appearing in a file that must work for every other.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Portable watchdog: stock macOS ships no GNU `timeout`, and the suite is a
# mandatory pre-push gate.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"

# ── THE IDENTITY OVERRIDES ARE CLEARED, AND THIS FILE IS WHY THEY MUST BE ──
#
# `SKILL.md`'s setup exports `REVIEW_BUS_REMOTE` to pin the session's repository,
# and step 5a then runs this whole suite through `pr-selfcheck.sh` — so an
# operator following the documented flow reaches this file with the pin already in
# the environment. `rb_identity` prefers it over `git remote get-url origin`, so
# every case here that forges a failing or malformed `git` would find its forgery
# never consulted, and the file went RED for a defect that was not there.
#
# NOT IN `testlib.sh`, which would have covered every fixture in one place. That
# library SHIPS AT RUNTIME — `pr-ci-state.sh` loads it to bound its `gh` calls —
# so an `unset` there executes inside the production script and wipes the pin the
# driver just set. It was written there first and `test-pr-ci-state.sh` caught it.
#
# All three names, not just the one that bit: `REVIEW_BUS_OWNER` and
# `REVIEW_BUS_REPO` override the parsed halves and would shift a forged origin's
# fields exactly as silently.
unset REVIEW_BUS_REMOTE REVIEW_BUS_OWNER REVIEW_BUS_REPO

# The concrete identity that must never be hard-coded, as ONE FIXED STRING.
#
# WHAT THIS CATCHES: this repository's OWNER, in any spelling, anywhere in the file,
# comments included. `p5ych0/other`,
# `p5ych0-other`, `/tmp/p5ych0-x-review-bus`, `owner=p5ych0` and
# `repo=$'p5ych0-x'` are each one substring away, and none of them needs the text to
# be parsed.
#
# THE OWNER ARM IS UNANCHORED ON PURPOSE. Anchoring it to `p5ych0/`, `p5ych0-` and
# `owner=p5ych0` was proposed, on the ground that a bare token names no repository.
# It is not exempt here: these files are the repo-agnostic ones, so there is no
# legitimate reason for the owner to appear in any spelling — `CLAUDE.md` grants the
# plugin's own metadata and install documentation an exemption, and neither is
# scanned. Anchoring would also be three substrings where one does, and each anchor
# is a shape somebody has to think of; the bare-token probe below says the strict
# reading is deliberate.
#
# THE PLUGIN'S OWN NAME IS NOT ONE OF THEM, and cannot be: setup's second discovery
# mode globs `~/.claude/plugins/cache/*/watch-pr-skill/*/skills/...` to find the
# scripts at all, so the literal is how the driver locates itself. An arm on it
# flags that line, which is the exemption `CLAUDE.md` already grants the plugin's
# own metadata and install path.
#
# WHY IT IS NOT A PATTERN LANGUAGE ANY MORE. This began as a list of two of the
# author's other repositories and was generalised into arms that tried to tell a
# LITERAL from an expansion after `owner=` and `repo=`, and a repository-keyed path
# from any other path. Four review rounds followed, each fixing the last and finding
# the next: a name may start with a digit (`repo=123`), then with a dot
# (`repo=.github`), then `[` is a glob and `--repo=[A-Za-z]*)` is legal code, then
# `+(` is one too under `extglob` and `$'…'` is a literal whose first character is
# `$`. Every one was a fact about SHELL SYNTAX, and reading shell syntax out of text
# needs a shell — which `CLAUDE.md` records this repository paying 2,200 lines and
# fifty-two rounds to learn once already.
#
# WHAT IS NOT CAUGHT, said rather than implied: a hard-coded identity belonging to
# NEITHER this repository nor its owner — `gh api -f owner=someone-else` — and a
# path keyed on this plugin's own name or some third project's. The first needs the literal-vs-expansion
# distinction above; the second was only ever caught by listing two project names,
# which is the list this change removes. `SCRIPT_PAT` below still catches a bare
# `owner/repo` slug in code, which is how a hard-coded target is actually written.
PAT='p5ych0'

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
        "$ROOT"/pr-phase-state.sh
        "$ROOT"/pr-close-round.sh
        "$ROOT"/pr-copilot-phase.sh
        "$ROOT"/pr-request-review.sh
        "$ROOT"/pr-findings.sh
        "$ROOT"/pr-watch.sh
        "$ROOT"/pr-origin.sh
        "$ROOT"/pr-setup.sh
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
        pr-request-review.sh) set -- 7 no /dev/null ;;
        pr-ci-gate.sh)      set -- 7 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
        pr-merge-range.sh)  set -- aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa HEAD ;;
        *)                  set -- 7 ;;
    esac
    ID_ARGV=( "$@" )
}
id_stream() {   # id_stream <script> ; the stream its loader sentinel goes to
    # THE FOUR PROSE CALLERS SAY IT ON STDOUT; the structured ones follow the
    # `PR_X status=error` lines around them, which go to stderr. Capturing both
    # together cannot tell them apart, and a sentinel on the wrong stream is the
    # ordinary-looking empty answer its consumer would get instead.
    case "$1" in
        pr-ci-gate.sh|pr-close-round.sh|pr-copilot-phase.sh|pr-merge-gate.sh) printf out ;;
        *) printf err ;;
    esac
}
id_rc() {   # id_rc <script> ; the status that script uses to refuse
    case "$1" in
        pr-merge-gate.sh) printf 1 ;;   # 0 merged, 1 blocked, 3 paused
        pr-close-round.sh) printf 1 ;;   # 0 closed, 1 stopped, 3 paused
        pr-copilot-phase.sh) printf 1 ;;   # 0 recorded/opened, 1 stopped, 3 paused
        pr-request-review.sh) printf 1 ;;   # 0 posted, 1 stopped
        pr-ci-gate.sh) printf 1 ;;   # 0 carry on, 1 stopped, 3 paused
        *)                printf 2 ;;   # the helpers' documented error status
    esac
}
ID_CALLERS="pr-review-state.sh pr-findings.sh pr-round-count.sh pr-ci-state.sh pr-merge-gate.sh pr-signoff.sh pr-close-round.sh pr-copilot-phase.sh pr-phase-state.sh pr-request-review.sh"
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
    if [ "$rc" -eq "$(id_rc "$sc")" ] && grep -q 'reason=no_origin' <<<"$out"; then
        echo "ok   - $sc rejects an origin lookup that printed before failing"
    else
        echo "FAIL - $sc accepted a failed origin lookup (rc=$rc out='$out')"; idfail=1
    fi
    if grep -q 'someone-else' <<<"$out"; then
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
    if [ "$rc" -eq "$(id_rc "$sc")" ] && grep -q 'reason=identitylib_empty' <<<"$out"; then
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
# THE CLAUSE IS A FUNCTION because two loops ask it. The one below also asserts
# WHICH loader call each script makes, which is an identity question and belongs
# to those five; the rule about not writing the loading sequence out by hand
# belongs to anything that loads a library at all, and runs over every runtime
# script further down. Separating them is #67: widening the identity loop instead
# would have failed every script that loads neither identitylib nor recordlib.
#
# THE REDIRECTION TOKEN IS REMOVED, NOT EVERYTHING AFTER IT. The first version cut
# from `2>` to the `||`, so `unset -f rb_load 2>/dev/null rb_elapsed || …` — a
# legal simple command — was trimmed down to exactly the exempt bootstrap clear
# and the copied clear passed. Only the redirection is dropped; operands after it
# survive to be judged.
# WHAT THIS CANNOT DO, so nobody mistakes it for the guarantee. It reads text, and
# a prefix redirection — `2>/dev/null unset -f rb_elapsed`, or the same before a
# `.` — moves the command word off the anchor and past both patterns. Anchoring
# is not optional either: these scripts DISCUSS `unset -f` in prose, so an
# unanchored match reports comments, which is the defect that closed #54.
#
# So this is a lint, and the guarantee is the behavioural fixture below it: each
# clock caller is run against an EMPTY `clocklib.sh` and must refuse. A
# hand-written load cannot pass that however it is spelled, because what fails
# there is the missing verification rather than the missing pattern.
rb_hand_loads() {   # <file> [sources-only] ; 0 copies the rule, 1 clean, 2 unreadable
    # THE FILE IS READ ONCE, WITH ITS STATUS TAKEN. `grep` answers 1 for "no
    # match" and 2 for "could not read", and both used to fall into the clean
    # branch — so a script this scan could not open was reported as using the
    # shared loader. A guard that cannot read a file must say so, not approve it.
    local body
    body="$(cat "$1" 2>/dev/null)" || return 2
    grep -qE '^[[:space:]]*(\.|source)[[:space:]]+"?\$_RB_SELF_DIR/('"$_LIB_NAMES"')\.sh' <<<"$body" \
        && return 0
    # SOURCES ONLY, for the one script that clears inherited functions on purpose.
    # Exempting that file entirely also exempted it from the line above, so it
    # could have started hand-sourcing a library with this guard still green.
    [ -n "${2-}" ] && return 1
    grep -E '^[[:space:]]*unset[[:space:]]+-f[[:space:]]' <<<"$body" \
      | sed 's/[[:space:]]*[0-9]*>&\{0,1\}[^[:space:]]*//g; s/[[:space:]]*[|&][|&].*//; s/[[:space:]]*$//' \
      | grep -qvE '^[[:space:]]*unset[[:space:]]+-f[[:space:]]+rb_load$' \
        && return 0
    return 1
}

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
    # NO SYMBOL LIST AT ALL, and no parsing of the libraries to build one. That
    # was a `sed` over their function declarations, and it would silently omit
    # `rb_new () {` or a brace on the next line — both legal — while the other
    # libraries kept the alternation non-empty, so a caller could hand-clear the
    # omitted name with the guard still green. The rule does not need to know the
    # names: a runtime script clears exactly ONE function by hand, `rb_load`, and
    # any other `unset -f` is the copied loading rule.
    #
    # THE PATTERN STAYS IN SINGLE QUOTES, with the derived names spliced in. The
    # first version put the whole thing in double quotes so the variables would
    # expand — and `\$_RB_SELF_DIR` then reached `grep` as `$_RB_SELF_DIR`, where
    # `$` is an end-of-line anchor. The pattern matched NOTHING, both fixtures
    # below passed, and the guard reported an invariant it no longer had.
    # THE EXEMPTION IS THE WHOLE COMMAND, NOT A SUBSTRING OF IT. `grep -v` drops a
    # LINE that contains the pattern, so `unset -f rb_load rb_elapsed` was exempted
    # by the `rb_load` in it while clearing a library symbol beside it — the copied
    # loading rule walking back in through the allowance written for the bootstrap.
    # The trailing noise is stripped and the remainder must be exactly the
    # bootstrap clear.
    # WHITESPACE IS `[[:space:]]+`, NOT A SINGLE SPACE. `unset  -f rb_elapsed` and a
    # tab after `-f` are both legal, and the detector matched neither — so it
    # emitted no line at all, the inverted grep received empty input, and the guard
    # reported that no copied loading rule existed. A check that finds nothing and
    # a check that finds nothing wrong are the same output.
    # `&& _hl=0 || _hl=$?`, NOT `; _hl=$?`. Under `set -e` a bare call that returns
    # non-zero aborts the file before the status can be read — and returning 1 is
    # what a CLEAN script does here, so the whole loop died on the first one.
    rb_hand_loads "$ROOT/$sc" && _hl=0 || _hl=$?
    case "$_hl" in
        0) echo "FAIL - $sc has its own copy of the loading rule again"; idfail=1 ;;
        1) echo "ok   - …and carries no second copy of the loading rule" ;;
        *) echo "FAIL - $sc could not be read by the loading-rule scan"; idfail=1 ;;
    esac
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
    if [ "$bs_rc" -eq "$(id_rc "$sc")" ] && grep -q 'reason=loadlib_empty' <<<"$bs_out"; then
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
        pr-request-review.sh) bs_want='ABORT:' ;;
        pr-signoff.sh) bs_want='PR_SIGNOFF status=error' ;;
        pr-phase-state.sh) bs_want='PR_PHASE status=error' ;;
        *) bs_want='PR_CI_STATE status=error' ;;
    esac
    if grep -qF "$bs_want" <<<"$bs_out"; then
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
    if grep -q 'PR_REVIEW_READY' <<<"$bs_out"; then
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
            if grep -qE 'reason=origin_(has_no_host|transport_unsupported)' <<<"$out"; then
                echo "FAIL - $sc rejected a valid remote as $label (out='$out')"; idfail=1
            else
                echo "ok   - $sc accepts $label"
            fi
            continue
        fi
        if [ "$rc" -eq "$(id_rc "$sc")" ] && grep -q "reason=$want" <<<"$out"; then
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
# ── AND NO RUNTIME SCRIPT WRITES THE LOADING SEQUENCE OUT BY HAND ──────────
# The loop above names five scripts because it asks an identity question. This
# one asks the universal one, so it runs over every runtime script — ten of them,
# where the five were chosen when only five loaded a library. `pr-ci-gate.sh` has
# loaded `recordlib.sh` for far longer than that and was inspected by nothing,
# and `pr-merge-gate.sh`, `pr-close-round.sh`, `pr-copilot-phase.sh` and
# `pr-signoff.sh` likewise. Issue #67.
#
# DERIVED FROM THE TREE, and with no prefilter: a script that replaced EVERY
# `rb_load` with a hand-written sequence would otherwise be skipped for having no
# loader call, the guard disappearing along with the thing it requires.
for sc in "$ROOT"/pr-*.sh; do
    [ -f "$sc" ] || continue
    _n="$(basename "$sc")"
    # TWO NARROWED EXEMPTIONS, NAMED AND EXPLAINED. `pr-selfcheck.sh` clears every
    # inherited function on purpose — it re-execs into a clean shell and then
    # removes what a startup hook may have left, which is the opposite of copying a
    # loading rule, and `test-pr-selfcheck.sh` covers that block.
    #
    # `pr-origin.sh` is exempt for a different reason and does no clearing at all:
    # the caller starts it with `/usr/bin/env bash -p`, so no function is imported
    # from the environment in the first place. It also loads no library, by design
    # — it is the one helper the driving shell reaches before anything else is
    # trusted, so it depends on nothing it would have to verify.
    #
    # Only the CLEARS are excused. Skipping either file entirely would excuse its
    # hand-SOURCING too, so it could begin loading a library by hand with this
    # guard still reporting that every runtime script goes through the loader.
    _only=""
    case "$_n" in pr-selfcheck.sh|pr-origin.sh) _only=sources-only ;; esac
    rb_hand_loads "$sc" "$_only" && _hl=0 || _hl=$?
    case "$_hl" in
        0) echo "FAIL - $_n has its own copy of the loading rule again"; idfail=1 ;;
        1) echo "ok   - $_n loads its libraries through the shared loader alone" ;;
        *) echo "FAIL - $_n could not be read by the loading-rule scan"; idfail=1 ;;
    esac
done

# ── THE SCAN ITSELF, ON THE TWO CASES THE LOOP CANNOT STAGE ────────────────
# A file the scan cannot open must be reported, not approved: `grep` answers 1
# for "no match" and 2 for "could not read", and both fell into the clean branch.
# This cannot be staged through the loop above, which walks the real tree.
HLTMP="$(mktemp_d)" || { echo "FAIL - could not create a scratch directory"; idfail=1; HLTMP=""; }
if [ -n "$HLTMP" ]; then
    printf '#!/usr/bin/env bash\n: \n' > "$HLTMP/unreadable.sh"
    chmod 000 "$HLTMP/unreadable.sh"
    if cat "$HLTMP/unreadable.sh" >/dev/null 2>&1; then
        # Running as root, or on a filesystem that ignores the mode: the case
        # would assert nothing, so it says so rather than passing.
        echo "ok   - …(unreadable-file case skipped: this user can read mode 000)"
    else
        rb_hand_loads "$HLTMP/unreadable.sh" && _hl=0 || _hl=$?
        [ "$_hl" -eq 2 ] \
            && echo "ok   - a file the scan cannot read is refused, not called clean" \
            || { echo "FAIL - an unreadable file scanned as $_hl, not 2"; idfail=1; }
    fi
    # …AND THE NARROWED EXEMPTION IS NARROW. `pr-selfcheck.sh` is excused its
    # deliberate function clears and nothing else, so a hand-SOURCE there is still
    # a violation — excusing the whole file excused this too.
    printf '#!/usr/bin/env bash\nunset -f something 2>/dev/null\n. "$_RB_SELF_DIR/recordlib.sh"\n' \
        > "$HLTMP/both.sh"
    rb_hand_loads "$HLTMP/both.sh" sources-only && _hl=0 || _hl=$?
    [ "$_hl" -eq 0 ] \
        && echo "ok   - the clears-only exemption still reports a hand-sourced library" \
        || { echo "FAIL - a hand-source was excused along with the clears ($_hl)"; idfail=1; }
    # …while the clears alone are excused, which is what the exemption is for.
    printf '#!/usr/bin/env bash\nunset -f something 2>/dev/null\n' > "$HLTMP/clears.sh"
    rb_hand_loads "$HLTMP/clears.sh" sources-only && _hl=0 || _hl=$?
    [ "$_hl" -eq 1 ] \
        && echo "ok   - …and excuses the deliberate clears it exists for" \
        || { echo "FAIL - the exemption did not excuse a bare function clear ($_hl)"; idfail=1; }
    rm -rf "$HLTMP"
fi

# ── THE INVARIANT ITSELF, RUN RATHER THAN READ ─────────────────────────────
# Two things have to hold, and neither is a pattern.
#
# THAT `rb_load` DID THE LOAD. A COMPLETE copy of the loading rule — clear,
# source, verify, report — refuses an empty library exactly as `rb_load` does, so
# an outcome-only check calls it compliant while the caller has reimplemented the
# loader and is free to drift from it. `loadlib.sh` is replaced by one that
# records each library it is asked for and then delegates, so what is asserted is
# that the shared loader was USED, not that something behaved like it.
#
# AND THAT AN EMPTY LIBRARY IS REFUSED, with the status each caller's consumer
# actually branches on: `pr-watch.sh` exits 2 for an unreadable state, because 1
# means an ordinary timeout and the driver RE-ARMS it — a clock that cannot be
# read would become an indefinite watch loop — and the gate exits 1, which is its
# contract for refusing a round.
CLKTMP="$(mktemp_d)" || { echo "FAIL - could not create a scratch directory"; idfail=1; CLKTMP=""; }
if [ -n "$CLKTMP" ]; then
    mkdir -p "$CLKTMP/run"
    for g in "$ROOT"/*.sh; do ln -sf "$g" "$CLKTMP/run/$(basename "$g")"; done
    rm -f "$CLKTMP/run/clocklib.sh"; : > "$CLKTMP/run/clocklib.sh"
    rm -f "$CLKTMP/run/loadlib.sh"
    cat > "$CLKTMP/run/loadlib.sh" <<'SPY'
. "$RB_REAL_LOADLIB" || return 1
eval "rb_real_load() $(declare -f rb_load | sed '1d')"
rb_load() { printf '%s\n' "$2" >> "$RB_LOAD_SPY"; rb_real_load "$@"; }
SPY
    for sc in pr-watch.sh:2 pr-ci-gate.sh:1; do
        _n="${sc%%:*}"; _want="${sc##*:}"
        [ -f "$ROOT/$_n" ] || continue
        : > "$CLKTMP/spy"
        # `|| rc=$?`, NOT `; rc=$?`. Under `set -e` a failing command substitution
        # inside an assignment aborts the fixture before the status can be read —
        # and refusing is what a correct run does here, so the whole block printed
        # nothing at all until this was found by running it.
        rc=0
        out="$(run_limited 20 env RB_REAL_LOADLIB="$ROOT/loadlib.sh" RB_LOAD_SPY="$CLKTMP/spy" \
                 REVIEW_BUS_REMOTE='git@github.com:o/r.git' \
                 bash -c 'rb_elapsed() { RB_ELAPSED=0; }
                          export -f rb_elapsed
                          exec "$1" 7 0123456789abcdef0123456789abcdef01234567' \
                 _ "$CLKTMP/run/$_n" 2>&1)" || rc=$?
        if grep -qx clocklib "$CLKTMP/spy" 2>/dev/null; then
            echo "ok   - $_n loads the clock through rb_load itself, not through a copy of it"
        else
            echo "FAIL - $_n never asked rb_load for clocklib (spy: $(tr '\n' ' ' < "$CLKTMP/spy"))"; idfail=1
        fi
        if [ "$rc" = "$_want" ] && grep -q 'clocklib_empty' <<<"$out"; then
            echo "ok   - …and refuses an empty clocklib with rc=$_want, even with rb_elapsed defined"
        else
            echo "FAIL - $_n gave rc=$rc for an empty clocklib (wanted $_want) out='$out'"; idfail=1
        fi
    done
    # …AND A HOSTILE STARTUP HOOK NO LONGER REACHES THE CALLERS AT ALL. This
    # block used to assert the opposite — that a `BASH_ENV` hook leaving
    # `RB_ELAPSED` readonly produced each caller's documented clock refusal
    # rather than a bare non-zero status. That was the best available answer
    # while the callers ran through `#!/usr/bin/env bash`, which SOURCES
    # `BASH_ENV`.
    #
    # They start privileged now, so the hook is never sourced and there is no
    # refusal to report: the caller runs its ordinary path and fails for its own
    # reason further down. What is asserted is therefore the ABSENCE of the clock
    # refusal — together with the concrete outcome, because absence alone passes
    # against a run that never started.
    # TWO HOOKS: the plain one, and the one that also FORGES the inspection. A
    # first fix asked `declare` whether these names were plain, and a hook that
    # defines `declare` answers yes for everything — after which the assignment is
    # fatal exactly as before. The forged case is the discriminating one, so it is
    # here rather than left as a shape nobody runs.
    printf 'RB_HOOK_RAN=yes\nreadonly RB_ELAPSED=0\n' > "$CLKTMP/hook.sh"
    printf 'RB_HOOK_RAN=yes\ndeclare() { printf "declare -- %%s\\n" "$2"; }\nreadonly RB_ELAPSED=0\n' \
        > "$CLKTMP/hook-forged.sh"
    # …and the alias BETWEEN two state variables, which no same-value check sees.
    #
    # ONLY WHERE THE SHELL HAS NAMEREFS. `declare -n` is Bash 4.3+, and the macOS
    # job runs this suite on 3.2, where the hook itself fails with `invalid
    # option` — so nothing is aliased, the caller proceeds, and the case fails on
    # whatever it does next. That is the shape this job exists to catch, and it
    # caught it: the unit case was guarded by version and this one was not.
    _hooks="hook hook-forged"
    if [ "${BASH_VERSINFO[0]:-0}" -gt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 3 ]; }; then
        printf 'RB_HOOK_RAN=yes\ndeclare -n RB_CLOCK_T0=RB_CLOCK_LAST\n' > "$CLKTMP/hook-alias.sh"
        _hooks="$_hooks hook-alias"
    else
        echo "ok   - …(alias hook skipped: Bash ${BASH_VERSINFO[0]:-?}.${BASH_VERSINFO[1]:-?} has no declare -n)"
    fi
    # A `gh` THAT ALWAYS FAILS, so these runs cannot reach the network. See the
    # loop below for why that became necessary with this change.
    mkdir -p "$CLKTMP/bin"
    printf '#!/usr/bin/env bash\nprintf "gh: stubbed\\n" >&2\nexit 1\n' > "$CLKTMP/bin/gh"
    chmod +x "$CLKTMP/bin/gh"
    # The real library AND the real loader: the spy above replaced both, and this
    # case is about the clock refusing rather than about who loaded it.
    ln -sf "$ROOT/clocklib.sh" "$CLKTMP/run/clocklib.sh"
    ln -sf "$ROOT/loadlib.sh" "$CLKTMP/run/loadlib.sh"
    for _hook in $_hooks; do
        # THE HOOK'S OWN REACH FIRST. Every hook file also sets a marker, so this
        # asks an ORDINARY shell whether the file still lands — without it, a hook
        # that had stopped working for some unrelated reason would make every case
        # below pass while proving nothing.
        _reach="$(run_limited 20 env BASH_ENV="$CLKTMP/$_hook.sh" \
                    bash -c 'printf %s "${RB_HOOK_RAN-no}"' 2>/dev/null)"
        if [ "$_reach" = yes ]; then
            echo "ok   - the $_hook file is still sourced by an ordinary shell"
        else
            echo "FAIL - the $_hook file no longer runs anywhere (marker='$_reach'); the cases below prove nothing"
            idfail=1
        fi
        for sc in pr-watch.sh:clock_unreadable pr-ci-gate.sh:"could not read the clock"; do
            _n="${sc%%:*}"; _say="${sc#*:}"
            [ -f "$ROOT/$_n" ] || continue
            rc=0
            # `gh` IS STUBBED, and that is not tidiness. These callers used to die
            # in the clock before reaching any API call; now that the hook never
            # lands they run their ORDINARY path, which on a contributor's machine
            # with a working `gh` means real requests against `github.com/o/r` —
            # the mandatory pre-push gate reaching the network, and `pr-watch.sh`
            # sitting in its polling loop until the watchdog kills it. The stub
            # makes each one fail at a known point instead.
            out="$(run_limited 20 env PATH="$CLKTMP/bin:$PATH" BASH_ENV="$CLKTMP/$_hook.sh" \
                     REVIEW_BUS_REMOTE='git@github.com:o/r.git' \
                     "$CLKTMP/run/$_n" 7 0123456789abcdef0123456789abcdef01234567 2>&1)" || rc=$?
            # THE CONCRETE OUTCOME as well as the absence: the caller reached its
            # ordinary work and refused THERE — a non-zero status, a sentinel of
            # its own, and not the watchdog's 124 or 125. A run killed at the first
            # line, or one still polling when time ran out, satisfies an absence
            # check and nothing else.
            if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 125 ] \
                && ! grep -q "$_say" <<<"$out" \
                && grep -q 'status=error\|state=error' <<<"$out"; then
                echo "ok   - $_n runs past the $_hook file, which its shell never sources"
            else
                echo "FAIL - $_n was reached by $_hook (rc=$rc) out='$out'"; idfail=1
            fi
        done
    done
    rm -rf "$CLKTMP"
fi

# ── EVERY RUNTIME HELPER IS STARTED PRIVILEGED ─────────────────────────────
#
# This is the contract that retires the shadowed-name class rather than answering
# it one name at a time. An ordinary `#!/usr/bin/env bash` sources `BASH_ENV`,
# imports functions from the environment and honours an exported `SHELLOPTS`, so
# every builtin a helper uses is a name the operator's shell can replace — `type`,
# `return`, `set`, `echo` and `exit` were each found that way, one per review
# round. `env -S bash -p` does none of the three.
#
# `pr-selfcheck.sh` IS EXEMPT AND IS ASSERTED TO BE. It is run by a person, not by
# the driver, and it already re-execs into a clean shell and clears every
# inherited function — a guarantee it makes for the whole suite and that this
# would duplicate rather than strengthen.
set +e
priv_missing=""
for f in "$ROOT"/pr-*.sh; do
    _b="$(basename "$f")"
    [ "$_b" = pr-selfcheck.sh ] && continue
    # `pr-origin.sh` IS THE SECOND EXEMPTION, and a narrower one. It is not
    # executable at all, so a shebang is inert: nothing can start it except a
    # caller naming an interpreter, and the documented caller names
    # `/usr/bin/env bash -p`. A privileged shebang there would state a protection
    # the file does not rely on and cannot enforce. Both halves are asserted
    # below, so the exemption cannot quietly become a hole.
    [ "$_b" = pr-origin.sh ] && continue
    # THE READ'S STATUS IS TAKEN, not only its output. A `head` that emits the
    # line and then fails would otherwise leave the match standing on a partial
    # read; an unreadable file is recorded as missing rather than as satisfied.
    _sb=""; _sb="$(head -n 1 "$f")" || _sb=""
    grep -qxF '#!/usr/bin/env -S bash -p' <<<"$_sb" \
        || priv_missing="$priv_missing $_b"
done
if [ -f "$ROOT/pr-origin.sh" ]; then
    [ ! -x "$ROOT/pr-origin.sh" ] \
        && echo "ok   - …and pr-origin.sh is not executable, so only a named interpreter starts it" \
        || { echo "FAIL - pr-origin.sh is executable; its shebang would become the entry point"; idfail=1; }
    _po_out="$(run_limited 20 env REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        bash "$ROOT/pr-origin.sh" read /dev/null 2>&1)"; _po_rc=$?
    { [ "$_po_rc" -ne 0 ] && grep -q 'not privileged' <<<"$_po_out"; } \
        && echo "ok   - …and it refuses an unprivileged interpreter by name" \
        || { echo "FAIL - pr-origin.sh ran unprivileged (rc=$_po_rc out='$_po_out')"; idfail=1; }
fi
[ -z "$priv_missing" ] \
    && echo "ok   - every runtime helper asks for a privileged interpreter" \
    || { echo "FAIL - helper(s) without a privileged shebang:$priv_missing"; idfail=1; }
# …AND NO HELPER CALLS ANOTHER BY PATHNAME ALONE. A nested call that reaches a
# helper by path leaves the kernel to process its shebang, which needs `env -S` —
# the requirement the driver's own invocation exists so users do not have. The
# gate, the round close, the phase, the merge gate and the watch all call one
# another, so this is not a corner: a bare call would make the plugin depend on
# `-S` again through the back door.
nested_bare=""
for f in "$ROOT"/pr-*.sh; do
    _b="$(basename "$f")"
    [ "$_b" = pr-selfcheck.sh ] && continue
    while IFS= read -r _l; do
        # An empty line is what a `grep` with no matches leaves in the heredoc,
        # and taking it as a finding reported every helper as bare.
        [ -n "$_l" ] || continue
        case "$_l" in
            *'/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-'*|*'/usr/bin/env bash -p "$STATE_SCRIPT"'*) ;;
            *) nested_bare="$nested_bare
$_b: $_l" ;;
        esac
    done <<EOF
$(grep -E '"\$_RB_SELF_DIR"/pr-[a-z-]+\.sh|probe "\$rem" "\$STATE_SCRIPT"' "$f" | grep -v '^#' || true)
EOF
done
[ -z "$nested_bare" ] \
    && echo "ok   - …and no helper calls another by pathname alone" \
    || { echo "FAIL - nested call(s) not started privileged:$nested_bare"; idfail=1; }
_sb=""; _sb="$(head -n 1 "$ROOT/pr-selfcheck.sh")" || _sb=""
grep -qxF '#!/usr/bin/env bash' <<<"$_sb" \
    && echo "ok   - …and pr-selfcheck.sh is the stated exception, which re-execs its own way" \
    || { echo "FAIL - pr-selfcheck.sh's shebang changed; its exemption is no longer what it says"; idfail=1; }
# AND IT IS TRUE AT RUNTIME, not only in the text. A shebang that a platform's
# `env` cannot honour would leave every helper unprotected while this file stayed
# green, so one is executed and asked what flags it actually got.
# IN A SCRATCH DIRECTORY OF ITS OWN. Written to a fixed path in the checkout, this
# removed whatever was already at that name — before writing and again after — so
# a contributor with an untracked file there lost it to the mandatory pre-push
# gate, and two concurrent runs overwrote each other.
PRVTMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
priv_probe="$PRVTMP/probe.sh"
{ head -n 1 "$ROOT/pr-review-state.sh"; printf 'printf "%%s" "$-"\n'; } > "$priv_probe"
chmod +x "$priv_probe"
priv_flags="$(run_limited 20 env 'BASH_FUNC_echo%%=() { :; }' "$priv_probe" 2>/dev/null)"
rm -rf "$PRVTMP"
# REPORTED, NOT REQUIRED, because this is the FALLBACK path. The driver starts
# every helper with `/usr/bin/env bash -p`, which needs no `-S`; the shebang
# covers direct execution and does need it. On a platform whose `env` predates
# `-S` the plugin still works and this probe does not, so the case says which
# happened rather than turning red on a machine the driver is fine on.
case "$priv_flags" in
    *p*) echo "ok   - …and that shebang really starts a privileged shell here" ;;
    *)   echo "ok   - …(this env has no -S; direct execution is unavailable, the driver's own invocation is not)" ;;
esac
# …AND A HELPER RUN THROUGH AN UNPRIVILEGED INTERPRETER REFUSES, which is what
# stops `bash pr-x.sh` being a silent downgrade past the shebang.
# EVERY GUARDED HELPER, not the identity callers. `ID_CALLERS` is a list about
# something else, and it omits `pr-ci-gate.sh` and `pr-merge-range.sh` — so their
# refusals had only their shebangs asserted, and removing a guard or giving it the
# wrong sentinel would have left this green.
for sc in $ID_CALLERS pr-watch.sh pr-ci-gate.sh pr-merge-range.sh; do
    [ -f "$ROOT/$sc" ] || continue
    id_args "$sc"; set -- "${ID_ARGV[@]}"
    up_out="$(run_limited 20 env REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        bash "$ROOT/$sc" "$@" 2>&1)"; up_rc=$?
    # THE DOCUMENTED STATUS AS WELL AS THE REASON: a helper refusing with somebody
    # else's exit code is a caller branching on the wrong thing.
    if [ "$up_rc" = "$(id_rc "$sc")" ] && grep -q 'reason=not_privileged' <<<"$up_out"; then
        echo "ok   - $sc refuses an unprivileged interpreter by name and status"
    else
        echo "FAIL - $sc ran unprivileged or refused wrongly (rc=$up_rc want=$(id_rc "$sc") out='$up_out')"; idfail=1
    fi
done
# …AND THE CLASS IS ACTUALLY DEAD, which is the point of the whole change. Five
# forged builtins at once, each of which took a review round to answer
# individually: `echo` swallowed the sentinel, `set` made `set +e` a no-op, `exit`
# made refusals non-terminal, `type` made a good library abort, `return` made a
# refusing stub succeed. Under a privileged interpreter none of them is imported.
# THE IDENTITY IS SUPPLIED, like every helper probe above it. Line 29 clears the
# session's `REVIEW_BUS_REMOTE` on purpose, so without one here this probe reaches
# `rb_identity` before the usage error it expects — and in a checkout with no
# parseable GitHub origin it would report that a forged builtin got through when
# privileged startup had worked correctly.
class_out="$(run_limited 20 env \
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    'BASH_FUNC_echo%%=() { :; }' \
    'BASH_FUNC_set%%=() { :; }' \
    'BASH_FUNC_exit%%=() { return 0; }' \
    'BASH_FUNC_type%%=() { return 1; }' \
    'BASH_FUNC_return%%=() { :; }' \
    "$ROOT/pr-review-state.sh" 2>&1)"; class_rc=$?
{ [ "$class_rc" -ne 0 ] && grep -q 'usage:' <<<"$class_out"; } \
    && pass_priv=1 || pass_priv=0
[ "$pass_priv" = 1 ] \
    && echo "ok   - five forged builtins at once do not reach a helper" \
    || { echo "FAIL - a forged builtin reached the helper (rc=$class_rc out='$class_out')"; idfail=1; }
# THE FIXTURE'S OWN REACH: the same environment must still land on an ordinary
# interpreter, or this proves nothing about privileged mode.
class_reach="$(run_limited 20 env 'BASH_FUNC_echo%%=() { :; }' \
    bash -c 'echo SHOULD-NOT-APPEAR; printf %s "$(type -t echo)"' 2>/dev/null)"
[ "$class_reach" = function ] \
    && echo "…and the same forgery does reach an ordinary one" \
    || { echo "FAIL - the forgery does not land anywhere (got '$class_reach'); the case above proves nothing"; idfail=1; }
set -e

# ── THE LOADER IS VERIFIED BY USING IT, NOT BY ASKING `type` ───────────────
#
# #88: the preflight asked `type -t rb_load` and took the answer as proof. The
# first load is the verification now, and two states have to hold for that to be
# worth anything — an empty library must still be NAMED, and `PATH` must not be
# able to answer in the library's place.
set +e
LDTMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
mkdir -p "$LDTMP/bin" "$LDTMP/run"
printf '#!/usr/bin/env bash\nexit 1\n' > "$LDTMP/bin/gh"
chmod +x "$LDTMP/bin/gh"
for g in "$ROOT"/*.sh; do ln -sf "$g" "$LDTMP/run/$(basename "$g")"; done
rm -f "$LDTMP/run/loadlib.sh"; : > "$LDTMP/run/loadlib.sh"
for sc in $ID_CALLERS pr-watch.sh pr-ci-gate.sh; do
    [ -f "$ROOT/$sc" ] || continue
    id_args "$sc"; set -- "${ID_ARGV[@]}"
    ld_out="$(run_limited 20 env PATH="$LDTMP/bin:$PATH" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        "$LDTMP/run/$sc" "$@" 2>"$LDTMP/err")"; ld_rc=$?
    ld_err="$(cat "$LDTMP/err")"
    # ON ITS OWN STREAM. Read together, a sentinel written to the wrong one still
    # matched — and the consumer reading the documented stream would have got
    # nothing at all.
    if [ "$(id_stream "$sc")" = out ]; then ld_said="$ld_out"; else ld_said="$ld_err"; fi
    if [ "$ld_rc" = "$(id_rc "$sc")" ] && grep -q 'reason=loadlib_empty' <<<"$ld_said"; then
        echo "ok   - $sc names an empty loader on its documented stream, with no preflight"
    else
        echo "FAIL - $sc did not name an empty loader on $(id_stream "$sc") (rc=$ld_rc want=$(id_rc "$sc") out='$ld_out' err='$ld_err')"; idfail=1
    fi
done
# …AND AN `rb_load` ON `PATH` CANNOT ANSWER IN THE LIBRARY'S PLACE. Privileged
# startup keeps functions out; it does not change `PATH`, so without the refusing
# stub an undefined `rb_load` would be looked up there — and an executable by that
# name exiting 0 reports every load successful with nothing cleared and no library
# sourced. The forger is an executable for exactly that reason.
printf '#!/usr/bin/env bash\nexit 0\n' > "$LDTMP/bin/rb_load"
chmod +x "$LDTMP/bin/rb_load"
ld_probe="$(run_limited 20 env PATH="$LDTMP/bin:$PATH" bash -c 'rb_load && echo REACHED' 2>/dev/null)"
if [ "$ld_probe" = REACHED ]; then
    echo "ok   - an rb_load on PATH is reachable at all"
else
    echo "FAIL - the PATH forger does not run (probe='$ld_probe'); the cases below prove nothing"
    idfail=1
fi
for sc in $ID_CALLERS pr-watch.sh pr-ci-gate.sh; do
    [ -f "$ROOT/$sc" ] || continue
    id_args "$sc"; set -- "${ID_ARGV[@]}"
    ld_out="$(run_limited 20 env PATH="$LDTMP/bin:$PATH" \
        REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        "$LDTMP/run/$sc" "$@" 2>"$LDTMP/err")"; ld_rc=$?
    ld_err="$(cat "$LDTMP/err")"
    if [ "$(id_stream "$sc")" = out ]; then ld_said="$ld_out"; else ld_said="$ld_err"; fi
    if [ "$ld_rc" = "$(id_rc "$sc")" ] && grep -q 'reason=loadlib_empty' <<<"$ld_said"; then
        echo "ok   - $sc refuses an empty loader with an rb_load on PATH"
    else
        echo "FAIL - $sc took its loader from PATH (rc=$ld_rc out='$ld_out' err='$ld_err')"; idfail=1
    fi
done
rm -rf "$LDTMP"
# …AND THE PREFLIGHT CANNOT COME BACK, which needs a STRUCTURAL check because no
# behaviour separates the two. Under a privileged interpreter a forged `type`
# cannot be imported, so `[ "$(type -t rb_load)" = function ]` and the stub give
# the same answer in every state this suite can build: with a good library both
# proceed, with an empty one both refuse, and with an `rb_load` executable on
# `PATH` the preflight sees `file` where the stub returns 127 — the same
# `loadlib_empty` either way. Restoring the dependency this PR removes would
# therefore leave both loops above green.
#
# What is left to assert is the SHAPE, which is what #88 is about: the loader is
# verified by being used, not by being asked about.
pre_back=""; stub_missing=""
for f in "$ROOT"/pr-*.sh; do
    _b="$(basename "$f")"
    grep -q '^\. "\$_RB_SELF_DIR/loadlib\.sh"' "$f" || continue
    grep -q 'type -t rb_load' <<EOF && pre_back="$pre_back $_b"
$(grep -v '^#' "$f")
EOF
    grep -qxF 'rb_load() { return 127; }' "$f" || stub_missing="$stub_missing $_b"
done
[ -z "$pre_back" ] \
    && echo "ok   - no helper verifies the loader by asking type" \
    || { echo "FAIL - the type preflight is back in:$pre_back"; idfail=1; }
[ -z "$stub_missing" ] \
    && echo "ok   - …and every one defines the refusing stub instead" \
    || { echo "FAIL - helper(s) without the refusing stub:$stub_missing"; idfail=1; }
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

# ── …AND THE SCAN CAN STILL SEE ONE ───────────────────────────────────────
# The check above asserts an ABSENCE, so a pattern that matches nothing reports
# the invariant holding without having tested it — the shape this repository calls
# worse than no check. Nothing exercised it until the pattern was generalised away
# from a list of project names, at which point there was no way to tell a wider
# pattern from a broken one.
#
# ONE STAGED FILE PER SHAPE the pattern claims to catch, including this
# repository's own slug: an installed copy serves every project, so a slug baked
# into a script sends another project's reviews here.
pat_probe_dir="$(mktemp -d)" || { echo "FAIL - no scratch dir for the identity-scan control"; echo "RESULT: FAIL"; exit 1; }
pat_probe_fail=0
for _pp in 'x=p5ych0/some-other-repo' \
           'x=p5ych0/watch-pr-skill' \
           'x=p5ych0-some-other-repo' \
           'gh api -f owner=p5ych0' \
           'd=/tmp/p5ych0-x-review-bus' \
           'gh api -f repo=$'"'"'p5ych0-x'"'"'' \
           '# a comment naming owner=p5ych0' \
           '# this only ever worked for p5ych0'; do
    printf '%s\n' "$_pp" > "$pat_probe_dir/probe.sh"
    if grep -qE "$PAT" "$pat_probe_dir/probe.sh"; then
        echo "ok   - the identity scan still catches: $_pp"
    else
        echo "FAIL - the identity scan does not catch '$_pp'; its absence above proves nothing"
        pat_probe_fail=1
    fi
done
# …AND LEGAL CODE IS LEFT ALONE. Every one of these was produced by a review round
# against the pattern language this replaced: an arm too WIDE blocks the self-check
# on code that hard-codes nothing, which is the same defect as one too narrow. They
# stay because a future arm would reintroduce exactly them.
for _pn in 'gh api -f repo="$REPO"' \
           'repo=$REPO' \
           'owner=$OWNER' \
           'u="repos/$OWNER/$REPO/commits"' \
           'case "$c" in *" --repo="*) ;; esac' \
           'case "$a" in --repo=[A-Za-z]*) ;; esac' \
           'case "$a" in --repo=+([A-Za-z])*) ;; esac' \
           'gh api -f repo=.github' \
           'gh api -f repo=123' \
           'REVIEW_BUS_REMOTE=x' \
           'DISABLE_REVIEW_BUS=1' \
           'CODEX_REVIEW_BUS=x' \
           'ls -dt "$HOME"/.claude/plugins/cache/*/watch-pr-skill/*/skills'; do
    printf '%s\n' "$_pn" > "$pat_probe_dir/probe.sh"
    if grep -qE "$PAT" "$pat_probe_dir/probe.sh"; then
        echo "FAIL - the identity scan flags legal code: '$_pn'"
        pat_probe_fail=1
    else
        echo "ok   - …and does not flag: $_pn"
    fi
done
rm -rf "$pat_probe_dir"
[ "$pat_probe_fail" -eq 0 ] || { echo "RESULT: FAIL"; exit 1; }

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
if [ "$frc" -eq 0 ] && grep -q 'pr-offender.sh' <<<"$found" \
   && grep -q 'pr-mixed.sh' <<<"$found"; then
    echo "ok   - …and a script that does hard-code one is caught, even beside \$OWNER/\$REPO"
else
    echo "FAIL - a hard-coded REPO_SLUG was not caught (rc=$frc out='$found')"
    rm -rf "$UNREAD"; echo "RESULT: FAIL"; exit 1
fi
rm -rf "$UNREAD"
set -e
echo "RESULT: PASS"
