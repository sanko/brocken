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

        # OpenBSD uses OSABI 0 (SYSV). NetBSD uses 2. FreeBSD uses 9.
        my %osabis      = ( freebsd => 9, netbsd => 2, solaris => 6, openbsd => 0, dragonfly => 0 );
        my $osabi       = $osabis{$os} // 0;
        my $align_f     = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
        my $text_padded = $text . ( "\0" x ( $align_f->( length($text), 0x1000 ) - length($text) ) );
        my $data_padded = $data . ( "\0" x ( $align_f->( length($data), 0x1000 ) - length($data) ) );

        # Create Identification Note
        my $note_data = '';
        if ( $os eq 'openbsd' ) {

            # OpenBSD Note: Name="OpenBSD\0", Type=1 (NT_IDENT), Desc=0
            $note_data = pack( 'LLL', 8, 4, 1 ) . "OpenBSD\0" . pack( 'L', 0 );
        }
        elsif ( $os eq 'netbsd' ) {

            # NetBSD Note: Name="NetBSD\0\0", Type=1, Desc=Version
            $note_data = pack( 'LLL', 7, 4, 1 ) . "NetBSD\0\0" . pack( 'L', 900000000 );
        }
        my $num_ph = $note_data ? 3 : 2;
        my $type   = 2;                    # ET_EXEC

        # ELF Header
        # e_phnum updated to $num_ph
        my $elf_hdr = pack(
            'A4 C C C C C x7 S S L Q Q Q L S S S S S S',
            "\x7fELF", 2, 1, 1,  $osabi, 0,       $type, $machine, 1, $base + $text_off,
            64,        0, 0, 64, 56,     $num_ph, 0,     0,        0, 0
        );

        # PT_LOAD Text (Read + Execute)
        my $ph_text = pack( 'LL Q Q Q Q Q Q', 1, 5, 0, $base, $base, $text_off + length($text_padded), $text_off + length($text_padded), 0x1000 );

        # PT_LOAD Data (Read + Write)
        my $ph_data
            = pack( 'LL Q Q Q Q Q Q', 1, 6, $data_off, $base + $data_off, $base + $data_off, length($data_padded), length($data_padded), 0x1000 );

        # PT_NOTE
        my $ph_note = '';
        if ($note_data) {

            # Place the note immediately after the program headers
            my $note_file_off = 64 + ( $num_ph * 56 );
            $ph_note = pack( 'LL Q Q Q Q Q Q', 4, 4, $note_file_off, 0, 0, length($note_data), length($note_data), 0 );
        }
        open my $fh, '>', $filename or die $!;
        binmode $fh;
        my $headers_and_notes = $elf_hdr . $ph_text . $ph_data . $ph_note . $note_data;
        print $fh $headers_and_notes;

        # Ensure the first page is exactly 0x1000 bytes long before starting .text
        print $fh ( "\0" x ( $text_off - length($headers_and_notes) ) );
        print $fh $text_padded;
        print $fh $data_padded;
        close $fh;
        chmod 0755, $filename;
        return $filename;
    }
}
1
