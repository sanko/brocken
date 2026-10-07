use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use Blib;
use Brocken;
use Brocken::Jenny::Linker::PE;

subtest 'long COFF section names get their string table below debug level 5' => sub {
    my $brocken  = Brocken->new();
    my $platform = $brocken->platform;
    my $name     = 'very_long_debug_section_name_xyz';
    my $linker   = Brocken::Jenny::Linker::PE->new();
    $linker->set_debug_level(1);
    $linker->set_debug_data( { $name => pack( 'N', 0xDEADBEEF ) } );

    my $output_file = $brocken->tmpdir . '/pe_strtab_test.exe';
    $linker->write_executable( $output_file, "\xC3", $platform );

    open my $fh, '<:raw', $output_file or die "open $output_file: $!";
    my $bin;
    { local $/; $bin = <$fh> }
    close $fh;

    # The string table is the last thing the writer emits.
    my $payload = pack( 'V', 5 + length($name) ) . $name . "\0";
    is( substr( $bin, length($bin) - length($payload), length($payload) ), $payload, 'the string table is appended even with no COFF symbol table' );

    # The long section header must reference it with a /N offset that actually resolves back to the name.
    my $pe_off = unpack( 'V', substr( $bin, 0x3C, 4 ) );
    my $num_secs = unpack( 'v', substr( $bin, $pe_off + 4 + 2, 2 ) );
    my $opt_size = unpack( 'v', substr( $bin, $pe_off + 4 + 16, 2 ) );
    my $sec0     = $pe_off + 4 + 20 + $opt_size;
    my $found;
    for my $i ( 0 .. $num_secs - 1 ) {
        my $sec    = substr( $bin, $sec0 + 40 * $i, 40 );
        my $namefd = substr( $sec, 0, 8 );
        if ( $namefd =~ m{^/(\d+)\0} ) {
            my $st_off = length($bin) - length($payload);
            $found = substr( $bin, $st_off + $1, length($name) );
            last;
        }
    }
    is $found, $name, 'the /N offset in the section header resolves to the long name in the string table';

    unlink $output_file;
};

done_testing;