use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# `defined` is the null test, not the truthiness test: a native scalar has no undefined value, so `defined 0` is true,
# while an `Any` box is undefined only when it is the null box that an uninitialised `my Any` or a missing `%h{key}`
# yields. A box holding `0`, `0.0`, `""`, or `"0"` is still defined. This is what distinguishes `defined $x` from
# `if ($x)`, which is false for those payloads.
#
# String and `%h{...}` cases need rodata, which the Wasm backend does not emit yet, so they run native-only.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub run_case {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}

# A native scalar can never be undef, so `defined` is a constant true even at 0 / 0.0 / false.
subtest 'a native scalar is always defined' => sub {
    answers( 'my i64 $x = 0; if (defined $x) { return 1; } return 0;',      1, 'defined 0 (i64) is true' );
    answers( 'my i64 $x = 5; if (defined $x) { return 1; } return 0;',      1, 'defined 5 (i64) is true' );
    answers( 'my f64 $x = 0.0; if (defined $x) { return 1; } return 0;',    1, 'defined 0.0 is true' );
    answers( 'my bool $x = false; if (defined $x) { return 1; } return 0;', 1, 'defined false is true' );
};

# An `Any` box is undefined only when it is the null box.
subtest 'an Any box is defined unless it is null' => sub {
    answers( 'my Any $x; if (defined $x) { return 1; } return 0;',     0, 'an uninitialised Any is undef' );
    answers( 'my Any $x = 0; if (defined $x) { return 1; } return 0;', 1, 'a box holding 0 is defined' );
    run_case( 'my Any $x = "0"; if (defined $x) { return 1; } return 0;', 1, 'a box holding "0" is defined' );
    run_case( 'my Any $x = ""; if (defined $x) { return 1; } return 0;',  1, 'a box holding "" is defined' );
};

# `!defined` is the undefined test, and it separates undef from a false payload.
subtest '!defined is the undefined test' => sub {
    answers( 'my Any $x; if (!defined $x) { return 1; } return 0;',     1, '!defined on a null box' );
    answers( 'my Any $x = 0; if (!defined $x) { return 1; } return 0;', 0, 'a box holding 0 is not undefined' );
    run_case( 'my Any $x = "0"; if (!defined $x) { return 1; } return 0;', 0, 'a box holding "0" is not undefined' );
};

# A missing hash key reads as a null box, so `defined %h{key}` reports presence.
subtest 'defined on a hash element reports presence' => sub {
    run_case( 'my %h; if (defined %h{"k"}) { return 1; } return 0;',                0, 'a missing key is undefined' );
    run_case( 'my %h; %h{"k"} = 0; if (defined %h{"k"}) { return 1; } return 0;',   1, 'a key holding 0 is defined' );
    run_case( 'my %h; %h{"k"} = "0"; if (defined %h{"k"}) { return 1; } return 0;', 1, 'a key holding "0" is defined' );
    run_case( 'my %h; %h{"k"} = 1; if (!defined %h{"k"}) { return 1; } return 0;',  0, 'a present key is not undefined' );
};

# `defined` drops into a ternary, where the condition is a select operand rather than a branch.
subtest 'defined in a ternary' => sub {
    answers( 'my Any $x = 7; return defined($x) ? 1 : 2;', 1, 'a defined box picks the first arm' );
    answers( 'my Any $x; return defined($x) ? 1 : 2;',     2, 'an undefined box picks the second arm' );
    answers( 'my i64 $x = 0; return defined($x) ? 1 : 2;', 1, 'a native picks the first arm' );
};

# A constant condition used to reach the encoder as an immediate operand, which the encoders cannot resolve, so
# `if (true)` aborted codegen. `if`/`while`/ternary conditions now materialize a literal as a comparison, which is
# also what a `defined` on a native scalar produces.
subtest 'a constant condition branches correctly' => sub {
    answers( 'if (true) { return 1; } return 0;',                                              1, 'if (true) takes the then branch' );
    answers( 'if (false) { return 1; } return 0;',                                             0, 'if (false) skips the then branch' );
    answers( 'if (false) { return 1; } else { return 2; }',                                    2, 'if (false) takes the else branch' );
    answers( 'return true ? 1 : 2;',                                                           1, 'a constant ternary picks the first arm' );
    answers( 'return false ? 1 : 2;',                                                          2, 'a constant ternary picks the second arm' );
    answers( 'my i64 $i = 0; while (true) { $i = $i + 1; if ($i == 3) { last; } } return $i;', 3, 'while (true) with a last' );
};
done_testing;
