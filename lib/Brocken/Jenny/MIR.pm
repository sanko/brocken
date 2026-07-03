use v5.42;
use feature qw[class];
no warnings qw[experimental::class];

class Brocken::Jenny::MIR::MachineOperand {
    field $kind  : param : reader;
    field $value : param : reader;
    field $type  : param : reader = undef;
}

class Brocken::Jenny::MIR::MachineInstruction {
    field $opcode      : param : reader;
    field $operands    : param : reader = [];
    field $comment     : param : reader = '';
    field $ir_inst_idx : param : reader : writer = -1;
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
        return $last->opcode =~ /^(jmp|beq|bne|br|ret|ctx_restore|ctx_swap)$/;
    }

    method terminator() {
        return undef if $self->instructions->@* == 0;
        my $last = $self->instructions->[-1];
        return $last->opcode =~ /^(jmp|beq|bne|br|ret|ctx_restore|ctx_swap)$/ ? $last : undef;
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

=encoding utf-8

=head1 NAME

Brocken::Jenny::MIR - Machine Intermediate Representation

=head1 DESCRIPTION

Defines the data structures for Brocken's Machine Intermediate Representation (MIR). The MIR is a low-level,
target-independent representation used between the Lowerer (Lindsay IR -> MIR) and the Codegen (MIR -> machine code).

=head2 Class Hierarchy

=over 4

=item L<Brocken::Jenny::MIR::MachineOperand> - A single operand (virtual reg,
physical reg, immediate value, or memory address). Memory operands use a
hashref with C<base>, C<index>, C<scale>, and C<disp> keys.

=item L<Brocken::Jenny::MIR::MachineInstruction> - A single instruction with an
opcode string, an array of operands, and an optional comment. Carries
C<ir_inst_idx> for DWARF source-location mapping back to the originating IR
instruction.

=item L<Brocken::Jenny::MIR::MachineBasicBlock> - A basic block of MIR
instructions with control-flow successor/predecessor tracking.

=item L<Brocken::Jenny::MIR::MachineFunction> - A function containing an array
of basic blocks and a frame size. Provides CFG computation (compute_cfg) and
block lookup (find_block).

=back

=head1 METHODS

=head2 Brocken::Jenny::MIR::MachineBasicBlock

=over

=item C<add_successor($block)>, C<add_predecessor($block)>

Record CFG edges. Duplicates are silently ignored.

=item C<is_terminated>

Returns 1 if the last instruction is a terminator (jmp, beq, bne, br, ret, ctx_restore, ctx_swap).

=item C<terminator>

Returns the terminator instruction or undef.

=back

=head2 Brocken::Jenny::MIR::MachineFunction

=over

=item C<compute_cfg>

Walks all blocks and their terminators to build successor/predecessor edges. Handles jmp (unconditional), beq/bne
(conditional), and ret (no successor).

=item C<find_block($name)>

Returns the block with the given name, or undef.

=item C<entry_block>

Returns the first block (entry) or undef.

=back

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
