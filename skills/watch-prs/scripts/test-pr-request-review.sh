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
cp "$SCRIPT" "$SELF_DIR/loadlib.sh" "$SELF_DIR/recordlib.sh" "$SELF_DIR/identitylib.sh" \
   "$SELF_DIR/writelib.sh" "$DIR/" \
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
# contract: stdout carries NOTHING, so a reason leaking onto it is output the caller has no
# use for and cannot see on the stream it does read. The baseline crosses in the file named
# by `--baseline-file`, which is the next paragraph.
OUT="$TMP/out"; ERR="$TMP/err"
# THE BASELINE IS A FILE THE CALLER NAMES SINCE #263, not this helper's stdout. The driver
# used to redirect — `> "$PRIOR_FILE"` — and that open follows a symlink and happens in the
# driving shell before the helper starts, so nothing here could refuse it.
BASEF="$TMP/prior.txt"
# THE BODY ARRIVES ON STDIN, which is why the third argument is gone. The driver
# redirects a file its own tool wrote, so `SKILL.md` needs no `cat` to write it
# and no heredoc to carry it — a heredoc would splice the account into shell
# source, where a line equal to the delimiter ends it. `$BODY_IN` is what this
# harness feeds through that redirection.
run() {   # run [args…] ; prints "<rc>", with the baseline in $BASEF and stderr in $ERR
    local rc=0
    : > "$BASEF"
    # THE OPTION IS SUPPLIED FOR THE ORDINARY TWO-ARGUMENT CALL, which is what the driver
    # makes. A case about the ARITY passes its own count and this does nothing to it.
    if [ "$#" -eq 2 ]; then set -- "$@" --baseline-file "$BASEF"; fi
    (cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
        BODIES="$TMP/bodies" REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
        /usr/bin/env bash -p "$DIR/pr-request-review.sh" "$@" <"$BODY_IN" >"$OUT" 2>"$ERR") || rc=$?
    printf '%s' "$rc"
}
# THE TERMINATING NEWLINE IS ASSERTED ON RAW BYTES, because nothing else in this file can
# see it. `$(…)` and `cat` in a substitution both strip trailing newlines, so every
# assertion phrased on the captured value passes whether or not the writer emitted the
# delimiter — and `pr-watch.sh` refuses a baseline without it as
# `unterminated_after_review_file`. A writer changed to emit a bare token would leave this
# suite green and break the real handoff, which is the shape of the defect this whole
# change is about.
raw_is() {   # raw_is <file> <expected-content-including-newlines> <label>
    printf '%s' "$2" > "$TMP/raw.expected" || die "could not stage the raw expectation for $3"
    cmp -s "$1" "$TMP/raw.expected" \
        && pass "…and $3 lands as raw bytes with its terminating newline" \
        || die "$3 is not byte-for-byte '$2': $(od -c "$1" 2>/dev/null | head -2)"
}
stdout()  { cat "$OUT"; }
# THE BASELINE IS READ FROM THE FILE THE CALL NAMED, not from stdout. Since #263 the helper
# RENAMES onto that path rather than opening it to write, because the driver's
# `> "$PRIOR_FILE"` followed a symlink and was opened before this process started — and a
# helper-side writing open would have followed it just the same.
baseline() { cat "$BASEF"; }
stderr()  { cat "$ERR"; }
posted()  { grep -q '^gh ' "$TMP/calls"; }
nothing_posted() { ! grep -q '^gh ' "$TMP/calls"; }
bodies()  { cat "$TMP/bodies"; }
# A PRODUCER'S STATUS IS NOT THE READER'S. `grep -q X <<<"$(producer)"` discards the
# substitution's status, so a producer that emits the expected marker and THEN fails
# — a truncated write, a missing file read halfway — leaves the reader matching and
# the assertion passing on an incomplete read. The pipeline this replaced took that
# status through `pipefail`; a herestring has no pipeline to take it from, so the
# capture has to. `_cap` takes it, reports it, and EMPTIES the value, because a
# partial read that still matches is the failure being guarded against.
_cap() { _CAP="$("$@")" || { die "producer failed: $*"; _CAP=; }; return 0; }
# …AND THE CAPTURE IS PROVEN TO REJECT AN EMIT-THEN-FAIL PRODUCER, which is the
# whole point of taking the status: the marker IS emitted, so the reader alone
# cannot tell the truncated read from the complete one.
_emit_then_fail() { printf '%s\n' 'THE-MARKER'; return 1; }
( die() { exit 7; }
  _cap _emit_then_fail
  grep -qF 'THE-MARKER' <<<"$_CAP" && exit 8
  exit 0 )
_ef=$?
[ "$_ef" -eq 7 ] \
    && pass "a producer that emits the marker and then fails is rejected" \
    || die "an emit-then-fail producer was not rejected (rc=$_ef)"


# ── THE ORDINARY MANUAL PATH ───────────────────────────────────────────────
world; rc="$(run 7 no)"
{ [ "$rc" = 0 ] && [ "$(baseline)" = 4242 ]; } \
    && pass "the manual path posts and writes the baseline into the file it was given" \
    || die "the manual path gave rc=$rc baseline='$(baseline)' stderr='$(stderr)'"
_cap bodies
grep -qF '@codex review' <<<"$_CAP" \
    && pass "…in one comment carrying the mention that IS the request" \
    || die "the manual path posted no mention: $(bodies)"
_cap bodies
grep -qF 'A one-paragraph account' <<<"$_CAP" \
    && pass "…and the account travels with it, rather than in a second comment" \
    || die "the account was not posted with the mention: $(bodies)"
[ "$(grep -c '^gh ' "$TMP/calls")" = 1 ] \
    && pass "…as ONE comment" \
    || die "the manual path posted $(grep -c '^gh ' "$TMP/calls") comments"

# AND ON THE MANUAL PATH "NO PRIOR REVIEW" IS AN ANSWER, NOT A FAILURE. This is
# the ORDINARY first request: Codex has not reviewed this head yet, so
# `review-id` succeeds with an empty value. Treating that as unusable aborts
# AFTER the request has been posted, leaving a pass in flight that nobody waits
# for — which is what a digits-only check in the driver did.
#
# IT IS SPELLED `none` SINCE #264, and the spelling is the point. Empty used to BE the
# no-floor value, so a writer whose truncation succeeded and whose write failed produced
# it by accident and the watch armed against nothing. A token has to be written on
# purpose. So the assertion is the exact string rather than "not a failure": emitting
# empty here would restore the old ambiguity and pass a laxer check.
world; : > "$W/prior.out"; rc="$(run 7 no)"
{ [ "$rc" = 0 ] && [ "$(baseline)" = none ] && posted; } \
    && pass "…and no prior review on the manual path reports the none token, not an empty value" \
    || die "a first request with no prior review gave rc=$rc baseline='$(baseline)' stderr='$(stderr)'"
raw_is "$BASEF" 'none
' "the manual path's none baseline"

# AND A COMMENT-BACKED BASELINE COMES THROUGH AS IT IS. A reviewer's newest
# verdict arrives either as a submitted review, whose id is digits, or as a clean
# COMMENT on the head — which `pr-review-state.sh` reports as `comment:<id>` and
# `pr-watch.sh` accepts. Rewriting or refusing it here would abort after the
# request had been posted.
world; printf 'comment:998877\n' > "$W/prior.out"; rc="$(run 7 no)"
{ [ "$rc" = 0 ] && [ "$(baseline)" = comment:998877 ] && posted; } \
    && pass "…and a comment-backed baseline is reported unchanged" \
    || die "a comment-backed baseline gave rc=$rc baseline='$(baseline)'"

# ── THE BASELINE IS WRITTEN BEFORE THE POST, AND ITS WRITE IS TAKEN ────────
# `printf` can fail — a full filesystem under the caller's transport file — and
# an `exit 0` after it masks that, so the driver reads an empty or truncated
# value as the baseline and the watch accepts the PREVIOUS review as the answer
# to a request just posted. Taking the status only works while there is something
# left to refuse with, which is why the write goes first.
#
# NO WATCHDOG ON THIS ONE, because the watchdog is what the case is trying to
# break. `run_limited` redirects its subject's stdout into a capture file — that
# is how it stops a child holding the caller's substitution pipe open — so the
# closed descriptor never reaches the helper and its write succeeds, the request
# is posted, and the case fails on the mac-shaped bash 3.2 job where the fallback
# is the only arm. Under GNU `timeout` the descriptor passes straight through.
#
# WHAT IS GIVEN UP is the time bound, and the subject cannot spend it: it is one
# `printf` and one stubbed `gh` call, with no loop between them.
#
# AND THE FAILURE IS STAGED ON THE TARGET, NOT ON A CLOSED DESCRIPTOR. Since #263 the
# baseline is written by RENAME into a path the call names, so stdout has nothing to do
# with it — closing fd 1 leaves the write perfectly able to succeed. Worse, omitting the
# option to provoke a failure makes the helper exit in argument validation, long before this
# write, so the case would stay green if this path ever posted without a usable baseline.
# The path is valid and its CONTAINING DIRECTORY is not writable, which is what stops an
# exclusive create.
#
# THE PRECONDITION IS ESTABLISHED RATHER THAN ASSUMED, because `chmod` does not bite for
# uid 0 and containers run this suite as root: the case probes the mode first and skips
# itself by name where it cannot stage the failure.
world
_uw="$TMP/unwritable"; rm -rf "$_uw"; mkdir -p "$_uw"; chmod 500 "$_uw"
if ( : > "$_uw/probe" ) 2>/dev/null; then
    chmod 700 "$_uw"; rm -rf "$_uw"
    pass "(the unwritable-baseline case is skipped: this uid can create through mode 500)"
else
    rc="$(run 7 no --baseline-file "$_uw/prior.txt")"
    chmod 700 "$_uw"
    { [ "$rc" != 0 ] && nothing_posted; } \
        && pass "a baseline that cannot be written stops with NOTHING posted" \
        || die "an unwritable baseline gave rc=$rc, posted=$(cat "$TMP/calls")"
    rm -rf "$_uw"
fi

# ── THE AUTOMATIC PATH HAS NO BASELINE, AND ASKS FOR NONE ──────────────────
# `--after-review` on the initial automatic pass can capture the very review
# being waited for: the trigger preceded this loop. So there is nothing to read,
# and reading it anyway is the failure — not a wasted call.
#
# REPORTED AS `none` SINCE #264 rather than as nothing, for the reason the manual case
# above gives — and the assertion is the exact string, since an empty value here would be
# the ambiguity that change removed.
world; rc="$(run 7 yes)"
{ [ "$rc" = 0 ] && [ "$(baseline)" = none ]; } \
    && pass "the automatic path posts and reports the none token as its baseline" \
    || die "the automatic path gave rc=$rc baseline='$(baseline)' stderr='$(stderr)'"
raw_is "$BASEF" 'none
' "the automatic path's none baseline"
grep -q '^review-state ' "$TMP/calls" \
    && die "…but it looked the baseline up anyway: $(cat "$TMP/calls")" \
    || pass "…and never looks one up"
_cap bodies
grep -qF '@codex review' <<<"$_CAP" \
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
    _cap stderr
    { [ "$rc" = 1 ] && grep -qF 'marker the loop reads as a record' <<<"$_CAP"; } \
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
_cap stderr
{ [ "$rc" = 1 ] && grep -qF 'queues a second one' <<<"$_CAP"; } \
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

# ── A BASELINE THAT CANNOT BE READ IS NOT A BASELINE ───────────────────────
# Read as empty it became the automatic path's answer on the manual path, and the
# watch then accepted the PREVIOUS review as this round's. Since #264 the automatic
# path's answer is the `none` token and an empty value is refused by the watch, so
# that particular collision is gone — and the reason to refuse here is unchanged: a
# read that failed must not be able to produce ANY value a caller would act on.
world; printf '2\n' > "$W/prior.rc"
rc="$(run 7 no)"
_cap stderr
{ [ "$rc" = 1 ] && grep -qF 'do not request a review blind' <<<"$_CAP"; } \
    && pass "an unreadable baseline stops the request" \
    || die "an unreadable baseline gave rc=$rc '$(stderr)'"
nothing_posted \
    && pass "…before anything is posted" \
    || die "the request was posted without a baseline: $(cat "$TMP/calls")"

# ── A FAILED POST IS NOT A REQUEST ─────────────────────────────────────────
# The wait step would otherwise poll until it timed out and report "no review
# arrived" rather than "none was asked for".
# The baseline is already written by then, and that is deliberate: the driver
# runs this as a condition and reads the file only on success, so a failed post
# takes the failure arm where the file is never consumed. What has to hold is the
# STATUS — the thing the driver branches on.
for _mode in no yes; do
    world; printf '1\n' > "$W/gh.rc"
    rc="$(run 7 "$_mode")"
    _cap stderr
    { [ "$rc" = 1 ] && grep -qF 'do not enter the wait step' <<<"$_CAP"; } \
        && pass "a failed post stops rather than reporting a request ($_mode)" \
        || die "a failed post on the $_mode path gave rc=$rc '$(stderr)'"
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
_cap stderr
{ [ "$rc" = 1 ] && grep -qF 'empty' <<<"$_CAP" && nothing_posted; } \
    && pass "…and an empty one is refused rather than posted as an account" \
    || die "an empty body gave rc=$rc '$(stderr)'"

# ── THE ARGUMENTS ARE REQUIRED AND CHECKED ─────────────────────────────────
world; rc="$(run)"
_cap stderr
{ [ "$rc" = 1 ] && grep -qF 'a PR number is required' <<<"$_CAP"; } \
    && pass "a missing PR number refuses" \
    || die "a missing PR gave rc=$rc '$(stderr)'"
world; rc="$(run notanumber no)"
_cap stderr
{ [ "$rc" = 1 ] && grep -qF 'a PR number is required' <<<"$_CAP"; } \
    && pass "…and so does one that is not a number" \
    || die "a non-numeric PR gave rc=$rc '$(stderr)'"

# THE MODE HAS NO DEFAULT AND IS NOT A TRUTHINESS TEST. The two wrong answers are
# a duplicate pass and a review nobody asked for, so an unrecognised value cannot
# fall into either branch — which is what `[ "$X" = yes ]` on its own does.
world; rc="$(run 7 '')"
_cap stderr
{ [ "$rc" = 1 ] && grep -qF 'auto-review mode is required' <<<"$_CAP" && nothing_posted; } \
    && pass "a missing auto-review mode refuses rather than defaulting" \
    || die "a missing mode gave rc=$rc '$(stderr)'"
for _bad in YES true on 1 y; do
    world; rc="$(run 7 "$_bad")"
    _cap stderr
    { [ "$rc" = 1 ] && grep -qF "'$_bad' is not an auto-review mode" <<<"$_CAP" && nothing_posted; } \
        && pass "…and '$_bad' is refused by name" \
        || die "the mode '$_bad' gave rc=$rc '$(stderr)', posted=$(cat "$TMP/calls")"
done
# AND THE OLD SHAPE IS REFUSED BY NAME, rather than dropping the argument and
# reading whatever stdin happened to be — a terminal, or the previous command's
# output, posted as this PR's account.
world; rc="$(run 7 no "$TMP/body.md")"
_cap stderr
{ [ "$rc" = 1 ] && grep -qF 'the body is no longer a file' <<<"$_CAP" && nothing_posted; } \
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
{ [ "$rc" = 0 ] && [ -z "$(stdout)" ] && [ "$(baseline)" = 4242 ]; } \
    && pass "…and a success says nothing there either, not even gh's own output" \
    || die "a success put '$(stdout)' on stdout"

# ── A SYMLINKED BASELINE PATH COSTS THE LINK, NOT ITS TARGET ───────────────
#
# THIS WAS THE LAST HANDOFF WRITE THE DRIVER STILL OPENED ITSELF. `> "$PRIOR_FILE"` in
# `SKILL.md` is opened by the DRIVING shell before this helper starts, and `>` follows a
# symlink — so a same-UID process that replaced that path had the operator's file at the
# other end truncated and the baseline written through it, with nothing this helper could
# check in time. The path is handed over as `--baseline-file` now and renamed onto here.
#
# THE VICTIM IS OUTSIDE THE SESSION, which is what made this worth a change: the handoff
# path lives under the session's working directory, and the file it can be pointed at does
# not.
world
_sl="$TMP/reqlink"; rm -rf "$_sl"; mkdir -p "$_sl"
printf 'the operator file, which must survive\n' > "$_sl/victim"
ln -s "$_sl/victim" "$_sl/link"
rc="$(run 7 no --baseline-file "$_sl/link")"
[ "$(cat "$_sl/victim")" = 'the operator file, which must survive' ] \
    && pass "a symlinked baseline path leaves the operator's file at the other end intact" \
    || die "the baseline write truncated the symlink's target (rc=$rc)"
{ [ "$rc" = 0 ] && [ ! -L "$_sl/link" ] && [ "$(cat "$_sl/link")" = 4242 ]; } \
    && pass "…the link being what the rename replaced, with the baseline across" \
    || die "the symlinked baseline gave rc=$rc and '$(cat "$_sl/link" 2>/dev/null)'"
rm -rf "$_sl"

# ── IT REFUSES TO RUN UNPRIVILEGED ─────────────────────────────────────────
# `$-` proves less than it looks and is a last-resort refusal, but the honest
# mistake — calling the file with a plain `bash` — is what it catches.
world
out="$(cd "$TMP" && run_limited 25 env PATH="$TMP/bin:$PATH" W="$W" CALLS="$TMP/calls" \
    BODIES="$TMP/bodies" REVIEW_BUS_REMOTE='git@github.com:acme/widget.git' \
    bash "$DIR/pr-request-review.sh" 7 no <"$TMP/body.md" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && grep -qF 'reason=not_privileged' <<<"$out"; } \
    && pass "an unprivileged interpreter is refused" \
    || die "an unprivileged run gave rc=$rc '$out'"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
