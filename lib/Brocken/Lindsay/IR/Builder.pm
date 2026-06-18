use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Lindsay::IR;

class Brocken::Lindsay::IR::Builder {
    field $insert_block : reader = undef;
    field $id_counter = 0;
    method position_at_end($block) { $insert_block = $block }
    method _next_id()              { '%' . $id_counter++ }

    method build_binop( $opcode, $lhs, $rhs, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction->new(
            name     => $name // $self->_next_id(),
            type     => $lhs->type,
            opcode   => $opcode,
            operands => [ $lhs, $rhs ],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }
    method build_add( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'add',  $lhs, $rhs, $name ) }
    method build_sub( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'sub',  $lhs, $rhs, $name ) }
    method build_mul( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'mul',  $lhs, $rhs, $name ) }
    method build_div( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'div',  $lhs, $rhs, $name ) }
    method build_rem( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'rem',  $lhs, $rhs, $name ) }
    method build_shl( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'shl',  $lhs, $rhs, $name ) }
    method build_lshr( $lhs, $rhs, $name = undef ) { $self->build_binop( 'lshr', $lhs, $rhs, $name ) }
    method build_ashr( $lhs, $rhs, $name = undef ) { $self->build_binop( 'ashr', $lhs, $rhs, $name ) }
    method build_and( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'and',  $lhs, $rhs, $name ) }
    method build_or( $lhs, $rhs, $name   = undef ) { $self->build_binop( 'or',   $lhs, $rhs, $name ) }
    method build_xor( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'xor',  $lhs, $rhs, $name ) }
    method build_min( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'min',  $lhs, $rhs, $name ) }
    method build_max( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'max',  $lhs, $rhs, $name ) }

    method build_unop( $opcode, $operand, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction->new(
            name     => $name // $self->_next_id(),
            type     => $operand->type,
            opcode   => $opcode,
            operands => [$operand],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }
    method build_neg( $operand, $name  = undef ) { $self->build_unop( 'neg',  $operand, $name ) }
    method build_abs( $operand, $name  = undef ) { $self->build_unop( 'abs',  $operand, $name ) }
    method build_sqrt( $operand, $name = undef ) { $self->build_unop( 'sqrt', $operand, $name ) }

    method build_phi( $type, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Phi->new(
            name   => $name // $self->_next_id(),
            type   => $type,
            opcode => 'phi',
            parent => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_select( $cond, $true_val, $false_val, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Select->new(
            name     => $name // $self->_next_id(),
            type     => $true_val->type,
            opcode   => 'select',
            operands => [ $cond, $true_val, $false_val ],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_gep( $base_type, $ptr, $indices, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::GetElementPtr->new(
            name      => $name // $self->_next_id(),
            type      => Brocken::Lindsay::IR::Type::ptr(),
            opcode    => 'getelementptr',
            base_type => $base_type,
            operands  => [ $ptr, $indices->@* ],
            parent    => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_icmp( $predicate, $lhs, $rhs, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::ICmp->new(
            name      => $name // $self->_next_id(),
            type      => Brocken::Lindsay::IR::Type::i1(),
            opcode    => 'icmp',
            predicate => $predicate,
            operands  => [ $lhs, $rhs ],
            parent    => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_br($dest_block) {
        my $inst = Brocken::Lindsay::IR::Instruction::Br->new(
            name       => undef,
            type       => Brocken::Lindsay::IR::Type::void(),
            opcode     => 'br',
            dest_block => $dest_block,
            parent     => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_cond_br( $cond_val, $true_block, $false_block ) {
        my $inst = Brocken::Lindsay::IR::Instruction::CondBr->new(
            name        => undef,
            type        => Brocken::Lindsay::IR::Type::void(),
            opcode      => 'br',
            operands    => [$cond_val],
            true_block  => $true_block,
            false_block => $false_block,
            parent      => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_ret( $val = undef ) {
        my $type = defined $val ? $val->type : Brocken::Lindsay::IR::Type::void();
        my $inst = Brocken::Lindsay::IR::Instruction::Ret->new(
            name     => undef,
            type     => $type,
            opcode   => 'ret',
            operands => defined $val ? [$val] : [],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_call( $callee, $args, $name = undef ) {
        my $type = $callee->return_type;
        my $inst = Brocken::Lindsay::IR::Instruction::Call->new(
            name     => $type->kind eq 'void' ? undef : ( $name // $self->_next_id() ),
            type     => $type,
            opcode   => 'call',
            callee   => $callee,
            operands => $args,
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_alloca( $type, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Alloca->new(
            name           => $name // $self->_next_id(),
            type           => Brocken::Lindsay::IR::Type::ptr(),
            opcode         => 'alloca',
            allocated_type => $type,
            parent         => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_load( $type, $ptr, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Load->new(
            name     => $name // $self->_next_id(),
            type     => $type,
            opcode   => 'load',
            operands => [$ptr],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_store( $val, $ptr ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Store->new(
            name     => undef,
            type     => Brocken::Lindsay::IR::Type::void(),
            opcode   => 'store',
            operands => [ $val, $ptr ],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_box( $val, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Box->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::dynamic(),
            opcode   => 'box',
            operands => [$val],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_unbox( $dynamic_val, $dest_type, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Unbox->new(
            name     => $name // $self->_next_id(),
            type     => $dest_type,
            opcode   => 'unbox',
            operands => [$dynamic_val],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }
}
1;
