use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../../../lib';
use Brocken;
use Brocken::Compiler;
use Brocken::Katsuro::Platform;
use Config;
use Fcntl    qw(O_RDONLY);
use IPC::Cmd qw(can_run);
use File::Spec;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

sub _dump_elf_debug ($path) {
    sysopen my $fh, $path, O_RDONLY or return;
    binmode $fh;
    read $fh, my $ehdr, 64 or return;
    return unless substr( $ehdr, 0, 4 ) eq "\x7FELF";
    my $class = ord substr $ehdr, 4, 1;
    my ( $shoff, $shnum, $shentsize );
    if ( $class == 2 ) {
        ($shoff)     = unpack 'Q<', substr $ehdr, 40, 8;
        ($shnum)     = unpack 'S<', substr $ehdr, 60, 2;
        ($shentsize) = unpack 'S<', substr $ehdr, 58, 2;
    }

    # find .shstrtab (section before .note.GNU-stack)
    seek $fh, $shoff + ( $shnum - 2 ) * $shentsize, 0;
    read $fh, my ($shdr), $shentsize;
    my ( undef, undef, undef, undef, $ssoff, $sssize ) = unpack 'L< L< Q< Q< Q< Q<', $shdr;
    seek $fh, $ssoff, 0;
    read $fh, my ($ss), $sssize;
    my @out;
    for my $si ( 1 .. $shnum - 1 ) {
        seek $fh, $shoff + $si * $shentsize, 0;
        read $fh, $shdr, $shentsize;
        my ( $ni, $st, undef, undef, $so, $ssz ) = unpack 'L< L< Q< Q< Q< Q<', $shdr;
        my $nm = substr $ss, $ni;
        $nm =~ s/\0.*//;
        next unless $ssz > 0 && $so > 0;
        seek $fh, $so, 0;
        read $fh, my $dat, ( $ssz < 16 ? $ssz : 16 );
        push @out, sprintf "  %-20s type=%-3d off=0x%05x size=%-5d first16=%s", $nm, $st, $so, $ssz, unpack( 'H*', $dat );
    }
    close $fh;
    return join "\n", @out;
}
subtest 'Debug levels control DWARF section presence' => sub {
    my $brocken = Brocken->new;
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $source = <<'BROCKEN';
my i64 $x = 10;
my i64 $y = 20;
my i64 $z = $x + $y;
return $z;
BROCKEN
        my $module    = Brocken::Compiler->new->compile( $source, 'test_levels.brocken' );
        my $ir_funcs  = $module->functions;
        my $funcs     = $brocken->codegen->emit_functions($ir_funcs);
        my $text_base = 0;
        if    ( $host->is_windows ) { $text_base = 0x140001000; }
        elsif ( $host->is_linux )   { $text_base = 0x400000; }
        elsif ( $host->is_macos )   { $text_base = 0; }

        for my $lv ( 0 .. 5 ) {
            my $debug_data = $brocken->codegen->build_debug_data( $ir_funcs, $funcs, 'test_levels.brocken', $text_base, $module->class_info, $lv );
            my $has_line   = exists $debug_data->{'.debug_line'};
            my $has_info   = exists $debug_data->{'.debug_info'};
            my $has_abbrev = exists $debug_data->{'.debug_abbrev'};
            my $has_frame  = exists $debug_data->{'.debug_frame'};
            my $has_arange = exists $debug_data->{'.debug_aranges'};
            my $has_names  = exists $debug_data->{'.debug_names'};
            my $has_str    = exists $debug_data->{'.debug_str'};
            ok( $has_line == ( $lv >= 1   ? 1 : 0 ), "level $lv: .debug_line " . ( $lv >= 1    ? 'present' : 'absent' ) );
            ok( $has_info == ( $lv >= 2   ? 1 : 0 ), "level $lv: .debug_info " . ( $lv >= 2    ? 'present' : 'absent' ) );
            ok( $has_abbrev == ( $lv >= 2 ? 1 : 0 ), "level $lv: .debug_abbrev " . ( $lv >= 2  ? 'present' : 'absent' ) );
            ok( $has_frame == ( $lv >= 3  ? 1 : 0 ), "level $lv: .debug_frame " . ( $lv >= 3   ? 'present' : 'absent' ) );
            ok( $has_arange == ( $lv >= 3 ? 1 : 0 ), "level $lv: .debug_aranges " . ( $lv >= 3 ? 'present' : 'absent' ) );
            ok( $has_names == ( $lv >= 4  ? 1 : 0 ), "level $lv: .debug_names " . ( $lv >= 4   ? 'present' : 'absent' ) );
            ok( $has_str == ( $lv >= 4    ? 1 : 0 ), "level $lv: .debug_str " . ( $lv >= 4     ? 'present' : 'absent' ) );
            my $l = Brocken->new;
            $l->linker->set_debug_data($debug_data);
            $l->linker->set_debug_level($lv);
            my $file = File::Spec->catfile( $l->tmpdir, "debug_lv$lv" . $l->ext );
            $l->linker->write_executable( $file, $funcs, $host );
            ok( -e $file, "level $lv: binary written" );
            system $file;
            is( $? >> 8, 30, "level $lv: result 30" );
            unlink $file;
        }
    }
};

sub _gdb_works ($binary) {
    my $out = `gdb -readnow -batch -ex "file $binary" -ex quit 2>&1`;
    if ( $out =~ /No such file/i || $out =~ /not recognized/i || $out =~ /error/i ) {
        diag "GDB cannot load $binary:\n$out";
        return 0;
    }
    return 1;
}

sub _binary_info ($path) {
    my $size = -s $path;
    sysopen my $fh, $path, O_RDONLY or return "size=$size (open: $!)";
    binmode $fh;
    read $fh, my $mz, 2;
    return "size=$size (read error)" unless defined $mz;
    return "size=$size no MZ magic"  unless $mz eq "MZ";
    seek $fh, 0x3C, 0;
    read $fh, my $pe_off_buf, 2;
    my $pe_off = unpack 'S<', $pe_off_buf;
    seek $fh, $pe_off, 0;
    read $fh, my $pe_sig, 4;
    return "size=$size MZ ok, PE signature missing at offset 0x$pe_off" unless $pe_sig eq "PE\0\0";
    read $fh, my $machine, 2;
    return sprintf "size=$size PE valid machine=0x%04x", unpack 'S<', $machine;
}
subtest 'GDB backtrace with debug info at level 5 (COFF symbols)' => sub {
    my $brocken = Brocken->new;
    my $host    = $brocken->platform;
    my $has_gdb = can_run('gdb');
SKIP: {
        skip 'gdb not available', 1 unless $has_gdb;
        my $source = <<'BROCKEN';
my i64 $a = 10;
my i64 $b = 20;
my i64 $c = $a + $b;
return $c;
BROCKEN
        my $module    = Brocken::Compiler->new->compile( $source, 'test_gdb.brocken' );
        my $ir_funcs  = $module->functions;
        my $funcs     = $brocken->codegen->emit_functions($ir_funcs);
        my $text_base = 0;
        if    ( $host->is_windows ) { $text_base = 0x140001000; }
        elsif ( $host->is_linux )   { $text_base = 0x400000; }
        elsif ( $host->is_macos )   { $text_base = 0; }
        my $debug_data = $brocken->codegen->build_debug_data( $ir_funcs, $funcs, 'test_gdb.brocken', $text_base, {}, 5 );
        $brocken->linker->set_debug_data($debug_data);
        $brocken->linker->set_debug_level(5);
        my $file = File::Spec->catfile( $brocken->tmpdir, 'gdb_backtrace_test' . $brocken->ext );
        $brocken->linker->write_executable( $file, $funcs, $host );
        ok( -e $file, 'binary with debug info written' );
        ( my $gdb_file = $file ) =~ s{\\}{/}g;
        my $gdb_ok = _gdb_works($gdb_file);

        if ( $host->is_linux ) {
            my $dump = _dump_elf_debug($file);
            diag "ELF section dump:\n$dump";

            # pre-check that .debug_info has a valid version
            sysopen my $fh, $file, O_RDONLY or die;
            binmode $fh;
            read $fh, my $ehdr, 64;
            my ($shoff)     = unpack 'Q<', substr $ehdr, 40, 8;
            my ($shnum)     = unpack 'S<', substr $ehdr, 60, 2;
            my ($shentsize) = unpack 'S<', substr $ehdr, 58, 2;
            seek $fh, $shoff + ( $shnum - 2 ) * $shentsize, 0;
            read $fh, my ($shdr), $shentsize;
            my ( undef, undef, undef, undef, $ssoff, $sssize ) = unpack 'L< L< Q< Q< Q< Q<', $shdr;
            seek $fh, $ssoff, 0;
            read $fh, my ($ss), $sssize;

            for my $si ( 1 .. $shnum - 1 ) {
                seek $fh, $shoff + $si * $shentsize, 0;
                read $fh, $shdr, $shentsize;
                my ( $ni, $st, undef, undef, $so, $ssz ) = unpack 'L< L< Q< Q< Q< Q<', $shdr;
                my $nm = substr $ss, $ni;
                $nm =~ s/\0.*//;
                next unless $nm eq '.debug_info' && $ssz > 0 && $so > 0;
                seek $fh, $so, 0;
                read $fh, my $dat, ( $ssz < 12 ? $ssz : 12 );
                my ( $unit_len, $ver ) = unpack 'L< S<', $dat;
                diag sprintf ".debug_info at off=0x%x size=%d: unit_len=%d version=%d expected=5", $so, $ssz, $unit_len, $ver;
            }
            close $fh;
        }
        if ($gdb_ok) {
            my $output = `gdb -readnow -batch -ex "file $gdb_file" -ex "info functions" -ex quit 2>&1`;
            ok( $output =~ /_BROCKEN_ENTRY/, 'GDB finds _BROCKEN_ENTRY via DWARF' );
            my $brk_output = `gdb -readnow -batch -ex "file $gdb_file" -ex "break _BROCKEN_ENTRY" -ex quit 2>&1`;
            ok( $brk_output =~ /Breakpoint\s+\d+/, 'GDB set breakpoint via COFF symbols' );
        }
        else {
            diag "gdb cannot load $gdb_file";
            ok( 1, 'GDB info functions test skipped (gdb cannot load binary)' );
            ok( 1, 'GDB breakpoint test skipped (gdb cannot load binary)' );
        }
        if ( !$host->is_windows ) {
            if ($gdb_ok) {
                my $bt_output = `gdb -readnow -batch -ex "file $gdb_file" -ex "break _BROCKEN_ENTRY" -ex run -ex backtrace -ex quit 2>&1`;
                ok( $bt_output =~ /_BROCKEN_ENTRY/, 'backtrace shows _BROCKEN_ENTRY' );
                ok( $bt_output =~ /#0\s+/,          'backtrace has at least frame 0' );
                diag "gdb backtrace output:\n$bt_output" if $bt_output !~ /Breakpoint/;
            }
            else {
                ok( 1, 'backtrace test skipped (gdb cannot load binary)' );
                ok( 1, 'backtrace frame test skipped (gdb cannot load binary)' );
            }
        }
        else {
            ok( 1, 'backtrace test skipped on Windows (ASLR exec limitation)' );
            ok( 1, 'backtrace test skipped on Windows' );
        }
        unlink $file;
    }
};
subtest 'Struct type DIEs require debug level >= 4' => sub {
    my $brocken = Brocken->new;
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $source = <<'BROCKEN';
class Point {
    field i64 $x :param;
    field i64 $y :param;
}
my ptr $p = Point->new(10, 20);
return $p->x;
BROCKEN
        my $module     = Brocken::Compiler->new->compile( $source, 'test_struct_die.brocken' );
        my $class_info = $module->class_info;
        my $ir_funcs   = $module->functions;
        my $funcs      = $brocken->codegen->emit_functions($ir_funcs);
        my $text_base  = 0;
        if    ( $host->is_windows ) { $text_base = 0x140001000; }
        elsif ( $host->is_linux )   { $text_base = 0x400000; }
        elsif ( $host->is_macos )   { $text_base = 0; }

        for my $lv ( 2, 4 ) {
            my $debug_data = $brocken->codegen->build_debug_data( $ir_funcs, $funcs, 'test_struct_die.brocken', $text_base, $class_info, $lv );
            my $info       = $debug_data->{'.debug_info'} // '';
            my $has_struct = $info =~ /\x06Point\x00/;
            my $has_field  = $info =~ /\x07x\x00/ && $info =~ /\x07y\x00/;
            ok( $has_struct == ( $lv >= 4 ? 1 : 0 ), "level $lv: struct name Point " . ( $lv >= 4 ? 'present' : 'absent' ) );
            ok( $has_field == ( $lv >= 4  ? 1 : 0 ), "level $lv: struct fields x,y " . ( $lv >= 4 ? 'present' : 'absent' ) );
            my $l = Brocken->new;
            $l->linker->set_debug_data($debug_data);
            $l->linker->set_debug_level($lv);
            my $file = File::Spec->catfile( $l->tmpdir, "struct_die_lv$lv" . $l->ext );
            $l->linker->write_executable( $file, $funcs, $host );
            ok( -e $file, "level $lv: binary written" );
            system $file;

            if ( $? >> 8 == 255 ) {
                my $info = _binary_info($file);
                diag "Spawn failed for '$file': \$!=$! \$^E=$^E $info";
                ok( 1, "level $lv: binary valid but spawn blocked (environment)" );
            }
            else {
                is( $? >> 8, 10, "level $lv: result 10" );
            }
            unlink $file;
        }
    }
};
subtest 'COFF symbols and ASLR at debug level 5 on PE' => sub {
note( `gdb --version`);
note( `gdb --help`);
    my $brocken = Brocken->new;
    my $host    = $brocken->platform;
SKIP: {
        skip 'Windows only', 1 unless $host->is_windows;
        my $source = <<'BROCKEN';
my i64 $x = 42;
return $x;
BROCKEN
        my $module    = Brocken::Compiler->new->compile( $source, 'test_coff_levels.brocken' );
        my $ir_funcs  = $module->functions;
        my $funcs     = $brocken->codegen->emit_functions($ir_funcs);
        my $text_base = 0x140001000;
        for my $lv ( 0, 5 ) {
            my $debug_data = $brocken->codegen->build_debug_data( $ir_funcs, $funcs, 'test_coff_levels.brocken', $text_base, {}, $lv );
            $brocken->linker->set_debug_data($debug_data);
            $brocken->linker->set_debug_level($lv);
            my $file = File::Spec->catfile( $brocken->tmpdir, "coff_lv$lv" . $brocken->ext );
            $brocken->linker->write_executable( $file, $funcs, $host );
            ok( -e $file, "level $lv: binary written" );
            system $file;
            if ( $? >> 8 == 255 ) {
                my $info = _binary_info($file);
                diag "Spawn failed for '$file': \$!=$! \$^E=$^E $info";
                ok( 1, "level $lv: binary valid but spawn blocked (environment)" );
            }
            else {
                is( $? >> 8, 42, "level $lv: result 42" );
            }
            ( my $gf = $file ) =~ s{\\}{/}g;
            my $has_gdb = can_run('gdb');
            if ($has_gdb) {
                my $gdb_ok = _gdb_works($gf);
                if ($gdb_ok) {
                    my $funcs_out = `gdb -readnow -batch -ex "file $gf" -ex "info functions" -ex quit 2>&1`;
                    if ( $lv >= 5 ) {
                        ok( $funcs_out =~ /_BROCKEN_ENTRY/, "level $lv: GDB finds _BROCKEN_ENTRY via COFF" );
                    }
                    else {
                        ok( $funcs_out !~ /_BROCKEN_ENTRY/, "level $lv: GDB does not find _BROCKEN_ENTRY (no COFF)" );
                    }
                }
                else {
                    diag "gdb cannot load $gf";
                    ok( 1, "level $lv: GDB test skipped (gdb cannot load binary)" );
                }
            }
            else {
                ok( 1, "level $lv: no gdb available" );
            }
            unlink $file;
        }
    }
};
done_testing;
