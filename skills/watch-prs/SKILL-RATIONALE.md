**One constraint on this file: every `## ` line is a claim.**

`test-pr-skill-contract.sh` compares the claims and the headings as exact strings.
It fails if a `# WHY:` names a claim that is not a heading here, if a heading here
is named by no claim, if either side repeats, or if the two totals differ.

It has no Markdown parser and no guards on this file's shape, deliberately. Both
were tried across a dozen review rounds: a parser needed fenced code, tilde
fences, indented fences, info strings, HTML comments and their ordering, and the
greps that replaced it then needed HTML blocks, indented headings, a second
title, and a hash run that is not a heading at all. The next construct was always
one round away, and `CLAUDE.md` records what a text scanner of that kind cost this
repository once already.

So the check is the bijection and nothing else. **Keep this file plain prose and
indented code.** A transcript line that would begin with `## ` is indented by four
spaces; a section hidden inside a comment or a fence, or written with a setext
underline, will pass the contract and mislead the next reader — which is a way of
mangling a document rather than a way of drifting, and the diff shows it.

**Which comments carry a pointer, and which do not.** A bash fence in `SKILL.md` holds three kinds of comment, and only one of them
belongs here.

- an **instruction** tells the driver what to do — a helper's arguments, its exit
  codes, how to write an account. It stays in the block and carries no pointer.
  Write it in sentence case, as an instruction: a capitalised assertion that is
  really an instruction reads as a claim whose argument has gone missing, and both
  reviewers have raised one as a finding;
- an **argument in place** is short enough that the whole of the reasoning fits
  beside the code. It stays, and carries no pointer. Nothing is gained by moving
  two lines into a section and pointing at it;
- a **claim** asserts why the code has its shape while the argument for it lives
  here. It carries a bare `# WHY:`, and its section heading is the claim character for
  character.

**ONE CLAIM PER INVARIANT.** Pairs may STACK above a single line of code, and a
usage table may sit between a pair and the code it belongs to — the contract asks
only that code follows before the fence closes. So there is never a reason to fold
two invariants into one claim, and folding is how three of them were lost, once in
each of three consecutive pull requests: the claim kept the strongest clause, the
section kept every argument, and the bijection compares headings, so nothing saw
it. Each was found by a reviewer reading the merge.

**What the contract does NOT check**, and cannot without becoming the scanner this
repository has twice paid to delete: whether a claim still says everything its
section argues, and whether a section still argues everything it used to. A
heading with no body at all is caught. A claim that has quietly lost a clause is a
judgement, and it is the reviewer's.

**These are not notes.** `CLAUDE.md` records that *a comment that argues against the
code beside it is an instruction, and it will be followed*. Each section below is a
defect that was shipped, found and paid for. Before changing a line the block
guards, read the section its claim names — the shape almost always looks
gratuitous until you do.

## THE TRACE IS MOVED OFF THE CAPTURE BEFORE ANY `$( )` RUNS, or xtrace lands inside the value.

THE TRACE IS MOVED OFF THE CAPTURE, BEFORE ANY `$( )` RUNS. `BASH_XTRACEFD=1`
sends xtrace to file descriptor 1 — and inside `X="$(cmd)"` fd 1 IS the capture,
so the trace of `cmd` is assigned to `X` along with its output. Measured:

    SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c 'X="$(printf hello)"; echo "[$X]"'
    [++ printf hello
    hello]

Every substitution in this block is affected — the repository root, the plugin
discovery, the `type -t` probe — so it is one property of the
block rather than a defect in any line. The validations below then reject the
corrupted values and setup aborts, which fails closed but ends a session that
had nothing wrong with it. Issue #92.

AN ASSIGNMENT, BECAUSE `set +x` IS A NAME. `set` is a builtin and a function can
shadow it, so a guard written that way leaves tracing on in the one shell state
it exists for. The parser handles an assignment and no function can take its
place — and this one needs no `unset`, which is the operation that would be
unsafe: bash CLOSES the descriptor `BASH_XTRACEFD` referred to when it is unset
or set to the empty string, so `BASH_XTRACEFD=` closes fd 1 outright. Measured
both ways on bash 5: `BASH_XTRACEFD=2` leaves fd 1 open and the capture clean;
`BASH_XTRACEFD=` kills the shell's stdout.

IT MOVES THE TRACE RATHER THAN ENDING IT. `set +x` would take the operator's
diagnostics away for the rest of their session; fd 2 is where bash sends xtrace
by default, so this puts it back where it belongs and the operator still sees
every line.

NORMALLY ONLY WHEN THE TARGET IS THE CAPTURE. A session tracing to stderr, or
to a log file on some other descriptor, writes nothing into the probe's capture,
so the condition is false and it is left as it was — `[[` is a reserved word, so
the test cannot be shadowed either. On bash 3.2 `BASH_XTRACEFD` does not exist,
the trace goes to stderr whatever this says, and the condition is false there
too.

THE EXCEPTION IS THE ACCEPTED FALSE POSITIVE, described below and repeated here
because this is the paragraph a maintainer reads as the postcondition: where
something ELSE writes into that capture — an inherited `DEBUG` trap under
`set -T` is the only thing that can — a log-file target IS moved to fd 2. That
session's captures are corrupted by the trap regardless and setup refuses
further down, so this is not a postcondition to preserve.

THE SUBSHELL IS A WRITABILITY PROBE, AND IT IS THERE FOR `set -e`. A readonly
`BASH_XTRACEFD` makes the assignment a FATAL error, not an ordinary failure: it
is not caught by `||`, not caught by an `if` around it, and under `errexit` it
ends the operator's long-lived shell where the documented outcome is a refusal
further down. Measured — all three forms exit 1 with the same message.

So the assignment is attempted in a subshell first, where that fatality is
confined, and its STATUS decides whether the real one runs. `( … )` is a parser
construct and an assignment is a parser construct, so the probe introduces no
name; a condition of `&&` is exempt from `errexit`, so a failing probe is a
skip rather than an exit. Where the variable is readonly the block does nothing
and the session behaves as it did before this guard existed.

NO POSTCONDITION ON THE REAL ASSIGNMENT, AND THAT IS DELIBERATE. Its other
failure mode is fd 2 not being open, and there bash takes the VALUE and rejects
it as a trace target, so there is no status to take and nothing to do: the trace
stays on stdout, the next capture is corrupted, its validation rejects it, and
setup stops. What the extra check WOULD add is another abort
reached through `exit` — a builtin a function shadows, so under
`exit() { return 0; }` it announces the refusal and continues anyway, with
tracing still aimed at every capture. That is the boundary #101 and #102 are
open on, and it is not one this line should quietly take a position on. The
guard is removed rather than hardened.

STDOUT IS NOT TOUCHED BY THIS. bash closes the descriptor `BASH_XTRACEFD`
referred to when it is UNSET or set to the empty string; a reassignment closes
nothing, and that is not a 5.3 behaviour: `sv_xtracefd` calls `xtrace_reset` —
the only path that closes — when the variable is UNSET or its value is EMPTY,
and takes `xtrace_set` for a valid descriptor, which replaces the target without
closing the old one. Measured on 4.4.0, 5.2.0 and 5.3.9, each built and run for
this: after `BASH_XTRACEFD=1` → `2`, ordinary
`printf` output still arrives on fd 1 and `exec 3>&1` still succeeds, while
`BASH_XTRACEFD=` produces no further output at all. `test-pr-skill-contract.sh`
asserts that on whatever bash runs the suite rather than trusting the version
this was measured on.
THE TEST IS THE EFFECT, NOT THE VALUE. `$( RB_TRACE_PROBE=1 )` puts one
assignment inside a capture: if this shell's trace lands there, the capture
comes back holding the trace of it, and if it does not, the capture is empty.
That is the exact property this guard exists for, measured directly. Why an
assignment rather than a command is two paragraphs down; the shape of the test
is the same either way.

COMPARING THE VARIABLE TO `1` WAS WRONG BY OMISSION, twice over. bash resolves
`01`, `+1` and ` 1` to descriptor 1 and a string compare misses all three —
measured. And the value is not the property anyway: an operator who runs
`exec 9>&1; BASH_XTRACEFD=9` has aimed the trace at a descriptor that is not
`1`, and one who traces to a log file has aimed it at one that is not the
capture either. A test on the number has to enumerate which descriptors alias
stdout, which is the list-that-is-wrong-by-omission shape this repository keeps
deleting. There is no list here.

IT SUBSUMES THE `x` CHECK TOO. With tracing off nothing is written, the capture
is empty, and a session that set `BASH_XTRACEFD` ready for a later `set -x`
keeps the destination it chose.

AN ASSIGNMENT INSIDE THE CAPTURE, BECAUSE EVERY COMMAND IS A NAME. `$( : )` was
the first spelling and it is wrong: a driving shell with `:() { printf marker; }`
makes the capture non-empty through the function's own output. An assignment is
handled by the parser, produces no output of its own, and is traced like any
other command. It runs in the substitution's subshell, so the variable does not
survive it.

AND THE TEST IS FOR SOMETHING ONLY XTRACE CAN WRITE. Non-empty was the second
spelling and the probe's own text was the third, and both are wrong for the same
reason one step further out: a `DEBUG` trap under `set -T` is inherited by the
substitution's subshell, so a trap that prints lands in the capture while xtrace
itself is still going somewhere else entirely. `trap 'printf "%s\n"
"$BASH_COMMAND"' DEBUG` prints exactly the probe's text, so matching that
literal cannot establish where it came from.

SO THE TEST IS "DID ANYTHING COME BACK", AND THE ASYMMETRY BELOW IS WHAT MAKES
THAT ACCEPTABLE. Marker schemes were tried — the probe's own text, then a pid
delivered through `PS4` — and each was forged by the next trap: `$BASH_COMMAND`
reproduces the command exactly, and `printf "%s:" "$$"` produces the pid. A trap
can emit any bytes, so no content test can prove provenance, and each sharper
marker added a way to MISS: an operator with `readonly PS4` made the pid scheme
blind, which is the harmful direction — the trace stays on stdout, every capture
is corrupted, and a perfectly good checkout is refused.

THE TWO DIRECTIONS ARE NOT SYMMETRIC, and that is the whole argument. A false
positive sends the trace to fd 2, which is where bash sends xtrace by default,
so every line still arrives. A false negative leaves it on stdout, corrupts
every capture below and aborts the session. So the test is the one that cannot
miss.

A DRIVING SHELL WITH NO STDERR IS OUT OF THIS GUARD'S REACH, and that is stated
rather than pretended away. With fd 2 closed, `BASH_XTRACEFD=2` is rejected by
bash as an invalid descriptor — the variable takes the value and the trace stays
on stdout — so the captures below are contaminated exactly as before. There is
no other target to choose: every descriptor that is not the capture is one this
block would have to open, and the one place a trace belongs is the standard
error that shell does not have. The consequence is the fail-closed one: a
corrupted `REPO_DIR` is not a directory, so the first thing that uses it
refuses, and no stage runs against a path that was never read.

WHERE OTHER OUTPUT REALLY DOES ARRIVE IN CAPTURES, this guard is not the cure
and does not pretend to be: a `DEBUG` trap that prints corrupts every capture in
this block, moving the trace fixes none of them, and setup refuses further down.
The session ends either way; what this line decides is only where the trace goes
on the way out.

AND NOTHING IS SAVED, BECAUSE THE SAVE IS WHAT A HOSTILE SHELL ATTACKS. Three
successive rounds found the same shape and it has no fixed point: a startup file
pre-seeds `RB_XTRACE_SAVED` — or the flag added to validate it — as `readonly`,
both assignments here fail silently, and the restore then aims the operator's
trace at a descriptor that startup file chose. Making the flag's value the pid
does not help: that file runs in THIS shell, so `$$` is as knowable to it as to
this line. Any state this block writes can be pre-seeded with the value it was
going to write.

SO THERE IS NO STATE. The trace is moved when it is reaching a capture and left
on fd 2 — which is where bash sends xtrace by default, so every line still
arrives and nothing is lost. What the removed restore bought was tidiness after
a MIS-FIRE, and a mis-fire needs something else writing into that capture. Only
a `DEBUG` trap inherited under `set -T` can: the probe runs no command, so there
is no function for a shadowed name to supply. Such a shell has
already corrupted every capture in this block, so setup refuses further down and
the session ends either way. Trading that for an unbounded regress of collision
guards is the over-building this file's own rules warn against.

WHAT IS ACCEPTED, STATED: in that shell the operator's chosen trace destination
becomes stderr for the rest of their session. `README.md` says so, rather than
leaving it to be discovered.

## THE HELPERS ARE LOCATED FIRST, because the identity parser is one of them.

THE HELPERS ARE LOCATED FIRST, because the identity parser is one of them.

`identitylib.sh` is the ONE definition of which repository this checkout is, and
it lives in `$RB_SCRIPTS`. Setup cannot source it — cannot answer the question
every later stage is addressed by — until that directory is known, so the
discovery has to come before the identity rather than after it. `pr-origin.sh`,
which reads origin where this shell's names cannot reach, is in the same
directory and has the same ordering.

That is also why the value is derived from `$CLAUDE_PLUGIN_ROOT` and validated
rather than assumed: everything below it either sources a library from here or
executes one, so a wrong directory here is not a wrong path, it is the whole
loop running somebody else's helpers.

## THE REPOSITORY ROOT IS CAPTURED WITH ITS STATUS TAKEN, or a failed read becomes a path.

`git rev-parse --show-toplevel` is a command substitution, and command
substitution keeps whatever the command printed before it failed. Written
`REPO_DIR="$(git rev-parse --show-toplevel)"` with no status check, a `git` that
emitted a plausible line and then errored leaves that line in `REPO_DIR`, and
every later stage inspects history in a tree nobody chose. So the status is taken
on the same line, and the abort names what could not be resolved.

`REPO_DIR` survives for `pr-merge-range.sh`, which inspects HISTORY rather than
identity — a tree, not a repository name. The identity itself comes from the pin,
which is why nothing else here reads this value.

## THE NEWEST INSTALLED COPY IS CHOSEN BY MTIME, not by `sort -V`, which is GNU-only.

`ls -dt … | head -1` — newest by mtime. NOT `sort -V`, which is GNU-only: on
macOS the fallback would fail before finding the scripts at all.

The discovery's STATUS is taken and the result validated. `ls` can print one
candidate and then fail on another unreadable cache entry, and `head` masks
that status anyway — so an unchecked pipeline could select a partial or stale
path, and every state, findings and merge-gate call below would then run a
different version of the helpers than the one that was installed.

## THE IDENTITY COMES FROM THE SHARED PARSER, never from a copy written out here.

THE IDENTITY COMES FROM THE SHARED PARSER, not from a copy written out here.

This was ~35 lines of origin parsing inline, and the same rules again in three
helper scripts. Both the hostless-origin rule and the file-transport rule had to
be written into all four, and the fixtures proving them had to be built a second
time to cover the copies that had silently missed one. A rule proven in one copy
is unproven in the others. See `identitylib.sh` and issue #18.

What a drifted copy costs: an origin whose host cannot be derived, defaulted to
github.com while the path split still yields a plausible `acme/widget`, points
every `gh` call at the unrelated PUBLIC repository of that name — reading,
commenting on and merging there. So the parser refuses rather than guessing: an
origin that names no host, or one whose transport reaches no GitHub server, is
not an identity.

`.` and not a subshell: `rb_identity` SETS `HOST`, `OWNER` and `REPO` rather than
printing them, because serialising three values through one string makes any
delimiter a value a remote can contain — and a remote carrying it shifts the
fields, which is the wrong-repository failure the parser exists to prevent.
The stale definition is cleared first, and the CLEARING IS CHECKED. Bash
exports functions through the environment, so a session that had already
defined `rb_identity` leaves one here before the `.` — and a library that is
empty or truncated above the definition still sources successfully. The check
below would then find the inherited function and report the parser loaded,
with every `gh` call addressed by whatever that stale version derives.

`|| true` reopened it: `readonly -f rb_identity` makes the unset FAIL and
leaves the function installed, and a discarded status makes a definition that
could not be cleared look like one that was never there. Unsetting a name that
is not defined returns 0, so a non-zero status here means only one thing.

## THE IDENTITY IS PINNED HERE, ONCE, AND EVERY HELPER INHERITS IT.

THE IDENTITY IS PINNED HERE, ONCE, AND EVERY HELPER INHERITS IT.

`rb_identity` reads `git remote get-url origin` from the CURRENT DIRECTORY, and
every helper calls it in its own process. A `cd` into a second checkout — an
ordinary thing for a driving session to do — therefore pointed the phase stages
at whatever PR of THAT repository shares this number, and each of them posts: a
signoff, a revocation, a review request.

`REVIEW_BUS_REMOTE` is the caller stating the identity rather than the library
deriving it, so exporting it removes the dependency instead of guarding it.
Wrapping each call in `(cd "$REPO_DIR" && …)` was the guard, and it was itself
defeatable: `cd` is a name, and a function named `cd` that returns 0 without
moving leaves the subshell reporting success from the wrong tree. This has no
name in it to shadow — the value is read in SETUP rather than at every call site, and
travels in the environment. (Setup reads it twice, the second time to confirm the pin is
this checkout's; what does not happen is a derivation per stage.)

`$REPO_DIR` IS STILL NEEDED, and for a different question: `pr-merge-range.sh`
inspects HISTORY, which is a tree rather than an identity, so the merge gate
keeps its own `cd`.
THE VALUE COMES BACK IN A FILE, NOT ON A DESCRIPTOR, and that is the third
mechanism this call has used. Stdout was first: a driving shell tracing to fd 1
writes its trace into the capture. fd 9 was second, with the redirections on a
group: it moved the problem to a caller tracing to fd 9, whose target the `9>&1`
then pointed at the capture. Moving the trace target instead was third and
worse — bash CLOSES the descriptor `BASH_XTRACEFD` referred to when it is unset,
so restoring it closed fd 2 and the next call in the session returned nothing.

A path has none of those properties. The operator's tracing goes wherever it
already went, the helper writes where it was told, and there is no descriptor
for the two to collide over. Measured: `$(<file)` and `read` are both clean
under an inherited xtrace, because nothing executes inside them to be traced.

`/usr/bin/env`, A PATH, BECAUSE `bash` IS A NAME. Written as `bash -p …` this
calls a function called `bash` if the driving shell has one — and such a function
writes a forged URL to the file it was handed and returns, with the helper never
running. A path cannot be shadowed. `/usr/bin/env` is the same one every script here already depends on
through its shebang, so it is not a new assumption; which `bash` it then finds is
a `PATH` question, and that is #91.

`bash -p` STARTS THE FIRST INTERPRETER PROTECTED, and it has to be the first:
privileged mode is what stops `BASH_ENV` being sourced at all, so entering it
from inside a shell that has already run the hook is too late. A hook needs to
shadow nothing to win that race: one that writes the transport file and exits is
a complete attack. There is no fallback inside the helper: it is not executable,
it carries no re-exec, and a missing `-p` is refused — by then the hook has
already run, so nothing in the file can recover from it.

READ THROUGH A HELPER, BY PATH, BECAUSE `git` IS A NAME. This was
`git remote get-url origin` here, and a function answering only
`remote get-url origin` forged the identity every stage is then addressed by —
successfully, with a plausible value. `"$RB_SCRIPTS"/pr-origin.sh` is a PATH, so
no function can stand in front of it, and `bash -p` means no startup hook is
sourced and no inherited function is imported in the first place. #84.
THE TRANSPORT IS A DIRECTORY, AND THE HELPER IS WHAT CREATES IT. `watch-pr-origin.$$`
was a FILE this setup named and the helper truncated, and that name is
predictable from another account on the machine: pre-created as a world-writable
file or as a symlink, the helper wrote through it and the value read back — the
one every later signoff, revocation and review request is addressed by — was
whatever that account left there. A directory created with `mkdir` answers it,
because `mkdir` FAILS if the name exists: a directory, a file and a symlink
alike. That exclusion is the helper's since #157, along with the ancestry walk
and the write, so all three run privileged, where `mkdir` is not a name an
operator's startup file can replace.

TWO DIRECTORIES, NOT ONE, AND BOTH LEFT WHERE THEY ARE. The origin read and the
pin probe are separate calls at separate times, and the second is behind the
first's success. NEITHER IS REMOVED AFTERWARDS: both names are published in argv,
and unlinking through one takes a replacement's own object — the class
`docs/decisions/2026-08-29-setup-leaf-cleanup.md` tabulates, reached here from
the driver's side. `-m 700` is applied by `mkdir` itself, so there is no interval
between creation and use in which anything can be placed inside.

THE PATH IS BUILT, NOT CAPTURED. `$(mktemp -d)` would name the directory in one
line, and a driving shell tracing to fd 1 would put the trace of `mktemp` inside
the value — so the variable holds trace text and a path, and the helper cannot
open it. `$$` and `$RANDOM` are the shell's own, so nothing runs and there is
nothing to trace. Three `$RANDOM` draws make the name unguessable, and the
exclusion — `mkdir` refusing a name that exists — is what makes a guess harmless
rather than a path written through.

WHAT THE RANDOMNESS DOES NOT STOP is squatting by an account that does not have
to GUESS. The candidate is an argv entry, published by `ps` and `/proc` the moment
the helper starts, so a watcher can create the name in the interval before the
helper's `mkdir` and make setup refuse — repeatably, for as long as they watch.
`pr-origin.sh` states that window where it reserves the name, and #160 carries the
protocol change that would close it.

THE CONSEQUENCE IS FAIL-CLOSED, AND CONTROL FLOW IS WHY. The squatted object is
the attacker's — the helper's `mkdir -m 700` FAILS rather than creating or
re-moding anything, so its mode is whatever they chose and proves nothing.
What stops the value being read from it is that the read below is inside the
helper's status-0 arm: a refused call does not reach it. Setup stops, and
nothing is forged or pinned.

THE PARENT HAS TO BE ONE NOBODY ELSE CAN REPLACE THE DIRECTORY IN, and mode 700
does not give that. It protects what is INSIDE the directory; it says nothing
about the entry naming it. On a shared `TMPDIR` that another account can write
and search and that lacks the sticky bit, that account can watch for the name,
RENAME the directory without ever entering it, and put a writable one of its own
at the same path — after which the helper writes `origin` into the replacement
and the value read back is theirs. The random suffix stops the name being
pre-created and does nothing about it being observed and then replaced.

WHO MAY RENAME THE DIRECTORY IS THE QUESTION, AND THE HELPER ANSWERS IT. Checking
a path and then opening it are two operations on a name, and whoever controls the
directory controls what the name means in between. That rule lives in
`pr-origin.sh`, which walks the whole ancestry as written and as it resolves —
ownership, group- and world-writability without the sticky bit, and the `+`/`@`
marks that show an ACL the mode bits do not. It is NOT the same as "owned by this
user": root-owned and sticky — `/tmp` — is safe, and an attacker-owned sticky
directory is not, because sticky says nothing about its OWNER renaming ours.

WHAT IS DECIDED HERE IS ONLY WHETHER A PARENT CAN BE TRIED AT ALL. Absolute,
because a relative path cannot be walked to the root and the helper refuses one —
and a relative but perfectly usable `TMPDIR` such as `.tmp` selected here and
refused there ended a session that had a working fallback next to it. A
directory, because a name that is not one cannot hold a transport. Writable and
searchable, because "can hold a directory" is what the fallback to `HOME` is FOR
and `-d` does not answer it: `/usr` satisfies `-d`, was committed to, and the
helper's `mkdir` then failed. None of the four is a SAFETY rule; the safety rules
are the helper's, in one place, and this stopped deciding them after an owned
mode-0777 `TMPDIR` passed an `-O` test here and was rejected there.

SO AN ANCESTRY REFUSAL IS REPORTED, NOT ROUTED AROUND. The two-candidate loop
this replaced tried `HOME` whenever the helper refused, which meant it also
retried after a bad ORIGIN — where `HOME` is just as bad — and it could only
work by re-asking the safety question here. A `TMPDIR` whose ancestry is unsafe
is a state an operator has to SEE named, and the helper names which component and
why.

THE NAMES THAT ARE LEFT ARE PROVED ASSIGNABLE BEFORE ANYTHING USES THEM. There
were five — `RB_TMPPARENT`, `RB_TRY`, `RB_TMPDIR`, `RB_ORIGIN_OUT` and
`RB_PIN_OUT` — each with a probe and each a thing this shell had to defend, and
there were two stages with a probe apiece. ELEVEN are probed now, in ONE probe:
`RB_TMPPARENT`, `RB_TMPPARENT2`, `RB_SETUP_DIR`, `RB_PIN_SEEN`, `RB_REMOTE`, the two
reviewer logins and the four working-file names. The list grew because the block
ASSIGNS more than it used to — the helper hands back one value, so everything else
is this shell's own — and the rule is the one stated below: every name this block
assigns is in it. The helper owns the rest, and since #228 it owns the whole second
stage as well, so there is one probe rather than two. A readonly or
value-transforming one in the long-lived driving shell survives an assignment and
leaves a STALE value behind, and a stale `/somewhere/owned` then passes every
check: its `origin` is read as this session's remote, and every stage after it is
addressed at whatever repository that names.

A SUBSHELL, ONE MIXED-CASE VALUE, COMPARED INSIDE. The subshell inherits the
attribute, so a readonly fails there and a `declare -i` or `declare -l` stores
something else and the comparison catches it — and as an `if` CONDITION the
failure is contained, which a bare assignment is not: under `errexit` a failed
readonly assignment ends the session where it stands. #151.

AND IT READS ANOTHER NAME BACK, because reading its OWN back cannot see an
ALIAS. `declare -n RB_SETUP_DIR=RB_REMOTE` passes an assign-and-read-back probe
perfectly: the assignment works and the value returns. The two are then the SAME
VARIABLE, so the read — which sets `RB_REMOTE` — silently changes
`RB_SETUP_DIR` under the checks that follow, and the working paths are then
proved against a literal built from a directory that is now the remote URL.

DISTINCT VALUES ARE WHAT MAKES IT VISIBLE, which is the pattern `clocklib.sh`
already uses and states: one value says nothing about whether two names are one
variable. `RB_REMOTE` was cleared and proved clear immediately above, so it
holds the empty string — writing a sentinel here and finding it there was an
alias, and finding it unchanged was not. That comparison is GONE, replaced by
`${!name}`, which asks the same question without naming the other side: for a
nameref it expands to the TARGET'S NAME, and for an ordinary variable it is
indirect expansion of a name nothing has set. One line, no list, and it catches
targets no list would have carried.

WHAT IT COVERS, STATED WITHOUT A LIST. There are no pairs any more: the probe
names ONE variable — the one it is about to assign — and asks whether that
assignment reaches anything else. Which "anything else" is not this file's
business, and that is the improvement: `RB_REMOTE`, the other transport name, the
operator's `HOME`, `GIT_DIR`, `CDPATH` and whatever the next tool reads are all
the same answer.

`2>/dev/null` because a nameref loop is a message, not an answer.
THE VALUE THIS SESSION PINS BY IS CLEARED AND PROVED CLEARED HERE, ABOVE THE
TRANSPORT REGION AND OUTSIDE IT. A readonly `RB_REMOTE` already in the driving
shell survives the assignment further down, and the checks after it — non-empty,
single-line, parseable — all pass on the stale URL, which is then exported and
addressed by every later post.

ABOVE, BECAUSE A COMPOUND COMMAND TAKES THIS DIAGNOSTIC AWAY. Inside the `if`
below, a failed readonly assignment ends the shell BEFORE the test that would
have named the variable — measured, and caught by the suite. Nothing here needs
the transport directory, so nothing here belongs inside it; and with the clear
proved out here, the arm contains no assignment a startup file can have frozen.

NOTHING TO CLEAN UP, EITHER. This used to sit after the directory existed, so
its refusal removed the transport file and the directory; up here there is
neither, which is two fewer commands taking a path from a variable.

## `-w` AND `-x` AS WELL AS `-d`, because "can hold a directory" is what the fallback is for.

`-w` AND `-x` AS WELL AS `-d`, because "can hold a directory" is what the
fallback is FOR and `-d` does not answer it. An absolute, existing but
unwritable `TMPDIR` — `/usr` is one — passed `-d`, was committed to, and
the helper's `mkdir` then failed with a usable `HOME` sitting next to it.
The candidate loop this replaced did fall through in that state.

AND WHAT `-w`/`-x` STILL CANNOT SEE: they are MODE BITS. A `TMPDIR` that
passes all three can fail to hold a directory anyway — an exhausted quota,
a full filesystem, a read-only mount, a name another account got to first
— and it can accept the directory and refuse the BYTES written into it,
which is the same failure one step later. THE RETRY BELOW IS WHAT COVERS
BOTH: the helper reports 2 for either, the retry reads that status in its
own condition, and both attempts join into one success arm — a branch on
the status OUTSIDE the arm is the walked-past-guard class this block
exists to close, and there is not one. #161.

WHAT IS NOT RETRIED, AND WHY. A parent whose ANCESTRY the helper refuses —
another account owning a component, a world-writable non-sticky one, an
ACL — is reported rather than silently routed around. Deciding it here
means a second copy of that walk in the one shell nothing can harden,
which is the removal this whole change is; and a `TMPDIR` whose ancestry
is unsafe is a state an operator has to SEE named, not one to step past
into `HOME`. The helper says which component and why.
BOTH PARENTS ARE KEPT, not just the first usable one. The mode bits
`-d`, `-w` and `-x` describe neither a filesystem that is full, over
quota or read-only nor a name another account got to first, and any of
those refused the session with `HOME` sitting beside it untried, because
the fallthrough happened on the BITS and not on the failure. #161.

## THE SAME PARENT TWICE IS NOT DEDUPLICATED, because two random leaves are two usable names.

THE SAME PARENT TWICE IS NOT DEDUPLICATED, deliberately. The two leaves
carry INDEPENDENT random suffixes, so two candidates under one parent are
two usable names — and a name another account got to first is exactly the
failure the retry recovers from. Clearing the second here would turn that
case back into a refusal.
AND AN EMPTY PARENT CANNOT PRODUCE A PATH AT ALL. Written as
`[[ -n $RB_TMPPARENT ]] || { echo …; exit 1; }` this was a GUARD, and
`exit` is a name a startup file can replace with one that RETURNS: the
refusal printed, the next line built `/watch-pr.…` from the empty value,
and for a root operator the helper could create it — so setup read an
origin from the filesystem root and went on to announce success. The
expansion is not a guard and has no name in it: `${VAR:?}` is the SHELL
refusing to expand, and in a non-interactive shell it ends the shell
where it stands whatever `exit` has become. Interactively it abandons
only its own command, which leaves the variable unset and the helper
refusing an empty argument — the same answer one step later.
CLEARED FIRST, BECAUSE AN ABANDONED ASSIGNMENT LEAVES THE OLD VALUE.
INTERACTIVELY `${VAR:?}` abandons only the command it is in — the shell
survives — so with a STALE `RB_SETUP_DIR` from an earlier run in the
same long-lived shell, the refusal fired and the helper was then invoked
with the previous session's path. Clearing it immediately before means an
abandoned assignment leaves EMPTY, and an empty argument is one the helper
refuses by name. That is a removal rather than a guard: there is no
condition here for a shadowed `exit` to walk past, because there is no
value left to walk past it WITH.

## THE RETRY IS A SECOND CALL, NOT A SECOND CANDIDATE PASSED TO ONE.

A SECOND ATTEMPT UNDER THE OTHER PARENT, AS A SECOND CALL — which is the
whole design and not a detail.

THE ALTERNATIVE WAS ONE CALL TAKING BOTH CANDIDATES, and it cannot work
from here. The helper cannot TELL this shell which of the two it used: a
second success status would put a status branch outside the arm holding
the read-back, and a line on a stream would put the value's own channel
into a capture. So the driver would have to GUESS — and the candidate
names are argv, published at `exec`, so every test of that name on a
parent another account can write is a check-then-use. Three of them were
built and refuted in that order: the leaf existing, `-O` on the leaf
descriptor (a symlink to another operator-owned transport passes it), and
`[[ ! -L ]] && [[ -d ]] && [[ -O ]]` on the directory (alternate the entry
between the two and the sequential probes disagree). There is no `openat`
here to anchor the identity. #161, #176.

THE STATUS IS READ WITHOUT LEAVING THE `if`. `$?` after a failed condition
is that command's, `[[` is a reserved word, and the read-back stays
contained in the success arm below — so the distinction is usable without
anything becoming a statement after a guard. And the arm knows exactly
which directory the helper created, because `RB_SETUP_DIR` names it and
the retry REASSIGNS it before calling again: there is nothing to guess and
therefore nothing to race.

THE READ-BACK IS WRITTEN ONCE, and reassigning that name is what buys it.
The shape before was an `elif` with an arm apiece, each spelling the
read-back for its own directory. A function would have held it once and
cannot be used: `return` is a name a startup file can replace with one
that does not return, and `readonly -f` makes this document's own
definition fail so an inherited one runs. `CLAUDE.md`
records both. Naming the directory in a variable both attempts read is
what removed the duplication a function could not.

AND A REFUSED FIRST ATTEMPT HAS ALREADY SAID WHY, on the helper's stderr,
naming the component and the reason. That is what makes retrying under
the other parent honest rather than a silent route around it — which is
the defect the old candidate loop had. The note below says a retry
happened; the helper's line above says what it is retrying past.
NOTHING RUNS IN THIS ARM THAT IS NOT A REDIRECTION OR AN EXPANSION, and
the announcement that used to is why it is stated. A note here is an
`echo`, and `echo` is a NAME. In the CONDITION, a function by that name
runs immediately before `$RB_SCRIPTS` and `$RB_TMPPARENT2` are expanded
for the retry and can point both at a script and a parent of its own.
Moved after the read it is no better: it then runs before the non-empty,
single-line, identity and export checks, and a function that assigns
`RB_REMOTE` replaces the value that was just authenticated. There is no
third position — every one of them is before something that trusts a
variable — and no command-free way to print, since `${VAR:?…}` terminates.

SO THE RETRY IS NOT ANNOUNCED, and what makes that acceptable is that the
REFUSAL is: the helper's own `ABORT:` line named the directory and the
reason before this arm was reached. What the operator does not get is a
line saying which parent the session ended up on. The abort further down
covers the case where both failed.
`$?` IS THE FIRST CALL'S STATUS, AND IT IS READ INSIDE THE `if`. That is
what makes the distinction usable: 2 means both ancestry walks passed and
the STORAGE would not take what the helper asked of it — the directory
could not be created exclusively, or the leaf inside it could not be
written, which is the same failure one step later. A full filesystem, a
quota, a read-only mount, a name another account got to first. And 1
means the refusal was about the PATH or the checkout, which another
parent does not fix and an operator has to see named.

NOT A BRANCH OUTSIDE THE ARM. `|| { [[ $? -eq 2 ]] && … && helper …; }` is
part of this same `if`'s condition, so the read-back below stays contained
in its success arm — nothing here is a statement after a guard, which is
the shape #155 and #158 removed. `[[` is a reserved word and `$?`
is a shell parameter, so neither is a name anything can take.

AND `$?` IS TAKEN BEFORE ANYTHING ELSE RUNS, which is why the emptiness
test comes second: a command between the two would replace it.

## ONE LINE, OR IT IS NOT A REMOTE — an interior newline means the value is not an origin.

ONE LINE, OR IT IS NOT A REMOTE. Kept as the last check on a value the whole
session is addressed by. Nothing known still writes to this stream — that is
what the invocation form buys — so this now guards the unknown rather than the
tracing case it was added for.
AND THIS ONE CLEARS THE VALUE AND THEN EXPANDS IT, because `${…:?…}` fires on
empty and there is no other state it can be given. The `||` takes an
ASSIGNMENT rather than a group: an assignment is handled by the parser, so
nothing can shadow it, and the line below is then the same shell-level
refusal every other one in this block is — carried by an assignment too,
because `:` is a name and on the ordinary path that expansion succeeds. #181.

THE VALUE IS NO LONGER IN THE MESSAGE, and that is the price. It cannot be:
the word is expanded after the clear. Printing a multi-line value into the
terminal was never much of a diagnostic anyway, and what the operator needs
is which check refused.
AND THE PATTERN IS `$'\n'`, ON ONE LINE. It was a quoted string spanning two
source lines, and the second was INDENTED to match this block — so the
pattern was a newline followed by four spaces, and `%%` stripped nothing from
a value whose second line began with anything else. The comparison was then
true and a multi-line origin passed the check that exists to refuse it.
Measured: staging one reached the pin. #183.

A CONTAINMENT TEST, NOT A STRIP-AND-COMPARE. `[[ $V = *$'\n'* ]]` asks the
question directly, and `[[` is a reserved word with the quoting handled by
the parser — there is no second expansion to get the indentation of wrong.
The old form said the same thing twice and only one of them was right.

AN INTERIOR NEWLINE IS THE STATE, which is why this reads the value rather
than the file. `$(<…)` strips TRAILING newlines, so a well-formed origin
never carries one and anything left is a second line.

## A COMMAND PREFIX, NOT THE EXPORT, so the driver and its children cannot disagree.

A COMMAND PREFIX, NOT THE EXPORT. This derives the DRIVER's own identity from
the same value the children will be pinned to, without depending on the export
having succeeded — so the two cannot disagree. The export itself is the last
thing this block does; see the end of it for why.

AND ITS REFUSAL IS THE SAME SHAPE AS THE TWO ABOVE: the failure clears
`RB_REMOTE` with an assignment, and the expansion below is the shell
refusing. `$RB_IDENTITY_REASON` is expanded into the word, so the parser
message still names which rule the origin broke. #181.

## THE CI KNOBS ARE EXPORTED, because a child process is what reads them now.

THE PUSHED HEAD MUST NOT BE RED BEFORE A ROUND IS CLOSED.

CI was red for four consecutive commits on one PR and neither the round loop nor
the pre-push self-check noticed: every round was closed as green on the strength
of a local suite run, and the operator had to point at the checks tab.
`pr-selfcheck.sh` runs the suite HERE, before the push — it cannot see a failure
that only happens on the runner, and that one only happened there. "The suite
passes here" and "the checks pass there" are different claims, and only the
first was ever being made.

THE GATE IS A SCRIPT, not a function defined here.

It was ~100 lines of shell in `SKILL.md`, pasted into your session and called from
four sites in it. Nothing checked it: the suite, `pr-selfcheck.sh` and the
bash 3.2 CI job all cover `scripts/`, and none of them can see shell inside a
Markdown file — `test-pr-skill-contract.sh` had to `sed` the function back out of
`SKILL.md` to execute it at all. It also needed a clear-and-verify dance
around its own definition, because a `readonly -f` copy left over in your shell
would silently survive an `unset -f` and a stale gate returning 0 lets a red head
close its round. A script cannot be shadowed that way, so all of that is gone
with it. Issue #26.

`pr-ci-gate.sh <pr> <head-oid>` — 0 carry on, 1 stop. Same bounds, same
`PR_CI_*` knobs, same diagnostics.

THE KNOBS ARE EXPORTED, because a child process is what reads them now. A
function saw `PR_CI_TIMEOUT=3600` assigned in your shell whether or not it was
exported; a script does not, and would have gone on using the 1800-second
default while the terminal showed the value you set. That is the one behaviour
the move could have changed silently, so it is handled here rather than at each
of the four call sites.

## ONE NAME PER CALL, because `export` is a name this shell may have wrapped.

The six knobs are exported one statement at a time rather than as
`export A B C D E F`, and the difference is not style. This block runs in the
operator's own shell, where `export` can be a function; a wrapper as ordinary as
`export() { builtin export "$1"; }` passes the first name and drops the rest.
Measured: the six-argument call exports `PR_CI_INTERVAL` and nothing else, while
six calls export all six.

WHAT THAT COSTS is `REVIEW_MERGE_STRICT`, and it costs it SILENTLY — no status,
no message, and the knob simply absent from every child. The other five make the
gate slower or more talkative; that one makes it merge with `--admin` instead of
handing the decision to GitHub, which is the bypass the operator set it to remove.

IT WAS A `for` LOOP BEFORE, over a variable of its own, and that shape had the
same failure by another route: with a nameref at that variable in the operator's
shell the `for` RETARGETS it rather than writing through — measured, the aliased
target keeps its value — after which the loop's own expansion is empty, every
`export ""` fails with `not a valid identifier`, and no knob reaches any child.
Silently again, the guard's `&&` list being exempt from `errexit`. Removing the
variable removed that; writing one name per call removes the other.

`REVIEW_MERGE_STRICT` IS IN THIS LIST FOR THE SAME REASON, and it is the one
that matters most: it is the knob that makes the merge SAFER, by handing the
decision to GitHub instead of merging with `--admin`. Losing it at the process
boundary does not fail — it silently restores the very bypass the operator set it
to avoid. The lesson was already learned for the CI bounds; this was the instance
it did not get applied to.
`RB_SUITE_JOBS` IS HERE FOR THE SAME REASON AND NOTHING MORE. `pr-selfcheck.sh`
runs the suite concurrently and takes its degree from that name, and step 5a
starts it as a CHILD — so an operator who lowers it in this shell without
exporting it watches the gate go on running four at a time while the terminal
shows the value they set. The quiet kind of wrong, like the CI bounds above.

## THE PIN IS THE LAST THING SETUP DOES, AND SETUP SAYS SO OR SAYS NOTHING.

── THE PIN IS THE LAST THING SETUP DOES, AND SETUP SAYS SO OR SAYS NOTHING ──

`REVIEW_BUS_REMOTE` is what every helper inherits, and every post is addressed
by it — `record`'s signoff, `open`'s revocation and review request, and the
second signoff `close` writes on the two-reviewer path. (`close … codex-only`
records nothing: there was no Copilot review to re-check.) So its failure
has to end setup, and "ends setup" cannot rest on another name.

A `readonly REVIEW_BUS_REMOTE` already in this long-lived shell makes the export
fail; a function named `exit` makes the abort return instead of exiting. Either
alone is caught below. TOGETHER they are not, if there is anything after them to
run: the guard's last line ends the `if` non-zero, but with no `set -e` the next
statement simply executes. That is why nothing comes after this — the position
is the guard. Do not add a step below it.

AND "ABOVE IT" WAS NOT ENOUGH EITHER, WHICH IS WHY THE WORKING FILES ARE INSIDE
ITS SUCCESS ARM. Allocated above, their own refusals fell into THIS block with
`exit` replaced — and the completion line then reported a finished setup naming
paths that were unset or somebody else's. Position guards what comes after a
failure; only containment guards what comes after a failure that could not stop
the shell. So the allocation is nested here, and the completion line is nested
inside IT.

THE SUCCESS LINE IS INSIDE THE SUCCESSFUL BRANCH for the same reason. It is how
the driver knows setup completed, so the failure path does not REACH it, whatever
`exit` has been replaced with.

"NOT REACHED" IS THE CLAIM, and it is deliberately weaker than "cannot be
emitted". `echo` is a name too: a function replacing it can print `OWNER=…` from
the ABORT below, or from anywhere else, and no arrangement of statements inside
this shell prevents that — the alternative is a failure path that says nothing
at all, which trades a real diagnostic for a guard against a shell that is
already lying about its output. What survives a forged `echo` is the STATUS: the
branch still ends non-zero. Removing the dependency means not composing this
message here, which is #84 along with `git` and `bash`.

## WHAT THE PIN PROOF PROVES, AND WHAT IT CANNOT, stated because review walks up to it every time.

WHAT THIS PROVES, AND WHAT IT CANNOT — the boundary is here because several
rounds of review walked up to it and it is cheaper to state than to
rediscover. #102.

IT PROVES A CHILD INHERITED THE PIN, which is the failure it was built for:
an `export` that assigns without setting the export attribute leaves this
shell holding the right value while every helper holds none, and a `cd` into
a second checkout then retargets every stage. That is #80, it is an ACCIDENT
rather than an attack, and asking a real child is what catches it.

IT DOES NOT PROVE ANYTHING AGAINST A FUNCTION IN THIS SHELL, and no
comparison written here can. `export` is a name, and one that MUTATES its
operand —

    export() { RB_REMOTE='git@github.com:WRONG/other.git'
               builtin export REVIEW_BUS_REMOTE="$RB_REMOTE"; }

— makes the child report the forged value and this line compare forged with
forged. Measured. A SECOND `pr-origin.sh read` was built to compare against
the repository instead, and it is not in this file because it bought exactly
one thing: an attacker who knew one variable name and not the other. The same
function rewrites both; it can also `cd` first, so a later read agrees with
the forgery, and an earlier one is just another variable. Every value this
shell holds is nameable, and the function runs at a point of its own
choosing — so there is no ordering and no extra child that makes the
comparison mean more than the shell it runs in. `SKILL.md` itself is a file
such a shell can edit, which is the same boundary `pr-origin.sh` § WHAT THIS
DOES NOT CLOSE and #91 draw.

NON-EMPTY AS WELL AS EQUAL, and the emptiness is the half that matters here.
A refusal walked past with `exit` shadowed leaves `RB_REMOTE` empty, the pin
probe reports empty because no child was asked, and `"" = ""` SUCCEEDS — so
setup announced success with no `REVIEW_BUS_REMOTE` at all, and every later
stage derived its identity from wherever the session happened to stand.


## AND THE PIN IS THIS CHECKOUT'S ORIGIN, or the stage refuses.

A separate invariant from the one above, and it needs its own claim because the bijection
compares HEADINGS: folded into "what the pin proof proves", removing the re-read would
leave every declared claim apparently intact.

What the proof above answers is whether a CHILD inherits the exported value. That is about
the export, not about where the value came from — and the value came through a file the
driver opened after `pr-setup.sh` had exited, which a same-UID process can replace in
between. `rb_identity` does not close that either: it asks whether a string is a usable
identity, not whether it is this checkout's, so a planted-but-valid remote satisfies both
by being what both are computed from.

So `pr-origin.sh pin` re-reads the checkout and refuses a value that is not its origin.
That question can only be asked there: `git` is a name in this shell and is not one in a
privileged helper. It compares the FETCH url — `remote.origin.url`, which is the identity
every `gh` call is addressed by — and not the push destination, which `pr-close-round.sh`
validates separately and which this does not replace.

The swap is not prevented; a value still reaches the driver. What it can no longer do is
address a session. #230.

## THE ACCOUNT IS PROSE, AND MUST NOT BECOME A RECORD, A REQUEST, OR A FRAGMENT.

THE BODY IS PROSE AND MUST NOT BECOME A RECORD. It is posted under YOUR identity,
which `pr-signoff.sh` and `pr-round-count.sh` trust — so a line reproducing one of
the markers they honour, coming from you, CREATES the record it was quoting. A
finding quoted verbatim about a signoff becomes the signoff; a quoted
acknowledgement becomes the acknowledgement, and the round boundary it answers
never fires again. The script refuses such a body rather than publishing it.

`**Reviewed commit:**` is NOT one of them, and is left alone deliberately: it is
read only from a reviewer bot's own comment, so writing it here creates nothing.
Listing it as forbidden would be a rule with no failure behind it.

THE MARKERS ARE HONOURED AT THE START OF A LINE, so indenting by four spaces or
quoting inline is enough. A FENCE DOES NOT HELP — the readers scan the raw comment
body, where a line inside a fence still begins at column 0.

AND IT MUST NOT CONTAIN `@codex review`. Any comment containing that text requests
a Codex pass. This summary is posted on its own and the loop stops immediately
after it, so a quoted mention starts a pass that answers nobody and burns the
round. In a Codex ROUND the mention IS the request and `pr-close-round.sh` writes
it itself, so quoting it there changes nothing — which is why the rule is stated
here and not there.

THE REMEDY IS NOT THE SAME ONE, and that is the point of separating them. The
trigger is matched case-insensitively ANYWHERE in the body rather than at the
start of a line, so indenting it, quoting it inline or fencing it changes nothing
and the summary is still refused. Break the mention up, or write it without the
`@`.

THE WRITE IS CHECKED, not only the read the script does. A redirection that
truncates the file and then fails — a full filesystem — leaves a non-empty
FRAGMENT which passes the script's own non-empty test and is posted as this
phase's account. A failed open leaves the PREVIOUS round's contents there to be
posted as this one's. Neither is distinguishable afterwards from an account
somebody wrote.

## WHICH REPOSITORY THIS ACTS ON IS SETTLED IN THE SETUP BLOCK, not here.

The session's origin is read at setup and exported as `REVIEW_BUS_REMOTE`, which this
stage and everything it drives inherit — so this call has no cwd dependency and needs no
wrapper. It is read a SECOND time before the session starts, by the pin, which refuses a
value that is not that checkout's origin; both reads happen in setup and neither is
repeated here.

Do not add one. A `(cd … && …)` guard here is what the pin replaced, and `cd` is a
name a function can take; a list of call sites to wrap is missing the next one,
which is the shape `CLAUDE.md` records paying for twice.

## PROVED STILL OPEN THREE TIMES, AND THE ORDER IS revoke, prove, baseline, request.

`open` proves three things, and all three are needed because NONE of them requires
the head to move:

- the head is unmoved;
- Codex's LIVE verdict on that sha is clean — a recorded signoff is history, and a
  review dismissed while the head stood still leaves head-equality passing;
- the RECORDED Codex signoff still names it — a revocation is how a phase is
  deliberately reopened, and GitHub serves the old clean verdict until the new pass
  reports, so the verdict alone cannot see it.

It re-enforces the ROUND BOUNDARY too, which is why `open` can return 3: the
signoff is published before `record` pauses, so a later session can resume straight
into this stage with the boundary unacknowledged.

ALL OF IT RUNS THREE TIMES — up front, before the revocation, and again after it —
because another session can change any of it while the probes in between are
running, and the revocation is itself a mutation with the request still to come.

THE ORDER IS revoke → prove → baseline → request. Two constraints pull against
each other: the proof wants to be last, and the Copilot BASELINE must be last or a
pass landing in between is accepted as the answer to a request made after it. This
is the proof as late as the baseline rule allows.

THE SESSION PIN COVERS THIS STAGE TOO, and it is the one where getting the
repository wrong costs most: `open` posts a signoff revocation and requests a
review. Both are inherited from the setup export rather than decided by the current
directory, so there is nothing to wrap here either.

## THE MODE IS SET BEFORE ANYTHING IN STEP 8 RUNS, and `codex-only` is not a skip.

`codex-only` means no Copilot review was ever requested, so there is no verdict to
re-check and no second signoff to record. The stage SAYS so and does nothing,
which is not the same as being skipped: a stage that is not run leaves no record
of why, and the next reader cannot tell a deliberate one-reviewer merge from a
phase somebody forgot.

`$CODEX_SHA` is passed as well as the head being read, because whether the two are
EQUAL decides which question the stop asks. The fault-tolerance pass is offered
only where the Copilot phase produced commits — where the two shas are the same,
Codex has already reviewed exactly what is being merged, and taking a pass there
costs a revocation, a round and a reopened phase for a verdict that cannot differ.
A session resuming into that reopened phase reads it as a Copilot phase to run
again. #55.

## THE SESSION PIN SETTLES THE REPOSITORY HERE AS WELL, and the gate below is another question.

`close` posts a signoff, and which repository it posts to comes from the pin the
setup block exported — not from the current directory.

The merge gate further down still runs from `$REPO_DIR`, and that is not an
inconsistency: it hands `pr-merge-range.sh` a TREE to inspect, which is a question
about history rather than about identity, and the pin says nothing about which
tree is on disk.

## `[[`, A RESERVED WORD, NOT `[` — and the branch ends in one too.

This runs in the driving session's own shell, which is long-lived and where a
function named `[` can already exist — it shadows the builtin and the `command`
and `builtin` prefixes alike. One returning success turns a failed close into a
successful one, and the driver carries on with no signoff recorded and no operator
stop.

A shadowed `exit` neutralises the abort the same way, so the branch ends with a
structural sentinel that is non-zero whatever `echo` and `exit` have been replaced
with. Both halves are needed: the reserved word decides whether the branch is
ENTERED, and the sentinel decides what it reports once it has been.

## THE PHASE IS A FACT ON THE PR, NOT SOMETHING A SESSION REMEMBERS.

`record` writes a signoff precisely so a later session can read it back, and
`pr-phase-state.sh` is that reading: it takes the two signoffs and the head,
selects which stop is being resumed from, and re-validates the record that has to
still stand — the head must BE the Codex commit before the Copilot phase, and the
COPILOT commit after it, where the head has advanced through Copilot fixes by
design.

## READING IT IS A HELPER, because 112 lines here exited 0 on every refusal.

Three arms and six refusals lived in this fence, and nothing executed them. Every
abort exited 0, so "the phase is not closed" and "this ran correctly" were the same
status to anything that read it — which is the whole of what a caller has to go on.

In `scripts/` the suite covers it, `pr-selfcheck.sh` gates it, and the statuses are
asserted. Issues #123 and #26.

## THERE IS NO STATUS VARIABLE; THE STATUS IS BRANCHED WHERE IT IS PRODUCED.

Written as `if …; then RC=0; else RC=$?; fi` and then a `case "$RC"`, a startup
file that had already made that name readonly with the value 0 caused BOTH
assignments to fail while leaving it at 0 — and a helper that returned 1 or 2 was
sent through the continuation into the merge flow.

A failed assignment does not even fire an `||`, so there is no status to take. The
answer is not to guard the variable but to have none.

`$?` in the `else` arm is the CONDITION's, read before anything else can change
it.

## THE CONTINUATION IS THE `then` BRANCH, and nothing follows it.

This bash runs in YOUR shell, which nothing here controls — `exit` is a builtin a
function can take the place of, and one that RETURNS instead of exiting leaves a
refusal falling straight through into whatever came after it.

Nothing follows, so there is nothing to fall into; and each refusal ENDS in a
reserved word, so it reports non-zero even with `echo` and `exit` both taken away.

## THE HELPER RUNS AS A CONDITION, which is what exempts it from `errexit`.

Not a simple command whose status is read afterwards. If the shell has `errexit` on
— this block is pasted into one as often as it is typed — a simple command that
exits non-zero ends the shell before anything can read its status, so the 1/2
distinction is lost at exactly the two statuses it exists for.

## THE SHA THE GATE IS PINNED TO, its status and its shape both checked.

By the same idiom step 7 uses: `sha` asks for the head alone, so nothing here
parses a record line.

The status AND the shape, because neither covers the other and this value is what
every gate below is measured against. A status of 1 with an empty answer is a
phase that is not closed; a status of 0 carrying something that is not 40 hex
cannot happen through the helper, and is checked anyway, because a gate pinned to
an unvalidated value is a gate in name only.

## THE LAST WORD IS A RESERVED ONE, and this branch needs it as much as step 7's.

`echo` and `exit` are builtins a function can shadow, and with both shadowed this
branch says nothing and returns 0 — a failed read indistinguishable from a resumed
phase. `[[ … ]]` is a reserved word, so the block ends non-zero whatever was done
to the builtins.

## THE GATE IS A SCRIPT.

It was 291 lines here, pasted into your shell, and nothing checked it — which is
how it came to contain a construct the bash macOS ships cannot PARSE, for fifty
review rounds. `scripts/` is covered by the suite, by `pr-selfcheck.sh` and by the
bash 3.2 CI job; a fenced block is not a file any of them has.

COVERAGE FALLS BY LIFT, NOT BY FILE. What reaches what is left in the document is
`test-pr-skill-contract.sh`, which LIFTS AND EXECUTES the blocks it knows about
rather than reading them — and both CI jobs run it, so those blocks are parsed and
run on bash 3.2 too. The parse defect above would be caught there today. A block
nothing lifts has none of that.

#26 measured whether the rest could move into `scripts/` instead and answered no:
what remains has to run in the operator's shell.

## RUN FROM THE REPOSITORY THIS SESSION STARTED IN.

The gate resolves its own repository root from the CURRENT DIRECTORY, and hands
that tree to `pr-merge-range.sh` — which decides whether every commit since the
reviewed sha is a `Review-Phase: copilot` fix. Run from another checkout, the range
is computed over history that has nothing to do with this pull request, and a merge
is licensed or refused on the wrong commits.

WHICH REPOSITORY IT ACTS ON IS NOT WHAT THIS PROTECTS. That is settled by the
session pin: `rb_identity` prefers the exported `REVIEW_BUS_REMOTE` over
`git remote get-url origin`, so a `cd` cannot retarget the gate's GitHub calls or
the `--admin` merge. Reading this as an identity defence is what the pin replaced,
and it was written that way here until Copilot read the two against each other.

`$REPO_DIR` was captured in the setup block, and it is a TREE rather than a name —
which is the same distinction the pin draws from the other side.

## AUTO_REVIEW IS PASSED AS AN ARGUMENT, not read from the environment.

A value assigned in your shell without `export` reaches a function and not a child
process, and this one decides whether an in-flight Codex pass may be ignored. A
silent default there is a merge on a verdict nobody read.

## THERE IS NO PLACEHOLDER HERE, and that is the third attempt at this line.

`$CODEX_SHA` was captured and validated in step 7, when the Codex phase closed.
Writing it out again here as something to fill in was redundant, and it did not
work: `<…>` is a REDIRECTION to the shell in argument position AND after an `=`,
so an unsubstituted placeholder does not reach the gate's own sha check — the
block fails to parse, which is a different failure in a different place.

## REVIEWERS IS `both` UNLESS THE OPERATOR CHOSE OTHERWISE at the Codex stop.

The choice was made there, at the stop that closed the Codex phase, and this is
where it is spent. Deciding it here instead would be deciding it twice, in a place
the operator was never asked.

## `codex-only` IS NOT A WEAKER GATE, and requires the head to BE the signed commit.

It drops Copilot's verdict and in exchange requires the head to be exactly the
commit Codex signed, because the `Review-Phase: copilot` trailers that license a
moved head do not exist when there was no Copilot phase.

So it is narrower rather than looser, and saying so matters: read as a shortcut it
would be chosen to save a round, which is the one reason it must not be.

## THE STATUS LEAVES THIS BLOCK, or a blocked merge reports success.

Every arm of the `case` above ends in an `echo`, whose status is 0 — so without
the final `exit` the block reports success for a blocked, paused or queued merge,
and whatever runs it next carries on as though the PR had landed. The distinction
the gate exists to draw survives only if it is passed on.

## THE REQUEST IS A SCRIPT.

It was eighteen lines here that nothing executed, and what they do is post the
comment that — on the manual path — IS the review request.

It was also a second, weaker copy of the round-closing request: that one refuses a
body carrying a marker the loop honours or a mention it did not write itself, and
this one refused neither, so the opening account was the one posting site with no
rules. Issues #26, #144.

## THE REQUEST RUNS AS A CONDITION.

Not as a simple command whose status is read afterwards. This block is pasted into
a shell with `errexit` on as often as it is typed into one without, and there a
simple command that exits non-zero ends the shell before any status can be read —
so the refusal below would never run, and a session would end with no account of
why. A command run as a CONDITION is exempt.

It is also what makes the success arm mean something: with the request as the
condition, everything that depends on it having been posted sits inside the branch
a refusal does not take.

## THE BODY NEVER BECOMES SHELL SOURCE, because an account can close a heredoc.

A heredoc splices it in: an account containing a line that is exactly the delimiter
ENDS the heredoc, and whatever follows is parsed by your long-lived shell — and
`EOF` is a line this loop's own accounts quote, out of a diff or a finding.

Choosing a rarer delimiter narrows that and does not close it, because the body is
not known when the delimiter is chosen.

## AND THE FILE IS NOT WRITTEN FROM THIS SHELL, because `cat` and `printf` are names.

Writing the file from here needs a command, and your shell can replace either of
those with a function — so the account that was validated and posted would be the
function's text rather than what you wrote.

Your file tool is neither a heredoc nor a command: it does not go through this
shell at all, which is what makes it the one way in that has no name to take.

## NO NAME HOLDS THE STATUS, because a readonly one loses a refusal twice over.

Written as `…; REQ_RC=$?` the status is lost two different ways. With `errexit` on, a
documented refusal ends the shell at the assignment before anything reads it. Without
it, a startup file that has already made the name readonly `0` leaves the assignment
failing silently at that benign value — and a request that never happened is followed
by a wait for it.

A command run as an `if` condition is exempt from `errexit` and leaves no name to seed.

## AND THE BASELINE NEVER BECOMES AN ASSIGNMENT EITHER.

It used to. The helper printed the review id, the driver read it back into
`PRIOR_REVIEW`, and because that assignment can be defeated by a readonly name, a
nameref or a transforming attribute, the driver carried a subshell probe to prove the
name assignable before posting, a read-back to prove the assignment survived, and a
four-arm `case` to prove the shape.

The last of those was a second, weaker copy of the validation in `pr-watch.sh`, which
checks both ids it compares — and `CLAUDE.md` records what a second copy of a rule
costs: every field check in `recordlib.sh` was written out two or three times and
every one was found missing from at least one copy.

The value has ONE consumer. So it is redirected into `$PRIOR_FILE` and read where it
is used, by a privileged helper that already knows what a review id looks like. That
is `prefer removing the dependency over guarding it` applied to three guards at once,
and it is the same answer `pr-origin.sh` gives: a path rather than a name. #243.

## THE ANSWER GOES TO A FILE, A PATH RATHER THAN A NAME.

A name can be made readonly or transforming by a startup file, and both failures
are invisible at the point of use. A path is neither: the helper writes the file,
and `pr-watch.sh` opens it — this shell only carries the path from one to the other.

It used to read the file back and prove the assignment against a second read of it,
which is where a name could still have defeated the handoff. Since #243 there is no
assignment to prove, because the value never lands here at all.

`pr-origin.sh` settled the same question the same way, and for the same reason.

## THE CONTINUATION IS THE `then` BRANCH HERE TOO.

`exit` is a builtin a startup file can replace with one that RETURNS, so a refusal
written as `echo …; exit` prints and carries straight on — into the wait for a
review that was never requested, against a baseline file this run never wrote.

Ending the arm in `[[ -n "" ]]` makes the LIST report non-zero, which nothing here
reads. What does hold is that the work sits inside the branch a refusal does not
take.

## THE LAST WORD IS A RESERVED ONE, or a failed request reads as a posted one.

`echo` and `exit` are builtins a function can shadow, and with both shadowed this
branch says nothing and returns 0 — a failed request indistinguishable from a
posted one, which sends the driver into a wait for a review that was never asked
for.

## AND THE HEAD FILE IS PROVEN NOT TO BE THE SUMMARY FILE.

`gate` refuses an aliased head file BEFORE it clears anything — it has to, or the
refusal would destroy the account it is protecting — so on that one path the file
is left holding the summary.

THE IDENTITY IS ASKED FIRST, and the content test is its success arm. A summary
that IS forty lowercase hex characters, a commit id someone pasted on a line of its
own, satisfies the content test exactly, and is the one summary that can. `-ef`
answers what the content cannot, and it answers it about the two paths this session
chose rather than about what is in them.

ONE DECISION RATHER THAN TWO STATEMENTS. Written as a guard above the content test,
a shadowed `exit` that returns would walk from the identity refusal straight into
the arm that accepts.

WHERE THE INVARIANT IS ACTUALLY ESTABLISHED is the setup block: the four working
paths are derived from one directory by DISTINCT literal suffixes and each is read
back against its own literal, so in the documented flow they cannot be the same
file. This is defence for a path that allocation already excludes, which is why it
costs one reserved-word test and no lookup.

## AND ITS CONTENT IS PROVEN A COMMIT ID.

Not merely non-empty. Every refusal other than the aliased one leaves the file
EMPTY — `gate` empties it before any other refusal can happen, and writes it only
on success — so an empty file is already the ordinary evidence that no gate
succeeded. Asking for a commit id also covers the aliased path, where the file
holds the summary.

A LITERAL PATTERN IN A `case`, not a regex in a variable. A validator held in a
name is a second name a startup file can seed, and a seeded pattern accepting a
seeded value is a check that agrees with itself; `case` is a reserved word and
these patterns are in the source. The forty-character test and the hex test are
separate arms because one glob cannot say both.

WHAT IT CANNOT PROVE is that the file holds what `gate` REPORTED. The record and
the file are two claims and only one of them reaches this shell. A file that was
written truthfully and then changed by something else would pass; `post` re-proves
the head against the local HEAD and the PR before it posts, which is where that is
caught.

## AND BOTH ARE PROVEN BEFORE THE REPLIES, which are the irreversible part.

A resolve cannot be taken back. Resolving before the head is proven records this
round's findings as answered on a commit that may never have landed, and with
automatic review on the pass the push started reads threads already marked
resolved with no summary saying what resolved them.

AFTER THE `fi`, NOT INSIDE THE GATE'S SUCCESS ARM. Placed there it is on the one
path that does not need it: a refusal takes the `else`, and with `exit` replaced by
a function that returns, control leaves the `if` having evaluated nothing. After
the `fi` it is on every path out of the stage.

THE GATE'S SUCCESS ARM IS TRUE, and `[[ -n x ]]` rather than `[[ -n "" ]]`. Under
`errexit` a false statement in a `then` BODY ends the shell — the exemption is for
a command run as a CONDITION, and this is not one — so the successful path would
have died after the push and before the replies. `:` would also be true, and is a
name; a reserved word that is true is both.

A SHADOWED `echo` COSTS THE MESSAGE, NOT THE REFUSAL, and that is ACCEPTED. The
refusal is the arm being taken and the head not being proven; the `echo` only says
why.

MAKING THE SHELL WRITE IT WAS TRIED TWICE AND COST MORE EACH TIME. A `${…:?}`
expansion needs a name to expand, and the name is the operator's to seed:
`declare -i RB_HEAD_BAD=1` makes the clear store `0`, so the expansion never fires
and the guard is decoration. Proving the clear with `[[ -z … ]]` fixes that and
opens a worse door — `declare -n RB_HEAD_BAD=BASH_XTRACEFD` makes the CLEAR itself
write through the nameref and close the operator's stdout, so the refusal is not
merely silent, it has damaged the shell it was protecting.

SO THE SCRATCH NAME IS GONE. A defence against a shadowable name that introduces a
seedable name is not a defence, and the second attempt was worse than the first.
The residue is: in a shell with `echo` shadowed and `exit` returning, the arm is
taken, nothing is printed, and control reaches the prose.

WHAT NO SHELL CONSTRUCT HERE CAN DO is make the reply instructions unreachable.
They are PROSE, in a Markdown document, between two fences — so a driver whose
`exit` returns can read them whatever the fence above did.

AND THAT IS A LIMIT OF THE DESIGN RATHER THAN A DEFERRED TASK. #26 asked whether
this code could move into `.sh` files and answered no, twice over: the setup block
exports `REVIEW_BUS_REMOTE` into the driving shell and a child cannot export into
its parent, and the read-backs that remain exist to catch a readonly name or a
nameref defeating the driver's own assignment — moving one into the helper would
move it to the one process that cannot observe the failure. The glue has to run
where the values land.

WHICH VALUES THOSE ARE HAS SHRUNK, and each removal was a value that turned out to
have ONE consumer. #228 took the setup work into `pr-setup.sh` and left the origin
crossing in a file; #243 did the same to the review baseline, which now goes from
the helper that captures it to the helper that reads it without being named here.
What cannot go is a value this shell must ASSIGN — `WHO`, `CODEX_SHA`, the four
working paths — because only this process can see its own assignment fail.

So there is no refactor waiting to close this, and a comment saying there is would
be read as an instruction to attempt one. What holds instead: every path takes a
refusal arm and prints it unless `echo` has been shadowed, `post` asks the content
question again and refuses, so no summary is posted and no pass requested, and the
allocation the paths come from cannot produce the aliased case at all.


## THE FILE IS READ ONCE, because two reads are two different values.

The check proved the head in two steps: an outer `case` for the LENGTH, and an inner one,
on a second `$(<…)` of the same path, for the ALPHABET. A value that is forty characters
when the first read runs and something else when the second does satisfies both — and the
path is published in argv, so a same-UID process is all it takes.

What that gates is the THREAD RESOLVES. They are the irreversible part of the round and
they happen before `post` gets to re-prove anything, so this is the only proof standing
between a gate that did not write a head and a round that resolves threads claiming it
did. A check-then-use is a poor thing to put there.

One read and one `case` with three arms answers both questions at once: a non-hex value
or an empty one is refused, exactly forty hex characters continues, and any other length
is refused. No name holds the value, because a name in this shell is one an operator's
startup file can have made readonly or aimed elsewhere — which is why the two reads were
there in the first place, and why the answer is one read rather than one variable.

The aliasing test that wraps all of this STAYS, and removing it was a mistake worth
recording. The reasoning was that `gate` already refuses a head file that is the summary
file, by `=` and by `-ef`, so a second refusal in the arm reached only when `gate` exited
0 could never fire.

Both halves of that are wrong. `gate` refuses the aliased pair BEFORE it empties anything
— it has to, or the refusal would destroy the account it is protecting — so on exactly
that path the file is left holding the SUMMARY. And this code is not reached only on
success: `exit` is a builtin a startup file can replace with one that RETURNS, so a driver
that takes the gate's refusal arm walks out of it, past the `fi`, and arrives here anyway.
A summary that is forty lowercase hexadecimal characters then reads as a gated head, and
the threads are resolved claiming a head no gate wrote.


## AND ITS IDENTITY IS PROVEN BEFORE ITS CONTENT, because a refusal can be walked past.

The content check answers "is this a commit id". It cannot answer "did a gate write this",
and on one path those differ: `gate` refuses a head file that IS the summary file before
it empties anything, so the file is left holding the account. Forty lowercase hexadecimal
characters of summary satisfy a content check perfectly.

That path is reachable. `exit` is a builtin a startup file can replace with one that
RETURNS, so a driver taking the gate's refusal arm walks out of it and past the `fi` — the
arm ends in a reserved word, which gives the `if` a status nothing here reads. So the
identity question is asked FIRST, by `=` and by `-ef`, the same pair `gate` uses, and the
content read sits inside the arm where the answer was no.

Both tests, not one. `-ef` compares the files and answers nothing when the path does not
exist; `=` compares the names and catches that case.

## THE INTERFACE IS IN THE SCRIPT'S OWN HEADER, and it is not restated here.

Twenty-four lines of this block were the two invocations, the exit statuses and the
two kinds of push refusal — all of it already in `pr-close-round.sh`'s header, where
a reader of the script finds it and where it cannot drift from the code beside it.
Here it was a second copy read on every invocation of the skill and executed by
nothing, and a second copy of a contract is the thing this repository has paid for
repeatedly: the copy that is not beside the code is the one that goes stale.

WHAT STAYS IS WHAT THE DRIVER HAS TO DECIDE — which stage runs when, that the
replies go between them, and what each status means for the round. The rest is one
line saying where to read it.

## THE STAGE RUNS AS A CONDITION HERE TOO, so no name holds its status.

`gate` has been an `if` condition since it was written; `post` was not, because its
STDOUT had to be captured to get the baseline out of the record. That capture is gone
— the baseline crosses in a file — and with it the reason for the shape.

WHAT THE SHAPE COST was two names the operator's shell owns. The status went into
`ROUND_RC`, and the branch was `[ "$ROUND_RC" -eq 0 ]`: a function called `[` that
returns success routes a STOPPED or PAUSED `post` into the arm that reads the baseline
and enters the watch — on a pass nobody requested, with the summary unposted. Both are
gone: `if <helper>; then` cannot be stood in for, and `case $?` in the `else` tells the
three answers apart with a reserved word, `$?` taken before anything can replace it.

AND A CONDITION IS EXEMPT FROM `errexit`, which is the same reason every other stage
in this document is written as one.

## AND WHAT WAS READ IS PROVED A SHA, because an attribute can transform an assignment.

The read succeeding does not mean the NAME holds what the file held. This block runs in
the operator's long-lived shell: declared
`declare -i`, a forty-digit sha is coerced to an integer the moment it is assigned —
measured, `0000…0001` becomes `1` — and declared `declare -u` it comes back uppercased.
Both assignments SUCCEED, so the condition is satisfied and the value is wrong.

WHAT IS WRONG WITH A WRONG VALUE HERE is that the signoff has already been posted: the
corrupted sha is then named to the operator on the pause, or handed to `open` and the
merge gates. So the length and the alphabet are checked inside the same condition,
where a failure takes the refusal arm rather than continuing.

AND `CODEX_SHA` IS IN SETUP'S PROBE, which is the other half and the earlier one. The
shape check catches a value that arrived wrong; it cannot catch a READONLY seed, where
the assignment fails and a shape-valid value the operator planted is what the checks
then pass — or where the failed assignment ends the shell outright, which is loud but
happens after `record` has posted the signoff. The probe answers both at setup, before
anything is posted, which is where every other name this session assigns is answered.

## AND THE PAUSE ARM READS IT TOO, the signoff being recorded either way.

A `3` is a round boundary, not a failure: `record` posts the signoff and THEN pauses, so
the sha exists and the operator is told which commit they may merge on. An arm that
skipped the read would stop without naming it, which is the one thing the operator needs
at that boundary.

IT IS THE SAME READ AND THE SAME PROOF, written out twice because this shell has no
function to hold it in — `return` is a name, and `readonly -f` defeats a definition made
here. That duplication is the price, and it is the one this document pays everywhere a
value crosses.

## THE STAGE RUNS AS A CONDITION, so no name holds its status.

The same shape every other stage in this document uses, and for the same reasons: a
condition is exempt from `errexit`, and there is no `PHASE_RC` for a startup file to
have made readonly or transforming. It was a capture — `PHASE_OUT="$(… 2>&1)"` with the
status into `PHASE_RC` — because the output had to be re-printed and the sha parsed out
of the record that followed. Neither is true now: the sha crosses in a file, and the
stage prints its own account straight to the terminal.

THE THREE ANSWERS ARE TOLD APART BY `case $?` IN THE `else`, with `case` a reserved
word and `$?` taken before anything else runs. The `3` is a round boundary and the
signoff IS recorded, so that arm reads the sha and names it to the operator; a `1` is a
stage that did not advance, and there is nothing to read.

## THE SIGNED-OFF HEAD COMES OUT OF THE FILE `record` WROTE, not from a second lookup.

`record` proves that sha, records it and holds it. The driver read it back with
`pr-signoff.sh sha`, then validated the answer with a regex and a status check —
a second round-trip to the API and eleven lines of the one shell nothing can harden,
for a value the stage that just ran already had. It writes it into a caller-named file
now, as `pr-close-round.sh gate` has handed the head over since #202 and `post` the
baseline since #234. #239.

WHAT THE HELPER DOES WITH THAT FILE IS THE HELPER'S TO ARGUE, and it does, beside the
code: that it empties the file early — though not before the alias checks, which refuse
without truncating, since a sha file that IS the body file would have its account
destroyed by the clearing — and that it writes and reads back the value BEFORE the
comment is posted, there being nothing left to refuse with afterwards. Those are
properties of `pr-copilot-phase.sh`, not of this block, and restating them here would be
the second copy this repository keeps paying for. What this block relies on is only that
the file holds a sha or the read fails, which the claims above and below it cover.

## THE BASELINE STAYS IN THE FILE `post` WROTE.

`post` writes the next round's baseline into `$PRIOR_FILE` before it requests the
pass, with the write's status taken and the value read back — after the request there
is nothing left to refuse with, and the round would be irreversibly half-closed.

What the driver then does with that file is nothing. It used to read it back through a
bound descriptor into `PRIOR_REVIEW`, behind a refusal for a read that failed. That
whole arm went with #243, and one platform hazard went with it: the read-back compared
the assignment against a SECOND read of the same descriptor, and on macOS and the BSDs
`/dev/fd/N` duplicates rather than re-opens, so the second read drains empty and every
non-empty baseline was refused — at step 2 leaving a posted request with no watch, at
step 5 aborting after the summary and the next pass had gone out. The `macos-shell`
job runs on Ubuntu and cannot see it. That was #238; removing the read closed it.

## AND THE WATCH IS THE ONE THAT READS IT, where a failed read is not an empty baseline.

`pr-watch.sh --after-review-file` binds the descriptor, reads it once, and validates
the shape — so the rule lives in the process that consumes the value rather than in
the shell that only carries it.

The distinction it has to keep is between a file that is EMPTY and one that could not
be READ. Empty is legitimate: it means there was no prior review to wait past, which
is the ordinary first request on a fresh head. A failed read degraded to empty would
say exactly that, and the watch would then accept the terminal review this round just
handled as the next one — the whole failure the baseline exists to prevent, arriving
through the read rather than through a missing flag. It is `state=error` instead. An
empty PATH is refused at the option, for the same reason one step earlier: a caller
expanding a name that was never assigned satisfies the argument count, and an empty
value would skip the read entirely and leave the watch with no baseline at all.

## THE BASELINE GOES STRAIGHT INTO THE FILE THE WATCH READS.

`open` captures the review id immediately before it requests Copilot — read earlier, a
pass already in flight on this unchanged head could finish during the probes or the
revocation, and the watch would accept a review made BEFORE the request as the answer
to it.

It writes `$PRIOR_FILE` before the request, with the write's status taken and the value
read back — the arrangement `gate` uses for the head and `record` for the signed-off
sha. After `--add-reviewer` there is nothing left to refuse with: the pass is in
flight, and a caller reading a truncated id would arm the watch against the wrong
review. The file is emptied at the top of the script, before the bootstrap, so a
refusal above the write cannot leave the previous round's id to be read as this
round's. #243.

## AND NOTHING HERE PARSES IT OUT OF THE RECORD.

The value used to reach the driver only through `PR_COPILOT_PHASE_OPENED`. The driver
captured the stage's whole output, selected the record with `sed`, proved it was
there, proved it carried the field, and cut the value out with
`${OPEN_REC##* prior-review=}` — a parse of a line whose field order belongs to the
helper, performed in the one shell nothing can harden, over four names any of which a
startup file can make readonly. That expansion is also why `prior-review=` had to be
the record's LAST field, which made the field order load-bearing for a reason that had
nothing to do with what the record is for.

The record still prints the baseline, and that is deliberate: it is what an operator
reads to see which pass this round is waiting past. Nothing parses it.

## THE STAGE RUNS AS A CONDITION, so its output is not captured.

`OPEN_OUT="$(… 2>&1)"` existed only because the baseline was cut out of it. With the
baseline in a file there is nothing to capture, so the stage runs as the `if`
condition — exempt from `errexit`, with its output going straight to the terminal
where an operator reads it, rather than into a name a startup file can have made
readonly.

The one assignment left is `WHO`, and it is read back: it selects the reviewer every
later stage is addressed to, and a nameref or a readonly there would send the Copilot
rounds at Codex.

## AND ITS STATUS IS NOT HELD, because a round boundary is not a refusal.

`open` returns 3 at an operator round boundary, which is a pause and not a stop —
so the status has to survive to be branched on. Held in `OPEN_RC`, it did not: a
readonly name leaves the assignment failing silently at whatever it already held, and
at `0` that reads a refusal as a phase that opened, with Copilot never requested and
the loop waiting for a pass nobody asked for.

`case $?` in the `else` takes it instead — `case` is a reserved word, and `$?` is
taken first, before any command can replace it.


## THE REVIEWER SWITCH IS A CONDITION, because its refusal has somewhere to fall.

`WHO` selects the reviewer every round below is addressed to, and it is the one
assignment this fence still makes. Both ways it can fail are silent: a readonly `WHO`
keeps the value it already had, which is Codex — so the Copilot rounds would poll the
reviewer that is already clean — and a transforming attribute such as `declare -u`
stores a login that is not anyone's, which `pr-review-state.sh` compares exactly, so
Copilot's verdict is never recognised and the phase re-arms forever.

Written as an assignment followed by a guard, the refusal did not hold. `exit` is a
builtin a startup file can replace with one that RETURNS, and a `{ echo …; exit 1; }`
group whose last command returns 0 SUCCEEDS — so the `||` was satisfied, execution
carried on past it, and the rounds ran against the wrong login with Copilot already
requested.

So the assignment and its proof are the `if` CONDITION, and the continuation is the
success arm. The refusal is an arm that is not taken rather than a statement that has
to stop the shell, which is the same shape every other fence here uses and the reason
`[[ -n "" ]]` is the last word in it.


## AND THE NAME IS PROVED HERE, because setup's probe cannot reach forward.

Setup proves every name this session assigns, `WHO` included. That proof is about the
shell as it was AT SETUP, and the driving shell is long-lived: a `declare -n
WHO=PRIOR_FILE` executed at any point afterwards is invisible to a probe that already
passed. `test-pr-skill-contract.sh` establishes exactly that about the other probed
names, so it is not a hypothetical about this one.

A nameref is the case a postcondition cannot catch, because it reads back through the
same alias. `WHO="$COPILOT_BOT"` writes the login into `PRIOR_FILE`, `[[ $WHO =
"$COPILOT_BOT" ]]` reads `PRIOR_FILE` and agrees — so the phase opens, Copilot is
requested, and the next watch is handed a reviewer login as its baseline path. The
target is destroyed either way: an alias onto any session name replaces its value.

The probe is the setup one, run where the assignment is. A SUBSHELL, so the write it
performs to prove the point cannot reach the parent — through an alias that write lands
on the target, and probing destructively in this shell would be the damage the probe
exists to prevent. `[[ $WHO = RbProbe* ]]` catches a transforming attribute, because
one succeeds and stores something else; `[[ -z ${!WHO:-} ]]` catches the alias, because
for a nameref that expansion is the TARGET'S NAME rather than a value. And it is the
first term of the `if`, so the assignment is inside an arm the refusal does not take.

## THE REVIEWER NAME IS PROVED WHERE IT IS SET, at every site that sets it.

There are two: this one, and the switch to Copilot in step 7. Setup proves `WHO` as
well, and that proof is worth having — it stops a session starting at all against a
shell that has already aimed the name somewhere — but it cannot reach forward, so it is
the floor rather than the answer.

Proving only the LATER site was the first attempt and it was wrong in a way worth
recording: the earlier assignment has the same hole, so guarding the site where a
reviewer happened to notice it would have shipped the identical defect one stage
sooner. The rule is the site, not the incident.

What each failure costs here is the whole run rather than one stage. `WHO` addresses
every helper the round calls — the watch, the round close, the phase — so a readonly
one leaves them all aimed at whatever the name already held, a transforming one at a
login that is nobody's, and an alias overwrites the name it points at while agreeing
with every check made of it. Nothing has been posted at this point, which is why the
refusal here can be total.


## THE REQUEST IS INSIDE THIS ARM, not a fence after it.

The proof above refuses by printing and calling `exit`, and `exit` is a builtin a
startup file can replace with one that RETURNS. Written as its own fence, the refusal
then ended that fence and the NEXT one posted the review anyway — with `WHO` still
readonly, still transforming, or still aimed at another name, so the round that follows
polls a reviewer nobody can be.

Ending the arm in `[[ -n "" ]]` does not answer it. That makes the compound command
report non-zero, and nothing reads the status of a fence in a Markdown document; what
the reserved word buys is that the LIST fails rather than reporting the refusal as
success, which matters only where something is reading. Containment is POSITION: the
work has to sit in a branch the refusal does not enter.

So the request is nested. The proof is the `if`, its success arm holds the request and
the request's own arms, and the refusal is the `else` — the shape every other fence in
this document already had, and the one this site was missing because the proof was
added later than the request it protects.

## THE RECORD IS STILL PRINTED, and it is what an operator reads.

`post` still ends with `PR_ROUND_CLOSED pr=… reviewer=… head=… mode=… prior-review=…`,
and the baseline is still in it. Moving the value into a file did not make the record
redundant: it is the line a person scrolling the terminal reads to see which head the
round closed on and which pass was requested, and it is what a transcript preserves.

WHAT CHANGED IS ONLY WHO READS IT. The driver used to, by parsing; it does not now.
Dropping the record because nothing machine-readable consumes it would take the
operator's account of the round with it.

## THE ROUND CLOSES THROUGH A SCRIPT, because both orderings were prose in `SKILL.md`.

Two recipes lived in `SKILL.md`, doing the same job in different ORDERS, and the
ordering is the whole content. Nothing executed either, and a reader had to choose
which one to copy — which is how the two drifted apart.

There is one recipe in `SKILL.md` now, and the two orders are inside the script,
where the suite reaches them. Issue #26.

## THE GATE RUNS BEFORE THE REPLIES, because a resolve cannot be taken back.

`gate` pushes and proves the head green, and only then are the threads answered —
so a resolve is a claim that is true when it is made.

Resolve first and a round that then fails to push, or pushes red, has already
recorded its findings as answered on a commit that never landed. With automatic
review on it is worse: the pass the push starts reads threads already marked
resolved, with no summary saying what resolved them.

## IT IS A REFUSAL BECAUSE THE ALTERNATIVE HAPPENED, and what it pushed was `main`.

A bare `git push` sends whatever branch the checkout is on, and this stage is given
a PR NUMBER, not a branch.

A round driven from a checkout left on the default branch — a `cd` or a `checkout`
that failed, a second worktree holding the PR's branch — pushed `main`: an
unreviewed commit on the default branch, and the round lost as well, because the
checks were then awaited on a head the PR did not have. A detached HEAD is refused
for the same reason. #119.

## `$AUTO_REVIEW` IS PASSED, NOT WRITTEN IN.

It was established in step 2 and the script refuses anything but `yes` or `no`, so
the mode this PR is in picks the order INSIDE the script.

The alternative was two recipes in `SKILL.md` and a reader deciding which to copy,
which is how the two orderings drifted apart in the first place. A value assigned in your
shell without `export` also reaches a function and not a child process, so reading
it from the environment would give the script a silent default — and the default
answer is a round closed on a mode nobody chose.

## THE GATED HEAD TRAVELS IN A FILE, so no name in this shell has to hold it.

It was a string, and that is what #202 was. The driver captured `gate`'s output,
`sed`ed the head out of the record, and assigned it — `GATED_HEAD="$( … )"`, an
ASSIGNMENT, in the operator's own long-lived shell, AFTER `gate` had already
pushed. A startup file that has made that name readonly fails it there: with
`errexit` on the shell ends, and without it the name keeps whatever it held, so the
non-empty check passes on a seeded value and `post` is handed a head the gate never
reported. `CLAUDE.md` records that an assignment's status cannot be taken, so a
`||` on it catches nothing.

A FILE HAS NO SUCH FAILURE, and it removes two more names with it. There is no
capture, and there is no `sed` — which is a NAME, and one that prints a plausible
forty hex and exits 0 sends `post` at whatever it says. Both stages take the same
path, `gate` writes and `post` reads, and the value never enters this shell at all:
what is checked here is that the file holds a COMMIT ID, which is a question about
the file rather than about a name. Not merely that it is non-empty — the section
below says why that is not enough — and not that it equals what `gate` reported,
which the driver cannot know, since the record and the file are two claims and only
one of them reaches this shell.

It is the shape `pr-request-review.sh` uses for the review baseline and
`pr-origin.sh` for the origin. A path rather than a name.

WHAT THE DRIVER STILL CANNOT PROVE is that the file holds what `gate` reported —
and it does not have to. `post` reads it and validates what it finds against
`sha_reason` before anything is posted, so a truncated or corrupted file stops the
round at the stage that depends on it, at the cost of a rerun. Checking it twice
would be a branch no fixture can stage.

## AND THE STAGE RUNS AS A CONDITION, so no name holds its OUTPUT.

`GATE_OUT="$( … )"` captured everything the stage printed so that a `sed` could
lift the head back out of it. Both halves are gone: the head travels in a file, and
what the stage prints goes straight to the operator, which is where a reason
belongs.

A capture is also an assignment made AFTER the push, which is the defect this whole
change is about, reached by the other road.

## AND NO NAME HOLDS ITS STATUS EITHER.

`; GATE_RC=$?` and a `case` on it: a readonly `GATE_RC` keeps its old value, so the
`case` branched on a status from another round. Run as a condition there is no
status variable at all, and `$?` in the `else` arm is the condition's own, read
before anything can change it.

WHAT NEITHER BUYS IS CONTAINMENT, and the claim used to say otherwise. With `exit`
replaced by a function that returns, the `else` arm's `exit` returns, the trailing
reserved word leaves the completed `if` with status 1, and execution carries on
after the `fi`. Nothing consumes that status. What follows the `fi` is the head
proof, which refuses on every path that is not a proven success — and after THAT is
prose, which no shell construct reaches.

## ONLY NOW IS THE ROUND CLOSED, after the threads are answered.

`post` posts the summary and requests the next pass, and both are irreversible: a
later comment saying "that round did not really close" is a record, not a
retraction, and it is itself a call that can fail.

Run ahead of the replies, it requests a pass over findings nobody has answered
while the summary says the round handled them — so the next review re-reports what
this one was about to fix, and the extra volume reads as regression rather than
repetition.

## AND THE HEAD IS RE-PROVED BEFORE ANYTHING IS POSTED.

Locally and on the PR, because the replies take as long as they take. A commit made
between the gate and the post leaves the summary describing one commit while the
reviewer reads another, and the gate's green verdict belongs to the commit the gate
saw and to no other.

This is a separate question from when the round closes: the ordering says the post
comes last, and this says the post is still allowed to happen when it gets there.

## NOTHING REACHES THE POST EXCEPT THROUGH THE ARM THAT PROVED IT.

These four refusals were `|| { echo "ABORT: …"; exit 0; }`, and that shape has no
containment in the shell this block runs in. `SKILL.md` executes in the operator's
own session, where `echo` and `exit` are both NAMES, and neither can be re-execed
away. Measured against the block lifted out of this document, with a probe printing
a plausible `PR_ROUND_PAUSE … rounds=41 …` line and exiting 1:

    operator shell                          acknowledgement posted?
    ordinary                                no
    echo() { :; }                           no
    echo() { :; }; exit() { return 0; }     YES

With both shadowed the arm runs, `exit` returns instead of terminating, execution
continues into the parse — which succeeds, because the forged line is well-formed —
and a failed probe's output becomes the operator's recorded permission to continue
past a check-in. That is the one thing the comment above this block says must never
happen. #224.

**The answer is where the post SITS, not what guards it.** Every proof is a reserved
word — `if`, `[[`, `case` — and the `gh pr comment` is inside the innermost success
arm of all three. A refusal is now an arm NOT TAKEN rather than a statement that has
to terminate, so there is nothing for a shadowed `echo` or `exit` to walk past: the
first silences the diagnostics and changes nothing else, and the second is not used
at all.

**THAT IS THE WHOLE OF THE GUARANTEE, AND IT IS NARROWER THAN "NO SHADOWED NAME".**
`printf`, `sed` and `gh` are still names in this shell, and a `sed` that prints `41`
and exits 0 on unparseable output takes every arm honestly and posts. What this
shape closes is a refusal PATH being walked past; what it cannot close is a forged
VALUE, which is the same class as a forged helper — and the same one `CLAUDE.md`
records the driver living with, since nothing inside a process can distinguish the
honest version of something it inherited. Claiming more than this was a finding on
the first round of the change.

**A REFUSAL SENTINEL WAS TRIED FIRST AND IS WORSE.** The first version of this fix
cleared a variable and expanded it with `${VAR:?…}`, which is #181's answer for the
setup block. It does not transfer, because the variables here are ones the
operator's shell can have seen first: measured, with `declare -i ROUNDS_PAUSE`
inherited, clearing it stores `0`, `${ROUNDS_PAUSE:?…}` finds that non-empty, and
the acknowledgement is posted anyway. The setup block's expansions are safe from
this because what they refuse on is an origin URL rather than a flag — a value no
integer attribute can forge into truth. A sentinel whose whole content is
"something was proved" is exactly the value an attribute can pre-seed.

**And the parse's status is taken by the `if` itself.** `ROUNDS="$(… | sed …)"` as
the condition means a parser that printed a plausible count and then failed takes
the else arm: measured, a `sed` printing `41` and returning 1 leaves the value in
place and the branch still refuses. Written as an assignment followed by a shape
check, those digits were accepted and posted.

**`0` IS REFUSED WITH THE SHAPES THAT ARE NOT COUNTS.** No pause happens at zero
rounds, so it is not a value this can ever legitimately acknowledge — and under a
`declare -i` inherited from the operator's shell an empty parse becomes exactly
that, so the semantic refusal closes an attribute hole as a side effect rather than
by aiming at it.

**What is NOT closed, and cannot be from inside.** A variable this block assigns can
be `readonly` in the operator's shell with a plausible value already in it; the
assignment then fails and the old value is what the arms see. That is the same limit
`CLAUDE.md` records for the whole driver — nothing inside a process can distinguish
the honest version of something it inherited — and it is why the block's own
guarantee is about what a shadowed COMMAND can reach.

## THE SETUP WORK RUNS IN A PROCESS, because nothing in this document executed it.

It was 177 executable lines and 105 comment lines of this document — about a fifth of
everything the driver reads on every invocation — and no test could reach any of it. A
fenced block is not a file the suite has, and `test-pr-skill-contract.sh` covers only
what it can lift and run.

#26 asked whether it could move and answered no, because setup EXPORTS into this
session and a child cannot export into its parent. That is true of a child's
ENVIRONMENT, and it settles less than it looks: what has to cross is a VALUE, and a
value can cross in a file.

WHAT STAYS IS WHAT A HELPER CANNOT DO FOR THIS SHELL: finding the scripts at all, since
the identity parser is one of them; choosing the parent directory to hand over; the
read; and the proofs after it, which catch a readonly name or a nameref defeating this
shell's own assignment — a helper process cannot observe that. The pin is a fifth, and
it is why the export below is made here.

## AND WHAT COMES BACK IS ONE VALUE, because eleven of the twelve were never information.

The helper wrote twelve assignments and this block SOURCED them, which is a separate
obligation from running the work in a process and is why it is a separate claim: the
helper could stay a process and go back to handing over twelve values tomorrow.

`OWNER`, `REPO` and `HOST` are what `rb_identity` derives FROM the origin, and this
block runs it anyway. The two reviewer logins are constants. The working directory and
its four files are a literal suffix under a directory this shell named itself —
`RB_WORK_DIR` was not referenced anywhere else in the document at all. So the origin is
the only value that crosses a boundary this shell cannot see across, and everything
else is assigned here and proved.
## NOTHING THE HELPER WROTE IS EXECUTED HERE, because `.` is a name in this shell.

`SKILL.md`'s bash runs in the operator's long-lived shell, which nothing controls and
which cannot re-exec out of its own functions. While the setup values arrived by
SOURCING, a function named `.` could delegate the earlier `identitylib.sh` load, read
the genuine assignments, and hand back a different origin — after which everything
agreed with it, because `rb_identity` derives `OWNER` and `REPO` FROM the value — and so
did the child pin, which then reported back the export made FROM it and nothing else. The
session posted, signed off and merged in another repository with every check passing. The
pin re-reads the checkout now (#230), so that last agreement is gone; the argument for not
sourcing is unaffected, because a function named `.` runs as CODE and that is a larger
failure than a forged value.

THAT IS AN INDEPENDENT OBLIGATION FROM HOW THE VALUE TRAVELS. A future edit could keep
the single value and reintroduce a source to read it, which is why this claim and the
one below it are two.

## THE VALUE ARRIVES BY EXPANSION, which the parser performs with no command in it.

`$(<file)` is a substitution the shell performs itself — no fork, no command name, and
nothing an operator's function can stand in for. It is how `pr-origin.sh` has always
sent a value back and how the pin already comes back a few lines below, so this is the
document's existing answer rather than a new one.

WHAT IT DOES NOT ANSWER is WHICH object was bound. A swap still gets a value past this
read; what it no longer gets is a session addressed to it, because `pr-origin.sh pin`
re-reads the checkout and refuses a pin that is not its origin. #230.
## THE TRANSPORTS ARE LEFT WHERE THEY ARE, because unlinking through a published name can hit what replaced it.

This block removed the env file after sourcing it and the pin leaf after reading it,
and both removals were the same defect one level up from the one `pr-setup.sh` was
fixed for: `$RB_SETUP_DIR` is published in argv, so `rm -f "$RB_SETUP_DIR/pin/pin"`
unlinks a REPLACEMENT's own `pin` when the directory it names has been swapped. The
helper does not answer it either — it removes nothing at all, for exactly this reason,
and this shell has no better name to remove through than the one it published.

WHAT THE REMOVALS WERE FOR does not survive examination. The argument was that a copy
left at a published name is one an account watching that name can read the origin out
of — but the origin is `git remote get-url origin`, which anyone who can reach the
checkout can read anyway, and the directory is mode 700. It was hygiene, and hygiene
is not worth a class of defect that has now been found twice.

SO NOTHING IS REMOVED, and the whole class goes with it. The setup directory is the
session's and outlives the block regardless — it holds `work/`, the four files every
later stage writes into.

## A SQUATTED PIN NAME COSTS A SECOND NAME, NOT THE SESSION.

`pr-origin.sh pin` creates the directory it is given, exclusively, so a same-UID process
that pre-creates `$RB_SETUP_DIR/pin` makes that call report 2 — the storage status. The
name is derived from one published in argv, which is exactly the race
`docs/decisions/2026-08-26-transport-candidate-in-argv.md` accepts, and what makes that
acceptance hold is that a squat costs a RETRY rather than a session.

So a 2 is retried once, under a second name. `elif [[ $? -eq 2 ]] && …` reads the status
in its own condition, inside the same `if`, so nothing becomes a statement after a guard
— the shape `pr-origin.sh`'s own two-call retry uses, and for the same reason.

A FIXED SECOND NAME, NOT A RANDOM ONE. The value has to be spelled twice — once for the
call and once for the redirection that reads it back — and this shell has no name to hold
it in that a startup file cannot have made readonly or aimed elsewhere. A random suffix
would have to be recovered by a glob in a redirection, which is one more thing that can
match nothing or match twice. One retry is what the record bounds the cost at, and one
fixed name is exactly one retry.

## A PIN FAILURE IS TERMINAL, because the work files are already on this parent.

`pr-origin.sh pin` reports 2 where the STORAGE would not take what it asked, and every
other call in this block that can report 2 is retried under the second parent. This one
is not, and the reason is the ORDER the work moved into: `pr-setup.sh` allocates `work/`
and the four files BEFORE the driver pins, so by the time the pin runs this session is
already committed to one parent. Those files and `$RB_SETUP_DIR/pin` are in the same
directory and therefore on the same filesystem, so pinning under the second parent while
they stay where they are produces a session that looks set up and dies at its first
write — after it has posted.

A PROBE INSIDE THE HELPER WAS TRIED AND REMOVED, because it cannot answer its own
question. Keeping what it allocated is inodes the pin then cannot have — a filesystem
with exactly enough for setup and the pin passes the probe and fails the call, the probe
having made the state it was meant to detect. Releasing what it allocated means removing
a name inside the reservation, which is the class `pr-setup.sh` spent several rounds
getting out of and which `docs/decisions/2026-08-29-setup-leaf-cleanup.md` tabulates.

SO THE RECOVERY IS A RE-RUN, and the abort says so. `pr-setup.sh` is offered the failing
parent first on that run, reports 2 for the same reason, and the retry that already
exists moves everything — files and all — to the parent that works. That costs the
operator a command rather than the document a second copy of itself.

THE SQUAT IS A DIFFERENT CASE AND IS HANDLED, because it is the one an accepted record
bounds: a same-UID process pre-creating the pin's own name makes that call report 2, and
the claim above this one is the retry for it.

## THE FILE IS BOUND BEFORE IT IS READ, because a name can be replaced between the two.

`$RB_SETUP_DIR` is published in argv, so the name is one another process can act on.
The object is bound ONCE, by a redirection, and the tests and the read all go through
the descriptor rather than through the name: `9<"$RB_SETUP_DIR/origin"` opens what is
there at that instant, `-O` refuses a file another ACCOUNT owns, `-f` refuses anything
that is not a regular file, and `$(<"/dev/fd/9")` reads the object those two just
examined. A replacement arriving after the open changes the NAME and cannot change
what the descriptor refers to — measured directly.

WHAT THIS DOES NOT CLOSE is the window between `pr-setup.sh` exiting and the open, and
nothing inside this shell can: a file already replaced when the descriptor is bound is
the file that gets bound. `-O` is what stands there, so the residue is a replacement by
the SAME account — which is not a boundary, since that account can edit this session's
files directly.

ONE THING ABOUT IT IMPROVED AND THE REST DID NOT, and the difference is worth stating
exactly. While this file was SOURCED, a replacement was arbitrary CODE in the operator's
shell; it is a string now, so the worst case is a wrong repository rather than execution.

AND THAT WORST CASE IS WHAT THE PIN NOW ANSWERS. `rb_identity` asks whether the string is
a usable identity, not whether it is THIS checkout's, so it agrees with a planted-but-valid
remote — it is computed from the same value. `pr-origin.sh pin` used to agree for the same
reason, reporting `REVIEW_BUS_REMOTE` as a CHILD sees it and nothing more. It re-reads the
checkout now and refuses a pin that is not the identity this checkout FETCHES from — the
fetch URL, not the push destination, which `pr-close-round.sh` validates separately with
`--push --all` and which this does not replace. That is the question actually at stake,
is the question actually at stake and one this shell cannot ask: `git` is a name here and
is not a name there. A swap still gets a value past the read; it no longer gets a session
addressed to it. #230.

## WHAT WAS READ IS PROVED HERE, because a file is not a promise.

The helper proves the origin parses before it writes it. This shell proves it again,
and the duplication is deliberate: what the helper can vouch for is the file it
WROTE, and what this shell reads is the file that is THERE. Between the two is a
directory under a shared parent, and a same-UID process that replaces the file in that
window is what this shell binds.

THAT WINDOW IS NOT AN ACCEPTED ONE, and it must not be attributed to the record that
accepts the transport NAME. `docs/decisions/2026-08-26-transport-candidate-in-argv.md`
accepts a squat on the candidate BEFORE the `mkdir`, and what makes it acceptable is
measured: the exclusion means a squatter cannot put a value where setup will read it, so
the cost is a denial of service and never a forged identity. Here the file exists and the
helper has exited, so a replacement reaches the driver — a different window with a
different cost. What bounds that cost is the pin: it re-reads the checkout and refuses a
value that is not this repository's origin, so the replacement stops the session rather
than retargeting it. #230.

So the identity is re-derived from the value that was READ rather than trusted, and a
value that is empty, spans a line, or is not a usable identity is refused by expansion —
the same three refusals this block has always made about an origin.

## EVERY OTHER VALUE IS THIS SHELL'S OWN, ASSIGNED FROM A LITERAL.

The helper hands back the origin and nothing else, so the rest is assigned here: the two
reviewer logins, which are constants, and the four working paths, which are a literal
suffix under a directory this shell chose. Assigning them here rather than receiving
them removes the transport they used to travel in, and with it the `.` that carried it.

THAT THEY ARRIVED IS A SEPARATE OBLIGATION, and it has its own claim below. This one is
about PROVENANCE — where the values come from — and a future edit could satisfy it while
dropping the read-backs, or keep the read-backs while going back to receiving the values.
Merging the two would leave the bijection green over either half.

## THE ASSIGNMENTS ARE READ BACK, because a readonly name fails one in silence.

An assignment to a readonly name prints a complaint and does NOT fail the list it is
in — measured on bash 5, `VAR=value || abort` reports SUCCESS with the variable keeping
its old value. So the postcondition is the assertion: each name is compared against the
literal it was just given, and the four files are required to exist and be empty
besides. A `readonly SUMMARY_FILE` pointing somewhere else is what that catches, and it
is the same shape this block uses for `RB_REMOTE` — assign, then prove by reading back.

## ONE GENERIC TEST REPLACES THE ENUMERATION, because a list of names is wrong by omission.

Each name this block assigns before the helper runs is probed once, in a subshell:
assign a sentinel, check it came back, check it is not a nameref. That catches
`readonly`, `declare -i`, `declare -l`, `declare -u` and a nameref onto another of
these names with one test rather than one per attribute — and an attribute nobody
has thought of is caught too, because what is checked is whether the assignment
took, not which attribute prevented it.

The alternative was a check per attribute, which is a list, and `CLAUDE.md` records
what a list of names costs: the first version enumerated the attributes it knew and
was defeated by the next one.


EVERY NAME THIS BLOCK ASSIGNS IS IN IT, and the six added with the local assignments
are why that sentence is not decoration. `declare -n CODEX_BOT=OWNER` makes the
assignment below write through into the identity: `OWNER` becomes the reviewer login,
`$CODEX_BOT` still reads back as the login because it resolves through the same alias,
the working-file checks pass, and the child pin compares only `RB_REMOTE` — so setup
announces the bot as the repository owner and every later `gh` call is addressed at a
slug nobody chose.

RE-DERIVING THE IDENTITY AFTERWARDS WAS THE OTHER CANDIDATE and was rejected. It works
only if the read-backs run AFTER it, so it is an ordering constraint on a chain that
did not have one; and it answers this alias rather than aliasing generally, which is
the enumeration this section exists to have removed. `${!name}` asks the question for
any target, including ones no list would carry.
## EVERYTHING AFTER THE CALL IS INSIDE ITS SUCCESS ARM, so nothing walks past a refusal.

The refusals here are arms not taken rather than statements that have to terminate.
That is #224's answer applied to this block: `SKILL.md` runs in the operator's own
shell, where `echo` and `exit` are both names, and a refusal written as
`|| { echo …; exit 1; }` can be walked past by shadowing both — the arm runs, `exit`
returns instead of terminating, and the next statement is the one the refusal
existed to prevent.

A FLAG WOULD HAVE BEEN WORSE THAN EITHER. The first version of this rewrite set
`RB_SETUP_OK=yes` in the success arm and expanded it afterwards, which is the
sentinel shape #225 removed for exactly this reason: with `declare -i RB_SETUP_OK`
inherited, the clear stores `0`, the expansion finds it non-empty, and setup
continues as though the helper had succeeded.
