use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# `for`/`foreach` iterate a list a stride at a time, and `builtin::indexed` builds the `(index, value)` pairs that a
# two-target loop consumes. Both lower to ordinary IR (list load, GEP, compare, branch) so they are checked on every
# native target that can run here. Wasm is left out: a string literal cannot be boxed there (no rodata/data-segment
# emission), and one case below iterates strings. A value past 255 wraps to the exit code, so a numeric check answers a
# boolean rather than the raw total.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub verify {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}
subtest 'a single loop variable walks every element' => sub {
    verify( 'sub f() :returns(i64) { my i64 $s = 0; for my $x (1, 2, 3) { $s = $s + $x; } return $s; } return f();',
        6, 'the elements are visited in order' );
    verify( 'sub f() :returns(i64) { my i64 $s = 0; foreach my $x (10, 20, 30) { $s = $s + $x; } return $s / 10; } return f();',
        6, 'foreach is the same statement' );
    verify( 'sub f() :returns(i64) { my i64 $s = 7; for my $x () { $s = 99; } return $s; } return f();', 7, 'an empty list never runs the body' );
};
subtest 'builtin::indexed yields index/value pairs' => sub {
    verify( 'sub f() :returns(i64) { my i64 $s = 0; for my ($i, $v) (builtin::indexed(10, 20, 30)) { $s = $s + $v; } return $s; } return f();',
        60, 'the value half is the element' );
    verify( 'sub f() :returns(i64) { my i64 $s = 0; for my ($i, $v) (builtin::indexed(10, 20, 30)) { $s = $s + $i; } return $s; } return f();',
        3, 'the index half is zero-based' );
    verify( 'sub f() :returns(i64) { my i64 $s = 0; for my ($i, $v) (builtin::indexed(7, 8, 9, 10)) { $s = $s + $i; } return $s; } return f();',
        6, 'four elements give four pairs' );
    verify( 'sub f() :returns(i64) { my ($a, $b, $c, $d) = builtin::indexed(5, 6); return $a + $b + $c + $d; } return f();',
        12, 'the pair list unpacks like any other list' );
};
subtest 'a stride of targets consumes a stride of elements' => sub {
    verify( 'sub f() :returns(i64) { my i64 $s = 0; for my ($i, $v) (0, 10, 1, 20, 2, 30) { $s = $s + $i; } return $s; } return f();',
        3, 'two targets advance two elements at a time' );

    # Six elements with a stride of two leave nothing over; a trailing element below the stride is dropped rather than
    # half-bound.
    verify( 'sub f() :returns(i64) { my i64 $s = 0; for my ($i, $v) (0, 10, 1, 20, 2, 30, 99) { $s = $s + $i; } return $s; } return f();',
        3, 'a short trailing element is ignored' );
};
subtest 'last and next' => sub {
    verify( 'sub f() :returns(i64) { my i64 $s = 0; for my $x (1, 2, 3, 4) { if ($x == 2) { last; } $s = $s + $x; } return $s + 1; } return f();',
        2, 'last leaves the loop' );
    verify( 'sub f() :returns(i64) { my i64 $s = 0; for my $x (1, 2, 3, 4) { if ($x == 2) { next; } $s = $s + $x; } return $s - 4; } return f();',
        4, 'next skips the rest of the body but still advances' );
};
subtest 'nested iteration' => sub {
    verify( 'sub f() :returns(i64) { my i64 $s = 0; for my $x (1, 2, 3) { for my $y (1, 2, 3) { $s = $s + $x * $y; } } return $s; } return f();',
        36, 'an inner loop runs fully for each outer element' );
    verify(
        'sub f() :returns(i64) { my i64 $s = 0; for my ($i, $v) (builtin::indexed(10, 20, 30)) { for my ($j, $w) (builtin::indexed(1, 2, 3)) { $s = $s + $j; } } return $s; } return f();',
        9,
        'two indexed loops nest'
    );
};
subtest 'iterating an array' => sub {
    verify(
        'sub f() :returns(i64) { my [i64; 3] @a; @a[0] = 4; @a[1] = 5; @a[2] = 6; my i64 $s = 0; for my $x (@a) { $s = $s + $x; } return $s; } return f();',
        15,
        'a bare array is unrolled into its elements'
    );
    verify(
        'sub f() :returns(i64) { my [i64; 3] @a; @a[0] = 4; @a[1] = 5; @a[2] = 6; my i64 $s = 0; for my ($i, $v) (builtin::indexed(@a)) { $s = $s + $i; } return $s; } return f();',
        3,
        'indexed over an array indexes from zero'
    );
};
subtest 'targets take their declared type' => sub {
    verify( 'sub f() :returns(i64) { my i64 $s = 0; for my $v (1, 2.5, 3) { if ($v == 3) { $s = $s + 1; } } return $s; } return f();',
        1, 'a boxed target unboxes for a comparison' );
    verify( 'sub f() :returns(i64) { for my (String $s) ("hi", "yo") { if ($s eq "yo") { return 1; } } return 0; } return f();',
        1, 'a String target reads the string payload' );
    verify( 'sub f() :returns(i64) { my i64 $s = 0; for my (i64 $x) (1, 2, 3, 4) { $x = $x * 2; $s = $s + $x; } return $s - 10; } return f();',
        10, 'an i64 target can be reassigned in the body' );
};
subtest 'the iterable is evaluated once' => sub {
    verify( 'sub f() :returns(i64) { my i64 $s = 0; for my ($i, $v) (builtin::indexed(10, 20, 30)) { $s = $s + $v; } return $s; } return f();',
        60, 'indexed inside a function' );
};
subtest 'a call iterable is asked for a list' => sub {

    # The iterable is consumed as a list, so a call producing it is told want=list even though the surrounding
    # expression is otherwise scalar. Without the override the callee sees the caller's scalar want and returns the
    # wrong shape (the branch is taken on the forwarded value).
    verify(
        'sub nums() :returns(ptr) { if (want("list")) { return (1, 2, 3); } return (99, 100); } my i64 $n = 0; for my $x (nums()) { $n = $n + 1; } return $n;',
        3,
        'the callee sees list want'
    );

    # The override applies only to the iterable: a later scalar-context call still sees scalar want.
    verify(
        'sub nums() :returns(ptr) { if (want("list")) { return (1, 2, 3); } return (99, 100); } sub sc() :returns(i64) { return want("list"); } my i64 $n = 0; for my $x (nums()) { $n = $n + 1; } return $n * 10 + sc();',
        30,
        'the want override does not leak past the loop'
    );
};
done_testing;
