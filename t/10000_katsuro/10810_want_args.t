use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# Perl evaluates every element of an argument list in list context, so a call sitting directly in argument position
# must see want("list") inside it -- the same rule the `for` iterable already follows. The override is scoped to the
# argument's own outermost call: an operator between the argument list and a nested call imposes its own scalar
# context, and the override never leaks past the call into the surrounding expression.
#
# Each snippet ends in a top-level `return`, which the lowerer warns about at runtime; that warning reaches stderr
# through `write`, which the Wasm backend cannot link (a pre-existing limitation; see `11260_implicit_return.t`), so
# these run on the native targets only.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
sub native_case { answers( $_[0], $_[1], $_[2], targets => [@native_targets] ) }

# `probe` reports whether it saw list context.
my $probe = 'sub probe() :returns(i64) { return want("list") ? 1 : 0; }';
subtest 'a call in argument position sees list context' => sub {
    native_case( "$probe sub g(i64 \$x) :returns(i64) { return \$x; } return g(probe());", 1, 'a single argument is list context' );
    native_case( "$probe sub g2(i64 \$a, i64 \$b) :returns(i64) { return \$a + \$b; } return g2(probe(), probe());",
        2, 'every argument in the list is list context' );
    native_case( "$probe sub g(i64 \$x) :returns(i64) { return \$x; } sub f(i64 \$y) :returns(i64) { return \$y; } return f(g(probe()));",
        1, 'the override reaches through a nested call' );
    native_case( "$probe sub g(i64 \$x) :returns(i64) { return \$x; } return g((probe()));", 1, 'parentheses around the argument are transparent' );
};
subtest 'a method call argument sees list context' => sub {
    native_case( "class C { method take(i64 \$x) :returns(i64) { return \$x; } } $probe my \$c = C->new(); return \$c->take(probe());",
        1, 'a plain call in a method argument is list context' );
    native_case(
        'class C { method m() :returns(i64) { return want("list") ? 1 : 0; } } sub g(i64 $x) :returns(i64) { return $x; } my $c = C->new(); return g($c->m());',
        1,
        'a method call in argument position is itself told want=list'
    );
};
subtest 'scalar context is unchanged' => sub {
    native_case( "$probe my i64 \$x = probe(); return \$x;",          0, 'a declaration initialiser is scalar context' );
    native_case( "$probe my i64 \$x = 0; \$x = probe(); return \$x;", 0, 'an assignment is scalar context' );
    native_case( "$probe sub g(i64 \$x) :returns(i64) { return \$x; } return g(probe() * 5);",
        0, 'an operator between the list and the call forces scalar context' );
};
subtest 'the override does not leak past the argument list' => sub {
    native_case(
        "$probe sub g(i64 \$x) :returns(i64) { return \$x; } my i64 \$r = g(probe()); sub sc() :returns(i64) { return want(\"list\"); } return \$r * 10 + sc();",
        10,
        'a later scalar-context call still sees scalar want'
    );
};
done_testing;
