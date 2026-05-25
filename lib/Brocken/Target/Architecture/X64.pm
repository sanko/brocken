use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
#
class Brocken::Target::Architecture::X64 {
    our %REG = (
        rax   => 0,  rcx   => 1,  rdx   => 2,  rbx   => 3,  rsp   => 4,  rbp   => 5,  rsi   => 6,  rdi   => 7,
        r8    => 8,  r9    => 9,  r10   => 10, r11   => 11, r12   => 12, r13   => 13, r14   => 14, r15   => 15,
        xmm0  => 0,  xmm1  => 1,  xmm2  => 2,  xmm3  => 3,  xmm4  => 4,  xmm5  => 5,  xmm6  => 6,  xmm7  => 7,
        xmm8  => 8,  xmm9  => 9,  xmm10 => 10, xmm11 => 11, xmm12 => 12, xmm13 => 13, xmm14 => 14, xmm15 => 15,
        '0' => 0, '1' => 1, '2' => 2, '3' => 3, '4' => 4, '5' => 5, '6' => 6, '7' => 7,
        '8' => 8, '9' => 9, '10' => 10, '11' => 11, '12' => 12, '13' => 13, '14' => 14, '15' => 15
    );
    field $code : reader = '';
    field @fixups;
    field %labels;
    method labels () { return \%labels }              # Returns the HASH reference
    method ret ()    { $code .= pack( 'C', 0xC3 ) }

    method _reg_idx($r) {
        my $idx = $REG{lc $r};
        die "Invalid register: $r" unless defined $idx;
        return $idx;
    }

    method _rex ( $w, $ri, $xi, $bi ) {
        my $rex = 0x40;
        $rex |= 0x08 if $w;
        $rex |= 0x04 if $ri >= 8;
        $rex |= 0x02 if $xi >= 8;
        $rex |= 0x01 if $bi >= 8;
        if ( !$w && ( ( $ri >= 4 && $ri <= 7 ) || ( $bi >= 4 && $bi <= 7 ) ) ) {
            return pack( 'C', $rex );
        }
        return ( $rex == 0x40 && !$w ) ? '' : pack( 'C', $rex );
    }

    method mov_imm ( $reg, $imm ) {
        my $ri = $self->_reg_idx($reg);
        die "mov_imm: imm is undefined" unless defined $imm;
        $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'Cq<', 0xB8 + ( $ri & 7 ), $imm );
    }

    method mov_reg( $dest, $src ) {
        my $di = $self->_reg_idx($dest);
        my $si = $self->_reg_idx($src);
        $code .= $self->_rex( 1, $si, 0, $di ) . pack( 'CC', 0x89, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
    }

    method mov_reg_to_sp($src) {
        $self->mov_reg('rsp', $src);
    }

    method add_imm ( $reg, $imm ) {
        my $ri = $self->_reg_idx($reg);
        $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xC0 | ( $ri & 7 ), $imm );
    }

    method add_reg_imm ( $dest, $src, $imm ) {
        my $di = $self->_reg_idx($dest);
        my $si = $self->_reg_idx($src);
        # Use LEA for add reg + imm
        $code .= $self->_rex( 1, $di, 0, $si );
        if ( $imm >= -128 && $imm <= 127 ) {
            $code .= pack( 'CC', 0x8D, 0x40 | ( ( $di & 7 ) << 3 ) | ( $si & 7 ) );
            $code .= pack( 'c',  $imm );
        }
        else {
            $code .= pack( 'CC', 0x8D, 0x80 | ( ( $di & 7 ) << 3 ) | ( $si & 7 ) );
            $code .= pack( 'l<', $imm );
        }
    }

    method sub_imm ( $reg, $imm ) {
        my $ri = $self->_reg_idx($reg);
        $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xE8 | ( $ri & 7 ), $imm );
    }

    method cmp_reg_imm ( $reg, $imm ) {
        my $ri = $self->_reg_idx($reg);
        $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xF8 | ( $ri & 7 ), $imm );
    }

    method rip_relative_mov ( $reg, $data_rva, $offset, $text_rva ) {
        my $ri       = $self->_reg_idx($reg);
        my $next_rip = $text_rva + length($code) + 7;
        my $disp     = $data_rva + $offset - $next_rip;
        $code .= $self->_rex( 1, $ri, 0, 0 ) . pack( 'CC l<', 0x8B, 0x05 | ( ( $ri & 7 ) << 3 ), $disp );
    }

    method call_rva( $target_rva, $text_rva ) {
        my $next_rip = $text_rva + length($code) + 6;
        $code .= pack( 'CC l<', 0xFF, 0x15, $target_rva - $next_rip );
    }

    method lea_reg_disp ( $dest, $base, $disp ) {
        my $di = $self->_reg_idx($dest);
        my $bi = $self->_reg_idx($base);
        $code .= $self->_rex( 1, $di, 0, $bi );
        if ( $disp >= -128 && $disp <= 127 ) {
            $code .= pack( 'CC', 0x8D, 0x40 | ( ( $di & 7 ) << 3 ) | ( $bi & 7 ) );
            $code .= pack( 'C',  0x24 ) if ( $bi & 7 ) == 4;
            $code .= pack( 'c',  $disp );
        }
        else {
            $code .= pack( 'CC', 0x8D, 0x80 | ( ( $di & 7 ) << 3 ) | ( $bi & 7 ) );
            $code .= pack( 'C',  0x24 ) if ( $bi & 7 ) == 4;
            $code .= pack( 'l<', $disp );
        }
    }

    method store_mem_disp_reg ( $base, $disp, $src ) {
        my $bi = $self->_reg_idx($base);
        my $si = $self->_reg_idx($src);
        $code .= $self->_rex( 1, $si, 0, $bi );
        if ( $disp >= -128 && $disp <= 127 ) {
            $code .= pack( 'CC', 0x89, 0x40 | ( ( $si & 7 ) << 3 ) | ( $bi & 7 ) );
            $code .= pack( 'C',  0x24 ) if ( $bi & 7 ) == 4;
            $code .= pack( 'c',  $disp );
        }
        else {
            $code .= pack( 'CC', 0x89, 0x80 | ( ( $si & 7 ) << 3 ) | ( $bi & 7 ) );
            $code .= pack( 'C',  0x24 ) if ( $bi & 7 ) == 4;
            $code .= pack( 'l<', $disp );
        }
    }
    method syscall( $os = '', $num = 0 ) { $code .= pack 'CC', 0x0F, 0x05 }
    method alloc_stack($size) { $self->sub_imm('rsp', $size) }
    method emit_mov_reg($dest, $src) { $self->mov_reg($dest, $src) }
    method emit_mov_imm($reg, $imm) { $self->mov_imm($reg, $imm) }
    method emit_syscall($num, @args) {
        $self->mov_imm('rax', $num);
        my @arg_regs = qw(rdi rsi rdx r10 r8 r9);
        for my $i (0 .. $#args) {
            $self->mov_imm($arg_regs[$i], $args[$i]) if defined $args[$i];
        }
        $self->syscall();
    }
    method emit_lea_label($reg, $label, $text_rva) { $self->lea_rva($reg, $label, $text_rva) }
    method emit_store_mem($base, $disp, $src) { $self->store_mem_disp_reg($base, $disp, $src) }
    method emit_label($name) { $self->mark_label($name) }
    method emit_branch_if_zero($reg, $label) {
        $self->cmp_reg_imm($reg, 0);
        $self->jcc(4, $label); # 4 is JZ/JE
    }
    method emit_branch_if_not_zero($reg, $label) {
        $self->cmp_reg_imm($reg, 0);
        $self->jcc(5, $label); # 5 is JNZ/JNE
    }
    method emit_call_label($label) { $self->call_label($label) }

    method jcc ( $cc, $label ) {
        $code .= pack( 'CC', 0x0F, 0x80 + ( $cc & 0xF ) );
        push @fixups, { offset => length($code), target => $label };
        $code .= pack( 'L<', 0 );
    }

    method jmp ($label) {
        $code .= pack( 'C', 0xE9 );
        push @fixups, { offset => length($code), target => $label };
        $code .= pack( 'L<', 0 );
    }
    method mark_label ($name) { $labels{$name} = length $code }

    method emit_print_str ( $os, $off, $len ) {
        if ( $os->is_posix ) {
            my $num = $os->syscall_write('x64');
            my $reg = $os->syscall_num_reg('x64');
            $self->mov_imm( $reg,  $num ) if defined $reg;
            $self->mov_imm( 'rdi', 1 );
            my $page_size = $os->page_size('x64');
            my $text_rva  = $os->text_rva || $page_size;
            my $data_rva  = $os->data_rva || (2 * $page_size);
            $os->write_syscall_args( $self, 'x64', $data_rva, $off, $text_rva, $len );
            $self->syscall( $os->name, $num );
        }
        else {
            my $text_rva = $os->text_rva;
            my $data_rva = $os->data_rva;
            $self->mov_imm( 'rcx', -11 );    # STD_OUTPUT_HANDLE
            $self->call_rva( $os->symbol_rva('GetStdHandle'), $text_rva );
            $self->mov_reg( 'rcx', 'rax' );
            $self->lea_rva( 'rdx', $data_rva + $off, $text_rva );
            $self->mov_imm( 'r8', $len );
            $self->lea_reg_disp( 'r9', 'rsp', 48 );
            $self->mov_imm( 'r10', 0 );
            $self->store_mem_disp_reg( 'rsp', 32, 'r10' );
            $self->call_rva( $os->symbol_rva('WriteFile'), $text_rva );
        }
    }

    method emit_exit_proc ( $os, $code_val ) {
        if ( $os->is_posix ) {
            my $num = $os->syscall_exit('x64');
            my $reg = $os->syscall_num_reg('x64');
            $self->mov_imm( $reg,  $num ) if defined $reg;
            $self->mov_imm( 'rdi', $code_val );
            $self->syscall( $os->name, $num );
        }
        else {
            $self->mov_imm( 'rcx', $code_val );
            $self->call_rva( $os->symbol_rva('ExitProcess'), $os->text_rva );
        }
    }

    method _emit_modrm( $opcode, $reg_name, $base_name, $disp, $w = 1, $prefix = '' ) {
        my $ri  = $self->_reg_idx($reg_name);
        my $bi  = $self->_reg_idx($base_name);
        my $mod = ( $disp == 0 && ( $bi & 7 ) != 5 ) ? 0 : ( $disp >= -128 && $disp <= 127 ? 1 : 2 );
        $code .= $self->_rex( $w, $ri, 0, $bi ) . $prefix . pack( 'C', $opcode ) . pack( 'C', ( $mod << 6 ) | ( ( $ri & 7 ) << 3 ) | ( $bi & 7 ) );
        $code .= pack( 'C', 0x24 ) if ( ( $bi & 7 ) == 4 );
        if    ( $mod == 1 )                                      { $code .= pack( 'c',  $disp ); }
        elsif ( $mod == 2 || ( $mod == 0 && ( $bi & 7 ) == 5 ) ) { $code .= pack( 'l<', $disp ); }
    }
    method append_code($bin) { $code .= $bin }
    method lock()            { $code .= pack( 'C', 0xF0 ) }
    method lea_rva ( $reg, $target, $txtrva = 0 ) {
        my $ri = $self->_reg_idx($reg);
        if ( $target =~ /^([A-Z_]|DATA:|TEXT:)/i ) {
            $code .= $self->_rex( 1, $ri, 0, 0 ) . pack( 'CC', 0x8D, 0x05 | ( ( $ri & 7 ) << 3 ) );
            push @fixups, { offset => length($code), target => $target };
            $code .= pack( 'L<', 0 );
        }
        else {
            my $next = $txtrva + length($code) + 7;
            $code .= $self->_rex( 1, $ri, 0, 0 ) . pack( 'CC l<', 0x8D, 0x05 | ( ( $ri & 7 ) << 3 ), $target - $next );
        }
    }
    method push_reg($r) {
        my $ri = $self->_reg_idx($r);
        if ( $ri >= 8 ) { $code .= pack( 'CC', 0x41, 0x50 | ( $ri & 7 ) ); }
        else            { $code .= pack( 'C', 0x50 | $ri ); }
    }
    method pop_reg($r) {
        my $ri = $self->_reg_idx($r);
        if ( $ri >= 8 ) { $code .= pack( 'CC', 0x41, 0x58 | ( $ri & 7 ) ); }
        else            { $code .= pack( 'C', 0x58 | $ri ); }
    }
    method cmp_reg_reg( $l, $r ) {
        my $li = $self->_reg_idx($l);
        my $ri = $self->_reg_idx($r);
        $code .= $self->_rex( 1, $ri, 0, $li ) .
            pack( 'CC', 0x39, 0xC0 | ( ( $ri & 7 ) << 3 ) | ( $li & 7 ) );
    }
    method cmp_reg_imm_32( $r, $i ) {
        my $ri = $self->_reg_idx($r);
        $code .= $self->_rex( 0, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xF8 | ( $ri & 7 ), $i );
    }
    method test_reg_reg( $l, $r ) {
        my $li = $self->_reg_idx($l);
        my $ri = $self->_reg_idx($r);
        $code .= $self->_rex( 1, $ri, 0, $li ) .
            pack( 'CC', 0x85, 0xC0 | ( ( $ri & 7 ) << 3 ) | ( $li & 7 ) );
    }
    method setcc( $cc, $r ) {
        my $ri = $self->_reg_idx($r);
        $code .= pack( 'C', 0x40 | ( $ri >= 8 ? 1 : 0 ) ) . pack( 'CCC', 0x0F, $cc, 0xC0 | ( $ri & 7 ) );
    }
    method store_mem_disp_byte( $b, $d, $s )      { $self->_emit_modrm( 0x88, $s, $b, $d, 0 ); }
    method load_reg_mem( $d, $s, $off = 0 )       { $self->_emit_modrm( 0x8B, $d, $s, $off, 1 ); }
    method load_reg_mem_byte( $d, $s, $off = 0 )  { $self->_emit_modrm( 0xB6, $d, $s, $off, 1, pack( 'C', 0x0F ) ); }
    method add_mem_disp_reg( $b, $d, $s, $w = 1 ) { $self->_emit_modrm( 0x01, $s, $b, $d, $w ); }
    method store_mem_disp_reg_byte( $b, $d, $s )  { $self->_emit_modrm( 0x88, $s, $b, $d, 0 ); }
    method sub_mem_disp_reg( $b, $d, $s, $w = 1 ) { $self->_emit_modrm( 0x29, $s, $b, $d, $w ); }
    method call_label($l) { $code .= pack( 'C', 0xE8 ); push @fixups, { offset => length($code), target => $l }; $code .= pack( 'L<', 0 ); }
    method call_reg($r)   { 
        my $ri = $self->_reg_idx($r);
        $code .= $self->_rex( 0, 0, 0, $ri ) . pack( 'C', 0xFF ) . pack( 'C', 0xD0 + ( $ri & 7 ) ); 
    }
    method jmp_reg($r)    { 
        my $ri = $self->_reg_idx($r);
        $code .= $self->_rex( 0, 0, 0, $ri ) . pack( 'C', 0xFF ) . pack( 'C', 0xE0 + ( $ri & 7 ) ); 
    }
    method mul_reg( $d, $s ) {
        my $di = $self->_reg_idx($d);
        my $si = $self->_reg_idx($s);
        $code .= $self->_rex( 1, $di, 0, $si ) .
            pack( 'CCC', 0x0F, 0xAF, 0xC0 | ( ( $di & 7 ) << 3 ) | ( $si & 7 ) );
    }
    method idiv_reg($src) { 
        my $si = $self->_reg_idx($src);
        $code .= $self->_rex( 1, 0, 0, $si ) . pack( 'CC', 0xF7, 0xF8 | ( $si & 7 ) ); 
    }
    method inc_byte_data($data_offset) {
        $code .= pack( 'CC', 0xFE, 0x05 );
        push @fixups, { offset => length($code), target => "DATA:$data_offset" };
        $code .= pack( 'l<', 0 );
    }
    method addsd_reg( $d, $s ) {
        my $di = $self->_reg_idx($d);
        my $si = $self->_reg_idx($s);
        $code .= pack( 'C', 0xF2 ) . $self->_rex( 0, $si, 0, $di ) . pack( 'CC', 0x0F, 0x58 ) . pack( 'C', 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
    }
    method subsd_reg( $d, $s ) {
        my $di = $self->_reg_idx($d);
        my $si = $self->_reg_idx($s);
        $code .= pack( 'C', 0xF2 ) . $self->_rex( 0, $si, 0, $di ) . pack( 'CC', 0x0F, 0x5C ) . pack( 'C', 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
    }
    method mulsd_reg( $d, $s ) {
        my $di = $self->_reg_idx($d);
        my $si = $self->_reg_idx($s);
        $code .= pack( 'C', 0xF2 ) . $self->_rex( 0, $si, 0, $di ) . pack( 'CC', 0x0F, 0x59 ) . pack( 'C', 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
    }
    method divsd_reg( $d, $s ) {
        my $di = $self->_reg_idx($d);
        my $si = $self->_reg_idx($s);
        $code .= pack( 'C', 0xF2 ) . $self->_rex( 0, $si, 0, $di ) . pack( 'CC', 0x0F, 0x5E ) . pack( 'C', 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
    }
    method ucomisd_reg( $d, $s ) {
        my $di = $self->_reg_idx($d);
        my $si = $self->_reg_idx($s);
        $code .= pack( 'C', 0x66 ) . $self->_rex( 0, $di, 0, $si ) . pack( 'CC', 0x0F, 0x2E ) . pack( 'C', 0xC0 | ( ( $di & 7 ) << 3 ) | ( $si & 7 ) );
    }
    method movq_reg_xmm( $d, $s ) {
        my $di = $self->_reg_idx($d);
        my $si = $self->_reg_idx($s);
        $code .= pack( 'C', 0x66 ) . $self->_rex( 1, $di, 0, $si ) . pack( 'CC', 0x0F, 0x6E ) . pack( 'C', 0xC0 | ( ( $di & 7 ) << 3 ) | ( $si & 7 ) );
    }
    method movq_xmm_reg( $d, $s ) {
        my $di = $self->_reg_idx($d);
        my $si = $self->_reg_idx($s);
        $code .= pack( 'C', 0x66 ) . $self->_rex( 1, $si, 0, $di ) . pack( 'CC', 0x0F, 0x7E ) . pack( 'C', 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
    }

    method resolve {
        for (@fixups) {
            my $target = $labels{ $_->{target} };
            substr( $code, $_->{offset}, 4, pack( 'l<', $target - ( $_->{offset} + 4 ) ) );
        }
    }
}
1;
