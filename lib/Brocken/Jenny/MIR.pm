use v5.42;
use feature qw[class];
no warnings qw[experimental::class];

class Brocken::Jenny::MIR::MachineOperand {
    field $kind  : param : reader;
    field $value : param : reader;
    field $type  : param : reader = undef;
}

class Brocken::Jenny::MIR::MachineInstruction {
    field $opcode   : param : reader;
    field $operands : param : reader = [];
    field $comment  : param : reader = '';
}

class Brocken::Jenny::MIR::MachineBasicBlock {
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
        return $last->opcode =~ /^(jmp|beq|bne|br|ret)$/;
    }

    method terminator() {
        return undef if $self->instructions->@* == 0;
        my $last = $self->instructions->[-1];
        return $last->opcode =~ /^(jmp|beq|bne|br|ret)$/ ? $last : undef;
    }
}

class Brocken::Jenny::MIR::MachineFunction {
    field $name       : param : reader;
    field $blocks     : param : reader = [];
    field $frame_size : param : reader = 0;
    method add_block($block) { push $self->blocks->@*, $block }
    method entry_block()     { return $self->blocks->@* ? $self->blocks->[0] : undef }

    method compute_cfg() {
        for my $bb ( $self->blocks->@* ) {
            my $term = $bb->terminator;
            next unless $term;
            my $opcode = $term->opcode;
            my @ops    = $term->operands->@*;
            if ( $opcode eq 'jmp' || $opcode eq 'br' ) {
                my $target = $ops[0]->value;
                my $tblock = $self->find_block($target);
                $bb->add_successor($tblock) if $tblock;
            }
            elsif ( $opcode eq 'beq' || $opcode eq 'bne' ) {
                my $target = $ops[1]->value;
                my $tblock = $self->find_block($target);
                $bb->add_successor($tblock) if $tblock;
                my $idx = 0;
                for my $b ( $self->blocks->@* ) {
                    last if $b == $bb;
                    $idx++;
                }
                if ( $idx + 1 < $self->blocks->@* ) {
                    $bb->add_successor( $self->blocks->[ $idx + 1 ] );
                }
            }
            elsif ( $opcode eq 'ret' ) {
            }
        }
    }

    method find_block($name) {
        for my $bb ( $self->blocks->@* ) {
            return $bb if $bb->name eq $name;
        }
        return undef;
    }
}
1;
