use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
#
class Brocken::Target::Format::ELF : isa(Brocken::Target::Format) {

    method write_bin ( $filename, $text, $data, $arch, $os = 'linux' ) {
        my $base     = 0x400000;
        my $text_off = 0x1000;
        my $data_off = 0x2000;
        my $machine  = ( $arch eq 'arm64' ) ? 183 : 62;

        # Comprehensive OSABI Map
        my %osabis = (
            linux     => 0,
            freebsd   => 9,
            netbsd    => 2,
            solaris   => 6,
            openbsd   => 0,    # OpenBSD prefers 0 + Note
            dragonfly => 0     # DragonFly prefers 0 + Note
        );
        my $osabi       = $osabis{$os} // 0;
        my $align_f     = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
        my $text_padded = $text . ( "\0" x ( $align_f->( length($text), 0x1000 ) - length($text) ) );
        my $data_padded = $data . ( "\0" x ( $align_f->( length($data), 0x1000 ) - length($data) ) );

        # Generate Identification Notes for BSDs
        my $note_data = '';
        # Note: Some OSes like OpenBSD may have issues with custom note sections
        if ( $os eq 'netbsd' ) {
            $note_data = pack( 'LLL', 7, 4, 1 ) . "NetBSD\0\0" . pack( 'L', 900000000 );
        }
        elsif ( $os eq 'freebsd' ) {

            # Namesz=8, Descsz=4, Type=1 (ABI_TAG)
            $note_data = pack( 'LLL', 8, 4, 1 ) . "FreeBSD\0" . pack( 'L', 1400000 );    # Ver 14.0
        }
        elsif ( $os eq 'dragonfly' ) {

            # Namesz=10, Descsz=4, Type=1
            $note_data = pack( 'LLL', 10, 4, 1 ) . "DragonFly\0\0" . pack( 'L', 0 );
        }
        my $num_ph = $note_data ? 3 : 2;

        # ELF Header
        my $elf_hdr = pack(
            'A4 C C C C C x7 S S L Q Q Q L S S S S S S',
            "\x7fELF", 2, 1, 1,  $osabi, 0,       2, $machine, 1, $base + $text_off,
            64,        0, 0, 64, 56,     $num_ph, 0, 0,        0, 0
        );

        # PT_LOAD (RX) - file offset points to text start, vaddr aligned to entry point
        my $ph_text
            = pack( 'LL Q Q Q Q Q Q', 1, 5, $text_off, $base + $text_off, $base + $text_off, length($text_padded), length($text_padded), 0x1000 );

        # PT_LOAD (RW)
        my $ph_data
            = pack( 'LL Q Q Q Q Q Q', 1, 6, $data_off, $base + $data_off, $base + $data_off, length($data_padded), length($data_padded), 0x1000 );

        # PT_NOTE - vaddr must match p_offset for proper loading
        my $ph_note = '';
        if ($note_data) {
            my $note_file_off = 64 + ( $num_ph * 56 );
            $ph_note = pack( 'LL Q Q Q Q Q Q', 4, 4, $note_file_off, $note_file_off, $note_file_off, length($note_data), length($note_data), 4 );
        }
        open my $fh, '>', $filename or die $!;
        binmode $fh;
        my $header_block = $elf_hdr . $ph_text . $ph_data . $ph_note . $note_data;
        print $fh $header_block;
        print $fh ( "\0" x ( $text_off - length($header_block) ) );
        print $fh $text_padded, $data_padded;
        close $fh;
        chmod 0755, $filename;
        return $filename;
    }

    method write_lib ( $filename, $text, $data, $arch, $os, $exports ) {
        my $base        = 0x400000;
        my $text_off    = 0x1000;
        my $dyn_off     = 0x3000;
        my $align_f     = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
        my $text_padded = $text . ( "\0" x ( $align_f->( length($text), 0x1000 ) - length($text) ) );
        my $data_padded = $data . ( "\0" x ( $align_f->( length($data), 0x1000 ) - length($data) ) );
        my $machine     = ( $arch eq 'arm64' ) ? 183 : 62;
        my %osabis      = ( linux => 0, freebsd => 9, netbsd => 2, solaris => 6, openbsd => 0, dragonfly => 0 );
        my $osabi       = $osabis{$os} // 0;
        my $num_exports = scalar keys %$exports;
        my $dynsym_size = 24 * ( $num_exports + 1 );
        my $dynstr      = "\0";
        my %dynstr_offs;

        for my $name ( sort keys %$exports ) {
            $dynstr_offs{$name} = length($dynstr);
            $dynstr .= $name . "\0";
        }
        my $dynsym = "\0" x 24;
        for my $name ( sort keys %$exports ) {
            $dynsym .= pack( 'L C C S Q Q', $dynstr_offs{$name}, 0x12, 0, 12, $base + $text_off + $exports->{$name}, 0 );
        }
        my $dynsec_off  = length($text_padded) + length($data_padded);
        my $dynsec_size = $dynsym_size + length($dynstr);
        my $dynsym_off  = $dynsec_off;
        my $dynstr_off  = $dynsec_off + $dynsym_size;
        my $elf_hdr     = pack(
            'A4 C C C C C x7 S S L Q Q Q L S S S S S S',
            "\x7fELF", 2, 1, 1,  $osabi, 0, 3, $machine, 1, $base + $text_off,
            64,        0, 0, 64, 56,     3, 0, 0,        0
        );
        my $ph_text = pack( 'LL Q Q Q Q Q Q', 1, 5, 0, $base, $base, $text_off + length($text_padded), $text_off + length($text_padded), 0x1000 );
        my $ph_data = pack( 'LL Q Q Q Q Q Q',
            1, 6,
            $dyn_off - 0x1000,
            $base + $dyn_off - 0x1000,
            $base + $dyn_off - 0x1000,
            length($data_padded), length($data_padded), 0x1000 );
        my $ph_dyn = pack( 'LL Q Q Q Q Q Q', 6, 1, $dynsec_off, $base + $dynsec_off, $base + $dynsec_off, $dynsec_size, $dynsec_size, 0x1000 );
        my $sh_off = 64 + 3 * 56;
        open my $fh, '>', $filename or die $!;
        binmode $fh;
        print $fh $elf_hdr, $ph_text, $ph_data, $ph_dyn;
        print $fh ( "\0" x ( $text_off - 64 - 3 * 56 ) );
        print $fh $text_padded, $data_padded;
        print $fh $dynsym;
        print $fh $dynstr;
        my $shdr_off = tell($fh);
        print $fh ( "\0" x 64 );
        print $fh pack( 'LLQQQQLLQQ', 0,  0, 0, 0,                         0,                 0,                    0, 0, 0,  0 );
        print $fh pack( 'LLQQQQLLQQ', 11, 1, 6, $base + 0x1000,            0x1000,            length($text),        0, 0, 16, 0 );
        print $fh pack( 'LLQQQQLLQQ', 14, 1, 6, $base + $dyn_off - 0x1000, $dyn_off - 0x1000, length($data_padded), 0, 0, 32, 0 );
        print $fh pack( 'LLQQQQLLQQ', 0,  0, 0, 0,                         0,                 0,                    0, 0, 0,  0 );
        seek( $fh, 40, 0 );
        print $fh pack( 'Q', $sh_off );
        seek( $fh, 60, 0 );
        print $fh pack( 'S', 4 );
        seek( $fh, 62, 0 );
        print $fh pack( 'S', 0 );
        close $fh;
        chmod 0755, $filename;
        return $filename;
    }
}
1
