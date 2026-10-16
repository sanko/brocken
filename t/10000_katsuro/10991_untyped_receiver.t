use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# The class runtime is exercised on the native targets: an object is raw memory addressed with a struct GEP, which
# the Wasm backend does not model the same way.
my @native = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub answers_native {
    my ( $src, $want, $name ) = @_;
    answers( $src, $want, $name, targets => [@native] );
}

# An untyped receiver (`my $p = P->new(); $p->m()`) holds a box whose payload is the object pointer, but the callee
# dereferences `$self` as the object itself. Before the fix the box pointer was passed straight through as `$self`, so
# the method read the field area at offsets that started at the box header and returned garbage. The receiver is now
# unboxed to its payload at the call site; a pointer-shaped receiver (`my ptr $p`, `$self`, a class name) is untouched.
subtest 'a method call on an untyped receiver reads the object' => sub {
    answers_native(
        'class P { field i64 $x :param; method get() :returns(i64) { return $self->x; } }'
            . ' my $p = P->new(x => 7); return $p->get();',
        7, 'the Any receiver is unboxed to the object before $self is passed'
    );
    answers_native(
        'class P { field i64 $x :param; field i64 $y :param;'
            . ' method total() :returns(i64) { return $self->x + $self->y; } }'
            . ' my $p = P->new(20, 22); return $p->total();',
        42, 'the object address is right for a field past the first'
    );
    answers_native(
        'class P { field i64 $x :param; field Any $s :param;'
            . ' method get() :returns(i64) { return $self->x; } }'
            . ' my $p = P->new(x => 11, s => 99); return $p->get();',
        11, 'a dynamic field after the fixed one does not shift the fixed field read'
    );
};

subtest 'a write through an untyped receiver reaches the object' => sub {
    answers_native(
        'class C { field i64 $a :param; field i64 $b :param;'
            . ' method set_a(i64 $v) :returns(ptr) { $self->a = $v; return $self; }'
            . ' method get_b() :returns(i64) { return $self->b; } }'
            . ' my $c = C->new(a => 1, b => 41); $c->set_a(100); return $c->get_b() + 1;',
        42, 'the write lands on the object and leaves the other field intact'
    );
};

subtest 'a field read through an untyped receiver' => sub {
    answers_native(
        'class P { field i64 $x :param; } my $p = P->new(x => 7); return $p->x;',
        7, 'a bare field access unboxes the receiver too'
    );
    answers_native(
        'class P { field i64 $x :param; } my $p = P->new(x => 40); $p->x = $p->x + 2; return $p->x;',
        42, 'a field written through the unboxed receiver is read back'
    );
};

subtest 'a writer that returns $self chains from an untyped receiver' => sub {
    answers_native(
        'class C { field i64 $n :param :writer; }'
            . ' my $c = C->new(n => 0); $c->set_n(5)->set_n(6); return $c->n;',
        6, 'only the untyped receiver is unboxed; the returned pointer is a plain receiver'
    );
};

subtest 'an untyped receiver of a derived class' => sub {
    answers_native(
        'class Animal { field i64 $legs :param; method legs() :returns(i64) { return $self->legs; } }'
            . ' class Dog :isa(Animal) { field i64 $tail :param; }'
            . ' my $d = Dog->new(legs => 4, tail => 1); return $d->legs();',
        4, 'the inherited method resolves and reads through the unboxed receiver'
    );
};

subtest 'a pointer-shaped receiver is passed as it stands' => sub {
    answers_native(
        'class P { field i64 $x :param; method get() :returns(i64) { return $self->x; } }'
            . ' my ptr $p = P->new(x => 8); return $p->get();',
        8, 'a statically typed receiver is not unboxed'
    );
};

subtest 'the same untyped receiver is usable for several calls' => sub {
    answers_native(
        'class P { field i64 $x :param; method get() :returns(i64) { return $self->x; } }'
            . ' my $p = P->new(x => 20); return $p->get() + $p->get() + 2;',
        42, 'each call unboxes the one box afresh'
    );
};

done_testing;
