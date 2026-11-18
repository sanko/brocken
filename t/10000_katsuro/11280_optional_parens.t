use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# A call to a known sub may omit its parentheses: the name is followed by a list of arguments that runs to the end of
# the statement (or the enclosing delimiter). `render2 'Alex'` is `render2('Alex')`, and in `say render, render2 'Alex'`
# the comma after a name makes it a zero-argument call -- the comma belongs to the enclosing list. The set of known
# subs is collected from the whole token stream, so a call may name a sub declared later in the file.
#
# `render 'Test'` on a zero-parameter sub parses the same way and is then an ordinary arity error, which is the point:
# the argument list is syntactic, not guessed from the signature.
#
# The behaviour cases use `exit(...)` so the entry point's value is an i64 with no string boxing. They run on the native
# targets only: a top-level `exit` now lowers to the entry's return on Wasm, but the `say`/`print` cases write strings
# through a path the Wasm backend does not support here (see `11260_implicit_return.t`).
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
sub native_case { answers( $_[0], $_[1], $_[2], targets => [@native_targets] ) }
subtest 'a paren-less call runs like the parenthesised form' => sub {
    native_case( 'sub two() :returns(i64) { return 2; } exit(two);',                 2, 'a bare call in a statement' );
    native_case( 'sub two() :returns(i64) { return 2; } exit(two());',               2, 'the parenthesised form is unchanged' );
    native_case( 'sub two() :returns(i64) { return 2; } my i64 $x = two; exit($x);', 2, 'a bare call as an initialiser' );
    native_case( 'sub two() :returns(i64) { return 2; } exit(two + two);',           4, 'a bare call inside an expression' );
    native_case( 'sub two() :returns(i64) { return 2; } exit(two) if true;',         2, 'a postfix if still applies' );
};
subtest 'a paren-less call takes its arguments from the list' => sub {
    native_case( 'sub inc(i64 $n) :returns(i64) { return $n + 1; } exit(inc 5);',     6, 'one bare argument' );
    native_case( 'sub inc(i64 $n) :returns(i64) { return $n + 1; } exit(inc inc 5);', 7, 'a nested bare call is its own argument' );
    native_case( 'sub f() :returns(i64) { return 3; } sub g(i64 $a, i64 $b) :returns(i64) { return $a * 10 + $b; } exit(g f, f);',
        33, 'a comma after a name ends its (empty) argument list' );
    native_case( 'sub f() :returns(i64) { return 3; } sub g(i64 $x) :returns(i64) { return $x; } exit(g(f));',
        3, 'the parenthesised form still takes precedence' );
};
subtest 'a sub declared later may be called without parentheses' => sub {
    native_case( 'exit(later); sub later() :returns(i64) { return 5; }', 5, 'a forward reference resolves' );
};
subtest 'methods and class construction are unaffected' => sub {
    native_case( 'class C { method m() :returns(i64) { return 7; } } my $c = C->new(); exit($c->m());',
        7, 'a method call still needs its own parentheses' );
    native_case( 'class C { field i64 $x = 3; } my $c = C->new(); exit($c->x);', 3, 'a field access still reads the field' );
};
subtest 'say/print may drop their parentheses' => sub {
    native_case( q!say 'hello'; exit(0);!,                                      0, 'say takes a bare argument' );
    native_case( q!sub two() :returns(i64) { return 2; } say two; exit(0);!,    0, 'say takes a bare call' );
    native_case( q!print 'a', 'b'; exit(0);!,                                   0, 'print takes a bare list' );
    native_case( q!sub two() :returns(i64) { return 2; } say(two()); exit(0);!, 0, 'the parenthesised form is unchanged' );
};
subtest 'too many arguments is still an arity error' => sub {
    my $err = do {
        local $@;
        eval { Brocken->new->compile('sub render() :returns(i64) { return 1; } render 5;') };
        $@;
    };
    like( $err, qr/Too many arguments to 'render'/, 'a bare argument to a zero-parameter sub is rejected' );
};
subtest 'an unknown bareword is still an error' => sub {
    my $err = do {
        local $@;
        eval { Brocken->new->compile('say undefined_thing;') };
        $@;
    };
    ok( $err, 'an unknown bareword does not silently become a call' );
};
done_testing;
