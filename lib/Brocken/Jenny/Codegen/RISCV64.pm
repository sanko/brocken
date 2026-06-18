use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use List::Util ();
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Lowerer::RISCV64;
use Brocken::Jenny::RegAlloc;
use Brocken::Jenny::MIR;

class Brocken::Jenny::Codegen::RISCV64 {
    field $platform : param = Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu');
    use constant {
        JAL     => 0x0000006F,
        JALR    => 0x00008067,
        SRAI_B  => 0x40000000,
        FSGNJ   => 0x20000000,
        FMINMAX => 0x28000000,
        FSQRT   => 0x58000000,
        FMV_W_X => 0xF0000000,
        FMV_D_X => 0xF2000000,
        FP_FMT  => 0x02000000,
        OP_IMM  => 0x13,
        OP      => 0x33,
        LOAD    => 0x03,
        STORE   => 0x23,
        FLOAD   => 0x07,
        FSTORE  => 0x27,
        FP_OP   => 0x53,
        BCC     => 0x63,
        LUI     => 0x37
    };

    method emit_function($ir_func) {
        my $lowerer = Brocken::Jenny::Lowerer::RISCV64->new();
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
        $alloc->insert_caller_save_code( $mf, \@fp_caller, $platform->stack_reg, 1, scalar(@gp_caller) );
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
            my $lowerer = Brocken::Jenny::Lowerer::RISCV64->new();
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
            $alloc->insert_caller_save_code( $mf, \@fp_caller, $platform->stack_reg, 1, scalar(@gp_caller) );
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
            push @to_save, 'ra';
        }
        my $callee_size   = scalar(@to_save) * 8;
        my $unified_frame = ( $callee_size + $spill_frame + 15 ) & ~15;
        my $extra_frame   = $unified_frame - $callee_size;
        my $reg_id        = sub ($r) {
            my %map = (
                zero => 0,
                ra   => 1,
                sp   => 2,
                gp   => 3,
                tp   => 4,
                t0   => 5,
                t1   => 6,
                t2   => 7,
                s0   => 8,
                fp   => 8,
                s1   => 9,
                a0   => 10,
                a1   => 11,
                a2   => 12,
                a3   => 13,
                a4   => 14,
                a5   => 15,
                a6   => 16,
                a7   => 17,
                s2   => 18,
                s3   => 19,
                s4   => 20,
                s5   => 21,
                s6   => 22,
                s7   => 23,
                s8   => 24,
                s9   => 25,
                s10  => 26,
                s11  => 27,
                t3   => 28,
                t4   => 29,
                t5   => 30,
                t6   => 31
            );
            return $map{$r} if exists $map{$r};
            return $1       if $r =~ /^x(\d+)$/;
            return $1       if $r =~ /^f(\d+)$/ && $1 <= 31;
            return 0;
        };
        my $resolve = sub ($op) {
            return $assignment->{ $op->value } // $op->value if $op->kind eq 'virt_reg';
            return $op->value                                if $op->kind eq 'phys_reg';
            die "Unexpected operand kind: ${\$op->kind}";
        };
        if ( $unified_frame > 0 ) {
            my $neg = ( -$unified_frame ) & 0xFFF;
            $bytes .= pack( 'V', ( $neg << 20 ) | ( 2 << 15 ) | ( 0 << 12 ) | ( 2 << 7 ) | OP_IMM );
            for my $i ( 0 .. $#to_save ) {
                my $reg      = $to_save[$i];
                my $rid      = $reg_id->($reg);
                my $off      = $i * 8;
                my $imm_lo   = $off & 0x1F;
                my $imm_hi   = ( $off >> 5 ) & 0x7F;
                my $store_op = $reg =~ /^f/ ? FSTORE : STORE;
                $bytes .= pack( 'V', ( $imm_hi << 25 ) | ( $rid << 20 ) | ( 2 << 15 ) | ( 3 << 12 ) | ( $imm_lo << 7 ) | $store_op );
            }
        }
        my %labels;
        my @fixups;
        my @func_fixups;
        my $current_offset = sub { return length $bytes };
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                my $opcode = $inst->opcode;
                my @ops    = $inst->operands->@*;
                my ( $dst, $src ) = @ops;
                if ( $opcode eq 'label' ) {
                    $labels{ $dst->value } = $current_offset->();
                }
                elsif ( $opcode eq 'jmp' ) {
                    push @fixups, { offset => $current_offset->(), type => 'jal', target => $dst->value };
                    $bytes .= pack( 'V', JAL );
                }
                elsif ( $opcode eq 'beq' || $opcode eq 'bne' ) {
                    my $cond_r = $resolve->($dst);
                    my $cid    = $reg_id->($cond_r);
                    my $funct3 = ( $opcode eq 'bne' ? 1 : 0 );

                    # BEQ/BNE rs1=cond, rs2=x0, offset placeholder
                    push @fixups, { offset => $current_offset->(), type => 'bcc', target => $src->value, rs1 => $cid, funct3 => $funct3 };
                    $bytes .= pack( 'V', ( $cid << 15 ) | ( $funct3 << 12 ) | BCC );
                }
                elsif ( $opcode eq 'mov' || $opcode eq 'mv' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    if ( $src->kind eq 'imm' ) {
                        my $val = $src->value;
                        if ( $val >= -2048 && $val <= 2047 ) {

                            # li rd, imm (addi rd, zero, imm)
                            my $imm = $val & 0xFFF;
                            $bytes .= pack( 'V', ( $imm << 20 ) | ( 0 << 15 ) | ( 0 << 12 ) | ( $did << 7 ) | OP_IMM );
                        }
                        else {
                            # 32-bit immediate: lui + addi
                            my $hi = ( $val + 0x800 ) >> 12;
                            my $lo = $val & 0xFFF;
                            $bytes .= pack( 'V', ( ( $hi & 0xFFFFF ) << 12 ) | ( $did << 7 ) | LUI );
                            $bytes .= pack( 'V', ( ( $lo & 0xFFF ) << 20 ) | ( $did << 15 ) | ( 0 << 12 ) | ( $did << 7 ) | OP_IMM );
                        }
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);

                        # mv rd, rs (addi rd, rs, 0)
                        $bytes .= pack( 'V', ( 0 << 20 ) | ( $sid << 15 ) | ( 0 << 12 ) | ( $did << 7 ) | OP_IMM );
                    }
                }
                elsif ( $opcode eq 'add' ||
                    $opcode eq 'sub'   ||
                    $opcode eq 'and'   ||
                    $opcode eq 'or'    ||
                    $opcode eq 'xor'   ||
                    $opcode eq 'mul'   ||
                    $opcode eq 'mulhu' ||
                    $opcode eq 'div'   ||
                    $opcode eq 'divu'  ||
                    $opcode eq 'slt'   ||
                    $opcode eq 'sltu'  ||
                    $opcode eq 'sltiu' ) {
                    my $dst_r  = $resolve->($dst);
                    my $did    = $reg_id->($dst_r);
                    my %imm_f3 = ( add => 0, sub => 0, and => 7, or => 6, xor => 4, slt => 2, sltu => 3, sltiu => 3 );
                    my %reg_f7 = (
                        add   => 0x00,
                        sub   => 0x20,
                        mul   => 0x01,
                        mulhu => 0x01,
                        div   => 0x01,
                        divu  => 0x01,
                        and   => 0x00,
                        or    => 0x00,
                        xor   => 0x00,
                        slt   => 0x00,
                        sltu  => 0x00
                    );
                    my %reg_f3 = (
                        add   => 0,
                        sub   => 0,
                        mul   => 0,
                        mulhu => 3,
                        div   => 0,
                        divu  => 1,
                        and   => 7,
                        or    => 6,
                        xor   => 4,
                        slt   => 2,
                        sltu  => 3,
                        sltiu => 3
                    );
                    if ( $src->kind eq 'imm' && exists $imm_f3{$opcode} ) {

                        # I-type: opcode 0x13, funct3 from %imm_f3
                        my $imm = $src->value;
                        $imm = -$imm if $opcode eq 'sub';
                        $imm &= 0xFFF;
                        $bytes .= pack( 'V', ( $imm << 20 ) | ( $did << 15 ) | ( $imm_f3{$opcode} << 12 ) | ( $did << 7 ) | OP_IMM );
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        $bytes .= pack( 'V',
                            ( $reg_f7{$opcode} << 25 ) | ( $sid << 20 ) | ( $did << 15 ) | ( $reg_f3{$opcode} << 12 ) | ( $did << 7 ) | OP );
                    }
                }
                elsif ( $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    if ( $src->kind eq 'imm' ) {

                        # I-type shift: SLLI/SRLI/SRAI, funct3=1/5/5, opcode=0x13
                        my $shamt = $src->value;
                        my %f3    = ( shl => 1, lshr => 5, ashr => 5 );
                        my $extra = ( $opcode eq 'ashr' ? SRAI_B : 0x00000000 );
                        $bytes .= pack( 'V', $extra | ( $shamt << 20 ) | ( $did << 15 ) | ( $f3{$opcode} << 12 ) | ( $did << 7 ) | OP_IMM );
                    }
                    else {
                        # R-type shift: SLL/SRL/SRA, funct7=0x00/0x00/0x20, funct3=1/5/5
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my %f3    = ( shl => 1,    lshr => 5,    ashr => 5 );
                        my %f7    = ( shl => 0x00, lshr => 0x00, ashr => 0x20 );
                        $bytes .= pack( 'V', ( $f7{$opcode} << 25 ) | ( $sid << 20 ) | ( $did << 15 ) | ( $f3{$opcode} << 12 ) | ( $did << 7 ) | OP );
                    }
                }
                elsif ( $opcode eq 'alloca' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $size  = $src->value;
                    $alloca_frame += $size;

                    # addi sp, sp, -size
                    my $neg_size = ( -$size ) & 0xFFF;
                    $bytes .= pack( 'V', ( $neg_size << 20 ) | ( 2 << 15 ) | ( 0 << 12 ) | ( 2 << 7 ) | OP_IMM );

                    # addi xd, sp, 0
                    $bytes .= pack( 'V', ( 0 << 20 ) | ( 2 << 15 ) | ( 0 << 12 ) | ( $did << 7 ) | OP_IMM );
                }
                elsif ( $opcode eq 'load' ) {
                    my $dst_r  = $resolve->($dst);
                    my $did    = $reg_id->($dst_r);
                    my $addr   = $src->value;
                    my $base_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} ) );
                    my $bid    = $reg_id->($base_r);
                    my $bits   = ( $dst->type && $dst->type->kind eq 'int' ) ? $dst->type->bits : 64;
                    my $funct3 = $bits == 32                                 ? 2                : 3;
                    if ( defined $addr->{index} ) {
                        my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid     = $reg_id->($index_r);
                        my %used;
                        @used{ values %$assignment } = ();
                        my $tmp_r;
                        for my $r ( $platform->registers('caller')->@* ) { $tmp_r = $r, last unless exists $used{$r} }
                        die 'no temp register for indexed load' unless $tmp_r;
                        my $tid = $reg_id->($tmp_r);
                        $bytes .= pack( 'V', ( $iid << 20 ) | ( $bid << 15 ) | ( 0 << 12 ) | ( $tid << 7 ) | OP );
                        my $disp = $addr->{disp} // 0;
                        $bytes .= pack( 'V', ( ( $disp & 0xFFF ) << 20 ) | ( $tid << 15 ) | ( $funct3 << 12 ) | ( $did << 7 ) | LOAD );
                    }
                    else {
                        my $disp = $addr->{disp} // 0;
                        $bytes .= pack( 'V', ( ( $disp & 0xFFF ) << 20 ) | ( $bid << 15 ) | ( $funct3 << 12 ) | ( $did << 7 ) | LOAD );
                    }
                }
                elsif ( $opcode eq 'store' ) {
                    my $src_r  = $resolve->($src);
                    my $sid    = $reg_id->($src_r);
                    my $addr   = $dst->value;
                    my $base_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} ) );
                    my $bid    = $reg_id->($base_r);
                    my $bits   = ( $src->type && $src->type->kind eq 'int' ) ? $src->type->bits : 64;
                    my $funct3 = $bits == 32                                 ? 2                : 3;
                    if ( defined $addr->{index} ) {
                        my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid     = $reg_id->($index_r);
                        my %used;
                        @used{ values %$assignment } = ();
                        my $tmp_r;
                        for my $r ( $platform->registers('caller')->@* ) { $tmp_r = $r, last unless exists $used{$r} }
                        die 'no temp register for indexed store' unless $tmp_r;
                        my $tid = $reg_id->($tmp_r);
                        $bytes .= pack( 'V', ( $iid << 20 ) | ( $bid << 15 ) | ( 0 << 12 ) | ( $tid << 7 ) | OP );
                        my $disp   = $addr->{disp} // 0;
                        my $imm_lo = $disp & 0x1F;
                        my $imm_hi = ( $disp >> 5 ) & 0x7F;
                        $bytes .= pack( 'V', ( $imm_hi << 25 ) | ( $sid << 20 ) | ( $tid << 15 ) | ( $funct3 << 12 ) | ( $imm_lo << 7 ) | STORE );
                    }
                    else {
                        my $disp   = $addr->{disp} // 0;
                        my $imm_lo = $disp & 0x1F;
                        my $imm_hi = ( $disp >> 5 ) & 0x7F;
                        $bytes .= pack( 'V', ( $imm_hi << 25 ) | ( $sid << 20 ) | ( $bid << 15 ) | ( $funct3 << 12 ) | ( $imm_lo << 7 ) | STORE );
                    }
                }
                elsif ( $opcode eq 'store_imm' ) {
                    my ( $mem, $imm ) = $inst->operands->@*;
                    my $addr   = $mem->value;
                    my $base_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} ) );
                    my $bid    = $reg_id->($base_r);
                    my $bits   = ( $imm->type && $imm->type->kind eq 'int' ) ? $imm->type->bits : 64;
                    my $funct3 = $bits == 32                                 ? 2                : 3;

                    # find a temporary register not in use
                    my %used;
                    @used{ values %$assignment } = ();
                    my $tmp_r;
                    for my $r ( $platform->registers('caller')->@* ) { $tmp_r = $r, last unless exists $used{$r} }
                    die 'no temp register for store_imm' unless $tmp_r;
                    my $tid = $reg_id->($tmp_r);

                    # li xtmp, imm  (addi xtmp, zero, imm12)
                    my $im = $imm->value & 0xFFF;
                    $bytes .= pack( 'V', ( $im << 20 ) | ( 0 << 15 ) | ( 0 << 12 ) | ( $tid << 7 ) | OP_IMM );
                    my $store_bid = $bid;
                    if ( defined $addr->{index} ) {
                        my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid     = $reg_id->($index_r);
                        my $tmp2    = $tid;
                        my %used2;
                        @used2{ values %$assignment } = ();
                        $used2{$tmp_r} = 1;
                        for my $r ( $platform->registers('caller')->@* ) { $tmp2 = $r, last unless exists $used2{$r} }
                        die 'no temp register for indexed store_imm' unless $tmp2;
                        my $tid2 = $reg_id->($tmp2);
                        $bytes .= pack( 'V', ( $iid << 20 ) | ( $bid << 15 ) | ( 0 << 12 ) | ( $tid2 << 7 ) | OP );
                        $store_bid = $tid2;
                    }
                    my $disp   = $addr->{disp} // 0;
                    my $imm_lo = $disp & 0x1F;
                    my $imm_hi = ( $disp >> 5 ) & 0x7F;
                    $bytes .= pack( 'V', ( $imm_hi << 25 ) | ( $tid << 20 ) | ( $store_bid << 15 ) | ( $funct3 << 12 ) | ( $imm_lo << 7 ) | STORE );
                }
                elsif ( $opcode eq 'fload' ) {
                    my $dst_r  = $resolve->($dst);
                    my $did    = $reg_id->($dst_r);
                    my $addr   = $src->value;
                    my $base_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} ) );
                    my $bid    = $reg_id->($base_r);
                    my $funct3 = ( $dst->type && $dst->type->bits <= 32 ) ? 2 : 3;
                    if ( defined $addr->{index} ) {
                        my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid     = $reg_id->($index_r);
                        my %used;
                        @used{ values %$assignment } = ();
                        my $tmp_r;
                        for my $r ( $platform->registers('caller')->@* ) { $tmp_r = $r, last unless exists $used{$r} }
                        die 'no temp register for indexed fload' unless $tmp_r;
                        my $tid = $reg_id->($tmp_r);
                        $bytes .= pack( 'V', ( $iid << 20 ) | ( $bid << 15 ) | ( 0 << 12 ) | ( $tid << 7 ) | OP );
                        my $disp = $addr->{disp} // 0;
                        $bytes .= pack( 'V', ( ( $disp & 0xFFF ) << 20 ) | ( $tid << 15 ) | ( $funct3 << 12 ) | ( $did << 7 ) | FLOAD );
                    }
                    else {
                        my $disp = $addr->{disp} // 0;
                        $bytes .= pack( 'V', ( ( $disp & 0xFFF ) << 20 ) | ( $bid << 15 ) | ( $funct3 << 12 ) | ( $did << 7 ) | FLOAD );
                    }
                }
                elsif ( $opcode eq 'fstore' ) {
                    my $src_r  = $resolve->($src);
                    my $sid    = $reg_id->($src_r);
                    my $addr   = $dst->value;
                    my $base_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} ) );
                    my $bid    = $reg_id->($base_r);
                    my $funct3 = ( $src->type && $src->type->bits <= 32 ) ? 2 : 3;
                    if ( defined $addr->{index} ) {
                        my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid     = $reg_id->($index_r);
                        my %used;
                        @used{ values %$assignment } = ();
                        my $tmp_r;
                        for my $r ( $platform->registers('caller')->@* ) { $tmp_r = $r, last unless exists $used{$r} }
                        die 'no temp register for indexed fstore' unless $tmp_r;
                        my $tid = $reg_id->($tmp_r);
                        $bytes .= pack( 'V', ( $iid << 20 ) | ( $bid << 15 ) | ( 0 << 12 ) | ( $tid << 7 ) | OP );
                        my $disp   = $addr->{disp} // 0;
                        my $imm_lo = $disp & 0x1F;
                        my $imm_hi = ( $disp >> 5 ) & 0x7F;
                        $bytes .= pack( 'V', ( $imm_hi << 25 ) | ( $sid << 20 ) | ( $tid << 15 ) | ( $funct3 << 12 ) | ( $imm_lo << 7 ) | FSTORE );
                    }
                    else {
                        my $disp   = $addr->{disp} // 0;
                        my $imm_lo = $disp & 0x1F;
                        my $imm_hi = ( $disp >> 5 ) & 0x7F;
                        $bytes .= pack( 'V', ( $imm_hi << 25 ) | ( $sid << 20 ) | ( $bid << 15 ) | ( $funct3 << 12 ) | ( $imm_lo << 7 ) | FSTORE );
                    }
                }
                elsif ( $opcode eq 'fmov' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type ? $dst->type->bits : 64;
                    if ( $bits <= 32 ) {
                        $bytes .= pack( 'V', FSGNJ | ( $sid << 20 ) | ( $sid << 15 ) | ( $did << 7 ) | FP_OP );
                    }
                    else {
                        $bytes .= pack( 'V', FSGNJ | FP_FMT | ( $sid << 20 ) | ( $sid << 15 ) | ( $did << 7 ) | FP_OP );
                    }
                }
                elsif ( $opcode eq 'fmov_gp2f' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type ? $dst->type->bits : 64;
                    if ( $bits <= 32 ) {
                        $bytes .= pack( 'V', FMV_W_X | ( $sid << 15 ) | ( $did << 7 ) | FP_OP );
                    }
                    else {
                        $bytes .= pack( 'V', FMV_D_X | ( $sid << 15 ) | ( $did << 7 ) | FP_OP );
                    }
                }
                elsif ( $opcode eq 'fcmp' ) {
                    my ( $result, $lhs, $rhs ) = $inst->operands->@*;
                    my $rd   = $reg_id->( $resolve->($result) );
                    my $rs1  = $reg_id->( $resolve->($lhs) );
                    my $rs2  = $reg_id->( $resolve->($rhs) );
                    my $bits = $lhs->type ? $lhs->type->bits : 64;
                    my $pred = ( $inst->comment =~ /fcmp (\w+)/ ? $1 : 'eq' );
                    my $fmt  = $bits > 32 ? 1 : 0;
                    if ( $pred eq 'gt' || $pred eq 'ge' ) { ( $rs1, $rs2 ) = ( $rs2, $rs1 ) }
                    my $funct5 = 0x14;
                    my $funct3 = $pred eq 'eq' || $pred eq 'ne' ? 2 : ( $pred eq 'lt' || $pred eq 'gt' ? 1 : 0 );
                    my $enc    = ( $funct5 << 27 ) | ( $fmt << 25 ) | ( $rs2 << 20 ) | ( $rs1 << 15 ) | ( $funct3 << 12 ) | ( $rd << 7 ) | FP_OP;
                    $bytes .= pack( 'V', $enc );
                    if ( $pred eq 'ne' ) { $bytes .= pack( 'V', ( 1 << 20 ) | ( $rd << 15 ) | ( 4 << 12 ) | ( $rd << 7 ) | OP_IMM ) }
                }
                elsif ( $opcode eq 'fadd' || $opcode eq 'fsub' || $opcode eq 'fmul' || $opcode eq 'fdiv' ) {
                    my $dst_r  = $resolve->($dst);
                    my $did    = $reg_id->($dst_r);
                    my $src_r  = $resolve->($src);
                    my $sid    = $reg_id->($src_r);
                    my $bits   = $dst->type ? $dst->type->bits : 64;
                    my %fop5   = ( fadd => 0x00, fsub => 0x01, fmul => 0x02, fdiv => 0x03 );
                    my $funct5 = $fop5{$opcode};
                    my $enc    = ( $funct5 << 27 ) | ( $sid << 20 ) | ( $did << 15 ) | ( $did << 7 ) | FP_OP;
                    $enc |= FP_FMT if $bits > 32;
                    $bytes .= pack( 'V', $enc );
                }
                elsif ( $opcode eq 'fneg' || $opcode eq 'fabs' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type        ? $dst->type->bits : 64;
                    my $rm    = $opcode eq 'fneg' ? 1                : 2;
                    my $enc   = FSGNJ | ( $sid << 20 ) | ( $sid << 15 ) | ( $rm << 12 ) | ( $did << 7 ) | FP_OP;
                    $enc |= FP_FMT if $bits > 32;
                    $bytes .= pack( 'V', $enc );
                }
                elsif ( $opcode eq 'fmin' || $opcode eq 'fmax' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type        ? $dst->type->bits : 64;
                    my $rm    = $opcode eq 'fmin' ? 0                : 1;
                    my $enc   = FMINMAX | ( $sid << 20 ) | ( $did << 15 ) | ( $rm << 12 ) | ( $did << 7 ) | FP_OP;
                    $enc |= FP_FMT if $bits > 32;
                    $bytes .= pack( 'V', $enc );
                }
                elsif ( $opcode eq 'fsqrt' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type ? $dst->type->bits : 64;
                    my $enc   = FSQRT | ( $sid << 15 ) | ( $did << 7 ) | FP_OP;
                    $enc |= FP_FMT if $bits > 32;
                    $bytes .= pack( 'V', $enc );
                }
                elsif ( $opcode eq 'call_func' ) {
                    my $func_name = $dst->value;
                    push @func_fixups, { offset => $current_offset->(), type => 'call_jal', target => $func_name };
                    $bytes .= pack( 'V', JAL | ( 1 << 7 ) | 0x6F );
                }
                elsif ( $opcode eq 'ret' ) {
                    my $cleanup = $alloca_frame + $extra_frame;
                    if ( $cleanup > 0 ) {
                        $bytes .= pack( 'V', ( ( $cleanup & 0xFFF ) << 20 ) | ( 2 << 15 ) | ( 0 << 12 ) | ( 2 << 7 ) | OP_IMM );
                    }
                    if ( $callee_size > 0 ) {
                        for my $i ( reverse 0 .. $#to_save ) {
                            my $reg     = $to_save[$i];
                            my $rid     = $reg_id->($reg);
                            my $off     = $i * 8;
                            my $load_op = $reg =~ /^f/ ? FLOAD : LOAD;
                            $bytes .= pack( 'V', ( ( $off & 0xFFF ) << 20 ) | ( 2 << 15 ) | ( 3 << 12 ) | ( $rid << 7 ) | $load_op );
                        }
                        $bytes .= pack( 'V', ( ( $callee_size & 0xFFF ) << 20 ) | ( 2 << 15 ) | ( 0 << 12 ) | ( 2 << 7 ) | OP_IMM );
                    }
                    $bytes .= pack( 'V', JALR );
                }
            }
        }
        for my $fixup (@fixups) {
            my $target_pos = $labels{ $fixup->{target} };
            die "undefined label: $fixup->{target}" unless defined $target_pos;
            my $rel = $target_pos - $fixup->{offset};
            if ( $fixup->{type} eq 'jal' ) {
                my $imm20 = ( $rel >> 1 ) & 0xFFFFF;
                my $enc   = ( ( $imm20 >> 19 ) & 1 ) << 31 | ( ( $imm20 & 0x3FF ) << 21 ) | ( ( $imm20 >> 10 ) & 1 ) << 20
                    | ( ( $imm20 >> 11 ) & 0xFF ) << 12 | JAL;
                substr $bytes, $fixup->{offset}, 4, pack( 'V', $enc );
            }
            elsif ( $fixup->{type} eq 'bcc' ) {
                my $imm13 = ( $rel >> 1 ) & 0x1FFF;
                my $enc   = ( ( $imm13 >> 11 ) & 1 ) << 31 | ( ( $imm13 >> 4 ) & 0x3F ) << 25 | ( $fixup->{rs1} << 15 ) | ( $fixup->{funct3} << 12 )
                    | ( ( $imm13 & 0x0F ) << 8 ) | ( ( $imm13 >> 10 ) & 1 ) << 7 | BCC;
                substr $bytes, $fixup->{offset}, 4, pack( 'V', $enc );
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
