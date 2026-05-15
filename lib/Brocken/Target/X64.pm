use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
#
class Brocken::Target::X64 {
    our %REG = ( rax => 0, rcx => 1, rdx => 2, rbx => 3, rsp => 4, rbp => 5, rsi => 6, rdi => 7, r8 => 8, r9 => 9, r10 => 10, r11 => 11 );
    field $code : reader = '';
    field @fixups;
    field %labels;
    method labels () { return \%labels }              # Returns the HASH reference
    method ret ()    { $code .= pack( 'C', 0xC3 ) }

    method _rex ( $w, $r, $x, $b ) {
        my $rex = 0x40;
        $rex |= 0x08 if $w;
        $rex |= 0x04 if $r >= 8;
        $rex |= 0x01 if $b >= 8;
        return ( $rex == 0x40 && !$w ) ? '' : pack( 'C', $rex );
    }

    method mov_imm ( $reg, $imm ) {
        my $r = $REG{ lc $reg };
        $code .= $self->_rex( 1, 0, 0, $r ) . pack( 'Cq<', 0xB8 + ( $r & 7 ), $imm );
    }

    method mov_reg( $dest, $src ) {
        my $d = $REG{ lc $dest };
        my $s = $REG{ lc $src };
        $code .= $self->_rex( 1, $s, 0, $d ) . pack( 'CC', 0x89, 0xC0 | ( ( $s & 7 ) << 3 ) | ( $d & 7 ) );
    }

    method add_imm ( $reg, $imm ) {
        my $r = $REG{ lc $reg };
        $code .= $self->_rex( 1, 0, 0, $r ) . pack( 'CCl<', 0x81, 0xC0 | ( $r & 7 ), $imm );
    }

    method sub_imm ( $reg, $imm ) {
        my $r = $REG{ lc $reg };
        $code .= $self->_rex( 1, 0, 0, $r ) . pack( 'CCl<', 0x81, 0xE8 | ( $r & 7 ), $imm );
    }

    method cmp_reg_imm ( $reg, $imm ) {
        my $r = $REG{ lc $reg };
        $code .= $self->_rex( 1, 0, 0, $r ) . pack( 'CCl<', 0x81, 0xF8 | ( $r & 7 ), $imm );
    }

    method lea_rva ( $reg, $target_rva, $text_rva ) {
        my $r        = $REG{ lc $reg };
        my $next_rip = $text_rva + length($code) + 7;
        $code .= $self->_rex( 1, $r, 0, 0 ) . pack( 'CC l<', 0x8D, 0x05 | ( ( $r & 7 ) << 3 ), $target_rva - $next_rip );
    }

    method call_rva( $target_rva, $text_rva ) {
        my $next_rip = $text_rva + length($code) + 6;
        $code .= pack( 'CC l<', 0xFF, 0x15, $target_rva - $next_rip );
    }

    method lea_reg_disp ( $dest, $base, $disp ) {
        my $d = $REG{ lc $dest };
        my $b = $REG{ lc $base };
        $code .= $self->_rex( 1, $d, 0, $b );
        if ( $disp >= -128 && $disp <= 127 ) {
            $code .= pack( 'CC', 0x8D, 0x40 | ( ( $d & 7 ) << 3 ) | ( $b & 7 ) );
            $code .= pack( 'C',  0x24 ) if ( $b & 7 ) == 4;
            $code .= pack( 'c',  $disp );
        }
        else {
            $code .= pack( 'CC', 0x8D, 0x80 | ( ( $d & 7 ) << 3 ) | ( $b & 7 ) );
            $code .= pack( 'C',  0x24 ) if ( $b & 7 ) == 4;
            $code .= pack( 'l<', $disp );
        }
    }

    method store_mem_disp_reg ( $base, $disp, $src ) {
        my $b = $REG{ lc $base };
        my $s = $REG{ lc $src };
        $code .= $self->_rex( 1, $s, 0, $b );
        if ( $disp >= -128 && $disp <= 127 ) {
            $code .= pack( 'CC', 0x89, 0x40 | ( ( $s & 7 ) << 3 ) | ( $b & 7 ) );
            $code .= pack( 'C',  0x24 ) if ( $b & 7 ) == 4;
            $code .= pack( 'c',  $disp );
        }
        else {
            $code .= pack( 'CC', 0x89, 0x80 | ( ( $s & 7 ) << 3 ) | ( $b & 7 ) );
            $code .= pack( 'C',  0x24 ) if ( $b & 7 ) == 4;
            $code .= pack( 'l<', $disp );
        }
    }
    method syscall( $os = '' ) { $code .= pack 'CC', 0x0F, 0x05 }

    method jcc ( $cc, $label ) {
        $code .= pack( 'CC', 0x0F, 0x80 + $cc );
        push @fixups, { offset => length($code), target => $label };
        $code .= pack( 'L<', 0 );
    }

    method jmp ($label) {
        $code .= pack( 'C', 0xE9 );
        push @fixups, { offset => length($code), target => $label };
        $code .= pack( 'L<', 0 );
    }
    method mark_label ($name) { $labels{$name} = length $code }

    method resolve {
        for (@fixups) {
            my $target = $labels{ $_->{target} };
            substr( $code, $_->{offset}, 4, pack( 'l<', $target - ( $_->{offset} + 4 ) ) );
        }
    }
}
1;
