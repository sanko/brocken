use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::Format::PE : isa(Brocken::Target::Format) {

    method write_bin ( $filename, $text, $data, $arch, $os = 'win64', $edata = undef ) {
        my $fa           = 512;
        my $sa           = 4096;
        my $text_padded  = $text . ( "\x00" x ( ( $fa - length($text) % $fa ) % $fa ) );
        my $data_padded  = $data . ( "\x00" x ( ( $fa - length($data) % $fa ) % $fa ) );
        my $idata        = $self->_make_imports();
        my $idata_padded = $idata . ( "\x00" x ( ( $fa - length($idata) % $fa ) % $fa ) );
        my $edata_padded = '';
        if ($edata) {
            $edata_padded = $edata . ( "\x00" x ( ( $fa - length($edata) % $fa ) % $fa ) );
        }
        my $is_dll       = defined $edata && length($edata) > 0 ? 1 : 0;
        my $num_sections = $is_dll                              ? 4 : 3;

        # COFF header
        my $coff
            = pack( 'S< S< L< L< L< S< S<', ( $arch eq 'arm64' ? 0xAA64 : 0x8664 ), $num_sections, time(), 0, 0, 224, $is_dll ? 0x2102 : 0x0102 );

        # Data directories
        my $dirs = '';
        $dirs .= pack( 'L< L<', $is_dll ? 0x4000 : 0, $is_dll ? length($edata) : 0 );    # Export
        $dirs .= pack( 'L< L<', 0x3000,               length($idata) );                  # Import
        $dirs .= pack( 'L< L<', 0,                    0 ) x 14;

        # Optional header (96 + 128 = 224 bytes)
        my $opt = pack(
            'S< C C L< L< L< L< L< Q< L< L< S< S< S< S< S< S< L< L< L< L< S< S< Q< Q< Q< Q< L< L<',
            0x20B, 14,  0,   length($text_padded), length($data_padded) + length($idata_padded) + length($edata_padded),
            0,     $sa, $sa, 0x1000, $sa, $fa, 6, 0, 0, 0, 6, 0, 0, $sa * 5, $fa, 0, 3, 0x8140, 0x100000, 0x1000, 0x100000, 0x1000, 0, 16
            ) .
            $dirs;

        # Sections
        my $sections = '';

        # .text at file offset 0x200, RVA 0x1000
        # Section headers - exactly 40 bytes each using single pack
        $sections = pack( 'a8 L< L< L< L< L< L< S< L<', '.text', length($text), $sa, length($text_padded), 0x200, 0, 0, 0x60000020 );
        $sections .= pack( 'a8 L< L< L< L< L< L< S< L<', '.data',  length($data),  $sa * 2, length($data_padded),  0x400, 0, 0, 0xC0000040 );
        $sections .= pack( 'a8 L< L< L< L< L< L< S< L<', '.idata', length($idata), 0x3000,  length($idata_padded), 0x600, 0, 0, 0xC0000040 );
        if ($is_dll) {
            $sections .= pack( 'a8 L< L< L< L< L< L< S< L<', '.edata', length($edata), 0x4000, length($edata_padded), 0x800, 0, 0, 0x40000040 );
        }

        # Build header: DOS stub (64) + PE offset (4) + PE sig (4) + COFF (20) + Opt (224) + Sections
        my $header = '';
        $header .= pack( 'S< x58 L<', 0x5A4D, 0x80 );      # DOS header, PE at 0x80
        $header .= "\x00" x ( 0x80 - length($header) );    # Pad to 0x80
        $header .= "PE\x00\x00";
        $header .= $coff;
        $header .= $opt;
        $header .= $sections;

        # Pad header to 0x200 (512 bytes)
        $header .= "\x00" x ( 0x200 - length($header) );

        # Write file
        open( my $fh, '>', $filename ) or die "Cannot create $filename: $!";
        binmode $fh;
        print $fh $header;

        # Pad from end of header to start of .text (0x200)
        print $fh "\x00" x ( 0x200 - length($header) );
        print $fh $text_padded;

        # Pad to 0x400
        my $pos = 0x200 + length($text_padded);
        print $fh "\x00" x ( 0x400 - $pos ) if $pos < 0x400;
        print $fh $data_padded;

        # Pad to 0x600
        $pos = 0x400 + length($data_padded);
        print $fh "\x00" x ( 0x600 - $pos ) if $pos < 0x600;
        print $fh $idata_padded;
        if ($edata_padded) {

            # Pad to 0x800
            $pos = 0x600 + length($idata_padded);
            print $fh "\x00" x ( 0x800 - $pos ) if $pos < 0x800;
            print $fh $edata_padded;
        }
        close $fh;
        return $filename;
    }

    method _make_imports () {
        my $rva_base = 0x3000;

        # Import Directory Table
        my $dir = pack( 'L<', $rva_base + 20 );    # ILT
        $dir .= pack( 'L<', 0 );                   # Time
        $dir .= pack( 'L<', 0 );                   # Forward
        $dir .= pack( 'L<', $rva_base + 40 );      # DLL name
        $dir .= pack( 'L<', $rva_base );           # IAT

        # Import Lookup Table
        my $ilt = pack( 'L<', $rva_base + 48 );    # Hint/Name
        $ilt .= pack( 'L<', 0 );

        # DLL Name
        my $name = "kernel32.dll\x00";

        # Hint/Name (first import)
        my $hint = pack( 'S<', 0 ) . "GetStdHandle\x00";
        return $dir . $ilt . $hint . $name;
    }

    method write_lib ( $filename, $text, $data, $arch, $os, $exports ) {
        my @names = sort keys %$exports;
        my $num   = scalar @names;
        if ( $num == 0 ) {
            return $self->write_bin( $filename, $text, $data, $arch, $os, undef );
        }

        # Build export directory
        my $base_rva = 0x4000;

        # String table starts after header + tables
        my $str_base = $base_rva + 40 + ( $num * 10 );
        my $dll_name = "pulse.dll\x00";
        my $str_tab  = $dll_name;
        my $eat      = '';
        my $npt      = '';
        my $ot       = '';
        for my $i ( 0 .. $#names ) {
            my $offset = length($str_tab);
            $eat     .= pack( 'L<', 0x1000 + $exports->{ $names[$i] } );    # Function RVA (in .text)
            $npt     .= pack( 'L<', $str_base + $offset );
            $ot      .= pack( 'S<', $i );
            $str_tab .= $names[$i] . "\x00";
        }
        my $edata = pack(
            'L< L< S< S< L< L< L< L< L< L< L<', 0, 0, 0, 0, $str_base,      # DLL name RVA
            1,                                                              # Ordinal base
            $num, $num,                                                     # Count
            $base_rva + 40,                                                 # EAT
            $base_rva + 40 + ( $num * 4 ),                                  # NPT
            $base_rva + 40 + ( $num * 8 )                                   # OT
        ) . $eat . $npt . $ot . $str_tab;
        return $self->write_bin( $filename, $text, $data, $arch, $os, $edata );
    }
}
1;
