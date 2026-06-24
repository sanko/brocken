use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'LiveInterval' => sub {
    my $li = Brocken::Jenny::RegAlloc::LiveInterval->new( name => '%x', start => 0, end => 5 );
    isa_ok $li, ['Brocken::Jenny::RegAlloc::LiveInterval'], 'live interval construction';
    is $li->name,  '%x', 'interval name';
    is $li->start, 0,    'interval start';
    is $li->end,   5,    'interval end';
};
subtest 'LinearScan basic allocation' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('x86_64-unknown-linux-gnu');
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
    ok ref($alloc) eq 'HASH',              'allocation result is a hashref';
    ok exists $alloc->{assignment},        'has assignment';
    ok exists $alloc->{used_callee},       'has used_callee';
    ok exists $alloc->{spill_slots},       'has spill_slots';
    ok exists $alloc->{spill_temp},        'has spill_temp';
    ok defined $alloc->{assignment}{'%a'}, '%a assigned to a register';
    ok defined $alloc->{assignment}{'%b'}, '%b assigned to a register';
};
subtest 'LinearScan with many virtual registers' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('x86_64-unknown-linux-gnu');
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
    my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new()->allocate( $mf, $platform );
    is scalar( keys %{ $alloc->{assignment} } ), 20, 'all 20 vregs have assignments';
};
done_testing;
