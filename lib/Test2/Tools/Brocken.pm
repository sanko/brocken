package Test2::Tools::Brocken v0.0.1 {
    use v5.40;
    use Exporter 'import';
    use Test2::API qw[context];

    # The assertion functions are used in their function form rather than through a context object, so they land in
    # whatever context the calling test already has -- a subtest, say -- instead of opening a nested one of their own.
    use Test2::Tools::Basic   qw[fail diag skip];
    use Test2::Tools::Compare qw[is];
    use Carp                  qw[croak];
    use File::Spec;
    use File::Temp;
    our @EXPORT_OK = qw[run_exec temp_path cross_available wasm_runner wasmtime_binary node_binary wasm_platform wasm_entry_value
        wasm_validates validates executable_targets answers phys_operands];
    our %EXPORT_TAGS = ( all => [@EXPORT_OK] );
    #
    sub temp_path ($basename) {
        state $TMPDIR //= File::Temp->newdir( CLEANUP => 1, TMPDIR => 1 );
        my $dir = $TMPDIR->dirname;
        $dir =~ s/\\/\//g;
        return $dir . '/' . $basename;
    }

    # Looks a binary up on PATH and returns where it was found, or nothing. The test suite carries no absolute path of
    # its own, so a missing tool leaves the caller free to skip rather than fail.
    #
    # The suffixes in PATHEXT are what `where` searches and this does not, so they are tried explicitly. Without that,
    # `wasmtime` is not found on a Windows host at all, because the file on disk is `wasmtime.exe`.
    sub _find_binary ($exe) {
        my @suffixes = ( '', ( $^O eq 'MSWin32' ? split /;/, ( $ENV{PATHEXT} // '.COM;.EXE;.BAT;.CMD' ) : () ) );
        for my $dir ( File::Spec->path ) {
            for my $suffix (@suffixes) {
                my $found = File::Spec->catfile( $dir, $exe . $suffix );
                return $found if -f $found;
            }
        }
        return undef;
    }
    sub wasmtime_binary () { state $found //= _find_binary('wasmtime') }
    sub node_binary ()     { state $found //= _find_binary('node') }

    # Which runner can execute a Wasm module here. wasmtime is preferred; node can instantiate a module without it,
    # which is enough to read the entry's return value. Nothing at all means the Wasm target cannot be exercised, and
    # the caller is expected to skip.
    sub wasm_runner () {
        return 'wasmtime' if wasmtime_binary();
        return 'node'     if node_binary();
        return undef;
    }

    sub wasm_platform () {
        require Brocken::Katsuro::Platform;
        return Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
    }

    # Whether a linked `.wasm` is accepted by a validator, as a system() status: zero when the module is valid. Nothing
    # at all when no runner is present, so the caller can skip rather than report a module as broken.
    sub wasm_validates ($file) {
        my $runner = wasm_runner() or return undef;
        if ( $runner eq 'wasmtime' ) {
            my $null = $^O eq 'MSWin32' ? 'NUL' : '/dev/null';
            return system qq["@{[ wasmtime_binary() ]}" compile "$file" -o "$null" 2>&1];
        }
        return system( node_binary(), '-e', "const fs=require('fs');process.exit(WebAssembly.validate(fs.readFileSync('$file'))?0:1);" );
    }

    # A qemu binary and the sysroot it needs are named for the host that has them, which on a Windows host is normally
    # WSL.  Both are named through
    # the environment so the test suite carries no absolute path of its own: without them there is nothing to run a
    # foreign ELF with, and the caller is expected to skip rather than fail.
    my %QEMU = ( aarch64 => 'qemu-aarch64', riscv64 => 'qemu-riscv64', x86_64 => 'qemu-x86_64' );

    sub _wsl_path ($path) {
        return undef unless defined $path && length $path;
        $path =~ s{\\}{/}g;

        # A path that already crosses into the distribution, whether written as a share (`//wsl$/Ubuntu/...`) or as the
        # path inside it, is passed through.  A Windows path is a drive letter, and the drive is mounted under /mnt by
        # default.
        return $1                          if $path =~ m{^(//wsl\$/[^/]+(?:/.*)?)$};
        return '/' . $1                    if $path =~ m{^/(wsl\$/[^/]+/.*)$};
        return '/mnt/' . lc($1) . '/' . $2 if $path =~ m{^([A-Za-z]):/(.*)$};
        return $path;
    }

    # A path that already names a place inside the distribution is what qemu wants, but it is not something this host
    # can stat, so the check goes through the share and the two forms are kept apart.
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
        return _find_binary($exe) ? 1 : 0;
    }

    # Every target a snippet can be run on here: the host always, a cross target only when its emulator and sysroot are
    # present, and Wasm only when a runner for it is. A target that cannot be executed is left out rather than reported
    # as a failure, since its absence says nothing about the compiler.
    sub executable_targets () {
        require Brocken::Katsuro::Platform;
        my @targets = ( [ 'host', undef ] );
        for my $triple ( 'aarch64-unknown-linux-gnu', 'riscv64-unknown-linux-gnu' ) {
            my $platform = eval { Brocken::Katsuro::Platform::parse($triple) };
            push @targets, [ $triple, $platform ] if $platform && cross_available($platform);
        }
        push @targets, [ 'wasm32-unknown-wasi', wasm_platform() ] if wasm_runner();
        return @targets;
    }

    # Runs a linked `.wasm` and returns the value `_BROCKEN_ENTRY` returned, followed by whatever the runner printed.
    # The entry returns an i64 that the test compares as a number, so it is the last line rather than the whole
    # output: a runner writes its own warnings alongside the value.
    sub wasm_entry_value ( $file, %args ) {
        my $runner = $args{runner} // wasm_runner();
        return ( undef, "no Wasm runner is available\n" ) unless $runner;
        my $memory = $args{memory} // 1024;
        my $output;
        if ( $runner eq 'wasmtime' ) {
            $output = qx["@{[ wasmtime_binary() ]}" run --invoke _BROCKEN_ENTRY "$file" $memory 2>&1];
        }
        else {
            my $js
                = "const fs=require('fs');const buf=fs.readFileSync('$file');" .
                'WebAssembly.instantiate(buf).then(r=>{process.exit(Number(' .
                "r.instance.exports._BROCKEN_ENTRY(BigInt($memory))));})" .
                '.catch(e=>{console.error(e);process.exit(1);});';
            system( node_binary(), '-e', $js );
            $output = ( $? >> 8 ) . "\n";
        }
        my @lines = grep {/\S/} split /\n/, $output;
        return ( @lines ? $lines[-1] : '', $output );
    }

    # Compiles a snippet and asserts the value it returns, on every target that can be run here. `targets` defaults to
    # `executable_targets`, and each entry is a `[ tag, platform ]` pair, with an undefined platform meaning the host.
    # A Wasm platform is linked to a `.wasm` and run through whichever runner is available; anything else is run as a
    # native executable and compared on its exit status. `basename` names the file each target is written to.
    sub answers ( $src, $want, $name, %args ) {
        require Brocken;
        require Brocken::Jenny::Linker::Wasm;
        my @targets  = @{ $args{targets} // [ executable_targets() ] };
        my $basename = $args{basename} // 'brocken';
        for my $target (@targets) {
            my ( $tag, $platform ) = @$target;
            my $label   = $tag eq 'host' ? $name                                 : "$name [$tag]";
            my $brocken = $platform      ? Brocken->new( platform => $platform ) : Brocken->new();
            my $module  = eval { $brocken->compile($src) };
            if ($@) { fail("$label: compile died: $@"); next }
            my $funcs = $brocken->codegen->emit_functions( $module->functions );
            if ( $platform && $platform->arch =~ /^wasm/ ) {
                my $file = temp_path($basename) . '.wasm';
                Brocken::Jenny::Linker::Wasm->new->write_executable( $file, $funcs, $platform );
                my ( $got, $output ) = wasm_entry_value($file);
                is( $got + 0, $want, $label ) or diag($output);
                unlink $file if -e $file;
                next;
            }

            # The linker's platform is the one the instance was built with, not this loop's `$platform`, which is undef
            # for the host target:
            # MachO reads `->arch` and `->os` off it to pick the slice.
            my $file = temp_path($basename) . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
            run_exec( $file, expected_exit => $want, platform => $platform, name => $label );
            unlink $file if -e $file;
        }
        return;
    }

    # Compiles a snippet for the Wasm target, links it, and asserts that the module validates. This is the check that
    # catches an operand width or a stack type the validator objects to, which is a different failure from
    # returning a wrong number: the module never runs at all. `answers` covers the running side.
    sub validates ( $src, $name, %args ) {
        require Brocken;
        require Brocken::Jenny::Linker::Wasm;
        my $platform = $args{platform} // wasm_platform();
        my $brocken  = $args{brocken}  // Brocken->new( platform => $platform );
        my $basename = $args{basename} // 'brocken';
        my $module   = eval { $brocken->compile($src) };
        if ($@) { fail("$name: compile died: $@"); return }
        my $file = temp_path($basename) . '.wasm';
        Brocken::Jenny::Linker::Wasm->new->write_executable( $file, $brocken->codegen->emit_functions( $module->functions ), $platform );
    SKIP: {
            skip 'no Wasm runner is available', 1 unless wasm_runner();
            my $status = wasm_validates($file);
            is( $status, 0, $name ) or diag('the module did not validate');
        }
        unlink $file if -e $file;
        return;
    }

    # The physical registers named by operand `$which` of every `$opcode` instruction in a machine function, in the
    # order they appear. A test that cares which register an argument landed in reads it through here rather than
    # walking the block and instruction lists itself.
    sub phys_operands ( $mf, $opcode, $which ) {
        my @names;
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                next unless $inst->opcode eq $opcode;
                my @ops = $inst->operands->@*;
                next unless @ops > $which;
                my $op = $ops[$which];
                push @names, $op->value if $op->kind eq 'phys_reg';
            }
        }
        return @names;
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

        # A foreign target needs an emulator, and this one is not always present.  Returning nothing leaves the caller
        # free to skip; running the file directly would only report a bad-executable error that says nothing about the
        # compiler.
        my $cross = cross_command( $file, $platform, $argv );
        return undef unless $cross;
        my $cmd  = $cross;
        my @exec = @$cmd;
        my $actual;

        # The assertion is reported here, not at the end, so that a caller that returns early still gets one.  Holding
        # the context open to the end meant a subtest died inside it and the whole subtest was reported as failing with
        # no assertion of its own.
        # A child killed by a signal reports `$? & 127`, and `$? >> 8` is then 0: the harness used to call that a clean
        # `exit 0`, which let real crashes (an isolate segfaulting with SIGSEGV reported as 139) pass any test expecting
        # 0. Signal death is now always a failure in its own right.
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
