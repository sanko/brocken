use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Every backend has to agree on one fat scalar layout, or a value boxed by one
# path and unboxed by another reads the wrong eight bytes. The first eight
# bytes are the reference-counting header from docs/spec.md section 4.2 and
# eg/ABI.md section 5, and the payload follows at offset 8.

my $i32 = Brocken::Lindsay::IR::Type::i32();

# The header is one 64-bit word: u16 refcount at +0, u8 flags at +2, u8 tag at
# +3, u32 aux at +4. i32 payload, so the tag is 1.
my $EXPECT_HEADER = 1 | ( 1 << 24 );

my @backends = (
    { name => 'x86_64',  lowerer => sub { Brocken::Jenny::Lowerer::X86_64->new( platform => Brocken::Katsuro::Platform::parse('x86_64-unknown-linux-gnu') ) } },
    { name => 'aarch64', lowerer => sub { Brocken::Jenny::Lowerer::ARM64->new( platform => Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu') ) } },
    { name => 'riscv64', lowerer => sub { Brocken::Jenny::Lowerer::RISCV64->new( platform => Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu') ) } },
    { name => 'wasm',    lowerer => sub { Brocken::Jenny::Lowerer::Wasm->new() } },
);

sub lower_box {
    my $lowerer = shift->();
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $boxed = $builder->build_box( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ), '%boxed' );
    my $val   = $builder->build_unbox( $boxed, $i32, '%val' );
    $builder->build_ret($val);
    my $mf = $lowerer->lower($func);
    return map { $_->instructions->@* } $mf->blocks->@*;
}

# The native backends fold the offset into a mem operand; wasm computes it with
# an i32_add fed by an i32_const, so fall back to the constant that built the
# address of the instruction carrying the comment.
sub offset_of {
    my ( $insts, $comment ) = @_;
    for my $i ( 0 .. $#{$insts} ) {
        next if $insts->[$i]->comment ne $comment;
        for my $opnd ( $insts->[$i]->operands->@* ) {
            return $opnd->value->{disp} if $opnd->kind eq 'mem' && ref $opnd->value eq 'HASH';
        }

        # wasm: the address is the running sum pushed before the access, so the
        # offset is the last i32_const ahead of the i32_add that formed it.
        my $add_at;
        for my $j ( reverse 0 .. $i - 1 ) {
            next unless $insts->[$j]->opcode eq 'i32_add';
            $add_at = $j;
            last;
        }
        return undef unless defined $add_at;
        for my $j ( reverse 0 .. $add_at - 1 ) {
            my $val = $insts->[$j]->operands->[0]->value;
            return $val if $insts->[$j]->opcode eq 'i32_const' && $val =~ /\A-?[0-9]+\z/;
        }
    }
    return undef;
}

# The value being stored. The native backends carry it on the store itself;
# wasm pushes it as a separate i64_const just ahead of the access.
sub immediate_of {
    my ( $insts, $comment ) = @_;
    for my $i ( 0 .. $#{$insts} ) {
        next if $insts->[$i]->comment ne $comment;
        for my $j ( $i, $i - 1 ) {
            next if $j < 0;
            for my $opnd ( $insts->[$j]->operands->@* ) {
                return $opnd->value if $opnd->kind eq 'imm';
            }
        }
    }
    return undef;
}

subtest 'every backend uses the same fat scalar offsets' => sub {
    for my $backend (@backends) {
        subtest $backend->{name} => sub {
            my $insts = [ lower_box($backend->{lowerer}) ];
            is offset_of( $insts, 'box: store payload' ), 8, 'payload is stored at offset 8';
            is offset_of( $insts, 'box: store header' ), 0, 'header is stored at offset 0';
            is offset_of( $insts, 'unbox: load payload' ), 8, 'payload is loaded from offset 8';
            is immediate_of( $insts, 'box: store header' ), $EXPECT_HEADER,
                'header word packs a refcount of 1 and the type tag at offset 3';

            # Nothing may still be writing a bare 64-bit tag into the payload
            # slot, which is what the old split layout did.
            ok !( grep { $_->comment eq 'box: store tag' } @$insts ), 'no separate tag store remains';
        };
    }
};

subtest '_box_header agrees across the four lowerer copies' => sub {
    my $header = $EXPECT_HEADER;
    is( $header & 0xFFFF,               1, 'u16 refcount at offset 0 is 1' );
    is( ( $header >> 16 ) & 0xFF,       0, 'u8 gc_flags at offset 2 is 0' );
    is( ( $header >> 24 ) & 0xFF,       1, 'u8 type_tag at offset 3 is the i32 tag' );
    is( ( $header >> 32 ) & 0xFFFFFFFF, 0, 'u32 aux at offset 4 is 0' );

    for my $backend (@backends) {
        is $backend->{lowerer}->()->_box_header(1), $header, "$backend->{name} packs the header identically";
    }
};

done_testing;
