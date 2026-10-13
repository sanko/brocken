use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Lindsay::IR;
use Test2::Tools::Brocken qw[answers executable_targets];

# A class field is placed at its natural alignment, so a narrow field declared before a wider one does not shift the
# wider one off its boundary. The offsets live on the struct type attached to the field GEPs, which is what every
# backend reads for `getelementptr`.
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

subtest 'a narrow field pads the wider field that follows' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class P {
    field i8 $a :param :reader;
    field i64 $b :param :reader;
}
my ptr $p = P->new(a => 1, b => 2);
return $p->b();
BROCKEN
    my $st = find_struct_type( $mod, 'P' );
    ok( $st, 'found the struct type for P' );
    is( $st->field_offset(0), 8,  'i8 lands right after the 8-byte header' );
    is( $st->field_offset(1), 16, 'i64 is padded up to its 8-byte alignment' );
    is( $st->struct_size,     24, 'total size includes the padding' );
};

subtest 'a trailing narrow field is tail-padded' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class Q {
    field i64 $a :param :reader;
    field i8 $b :param :reader;
}
my ptr $q = Q->new(a => 1, b => 2);
return $q->b();
BROCKEN
    my $st = find_struct_type( $mod, 'Q' );
    ok( $st, 'found the struct type for Q' );
    is( $st->field_offset(0), 8,  'i64 sits at the first 8-byte slot' );
    is( $st->field_offset(1), 16, 'i8 starts after the i64' );
    is( $st->struct_size,     24, 'the object is padded out to its 8-byte alignment' );
};

subtest 'an all-i64 class keeps the packed layout' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class R {
    field i64 $a :param :reader;
    field i64 $b :param :reader;
}
my ptr $r = R->new(a => 1, b => 2);
return $r->b();
BROCKEN
    my $st = find_struct_type( $mod, 'R' );
    ok( $st, 'found the struct type for R' );
    is( $st->field_offset(0), 8,  'first i64' );
    is( $st->field_offset(1), 16, 'second i64 immediately after' );
    is( $st->struct_size,     24, 'no padding is introduced' );
};

# The layout change is invisible to correct programs: the aligned fields still round-trip.
my @native = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
subtest 'mixed-width fields read back correctly' => sub {
    answers(
        'class M {' .
            ' field i8 $a :param :reader;' .
            ' field i64 $b :param :reader;' .
            ' field i32 $c :param :reader; }' .
            ' my ptr $m = M->new(a => 3, b => 40, c => -1);' .
            ' return $m->a() + $m->b() + $m->c();',
        42, 'i8/i64/i32 fields round-trip through the aligned layout', targets => [@native]
    );
};
done_testing;
