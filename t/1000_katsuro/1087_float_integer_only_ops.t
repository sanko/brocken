use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Test2::Tools::Brocken qw[answers];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# `&`, `|`, `^`, `<<`, `>>` and `%` are integer-only, and a float operand is
# truncated toward zero before the operator applies. That is Perl's rule:
# `12.7 & 10.3` is `12 & 10`, `-3.9 & 7.0` is `-3 & 7`, and `1.0 << 2.9`
# shifts by 2. Truncation is toward zero and not toward negative infinity, so
# `-3.9` truncates to `-3` and not to `-4`; the two disagree under `&`, where
# `-3 & 7` is 5 and `-4 & 7` is 4.
#
# `&&` and `||` are a truth test instead of an integer operator, so a float
# operand is compared against zero and not truncated. Truncation would get that
# backwards in both directions, since 0.5 and -0.5 both truncate to 0 while
# both are true. An untyped operand is read as f64 for these two so that one
# comparison covers either kind of box: `Brocken::Runtime::unbox_f64` widens an
# integer payload, so `my $x = 5; $x && $y` is `5.0 != 0.0` and `my $x = 0;
# $x && $y` is false.
#
# The operands here are deliberately fractional. Whole-number floats such as
# `12.0` and `10.0` truncate to values whose bitwise results coincide with
# several other readings of the operator, so `12.0 & 10.0` cannot tell a
# truncation apart from a mask of the raw IEEE-754 bits. `12.7` separates them.
#
# `answers` runs this on the host, on the cross targets when BROCKEN_SYSROOT_* is
# set, and on Wasm when a runner is on PATH.
subtest 'a float operand is truncated, then the integer operator applies' => sub {
    answers( 'my f64 $a = 12.7; my f64 $b = 10.3; return $a & $b;',  8,  'f64 & f64' );
    answers( 'my f64 $a = 12.7; my f64 $b = 10.3; return $a | $b;',  14, 'f64 | f64' );
    answers( 'my f64 $a = 12.7; my f64 $b = 10.3; return $a ^ $b;',  6,  'f64 ^ f64' );
    answers( 'my f64 $a = 12.7; my f64 $b = 2.0;  return $a << $b;', 48, 'f64 << f64' );
    answers( 'my f64 $a = 12.7; my f64 $b = 2.0;  return $a >> $b;', 3,  'f64 >> f64' );
    answers( 'my f64 $a = 12.7; my f64 $b = 10.3; return $a % $b;',  2,  'f64 % f64' );
};
subtest 'the truncation goes toward zero, not toward negative infinity' => sub {

    # -3.9 truncates to -3, not to floor(-3.9) == -4, and the two disagree under
    # `&`: -3 & 7 is 5 while -4 & 7 is 4. So this single case separates a
    # truncation from a floor.
    #
    # `-3.9 | 7.0` is -1 and is not asserted: the answer is a negative integer and
    # an exit code is eight bits wide, so it would come back as 255 and pass for a
    # number nobody wrote.
    answers( 'my f64 $a = -3.9; my f64 $b = 7.0; return $a & $b;', 5, 'f64 -3.9 & f64 7.0, not 4' );

    # 0.9 truncates to 0, so both operands vanish and every operator answers 0.
    answers( 'my f64 $a = 0.9; my f64 $b = 0.9; return $a | $b;',  0, 'f64 0.9 | f64 0.9, not 1' );
    answers( 'my f64 $a = -0.9; my f64 $b = 0.0; return $a & $b;', 0, 'f64 -0.9 & f64 0.0' );
    answers( 'my f64 $a = 0.5; my f64 $b = 0.5; return $a ^ $b;',  0, 'f64 0.5 ^ f64 0.5' );
};
subtest 'a fractional shift count truncates too' => sub {
    answers( 'my f64 $a = 1.0; my f64 $b = 2.9; return $a << $b;', 4, 'f64 1.0 << f64 2.9' );
    answers( 'my f64 $a = 8.0; my f64 $b = 1.9; return $a >> $b;', 4, 'f64 8.0 >> f64 1.9' );
};
subtest 'a whole-number float is truncated like any other' => sub {

    # 12.0 and 10.0 carry no fraction, so this is the one shape where truncating
    # first and masking the raw bits agree. `12.7` in the subtest above is what
    # tells the two apart; this one pins the whole-number answer as well.
    answers( 'my f64 $a = 12.0; my f64 $b = 10.0; return $a & $b;', 8, 'f64 12.0 & f64 10.0' );
};
subtest 'a mixed integer and float operand truncates the float' => sub {
    answers( 'my f64 $a = 12.7; my i64 $b = 10; return $a | $b;', 14, 'f64 | i64' );
    answers( 'my i64 $a = 12; my f64 $b = 10.3; return $a | $b;', 14, 'i64 | f64' );
    answers( 'my f64 $a = 12.7; my i64 $b = 5;  return $a % $b;', 2,  'f64 % i64' );
};
subtest 'an untyped operand agrees with a declared one' => sub {
    answers( 'my $a = 12; my f64 $b = 10.3; return $a | $b;', 14, 'untyped | f64' );
    answers( 'my f64 $a = 12.7; my $b = 10; return $a | $b;', 14, 'f64 | untyped' );
    answers( 'my $a = 12.7; my $b = 10.3; return $a & $b;',   8,  'untyped & untyped' );
    answers( 'my $a = 12.7; my $b = 2.0;  return $a << $b;',  48, 'untyped << untyped' );
};
subtest 'the result is an integer, whatever it is stored into' => sub {

    # The operator is integer-only, so the value it produces is an integer. A
    # declaration of `f64` converts it on the way in, which matches Perl, where
    # `my $r = 12.7 & 10.3` is an integer.
    answers( 'my f64 $a = 12.7; my i64 $r = $a & 10; return $r;', 8, 'into i64' );
    answers( 'my f64 $a = 12.7; my f64 $r = $a & 10; return $r;', 8, 'into f64' );
};
subtest 'integer arithmetic is unaffected by the float rules' => sub {
    answers( 'my i64 $a = 12; my i64 $b = 10; return $a & $b;', 8,  'i64 & i64' );
    answers( 'my i64 $a = 12; my i64 $b = 10; return $a | $b;', 14, 'i64 | i64' );
    answers( 'my i64 $a = 12; my i64 $b = 10; return $a ^ $b;', 6,  'i64 ^ i64' );
    answers( 'my i64 $a = 12; return $a << 2;',                 48, 'i64 << 2' );
    answers( 'my i64 $a = 12; return $a >> 2;',                 3,  'i64 >> 2' );
    answers( 'my i64 $a = 12; my i64 $b = 5; return $a % $b;',  2,  'i64 % i64' );
};
subtest 'float arithmetic is unaffected by the float rules' => sub {
    answers( 'my f64 $a = 1.5; my f64 $b = 2.5; return ($a + $b) * 2;',   8, 'f64 + f64' );
    answers( 'my f64 $a = 1.5; my f64 $b = 2.5; return $b - $a;',         1, 'f64 - f64' );
    answers( 'my f64 $a = 7.0; my f64 $b = 2.0; return $a / $b;',         3, 'f64 / f64' );
    answers( 'my f64 $a = 1.5; my f64 $b = 2.5; return $a < $b ? 1 : 0;', 1, 'f64 < f64' );
    answers( 'my i64 $a = 1; my f64 $b = 1.5; return ($a + $b) * 2;',     5, 'i64 + f64 keeps the fraction' );
};
subtest 'a float is true when it is not zero, not when it truncates' => sub {

    # 0.5 is the case that separates a truth test from a truncation: it is true,
    # and it truncates to 0. A zero float is asserted alongside it so that the
    # pair pins both sides rather than only the true one.
    answers( 'my f64 $a = 0.5; my f64 $b = 1.0; return $a && $b;', 1, 'f64 0.5 && f64 1.0' );
    answers( 'my f64 $a = 1.5; my f64 $b = 2.5; return $a && $b;', 1, 'f64 1.5 && f64 2.5' );
    answers( 'my f64 $a = 0.0; my f64 $b = 1.0; return $a && $b;', 0, 'f64 0.0 && f64 1.0' );
    answers( 'my f64 $a = 0.5; my f64 $b = 1.0; return $a || $b;', 1, 'f64 0.5 || f64 1.0' );
    answers( 'my f64 $a = 0.0; my f64 $b = 0.0; return $a || $b;', 0, 'f64 0.0 || f64 0.0' );
    answers( 'my f64 $a = 1.5; my f64 $b = 0.0; return $a || $b;', 1, 'f64 1.5 || f64 0.0' );

    # The untyped box goes through the same comparison, and covers the integer
    # payload case as well as the float one.
    answers( 'my $a = 0.5; my f64 $b = 1.0; return $a && $b;', 1, 'untyped 0.5 && f64 1.0' );
    answers( 'my $a = 0.5; my f64 $b = 1.0; return $a || $b;', 1, 'untyped 0.5 || f64 1.0' );
    answers( 'my $a = 0; my f64 $b = 1.0; return $a && $b;',   0, 'untyped 0 && f64 1.0' );
    answers( 'my $a = 5; my f64 $b = 1.0; return $a && $b;',   1, 'untyped 5 && f64 1.0' );
};
done_testing;
