use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Lindsay::IR;

class Brocken::Lindsay::IR::Builder {
    field $insert_block : reader = undef;
    field $id_counter = 0;
    method position_at_end($block) { $insert_block = $block }
    method _next_id()              { '%' . $id_counter++ }

    method build_binop( $opcode, $lhs, $rhs, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction->new(
            name     => $name // $self->_next_id(),
            type     => $lhs->type,
            opcode   => $opcode,
            operands => [ $lhs, $rhs ],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }
    method build_add( $lhs, $rhs, $name  = undef, $line = 0, $col = 0 ) { $self->build_binop( 'add',  $lhs, $rhs, $name, $line, $col ) }
    method build_sub( $lhs, $rhs, $name  = undef, $line = 0, $col = 0 ) { $self->build_binop( 'sub',  $lhs, $rhs, $name, $line, $col ) }
    method build_mul( $lhs, $rhs, $name  = undef, $line = 0, $col = 0 ) { $self->build_binop( 'mul',  $lhs, $rhs, $name, $line, $col ) }
    method build_div( $lhs, $rhs, $name  = undef, $line = 0, $col = 0 ) { $self->build_binop( 'div',  $lhs, $rhs, $name, $line, $col ) }
    method build_rem( $lhs, $rhs, $name  = undef, $line = 0, $col = 0 ) { $self->build_binop( 'rem',  $lhs, $rhs, $name, $line, $col ) }
    method build_shl( $lhs, $rhs, $name  = undef, $line = 0, $col = 0 ) { $self->build_binop( 'shl',  $lhs, $rhs, $name, $line, $col ) }
    method build_lshr( $lhs, $rhs, $name = undef, $line = 0, $col = 0 ) { $self->build_binop( 'lshr', $lhs, $rhs, $name, $line, $col ) }
    method build_ashr( $lhs, $rhs, $name = undef, $line = 0, $col = 0 ) { $self->build_binop( 'ashr', $lhs, $rhs, $name, $line, $col ) }
    method build_and( $lhs, $rhs, $name  = undef, $line = 0, $col = 0 ) { $self->build_binop( 'and',  $lhs, $rhs, $name, $line, $col ) }
    method build_or( $lhs, $rhs, $name   = undef, $line = 0, $col = 0 ) { $self->build_binop( 'or',   $lhs, $rhs, $name, $line, $col ) }
    method build_xor( $lhs, $rhs, $name  = undef, $line = 0, $col = 0 ) { $self->build_binop( 'xor',  $lhs, $rhs, $name, $line, $col ) }
    method build_min( $lhs, $rhs, $name  = undef, $line = 0, $col = 0 ) { $self->build_binop( 'min',  $lhs, $rhs, $name, $line, $col ) }
    method build_max( $lhs, $rhs, $name  = undef, $line = 0, $col = 0 ) { $self->build_binop( 'max',  $lhs, $rhs, $name, $line, $col ) }

    method build_unop( $opcode, $operand, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction->new(
            name     => $name // $self->_next_id(),
            type     => $operand->type,
            opcode   => $opcode,
            operands => [$operand],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }
    method build_neg( $operand, $name  = undef, $line = 0, $col = 0 ) { $self->build_unop( 'neg',  $operand, $name, $line, $col ) }
    method build_abs( $operand, $name  = undef, $line = 0, $col = 0 ) { $self->build_unop( 'abs',  $operand, $name, $line, $col ) }
    method build_sqrt( $operand, $name = undef, $line = 0, $col = 0 ) { $self->build_unop( 'sqrt', $operand, $name, $line, $col ) }

    method build_zext( $val, $target_type, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Zext->new(
            name        => $name // $self->_next_id(),
            type        => $target_type,
            opcode      => 'zext',
            target_type => $target_type,
            operands    => [$val],
            parent      => $insert_block,
            line        => $line,
            col         => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_sext( $val, $target_type, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Sext->new(
            name        => $name // $self->_next_id(),
            type        => $target_type,
            opcode      => 'sext',
            target_type => $target_type,
            operands    => [$val],
            parent      => $insert_block,
            line        => $line,
            col         => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_sitofp( $val, $target_type, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::SIToFP->new(
            name        => $name // $self->_next_id(),
            type        => $target_type,
            opcode      => 'sitofp',
            target_type => $target_type,
            operands    => [$val],
            parent      => $insert_block,
            line        => $line,
            col         => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_fptosi( $val, $target_type, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::FPToSI->new(
            name        => $name // $self->_next_id(),
            type        => $target_type,
            opcode      => 'fptosi',
            target_type => $target_type,
            operands    => [$val],
            parent      => $insert_block,
            line        => $line,
            col         => $col,
        );
        return $insert_block->append_inst($inst);
    }
    method build_udiv( $lhs, $rhs, $name = undef, $line = 0, $col = 0 ) { $self->build_binop( 'udiv', $lhs, $rhs, $name, $line, $col ) }
    method build_urem( $lhs, $rhs, $name = undef, $line = 0, $col = 0 ) { $self->build_binop( 'urem', $lhs, $rhs, $name, $line, $col ) }

    method build_frame_addr( $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::FrameAddr->new(
            name   => $name // $self->_next_id(),
            type   => Brocken::Lindsay::IR::Type::ptr(),
            opcode => 'frame_addr',
            parent => $insert_block,
            line   => $line,
            col    => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_phi( $type, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Phi->new(
            name   => $name // $self->_next_id(),
            type   => $type,
            opcode => 'phi',
            parent => $insert_block,
            line   => $line,
            col    => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_select( $cond, $true_val, $false_val, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Select->new(
            name     => $name // $self->_next_id(),
            type     => $true_val->type,
            opcode   => 'select',
            operands => [ $cond, $true_val, $false_val ],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_gep( $base_type, $ptr, $indices, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::GetElementPtr->new(
            name      => $name // $self->_next_id(),
            type      => Brocken::Lindsay::IR::Type::ptr(),
            opcode    => 'getelementptr',
            base_type => $base_type,
            operands  => [ $ptr, $indices->@* ],
            parent    => $insert_block,
            line      => $line,
            col       => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_struct_gep( $struct_type, $ptr, $field_idx, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::GetElementPtr->new(
            name             => $name // $self->_next_id(),
            type             => Brocken::Lindsay::IR::Type::ptr(),
            opcode           => 'getelementptr',
            base_type        => $struct_type,
            struct_field_idx => $field_idx,
            operands         => [
                $ptr,
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => $field_idx ),
            ],
            parent => $insert_block,
            line   => $line,
            col    => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_icmp( $predicate, $lhs, $rhs, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::ICmp->new(
            name      => $name // $self->_next_id(),
            type      => Brocken::Lindsay::IR::Type::i1(),
            opcode    => 'icmp',
            predicate => $predicate,
            operands  => [ $lhs, $rhs ],
            parent    => $insert_block,
            line      => $line,
            col       => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_br( $dest_block, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Br->new(
            name       => undef,
            type       => Brocken::Lindsay::IR::Type::void(),
            opcode     => 'br',
            dest_block => $dest_block,
            parent     => $insert_block,
            line       => $line,
            col        => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_cond_br( $cond_val, $true_block, $false_block, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::CondBr->new(
            name        => undef,
            type        => Brocken::Lindsay::IR::Type::void(),
            opcode      => 'br',
            operands    => [$cond_val],
            true_block  => $true_block,
            false_block => $false_block,
            parent      => $insert_block,
            line        => $line,
            col         => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_ret( $val = undef, $line = 0, $col = 0 ) {
        my $type = defined $val ? $val->type : Brocken::Lindsay::IR::Type::void();
        my $inst = Brocken::Lindsay::IR::Instruction::Ret->new(
            name     => undef,
            type     => $type,
            opcode   => 'ret',
            operands => defined $val ? [$val] : [],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_call( $callee, $args, $name = undef, $line = 0, $col = 0 ) {
        my $type = $callee->return_type;
        my $inst = Brocken::Lindsay::IR::Instruction::Call->new(
            name     => $type->kind eq 'void' ? undef : ( $name // $self->_next_id() ),
            type     => $type,
            opcode   => 'call',
            callee   => $callee,
            operands => $args,
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_alloca( $type, $name = undef, $count = undef, $line = 0, $col = 0, $debug_name = undef, $debug_type_name = undef ) {
        $count = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $count ) if defined $count && !ref $count;
        my $inst = Brocken::Lindsay::IR::Instruction::Alloca->new(
            name            => $name // $self->_next_id(),
            type            => Brocken::Lindsay::IR::Type::ptr(),
            opcode          => 'alloca',
            allocated_type  => $type,
            count           => $count,
            debug_name      => $debug_name,
            debug_type_name => $debug_type_name,
            parent          => $insert_block,
            line            => $line,
            col             => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_load( $type, $ptr, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Load->new(
            name     => $name // $self->_next_id(),
            type     => $type,
            opcode   => 'load',
            operands => [$ptr],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_store( $val, $ptr, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Store->new(
            name     => undef,
            type     => Brocken::Lindsay::IR::Type::void(),
            opcode   => 'store',
            operands => [ $val, $ptr ],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_syscall( $args, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Syscall->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i64(),
            opcode   => 'syscall',
            operands => $args,
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_box( $val, $name = undef, $line = 0, $col = 0, $heap_base = undef ) {
        my @operands = ($val);
        push @operands, $heap_base if $heap_base;
        my $inst = Brocken::Lindsay::IR::Instruction::Box->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::dynamic(),
            opcode   => 'box',
            operands => \@operands,
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_unbox( $dynamic_val, $dest_type, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Unbox->new(
            name     => $name // $self->_next_id(),
            type     => $dest_type,
            opcode   => 'unbox',
            operands => [$dynamic_val],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_incref( $val, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Incref->new(
            name     => undef,
            type     => Brocken::Lindsay::IR::Type::void(),
            opcode   => 'incref',
            operands => [$val],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_decref( $val, $line = 0, $col = 0, $heap_base = undef ) {
        my @operands = defined $heap_base ? ( $val, $heap_base ) : ($val);
        my $inst     = Brocken::Lindsay::IR::Instruction::Decref->new(
            name     => undef,
            type     => Brocken::Lindsay::IR::Type::void(),
            opcode   => 'decref',
            operands => \@operands,
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_fiber_create( $callee, $args, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::FiberCreate->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::ptr(),
            opcode   => 'fiber_create',
            callee   => $callee,
            operands => $args,
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_fiber_transfer( $fiber, $val, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::FiberTransfer->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::dynamic(),
            opcode   => 'fiber_transfer',
            operands => [ $fiber, $val ],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_fiber_yield( $val, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::FiberYield->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::dynamic(),
            opcode   => 'fiber_yield',
            operands => [$val],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_fiber_id( $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::FiberId->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i64(),
            opcode   => 'fiber_id',
            operands => [],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_fiber_pin( $fiber, $tid, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::FiberPin->new(
            name     => undef,
            type     => Brocken::Lindsay::IR::Type::void(),
            opcode   => 'fiber_pin',
            operands => [ $fiber, $tid ],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_isolate_create( $callee, $args, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::IsolateCreate->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i64(),
            opcode   => 'isolate_create',
            callee   => $callee,
            operands => $args,
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_isolate_join( $isolate, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::IsolateJoin->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i64(),
            opcode   => 'isolate_join',
            operands => [$isolate],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_chan_create( $capacity, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::ChanCreate->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::ptr(),
            opcode   => 'chan_create',
            operands => [$capacity],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_chan_send( $chan, $val, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::ChanSend->new(
            name     => undef,
            type     => Brocken::Lindsay::IR::Type::void(),
            opcode   => 'chan_send',
            operands => [ $chan, $val ],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_chan_recv( $chan, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::ChanRecv->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i64(),
            opcode   => 'chan_recv',
            operands => [$chan],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_chan_close( $chan, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::ChanClose->new(
            name     => undef,
            type     => Brocken::Lindsay::IR::Type::void(),
            opcode   => 'chan_close',
            operands => [$chan],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_chan_try_send( $chan, $val, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::ChanTrySend->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i1(),
            opcode   => 'chan_try_send',
            operands => [ $chan, $val ],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }

    method build_chan_try_recv( $chan, $name = undef, $line = 0, $col = 0 ) {
        my $inst = Brocken::Lindsay::IR::Instruction::ChanTryRecv->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i64(),
            opcode   => 'chan_try_recv',
            operands => [$chan],
            parent   => $insert_block,
            line     => $line,
            col      => $col,
        );
        return $insert_block->append_inst($inst);
    }
}

=encoding utf-8

=head1 NAME

Brocken::Lindsay::IR::Builder - Incremental IR Construction API

=head1 DESCRIPTION

Provides a convenient imperative API for constructing Lindsay IR incrementally. Instructions are appended to the
current insertion block, which is set via L</position_at_end>.

=head1 METHODS

=head2 position_at_end

    $builder->position_at_end($block);

Sets the block where subsequent build_* methods will insert instructions.

=head2 Arithmetic Builders

    $builder->build_add($lhs, $rhs, $name?)
    $builder->build_sub($lhs, $rhs, $name?)
    $builder->build_mul($lhs, $rhs, $name?)
    $builder->build_div($lhs, $rhs, $name?)
    $builder->build_rem($lhs, $rhs, $name?)
    $builder->build_shl($lhs, $rhs, $name?)
    $builder->build_lshr($lhs, $rhs, $name?)
    $builder->build_ashr($lhs, $rhs, $name?)
    $builder->build_and($lhs, $rhs, $name?)
    $builder->build_or($lhs, $rhs, $name?)
    $builder->build_xor($lhs, $rhs, $name?)
    $builder->build_min($lhs, $rhs, $name?)
    $builder->build_max($lhs, $rhs, $name?)

=head2 Unary Builders

    $builder->build_neg($operand, $name?)
    $builder->build_abs($operand, $name?)
    $builder->build_sqrt($operand, $name?)

=head2 Memory Builders

    $builder->build_alloca($type, $name?)
    $builder->build_load($type, $ptr, $name?)
    $builder->build_store($val, $ptr)
    $builder->build_gep($base_type, $ptr, \@indices, $name?)

=head2 Control Flow Builders

    $builder->build_br($dest_block)
    $builder->build_cond_br($cond_val, $true_block, $false_block)
    $builder->build_ret($val?)
    $builder->build_call($callee_func, \@args, $name?)
    $builder->build_phi($type, $name?)
    $builder->build_select($cond, $true_val, $false_val, $name?)
    $builder->build_icmp($predicate, $lhs, $rhs, $name?)

=head2 Runtime Builders

    $builder->build_box($val, $name?)
    $builder->build_unbox($dynamic_val, $dest_type, $name?)
    $builder->build_incref($val)
    $builder->build_decref($val)

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
