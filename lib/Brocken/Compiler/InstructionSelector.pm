use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Compiler::InstructionSelector {
    field $arch     : reader : param;
    field $mapping  : reader : param; # Result of register allocation
    field $emitter  : reader : param; # Target::Architecture::* instance

    method select($cfg) {
        for my $block ($cfg->blocks) {
            $emitter->mark_label($block->name);
            for my $instr ($block->instructions) {
                $self->_emit_instruction($instr);
            }
            if ($block->terminator) {
                $self->_emit_instruction($block->terminator);
            }
        }
        $emitter->resolve();
        return $emitter->code;
    }

    method _emit_instruction($instr) {
        if ($instr->isa('Brocken::IR::Assign')) {
            # ... existing logic ...
            my $dest = $self->_get_reg($instr->dest);
            my $lhs  = $self->_get_reg($instr->lhs);
            my $rhs  = $self->_get_reg($instr->rhs);
            if ($instr->op eq '') {
                if ($instr->lhs =~ /^\d+$/) {
                    $emitter->mov_imm($dest, $instr->lhs);
                } else {
                    $emitter->mov_reg($dest, $lhs);
                }
            } else {
                $emitter->mov_reg($dest, $lhs);
                if ($instr->op eq '+') { $emitter->add_imm($dest, $rhs) }
                elsif ($instr->op eq '-') { $emitter->sub_imm($dest, $rhs) }
            }
        }
        elsif ($instr->isa('Brocken::IR::Load')) {
            my $dest = $self->_get_reg($instr->dest);
            # Simplified: load variable to register
            # Need to implement memory access in emitter if not already there
            # For now, just a placeholder or comment if not supported
            $emitter->mov_imm($dest, 0); # Placeholder: load from memory address
        }
        elsif ($instr->isa('Brocken::IR::Store')) {
            # Simplified: store register to variable
            my $src = $self->_get_reg($instr->src);
            # Need memory access
        }
        elsif ($instr->isa('Brocken::IR::Call')) {
            # Call handling (ABI dependent)
            my $dest = $self->_get_reg($instr->dest);
            # For now, just call a placeholder address
            $emitter->call_rva(0x0, 0x1000); 
        }
        elsif ($instr->isa('Brocken::IR::Jump')) {
            $emitter->jmp($instr->label);
        }
        elsif ($instr->isa('Brocken::IR::Branch')) {
            $emitter->jcc(0, $instr->label); # Simplified
        }
        elsif ($instr->isa('Brocken::IR::Return')) {
            $emitter->ret();
        }
        elsif ($instr->isa('Brocken::IR::RefInc') || $instr->isa('Brocken::IR::RefDec')) {
            # Skip for now
        }
    }

    method _get_reg($vreg) {
        return $vreg if $vreg =~ /^\d+$/; # It's an immediate
        return $mapping->{$vreg} // 'stack';
    }
}
1;
