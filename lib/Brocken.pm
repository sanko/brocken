use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
#
class Brocken {
    field $arch   : reader : param = undef;
    field $os     : reader : param = undef;
    field $as     : reader;
    field $data   : reader = '';
    field $format : reader;
    field $label_count = 0;
    #
    ADJUST {
        warn $^O;
        my $d_os = 'linux';
        $d_os = 'win64'     if $^O eq 'MSWin32' || $^O eq 'cygwin';
        $d_os = 'macos'     if $^O eq 'darwin';
        $d_os = 'freebsd'   if $^O eq 'freebsd';
        $d_os = 'openbsd'   if $^O eq 'openbsd';
        $d_os = 'netbsd'    if $^O eq 'netbsd';
        $d_os = 'solaris'   if $^O eq 'solaris';
        $d_os = 'dragonfly' if $^O eq 'dragonfly';
        my $d_arch = 'x64';

        if ( $d_os eq 'win64' ) {
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
        $as
            = $arch eq 'arm64' ?
            do   { require Brocken::Target::ARM64; Brocken::Target::ARM64->new() }
            : do { require Brocken::Target::X64;   Brocken::Target::X64->new() };
        if    ( $os eq 'win64' ) { require Brocken::Target::Format::PE;    $format = Brocken::Target::Format::PE->new() }
        elsif ( $os eq 'macos' ) { require Brocken::Target::Format::MachO; $format = Brocken::Target::Format::MachO->new() }
        else                     { require Brocken::Target::Format::ELF;   $format = Brocken::Target::Format::ELF->new() }
    }
    #
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
    #
    method write_bin($path) {
        $path = $os eq 'win64' ? "./$path.exe" : "./$path";
        $format->write_bin( $path, $as->code, $data, $arch, $os );
    }
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
                $as->call_rva( 0x3008, 0x1000 );      # IAT 1: GetStdHandle
                $as->mov_reg( 'x0', 'x0' );
                $as->lea_rva( 'x1', 0x2000 + $off, 0x1000 );
                $as->mov_imm( 'x2', length($str) );
                $as->mov_imm( 'x4', 0 );              # lpOverlapped = null
                $as->call_rva( 0x3010, 0x1000 );      # IAT 2: WriteFile
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
1;
