use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# The class runtime is exercised on the native targets.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
my %native         = ( targets => [@native_targets] );

# A field initializer runs in the constructor after the earlier fields have been assigned, so it can read them:
# `field $y = $x + 1;` sees the value `$x` was given -- positionally, by name, or from its own initializer.
subtest 'a field initializer sees earlier fields' => sub {
    answers( 'class Pair { field i64 $x :param :reader; field i64 $y :reader = $x + 1; } my ptr $p = Pair->new(x => 10); return $p->y;',
        11, 'default reads a :param field set by name', %native );
    answers(
        'class Box { field i64 $w :param :reader; field i64 $h :param :reader; field i64 $area :reader = $w * $h; }' .
            ' my ptr $b = Box->new(h => 4, w => 5); return $b->area;',
        20, 'default reads fields set by name, in any order', %native
    );
};
subtest 'field initializers chain in declaration order' => sub {
    answers(
        'class Chain { field i64 $a :reader = 3; field i64 $b :reader = $a + 1; field i64 $c :reader = $b + 1; }' .
            ' my ptr $c = Chain->new(); return $c->c;',
        5, 'each initializer sees the previous one', %native
    );

    # A local at the call site may share a field's name; the constructor's temporary binding must not leak.
    answers( 'class Echo { field i64 $x :reader = 7; } my i64 $x = 100; my ptr $e = Echo->new(); return $x + $e->x;',
        107, 'field bindings are restored at the call site', %native );
};
subtest 'a field initializer may use $self' => sub {
    answers(
        'class Greeter { field i64 $base :param :reader; method twice() :returns(i64) { return $base * 2; }' .
            ' field i64 $doubled :reader = $self->twice(); } my ptr $g = Greeter->new(base => 21); return $g->doubled;',
        42, '$self is available to initializers', %native
    );
};
subtest 'constructor arguments keep the caller class context' => sub {

    # The class context is established only around the initializers, so a caller passing its own field to a
    # constructor still lowers that field with the caller's type: the f64 2.5 converts (fptosi) to 2 rather than
    # having its bits reinterpreted as an i64.
    answers(
        'class N { field i64 $x :param :reader; }' .
            ' class M { field f64 $z :param; method go() :returns(i64) { my ptr $n = N->new(x => $z); return $n->x; } }' .
            ' my ptr $m = M->new(z => 2.5); return $m->go();',
        2, 'an outer field passed to a constructor is typed in the caller', %native
    );
};
subtest '__CLASS__ resolves inside a field initializer' => sub {

    # TODO(F15): the value of __CLASS__ is not yet a usable class handle (it numifies to 0), so only check that the
    # constructor establishes class context and the default compiles instead of croaking.
    my $ok = eval { Brocken->new->compile('class C { field ptr $tag = __CLASS__; } C->new(); return 0;'); 1 };
    ok( $ok, 'a field default may mention __CLASS__' ) or diag($@);
};
done_testing;
