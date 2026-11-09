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
subtest 'an empty body is a callable definition' => sub {
    answers( 'sub f() :returns(i64) { } sub m() :returns(i64) { return f(); } return m();', 0, 'a typed empty function returns zero' );
    answers( 'sub f() { } sub m() :returns(i64) { f(); return 4; } return m();',            4, 'a void empty function is callable' );
    answers( 'sub f() :returns(Any) { } sub m() :returns(i64) { my Any $x = f(); return defined($x) ? 1 : 0; } return m();',
        0, 'an empty dynamic function returns undef' );
    answers( 'sub f() :returns(String) { } sub m() :returns(i64) { my String $s = f(); return defined($s) ? 1 : 0; } return m();',
        0, 'an empty String function returns undef' );
    answers( 'sub f() :returns(f64) { } sub m() :returns(i64) { return f() == 0.0 ? 1 : 0; } return m();', 1, 'an empty f64 function returns 0.0' );
    answers( 'sub f() :returns(f32) { } sub m() :returns(i64) { return f() == 0.0 ? 1 : 0; } return m();', 1, 'an empty f32 function returns 0.0' );
    answers( 'sub f() :returns(bool) { } sub m() :returns(i64) { return f() ? 1 : 0; } return m();', 0, 'an empty bool function returns false' );
    answers( 'sub f() :returns(ptr) { } sub m() :returns(i64) { my ptr $p = f(); return defined($p) ? 1 : 0; } return m();',
        0, 'an empty ptr function returns null' );
    answers(
        'class Pt { field i64 $x = 1; } sub f() :returns(Pt) { } sub m() :returns(i64) { my Pt $p = f(); return defined($p) ? 1 : 0; } return m();',
        0, 'an empty class function returns undef' );
    answers( 'sub f(Any $x) { } sub m() :returns(i64) { my Any $v = 1; f($v); return 2; } return m();',
        2, 'an empty body accepts (and ignores) a parameter' );
    answers( 'package P; sub f() :returns(i64) { } sub m() :returns(i64) { return P::f(); } return P::m();', 0, 'an empty body inside a package' );
};
subtest 'an empty method body is callable' => sub {
    answers( 'class C { method m() {} } sub k() :returns(i64) { my $c = C->new(); $c->m(); return 3; } return k();',
        3, 'an empty method runs and returns' );
    answers(
        'class C { method name() :returns(String) {} } sub k() :returns(i64) { my $c = C->new(); my String $n = $c->name(); return defined($n) ? 1 : 0; } return k();',
        0,
        'an empty method returning String returns undef'
    );
};
subtest 'bare return in typed function returns zero or undef' => sub {
    answers( 'sub f() :returns(i64) { return; } sub m() :returns(i64) { return f(); } return m();', 0, 'bare return in i64 returns 0' );
    answers( 'sub f(i64 $n) :returns(i64) { if ($n < 2) { return 42; } return; } return f(10);',    0, 'bare return in conditional returns 0' );
    answers( 'sub f() :returns(Any) { return; } sub m() :returns(i64) { my Any $x = f(); return defined($x) ? 1 : 0; } return m();',
        0, 'bare return in dynamic returns undef' );
    answers( 'sub f() :returns(String) { return; } sub m() :returns(i64) { my String $s = f(); return defined($s) ? 1 : 0; } return m();',
        0, 'bare return in String returns undef' );
    answers( 'sub f() :returns(f64) { return; } sub m() :returns(i64) { return f() == 0.0 ? 1 : 0; } return m();',
        1, 'bare return in f64 returns 0.0' );
    answers( 'sub f() :returns(f32) { return; } sub m() :returns(i64) { return f() == 0.0 ? 1 : 0; } return m();',
        1, 'bare return in f32 returns 0.0' );
    answers( 'sub f() :returns(bool) { return; } sub m() :returns(i64) { return f() ? 1 : 0; } return m();', 0, 'bare return in bool returns false' );
    answers( 'sub f() :returns(ptr) { return; } sub m() :returns(i64) { my ptr $p = f(); return defined($p) ? 1 : 0; } return m();',
        0, 'bare return in ptr returns null' );
    answers(
        'class Pt { field i64 $x = 1; } sub f() :returns(Pt) { return; } sub m() :returns(i64) { my Pt $p = f(); return defined($p) ? 1 : 0; } return m();',
        0,
        'bare return in class returns undef'
    );
    answers( 'sub f() :returns(i32) { return; } sub m() :returns(i64) { return f() == 0 ? 1 : 0; } return m();', 1, 'bare return in i32 returns 0' );
    answers( 'sub f() :returns(u64) { return; } sub m() :returns(i64) { return f() == 0 ? 1 : 0; } return m();', 1, 'bare return in u64 returns 0' );
    answers( 'class Svc { method run() :returns(i64) { return; } } sub m() :returns(i64) { my $s = Svc->new(); return $s->run(); } return m();',
        0, 'bare return in method returning i64 returns 0' );
    answers(
        'class Svc { method name() :returns(String) { return; } } sub m() :returns(i64) { my $s = Svc->new(); my String $n = $s->name(); return defined($n) ? 1 : 0; } return m();',
        0,
        'bare return in method returning String returns undef'
    );
    answers(
        'class Svc { method active() :returns(bool) { return; } } sub m() :returns(i64) { my $s = Svc->new(); return $s->active() ? 1 : 0; } return m();',
        0,
        'bare return in method returning bool returns false'
    );
    answers(
        'class Svc { method val() :returns(f64) { return; } } sub m() :returns(i64) { my $s = Svc->new(); return $s->val() == 0.0 ? 1 : 0; } return m();',
        1,
        'bare return in method returning f64 returns 0.0'
    );
};
subtest 'a prototype supplies the signature for its definition' => sub {
    answers( 'sub f(); sub f() :returns(i64) { return 5; } sub m() :returns(i64) { return f(); } return m();',
        5, 'prototype first, definition after' );
    answers( 'sub f() :returns(i64) { return 5; } sub f(); sub m() :returns(i64) { return f(); } return m();',
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
#
done_testing;
