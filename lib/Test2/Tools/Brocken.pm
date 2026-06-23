package Test2::Tools::Brocken v0.0.1 {
    use v5.40;
    use Exporter 'import';
    use Test2::API qw[context];
    use Carp       qw[croak];
    our @EXPORT = qw[run_exec];

    sub run_exec ( $file, %args ) {
        croak "run_exec: file '$file' not found" unless -e $file;
        my $TIMEOUT  = 30;
        my $expected = $args{expected_exit};
        my $name     = $args{name} // "Run $file";
        my $platform = $args{platform};
        my $do_gdb   = $args{gdb}  // 0;
        my $keep     = $args{keep} // 0;
        my $argv     = $args{args} // [];
        my $ctx      = context();
        my $cmd      = ( defined $platform && $platform->is_windows ) ? ".\\$file" : "./$file";
        my $actual;

        if ($do_gdb) {
            my @gdb_cmd = (
                'gdb', '-batch', '-nx',
                '-ex', 'run',
                '-ex', 'bt',
                '-ex', 'info registers',
                '-ex', 'x/30i $rip-10',
                '-ex', 'quit',
                '--args', $cmd, @$argv
            );
            my $gdb_out;
            if ( open my $fh, '-|', @gdb_cmd ) {
                $gdb_out = do { local $/; <$fh> };
                close $fh;
            }
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
            eval {
                local $SIG{ALRM} = sub { die "timeout\n" };
                alarm $TIMEOUT;
                system( $cmd, @$argv );
                alarm 0;
            };
            if ( $@ && $@ eq "timeout\n" ) {
                $ctx->diag("run_exec timed out for $name");
                $actual = -1;
            }
            else {
                $actual = $? >> 8;
            }
        }
        my $mismatch = defined $expected && $actual != $expected;
        if ($mismatch) {
            warn "$name: expected exit code $expected, got $actual (raw status \$?=$?)\n";
            if ( -e $file ) {
                if ( open my $fh, '<:raw', $file ) {
                    my $bytes = do { local $/; <$fh> };
                    close $fh;
                    my $len = length $bytes;
                    for ( my $i = 0; $i < $len; $i += 16 ) {
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

=encoding utf-8

=head1 NAME

Test2::Tools::Brocken - Test Utility for Running Compiled Executables

=head1 DESCRIPTION

Provides the C<run_exec> function for testing compiled Brocken executables within the Test2 test framework. Handles
running the binary, checking the exit code, and optionally debugging with GDB.

=head1 FUNCTIONS

=head2 run_exec

    run_exec($file, %args);

Runs a compiled executable and checks its exit code.

=head3 Arguments

=over 4

=item C<file> - Path to the compiled executable

=item C<expected_exit> - Expected exit code (required for assertions)

=item C<name> - Test name for Test2 output

=item C<platform> - L<Brocken::Katsuro::Platform> object (for path separators)

=item C<gdb> - If true, run under GDB for debugging

=item C<keep> - If true, do not delete the executable after the test

=item C<args> - Arrayref of command-line arguments to pass

=back

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
