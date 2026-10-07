use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Lindsay::IR;

sub find_function {
    my ( $mod, $name ) = @_;
    for my $f ( $mod->functions->@* ) {
        return $f if $f->name eq $name;
    }
    return undef;
}
subtest 'Class instances carry an 8-byte object header' => sub {
    my $c   = Brocken->new;
    my $mod = eval { $c->compile(<<'BROCKEN') };
class Point {
    field i64 $x :param;
    field i64 $y :param;
}
my ptr $p = Point->new(x => 10, y => 20);
return $p->x;
BROCKEN
    ok( !$@, 'compiled class program' ) or diag $@;
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/Brocken::Runtime::bump_alloc\(ptr\s+\S+,\s+i64\s+24/, 'new allocates header + both fields (8 + 16 = 24)' );
    like( $text, qr/store\s+i64\s+67108865/, 'new initializes the object header (refcount 1, tag 4 = ptr)' );
    my ($gep) = grep { $_->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr') && $_->base_type->kind eq 'struct' }
        map { $_->instructions->@* } $f->blocks->@*;
    ok( $gep, 'found struct GEP for field access' );
    is( $gep->base_type->field_offset(0), 8,  'first field lives at offset 8, after the header' );
    is( $gep->base_type->field_offset(1), 16, 'second field lives at offset 16' );
};
done_testing;