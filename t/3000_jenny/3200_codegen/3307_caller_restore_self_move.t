use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

sub mk_mf {
    my $mf = Brocken::Jenny::MIR::MachineFunction->new( name => 'restores', frame_size => 0 );
    my $bb = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    my $r10 = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'r10' );
    my $r11 = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'r11' );
    my $r12 = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'r12' );
    my $sp10 = Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => 'sp', disp => 0 }, type => 0 );
    my $sp18 = Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => 'sp', disp => 8 }, type => 0 );

    # A caller-restore reload followed by a *self*-move.  The move keeps the value reg r10 already has after the call
    # -- which is the clobbered one -- so the reload is the only thing that restores r10, and removing it is a bug.
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'load', operands => [ $r10, $sp10 ], comment => 'caller-restore r10' ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov',  operands => [ $r10, $r10 ],  comment => 'a real copy' ) );

    # Control: a reload followed by a copy from a *different* register is redundant, because the copy overwrites the
    # destination with its own value.  Keep this optimization.
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'load', operands => [ $r11, $sp18 ], comment => 'caller-restore r11' ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov',  operands => [ $r11, $r12 ],  comment => 'a real copy' ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret',  operands => [] ) );
    $mf->add_block($bb);
    return $mf;
}

my $mf   = mk_mf();
my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new();
$alloc->remove_redundant_caller_restores($mf);

my @insts = grep { $_->opcode ne 'ret' } map { $_->instructions->@* } $mf->blocks->@*;
is scalar(@insts), 3, 'the self-move case keeps its caller-restore reload, the different-src case still drops its reload';
is $insts[0]->opcode, 'load', 'first survivor is the r10 caller-restore reload';
is $insts[0]->comment, 'caller-restore r10', 'the reload before a self-move survives';
is $insts[1]->opcode, 'mov', 'the self-move is left in place';

done_testing;