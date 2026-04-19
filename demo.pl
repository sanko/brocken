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
        $code .= pack( 'L<', 0xD2800000 | ( ( $imm & 0xFFFF ) << 5 ) | $r );
        if ( ( $imm >> 16 ) & 0xFFFF ) {
            $code .= pack( 'L<', 0xF2A00000 | ( 1 << 21 ) | ( ( ( $imm >> 16 ) & 0xFFFF ) << 5 ) | $r );
        }
        if ( ( $imm >> 32 ) & 0xFFFF ) {
            $code .= pack( 'L<', 0xF2C00000 | ( 2 << 21 ) | ( ( ( $imm >> 32 ) & 0xFFFF ) << 5 ) | $r );
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

    method syscall( $macos = 0 ) {

        # For macOS ARM64, syscall number is in x16. Use SVC #0x80.
        # For Linux ARM64, syscall number is in x8. Use SVC #0.
        if ($macos) {
            $code .= pack( 'L<', 0xD4001001 );    # SVC #0x80
        }
        else {
            $code .= pack( 'L<', 0xD4000001 );    # SVC #0
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
    method syscall { $code .= pack 'CC', 0x0F, 0x05 }

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
    method write_bin( $filename, $text, $data, $arch, $os ) { }
}

class Pulse::Format::MachO : isa(Pulse::Format) {

    method write_bin ( $filename, $text, $data, $arch, $os = 'macos' ) {
        my $is_arm      = ( $arch eq 'arm64' );
        my $page_size   = $is_arm ? 0x4000     : 0x1000;
        my $cpu_type    = $is_arm ? 0x0100000C : 0x01000007;
        my $cpu_subtype = $is_arm ? 0x00000000 : 0x00000003;
        my $align_f     = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
        my $text_padded = $text . ( "\0" x ( $align_f->( length($text), $page_size ) - length($text) ) );
        my $data_padded = $data . ( "\0" x ( $align_f->( length($data), $page_size ) - length($data) ) );

        # 12 Load Commands for strict dyld/codesign compliance
        my $ncmds      = 12;
        my $sizeofcmds = 72 + 152 + 152 + 72 + 24 + 24 + 24 + 32 + 56 + 24 + 80 + 48;    # 760 bytes

        # Header (MH_PIE | MH_TWOLEVEL | MH_DYLDLINK | MH_NOUNDEFS)
        my $header = pack( 'L L L L L L L L', 0xFEEDFACF, $cpu_type, $cpu_subtype, 2, $ncmds, $sizeofcmds, 0x00200085, 0 );

        # LC_SEGMENT_64 (__PAGEZERO)
        my $lc_pagezero = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 72, "__PAGEZERO", 0, 0x100000000, 0, 0, 0, 0, 0, 0 );

        # LC_SEGMENT_64 (__TEXT) - Permissions RX (5)
        my $text_vmsize = 2 * $page_size;
        my $lc_text     = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 152, "__TEXT", 0x100000000, $text_vmsize, 0, $text_vmsize, 5, 5, 1, 0 );
        $lc_text .= pack(
            'a16 a16 Q Q L L L L L L L L',
            "__text", "__TEXT", 0x100000000 + $page_size,
            length($text_padded), $is_arm ? 14 : 12,
            $page_size, 0, 0, 0, $is_arm ? 0x80000400 : 0x00000400,
            0, 0, 0
        );

        # LC_SEGMENT_64 (__DATA) - Permissions RW (3)
        my $data_vmaddr = 0x100000000 + 2 * $page_size;
        my $lc_data     = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 152, "__DATA", $data_vmaddr, $page_size, 2 * $page_size, $page_size, 3, 3, 1, 0 );
        $lc_data .= pack(
            'a16 a16 Q Q L L L L L L L L',
            "__data", "__DATA", $data_vmaddr, length($data_padded),
            $is_arm ? 14 : 12,
            2 * $page_size,
            0, 0, 0, 0, 0, 0, 0
        );

        # LC_SEGMENT_64 (__LINKEDIT) - Permissions R (1)
        my $link_vmaddr  = 0x100000000 + 3 * $page_size;
        my $link_fileoff = 3 * $page_size;
        my $lc_linkedit  = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 72, "__LINKEDIT", $link_vmaddr, $page_size, $link_fileoff, $page_size, 1, 1, 0, 0 );

        # LC_MAIN (Entry point offset)
        my $lc_main = pack( 'L L Q Q', 0x80000028, 24, $page_size, 0 );

        # LC_BUILD_VERSION (macOS 11.0)
        my $lc_build = pack( 'L L L L L L', 0x32, 24, 1, 0x000B0000, 0x000B0000, 0 );

        # LC_UUID
        my $lc_uuid = pack( 'L L a16', 0x1B, 24, pack( "H*", "C0FFEE" . "0" x 26 ) );

        # LC_LOAD_DYLINKER
        my $lc_dyld = pack( 'L L L a20', 0x0E, 32, 12, "/usr/lib/dyld" );

        # LC_LOAD_DYLIB
        my $lc_dylib = pack( 'L L L L L L a32', 0x0C, 56, 24, 2, 0x01000000, 0x01000000, "/usr/lib/libSystem.B.dylib" );

        # LC_SYMTAB (Points to start of __LINKEDIT so codesign safely bounds it)
        my $lc_symtab = pack( 'L L L L L L', 0x02, 24, $link_fileoff, 0, $link_fileoff, 0 );

        # LC_DYSYMTAB (Required safely zeroed metadata for dyld parsing)
        my $lc_dysymtab = pack( 'L L' . 'L' x 18, 0x0B, 80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 );

        # LC_DYLD_INFO_ONLY (Also bound safely to the __LINKEDIT to prevent bounds underflow)
        my $lc_dyld_info = pack( 'L L L L L L L L L L L L',
            0x80000022, 48, $link_fileoff, 0, $link_fileoff, 0, $link_fileoff, 0, $link_fileoff, 0, $link_fileoff, 0 );
        open my $fh, '>', $filename or die $!;
        binmode $fh;

        # Write exactly 760 bytes of load commands + 32 bytes of Mach-O Header
        print $fh $header, $lc_pagezero, $lc_text, $lc_data, $lc_linkedit, $lc_main, $lc_build, $lc_uuid, $lc_dyld, $lc_dylib, $lc_symtab,
            $lc_dysymtab, $lc_dyld_info;

        # Pad up to $page_size boundary. This strictly isolates the header from the code.
        print $fh ( "\0" x ( $page_size - ( length($header) + $sizeofcmds ) ) );
        print $fh $text_padded;             # Page 1
        print $fh $data_padded;             # Page 2
        print $fh ( "\0" x $page_size );    # Page 3 (Empty space for `codesign` to overwrite)
        close $fh;
        chmod 0755, $filename;
        if ( $^O eq 'darwin' ) {
            system("codesign --force --sign - \"$filename\" >/dev/null 2>&1");
        }
        return $filename;
    }
}

class Pulse::Format::ELF : isa(Pulse::Format) {

    method write_bin ( $filename, $text, $data, $arch, $os = 'linux' ) {
        my $base        = 0x400000;
        my $text_off    = 0x1000;
        my $data_off    = 0x2000;
        my $machine     = ( $arch eq 'arm64' ) ? 183 : 62;
        my %osabis      = ( freebsd => 9, netbsd => 2, solaris => 6 );
        my $osabi       = $osabis{$os} // 0;
        my $align       = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
        my $text_padded = $text . ( "\0" x ( $align->( length($text), 0x1000 ) - length($text) ) );
        my $data_padded = $data . ( "\0" x ( $align->( length($data), 0x1000 ) - length($data) ) );
        my $elf_hdr     = pack(
            'A4 C C C C C x7 S S L Q Q Q L S S S S S S',
            "\x7fELF", 2, 1, 1,  $osabi, 0, 2, $machine, 1, $base + $text_off,
            0x40,      0, 0, 64, 56,     2, 0, 0,        0
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

    method write_bin ( $filename, $text, $data, $arch, $os = 'win64' ) {
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
        my $headers_bin  = pack( 'S< x58 L<', 0x5A4D, 0x80 ) . pack( 'a64', "This program cannot be run in DOS mode.\n\$" );
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

class Pulse::Lexer { }

class Pulse::Parser { }

class Pulse::Compiler {
    field $arch   : reader : param = undef;
    field $os     : reader : param = undef;
    field $as     : reader;
    field $data   : reader = '';
    field $format : reader;
    field $label_count = 0;
    #
    ADJUST {
        my $d_os = 'linux';
        $d_os = 'win64'     if $^O eq 'MSWin32';
        $d_os = 'macos'     if $^O eq 'darwin';
        $d_os = 'freebsd'   if $^O eq 'freebsd';
        $d_os = 'openbsd'   if $^O eq 'openbsd';
        $d_os = 'netbsd'    if $^O eq 'netbsd';
        $d_os = 'solaris'   if $^O eq 'solaris';
        $d_os = 'dragonfly' if $^O eq 'dragonfly';
        my $d_arch = 'x64';

        if ( $^O eq 'MSWin32' ) {
            $d_arch = ( ( $ENV{PROCESSOR_ARCHITECTURE} // '' ) =~ /ARM64/i ) ? 'arm64' : 'x64';
        }
        else {
            my $m = `uname -m` // 'x86_64';
            $d_arch = 'arm64' if $m =~ /aarch64|arm64|armv8/i;
            use Config;
            $d_arch = 'arm64' if ( $Config{archname} // '' ) =~ /aarch64|arm64|apple-arm64/i;
        }
        my $os_list = 'linux|win64|macos|freebsd|openbsd|netbsd|solaris|dragonfly';
        if ( @ARGV && $ARGV[0] =~ /^(?:$os_list)-(?:x64|arm64)$/ ) {
            my $target = shift @ARGV;
            ( $os, $arch ) = split /-/, $target;
        }
        $os   //= $d_os;
        $arch //= $d_arch;
        $as = $arch eq 'arm64' ? Pulse::Emit::ARM64->new() : Pulse::Emit::X64->new();
        if    ( $os eq 'win64' ) { $format = Pulse::Format::PE->new() }
        elsif ( $os eq 'macos' ) { $format = Pulse::Format::MachO->new() }
        else                     { $format = Pulse::Format::ELF->new() }
    }
    #
    method write_bin($path) { $format->write_bin( $path, $as->code, $data, $arch, $os ) }
    #
    method cc ($name) {
        return { eq => 0, ne => 1, lt => 0xB, le => 0xD, gt => 0xC, ge => 0xA, z => 0, nz => 1 }->{$name} if $arch eq 'arm64';
        return { eq => 4, ne => 5, lt => 0xC, le => 0xE, gt => 0xF, ge => 0xD, z => 4, nz => 5 }->{$name};
    }

    method print_str ($str) {
        my $as  = $as;
        my $off = length $data;
        $data .= $str;
        my $is_bsd_like = $os =~ /macos|freebsd|openbsd|netbsd|dragonfly|solaris/;
        if ( $os eq 'linux' || $is_bsd_like ) {
            if ( $arch eq 'arm64' ) {
                my $num = ( $os eq 'macos' ) ? 0x2000004 : ( $is_bsd_like ? 4 : 64 );    # write
                $as->mov_imm( $os eq 'macos' ? 'x16' : 'x8', $num );
                $as->mov_imm( 'x0', 1 );                                                 # stdout
                my $page_size = ( $os eq 'macos' ) ? 0x4000 : 0x1000;
                my $text_rva  = $page_size;
                my $data_rva  = 2 * $page_size;
                $as->lea_rva( 'x1', $data_rva + $off, $text_rva );
                $as->mov_imm( 'x2', length($str) );
                $as->syscall( $os eq 'macos' );
            }
            else {
                my $num = ( $os eq 'macos' ) ? 0x2000004 : ( $is_bsd_like ? 4 : 1 );
                $as->mov_imm( 'rax', $num );
                $as->mov_imm( 'rdi', 1 );
                my $page_size = ( $os eq 'macos' ) ? 0x1000 : 0x1000;
                my $text_rva  = $page_size;
                my $data_rva  = 2 * $page_size;
                $as->lea_rva( 'rsi', $data_rva + $off, $text_rva );
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
                $as->call_rva( 0x3010, 0x1000 );
            }
            else {
                $as->mov_imm( 'rcx', -11 );
                $as->call_rva( 0x3008, 0x1000 );                # IAT 1: GetStdHandle
                $as->mov_reg( 'rcx', 'rax' );
                $as->lea_rva( 'rdx', 0x2000 + $off, 0x1000 );
                $as->mov_imm( 'r8', length($str) );
                $as->lea_reg_disp( 'r9', 'rsp', 48 );
                $as->mov_imm( 'r10', 0 );
                $as->store_mem_disp_reg( 'rsp', 32, 'r10' );    # lpOverlapped = null
                $as->call_rva( 0x3010, 0x1000 );                # IAT 2: WriteFile
            }
        }
    }

    method exit_proc ($code) {
        my $is_bsd_like = $os =~ /macos|freebsd|openbsd|netbsd|dragonfly|solaris/;
        if ( $os eq 'linux' || $is_bsd_like ) {
            if ( $arch eq 'arm64' ) {
                my $num = ( $os eq 'macos' ) ? 0x2000001 : ( $is_bsd_like ? 1 : 93 );    # exit
                $as->mov_imm( $os eq 'macos' ? 'x16' : 'x8', $num );
                $as->mov_imm( 'x0', $code );
                $as->syscall( $os eq 'macos' );
            }
            else {
                my $num = ( $os eq 'macos' ) ? 0x2000001 : ( $is_bsd_like ? 1 : 60 );
                $as->mov_imm( 'rax', $num );
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
}
#
my $p = Pulse::Compiler->new();
say 'Detected OS: ' . $p->os . ' Arch: ' . $p->arch;
my $as = $p->as;
#
if ( $p->os eq 'win64' && $p->arch eq 'x64' ) {
    $as->sub_imm( 'rsp', 56 );
}
$p->print_str("Pulse AOT Engine Starting...\n");
my $loop_reg = ( $p->arch eq 'arm64' ) ? 'x19' : 'rbx';
$as->mov_imm( $loop_reg, 1 );
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
my $status = system($exe);
if ( $status == -1 ) {
    say "Failed to execute: $!";
}
elsif ( $status & 127 ) {
    printf "Child died with signal %d, %s coredump
", ( $status & 127 ), ( $status & 128 ) ? 'with' : 'without';
}
else {
    printf "Exit code: %d
", $status >> 8;
}
