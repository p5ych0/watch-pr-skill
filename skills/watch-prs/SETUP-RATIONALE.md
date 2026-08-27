**Five constraints on this file, because the contract uses `grep` and not a parser.**

`test-pr-skill-contract.sh` compares the claims and the headings as exact strings.
It fails if a `# WHY:` names a claim that is not a heading here, or if a heading
here is named by no claim, or if either side carries a duplicate. It has no
Markdown parser, deliberately — an earlier version grew one to tell a real heading
from a fenced `## example`, and then needed tilde fences, indented fences, info
strings, HTML comments and their ordering; `CLAUDE.md` records what a text scanner
of that kind cost this repository once already.

So the constructs that would make a `grep` lie are forbidden here rather than
parsed around, and each is one `grep` with its status taken:

- **every `## ` line is a claim.** A transcript line that would begin with `## ` is
  indented by one space so it is not a heading;
- **every heading is `## ` followed by text.** `## ` alone reduces to an empty
  record that command substitution strips, and a bare `##` is a heading the scan
  never sees — either way a section exists that no claim introduces;
- **no raw HTML.** A comment can wrap a section and a block such as `<div>` can
  swallow one, and Markdown then renders neither as sections;
- **no fence.** A section wrapped in one keeps its `## ` line while the whole thing
  renders as code, so the two transcripts here are INDENTED by four spaces;
- **no setext underline.** Text followed by `---` is a level-two heading that
  `^## ` cannot match, so an argument could sit here with no claim at all.

**That list is what has been found, not a proof.** Each entry was a live fail-open
caught in review, and the one before it looked complete at the time. What holds it
together is the shape rather than the enumeration: this file is plain prose and
indented code, and every construct that creates or conceals a heading is refused.
If a sixth turns up, add it here and to the staged document in the fixture — which
carries all of them, so a guard cannot be deleted unnoticed merely because this
file happens not to contain the form it refuses.

# Why setup is shaped the way it is

The argument behind the **Derive identity** block of the `SKILL.md` beside this file,
one section per claim.

Each section is pointed at from the block by a `# WHY:` line sitting directly under
the claim it belongs to, naming `$RB_SCRIPTS/../SETUP-RATIONALE.md`.

That path rather than a bare relative one, because the driving shell stays in the
project being reviewed — `docs/…` there would name that project's documentation.
And `$RB_SCRIPTS` rather than `$CLAUDE_PLUGIN_ROOT`, because setup has a second
discovery mode: where the plugin-root variable is unset it finds the newest
installed copy itself, and a pointer built from the empty variable would read
`/docs/…`. `RB_SCRIPTS` is set and validated in BOTH modes, which is why this file
sits beside `SKILL.md` rather than under `docs/`.

**The claim IS the key.** Each heading below is, character for character, the
comment line the pointer sits under. So a reader greps the claim they just read;
there is no id to follow, none to mistype, and two pointers cannot be swapped
without swapping the claims above them, which changes nothing.

**These are not notes.** `CLAUDE.md` records that *a comment that argues against the
code beside it is an instruction, and it will be followed*. Each section below is a
defect that was shipped, found and paid for. Before changing a line the block
guards, read the section its claim names — the shape almost always looks
gratuitous until you do.

**Three constraints on this file, because the contract uses `grep` and not a parser.**

`test-pr-skill-contract.sh` compares the claims and the headings as exact strings.
It fails if a `# WHY:` names a claim that is not a heading here, or if a heading
here is named by no claim, or if either side carries a duplicate. It has no
Markdown parser, deliberately — an earlier version grew one to tell a real heading
from a fenced `## example`, and then needed tilde fences, indented fences, info
strings, HTML comments and their ordering; `CLAUDE.md` records what a text scanner
of that kind cost this repository once already.

So three things are forbidden here rather than parsed around, and each is a `grep`:

- **every `## ` line is a claim.** A transcript line that would begin with `## ` is
  indented by one space so it is not a heading;
- **no HTML comment.** One can wrap a section and hide it from every check while
  Markdown renders nothing;
- **every heading is `## ` followed by text.** `## ` alone reduces to an empty
  record that command substitution strips, and a bare `##` is a heading the scan
  never sees — either way a section exists that no claim introduces;
- **no fence.** A section wrapped in one keeps its `## ` line while Markdown
  renders the whole thing as code, so the two transcripts here are INDENTED by
  four spaces instead;
- **no setext underline.** Text followed by `---` is a level-two heading that
  `^## ` cannot match, so an argument could sit here with no claim at all.

Those are all of them. A heading can be hidden (a comment, a fence), faked
(setext), or made unmatchable (`## ` alone, a bare `##`), and each is refused by
one `grep` with its status taken — and by a staged document in the fixture, so a
guard cannot be deleted unnoticed just because this file happens not to contain
the form it refuses.

## THE TRACE IS MOVED OFF THE CAPTURE BEFORE ANY `$( )` RUNS, or xtrace lands inside the value.

THE TRACE IS MOVED OFF THE CAPTURE, BEFORE ANY `$( )` RUNS. `BASH_XTRACEFD=1`
sends xtrace to file descriptor 1 — and inside `X="$(cmd)"` fd 1 IS the capture,
so the trace of `cmd` is assigned to `X` along with its output. Measured:

    SHELLOPTS=xtrace BASH_XTRACEFD=1 bash -c 'X="$(printf hello)"; echo "[$X]"'
    [++ printf hello
    hello]

Every substitution in this block is affected — the repository root, the plugin
discovery, the `mktemp`, the `type -t` probe — so it is one property of the
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

Same rule as every probe here: the status is taken. This path is handed to
`pr-merge-range.sh`, which inspects history in it to decide whether every commit
since the reviewed SHA is a review fix — so a directory retained from a failed
probe is a merge decision made about the wrong tree.

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
name in it to shadow — the value is read once, here, and travels in the
environment.

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

TWO DIRECTORIES, NOT ONE, AND EACH GONE AS SOON AS ITS VALUE IS READ. The origin
read and the pin probe are separate calls at separate times, and the second is
behind the first's success; sharing one directory would mean keeping it open
across the whole of setup for no gain. `-m 700` is applied by `mkdir` itself, so
there is no interval between creation and use in which anything can be placed
inside.

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
`RB_PIN_OUT` — each with a probe and each a thing this shell had to defend; two
remain per stage, because the helper owns the rest. A readonly or
value-transforming one in the long-lived driving shell survives an assignment and
leaves a STALE value behind, and a stale `/somewhere/owned` then passes every
check: its `origin` is read as this session's remote and the cleanup deletes it.

A SUBSHELL, ONE MIXED-CASE VALUE, COMPARED INSIDE. The subshell inherits the
attribute, so a readonly fails there and a `declare -i` or `declare -l` stores
something else and the comparison catches it — and as an `if` CONDITION the
failure is contained, which a bare assignment is not: under `errexit` a failed
readonly assignment ends the session where it stands. #151.

AND IT READS ANOTHER NAME BACK, because reading its OWN back cannot see an
ALIAS. `declare -n RB_ORIGIN_DIR=RB_REMOTE` passes an assign-and-read-back probe
perfectly: the assignment works and the value returns. The two are then the SAME
VARIABLE, so the origin read — which sets `RB_REMOTE` — silently changes
`RB_ORIGIN_DIR` before the cleanups run. For a local origin such as
`/tmp/victim` they remove `/tmp/victim/origin` and try to remove `/tmp/victim`.

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

## THE CLEAR IS A CONDITION, WITH EVERYTHING THAT DEPENDS ON THE VALUE AS ITS ARM.

AND THE CLEAR IS A CONDITION, WITH EVERYTHING THAT DEPENDS ON THE VALUE AS ITS
ARM. Written as a guard it prints and RETURNS once `exit` has been replaced —
the descriptor assignment further down cannot overwrite a readonly either, and
its refusal returns the same way, so the stale non-empty URL reaches the
identity parser, passes it, and is exported. Every request, signoff, revocation
and merge for that session is then addressed at a repository the operator's
environment chose. #155.

THE CLEAR ITSELF STAYS OUTSIDE IT. Inside a compound command a failed readonly
assignment ends the shell BEFORE the test that would have named the variable —
measured, and a containment reverted over it — so the assignment is out here
where its own diagnostic survives, and the TEST is the condition.

THE ARM RUNS TO THE END OF SETUP, because the pin is the last thing here and
what it pins is this value. With the continuation contained there is nothing
after the final `fi` at all.

## ONE GENERIC TEST REPLACES THE ENUMERATION, because a list of names is wrong by omission.

ONE GENERIC TEST, WHICH REPLACES THE ENUMERATION ENTIRELY. Thirteen names were
found one review round apiece — `HOME`, `TMPDIR`, `REPO_DIR`, `RB_SCRIPTS`,
`PATH`, `HOST`, `OWNER`, `REPO`, `IFS`, the operator knobs, the reviewer
logins, `GIT_DIR`, `CDPATH` — and the last two showed the list could never be
completed: it would have to union what this driver reads, what its tools read,
and what the SHELL ITSELF consults, and the last grows with the shell version.

`${!name}` IS THE ANSWER, and it is portable. For a NAMEREF it expands to the
TARGET'S NAME; for an ordinary variable it is indirect expansion — the value
of the variable NAMED by this one. So assign a value that is a legal variable
name and cannot be a set one, and ask whether `${!name}` is empty: an ordinary
variable names nothing and gives nothing, and a nameref gives whatever it
points at, whether that is `HOME`, `GIT_DIR`, `CDPATH` or something no list
here would ever have carried.

AND IT WORKS WHERE `[[ -R ]]` CANNOT. `-R` answers the same question in one
word and is bash 4.3+, and on 3.2 an unknown unary operator inside `[[ ]]` is
a PARSE error, so the whole block would fail to parse on the shell
`macos-shell` exists to cover. Indirect expansion is bash 2, and on a shell
with no namerefs it simply reports nothing — which is the right answer there,
since nothing can be one.

THE VALUE IS BUILT FROM `$$` AND `$RANDOM`, not fixed. A fixed sentinel
COLLIDES: with two fixed pairs and an operator holding one value from each,
both pairs failed and a shell nothing had corrupted was refused.
`RbProbe$$$RANDOM$RANDOM` is a legal variable name, and the only way to
collide is to have a variable of exactly that name already set.

`$$` IS THERE BECAUSE `RANDOM` CAN BE UNSET. `unset RANDOM` removes its
special behaviour and every later `$RANDOM` is empty, which would leave a
FIXED `RbProbe` — back to a value an operator can hold. `$$` is the shell's
own pid and cannot be unset, so the sentinel stays per-session whatever has
been done to `RANDOM`.

AND WHAT THAT STILL DOES NOT STOP, STATED RATHER THAN CHASED. A startup file
runs IN THIS SHELL, so it knows `$$` and it can read this file: with `RANDOM`
unset it can pre-seed `RbProbe$$` and the probe reads their value through
`${!name}`, concludes "nameref", and refuses. No mechanism here can close
that, because every input to the sentinel is either public or something the
same file can unset — which is the boundary `CLAUDE.md` records as "nothing
inside a process can distinguish the honest version of something it
inherited", and #102 and #91 draw in the same place.

WHAT IT COSTS IS A REFUSAL, WHICH IS WHY IT IS ACCEPTABLE. The failure is
fail-CLOSED: setup stops, nothing is forged, nothing is pinned. A startup
file that wants to stop this session can call `exit` in its first line, so
the attack buys an adversary nothing they did not already have — and the
honest version of the same state, an operator who happens to hold that
variable, is vanishingly unlikely to have a name shaped like this one.

AND THE PREFIX MATCH IS THE OTHER HALF, IN MIXED CASE. A readonly leaves the
old value, `declare -i` stores `0`, `declare -l` lower-cases it and
`declare -u` upper-cases it — and an ALL-CAPS sentinel survives `declare -u`
unchanged, which is how that one attribute got through. `RbProbe*` matches
neither transformation, so the same two lines catch every attribute as well as
the alias.

## THE PIN NAMES GET THE SAME GENERIC TEST, for the reason the transport probe gives.

The argument is the one above, not a second copy of it: the pin probe guards
`RB_PIN_DIR`, `RB_PIN_DIR2` and `RB_PIN_SEEN` exactly as the transport probe
guards its four, and for the same reason — a list of names is wrong by
omission, and `${!name}` answers generically what an enumeration cannot.

It has its own claim because it is its own SITE. Sharing one claim between two
places in the block meant a claim could be deleted from one of them and added
anywhere else, and every count still balanced; with one claim per site the
mapping to this document is one-to-one, and a claim that moves or goes is a
number that no longer matches.

See the transport probe's section above for what the test does and what it still
cannot stop.

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
BOTH: the helper reports 2 for either, the `elif` reads that status in its
own condition, and the read-back stays inside the arm that names its
directory. A second copy of the read-back is the price, and it is the one
this block can pay — a branch on the status OUTSIDE the arm is the
walked-past-guard class this block exists to close, and there is not one.
#161.

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
survives — so with a STALE `RB_ORIGIN_DIR` from an earlier run in the
same long-lived shell, the refusal fired and the helper was then invoked
with the previous session's path. Clearing it immediately before means an
abandoned assignment leaves EMPTY, and an empty argument is one the helper
refuses by name. That is a removal rather than a guard: there is no
condition here for a shadowed `exit` to walk past, because there is no
value left to walk past it WITH.

## THE SECOND CANDIDATE IS EMPTY WHERE THERE IS NO SECOND PARENT.

AND THE SECOND, EMPTY WHERE THERE IS NO SECOND PARENT. Cleared first for
the reason the first one is: an abandoned assignment leaves the OLD
value, and a stale path from an earlier run in the same long-lived shell
would become this session's retry.
A LITERAL DISCRIMINATOR IN THE LEAF, so the two names differ without
`$RANDOM`. `unset RANDOM` removes its special behaviour — it expands to
nothing thereafter — and with `TMPDIR` and `HOME` naming one directory
both candidates then reduce to the same `watch-pr.$$.` path, so a retry
after a taken name submits the name that was taken.

## THE READ AND BOTH REMOVALS ARE THE HELPER'S SUCCESS ARM, not statements after a guard.

THE READ AND BOTH REMOVALS ARE THE HELPER'S SUCCESS ARM, not statements
after a guard. `mkdir` is what proves this shell's helper created that
directory, and it is the helper that runs it — so a REFUSED call means
the name was already something, and something is not ours. Written as a
guard the refusal was walked past by a shadowed `exit` and the lines
below then read a pre-existing `origin` owned by this user, which passes
`-O` and `-f`, and pinned the session from it — and removed the
operator's file and directory on the way out. Containment is what a
neutralised `exit` cannot step over.

## THE READ-BACK IS THE CALLER'S HALF AND STAYS HERE, where the descriptor can be checked.

THE READ IS THE CALLER'S HALF AND STAYS HERE. `-O` and `-f` are asked
of the OPEN DESCRIPTOR, so they describe the object this shell is
about to read rather than a name it could be talked into looking up
twice.
AND A REFUSED READ REMOVES WHAT THE HELPER LEFT. The helper cleans up
after its OWN refusals — it created the directory — but a read this
side rejects leaves a written file in a directory nothing else will
remove. The obligation follows whoever the refusal belongs to.
AND THE TWO CLEANUPS ARE DISJOINT ARMS, not a rejection arm followed
by an unconditional one. Written that way the rejected path removed
the leaf and the directory, then `exit` — a name — returned, and the
lines below removed them AGAIN: on a shared sticky parent a watcher
that learned the candidate from the helper's argv can put a symlink
at the freed name between the two, and the second `rm -f` follows it
into a file this run never created. Same defect the helper's own
cleanup had, on this side of the call.

## THE EXPANSION IS FIRST, AND THAT ORDER IS THE WHOLE OF IT.

THE EXPANSION IS FIRST, AND THAT ORDER IS THE WHOLE OF IT. `echo`
is a NAME, and one that both forges a value and neuters `exit`
walks straight past everything below it:

    echo() { RB_REMOTE=git@github.com:attacker/other.git
             exit() { return 0; }; }

`echo` runs, the assignment has happened, `exit` returns, and
`[[ -n "" ]]` ends this `if` list false — which is containment
doing exactly its job and still leaving the forged URL in hand
for the identity parser, which validates FORM and not origin.
Reached before any of that, `${RB_REMOTE:?…}` is the shell
refusing to expand: no command runs, so there is nothing to
shadow, and a non-interactive shell ends there. #178.

AND IT ALWAYS FIRES HERE, which is what makes the order enough.
This arm is the read-backs failure, and the read-back is the
only thing that assigns `RB_REMOTE` — the clear far above is a
CONDITION with this whole block as its arm, so a value a startup
file pre-set never reaches here at all.

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

AN `elif` READS THE STATUS WITHOUT LEAVING THE `if`. `$?` after a failed
condition is that command's, `[[` is a reserved word, and the read-back
stays contained in the arm below — so the distinction is usable without
anything becoming a statement after a guard. And each arm knows exactly
which directory the helper just created, because it named it: there is
nothing to guess and therefore nothing to race.

THE READ-BACK IS WRITTEN TWICE, and that is the price. A function would
hold it once and cannot be used: `return` is a name a startup file can
replace with one that does not return, and `readonly -f` makes this
document's own definition fail so an inherited one runs. `CLAUDE.md`
records both. Two copies of a correct read-back beat one copy of a guess.

AND A REFUSED FIRST ATTEMPT HAS ALREADY SAID WHY, on the helper's stderr,
naming the component and the reason. That is what makes retrying under
the other parent honest rather than a silent route around it — which is
the defect the old candidate loop had. The note below says a retry
happened; the helper's line above says what it is retrying past.
NOTHING RUNS IN THIS ARM THAT IS NOT A REDIRECTION OR AN EXPANSION, and
the announcement that used to is why it is stated. A note here is an
`echo`, and `echo` is a NAME. In the CONDITION, a function by that name
runs immediately before `$RB_SCRIPTS` and `$RB_ORIGIN_DIR2` are expanded
for the call and can point both at a script and a directory of its own.
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

NOT A BRANCH OUTSIDE THE ARM. `elif [[ $? -eq 2 ]] && helper …; then` is a
condition of this same `if`, so the read-back below stays contained in the
arm that names its directory — nothing here is a statement after a guard,
which is the shape #155 and #158 removed. `[[` is a reserved word and `$?`
is a shell parameter, so neither is a name anything can take.

AND `$?` IS TAKEN BEFORE ANYTHING ELSE RUNS, which is why the emptiness
test comes second: a command between the two would replace it.

## THE PARENT THAT WORKED BECOMES THE PRIMARY ONE, or the session dies one step later.

THE PARENT THAT WORKED BECOMES THE PRIMARY ONE, which is what makes
this a fix rather than a partial one. `RB_TMPPARENT` is what the pin
probe and the working directory are built from further down, so
leaving it on the parent that just refused meant the origin was read
from `HOME` and the session then died allocating its working directory
under the same full `TMPDIR` — the exact state this retry exists for.
The refused one stays as the second candidate: retrying there later is
pointless where the filesystem is full and correct where the first
name was simply taken.

## THIS ARM IS REACHED THREE WAYS AND SAYS SO IN ONE MESSAGE, because it cannot tell them apart.

THIS ARM IS REACHED THREE WAYS AND SAYS SO IN ONE MESSAGE, because it
cannot tell them apart — the first call refused and the second either
was not made or refused as well. The helper has named each attempt it
made on stderr, so the message points at those lines rather than
counting them; see IT DOES NOT COUNT THE ATTEMPTS below, which is the
whole of why. The advice that used to live here — unset `TMPDIR` and
re-run — is what the retry now does where there IS a second parent and
the first refusal was retryable, so repeating it would send the
operator to do again what already happened. #161.

THE EXPANSION IS THE MESSAGE, because `echo` is a NAME and this line is
the whole of what the change does: an `echo` that returns without
printing leaves the arm silent, and the operator back where they
started. `${VAR:?…}` is the shell refusing to expand — no command runs,
so there is nothing to shadow — and it is the same form the parent
selection above already uses. `RB_REMOTE` is the name because it is
the one this arm is reached with UNSET: the read-back never assigned
it. No new name is introduced, so nothing new has to be probed.

AND THE EXPANSION ALWAYS FIRES HERE, which is worth stating because
the obvious reason to keep the `echo` behind it is wrong: a startup
file that pre-set `RB_REMOTE` never reaches this arm at all. The clear
far above is a CONDITION with this whole block as its arm, so a value
that survives it takes the readonly refusal instead, and one that does
not leaves `RB_REMOTE` empty — which is what `:?` fires on. The `echo`
and the `exit` stay as the shape every other arm in this block has,
and would carry the refusal if a later change ever left a value here;
they are not a second channel for a state that exists today.

QUALIFIED, BECAUSE THIS ARM IS EVERY REFUSAL. The helper refuses for an
unreadable `origin`, an ancestry another account owns and an
unresolvable path as well as for storage it could not use, and the
storage one is the only one this line is about. So it names the REPORT
it applies to and leaves the rest to the helper's own line above.

ON WHAT THE REPORT NAMES, NOT ON `TMPDIR` BEING SET. Selection can
REJECT a set `TMPDIR` — a relative one, or one the mode bits refuse —
and choose `HOME`; the failure is then under `HOME`, and "if TMPDIR is
set" sends the operator to unset something already ignored.

CREATE OR WRITE, because the helper refuses on both and the storage
failure is the same one: a filesystem that accepts the directory can
fill, hit quota or go read-only while the leaf is written. Enumerating
the two diagnostics was the alternative and it is the shape this
repository has paid for twice — the advice keys on what the report
NAMES rather than on which of the helper's sentences produced it.

AND EXHAUSTION IS NOT INFERRED FROM THEM. Both of those refusals also
cover a name another account got to first, where the filesystem has
room and re-running is the whole fix. So the cheap answer comes first
and storage is what to look at when re-running keeps failing —
asserting a full filesystem from a diagnostic that does not say so
sends the operator to change storage for a race.

A NEW SESSION, NOT `unset TMPDIR` IN THIS ONE. `unset` is a name, the
variable may be readonly, and on bash 4.3+ a `declare -n TMPDIR=HOME`
makes `unset TMPDIR` destroy `HOME` in the operator's long-lived shell
— after which the re-run aborts one step earlier than before. Starting
a session without the override needs none of that to be true.

AND `HOME` IS NOT AUTOMATICALLY AN ESCAPE. `/tmp` and a home directory
share the root filesystem on many machines, so a full one or a
filesystem-wide quota is not something falling through to `HOME`
escapes. The line says so rather than promising a recovery that
re-runs into the same storage.
AND NO APOSTROPHE IN IT. Inside `${…}` bash treats a single quote as
a QUOTE even within double quotes, so one apostrophe in this message
leaves the brace expansion unterminated and the whole block fails to
parse — five hundred lines below, where nothing points back here.
`test-pr-skill-contract.sh` parses the lifted block, which is what
caught it; the phrasing avoids the character rather than escaping it.
AND IT DOES NOT COUNT THE ATTEMPTS, because it cannot. Reaching this
arm means the first call failed and the second either was not made or
failed too — and the three reasons it was not made are different: there
was no second candidate, or the first refusal was TERMINAL and the
status gate skipped it, or it ran and refused as well. Telling them
apart here needs the first call's status carried in a variable, which
is another name for a startup file to make readonly, for a claim the
operator can read off the lines above anyway.

TWO MESSAGES CHOSEN ON `RB_ORIGIN_DIR2` WAS THE PREVIOUS SHAPE, and it
was wrong for exactly the middle case: a terminal first refusal with a
second candidate present said two attempts were made when the gate had
correctly skipped the second.

## THE EXPANSION IS THE REFUSAL, NOT A GUARD IN FRONT OF ONE.

THE EXPANSION IS THE REFUSAL, NOT A GUARD IN FRONT OF ONE. This was
`[[ -n $RB_REMOTE ]] || { echo …; exit 1; }`, and a startup file that defines
`exit` as a function which RETURNS makes that group print and carry on — with
an empty origin, into the identity parse, the export and the pin. There is no
containment on a `||` group: it is a statement, and the statement after it
simply runs.

`${RB_REMOTE:?…}` fires on exactly the state the guard tested — unset or
EMPTY — so the check and the refusal are one thing the shell does. #181.

AND IT IS AN ASSIGNMENT, NOT `: "${…}"`. `:` IS A NAME — a startup file can
define a function called `:`, and on the ORDINARY path the expansion SUCCEEDS
and that function then runs with the value as its argument, free to replace
`RB_REMOTE` before the identity parse. The refusal path was never the exposed
one; the success path is, and there is one on every session. An assignment is
handled by the parser, so there is no command to invoke, and assigning the
value back to the name it came from introduces nothing new to be readonly or
transforming — `RB_ORIGIN_DIR="${RB_TMPPARENT:?…}/…"` above is the same idiom.

## THE TRANSPORT FILE IS REMOVED WHETHER OR NOT THE READ SUCCEEDED.

THE FILE IS REMOVED WHETHER OR NOT THE READ SUCCEEDED. It holds one line of
public information, so this is tidiness rather than secrecy — but the setup block
already allocates one temporary and `test-pr-skill-contract.sh` counts what a run
leaves behind, so a second one that survives a refusal would be a leak the suite
reports and nobody meant.

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

## THE PIN PARENT IS REQUIRED BY THE EXPANSION, or an empty one builds a path from nothing.

AND THE PARENT IS REQUIRED BY THE EXPANSION HERE TOO, for the reason the
origin read gives: an empty one built `/watch-pr-pin.…` from nothing.
CLEARED FIRST, for the reason the origin read gives: interactively the
expansion abandons its own command and a stale `RB_PIN_DIR` from an
earlier run in the same shell would otherwise be what the helper is
handed.

## THE PIN REMOVALS ARE THE HELPER'S SUCCESS ARM TOO, for the reason the read above states.

THE REMOVALS ARE THE HELPER'S SUCCESS ARM TOO, for the reason the read
above states: a refused call means the `mkdir` inside the helper found
the name already taken, so the directory and the file in it are the
OPERATOR'S — and `rm -f` deletes that file while `rmdir` deletes the
directory whenever it is empty, which an operator's directory often is.
Written after the call they ran on every path, including that one.

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

## THE SESSION'S THREE WORKING FILES COME FROM ONE ALLOCATION.

THE SESSION'S THREE WORKING FILES, FROM ONE ALLOCATION. Files rather than
shell variables: the text is long, contains backticks and quotes, and passing
it inline mangles it — and the baseline comes back in one because a variable is
a name a startup file can have made readonly, which `pr-origin.sh` settled the
same way. Freshly created per PR and per session, because a reused path is how
a stale summary from another round — or another PR — gets posted as if it were
this one's.

ONE DIRECTORY, AND THE THREE PATHS DERIVED FROM IT. Three `mktemp` calls made
them three separate answers, and `mktemp` is a NAME: a function returning the
same existing empty path each time passes every validation and leaves all three
ALIASED. Writing the opening account would then populate the round-summary
file, and a first round that missed its own summary write would post that
account as the summary and request another pass — the exact regression the
separate files exist to prevent. Derived by literal suffixes there is nothing to
make equal: the distinctness is in the source, not in what a command returned.

AND NO `mktemp` AT ALL, WHICH IS THE SAME ANSWER THE TRANSPORT DIRECTORY ABOVE
ALREADY GIVES. The path is BUILT by expansion — `$$` and `$RANDOM` are the
shell's own, so nothing runs and a driving shell tracing to fd 1 has nothing to
write into the value. `mkdir` IS THE EXCLUSION: it fails if the name exists, so
an account on this machine that guesses the name gets nothing rather than a
file this session then writes through, and `-m 700` is applied by `mkdir`
itself, so all three files inherit that protection rather than each needing its
own. It runs through `/usr/bin/env` for the reason every other command in this
block does.

THE PARENT IS THE ONE ALREADY PROVEN — absolute, a directory, and one this user
could create under. Choosing it a second time would be a second copy of the
loop above, which is the defect this document keeps deleting.
ASSIGNABLE FIRST, AND ASKED IN A SUBSHELL — the probe the transport parent
above already uses, and for the reason it gives. ONE value, because the
subshell is where the assignment happens: a readonly pre-seeded with the
probe's own value makes it fail outright there, so the comparison inside
is never reached. Two unequal values were what a comparison in THIS shell
needed, and that comparison is gone.

THE SHAPE CHECK BELOW IS NOT WHAT STOPS ONE. It matches a PREFIX, and a readonly
value such as `…/watch-pr-work.anchor/../elsewhere/session` satisfies it while
naming a directory under a parent nothing proved — `mkdir` resolves the `..`,
and another account owning that parent could then replace the directory and with
it the account this session posts and the baseline it waits on. It stays as a
statement of the shape; the probes are what make the value this session's.
EVERY FAILURE ARM EXCLUDES THE WORK STRUCTURALLY, rather than ending it. `exit`
is a builtin a startup file can replace with one that RETURNS, and this bash
runs in the operator's own shell — so a guard written as
`… || { echo …; exit 1; }` prints and then carries straight on to the next
line. With `RB_WORK_DIR` readonly to an existing directory that meant reaching
the three redirections below and truncating `summary.md`, `request.md` and
`prior.txt` inside it. `[[ -n "" ]]` is not the answer here either: it makes the
LIST report non-zero, which nothing reads. The allocation is one condition and
the files are its `then`, so a failed arm cannot reach them whatever `exit` was
made to do. Each cause still names itself, from inside the condition, ending in
a reserved word so the arm is false however `echo` was replaced.
ASKED IN A SUBSHELL, WHICH IS WHAT MAKES IT SAFE TO ASK. It was two
unequal assignments read back here, because one proves nothing against a
readonly holding the probe's own value — and both were assignments in
THIS shell, which is the operator's, where a failed readonly assignment
under `errexit` is FATAL. The probe ended the session in exactly the
state it exists to detect. A subshell inherits the attribute, fails for
the same reason, and as a condition is exempt. The value is compared
INSIDE it, because a TRANSFORMING attribute — `declare -i` — lets the
assignment succeed and stores something else, which a status-only probe
accepts. One value is enough: a readonly pre-seeded with the probe's own
value makes the subshell's assignment fail outright, so the comparison
is never reached. #148.

## THE WORKING-DIRECTORY PARENT IS REQUIRED TOO, and is not redundant with the two above.

THE PARENT IS REQUIRED BY THE EXPANSION HERE TOO, and it is
not redundant with the two above: the prefix check on the
next line compares against `$RB_TMPPARENT`, so with an EMPTY
one it reads `[[ /watch-pr-work.X = /watch-pr-work.* ]]` and
AGREES — the check that exists to keep this under the proven
parent is the check an empty parent satisfies. Reaching here
with one requires the pin to have succeeded, which the clears
above make impossible; stating the requirement locally means
that argument does not have to be re-derived three blocks
away.

## THE OPENING ACCOUNT IS NOT THE ROUND SUMMARY, and they must not share a file.

The opening account, which is NOT the round summary. Sharing one file meant
that a first round whose summary write did not happen left the OPENING
account sitting there — non-empty, well-formed, and about the right PR — so
`pr-close-round.sh` posted it as the round summary and requested the next
pass instead of refusing to close. The round-summary file has to be empty
until that round writes it, and that is only true if nothing else writes it.

## THE WORKING FILES ARE CREATED EMPTY BY REDIRECTION ALONE, so there is no command name to shadow.

CREATED HERE, EMPTY, BY REDIRECTION ALONE — no command name, so there is
none to shadow, and a redirection that cannot be made reports it:
measured, a `> path` into a directory that does not exist is status 1.
Each is then proven present and empty. A missing one fails closed later
anyway — the request's `<` refuses and `pr-close-round.sh` cannot read
its summary — but "fails closed later" is not a reason to leave setup
unable to say so.
