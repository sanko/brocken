use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::Format::PE : isa(Brocken::Target::Format) {

    method write_bin ( $filename, $text, $data, $arch, $os = 'win64', $edata = undef ) {
        my $fa          = 512;
        my $sa          = 4096;
        my $image_base  = 0x1000;
        my $machine     = ( $arch eq 'arm64' ) ? 0xAA64 : 0x8664;
        my $align       = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
        
        # Pad everything to 512-byte alignment  
        my $text_padded = $text . ( "\0" x ( $align->( length($text), $fa ) - length($text) ) );
        my $data_padded = $data . ( "\0" x ( $align->( length($data), $fa ) - length($data) ) );
        my $edata_padded = $edata ? $edata . ( "\0" x ( $align->( length($edata), $fa ) - length($edata) ) ) : '';

        # RVAs
        my $text_rva     = $sa;
        my $data_rva     = $sa * 2;
        my $idata_rva    = $sa * 3;
        my $edata_rva    = $sa * 4;
        
        # Import table - minimal placeholder
        my $idata_raw = pack('L< L< L< L< L<', $idata_rva + 16, 0, 0, $idata_rva + 32, $idata_rva) . 
                        (pack('L<',0) x 5) . 
                        pack('a16', 'KERNEL32.dll') . 
                        (pack('C',0) x 16);
        my $idata_padded = $idata_raw . ( "\0" x ( $align->( length($idata_raw), $fa ) - length($idata_raw) ) );

        # DLL config
        my $is_dll = defined $edata ? 1 : 0;
        my $characteristics = $is_dll ? 0x2102 : 0x0102;
        my $num_sections = 3;
        
        # COFF header (20 bytes)
        my $coff = pack('S< S< L< L< L< S< S<', 
            $machine, $num_sections, time(), 0, 0, 224, $characteristics);
        
        # Data directories - export and import
        my $export_rva = $is_dll ? $edata_rva : 0;
        my $export_size = $is_dll && defined $edata ? length($edata) : 0;
        
        my $data_dirs = pack('L< L<', $export_rva, $export_size);
        $data_dirs .= pack('L< L<', $idata_rva, length($idata_raw));
        $data_dirs .= pack('L< L<', 0, 0) x 14;
        
        # Optional header (96 bytes base + 128 bytes dirs = 224 total)
        my $size_of_image = $edata_rva + length($edata_padded) + $sa;
        $size_of_image = $align->($size_of_image, $sa);
        
        my $opt = pack('S< C C L< L< L< L< L< Q< L< L< S< S< S< S< S< S< L< L< L< L< S< S< Q< Q< Q< Q< L< L<',
            0x20B, 14, 0, 
            length($text_padded),
            length($data_padded) + length($idata_padded) + length($edata_padded),
            0, $text_rva, $text_rva,
            $image_base, $sa, $fa,
            6, 0, 0, 0, 6, 0, 0,
            $size_of_image,
            $fa, 0, 3, 0x8140, 0x100000,
            0x1000, 0x100000, 0x1000, 0, 16
        ) . $data_dirs;
        
        # Section headers - 3 sections * 40 bytes = 120 bytes
        my $sections = '';
        
        # .text section
        $sections .= pack('a8 L< L< L< L< L< L< L< S< S< L<',
            '.text', length($text), $text_rva, length($text_padded),
            512, 0, 0, 0, 0, 0x60000020);
            
        # .data section
        $sections .= pack('a8 L< L< L< L< L< L< L< S< S< L<',
            '.data', length($data), $data_rva, length($data_padded),
            512 + length($text_padded), 0, 0, 0, 0, 0xC0000040);
            
        # .idata section (or .edata if DLL)
        if ($is_dll) {
            # Combine idata and edata into one section
            my $rdata_rva = $sa * 3;
            my $rdata_size = length($idata_padded) + length($edata_padded);
            my $rdata_file = 512 + length($text_padded) + length($data_padded);
            $sections .= pack('a8 L< L< L< L< L< L< L< S< S< L<',
                '.rdata', $rdata_size, $rdata_rva, $rdata_size,
                $rdata_file, 0, 0, 0, 0, 0x40000040);
        } else {
            $sections .= pack('a8 L< L< L< L< L< L< L< S< S< L<',
                '.idata', length($idata_raw), $idata_rva, length($idata_padded),
                512 + length($text_padded) + length($data_padded), 0, 0, 0, 0, 0xC0000040);
        }
        
        # Build full header
        my $dos_stub = "\x00" x 64;
        my $pe_sig = "PE\x00\x00";
        
        my $header = $dos_stub . pack('L<', 0x80) . $pe_sig . $coff . $opt . $sections;
        
        # Pad to 512 bytes
        $header .= "\x00" x (512 - length($header));
        
        # Write file
        open my $fh, '>', $filename or die $!;
        binmode $fh;
        print $fh $header;
        print $fh $text_padded;
        print $fh $data_padded;
        if ($is_dll) {
            print $fh $idata_padded;
            print $fh $edata_padded;
        } else {
            print $fh $idata_padded;
        }
        close $fh;
        return $filename;
    }
    
    method write_lib ( $filename, $text, $data, $arch, $os, $exports ) {
        my $sa = 4096;
        my $edata_rva = $sa * 4;
        my @names = sort keys %$exports;
        my $num = scalar @names;
        
        return $self->write_bin($filename, $text, $data, $arch, $os, '');
    }
}
1;