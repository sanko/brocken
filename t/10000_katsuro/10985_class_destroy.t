use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# DESTROY is a class-body member like ADJUST: its body is lowered into a generated Class::DESTROY that runs this
# class's user code and then chains to the nearest ancestor's DESTROY, so teardown runs derived-to-root. It is a
# method, so it is inherited and callable on a receiver.
my @native = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

subtest 'DESTROY is callable and chains derived-to-root' => sub {
    answers(
        'class Base {' .
            ' field i64 $trace :param :reader :writer;' .
            ' DESTROY { $trace = $trace * 10 + 2; } }' .
            ' class Derived :isa(Base) {' .
            ' field i64 $seed :param;' .
            ' DESTROY { $self->set_trace($self->trace() * 10 + 1); } }' .
            ' my ptr $d = Derived->new(trace => 0, seed => 7);' .
            ' $d->DESTROY();' .
            ' return $d->trace();',
        12, 'the derived body runs before the base body', targets => [@native]
    );
};

subtest 'a three-level chain unwinds derived-to-root' => sub {
    answers(
        'class A {' .
            ' field i64 $t :param :reader :writer;' .
            ' DESTROY { $t = $t * 3 + 1; } }' .
            ' class B :isa(A) { DESTROY { $self->set_t($self->t() * 3 + 2); } }' .
            ' class C :isa(B) { DESTROY { $self->set_t($self->t() * 3 + 3); } }' .
            ' my ptr $c = C->new(t => 0);' .
            ' $c->DESTROY();' .
            ' return $c->t();',
        34, 'C runs, then B, then A', targets => [@native]
    );
};

subtest 'a class without its own DESTROY inherits the ancestor body' => sub {
    answers(
        'class Base {' .
            ' field i64 $t :param :reader;' .
            ' DESTROY { $t = $t + 5; } }' .
            ' class Plain :isa(Base) { field i64 $x :param; }' .
            ' my ptr $p = Plain->new(t => 1, x => 2);' .
            ' $p->DESTROY();' .
            ' return $p->t();',
        6, 'the inherited DESTROY runs on the derived object', targets => [@native]
    );
};

subtest 'DESTROY sees the declaring class fields bare' => sub {
    answers(
        'class Counter {' .
            ' field i64 $n :param :reader;' .
            ' field i64 $hits :reader = 0;' .
            ' DESTROY { $hits = $hits + $n; } }' .
            ' my ptr $c = Counter->new(n => 9);' .
            ' $c->DESTROY();' .
            ' return $c->hits();',
        9, 'the bare field access resolves in the destructor', targets => [@native]
    );
};

subtest 'DESTROY can call the class own methods and accessors' => sub {
    answers(
        'class Thing {' .
            ' field i64 $v :param :reader :writer;' .
            ' method bump() :returns(i64) { return $v + 1; }' .
            ' DESTROY { $self->set_v($self->bump()); } }' .
            ' my ptr $t = Thing->new(v => 40);' .
            ' $t->DESTROY();' .
            ' return $t->v();',
        41, 'the destructor body resolved the class own method and writer', targets => [@native]
    );
};

subtest 'a DESTROY-only class body is a definition, not a forward declaration' => sub {
    answers(
        'class Only;' .
            ' class Only { DESTROY { } }' .
            ' my ptr $o = Only->new();' .
            ' $o->DESTROY();' .
            ' return 42;',
        42, 'the DESTROY-only body still registers a callable destructor', targets => [@native]
    );
};

done_testing;
