use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Codegen::RISCV64;
use constant { OP_IMM => 0x13, OP => 0x33, LOAD => 0x03, STORE => 0x23, };
my %rid = (
    a0  => 10,
    a1  => 11,
    a2  => 12,
    a3  => 13,
    a4  => 14,
    a5  => 15,
    a6  => 16,
    a7  => 17,
    t0  => 5,
    t1  => 6,
    t2  => 7,
    t3  => 28,
    t4  => 29,
    t5  => 30,
    t6  => 31,
    sp  => 2,
    s0  => 8,
    s10 => 26
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
subtest 'a wide-displacement spilled source reuses its scratch for the address' => sub {

    # The allocator's reload scratch (t6) can hold the destination of the very instruction whose memory source is
    # being loaded.  When the source slot is far enough down a large frame to need address materialisation, the
    # address scratch must not be that reload register: computing the address into t6 would destroy the value the
    # instruction is about to read.  A load overwrites its destination, so the source scratch can address through
    # itself and no second scratch is needed.
    my $platform = Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu');
    my $i64      = Brocken::Lindsay::IR::Type::i64();
    my $mf       = Brocken::Jenny::MIR::MachineFunction->new( name => 'wide_source', frame_size => 0 );
    my $bb       = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf->add_block($bb);
    my $mem   = Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => 'sp', disp => 4096 }, type => $i64 );
    my $spill = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 't6' );
    $bb->add_instruction(
        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mul', operands => [ $spill, $mem ], comment => 'spilled mul wide' ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [], comment => 'ret' ) );

    # Every non-reserved caller register carries a live value, so the only candidates for the source scratch are the
    # reserved reload registers.
    my %assignment;
    my @pressure = qw(a0 a1 a2 a3 a4 a5 a6 a7 t0 t1 t2 t3 t4 t5);
    $assignment{"%p$_"} = $pressure[$_] for 0 .. $#pressure;
    my $codegen   = Brocken::Jenny::Codegen::RISCV64->new( platform => $platform );
    my ($bytes)   = $codegen->_encode( $mf, \%assignment, [], undef, undef, [ 't6', 's10' ] );
    my @w         = map { unpack( 'V', substr( $bytes, $_ * 4, 4 ) ) } 0 .. length($bytes) / 4 - 1;
    my ($mul_idx) = grep { ( ( $w[$_] & 0x7f ) == OP ) && ( ( ( $w[$_] >> 25 ) & 0x7f ) == 0x01 ) } 0 .. $#w;
    ok defined $mul_idx, 'the spilled mul was encoded';
    my $src = ( $w[$mul_idx] >> 20 ) & 0x1f;    # second source of `mul a, a, src`
    my $ld  = $w[ $mul_idx - 1 ];
    is( $ld & 0x7f,           LOAD, 'the source load precedes the mul' );
    is( ( $ld >> 7 ) & 0x1f,  $src, 'the load writes the source scratch' );
    is( ( $ld >> 15 ) & 0x1f, $src, 'and addresses through that same scratch, not the reload register' );
    isnt( ( $ld >> 15 ) & 0x1f, $rid{t6}, 'the destination reload register t6 is never the address scratch' );
};
#
done_testing;
