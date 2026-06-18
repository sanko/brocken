use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use List::Util ();
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Lowerer::X86_64;
use Brocken::Jenny::RegAlloc;
use Brocken::Jenny::MIR;

class Brocken::Jenny::Codegen::X86_64 {
    field $platform : param = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
    use constant {
        REX_W       => 0x08,
        REX_B       => 0x01,
        MOV_EAX_IMM => 0xB8,
        MOV_RM_R    => 0x8B,
        MOV_R_RM    => 0x89,
        MOV_IMM_RM  => 0xC7,
        ARITH_IMM   => 0x81,
        CMP_IMM8    => 0x83,
        SHIFT_IMM   => 0xC1,
        IMUL_IMM    => 0x69,
        JMP_REL32   => 0xE9,
        JE          => 0x84,
        JNE         => 0x85,
        RET_BYTE    => 0xC3,
        POP_BASE    => 0x58,
        PUSH_BASE   => 0x50,
    };

    # Lower Lindsay IR to MIR, allocate registers, then encode to x86_64 machine code
    method emit_function($ir_func) {
        my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
        my $mf      = $lowerer->lower($ir_func);
        my $alloc   = Brocken::Jenny::RegAlloc::LinearScan->new();
        my $int_res = $alloc->allocate( $mf, $platform, 0 );
        $alloc->insert_spill_code( $mf, $int_res->{spill_slots}, $int_res->{spill_temp}, $platform->stack_reg, 0 );
        my $fp_res = $alloc->allocate( $mf, $platform, 1 );
        $alloc->insert_spill_code( $mf, $fp_res->{spill_slots}, $fp_res->{spill_temp}, $platform->stack_reg, 1 );
        my %assignment = ( $int_res->{assignment}->%*, $fp_res->{assignment}->%* );

        # Caller-save: save/restore caller regs around call_func (exclude return registers)
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

    # Emit multiple functions with cross-function call fixups
    method emit_functions($ir_funcs) {
        my @result;
        for my $func ( $ir_funcs->@* ) {
            my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
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

    # Encode MIR to x86_64 machine code bytes (registers pre-allocated)
    method _encode( $mf, $assignment, $used_callee ) {
        my $bytes        = '';
        my $alloca_frame = 0;
        my %reg_id_map   = ( rax => 0, rcx => 1, rdx => 2, rbx => 3, rsp => 4, rbp => 5, rsi => 6, rdi => 7 );
        for my $i ( 0 .. 15 ) { $reg_id_map{"xmm$i"} = $i }
        my $reg_id        = sub ($r) { return $reg_id_map{$r} // ( $r =~ /^r(\d+)$/ ? $1 : 0 ) };
        my $spill_frame   = $self->_compute_spill_frame( $mf, 'rsp' );
        my $callee_size   = scalar(@$used_callee) * 8;
        my $unified_frame = ( $callee_size + $spill_frame + 15 ) & ~15;
        my $extra_frame   = $unified_frame - $callee_size;
        my $is_leaf       = 1;

        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                $is_leaf = 0 if $inst->opcode eq 'call_func';
            }
        }
        if ($is_leaf) {
            if ( $unified_frame > 0 ) {
                $bytes .= pack( 'CCCV', 0x48, 0x81, 0xC0 | ( 5 << 3 ) | 4, $unified_frame );
            }
            for my $i ( 0 .. $#$used_callee ) {
                my $reg = $used_callee->[$i];
                my $rid = $reg_id->($reg);
                my $off = $spill_frame + $i * 8;
                my $rex = 0x48 | ( $rid >= 8 ? 4 : 0 );
                $bytes .= pack( 'C', $rex ) . pack( 'CCCV', 0x89, ( 2 << 6 ) | ( ( $rid & 7 ) << 3 ) | 4, 0x24, $off );
            }
        }
        else {
            for my $reg ( $used_callee->@* ) {
                my $rid = $reg_id->($reg);
                if ( $rid < 8 ) { $bytes .= pack( 'C', PUSH_BASE + $rid ) }
                else            { $bytes .= pack( 'CC', 0x41, PUSH_BASE + ( $rid - 8 ) ) }
            }
            if ( $extra_frame > 0 ) {
                $bytes .= pack( 'CCCV', 0x48, 0x81, 0xC0 | ( 5 << 3 ) | 4, $extra_frame );
            }
        }
        my $resolve = sub ($op) {
            return $assignment->{ $op->value } // $op->value if $op->kind eq 'virt_reg';
            return $op->value                                if $op->kind eq 'phys_reg';
            die "Unexpected operand kind: ${\$op->kind}";
        };
        my %labels;
        my @fixups;
        my @func_fixups;
        my $current_offset = sub { return length $bytes };
        my $mem_modrm      = sub ( $mem_op, $reg_idx ) {
            my $addr   = $mem_op->value;
            my $base_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} ) );
            my $bid    = $reg_id->($base_r);
            my $disp   = $addr->{disp} // 0;
            if ( defined $addr->{index} ) {
                my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                my $iid     = $reg_id->($index_r);
                my $scale   = $addr->{scale} // 1;
                my $sibits  = ( $scale == 1 ) ? 0 : ( $scale == 2 ) ? 1 : ( $scale == 4 ) ? 2 : 3;
                my $sib_idx = $iid & 7;
                $sib_idx = 4 if $sib_idx == 4;
                my $sib_base = $bid & 7;
                my $sib      = ( $sibits << 6 ) | ( $sib_idx << 3 ) | $sib_base;
                my $mod;
                if    ( $disp == 0 && $sib_base != 5 )  { $mod = 0 }
                elsif ( $disp >= -128 && $disp <= 127 ) { $mod = 1 }
                else                                    { $mod = 2 }
                my $modrm = ( $mod << 6 ) | ( ( $reg_idx & 7 ) << 3 ) | 4;
                my @extra = ( pack( 'C', $sib ) );
                if    ( $mod == 1 ) { push @extra, pack( 'c', $disp ) }
                elsif ( $mod == 2 ) { push @extra, pack( 'V', $disp ) }
                my $rex_x = ( $iid >= 8 ) ? 2 : 0;
                my $rex_b = ( $bid >= 8 ) ? 1 : 0;
                return ( $modrm, \@extra, $rex_x, $rex_b );
            }
            my $rm = $bid & 7;
            my ( $mod, @extra );
            if ( $rm == 4 ) {
                if    ( $disp == 0 )                    { $mod = 0; @extra = ("\x24") }
                elsif ( $disp >= -128 && $disp <= 127 ) { $mod = 1; @extra = ( "\x24", pack( 'c', $disp ) ) }
                else                                    { $mod = 2; @extra = ( "\x24", pack( 'V', $disp ) ) }
            }
            elsif ( $disp == 0 && $rm != 5 ) {
                $mod = 0;
            }
            else {
                if   ( $disp >= -128 && $disp <= 127 ) { $mod = 1; @extra = ( pack( 'c', $disp ) ) }
                else                                   { $mod = 2; @extra = ( pack( 'V', $disp ) ) }
            }
            my $modrm = ( $mod << 6 ) | ( ( $reg_idx & 7 ) << 3 ) | $rm;
            my $rex_b = ( $bid >= 8 ) ? 1 : 0;
            return ( $modrm, \@extra, 0, $rex_b );
        };
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                my $opcode = $inst->opcode;
                my ( $dst, $src ) = $inst->operands->@*;
                if ( $opcode eq 'mov' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $bits  = $dst->type ? $dst->type->bits : 64;
                    if ( $src->kind eq 'imm' ) {
                        my $rex_w = ( $bits >= 64 ) ? REX_W : 0;
                        my $rex_b = $did >= 8       ? REX_B : 0;
                        if ( $rex_w && ( abs( $src->value ) > 0x7FFFFFFF ) ) {
                            $bytes .= pack( 'C', 0x48 | $rex_b ) . pack( 'C', MOV_EAX_IMM + ( $did & 7 ) ) . pack( 'Q', $src->value );
                        }
                        elsif ($rex_w) {
                            $bytes .= pack( 'CCC', 0x48 | $rex_b, MOV_IMM_RM, 0xC0 | ( $did & 7 ) );
                            $bytes .= pack( 'V', $src->value );
                        }
                        elsif ($rex_b) {
                            $bytes .= pack( 'CCV', 0x41, MOV_EAX_IMM + ( $did & 7 ), $src->value );
                        }
                        else {
                            $bytes .= pack( 'CV', MOV_EAX_IMM + $did, $src->value );
                        }
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $rex_w = ( $bits >= 64 ) ? REX_W : 0;
                        my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                        $bytes .= pack( 'CCC', $rex, MOV_RM_R, $modrm );
                    }
                }
                elsif ( $opcode eq 'add' ||
                    $opcode eq 'sub' ||
                    $opcode eq 'and' ||
                    $opcode eq 'or'  ||
                    $opcode eq 'xor' ||
                    $opcode eq 'adc' ||
                    $opcode eq 'sbb' ) {
                    my $dst_r   = $resolve->($dst);
                    my $did     = $reg_id->($dst_r);
                    my $bits    = $dst->type ? $dst->type->bits : 64;
                    my %imm_ext = ( add => 0,    sub => 5,    and => 4,    or => 1,    xor => 6,    adc => 2,    sbb => 3 );
                    my %reg_op  = ( add => 0x01, sub => 0x29, and => 0x21, or => 0x09, xor => 0x31, adc => 0x11, sbb => 0x19 );
                    my $rex_w   = ( $bits >= 64 ) ? REX_W : 0;
                    if ( $src->kind eq 'imm' ) {
                        my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                        my $ext   = $imm_ext{$opcode};
                        my $modrm = 0xC0 | ( $ext << 3 ) | ( $did & 7 );
                        $bytes .= pack( 'CCCV', $rex, ARITH_IMM, $modrm, $src->value );
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $rex   = 0x40 | $rex_w | ( $sid >= 8 ? 4 : 0 ) | ( $did >= 8 ? 1 : 0 );
                        my $op    = $reg_op{$opcode};
                        my $modrm = 0xC0 | ( ( $sid & 7 ) << 3 ) | ( $did & 7 );
                        $bytes .= pack( 'CCC', $rex, $op, $modrm );
                    }
                }
                elsif ( $opcode eq 'mul' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $bits  = $dst->type      ? $dst->type->bits : 64;
                    my $rex_w = ( $bits >= 64 ) ? REX_W            : 0;
                    if ( $src->kind eq 'imm' ) {

                        # imul dst, dst, imm32  => REX.W 69 /r
                        my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 ) | ( $did >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $did & 7 );
                        $bytes .= pack( 'CCCV', $rex, IMUL_IMM, $modrm, $src->value );
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );

                        # imul dst, src  => REX.W 0F AF /r
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                        $bytes .= pack( 'CCC', $rex, 0x0F, 0xAF ) . pack( 'C', $modrm );
                    }
                }
                elsif ( $opcode eq 'umulh' ) {
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $rex_w = REX_W;

                    # MOV RAX, dst  (RAX = dst, first operand)
                    my $rax_rex   = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 );
                    my $rax_modrm = 0xC0 | ( 0 << 3 ) | ( $did & 7 );
                    $bytes .= pack( 'CCC', $rax_rex, 0x8B, $rax_modrm );

                    # MUL src  (RDX:RAX = RAX * src; /4 = MUL opcode extension)
                    my $mul_rex   = 0x40 | $rex_w | ( $sid >= 8 ? 1 : 0 );
                    my $mul_modrm = 0xC0 | ( 4 << 3 ) | ( $sid & 7 );
                    $bytes .= pack( 'CCC', $mul_rex, 0xF7, $mul_modrm );

                    # MOV dst, RDX  (dst = high 64 bits)
                    my $rdx_rex   = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 );
                    my $rdx_modrm = 0xC0 | ( 2 << 3 ) | ( $did & 7 );
                    $bytes .= pack( 'CCC', $rdx_rex, 0x8B, $rdx_modrm );
                }
                elsif ( $opcode eq 'udiv' ) {
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $rex_w = REX_W;

                    # MOV RAX, dst  (RAX = low 64 bits of dividend)
                    my $rax_rex   = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 );
                    my $rax_modrm = 0xC0 | ( 0 << 3 ) | ( $did & 7 );
                    $bytes .= pack( 'CCC', $rax_rex, 0x8B, $rax_modrm );

                    # XOR RDX, RDX  (RDX = 0 = high 64 bits of dividend)
                    my $rdx_rex = 0x40 | $rex_w;
                    $bytes .= pack( 'CCC', $rdx_rex, 0x31, 0xD2 );

                    # DIV src  (RDX:RAX / src -> RAX = quotient, RDX = remainder; /6 = DIV)
                    my $div_rex   = 0x40 | $rex_w | ( $sid >= 8 ? 1 : 0 );
                    my $div_modrm = 0xC0 | ( 6 << 3 ) | ( $sid & 7 );
                    $bytes .= pack( 'CCC', $div_rex, 0xF7, $div_modrm );

                    # MOV dst, RAX  (dst = quotient)
                    my $mov_rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                    my $mov_modrm = 0xC0 | ( 0 << 3 ) | ( $did & 7 );
                    $bytes .= pack( 'CCC', $mov_rex, 0x89, $mov_modrm );
                }
                elsif ( $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' ) {
                    my $dst_r  = $resolve->($dst);
                    my $did    = $reg_id->($dst_r);
                    my $bits   = $dst->type ? $dst->type->bits : 64;
                    my %ext    = ( shl => 4, lshr => 5, ashr => 7 );
                    my $rex_w  = ( $bits >= 64 ) ? REX_W : 0;
                    my $rex    = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                    my $extval = $ext{$opcode};
                    if ( $src->kind eq 'imm' ) {

                        # shift by imm8: REX.W C1 /ext ib
                        my $modrm = 0xC0 | ( $extval << 3 ) | ( $did & 7 );
                        $bytes .= pack( 'CCCC', $rex, SHIFT_IMM, $modrm, $src->value );
                    }
                    else {
                        # shift by CL: REX.W D3 /ext rm
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        if ( $sid != 1 ) {
                            my $mrex   = 0x40 | ( $sid >= 8 ? 1 : 0 );
                            my $mmodrm = 0xC0 | ( 1 << 3 ) | ( $sid & 7 );
                            $bytes .= pack( 'CCC', $mrex, 0x8B, $mmodrm );
                        }
                        my $smodrm = 0xC0 | ( $extval << 3 ) | ( $did & 7 );
                        $bytes .= pack( 'CCC', $rex, 0xD3, $smodrm );
                    }
                }
                elsif ( $opcode eq 'alloca' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $size  = $src->value;
                    $alloca_frame += $size;

                    # sub rsp, size  (48 81 EC <size32>) -- rsp is always 64-bit
                    my $rex   = 0x48;
                    my $modrm = 0xC0 | ( 5 << 3 ) | 4;    # /5 = sub, r/m = rsp
                    $bytes .= pack( 'CCCV', $rex, ARITH_IMM, $modrm, $size );

                    # mov dst, rsp  (48 8B <modrm>) -- rsp is always 64-bit
                    my $rex2 = 0x48 | ( $did >= 8 ? 4 : 0 );
                    my $mr2  = 0xC0 | ( ( $did & 7 ) << 3 ) | 4;
                    $bytes .= pack( 'CCC', $rex2, MOV_RM_R, $mr2 );
                }
                elsif ( $opcode eq 'lea' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $src, $did );
                    my $rex = 0x48 | $rex_x | $rex_b | ( $did >= 8 ? 4 : 0 );
                    $bytes .= pack( 'C', $rex ) . pack( 'C', 0x8D ) . pack( 'C', $modrm );
                    $bytes .= join '', $extra->@*;
                }
                elsif ( $opcode eq 'load' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $src, $did );
                    my $bits = ( $dst->type && $dst->type->kind eq 'int' ) ? $dst->type->bits : 64;
                    my $rex  = ( $bits == 64 ? 0x48 : 0 ) | $rex_x | $rex_b | ( $did >= 8 ? 4 : 0 );
                    if ($rex) { $bytes .= pack( 'C', $rex ) }
                    $bytes .= pack( 'C', MOV_RM_R ) . pack( 'C', $modrm );
                    $bytes .= join '', $extra->@*;
                }
                elsif ( $opcode eq 'store' ) {
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $dst, $sid );
                    my $bits = ( $src->type && $src->type->kind eq 'int' ) ? $src->type->bits : 64;
                    my $rex  = ( $bits == 64 ? 0x48 : 0 ) | $rex_x | $rex_b | ( $sid >= 8 ? 4 : 0 );
                    if ($rex) { $bytes .= pack( 'C', $rex ) }
                    $bytes .= pack( 'C', MOV_R_RM ) . pack( 'C', $modrm );
                    $bytes .= join '', $extra->@*;
                }
                elsif ( $opcode eq 'store_imm' ) {
                    my ( $mem, $imm ) = $inst->operands->@*;
                    my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $mem, 0 );    # /0 ext = mov
                    my $bits = ( $imm->type && $imm->type->kind eq 'int' ) ? $imm->type->bits : 64;
                    my $rex  = ( $bits == 64 ? 0x48 : 0 ) | $rex_x | $rex_b;
                    if ($rex) { $bytes .= pack( 'C', $rex ) }
                    $bytes .= pack( 'C', MOV_IMM_RM ) . pack( 'C', $modrm );
                    $bytes .= join '', $extra->@*;
                    $bytes .= pack( 'V', $imm->value );
                }

                # SSE float opcodes
                elsif ( $opcode eq 'fload' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $src, $did );
                    my $bits = $dst->type  ? $dst->type->bits     : 32;
                    my $op   = $bits >= 64 ? [ 0xF2, 0x0F, 0x10 ] : [ 0xF3, 0x0F, 0x10 ];
                    my $rex  = 0x40 | $rex_x | $rex_b | ( $did >= 8 ? 4 : 0 );
                    if ( $rex > 0x40 ) { $bytes .= pack( 'C', $rex ) }
                    $bytes .= pack( 'CCC', $op->@* ) . pack( 'C', $modrm );
                    $bytes .= join '', $extra->@*;
                }
                elsif ( $opcode eq 'fstore' ) {
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $dst, $sid );
                    my $bits = $src->type  ? $src->type->bits     : 32;
                    my $op   = $bits >= 64 ? [ 0xF2, 0x0F, 0x11 ] : [ 0xF3, 0x0F, 0x11 ];
                    my $rex  = 0x40 | $rex_x | $rex_b | ( $sid >= 8 ? 4 : 0 );
                    if ( $rex > 0x40 ) { $bytes .= pack( 'C', $rex ) }
                    $bytes .= pack( 'CCC', $op->@* ) . pack( 'C', $modrm );
                    $bytes .= join '', $extra->@*;
                }
                elsif ( $opcode eq 'fmov' ) {
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type  ? $dst->type->bits     : 32;
                    my $op    = $bits >= 64 ? [ 0xF2, 0x0F, 0x10 ] : [ 0xF3, 0x0F, 0x10 ];
                    my $rex   = 0x40 | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                    $bytes .= pack( 'CCCC', $rex, $op->[0], $op->[1], $op->[2] ) . pack( 'C', $modrm );
                }
                elsif ( $opcode eq 'fmov_gp2f' ) {
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type  ? $dst->type->bits : 32;
                    my $rex   = $bits >= 64 ? 0x48             : 0x40;
                    $rex |= ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                    $bytes .= pack( 'C', $rex ) if $rex > 0x40;
                    $bytes .= pack( 'CCC', 0x66, 0x0F, 0x6E ) . pack( 'C', $modrm );
                }
                elsif ( $opcode eq 'fadd' ||
                    $opcode eq 'fsub'  ||
                    $opcode eq 'fmul'  ||
                    $opcode eq 'fdiv'  ||
                    $opcode eq 'fsqrt' ||
                    $opcode eq 'fmin'  ||
                    $opcode eq 'fmax' ) {
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type ? $dst->type->bits : 32;
                    my %ss_op = ( fadd => 0x58, fsub => 0x5C, fmul => 0x59, fdiv => 0x5E, fsqrt => 0x51, fmin => 0x5D, fmax => 0x5F );
                    my $op    = $bits >= 64 ? [ 0xF2, 0x0F, $ss_op{$opcode} ] : [ 0xF3, 0x0F, $ss_op{$opcode} ];
                    my $rex   = 0x40 | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                    $bytes .= pack( 'CCCC', $rex, $op->[0], $op->[1], $op->[2] ) . pack( 'C', $modrm );
                }
                elsif ( $opcode eq 'fxor' || $opcode eq 'fand' ) {
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type ? $dst->type->bits : 32;
                    my %ss_op = ( fxor => 0x57, fand => 0x54 );
                    my $op    = $bits >= 64 ? [ 0x66, 0x0F, $ss_op{$opcode} ] : [ 0x0F, $ss_op{$opcode} ];
                    my $rex   = 0x40 | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );

                    if ( $bits >= 64 ) {
                        $bytes .= pack( 'CCCC', $rex, $op->[0], $op->[1], $op->[2] ) . pack( 'C', $modrm );
                    }
                    else {
                        $bytes .= pack( 'CCC', $rex, $op->[0], $op->[1] ) . pack( 'C', $modrm );
                    }
                }
                elsif ( $opcode eq 'fcmp' ) {
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type  ? $dst->type->bits     : 32;
                    my $op    = $bits >= 64 ? [ 0x66, 0x0F, 0x2E ] : [ 0x0F, 0x2E ];
                    my $rex   = 0x40 | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                    $bytes .= pack( 'C' x ( $bits >= 64 ? 4 : 3 ), $rex, $op->@* ) . pack( 'C', $modrm );
                }
                elsif ( $opcode eq 'label' ) {
                    $labels{ $dst->value } = $current_offset->();
                }
                elsif ( $opcode eq 'jmp' ) {
                    push @fixups, { offset => $current_offset->(), type => 'jmp_rel32', target => $dst->value, size => 5 };
                    $bytes .= pack( 'C', JMP_REL32 ) . "\x00\x00\x00\x00";
                }
                elsif ( $opcode eq 'beq' || $opcode eq 'bne' ) {
                    my $cond_r = $resolve->($dst);
                    my $cid    = $reg_id->($cond_r);

                    # cmp reg, 0: REX.W 83 /7 0  (4 bytes)
                    my $rex   = 0x48 | ( $cid >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( 7 << 3 ) | ( $cid & 7 );
                    $bytes .= pack( 'CCCC', $rex, CMP_IMM8, $modrm, 0 );
                    my $jcc = ( $opcode eq 'beq' ? JE : JNE );
                    push @fixups, { offset => $current_offset->(), type => 'jcc_rel32', jcc => $jcc, target => $src->value, size => 6 };
                    $bytes .= pack( 'CC', 0x0F, $jcc ) . "\x00\x00\x00\x00";
                }
                elsif ( $opcode eq 'cmp' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $bits  = $dst->type      ? $dst->type->bits : 64;
                    my $rex_w = ( $bits >= 64 ) ? REX_W            : 0;
                    if ( $src->kind eq 'imm' ) {
                        my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( 7 << 3 ) | ( $did & 7 );
                        $bytes .= pack( 'CCCV', $rex, ARITH_IMM, $modrm, $src->value );
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                        $bytes .= pack( 'CCC', $rex, 0x3B, $modrm );
                    }
                }
                elsif ( $opcode eq 'sete' ||
                    $opcode eq 'setne' ||
                    $opcode eq 'setl'  ||
                    $opcode eq 'setg'  ||
                    $opcode eq 'setle' ||
                    $opcode eq 'setge' ||
                    $opcode eq 'setb'  ||
                    $opcode eq 'seta'  ||
                    $opcode eq 'setbe' ||
                    $opcode eq 'setae' ||
                    $opcode eq 'setp'  ||
                    $opcode eq 'setnp' ) {
                    my %cc = (
                        sete  => 0x94,
                        setne => 0x95,
                        setl  => 0x9C,
                        setg  => 0x9F,
                        setle => 0x9E,
                        setge => 0x9D,
                        setb  => 0x92,
                        seta  => 0x97,
                        setbe => 0x96,
                        setae => 0x93,
                        setp  => 0x9A,
                        setnp => 0x9B
                    );
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $rex   = 0x40 | ( $did >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( $did & 7 );
                    $bytes .= pack( 'CCC', $rex, 0x0F, $cc{$opcode} ) . pack( 'C', $modrm );
                }
                elsif ( $opcode eq 'call_func' ) {
                    my $func_name = $dst->value;
                    push @func_fixups, { offset => $current_offset->(), type => 'call_rel32', target => $func_name };
                    $bytes .= pack( 'C', 0xE8 ) . "\x00\x00\x00\x00";
                }
                elsif ( $opcode eq 'ret' ) {
                    if ($is_leaf) {
                        for my $i ( reverse 0 .. $#$used_callee ) {
                            my $reg = $used_callee->[$i];
                            my $rid = $reg_id->($reg);
                            my $off = $spill_frame + $alloca_frame + $i * 8;
                            my $rex = 0x48 | ( $rid >= 8 ? 4 : 0 );
                            $bytes .= pack( 'C', $rex ) . pack( 'CCCV', 0x8B, ( 2 << 6 ) | ( ( $rid & 7 ) << 3 ) | 4, 0x24, $off );
                        }
                        my $cleanup = $unified_frame + $alloca_frame;
                        if ( $cleanup > 0 ) {
                            $bytes .= pack( 'CCCV', 0x48, 0x81, 0xC0 | ( 0 << 3 ) | 4, $cleanup );
                        }
                    }
                    else {
                        my $cleanup = $alloca_frame + $extra_frame;
                        if ( $cleanup > 0 ) {
                            $bytes .= pack( 'CCCV', 0x48, 0x81, 0xC0 | ( 0 << 3 ) | 4, $cleanup );
                        }
                        for my $reg ( reverse $used_callee->@* ) {
                            my $rid = $reg_id->($reg);
                            if ( $rid < 8 ) { $bytes .= pack( 'C', POP_BASE + $rid ) }
                            else            { $bytes .= pack( 'CC', 0x41, POP_BASE + ( $rid - 8 ) ) }
                        }
                    }
                    $bytes .= pack( 'C', RET_BYTE );
                }
            }
        }
        for my $fixup (@fixups) {
            my $target_pos = $labels{ $fixup->{target} };
            die "undefined label: $fixup->{target}" unless defined $target_pos;
            my $src_pos = $fixup->{offset};
            my $rel     = $target_pos - ( $src_pos + $fixup->{size} );
            if ( $fixup->{type} eq 'jmp_rel32' ) {
                substr $bytes, $fixup->{offset} + 1, 4, pack( 'V', $rel & 0xFFFFFFFF );
            }
            elsif ( $fixup->{type} eq 'jcc_rel32' ) {
                substr $bytes, $fixup->{offset} + 2, 4, pack( 'V', $rel & 0xFFFFFFFF );
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
