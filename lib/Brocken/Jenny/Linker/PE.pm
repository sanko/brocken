use v5.42;
use feature qw[class];
no warnings qw[portable];
no warnings qw[experimental::class];
use Brocken::Jenny::Linker;
use Brocken::Katsuro::Platform;

class Brocken::Jenny::Linker::PE : isa(Brocken::Jenny::Linker) {
    field $ENABLE_COFF = 0;

=pod

=head1 NAME

Brocken::Jenny::Linker::PE - 64-bit Portable Executable (PE32+) Generator

=head1 DESCRIPTION

Generates PE binaries for modern 64-bit Windows (x86_64 and ARM64).

=head2 Binary Structure

=over 4

=item * B<DOS MZ Header>: Legacy 64-byte header for compatibility.

=item * B<PE Signature>: "PE\0\0" magic.

=item * B<COFF File Header>: Specifies machine type and section count.

=item * B<Optional Header>: The real PE32+ header containing entry point,
image base, and security flags.

=back

=head2 Windows ARM64 Quirk

Windows on ARM64 strictly mandates the presence of a Base Relocation Table (C<.reloc> section) even for executables
that don't technically need it. If omitted, the loader throws a "Corrupt Executable" error. We generate a dummy
relocation block to satisfy this.

=head2 Security Flags

We enable several modern Windows security features:

=over 4

=item * B<NX_COMPAT>: No-Execute/Data Execution Prevention (DEP).

=item * B<DYNAMIC_BASE>: ASLR support.

=item * B<HIGH_ENTROPY_VA>: 64-bit ASLR (high entropy).

=back

=cut

    method write_executable ( $output_file, $code_data, $platform, $passed_argument = undef, $debug_bytes = undef ) {

        # Ensure $platform is normalized into a platform object if a raw string is passed
        $platform = Brocken::Katsuro::Platform::parse($platform) unless ref $platform;

        # Multi-function support: if $code_data is an arrayref of {name, bytes, fixups},
        # concatenate all blobs, compute function offsets, and track external fixups.
        my @func_fixups;
        my %func_offsets;
        my $code_bytes;
        if ( ref $code_data eq 'ARRAY' ) {
            my @blobs;
            my $offset = 0;
            for my $fd ( $code_data->@* ) {
                $func_offsets{ $fd->{name} } = $offset;
                push @blobs, $fd->{bytes};
                for my $fixup ( $fd->{fixups}->@* ) {
                    push @func_fixups, { %$fixup, base_offset => $offset };
                }
                $offset += length( $fd->{bytes} );
            }
            $code_bytes = join( '', @blobs );
            for my $name ( $self->exported_funcs->@* ) {
                $self->labels->{"E_$name"} //= $func_offsets{$name};
            }
        }
        else {
            $code_bytes = $code_data;
        }
        my $full_code    = ref $code_bytes eq 'HASH' ? $code_bytes->{binary}                        : $code_bytes;
        my $writable_off = ref $code_bytes eq 'HASH' ? ( $code_bytes->{writable_data_offset} // 0 ) : 0;
        my $text_raw     = $writable_off             ? substr( $full_code, 0, $writable_off )       : $full_code;
        my $data_bytes   = $writable_off             ? substr( $full_code, $writable_off )          : '';
        my $text         = $text_raw;
        my $entry_stub   = '';
        if ( $self->type eq 'exe' ) {
            if ( $platform->is_arm64 ) {

                # Windows ARM64 Entry Stub:
                # - stp x29, x30, [sp, #-16]!
                # - mov x29, sp
                # - bl main (relative call offset +16 bytes -> 4 instructions)
                # - ldp x29, x30, [sp], #16
                # - uxtb w0, w0  (truncate exit code to 8 bits)
                # - ret
                my $bl = 0x94000000 | ( ( ( 16 + ( $func_offsets{main} // 0 ) ) >> 2 ) & 0x3FFFFFF );
                $entry_stub = pack( 'V6', 0xA9BF7BFD, 0x910003FD, $bl, 0xA8C17BFD, 0x53001C00, 0xD65F03C0 );
            }
            else {
                # Windows x86_64 Entry Stub (with shadow space):
                # - sub rsp, 40
                # - call main (past stub + truncation)
                # - add rsp, 40
                # - movzx eax, al  (truncate exit code to 8 bits)
                # - ret
                $entry_stub = pack( 'C4', 0x48, 0x83, 0xEC, 0x28 );
                $entry_stub .= pack( 'C V', 0xE8, 8 + ( $func_offsets{main} // 0 ) );
                $entry_stub .= pack( 'C4',  0x48, 0x83, 0xC4, 0x28 );
                $entry_stub .= pack( 'C3',  0x0F, 0xB6, 0xC0 );
                $entry_stub .= pack( 'C',   0xC3 );
            }
            $text = $entry_stub . $text_raw;
        }

        # Resolve cross-function call fixups at link time
        my $entry_size = $self->type eq 'exe' ? length($entry_stub) : 0;
        for my $ff (@func_fixups) {
            my $target_off = $func_offsets{ $ff->{target} };
            die "write_executable: undefined function '$ff->{target}'" unless defined $target_off;
            my $src_pos = $entry_size + $ff->{base_offset} + $ff->{offset};
            if ( $ff->{type} eq 'call_rel32' ) {
                my $rel = ( $entry_size + $target_off ) - ( $src_pos + 5 );
                substr( $text, $src_pos + 1, 4, pack( 'V', $rel & 0xFFFFFFFF ) );
            }
            elsif ( $ff->{type} eq 'call_bl' ) {
                my $rel  = ( $entry_size + $target_off ) - $src_pos;
                my $word = unpack( 'V', substr( $text, $src_pos, 4 ) );
                $word = ( $word & 0xFC000000 ) | ( ( $rel >> 2 ) & 0x3FFFFFF );
                substr( $text, $src_pos, 4, pack( 'V', $word ) );
            }
            elsif ( $ff->{type} eq 'call_jal' ) {
                my $rel  = ( $entry_size + $target_off ) - $src_pos;
                my $half = $rel >> 1;
                my $enc
                    = ( ( $half >> 19 ) & 1 ) << 31 | ( ( $half & 0x3FF ) << 21 ) | ( ( $half >> 10 ) & 1 ) << 20 | ( ( $half >> 11 ) & 0xFF ) << 12;
                my $word = unpack( 'V', substr( $text, $src_pos, 4 ) );
                $word = ( $word & 0x00000FFF ) | $enc;
                substr( $text, $src_pos, 4, pack( 'V', $word ) );
            }
        }
        my $text_bytes = $text;
        my $has_data   = length($data_bytes) > 0;
        my $has_debug  = defined $debug_bytes ? 1 : 0;
        my $has_reloc  = 1;                              # ARM64 Windows strictly enforces ASLR / .reloc presence

        # Check for dynamic exports to write the .edata payload
        my $has_exports        = ( ref $self->exported_funcs eq 'ARRAY' && scalar( @{ $self->exported_funcs } ) > 0 ) ? 1 : 0;
        my $edata_bytes        = '';
        my $sec_raw_edata_size = 0;
        my $edata_rva          = 0;
        my @sorted_exports     = ();
        if ($has_exports) {
            my $text_rva = 0x1000;
            my $data_rva = 0x1000 + ( ( length($text_bytes) + 4095 ) & ~4095 );
            $edata_rva = $data_rva;
            if ($has_data) {
                $edata_rva += ( ( length($data_bytes) + 4095 ) & ~4095 );
            }

            # Initialize with 40 placeholder bytes for the Export Directory Table at offset 0
            $edata_bytes = "\x00" x 40;
            require File::Basename;
            my $dll_name     = File::Basename::basename($output_file);
            my $dll_name_off = length($edata_bytes);
            $edata_bytes .= $dll_name . "\0";
            @sorted_exports = sort @{ $self->exported_funcs };
            my %name_offsets;

            for my $name (@sorted_exports) {
                $name_offsets{$name} = length($edata_bytes);
                $edata_bytes .= $name . "\0";
            }
            my $eat_off = length($edata_bytes);
            for my $name (@sorted_exports) {
                my $label_val = $self->labels->{"E_$name"} // $self->labels->{$name} // 0;
                my $func_rva  = $text_rva + $label_val;
                $edata_bytes .= pack( 'V', $func_rva );
            }
            my $enpt_off = length($edata_bytes);
            for my $name (@sorted_exports) {
                my $name_rva = $edata_rva + $name_offsets{$name};
                $edata_bytes .= pack( 'V', $name_rva );
            }
            my $eot_off = length($edata_bytes);
            my $idx     = 0;
            for my $name (@sorted_exports) {
                $edata_bytes .= pack( 'v', $idx++ );
            }

            # Pad with 4 trailing null bytes to satisfy strict peXXigen.c bounds checks (offset + size < datasize)
            $edata_bytes .= "\x00" x 4;

            # Overwrite the first 40 bytes with the actual Export Directory Table
            my $timestamp        = $ENV{SOURCE_DATE_EPOCH} || time();
            my $export_dir_table = pack( 'V2 v2 V7',
                0, $timestamp, 0, 0, $edata_rva + $dll_name_off,
                1, scalar(@sorted_exports), scalar(@sorted_exports),
                $edata_rva + $eat_off,
                $edata_rva + $enpt_off,
                $edata_rva + $eot_off );
            substr( $edata_bytes, 0, 40, $export_dir_table );
        }
        my $num_sections = 1 + ( $has_data ? 1 : 0 ) + ( $has_exports ? 1 : 0 ) + $has_reloc + ( $has_debug ? 1 : 0 );
        open my $fh, '>', $output_file or die "Cannot open $output_file for writing: $!";
        binmode $fh;

        # DOS MZ Header (Exactly 64 bytes: a2=magic, v29=29 WORDS, V=e_lfanew)
        # We explicitly use v29 and count-matched repetition to avoid pack argument shifts.
        my $dos_header = pack(
            'a2 v29 V', 'MZ',    # e_magic: DOS Magic Signature
            0x0090,              # e_cblp: Bytes on last page of file (144)
            0x0003,              # e_cp: Pages in file (3)
            0x0000,              # e_crlc: Relocations (0)
            0x0004,              # e_cparhdr: Size of header in paragraphs (4)
            0x0000,              # e_minalloc: Minimum extra paragraphs needed (0)
            0xffff,              # e_maxalloc: Maximum extra paragraphs needed (65535)
            0x0000,              # e_ss: Initial (relative) SS value (0)
            0x0100,              # e_sp: Initial SP value (256)
            0x0000,              # e_csum: Checksum (0)
            0x0000,              # e_ip: Initial IP value (0)
            0x0000,              # e_cs: Initial (relative) CS value (0)
            0x0040,              # e_lfarlc: File address of relocation table (64)
            0x0000,              # e_ovno: Overlay number (0)
            (0) x 4,             # e_res: Reserved words (4 WORDS)
            0,                   # e_oemid: OEM identifier (0)
            0,                   # e_oeminfo: OEM information (0)
            (0) x 10,            # e_res2: Reserved words (10 WORDS)
            0x00000080           # e_lfanew: File address of new exe header (Offset 128 / 0x80)
        );
        my $dos_stub     = ( "\x00" x 64 );    # 64 bytes padding to align PE header at offset 128 (0x80)
        my $pe_signature = "PE\x00\x00";

        # COFF File Header (Exactly 20 bytes)
        # Reference: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#coff-file-header-object-and-image
        my $machine   = $platform->is_arm64 ? 0xAA64 : 0x8664;    # IMAGE_FILE_MACHINE_ARM64 or AMD64
        my $timestamp = $ENV{SOURCE_DATE_EPOCH} || time();

        # Layout sections
        my $section_table   = '';
        my $size_of_headers = ( 392 + ( $num_sections * 40 ) + 511 ) & ~511;
        my $sec_raw_ptr     = $size_of_headers;
        my $sec_rva         = 0x1000;

        # .text section (Code)
        my $sec_raw_code_size = ( length($text_bytes) + 511 ) & ~511;
        $section_table .= pack( 'a8 V2 V2 V2 v2 V', ".text\x00\x00\x00", length($text_bytes), $sec_rva, $sec_raw_code_size, $sec_raw_ptr, 0, 0, 0, 0,
            0x60000020 );
        $sec_rva     += ( length($text_bytes) + 4095 ) & ~4095;
        $sec_raw_ptr += $sec_raw_code_size;

        # .data section (Initialized Data)
        my $sec_raw_data_size = 0;
        if ($has_data) {
            $sec_raw_data_size = ( length($data_bytes) + 511 ) & ~511;
            $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                ".data\x00\x00\x00", length($data_bytes), $sec_rva, $sec_raw_data_size, $sec_raw_ptr, 0, 0, 0, 0, 0xC0000040 );
            $sec_rva     += ( length($data_bytes) + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_data_size;
        }

        # .edata section
        if ($has_exports) {
            $sec_raw_edata_size = ( length($edata_bytes) + 511 ) & ~511;
            $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                ".edata\x00\x00", length($edata_bytes), $sec_rva, $sec_raw_edata_size, $sec_raw_ptr, 0, 0, 0, 0, 0x40000040 );
            $sec_rva     += ( length($edata_bytes) + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_edata_size;
        }

        # .reloc section (Mandatory for ARM64)
        my $reloc_bytes        = pack( 'V V v v', 0x1000, 12, 0, 0 );     # Base RVA, Block Size, TypeOffset entries (empty)
        my $reloc_rva          = $sec_rva;
        my $sec_raw_reloc_size = ( length($reloc_bytes) + 511 ) & ~511;
        $section_table .= pack( 'a8 V2 V2 V2 v2 V', ".reloc\x00\x00", length($reloc_bytes), $sec_rva, $sec_raw_reloc_size, $sec_raw_ptr, 0, 0, 0, 0,
            0x42000040 );
        $sec_rva     += ( length($reloc_bytes) + 4095 ) & ~4095;
        $sec_raw_ptr += $sec_raw_reloc_size;

        # .debug_l (Simplified debug section for Windows)
        my $sec_raw_debug_size = 0;
        if ($has_debug) {
            $sec_raw_debug_size = ( length($debug_bytes) + 511 ) & ~511;
            $section_table
                .= pack( 'a8 V2 V2 V2 v2 V', '.debug_l', length($debug_bytes), $sec_rva, $sec_raw_debug_size, $sec_raw_ptr, 0, 0, 0, 0, 0x42000040 );
            $sec_rva     += ( length($debug_bytes) + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_debug_size;
        }

        # Build the COFF Symbol Table (18 bytes per symbol) and String Table
        my $coff_symtab      = '';
        my $coff_strtab      = '';
        my $num_coff_symbols = 0;

        # Keeping legacy COFF Symbol Table fields zeroed out for pristine executables/libraries
        my $pointer_to_symbol_table = 0;
        if ( $ENABLE_COFF && $has_exports && scalar(@sorted_exports) > 0 ) {
            my $str_payload = '';
            my %coff_str_offsets;
            for my $name (@sorted_exports) {
                $coff_str_offsets{$name} = 4 + length($str_payload);
                $str_payload .= $name . "\0";
            }
            for my $name (@sorted_exports) {
                my $label_val = $self->labels->{"E_$name"} // $self->labels->{$name} // 0;
                my $func_rva  = 0x1000 + $label_val;                                         # .text section RVA starts at 0x1000
                my $entry_name_field;
                if ( length($name) <= 8 ) {
                    $entry_name_field = pack( 'a8', $name );
                }
                else {
                    $entry_name_field = pack( 'V2', 0, $coff_str_offsets{$name} );
                }

                # IMAGE_SYMBOL struct size is 18 bytes
                $coff_symtab .= pack(
                    'a8 V v v C2', $entry_name_field,    # union: ShortName / Offset
                    $func_rva,                           # Value (Address relative to ImageBase)
                    1,                                   # SectionNumber (1-based index, .text is 1)
                    0x20,                                # Type (0x0020 = Function)
                    2,                                   # StorageClass (2 = External/Global)
                    0                                    # NumberOfAuxSymbols
                );
                $num_coff_symbols++;
            }
            if ( length($str_payload) > 0 ) {
                $coff_strtab = pack( 'V', 4 + length($str_payload) ) . $str_payload;
            }

            # Position table offset directly after raw section data on disk
            $pointer_to_symbol_table = $sec_raw_ptr;
        }
        my $file_header = pack(
            'v2 V3 v2', $machine,        # Machine Architecture
            $num_sections,               # Number of Sections
            $timestamp,                  # TimeDateStamp
            $pointer_to_symbol_table,    # PointerToSymbolTable (zeroed for clean images)
            $num_coff_symbols,           # NumberOfSymbols (zeroed for clean images)
            240,                         # SizeOfOptionalHeader (240 bytes for PE32+)
            0x0022                       # Characteristics (EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE)
        );
        #
        my $size_of_image  = $sec_rva;
        my $size_of_code   = $sec_raw_code_size;
        my $init_data_size = $sec_raw_data_size + $sec_raw_reloc_size + $sec_raw_debug_size;
        my $os_ver         = 6;                                                                # Target Windows Vista/7+ compatibility

        # PE32+ Optional Header (Exactly 240 bytes)
        # Reference: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#optional-header-image-only
        my $opt_header = pack(
            'v C2 V3 V2 Q< V2 v4 v2 V V V V v2 Q<4 V2', 0x020b,                        # Magic Number (PE32+ 64-bit)
            14,                                         10,                            # Major/Minor LinkerVersion
            $size_of_code,                              $init_data_size, 0, 0x1000,    # AddressOfEntryPoint (RVA 0x1000)
            0x1000,                                                                    # BaseOfCode
            0x140000000,                                                               # ImageBase (Modern default 5GB base)
            4096,                                                                      # SectionAlignment
            512,                                                                       # FileAlignment
            $os_ver, 0,                                                                # Major/Minor OS
            0,       0,                                                                # Major/Minor Image
            $os_ver, 0,                                                                # Major/Minor Subsystem
            0,                                                                         # Win32VersionValue
            $size_of_image, $size_of_headers, 0,                                       # CheckSum (Optional for non-drivers)
            3,         # Subsystem (Windows Console)
            0x8160,    # DllCharacteristics (DYNAMIC_BASE | NX_COMPAT | TS_AWARE | HIGH_ENTROPY_VA)
            0x100000, 0x1000, 0x100000, 0x1000,    # Stack/Heap Reserve/Commit
            0,                                     # LoaderFlags
            16                                     # NumberOfRvaAndSizes (Data Directories)
        );

        # Data Directories (16 entries, 8 bytes each)
        my $data_dirs = "\x00" x 128;
        if ( ref $code_bytes eq 'HASH' ) {
            my $import_rva  = $code_bytes->{import_descriptor_rva}  // 0;
            my $import_size = $code_bytes->{import_descriptor_size} // 0;
            if ($import_rva) {

                # Import Directory (Index 1)
                substr $data_dirs, 8,  4, pack( 'V', $import_rva );
                substr $data_dirs, 12, 4, pack( 'V', $import_size );
            }
        }
        #
        if ($has_exports) {

            # VirtualAddress points to standard RVA 0x2000; Size spans the entire export payload block
            substr $data_dirs, 0, 4, pack( 'V', $edata_rva );
            substr $data_dirs, 4, 4, pack( 'V', length($edata_bytes) );
        }

        # Insert Base Relocation Data Directory (Index 5 = Offset 40)
        substr $data_dirs, 40, 4, pack( 'V', $reloc_rva );
        substr $data_dirs, 44, 4, pack( 'V', length($reloc_bytes) );
        $opt_header .= $data_dirs;
        print $fh $dos_header, $dos_stub, $pe_signature, $file_header, $opt_header, $section_table;

        # Pad headers to FileAlignment
        my $headers_len
            = length($dos_header) + length($dos_stub) + length($pe_signature) + length($file_header) + length($opt_header) + length($section_table);
        print $fh ( "\x00" x ( $size_of_headers - $headers_len ) );

        # Write section payloads
        print $fh $text_bytes;
        print $fh ( "\x00" x ( $sec_raw_code_size - length($text_bytes) ) );
        if ($has_data) {
            print $fh $data_bytes;
            print $fh ( "\x00" x ( $sec_raw_data_size - length($data_bytes) ) );
        }
        if ($has_exports) {
            print $fh $edata_bytes;
            print $fh ( "\x00" x ( $sec_raw_edata_size - length($edata_bytes) ) );
        }
        if ($has_reloc) {
            print $fh $reloc_bytes;
            print $fh ( "\x00" x ( $sec_raw_reloc_size - length($reloc_bytes) ) );
        }
        if ($has_debug) {
            print $fh $debug_bytes;
            print $fh ( "\x00" x ( $sec_raw_debug_size - length($debug_bytes) ) );
        }

        # Append the dynamic COFF symbol table block at the calculated file offset
        if ( $pointer_to_symbol_table > 0 ) {
            print $fh $coff_symtab;
            print $fh $coff_strtab;
        }
        close $fh;
        chmod 0755, $output_file;
    }

    method write_shared_library ( $output_file, $code_bytes, $platform, $debug_bytes = undef ) {
        my $p = ref($platform) ? $platform : Brocken::Katsuro::Platform::parse($platform);
        $self->write_executable( $output_file, $code_bytes, $p, undef, $debug_bytes );
        open my $fh, '+<', $output_file or die $!;
        binmode $fh;
        seek $fh, 0x96, 0;                # Offset to COFF Characteristics
        print $fh pack( 'v', 0x2022 );    # EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE | IMAGE_FILE_DLL
        close $fh;
    }
}
1;
