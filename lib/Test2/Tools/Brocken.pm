package Test2::Tools::Brocken v0.0.1 {
    use v5.40;
    use Exporter 'import';
    use Test2::API qw[context];
    use Carp       qw[croak];
    use File::Temp;
    our @EXPORT = qw[run_exec temp_path run_cross cross_available];

    # Where the cross libc for each non-native target lives. These come from the
    # libc6-<arch>-cross packages, which put the loader and shared objects under
    # a triple-prefixed directory; qemu needs that as its -L root to find the
    # interpreter the linker wrote into the binary.
    my %SYSROOT = ( aarch64 => '/usr/aarch64-linux-gnu', riscv64 => '/usr/riscv64-linux-gnu', );
    my %QEMU    = ( aarch64 => 'qemu-aarch64',           riscv64 => 'qemu-riscv64' );

    # The host architecture and OS, taken from the platform module's own host
    # triple rather than from Config, since Config's myarchname is an OS label on
    # Windows ("MSWin32") rather than an architecture. Both fields matter: a
    # Linux target on a Windows host has the same architecture but is not
    # natively runnable, and checking only the architecture would try to start a
    # Linux ELF directly.
    #
    # The triple is run through the platform parser rather than split on "-",
    # because it names the OS with the release in it: macOS reports
    # "darwin25.0.0", and the middle field is the version rather than the
    # vendor, so splitting left $HOST_OS as "darwin25.0.0". No target compares
    # equal to that, so the "is this native?" test below said no on macOS and
    # every natively-built test there tried to start under qemu -- or, with
    # nothing to run it with, was skipped. The parser's own fields are already
    # the normalized "darwin" and "aarch64".
    my ( $HOST_ARCH, $HOST_OS ) = do {
        require Brocken::Katsuro::Platform;
        my $host = Brocken::Katsuro::Platform::parse( Brocken::Katsuro::Platform::gen_triple() );
        ( $host->arch, $host->os );
    };
    my $TMPDIR;

    sub temp_path ($basename) {
        $TMPDIR //= File::Temp->newdir( CLEANUP => 1, TMPDIR => 1 );
        my $dir = $TMPDIR->dirname;
        $dir =~ s/\\/\//g;
        return $dir . '/' . $basename;
    }

    # The command prefix needed to run a binary built for $platform on this host.
    # A native target needs no prefix and gets an empty one; a non-native target
    # gets qemu and its sysroot, or undef when neither is available, so a caller
    # can skip rather than fail. Both qemu and the cross sysroot have to be
    # present, since a binary that links against libc.so.6 cannot start without
    # the matching loader even under emulation.
    #
    # The native case goes by architecture and OS rather than by is_native,
    # because that compares whole triples: this host is x86_64-pc-linux-gnu, so a
    # platform written as x86_64-unknown-linux-gnu is the same machine spelled
    # with a different vendor and is_native says no.
    sub cross_runner ($platform) {
        return undef unless $platform;
        return [] if $platform->arch eq $HOST_ARCH && ( $platform->os // '' ) eq $HOST_OS;
        my $arch    = $platform->arch;
        my $qemu    = $QEMU{$arch}    // return undef;
        my $sysroot = $SYSROOT{$arch} // return undef;
        my $path    = _which($qemu)   // return undef;
        return undef unless -x $path;
        return undef unless -e $sysroot;
        return [ $qemu, '-L', $sysroot ];
    }
    sub cross_available ($platform) { return defined cross_runner($platform) }

    sub _which ($name) {
        for my $dir ( split /:/, ( $ENV{PATH} // '' ) ) {
            my $p = $dir . '/' . $name;
            return $p if -x $p;
        }
        return undef;
    }

    # Compile $src for $platform, run it, and check the exit code. Returns the
    # exit status, or undef if the target cannot be run here, so a caller can
    # skip rather than fail. The exit code is the program's answer, so the same
    # program compiles for every target and each reports its own verdict.
    sub run_cross ( $src, $platform, %args ) {
        require Brocken;
        require Brocken::Compiler;
        my $runner  = cross_runner($platform) // return undef;
        my $name    = $args{name}             // ( 'Run ' . $platform->friendly );
        my $brocken = Brocken->new( platform => $platform );
        my $module  = eval { Brocken::Compiler->new->compile($src) };
        croak "run_cross: compile failed for $platform: $@" if $@;
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/cross' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $platform );
        return run_exec( $file, %args, runner => $runner, name => $name );
    }

    sub run_exec ( $file, %args ) {
        croak "run_exec: file '$file' not found" unless -e $file;
        my $TIMEOUT  = 30;
        my $expected = $args{expected_exit};
        my $name     = $args{name} // "Run $file";
        my $platform = $args{platform};
        my $do_gdb   = $args{gdb}    // 0;
        my $keep     = $args{keep}   // 0;
        my $argv     = $args{args}   // [];
        my $runner   = $args{runner} // [];
        my $ctx      = context();
        my $cmd      = $file;
        my $actual;

        if ($do_gdb) {
            my @gdb_cmd = (
                'gdb',            '-batch', '-nx',           '-ex', 'run',  '-ex',    'bt', '-ex',
                'info registers', '-ex',    'x/30i $rip-10', '-ex', 'quit', '--args', $cmd, @$argv
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
                system( @$runner, $cmd, @$argv );
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

            #            if ( -e $file ) {
            #                if ( open my $fh, '<:raw', $file ) {
            #                    my $bytes = do { local $/; <$fh> };
            #                    close $fh;
            #                    my $len = length $bytes;
            #                    for ( my $i = 0; $i < $len; $i += 16 ) {
            #                        my $chunk = substr( $bytes, $i, 16 );
            #                        my $hex   = join( ' ', map { sprintf '%02X', ord $_ } split( //, $chunk ) );
            #                        my $pad   = 16 - length($chunk);
            #                        $hex .= '   ' x $pad if $pad;
            #                        my $ascii = join( '', map { ord $_ >= 32 && ord $_ < 127 ? $_ : '.' } split( //, $chunk ) );
            #                        warn sprintf( '%08x: %-48s %s', $i, $hex, $ascii ) . "\n";
            #                    }
            #                    warn "(hex dump of $file, $len bytes)\n";
            #                }
            #                else {
            #                    warn "Cannot open $file for hex dump: $!\n";
            #                }
            #            }
        }
        $ctx->ok( !$mismatch, $name ) if defined $expected;
        unlink $file unless $keep;
        $ctx->release;
        return $actual;
    }
};
#
1;
