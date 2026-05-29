use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Target::OS;

class Brocken::Compiler::InstructionSelector {
    field $arch    : reader : param;
    field $mapping : reader : param;
    field $emitter : reader : param;
    field $os      : reader : param;
    field %string_literals;
    field %string_offsets;
    field $data_offset = 0;
    field %string_origins;
    field $label_count = 0;
    field %var_slots;
    field $var_count = 0;
    field %const_values;
    method _new_label() { return "ISL" . $label_count++ }

    method select($cfg) {
        %var_slots = ();
        $var_count = 0;
        %const_values = ();
        my @thread_labels;
        for my $block ( $cfg->blocks ) {
            for my $instr ( $block->instructions ) {
                if ( $instr->isa('Brocken::IR::Store') && !exists $var_slots{ $instr->var } ) {
                    $var_slots{ $instr->var } = $var_count++;
                }
                if ( $instr->isa('Brocken::IR::Load') && !exists $var_slots{ $instr->var } ) {
                    $var_slots{ $instr->var } = $var_count++;
                }
                if ( $instr->isa('Brocken::IR::Assign') && $instr->op eq '' && $instr->lhs !~ /^\d+$/ && $instr->lhs !~ /^v\d+$/ ) {
                    $string_literals{ $instr->dest } = $instr->lhs;
                }
                if ( $instr->isa('Brocken::IR::Assign') && $instr->op eq '' && $instr->lhs =~ /^-?\d+$/ ) {
                    $const_values{ $instr->dest } = $instr->lhs;
                }
                if ( $instr->isa('Brocken::IR::Call') && $instr->func eq 'spawn_thread' ) {
                    my $arg = $instr->args->[0];
                    my $entry_label = $string_literals{$arg};
                    push @thread_labels, $entry_label if $entry_label;
                }
            }
        }
        my $var_space = $var_count * 8;
        my %var_current_src;
        for my $block ( $cfg->blocks ) {
            my $is_thread_entry = grep { $_ eq $block->name } @thread_labels;
            $emitter->mark_label( $block->name );
            if ( $var_space > 0 && ( $block->name eq 'entry' || $is_thread_entry ) ) {
                $emitter->push_reg('rbp');
                $emitter->mov_reg( 'rbp', 'rsp' );
                $emitter->sub_imm( 'rsp', $var_space );
            }
            for my $instr ( $block->instructions ) {
                if ( $instr->isa('Brocken::IR::Store') ) {
                    $var_current_src{ $instr->var } = $instr->src;
                }
                if ( $instr->isa('Brocken::IR::Load') && exists $var_current_src{ $instr->var } ) {
                    my $src = $var_current_src{ $instr->var };
                    if ( exists $string_literals{$src} ) {
                        $string_literals{ $instr->dest } = $string_literals{$src};
                        $string_origins{ $instr->dest } = $src;
                    }
                    if ( exists $const_values{$src} ) {
                        $const_values{ $instr->dest } = $const_values{$src};
                    }
                }
                $self->_emit_instruction($instr);
            }
            if ( $block->terminator ) {
                $self->_emit_instruction( $block->terminator );
            }
        }
        $emitter->resolve();
        return $emitter->code;
    }

    method _var_offset($var) {
        my $slot = $var_slots{$var};
        return defined $slot ? -( ($slot + 1) * 8 ) : 0;
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
            elsif ( $instr->op eq '+' ) {
                $emitter->mov_reg( $dest, $lhs );
                if ( $rhs =~ /^-?\d+$/ ) {
                    $emitter->add_imm( $dest, $rhs );
                }
                else {
                    $emitter->add_reg( $dest, $rhs );
                }
            }
            elsif ( $instr->op eq '-' ) {
                $emitter->mov_reg( $dest, $lhs );
                if ( $rhs =~ /^-?\d+$/ ) {
                    $emitter->sub_imm( $dest, $rhs );
                }
                else {
                    $emitter->sub_reg( $dest, $rhs );
                }
            }
            else {
                my $lhs_is_imm = $lhs =~ /^-?\d+$/;
                my $rhs_is_imm = $rhs =~ /^-?\d+$/;
                my %cmp_cc = ( '<' => 0x9C, '>' => 0x9F, '<=' => 0x9E, '>=' => 0x9D, '==' => 0x94, '!=' => 0x95 );
                my %cmp_inv = ( '<' => 0x9F, '>' => 0x9C, '<=' => 0x9D, '>=' => 0x9E, '==' => 0x94, '!=' => 0x95 );
                my $cc = $cmp_cc{$instr->op};
                if ( defined $cc ) {
                    $emitter->mov_imm( $dest, 0 );
                    if ( !$lhs_is_imm && !$rhs_is_imm ) {
                        $emitter->cmp_reg_reg( $lhs, $rhs );
                        $emitter->setcc( $cc, $dest );
                    }
                    elsif ( !$lhs_is_imm && $rhs_is_imm ) {
                        $emitter->cmp_reg_imm( $lhs, $rhs );
                        $emitter->setcc( $cc, $dest );
                    }
                    elsif ( $lhs_is_imm && !$rhs_is_imm ) {
                        $emitter->cmp_reg_imm( $rhs, $lhs );
                        $emitter->setcc( $cmp_inv{$instr->op}, $dest );
                    }
                    else {
                        $emitter->mov_imm( $dest, $lhs < $rhs ? 1 : 0 );
                    }
                }
            }
        }
        elsif ( $instr->isa('Brocken::IR::Store') ) {
            my $src = $self->_get_reg( $instr->src );
            if ( $src ne 'stack' && $src !~ /^\d+$/ ) {
                my $off = $self->_var_offset( $instr->var );
                $emitter->store_mem_disp_reg( 'rbp', $off, $src );
            }
        }
        elsif ( $instr->isa('Brocken::IR::Load') ) {
            my $dest = $self->_get_reg( $instr->dest );
            if ( $dest ne 'stack' ) {
                my $off = $self->_var_offset( $instr->var );
                $emitter->load_reg_mem( $dest, 'rbp', $off );
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
                my $src = $string_origins{$arg}  // $arg;
                my $off = $string_offsets{$src}  // 0;
                $emitter->emit_print_str( $os, $off, length($str) );
            }
            elsif ( $instr->func eq 'say' ) {
                my $arg = $instr->args->[0]      // '';
                my $str = $string_literals{$arg} // '';
                my $src = $string_origins{$arg}  // $arg;
                my $off = $string_offsets{$src}  // 0;
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
                $emitter->sub_imm( 'rsp', 0x28 );
                $emitter->mov_imm( 'rcx', 0 );
                $emitter->mov_imm( 'rdx', 0x40000 );
                $emitter->lea_rva( 'r8', $entry_label, $text_rva );
                $emitter->mov_imm( 'r9',  0 );
                $emitter->mov_imm( 'r10', 0 );
                $emitter->store_mem_disp_reg( 'rsp', 32, 'r10' );
                $emitter->store_mem_disp_reg( 'rsp', 40, 'r10' );
                $emitter->call_rva( $os->symbol_rva('CreateThread'), $text_rva );
                $emitter->mov_reg( $dest_reg, 'rax' );
                $emitter->add_imm( 'rsp', 0x28 );
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
                        $emitter->mov_reg( 'r10', 'rbp' );
                        $emitter->mov_imm( 'r8',  0 );
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
                    $emitter->sub_imm( 'rsp', 0x28 );
                    if ( $arg =~ /^\d+$/ ) {
                        $emitter->mov_imm( 'rcx', $arg * 1000 );
                    }
                    else {
                        my $arg_reg = $self->_get_reg($arg);
                        $emitter->mov_imm( 'rcx', 1000 );
                        $emitter->mul_reg( 'rcx', $arg_reg );
                    }
                    $emitter->call_rva( $os->symbol_rva('Sleep'), $os->text_rva );
                    $emitter->add_imm( 'rsp', 0x28 );
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
                        $emitter->store_mem_disp_reg( 'rsp', 0, 'r10' );
                        $emitter->mov_imm( 'r10', 0 );
                        $emitter->store_mem_disp_reg( 'rsp', 8, 'r10' );
                        $emitter->mov_reg( 'rdi', 'rsp' );
                        $emitter->mov_imm( 'rsi', 0 );
                        $emitter->mov_imm( 'rax', $num );
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
                        $emitter->sub_imm( 'rsp', 0x28 );
                        $emitter->mov_reg( 'rcx', $arg_reg );
                        $emitter->mov_imm( 'rdx', 0xFFFFFFFF );
                        $emitter->call_rva( $os->symbol_rva('WaitForSingleObject'), $text_rva );
                        $emitter->add_imm( 'rsp', 0x28 );
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
                         $emitter->emit_syscall( $wait_num, $arg_reg, 0, 0, 0 );
                    } else {
                         $emitter->emit_syscall( $wait_num, $arg_reg, 0, 0, 0 );
                    }
                }
            }
        elsif ( $instr->func eq 'exit' || $instr->func eq 'die' ) {
            my $arg    = $instr->args->[0] // '';
            my $is_die = $instr->func eq 'die';
            if ( $os->name eq 'win64' ) {
                $emitter->sub_imm( 'rsp', 0x28 );
                my $code_val = ($arg =~ /^\d+$/) ? $arg : (defined $const_values{$arg} ? $const_values{$arg} : 42);
                $emitter->mov_imm( 'rcx', $code_val );
                $emitter->call_rva( $os->symbol_rva('ExitProcess'), $os->text_rva );
                }
                elsif ( $os->is_posix ) {
                    my $num = $os->syscall_exit($arch);
                    if ( defined $num ) {
                        if ( $arg =~ /^\d+$/ ) {
                            $emitter->mov_imm( 'rdi', $is_die ? 1 : $arg );
                        }
                        else {
                            my $arg_reg = $self->_get_reg($arg);
                            if ($is_die) {
                                $emitter->mov_imm( 'rdi', 1 );
                            }
                            else {
                                $emitter->mov_reg( 'rdi', $arg_reg );
                            }
                        }
                        $emitter->mov_imm( 'rax', $num );
                        $emitter->syscall();
                    }
                }
            }
            else {
                die "Unimplemented function call: " . $instr->func;
            }
        }
        elsif ( $instr->isa('Brocken::IR::Jump') ) {
            $emitter->jmp( $instr->label );
        }
        elsif ( $instr->isa('Brocken::IR::Branch') ) {
            my $cond = $self->_get_reg( $instr->cond );
            if ( $cond eq 'stack' ) {
                $emitter->load_reg_mem( 'r10', 'rbp', 0 );
                $emitter->cmp_reg_imm( 'r10', 0 );
                $emitter->jcc( 4, $instr->label );
            }
            elsif ( $cond =~ /^-?\d+$/ ) {
                $emitter->jmp( $instr->label ) if $cond == 0;
            }
            else {
                $emitter->cmp_reg_imm( $cond, 0 );
                $emitter->jcc( 4, $instr->label );
            }
        }
        elsif ( $instr->isa('Brocken::IR::Return') ) {
            if ( $var_count > 0 ) {
                $emitter->mov_reg( 'rsp', 'rbp' );
                $emitter->pop_reg('rbp');
            }
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
        }
        else {
            die "Cannot emit instruction: " . ref($instr);
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
        return $vreg if $vreg =~ /^\d+$/;
        return $mapping->{$vreg} // 'stack';
    }
}
1;
