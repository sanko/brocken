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
    field $current_is_thread = 0;
    method _new_label() { return "ISL" . $label_count++ }

    method select($cfg) {
        %var_slots    = ();
        $var_count    = 0;
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
                    my $arg         = $instr->args->[0];
                    my $entry_label = $string_literals{$arg};
                    push @thread_labels, $entry_label if $entry_label;
                }
            }
        }
        my $var_space = $var_count * 8;
        $var_space = ( $var_space + 15 ) & ~15 if $arch eq 'arm64';
        my %var_current_src;

        # Mark all blocks belonging to threads
        my %is_thread_block;
        for my $entry_label (@thread_labels) {
            my @worklist = ($entry_label);
            while (@worklist) {
                my $name = shift @worklist;
                next if $is_thread_block{$name};
                $is_thread_block{$name} = 1;
                my $block = $cfg->get_block($name);
                if ( $block && $block->terminator ) {
                    if ( $block->terminator->isa('Brocken::IR::Jump') ) {
                        push @worklist, $block->terminator->label;
                    }
                    elsif ( $block->terminator->isa('Brocken::IR::Branch') ) {
                        push @worklist, $block->terminator->label;
                    }
                }
            }
        }
        for my $block ( $cfg->blocks ) {
            $current_is_thread = $is_thread_block{ $block->name } // 0;
            my $is_thread_start = grep { $_ eq $block->name } @thread_labels;
            $emitter->mark_label( $block->name );
            if ( $var_space > 0 && ( $block->name eq 'entry' || $is_thread_start ) ) {
                my $fp = $os->frame_reg($arch);
                my $sp = $os->stack_reg($arch);
                $emitter->push_reg($fp);
                $emitter->mov_reg( $fp, $sp );
                $emitter->sub_imm( $sp, $var_space );
            }
            for my $instr ( $block->instructions ) {
                if ( $instr->isa('Brocken::IR::Store') ) {
                    $var_current_src{ $instr->var } = $instr->src;
                }
                if ( $instr->isa('Brocken::IR::Load') && exists $var_current_src{ $instr->var } ) {
                    my $src = $var_current_src{ $instr->var };
                    if ( exists $string_literals{$src} ) {
                        $string_literals{ $instr->dest } = $string_literals{$src};
                        $string_origins{ $instr->dest }  = $src;
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
        return defined $slot ? -( ( $slot + 1 ) * 8 ) : 0;
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
                    $string_offsets{ $instr->dest }  = $data_offset;
                    $data_offset += length( $instr->lhs ) + 1;
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
            elsif ( $instr->op eq '!' ) {
                if ( $lhs =~ /^-?\d+$/ ) {
                    $emitter->mov_imm( $dest, $lhs == 0 ? 1 : 0 );
                }
                else {
                    my $l_not_done = $self->_new_label();
                    $emitter->mov_imm( $dest, 1 );
                    $emitter->emit_branch_if_zero( $lhs, $l_not_done );
                    $emitter->mov_imm( $dest, 0 );
                    $emitter->mark_label($l_not_done);
                }
            }
            else {
                my $lhs_is_imm = $lhs =~ /^-?\d+$/;
                my $rhs_is_imm = $rhs =~ /^-?\d+$/;
                my %cmp_cc     = ( '<' => 0x9C, '>' => 0x9F, '<=' => 0x9E, '>=' => 0x9D, '==' => 0x94, '!=' => 0x95 );
                my %cmp_inv    = ( '<' => 0x9F, '>' => 0x9C, '<=' => 0x9D, '>=' => 0x9E, '==' => 0x94, '!=' => 0x95 );
                my $cc         = $cmp_cc{ $instr->op };
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
                        $emitter->setcc( $cmp_inv{ $instr->op }, $dest );
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
                $emitter->store_mem_disp_reg( $os->frame_reg($arch), $off, $src );
            }
        }
        elsif ( $instr->isa('Brocken::IR::Load') ) {
            my $dest = $self->_get_reg( $instr->dest );
            if ( $dest ne 'stack' ) {
                my $off = $self->_var_offset( $instr->var );
                $emitter->load_reg_mem( $dest, $os->frame_reg($arch), $off );
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
                    $string_offsets{'__SAY_NL__'}  = $data_offset;
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
                    my $flags      = 0x00010900;
                    if ( $arch eq 'x64' ) {
                        $os->write_mmap_args( $emitter, $arch, $stack_size );
                        $emitter->emit_syscall($mmap_num);
                        $emitter->push_reg('rbp');
                        $emitter->mov_reg( 'rbp', $ret_reg );
                        $emitter->mov_imm( 'rdi', $flags );
                        $emitter->lea_reg_disp( 'rsi', 'rbp', $stack_size );
                        $emitter->mov_imm( 'rdx', 0 );
                        $emitter->mov_reg( 'r10', 'rbp' );
                        $emitter->mov_imm( 'r8', 0 );
                        $emitter->emit_syscall($clone_num);
                        $emitter->emit_branch_if_zero( $ret_reg, $entry_label );
                        $emitter->mov_reg( $dest_reg, 'rbp' );
                        $emitter->pop_reg('rbp');
                    }
                    elsif ( $arch eq 'arm64' ) {
                        my $mmap_num   = $os->syscall_mmap($arch);
                        my $clone_num  = $os->syscall_clone($arch);
                        my $ret_reg    = $os->syscall_ret_reg($arch);
                        my $stack_size = 0x100000;
                        my $flags      = 0x210900;
                        $os->write_mmap_args( $emitter, $arch, $stack_size );
                        $emitter->emit_syscall($mmap_num);
                        $emitter->mov_reg( 'x19', $ret_reg );
                        $emitter->mov_imm( 'x0', $flags );
                        $emitter->lea_reg_disp( 'x1', 'x19', $stack_size );
                        $emitter->mov_imm( 'x2', 0 );
                        $emitter->mov_reg( 'x3', 'x19' );
                        $emitter->mov_imm( 'x4', 0 );
                        $emitter->emit_syscall($clone_num);
                        $emitter->emit_branch_if_zero( 'x0', $entry_label );
                        $emitter->mov_reg( $dest_reg, 'x19' );
                    }
                    else {
                        $emitter->emit_syscall( $os->syscall_fork($arch), 17, 0 );
                        $emitter->emit_branch_if_zero( $ret_reg, $entry_label );
                        $emitter->mov_reg( $dest_reg, $ret_reg );
                    }
                }
                elsif ( $os->name eq 'macos' ) {
                    my $fork_num = $os->syscall_fork($arch);
                    my $ret_reg  = $os->syscall_ret_reg($arch);
                    my $nr       = $os->syscall_num_reg($arch);
                    $emitter->mov_imm( $nr, $fork_num );
                    $emitter->syscall( $os->name, $fork_num );

                    # On macOS, rax is child PID in both parent and child,
                    # but rdx is 1 in child and 0 in parent.
                    if ( $arch eq 'x64' ) {
                        $emitter->test_reg_reg( 'rdx', 'rdx' );
                        $emitter->jcc( 5, $entry_label );    # JNZ -> child
                    }
                    elsif ( $arch eq 'arm64' ) {
                        $emitter->cmp_reg_imm( 'x1', 0 );
                        $emitter->emit_branch_if_not_zero( 'x1', $entry_label );
                    }
                    else {
                        $emitter->emit_branch_if_zero( $ret_reg, $entry_label );
                    }
                    $emitter->mov_reg( $dest_reg, $ret_reg );
                }
                else {
                    my $syscall_num = $os->syscall_fork($arch);
                    if ( !defined $syscall_num ) {
                        die "spawn_thread not implemented on ${\$os->name}";
                    }
                    my $ret_reg = $os->syscall_ret_reg($arch);
                    $emitter->mov_imm( $os->syscall_num_reg($arch), $syscall_num );
                    $emitter->syscall( $os->name, $syscall_num );
                    $emitter->emit_branch_if_zero( $ret_reg, $entry_label );
                    $emitter->mov_reg( $dest_reg, $ret_reg );
                }
            }
            elsif ( $instr->func eq 'sleep' ) {
                my $arg = $instr->args->[0] // '';
                if ( $os->name eq 'haiku' ) {
                    my $num = $os->syscall_snooze($arch);
                    if ( defined $num ) {
                        my $arg_reg_name = $os->syscall_exit_arg_reg($arch);
                        if ( $arg =~ /^\d+$/ ) {
                            $emitter->mov_imm( $arg_reg_name, $arg * 1000000 );
                        }
                        else {
                            my $arg_reg = $self->_get_reg($arg);
                            my $tmp_reg = $arch eq 'x64' ? 'rax' : ( $arch eq 'arm64' ? 'x1' : 't0' );
                            if ( $arg_reg eq $arg_reg_name ) {
                                $emitter->mov_reg( $tmp_reg, $arg_reg_name );
                                $arg_reg = $tmp_reg;
                            }
                            $emitter->mov_imm( $arg_reg_name, 1000000 );
                            $emitter->mul_reg( $arg_reg_name, $arg_reg );
                        }
                        my $nr = $os->syscall_num_reg($arch);
                        $emitter->mov_imm( $nr, $num ) if defined $nr;
                        $emitter->syscall( $os->name, $num );
                    }
                }
                elsif ( $os->name eq 'win64' ) {
                    if ( $arch eq 'arm64' ) {
                        if ( $arg =~ /^\d+$/ ) {
                            $emitter->mov_imm( 'x0', $arg * 1000 );
                        }
                        else {
                            my $arg_reg = $self->_get_reg($arg);
                            if ( $arg_reg eq 'x0' ) {
                                $emitter->mov_reg( 'x1', 'x0' );
                                $arg_reg = 'x1';
                            }
                            $emitter->mov_imm( 'x0', 1000 );
                            $emitter->mul_reg( 'x0', $arg_reg );
                        }
                        $emitter->call_rva( $os->symbol_rva('Sleep'), $os->text_rva );
                    }
                    else {
                        $emitter->sub_imm( 'rsp', 0x28 );
                        if ( $arg =~ /^\d+$/ ) {
                            $emitter->mov_imm( 'rcx', $arg * 1000 );
                        }
                        else {
                            my $arg_reg = $self->_get_reg($arg);
                            if ( $arg_reg eq 'rcx' ) {
                                $emitter->mov_reg( 'rax', 'rcx' );
                                $arg_reg = 'rax';
                            }
                            $emitter->mov_imm( 'rcx', 1000 );
                            $emitter->mul_reg( 'rcx', $arg_reg );
                        }
                        $emitter->call_rva( $os->symbol_rva('Sleep'), $os->text_rva );
                        $emitter->add_imm( 'rsp', 0x28 );
                    }
                }
                elsif ( $os->is_posix ) {
                    my $num = $os->syscall_nanosleep($arch);
                    if ( defined $num ) {
                        if ( $arch eq 'arm64' ) {
                            my $tmp = 'x10';
                            $emitter->push_reg($tmp);
                            if ( $arg =~ /^\d+$/ ) {
                                $emitter->mov_imm( $tmp, $arg );
                            }
                            else {
                                my $arg_reg = $self->_get_reg($arg);
                                $emitter->mov_reg( $tmp, $arg_reg ) if $arg_reg ne $tmp;
                            }
                            $emitter->sub_imm( 'sp', 16 );
                            $emitter->store_mem_disp_reg( 'sp', 0, $tmp );
                            $emitter->mov_imm( $tmp, 0 );
                            $emitter->store_mem_disp_reg( 'sp', 8, $tmp );
                            $emitter->mov_reg( 'x0', 'sp' );
                            $emitter->mov_imm( 'x1', 0 );
                            my $nr = $os->syscall_num_reg($arch);
                            $emitter->mov_imm( $nr, $num ) if defined $nr;
                            $emitter->syscall( $os->name, $num );
                            $emitter->add_imm( 'sp', 16 );
                            $emitter->pop_reg($tmp);
                        }
                        elsif ( $arch eq 'riscv64' ) {
                            my $tmp = 't0';
                            $emitter->push_reg($tmp);
                            if ( $arg =~ /^\d+$/ ) {
                                $emitter->mov_imm( $tmp, $arg );
                            }
                            else {
                                my $arg_reg = $self->_get_reg($arg);
                                $emitter->mov_reg( $tmp, $arg_reg ) if $arg_reg ne $tmp;
                            }
                            $emitter->sub_imm( 'sp', 16 );
                            $emitter->store_mem_disp_reg( 'sp', 0, $tmp );
                            $emitter->mov_imm( $tmp, 0 );
                            $emitter->store_mem_disp_reg( 'sp', 8, $tmp );
                            $emitter->mov_reg( 'a0', 'sp' );
                            $emitter->mov_imm( 'a1', 0 );
                            my $nr = $os->syscall_num_reg($arch);
                            $emitter->mov_imm( $nr, $num ) if defined $nr;
                            $emitter->syscall( $os->name, $num );
                            $emitter->add_imm( 'sp', 16 );
                            $emitter->pop_reg($tmp);
                        }
                        else {
                            my $tmp = 'r10';
                            $emitter->push_reg($tmp);
                            if ( $arg =~ /^\d+$/ ) {
                                $emitter->mov_imm( $tmp, $arg );
                            }
                            else {
                                my $arg_reg = $self->_get_reg($arg);
                                $emitter->mov_reg( $tmp, $arg_reg ) if $arg_reg ne $tmp;
                            }
                            $emitter->sub_imm( 'rsp', 16 );
                            $emitter->store_mem_disp_reg( 'rsp', 0, $tmp );
                            $emitter->mov_imm( $tmp, 0 );
                            $emitter->store_mem_disp_reg( 'rsp', 8, $tmp );
                            $emitter->mov_reg( 'rdi', 'rsp' );
                            $emitter->mov_imm( 'rsi', 0 );
                            my $nr = $os->syscall_num_reg($arch);
                            $emitter->mov_imm( $nr, $num ) if defined $nr;
                            $emitter->syscall( $os->name, $num );
                            $emitter->add_imm( 'rsp', 16 );
                            $emitter->pop_reg($tmp);
                        }
                    }
                }
            }
            elsif ( $instr->func eq 'join_thread' ) {
                my $arg_vreg = $instr->args->[0] // '';
                my $arg_reg  = $self->_get_reg($arg_vreg);
                my $text_rva = $os->text_rva;
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
                    if ( $arch eq 'x64' ) {
                        my $join_loop = $self->_new_label();
                        my $join_done = $self->_new_label();
                        $emitter->mark_label($join_loop);
                        $emitter->load_reg_mem( 'rdx', $arg_reg );
                        $emitter->cmp_reg_imm( 'rdx', 0 );
                        $emitter->jcc( 5, $join_done );
                        $emitter->pause();
                        $emitter->jmp($join_loop);
                        $emitter->mark_label($join_done);
                    }
                    elsif ( $arch eq 'arm64' ) {
                        my $join_loop = $self->_new_label();
                        my $join_done = $self->_new_label();
                        $emitter->mark_label($join_loop);
                        $emitter->load_reg_mem( 'x10', $arg_reg );
                        $emitter->cmp_reg_imm( 'x10', 0 );
                        $emitter->jcc( 5, $join_done );
                        $emitter->jmp($join_loop);
                        $emitter->mark_label($join_done);
                    }
                    else {
                        my $wait4_num = $os->syscall_wait4($arch);
                        $emitter->emit_syscall( $wait4_num, $arg_reg, 0, 0, 0 );
                    }
                }
                else {
                    my $wait_num = ( $os->name eq 'macos' ) ? $os->syscall_waitpid($arch) : $os->syscall_wait4($arch);
                    if ( $os->name eq 'haiku' ) {
                        $emitter->emit_syscall( $wait_num, $arg_reg, 0, 0, 0 );
                    }
                    else {
                        $emitter->emit_syscall( $wait_num, $arg_reg, 0, 0, 0 );
                    }
                }
            }
            elsif ( $instr->func eq 'exit' || $instr->func eq 'die' ) {
                my $arg    = $instr->args->[0] // '';
                my $is_die = $instr->func eq 'die';
                if ( $os->is_posix ) {
                    my $num = $os->syscall_exit($arch);
                    if ( defined $num ) {
                        my $exit_reg = $os->syscall_exit_arg_reg($arch);
                        my $nr       = $os->syscall_num_reg($arch);
                        if ($is_die) {
                            $emitter->mov_imm( $exit_reg, 1 );
                        }
                        elsif ( $arg =~ /^\d+$/ ) {
                            $emitter->mov_imm( $exit_reg, $arg );
                        }
                        elsif ( defined $const_values{$arg} ) {
                            $emitter->mov_imm( $exit_reg, $const_values{$arg} );
                        }
                        else {
                            my $arg_reg = $self->_get_reg($arg);
                            if ( $arg_reg ne $exit_reg ) {
                                $emitter->mov_reg( $exit_reg, $arg_reg );
                            }
                        }
                        if ( defined $nr ) {
                            $emitter->mov_imm( $nr, $num );
                        }
                        $emitter->syscall( $os->name, $num );
                        $emitter->halt();
                    }
                }
                else {
                    my $code_val = ( $arg =~ /^\d+$/ ) ? $arg : ( defined $const_values{$arg} ? $const_values{$arg} : 42 );
                    $code_val = $is_die ? 1 : $code_val;
                    $emitter->emit_exit_proc( $os, $code_val );
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
                my $tr = $arch eq 'x64' ? 'r10' : $arch eq 'arm64' ? 'x10' : 't0';
                $emitter->load_reg_mem( $tr, $os->frame_reg($arch), 0 );
                $emitter->cmp_reg_imm( $tr, 0 );
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
                my $fp = $os->frame_reg($arch);
                my $sp = $os->stack_reg($arch);
                $emitter->mov_reg( $sp, $fp );
                $emitter->pop_reg($fp);
            }
            my $val = $instr->val;
            if ( defined $val && $val eq 'EXIT_THREAD' ) {
                if ( $os->is_posix ) {
                    if ( $os->name eq 'linux' ) {
                        if ( $arch eq 'x64' ) {
                            $emitter->mov_imm( 'rcx', 1 );
                            $emitter->store_mem_disp_reg( 'rbp', 0, 'rcx' );
                        }
                        elsif ( $arch eq 'arm64' ) {
                            $emitter->mov_imm( 'x10', 1 );
                            $emitter->store_mem_disp_reg( 'x19', 0, 'x10' );
                        }
                    }
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
                if ( $current_is_thread && $os->name eq 'win64' ) {
                    if ( $arch eq 'x64' ) {
                        $emitter->sub_imm( 'rsp', 0x28 );
                        $emitter->mov_imm( 'rcx', 0 );
                        $emitter->call_rva( $os->symbol_rva('ExitThread'), $os->text_rva );
                        $emitter->add_imm( 'rsp', 0x28 );
                    }
                    elsif ( $arch eq 'arm64' ) {
                        $emitter->mov_imm( 'x0', 0 );
                        $emitter->call_rva( $os->symbol_rva('ExitThread'), $os->text_rva );
                    }
                    else {
                        $emitter->emit_exit_proc( $os, 0 );
                    }
                }
                else {
                    $emitter->emit_exit_proc( $os, 0 );
                }
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
