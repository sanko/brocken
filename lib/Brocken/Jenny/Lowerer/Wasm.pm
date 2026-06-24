use v5.42;
use feature qw[class];
no warnings qw[portable];
no warnings qw[experimental::class];
use Brocken::Jenny::MIR;
use List::Util qw[min max];

class Brocken::Jenny::Lowerer::Wasm {

    method lower($ir_func) {
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
                        elsif ( $opcode eq 'div' || $opcode eq 'rem' ) {
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
                        if ( $inst->type && $inst->type->kind eq 'float' ) {
                            $p = $inst->type->bits >= 64 ? 'f64' : 'f32';
                        }
                        else {
                            my $bits = $inst->type && $inst->type->kind eq 'int' ? $inst->type->bits : 32;
                            $p = $bits >= 64 ? 'i64' : 'i32';
                        }

                        # Push LHS onto Wasm stack
                        $mbb->add_instruction( $self->_wasm_push( $lhs, 'LHS' ) );

                        # Push RHS onto Wasm stack
                        $mbb->add_instruction( $self->_wasm_push( $rhs, 'RHS' ) );

                        # Arithmetic/bitwise op (consumes 2, produces 1 on stack)
                        my %map = (
                            add  => "${p}_add",
                            sub  => "${p}_sub",
                            mul  => "${p}_mul",
                            div  => "${p}_div_u",
                            rem  => "${p}_rem_u",
                            and  => "${p}_and",
                            or   => "${p}_or",
                            xor  => "${p}_xor",
                            shl  => "${p}_shl",
                            lshr => "${p}_shr_u",
                            ashr => "${p}_shr_s",
                            min  => "${p}_min",
                            max  => "${p}_max",
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => $map{$opcode}, operands => [], comment => $opcode ) );

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
                elsif ( $opcode eq 'neg' || $opcode eq 'abs' || $opcode eq 'sqrt' ) {
                    my ($val) = $inst->operands->@*;
                    die "Wasm unary op $opcode requires float type" unless $inst->type && $inst->type->kind eq 'float';
                    my $p = $inst->type->bits >= 64 ? 'f64' : 'f32';
                    print STDERR ">>> UNARY $opcode: pushing val of type " .
                        ( $val->type                                  ? $val->type->kind       : 'undef' ) . " val=" .
                        ( $val->isa('Brocken::Lindsay::IR::Constant') ? 'Const:' . $val->value : ( $val->name // 'anon' ) ) . "\n";
                    $mbb->add_instruction( $self->_wasm_push( $val, 'unop: val' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => "${p}_${opcode}", operands => [], comment => $opcode ) );
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'local_set', operands => [$dst], comment => 'store ' . $inst->name )
                    );
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
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Alloca') ) {
                    my $size = $inst->allocated_type->bits / 8;

                    # save current heap_ptr as result
                    $mbb->add_instruction( $self->_wasm_push_vreg( '%heap_ptr', 'alloca: push heap' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'local_set',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                            comment  => 'alloca: save to ' . $inst->name
                        )
                    );

                    # heap_ptr += size
                    $mbb->add_instruction( $self->_wasm_push_vreg( '%heap_ptr', 'alloca: push heap' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i32_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $size ) ],
                            comment  => "alloca: size $size"
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_add', operands => [], comment => 'alloca: add' ) );
                    $mbb->add_instruction( $self->_wasm_set_vreg( '%heap_ptr', 'alloca: save heap' ) );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Load') ) {
                    my $ptr = $inst->operands->[0];
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

                    # save heap_ptr as result
                    $mbb->add_instruction( $self->_wasm_push_vreg( '%heap_ptr', 'box: push heap' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'local_set',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                            comment  => 'box: save to ' . $inst->name
                        )
                    );

                    # heap_ptr += 16
                    $mbb->add_instruction( $self->_wasm_push_vreg( '%heap_ptr', 'box: push heap' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'i32_const',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 16 ) ],
                            comment  => 'box: bump 16'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_add', operands => [], comment => 'box: add' ) );
                    $mbb->add_instruction( $self->_wasm_set_vreg( '%heap_ptr', 'box: save heap' ) );

                    # store payload at [%dyn + 0]
                    $mbb->add_instruction( $self->_wasm_push_vreg( $inst->name, 'box: push dyn' ) );
                    $mbb->add_instruction( $self->_wasm_push( $val, 'box: push val' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_store', operands => [], comment => 'box: store payload' ) );

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
                    $mbb->add_instruction( $self->_wasm_push( $dyn, 'unbox: push dyn' ) );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_load', operands => [], comment => 'unbox: load payload' ) );
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
                    $mbb->add_instruction( $self->_wasm_push( $lhs, 'icmp lhs' ) );
                    $mbb->add_instruction( $self->_wasm_push( $rhs, 'icmp rhs' ) );
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
                    die "isolate_create not yet implemented on Wasm";
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::IsolateJoin') ) {
                    die "isolate_join not yet implemented on Wasm";
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
                            $mbb->add_instruction( $self->_wasm_push( $val, 'retval' ) );
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

    method _wasm_push( $ir_val, $label ) {
        if ( $ir_val->isa('Brocken::Lindsay::IR::Constant') ) {
            my $op;
            if ( $ir_val->type && $ir_val->type->kind eq 'float' ) {
                $op = $ir_val->type->bits >= 64 ? 'f64_const' : 'f32_const';
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
