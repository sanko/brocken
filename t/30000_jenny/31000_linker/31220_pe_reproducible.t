use v5.42;
use Test2::V0 '!subtest';
use blib;
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Reproducible linking: compiling the same module twice must produce byte-identical output.
#
# The COFF File Header carries a TimeDateStamp, and the PE linker used to fill it from time().  Two links of the same
# module a second apart therefore differed, which is the "Nondeterministic Codegen" item in TODO section 1.  ELF,
# Mach-O, and Wasm write no timestamp, so PE is now brought in line: the stamp comes from
# Linker::effective_timestamp, which prefers an explicit set_timestamp, then SOURCE_DATE_EPOCH, then the epoch.

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

sub link_pe {
    my ($out) = @_;
    my $linker = Brocken::Jenny::Linker::PE->new();
    $linker->write_executable( $out, $bytes, $platform );
    open my $fh, '<:raw', $out or die "$out: $!";
    my $bin = do { local $/; <$fh> };
    close $fh;
    return $bin;
}

local $ENV{SOURCE_DATE_EPOCH};
delete $ENV{SOURCE_DATE_EPOCH};

my $out_a = $brocken->tmpdir . '/repro_a.exe';
my $out_b = $brocken->tmpdir . '/repro_b.exe';
my $bin_a = link_pe($out_a);
my $bin_b = link_pe($out_b);

is( length($bin_a), length($bin_b), 'two links of the same module produce the same length' );
is( $bin_a, $bin_b, 'two links of the same module are byte-identical' );
is( coff_timestamp($bin_a), 0, 'default COFF TimeDateStamp is the epoch, not wall-clock time' );

# SOURCE_DATE_EPOCH overrides the default.
$ENV{SOURCE_DATE_EPOCH} = 1234567890;
my $bin_c = link_pe( $brocken->tmpdir . '/repro_c.exe' );
is( coff_timestamp($bin_c), 1234567890, 'SOURCE_DATE_EPOCH is written into the COFF TimeDateStamp' );
isnt( $bin_c, $bin_a, 'a different timestamp changes the image' );

# The string "0" is a valid stamp and must not be mistaken for "unset".
$ENV{SOURCE_DATE_EPOCH} = 0;
my $bin_d = link_pe( $brocken->tmpdir . '/repro_d.exe' );
is( coff_timestamp($bin_d), 0, 'SOURCE_DATE_EPOCH=0 is honored rather than treated as unset' );

# An explicit set_timestamp beats the environment.
{
    my $linker = Brocken::Jenny::Linker::PE->new();
    $linker->set_timestamp(4242);
    is( $linker->effective_timestamp, 4242, 'set_timestamp overrides SOURCE_DATE_EPOCH' );
}

unlink grep { -e } $out_a, $out_b, $brocken->tmpdir . '/repro_c.exe', $brocken->tmpdir . '/repro_d.exe';
done_testing;
