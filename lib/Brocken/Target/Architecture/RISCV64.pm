use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::Architecture::RISCV64 {
    our %REG = (
        zero => 0,
        ra   => 1,
        sp   => 2,
        gp   => 3,
        tp   => 4,
        t0   => 5,
        t1   => 6,
        t2   => 7,
        s0   => 8,
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
        t6   => 31,
    );
    field $code : reader = '';
    field @fixups;
    field %labels;
    method labels () { return \%labels }
    method ret ()    { $code .= pack( 'L<', 0x00008067 ) }

    method _li ( $r, $imm ) {
        return $self->_addi( $r, 0, $imm ) if $imm >= -2048 && $imm <= 2047;
        my $upper = ( $imm + 0x800 ) >> 12;
        my $lower = $imm - ( $upper << 12 );
        $self->_lui( $r, $upper & 0xFFFFF );
        $self->_addi( $r, $r, $lower ) if $lower;
    }

    method _lui ( $r, $imm20 ) {
        $code .= pack( 'L<', ( ( $imm20 & 0xFFFFF ) << 12 ) | ( $r << 7 ) | 0x37 );
    }

    method _addi ( $rd, $rs1, $imm12 ) {
        $code .= pack( 'L<', ( ( $imm12 & 0xFFF ) << 20 ) | ( $rs1 << 15 ) | ( $rd << 7 ) | 0x13 );
    }

    method _addiw ( $rd, $rs1, $imm12 ) {
        $code .= pack( 'L<', ( ( $imm12 & 0xFFF ) << 20 ) | ( $rs1 << 15 ) | ( $rd << 7 ) | 0x1B );
    }

    method _sub ( $rd, $rs1, $rs2 ) {
        $code .= pack( 'L<', ( 0x20 << 25 ) | ( $rs2 << 20 ) | ( $rs1 << 15 ) | ( $rd << 7 ) | 0x33 );
    }

    method _slli ( $rd, $rs1, $shamt ) {
        $code .= pack( 'L<', ( ( $shamt & 0x3F ) << 20 ) | ( $rs1 << 15 ) | ( 1 << 12 ) | ( $rd << 7 ) | 0x13 );
    }

    method _ori ( $rd, $rs1, $imm12 ) {
        $code .= pack( 'L<', ( ( $imm12 & 0xFFF ) << 20 ) | ( $rs1 << 15 ) | ( 6 << 12 ) | ( $rd << 7 ) | 0x13 );
    }

    method _xori ( $rd, $rs1, $imm12 ) {
        $code .= pack( 'L<', ( ( $imm12 & 0xFFF ) << 20 ) | ( $rs1 << 15 ) | ( 4 << 12 ) | ( $rd << 7 ) | 0x13 );
    }

    method _slt ( $rd, $rs1, $rs2 ) {
        $code .= pack( 'L<', ( $rs2 << 20 ) | ( $rs1 << 15 ) | ( 2 << 12 ) | ( $rd << 7 ) | 0x33 );
    }

    method _sltu ( $rd, $rs1, $rs2 ) {
        $code .= pack( 'L<', ( $rs2 << 20 ) | ( $rs1 << 15 ) | ( 3 << 12 ) | ( $rd << 7 ) | 0x33 );
    }

    method _slti ( $rd, $rs1, $imm12 ) {
        $code .= pack( 'L<', ( ( $imm12 & 0xFFF ) << 20 ) | ( $rs1 << 15 ) | ( 2 << 12 ) | ( $rd << 7 ) | 0x13 );
    }

    method _sltiu ( $rd, $rs1, $imm12 ) {
        $code .= pack( 'L<', ( ( $imm12 & 0xFFF ) << 20 ) | ( $rs1 << 15 ) | ( 3 << 12 ) | ( $rd << 7 ) | 0x13 );
    }

    method _ld ( $rd, $imm12, $rs1 ) {
        $code .= pack( 'L<', ( ( $imm12 & 0xFFF ) << 20 ) | ( $rs1 << 15 ) | ( 3 << 12 ) | ( $rd << 7 ) | 0x03 );
    }

    method _sd ( $rs2, $imm12, $rs1 ) {
        my $hi = ( $imm12 >> 5 ) & 0x7F;
        my $lo = $imm12 & 0x1F;
        $code .= pack( 'L<', ( $hi << 25 ) | ( $rs2 << 20 ) | ( $rs1 << 15 ) | ( 3 << 12 ) | ( $lo << 7 ) | 0x23 );
    }

    method _reg ($name) {
        my $n = $REG{ lc $name };
        die "Unknown register: $name" unless defined $n;
        return $n;
    }

    method mov_imm ( $reg, $imm ) {
        $self->_li( $self->_reg($reg), $imm );
    }

    method mov_reg ( $dest, $src ) {
        my $d = $self->_reg($dest);
        my $s = $self->_reg($src);
        $code .= pack( 'L<', ( $s << 15 ) | ( $d << 7 ) | 0x13 );
    }

    method mov_reg_to_sp($src) {
        $self->mov_reg( 'sp', $src );
    }

    method add_reg( $dest, $src ) {
        my $d = $self->_reg($dest);
        my $s = $self->_reg($src);
        $code .= pack( 'L<', ( $s << 20 ) | ( $d << 15 ) | ( $d << 7 ) | 0x33 );
    }

    method sub_reg( $dest, $src ) {
        my $d = $self->_reg($dest);
        my $s = $self->_reg($src);
        $code .= pack( 'L<', ( 0x20 << 25 ) | ( $s << 20 ) | ( $d << 15 ) | ( $d << 7 ) | 0x33 );
    }

    method mul_reg( $dest, $src ) {
        my $d = $self->_reg($dest);
        my $s = $self->_reg($src);
        $code .= pack( 'L<', ( 1 << 25 ) | ( $s << 20 ) | ( $d << 15 ) | ( $d << 7 ) | 0x33 );
    }

    method lea_reg_disp( $dest, $base, $disp ) {
        if ( $disp >= -2048 && $disp <= 2047 ) {
            $self->add_reg_imm( $dest, $base, $disp );
        }
        else {
            $self->mov_imm( $dest, $disp );
            $self->add_reg( $dest, $base );
        }
    }

    method store_mem_disp_reg( $base, $disp, $src ) { $self->emit_store_mem( $base, $disp, $src ) }

    method cmp_reg_reg ( $l, $r ) {
        my $l_reg = $self->_reg($l);
        my $r_reg = $self->_reg($r);
        my $t = $REG{t0};
        $code .= pack( 'L<', ( 0x20 << 25 ) | ( $r_reg << 20 ) | ( $l_reg << 15 ) | ( $t << 7 ) | 0x33 );
    }

    method pause() {
        $code .= pack( 'L<', 0x00000013 );
    }

    method add_imm ( $reg, $imm ) {
        my $r = $self->_reg($reg);
        $self->_addi( $r, $r, $imm );
    }

    method add_reg_imm ( $dest, $src, $imm ) {
        my $d = $self->_reg($dest);
        my $s = $self->_reg($src);
        $self->_addi( $d, $s, $imm );
    }

    method sub_imm ( $reg, $imm ) {
        my $r = $self->_reg($reg);
        $self->_addi( $r, $r, -$imm );
    }

    method cmp_reg_imm ( $reg, $imm ) {
        my $r = $self->_reg($reg);
        my $t = $REG{t0};
        $self->_li( $t, $imm );
        $self->_sub( $t, $r, $t );
    }

    method lea_rva ( $reg, $target_rva, $text_rva ) {
        my $r   = $self->_reg($reg);
        my $off = $target_rva - ( $text_rva + length($code) );
        my $hi  = ( $off + 0x800 ) >> 12;
        my $lo  = $off - ( $hi << 12 );
        $code .= pack( 'L<', ( ( $hi & 0xFFFFF ) << 12 ) | ( $r << 7 ) | 0x17 );
        $self->_addi( $r, $r, $lo );
    }

    method call_rva ( $target_rva, $text_rva ) {
        my $t   = $REG{t0};
        my $off = $target_rva - ( $text_rva + length($code) );
        my $hi  = ( $off + 0x800 ) >> 12;
        my $lo  = $off - ( $hi << 12 );
        $code .= pack( 'L<', ( ( $hi & 0xFFFFF ) << 12 ) | ( $t << 7 ) | 0x17 );
        $self->_addi( $t, $t, $lo );
        $self->_ld( $t, 0, $t );
        $code .= pack( 'L<', ( $t << 15 ) | ( 1 << 7 ) | 0x67 );
    }

    method syscall ( $os = '', $num = 0 ) {
        $code .= pack( 'L<', 0x00000073 );
    }

    method setcc ( $cc, $r ) {
        my $rd = $self->_reg($r);
        my $z  = $REG{zero};
        my $t  = $REG{t0};
        if ( $cc == 0x94 ) {        # ==
            $self->_sltiu( $rd, $t, 1 );
        }
        elsif ( $cc == 0x95 ) {     # !=
            $self->_sltu( $rd, $z, $t );
        }
        elsif ( $cc == 0x9C ) {     # <
            $self->_slt( $rd, $t, $z );
        }
        elsif ( $cc == 0x9D ) {     # >=
            $self->_slt( $rd, $t, $z );
            $self->_xori( $rd, $rd, 1 );
        }
        elsif ( $cc == 0x9E ) {     # <=
            $self->_slti( $rd, $t, 1 );
        }
        elsif ( $cc == 0x9F ) {     # >
            $self->_slt( $rd, $z, $t );
        }
    }

    method jcc ( $cc, $label ) {
        my $t      = $REG{t0};
        my $funct3 = 0;
        my $rs2    = $REG{zero};
        if    ( $cc == 0 || $cc == 4 ) { $funct3 = 0 }                                # beq t0, x0
        elsif ( $cc == 1 || $cc == 5 ) { $funct3 = 1 }                                # bne t0, x0
        elsif ( $cc == 0xB )           { $funct3 = 4 }                                # blt t0, x0
        elsif ( $cc == 0xA )           { $funct3 = 5 }                                # bge t0, x0
        elsif ( $cc == 0xC )           { $funct3 = 4; $rs2 = $t; $t = $REG{zero} }    # blt x0, t0
        elsif ( $cc == 0xD )           { $funct3 = 5; $rs2 = $t; $t = $REG{zero} }    # bge x0, t0
        else                           { $funct3 = 0 }
        push @fixups, { offset => length($code), target => $label, funct3 => $funct3, rs1 => $t, rs2 => $rs2 };
        $code .= pack( 'L<', 0 );                                                     # placeholder
    }

    method jmp ($label) {
        push @fixups, { offset => length($code), target => $label, type => 'jal' };
        $code .= pack( 'L<', 0 );
    }
    method mark_label ($name) { $labels{$name} = length $code }

    method resolve {
        for (@fixups) {
            my $target = $labels{ $_->{target} };
            my $off    = $target - $_->{offset};    # byte offset
            if ( $_->{type} && $_->{type} eq 'jal' ) {
                my $instr = 0x6F;                             # JAL x0
                $instr |= ( ( $off >> 20 ) & 1 ) << 31;       # off[20]
                $instr |= ( ( $off >> 1 ) & 0x3FF ) << 21;    # off[10:1]
                $instr |= ( ( $off >> 11 ) & 1 ) << 20;       # off[11]
                $instr |= ( ( $off >> 12 ) & 0xFF ) << 12;    # off[19:12]
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
            elsif ( $_->{type} && $_->{type} eq 'jal_ra' ) {
                my $instr = 0xEF;                             # JAL ra
                $instr |= ( ( $off >> 20 ) & 1 ) << 31;       # off[20]
                $instr |= ( ( $off >> 1 ) & 0x3FF ) << 21;    # off[10:1]
                $instr |= ( ( $off >> 11 ) & 1 ) << 20;       # off[11]
                $instr |= ( ( $off >> 12 ) & 0xFF ) << 12;    # off[19:12]
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
            else {
                my $funct3 = $_->{funct3};
                my $rs1    = $_->{rs1};
                my $rs2    = $_->{rs2};
                my $instr  = 0x63;                            # BRANCH
                $instr |= ( ( $off >> 12 ) & 1 ) << 31;       # off[12]
                $instr |= ( ( $off >> 5 ) & 0x3F ) << 25;     # off[10:5]
                $instr |= ( $rs2 << 20 );
                $instr |= ( $rs1 << 15 );
                $instr |= ( $funct3 << 12 );
                $instr |= ( ( $off >> 1 ) & 0xF ) << 8;       # off[4:1]
                $instr |= ( ( $off >> 11 ) & 1 ) << 7;        # off[11]
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
        }
    }
    method alloc_stack($size)          { $self->sub_imm( 'sp', $size ) }
    method emit_mov_reg( $dest, $src ) { $self->mov_reg( $dest, $src ) }
    method emit_mov_imm( $reg, $imm )  { $self->mov_imm( $reg, $imm ) }

    method emit_syscall( $num, @args ) {
        my @arg_regs = qw(a0 a1 a2 a3 a4 a5);
        for my $i ( 0 .. $#args ) {
            $self->mov_imm( $arg_regs[$i], $args[$i] ) if defined $args[$i];
        }
        $self->mov_imm( 'a7', $num );
        $self->syscall();
    }
    method emit_lea_label( $reg, $label, $text_rva ) { $self->lea_rva( $reg, $label, $text_rva ) }

    method emit_store_mem( $base, $disp, $src ) {
        my $rs2 = $self->_reg($src);
        my $rs1 = $self->_reg($base);
        $self->_sd( $rs2, $disp, $rs1 );
    }
    method load_reg_mem( $dest, $base, $off = 0 ) {
        my $rd = $self->_reg($dest);
        my $rs1 = $self->_reg($base);
        $self->_ld( $rd, $off, $rs1 );
    }
    method push_reg($r) {
        $self->add_imm( 'sp', -16 );
        $self->emit_store_mem( 'sp', 0, $r );
    }
    method pop_reg($r) {
        $self->load_reg_mem( $r, 'sp', 0 );
        $self->add_imm( 'sp', 16 );
    }
    method emit_label($name) { $self->mark_label($name) }

    method emit_branch_if_zero( $reg, $label ) {
        my $r = $self->_reg($reg);
        push @fixups, { offset => length($code), target => $label, funct3 => 0, rs1 => $r, rs2 => $REG{zero} };
        $code .= pack( 'L<', 0 );
    }

    method emit_branch_if_not_zero( $reg, $label ) {
        my $r = $self->_reg($reg);
        push @fixups, { offset => length($code), target => $label, funct3 => 1, rs1 => $r, rs2 => $REG{zero} };
        $code .= pack( 'L<', 0 );
    }
    method emit_call_label($label) { $self->call_label($label) }

    method call_label($l) {
        push @fixups, { offset => length($code), target => $l, type => 'jal_ra' };
        $code .= pack( 'L<', 0 );
    }

    method emit_print_str ( $os, $off, $len ) {
        if ( $os->is_posix ) {
            my $num = $os->syscall_write('riscv64');
            $self->mov_imm( 'a7', $num );
            $self->mov_imm( 'a0', 1 );
            my $page_size = $os->page_size('riscv64');
            my $text_rva  = $page_size;
            my $data_rva  = 2 * $page_size;
            $os->write_syscall_args( $self, 'riscv64', $data_rva, $off, $text_rva, $len );
            $self->syscall( $os->name, $num );
        }
        else {
            $self->mov_imm( 'a0', -11 );
            $self->call_rva( 0x3008, 0x1000 );
            $self->mov_reg( 'a0', 'a0' );
            $self->lea_rva( 'a1', 0x2000 + $off, 0x1000 );
            $self->mov_imm( 'a2', $len );
            $self->mov_imm( 'a4', 0 );
            $self->call_rva( 0x3010, 0x1000 );
        }
    }

    method emit_exit_proc ( $os, $code ) {
        if ( $os->is_posix ) {
            my $num = $os->syscall_exit('riscv64');
            $self->mov_imm( 'a7', $num );
            $self->mov_imm( 'a0', $code );
            $self->syscall( $os->name, $num );
        }
        else {
            $self->mov_imm( 'a0', $code );
            $self->call_rva( 0x3000, 0x1000 );
        }
    }
}
1;
