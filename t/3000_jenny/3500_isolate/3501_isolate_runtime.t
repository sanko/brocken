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
            for my $lib (grep -e, glob('/lib/libc.so.* /usr/lib/libc.so.* /lib/libpthread.so.* /usr/lib/libpthread.so.* /usr/lib/libthread_xu.so.*')) {
                diag("--- $lib (readelf -l) ---");
                my $lout = `readelf -l $lib 2>&1`;
                for ( split /\n/, $lout ) {
                    if (/PT_TLS|LOAD|Type|Offset|VirtAddr|FileSiz|MemSiz|Flags|Align/) {
                        s/\t/ /g;
                        diag("  $_");
                    }
                }
            }

            # Find sigblockall symbol across all libs using nm (dynamic syms)
            diag('--- sigblockall analysis ---');
            my ($sig_addr, $sig_lib);
            for my $lib (grep -e, glob('/lib/libc.so.* /usr/lib/libc.so.*')) {
                for my $cmd (
                    "nm -D $lib 2>/dev/null | grep -w sigblockall",
                    "objdump -T $lib 2>/dev/null | grep -w sigblockall",
                    "readelf -s $lib 2>/dev/null | grep -w sigblockall",
                ) {
                    my $out = `$cmd`;
                    chomp $out;
                    next unless $out;
                    diag("  $cmd => $out");
                    if ($out =~ /([0-9a-fA-F]+)\s/) {
                        $sig_addr = hex($1);
                        $sig_lib  = $lib;
                        last;
                    }
                }
                last if $sig_addr;
            }

            if ($sig_addr) {
                my $start = sprintf '%x', $sig_addr - 0x10;
                my $stop  = sprintf '%x', $sig_addr + 0x40;
                diag("  --- $sig_lib disassembly around sigblockall (0x$start-0x$stop) ---");
                my $dis = `objdump -d --start-address=0x$start --stop-address=0x$stop $sig_lib 2>&1`;
                for ( split /\n/, $dis ) { s/\t/ /g; diag("  $_"); }

                # Dump relocation table for the matched lib
                diag("  relocation table for $sig_lib:");
                my $rel = `readelf -r $sig_lib 2>&1`;
                for ( split /\n/, $rel ) { s/\t/ /g; diag("  $_"); }

                # Hexdump .got and .data
                diag("  hexdump .got (objdump -s) for $sig_lib:");
                my $got = `objdump -s -j .got $sig_lib 2>&1`;
                for ( split /\n/, $got ) { s/\t/ /g; diag("  $_"); }
                diag("  hexdump .data (objdump -s) for $sig_lib:");
                my $data = `objdump -s -j .data $sig_lib 2>&1 | head -40`;
                for ( split /\n/, $data ) { s/\t/ /g; diag("  $_"); }

                # Compute the runtime address for the GOT entry used by sigblockall+9
                if ( $sig_lib =~ m|/libc\.so| ) {
                    diag( '  --- sigblockall+9 GOT entry analysis ---' );

                    # Find LOAD segments to compute file offset of GOT entry
                    my $load_info = `readelf -l $sig_lib 2>&1`;
                    # RW LOAD: second LOAD, we need its FileSiz+MemSiz
                    my ($rw_file_off, $rw_va, $rw_file_sz);
                    for (split /\n/, $load_info) {
                        if (/LOAD\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x([0-9a-f]+)/) {
                            ($rw_file_off, $rw_va, $rw_file_sz) = (hex($1), hex($2), hex($3));
                        }
                    }
                    if ($rw_va) {
                        my $rw_file_off_end = $rw_file_off + $rw_file_sz;
                        my $got_va = 0x338770;
                        my $inside = ($got_va >= $rw_va && $got_va < $rw_va + $rw_file_sz);
                        my $file_off = $rw_file_off + ($got_va - $rw_va);
                        diag("  --- file-level GOT entry ($got_va) ---");
                        diag("    RW LOAD: VA=0x$rw_va, file_off=0x$rw_file_off, file_sz=0x$rw_file_sz, end=0x$rw_file_off_end");
                        diag("    GOT VA 0x$got_va " . ($inside ? "INSIDE RW LOAD" : "OUTSIDE RW LOAD"));
                        diag("    GOT file offset: 0x" . sprintf('%x', $file_off));
                        my $od_out = `od -A x -t x8 -j $file_off -N 8 $sig_lib 2>&1`;
                        chomp $od_out;
                        diag("    raw file bytes (od): $od_out");
                    }

                    diag("  --- runtime GOT analysis (file-level) ---");

                    # nm -D with object size/st_type for __lpmap_blockallsigs
                    my $sym = `nm -D $sig_lib 2>/dev/null | grep '__lpmap_blockallsigs'`;
                    chomp $sym;
                    diag("    __lpmap_blockallsigs (nm -D): $sym");
                    my $readelf_sym = `readelf -s $sig_lib 2>/dev/null | grep '__lpmap_blockallsigs'`;
                    chomp $readelf_sym;
                    diag("    __lpmap_blockallsigs (readelf -s): $readelf_sym");

                    # Check if libc is ET_EXEC or ET_DYN
                    my $elf_type = `readelf -h $sig_lib 2>/dev/null | grep 'Type:'`;
                    chomp $elf_type;
                    diag("    libc ELF type: $elf_type");

                    # Dump /proc/self/map via GDB (run then crash to get state)
                    diag("  --- /proc/self/map (from GDB batch) ---");
                    my $map_out = `gdb -batch -ex run -ex 'info proc mappings' -ex quit $output_file 2>&1 | grep -E '0x[0-9a-f]+-' | head -40`;
                    for (split /\n/, $map_out) { s/\t/ /g; diag("  $_"); }

                    # Read runtime GOT value using GDB
                    diag("  --- runtime GOT entry value (from GDB) ---");
                    my $gdb_got = `gdb -batch -ex run -ex 'print/x (sigblockall + 9 + 7 + 0x2f9ba8)' -ex 'x/gx (sigblockall + 9 + 7 + 0x2f9ba8)' -ex 'info reg fs_base' -ex quit $output_file 2>&1`;
                    for (split /\n/, $gdb_got) { s/\t/ /g; diag("  $_"); }
                }
            } else {
                diag('  sigblockall NOT found via nm/objdump/readelf in any libc');
                diag('  --- fallback: dumping all libc symbols matching "blockallsigs" ---');
                for my $lib (grep -e, glob('/lib/libc.so.* /usr/lib/libc.so.*')) {
                    my $out = `nm -D $lib 2>/dev/null | grep -i blockallsigs`;
                    next unless $out;
                    diag("  $lib:");
                    for ( split /\n/, $out ) { s/\t/ /g; diag("    $_"); }
                }
            }
        }
        if ( $platform->is_dragonflybsd ) {
            diag('=== GCC comparison: compile C pthread binary ===');
            my ( $sfh, $c_path ) = File::Temp::tempfile( 'gcc_diag_XXXX', SUFFIX => '.c', TMPDIR => 1, UNLINK => 0 );
            my $gcc_bin = $c_path;
            $gcc_bin =~ s/\.c$//;
            print $sfh <<'CCODE';
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
void* thread_func(void* arg) { int* val = (int*)arg; printf("thread: %d\n", *val); return NULL; }
int main() {
    pthread_t t; int val = 42;
    if (pthread_create(&t, NULL, thread_func, &val) != 0) { fprintf(stderr, "pthread_create failed\n"); return 1; }
    if (pthread_join(t, NULL) != 0) { fprintf(stderr, "pthread_join failed\n"); return 1; }
    printf("main: ok\n"); return 0;
}
CCODE
            close $sfh;
            my $gcc_out = `gcc -lpthread -o $gcc_bin $c_path 2>&1`;
            my $gcc_rc = $? >> 8;
            if ($gcc_rc == 0) {
                diag('=== GCC binary compiled OK ===');
                diag('--- readelf -l comparison ---');
                my $our_phdr = `readelf -l $output_file 2>&1`;
                my $gcc_phdr = `readelf -l $gcc_bin 2>&1`;
                diag("BROCKEN binary program headers:\n$our_phdr");
                diag("GCC binary program headers:\n$gcc_phdr");
                diag('--- readelf -d comparison ---');
                my $our_dyn = `readelf -d $output_file 2>&1`;
                my $gcc_dyn = `readelf -d $gcc_bin 2>&1`;
                diag("BROCKEN dynamic section:\n$our_dyn");
                diag("GCC dynamic section:\n$gcc_dyn");
                diag('--- readelf -S comparison ---');
                my $our_sec = `readelf -S $output_file 2>&1`;
                my $gcc_sec = `readelf -S $gcc_bin 2>&1`;
                diag("BROCKEN section headers:\n$our_sec");
                diag("GCC section headers:\n$gcc_sec");
                diag('--- readelf -s comparison ---');
                my $our_sym = `readelf -s $output_file 2>&1`;
                my $gcc_sym = `readelf -s $gcc_bin 2>&1`;
                diag("BROCKEN symbol table:\n$our_sym");
                diag("GCC symbol table:\n$gcc_sym");
                diag('--- .interp content comparison ---');
                my $our_interp = `strings -n 1 $output_file | grep '^/' | head -1`;
                my $gcc_interp = `strings -n 1 $gcc_bin | grep '^/' | head -1`;
                $our_interp //= '';
                $gcc_interp //= '';
                chomp $our_interp;
                chomp $gcc_interp;
                diag("  BROCKEN interp: '$our_interp'");
                diag("  GCC interp:     '$gcc_interp'");
                diag('--- objdump -p (GCC full private header) ---');
                my $gcc_objdump = `objdump -p $gcc_bin 2>&1`;
                diag($gcc_objdump);
            } else {
                diag("gcc compilation failed (exit $gcc_rc): $gcc_out");
            }
            for my $f ($c_path, $gcc_bin) { unlink $f if defined $f && -f $f; }
        }
        system $output_file;
        my $exit_code = $? >> 8;
        is( $exit_code, 99, 'Isolate test exited with 99 (lifecycle completed)' );

        #~ unlink $output_file;
    };
}
done_testing;
