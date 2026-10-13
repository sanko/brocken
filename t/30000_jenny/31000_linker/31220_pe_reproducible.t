use v5.42;
use Test2::V0 '!subtest';
use blib;
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# PE reproducibility.
#
# The COFF File Header carries a build timestamp, and the PE linker fills it with the wall clock.  A PE image is
# therefore time-varying from one link to the next; ELF, Mach-O, and Wasm write no timestamp at all.  Pinning
# SOURCE_DATE_EPOCH (or calling set_timestamp) is what makes a link reproducible, on PE and, for a uniform recipe,
# on every target.

# COFF File Header TimeDateStamp: e_lfanew lives at 0x3C; then the "PE\0\0" signature (4 bytes); then the COFF header,
# whose first three fields are Machine (2), NumberOfSections (2), and TimeDateStamp (4).
sub coff_timestamp {
    my ($bin) = @_;
    my $e_lfanew = unpack( 'V', substr( $bin, 0x3C, 4 ) );
    return unpack( 'V', substr( $bin, $e_lfanew + 8, 4 ) );
}

my $brocken  = Brocken->new();
my $platform = $brocken->platform;

my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
my $builder = Brocken::Lindsay::IR::Builder->new();
$builder->position_at_end( $func->append_block('entry') );
$builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
my $bytes = $brocken->codegen->emit_function($func);

my @files;
sub link_pe {
    my ($name) = @_;
    my $out = $brocken->tmpdir . '/' . $name;
    push @files, $out;
    my $linker = Brocken::Jenny::Linker::PE->new();
    $linker->write_executable( $out, $bytes, $platform );
    open my $fh, '<:raw', $out or die "$out: $!";
    my $bin = do { local $/; <$fh> };
    close $fh;
    return $bin;
}

# With no SOURCE_DATE_EPOCH the linker stamps the current time: the image is not reproducible, and the stamp is a real
# timestamp rather than a fabricated epoch.
{
    local $ENV{SOURCE_DATE_EPOCH};
    delete $ENV{SOURCE_DATE_EPOCH};
    my $bin   = link_pe('repro_now.exe');
    my $stamp = coff_timestamp($bin);
    ok( $stamp > 0, 'PE TimeDateStamp is a real timestamp when SOURCE_DATE_EPOCH is unset' );
    ok( abs( $stamp - time() ) <= 10, 'PE TimeDateStamp matches the current wall clock' );
}

# SOURCE_DATE_EPOCH pins the stamp, which makes repeated links byte-identical.
{
    local $ENV{SOURCE_DATE_EPOCH} = 1234567890;
    my $a = link_pe('repro_a.exe');
    my $b = link_pe('repro_b.exe');
    is( coff_timestamp($a), 1234567890, 'SOURCE_DATE_EPOCH is written into the COFF TimeDateStamp' );
    is( $a, $b, 'links are byte-identical under a fixed SOURCE_DATE_EPOCH' );
}

# A stamp of exactly 0 is honored, not mistaken for "unset".
{
    local $ENV{SOURCE_DATE_EPOCH} = 0;
    my $bin = link_pe('repro_zero.exe');
    is( coff_timestamp($bin), 0, 'SOURCE_DATE_EPOCH=0 is honored rather than treated as unset' );
}

# An explicit set_timestamp beats the environment.
{
    local $ENV{SOURCE_DATE_EPOCH} = 999;
    my $linker = Brocken::Jenny::Linker::PE->new();
    $linker->set_timestamp(4242);
    is( $linker->effective_timestamp, 4242, 'set_timestamp overrides SOURCE_DATE_EPOCH' );
}

unlink grep { -e } @files;
done_testing;
