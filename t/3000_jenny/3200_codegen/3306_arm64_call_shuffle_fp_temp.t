use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Codegen::ARM64;
use Brocken::Jenny::RegAlloc;

sub mk_mf {
    my $i64 = Brocken::Lindsay::IR::Type::i64();

    # A two-argument floating copy pair whose registers cross: the copy into v7 reads
    # v6 and the copy into v6 reads v7, so neither can start first.  The scheduler has
    # to park one source in its floating-point temporary to break the cycle.  v7 is an
    # argument register here, so an fp spill temp who is v7 is also paired with the
    # source of one copy and the temporary cannot be used; the run has to be left
    # unscheduled with its sources crossed.  The ABI's fp_entry_shuffle_temp (v31) is
    # outside every register set and is free to park in.
    my $mf = Brocken::Jenny::MIR::MachineFunction->new( name => 'shuf', frame_size => 0 );
    my $bb = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    my $t  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%t' );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'add', operands => [ $t, $t, $t ], comment => 'terminator' ) );
    $bb->add_instruction(
        Brocken::Jenny::MIR::MachineInstruction->new(
            opcode   => 'fmov',
            operands => [
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'v7' ),
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'v6' )
            ],
            comment => 'arg 0'
        )
    );
    $bb->add_instruction(
        Brocken::Jenny::MIR::MachineInstruction->new(
            opcode   => 'fmov',
            operands => [
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'v6' ),
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'v7' )
            ],
            comment => 'arg 1'
        )
    );
    $bb->add_instruction(
        Brocken::Jenny::MIR::MachineInstruction->new(
            opcode   => 'call_indirect',
            operands => [
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%ret', type => $i64 ),
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%fn',  type => $i64 )
            ],
            comment => 'call'
        )
    );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] ) );
    $mf->add_block($bb);
    return $mf;
}

sub has_save_inst {
    my ($mf) = @_;
    for my $bb ( $mf->blocks->@* ) {
        for my $inst ( $bb->instructions->@* ) {
            return 1 if ( $inst->comment // '' ) =~ /^call-shuffle save /;
        }
    }
    return 0;
}
subtest 'a spill temp that is an argument register blocks the shuffle' => sub {
    my $mf_v7 = mk_mf();
    my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new();
    $alloc->fix_call_shuffle( $mf_v7, {}, undef, 'v7' );
    ok !has_save_inst($mf_v7), 'an fp spill temp of v7 is touched by the run and the shuffle is skipped';
    my $mf_v31 = mk_mf();
    $alloc->fix_call_shuffle( $mf_v31, {}, undef, 'v31' );
    ok has_save_inst($mf_v31), 'the ABI fp entry shuffle temp schedules the same run';
};
subtest 'the ARM64 backend passes the ABI fp entry shuffle temp to the call shuffle' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu');
    my $codegen  = Brocken::Jenny::Codegen::ARM64->new( platform => $platform );
    my $blob     = $codegen->_emit_single_mf( mk_mf() );
    my $bytes    = $blob->{bytes};
    like $bytes, qr/\Q@{[ pack( 'V', 0x1E6040DF ) ]}\E/s, 'the parked copy fmov v31, v6 (0x1E6040DF) survives codegen';
};
done_testing;
