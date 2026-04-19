use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
$|++;
#
package Pulse::Util {

    sub hexdump ($data) {
        my $out = '';
        for ( my $i = 0; $i < length($data); $i += 16 ) {
            my $chunk = substr( $data, $i, 16 );
            my $hex   = join( ' ', map { sprintf( '%02X', ord($_) ) } split( //, $chunk ) );
            my $pad   = ' ' x ( 48 - length($hex) );
            my $asc   = join( '', map { $_ =~ /[ -~]/ ? $_ : '.' } split( //, $chunk ) );
            $out .= sprintf( "%08X  %s%s |%s|\n", $i, $hex, $pad, $asc );
        }
        return $out;
    }
    sub align ( $val, $align ) { ( $val + $align - 1 ) & ~( $align - 1 ) }
}

class Pulse::Emit::ARM64 {
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

    method mov_imm ( $reg, $imm ) {
        my $r = $REG{ lc $reg };

        # MOVZ xd, imm16
        $code .= pack( 'L<', 0xD2800000 | ( ( $imm & 0xFFFF ) << 5 ) | $r );
        if ( $imm > 0xFFFF ) {

            # MOVK xd, imm16, lsl 16
            $code .= pack( 'L<', 0xF2A00000 | ( 1 << 21 ) | ( ( ( $imm >> 16 ) & 0xFFFF ) << 5 ) | $r );
        }
        if ( $imm > 0xFFFFFFFF ) {

            # MOVK xd, imm16, lsl 32
            $code .= pack( 'L<', 0xF2C00000 | ( 2 << 21 ) | ( ( ( $imm >> 32 ) & 0xFFFF ) << 5 ) | $r );
        }
    }

    method mov_reg ( $dest, $src ) {
        my $d = $REG{ lc $dest };
        my $s = $REG{ lc $src };

        # ORR xd, xzr, xm (MOV xd, xm)
        $code .= pack( 'L<', 0xAA0003E0 | ( $s << 16 ) | $d );
    }

    method add_imm ( $reg, $imm ) {
        my $r = $REG{ lc $reg };

        # ADD xd, xn, imm12
        $code .= pack( 'L<', 0x91000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r );
    }

    method sub_imm ( $reg, $imm ) {
        my $r = $REG{ lc $reg };

        # SUB xd, xn, imm12
        $code .= pack( 'L<', 0xD1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r );
    }

    method cmp_reg_imm ( $reg, $imm ) {
        my $r = $REG{ lc $reg };

        # SUBS xzr, xn, imm12 (CMP xn, imm12)
        $code .= pack( 'L<', 0xF1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | 31 );
    }

    # PC-Relative Addressing
    method lea_rva ( $reg, $target_rva, $text_rva ) {
        my $r = $REG{ lc $reg };

        # ADR xd, label (21-bit offset)
        my $off   = $target_rva - ( $text_rva + length($code) );
        my $immlo = $off & 0x3;
        my $immhi = ( $off >> 2 ) & 0x7FFFF;
        $code .= pack( 'L<', 0x10000000 | ( $immlo << 29 ) | ( $immhi << 5 ) | $r );
    }

    method call_rva ( $target_rva, $text_rva ) {
        $self->lea_rva( 'x16', $target_rva, $text_rva );

        # LDR x16, [x16, #0] (Load from IAT)
        $code .= pack( 'L<', 0xF9400000 | ( 16 << 5 ) | 16 );

        # BLR x16 (Branch with Link to Register)
        $code .= pack( 'L<', 0xD63F0200 );
    }

    # System Calls
    method syscall {
        $code .= pack( 'L<', 0xD4000001 );    # SVC #0 (Supervisor Call)
    }

    # Control Flow
    method jcc ( $cc, $label ) {

        # B.cond (19-bit offset)
        # cc: 4 = EQ/Z, 0x0C = LT, 0x0D = LE, 0x0A = GE, 0x0B = GT
        push @fixups, { offset => length($code), target => $label, type => 'cond', cc => $cc };
        $code .= pack( 'L<', 0x54000000 | $cc );
    }

    method jmp ($label) {

        # B (26-bit PC-relative branch, 26-bit offset)
        push @fixups, { offset => length($code), target => $label, type => 'uncond' };
        $code .= pack( 'L<', 0x14000000 );
    }
    method mark_label ($name) { $labels{$name} = length $code }

    method resolve {
        for (@fixups) {
            my $target = $labels{ $_->{target} };
            my $off    = ( $target - $_->{offset} ) / 4;
            if ( $_->{type} eq 'cond' ) {

                # B.cond imm19
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( $off & 0x7FFFF ) << 5;
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
            else {
                # B imm26
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( $off & 0x3FFFFFF );
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
        }
    }
}

package Pulse::Emit::RISCV { }

class Pulse::Emit::X64 {
    our %REG = ( rax => 0, rcx => 1, rdx => 2, rbx => 3, rsp => 4, rbp => 5, rsi => 6, rdi => 7, r8 => 8, r9 => 9, r10 => 10, r11 => 11 );
    field $code : reader = '';
    field %labels;
    field @fixups;

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

    # Position Independent Addressing
    method lea_rva ( $reg, $target_rva, $text_rva ) {
        my $r        = $REG{ lc $reg };
        my $next_rip = $text_rva + length($code) + 7;
        $code .= $self->_rex( 1, $r, 0, 0 ) . pack( 'CC l<', 0x8D, 0x05 | ( ( $r & 7 ) << 3 ), $target_rva - $next_rip );
    }

    method call_rva( $target_rva, $text_rva ) {
        my $next_rip = $text_rva + length($code) + 6;
        $code .= pack( 'CC l<', 0xFF, 0x15, $target_rva - $next_rip );
    }

    # Stack / Memory SIB Addressing for Win64
    method lea_reg_disp ( $dest, $base, $disp ) {
        my $d = $REG{ lc $dest };
        my $b = $REG{ lc $base };
        $code .= $self->_rex( 1, $d, 0, $b );
        if ( $disp >= -128 && $disp <= 127 ) {
            $code .= pack( 'CC', 0x8D, 0x40 | ( ( $d & 7 ) << 3 ) | ( $b & 7 ) );
            $code .= pack( 'C',  0x24 ) if ( $b & 7 ) == 4;    # SIB byte for RSP
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
    method syscall { $code .= pack 'CC', 0x0F, 0x05 }

    # Control Flow
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

class Pulse::Format {
    method write_bin( $filename, $text, $data, $arch ) {...}
}

class Pulse::Format::MachO : isa(Pulse::Format) { }

class Pulse::Format::ELF : isa(Pulse::Format) {

    method write_bin ( $filename, $text, $data, $arch ) {
        my $base        = 0x400000;
        my $text_off    = 0x1000;
        my $data_off    = 0x2000;
        my $machine     = ( $arch eq 'arm64' ) ? 183 : 62;
        my $align       = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
        my $text_padded = $text . ( "\0" x ( $align->( length($text), 0x1000 ) - length($text) ) );
        my $data_padded = $data . ( "\0" x ( $align->( length($data), 0x1000 ) - length($data) ) );
        my $elf_hdr     = pack(
            'A4 C C C C C x7 S S L Q Q Q L S S S S S S',
            "\x7fELF", 2, 1, 1,  0,  0, 2, $machine, 1, $base + $text_off,
            0x40,      0, 0, 64, 56, 2, 0, 0,        0
        );
        my $ph_text = pack( 'LL Q Q Q Q Q Q', 1, 5, 0, $base, $base, $text_off + length($text_padded), $text_off + length($text_padded), 0x1000 );
        my $ph_data
            = pack( 'LL Q Q Q Q Q Q', 1, 6, $data_off, $base + $data_off, $base + $data_off, length($data_padded), length($data_padded), 0x1000 );
        open my $fh, '>', $filename or die $!;
        binmode $fh;
        print $fh $elf_hdr, $ph_text, $ph_data, ( "\0" x ( $text_off - ( 0x40 + 0x38 * 2 ) ) );
        print $fh $text_padded, $data_padded;
        close $fh;
        chmod 0755, $filename;
        return $filename;
    }
}

class Pulse::Format::PE : isa(Pulse::Format) {

    method write_bin ( $filename, $text, $data, $arch ) {
        my $fa          = 0x200;
        my $sa          = 0x1000;
        my $image_base  = hex '140000000';
        my $machine     = ( $arch eq 'arm64' ) ? 0xAA64 : 0x8664;
        my $align       = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
        my $text_padded = $text . ( "\0" x ( $align->( length($text), $fa ) - length($text) ) );
        my $data_padded = $data . ( "\0" x ( $align->( length($data), $fa ) - length($data) ) );
        my $text_rva    = $sa;
        my $data_rva    = $sa * 2;
        my $idata_rva   = $sa * 3;
        my @funcs       = qw[ExitProcess GetStdHandle WriteFile];
        my $iat_size    = ( @funcs + 1 ) * 8;
        my $rva_iat     = $idata_rva;
        my $rva_ilt     = $rva_iat + $iat_size;
        my $rva_dir     = $rva_ilt + $iat_size;
        my $rva_dll     = $rva_dir + 40;
        my $rva_hn      = $rva_dll + 16;
        my $iat_data    = '';
        my $hn_data     = '';

        for my $fn (@funcs) {
            $iat_data .= pack( 'Q<', $rva_hn + length($hn_data) );
            my $hn_entry = pack( 'S<', 0 ) . $fn . "\0";
            $hn_entry .= "\0" if length($hn_entry) % 2 != 0;
            $hn_data  .= $hn_entry;
        }
        $iat_data .= pack( 'Q<', 0 );
        my $import_dir   = pack( 'L< L< L< L< L<', $rva_ilt, 0, 0, $rva_dll, $rva_iat ) . ( "\0" x 20 );
        my $idata_raw    = $iat_data . $iat_data . $import_dir . pack( 'a16', 'kernel32.dll' ) . $hn_data;
        my $idata_padded = $idata_raw . ( "\0" x ( $align->( length($idata_raw), $fa ) - length($idata_raw) ) );
        my $headers_bin  = pack( 'S< x58 L<', 0x5A4D, 0x80 ) . pack( 'a64', "This program cannot be run in DOS mode.\r\r\n\$" );
        my $file_hdr     = pack( 'S< S< L< L< L< S< S<', $machine, 3, time(), 0, 0, 240, 0x0022 );
        my $opt_hdr      = pack(
            'S< C C L< L< L< L< L< Q< L< L< S< S< S< S< S< S< L< L< L< L< S< S< Q< Q< Q< Q< L< L<',
            0x20B, 14,        0,         length($text_padded), length($data_padded) + length($idata_padded),
            0,     $text_rva, $text_rva, $image_base,          $sa, $fa, 6, 0, 0, 0, 6, 0, 0, $align->( $idata_rva + length($idata_padded), $sa ),
            $fa,   0,         3,         0x8140,               0x100000, 0x1000, 0x100000, 0x1000, 0, 16
        );
        my $data_dirs = pack( 'L< L<', 0, 0 ) . pack( 'L< L<', $rva_dir, 40 ) . ( pack( 'L< L<', 0, 0 ) x 14 );
        my $sec_text  = pack( 'a8 L< L< L< L< L< L< S< S< L<', '.text', length($text), $text_rva, length($text_padded), $fa, 0, 0, 0, 0, 0x60000020 );
        my $sec_data  = pack(
            'a8 L< L< L< L< L< L< S< S< L<',
            '.data', length($data), $data_rva, length($data_padded), $fa + length($text_padded),
            0,       0,             0,         0,                    0xC0000040
        );
        my $sec_idata = pack(
            'a8 L< L< L< L< L< L< S< S< L<',
            '.idata', length($idata_raw), $idata_rva, length($idata_padded), $fa + length($text_padded) + length($data_padded),
            0,        0,                  0,          0,                     0xC0000040
        );
        my $full_header = $headers_bin . pack( 'L<', 0x00004550 ) . $file_hdr . $opt_hdr . $data_dirs . $sec_text . $sec_data . $sec_idata;
        $full_header .= ( "\0" x ( $align->( length($full_header), $fa ) - length($full_header) ) );
        substr( $full_header, 0x80 + 4 + 20 + 60, 4, pack( 'L<', length($full_header) ) );
        open my $fh, '>', $filename or die $!;
        binmode $fh;
        print $fh $full_header, $text_padded, $data_padded, $idata_padded;
        close $fh;
        return $filename;
    }
}

package Pulse::Syscall::SysV { }

package Pulse::Syscall::Windows { }

package Pulse::Syscall::ARM64 { }

package Pulse::Runtime::Memory { }

package Pulse::Runtime::Types { }

package Pulse::Lexer { }

package Pulse::Parser { }

class Pulse::Compiler {
    field $arch   : reader : param = undef;
    field $os     : reader : param = undef;
    field $as     : reader;
    field $data   : reader = '';
    field $format : reader;
    #
    field $label_count = 0;
    #
    ADJUST {
        my $d_os   = ( $^O eq 'MSWin32' ? 'win64' : 'linux' );
        my $d_arch = 'x64';
        if ( $^O eq 'MSWin32' ) {
            $d_arch = ( ( $ENV{PROCESSOR_ARCHITECTURE} // '' ) =~ /ARM64/i ) ? 'arm64' : 'x64';
        }
        else {
            my $m = `uname -m` // 'x86_64';
            $d_arch = 'arm64' if $m =~ /aarch64|arm64|armv8/i;
            use Config;
            $d_arch = 'arm64' if ( $Config{archname} // '' ) =~ /aarch64|arm64/i;
        }
        if ( @ARGV && $ARGV[0] =~ /^(?:linux|win64)-(?:x64|arm64)$/ ) {
            my $target = shift @ARGV;
            ( $os, $arch ) = split /-/, $target;
        }
        $os   //= $d_os;
        $arch //= $d_arch;
        $as     = $arch eq 'arm64' ? Pulse::Emit::ARM64->new() : Pulse::Emit::X64->new();
        $format = $os eq 'win64'   ? Pulse::Format::PE->new()  : Pulse::Format::ELF->new();
    }
    #
    method write_bin($path) { $format->write_bin( $path, $as->code, $data, $arch ) }
    #
    method cc ($name) {
        return { eq => 0, ne => 1, lt => 0xB, le => 0xD, gt => 0xC, ge => 0xA, z => 0, nz => 1 }->{$name} if $arch eq 'arm64';
        return { eq => 4, ne => 5, lt => 0xC, le => 0xE, gt => 0xF, ge => 0xD, z => 4, nz => 5 }->{$name};
    }

    method print_str ($str) {
        my $as  = $as;
        my $off = length $data;
        $data .= $str;
        if ( $os eq 'linux' ) {
            if ( $arch eq 'arm64' ) {
                $as->mov_imm( 'x8', 64 );    # write
                $as->mov_imm( 'x0', 1 );     # stdout
                $as->lea_rva( 'x1', 0x2000 + $off, 0x1000 );
                $as->mov_imm( 'x2', length($str) );
                $as->syscall();
            }
            else {
                $as->mov_imm( 'rax', 1 );
                $as->mov_imm( 'rdi', 1 );
                $as->lea_rva( 'rsi', 0x2000 + $off, 0x1000 );
                $as->mov_imm( 'rdx', length($str) );
                $as->syscall();
            }
        }
        else {
            if ( $arch eq 'arm64' ) {
                $as->mov_imm( 'x0', -11 );
                $as->call_rva( 0x3008, 0x1000 );    # IAT 1: GetStdHandle
                $as->mov_reg( 'x0', 'x0' );
                $as->lea_rva( 'x1', 0x2000 + $off, 0x1000 );
                $as->mov_imm( 'x2', length($str) );

                # Incomplete for Win-ARM64 but good enough for demo
                $as->call_rva( 0x3010, 0x1000 );
            }
            else {
                $as->mov_imm( 'rcx', -11 );
                $as->call_rva( 0x3008, 0x1000 );    # IAT 1: GetStdHandle
                $as->mov_reg( 'rcx', 'rax' );
                $as->lea_rva( 'rdx', 0x2000 + $off, 0x1000 );
                $as->mov_imm( 'r8', length($str) );

                # Win64 ABI specifies arg5 and arg6 go to stack offsets [rsp+32] and [rsp+40]
                # 4th arg (r9) is pointer to bytes_written. We point to [rsp+48]
                $as->lea_reg_disp( 'r9', 'rsp', 48 );
                $as->mov_imm( 'r10', 0 );
                $as->store_mem_disp_reg( 'rsp', 32, 'r10' );    # lpOverlapped = null
                $as->call_rva( 0x3010, 0x1000 );                # IAT 2: WriteFile
            }
        }
    }

    method exit_proc ($code) {
        if ( $os eq 'linux' ) {
            if ( $arch eq 'arm64' ) {
                $as->mov_imm( 'x8', 93 );                       # exit
                $as->mov_imm( 'x0', $code );
                $as->syscall();
            }
            else {
                $as->mov_imm( 'rax', 60 );
                $as->mov_imm( 'rdi', $code );
                $as->syscall();
            }
        }
        else {
            if ( $arch eq 'arm64' ) {
                $as->mov_imm( 'x0', $code );
                $as->call_rva( 0x3000, 0x1000 );
            }
            else {
                $as->mov_imm( 'rcx', $code );
                $as->call_rva( 0x3000, 0x1000 );    # IAT 0: ExitProcess
            }
        }
    }
    method _label () { 'L' . $label_count++; }

    method emit_if ( $cond_cb, $then_cb, $else_cb ) {
        my $l_else = $self->_label();
        my $l_end  = $self->_label();
        $cond_cb->($as);

        # Assume $cond_cb sets Zero Flag if false. JZ -> else
        $as->jcc( $self->cc('z'), $l_else );
        $then_cb->($as);
        $as->jmp($l_end) if $else_cb;
        $as->mark_label($l_else);
        $else_cb->($as) if $else_cb;
        $as->mark_label($l_end);
    }

    method emit_while ( $cond_cb, $body_cb ) {
        my $l_start = $self->_label();
        my $l_end   = $self->_label();
        $as->mark_label($l_start);
        $cond_cb->($as);
        $as->jcc( $self->cc('z'), $l_end );    # JZ -> end
        $body_cb->($as);
        $as->jmp($l_start);
        $as->mark_label($l_end);
    }

    method emit_alloc ( $size_bytes, $dest_reg ) {
        $size_bytes = Pulse::Util::align( $size_bytes, 8 );    # $size_bytes must be aligned to 8
        my $l_fast_path = $self->_label();
        my $l_end       = $self->_label();

        # Load Heap Pointers
        $as->lea_rva( 'r8', 0x2000 + 8,  0x1000 );             # R8 = address of alloc_ptr
        $as->lea_rva( 'r9', 0x2000 + 16, 0x1000 );             # R9 = address of limit_ptr
        if ( $arch eq 'x64' ) {
            $as->load_reg_mem( 'rax', 'r8' );                  # RAX = current alloc_ptr
            $as->load_reg_mem( 'rcx', 'r9' );                  # RCX = current limit_ptr

            # Check if we have enough space (alloc_ptr + size <= limit_ptr)
            $as->mov_reg( 'rdx', 'rax' );
            $as->add_imm( 'rdx', $size_bytes );
            $as->cmp_reg_reg( 'rdx', 'rcx' );
            $as->jcc( 0x0E, $l_fast_path );                    # JLE (Jump Less Equal) -> Fast Path

            # SLOW PATH: Trigger GC
            # Warning: This will call out to a compiled runtime function
            $as->mov_imm( 'rcx', $size_bytes );          # Pass size to GC
            $as->call_rva( 0x1000 + 0xDEAD, 0x1000 );    # Call GC_Collect (Address TBA)
            $as->mov_reg( 'rdx', 'rax' );

            # FAST PATH: Bump the pointer
            $as->mark_label($l_fast_path);
            $as->store_mem_reg( 'r8', 'rdx' );           # alloc_ptr = alloc_ptr + size
            $as->mark_label($l_end);
            $as->mov_reg( $dest_reg, 'rax' ) if $dest_reg ne 'rax';
        }
    }

    # try/catch using a shadow stack stored in .data
    method emit_try_catch ( $try_cb, $catch_cb ) {
        my $l_catch = $self->_label();
        my $l_end   = $self->_label();
        if ( $arch eq 'x64' ) {
            $as->mov_reg( 'r10', 'rsp' );
            $as->lea_rva( 'r8', 0x2000, 0x1000 );        # r8 = aslr safe address of shadow stack
            $as->load_reg_mem( 'r9', 'r8' );             # r9 = [head]
            $as->push_reg('r9');                         # Save prev head
            $as->lea_rip( 'r9', $l_catch );
            $as->push_reg('r9');                         # Save Catch Address
            $as->push_reg('rbp');                        # Save Frame Pointer
            $as->push_reg('rsp');                        # Save Stack Pointer (will be restored by throw)
            $as->store_mem_reg( 'r8', 'rsp' );           # [head] = new frame (rsp)
            $try_cb->($as);

            # If no exception, pop the frame and skip catch
            $as->lea_rva( 'r8', 0x2000, 0x1000 );
            $as->load_reg_mem_disp( 'r9', 'rsp', 24 );    # r9 = prev head
            $as->store_mem_reg( 'r8', 'r9' );             # [head] = prev head
            $as->add_imm( 'rsp', 32 );                    # cleanup 4 pushes
            $as->jmp($l_end);

            # Catch Block
            $as->mark_label($l_catch);
            $catch_cb->($as);
            $as->mark_label($l_end);
        }
    }

    method emit_throw ($err_code) {
        if ( $arch eq 'x64' ) {
            $as->mov_imm( 'rax', $err_code );             # RAX = Error Code
            $as->lea_rva( 'r8', 0x2000, 0x1000 );         # ASLR safe
            $as->load_reg_mem( 'r9', 'r8' );              # R9 = current frame (saved RSP)

            # Restore context from frame
            $as->load_reg_mem_disp( 'rsp', 'r9', 0 );     # RSP = saved_rsp
            $as->load_reg_mem_disp( 'rbp', 'r9', 8 );     # RBP = saved_rbp
            $as->load_reg_mem_disp( 'r10', 'r9', 16 );    # R10 = Catch Address
            $as->load_reg_mem_disp( 'r11', 'r9', 24 );    # R11 = prev head
            $as->store_mem_reg( 'r8', 'r11' );            # Pop frame from shadow stack
            $as->jmp_reg('r10');                          # Jump to catch
        }
    }

    method emit_tail_call ( $target_label, $frame_size = 0 ) {
        $as->add_imm( 'rsp', $frame_size ) if $frame_size > 0;
        $as->jmp($target_label);
    }
}
#
class Brocken::AST {

    class Brocken::AST::Class {
        field $name;
        field @fields;
        field @methods;

        class Brocken::AST::Method {
            field $name;
            field @params;
            field $body;
            field $returns;
        }
    }
}
#
class Brocken::Parser {
    field $lexer;
    field $current_token;

    method parse_class() {
        $self->expect('class');
        my $name = $self->expect('IDENTIFIER');
        my $node = Brocken::AST::Class->new( name => $name );
        $self->expect('{');
        while ( $current_token ne '}' ) {
            if ( $current_token eq 'field' )  { push @{ $node->fields },  $self->parse_field(); }
            if ( $current_token eq 'method' ) { push @{ $node->methods }, $self->parse_method(); }
        }
        $self->expect('}');
        return $node;
    }

    # ... and so on
}
#
my $p = Pulse::Compiler->new();
say 'Detected OS: ' . $p->os . ' Arch: ' . $p->arch;
my $as = $p->as;
#
# Windows ABI: Setup 32 bytes shadow space
if ( $p->os eq 'win64' && $p->arch eq 'x64' ) {
    $as->sub_imm( 'rsp', 56 );
}
$p->print_str("Pulse AOT Engine Starting...\n");

# Set Loop Counter
my $loop_reg = ( $p->arch eq 'arm64' ) ? 'x19' : 'rbx';
$as->mov_imm( $loop_reg, 1 );

# Loop Top Label
$as->mark_label('loop');
$p->print_str(" -> Inside Loop Iteration\n");
$as->add_imm( $loop_reg, 1 );
$as->cmp_reg_imm( $loop_reg, 4 );
$as->jcc( $p->cc('lt'), 'loop' );
$p->print_str("Done! Exiting with status 42.\n");
$p->exit_proc(42);
$as->resolve();
#
my $exe = $p->write_bin('pulse_output');
$exe = "./$exe" if $^O ne 'MSWin32';
say 'Exit code: ' . ( system($exe) >> 8 );
