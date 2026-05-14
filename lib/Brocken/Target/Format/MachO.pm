use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
#
class Brocken::Target::Format::MachO : isa(Brocken::Target::Format) {

    method write_bin ( $filename, $text, $data, $arch, $os = 'macos' ) {
        my $is_arm      = ( $arch eq 'arm64' );
        my $page_size   = $is_arm ? 0x4000     : 0x1000;
        my $cpu_type    = $is_arm ? 0x0100000C : 0x01000007;
        my $cpu_subtype = $is_arm ? 0x00000000 : 0x00000003;
        my $align_f     = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
        my $text_padded = $text . ( "\0" x ( $align_f->( length($text), $page_size ) - length($text) ) );
        my $data_padded = $data . ( "\0" x ( $align_f->( length($data), $page_size ) - length($data) ) );

        # 12 Load Commands for strict dyld/codesign compliance
        my $ncmds      = 12;
        my $sizeofcmds = 72 + 152 + 152 + 72 + 24 + 24 + 24 + 32 + 56 + 24 + 80 + 48;    # 760 bytes

        # Header (MH_PIE | MH_TWOLEVEL | MH_DYLDLINK | MH_NOUNDEFS)
        my $header = pack( 'L L L L L L L L', 0xFEEDFACF, $cpu_type, $cpu_subtype, 2, $ncmds, $sizeofcmds, 0x00200085, 0 );

        # LC_SEGMENT_64 (__PAGEZERO)
        my $lc_pagezero = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 72, "__PAGEZERO", 0, 0x100000000, 0, 0, 0, 0, 0, 0 );

        # LC_SEGMENT_64 (__TEXT) - Permissions RX (5)
        my $text_vmsize = 2 * $page_size;
        my $lc_text     = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 152, "__TEXT", 0x100000000, $text_vmsize, 0, $text_vmsize, 5, 5, 1, 0 );
        $lc_text .= pack(
            'a16 a16 Q Q L L L L L L L L',
            "__text", "__TEXT", 0x100000000 + $page_size,
            length($text_padded), $is_arm ? 14 : 12,
            $page_size, 0, 0, 0, $is_arm ? 0x80000400 : 0x00000400,
            0, 0, 0
        );

        # LC_SEGMENT_64 (__DATA) - Permissions RW (3)
        my $data_vmaddr = 0x100000000 + 2 * $page_size;
        my $lc_data     = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 152, "__DATA", $data_vmaddr, $page_size, 2 * $page_size, $page_size, 3, 3, 1, 0 );
        $lc_data .= pack(
            'a16 a16 Q Q L L L L L L L L',
            "__data", "__DATA", $data_vmaddr, length($data_padded),
            $is_arm ? 14 : 12,
            2 * $page_size,
            0, 0, 0, 0, 0, 0, 0
        );

        # LC_SEGMENT_64 (__LINKEDIT) - Permissions R (1)
        my $link_vmaddr  = 0x100000000 + 3 * $page_size;
        my $link_fileoff = 3 * $page_size;
        my $lc_linkedit  = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 72, "__LINKEDIT", $link_vmaddr, $page_size, $link_fileoff, $page_size, 1, 1, 0, 0 );

        # LC_MAIN (Entry point offset)
        my $lc_main = pack( 'L L Q Q', 0x80000028, 24, $page_size, 0 );

        # LC_BUILD_VERSION (macOS 11.0)
        my $lc_build = pack( 'L L L L L L', 0x32, 24, 1, 0x000B0000, 0x000B0000, 0 );

        # LC_UUID
        my $lc_uuid = pack( 'L L a16', 0x1B, 24, pack( "H*", "C0FFEE" . "0" x 26 ) );

        # LC_LOAD_DYLINKER
        my $lc_dyld = pack( 'L L L a20', 0x0E, 32, 12, "/usr/lib/dyld" );

        # LC_LOAD_DYLIB
        my $lc_dylib = pack( 'L L L L L L a32', 0x0C, 56, 24, 2, 0x01000000, 0x01000000, "/usr/lib/libSystem.B.dylib" );

        # LC_SYMTAB (Points to start of __LINKEDIT so codesign safely bounds it)
        my $lc_symtab = pack( 'L L L L L L', 0x02, 24, $link_fileoff, 0, $link_fileoff, 0 );

        # LC_DYSYMTAB (Required safely zeroed metadata for dyld parsing)
        my $lc_dysymtab = pack( 'L L' . 'L' x 18, 0x0B, 80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 );

        # LC_DYLD_INFO_ONLY (Also bound safely to the __LINKEDIT to prevent bounds underflow)
        my $lc_dyld_info = pack( 'L L L L L L L L L L L L',
            0x80000022, 48, $link_fileoff, 0, $link_fileoff, 0, $link_fileoff, 0, $link_fileoff, 0, $link_fileoff, 0 );
        open my $fh, '>', $filename or die $!;
        binmode $fh;

        # Write exactly 760 bytes of load commands + 32 bytes of Mach-O Header
        print $fh $header, $lc_pagezero, $lc_text, $lc_data, $lc_linkedit, $lc_main, $lc_build, $lc_uuid, $lc_dyld, $lc_dylib, $lc_symtab,
            $lc_dysymtab, $lc_dyld_info;

        # Pad up to $page_size boundary. This strictly isolates the header from the code.
        print $fh ( "\0" x ( $page_size - ( length($header) + $sizeofcmds ) ) );
        print $fh $text_padded;             # Page 1
        print $fh $data_padded;             # Page 2
        print $fh ( "\0" x $page_size );    # Page 3 (Empty space for `codesign` to overwrite)
        close $fh;
        chmod 0755, $filename;
        if ( $^O eq 'darwin' ) {
            system("codesign --force --sign - \"$filename\" >/dev/null 2>&1");
        }
        return $filename;
    }
}
1
