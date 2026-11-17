use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# Perl's implicit last-expression return: when a sub or method body falls off its end, the value of its final
# expression is the value of the call. The lowerer turns that trailing expression into a synthesized `return`, so it
# gets the same conversion, reference-count, and handler bookkeeping a written `return` would. The inferred return
# type includes it too, which is what lets an unannotated `sub seven() { 7; }` be called as a value.
#
# A `void` body discards the trailing expression instead: it is a side-effecting statement, and the sub keeps its
# default void return. The entry point never takes an implicit return either -- its value is the process exit code,
# and a top-level statement must not set it by accident.
#
# The Wasm backend cannot link the `write` reference `core.brocken`'s diagnostic helpers pull in (a pre-existing
# limitation unrelated to return inference; see `11200_empty_sub.t`), so these cases run on the native targets only.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
sub native_case { answers( $_[0], $_[1], $_[2], targets => [@native_targets] ) }
subtest 'a typed sub returns its final expression' => sub {
    native_case( 'sub add(i64 $a, i64 $b) :returns(i64) { $a + $b; } return add(10, 32);', 42, 'an i64 body returns its last expression' );
    native_case( 'sub half(f64 $x) :returns(f64) { $x / 2.0; } sub m() :returns(i64) { return half(8.0) == 4.0 ? 1 : 0; } return m();',
        1, 'an f64 body returns its last expression' );
    native_case( 'sub yes() :returns(bool) { true; } sub m() :returns(i64) { return yes() ? 1 : 0; } return m();',
        1, 'a bool body returns its last expression' );
    native_case( 'sub f() :returns(i32) { 7; } sub m() :returns(i64) { return f(); } return m();', 7, 'an i32 body returns its last expression' );
    native_case( 'sub f() :returns(u8) { 9; } sub m() :returns(i64) { return f(); } return m();',  9, 'a u8 body returns its last expression' );
    native_case( 'sub name() :returns(String) { "hi"; } sub m() :returns(i64) { my String $s = name(); return defined($s) ? 1 : 0; } return m();',
        1, 'a String body returns a defined value' );
    native_case(
        'class Pt { field i64 $x = 1; } sub make() :returns(Pt) { Pt->new(); } sub m() :returns(i64) { my Pt $p = make(); return $p->x; } return m();',
        1,
        'a class body returns the constructed instance'
    );
};
subtest 'an unannotated sub infers its return type from the final expression' => sub {
    native_case( 'sub seven() { 7; } return seven();', 7, 'a constant body infers i64' );
    native_case( 'sub three() { 3; } sub six() { three() + three(); } return six() + three();',
        9, 'a body that calls another inferred sub infers through it' );
    native_case( 'sub pi() { 3.5; } sub m() :returns(i64) { return pi() == 3.5 ? 1 : 0; } return m();', 1, 'a float body infers f64' );
    native_case( 'sub flag() { true; } sub m() :returns(i64) { return flag() ? 1 : 0; } return m();',   1, 'a bool body infers bool' );
    native_case( 'sub greet() { "hi"; } sub m() :returns(i64) { my String $s = greet(); return defined($s) ? 1 : 0; } return m();',
        1, 'a string body infers a dynamic value' );
};
subtest 'a void sub discards its final expression' => sub {
    native_case( 'sub greet() { say("hi"); } greet(); return 5;',                5,  'a trailing say is a discarded statement' );
    native_case( 'sub noop() { } noop(); return 6;',                             6,  'an empty body returns nothing' );
    native_case( 'sub outer() { inner(); } sub inner() { } outer(); return 11;', 11, 'a forward call to a void sub is not mistaken for a value' );
    native_case( 'sub outer() { inner(); } sub inner() { say("x"); } outer(); return 12;',
        12, 'a forward call to a say-ended void sub is discarded too' );
};
subtest 'an explicit return still wins over the trailing expression' => sub {
    native_case( 'sub f() :returns(i64) { return 3; 9; } return f();',                3, 'an early return wins' );
    native_case( 'sub f() :returns(i64) { if (true) { return 4; } 9; } return f();',  4, 'a return inside a branch wins' );
    native_case( 'sub f() :returns(i64) { if (false) { return 4; } 9; } return f();', 9, 'the trailing expression is used when no branch returns' );
};
subtest 'a body that does not end in an expression falls through' => sub {
    native_case( 'sub f() :returns(i64) { my i64 $x = 5; } return f();',     0, 'a declaration as the last statement yields the default' );
    native_case( 'sub f() :returns(i64) { if (false) { 1; } } return f();',  0, 'an if as the last statement yields the default' );
    native_case( 'sub f() :returns(i64) { my i64 $x = 5; $x; } return f();', 5, 'a value after a declaration is still returned' );
};
subtest 'a method returns its final expression' => sub {
    native_case( 'class Calc { method twice(i64 $x) :returns(i64) { $x * 2; } } my $c = Calc->new(); return $c->twice(6);',
        12, 'a typed method returns its last expression' );
    native_case( 'class Calc { method one() { 1; } } my $c = Calc->new(); return $c->one();', 1, 'an unannotated method infers its return type' );
    native_case( 'class C { method val() :returns(i64) { 7; } method run() :returns(i64) { $self->val(); } } my $c = C->new(); return $c->run();',
        7, 'a method may return another method call' );
};
subtest 'the entry point never takes an implicit return' => sub {
    native_case( 'sub five() { 5; } five();',             0, 'a trailing call at the top level does not set the exit code' );
    native_case( 'sub five() { 5; } my i64 $x = five();', 0, 'a trailing declaration at the top level does not either' );
};
#
done_testing;
