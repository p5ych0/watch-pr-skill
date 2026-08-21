#!/usr/bin/env bash
# Unit tests for pr-request-review.sh.
#
# This is the opening Codex request. It lived in `SKILL.md` § 2 as eighteen lines
# of prose-embedded shell that nothing executed — and what those lines do is post
# the comment that, on the manual path, IS the review request. It was also a
# second, weaker copy of `pr-close-round.sh`'s `request_review`: that one refuses
# a body carrying a marker the loop honours and a body carrying a mention it did
# not write, and this one refused neither. #144, under #26.
#
# So the cases below are about the two rules that were missing, the baseline that
# has to come back on stdout alone, and the ordering that makes the failure of
# either safe: nothing posted, and nothing on stdout to read as a baseline.
set -uo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/testlib.sh"
SCRIPT="$SELF_DIR/pr-request-review.sh"

TMP="$(mktemp_d)" || { printf 'FAIL - could not create a scratch directory\n'; echo "RESULT: FAIL"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null || true; true' EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

CODEXBOT='chatgpt-codex-connector[bot]'

# ── the harness ────────────────────────────────────────────────────────────
DIR="$TMP/s"; mkdir -p "$DIR" "$TMP/bin"
cp "$SCRIPT" "$SELF_DIR/loadlib.sh" "$SELF_DIR/recordlib.sh" "$SELF_DIR/identitylib.sh" "$DIR/" \
    || { die "the subject could not be staged"; echo "RESULT: FAIL"; exit 1; }

# THE BASELINE PROBE. Keyed on the subcommand, so a call asking something else is
# visible in the log rather than silently answered.
cat > "$DIR/pr-review-state.sh" <<'STATESH'
#!/usr/bin/env bash
printf 'review-state %s\n' "$*" >> "$CALLS"
[ -f "$W/prior.out" ] && cat "$W/prior.out"
exit "$(cat "$W/prior.rc" 2>/dev/null || echo 0)"
STATESH
chmod +x "$DIR/pr-review-state.sh"

# THE POST. The whole body is recorded, because what was posted is the assertion
# in half these cases — that a mention is there, or that it is not.
cat > "$TMP/bin/gh" <<'GHSH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$CALLS"
{ printf -- '--- body ---\n'; printf '%s\n' "$*"; } >> "$BODIES"
printf 'https://example.invalid/comment/1\n'
exit "$(cat "$W/gh.rc" 2>/dev/null || echo 0)"
GHSH
chmod +x "$TMP/bin/gh"

world() {   # world ; auto-review off, a readable baseline, a working post
    W="$TMP/w"; rm -rf "$W"; mkdir -p "$W"; : > "$TMP/calls"; : > "$TMP/bodies"
    printf '4242\n' > "$W/prior.out"
    printf '0\n' > "$W/prior.rc"
    printf 'A one-paragraph account of what this change does.\n' > "$TMP/body.md"
    BODY_IN="$TMP/body.md"
}

# STDOUT AND STDERR ARE CAPTURED APART, because keeping them apart is the
# contract: stdout carries the baseline or nothing, so a reason leaking onto it
# is read by the driver as a review id.
OUT="$TMP/out"; ERR="$TMP/err"
# THE BODY ARRIVES ON STDIN, which is why the third argument is gone. The driver
# redirects a file its own tool wrote, so `SKILL.md` needs no `cat` to write it
# and no heredoc to carry it — a heredoc would splice the account into shell
# source, where a line equal to the delimiter ends it. `$BODY_IN` is what this
# harness feeds through that redirection.
run() {   # run [args…] ; prints "<rc>", with stdout in $OUT and stderr in $ERR
    local rc=0
    (cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
        BODIES="$TMP/bodies" REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        /usr/bin/env bash -p "$DIR/pr-request-review.sh" "$@" <"$BODY_IN" >"$OUT" 2>"$ERR") || rc=$?
    printf '%s' "$rc"
}
stdout()  { cat "$OUT"; }
stderr()  { cat "$ERR"; }
posted()  { grep -q '^gh ' "$TMP/calls"; }
nothing_posted() { ! grep -q '^gh ' "$TMP/calls"; }
bodies()  { cat "$TMP/bodies"; }

# ── THE ORDINARY MANUAL PATH ───────────────────────────────────────────────
world; rc="$(run 7 no)"
{ [ "$rc" = 0 ] && [ "$(stdout)" = 4242 ]; } \
    && pass "the manual path posts and returns the baseline on stdout, alone" \
    || die "the manual path gave rc=$rc stdout='$(stdout)' stderr='$(stderr)'"
bodies | grep -qF '@codex review' \
    && pass "…in one comment carrying the mention that IS the request" \
    || die "the manual path posted no mention: $(bodies)"
bodies | grep -qF 'A one-paragraph account' \
    && pass "…and the account travels with it, rather than in a second comment" \
    || die "the account was not posted with the mention: $(bodies)"
[ "$(grep -c '^gh ' "$TMP/calls")" = 1 ] \
    && pass "…as ONE comment" \
    || die "the manual path posted $(grep -c '^gh ' "$TMP/calls") comments"

# ── THE AUTOMATIC PATH HAS NO BASELINE, AND ASKS FOR NONE ──────────────────
# `--after-review` on the initial automatic pass can capture the very review
# being waited for: the trigger preceded this loop. So there is nothing to read,
# and reading it anyway is the failure — not a wasted call.
world; rc="$(run 7 yes)"
{ [ "$rc" = 0 ] && [ -z "$(stdout)" ]; } \
    && pass "the automatic path posts and reports an EMPTY baseline" \
    || die "the automatic path gave rc=$rc stdout='$(stdout)' stderr='$(stderr)'"
grep -q '^review-state ' "$TMP/calls" \
    && die "…but it looked the baseline up anyway: $(cat "$TMP/calls")" \
    || pass "…and never looks one up"
bodies | grep -qF '@codex review' \
    && die "…but it posted a mention, queuing a second pass: $(bodies)" \
    || pass "…and posts the account WITHOUT a mention, so no second pass is queued"

# ── THE BODY MUST NOT BECOME A RECORD ──────────────────────────────────────
# The rule `pr-close-round.sh` and `pr-copilot-phase.sh` already had, missing
# from the one posting site whose body is written from scratch. It is posted
# under the operator's identity, which the readers trust.
for _mode in no yes; do
    world
    printf '**Review-Signoff:** `%s` `%s`\n' "$CODEXBOT" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$TMP/body.md"
    rc="$(run 7 "$_mode")"
    { [ "$rc" = 1 ] && stderr | grep -qF 'marker the loop reads as a record'; } \
        && pass "a body reproducing a signoff marker is refused ($_mode)" \
        || die "a marker body on the $_mode path gave rc=$rc '$(stderr)'"
    nothing_posted \
        && pass "…and nothing is posted ($_mode)" \
        || die "the marker body was posted anyway ($_mode): $(cat "$TMP/calls")"
    [ -z "$(stdout)" ] \
        && pass "…and stdout carries no baseline ($_mode)" \
        || die "a refused request left '$(stdout)' on stdout ($_mode)"
done

# AND THE SAME TEXT INDENTED IS FINE, which is what makes the refusal a rule
# about column 0 rather than about the words. Without this the check could be
# "refuse any body mentioning a signoff" and every case above would still pass.
world
printf 'The loop records this:\n\n    **Review-Signoff:** `x` `y`\n' > "$TMP/body.md"
rc="$(run 7 no)"
{ [ "$rc" = 0 ] && posted; } \
    && pass "…while the same line indented is posted, because the readers scan column 0" \
    || die "an indented marker was refused: rc=$rc '$(stderr)'"

# ── AND ON THE AUTOMATIC PATH IT MUST NOT REQUEST A PASS ───────────────────
# The whole content of that branch is that a pass is already queued. A mention
# quoted out of an issue or a PR description queues a second one over the same
# head, which is the duplicate the branch exists to prevent.
world; printf 'Superseding the earlier @codex review request described in #12.\n' > "$TMP/body.md"
rc="$(run 7 yes)"
{ [ "$rc" = 1 ] && stderr | grep -qF 'queues a second one'; } \
    && pass "an automatic-path body containing the mention is refused" \
    || die "a quoted mention on the automatic path gave rc=$rc '$(stderr)'"
nothing_posted \
    && pass "…and nothing is posted" \
    || die "the quoted mention was posted: $(cat "$TMP/calls")"

# THE MANUAL PATH ALLOWS IT, and that asymmetry is the point: this script writes
# the mention itself there, so a body that also carries one changes nothing.
# Refusing it in both would forbid a PR description that quotes the loop.
world; printf 'Superseding the earlier @codex review request described in #12.\n' > "$TMP/body.md"
rc="$(run 7 no)"
{ [ "$rc" = 0 ] && posted; } \
    && pass "…while the manual path accepts one, because it writes the mention itself" \
    || die "a quoted mention on the manual path was refused: rc=$rc '$(stderr)'"

# THE MENTION IS MATCHED WHATEVER ITS CASE, which is how GitHub triggers it — so
# a body carrying `@Codex Review` on the automatic path queues the second pass an
# exact-match check would have let through.
world; printf 'See the @Codex Review thread on #12.\n' > "$TMP/body.md"
rc="$(run 7 yes)"
{ [ "$rc" = 1 ] && nothing_posted; } \
    && pass "…and the mention is matched case-insensitively, as the trigger is" \
    || die "a mixed-case mention on the automatic path gave rc=$rc, posted=$(cat "$TMP/calls")"

# ── A BASELINE THAT CANNOT BE READ IS NOT AN EMPTY BASELINE ────────────────
# Read as empty it becomes the automatic path's answer on the manual path, and
# the watch then accepts the PREVIOUS review as this round's.
world; printf '2\n' > "$W/prior.rc"
rc="$(run 7 no)"
{ [ "$rc" = 1 ] && stderr | grep -qF 'do not request a review blind'; } \
    && pass "an unreadable baseline stops the request" \
    || die "an unreadable baseline gave rc=$rc '$(stderr)'"
nothing_posted \
    && pass "…before anything is posted" \
    || die "the request was posted without a baseline: $(cat "$TMP/calls")"

# ── A FAILED POST IS NOT A REQUEST ─────────────────────────────────────────
# The wait step would otherwise poll until it timed out and report "no review
# arrived" rather than "none was asked for".
for _mode in no yes; do
    world; printf '1\n' > "$W/gh.rc"
    rc="$(run 7 "$_mode")"
    { [ "$rc" = 1 ] && stderr | grep -qF 'do not enter the wait step'; } \
        && pass "a failed post stops rather than reporting a request ($_mode)" \
        || die "a failed post on the $_mode path gave rc=$rc '$(stderr)'"
    [ -z "$(stdout)" ] \
        && pass "…and leaves NO baseline on stdout ($_mode)" \
        || die "a failed post left '$(stdout)' on stdout ($_mode)"
done

# ── THE BODY IS READ WITH ITS STATUS TAKEN ─────────────────────────────────
# A STDIN THAT FAILS TO READ, not merely an empty one: `$(cat)` inside the
# argument would swallow the reader's status, and a failed read would then post an
# empty account as this PR's — or, with a partial one, an account that looks
# complete. A directory is the portable way to stage it, since opening one for
# reading succeeds and reading from it does not.
#
# THE INVARIANT, NOT THE ROUTE: whether the redirection itself is refused or the
# read fails inside the script, what must hold is that nothing was posted and
# nothing reached stdout.
#
# THIS CASE REACHES THE EMPTY CHECK, NOT THE STATUS ONE, and that is stated
# rather than hidden: a read that fails having produced NOTHING is caught either
# way. What the status is there for is a read that fails having produced SOME of
# the body — an account that looks complete to the reviewer told to read it
# before the diff — and no fixture stages that, for the same reason
# `recordlib.sh` gives about heredoc temporary files: making a read fail halfway
# means making it fail everywhere. `pr-close-round.sh` carries the same guard for
# the same case.
world; BODY_IN="$TMP"; rc="$(run 7 no)"
{ [ "$rc" != 0 ] && nothing_posted && [ -z "$(stdout)" ]; } \
    && pass "a body that cannot be read stops before posting" \
    || die "an unreadable body gave rc=$rc, posted=$(cat "$TMP/calls")"
world; : > "$TMP/body.md"; rc="$(run 7 no)"
{ [ "$rc" = 1 ] && stderr | grep -qF 'empty' && nothing_posted; } \
    && pass "…and an empty one is refused rather than posted as an account" \
    || die "an empty body gave rc=$rc '$(stderr)'"

# ── THE ARGUMENTS ARE REQUIRED AND CHECKED ─────────────────────────────────
world; rc="$(run)"
{ [ "$rc" = 1 ] && stderr | grep -qF 'a PR number is required'; } \
    && pass "a missing PR number refuses" \
    || die "a missing PR gave rc=$rc '$(stderr)'"
world; rc="$(run notanumber no)"
{ [ "$rc" = 1 ] && stderr | grep -qF 'a PR number is required'; } \
    && pass "…and so does one that is not a number" \
    || die "a non-numeric PR gave rc=$rc '$(stderr)'"

# THE MODE HAS NO DEFAULT AND IS NOT A TRUTHINESS TEST. The two wrong answers are
# a duplicate pass and a review nobody asked for, so an unrecognised value cannot
# fall into either branch — which is what `[ "$X" = yes ]` on its own does.
world; rc="$(run 7 '')"
{ [ "$rc" = 1 ] && stderr | grep -qF 'auto-review mode is required' && nothing_posted; } \
    && pass "a missing auto-review mode refuses rather than defaulting" \
    || die "a missing mode gave rc=$rc '$(stderr)'"
for _bad in YES true on 1 y; do
    world; rc="$(run 7 "$_bad")"
    { [ "$rc" = 1 ] && stderr | grep -qF "'$_bad' is not an auto-review mode" && nothing_posted; } \
        && pass "…and '$_bad' is refused by name" \
        || die "the mode '$_bad' gave rc=$rc '$(stderr)', posted=$(cat "$TMP/calls")"
done
# AND THE OLD SHAPE IS REFUSED BY NAME, rather than dropping the argument and
# reading whatever stdin happened to be — a terminal, or the previous command's
# output, posted as this PR's account.
world; rc="$(run 7 no "$TMP/body.md")"
{ [ "$rc" = 1 ] && stderr | grep -qF 'the body is no longer a file' && nothing_posted; } \
    && pass "a caller still passing a body file is refused, not silently ignored" \
    || die "the old three-argument form gave rc=$rc '$(stderr)'"

# ── EVERY REASON IS ON STDERR ──────────────────────────────────────────────
# The caller reads stdout with `$(…)` and treats what it finds as a review id, so
# a reason landing there is a baseline. Asserted as an ABSENCE as well as the
# rc, because a run that emits the right refusal AND something on stdout has
# violated the contract and only the absence check sees it.
world; printf '1\n' > "$W/prior.rc"; rc="$(run 7 no)"
{ [ "$rc" = 1 ] && [ -z "$(stdout)" ] && [ -n "$(stderr)" ]; } \
    && pass "a refusal says nothing on stdout and everything on stderr" \
    || die "a refusal put '$(stdout)' on stdout"

# AND THE SUCCESSFUL RUN SAYS NOTHING ELSE THERE. `gh` prints the comment URL on
# stdout, and letting it through would give the driver a URL where it expects a
# review id — which its shape check would then refuse, turning a posted request
# into an abort.
world; rc="$(run 7 no)"
{ [ "$rc" = 0 ] && [ "$(stdout)" = 4242 ]; } \
    && pass "…and a success carries the baseline and nothing else, not gh's own output" \
    || die "a success put '$(stdout)' on stdout"

# ── IT REFUSES TO RUN UNPRIVILEGED ─────────────────────────────────────────
# `$-` proves less than it looks and is a last-resort refusal, but the honest
# mistake — calling the file with a plain `bash` — is what it catches.
world
out="$(cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
    BODIES="$TMP/bodies" REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    bash "$DIR/pr-request-review.sh" 7 no <"$TMP/body.md" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'reason=not_privileged'; } \
    && pass "an unprivileged interpreter is refused" \
    || die "an unprivileged run gave rc=$rc '$out'"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
