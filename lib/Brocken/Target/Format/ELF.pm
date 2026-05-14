use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
#
class Brocken::Target::Format::ELF : isa(Brocken::Target::Format) {

    method write_bin ( $filename, $text, $data, $arch, $os = 'linux' ) {
        my $base        = 0x400000;
        my $text_off    = 0x1000;
        my $data_off    = 0x2000;
        my $machine     = ( $arch eq 'arm64' ) ? 183 : 62;
        my %osabis      = ( freebsd => 9, netbsd => 0, solaris => 6, openbsd => 0, dragonfly => 0 );
        my $osabi       = $osabis{$os} // 0;
        my $align       = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
        my $text_padded = $text . ( "\0" x ( $align->( length($text), 0x1000 ) - length($text) ) );
        my $data_padded = $data . ( "\0" x ( $align->( length($data), 0x1000 ) - length($data) ) );
        my $type        = 2;      # ET_EXEC
        my $elf_hdr     = pack(
            'A4 C C C C C x7 S S L Q Q Q L S S S S S S',
            "\x7fELF", 2, 1, 1,  $osabi, 0, $type, $machine, 1, $base + $text_off,
            64,        0, 0, 64, 56,     2, 0,     0,        0
        );
        my $ph_text = pack( 'LL Q Q Q Q Q Q', 1, 5, 0, $base, $base, $text_off + length($text_padded), $text_off + length($text_padded), 0x1000 );
        my $ph_data
            = pack( 'LL Q Q Q Q Q Q', 1, 6, $data_off, $base + $data_off, $base + $data_off, length($data_padded), length($data_padded), 0x1000 );
        open my $fh, '>', $filename or die $!;
        binmode $fh;
        my $ph_size = length($ph_text) + length($ph_data);
        my $pad     = $text_off - 64 - $ph_size;
        print $fh $elf_hdr, $ph_text, $ph_data, ( "\0" x $pad ) if $pad > 0;
        print $fh $text_padded, $data_padded;
        close $fh;
        chmod 0755, $filename;
        return $filename;
    }
}
1
