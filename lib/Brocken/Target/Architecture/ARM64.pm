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
    field $code : reader = '';
    field %labels : reader;
    field @fixups;
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

    method add_imm ( $reg, $imm ) {
        my $r = $REG{ lc $reg };
        $code .= pack( 'L<', 0x91000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r );
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

    method call_rva ( $target_rva, $text_rva ) {
        $self->lea_rva( 'x16', $target_rva, $text_rva );
        $code .= pack( 'L<', 0xF9400000 | ( 16 << 5 ) | 16 );
        $code .= pack( 'L<', 0xD63F0200 );
    }

    method syscall( $os = '', $num = 0 ) {

        # For macOS ARM64, syscall number is in x16. Use SVC #0x80.
        if ( $os eq 'macos' ) {
            $code .= pack( 'L<', 0xD4001001 );    # SVC #0x80
        }

        # For NetBSD ARM64, the syscall number is encoded into the SVC immediate
        elsif ( $os eq 'netbsd' && $num > 0 ) {
            $code .= pack( 'L<', 0xD4000001 | ( ( $num & 0xFFFF ) << 5 ) );
        }

        # For Linux/FreeBSD/OpenBSD ARM64, syscall number is in x8. Use SVC #0.
        else {
            $code .= pack( 'L<', 0xD4000001 );    # SVC #0
            if ( $os eq 'openbsd' ) {

                # OpenBSD ARM64 kernel purposefully skips exactly 2 instructions after a syscall to mitigate speculative execution
                $code .= pack( 'L<', 0x14000002 );    # B .+8
                $code .= pack( 'L<', 0xD4200000 );    # BRK #0
            }
        }
    }

    method jcc ( $cc, $label ) {
        push @fixups, { offset => length($code), target => $label, type => 'cond', cc => $cc };
        $code .= pack( 'L<', 0x54000000 | $cc );
    }

    method jmp ($label) {
        push @fixups, { offset => length($code), target => $label, type => 'uncond' };
        $code .= pack( 'L<', 0x14000000 );
    }
    method mark_label ($name) { $labels{$name} = length $code }

    method resolve {
        for (@fixups) {
            my $target = $labels{ $_->{target} };
            my $off    = ( $target - $_->{offset} ) / 4;
            if ( $_->{type} eq 'cond' ) {
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( $off & 0x7FFFF ) << 5;
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
            else {
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( $off & 0x3FFFFFF );
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
        }
    }
}
1;
