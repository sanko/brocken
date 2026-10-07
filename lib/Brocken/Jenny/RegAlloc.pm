use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
class Brocken::Jenny::RegAlloc::LiveInterval v0.0.1 {
    field $name  : param : reader;
    field $start : param : reader;
    field $end   : param : reader;
};
class Brocken::Jenny::RegAlloc::LinearScan v0.0.1 {
    use List::Util ();
    use Carp ();

    method allocate( $mf, $platform, $is_float = 0 ) {
        $mf->compute_cfg unless $mf->entry_block->successors->@*;
        my @intervals = $self->_compute_live_intervals( $mf, $platform, $is_float );

        # The address scratch is reserved on a second pass, and only when the first one actually produced a collision.
        # Reserving it up front is not
        # an option: almost every function has some addressable memory operand, so the reserve would shrink the
        # allocatable pool of nearly every function by one register and change assignments that were correct before.
        # Deciding after allocation is safe because the first pass has already chosen its registers, so the second pass
        # cannot be invalidated by the decision it makes.
        my $res = $self->_linear_scan( $mf, \@intervals, $platform, $is_float, 0 );
        if ( !defined $res->{spill_addr_temp} && $self->_has_addr_hazard( $mf, $res->{spill_slots} ) ) {
            $res = $self->_linear_scan( $mf, \@intervals, $platform, $is_float, 1 );
        }
        return $res;
    }

    # Does any instruction need a reloaded address and a reloaded value at once?
    #
    # This mirrors the decision insert_spill_code makes per instruction: a memory operand whose base is spilled has to
    # be reloaded into a register, and if the same instruction also has a spilled register operand that goes into the
    # value scratch, the two have to be different registers.  A load with only a spilled destination does not collide,
    # because the destination write consumes the address rather than needing it alongside the value.
    method _has_addr_hazard( $mf, $spill_slots ) {
        return 0 unless $spill_slots && keys %$spill_slots;
        for my $bb ( $mf->blocks->@* ) {
            for my $inst ( $bb->instructions->@* ) {
                my $addr_spilled = 0;
                my $val_spilled  = 0;
                for my $op ( $inst->operands->@* ) {
                    if ( $op->kind eq 'mem' ) {
                        my $base = $op->value->{base} // '';
                        $addr_spilled = 1 if defined $spill_slots->{$base};
                    }
                    elsif ( $op->kind eq 'virt_reg' ) {
                        $val_spilled = 1 if defined $spill_slots->{ $op->value };
                    }
                }
                return 1 if $addr_spilled && $val_spilled;
            }
        }
        return 0;
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

            # The physical stack register is named directly by a raw memory operand (an incoming or outgoing argument at
            # a fixed stack pointer offset).  It has no interval: nothing ever defines it, so treating it as a virtual
            # register would hand it an unrelated register and, under pressure, a spill slot whose reload would retarget
            # the operand.
            next if $base eq $platform->stack_reg;

            # Track virtual register names, but skip known physical register names (like r12, which the lowerer uses
            # directly in fiber memory operands).
            push @names, $base if $base ne '' && $base !~ $phys_re;
            my $index = $op->value->{index} // '';
            push @names, $index if $index ne '';
        }
        return @names;
    }

    method _register_operands($inst) {
        return $inst->operands->@*;
    }

    # Whether an instruction's first operand is a destination (written) rather than a source (read).
    method _defines_operand0($inst) {
        return 0 if $inst->opcode =~ /^(?:store|store_imm|bne|beq|cmp|fcmp|ctx_swap)$/;
        return 1;
    }

    # Walk one straight-line instruction list and collect the virtual registers it defines and uses.
    #
    # The reads of an instruction are recorded before its write, so a read-modify-write such as `mv X, X` marks X as
    # both.  Recording the write first would drop the read, and that misclassifies every loop-carried virtual register
    # that the loop body happens to touch first through a self-move: it would not reach the block's USE set, so its live
    # interval would stop at the self-move instead of running to the end of the block, and a later temporary would be
    # free to take the same physical register.  That silently destroyed a value across the loop back edge -- the q-bit
    # scratch was handed the register holding the running remainder high word of an i128 division.
    method _scan_insts( $insts, $is_float, $platform ) {
        my %defd;
        my %used;
        my %rmw = map { $_ => 1 } qw(add sub mul udiv sdiv div rem urem and or xor shl lshr ashr adc sbb fadd fsub fmul fdiv fmin fmax fxor fand);
        for my $inst ( $insts->@* ) {
            my @ops    = $self->_register_operands($inst);
            my $writes = @ops && $self->_defines_operand0($inst);
            my $dst;
            for my $i ( 0 .. $#ops ) {
                my $name = $self->_vreg_name( $ops[$i], $is_float );
                next unless defined $name;
                if ( $i == 0 && $writes ) {
                    $dst = $name;
                    $used{$name} = 1 if $rmw{$inst->opcode};
                    next;
                }
                $used{$name} = 1;
            }
            unless ($is_float) {
                $used{$_} = 1 for $self->_vreg_names_from_mem_operands( $inst, $platform );
            }
            $defd{$dst} = 1 if defined $dst;
        }
        return ( \%defd, \%used );
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

            # Detect intra-block loops: find the first label that is the target of a branch within the same block.  Such
            # blocks contain a preamble (pre-label) and a loop body (post-label).
            # Loop-carried vregs (defined in preamble, used in loop body) must appear in USE[b] so their live intervals
            # span the full block rather than ending at their last mention.
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
                my ( $pre_defd, $pre_used )   = $self->_scan_insts( \@pre_insts, $is_float, $platform );
                my ( $post_defd, $post_used ) = $self->_scan_insts( \@post_insts, $is_float, $platform );

                # use = pre_use U (pre_def ^ post_use)
                # def = pre_def U post_def
                for my $v ( keys %$pre_used ) {
                    $used{$v} = 1;
                }
                for my $v ( keys %$pre_defd ) {
                    $used{$v} = 1 if $post_used->{$v};
                }
                for my $v ( keys %$pre_defd ) {
                    $defd{$v} = 1;
                }
                for my $v ( keys %$post_defd ) {
                    $defd{$v} = 1;
                }
            }
            else {
                my ( $d, $u ) = $self->_scan_insts( [ $bb->instructions->@* ], $is_float, $platform );
                %defd = %$d;
                %used = %$u;
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
        if ( $ENV{BROCKEN_DUMP_INTERVALS} ) {
            for my $bi ( 0 .. $#blocks ) {
                printf STDERR "BLOCK %d: use=[%s] def=[%s]\n", $bi, join( ',', sort keys %{ $use{$bi} } ), join( ',', sort keys %{ $def{$bi} } );
            }
            printf STDERR "INTERVAL %-40s [%3d,%3d]\n", $_->name, $_->start, $_->end for @intervals;
        }
        return @intervals;
    }

    method _linear_scan( $mf, $intervals, $platform, $is_float, $need_addr_scratch = 0 ) {
        my @caller_regs = $is_float ? $platform->fp_registers('caller')->@* : $platform->registers('caller')->@*;
        my @callee_regs = $is_float ? $platform->fp_registers('callee')->@* : $platform->registers('callee')->@*;
        my $skip_reg    = $is_float ? $platform->fp_return_register         : $platform->return_register;
        my $fiber_reg   = $is_float ? undef                                 : $platform->fiber_reg;
        @caller_regs = grep { $_ ne $skip_reg } @caller_regs;
        @callee_regs = grep { $_ ne $skip_reg } @callee_regs;
        @caller_regs = grep { $_ ne $fiber_reg } @caller_regs if $fiber_reg;
        @callee_regs = grep { $_ ne $fiber_reg } @callee_regs if $fiber_reg;

        # Exclude physical registers that are used as destinations by any instruction in this function. This prevents
        # argument-setup MOVs (e.g. `mov rcx, virt`) from clobbering virt_reg values that the allocator may have
        # assigned to the same physical register.
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
                    next unless defined $dst->value;
                    $defined_phys{ $dst->value } = 1;
                }
            }
        }

        # Exclude r10/r11 when the function contains ctx_swap. The ctx_swap encoding body uses these as internal
        # temporaries (resume_pc and saved_rsp), making them invisible to the per-function phys_reg destination scan
        # above. Any virtual register allocated to r10 or r11 would have its value silently corrupted within ctx_swap.
        if ( $has_ctx_swap && !$is_float ) {
            $defined_phys{r10} = 1;
            $defined_phys{r11} = 1;
        }

        # Exclude rax/rdx when the function contains udiv, sdiv, umulh, div128_64, or rem128_64. Their codegen emits
        # inline assembly that clobbers rax and rdx (e.g. MOV RAX,dst; XOR RDX,RDX; DIV src; MOV dst,RAX) without
        # exposing those registers in the MIR operand list. Any virtual register assigned to rax or rdx would be
        # silently corrupted at the inline asm boundary.
        if ( !$is_float && $mf && $mf->blocks->@* ) {
            for my $mbb ( $mf->blocks->@* ) {
                for my $inst ( $mbb->instructions->@* ) {
                    if ( $inst->opcode =~ /^(?:udiv|sdiv|umulh|div128_64|rem128_64)$/ ) {
                        $defined_phys{rax} = 1;
                        $defined_phys{rdx} = 1;
                    }
                }
            }
        }

        # Exclude rax when the function contains fmov_gp2f.
        # The AMD Zen 4 erratum workaround in X86_64 codegen (fmov_gp2f with source in R8-R15) moves the GP source
        # through RAX via inline assembly bytes not visible in the MIR operand list. Any virtual register assigned to
        # rax would be silently corrupted.
        if ( !$is_float && $mf && $mf->blocks->@* ) {
            for my $mbb ( $mf->blocks->@* ) {
                for my $inst ( $mbb->instructions->@* ) {
                    if ( $inst->opcode eq 'fmov_gp2f' ) {
                        $defined_phys{rax} = 1;
                    }
                }
            }
        }

        # Exclude rcx when the function contains shl, lshr, or ashr.
        # Variable-count shift codegen (D3 /ext rm) emits MOV src -> ecx then SHL/ SHR /SAR dst, %cl. The MOV to ecx
        # silently clobbers whatever was in rcx, but the MIR operands (dst, src) do not expose this fixed-register
        # usage. Any virtual register assigned to rcx would be silently corrupted.
        if ( !$is_float && $mf && $mf->blocks->@* ) {
            for my $mbb ( $mf->blocks->@* ) {
                for my $inst ( $mbb->instructions->@* ) {
                    if ( $inst->opcode =~ /^(?:shl|lshr|ashr)$/ ) {
                        $defined_phys{rcx} = 1;
                    }
                }
            }
        }
        @caller_regs = grep { !$defined_phys{$_} } @caller_regs;
        @callee_regs = grep { !$defined_phys{$_} } @callee_regs;

        # A second scratch, for the address of a spilled memory operand.
        #
        # One scratch is not always enough: an instruction can need a reloaded address *and* a reloaded value at the
        # same time, which is what a store through a spilled address is (the address is one spilled value and the stored
        # value is another).  Reloading both into one scratch made the second overwrite the first, so the instruction
        # addressed memory through whatever the value happened to be -- usually a small integer, which is an unmapped
        # address.
        #
        # Taking the register out of the pool is what makes this expensive, and
        # it is expensive: which virtual registers a function can hold depends on how many registers are left, so one
        # register fewer re-shuffles the assignment of a function that was already correct.  Every register below is
        # therefore drawn first from the registers this function cannot use anyway, which costs the assignment nothing,
        # and only falls back to the pool when there is no such register left.  The register is reserved at all only
        # when the function can need it; see _has_addr_hazard for why that is decided after the first pass.
        my $spill_temp = pop @caller_regs;

        # A register that is in neither pool and that the scan above did not pin
        # is free to clobber: nothing in the function holds a value in it.  The return register is the usual one, since
        # it is excluded from both pools by construction, and the reloads using it are always immediately followed by
        # the instruction that consumes them.
        my @spare;
        if ($need_addr_scratch) {
            my %pool = map { $_ => 1 } ( @caller_regs, @callee_regs, $spill_temp );
            my $all  = $is_float ? [ $platform->fp_registers('caller')->@*, $platform->fp_registers('callee')->@* ] :
                [ $platform->registers('caller')->@*, $platform->registers('callee')->@* ];
            my %seen;
            for my $r ( ( defined $skip_reg ? ($skip_reg) : () ), @$all ) {
                next if $seen{$r}++ || $pool{$r} || $defined_phys{$r};
                next if defined $fiber_reg && $r eq $fiber_reg;
                push @spare, $r;
            }
        }
        my $spill_addr_temp = pop @spare;
        my $addr_is_callee  = 0;
        if ( !defined $spill_addr_temp && $need_addr_scratch ) {

            # Nothing is free, so the register has to come out of the pool.  The
            # callee set first: it is in no argument file, so a caller-register shortage cannot turn into a different
            # stack argument layout.  The price is an extra prologue save.
            $spill_addr_temp = pop @callee_regs;
            $addr_is_callee  = 1;
        }
        if ( !defined $spill_addr_temp && $need_addr_scratch ) {
            $spill_addr_temp = pop @caller_regs;
            $addr_is_callee  = 0;
        }
        Carp::croak('no register available for the spill address scratch') if $need_addr_scratch && !defined $spill_addr_temp;
        my @regs = ( @caller_regs, @callee_regs );
        my %assignment;
        my %used_callee;
        $used_callee{$spill_addr_temp} = 1 if $addr_is_callee;
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
                if ( $spill->end > $int->end ) {
                    my $freed_reg = $assignment{ $spill->name };
                    $spill_slots{ $spill->name } = $next_spill++ * 8;
                    $assignment{ $spill->name }  = 'spill(' . $spill_slots{ $spill->name } . ')';
                    @active                      = grep { $_->name ne $spill->name } @active;
                    $assignment{ $int->name }    = $freed_reg;
                    $used_callee{$freed_reg}     = 1 if grep { $_ eq $freed_reg } @callee_regs;
                    push @active, $int;
                }
                else {
                    $spill_slots{ $int->name } = $next_spill++ * 8;
                    $assignment{ $int->name }  = 'spill(' . $spill_slots{ $int->name } . ')';
                }
            }
        }
        return {
            assignment      => \%assignment,
            used_callee     => [ sort keys %used_callee ],
            spill_slots     => \%spill_slots,
            spill_temp      => $spill_temp,
            spill_addr_temp => $spill_addr_temp,
        };
    }

    method insert_spill_code( $mf, $spill_slots, $spill_temp, $stack_reg, $is_float = 0, $spill_addr_temp = undef ) {
        return unless $spill_slots && keys %$spill_slots;
        my $load_op     = $is_float ? 'fload'  : 'load';
        my $store_op    = $is_float ? 'fstore' : 'store';
        my %reads_dst   = map { $_ => 1 } qw(add sub mul sdiv udiv div rem urem adc sbb and or xor cmp shl shr sar neg inc dec not bne beq fadd fsub fmul fdiv fmin fmax fxor fand);
        my %can_mem_src = map { $_ => 1 } qw(add sub adc sbb and or xor cmp);
        my $temp_op     = sub { Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $spill_temp, type => undef ) };

        # Falls back to the value scratch when no address scratch was reserved.
        # That is safe for the same reason the memory base falls back below: the reservation happens exactly when an
        # address and a value would be live together, so sharing is only reached when nothing else is live in it.
        my $addr_reg = defined $spill_addr_temp ? $spill_addr_temp : $spill_temp;
        my $addr_op  = sub { Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $addr_reg, type => undef ) };
        my $mem_op
            = sub ($o) { Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => $stack_reg, disp => $o }, type => undef ) };
        my $load_inst = sub ($o) {
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => $load_op,
                operands => [ $temp_op->(), $mem_op->($o) ],
                comment  => 'spill-reload'
            );
        };

        # The address of a spilled memory operand is reloaded into the address scratch, not the value scratch, so an
        # instruction that also reloads a value keeps both live at once.
        my $load_addr_inst = sub ($o) {
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => $load_op,
                operands => [ $addr_op->(), $mem_op->($o) ],
                comment  => 'spill-reload-addr'
            );
        };
        my $store_inst = sub ($o) {
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => $store_op,
                operands => [ $mem_op->($o), $temp_op->() ],
                comment  => 'spill-store'
            );
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
                        $op->value->{base} = $addr_reg;
                    }
                }
                if ( !keys %sp && !defined $smem_off ) {
                    push @new, $inst;
                    next;
                }
                # Which operand positions the encoder can take straight from memory.  A spilled operand there costs
                # no scratch at all, which matters when an instruction reads several sources at once: the reload
                # scratch is a single register, so two reloaded sources would otherwise overwrite each other before
                # the instruction ran.  `div128_64`/`rem128_64` read three sources and write one, so every position
                # (including the destination) may be memory.
                my %mem_ok;
                if ( $opcode eq 'div128_64' || $opcode eq 'rem128_64' ) {
                    $mem_ok{$_} = 1 for 0 .. 3;
                }
                elsif ( $can_mem_src{$opcode} || $opcode eq 'mul' || $opcode eq 'udiv' || $opcode eq 'sdiv' ) {
                    $mem_ok{1} = 1;
                }

                # A spilled operand that is not taken from memory is reloaded into the single value
                # scratch, so the reload below matches this assignment.
                my @load_offsets;
                my $store_off;
                for my $i ( 0 .. $#ops ) {
                    next unless defined $sp{$i};
                    if ( $mem_ok{$i} ) {
                        $ops[$i] = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $stack_reg, disp => $sp{$i} },
                            type  => $ops[$i]->type,
                        );
                        next;
                    }
                    $ops[$i] = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $spill_temp, type => $ops[$i]->type );
                    if ( $i == 0 ) {
                        push @load_offsets, $sp{0} if $reads_dst{$opcode};
                        $store_off = $sp{0};
                    }
                    else {
                        push @load_offsets, $sp{$i};
                    }
                }

                # Address first: it lands in its own scratch and stays valid
                # while the value scratch is reused below.
                push @new, $load_addr_inst->($smem_off) if defined $smem_off;
                push @new, $load_inst->($_) for @load_offsets;
                push @new, Brocken::Jenny::MIR::MachineInstruction->new( opcode => $opcode, operands => [@ops], comment => $inst->comment, );
                push @new, $store_inst->($store_off) if defined $store_off;
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
                if ( $inst->opcode =~ /^(?:call_func|call_indirect|ctx_swap|syscall)$/ ) {
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
                if ( $inst->opcode =~ /^(?:call_func|call_indirect|ctx_swap|syscall)$/ ) {
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
    # The lowerer emits one `<move> <dst>, <param_reg>` per incoming argument at the very top of the entry block, so the
    # captures read the caller's argument registers simultaneously -- they behave like a parallel move, not a sequence.
    # Once the allocator picks destinations, a destination may land on a register that a *later* capture still has to
    # read.
    #
    # Parking every such source in the one spill temp is not enough: each new park overwrites the previous one, so only
    # the last value survives.  A temp that is not reserved from allocation (the second argument the old call sites
    # passed) can itself be a capture destination, which is how a parked value was clobbered and a parameter read back
    # as its neighbour.
    # So schedule the captures as a real parallel move: emit any capture whose destination is not a pending source, and
    # break a cycle by parking a single source in the temp of that capture's own register class, which frees the temp
    # again as soon as its one consumer runs.
    method fix_entry_shuffle( $mf, $assignment, $temp_reg, $fp_temp_reg = undef ) {
        my $entry = $mf->entry_block;
        return unless $entry;

        # Captures are the leading run of register moves reading a physical register.  Later moves that read a physical
        # register (a return value landing in a register, say) are not part of this parallel move and must be left where
        # they are.  A floating-point capture is an `fmov` and a RISC-V integer capture a `mv`, not a `mov`, so a scan
        # that recognised only `mov` stopped at the first one and left the rest unscheduled -- a capture that wrote a
        # register could land before one that read it, and an argument arrived as a copy of its neighbour.
        my $is_capture = sub {
            my ($inst) = @_;
            return 0 unless $inst;
            return 0 unless $inst->opcode eq 'mov' || $inst->opcode eq 'mv' || $inst->opcode eq 'fmov';
            my ( $dst, $src ) = $inst->operands->@*;
            return 0 unless $src && $src->kind eq 'phys_reg';
            return $dst && ( $dst->kind eq 'phys_reg' || $dst->kind eq 'virt_reg' ) ? 1 : 0;
        };
        my ( @prefix, @tokens );
        my @insts = $entry->instructions->@*;

        # A load reads memory and writes a virtual register, so it neither reads nor clobbers a register the captures
        # shuffle.  One can sit among them -- a parameter that arrived on the stack is read there -- and the captures on
        # either side of it belong to the same parallel move.  Treating the load as the end of the run instead stranded
        # the
        # captures after it: they kept their original order, so a floating-point capture ran after another had already
        # written the register it read and an argument arrived as its neighbour.
        #
        # A load with no capture after it ends the run rather than widening it over the rest of the block, which by now
        # carries the spill reloads that the captures are interleaved among.
        for ( my $k = 0; $k < @insts; $k++ ) {
            my $inst = $insts[$k];
            if ( $is_capture->($inst) ) {
                my ( $dst, $src ) = $inst->operands->@*;
                push @prefix, { inst   => $inst, src => $src->value, is_fp => ( $inst->opcode eq 'fmov' ? 1 : 0 ) };
                push @tokens, { is_cap => 1 };
                next;
            }
            last unless $inst->opcode eq 'load' || $inst->opcode eq 'fload';
            last unless $is_capture->( $insts[ $k + 1 ] );
            push @tokens, { is_cap => 0, inst => $inst };
        }
        return unless @prefix > 1;

        # A cycle is broken through the spill temp of its own class: a `mov` cycle needs a general register and an
        # `fmov` cycle a floating-point one, and neither can stand in for the other.
        my @plan;
        for my $class ( [ 0, $temp_reg, 'mov' ], [ 1, $fp_temp_reg, 'fmov' ] ) {
            my ( $is_fp, $temp, $opcode ) = @$class;
            my ( @work, @parked );
            for my $cap (@prefix) {
                next unless $cap->{is_fp} == $is_fp;
                my $dst = $cap->{inst}->operands->[0];
                my $reg = $dst->kind eq 'phys_reg' ? $dst->value : $assignment->{ $dst->value };

                # A spilled or unresolved destination writes no register, so it cannot clobber a source.  A `mov r, r`
                # preserves its source.
                # Neither takes part in scheduling; both are still emitted.
                if ( !defined $reg || $reg =~ /^spill\(/ || $reg eq $cap->{src} ) {
                    push @parked, $cap;
                    next;
                }
                push @work, { cap => $cap, dst => $reg, src => $cap->{src} };
            }

            # One capture on its own cannot clobber a source, and none cannot either, so there is nothing to order.
            # They are still emitted: the block is rebuilt from the plan, and dropping them here would take them out of
            # the instruction stream.
            if ( @work <= 1 ) {
                push @plan, @work, map { { cap => $_, src => $_->{src} } } @parked;
                next;
            }

            # Without a scratch of this class there is nothing to park a cycle in, so the group keeps its original order
            # rather than being scheduled around a temp that does not exist.  The same goes for a group the scheduler
            # could not finish.  Either way its captures
            # are still emitted: the block is rebuilt from the plan, and leaving them out would drop them.
            unless ( defined $temp ) {
                push @plan, @work, map { { cap => $_, src => $_->{src} } } @parked;
                next;
            }

            # The spill temp is excluded from allocation, so no capture writes it.  If that ever stops holding, decline
            # rather than emit a shuffle we cannot schedule.
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

                    # Every remaining destination is still needed as a source, so the rest is a cycle.  Park one source
                    # in the temp and reschedule; its consumer runs before the temp is reused.
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

        # Group the plan so that a cycle parked in the temp travels with the capture that consumes it, and keep the
        # register each capture reads.
        my @groups;
        my @pending;
        for my $step (@plan) {
            if ( $step->{cap} ) {
                push @groups, { lead => [@pending], inst => $step->{cap}{inst}, src => $step->{src} };
                @pending = ();
                next;
            }
            push @pending,
                Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => $step->{opcode},
                operands => [
                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $step->{dst} ),
                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $step->{src} )
                ],
                comment => 'entry-shuffle save ' . $step->{src}
                );
        }

        # Each capture is re-emitted in the scheduled order but keeps the slot it already occupied, and a load read
        # among the captures stays where
        # it was: a stack parameter is addressed against the stack pointer the prologue left, so the load cannot be
        # moved to suit the shuffle.
        my @new;
        for my $token (@tokens) {
            if ( !$token->{is_cap} ) { push @new, $token->{inst}; next }
            my $group = shift @groups;
            last unless $group;
            push @new, @{ $group->{lead} };
            my $cap = $group->{inst};
            my $src = $cap->operands->[1];
            $cap->operands->[1] = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $group->{src}, type => $src->type );
            push @new, $cap;
        }
        splice $entry->instructions->@*, 0, scalar @tokens, @new;
    }

    # Schedule the argument copies before a call as a parallel move.
    #
    # The lowerer emits one move per register argument just before each call, in reverse order, on the theory that
    # setting the first argument last keeps a later move from clobbering it.  That holds only for a chain whose
    # sources are never themselves written: with two floating-point arguments allocated to xmm1 and xmm2, reversing
    # emits the copy into xmm1 first and destroys the source of the copy into xmm0, so the earlier argument reads back
    # as its neighbour.  The reverse order is not a parallel move; this is.
    #
    # An argument register is both the destination of one copy and, once the allocator has run, the place a source can
    # live, so the copies are
    # unordered and have to be scheduled: emit any copy whose destination no remaining copy still reads, and break a
    # cycle by parking one source in the spill temp of its own class.  A run that already has no collision is left
    # exactly as the lowerer wrote it, so nothing that worked moves.
    #
    # Only plain register copies take part.  A stack store, an immediate, a spilled source (whose reload is not part of
    # the run) or anything else makes the group one this scheduler cannot see through, and it is left alone rather than
    # reordered on incomplete information.
    method fix_call_shuffle( $mf, $assignment, $int_temp, $fp_temp ) {
        my $reg_of = sub ($op) {
            return undef unless $op;
            return $op->value if $op->kind eq 'phys_reg';
            if ( $op->kind eq 'virt_reg' ) {
                my $a = $assignment->{ $op->value };
                return undef unless defined $a;
                return undef if $a eq '' || $a =~ /^spill\(/;
                return $a;
            }
            return undef;
        };
        my $is_arg = sub ($inst) {
            my $op = $inst->opcode  // '';
            my $cm = $inst->comment // '';
            return ( $op =~ /^(?:mov|mv|fmov|lea_rodata)$/ && $cm =~ /^(?:arg \d|isolate arg|syscall arg|box: arg)/ ) ? 1 : 0;
        };
        for my $bb ( $mf->blocks->@* ) {
            my @insts = $bb->instructions->@*;
            my @calls;
            for my $ci ( 0 .. $#insts ) {
                push @calls, $ci if $insts[$ci]->opcode =~ /^(?:call_func|call_indirect|ctx_swap|syscall)$/;
            }
            for my $ci ( reverse @calls ) {
                my $last = $ci - 1;
                $last-- while $last >= 0 && ( $insts[$last]->comment // '' ) =~ /^caller-save /;
                next if $last < 0 || !$is_arg->( $insts[$last] );
                my $first = $last;
                $first-- while $first > 0 && $is_arg->( $insts[ $first - 1 ] );
                my @run = @insts[ $first .. $last ];
                next unless @run > 1;
                my @items;
                my $understood = 1;

                for my $inst (@run) {
                    my ( $dst, $src ) = $inst->operands->@*;
                    my ( $w,   $r )   = ( [], [] );
                    if ( $inst->opcode eq 'lea_rodata' ) {
                        my $d = $reg_of->($dst);
                        ( $understood = 0 ), last unless defined $d;
                        push @$w, $d;
                    }
                    else {
                        my $d = $reg_of->($dst);
                        my $s = $reg_of->($src);
                        ( $understood = 0 ), last unless defined $d && defined $s;
                        push @$w, $d;
                        push @$r, $s;
                    }
                    push @items,
                        {
                        inst   => $inst,
                        writes => $w,
                        reads  => $r,
                        is_fp  => ( $inst->opcode eq 'fmov' ? 1 : 0 ),
                        opcode => $inst->opcode,
                        type   => $src ? $src->type : undef,
                        };
                }
                next unless $understood;
                my %touch;
                $touch{$_} = 1 for map { $_->@* } map { ( $_->{writes}, $_->{reads} ) } @items;
                next if $int_temp && $touch{$int_temp};
                next if $fp_temp  && $touch{$fp_temp};
                my $hazard = 0;
                for my $x (@items) {
                    for my $y (@items) {
                        next if $x == $y;
                        for my $reg ( $y->{reads}->@* ) {
                            $hazard = 1 if grep { $_ eq $reg } $x->{writes}->@*;
                        }
                    }
                }
                next unless $hazard;
                my @rem = @items;
                my @plan;
                my $scheduled = 1;
                my $budget    = 4 * scalar(@rem);
                while (@rem) {
                    my $chosen;
                    for my $k ( 0 .. $#rem ) {
                        my %w     = map { $_ => 1 } $rem[$k]{writes}->@*;
                        my $clash = 0;
                        for my $j ( 0 .. $#rem ) {
                            next if $j == $k;
                            for my $reg ( $rem[$j]{reads}->@* ) { $clash = 1 if $w{$reg}; }
                        }
                        if ( !$clash ) { $chosen = $k; last; }
                    }
                    if ( defined $chosen ) { push @plan, splice @rem, $chosen, 1; next; }
                    if ( --$budget < 0 )   { $scheduled = 0;                      last; }
                    my ($head) = grep { $_->{reads}->@* } @rem;
                    if ( !$head ) { $scheduled = 0; last; }
                    my $temp = $head->{is_fp} ? $fp_temp : $int_temp;
                    if ( !defined $temp ) { $scheduled = 0; last; }
                    push @plan, { park => 1, opcode => $head->{opcode}, temp => $temp, src => $head->{reads}->[0], type => $head->{type} };
                    $head->{reads} = [$temp];
                }
                next unless $scheduled;
                my @new;
                for my $step (@plan) {
                    if ( $step->{park} ) {
                        push @new,
                            Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => $step->{opcode},
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $step->{temp}, type => $step->{type} ),
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $step->{src},  type => $step->{type} )
                            ],
                            comment => 'call-shuffle save ' . $step->{src}
                            );
                        next;
                    }
                    my $inst = $step->{inst};
                    if ( $inst->opcode eq 'lea_rodata' || !$step->{reads}->@* ) {

                        # A lea_rodata load has no register source; rewriting operand 1 would turn its label into an
                        # undef phys_reg.
                    }
                    else {
                        $inst->operands->[1]
                            = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $step->{reads}->[0], type => $step->{type} );
                    }
                    push @new, $inst;
                }
                splice @insts, $first, scalar(@run), @new;
            }
            $bb->instructions->@* = @insts;
        }
    }

    method compute_unified_frame( $num_callee, $spill_frame, $caller_save_size ) {
        my $frame = $num_callee * 8 + $spill_frame + $caller_save_size;
        return ( $frame + 15 ) & ~15;
    }
};
#
1;
