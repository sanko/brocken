use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# Unary `-` on a dynamic operand (F8) used to force `unbox_i64`, which truncates a float payload toward zero, so `-$x`
# where `$x` holds 3.5 came out -3 (and -3.5 came out 3). Reading the operand at f64 follows the same Perl scalar rule
# the binary untyped arithmetic uses (lower_binop): `unbox_f64` widens an integer payload, so one fneg serves either
# kind of box and keeps the fraction a float box carries.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub check {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}

subtest 'unary minus on a boxed float keeps the fraction' => sub {
    check( 'my $x = 3.5; my $r = -$x; return $r == -3.5 ? 1 : 0;', 1, 'a float box negates to its exact negative' );
    check( 'my $x = 3.5; my $r = -$x; return $r > -3.6 ? 1 : 0;', 1, 'the negated value is past -3.6' );
    check( 'my $x = 3.5; my $r = -$x; return $r < -3.4 ? 1 : 0;', 1, 'the negated value is before -3.4 (not truncated to -3)' );
};

subtest 'unary minus on a boxed int is still correct' => sub {
    check( 'my $x = 5; my $r = -$x; return $r == -5 ? 1 : 0;', 1, 'an int box negates to -5' );
    check( 'my $x = 0; my $r = -$x; return $r == 0 ? 1 : 0;',  1, 'negating zero stays zero' );
};

subtest 'double negation round-trips' => sub {
    check( 'my $x = 3.5; my $r = -(-$x); return $r == 3.5 ? 1 : 0;', 1, 'a float survives two negations' );
    check( 'my $x = 7; my $r = -(-$x); return $r == 7 ? 1 : 0;',     1, 'an int survives two negations' );
};

subtest 'the negated result is usable in comparisons and slots' => sub {
    check( 'my $x = 3.5; my $r = -$x; if ($r) { return 1; } return 0;',                          1, 'a negated float is truthy' );
    check( 'my $x = 3.5; my $r = -$x; my f64 $y = $r; return $y == -3.5 ? 1 : 0;',               1, 'it stores into a typed f64 slot' );
    check( 'my $x = 3.5; my $r = -$x; my i64 $n = $r; return $n == -3 ? 1 : 0;',                 1, 'storing into an i64 truncates toward zero' );
    check( 'my $x = 3.5; my $r = -$x; my f64 $y = 0.0; $y = $r; return $y == -3.5 ? 1 : 0;',     1, 'it assigns into a typed f64 slot' );
};

subtest 'a literal float still folds to a negative constant' => sub {
    check( 'my f64 $y = -3.5; return $y == -3.5 ? 1 : 0;', 1, 'a negative float literal' );
    check( 'my $r = -3.5; return $r == -3.5 ? 1 : 0;',     1, 'a negative float literal into an untyped slot' );
};

done_testing;
