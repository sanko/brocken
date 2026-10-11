use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Codegen::RISCV64;
use constant { OP_IMM => 0x13, OP => 0x33, LOAD => 0x03, STORE => 0x23, };
my %rid = (
    a0 => 10,
    a1 => 11,
    a2 => 12,
    a3 => 13,
    a4 => 14,
    a5 => 15,
    a6 => 16,
    a7 => 17,
    t0 => 5,
    t1 => 6,
    t2 => 7,
    t3 => 28,
    t4 => 29,
    t5 => 30,
    t6 => 31,
    sp => 2,
    s0 => 8
);
sub word { return unpack( 'V', substr( $_[0], $_[1] * 4, 4 ) ) }
subtest 'encode a spilled arithmetic source by pulling it into a scratch register' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu');

    # The pattern insert_spill_code leaves a both-spilled `add`/`mul` in: destination reloaded into the reserved spill
    # register, source left as a stack memory operand.  The encoder used to die resolving the mem source.
    my $mf = Brocken::Jenny::MIR::MachineFunction->new( name => 'spilled', frame_size => 0 );
    my $bb = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf->add_block($bb);
    my $i64   = Brocken::Lindsay::IR::Type::i64();
    my $mem   = Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => 'sp', disp => 0 }, type => $i64 );
    my $spill = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'a0' );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'add', operands => [ $spill, $mem ], comment => 'spilled add' ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mul', operands => [ $spill, $mem ], comment => 'spilled mul' ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [], comment => 'ret' ) );
    my $codegen = Brocken::Jenny::Codegen::RISCV64->new( platform => $platform );
    my ($bytes) = $codegen->_encode( $mf, {}, [], undef, undef, ['a0'] );
    is( length($bytes), 40, 'prologue + 2 loads + 2 arithmetic + epilogue + ret, all 4-byte words' );

    # word 4: the load that materializes the mem source of `add` (base sp, funct3 3 for i64, into scratch t0)
    is( word( $bytes, 3 ), ( 0 << 20 ) | ( $rid{sp} << 15 ) | ( 3 << 12 ) | ( $rid{t0} << 7 ) | LOAD, 'add source loaded from [sp+0]' );

    # word 5: add a0, a0, t0
    is(
        word( $bytes, 4 ),
        ( 0x00 << 25 ) | ( $rid{t0} << 20 ) | ( $rid{a0} << 15 ) | ( 0 << 12 ) | ( $rid{a0} << 7 ) | OP,
        'add reads the scratch, not the spilled memory'
    );

    # word 6: mul source loaded into the scratch; word 7: mul a0, a0, t0
    is( word( $bytes, 5 ), ( 0 << 20 ) | ( $rid{sp} << 15 ) | ( 3 << 12 ) | ( $rid{t0} << 7 ) | LOAD, 'mul source loaded the same way' );
    is(
        word( $bytes, 6 ),
        ( 0x01 << 25 ) | ( $rid{t0} << 20 ) | ( $rid{a0} << 15 ) | ( 0 << 12 ) | ( $rid{a0} << 7 ) | OP,
        'and the mul reads the scratch'
    );
};
#
done_testing;
