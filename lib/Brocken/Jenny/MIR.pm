use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
class Brocken::Jenny::MIR::MachineOperand v0.0.1 {
    field $kind  : param : reader;
    field $value : param : reader;
    field $type  : param : reader = undef;
};
class Brocken::Jenny::MIR::MachineInstruction v0.0.1 {
    field $opcode      : param : reader;
    field $operands    : param : reader = [];
    field $comment     : param : reader = '';
    field $ir_inst_idx : param : reader : writer = -1;
};
class Brocken::Jenny::MIR::MachineBasicBlock v0.0.1 {
    field $name         : param : reader;
    field $instructions : param : reader = [];
    field $successors   : reader = [];
    field $predecessors : reader = [];
    method add_instruction($inst) { push $self->instructions->@*, $inst }

    method add_successor($block) {
        return if grep { $_ == $block } $self->successors->@*;
        push $self->successors->@*, $block;
        $block->add_predecessor($self);
    }

    method add_predecessor($block) {
        return if grep { $_ == $block } $self->predecessors->@*;
        push $self->predecessors->@*, $block;
    }

    method is_terminated() {
        return 0 if $self->instructions->@* == 0;
        my $last = $self->instructions->[-1];
        return $last->opcode =~ /^(jmp|beq|bne|br|ret|ctx_restore|ctx_swap)$/;
    }

    method terminator() {
        return undef if $self->instructions->@* == 0;
        my $last = $self->instructions->[-1];
        return $last->opcode =~ /^(jmp|beq|bne|br|ret|ctx_restore|ctx_swap)$/ ? $last : undef;
    }
};
class Brocken::Jenny::MIR::MachineFunction v0.0.1 {
    field $name       : param : reader;
    field $blocks     : param : reader = [];
    field $frame_size : param : reader = 0;
    method add_block($block) { push $self->blocks->@*, $block }
    method entry_block()     { return $self->blocks->@* ? $self->blocks->[0] : undef }

    method compute_cfg() {
        for my $bb ( $self->blocks->@* ) {
            my @insts = $bb->instructions->@*;
            for my $inst (@insts) {
                my $opcode = $inst->opcode;
                next unless $opcode =~ /^(?:jmp|br|beq|bne)$/;
                my @ops = $inst->operands->@*;
                if ( $opcode eq 'jmp' || $opcode eq 'br' ) {
                    my $target = $ops[0]->value;
                    my $tblock = $self->find_block($target);
                    $bb->add_successor($tblock) if $tblock;
                }
                elsif ( $opcode eq 'beq' || $opcode eq 'bne' ) {

                    # Wasm CondBr: bne has 1 operand (label only, condition on implicit stack)
                    # x86_64/ARM64/RISCV64 CondBr: bne/beq have 2 operands (cond, label)
                    # Wasm Select: beq has 2 operands (condition, label) - same as x86_64
                    my $target_idx = @ops == 2 ? 1 : 0;
                    my $target     = $ops[$target_idx]->value;
                    my $tblock     = $self->find_block($target);
                    $bb->add_successor($tblock) if $tblock;
                }
            }
        }
    }

    method find_block($name) {
        for my $bb ( $self->blocks->@* ) {
            return $bb if $bb->name eq $name;
        }
        return undef;
    }

    # Break reference cycles (successors/predecessors) so Perl GC can free the MIR.
    method release() {
        for my $bb ( $self->blocks->@* ) {
            my $succ = $bb->successors;
            @$succ = ();
            my $pred = $bb->predecessors;
            @$pred = ();
        }
    }
};
#
1;
