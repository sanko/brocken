use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
class Brocken::Lindsay::IR::Builder v0.0.1 {
    use Brocken::Lindsay::IR;
    field $insert_block : reader = undef;
    field $id_counter = 0;
    field %name_counts;
    method position_at_end($block) { $insert_block = $block }
    method _next_id()              { '%' . $id_counter++ }

    # A readable name that is still unique. The frontend names call results
    # after the callee, so two calls to the same function in one expression
    # both wanted `%f_res` and the second silently overwrote the first: the
    # IR carried two different values under one name, and every backend that
    # maps values to registers or locals collapsed them into one.
    method _unique_name($hint) {
        return $self->_next_id() unless defined $hint && length $hint;
        my $seen = $name_counts{$hint}++;
        return $hint if $seen == 0;
        return $hint . '_' . $seen;
    }

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

    method build_zext( $val, $target_type, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Zext->new(
            name        => $name // $self->_next_id(),
            type        => $target_type,
            opcode      => 'zext',
            target_type => $target_type,
            operands    => [$val],
            parent      => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_sext( $val, $target_type, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Sext->new(
            name        => $name // $self->_next_id(),
            type        => $target_type,
            opcode      => 'sext',
            target_type => $target_type,
            operands    => [$val],
            parent      => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_trunc( $val, $target_type, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Trunc->new(
            name        => $name // $self->_next_id(),
            type        => $target_type,
            opcode      => 'trunc',
            target_type => $target_type,
            operands    => [$val],
            parent      => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    # A float reaching an integer slot is a computation, not a relabelling: the
    # two hold different bits, so this cannot be the pointer/int mirror above.
    # Without it the float's IEEE pattern was stored verbatim into the integer
    # slot and the reload read it back as a large number that happened to end in
    # zero -- a silent answer rather than a wrong-looking one.
    method build_fptosi( $val, $target_type, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Fptosi->new(
            name        => $name // $self->_next_id(),
            type        => $target_type,
            opcode      => 'fptosi',
            target_type => $target_type,
            operands    => [$val],
            parent      => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    # The mirror of the conversion above, and subject to the same two ways of
    # getting it wrong: the IEEE pattern must not be stored verbatim, and the
    # result must be a converted number rather than integer bits in a float
    # slot. Only the target differs, so the source keeps its own type here and
    # the widening that makes the unsigned cases work is the frontend's job.
    method build_sitofp( $val, $target_type, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Sitofp->new(
            name        => $name // $self->_next_id(),
            type        => $target_type,
            opcode      => 'sitofp',
            target_type => $target_type,
            operands    => [$val],
            parent      => $insert_block
        );
        return $insert_block->append_inst($inst);
    }
    method build_udiv( $lhs, $rhs, $name = undef ) { $self->build_binop( 'udiv', $lhs, $rhs, $name ) }
    method build_urem( $lhs, $rhs, $name = undef ) { $self->build_binop( 'urem', $lhs, $rhs, $name ) }

    method build_frame_addr( $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::FrameAddr->new(
            name   => $name // $self->_next_id(),
            type   => Brocken::Lindsay::IR::Type::ptr(),
            opcode => 'frame_addr',
            parent => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

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

    method build_alloca( $type, $name = undef, $count = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::Alloca->new(
            name           => $name // $self->_next_id(),
            type           => Brocken::Lindsay::IR::Type::ptr(),
            opcode         => 'alloca',
            allocated_type => $type,
            count          => $count,
            parent         => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_memory_grow( $pages, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::MemoryGrow->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i32(),
            opcode   => 'memory_grow',
            operands => [$pages],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_memory_size( $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::MemorySize->new(
            name   => $name // $self->_next_id(),
            type   => Brocken::Lindsay::IR::Type::i32(),
            opcode => 'memory_size',
            parent => $insert_block
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

    method build_ptrcast( $val, $target_type, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::PtrCast->new(
            name        => $name // $self->_next_id(),
            type        => $target_type,
            opcode      => 'ptrcast',
            target_type => $target_type,
            operands    => [$val],
            parent      => $insert_block
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

    method build_incref($val) {
        my $inst = Brocken::Lindsay::IR::Instruction::Incref->new(
            name     => undef,
            type     => Brocken::Lindsay::IR::Type::void(),
            opcode   => 'incref',
            operands => [$val],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_decref($val) {
        my $inst = Brocken::Lindsay::IR::Instruction::Decref->new(
            name     => undef,
            type     => Brocken::Lindsay::IR::Type::void(),
            opcode   => 'decref',
            operands => [$val],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_fiber_create( $callee, $args, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::FiberCreate->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::ptr(),
            opcode   => 'fiber_create',
            callee   => $callee,
            operands => $args,
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_fiber_transfer( $fiber, $val, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::FiberTransfer->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::dynamic(),
            opcode   => 'fiber_transfer',
            operands => [ $fiber, $val ],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_fiber_yield( $val, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::FiberYield->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::dynamic(),
            opcode   => 'fiber_yield',
            operands => [$val],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_fiber_id( $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::FiberId->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i64(),
            opcode   => 'fiber_id',
            operands => [],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_fiber_pin( $fiber, $tid ) {
        my $inst = Brocken::Lindsay::IR::Instruction::FiberPin->new(
            name     => undef,
            type     => Brocken::Lindsay::IR::Type::void(),
            opcode   => 'fiber_pin',
            operands => [ $fiber, $tid ],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_isolate_create( $callee, $args, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::IsolateCreate->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i64(),
            opcode   => 'isolate_create',
            callee   => $callee,
            operands => $args,
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_isolate_join( $isolate, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::IsolateJoin->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i64(),
            opcode   => 'isolate_join',
            operands => [$isolate],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_chan_create( $capacity, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::ChanCreate->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::ptr(),
            opcode   => 'chan_create',
            operands => [$capacity],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_chan_send( $chan, $val ) {
        my $inst = Brocken::Lindsay::IR::Instruction::ChanSend->new(
            name     => undef,
            type     => Brocken::Lindsay::IR::Type::void(),
            opcode   => 'chan_send',
            operands => [ $chan, $val ],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_chan_recv( $chan, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::ChanRecv->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i64(),
            opcode   => 'chan_recv',
            operands => [$chan],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_chan_close($chan) {
        my $inst = Brocken::Lindsay::IR::Instruction::ChanClose->new(
            name     => undef,
            type     => Brocken::Lindsay::IR::Type::void(),
            opcode   => 'chan_close',
            operands => [$chan],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_chan_try_send( $chan, $val, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::ChanTrySend->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i1(),
            opcode   => 'chan_try_send',
            operands => [ $chan, $val ],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }

    method build_chan_try_recv( $chan, $name = undef ) {
        my $inst = Brocken::Lindsay::IR::Instruction::ChanTryRecv->new(
            name     => $name // $self->_next_id(),
            type     => Brocken::Lindsay::IR::Type::i64(),
            opcode   => 'chan_try_recv',
            operands => [$chan],
            parent   => $insert_block
        );
        return $insert_block->append_inst($inst);
    }
};
#
1;
