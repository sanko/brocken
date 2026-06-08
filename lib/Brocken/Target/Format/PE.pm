# lib/Brocken/Target/Format/PE.pm
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Target::Format::PE {
    no warnings 'portable';

    method write_executable ( $output_file, $code_bytes, $triple, $passed_argument = undef, $debug_bytes = undef ) {
        my $full_code    = ref $code_bytes eq 'HASH' ? $code_bytes->{binary}                        : $code_bytes;
        my $writable_off = ref $code_bytes eq 'HASH' ? ( $code_bytes->{writable_data_offset} // 0 ) : 0;

        # Split binary into .text (read+execute) and .data (read+write) parts
        my $text_bytes   = $writable_off ? substr( $full_code, 0, $writable_off ) : $full_code;
        my $data_bytes   = $writable_off ? substr( $full_code, $writable_off ) : '';
        my $has_data     = length($data_bytes) > 0;
        my $has_debug    = defined $debug_bytes ? 1 : 0;
        my $num_sections = 1 + ( $has_data ? 1 : 0 ) + ( $has_debug ? 1 : 0 );
        open my $fh, '>', $output_file or die "Cannot open $output_file for writing: $!";
        binmode $fh;

        # DOS MZ Header (64 bytes: a2=magic, S29=29 WORDS, L=e_lfanew)
        my $dos_header = pack 'a2 S29 L', 'MZ', 0x0090, 0x0003, 0x0000, 0x0004, 0x0000, 0xffff, 0x0000, 0x0100, 0x0000, 0x0000, 0x0000, 0x0040,
            0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
            0x00000080;
        my $dos_stub     = ( "\x00" x 64 );
        my $pe_signature = "PE\x00\x00";

        # COFF File Header
        my $machine              = $triple->is_arm64 ? 0xAA64 : 0x8664;
        my $timestamp            = $ENV{SOURCE_DATE_EPOCH} // 0;
        my $symbol_table_ptr     = 0;
        my $num_symbols          = 0;
        my $optional_header_size = 240;
        my $characteristics      = 0x0022;
        my $file_header          = pack 'S2 L3 S2', $machine, $num_sections, $timestamp, $symbol_table_ptr, $num_symbols, $optional_header_size,
            $characteristics;

        # PE32+ Optional Header
        my $magic_pe32plus        = 0x020b;
        my $major_linker          = 1;
        my $minor_linker          = 0;
        my $code_size             = 4096;
        my $init_data_size        = ( $has_data || $has_debug ) ? 4096 : 0;
        my $uninit_data_size      = 0;
        my $entry_point           = 0x1000;
        my $base_of_code          = 0x1000;
        my $image_base            = 0x140000000;
        my $section_alignment     = 4096;
        my $file_alignment        = 512;
        my $major_os              = 6;
        my $minor_os              = 0;
        my $major_image           = 0;
        my $minor_image           = 0;
        my $major_subsystem       = 6;
        my $minor_subsystem       = 0;
        my $win32_version         = 0;
        my $size_of_image         = 0x1000 * $num_sections + 0x1000;
        my $size_of_headers       = 512;
        my $checksum              = 0;
        my $subsystem             = 3;
        my $dll_characteristics   = 0x8140;
        my $size_of_stack_reserve = 0x100000;
        my $size_of_stack_commit  = 0x1000;
        my $size_of_heap_reserve  = 0x100000;
        my $size_of_heap_commit   = 0x1000;
        my $loader_flags          = 0;
        my $num_data_directories  = 16;

        # S C2 L3 L2 Q L2 S4 S2 L L L L S2 Q4 L2 = 112 bytes
        my $opt_header = pack 'S C2 L3 L2 Q L2 S4 S2 L L L L S2 Q4 L2', $magic_pe32plus, $major_linker, $minor_linker, $code_size, $init_data_size,
            $uninit_data_size,    $entry_point, $base_of_code, $image_base, $section_alignment, $file_alignment, $major_os, $minor_os, $major_image,
            $minor_image,         $major_subsystem,       $minor_subsystem, $win32_version, $size_of_image, $size_of_headers, $checksum, $subsystem,
            $dll_characteristics, $size_of_stack_reserve, $size_of_stack_commit, $size_of_heap_reserve, $size_of_heap_commit, $loader_flags,
            $num_data_directories;

        # Build data directories (16 entries, 8 bytes each)
        my $data_dirs = "\x00" x 128;

        # Set import directory entry if provided
        if ( ref $code_bytes eq 'HASH' ) {
            my $import_rva  = $code_bytes->{import_descriptor_rva}  // 0;
            my $import_size = $code_bytes->{import_descriptor_size} // 0;
            if ($import_rva) {
                substr $data_dirs, 8,  4, pack( 'V', $import_rva );
                substr $data_dirs, 12, 4, pack( 'V', $import_size );
            }
        }
        $opt_header .= $data_dirs;

        # Section table
        my $section_table = '';
        my $sec_raw_ptr   = 512;

        # Section 1: .text — CODE | EXECUTE | READ (no WRITE)
        my $sec_raw_code_size = ( length($text_bytes) + 511 ) & ~511;
        $section_table .= pack 'a8 L2 L2 L2 S2 L', ".text\x00\x00\x00", length($text_bytes), 0x1000, $sec_raw_code_size, $sec_raw_ptr, 0, 0, 0, 0,
            0x60000020;
        $sec_raw_ptr += $sec_raw_code_size;

        # Section 2: .data — INITIALIZED_DATA | READ | WRITE (if writable data exists)
        if ($has_data) {
            my $sec_raw_data_size = ( length($data_bytes) + 511 ) & ~511;
            $section_table .= pack 'a8 L2 L2 L2 S2 L', ".data\x00\x00\x00", length($data_bytes), 0x2000, $sec_raw_data_size, $sec_raw_ptr, 0, 0, 0,
                0, 0xC0000040;
            $sec_raw_ptr += $sec_raw_data_size;
        }

        # Section 3: .debug_l — DWARF Line Table (optional)
        if ($has_debug) {
            my $sec_raw_debug_size = ( length($debug_bytes) + 511 ) & ~511;
            $section_table .= pack 'a8 L2 L2 L2 S2 L', '.debug_l', length($debug_bytes), 0x3000, $sec_raw_debug_size, $sec_raw_ptr, 0, 0, 0, 0,
                0x42000040;
            $sec_raw_ptr += $sec_raw_debug_size;
        }

        # Write output
        print $fh $dos_header;
        print $fh $dos_stub;
        print $fh $pe_signature;
        print $fh $file_header;
        print $fh $opt_header;
        print $fh $section_table;

        # Pad headers up to 512 disk alignment
        my $headers_len
            = length($dos_header) + length($dos_stub) + length($pe_signature) + length($file_header) + length($opt_header) + length($section_table);
        print $fh ( "\x00" x ( 512 - $headers_len ) );

        # Write .text segment bytes
        print $fh $text_bytes;
        print $fh ( "\x00" x ( $sec_raw_code_size - length($text_bytes) ) );

        # Write .data segment bytes
        if ($has_data) {
            my $sec_raw_data_size = ( length($data_bytes) + 511 ) & ~511;
            print $fh $data_bytes;
            print $fh ( "\x00" x ( $sec_raw_data_size - length($data_bytes) ) );
        }

        # Write .debug_l segment bytes
        if ($has_debug) {
            my $sec_raw_debug_size = ( length($debug_bytes) + 511 ) & ~511;
            print $fh $debug_bytes;
            print $fh ( "\x00" x ( $sec_raw_debug_size - length($debug_bytes) ) );
        }
        close $fh;
    }

    method write_shared_library ( $output_file, $code_bytes, $triple, $debug_bytes = undef ) {
        $self->write_executable( $output_file, $code_bytes, $triple, undef, $debug_bytes );
        open my $fh, '+<', $output_file or die $!;
        binmode $fh;
        seek $fh, 0x96, 0;
        print $fh pack( "S", 0x2022 );    # EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE | IMAGE_FILE_DLL
        close $fh;
    }
}
1;
