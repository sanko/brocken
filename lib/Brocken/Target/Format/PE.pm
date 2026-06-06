use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Target::Format::PE {
    no warnings 'portable';

    method write_executable ( $output_file, $code_bytes, $triple, $passed_argument = undef, $debug_bytes = undef ) {

        # standalone PE executables run directly by returning 'ret' from their loader thread.
        # This allows us to map code directly with no dynamic dll dependency overhead.
        my $full_code = $code_bytes;
        open my $fh, '>', $output_file or die "Cannot open $output_file for writing: $!";
        binmode $fh;

        # DOS MZ Header (64 bytes)
        my $dos_header = pack 'a2 S27 L',                                                                  #
            'MZ',                                                                                          # magic
            0x0090, 0x0003, 0x0000, 0x0004, 0x0000, 0xffff, 0x0000, 0x0100, 0x0000, 0x0000, 0x0000, 0x0040, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
            0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x00000080;    # e_lfanew (pointer to PE header)

        # MS-DOS Stub padding (64 bytes)
        my $dos_stub = ( "\x00" x 64 );

        # PE Signature ("PE\0\0")
        my $pe_signature = "PE\x00\x00";

        # COFF File Header (20 bytes)
        my $has_debug = defined $debug_bytes ? 1 : 0;
        my $machine   = $triple->is_arm64 ?
            0xAA64                                                                                         # IMAGE_FILE_MACHINE_ARM64
            :
            0x8664;                                                                                        # IMAGE_FILE_MACHINE_AMD64 (x64)
        my $num_sections         = $has_debug ? 2 : 1;                   # Text section containing executable code and DWARF (if present)
        my $timestamp            = $ENV{SOURCE_DATE_EPOCH} // time();    # https://reproducible-builds.org/specs/source-date-epoch/
        my $symbol_table_ptr     = 0;
        my $num_symbols          = 0;
        my $optional_header_size = 240;                                  # Size of Optional Header PE32+
        my $characteristics      = 0x0022;                               # EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE

        #
        my $file_header = pack 'S2 L3 S2', $machine, $num_sections, $timestamp, $symbol_table_ptr, $num_symbols, $optional_header_size,
            $characteristics;

        # PE32+ Optional Header (240 bytes)
        my $magic_pe32plus        = 0x020b;                              # PE32+ (64-bit format)
        my $major_linker          = 1;
        my $minor_linker          = 0;
        my $code_size             = 4096;
        my $init_data_size        = $has_debug ? 4096 : 0;
        my $uninit_data_size      = 0;
        my $entry_point           = 0x1000;                              # Virtual offset of entry point (.text)
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
        my $size_of_image         = $has_debug ? 12288 : 8192;           # Size of headers + .text segment + DWARF page size
        my $size_of_headers       = 512;
        my $checksum              = 0;
        my $subsystem             = 3;                                   # Console User Interface (CUI)
        my $dll_characteristics   = 0x8140;                              # DYNAMIC_BASE | NX_COMPAT
        my $size_of_stack_reserve = 0x100000;
        my $size_of_stack_commit  = 0x1000;
        my $size_of_heap_reserve  = 0x100000;
        my $size_of_heap_commit   = 0x1000;
        my $loader_flags          = 0;
        my $num_data_directories  = 16;
        #
        my $opt_header = pack 'S C2 L3 L2 Q L2 S4 S2 S2 L4 S2 Q4 L2', $magic_pe32plus, $major_linker, $minor_linker, $code_size, $init_data_size,
            $uninit_data_size,    $entry_point, $base_of_code, $image_base, $section_alignment, $file_alignment, $major_os, $minor_os, $major_image,
            $minor_image,         $major_subsystem,       $minor_subsystem, $win32_version, $size_of_image, $size_of_headers, $checksum, $subsystem,
            $dll_characteristics, $size_of_stack_reserve, $size_of_stack_commit, $size_of_heap_reserve, $size_of_heap_commit, $loader_flags,
            $num_data_directories;

        # Append empty directories
        $opt_header .= "\x00" x 128;

        # Alignments on Disk
        my $sec_raw_code_size = ( length($full_code) + 511 ) & ~511;
        my $debug_raw_ptr     = 512 + $sec_raw_code_size;

        # Section Table (40 bytes per section)
        # Section 1: .text (Code)
        my $section_table = pack 'a8 L2 L2 L2 S2 L', ".text\x00\x00\x00", length($full_code), 0x1000, $sec_raw_code_size, 512, 0, 0, 0, 0,
            0x60000020;    # CODE | EXECUTE | READ

        # Section 2: .debug_l (DWARF Line Table)
        if ($has_debug) {
            my $sec_raw_debug_size = ( length($debug_bytes) + 511 ) & ~511;
            $section_table .= pack 'a8 L2 L2 L2 S2 L', '.debug_l', length($debug_bytes), 0x2000, $sec_raw_debug_size, $debug_raw_ptr, 0, 0, 0, 0,
                0x42000040    # INITIALIZED_DATA | MEM_READ | MEM_DISCARDABLE
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
        print $fh $full_code;
        print $fh ( "\x00" x ( $sec_raw_code_size - length($full_code) ) );

        # Write .debug_l segment bytes
        if ($has_debug) {
            my $sec_raw_debug_size = ( length($debug_bytes) + 511 ) & ~511;
            print $fh $debug_bytes;
            print $fh ( "\x00" x ( $sec_raw_debug_size - length($debug_bytes) ) );
        }
        close $fh;
    }

    # Compiles a Windows DLL (.dll) instead of an executable
    method write_shared_library ( $output_file, $code_bytes, $triple, $debug_bytes = undef ) {

        # Redirect to standard PE compiler, then patch the characteristics flag to IMAGE_FILE_DLL (0x2000)
        $self->write_executable( $output_file, $code_bytes, $triple, undef, $debug_bytes );
        open my $fh, '+<', $output_file or die $!;
        binmode $fh;

        # PE characteristics flag is at byte offset e_lfanew (0x80) + 4 (Signature) + 18 = 0x96
        seek $fh, 0x96, 0;
        print $fh pack( "S", 0x2022 );    # EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE | IMAGE_FILE_DLL
        close $fh;
    }
}
