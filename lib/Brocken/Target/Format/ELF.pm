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
        if ( $os eq 'openbsd' ) {
            $note_data = pack( 'LLL', 8, 4, 1 ) . "OpenBSD\0" . pack( 'L', 0 );
        }
        elsif ( $os eq 'netbsd' ) {
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

        # PT_LOAD (RX)
        my $ph_text = pack( 'LL Q Q Q Q Q Q', 1, 5, 0, $base, $base, $text_off + length($text_padded), $text_off + length($text_padded), 0x1000 );

        # PT_LOAD (RW)
        my $ph_data
            = pack( 'LL Q Q Q Q Q Q', 1, 6, $data_off, $base + $data_off, $base + $data_off, length($data_padded), length($data_padded), 0x1000 );

        # PT_NOTE
        my $ph_note = '';
        if ($note_data) {
            my $note_file_off = 64 + ( $num_ph * 56 );
            $ph_note = pack( 'LL Q Q Q Q Q Q', 4, 4, $note_file_off, 0, 0, length($note_data), length($note_data), 0 );
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
}
1
