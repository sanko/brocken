use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
#
class Brocken v0.0.1 {
    field $arch      : reader : param = undef;
    field $os        : reader : param = undef;
    field $as        : reader;
    field $data      : reader = '';
    field $format    : reader;
    field $target_os : reader;
    field $abi       : reader;
    field $label_count = 0;
    #
    field %exports;    # Attempt to generate shared libs

    #
    ADJUST {
        require Brocken::Target::OS;
        require Brocken::Target::ABI;
        my $d_host_os = Brocken::Target::OS->detect_host();
        my $d_os_name = $d_host_os->name;
        my $d_arch    = 'x64';
        if ( $d_os_name eq 'win64' ) {
            $d_arch = ( ( $ENV{PROCESSOR_ARCHITECTURE} // '' ) =~ /ARM64/i ) ? 'arm64' : 'x64';
        }
        else {
            my $m = `uname -m` // 'x86_64';
            $d_arch = 'arm64'   if $m =~ /aarch64|arm64|armv8/i;
            $d_arch = 'riscv64' if $m =~ /riscv64/i;
            use Config;
            $d_arch = 'arm64' if ( $Config{archname} // '' ) =~ /aarch64|arm64|apple-arm64/i;
        }
        my $os_list = 'linux|win64|macos|freebsd|openbsd|netbsd|solaris|dragonfly|midnightbsd|haiku';
        if ( @ARGV && $ARGV[0] =~ /^(?:$os_list)-(?:x64|arm64|riscv64)$/ ) {
            my $target = shift @ARGV;
            ( $os, $arch ) = split /-/, $target;
        }
        $os   //= $d_os_name;
        $arch //= $d_arch;
        $target_os = Brocken::Target::OS->from_name($os);
        $abi       = Brocken::Target::ABI->new();
        $as
            = $arch eq 'arm64'   ? do { require Brocken::Target::Architecture::ARM64;   Brocken::Target::Architecture::ARM64->new(os_name => $target_os->name) }
            : $arch eq 'riscv64' ? do { require Brocken::Target::Architecture::RISCV64; Brocken::Target::Architecture::RISCV64->new() }
            :                      do { require Brocken::Target::Architecture::X64;     Brocken::Target::Architecture::X64->new() };
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
        $path = $target_os->exe_name($path);
        $format->write_bin( $path, $as->code, $data, $arch, $os );
    }
    #
    method export_label ($label) { $exports{$label} = 1; }

    method write_lib( $path, $manual_exports = undef ) {
        my $ext = $target_os->lib_ext;
        $path .= $ext unless $path =~ /\Q$ext\E$/;
        my $export_map;
        if ( defined $manual_exports ) {

            # If user passed a hashref, use it
            $export_map = $manual_exports;
        }
        else {
            # Auto-export everything currently in the label table
            $export_map = $as->labels();
        }
        $format->write_lib( $path, $as->code, $data, $arch, $os, $export_map );
        return $path;
    }
    #
    method cc ($name) {
        return $abi->cc( $arch, $name );
    }

    method print_str ($str) {
        my $off = length $data;
        $data .= $str;
        $as->emit_print_str( $target_os, $off, length($str) );
    }

    method exit_proc ($code) {
        $as->emit_exit_proc( $target_os, $code );
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
} 1;
