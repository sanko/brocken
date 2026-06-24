use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'MachineOperand' => sub {
    my $vreg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%x' );
    isa_ok $vreg, ['Brocken::Jenny::MIR::MachineOperand'], 'virtual register operand';
    is $vreg->kind,  'virt_reg', 'vreg kind';
    is $vreg->value, '%x',       'vreg value';
    my $phys = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rax' );
    is $phys->kind,  'phys_reg', 'physical register kind';
    is $phys->value, 'rax',      'physical register value';
    my $imm = Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 42 );
    is $imm->kind,  'imm', 'immediate kind';
    is $imm->value, 42,    'immediate value';
};
subtest 'MachineInstruction' => sub {
    my $dst  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%res' );
    my $src  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm',      value => 1 );
    my $inst = Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'add', operands => [ $dst, $src ], comment => 'x + 1', );
    isa_ok $inst, ['Brocken::Jenny::MIR::MachineInstruction'], 'instruction construction';
    is $inst->opcode,              'add',   'instruction opcode';
    is scalar $inst->operands->@*, 2,       'instruction operand count';
    is $inst->comment,             'x + 1', 'instruction comment';
};
subtest 'MachineBasicBlock' => sub {
    my $bb = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    isa_ok $bb, ['Brocken::Jenny::MIR::MachineBasicBlock'], 'basic block construction';
    is $bb->name,                    'entry', 'block name';
    is scalar $bb->instructions->@*, 0,       'block starts with no instructions';
    my $inst = Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] );
    $bb->add_instruction($inst);
    is scalar $bb->instructions->@*, 1, 'block has one instruction after add';
};
subtest 'MachineFunction' => sub {
    my $mf = Brocken::Jenny::MIR::MachineFunction->new( name => 'test', frame_size => 16 );
    isa_ok $mf, ['Brocken::Jenny::MIR::MachineFunction'], 'function construction';
    is $mf->name,              'test', 'function name';
    is $mf->frame_size,        16,     'function frame size';
    is scalar $mf->blocks->@*, 0,      'function starts with no blocks';
    my $bb = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf->add_block($bb);
    is scalar $mf->blocks->@*, 1, 'function has one block after add';
};
done_testing;
