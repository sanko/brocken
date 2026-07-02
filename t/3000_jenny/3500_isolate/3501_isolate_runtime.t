use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../../../lib';
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
SKIP: {
    my $brocken  = Brocken->new();
    my $platform = $brocken->platform;
    skip 'Isolate runtime test only on native hosts', 1 unless $platform->is_native;
    subtest 'isolate_create and isolate_join basic lifecycle' => sub {
        my $i32 = Brocken::Lindsay::IR::Type::i32();
        my $i64 = Brocken::Lindsay::IR::Type::i64();

        # Worker: return 42 (verifies thread executes and function call works)
        my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
        my $wb     = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );

        # Main: create isolate, join it, return 99 as proof of lifecycle
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $iso = $mb->build_isolate_create( $worker, [], '%iso' );
        $mb->build_isolate_join($iso);
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );

        # Compile with isolate trampoline support
        my $funcs           = $brocken->codegen->emit_functions( [ $main, $worker ] );
        my $expect_fn_count = $platform->is_windows ? 4 : 3;
        ok( scalar @$funcs == $expect_fn_count, "emit_functions produced $expect_fn_count functions" ) or
            diag( join( ', ', map { $_->{name} // '?' } $funcs->@* ) );
        my $output_file = $brocken->tmpdir . '/isolate_test' . $brocken->ext;
        $brocken->linker->write_executable( $output_file, $funcs, $platform );
        ok( -f $output_file, 'Isolate test executable exists' ) or do { unlink $output_file if -f $output_file; skip 'no binary', 0 };
        if ( $platform->is_dragonflybsd || $platform->is_freebsd ) {
            for my $cmd ( "readelf -l $output_file", "readelf -d $output_file", "readelf -h $output_file" ) {
                diag("=== $cmd ===");
                my $out = `$cmd 2>&1`;
                chomp $out;
                diag($_) for split /\n/, $out;
            }
        }
        if ( $platform->is_dragonflybsd ) {
            diag('=== DragonFly libc diagnostics ===');
            for my $lib (qw(/usr/lib/libc.so.8 /usr/lib/libpthread.so.0 /usr/lib/libthread_xu.so.2)) {
                next unless -e $lib;
                diag("--- $lib PT_TLS (readelf -l) ---");
                my $lout = `readelf -l $lib 2>&1`;
                for ( split /\n/, $lout ) {
                    if (/PT_TLS|LOAD|Type|Offset|VirtAddr|FileSiz|MemSiz|Flags|Align/) {
                        s/\t/ /g;
                        diag("  $_");
                    }
                }
            }

            # Find sigblockall symbol and dump its disassembly + GOT data
            diag('--- sigblockall analysis ---');
            my $sym_out = `readelf -s /usr/lib/libc.so.8 2>/dev/null | grep sigblockall`;
            chomp $sym_out;
            diag("  readelf -s: $sym_out");
            my $sig_addr;
            if ( $sym_out =~ /:\s+([0-9a-fA-F]+)\s/ ) {
                $sig_addr = hex($1);
            }
            if ($sig_addr) {
                my $start = sprintf '%x', $sig_addr;
                my $stop  = sprintf '%x', $sig_addr + 0x40;
                my $dis   = `objdump -d --start-address=0x$start --stop-address=0x$stop /usr/lib/libc.so.8 2>&1`;
                for ( split /\n/, $dis ) { s/\t/ /g; diag("  $_"); }

                # The instruction at sigblockall+9 is:
                #   mov 0x2f9ba8(%rip),%rax
                # This loads from RIP at runtime.  We need the file-level offset.
                # RIP-relative at offset (sig_addr+9+7 = sig_addr+0x10) with disp32 = 0x2f9ba8.
                # Target file offset = (sig_addr + 0x10) + 0x2f9ba8.  That's the GOT/data addr.
                my $got_file_offset = $sig_addr + 0x10 + 0x2f9ba8;
                diag( sprintf '  GOT/data file offset from sigblockall+9 = 0x%x', $got_file_offset );

                # Check relocation at or near that file offset
                diag('  readelf -r entries at that offset:');
                my $hex_off = sprintf '%x', $got_file_offset;
                my $rel     = `readelf -r /usr/lib/libc.so.8 2>&1`;
                for ( split /\n/, $rel ) {
                    if (/\Q$hex_off\E/i) { s/\t/ /g; diag("  $_"); }
                }

                # Raw 8-byte value at that file offset
                diag('  raw 8 bytes at that offset (od):');
                my $od = `od -A x -t x8 -j $got_file_offset -N 8 /usr/lib/libc.so.8 2>&1`;
                for ( split /\n/, $od ) { s/\t/ /g; diag("  $_"); }

                # Also dump offset comparisons with FS.base values from GDB
                diag('  FS.base ~= 0x800876980 (from GDB %fs:0x0)');
                diag('  rax = 0x800878fd0 (from GDB crash register dump)');
                diag( sprintf '  rax - FS.base = 0x%x', 0x800878fd0 - 0x800876980 );
            }
        }
        system $output_file;
        my $exit_code = $? >> 8;
        is( $exit_code, 99, 'Isolate test exited with 99 (lifecycle completed)' );

        #~ unlink $output_file;
    };
}
done_testing;
