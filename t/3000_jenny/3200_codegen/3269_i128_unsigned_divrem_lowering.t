use v5.42;
use Test2::V0 '!subtest';
use blib;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
use Math::BigInt;
#
my %class_to_triple = (
    'Brocken::Jenny::Lowerer::X86_64'  => 'x86_64-unknown-linux-gnu',
    'Brocken::Jenny::Lowerer::ARM64'   => 'aarch64-unknown-linux-gnu',
    'Brocken::Jenny::Lowerer::RISCV64' => 'riscv64-unknown-linux-gnu'
);
my @backends = (
    [ 'Brocken::Jenny::Lowerer::X86_64',  'X86_64' ],
    [ 'Brocken::Jenny::Lowerer::ARM64',   'ARM64' ],
    [ 'Brocken::Jenny::Lowerer::RISCV64', 'RISCV64' ],
    [ 'Brocken::Jenny::Lowerer::Wasm',    'Wasm' ]
);
my $big_const = sub {
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => $_[0]->copy );
};
my $i128 = sub { Brocken::Lindsay::IR::Type::i128() };

# Only the abs prologue and the sign epilogue are signed: the shift-subtract loop itself shifts and compares without
# looking at a sign bit on every backend, and div128_64 is an unsigned x86 DIV. A u128 operand used to take both of
# them anyway. These are the registers only those two blocks name, so their absence says the signed handling was
# skipped. t/3268 checks the arithmetic on the native host; this covers the three backends that cannot run here.
my $SIGNED_ONLY = qr/(?:_sgnd|_signv|_mskd|_mskv|_mskq|_mskr|_sqt)$/;
my $TWO127      = Math::BigInt->new(2)->bpow(127);
for my $backend (@backends) {
    my ( $class, $label ) = @$backend;
    my $platform = $class_to_triple{$class} ? Brocken::Katsuro::Platform::parse( $class_to_triple{$class} ) : undef;
    for my $operand ( [ Math::BigInt->new(3), 'small divisor', 'fast path' ],
        [ $TWO127->copy->badd(2), 'divisor above 2^127', 'shift-subtract loop' ], ) {
        my ( $divisor, $operand_desc, $path ) = @$operand;
        for my $op (qw[div udiv rem urem]) {
            my $func  = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i128->() );
            my $build = Brocken::Lindsay::IR::Builder->new();
            $build->position_at_end( $func->append_block('entry') );
            my $lhs = $big_const->( Math::BigInt->new(2)->bpow(127)->badd(6) );
            my $rhs = $big_const->($divisor);
            my $result
                = $op eq 'div' ? $build->build_div( $lhs, $rhs, '%r' ) :
                $op eq 'udiv'  ? $build->build_udiv( $lhs, $rhs, '%r' ) :
                $op eq 'rem'   ? $build->build_rem( $lhs, $rhs, '%r' ) :
                $build->build_urem( $lhs, $rhs, '%r' );
            $build->build_ret($result);
            my $lowerer = $platform ? $class->new( platform => $platform ) : $class->new();
            my @insts   = $lowerer->lower($func)->blocks->[0]->instructions->@*;
            my $signed  = grep {
                grep { defined $_->value && $_->value =~ $SIGNED_ONLY }
                    $_->operands->@*
            } @insts;
            my $is_signed = $op eq 'div' || $op eq 'rem';
            is( $signed ? 1 : 0, $is_signed ? 1 : 0, "$label i128 $op ($operand_desc): signed handling " . ( $is_signed ? 'present' : 'absent' ) );
            my ($idx) = grep { ( $insts[$_]->comment // '' ) eq 'i128 div store lo' } 0 .. $#insts;
            ok( defined $idx, "$label i128 $op ($operand_desc): result stored" );
            next unless defined $idx;
            my $store = $insts[$idx];

            # The other three backends name the source in the store itself. Wasm pushes it onto the stack first and
            # stores with the destination alone, so the source is the operand of the instruction before.
            my $src = $store->operands->[1] // $insts[ $idx - 1 ]->operands->[-1];
            ok( defined $src, "$label i128 $op ($operand_desc): source operand found" );
            next unless defined $src;
            like( $src->value // '', qr/_(?:q|r)_lo$/, "$label i128 $op ($operand_desc): takes the " . ( $op =~ /div/ ? 'quotient' : 'remainder' ) );
        }
    }
}
#
done_testing;
