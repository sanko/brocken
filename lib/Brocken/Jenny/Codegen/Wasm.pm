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

        # %heap_ptr is a module global now, not a local: see
        # Brocken::Jenny::Linker::Wasm::_global_section. It is deliberately left
        # out of %vreg_map so no local slot is spent on it.

        # A Wasm branch may only reach a label that encloses it, so an arbitrary
        # control-flow graph cannot be laid out as a chain of nested blocks. Each
        # block instead becomes a case of a dispatch loop, and this local holds
        # the number of the one that runs next. Declared with no name in
        # %vreg_map, so it is typed i32 like the state it carries.
        my $state_local = $next_local++;
        my @blocks      = $mf->blocks->@*;
        my %label_to_block_idx;
        for my $bi ( 0 .. $#blocks ) {
            for my $inst ( $blocks[$bi]->instructions->@* ) {
                $label_to_block_idx{ $inst->operands->[0]->value } = $bi if $inst->opcode eq 'label';
            }
        }
        my $num_non_entry = $#blocks;

        # Local numbers are handed out in the order the body below first mentions
        # each value, but the declared type of a local has to be known while that
        # body is emitted: a branch tests an i32, and a comparison result may be
        # held in an i64 local that needs narrowing first. Assigning every local
        # up front, from the same walk, keeps the declaration and the narrowing
        # in step instead of leaving the two to be derived separately.
        my $num_params = scalar( $ir_params->@* );
        my %mir_local_type;
        for my $mbb (@blocks) {
            for my $inst ( $mbb->instructions->@* ) {
                next unless $inst->opcode eq 'local_get' || $inst->opcode eq 'local_set';
                my $mo = $inst->operands->[0];
                $mir_local_type{ $mo->value } //= $mo->type;
                $vreg_map{ $mo->value } //= $next_local++;
            }
        }
        my %lid_to_type;
        {
            my %lid_to_name = reverse %vreg_map;

            # A parameter's type is carried by the parameter itself; only the
            # values defined in the body appear in %ir_types. Without this a
            # pointer parameter would fall through to the i32 default and be
            # declared too narrow for the i64 that gets passed to it.
            for my $i ( 0 .. $num_params - 1 ) {
                my $pt = $ir_params->[$i]->type;
                $lid_to_type{$i} = $pt ? $self->_wasm_valtype($pt) : VALTYPE_I32;
            }

            # A name the lowerer invented is not in the IR at all: %heap_ptr,
            # which carries the bump allocator between allocas, is defined
            # straight into MIR as a pointer. The MIR operand still knows that,
            # so ask it before giving up and declaring the local i32. Declaring
            # it too narrow made every body that allocates fail validation
            # outright -- "type mismatch: expected i32, found i64" at the first
            # use of the address -- which is every untyped `my`, since an
            # untyped variable is boxed and so needs an alloca.
            for my $lid ( $num_params .. $next_local - 1 ) {
                my $name  = $lid_to_name{$lid} // '';
                my $itype = $name ? ( $ir_types->{$name} // $mir_local_type{$name} ) : undef;
                $lid_to_type{$lid} = $itype ? $self->_wasm_valtype($itype) : VALTYPE_I32;
            }
        }
        my $entry_bytes = '';
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

                    # Each case body is emitted between the end of its own block
                    # and the end of the next one out, so from inside case $bi the
                    # enclosing labels are the $bi case blocks, then $exit, then
                    # $loop: a branch to the dispatch is depth $bi + 1.
                    #
                    # Both outcomes re-dispatch, and the block number has to reach
                    # the state local on either path, before the branch. A block
                    # cannot carry that: it validates against a fresh operand
                    # stack, so it would not see a condition pushed before it
                    # opened. Choosing between the two indices here keeps the
                    # condition reachable, and stashing it in the state local
                    # first clears the stack for the select.
                    my $true_idx  = $label_to_block_idx{ $ops[0]->value };
                    my $false_idx = $label_to_block_idx{ $ops[1]->value };
                    $$buf .= pack( 'C', LOCAL_SET ) . $self->_uleb($state_local);
                    $$buf .= pack( 'C', I32_CONST ) . $self->_sleb($true_idx);
                    $$buf .= pack( 'C', I32_CONST ) . $self->_sleb($false_idx);
                    $$buf .= pack( 'C', LOCAL_GET ) . $self->_uleb($state_local);
                    $$buf .= pack( 'C', SELECT_T ) . pack( 'C', 1 ) . pack( 'C', VALTYPE_I32 );
                    $$buf .= pack( 'C', LOCAL_SET ) . $self->_uleb($state_local);
                    $$buf .= pack( 'C', BR ) . $self->_uleb( $bi + 1 );
                }
                elsif ( $opcode eq 'jmp' ) {
                    my $target_idx = $label_to_block_idx{ $ops[0]->value };
                    $$buf .= pack( 'C', I32_CONST ) . $self->_sleb($target_idx);
                    $$buf .= pack( 'C', LOCAL_SET ) . $self->_uleb($state_local);
                    $$buf .= pack( 'C', BR ) . $self->_uleb( $bi + 1 );
                }
                elsif ( $opcode eq 'local_get' ) {
                    my $lid = $vreg_map{ $ops[0]->value } //= $next_local++;
                    $$buf .= pack( 'C', LOCAL_GET ) . $self->_uleb($lid);
                }
                elsif ( $opcode eq 'global_get' ) {
                    $$buf .= pack( 'C', GLOBAL_GET ) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'global_set' ) {
                    $$buf .= pack( 'C', GLOBAL_SET ) . $self->_uleb(0);
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
                elsif ( $opcode eq 'i32_div_s' ) { $$buf .= pack( 'C', I32_DIV_S ) }
                elsif ( $opcode eq 'i32_div_u' ) { $$buf .= pack( 'C', I32_DIV_U ) }
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
                elsif ( $opcode eq 'i64_div_s' ) { $$buf .= pack( 'C', I64_DIV_S ) }
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
                elsif ( $opcode eq 'i32_load8_s' ) {
                    $$buf .= pack( 'C', I32_LOAD8_S ) . $self->_uleb(0) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i32_load8_u' ) {
                    $$buf .= pack( 'C', I32_LOAD8_U ) . $self->_uleb(0) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i32_load16_s' ) {
                    $$buf .= pack( 'C', I32_LOAD16_S ) . $self->_uleb(1) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i32_load16_u' ) {
                    $$buf .= pack( 'C', I32_LOAD16_U ) . $self->_uleb(1) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_load8_s' ) {
                    $$buf .= pack( 'C', I64_LOAD8_S ) . $self->_uleb(0) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_load8_u' ) {
                    $$buf .= pack( 'C', I64_LOAD8_U ) . $self->_uleb(0) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_load16_s' ) {
                    $$buf .= pack( 'C', I64_LOAD16_S ) . $self->_uleb(1) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_load16_u' ) {
                    $$buf .= pack( 'C', I64_LOAD16_U ) . $self->_uleb(1) . $self->_uleb(0);
                }
                elsif ( $opcode eq 'i64_load32_s' ) {
                    $$buf .= pack( 'C', I64_LOAD32_S ) . $self->_uleb(2) . $self->_uleb(0);
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
                elsif ( $opcode eq 'f64_convert_i32_s' ) { $$buf .= pack( 'C', F64_CONVERT_I32_S ) }
                elsif ( $opcode eq 'f32_convert_i64_s' ) { $$buf .= pack( 'C', F32_CONVERT_I64_S ) }
                elsif ( $opcode eq 'f32_convert_i32_s' ) { $$buf .= pack( 'C', F32_CONVERT_I32_S ) }
                elsif ( $opcode eq 'i64_trunc_f64_s' )   { $$buf .= pack( 'C', I64_TRUNC_F64_S ) }
                elsif ( $opcode eq 'i64_trunc_f32_s' )   { $$buf .= pack( 'C', I64_TRUNC_F32_S ) }
                elsif ( $opcode eq 'i32_trunc_f64_s' )   { $$buf .= pack( 'C', I32_TRUNC_F64_S ) }
                elsif ( $opcode eq 'i32_trunc_f32_s' )   { $$buf .= pack( 'C', I32_TRUNC_F32_S ) }
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

        # Assemble the function body. A branch can only reach an enclosing label, so
        # the blocks are not nested one inside the next: each one becomes a case
        # of a dispatch loop. The openers run outermost-first ($loop, $exit, then
        # $case0..$caseN with $case0 the outermost case), so $caseN and $default
        # are innermost and close first.
        my @block_start;
        my $pos     = 0;
        my $nblocks = scalar @blocks;
        my $top     = $nblocks - 1;
        my $emit    = sub ($chunk) { $bytes .= $chunk; $pos += length($chunk); };

        # The first case runs on entry. A case that branches back to the dispatch
        # leaves its target in the state local, so seeding it here rather than
        # inside the loop is what keeps a re-dispatch from restarting at case 0.
        $emit->( pack( 'C', I32_CONST ) . $self->_sleb(0) );
        $emit->( pack( 'C', LOCAL_SET ) . $self->_uleb($state_local) );
        $emit->( pack( 'C', LOOP ) . pack( 'C', 0x40 ) );                  # $loop
        $emit->( pack( 'C', BLOCK ) . pack( 'C', 0x40 ) );                 # $exit
        $emit->( pack( 'C', BLOCK ) . pack( 'C', 0x40 ) ) for 0 .. $top;

        # The dispatch sits inside every case label, so a single br_table reaches
        # all of them: case $top is depth 1, case 0 is depth $top + 1.
        $emit->( pack( 'C', BLOCK ) . pack( 'C', 0x40 ) );                # $default
        $emit->( pack( 'C', LOCAL_GET ) . $self->_uleb($state_local) );
        $emit->( pack( 'C', BR_TABLE ) . $self->_uleb( $top + 1 ) );
        $emit->( $self->_uleb( 1 + $top - $_ ) ) for 0 .. $top;
        $emit->( $self->_uleb(0) );                                       # out of range: fall through to the trap
        $emit->( pack( 'C', END_BLOCK ) );

        # The state only ever holds a block number that was set here, so an
        # out-of-range value is a codegen bug. Trap rather than return, which
        # would have to supply a result of whatever type the function declares.
        $emit->( pack( 'C', UNREACHABLE ) );
        for my $bi ( reverse 0 .. $top ) {
            $emit->( pack( 'C', END_BLOCK ) );
            $block_start[$bi] = $pos;
            $emit->( $bi == 0 ? $entry_bytes : $non_entry_bytes[ $bi - 1 ] );

            # A block that runs off its end would otherwise fall into the next
            # case, so every case ends by re-dispatching even when its own
            # terminator already left.
            $emit->( pack( 'C', I32_CONST ) . $self->_sleb(0) );
            $emit->( pack( 'C', LOCAL_SET ) . $self->_uleb($state_local) );
            $emit->( pack( 'C', BR ) . $self->_uleb( $bi + 1 ) );
        }
        $emit->( pack( 'C', END_BLOCK ) );    # $exit
        $emit->( pack( 'C', END_BLOCK ) );    # $loop

        # Every path out of the dispatch leaves by returning, by trapping or by
        # branching back to it, so falling out of the loop cannot happen. It has
        # to be said anyway: unreachability does not carry out of a void block,
        # so without this the frame is reachable with an empty stack and a
        # function that returns a value fails to validate at its final end.
        $emit->( pack( 'C', UNREACHABLE ) );
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
        my $num_extra_locals = $next_local - $num_params;
        my $locals_block     = '';
        if ( $num_extra_locals > 0 ) {

            # Group consecutive locals that share a declared type. The widths come
            # from the table built before the body was emitted, so what is declared
            # here is exactly what the body was compiled against.
            my @groups;
            my $prev_wt;
            for my $lid ( $num_params .. $next_local - 1 ) {
                my $wt = $lid_to_type{$lid} // VALTYPE_I32;
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
