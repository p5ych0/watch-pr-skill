#!/usr/bin/env bash
# The shared identity parser: `rb_identity` in identitylib.sh.
#
# Every rule here was previously asserted only through the three helper scripts
# that each carried their own copy — which is why a rule reverted in one copy left
# the suite green. The rules are proven against the definition now, and
# `test-pr-identity.sh` proves each caller is wired to it. Issue #18.
set -Eeuo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
. "$SELF_DIR/identitylib.sh"

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

[ "$(type -t rb_identity 2>/dev/null)" = function ] \
    || { die "identitylib.sh does not define rb_identity"; echo "RESULT: FAIL"; exit 1; }

# Every case goes through the SAME entry point the callers use, with the remote
# supplied through the documented override rather than a stubbed `git` — the
# override is part of the contract (CLAUDE.md § Repo-agnostic invariant) and a
# stub would additionally be testing the stub.
#
# `HOST`, `OWNER` and `REPO` are cleared first. The parser sets them, so a case
# that failed to set one would otherwise be checked against the PREVIOUS case's
# value and pass — the fixture reporting a rule held using an answer from another
# input entirely.
id_case() {   # id_case <remote> <want: HOST/OWNER/REPO | reason-token> <label>
    local remote="$1" want="$2" label="$3" rc got
    HOST=''; OWNER=''; REPO=''; RB_IDENTITY_REASON=''
    rc=0
    REVIEW_BUS_REMOTE="$remote" rb_identity || rc=$?
    case "$want" in
        */*)
            got="$HOST/$OWNER/$REPO"
            { [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; } \
                && pass "$label derives $want" \
                || die "$label gave rc=$rc '$got' (wanted 0 and '$want')" ;;
        *)
            # THE REASON, not merely a non-zero status. Several of these remotes
            # would fail later anyway, at the first `gh` call against the wrong
            # repository — so an rc-only assertion passes on a parser that never
            # refused, having already addressed a request somewhere else.
            { [ "$rc" -eq 2 ] && case "$RB_IDENTITY_REASON" in "$want"*) true ;; *) false ;; esac; } \
                && pass "$label is refused as $want" \
                || die "$label gave rc=$rc reason='$RB_IDENTITY_REASON' (wanted 2 and $want)" ;;
    esac
}

# ── the shapes that must be REFUSED ────────────────────────────────────────
# Each of these derives a plausible `acme/widget` from its path while naming no
# GitHub server, so the failure it causes is not an error: it is every `gh` call
# landing on the unrelated PUBLIC repository of that name.
id_case '/srv/mirrors/acme/widget.git' origin_has_no_host 'an absolute local path'
id_case '../acme/widget.git'           origin_has_no_host 'a relative local path'
id_case '~/mirrors/acme/widget.git'    origin_has_no_host 'a tilde local path'
id_case 'acme-widget'                  origin_has_no_host 'a bare name with no path at all'
id_case 'file://github.com/srv/acme/widget.git' origin_transport_unsupported \
        'a file:// URL carrying a github.com authority'
id_case 'ftp://github.com/acme/widget.git' origin_transport_unsupported \
        'a transport that reaches no GitHub server'

# A URL whose transport IS accepted but which carries no authority at all. This
# branch had no fixture in any copy of the parser before it was extracted, and a
# mutant that removed the check survived the whole suite: the arm above yields an
# EMPTY host, and an empty host is what every `gh --hostname` call would then be
# given. Both spellings reach it — an ssh:// URL with nothing between the slashes,
# and an SCP-style remote with nothing before the colon.
id_case 'ssh:///acme/widget.git' origin_host_unparseable 'an ssh:// URL with no authority'
id_case ':acme/widget.git'       origin_host_unparseable 'an SCP-style remote with no host'

# ── the shapes that must be ACCEPTED, and what they derive ─────────────────
# The negative controls. Without them a matrix of refusals is satisfied by a
# parser that refuses everything, which is not the invariant — and a parser that
# refuses every remote makes the whole tool inoperable rather than safe.
id_case 'git@github.com:acme/widget.git'       'github.com/acme/widget' 'an SCP-style GitHub remote'
id_case 'https://github.com/acme/widget.git'   'github.com/acme/widget' 'an https GitHub remote'
id_case 'https://github.com/acme/widget'       'github.com/acme/widget' 'an https remote without .git'
id_case 'ssh://git@github.com/acme/widget.git' 'github.com/acme/widget' 'an ssh:// GitHub remote'
id_case 'git://github.com/acme/widget.git'     'github.com/acme/widget' 'a git:// GitHub remote'
id_case 'git+ssh://git@github.com/acme/widget.git' 'github.com/acme/widget' 'a git+ssh:// remote'
# The ENTERPRISE cases, which are the reason the authority is parsed rather than
# matched. `github.com` appearing anywhere in the URL sent these to the public
# host — and the public host holds a different `org/repo` of that name.
id_case 'git@ghe.example:org/github.com-mirror.git' 'ghe.example/org/github.com-mirror' \
        'an enterprise remote whose PATH contains github.com'
id_case 'https://ghe.example/org/widget.git' 'ghe.example/org/widget' 'an enterprise https remote'
id_case 'ghe.example:org/widget.git' 'ghe.example/org/widget' 'a userless SCP-style enterprise remote'

# ── an origin lookup that PRINTED and then failed is not an identity ───────
# `git remote get-url origin` can write a plausible URL and exit non-zero, and
# command substitution keeps what it wrote. This is the only rule here that
# cannot be reached through the override — the override IS the caller stating an
# identity, and has no status to take — so it needs a stubbed `git`.
IDTMP="$(mktemp_d)" || { die "could not create a scratch directory"; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$IDTMP"' EXIT
mkdir -p "$IDTMP/bin"
REAL_GIT="$(command -v git)" || { die "no git on PATH"; echo "RESULT: FAIL"; exit 1; }
cat > "$IDTMP/bin/git" <<GITSH
#!/usr/bin/env bash
if [ "\$1" = "remote" ]; then
    printf 'git@github.com:someone-else/other-repo.git\n'
    exit 1
fi
exec "$REAL_GIT" "\$@"
GITSH
chmod +x "$IDTMP/bin/git"
# A subshell, so the stubbed PATH and the unset override cannot leak into the
# cases above or below. `run_limited … env`, never a PATH on the watchdog: where
# GNU `timeout` is missing, `run_limited` polls with its own `sleep`.
probe="$(run_limited 20 env PATH="$IDTMP/bin:$PATH" bash -c '
    . "'"$SELF_DIR"'/identitylib.sh"
    unset REVIEW_BUS_REMOTE REVIEW_BUS_OWNER REVIEW_BUS_REPO
    rb_identity && printf "ACCEPTED:%s/%s/%s" "$HOST" "$OWNER" "$REPO" \
        || printf "REFUSED:%s" "$RB_IDENTITY_REASON"' 2>&1)" || true
case "$probe" in
    'REFUSED:no_origin') pass "an origin lookup that printed and then failed is refused" ;;
    *) die "a failed origin lookup was accepted ('$probe')" ;;
esac
# …and the untrusted value it printed was not used. The reason line does not
# quote the remote in this case, so a message-only assertion would prove nothing:
# the check is that the derived identity never appears at all.
case "$probe" in
    *someone-else*) die "the parser derived an identity from a failed lookup" ;;
    *) pass "…and nothing was derived from what it printed" ;;
esac

# ── the explicit overrides ─────────────────────────────────────────────────
# These exist so tests can supply an identity without a real remote. A parser
# that ignored them would make every fixture in this suite depend on the checkout
# it happens to run in.
HOST=''; OWNER=''; REPO=''
REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' REVIEW_BUS_OWNER='other' \
    REVIEW_BUS_REPO='thing' rb_identity && ov_rc=0 || ov_rc=$?
{ [ "${ov_rc:-1}" -eq 0 ] && [ "$HOST/$OWNER/$REPO" = 'github.com/other/thing' ]; } \
    && pass "REVIEW_BUS_OWNER and REVIEW_BUS_REPO override the derived path" \
    || die "the overrides were ignored (rc=${ov_rc:-?} got '$HOST/$OWNER/$REPO')"

# ── a failure does not leave a half-set identity behind ────────────────────
# The caller exits on a non-zero return, but a parser that assigned before
# refusing leaves the values set for anything that does not — and a caller reading
# them after a guard it got wrong sees a plausible `acme/widget` with an empty
# host. The REASON is what a failing call communicates, so it must be the only
# thing that changed.
#
# ALL THREE NAMES, ON EVERY REFUSING PATH. The first version checked `HOST` after
# one local-path remote, which is the single case where `HOST` was never reached:
# `OWNER` and `REPO` were assigned before any validation and were overwritten on
# that very case, and the `ssh://` arm set `HOST` to an empty string before
# returning `origin_host_unparseable`. An assertion that names one variable and one
# input reads like a guarantee and is not one.
for hs_remote in '/srv/mirrors/acme/widget.git' '../acme/widget.git' \
                 'file://github.com/srv/acme/widget.git' 'ssh:///acme/widget.git' \
                 ':acme/widget.git' 'acme-widget'; do
    HOST='SENTINEL_H'; OWNER='SENTINEL_O'; REPO='SENTINEL_R'; RB_IDENTITY_REASON=''
    hs_rc=0
    REVIEW_BUS_REMOTE="$hs_remote" rb_identity || hs_rc=$?
    { [ "$hs_rc" -eq 2 ] \
        && [ "$HOST" = 'SENTINEL_H' ] && [ "$OWNER" = 'SENTINEL_O' ] \
        && [ "$REPO" = 'SENTINEL_R' ]; } \
        && pass "a refused '$hs_remote' leaves the identity untouched" \
        || die "'$hs_remote' left a half-derived identity (rc=$hs_rc $HOST/$OWNER/$REPO)"
    [ -n "$RB_IDENTITY_REASON" ] \
        && pass "…and reports why through RB_IDENTITY_REASON alone" \
        || die "'$hs_remote' refused without setting a reason"
done

# ── the `rb-assigns:` declaration is TRUE ──────────────────────────────────
# `pr-selfcheck.sh` reads that line to decide which of SKILL.md's variables this
# library assigns, and it reads it rather than deducing it because every attempt
# to deduce reachability from the body was wrong in the quiet direction. A
# declaration is only safe while it is accurate, so accuracy is what this proves —
# otherwise the contract is just a comment that widens what the selfcheck accepts.
declared="$(grep -oE '^# rb-assigns:[A-Za-z0-9_ ]*' "$SELF_DIR/identitylib.sh" \
    | sed -E 's/^# rb-assigns:[[:space:]]*//' | tr ' ' '\n' | grep -vE '^$' | sort -u)"
[ -n "$declared" ] \
    && pass "identitylib.sh declares the names it assigns" \
    || die "identitylib.sh carries no rb-assigns declaration"

# EVERY DECLARED NAME IS SET by a successful call. A declaration naming something
# the parser never touches is the exact hole this replaces: the selfcheck would
# credit it and the driver would expand an unset value.
for n in $declared; do
    case "$n" in RB_IDENTITY_REASON) continue ;; esac   # set on failure, cleared on success
    unset "$n"
    REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' rb_identity >/dev/null 2>&1
    [ -n "${!n-}" ] \
        && pass "…and a successful call sets $n" \
        || die "$n is declared but a successful call leaves it unset"
done
# …and the failure name is set on the path that reports one.
unset RB_IDENTITY_REASON
# `|| true`: this file runs under `-e` and the call is EXPECTED to fail — that is
# the assertion. Without it the script aborts here and reports nothing at all.
REVIEW_BUS_REMOTE='/srv/mirrors/acme/widget.git' rb_identity >/dev/null 2>&1 || true
[ -n "${RB_IDENTITY_REASON-}" ] \
    && pass "…and a refused call sets RB_IDENTITY_REASON" \
    || die "RB_IDENTITY_REASON is declared but a refused call leaves it unset"

# AND NOTHING ELSE. A call that quietly set a fourth global would leave the
# declaration incomplete in the other direction: `pr-selfcheck.sh` would report
# that name undefined in SKILL.md, which is the loud direction — but it also means
# the library is doing something its contract does not say, and the next reader
# would have no way to know. The environment is snapshotted around the call, so
# this needs no list to keep in step.
#
# IN A FRESH SHELL. Snapshotting around a call in THIS shell proves nothing: the
# cases above have already called `rb_identity` many times, so anything it sets is
# in the "before" picture too, and a mutant adding an undeclared global survived
# the whole suite. The comparison has to happen where the call is the first one.
# `REVIEW_BUS_REMOTE` is set before the snapshot rather than as a command prefix,
# because a prefix assignment on a FUNCTION call stays in effect afterwards in
# bash and would read as a global the call had set.
extra="$(bash -c '
    . "'"$SELF_DIR"'/identitylib.sh"
    REVIEW_BUS_REMOTE="git@github.com:acme/widget.git"
    before="$(compgen -v | grep -E "^[A-Z][A-Z0-9_]*$" | sort)"
    rb_identity >/dev/null 2>&1
    compgen -v | grep -E "^[A-Z][A-Z0-9_]*$" | sort \
        | comm -13 <(printf "%s\n" "$before") -' 2>&1 \
    `# racy-pipeline-ok: the pipe below belongs to the bash -c, not to that printf` \
    | grep -vxF -f <(printf '%s\n' "$declared") || true)"
[ -z "$extra" ] \
    && pass "…and a call sets no global the declaration does not name" \
    || die "rb_identity sets undeclared globals: $(printf '%s' "$extra" | tr '\n' ' ')"

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
