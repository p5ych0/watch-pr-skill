#!/usr/bin/env bash
# How a value crosses to the caller in a file the CALLER named. Sourced, never executed.
#
# NOT named `test-*.sh`: `pr-selfcheck.sh` and CI both run every `test-*.sh` as a test, and
# a library that ran as one would report a vacuous pass.
#
# WHY THIS EXISTS
#
# Three values cross from a helper to the driver in a file whose path the driver chose: the
# gated head from `pr-close-round.sh`, the review baseline from that helper and from
# `pr-copilot-phase.sh open`, and the signed-off sha from `pr-copilot-phase.sh record`.
# Every one of them was written as `printf … > "$THE_PATH"`, and `>` FOLLOWS A SYMLINK.
#
# So a same-UID process that replaced one of those paths with a symlink had the symlink's
# TARGET truncated — an arbitrary file of the operator's, outside the session's working
# directory entirely, on every invocation that got that far rather than only on a refusal.
# That is #263. COUNTED FROM THE TREE, there are TEN call sites in THREE helpers today: six
# in `pr-close-round.sh` — the two pre-bootstrap emptyings, the two `gate` emptyings, the
# head write and the baseline write — three in `pr-copilot-phase.sh`, and one in
# `pr-request-review.sh`. The issue was opened over the handoff WRITES in two helpers; the
# bare `>` emptyings were found next, and the last one only in review — the driver's own
# `> "$PRIOR_FILE"` around `pr-request-review.sh`, which now takes the path and writes it
# here. That last one is the argument for counting from the tree rather than from the
# issue: its unsafe open was in `SKILL.md`, so an audit reading the helpers would not have
# found it at all.
#
# WHAT THIS DOES INSTEAD: WRITE, THEN RENAME.
#
#   1. create a temporary beside the target, EXCLUSIVELY, with `O_CREAT|O_EXCL`
#   2. write the value into it and take the status
#   3. `mv` it over the target
#
# THE RENAME IS THE WHOLE POINT. `rename(2)` replaces the NAME, so where the target is a
# symlink it is the symlink that goes and never the file it points at. Measured both ways:
# `> target` on a symlink truncates the victim, and `mv src target` on the same symlink
# leaves the victim's bytes untouched and puts a regular file at the name.
#
# AND IT IS NOT A CHECK-THEN-OPEN GUARD, which #245 already convicted and which this must
# not reintroduce. The distinction is NOT that nothing is asked and NOT that nothing is ever
# opened — the type test below asks exactly what is at the target and is load-bearing, and
# the value postcondition OPENS the target to verify it. It is that nothing opens the target
# TO WRITE IT: the value goes into a temporary and is RENAMED onto the name, so the answer
# the type test gave is not what the write's safety rests on. A racer who changes the answer
# afterwards costs the RACER their inode, not the operator a file: the rename replaces
# whatever non-directory thing they installed, the value arrives, and the call returns 0.
# That is the documented limit below, not a refusal — do not read this paragraph as one. #245's shape was a test
# whose answer licensed a WRITING open of the thing tested. The verifying open is on the
# other side of the rename and carries its own no-follow, non-blocking, fstat-on-the-handle
# answer, so it licenses nothing either.
#
# IT ANSWERS WHAT THE CALLER NAMED, AND IT IS ASKED ONCE. A special inode a RACER installs
# after this test is REPLACED by the rename rather than refused: `rename(2)` takes any
# non-directory destination, and no rename reachable from a shell can be made conditional on
# the destination's type — a re-check before the rename is the same race one instruction
# later. That is a bounded outcome rather than a hole, and the bound is who can be hurt: the
# inode is in the session's own working directory, so anything appearing there mid-write was
# put there by a process that already writes that directory, and what it loses is its own.
# An operator's FIFO or device at the path was there when this was asked, and IS refused.
# Do not add the re-check; state the limit.
#
# A SQUATTER ON THE TEMPORARY COSTS A REFUSAL, NOT A TRUNCATION. The name carries the
# caller's path and this shell's pid, and a same-UID process that gets there first makes the
# exclusive create fail — whatever it left, of whatever type, since `O_CREAT|O_EXCL` refuses
# any existing path. The run stops with nothing written and nothing renamed.
#
# NO BOUND HERE, AND THE CALLERS KEEP THEIRS. This library sets no watchdog of its own: it
# is a shell function, and `run_limited` bounds a COMMAND. That is a fact about where the
# bound can live, NOT a claim that none is needed — read the other way it invites a
# maintainer to drop the three that exist and recreate a hang with the phase half-open.
#
# WHAT THE EXCLUSIVE CREATE SETTLES IS THE FIFO AND ONLY THE FIFO. A plain `>` on a
# caller-named path waits for a reader that never comes; the exclusive create makes that open
# fail instead — `set -C` did NOT, which is #271: bash's noclobber fails a redirection only
# where the existing file is REGULAR, so a FIFO at the temporary's name was opened and the
# write blocked. It does not make this function non-blocking: pathname resolution, the write and
# the `mv` can each stall on an unresponsive filesystem. So the three call sites that were
# bounded still are, with `run_limited` moved around a CHILD that sources this library —
# `pr-copilot-phase.sh`'s readiness, baseline and sha writes, the second of which stands
# after the Copilot-signoff revocation, where a hang leaves the phase half-open with no
# diagnostic. THERE ARE NO READ-BACKS BESIDE THEM ANY MORE: those callers each re-proved the
# bytes on a descriptor of their own, and #271 removed all three — this library's own
# postcondition answers the same question earlier and with an open that cannot block or
# follow a link. A caller-side read-back is a regression, not an extra layer.
#
# NOTHING IS REMOVED, INCLUDING ON FAILURE. This library never unlinks — not the temporary,
# not anything — and a failure BEFORE the rename therefore leaves the temporary behind. A
# failure REPORTED BY the rename is not a promise of that: `mv -T` can complete the syscall
# and still exit non-zero, after which `perl` finds the source gone and the refusal arrives
# with the target replaced and no temporary anywhere. The rule is about what this code does,
# which is nothing; it is not a guarantee about what is left. The reason it removes nothing
# is that `docs/decisions/2026-08-29-setup-leaf-cleanup.md`
# convicts the whole class, because a removal resolves a name a same-UID process may have
# substituted since. The residue is one file in the session's own working directory, which
# is the litter `docs/decisions/2026-09-01-origin-cleanup-races.md` already accepts, and it
# is named so an operator reading the abort can see it.

# TWO ENTRY POINTS, ONE MECHANISM. A value and an emptying are different contents and the
# same problem, and a single function taking "" for both would have to decide what an empty
# value means — a zero-byte file or a lone newline. `gate` wants the first: it is not
# handing over a value, it is removing a claim, and `pr-watch.sh` refuses a zero-byte
# baseline and a newline-only one alike, so the distinction is the caller's to state rather
# than the library's to guess.
#
# rb_write_handoff <target> <content>
#   0  the target now holds <content> followed by one newline
#   1  refused; the reason is on stdout
#
# rb_empty_handoff <target>
#   0  the target is now a zero-byte regular file
#   1  refused; the reason is on stdout
#
# A REFUSAL IS NOT A PROMISE THAT THE TARGET IS UNTOUCHED, and it used to say it was. Every
# refusal BEFORE the rename leaves it exactly as it was — the type test, the exclusive
# create, the write — and those are the ordinary ones. But the POSTCONDITION refuses after
# the rename has happened: where a racer replaced the published temporary, the substituted
# inode is at the target and the refusal is the caller being told the value did not cross,
# not that nothing did. A caller must read a non-zero status as "this handoff did not
# happen", never as "the previous handoff is still readable".
#
# The caller supplies its own abort prose: these are three stages with three consequences,
# and a shared message would name none of them.
# rb_handoff_is_sha <path>
#   0  the path is a plain regular file holding exactly one 40-character lowercase
#      hexadecimal commit id and the terminating newline this library writes
#   1  it is not, or could not be read
#
# THE READ SIDE OF THE SAME RULE, and it exists because the DRIVER needs it. `SKILL.md`
# asked `[[ -f $HEAD_FILE ]]` and then `case "$(<"$HEAD_FILE")"`, which is a test and then a
# separate open of the same name: a same-UID process that replaced a regular file with a FIFO
# between them had the substitution BLOCK, in a shell with no watchdog and no non-blocking
# read, before the thread-resolution step. No additional pathname test closes that; only
# asking the question of the descriptor that was opened does.
#
# SO IT IS ONE OPEN AND EVERY ANSWER COMES FROM IT. `O_NOFOLLOW` refuses a symlink at the
# open, `O_NONBLOCK` makes a FIFO return at once instead of waiting, `-f` on the HANDLE gives
# the type of the inode actually opened, and the bytes are slurped and matched whole.
#
# NOTHING CROSSES BACK, WHICH IS THE POINT FOR THAT CALLER. The driver does not need the sha
# — it needs to know a gate proved one — so this answers with a STATUS and the driver uses it
# as a condition. A value would have to land in a name, and a name a startup file has made
# readonly loses it silently.
rb_handoff_is_sha() {
    /usr/bin/env -i PATH="$PATH" perl -e '
        use Fcntl qw(O_RDONLY O_NONBLOCK O_NOFOLLOW);
        sysopen(my $h, $ARGV[0], O_RDONLY|O_NONBLOCK|O_NOFOLLOW) or exit 2;
        stat($h) or exit 3;
        exit 4 unless -f _;
        local $/;
        my $got = <$h>;
        $got = "" unless defined $got;
        exit 5 unless $got =~ /\A[0-9a-f]{40}\n\z/;
        exit 0;
    ' -- "$1" 2>/dev/null
}

rb_write_handoff() { _rb_handoff "$1" value "$2"; }
rb_empty_handoff() { _rb_handoff "$1" empty; }

_rb_handoff() {   # _rb_handoff <target> value|empty [content]
    # THE TARGET MUST BE ABSENT OR A REGULAR FILE, AND THIS IS NOT THE CONVICTED SHAPE.
    # #245 convicted a check that PRECEDES A WRITING OPEN OF THE SAME NAME, where the race
    # changes what the open hits. Nothing here opens the target to WRITE it, before this
    # test or after it, so the rename's safety does not rest on the answer. The value
    # postcondition opens it to READ, past the rename, and answers its own question at that
    # open — `O_NOFOLLOW`, `O_NONBLOCK`, and the type from `fstat` on the handle. What this refuses is a
    # caller naming something that is not a handoff file, early and with nothing written:
    #
    #   * an ACTUAL DIRECTORY. The EXACT RENAME below refuses this on its own — `rename(2)`
    #     will not put a file over a directory — so what the test buys here is an earlier
    #     refusal with no temporary created, and a message about the caller's argument rather
    #     than about a rename that failed. A convenience over the rename, NOT a substitute
    #     for it: the two-operand `mv` would move the source INSIDE and report success, which
    #     is why the rename must stay exact.
    #   * a SYMLINK TO A DIRECTORY, which the rename does NOT refuse and this test does.
    #     `rename(2)` never follows a final symlink, so it would REPLACE the link and
    #     succeed, leaving the directory untouched — safe, but not what a caller naming that
    #     path meant, and the caller loses a link they may have wanted. Grouping this with
    #     the case above was wrong: only one of the two reaches the rename's own refusal.
    #   * a DEVICE or a SOCKET. `mv -f` replaces every non-directory inode it can rename
    #     over, so a run with permission — root in a container, with `/dev/null` named as
    #     the handoff path — would replace the character device with a regular file.
    #   * a FIFO, which is refused rather than replaced. Replacing it is safe and was
    #     briefly the behaviour; refusing keeps the promise `README.md` already makes and
    #     leaves one fewer thing about this handoff that changed.
    #
    # A SYMLINK TO A REGULAR FILE PASSES, and must: `-f` follows the link, and that case is
    # the whole of #263 — the rename then replaces the LINK and leaves the file it pointed
    # at untouched, which is what a plain `>` did not do.
    #
    # THE TYPE IS ASKED ONCE, AND A LATE SWAP IS NOT REFUSED. A racer who installs a FIFO,
    # a device or a socket between this test and the rename has it REPLACED: `rename(2)`
    # takes any non-directory destination, the value arrives, and the postcondition passes.
    # A DIRECTORY is the exception, and only because the rename itself refuses one. This is
    # the documented limit rather than an oversight — no shell-reachable rename is
    # conditional on the destination's type, and a re-check is the same race one instruction
    # later — and `test-writelib.sh` pins the outcome so a change here fails rather than
    # widening it quietly. A caller must not expect a refusal for a late special inode.
    # `-L` IS ASKED AS WELL AS `-e`, BECAUSE `-e` FOLLOWS THE LINK. A DANGLING symlink — one
    # whose referent has gone — makes `-e` false, so the test read it as an ABSENT path and
    # the rename then replaced the link and reported success. That is a caller-provided link
    # destroyed by a call the contract says accepts only an absent path, a regular file, or a
    # symlink resolving to one. `-L` is true for a link whatever its referent, so the pair
    # answers "is there an entry at this name" rather than "does this name resolve".
    if { [ -e "$1" ] || [ -L "$1" ]; } && [ ! -f "$1" ]; then
        echo "'$1' is not a regular file; a handoff target must be a regular file or absent"
        return 1
    fi
    # THE TEMPORARY IS BESIDE THE TARGET, because `mv` must not cross a filesystem: a
    # rename that becomes a copy is no longer atomic, and a reader could see a partial file
    # at the target. The caller's own directory is the one place guaranteed to be on the
    # same filesystem as the caller's own file.
    #
    # AND ITS NAME IS UNPREDICTABLE, WHICH BOUNDS RESIDUE AND COLLISIONS — AND NOT THE
    # DIRECTORY SWAP. It stops an accidental collision between two runs, and it stops a
    # racer PRE-PLACING an entry at a name they have not yet seen. It does NOT stop the
    # directory swap, and crediting it with that was wrong: a racer who WAITS for the
    # temporary to appear reads the basename out of the directory and can seed exactly it
    # before the rename, because the name is unguessable and not unobservable. What
    # prevents that loss is the EXACT-DESTINATION rename below, which refuses a directory
    # destination outright rather than moving the source inside it.
    _rb_wh_tmp="$1.rb-write.$$.${RANDOM}${RANDOM}"
    # ONE EXCLUSIVE OPEN, AND THE WRITE GOES THROUGH THAT HANDLE. Creating the temporary and
    # then opening it AGAIN by name to write would be a check-then-open of its own: a
    # same-UID process can replace it between the two, and the second open would follow a
    # symlink or block on a FIFO, which is the whole defect this library exists to remove,
    # reproduced inside it. `sysopen` returns the handle the write then uses, so there is one
    # open and no name is resolved twice.
    #
    # AND `set -C` IS NOT THAT OPEN, WHICH IS WHY THIS IS NOT A REDIRECTION. Bash's
    # noclobber does what POSIX says: the redirection fails if the file exists AND IS A
    # REGULAR FILE. For every other type it opens anyway — so a FIFO pre-placed at the
    # temporary's name by a same-UID watcher was OPENED and the write BLOCKED, waiting for a
    # reader that never comes. Measured. `O_CREAT|O_EXCL` has no such exemption: it refuses
    # whatever is there, of any type.
    #
    # AND THE HANG WOULD REACH SEVEN OF THE TEN CALLERS, not two. This open runs for every
    # handoff, emptyings included, so the ones with no watchdog are the four emptyings —
    # both pre-bootstrap and both in `gate` — plus the two value writes in
    # `pr-close-round.sh` and the one in `pr-request-review.sh`. Only the three in
    # `pr-copilot-phase.sh` are bounded. The read-back's own count is smaller and is stated
    # separately below, because the emptyings never reach it.
    #
    # SO THE OPEN IS `perl`'s `sysopen`, WHICH IS THE SYSCALL. The same reason the rename is
    # `rename(2)` rather than `mv SRC DEST`: the shell's spellings of these operations carry
    # exemptions the syscalls do not have, and reading the exemption out of a utility's
    # documentation is how both of these were got wrong. It also settles the option-parsing
    # question for the create, since paths travel in `@ARGV` and are never parsed.
    #
    # ONE OPEN, AND THE WRITE GOES THROUGH THE SAME HANDLE. Creating the temporary and then
    # opening it again by name would be a check-then-open of its own, with the second open
    # free to follow a symlink or block on a FIFO — the defect reproduced inside the fix.
    #
    # AND THE STATUSES ARE DISTINCT, so a refusal says which step refused: 2 the exclusive
    # create, 3 the write or the close — `close` is where a full filesystem is reported, and
    # a `print` that succeeded proves nothing without it — and anything else is `perl` itself
    # not running, which is a refusal too. There is no arm that proceeds.
    #
    # THIS MAKES `perl` A REQUIREMENT rather than a fallback, and `README.md` says so. The
    # alternative is a create that is exclusive for regular files only, which is the defect
    # above; a shell has no other exclusive create — `mkdir` refuses every type but makes a
    # directory, and `ln` needs a source that has the same problem one step earlier.
    #
    # AND IT RUNS WITH THE ENVIRONMENT CLEARED, `env -i` KEEPING ONLY `PATH`. `perl` reads
    # its own environment before it reads the program: `PERL5OPT=-MDefinitelyMissing` makes
    # it exit before the first statement, and `PERL5LIB` and `PERLLIB` redirect where it
    # finds modules. That is the same class as a poisoned `PATH` — an inherited value that
    # redirects an external command — except that this one can be REMOVED, and `PATH` cannot
    # be, since it is the question `PATH` exists to answer. `env -i` is a removal rather than
    # a denylist, so there is no list of perl variables to keep in step: `CLAUDE.md` records
    # that a list of names is wrong by omission, and this needs none.
    /usr/bin/env -i PATH="$PATH" perl -e '
        use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
        sysopen(my $h, $ARGV[0], O_WRONLY|O_CREAT|O_EXCL, 0600) or exit 2;
        if ($ARGV[1] eq "value") { print $h $ARGV[2], "\n" or exit 3; }
        close($h) or exit 3;
        exit 0;
    ' -- "$_rb_wh_tmp" "$2" "${3-}" 2>/dev/null \
        || { echo "could not create '$_rb_wh_tmp' exclusively and write it; the name is taken by an entry of some type, its directory is unwritable, the storage refused the bytes, or perl could not run — this handoff needs a working perl"; return 1; }
    # `mv` RATHER THAN `cp`: the point is the rename, and a copy would open the target for
    # writing and be exactly the truncation this exists to remove.
    #
    # AND AN EXACT-DESTINATION `mv`, BECAUSE THE TWO-OPERAND FORM IS NOT A RENAME. `mv SRC
    # DEST` STATS `DEST` FIRST and, where it resolves to a DIRECTORY, moves the source
    # INSIDE it — following a symlink to do so. `rename(2)` does neither: it never follows a
    # symlink in the final component of either operand, so the link is what it replaces.
    # The directory behaviour is the UTILITY's, and it is the whole of the attack: a racer
    # reads the temporary's name out of the directory once it exists — randomness makes a
    # name unguessable, not unobservable — points the target at a directory of their own,
    # and puts a file worth keeping there under that name for `mv -f` to overwrite. The
    # postcondition sees it afterwards, which is after the loss.
    #
    # SO AN EXACT-DESTINATION RENAME IS ASKED FOR FIRST. `-T` is the GNU spelling, and it is
    # attempted as THE REAL OPERATION rather than probed: a `mv` that does not know an option
    # fails on the option, having moved nothing, so the next attempt is safe to make. Probing
    # with `--version` would ask a different question and answer it wrongly, which is #269;
    # probing with a scratch directory would need that directory REMOVED, which is the class
    # `docs/decisions/2026-08-29-setup-leaf-cleanup.md` convicts.
    #
    # BSD `mv -h` IS NOT THE OTHER HALF OF THAT, and it was written here as if it were. Its
    # contract is narrower than `-T`: "if the target is a symbolic link to a directory, do
    # not follow it". A racer who swaps in an ACTUAL DIRECTORY is not a symlink, so `-h`
    # takes the ordinary two-operand path and moves the source inside it — which is the same
    # loss by the other route, behind a flag that reads as if it had been covered.
    #
    # `perl`'s `rename` IS rename(2), and that is the one primitive that covers both: it
    # never follows a symlink in a final component, and it refuses a directory destination
    # outright. Measured both ways. It is second rather than first only to save a process
    # where `mv -T` is there; `perl` is a requirement of this library either way, since the
    # exclusive create above has no other spelling.
    #
    # AND THERE IS NO PLAIN-`mv` FALLBACK, WHICH IS A REMOVAL RATHER THAN A GAP. One was
    # kept, so that a platform with neither spelling still worked — and it turned every way
    # `perl` can fail into the unsafe path. An inherited `PERL5OPT=-MDefinitelyMissing` makes
    # `perl` exit 2 before it reaches `rename`, and the fallback then performed the move the
    # exact form exists to refuse. Telling "perl aborted" from "perl is not installed" means
    # reading an exit status the environment controls; having no fallback needs no such
    # reading. So: `mv -T`, or `perl`, or a refusal. The cost is that a platform with
    # neither cannot run this loop — loudly, with the reason named — and neither platform
    # this project builds and tests on is that platform. `README.md` states the requirement.
    #
    # AND THE FAILURE MESSAGE PROMISES NOTHING ABOUT EITHER PATH. It used to say the target
    # is unchanged and the temporary is left behind, and neither is certain: `mv -T` can
    # complete the rename and still report non-zero — killed after the syscall, or a wrapper
    # that renames and exits 1 — after which `perl` finds the source gone, fails, and this
    # arm runs with the target ALREADY REPLACED and no temporary left. The contract at the
    # top of this file says a refusal means "this handoff did not happen" and nothing more;
    # the message has to say the same.
    #
    # AND `--` BEFORE THE OPERANDS, ON BOTH. A handoff path is the CALLER'S, and a relative
    # one may begin with `-`: the temporary derived from it does too, so `mv` reads the
    # source as an option bundle and `perl` reads it as a switch. Both attempts then fail on
    # the option, the write refuses, and a path that was perfectly writable takes the stage
    # down. `--` is where each of them stops parsing.
    /usr/bin/env mv -T -f -- "$_rb_wh_tmp" "$1" 2>/dev/null \
        || /usr/bin/env -i PATH="$PATH" perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' -- "$_rb_wh_tmp" "$1" 2>/dev/null \
        || { echo "the rename of '$_rb_wh_tmp' onto '$1' did not report success; neither is in a known state and this call did not hand a value over. An exact-destination rename is required: 'mv -T' or a working 'perl'"; return 1; }
    # AND THE POSTCONDITION ASKS WHAT IS AT THE TARGET, NOT MERELY WHAT KIND OF THING IT IS.
    # It is the ONE place this library opens the target, and it does so only to READ: the
    # write never opens it, which is the whole of #263.
    # It runs after the rename rather than before it, so it asks what actually happened.
    #
    # AND THE DIRECTORY SWAP IS NOT WHAT IT CATCHES — the EXACT RENAME is. A directory
    # installed after the type test makes both `mv -T` and `perl`'s `rename` refuse, so this
    # never runs and the temporary is never moved inside it; a directory appearing after the
    # rename arrives when the temporary's name is already gone. Crediting this check, or the
    # temporary's randomness, with that safety is how someone talks themselves into weakening
    # the rename. What this validates is WHAT ARRIVED at the target — which is the source
    # race below, and nothing to do with directories.
    #
    # THE SOURCE IS RACEABLE TOO, and a type check alone cannot see it. The temporary's name
    # is published in the directory the moment it exists, so a same-UID process can replace
    # THAT path — with a symlink, or with a regular file of its own carrying another 40-hex
    # OID — and the exact rename then moves the substituted inode onto the handoff path,
    # faithfully. `[ -f ]` is satisfied, the helper returns 0, and the driver reads a head
    # this run never gated as though it had.
    #
    # SO THE VALUE IS PROVEN, AND A SYMLINK AT THE TARGET IS REFUSED OUTRIGHT. An exact
    # rename leaves a regular file at that name; a link there means what arrived is not what
    # this call put there.
    { [ ! -L "$1" ] && [ -f "$1" ]; } \
        || { echo "'$1' is not a plain regular file after the write; it was replaced while the value was crossing, and the value did not cross"; return 1; }
    if [ "$2" = value ]; then
        # THE RAW BYTES, TERMINATOR INCLUDED, READ WITH A BUILTIN. `$(<…)` strips trailing
        # newlines, so it cannot see the delimiter every reader of these files requires, and
        # `cat` is a name. `local $/` makes perl SLURP — the whole file, whatever is in it —
        # so the comparison is on the complete bytes and there is no reader's stopping rule
        # to reason about.
        #
        # WHICH IS ALSO HOW A NUL IS REFUSED, and it used to take an argument. This was
        # `read -d ''`, which stops AT the first NUL, so a forgery spelled "the requested
        # value, then a NUL, then anything" filled the variable with exactly the expected
        # bytes and compared EQUAL — the driver's `$(<…)` then drops the trailing NUL and
        # accepts the 40-hex prefix. Catching it meant reading the read's STATUS backwards,
        # since it returns 0 only when it FOUND the delimiter. Slurped, the extra bytes are
        # simply there and the comparison fails; nothing has to be interpreted.
        # THE READ-BACK OPENS THE TARGET, WHICH IS THE ONE OPEN THIS LIBRARY MAKES — so it
        # is the one place a racer can still cost the caller a HANG rather than a refusal.
        # `[ -f ]` above answers before the open, and a FIFO swapped in between the two had
        # `read` waiting for a writer that never comes: of the six VALUE calls, which are
        # the only ones that reach this open, three have no
        # watchdog, and in the round-closing baseline path that hang lands AFTER the thread
        # replies are resolved, leaving the round half-closed.
        #
        # SO THE OPEN IS NON-BLOCKING AND THE TYPE COMES FROM `fstat`, NOT FROM A TEST
        # BEFORE IT. `O_NONBLOCK` makes opening a FIFO for reading return at once instead of
        # waiting, and `-f _` on the HANDLE asks about the inode that was actually opened —
        # so there is no window between the question and the answer, which is what makes
        # this a postcondition rather than another guard. `[ ! -L ]` and `[ -f ]` above stay
        # as the cheap early answer with a clearer message; neither is load-bearing now.
        #
        # AND A NUL IS STILL A REFUSAL. Slurped, the bytes come back whole, so a forgery
        # spelled "the requested value, then a NUL, then anything" no longer compares equal
        # by being truncated at the delimiter — it compares unequal, which is the same
        # answer reached without depending on a reader's stopping rule.
        # AND `O_NOFOLLOW`, BECAUSE `[ ! -L ]` ABOVE IS A TEST AND THIS IS THE OPEN. A racer
        # who replaces the target with a SYMLINK between the two, pointing at a regular file
        # holding the requested bytes, satisfies `fstat` on the referent and the byte
        # comparison both — so the call returned 0 with a link at the handoff path, and the
        # driver then read through a path the racer controls. `O_NOFOLLOW` refuses a symlink
        # in the final component at the open itself, which is the same move as taking the
        # type from the handle: the question and the answer are one operation.
        #
        # REQUIRED, NOT PROBED. POSIX.1-2008 has it and so do both platforms this runs on; a
        # perl whose `Fcntl` lacks it fails to compile the program, which exits non-zero and
        # refuses. That is the direction to fail in — a fallback that dropped the flag would
        # be silently weaker exactly where a fixture cannot see it.
        /usr/bin/env -i PATH="$PATH" perl -e '
            use Fcntl qw(O_RDONLY O_NONBLOCK O_NOFOLLOW);
            sysopen(my $h, $ARGV[0], O_RDONLY|O_NONBLOCK|O_NOFOLLOW) or exit 2;
            stat($h) or exit 3;
            exit 4 unless -f _;
            local $/;
            my $got = <$h>;
            $got = "" unless defined $got;
            exit 5 unless $got eq $ARGV[1] . "\n";
            exit 0;
        ' -- "$1" "$3" 2>/dev/null \
            || { echo "'$1' does not hold what this call wrote, or is no longer a plain file; the temporary was replaced before the rename, or the target was, and the value did not cross"; return 1; }
    else
        # ZERO BYTES, ON THE SAME ONE DESCRIPTOR. `[ ! -L ]`, `[ -f ]` and `[ ! -s ]` are
        # three separate resolutions of the name, so a racer between any two of them is
        # answered about a different inode each time — a FIFO or a symlink to an empty file
        # swapped in before the size test made `-s` examine the REPLACEMENT and this return
        # 0 with the target not the zero-byte regular file it promised. The value branch
        # above already asks its questions of one open handle; this asks the same way.
        #
        # AND IT STILL CANNOT BLOCK OR FOLLOW. `O_NONBLOCK` means opening a FIFO returns at
        # once instead of waiting — which matters because the pre-bootstrap clearing in
        # `pr-close-round.sh` has no watchdog — and `O_NOFOLLOW` refuses a symlink at the
        # open rather than resolving it. The size comes from `fstat` on the handle, so it is
        # the size of the file that was opened.
        /usr/bin/env -i PATH="$PATH" perl -e '
            use Fcntl qw(O_RDONLY O_NONBLOCK O_NOFOLLOW);
            sysopen(my $h, $ARGV[0], O_RDONLY|O_NONBLOCK|O_NOFOLLOW) or exit 2;
            my @s = stat($h) or exit 3;
            exit 4 unless -f _;
            exit 5 unless $s[7] == 0;
            exit 0;
        ' -- "$1" 2>/dev/null \
            || { echo "'$1' is not an empty regular file after the emptying; it was replaced while the claim was being removed"; return 1; }
    fi
    return 0
}
