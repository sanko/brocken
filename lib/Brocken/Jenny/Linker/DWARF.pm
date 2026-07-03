use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Jenny::Linker;

class Brocken::Jenny::Linker::DWARF : isa(Brocken::Jenny::Linker) {

=pod

=head1 NAME

Brocken::Jenny::Linker::DWARF - Debug Information Generator

=head1 DESCRIPTION

Generates DWARF v5 compliant debug sections for source-level debugging with
GDB (ELF) and integrated debuggers (PE). Accepts source-location entries
(machine code offset to source line/col), function ranges, and variable/struct
type metadata via C<class_info>.

=head2 Sections Generated:

=over 4

=item * B<.debug_line>: Maps machine code offsets to source lines. Uses DWARF
v5 line number program header with file entries and address/line opcodes.

=item * B<.debug_info>: The main Debug Information Entry (DIE) tree. Includes
compile unit, base types (Int, Bool, String, Any, ptr, Array), subprogram DIEs
for each function, variable/parameter DIEs (with decl_line/decl_column/
artificial attributes), and structure-type DIEs for user-defined classes.

=item * B<.debug_abbrev>: Definitions of DIE abbreviations. Abbrev codes: 1
(compile_unit), 2 (base_type), 3 (subprogram), 4 (formal_parameter), 5
(variable), 6 (structure_type), 7 (member).

=item * B<.debug_frame>: Stack unwinding and frame pointer recovery data. Uses
platform-specific CFA (x64/RSP, ARM64/SP, RISCV64/SP) and frame-pointer
registers (x64/RBP, ARM64/X29, RISCV64/S0).

=item * B<.debug_aranges>: Rapid lookup table mapping text-section address
ranges to compile units.

=item * B<.debug_names>: Fast, hashed symbol lookup table (DWARF v5). Uses
case-folding DJB hash. Generated when function pubnames are non-empty.

=item * B<.debug_str>: Dedicated string table referenced by .debug_names.

=item * B<.eh_frame>: Exception handling frame data (LSDA compatible). Uses
'zR' augmentation with pcrel FDE encoding. Only generated when
C<eh_frame_base> is non-zero.

=back

=head1 FIELDS

=over

=item C<source_locs>

ArrayRef of hashrefs: C<{ offset, line }>. Machine code byte offsets relative
to C<text_base> mapped to source line numbers. Used by C<build_debug_line>.

=item C<text_base>

Base address (file offset) of the .text section in the output binary.

=item C<source_file>, C<source_files>

Primary source filename (string) or list of filenames (arrayref). Referenced
by DW_AT_name and directory/file entries in .debug_line.

=item C<func_ranges>

ArrayRef of hashrefs: C<{ name, start, end, source_file, params, locals }>.
Each entry becomes a DW_TAG_subprogram DIE with child variable/parameter DIEs.

=item C<class_info>

Hashref from class name to C<{ fields, total_size }>. Used to emit
DW_TAG_structure_type and DW_TAG_member DIEs (only at debug level >= 4).

=item C<debug>

Debug level (0-5). Controls which DWARF sections are built:

    0  No sections
    1  .debug_line only
    2  + .debug_info, .debug_abbrev
    3  + .debug_frame, .debug_aranges
    4  + .debug_names, .debug_str
    5  (same as 4)

=item C<arch>

Target architecture string: C<x64>, C<aarch64>, C<arm64>, or C<riscv64>.
Determines DWARF register numbers, frame pointer, and return address.

=item C<preserved_regs>

List of register names preserved across calls. Used by C<build_debug_frame>
to emit DW_CFA_offset instructions.

=item C<platform>

Optional L<Brocken::Katsuro::Platform> instance. If defined, used for DWARF
register number resolution via C<< platform->abi->dwarf_reg_num >>.

=back

=head1 METHODS

=head2 build_all

Produces all requested debug sections as a hashref keyed by section name
(e.g. C<{ '.debug_line' => ..., '.debug_info' => ... }>). Conditionally
includes C<.debug_names>/.debug_str, C<.debug_frame>/.debug_aranges,
and C<.eh_frame> when their data sources are non-empty.

=head2 build_debug_line

Builds the .debug_line section using DWARF v5 header format. For each
source-location entry, emits Set Address (0x02) + Advance Line (0x03) + Copy
(0x01) opcodes. Ends the sequence with a terminating entry.

=head2 build_debug_abbrev

Builds the .debug_abbrev section defining DIE abbreviations used by
.debug_info. Abbrev 4 (formal_parameter) and 5 (variable) include
DW_AT_decl_line, DW_AT_decl_column, and DW_AT_artificial attributes.

=head2 build_debug_info

Builds the .debug_info section: a DWARF v5 compile unit header followed by
base-type DIEs, structure-type DIEs (from class_info), and subprogram DIEs
with variable/parameter child DIEs. Each variable DIE carries source
coordinates and artificial flag.

=head2 build_debug_names

Builds the .debug_names accelerated-lookup section (DWARF v5). Returns
C<($names_data, $str_data)> or empty list if no pubnames exist. Uses
case-folding DJB hashing for case-insensitive lookups.

=head2 build_debug_aranges

Builds a minimal .debug_aranges table covering the full text section range.

=head2 build_debug_frame

Builds .debug_frame: CIE (Common Information Entry) defining CFA rules for
the target ABI, followed by one FDE (Frame Description Entry) per function
with register preservation and frame-pointer setup instructions.

=head2 build_eh_frame

Builds .eh_frame for exception handling. Uses 'zR' augmentation with pcrel
absolute-address FDE encoding. Only emitted when C<eh_frame_base> is non-zero.

=back

=cut

    field $source_locs    : param : reader;
    field $text_base      : param : reader;
    field $source_file    : param : reader //= 'source.brocken';
    field $source_files   : param : reader = undef;
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
        @$func_ranges    = @$func_ranges[ 0 .. 999 ]   if @$func_ranges > 1000;
        @$preserved_regs = @$preserved_regs[ 0 .. 63 ] if @$preserved_regs > 64;
        my $sections = {};
        if ( $self->debug >= 1 ) {
            $sections->{'.debug_line'} = $self->build_debug_line;
        }
        if ( $self->debug >= 2 ) {
            $sections->{'.debug_info'}   = $self->build_debug_info;
            $sections->{'.debug_abbrev'} = $self->build_debug_abbrev;
        }
        if ( $self->debug >= 3 && @$func_ranges ) {
            $sections->{'.debug_frame'}   = $self->build_debug_frame;
            $sections->{'.debug_aranges'} = $self->build_debug_aranges;
            if ( $self->eh_frame_base ) {
                my ( $eh_frame, $fde_offsets ) = $self->build_eh_frame;
                $sections->{'.eh_frame'}      = $eh_frame;
                $sections->{'.eh_frame_hdr'}  = $self->build_eh_frame_hdr($fde_offsets);
            }
        }
        if ( $self->debug >= 4 ) {
            my ( $names, $str ) = $self->build_debug_names;
            if ($names) {
                $sections->{'.debug_names'} = $names;
                $sections->{'.debug_str'}   = $str;
            }
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
        $prologue .= $self->_uleb(1) . ".\0";

        # File entry format count = 2 (DW_LNCT_path=1/string, DW_LNCT_directory_index=2/udata)
        my $sf = $self->source_files // [$source_file];
        $prologue .= pack( 'C', 2 );
        $prologue .= $self->_uleb(1) . $self->_uleb(0x08);
        $prologue .= $self->_uleb(2) . $self->_uleb(0x0F);
        $prologue .= $self->_uleb( scalar @$sf );
        for my $f (@$sf) {
            $prologue .= "$f\0" . pack( 'C', 0 );
        }
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
        $abbrev .= $self->_uleb(0x25) . $self->_uleb(0x08);                                        # DW_AT_producer -> string
        $abbrev .= $self->_uleb(0x1B) . $self->_uleb(0x08);                                        # DW_AT_comp_dir -> string
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
        $abbrev .= $self->_uleb(0x38) . $self->_uleb(0x0B);                                        # DW_AT_decl_file -> data1
        $abbrev .= $self->_uleb(0x6E) . $self->_uleb(0x08);                                        # DW_AT_linkage_name -> string
        $abbrev .= pack( 'CC', 0, 0 );

        # Abbrev 4: DW_TAG_formal_parameter (0x05) / Abbrev 5: DW_TAG_variable (0x34)
        for ( 4 .. 5 ) {
            $abbrev .= $self->_uleb($_) . $self->_uleb( $_ == 4 ? 0x05 : 0x34 ) . $self->_uleb(0);
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                                      # name -> string
            $abbrev .= $self->_uleb(0x02) . $self->_uleb(0x18);                                      # location -> exprloc
            $abbrev .= $self->_uleb(0x49) . $self->_uleb(0x13);                                      # type -> ref4
            $abbrev .= $self->_uleb(0x38) . $self->_uleb(0x0B);                                      # DW_AT_decl_file -> data1
            $abbrev .= $self->_uleb(0x39) . $self->_uleb(0x05);                                      # DW_AT_decl_line -> data2
            $abbrev .= $self->_uleb(0x3D) . $self->_uleb(0x0B);                                      # DW_AT_decl_column -> data1
            $abbrev .= $self->_uleb(0x34) . $self->_uleb(0x0B);                                      # DW_AT_artificial -> data1
            $abbrev .= pack( 'CC', 0, 0 );
        }
        # Abbrev 6: DW_TAG_structure_type (0x13) with children
        $abbrev .= $self->_uleb(6) . $self->_uleb(0x13) . $self->_uleb(1);
        $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                                        # DW_AT_name -> string
        $abbrev .= $self->_uleb(0x0B) . $self->_uleb(0x0B);                                        # DW_AT_byte_size -> data1
        $abbrev .= pack( 'CC', 0, 0 );

        # Abbrev 7: DW_TAG_member (0x0D) no children
        $abbrev .= $self->_uleb(7) . $self->_uleb(0x0D) . $self->_uleb(0);
        $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                                        # DW_AT_name -> string
        $abbrev .= $self->_uleb(0x49) . $self->_uleb(0x13);                                        # DW_AT_type -> ref4
        $abbrev .= $self->_uleb(0x38) . $self->_uleb(0x0B);                                        # DW_AT_data_member_location -> data1
        $abbrev .= pack( 'CC', 0, 0 );
        $abbrev .= "\x00";
        return $abbrev;
    }

    method build_debug_info () {
        my $max_pc = 0;
        for my $fn (@$func_ranges) { $max_pc = $fn->{end} if ( $fn->{end} // 0 ) > $max_pc; }
        my $cu_body = '';
        $cu_body
            .= $self->_uleb(1) . pack( 'L<', 0 ) . "$source_file\0" . pack( 'C', 2 ) . pack( 'Q<', $text_base ) . pack( 'Q<', $text_base + $max_pc );
        $cu_body .= "Brocken v0.1\0";                                                                          # DW_AT_producer
        $cu_body .= ".\0";                                                                                      # DW_AT_comp_dir
        my $CU_HEADER_SIZE = 12;
        my $type_off       = {};
        for my $t ( [ 'Int', 5 ], [ 'Bool', 2 ], [ 'String', 1 ], [ 'Any', 1 ], [ 'ptr', 1 ], [ 'Array', 1 ] ) {
            $type_off->{ $t->[0] } = $CU_HEADER_SIZE + length($cu_body);
            $cu_body .= $self->_uleb(2) . "$t->[0]\0" . pack( 'CC', 8, $t->[1] );
        }

        # Emit DW_TAG_structure_type DIEs for each class in class_info (level >= 4)
        if ( $self->debug >= 4 ) {
            for my $cn ( sort keys %$class_info ) {
            my $cd = $class_info->{$cn};
            next unless ref $cd eq 'HASH' && exists $cd->{fields};
            $type_off->{$cn} = $CU_HEADER_SIZE + length($cu_body);
            $cu_body .= $self->_uleb(6);                                 # abbrev 6: structure_type
            $cu_body .= "$cn\0";
            $cu_body .= pack( 'C', $cd->{total_size} // 8 );             # DW_AT_byte_size
            for my $fd ( $cd->{fields}->@* ) {
                my $ftype = $type_off->{ $fd->{type} } // $type_off->{Any};
                $cu_body .= $self->_uleb(7);                             # abbrev 7: member
                $cu_body .= "$fd->{name}\0";
                $cu_body .= pack( 'L<', $ftype );                        # DW_AT_type -> ref4
                $cu_body .= pack( 'C', $fd->{offset} // 0 );             # DW_AT_data_member_location
            }
                $cu_body .= "\x00";                                           # end children
            }
        }

        my $sf = $self->source_files // [$source_file];
        my %file_idx = map { $sf->[$_] => $_ + 1 } 0 .. $#$sf;

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

            # DW_AT_decl_file
            my $f_idx = $file_idx{ $fn->{source_file} // $source_file } // 1;
            $cu_body .= pack( 'C', $f_idx );

            # DW_AT_linkage_name
            $cu_body .= "$fn->{name}\0";

            # Parameter and Local Variable DIEs
            for my $v ( @{ $fn->{params} // [] }, @{ $fn->{locals} // [] } ) {
                $cu_body .= $self->_uleb( exists $v->{slot} ? 5 : 4 );
                ( my $n = $v->{name} ) =~ s/^\$//;
                $cu_body .= "$n\0";

                # Variable Location (DW_OP_fbreg + sleb128 offset)
                my $loc = "\x91" . $self->_sleb( -$v->{slot} );
                $cu_body .= $self->_uleb( length($loc) ) . $loc;
                $cu_body .= pack( 'L<', $type_off->{ $v->{type} } // $type_off->{Any} );
                $cu_body .= pack( 'C', $f_idx );    # DW_AT_decl_file
                $cu_body .= pack( 'S<', $v->{line} // 0 );    # DW_AT_decl_line
                $cu_body .= pack( 'C', $v->{col} // 0 );      # DW_AT_decl_column
                $cu_body .= pack( 'C', $v->{artificial} // 0 ); # DW_AT_artificial
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
    # Returns ($data, \@fde_offsets) where fde_offsets are byte offsets within .eh_frame.
    method build_eh_frame () {
        return ( '', [] ) unless $eh_frame_base;
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
        my @fde_offsets;
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
            push @fde_offsets, $fde_offset;
            $data .= pack( 'L<', length($fde_body) + 4 ) . pack( 'L<', $fde_offset + 4 ) . $fde_body;
        }
        return ( $data, \@fde_offsets );
    }

    # .eh_frame_hdr: binary search index for .eh_frame FDEs.
    # Uses absolute-pointer encoding (DW_EH_PE_absptr) for all pointers.
    method build_eh_frame_hdr ($fde_offsets) {
        return '' unless $eh_frame_base;
        my @table;
        for my $i ( 0 .. $#$func_ranges ) {
            my $fn = $func_ranges->[$i];
            push @table, {
                initial_loc => $text_base + $fn->{start},
                fde_addr    => $eh_frame_base + $fde_offsets->[$i],
            };
        }
        @table = sort { $a->{initial_loc} <=> $b->{initial_loc} } @table;
        my $hdr = pack( 'C4', 1, 0x00, 0x03, 0x00 );
        $hdr .= pack( 'Q<', $eh_frame_base );
        $hdr .= pack( 'L<', scalar @table );
        $hdr .= pack( 'Q< Q<', $_->{initial_loc}, $_->{fde_addr} ) for @table;
        return $hdr;
    }
};
1;
