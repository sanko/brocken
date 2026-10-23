use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Lindsay::IR;
use Test2::Tools::Brocken qw[answers executable_targets];

# The class runtime is exercised on the native targets: an object is raw memory addressed with a struct GEP, which
# the Wasm backend does not model the same way.
my @native = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub find_struct_type {
    my ( $mod, $name ) = @_;
    for my $f ( $mod->functions->@* ) {
        for my $b ( $f->blocks->@* ) {
            for my $i ( $b->instructions->@* ) {
                next unless $i->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr');
                my $bt = $i->base_type;
                next unless $bt->kind eq 'struct' && $bt->struct_name eq $name;
                return $bt;
            }
        }
    }
    return undef;
}
subtest 'the derived struct lays the parent field block first' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class Base {
    field i64 $a :param :reader;
}
class Derived :isa(Base) {
    field i64 $b :param :reader;
}
my ptr $d = Derived->new(a => 1, b => 2);
return $d->b();
BROCKEN
    my $base = find_struct_type( $mod, 'Base' );
    my $der  = find_struct_type( $mod, 'Derived' );
    ok( $base, 'found the Base struct' );
    ok( $der,  'found the Derived struct' );
    is( $base->field_offset(0), 8,  'Base.a starts after the header' );
    is( $der->field_offset(0),  8,  'Derived keeps the inherited a at the same offset' );
    is( $der->field_offset(1),  16, 'Derived.b follows the parent block' );
    is( $der->struct_size,      24, 'Derived object is the whole chain' );
};
subtest 'a derived class may be declared before its parent' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class Child :isa(Parent) {
    field i64 $b :param :reader;
}
class Parent {
    field i64 $a :param :reader;
}
my ptr $c = Child->new(a => 40, b => 2);
return $c->a() + $c->b();
BROCKEN
    my $der = find_struct_type( $mod, 'Child' );
    is( $der->field_offset(0), 8,  'inherited a lands first' );
    is( $der->field_offset(1), 16, 'own b follows' );
};
subtest 'an inherited method is callable on the derived object' => sub {
    answers(
        'class Animal { field i64 $legs :param :reader;' .
            ' method describe() :returns(i64) { return $legs + 1; } }' .
            ' class Dog :isa(Animal) { field i64 $tail :param :reader; }' .
            ' my ptr $d = Dog->new(legs => 4, tail => 1);' .
            ' return $d->describe() + $d->tail();',
        6,
        'inherited describe() reads the inherited field',
        targets => [@native]
    );
};
subtest 'constructor chaining takes parent params first' => sub {
    answers(
        'class Animal { field i64 $legs :param :reader; }' .
            ' class Dog :isa(Animal) { field i64 $tail :param :reader; }' .
            ' my ptr $d = Dog->new(4, 3);' .
            ' return $d->legs() * 10 + $d->tail();',
        43,
        'positional order is root then derived',
        targets => [@native]
    );
};
subtest 'SUPER:: reaches the overridden parent method' => sub {
    answers(
        'class Base { field i64 $n :param :reader;' .
            ' method value() :returns(i64) { return $n; } }' .
            ' class Doubler :isa(Base) {' .
            ' method value() :returns(i64) { return $self->SUPER::value() * 2; } }' .
            ' my ptr $d = Doubler->new(n => 21);' .
            ' return $d->value();',
        42,
        'Doubler::value calls Base::value through SUPER::',
        targets => [@native]
    );
};
subtest 'a parent field default runs for the derived constructor' => sub {
    answers(
        'class Base { field i64 $a :reader = 40; }' .
            ' class Derived :isa(Base) { field i64 $b :reader = 2; }' .
            ' my ptr $d = Derived->new();' .
            ' return $d->a() + $d->b();',
        42,
        'the inherited field default is applied',
        targets => [@native]
    );
};
subtest 'ADJUST runs root-first' => sub {
    answers(
        'class Base { field i64 $x :reader = 0; ADJUST { $x = $x + 1; } }' .
            ' class Derived :isa(Base) { field i64 $y :reader = 0; ADJUST { $y = $y + 10; } }' .
            ' my ptr $d = Derived->new();' .
            ' return $d->x() * 100 + $d->y();',
        110,
        'the base ADJUST runs before the derived ADJUST',
        targets => [@native]
    );
};
subtest 'an inherited :reader still answers for the derived object' => sub {
    answers(
        'class Base { field i64 $secret :param :reader; }' .
            ' class Derived :isa(Base) { field i64 $own :param :reader; }' .
            ' my ptr $d = Derived->new(secret => 7, own => 3);' .
            ' return $d->secret() * 10 + $d->own();',
        73,
        'the inherited accessor reads the inherited field',
        targets => [@native]
    );
};

# Fields are lexical to the class that declares them, so neither an outside field access nor a subclass body can
# name an inherited field directly; an inherited accessor is the way in.
subtest 'fields are not inherited' => sub {
    my $c  = Brocken->new;
    my $ok = eval {
        $c->compile( 'class Base { field i64 $a; } class Derived :isa(Base) { }' . ' my ptr $d = Derived->new(); return $d->a;' );
        1;
    };
    ok( !$ok, 'an outside access to an inherited field is rejected' );
    like( $@, qr/Unknown field 'a' in class 'Derived'/, 'the error names the class' );
    my $c2  = Brocken->new;
    my $ok2 = eval {
        $c2->compile( 'class Base { field i64 $a; }' .
                ' class Derived :isa(Base) { method peek() :returns(i64) { return $a; } }' . ' my ptr $d = Derived->new(); return $d->peek();' );
        1;
    };
    ok( !$ok2, 'a subclass method cannot name an inherited field' );
    like( $@, qr/Undefined variable 'a'/, 'the error names the missing binding' );
};
subtest ':isa diagnostics' => sub {
    my $unknown = eval { Brocken->new->compile('class D :isa(Nope) { }'); 1 };
    ok( !$unknown, 'an unknown superclass is rejected' );
    like( $@, qr/Unknown superclass 'Nope'/, 'the error names the superclass' );
    my $cycle = eval { Brocken->new->compile('class A :isa(B) { } class B :isa(A) { }'); 1 };
    ok( !$cycle, 'an inheritance cycle is rejected' );
    like( $@, qr/cycle/i, 'the error mentions the cycle' );
    my $twice = eval { Brocken->new->compile('class A { } class B { } class D :isa(A) :isa(B) { }'); 1 };
    ok( !$twice, 'more than one :isa is rejected' );
    like( $@, qr/more than one :isa/, 'the error explains the limit' );
    my $self = eval { Brocken->new->compile('class A :isa(A) { }'); 1 };
    ok( !$self, 'a class cannot inherit from itself' );
    like( $@, qr/cannot inherit from itself/, 'the error says why' );
};
done_testing;
