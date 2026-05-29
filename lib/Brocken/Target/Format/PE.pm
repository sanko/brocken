use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
#
class Brocken::Target::Format::PE : isa(Brocken::Target::Format) {

    method write_bin ( $filename, $text, $data, $arch, $os = 'win64' ) {
        my $fa          = 0x200;
        my $sa          = 0x1000;
        my $image_base  = hex '140000000';
        my $machine     = ( $arch eq 'arm64' ) ? 0xAA64 : 0x8664;
        my $align       = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
        my $text_padded = $text . ( "\0" x ( $align->( length($text), $fa ) - length($text) ) );
        if ( length($data) == 0 ) { $data = "\0" }
        my $data_padded = $data . ( "\0" x ( $align->( length($data), $fa ) - length($data) ) );
        my $text_rva    = $sa;
        my $data_rva    = $sa * 2;
        my $idata_rva   = $sa * 3;
        my @funcs       = qw[ExitProcess ExitThread GetStdHandle WriteFile CreateThread Sleep WaitForSingleObject];
        my $iat_size    = ( @funcs + 1 ) * 8;
        my $rva_iat     = $idata_rva;
        my $rva_ilt     = $rva_iat + $iat_size;
        my $rva_dir     = $rva_ilt + $iat_size;
        my $rva_dll     = $rva_dir + 40;
        my $rva_hn      = $rva_dll + 16;
        my $iat_data    = '';
        my $hn_data     = '';

        for my $fn (@funcs) {
            $iat_data .= pack( 'Q<', $rva_hn + length($hn_data) );
            my $hn_entry = pack( 'S<', 0 ) . $fn . "\0";
            $hn_entry .= "\0" if length($hn_entry) % 2 != 0;
            $hn_data  .= $hn_entry;
        }
        $iat_data .= pack( 'Q<', 0 );
        my $import_dir   = pack( 'L< L< L< L< L<', $rva_ilt, 0, 0, $rva_dll, $rva_iat ) . ( "\0" x 20 );
        my $idata_raw    = $iat_data . $iat_data . $import_dir . pack( 'a16', 'kernel32.dll' ) . $hn_data;
        my $idata_padded = $idata_raw . ( "\0" x ( $align->( length($idata_raw), $fa ) - length($idata_raw) ) );
        my $headers_bin  = pack( 'S< x58 L<', 0x5A4D, 0x80 ) . pack( 'a64', "This program cannot be run in DOS mode.\n\$" );
        my $file_hdr     = pack( 'S< S< L< L< L< S< S<', $machine, 3, time(), 0, 0, 240, 0x0022 );
        my $opt_hdr      = pack(
            'S< C C L< L< L< L< L< Q< L< L< S< S< S< S< S< S< L< L< L< L< S< S< Q< Q< Q< Q< L< L<',
            0x20B, 14,        0,         length($text_padded), length($data_padded) + length($idata_padded),
            0,     $text_rva, $text_rva, $image_base,          $sa, $fa, 6, 0, 0, 0, 6, 0, 0, $align->( $idata_rva + length($idata_padded), $sa ),
            $fa,   0,         3,         0x8140,               0x100000, 0x1000, 0x100000, 0x1000, 0, 16
        );
        my $data_dirs = pack( 'L< L<', 0, 0 ) . pack( 'L< L<', $rva_dir, 40 ) . ( pack( 'L< L<', 0, 0 ) x 14 );
        my $sec_text  = pack( 'a8 L< L< L< L< L< L< S< S< L<', '.text', length($text), $text_rva, length($text_padded), $fa, 0, 0, 0, 0, 0x60000020 );
        my $sec_data  = pack(
            'a8 L< L< L< L< L< L< S< S< L<',
            '.data', length($data), $data_rva, length($data_padded), $fa + length($text_padded),
            0,       0,             0,         0,                    0xC0000040
        );
        my $sec_idata = pack(
            'a8 L< L< L< L< L< L< S< S< L<',
            '.idata', length($idata_raw), $idata_rva, length($idata_padded), $fa + length($text_padded) + length($data_padded),
            0,        0,                  0,          0,                     0xC0000040
        );
        my $full_header = $headers_bin . pack( 'L<', 0x00004550 ) . $file_hdr . $opt_hdr . $data_dirs . $sec_text . $sec_data . $sec_idata;
        $full_header .= ( "\0" x ( $align->( length($full_header), $fa ) - length($full_header) ) );
        substr( $full_header, 0x80 + 4 + 20 + 60, 4, pack( 'L<', length($full_header) ) );
        open my $fh, '>', $filename or die $!;
        binmode $fh;
        print $fh $full_header, $text_padded, $data_padded, $idata_padded;
        close $fh;
        return $filename;
    }
}
1
