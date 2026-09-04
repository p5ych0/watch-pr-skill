#!/usr/bin/env bash
# Write a temporary beside the target, then rename it over: `>` follows a symlink and truncates its
# referent, `rename(2)` replaces the name. Nothing here removes anything — `docs/decisions/2026-08-29-setup-leaf-cleanup.md`.

# One open answers everything, so a FIFO swapped in after a `[[ -f ]]` cannot block the driver's
# shell; a status rather than a value, since a value must land in a name that may be readonly.
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
    # `-L` as well as `-e`, since `-e` is false on a dangling link. A special inode a racer
    # installs after this test is replaced by the rename rather than refused; `test-writelib.sh` pins that.
    if { [ -e "$1" ] || [ -L "$1" ]; } && [ ! -f "$1" ]; then
        echo "'$1' is not a regular file; a handoff target must be a regular file or absent"
        return 1
    fi
    # Beside the target so the rename never crosses a filesystem. The random suffix bounds
    # accidental collisions and a name pre-placed before it exists; it does not hide the name.
    _rb_wh_tmp="$1.rb-write.$$.${RANDOM}${RANDOM}"
    # `O_CREAT|O_EXCL` through the syscall, and the write through the same handle: `set -C` opens
    # a pre-placed FIFO and blocks. `env -i` because `PERL5OPT` and `PERL5LIB` are read before the program is.
    /usr/bin/env -i PATH="$PATH" perl -e '
        use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
        sysopen(my $h, $ARGV[0], O_WRONLY|O_CREAT|O_EXCL, 0600) or exit 2;
        if ($ARGV[1] eq "value") { print $h $ARGV[2], "\n" or exit 3; }
        close($h) or exit 3;
        exit 0;
    ' -- "$_rb_wh_tmp" "$2" "${3-}" 2>/dev/null \
        || { echo "could not create '$_rb_wh_tmp' exclusively and write it; the name is taken by an entry of some type, its directory is unwritable, the storage refused the bytes, or perl could not run — this handoff needs a working perl"; return 1; }
    # Exact-destination or refuse: two-operand `mv` moves the source inside a directory the target
    # resolves to, and `mv -h` covers only a link to one. `--` since a caller's path may begin with `-`.
    /usr/bin/env mv -T -f -- "$_rb_wh_tmp" "$1" 2>/dev/null \
        || /usr/bin/env -i PATH="$PATH" perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' -- "$_rb_wh_tmp" "$1" 2>/dev/null \
        || { echo "the rename of '$_rb_wh_tmp' onto '$1' did not report success; neither is in a known state and this call did not hand a value over. An exact-destination rename is required: 'mv -T' or a working 'perl'"; return 1; }
    # What arrived, not what kind of thing is there: the temporary's name is public once it exists.
    # A link at the target is refused outright, since an exact rename leaves a regular file.
    { [ ! -L "$1" ] && [ -f "$1" ]; } \
        || { echo "'$1' is not a plain regular file after the write; it was replaced while the value was crossing, and the value did not cross"; return 1; }
    if [ "$2" = value ]; then
        # `O_NOFOLLOW` so a link swapped in after the test above is refused, `O_NONBLOCK` so a FIFO
        # cannot hang a caller with no watchdog, `sysread` to EOF since a slurp returns what arrived before an error.
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

# Defined last: a library truncated between them would define the public names and not
# `_rb_handoff`, pass every load check, and resolve the private name on `PATH`.
rb_write_handoff() { _rb_handoff "$1" value "$2"; }
rb_empty_handoff() { _rb_handoff "$1" empty; }
