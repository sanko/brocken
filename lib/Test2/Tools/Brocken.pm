package Test2::Tools::Brocken v0.0.1 {
    use v5.40;
    use Exporter 'import';
    use Test2::API qw[context];
    use Carp       qw[croak];
    our @EXPORT = qw[run_exec];

    sub run_exec ( $file, %args ) {
        croak "run_exec: file '$file' not found" unless -e $file;
        my $expected = $args{expected_exit};
        my $name     = $args{name} // "Run $file";
        my $platform = $args{platform};
        my $do_gdb   = $args{gdb}  // 0;
        my $keep     = $args{keep} // 0;
        my $argv     = $args{args} // [];
        my $ctx      = context();
        my $cmd      = ( defined $platform && $platform->is_windows ) ? $file : "./$file";
        my $actual;

        if ($do_gdb) {
            my @gdb_cmd = ( 'gdb', '-batch', '-nx', '-ex', 'run', '-ex', 'quit', '--args', $cmd, @$argv );
            my $gdb_out = `@gdb_cmd 2>&1`;
            $actual = $? >> 8;
            if ( $gdb_out =~ /Inferior.*exited with code (\d+)\]/ ) {
                $actual = oct($1);
            }
            elsif ( $gdb_out =~ /Thread.*exited with code (\d+)\]/ ) {
                $actual = $1;
            }
            $ctx->diag("GDB output for $name:\n$gdb_out") if length $gdb_out;
        }
        else {
            system {$cmd} $cmd, @$argv;
            $actual = $? >> 8;
        }
        my $mismatch = defined $expected && $actual != $expected;
        if ($mismatch) {
            warn "$name: expected exit code $expected, got $actual (raw status \$?=$?)\n";
            if ( -e $file ) {
                if ( open my $fh, '<:raw', $file ) {
                    my $bytes = do { local $/; <$fh> };
                    close $fh;
                    my $len = length $bytes;
                    for ( my $i = 0 ; $i < $len ; $i += 16 ) {
                        my $chunk = substr( $bytes, $i, 16 );
                        my $hex   = join( ' ', map { sprintf '%02X', ord $_ } split( //, $chunk ) );
                        my $pad   = 16 - length($chunk);
                        $hex .= '   ' x $pad if $pad;
                        my $ascii = join( '', map { ord $_ >= 32 && ord $_ < 127 ? $_ : '.' } split( //, $chunk ) );
                        warn sprintf( '%08x: %-48s %s', $i, $hex, $ascii ) . "\n";
                    }
                    warn "(hex dump of $file, $len bytes)\n";
                }
                else {
                    warn "Cannot open $file for hex dump: $!\n";
                }
            }
        }
        $ctx->ok( !$mismatch, $name ) if defined $expected;
        unlink $file unless $keep;
        $ctx->release;
        return $actual;
    }
};
1;
