use v5.42;
use feature qw[class];
use Brocken::Katsuro::Platform::ABI::X86_64;
use Brocken::Jenny::MIR;
use List::Util qw[min max];
class Brocken::Jenny::Lowerer::X86_64 {
    method _abi() { state $abi = Brocken::Katsuro::Platform::ABI::X86_64->new }

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
            if ( $ir_func->blocks->[0] == $block && $ir_func->params->@* ) {
                my @arg_regs = $self->_abi->param_registers->@*;
                for my $i ( 0 .. $#{ $ir_func->params } ) {
                    my $param = $ir_func->params->[$i];
                    my $reg   = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $arg_regs[$i] );
                    my $dst   = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $param->name, type => $param->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $dst, $reg ],
                            comment  => "param $i from " . $arg_regs[$i]
                        )
                    );
                }
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
                    my $is_i128 = $inst->type && $inst->type->kind eq 'int' && $inst->type->bits == 128;
                    if (
                        $is_i128 &&
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
                            $opcode eq 'rem' )
                    ) {
                        if ( $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' ) {
                            my ( $lo_lhs, $hi_lhs ) = $self->_split_i128($lhs);
                            my $lo_dst = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_lo',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $hi_dst = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_hi',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $lo_tmp = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_t',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            if ( $rhs->isa('Brocken::Lindsay::IR::Constant') ) {
                                my $amt = $rhs->value;
                                if ( $amt == 0 ) {
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mov',
                                            operands => [ $lo_dst, $lo_lhs ],
                                            comment  => 'i128 shl/lo by 0'
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mov',
                                            operands => [ $hi_dst, $hi_lhs ],
                                            comment  => 'i128 shl/hi by 0'
                                        )
                                    );
                                }
                                elsif ( $opcode eq 'shl' ) {
                                    if ( $amt < 64 ) {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $lo_dst, $lo_lhs ],
                                                comment  => 'i128 shl lo'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'shl',
                                                operands => [
                                                    $lo_dst,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => $amt,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 shl lo by ' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $lo_tmp, $lo_lhs ],
                                                comment  => 'i128 shl carry tmp'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'lshr',
                                                operands => [
                                                    $lo_tmp,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => 64 - $amt,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 shl carry >> ' . ( 64 - $amt )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $hi_dst, $hi_lhs ],
                                                comment  => 'i128 shl hi'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'shl',
                                                operands => [
                                                    $hi_dst,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => $amt,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 shl hi by ' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'or',
                                                operands => [ $hi_dst, $lo_tmp ],
                                                comment  => 'i128 shl hi |= carry'
                                            )
                                        );
                                    }
                                    elsif ( $amt == 64 ) {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $hi_dst, $lo_lhs ],
                                                comment  => 'i128 shl hi = lo'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'xor',
                                                operands => [ $lo_dst, $lo_dst ],
                                                comment  => 'i128 shl lo = 0'
                                            )
                                        );
                                    }
                                    elsif ( $amt < 128 ) {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $hi_dst, $lo_lhs ],
                                                comment  => 'i128 shl hi = lo'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'shl',
                                                operands => [
                                                    $hi_dst,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => $amt - 64,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 shl hi << ' . ( $amt - 64 )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'xor',
                                                operands => [ $lo_dst, $lo_dst ],
                                                comment  => 'i128 shl lo = 0'
                                            )
                                        );
                                    }
                                    else {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'xor',
                                                operands => [ $lo_dst, $lo_dst ],
                                                comment  => 'i128 shl lo = 0'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'xor',
                                                operands => [ $hi_dst, $hi_dst ],
                                                comment  => 'i128 shl hi = 0'
                                            )
                                        );
                                    }
                                }
                                elsif ( $opcode eq 'lshr' ) {
                                    if ( $amt < 64 ) {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $hi_dst, $hi_lhs ],
                                                comment  => 'i128 lshr hi'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'lshr',
                                                operands => [
                                                    $hi_dst,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => $amt,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 lshr hi >> ' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $lo_tmp, $hi_lhs ],
                                                comment  => 'i128 lshr carry tmp'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'shl',
                                                operands => [
                                                    $lo_tmp,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => 64 - $amt,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 lshr carry << ' . ( 64 - $amt )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $lo_dst, $lo_lhs ],
                                                comment  => 'i128 lshr lo'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'lshr',
                                                operands => [
                                                    $lo_dst,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => $amt,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 lshr lo >> ' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'or',
                                                operands => [ $lo_dst, $lo_tmp ],
                                                comment  => 'i128 lshr lo |= carry'
                                            )
                                        );
                                    }
                                    elsif ( $amt == 64 ) {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $lo_dst, $hi_lhs ],
                                                comment  => 'i128 lshr lo = hi'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'xor',
                                                operands => [ $hi_dst, $hi_dst ],
                                                comment  => 'i128 lshr hi = 0'
                                            )
                                        );
                                    }
                                    elsif ( $amt < 128 ) {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $lo_dst, $hi_lhs ],
                                                comment  => 'i128 lshr lo = hi'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'lshr',
                                                operands => [
                                                    $lo_dst,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => $amt - 64,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 lshr lo >> ' . ( $amt - 64 )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'xor',
                                                operands => [ $hi_dst, $hi_dst ],
                                                comment  => 'i128 lshr hi = 0'
                                            )
                                        );
                                    }
                                    else {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'xor',
                                                operands => [ $lo_dst, $lo_dst ],
                                                comment  => 'i128 lshr lo = 0'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'xor',
                                                operands => [ $hi_dst, $hi_dst ],
                                                comment  => 'i128 lshr hi = 0'
                                            )
                                        );
                                    }
                                }
                                else {
                                    if ( $amt < 64 ) {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $hi_dst, $hi_lhs ],
                                                comment  => 'i128 ashr hi'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'ashr',
                                                operands => [
                                                    $hi_dst,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => $amt,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 ashr hi >> ' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $lo_tmp, $hi_lhs ],
                                                comment  => 'i128 ashr carry tmp'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'shl',
                                                operands => [
                                                    $lo_tmp,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => 64 - $amt,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 ashr carry << ' . ( 64 - $amt )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $lo_dst, $lo_lhs ],
                                                comment  => 'i128 ashr lo'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'lshr',
                                                operands => [
                                                    $lo_dst,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => $amt,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 ashr lo >> ' . $amt
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'or',
                                                operands => [ $lo_dst, $lo_tmp ],
                                                comment  => 'i128 ashr lo |= carry'
                                            )
                                        );
                                    }
                                    elsif ( $amt == 64 ) {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $lo_dst, $hi_lhs ],
                                                comment  => 'i128 ashr lo = hi'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $hi_dst, $hi_lhs ],
                                                comment  => 'i128 ashr hi for sign'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'ashr',
                                                operands => [
                                                    $hi_dst,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => 63,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 ashr sign extend'
                                            )
                                        );
                                    }
                                    elsif ( $amt < 128 ) {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $lo_dst, $hi_lhs ],
                                                comment  => 'i128 ashr lo = hi'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'ashr',
                                                operands => [
                                                    $lo_dst,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => $amt - 64,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 ashr lo >> ' . ( $amt - 64 )
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $hi_dst, $hi_lhs ],
                                                comment  => 'i128 ashr hi for sign'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'ashr',
                                                operands => [
                                                    $hi_dst,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => 63,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 ashr sign extend'
                                            )
                                        );
                                    }
                                    else {
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $lo_dst, $hi_lhs ],
                                                comment  => 'i128 ashr lo = sign'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'ashr',
                                                operands => [
                                                    $lo_dst,
                                                    Brocken::Jenny::MIR::MachineOperand->new(
                                                        kind  => 'imm',
                                                        value => 63,
                                                        type  => Brocken::Lindsay::IR::Type::i64()
                                                    )
                                                ],
                                                comment => 'i128 ashr lo sign'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mov',
                                                operands => [ $hi_dst, $lo_dst ],
                                                comment  => 'i128 ashr hi = sign'
                                            )
                                        );
                                    }
                                }
                            }
                            else {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $lo_dst, $lo_lhs ],
                                        comment  => 'i128 var-shl load lo'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $hi_dst, $hi_lhs ],
                                        comment  => 'i128 var-shl load hi'
                                    )
                                );
                            }
                        }
                        elsif ( $opcode eq 'mul' ) {
                            my ( $lo_lhs, $hi_lhs ) = $self->_split_i128($lhs);
                            my ( $lo_rhs, $hi_rhs ) = $self->_split_i128($rhs);
                            my $lo_dst = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_lo',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $hi_dst = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_hi',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $tmp1 = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_t1',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $tmp2 = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_t2',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $lo_dst, $lo_lhs ],
                                    comment  => 'i128 mul lo'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mul',
                                    operands => [ $lo_dst, $lo_rhs ],
                                    comment  => 'i128 mul lo = a_lo * b_lo'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $hi_dst, $lo_lhs ],
                                    comment  => 'i128 mul hi'
                                )
                            );

                            if ( $lo_rhs->kind eq 'imm' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_rl',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $r, $lo_rhs ],
                                        comment  => 'i128 mul rhs lo'
                                    )
                                );
                                $lo_rhs = $r;
                            }
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'umulh',
                                    operands => [ $hi_dst, $lo_rhs ],
                                    comment  => 'i128 mul hi = umulh(a_lo, b_lo)'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $tmp1, $lo_lhs ],
                                    comment  => 'i128 mul tmp1'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mul',
                                    operands => [ $tmp1, $hi_rhs ],
                                    comment  => 'i128 mul tmp1 = a_lo * b_hi'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'add',
                                    operands => [ $hi_dst, $tmp1 ],
                                    comment  => 'i128 mul hi += tmp1'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $tmp2, $hi_lhs ],
                                    comment  => 'i128 mul tmp2'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mul',
                                    operands => [ $tmp2, $lo_rhs ],
                                    comment  => 'i128 mul tmp2 = a_hi * b_lo'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'add',
                                    operands => [ $hi_dst, $tmp2 ],
                                    comment  => 'i128 mul hi += tmp2'
                                )
                            );
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
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $q_lo, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 div q_lo=0'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $q_hi, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 div q_hi=0'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $r_lo, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 div r_lo=0'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $r_hi, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 div r_hi=0'
                                )
                            );

                            for my $ii ( reverse 0 .. 127 ) {
                                my $val   = $ii >= 64 ? $hi_lhs  : $lo_lhs;
                                my $shift = $ii >= 64 ? $ii - 64 : $ii;
                                my $bit   = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_b$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $carry = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_c$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $t_hi_gt = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_hgt$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $t_hi_eq = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_heq$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $t_lo_ge = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_lge$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $t_cond = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_cond$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $t_neg = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_neg$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $t_mdl = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_mdl$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $t_bor = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_bor$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $t_mdh = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_mdh$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );

                                # bit = (val >> shift) & 1
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $bit, $val ],
                                        comment  => "i128 div bit$ii val"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'lshr',
                                        operands => [ $bit, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $shift ) ],
                                        comment  => "i128 div bit$ii shr"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'and',
                                        operands => [ $bit, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ],
                                        comment  => "i128 div bit$ii and"
                                    )
                                );

                                # carry = r_lo >> 63
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $carry, $r_lo ],
                                        comment  => "i128 div carry$ii load"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'lshr',
                                        operands => [ $carry, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 63 ) ],
                                        comment  => "i128 div carry$ii shr"
                                    )
                                );

                                # r_lo = (r_lo << 1) | bit
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $r_lo, $r_lo ],
                                        comment  => "i128 div r_lo$ii shl"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'shl',
                                        operands => [ $r_lo, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ],
                                        comment  => "i128 div r_lo$ii shl"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'or',
                                        operands => [ $r_lo, $bit ],
                                        comment  => "i128 div r_lo$ii or"
                                    )
                                );

                                # r_hi = (r_hi << 1) | carry
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $r_hi, $r_hi ],
                                        comment  => "i128 div r_hi$ii shl"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'shl',
                                        operands => [ $r_hi, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ],
                                        comment  => "i128 div r_hi$ii shl"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'or',
                                        operands => [ $r_hi, $carry ],
                                        comment  => "i128 div r_hi$ii or"
                                    )
                                );

                                # cond_hi_gt = r_hi > d_hi  (unsigned greater than)
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $t_hi_gt, $r_hi ],
                                        comment  => "i128 div hgt$ii load"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'cmp',
                                        operands => [ $t_hi_gt, $hi_rhs ],
                                        comment  => "i128 div hgt$ii cmp"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $t_hi_gt, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                        comment  => "i128 div hgt$ii zero"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'seta',
                                        operands => [$t_hi_gt],
                                        comment  => "i128 div hgt$ii seta"
                                    )
                                );

                                # cond_hi_eq = r_hi == d_hi
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $t_hi_eq, $r_hi ],
                                        comment  => "i128 div heq$ii load"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'cmp',
                                        operands => [ $t_hi_eq, $hi_rhs ],
                                        comment  => "i128 div heq$ii cmp"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $t_hi_eq, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                        comment  => "i128 div heq$ii zero"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sete',
                                        operands => [$t_hi_eq],
                                        comment  => "i128 div heq$ii sete"
                                    )
                                );

                                # cond_lo_ge = !(r_lo < d_lo)  i.e., r_lo >= d_lo  (unsigned)
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $t_lo_ge, $r_lo ],
                                        comment  => "i128 div lge$ii load"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'cmp',
                                        operands => [ $t_lo_ge, $lo_rhs ],
                                        comment  => "i128 div lge$ii cmp"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $t_lo_ge, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                        comment  => "i128 div lge$ii zero"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'setae',
                                        operands => [$t_lo_ge],
                                        comment  => "i128 div lge$ii setae"
                                    )
                                );

                                # cond = cond_hi_gt | (cond_hi_eq & cond_lo_ge)
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'and',
                                        operands => [ $t_hi_eq, $t_lo_ge ],
                                        comment  => "i128 div cond$ii and"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'or',
                                        operands => [ $t_hi_gt, $t_hi_eq ],
                                        comment  => "i128 div cond$ii or"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $t_cond, $t_hi_gt ],
                                        comment  => "i128 div cond$ii save"
                                    )
                                );

                                # neg_cond = -cond  (0 -> 0, 1 -> -1 = all-ones mask)
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $t_neg, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                        comment  => "i128 div neg$ii zero"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sub',
                                        operands => [ $t_neg, $t_cond ],
                                        comment  => "i128 div neg$ii sub"
                                    )
                                );

                                # masked_d_lo = d_lo & neg_cond
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $t_mdl, $lo_rhs ],
                                        comment  => "i128 div mdl$ii load"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'and',
                                        operands => [ $t_mdl, $t_neg ],
                                        comment  => "i128 div mdl$ii and"
                                    )
                                );

                                # borrow = r_lo < masked_d_lo  (unsigned)
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $t_bor, $r_lo ],
                                        comment  => "i128 div bor$ii load"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'cmp',
                                        operands => [ $t_bor, $t_mdl ],
                                        comment  => "i128 div bor$ii cmp"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $t_bor, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                        comment  => "i128 div bor$ii zero"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'setb',
                                        operands => [$t_bor],
                                        comment  => "i128 div bor$ii setb"
                                    )
                                );

                                # r_lo -= masked_d_lo
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $r_lo, $r_lo ],
                                        comment  => "i128 div r_lo$ii sub"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sub',
                                        operands => [ $r_lo, $t_mdl ],
                                        comment  => "i128 div r_lo$ii sub"
                                    )
                                );

                                # masked_d_hi = d_hi & neg_cond
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $t_mdh, $hi_rhs ],
                                        comment  => "i128 div mdh$ii load"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'and',
                                        operands => [ $t_mdh, $t_neg ],
                                        comment  => "i128 div mdh$ii and"
                                    )
                                );

                                # r_hi -= masked_d_hi + borrow
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $r_hi, $r_hi ],
                                        comment  => "i128 div r_hi$ii sub"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sub',
                                        operands => [ $r_hi, $t_mdh ],
                                        comment  => "i128 div r_hi$ii sub mdh"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sub',
                                        operands => [ $r_hi, $t_bor ],
                                        comment  => "i128 div r_hi$ii sub bor"
                                    )
                                );

                                # Q_bit = (1 << (ii % 64)) & neg_cond
                                my $qbit_val = 1 << ( $ii % 64 );
                                my $qbit     = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . "_qb$ii",
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $qbit, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $qbit_val ) ],
                                        comment  => "i128 div qb$ii val"
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'and',
                                        operands => [ $qbit, $t_neg ],
                                        comment  => "i128 div qb$ii and"
                                    )
                                );
                                if ( $ii >= 64 ) {
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mov',
                                            operands => [ $q_hi, $q_hi ],
                                            comment  => "i128 div q_hi$ii or"
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'or',
                                            operands => [ $q_hi, $qbit ],
                                            comment  => "i128 div q_hi$ii or"
                                        )
                                    );
                                }
                                else {
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mov',
                                            operands => [ $q_lo, $q_lo ],
                                            comment  => "i128 div q_lo$ii or"
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'or',
                                            operands => [ $q_lo, $qbit ],
                                            comment  => "i128 div q_lo$ii or"
                                        )
                                    );
                                }
                            }
                            my $out_lo = $opcode eq 'div' ? $q_lo : $r_lo;
                            my $out_hi = $opcode eq 'div' ? $q_hi : $r_hi;
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $lo_dst, $out_lo ],
                                    comment  => 'i128 div store lo'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $hi_dst, $out_hi ],
                                    comment  => 'i128 div store hi'
                                )
                            );
                        }
                        else {
                            my ( $lo_lhs, $hi_lhs ) = $self->_split_i128($lhs);
                            my ( $lo_rhs, $hi_rhs ) = $self->_split_i128($rhs);
                            my $lo_dst = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_lo',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            my $hi_dst = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_hi',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $lo_dst, $lo_lhs ],
                                    comment  => 'i128 load lo ' . ( $lhs->name || $lhs->value )
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $opcode,
                                    operands => [ $lo_dst, $lo_rhs ],
                                    comment  => 'i128 ' . $opcode . ' lo'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $hi_dst, $hi_lhs ],
                                    comment  => 'i128 load hi ' . ( $lhs->name || $lhs->value )
                                )
                            );
                            if ( $opcode eq 'add' ) {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'adc',
                                        operands => [ $hi_dst, $hi_rhs ],
                                        comment  => 'i128 adc hi'
                                    )
                                );
                            }
                            elsif ( $opcode eq 'sub' ) {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sbb',
                                        operands => [ $hi_dst, $hi_rhs ],
                                        comment  => 'i128 sbb hi'
                                    )
                                );
                            }
                            else {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => $opcode,
                                        operands => [ $hi_dst, $hi_rhs ],
                                        comment  => 'i128 ' . $opcode . ' hi'
                                    )
                                );
                            }
                        }
                    }
                    else {
                        my $dst      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                        my $is_float = $inst->type && $inst->type->kind eq 'float';
                        if ($is_float) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'fmov',
                                    operands => [ $dst, $self->_materialize( $mbb, $lhs ) ],
                                    comment  => 'fload ' . ( $lhs->name || $lhs->value )
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'f' . $opcode,
                                    operands => [ $dst, $self->_materialize( $mbb, $rhs ) ],
                                    comment  => 'f' . $opcode
                                )
                            );
                        }
                        elsif ( $opcode eq 'div' ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'load ' . ( $lhs->name || $lhs->value )
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'udiv',
                                    operands => [ $dst, $self->_lower_opnd($rhs) ],
                                    comment  => 'udiv'
                                )
                            );
                        }
                        elsif ( $opcode eq 'rem' ) {
                            my $tmp = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_rem',
                                type  => $inst->type
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $tmp, $self->_lower_opnd($lhs) ],
                                    comment  => 'load ' . ( $lhs->name || $lhs->value ) . ' (rem tmp)'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'udiv',
                                    operands => [ $tmp, $self->_lower_opnd($rhs) ],
                                    comment  => 'udiv (rem)'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mul',
                                    operands => [ $tmp, $self->_lower_opnd($rhs) ],
                                    comment  => 'mul (rem)'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'load ' . ( $lhs->name || $lhs->value ) . ' (rem)'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'sub',
                                    operands => [ $dst, $tmp ],
                                    comment  => 'sub (rem)'
                                )
                            );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'load ' . ( $lhs->name || $lhs->value )
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $opcode,
                                    operands => [ $dst, $self->_lower_opnd($rhs) ],
                                    comment  => $opcode
                                )
                            );
                        }
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
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'bne',
                            operands => [
                                $self->_lower_opnd( $inst->operands->[0] ),
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->true_block->name )
                            ],
                            comment => 'cond_br: true'
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
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ICmp') ) {
                    my ( $lhs, $rhs ) = $inst->operands->@*;
                    my $pred = $inst->predicate;
                    my %cond = (
                        eq  => 'e',
                        ne  => 'ne',
                        slt => 'l',
                        sgt => 'g',
                        sle => 'le',
                        sge => 'ge',
                        ult => 'b',
                        ugt => 'a',
                        ule => 'be',
                        uge => 'ae'
                    );
                    my %fcond = ( eq => 'e', ne => 'ne', lt => 'b', le => 'be', gt => 'a', ge => 'ae' );
                    my $dst   = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    if ( $lhs->type && $lhs->type->kind eq 'float' ) {
                        my $lhs_op = $self->_materialize( $mbb, $lhs );
                        my $rhs_op = $self->_materialize( $mbb, $rhs );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'fcmp',
                                operands => [ $lhs_op, $rhs_op ],
                                comment  => 'fcmp ' . $pred
                            )
                        );

                        # NaN-correct float comparison (IEEE 754 ordered/unordered)
                        # After UCOMISS: PF=1 when unordered (NaN); only setnp/setp check PF.
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                comment  => 'zero dst'
                            )
                        );
                        if ( $pred eq 'ne' ) {

                            # ne: unordered OR not equal  => setp OR setne
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'setp',
                                    operands => [$dst],
                                    comment  => 'setp: unordered (PF=1)'
                                )
                            );
                        }
                        else {
                            # ordered predicates: setnp AND setCC
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'setnp',
                                    operands => [$dst],
                                    comment  => 'setnp: ordered (PF=0)'
                                )
                            );
                        }
                        my $tmp = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $inst->name . '_pf',
                            type  => Brocken::Lindsay::IR::Type::i1()
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ $tmp, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                comment  => 'zero tmp'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'set' . $fcond{$pred},
                                operands => [$tmp],
                                comment  => 'set' . $fcond{$pred}
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => ( $pred eq 'ne' ? 'or' : 'and' ),
                                operands => [ $dst, $tmp ],
                                comment  => ( $pred eq 'ne' ? 'unordered OR not equal' : 'ordered AND condition' )
                            )
                        );
                    }
                    elsif ( $lhs->type && $lhs->type->kind eq 'int' && $lhs->type->bits == 128 ) {
                        my ( $lo_lhs, $hi_lhs ) = $self->_split_i128($lhs);
                        my ( $lo_rhs, $hi_rhs ) = $self->_split_i128($rhs);
                        my $t0 = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $inst->name . '_t0',
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        my $t1 = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $inst->name . '_t1',
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        my $t2 = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $inst->name . '_t2',
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        if ( $pred eq 'eq' || $pred eq 'ne' ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t0, $lo_lhs ],
                                    comment  => 'i128 icmp lo'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'xor',
                                    operands => [ $t0, $lo_rhs ],
                                    comment  => 'i128 icmp lo_diff'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t1, $hi_lhs ],
                                    comment  => 'i128 icmp hi'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'xor',
                                    operands => [ $t1, $hi_rhs ],
                                    comment  => 'i128 icmp hi_diff'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'or',
                                    operands => [ $t0, $t1 ],
                                    comment  => 'i128 icmp combined'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp zero dst'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'cmp',
                                    operands => [ $t0, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp test'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => ( $pred eq 'eq' ? 'sete' : 'setne' ),
                                    operands => [$dst],
                                    comment  => 'i128 icmp ' . $pred
                                )
                            );
                        }
                        elsif ( $pred eq 'ult' || $pred eq 'slt' ) {
                            my $set_op = $pred eq 'ult' ? 'setb' : 'setl';
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t0, $hi_lhs ],
                                    comment  => 'i128 icmp hi'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'cmp',
                                    operands => [ $t0, $hi_rhs ],
                                    comment  => 'i128 icmp hi_cmp'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t0, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $set_op,
                                    operands => [$t0],
                                    comment  => 'i128 icmp hi_' . $pred
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t1, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sete', operands => [$t1], comment => 'i128 icmp hi_eq' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t2, $lo_lhs ],
                                    comment  => 'i128 icmp lo'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'cmp',
                                    operands => [ $t2, $lo_rhs ],
                                    comment  => 'i128 icmp lo_cmp'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t2, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'setb', operands => [$t2], comment => 'i128 icmp lo_lt' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'and',
                                    operands => [ $t1, $t2 ],
                                    comment  => 'i128 icmp hi_eq&lo_lt'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'or',
                                    operands => [ $t0, $t1 ],
                                    comment  => 'i128 icmp result'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $dst, $t0 ],
                                    comment  => 'i128 icmp ' . $pred
                                )
                            );
                        }
                        elsif ( $pred eq 'ugt' || $pred eq 'sgt' ) {
                            my $set_op = $pred eq 'ugt' ? 'setb' : 'setl';
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t0, $hi_rhs ],
                                    comment  => 'i128 icmp hi (swapped)'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'cmp',
                                    operands => [ $t0, $hi_lhs ],
                                    comment  => 'i128 icmp hi_cmp'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t0, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $set_op,
                                    operands => [$t0],
                                    comment  => 'i128 icmp hi_' . $pred
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t1, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sete', operands => [$t1], comment => 'i128 icmp hi_eq' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t2, $lo_rhs ],
                                    comment  => 'i128 icmp lo (swapped)'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'cmp',
                                    operands => [ $t2, $lo_lhs ],
                                    comment  => 'i128 icmp lo_cmp'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t2, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'setb', operands => [$t2], comment => 'i128 icmp lo_lt' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'and',
                                    operands => [ $t1, $t2 ],
                                    comment  => 'i128 icmp hi_eq&lo_lt'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'or',
                                    operands => [ $t0, $t1 ],
                                    comment  => 'i128 icmp result'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $dst, $t0 ],
                                    comment  => 'i128 icmp ' . $pred
                                )
                            );
                        }
                        else {
                            my ( $set_lt, $swap )
                                = $pred eq 'ule' ? ( 'setb', 1 ) :
                                $pred eq 'uge'   ? ( 'setb', 0 ) :
                                $pred eq 'sle'   ? ( 'setl', 1 ) :
                                ( 'setl', 0 );
                            my ( $hi_a, $hi_b, $lo_a, $lo_b );
                            if ($swap) {
                                ( $hi_a, $hi_b ) = ( $hi_rhs, $hi_lhs );
                                ( $lo_a, $lo_b ) = ( $lo_rhs, $lo_lhs );
                            }
                            else {
                                ( $hi_a, $hi_b ) = ( $hi_lhs, $hi_rhs );
                                ( $lo_a, $lo_b ) = ( $lo_lhs, $lo_rhs );
                            }
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t0, $hi_a ],
                                    comment  => 'i128 icmp hi'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'cmp',
                                    operands => [ $t0, $hi_b ],
                                    comment  => 'i128 icmp hi_cmp'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t0, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $set_lt,
                                    operands => [$t0],
                                    comment  => 'i128 icmp hi_lt'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t1, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sete', operands => [$t1], comment => 'i128 icmp hi_eq' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t2, $lo_a ],
                                    comment  => 'i128 icmp lo'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'cmp',
                                    operands => [ $t2, $lo_b ],
                                    comment  => 'i128 icmp lo_cmp'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t2, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'setb', operands => [$t2], comment => 'i128 icmp lo_lt' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'and',
                                    operands => [ $t1, $t2 ],
                                    comment  => 'i128 icmp hi_eq&lo_lt'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'or',
                                    operands => [ $t0, $t1 ],
                                    comment  => 'i128 icmp result'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp zero dst'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'cmp',
                                    operands => [ $t0, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp not test'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'sete',
                                    operands => [$dst],
                                    comment  => 'i128 icmp ' . $pred
                                )
                            );
                        }
                    }
                    else {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ $dst, $self->_lower_opnd($lhs) ],
                                comment  => 'load lhs'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'cmp',
                                operands => [ $dst, $self->_lower_opnd($rhs) ],
                                comment  => 'icmp ' . $pred
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'set' . $cond{$pred},
                                operands => [$dst],
                                comment  => 'set' . $cond{$pred}
                            )
                        );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Ret') ) {
                    if ( $inst->type->kind ne 'void' ) {
                        my $val = $inst->operands->[0];
                        my $abi = $self->_abi;
                        if ( $inst->type->kind eq 'float' ) {
                            my $fp_ret = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $abi->fp_return_register );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'fmov',
                                    operands => [ $fp_ret, $self->_materialize( $mbb, $val ) ],
                                    comment  => '=> ' . $abi->fp_return_register
                                )
                            );
                        }
                        else {
                            my $is_i128 = $val->type && $val->type->kind eq 'int' && $val->type->bits == 128;
                            if ($is_i128) {
                                my $rax = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $abi->return_register );
                                my $rdx = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rdx' );
                                my ( $lo, $hi ) = $self->_split_i128($val);
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $rax, $lo ],
                                        comment  => '=> ' . $abi->return_register . ' (i128 lo)'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $rdx, $hi ],
                                        comment  => '=> rdx (i128 hi)'
                                    )
                                );
                            }
                            else {
                                my $ret_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $abi->return_register );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $ret_reg, $self->_lower_opnd($val) ],
                                        comment  => '=> ' . $abi->return_register
                                    )
                                );
                            }
                        }
                    }
                    $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [], comment => '' ) );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Alloca') ) {
                    my $dst  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    my $size = $inst->allocated_type->bits / 8;
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'alloca',
                            operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $size ) ],
                            comment  => "alloca $size bytes"
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Load') ) {
                    my $ptr     = $inst->operands->[0];
                    my $is_i128 = $inst->type && $inst->type->kind eq 'int' && $inst->type->bits == 128;
                    if ($is_i128) {
                        my $lo_dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $inst->name . '_lo',
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        my $hi_dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $inst->name . '_hi',
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        my $mem_lo = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $ptr->name, disp => 0 },
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        my $mem_hi = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $ptr->name, disp => 8 },
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'load',
                                operands => [ $lo_dst, $mem_lo ],
                                comment  => 'i128 load lo'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'load',
                                operands => [ $hi_dst, $mem_hi ],
                                comment  => 'i128 load hi'
                            )
                        );
                    }
                    else {
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $ptr->name, disp => 0 },
                            type  => $inst->type
                        );
                        my $dst     = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                        my $load_op = ( $inst->type && $inst->type->kind eq 'float' ) ? 'fload' : 'load';
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => $load_op, operands => [ $dst, $mem ], comment => 'load' ) );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Store') ) {
                    my ( $val, $ptr ) = $inst->operands->@*;
                    my $is_i128 = $val->type && $val->type->kind eq 'int' && $val->type->bits == 128;
                    if ($is_i128) {
                        my ( $lo, $hi ) = $self->_split_i128($val);
                        my $mem_lo = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $ptr->name, disp => 0 },
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        my $mem_hi = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $ptr->name, disp => 8 },
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => ( $lo->kind eq 'imm' ? 'store_imm' : 'store' ),
                                operands => [ $mem_lo, $lo ],
                                comment  => 'i128 store lo'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => ( $hi->kind eq 'imm' ? 'store_imm' : 'store' ),
                                operands => [ $mem_hi, $hi ],
                                comment  => 'i128 store hi'
                            )
                        );
                    }
                    else {
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $ptr->name, disp => 0 },
                            type  => $val->type
                        );
                        if ( $val->type && $val->type->kind eq 'float' ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'fstore',
                                    operands => [ $mem, $self->_materialize( $mbb, $val ) ],
                                    comment  => 'fstore'
                                )
                            );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => ( $val->isa('Brocken::Lindsay::IR::Constant') ? 'store_imm' : 'store' ),
                                    operands => [ $mem, $self->_lower_opnd($val) ],
                                    comment  => 'store'
                                )
                            );
                        }
                    }
                }
                elsif ( $opcode eq 'neg' || $opcode eq 'abs' || $opcode eq 'sqrt' ) {
                    my ($val) = $inst->operands->@*;
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    if ( $inst->type && $inst->type->kind eq 'float' ) {
                        my $src = $self->_materialize( $mbb, $val );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'fmov',
                                operands => [ $dst, $src ],
                                comment  => 'load ' . $opcode . ' operand'
                            )
                        );
                        if ( $opcode eq 'sqrt' ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'fsqrt', operands => [ $dst, $dst ], comment => 'fsqrt' )
                            );
                        }
                        else {
                            my $bits     = $inst->type->bits;
                            my $mask_val = $opcode eq 'neg' ? ( $bits >= 64 ? 0x8000000000000000 : 0x80000000 ) :
                                ( $bits >= 64 ? 0x7FFFFFFFFFFFFFFF : 0x7FFFFFFF );
                            my $mname   = $inst->name . '_m';
                            my $mask_gp = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $mname,
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $mask_gp, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $mask_val ) ],
                                    comment  => 'mask constant'
                                )
                            );
                            my $mask_fp
                                = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $mname . 'f', type => $inst->type );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'fmov_gp2f',
                                    operands => [ $mask_fp, $mask_gp ],
                                    comment  => 'mask -> XMM'
                                )
                            );
                            my $fop = $opcode eq 'neg' ? 'fxor' : 'fand';
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => $fop, operands => [ $dst, $mask_fp ], comment => $fop ) );
                        }
                    }
                    else {
                        die "Unsupported unary op $opcode for non-float type";
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Box') ) {
                    my $val  = $inst->operands->[0];
                    my $tag  = $self->_type_tag( $val->type );
                    my $size = 16;                               # fat scalar: 16 bytes (8 payload + 8 tag)
                    my $dyn  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );

                    # alloca %dyn, 16
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'alloca',
                            operands => [ $dyn, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $size ) ],
                            comment  => 'box: alloca 16'
                        )
                    );

                    # store [%dyn + 0], %val
                    my $mem_val = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name, disp => 0 },
                        type  => $val->type
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => ( $val->isa('Brocken::Lindsay::IR::Constant') ? 'store_imm' : 'store' ),
                            operands => [ $mem_val, $self->_lower_opnd($val) ],
                            comment  => 'box: store payload'
                        )
                    );

                    # store [%dyn + 8], tag
                    my $mem_tag = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name, disp => 8 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store_imm',
                            operands => [
                                $mem_tag,
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'imm',
                                    value => $tag,
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                )
                            ],
                            comment => 'box: store tag'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Unbox') ) {
                    my $dyn = $inst->operands->[0];
                    my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $dyn->name, disp => 0 },
                        type  => $inst->type
                    );
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'load',
                            operands => [ $dst, $mem ],
                            comment  => 'unbox: load payload'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr') ) {
                    my ( $ptr, @indices ) = $inst->operands->@*;
                    my $scale = $inst->base_type->bits / 8;
                    my $idx   = $indices[0];
                    my $dst   = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    if ( $idx->isa('Brocken::Lindsay::IR::Constant') ) {
                        my $offset = $idx->value * $scale;
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'lea',
                                operands => [
                                    $dst,
                                    Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'mem',
                                        value => { base => $ptr->name, disp => $offset },
                                        type  => $ptr->type
                                    )
                                ],
                                comment => 'gep: lea const offset ' . $offset
                            )
                        );
                    }
                    else {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'lea',
                                operands => [
                                    $dst,
                                    Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'mem',
                                        value => { base => $ptr->name, index => $idx->name, scale => $scale, disp => 0 },
                                        type  => $ptr->type
                                    )
                                ],
                                comment => 'gep: lea indexed'
                            )
                        );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Call') ) {
                    my $callee   = $inst->callee;
                    my @args     = $inst->operands->@*;
                    my $abi      = $self->_abi;
                    my @arg_regs = $abi->param_registers->@*;
                    for my $i ( 0 .. $#args ) {
                        my $reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $arg_regs[$i] );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ $reg, $self->_lower_opnd( $args[$i] ) ],
                                comment  => "arg $i to $arg_regs[$i]"
                            )
                        );
                    }
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'call_func',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => $callee->name ) ],
                            comment  => "call @" . $callee->name
                        )
                    );
                    if ( defined $inst->name ) {
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                        if ( $inst->type->kind eq 'float' ) {
                            my $fp_ret = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $abi->fp_return_register );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'fmov',
                                    operands => [ $dst, $fp_ret ],
                                    comment  => "retval from " . $abi->fp_return_register
                                )
                            );
                        }
                        else {
                            my $ret_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $abi->return_register );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $dst, $ret_reg ],
                                    comment  => "retval from " . $abi->return_register
                                )
                            );
                        }
                    }
                }
            }
            $mf->add_block($mbb);
        }
        return $mf;
    }

    method _type_tag($type) {
        return 1 if $type->kind eq 'int' && $type->bits <= 32;    # i1, i8, i16, i32
        return 2 if $type->kind eq 'int' && $type->bits == 64;
        return 6 if $type->kind eq 'int' && $type->bits == 128;
        return 3 if $type->kind eq 'float';                       # f32, f64
        return 4 if $type->kind eq 'ptr';
        return 5 if $type->kind eq 'dynamic';
        return 0;
    }

    method _split_i128($ir_val) {
        if ( $ir_val->isa('Brocken::Lindsay::IR::Constant') ) {
            my $val = $ir_val->value;
            my $lo  = $val & 0xFFFFFFFFFFFFFFFF;
            my $hi  = ( $val >> 64 ) & 0xFFFFFFFFFFFFFFFF;
            $hi = -( ~$hi & 0xFFFFFFFFFFFFFFFF ) - 1 if $hi >= 0x8000000000000000;
            $lo = -( ~$lo & 0xFFFFFFFFFFFFFFFF ) - 1 if $lo >= 0x8000000000000000;
            return (
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $lo, type => Brocken::Lindsay::IR::Type::i64() ),
                Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $hi, type => Brocken::Lindsay::IR::Type::i64() ),
            );
        }
        return (
            Brocken::Jenny::MIR::MachineOperand->new(
                kind  => 'virt_reg',
                value => $ir_val->name . '_lo',
                type  => Brocken::Lindsay::IR::Type::i64()
            ),
            Brocken::Jenny::MIR::MachineOperand->new(
                kind  => 'virt_reg',
                value => $ir_val->name . '_hi',
                type  => Brocken::Lindsay::IR::Type::i64()
            ),
        );
    }

    method _materialize( $mbb, $ir_val ) {
        state $fc = 0;
        if ( $ir_val->isa('Brocken::Lindsay::IR::Constant') && $ir_val->type && $ir_val->type->kind eq 'float' ) {
            my $bits        = $ir_val->type->bits;
            my $value       = $ir_val->value;
            my $bit_pattern = $bits >= 64 ? unpack( 'Q', pack( 'd', $value ) ) : unpack( 'V', pack( 'f', $value ) );
            my $gp_name     = '%fmcgp_' . $fc++;
            my $fp_name     = '%fmcfp_' . $fc++;
            my $gp_type     = Brocken::Lindsay::IR::Type::i64();
            my $gp          = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $gp_name, type => $gp_type );
            my $fp          = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $fp_name, type => $ir_val->type );
            $mbb->add_instruction(
                Brocken::Jenny::MIR::MachineInstruction->new(
                    opcode   => 'mov',
                    operands => [ $gp, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $bit_pattern, type => $gp_type ) ],
                    comment  => 'fmc: bit pattern'
                )
            );
            $mbb->add_instruction(
                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'fmov_gp2f', operands => [ $fp, $gp ], comment => 'fmc: gp->xmm' ) );
            return $fp;
        }
        return $self->_lower_opnd($ir_val);
    }

    method _lower_opnd($ir_val) {
        if ( $ir_val->isa('Brocken::Lindsay::IR::Constant') ) {
            return Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $ir_val->value, type => $ir_val->type );
        }
        return Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $ir_val->name, type => $ir_val->type );
    }
}

# ---------------------------------------------------------------------------
# Lowerer: Lindsay IR -> Machine IR (ARM64 / AArch64)
1;