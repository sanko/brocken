use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use List::Util ();

class Brocken::Jenny::RegAlloc::LiveInterval {
    field $name  : param : reader;
    field $start : param : reader;
    field $end   : param : reader;
}

class Brocken::Jenny::RegAlloc::LinearScan {

    method allocate( $mf, $platform, $is_float = 0 ) {
        $mf->compute_cfg unless $mf->entry_block->successors->@*;
        my @intervals = $self->_compute_live_intervals( $mf, $is_float );
        return $self->_linear_scan( \@intervals, $platform, $is_float );
    }

    method _vreg_name( $op, $is_float ) {
        return undef unless $op->kind eq 'virt_reg';
        my $type = $op->type;
        my $is_f = $type ? ( $type->kind eq 'float' ) : 0;
        return undef if $is_float != $is_f;
        return $op->value;
    }

    method _vreg_names_from_mem_operands($inst) {
        my @names;
        for my $op ( $inst->operands->@* ) {
            next unless $op->kind eq 'mem';
            my $base = $op->value->{base} // '';
            push @names, $base if $base =~ /^%/;
            my $index = $op->value->{index} // '';
            push @names, $index if $index =~ /^%/;
        }
        return @names;
    }

    method _register_operands($inst) {
        return $inst->operands->@*;
    }

    method _compute_live_intervals( $mf, $is_float ) {
        my @blocks = $mf->blocks->@*;
        my @bi_range;    # block_idx => [first_inst_idx, last_inst_idx]
        my $total_idx = 0;
        for my $bb (@blocks) {
            my $first = $total_idx;
            $total_idx += $bb->instructions->@*;
            push @bi_range, [ $first, $total_idx - 1 ];
        }

        # DEF[b] = vregs defined (written) in b
        # USE[b] = vregs used before any definition in b
        my %def;
        my %use;
        for my $bi ( 0 .. $#blocks ) {
            my $bb   = $blocks[$bi];
            my %defd = ();
            my %used = ();
            for my $inst ( $bb->instructions->@* ) {
                my @ops = $self->_register_operands($inst);
                for my $op (@ops) {
                    my $name = $self->_vreg_name( $op, $is_float );
                    next unless defined $name;
                    if ( $op == $ops[0] && $inst->opcode ne 'store' && $inst->opcode ne 'store_imm' ) {
                        $defd{$name} = 1 unless exists $used{$name};
                    }
                    else {
                        $used{$name} = 1 unless exists $defd{$name};
                    }
                }
                for my $base ( $self->_vreg_names_from_mem_operands($inst) ) {
                    next if $is_float;
                    $used{$base} = 1 unless exists $defd{$base};
                }
            }
            $def{$bi} = \%defd;
            $use{$bi} = \%used;
        }

        # Fixed-point liveness (backward dataflow)
        my %live_in;
        my %live_out;
        my $changed = 1;
        while ($changed) {
            $changed = 0;
            for my $bi ( reverse 0 .. $#blocks ) {
                my $bb = $blocks[$bi];
                my %new_out;
                for my $succ ( $bb->successors->@* ) {
                    my $si = 0;
                    for my $b (@blocks) { last if $b == $succ; $si++ }
                    for my $v ( keys %{ $live_in{$si} // {} } ) {
                        $new_out{$v} = 1;
                    }
                }
                if ( join( "\0", sort keys %new_out ) ne join( "\0", sort keys %{ $live_out{$bi} // {} } ) ) {
                    $changed = 1;
                    $live_out{$bi} = \%new_out;
                }
                my %new_in = ( %{ $use{$bi} } );
                for my $v ( keys %new_out ) {
                    $new_in{$v} = 1 unless $def{$bi}{$v};
                }
                if ( join( "\0", sort keys %new_in ) ne join( "\0", sort keys %{ $live_in{$bi} // {} } ) ) {
                    $changed = 1;
                    $live_in{$bi} = \%new_in;
                }
            }
        }

        # Build intervals from liveness info
        my %first;
        my %last;
        for my $bi ( 0 .. $#blocks ) {
            my $bb       = $blocks[$bi];
            my @insts    = $bb->instructions->@*;
            my $bi_first = $bi_range[$bi][0];
            my $bi_last  = $bi_range[$bi][1];
            for my $v ( keys %{ $live_in{$bi} // {} } ) {
                $first{$v} //= $bi_first;
                $last{$v} = List::Util::max( $last{$v} // 0, $bi_last );
            }
            for my $inst ( $bb->instructions->@* ) {
                for my $op ( $self->_register_operands($inst) ) {
                    my $name = $self->_vreg_name( $op, $is_float );
                    next unless defined $name;
                    $first{$name} = List::Util::min( $first{$name} // $total_idx, $bi_first );
                    $last{$name}  = List::Util::max( $last{$name}  // 0, $bi_first );
                }
                for my $base ( $self->_vreg_names_from_mem_operands($inst) ) {
                    next if $is_float;
                    $first{$base} = List::Util::min( $first{$base} // $total_idx, $bi_first );
                    $last{$base}  = List::Util::max( $last{$base}  // 0, $bi_first );
                }
                $bi_first++;
            }
            for my $v ( keys %{ $live_out{$bi} // {} } ) {
                $first{$v} //= $bi_range[$bi][0];
                $last{$v} = List::Util::max( $last{$v} // 0, $bi_range[$bi][1] );
            }
        }
        my @intervals;
        for my $name ( sort { $first{$a} <=> $first{$b} || $a cmp $b } keys %first ) {
            push @intervals, Brocken::Jenny::RegAlloc::LiveInterval->new( name => $name, start => $first{$name}, end => $last{$name} );
        }
        return @intervals;
    }

    method _linear_scan( $intervals, $platform, $is_float ) {
        my @caller_regs = $is_float ? $platform->fp_registers('caller')->@* : $platform->registers('caller')->@*;
        my @callee_regs = $is_float ? $platform->fp_registers('callee')->@* : $platform->registers('callee')->@*;
        my $skip_reg    = $is_float ? $platform->fp_return_register          : $platform->return_register;
        @caller_regs    = grep { $_ ne $skip_reg } @caller_regs;
        @callee_regs    = grep { $_ ne $skip_reg } @callee_regs;
        my $spill_temp  = pop @caller_regs;
        my @regs        = ( @caller_regs, @callee_regs );
        my %assignment;
        my %used_callee;
        my %spill_slots;
        my @active;
        my $next_spill = 0;

        for my $int ( $intervals->@* ) {
            @active = grep { $_->end >= $int->start } @active;
            if ( @active < @regs ) {
                my %taken;
                for my $a (@active) { $taken{ $assignment{ $a->name } } = 1 }
                my $free;
                for my $r (@regs) {
                    unless ( $taken{$r} ) { $free = $r; last }
                }
                $assignment{ $int->name } = $free;
                $used_callee{$free} = 1 if grep { $_ eq $free } @callee_regs;
                push @active, $int;
            }
            else {
                my ($spill) = sort { $b->end <=> $a->end } @active;
                my $freed_reg = $assignment{ $spill->name };
                $spill_slots{ $spill->name } = $next_spill++ * 8;
                $assignment{ $spill->name }  = 'spill(' . $spill_slots{ $spill->name } . ')';
                @active                      = grep { $_->name ne $spill->name } @active;
                $assignment{ $int->name }    = $freed_reg;
                $used_callee{$freed_reg}     = 1 if grep { $_ eq $freed_reg } @callee_regs;
                push @active, $int;
            }
        }
        return { assignment => \%assignment, used_callee => [ sort keys %used_callee ], spill_slots => \%spill_slots, spill_temp => $spill_temp, };
    }

    method insert_spill_code( $mf, $spill_slots, $spill_temp, $stack_reg, $is_float = 0 ) {
        return unless $spill_slots && keys %$spill_slots;
        my $load_op  = $is_float ? 'fload'  : 'load';
        my $store_op = $is_float ? 'fstore' : 'store';
        for my $vreg ( keys %$spill_slots ) {
            my $offset = $spill_slots->{$vreg};
            for my $bb ( $mf->blocks->@* ) {
                my @new;
                for my $inst ( $bb->instructions->@* ) {
                    my $opcode      = $inst->opcode;
                    my @ops         = $inst->operands->@*;
                    my $spilled_dst = 0;
                    my $spilled_src = 0;
                    my $spilled_mem = 0;
                    if ( @ops >= 1 && $ops[0]->kind eq 'virt_reg' && $ops[0]->value eq $vreg ) {
                        $spilled_dst = 1;
                        $ops[0] = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $spill_temp, type => $ops[0]->type );
                    }
                    if ( @ops >= 2 && $ops[1]->kind eq 'virt_reg' && $ops[1]->value eq $vreg ) {
                        $spilled_src = 1;
                        $ops[1] = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $spill_temp, type => $ops[1]->type );
                    }
                    for my $op (@ops) {
                        next unless $op->kind eq 'mem';
                        if ( ( $op->value->{base} // '' ) eq $vreg ) {
                            $spilled_mem = 1;
                            $op->value->{base} = $spill_temp;
                        }
                    }
                    if ( $spilled_src || $spilled_mem ) {
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $stack_reg, disp => $offset },
                            type  => undef,
                        );
                        push @new,
                            Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => $load_op,
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $spill_temp ), $mem, ],
                            comment  => 'spill-reload',
                            );
                    }
                    my $new_inst = Brocken::Jenny::MIR::MachineInstruction->new( opcode => $opcode, operands => \@ops, comment => $inst->comment, );
                    push @new, $new_inst;
                    if ($spilled_dst) {
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $stack_reg, disp => $offset },
                            type  => undef,
                        );
                        push @new,
                            Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => $store_op,
                            operands => [ $mem, Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $spill_temp ), ],
                            comment  => 'spill-store',
                            );
                    }
                }
                $bb->instructions->@* = @new;
            }
        }
    }

    method insert_caller_save_code( $mf, $caller_regs, $stack_reg, $is_float = 0, $base_idx = 0 ) {
        my $store_op  = $is_float ? 'fstore' : 'store';
        my $load_op   = $is_float ? 'fload'  : 'load';
        my $spill_idx = $base_idx;
        for my $bb ( $mf->blocks->@* ) {
            my @new;
            for my $inst ( $bb->instructions->@* ) {
                if ( $inst->opcode eq 'call_func' ) {
                    for my $r (@$caller_regs) {
                        my $mem
                            = Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => $stack_reg, disp => $spill_idx++ * 8 }, );
                        push @new,
                            Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => $store_op,
                            operands => [ $mem, Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $r ) ],
                            comment  => 'caller-save ' . $r,
                            );
                    }
                }
                push @new, $inst;
                if ( $inst->opcode eq 'call_func' ) {
                    for my $r ( reverse @$caller_regs ) {
                        my $mem
                            = Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => $stack_reg, disp => $spill_idx-- * 8 - 8 },
                            );
                        push @new,
                            Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => $load_op,
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $r ), $mem ],
                            comment  => 'caller-restore ' . $r,
                            );
                    }
                }
            }
            $bb->instructions->@* = @new;
        }
    }

    method remove_redundant_moves( $mf, $assignment ) {
        for my $bb ( $mf->blocks->@* ) {
            my @new;
            for my $inst ( $bb->instructions->@* ) {
                if ( $inst->opcode eq 'mov' ) {
                    my @ops = $inst->operands->@*;
                    next
                        if @ops >= 2                &&
                        $ops[0]->kind eq 'virt_reg' &&
                        $ops[1]->kind eq 'virt_reg' &&
                        ( $assignment->{ $ops[0]->value } // '' ) eq ( $assignment->{ $ops[1]->value } // '' );
                }
                push @new, $inst;
            }
            $bb->instructions->@* = @new;
        }
    }

    method fix_entry_shuffle( $mf, $assignment, $temp_reg ) {
        my $entry = $mf->entry_block;
        return unless $entry;

        # Collect save-phase MOVs: mov <virt_reg>, <phys_reg>  (capturing
        # a parameter from its calling-convention register).  These are the
        # only instructions that can create register hazards because they
        # read the caller's register values before they are overwritten.
        my @saves;
        my @insts = $entry->instructions->@*;
        for my $i ( 0 .. $#insts ) {
            my $inst = $insts[$i];
            next unless $inst->opcode eq 'mov';
            my ( $dst, $src ) = $inst->operands->@*;
            next unless $src->kind eq 'phys_reg';
            my $dst_reg;
            if ( $dst->kind eq 'phys_reg' ) {
                $dst_reg = $dst->value;
            }
            elsif ( $dst->kind eq 'virt_reg' ) {
                $dst_reg = $assignment->{ $dst->value };
            }
            next unless $dst_reg && $dst_reg !~ /^spill\(/;
            push @saves, { idx => $i, dst => $dst_reg, src => $src->value };
        }

        # Detect hazard: dst_i == src_j for i < j  (save MOV i overwrites
        # a register whose original value save MOV j still needs to read).
        # Break cycles using the platform-specific spill-temp register.
        for my $i ( 0 .. $#saves ) {
            for my $j ( $i + 1 .. $#saves ) {
                if ( $saves[$i]{dst} eq $saves[$j]{src} ) {
                    # MOV i writes to a register that MOV j subsequently reads
                    # as its original caller-set value.  Insert a save before
                    # MOV i and redirect MOV j to read from the temp register.
                    my $hazard_reg = $saves[$i]{dst};
                    my $save_inst = Brocken::Jenny::MIR::MachineInstruction->new(
                        opcode   => 'mov',
                        operands => [
                            Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $temp_reg ),
                            Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $hazard_reg ),
                        ],
                        comment => 'entry-shuffle save ' . $hazard_reg,
                    );

                    # Insert before MOV i
                    splice $entry->instructions->@*, $saves[$i]{idx}, 0, $save_inst;

                    # Shift indices after insertion point
                    for my $k ( $i .. $#saves ) {
                        $saves[$k]{idx}++;
                    }

                    # Patch MOV j's source to r11
                    my $j_inst = $entry->instructions->[ $saves[$j]{idx} ];
                    $j_inst->operands->[1] = Brocken::Jenny::MIR::MachineOperand->new(
                        kind => 'phys_reg', value => $temp_reg, type => $j_inst->operands->[1]->type,
                    );

                    # Mark this hazard as resolved so we don't re-process it
                    $saves[$j]{src} = $temp_reg;
                }
            }
        }
    }

    method compute_unified_frame( $num_callee, $spill_frame, $caller_save_size ) {
        my $frame = $num_callee * 8 + $spill_frame + $caller_save_size;
        return ( $frame + 15 ) & ~15;
    }
}
1;
