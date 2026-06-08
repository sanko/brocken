# lib/Brocken/Target/Format/MachO.pm
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Target::Format::MachO {
    no warnings 'portable';

    # Mach-O 64-bit loader constants
    use constant MH_MAGIC_64          => 0xfeedfacf;
    use constant CPU_TYPE_X86_64      => 0x01000007;
    use constant CPU_TYPE_ARM64       => 0x0100000c;
    use constant CPU_SUBTYPE_LIB64    => 0x80000000;
    use constant CPU_SUBTYPE_I386_ALL => 0x00000003;
    use constant MH_EXECUTE           => 0x2;
    use constant MH_DYLIB             => 0x6;
    use constant MH_NOUNDEFS          => 0x1;
    use constant MH_DYLDLINK          => 0x4;
    use constant MH_TWOLEVEL          => 0x80;
    use constant MH_PIE               => 0x200000;
    use constant LC_SEGMENT_64        => 0x19;
    use constant LC_MAIN              => 0x80000028;
    use constant LC_BUILD_VERSION     => 0x32;
    use constant LC_LOAD_DYLINKER     => 0x0E;
    use constant LC_ID_DYLIB          => 0x0D;
    use constant LC_SYMTAB            => 0x02;
    use constant LC_DYSYMTAB          => 0x0B;

    method write_executable ( $output_file, $code_bytes, $triple, $passed_argument = undef, $debug_bytes = undef ) {
        my $code          = ref $code_bytes eq 'HASH' ? $code_bytes->{binary} : $code_bytes;
        my $start_wrapper = '';
        if ( $triple->is_arm64 ) {
            $start_wrapper .= pack 'V*', 0x94000004, 0xd2800030, 0xf2a04010, 0xd4000001;
        }
        else {
            $start_wrapper .= pack 'C3 V', 0x48, 0xC7, 0xC7, $passed_argument if defined $passed_argument;
            $start_wrapper .= pack 'C*', 0xE8, 0x0C, 0x00, 0x00, 0x00, 0x48, 0x89, 0xC7, 0x48, 0xC7, 0xC0, 0x01, 0x00, 0x00, 0x02, 0x0F, 0x05;
        }
        my $full_code = $start_wrapper . $code;
        open my $fh, '>', $output_file or die "Cannot open $output_file for writing: $!";
        binmode $fh;
        my $has_debug        = defined $debug_bytes ? 1     : 0;
        my $page_size        = $triple->is_arm64    ? 16384 : 4096;
        my $text_align       = $triple->is_arm64    ? 14    : 12;
        my $dylinker_path    = "/usr/lib/dyld\0";
        my $dylinker_cmdsize = ( 12 + length($dylinker_path) + 7 ) & ~7;
        my $dylinker_padding = "\x00" x ( $dylinker_cmdsize - 12 - length($dylinker_path) );

        # Load command sizes
        my $sz_pagezero  = 72;
        my $sz_text      = 152;
        my $sz_linkedit  = 72;
        my $sz_build_ver = 24;
        my $sz_dylinker  = $dylinker_cmdsize;
        my $sz_main      = 24;
        my $sz_symtab    = 24;
        my $sz_dysymtab  = 80;
        my $sz_dwarf     = $has_debug ? 152 : 0;
        my $ncmds        = 8;
        $ncmds++ if $has_debug;
        my $sizeofcmds = $sz_pagezero + $sz_text + $sz_linkedit + $sz_build_ver + $sz_dylinker + $sz_main + $sz_symtab + $sz_dysymtab + $sz_dwarf;

        # Mach-O Header
        my $magic       = MH_MAGIC_64;
        my $cputype     = $triple->is_arm64 ? CPU_TYPE_ARM64 : CPU_TYPE_X86_64;
        my $cpusubtype  = $triple->is_arm64 ? 0              : ( CPU_SUBTYPE_LIB64 | CPU_SUBTYPE_I386_ALL );
        my $filetype    = MH_EXECUTE;
        my $flags       = MH_NOUNDEFS | MH_PIE | MH_DYLDLINK | MH_TWOLEVEL;
        my $reserved    = 0;
        my $mach_header = pack 'L7 L', $magic, $cputype, $cpusubtype, $filetype, $ncmds, $sizeofcmds, $flags, $reserved;

        # PAGEZERO Segment Command (72 bytes)
        my $pagezero_cmd = pack 'L2 a16 Q4 L4', LC_SEGMENT_64, 72, '__PAGEZERO', 0, 0x100000000, 0, 0, 0, 0, 0, 0;

        # TEXT Segment Command + Section Descriptor (152 bytes)
        my $header_size   = length($mach_header) + $sizeofcmds;
        my $text_offset   = ( $header_size + $page_size - 1 ) & ~( $page_size - 1 );
        my $text_filesize = $text_offset + length($full_code);
        my $text_vmsize   = ( $text_filesize + $page_size - 1 ) & ~( $page_size - 1 );
        my $text_cmd      = pack 'L2 a16 Q4 L4', LC_SEGMENT_64, $sz_text, '__TEXT', 0x100000000, $text_vmsize, 0, $text_filesize, 5, 5, 1, 0;

        # Section description for __text (80 bytes)
        my $text_sect = pack 'a16 a16 Q2 L8', '__text', '__TEXT', 0x100000000 + $text_offset, length($full_code), $text_offset, $text_align, 0, 0, 0,
            0, 0, 0;

        # LINKEDIT Segment Command (72 bytes)
        my $data_end          = $text_filesize + ( $has_debug ? length($debug_bytes) : 0 );
        my $linkedit_fileoff  = ( $data_end + $page_size - 1 ) & ~( $page_size - 1 );
        my $linkedit_filesize = $page_size;
        my $linkedit_vmaddr   = 0x100000000 + $text_vmsize;
        my $linkedit_vmsize   = $page_size;
        my $linkedit_cmd      = pack 'L2 a16 Q4 L4', LC_SEGMENT_64, $sz_linkedit, '__LINKEDIT', $linkedit_vmaddr, $linkedit_vmsize, $linkedit_fileoff,
            $linkedit_filesize, 1, 1, 0, 0;
        my $lc_build_version = pack 'L6',    LC_BUILD_VERSION, 0x18, 1, 0x000E0000, 0x000E0000, 0;
        my $lc_dylinker      = pack 'L3 a*', LC_LOAD_DYLINKER, $sz_dylinker, 12, $dylinker_path . $dylinker_padding;
        my $lc_main          = pack 'L2 Q2', LC_MAIN,          24, $text_offset, 0;
        my $lc_symtab        = pack 'L6',    LC_SYMTAB,        24, 0, 0, 0, 0;
        my $lc_dysymtab      = pack 'L20',   LC_DYSYMTAB,      80, (0) x 18;

        # DWARF Segment Command (152 bytes)
        my $dwarf_cmd    = '';
        my $dwarf_sect   = '';
        my $debug_offset = $text_offset + length($full_code);
        if ($has_debug) {
            $dwarf_cmd = pack 'L2 a16 Q4 L4', LC_SEGMENT_64, 152, '__DWARF', 0, length($debug_bytes), $debug_offset, length($debug_bytes), 1, 1, 1, 0;
            $dwarf_sect = pack 'a16 a16 Q2 L8', '__debug_line', '__DWARF', 0, length($debug_bytes), $debug_offset, 0, 0, 0, 0x02000000, 0, 0, 0, 0;
        }

        # Write out
        print $fh $mach_header;
        print $fh $pagezero_cmd;
        print $fh $text_cmd;
        print $fh $text_sect;
        print $fh $linkedit_cmd;
        print $fh $lc_build_version;
        print $fh $lc_dylinker;
        print $fh $lc_main;
        print $fh $lc_symtab;
        print $fh $lc_dysymtab;

        if ($has_debug) {
            print $fh $dwarf_cmd;
            print $fh $dwarf_sect;
        }

        # Pad and write code
        my $padding_len = $text_offset - length($mach_header) - $sizeofcmds;
        print $fh "\x00" x $padding_len;
        print $fh $full_code;
        if ($has_debug) {
            print $fh $debug_bytes;
        }

        # Pad to page-aligned LINKEDIT start
        my $pad_to_linkedit = $linkedit_fileoff - tell($fh);
        print $fh "\x00" x $pad_to_linkedit if $pad_to_linkedit > 0;

        # Write LINKEDIT data
        print $fh "\x00" x $linkedit_filesize;
        close $fh;
        chmod 0755, $output_file;
    }

    # Compiles a macOS dynamic shared library (.dylib) instead of an executable
    method write_shared_library ( $output_file, $code_bytes, $triple, $debug_bytes = undef ) {
        my $full_code = $code_bytes;
        open my $fh, '>', $output_file or die "Cannot open $output_file for writing: $!";
        binmode $fh;
        my $has_debug     = defined $debug_bytes ? 1     : 0;
        my $page_size     = $triple->is_arm64    ? 16384 : 4096;
        my $text_align    = $triple->is_arm64    ? 14    : 12;
        my $dylib_path    = "\@rpath/libdemo.dylib\0";
        my $dylib_cmdsize = ( 24 + length($dylib_path) + 7 ) & ~7;
        my $dylib_padding = "\x00" x ( $dylib_cmdsize - 24 - length($dylib_path) );
        my $sz_text       = 152;
        my $sz_linkedit   = 72;
        my $sz_build_ver  = 24;
        my $sz_id_dylib   = $dylib_cmdsize;
        my $sz_symtab     = 24;
        my $sz_dysymtab   = 80;
        my $sz_dwarf      = $has_debug ? 152 : 0;
        my $ncmds         = 6;
        $ncmds++ if $has_debug;
        my $sizeofcmds    = $sz_text + $sz_linkedit + $sz_build_ver + $sz_id_dylib + $sz_symtab + $sz_dysymtab + $sz_dwarf;
        my $magic         = MH_MAGIC_64;
        my $cputype       = $triple->is_arm64 ? CPU_TYPE_ARM64 : CPU_TYPE_X86_64;
        my $cpusubtype    = $triple->is_arm64 ? 0              : ( CPU_SUBTYPE_LIB64 | CPU_SUBTYPE_I386_ALL );
        my $filetype      = MH_DYLIB;
        my $flags         = MH_NOUNDEFS | MH_PIE | MH_DYLDLINK | MH_TWOLEVEL;
        my $reserved      = 0;
        my $mach_header   = pack 'L7 L', $magic, $cputype, $cpusubtype, $filetype, $ncmds, $sizeofcmds, $flags, $reserved;
        my $header_size   = length($mach_header) + $sizeofcmds;
        my $text_offset   = ( $header_size + $page_size - 1 ) & ~( $page_size - 1 );
        my $text_filesize = $text_offset + length($full_code);
        my $text_vmsize   = ( $text_filesize + $page_size - 1 ) & ~( $page_size - 1 );
        my $text_cmd      = pack 'L2 a16 Q4 L4',  LC_SEGMENT_64, $sz_text, '__TEXT', 0, $text_vmsize, 0, $text_filesize, 5, 5, 1, 0;
        my $text_sect     = pack 'a16 a16 Q2 L8', '__text', '__TEXT', $text_offset, length($full_code), $text_offset, $text_align, 0, 0, 0, 0, 0, 0;
        my $data_end          = $text_filesize + ( $has_debug ? length($debug_bytes) : 0 );
        my $linkedit_fileoff  = ( $data_end + $page_size - 1 ) & ~( $page_size - 1 );
        my $linkedit_filesize = $page_size;
        my $linkedit_vmaddr   = $text_vmsize;
        my $linkedit_vmsize   = $page_size;
        my $linkedit_cmd      = pack 'L2 a16 Q4 L4', LC_SEGMENT_64, $sz_linkedit, '__LINKEDIT', $linkedit_vmaddr, $linkedit_vmsize, $linkedit_fileoff,
            $linkedit_filesize, 1, 1, 0, 0;
        my $lc_build_version = pack 'L6',    LC_BUILD_VERSION, 0x18, 1, 0x000E0000, 0x000E0000, 0;
        my $lc_id_dylib      = pack 'L6 a*', LC_ID_DYLIB,      $sz_id_dylib, 24, 0, 0x010000, 0x010000, $dylib_path . $dylib_padding;
        my $lc_symtab        = pack 'L6',    LC_SYMTAB,        24, 0, 0, 0, 0;
        my $lc_dysymtab      = pack 'L20',   LC_DYSYMTAB,      80, (0) x 18;
        my $dwarf_cmd        = '';
        my $dwarf_sect       = '';
        my $debug_offset     = $text_offset + length($full_code);

        if ($has_debug) {
            $dwarf_cmd = pack 'L2 a16 Q4 L4', LC_SEGMENT_64, 152, '__DWARF', 0, length($debug_bytes), $debug_offset, length($debug_bytes), 1, 1, 1, 0;
            $dwarf_sect = pack 'a16 a16 Q2 L8', '__debug_line', '__DWARF', 0, length($debug_bytes), $debug_offset, 0, 0, 0, 0x02000000, 0, 0, 0, 0;
        }
        print $fh $mach_header;
        print $fh $text_cmd;
        print $fh $text_sect;
        print $fh $linkedit_cmd;
        print $fh $lc_build_version;
        print $fh $lc_id_dylib;
        print $fh $lc_symtab;
        print $fh $lc_dysymtab;

        if ($has_debug) {
            print $fh $dwarf_cmd;
            print $fh $dwarf_sect;
        }
        my $padding_len = $text_offset - length($mach_header) - $sizeofcmds;
        print $fh "\x00" x $padding_len;
        print $fh $full_code;
        if ($has_debug) {
            print $fh $debug_bytes;
        }
        my $pad_to_linkedit = $linkedit_fileoff - tell($fh);
        print $fh "\x00" x $pad_to_linkedit if $pad_to_linkedit > 0;
        print $fh "\x00" x $linkedit_filesize;
        close $fh;
        chmod 0755, $output_file;
    }
}
1;
