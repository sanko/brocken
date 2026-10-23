use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# `TARGET OP= EXPR` is a compound assignment: `$x += 1` parses as `$x = $x + 1`, `$s .= "b"` as `$s = $s . "b"`, and so
# on. The desugaring reuses the ordinary assignment lowering, so all of its reference counting and boxing apply.
#
# Cases that mention a string literal need rodata, and the class forms address raw object memory with a struct GEP,
# which the Wasm backend does not model the same way, so those run native-only.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub native_case {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}
subtest 'arithmetic compound assignment on i64' => sub {
    answers( 'my i64 $x = 10; $x += 5; return $x;', 15, '+=' );
    answers( 'my i64 $x = 10; $x -= 5; return $x;', 5,  '-=' );
    answers( 'my i64 $x = 10; $x *= 5; return $x;', 50, '*=' );
    answers( 'my i64 $x = 20; $x /= 4; return $x;', 5,  '/=' );
    answers( 'my i64 $x = 17; $x %= 5; return $x;', 2,  '%=' );
};
subtest 'bitwise and shift compound assignment on i64' => sub {
    answers( 'my i64 $x = 12; $x &= 10; return $x;', 8,  '&=' );
    answers( 'my i64 $x = 12; $x |= 3; return $x;',  15, '|=' );
    answers( 'my i64 $x = 12; $x ^= 10; return $x;', 6,  '^=' );
    answers( 'my i64 $x = 1; $x <<= 4; return $x;',  16, '<<=' );
    answers( 'my i64 $x = 32; $x >>= 3; return $x;', 4,  '>>=' );
};

# The right-hand side is a full expression, binding looser than the compound operator but tighter than a following
# statement. This is the ordinary `Expr` grammar, not a single token.
subtest 'the RHS is an arbitrary expression' => sub {
    answers( 'my i64 $x = 0; $x += 2 * 3; return $x;',               6,  'product on the RHS' );
    answers( 'my i64 $x = 1; $x += 1 + 2; return $x;',               4,  'sum on the RHS' );
    answers( 'my i64 $x = 100; $x -= 10 + 5; return $x;',            85, 'a lower- than the operator RHS still groups together' );
    answers( 'my i64 $x = 1; $x += 2; $x *= 3; $x -= 4; return $x;', 5,  'a chain of compound assignments' );
};

# A compound assignment over an `Any` slot reads the box, combines, and stores the reduced value; the value survives
# the f64 round-trip that untyped arithmetic uses.
subtest 'compound assignment on an Any box' => sub {
    answers( 'my Any $x = 5; $x += 3; if ($x == 8) { return 1; } return 0;',     1, 'Any +=' );
    answers( 'my Any $x = 5; $x *= 2; if ($x == 10) { return 1; } return 0;',    1, 'Any *=' );
    answers( 'my Any $x = 5; $x -= 8; if ($x == 0 - 3) { return 1; } return 0;', 1, 'Any -= through zero' );
};
subtest 'compound assignment on an array element' => sub {
    answers( 'my [i64; 3] @a; @a[0] = 4; @a[0] += 6; return @a[0];',              10, '@a[i] +=' );
    answers( 'my [i64; 3] @a; @a[1] = 4; @a[1] *= 5; return @a[1];',              20, '@a[i] *=' );
    answers( 'my [i64; 3] @a; @a[2] = 20; @a[2] -= 7; @a[2] *= 2; return @a[2];', 26, 'two updates in sequence' );
};
subtest 'compound assignment on a hash element' => sub {
    native_case( 'my %h; %h{"k"} = 10; %h{"k"} += 5; if (%h{"k"} == 15) { return 1; } return 0;', 1, '%h{k} +=' );
    native_case( 'my %h; %h{"k"} = 2; %h{"k"} *= 3; if (%h{"k"} == 6) { return 1; } return 0;',   1, '%h{k} *=' );
    native_case( 'my %h; %h{"k"} += 4; if (%h{"k"} == 4) { return 1; } return 0;',                1, 'an absent key starts from undef' );
};
subtest 'string compound assignment' => sub {
    native_case( 'my String $s = "a"; $s .= "b"; return $s eq "ab" ? 1 : 0;',                       1, 'String .=' );
    native_case( 'my Any $s = "x"; $s .= "y"; $s .= "z"; if ($s eq "xyz") { return 1; } return 0;', 1, 'Any .= chained' );
};
subtest 'compound assignment on a field' => sub {
    native_case(
        'class P { field i64 $x : param = 0;' .
            ' method bump() :returns(i64) { $x += 5; return $x; } }' .
            ' my ptr $p = P->new(); return $p->bump();',
        5,
        'a bare field name as the compound target',
    );
};
done_testing;
