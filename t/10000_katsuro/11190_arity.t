use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# Call arity is validated at compile time (TODO 9, F14): an excess argument used to be lowered and then dropped on the
# floor, and a missing argument used to leave the callee reading an uninitialised parameter slot -- either way a silent
# wrong answer or a crash instead of a diagnostic. Both are now hard errors for functions and methods alike, with the
# hidden `%__heap_base` / `%__want` / `$self` parameters excluded (they are plumbing, not user arguments) and
# `say`/`print` exempt because they are variadic. Trailing parameters with defaults still fill in, so the check only
# fires when a *required* parameter would go unfilled. Wasm is excluded because the `say` case needs rodata, which the
# Wasm backend does not emit yet.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub check {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}

sub compile_error {
    my ( $source, $pattern, $label ) = @_;
    my $ok = eval { Brocken->new->compile($source); 1 };
    ok( !$ok, $label );
    like( $@, $pattern, '... with the expected diagnostic' ) if !$ok;
}

subtest 'an excess argument is a compile error' => sub {
    compile_error(
        'sub f($x) { return $x; } sub m() :returns(i64) { return f(1, 2); } return m();',
        qr/Too many arguments to 'f': 1 expected, got 2/,
        'a second argument a one-parameter function never declared is rejected'
    );
    compile_error(
        'sub f($x, $y = 3) :returns(i64) { return $x + $y; } sub m() :returns(i64) { return f(1, 2, 3); } return m();',
        qr/Too many arguments to 'f': 2 expected, got 3/,
        'the count is the declared parameter count even when defaults exist'
    );
};

subtest 'an unfilled required parameter is a compile error' => sub {
    compile_error(
        'sub f($x, $y) { return $x; } sub m() :returns(i64) { return f(1); } return m();',
        qr/Missing required argument 2 of 'f'/,
        'a parameter with no default must be supplied'
    );
    compile_error(
        'sub f($x, $y = 3) :returns(i64) { return $x + $y; } sub m() :returns(i64) { return f(); } return m();',
        qr/Missing required argument 1 of 'f'/,
        'a default on a later parameter does not excuse the first'
    );
};

subtest 'method arity is checked the same way' => sub {
    compile_error(
        'class P { method get(i64 $i) :returns(i64) { return $i; } }'
            . ' sub m() :returns(i64) { my $p = P->new(); return $p->get(); } return m();',
        qr/Missing required argument 1 of 'get'/,
        'a method call with no argument for a required parameter is rejected'
    );
    compile_error(
        'class P { method get(i64 $i) :returns(i64) { return $i; } }'
            . ' sub m() :returns(i64) { my $p = P->new(); return $p->get(1, 2); } return m();',
        qr/Too many arguments to 'get': 1 expected, got 2/,
        'a method call with an excess argument is rejected'
    );
};

subtest 'calls with the right arity still work' => sub {
    check( 'sub f($x) :returns(i64) { return $x * 2; } return f(21);',                     42, 'a plain function call' );
    check( 'sub f($x, $y = 3) :returns(i64) { return $x + $y; } return f(1);',              4, 'an omitted trailing parameter takes its default' );
    check( 'sub f($x, $y = 3) :returns(i64) { return $x + $y; } return f(1, 2);',           3, 'an explicitly supplied parameter overrides the default' );
    check( 'sub f($x, $y) :returns(i64) { return $x * 10 + $y; } return f(1, 2);',         12, 'every required parameter supplied' );
    check( 'class P { method get(i64 $i, i64 $j = 2) :returns(i64) { return $i + $j; } }'
            . ' sub m() :returns(i64) { my $p = P->new(); return $p->get(5); } return m();',
        7, 'a method call fills its default' );
    check( 'sub main2() :returns(i64) { say("a", "b"); return 9; } return main2();',
        9, 'say stays variadic (any number of arguments)' );
};

subtest 'a default may reference an earlier parameter' => sub {
    check( 'sub f($a, $b = $a + 1) :returns(i64) { return $a * 10 + $b; } return f(1);',
        12, 'the default is computed with the first argument bound' );
};

done_testing;
