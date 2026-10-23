use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# A postfix statement modifier (`STATEMENT if COND;` / `STATEMENT unless COND;`) is sugar for a one-statement `if`.
# The condition is the same truthiness test a prefix `if` uses, so `next if $x` and `if ($x) { next; }` behave alike.
#
# Only simple statements -- the ones that end in a `;` -- take a modifier. A compound statement needs no `;`, so an
# `if` that follows one is a new statement rather than a modifier; that is pinned by the regression cases below.
#
# Cases that mention a string literal need rodata, which the Wasm backend does not emit yet, and `throw` needs the
# setjmp/longjmp dispatcher, which Wasm lacks, so those run native-only.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub native_case {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}
subtest 'postfix if on return' => sub {
    answers( 'sub f(i64 $x) : returns(i64) { return 1 if $x > 0; return 0; } return f(1);',     1, 'taken when true' );
    answers( 'sub f(i64 $x) : returns(i64) { return 1 if $x > 0; return 0; } return f(0);',     0, 'skipped at zero' );
    answers( 'sub f(i64 $x) : returns(i64) { return 1 if $x > 0; return 0; } return f(0 - 1);', 0, 'skipped when negative' );
};
subtest 'postfix unless on return' => sub {
    answers( 'sub f(i64 $x) : returns(i64) { return 1 unless $x > 0; return 0; } return f(0);', 1, 'taken when false' );
    answers( 'sub f(i64 $x) : returns(i64) { return 1 unless $x > 0; return 0; } return f(1);', 0, 'skipped when true' );
};

# The modifier keeps the expression's own value: only its effect is made conditional.
subtest 'postfix modifier on an assignment' => sub {
    answers( 'my i64 $x = 0; $x = 5 if true; return $x;',      5, 'assignment runs when true' );
    answers( 'my i64 $x = 0; $x = 5 if false; return $x;',     0, 'assignment skipped when false' );
    answers( 'my i64 $x = 0; $x = 5 unless false; return $x;', 5, 'unless runs when false' );
    answers( 'my i64 $x = 0; $x = 5 unless true; return $x;',  0, 'unless skipped when true' );
};

# `if`/`while`/`for` need no `;`, so a following `if` starts a new statement. Wrapping is done only by the simple
# statements, which is what keeps these two apart.
subtest 'a compound statement does not swallow the next statement' => sub {
    answers( 'my i64 $x = 0; if (false) { $x = 5; } if (true) { $x = 7; } return $x;',              7, 'two ifs are two statements' );
    answers( 'my i64 $i = 0; while ($i < 3) { $i = $i + 1; } if ($i == 3) { return 1; } return 0;', 1, 'an if after a while is a new statement' );
};
subtest 'postfix if on next' => sub {
    answers( 'my i64 $sum = 0; my i64 $i = 0; while ($i < 5) { $i = $i + 1; next if $i == 3; $sum = $sum + $i; } return $sum;',
        12, 'the skipped iteration contributes nothing' );
};
subtest 'postfix on last' => sub {
    answers( 'my i64 $i = 0; while (true) { $i = $i + 1; last if $i == 4; } return $i;',      4, 'last if stops the loop' );
    answers( 'my i64 $i = 0; while ($i < 5) { $i = $i + 1; last unless $i < 3; } return $i;', 3, 'last unless stops the loop' );
};

# The modifier may be followed by nothing else, and an `if` body may itself contain a modified statement.
subtest 'postfix inside a branch and a loop' => sub {
    answers( 'my i64 $x = 0; if (true) { $x = 1 if true; $x = 2 if false; } return $x;', 1, 'a postfix inside an if body' );
    answers( 'my i64 $sum = 0; my i64 $i = 0; while ($i < 4) { $i = $i + 1; $sum = $sum + $i if $i != 2; } return $sum;',
        8, 'a postfix inside a loop body' );
};

# A `return` whose value is a ternary keeps the whole expression: the modifier follows the value, not the arms.
subtest 'postfix after a non-trivial return value' => sub {
    answers( 'sub f(i64 $a) : returns(i64) { return $a > 0 ? 1 : 2 if true; return 3; } return f(5);',  1, 'ternary then' );
    answers( 'sub f(i64 $a) : returns(i64) { return $a > 0 ? 1 : 2 if true; return 3; } return f(0);',  2, 'ternary else' );
    answers( 'sub f(i64 $a) : returns(i64) { return $a > 0 ? 1 : 2 if false; return 3; } return f(5);', 3, 'modifier false' );
};
subtest 'postfix on throw' => sub {
    native_case( 'try { throw 1 if true; } catch ($e) { return 7; } return 0;',  7, 'a taken throw is caught' );
    native_case( 'try { throw 1 if false; } catch ($e) { return 7; } return 0;', 0, 'a skipped throw runs the rest' );
};
subtest 'postfix on a print statement' => sub {
    native_case( 'print("x") if false; return 0;',  0, 'print suppressed when false' );
    native_case( 'say("x") if true; return 0;',     0, 'say runs when true' );
    native_case( 'say("x") unless true; return 0;', 0, 'say suppressed by unless' );
};
#
done_testing;
