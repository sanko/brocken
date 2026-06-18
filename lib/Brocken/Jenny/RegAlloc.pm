use v5.42;
use feature qw[class];

class Brocken::Jenny::RegAlloc::LiveInterval {
    field $name  : param : reader;
    field $start : param : reader;
    field $end   : param : reader;
}

class Brocken::Jenny::RegAlloc::LinearScan {

    method allocate( $mf, $platform, $is_float = 0 ) {
        my @intervals = $self->_compute_live_intervals( $mf, $is_float );
        return $self->_linear_scan( \@intervals, $platform, $is_float );
    }

    method _compute_live_intervals( $mf, $is_float ) {
        my ( %first, %last );
        my $idx = 0;
        for my $bb ( $mf->blocks->@* ) {
            for my $inst ( $bb->instructions->@* ) {
                for my $op ( $inst->operands->@* ) {
                    if ( $op->kind eq 'virt_reg' ) {
                        my $name = $op->value;
                        my $type = $op->type;
                        my $is_f = $type ? ( $type->kind eq 'float' ) : 0;
                        next if $is_float != $is_f;
                        $first{$name} //= $idx;
                        $last{$name} = $idx;
                    }
                    elsif ( $op->kind eq 'mem' ) {
                        my $base = $op->value->{base};
                        next if $is_float;
                        $first{$base} //= $idx;
                        $last{$base} = $idx;
                    }
                }
                $idx++;
            }
        }
        my @intervals;
        for my $name ( sort { $first{$a} <=> $first{$b} } keys %first ) {
            push @intervals, Brocken::Jenny::RegAlloc::LiveInterval->new( name => $name, start => $first{$name}, end => $last{$name} );
        }
        return @intervals;
    }

    method _linear_scan( $intervals, $platform, $is_float ) {
        my @caller_regs = $is_float ? $platform->fp_registers('caller')->@* : $platform->registers('caller')->@*;
        my @callee_regs = $is_float ? $platform->fp_registers('callee')->@* : $platform->registers('callee')->@*;
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
        return {
            assignment  => \%assignment,
            used_callee => [ sort keys %used_callee ],
            spill_slots => \%spill_slots,
            spill_temp  => $spill_temp,
        };
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
                    my $new_inst
                        = Brocken::Jenny::MIR::MachineInstruction->new( opcode => $opcode, operands => \@ops, comment => $inst->comment, );
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
}
1;
