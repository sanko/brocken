use v5.42;
use feature qw[class];
no warnings qw[portable];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Lowerer::Wasm;
use Brocken::Jenny::RegAlloc;
use Brocken::Jenny::MIR;

class Brocken::Jenny::Codegen::Wasm {
    use Brocken::Jenny::Codegen::Wasm::Encodings qw[:all];
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
        $mf->release;
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
            $mf->release;
            my @param_valtypes;
            for my $p ( $ir_func->params->@* ) {
                push @param_valtypes, $self->_wasm_valtype( $p->type );
            }
            my $locals_size = length( $result->{locals} );
            for my $idx ( keys %source_map ) {
                $source_map{$idx} += $locals_size;
            }
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
                    $$buf .= pack( 'C', BR_IF ) . $self->_uleb($depth);
                }
                elsif ( $opcode eq 'jmp' ) {
                    my $depth = $num_non_entry - $label_to_block_idx{ $ops[0]->value };
                    $$buf .= pack( 'C', BR ) . $self->_uleb($depth);
                }
                elsif ( $opcode eq 'local_get' ) {
                    my $lid = $vreg_map{ $ops[0]->value } //= $next_local++;
                    $$buf .= pack( 'C', LOCAL_GET ) . $self->_uleb($lid);
                }
                elsif ( $opcode eq 'i32_const' ) {
                    $$buf .= pack( 'C', I32_CONST ) . $self->_sleb( $ops[0]->value );
                }
                elsif ( $opcode eq 'i64_const' ) {
                    $$buf .= pack( 'C', I64_CONST ) . $self->_sleb( $ops[0]->value );
                }
                elsif ( $opcode eq 'f32_const' ) {
                    $$buf .= pack( 'C', F32_CONST ) . pack( 'f', $ops[0]->value );
                }
                elsif ( $opcode eq 'f64_const' ) {
                    $$buf .= pack( 'C', F64_CONST ) . pack( 'd', $ops[0]->value );
                }
                elsif ( $opcode eq 'i32_add' )   { $$buf .= pack( 'C', I32_ADD ) }
                elsif ( $opcode eq 'i32_sub' )   { $$buf .= pack( 'C', I32_SUB ) }
                elsif ( $opcode eq 'i32_mul' )   { $$buf .= pack( 'C', I32_MUL ) }
                elsif ( $opcode eq 'i32_rem_s' ) { $$buf .= pack( 'C', I32_REM_S ) }
                elsif ( $opcode eq 'i32_rem_u' ) { $$buf .= pack( 'C', I32_REM_U ) }
                elsif ( $opcode eq 'i32_and' )   { $$buf .= pack( 'C', I32_AND ) }
                elsif ( $opcode eq 'i32_or' )    { $$buf .= pack( 'C', I32_OR ) }
                elsif ( $opcode eq 'i32_xor' )   { $$buf .= pack( 'C', I32_XOR ) }
                elsif ( $opcode eq 'i32_shl' )   { $$buf .= pack( 'C', I32_SHL ) }
                elsif ( $opcode eq 'i32_shr_s' ) { $$buf .= pack( 'C', I32_SHR_S ) }
                elsif ( $opcode eq 'i32_shr_u' ) { $$buf .= pack( 'C', I32_SHR_U ) }
                elsif ( $opcode eq 'i64_add' )   { $$buf .= pack( 'C', I64_ADD ) }
                elsif ( $opcode eq 'i64_sub' )   { $$buf .= pack( 'C', I64_SUB ) }
                elsif ( $opcode eq 'i64_mul' )   { $$buf .= pack( 'C', I64_MUL ) }
                elsif ( $opcode eq 'i64_div_u' ) { $$buf .= pack( 'C', I64_DIV_U ) }
                elsif ( $opcode eq 'i64_rem_s' ) { $$buf .= pack( 'C', I64_REM_S ) }
                elsif ( $opcode eq 'i64_rem_u' ) { $$buf .= pack( 'C', I64_REM_U ) }
                elsif ( $opcode eq 'i64_and' )   { $$buf .= pack( 'C', I64_AND ) }
                elsif ( $opcode eq 'i64_or' )    { $$buf .= pack( 'C', I64_OR ) }
                elsif ( $opcode eq 'i64_xor' )   { $$buf .= pack( 'C', I64_XOR ) }
                elsif ( $opcode eq 'i64_shl' )   { $$buf .= pack( 'C', I64_SHL ) }
                elsif ( $opcode eq 'i64_shr_s' ) { $$buf .= pack( 'C', I64_SHR_S ) }
                elsif ( $opcode eq 'i64_shr_u' ) { $$buf .= pack( 'C', I64_SHR_U ) }
                elsif ( $opcode eq 'i32_load' ) {
                    $$buf .= pack( 'C', I32_LOAD ) . $self->_uleb(2) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_load' ) {
                    $$buf .= pack( 'C', I64_LOAD ) . $self->_uleb(3) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i32_load8_u' ) {
                    $$buf .= pack( 'C', I32_LOAD8_U ) . $self->_uleb(0) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i32_load16_u' ) {
                    $$buf .= pack( 'C', I32_LOAD16_U ) . $self->_uleb(1) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_load8_u' ) {
                    $$buf .= pack( 'C', I64_LOAD8_U ) . $self->_uleb(0) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_load16_u' ) {
                    $$buf .= pack( 'C', I64_LOAD16_U ) . $self->_uleb(1) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_load32_u' ) {
                    $$buf .= pack( 'C', I64_LOAD32_U ) . $self->_uleb(2) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i32_store' ) {
                    $$buf .= pack( 'C', I32_STORE ) . $self->_uleb(2) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_store' ) {
                    $$buf .= pack( 'C', I64_STORE ) . $self->_uleb(3) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i32_store8' ) {
                    $$buf .= pack( 'C', I32_STORE8 ) . $self->_uleb(0) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i32_store16' ) {
                    $$buf .= pack( 'C', I32_STORE16 ) . $self->_uleb(1) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_store8' ) {
                    $$buf .= pack( 'C', I64_STORE8 ) . $self->_uleb(0) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_store16' ) {
                    $$buf .= pack( 'C', I64_STORE16 ) . $self->_uleb(1) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_store32' ) {
                    $$buf .= pack( 'C', I64_STORE32 ) . $self->_uleb(2) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i32_eqz' )          { $$buf .= pack( 'C', I32_EQZ ) }
                elsif ( $opcode eq 'i32_eq' )           { $$buf .= pack( 'C', I32_EQ ) }
                elsif ( $opcode eq 'i32_ne' )           { $$buf .= pack( 'C', I32_NE ) }
                elsif ( $opcode eq 'i32_lt_s' )         { $$buf .= pack( 'C', I32_LT_S ) }
                elsif ( $opcode eq 'i32_gt_s' )         { $$buf .= pack( 'C', I32_GT_S ) }
                elsif ( $opcode eq 'i32_le_s' )         { $$buf .= pack( 'C', I32_LE_S ) }
                elsif ( $opcode eq 'i32_ge_s' )         { $$buf .= pack( 'C', I32_GE_S ) }
                elsif ( $opcode eq 'i32_lt_u' )         { $$buf .= pack( 'C', I32_LT_U ) }
                elsif ( $opcode eq 'i32_gt_u' )         { $$buf .= pack( 'C', I32_GT_U ) }
                elsif ( $opcode eq 'i32_le_u' )         { $$buf .= pack( 'C', I32_LE_U ) }
                elsif ( $opcode eq 'i32_ge_u' )         { $$buf .= pack( 'C', I32_GE_U ) }
                elsif ( $opcode eq 'i64_eqz' )          { $$buf .= pack( 'C', I64_EQZ ) }
                elsif ( $opcode eq 'i64_eq' )           { $$buf .= pack( 'C', I64_EQ ) }
                elsif ( $opcode eq 'i64_ne' )           { $$buf .= pack( 'C', I64_NE ) }
                elsif ( $opcode eq 'i64_lt_s' )         { $$buf .= pack( 'C', I64_LT_S ) }
                elsif ( $opcode eq 'i64_gt_s' )         { $$buf .= pack( 'C', I64_GT_S ) }
                elsif ( $opcode eq 'i64_le_s' )         { $$buf .= pack( 'C', I64_LE_S ) }
                elsif ( $opcode eq 'i64_ge_s' )         { $$buf .= pack( 'C', I64_GE_S ) }
                elsif ( $opcode eq 'i64_lt_u' )         { $$buf .= pack( 'C', I64_LT_U ) }
                elsif ( $opcode eq 'i32_wrap_i64' )     { $$buf .= pack( 'C', I32_WRAP_I64 ) }
                elsif ( $opcode eq 'i64_extend_i32_s' ) { $$buf .= pack( 'C', I64_EXTEND_I32_S ) }
                elsif ( $opcode eq 'i64_extend_i32_u' ) { $$buf .= pack( 'C', I64_EXTEND_I32_U ) }
                elsif ( $opcode eq 'i64_gt_u' )         { $$buf .= pack( 'C', I64_GT_U ) }
                elsif ( $opcode eq 'i64_le_u' )         { $$buf .= pack( 'C', I64_LE_U ) }
                elsif ( $opcode eq 'i64_ge_u' )         { $$buf .= pack( 'C', I64_GE_U ) }
                elsif ( $opcode eq 'f32_load' ) {
                    $$buf .= pack( 'C', F32_LOAD ) . $self->_uleb(2) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'f64_load' ) {
                    $$buf .= pack( 'C', F64_LOAD ) . $self->_uleb(3) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'f32_store' ) {
                    $$buf .= pack( 'C', F32_STORE ) . $self->_uleb(2) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'f64_store' ) {
                    $$buf .= pack( 'C', F64_STORE ) . $self->_uleb(3) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'f32_add' )           { $$buf .= pack( 'C', F32_ADD ) }
                elsif ( $opcode eq 'f32_sub' )           { $$buf .= pack( 'C', F32_SUB ) }
                elsif ( $opcode eq 'f32_mul' )           { $$buf .= pack( 'C', F32_MUL ) }
                elsif ( $opcode eq 'f32_div' )           { $$buf .= pack( 'C', F32_DIV ) }
                elsif ( $opcode eq 'f32_min' )           { $$buf .= pack( 'C', F32_MIN ) }
                elsif ( $opcode eq 'f32_max' )           { $$buf .= pack( 'C', F32_MAX ) }
                elsif ( $opcode eq 'f32_abs' )           { $$buf .= pack( 'C', F32_ABS ) }
                elsif ( $opcode eq 'f32_neg' )           { $$buf .= pack( 'C', F32_NEG ) }
                elsif ( $opcode eq 'f32_sqrt' )          { $$buf .= pack( 'C', F32_SQRT ) }
                elsif ( $opcode eq 'f64_add' )           { $$buf .= pack( 'C', F64_ADD ) }
                elsif ( $opcode eq 'f64_sub' )           { $$buf .= pack( 'C', F64_SUB ) }
                elsif ( $opcode eq 'f64_mul' )           { $$buf .= pack( 'C', F64_MUL ) }
                elsif ( $opcode eq 'f64_div' )           { $$buf .= pack( 'C', F64_DIV ) }
                elsif ( $opcode eq 'f64_min' )           { $$buf .= pack( 'C', F64_MIN ) }
                elsif ( $opcode eq 'f64_max' )           { $$buf .= pack( 'C', F64_MAX ) }
                elsif ( $opcode eq 'f64_abs' )           { $$buf .= pack( 'C', F64_ABS ) }
                elsif ( $opcode eq 'f64_neg' )           { $$buf .= pack( 'C', F64_NEG ) }
                elsif ( $opcode eq 'f64_sqrt' )          { $$buf .= pack( 'C', F64_SQRT ) }
                elsif ( $opcode eq 'f64_convert_i64_s' ) { $$buf .= pack( 'C', F64_CONVERT_I64_S ) }
                elsif ( $opcode eq 'i64_trunc_f64_s' )   { $$buf .= pack( 'C', I64_TRUNC_F64_S ) }
                elsif ( $opcode eq 'f32_eq' )            { $$buf .= pack( 'C', F32_EQ ) }
                elsif ( $opcode eq 'f32_ne' )            { $$buf .= pack( 'C', F32_NE ) }
                elsif ( $opcode eq 'f32_lt' )            { $$buf .= pack( 'C', F32_LT ) }
                elsif ( $opcode eq 'f32_gt' )            { $$buf .= pack( 'C', F32_GT ) }
                elsif ( $opcode eq 'f32_le' )            { $$buf .= pack( 'C', F32_LE ) }
                elsif ( $opcode eq 'f32_ge' )            { $$buf .= pack( 'C', F32_GE ) }
                elsif ( $opcode eq 'f64_eq' )            { $$buf .= pack( 'C', F64_EQ ) }
                elsif ( $opcode eq 'f64_ne' )            { $$buf .= pack( 'C', F64_NE ) }
                elsif ( $opcode eq 'f64_lt' )            { $$buf .= pack( 'C', F64_LT ) }
                elsif ( $opcode eq 'f64_gt' )            { $$buf .= pack( 'C', F64_GT ) }
                elsif ( $opcode eq 'f64_le' )            { $$buf .= pack( 'C', F64_LE ) }
                elsif ( $opcode eq 'f64_ge' )            { $$buf .= pack( 'C', F64_GE ) }
                elsif ( $opcode eq 'ret' ) {
                    $$buf .= pack( 'C', RETURN );
                }
                elsif ( $opcode eq 'local_set' ) {
                    my $lid = $vreg_map{ $ops[0]->value } //= $next_local++;
                    $$buf .= pack( 'C', LOCAL_SET ) . $self->_uleb($lid);
                }
                elsif ( $opcode eq 'select' ) {
                    $$buf .= pack( 'C', SELECT_T ) . pack( 'C', 1 ) . pack( 'C', $ops[0]->value );
                }
                elsif ( $opcode eq 'call_func' ) {
                    my $func_name = $ops[0]->value;
                    my $fixup_pos = length($$buf);
                    $$buf .= pack( 'C', CALL ) . "\x80\x80\x80\x80\x00";    # call + placeholder LEB128
                    push @func_fixups, { type => 'call_idx', target => $func_name, block => $bi, offset => $fixup_pos + 1 };
                }
                elsif ( $opcode eq 'call_indirect' ) {
                    $$buf .= pack( 'C', UNREACHABLE );                      # unreachable (stub)
                }
                elsif ( $opcode eq 'ctx_swap' ) {

                    # Wasm has no native register context; no-op
                }
                elsif ( $opcode eq 'lea_func' ) {
                    my $func_name = $ops[1]->value;
                    my $fixup_pos = length($$buf);
                    $$buf .= pack( 'C', CALL ) . "\x80\x80\x80\x80\x00";    # call + placeholder LEB128
                    push @func_fixups, { type => 'call_idx', target => $func_name, block => $bi, offset => $fixup_pos + 1 };
                }
                else {
                    # Silently emitting nothing here is how the encoder produces a
                    # module that links but does not validate, so an opcode with no
                    # encoding is a bug in the lowerer and has to be loud.
                    die "Wasm code generator has no encoding for '$opcode'";
                }
            }
        }

        # Assemble final function body and track block positions for source_map in one pass.
        # Block layout: outermost-first openers, entry body, then innermost-first closers.
        my @block_start;
        my $pos = 0;
        for my $bi ( 1 .. $num_non_entry ) {
            $bytes .= pack( 'C', BLOCK ) . pack( 'C', 0x40 );
            $pos += 2;
        }
        $block_start[0] = $pos;
        $bytes .= $entry_bytes;
        $pos += length($entry_bytes);
        for my $bi ( reverse 1 .. $num_non_entry ) {
            $bytes .= pack( 'C', END_BLOCK );
            $pos += 1;
            $block_start[$bi] = $pos;
            $bytes .= $non_entry_bytes[ $bi - 1 ];
            $pos += length( $non_entry_bytes[ $bi - 1 ] );
        }
        if ($source_map) {
            for my $idx ( keys %raw_offsets ) {
                my ( $bi, $buf_off ) = $raw_offsets{$idx}->@*;
                $source_map->{$idx} = $block_start[$bi] + $buf_off;
            }
        }

        # Call placeholders were recorded against per-block buffers, so rebase
        # them onto the assembled body the linker will patch.
        for my $fx (@func_fixups) {
            $fx->{offset} = $block_start[ $fx->{block} ] + $fx->{offset};
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
                my $wt    = $itype ? $self->_wasm_valtype($itype) : VALTYPE_I32;
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
            $ret_valtype = [ VALTYPE_I64, VALTYPE_I64 ];
        }
        elsif ( $return_type && $return_type->kind eq 'void' ) {

            # A void function takes no results, which is not the same as taking an
            # i32: the linker writes a result count, so this has to say so.
            $ret_valtype = 'void';
        }
        else {
            $ret_valtype = $return_type ? $self->_wasm_valtype($return_type) : VALTYPE_I32;
        }
        return ( { body => $bytes . pack( 'C', END_BLOCK ), locals => $locals_block, num_locals => $next_local, return_valtype => $ret_valtype },
            \@func_fixups );
    }

    # A pointer is a 64-bit value here, matching the way the IR models one, and
    # is only narrowed to the i32 that a Wasm memory access wants at the point of
    # the access. Keeping it 64-bit elsewhere is what stops an i32 address from
    # meeting an i64 offset, or a pointer argument, and disagreeing.
    method _wasm_valtype($ir_type) {
        return VALTYPE_I32 if $ir_type->kind eq 'int' && $ir_type->bits <= 32;      # i32
        return VALTYPE_I64 if $ir_type->kind eq 'int' && $ir_type->bits == 64;      # i64
        return VALTYPE_I64 if $ir_type->kind eq 'ptr';                              # pointer
        return VALTYPE_I64 if $ir_type->kind eq 'dynamic';                          # boxed value is an address
        return VALTYPE_F32 if $ir_type->kind eq 'float' && $ir_type->bits <= 32;    # f32
        return VALTYPE_F64 if $ir_type->kind eq 'float' && $ir_type->bits >= 64;    # f64
        return VALTYPE_I32;                                                         # default i32
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

    method build_debug_data( $ir_funcs, $func_blobs, $source_file = 'source.brocken', $text_base = 0, $class_info = {}, $debug_level = 0 ) {
        require Brocken::Jenny::Linker::DWARF;
        my @func_ranges;
        my @source_locs;
        my $text_offset = 0;
        for my $i ( 0 .. $#$ir_funcs ) {
            my $ir_fn            = $ir_funcs->[$i];
            my $blob             = $func_blobs->[$i];
            my $fname            = $blob->{name};
            my $fstart           = $text_offset;
            my $fend             = $text_offset + length( $blob->{bytes} );
            my $func_source_file = $fname =~ /^Brocken::Runtime::/ ? '<runtime>' : $source_file;
            push @func_ranges, { name => $fname, start => $fstart, end => $fend, params => [], locals => [], source_file => $func_source_file };
            my $source_map = $blob->{source_map} // {};
            my $inst_idx   = 0;

            for my $block ( $ir_fn->blocks->@* ) {
                for my $inst ( $block->instructions->@* ) {
                    if ( $inst->line ) {
                        my $offset = defined( $source_map->{$inst_idx} ) ? $fstart + $source_map->{$inst_idx} : $fstart;
                        push @source_locs, { offset => $offset, line => $inst->line, col => $inst->col, file => $func_source_file };
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
1;
