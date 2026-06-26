use v5.42;
use feature qw[class];
no warnings qw[portable];
no warnings qw[experimental::class];
use Brocken::Jenny::MIR;
use List::Util qw[min max];

class Brocken::Jenny::Lowerer::X86_64 {
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
                        my $lo_tmp      = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $param->name . '_lo.entry',
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        my $hi_tmp = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $param->name . '_hi.entry',
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ $lo_tmp, $lo_reg ],
                                comment  => "save param $i lo from $lo_reg_name"
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ $hi_tmp, $hi_reg ],
                                comment  => "save param $i hi from $hi_reg_name"
                            )
                        );
                    }
                    else {
                        my $tmp_name = $param->name . '.entry';
                        my $reg_name = $is_float ? $fp_regs[ $fp_idx++ ] : $gp_regs[ $gp_idx++ ];
                        my $reg      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $reg_name );
                        my $tmp      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $tmp_name, type => $param->type );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => $is_float ? 'fmov' : 'mov',
                                operands => [ $tmp, $reg ],
                                comment  => "save param $i from " . $reg_name
                            )
                        );
                    }
                }
                for ( my $i = 0; $i <= $last; $i++ ) {
                    my $param    = $ir_func->params->[$i];
                    my $is_float = $param->type && $param->type->kind eq 'float';
                    my $is_i128  = !$is_float   && $param->type && $param->type->kind eq 'int' && $param->type->bits == 128;
                    if ($is_i128) {
                        my $lo_dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $param->name . '_lo',
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        my $hi_dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $param->name . '_hi',
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        my $lo_tmp = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $param->name . '_lo.entry',
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        my $hi_tmp = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'virt_reg',
                            value => $param->name . '_hi.entry',
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ $lo_dst, $lo_tmp ],
                                comment  => "init param $i lo"
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ $hi_dst, $hi_tmp ],
                                comment  => "init param $i hi"
                            )
                        );
                    }
                    else {
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $param->name, type => $param->type );
                        my $tmp
                            = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $param->name . '.entry', type => $param->type );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => $is_float ? 'fmov' : 'mov',
                                operands => [ $dst, $tmp ],
                                comment  => "init param $i"
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
                            $opcode eq 'rem'  ||
                            $opcode eq 'min'  ||
                            $opcode eq 'max' )
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

                            # materialize constant operands to virt_regs
                            if ( $lo_lhs->kind eq 'imm' ) {
                                my $mlo = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_mlo',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $mhi = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_mhi',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $mlo, $lo_lhs ] ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $mhi, $hi_lhs ] ) );
                                $lo_lhs = $mlo;
                                $hi_lhs = $mhi;
                            }
                            if ( $lo_rhs->kind eq 'imm' ) {
                                my $rmlo = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_rmlo',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                my $rmhi = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'virt_reg',
                                    value => $inst->name . '_rmhi',
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $rmlo, $lo_rhs ] ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $rmhi, $hi_rhs ] ) );
                                $lo_rhs = $rmlo;
                                $hi_rhs = $rmhi;
                            }

                            # ---- signed i128 div/rem: convert inputs to absolute values ----
                            my $imm128        = sub ($v) { Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $v ) };
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
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $tmp, $lo ] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'xor', operands => [ $tmp, $mask ] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sub', operands => [ $tmp, $mask ] ) );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $bor, $imm128->(0) ] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'setb', operands => [$bor] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $lo,  $tmp ] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $tmp, $hi ] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'xor', operands => [ $tmp, $mask ] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sub', operands => [ $tmp, $mask ] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sub', operands => [ $tmp, $bor ] ) );
                                $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $hi,  $tmp ] ) );
                            };

                            # dividend sign + abs
                            my $sign_d = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_sgnd',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $sign_d, $hi_lhs ],
                                    comment  => 'i128 sign d mov'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'lshr',
                                    operands => [ $sign_d, $imm128->(63) ],
                                    comment  => 'i128 sign d shr'
                                )
                            );
                            my $mask_d = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_mskd',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $mask_d, $imm128->(0) ],
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

                            # divisor sign + abs
                            my $sign_v = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_signv',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $sign_v, $hi_rhs ],
                                    comment  => 'i128 sign v mov'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'lshr',
                                    operands => [ $sign_v, $imm128->(63) ],
                                    comment  => 'i128 sign v shr'
                                )
                            );
                            my $mask_v = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'virt_reg',
                                value => $inst->name . '_mskv',
                                type  => Brocken::Lindsay::IR::Type::i64()
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $mask_v, $imm128->(0) ],
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
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $sign_q_tmp, $sign_d ] ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'xor',
                                    operands => [ $sign_q_tmp, $sign_v ],
                                    comment  => 'i128 q sign = d ^ v'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $mask_q, $imm128->(0) ],
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
                                    opcode   => 'mov',
                                    operands => [ $mask_r, $imm128->(0) ],
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
                            my $one
                                = Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => -1, type => Brocken::Lindsay::IR::Type::i64() );

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
                                        opcode   => 'mov',
                                        operands => [ $r, $lo_rhs ],
                                        comment  => 'i128 minmax rhs lo'
                                    )
                                );
                                $lo_rhs = $r;
                            }
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
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
                                    opcode   => 'mov',
                                    operands => [ $t0, $zero ],
                                    comment  => 'i128 minmax zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'setl', operands => [$t0], comment => 'i128 minmax hi_lt' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t1, $zero ],
                                    comment  => 'i128 minmax zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sete', operands => [$t1], comment => 'i128 minmax hi_eq' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
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
                                    opcode   => 'mov',
                                    operands => [ $t2, $zero ],
                                    comment  => 'i128 minmax zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'setb', operands => [$t2], comment => 'i128 minmax lo_lt' ) );
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
                                    opcode   => 'mov',
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
                                    opcode   => 'mov',
                                    operands => [ $lo_dst, $lo_lhs ],
                                    comment  => 'i128 minmax lo mov'
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
                                    opcode   => 'mov',
                                    operands => [ $hi_dst, $hi_lhs ],
                                    comment  => 'i128 minmax hi mov'
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
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sete', operands => [$t1], comment => 'i128 icmp hi_eq' ) );
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
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'setb', operands => [$t2], comment => 'i128 icmp lo_lt' ) );
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
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sete', operands => [$t1], comment => 'i128 icmp hi_eq' ) );
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
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'setb', operands => [$t2], comment => 'i128 icmp lo_lt' ) );
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
                                = $pred eq 'ule' ? ( 'setb', 1 ) : $pred eq 'uge' ? ( 'setb', 0 ) : $pred eq 'sle' ? ( 'setl', 1 ) : ( 'setl', 0 );
                            my ( $hi_a, $hi_b, $lo_a, $lo_b );
                            if ($swap) {
                                ( $hi_a, $hi_b ) = ( $hi_rhs, $hi_lhs );
                                ( $lo_a, $lo_b ) = ( $lo_rhs, $lo_lhs );
                            }
                            else {
                                ( $hi_a, $hi_b ) = ( $hi_lhs, $hi_rhs );
                                ( $lo_a, $lo_b ) = ( $lo_lhs, $lo_rhs );
                            }
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
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t0, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => $set_lt, operands => [$t0], comment => 'i128 icmp hi_lt' ) );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $t1, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0 ) ],
                                    comment  => 'i128 icmp zero'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sete', operands => [$t1], comment => 'i128 icmp hi_eq' ) );
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
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'setb', operands => [$t2], comment => 'i128 icmp lo_lt' ) );
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
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'sete', operands => [$dst], comment => 'i128 icmp ' . $pred )
                            );
                        }
                    }
                    else {
                        my $lhs_op  = $self->_lower_opnd($lhs);
                        my $rhs_op  = $self->_lower_opnd($rhs);
                        my $result  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name, type => $inst->type );
                        my $cmp_lhs = $lhs_op;
                        if ( $lhs_op->kind eq 'imm' ) {
                            my $tmp
                                = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '_lhs', type => $lhs_op->type,
                                );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $tmp, $lhs_op ],
                                    comment  => 'icmp materialize lhs'
                                )
                            );
                            $cmp_lhs = $tmp;
                        }
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'cmp',
                                operands => [ $cmp_lhs, $rhs_op ],
                                comment  => 'icmp ' . $pred
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'set' . $cond{$pred},
                                operands => [$result],
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
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => $ptr->name, disp => 0 },
                            type => $val->type );
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
                                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'fsqrt', operands => [ $dst, $dst ], comment => 'fsqrt' ) );
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
                            my $mask_fp = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $mname . 'f', type => $inst->type );
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
                    my $mem_val
                        = Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => $inst->name, disp => 0 }, type => $val->type );
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
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $tag, type => Brocken::Lindsay::IR::Type::i64() )
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
                    my $callee  = $inst->callee;
                    my @args    = $inst->operands->@*;
                    my $abi     = $self->_abi;
                    my @gp_regs = $abi->param_registers->@*;
                    my @fp_regs = $abi->fp_param_registers->@*;

                    # Pre-compute register assignments for all args
                    my @arg_regs;
                    my ( $gp_idx, $fp_idx ) = ( 0, 0 );
                    for my $i ( 0 .. $#args ) {
                        my $arg_type = $args[$i]->type;
                        my $is_float = $arg_type  && $arg_type->kind eq 'float';
                        my $is_i128  = !$is_float && $arg_type && $arg_type->kind eq 'int' && $arg_type->bits == 128;
                        if ($is_i128) {
                            $arg_regs[$i] = [ $gp_regs[ $gp_idx++ ], $gp_regs[ $gp_idx++ ] ];
                        }
                        else {
                            $arg_regs[$i] = $is_float ? $fp_regs[ $fp_idx++ ] : $gp_regs[ $gp_idx++ ];
                        }
                    }

                    # Emit in reverse order so arg0 (reg rcx/rdi) is set last,
                    # avoiding clobber of virt_regs that may have been allocated
                    # to the same param register as a later argument.
                    for my $i ( reverse 0 .. $#args ) {
                        my $arg_type = $args[$i]->type;
                        my $is_float = $arg_type  && $arg_type->kind eq 'float';
                        my $is_i128  = !$is_float && $arg_type && $arg_type->kind eq 'int' && $arg_type->bits == 128;
                        if ($is_i128) {
                            my ( $lo_reg_name, $hi_reg_name ) = $arg_regs[$i]->@*;
                            my $lo_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $lo_reg_name );
                            my $hi_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $hi_reg_name );
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
                            my $reg_name = $arg_regs[$i];
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
                            my $rax = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $abi->return_register );
                            my $rdx = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rdx' );
                            my ( $lo, $hi ) = $self->_split_i128($inst);
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $lo, $rax ],
                                    comment  => "retval i128 lo from rax"
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $hi, $rdx ],
                                    comment  => "retval i128 hi from rdx"
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
                elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::FiberCreate') ) {
                    my $callee   = $inst->callee;
                    my $stack_sz = 64 * 1024;
                    my $fcb_sz   = 80;                                         # +8 os_thread at offset 72
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
                    my $saved_rsp = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'virt_reg',
                        value => $inst->name . '.rsp',
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $saved_rsp, $stack ],
                            comment  => 'saved_rsp = stack'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'add',
                            operands => [
                                $saved_rsp,
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'imm',
                                    value => $stack_sz - 8,
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                )
                            ],
                            comment => 'saved_rsp += stack_sz - 8 (simulate call push)'
                        )
                    );
                    my $fcb_rsp_field = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name . '.fcb', disp => 48 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [ $fcb_rsp_field, $saved_rsp ],
                            comment  => 'FCB.saved_rsp'
                        )
                    );

                    # Zero-initialize callee-save slots before setting specific values.
                    # The alloca does not zero memory, so uninitialized slots would
                    # load garbage into callee registers on the fiber's first entry.
                    for my $off ( 0, 8, 24, 32, 40, 72 ) {
                        my $f = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $inst->name . '.fcb', disp => $off },
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'store_imm',
                                operands => [
                                    $f,
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => Brocken::Lindsay::IR::Type::i64() )
                                ],
                                comment => "FCB[$off] = 0"
                            )
                        );
                    }

                    # Store self-pointer in FCB.r12 slot (offset 16)
                    my $fcb_self_field = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name . '.fcb', disp => 16 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [ $fcb_self_field, $fcb ],
                            comment  => 'FCB.self = FCB addr'
                        )
                    );

                    # Store parent FCB pointer (current fiber's r12) in FCB.parent slot (offset 56)
                    my $fcb_parent_field = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name . '.fcb', disp => 56 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    my $fiber_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'r12' );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [ $fcb_parent_field, $fiber_reg ],
                            comment  => 'FCB.parent = current fiber'
                        )
                    );

                    # Store entry function address in FCB.resume_pc (offset 64)
                    my $fcb_resume_field = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name . '.fcb', disp => 64 },
                        type  => Brocken::Lindsay::IR::Type::i64()
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [ $fcb_resume_field, $fptr ],
                            comment  => 'FCB.resume_pc = entry addr'
                        )
                    );

                    # Copy os_thread pointer from current fiber (r12) to new FCB[72]
                    my $fcb_os_thread = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $inst->name . '.fcb', disp => 72 },
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
                    my $fiber_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'r12' );
                    my $ret_reg   = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rax' );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $ret_reg, $self->_lower_opnd($val) ],
                            comment  => 'transfer value'
                        )
                    );

                    # Atomic context switch: save current FCB, restore target FCB, jump
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
                    my $fiber_reg = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'r12' );
                    my $ptr       = Brocken::Lindsay::IR::Type::ptr();
                    my $ret_reg   = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rax' );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $ret_reg, $self->_lower_opnd($val) ],
                            comment  => 'yield value'
                        )
                    );

                    # Load parent FCB from [r12 + 56]
                    my $parent_tmp = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '.parent', type => $ptr );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'load',
                            operands => [
                                $parent_tmp,
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'mem',
                                    value => { base => 'r12', disp => 56 },
                                    type  => Brocken::Lindsay::IR::Type::i64()
                                )
                            ],
                            comment => 'load parent FCB from current FCB'
                        )
                    );

                    # Atomic context switch: save current FCB, restore parent FCB, jump
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
                    if ( $platform->is_windows ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rcx' ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => -2, type => $i64 )
                                ],
                                comment => 'GetCurrentThread() pseudo-handle'
                            )
                        );
                        my $mask_lowered = $self->_lower_opnd($mask_opnd);
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rdx' ), $mask_lowered ],
                                comment  => 'mask'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'call_func',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'SetThreadAffinityMask' ) ],
                                comment  => 'SetThreadAffinityMask'
                            )
                        );
                    }
                    elsif ( $platform->is_linux || $platform->is_freebsd || $platform->is_dragonflybsd ) {
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
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rdi' ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 )
                                ],
                                comment => 'pid = 0 (current thread)'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rsi' ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 8, type => $i64 )
                                ],
                                comment => 'cpusetsize = 8'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'lea',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rdx' ),
                                    Brocken::Jenny::MIR::MachineOperand->new(
                                        kind  => 'mem',
                                        value => { base => $inst_tag . '.msk', disp => 0 },
                                        type  => $ptr
                                    )
                                ],
                                comment => '&mask'
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
                    my $fcb_sz   = 80;
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
                    my $saved_rsp = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name . '.rsp', type => $i64 );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [ $saved_rsp, $stack ],
                            comment  => 'saved_rsp = stack'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'add',
                            operands =>
                                [ $saved_rsp, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $stack_sz - 8, type => $i64 ) ],
                            comment => 'saved_rsp += stack_sz - 8'
                        )
                    );
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'store',
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new(
                                    kind  => 'mem',
                                    value => { base => $inst->name . '.fcb', disp => 48 },
                                    type  => $i64
                                ),
                                $saved_rsp
                            ],
                            comment => 'FCB.saved_rsp'
                        )
                    );

                    for my $off ( 0, 8, 24, 32, 40 ) {
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
                                    value => { base => $inst->name . '.fcb', disp => 16 },
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
                                    value => { base => $inst->name . '.fcb', disp => 56 },
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
                                    value => { base => $inst->name . '.fcb', disp => 64 },
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
                                    value => { base => $inst->name . '.fcb', disp => 72 },
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

                        # On Windows x86_64, call _create_thread thunk (handles Win64 ABI for CreateThread)
                        # Args use Win64 ABI: rcx=&handle, rdx=0(ignored), r8=start, r9=arg
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rcx' ), $handle ],
                                comment  => 'arg1: &handle'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rdx' ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 )
                                ],
                                comment => 'arg2: (unused)'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'r8' ), $tramp ],
                                comment  => 'arg3: start_routine'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'r9' ), $arg ],
                                comment  => 'arg4: arg'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'call_func',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => '_create_thread' ) ],
                                comment  => '_create_thread'
                            )
                        );
                    }
                    else {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rdi' ), $handle ],
                                comment  => 'arg1: &thread'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rsi' ),
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0, type => $i64 )
                                ],
                                comment => 'arg2: NULL attr'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rdx' ), $tramp ],
                                comment  => 'arg3: start_routine'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rcx' ), $arg ],
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

                        # WaitForSingleObject(handle, INFINITE), GetExitCodeThread(handle, &retval), then CloseHandle(handle)
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
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rcx' ), $reg ],
                                comment  => 'arg1: handle'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rdx' ),
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
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rcx' ), $reg ],
                                comment  => 'arg1: handle'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rdx' ), $retv_slot ],
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
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rcx' ), $reg ],
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
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rdi' ), $reg ],
                                comment  => 'arg1: thread handle'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'mov',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rsi' ), $retv_slot ],
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

=encoding utf-8

=head1 NAME

Brocken::Jenny::Lowerer::X86_64 - x86_64 Lowerer (Lindsay IR to MIR)

=head1 DESCRIPTION

Lowers Lindsay IR to machine-level MIR for the x86_64 architecture. Translates SSA instructions to register-based
machine operations while following the System V AMD64 calling convention.

=head2 Lowering Strategy

=over 4

=item B<Parameters> are mapped to their ABI register positions (rdi, rsi, rdx, rcx, r8, r9) with argument-area spill slots for stack-passed args

=item B<Calls> set up arguments in the correct ABI registers/stack slots, generate explicit C<call_func> MIR instructions, avoid clobbering argument registers by emitting them in reverse order

=item B<Boxing> serializes type-tagged values (int32->1, int64->2, i128->6, float->3, ptr->4, dynamic->5) into a 16-byte structure using the bump allocator

=item B<Unboxing> reads the type tag from the dynamic value and extracts the payload, with optional type checking

=item B<Refcounting> inserts C<incref> with atomic add and C<decref> with conditional free via the allocator's free-list

=item B<Alloca> translates to MIR C<alloca> instructions with pre-scanned prologue frame adjustment

=back

=head2 Floating-Point Materialization

The L<_materialize> method loads floating-point constants into XMM registers by first loading the bit pattern as an
integer GP register, then transferring to XMM via C<fmov_gp2f> (MOVQ/MOVD).

=head2 ABI Handling

Uses B<rdi> (arg 1), B<rsi> (arg 2), B<rdx> (arg 3), B<rcx> (arg 4), B<r8> (arg 5), B<r9> (arg 6). The C<caller_regs>
list in the ABI module must be ordered so non-parameter registers come first to avoid register allocator clashes with
argument-setup MOVs.

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

# ---------------------------------------------------------------------------
# Lowerer: Lindsay IR -> Machine IR (ARM64 / AArch64)
1;
