use v5.38;
open my $fh, "<:raw", $ARGV[0] or die "$!";
my $data;
read $fh, $data, 16384;
close $fh;
my $pe_off       = unpack( "V", substr( $data, 0x3C,             4 ) );
my $num_sects    = unpack( "v", substr( $data, $pe_off + 4 + 2,  2 ) );
my $opt_hdr_size = unpack( "v", substr( $data, $pe_off + 4 + 16, 2 ) );
my $sect_off     = $pe_off + 4 + 20 + $opt_hdr_size;

# PE32+ optional header layout: AddressOfEntryPoint is at +16 from optional header start
my $opt_start  = $pe_off + 4 + 20;
my $entry      = unpack( "V", substr( $data, $opt_start + 16, 4 ) );
my $image_base = unpack( "Q", substr( $data, $opt_start + 24, 8 ) );
printf "ImageBase: 0x%X, Entry RVA: 0x%X\n", $image_base, $entry;
for my $i ( 0 .. $num_sects - 1 ) {
    my $s    = substr( $data, $sect_off + $i * 40, 40 );
    my $name = substr( $s,    0,                   8 );
    $name =~ s/\x00//g;
    my ( $vs, $va, $rs, $roff ) = unpack( "V4", substr( $s, 8, 16 ) );
    printf "Section '$name': VA=0x%X VSize=0x%X RawOff=0x%X RawSize=0x%X\n", $va, $vs, $roff, $rs;
    if ( $rs > 0 && $roff > 0 ) {
        my $len      = ( $rs < 256 ? $rs : 256 );
        my $sec_data = substr( $data, $roff, $len );
        my $size     = length($sec_data);
        printf "  Raw data at file off 0x%X (%d bytes):\n", $roff, $size;
        for ( my $j = 0; $j < $size; $j += 16 ) {
            my @b = unpack( "C*", substr( $sec_data, $j, ( $size - $j < 16 ? $size - $j : 16 ) ) );
            printf "    %04X: %s\n", $j, join( " ", map { sprintf( "%02X", $_ ) } @b );
        }
    }
}
