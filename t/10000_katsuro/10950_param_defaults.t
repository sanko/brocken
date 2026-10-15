use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# String literals live in rodata, which Wasm has no support for yet; those snippets run on the native targets only.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

# Omitted trailing parameters take their defaults, which are lowered at the call site. As in Perl, a default may
# reference any earlier parameter, so `sub f($a, $b = $a * 2)` gets a defaulted b built from the a that was passed.
subtest 'omitted trailing args take their defaults' => sub {
    answers( 'sub add(i64 $a = 1, i64 $b = 2) :returns(i64) { return $a + $b; } return add();',       3,  'no args: both defaults' );
    answers( 'sub add(i64 $a = 1, i64 $b = 2) :returns(i64) { return $a + $b; } return add(10);',     12, 'one arg: first wins, second defaulted' );
    answers( 'sub add(i64 $a = 1, i64 $b = 2) :returns(i64) { return $a + $b; } return add(10, 20);', 30, 'two args: defaults unused' );
};
subtest 'defaults may reference earlier parameters' => sub {
    answers( 'sub scale(i64 $x, i64 $m = $x * 2) :returns(i64) { return $m; } return scale(5);', 10, 'default sees the passed x' );
    answers( 'sub scale(i64 $x, i64 $m = $x * 2) :returns(i64) { return $m; } return scale(5, 30);',
        30, 'an explicit second argument beats the default' );
    answers( 'sub pair(i64 $a = 3, i64 $b = $a + 1) :returns(i64) { return $a * 10 + $b; } return pair();',
        34, 'a default can reference an earlier defaulted argument' );
};
subtest 'String defaults run through rodata' => sub {
    answers(
        'sub greet(String $name = "someone") :returns(i64) { return length($name); } return greet();',
        7,
        'constant String default',
        targets => [@native_targets]
    );
    answers(
        'sub greet(String $name = "someone") :returns(i64) { return length($name); } return greet("alice");',
        5,
        'explicit String argument beats the default',
        targets => [@native_targets]
    );
};
subtest 'float defaults' => sub {
    answers( 'sub big(f64 $x = 9.0) :returns(i64) { if ($x > 2.5) { return 1; } return 0; } return big();',    1, 'float default' );
    answers( 'sub big(f64 $x = 9.0) :returns(i64) { if ($x > 2.5) { return 1; } return 0; } return big(1.0);', 0, 'explicit float wins' );
};
subtest 'method parameter defaults' => sub {
    answers(
        'class Greet { method hello(String $name = "bob") :returns(i64) { return length($name); } } my ptr $g = Greet->new(); return $g->hello();',
        3,
        'method String default',
        targets => [@native_targets]
    );
    answers(
        'class Greet { method hello(String $name = "bob") :returns(i64) { return length($name); } } my ptr $g = Greet->new(); return $g->hello("alice");',
        5,
        'explicit method argument wins',
        targets => [@native_targets]
    );
    answers(
        'class Calc { method pair(i64 $a = 4, i64 $b = $a + 1) :returns(i64) { return $a * 10 + $b; } } my ptr $c = Calc->new(); return $c->pair();',
        45,
        'method defaults and chained reference',
        targets => [@native_targets]
    );
    answers(
        'class Calc { method pair(i64 $a = 4, i64 $b = $a + 1) :returns(i64) { return $a * 10 + $b; } } my ptr $c = Calc->new(); return $c->pair(1, 2);',
        12,
        'method explicit args',
        targets => [@native_targets]
    );
};

# A callable with no defaults must not bind its parameter names while its arguments lower. Doing so shadowed a caller
# variable that happened to share a parameter's name, so `f($x, $x)` resolved the second `$x` to the first argument's
# loaded value and died in the lowerer (`.allocated_type` on a Load).
subtest 'a default-less callable does not shadow caller variables' => sub {
    answers( 'sub f(i64 $x, i64 $y) :returns(i64) { return $x + $y; } my i64 $x = 3; return f($x, $x);',
        6, 'the same variable passed twice' );
    answers( 'sub g(i64 $a, i64 $b) :returns(i64) { return $a * 10 + $b; } my i64 $a = 2; return g($a, $a + 1);',
        23, 'a later argument may reference a variable named like an earlier parameter' );
    answers( 'sub h(i64 $x) :returns(i64) { return $x; } my i64 $x = 7; return h($x) + $x;',
        14, 'the caller variable survives the call' );
};
done_testing;
