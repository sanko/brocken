use v5.42;
use feature qw[class];
no warnings qw[portable];
no warnings qw[experimental::class];
use Brocken::Jenny::MIR;

class Brocken::Jenny::Lowerer::RISCV64 {
    field $platform : param;
    method _abi() { $platform->abi }

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
                my @gp_regs = $self->_abi->param_registers->@*;
                my @fp_regs = $self->_abi->fp_param_registers->@*;
                my ( $gp_idx, $fp_idx ) = ( 0, 0 );
                for my $i ( 0 .. $#{ $ir_func->params } ) {
                    my $param    = $ir_func->params->[$i];
                    my $is_float = $param->type && $param->type->kind eq 'float';
                    my $reg_name = $is_float ? $fp_regs[ $fp_idx++ ] : $gp_regs[ $gp_idx++ ];
                    my $reg      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $reg_name );
                    my $dst      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $param->name, type => $param->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => $is_float ? 'fmov' : 'mv',
                            operands => [ $dst, $reg ],
                            comment  => "param $i from " . $reg_name
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
                    $opcode eq 'ashr' ) {
                    my ( $lhs, $rhs ) = $inst->operands->@*;
                    my $is_float = $lhs->type && $lhs->type->kind eq 'float';
                    my $mop      = $is_float ? "f$opcode" : $opcode;
                    $mop = $opcode if $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr';
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
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
                                opcode   => $mop,
                                operands => [ $dst, $self->_materialize( $mbb, $rhs ) ],
                                comment  => $opcode
                            )
                        );
                    }
                    else {
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
                                                opcode   => 'mv',
                                                operands => [ $lo_dst, $lo_lhs ],
                                                comment  => 'i128 shl lo by 0'
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mv',
                                                operands => [ $hi_dst, $hi_lhs ],
                                                comment  => 'i128 shl hi by 0'
                                            )
                                        );
                                    }
                                    elsif ( $opcode eq 'shl' ) {
                                        if ( $amt < 64 ) {
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
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
                                                    comment => 'i128 shl lo<<' . $amt
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
                                                    operands => [ $lo_tmp, $lo_lhs ],
                                                    comment  => 'i128 shl carry'
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
                                                    comment => 'i128 shl carry>>' . ( 64 - $amt )
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
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
                                                    comment => 'i128 shl hi<<' . $amt
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'or',
                                                    operands => [ $hi_dst, $lo_tmp ],
                                                    comment  => 'i128 shl hi|=carry'
                                                )
                                            );
                                        }
                                        elsif ( $amt == 64 ) {
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
                                                    operands => [ $hi_dst, $lo_lhs ],
                                                    comment  => 'i128 shl hi=lo'
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'xor',
                                                    operands => [ $lo_dst, $lo_dst ],
                                                    comment  => 'i128 shl lo=0'
                                                )
                                            );
                                        }
                                        elsif ( $amt < 128 ) {
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
                                                    operands => [ $hi_dst, $lo_lhs ],
                                                    comment  => 'i128 shl hi=lo'
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
                                                    comment => 'i128 shl hi<<' . ( $amt - 64 )
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'xor',
                                                    operands => [ $lo_dst, $lo_dst ],
                                                    comment  => 'i128 shl lo=0'
                                                )
                                            );
                                        }
                                        else {
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'xor',
                                                    operands => [ $lo_dst, $lo_dst ],
                                                    comment  => 'i128 shl lo=0'
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'xor',
                                                    operands => [ $hi_dst, $hi_dst ],
                                                    comment  => 'i128 shl hi=0'
                                                )
                                            );
                                        }
                                    }
                                    elsif ( $opcode eq 'lshr' ) {
                                        if ( $amt < 64 ) {
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
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
                                                    comment => 'i128 lshr hi>>' . $amt
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
                                                    operands => [ $lo_tmp, $hi_lhs ],
                                                    comment  => 'i128 lshr carry'
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
                                                    comment => 'i128 lshr carry<<' . ( 64 - $amt )
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
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
                                                    comment => 'i128 lshr lo>>' . $amt
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'or',
                                                    operands => [ $lo_dst, $lo_tmp ],
                                                    comment  => 'i128 lshr lo|=carry'
                                                )
                                            );
                                        }
                                        elsif ( $amt == 64 ) {
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
                                                    operands => [ $lo_dst, $hi_lhs ],
                                                    comment  => 'i128 lshr lo=hi'
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'xor',
                                                    operands => [ $hi_dst, $hi_dst ],
                                                    comment  => 'i128 lshr hi=0'
                                                )
                                            );
                                        }
                                        elsif ( $amt < 128 ) {
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
                                                    operands => [ $lo_dst, $hi_lhs ],
                                                    comment  => 'i128 lshr lo=hi'
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
                                                    comment => 'i128 lshr lo>>' . ( $amt - 64 )
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'xor',
                                                    operands => [ $hi_dst, $hi_dst ],
                                                    comment  => 'i128 lshr hi=0'
                                                )
                                            );
                                        }
                                        else {
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'xor',
                                                    operands => [ $lo_dst, $lo_dst ],
                                                    comment  => 'i128 lshr lo=0'
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'xor',
                                                    operands => [ $hi_dst, $hi_dst ],
                                                    comment  => 'i128 lshr hi=0'
                                                )
                                            );
                                        }
                                    }
                                    else {
                                        if ( $amt < 64 ) {
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
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
                                                    comment => 'i128 ashr hi>>' . $amt
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
                                                    operands => [ $lo_tmp, $hi_lhs ],
                                                    comment  => 'i128 ashr carry'
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
                                                    comment => 'i128 ashr carry<<' . ( 64 - $amt )
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
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
                                                    comment => 'i128 ashr lo>>' . $amt
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'or',
                                                    operands => [ $lo_dst, $lo_tmp ],
                                                    comment  => 'i128 ashr lo|=carry'
                                                )
                                            );
                                        }
                                        elsif ( $amt == 64 ) {
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
                                                    operands => [ $lo_dst, $hi_lhs ],
                                                    comment  => 'i128 ashr lo=hi'
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
                                                    operands => [ $hi_dst, $hi_lhs ],
                                                    comment  => 'i128 ashr hi sign'
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
                                                    opcode   => 'mv',
                                                    operands => [ $lo_dst, $hi_lhs ],
                                                    comment  => 'i128 ashr lo=hi'
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
                                                    comment => 'i128 ashr lo>>' . ( $amt - 64 )
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
                                                    operands => [ $hi_dst, $hi_lhs ],
                                                    comment  => 'i128 ashr hi sign'
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
                                                    opcode   => 'mv',
                                                    operands => [ $lo_dst, $hi_lhs ],
                                                    comment  => 'i128 ashr lo sign'
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
                                                    comment => 'i128 ashr lo>>63'
                                                )
                                            );
                                            $mbb->add_instruction(
                                                Brocken::Jenny::MIR::MachineInstruction->new(
                                                    opcode   => 'mv',
                                                    operands => [ $hi_dst, $lo_dst ],
                                                    comment  => 'i128 ashr hi=sign'
                                                )
                                            );
                                        }
                                    }
                                }
                                else {
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $lo_dst, $lo_lhs ],
                                            comment  => 'i128 var-shl lo'
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $hi_dst, $hi_lhs ],
                                            comment  => 'i128 var-shl hi'
                                        )
                                    );
                                }
                            }
                            elsif ( $opcode eq 'mul' ) {
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
                                my ( $lo_lhs, $hi_lhs ) = $self->_split_i128($lhs);
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
                                        opcode   => 'mv',
                                        operands => [ $lo_dst, $lo_lhs ],
                                        comment  => 'i128 mul lo'
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
                                            opcode   => 'mv',
                                            operands => [ $r, $lo_rhs ],
                                            comment  => 'i128 mul rhs lo'
                                        )
                                    );
                                    $lo_rhs = $r;
                                }
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mul',
                                        operands => [ $lo_dst, $lo_rhs ],
                                        comment  => 'i128 mul lo = a_lo * b_lo'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $hi_dst, $lo_lhs ],
                                        comment  => 'i128 mul hi'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mulhu',
                                        operands => [ $hi_dst, $lo_rhs ],
                                        comment  => 'i128 mul hi = mulhu(a_lo, b_lo)'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $tmp1, $lo_lhs ],
                                        comment  => 'i128 mul tmp1'
                                    )
                                );
                                if ( $hi_rhs->kind eq 'imm' ) {
                                    my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_rh',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $r, $hi_rhs ],
                                            comment  => 'i128 mul rhs hi'
                                        )
                                    );
                                    $hi_rhs = $r;
                                }
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
                                        opcode   => 'mv',
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
                                        opcode   => 'mv',
                                        operands => [ $q_lo, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                        comment  => 'i128 div q_lo=0'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $q_hi, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                        comment  => 'i128 div q_hi=0'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $r_lo, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                        comment  => 'i128 div r_lo=0'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $r_hi, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                        comment  => 'i128 div r_hi=0'
                                    )
                                );

                                # ---- signed i128 div/rem: convert inputs to absolute values ----
                                my $imm = sub ($v) {
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $v, type => Brocken::Lindsay::IR::Type::i64() );
                                };
                                my $sixty3 = $imm->(63);
                                if ( $lo_lhs->kind eq 'imm' ) {
                                    my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_mlo',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $r, $lo_lhs ] ) );
                                    $lo_lhs = $r;
                                }
                                if ( $hi_lhs->kind eq 'imm' ) {
                                    my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_mhi',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $r, $hi_lhs ] ) );
                                    $hi_lhs = $r;
                                }
                                if ( $lo_rhs->kind eq 'imm' ) {
                                    my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_rmlo',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $r, $lo_rhs ] ) );
                                    $lo_rhs = $r;
                                }
                                if ( $hi_rhs->kind eq 'imm' ) {
                                    my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_rmhi',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $r, $hi_rhs ] ) );
                                    $hi_rhs = $r;
                                }
                                my $apply_mask128 = sub ( $name, $lo, $hi, $mask ) {
                                    my $bor = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => "${name}_bor",
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    my $tmp = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => "${name}_tmp",
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $tmp, $lo ] ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'xor', operands => [ $tmp, $mask ] ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $bor, $tmp ] ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'sltu',
                                            operands => [ $bor, $mask ],
                                            comment  => 'mask128 borrow'
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sub', operands => [ $tmp, $mask ] ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $lo, $tmp ] ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $tmp, $hi ] ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'xor', operands => [ $tmp, $mask ] ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sub', operands => [ $tmp, $mask ] ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sub', operands => [ $tmp, $bor ] ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $hi, $tmp ] ) );
                                };
                                my $sign_d = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_sgnd',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $sign_d, $hi_lhs ],
                                        comment  => 'i128 sign d mv'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'lshr',
                                        operands => [ $sign_d, $sixty3 ],
                                        comment  => 'i128 sign d lshr'
                                    )
                                );
                                my $mask_d = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_mskd',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $mask_d, $imm->(0) ],
                                        comment  => 'i128 mask d=0'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sub',
                                        operands => [ $mask_d, $sign_d ],
                                        comment  => 'i128 mask d=-sign'
                                    )
                                );
                                $apply_mask128->( $inst->name . '_ad', $lo_lhs, $hi_lhs, $mask_d );
                                my $sign_v = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_signv',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $sign_v, $hi_rhs ],
                                        comment  => 'i128 sign v mv'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'lshr',
                                        operands => [ $sign_v, $sixty3 ],
                                        comment  => 'i128 sign v lshr'
                                    )
                                );
                                my $mask_v = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_mskv',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $mask_v, $imm->(0) ],
                                        comment  => 'i128 mask v=0'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sub',
                                        operands => [ $mask_v, $sign_v ],
                                        comment  => 'i128 mask v=-sign'
                                    )
                                );
                                $apply_mask128->( $inst->name . '_av', $lo_rhs, $hi_rhs, $mask_v );

                                # ---- end signed handling ----
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
                                    my $i_one = Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 );

                                    # bit = (val >> shift) & 1
                                    my $one = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . "_one$ii",
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $bit, $val ],
                                            comment  => "i128 div bit$ii val"
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $one, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ],
                                            comment  => "i128 div bit$ii one"
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'lshr',
                                            operands => [
                                                $bit,
                                                Brocken::Jenny::MIR::MachineOperand->new(
                                                    kind  => 'imm',
                                                    value => $shift,
                                                    type  => Brocken::Lindsay::IR::Type::i64()
                                                )
                                            ],
                                            comment => "i128 div bit$ii shr"
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'and',
                                            operands => [ $bit, $one ],
                                            comment  => "i128 div bit$ii and"
                                        )
                                    );

                                    # carry = r_lo >> 63
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
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
                                            opcode   => 'mv',
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
                                            opcode   => 'mv',
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

                                    # cond_hi_gt = r_hi > d_hi  (unsigned = d_hi < r_hi)
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $t_hi_gt, $hi_rhs ],
                                            comment  => "i128 div hgt$ii load d_hi"
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'sltu',
                                            operands => [ $t_hi_gt, $r_hi ],
                                            comment  => "i128 div hgt$ii sltu"
                                        )
                                    );

                                    # cond_hi_eq = r_hi == d_hi
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $t_hi_eq, $r_hi ],
                                            comment  => "i128 div heq$ii load"
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'xor',
                                            operands => [ $t_hi_eq, $hi_rhs ],
                                            comment  => "i128 div heq$ii xor"
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'sltiu',
                                            operands => [ $t_hi_eq, $i_one ],
                                            comment  => "i128 div heq$ii seqz"
                                        )
                                    );

                                    # cond_lo_ge = r_lo >= d_lo  (i.e., !(r_lo < d_lo))
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $t_lo_ge, $r_lo ],
                                            comment  => "i128 div lge$ii load"
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'sltu',
                                            operands => [ $t_lo_ge, $lo_rhs ],
                                            comment  => "i128 div lge$ii sltu"
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'xor',
                                            operands => [ $t_lo_ge, $i_one ],
                                            comment  => "i128 div lge$ii not"
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
                                            opcode   => 'mv',
                                            operands => [ $t_cond, $t_hi_gt ],
                                            comment  => "i128 div cond$ii save"
                                        )
                                    );

                                    # neg_cond = -cond
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
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
                                            opcode   => 'mv',
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

                                    # borrow = r_lo < masked_d_lo
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $t_bor, $r_lo ],
                                            comment  => "i128 div bor$ii load"
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'sltu',
                                            operands => [ $t_bor, $t_mdl ],
                                            comment  => "i128 div bor$ii sltu"
                                        )
                                    );

                                    # r_lo -= masked_d_lo
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
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
                                            opcode   => 'mv',
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
                                            opcode   => 'mv',
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
                                            opcode   => 'mv',
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
                                                opcode   => 'mv',
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
                                                opcode   => 'mv',
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

                                # ---- signed i128 div/rem: apply sign to quotient and remainder ----
                                my $sign_q_tmp = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_sqt',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $mask_q = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_mskq',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $sign_q_tmp, $sign_d ] ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'xor',
                                        operands => [ $sign_q_tmp, $sign_v ],
                                        comment  => 'i128 q sign = d ^ v'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $mask_q, $imm->(0) ],
                                        comment  => 'i128 mask q=0'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sub',
                                        operands => [ $mask_q, $sign_q_tmp ],
                                        comment  => 'i128 mask q=-sign'
                                    )
                                );
                                $apply_mask128->( $inst->name . '_aq', $q_lo, $q_hi, $mask_q );
                                my $mask_r = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_mskr',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $mask_r, $imm->(0) ],
                                        comment  => 'i128 mask r=0'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sub',
                                        operands => [ $mask_r, $sign_d ],
                                        comment  => 'i128 mask r=-sign'
                                    )
                                );
                                $apply_mask128->( $inst->name . '_ar', $r_lo, $r_hi, $mask_r );

                                # ---- end signed handling ----
                                my $out_lo = $opcode eq 'div' ? $q_lo : $r_lo;
                                my $out_hi = $opcode eq 'div' ? $q_hi : $r_hi;
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $lo_dst, $out_lo ],
                                        comment  => 'i128 div store lo'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $hi_dst, $out_hi ],
                                        comment  => 'i128 div store hi'
                                    )
                                );
                            }
                            else {
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
                                my ( $lo_lhs, $hi_lhs ) = $self->_split_i128($lhs);
                                my ( $lo_rhs, $hi_rhs ) = $self->_split_i128($rhs);
                                my $tmp = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_tmp',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );

                                # lo part
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $lo_dst, $lo_lhs ],
                                        comment  => 'i128 load lo ' . ( $lhs->name || $lhs->value )
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $tmp, $lo_dst ],
                                        comment  => 'i128 save lo_lhs'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => $opcode,
                                        operands => [ $lo_dst, $lo_rhs ],
                                        comment  => 'i128 ' . $opcode . ' lo'
                                    )
                                );
                                if ( $opcode eq 'add' ) {
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'sltu',
                                            operands => [ $tmp, $lo_dst, $tmp ],
                                            comment  => 'i128 carry'
                                        )
                                    );
                                }
                                elsif ( $opcode eq 'sub' ) {
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'sltu',
                                            operands => [ $tmp, $tmp, $lo_dst ],
                                            comment  => 'i128 borrow'
                                        )
                                    );
                                }

                                # hi part
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $hi_dst, $hi_lhs ],
                                        comment  => 'i128 load hi ' . ( $lhs->name || $lhs->value )
                                    )
                                );
                                if ( $opcode eq 'add' || $opcode eq 'sub' ) {
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => $opcode,
                                            operands => [ $hi_dst, $hi_rhs ],
                                            comment  => 'i128 ' . $opcode . ' hi'
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => $opcode,
                                            operands => [ $hi_dst, $tmp ],
                                            comment  => 'i128 ' . $opcode . ' carry'
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
                                    opcode   => 'divu',
                                    operands => [ $dst, $self->_lower_opnd($rhs) ],
                                    comment  => 'divu'
                                )
                            );
                        }
                        elsif ( $opcode eq 'rem' ) {
                            my $tmp
                                = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '_rem', type => $inst->type );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $tmp, $self->_lower_opnd($lhs) ],
                                    comment  => 'load ' . ( $lhs->name || $lhs->value ) . ' (rem tmp)'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'divu',
                                    operands => [ $tmp, $self->_lower_opnd($rhs) ],
                                    comment  => 'divu (rem)'
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
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sub', operands => [ $dst, $tmp ], comment => 'sub (rem)' ) );
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
                elsif ( $opcode eq 'neg' || $opcode eq 'abs' || $opcode eq 'sqrt' || $opcode eq 'min' || $opcode eq 'max' ) {
                    my @ops = $inst->operands->@*;
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    if ( $inst->type && $inst->type->kind eq 'float' ) {
                        my $src = $self->_materialize( $mbb, $ops[0] );
                        if ( $opcode eq 'min' || $opcode eq 'max' ) {
                            my $src2 = $self->_materialize( $mbb, $ops[1] );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => "f$opcode",
                                    operands => [ $dst, $src, $src2 ],
                                    comment  => "f$opcode"
                                )
                            );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => "f$opcode",
                                    operands => [ $dst, $src ],
                                    comment  => "f$opcode"
                                )
                            );
                        }
                    }
                    else {
                        # Integer neg/abs/etc. (not strictly needed for the float task but good for completeness if we can)
                        # For now just skip if not float as we don't have them in IR yet for int
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
                    my $cond = $self->_lower_opnd( $inst->operands->[0] );
                    if ( $cond->kind eq 'imm' ) {
                        state $cond_mat_id = 0;
                        $cond_mat_id++;
                        my $tmp_name  = '%cond_mat_' . $cond_mat_id;
                        my $cond_type = $inst->operands->[0]->type;
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mv',
                                operands =>
                                    [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $tmp_name, type => $cond_type ), $cond ],
                                comment => 'materialize cond_br condition'
                            )
                        );
                        $cond = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $tmp_name, type => $cond_type );
                    }
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'bne',
                            operands => [ $cond, Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->true_block->name ) ],
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
                    my $ptr = $inst->operands->[0];
                    if ( $inst->type && $inst->type->kind eq 'int' && $inst->type->bits == 128 ) {
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
                        my $lo_mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $ptr->name, disp => 0 },
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        my $hi_mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $ptr->name, disp => 8 },
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'load',
                                operands => [ $lo_dst, $lo_mem ],
                                comment  => 'i128 load lo'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'load',
                                operands => [ $hi_dst, $hi_mem ],
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
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                        my $lop = ( $inst->type && $inst->type->kind eq 'float' ) ? 'fload' : 'load';
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => $lop, operands => [ $dst, $mem ], comment => $lop ) );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Store') ) {
                    my ( $val, $ptr ) = $inst->operands->@*;
                    if ( $val->type && $val->type->kind eq 'int' && $val->type->bits == 128 ) {
                        my ( $lo_val, $hi_val ) = $self->_split_i128($val);
                        my $lo_mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $ptr->name, disp => 0 },
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        my $hi_mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $ptr->name, disp => 8 },
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => ( $lo_val->kind eq 'imm' ? 'store_imm' : 'store' ),
                                operands => [ $lo_mem, $lo_val ],
                                comment  => 'i128 store lo'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => ( $hi_val->kind eq 'imm' ? 'store_imm' : 'store' ),
                                operands => [ $hi_mem, $hi_val ],
                                comment  => 'i128 store hi'
                            )
                        );
                    }
                    else {
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => $ptr->name, disp => 0 },
                            type => $val->type );
                        if ( $val->type && $val->type->kind eq 'float' ) {
                            my $src = $val->isa('Brocken::Lindsay::IR::Constant') ? $self->_materialize( $mbb, $val ) : $self->_lower_opnd($val);
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'fstore', operands => [ $mem, $src ], comment => 'fstore' ) );
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
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Box') ) {
                    my $val  = $inst->operands->[0];
                    my $size = 16;
                    my $dyn  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'alloca',
                            operands => [ $dyn, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $size ) ],
                            comment  => 'box: alloca 16'
                        )
                    );
                    my $payload_mem
                        = Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => $inst->name, disp => 0 }, type => $val->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => ( $val->isa('Brocken::Lindsay::IR::Constant') ? 'store_imm' : 'store' ),
                            operands => [ $payload_mem, $self->_lower_opnd($val) ],
                            comment  => 'box: store payload'
                        )
                    );
                    my $tag_mem = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name, disp => 8 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store_imm',
                            operands => [
                                $tag_mem,
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'imm',
                                    value => $self->_type_tag( $val->type ),
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                )
                            ],
                            comment => 'box: store tag'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Unbox') ) {
                    my $dyn = $inst->operands->[0];
                    my $mem
                        = Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => $dyn->name, disp => 0 }, type => $inst->type );
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'load',
                            operands => [ $dst, $mem ],
                            comment  => 'unbox: load payload'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Incref') || $inst->isa('Brocken::Lindsay::IR::Instruction::Decref') ) {
                    my $val       = $inst->operands->[0];
                    my $op_name   = $inst->opcode;
                    my $func_name = 'Brocken::Runtime::' . $op_name;
                    my @arg_regs  = $self->_abi->param_registers->@*;
                    my $reg       = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $arg_regs[0] );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $reg, $self->_lower_opnd($val) ],
                            comment  => "$op_name arg 0"
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'call_func',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => $func_name ) ],
                            comment  => "call \@$func_name"
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

                        # mv dst, ptr; add dst, offset
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mv',
                                operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $ptr->name ) ],
                                comment  => 'gep: mv ptr'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'add',
                                operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $offset ) ],
                                comment  => 'gep: add const ' . $offset
                            )
                        );
                    }
                    else {
                        # mv dst, idx; (shl dst, log2scale); add dst, ptr
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mv',
                                operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $idx->name ) ],
                                comment  => 'gep: mv idx'
                            )
                        );
                        my $log2scale = int( log($scale) / log(2) );
                        if ( $log2scale > 0 ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'shl',
                                    operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $log2scale ) ],
                                    comment  => 'gep: slli ' . $log2scale
                                )
                            );
                        }
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'add',
                                operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $ptr->name ) ],
                                comment  => 'gep: add ptr'
                            )
                        );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ICmp') ) {
                    my ( $lhs, $rhs ) = $inst->operands->@*;
                    my $pred = $inst->predicate;
                    my $dst  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    if ( $lhs->type && $lhs->type->kind eq 'float' ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'fcmp',
                                operands => [ $dst, $self->_materialize( $mbb, $lhs ), $self->_materialize( $mbb, $rhs ) ],
                                comment  => 'fcmp ' . $pred
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
                        my $i_one  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 );
                        my $i_zero = Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 );
                        if ( $pred eq 'eq' || $pred eq 'ne' ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
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
                                    opcode   => 'mv',
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
                                    opcode   => 'sltiu',
                                    operands => [ $dst, $i_one ],
                                    comment  => 'i128 icmp seqz'
                                )
                            );
                            if ( $pred eq 'ne' ) {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'xor',
                                        operands => [ $dst, $i_one ],
                                        comment  => 'i128 icmp ne'
                                    )
                                );
                            }
                        }
                        else {
                            my $signed = ( $pred eq 'slt' || $pred eq 'sgt' || $pred eq 'sle' || $pred eq 'sge' );
                            my $lt_op  = $signed ? 'slt' : 'sltu';
                            my ( $hi_a, $hi_b, $lo_a, $lo_b );
                            if ( $pred eq 'ult' || $pred eq 'slt' || $pred eq 'uge' || $pred eq 'sge' ) {
                                ( $hi_a, $hi_b, $lo_a, $lo_b ) = ( $hi_lhs, $hi_rhs, $lo_lhs, $lo_rhs );
                            }
                            else {
                                ( $hi_a, $hi_b, $lo_a, $lo_b ) = ( $hi_rhs, $hi_lhs, $lo_rhs, $lo_lhs );
                            }
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $t0, $hi_a ], comment => 'i128 icmp hi' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $lt_op,
                                    operands => [ $t0, $hi_b ],
                                    comment  => 'i128 icmp hi_' . $lt_op
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $t1, $hi_a ],
                                    comment  => 'i128 icmp hi_eq'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'xor',
                                    operands => [ $t1, $hi_b ],
                                    comment  => 'i128 icmp hi_xor'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'sltiu',
                                    operands => [ $t1, $i_one ],
                                    comment  => 'i128 icmp hi_eq'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $t2, $lo_a ], comment => 'i128 icmp lo' )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'sltu',
                                    operands => [ $t2, $lo_b ],
                                    comment  => 'i128 icmp lo_lt'
                                )
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

                            if ( $pred eq 'ule' || $pred eq 'uge' || $pred eq 'sle' || $pred eq 'sge' ) {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'xor',
                                        operands => [ $t0, $i_one ],
                                        comment  => 'i128 icmp ' . $pred
                                    )
                                );
                            }
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $dst, $t0 ],
                                    comment  => 'i128 icmp store'
                                )
                            );
                        }
                    }
                    elsif ( $pred eq 'eq' || $pred eq 'ne' ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mv',
                                operands => [ $dst, $self->_lower_opnd($lhs) ],
                                comment  => 'icmp ' . $pred . ': mv lhs'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'xor',
                                operands => [ $dst, $self->_lower_opnd($rhs) ],
                                comment  => 'icmp ' . $pred . ': xor rhs'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'sltiu',
                                operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ],
                                comment  => 'seqz'
                            )
                        );
                        if ( $pred eq 'ne' ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'xor',
                                    operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ],
                                    comment  => 'xori 1'
                                )
                            );
                        }
                    }
                    elsif ( $pred eq 'ult' || $pred eq 'ugt' || $pred eq 'ule' || $pred eq 'uge' ) {

                        # ult/ugt/ule/uge: sltu rd, rs1, rs2
                        if ( $pred eq 'ugt' || $pred eq 'ule' ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $dst, $self->_lower_opnd($rhs) ],
                                    comment  => 'icmp ' . $pred . ': mv rhs'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'sltu',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'icmp ' . $pred . ': sltu'
                                )
                            );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'icmp ' . $pred . ': mv lhs'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'sltu',
                                    operands => [ $dst, $self->_lower_opnd($rhs) ],
                                    comment  => 'icmp ' . $pred . ': sltu'
                                )
                            );
                        }
                        if ( $pred eq 'ule' || $pred eq 'uge' ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'xor',
                                    operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ],
                                    comment  => 'xori 1'
                                )
                            );
                        }
                    }
                    else {
                        # slt/sgt/sle/sge: slt rd, rs1, rs2
                        if ( $pred eq 'sgt' || $pred eq 'sle' ) {

                            # slt dst, rhs, lhs  ->  mv dst, rhs; slt dst, lhs
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $dst, $self->_lower_opnd($rhs) ],
                                    comment  => 'icmp ' . $pred . ': mv rhs'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'slt',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'icmp ' . $pred . ': slt'
                                )
                            );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'icmp ' . $pred . ': mv lhs'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'slt',
                                    operands => [ $dst, $self->_lower_opnd($rhs) ],
                                    comment  => 'icmp ' . $pred . ': slt'
                                )
                            );
                        }
                        if ( $pred eq 'sle' || $pred eq 'sge' ) {

                            # xori dst, dst, 1
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'xor',
                                    operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ],
                                    comment  => 'xori 1'
                                )
                            );
                        }
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Call') ) {
                    my $callee   = $inst->callee;
                    my @args     = $inst->operands->@*;
                    my $abi      = $self->_abi;
                    my @gp_regs  = $abi->param_registers->@*;
                    my @fp_regs  = $abi->fp_param_registers->@*;
                    my ( $gp_idx, $fp_idx ) = ( 0, 0 );
                    for my $i ( 0 .. $#args ) {
                        my $arg_type = $args[$i]->type;
                        my $is_float = $arg_type && $arg_type->kind eq 'float';
                        my $reg_name = $is_float ? $fp_regs[ $fp_idx++ ] : $gp_regs[ $gp_idx++ ];
                        my $reg      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $reg_name );
                        my $val      = $self->_lower_opnd( $args[$i] );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => $is_float ? 'fmov' : 'mv',
                                operands => [ $reg, $val ],
                                comment  => "arg $i to $reg_name"
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
                                    opcode   => 'mv',
                                    operands => [ $dst, $ret_reg ],
                                    comment  => "retval from " . $abi->return_register
                                )
                            );
                        }
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Ret') ) {
                    if ( $inst->type->kind ne 'void' ) {
                        my $val = $inst->operands->[0];
                        my $abi = $self->_abi;
                        if ( $val->type && $val->type->kind eq 'int' && $val->type->bits == 128 ) {
                            my $ret_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $abi->return_register );
                            my $a1      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'a1' );
                            my ( $lo, $hi ) = $self->_split_i128($val);
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $ret_reg, $lo ],
                                    comment  => '=> ' . $abi->return_register . ' (i128 lo)'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $a1, $hi ],
                                    comment  => '=> a1 (i128 hi)'
                                )
                            );
                        }
                        else {
                            my $ret_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $abi->return_register );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $ret_reg, $self->_lower_opnd($val) ],
                                    comment  => '=> ' . $abi->return_register
                                )
                            );
                        }
                    }
                    $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [], comment => '' ) );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberCreate') ) {
                    my $callee   = $inst->callee;
                    my $stack_sz = 64 * 1024;
                    my $fcb_sz   = 128;     # +8 for resume_pc at offset 120
                    my $stack    = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'virt_reg',
                        value => $inst->name . '.stk',
                        type  => Brocken::Lindsay::IR::Type::ptr()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'alloca',
                            operands => [
                                $stack,
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'imm',
                                    value => $stack_sz,
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                )
                            ],
                            comment => 'fiber stack'
                        )
                    );
                    my $fptr = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'virt_reg',
                        value => $inst->name . '.fptr',
                        type  => Brocken::Lindsay::IR::Type::ptr()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'lea_func',
                            operands => [ $fptr, Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => $callee->name ) ],
                            comment  => 'load fiber entry addr'
                        )
                    );
                    my $fcb = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'virt_reg',
                        value => $inst->name . '.fcb',
                        type  => Brocken::Lindsay::IR::Type::ptr()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'alloca',
                            operands => [
                                $fcb,
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'imm',
                                    value => $fcb_sz,
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                )
                            ],
                            comment => 'fiber FCB'
                        )
                    );
                    my $saved_sp = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'virt_reg',
                        value => $inst->name . '.sp',
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $saved_sp, $stack ],
                            comment  => 'saved_sp = stack'
                        )
                    );
                    my $tmp = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'virt_reg',
                        value => $inst->name . '.tmp',
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [
                                $tmp,
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'imm',
                                    value => $stack_sz,
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                )
                            ],
                            comment => 'tmp = stack_sz'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'add',
                            operands => [ $saved_sp, $tmp ],
                            comment  => 'saved_sp += stack_sz'
                        )
                    );
                    my $fcb_sp_field = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name . '.fcb', disp => 104 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [ $fcb_sp_field, $saved_sp ],
                            comment  => 'FCB.saved_sp'
                        )
                    );
                    # Zero out ra so entry fn crashes cleanly instead of infinite loop
                    my $fcb_ra_field = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name . '.fcb', disp => 96 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store_imm',
                            operands => [ $fcb_ra_field, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => Brocken::Lindsay::IR::Type::i64() ) ],
                            comment  => 'FCB.ra = 0 (crash on ret)'
                        )
                    );

                    # Store entry function address in FCB.resume_pc (offset 120)
                    my $fcb_resume_field = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name . '.fcb', disp => 120 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [ $fcb_resume_field, $fptr ],
                            comment  => 'FCB.resume_pc = entry addr'
                        )
                    );
                    my $fcb_self_field = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name . '.fcb', disp => 88 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [ $fcb_self_field, $fcb ],
                            comment  => 'FCB.self = FCB addr'
                        )
                    );
                    my $fcb_parent_field = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name . '.fcb', disp => 112 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    my $fiber_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 's11' );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [ $fcb_parent_field, $fiber_reg ],
                            comment  => 'FCB.parent = current fiber'
                        )
                    );
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mv',
                            operands => [ $dst, $fcb ],
                            comment  => 'fiber_create result = FCB'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberTransfer') ) {
                    my ( $fiber, $val ) = $inst->operands->@*;
                    my $fiber_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 's11' );
                    my $ret_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'a0' );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mv',
                            operands => [ $ret_reg, $self->_lower_opnd($val) ],
                            comment  => 'transfer value'
                        )
                    );

                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'ctx_swap',
                            operands => [ $fiber_reg, $self->_lower_opnd($fiber) ],
                            comment  => 'swap to target FCB'
                        )
                    );
                    if ( defined $inst->name ) {
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mv',
                                operands => [ $dst, $ret_reg ],
                                comment  => 'transfer result'
                            )
                        );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberYield') ) {
                    my ($val) = $inst->operands->@*;
                    my $fiber_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 's11' );
                    my $ptr       = Brocken::Lindsay::IR::Type::ptr();
                    my $ret_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'a0' );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mv',
                            operands => [ $ret_reg, $self->_lower_opnd($val) ],
                            comment  => 'yield value'
                        )
                    );
                    my $parent_tmp = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'virt_reg',
                        value => $inst->name . '.parent',
                        type  => $ptr
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'load',
                            operands => [
                                $parent_tmp,
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'mem',
                                    value => { base => 's11', disp => 112 },
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                )
                            ],
                            comment => 'load parent FCB from current FCB'
                        )
                    );

                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'ctx_swap',
                            operands => [ $fiber_reg, $parent_tmp ],
                            comment  => 'swap to parent FCB'
                        )
                    );

                    if ( defined $inst->name ) {
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $dst, $ret_reg ], comment => 'yield result' )
                        );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberId') ) {
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mv',
                            operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $inst->type ) ],
                            comment  => 'fiber_id = 0'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberPin') ) {
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FrameAddr') ) {
                    my $dst    = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    my $fp_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $self->_abi->frame_reg );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $dst, $fp_reg ], comment => "frame_addr" ) );
                }
            }
            $mf->add_block($mbb);
        }
        $mf->compute_cfg;
        return $mf;
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
                    opcode   => 'mv',
                    operands => [ $gp, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $bit_pattern, type => $gp_type ) ],
                    comment  => 'fmc: bit pattern'
                )
            );
            $mbb->add_instruction(
                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'fmov_gp2f', operands => [ $fp, $gp ], comment => 'fmc: gp->fp' ) );
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

    method _type_tag($type) {
        return 1 if $type->kind eq 'int' && $type->bits <= 32;
        return 2 if $type->kind eq 'int' && $type->bits == 64;
        return 6 if $type->kind eq 'int' && $type->bits == 128;
        return 3 if $type->kind eq 'float';
        return 4 if $type->kind eq 'ptr';
        return 5 if $type->kind eq 'dynamic';
        return 0;
    }
}

# ---------------------------------------------------------------------------
# Lowerer: Lindsay IR -> Machine IR (Wasm)
1;
