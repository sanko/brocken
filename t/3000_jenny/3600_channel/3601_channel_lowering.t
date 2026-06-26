use v5.42;
use Test2::V0;
use lib 'lib', '../../lib', '../../../lib';
use Brocken::Katsuro;
use Brocken::Lindsay::IR;
use Brocken::Lindsay::IR::Builder;
use Brocken::Jenny::Lowerer::X86_64;
use Brocken::Jenny::Lowerer::ARM64;
use Brocken::Jenny::Lowerer::RISCV64;
use Brocken::Jenny::Lowerer::Wasm;
no warnings qw[experimental::class];
use feature qw[class];
my $i64  = Brocken::Lindsay::IR::Type::i64();
my $ptr  = Brocken::Lindsay::IR::Type::ptr();
my $void = Brocken::Lindsay::IR::Type::void();

# Helper: build a function with all 6 channel ops, lower it, return opcode count
sub build_and_lower {
    my ( $lowerer, $platform_str ) = @_;
    my $b    = Brocken::Lindsay::IR::Builder->new();
    my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i64 );
    $b->position_at_end( $main->append_block('entry') );

    my $ch = $b->build_chan_create( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 16 ), '%ch' );
    $b->build_chan_send( $ch, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 42 ) );
    $b->build_chan_recv( $ch, '%rv' );
    $b->build_chan_close($ch);
    $b->build_chan_try_send( $ch, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 99 ), '%ts' );
    $b->build_chan_try_recv( $ch, '%tr' );
    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ) );

    my $l;
    if ( $lowerer eq 'Brocken::Jenny::Lowerer::Wasm' ) {
        $l = $lowerer->new();
    }
    else {
        my $plat = Brocken::Katsuro::Platform::parse($platform_str);
        $l = $lowerer->new( platform => $plat );
    }
    my $mf = $l->lower($main);

    my %opcodes;
    for my $mbb ( $mf->blocks->@* ) {
        for my $inst ( $mbb->instructions->@* ) {
            $opcodes{ $inst->opcode }++;
        }
    }
    return \%opcodes;
}

# X86_64 lowering
{
    my $op = build_and_lower( 'Brocken::Jenny::Lowerer::X86_64', 'x86_64-unknown-linux-gnu' );
    ok $op->{mov}, 'X86_64: chan stubs produce mov (imm)';
    note "X86_64 opcodes: " . join(', ', sort keys %$op);
}

# ARM64 lowering
{
    my $op = build_and_lower( 'Brocken::Jenny::Lowerer::ARM64', 'aarch64-unknown-linux-gnu' );
    ok $op->{mov}, 'ARM64: chan stubs produce mov (imm)';
    note "ARM64 opcodes: " . join(', ', sort keys %$op);
}

# RISCV64 lowering
{
    my $op = build_and_lower( 'Brocken::Jenny::Lowerer::RISCV64', 'riscv64-unknown-linux-gnu' );
    ok $op->{mov}, 'RISCV64: chan stubs produce mov (imm)';
    note "RISCV64 opcodes: " . join(', ', sort keys %$op);
}

# Wasm lowering
{
    my $op = build_and_lower( 'Brocken::Jenny::Lowerer::Wasm', 'wasm32-unknown-unknown' );
    ok $op->{i64_const}, 'Wasm: chan stubs produce i64_const';
    ok $op->{local_set}, 'Wasm: chan stubs produce local_set';
    note "Wasm opcodes: " . join(', ', sort keys %$op);
}

done_testing;
