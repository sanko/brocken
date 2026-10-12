use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# The class runtime is exercised on the native targets: the array forms address raw object memory with a struct GEP,
# which the Wasm backend does not model the same way.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
my %native         = ( targets => [@native_targets] );

# An inline array field, `field [T; N] $name`, reserves N elements inside the object. Inside a method the field is
# addressed as `@name[i]`; from outside it is `$obj->name[i]`, and a `:reader` hands back the element base.
subtest 'inline array field: read and write in place' => sub {
    answers(
        'class Vec {' .
            ' field [i64; 3] $xs :reader;' .
            ' method fill() :returns(i64) { @xs[0] = 10; @xs[1] = 20; @xs[2] = 12; return 0; }' .
            ' method sum() :returns(i64) { return @xs[0] + @xs[1] + @xs[2]; }' .
            ' }' .
            ' my ptr $v = Vec->new(); $v->fill(); return $v->sum();',
        42, '@xs[i] reads and writes the inline storage', %native
    );
    answers(
        'class V { field [i64; 2] $xs;' .
            ' method put(i64 $i, i64 $v) :returns(i64) { @xs[$i] = $v; return 0; } }' .
            ' my ptr $v = V->new(); $v->put(1, 33); return $v->xs[1];',
        33, '$obj->xs[i] addresses the same storage', %native
    );
};

# A field after an inline array must start past the whole array, so the element count has to feed the layout.
subtest 'fields after an inline array keep their offsets' => sub {
    answers(
        'class Mix {' .
            ' field i64 $a :param :reader;' .
            ' field [i64; 2] $b :reader;' .
            ' field i64 $c :param :reader;' .
            ' method setb(i64 $x, i64 $y) :returns(i64) { @b[0] = $x; @b[1] = $y; return 0; }' .
            ' method sum() :returns(i64) { return $a + @b[0] + @b[1] + $c; }' .
            ' }' .
            ' my ptr $m = Mix->new(a => 1, c => 100); $m->setb(20, 21); return $m->sum();',
        142, 'a scalar field declared after an inline array is still reachable', %native
    );
};

# A pointer array field, `field T @name`, is one slot holding an element base. `:param`/`:writer` take that pointer;
# indexing the field walks the elements it points at.
subtest 'pointer array field' => sub {
    answers(
        'class Buf { field i64 @xs :param :reader;' .
            ' method at(i64 $i) :returns(i64) { return @xs[$i]; } }' .
            ' my [i64; 3] $a; @a[0] = 7; @a[1] = 8; @a[2] = 9;' .
            ' my ptr $b = Buf->new(xs => @a); return $b->at(1);',
        8, ':param stores the base and @xs[i] walks it', %native
    );
    answers(
        'class W { field i64 @ys :param :writer;' .
            ' method at(i64 $i) :returns(i64) { return @ys[$i]; } }' .
            ' my [i64; 2] $a; @a[0] = 4; @a[1] = 5;' .
            ' my ptr $w = W->new(ys => @a);' .
            ' my [i64; 2] $b; @b[0] = 40; @b[1] = 50;' .
            ' $w->set_ys(@b); return $w->at(1);',
        50, 'the writer replaces the base pointer', %native
    );
};

subtest 'a reader supplies another object a pointer array' => sub {
    answers(
        'class Src { field [i64; 2] $xs :reader; method put() :returns(i64) { @xs[0] = 5; @xs[1] = 6; return 0; } }' .
            ' class Dst { field i64 @ys :param; method at(i64 $i) :returns(i64) { return @ys[$i]; } }' .
            ' my ptr $s = Src->new(); $s->put();' .
            ' my ptr $d = Dst->new(ys => $s->xs()); return $d->at(0) + $d->at(1);',
        11, 'the base from an inline array reader indexes as a pointer array', %native
    );
};

# A hash field, `field T %name`, is an opaque pointer slot holding heap hash data; it stores and returns the pointer
# but has no lookup yet.
subtest 'hash field stores and returns its pointer' => sub {
    answers( 'class H { field i64 %h :param :reader; method ok() :returns(i64) { return 0; } }' .
            ' my ptr $h = H->new(h => (a => 1)); return $h->ok();',
        0, 'a hash literal may be passed to a hash field', %native );
    answers( 'class HB { field i64 %h :reader :writer; method ok() :returns(i64) { return 0; } }' .
            ' my ptr $b = HB->new(); $b->set_h((a => 1))->ok(); return $b->ok();',
        0, 'the hash writer chains and returns the receiver', %native );
};

subtest 'the forms that cannot work are rejected at compile time' => sub {
    my $inline_param
        = eval { Brocken->new->compile('class C { field [i64; 2] $xs :param; } C->new(); return 0;'); 1 };
    ok( !$inline_param, 'an inline array field cannot be :param' );
    like( $@, qr/cannot be :param/, 'the error says why' );

    my $dynamic_size = eval { Brocken->new->compile('class C { field [i64; n] $xs; } C->new(); return 0;'); 1 };
    ok( !$dynamic_size, 'an inline array field needs a constant element count' );
    like( $@, qr/constant element count/, 'the error says why' );
};

done_testing;
