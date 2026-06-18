use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use List::Util ();
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Lowerer::ARM64;
use Brocken::Jenny::RegAlloc;
use Brocken::Jenny::MIR;

class Brocken::Jenny::Codegen::ARM64 {
    field $platform : param = Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu');
    use constant {
        B            => 0x14000000,
        CBZ          => 0xB4000000,
        CBNZ         => 0xB5000000,
        ADD_W        => 0x0B000000,
        SUB_W        => 0x4B000000,
        AND_W        => 0x0A000000,
        ORR_W        => 0x2A000000,
        EOR_W        => 0x4A000000,
        MUL_W        => 0x1B007C00,
        ADD_X        => 0x8B000000,
        SUB_X        => 0xCB000000,
        ADCS_X       => 0x9A000000,
        SBCS_X       => 0xDA000000,
        AND_X        => 0x8A000000,
        ORR_X        => 0xAA000000,
        EOR_X        => 0xCA000000,
        MUL_X        => 0x9B007C00,
        UMULH_X      => 0x9BC07C00,
        UDIV_X       => 0x9AC00800,
        ADD_IMM      => 0x11000000,
        SUB_IMM      => 0x51000000,
        UBFM         => 0xD3400000,
        SBFM         => 0x93400000,
        MOVZ_32      => 0x52800000,
        MOVZ_64      => 0xD2800000,
        MOVK_32      => 0x72800000,
        MOVK_64      => 0xF2800000,
        MOV_X        => 0xAA0003E0,
        SUB_SP       => 0xD10003FF,
        ADD_SP       => 0x910003FF,
        MOV_SP       => 0x910003E0,
        LDR_32       => 0xB9400000,
        LDR_64       => 0xF9400000,
        STR_32       => 0xB9000000,
        STR_64       => 0xF9000000,
        LDR_32_REG   => 0xB8408000,
        LDR_64_REG   => 0xF8408000,
        STR_32_REG   => 0xB8208000,
        STR_64_REG   => 0xF8208000,
        FLDR_32      => 0xBD400000,
        FLDR_64      => 0xFD400000,
        FSTR_32      => 0xBD000000,
        FSTR_64      => 0xFD000000,
        FLDR_32_REG  => 0xBC408000,
        FLDR_64_REG  => 0xFC408000,
        FSTR_32_REG  => 0xBC208000,
        FSTR_64_REG  => 0xFC208000,
        CMP_IMM      => 0x7100001F,
        CMP_REG      => 0x6B00001F,
        CSINC        => 0x9A9F07E0,
        FABS_32      => 0x1E20C000,
        FNEG_32      => 0x1E214000,
        FSQRT_32     => 0x1E21C000,
        FMOV_32      => 0x1E204000,
        FMOV_GP2F_32 => 0x1E270000,
        FMOV_GP2F_64 => 0x9E670000,
        FCMP_32      => 0x1E202000,
        FCMP_64      => 0x1E602000,
        FP_SZ        => 0x00400000,
        FADD         => 0x1E202800,
        FSUB         => 0x1E203800,
        FMUL         => 0x1E200800,
        FDIV         => 0x1E201800,
        FMIN         => 0x1E205800,
        FMAX         => 0x1E204800,
        SF           => 0x80000000,
        RET          => 0xD65F03C0,
    };

    method emit_function($ir_func) {
        my $lowerer = Brocken::Jenny::Lowerer::ARM64->new();
        my $mf      = $lowerer->lower($ir_func);
        my $alloc   = Brocken::Jenny::RegAlloc::LinearScan->new();
        my $int_res = $alloc->allocate( $mf, $platform, 0 );
        $alloc->insert_spill_code( $mf, $int_res->{spill_slots}, $int_res->{spill_temp}, $platform->stack_reg, 0 );
        my $fp_res = $alloc->allocate( $mf, $platform, 1 );
        $alloc->insert_spill_code( $mf, $fp_res->{spill_slots}, $fp_res->{spill_temp}, $platform->stack_reg, 1 );
        my %assignment = ( $int_res->{assignment}->%*, $fp_res->{assignment}->%* );
        my %skip;
        @skip{ $platform->return_register, $platform->fp_return_register } = ( 1, 1 );
        my @gp_caller = grep { !$skip{$_} } $platform->registers('caller')->@*;
        my @fp_caller = grep { !$skip{$_} } $platform->fp_registers('caller')->@*;
        $alloc->insert_caller_save_code( $mf, \@gp_caller, $platform->stack_reg, 0 );
        $alloc->insert_caller_save_code( $mf, \@fp_caller, $platform->stack_reg, 1 );
        $alloc->remove_redundant_moves( $mf, \%assignment );
        my %callee_seen;
        @callee_seen{ $int_res->{used_callee}->@* } = ();
        @callee_seen{ $fp_res->{used_callee}->@* }  = ();
        my @used_callee = sort keys %callee_seen;
        my ($bytes) = $self->_encode( $mf, \%assignment, \@used_callee );
        return $bytes;
    }

    method emit_functions($ir_funcs) {
        my @result;
        for my $func ( $ir_funcs->@* ) {
            my $lowerer = Brocken::Jenny::Lowerer::ARM64->new();
            my $mf      = $lowerer->lower($func);
            my $alloc   = Brocken::Jenny::RegAlloc::LinearScan->new();
            my $int_res = $alloc->allocate( $mf, $platform, 0 );
            $alloc->insert_spill_code( $mf, $int_res->{spill_slots}, $int_res->{spill_temp}, $platform->stack_reg, 0 );
            my $fp_res = $alloc->allocate( $mf, $platform, 1 );
            $alloc->insert_spill_code( $mf, $fp_res->{spill_slots}, $fp_res->{spill_temp}, $platform->stack_reg, 1 );
            my %assignment = ( $int_res->{assignment}->%*, $fp_res->{assignment}->%* );
            my %skip;
            @skip{ $platform->return_register, $platform->fp_return_register } = ( 1, 1 );
            my @gp_caller = grep { !$skip{$_} } $platform->registers('caller')->@*;
            my @fp_caller = grep { !$skip{$_} } $platform->fp_registers('caller')->@*;
            $alloc->insert_caller_save_code( $mf, \@gp_caller, $platform->stack_reg, 0 );
            $alloc->insert_caller_save_code( $mf, \@fp_caller, $platform->stack_reg, 1 );
            $alloc->remove_redundant_moves( $mf, \%assignment );
            my %callee_seen;
            @callee_seen{ $int_res->{used_callee}->@* } = ();
            @callee_seen{ $fp_res->{used_callee}->@* }  = ();
            my @used_callee = sort keys %callee_seen;
            my ( $bytes, $func_fixups ) = $self->_encode( $mf, \%assignment, \@used_callee );
            push @result, { name => $func->name, bytes => $bytes, fixups => $func_fixups };
        }
        return \@result;
    }

    method _encode( $mf, $assignment, $used_callee ) {
        my $bytes        = '';
        my $alloca_frame = 0;
        my $is_leaf      = 1;
        my $spill_frame  = $self->_compute_spill_frame( $mf, 'sp' );
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                $is_leaf = 0 if $inst->opcode eq 'call_func';
            }
        }
        my @to_save = $used_callee->@*;
        if ( !$is_leaf ) {
            push @to_save, 'x30';
        }
        my $callee_size   = scalar(@to_save) * 8;
        my $unified_frame = ( $callee_size + $spill_frame + 15 ) & ~15;
        my $extra_frame   = $unified_frame - $callee_size;
        my $reg_id        = sub ($r) {
            return 31 if $r eq 'sp';
            return $1 if $r =~ /^[xw](\d+)$/;
            return $1 if $r =~ /^v(\d+)$/;
            return 0;
        };
        my $resolve = sub ($op) {
            return $assignment->{ $op->value } // $op->value if $op->kind eq 'virt_reg';
            return $op->value                                if $op->kind eq 'phys_reg';
            die "Unexpected operand kind: ${\$op->kind}";
        };
        if ( $unified_frame > 0 ) {
            $bytes .= pack( 'V', SUB_SP | ( ( $unified_frame & 0xFFF ) << 10 ) );
            for my $i ( 0 .. $#to_save ) {
                my $reg  = $to_save[$i];
                my $rid  = $reg_id->($reg);
                my $base = $reg =~ /^v/ ? FSTR_64 : STR_64;
                my $imm12 = ( $extra_frame + $i * 8 ) >> 3;
                $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( 31 << 5 ) | $rid );
            }
        }
        my %labels;
        my @fixups;
        my @func_fixups;
        my $current_offset = sub { return length $bytes };
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                my $opcode = $inst->opcode;
                my ( $dst, $src ) = $inst->operands->@*;
                if ( $opcode eq 'label' ) {
                    $labels{ $dst->value } = $current_offset->();
                }
                elsif ( $opcode eq 'jmp' ) {
                    push @fixups, { offset => $current_offset->(), type => 'b', target => $dst->value };
                    $bytes .= pack( 'V', B );
                }
                elsif ( $opcode eq 'beq' || $opcode eq 'bne' ) {
                    my $cond_r = $resolve->($dst);
                    my $cid    = $reg_id->($cond_r);
                    my $base   = ( $opcode eq 'bne' ? CBNZ : CBZ );
                    push @fixups, { offset => $current_offset->(), type => 'cbz', target => $src->value, rid => $cid, base => $base };
                    $bytes .= pack( 'V', $base | $cid );
                }
                elsif ( $opcode eq 'mov' || $opcode eq 'mv' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    if ( $src->kind eq 'imm' ) {
                        my $bits    = $dst->type      ? $dst->type->bits : 64;
                        my $sf      = ( $bits >= 64 ) ? SF               : 0x00000000;
                        my $value   = $src->value;
                        my $max_hw  = int( ( $bits + 15 ) / 16 ) - 1;
                        my $emitted = 0;
                        for my $hw ( 0 .. $max_hw ) {
                            my $chunk = ( $value >> ( $hw * 16 ) ) & 0xFFFF;
                            if ( $chunk || !$emitted ) {
                                my $base = $emitted ? MOVK_32 : MOVZ_32;
                                $bytes .= pack( 'V', $sf | $base | ( $chunk << 5 ) | ( $hw << 21 ) | $did );
                                $emitted = 1;
                            }
                        }
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        $bytes .= pack( 'V', MOV_X | ( $sid << 16 ) | $did );
                    }
                }
                elsif ( $opcode eq 'add' ||
                    $opcode eq 'sub'   ||
                    $opcode eq 'and'   ||
                    $opcode eq 'or'    ||
                    $opcode eq 'xor'   ||
                    $opcode eq 'mul'   ||
                    $opcode eq 'umulh' ||
                    $opcode eq 'udiv'  ||
                    $opcode eq 'adc'   ||
                    $opcode eq 'sbb' ) {
                    my $dst_r  = $resolve->($dst);
                    my $did    = $reg_id->($dst_r);
                    my $bits   = $dst->type ? $dst->type->bits : 64;    # width-aware
                    my %reg_op = (
                        add   => ( $bits >= 64 ? ADD_X : ADD_W ),
                        sub   => ( $bits >= 64 ? SUB_X : SUB_W ),
                        and   => ( $bits >= 64 ? AND_X : AND_W ),
                        or    => ( $bits >= 64 ? ORR_X : ORR_W ),
                        xor   => ( $bits >= 64 ? EOR_X : EOR_W ),
                        mul   => ( $bits >= 64 ? MUL_X : MUL_W ),
                        umulh => UMULH_X,
                        udiv  => UDIV_X,
                        adc   => ADCS_X,
                        sbb   => SBCS_X,
                    );
                    if ( $src->kind eq 'imm' && ( $opcode eq 'add' || $opcode eq 'sub' ) ) {
                        my $sf    = ( $bits >= 64 ) ? SF : 0x00000000;
                        my $op    = $sf | ( $opcode eq 'add' ? ADD_IMM : SUB_IMM );
                        my $imm12 = $src->value & 0xFFF;
                        $bytes .= pack( 'V', $op | ( $imm12 << 10 ) | ( $did << 5 ) | $did );
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $op    = $reg_op{$opcode};
                        $bytes .= pack( 'V', $op | ( $sid << 16 ) | ( $did << 5 ) | $did );
                    }
                }
                elsif ( $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    if ( $src->kind eq 'imm' ) {
                        my $imm = $src->value;
                        if ( $opcode eq 'shl' ) {
                            my $immr = ( 64 - $imm ) & 0x3F;
                            my $imms = ( 63 - $imm ) & 0x3F;
                            $bytes .= pack( 'V', UBFM | ( $immr << 16 ) | ( $imms << 10 ) | ( $did << 5 ) | $did );
                        }
                        elsif ( $opcode eq 'lshr' ) {
                            $bytes .= pack( 'V', UBFM | ( $imm << 16 ) | ( 63 << 10 ) | ( $did << 5 ) | $did );
                        }
                        else {
                            $bytes .= pack( 'V', SBFM | ( $imm << 16 ) | ( 63 << 10 ) | ( $did << 5 ) | $did );
                        }
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my %base  = ( shl => 0x9AC02000, lshr => 0x9AC02400, ashr => 0x9AC02C00 );
                        $bytes .= pack( 'V', $base{$opcode} | ( $sid << 16 ) | ( $did << 5 ) | $did );
                    }
                }
                elsif ( $opcode eq 'alloca' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $size  = $src->value;
                    $alloca_frame += $size;
                    $bytes .= pack( 'V', SUB_SP | ( ( $size & 0xFFF ) << 10 ) );
                    $bytes .= pack( 'V', MOV_SP | $did );
                }
                elsif ( $opcode eq 'load' ) {
                    my $dst_r  = $resolve->($dst);
                    my $did    = $reg_id->($dst_r);
                    my $addr   = $src->value;
                    my $base_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} ) );
                    my $bid    = $reg_id->($base_r);
                    my $bits   = ( $dst->type && $dst->type->kind eq 'int' ) ? $dst->type->bits : 64;
                    if ( defined $addr->{index} ) {
                        my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid     = $reg_id->($index_r);
                        my $reg_op  = $bits == 32 ? LDR_32_REG : LDR_64_REG;
                        $bytes .= pack( 'V', $reg_op | ( $iid << 16 ) | ( $bid << 5 ) | $did );
                    }
                    else {
                        my $disp  = $addr->{disp} // 0;
                        my $imm12 = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $base  = $bits == 32 ? LDR_32 : LDR_64;
                        $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( $bid << 5 ) | $did );
                    }
                }
                elsif ( $opcode eq 'store' ) {
                    my $src_r  = $resolve->($src);
                    my $sid    = $reg_id->($src_r);
                    my $addr   = $dst->value;
                    my $base_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} ) );
                    my $bid    = $reg_id->($base_r);
                    my $bits   = ( $src->type && $src->type->kind eq 'int' ) ? $src->type->bits : 64;
                    if ( defined $addr->{index} ) {
                        my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid     = $reg_id->($index_r);
                        my $reg_op  = $bits == 32 ? STR_32_REG : STR_64_REG;
                        $bytes .= pack( 'V', $reg_op | ( $iid << 16 ) | ( $bid << 5 ) | $sid );
                    }
                    else {
                        my $disp  = $addr->{disp} // 0;
                        my $imm12 = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $base  = $bits == 32 ? STR_32 : STR_64;
                        $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( $bid << 5 ) | $sid );
                    }
                }
                elsif ( $opcode eq 'store_imm' ) {
                    my ( $mem, $imm ) = $inst->operands->@*;
                    my $addr   = $mem->value;
                    my $base_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} ) );
                    my $bid    = $reg_id->($base_r);
                    my $bits   = ( $imm->type && $imm->type->kind eq 'int' ) ? $imm->type->bits : 64;

                    # find a temporary register not in use
                    my %used;
                    @used{ values %$assignment } = ();
                    my $tmp_r;
                    for my $r ( $platform->registers('caller')->@* ) { $tmp_r = $r, last unless exists $used{$r} }
                    die 'no temp register for store_imm' unless $tmp_r;
                    my $tid     = $reg_id->($tmp_r);
                    my $imm_val = $imm->value;
                    my $max_hw  = int( ( $bits + 15 ) / 16 ) - 1;

                    for my $hw ( 0 .. $max_hw ) {
                        my $chunk = ( $imm_val >> ( $hw * 16 ) ) & 0xFFFF;
                        if ( $chunk || $hw == 0 ) {
                            my $base = $hw == 0 ? ( $bits >= 64 ? MOVZ_64 : MOVZ_32 ) : ( $bits >= 64 ? MOVK_64 : MOVK_32 );
                            $bytes .= pack( 'V', $base | ( $chunk << 5 ) | ( $hw << 21 ) | $tid );
                        }
                    }
                    if ( defined $addr->{index} ) {
                        my $index_r  = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid      = $reg_id->($index_r);
                        my $str_base = $bits >= 64 ? STR_64_REG : STR_32_REG;
                        $bytes .= pack( 'V', $str_base | ( $iid << 16 ) | ( $bid << 5 ) | $tid );
                    }
                    else {
                        my $disp     = $addr->{disp} // 0;
                        my $imm12    = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $str_base = $bits >= 64 ? STR_64 : STR_32;
                        $bytes .= pack( 'V', $str_base | ( $imm12 << 10 ) | ( $bid << 5 ) | $tid );
                    }
                }
                elsif ( $opcode eq 'cmp' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $bits  = $dst->type      ? $dst->type->bits : 64;
                    my $sf    = ( $bits >= 64 ) ? SF               : 0x00000000;
                    if ( $src->kind eq 'imm' ) {
                        my $imm12 = $src->value & 0xFFF;
                        $bytes .= pack( 'V', $sf | CMP_IMM | ( $imm12 << 10 ) | ( $did << 5 ) );
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        $bytes .= pack( 'V', $sf | CMP_REG | ( $sid << 16 ) | ( $did << 5 ) );
                    }
                }
                elsif ( $opcode eq 'cset_eq' ||
                    $opcode eq 'cset_ne' ||
                    $opcode eq 'cset_lt' ||
                    $opcode eq 'cset_gt' ||
                    $opcode eq 'cset_le' ||
                    $opcode eq 'cset_ge' ||
                    $opcode eq 'cset_cc' ||
                    $opcode eq 'cset_cs' ||
                    $opcode eq 'cset_hi' ||
                    $opcode eq 'cset_ls' ||
                    $opcode eq 'cset_vc' ||
                    $opcode eq 'cset_vs' ) {
                    my %arm_cond = (
                        cset_eq => 1,
                        cset_ne => 0,
                        cset_lt => 0xA,
                        cset_gt => 0xD,
                        cset_le => 0xC,
                        cset_ge => 0xB,
                        cset_cc => 2,
                        cset_cs => 3,
                        cset_hi => 9,
                        cset_ls => 8,
                        cset_vc => 6,
                        cset_vs => 7
                    );
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $cond  = $arm_cond{$opcode};
                    $bytes .= pack( 'V', CSINC | ( 31 << 16 ) | ( $cond << 12 ) | ( 31 << 5 ) | $did );
                }
                elsif ( $opcode eq 'sltu' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    $bytes .= pack( 'V', 0xEB00001F | ( $sid << 16 ) | ( $did << 5 ) );
                    $bytes .= pack( 'V', CSINC | ( 31 << 16 ) | ( 2 << 12 ) | ( 31 << 5 ) | $did );
                }
                elsif ( $opcode eq 'fload' ) {
                    my $dst_r  = $resolve->($dst);
                    my $did    = $reg_id->($dst_r);
                    my $addr   = $src->value;
                    my $base_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} ) );
                    my $bid    = $reg_id->($base_r);
                    my $bits   = $dst->type ? $dst->type->bits : 64;
                    if ( defined $addr->{index} ) {
                        my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid     = $reg_id->($index_r);
                        my $reg_op  = $bits == 32 ? FLDR_32_REG : FLDR_64_REG;
                        $bytes .= pack( 'V', $reg_op | ( $iid << 16 ) | ( $bid << 5 ) | $did );
                    }
                    else {
                        my $disp  = $addr->{disp} // 0;
                        my $imm12 = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $base  = $bits == 32 ? FLDR_32 : FLDR_64;
                        $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( $bid << 5 ) | $did );
                    }
                }
                elsif ( $opcode eq 'fstore' ) {
                    my $mem    = $dst;
                    my $src_r  = $resolve->($src);
                    my $sid    = $reg_id->($src_r);
                    my $addr   = $mem->value;
                    my $base_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} ) );
                    my $bid    = $reg_id->($base_r);
                    my $bits   = $src->type ? $src->type->bits : 64;
                    if ( defined $addr->{index} ) {
                        my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid     = $reg_id->($index_r);
                        my $reg_op  = $bits == 32 ? FSTR_32_REG : FSTR_64_REG;
                        $bytes .= pack( 'V', $reg_op | ( $iid << 16 ) | ( $bid << 5 ) | $sid );
                    }
                    else {
                        my $disp  = $addr->{disp} // 0;
                        my $imm12 = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $base  = $bits == 32 ? FSTR_32 : FSTR_64;
                        $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( $bid << 5 ) | $sid );
                    }
                }
                elsif ( $opcode eq 'fmov' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type  ? $dst->type->bits : 64;
                    my $base  = $bits == 32 ? FMOV_32          : ( FMOV_32 | FP_SZ );
                    $bytes .= pack( 'V', $base | ( $sid << 5 ) | $did );
                }
                elsif ( $opcode eq 'fmov_gp2f' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type  ? $dst->type->bits : 64;
                    my $base  = $bits == 32 ? FMOV_GP2F_32     : FMOV_GP2F_64;
                    $bytes .= pack( 'V', $base | ( $sid << 5 ) | $did );
                }
                elsif ( $opcode eq 'fadd' || $opcode eq 'fsub' || $opcode eq 'fmul' || $opcode eq 'fdiv' || $opcode eq 'fmin' || $opcode eq 'fmax' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type ? $dst->type->bits : 64;
                    my %fop   = ( fadd => FADD, fsub => FSUB, fmul => FMUL, fdiv => FDIV, fmin => FMIN, fmax => FMAX );
                    my $base  = $fop{$opcode};
                    $base = $bits == 32 ? $base : ( $base | FP_SZ );
                    $bytes .= pack( 'V', $base | ( $sid << 16 ) | ( $did << 5 ) | $did );
                }
                elsif ( $opcode eq 'fsqrt' || $opcode eq 'fabs' || $opcode eq 'fneg' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type ? $dst->type->bits : 64;
                    my %fop   = ( fsqrt => FSQRT_32, fabs => FABS_32, fneg => FNEG_32 );
                    my $base  = $fop{$opcode};
                    $base = $bits == 32 ? $base : ( $base | FP_SZ );
                    $bytes .= pack( 'V', $base | ( $sid << 5 ) | $did );
                }
                elsif ( $opcode eq 'fcmp' ) {
                    my $lhs_r = $resolve->($dst);
                    my $lid   = $reg_id->($lhs_r);
                    my $rhs_r = $resolve->($src);
                    my $rid   = $reg_id->($rhs_r);
                    my $bits  = $dst->type  ? $dst->type->bits : 64;
                    my $base  = $bits == 32 ? FCMP_32          : FCMP_64;
                    $bytes .= pack( 'V', $base | ( $rid << 16 ) | ( $lid << 5 ) );
                }
                elsif ( $opcode eq 'call_func' ) {
                    my $func_name = $dst->value;
                    push @func_fixups, { offset => $current_offset->(), type => 'call_bl', target => $func_name };
                    $bytes .= pack( 'V', 0x94000000 );
                }
                elsif ( $opcode eq 'ret' ) {
                    if ( $alloca_frame > 0 ) {
                        $bytes .= pack( 'V', ADD_SP | ( ( $alloca_frame & 0xFFF ) << 10 ) );
                    }
                    if ( $callee_size > 0 ) {
                        for my $i ( reverse 0 .. $#to_save ) {
                            my $reg  = $to_save[$i];
                            my $rid  = $reg_id->($reg);
                            my $base = $reg =~ /^v/ ? FLDR_64 : LDR_64;
                            my $imm12 = ( $extra_frame + $i * 8 ) >> 3;
                            $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( 31 << 5 ) | $rid );
                        }
                    }
                    if ( $unified_frame > 0 ) {
                        $bytes .= pack( 'V', ADD_SP | ( ( $unified_frame & 0xFFF ) << 10 ) );
                    }
                    $bytes .= pack( 'V', RET );
                }
            }
        }
        for my $fixup (@fixups) {
            my $target_pos = $labels{ $fixup->{target} };
            die "undefined label: $fixup->{target}" unless defined $target_pos;
            my $rel = $target_pos - $fixup->{offset};
            if ( $fixup->{type} eq 'b' ) {
                substr $bytes, $fixup->{offset}, 4, pack( 'V', B | ( ( $rel / 4 ) & 0x3FFFFFF ) );
            }
            elsif ( $fixup->{type} eq 'cbz' ) {
                my $inst = unpack( 'V', substr $bytes, $fixup->{offset}, 4 );
                $inst = ( $inst & 0xFF00001F ) | ( ( ( $rel / 4 ) & 0x7FFFF ) << 5 );
                substr $bytes, $fixup->{offset}, 4, pack( 'V', $inst );
            }
        }
        return ( $bytes, \@func_fixups );
    }

    method _compute_spill_frame( $mf, $stack_reg ) {
        my $max_disp = 0;
        my $found    = 0;
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                for my $op ( $inst->operands->@* ) {
                    next unless $op->kind eq 'mem';
                    my $addr = $op->value;
                    next unless defined $addr->{base} && !ref $addr->{base} && $addr->{base} eq $stack_reg;
                    $max_disp = List::Util::max( $max_disp, $addr->{disp} // 0 );
                    $found    = 1;
                }
            }
        }
        return $found ? ( ( $max_disp + 8 + 15 ) & ~15 ) : 0;
    }
}
1;
