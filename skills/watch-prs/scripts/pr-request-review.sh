#!/usr/bin/env -S bash -p
# Request the OPENING Codex review, and report the baseline the watch needs.
#
#   pr-request-review.sh <pr> <auto-review: yes|no> --baseline-file <path> < <body>
#
#   stdin   the account of what to look at; prose, one paragraph
#   the file  the review-id baseline — the `none` token where there is no prior
#           review to wait past, which is always the case on the automatic path, and
#           `comment:<id>` where the reviewer's newest verdict came through the
#           comment channel rather than as a submitted review. NEVER empty: the watch
#           refuses an empty baseline. That refusal was written when a failed write
#           produced one — every writer truncated before it wrote — and the rename
#           stopped that: a write that fails now leaves the previous contents. It stays
#           because `gate`'s explicit clearing and a file left by an older version both
#           still produce an empty file, and neither is an answer.
#           WRITTEN BY RENAME through `writelib.sh` rather than sent to stdout for the
#           driver to redirect: `>` in the driving shell follows a symlink, so a path a
#           same-UID process had replaced cost the operator the file it pointed at, and
#           the redirection is opened BEFORE this helper starts, so nothing here could
#           refuse it. #263
#   stdout  nothing
#   stderr  every reason
#
#   0  posted — the baseline is in the file `--baseline-file` names
#   1  stopped — nothing was posted
#
# WHY THIS EXISTS AS A SCRIPT
#
# It was eighteen lines in `SKILL.md` § 2, in a fenced block nothing executes:
# not the suite, not `pr-selfcheck.sh`, not the bash 3.2 job. What those lines do
# is post a GitHub comment that, on the manual path, IS the review request — the
# one mutation in this loop that starts everything after it. Issues #26, #144.
#
# AND IT WAS A SECOND, WEAKER COPY of `pr-close-round.sh`'s `request_review`,
# which does the same job for every LATER round. That copy refuses a body
# carrying a marker the loop honours and a body carrying a review trigger it did
# not write; this one did neither, so the opening request — the only one whose
# body is written from scratch rather than assembled from a round's findings —
# was the one posting site with no rules. `CLAUDE.md` § Tests: a rule that
# applies to more than one helper lives in a shared library, and every field
# check now in `recordlib.sh` began as two or three copies with at least one
# missing a rule.
#
# THE BODY IS PROSE AND MUST NOT BECOME A RECORD. It is posted under the
# operator's identity, which `pr-signoff.sh` and `pr-round-count.sh` trust, so a
# line reproducing one of their markers CREATES the record it was describing — a
# paragraph explaining this loop, or quoting a finding about it, becomes a
# signoff or an acknowledgement. `rb_reserved_marker_line` is the rule and it is
# shared, because three sites now post a caller-written body.
#
# ON THE AUTOMATIC PATH IT MUST NOT REQUEST A PASS EITHER. A comment CONTAINING
# `@codex review` queues a review on its own, and the whole content of the
# automatic branch is that a pass is ALREADY queued by the push or the PR-open —
# so a mention quoted out of an issue or a PR description queues a second pass
# over the same head, which is the duplicate this branch exists to prevent. On
# the MANUAL path this script writes the mention itself, so a body that also
# carries one changes nothing, exactly as in a Codex round.
#
# WHY THE REVIEWER IS NOT AN ARGUMENT. This is the Codex-first request, and every
# path below either writes `@codex review` or relies on a pass Codex queued.
# Copilot is never triggered by a mention and never by a push — only by
# `--add-reviewer`, which `pr-copilot-phase.sh open` owns — so a reviewer
# parameter here would have exactly one correct value and one that posts a Codex
# mention while claiming to ask Copilot. `pr-close-round.sh` needs the parameter
# because it closes rounds in both phases; this does not.
#
# `set -uo pipefail`, NOT `-e`: the probe below reports its answer as an exit
# status. See CLAUDE.md § Bash conventions.
# ── STARTED PRIVILEGED, OR NOT STARTED ─────────────────────────────────────
#
# The shebang is `env -S bash -p`, and the caller supplies the same thing:
# `SKILL.md` invokes this as `/usr/bin/env bash -p "$RB_SCRIPTS"/pr-request-review.sh`.
# An ordinary `#!/usr/bin/env bash` SOURCES `BASH_ENV`, IMPORTS functions from the
# environment and honours an exported `SHELLOPTS`, so every builtin here would be
# a name the operator's shell can replace. The full argument is in CLAUDE.md
# § The helpers are started privileged; `$-` below is the last-resort refusal it
# describes, and proves the MODE rather than how this shell reached it.
if [[ $- != *p* ]]; then
    echo "ABORT: reason=not_privileged" >&2
    exit 1
fi

set -uo pipefail

_RB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "ABORT: reason=lib_dir_unresolvable" >&2; exit 1; }
unset -f rb_load 2>/dev/null || { echo "ABORT: reason=loadlib_stale_definition" >&2; exit 1; }
# CLEAR, TAKE THE CLEAR'S STATUS, DEFINE A REFUSING STUB, SOURCE — the bootstrap
# that loads the loader cannot use the loader. No `type -t` preflight: the FIRST
# load is the verification, and the stub is what stops `PATH` answering in its
# place. #88.
rb_load() { return 127; }
. "$_RB_SELF_DIR/loadlib.sh" || { echo "ABORT: reason=loadlib_unreadable" >&2; exit 1; }
# THE FIRST LOAD CARRIES THE SENTINEL, because it is what the preflight used to
# say: an empty `loadlib.sh` leaves the stub, the stub returns 127, and without
# this arm the only trace is a bare exit status.
# NO `2>&1` ON THESE, unlike the helpers whose contract is stdout. `rb_load` reports on
# stderr, and so does everything this script says. Nothing at all goes to stdout since
# #263 — the baseline crosses in the file `--baseline-file` names — so redirecting here
# would only mix a load failure into a stream the caller has no use for, while hiding it
# from the one it reads.
rb_load "$_RB_SELF_DIR" recordlib rb_reserved_marker_line "ABORT:" || {
    _rb_rc=$?
    [[ $_rb_rc -eq 127 ]] && echo "ABORT: reason=loadlib_empty" >&2
    exit 1; }
rb_load "$_RB_SELF_DIR" recordlib rb_review_trigger "ABORT:" || exit 1
# THE REVIEWER LOGIN IS LIBRARY DATA, not a literal here and not an argument.
# `rb_load` clears before it sources, which is what stops an exported
# `RB_CODEX_BOT` from the environment being accepted as the login whose review
# this baseline is about.
rb_load "$_RB_SELF_DIR" recordlib RB_CODEX_BOT "ABORT:" var || exit 1
rb_load "$_RB_SELF_DIR" identitylib rb_identity "ABORT:" || exit 1
rb_load "$_RB_SELF_DIR" writelib rb_write_handoff "ABORT:" || exit 1
rb_identity || { echo "ABORT: reason=$RB_IDENTITY_REASON" >&2; exit 1; }

# AN EXTRA ARGUMENT IS REFUSED RATHER THAN IGNORED. The body used to be a third
# argument naming a file, and a caller still passing one would have it silently
# dropped while the body was taken from whatever stdin happened to be — a
# terminal, or the previous command's output. A shape that changed is worth
# saying so about; an argument nothing reads is not.
#
# AND THE BASELINE PATH IS AN OPTION RATHER THAN A THIRD POSITIONAL, for exactly that
# reason: a caller still passing the old body-file form would have that file OVERWRITTEN
# with the baseline, which is worse than the silent drop the refusal above exists for.
# Spelled out, the old form still lands on the refusal above and the new one cannot be
# confused with it.
{ [ "$#" -le 2 ] || { [ "$#" -eq 4 ] && [ "$3" = --baseline-file ]; }; } \
    || { echo "ABORT: this takes <pr> <auto-review> --baseline-file <path> and the body on stdin (got $# — a third positional was the body file, and the body is no longer a file)" >&2; exit 1; }
PR="${1:-}"; AUTO_REVIEW="${2:-}"; BASELINE_FILE="${4:-}"
case "$PR" in
    ""|*[!0-9]*) echo "ABORT: a PR number is required (got '$PR')" >&2; exit 1 ;;
esac
# NO DEFAULT, AND NOT A TRUTHINESS TEST. This value decides whether a review is
# requested at all, and the two wrong answers are a duplicate pass and a review
# nobody asked for — so an unrecognised value is refused by name rather than
# falling into either branch. It cannot be probed from `gh`: Codex automatic
# review is an account/repository setting, not repository state.
# AND THE BASELINE PATH IS REQUIRED, CHECKED AFTER THE TWO POSITIONALS. Its own refusal
# is separate from the arity one above so that a caller who omitted everything is told what
# a PR number is before being told about an option — and so that the OLD three-argument
# form, whose third argument named the BODY, still lands on the arity refusal rather than
# having that file overwritten with the baseline.
[ -n "$BASELINE_FILE" ] \
    || { echo "ABORT: --baseline-file <path> is required: the review baseline is written into it, and pr-watch.sh --after-review-file reads it back" >&2; exit 1; }
case "$AUTO_REVIEW" in
    yes|no) ;;
    "") echo "ABORT: the auto-review mode is required: 'yes' if Codex automatic review is on for this repository, 'no' if it is not" >&2; exit 1 ;;
    *) echo "ABORT: '$AUTO_REVIEW' is not an auto-review mode; expected 'yes' or 'no'" >&2; exit 1 ;;
esac
# THE BODY ARRIVES ON STDIN, NOT IN A FILE THE CALLER WROTE FIRST.
#
# It was a file, and writing it meant `cat > "$FILE" <<EOF` in `SKILL.md` — whose
# bash runs in the operator's own shell, where `cat` is a NAME. A function by that
# name receives the heredoc on stdin and writes whatever it likes to the
# redirection, so the account this script validates and posts would be the
# function's text rather than the driver's; and one that writes nothing and
# succeeds stops an otherwise valid request. `CLAUDE.md`: prefer REMOVING the
# dependency over guarding it.
#
# AND NOT FROM A HEREDOC IN THE DRIVER EITHER, which was the first answer. A
# heredoc splices the account into shell source: an account containing a line
# that is exactly the delimiter ENDS it, and whatever follows is parsed by that
# long-lived shell — and `EOF` is a line this loop's own accounts quote, out of a
# diff or a finding. A rarer delimiter narrows that without closing it, because
# the body is not known when the delimiter is chosen. The driver writes the file
# with its own file tool, which does not go through a shell at all, and redirects
# it here — a redirection the parser handles, with no command name in it to take.
#
# READ WITH ITS STATUS TAKEN, before anything is posted. `$(cat)` inside the
# argument swallows the reader's status, so a partial read still produces a
# successful `gh pr comment` — and this is the account the reviewer is told to
# read before the diff, so a truncated one is worse than none: it looks complete.
# Here `cat` is an external command in a PRIVILEGED shell, which imports no
# functions — the same footing as `gh`, `jq` and `git`, and the `PATH` boundary
# settled in #91.
#
# FULLY, AND FIRST. Everything below runs with stdin at end of file, so the
# nested helper and `gh` inherit nothing to consume.
BODY="$(cat)" || { echo "ABORT: could not read the request body from stdin." >&2; exit 1; }
[ -n "$BODY" ] || { echo "ABORT: the request body is empty." >&2; exit 1; }

if _marker="$(rb_reserved_marker_line "$BODY")"; then
    echo "ABORT: the request body starts a line with a marker the loop reads as a record: $_marker" >&2
    echo "It would be posted under your identity and honoured. Indent it by four spaces, or quote it inline with backticks — either still says what you meant. A fenced block does NOT help: the line inside it still starts at column 0, which is all the readers look at." >&2
    exit 1
fi

if [ "$AUTO_REVIEW" = "yes" ]; then
    rb_review_trigger "$BODY"; _trig_rc=$?
    case "$_trig_rc" in
        1) ;;
        0) echo "ABORT: automatic review is on, so a pass over this head is already queued — and this body contains '@codex review', which queues a second one." >&2
           echo "That is the duplicate pass this path exists to avoid: two passes, two sets of findings, one round. Break the mention up, or write it without the @." >&2
           exit 1 ;;
        *) echo "ABORT: could not tell whether the request body requests a review (rc=$_trig_rc)" >&2; exit 1 ;;
    esac
fi

# THE BASELINE, AND WHY THE AUTOMATIC PATH HAS NONE.
#
# `--after-review` means "the review I am waiting for is newer than this one". On
# a re-request that is right, and `pr-close-round.sh` reads one immediately before
# every later request. On the INITIAL AUTOMATIC pass it is actively wrong: the
# push or PR-open that triggered the review happened before this loop ran, so a
# lookup here can capture the very pass being waited for. The watch would then
# reject the only terminal review as stale and re-arm forever, waiting for a
# review nobody is going to request.
#
# There is nothing to capture before the trigger, because the trigger preceded
# us. So the automatic path waits on any terminal review, and only the explicit
# request below carries a baseline.
#
# READ IMMEDIATELY BEFORE THE REQUEST, never earlier — a baseline captured and
# then left to age accepts a pass that finished in between as the answer to a
# request made after it.
#
# NO HEAD BASELINE IS CAPTURED EITHER. One used to be, so the automatic path
# could tell a real push from a no-op one and send a mention only for the second;
# the request is unconditional now and nothing reads it. Left in place it would
# be a `gh pr view` whose transient failure or malformed answer stops this step
# before any context is posted or any wait begins — a call that can only cost.
PRIOR=""
if [ "$AUTO_REVIEW" = "no" ]; then
    PRIOR=$(/usr/bin/env bash -p "$_RB_SELF_DIR"/pr-review-state.sh review-id "$PR" "$RB_CODEX_BOT") \
        || { echo "ABORT: could not read the current review id; do not request a review blind." >&2; exit 1; }
fi

# THE BASELINE IS WRITTEN BEFORE THE POST, AND ITS WRITE IS TAKEN. The write can FAIL — a
# full filesystem under the caller's transport file — and an `exit 0` after it masks that.
# When this was written that meant the driver read an empty or truncated value as the
# baseline and `pr-watch.sh` accepted the PREVIOUS review as the answer to a request just
# posted.
#
# SINCE #264 THE WATCH REFUSES BOTH of those — an empty file, and one whose last byte is not
# the writer's newline — and since #263 the write RENAMES, so a failure leaves the previous
# contents rather than a truncated value and cannot produce either shape by accident. The
# consequence has moved rather than gone. What taking the status prevents now is posting a
# request whose baseline was never produced: the
# request would be in flight, and the driver's watch would stop with
# `empty_after_review_file` or `unterminated_after_review_file` on a round that cannot be
# re-armed without re-requesting. Taking the status only works if there is something left
# to refuse WITH, and after the post there is not.
#
# WRITING IT FIRST COSTS NOTHING, because the driver runs this as a condition and
# only reads the file on success — a post that then fails takes the failure arm,
# where the file is never consumed. So an unwritable baseline stops with nothing
# posted, which is the order the two failures should be in.
# THE NO-FLOOR VALUE IS SPELLED `none`, NOT LEFT EMPTY. #264: an empty file used to mean
# "no prior review", which made absence indistinguishable from failure — every writer
# TRUNCATED before it wrote, so any failure in between produced the legal value. The state
# is real and still has to be expressible, so it is expressed by a value a writer produces
# on purpose. Since #263 the write RENAMES, so a failure leaves the previous contents rather
# than an empty file and that particular route is gone — the token stays because `gate`'s
# explicit clearing and a file left by an older version both still produce one, and
# `pr-watch.sh` refuses an empty file for that reason.
# AND IT CROSSES BY RENAME, ONTO A PATH THIS HELPER NEVER OPENS TO WRITE. It went to stdout
# and the driver
# redirected — `> "$PRIOR_FILE"` — which follows a symlink and is opened by the driving
# shell BEFORE this process starts, so a path a same-UID process had replaced cost the
# operator the file it pointed at and nothing here could refuse it. #263.
_rb_wh="$(rb_write_handoff "$BASELINE_FILE" "${PRIOR:-none}")" \
    || { echo "ABORT: the review baseline could not be written; nothing has been posted: $_rb_wh" >&2; exit 1; }

# THE POST IS BRANCHED ON, because a failed one means no review was ever queued —
# and the wait step would then poll for one until it timed out, reporting "no
# review arrived" rather than "none was asked for".
#
# ONE COMMENT ON THE MANUAL PATH, because the mention IS the trigger: the account
# posted separately is an account the pass may not have read.
if [ "$AUTO_REVIEW" = "yes" ]; then
    gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "$BODY" >&2 \
        || { echo "ABORT: could not post the PR context — do not enter the wait step." >&2; exit 1; }
else
    gh pr comment "$PR" --repo "$HOST/$OWNER/$REPO" --body "@codex review

$BODY" >&2 \
        || { echo "ABORT: could not post the @codex request — do not enter the wait step." >&2; exit 1; }
fi
exit 0
