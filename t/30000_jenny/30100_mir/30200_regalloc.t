use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Jenny::RegAlloc;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
#
subtest LiveInterval => sub {
    my $li = Brocken::Jenny::RegAlloc::LiveInterval->new( name => '%x', start => 0, end => 5 );
    isa_ok $li, ['Brocken::Jenny::RegAlloc::LiveInterval'], 'live interval construction';
    is $li->name,  '%x', 'interval name';
    is $li->start, 0,    'interval start';
    is $li->end,   5,    'interval end';
};
subtest 'LinearScan basic allocation' => sub {
    my $brocken  = Brocken->new();
    my $platform = $brocken->platform;
    my $mf       = Brocken::Jenny::MIR::MachineFunction->new( name => 'test', frame_size => 0 );
    my $bb       = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf->add_block($bb);
    my $vreg_a = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%a' );
    my $vreg_b = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%b' );
    my $imm_1  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm',      value => 1 );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'add', operands => [ $vreg_a, $imm_1 ] ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'add', operands => [ $vreg_b, $vreg_a ] ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] ) );
    my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new()->allocate( $mf, $platform );
    is $alloc, hash {
        field assignment => hash {
            field '%a' => D();
            field '%b' => D();
            end
        };
        field used_callee     => E();
        field spill_slots     => E();
        field spill_temp      => E();
        field spill_addr_temp => E();
        end
    }, 'allocation result';
};
subtest 'LinearScan with many virtual registers' => sub {
    my $brocken  = Brocken->new();
    my $platform = $brocken->platform;
    my $mf       = Brocken::Jenny::MIR::MachineFunction->new( name => 'heavy', frame_size => 0 );
    my $bb       = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf->add_block($bb);
    my $imm = Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 );
    my @vregs;
    for my $i ( 1 .. 20 ) {
        my $vr = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => "%r$i" );
        push @vregs, $vr;
        $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'add', operands => [ $vr, $imm ] ) );
    }
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] ) );
    my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new->allocate( $mf, $platform );
    is scalar( keys %{ $alloc->{assignment} } ), 20, 'all 20 vregs have assignments';
};
#
done_testing;
