use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# String operators (`.` and the `eq`/`ne`/`lt`/`gt`/`le`/`ge`/`cmp` comparisons) stringify both operands, so a dynamic
# (`Any`) operand must be rendered from its box tag -- a string payload, an integer, a float -- rather than unboxed to
# f64 by the numeric unification. A box holding `"x"` is the string `"x"`, not `"0.000000"`.
#
# Every case mentions a string literal, which needs rodata, so these run native-only.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub native_case {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}

subtest 'a dynamic operand concatenates as its string payload' => sub {
    native_case( 'my Any $s = "x"; if (($s . "y") eq "xy") { return 1; } return 0;', 1, 'boxed string on the left' );
    native_case( 'my Any $s = "y"; if (("x" . $s) eq "xy") { return 1; } return 0;', 1, 'boxed string on the right' );
    native_case( 'my Any $a = "m"; my Any $b = "n"; if (($a . $b) eq "mn") { return 1; } return 0;', 1, 'two boxed strings' );
};

# A box holding something other than a string still renders through the integer/float path, so the box's tag is what
# selects the rendering (the same dispatch `say` uses).
subtest 'a dynamic integer or float still renders numerically' => sub {
    native_case( 'my Any $n = 12; if (($n . "!") eq "12!") { return 1; } return 0;', 1, 'boxed integer' );
};

# A boxed `undef` renders as the empty string, matching the `say` behavior.
subtest 'an undefined box concatenates as the empty string' => sub {
    native_case( 'my Any $u; if (("a" . $u) eq "a") { return 1; } return 0;', 1, 'null box on the right' );
};

subtest 'a dynamic operand compares as its string payload' => sub {
    native_case( 'my Any $s = "abc"; if ($s eq "abc") { return 1; } return 0;',   1, 'eq on a boxed string' );
    native_case( 'my Any $s = "abc"; if ($s ne "abd") { return 1; } return 0;',   1, 'ne on a boxed string' );
    native_case( 'my Any $s = "abc"; if ($s lt "abd") { return 1; } return 0;',   1, 'lt on a boxed string' );
    native_case( 'my Any $s = "abc"; if ($s gt "abb") { return 1; } return 0;',   1, 'gt on a boxed string' );
    native_case( 'my Any $s = "abc"; if ($s le "abc") { return 1; } return 0;',   1, 'le on a boxed string' );
    native_case( 'my Any $s = "abc"; if ($s ge "abc") { return 1; } return 0;',   1, 'ge on a boxed string' );
    native_case( 'my Any $s = "abc"; if (($s cmp "abd") == 0 - 1) { return 1; } return 0;', 1, 'cmp on a boxed string' );
    native_case( 'my Any $n = 12; if ($n eq "12") { return 1; } return 0;',       1, 'eq renders a boxed integer' );
};

# The static cases are unchanged: a `String` operand is already a pointer, two literals fold into one, and a native
# integer renders through the integer helper.
subtest 'static operands are unaffected' => sub {
    native_case( 'my String $s = "p"; if (($s . "q") eq "pq") { return 1; } return 0;', 1, 'String . literal' );
    native_case( 'if (("a" . "b") eq "ab") { return 1; } return 0;', 1, 'two literals fold' );
    native_case( 'my i64 $n = 7; if (($n . "x") eq "7x") { return 1; } return 0;', 1, 'native integer . literal' );
    native_case( 'my String $a = "apple"; my String $b = "banana"; if ($a lt $b) { return 1; } return 0;', 1, 'String comparison' );
    native_case( 'my i64 $n = 7; if ($n eq "7") { return 1; } return 0;', 1, 'native integer eq literal' );
};

done_testing;
