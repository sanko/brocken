use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Converting an integer to a float.
#
# A computed integer reaching a float slot used to be refused outright, which
# was the right call: storing integer bits through a float slot is wrong for
# everything past 2**52, so an instruction or a diagnostic was needed and
# neither existed. Now there is an instruction, and the way to get the unsigned
# cases right without one is the interesting part of it.
#
# There is no unsigned convert on x86-64. `CVTSI2SD` is signed only, so a u32
# with the top bit set would come out negative. Rather than add a multi-
# instruction fixup, the source is widened to 64 bits first -- a u32 zero-
# extended into an i64 is a positive i64 and converts correctly, and a u8 or u16
# likewise. One signed instruction therefore covers every signed type and every
# unsigned type up to 32 bits.
#
# The values are chosen so that a re-interpretation cannot pass: 7 and -7 are
# not what any bit pattern reads back as, and 3000000000 is a u32 that is
# negative if read as i32 and far past 2**31 if read as i64. A conversion that
# did nothing at all would answer with those, and 0 for the small ones.
my $brocken = Brocken->new;
SKIP: {
    skip 'Not native', 20 unless $brocken->platform->is_native;
    for my $ftype (qw[f64 f32]) {

        # The largest integer the float type can hold exactly, which is not the
        # same on both: f64 has a 53-bit significand and f32 a 24-bit one, so
        # 2**31-1 is representable in the first and rounds in the second. Asking
        # f32 for it would be testing the float format, not the conversion.
        my $big = $ftype eq 'f64' ? 2147483647 : 16777215;
        is( convert_ok( $ftype, 'i64',  7,    7 ),   0, "native: $ftype 7 converts to i64" );
        is( convert_ok( $ftype, 'i64', -7,   -7 ),   0, "native: $ftype -7 converts to i64" );
        is( convert_ok( $ftype, 'i32',  7,    7 ),   0, "native: $ftype 7 converts to i32" );
        is( convert_ok( $ftype, 'i32', -7,   -7 ),   0, "native: $ftype -7 converts to i32" );
        is( convert_ok( $ftype, 'i32', $big, $big ), 0, "native: $ftype $big converts to i32" );
    }

    # The narrow signed types have to be widened with the sign, or a negative
    # value would widen to a large positive one.
    is( convert_ok( 'f64', 'i8',  -7, -7 ), 0, 'native: an i8 -7 widens with its sign' );
    is( convert_ok( 'f64', 'i16', -7, -7 ), 0, 'native: an i16 -7 widens with its sign' );
    is( convert_ok( 'f64', 'i32', -7, -7 ), 0, 'native: an i32 -7 widens with its sign' );

    # The unsigned cases, where a sign extension instead of a zero extension is
    # the whole difference between right and wrong.
    is( convert_ok( 'f64', 'u8',  200,        200 ),        0, 'native: a u8 widens with a zero' );
    is( convert_ok( 'f64', 'u16', 60000,      60000 ),      0, 'native: a u16 widens with a zero' );
    is( convert_ok( 'f64', 'u32', 3000000000, 3000000000 ), 0, 'native: a u32 past 2**31 converts' );
    is( convert_ok( 'f32', 'u32', 3000000000, 3000000000 ), 0, 'native: a u32 past 2**31 converts to f32' );

    # A computed source, so the conversion is not folded on the way in.
    is( param_ok(),   0, 'native: a converted integer parameter keeps its value' );
    is( chained_ok(), 0, 'native: int to float and back is consistent' );
}
done_testing;

# An integer of $itype converted to a $ftype and read back as an i64.  The
# expected value is compared after the conversion, so a float that lost the
# low bits of a large integer cannot pass by being close.
sub convert_ok {
    my ( $ftype, $itype, $value, $want ) = @_;
    my $src = <<"BROCKEN";
my $itype \$i = $value;
my $ftype \$f = \$i;
my i64 \$back = \$f;
if (\$back != $want) { return 1; }
return 0;
BROCKEN
    return run($src);
}

sub param_ok {
    my $src = <<'BROCKEN';
sub widen( i32 $i ) -> f64 {
    my f64 $f = $i;
    return $f;
}
if ( widen(7) != 7 ) { return 1; }
return 0;
BROCKEN
    return run($src);
}

# Both directions in one program, with the integer used as an integer first, so
# neither conversion can be folded out of the way.
sub chained_ok {
    my $src = <<'BROCKEN';
my i32 $i = 21;
my f64 $f = $i;
my i64 $j = $i * 2;
if ($j != 42) { return 1; }
if ($f != 21) { return 2; }
return 0;
BROCKEN
    return run($src);
}

sub run {
    my ($src)  = @_;
    my $module = Brocken::Compiler->new->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = $brocken->tmpdir . '/i2f' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    system $file;
    return $? >> 8;
}
