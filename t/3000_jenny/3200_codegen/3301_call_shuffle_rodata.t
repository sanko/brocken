use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use Blib;
use Brocken;
use Brocken::Jenny::RegAlloc ();

# fix_call_shuffle re-emitted every step by writing its single register source into operand 1.  A lea_rodata item has
# no source, so a string call argument sitting in a shuffled run had its label operand replaced with an undef phys_reg.
subtest 'call shuffle keeps the lea_rodata label operand' => sub {
    my $mf = Brocken::Jenny::MIR::MachineFunction->new( name => 'test', frame_size => 0 );
    my $bb = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf->add_block($bb);

    # arg0 writes rdi reading %b (assigned rsi); arg1 writes rsi reading %a (assigned rdi): a swap.  arg2 is a string
    # constant materialized with lea_rodata, whose destination is rdx.
    $bb->add_instruction(
        Brocken::Jenny::MIR::MachineInstruction->new(
            opcode   => 'mov',
            operands => [
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rdi' ),
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%b' ),
            ],
            comment => 'arg 0 to rdi'
        )
    );
    $bb->add_instruction(
        Brocken::Jenny::MIR::MachineInstruction->new(
            opcode   => 'mov',
            operands => [
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rsi' ),
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%a' ),
            ],
            comment => 'arg 1 to rsi'
        )
    );
    $bb->add_instruction(
        Brocken::Jenny::MIR::MachineInstruction->new(
            opcode   => 'lea_rodata',
            operands => [
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rdx' ),
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'rodata_label', value => '__str_0' ),
            ],
            comment => 'arg 2 (string) to rdx'
        )
    );
    $bb->add_instruction(
        Brocken::Jenny::MIR::MachineInstruction->new(
            opcode   => 'call_func',
            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => '@foo' ) ],
            comment  => 'call @foo'
        )
    );

    my %assignment = ( '%a' => 'rdi', '%b' => 'rsi' );
    Brocken::Jenny::RegAlloc::LinearScan->new()->fix_call_shuffle( $mf, \%assignment, 'rax', 'xmm0' );

    my @insts = $bb->instructions->@*;
    my (@rodata) = grep { $_->opcode eq 'lea_rodata' } @insts;
    is( scalar @rodata, 1, 'one lea_rodata survives the shuffle' );
    is( $rodata[0]->operands->[1]->kind,  'rodata_label', 'label operand kind preserved' );
    is( $rodata[0]->operands->[1]->value, '__str_0',      'label operand value preserved' );
    for my $i (@insts) {
        for my $op ( $i->operands->@* ) {
            ok( !( ref($op) && $op->kind eq 'phys_reg' && !defined $op->value ), 'no undef phys_reg operand emitted' );
        }
    }
};
done_testing;