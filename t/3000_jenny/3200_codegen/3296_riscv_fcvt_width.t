use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Lindsay;
use Brocken::Katsuro;
use Brocken::Jenny::Codegen::RISCV64;
use Brocken::Jenny::Codegen::RISCV64::Encodings qw[:all];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# The RISC-V converter hardcoded FCVT.D.L / FCVT.L.D for every int/float
# conversion, ignoring the float width. An f32 was therefore converted as if
# its register held a double, so f32 conversions returned garbage while f64
# worked. The lowerer emits a bare `scvtf`/`fcvtzs`, so the format (and the
# integer width) has to be chosen here, exactly as the ARM64 backend does.
#
# This is a codegen-level check so it runs on any host: t/1000_katsuro/
# 1076_float_conversion.t exercises the same path natively, but only on a
# RISC-V runner.

my $plat = Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu');
my $cg   = Brocken::Jenny::Codegen::RISCV64->new( platform => $plat );

my $I32 = Brocken::Lindsay::IR::Type::i32();
my $I64 = Brocken::Lindsay::IR::Type::i64();
my $F32 = Brocken::Lindsay::IR::Type::f32();
my $F64 = Brocken::Lindsay::IR::Type::f64();

# rs1 [19:15] and rd [11:7] are chosen by the register allocator; every other
# field (funct7, fmt, rs2, rm, opcode) identifies the instruction.
my $SIGNATURE = 0xFFF0707F;

sub conversion_signatures ($func) {
    my $bytes = $cg->emit_function($func);
    return map { $_ & $SIGNATURE } unpack( 'V*', $bytes );
}

sub sitofp_func ($it, $ft) {
    my $func = Brocken::Lindsay::IR::Function->new( name => 'sitofp', return_type => $ft );
    my $b    = Brocken::Lindsay::IR::Builder->new();
    $b->position_at_end( $func->append_block('entry') );
    my $slot = $b->build_alloca( $it, '%slot' );
    $b->build_store( Brocken::Lindsay::IR::Constant->new( type => $it, value => 42 ), $slot );
    my $val  = $b->build_load( $it, $slot, '%val' );
    my $conv = $b->build_sitofp( $val, $ft, '%conv' );
    $b->build_ret($conv);
    return $func;
}

sub fptosi_func ($ft, $it) {
    my $func = Brocken::Lindsay::IR::Function->new( name => 'fptosi', return_type => $it );
    my $b    = Brocken::Lindsay::IR::Builder->new();
    $b->position_at_end( $func->append_block('entry') );
    my $slot = $b->build_alloca( $ft, '%slot' );
    $b->build_store( Brocken::Lindsay::IR::Constant->new( type => $ft, value => 42.0 ), $slot );
    my $val  = $b->build_load( $ft, $slot, '%val' );
    my $conv = $b->build_fptosi( $val, $it, '%conv' );
    $b->build_ret($conv);
    return $func;
}

subtest 'int -> float selects the float and integer width' => sub {
    for my $case (
        [ $I32, $F32, FCVT_S_W, 'i32 -> f32 is FCVT.S.W' ],
        [ $I64, $F32, FCVT_S_L, 'i64 -> f32 is FCVT.S.L' ],
        [ $I32, $F64, FCVT_D_W, 'i32 -> f64 is FCVT.D.W' ],
        [ $I64, $F64, FCVT_D_L, 'i64 -> f64 is FCVT.D.L' ],
        )
    {
        my ( $it, $ft, $base, $label ) = @$case;
        my @sigs = conversion_signatures( sitofp_func( $it, $ft ) );
        ok( scalar( grep { $_ == ( $base | FP_OP ) } @sigs ), $label );
    }
};

subtest 'float -> int selects the float and integer width' => sub {
    for my $case (
        [ $F32, $I32, FCVT_W_S, 'f32 -> i32 is FCVT.W.S' ],
        [ $F64, $I32, FCVT_W_D, 'f64 -> i32 is FCVT.W.D' ],
        [ $F32, $I64, FCVT_L_S, 'f32 -> i64 is FCVT.L.S' ],
        [ $F64, $I64, FCVT_L_D, 'f64 -> i64 is FCVT.L.D' ],
        )
    {
        my ( $ft, $it, $base, $label ) = @$case;
        my @sigs = conversion_signatures( fptosi_func( $ft, $it ) );
        ok( scalar( grep { $_ == ( $base | FP_OP ) } @sigs ), $label );
    }
};

done_testing;
