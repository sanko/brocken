use v5.42;
use feature qw[class];
no warnings qw[portable];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Lowerer::Wasm;
use Brocken::Jenny::RegAlloc;
use Brocken::Jenny::MIR;

class Brocken::Jenny::Codegen::Wasm {
    field $platform : param;

    method emit_function($ir_func) {
        my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
        my $mf      = $lowerer->lower($ir_func);
        my %ir_types;
        for my $block ( $ir_func->blocks->@* ) {
            for my $inst ( $block->instructions->@* ) {
                $ir_types{ $inst->name } = $inst->type if $inst->name;
            }
        }
        for my $mbb ( $mf->blocks->@* ) {
            for my $mi ( $mbb->instructions->@* ) {
                for my $mo ( $mi->operands->@* ) {
                    $ir_types{ $mo->value } = $mo->type if $mo->kind eq 'virt_reg' && $mo->value && $mo->type;
                }
            }
        }
        my ( $result, $fixups ) = $self->_encode( $mf, $ir_func->params, \%ir_types, $ir_func->return_type );
        $result->{fixups} = $fixups if @$fixups;
        $result->{name}   = $ir_func->name;
        return $result;
    }

    method emit_functions($ir_funcs) {
        my @funcs;
        for my $ir_func ( $ir_funcs->@* ) {
            my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
            my $mf      = $lowerer->lower($ir_func);
            my %ir_types;
            for my $block ( $ir_func->blocks->@* ) {
                for my $inst ( $block->instructions->@* ) {
                    $ir_types{ $inst->name } = $inst->type if $inst->name;
                }
            }
            for my $mbb ( $mf->blocks->@* ) {
                for my $mi ( $mbb->instructions->@* ) {
                    for my $mo ( $mi->operands->@* ) {
                        $ir_types{ $mo->value } = $mo->type if $mo->kind eq 'virt_reg' && $mo->value && $mo->type;
                    }
                }
            }
            my ( $result, $fixups ) = $self->_encode( $mf, $ir_func->params, \%ir_types, $ir_func->return_type );
            my @param_valtypes;
            for my $p ( $ir_func->params->@* ) {
                push @param_valtypes, $self->_wasm_valtype( $p->type );
            }
            my $locals_size = length( $result->{locals} );
            my @adjusted_fixups;
            for my $fx ( $fixups->@* ) {
                push @adjusted_fixups, { %$fx, offset => $fx->{offset} + $locals_size };
            }
            push @funcs,
                {
                name           => $ir_func->name,
                bytes          => $result->{locals} . $result->{body},
                fixups         => \@adjusted_fixups,
                return_valtype => $result->{return_valtype},
                param_valtypes => \@param_valtypes,
                };
        }
        return \@funcs;
    }

    method _encode( $mf, $ir_params, $ir_types, $return_type ) {
        my $bytes       = '';
        my %vreg_map    = ();
        my $next_local  = scalar( $ir_params->@* );

        # Fixups are collected per block and rebased onto the function body
        # during assembly below.
        my @block_fixups = ();

        # Map parameters to locals 0..N-1
        for my $i ( 0 .. ( $next_local - 1 ) ) {
            $vreg_map{ $ir_params->[$i]->name } = $i;
        }

    # The heap base. Every heap block -- object fields, array slots, boxes --
    # comes from Brocken::Runtime::bump_alloc, which needs the base as its
    # first argument, and the base reaches the module as an argument to
    # _BROCKEN_ENTRY only. A slot can be allocated in any function, so the
    # value is published in a module global (section 6) that every frame
    # shares; the linker emits it and the entry stub seeds it from the
    # %__heap_base argument.
    #
    # This used to be a bump pointer rather than a base, which meant escaping
    # allocas advanced their own copy of the cursor while objects advanced the
    # one inside the runtime header. Both started at the heap base, so the two
    # hands of the allocator could hand out the same bytes. Reading the base
    # and letting the one allocator advance it removes the second cursor.
    use constant HEAP_BASE_GLOBAL => 0;

        my @blocks = $mf->blocks->@*;
        my $nb     = scalar @blocks;
        my %label_to_block_idx;
        for my $bi ( 0 .. $nb - 1 ) {
            for my $inst ( $blocks[$bi]->instructions->@* ) {
                $label_to_block_idx{ $inst->operands->[0]->value } = $bi if $inst->opcode eq 'label';
            }
        }

        # Successors, read off the terminator. A block ends in `jmp`, `br-if`,
        # or `ret`, so nothing should depend on falling into the next block;
        # anything else is treated as a fall-through to the MIR successor and
        # given an explicit branch, which is what lets the emitted order differ
        # from the MIR order below.
        my ( %succ, %fallthru );
        for my $bi ( 0 .. $nb - 1 ) {
            my @s;
            my $instrs = $blocks[$bi]->instructions;
            my $last_op = @$instrs ? $instrs->[-1]->opcode : undef;
            for my $inst (@$instrs) {
                next unless $inst->opcode eq 'jmp' || $inst->opcode eq 'bne';
                my $t = $label_to_block_idx{ $inst->operands->[0]->value };
                push @s, $t if defined $t;
            }
            if ( !defined $last_op || ( $last_op ne 'jmp' && $last_op ne 'ret' ) ) {
                if ( $bi + 1 < $nb ) { $fallthru{$bi} = $bi + 1; push @s, $bi + 1 }
            }
            $succ{$bi} = \@s;
        }

        # Depth-first walk to find the back edges. An edge to a block still on
        # the DFS stack closes a cycle, and its target is a loop header.
        my ( %preds, %is_back, %seen, %on_stack );
        for my $bi ( 0 .. $nb - 1 ) {
            push @{ $preds{$_} }, $bi for @{ $succ{$bi} // [] };
        }
        my $dfs;
        $dfs = sub {
            my ($bi) = @_;
            $on_stack{$bi} = 1;
            for my $s ( @{ $succ{$bi} // [] } ) {
                if   ( $on_stack{$s} ) { $is_back{"$bi>$s"} = 1 }
                elsif ( !$seen{$s} )   { $seen{$s} = 1; $dfs->($s) }
            }
            delete $on_stack{$bi};
        };
        for my $root ( 0 .. $nb - 1 ) {
            next if $seen{$root};
            $seen{$root} = 1;
            $dfs->($root);
        }

        # Natural loop body per header: the header plus everything that reaches
        # the back edge without going back through the header. The walk stops at
        # anything the header cannot reach, which is what keeps a preheader out.
        # Without that stop every block feeding the header is pulled in, so a
        # loop wrapped in an `if` swallows the whole `if` and the condition
        # ends up inside the loop it guards. Reducible CFGs, which is all the
        # frontend produces, make these laminar, so each block sits in one
        # innermost loop.
        my ( %loop_body, %loop_header );
        for my $edge ( sort keys %is_back ) {
            my ( $u, $h ) = split />/, $edge, 2;
            $loop_header{$h} = 1;
            $loop_body{$h} //= { $h => 1 };

            # What the header reaches without passing back through itself.
            my ( @todo, %from_header );
            $from_header{$h} = 1;
            push @todo, $h;
            while (@todo) {
                my $n = shift @todo;
                for my $s ( @{ $succ{$n} // [] } ) {
                    next if $from_header{$s} || $s == $h;
                    $from_header{$s} = 1;
                    push @todo, $s;
                }
            }

            my @work = ($u);
            while (@work) {
                my $n = pop @work;
                next if $n == $h || $loop_body{$h}{$n};
                $loop_body{$h}{$n} = 1;
                push @work, grep { $from_header{$_} } @{ $preds{$n} // [] };
            }
        }
        my %innermost;
        for my $bi ( 0 .. $nb - 1 ) {
            my $best;
            for my $h ( keys %loop_body ) {
                next unless $loop_body{$h}{$bi};
                $best = $h if !defined $best || keys %{ $loop_body{$h} } < keys %{ $loop_body{$best} };
            }
            $innermost{$bi} = $best;
        }

        # Emission order. A structured encoding needs every branch that is not a
        # loop back edge to point *forwards* in the emitted code, and each
        # loop's blocks to be one unbroken run. Neither falls out of a plain
        # reverse postorder: that put an `if`'s continuation between the loop
        # header and the loop body, and it laid an `else` arm out *after* the
        # join that arm branches back to, which no stack of labels can express
        # because a label that has closed cannot be branched to again.
        #
        # So order the regions one at a time, and within a region place a block
        # only once every predecessor that is not a back edge has been placed.
        # Waiting for the predecessors is what puts a join after both the arms
        # that reach it, which is the case a depth-first walk gets wrong: it
        # finishes the first arm's whole subgraph, join included, before it
        # starts the second arm. Each region keeps its own ready list, so a
        # block that belongs to an enclosing region is handed back to the
        # caller and lands after this region rather than inside it.
        my %pending;
        $pending{$_} = 0 for 0 .. $nb - 1;
        for my $u ( 0 .. $nb - 1 ) {
            $pending{$_}++ for grep { !$is_back{"$u>$_"} } @{ $succ{$u} // [] };
        }

        my ( @order, %placed, @sink );
        my $place_region;
        $place_region = sub {
            my ( $region, $entry, $outer ) = @_;
            $outer //= \@sink;
            my @ready = ($entry);
            while (@ready) {
                my $bi = shift @ready;
                next if $placed{$bi};
                my $rs = $innermost{$bi} // 'fn';
                if ( $rs ne $region ) {
                    if ( $region eq 'fn' || $loop_body{$region}{$rs} ) {

                        # A loop nested in this one. Hand back to *this*
                        # region's list, not to the caller's: a block the
                        # nested loop leads to but does not own belongs to this
                        # region, and it has to be placed here to keep the
                        # region's blocks in one run.
                        $place_region->( $rs, $bi, \@ready );
                    }
                    else {
                        push @$outer, $bi;
                    }
                    next;
                }
                $placed{$bi} = 1;
                push @order, $bi;
                for my $s ( @{ $succ{$bi} // [] } ) {
                    next if $placed{$s} || $is_back{"$bi>$s"};
                    push @ready, $s unless --$pending{$s};
                }
            }
        };
        $place_region->( 'fn', 0, undef );
        $place_region->( $innermost{$_} // 'fn', $_, undef ) for grep { !$placed{$_} } 0 .. $nb - 1;

        my %order_pos;
        $order_pos{ $order[$_] } = $_ for 0 .. $#order;

        # Check the properties the branch depths rely on, so a layout that broke
        # one is reported here rather than as an unreadable module.
        for my $bi ( 0 .. $nb - 1 ) {
            for my $s ( @{ $succ{$bi} // [] } ) {
                next if $is_back{"$bi>$s"} || $order_pos{$s} > $order_pos{$bi};
                die "Wasm: branch from block $bi to $s runs backwards in the emitted code";
            }
        }
        for my $h ( sort keys %loop_body ) {
            my @pos = sort { $a <=> $b } map { $order_pos{$_} } grep { $loop_body{$h}{$_} } 0 .. $nb - 1;
            next unless @pos > 1;
            die "Wasm: loop at block $h is not laid out contiguously"
                if $pos[-1] - $pos[0] != $#pos;
        }

        # A region is one loop, or the whole function. Its items are the blocks
        # it owns, in emission order. A loop header's own code belongs inside
        # its loop, so the loop instead takes a "loop:N" marker in the region
        # that *encloses* it. Emitted the other way round, a loop would have no
        # event at all and its body would be dropped from the function.
        my %owned;
        for my $bi ( 0 .. $nb - 1 ) {
            push @{ $owned{ $innermost{$bi} // 'fn' } }, $bi;
        }
        my ( %region_items, %item_pos );
        for my $key ( keys %owned ) {
            for my $bi ( @{ $owned{$key} } ) {
                push @{ $region_items{$key} }, $bi;
                $item_pos{$bi} = $order_pos{$bi};
            }
        }
        for my $h ( keys %loop_header ) {

            # The enclosing region is the smallest loop that contains the header
            # other than the header's own loop.
            my $parent;
            for my $L ( keys %loop_body ) {
                next if $L == $h || !$loop_body{$L}{$h};
                $parent = $L if !defined $parent || keys %{ $loop_body{$L} } < keys %{ $loop_body{$parent} };
            }
            $parent //= 'fn';
            push @{ $region_items{$parent} }, "loop:$h";
            $item_pos{"loop:$h"} = $order_pos{$h};
        }
        for my $key ( keys %region_items ) {
            @{ $region_items{$key} } = sort { $item_pos{$a} <=> $item_pos{$b} } @{ $region_items{$key} };
        }

        # Every branch target needs a label, and the label has to close right
        # before that block's own code so the branch lands on it. Opening them
        # in reverse order means the innermost is the one that closes first.
        my %need_label;
        for my $bi ( 0 .. $nb - 1 ) {
            $need_label{$_} = 1 for @{ $succ{$bi} // [] };
        }

        # A loop header is entered two different ways. A back edge wants the
        # loop itself, since branching to a `loop` restarts at its head, while a
        # branch from outside wants a plain `block` that ends just before the
        # loop begins. Only emit that outer block when something outside the loop
        # actually branches here; the back edge alone needs no second label.
        my %outer_label;
        for my $bi ( 0 .. $nb - 1 ) {
            next unless $need_label{$bi};
            $outer_label{$bi} = 1
                if !$loop_header{$bi}
                || grep { !$loop_body{$bi}{$_} } @{ $preds{$bi} // [] };
        }

        my @events;
        my $build_region;
        $build_region = sub {
            my ( $key, $header ) = @_;
            my @items = @{ $region_items{$key} // [] };

            # A region's own header is labelled by the enclosing region, so it
            # contributes no label events here, only its code.
            my $labelled = sub {
                my ($it) = @_;
                my $bi = $it =~ /^loop:(\d+)$/ ? $1 : $it;
                return ( $bi, 0 ) if defined $header && $bi == $header;
                return ( $bi, $outer_label{$bi} ? 1 : 0 );
            };

            for my $it ( reverse @items ) {
                my ( $bi, $lab ) = $labelled->($it);
                push @events, [ 'open', $bi ] if $lab;
            }
            for my $it (@items) {
                my ( $bi, $lab ) = $labelled->($it);
                if ( $it =~ /^loop:/ ) {
                    push @events, [ 'close', $bi ] if $lab;
                    push @events, [ 'open_loop', $bi ];
                    $build_region->( $bi, $bi );
                    push @events, ['close_loop'];
                }
                else {
                    push @events, [ 'close', $bi ] if $lab;
                    push @events, [ 'code',  $bi ];
                }
            }
        };
        $build_region->( 'fn', undef );

        # Walk the events to record, for each block, how deep each of its
        # targets sits. Doing it against the live label stack is what makes the
        # depth right: the old code derived it from a single formula that only
        # held for a branch out of the entry block.
        my ( @stack, %depth_to );
        for my $ev (@events) {
            my $kind = $ev->[0];
            if ( $kind eq 'open' )         { push @stack, [ 'block', $ev->[1] ] }
            elsif ( $kind eq 'close' )      { pop @stack }
            elsif ( $kind eq 'open_loop' )  { push @stack, [ 'loop', $ev->[1] ] }
            elsif ( $kind eq 'close_loop' ) { pop @stack }
            else {
                my $bi  = $ev->[1];
                my @tgt = @{ $succ{$bi} // [] };
                for my $t (@tgt) {
                    my $want = $is_back{"$bi>$t"} ? 'loop' : 'block';
                    my $idx;
                    for my $i ( reverse 0 .. $#stack ) {
                        next unless $stack[$i][1] == $t;
                        $idx = $i, last if $stack[$i][0] eq $want;
                        $idx = $i unless defined $idx;
                    }
                    die "Wasm: no enclosing label for the branch from block $bi to $t" unless defined $idx;
                    $depth_to{"$bi\t$t"} = $#stack - $idx;
                }
            }
        }

        my @block_bytes;
        for my $bi ( 0 .. $nb - 1 ) {
            my $mbb = $blocks[$bi];
            my $buf = \( $block_bytes[$bi] = '' );
            for my $inst ( $mbb->instructions->@* ) {
                next if $bi > 0 && $inst->opcode eq 'label';
                my $opcode = $inst->opcode;
                my @ops    = $inst->operands->@*;
                if ( $opcode eq 'bne' ) {
                    my $t     = $label_to_block_idx{ $ops[0]->value };
                    my $depth = $depth_to{"$bi\t$t"};
                    $$buf .= pack( 'C', 0x0D ) . $self->_uleb($depth);
                }
                elsif ( $opcode eq 'jmp' ) {
                    my $t     = $label_to_block_idx{ $ops[0]->value };
                    my $depth = $depth_to{"$bi\t$t"};
                    $$buf .= pack( 'C', 0x0C ) . $self->_uleb($depth);
                }
                elsif ( $opcode eq 'local_get' ) {
                    if ( $ops[0]->value eq '%__heap_base' ) {
                        $$buf .= pack( 'C', 0x23 ) . $self->_uleb(HEAP_BASE_GLOBAL);
                    }
                    else {
                        my $lid = $vreg_map{ $ops[0]->value } //= $next_local++;
                        $$buf .= pack( 'C', 0x20 ) . $self->_uleb($lid);
                    }
                }
                elsif ( $opcode eq 'i32_const' ) {
                    $$buf .= pack( 'C', 0x41 ) . $self->_sleb( $ops[0]->value );
                }
                elsif ( $opcode eq 'i64_const' ) {
                    $$buf .= pack( 'C', 0x42 ) . $self->_sleb( $ops[0]->value );
                }
                elsif ( $opcode eq 'f32_const' ) {
                    $$buf .= pack( 'C', 0x43 ) . pack( 'f', $ops[0]->value );
                }
                elsif ( $opcode eq 'f64_const' ) {
                    $$buf .= pack( 'C', 0x44 ) . pack( 'd', $ops[0]->value );
                }
                elsif ( $opcode eq 'i32_add' )   { $$buf .= pack( 'C', 0x6A ) }
                elsif ( $opcode eq 'memory_size' ) { $$buf .= pack( 'C', 0x3F ) . pack( 'C', 0x00 ) }
                elsif ( $opcode eq 'memory_grow' ) { $$buf .= pack( 'C', 0x40 ) . pack( 'C', 0x00 ) }
                elsif ( $opcode eq 'i32_sub' )   { $$buf .= pack( 'C', 0x6B ) }
                elsif ( $opcode eq 'i32_mul' )   { $$buf .= pack( 'C', 0x6C ) }
                elsif ( $opcode eq 'i32_div_s' ) { $$buf .= pack( 'C', 0x6D ) }
                elsif ( $opcode eq 'i32_div_u' ) { $$buf .= pack( 'C', 0x6E ) }
                elsif ( $opcode eq 'i32_rem_s' ) { $$buf .= pack( 'C', 0x6F ) }
                elsif ( $opcode eq 'i32_rem_u' ) { $$buf .= pack( 'C', 0x70 ) }
                elsif ( $opcode eq 'i32_and' )   { $$buf .= pack( 'C', 0x71 ) }
                elsif ( $opcode eq 'i32_or' )    { $$buf .= pack( 'C', 0x72 ) }
                elsif ( $opcode eq 'i32_xor' )   { $$buf .= pack( 'C', 0x73 ) }
                elsif ( $opcode eq 'i32_shl' )   { $$buf .= pack( 'C', 0x74 ) }
                elsif ( $opcode eq 'i32_shr_s' ) { $$buf .= pack( 'C', 0x75 ) }
                elsif ( $opcode eq 'i32_shr_u' ) { $$buf .= pack( 'C', 0x76 ) }
                elsif ( $opcode eq 'i64_add' )   { $$buf .= pack( 'C', 0x7C ) }
                elsif ( $opcode eq 'i64_sub' )   { $$buf .= pack( 'C', 0x7D ) }
                elsif ( $opcode eq 'i64_mul' )   { $$buf .= pack( 'C', 0x7E ) }
                elsif ( $opcode eq 'i64_div_s' ) { $$buf .= pack( 'C', 0x7F ) }
                elsif ( $opcode eq 'i64_div_u' ) { $$buf .= pack( 'C', 0x80 ) }
                elsif ( $opcode eq 'i64_rem_s' ) { $$buf .= pack( 'C', 0x81 ) }
                elsif ( $opcode eq 'i64_rem_u' ) { $$buf .= pack( 'C', 0x82 ) }
                elsif ( $opcode eq 'i64_and' )   { $$buf .= pack( 'C', 0x83 ) }
                elsif ( $opcode eq 'i64_or' )    { $$buf .= pack( 'C', 0x84 ) }
                elsif ( $opcode eq 'i64_xor' )   { $$buf .= pack( 'C', 0x85 ) }
                elsif ( $opcode eq 'i64_shl' )   { $$buf .= pack( 'C', 0x86 ) }
                elsif ( $opcode eq 'i64_shr_s' ) { $$buf .= pack( 'C', 0x87 ) }
                elsif ( $opcode eq 'i64_shr_u' ) { $$buf .= pack( 'C', 0x88 ) }
                elsif ( $opcode eq 'i32_wrap_i64' ) { $$buf .= pack( 'C', 0xA7 ) }
                elsif ( $opcode eq 'i32_load' ) {
                    $$buf .= pack( 'C', 0x28 ) . $self->_uleb(2) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_load' ) {
                    $$buf .= pack( 'C', 0x29 ) . $self->_uleb(3) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i32_store' ) {
                    $$buf .= pack( 'C', 0x36 ) . $self->_uleb(2) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_store' ) {
                    $$buf .= pack( 'C', 0x37 ) . $self->_uleb(3) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i32_eqz' )          { $$buf .= pack( 'C', 0x45 ) }
                elsif ( $opcode eq 'i32_eq' )           { $$buf .= pack( 'C', 0x46 ) }
                elsif ( $opcode eq 'i32_ne' )           { $$buf .= pack( 'C', 0x47 ) }
                elsif ( $opcode eq 'i32_lt_s' )         { $$buf .= pack( 'C', 0x48 ) }
                elsif ( $opcode eq 'i32_gt_s' )         { $$buf .= pack( 'C', 0x4A ) }
                elsif ( $opcode eq 'i32_le_s' )         { $$buf .= pack( 'C', 0x4C ) }
                elsif ( $opcode eq 'i32_ge_s' )         { $$buf .= pack( 'C', 0x4E ) }
                elsif ( $opcode eq 'i32_lt_u' )         { $$buf .= pack( 'C', 0x49 ) }
                elsif ( $opcode eq 'i32_gt_u' )         { $$buf .= pack( 'C', 0x4B ) }
                elsif ( $opcode eq 'i32_le_u' )         { $$buf .= pack( 'C', 0x4D ) }
                elsif ( $opcode eq 'i32_ge_u' )         { $$buf .= pack( 'C', 0x4F ) }
                elsif ( $opcode eq 'i64_eqz' )          { $$buf .= pack( 'C', 0x50 ) }
                elsif ( $opcode eq 'i64_eq' )           { $$buf .= pack( 'C', 0x51 ) }
                elsif ( $opcode eq 'i64_ne' )           { $$buf .= pack( 'C', 0x52 ) }
                elsif ( $opcode eq 'i64_lt_s' )         { $$buf .= pack( 'C', 0x53 ) }
                elsif ( $opcode eq 'i64_gt_s' )         { $$buf .= pack( 'C', 0x55 ) }
                elsif ( $opcode eq 'i64_le_s' )         { $$buf .= pack( 'C', 0x57 ) }
                elsif ( $opcode eq 'i64_ge_s' )         { $$buf .= pack( 'C', 0x59 ) }
                elsif ( $opcode eq 'i64_lt_u' )         { $$buf .= pack( 'C', 0x54 ) }
                elsif ( $opcode eq 'i64_extend_i32_s' ) { $$buf .= pack( 'C', 0xAC ) }
                elsif ( $opcode eq 'i64_extend_i32_u' ) { $$buf .= pack( 'C', 0xAD ) }
                elsif ( $opcode eq 'i64_gt_u' )         { $$buf .= pack( 'C', 0x56 ) }
                elsif ( $opcode eq 'i64_le_u' )         { $$buf .= pack( 'C', 0x58 ) }
                elsif ( $opcode eq 'i64_ge_u' )         { $$buf .= pack( 'C', 0x5A ) }
                elsif ( $opcode eq 'f32_load' ) {
                    $$buf .= pack( 'C', 0x2A ) . $self->_uleb(2) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'f64_load' ) {
                    $$buf .= pack( 'C', 0x2B ) . $self->_uleb(3) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'f32_store' ) {
                    $$buf .= pack( 'C', 0x3A ) . $self->_uleb(2) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'f64_store' ) {
                    $$buf .= pack( 'C', 0x3B ) . $self->_uleb(3) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'f32_add' )  { $$buf .= pack( 'C', 0x92 ) }
                elsif ( $opcode eq 'f32_sub' )  { $$buf .= pack( 'C', 0x93 ) }
                elsif ( $opcode eq 'f32_mul' )  { $$buf .= pack( 'C', 0x94 ) }
                elsif ( $opcode eq 'f32_div' )  { $$buf .= pack( 'C', 0x95 ) }
                elsif ( $opcode eq 'f32_min' )  { $$buf .= pack( 'C', 0x96 ) }
                elsif ( $opcode eq 'f32_max' )  { $$buf .= pack( 'C', 0x97 ) }
                elsif ( $opcode eq 'f32_abs' )  { $$buf .= pack( 'C', 0x8B ) }
                elsif ( $opcode eq 'f32_neg' )  { $$buf .= pack( 'C', 0x8C ) }
                elsif ( $opcode eq 'f32_sqrt' ) { $$buf .= pack( 'C', 0x91 ) }
                elsif ( $opcode eq 'f64_add' )  { $$buf .= pack( 'C', 0xA0 ) }
                elsif ( $opcode eq 'f64_sub' )  { $$buf .= pack( 'C', 0xA1 ) }
                elsif ( $opcode eq 'f64_mul' )  { $$buf .= pack( 'C', 0xA2 ) }
                elsif ( $opcode eq 'f64_div' )  { $$buf .= pack( 'C', 0xA3 ) }
                elsif ( $opcode eq 'f64_min' )  { $$buf .= pack( 'C', 0xA4 ) }
                elsif ( $opcode eq 'f64_max' )  { $$buf .= pack( 'C', 0xA5 ) }
                elsif ( $opcode eq 'f64_abs' )  { $$buf .= pack( 'C', 0x99 ) }
                elsif ( $opcode eq 'f64_neg' )  { $$buf .= pack( 'C', 0x9A ) }
                elsif ( $opcode eq 'f64_sqrt' ) { $$buf .= pack( 'C', 0x9F ) }
                elsif ( $opcode eq 'f32_eq' )   { $$buf .= pack( 'C', 0x5B ) }
                elsif ( $opcode eq 'f32_ne' )   { $$buf .= pack( 'C', 0x5C ) }
                elsif ( $opcode eq 'f32_lt' )   { $$buf .= pack( 'C', 0x5D ) }
                elsif ( $opcode eq 'f32_gt' )   { $$buf .= pack( 'C', 0x5E ) }
                elsif ( $opcode eq 'f32_le' )   { $$buf .= pack( 'C', 0x5F ) }
                elsif ( $opcode eq 'f32_ge' )   { $$buf .= pack( 'C', 0x60 ) }
                elsif ( $opcode eq 'f64_eq' )   { $$buf .= pack( 'C', 0x61 ) }
                elsif ( $opcode eq 'f64_ne' )   { $$buf .= pack( 'C', 0x62 ) }
                elsif ( $opcode eq 'f64_lt' )   { $$buf .= pack( 'C', 0x63 ) }
                elsif ( $opcode eq 'f64_gt' )   { $$buf .= pack( 'C', 0x64 ) }
                elsif ( $opcode eq 'f64_le' )   { $$buf .= pack( 'C', 0x65 ) }
                elsif ( $opcode eq 'f64_ge' )   { $$buf .= pack( 'C', 0x66 ) }
                elsif ( $opcode eq 'select' ) {

                    # Plain 0x1B, with no type immediate. The MVP select is
                    # untyped and infers its operands from the stack, which
                    # covers i32/i64/f32/f64 alike. The typed form is a
                    # different opcode (0x1C) and takes a *vector* of value
                    # types, so appending a bare valtype here makes the
                    # validator read that byte as a vector length and reject
                    # the module.
                    $$buf .= pack( 'C', 0x1B );
                }
                elsif ( $opcode eq 'ret' ) {
                    $$buf .= pack( 'C', 0x0F );
                }
                elsif ( $opcode eq 'local_set' ) {
                    my $lid = $vreg_map{ $ops[0]->value } //= $next_local++;
                    $$buf .= pack( 'C', 0x21 ) . $self->_uleb($lid);
                }
                elsif ( $opcode eq 'call_func' ) {
                    my $func_name = $ops[0]->value;
                    my $fixup_pos = length($$buf);
                    $$buf .= pack( 'C', 0x10 ) . "\x80\x80\x80\x80\x00";    # call + placeholder LEB128
                    push @{ $block_fixups[$bi] }, { type => 'call_idx', target => $func_name, offset => $fixup_pos + 1 };
                }
                elsif ( $opcode eq 'call_indirect' ) {
                    $$buf .= pack( 'C', 0x00 );                             # unreachable (stub)
                }
                elsif ( $opcode eq 'ctx_swap' ) {

                    # Wasm has no native register context; no-op
                }
                elsif ( $opcode eq 'lea_func' ) {
                    my $func_name = $ops[1]->value;
                    my $fixup_pos = length($$buf);
                    $$buf .= pack( 'C', 0x10 ) . "\x80\x80\x80\x80\x00";    # call + placeholder LEB128
                    push @{ $block_fixups[$bi] }, { type => 'call_idx', target => $func_name, offset => $fixup_pos + 1 };
                }
                else {

                    # Never fall through an unhandled opcode. An earlier version
                    # of this chain had no else, so every opcode the encoder did
                    # not know was silently dropped: i32 division returned its
                    # right-hand operand, and integer min/max did the same,
                    # because Wasm has no i32.min/i64.min at all and the
                    # lowerer emitted one anyway. The result was a wrong answer
                    # with no diagnostic, which is how those bugs stayed
                    # invisible while the Wasm tests skipped for want of a
                    # runtime. Opcodes that are deliberately no-ops (ctx_swap)
                    # get an explicit branch above rather than falling through.
                    die "Brocken::Jenny::Codegen::Wasm: no encoder for MIR opcode '$opcode'"
                        . ( defined $ops[0] ? ' (first operand: ' . $ops[0]->value . ')' : '' );
                }
            }
        }

        # A block that did not end in a branch falls into its MIR successor,
        # which the reordering above may have moved, so say so explicitly.
        for my $bi ( 0 .. $nb - 1 ) {
            next unless defined $fallthru{$bi};
            $block_bytes[$bi] .= pack( 'C', 0x0C ) . $self->_uleb( $depth_to{"$bi\t$fallthru{$bi}"} );
        }

        # Assemble the event list. A `block` label closes immediately before the
        # code of the block it names, which is what makes `br` to it land there;
        # a `loop` label is what a back edge targets, because branching to a
        # `loop` restarts at its head while branching to a `block` resumes
        # after its end.
        my @func_fixups;
        for my $ev (@events) {
            my $kind = $ev->[0];
            if ( $kind eq 'open' )   { $bytes .= pack( 'C', 0x02 ) . pack( 'C', 0x40 ) }    # block void
            elsif ( $kind eq 'close' )    { $bytes .= pack( 'C', 0x0B ) }                      # end
            elsif ( $kind eq 'open_loop' )  { $bytes .= pack( 'C', 0x03 ) . pack( 'C', 0x40 ) }# loop void
            elsif ( $kind eq 'close_loop' ) { $bytes .= pack( 'C', 0x0B ) }                      # end
            else {
                my $bi = $ev->[1];

                # The encoder measured each placeholder against its own block,
                # but the linker rewrites the finished function body, where the
                # same call sits after however many `block`/`loop` opcodes the
                # region layout put in front of it. Rebase here or the linker
                # overwrites the wrong five bytes: for an `if`, whose entry
                # block is preceded by one `block` per target, it landed on the
                # `call` opcode itself and left the function calling itself.
                for my $fx ( @{ $block_fixups[$bi] // [] } ) {
                    push @func_fixups, { %$fx, offset => $fx->{offset} + length($bytes) };
                }
                $bytes .= $block_bytes[$bi];
            }
        }

        my $num_params       = scalar( $ir_params->@* );
        my $num_extra_locals = $next_local - $num_params;
        my $locals_block     = '';
        if ( $num_extra_locals > 0 ) {

            # Build reverse mapping: local_id => vreg name
            my %lid_to_name = reverse %vreg_map;

            # Scan locals sequentially and group consecutive same-type
            my @groups;
            my $prev_wt;
            for my $lid ( $num_params .. $next_local - 1 ) {
                my $name  = $lid_to_name{$lid} // '';
                my $itype = $name  ? $ir_types->{$name}           : undef;
                my $wt    = $itype ? $self->_wasm_valtype($itype) : 0x7F;
                if ( !defined $prev_wt || $wt ne $prev_wt ) {
                    push @groups, [ $wt, 0 ];
                    $prev_wt = $wt;
                }
                $groups[-1][1]++;
            }
            my $num_groups = scalar @groups;
            $locals_block = $self->_uleb($num_groups);
            for my $g (@groups) {
                $locals_block .= $self->_uleb( $g->[1] ) . pack( 'C', $g->[0] );
            }
        }
        else {
            $locals_block = $self->_uleb(0);
        }
        my $ret_valtype;
        if ( $return_type && $return_type->kind eq 'int' && $return_type->bits == 128 ) {
            $ret_valtype = [ 0x7E, 0x7E ];
        }
        elsif ( !$return_type || $return_type->kind eq 'void' ) {

            # A void function gets an empty Wasm result vector. The frontend
            # gives an unannotated function a real type object whose kind is
            # 'void', so testing only for a missing return type was not enough
            # and fell through to the i32 default: Brocken::Runtime::_init then
            # declared itself as returning i32 while its body ends in a bare
            # `return` with an empty stack, and the validator rejected the module
            # with "expected i32 but nothing on stack".
            $ret_valtype = 'void';
        }
        else {
            $ret_valtype = $self->_wasm_valtype($return_type);
        }
        return ( { body => $bytes . pack( 'C', 0x0B ), locals => $locals_block, num_locals => $next_local, return_valtype => $ret_valtype },
            \@func_fixups );
    }

    method _wasm_valtype($ir_type) {
        return 0x7F if $ir_type->kind eq 'int'   && $ir_type->bits <= 32;    # i32
        return 0x7E if $ir_type->kind eq 'int'   && $ir_type->bits == 64;    # i64
        return 0x7D if $ir_type->kind eq 'float' && $ir_type->bits <= 32;    # f32
        return 0x7C if $ir_type->kind eq 'float' && $ir_type->bits >= 64;    # f64
        return 0x7F;                                                         # default i32
    }

    method _uleb ($v) {
        my $out = '';
        do {
            my $byte = $v & 0x7F;
            $v >>= 7;
            $byte |= 0x80 if $v;
            $out .= pack( 'C', $byte );
        } while ($v);
        return $out;
    }

    # Signed LEB128. The shift has to stay in integer arithmetic: dividing by
    # 128 with POSIX::floor goes through a double, which carries 53 bits of
    # mantissa, so any value past 2**53 was rounded before the next group was
    # taken. INT64_MAX came out as ff 80 80 80 80 80 80 80 80 01, which the
    # validator rejects outright as an over-long var_i64.
    #
    # Perl's >> shifts the unsigned representation, so a negative value needs
    # the -((-v + 127) >> 7) form to still round toward negative infinity.
    method _sleb ($v) {
        $v -= 18446744073709551616 if $v >= 9223372036854775808;
        my $out = '';
        while (1) {
            my $byte = $v & 0x7f;
            $v = $v >= 0 ? $v >> 7 : -( ( -$v + 127 ) >> 7 );
            if ( ( $v == 0 && !( $byte & 0x40 ) ) || ( $v == -1 && ( $byte & 0x40 ) ) ) {
                $out .= pack( 'C', $byte );
                last;
            }
            $out .= pack( 'C', $byte | 0x80 );
        }
        return $out;
    }
}

=encoding utf-8

=head1 NAME

Brocken::Jenny::Codegen::Wasm - WebAssembly Binary Code Generator

=head1 DESCRIPTION

Generates WebAssembly binary code from MIR. Produces standard WASM bytecode suitable for embedding in a .wasm module.

=head2 WebAssembly Features

=over 4

=item B<Locals>: Declares MIR virtual registers as WASM local variables

=item B<Constants>: i32.const, i64.const for immediate values

=item B<Arithmetic>: i32.add/sub/mul/div_s/rem_s, i64 variants, i32.and/or/xor/shl/shr_s/shr_u

=item B<Comparison>: i32.eq/ne/lt_s/le_s/gt_s/ge_s, i64 variants

=item B<Memory>: i32.load/store (with 4-byte alignment), i64.load/store (with 8-byte alignment)

=item B<Control flow>: block, end, br (by depth), br_if, br_table, return

=item B<Calls>: call (by function index)

=item B<Local access>: local.get, local.set (by index)

=back

=head2 Structured Control Flow

WebAssembly requires structured control flow (no arbitrary jumps). The codegen uses nested B<block> and B<end> pairs
with L<br> targeting by block depth to implement conditional branches and loops.

=head2 Limitations

=over 4

=item * No floating-point support yet (WASM supports f32/f64 natively)

=item * No alloca support (WASM has linear memory but no dynamic stack allocation)

=item * Limited to a single function and linear memory

=back

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
