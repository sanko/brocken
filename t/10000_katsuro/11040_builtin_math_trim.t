use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# `ceil`/`floor`/`inf`/`nan`/`trim` are lowered in the front end, but they lean on `fptosi`/`sitofp`/`fcmp` and a
# managed string helper, so they are checked on every native target that can run here. Wasm is excluded: string
# literals are unsupported there (no rodata/data-segment emission), which the `trim` cases need. A negative result is
# reported as an exit code mod 256, so the numeric checks answer a boolean rather than the raw value.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub check  ( $source, $want, $label ) {
    answers( $source, $want, $label, targets => [@native_targets] );
}
subtest 'ceil rounds toward positive infinity' => sub {
    check( 'sub f() :returns(i64) { if (builtin::ceil(2.5) == 3) { return 1; } return 0; } return f();',   1, 'ceil(2.5) is 3' );
    check( 'sub f() :returns(i64) { if (builtin::ceil(-2.5) == -2) { return 1; } return 0; } return f();', 1, 'ceil(-2.5) is -2' );
    check( 'sub f() :returns(i64) { if (builtin::ceil(3.0) == 3) { return 1; } return 0; } return f();',   1, 'ceil of an integral float is itself' );
};
subtest 'floor rounds toward negative infinity' => sub {
    check( 'sub f() :returns(i64) { if (builtin::floor(2.5) == 2) { return 1; } return 0; } return f();',   1, 'floor(2.5) is 2' );
    check( 'sub f() :returns(i64) { if (builtin::floor(-2.5) == -3) { return 1; } return 0; } return f();', 1, 'floor(-2.5) is -3' );
    check( 'sub f() :returns(i64) { if (builtin::floor(3.0) == 3) { return 1; } return 0; } return f();', 1, 'floor of an integral float is itself' );
};
subtest 'rounding an integer is the identity' => sub {
    check( 'sub f() :returns(i64) { return builtin::ceil(7); } return f();',  7, 'ceil of an int' );
    check( 'sub f() :returns(i64) { return builtin::floor(7); } return f();', 7, 'floor of an int' );
};
subtest 'rounding a boxed number reads its tag' => sub {

    # A float box rounds; an int box is returned untouched (it never goes through the float conversion, which would
    # lose bits beyond 2^53).
    check( 'sub f() :returns(i64) { my Any $x = 2.5; return builtin::ceil($x); } return f();',  3, 'a boxed float ceils' );
    check( 'sub f() :returns(i64) { my Any $x = 2.5; return builtin::floor($x); } return f();', 2, 'a boxed float floors' );
    check( 'sub f() :returns(i64) { my Any $x = 7; return builtin::floor($x); } return f();',   7, 'a boxed int passes through' );
};
subtest 'inf is the floating-point infinity' => sub {
    check( 'sub f() :returns(i64) { if (builtin::inf() > 1000000.0) { return 1; } return 0; } return f();',  1, 'inf() is large' );
    check( 'sub f() :returns(i64) { if (builtin::inf(1) > 1000000.0) { return 1; } return 0; } return f();', 1, 'inf(1) is positive' );
    check( 'sub f() :returns(i64) { if (builtin::inf(-1) < 0.0) { return 1; } return 0; } return f();',      1, 'inf(-1) is negative' );
};
subtest 'nan is never equal to itself' => sub {
    check( 'sub f() :returns(i64) { if (builtin::nan() != builtin::nan()) { return 1; } return 0; } return f();', 1, 'nan() != nan()' );
    check( 'sub f() :returns(i64) { if (builtin::nan() == builtin::nan()) { return 1; } return 0; } return f();', 0, 'nan() == nan() is false' );
};
subtest 'trim strips leading and trailing whitespace' => sub {
    check( 'sub f() :returns(i64) { my String $s = builtin::trim("  hi  "); return length($s); } return f();',  2, 'both ends' );
    check( 'sub f() :returns(i64) { my String $s = builtin::trim("hi"); return length($s); } return f();',      2, 'nothing to strip' );
    check( 'sub f() :returns(i64) { my String $s = builtin::trim("   "); return length($s); } return f();',     0, 'all whitespace is empty' );
    check( 'sub f() :returns(i64) { my String $s = builtin::trim(""); return length($s); } return f();',        0, 'the empty string stays empty' );
    check( 'sub f() :returns(i64) { my String $s = builtin::trim("\t x \n"); return length($s); } return f();', 1, 'tab and newline are whitespace' );

    # The surfaces prove the boundary; this proves the interior survived untouched.
    check( 'sub f() :returns(i64) { if (builtin::trim("  hi  ") eq "hi") { return 1; } return 0; } return f();', 1, 'content preserved' );
};
subtest 'trim reads a boxed string' => sub {
    check( 'sub f() :returns(i64) { my Any $d = "  yo  "; my String $s = builtin::trim($d); return length($s); } return f();',
        2, 'a boxed string trims' );
};
#
done_testing;
