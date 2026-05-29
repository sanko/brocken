use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
#
class Brocken::Target::Architecture::ARM64 {
    field $os_name : param : reader = 'linux';
    our %REG = (
        x0  => 0,
        x1  => 1,
        x2  => 2,
        x3  => 3,
        x4  => 4,
        x5  => 5,
        x6  => 6,
        x7  => 7,
        x8  => 8,
        x9  => 9,
        x10 => 10,
        x11 => 11,
        x12 => 12,
        x13 => 13,
        x14 => 14,
        x15 => 15,
        x16 => 16,
        x17 => 17,
        x18 => 18,
        x19 => 19,
        x20 => 20,
        x21 => 21,
        x22 => 22,
        x23 => 23,
        x24 => 24,
        x25 => 25,
        x26 => 26,
        x27 => 27,
        x28 => 28,
        x29 => 29,
        x30 => 30,
        sp  => 31,
        xzr => 31
    );
    field $code : reader = '';
    field %labels;
    field @fixups;
    method labels()    { \%labels }
    method label($key) { $labels{$key} // () }
    method ret ()      { $code .= pack( 'L<', 0xD65F03C0 ) }

    method mov_imm ( $reg, $imm ) {
        my $r = $REG{ lc $reg };
        $code .= pack( 'L<', 0xD2800000 | ( ( $imm & 0xFFFF ) << 5 ) | $r );
        if ( ( $imm >> 16 ) & 0xFFFF ) {
            $code .= pack( 'L<', 0xF2A00000 | ( 1 << 21 ) | ( ( ( $imm >> 16 ) & 0xFFFF ) << 5 ) | $r );
        }
        if ( ( $imm >> 32 ) & 0xFFFF ) {
            $code .= pack( 'L<', 0xF2C00000 | ( 2 << 21 ) | ( ( ( $imm >> 32 ) & 0xFFFF ) << 5 ) | $r );
        }
        if ( ( $imm >> 48 ) & 0xFFFF ) {
            $code .= pack( 'L<', 0xF2E00000 | ( 3 << 21 ) | ( ( ( $imm >> 48 ) & 0xFFFF ) << 5 ) | $r );
        }
    }

    method mov_reg ( $dest, $src ) {
        my $d = $REG{ lc $dest };
        my $s = $REG{ lc $src };
        if ( lc($dest) eq 'sp' || lc($src) eq 'sp' ) {
            $code .= pack( 'L<', 0x91000000 | ( $s << 5 ) | $d );
        }
        else {
            $code .= pack( 'L<', 0xAA0003E0 | ( $s << 16 ) | $d );
        }
    }

    method mov_reg_to_sp($src) {
        my $s = $REG{ lc $src };
        $code .= pack( 'L<', 0x91000000 | ( $s << 5 ) | 31 );    # ADD SP, Xn, #0
    }

    method add_imm ( $reg, $imm ) {
        my $r = $REG{ lc $reg };
        $code .= pack( 'L<', 0x91000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r );
    }

    method add_reg_imm ( $dest, $src, $imm ) {
        my $d = $REG{ lc $dest };
        my $s = $REG{ lc $src };
        $code .= pack( 'L<', 0x91000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $s << 5 ) | $d );
    }

    method sub_imm ( $reg, $imm ) {
        my $r = $REG{ lc $reg };
        $code .= pack( 'L<', 0xD1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r );
    }

    method cmp_reg_imm ( $reg, $imm ) {
        my $r = $REG{ lc $reg };
        $code .= pack( 'L<', 0xF1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | 31 );
    }

    method add_reg( $dest, $src ) {
        my $d = $REG{ lc $dest };
        my $s = $REG{ lc $src };
        $code .= pack( 'L<', 0x8B000000 | ( $s << 16 ) | ( $d << 5 ) | $d );
    }

    method sub_reg( $dest, $src ) {
        my $d = $REG{ lc $dest };
        my $s = $REG{ lc $src };
        $code .= pack( 'L<', 0xCB000000 | ( $s << 16 ) | ( $d << 5 ) | $d );
    }

    method mul_reg( $dest, $src ) {
        my $d = $REG{ lc $dest };
        my $s = $REG{ lc $src };
        $code .= pack( 'L<', 0x9B007C00 | ( $s << 16 ) | ( $d << 5 ) | $d );
    }

    method cmp_reg_reg ( $l, $r ) {
        my $rd = $REG{ lc $l };
        my $rs = $REG{ lc $r };
        $code .= pack( 'L<', 0xEB00001F | ( $rs << 16 ) | ( $rd << 5 ) );
    }

    method lea_rva ( $reg, $target, $txtrva = 0 ) {
        my $r = $REG{ lc $reg };
        if ( $target =~ /^([A-Z_]|DATA:|TEXT:)/i ) {
            push @fixups, { offset => length($code), target => $target, type => 'adrp', reg => $r };
            $code .= pack( 'L<', 0x90000000 | ( $r & 31 ) );                  # ADRP Xn, label
            push @fixups, { offset => length($code), target => $target, type => 'add_page', reg => $r };
            $code .= pack( 'L<', 0x91000000 | ( $r << 5 ) | ( $r & 31 ) );    # ADD Xn, Xn, #pg_off
        }
        else {
            my $off   = $target - ( $txtrva + length($code) );
            my $immlo = $off & 0x3;
            my $immhi = ( $off >> 2 ) & 0x7FFFF;
            $code .= pack( 'L<', 0x10000000 | ( $immlo << 29 ) | ( $immhi << 5 ) | $r );
        }
    }
    method alloc_stack($size)          { $self->sub_imm( 'sp', $size ) }
    method emit_mov_reg( $dest, $src ) { $self->mov_reg( $dest, $src ) }
    method emit_mov_imm( $reg, $imm )  { $self->mov_imm( $reg, $imm ) }

    method lea_reg_disp( $dest, $base, $disp ) {
        if ( $disp <= 0xFFF ) {
            $self->add_reg_imm( $dest, $base, $disp );
        }
        elsif ( ( $disp & 0xFFF ) == 0 && ( $disp >> 12 ) <= 0xFFF ) {
            my $d     = $REG{ lc $dest };
            my $b     = $REG{ lc $base };
            my $imm12 = $disp >> 12;
            $code .= pack( 'L<', 0x91400000 | ( 1 << 22 ) | ( $imm12 << 10 ) | ( $b << 5 ) | $d );
        }
        else {
            $self->mov_imm( $dest, $disp );
            $self->add_reg( $dest, $base );
        }
    }

    method load_reg_mem( $dest, $base, $off = 0 ) {
        my $d = $REG{ lc $dest };
        my $b = $REG{ lc $base };
        if ( $off >= 0 ) {
            $code .= pack( 'L<', 0xF9400000 | ( ( $off >> 3 ) << 10 ) | ( $b << 5 ) | $d );
        }
        else {
            $code .= pack( 'L<', 0xF8400000 | ( ( $off & 0x1FF ) << 12 ) | ( $b << 5 ) | $d );
        }
    }

    method push_reg($r) {
        $self->sub_imm( 'sp', 16 );
        $self->emit_store_mem( 'sp', 0, $r );
    }

    method pop_reg($r) {
        $self->load_reg_mem( $r, 'sp', 0 );
        $self->add_imm( 'sp', 16 );
    }

    method emit_syscall( $num, @args ) {
        my $os = $self->os_name;
        $self->mov_imm( $os eq 'macos' ? 'x16' : 'x8', $num );
        my @arg_regs = qw(x0 x1 x2 x3 x4 x5);
        for my $i ( 0 .. $#args ) {
            my $arg = $args[$i];
            next unless defined $arg;
            if ( $arg !~ /^-?\d+$/ && $arg ne 'stack' && exists $REG{ lc $arg } ) {
                $self->mov_reg( $arg_regs[$i], $arg );
            }
            else {
                $self->mov_imm( $arg_regs[$i], $arg );
            }
        }
        $self->syscall( $os, $num );
    }
    method emit_lea_label( $reg, $label, $text_rva ) { $self->lea_rva( $reg, $label, $text_rva ) }

    method emit_store_mem( $base, $disp, $src ) {
        my $d = $REG{ lc $src };
        my $b = $REG{ lc $base };
        if ( $disp >= 0 ) {
            $code .= pack( 'L<', 0xF9000000 | ( ( $disp >> 3 ) << 10 ) | ( $b << 5 ) | $d );
        }
        else {
            $code .= pack( 'L<', 0xF8000000 | ( ( $disp & 0x1FF ) << 12 ) | ( $b << 5 ) | $d );
        }
    }
    method store_mem_disp_reg( $base, $disp, $src ) { $self->emit_store_mem( $base, $disp, $src ) }
    method emit_label($name)                        { $self->mark_label($name) }

    method setcc ( $cc, $r ) {
        my %arm_cc = ( 0x9C => 0xA, 0x9D => 0xB, 0x9E => 0xC, 0x9F => 0xD, 0x94 => 0x1, 0x95 => 0x0 );
        my $cond   = $arm_cc{$cc} // 0;
        my $rd     = $REG{ lc $r };
        $code .= pack( 'L<', 0x9A9F07E0 | ( $cond << 12 ) | $rd );
    }

    method emit_branch_if_zero( $reg, $label ) {
        my $r = $REG{ lc $reg };
        push @fixups, { offset => length($code), target => $label, type => 'cond_cbz' };
        $code .= pack( 'L<', 0xB4000000 | $r );
    }

    method emit_branch_if_not_zero( $reg, $label ) {
        my $r = $REG{ lc $reg };
        push @fixups, { offset => length($code), target => $label, type => 'cond_cbnz' };
        $code .= pack( 'L<', 0xB5000000 | $r );
    }
    method emit_call_label($label)             { $self->call_label($label) }
    method call_rva_label( $label, $text_rva ) { $self->call_rva( $labels{$label} // 0, $text_rva ) }

    method call_rva( $target_rva, $text_rva ) {
        my $code_off    = length($code);
        my $source_page = ( $text_rva + $code_off ) & ~0xFFF;
        my $target_page = $target_rva & ~0xFFF;
        my $page_delta  = ( $target_page - $source_page ) >> 12;
        my $page_offset = $target_rva & 0xFFF;

        # ADRP x16, page_of(IAT_entry)
        my $immlo = $page_delta & 0x3;
        my $immhi = ( $page_delta >> 2 ) & 0x7FFFF;
        $code .= pack( 'L<', 0x90000000 | ( $immlo << 29 ) | ( $immhi << 5 ) | 16 );

        # LDR x16, [x16, #page_offset]
        my $ldr_imm = $page_offset >> 3;
        $code .= pack( 'L<', 0xF9400200 | ( $ldr_imm << 10 ) | ( 16 << 5 ) | 16 );

        # BLR x16
        $code .= pack( 'L<', 0xD63F0200 | ( 16 << 5 ) );
    }

    method call_label($l) {
        push @fixups, { offset => length($code), target => $l, type => 'uncond_bl' };
        $code .= pack( 'L<', 0x94000000 );
    }

    method syscall( $os = '', $num = 0 ) {
        if ( $os eq 'macos' ) {
            $code .= pack( 'L<', 0xD4000001 );    # SVC #0
        }
        elsif ( $os eq 'netbsd' && $num > 0 ) {
            $code .= pack( 'L<', 0xD4000001 | ( ( $num & 0xFFFF ) << 5 ) );
        }
        else {
            $code .= pack( 'L<', 0xD4000001 );    # SVC #0
            if ( $os eq 'openbsd' ) {
                $code .= pack( 'L<', 0x14000002 );    # B .+8
                $code .= pack( 'L<', 0xD4200000 );    # BRK #0
            }
        }
    }

    method jcc ( $cc, $label ) {
        my $cond = $cc;
        if    ( $cc == 4 ) { $cond = 0; }    # x86 JZ -> ARM64 EQ
        elsif ( $cc == 5 ) { $cond = 1; }    # x86 JNZ -> ARM64 NE
        push @fixups, { offset => length($code), target => $label, type => 'cond_b_cc', cc => $cond };
        $code .= pack( 'L<', 0x54000000 | $cond );
    }

    method jmp ($label) {
        push @fixups, { offset => length($code), target => $label, type => 'uncond_b' };
        $code .= pack( 'L<', 0x14000000 );
    }
    method mark_label ($name) { $labels{$name} = length $code }
    method halt ()            { $code .= pack( 'L<', 0xD4200000 ) }    # BRK #0

    method emit_print_str ( $os, $off, $len ) {
        if ( $os->is_posix ) {
            my $num = $os->syscall_write('arm64');
            my $reg = $os->syscall_num_reg('arm64');
            $self->mov_imm( $reg, $num ) if defined $reg;
            $self->mov_imm( 'x0', 1 );
            my $page_size = $os->page_size('arm64');
            my $text_rva  = $page_size;
            my $data_rva  = 2 * $page_size;
            $os->write_syscall_args( $self, 'arm64', $data_rva, $off, $text_rva, $len );
            $self->syscall( $os->name, $num );
        }
        else {
            # Windows ARM64: GetStdHandle + WriteFile via IAT
            my $text_rva = $os->text_rva;
            $self->mov_imm( 'x0', -11 );                            # STD_OUTPUT_HANDLE
            $self->call_rva( $os->symbol_rva('GetStdHandle'), $text_rva );
            my $data_rva = $os->data_rva;
            $self->lea_rva( 'x1', $data_rva + $off, $text_rva );    # lpBuffer
            $self->mov_imm( 'x2', $len );                           # nNumberOfBytesToWrite
            $self->mov_imm( 'x3', 0 );                              # lpNumberOfBytesWritten = NULL
            $self->mov_imm( 'x4', 0 );                              # lpOverlapped = NULL
            $self->call_rva( $os->symbol_rva('WriteFile'), $text_rva );
        }
    }

    method emit_exit_proc ( $os, $code_val ) {
        if ( $os->is_posix ) {
            my $num = $os->syscall_exit('arm64');
            my $reg = $os->syscall_num_reg('arm64');
            $self->mov_imm( $reg, $num ) if defined $reg;
            $self->mov_imm( 'x0', $code_val );
            $self->syscall( $os->name, $num );
            $self->halt();
        }
        else {
            $self->mov_imm( 'x0', $code_val );
            $self->call_rva( $os->symbol_rva('ExitProcess'), $os->text_rva );
            $self->halt();
        }
    }

    method resolve {
        for (@fixups) {
            my $target = $labels{ $_->{target} };
            die "Undefined target label: $_->{target}" unless defined $target;
            my $off   = ( $target - $_->{offset} ) / 4;
            my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
            if ( $_->{type} eq 'cond_b_cc' ) {
                $instr |= ( $off & 0x7FFFF ) << 5;
            }
            elsif ( $_->{type} eq 'cond_cbz' || $_->{type} eq 'cond_cbnz' ) {
                $instr |= ( $off & 0x7FFFF ) << 5;
            }
            elsif ( $_->{type} eq 'uncond_b' || $_->{type} eq 'uncond_bl' ) {
                $instr |= ( $off & 0x3FFFFFF );
            }
            elsif ( $_->{type} eq 'adrp' ) {
                my $target_page = $target & ~0xFFF;
                my $source_page = $_->{offset} & ~0xFFF;
                my $page_delta  = ( $target_page - $source_page ) >> 12;
                my $immlo       = $page_delta & 0x3;
                my $immhi       = ( $page_delta >> 2 ) & 0x7FFFF;
                $instr |= ( $immlo << 29 ) | ( $immhi << 5 );
            }
            elsif ( $_->{type} eq 'add_page' ) {
                my $page_offset = $target & 0xFFF;
                $instr |= ( $page_offset << 10 );
            }
            elsif ( $_->{type} eq 'ldr_page' ) {
                my $page_offset = $target & 0xFFF;
                my $ldr_imm     = $page_offset >> 3;
                $instr |= ( $ldr_imm << 10 );
            }
            substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
        }
    }
}
1;
