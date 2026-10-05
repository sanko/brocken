use v5.42;
use Test2::V0 '!subtest';
use blib;
use Test2::Tools::Brocken qw[run_exec];
use Brocken;
use Brocken::Lindsay;
use Math::BigInt;
use Time::HiRes qw[time];

#
my $brocken   = Brocken->new();
my $platform  = $brocken->platform;
my $big_const = sub {
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => $_[0]->copy );
};
my $TWO127   = Math::BigInt->new(2)->bpow(127);
my $TWO128   = Math::BigInt->new(2)->bpow(128);
my $TWO64    = Math::BigInt->new(2)->bpow(64);
my $ALL_ONES = $TWO128->copy->bsub(1);

# udiv/urem took the signed path: both operands were replaced by their absolute values and the sign was reapplied to the
# quotient and remainder afterwards. For a divisor below 2^64 that returns the right answer, because undoing a sign with
# an exclusive or and a subtract is exact modulo 2^128. It stops agreeing as soon as the division truncates -- the
# magnitude was divided, not the value -- so a u128 dividend with bit 127 set came back with the wrong quotient, and a
# u128 divisor was divided by its own negation. Both cases are covered below with the expected value computed here, so
# the test states the arithmetic rather than a number chosen to fit an exit code.
for my $tc (
    [ udiv => $TWO127->copy->badd(6), Math::BigInt->new(3),   '2^127+6 udiv 3 (fast path, bit 127 set)' ],
    [ udiv => $TWO127->copy->badd(6), $TWO127->copy->badd(2), '2^127+6 udiv 2^127+2 (divisor above 2^127)' ],
    [ udiv => $ALL_ONES->copy,        Math::BigInt->new(3),   '2^128-1 udiv 3 (all bits set)' ],
    [ udiv => $ALL_ONES->copy,        $TWO64->copy,           '2^128-1 udiv 2^64' ],
    [ udiv => $ALL_ONES->copy,        Math::BigInt->new(1),   '2^128-1 udiv 1' ],
    [ udiv => $TWO127->copy,          $TWO127->copy->badd(2), '2^127 udiv 2^127+2 (quotient 0)' ],
    [ udiv => Math::BigInt->new(42),  Math::BigInt->new(1),   '42 udiv 1 (narrow operands)' ],
    [ urem => $TWO127->copy->badd(6), Math::BigInt->new(3),   '2^127+6 urem 3 (fast path, bit 127 set)' ],
    [ urem => $TWO127->copy->badd(6), $TWO127->copy->badd(2), '2^127+6 urem 2^127+2 (divisor above 2^127)' ],
    [ urem => $ALL_ONES->copy,        Math::BigInt->new(3),   '2^128-1 urem 3 (all bits set)' ],
    [ urem => $ALL_ONES->copy,        $TWO64->copy->bsub(1),  '2^128-1 urem 2^64-1' ],
    [ urem => $TWO127->copy,          $TWO127->copy->badd(2), '2^127 urem 2^127+2 (remainder is the dividend)' ],
    [ urem => Math::BigInt->new(42),  Math::BigInt->new(5),   '42 urem 5 (narrow operands)' ],
    [ urem => Math::BigInt->new(43),  Math::BigInt->new(5),   '43 urem 5 (narrow operands)' ]
) {
    my ( $op, $lhs, $rhs, $desc ) = @$tc;
    my $expected = $op eq 'udiv' ? $lhs->copy->bfdiv($rhs) : $lhs->copy->bmod($rhs);
    my $t0       = time;
    my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder  = Brocken::Lindsay::IR::Builder->new();
    my $entry    = $func->append_block('entry');
    my $t_block  = $func->append_block('if.then');
    my $f_block  = $func->append_block('if.else');
    $builder->position_at_end($entry);
    my $result = $op eq 'udiv' ? $builder->build_udiv( $big_const->($lhs), $big_const->($rhs), '%r' ) :
        $builder->build_urem( $big_const->($lhs), $big_const->($rhs), '%r' );
    my $cond = $builder->build_icmp( 'eq', $result, $big_const->($expected), '%cmp' );
    $builder->build_cond_br( $cond, $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0 ) );
    my $codegen = $brocken->codegen;
    my $bytes   = $codegen->emit_function($func);
    my $t1      = time;
    diag( "$desc: emit=" . int( ( $t1 - $t0 ) * 1000 + 0.5 ) . 'ms bytes=' . length($bytes) );
    ok( length($bytes) > 0, "Generated native i128 $op bytes for $desc on " . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = $brocken->tmpdir . "/i128_unsigned_${op}_native" . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        my $t2 = time;
        diag( "$desc: link=" . int( ( $t2 - $t1 ) * 1000 + 0.5 ) . 'ms' );
        ok( -e $output_file, "Native i128 $op file exists for $desc" );
        run_exec(
            $output_file,
            expected_exit => 42,
            platform      => $platform,
            name          => "Native i128 $desc returned " . $expected->as_hex . " on " . $platform->friendly
        );
        my $t3 = time;
        diag( "$desc: exec=" . int( ( $t3 - $t2 ) * 1000 + 0.5 ) . 'ms total=' . int( ( $t3 - $t0 ) * 1000 + 0.5 ) . 'ms' );
    }
}
#
done_testing;
