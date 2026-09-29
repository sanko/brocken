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

# Converting a float to an integer.
#
# Assigning a float to an integer declaration used to store the IEEE bit
# pattern into the integer instead of converting it. Nothing complained and
# nothing was obviously wrong at the point of use either, because the bits of a
# small float and a small integer disagree only in the high bytes: 3.0f64 is
# 0x4008000000000000, whose low byte is zero, so a program that read the value
# back as an integer saw 0.
#
#     my f64 $h = 7; my f64 $t = $h / 2;   # 3.5
#     my i64 $i = $t;                       # 3, was 0
#
# The tests below therefore check the value the program can actually observe,
# not the encoding, and each one returns its own exit code so a failure says
# which conversion went wrong.
#
# Every case uses a fraction, because a whole number converts to something that
# is easy to get right by accident: a bit pattern truncated to its low bits can
# look plausible. `7 / 2` is written as a division because decimal literals are
# a separate gap of their own, and `0 - $h` is written as a subtraction for the
# same reason, since `-7` as a float initialiser is refused.
my $brocken = Brocken->new;
SKIP: {
    skip 'Not native', 16 unless $brocken->platform->is_native;
    for my $ftype (qw[f64 f32]) {
        for my $itype (qw[i32 i64]) {
            is( truncate_ok( $ftype, $itype, 7,  3 ), 0, "native: $ftype 3.5 converts to $itype as 3" );
            is( truncate_ok( $ftype, $itype, 9,  4 ), 0, "native: $ftype 4.5 converts to $itype as 4" );
            is( truncate_ok( $ftype, $itype, 7, -3 ), 0, "native: $ftype -3.5 converts to $itype as -3, not -4" );
        }
    }

    # A float parameter is converted after the call has put it in a register,
    # which is a different read path from a local.
    is( param_ok( 'f64', 'i64' ), 0, 'native: a converted f64 parameter keeps its value' );
    is( param_ok( 'f32', 'i32' ), 0, 'native: a converted f32 parameter keeps its value' );

    # Converting the result of a call goes through the same path as any other
    # computed value.
    is( call_ok(), 0, 'native: converting a call result truncates toward zero' );

    # An integer local fed to a float local first, so the conversion cannot be
    # folded away and both halves of the round trip stay live.
    is( chained_ok(), 0, 'native: a chain of float and integer conversions is consistent' );
}
done_testing;

# A half-integer converted to an integer.  `$num` over two makes the value and
# `$want` is what it has to become.  The sign of `$want` is what distinguishes
# truncation from flooring, since -3.5 floors to -4 and truncates to -3, and
# only one of them is right.
sub truncate_ok {
    my ( $ftype, $itype, $num, $want ) = @_;
    my $sign = $want < 0 ? '0 - $h' : '$h';
    my $src  = <<"BROCKEN";
my $ftype \$h = $num;
my $ftype \$n = $sign;
my $ftype \$t = \$n / 2;
my $itype \$i = \$t;
if (\$i != $want) { return 1; }
return 0;
BROCKEN
    return run($src);
}

# The float arrives as a parameter, so the value being converted was written by
# a call rather than by a store to the alloca area.
sub param_ok {
    my ( $ftype, $itype ) = @_;
    my $src = <<"BROCKEN";
sub half( $ftype \$h ) -> $itype {
    my $ftype \$t = \$h / 2;
    my $itype \$i = \$t;
    return \$i;
}
if ( half(7) != 3 ) { return 1; }
return 0;
BROCKEN
    return run($src);
}

sub call_ok {
    my $src = <<'BROCKEN';
sub three() -> f64 { return 3; }
my f64 $h = 1;
my f64 $t = three() + $h / 2;
my i64 $i = $t;
if ($i != 3) { return 1; }
return 0;
BROCKEN
    return run($src);
}

# Float to integer and back again through separate declarations, with the
# integer used as an integer and the float compared as a float, so a conversion
# that lands in the wrong register cannot pass by being re-interpreted.
sub chained_ok {
    my $src = <<'BROCKEN';
my f64 $h = 7;
my f64 $t = $h / 2;
my i64 $i = $t;
my i64 $j = $i + 1;
if ($j != 4) { return 1; }
if ($t == 3) { return 2; }
return 0;
BROCKEN
    return run($src);
}

sub run {
    my ($src)  = @_;
    my $module = Brocken::Compiler->new->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = $brocken->tmpdir . '/f2i' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    system $file;
    return $? >> 8;
}
