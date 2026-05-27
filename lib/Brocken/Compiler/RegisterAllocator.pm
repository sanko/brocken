use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Compiler::RegisterAllocator {
    field $abi  : reader : param;
    field $arch : reader : param;
    field %mapping;
    field @free_registers;
    field @active;    # Currently active intervals

    method allocate($cfg) {
        %mapping        = ();
        @free_registers = $abi->available_registers($arch);
        @active         = ();

        # 1. Compute live intervals
        my %intervals = $self->_compute_intervals($cfg);

        # 2. Sort intervals by start point
        my @sorted_vregs = sort { $intervals{$a}->{start} <=> $intervals{$b}->{start} } keys %intervals;

        # 3. Linear Scan
        for my $vreg (@sorted_vregs) {
            $self->_expire_old_intervals( $intervals{$vreg}->{start} );
            if ( !@free_registers ) {
                $self->_spill_at_interval( $vreg, \%intervals );
            }
            else {
                my $reg = shift @free_registers;
                $mapping{$vreg} = $reg;
                push @active, { vreg => $vreg, end => $intervals{$vreg}->{end} };
                @active = sort { $a->{end} <=> $b->{end} } @active;
            }
        }
        return \%mapping;
    }

    method _compute_intervals($cfg) {
        my %intervals;
        my $pos = 0;
        for my $block ( $cfg->blocks ) {

            # We treat instructions in sequence across blocks for simple linear scan
            # In a better version, we'd use a depth-first ordering
            for my $instr ( $block->instructions, ( $block->terminator // () ) ) {
                my @uses = $instr->uses;
                my @defs = $instr->defs;
                for my $vreg ( @uses, @defs ) {
                    if ( !exists $intervals{$vreg} ) {
                        $intervals{$vreg} = { start => $pos, end => $pos };
                    }
                    else {
                        $intervals{$vreg}->{end} = $pos;
                    }
                }
                $pos++;
            }
        }
        return %intervals;
    }

    method _expire_old_intervals($start) {
        while ( @active && $active[0]->{end} < $start ) {
            my $interval = shift @active;
            push @free_registers, $mapping{ $interval->{vreg} };
        }
    }

    method _spill_at_interval( $vreg, $intervals ) {
        my $spill = $active[-1];
        if ( $spill->{end} > $intervals->{$vreg}->{end} ) {
            $mapping{$vreg} = $mapping{ $spill->{vreg} };
            delete $mapping{ $spill->{vreg} };
            $mapping{ $spill->{vreg} } = 'stack';    # Placeholder for spill
            pop @active;
            push @active, { vreg => $vreg, end => $intervals->{$vreg}->{end} };
            @active = sort { $a->{end} <=> $b->{end} } @active;
        }
        else {
            $mapping{$vreg} = 'stack';
        }
    }
}
1;
