use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Jenny::Linker;

class Brocken::Jenny::Linker::DWARF : isa(Brocken::Jenny::Linker) {

=pod

=head1 NAME

Brocken::Jenny::Linker::DWARF - Debug Information Generator

=head1 DESCRIPTION

Generates DWARF v5 compliant debug sections.

=head2 Sections Generated:

=over 4

=item * B<.debug_line>: Maps machine code offsets to source lines.

=item * B<.debug_info>: The main Debug Information Entry (DIE) tree.

=item * B<.debug_abbrev>: Definitions of DIE abbreviations.

=item * B<.debug_frame>: Stack unwinding and frame pointer recovery data.

=item * B<.debug_aranges>: Rapid lookup table for address ranges.

=item * B<.debug_names>: Fast, hashed symbol lookup table (new in DWARF 5).

=item * B<.debug_str>: String table for DWARF 5 symbol references.

=item * B<.eh_frame>: Exception handling frame data (LSDA compatible).

=back

=cut

    field $source_locs    : param : reader;
    field $text_base      : param : reader;
    field $source_file    : param : reader //= 'source.brocken';
    field $func_ranges    : param : reader = [];
    field $context_size   : param : reader = 64;
    field $class_info     : param : reader = {};
    field $debug          : param : reader = 0;
    field $eh_frame_base  : param : reader = 0;
    field $arch           : param : reader = 'x64';
    field $preserved_regs : param : reader = [];
    field $platform       : param : reader = undef;    # Optional target Platform
    field @pubnames;

    # Unified DWARF register number resolver delegating to Katsuro::Platform::ABI
    method dwarf_reg_num($name) {
        if ( defined $platform ) {
            return $platform->abi->dwarf_reg_num($name);
        }

        # Fallback for older constructor calls: dynamically parse the platform from $arch
        my $parsed_platform = Brocken::Katsuro::Platform::parse($arch);
        return $parsed_platform->abi->dwarf_reg_num($name);
    }

    method build_all () {
        my $info = $self->build_debug_info;
        my ( $names, $str ) = $self->build_debug_names;
        my $sections = { '.debug_line' => $self->build_debug_line, '.debug_info' => $info, '.debug_abbrev' => $self->build_debug_abbrev, };
        if ($names) {
            $sections->{'.debug_names'} = $names;
            $sections->{'.debug_str'}   = $str;
        }
        if (@$func_ranges) {
            $sections->{'.debug_frame'}   = $self->build_debug_frame;
            $sections->{'.debug_aranges'} = $self->build_debug_aranges;
            $sections->{'.eh_frame'}      = $self->build_eh_frame if $self->eh_frame_base;
        }
        return $sections;
    }

    # Generates the line number program.
    # Uses standard DWARF opcodes:
    # - 0x02: Set Address (Extended)
    # - 0x03: Advance Line (Signed)
    # - 0x01: Copy (Append row to matrix)
    method build_debug_line () {
        my @entries   = sort { $a->{offset} <=> $b->{offset} } @$source_locs;
        my $program   = '';
        my $prev_line = 1;
        my $prev_addr = $text_base;
        for my $e (@entries) {
            my $addr = $text_base + $e->{offset};
            my $line = $e->{line};

            # Set Address (Opcode 0x02)
            $program .= "\x00" . $self->_uleb(9) . "\x02" . pack( 'Q<', $addr );

            # Advance Line (Opcode 0x03)
            $program .= "\x03" . $self->_sleb( $line - $prev_line );

            # Copy row (Opcode 0x01)
            $program .= "\x01";
            $prev_line = $line;
        }

        # End of sequence
        my $max_offset = 0;
        for my $fn (@$func_ranges) { $max_offset = $fn->{end} if ( $fn->{end} // 0 ) > $max_offset; }
        $program .= "\x00" . $self->_uleb(9) . "\x02" . pack( 'Q<', $text_base + $max_offset );
        $program .= "\x00" . $self->_uleb(1) . "\x01";

        # DWARF 5 Line Number Program Header
        my $header   = pack( 'C', 8 ) . pack( 'C', 0 );    # address_size=8, segment_selector_size=0
        my $prologue = pack( 'C', 1 ) . pack( 'C', 1 ) . pack( 'C', 1 ) . pack( 'c', -5 ) . pack( 'C', 14 ) . pack( 'C', 13 );
        $prologue .= pack( 'C*', 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1 );

        # Directory entry format count = 1 (DW_LNCT_path = 1, DW_FORM_string = 0x08)
        $prologue .= pack( 'C', 1 ) . $self->_uleb(1) . $self->_uleb(0x08);
        $prologue .= $self->_uleb(1) . ".\0";                                 # 1 directory: "."

        # File entry format count = 2 (DW_LNCT_path=1/string, DW_LNCT_directory_index=2/udata)
        $prologue .= pack( 'C', 2 );
        $prologue .= $self->_uleb(1) . $self->_uleb(0x08);
        $prologue .= $self->_uleb(2) . $self->_uleb(0x0F);
        $prologue .= $self->_uleb(1) . "$source_file\0" . pack( 'C', 0 );
        $prologue = pack( 'L<', length($prologue) ) . $prologue;
        my $total_len = length($header) + length($prologue) + length($program);
        return pack( 'L<', $total_len + 2 ) . pack( 'S<', 5 ) . $header . $prologue . $program;    # Version 5
    }

    # Defines abbreviations used in .debug_info to reduce redundant tags.
    method build_debug_abbrev () {
        my $abbrev = '';

        # Abbrev 1: DW_TAG_compile_unit (0x11)
        $abbrev .= $self->_uleb(1) . $self->_uleb(0x11) . $self->_uleb(1);
        $abbrev .= $self->_uleb(0x10) . $self->_uleb(0x17);                                        # DW_AT_stmt_list -> sec_offset
        $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                                        # DW_AT_name -> string
        $abbrev .= $self->_uleb(0x13) . $self->_uleb(0x0B);                                        # DW_AT_language -> data1
        $abbrev .= $self->_uleb(0x11) . $self->_uleb(0x01);                                        # DW_AT_low_pc -> addr
        $abbrev .= $self->_uleb(0x12) . $self->_uleb(0x01);                                        # DW_AT_high_pc -> addr
        $abbrev .= pack( 'CC', 0, 0 );

        # Abbrev 2: DW_TAG_base_type (0x24)
        $abbrev .= $self->_uleb(2) . $self->_uleb(0x24) . $self->_uleb(0);
        $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                                        # DW_AT_name -> string
        $abbrev .= $self->_uleb(0x0B) . $self->_uleb(0x0B);                                        # DW_AT_byte_size -> data1
        $abbrev .= $self->_uleb(0x3E) . $self->_uleb(0x0B);                                        # DW_AT_encoding -> data1
        $abbrev .= pack( 'CC', 0, 0 );

        # Abbrev 3: DW_TAG_subprogram (0x2E)
        $abbrev .= $self->_uleb(3) . $self->_uleb(0x2E) . $self->_uleb(1);                         # has_children = 1
        $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                                        # DW_AT_name
        $abbrev .= $self->_uleb(0x11) . $self->_uleb(0x01);                                        # low_pc
        $abbrev .= $self->_uleb(0x12) . $self->_uleb(0x01);                                        # high_pc
        $abbrev .= $self->_uleb(0x40) . $self->_uleb(0x18);                                        # DW_AT_frame_base -> exprloc
        $abbrev .= pack( 'CC', 0, 0 );

        # Abbrev 4: DW_TAG_formal_parameter (0x05) / Abbrev 5: DW_TAG_variable (0x34)
        for ( 4 .. 5 ) {
            $abbrev .= $self->_uleb($_) . $self->_uleb( $_ == 4 ? 0x05 : 0x34 ) . $self->_uleb(0);
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                                      # name -> string
            $abbrev .= $self->_uleb(0x02) . $self->_uleb(0x18);                                      # location -> exprloc
            $abbrev .= $self->_uleb(0x49) . $self->_uleb(0x13);                                      # type -> ref4
            $abbrev .= pack( 'CC', 0, 0 );
        }
        $abbrev .= "\x00";
        return $abbrev;
    }

    method build_debug_info () {
        my $max_pc = 0;
        for my $fn (@$func_ranges) { $max_pc = $fn->{end} if ( $fn->{end} // 0 ) > $max_pc; }
        my $cu_body = '';
        $cu_body
            .= $self->_uleb(1) . pack( 'L<', 0 ) . "$source_file\0" . pack( 'C', 12 ) . pack( 'Q<', $text_base ) . pack( 'Q<', $text_base + $max_pc );
        my $CU_HEADER_SIZE = 12;
        my $type_off       = {};
        for my $t ( [ 'Int', 5 ], [ 'Bool', 2 ], [ 'String', 1 ], [ 'Any', 1 ], [ 'ptr', 1 ], [ 'Array', 1 ] ) {
            $type_off->{ $t->[0] } = $CU_HEADER_SIZE + length($cu_body);
            $cu_body .= $self->_uleb(2) . "$t->[0]\0" . pack( 'CC', 8, $t->[1] );
        }
        for my $fn ( sort { $a->{start} <=> $b->{start} } @$func_ranges ) {
            my $die_off = $CU_HEADER_SIZE + length($cu_body);
            push @pubnames, { offset => $die_off, name => ( $fn->{name} =~ s/^M_//r ) };
            $cu_body .= $self->_uleb(3);
            $cu_body .= "$fn->{name}\0";
            $cu_body .= pack( 'Q<', $text_base + $fn->{start} );
            $cu_body .= pack( 'Q<', $text_base + ( $fn->{end} // $fn->{start} ) );

            # frame_base (DW_AT_frame_base: RBP on x64, X29 on ARM64, S0/FP on RISCV64)
            my $fb = pack( 'C', 0x70 + ( $arch =~ /aarch64|arm64/i ? 29 : ( $arch =~ /riscv/i ? 8 : 6 ) ) ) . "\x00";
            $cu_body .= $self->_uleb( length($fb) ) . $fb;

            # Parameter and Local Variable DIEs
            for my $v ( @{ $fn->{params} // [] }, @{ $fn->{locals} // [] } ) {
                $cu_body .= $self->_uleb( exists $v->{slot} ? 5 : 4 );
                ( my $n = $v->{name} ) =~ s/^\$//;
                $cu_body .= "$n\0";

                # Variable Location (DW_OP_fbreg + sleb128 offset)
                my $loc = "\x91" . $self->_sleb( -$v->{slot} );
                $cu_body .= $self->_uleb( length($loc) ) . $loc;
                $cu_body .= pack( 'L<', $type_off->{ $v->{type} } // $type_off->{Any} );
            }
            $cu_body .= "\x00";    # end subprogram
        }
        $cu_body .= "\x00";

        # DWARF 5 Info Header: length(4), version=5(2), unit_type=1(1), addr_size=8(1), abbrev_offset=0(4)
        return pack( 'L< S< C C L<', length($cu_body) + 8, 5, 1, 8, 0 ) . $cu_body;
    }

    # DWARF v5 Case-Folding DJB Hash Function
    method _djb_hash($name) {
        my $hash = 5381;
        for my $char ( split //, lc($name) ) {
            my $code = ord($char);
            $hash = ( ( $hash << 5 ) + $hash ) + $code;
            $hash &= 0xFFFFFFFF;    # Clamp to 32-bit unsigned
        }
        return $hash;
    }

    method build_debug_names() {
        return () unless @pubnames;

        # 1. Build dedicated .debug_str table
        my $debug_str = "\x00";
        my %str_offsets;
        for my $pn (@pubnames) {
            next if exists $str_offsets{ $pn->{name} };
            $str_offsets{ $pn->{name} } = length($debug_str);
            $debug_str .= $pn->{name} . "\x00";
        }
        while ( length($debug_str) % 4 != 0 ) { $debug_str .= "\x00"; }

        # 2. Hash and sort name targets
        my @sorted;
        my $bucket_count = scalar @pubnames;
        for my $pn (@pubnames) {
            my $name   = $pn->{name};
            my $hash   = $self->_djb_hash($name);
            my $bucket = $hash % $bucket_count;
            push @sorted, { name => $name, offset => $pn->{offset}, hash => $hash, bucket => $bucket, };
        }
        @sorted = sort { $a->{bucket} <=> $b->{bucket} || $a->{name} cmp $b->{name} } @sorted;

        # 3. Build Bucket and Hash Tables
        my @buckets    = (0) x $bucket_count;
        my $hashes_bin = "";
        for my $i ( 0 .. $#sorted ) {
            my $s = $sorted[$i];
            if ( $buckets[ $s->{bucket} ] == 0 ) {
                $buckets[ $s->{bucket} ] = $i + 1;    # 1-based index
            }
            $hashes_bin .= pack( 'V', $s->{hash} );
        }
        my $buckets_bin = pack( 'V*', @buckets );

        # 4. Build Abbreviation Table
        my $abbrev_data = "";
        $abbrev_data .= $self->_uleb(1);       # abbrev code
        $abbrev_data .= $self->_uleb(0x2E);    # DW_TAG_subprogram
        $abbrev_data .= $self->_uleb(1);       # DW_IDX_compile_unit
        $abbrev_data .= $self->_uleb(0x0B);    # DW_FORM_data1 (1-byte index)
        $abbrev_data .= $self->_uleb(3);       # DW_IDX_die_offset
        $abbrev_data .= $self->_uleb(0x13);    # DW_FORM_ref4 (4-byte offset into .debug_info)
        $abbrev_data .= pack( 'CC', 0, 0 );    # terminate attributes
        $abbrev_data .= "\x00";                # terminate abbrevs

        # 5. Build Entry Pool and collect offsets
        my $entry_pool = "";
        my @entry_offsets;
        for my $s (@sorted) {
            push @entry_offsets, length($entry_pool);
            $entry_pool .= pack( 'C C L< C', 1, 0, $s->{offset}, 0 );    # [code=1, cu=0, offset, terminator=0]
        }

        # 6. Build Name Table
        my $string_offsets_bin = "";
        my $entry_offsets_bin  = "";
        for my $i ( 0 .. $#sorted ) {
            my $s = $sorted[$i];
            $string_offsets_bin .= pack( 'V', $str_offsets{ $s->{name} } );
            $entry_offsets_bin  .= pack( 'V', $entry_offsets[$i] );
        }

        # 7. Compilation Unit List
        my $cu_list_bin = pack( 'V', 0 );    # 1 CU at offset 0

        # 8. Assemble Header & Body
        my $aug_str      = "BRK\x00";
        my $header_fixed = pack( 'S< S< V4', 5, 0, 1, 0, 0, $bucket_count );
        my $header_var   = pack( 'V3', scalar(@sorted), length($abbrev_data), length($aug_str) ) . $aug_str;
        my $body         = $cu_list_bin . $buckets_bin . $hashes_bin . $string_offsets_bin . $entry_offsets_bin . $abbrev_data . $entry_pool;
        my $total_len    = length($header_fixed) + length($header_var) + length($body);
        return ( pack( 'L<', $total_len ) . $header_fixed . $header_var . $body, $debug_str );
    }

    method build_debug_aranges () {
        my $max_pc = 0;
        for my $fn (@$func_ranges) { $max_pc = $fn->{end} if ( $fn->{end} // 0 ) > $max_pc; }
        my $body = pack( 'Q< Q<', $text_base, $max_pc );
        $body .= pack( 'Q< Q<', 0, 0 );
        my $header = pack( 'S< L< C C', 2, 0, 8, 0 );

        # Padding to 16-byte boundary
        my $pad = ( 16 - ( ( length($header) + 4 ) % 16 ) ) % 16;
        return pack( 'L<', length($header) + $pad + length($body) ) . $header . ( "\0" x $pad ) . $body;
    }

    method build_debug_pubnames ( $info_len = 0 ) {
        my $body = '';
        for my $pn (@pubnames) { $body .= pack( 'L<', $pn->{offset} ) . "$pn->{name}\0"; }
        $body .= pack( 'L<', 0 );
        return pack( 'L< S< L< L<', length($body) + 10, 2, 0, $info_len ) . $body;
    }

    # Unsigned LEB128 encoding (Variable length integer)
    method _uleb ($v) {
        my $out = '';
        do {
            my $byte = $v & 0x7F;
            $v >>= 7;
            $byte |= 0x80 if $v;
            $out .= pack( 'C', $byte );
        } while ($v);
        return $out;
    }

    # Signed LEB128 encoding
    method _sleb ($v) {
        require POSIX;
        my $out = '';
        while (1) {
            my $byte = $v & 0x7f;
            $v = POSIX::floor( $v / 128 );
            if ( ( $v == 0 && !( $byte & 0x40 ) ) || ( $v == -1 && ( $byte & 0x40 ) ) ) {
                $out .= pack( 'C', $byte );
                last;
            }
            $out .= pack( 'C', $byte | 0x80 );
        }
        return $out;
    }

    # Call Frame Information (CFI) for stack unwinding.
    method build_debug_frame () {

        # Basic CIE (Common Information Entry)
        # - code_alignment_factor: 1
        # - data_alignment_factor: -8
        # - return_address_register: 16 (x64), 30 (ARM64), or 1 (RISC-V ra)
        my $cie_ra   = $arch =~ /aarch64|arm64/i ? 30 : ( $arch eq 'riscv64' ? 1 : 16 );
        my $cie_cfa  = $arch =~ /aarch64|arm64/i ? 31 : ( $arch eq 'riscv64' ? 2 : 7 );
        my $cie_fp   = $arch =~ /aarch64|arm64/i ? 29 : ( $arch eq 'riscv64' ? 8 : 6 );
        my $cie_body = pack( 'C', 3 ) . "\0" . $self->_uleb(1) . $self->_sleb(-8);
        $cie_body .= pack( 'C', $cie_ra );

        # Initial instructions: DW_CFA_def_cfa (0x0C) SP+8
        $cie_body .= "\x0C" . $self->_uleb($cie_cfa) . $self->_uleb(8);

        # Tell DWARF where the return address is saved (offset 1 * -8 from CFA)
        # DW_CFA_offset (0x80 | reg)
        if ( $arch eq 'x64' || $arch eq 'riscv64' ) {
            $cie_body .= pack( 'C', 0x80 | $cie_ra ) . $self->_uleb(1);
        }
        my $cie_pad = ( 8 - ( ( length($cie_body) + 8 ) % 8 ) ) % 8;
        $cie_body .= "\0" x $cie_pad;
        my $data = pack( 'L<', length($cie_body) + 4 ) . pack( 'L<', 0xFFFFFFFF ) . $cie_body;

        # FDE (Frame Description Entry) per function
        for my $fn (@$func_ranges) {

            # DW_CFA_def_cfa FP, offset (context_size + 8)
            my $instr           = "\x0C" . $self->_uleb($cie_fp) . $self->_uleb( $context_size + 8 );
            my $offset_from_cfa = -16;

            # Register preservation mapping
            for my $r (@$preserved_regs) {
                my $reg_num      = $self->dwarf_reg_num($r) // 0;
                my $factored_off = $offset_from_cfa / -8;
                $instr .= pack( 'C', 0x80 | $reg_num ) . $self->_uleb($factored_off);
                $offset_from_cfa -= 8;
            }
            my $fde_body = pack( 'Q< Q<', $text_base + $fn->{start}, $fn->{end} - $fn->{start} ) . $instr;
            my $fde_pad  = ( 8 - ( ( length($fde_body) + 8 ) % 8 ) ) % 8;
            $fde_body .= "\0" x $fde_pad;
            $data     .= pack( 'L<', length($fde_body) + 4 ) . pack( 'L<', 0 ) . $fde_body;
        }
        return $data;
    }

    # Exception Handling frame (LSDA compatible).
    # Similar to .debug_frame but used at runtime for stack walking.
    method build_eh_frame () {
        return '' unless $eh_frame_base;
        my $reg = $arch =~ /aarch64|arm64/i ? 30 : ( $arch eq 'riscv64' ? 1 : 16 );
        my $cfa = $arch =~ /aarch64|arm64/i ? 31 : ( $arch eq 'riscv64' ? 2 : 7 );
        my $fpr = $arch =~ /aarch64|arm64/i ? 29 : ( $arch eq 'riscv64' ? 8 : 6 );

        # CIE with 'zR' augmentation for pcrel FDE encoding
        my $cie_body = pack( 'C', 1 ) . "zR\0" . $self->_uleb(1) . $self->_sleb(-8);
        $cie_body .= pack( 'C', $reg );

        # Augmentation data length + FDE encoding (pcrel|sdata4 = 0x1B)
        $cie_body .= $self->_uleb(1) . "\x1B";

        # Initial instructions: def_cfa SP+8, offset ra at cfa-8
        $cie_body .= "\x0C" . $self->_uleb($cfa) . $self->_uleb(8);
        $cie_body .= pack( 'C', 0x80 | $reg ) . $self->_uleb(1);
        my $cie_pad = ( 4 - ( ( length($cie_body) + 4 ) % 4 ) ) % 4;
        $cie_body .= "\0" x $cie_pad;
        my $data = pack( 'L<', length($cie_body) + 4 ) . pack( 'L<', 0 ) . $cie_body;
        for my $fn (@$func_ranges) {
            my $fn_start = $fn->{start};
            my $fn_len   = ( $fn->{end} // $fn->{start} + 1 ) - $fn->{start};
            my $instr    = "\x0C" . $self->_uleb($fpr) . $self->_uleb( $context_size + 8 );
            for my $r (@$preserved_regs) {
                my $reg_num      = $self->dwarf_reg_num($r) // 0;
                my $factored_off = -16 / -8;
                $instr .= pack( 'C', 0x80 | $reg_num ) . $self->_uleb($factored_off);
            }

            # pcrel initial_location: the file-relative offset to fn_start
            my $fde_body = pack( 'L<', $fn_start ) . pack( 'L<', $fn_len ) . $instr;
            my $fde_pad  = ( 4 - ( ( length($fde_body) + 4 ) % 4 ) ) % 4;
            $fde_body .= "\0" x $fde_pad;

            # CIE_pointer = offset of CIE_pointer_field - CIE_offset
            my $fde_offset = length($data);
            $data .= pack( 'L<', length($fde_body) + 4 ) . pack( 'L<', $fde_offset + 4 ) . $fde_body;
        }
        return $data;
    }
};
1;
