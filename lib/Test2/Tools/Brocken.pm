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
        if ( defined $expected && $actual != $expected ) {
            $ctx->diag("$name: expected exit code $expected, got $actual (raw status \$?=$?)");
        }
        $ctx->ok( $actual == $expected, $name ) if defined $expected;
        unlink $file unless $keep;
        $ctx->release;
        return $actual;
    }
};
1;
