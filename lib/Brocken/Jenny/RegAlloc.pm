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

            # A raw displacement is positioned by the ABI against the real stack
            # pointer, so the base is a real register rather than a name the
            # allocator owns.  Letting it in here would give the stack pointer a
            # virtual register, and every spill slot, caller-save slot and alloca
            # is named against that same string: the allocator would then place
            # them through an unrelated register.
            my $raw_stack = $op->value->{raw} && $base eq $platform->stack_reg;

            # Track virtual register names, but skip known physical register names
            # (like r12, which the lowerer uses directly in fiber memory operands).
            push @names, $base if !$raw_stack && $base ne '' && $base !~ $phys_re;
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

            # Detect intra-block loops: find the first label that is the
            # target of a branch within the same block.  Such blocks contain
            # a preamble (pre-label) and a loop body (post-label).
            # Loop-carried vregs (defined in preamble, used in loop body)
            # must appear in USE[b] so their live intervals span the full
            # block rather than ending at their last mention.
            my $split_idx = -1;
            {
                my %labels_in_block;
                for my $i ( 0 .. $#{ $bb->instructions } ) {
                    my $inst = $bb->instructions->[$i];
                    next unless $inst->opcode eq 'label';
                    $labels_in_block{ $inst->operands->[0]->value } = $i;
                }
                for my $i ( 0 .. $#{ $bb->instructions } ) {
                    my $inst = $bb->instructions->[$i];
                    my $target;
                    if ( $inst->opcode eq 'bne' || $inst->opcode eq 'beq' ) {
                        $target = $inst->operands->[1]->value;
                    }
                    elsif ( $inst->opcode eq 'jmp' ) {
                        $target = $inst->operands->[0]->value;
                    }
                    if ( defined $target && exists $labels_in_block{$target} ) {
                        my $label_idx = $labels_in_block{$target};
                        if ( $split_idx < 0 || $label_idx < $split_idx ) {
                            $split_idx = $label_idx;
                        }
                    }
                }
            }
            if ( $split_idx > 0 ) {
                my @pre_insts  = $bb->instructions->@[ 0 .. $split_idx - 1 ];
                my @post_insts = $bb->instructions->@[ $split_idx .. $#{ $bb->instructions } ];
                my %pre_defd;
                my %pre_used;
                for my $inst (@pre_insts) {
                    my @ops = $self->_register_operands($inst);
                    for my $op (@ops) {
                        my $name = $self->_vreg_name( $op, $is_float );
                        next unless defined $name;
                        if ( $op == $ops[0] && $inst->opcode ne 'store' && $inst->opcode ne 'store_imm' ) {
                            $pre_defd{$name} = 1 unless exists $pre_used{$name};
                        }
                        else {
                            $pre_used{$name} = 1 unless exists $pre_defd{$name};
                        }
                    }
                    for my $base ( $self->_vreg_names_from_mem_operands( $inst, $platform ) ) {
                        next if $is_float;
                        $pre_used{$base} = 1 unless exists $pre_defd{$base};
                    }
                }
                my %post_defd;
                my %post_used;
                for my $inst (@post_insts) {
                    my @ops = $self->_register_operands($inst);
                    for my $op (@ops) {
                        my $name = $self->_vreg_name( $op, $is_float );
                        next unless defined $name;
                        if ( $op == $ops[0] && $inst->opcode ne 'store' && $inst->opcode ne 'store_imm' ) {
                            $post_defd{$name} = 1 unless exists $post_used{$name};
                        }
                        else {
                            $post_used{$name} = 1 unless exists $post_defd{$name};
                        }
                    }
                    for my $base ( $self->_vreg_names_from_mem_operands( $inst, $platform ) ) {
                        next if $is_float;
                        $post_used{$base} = 1 unless exists $post_defd{$base};
                    }
                }

                # use = pre_use U (pre_def ^ post_use)
                # def = pre_def U post_def
                for my $v ( keys %pre_used ) {
                    $used{$v} = 1;
                }
                for my $v ( keys %pre_defd ) {
                    $used{$v} = 1 if $post_used{$v};
                }
                for my $v ( keys %pre_defd ) {
                    $defd{$v} = 1;
                }
                for my $v ( keys %post_defd ) {
                    $defd{$v} = 1;
                }
            }
            else {
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

    # How many scratch registers `insert_spill_code` can need at once.
    #
    # One instruction can need several spilled values simultaneously rather
    # than one after another. A store through a spilled pointer is the plain
    # case: it needs the address and the value at the same time. One temp
    # cannot hold both, and the second reload lands on top of the first, so
    # the store goes through whatever the value was instead of through the
    # address. Every operand that may end up spilled therefore needs its own
    # temp, and so does a `mem` operand whose base is a virtual register,
    # because that base is replaced by a temp and has to stay valid until the
    # instruction retires.
    #
    # This is counted before allocation, from the shape of the MIR, so it can
    # only be an upper bound -- the answer is the most temps any single
    # instruction could ask for, not the most it does. Keeping the reserve that
    # small matters: a temp is a register the allocator never gets to use, and
    # every extra one is paid for by every function in the module.
    method spill_temp_count($mf) {
        my $max = 1;
        return $max unless $mf && $mf->blocks->@*;
        INSN_SCAN: for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                my $need = 0;
                for my $op ( $inst->operands->@* ) {
                    if ( $op->kind eq 'virt_reg' ) { $need++ }
                    elsif ( $op->kind eq 'mem' ) {

                        # A base naming a virtual register becomes a temp. A
                        # base naming a physical register is a real frame
                        # reference and needs none. This asks only which one it
                        # is, so the leading `%` is the whole test -- unlike the
                        # interval model, where a base that is not an available
                        # register is what has to be caught, and a raw stack
                        # displacement has to be let past.
                        $need++ if ( $op->value->{base} // '' ) =~ /^%/;
                    }
                }
                $max = $need if $need > $max;
            }
        }
        return $max;
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

        # The umulh/udiv/idiv/irem/div128_64 encodings use rax and rdx as
        # internal temporaries, which is invisible to the per-function phys_reg
        # destination scan above. A virtual register allocated to either would
        # have its value silently destroyed by the sequence, so keep both out
        # of the pool whenever one of those opcodes is present.
        my $has_div_scratch = 0;
        if ( $mf && $mf->blocks->@* && !$is_float ) {
            DIV_SCAN: for my $mbb ( $mf->blocks->@* ) {
                for my $inst ( $mbb->instructions->@* ) {
                    next unless $inst->opcode eq 'umulh'
                        || $inst->opcode eq 'udiv'
                        || $inst->opcode eq 'idiv'
                        || $inst->opcode eq 'irem'
                        || $inst->opcode eq 'div128_64'
                        || $inst->opcode eq 'rem128_64';
                    $has_div_scratch = 1;
                    last DIV_SCAN;
                }
            }
        }
        if ($has_div_scratch) {
            $defined_phys{rax} = 1;
            $defined_phys{rdx} = 1;
        }

        # The register-source shift encodings (shl/lshr/ashr with a non-immediate
        # count) use the D3 /ext form, which requires the count in CL, so the
        # count is moved into rcx immediately before the shift. That move is
        # invisible to the per-function phys_reg destination scan above, so a
        # value or shift destination allocated to rcx would be silently
        # destroyed by it. Keep rcx out of the pool for such functions.
        my $has_shift_scratch = 0;
        if ( $mf && $mf->blocks->@* && !$is_float ) {
            SHIFT_SCAN: for my $mbb ( $mf->blocks->@* ) {
                for my $inst ( $mbb->instructions->@* ) {
                    next unless $inst->opcode eq 'shl'
                        || $inst->opcode eq 'lshr'
                        || $inst->opcode eq 'ashr';
                    my @ops = $inst->operands->@*;
                    next if @ops < 2;
                    next if $ops[1]->kind eq 'imm';
                    $has_shift_scratch = 1;
                    last SHIFT_SCAN;
                }
            }
        }
        if ($has_shift_scratch) {
            $defined_phys{rcx} = 1;
        }

        @caller_regs = grep { !$defined_phys{$_} } @caller_regs;

        # Reserve as many temps as the widest instruction could need, and
        # always at least one. The temps are taken off the end of the caller
        # pool, so they are the last registers a spill would otherwise reach
        # for and the first to disappear if the function is under pressure.
        my $temp_count = $mf ? $self->spill_temp_count($mf) : 1;
        $temp_count = 1                  if $temp_count < 1;
        $temp_count = scalar @caller_regs if $temp_count > @caller_regs;
        my @spill_temps = splice @caller_regs, ( scalar(@caller_regs) - $temp_count );
        my $spill_temp  = $spill_temps[0];
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
        return {
            assignment  => \%assignment,
            used_callee => [ sort keys %used_callee ],
            spill_slots => \%spill_slots,
            spill_temp  => $spill_temp,
            spill_temps => \@spill_temps,
        };
    }

    method insert_spill_code( $mf, $spill_slots, $spill_temp, $stack_reg, $is_float = 0 ) {
        return unless $spill_slots && keys %$spill_slots;
        my $load_op     = $is_float ? 'fload'  : 'load';
        my $store_op    = $is_float ? 'fstore' : 'store';
        my %reads_dst   = map { $_ => 1 } qw(add sub adc sbb and or xor cmp shl shr sar neg inc dec not);
        my %can_mem_src = map { $_ => 1 } qw(add sub adc sbb and or xor cmp);

        # `spill_temp` is the reserved temp pool. A plain string is accepted so
        # a caller holding only the single-temp result still works.
        my @temps = !ref $spill_temp ? ($spill_temp) : $spill_temp->@*;
        @temps = ('r11') unless @temps;

        my $temp_for = sub ($k) {
            $temps[ $k < @temps ? $k : $#temps ];
        };
        my $temp_op = sub ($k) { Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $temp_for->($k), type => undef ) };
        my $mem_op
            = sub ($o) { Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => $stack_reg, disp => $o }, type => undef ) };
        my $load_inst = sub ($k, $o) {
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => $load_op,
                operands => [ $temp_op->($k), $mem_op->($o) ],
                comment  => 'spill-reload'
            );
        };
        my $store_inst = sub ($k, $o) {
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => $store_op,
                operands => [ $mem_op->($o), $temp_op->($k) ],
                comment  => 'spill-store'
            );
        };
        for my $bb ( $mf->blocks->@* ) {
            my @new;
            for my $inst ( $bb->instructions->@* ) {
                my $opcode = $inst->opcode;
                my @ops    = $inst->operands->@*;

                # One slot per physical temp, and one reload per slot, so two
                # values that have to be live at the same time cannot land on
                # each other. A slot may hold more than one offset when the
                # instruction reads and writes the same spilled value, which
                # is a single value by definition.
                my ( @off_of, @order );
                my $reserve = sub ($off) {
                    for my $k ( 0 .. $#order ) {
                        return $k if $off_of[$k] == $off;
                    }
                    push @order, $off;
                    $off_of[ $#order ] = $off;
                    return $#order;
                };

                my %sp;
                for my $i ( 0 .. $#ops ) {
                    next unless $ops[$i]->kind eq 'virt_reg';
                    my $off = $spill_slots->{ $ops[$i]->value };
                    next unless defined $off;
                    $sp{$i} = $off;
                }

                # A spilled `mem` base is replaced by a temp that has to hold
                # the address across the whole instruction, so it is reserved
                # before any operand can claim the same temp.
                my ( $base_k, $smem_off );
                for my $op (@ops) {
                    next unless $op->kind eq 'mem';

                    # A raw operand is addressed against the hardware stack
                    # pointer -- an incoming stack argument, or one being
                    # written for an outgoing call -- so its base is a real
                    # register and there is nothing spilled to reload it from.
                    next if $op->value->{raw};
                    my $base = $op->value->{base} // '';
                    if ( defined( my $off = $spill_slots->{$base} ) ) {
                        $smem_off = $off;
                        $base_k   = $reserve->($off);
                        $op->value->{base} = $temp_for->($base_k);
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
                my $same  = $d_sp && $s_sp && $d_off == $s_off;
                my $d_k   = $d_sp ? $reserve->($d_off) : undef;
                my $s_k   = $s_sp ? $reserve->($s_off) : undef;

                # A destination that the instruction also reads has to keep its
                # old value somewhere the write will not destroy, which is a
                # second temp holding the same offset.
                my $needs_old_d = $d_sp && $reads_dst{$opcode} && $d_k == $base_k;
                my $old_k       = $d_k;
                if ($needs_old_d) {

                    # The base already holds a temp for this offset, and a temp
                    # that is about to be overwritten is not a place to keep it.
                    $old_k = $#order + 1;
                    push @order, $d_off;
                    $off_of[$old_k] = $d_off;
                }

                if ($d_sp) {
                    $ops[0] = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $temp_for->($d_k), type => $ops[0]->type );
                }
                if ( $s_sp && !$same && !$can_mem_src{$opcode} ) {
                    $ops[1] = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $temp_for->($s_k), type => $ops[1]->type );
                }
                elsif ( $s_sp && !$same && $can_mem_src{$opcode} ) {
                    $ops[1] = Brocken::Jenny::MIR::MachineOperand->new(
                        kind  => 'mem',
                        value => { base => $stack_reg, disp => $s_off },
                        type  => $ops[1]->type,
                    );
                }

                # Every remaining operand is a distinct value, so each takes
                # the next free temp and keeps it to itself.
                my @extra_k;
                for my $i ( 2 .. $#ops ) {
                    next unless defined $sp{$i};
                    my $k = $reserve->( $sp{$i} );
                    push @extra_k, [ $k, $sp{$i} ];
                    $ops[$i] = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $temp_for->($k), type => $ops[$i]->type );
                }

                my @loads;
                push @loads, [ $base_k, $smem_off ] if defined $base_k;
                push @loads, [ $s_k,    $s_off ]    if $s_sp && !$same && !$can_mem_src{$opcode};
                push @loads, [ $old_k,  $d_off ]    if $needs_old_d;
                push @loads, @extra_k;

                push @new, $load_inst->(@$_) for @loads;
                push @new, Brocken::Jenny::MIR::MachineInstruction->new( opcode => $opcode, operands => [@ops], comment => $inst->comment, );
                if ($d_sp) {
                    push @new, $store_inst->( $d_k, $d_off );
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

    # Schedule the parameter-capture shuffle at function entry.
    #
    # The lowerer emits one `mov <dst>, <param_reg>` per incoming argument at
    # the very top of the entry block, so the captures read the caller's
    # argument registers simultaneously -- they behave like a parallel move,
    # not a sequence.  Once the allocator picks destinations, a destination may
    # land on a register that a *later* capture still has to read.
    #
    # Parking every such source in the one spill temp is not enough: each new
    # park overwrites the previous one, so only the last value survives.  With
    # four integer parameters the allocator produces the cycle
    #
    #     rcx <- rdi,  rdx <- rsi,  rsi <- rdx,  rdi <- rcx
    #
    # which needs two registers held live at once.  So schedule the captures as
    # a real parallel move: emit any capture whose destination is not a pending
    # source, and break a cycle by parking a single source in the temp, which
    # frees that temp again as soon as its one consumer runs.
    method fix_entry_shuffle( $mf, $assignment, $temp_reg ) {
        my $entry = $mf->entry_block;
        return unless $entry;

        # Captures are the leading run of MOVs reading a physical register.
        # Later MOVs that read a physical register (a return value landing in a
        # register, say) are not part of this parallel move and must be left
        # where they are.
        my @prefix;
        my @insts = $entry->instructions->@*;
        for my $inst (@insts) {
            last unless $inst->opcode eq 'mov';
            my ( $dst, $src ) = $inst->operands->@*;
            last unless $src && $src->kind eq 'phys_reg';
            last unless $dst && ( $dst->kind eq 'phys_reg' || $dst->kind eq 'virt_reg' );
            push @prefix, { inst => $inst, src => $src->value };
        }
        return unless @prefix > 1;

        my ( @work, @parked );
        for my $cap (@prefix) {
            my $dst = $cap->{inst}->operands->[0];
            my $reg = $dst->kind eq 'phys_reg' ? $dst->value : $assignment->{ $dst->value };

            # A spilled or unresolved destination writes no register, so it
            # cannot clobber a source.  A `mov r, r` preserves its source.
            # Neither takes part in scheduling; both are still emitted.
            if ( !defined $reg || $reg =~ /^spill\(/ || $reg eq $cap->{src} ) {
                push @parked, $cap;
                next;
            }
            push @work, { inst => $cap->{inst}, dst => $reg, src => $cap->{src} };
        }
        return unless @work > 1;

        # The spill temp is excluded from allocation, so no capture writes it.
        # If that ever stops holding, decline rather than emit a shuffle we
        # cannot schedule.
        my %touched = map { $_ => 1 } map { ( $_->{dst}, $_->{src} ) } @work;
        return if $touched{$temp_reg};

        my @plan;
        my $total = scalar @work;
        my $budget = 2 * $total;
        while (@work) {
            my $chosen;
            for my $k ( 0 .. $#work ) {
                my $dst = $work[$k]{dst};
                unless ( grep { $_->{src} eq $dst } @work ) {
                    $chosen = $k;
                    last;
                }
            }
            unless ( defined $chosen ) {

                # Every remaining destination is still needed as a source, so
                # the rest is a cycle.  Park one source in the temp and
                # reschedule; its consumer runs before the temp is reused.
                last if --$budget < 0;
                my $head = $work[0];
                push @plan, { inst => undef, dst => $temp_reg, src => $head->{src} };
                $head->{src} = $temp_reg;
                next;
            }
            push @plan, splice @work, $chosen, 1;
        }
        # A schedule step per capture, plus whatever temp parks it needed.
        return if @plan < $total;

        my @new;
        for my $step ( @plan, @parked ) {
            my $inst = $step->{inst};
            if ($inst) {
                my $src = $inst->operands->[1];
                $inst->operands->[1]
                    = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $step->{src}, type => $src->type );
                push @new, $inst;
            }
            else {
                push @new,
                    Brocken::Jenny::MIR::MachineInstruction->new(
                    opcode   => 'mov',
                    operands => [
                        Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $step->{dst} ),
                        Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $step->{src} ),
                    ],
                    comment => 'entry-shuffle save ' . $step->{src},
                    );
            }
        }
        splice $entry->instructions->@*, 0, scalar @prefix, @new;
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

Schedules the entry-block parameter captures as a parallel move, so a capture
is never emitted after the one that overwrites the register it still has to
read. Cycles are broken by parking one source in the spill temp, which is
released again before the temp is reused. Only the leading run of captures is
touched, so a later move that reads a physical register keeps its position.

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
