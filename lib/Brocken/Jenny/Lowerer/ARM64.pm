use v5.42;
use feature qw[class];
no warnings qw[portable];
no warnings qw[experimental::class];
use Brocken::Jenny::MIR;

class Brocken::Jenny::Lowerer::ARM64 {
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
                my $last = $#{ $ir_func->params };
                for ( my $i = 0; $i <= $last; $i++ ) {
                    my $param    = $ir_func->params->[$i];
                    my $is_float = $param->type && $param->type->kind eq 'float';
                    my $is_i128  = !$is_float   && $param->type && $param->type->kind eq 'int' && $param->type->bits == 128;
                    if ($is_i128) {
                        my $lo_reg_name = $gp_regs[ $gp_idx++ ];
                        my $hi_reg_name = $gp_regs[ $gp_idx++ ];
                        my $lo_reg      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $lo_reg_name );
                        my $hi_reg      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $hi_reg_name );
                        my $lo_dst      = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $param->name . '_lo',
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        my $hi_dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $param->name . '_hi',
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ $lo_dst, $lo_reg ],
                                comment  => "param $i lo from $lo_reg_name"
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ $hi_dst, $hi_reg ],
                                comment  => "param $i hi from $hi_reg_name"
                            )
                        );
                    }
                    else {
                        my $reg_name = $is_float ? $fp_regs[ $fp_idx++ ] : $gp_regs[ $gp_idx++ ];
                        my $reg      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $reg_name );
                        my $dst      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $param->name, type => $param->type );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => $is_float ? 'fmov' : 'mov',
                                operands => [ $dst, $reg ],
                                comment  => "param $i from " . $reg_name
                            )
                        );
                    }
                }
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
                                $opcode eq 'rem'  ||
                                $opcode eq 'udiv' ||
                                $opcode eq 'urem' ||
                                $opcode eq 'min'  ||
                                $opcode eq 'max' )
                        ) {
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
                            my $lo_tmp = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_t',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            if ( $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' ) {
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
                                        opcode   => 'umulh',
                                        operands => [ $hi_dst, $lo_rhs ],
                                        comment  => 'i128 mul hi = umulh(a_lo, b_lo)'
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
                            elsif ( $opcode eq 'add' ) {
                                my $temp = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_t',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $carry = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_c',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my ( $lo_rhs, $hi_rhs ) = $self->_split_i128($rhs);
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $temp, $lo_lhs ],
                                        comment  => 'i128 save lhs_lo for carry'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $lo_dst, $lo_lhs ],
                                        comment  => 'i128 load lo ' . ( $lhs->name || $lhs->value )
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'add',
                                        operands => [ $lo_dst, $lo_rhs ],
                                        comment  => 'i128 add lo'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $carry, $lo_dst ],
                                        comment  => 'i128 carry = lo_result'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sltu',
                                        operands => [ $carry, $temp ],
                                        comment  => 'i128 carry = (lo_result < lhs_lo)'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $hi_dst, $hi_lhs ],
                                        comment  => 'i128 load hi ' . ( $lhs->name || $lhs->value )
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'add',
                                        operands => [ $hi_dst, $hi_rhs ],
                                        comment  => 'i128 add hi'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'add',
                                        operands => [ $hi_dst, $carry ],
                                        comment  => 'i128 add hi + carry'
                                    )
                                );
                            }
                            elsif ( $opcode eq 'sub' ) {
                                my $temp = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_t',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $borrow = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_b',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my ( $lo_rhs, $hi_rhs ) = $self->_split_i128($rhs);
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
                                            comment  => 'i128 sub rhs lo'
                                        )
                                    );
                                    $lo_rhs = $r;
                                }
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $temp, $lo_lhs ],
                                        comment  => 'i128 save lhs_lo for borrow'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $lo_dst, $lo_lhs ],
                                        comment  => 'i128 load lo ' . ( $lhs->name || $lhs->value )
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sub',
                                        operands => [ $lo_dst, $lo_rhs ],
                                        comment  => 'i128 sub lo'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $borrow, $temp ],
                                        comment  => 'i128 borrow = lhs_lo'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sltu',
                                        operands => [ $borrow, $lo_rhs ],
                                        comment  => 'i128 borrow = (lhs_lo < rhs_lo)'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $hi_dst, $hi_lhs ],
                                        comment  => 'i128 load hi ' . ( $lhs->name || $lhs->value )
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sub',
                                        operands => [ $hi_dst, $hi_rhs ],
                                        comment  => 'i128 sub hi'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sub',
                                        operands => [ $hi_dst, $borrow ],
                                        comment  => 'i128 sub hi - borrow'
                                    )
                                );
                            }
                            elsif ( $opcode eq 'div' || $opcode eq 'rem' || $opcode eq 'udiv' || $opcode eq 'urem' ) {
                                my ( $lo_lhs, $hi_lhs ) = $self->_split_i128($lhs);
                                my ( $lo_rhs, $hi_rhs ) = $self->_split_i128($rhs);
                                my $fast_path;
                                if ( $lo_rhs->kind eq 'imm' && $hi_rhs->kind eq 'imm' ) {
                                    $fast_path = $hi_rhs->value == 0;
                                    if ( !$fast_path && $hi_rhs->value < 0 ) {
                                        $fast_path = $lo_rhs->value != 0;
                                    }
                                }
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
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'cmp',
                                            operands => [ $tmp, $mask ],
                                            comment  => 'mask128 borrow'
                                        )
                                    );
                                    $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cset_cc', operands => [$bor] ) );
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
                                if ($fast_path) {

                                    # q_hi = hi_lhs / lo_rhs  (64-bit native udiv)
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $q_hi, $hi_lhs ],
                                            comment  => 'i128 div fast q_hi mv'
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'udiv',
                                            operands => [ $q_hi, $lo_rhs ],
                                            comment  => 'i128 div fast q_hi = hi/lo'
                                        )
                                    );

                                    # r_hi = hi_lhs - q_hi * lo_rhs (remainder)
                                    my $frem = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_fre',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $frem, $q_hi ],
                                            comment  => 'i128 div fast frem mv'
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mul',
                                            operands => [ $frem, $lo_rhs ],
                                            comment  => 'i128 div fast frem mul'
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $r_hi, $hi_lhs ],
                                            comment  => 'i128 div fast r_hi mv'
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'sub',
                                            operands => [ $r_hi, $frem ],
                                            comment  => 'i128 div fast r_hi = hi - q*lo'
                                        )
                                    );

                                    # 64-iteration MIR loop for q_lo and final remainder
                                    my $fcnt = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_fcn',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    my $fone = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_fon',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $fone, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ],
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $fcnt, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 64 ) ],
                                            comment  => 'i128 div fast counter=64'
                                        )
                                    );
                                    my $flbl = Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->name . '_flp' );
                                    $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'label', operands => [$flbl], ) );

                                    # cnt--
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'sub',
                                            operands => [ $fcnt, $fone ],
                                            comment  => 'i128 div fast cnt--'
                                        )
                                    );

                                    # bit = (lo_lhs >> cnt) & 1
                                    my $fbit = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_fbt',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $fbit, $lo_lhs ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'lshr', operands => [ $fbit, $fcnt ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'and', operands => [ $fbit, $fone ], ) );

                                    # carry = r_lo >> 63
                                    my $fcarry = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_fcy',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $fcarry, $r_lo ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'lshr',
                                            operands => [ $fcarry, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 63 ) ],
                                        )
                                    );

                                    # r_lo = (r_lo << 1) | bit
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $r_lo, $r_lo ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'shl', operands => [ $r_lo, $fone ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'or', operands => [ $r_lo, $fbit ], ) );

                                    # r_hi = (r_hi << 1) | carry
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $r_hi, $r_hi ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'shl', operands => [ $r_hi, $fone ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'or', operands => [ $r_hi, $fcarry ], ) );

                                    # cond = (r_hi != 0) || (r_lo >= lo_rhs)  [d_hi = 0]
                                    my $flge = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_flg',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $flge, $r_lo ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cmp', operands => [ $flge, $lo_rhs ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cset_cs', operands => [$flge], ) );
                                    my $fcond = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_fcd',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'cmp',
                                            operands => [ $r_hi, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cset_ne', operands => [$fcond], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'or', operands => [ $fcond, $flge ], ) );

                                    # neg_cond = -cond
                                    my $fneg = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_fng',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mv',
                                            operands => [ $fneg, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sub', operands => [ $fneg, $fcond ], ) );

                                    # masked_lo = lo_rhs & neg_cond
                                    my $fmdl = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_fml',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $fmdl, $lo_rhs ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'and', operands => [ $fmdl, $fneg ], ) );

                                    # borrow = r_lo < masked_lo
                                    my $fbor = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_fbr',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $fbor, $r_lo ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cmp', operands => [ $fbor, $fmdl ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cset_cc', operands => [$fbor], ) );

                                    # r_lo -= masked_lo
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $r_lo, $r_lo ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sub', operands => [ $r_lo, $fmdl ], ) );

                                    # r_hi -= borrow  (masked_hi = 0 since d_hi = 0)
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $r_hi, $r_hi ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sub', operands => [ $r_hi, $fbor ], ) );

                                    # qbit = (1 << cnt) & neg_cond
                                    my $fqb = Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'virt_reg',
                                        value => $inst->name . '_fqb',
                                        type  => Brocken::Lindsay::IR::Type::i64()
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $fqb, $fone ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'shl', operands => [ $fqb, $fcnt ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'and', operands => [ $fqb, $fneg ], ) );

                                    # q_lo |= qbit
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $q_lo, $q_lo ], ) );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'or', operands => [ $q_lo, $fqb ], ) );

                                    # Branch back if counter != 0
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'bne',
                                            operands => [ $fcnt, $flbl ],
                                            comment  => 'i128 div fast loop'
                                        )
                                    );
                                }
                                else {
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

                                        # cond_hi_gt = r_hi > d_hi  (unsigned greater than)
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mv',
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
                                                opcode   => 'cset_hi',
                                                operands => [$t_hi_gt],
                                                comment  => "i128 div hgt$ii cset_hi"
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
                                                opcode   => 'cmp',
                                                operands => [ $t_hi_eq, $hi_rhs ],
                                                comment  => "i128 div heq$ii cmp"
                                            )
                                        );
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'cset_eq',
                                                operands => [$t_hi_eq],
                                                comment  => "i128 div heq$ii cset_eq"
                                            )
                                        );

                                        # cond_lo_ge = r_lo >= d_lo  (unsigned, carry set)
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mv',
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
                                                opcode   => 'cset_cs',
                                                operands => [$t_lo_ge],
                                                comment  => "i128 div lge$ii cset_cs"
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

                                        # borrow = r_lo < masked_d_lo  (unsigned less than)
                                        $mbb->add_instruction(
                                            Brocken::Jenny::MIR::MachineInstruction->new(
                                                opcode   => 'mv',
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
                                                opcode   => 'cset_cc',
                                                operands => [$t_bor],
                                                comment  => "i128 div bor$ii cset_cc"
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
                                }
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
                            elsif ( $opcode eq 'min' || $opcode eq 'max' ) {
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
                                my $mask = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_mask',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $zero = Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 );
                                my $one  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => -1,
                                    type => Brocken::Lindsay::IR::Type::i64() );

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
                                            comment  => 'i128 minmax rhs hi'
                                        )
                                    );
                                    $hi_rhs = $r;
                                }
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
                                            comment  => 'i128 minmax rhs lo'
                                        )
                                    );
                                    $lo_rhs = $r;
                                }
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $t0, $hi_lhs ],
                                        comment  => 'i128 minmax hi'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'cmp',
                                        operands => [ $t0, $hi_rhs ],
                                        comment  => 'i128 minmax hi cmp'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $t0, $zero ],
                                        comment  => 'i128 minmax zero'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'cset_lt',
                                        operands => [$t0],
                                        comment  => 'i128 minmax hi_lt'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $t1, $zero ],
                                        comment  => 'i128 minmax zero'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'cset_eq',
                                        operands => [$t1],
                                        comment  => 'i128 minmax hi_eq'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $t2, $lo_lhs ],
                                        comment  => 'i128 minmax lo'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'cmp',
                                        operands => [ $t2, $lo_rhs ],
                                        comment  => 'i128 minmax lo cmp'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $t2, $zero ],
                                        comment  => 'i128 minmax zero'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'cset_cc',
                                        operands => [$t2],
                                        comment  => 'i128 minmax lo_lt'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'and',
                                        operands => [ $t1, $t2 ],
                                        comment  => 'i128 minmax hi_eq&lo_lt'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'or',
                                        operands => [ $t0, $t1 ],
                                        comment  => 'i128 minmax cmp'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $mask, $zero ],
                                        comment  => 'i128 minmax mask=0'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sub',
                                        operands => [ $mask, $t0 ],
                                        comment  => 'i128 minmax mask=-(a<b)'
                                    )
                                );

                                if ( $opcode eq 'max' ) {
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'xor',
                                            operands => [ $mask, $one ],
                                            comment  => 'i128 max invert mask'
                                        )
                                    );
                                }
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $lo_dst, $lo_lhs ],
                                        comment  => 'i128 minmax lo mv'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'xor',
                                        operands => [ $lo_dst, $lo_rhs ],
                                        comment  => 'i128 minmax lo xor'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'and',
                                        operands => [ $lo_dst, $mask ],
                                        comment  => 'i128 minmax lo and'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'xor',
                                        operands => [ $lo_dst, $lo_rhs ],
                                        comment  => 'i128 minmax lo sel'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $hi_dst, $hi_lhs ],
                                        comment  => 'i128 minmax hi mv'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'xor',
                                        operands => [ $hi_dst, $hi_rhs ],
                                        comment  => 'i128 minmax hi xor'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'and',
                                        operands => [ $hi_dst, $mask ],
                                        comment  => 'i128 minmax hi and'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'xor',
                                        operands => [ $hi_dst, $hi_rhs ],
                                        comment  => 'i128 minmax hi sel'
                                    )
                                );
                            }
                            else {
                                my ( $lo_rhs, $hi_rhs ) = $self->_split_i128($rhs);
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
                                            comment  => 'i128 rhs lo'
                                        )
                                    );
                                    $lo_rhs = $r;
                                }
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
                                            comment  => 'i128 rhs hi'
                                        )
                                    );
                                    $hi_rhs = $r;
                                }
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
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
                                        opcode   => 'mv',
                                        operands => [ $hi_dst, $hi_lhs ],
                                        comment  => 'i128 load hi ' . ( $lhs->name || $lhs->value )
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => $opcode,
                                        operands => [ $hi_dst, $hi_rhs ],
                                        comment  => 'i128 ' . $opcode . ' hi'
                                    )
                                );
                            }
                        }
                        elsif ( $opcode eq 'div' || $opcode eq 'udiv' ) {
                            my $rhs_opnd = $self->_lower_opnd($rhs);
                            if ( $rhs_opnd->kind eq 'imm' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '_dv',
                                    type => $inst->type );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $r, $rhs_opnd ],
                                        comment  => 'div rhs'
                                    )
                                );
                                $rhs_opnd = $r;
                            }
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'load ' . ( $lhs->name || $lhs->value )
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'udiv', operands => [ $dst, $rhs_opnd ], comment => 'udiv' )
                            );
                        }
                        elsif ( $opcode eq 'rem' || $opcode eq 'urem' ) {
                            my $rhs_opnd = $self->_lower_opnd($rhs);
                            if ( $rhs_opnd->kind eq 'imm' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '_rm',
                                    type => $inst->type );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $r, $rhs_opnd ],
                                        comment  => 'rem rhs'
                                    )
                                );
                                $rhs_opnd = $r;
                            }
                            my $tmp
                                = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '_rem', type => $inst->type );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $tmp, $self->_lower_opnd($lhs) ],
                                    comment  => 'load ' . ( $lhs->name || $lhs->value ) . ' (rem tmp)'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'udiv',
                                    operands => [ $tmp, $rhs_opnd ],
                                    comment  => 'udiv (rem)'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mul',
                                    operands => [ $tmp, $rhs_opnd ],
                                    comment  => 'mul (rem)'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'load ' . ( $lhs->name || $lhs->value ) . ' (rem)'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sub', operands => [ $dst, $tmp ], comment => 'sub (rem)' ) );
                        }
                        else {
                            my $rhs_opnd = $self->_lower_opnd($rhs);
                            if ( $rhs_opnd->kind eq 'imm' && $opcode ne 'add' && $opcode ne 'sub' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '_r',
                                    type => $inst->type );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mv', operands => [ $r, $rhs_opnd ], comment => 'rhs' ) );
                                $rhs_opnd = $r;
                            }
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'load ' . ( $lhs->name || $lhs->value )
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $opcode,
                                    operands => [ $dst, $rhs_opnd ],
                                    comment  => $opcode
                                )
                            );
                        }
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Zext') ) {
                    my ($val) = $inst->operands->@*;
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'movzx',
                            operands => [ $dst, $self->_lower_opnd($val) ],
                            comment  => 'zext ' . ( $val->name || $val->value )
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Sext') ) {
                    my ($val) = $inst->operands->@*;
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'movsx',
                            operands => [ $dst, $self->_lower_opnd($val) ],
                            comment  => 'sext ' . ( $val->name || $val->value )
                        )
                    );
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
                        my $mop = $opcode eq 'neg' ? 'fneg' : ( $opcode eq 'abs' ? 'fabs' : 'fsqrt' );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => $mop, operands => [ $dst, $dst ], comment => $mop ) );
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
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Alloca') ) {
                    my $dst  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    my $size = ( $inst->allocated_type->bits / 8 ) * ( $inst->count ? $inst->count->value : 1 );
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
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                        my $lop = ( $inst->type && $inst->type->kind eq 'float' ) ? 'fload' : 'load';
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => $lop, operands => [ $dst, $mem ], comment => $lop ) );
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

                    # mv dst, ptr  (copy base pointer to result)
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $ptr->name ) ],
                            comment  => 'gep: mv ptr'
                        )
                    );
                    if ( $idx->isa('Brocken::Lindsay::IR::Constant') ) {
                        my $offset = $idx->value * $scale;
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'add',
                                operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $offset ) ],
                                comment  => 'gep: add const ' . $offset
                            )
                        );
                    }
                    else {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'add',
                                operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $idx->name ) ],
                                comment  => 'gep: add index'
                            )
                        );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ICmp') ) {
                    my ( $lhs, $rhs ) = $inst->operands->@*;
                    my $pred = $inst->predicate;
                    my %cond = (
                        eq  => 'cset_eq',
                        ne  => 'cset_ne',
                        slt => 'cset_lt',
                        sgt => 'cset_gt',
                        sle => 'cset_le',
                        sge => 'cset_ge',
                        ult => 'cset_cc',
                        ugt => 'cset_hi',
                        ule => 'cset_ls',
                        uge => 'cset_cs'
                    );
                    my %fcond = ( eq => 'cset_eq', ne => 'cset_ne', lt => 'cset_lt', le => 'cset_le', gt => 'cset_gt', ge => 'cset_ge' );
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
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                comment  => 'zero dst'
                            )
                        );
                        my $tmp = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $inst->name . '_pf',
                            type  => Brocken::Lindsay::IR::Type::i1()
                        );
                        if ( $pred eq 'ne' ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cset_vs', operands => [$dst], comment => 'unordered' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cset_ne', operands => [$tmp], comment => 'ne' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'or',
                                    operands => [ $dst, $tmp ],
                                    comment  => 'unordered OR ne'
                                )
                            );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cset_vc', operands => [$dst], comment => 'ordered' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => $fcond{$pred}, operands => [$tmp], comment => $pred ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'and',
                                    operands => [ $dst, $tmp ],
                                    comment  => 'ordered AND condition'
                                )
                            );
                        }
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
                                        comment  => 'i128 icmp rhs lo'
                                    )
                                );
                                $lo_rhs = $r;
                            }
                            if ( $hi_rhs->kind eq 'imm' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_rh',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $r, $hi_rhs ],
                                        comment  => 'i128 icmp rhs hi'
                                    )
                                );
                                $hi_rhs = $r;
                            }
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
                                    opcode   => 'cmp',
                                    operands => [ $t0, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp test'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => ( $pred eq 'eq' ? 'cset_eq' : 'cset_ne' ),
                                    operands => [$dst],
                                    comment  => 'i128 icmp ' . $pred
                                )
                            );
                        }
                        elsif ( $pred eq 'ult' || $pred eq 'slt' ) {
                            my $cset_hi = $pred eq 'ult' ? 'cset_cc' : 'cset_lt';
                            if ( $hi_rhs->kind eq 'imm' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_rh',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $r, $hi_rhs ],
                                        comment  => 'i128 icmp rhs hi'
                                    )
                                );
                                $hi_rhs = $r;
                            }
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
                                        comment  => 'i128 icmp rhs lo'
                                    )
                                );
                                $lo_rhs = $r;
                            }
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
                                    opcode   => $cset_hi,
                                    operands => [$t0],
                                    comment  => 'i128 icmp hi_' . $pred
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cset_eq', operands => [$t1], comment => 'i128 icmp hi_eq' )
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
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cset_cc', operands => [$t2], comment => 'i128 icmp lo_lt' )
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
                            my $cset_hi = $pred eq 'ugt' ? 'cset_cc' : 'cset_lt';
                            if ( $hi_lhs->kind eq 'imm' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_lh',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $r, $hi_lhs ],
                                        comment  => 'i128 icmp lhs hi'
                                    )
                                );
                                $hi_lhs = $r;
                            }
                            if ( $lo_lhs->kind eq 'imm' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_ll',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $r, $lo_lhs ],
                                        comment  => 'i128 icmp lhs lo'
                                    )
                                );
                                $lo_lhs = $r;
                            }
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
                                    opcode   => $cset_hi,
                                    operands => [$t0],
                                    comment  => 'i128 icmp hi_' . $pred
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cset_eq', operands => [$t1], comment => 'i128 icmp hi_eq' )
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
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cset_cc', operands => [$t2], comment => 'i128 icmp lo_lt' )
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
                            my ( $cset_hi, $swap )
                                = $pred eq 'ule' ? ( 'cset_cc', 1 ) :
                                $pred eq 'uge'   ? ( 'cset_cc', 0 ) :
                                $pred eq 'sle'   ? ( 'cset_lt', 1 ) :
                                ( 'cset_lt', 0 );
                            my ( $hi_a, $hi_b, $lo_a, $lo_b )
                                = $swap ? ( $hi_rhs, $hi_lhs, $lo_rhs, $lo_lhs ) : ( $hi_lhs, $hi_rhs, $lo_lhs, $lo_rhs );
                            if ( $hi_b->kind eq 'imm' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_bh',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $r, $hi_b ],
                                        comment  => 'i128 icmp hi rhs'
                                    )
                                );
                                $hi_b = $r;
                            }
                            if ( $lo_b->kind eq 'imm' ) {
                                my $r = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_bl',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $r, $lo_b ],
                                        comment  => 'i128 icmp lo rhs'
                                    )
                                );
                                $lo_b = $r;
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
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => $cset_hi, operands => [$t0], comment => 'i128 icmp hi_lt' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cset_eq', operands => [$t1], comment => 'i128 icmp hi_eq' )
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
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'cset_cc', operands => [$t2], comment => 'i128 icmp lo_lt' )
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
                                    opcode   => 'cset_eq',
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
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => $cond{$pred}, operands => [$dst], comment => $pred ) );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Call') ) {
                    my $callee  = $inst->callee;
                    my @args    = $inst->operands->@*;
                    my $abi     = $self->_abi;
                    my @gp_regs = $abi->param_registers->@*;
                    my @fp_regs = $abi->fp_param_registers->@*;
                    my ( $gp_idx, $fp_idx ) = ( 0, 0 );
                    for my $i ( 0 .. $#args ) {
                        my $arg_type = $args[$i]->type;
                        my $is_float = $arg_type  && $arg_type->kind eq 'float';
                        my $is_i128  = !$is_float && $arg_type && $arg_type->kind eq 'int' && $arg_type->bits == 128;
                        if ($is_i128) {
                            my $lo_reg_name = $gp_regs[ $gp_idx++ ];
                            my $hi_reg_name = $gp_regs[ $gp_idx++ ];
                            my $lo_reg      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $lo_reg_name );
                            my $hi_reg      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $hi_reg_name );
                            my ( $lo, $hi ) = $self->_split_i128( $args[$i] );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $lo_reg, $lo ],
                                    comment  => "arg $i lo to $lo_reg_name"
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $hi_reg, $hi ],
                                    comment  => "arg $i hi to $hi_reg_name"
                                )
                            );
                        }
                        else {
                            my $reg_name = $is_float ? $fp_regs[ $fp_idx++ ] : $gp_regs[ $gp_idx++ ];
                            my $reg      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $reg_name );
                            my $val      = $self->_lower_opnd( $args[$i] );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $is_float ? 'fmov' : 'mov',
                                    operands => [ $reg, $val ],
                                    comment  => "arg $i to $reg_name"
                                )
                            );
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
                        my $dst     = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                        my $is_i128 = $inst->type && $inst->type->kind eq 'int' && $inst->type->bits == 128;
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
                        elsif ($is_i128) {
                            my $x0 = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $abi->return_register );
                            my $x1 = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x1' );
                            my ( $lo, $hi ) = $self->_split_i128($inst);
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $lo, $x0 ],
                                    comment  => "retval i128 lo from x0"
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $hi, $x1 ],
                                    comment  => "retval i128 hi from x1"
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
                                my $ret_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $abi->return_register );
                                my $x1      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x1' );
                                my ( $lo, $hi ) = $self->_split_i128($val);
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $ret_reg, $lo ],
                                        comment  => '=> ' . $abi->return_register . ' (i128 lo)'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $x1, $hi ],
                                        comment  => '=> x1 (i128 hi)'
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
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberCreate') ) {
                    my $callee   = $inst->callee;
                    my $stack_sz = 64 * 1024;
                    my $fcb_sz   = 128;                                        # +8 os_thread at offset 120
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
                        value => { base => $inst->name . '.fcb', disp => 96 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [ $fcb_sp_field, $saved_sp ],
                            comment  => 'FCB.saved_sp'
                        )
                    );

                    # Zero out x30 so entry fn crashes cleanly instead of infinite loop
                    my $fcb_lr_field = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name . '.fcb', disp => 88 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store_imm',
                            operands => [
                                $fcb_lr_field,
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => Brocken::Lindsay::IR::Type::i64() )
                            ],
                            comment => 'FCB.x30 = 0 (crash on ret)'
                        )
                    );

                    # Store entry function address in FCB.resume_pc (offset 112)
                    my $fcb_resume_field = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name . '.fcb', disp => 112 },
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
                        value => { base => $inst->name . '.fcb', disp => 72 },
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
                        value => { base => $inst->name . '.fcb', disp => 104 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    my $fiber_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x28' );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [ $fcb_parent_field, $fiber_reg ],
                            comment  => 'FCB.parent = current fiber'
                        )
                    );

                    # Copy os_thread pointer from current fiber (x28) to new FCB[120]
                    my $fcb_os_thread = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name . '.fcb', disp => 120 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [ $fcb_os_thread, $fiber_reg ],
                            comment  => 'FCB.os_thread = current fiber os_thread'
                        )
                    );
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $dst, $fcb ],
                            comment  => 'fiber_create result = FCB'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberTransfer') ) {
                    my ( $fiber, $val ) = $inst->operands->@*;
                    my $fiber_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x28' );
                    my $ret_reg   = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x0' );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
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
                                opcode   => 'mov',
                                operands => [ $dst, $ret_reg ],
                                comment  => 'transfer result'
                            )
                        );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberYield') ) {
                    my ($val)     = $inst->operands->@*;
                    my $fiber_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x28' );
                    my $ptr       = Brocken::Lindsay::IR::Type::ptr();
                    my $ret_reg   = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x0' );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $ret_reg, $self->_lower_opnd($val) ],
                            comment  => 'yield value'
                        )
                    );
                    my $parent_tmp = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '.parent', type => $ptr );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'load',
                            operands => [
                                $parent_tmp,
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'mem',
                                    value => { base => 'x28', disp => 104 },
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
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ $dst, $ret_reg ],
                                comment  => 'yield result'
                            )
                        );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberId') ) {
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $inst->type ) ],
                            comment  => 'fiber_id = 0'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberPin') ) {
                    my $i64      = Brocken::Lindsay::IR::Type::i64();
                    my $ptr      = Brocken::Lindsay::IR::Type::ptr();
                    my $inst_tag = 'fp' . ( $inst->name // int( $inst + 0 ) );
                    my ( $fiber, $mask_opnd ) = $inst->operands->@*;
                    if ( $platform->is_linux || $platform->is_freebsd ) {
                        my $mask_slot = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst_tag . '.msk', type => $ptr );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'alloca',
                                operands => [ $mask_slot, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 8, type => $i64 ) ],
                                comment  => 'mask slot'
                            )
                        );
                        my $mask_lowered = $self->_lower_opnd($mask_opnd);
                        my $store_op     = $mask_lowered->kind eq 'imm' ? 'store_imm' : 'store';
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => $store_op,
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'mem',
                                        value => { base => $inst_tag . '.msk', disp => 0 },
                                        type  => $i64
                                    ),
                                    $mask_lowered
                                ],
                                comment => 'store mask'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x0' ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 )
                                ],
                                comment => 'pid = 0 (current thread)'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x1' ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 8, type => $i64 )
                                ],
                                comment => 'cpusetsize = 8'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x2' ), $mask_slot ],
                                comment  => 'mask ptr'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'call_func',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'sched_setaffinity' ) ],
                                comment  => 'sched_setaffinity'
                            )
                        );
                    }
                    elsif ( $platform->is_dragonflybsd ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode  => 'nop',
                                comment => 'DragonFly uses pthread_setaffinity_np; pin not yet implemented'
                            )
                        );
                    }
                    elsif ( $platform->is_netbsd ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode  => 'nop',
                                comment => 'NetBSD lacks sched_setaffinity; pin not implemented'
                            )
                        );
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::IsolateCreate') ) {
                    my $callee   = $inst->callee;
                    my $stack_sz = 64 * 1024;
                    my $fcb_sz   = 128;
                    my $icb_sz   = 64;
                    my $i64      = Brocken::Lindsay::IR::Type::i64();
                    my $ptr      = Brocken::Lindsay::IR::Type::ptr();
                    my $stack    = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '.stk', type => $ptr );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'alloca',
                            operands => [ $stack, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $stack_sz, type => $i64 ) ],
                            comment  => 'isolate stack'
                        )
                    );
                    my $fptr = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '.fptr', type => $ptr );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'lea_func',
                            operands => [ $fptr, Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => $callee->name ) ],
                            comment  => 'load isolate entry addr'
                        )
                    );
                    my $fcb = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '.fcb', type => $ptr );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'alloca',
                            operands => [ $fcb, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $fcb_sz, type => $i64 ) ],
                            comment  => 'isolate FCB'
                        )
                    );
                    my $saved_sp = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '.sps', type => $i64 );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $saved_sp, $stack ],
                            comment  => 'saved_sp = stack'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'add',
                            operands =>
                                [ $saved_sp, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $stack_sz - 8, type => $i64 ) ],
                            comment => 'saved_sp += stack_sz - 8'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'mem',
                                    value => { base => $inst->name . '.fcb', disp => 96 },
                                    type  => $i64
                                ),
                                $saved_sp
                            ],
                            comment => 'FCB.saved_sp'
                        )
                    );

                    for my $off ( 0, 8, 24, 32, 40, 48, 56, 64, 80, 88, 104 ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'store_imm',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'mem',
                                        value => { base => $inst->name . '.fcb', disp => $off },
                                        type  => $i64
                                    ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 )
                                ],
                                comment => "FCB[$off] = 0"
                            )
                        );
                    }
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'mem',
                                    value => { base => $inst->name . '.fcb', disp => 72 },
                                    type  => $i64
                                ),
                                $fcb
                            ],
                            comment => 'FCB.self = FCB addr'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store_imm',
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'mem',
                                    value => { base => $inst->name . '.fcb', disp => 104 },
                                    type  => $i64
                                ),
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 )
                            ],
                            comment => 'FCB.parent = NULL'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'mem',
                                    value => { base => $inst->name . '.fcb', disp => 112 },
                                    type  => $i64
                                ),
                                $fptr
                            ],
                            comment => 'FCB.resume_pc = entry addr'
                        )
                    );
                    my $icb = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '.icb', type => $ptr );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'alloca',
                            operands => [ $icb, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $icb_sz, type => $i64 ) ],
                            comment  => 'isolate ICB'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store_imm',
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'mem',
                                    value => { base => $inst->name . '.icb', disp => 0 },
                                    type  => $i64
                                ),
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 )
                            ],
                            comment => 'ICB.heap_cursor = NULL'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'mem',
                                    value => { base => $inst->name . '.fcb', disp => 120 },
                                    type  => $i64
                                ),
                                $icb
                            ],
                            comment => 'FCB.os_thread = ICB'
                        )
                    );
                    my $max_args = 6;
                    my @ir_args  = $inst->operands->@*;
                    my $num_args = scalar @ir_args;
                    $num_args = $max_args if $num_args > $max_args;
                    my $arg_size = 16 + 8 * $num_args;
                    my $arg      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '.arg', type => $ptr );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'alloca',
                            operands => [ $arg, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $arg_size, type => $i64 ) ],
                            comment  => "isolate arg {FCB,ICB,$num_args args}"
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'mem',
                                    value => { base => $inst->name . '.arg', disp => 0 },
                                    type  => $ptr
                                ),
                                $fcb
                            ],
                            comment => 'arg.fcb'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'mem',
                                    value => { base => $inst->name . '.arg', disp => 8 },
                                    type  => $ptr
                                ),
                                $icb
                            ],
                            comment => 'arg.icb'
                        )
                    );

                    for my $ai ( 0 .. $num_args - 1 ) {
                        my $av = $self->_lower_opnd( $ir_args[$ai] );
                        my $am = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $inst->name . '.arg', disp => 16 + 8 * $ai },
                            type  => $ptr
                        );
                        my $op = $av->kind eq 'imm' ? 'store_imm' : 'store';
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => $op, operands => [ $am, $av ], comment => "arg[$ai]" ) );
                    }
                    my $tramp = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '.tramp', type => $ptr );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'lea_func',
                            operands => [ $tramp, Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => '_isolate_trampoline' ) ],
                            comment  => 'load trampoline addr'
                        )
                    );
                    my $handle = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '.handle', type => $ptr );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'alloca',
                            operands => [ $handle, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 8, type => $i64 ) ],
                            comment  => 'handle storage'
                        )
                    );
                    if ( $platform->is_windows ) {

                        # CreateThread respects ARM64 ABI: all 6 args in x0-x5
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x0' ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 )
                                ],
                                comment => 'arg1: NULL'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x1' ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 )
                                ],
                                comment => 'arg2: default stack size'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x2' ), $tramp ],
                                comment  => 'arg3: start_routine'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x3' ), $arg ],
                                comment  => 'arg4: arg'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x4' ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 )
                                ],
                                comment => 'arg5: flags = 0'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x5' ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 )
                                ],
                                comment => 'arg6: threadId = NULL'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'call_func',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'CreateThread' ) ],
                                comment  => 'CreateThread'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'store',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'mem',
                                        value => { base => $inst->name . '.handle', disp => 0 },
                                        type  => $i64
                                    ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x0' )
                                ],
                                comment => 'save handle from return value'
                            )
                        );
                    }
                    else {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x0' ), $handle ],
                                comment  => 'arg1: &thread'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x1' ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 )
                                ],
                                comment => 'arg2: NULL attr'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x2' ), $tramp ],
                                comment  => 'arg3: start_routine'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x3' ), $arg ],
                                comment  => 'arg4: arg'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'call_func',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'pthread_create' ) ],
                                comment  => 'pthread_create'
                            )
                        );
                    }
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'load',
                            operands => [
                                $dst,
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'mem',
                                    value => { base => $inst->name . '.handle', disp => 0 },
                                    type  => $i64
                                )
                            ],
                            comment => 'isolate_create result = handle'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::IsolateJoin') ) {
                    my $i64     = Brocken::Lindsay::IR::Type::i64();
                    my $ptr     = Brocken::Lindsay::IR::Type::ptr();
                    my $isolate = $inst->operands->[0];
                    my $reg     = $self->_lower_opnd($isolate);
                    if ( $platform->is_windows ) {
                        my $tag       = $inst->name // 'anon' . int($inst);
                        my $retv_slot = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $tag . '.rv', type => $ptr );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'alloca',
                                operands => [ $retv_slot, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 8, type => $i64 ) ],
                                comment  => 'retval slot'
                            )
                        );
                        my $i32 = Brocken::Lindsay::IR::Type::i32();
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x0' ), $reg ],
                                comment  => 'arg1: handle'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x1' ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0xFFFFFFFF, type => $i32 )
                                ],
                                comment => 'arg2: INFINITE'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'call_func',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'WaitForSingleObject' ) ],
                                comment  => 'WaitForSingleObject'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x0' ), $reg ],
                                comment  => 'arg1: handle'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x1' ), $retv_slot ],
                                comment  => 'arg2: &retval'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'call_func',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'GetExitCodeThread' ) ],
                                comment  => 'GetExitCodeThread'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x0' ), $reg ],
                                comment  => 'arg1: handle'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'call_func',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'CloseHandle' ) ],
                                comment  => 'CloseHandle'
                            )
                        );

                        if ( defined $inst->name ) {
                            my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'load',
                                    operands => [
                                        $dst,
                                        Brocken::Jenny::MIR::MachineOperand->new(
                                            kind  => 'mem',
                                            value => { base => $tag . '.rv', disp => 0 },
                                            type  => $i64
                                        )
                                    ],
                                    comment => 'isolate_join result'
                                )
                            );
                        }
                    }
                    else {
                        my $tag       = $inst->name // 'anon' . int($inst);
                        my $retv_slot = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $tag . '.rv', type => $ptr );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'alloca',
                                operands => [ $retv_slot, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 8, type => $i64 ) ],
                                comment  => 'retval slot'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x0' ), $reg ],
                                comment  => 'arg1: thread handle'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x1' ), $retv_slot ],
                                comment  => 'arg2: &retval'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'call_func',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'pthread_join' ) ],
                                comment  => 'pthread_join'
                            )
                        );
                        if ( defined $inst->name ) {
                            my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'load',
                                    operands => [
                                        $dst,
                                        Brocken::Jenny::MIR::MachineOperand->new(
                                            kind  => 'mem',
                                            value => { base => $tag . '.rv', disp => 0 },
                                            type  => $i64
                                        )
                                    ],
                                    comment => 'isolate_join result'
                                )
                            );
                        }
                    }
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FrameAddr') ) {
                    my $dst    = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                    my $fp_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $self->_abi->frame_reg );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $dst, $fp_reg ], comment => "frame_addr" ) );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ChanCreate') ) {
                    my $i64 = Brocken::Lindsay::IR::Type::i64();
                    my $ptr = Brocken::Lindsay::IR::Type::ptr();
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $ptr );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 ) ],
                            comment  => 'chan_create stub (null ptr)'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ChanSend') ) {

                    # stub -- no-op
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ChanRecv') ) {
                    my $i64 = Brocken::Lindsay::IR::Type::i64();
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $i64 );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 ) ],
                            comment  => 'chan_recv stub (0)'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ChanClose') ) {

                    # stub -- no-op
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ChanTrySend') ) {
                    my $i1  = Brocken::Lindsay::IR::Type::i1();
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $i1 );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i1 ) ],
                            comment  => 'chan_try_send stub (false)'
                        )
                    );
                }
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ChanTryRecv') ) {
                    my $i64 = Brocken::Lindsay::IR::Type::i64();
                    my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $i64 );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 ) ],
                            comment  => 'chan_try_recv stub (0)'
                        )
                    );
                }
            }
            $mf->add_block($mbb);
        }
        $mf->compute_cfg;
        return $mf;
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

# ---------------------------------------------------------------------------
# Lowerer: Lindsay IR -> Machine IR (RISC-V 64)
1;
