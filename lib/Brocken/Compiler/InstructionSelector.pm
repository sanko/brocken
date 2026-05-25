use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Target::OS;

class Brocken::Compiler::InstructionSelector {
    field $arch     : reader : param;
    field $mapping  : reader : param; # Result of register allocation
    field $emitter  : reader : param; # Target::Architecture::* instance
    field $os       : reader : param; # Target::OS instance
    field %string_literals;           # vreg => string value
    field $label_count = 0;

    method _new_label() { return "ISL" . $label_count++ }

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
            my $dest = $self->_get_reg($instr->dest);
            my $lhs  = $self->_get_reg($instr->lhs);
            my $rhs  = $self->_get_reg($instr->rhs);
            if ($instr->op eq '') {
                if ($instr->lhs =~ /^\d+$/) {
                    $emitter->mov_imm($dest, $instr->lhs);
                } elsif ($instr->lhs =~ /^v\d+$/) {
                    $emitter->mov_reg($dest, $lhs);
                } else {
                    $string_literals{$instr->dest} = $instr->lhs;
                }
            } else {
                $emitter->mov_reg($dest, $lhs);
                if ($instr->op eq '+') { $emitter->add_imm($dest, $rhs) }
                elsif ($instr->op eq '-') { $emitter->sub_imm($dest, $rhs) }
            }
        }
        elsif ($instr->isa('Brocken::IR::Load')) {
            my $dest = $self->_get_reg($instr->dest);
            $emitter->mov_imm($dest, 0); 
        }
        elsif ($instr->isa('Brocken::IR::Store')) {
            my $src = $self->_get_reg($instr->src);
        }
        elsif ($instr->isa('Brocken::IR::Call')) {
            if ($instr->func eq 'print') {
                my $arg = $instr->args->[0] // '';
                my $str = $string_literals{$arg} // '';
                $emitter->emit_print_str($os, 0, length($str));
            }
            elsif ($instr->func eq 'spawn_thread') {
                my $arg = $instr->args->[0] // '';
                my $entry_label = $string_literals{$arg} // '';
                my $text_rva    = $os->text_rva;

                if ($os->name eq 'win64') {
                    $emitter->sub_imm('rsp', 32);
                    $emitter->mov_imm('rcx', 0);
                    $emitter->mov_imm('rdx', 0x40000);
                    $emitter->lea_rva('r8', $entry_label, $text_rva);
                    $emitter->mov_imm('r9', 0);
                    $emitter->mov_imm('r10', 0);
                    $emitter->store_mem_disp_reg('rsp', 32, 'r10');
                    $emitter->store_mem_disp_reg('rsp', 40, 'r10');
                    $emitter->call_rva($os->symbol_rva('CreateThread'), $text_rva);
                    $emitter->add_imm('rsp', 32);
                    $emitter->sub_imm('rsp', 32);
                    $emitter->mov_imm('rcx', 500);
                    $emitter->call_rva($os->symbol_rva('Sleep'), $text_rva);
                    $emitter->add_imm('rsp', 32);
                }
                elsif ($os->name eq 'linux') {
                    # Real OS threads on Linux using clone + mmap stack
                    my $stack_size = 1024 * 1024; # 1MB
                    my $ret_reg = $os->syscall_num_reg($arch);
                    
                    # 1. Allocate stack
                    $os->write_mmap_args($emitter, $arch, $stack_size);
                    $emitter->emit_syscall($os->syscall_mmap($arch));
                    
                    # rax/x0/a0 now has stack base
                    my $stack_top  = $arch eq 'x64' ? 'r11' : ($arch eq 'arm64' ? 'x10' : 't1');
                    $emitter->add_reg_imm($stack_top, $ret_reg, $stack_size);
                    
                    # 2. Call clone
                    # Flags: CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|CLONE_SYSVSEM = 0x70f00
                    my $flags = 0x70f00;
                    if ($arch eq 'x64') {
                        $emitter->emit_syscall($os->syscall_clone($arch), $flags, $stack_top, 0, 0, 0);
                    } else {
                        # ARM64/RISCV64: clone(flags, stack, ...)
                        $emitter->emit_syscall($os->syscall_clone($arch), $flags, $stack_top);
                    }
                    
                    $emitter->emit_branch_if_zero($ret_reg, $entry_label . "_child");
                    
                    # Parent: delay loop
                    my $delay_reg = $arch eq 'x64' ? 'rcx' : ($arch eq 'arm64' ? 'x9' : 't0');
                    $emitter->mov_imm($delay_reg, 0x1FFFFF);
                    my $delay_label = "delay_" . $self->_new_label();
                    $emitter->emit_label($delay_label);
                    $emitter->sub_imm($delay_reg, 1);
                    $emitter->emit_branch_if_not_zero($delay_reg, $delay_label);
                    $emitter->jmp($entry_label . "_after");

                    # Child thread entry
                    $emitter->emit_label($entry_label . "_child");
                    $emitter->mov_reg_to_sp($stack_top);
                    $emitter->jmp($entry_label);
                    
                    $emitter->emit_label($entry_label . "_after");
                }
                else {
                    # POSIX-like: try specific thread primitives or fall back to fork
                    my $syscall_num;
                    if    ($os->name eq 'netbsd')  { $syscall_num = $os->syscall_lwp_create($arch) }
                    elsif ($os->name eq 'openbsd') { $syscall_num = $os->syscall_tfork($arch) }
                    elsif ($os->name eq 'freebsd') { $syscall_num = $os->syscall_rfork($arch) }
                    
                    $syscall_num //= $os->syscall_fork($arch);
                    
                    my $ret_reg = $os->syscall_num_reg($arch); # Return value usually in same reg
                    $emitter->emit_syscall($syscall_num);
                    $emitter->emit_branch_if_zero($ret_reg, $entry_label);
                    
                    # Parent: Sleep a bit to allow child to run
                    if ($arch eq 'x64' || $arch eq 'arm64' || $arch eq 'riscv64') {
                        my $delay_reg = $arch eq 'x64' ? 'rcx' : ($arch eq 'arm64' ? 'x9' : 't0');
                        $emitter->mov_imm($delay_reg, 0x1FFFFF);
                        my $delay_label = "delay_" . $self->_new_label();
                        $emitter->emit_label($delay_label);
                        $emitter->sub_imm($delay_reg, 1);
                        $emitter->emit_branch_if_not_zero($delay_reg, $delay_label);
                    }
                }
            }
        }
        elsif ($instr->isa('Brocken::IR::Jump')) {
            $emitter->jmp($instr->label);
        }
        elsif ($instr->isa('Brocken::IR::Branch')) {
            $emitter->jcc(0, $instr->label); 
        }
        elsif ($instr->isa('Brocken::IR::Return')) {
            my $val = $instr->val;
            if (defined $val && $val eq 'EXIT_THREAD') {
                if ($os->is_posix) {
                    $emitter->emit_exit_proc($os, 0);
                } else {
                    $emitter->ret();
                }
            }
            elsif ($emitter->can('emit_exit_proc')) {
                $emitter->emit_exit_proc($os, 0);
            } else {
                $emitter->ret();
            }
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
