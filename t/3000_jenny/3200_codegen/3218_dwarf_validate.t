use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../../../lib';
use Brocken;
use Brocken::Compiler;
use Config;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'DWARF v5 binary structure validation' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $source = <<'BROCKEN';
my i64 $x = 10;
my i64 $y = 20;
my i64 $z = $x + $y;
return $z;
BROCKEN
        my $module    = Brocken::Compiler->new->compile( $source, 'test_dwarf.brocken' );
        my $ir_funcs  = $module->functions;
        my $funcs     = $brocken->codegen->emit_functions($ir_funcs);
        my $text_base = 0;
        if    ( $host->is_windows ) { $text_base = 0x140001000; }
        elsif ( $host->is_linux )   { $text_base = 0x400000; }
        elsif ( $host->is_macos )   { $text_base = 0; }
        my $debug_data = $brocken->codegen->build_debug_data( $ir_funcs, $funcs, 'test_dwarf.brocken', $text_base, $module->class_info, 5 );
        ok( exists $debug_data->{'.debug_info'},   '.debug_info section present' );
        ok( exists $debug_data->{'.debug_abbrev'}, '.debug_abbrev section present' );
        ok( exists $debug_data->{'.debug_line'},   '.debug_line section present' );

        # ---- Validate .debug_info header ----
        my $info     = $debug_data->{'.debug_info'};
        my $info_len = length($info);
        ok( $info_len > 12, '.debug_info has header + body' );
        my $unit_len = unpack( 'L<', substr( $info, 0, 4 ) );
        is( $unit_len, $info_len - 4, '.debug_info unit_length == section length - 4' );
        my $version = unpack( 'S<', substr( $info, 4, 2 ) );
        is( $version, 5, '.debug_info version == 5 (DWARF v5)' );
        my $unit_type = unpack( 'C', substr( $info, 6, 1 ) );
        is( $unit_type, 1, '.debug_info unit_type == 1 (DW_UT_compile)' );
        my $addr_size = unpack( 'C', substr( $info, 7, 1 ) );
        is( $addr_size, 8, '.debug_info address_size == 8' );
        my $abbrev_off = unpack( 'L<', substr( $info, 8, 4 ) );
        is( $abbrev_off, 0, '.debug_info debug_abbrev_offset == 0' );

        # ---- Validate .debug_abbrev structure ----
        my $abbrev = $debug_data->{'.debug_abbrev'};
        ok( length($abbrev) > 10, '.debug_abbrev has content' );
        my $pos = 0;
        my %found_abbrevs;
        while ( $pos < length($abbrev) ) {
            my $code = 0;
            my $c;
            my $shift = 0;
            do {
                $c = ord( substr( $abbrev, $pos++, 1 ) );
                $code |= ( $c & 0x7F ) << $shift;
                $shift += 7;
            } while ( $c & 0x80 );
            last if $code == 0;
            my $tag = 0;
            $shift = 0;
            do {
                $c = ord( substr( $abbrev, $pos++, 1 ) );
                $tag |= ( $c & 0x7F ) << $shift;
                $shift += 7;
            } while ( $c & 0x80 );
            my $has_children = ord( substr( $abbrev, $pos++, 1 ) );
            $found_abbrevs{$code} = { tag => $tag, has_children => $has_children, attrs => [] };
            while (1) {
                my $attr_name = 0;
                $shift = 0;
                do {
                    $c = ord( substr( $abbrev, $pos++, 1 ) );
                    $attr_name |= ( $c & 0x7F ) << $shift;
                    $shift += 7;
                } while ( $c & 0x80 );
                my $attr_form = 0;
                $shift = 0;
                do {
                    $c = ord( substr( $abbrev, $pos++, 1 ) );
                    $attr_form |= ( $c & 0x7F ) << $shift;
                    $shift += 7;
                } while ( $c & 0x80 );
                last if $attr_name == 0 && $attr_form == 0;
                push $found_abbrevs{$code}{attrs}->@*, { name => $attr_name, form => $attr_form };
            }
        }
        ok( exists $found_abbrevs{1}, 'Abbrev 1 (DW_TAG_compile_unit) present' );
        ok( exists $found_abbrevs{2}, 'Abbrev 2 (DW_TAG_base_type) present' );
        ok( exists $found_abbrevs{3}, 'Abbrev 3 (DW_TAG_subprogram) present' );
        ok( exists $found_abbrevs{4}, 'Abbrev 4 (DW_TAG_formal_parameter) present' );
        ok( exists $found_abbrevs{5}, 'Abbrev 5 (DW_TAG_variable) present' );

        # Check that subprogram has DW_AT_decl_file
        my $abbrev3   = $found_abbrevs{3};
        my @ab3_names = map { $_->{name} } $abbrev3->{attrs}->@*;
        ok( grep( $_ == 0x38, @ab3_names ), 'Abbrev 3 has DW_AT_decl_file (0x38)' );

        # Check that variable has DW_AT_decl_file
        my $abbrev5   = $found_abbrevs{5};
        my @ab5_names = map { $_->{name} } $abbrev5->{attrs}->@*;
        ok( grep( $_ == 0x38, @ab5_names ), 'Abbrev 5 has DW_AT_decl_file (0x38)' );

        # ---- Validate .debug_line header ----
        my $line = $debug_data->{'.debug_line'};
        ok( length($line) > 20, '.debug_line has content' );
        my $line_unit_len = unpack( 'L<', substr( $line, 0, 4 ) );
        is( $line_unit_len, length($line) - 4, '.debug_line unit_length == section length - 4' );
        my $line_version = unpack( 'S<', substr( $line, 4, 2 ) );
        is( $line_version, 5, '.debug_line version == 5' );

        # ---- Validate presence of DW_AT_decl_file attributes ----
        # Check .debug_abbrev contains DW_AT_decl_file (0x38) attribute names
        my $abbrev_38_count = 0;
        my $pos2            = 0;
        while ( $pos2 < length($abbrev) ) {
            my $idx = index( $abbrev, "\x38", $pos2 );
            last if $idx < 0;
            $abbrev_38_count++;
            $pos2 = $idx + 1;
        }
        cmp_ok( $abbrev_38_count, '>', 0, 'DW_AT_decl_file (0x38) present in .debug_abbrev attributes' );

        # Verify .debug_info contains expected abbrev codes (1=compile_unit, 2=base_type, 3=subprogram, etc.)
        my $info_body = substr( $info, 12 );

        # After the CU abbrev code (1) and its attributes, we expect base type abbrev (2), then subprogram abbrev (3)
        ok( index( $info_body, "\x01" ) >= 0, '.debug_info contains compile_unit DIE (abbrev 1)' );
        ok( index( $info_body, "\x02" ) >= 0, '.debug_info contains base_type DIE (abbrev 2)' );
        ok( index( $info_body, "\x03" ) >= 0, '.debug_info contains subprogram DIE (abbrev 3)' );

        # ---- Scan for source file names in .debug_line ----
        my $line_tail         = substr( $line, 6 );
        my $source_file_count = () = $line_tail =~ /test_dwarf\.brocken\0/g;
        cmp_ok( $source_file_count, '>', 0, '.debug_line contains source file name "test_dwarf.brocken"' );
    }
};
subtest '.eh_frame_hdr structure validation' => sub {
    my $dwarf = Brocken::Jenny::Linker::DWARF->new(
        source_locs   => [ { offset => 0, line => 1 }, { offset => 12, line => 2 }, ],
        text_base     => 0x400000,
        source_file   => 'test_eh.brocken',
        func_ranges   => [ { name => 'main', start => 0, end => 24 }, { name => 'helper', start => 32, end => 64 }, ],
        debug         => 3,
        eh_frame_base => 1,
        arch          => 'x64',
    );
    ok( 1, 'DWARF object created with eh_frame_base set' );
    my $sections = $dwarf->build_all;
    ok( exists $sections->{'.eh_frame_hdr'}, '.eh_frame_hdr present when eh_frame_base is non-zero' );
    ok( exists $sections->{'.eh_frame'},     '.eh_frame present when eh_frame_base is non-zero' );
    my $hdr = $sections->{'.eh_frame_hdr'};
    ok( length($hdr) > 16, '.eh_frame_hdr has size > 16' );
    my ( $ver, $ptr_enc, $cnt_enc, $tbl_enc ) = unpack 'C4', substr( $hdr, 0, 4 );
    is( $ver,     1,    'version == 1' );
    is( $ptr_enc, 0x00, 'eh_frame_ptr_enc == DW_EH_PE_absptr' );
    is( $cnt_enc, 0x03, 'fde_count_enc == DW_EH_PE_udata4' );
    is( $tbl_enc, 0x00, 'table_enc == DW_EH_PE_absptr' );
    my $eh_frame_ptr = unpack 'Q<', substr( $hdr, 4, 8 );
    is( $eh_frame_ptr, 1, 'eh_frame_ptr == eh_frame_base' );
    my $fde_count = unpack 'L<', substr( $hdr, 12, 4 );
    is( $fde_count, 2, 'FDE count == number of func_ranges' );
    my $entry_size     = 16;
    my $total_expected = 16 + $fde_count * $entry_size;
    is( length($hdr), $total_expected, 'total size == header(16) + N*16 entries' );
    my ( $loc0, $fde0 ) = unpack 'Q< Q<', substr( $hdr, 16, $entry_size );
    is( $loc0, 0x400000, 'first entry initial_location == text_base + fn[0].start' );
    cmp_ok( $fde0, '>', 1, 'first entry fde_addr > eh_frame_base' );
    my ( $loc1, $fde1 ) = unpack 'Q< Q<', substr( $hdr, 16 + $entry_size, $entry_size );
    is( $loc1, 0x400020, 'second entry initial_location == text_base + fn[1].start' );
    cmp_ok( $loc0, '<', $loc1, 'entries sorted by initial_location' );
    cmp_ok( $fde0, '<', $fde1, 'FDE offsets in ascending order' );
};
subtest '.eh_frame_hdr absent when eh_frame_base is 0' => sub {
    my $dwarf = Brocken::Jenny::Linker::DWARF->new(
        source_locs   => [ { offset => 0, line => 1 } ],
        text_base     => 0x400000,
        source_file   => 'test_eh.brocken',
        func_ranges   => [ { name => 'main', start => 0, end => 8 } ],
        debug         => 3,
        eh_frame_base => 0,
        arch          => 'x64',
    );
    my $sections = $dwarf->build_all;
    ok( !exists $sections->{'.eh_frame_hdr'}, '.eh_frame_hdr absent when eh_frame_base is 0' );
    ok( !exists $sections->{'.eh_frame'},     '.eh_frame absent when eh_frame_base is 0' );
};
subtest 'Multi-file line program emits DW_LNS_set_file' => sub {
    my $dwarf = Brocken::Jenny::Linker::DWARF->new(
        source_locs => [
            { offset => 0,  line => 1, file => 'a.brocken' },
            { offset => 12, line => 2, file => 'a.brocken' },
            { offset => 24, line => 1, file => 'b.brocken' },
            { offset => 36, line => 2, file => 'b.brocken' },
        ],
        text_base    => 0x400000,
        source_file  => 'a.brocken',
        source_files => [ 'a.brocken', 'b.brocken' ],
        func_ranges  => [
            { name => 'fn_a', start => 0,  end => 20, source_file => 'a.brocken' },
            { name => 'fn_b', start => 24, end => 48, source_file => 'b.brocken' },
        ],
        class_info => {},
        arch       => 'x86_64',
        platform   => 'linux',
        debug      => 5,
    );
    my $sections = $dwarf->build_all;
    ok( exists $sections->{'.debug_line'}, '.debug_line section present with multiple files' );
    my $line_data     = $sections->{'.debug_line'};
    my $prologue_len  = unpack( 'L<', substr( $line_data, 8, 4 ) );    # offset 8 = unit_length(4) + version(2) + addr_size(1) + seg_sel_size(1)
    my $program_start = 12 + $prologue_len;                            # 12 = offset after prologue_length field
    my $program       = substr( $line_data, $program_start );
    my @set_file_ops;
    my $pos = 0;

    while ( $pos < length($program) ) {
        my $byte = ord( substr( $program, $pos, 1 ) );
        last if $byte == 0x00 && $pos + 1 < length($program) && ord( substr( $program, $pos + 1, 1 ) ) == 1;
        if ( $byte == 0x00 ) {
            last if $pos + 10 > length($program);
            $pos += 1 + 1 + 9;    # extended op: len(1) + opcode(1) + addr(8)
        }
        elsif ( $byte == 0x04 ) {
            push @set_file_ops, $pos;
            $pos += 2;            # opcode(1) + index(1, small)
        }
        elsif ( $byte == 0x03 ) {
            $pos += 1;
            while ( $pos < length($program) && ( ord( substr( $program, $pos, 1 ) ) & 0x80 ) ) { $pos++ }
            $pos++;
        }
        elsif ( $byte == 0x01 ) { $pos++ }
        elsif ( $byte == 0x02 ) { $pos += 1 + 1 + 9 }
        else                    { $pos++ }
    }
    cmp_ok( scalar @set_file_ops, '>=', 2, 'At least two DW_LNS_set_file ops: a.brocken(1) and b.brocken(2)' );
    my $fidx1 = ord( substr( $program, $set_file_ops[0] + 1, 1 ) );
    my $fidx2 = ord( substr( $program, $set_file_ops[1] + 1, 1 ) );
    is( $fidx1, 1, 'First set_file = file index 1 (a.brocken)' );
    is( $fidx2, 2, 'Second set_file = file index 2 (b.brocken)' );
};
done_testing;
