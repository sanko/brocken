use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
#
class Brocken::Target::Architecture::ARM64 {
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
    field $code    : reader = '';
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
        $code .= pack( 'L<', 0xAA0003E0 | ( $s << 16 ) | $d );
    }

    method mov_reg_to_sp($src) {
        my $s = $REG{ lc $src };
        $code .= pack( 'L<', 0x91000000 | ( $s << 5 ) | 31 ); # ADD SP, Xn, #0
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

    method lea_rva ( $reg, $target_rva, $text_rva ) {
        my $r     = $REG{ lc $reg };
        my $off   = $target_rva - ( $text_rva + length($code) );
        my $immlo = $off & 0x3;
        my $immhi = ( $off >> 2 ) & 0x7FFFF;
        $code .= pack( 'L<', 0x10000000 | ( $immlo << 29 ) | ( $immhi << 5 ) | $r );
    }

    method alloc_stack($size) { $self->sub_imm('sp', $size) }
    method emit_mov_reg($dest, $src) { $self->mov_reg($dest, $src) }
    method emit_mov_imm($reg, $imm) { $self->mov_imm($reg, $imm) }
    method emit_syscall($num, @args) {
        $self->mov_imm('x8', $num);
        my @arg_regs = qw(x0 x1 x2 x3 x4 x5);
        for my $i (0 .. $#args) {
            $self->mov_imm($arg_regs[$i], $args[$i]) if defined $args[$i];
        }
        $self->syscall('linux', $num);
    }
    method emit_lea_label($reg, $label, $text_rva) { $self->lea_rva($reg, $label, $text_rva) }
    method emit_store_mem($base, $disp, $src) {
        my $d = $REG{ lc $src };
        my $b = $REG{ lc $base };
        $code .= pack( 'L<', 0xF9000000 | ( ( $disp >> 3 ) << 10 ) | ( $b << 5 ) | $d );
    }
    method emit_label($name) { $self->mark_label($name) }
    method emit_branch_if_zero($reg, $label) {
        my $r = $REG{ lc $reg };
        push @fixups, { offset => length($code), target => $label, type => 'cond_cbz' };
        $code .= pack( 'L<', 0xB4000000 | $r );
    }
    method emit_branch_if_not_zero($reg, $label) {
        my $r = $REG{ lc $reg };
        push @fixups, { offset => length($code), target => $label, type => 'cond_cbnz' };
        $code .= pack( 'L<', 0xB5000000 | $r );
    }
    method emit_call_label($label) { $self->call_label($label) }
    method call_label($l) {
        push @fixups, { offset => length($code), target => $l, type => 'uncond_bl' };
        $code .= pack( 'L<', 0x94000000 );
    }

    method syscall( $os = '', $num = 0 ) {
        if ( $os eq 'macos' ) {
            $code .= pack( 'L<', 0xD4001001 );    # SVC #0x80
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
        push @fixups, { offset => length($code), target => $label, type => 'cond_b_cc', cc => $cc };
        $code .= pack( 'L<', 0x54000000 | $cc );
    }

    method jmp ($label) {
        push @fixups, { offset => length($code), target => $label, type => 'uncond_b' };
        $code .= pack( 'L<', 0x14000000 );
    }
    method mark_label ($name) { $labels{$name} = length $code }

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
            # Placeholder for non-POSIX (Windows ARM64)
            $self->mov_imm( 'x0', -11 );
            # $self->call_rva( ... ); # Need correct RVA or label
            # For now, let's keep it as is if it's not the focus
        }
    }

    method emit_exit_proc ( $os, $code_val ) {
        if ( $os->is_posix ) {
            my $num = $os->syscall_exit('arm64');
            my $reg = $os->syscall_num_reg('arm64');
            $self->mov_imm( $reg, $num ) if defined $reg;
            $self->mov_imm( 'x0', $code_val );
            $self->syscall( $os->name, $num );
        }
        else {
            $self->mov_imm( 'x0', $code_val );
            # $self->call_rva( ... );
        }
    }

    method resolve {
        for (@fixups) {
            my $target = $labels{ $_->{target} };
            die "Undefined target label: $_->{target}" unless defined $target;
            my $off    = ( $target - $_->{offset} ) / 4;
            
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
            
            substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
        }
    }
}
1;
