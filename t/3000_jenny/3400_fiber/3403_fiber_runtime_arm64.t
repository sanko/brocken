use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../../../lib';
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $brocken  = Brocken->new();
my $platform = $brocken->platform;
subtest 'ARM64 fiber yield passes value to main exit code' => sub {
    my $i32    = Brocken::Lindsay::IR::Type::i32();
    my $i64    = Brocken::Lindsay::IR::Type::i64();
    my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
    my $wb     = Brocken::Lindsay::IR::Builder->new();
    $wb->position_at_end( $worker->append_block('entry') );
    my $yield_val = Brocken::Lindsay::IR::Constant->new( type => $i64, value => 99 );
    $wb->build_fiber_yield( $yield_val, '%yv' );
    $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
    my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
    my $mb   = Brocken::Lindsay::IR::Builder->new();
    $mb->position_at_end( $main->append_block('entry') );
    my $fcb  = $mb->build_fiber_create( $worker, [], '%fcb' );
    my $send = Brocken::Lindsay::IR::Constant->new( type => $i64, value => 42 );
    my $recv = $mb->build_fiber_transfer( $fcb, $send, '%recv' );
    $mb->build_ret($recv);
    my $codegen = $brocken->codegen;
    my $funcs   = $codegen->emit_functions( [ $main, $worker ] );
    ok( scalar @$funcs == 3, 'emit_functions produced 3 functions (main wrapper, _real_main, worker_fn)' ) or diag( explain($funcs) );

    for my $f ( $funcs->@* ) {
        warn "=== Hex dump of function '$f->{name}' (" . length( $f->{bytes} ) . " bytes) ===\n";
        my $bytes = $f->{bytes};
        for ( my $i = 0; $i < length $bytes; $i += 16 ) {
            my $chunk = substr( $bytes, $i, 16 );
            my $hex   = join( ' ', map { sprintf '%02X', ord $_ } split( //, $chunk ) );
            my $pad   = 16 - length($chunk);
            $hex .= '   ' x $pad if $pad;
            my $ascii = join( '', map { ord $_ >= 32 && ord $_ < 127 ? $_ : '.' } split( //, $chunk ) );
            warn sprintf( '%08x: %-48s %s', $i, $hex, $ascii ) . "\n";
        }
        for my $fix ( $f->{fixups}->@* ) {
            warn "  fixup: offset=$fix->{offset} type=$fix->{type} target=$fix->{target}\n";
        }
    }
    warn "(end of hex dumps)\n";
SKIP: {
        skip 'Only for ARM64 native hosts', 2 unless $platform->is_arm64 && $platform->is_native;
        my $linker      = $brocken->linker;
        my $output_file = 'fiber_test_arm64' . $brocken->ext;
        $linker->write_executable( $output_file, $funcs, $platform );
        ok( -f $output_file, 'ARM64 fiber test executable exists' ) or do { unlink $output_file if -f $output_file; skip 'no binary', 0 };

        # DEBUG: post-link hex dump + disassembly on ARM64
        warn "\n### DEBUG: post-link binary '$output_file' ###\n";
        open my $fh, '<:raw', $output_file or warn "  can't open $output_file: $!";
        if ($fh) {
            my $bin;
            read $fh, $bin, 4096;
            close $fh;
            for ( my $i = 0; $i < length $bin; $i += 16 ) {
                my $chunk = substr( $bin, $i, 16 );
                my $hex   = join( ' ', map { sprintf '%02X', ord $_ } split( //, $chunk ) );
                my $pad   = 16 - length($chunk);
                $hex .= '   ' x $pad if $pad;
                my $ascii = join( '', map { ord $_ >= 32 && ord $_ < 127 ? $_ : '.' } split( //, $chunk ) );
                warn sprintf( '%08x: %-48s %s', $i, $hex, $ascii ) . "\n";
            }
        }
        warn "\n### DEBUG: disassembly ###\n";
        if ( $platform->is_macos ) {
            system("otool -v -t $output_file 2>&1");
            system("llvm-objdump -d --arch=aarch64 $output_file 2>&1");
        }
        else {
            system("objdump -d --architecture=aarch64 $output_file 2>&1");
        }

        # On Windows, validate the PE format before attempting execution
        if ( $platform->is_windows ) {
            open my $fh, '<:raw', $output_file or die "can't open $output_file: $!";
            my $bin;
            read $fh, $bin, 4096;
            close $fh;
            my $pe_ok = 1;

            # Check MZ magic
            if ( substr( $bin, 0, 2 ) ne 'MZ' ) {
                warn "PE VALIDATION: bad MZ magic\n";
                $pe_ok = 0;
            }
            my $lfanew = unpack( 'V', substr( $bin, 0x3C, 4 ) );
            if ( substr( $bin, $lfanew, 4 ) ne "PE\x00\x00" ) {
                warn "PE VALIDATION: bad PE signature at offset $lfanew\n";
                $pe_ok = 0;
            }
            my $machine             = unpack( 'v', substr( $bin, $lfanew + 4,  2 ) );
            my $num_sections        = unpack( 'v', substr( $bin, $lfanew + 6,  2 ) );
            my $size_of_opt_hdr     = unpack( 'v', substr( $bin, $lfanew + 20, 2 ) );
            my $characteristics     = unpack( 'v', substr( $bin, $lfanew + 22, 2 ) );
            my $opt_hdr_start       = $lfanew + 24;
            my $entry_rva           = unpack( 'V', substr( $bin, $opt_hdr_start + 16, 4 ) );
            my $base_of_code        = unpack( 'V', substr( $bin, $opt_hdr_start + 20, 4 ) );
            my $opt_magic           = unpack( 'v', substr( $bin, $opt_hdr_start,      2 ) );
            my $section_table_start = $opt_hdr_start + $size_of_opt_hdr;
            warn "PE VALIDATION: machine=0x" .
                sprintf( '%04X', $machine ) .
                " sections=$num_sections opt_hdr_size=$size_of_opt_hdr chars=0x" .
                sprintf( '%04X', $characteristics ) . "\n";
            warn "PE VALIDATION: entry_rva=0x" . sprintf( '%X', $entry_rva ) . " base_of_code=0x" . sprintf( '%X', $base_of_code ) . "\n";

            if ( $machine != 0xAA64 ) {
                warn "PE VALIDATION: expected machine 0xAA64 (ARM64)\n";
                $pe_ok = 0;
            }
            if ( $size_of_opt_hdr != 240 ) {
                warn "PE VALIDATION: expected opt hdr size 240 (PE32+ with 16 data dirs), got $size_of_opt_hdr\n";
                $pe_ok = 0;
            }
            if ( $entry_rva == 0 ) {
                warn "PE VALIDATION: entry RVA is 0! Text section RVA is 0x1000\n";
                $pe_ok = 0;
            }

            # Check optional header magic
            if ( $opt_magic != 0x020B ) {
                warn "PE VALIDATION: expected PE32+ magic 0x020B, got 0x" . sprintf( '%04X', $opt_magic ) . "\n";
                $pe_ok = 0;
            }

            # Read section table and dump it
            for my $i ( 0 .. $num_sections - 1 ) {
                my $sec_start = $section_table_start + $i * 40;
                my $sec_name  = substr( $bin, $sec_start, 8 );
                $sec_name =~ s/\x00+$//;
                my ( $sec_vsize, $sec_rva, $sec_rsize, $sec_rptr ) = unpack( 'V4', substr( $bin, $sec_start + 8, 16 ) );
                warn "PE SECTION $i: name='$sec_name' vsize=$sec_vsize rva=0x" .
                    sprintf( '%X', $sec_rva ) .
                    " rsize=$sec_rsize rptr=0x" .
                    sprintf( '%X', $sec_rptr ) . "\n";
            }
            warn "PE VALIDATION: " . ( $pe_ok ? "OK" : "FAILED" ) . "\n";
        }

        # Try running with gdb in batch mode on Windows (if available)
        if ( $platform->is_windows ) {
            my $gdb_out;
            if ( open my $fh, '-|', 'gdb', '-batch', '-nx', '-ex', 'run', '-ex', 'quit', '--args', ".\\$output_file" ) {
                $gdb_out = do { local $/; <$fh> };
                close $fh;
                warn "GDB output:\n$gdb_out\n" if $gdb_out;
            }
            else {
                warn "gdb not available on this system\n";
            }
        }
        my $cmd = $platform->is_windows ? ".\\$output_file" : "./$output_file";
        system {$cmd} $cmd;
        my $exit_code = $? >> 8;
        my $errno     = 0 + $!;
        diag "system($cmd) returned exit=$exit_code, errno=$errno ('$!')" if $exit_code != 99;
        is( $exit_code, 99, 'ARM64 fiber test exited with 99' );
        unlink $output_file;
    }
};
done_testing;
