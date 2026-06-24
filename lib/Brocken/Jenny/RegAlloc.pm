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
        my @intervals = $self->_compute_live_intervals( $mf, $platform, $is_float );
        return $self->_linear_scan( $mf, \@intervals, $platform, $is_float );
    }

    method _vreg_name( $op, $is_float ) {
        return undef unless $op->kind eq 'virt_reg';
        my $type = $op->type;
        my $is_f = $type ? ( $type->kind eq 'float' ) : 0;
        return undef if $is_float != $is_f;
        return $op->value;
    }

    method _vreg_names_from_mem_operands( $inst, $platform ) {
        state $phys_re = do {
            my @regs = $platform->registers('available')->@*;
            my $pat  = join '|', map quotemeta, @regs;
            qr/^($pat)$/;
        };
        my @names;
        for my $op ( $inst->operands->@* ) {
            next unless $op->kind eq 'mem';
            my $base = $op->value->{base} // '';

            # Track virtual register names, but skip known physical register names
            # (like r12, which the lowerer uses directly in fiber memory operands).
            push @names, $base if $base ne '' && $base !~ $phys_re;
            my $index = $op->value->{index} // '';
            push @names, $index if $index ne '';
        }
        return @names;
    }

    method _register_operands($inst) {
        return $inst->operands->@*;
    }

    method _compute_live_intervals( $mf, $platform, $is_float ) {
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
                for my $base ( $self->_vreg_names_from_mem_operands( $inst, $platform ) ) {
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
                for my $base ( $self->_vreg_names_from_mem_operands( $inst, $platform ) ) {
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

    method _linear_scan( $mf, $intervals, $platform, $is_float ) {
        my @caller_regs = $is_float ? $platform->fp_registers('caller')->@* : $platform->registers('caller')->@*;
        my @callee_regs = $is_float ? $platform->fp_registers('callee')->@* : $platform->registers('callee')->@*;
        my $skip_reg    = $is_float ? $platform->fp_return_register         : $platform->return_register;
        my $fiber_reg   = $is_float ? undef                                 : $platform->fiber_reg;
        @caller_regs = grep { $_ ne $skip_reg } @caller_regs;
        @callee_regs = grep { $_ ne $skip_reg } @callee_regs;
        @caller_regs = grep { $_ ne $fiber_reg } @caller_regs if $fiber_reg;
        @callee_regs = grep { $_ ne $fiber_reg } @callee_regs if $fiber_reg;

        # Exclude physical registers that are used as destinations by any
        # instruction in this function. This prevents argument-setup MOVs
        # (e.g. `mov rcx, virt`) from clobbering virt_reg values that the
        # allocator may have assigned to the same physical register.
        my %defined_phys;
        my $has_ctx_swap = 0;
        if ( $mf && $mf->blocks->@* ) {
            for my $mbb ( $mf->blocks->@* ) {
                for my $inst ( $mbb->instructions->@* ) {
                    $has_ctx_swap = 1 if $inst->opcode eq 'ctx_swap';
                    my @ops = $inst->operands->@*;
                    next unless @ops >= 1;
                    my $dst = $ops[0];
                    next unless $dst->kind eq 'phys_reg';
                    my $is_dst_float = $dst->type ? ( $dst->type->kind eq 'float' ? 1 : 0 ) : 0;
                    next if $is_float != $is_dst_float;
                    next if $inst->opcode eq 'store' || $inst->opcode eq 'store_imm';
                    $defined_phys{ $dst->value } = 1;
                }
            }
        }

        # Exclude r10/r11 when the function contains ctx_swap. The ctx_swap
        # encoding body uses these as internal temporaries (resume_pc and
        # saved_rsp), making them invisible to the per-function phys_reg
        # destination scan above. Any virtual register allocated to r10 or
        # r11 would have its value silently corrupted within ctx_swap.
        if ( $has_ctx_swap && !$is_float ) {
            $defined_phys{r10} = 1;
            $defined_phys{r11} = 1;
        }
        @caller_regs = grep { !$defined_phys{$_} } @caller_regs;
        my $spill_temp = pop @caller_regs;
        my @regs       = ( @caller_regs, @callee_regs );
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
        my $load_op    = $is_float ? 'fload'  : 'load';
        my $store_op   = $is_float ? 'fstore' : 'store';
        my %reads_dst  = map { $_ => 1 } qw(add sub adc sbb and or xor cmp shl shr sar neg inc dec not);
        my %can_mem_src = map { $_ => 1 } qw(add sub adc sbb and or xor cmp);
        my $temp_op    = sub { Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $spill_temp, type => undef ) };
        my $mem_op     = sub ($o) { Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => $stack_reg, disp => $o }, type => undef ) };
        my $load_inst  = sub ($o) {
            Brocken::Jenny::MIR::MachineInstruction->new( opcode => $load_op, operands => [ $temp_op->(), $mem_op->($o) ], comment => 'spill-reload' );
        };
        my $store_inst = sub ($o) {
            Brocken::Jenny::MIR::MachineInstruction->new( opcode => $store_op, operands => [ $mem_op->($o), $temp_op->() ], comment => 'spill-store' );
        };

        for my $bb ( $mf->blocks->@* ) {
            my @new;
            for my $inst ( $bb->instructions->@* ) {
                my $opcode = $inst->opcode;
                my @ops    = $inst->operands->@*;

                my %sp;
                for my $i ( 0 .. $#ops ) {
                    next unless $ops[$i]->kind eq 'virt_reg';
                    my $off = $spill_slots->{ $ops[$i]->value };
                    next unless defined $off;
                    $sp{$i} = $off;
                }

                my $smem_off;
                for my $op (@ops) {
                    next unless $op->kind eq 'mem';
                    my $base = $op->value->{base} // '';
                    if ( defined( my $off = $spill_slots->{$base} ) ) {
                        $smem_off = $off;
                        $op->value->{base} = $spill_temp;
                    }
                }

                if ( !keys %sp && !defined $smem_off ) {
                    push @new, $inst;
                    next;
                }

                my $d_off = $sp{0};
                my $s_off = $sp{1};
                my $d_sp  = defined $d_off;
                my $s_sp  = defined $s_off;
                my $dd    = $d_sp && $s_sp && $d_off != $s_off;

                if ($d_sp) {
                    $ops[0] = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $spill_temp, type => $ops[0]->type );
                }

                if ( $s_sp && $dd && $can_mem_src{$opcode} ) {
                    $ops[1] = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $stack_reg, disp => $s_off },
                        type  => $ops[1]->type,
                    );
                }
                elsif ($s_sp) {
                    $ops[1] = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $spill_temp, type => $ops[1]->type );
                }

                my @load_offsets;
                push @load_offsets, $smem_off if defined $smem_off;
                if ($dd) {
                    if ( $can_mem_src{$opcode} ) {
                        push @load_offsets, $d_off if $reads_dst{$opcode};
                    }
                    else {
                        push @load_offsets, $s_off;
                        push @load_offsets, $d_off if $reads_dst{$opcode};
                    }
                }
                else {
                    push @load_offsets, $s_off if $s_sp;
                    push @load_offsets, $d_off if $d_sp && $reads_dst{$opcode};
                }
                push @new, $load_inst->($_) for @load_offsets;

                push @new, Brocken::Jenny::MIR::MachineInstruction->new( opcode => $opcode, operands => [@ops], comment => $inst->comment, );

                if ($d_sp) {
                    push @new, $store_inst->($d_off);
                }
            }
            $bb->instructions->@* = @new;
        }
    }

    method insert_caller_save_code( $mf, $caller_regs, $stack_reg, $is_float = 0, $base_idx = 0 ) {
        my $store_op  = $is_float ? 'fstore' : 'store';
        my $load_op   = $is_float ? 'fload'  : 'load';
        my $spill_idx = $base_idx;
        for my $bb ( $mf->blocks->@* ) {
            my @new;
            for my $inst ( $bb->instructions->@* ) {
                if ( $inst->opcode =~ /^(?:call_func|call_indirect|ctx_swap)$/ ) {
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
                if ( $inst->opcode =~ /^(?:call_func|call_indirect|ctx_swap)$/ ) {
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

    method remove_redundant_caller_restores($mf) {
        for my $bb ( $mf->blocks->@* ) {
            my @new;
            for my $i ( 0 .. $#{ $bb->instructions } ) {
                my $inst = $bb->instructions->[$i];
                my $next = $bb->instructions->[ $i + 1 ];
                if ( $inst->opcode =~ /^(?:load|fload)$/ && $inst->comment =~ /^caller-restore / && $next && $next->opcode =~ /^(?:mov|fmov)$/ ) {
                    my ($load_dst) = $inst->operands->@*;
                    my ( $mov_dst, $mov_src ) = $next->operands->@*;
                    if ( $load_dst->kind eq 'phys_reg' && $mov_dst->kind eq 'phys_reg' && $load_dst->value eq $mov_dst->value ) {
                        next;
                    }
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
                    my $save_inst  = Brocken::Jenny::MIR::MachineInstruction->new(
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
                    $j_inst->operands->[1]
                        = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $temp_reg, type => $j_inst->operands->[1]->type, );

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

=encoding utf-8

=head1 NAME

Brocken::Jenny::RegAlloc - Linear Scan Register Allocator

=head1 DESCRIPTION

Implements a linear-scan register allocator for MIR functions. Handles allocation of both general-purpose and
floating-point registers, spill code insertion, caller-save/restore code, redundant-move elimination, and entry-block
shuffle hazard detection.

=head2 Algorithm

The allocator uses a standard linear-scan approach:

=over 4

=item 1. Compute live intervals via global dataflow analysis (backward fixed-point)

=item 2. Sort intervals by start position

=item 3. Linear scan: allocate registers greedily with furthest-next-use spill heuristic

=item 4. Insert spill code for spilled virtual registers

=item 5. Insert caller-save/restore code around call instructions

=item 6. Remove redundant register-to-register moves

=item 7. Fix entry-block parameter shuffle hazards

=back

=head2 Classes

=over 4

=item L<Brocken::Jenny::RegAlloc::LiveInterval> - Represents a vreg's live range

=item L<Brocken::Jenny::RegAlloc::LinearScan> - The allocator implementation

=back

=head1 METHODS

=head2 allocate

    $allocator->allocate($mf, $platform, $is_float?)

Performs full register allocation on the MIR function.

=head2 insert_spill_code

    $allocator->insert_spill_code($mf, $spill_slots, $spill_temp, $stack_reg, $is_float?)

Inserts load/store instructions for each spilled virtual register.

=head2 insert_caller_save_code

    $allocator->insert_caller_save_code($mf, $caller_regs, $stack_reg, $is_float?, $base_idx?)

Saves all caller-saved registers before each call and restores them after.

=head2 remove_redundant_moves

    $allocator->remove_redundant_moves($mf, $assignment)

Elides MOV instructions where source and destination map to the same physical register.

=head2 fix_entry_shuffle

    $allocator->fix_entry_shuffle($mf, $assignment, $temp_reg)

Detects and fixes register hazards in entry-block parameter shuffles by inserting spill-temp save/restore sequences.

=head2 compute_unified_frame

    $allocator->compute_unified_frame($num_callee, $spill_frame, $caller_save_size)

Computes the total stack frame size, aligned to 16 bytes.

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
