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
            my %source_map;
            my ( $result, $fixups ) = $self->_encode( $mf, $ir_func->params, \%ir_types, $ir_func->return_type, \%source_map );
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
                source_map     => \%source_map,
                return_valtype => $result->{return_valtype},
                param_valtypes => \@param_valtypes,
                };
        }
        return \@funcs;
    }

    method _encode( $mf, $ir_params, $ir_types, $return_type, $source_map = undef ) {
        my $bytes       = '';
        my %vreg_map    = ();
        my $next_local  = scalar( $ir_params->@* );
        my @func_fixups = ();

        # Map parameters to locals 0..N-1
        for my $i ( 0 .. ( $next_local - 1 ) ) {
            $vreg_map{ $ir_params->[$i]->name } = $i;
        }

        # Reserve a local for the linear-memory heap bump pointer
        $vreg_map{'%heap_ptr'} = $next_local++;
        my @blocks = $mf->blocks->@*;
        my %label_to_block_idx;
        for my $bi ( 0 .. $#blocks ) {
            for my $inst ( $blocks[$bi]->instructions->@* ) {
                $label_to_block_idx{ $inst->operands->[0]->value } = $bi if $inst->opcode eq 'label';
            }
        }
        my $num_non_entry = $#blocks;
        my $entry_bytes   = '';
        my @non_entry_bytes;
        my %raw_offsets;
        for my $bi ( 0 .. $#blocks ) {
            my $mbb = $blocks[$bi];
            my $buf = $bi == 0 ? \$entry_bytes : \( $non_entry_bytes[ $bi - 1 ] = '' );
            for my $inst ( $mbb->instructions->@* ) {
                if ( $source_map && $inst->ir_inst_idx >= 0 && !exists $raw_offsets{ $inst->ir_inst_idx } ) {
                    $raw_offsets{ $inst->ir_inst_idx } = [ $bi, length($$buf) ];
                }
                next if $bi > 0 && $inst->opcode eq 'label';
                my $opcode = $inst->opcode;
                my @ops    = $inst->operands->@*;
                if ( $opcode eq 'bne' ) {
                    my $depth = $num_non_entry - $label_to_block_idx{ $ops[0]->value };
                    $$buf .= pack( 'C', 0x0D ) . $self->_uleb($depth);
                }
                elsif ( $opcode eq 'jmp' ) {
                    my $depth = $num_non_entry - $label_to_block_idx{ $ops[0]->value };
                    $$buf .= pack( 'C', 0x0C ) . $self->_uleb($depth);
                }
                elsif ( $opcode eq 'local_get' ) {
                    my $lid = $vreg_map{ $ops[0]->value } //= $next_local++;
                    $$buf .= pack( 'C', 0x20 ) . $self->_uleb($lid);
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
                elsif ( $opcode eq 'i32_sub' )   { $$buf .= pack( 'C', 0x6B ) }
                elsif ( $opcode eq 'i32_mul' )   { $$buf .= pack( 'C', 0x6C ) }
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
                elsif ( $opcode eq 'i64_div_u' ) { $$buf .= pack( 'C', 0x80 ) }
                elsif ( $opcode eq 'i64_rem_s' ) { $$buf .= pack( 'C', 0x81 ) }
                elsif ( $opcode eq 'i64_rem_u' ) { $$buf .= pack( 'C', 0x82 ) }
                elsif ( $opcode eq 'i64_and' )   { $$buf .= pack( 'C', 0x83 ) }
                elsif ( $opcode eq 'i64_or' )    { $$buf .= pack( 'C', 0x84 ) }
                elsif ( $opcode eq 'i64_xor' )   { $$buf .= pack( 'C', 0x85 ) }
                elsif ( $opcode eq 'i64_shl' )   { $$buf .= pack( 'C', 0x86 ) }
                elsif ( $opcode eq 'i64_shr_s' ) { $$buf .= pack( 'C', 0x87 ) }
                elsif ( $opcode eq 'i64_shr_u' ) { $$buf .= pack( 'C', 0x88 ) }
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
                elsif ( $opcode eq 'i64_extend_i32_u' ) { $$buf .= pack( 'C', 0xAC ) }
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
                    push @func_fixups, { type => 'call_idx', target => $func_name, offset => $fixup_pos + 1 };
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
                    push @func_fixups, { type => 'call_idx', target => $func_name, offset => $fixup_pos + 1 };
                }
            }
        }

        # Open nested blocks (outermost first).  br N targets N levels out;
        # after the matching `end`, control continues.  So each block's
        # body must come *after* that block's `end`, not before it.
        for my $bi ( 1 .. $num_non_entry ) {
            $bytes .= pack( 'C', 0x02 ) . pack( 'C', 0x40 );
        }
        $bytes .= $entry_bytes;

        # Close innermost first, emitting each block's code *after* its end
        for my $bi ( reverse 1 .. $num_non_entry ) {
            $bytes .= pack( 'C', 0x0B );
            $bytes .= $non_entry_bytes[ $bi - 1 ];
        }
        if ($source_map) {
            my @block_sizes;
            my @block_start;
            $block_sizes[0] = length($entry_bytes);
            for my $bi ( 1 .. $num_non_entry ) {
                $block_sizes[$bi] = length( $non_entry_bytes[ $bi - 1 ] );
            }
            my $pos = $num_non_entry * 2;
            $block_start[0] = $pos;
            $pos += $block_sizes[0];
            for my $bi ( reverse 1 .. $num_non_entry ) {
                $block_start[$bi] = $pos + 1;
                $pos += 1 + $block_sizes[$bi];
            }
            for my $idx ( keys %raw_offsets ) {
                my ( $bi, $buf_off ) = $raw_offsets{$idx}->@*;
                $source_map->{$idx} = $block_start[$bi] + $buf_off;
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
        else {
            $ret_valtype = $return_type ? $self->_wasm_valtype($return_type) : 0x7F;
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

    method _sleb ($v) {
        require POSIX;
        $v = -( ~( $v & 0xFFFFFFFFFFFFFFFF ) + 1 ) if $v >= 0x8000000000000000;
        my $out = '';
        while (1) {
            my $byte = $v & 0x7f;
            $v = POSIX::floor( $v / 128 );
            if ( ( $v == 0 && !( $byte & 0x40 ) ) || ( $v == -1 && ( $byte & 0x40 ) ) ) {
                $out .= pack( 'C', $byte );
                last;
            }
            $out .= pack( 'C', $byte | 0x80 );
        }
        return $out;
    }

    method build_debug_data( $ir_funcs, $func_blobs, $source_file = 'source.brocken', $text_base = 0, $class_info = {}, $debug_level = 0 ) {
        require Brocken::Jenny::Linker::DWARF;
        my @func_ranges;
        my @source_locs;
        my $text_offset = 0;
        for my $i ( 0 .. $#$ir_funcs ) {
            my $ir_fn  = $ir_funcs->[$i];
            my $blob   = $func_blobs->[$i];
            my $fname  = $blob->{name};
            my $fstart = $text_offset;
            my $fend   = $text_offset + length( $blob->{bytes} );
            push @func_ranges, { name => $fname, start => $fstart, end => $fend, params => [], locals => [], source_file => $source_file };
            my $source_map = $blob->{source_map} // {};
            my $inst_idx   = 0;

            for my $block ( $ir_fn->blocks->@* ) {
                for my $inst ( $block->instructions->@* ) {
                    if ( $inst->line ) {
                        my $offset = defined( $source_map->{$inst_idx} ) ? $fstart + $source_map->{$inst_idx} : $fstart;
                        push @source_locs, { offset => $offset, line => $inst->line, col => $inst->col };
                    }
                    $inst_idx++;
                }
            }
            $text_offset = $fend;
        }
        my %seen;
        my @uniq_files = grep { !$seen{$_}++ } map { $_->{source_file} // $source_file } @func_ranges;
        my $dwarf      = Brocken::Jenny::Linker::DWARF->new(
            source_locs  => \@source_locs,
            text_base    => $text_base,
            source_file  => $source_file,
            source_files => \@uniq_files,
            func_ranges  => \@func_ranges,
            class_info   => $class_info,
            arch         => 'wasm64',
            platform     => $platform,
            debug        => $debug_level,
        );
        return $dwarf->build_all;
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
