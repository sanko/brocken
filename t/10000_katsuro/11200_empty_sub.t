use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# `sub f() {}` (F16) used to produce a declaration with no definition, so every call to it died at run time with an
# undefined-symbol link error. lower_function skipped any body with no statements, which conflated two different
# things: a prototype `sub f();`, which really is signature-only (the definition that follows supplies the body, and a
# lone one becomes a `declare`), and an empty body, which is a real function that must still emit a definition (here,
# the default return). Prototypes are now flagged by the parser and still lower nothing; an empty body falls through to
# the epilogue and emits `ret 0` / `ret void`.
my @targets = executable_targets();

sub check {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@targets] );
}
subtest 'an empty body is a callable definition' => sub {
    check( 'sub f() :returns(i64) { } sub m() :returns(i64) { return f(); } return m();', 0, 'a typed empty function returns zero' );
    check( 'sub f() { } sub m() :returns(i64) { f(); return 4; } return m();',            4, 'a void empty function is callable' );
    check( 'sub f() :returns(Any) { } sub m() :returns(i64) { my Any $x = f(); return defined($x) ? 1 : 0; } return m();',
        0, 'an empty dynamic function returns undef' );
    check( 'sub f(Any $x) { } sub m() :returns(i64) { my Any $v = 1; f($v); return 2; } return m();',
        2, 'an empty body accepts (and ignores) a parameter' );
    check( 'package P; sub f() :returns(i64) { } sub m() :returns(i64) { return P::f(); } return P::m();', 0, 'an empty body inside a package' );
};
subtest 'an empty method body is callable' => sub {
    check( 'class C { method m() {} } sub k() :returns(i64) { my $c = C->new(); $c->m(); return 3; } return k();',
        3, 'an empty method runs and returns' );
};
subtest 'a prototype supplies the signature for its definition' => sub {
    check( 'sub f(); sub f() :returns(i64) { return 5; } sub m() :returns(i64) { return f(); } return m();', 5, 'prototype first, definition after' );
    check( 'sub f() :returns(i64) { return 5; } sub f(); sub m() :returns(i64) { return f(); } return m();',
        5, 'definition first, prototype after (the prototype must not clobber it)' );
};
subtest 'a lone prototype becomes a declare, not an error' => sub {
    my $mod = Brocken->new->compile('sub foo() :returns(i64);');
    my ($f) = grep { $_->name eq 'foo' } $mod->functions->@*;
    ok( $f, 'found function foo' );
    is( $f->return_type->as_string, 'i64' );
    is( $f->params->@*, 2, 'only the hidden heap_base/want params, no body' );
};
subtest 'the prototype flag is on the AST, not inferred from the body' => sub {
    my $c  = Brocken->new;
    my $p1 = $c->parse('sub f();');
    is( $p1->statements->[0]->prototype, 1, 'sub f(); is flagged as a prototype' );
    my $p2 = $c->parse('sub f() { }');
    ok( !$p2->statements->[0]->prototype, 'sub f() { } is not' );
};
done_testing;
