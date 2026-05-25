use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Compiler::LivenessAnalyzer {

    method analyze($cfg) {
        my @blocks = $cfg->blocks;
        
        # Initial empty sets
        for my $block (@blocks) {
            $block->set_live_in();
            $block->set_live_out();
        }

        my $changed = 1;
        while ($changed) {
            $changed = 0;
            # Backward analysis
            for my $block (reverse @blocks) {
                my %old_live_in = $block->live_in;
                
                # LiveOut[b] = ∪ { LiveIn[s] | s ∈ successors(b) }
                my %new_live_out;
                my @succs = $self->_get_successors($cfg, $block);
                for my $s (@succs) {
                    my %sli = $s->live_in;
                    for my $var (keys %sli) {
                        $new_live_out{$var} = 1;
                    }
                }
                $block->set_live_out(%new_live_out);

                # LiveIn[b] = use[b] ∪ (LiveOut[b] - def[b])
                # We need to process instructions in the block backward too
                my %current_live = %new_live_out;
                
                # Process terminator first (it's the last "instruction")
                if ($block->terminator) {
                    my @defs = $block->terminator->defs;
                    my @uses = $block->terminator->uses;
                    delete $current_live{$_} for @defs;
                    $current_live{$_} = 1 for @uses;
                }

                # Process instructions backward
                for my $instr (reverse $block->instructions) {
                    my @defs = $instr->defs;
                    my @uses = $instr->uses;
                    delete $current_live{$_} for @defs;
                    $current_live{$_} = 1 for @uses;
                }
                
                $block->set_live_in(%current_live);

                # Check if LiveIn changed
                if (scalar(keys %current_live) != scalar(keys %old_live_in)) {
                    $changed = 1;
                } else {
                    for my $var (keys %current_live) {
                        if (!exists $old_live_in{$var}) {
                            $changed = 1;
                            last;
                        }
                    }
                }
            }
        }
    }

    method _get_successors($cfg, $block) {
        my $term = $block->terminator;
        return () unless $term;
        
        my @succs;
        if ($term->isa('Brocken::IR::Jump')) {
            push @succs, $cfg->get_block($term->target);
        } elsif ($term->isa('Brocken::IR::Branch')) {
            # Successor 1: the target label
            push @succs, $cfg->get_block($term->target);
            
            # Successor 2: the next block in sequence (fallthrough)
            # This assumes the CFG blocks are in an order where the fallthrough is the next one.
            # In a more robust CFG, this would be explicitly linked.
            my @blocks = $cfg->blocks;
            for (my $i = 0; $i < @blocks - 1; $i++) {
                if ($blocks[$i]->name eq $block->name) {
                    push @succs, $blocks[$i+1];
                    last;
                }
            }
        }
        return grep { defined } @succs;
    }
}
1;
