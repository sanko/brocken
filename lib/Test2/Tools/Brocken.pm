package Test2::Tools::Brocken v0.0.1 {
    use v5.40;
    use Exporter 'import';
    use Test2::API qw[context];
    use Carp       qw[croak];
    use File::Spec;
    use File::Temp;
    our %EXPORT_TAGS = ( all => [ our @EXPORT_OK = qw[run_exec temp_path cross_available] ] );
    #
    sub temp_path ($basename) {
        state $TMPDIR //= File::Temp->newdir( CLEANUP => 1, TMPDIR => 1 );
        my $dir = $TMPDIR->dirname;
        $dir =~ s/\\/\//g;
        return $dir . '/' . $basename;
    }

    # A qemu binary and the sysroot it needs are named for the host that has
    # them, which on a Windows host is normally WSL.  Both are named through
    # the environment so the test suite carries no absolute path of its own:
    # without them there is nothing to run a foreign ELF with, and the caller
    # is expected to skip rather than fail.
    my %QEMU = ( aarch64 => 'qemu-aarch64', riscv64 => 'qemu-riscv64', x86_64 => 'qemu-x86_64' );

    sub _wsl_path ($path) {
        return undef unless defined $path && length $path;
        $path =~ s{\\}{/}g;

        # A path that already crosses into the distribution, whether written
        # as a share (`//wsl$/Ubuntu/...`) or as the path inside it, is passed
        # through.  A Windows path is a drive letter, and the drive is mounted
        # under /mnt by default.
        return $1                          if $path =~ m{^(//wsl\$/[^/]+(?:/.*)?)$};
        return '/' . $1                    if $path =~ m{^/(wsl\$/[^/]+/.*)$};
        return '/mnt/' . lc($1) . '/' . $2 if $path =~ m{^([A-Za-z]):/(.*)$};
        return $path;
    }

    # A path that already names a place inside the distribution is what qemu
    # wants, but it is not something this host can stat, so the check goes
    # through the share and the two forms are kept apart.
    sub _sysroot ($platform) {
        my $sysroot = $ENV{ 'BROCKEN_SYSROOT_' . uc $platform->arch } // $ENV{BROCKEN_SYSROOT};
        return undef unless $sysroot && length $sysroot;
        if ( $^O eq 'MSWin32' && $sysroot =~ m{^/} && $sysroot !~ m{^/mnt/} ) {
            my $distro = $ENV{BROCKEN_WSL_DISTRO} // 'Ubuntu';
            return ( '\\\\wsl$\\' . $distro . $sysroot, $sysroot );
        }
        return ( _wsl_path($sysroot), _wsl_path($sysroot) );
    }

    sub cross_command ( $file, $platform, $argv ) {
        return [ $file, @$argv ] if !$platform || $platform->is_native;
        my $emu = $QEMU{ $platform->arch } or return undef;

        # A dynamically linked binary needs the target's loader, so the
        # sysroot is not optional.
        my ( $check, $sysroot ) = _sysroot($platform);
        return undef unless $check && -d $check;
        if ( $^O eq 'MSWin32' ) {

            # The executable bit does not survive the drive, and qemu refuses
            # to run a file without it.
            my $target = _wsl_path($file);
            system( 'wsl', '-e', 'chmod', '+x', $target ) if defined $target;
            return [ 'wsl', '-e', $emu, '-L', $sysroot, _wsl_path($file), @$argv ];
        }
        return [ $emu, '-L', $sysroot, $file, @$argv ];
    }

    sub cross_available ($platform) {
        return 1 if !$platform || $platform->is_native;
        my $emu = $QEMU{ $platform->arch } or return 0;
        my ($check) = _sysroot($platform);
        return 0 unless $check && -d $check;
        return $^O eq 'MSWin32' ? 1 : !!_which($emu);
    }

    sub _which ($exe) {
        for my $dir ( File::Spec->path ) {
            return 1 if -x File::Spec->catfile( $dir, $exe );
        }
        return 0;
    }

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

        # A foreign target needs an emulator, and this one is not always
        # present.  Returning nothing leaves the caller free to skip; running
        # the file directly would only report a bad-executable error that
        # says nothing about the compiler.
        my $cross = cross_command( $file, $platform, $argv );
        return undef unless $cross;
        my $cmd  = $cross;
        my @exec = @$cmd;
        my $actual;

        # The assertion is reported here, not at the end, so that a caller that
        # returns early still gets one.  Holding the context open to the end
        # meant a subtest died inside it and the whole subtest was reported as
        # failing with no assertion of its own.
        # A child killed by a signal reports `$? & 127`, and `$? >> 8` is then 0:
        # the harness used to call that a clean `exit 0`, which let real crashes
        # (an isolate segfaulting with SIGSEGV reported as 139) pass any test
        # expecting 0. Signal death is now always a failure in its own right.
        my $signal;
        if ($do_gdb) {
            my $gdb_out;
            if (
                open my $fh, '-|', 'gdb', '-batch', '-nx', '-ex', 'run', '-ex', 'bt',
                '-ex', 'info registers', '-ex', 'x/30i $rip-10', '-ex', 'quit', '--args', @exec
            ) {
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
            elsif ( $gdb_out =~ /Program received signal (\w+)/ ) {

                # gdb reports the signal instead of an exit code, and gdb itself
                # still exits 0, so record it separately.
                $signal = $1;
            }
            $ctx->diag("GDB output for $name:\n$gdb_out") if length $gdb_out;
        }
        else {
            eval {
                local $SIG{ALRM} = sub { die "timeout\n" };
                alarm $TIMEOUT;
                system(@exec);
                alarm 0;
            };
            if ( $@ && $@ eq "timeout\n" ) {
                $ctx->diag("run_exec timed out for $name");
                $actual = -1;
                $signal = 0;
            }
            else {
                $actual = $? >> 8;
                $signal = $? & 127;
            }
        }
        my $mismatch = $signal || ( defined $expected && $actual != $expected );

        # The result is asserted before anything can go wrong on the way out,
        # so a test that dies afterwards still records what the run found.
        $ctx->ok( !$mismatch, $name ) if defined $expected;
        if ($mismatch) {
            my $how = $signal ? " (killed by signal $signal)" : '';
            warn "$name: expected exit code $expected, got $actual$how (raw status \$?=$?)\n";

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
        unlink $file unless $keep;
        $ctx->release;
        return $actual;
    }
};

1;
