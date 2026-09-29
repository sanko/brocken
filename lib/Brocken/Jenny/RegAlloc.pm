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
            qr[^($pat)$];
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
    method _register_operands($inst) { $inst->operands->@* }

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
                    if    ( $op->kind eq 'virt_reg' ) { $need++ }
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
                    next
                        unless $inst->opcode eq 'umulh' ||
                        $inst->opcode eq 'udiv'         ||
                        $inst->opcode eq 'idiv'         ||
                        $inst->opcode eq 'irem'         ||
                        $inst->opcode eq 'div128_64'    ||
                        $inst->opcode eq 'rem128_64';
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
                    next unless $inst->opcode eq 'shl' || $inst->opcode eq 'lshr' || $inst->opcode eq 'ashr';
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
        $temp_count = 1                   if $temp_count < 1;
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
            spill_temps => \@spill_temps
        };
    }

    # `$mem_src` names the opcodes the calling backend can encode with a memory
    # operand as the source, so a spilled source does not have to be reloaded
    # into a temp first. It has to be passed in rather than assumed: the form is
    # an x86 addressing mode, and the other backends resolve every source through
    # a register, so handing one of them a `mem` operand is not a fallback but a
    # crash. A backend that lists nothing gets a temp reload for every spilled
    # source, which is always correct and is why this is a list and not a flag.
    method insert_spill_code( $mf, $spill_slots, $spill_temp, $stack_reg, $is_float = 0, $mem_src = [] ) {
        return unless $spill_slots && keys %$spill_slots;
        my $load_op     = $is_float ? 'fload'  : 'load';
        my $store_op    = $is_float ? 'fstore' : 'store';
        my %reads_dst   = map { $_ => 1 } qw[add sub adc sbb and or xor cmp shl shr sar neg inc dec not];
        my %can_mem_src = map { $_ => 1 } $mem_src->@*;

        # `spill_temp` is the reserved temp pool. A plain string is accepted so
        # a caller holding only the single-temp result still works.
        my @temps = !ref $spill_temp ? ($spill_temp) : $spill_temp->@*;
        @temps = ('r11') unless @temps;
        my $temp_for = sub ($k) { $temps[ $k < @temps ? $k : $#temps ] };

        # One slot per physical temp, and one reload per slot, so two values that
        # have to be live at the same time cannot land on each other. A slot may
        # hold more than one offset when the instruction reads and writes the
        # same spilled value, which is a single value by definition.
        #
        # A slot also remembers the type of the value it holds, because the
        # reload and the store are the only operands in the whole spill sequence
        # that would otherwise have no type at all, and the width of a
        # floating-point move is taken from it. Left unset, an f64 spilled to
        # the stack came back through `movss`, which moves four of the eight
        # bytes and leaves the rest as whatever the register held, so a reloaded
        # value was whatever the high half happened to say and a comparison
        # against it was decided by stale register contents. Nothing downstream
        # could see it.
        my ( @off_of, @order, @type_of );

        # Only a floating-point slot needs a type. `load` and `store` derive an
        # integer's width from the value they move rather than from the operand,
        # so a slot that has always been untyped widens correctly; a float move
        # takes the width from the operand instead, and an untyped one is 32
        # bits. That put half of an f64 back into the register and left the
        # other half as whatever was already in it, so a reloaded value was
        # decided by stale register contents. Restricting the type to floats
        # leaves every integer spill encoding exactly as it was.
        my $slot_type = sub ($t) { return ( $t && $t->kind eq 'float' ) ? $t : undef };
        my $temp_op   = sub ( $k, $type ) { Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $temp_for->($k), type => $type ) };
        my $mem_op    = sub ( $o, $type ) {
            Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => $stack_reg, disp => $o }, type => $type );
        };
        my $load_inst = sub ( $k, $o ) {
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => $load_op,
                operands => [ $temp_op->( $k, $type_of[$k] ), $mem_op->( $o, $type_of[$k] ) ],
                comment  => 'spill-reload'
            );
        };
        my $store_inst = sub ( $k, $o ) {
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => $store_op,
                operands => [ $mem_op->( $o, $type_of[$k] ), $temp_op->( $k, $type_of[$k] ) ],
                comment  => 'spill-store'
            );
        };
        for my $bb ( $mf->blocks->@* ) {
            my @new;
            for my $inst ( $bb->instructions->@* ) {

                # The slot table is per instruction: the reload and store that
                # belong to one instruction are emitted next to it, and a slot
                # only has to be shared between the operands of that single
                # instruction. Declaring it out here is only so the reload and
                # store closures above can see it.
                @off_of  = ();
                @order   = ();
                @type_of = ();
                my $opcode = $inst->opcode;
                my @ops    = $inst->operands->@*;

                # One slot per physical temp, and one reload per slot, so two
                # values that have to be live at the same time cannot land on
                # each other. A slot may hold more than one offset when the
                # instruction reads and writes the same spilled value, which
                # is a single value by definition.
                my $reserve = sub ( $off, $type ) {
                    for my $k ( 0 .. $#order ) {
                        return $k if $off_of[$k] == $off;
                    }
                    push @order, $off;
                    $off_of[$#order]  = $off;
                    $type_of[$#order] = $type;
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

                        # No type, because this slot holds the address rather
                        # than the value: the operand's own type is the width of
                        # what is being loaded through it, so an i8 field would
                        # have reloaded half the address.
                        $base_k = $reserve->( $off, undef );
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
                my $d_k   = $d_sp ? $reserve->( $d_off, $slot_type->( $ops[0]->type ) ) : undef;
                my $s_k   = $s_sp ? $reserve->( $s_off, $slot_type->( $ops[1]->type ) ) : undef;

                # A destination that the instruction also reads has to keep its
                # old value somewhere the write will not destroy, which is a
                # second temp holding the same offset. With no spilled base
                # there is no temp to collide with, so the destination's own
                # temp is still good.
                my $needs_old_d = $d_sp && $reads_dst{$opcode} && defined $base_k && $d_k == $base_k;
                my $old_k       = $d_k;
                if ($needs_old_d) {

                    # The base already holds a temp for this offset, and a temp
                    # that is about to be overwritten is not a place to keep it.
                    $old_k = $#order + 1;
                    push @order, $d_off;
                    $off_of[$old_k]  = $d_off;
                    $type_of[$old_k] = $slot_type->( $ops[0]->type );
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
                    my $k = $reserve->( $sp{$i}, $slot_type->( $ops[$i]->type ) );
                    push @extra_k, [ $k, $sp{$i} ];
                    $ops[$i] = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $temp_for->($k), type => $ops[$i]->type );
                }
                my @loads;
                push @loads, [ $base_k, $smem_off ] if defined $base_k;
                push @loads, [ $s_k,    $s_off ]    if $s_sp && !$same && !$can_mem_src{$opcode};
                push @loads, [ $old_k,  $d_off ]    if $needs_old_d;
                push @loads, @extra_k;
                push @new,   $load_inst->(@$_) for @loads;
                push @new,   Brocken::Jenny::MIR::MachineInstruction->new( opcode => $opcode, operands => [@ops], comment => $inst->comment, );

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

        # A slot here is eight bytes wide whatever it holds, and the width of a
        # floating-point move is taken from the operand type, so the save and
        # the restore have to carry one. Untyped, they both fell back to 32 bits
        # and every f64 live across a call was written and read back with
        # `movss`: four of the eight bytes moved, the other four left as whatever
        # the register already held, so the value came back as a denormal or a
        # NaN and any comparison against it was decided by stale register
        # contents. f64 is the right type to say for an f32 here too, since the
        # slot is eight bytes and the meaningful half is the low one.
        my $ftype = $is_float ? Brocken::Lindsay::IR::Type::f64() : undef;
        for my $bb ( $mf->blocks->@* ) {
            my @new;
            for my $inst ( $bb->instructions->@* ) {
                if ( $inst->opcode =~ /^(?:call_func|call_indirect|ctx_swap)$/ ) {
                    for my $r (@$caller_regs) {
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $stack_reg, disp => $spill_idx++ * 8 },
                            type  => $ftype,
                        );
                        push @new,
                            Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => $store_op,
                            operands => [ $mem, Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $r, type => $ftype ) ],
                            comment  => 'caller-save ' . $r,
                            );
                    }
                }
                push @new, $inst;
                if ( $inst->opcode =~ /^(?:call_func|call_indirect|ctx_swap)$/ ) {
                    for my $r ( reverse @$caller_regs ) {
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $stack_reg, disp => $spill_idx-- * 8 - 8 },
                            type  => $ftype,
                        );
                        push @new,
                            Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => $load_op,
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $r, type => $ftype ), $mem ],
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
    method fix_entry_shuffle( $mf, $assignment, $temp_reg, $fp_temp_reg = undef ) {
        my $entry = $mf->entry_block;
        return unless $entry;

        # Captures are the leading run of MOVs reading a physical register.
        # Later MOVs that read a physical register (a return value landing in a
        # register, say) are not part of this parallel move and must be left
        # where they are.  Floating-point captures come first in a function with
        # floating-point parameters, and they are `fmov` rather than `mov`, so
        # stopping at the first non-`mov` left them in whatever order the
        # parameter registers happened to be numbered: a capture that wrote
        # xmm1 came before a capture that read it, and the second parameter
        # arrived as a copy of the first.
        #
        # RISC-V spells an integer register move `mv` rather than `mov`, and a
        # capture that is not recognised ends the run early: with `fmov, mv,
        # fmov` the loop stopped at the `mv`, left one floating-point capture in
        # the prefix, and the `@prefix > 1` guard skipped the shuffle entirely,
        # so an interleaved parameter list read the same register twice.
        my @prefix;
        my @insts = $entry->instructions->@*;
        for my $inst (@insts) {
            last unless $inst->opcode eq 'mov' || $inst->opcode eq 'mv' || $inst->opcode eq 'fmov';
            my ( $dst, $src ) = $inst->operands->@*;
            last unless $src && $src->kind eq 'phys_reg';
            last unless $dst && ( $dst->kind eq 'phys_reg' || $dst->kind eq 'virt_reg' );
            push @prefix, { inst => $inst, src => $src->value, is_fp => ( $inst->opcode eq 'fmov' ? 1 : 0 ) };
        }
        return unless @prefix > 1;

        # A cycle is broken through the spill temp of its own class: a `mov`
        # cycle needs a general register and an `fmov` cycle a floating-point
        # one, and neither can stand in for the other.
        my @plan;
        for my $class ( [ 0, $temp_reg, 'mov' ], [ 1, $fp_temp_reg, 'fmov' ] ) {
            my ( $is_fp, $temp, $opcode ) = @$class;
            my ( @work, @parked );
            for my $cap (@prefix) {
                next unless $cap->{is_fp} == $is_fp;
                my $dst = $cap->{inst}->operands->[0];
                my $reg = $dst->kind eq 'phys_reg' ? $dst->value : $assignment->{ $dst->value };

                # A spilled or unresolved destination writes no register, so it
                # cannot clobber a source.  A `mov r, r` preserves its source.
                # Neither takes part in scheduling; both are still emitted.
                if ( !defined $reg || $reg =~ /^spill\(/ || $reg eq $cap->{src} ) {
                    push @parked, $cap;
                    next;
                }
                push @work, { cap => $cap, dst => $reg, src => $cap->{src} };
            }

            # One capture on its own cannot clobber a source, and none cannot
            # either, so there is nothing to order. They are still emitted: the
            # block is rebuilt from the plan, and dropping them here would take
            # them out of the instruction stream.
            if ( @work <= 1 ) {
                push @plan, @work, map { { cap => $_, src => $_->{src} } } @parked;
                next;
            }

            # Without a scratch of this class there is nothing to park a cycle
            # in, so the group keeps its original order rather than being
            # scheduled around a temp that does not exist.  The same goes for a
            # group the scheduler could not finish.  Either way its captures are
            # still emitted: the block is rebuilt from the plan, and leaving them
            # out would drop them.
            unless ( defined $temp ) {
                push @plan, @work, map { { cap => $_, src => $_->{src} } } @parked;
                next;
            }

            # The spill temp is excluded from allocation, so no capture writes it.
            # If that ever stops holding, decline rather than emit a shuffle we
            # cannot schedule.
            my %touched = map { $_ => 1 } map { ( $_->{dst}, $_->{src} ) } @work;
            if ( $touched{$temp} ) {
                push @plan, @work, map { { cap => $_, src => $_->{src} } } @parked;
                next;
            }
            my @steps;
            my $total  = scalar @work;
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
                    push @steps, { cap => undef, opcode => $opcode, dst => $temp, src => $head->{src} };
                    $head->{src} = $temp;
                    next;
                }
                push @steps, splice @work, $chosen, 1;
            }

            # A schedule step per capture, plus whatever temp parks it needed.
            if ( @steps < $total ) {
                push @plan, @work, map { { cap => $_, src => $_->{src} } } @parked;
                next;
            }
            push @plan, @steps;
            push @plan, map { { cap => $_, src => $_->{src} } } @parked;
        }
        return unless @plan;
        my @new;
        for my $step (@plan) {
            my $inst = $step->{cap} ? $step->{cap}{inst} : undef;
            if ($inst) {
                my $src = $inst->operands->[1];
                $inst->operands->[1] = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $step->{src}, type => $src->type );
                push @new, $inst;
            }
            else {
                push @new,
                    Brocken::Jenny::MIR::MachineInstruction->new(
                    opcode   => $step->{opcode},
                    operands => [
                        Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $step->{dst} ),
                        Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $step->{src} )
                    ],
                    comment => 'entry-shuffle save ' . $step->{src}
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
#
1;
