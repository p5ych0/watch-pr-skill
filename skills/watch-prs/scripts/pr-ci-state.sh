#!/usr/bin/env -S bash -p
# Are this PR's checks green on the head that was just pushed?
#
#   pr-ci-state.sh <pr> [--required]
#
#   pr-ci-state.sh <pr> [--required] [--head <oid>]
#
#   0  green    — every check considered passed
#   1  failed   — at least one failed or was cancelled
#   3  pending  — at least one is still running and none has failed
#   4  none     — no checks are configured; there is nothing to be green
#   5  stale    — the PR head is not the OID asked about; ask again shortly
#   2  error    — could not be established; fail closed
#
# WHY THIS EXISTS
#
# CI was red for four consecutive commits on PR #14 and neither the round loop nor
# the pre-push self-check noticed. Every one of those rounds was closed as green on
# the strength of a local suite run, and the operator had to point at the checks
# tab. `pr-selfcheck.sh` runs the suite HERE, before the push; it cannot see a
# failure that only happens on the runner — and that one only happened there,
# because GitHub Actions ignores SIGPIPE, so a `printf` losing a pipe race returned
# 1 instead of dying with 141.
#
# "the suite passes here" and "the checks pass there" are different claims, and
# only the first was ever made. Issue #16.
#
# NOT A SECOND COPY. The merge gate already asked this question, in about seventy
# lines inline in `SKILL.md`. Writing them out again for the round loop is the
# defect issues #11 and #18 were both opened for, so the gate calls this too and
# `--required` is what separates the two questions: the merge gate asks whether
# branch protection is satisfied, and the round loop asks whether the commit it
# just pushed is broken — a failing non-required check is still a broken push.
#
# `set -uo pipefail`, NOT `-e`: `gh` probes fail as normal operation and the
# result is control flow. See CLAUDE.md § Bash conventions.
# ── STARTED PRIVILEGED, OR NOT STARTED ─────────────────────────────────────
#
# The shebang above is `env -S bash -p`, and that is the defence this block
# exists to state. An ordinary `#!/usr/bin/env bash` SOURCES `BASH_ENV`, IMPORTS
# functions from the environment, and honours an exported `SHELLOPTS` — so every
# builtin this script uses is a name the operator's shell can replace, and each
# one found took a review round of its own: `type`, `return`, `set`, `echo`,
# `exit`. Privileged mode does none of the three, so there is nothing to shadow
# and nothing to clear. Measured: under `BASH_FUNC_echo%` and `BASH_FUNC_set%`,
# a privileged shell reports both as builtins.
#
# THE HOOK CANNOT BE OUT-RUN FROM IN HERE, which is why this is the shebang and
# not a re-exec. A `BASH_ENV` hook runs before this file's first line, and one
# that prints a forged `PR_CI_STATE status=error` line and exits has already answered the
# caller — no later re-exec takes that back. The interpreter has to be privileged
# from the start, which only the shebang or the caller can arrange.
#
# WHAT STARTS IT PRIVILEGED IS THE CALLER, AND THE SHEBANG IS THE FALLBACK.
# `SKILL.md` invokes every helper as `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-x.sh`,
# which starts a fresh privileged interpreter whatever the driving shell is and
# whatever that platform's `env` supports. The shebang covers the other way in —
# executing the file directly — and needs `env -S`, which is why it is not the
# thing relied on.
#
# `$-` IS A LAST-RESORT REFUSAL AND PROVES LESS THAN IT LOOKS. It reports the
# MODE this shell is in, not how it got there: run as `BASH_ENV=hook bash
# pr-x.sh`, the hook is sourced BEFORE this line and can itself run `set -p` and
# then define `echo` or `exit`, after which `$-` contains `p` and this test
# passes on a shell that has already executed hostile code. Nothing inside a
# script can detect work done before its first line — so this catches the honest
# mistake, and `bash pr-x.sh` is UNSUPPORTED rather than defended. Measured:
# `BASH_ENV=/tmp/h bash -c 'printf "%s %s" "$-" "$(type -t echo)"'` with a hook
# running `set -p; echo() { :; }` prints `hpBc function`.
if [[ $- != *p* ]]; then
    echo "PR_CI_STATE status=error reason=not_privileged" >&2
    exit 2
fi

set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "PR_CI_STATE status=error reason=lib_dir_unresolvable" >&2; exit 2; }
# The library loader — and it obeys its own rule. A helper cannot load the file
# that defines it, so this sequence is written out here; that asymmetry is
# irreducible, but it is not a licence to load the loader carelessly. An exported
# `rb_load` survives into this shell and an empty `loadlib.sh` still sources
# successfully, so without the clear the first load runs the INHERITED
# function — and a stale loader is the one thing that can make every OTHER load
# look clean. See loadlib.sh and issue #22.
unset -f rb_load 2>/dev/null || {
    echo "PR_CI_STATE status=error reason=loadlib_stale_definition" >&2; exit 2; }
# NO `type -t rb_load` PREFLIGHT. It verified the loader by asking `type`, which
# is a NAME — and while a privileged interpreter means no function by that name
# can be imported, verifying a thing by asking a second thing about it is the
# shape #88 is about: the answer is only as good as the asker. The FIRST LOAD is
# the verification instead: the stub below is what an empty `loadlib.sh` leaves
# behind, and calling it fails. Nothing is asked ABOUT the loader — the load
# itself is the answer.
#
# THE REFUSING STUB IS WHAT MAKES THAT TRUE. Without it, an `rb_load` that is not
# a function is looked up on `PATH` — privileged mode does not change `PATH` —
# and an executable by that name exiting 0 would report every load successful
# with nothing cleared and no library sourced. Defining it means the call cannot
# leave this shell: a good `loadlib.sh` replaces the stub when sourced, an empty
# one leaves the refusal. `return` is a builtin and nothing can shadow it here,
# because a privileged shell imports no functions. #88.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || {
    echo "PR_CI_STATE status=error reason=loadlib_unreadable" >&2; exit 2; }
# `run_limited` — the portable watchdog. A `gh` call that hangs on a dead
# connection never returns, and the caller's `PR_CI_TIMEOUT` is then not a bound at
# all: the round gate waits forever on a probe that is the thing being bounded.
# Stock macOS ships no GNU `timeout`, which is why this is a shared helper rather
# than a one-line wrapper.
#
# `testlib.sh` is the fixture watchdog by history and is a runtime dependency now.
# The alternative was a second copy of ninety lines that already exist and are
# already tested, which is the duplication issues #11 and #18 were opened for.
# THE FIRST LOAD CARRIES THE SENTINEL, because it is what the preflight used to
# say. An empty `loadlib.sh` leaves the stub, the stub returns 127, and without
# this arm the only trace is a bare exit status — the ordinary-looking empty
# answer `CLAUDE.md` forbids. 127 is the stub's and nothing else's: `rb_load`'s
# own refusals report their own reason and their own status.
rb_load "$_RB_SELF_DIR" testlib run_limited "PR_CI_STATE status=error" || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "PR_CI_STATE status=error reason=loadlib_empty" >&2
    exit 2; }
# `sha_reason` — one definition of "a full commit SHA" across the plugin, used
# below to validate both the OID asked about and the one the API returns.
rb_load "$_RB_SELF_DIR" recordlib sha_reason "PR_CI_STATE status=error" || exit 2
rb_load "$_RB_SELF_DIR" identitylib rb_identity "PR_CI_STATE status=error" || exit 2
rb_identity || {
    echo "PR_CI_STATE status=error reason=$RB_IDENTITY_REASON" >&2; exit 2; }

PR="${1:-}"
case "$PR" in
    ""|*[!0-9]*) echo "usage: $0 <pr> [--required] [--head <oid>]" >&2; exit 2 ;;
esac
shift
REQUIRED=""; WANT_HEAD=""; DEADLINE="${PR_CI_PROBE_TIMEOUT:-60}"
# A malformed bound falls back to the default rather than removing the watchdog:
# a typo must not turn a bounded probe into an unbounded one. Leading zeros are
# rejected because Bash reads them as octal in arithmetic.
case "$DEADLINE" in ""|0|0*|*[!0-9]*|??????*) DEADLINE=60 ;; esac
# ONE DEADLINE FOR THE WHOLE RUN, not one per call. This script makes up to three
# sequential requests, and giving each the full allowance meant a five-second
# budget could be spent three times over: a head lookup that took four seconds,
# then a checks request that hung for five, then a confirmation that hung for five
# more. The caller's bound is then not a bound at all.
_RB_T0=$SECONDS
# What is left — and NOTHING when the deadline has passed. Clamping an exhausted
# budget up to one second granted a fresh allowance to every remaining call, each
# of which can then take that second plus the watchdog's five-second escalation:
# the bound turned into a floor. An expired deadline is not a short deadline.
rb_left() {
    local left=$((DEADLINE - (SECONDS - _RB_T0)))
    [ "$left" -ge 1 ] || return 1
    printf '%s' "$left"
    return 0
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --required) REQUIRED="--required"; shift ;;
        --head)
            # A missing value is usage, not something to recover from: `shift 2`
            # on a one-element list leaves the flag consuming nothing and the
            # check silently unpinned.
            [ "$#" -ge 2 ] || { echo "usage: $0 <pr> [--required] [--head <oid>]" >&2; exit 2; }
            WANT_HEAD="$2"; shift 2 ;;
        *) echo "usage: $0 <pr> [--required] [--head <oid>]" >&2; exit 2 ;;
    esac
done
if [ -n "$WANT_HEAD" ]; then
    # THE HEAD IS CONFIRMED FIRST, and since #214 that confirmation means the same
    # thing for both questions: each is answered by a rollup addressed by this OID,
    # so the answer is bound and the confirmation only reports whether the head has
    # since moved. It used to be half of a bracket for `--required`, which went to
    # `gh pr checks` — a PR-addressed read whose answer carries no OID, so for a
    # moment after a push it described the commit from the round before and read as
    # permission to close.
    #
    # A MISMATCH IS ITS OWN VERDICT either way, rather than an error: the caller's
    # correct response is to wait, not to stop.
    _reason="$(sha_reason "$WANT_HEAD")" || {
        echo "PR_CI_STATE pr=$PR status=error reason=$_reason head=$WANT_HEAD" >&2; exit 2; }
    _left_head="$(rb_left)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=deadline_exhausted" >&2; exit 2; }
    HEAD_NOW="$(run_limited "$_left_head" gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" \
                  --json headRefOid --jq '.headRefOid' 2>/dev/null)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=head_unreadable" >&2; exit 2; }
    # Anything `gh` printed before failing is not data, and the shape is checked
    # rather than trusted: a partial read that happened to equal the wanted OID
    # would otherwise unpin the check it was added to pin.
    _reason="$(sha_reason "$HEAD_NOW")" || {
        echo "PR_CI_STATE pr=$PR status=error reason=$_reason head=$HEAD_NOW" >&2; exit 2; }
    if [ "$HEAD_NOW" != "$WANT_HEAD" ]; then
        echo "PR_CI_STATE pr=$PR status=stale head=$HEAD_NOW want=$WANT_HEAD"
        exit 5
    fi
fi
# The head is confirmed AGAIN after the checks are read, below. Confirming only
# before leaves a window: a push landing between the two calls means the checks
# describe a head nobody verified, and its first `none` inherits the grace the
# previous head had almost finished earning.

# "NONE CONFIGURED" IS NOT "COULD NOT TELL". `gh pr checks` exits NON-ZERO when
# there is nothing to report, saying so on stderr — not because anything failed.
# Treating every non-zero as unreadable blocked every repository without branch
# protection, permanently: not a fail-closed guard but a gate that never opens,
# and found by trying to merge rather than by reading the code.
#
# THE WHOLE DIAGNOSTIC IS MATCHED, not searched for a phrase. `gh` has no
# dedicated status for this case, so the message is the only signal, and a
# substring test accepted it inside a LARGER failure: a run that printed the
# benign line and then failed for an unrelated reason was classified as benign.
# Matching the entire message means an extra line, an extra sentence or a wrapped
# error all fall through to the blocking branch, which is the direction that
# cannot be wrong.
#
# Both wordings are accepted because `gh` drops "required" when the branch has no
# checks whatsoever, and both mean the same thing here: nothing to be green.
checks_msg_is_none_configured() {
    case "$1" in
        *"
"*) return 1 ;;                       # more than one line is more than one thing
    esac
    case "$1" in
        "no checks reported on the '"*"' branch"|"no required checks reported on the '"*"' branch")
            return 0 ;;
    esac
    return 1
}

# ── THE COMMIT-ADDRESSED READ, for the all-checks question ─────────────────
#
# `gh pr checks` is addressed by PULL REQUEST and its answer carries no OID, so
# bracketing it with head confirmations narrows when a head can move and never
# binds the answer to a commit. This rollup IS addressed by a commit: what it
# returns is about the OID it is asked for and nothing else.
#
# THE ALL-CHECKS QUESTION ONLY. `--required` also needs to know WHICH contexts the
# base branch requires, which this cannot say; `required_checks_verdict` below
# reads that separately and then asks this same rollup for the contexts.
#
# IT IS NOT A SUPERSET OF WHAT IS REQUIRED, and an earlier version of this comment
# claimed it was. These endpoints report the checks that EXIST on the commit; a
# required context that has not reported has neither a check run nor a status, so
# this answer can be green while a requirement is unmet. What binding buys is that
# a check which DID report on the merge target cannot be masked by another
# commit's — not that the required set is covered. That set is read separately,
# by `required_contexts` below, which is what closed #214.
#
# BOTH SOURCES, because `gh pr checks` merges them and dropping one would make
# this laxer than what it replaces: check runs from the Checks API, and the legacy
# commit statuses that older integrations still post. `statusCheckRollup` is over
# BOTH — measured, a `cli/cli` commit with thirteen check runs and no statuses
# reports SUCCESS, and a `pandas-dev/pandas` commit with one failed run, six still
# in progress and a passing legacy status reports FAILURE.
#
# ONE ROLLUP RATHER THAN TWO PAGINATED READS, and that is what closes a class this
# pull request spent four rounds inside. The REST reads had to be assembled here:
# `--paginate` requests pages sequentially and is not a snapshot, so a rerun
# landing between two of them lets a record repeat, or be REPLACED by one with a
# fresh id while the count holds — and the second of those is invisible to any
# rule about the pages themselves, because every page is individually well-formed.
# Nothing available can make two REST reads atomic, so each guard bought one
# interleaving and left the next. GitHub computes this rollup itself, over both
# sources, in one response addressed by the OID: there are no pages to reconcile
# and no fold to get wrong. `prefer removing the dependency over guarding it`.
#
# THE PRECEDENCE IS THE SERVER`S TOO, and it agrees with this file`s contract: the
# pandas commit above has a failed run and six unfinished ones and reports FAILURE,
# which is "at least one is still running AND NONE HAS FAILED" read the way the
# bucket parse below reads it.
#
# `EXPECTED` IS PENDING. It is the state of a context branch protection requires
# that has not reported, so it is precisely the case where the answer is not in
# yet — and it is not green. An unrecognised state is malformed, for the reason
# `recordlib.sh` records.
#
# A NULL ROLLUP IS `none` AND A NULL OBJECT IS AN ERROR. They arrive the same way,
# with status 0 and no message: a commit that has no checks at all answers
# `statusCheckRollup: null`, and an OID this repository does not have answers
# `object: null` — measured, both. Reading the second as `none` would hand the CI
# gate "no checks are configured" for a commit nobody could find.
commit_checks_verdict() {   # <oid> ; prints green|failed|pending|none|malformed
    local oid="$1" _left _out
    _left="$(rb_left)" || return 2
    # `-f`, NOT `-F`. `--field` performs magic conversion, so a value that looks
    # like a number is sent as a JSON number — and both of these variables are
    # declared `String!`, so a repository named `123` is rejected by the server and
    # this helper reports the round unreadable for that repository alone. An OID of
    # forty digits is the same trap on the other variable. `--raw-field` sends the
    # string that was measured, which is the only shape any of the three can have.
    _out="$(run_limited "$_left" gh api graphql --hostname "$HOST" \
        -f query='query($o:String!,$r:String!,$oid:GitObjectID!){repository(owner:$o,name:$r){object(oid:$oid){... on Commit{statusCheckRollup{state}}}}}' \
        -f o="$OWNER" -f r="$REPO" -f oid="$oid" 2>/dev/null)" || return 2
    # THE WHOLE PATH IS WALKED WITH `has`, not with `//`. A default swallows the
    # difference between a field that is absent because the body is an error and
    # one that is null because there is nothing to report, and those are opposite
    # answers here.
    printf '%s' "$_out" | jq -r '
        if type != "object" or (has("errors")) then "malformed"
        elif (.data | type) != "object" then "malformed"
        elif (.data.repository | type) != "object" then "malformed"
        elif (.data.repository | has("object") | not) then "malformed"
        elif (.data.repository.object | type) != "object" then "malformed"
        elif (.data.repository.object | has("statusCheckRollup") | not) then "malformed"
        elif .data.repository.object.statusCheckRollup == null then "none"
        elif (.data.repository.object.statusCheckRollup | type) != "object" then "malformed"
        elif (.data.repository.object.statusCheckRollup.state | type) != "string" then "malformed"
        else ( .data.repository.object.statusCheckRollup.state
               | if IN("FAILURE","ERROR") then "failed"
                 elif IN("PENDING","EXPECTED") then "pending"
                 elif . == "SUCCESS" then "green"
                 else "malformed" end )
        end' 2>/dev/null || return 2
    return 0
}

# ── WHAT THE BASE BRANCH REQUIRES, AND WHETHER THIS COMMIT MEETS IT ────────
#
# THE READ IS AVAILABLE, and #214 said it was not. That issue measured
# `repos/{o}/{r}/branches/{b}/protection`, which does need admin and denies with a
# 404 indistinguishable from "not protected". The BRANCH OBJECT carries the same
# answer and is readable with the `repo` scope this loop runs under: measured on
# ten repositories none of which this account administers, `repos/{o}/{r}/branches/{b}`
# returns `protected` and, under `protection.required_status_checks`, the contexts
# themselves — three on `cli/cli`, eleven on `kubernetes/kubernetes`,
# twenty-three on `microsoft/vscode` — while the dedicated endpoint 404s on the
# same repository with the same token.
#
# BOTH SOURCES, because either can be the whole answer. `home-assistant/core`
# reports `protection.enabled: false` with `protected: true`: its protection is a
# RULESET, and its eight required contexts appear only under
# `repos/{o}/{r}/rules/branches/{b}`. `cli/cli` is the other way round. So the
# required set is the UNION, and reading one alone reports a requirement as absent.
#
# A RULE THIS CANNOT EVALUATE IS AN ERROR, not a rule with no contexts in it. The
# ruleset types that gate a merge on something other than a status context —
# `workflows`, `code_scanning`, `required_deployments` — would otherwise be dropped
# here and the branch would read as requiring only what its `required_status_checks`
# rules name, which is #214's own shape one level down: an enforcement rule
# arriving as an empty required set. They cannot be evaluated from a check context,
# so they are named as unsupported and the merge stops; `REVIEW_MERGE_STRICT=1` is
# where GitHub evaluates them itself.
#
# THE REFUSAL STANDS IN BOTH MODES, and `merge_queue` is the one exception. Strict
# mode was tried as a general exemption and taken back in the same pull request:
# `REVIEW_MERGE_STRICT=1` only stops passing `--admin`, and the decision record
# says so — it does not make the repository`s rules non-bypassable, so a credential
# on a ruleset`s bypass list merges past them there too. The two mistakes are not
# symmetrical: refusing costs a merge the operator can make by hand, with the rule
# NAMED on the line; passing costs a merge nobody evaluated, and nothing says so.
#
# THE QUEUE IS THE EXCEPTION BECAUSE THE RECORD MAKES IT ONE.
# `docs/decisions/2026-08-06-merge-admin-default.md` states that the `--admin`
# waiver does not cover a base branch requiring a merge queue and that
# `REVIEW_MERGE_STRICT=1` is the only SUPPORTED setting there — so refusing under
# strict would refuse the one configuration that record recommends, on the one rule
# where `gh pr merge` without `--admin` does the right thing by queueing the
# request, which the gate then reports as status 4 rather than as a merge.
#
# THE LIST COMES FROM THE SCHEMA, not from what has been seen in the wild:
# `RepositoryRuleType` is an enum, and the entries here are the ones that cannot
# name a check — creation and deletion, history and signature rules, review and
# authorization rules, the pattern and file restrictions, `lock_branch`, `tag`,
# `max_ref_updates`, `workflow_updates`. What is deliberately NOT on it is every
# rule that can block a merge on something this cannot read: `workflows`,
# `required_workflow_status_checks`, `code_scanning`, `secret_scanning`,
# `license_compliance_scanning`, `required_deployments` and `merge_queue`.
#
# AND THE TYPE IS NAMED, which is the only thing that makes refusing actionable.
# jq writes it to `$ERRF` rather than to `/dev/null`, and the caller lifts it onto
# the error line as `rule=<type>`, filtered to the characters a rule type can have
# — the text is a message from a body this script did not write, and it lands in a
# line other programs parse.
#
# THE LIST IS OF WHAT IS IRRELEVANT, not of what blocks, so an unrecognised type
# refuses. A rule type GitHub adds tomorrow is one nobody here has read, and the
# two directions are not symmetrical: refusing names the type in the diagnostic and
# costs a rerun once the list grows, while ignoring it costs the gate. The listed
# types are the ones that cannot name a check — patterns, restrictions, history and
# review rules — and `copilot_code_review` is among them because `cli/cli` carries
# it today and refusing there would be a gate that never opens.
#
# `protected: false` IS AN ANSWER; an unreadable shape is not. A branch with no
# protection from either source requires nothing, and that is what `none` means
# here — not "could not tell". But a branch that IS protected whose protection
# object is missing or of another shape is `malformed`, because the contexts
# cannot be listed and a merge would then be gated on an empty set.
#
# THE RULES READ IS PAGINATED, at thirty a page by default, so a branch with more
# rules than that could carry its `required_status_checks` on the second — parsed
# as a well-formed array with the requirement simply absent. `--paginate` and every
# page is read; each is validated as an array of its own, since `jq -s` slurps them
# as separate documents and a `.[][]` over an error body would walk its values.
# That the pages are not one snapshot is already answered above: both sources are
# read twice and everything is unioned, so a rule that moved between pages is
# honoured rather than lost.
#
# THE BRANCH READ IS ALSO WHAT PROVES THE NAME. `rules/branches/{b}` answers `[]`
# for a branch that does not exist — a misspelling would arrive as "nothing is
# required" — while `branches/{b}` 404s, so the read that can be wrong is the one
# behind the read that cannot. The name arrives PERCENT-ENCODED, which both
# endpoints accept: measured, `branches/foo/bar` and `branches/foo%2Fbar` reach the
# same handler.
#
# WHAT IS NOT COVERED, stated because the comment beside the code is where a
# reader looks: the "require branches to be up to date" policy (`strict` in
# classic protection, `strict_required_status_checks_policy` in a ruleset) is not
# read. Nothing enforces it on the DEFAULT path — `--admin` bypasses branch
# protection outright, so a branch behind its base merges with its checks never
# having run against the merged state — and under `REVIEW_MERGE_STRICT=1` GitHub
# enforces it, as it enforces everything else there. #214 is about which contexts
# are required; that gap is #220.
required_contexts() {   # <base ref> ; prints a JSON array of {context, app} entries
    local base="$1" _left _branch _rules
    _left="$(rb_left)" || return 2
    _branch="$(run_limited "$_left" gh api --hostname "$HOST" \
        "repos/$OWNER/$REPO/branches/$base" 2>/dev/null)" || return 2
    _left="$(rb_left)" || return 2
    _rules="$(run_limited "$_left" gh api --hostname "$HOST" \
        "repos/$OWNER/$REPO/rules/branches/$base" --paginate 2>/dev/null)" || return 2
    # EVERY FIELD IS TYPED BEFORE IT IS USED. An absent or oddly-shaped one read as
    # "no contexts" is a merge gated on an empty required set, which is the
    # direction that opens the gate rather than the one that closes it.
    printf '%s\n%s\n' "$_branch" "$_rules" | jq -c -s --argjson strict \
        "$(if [ "${REVIEW_MERGE_STRICT:-}" = "1" ]; then printf 'true'; else printf 'false'; fi)" '
        if length < 2 then error("a branch and at least one rules page are expected")
        elif (.[0] | type) != "object" then error("the branch is not an object")
        elif (.[0].protected | type) != "boolean" then error("protected is not a boolean")
        elif any(.[1:][]; type != "array") then error("a rules page is not an array")
        else
          ( .[0] as $b
            | if ($b.protection | type) == "object" then
                if ($b.protection.required_status_checks | type) == "null"
                   or ($b.protection | has("required_status_checks") | not) then []
                elif ($b.protection.required_status_checks | type) != "object"
                  then error("required_status_checks is not an object")
                elif ($b.protection.required_status_checks.checks | type) == "array" then
                  [ $b.protection.required_status_checks.checks[]
                    | if type != "object" or (.context | type) != "string"
                      then error("a classic check has no context")
                      elif (.app_id | type) | IN("number","null") | not
                      then error("a classic app_id is not a number")
                      else {context: .context,
                            app: (if .app_id == -1 then null else .app_id end)} end ]
                elif ($b.protection.required_status_checks.contexts | type) != "array"
                  then error("the classic contexts are not an array")
                elif any($b.protection.required_status_checks.contexts[]; type != "string")
                  then error("a classic context is not a string")
                else [ $b.protection.required_status_checks.contexts[] | {context: ., app: null} ] end
              elif $b.protected then error("the branch is protected and its protection is unreadable")
              else [] end ) as $classic
          | ( [ .[1:][][]
                | if type != "object" then error("a rule is not an object")
                  elif (.type | type) != "string" then error("a rule has no type")
                  elif .type == "required_status_checks" then
                       if (.parameters | type) != "object" then error("a rule has no parameters")
                       elif (.parameters.required_status_checks | type) != "array"
                         then error("the ruleset checks are not an array")
                       else .parameters.required_status_checks[]
                            | if type != "object" or (.context | type) != "string"
                              then error("a ruleset context is not a string")
                              elif (.integration_id | type) | IN("number","null") | not
                              then error("a ruleset integration_id is not a number")
                              else {context: .context,
                                    app: (if .integration_id == -1 then null
                                          else .integration_id end)} end
                       end
                  elif .type | IN(
                      "creation","update","deletion","non_fast_forward",
                      "required_linear_history","required_signatures","pull_request",
                      "required_review_thread_resolution","copilot_code_review",
                      "authorization","tag","lock_branch","merge_queue_locked_ref",
                      "max_ref_updates","workflow_updates",
                      "commit_message_pattern","commit_author_email_pattern",
                      "committer_email_pattern","branch_name_pattern","tag_name_pattern",
                      "file_path_restriction","max_file_size","max_file_path_length",
                      "file_extension_restriction"
                    ) then empty
                  elif .type == "merge_queue" and $strict then empty
                  else error("a rule type this cannot evaluate: " + .type)
                  end ] ) as $ruleset
          | ( $classic + $ruleset | unique )
        end' 2>"$ERRF" || return 2
    return 0
}

# THE CONTEXTS OF THE COMMIT, from the same rollup the all-checks question uses
# and therefore addressed the same way. `contexts` is the rollup's own view, one
# entry per context rather than one per run: measured, a `cli/cli` commit whose
# REST check-run listing holds 302 records reports 10 here. A page boundary is
# still refused rather than truncated — a required context on the second page
# would read as one that has not reported, and this loop would wait for a check
# that had already passed.
#
# EVERY RECORD SHARING THE NAME IS EVALUATED, not the first one found. A name can
# arrive as a check run AND as a legacy status — an integration posting both, or two
# apps using the same name where the requirement is unbound — and GitHub requires
# all of them. Taking the first match meant whichever the rollup happened to list
# first decided, so a passing record could answer for a failing one.
#
# A REQUIRED CONTEXT THAT IS NOT THERE IS PENDING, not missing. That is what
# `EXPECTED` means on the other side of the same question: the requirement stands
# and the answer is not in yet.
#
# THE NAME IS NOT THE WHOLE REQUIREMENT. Both sources can bind a context to an APP
# — `app_id` under classic protection`s `checks`, `integration_id` in a ruleset —
# and GitHub then counts only that app`s run. Matching on the name alone would let
# a passing run of the same name from ANOTHER app satisfy this gate, which on the
# default `--admin` path is the merge. So a bound requirement is matched on the
# app too, read from the run`s own check suite.
#
# `-1` IS NOT AN APP, IT IS THE WILDCARD. GitHub writes `app_id: -1` where the
# requirement explicitly allows ANY app to provide the check, so keeping it as a
# binding would look for a check suite whose app id is `-1`, find none, and report
# `pending` for ever — a required context that has passed, on a gate that cannot
# open. It is normalised to the unbound representation on both sources: no app id
# is negative, so where the value is not the wildcard it is one nothing can match
# and refusing to merge is still the right direction.
#
# A BOUND REQUIREMENT CANNOT BE MET BY A LEGACY STATUS, and that is a refusal
# rather than an omission: a `StatusContext` carries a creator, not the app id the
# requirement names, so there is nothing to compare and the requirement reads as
# not yet answered. An UNBOUND one — `app_id` null, which is what `cli/cli` carries
# on all three of its contexts — is met by either kind, as GitHub does it.
required_checks_verdict() {   # <oid> <base> ; prints green|failed|pending|none|malformed
    local oid="$1" base="$2" _left _req _req2 _out
    # BOTH SOURCES ARE READ TWICE AND EVERYTHING IS UNIONED, because the two reads
    # are not one snapshot and a requirement can MOVE between them. Add the context
    # to classic protection after the branch read, remove it from the ruleset before
    # the rules read, and neither body carries it though it was required throughout
    # — an empty required set, which is a merge with nothing asserted.
    #
    # THE UNION IS MONOTONE, which is why this is a second read rather than a
    # comparison. Refusing on a changed pair blocks the merge on any benign edit and
    # still has to decide what a third answer means; unioning cannot LOSE a
    # requirement, and the cost of a stale one is that the gate reports it pending
    # for this run and the operator re-runs. Over-requiring for one run is the safe
    # direction; under-requiring is the merge.
    #
    # TWO CALLS, NOT A LOOP INSIDE, so the reads interleave classic, rules, classic,
    # rules. A requirement that dodged every sample would have to be in the ruleset
    # at both classic reads and in classic at both ruleset reads, which is three
    # migrations inside one gate run.
    _req="$(required_contexts "$base")" || return 2
    _req2="$(required_contexts "$base")" || return 2
    _req="$(printf '%s\n%s\n' "$_req" "$_req2" | jq -c -s '
        if length != 2 or any(.[]; type != "array") then error("two arrays are expected")
        else (.[0] + .[1] | unique) end' 2>/dev/null)" || return 2
    case "$_req" in
        '[]') printf '%s\n' none; return 0 ;;
        '['*) ;;
        *)    return 2 ;;
    esac
    _left="$(rb_left)" || return 2
    _out="$(run_limited "$_left" gh api graphql --hostname "$HOST" \
        -f query='query($o:String!,$r:String!,$oid:GitObjectID!){repository(owner:$o,name:$r){object(oid:$oid){... on Commit{statusCheckRollup{contexts(first:100){pageInfo{hasNextPage}nodes{__typename ... on CheckRun{name status conclusion checkSuite{app{databaseId}}} ... on StatusContext{context state}}}}}}}}' \
        -f o="$OWNER" -f r="$REPO" -f oid="$oid" 2>/dev/null)" || return 2
    printf '%s' "$_out" | jq -r --argjson req "$_req" '
        if type != "object" or (has("errors")) then "malformed"
        elif (.data | type) != "object" then "malformed"
        elif (.data.repository | type) != "object" then "malformed"
        elif (.data.repository | has("object") | not) then "malformed"
        elif (.data.repository.object | type) != "object" then "malformed"
        elif (.data.repository.object | has("statusCheckRollup") | not) then "malformed"
        else ( if .data.repository.object.statusCheckRollup == null then []
               elif (.data.repository.object.statusCheckRollup | type) != "object" then null
               elif (.data.repository.object.statusCheckRollup.contexts | type) != "object" then null
               elif (.data.repository.object.statusCheckRollup.contexts.pageInfo.hasNextPage | type) != "boolean" then null
               elif .data.repository.object.statusCheckRollup.contexts.pageInfo.hasNextPage then null
               elif (.data.repository.object.statusCheckRollup.contexts.nodes | type) != "array" then null
               else .data.repository.object.statusCheckRollup.contexts.nodes end ) as $ctx
          | if $ctx == null then "malformed"
            elif any($ctx[]; type != "object" or (.__typename | type) != "string") then "malformed"
            else [ $req[] as $want
                   | ( [ $ctx[]
                         | select((.name // .context) == $want.context)
                         | select($want.app == null
                                  or (.__typename == "CheckRun"
                                      and (.checkSuite.app.databaseId == $want.app))) ] ) as $cs
                   | ( [ $cs[]
                         | if .__typename == "CheckRun" then
                             if (.status | type) != "string" then "malformed"
                             elif .status != "COMPLETED" then "pending"
                             elif (.conclusion | type) != "string" then "malformed"
                             elif .conclusion | IN("FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","STALE") then "failed"
                             elif .conclusion | IN("SUCCESS","NEUTRAL","SKIPPED") then "green"
                             else "malformed" end
                           elif .__typename == "StatusContext" then
                             if (.state | type) != "string" then "malformed"
                             elif .state | IN("FAILURE","ERROR") then "failed"
                             elif .state | IN("PENDING","EXPECTED") then "pending"
                             elif .state == "SUCCESS" then "green"
                             else "malformed" end
                           else "malformed" end ] ) as $each
                   | if ($each | length) == 0 then "pending"
                     elif any($each[]; . == "malformed") then "malformed"
                     elif any($each[]; . == "failed") then "failed"
                     elif any($each[]; . == "pending") then "pending"
                     else "green" end ] as $v
              | if any($v[]; . == "malformed") then "malformed"
                elif any($v[]; . == "failed") then "failed"
                elif any($v[]; . == "pending") then "pending"
                else "green" end
            end
        end' 2>/dev/null || return 2
    return 0
}

ERRF="$(mktemp 2>/dev/null)" || {
    echo "PR_CI_STATE pr=$PR status=error reason=no_scratch_file" >&2; exit 2; }
# THE CONTAINER IS VALIDATED BEFORE anything is concluded from it. `all(.[]; …)`
# over an empty stream is `true` by definition, so a successful read that returned
# an object, a null or an empty array came out as "everything passed".
#
# AND AN UNRECOGNISED BUCKET IS MALFORMED, not benign. `skipping` and `cancel` are
# documented today; a value outside the set this script knows must not fall
# through a catch-all into "green", which is the same shape as the review state
# that reached `dismissed` through a catch-all and drove a review loop. See
# recordlib.sh.
RC=0
# THE COMMIT-ADDRESSED PATH IS TAKEN WHERE IT CAN ANSWER, and since #214 that is
# BOTH questions with a head to ask about. A call with no `--head` still goes to
# `gh pr checks`, because there is no commit to address.
if [ -n "$WANT_HEAD" ] && [ -z "$REQUIRED" ]; then
    OUT="$(commit_checks_verdict "$WANT_HEAD")" || RC=$?
    MSG=""
    if [ "$RC" -ne 0 ]; then
        echo "PR_CI_STATE pr=$PR status=error reason=commit_checks_unreadable rc=$RC head=$WANT_HEAD" >&2
        rm -f "$ERRF" 2>/dev/null
        exit 2
    fi
    rm -f "$ERRF" 2>/dev/null
elif [ -n "$WANT_HEAD" ]; then
    # WHICH BRANCH IS BEING MERGED INTO, because that is what requires anything.
    # It is the PR's own field rather than the checkout's: this helper is given a
    # PR number, and the working tree may be on any branch or none.
    _left_base="$(rb_left)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=deadline_exhausted" >&2; exit 2; }
    BASE_REF="$(run_limited "$_left_base" gh pr view "$PR" --repo "$HOST/$OWNER/$REPO"                   --json baseRefName --jq '.baseRefName' 2>/dev/null)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=base_unreadable" >&2; exit 2; }
    # THE VALUE IS ENCODED, not refused. It goes into a URL PATH, and `#`, `%` and
    # a space all need encoding there — but every one of them is legal in a git ref,
    # so refusing them would mean this gate could never merge a pull request
    # targeting `release#candidate` whatever its checks said: a gate that never
    # opens for whoever branches that way. `@uri` is jq's, so the encoding is the
    # one thing here that is not hand-written, and it handles UTF-8 by bytes —
    # measured, `ünïcode` comes back `%C3%BCn%C3%AFcode`.
    #
    # TWO ARE STILL REFUSED, and neither refuses a ref that git would create. An
    # EMPTY name has nothing to ask about. A name containing `..` is the one
    # traversal vector encoding does not close, because `.` is unreserved and stays
    # itself: `branches/../../secret` would ask about another repository's branch.
    # Git rejects two consecutive dots in a ref name, so this refuses nothing that
    # could arrive from a real pull request.
    case "$BASE_REF" in
        ""|*..*)
            echo "PR_CI_STATE pr=$PR status=error reason=bad_base base=$BASE_REF" >&2; exit 2 ;;
    esac
    BASE_ENC="$(jq -rn --arg s "$BASE_REF" '$s|@uri' 2>/dev/null)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=base_unencodable" >&2; exit 2; }
    # THE ENCODING IS PROVEN, not assumed: an empty result would ask about
    # `branches/`, which is the branch LIST — a body of another shape that this
    # would then read as "no protection".
    [ -n "$BASE_ENC" ] || {
        echo "PR_CI_STATE pr=$PR status=error reason=base_unencodable" >&2; exit 2; }
    OUT="$(required_checks_verdict "$WANT_HEAD" "$BASE_ENC")" || RC=$?
    MSG=""
    if [ "$RC" -ne 0 ]; then
        # THE UNSUPPORTED RULE TYPE IS LIFTED ONTO THE LINE. Without it the operator
        # is told the required checks are unreadable and nothing else, on a merge
        # that will never proceed until they change something they cannot see. The
        # value is filtered to what a rule type can contain rather than trusted:
        # it comes out of an API body, and this line is parsed.
        REQ_DETAIL=""
        REQ_MSG="$(cat "$ERRF" 2>/dev/null)" || REQ_MSG=""
        case "$REQ_MSG" in
            *"a rule type this cannot evaluate: "*)
                REQ_DETAIL="${REQ_MSG##*a rule type this cannot evaluate: }"
                REQ_DETAIL="${REQ_DETAIL//[!A-Za-z0-9_-]/}"
                [ -n "$REQ_DETAIL" ] && REQ_DETAIL=" rule=$REQ_DETAIL" ;;
        esac
        echo "PR_CI_STATE pr=$PR status=error reason=required_checks_unreadable rc=$RC head=$WANT_HEAD$REQ_DETAIL" >&2
        rm -f "$ERRF" 2>/dev/null
        exit 2
    fi
    rm -f "$ERRF" 2>/dev/null
else
_left_checks="$(rb_left)" || {
    echo "PR_CI_STATE pr=$PR status=error reason=deadline_exhausted" >&2; exit 2; }
OUT="$(run_limited "$_left_checks" gh pr checks "$PR" --repo "$HOST/$OWNER/$REPO" $REQUIRED --json bucket \
         --jq 'if type != "array" or length == 0 then "malformed"
               elif any(.[]; type != "object" or (.bucket | type) != "string") then "malformed"
               elif any(.[]; .bucket | IN("fail","cancel")) then "failed"
               elif any(.[]; .bucket == "pending") then "pending"
               elif all(.[]; .bucket | IN("pass","skipping")) then "green"
               else "malformed" end' 2>"$ERRF")" || RC=$?
# The READ has its own status, taken before `rm` overwrites it. A `cat` that
# emitted text containing "no checks" and then failed would otherwise be
# classified as the benign none-configured case — a failed probe reported as a
# repository with nothing to check.
MSG="$(cat "$ERRF" 2>/dev/null)"; MSG_RC=$?
rm -f "$ERRF" 2>/dev/null
[ "$MSG_RC" -eq 0 ] || {
    echo "PR_CI_STATE pr=$PR status=error reason=diagnostic_unreadable rc=$MSG_RC" >&2; exit 2; }
fi

# `gh pr checks` exits non-zero when a check FAILED as well as when it is pending
# or absent, so the status alone does not classify anything — the parsed value
# does, and the status only matters where there is no value to trust.
# THE HEAD IS CONFIRMED AFTER THE READ as well as before it. The confirmation
# above and the read are separate requests, and a push landing between them means
# the answer describes a commit nobody verified — in the round loop, a head that
# had almost finished earning its grace hands that grace to a different commit,
# whose own checks have not been registered yet.
#
# So the head is read once more and must still be the one asked about.
#
# WHAT THE CONFIRMATION IS WORTH DEPENDS ON WHICH READ ANSWERED. Both questions
# are addressed by the OID now — `commit_checks_verdict` and
# `required_checks_verdict` each ask a rollup for the commit they are given — so
# the answer is BOUND and this confirmation only reports whether the head has
# since moved. Only a call with NO `--head` goes through `gh pr checks`, which has
# no commit selector; there this block does not run at all. #214.
#
# THE REQUIRED SET ITSELF IS A PROPERTY OF THE BASE BRANCH, not of the commit, so
# it is not bound by an OID and cannot be: protection changed between the read and
# the merge is a race GitHub has too, and it is not the one #214 is about.
if [ -n "$WANT_HEAD" ]; then
    _left_after="$(rb_left)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=deadline_exhausted" >&2; exit 2; }
    HEAD_AFTER="$(run_limited "$_left_after" gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" \
                    --json headRefOid --jq '.headRefOid' 2>/dev/null)" || {
        echo "PR_CI_STATE pr=$PR status=error reason=head_unreadable_after" >&2; exit 2; }
    _reason="$(sha_reason "$HEAD_AFTER")" || {
        echo "PR_CI_STATE pr=$PR status=error reason=$_reason head=$HEAD_AFTER" >&2; exit 2; }
    if [ "$HEAD_AFTER" != "$WANT_HEAD" ]; then
        echo "PR_CI_STATE pr=$PR status=stale head=$HEAD_AFTER want=$WANT_HEAD moved=during_checks"
        exit 5
    fi
    # THE BASE IS CONFIRMED TOO, and only the required question needs it. A pull
    # request can be RETARGETED without its head moving, so `--match-head-commit`
    # sees nothing: the requirements just read are the old base`s, and the merge
    # lands on a branch whose own required checks were never asked about. That is
    # the same shape as a head that moved, so it is the same answer — `stale`, which
    # the caller re-runs rather than stopping on.
    if [ -n "$REQUIRED" ]; then
        _left_base2="$(rb_left)" || {
            echo "PR_CI_STATE pr=$PR status=error reason=deadline_exhausted" >&2; exit 2; }
        BASE_AFTER="$(run_limited "$_left_base2" gh pr view "$PR" --repo "$HOST/$OWNER/$REPO" \
                        --json baseRefName --jq '.baseRefName' 2>/dev/null)" || {
            echo "PR_CI_STATE pr=$PR status=error reason=base_unreadable_after" >&2; exit 2; }
        if [ "$BASE_AFTER" != "$BASE_REF" ]; then
            echo "PR_CI_STATE pr=$PR status=stale head=$HEAD_AFTER want=$WANT_HEAD moved=base"
            exit 5
        fi
    fi
fi

case "$OUT" in
    # GREEN REQUIRES A CLEAN STATUS. `gh` can emit a complete, valid green result
    # and then exit non-zero because the request failed part-way, and command
    # substitution keeps what it printed — so the one verdict that opens a gate
    # was the one being taken on trust. In the merge gate that is an
    # administrator merge on an untrusted partial response.
    #
    # `failed` and `pending` are accepted whatever the status, because both are
    # directions the caller stops or waits in: a wrong `failed` costs a round, a
    # wrong `green` costs the gate.
    green)
        [ "$RC" -eq 0 ] || {
            echo "PR_CI_STATE pr=$PR status=error reason=green_from_failed_probe rc=$RC" >&2
            exit 2
        }
        echo "PR_CI_STATE pr=$PR status=green";   exit 0 ;;
    failed)  echo "PR_CI_STATE pr=$PR status=failed";  exit 1 ;;
    pending) echo "PR_CI_STATE pr=$PR status=pending"; exit 3 ;;
    # `none` REACHES HERE AS A VALUE on the commit-addressed path, where this
    # script does the classifying and can say so directly. On the PR-addressed
    # path it arrives as a MESSAGE and a status, below, because that is the only
    # way `gh pr checks` reports it.
    none)
        [ "$RC" -eq 0 ] || {
            echo "PR_CI_STATE pr=$PR status=error reason=none_from_failed_probe rc=$RC" >&2
            exit 2
        }
        echo "PR_CI_STATE pr=$PR status=none"; exit 4 ;;
esac
# AND THE STATUS HAS TO BE THE ONE THAT MEANS IT. `gh` reports "nothing to
# report" by exiting 1 with that message on stderr; a probe that printed the
# message and then DIED — the watchdog's 124 for a hang, its 125 for a watchdog
# that could not do its job — carries the same text and means something else
# entirely. Ignoring the status there turned a failed probe into `none`, which the
# round gate accepts after its grace and the merge gate accepts at once: a hung
# request becoming merge permission.
#
# 1 is required rather than "not 124 and not 125", because the next unexpected
# status should block too. `gh pr checks` documents 8 for pending, which is
# handled above by its value; there is no documented third code for this case.
if checks_msg_is_none_configured "$MSG" && [ "$RC" -eq 1 ]; then
    echo "PR_CI_STATE pr=$PR status=none"
    exit 4
fi
echo "PR_CI_STATE pr=$PR status=error reason=unreadable rc=$RC out=$OUT err=$MSG" >&2
exit 2
