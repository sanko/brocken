use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];
use Brocken;

# `push @a, v...` / `pop @a` / `shift @a` / `unshift @a, v...` (spec 6.1) mutate a *growable* array: one declared with
# a runtime or omitted element count (`my [i64] @a;` or `my [i64; $n] @a;`), which is heap-backed with the tag-9 header
# the runtime helpers need. Growth re-allocates the block, so the array slot is re-pointed at the fresh base; the value
# is the new element count. `pop`/`shift` shrink the count in place and answer the removed element (0 when empty -- an
# i64 element has no undef).
#
# The class runtime's array forms address raw object memory, which the Wasm backend does not model the same way, so
# these run on the native targets (host plus whichever cross emulators are present).
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
my %native         = ( targets => [@native_targets] );
subtest 'push appends and answers the new length' => sub {
    answers( 'my [i64] @a; push @a, 1; return @a[0];',             1,  'one element',                           %native );
    answers( 'my [i64] @a; push @a, 1; push @a, 2; return @a[1];', 2,  'appends in order',                      %native );
    answers( 'my [i64] @a; push @a, 10, 20, 30; return @a[2];',    30, 'several values at once',                %native );
    answers( 'my [i64] @a; push @a, 5, 6, 7; return push @a, 8;',  4,  'the value is the new length',           %native );
    answers( 'my [i64] @a; my i64 $n = push @a, 1, 2; return $n;', 2,  'usable as an expression',               %native );
    answers( 'my [i64] @a; push @a, 1, 2; return push @a;',        2,  'push with no values answers the count', %native );
};
subtest 'pop removes and answers the last element' => sub {
    answers( 'my [i64] @a; push @a, 1, 2, 3; return pop @a;',             3, 'answers the last',                %native );
    answers( 'my [i64] @a; push @a, 1, 2, 3; pop @a; return push @a, 9;', 3, 'the count shrinks (3 -> 2 -> 3)', %native );
    answers( 'my [i64] @a; return pop @a;',                               0, 'an empty array answers 0' );
};
subtest 'shift removes and answers the first element' => sub {
    answers( 'my [i64] @a; push @a, 4, 5, 6; return shift @a;',             4, 'answers the first',               %native );
    answers( 'my [i64] @a; push @a, 4, 5, 6; shift @a; return @a[0];',      5, 'the rest move down',              %native );
    answers( 'my [i64] @a; push @a, 1, 2, 3; shift @a; return push @a, 7;', 3, 'the count shrinks (3 -> 2 -> 3)', %native );
};
subtest 'unshift prepends in argument order and answers the new length' => sub {
    answers( 'my [i64] @a; push @a, 3, 4; unshift @a, 1, 2; return @a[0];',        1,  'first value leads',               %native );
    answers( 'my [i64] @a; push @a, 3, 4; unshift @a, 1, 2; return @a[2];',        3,  'order is preserved',              %native );
    answers( 'my [i64] @a; unshift @a, 7; return unshift @a, 8;',                  2,  'the value is the new length',     %native );
    answers( 'my [i64] @a; push @a, 5; unshift @a, 1; return @a[0] * 10 + @a[1];', 15, 'grows ahead of the old contents', %native );
};
subtest 'the parenthesised Perl spelling parses too' => sub {
    answers( 'my [i64] @a; push(@a, 4, 5); return @a[1];',  5, 'parenthesised push',                %native );
    answers( 'my [i64] @a; push @a, 4, 5; return pop(@a);', 5, 'parenthesised pop',                 %native );
    answers( 'my [i64] @a; return push(@a);',               0, 'parenthesised push with no values', %native );
};
subtest 'runtime-sized declarations are growable' => sub {
    answers( 'my i64 $n = 0; my [i64; $n] @a; push @a, 7; return @a[0];',      7, 'a runtime count starts empty',       %native );
    answers( 'my i64 $n = 2; my [i64; $n] @a; push @a, 7; return push @a, 8;', 4, 'a nonzero runtime count also grows', %native );
};
subtest 'growth inside a loop re-points the slot each time' => sub {
    answers( 'my [i64] @a; my i64 $i = 0; while ($i < 5) { push @a, $i; $i = $i + 1; } return @a[4];', 4, 'push in a loop', %native );
    answers(
        'my [i64] @a; my i64 $i = 0; while ($i < 5) { push @a, $i; $i = $i + 1; } my i64 $sum = 0;' .
            ' while (push @a) { $sum = $sum + shift @a; } return $sum;',
        10, 'drain with shift (0+1+2+3+4)', %native
    );
};
subtest 'independent growable arrays do not alias' => sub {
    answers( 'my [i64] @a; my [i64] @b; push @a, 1, 2; push @b, 3, 4, 5; shift @a; unshift @b, 0; return @a[0] * 100 + @b[0];',
        200, 'two arrays grow separately', %native );
};
subtest 'unsupported forms are compile errors, not silent no-ops' => sub {
    ok( !eval { Brocken->new->compile('my [i64; 3] @a; push @a, 1; return 0;'); 1 }, 'a compile-time-sized array rejects push' );
    like( $@, qr/needs a growable array/, '...with a growable-array message' );
    ok( !eval { Brocken->new->compile('my [String] @a; push @a, 1; return 0;'); 1 }, 'a non-i64 element array rejects push' );
    like( $@, qr/only i64 element arrays/, '...with an i64-only message' );
    ok( !eval { Brocken->new->compile('push @missing, 1; return 0;'); 1 }, 'an unknown array rejects push' );
    like( $@, qr/Unknown array variable/, '...with an unknown-variable message' );
};
done_testing;
