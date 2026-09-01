        if !defined($snapshot);

    my $dataset = ($class->parse_volname($volname))[1];

    my $fd = fileno($fh);
    die "internal error: invalid file handle for volume_export\n"
        if !defined($fd);
    $fd = ">&$fd";

    # For zfs we always create a replication stream (-R) which means the remote
    # side will always delete non-existing source snapshots. This should work
    # for all our use cases.
    my $cmd = ['zfs', 'send', '-RpvL'];
    if (defined($base_snapshot)) {
        my $arg = $with_snapshots ? '-I' : '-i';
        push @$cmd, $arg, $base_snapshot;
    }
    push @$cmd, '--', "$scfg->{pool}/$dataset\@$snapshot";

    run_command(
        $cmd,
        output => $fd,
        errfunc => sub {
            my $line = shift;
            if ($line !~ /^WARNING: no-preserve-encryption flag set, sending dataset/) {
                chomp($line);
                print STDERR "$line\n";
                *STDERR->flush();
