use v5.42;
use feature qw[class];
no warnings qw[portable];
no warnings qw[experimental::class];
use Brocken::Jenny::MIR;
use List::Util qw[min max];

class Brocken::Jenny::Lowerer::Wasm {

    method lower($ir_func) {

        # alloca name => the Alloca instruction, for slots held in a wasm local
        my %promoted = %{ $self->_promotable_allocas($ir_func) };
        my $mf = Brocken::Jenny::MIR::MachineFunction->new( name => $ir_func->name );
        for my $block ( $ir_func->blocks->@* ) {
            my $mbb = Brocken::Jenny::MIR::MachineBasicBlock->new( name => $block->name );
            if ( $ir_func->blocks->[0] != $block ) {
                $mbb->add_instruction(
                    Brocken::Jenny::MIR::MachineInstruction->new(
                        opcode   => 'label',
                        operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $block->name ) ],
                        comment  => 'block: ' . $block->name
                    )
                );
            }
            for my $inst ( $block->instructions->@* ) {
                my $opcode = $inst->opcode;
                if ( $opcode eq 'add' ||
                    $opcode eq 'sub'  ||
                    $opcode eq 'mul'  ||
                    $opcode eq 'div'  ||
                    $opcode eq 'rem'  ||
                    $opcode eq 'udiv' ||
                    $opcode eq 'urem' ||
                    $opcode eq 'and'  ||
                    $opcode eq 'or'   ||
                    $opcode eq 'xor'  ||
                    $opcode eq 'shl'  ||
                    $opcode eq 'lshr' ||
                    $opcode eq 'ashr' ||
                    $opcode eq 'min'  ||
                    $opcode eq 'max' ) {
                    my ( $lhs, $rhs ) = $inst->operands->@*;
                    if (
                        $inst->type                &&
                        $inst->type->kind eq 'int' &&
                        $inst->type->bits == 128   &&
                        ( $opcode eq 'add' ||
                            $opcode eq 'sub'  ||
                            $opcode eq 'and'  ||
                            $opcode eq 'or'   ||
                            $opcode eq 'xor'  ||
                            $opcode eq 'shl'  ||
                            $opcode eq 'lshr' ||
                            $opcode eq 'ashr' ||
                            $opcode eq 'mul'  ||
                            $opcode eq 'div'  ||
                            $opcode eq 'rem'  ||
                            $opcode eq 'udiv' ||
                            $opcode eq 'urem' ||
                            $opcode eq 'min'  ||
                            $opcode eq 'max' )
                    ) {
                        if ( $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' ) {
                            my ( $lo_lhs, $hi_lhs ) = $self->_split_i128($lhs);
                            my ( $lo_dst, $hi_dst ) = $self->_split_i128($inst);
                            my $lo_tmp = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_t',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            if ( $rhs->isa('Brocken::Lindsay::IR::Constant') ) {
                                my $amt = $rhs->value;
                                if ( $amt == 0 ) {
                                    $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'local_set',
                                            operands => [$lo_dst],
                                            comment  => 'store lo'
                                        )
                                    );
                                    $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'local_set',
                                            operands => [$hi_dst],
                                            comment  => 'store hi'
                                        )
                                    );
                                }
                                elsif ( $opcode eq 'shl' ) {
                                    if ( $amt < 64 ) {
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $amt ) ],
                                                comment  => 'amt ' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shl',
                                                operands => [],
                                                comment  => 'lo<<' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_dst],
                                                comment  => 'store lo'
                                            )
                                        );
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 64 - $amt ) ],
                                                comment  => 'amt ' . ( 64 - $amt )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shr_u',
                                                operands => [],
                                                comment  => 'carry>>' . ( 64 - $amt )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_tmp],
                                                comment  => 'save carry'
                                            )
                                        );
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $amt ) ],
                                                comment  => 'amt ' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shl',
                                                operands => [],
                                                comment  => 'hi<<' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_get',
                                                operands => [$lo_tmp],
                                                comment  => 'push carry'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_or',
                                                operands => [],
                                                comment  => 'hi|=carry'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$hi_dst],
                                                comment  => 'store hi'
                                            )
                                        );
                                    }
                                    elsif ( $amt == 64 ) {
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$hi_dst],
                                                comment  => 'store hi=lo'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                                comment  => '0'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_dst],
                                                comment  => 'store lo=0'
                                            )
                                        );
                                    }
                                    elsif ( $amt < 128 ) {
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $amt - 64 ) ],
                                                comment  => 'amt ' . ( $amt - 64 )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shl',
                                                operands => [],
                                                comment  => 'hi<<' . ( $amt - 64 )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$hi_dst],
                                                comment  => 'store hi'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                                comment  => '0'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_dst],
                                                comment  => 'store lo=0'
                                            )
                                        );
                                    }
                                    else {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                                comment  => '0'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_dst],
                                                comment  => 'store lo=0'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                                comment  => '0'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$hi_dst],
                                                comment  => 'store hi=0'
                                            )
                                        );
                                    }
                                }
                                elsif ( $opcode eq 'lshr' ) {
                                    if ( $amt < 64 ) {
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $amt ) ],
                                                comment  => 'amt ' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shr_u',
                                                operands => [],
                                                comment  => 'hi>>' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$hi_dst],
                                                comment  => 'store hi'
                                            )
                                        );
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 64 - $amt ) ],
                                                comment  => 'amt ' . ( 64 - $amt )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shl',
                                                operands => [],
                                                comment  => 'carry<<' . ( 64 - $amt )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_tmp],
                                                comment  => 'save carry'
                                            )
                                        );
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $amt ) ],
                                                comment  => 'amt ' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shr_u',
                                                operands => [],
                                                comment  => 'lo>>' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_get',
                                                operands => [$lo_tmp],
                                                comment  => 'push carry'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_or',
                                                operands => [],
                                                comment  => 'lo|=carry'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_dst],
                                                comment  => 'store lo'
                                            )
                                        );
                                    }
                                    elsif ( $amt == 64 ) {
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_dst],
                                                comment  => 'store lo=hi'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                                comment  => '0'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$hi_dst],
                                                comment  => 'store hi=0'
                                            )
                                        );
                                    }
                                    elsif ( $amt < 128 ) {
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $amt - 64 ) ],
                                                comment  => 'amt ' . ( $amt - 64 )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shr_u',
                                                operands => [],
                                                comment  => 'lo>>' . ( $amt - 64 )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_dst],
                                                comment  => 'store lo'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                                comment  => '0'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$hi_dst],
                                                comment  => 'store hi=0'
                                            )
                                        );
                                    }
                                    else {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                                comment  => '0'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_dst],
                                                comment  => 'store lo=0'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                                comment  => '0'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$hi_dst],
                                                comment  => 'store hi=0'
                                            )
                                        );
                                    }
                                }
                                else {
                                    if ( $amt < 64 ) {
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $amt ) ],
                                                comment  => 'amt ' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shr_s',
                                                operands => [],
                                                comment  => 'hi>>' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$hi_dst],
                                                comment  => 'store hi'
                                            )
                                        );
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 64 - $amt ) ],
                                                comment  => 'amt ' . ( 64 - $amt )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shl',
                                                operands => [],
                                                comment  => 'carry<<' . ( 64 - $amt )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_tmp],
                                                comment  => 'save carry'
                                            )
                                        );
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $amt ) ],
                                                comment  => 'amt ' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shr_u',
                                                operands => [],
                                                comment  => 'lo>>' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_get',
                                                operands => [$lo_tmp],
                                                comment  => 'push carry'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_or',
                                                operands => [],
                                                comment  => 'lo|=carry'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_dst],
                                                comment  => 'store lo'
                                            )
                                        );
                                    }
                                    elsif ( $amt == 64 ) {
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_dst],
                                                comment  => 'store lo=hi'
                                            )
                                        );
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 63 ) ],
                                                comment  => '63'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shr_s',
                                                operands => [],
                                                comment  => 'sign extend'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$hi_dst],
                                                comment  => 'store hi sign'
                                            )
                                        );
                                    }
                                    elsif ( $amt < 128 ) {
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $amt - 64 ) ],
                                                comment  => 'amt ' . ( $amt - 64 )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shr_s',
                                                operands => [],
                                                comment  => 'lo>>' . ( $amt - 64 )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_dst],
                                                comment  => 'store lo'
                                            )
                                        );
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 63 ) ],
                                                comment  => '63'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_shr_s',
                                                operands => [],
                                                comment  => 'sign extend'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$hi_dst],
                                                comment  => 'store hi sign'
                                            )
                                        );
                                    }
                                    else {
                                        $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'i64_const',
                                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 63 ) ],
                                                comment  => '63'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_shr_s', operands => [], comment => 'sign' )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_tmp],
                                                comment  => 'save sign'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_get',
                                                operands => [$lo_tmp],
                                                comment  => 'push sign'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$lo_dst],
                                                comment  => 'store lo'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_get',
                                                operands => [$lo_tmp],
                                                comment  => 'push sign'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'local_set',
                                                operands => [$hi_dst],
                                                comment  => 'store hi'
                                            )
                                        );
                                    }
                                }
                            }
                            else {
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'local_set',
                                        operands => [$lo_dst],
                                        comment  => 'store lo'
                                    )
                                );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'local_set',
                                        operands => [$hi_dst],
                                        comment  => 'store hi'
                                    )
                                );
                            }
                        }
                        elsif ( $opcode eq 'mul' ) {
                            my ( $lo_lhs, $hi_lhs ) = $self->_split_i128($lhs);
                            my ( $lo_rhs, $hi_rhs ) = $self->_split_i128($rhs);
                            my ( $lo_dst, $hi_dst ) = $self->_split_i128($inst);
                            my $al = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_al',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $ah = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_ah',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $bl = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_bl',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $bh = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_bh',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $p0 = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_p0',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $p1 = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_p1',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $p2 = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_p2',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $p3 = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_p3',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $carry = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_carry',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );

                            # umulh(a_lo, b_lo) via 32-bit schoolbook decomposition
                            # al = a_lo & 0xFFFFFFFF
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0xFFFFFFFF ) ],
                                    comment  => 'mask'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_and', operands => [], comment => 'al' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$al], comment => 'save al' ) );

                            # ah = a_lo >> 32
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 32 ) ],
                                    comment  => '32'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_shr_u', operands => [], comment => 'ah' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$ah], comment => 'save ah' ) );

                            # bl = b_lo & 0xFFFFFFFF
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_rhs, 'lo_rhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0xFFFFFFFF ) ],
                                    comment  => 'mask'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_and', operands => [], comment => 'bl' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$bl], comment => 'save bl' ) );

                            # bh = b_lo >> 32
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_rhs, 'lo_rhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 32 ) ],
                                    comment  => '32'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_shr_u', operands => [], comment => 'bh' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$bh], comment => 'save bh' ) );

                            # p0 = al * bl
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$al], comment => 'al' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$bl], comment => 'bl' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_mul', operands => [], comment => 'p0' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$p0], comment => 'save p0' ) );

                            # p1 = al * bh
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$al], comment => 'al' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$bh], comment => 'bh' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_mul', operands => [], comment => 'p1' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$p1], comment => 'save p1' ) );

                            # p2 = ah * bl
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$ah], comment => 'ah' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$bl], comment => 'bl' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_mul', operands => [], comment => 'p2' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$p2], comment => 'save p2' ) );

                            # p3 = ah * bh
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$ah], comment => 'ah' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$bh], comment => 'bh' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_mul', operands => [], comment => 'p3' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$p3], comment => 'save p3' ) );

                            # carry = (p0>>32) + (p1&0xFFFFFFFF) + (p2&0xFFFFFFFF)
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$p0], comment => 'p0' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 32 ) ],
                                    comment  => '32'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_shr_u', operands => [], comment => '>>32' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$p1], comment => 'p1' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0xFFFFFFFF ) ],
                                    comment  => 'mask'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_and', operands => [], comment => '&mask' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_add', operands => [], comment => '+' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$p2], comment => 'p2' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0xFFFFFFFF ) ],
                                    comment  => 'mask'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_and', operands => [], comment => '&mask' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_add', operands => [], comment => 'carry0' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$carry], comment => 'save carry0' )
                            );

                            # carry = carry0 >> 32  (carry1)
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$carry], comment => 'carry0' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 32 ) ],
                                    comment  => '32'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_shr_u', operands => [], comment => 'carry1' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$carry], comment => 'save carry1' )
                            );

                            # hi_dst = (p1>>32) + (p2>>32) + p3 + carry1  (= umulh(a_lo,b_lo))
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$p1], comment => 'p1' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 32 ) ],
                                    comment  => '32'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_shr_u', operands => [], comment => '>>32' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$p2], comment => 'p2' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 32 ) ],
                                    comment  => '32'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_shr_u', operands => [], comment => '>>32' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_add', operands => [], comment => '+' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$p3], comment => 'p3' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_add', operands => [], comment => '+p3' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$carry], comment => 'carry1' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_add', operands => [], comment => 'umulh(a_lo,b_lo)' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_set',
                                    operands => [$hi_dst],
                                    comment  => 'save hi (umulh)'
                                )
                            );

                            # lo_dst = a_lo * b_lo (low 64 bits)
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_rhs, 'lo_rhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_mul', operands => [], comment => 'lo = a_lo*b_lo' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$lo_dst], comment => 'save lo' ) );

                            # hi_dst += a_lo * b_hi
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi_rhs, 'hi_rhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_mul', operands => [], comment => 'a_lo*b_hi' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$hi_dst], comment => 'hi' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_add', operands => [], comment => 'hi += a_lo*b_hi' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$hi_dst], comment => 'save hi' ) );

                            # hi_dst += a_hi * b_lo
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_rhs, 'lo_rhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_mul', operands => [], comment => 'a_hi*b_lo' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$hi_dst], comment => 'hi' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_add', operands => [], comment => 'hi += a_hi*b_lo' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$hi_dst], comment => 'save hi' ) );
                        }
                        elsif ( $opcode eq 'div' || $opcode eq 'rem' || $opcode eq 'udiv' || $opcode eq 'urem' ) {
                            my ( $lo_lhs, $hi_lhs ) = $self->_split_i128($lhs);
                            my ( $lo_rhs, $hi_rhs ) = $self->_split_i128($rhs);
                            my ( $lo_dst, $hi_dst ) = $self->_split_i128($inst);
                            my $q_lo = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_q_lo',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $q_hi = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_q_hi',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $r_lo = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_r_lo',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $r_hi = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_r_hi',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );

                            # Q = 0, R = 0
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ]
                                )
                            );
                            $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$q_lo] ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ]
                                )
                            );
                            $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$q_hi] ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ]
                                )
                            );
                            $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$r_lo] ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ]
                                )
                            );
                            $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$r_hi] ) );
                            my $orig_lo_lhs = $lo_lhs;
                            my $orig_hi_lhs = $hi_lhs;
                            my $orig_lo_rhs = $lo_rhs;
                            my $orig_hi_rhs = $hi_rhs;

                            # ---- signed i128 div/rem: materialize imm operands to virt_reg ----
                            if ( $lo_lhs->kind eq 'imm' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_mlo',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$r] ) );
                                $lo_lhs = $r;
                            }
                            if ( $hi_lhs->kind eq 'imm' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_mhi',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$r] ) );
                                $hi_lhs = $r;
                            }
                            if ( $lo_rhs->kind eq 'imm' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_rmlo',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_rhs, 'lo_rhs' ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$r] ) );
                                $lo_rhs = $r;
                            }
                            if ( $hi_rhs->kind eq 'imm' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_rmhi',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $hi_rhs, 'hi_rhs' ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$r] ) );
                                $hi_rhs = $r;
                            }

                            # ---- end materialization ----
                            # ---- signed i128 div/rem: abs inputs via xor+sub with sign mask ----
                            my $do_mask128 = sub ( $lo, $hi, $mask ) {
                                my $tmp = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_dmtmp',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $bor = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_dmbor',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo, 'lo' ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$mask] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_xor',   operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$tmp] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$tmp] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$mask] ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_lt_u', operands => [], comment => 'mask128 borrow' )
                                );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_extend_i32_u', operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$bor] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$tmp] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$mask] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_sub',   operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$lo] ) );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $hi, 'hi' ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$mask] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_xor',   operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$mask] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_sub',   operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$bor] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_sub',   operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$hi] ) );
                            };
                            my $sign_d = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_sgnd',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 63 ) ]
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_shr_s', operands => [], comment => 'i128 sign d' ) );
                            $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$sign_d] ) );
                            $do_mask128->( $lo_lhs, $hi_lhs, $sign_d );
                            my $sign_v = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_signv',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi_rhs, 'hi_rhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 63 ) ]
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_shr_s', operands => [], comment => 'i128 sign v' ) );
                            $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$sign_v] ) );
                            $do_mask128->( $lo_rhs, $hi_rhs, $sign_v );

                            # ---- end input abs ----
                            for my $ii ( reverse 0 .. 127 ) {
                                my $val   = $ii >= 64 ? $hi_lhs  : $lo_lhs;
                                my $shift = $ii >= 64 ? $ii - 64 : $ii;

                                # bit = (val >> $shift) & 1
                                $mbb->add_instruction( $self->_wasm_push_opnd( $val, "bit$ii" ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'i64_const',
                                        operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $shift ) ]
                                    )
                                );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_shr_u', operands => [] ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'i64_const',
                                        operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ]
                                    )
                                );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_and', operands => [] ) );
                                my $bit = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_b$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$bit] ) );

                                # carry = r_lo >> 63
                                $mbb->add_instruction( $self->_wasm_push_opnd( $r_lo, 'r_lo' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'i64_const',
                                        operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 63 ) ]
                                    )
                                );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_shr_u', operands => [] ) );
                                my $carry = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_c$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$carry] ) );

                                # r_lo = (r_lo << 1) | bit
                                $mbb->add_instruction( $self->_wasm_push_opnd( $r_lo, 'r_lo' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'i64_const',
                                        operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ]
                                    )
                                );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_shl',   operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$bit] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_or',    operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$r_lo] ) );

                                # r_hi = (r_hi << 1) | carry
                                $mbb->add_instruction( $self->_wasm_push_opnd( $r_hi, 'r_hi' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'i64_const',
                                        operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ]
                                    )
                                );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_shl',   operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$carry] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_or',    operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$r_hi] ) );

                                # Compare R >= D
                                # cond_hi_gt = r_hi > d_hi
                                $mbb->add_instruction( $self->_wasm_push_opnd( $r_hi,   'r_hi' ) );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $hi_rhs, 'd_hi' ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_gt_u', operands => [] ) );
                                my $cond_hi_gt = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_hgt$ii",
                                    type  => Brocken::Lindsay::IR::Type::i32()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$cond_hi_gt] ) );

                                # cond_hi_eq = r_hi == d_hi
                                $mbb->add_instruction( $self->_wasm_push_opnd( $r_hi,   'r_hi' ) );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $hi_rhs, 'd_hi' ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_eq', operands => [] ) );
                                my $cond_hi_eq = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_heq$ii",
                                    type  => Brocken::Lindsay::IR::Type::i32()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$cond_hi_eq] ) );

                                # cond_lo_ge = !(r_lo < d_lo)
                                $mbb->add_instruction( $self->_wasm_push_opnd( $r_lo,   'r_lo' ) );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_rhs, 'd_lo' ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_lt_u', operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_eqz',  operands => [] ) );
                                my $cond_lo_ge = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_lge$ii",
                                    type  => Brocken::Lindsay::IR::Type::i32()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$cond_lo_ge] ) );

                                # cond = cond_hi_gt | (cond_hi_eq & cond_lo_ge)
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$cond_hi_eq] ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$cond_lo_ge] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_and', operands => [] ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$cond_hi_gt] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_or',           operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_extend_i32_u', operands => [] ) );
                                my $cond = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_cond$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$cond] ) );

                                # neg_cond = -cond = 0 - cond
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'i64_const',
                                        operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ]
                                    )
                                );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$cond] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_sub',   operands => [] ) );
                                my $neg_cond = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_neg$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$neg_cond] ) );

                                # masked_d_lo = d_lo & neg_cond
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_rhs, 'd_lo' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$neg_cond] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_and', operands => [] ) );
                                my $masked_d_lo = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_mdl$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$masked_d_lo] ) );

                                # borrow = r_lo < masked_d_lo
                                $mbb->add_instruction( $self->_wasm_push_opnd( $r_lo, 'r_lo' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$masked_d_lo] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_lt_u', operands => [] ) );
                                my $borrow = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_bor$ii",
                                    type  => Brocken::Lindsay::IR::Type::i32()
                                );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$borrow] ) );

                                # r_lo -= masked_d_lo
                                $mbb->add_instruction( $self->_wasm_push_opnd( $r_lo, 'r_lo' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$masked_d_lo] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_sub',   operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$r_lo] ) );

                                # masked_d_hi = d_hi & neg_cond
                                $mbb->add_instruction( $self->_wasm_push_opnd( $hi_rhs, 'd_hi' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$neg_cond] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_and', operands => [] ) );
                                my $masked_d_hi = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_mdh$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$masked_d_hi] ) );

                                # r_hi -= masked_d_hi + borrow
                                $mbb->add_instruction( $self->_wasm_push_opnd( $r_hi, 'r_hi' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$masked_d_hi] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$borrow] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_extend_i32_u', operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_add',          operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_sub',          operands => [] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$r_hi] ) );

                                # Q_bit = (1 << ($ii % 64)) & neg_cond
                                my $qbit_val = 1 << ( $ii % 64 );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'i64_const',
                                        operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $qbit_val ) ]
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$neg_cond] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_and', operands => [] ) );
                                my $qbit = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_qb$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$qbit] ) );
                                if ( $ii >= 64 ) {
                                    $mbb->add_instruction( $self->_wasm_push_opnd( $q_hi, 'q_hi' ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$qbit] ) );
                                    $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_or', operands => [] ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$q_hi] ) );
                                }
                                else {
                                    $mbb->add_instruction( $self->_wasm_push_opnd( $q_lo, 'q_lo' ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$qbit] ) );
                                    $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_or', operands => [] ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$q_lo] ) );
                                }
                            }

                            # ---- signed i128 div/rem: apply sign to quotient and remainder ----
                            # sign_d and sign_v are already 0/-1 masks from i64_shr_s
                            my $sign_q = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_sgnq',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$sign_d] ) );
                            $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$sign_v] ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_xor', operands => [], comment => 'i128 q sign = d ^ v' )
                            );
                            $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$sign_q] ) );
                            $do_mask128->( $q_lo, $q_hi, $sign_q );
                            $do_mask128->( $r_lo, $r_hi, $sign_d );

                            # ---- end signed handling ----
                            my $out_lo = $opcode eq 'div' ? $q_lo : $r_lo;
                            my $out_hi = $opcode eq 'div' ? $q_hi : $r_hi;
                            $mbb->add_instruction( $self->_wasm_push_opnd( $out_lo, 'out_lo' ) );
                            $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$lo_dst] ) );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $out_hi, 'out_hi' ) );
                            $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$hi_dst] ) );
                        }
                        elsif ( $opcode eq 'min' || $opcode eq 'max' ) {
                            my ( $lo_lhs, $hi_lhs ) = $self->_split_i128($lhs);
                            my ( $lo_rhs, $hi_rhs ) = $self->_split_i128($rhs);
                            my ( $lo_dst, $hi_dst ) = $self->_split_i128($inst);
                            my $mask_tmp = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_mask',
                                type  => Brocken::Lindsay::IR::Type::i32()
                            );
                            my $tmp_lhs_lo = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_llo',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $tmp_lhs_hi = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_lhi',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $tmp_rhs_lo = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_rlo',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $tmp_rhs_hi = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_rhi',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );

                            # Save operands to locals
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'i128 minmax lo_lhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_set',
                                    operands => [$tmp_lhs_lo],
                                    comment  => 'i128 minmax save lo_lhs'
                                )
                            );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'i128 minmax hi_lhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_set',
                                    operands => [$tmp_lhs_hi],
                                    comment  => 'i128 minmax save hi_lhs'
                                )
                            );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_rhs, 'i128 minmax lo_rhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_set',
                                    operands => [$tmp_rhs_lo],
                                    comment  => 'i128 minmax save lo_rhs'
                                )
                            );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi_rhs, 'i128 minmax hi_rhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_set',
                                    operands => [$tmp_rhs_hi],
                                    comment  => 'i128 minmax save hi_rhs'
                                )
                            );

                            # Compute mask: hi_lt | (hi_eq & lo_lt)
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$tmp_lhs_hi],
                                    comment  => 'i128 minmax lhs_hi'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$tmp_rhs_hi],
                                    comment  => 'i128 minmax rhs_hi'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_lt_s', operands => [], comment => 'i128 minmax hi_lt' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$tmp_lhs_hi],
                                    comment  => 'i128 minmax lhs_hi'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$tmp_rhs_hi],
                                    comment  => 'i128 minmax rhs_hi'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_eq', operands => [], comment => 'i128 minmax hi_eq' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$tmp_lhs_lo],
                                    comment  => 'i128 minmax lhs_lo'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$tmp_rhs_lo],
                                    comment  => 'i128 minmax rhs_lo'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_lt_u', operands => [], comment => 'i128 minmax lo_lt' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i32_and',
                                    operands => [],
                                    comment  => 'i128 minmax hi_eq&lo_lt'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_or', operands => [], comment => 'i128 minmax mask' ) );

                            if ( $opcode eq 'max' ) {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'i32_eqz',
                                        operands => [],
                                        comment  => 'i128 max invert mask'
                                    )
                                );
                            }

                            # Extend mask to i64 for AND with i64 values
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_extend_i32_u',
                                    operands => [],
                                    comment  => 'i128 minmax mask extend'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_set',
                                    operands => [$mask_tmp],
                                    comment  => 'i128 minmax save mask64'
                                )
                            );

                            # lo_dst = ((lo_lhs XOR lo_rhs) AND mask) XOR lo_rhs
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$tmp_lhs_lo],
                                    comment  => 'i128 minmax lhs_lo'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$tmp_rhs_lo],
                                    comment  => 'i128 minmax rhs_lo'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_xor', operands => [], comment => 'i128 minmax lo xor' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$mask_tmp],
                                    comment  => 'i128 minmax mask'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_and', operands => [], comment => 'i128 minmax lo and' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$tmp_rhs_lo],
                                    comment  => 'i128 minmax rhs_lo'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_xor', operands => [], comment => 'i128 minmax lo sel' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_set',
                                    operands => [$lo_dst],
                                    comment  => 'i128 minmax store lo'
                                )
                            );

                            # hi_dst = ((hi_lhs XOR hi_rhs) AND mask) XOR hi_rhs
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$tmp_lhs_hi],
                                    comment  => 'i128 minmax lhs_hi'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$tmp_rhs_hi],
                                    comment  => 'i128 minmax rhs_hi'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_xor', operands => [], comment => 'i128 minmax hi xor' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$mask_tmp],
                                    comment  => 'i128 minmax mask'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_and', operands => [], comment => 'i128 minmax hi and' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$tmp_rhs_hi],
                                    comment  => 'i128 minmax rhs_hi'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_xor', operands => [], comment => 'i128 minmax hi sel' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_set',
                                    operands => [$hi_dst],
                                    comment  => 'i128 minmax store hi'
                                )
                            );
                        }
                        else {
                            my ( $lo_lhs, $hi_lhs ) = $self->_split_i128($lhs);
                            my ( $lo_rhs, $hi_rhs ) = $self->_split_i128($rhs);
                            my ( $lo_dst, $hi_dst ) = $self->_split_i128($inst);
                            if ( $opcode eq 'add' ) {
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_rhs, 'lo_rhs' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_add', operands => [], comment => 'lo add' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'local_set',
                                        operands => [$lo_dst],
                                        comment  => 'store lo'
                                    )
                                );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'local_get',
                                        operands => [$lo_dst],
                                        comment  => 'push lo_dst'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_gt_u', operands => [], comment => 'carry' ) );
                                my $carry = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_carry',
                                    type  => Brocken::Lindsay::IR::Type::i32()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'local_set',
                                        operands => [$carry],
                                        comment  => 'save carry'
                                    )
                                );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $hi_rhs, 'hi_rhs' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_add', operands => [], comment => 'hi add' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'local_get',
                                        operands => [$carry],
                                        comment  => 'push carry'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'i64_extend_i32_u',
                                        operands => [],
                                        comment  => 'carry i32->i64'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_add', operands => [], comment => 'hi add carry' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'local_set',
                                        operands => [$hi_dst],
                                        comment  => 'store hi'
                                    )
                                );
                            }
                            elsif ( $opcode eq 'sub' ) {
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_rhs, 'lo_rhs' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_sub', operands => [], comment => 'lo sub' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'local_set',
                                        operands => [$lo_dst],
                                        comment  => 'store lo'
                                    )
                                );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_rhs, 'lo_rhs' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_lt_u', operands => [], comment => 'borrow' ) );
                                my $borrow = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_carry',
                                    type  => Brocken::Lindsay::IR::Type::i32()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'local_set',
                                        operands => [$borrow],
                                        comment  => 'save borrow'
                                    )
                                );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $hi_rhs, 'hi_rhs' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_sub', operands => [], comment => 'hi sub' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'local_get',
                                        operands => [$borrow],
                                        comment  => 'push borrow'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'i64_extend_i32_u',
                                        operands => [],
                                        comment  => 'borrow i32->i64'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_sub', operands => [], comment => 'hi sub borrow' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'local_set',
                                        operands => [$hi_dst],
                                        comment  => 'store hi'
                                    )
                                );
                            }
                            else {
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'lo_lhs' ) );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $lo_rhs, 'lo_rhs' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => "i64_$opcode", operands => [], comment => "lo $opcode" )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'local_set',
                                        operands => [$lo_dst],
                                        comment  => 'store lo'
                                    )
                                );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'hi_lhs' ) );
                                $mbb->add_instruction( $self->_wasm_push_opnd( $hi_rhs, 'hi_rhs' ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => "i64_$opcode", operands => [], comment => "hi $opcode" )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'local_set',
                                        operands => [$hi_dst],
                                        comment  => 'store hi'
                                    )
                                );
                            }
                        }
                    }
                    else {
                        my $p;
                        my $ibits = $inst->type && $inst->type->kind eq 'int' ? $inst->type->bits : 32;
                        my $lbits = $lhs->type && $lhs->type->kind eq 'int' ? $lhs->type->bits : 32;
                        my $rbits = $rhs->type && $rhs->type->kind eq 'int' ? $rhs->type->bits : 32;
                        if ( $inst->type && $inst->type->kind eq 'float' ) {
                            $p = $inst->type->bits >= 64 ? 'f64' : 'f32';
                        }
                        else {

                            # Pick the width from the *wider operand*, not just
                            # the result type. Pointer arithmetic in the runtime
                            # is `ptr + i64` (a base address plus a byte count),
                            # and the result is a pointer, so the result type
                            # alone would pick i32 and either mismatch the i64
                            # operand or silently truncate the byte count.
                            my $w     = $ibits > $lbits ? $ibits : $lbits;
                            $w        = $rbits > $w     ? $rbits : $w;
                            $p        = $w >= 64 ? 'i64' : 'i32';
                        }

                        # Push LHS onto Wasm stack. Both operands are forced to
                        # the width the op below was chosen for, so a literal
                        # typed differently from the instruction still matches.
                        my $push_bits = $p eq 'i64' ? 64 : $p eq 'i32' ? 32 : undef;
                        $mbb->add_instruction( $self->_wasm_push( $lhs, 'LHS', $push_bits ) );

                        # A Wasm op consumes two operands of exactly its own
                        # width. When the wider operand forced the op up to i64
                        # (runtime pointer arithmetic is `ptr + i64`), a 32-bit
                        # operand has to be widened on the stack first, otherwise
                        # the validator rejects the i32 local feeding an i64_add.
                        # This has to run before the RHS push: the operand sits on
                        # top of the stack, and the next push would bury it.
                        if ( $p eq 'i64' && $lbits < 64 ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_extend_i32_u',
                                    operands => [],
                                    comment  => 'widen LHS to i64'
                                )
                            );
                        }

                        # Push RHS onto Wasm stack
                        $mbb->add_instruction( $self->_wasm_push( $rhs, 'RHS', $push_bits ) );

                        if ( $p eq 'i64' && $rbits < 64 ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i64_extend_i32_u',
                                    operands => [],
                                    comment  => 'widen RHS to i64'
                                )
                            );
                        }

                        # Arithmetic/bitwise op (consumes 2, produces 1 on stack)
                        my %map = (
                            add  => "${p}_add",
                            sub  => "${p}_sub",
                            mul  => "${p}_mul",
                            div  => "${p}_div_s",
                            rem  => "${p}_rem_s",
                            udiv => "${p}_div_u",
                            urem => "${p}_rem_u",
                            and  => "${p}_and",
                            or   => "${p}_or",
                            xor  => "${p}_xor",
                            shl  => "${p}_shl",
                            lshr => "${p}_shr_u",
                            ashr => "${p}_shr_s",
                        );

                        # Wasm has integer min/max opcodes for floats only
                        # (f32.min/f64.min), so an integer min/max has to
                        # become a select. `select` pops cond, val2, val1 and
                        # yields val1 when cond is non-zero, so pushing
                        # (lhs, rhs, lhs <op> rhs) picks the lhs on the
                        # interesting side of the comparison and the rhs
                        # otherwise. Both operands are already on the stack.
                        my $is_minmax = $opcode eq 'min' || $opcode eq 'max';
                        if ( $is_minmax && $p ne 'f32' && $p ne 'f64' ) {

                            # The comparison consumes both operands, but select
                            # needs three values: val1, val2, cond. So push the
                            # pair a second time and compare that copy, leaving
                            # the originals underneath for select to choose from.
                            $mbb->add_instruction( $self->_wasm_push( $lhs, 'LHS', $push_bits ) );
                            $mbb->add_instruction( $self->_wasm_push( $rhs, 'RHS', $push_bits ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => "${p}_" . ( $opcode eq 'min' ? 'lt_s' : 'gt_s' ),
                                    operands => [],
                                    comment  => "$opcode cmp"
                                )
                            );

                            # Untyped select; the operands on the stack give
                            # the validator everything it needs.
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode => 'select', operands => [], comment => $opcode ) );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $is_minmax ? "${p}_$opcode" : $map{$opcode},
                                    operands => [],
                                    comment  => $opcode ) );
                        }

                        # A pointer result computed in i64 has to be wrapped back
                        # to i32: the destination local is declared from the
                        # instruction's ptr type, and a wasm32 address is 32 bits.
                        if ( $p eq 'i64' && $ibits < 64 ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i32_wrap_i64',
                                    operands => [],
                                    comment  => 'wrap to ptr'
                                )
                            );
                        }

                        # Store result from stack to a local
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'local_set',
                                operands => [$dst],
                                comment  => 'store ' . $inst->name
                            )
                        );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Zext') ) {
                    my ($val)    = $inst->operands->@*;
                    my $src_bits = $val->type ? $val->type->bits : 64;
                    my $dst_bits = $inst->type ? $inst->type->bits : 64;
                    my $dst      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction( $self->_wasm_push( $val, 'zext val', $src_bits ) );
                    if ( $src_bits < 32 && $dst_bits > $src_bits ) {

                        # A sub-word value already sits in a local holding all 32
                        # bits, so the high bits are garbage until they are
                        # masked off. Masking has to happen in the source width:
                        # pushing an i32 and then applying i64 ops is a type
                        # mismatch and the module fails to compile.
                        my $mask = ( 1 << $src_bits ) - 1;
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'i32_const',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $mask ) ],
                                comment  => 'mask'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_and', operands => [], comment => 'zext' ) );
                    }
                    if ( $src_bits <= 32 && $dst_bits > 32 ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'i64_extend_i32_u', operands => [], comment => 'widen' ) );
                    }
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'store ' . $inst->name )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::PtrCast') ) {
                    my ($val)    = $inst->operands->@*;
                    my $src_bits = $val->type && $val->type->kind eq 'int' ? $val->type->bits : 32;
                    my $dst_bits = $inst->type && $inst->type->kind eq 'int' ? $inst->type->bits : 32;
                    my $dst      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );

                    # A wasm32 address is 32 bits, so a pointer is i32 and an
                    # i64 holding one has to be truncated, while a pointer
                    # widened to i64 has to be zero-extended. _wasm_push only
                    # re-types constants; a vreg keeps the width of its own
                    # local, so the conversion has to be explicit.
                    $mbb->add_instruction( $self->_wasm_push( $val, 'ptrcast val' ) );
                    if ( $dst_bits > $src_bits ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'i64_extend_i32_u',
                                operands => [],
                                comment  => 'ptrcast to i64'
                            )
                        );
                    }
                    elsif ( $dst_bits < $src_bits ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'i32_wrap_i64',
                                operands => [],
                                comment  => 'ptrcast to i32'
                            )
                        );
                    }
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'local_set',
                            operands => [$dst],
                            comment  => 'ptrcast ' . $inst->name
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Sext') ) {
                    my ($val)    = $inst->operands->@*;
                    my $src_bits = $val->type ? $val->type->bits : 64;
                    my $dst_bits = $inst->type ? $inst->type->bits : 64;
                    my $dst      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction( $self->_wasm_push( $val, 'sext val', $src_bits ) );
                    if ( $src_bits < 32 && $dst_bits > $src_bits ) {

                        # Sign-extend to the full 32-bit lane first. The shift
                        # pair has to be i32 to match what was just pushed; doing
                        # it in i64 is a type mismatch and the module will not
                        # validate.
                        my $shift = 32 - $src_bits;
                        for my $pair ( [ 'i32_shl', 'sext shl' ], [ 'i32_shr_s', 'sext shr_s' ] ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i32_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $shift ) ],
                                    comment  => 'shift'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => $pair->[0], operands => [], comment => $pair->[1] ) );
                        }
                    }
                    if ( $src_bits <= 32 && $dst_bits > 32 ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'i64_extend_i32_s', operands => [], comment => 'widen' ) );
                    }
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'store ' . $inst->name )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Trunc') ) {
                    my ($val)    = $inst->operands->@*;
                    my $src_bits = $val->type  ? $val->type->bits  : 64;
                    my $dst_bits = $inst->type ? $inst->type->bits : 64;
                    my $dst      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction( $self->_wasm_push( $val, 'trunc val', $src_bits ) );
                    if ( $src_bits > 32 ) {

                        # Keep only the low 32 bits. Wasm has no sub-word values,
                        # so anything narrower than a lane is masked in place.
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_wrap_i64', operands => [], comment => 'trunc' ) );
                    }
                    if ( $dst_bits < 32 ) {
                        my $mask = ( 1 << $dst_bits ) - 1;
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'i32_const',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $mask ) ],
                                comment  => 'trunc mask'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_and', operands => [], comment => 'trunc' ) );
                    }
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'store ' . $inst->name )
                    );
                }
                elsif ( $opcode eq 'neg' || $opcode eq 'abs' || $opcode eq 'sqrt' ) {
                    my ($val) = $inst->operands->@*;
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    if ( $inst->type && $inst->type->kind eq 'float' ) {
                        my $p = $inst->type->bits >= 64 ? 'f64' : 'f32';
                        $mbb->add_instruction( $self->_wasm_push( $val, 'unop: val' ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => "${p}_${opcode}", operands => [], comment => $opcode ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'store ' . $inst->name )
                        );
                    }
                    elsif ( $inst->type && $inst->type->kind eq 'int' ) {
                        die "Unsupported unary op $opcode for i128" if $inst->type->bits > 64;
                        if ( $opcode eq 'sqrt' ) {
                            die "Unsupported unary op $opcode for non-float type";
                        }

                        # Wasm has no integer neg/abs opcode; neg(x) is 0 - x
                        # and abs(x) is x < 0 ? -x : x, both built from the
                        # generic i32/i64 ops. `select` pops cond, val2, val1
                        # and yields val1 when cond is non-zero, so pushing
                        # (-x, x, x < 0) picks -x for a negative operand.
                        my $p = $inst->type->bits >= 64 ? 'i64' : 'i32';
                        my $zero = sub {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => "${p}_const",
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => "$opcode zero" )
                            );
                        };
                        if ( $opcode eq 'neg' ) {
                            $zero->();
                            $mbb->add_instruction( $self->_wasm_push( $val, 'neg val', $inst->type->bits ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => "${p}_sub", operands => [], comment => 'neg' ) );
                        }
                        else {
                            $zero->();
                            $mbb->add_instruction( $self->_wasm_push( $val, 'abs -x', $inst->type->bits ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => "${p}_sub", operands => [], comment => 'abs -x' ) );
                            $mbb->add_instruction( $self->_wasm_push( $val, 'abs val1', $inst->type->bits ) );
                            $mbb->add_instruction( $self->_wasm_push( $val, 'abs val2', $inst->type->bits ) );
                            $zero->();
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => "${p}_lt_s", operands => [], comment => 'abs x < 0' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'select', operands => [], comment => 'abs' ) );
                        }
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'store ' . $inst->name )
                        );
                    }
                    else {
                        die "Wasm unary op $opcode requires a typed value";
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Br') ) {
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'jmp',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->dest_block->name ) ],
                            comment  => 'br ' . $inst->dest_block->name
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::CondBr') ) {
                    $mbb->add_instruction( $self->_wasm_push( $inst->operands->[0], 'cond' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'bne',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->true_block->name ) ],
                            comment  => 'cond_br: true'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'jmp',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->false_block->name ) ],
                            comment  => 'cond_br: false'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::MemoryGrow') ) {
                    my $pages = $inst->operands->[0];

                    # The page count is computed in i64 arithmetic, but
                    # `memory.grow` takes an i32, so narrow it the same way an
                    # array index is narrowed.
                    my $bits = $pages->type && $pages->type->kind eq 'int' ? $pages->type->bits : 32;
                    $mbb->add_instruction( $self->_wasm_push( $pages, 'grow: pages', 32 ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode => 'i32_wrap_i64', operands => [], comment => 'grow: wrap pages to i32'
                        )
                    ) if $bits > 32;
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'memory_grow', operands => [], comment => 'memory.grow' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'local_set',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                            comment  => 'grow: save to ' . $inst->name
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::MemorySize') ) {
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'memory_size', operands => [], comment => 'memory.size' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'local_set',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                            comment  => 'size: save to ' . $inst->name
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Alloca') ) {

                    # A promoted slot is a wasm local, defined by the store that
                    # fills it and read by the loads that use it.
                    next if $promoted{ $inst->name };

                    my $elem = $inst->allocated_type->bits / 8;

                    # The bump is a single immediate, so a count has to be a
                    # literal to scale the reservation. A computed count has
                    # no ->value and reserved 0 bytes.
                    my $size = $elem;
                    if ( defined $inst->count ) {
                        die "Wasm alloca with a non-constant element count is not supported"
                            unless $inst->count->isa('Brocken::Lindsay::IR::Constant');
                        $size = $elem * $inst->count->value;
                    }

                    # An escaping slot is a heap block, so it goes through the
                    # same runtime allocator objects use. Bumping a second,
                    # module-local cursor here instead was what let arrays and
                    # objects overlap: both started at the heap base and neither
                    # knew about the other. Sharing the allocator also buys the
                    # array the growth and the out-of-memory refusal it lacked.
                    # The base is the module global, because the heap base is an
                    # entry argument and the slot can be allocated in any
                    # function, not just the entry.
                    $mbb->add_instruction( $self->_wasm_push_vreg( '%__heap_base', 'alloca: base' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i64_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $size ) ],
                            comment  => "alloca: size $size"
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'call_func',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'Brocken::Runtime::bump_alloc' ) ],
                            comment  => 'alloca: bump_alloc'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'call_func',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'Brocken::Runtime::check_alloc' ) ],
                            comment  => 'alloca: check_alloc'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'local_set',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                            comment  => 'alloca: save to ' . $inst->name
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Load') ) {
                    my $ptr = $inst->operands->[0];
                    if ( $ptr && $ptr->name && ( my $slot = $promoted{ $ptr->name } ) ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'local_get',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $ptr->name,
                                        type  => $slot->allocated_type
                                    )
                                ],
                                comment => 'load: ' . $ptr->name
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'local_set',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                                comment  => 'load: save to ' . $inst->name
                            )
                        );
                        next;
                    }
                    if ( $inst->type && $inst->type->kind eq 'int' && $inst->type->bits == 128 ) {
                        my ( $lo_dst, $hi_dst ) = $self->_split_i128($inst);
                        $mbb->add_instruction( $self->_wasm_push( $ptr, 'load: ptr' ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_load', operands => [], comment => 'load lo' ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$lo_dst], comment => 'load lo' ) );
                        $mbb->add_instruction( $self->_wasm_push( $ptr, 'load: ptr' ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'i32_const',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 8 ) ],
                                comment  => 'offset 8'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_add', operands => [], comment => 'ptr+8' ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_load', operands => [], comment => 'load hi' ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$hi_dst], comment => 'load hi' ) );
                    }
                    else {
                        my $op;
                        if ( $inst->type && $inst->type->kind eq 'float' ) {
                            $op = $inst->type->bits >= 64 ? 'f64_load' : 'f32_load';
                        }
                        else {
                            my $bits = $inst->type && $inst->type->kind eq 'int' ? $inst->type->bits : 32;
                            $op = $bits >= 64 ? 'i64_load' : 'i32_load';
                        }
                        $mbb->add_instruction( $self->_wasm_push( $ptr, 'load: ptr' ) );
                        $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => $op, operands => [], comment => 'load' ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'local_set',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                                comment  => 'load: save to ' . $inst->name
                            )
                        );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Store') ) {
                    my ( $val, $ptr ) = $inst->operands->@*;
                    if ( $ptr && $ptr->name && ( my $slot = $promoted{ $ptr->name } ) ) {
                        my $bits = $slot->allocated_type->kind eq 'int' ? $slot->allocated_type->bits : undef;
                        $mbb->add_instruction( $self->_wasm_push( $val, 'store: val', $bits ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'local_set',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $ptr->name,
                                        type  => $slot->allocated_type
                                    )
                                ],
                                comment => 'store: save to ' . $ptr->name
                            )
                        );
                        next;
                    }
                    if ( $val->type && $val->type->kind eq 'int' && $val->type->bits == 128 ) {
                        my ( $lo_val, $hi_val ) = $self->_split_i128($val);

                        # Store lo at [ptr+0]
                        $mbb->add_instruction( $self->_wasm_push( $ptr, 'store: ptr' ) );
                        $mbb->add_instruction( $self->_wasm_push_opnd( $lo_val, 'store lo' ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_store', operands => [], comment => 'store lo' ) );

                        # Store hi at [ptr+8]
                        $mbb->add_instruction( $self->_wasm_push( $ptr, 'store: ptr' ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'i32_const',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 8 ) ],
                                comment  => 'offset 8'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_add', operands => [], comment => 'ptr+8' ) );
                        $mbb->add_instruction( $self->_wasm_push_opnd( $hi_val, 'store hi' ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_store', operands => [], comment => 'store hi' ) );
                    }
                    else {
                        my $op;
                        if ( $val->type && $val->type->kind eq 'float' ) {
                            $op = $val->type->bits >= 64 ? 'f64_store' : 'f32_store';
                        }
                        else {
                            my $bits = $val->type && $val->type->kind eq 'int' ? $val->type->bits : 32;
                            $op = $bits >= 64 ? 'i64_store' : 'i32_store';
                        }
                        $mbb->add_instruction( $self->_wasm_push( $ptr, 'store: ptr' ) );
                        $mbb->add_instruction( $self->_wasm_push( $val, 'store: val' ) );
                        $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => $op, operands => [], comment => 'store' ) );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr') ) {
                    my ( $ptr, @indices ) = $inst->operands->@*;
                    my $scale = $inst->base_type->bits / 8;
                    my $idx   = $indices[0];
                    $mbb->add_instruction( $self->_wasm_push( $ptr, 'gep: ptr' ) );
                    if ( $idx->isa('Brocken::Lindsay::IR::Constant') ) {
                        my $offset = $idx->value * $scale;
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'i32_const',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $offset ) ],
                                comment  => "gep: const offset $offset"
                            )
                        );
                    }
                    else {
                        $mbb->add_instruction( $self->_wasm_push( $idx, 'gep: idx' ) );

                        # An index is an i64 in the IR, but a wasm32 address is
                        # i32 and the scale/multiply/add below are all i32
                        # operations. Pushing the index unchanged emits an i64
                        # followed by `i32.mul`, which the validator rejects with
                        # "type mismatch: expected i32, found i64" -- so a
                        # variable index into an array produced an invalid module
                        # while a constant index, folded into a displacement above,
                        # worked. Narrow it the way the pointer arithmetic does.
                        my $idx_bits = $idx->type && $idx->type->kind eq 'int' ? $idx->type->bits : 32;
                        if ( $idx_bits > 32 ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i32_wrap_i64',
                                    operands => [],
                                    comment  => 'gep: wrap index to i32'
                                )
                            );
                        }
                        if ( $scale > 1 ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i32_const',
                                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $scale ) ],
                                    comment  => "gep: scale $scale"
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_mul', operands => [], comment => 'gep: mul' ) );
                        }
                    }
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_add', operands => [], comment => 'gep: add' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'local_set',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                            comment  => 'gep: save to ' . $inst->name
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Box') ) {
                    my $val = $inst->operands->[0];
                    my $tag = $self->_type_tag( $val->type );

                    # A box is a 16-byte heap cell, so it is allocated from the
                    # shared allocator like every other escaping block.
                    $mbb->add_instruction( $self->_wasm_push_vreg( '%__heap_base', 'box: base' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i64_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 16 ) ],
                            comment  => 'box: size 16'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'call_func',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'Brocken::Runtime::bump_alloc' ) ],
                            comment  => 'box: bump_alloc'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'call_func',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'Brocken::Runtime::check_alloc' ) ],
                            comment  => 'box: check_alloc'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'local_set',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                            comment  => 'box: save to ' . $inst->name
                        )
                    );

                    # store payload at [%dyn + 0]. The payload slot is eight
                    # bytes wide, so a 64-bit value has to be stored with the
                    # 64-bit form; a fixed i32 store left an i64 literal on the
                    # stack as i64 and the module failed to validate.
                    my $vbits        = ( $val->type && $val->type->kind eq 'int' ) ? $val->type->bits : 32;
                    my $payload_store = $vbits > 32 ? 'i64_store' : 'i32_store';
                    $mbb->add_instruction( $self->_wasm_push_vreg( $inst->name, 'box: push dyn' ) );
                    $mbb->add_instruction( $self->_wasm_push( $val, 'box: push val' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => $payload_store, operands => [], comment => 'box: store payload' ) );

                    # store tag at [%dyn + 8]
                    $mbb->add_instruction( $self->_wasm_push_vreg( $inst->name, 'box: push dyn' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i32_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 8 ) ],
                            comment  => 'box: offset 8'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_add', operands => [], comment => 'box: add offset' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i32_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $tag ) ],
                            comment  => 'box: tag'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_store', operands => [], comment => 'box: store tag' ) );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Unbox') ) {
                    my $dyn = $inst->operands->[0];

                    # Read the payload back at the width it was written at, which
                    # is the width of the unboxed value.
                    my $ibits       = ( $inst->type && $inst->type->kind eq 'int' ) ? $inst->type->bits : 32;
                    my $payload_load = $ibits > 32 ? 'i64_load' : 'i32_load';
                    $mbb->add_instruction( $self->_wasm_push( $dyn, 'unbox: push dyn' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => $payload_load, operands => [], comment => 'unbox: load payload' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'local_set',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                            comment  => 'unbox: save to ' . $inst->name
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Incref') || $inst->isa('Brocken::Lindsay::IR::Instruction::Decref') ) {
                    my $val       = $inst->operands->[0];
                    my $op_name   = $inst->opcode;
                    my $func_name = 'Brocken::Runtime::' . $op_name;
                    $mbb->add_instruction( $self->_wasm_push( $val, "$op_name arg 0" ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'call_func',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => $func_name ) ],
                            comment  => "call \@$func_name"
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ICmp') ) {
                    my ( $lhs, $rhs ) = $inst->operands->@*;
                    my $pred = $inst->predicate;
                    my $p;
                    my $float = $lhs->type && $lhs->type->kind eq 'float';
                    if ($float) {
                        $p = $lhs->type->bits >= 64 ? 'f64' : 'f32';
                    }
                    elsif ( $lhs->type && $lhs->type->kind eq 'int' && $lhs->type->bits == 128 ) {
                        my ( $lo_lhs, $hi_lhs ) = $self->_split_i128($lhs);
                        my ( $lo_rhs, $hi_rhs ) = $self->_split_i128($rhs);
                        my $t0 = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $inst->name . '_t0',
                            type  => Brocken::Lindsay::IR::Type::i32()
                        );
                        my $t1 = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $inst->name . '_t1',
                            type  => Brocken::Lindsay::IR::Type::i32()
                        );
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                        if ( $pred eq 'eq' || $pred eq 'ne' ) {
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_lhs, 'i128 icmp lo_lhs' ) );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_rhs, 'i128 icmp lo_rhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_xor', operands => [], comment => 'i128 icmp lo_xor' ) );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi_lhs, 'i128 icmp hi_lhs' ) );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi_rhs, 'i128 icmp hi_rhs' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_xor', operands => [], comment => 'i128 icmp hi_xor' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_or', operands => [], comment => 'i128 icmp or' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_eqz', operands => [], comment => 'i128 icmp eqz' ) );

                            if ( $pred eq 'ne' ) {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_eqz', operands => [], comment => 'i128 icmp ne' ) );
                            }
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_set',
                                    operands => [$dst],
                                    comment  => 'i128 icmp store'
                                )
                            );
                        }
                        else {
                            my $swap   = ( $pred eq 'ugt' || $pred eq 'sgt' || $pred eq 'ule' || $pred eq 'sle' );
                            my $signed = ( $pred eq 'slt' || $pred eq 'sgt' || $pred eq 'sle' || $pred eq 'sge' );
                            my $cmp    = $signed ? 'i64_lt_s' : 'i64_lt_u';
                            my ( $hi_a, $hi_b, $lo_a, $lo_b )
                                = $swap ? ( $hi_rhs, $hi_lhs, $lo_rhs, $lo_lhs ) : ( $hi_lhs, $hi_rhs, $lo_lhs, $lo_rhs );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi_a, 'i128 icmp hi_a' ) );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi_b, 'i128 icmp hi_b' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => $cmp, operands => [], comment => 'i128 icmp hi_' . $cmp ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_set',
                                    operands => [$t0],
                                    comment  => 'i128 icmp save hi_lt'
                                )
                            );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi_a, 'i128 icmp hi_a' ) );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi_b, 'i128 icmp hi_b' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_eq', operands => [], comment => 'i128 icmp hi_eq' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_set',
                                    operands => [$t1],
                                    comment  => 'i128 icmp save hi_eq'
                                )
                            );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_a, 'i128 icmp lo_a' ) );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo_b, 'i128 icmp lo_b' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_lt_u', operands => [], comment => 'i128 icmp lo_lt' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$t1],
                                    comment  => 'i128 icmp push hi_eq'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'i32_and',
                                    operands => [],
                                    comment  => 'i128 icmp hi_eq&lo_lt'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_get',
                                    operands => [$t0],
                                    comment  => 'i128 icmp push hi_lt'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_or', operands => [], comment => 'i128 icmp result' ) );

                            if ( $pred eq 'ule' || $pred eq 'uge' || $pred eq 'sle' || $pred eq 'sge' ) {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'i32_eqz',
                                        operands => [],
                                        comment  => 'i128 icmp invert'
                                    )
                                );
                            }
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_set',
                                    operands => [$dst],
                                    comment  => 'i128 icmp store'
                                )
                            );
                        }
                        next;
                    }
                    else {
                        my $bits = $lhs->type && $lhs->type->kind eq 'int' ? $lhs->type->bits : 32;
                        $p = $bits >= 64 ? 'i64' : 'i32';
                    }
                    my %map = $float ? ( eq => "${p}_eq", ne => "${p}_ne", lt => "${p}_lt", gt => "${p}_gt", le => "${p}_le", ge => "${p}_ge" ) : (
                        eq  => "${p}_eq",
                        ne  => "${p}_ne",
                        slt => "${p}_lt_s",
                        sgt => "${p}_gt_s",
                        sle => "${p}_le_s",
                        sge => "${p}_ge_s",
                        ult => "${p}_lt_u",
                        ugt => "${p}_gt_u",
                        ule => "${p}_le_u",
                        uge => "${p}_ge_u"
                    );
                    my $push_bits = $p eq 'i64' ? 64 : $p eq 'i32' ? 32 : undef;
                    $mbb->add_instruction( $self->_wasm_push( $lhs, 'icmp lhs', $push_bits ) );
                    $mbb->add_instruction( $self->_wasm_push( $rhs, 'icmp rhs', $push_bits ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => $map{$pred}, operands => [], comment => 'icmp ' . $pred ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'local_set',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                            comment  => 'icmp store'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Call') ) {
                    my $callee = $inst->callee;
                    for my $arg ( $inst->operands->@* ) {
                        my $is_i128 = $arg->type && $arg->type->kind eq 'int' && $arg->type->bits == 128;
                        if ($is_i128) {
                            my ( $lo, $hi ) = $self->_split_i128($arg);
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo, 'arg lo' ) );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi, 'arg hi' ) );
                        }
                        else {
                            $mbb->add_instruction( $self->_wasm_push( $arg, 'arg' ) );
                        }
                    }
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'call_func',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => $callee->name ) ],
                            comment  => "call @" . $callee->name
                        )
                    );
                    if ( defined $inst->name ) {
                        my $is_i128 = $inst->type && $inst->type->kind eq 'int' && $inst->type->bits == 128;
                        if ($is_i128) {
                            my ( $lo, $hi ) = $self->_split_i128($inst);
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$hi], comment => 'retval hi' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$lo], comment => 'retval lo' ) );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'local_set',
                                    operands =>
                                        [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type ) ],
                                    comment => 'retval to ' . $inst->name
                                )
                            );
                        }
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberCreate') ) {
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i32_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                            comment  => 'fiber_create stub'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'fiber_create result' ) );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberTransfer') ) {
                    my ( $fiber, $val ) = $inst->operands->@*;
                    $mbb->add_instruction( $self->_wasm_push( $val, 'transfer val' ) );
                    if ( defined $inst->name ) {
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'local_set',
                                operands => [$dst],
                                comment  => 'fiber_transfer result'
                            )
                        );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberYield') ) {
                    my ($val) = $inst->operands->@*;
                    $mbb->add_instruction( $self->_wasm_push( $val, 'yield val' ) );
                    if ( defined $inst->name ) {
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'local_set',
                                operands => [$dst],
                                comment  => 'fiber_yield result'
                            )
                        );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberId') ) {
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i32_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                            comment  => 'fiber_id stub'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'fiber_id result' ) );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberPin') ) {
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::IsolateCreate') ) {
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i64_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                            comment  => 'isolate_create stub (threading TBD)'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'isolate_create result' )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::IsolateJoin') ) {
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i64_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                            comment  => 'isolate_join stub (threading TBD)'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'isolate_join result' ) );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ChanCreate') ) {
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i64_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                            comment  => 'chan_create stub (null ptr)'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'chan_create result' ) );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ChanSend') ) {

                    # stub -- no-op
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ChanRecv') ) {
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i64_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                            comment  => 'chan_recv stub (0)'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'chan_recv result' ) );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ChanClose') ) {

                    # stub -- no-op
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ChanTrySend') ) {
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i64_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                            comment  => 'chan_try_send stub (false)'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'chan_try_send result' )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ChanTryRecv') ) {
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i64_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                            comment  => 'chan_try_recv stub (0)'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'chan_try_recv result' )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Ret') ) {
                    if ( $inst->type->kind ne 'void' ) {
                        my $val = $inst->operands->[0];
                        if ( $val->type && $val->type->kind eq 'int' && $val->type->bits == 128 ) {
                            my ( $lo, $hi ) = $self->_split_i128($val);
                            $mbb->add_instruction( $self->_wasm_push_opnd( $lo, 'retval lo' ) );
                            $mbb->add_instruction( $self->_wasm_push_opnd( $hi, 'retval hi' ) );
                        }
                        else {

                            # A literal has to be pushed at the width the
                            # *function* returns, not the width the literal
                            # defaults to. `return 0` in a function declared
                            # `-> ptr` pushed an i64 literal into a function the
                            # type section declares as returning i32, and the
                            # validator rejected it. A non-constant needs no
                            # special case here: lower_return already converts
                            # the value to the declared return type, so its
                            # vreg has the right width.
                            my $ret_bits;
                            if ( $inst->type->kind eq 'int' ) {
                                $ret_bits = $inst->type->bits;
                            }
                            elsif ( $inst->type->kind eq 'ptr' ) {
                                $ret_bits = 32;
                            }
                            if ( defined $ret_bits && $val->isa('Brocken::Lindsay::IR::Constant') ) {
                                $mbb->add_instruction( $self->_wasm_push( $val, 'retval', $ret_bits ) );
                            }
                            else {
                                $mbb->add_instruction( $self->_wasm_push( $val, 'retval' ) );
                            }
                        }
                    }
                    $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [], comment => '' ) );
                }
            }
            $mf->add_block($mbb);
        }
        $mf->compute_cfg;
        return $mf;
    }

    # A slot is a per-invocation value, not a place in linear memory, unless
    # something needs its address. Spilling it to the bump cursor instead makes
    # memory scale with the total number of calls rather than the current depth,
    # because nothing ever gives the space back. A wasm local is the engine's own
    # per-invocation slot, reclaimed on return, so promoting removes that cost.
    method _promotable_allocas($ir_func) {
        my %promotable;
        for my $block ( $ir_func->blocks->@* ) {
            for my $inst ( $block->instructions->@* ) {
                next unless $inst->isa('Brocken::Lindsay::IR::Instruction::Alloca');

                # Only a slot of one scalar. A counted alloca is an array, whose
                # base is offset by getelementptr, and a 128-bit one is already
                # lowered as a pair. The block does not matter: a wasm local is
                # per-invocation, so a slot declared in a loop body is one local
                # reused each trip rather than a fresh reservation per trip.
                next if defined $inst->count;
                my $elem = $inst->allocated_type;
                next unless $elem && ( $elem->kind eq 'int' || $elem->kind eq 'ptr' || $elem->kind eq 'float' );
                next if $elem->kind eq 'int' && $elem->bits == 128;
                next unless $inst->name;

                # The address may only ever be the address operand of a load or
                # a store. Any other mention -- a call argument, a return, a
                # pointer add -- needs a real memory object behind it.
                my $escapes = 0;
                OUTER: for my $use_block ( $ir_func->blocks->@* ) {
                    for my $use ( $use_block->instructions->@* ) {
                        next if $use == $inst;
                        if ( $use->isa('Brocken::Lindsay::IR::Instruction::Load') ) {
                            my $addr = $use->operands->[0];
                            next if $addr && $addr->name && $addr->name eq $inst->name;
                        }
                        elsif ( $use->isa('Brocken::Lindsay::IR::Instruction::Store') ) {
                            my $addr = $use->operands->[1];
                            next
                                if $addr
                                && $addr->name
                                && $addr->name eq $inst->name
                                && !$use->operands->[0]->isa($inst);
                        }
                        for my $opnd ( $use->operands->@* ) {
                            next unless $opnd && $opnd->name && $opnd->name eq $inst->name;
                            $escapes = 1;
                            last OUTER;
                        }
                    }
                }
                $promotable{ $inst->name } = $inst unless $escapes;
            }
        }
        return \%promotable;
    }

    method _wasm_push( $ir_val, $label, $force_bits = undef ) {
        if ( $ir_val->isa('Brocken::Lindsay::IR::Constant') ) {
            my $op;

            # Float constants are decided by the value's own type. Checking the
            # forced integer width first would turn an f32 literal into an
            # i32_const, and a float op then gets an integer operand.
            if ( $ir_val->type && $ir_val->type->kind eq 'float' ) {
                $op = $ir_val->type->bits >= 64 ? 'f64_const' : 'f32_const';
            }
            elsif ($force_bits) {

                # The consumer already decided the width from the
                # instruction's own type, so the literal has to be materialised
                # at that width. Inferring it from the constant's type instead
                # mismatched whenever the two disagreed -- most visibly in
                # pointer arithmetic, where the add is i32 (a wasm32 address)
                # but an integer literal defaults to i64, producing
                # `i64.const` followed by `i32.add` and a module the
                # validator rejects with "expected i32, found i64".
                $op = $force_bits >= 64 ? 'i64_const' : 'i32_const';
            }
            else {
                my $bits = $ir_val->type && $ir_val->type->kind eq 'int' ? $ir_val->type->bits : 32;
                $op = $bits >= 64 ? 'i64_const' : 'i32_const';
            }
            return Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => $op,
                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $ir_val->value ) ],
                comment  => "push $label=" . $ir_val->value
            );
        }
        return Brocken::Jenny::MIR::MachineInstruction->new(
            opcode   => 'local_get',
            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $ir_val->name ) ],
            comment  => "push $label=" . $ir_val->name
        );
    }

    method _wasm_push_vreg( $name, $label ) {
        return Brocken::Jenny::MIR::MachineInstruction->new(
            opcode   => 'local_get',
            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $name ) ],
            comment  => $label
        );
    }

    method _wasm_set_vreg( $name, $label ) {
        return Brocken::Jenny::MIR::MachineInstruction->new(
            opcode   => 'local_set',
            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $name ) ],
            comment  => $label
        );
    }

    method _wasm_push_opnd( $opnd, $label ) {
        if ( $opnd->kind eq 'imm' ) {
            return Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i64_const', operands => [$opnd],
                comment => "push $label=" . $opnd->value );
        }
        return Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_get', operands => [$opnd], comment => "push $label=" . $opnd->value );
    }

    method _type_tag($type) {
        return 1 if $type->kind eq 'int' && $type->bits <= 32;
        return 2 if $type->kind eq 'int' && $type->bits == 64;
        return 6 if $type->kind eq 'int' && $type->bits == 128;
        return 3 if $type->kind eq 'float';
        return 4 if $type->kind eq 'ptr';
        return 5 if $type->kind eq 'dynamic';
        return 0;
    }

    method _split_i128($ir_val) {
        if ( $ir_val->isa('Brocken::Lindsay::IR::Constant') ) {
            my $val = $ir_val->value;
            my $lo  = $val & 0xFFFFFFFFFFFFFFFF;
            my $hi  = ( $val >> 64 ) & 0xFFFFFFFFFFFFFFFF;
            $hi = 0xFFFFFFFFFFFFFFFF                 if $val < 0;
            $hi = -( ~$hi & 0xFFFFFFFFFFFFFFFF ) - 1 if $hi >= 0x8000000000000000;
            $lo = -( ~$lo & 0xFFFFFFFFFFFFFFFF ) - 1 if $lo >= 0x8000000000000000;
            return (
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $lo, type => Brocken::Lindsay::IR::Type::i64() ),
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $hi, type => Brocken::Lindsay::IR::Type::i64() ),
            );
        }
        return (
            Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $ir_val->name . '_lo', type => Brocken::Lindsay::IR::Type::i64() ),
            Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $ir_val->name . '_hi', type => Brocken::Lindsay::IR::Type::i64() ),
        );
    }
}

=encoding utf-8

=head1 NAME

Brocken::Jenny::Lowerer::Wasm - WebAssembly Lowerer (Lindsay IR to MIR)

=head1 DESCRIPTION

Lowers Lindsay IR to machine-level MIR for WebAssembly. Translates SSA instructions to WASM-compatible operations.

=head2 Lowering Strategy

=over 4

=item B<Parameters> mapped to C<local.get> / C<local.set> by index (no physical registers)

=item B<Arithmetic> lowered to WASM i32/i64 opcodes directly

=item B<Boxing/Unboxing> packed into linear memory via C<i64.store> / C<i64.load>

=item B<Refcounting> uses C<i64.atomic.rmw> for atomic increment and
C<i64.atomic.rmw> + conditional free for decrement

=item B<Memory> uses WASM linear memory with explicit alignment (4 for i32, 8 for i64)

=back

=head2 Limitations

=over 4

=item * No floating-point arithmetic support (WASM target missing float operations)

=item * No alloca support (WASM has no dynamic stack allocation)

=item * Control flow uses structured blocks with depth-based branch targeting

=back

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
