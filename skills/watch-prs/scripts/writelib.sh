#!/usr/bin/env bash
# How a value crosses to the caller in a file the caller named: write a temporary beside the
# target, then rename it over. Sourced, never executed. `>` follows a symlink and truncates
# whatever it points at; `rename(2)` replaces the name and leaves the referent alone. Nothing
# here opens the target to write it, and nothing here removes anything, on any path —
# `docs/decisions/2026-08-29-setup-leaf-cleanup.md` convicts the class. This library sets no
# watchdog; a caller that needs a bound keeps its own around a child that sources this file.

# rb_write_handoff <target> <content>   0 the target holds <content> and one newline
# rb_empty_handoff <target>             0 the target is a zero-byte regular file
#   1 refused, the reason on stdout. A refusal means this handoff did not happen — not that
#   the target is untouched, since the postcondition refuses after the rename.
#
# rb_handoff_is_sha <path>   0 a plain regular file holding one 40-hex id and a newline
#   The driver's read side: one open answers everything, so a FIFO swapped in after a `[[ -f ]]`
#   cannot block a shell with no watchdog. A status rather than a value, because a value would
#   have to land in a name the operator's shell may have made readonly.
rb_handoff_is_sha() {
    /usr/bin/env -i PATH="$PATH" perl -e '
        use Fcntl qw(O_RDONLY O_NONBLOCK O_NOFOLLOW);
        sysopen(my $h, $ARGV[0], O_RDONLY|O_NONBLOCK|O_NOFOLLOW) or exit 2;
        stat($h) or exit 3;
        exit 4 unless -f _;
        my $got = "";
        while (1) {
            my $n = sysread($h, my $buf, 65536);
            exit 6 unless defined $n;
            last if $n == 0;
            $got .= $buf;
        }
        exit 5 unless $got =~ /\A[0-9a-f]{40}\n\z/;
        exit 0;
    ' -- "$1" 2>/dev/null
}


_rb_handoff() {   # _rb_handoff <target> value|empty [content]
    # Refuses a caller naming something that is not a handoff file — a directory, a device, a
    # socket, a FIFO — with nothing created; a symlink to a regular file passes, since that is
    # the case the rename exists for. `-L` as well as `-e` because `-e` is false on a dangling
    # link. Not a check-then-open: the rename's safety does not rest on this answer, and a
    # special inode a racer installs after it is replaced, which `test-writelib.sh` pins.
    if { [ -e "$1" ] || [ -L "$1" ]; } && [ ! -f "$1" ]; then
        echo "'$1' is not a regular file; a handoff target must be a regular file or absent"
        return 1
    fi
    # Beside the target so the rename never crosses a filesystem. The random suffix bounds
    # accidental collisions and a name pre-placed before it exists; it does not hide the name.
    _rb_wh_tmp="$1.rb-write.$$.${RANDOM}${RANDOM}"
    # `O_CREAT|O_EXCL` through the syscall, and the write through the same handle. `set -C`
    # is not that open: noclobber fails only on a regular file, so a pre-placed FIFO was
    # opened and the write blocked. `env -i` because `PERL5OPT` and `PERL5LIB` are read
    # before the program is. 2 the create, 3 the write or the close, where a full filesystem
    # is reported.
    /usr/bin/env -i PATH="$PATH" perl -e '
        use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
        sysopen(my $h, $ARGV[0], O_WRONLY|O_CREAT|O_EXCL, 0600) or exit 2;
        if ($ARGV[1] eq "value") { print $h $ARGV[2], "\n" or exit 3; }
        close($h) or exit 3;
        exit 0;
    ' -- "$_rb_wh_tmp" "$2" "${3-}" 2>/dev/null \
        || { echo "could not create '$_rb_wh_tmp' exclusively and write it; the name is taken by an entry of some type, its directory is unwritable, the storage refused the bytes, or perl could not run — this handoff needs a working perl"; return 1; }
    # An exact-destination rename, or a refusal. Two-operand `mv` stats the destination and
    # moves the source inside a directory it resolves to, following a symlink to get there;
    # BSD `mv -h` covers a link to a directory and not an actual one. `perl`'s `rename` is
    # `rename(2)`. No plain-`mv` fallback: it turned every way `perl` can fail into the unsafe
    # path. `--` because a caller's relative path, and so the temporary, may begin with `-`.
    /usr/bin/env mv -T -f -- "$_rb_wh_tmp" "$1" 2>/dev/null \
        || /usr/bin/env -i PATH="$PATH" perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' -- "$_rb_wh_tmp" "$1" 2>/dev/null \
        || { echo "the rename of '$_rb_wh_tmp' onto '$1' did not report success; neither is in a known state and this call did not hand a value over. An exact-destination rename is required: 'mv -T' or a working 'perl'"; return 1; }
    # What arrived, not what kind of thing is there: the temporary's name is public once it
    # exists, so a racer can replace the source before the rename moves it. A link at the
    # target is refused outright — an exact rename leaves a regular file.
    { [ ! -L "$1" ] && [ -f "$1" ]; } \
        || { echo "'$1' is not a plain regular file after the write; it was replaced while the value was crossing, and the value did not cross"; return 1; }
    if [ "$2" = value ]; then
        # The one open of the target this library makes, and every answer comes from it:
        # `O_NOFOLLOW` so a link swapped in after the test above is refused rather than
        # followed, `O_NONBLOCK` so a FIFO cannot hang a caller with no watchdog, the type
        # from `fstat` on the handle. `sysread` to a zero-length read rather than a slurp,
        # which returns what arrived before an I/O error and lets a matching prefix pass.
        /usr/bin/env -i PATH="$PATH" perl -e '
            use Fcntl qw(O_RDONLY O_NONBLOCK O_NOFOLLOW);
            sysopen(my $h, $ARGV[0], O_RDONLY|O_NONBLOCK|O_NOFOLLOW) or exit 2;
            stat($h) or exit 3;
            exit 4 unless -f _;
            my $got = "";
            while (1) {
                my $n = sysread($h, my $buf, 65536);
                exit 6 unless defined $n;
                last if $n == 0;
                $got .= $buf;
            }
            exit 5 unless $got eq $ARGV[1] . "\n";
            exit 0;
        ' -- "$1" "$3" 2>/dev/null \
            || { echo "'$1' does not hold what this call wrote, or is no longer a plain file; the temporary was replaced before the rename, or the target was, and the value did not cross"; return 1; }
    else
        # Zero bytes on the same one descriptor, for the same reasons.
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

# Defined last, after the implementation: a library truncated between them would define the
# public names and not `_rb_handoff`, pass every load check, and resolve the private name on
# `PATH`. With the wrappers at the end a truncation leaves them undefined for the stub to refuse.
rb_write_handoff() { _rb_handoff "$1" value "$2"; }
rb_empty_handoff() { _rb_handoff "$1" empty; }
