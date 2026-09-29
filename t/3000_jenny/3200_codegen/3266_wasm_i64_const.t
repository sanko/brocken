use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use File::Spec ();
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];
use Test2::Tools::Brocken qw(temp_path);

# i64.const immediates are signed LEB128. The encoder used to reach for
# POSIX::floor($v / 128), which divides through a double: a double carries 53
# bits of mantissa, so every value past 2**53 was rounded before the next group
# was taken. INT64_MAX came out as ff 80 80 80 80 80 80 80 80 01 -- one group
# too many, and the validator rejected it outright as an over-long var_i64, so
# a module mentioning that constant would not compile at all. Anything in the
# 2**53..2**63 range that did compile came back with the wrong value.
#
# These cases are checked by running the module, not by decoding the bytes: a
# decoder written next to the encoder is exactly the thing that agrees with a
# broken encoder.
my $i64      = Brocken::Lindsay::IR::Type::i64();
my $K        = sub { Brocken::Lindsay::IR::Constant->new(@_) };
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');

sub build {
    my ($value) = @_;
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i64 );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret( $K->( type => $i64, value => $value ) );
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $bytes   = $codegen->emit_function($func);
    my $out     = temp_path('sleb') . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $out, $bytes, $platform );
    return $out;
}
my $devnull       = File::Spec->devnull;
my $have_wasmtime = (`wasmtime --version 2>$devnull`) ? 1 : 0;

# Runs main() and returns the value wasmtime printed on stdout, or undef when
# the module was rejected. stderr is discarded because --invoke emits an
# unrelated experimental warning there. Redirect to the devnull path rather
# than to an open filehandle: an interpolated filehandle stringifies to
# "GLOB(0x...)", and the shell then creates a file by that name in the cwd.
sub run {
    my ($path) = @_;
    my $out = `wasmtime run --invoke main "$path" 2>$devnull`;
    chomp $out;
    return $out =~ /^\s*(-?\d+)\s*$/ ? $1 + 0 : undef;
}

# 2**53 is the first magnitude a double can no longer represent exactly, so
# these straddle the boundary the old division lost. Cases are written as
# literal decimals: a bare 64-bit hex literal exceeds IV range and lands in
# Perl as an NV, so 0xF0F0F0F0F0F0F0F0 would silently become a float and the
# comparison itself would be inexact.
my @cases = (
    [ 'zero'  => 0 ], [ 'small' => 42 ], [ 'negative' => -13 ], [ '2**31' => 2147483648 ], [ '2**32 - 1' => 4294967295 ], [ '2**32' => 4294967296 ],
    [ '2**40' => 1099511627776 ], [ '2**53 - 1' => 9007199254740991 ], [ '2**53' => 9007199254740992 ], [ '2**53 + 1' => 9007199254740993 ],
    [ '2**62'         =>  4611686018427387904 ], [ 'INT64_MAX' =>  9223372036854775807 ], [ 'INT64_MIN'     => -9223372036854775808 ],
    [ 'INT64_MIN + 1' => -9223372036854775807 ], [ '-2**62'    => -4611686018427387904 ], [ 'high bits set' => -1 ],

    # -(2**64 - 0x0F0F0F0F0F0F0F0): the top bit set, so negative, with a
    # repeating nibble pattern that would be obvious if the low groups were
    # dropped or rounded.
    [ '0xF0F0..F0F0 as i64' => -1085102592571150096 ],

    # -(2**64 - 0xFFFFFFFF00000000): only the top 32 bits set.
    [ '0xFFFF..0000 as i64' => -4294967296 ],
);
SKIP: {
    skip 'wasmtime is not installed', scalar @cases unless $have_wasmtime;
    for my $c (@cases) {
        my ( $label, $value ) = @$c;
        my $path = eval { build($value) };
        if ( !defined $path ) { fail("$label: build died: $@"); next }
        my $got = run($path);
        is $got, $value, "i64.const $label";
        unlink $path if -e $path;
    }
}
done_testing;
