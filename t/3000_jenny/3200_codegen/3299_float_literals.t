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

# Integer literals used where a float is expected.
#
# A literal carries the type it was written with, so `3` is an i64 and knows
# nothing about the `f64` slot it is about to be stored into. Nothing in the IR
# recovers that: the store's own type is void and its destination is a plain
# `ptr`, so the pointee type is not visible where the value is written. The
# constant therefore reached the backend still typed as an integer, `store_imm`
# packed the integer 3 into eight bytes, and the reload read those bytes back as
# a denormal rather than 3.0.
#
# The mistake was invisible where it was made and surfaced in three different
# ways downstream, so all three are covered here:
#
#   * a store, where the wrong bits land in memory;
#   * a return, where the callee emits a value it never re-reads and the caller
#     is simply told the wrong number;
#   * an arithmetic operand, where an i64 meets an f64 inside one instruction.
#
# The return case is not a miscompile but a hard failure, and it is the reason
# this file could not have existed before. Nothing coerced the return value, so a
# float function returning a literal emitted `ret i64` and the comparison against
# it died in the operand resolver with `Unexpected operand kind: imm`. A test
# that only checked a stored value would have gone green while the shortest way
# to write the same thing stayed broken.
#
# Two forms are deliberately absent, both broken in their own right and both
# tracked in `TODO.md`:
#
#   * Comparing a float *call result* against a literal, as in
#     `if (f() == 3)`, gets the wrong answer even where the callee is correct.
#     Every case here therefore compares inside the function that holds the
#     value, which is the part this file is about.
#   * `!=` and the ordering forms on floats. `==` is enough to tell a correct
#     value from a denormal, and reaching for the others would fail for reasons
#     that have nothing to do with literals.
#
# Decimal literals (`my f64 $t = 3.0;`) are not used either: the parser rejects
# them outright, which is a separate gap. Writing the literal as an integer is
# currently the only way to say it, and is exactly the case that was broken.
my $brocken = Brocken->new;
SKIP: {
    skip 'Not native', 1 unless $brocken->platform->is_native;
    my @cases = (
        [ 'f64 local initialised from an integer literal', q|sub f() -> i64 { my f64 $t = 3; if ($t == 3) { return 42; } return 1; } return f();| ],
        [ 'f32 local initialised from an integer literal', q|sub f() -> i64 { my f32 $t = 3; if ($t == 3) { return 42; } return 1; } return f();| ],

        # A value past 2**52, where the integer and floating-point bit patterns
        # differ in more than the exponent. A fix that only got the *width*
        # right -- widening, truncating, or re-tagging as i32 -- passes the
        # small cases above and fails here, which is what keeps the test from
        # being satisfied by a coincidence of small numbers.
        [   'f64 local holding a value past 2**52',
            q|sub f() -> i64 { my f64 $t = 9007199254740993; if ($t == 9007199254740993) { return 42; } return 1; } return f();|
        ],

        # The literal is the second operand, so the instruction is mixed before
        # lowering ever sees it. Left as an i64 it met an f64 in one `add`, and
        # the wider operand decided the width for the whole instruction.
        [   'integer literal as the right operand of a float add',
            q|sub f() -> i64 { my f64 $t = 3; my f64 $u = $t + 1; if ($u == 4) { return 42; } return 1; } return f();|
        ],
        [   'integer literal as the left operand of a float add',
            q|sub f() -> i64 { my f64 $t = 1; my f64 $u = 3 + $t; if ($u == 4) { return 42; } return 1; } return f();|
        ],

        # Through a parameter and a return, so the value crosses a function
        # boundary and the callee's capture of an f64 argument is part of what is
        # under test.
        [   'integer literal stored locally and passed to a float parameter',
            q|sub g(f64 $a) -> i64 { if ($a == 3) { return 42; } return 1; } sub f() -> i64 { my f64 $t = 3; return g($t); } return f();|
        ],
    );
    for my $case (@cases) {
        my ( $name, $src ) = $case->@*;
        is( run($src), 42, "native: $name" );
    }
}
done_testing;

sub run {
    my ($src)  = @_;
    my $module = Brocken::Compiler->new->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = $brocken->tmpdir . '/fatlit' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    system $file;
    return $? >> 8;
}
