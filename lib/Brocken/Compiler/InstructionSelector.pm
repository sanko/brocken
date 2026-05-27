use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Target::OS;

class Brocken::Compiler::InstructionSelector {
    field $arch    : reader : param;
    field $mapping : reader : param;    # Result of register allocation
    field $emitter : reader : param;    # Target::Architecture::* instance
    field $os      : reader : param;    # Target::OS instance
    field %string_literals;             # vreg => string value
    field %string_offsets;              # vreg => data segment offset
    field $data_offset = 0;
    field $label_count = 0;
    method _new_label() { return "ISL" . $label_count++ }

    method select($cfg) {
        for my $block ( $cfg->blocks ) {
            $emitter->mark_label( $block->name );
            for my $instr ( $block->instructions ) {
                $self->_emit_instruction($instr);
            }
            if ( $block->terminator ) {
                $self->_emit_instruction( $block->terminator );
            }
        }
        $emitter->resolve();
        return $emitter->code;
    }

    method _emit_instruction($instr) {
        if ( $instr->isa('Brocken::IR::Assign') ) {
            my $dest = $self->_get_reg( $instr->dest );
            my $lhs  = $self->_get_reg( $instr->lhs );
            my $rhs  = $self->_get_reg( $instr->rhs );
            if ( $instr->op eq '' ) {
                if ( $instr->lhs =~ /^\d+$/ ) {
                    $emitter->mov_imm( $dest, $instr->lhs );
                }
                elsif ( $instr->lhs =~ /^v\d+$/ ) {
                    $emitter->mov_reg( $dest, $lhs );
                }
                else {
                    $string_literals{ $instr->dest } = $instr->lhs;
                    $string_offsets{ $instr->dest } = $data_offset;
                    $data_offset += length($instr->lhs) + 1;
                }
            }
            else {
                $emitter->mov_reg( $dest, $lhs );
                if    ( $instr->op eq '+' ) { $emitter->add_imm( $dest, $rhs ) }
                elsif ( $instr->op eq '-' ) { $emitter->sub_imm( $dest, $rhs ) }
            }
        }
        elsif ( $instr->isa('Brocken::IR::Store') ) {
            my $src = $self->_get_reg( $instr->src );
            if ( $src ne 'stack' && $src !~ /^\d+$/ ) {
                $emitter->push_reg($src);
            }
        }
        elsif ( $instr->isa('Brocken::IR::Load') ) {
            my $dest = $self->_get_reg( $instr->dest );
            if ( $dest ne 'stack' ) {
                $emitter->pop_reg($dest);
            }
            else {
                my $sp = $arch eq 'x64' ? 'rsp' : 'sp';
                $emitter->add_imm( $sp, 8 );
            }
        }
        elsif ( $instr->isa('Brocken::IR::Call') ) {
            if ( $instr->func eq 'print' ) {
                my $arg = $instr->args->[0]      // '';
                my $str = $string_literals{$arg} // '';
                my $off = $string_offsets{$arg}  // 0;
                $emitter->emit_print_str( $os, $off, length($str) );
            }
            elsif ( $instr->func eq 'say' ) {
                my $arg = $instr->args->[0]      // '';
                my $str = $string_literals{$arg} // '';
                my $off = $string_offsets{$arg}  // 0;
                if ( $str ne '' ) {
                    $emitter->emit_print_str( $os, $off, length($str) );
                }
                if ( !exists $string_literals{'__SAY_NL__'} ) {
                    $string_literals{'__SAY_NL__'} = "\n";
                    $string_offsets{'__SAY_NL__'} = $data_offset;
                    $data_offset += 2;
                }
                $emitter->emit_print_str( $os, $string_offsets{'__SAY_NL__'}, 1 );
            }
            elsif ( $instr->func eq 'spawn_thread' ) {
                my $arg         = $instr->args->[0]      // '';
                my $entry_label = $string_literals{$arg} // '';
                my $text_rva    = $os->text_rva;
                my $dest_reg    = $self->_get_reg( $instr->dest );
                if ( $os->name eq 'win64' ) {
                    if ( $arch eq 'arm64' ) {
                        $emitter->mov_imm( 'x0', 0 );
                        $emitter->mov_imm( 'x1', 0x40000 );
                        $emitter->lea_rva( 'x2', $entry_label, $text_rva );
                        $emitter->mov_imm( 'x3', 0 );
                        $emitter->mov_imm( 'x4', 0 );
                        $emitter->mov_imm( 'x5', 0 );
                        $emitter->call_rva( $os->symbol_rva('CreateThread'), $text_rva );
                        $emitter->mov_reg( $dest_reg, 'x0' );
                    }
                    else {
                        $emitter->sub_imm( 'rsp', 32 );
                        $emitter->mov_imm( 'rcx', 0 );
                        $emitter->mov_imm( 'rdx', 0x40000 );
                        $emitter->lea_rva( 'r8', $entry_label, $text_rva );
                        $emitter->mov_imm( 'r9',  0 );
                        $emitter->mov_imm( 'r10', 0 );
                        $emitter->store_mem_disp_reg( 'rsp', 32, 'r10' );
                        $emitter->store_mem_disp_reg( 'rsp', 40, 'r10' );
                        $emitter->call_rva( $os->symbol_rva('CreateThread'), $text_rva );
                        $emitter->mov_reg( $dest_reg, 'rax' );
                        $emitter->add_imm( 'rsp', 32 );
                    }
                }
                elsif ( $os->name eq 'linux' ) {
                    my $mmap_num   = $os->syscall_mmap($arch);
                    my $clone_num  = $os->syscall_clone($arch);
                    my $ret_reg    = $os->syscall_ret_reg($arch);
                    my $stack_size = 0x100000;
                    my $flags      = 0x250F00;
                    if ( $arch eq 'x64' ) {
                        $os->write_mmap_args( $emitter, $arch, $stack_size );
                        $emitter->emit_syscall($mmap_num);
                        $emitter->mov_reg( 'rbp', $ret_reg );
                        $emitter->mov_imm( 'rdi', $flags );
                        $emitter->lea_reg_disp( 'rsi', 'rbp', $stack_size );
                        $emitter->mov_imm( 'rdx', 0 );
                        $emitter->mov_reg( 'r10', 'rbp' );     # child_clear_tid
                        $emitter->mov_imm( 'r8',  0 );         # tls = 0
                        $emitter->emit_syscall($clone_num);
                        $emitter->emit_branch_if_zero( $ret_reg, $entry_label );
                        $emitter->mov_reg( $dest_reg, 'rbp' );
                    }
                    else {
                        $emitter->emit_syscall( $os->syscall_fork($arch), 17, 0 );
                        $emitter->emit_branch_if_zero( $ret_reg, $entry_label );
                        $emitter->mov_reg( $dest_reg, $ret_reg );
                    }
                }
                elsif ( $os->name eq 'macos' ) {
                    my $fork_num   = $os->syscall_fork($arch);
                    my $getpid_num = $os->syscall_getpid($arch);
                    my $ret_reg    = $os->syscall_ret_reg($arch);
                    if ( $arch eq 'x64' ) {
                        $emitter->emit_syscall($fork_num);
                        $emitter->mov_reg( 'rbp', $ret_reg );
                        $emitter->emit_branch_if_zero( 'rbp', $entry_label );
                        $emitter->emit_syscall($getpid_num);
                        $emitter->cmp_reg_reg( $ret_reg, 'rbp' );
                        $emitter->jcc( 4, $entry_label );
                        $emitter->mov_reg( $dest_reg, 'rbp' );
                    }
                    else {
                        $emitter->emit_syscall($fork_num);
                        $emitter->mov_reg( 'x19', $ret_reg );
                        $emitter->emit_branch_if_zero( 'x19', $entry_label );
                        $emitter->emit_syscall($getpid_num);
                        $emitter->cmp_reg_reg( $ret_reg, 'x19' );
                        $emitter->jcc( 0, $entry_label );
                        $emitter->mov_reg( $dest_reg, 'x19' );
                    }
                }
                else {
                    my $syscall_num;
                    my @syscall_args;
                    if ($os->name eq 'openbsd') {
                        $syscall_num = $os->syscall_tfork($arch);
                    } else {
                        $syscall_num = $os->syscall_fork($arch);
                    }
                    if ( !defined $syscall_num ) {
                        die "spawn_thread not implemented on ${\$os->name}";
                    }
                    my $ret_reg = $os->syscall_ret_reg($arch);
                    $emitter->emit_syscall( $syscall_num, @syscall_args );
                    $emitter->emit_branch_if_zero( $ret_reg, $entry_label );
                    $emitter->mov_reg( $dest_reg, $ret_reg );
                }
            }
            elsif ( $instr->func eq 'sleep' ) {
                my $arg = $instr->args->[0] // '';
                if ( $os->name eq 'win64' ) {
                    $emitter->sub_imm( 'rsp', 32 );
                    if ( $arg =~ /^\d+$/ ) {
                        $emitter->mov_imm( 'rcx', $arg * 1000 );
                    }
                    else {
                        my $arg_reg = $self->_get_reg($arg);
                        $emitter->mov_imm( 'rcx', 1000 );
                        $emitter->mul_reg( 'rcx', $arg_reg );
                    }
                    $emitter->call_rva( $os->symbol_rva('Sleep'), $os->text_rva );
                    $emitter->add_imm( 'rsp', 32 );
                }
                elsif ( $os->is_posix ) {
                    my $num = $os->syscall_nanosleep($arch);
                    if ( defined $num ) {
                        $emitter->alloc_stack(16);
                        if ( $arg =~ /^\d+$/ ) {
                            $emitter->mov_imm( 'r10', $arg );
                        }
                        else {
                            my $arg_reg = $self->_get_reg($arg);
                            $emitter->mov_reg( 'r10', $arg_reg );
                        }
                        $emitter->store_mem_disp_reg( 'rsp', 0, 'r10' );  # tv_sec
                        $emitter->mov_imm( 'r10', 0 );
                        $emitter->store_mem_disp_reg( 'rsp', 8, 'r10' );  # tv_nsec = 0
                        $emitter->mov_reg( 'rdi', 'rsp' );                 # req = &timespec
                        $emitter->mov_imm( 'rsi', 0 );                     # rem = NULL
                        $emitter->mov_imm( 'rax', $num );                   # syscall number
                        $emitter->syscall();
                        $emitter->add_imm( 'rsp', 16 );
                    }
                }
            }
            elsif ( $instr->func eq 'join_thread' ) {
                my $arg_vreg  = $instr->args->[0] // '';
                my $arg_reg   = $self->_get_reg($arg_vreg);
                my $text_rva  = $os->text_rva;
                if ( $os->name eq 'win64' ) {
                    if ( $arch eq 'arm64' ) {
                        $emitter->mov_reg( 'x0', $arg_reg );
                        $emitter->mov_imm( 'x1', 0xFFFFFFFF );
                        $emitter->call_rva( $os->symbol_rva('WaitForSingleObject'), $text_rva );
                    }
                    else {
                        $emitter->sub_imm( 'rsp', 32 );
                        $emitter->mov_reg( 'rcx', $arg_reg );
                        $emitter->mov_imm( 'rdx', 0xFFFFFFFF );
                        $emitter->call_rva( $os->symbol_rva('WaitForSingleObject'), $text_rva );
                        $emitter->add_imm( 'rsp', 32 );
                    }
                }
                elsif ( $os->name eq 'linux' ) {
                    my $futex_num = $os->syscall_futex($arch);
                    if ( $arch eq 'x64' ) {
                        $emitter->mov_reg( 'rdi', $arg_reg );
                        $emitter->mov_imm( 'rsi', 0 );
                        $emitter->load_reg_mem( 'rdx', $arg_reg );
                        $emitter->mov_imm( 'r10', 0 );
                        $emitter->mov_imm( 'r8', 0 );
                        $emitter->mov_imm( 'r9', 0 );
                        $emitter->emit_syscall($futex_num);
                    }
                    else {
                        my $wait4_num = $os->syscall_wait4($arch);
                        $emitter->emit_syscall( $wait4_num, $arg_reg, 0, 0, 0 );
                    }
                }
                else {
                    my $wait_num = ($os->name eq 'macos') ? $os->syscall_waitpid($arch) : $os->syscall_wait4($arch);
                    if ($os->name eq 'haiku') {
                         # _kern_wait_for_child(team_id, status, options)
                         # If it fails, maybe status_ptr needs to be valid?
                         $emitter->emit_syscall( $wait_num, $arg_reg, 0, 0, 0 );
                    } else {
                         $emitter->emit_syscall( $wait_num, $arg_reg, 0, 0, 0 );
                    }
                }
            }
        }
        elsif ( $instr->isa('Brocken::IR::Jump') ) {
            $emitter->jmp( $instr->label );
        }
        elsif ( $instr->isa('Brocken::IR::Branch') ) {
            $emitter->jcc( 0, $instr->label );
        }
        elsif ( $instr->isa('Brocken::IR::Return') ) {
            my $val = $instr->val;
            if ( defined $val && $val eq 'EXIT_THREAD' ) {
                if ( $os->is_posix ) {
                    $emitter->emit_exit_proc( $os, 0 );
                }
                elsif ( $arch eq 'arm64' ) {
                    $emitter->mov_imm( 'x0', 0 );
                    $emitter->call_rva( $os->symbol_rva('ExitThread'), $os->text_rva );
                }
                else {
                    $emitter->ret();
                }
            }
            elsif ( $emitter->can('emit_exit_proc') ) {
                $emitter->emit_exit_proc( $os, 0 );
            }
            else {
                $emitter->ret();
            }
        }
        elsif ( $instr->isa('Brocken::IR::RefInc') || $instr->isa('Brocken::IR::RefDec') ) {

            # Skip for now
        }
    }

    method data_segment() {
        my $data = '';
        for my $vreg ( sort { $string_offsets{$a} <=> $string_offsets{$b} } keys %string_offsets ) {
            $data .= $string_literals{$vreg} . "\0";
        }
        return $data;
    }

    method _get_reg($vreg) {
        return $vreg if $vreg =~ /^\d+$/;    # It's an immediate
        return $mapping->{$vreg} // 'stack';
    }
}
1;
