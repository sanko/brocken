use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', 'blib/lib', '../../blib/lib';
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
$|++;
#
class Brocken::Compiler { }

package Brocken::Katsuro {

    class Brocken::Katsuro::Platform {

        #~ https://wiki.osdev.org/Target_Triplet
        #~ https://github.com/ziglang/zig/issues/20690
        #~ https://mcyoung.xyz/2025/04/14/target-triples/
        #~ https://llvm.org/doxygen/Triple_8h_source.html
        #~ <arch>[.<cpu>[+~feats]]
        #~ -<os>[.<ver>]
        #~ [-<api>[.<ver>]
        #~ [-<abi>[+~opts]]]
        my %known_vendor = map { $_ => 1 } qw(
            pc apple unknown w64 ibm hp sun amd
            nintendo sony mti nvidia fortanix risc0
            esp lynx unikraft kmc wrs
        );
        use Config;

        # Hide stderr appropriately for the host OS shell
        sub get_cmd_output($cmd) {
            my $redirect = ( $^O =~ /MSWin32/i ) ? '2> NUL' : '2> /dev/null';
            my $output   = `$cmd $redirect`;

            # If the command succeeded and returned text
            if ( $? == 0 && defined $output && $output !~ /^\s*$/ ) {
                chomp $output;
                return $output;
            }
            return undef;
        }

        sub normalize_triple($raw) {
            my @parts = split( /-/, $raw );

            # Canonicalize architecture names before parsing
            $parts[0] = 'aarch64' if ( $parts[0] // '' ) =~ /^arm64$/i;
            $parts[0] = 'x86_64'  if ( $parts[0] // '' ) =~ /^(amd64|x64)$/i;
            $parts[0] = 'i386'    if ( $parts[0] // '' ) =~ /^i[3456]86$/i;
            return join( '-', @parts ) if @parts == 4;
            if ( @parts == 3 ) {
                my ( $p1, $p2, $p3 ) = @parts;
                return join( '-', $p1, $p2,  $p3,       'macho' ) if $p2 eq 'apple' && $p3 =~ /darwin/i;
                return join( '-', $p1, 'pc', $p2,       $p3 )     if $p2 eq 'linux';
                return join( '-', $p1, 'pc', 'windows', 'gnu' )   if $p2 =~ /w64/i && $p3 =~ /mingw/i;

                # Handle arch--os (empty vendor)
                if ( $p2 eq '' ) { return join( '-', $p1, 'unknown', $p3, 'unknown' ) }
                return $known_vendor{$p2} ? join( '-', $p1, $p2, $p3, 'unknown' ) : join( '-', $p1, 'unknown', $p2, $p3 );
            }
            if ( @parts == 2 ) { return join( '-', $parts[0], 'unknown', $parts[1], 'unknown' ) }
            push @parts, 'unknown' while @parts < 4;
            return join( '-', @parts[ 0 .. 3 ] );
        }

        sub gen_triple() {
            state $cached_host_triple;
            return $cached_host_triple if defined $cached_host_triple;
            my $clang_out = get_cmd_output('clang --print-target-triple');
            if ($clang_out) {
                if ( $^O eq 'midnightbsd' ) { $clang_out =~ s/\bfreebsd[^-]*/midnightbsd/gi }
                return $cached_host_triple = normalize_triple($clang_out);
            }
            my $gcc_out = get_cmd_output('gcc -dumpmachine');
            if ($gcc_out) {
                if ( $^O eq 'midnightbsd' ) { $gcc_out =~ s/\bfreebsd[^-]*/midnightbsd/gi }
                return $cached_host_triple = normalize_triple($gcc_out);
            }
            my ( $arch, $vendor, $os, $env ) = ('unknown') x 4;
            if ( $^O =~ /MSWin32|msys|cygwin/i ) {
                $vendor = 'pc';
                $os     = 'windows';
                $env    = ( $Config{cc} =~ /cl(\.exe)?$/i ) ? 'msvc' : 'gnu';
                my $win_arch = $ENV{PROCESSOR_ARCHITEW6432} || $ENV{PROCESSOR_ARCHITECTURE} || '';
                if    ( $win_arch =~ /^ARM64$/i ) { $arch = 'aarch64' }
                elsif ( $win_arch =~ /^ARM$/i )   { $arch = 'arm' }
                elsif ( $win_arch =~ /^AMD64$/i ) { $arch = 'x86_64' }
                elsif ( $win_arch =~ /^x86$/i )   { $arch = 'i386' }
            }
            else {
                eval { require POSIX; my @uname = POSIX::uname(); $arch = $uname[4] };
                if ( $arch eq 'unknown' || $@ ) { $arch = $Config{archname}; $arch =~ s/-.*// }
                $arch = lc($arch);
                $arch = 'x86_64'  if $arch eq 'amd64';
                $arch = 'aarch64' if $arch =~ /aarch64|arm64/i;
                $arch = 'i386'    if $arch =~ /^i[3456]86$/;
                if ( $^O eq 'linux' ) {
                    $vendor = 'pc';
                    $os     = 'linux';
                    $env    = 'gnu';
                    my $ldd_output = `ldd --version 2>/dev/null` || '';
                    $env = 'musl'      if -f '/etc/alpine-release' || $ldd_output =~ /musl/i;
                    $env = 'gnueabihf' if $arch =~ /^arm/;
                }
                elsif ( $^O eq 'darwin' )                 { $vendor = 'apple';   $os = 'darwin';      $env = 'macho' }
                elsif ( $^O eq 'haiku' )                  { $vendor = 'pc';      $os = 'haiku';       $env = 'elf' }
                elsif ( $^O eq 'midnightbsd' )            { $vendor = 'pc';      $os = 'midnightbsd'; $env = 'elf' }
                elsif ( $^O =~ /bsd/i )                   { $vendor = 'pc';      $os = $^O;           $env = 'elf' }
                elsif ( $^O =~ /solaris|sunos|illumos/i ) { $vendor = 'unknown'; $os = 'solaris';     $env = 'elf' }
            }
            $cached_host_triple = join '-', $arch || 'unknown', $vendor || 'unknown', $os || 'unknown', $env || 'unknown';
        }

        sub parse( $platform //= gen_triple() ) {
            $platform = normalize_triple($platform);
            my $host_triple = gen_triple();
            my $is_native   = ( $platform eq $host_triple ) ? 1 : 0;
            my ( $arch, $vendor, $os, $env ) = split /-/, $platform;
            my $class = 'Brocken::Katsuro::Platform';
            if    ( $os =~ /linux/i )                                       { $class = 'Brocken::Katsuro::Platform::Linux' }
            elsif ( $os =~ /darwin|macos|ios/i )                            { $class = 'Brocken::Katsuro::Platform::MacOS' }
            elsif ( $os =~ /windows|win32|mswin/i )                         { $class = 'Brocken::Katsuro::Platform::Windows' }
            elsif ( $os =~ /midnightbsd/i )                                 { $class = 'Brocken::Katsuro::Platform::MidnightBSD' }
            elsif ( $os =~ /freebsd/i )                                     { $class = 'Brocken::Katsuro::Platform::FreeBSD' }
            elsif ( $os =~ /openbsd/i )                                     { $class = 'Brocken::Katsuro::Platform::OpenBSD' }
            elsif ( $os =~ /netbsd/i )                                      { $class = 'Brocken::Katsuro::Platform::NetBSD' }
            elsif ( $os =~ /dragonfly/i )                                   { $class = 'Brocken::Katsuro::Platform::DragonflyBSD' }
            elsif ( $os =~ /bsd/i )                                         { $class = 'Brocken::Katsuro::Platform::BSD' }
            elsif ( $os =~ /^haiku$/i )                                     { $class = 'Brocken::Katsuro::Platform::Haiku' }
            elsif ( $arch =~ /^wasm/ || $os =~ /wasi/i || $env =~ /wasi/i ) { $class = 'Brocken::Katsuro::Platform::Wasm' }
            my $friendly;
            $class->new( arch => $arch, vendor => $vendor, os => $os, env => $env, friendly => $friendly, is_native => $is_native );
        }
        field $arch      : reader : param;
        field $vendor    : reader : param;
        field $os        : reader : param = ();
        field $env       : reader : param = ();
        field $friendly  : reader : param = ();
        field $is_native : reader : param = 0;
        field $abi       : reader = Brocken::Katsuro::Platform::ABI->parse($arch);
        ADJUST {
            if ( !defined $friendly ) {
                if ( $vendor eq 'apple' ) {
                    if ( $arch eq 'aarch64' ) {
                        if    ( $os eq 'darwin' )   { $friendly = 'macOS on Apple Silicon' }
                        elsif ( $os eq 'ios' )      { $friendly = 'iOS' }
                        elsif ( $os eq 'tvos' )     { $friendly = 'Apple TV' }
                        elsif ( $os eq 'visionos' ) { $friendly = 'Apple Vision' }
                        elsif ( $os eq 'watchos' )  { $friendly = 'Apple Watch' }
                    }
                    elsif ( $arch eq 'x86_64' ) {
                        if    ( $os eq 'darwin' )  { $friendly = 'macOS on Intel' }
                        elsif ( $os eq 'watchos' ) { $friendly = 'Apple Watch Simulator' }
                    }
                }
                if ( !defined $friendly ) {
                    my $os_name = ucfirst($os);
                    $os_name = 'Windows'       if $os =~ /windows|win32|mswin/i;
                    $os_name = 'macOS'         if $os =~ /darwin|macos/i;
                    $os_name = 'Linux'         if $os =~ /linux/i;
                    $os_name = 'FreeBSD'       if $os =~ /freebsd/i;
                    $os_name = 'OpenBSD'       if $os =~ /openbsd/i;
                    $os_name = 'NetBSD'        if $os =~ /netbsd/i;
                    $os_name = 'Haiku'         if $os =~ /haiku/i;
                    $os_name = 'Solaris'       if $os =~ /solaris/i;
                    $os_name = 'OmniOS'        if $os =~ /omnios/i;
                    $os_name = 'MidnightBSD'   if $os =~ /midnightbsd/i;
                    $os_name = 'DragonFly BSD' if $os =~ /dragonflybsd/i;
                    $os_name = 'WebAssembly'   if $self->is_wasm;
                    my $arch_name = $arch;
                    $arch_name = 'x64'    if $arch eq 'x86_64';
                    $arch_name = 'ARM64'  if $arch =~ /aarch64|arm64/i;
                    $arch_name = 'RISC-V' if $arch =~ /riscv/i;
                    $arch_name = 'Wasm'   if $arch =~ /wasm/i;

                    if ( $os_name eq 'WebAssembly' ) {
                        $friendly = "WebAssembly ($arch_name)";
                    }
                    elsif ( $os_name eq 'Unknown' && $arch_name eq 'unknown' ) {
                        $friendly = 'sand that does math';
                    }
                    else {
                        $friendly = "$os_name on $arch_name";
                    }
                }
            }
        }
        #
        method bin_ext()        {''}
        method lib_ext()        {'.so'}
        method format()         {'elf'}
        method abi_name()       { $self->env }
        method lib_prefix()     {'lib'}
        method bin_name($name)  { $name . $self->bin_ext }
        method static_lib_ext() {'.a'}

        method static_lib_name($name) {
            $self->lib_prefix . $name . $self->static_lib_ext;
        }

        method shared_lib_name( $name, $version = undef ) {
            my $base = $self->lib_prefix . $name . $self->lib_ext;
            return $base if !defined $version;
            return "$base.$version";
        }
        method is_windows()      {0}
        method is_macos()        {0}
        method is_linux()        {0}
        method is_bsd()          {0}
        method is_freebsd()      {0}
        method is_netbsd()       {0}
        method is_openbsd()      {0}
        method is_haiku()        {0}
        method is_midnightbsd()  {0}
        method is_dragonflybsd() {0}
        method is_wasm()         {0}
        method is_posix()        {1}
        #
        method is_arm64()   { $self->arch eq 'aarch64' }
        method is_riscv64() { $self->arch eq 'riscv64' }
        method is_x64()     { $self->arch eq 'x86_64' }
        #
        #~ Syscall Defaults (BSD family)
        method syscalls() {
            return {
                x86_64 => {
                    write     => 4,
                    read      => 3,
                    open      => 5,
                    close     => 6,
                    exit      => 1,
                    fork      => 2,
                    getpid    => 20,
                    wait4     => 7,
                    mmap      => 477,
                    nanosleep => 240,
                    brk       => 45
                },
                aarch64 => {
                    write     => 4,
                    read      => 3,
                    open      => 5,
                    close     => 6,
                    exit      => 1,
                    fork      => 2,
                    getpid    => 20,
                    wait4     => 7,
                    mmap      => 477,
                    nanosleep => 240,
                    brk       => 45
                },
                riscv64 => {
                    write     => 4,
                    read      => 3,
                    open      => 5,
                    close     => 6,
                    exit      => 1,
                    fork      => 2,
                    getpid    => 20,
                    wait4     => 7,
                    mmap      => 477,
                    nanosleep => 240,
                    brk       => 45
                },
            };
        }
        method syscall($name) { $self->syscalls->{ $self->arch }{$name} }

        method syscall_num_reg() {
            my %map = ( x86_64 => 'rax', aarch64 => 'x8', riscv64 => 'a7' );
            return $map{ $self->arch };
        }

        method syscall_ret_reg() {
            my %map = ( x86_64 => 'rax', aarch64 => 'x0', riscv64 => 'a0' );
            return $map{ $self->arch };
        }

        method page_size() {
            return 0x4000 if $self->arch =~ /aarch64|arm64/i;
            return 0x1000;
        }

        #~ Register queries from ABI
        method registers( $category = 'available' ) { $self->abi->registers($category) }
        method caller_saved()                       { $self->abi->caller_saved }
        method callee_saved()                       { $self->abi->callee_saved }
        method frame_reg()                          { $self->abi->frame_reg }
        method stack_reg()                          { $self->abi->stack_reg }

        class Brocken::Katsuro::Platform::ABI {

            sub parse ( $class, $arch ) {
                if    ( $arch =~ /x86_64|x64|amd64/i ) { return Brocken::Katsuro::Platform::ABI::X86_64->new }
                elsif ( $arch =~ /aarch64|arm64/i )    { return Brocken::Katsuro::Platform::ABI::AArch64->new }
                elsif ( $arch =~ /riscv64/i )          { return Brocken::Katsuro::Platform::ABI::RISCV64->new }
                return $class->new;
            }
            method registers( $category = 'available' ) { [] }
            method caller_saved()                       { $self->registers('caller') }
            method callee_saved()                       { $self->registers('callee') }
            method frame_reg()                          {undef}
            method stack_reg()                          {undef}
            method dwarf_reg_num($name)                 {undef}
        }

        class Brocken::Katsuro::Platform::ABI::X86_64 : isa(Brocken::Katsuro::Platform::ABI) {

            method registers( $category = 'available' ) {
                my %data = (
                    available => [qw[rax rcx rdx rbx rsi rdi r8 r9 r10 r11 r12 r13 r14 r15]],
                    caller    => [qw[rax rcx rdx rsi rdi r8 r9 r10 r11]],
                    callee    => [qw[rbx r12 r13 r14 r15]]
                );
                return $data{$category} // [];
            }
            method frame_reg() {'rbp'}
            method stack_reg() {'rsp'}

            # System V AMD64 DWARF register numbers (rax=0, rdx=1, etc.)
            method dwarf_reg_num($name) {
                my %map = (
                    rax => 0,
                    rdx => 1,
                    rcx => 2,
                    rbx => 3,
                    rsi => 4,
                    rdi => 5,
                    rbp => 6,
                    rsp => 7,
                    r8  => 8,
                    r9  => 9,
                    r10 => 10,
                    r11 => 11,
                    r12 => 12,
                    r13 => 13,
                    r14 => 14,
                    r15 => 15
                );
                return $map{$name};
            }
        }

        class Brocken::Katsuro::Platform::ABI::AArch64 : isa(Brocken::Katsuro::Platform::ABI) {

            method registers( $category = 'available' ) {
                my %data = (
                    available => [qw[x0 x1 x2 x3 x4 x5 x6 x7 x9 x10 x11 x12 x13 x14 x15 x20 x21 x22 x23 x24 x25 x26 x27 x28]],
                    caller    => [qw[x0 x1 x2 x3 x4 x5 x6 x7 x9 x10 x11 x12 x13 x14 x15]],
                    callee    => [qw[x20 x21 x22 x23 x24 x25 x26 x27 x28]]
                );
                return $data{$category} // [];
            }
            method frame_reg() {'x29'}
            method stack_reg() {'sp'}    # ARM64 standard DWARF mappings: x0-x30 map to 0-30, sp maps to 31

            method dwarf_reg_num($name) {
                return 31 if $name eq 'sp';
                return $1 if $name =~ /^x(\d+)$/;
                return undef;
            }
        }

        class Brocken::Katsuro::Platform::ABI::RISCV64 : isa(Brocken::Katsuro::Platform::ABI) {

            method registers( $category = 'available' ) {
                my %data = (
                    available => [qw[a0 a1 a2 a3 a4 a5 a6 a7 s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t0 t1 t2 t3 t4 t5 t6]],
                    caller    => [qw[a0 a1 a2 a3 a4 a5 a6 a7 t0 t1 t2 t3 t4 t5 t6]],
                    callee    => [qw[s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11]]
                );
                return $data{$category} // [];
            }
            method frame_reg() {'s0'}
            method stack_reg() {'sp'}    # RISC-V ABI register mappings to x0-x31 (zero=0, ra=1, sp=2, etc.)

            method dwarf_reg_num($name) {
                my %map = (
                    zero => 0,
                    ra   => 1,
                    sp   => 2,
                    gp   => 3,
                    tp   => 4,
                    t0   => 5,
                    t1   => 6,
                    t2   => 7,
                    s0   => 8,
                    fp   => 8,
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
                    t6   => 31
                );
                return $map{$name} // ( $name =~ /^x(\d+)$/ ? $1 : undef );
            }
        }
    }

    class Brocken::Katsuro::Platform::Linux : isa(Brocken::Katsuro::Platform) {
        method is_linux() {1}
        method format()   {'elf'}

        method syscalls() {
            return {
                x86_64 => {
                    write     => 1,
                    read      => 0,
                    open      => 2,
                    close     => 3,
                    exit      => 60,
                    fork      => 57,
                    getpid    => 39,
                    wait4     => 61,
                    mmap      => 9,
                    nanosleep => 35,
                    futex     => 202,
                    brk       => 12
                },
                aarch64 => {
                    write     => 64,
                    read      => 63,
                    open      => 56,
                    close     => 57,
                    exit      => 93,
                    fork      => 220,
                    getpid    => 172,
                    wait4     => 260,
                    mmap      => 222,
                    nanosleep => 101,
                    futex     => 98,
                    brk       => 214
                },
                riscv64 => {
                    write     => 64,
                    read      => 63,
                    open      => 56,
                    close     => 57,
                    exit      => 93,
                    fork      => 220,
                    getpid    => 172,
                    wait4     => 260,
                    mmap      => 222,
                    nanosleep => 101,
                    futex     => 98,
                    brk       => 214
                },
            };
        }
    }

    class Brocken::Katsuro::Platform::MacOS : isa(Brocken::Katsuro::Platform) {
        method is_macos() {1}
        method lib_ext()  {'.dylib'}
        method format()   {'macho'}

        method shared_lib_name( $name, $version = undef ) {
            my $pre = $self->lib_prefix . $name;
            return $pre . $self->lib_ext if !defined $version;
            return "$pre.$version" . $self->lib_ext;
        }

        method syscalls() {
            my $off64 = 0x2000000;
            return {
                x86_64 => {
                    write     => $off64 + 4,
                    read      => $off64 + 3,
                    open      => $off64 + 5,
                    close     => $off64 + 6,
                    exit      => $off64 + 1,
                    fork      => $off64 + 2,
                    getpid    => $off64 + 20,
                    wait4     => $off64 + 7,
                    mmap      => $off64 + 197,
                    nanosleep => $off64 + 101,
                    brk       => $off64 + 45
                },
                aarch64 => {
                    write     => $off64 + 4,
                    read      => $off64 + 3,
                    open      => $off64 + 5,
                    close     => $off64 + 6,
                    exit      => $off64 + 1,
                    fork      => $off64 + 2,
                    getpid    => $off64 + 20,
                    wait4     => $off64 + 11,
                    mmap      => $off64 + 197,
                    nanosleep => $off64 + 101,
                    brk       => $off64 + 45
                }
            };
        }

        method syscall_num_reg() {
            my %map = ( x86_64 => 'rax', aarch64 => 'x16', riscv64 => 'a7' );
            return $map{ $self->arch };
        }
    }

    class Brocken::Katsuro::Platform::Windows : isa(Brocken::Katsuro::Platform) {
        method is_windows() {1}
        method is_posix()   {0}
        method bin_ext()    {'.exe'}
        method lib_ext()    {'.dll'}
        method format()     {'pe'}
        method lib_prefix() {''}

        method static_lib_ext() {
            return '.a' if $self->env eq 'gnu';
            return '.lib';
        }

        method shared_lib_name( $name, $version = undef ) {
            return $name . $self->lib_ext if !defined $version;
            return $name . '-' . $version . $self->lib_ext;
        }
    }

    class Brocken::Katsuro::Platform::BSD : isa(Brocken::Katsuro::Platform) {
        method is_bsd() {1}
    }

    class Brocken::Katsuro::Platform::FreeBSD : isa(Brocken::Katsuro::Platform::BSD) {
        method is_freebsd() {1}
    }

    class Brocken::Katsuro::Platform::OpenBSD : isa(Brocken::Katsuro::Platform::BSD) {
        method is_openbsd() {1}
    }

    class Brocken::Katsuro::Platform::NetBSD : isa(Brocken::Katsuro::Platform::BSD) {
        method is_netbsd() {1}
    }

    class Brocken::Katsuro::Platform::MidnightBSD : isa(Brocken::Katsuro::Platform::BSD) {
        method is_midnightbsd() {1}
    }

    class Brocken::Katsuro::Platform::DragonflyBSD : isa(Brocken::Katsuro::Platform::BSD) {
        method is_dragonflybsd() {1}
    }

    class Brocken::Katsuro::Platform::Haiku : isa(Brocken::Katsuro::Platform) {
        my %cache;
        method is_haiku() {1}

        sub _detect_syscall( $class, $name, $arch ) {
            my $lib = '/boot/system/lib/libroot.so';
            return undef unless -e $lib;
            my %stub = (
                write  => '_kern_write',
                exit   => '_kern_exit_team',
                fork   => '_kern_fork',
                wait4  => '_kern_wait_for_child',
                read   => '_kern_read',
                open   => '_kern_open',
                close  => '_kern_close',
                getpid => '_kern_getpid'
            );
            my $fn  = $stub{$name} or return undef;
            my $cmd = "objdump -d '$lib' | grep -A 20 '<$fn>:'";
            my $dis = `$cmd 2>/dev/null` or return undef;
            if    ( $arch =~ /x86_64|x64|amd64/i ) { return hex($1) if $dis =~ /mov\s+eax,\s*0x([0-9a-f]+)/i }
            elsif ( $arch =~ /aarch64|arm64/i )    { return hex($1) if $dis =~ /mov\s+x8,\s*#0x([0-9a-f]+)/i }
            elsif ( $arch =~ /riscv64|riscv/i )    { return hex($1) if $dis =~ /li\s+a7,\s*#?0x([0-9a-f]+)/i }
            return undef;
        }

        method syscall($name) {
            return $cache{ $self->arch }{$name} if exists $cache{ $self->arch }{$name};
            my $num;
            $num = _detect_syscall( ref($self), $name, $self->arch ) if $self->is_native;
            unless ( defined $num ) {
                my %fallback = (
                    x86_64 => {
                        write     => 151,
                        exit      => 41,
                        fork      => 47,
                        wait4     => 45,
                        read      => 148,
                        open      => 83,
                        close     => 42,
                        getpid    => 46,
                        mmap      => 103,
                        nanosleep => 156,
                        brk       => 110
                    },
                    aarch64 => {
                        write     => 151,
                        exit      => 41,
                        fork      => 47,
                        wait4     => 45,
                        read      => 148,
                        open      => 83,
                        close     => 42,
                        getpid    => 46,
                        mmap      => 103,
                        nanosleep => 156,
                        brk       => 110
                    },
                    riscv64 => {
                        write     => 151,
                        exit      => 41,
                        fork      => 47,
                        wait4     => 45,
                        read      => 148,
                        open      => 83,
                        close     => 42,
                        getpid    => 46,
                        mmap      => 103,
                        nanosleep => 156,
                        brk       => 110
                    },
                );
                $num = $fallback{ $self->arch }{$name};
            }
            $cache{ $self->arch }{$name} = $num;
            return $num;
        }
    }

    class Brocken::Katsuro::Platform::Wasm : isa(Brocken::Katsuro::Platform) {
        method is_wasm()    {1}
        method is_posix()   { ( $self->os // '' ) =~ /wasi/i || ( $self->env // '' ) =~ /wasi/i }
        method bin_ext()    {'.wasm'}
        method lib_ext()    {'.wasm'}
        method format()     {'wasm'}
        method lib_prefix() {''}
    }
}

package Brocken::Lindsay {

    class Brocken::Lindsay::IR::Type {
        field $kind : reader : param;        # 'int', 'float', 'ptr', 'void'
        field $bits : reader : param = 0;    # 8, 16, 32, 64, ...

        # Singletons for common types to save memory and allow `==` comparison
        sub i1      { state $t //= __PACKAGE__->new( kind => 'int', bits => 1 );       $t }    # bool
        sub i32     { state $t //= __PACKAGE__->new( kind => 'int', bits => 32 );      $t }
        sub i64     { state $t //= __PACKAGE__->new( kind => 'int', bits => 64 );      $t }
        sub ptr     { state $t //= __PACKAGE__->new( kind => 'ptr' );                  $t }    # opaque pointer
        sub void    { state $t //= __PACKAGE__->new( kind => 'void' );                 $t }
        sub dynamic { state $t //= __PACKAGE__->new( kind => 'dynamic', bits => 128 ); $t }    # 16-byte Fat Scalar (Tag + Payload), our SV*

        method as_string() {
            return "i$bits" if $kind eq 'int';
            return $kind;
        }
    }

    class Brocken::Lindsay::IR::Value {
        field $type : reader : param;
        field $name : reader : param = undef;

        # Every value needs a way to print itself in IR dumps
        method as_string() { $name // '%<anon>' }
    }

    class Brocken::Lindsay::IR::Constant : isa(Brocken::Lindsay::IR::Value) {
        field $value : reader : param;
        method as_string() {$value}
    }

    class Brocken::Lindsay::IR::Instruction : isa(Brocken::Lindsay::IR::Value) {
        field $opcode   : reader : param;
        field $operands : reader : param = [];
        field $parent   : reader : param = undef;    # The Basic Block

        method render() {
            my $ops = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $operands->@*;
            my $res = $self->type->kind eq 'void' ? '' : ( $self->name // '%<anon>' ) . ' = ';
            return "  $res$opcode $ops";
        }
    }

    class Brocken::Lindsay::IR::Instruction::ICmp : isa(Brocken::Lindsay::IR::Instruction) {
        field $predicate : reader : param;           # 'eq', 'ne', 'sgt' (signed greater than), 'slt', etc.

        method render() {
            my ( $lhs, $rhs ) = $self->operands->@*;
            return sprintf '  %s = icmp %s %s %s, %s', ( $self->name // '%<anon>' ), $predicate, $lhs->type->as_string, $lhs->as_string,
                $rhs->as_string;
        }
    }

    class Brocken::Lindsay::IR::Instruction::Br : isa(Brocken::Lindsay::IR::Instruction) {
        field $dest_block : reader : param;

        method render() {
            return '  br label %' . $dest_block->name;
        }
    }

    class Brocken::Lindsay::IR::Instruction::CondBr : isa(Brocken::Lindsay::IR::Instruction) {
        field $true_block  : reader : param;
        field $false_block : reader : param;

        method render() {
            my $cond = $self->operands->[0];
            return sprintf '  br %s %s, label %%%s, label %%%s', $cond->type->as_string, $cond->as_string, $true_block->name, $false_block->name;
        }
    }

    class Brocken::Lindsay::IR::Instruction::Ret : isa(Brocken::Lindsay::IR::Instruction) {

        method render() {
            return '  ret void' if $self->type->kind eq 'void';
            my $val = $self->operands->[0];
            return '  ret ' . $val->type->as_string . ' ' . $val->as_string;
        }
    }

    class Brocken::Lindsay::IR::Instruction::Call : isa(Brocken::Lindsay::IR::Instruction) {
        field $callee : reader : param;    # Brocken::Lindsay::IR::Function

        method render() {
            my $args = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $self->operands->@*;
            my $res  = $self->type->kind eq 'void' ? '' : ( $self->name // '%<anon>' ) . ' = ';
            return sprintf '  %scall %s @%s(%s)', $res, $self->type->as_string, $callee->name, $args;
        }
    }

    class Brocken::Lindsay::IR::Instruction::Box : isa(Brocken::Lindsay::IR::Instruction) {

        method render() {
            my $val = $self->operands->[0];
            return sprintf '  %s = box %s %s to dynamic', ( $self->name // '%<anon>' ), $val->type->as_string, $val->as_string;
        }
    }

    class Brocken::Lindsay::IR::Instruction::Unbox : isa(Brocken::Lindsay::IR::Instruction) {

        method render() {
            my $val = $self->operands->[0];
            return sprintf '  %s = unbox %s %s to %s', ( $self->name // '%<anon>' ), $val->type->as_string, $val->as_string, $self->type->as_string;
        }
    }

    class Brocken::Lindsay::IR::Block {
        field $name         : reader : param;
        field $parent       : reader : param = undef;    # The function
        field $instructions : reader = [];

        method append_inst($inst) {
            push $instructions->@*, $inst;
            return $inst;
        }

        method as_string() {
            my $out = "$name:\n";
            $out .= $_->render . "\n" for $instructions->@*;
            return $out;
        }
    }

    class Brocken::Lindsay::IR::Function {
        field $name        : reader : param;
        field $return_type : reader : param;
        field $params      : reader : param = [];    # Array of Brocken::Lindsay::IR::Value
        field $blocks      : reader = [];

        method append_block($name) {
            my $bb = Brocken::Lindsay::IR::Block->new( name => $name, parent => $self );
            push $blocks->@*, $bb;
            return $bb;
        }

        method as_string() {

            # If there are no blocks, this is an FFI declaration
            if ( scalar( $blocks->@* ) == 0 ) {

                # Declarations usually just list the types, no names needed
                my $p_str = join ', ', map { $_->type->as_string } $params->@*;
                return sprintf qq[declare %s @%s(%s)\n], $return_type->as_string, $name, $p_str;
            }
            my $p_str = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $params->@*;
            my $out   = sprintf qq[define %s @%s(%s) {\n], $return_type->as_string, $name, $p_str;
            $out .= $_->as_string for $blocks->@*;
            $out .= qq[}\n];
            return $out;
        }
    }

    class Brocken::Lindsay::IR::Module {
        field $name : reader : param = 'main';
        field $functions : reader = [];

        method add_function($func) {
            push $functions->@*, $func;
            return $func;
        }

        method as_string() {
            my $out = "; ModuleID = '$name'\n\n";
            $out .= $_->as_string . "\n" for $functions->@*;
            return $out;
        }
    }

    class Brocken::Lindsay::IR::Builder {
        field $insert_block : reader = undef;
        field $id_counter = 0;
        method position_at_end($block) { $insert_block = $block }
        method _next_id()              { '%' . $id_counter++ }

        method build_add( $lhs, $rhs, $name = undef ) {
            my $inst = Brocken::Lindsay::IR::Instruction->new(
                name     => $name // $self->_next_id(),
                type     => $lhs->type,
                opcode   => 'add',
                operands => [ $lhs, $rhs ],
                parent   => $insert_block
            );
            return $insert_block->append_inst($inst);
        }

        method build_icmp( $predicate, $lhs, $rhs, $name = undef ) {
            my $inst = Brocken::Lindsay::IR::Instruction::ICmp->new(
                name      => $name // $self->_next_id(),
                type      => Brocken::Lindsay::IR::Type::i1(),    # comparisons yield a boolean
                opcode    => 'icmp',
                predicate => $predicate,
                operands  => [ $lhs, $rhs ],
                parent    => $insert_block
            );
            return $insert_block->append_inst($inst);
        }

        method build_br($dest_block) {
            my $inst = Brocken::Lindsay::IR::Instruction::Br->new(
                name       => undef,
                type       => Brocken::Lindsay::IR::Type::void(),
                opcode     => 'br',
                dest_block => $dest_block,
                parent     => $insert_block
            );
            return $insert_block->append_inst($inst);
        }

        method build_cond_br( $cond_val, $true_block, $false_block ) {
            my $inst = Brocken::Lindsay::IR::Instruction::CondBr->new(
                name        => undef,
                type        => Brocken::Lindsay::IR::Type::void(),
                opcode      => 'br',
                operands    => [$cond_val],
                true_block  => $true_block,
                false_block => $false_block,
                parent      => $insert_block
            );
            return $insert_block->append_inst($inst);
        }

        method build_ret( $val = undef ) {
            my $type = defined $val ? $val->type : Brocken::Lindsay::IR::Type::void();
            my $inst = Brocken::Lindsay::IR::Instruction::Ret->new(
                name     => undef,
                type     => $type,
                opcode   => 'ret',
                operands => defined $val ? [$val] : [],
                parent   => $insert_block
            );
            return $insert_block->append_inst($inst);
        }

        method build_call( $callee, $args, $name = undef ) {
            my $type = $callee->return_type;
            my $inst = Brocken::Lindsay::IR::Instruction::Call->new(
                name     => $type->kind eq 'void' ? undef : ( $name // $self->_next_id() ),
                type     => $type,
                opcode   => 'call',
                callee   => $callee,
                operands => $args,
                parent   => $insert_block
            );
            return $insert_block->append_inst($inst);
        }

        method build_alloca( $type, $name = undef ) {
            my $inst = Brocken::Lindsay::IR::Instruction::Alloca->new(
                name           => $name // $self->_next_id(),
                type           => Brocken::Lindsay::IR::Type::ptr(),    # allocas yield a ptr
                opcode         => 'alloca',
                allocated_type => $type,                                # What we are allocating
                parent         => $insert_block
            );
            return $insert_block->append_inst($inst);
        }

        method build_load( $type, $ptr, $name = undef ) {
            my $inst = Brocken::Lindsay::IR::Instruction::Load->new(
                name     => $name // $self->_next_id(),
                type     => $type,                                      # a load yields the type being loaded
                opcode   => 'load',
                operands => [$ptr],
                parent   => $insert_block
            );
            return $insert_block->append_inst($inst);
        }

        method build_store( $val, $ptr ) {
            my $inst = Brocken::Lindsay::IR::Instruction::Store->new(
                name     => undef,
                type     => Brocken::Lindsay::IR::Type::void(),         # stores do not yield an SSA value
                opcode   => 'store',
                operands => [ $val, $ptr ],
                parent   => $insert_block
            );
            return $insert_block->append_inst($inst);
        }

        method build_box( $val, $name = undef ) {
            my $inst = Brocken::Lindsay::IR::Instruction::Box->new(
                name     => $name // $self->_next_id(),
                type     => Brocken::Lindsay::IR::Type::dynamic(),      # always yields a dynamic
                opcode   => 'box',
                operands => [$val],
                parent   => $insert_block
            );
            return $insert_block->append_inst($inst);
        }

        method build_unbox( $dynamic_val, $dest_type, $name = undef ) {
            my $inst = Brocken::Lindsay::IR::Instruction::Unbox->new(
                name     => $name // $self->_next_id(),
                type     => $dest_type,                                 # yields the requested native type
                opcode   => 'unbox',
                operands => [$dynamic_val],
                parent   => $insert_block
            );
            return $insert_block->append_inst($inst);
        }
    }

    class Brocken::Lindsay::IR::Instruction::Alloca : isa(Brocken::Lindsay::IR::Instruction) {
        field $allocated_type : reader : param;

        method render() {
            return sprintf '  %s = alloca %s', ( $self->name // '%<anon>' ), $allocated_type->as_string;
        }
    }

    class Brocken::Lindsay::IR::Instruction::Load : isa(Brocken::Lindsay::IR::Instruction) {

        method render() {
            my $ptr = $self->operands->[0];

            # The type of a load instruction *is* the type it loads
            return sprintf '  %s = load %s, %s %s', ( $self->name // '%<anon>' ), $self->type->as_string, $ptr->type->as_string, $ptr->as_string;
        }
    }

    class Brocken::Lindsay::IR::Instruction::Store : isa(Brocken::Lindsay::IR::Instruction) {

        method render() {
            my ( $val, $ptr ) = $self->operands->@*;
            return sprintf '  store %s %s, %s %s', $val->type->as_string, $val->as_string, $ptr->type->as_string, $ptr->as_string;
        }
    }
}

package Brocken::Jenny {

    class Brocken::Jenny::Codegen::X86_64 {

        # Simple x86_64 machine code mapping for our IR subset
        method emit_function($ir_func) {
            my $bytes = "";

            # Iterate through basic blocks and instructions
            for my $block ( $ir_func->blocks->@* ) {
                for my $inst ( $block->instructions->@* ) {
                    if ( $inst->isa('Brocken::Lindsay::IR::Instruction::Ret') ) {
                        if ( $inst->type->kind eq 'void' ) {

                            # No-op / return void
                            $bytes .= pack( "C", 0xC3 );    # ret
                        }
                        else {
                            # We need to put the return value in RAX (x86_64 return register)
                            my $val = $inst->operands->[0];
                            if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {

                                # mov eax, IMM32 (shorter than mov rax, IMM64)
                                $bytes .= pack( "CV", 0xB8, $val->value );
                            }
                            $bytes .= pack( "C", 0xC3 );    # ret
                        }
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Box') || $inst->isa('Brocken::Lindsay::IR::Instruction::Unbox') ) {

                        # Stub: Gradual typing boxing/unboxing operations
                        # will be handled here during lowering.
                    }

                    # Additional instructions (add, load, store) will map
                    # to their respective x86_64 opcodes here.
                }
            }
            return $bytes;
        }
    }

    class Brocken::Jenny::Codegen::RISCV64 {

        # Simple RISC-V 64-bit machine code generator
        method emit_function($ir_func) {
            my $bytes = "";

            # Iterate through basic blocks and instructions
            for my $block ( $ir_func->blocks->@* ) {
                for my $inst ( $block->instructions->@* ) {
                    if ( $inst->isa('Brocken::Lindsay::IR::Instruction::Ret') ) {
                        if ( $inst->type->kind eq 'void' ) {

                            # ret (jalr x0, ra, 0)
                            $bytes .= pack( "V", 0x00008067 );
                        }
                        else {
                            my $val = $inst->operands->[0];
                            if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {

                                # addi a0, x0, 42 (loads exit code into return register)
                                $bytes .= pack( "V", 0x02a00513 );
                            }

                            # ret (jalr x0, ra, 0)
                            $bytes .= pack( "V", 0x00008067 );
                        }
                    }
                }
            }
            return $bytes;
        }
    }

    class Brocken::Jenny::Codegen::ARM64 {

        # Simple ARM64 / AArch64 machine code generator
        method emit_function($ir_func) {
            my $bytes = "";

            # Iterate through basic blocks and instructions
            foreach my $block ( $ir_func->blocks->@* ) {
                foreach my $inst ( $block->instructions->@* ) {
                    if ( $inst->isa('Brocken::Lindsay::IR::Instruction::Ret') ) {
                        if ( $inst->type->kind eq 'void' ) {

                            # ret (returns execution to the caller, jumping to x30)
                            $bytes .= pack( "V", 0xD65F03C0 );
                        }
                        else {
                            my $val = $inst->operands->[0];
                            if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {

                                # movz w0, #42 (loads return value into return register w0)
                                $bytes .= pack( "V", 0x52800540 );
                            }

                            # ret
                            $bytes .= pack( "V", 0xD65F03C0 );
                        }
                    }
                }
            }
            return $bytes;
        }
    }

    class Brocken::Jenny::Linker {
        field $_layout        : reader(layout);
        field $type           : param : reader = 'exe';
        field $debug_data     : reader = {};
        field $func_ranges    : reader = [];
        field $labels         : reader = {};
        field $exported_funcs : reader = [];
        field $preserved_regs : reader = [];
        field $frame_size     : reader = 0;
        field $timestamp      : reader = undef;
        #
        method set_preserved_regs($r) { $preserved_regs = $r; }
        method set_frame_size($s)     { $frame_size     = $s; }
        method set_timestamp($t)      { $timestamp      = $t; }

        # Default to the current time when not explicitly set. Pass 0 to
        # write a deterministic build (e.g. for reproducible-build tests).
        method effective_timestamp() { $timestamp // time() }
        method set_debug_data($d)    { $debug_data = $d; }
        method debug_section($name)  { return $self->debug_data->{$name} // ''; }
        method set_func_ranges($r)   { $func_ranges = $r; }
        method set_labels($l)        { $labels      = $l; }

        # shared lib
        method set_exported_funcs($f) { $exported_funcs = $f; }
        #
        method rva_for($name) {
            return $self->layout->get($name)->{rva};
        }
        method image_base() { return 0; }

        method pre_layout( $text_size, $data_size, $arch, $os, $debug = 0 ) {
            my $is_macos   = $os                =~ /^(macos|darwin)/i;
            my $is_arm_mac = $is_macos && $arch =~ /aarch64|arm64/i;
            my $page_align
                = $is_arm_mac                 ? 0x4000 :
                $is_macos                     ? 0x1000 :
                $os eq 'win64'                ? 0x200 :
                ( $arch =~ /aarch64|arm64/i ) ? 0x10000    # 64KB alignment for ARM64 ELF
                :
                0x1000;
            eval {
                require Brocken::Target::Format::Layout;
                $_layout = Brocken::Target::Format::Layout->new( file_align => $page_align, section_align => $page_align );
            };
            if ( $@ || !defined $_layout ) {
                $_layout = Brocken::Jenny::Linker::Layout->new( file_align => $page_align, section_align => $page_align );
            }
            $self->_setup_layout( $_layout, $text_size, $data_size, $arch, $os, $debug );
            $_layout->calculate($page_align);
        }
        method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 )           { die "Abstract" }
        method write_bin( $filename, $text, $data, $arch, $os, $type ) { die "Abstract" }
        method import_rva($name)                                       { die "Imports not supported by this format" }
    }

    class Brocken::Jenny::Linker::Layout {
        field $file_align    : param : reader = 0x200;
        field $section_align : param : reader = 0x1000;
        field @sections;
        field $header_size : reader = 0;

        method add_section( $name, $size, $flags ) {
            push @sections, { name => $name, size => ( $size || 1 ), flags => $flags, rva => 0, off => 0 };
        }

        method calculate($min_hdr) {
            $header_size = ( $min_hdr + $file_align - 1 ) & ~( $file_align - 1 );
            my $curr_off = $header_size;

            # RVA must mathematically align with file offset on strict formats (Mach-O)
            my $curr_rva = ( $header_size + $section_align - 1 ) & ~( $section_align - 1 );
            for my $s (@sections) {
                $s->{off} = $curr_off;
                $s->{rva} = $curr_rva;
                $curr_off += ( $s->{size} + $file_align - 1 ) & ~( $file_align - 1 );
                $curr_rva += ( $s->{size} + $section_align - 1 ) & ~( $section_align - 1 );
            }
            return $curr_rva;
        }

        method get($n) {
            for (@sections) { return $_ if $_->{name} eq $n }
            die "Layout Error: Section $n not found";
        }
        method sections() {@sections}
    }

    class Brocken::Jenny::Linker::DWARF : isa(Brocken::Jenny::Linker) {
        field $source_locs    : param : reader;
        field $text_base      : param : reader;
        field $source_file    : param : reader //= 'source.brocken';
        field $func_ranges    : param : reader = [];
        field $context_size   : param : reader = 64;
        field $class_info     : param : reader = {};
        field $debug          : param : reader = 0;
        field $eh_frame_base  : param : reader = 0;
        field $arch           : param : reader = 'x64';
        field $preserved_regs : param : reader = [];
        field $platform       : param : reader = undef;    # Optional target Platform
        field @pubnames;

        # Unified DWARF register number resolver delegating to Katsuro::Platform::ABI
        method dwarf_reg_num($name) {
            if ( defined $platform ) {
                return $platform->abi->dwarf_reg_num($name);
            }

            # Fallback for older constructor calls: dynamically parse the platform from $arch
            my $parsed_platform = Brocken::Katsuro::Platform::parse($arch);
            return $parsed_platform->abi->dwarf_reg_num($name);
        }

        method build_all () {
            my $info     = $self->build_debug_info;
            my $sections = { '.debug_line' => $self->build_debug_line, '.debug_info' => $info, '.debug_abbrev' => $self->build_debug_abbrev, };
            if (@$func_ranges) {
                $sections->{'.debug_frame'}    = $self->build_debug_frame;
                $sections->{'.debug_aranges'}  = $self->build_debug_aranges;
                $sections->{'.debug_pubnames'} = $self->build_debug_pubnames( length($info) );
                $sections->{'.eh_frame'}       = $self->build_eh_frame if $self->eh_frame_base;
            }
            return $sections;
        }

        method build_debug_line () {
            my @entries   = sort { $a->{offset} <=> $b->{offset} } @$source_locs;
            my $program   = '';
            my $prev_line = 1;
            my $prev_addr = $text_base;
            for my $e (@entries) {
                my $addr = $text_base + $e->{offset};
                my $line = $e->{line};

                # Set Address
                $program .= "\x00" . $self->_uleb(9) . "\x02" . pack( 'Q<', $addr );

                # Advance Line
                $program .= "\x03" . $self->_sleb( $line - $prev_line );

                # Copy row
                $program .= "\x01";
                $prev_line = $line;
            }

            # End of sequence
            my $max_offset = 0;
            for my $fn (@$func_ranges) { $max_offset = $fn->{end} if ( $fn->{end} // 0 ) > $max_offset; }
            $program .= "\x00" . $self->_uleb(9) . "\x02" . pack( 'Q<', $text_base + $max_offset );
            $program .= "\x00" . $self->_uleb(1) . "\x01";
            my $prologue = pack( 'C', 1 ) . pack( 'C', 1 ) . pack( 'c', -5 ) . pack( 'C', 14 ) . pack( 'C', 13 );
            $prologue .= pack( 'C*', 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1 );
            $prologue .= "\x00";                                                                     # Directory table
            $prologue .= "$source_file\x00" . $self->_uleb(0) . $self->_uleb(0) . $self->_uleb(0);
            $prologue .= "\x00";
            my $full_len = 2 + 4 + length($prologue) + length($program);
            my $header   = pack( 'L<', $full_len );
            $header .= pack( 'S<', 2 );
            $header .= pack( 'L<', length($prologue) );
            return $header . $prologue . $program;
        }

        method build_debug_abbrev () {
            my $abbrev = '';

            # Abbrev 1: DW_TAG_compile_unit
            $abbrev .= $self->_uleb(1) . $self->_uleb(0x11) . $self->_uleb(1);
            $abbrev .= $self->_uleb(0x10) . $self->_uleb(0x06);                  # DW_AT_stmt_list -> data4
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                  # DW_AT_name -> string
            $abbrev .= $self->_uleb(0x13) . $self->_uleb(0x0B);                  # DW_AT_language -> data1
            $abbrev .= $self->_uleb(0x11) . $self->_uleb(0x01);                  # DW_AT_low_pc -> addr
            $abbrev .= $self->_uleb(0x12) . $self->_uleb(0x01);                  # DW_AT_high_pc -> addr
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 2: DW_TAG_base_type
            $abbrev .= $self->_uleb(2) . $self->_uleb(0x24) . $self->_uleb(0);
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                  # DW_AT_name -> string
            $abbrev .= $self->_uleb(0x0B) . $self->_uleb(0x0B);                  # DW_AT_byte_size -> data1
            $abbrev .= $self->_uleb(0x3E) . $self->_uleb(0x0B);                  # DW_AT_encoding -> data1
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 3: DW_TAG_subprogram
            $abbrev .= $self->_uleb(3) . $self->_uleb(0x2E) . $self->_uleb(1);
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                  # DW_AT_name
            $abbrev .= $self->_uleb(0x11) . $self->_uleb(0x01);                  # low_pc
            $abbrev .= $self->_uleb(0x12) . $self->_uleb(0x01);                  # high_pc
            $abbrev .= $self->_uleb(0x40) . $self->_uleb(0x18);                  # frame_base -> exprloc
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 4: DW_TAG_formal_parameter / Abbrev 5: DW_TAG_variable
            for ( 4 .. 5 ) {
                $abbrev .= $self->_uleb($_) . $self->_uleb( $_ == 4 ? 0x05 : 0x34 ) . $self->_uleb(0);
                $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                                      # name
                $abbrev .= $self->_uleb(0x02) . $self->_uleb(0x18);                                      # location
                $abbrev .= $self->_uleb(0x49) . $self->_uleb(0x13);                                      # type -> ref4
                $abbrev .= pack( 'CC', 0, 0 );
            }
            $abbrev .= "\x00";
            return $abbrev;
        }

        method build_debug_info () {
            my $max_pc = 0;
            for my $fn (@$func_ranges) { $max_pc = $fn->{end} if ( $fn->{end} // 0 ) > $max_pc; }
            my $cu_body = '';
            $cu_body .= $self->_uleb(1);                       # DW_TAG_compile_unit
            $cu_body .= pack( 'L<', 0 );                       # stmt_list
            $cu_body .= "$source_file\0";
            $cu_body .= pack( 'C',  12 );                      # language (C99)
            $cu_body .= pack( 'Q<', $text_base );              # low_pc
            $cu_body .= pack( 'Q<', $text_base + $max_pc );    # high_pc
            my $CU_HEADER_SIZE = 11;
            my $type_off       = {};

            for my $t ( [ 'Int', 5 ], [ 'Bool', 2 ], [ 'String', 1 ], [ 'Any', 1 ], [ 'ptr', 1 ], [ 'Array', 1 ] ) {
                $type_off->{ $t->[0] } = $CU_HEADER_SIZE + length($cu_body);
                $cu_body .= $self->_uleb(2) . "$t->[0]\0" . pack( 'CC', 8, $t->[1] );
            }
            for my $fn ( sort { $a->{start} <=> $b->{start} } @$func_ranges ) {
                my $die_off = $CU_HEADER_SIZE + length($cu_body);
                push @pubnames, { offset => $die_off, name => ( $fn->{name} =~ s/^M_//r ) };
                $cu_body .= $self->_uleb(3);    # DW_TAG_subprogram
                $cu_body .= "$fn->{name}\0";
                $cu_body .= pack( 'Q<', $text_base + $fn->{start} );
                $cu_body .= pack( 'Q<', $text_base + ( $fn->{end} // $fn->{start} ) );

                # frame_base (RBP relative)
                my $fb = pack( 'C', 0x70 + ( $arch =~ /aarch64|arm64/i ? 29 : 6 ) ) . "\x00";
                $cu_body .= $self->_uleb( length($fb) ) . $fb;
                for my $v ( @{ $fn->{params} // [] }, @{ $fn->{locals} // [] } ) {
                    $cu_body .= $self->_uleb( exists $v->{slot} ? 5 : 4 );
                    ( my $n = $v->{name} ) =~ s/^\$//;
                    $cu_body .= "$n\0";
                    my $loc = "\x91" . $self->_sleb( -$v->{slot} );
                    $cu_body .= $self->_uleb( length($loc) ) . $loc;
                    $cu_body .= pack( 'L<', $type_off->{ $v->{type} } // $type_off->{Any} );
                }
                $cu_body .= "\x00";    # end subprogram
            }
            $cu_body .= "\x00";        # end CU
            return pack( 'L< S< L< C', length($cu_body) + 7, 2, 0, 8 ) . $cu_body;
        }

        method build_debug_aranges () {
            my $max_pc = 0;
            for my $fn (@$func_ranges) { $max_pc = $fn->{end} if ( $fn->{end} // 0 ) > $max_pc; }
            my $body = pack( 'Q< Q<', $text_base, $max_pc );
            $body .= pack( 'Q< Q<', 0, 0 );
            my $header = pack( 'S< L< C C', 2, 0, 8, 0 );

            # Padding to 16-byte boundary
            my $pad = ( 16 - ( ( length($header) + 4 ) % 16 ) ) % 16;
            return pack( 'L<', length($header) + $pad + length($body) ) . $header . ( "\0" x $pad ) . $body;
        }

        method build_debug_pubnames ( $info_len = 0 ) {
            my $body = '';
            for my $pn (@pubnames) { $body .= pack( 'L<', $pn->{offset} ) . "$pn->{name}\0"; }
            $body .= pack( 'L<', 0 );
            return pack( 'L< S< L< L<', length($body) + 10, 2, 0, $info_len ) . $body;
        }

        method _uleb ($v) {
            my $out = '';
            do {
                my $byte = $v & 0x7F;
                $v >>= 7;
                $byte |= 0x80 if $v;
                $out .= pack( 'C', $byte );
            } while ($v);
            return $out;
        }

        method _sleb ($v) {
            require POSIX;
            my $out = '';
            while (1) {
                my $byte = $v & 0x7f;
                $v = POSIX::floor( $v / 128 );
                if ( ( $v == 0 && !( $byte & 0x40 ) ) || ( $v == -1 && ( $byte & 0x40 ) ) ) {
                    $out .= pack( 'C', $byte );
                    last;
                }
                $out .= pack( 'C', $byte | 0x80 );
            }
            return $out;
        }

        method build_debug_frame () {

            # Basic CIE
            my $cie_body = pack( 'C', 3 ) . "\0" . $self->_uleb(1) . $self->_sleb(-8);
            $cie_body .= ( $arch                      =~ /aarch64|arm64/i ? pack( 'C', 30 ) : pack( 'C', 16 ) );        # Return reg
            $cie_body .= "\x0C" . $self->_uleb( $arch =~ /aarch64|arm64/i ? 31              : 7 ) . $self->_uleb(8);    # def_cfa

            # Tell DWARF where the return address is saved (offset 1 * -8)
            if ( $arch eq 'x64' ) {
                $cie_body .= pack( 'C', 0x80 | 16 ) . $self->_uleb(1);
            }
            my $cie_pad = ( 8 - ( ( length($cie_body) + 8 ) % 8 ) ) % 8;
            $cie_body .= "\0" x $cie_pad;
            my $data = pack( 'L<', length($cie_body) + 4 ) . pack( 'L<', 0xFFFFFFFF ) . $cie_body;
            for my $fn (@$func_ranges) {
                my $instr           = "\x0C" . $self->_uleb( $arch =~ /aarch64|arm64/i ? 29 : 6 ) . $self->_uleb( $context_size + 8 );
                my $offset_from_cfa = -16;
                for my $r (@$preserved_regs) {
                    my $reg_num      = $self->dwarf_reg_num($r) // 0;    # Clean delegation
                    my $factored_off = $offset_from_cfa / -8;
                    $instr .= pack( 'C', 0x80 | $reg_num ) . $self->_uleb($factored_off);
                    $offset_from_cfa -= 8;
                }
                my $fde_body = pack( 'Q< Q<', $text_base + $fn->{start}, $fn->{end} - $fn->{start} ) . $instr;
                my $fde_pad  = ( 8 - ( ( length($fde_body) + 8 ) % 8 ) ) % 8;
                $fde_body .= "\0" x $fde_pad;
                $data     .= pack( 'L<', length($fde_body) + 4 ) . pack( 'L<', 0 ) . $fde_body;
            }
            return $data;
        }

        method build_eh_frame () {
            return '' unless $eh_frame_base;
            my $reg = $arch =~ /aarch64|arm64/i ? 30 : 16;

            # CIE with "zR" augmentation for pcrel FDE encoding
            my $cie_body = pack( 'C', 1 ) . "zR\0" . $self->_uleb(1) . $self->_sleb(-8);
            $cie_body .= pack( 'C', $reg );

            # Augmentation data length + FDE encoding (pcrel|sdata4 = 0x1B)
            $cie_body .= $self->_uleb(1) . "\x1B";

            # Initial instructions: def_cfa RSP+8, offset rip at cfa-8
            $cie_body .= "\x0C" . $self->_uleb( $arch =~ /aarch64|arm64/i ? 31 : 7 ) . $self->_uleb(8);
            $cie_body .= pack( 'C', 0x80 | $reg ) . $self->_uleb(1);
            my $cie_pad = ( 4 - ( ( length($cie_body) + 4 ) % 4 ) ) % 4;
            $cie_body .= "\0" x $cie_pad;
            my $data = pack( 'L<', length($cie_body) + 4 ) . pack( 'L<', 0 ) . $cie_body;
            for my $fn (@$func_ranges) {
                my $fn_start = $fn->{start};
                my $fn_len   = ( $fn->{end} // $fn->{start} + 1 ) - $fn->{start};
                my $instr    = "\x0C" . $self->_uleb( $arch =~ /aarch64|arm64/i ? 29 : 6 ) . $self->_uleb( $context_size + 8 );
                for my $r (@$preserved_regs) {
                    my $reg_num      = $self->dwarf_reg_num($r) // 0;    # Clean delegation
                    my $factored_off = -16 / -8;
                    $instr .= pack( 'C', 0x80 | $reg_num ) . $self->_uleb($factored_off);
                }

                # pcrel initial_location: the file-relative offset to fn_start
                # (Runtime adds the eh_frame_base to resolve)
                my $fde_body = pack( 'L<', $fn_start ) . pack( 'L<', $fn_len ) . $instr;
                my $fde_pad  = ( 4 - ( ( length($fde_body) + 4 ) % 4 ) ) % 4;
                $fde_body .= "\0" x $fde_pad;

                # CIE_pointer = offset of CIE_pointer_field - CIE_offset
                # CIE is at section offset 0, FDE CIE_pointer field at data_end + 4
                my $fde_offset = length($data);
                $data .= pack( 'L<', length($fde_body) + 4 ) . pack( 'L<', $fde_offset + 4 ) . $fde_body;
            }
            return $data;
        }
    };

    class Brocken::Jenny::Linker::MachO : isa(Brocken::Jenny::Linker) {
        no warnings 'portable';
        field $has_ffi : reader = false;
        method set_has_ffi($v) { $has_ffi = $v; }

        method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
            $l->add_section( '.text',     $t,                   5 );                # Read + Execute
            $l->add_section( '.data',     $d,                   3 ) if $d > 0;      # Read + Write
            $l->add_section( '.got',      512,                  3 ) if $has_ffi;    # Global Offset Table
            $l->add_section( '.linkedit', $has_ffi ? 4096 : 64, 1 );                # Symbols, Strings, Dynamic linking info
            if ( $dbg >= 1 ) {
                $l->add_section( '.debug_line',     4096, 0 );
                $l->add_section( '.debug_info',     8192, 0 );
                $l->add_section( '.debug_abbrev',   4096, 0 );
                $l->add_section( '.debug_frame',    8192, 0 );
                $l->add_section( '.debug_aranges',  4096, 0 );
                $l->add_section( '.debug_pubnames', 4096, 0 );
            }
        }

        method import_rva($name) {
            my $imports = { dlopen => 0, dlsym => 8, pthread_create => 16 };
            return $self->layout->get('.got')->{rva} + ( $imports->{$name} // die "Unknown Mach-O import: $name" );
        }
        method image_base () { return hex('100000000'); }    # 64-bit macOS default image base (4GB)

        method write_executable ( $output_file, $code_bytes, $platform, $shared = false, $debug_bytes = undef ) {
            my $full_code    = ref $code_bytes eq 'HASH' ? $code_bytes->{binary}                        : $code_bytes;
            my $writable_off = ref $code_bytes eq 'HASH' ? ( $code_bytes->{writable_data_offset} // 0 ) : 0;
            my $text_raw     = $writable_off             ? substr( $full_code, 0, $writable_off )       : $full_code;
            my $data_bytes   = $writable_off             ? substr( $full_code, $writable_off )          : '';
            my $text         = $text_raw;
            my $arch         = $platform->arch;
            my $os           = $platform->os;

            # Prepend platform-specific Mach-O _start stubs if compiling an executable
            if ( $self->type eq 'exe' ) {
                my $entry_stub = "";
                my $exit_sys   = $platform->syscall('exit') // 0x2000001;
                if ( $platform->is_arm64 ) {

                    # ARM64 (Apple Silicon) native exit stub:
                    # - bl main (relative call offset +20 bytes -> 5 instructions)
                    # - movz x16, #sys_low
                    # - movk x16, #sys_high, lsl #16
                    # - svc #0x80
                    # - brk #0 (Safety crash)
                    my $movz = 0xD2800000 | ( ( $exit_sys & 0xffff ) << 5 ) | 16;
                    my $movk = 0xF2A00000 | ( ( ( $exit_sys >> 16 ) & 0xffff ) << 5 ) | 16;
                    $entry_stub = pack( "V5", 0x94000005, $movz, $movk, 0xD4001001, 0xD4200000 );
                }
                else {
                    # x86_64 (Intel Mac) native exit stub:
                    # - call main:      e8 0c 00 00 00 (Relative call 12 bytes ahead)
                    # - mov rdi, rax:   48 89 c7       (Copy main's return code to first argument)
                    # - mov eax, sys:   b8 ...         (0x2000001 is exit syscall with macOS offset)
                    # - syscall:        0f 05
                    # - ud2:            0f 0b
                    $entry_stub = pack( "C V", 0xE8, 12 );
                    $entry_stub .= pack( "C3",  0x48, 0x89, 0xC7 );
                    $entry_stub .= pack( "C V", 0xB8, $exit_sys );
                    $entry_stub .= pack( "C2",  0x0F, 0x05 );
                    $entry_stub .= pack( "C2",  0x0F, 0x0B );
                }
                $text = $entry_stub . $text_raw;
            }

            # Automatically calculate layout if it wasn't called beforehand
            if ( !defined $self->layout ) {
                $self->pre_layout( length($text), length($data_bytes), $arch, $os );
            }
            my $l              = $self->layout;
            my $base           = $self->image_base;
            my $page_size      = $platform->page_size;                                       # 16KB for Apple Silicon, 4KB for Intel
            my $cputype        = ( $arch =~ /aarch64|arm64/i ) ? 0x0100000c : 0x01000007;    # CPU_TYPE_ARM64 or CPU_TYPE_X86_64
            my $cpusubtype     = ( $arch =~ /aarch64|arm64/i ) ? 0          : 3;             # CPU_SUBTYPE_ARM64_ALL or CPU_SUBTYPE_I386_ALL
            my $filetype       = ( $self->type eq 'shared' ) ? 6 : 2;                        # MH_DYLIB or MH_EXECUTE
            my @debug_sections = grep { $_->{name} =~ /^\.debug/ } $l->sections;
            my $_uleb          = sub {
                my $v   = shift;
                my $out = '';
                do {
                    my $byte = $v & 0x7F;
                    $v >>= 7;
                    $byte |= 0x80 if $v;
                    $out .= pack( 'C', $byte );
                } while ($v);
                return $out;
            };
            my $lib_name = "/usr/lib/libSystem.B.dylib\0";
            while ( length($lib_name) % 8 != 0 ) { $lib_name .= "\0"; }

            # LC_LOAD_DYLIB load command (Loads macOS system library)
            my $lc_load_libsystem = pack( 'L<6', 0xC, 24 + length($lib_name), 24, 2, 0x010000, 0x010000 ) . $lib_name;

            # Setup dynamic binding info for resolving FFI imports
            my $bind_info      = '';
            my $bind_info_size = 0;
            my $got_sec        = eval { $l->get('.got') };
            if ($got_sec) {
                my $data_sec = eval { $l->get('.data') };
                my $data_rva = $data_sec ? $data_sec->{rva} : $got_sec->{rva};
                $bind_info .= pack( 'C', 0x11 );
                $bind_info .= pack( 'C', 0x51 );
                $bind_info .= pack( 'C', 0x72 ) . $_uleb->( $got_sec->{rva} - $data_rva );
                $bind_info .= pack( 'C', 0x40 ) . "_dlopen\0";
                $bind_info .= pack( 'C', 0x90 );
                $bind_info .= pack( 'C', 0x40 ) . "_dlsym\0";
                $bind_info .= pack( 'C', 0x90 );
                $bind_info .= pack( 'C', 0x40 ) . "_pthread_create\0";
                $bind_info .= pack( 'C', 0x90 );
                $bind_info .= pack( 'C', 0x00 );
                $bind_info_size = length($bind_info);
                while ( length($bind_info) % 8 != 0 ) { $bind_info .= "\0"; }
            }
            my ( $trie, $symtab, $strtab, $lc_id_dylib ) = ( '', '', '', '' );
            my ( $num_syms, $le_off, $trie_size, $symtab_size, $strtab_size ) = ( 0, 0, 0, 0, 0 );
            if ( $self->type eq 'shared' ) {
                require File::Basename;
                my $dylib_name     = File::Basename::basename($output_file);
                my $dylib_name_pad = $dylib_name . "\0";
                while ( length($dylib_name_pad) % 8 != 0 ) { $dylib_name_pad .= "\0"; }

                # LC_ID_DYLIB (Identifies the output dylib name)
                $lc_id_dylib = pack( 'L<6', 0xD, 24 + length($dylib_name_pad), 24, 1, 1, 1 ) . $dylib_name_pad;
                my @exports = @{ $self->exported_funcs // [] };
                my %export_rvas;
                for my $name (@exports) {
                    $export_rvas{"_$name"} = $l->get('.text')->{rva} + ( $self->labels->{"E_$name"} // 0 );
                }
                my @syms = sort keys %export_rvas;
                $num_syms = scalar @syms;
                $strtab   = "\0";
                my %strx;
                for my $sym (@syms) {
                    $strx{$sym} = length($strtab);
                    $strtab .= $sym . "\0";
                }
                while ( length($strtab) % 8 != 0 ) { $strtab .= "\0"; }
                for my $sym (@syms) {
                    $symtab .= pack( 'L< C C S< Q<', $strx{$sym}, 0x0f, 1, 0, $base + $export_rvas{$sym} );
                }
                if ( $num_syms > 0 ) {
                    my @nodes;
                    for my $sym (@syms) {
                        my $rva        = $export_rvas{$sym};
                        my $flags_u    = $_uleb->(0);
                        my $rva_u      = $_uleb->($rva);
                        my $term_data  = $flags_u . $rva_u;
                        my $node_bytes = $_uleb->( length($term_data) ) . $term_data . pack( 'C', 0 );
                        push @nodes, { sym => $sym, bytes => $node_bytes };
                    }
                    my %node_offsets;
                    for ( 1 .. 3 ) {
                        my $root = pack( 'C', 0 ) . pack( 'C', $num_syms );
                        for my $n (@nodes) { $root .= $n->{sym} . "\0" . $_uleb->( $node_offsets{ $n->{sym} } // 1024 ); }
                        my $offset = length($root);
                        for my $n (@nodes) {
                            $node_offsets{ $n->{sym} } = $offset;
                            $offset += length( $n->{bytes} );
                        }
                    }
                    $trie = pack( 'C', 0 ) . pack( 'C', $num_syms );
                    for my $n (@nodes) { $trie .= $n->{sym} . "\0" . $_uleb->( $node_offsets{ $n->{sym} } ); }
                    for my $n (@nodes) { $trie .= $n->{bytes}; }
                    while ( length($trie) % 8 != 0 ) { $trie .= "\0"; }
                }
            }
            $trie_size   = length($trie);
            $symtab_size = length($symtab);
            $strtab_size = length($strtab);

            # Enforce Minimum Linkedit size to prevent sparse file truncation issues
            my $le_payload_size = length($bind_info) + $trie_size + $symtab_size + $strtab_size;
            $l->get('.linkedit')->{size} = $le_payload_size > 64 ? $le_payload_size : 64;
            $l->calculate($page_size);
            $le_off = $l->get('.linkedit')->{off};
            my %seg_names = ( '.text' => '__TEXT', '.data' => '__DATA', '.got' => '__DATA', );
            my %sec_names = ( '.text' => '__text', '.data' => '__data', '.got' => '__got', );
            for my $s ( $l->sections ) {
                if ( $s->{name} =~ /^\.debug_/ ) {
                    $seg_names{ $s->{name} } = '__DWARF';
                    ( my $macho_name = $s->{name} ) =~ s/^\./__/;
                    $sec_names{ $s->{name} } = $macho_name;
                }
            }
            my @text_sections = grep { $_->{name} eq '.text' } $l->sections;
            my $t_sec         = $text_sections[0];
            my @data_sections = grep { $_->{name} eq '.data' || $_->{name} eq '.got' } $l->sections;
            my $t_vmsize      = $t_sec->{off} + $t_sec->{size};
            my $t_seg_size    = ( $t_vmsize + $page_size - 1 ) & ~( $page_size - 1 );
            my ( $d_start_rva, $d_start_off, $d_size, $d_seg_size );
            if (@data_sections) {
                $d_start_rva = $data_sections[0]->{rva};
                $d_start_off = $data_sections[0]->{off};
                $d_size      = 0;
                for (@data_sections) { $d_size += $_->{size}; }
                $d_seg_size = ( $d_size + $page_size - 1 ) & ~( $page_size - 1 );
            }
            my @cmds = ();

            # PageZero Segment Header
            if ( $self->type ne 'shared' ) {
                push @cmds, pack(
                    'L<2 a16 Q<4 L<4', 0x19,    # cmd (LC_SEGMENT_64)
                    72,                         # cmdsize
                    "__PAGEZERO",               # segname
                    0,                          # vmaddr
                    $base,                      # vmsize
                    0,                          # fileoff
                    0,                          # filesize
                    0,                          # maxprot (none)
                    0,                          # initprot (none)
                    0,                          # nsects
                    0                           # flags
                );
            }

            # TEXT Segment Header
            my $t_cmd_size = 72 + 80 * scalar(@text_sections);
            my $t_cmd      = pack(
                'L<2 a16 Q<4 L<4', 0x19,    # cmd (LC_SEGMENT_64)
                $t_cmd_size,                # cmdsize
                "__TEXT",                   # segname
                $base,                      # vmaddr
                $t_seg_size,                # vmsize
                0,                          # fileoff
                $t_seg_size,                # filesize
                5,                          # maxprot (VM_PROT_READ | VM_PROT_EXECUTE)
                5,                          # initprot (VM_PROT_READ | VM_PROT_EXECUTE)
                scalar(@text_sections),     # nsects
                0                           # flags
            );
            for my $s (@text_sections) {

                # TEXT Sections (80 bytes each)
                $t_cmd .= pack(
                    'a16 a16 Q<2 L<2 L<3 L<2 L<',
                    $sec_names{ $s->{name} },
                    "__TEXT",   $base + $s->{rva},
                    $s->{size}, $s->{off}, 4, 0, 0, 0x80000400, 0, 0, 0
                );
            }
            push @cmds, $t_cmd;

            # DATA Segment Header (only if we have data or GOT sections)
            if (@data_sections) {
                my $d_cmd_size = 72 + 80 * scalar(@data_sections);
                my $d_cmd      = pack(
                    'L<2 a16 Q<4 L<4', 0x19,    # cmd (LC_SEGMENT_64)
                    $d_cmd_size,                # cmdsize
                    "__DATA",                   # segname
                    $base + $d_start_rva,       # vmaddr
                    $d_seg_size,                # vmsize
                    $d_start_off,               # fileoff
                    $d_size,                    # filesize
                    3,                          # maxprot (VM_PROT_READ | VM_PROT_WRITE)
                    3,                          # initprot (VM_PROT_READ | VM_PROT_WRITE)
                    scalar(@data_sections),     # nsects
                    0                           # flags
                );
                for my $s (@data_sections) {

                    # DATA Sections (80 bytes each)
                    $d_cmd .= pack(
                        'a16 a16 Q<2 L<2 L<3 L<2 L<',
                        $sec_names{ $s->{name} },
                        "__DATA",   $base + $s->{rva},
                        $s->{size}, $s->{off}, 3, 0, 0, 0, 0, 0, 0
                    );
                }
                push @cmds, $d_cmd;
            }

            # LINKEDIT Segment Header
            my $le_sec      = $l->get('.linkedit');
            my $le_seg_size = ( $le_sec->{size} + $page_size - 1 ) & ~( $page_size - 1 );
            push @cmds, pack(
                'L<2 a16 Q<4 L<4', 0x19,    # cmd (LC_SEGMENT_64)
                72,                         # cmdsize
                "__LINKEDIT",               # segname
                $base + $le_sec->{rva},     # vmaddr
                $le_seg_size,               # vmsize
                $le_sec->{off},             # fileoff
                $le_sec->{size},            # filesize
                1,                          # maxprot (VM_PROT_READ)
                1,                          # initprot (VM_PROT_READ)
                0,                          # nsects
                0                           # flags
            );
            push @cmds, $lc_id_dylib if $self->type eq 'shared';

            # LC_LOAD_DYLINKER (Loads dynamic linker `/usr/lib/dyld`)
            push @cmds, pack( 'L<3', 0xE, 32, 12 ) . "/usr/lib/dyld\0\0\0\0\0\0\0";
            push @cmds, $lc_load_libsystem;

            # LC_DYLD_INFO_ONLY (48 bytes)
            my $export_off = $self->type eq 'shared' ? $le_off + length($bind_info) : 0;
            my $export_sz  = $self->type eq 'shared' ? $trie_size                   : 0;
            push @cmds, pack(
                'L<12', 0x80000022,         # cmd
                48,                         # cmdsize
                0, 0,                       # rebase_off, rebase_size
                $le_off,                    # bind_off
                $bind_info_size,            # bind_size
                0, 0,                       # weak_bind_off, weak_bind_size
                0, 0,                       # lazy_bind_off, lazy_bind_size
                $export_off,                # export_off
                $export_sz                  # export_size
            );

            # LC_SYMTAB (24 bytes)
            my $symtab_off = $le_off + length($bind_info) + $trie_size;
            push @cmds, pack(
                'L<6', 0x2,                    # cmd
                24,                            # cmdsize
                $symtab_off,                   # symoff
                $num_syms,                     # nsyms
                $symtab_off + $symtab_size,    # stroff
                $strtab_size                   # strsize
            );

            # LC_DYSYMTAB (80 bytes)
            push @cmds, pack(
                'L<20', 0xB,                   # cmd
                80,                            # cmdsize
                0,         0,                  # ilocalsym, nlocalsym
                0,         $num_syms,          # iextdefsym, nextdefsym
                $num_syms, 0,                  # iundefsym, nundefsym
                (0) x 14                       # reserved / empty
            );

            # LC_MAIN (24 bytes - Points directly to our TEXT segment start off)
            push @cmds, pack(
                'L<2 Q<2', 0x80000028,         # cmd (LC_MAIN)
                24,                            # cmdsize
                $t_sec->{off},                 # entryoff (physical offset of _start)
                0                              # stacksize
            ) if $self->type eq 'exe';
            if (@debug_sections) {
                my $cmdsize      = 72 + 80 * scalar(@debug_sections);
                my $dw_start_rva = $debug_sections[0]->{rva};
                my $dw_start_off = $debug_sections[0]->{off};
                my $dw_size      = 0;
                for (@debug_sections) { $dw_size += $_->{size}; }
                my $dw_size_aligned = ( $dw_size + $page_size - 1 ) & ~( $page_size - 1 );
                my $dw_cmd          = pack( 'L<2 a16 Q<4 L<4',
                    0x19, $cmdsize, "__DWARF", $base + $dw_start_rva,
                    $dw_size_aligned, $dw_start_off, $dw_size_aligned, 0, 0, scalar(@debug_sections), 0 );
                for my $s (@debug_sections) {
                    $dw_cmd .= pack(
                        'a16 a16 Q<2 L<2 L<3 L<2 L<',
                        $sec_names{ $s->{name} },
                        "__DWARF",  $base + $s->{rva},
                        $s->{size}, $s->{off}, 0, 0, 0, 0, 0, 0, 0
                    );
                }
                push @cmds, $dw_cmd;
            }
            my $ncmds      = scalar(@cmds);
            my $sizeofcmds = 0;
            for (@cmds) { $sizeofcmds += length($_); }
            open my $fh, '>', $output_file or die $!;
            binmode $fh;

            # mach_header_64 (Exactly 32 bytes)
            my $flags = 0x200085 | 0x00200000;
            $flags = 0x100085 if $self->type eq 'shared';
            print $fh pack(
                'L<7 L<', 0xfeedfacf,    # magic (MH_MAGIC_64)
                $cputype,                # cputype
                $cpusubtype,             # cpusubtype
                $filetype,               # filetype
                $ncmds,                  # ncmds
                $sizeofcmds,             # sizeofcmds
                $flags,                  # flags
                0                        # reserved
            );
            print $fh $_ for @cmds;

            # Write __TEXT,__text segment (padded to layout size)
            seek( $fh, $t_sec->{off}, 0 );
            my $text_payload = $text;
            $text_payload .= ( "\0" x ( $t_sec->{size} - length($text_payload) ) ) if length($text_payload) < $t_sec->{size};
            print $fh $text_payload;

            # Write __DATA,__data segment (padded to layout size) if section exists
            my $d_sec_actual = eval { $l->get('.data') };
            if ($d_sec_actual) {
                seek( $fh, $d_sec_actual->{off}, 0 );
                my $data_payload = $data_bytes // '';
                $data_payload .= ( "\0" x ( $d_sec_actual->{size} - length($data_payload) ) ) if length($data_payload) < $d_sec_actual->{size};
                print $fh $data_payload;
            }

            # Write __DATA,__got segment (padded to layout size) if section exists
            if ($got_sec) {
                seek( $fh, $got_sec->{off}, 0 );
                my $got_payload = pack( 'Q< Q< Q<', 0, 0, 0 );
                $got_payload .= ( "\0" x ( $got_sec->{size} - length($got_payload) ) ) if length($got_payload) < $got_sec->{size};
                print $fh $got_payload;
            }

            # Write LINKEDIT segment (padded to layout size)
            seek( $fh, $le_sec->{off}, 0 );
            my $le_payload = $bind_info . $trie . $symtab . $strtab;
            $le_payload .= ( "\0" x ( $le_sec->{size} - length($le_payload) ) ) if length($le_payload) < $le_sec->{size};
            print $fh $le_payload;
            if (@debug_sections) {
                for my $s (@debug_sections) {
                    seek( $fh, $s->{off}, 0 );
                    my $dw_payload = $self->debug_section( $s->{name} ) || '';
                    $dw_payload .= ( "\0" x ( $s->{size} - length($dw_payload) ) ) if length($dw_payload) < $s->{size};
                    print $fh $dw_payload;
                }
            }
            close $fh;
            chmod 0755, $output_file;
            if ( $os =~ /^(macos|darwin)/i ) {
                my $cs_out = `codesign -f -s - "$output_file" 2>&1`;
                warn "codesign output: $cs_out" if length $cs_out;
                warn "codesign exit: " . ( $? >> 8 ) . "\n";
            }
            return $output_file;
        }
    }

    class Brocken::Jenny::Linker::PE : isa(Brocken::Jenny::Linker) {

        method write_executable ( $output_file, $code_bytes, $platform, $passed_argument = undef, $debug_bytes = undef ) {

            # Ensure $platform is normalized into a platform object if a raw string is passed
            $platform = Brocken::Katsuro::Platform::parse($platform) unless ref $platform;
            my $full_code    = ref $code_bytes eq 'HASH' ? $code_bytes->{binary}                        : $code_bytes;
            my $writable_off = ref $code_bytes eq 'HASH' ? ( $code_bytes->{writable_data_offset} // 0 ) : 0;
            my $text_bytes   = $writable_off             ? substr( $full_code, 0, $writable_off )       : $full_code;
            my $data_bytes   = $writable_off             ? substr( $full_code, $writable_off )          : '';
            my $has_data     = length($data_bytes) > 0;
            my $has_debug    = defined $debug_bytes ? 1 : 0;
            my $has_reloc    = 1;                              # ARM64 Windows strictly enforces ASLR / .reloc presence
            my $num_sections = 1 + ( $has_data ? 1 : 0 ) + $has_reloc + ( $has_debug ? 1 : 0 );
            open my $fh, '>', $output_file or die "Cannot open $output_file for writing: $!";
            binmode $fh;

            # DOS MZ Header (Exactly 64 bytes: a2=magic, v29=29 WORDS, V=e_lfanew)
            # We explicitly use v29 and count-matched repetition to avoid pack argument shifts.
            my $dos_header = pack(
                'a2 v29 V', 'MZ',    # e_magic: DOS Magic Signature
                0x0090,              # e_cblp: Bytes on last page of file (144)
                0x0003,              # e_cp: Pages in file (3)
                0x0000,              # e_crlc: Relocations (0)
                0x0004,              # e_cparhdr: Size of header in paragraphs (4)
                0x0000,              # e_minalloc: Minimum extra paragraphs needed (0)
                0xffff,              # e_maxalloc: Maximum extra paragraphs needed (65535)
                0x0000,              # e_ss: Initial (relative) SS value (0)
                0x0100,              # e_sp: Initial SP value (256)
                0x0000,              # e_csum: Checksum (0)
                0x0000,              # e_ip: Initial IP value (0)
                0x0000,              # e_cs: Initial (relative) CS value (0)
                0x0040,              # e_lfarlc: File address of relocation table (64)
                0x0000,              # e_ovno: Overlay number (0)
                (0) x 4,             # e_res: Reserved words (4 WORDS)
                0,                   # e_oemid: OEM identifier (0)
                0,                   # e_oeminfo: OEM information (0)
                (0) x 10,            # e_res2: Reserved words (10 WORDS)
                0x00000080           # e_lfanew: File address of new exe header (Offset 128 / 0x80)
            );
            my $dos_stub     = ( "\x00" x 64 );    # 64 bytes padding to align PE header at offset 128 (0x80)
            my $pe_signature = "PE\x00\x00";

            # COFF File Header
            my $machine     = $platform->is_arm64 ? 0xAA64 : 0x8664;
            my $timestamp   = $ENV{SOURCE_DATE_EPOCH} || time();
            my $file_header = pack(
                'v2 V3 v2', $machine,    # Machine Architecture
                $num_sections,           # Number of Sections
                $timestamp,              # TimeDateStamp
                0, 0,                    # PointerToSymbolTable, NumberOfSymbols
                240,                     # SizeOfOptionalHeader (PE32+)
                0x0022                   # Characteristics (EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE)
            );

            # Layout sections
            my $section_table   = '';
            my $size_of_headers = ( 392 + ( $num_sections * 40 ) + 511 ) & ~511;
            my $sec_raw_ptr     = $size_of_headers;
            my $sec_rva         = 0x1000;

            # .text
            my $sec_raw_code_size = ( length($text_bytes) + 511 ) & ~511;
            $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                ".text\x00\x00\x00", length($text_bytes), $sec_rva, $sec_raw_code_size, $sec_raw_ptr, 0, 0, 0, 0, 0x60000020 );
            $sec_rva     += ( length($text_bytes) + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_code_size;

            # .data
            my $sec_raw_data_size = 0;
            if ($has_data) {
                $sec_raw_data_size = ( length($data_bytes) + 511 ) & ~511;
                $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                    ".data\x00\x00\x00", length($data_bytes), $sec_rva, $sec_raw_data_size, $sec_raw_ptr, 0, 0, 0, 0, 0xC0000040 );
                $sec_rva     += ( length($data_bytes) + 4095 ) & ~4095;
                $sec_raw_ptr += $sec_raw_data_size;
            }

            # .reloc
            my $reloc_bytes        = pack( 'V V v v', 0x1000, 12, 0, 0 );
            my $reloc_rva          = $sec_rva;
            my $sec_raw_reloc_size = ( length($reloc_bytes) + 511 ) & ~511;
            $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                ".reloc\x00\x00", length($reloc_bytes), $sec_rva, $sec_raw_reloc_size, $sec_raw_ptr, 0, 0, 0, 0, 0x42000040 );
            $sec_rva     += ( length($reloc_bytes) + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_reloc_size;

            # .debug_l
            my $sec_raw_debug_size = 0;
            if ($has_debug) {
                $sec_raw_debug_size = ( length($debug_bytes) + 511 ) & ~511;
                $section_table .= pack( 'a8 V2 V2 V2 v2 V', ".debug_l", length($debug_bytes), $sec_rva, $sec_raw_debug_size, $sec_raw_ptr, 0, 0, 0, 0,
                    0x42000040 );
                $sec_rva     += ( length($debug_bytes) + 4095 ) & ~4095;
                $sec_raw_ptr += $sec_raw_debug_size;
            }
            my $size_of_image  = $sec_rva;
            my $size_of_code   = $sec_raw_code_size;
            my $init_data_size = $sec_raw_data_size + $sec_raw_reloc_size + $sec_raw_debug_size;
            my $os_ver         = 6;                                                                # Compatibility with older Windows platforms
            my $opt_header     = pack(
                'v C2 V3 V2 Q< V2 v4 v2 V V V V v2 Q<4 V2', 0x020b,                        # Magic Number (PE32+)
                14,                                         10,                            # Major/Minor LinkerVersion
                $size_of_code,                              $init_data_size, 0, 0x1000,    # AddressOfEntryPoint
                0x1000,                                                                    # BaseOfCode
                0x140000000,                                                               # ImageBase
                4096,                                                                      # SectionAlignment
                512,                                                                       # FileAlignment
                $os_ver, 0,                                                                # Major/Minor OS
                0,       0,                                                                # Major/Minor Image
                $os_ver, 0,                                                                # Major/Minor Subsystem
                0,                                                                         # Win32VersionValue
                $size_of_image, $size_of_headers, 0,                                       # CheckSum
                3,         # Subsystem (Windows Console)
                0x8160,    # DllCharacteristics (DYNAMIC_BASE | NX_COMPAT | TS_AWARE | HIGH_ENTROPY_VA)
                0x100000, 0x1000, 0x100000, 0x1000,    # Stack/Heap Reserve/Commit
                0,                                     # LoaderFlags
                16                                     # NumberOfRvaAndSizes
            );
            my $data_dirs = "\x00" x 128;
            if ( ref $code_bytes eq 'HASH' ) {
                my $import_rva  = $code_bytes->{import_descriptor_rva}  // 0;
                my $import_size = $code_bytes->{import_descriptor_size} // 0;
                if ($import_rva) {
                    substr $data_dirs, 8,  4, pack( 'V', $import_rva );
                    substr $data_dirs, 12, 4, pack( 'V', $import_size );
                }
            }

            # Insert Base Relocation Data Directory (Index 5 = Offset 40)
            substr $data_dirs, 40, 4, pack( 'V', $reloc_rva );
            substr $data_dirs, 44, 4, pack( 'V', length($reloc_bytes) );
            $opt_header .= $data_dirs;
            print $fh $dos_header, $dos_stub, $pe_signature, $file_header, $opt_header, $section_table;
            my $headers_len
                = length($dos_header)
                + length($dos_stub)
                + length($pe_signature)
                + length($file_header)
                + length($opt_header)
                + length($section_table);
            print $fh ( "\x00" x ( $size_of_headers - $headers_len ) );
            print $fh $text_bytes;
            print $fh ( "\x00" x ( $sec_raw_code_size - length($text_bytes) ) );

            if ($has_data) {
                print $fh $data_bytes;
                print $fh ( "\x00" x ( $sec_raw_data_size - length($data_bytes) ) );
            }
            if ($has_reloc) {
                print $fh $reloc_bytes;
                print $fh ( "\x00" x ( $sec_raw_reloc_size - length($reloc_bytes) ) );
            }
            if ($has_debug) {
                print $fh $debug_bytes;
                print $fh ( "\x00" x ( $sec_raw_debug_size - length($debug_bytes) ) );
            }
            close $fh;
            chmod 0755, $output_file;
        }

        method write_shared_library ( $output_file, $code_bytes, $platform, $debug_bytes = undef ) {
            my $p = ref($platform) ? $platform : Brocken::Katsuro::Platform::parse($platform);
            $self->write_executable( $output_file, $code_bytes, $p, undef, $debug_bytes );
            open my $fh, '+<', $output_file or die $!;
            binmode $fh;
            seek $fh, 0x96, 0;
            print $fh pack( "v", 0x2022 );    # EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE | IMAGE_FILE_DLL
            close $fh;
        }
    }
}

class Brocken::Jenny::Linker::ELF64 : isa(Brocken::Jenny::Linker) {

        method _detect_elf_info ( $ref = undef ) {
            my @candidates = $ref ? ($ref) : ( '/bin/sh', '/sbin/init', '/usr/bin/env', '/boot/system/bin/sh', '/boot/system/bin/env' );
            for my $candidate (@candidates) {
                next if !-e $candidate || !-r _;
                open my $fh, '<:raw', $candidate or next;
                my $bytes = read( $fh, my $ehdr, 64 );
                close $fh;
                next if $bytes != 64;
                next if substr( $ehdr, 0, 4 ) ne "\x7fELF";
                my $osabi    = ord( substr( $ehdr, 7, 1 ) );
                my $ei_class = ord( substr( $ehdr, 4, 1 ) );
                next if $ei_class != 1 && $ei_class != 2;
                my ( $e_phoff, $e_phentsize, $e_phnum );

                if ( $ei_class == 2 ) {
                    $e_phoff     = unpack( 'Q', substr( $ehdr, 32, 8 ) );
                    $e_phentsize = unpack( 'S', substr( $ehdr, 54, 2 ) );
                    $e_phnum     = unpack( 'S', substr( $ehdr, 56, 2 ) );
                }
                else {
                    $e_phoff     = unpack( 'L', substr( $ehdr, 28, 4 ) );
                    $e_phentsize = unpack( 'S', substr( $ehdr, 42, 2 ) );
                    $e_phnum     = unpack( 'S', substr( $ehdr, 44, 2 ) );
                }
                next if !$e_phnum || !$e_phentsize;
                open my $fh2, '<:raw', $candidate or next;
                seek( $fh2, $e_phoff, 0 );
                my $ph_bytes = $e_phentsize * $e_phnum;
                my $read_ok  = read( $fh2, my $phdrs, $ph_bytes );
                close $fh2;
                next if !$read_ok;
                my ( $note_data, $has_pintable ) = ( '', 0 );

                for my $i ( 0 .. $e_phnum - 1 ) {
                    my $phdr   = substr( $phdrs, $i * $e_phentsize, $e_phentsize );
                    my $p_type = unpack( 'L', substr( $phdr, 0, 4 ) );
                    if ( $p_type == 4 && !$note_data ) {
                        my ( $p_offset, $p_filesz );
                        if ( $ei_class == 2 ) {
                            $p_offset = unpack( 'Q', substr( $phdr, 8,  8 ) );
                            $p_filesz = unpack( 'Q', substr( $phdr, 32, 8 ) );
                        }
                        else {
                            $p_offset = unpack( 'L', substr( $phdr, 4,  4 ) );
                            $p_filesz = unpack( 'L', substr( $phdr, 16, 4 ) );
                        }
                        open my $fh3, '<:raw', $candidate or next;
                        seek( $fh3, $p_offset, 0 );
                        read( $fh3, $note_data, $p_filesz );
                        close $fh3;
                    }
                    elsif ( $p_type == 0x65a3dbe9 && !$has_pintable ) {
                        $has_pintable = 1;
                    }
                }
                return ( $osabi, $note_data, $has_pintable );
            }
            return ( 0, '', 0 );
        }

        # Structurally compliant segment layout grouping all read-only sections
        # in the RX segment, and keeping only writable sections in the RW segment.
        method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
            $l->add_section( '.text', $t, 5 );    # RX

            # Read-only metadata sections (strictly mapped to RX segment)
            $l->add_section( '.interp',   512,  2 ) if $self->type eq 'exe';
            $l->add_section( '.dynstr',   4096, 2 );
            $l->add_section( '.dynsym',   4096, 2 );
            $l->add_section( '.rela.dyn', 4096, 2 );
            $l->add_section( '.hash',     4096, 2 );

            # Writable data and dynamic linking tables (mapped to RW segment)
            $l->add_section( '.dynamic',  4096, 3 ); # RW
            $l->add_section( '.data', $d, 6 );    # RW
            $l->add_section( '.got',      512,  6 );                           # RW

            if ( $dbg >= 1 ) {
                $l->add_section( '.debug_line',     4096, 0 );
                $l->add_section( '.debug_info',     4096, 0 );
                $l->add_section( '.debug_abbrev',   4096, 0 );
                $l->add_section( '.debug_frame',    4096, 0 );
                $l->add_section( '.debug_aranges',  4096, 0 );
                $l->add_section( '.debug_pubnames', 4096, 0 );
                $l->add_section( '.eh_frame',       4096, 0 );
            }
        }

        method import_rva($name) {
            my $imports = { dlopen => 0, dlsym => 8, pthread_create => 16, exit => 24 };
            return $self->layout->get('.got')->{rva} + ( $imports->{$name} // die "Unknown ELF import: $name" );
        }
        method image_base () { return $self->type eq 'shared' ? 0 : 0x400000; }

        method write_executable ( $output_file, $code_bytes, $platform, $shared = false, $debug_bytes = undef ) {
            # Ensure $platform is normalized into a platform object if a raw string is passed
            $platform = Brocken::Katsuro::Platform::parse($platform) unless ref $platform;

            # Automatically calculate layout if it wasn't called beforehand
            if ( !defined $self->layout ) {
                $self->pre_layout( length($code_bytes) + 32, 0, $platform->arch, $platform->os );
            }
            my $l          = $self->layout;
            my $is_pie     = $platform->is_bsd || $platform->is_haiku;
            my $base       = $is_pie ? 0 : $self->image_base;
            my $elf_type   = $shared ? 3 : ( $is_pie ? 3 : 2 );
            my $text_rva   = $l->get('.text')->{rva};
            my $got_rva    = $l->get('.got')->{rva};
            my $page_align = $l->section_align;

            my $text = $code_bytes;
            if ( $self->type eq 'exe' ) {
                my $entry_stub = '';
                if ( $platform->is_arm64 ) {
                    # ARM64 (AArch64) Dynamic exit stub calling exit() via GOT:
                    # - bl main (offset 32): 0x94000008
                    # - ldr x16, [pc, 20]:   0x580000b0 (Loads exit GOT slot pointer from stub)
                    # - ldr x16, [x16]:      0xf9400210 (Dereferences pointer)
                    # - br x16:              0xd61f0200 (Jumps directly to C exit stub)
                    # - nops to pad to 24 bytes
                    # - got_slot_addr:       8-byte pointer to the exit GOT slot
                    my $got_slot_addr = $base + $got_rva + 24;
                    $entry_stub = pack( "V6 Q<", 0x94000008, 0x580000b0, 0xf9400210, 0xd61f0200, 0xd503201f, 0xd503201f, $got_slot_addr );
                }
                elsif ( $platform->is_riscv64 ) {
                    # RISC-V 64-bit native exit stub:
                    # - jal ra, 16 (relative call offset +16 bytes -> 4 instructions)
                    # - li a7, sys (addi a7, x0, sys -> 4 bytes)
                    # - ecall      (trigger syscall -> 4 bytes)
                    # - unimp      (safety crash -> 4 bytes)
                    my $li = ( $platform->syscall('exit') << 20 ) | 0x00000893;
                    $entry_stub = pack( "V4", 0x010000EF, $li, 0x00000073, 0x00000000 );
                }
                else {
                    # x86_64 Direct syscall exit stub (no GOT dependency, 17 bytes):
                    # - call main:      E8 0C 00 00 00 (Relative call 12 bytes ahead)
                    # - mov rdi, rax:   48 89 C7       (Copy main's return code to rdi)
                    # - mov eax, SYS:   B8 <sys_exit>  (Load exit syscall number)
                    # - syscall:        0F 05          (Invoke kernel)
                    # - ud2:            0F 0B          (Safety crash)
                    my $exit_sys = $platform->syscall('exit') // 1;
                    $entry_stub = pack( "C V", 0xE8, 12 );
                    $entry_stub .= pack( "C3",  0x48, 0x89, 0xC7 );
                    $entry_stub .= pack( "C V", 0xB8, $exit_sys );
                    $entry_stub .= pack( "C2",  0x0F, 0x05 );
                    $entry_stub .= pack( "C2",  0x0F, 0x0B );
                }
                $text = $entry_stub . $code_bytes;
            }

            # Probe system binaries for the correct OSABI and PT_NOTE data
            my ( undef, $note_data, $has_pintable ) = $self->_detect_elf_info();
            my $osabi = 0;

            # Set OSABI and ABI note explicitly per platform to guarantee kernel recognition.
            if ( $platform->is_freebsd ) {
                $osabi     = 9;    # ELFOSABI_FREEBSD
                $note_data = pack( 'L<3 a8 L<', 8, 4, 1, "FreeBSD\0", 1400097 );
            }
            elsif ( $platform->is_midnightbsd ) {
                $osabi     = 9;    # ELFOSABI_FREEBSD (MidnightBSD inherits from FreeBSD)
                $note_data = pack( 'L<3 a12 L<', 12, 4, 1, "MidnightBSD\0", 300000 );
            }
            elsif ( $platform->is_netbsd ) {
                $osabi = 2;       # ELFOSABI_NETBSD
            }
            elsif ( $platform->is_openbsd ) {
                $osabi = 6;       # ELFOSABI_OPENBSD
            }
            elsif ( $platform->is_dragonflybsd ) {
                $osabi = 9;       # ELFOSABI_FREEBSD (DragonFly uses FreeBSD OSABI)
            }

            # Per-OS interpreter path for dynamic executables
            my %interp_map = (
                linux        => '/lib64/ld-linux-x86-64.so.2',
                linux_arm    => '/lib/ld-linux-aarch64.so.1',
                linux_riscv  => '/lib/ld-linux-riscv64-lp64d.so.1',
                freebsd      => '/libexec/ld-elf.so.1',
                netbsd       => '/usr/libexec/ld.elf_so',
                openbsd      => '/usr/libexec/ld.so',
                dragonfly    => '/libexec/ld-elf.so.2',
                dragonflybsd => '/libexec/ld-elf.so.2',
                solaris      => '/lib/64/ld.so.1',
                midnightbsd  => '/libexec/ld-elf.so.1',
                haiku        => '/system/runtime_loader'
            );

            # Per-OS libc name fallback for DT_NEEDED
            my %libc_map = (
                linux        => 'libc.so.6',
                linux_arm    => 'libc.so.6',
                linux_riscv  => 'libc.so.6',
                freebsd      => 'libc.so.7',
                netbsd       => 'libc.so.12',
                openbsd      => 'libc.so.98.1',
                dragonfly    => 'libc.so.8',
                dragonflybsd => 'libc.so.8',
                solaris      => 'libc.so.1',
                midnightbsd  => 'libc.so.7',
                haiku        => 'libroot.so'
            );

            # Generate pintable data for OpenBSD (syscall allowlisting)
            my $pintable_data = '';
            if ($has_pintable) {
                my $pos      = 0;
                my $text_rva_actual = $l->get('.text')->{rva};
                if ( $platform->is_x64 ) {
                    while ( ( my $idx = index( $text, "\x0F\x05", $pos ) ) != -1 ) {
                        my $vaddr = $base + $text_rva_actual + $idx;
                        $pintable_data .= pack( 'L<L<', $vaddr, 1 );
                        $pintable_data .= pack( 'L<L<', $vaddr, 4 );
                        $pos = $idx + 2;
                    }
                }
                else {
                    while ( ( my $idx = index( $text, "\x01\x00\x00\xd4", $pos ) ) != -1 ) {
                        my $vaddr = $base + $text_rva_actual + $idx;
                        $pintable_data .= pack( 'L<L<', $vaddr, 1 );
                        $pintable_data .= pack( 'L<L<', $vaddr, 4 );
                        $pos = $idx + 4;
                    }
                }
            }

            # Setup Interp path for executable
            my $interp     = '';
            my $has_interp = 0;
            my $os_base    = ( $platform->os =~ /^([A-Za-z]+)/ )[0] // $platform->os;
            if ( $self->type eq 'exe' ) {
                my $interp_key
                    = ( $platform->is_arm64 && $platform->is_linux ) ? 'linux_arm' :
                    ( $platform->is_riscv64 && $platform->is_linux ) ? 'linux_riscv' :
                    $os_base;
                my $ipath = $interp_map{$interp_key} // '/lib/ld.so.1';
                if ( length $ipath ) {
                    $interp                    = $ipath . "\0";
                    $l->get('.interp')->{size} = length($interp);
                    $has_interp                = 1;
                }
            }

            # Setup Dynamic Strings Table
            my @exports = @{ $self->exported_funcs // [] };
            my @imports = ( 'dlopen', 'dlsym', 'pthread_create', 'exit' );
            my $libc    = $libc_map{$os_base} // 'libc.so';

            # Probe the exact dynamic libc.so name on the host filesystem when running natively
            if ( $platform->is_native ) {
                my @search_paths = (
                    '/usr/lib',
                    '/lib',
                    '/lib64',
                    '/usr/lib64',
                    '/usr/lib/x86_64-linux-gnu',
                    '/usr/lib/aarch64-linux-gnu',
                    '/usr/lib/riscv64-linux-gnu',
                );
                my @found;
                for my $dir (@search_paths) {
                    next unless -d $dir;
                    my @matches = glob("$dir/libc.so.[0-9]*");
                    for my $m (@matches) {
                        next if $m =~ /_p\.so/; # skip profiled
                        push @found, $m;
                    }
                }
                if (@found) {
                    my $best = (sort {
                        my ($amaj, $amin) = $a =~ /libc\.so\.(\d+)(?:\.(\d+))?/;
                        my ($bmaj, $bmin) = $b =~ /libc\.so\.(\d+)(?:\.(\d+))?/;
                        ($amaj // 0) <=> ($bmaj // 0) || (($amin // 0) <=> ($bmin // 0));
                    } @found)[-1];
                    if ($best) {
                        require File::Basename;
                        $libc = File::Basename::basename($best);
                    }
                }
            }

            # Dynamic libraries loaded by DT_NEEDED
            my @libs = ($libc);
            if ( !$platform->is_haiku ) {
                my $libpthread = $platform->is_freebsd || $platform->is_midnightbsd ? 'libthr.so.3' : 'libpthread.so.0';
                $libpthread = 'libpthread.so' if $platform->is_openbsd || $platform->is_netbsd || $platform->is_dragonflybsd;

                if ( $platform->is_native ) {
                    my @search_paths = (
                        '/usr/lib',
                        '/lib',
                        '/lib64',
                        '/usr/lib64',
                        '/usr/lib/x86_64-linux-gnu',
                        '/usr/lib/aarch64-linux-gnu',
                        '/usr/lib/riscv64-linux-gnu',
                    );
                    my @found;
                    my $prefix = $platform->is_freebsd || $platform->is_midnightbsd ? 'libthr' : 'libpthread';
                    for my $dir (@search_paths) {
                        next unless -d $dir;
                        my @matches = glob("$dir/$prefix.so.[0-9]*");
                        for my $m (@matches) {
                            next if $m =~ /_p\.so/; # skip profiled
                            push @found, $m;
                        }
                    }
                    if (@found) {
                        my $best = (sort {
                            my ($amaj, $amin) = $a =~ /\.so\.(\d+)(?:\.(\d+))?/;
                            my ($bmaj, $bmin) = $b =~ /\.so\.(\d+)(?:\.(\d+))?/;
                            ($amaj // 0) <=> ($bmaj // 0) || (($amin // 0) <=> ($bmin // 0));
                        } @found)[-1];
                        if ($best) {
                            require File::Basename;
                            $libpthread = File::Basename::basename($best);
                        }
                    }
                }
                push @libs, $libpthread;
            }

            my $dynstr  = "\0";
            my %str_off;
            for my $s ( @libs, @imports, @exports ) {
                next if exists $str_off{$s};
                $str_off{$s} = length($dynstr);
                $dynstr .= $s . "\0";
            }
            if ( $platform->is_bsd ) {
                $str_off{'__progname'} = length($dynstr);
                $dynstr .= '__progname' . "\0";
            }
            $l->get('.dynstr')->{size} = length($dynstr);

            # Setup Dynamic Symbol Table
            # Elf64_Sym (24 bytes): Null symbol
            my $dynsym = pack(
                'L< C C S< Q< Q<', 0,    # st_name (String table offset)
                0,                       # st_info (Bind/Type)
                0,                       # st_other (Visibility)
                0,                       # st_shndx (Section index)
                0,                       # st_value (Value/Address)
                0                        # st_size (Symbol size)
            );
            my $sym_idx = 1;
            my %sym_indices;

            # Undefined dynamic imports
            for my $name (@imports) {
                $sym_indices{$name} = $sym_idx++;

                # Elf64_Sym (24 bytes) for undefined global functions
                $dynsym .= pack(
                    'L< C C S< Q< Q<', $str_off{$name},    # st_name
                    0x12,                                  # st_info (STB_GLOBAL | STT_FUNC)
                    0,                                     # st_other (STV_DEFAULT)
                    0,                                     # st_shndx (SHN_UNDEF)
                    0,                                     # st_value
                    0                                      # st_size
                );
            }

            # Exports if shared library
            if ( $self->type eq 'shared' ) {
                for my $name (@exports) {
                    my $rva = $l->get('.text')->{rva} + ( $self->labels->{"E_$name"} // 0 );
                    $sym_indices{$name} = $sym_idx++;

                    # Elf64_Sym (24 bytes) for defined exported functions
                    $dynsym .= pack(
                        'L< C C S< Q< Q<', $str_off{$name},    # st_name
                        0x12,                                  # st_info (STB_GLOBAL | STT_FUNC)
                        0,                                     # st_other (STV_DEFAULT)
                        1,                                     # st_shndx (.text section index)
                        $base + $rva,                          # st_value
                        0                                      # st_size
                    );
                }
            }

            # Define __progname for BSD to satisfy libc's internal reference (e.g. DragonFly)
            if ( $platform->is_bsd ) {
                my $progname_off = $str_off{'__progname'};
                if ( defined $progname_off ) {
                    $sym_indices{'__progname'} = $sym_idx++;
                    my $data_sec = $l->get('.data');
                    my $data_sec_idx;
                    my $sec_i = 1;
                    for my $s ( $l->sections ) {
                        if ( $s->{name} eq '.data' ) {
                            $data_sec_idx = $sec_i;
                            last;
                        }
                        $sec_i++;
                    }
                    $dynsym .= pack(
                        'L< C C S< Q< Q<', $progname_off,         # st_name
                        0x10,                                      # st_info (STB_GLOBAL | STT_NOTYPE)
                        0,                                         # st_other (STV_DEFAULT)
                        $data_sec_idx // 0,                        # st_shndx
                        $base + $data_sec->{rva} + $data_sec->{size} - 1,  # st_value (point to NUL byte)
                        0                                          # st_size
                    );
                }
            }
            $l->get('.dynsym')->{size} = length($dynsym);

            # Setup Relocations (.rela.dyn)
            my $rel_type = $platform->is_arm64 ? 1025 : ( $platform->is_riscv64 ? 2 : 6 );    # R_AARCH64_GLOB_DAT or R_X86_64_GLOB_DAT
            my $rela_dyn = '';

            # Elf64_Rela (24 bytes) for dlopen
            my $dlopen_slot    = $base + $got_rva + 0;
            my $dlopen_sym_idx = $sym_indices{'dlopen'};
            $rela_dyn .= pack(
                'Q< Q< q<', $dlopen_slot,                 # r_offset
                ( $dlopen_sym_idx << 32 ) | $rel_type,    # r_info
                0                                         # r_addend
            );

            # Elf64_Rela (24 bytes) for dlsym
            my $dlsym_slot    = $base + $got_rva + 8;
            my $dlsym_sym_idx = $sym_indices{'dlsym'};
            $rela_dyn .= pack(
                'Q< Q< q<', $dlsym_slot,                  # r_offset
                ( $dlsym_sym_idx << 32 ) | $rel_type,     # r_info
                0                                         # r_addend
            );

            # Elf64_Rela (24 bytes) for pthread_create
            my $pthread_slot    = $base + $got_rva + 16;
            my $pthread_sym_idx = $sym_indices{'pthread_create'};
            $rela_dyn .= pack(
                'Q< Q< q<', $pthread_slot,                 # r_offset
                ( $pthread_sym_idx << 32 ) | $rel_type,    # r_info
                0                                          # r_addend
            );

            # Elf64_Rela (24 bytes) for exit
            my $exit_slot    = $base + $got_rva + 24;
            my $exit_sym_idx = $sym_indices{'exit'};
            $rela_dyn .= pack(
                'Q< Q< q<', $exit_slot,                 # r_offset
                ( $exit_sym_idx << 32 ) | $rel_type,    # r_info
                0                                       # r_addend
            );
            $l->get('.rela.dyn')->{size} = length($rela_dyn);

            # Setup GOT section payload (four zeroed slots: dlopen, dlsym, pthread_create, exit)
            my $got = pack( 'Q< Q< Q< Q<', 0, 0, 0, 0 );
            $l->get('.got')->{size} = length($got);

            # Setup Hash Table
            my $elf_hash = sub {
                my $name = shift;
                my $h    = 0;
                for my $c ( split //, $name ) {
                    $h = ( $h << 4 ) + ord($c);
                    $h &= 0xffffffff;
                    my $g = $h & 0xf0000000;
                    if ($g) { $h ^= ( $g >> 24 ); }
                    $h &= 0x0fffffff;
                }
                return $h;
            };
            my $nbucket = 3;
            my $nchain  = $sym_idx;
            my @buckets = (0) x $nbucket;
            my @chains  = (0) x $nchain;
            for my $name ( keys %sym_indices ) {
                my $idx = $sym_indices{$name};
                my $h   = $elf_hash->($name);
                my $b   = $h % $nbucket;
                $chains[$idx] = $buckets[$b];
                $buckets[$b]  = $idx;
            }
            my $hash = pack( 'L<*', $nbucket, $nchain, @buckets, @chains );
            $l->get('.hash')->{size} = length($hash);

            # Calculate to stabilize RVAs before building .dynamic
            $l->calculate($page_align);

            # Setup .dynamic payload
            my $dyn_rva        = $l->get('.dynamic')->{rva};
            my $str_rva        = $l->get('.dynstr')->{rva};
            my $sym_rva        = $l->get('.dynsym')->{rva};
            my $hash_rva       = $l->get('.hash')->{rva};
            my $rela_rva       = $l->get('.rela.dyn')->{rva};
            my $got_rva_actual = $l->get('.got')->{rva};
            my $dynamic        = '';

            # Elf64_Dyn (16 bytes each) entries
            for my $lib (@libs) {
                $dynamic .= pack( 'Q< Q<', 1, $str_off{$lib} );          # DT_NEEDED (string offset)
            }
            $dynamic .= pack( 'Q< Q<', 4,  $base + $hash_rva );          # DT_HASH
            $dynamic .= pack( 'Q< Q<', 5,  $base + $str_rva );           # DT_STRTAB
            $dynamic .= pack( 'Q< Q<', 6,  $base + $sym_rva );           # DT_SYMTAB
            $dynamic .= pack( 'Q< Q<', 10, length($dynstr) );            # DT_STRSZ
            $dynamic .= pack( 'Q< Q<', 11, 24 );                         # DT_SYMENT (sizeof Elf64_Sym)
            $dynamic .= pack( 'Q< Q<', 7,  $base + $rela_rva );          # DT_RELA
            $dynamic .= pack( 'Q< Q<', 8,  length($rela_dyn) );          # DT_RELASZ
            $dynamic .= pack( 'Q< Q<', 9,  24 );                         # DT_RELAENT (sizeof Elf64_Rela)
            $dynamic .= pack( 'Q< Q<', 3,  $base + $got_rva_actual );    # DT_PLTGOT
            my $main_lbl = $self->labels->{'L_MAIN_START'};

            if ( defined $main_lbl && $self->type ne 'shared' ) {
                $dynamic .= pack( 'Q< Q<', 12, $base + $l->get('.text')->{rva} + $main_lbl );    # DT_INIT
            }
            $dynamic .= pack( 'Q< Q<', 0, 0 );                                                   # DT_NULL
            $l->get('.dynamic')->{size} = length($dynamic);

            # Final layout calculation
            $l->calculate($page_align);

            # Build Section Names String Table (.shstrtab)
            my $shstrtab = "\0";
            my %sh_name_off;
            for my $s ( $l->sections ) {
                $sh_name_off{ $s->{name} } = length($shstrtab);
                $shstrtab .= $s->{name} . "\0";
            }
            $sh_name_off{'.shstrtab'} = length($shstrtab);
            $shstrtab .= ".shstrtab\0";
            $sh_name_off{'.note.GNU-stack'} = length($shstrtab);
            $shstrtab .= ".note.GNU-stack\0";
            my $sec_idx = 1;
            my %sec_indices;
            for my $s ( $l->sections ) { $sec_indices{ $s->{name} } = $sec_idx++; }

            # Open file and write payloads based on layout
            open my $fh, '>', $output_file or die $!;
            binmode $fh;
            for my $s ( $l->sections ) {
                my $payload
                    = $s->{name} eq '.text'   ? $text :
                    $s->{name} eq '.interp'   ? $interp :
                    $s->{name} eq '.dynstr'   ? $dynstr :
                    $s->{name} eq '.dynsym'   ? $dynsym :
                    $s->{name} eq '.rela.dyn' ? $rela_dyn :
                    $s->{name} eq '.hash'     ? $hash :
                    $s->{name} eq '.dynamic'  ? $dynamic :
                    $s->{name} eq '.got'      ? $got :
                    $s->{name} eq '.data'     ? ("\0" x $s->{size}) :
                    ( $s->{name} =~ /^\.(debug|eh_frame)/ ? ( $self->debug_section( $s->{name} ) || "\0" ) : ("\0" x $s->{size}) );
                $payload .= ( "\0" x ( $s->{size} - length($payload) ) ) if length($payload) < $s->{size};
                seek( $fh, $s->{off}, 0 );
                print $fh $payload;
            }

            # Write Section Header String Table and Section Headers at the end
            my $shstrtab_off = tell($fh);
            print $fh $shstrtab;
            my $shoff = tell($fh);
            my @shdrs = ();

            # NULL Section (index 0) — Elf64_Shdr (64 bytes)
            push @shdrs, pack(
                'L< L< Q< Q< Q< Q< L< L< Q< Q<', 0,    # sh_name
                0,                                     # sh_type
                0,                                     # sh_flags
                0,                                     # sh_addr
                0,                                     # sh_offset
                0,                                     # sh_size
                0,                                     # sh_link
                0,                                     # sh_info
                0,                                     # sh_addralign
                0                                      # sh_entsize
            );

            # Real sections from layout — Elf64_Shdr (64 bytes each)
            for my $s ( $l->sections ) {
                my $type       = 1;                    # SHT_PROGBITS
                my $flags      = 0;
                my $sh_link    = 0;
                my $sh_info    = 0;
                my $sh_entsize = 0;
                if ( $s->{name} eq '.text' ) {
                    $flags = 6;                        # SHF_ALLOC | SHF_EXECINSTR
                }
                elsif ( $s->{name} eq '.data' ) {
                    $flags = 3;                        # SHF_ALLOC | SHF_WRITE
                }
                elsif ( $s->{name} eq '.interp' ) {
                    $type  = 1;                        # SHT_PROGBITS
                    $flags = 2;                        # SHF_ALLOC
                }
                elsif ( $s->{name} eq '.dynstr' ) {
                    $type  = 3;                        # SHT_STRTAB
                    $flags = 2;                        # SHF_ALLOC
                }
                elsif ( $s->{name} eq '.dynsym' ) {
                    $type       = 11;                             # SHT_DYNSYM
                    $flags      = 2;                              # SHF_ALLOC
                    $sh_link    = $sec_indices{'.dynstr'} // 0;
                    $sh_info    = 1;                              # One local symbol (the null symbol)
                    $sh_entsize = 24;
                }
                elsif ( $s->{name} eq '.rela.dyn' ) {
                    $type       = 4;                              # SHT_RELA
                    $flags      = 2;                              # SHF_ALLOC
                    $sh_link    = $sec_indices{'.dynsym'} // 0;
                    $sh_entsize = 24;
                }
                elsif ( $s->{name} eq '.hash' ) {
                    $type       = 5;                              # SHT_HASH
                    $flags      = 2;                              # SHF_ALLOC
                    $sh_link    = $sec_indices{'.dynsym'} // 0;
                    $sh_entsize = 4;
                }
                elsif ( $s->{name} eq '.dynamic' ) {
                    $type       = 6;                              # SHT_DYNAMIC
                    $flags      = 3;                              # SHF_ALLOC | SHF_WRITE
                    $sh_link    = $sec_indices{'.dynstr'} // 0;
                    $sh_entsize = 16;
                }
                elsif ( $s->{name} eq '.got' ) {
                    $type       = 1;                              # SHT_PROGBITS
                    $flags = 3;                        # SHF_ALLOC | SHF_WRITE
                    $sh_entsize = 8;
                }
                elsif ( $s->{name} =~ /^\.(debug|eh_frame)/ ) {
                    $flags = 0;                                   # Debug sections are not loaded
                }
                push @shdrs, pack(
                    'L< L< Q< Q< Q< Q< L< L< Q< Q<', $sh_name_off{ $s->{name} },    # sh_name
                    $type,                                                          # sh_type
                    $flags,                                                         # sh_flags
                    ( $flags & 2 ? $base + $s->{rva} : 0 ),                         # sh_addr
                    $s->{off},                                                      # sh_offset
                    $s->{size},                                                     # sh_size
                    $sh_link,                                                       # sh_link
                    $sh_info,                                                       # sh_info
                    1,                                                              # sh_addralign
                    $sh_entsize                                                     # sh_entsize
                );
            }
            my $shstrtab_idx = scalar(@shdrs);

            # .shstrtab section header — Elf64_Shdr (64 bytes)
            push @shdrs, pack(
                'L< L< Q< Q< Q< Q< L< L< Q< Q<', $sh_name_off{'.shstrtab'},    # sh_name
                3,                                                             # sh_type (SHT_STRTAB)
                0,                                                             # sh_flags
                0,                                                             # sh_addr
                $shstrtab_off,                                                 # sh_offset
                length($shstrtab),                                             # sh_size
                0, 0, 1, 0                                                     # sh_link, sh_info, sh_addralign, sh_entsize
            );

            # .note.GNU-stack section header — Elf64_Shdr (64 bytes)
            push @shdrs, pack(
                'L< L< Q< Q< Q< Q< L< L< Q< Q<', $sh_name_off{'.note.GNU-stack'},    # sh_name
                1,                                                                   # sh_type (SHT_PROGBITS)
                0,                                                                   # sh_flags
                0, 0, 0, 0, 0, 1, 0    # sh_addr, sh_offset, sh_size, l, i, a, e
            );
            seek( $fh, $shoff, 0 );
            print $fh $_ for @shdrs;

            # Program Headers — Elf64_Phdr (56 bytes each)
            my $num_ph = 5;                       # PT_PHDR, PT_LOAD (RX), PT_LOAD (RW), PT_DYNAMIC, PT_GNU_STACK
            if ($has_interp)    { $num_ph++; }    # PT_INTERP
            if ($note_data)     { $num_ph++; }    # PT_NOTE
            if ($pintable_data) { $num_ph++; }    # PT_OPENBSD_PINTABLE
            my @phdrs = ();

            # Declare $extra_off before pushing program headers to prevent compilation errors
            my $extra_off = 64 + ( $num_ph * 56 );

            # 1. PT_PHDR (type 6) — Elf64_Phdr (56 bytes)
            push @phdrs, pack(
                'L< L< Q< Q< Q< Q< Q< Q<', 6,    # p_type (PT_PHDR)
                4,                               # p_flags (PF_R)
                64,                              # p_offset (offset immediately following ELF header)
                $base + 64,                      # p_vaddr
                $base + 64,                      # p_paddr
                $num_ph * 56,                    # p_filesz
                $num_ph * 56,                    # p_memsz
                8                                # p_align
            );

            # 2. PT_INTERP (type 3) — Elf64_Phdr (56 bytes)
            if ($has_interp) {
                my $interp_sec = $l->get('.interp');
                push @phdrs, pack(
                    'L< L< Q< Q< Q< Q< Q< Q<', 3,    # p_type (PT_INTERP)
                    4,                               # p_flags (PF_R)
                    $interp_sec->{off},              # p_offset
                    $base + $interp_sec->{rva},      # p_vaddr
                    $base + $interp_sec->{rva},      # p_paddr
                    $interp_sec->{size},             # p_filesz
                    $interp_sec->{size},             # p_memsz
                    1                                # p_align
                );
            }

            # 3. PT_LOAD RX segment (Headers + .text through .hash) — Elf64_Phdr (56 bytes)
            my $hash_sec  = $l->get('.hash');
            my $rx_p_off  = 0;
            my $rx_p_size = $hash_sec->{off} + $hash_sec->{size};
            push @phdrs, pack(
                'L< L< Q< Q< Q< Q< Q< Q<', 1,    # p_type (PT_LOAD)
                5,                               # p_flags (PF_R | PF_X)
                $rx_p_off,                       # p_offset
                $base,                           # p_vaddr
                $base,                           # p_paddr
                $rx_p_size,                      # p_filesz
                $rx_p_size,                      # p_memsz
                $page_align                      # p_align
            );

            # 4. PT_LOAD RW segment (Covers .dynamic through .got) — Elf64_Phdr (56 bytes)
            my $dyn_sec  = $l->get('.dynamic');
            my $got_sec  = $l->get('.got');
            my $rw_p_off = $dyn_sec->{off} & ~($page_align - 1);
            my $rw_size  = ( $got_sec->{off} + $got_sec->{size} ) - $rw_p_off;
            push @phdrs, pack(
                'L< L< Q< Q< Q< Q< Q< Q<', 1,    # p_type (PT_LOAD)
                6,                               # p_flags (PF_R | PF_W)
                $rw_p_off,                       # p_offset (page-aligned down)
                $base + $dyn_sec->{rva},         # p_vaddr
                $base + $dyn_sec->{rva},         # p_paddr
                $rw_size,                        # p_filesz
                $rw_size,                        # p_memsz
                $page_align                      # p_align
            );

            # 5. PT_DYNAMIC (type 2) — Elf64_Phdr (56 bytes)
            push @phdrs, pack(
                'L< L< Q< Q< Q< Q< Q< Q<', 2,    # p_type (PT_DYNAMIC)
                6,                               # p_flags (PF_R | PF_W)
                $dyn_sec->{off},                 # p_offset
                $base + $dyn_sec->{rva},         # p_vaddr
                $base + $dyn_sec->{rva},         # p_paddr
                $dyn_sec->{size},                # p_filesz
                $dyn_sec->{size},                # p_memsz
                8                                # p_align
            );

            # 6. PT_NOTE — Elf64_Phdr (56 bytes)
            if ($note_data) {
                push @phdrs, pack(
                    'L< L< Q< Q< Q< Q< Q< Q<', 4,    # p_type (PT_NOTE)
                    4,                               # p_flags (PF_R)
                    $extra_off,                      # p_offset
                    $base + $extra_off,              # p_vaddr
                    $base + $extra_off,              # p_paddr
                    length($note_data),              # p_filesz
                    length($note_data),              # p_memsz
                    4                                # p_align
                );
                $extra_off += length($note_data);
            }

            # 7. PT_OPENBSD_PINTABLE — Elf64_Phdr (56 bytes)
            if ($pintable_data) {
                push @phdrs, pack(
                    'L< L< Q< Q< Q< Q< Q< Q<', 0x65a3dbe9,    # p_type (PT_OPENBSD_PINTABLE)
                    4,                                        # p_flags (PF_R)
                    $extra_off,                               # p_offset
                    $base + $extra_off,                       # p_vaddr
                    $base + $extra_off,                       # p_paddr
                    length($pintable_data),                   # p_filesz
                    length($pintable_data),                   # p_memsz
                    4                                         # p_align
                );
                $extra_off += length($pintable_data);
            }

            # 8. PT_GNU_STACK (type 0x6474e551) — Elf64_Phdr (56 bytes)
            push @phdrs, pack(
                'L< L< Q< Q< Q< Q< Q< Q<', 0x6474e551,    # p_type (PT_GNU_STACK)
                0, 0, 0, 0, 0, 0, 0x10                    # p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align
            );

            my $entry_point = $self->type eq 'shared' ? 0 : $base + $l->get('.text')->{rva};

            # Finalize ELF Header (Elf64_Ehdr - Exactly 64 bytes) and write program headers/extra data
            my $ehdr = pack(
                'A4 C C C C C x7 S< S< L< Q< Q< Q< L< S< S< S< S< S< S<', "\x7fELF",    # e_ident[0..3] (Magic)
                2,                                                                      # e_ident[4] (Class: 64-bit)
                1,                                                                      # e_ident[5] (Data: Little Endian)
                1,                                                                      # e_ident[6] (Version: 1)
                $osabi,                                                                 # e_ident[7] (OS/ABI)
                0,                                                                      # e_ident[8] (ABI Version)

                # e_ident[9..15] (Padding, implicitly added by x7)
                $elf_type,                                                               # e_type (ET_EXEC = 2 or ET_DYN = 3)
                ( $platform->is_arm64 ? 183 : ( $platform->is_riscv64 ? 243 : 62 ) ),    # e_machine (EM_AARCH64 = 183 or EM_X86_64 = 62)
                1,                                                                       # e_version
                $entry_point,                                                            # e_entry (Starting Virtual Address)
                64,                                                                      # e_phoff (Program Header Table offset)
                $shoff,                                                                  # e_shoff (Section Header Table offset)
                0,                                                                       # e_flags
                64,                                                                      # e_ehsize (ELF Header Size)
                56,                                                                      # e_phentsize (Program Header Entry Size)
                $num_ph,                                                                 # e_phnum (Number of Program Header Entries)
                64,                                                                      # e_shentsize (Section Header Entry Size)
                scalar(@shdrs),                                                          # e_shnum (Number of Section Header Entries)
                $shstrtab_idx                                                            # e_shstrndx (Section index of .shstrtab)
            );
            seek( $fh, 0, 0 );
            print $fh $ehdr, @phdrs, $note_data, $pintable_data;
            close $fh;
            chmod 0755, $output_file;
            return $output_file;
        }
    }


    my $compiler = Brocken::Compiler->new();
subtest Katsuro => sub {
    subtest 'platform parsing' => sub {
        my $raw_triple = Brocken::Katsuro::Platform::gen_triple();
        diag "Host raw triple: $raw_triple";
        my $platform = Brocken::Katsuro::Platform::parse($raw_triple);
        diag 'Host: ' . $platform->os . '/' . $platform->arch;
        diag 'File: app' . $platform->bin_ext . ' / lib' . $platform->lib_ext;
        isa_ok $platform, ['Brocken::Katsuro::Platform'], 'parsed host platform';
        my $linux = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        is $linux->arch,    'x86_64', 'linux arch';
        is $linux->vendor,  'pc',     'linux vendor';
        is $linux->os,      'linux',  'linux os';
        is $linux->env,     'gnu',    'linux env';
        is $linux->bin_ext, '',       'linux bin_ext';
        is $linux->lib_ext, '.so',    'linux lib_ext';
        is $linux->format,  'elf',    'linux format';
        ok $linux->is_linux,    'is_linux';
        ok $linux->is_posix,    'is_posix';
        ok !$linux->is_windows, 'not windows';
        ok !$linux->is_bsd,     'not bsd';
        ok !$linux->is_haiku,   'not haiku';
        my $win = Brocken::Katsuro::Platform::parse('x86_64-pc-windows-msvc');
        is $win->bin_ext, '.exe', 'windows bin_ext';
        is $win->lib_ext, '.dll', 'windows lib_ext';
        is $win->format,  'pe',   'windows format';
        ok $win->is_windows, 'is_windows';
        ok !$win->is_posix,  'not posix';
        my $mac = Brocken::Katsuro::Platform::parse('aarch64-apple-darwin-macho');
        is $mac->bin_ext, '',       'macos bin_ext';
        is $mac->lib_ext, '.dylib', 'macos lib_ext';
        is $mac->format,  'macho',  'macos format';
        ok $mac->is_macos, 'is_macos';
        ok $mac->is_posix, 'is_posix';
        my $openbsd = Brocken::Katsuro::Platform::parse('x86_64-unknown-openbsd-elf');
        is $openbsd->bin_ext, '',    'openbsd bin_ext';
        is $openbsd->lib_ext, '.so', 'openbsd lib_ext';
        is $openbsd->format,  'elf', 'openbsd format';
        ok $openbsd->is_bsd,    'is_bsd';
        ok $openbsd->is_posix,  'is_posix';
        ok !$openbsd->is_linux, 'not linux';
        my $haiku = Brocken::Katsuro::Platform::parse('x86_64-pc-haiku-elf');
        is $haiku->bin_ext, '',    'haiku bin_ext';
        is $haiku->lib_ext, '.so', 'haiku lib_ext';
        is $haiku->format,  'elf', 'haiku format';
        ok $haiku->is_haiku, 'is_haiku';
        ok $haiku->is_posix, 'is_posix';
        ok !$haiku->is_bsd,  'not bsd';
        my $wasm = Brocken::Katsuro::Platform::parse('wasm32-unknown-unknown');
        is $wasm->bin_ext, '.wasm', 'wasm bin_ext';
        is $wasm->format,  'wasm',  'wasm format';
        ok $wasm->is_wasm,   'is_wasm';
        ok !$wasm->is_posix, 'wasm-unknown-unknown is not posix';
        my $wasi = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        ok $wasi->is_wasm,  'wasi is_wasm';
        ok $wasi->is_posix, 'wasi is_posix';
        my $netbsd = Brocken::Katsuro::Platform::parse('aarch64--netbsd');
        is $netbsd->os, 'netbsd', 'netbsd os identified from empty-vendor triple';
        ok $netbsd->is_bsd, 'is_bsd for netbsd';
    };
    subtest 'friendly names' => sub {
        my $linux = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        is $linux->friendly, 'Linux on x64', 'linux friendly name';
        my $win = Brocken::Katsuro::Platform::parse('aarch64-pc-windows-msvc');
        is $win->friendly, 'Windows on ARM64', 'windows friendly name';
        my $mac = Brocken::Katsuro::Platform::parse('aarch64-apple-darwin');
        is $mac->friendly, 'macOS on Apple Silicon', 'macos apple silicon friendly name';
        my $mac_intel = Brocken::Katsuro::Platform::parse('x86_64-apple-darwin');
        is $mac_intel->friendly, 'macOS on Intel', 'macos intel friendly name';
        my $freebsd = Brocken::Katsuro::Platform::parse('riscv64-unknown-freebsd');
        is $freebsd->friendly, 'FreeBSD on RISC-V', 'freebsd friendly name';
        my $wasm = Brocken::Katsuro::Platform::parse('wasm32-unknown-unknown');
        is $wasm->friendly, 'WebAssembly (Wasm)', 'wasm friendly name';
        my $unknown = Brocken::Katsuro::Platform::parse('unknown-unknown-unknown-unknown');
        is $unknown->friendly, 'sand that does math', 'fallback friendly name';
    };
    subtest 'platform naming' => sub {
        subtest 'Linux (ELF)' => sub {
            my $linux = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
            is $linux->bin_name('foo'),                 'foo',           'linux bin_name';
            is $linux->static_lib_name('foo'),          'libfoo.a',      'linux static_lib_name';
            is $linux->shared_lib_name('foo'),          'libfoo.so',     'linux shared_lib_name';
            is $linux->shared_lib_name( 'foo', '1.2' ), 'libfoo.so.1.2', 'linux shared_lib_name with version';
        };
        subtest 'Windows (PE)' => sub {
            subtest 'MSVC style' => sub {
                my $win = Brocken::Katsuro::Platform::parse('x86_64-pc-windows-msvc');
                is $win->bin_name('foo'),                 'foo.exe',     'windows bin_name';
                is $win->static_lib_name('foo'),          'foo.lib',     'windows static_lib_name';
                is $win->shared_lib_name('foo'),          'foo.dll',     'windows shared_lib_name';
                is $win->shared_lib_name( 'foo', '1.2' ), 'foo-1.2.dll', 'windows shared_lib_name with version';
            };
            subtest 'GNU style' => sub {
                my $win = Brocken::Katsuro::Platform::parse('x86_64-pc-windows-gnu');
                is $win->bin_name('foo'),                 'foo.exe',     'windows bin_name';
                is $win->static_lib_name('foo'),          'foo.a',       'windows static_lib_name';
                is $win->shared_lib_name('foo'),          'foo.dll',     'windows shared_lib_name';
                is $win->shared_lib_name( 'foo', '1.2' ), 'foo-1.2.dll', 'windows shared_lib_name with version';
            };
        };
        subtest 'MacOS (Mach-O)' => sub {
            my $mac = Brocken::Katsuro::Platform::parse('aarch64-apple-darwin');
            is $mac->bin_name('foo'),                 'foo',              'macos bin_name';
            is $mac->static_lib_name('foo'),          'libfoo.a',         'macos static_lib_name';
            is $mac->shared_lib_name('foo'),          'libfoo.dylib',     'macos shared_lib_name';
            is $mac->shared_lib_name( 'foo', '1.2' ), 'libfoo.1.2.dylib', 'macos shared_lib_name with version';
        };
        subtest 'Wasm' => sub {
            my $wasm = Brocken::Katsuro::Platform::parse('wasm32-unknown-unknown');
            is $wasm->bin_name('foo'),        'foo.wasm', 'wasm bin_name';
            is $wasm->static_lib_name('foo'), 'foo.a',    'wasm static_lib_name';
            is $wasm->shared_lib_name('foo'), 'foo.wasm', 'wasm shared_lib_name';
        }
    };
    subtest 'OS syscall numbers' => sub {
        my $bsd = Brocken::Katsuro::Platform::parse('x86_64-pc-freebsd-elf');
        is $bsd->syscall('write'), 4,     'bsd x86_64 write';
        is $bsd->syscall('exit'),  1,     'bsd x86_64 exit';
        is $bsd->syscall('fork'),  2,     'bsd x86_64 fork';
        is $bsd->syscall_num_reg,  'rax', 'bsd x86_64 syscall_num_reg';
        is $bsd->syscall_ret_reg,  'rax', 'bsd x86_64 syscall_ret_reg';
        my $lnx = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        is $lnx->syscall('write'), 1,   'linux x86_64 write';
        is $lnx->syscall('exit'),  60,  'linux x86_64 exit';
        is $lnx->syscall('fork'),  57,  'linux x86_64 fork';
        is $lnx->syscall('futex'), 202, 'linux x86_64 futex';
        my $lnx64 = Brocken::Katsuro::Platform::parse('aarch64-pc-linux-gnu');
        is $lnx64->syscall('write'), 64, 'linux aarch64 write';
        is $lnx64->syscall('exit'),  93, 'linux aarch64 exit';
        my $mac = Brocken::Katsuro::Platform::parse('x86_64-apple-darwin-macho');
        is $mac->syscall('write'), 0x2000004, 'macos x86_64 write (with offset)';
        is $mac->syscall('exit'),  0x2000001, 'macos x86_64 exit (with offset)';
        ok $mac->syscall('write') != 4, 'macos write != bsd write';
    };
    subtest 'Haiku syscall numbers (fallback)' => sub {
        my $haiku = Brocken::Katsuro::Platform::parse('x86_64-pc-haiku-elf');
        is $haiku->syscall('write'),  151, 'haiku x86_64 write fallback';
        is $haiku->syscall('exit'),   41,  'haiku x86_64 exit fallback';
        is $haiku->syscall('fork'),   47,  'haiku x86_64 fork fallback';
        is $haiku->syscall('getpid'), 46,  'haiku x86_64 getpid fallback';
        is $haiku->syscall('read'),   148, 'haiku x86_64 read fallback';
    };
    subtest 'ABI register sets' => sub {
        my $p     = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        my @avail = $p->registers('available')->@*;
        ok grep( /^rax$/,  @avail ), 'x86_64 has rax';
        ok grep( /^r15$/,  @avail ), 'x86_64 has r15';
        ok !grep( /^rsp$/, @avail ), 'x86_64 excludes rsp';
        my @caller = $p->caller_saved->@*;
        ok grep( /^rax$/,  @caller ), 'x86_64 caller rax';
        ok !grep( /^rbx$/, @caller ), 'x86_64 caller excludes rbx';
        my @callee = $p->callee_saved->@*;
        ok grep( /^rbx$/, @callee ), 'x86_64 callee rbx';
        ok grep( /^r12$/, @callee ), 'x86_64 callee r12';
        is $p->frame_reg, 'rbp', 'x86_64 frame = rbp';
        is $p->stack_reg, 'rsp', 'x86_64 stack = rsp';
        my $aarch    = Brocken::Katsuro::Platform::parse('aarch64-pc-linux-gnu');
        my @a_caller = $aarch->caller_saved->@*;
        ok grep( /^x0$/,   @a_caller ), 'aarch64 caller x0';
        ok grep( /^x15$/,  @a_caller ), 'aarch64 caller x15';
        ok !grep( /^x19$/, @a_caller ), 'aarch64 caller excludes x19';
        ok !grep( /^x20$/, @a_caller ), 'aarch64 caller excludes x20';
        my @a_callee = $aarch->callee_saved->@*;
        ok grep( /^x20$/, @a_callee ), 'aarch64 callee x20';
        ok grep( /^x28$/, @a_callee ), 'aarch64 callee x28';
        is $aarch->frame_reg, 'x29', 'aarch64 frame = x29';
        my $riscv    = Brocken::Katsuro::Platform::parse('riscv64-pc-linux-gnu');
        my @r_caller = $riscv->caller_saved->@*;
        ok grep( /^a0$/, @r_caller ), 'riscv64 caller a0';
        ok grep( /^t6$/, @r_caller ), 'riscv64 caller t6';
        my @r_callee = $riscv->callee_saved->@*;
        ok grep( /^s1$/,  @r_callee ), 'riscv64 callee s1';
        ok grep( /^s11$/, @r_callee ), 'riscv64 callee s11';
        is $riscv->frame_reg, 's0', 'riscv64 frame = s0';
    };
    subtest 'triple normalization' => sub {
        my $norm = Brocken::Katsuro::Platform::normalize_triple('x86_64-apple-darwin21.0.0');
        is $norm, 'x86_64-apple-darwin21.0.0-macho', '3-field apple triple';
        $norm = Brocken::Katsuro::Platform::normalize_triple('x86_64-linux-gnu');
        is $norm, 'x86_64-pc-linux-gnu', '3-field linux triple';
        $norm = Brocken::Katsuro::Platform::normalize_triple('x86_64-w64-mingw32');
        is $norm, 'x86_64-pc-windows-gnu', '3-field mingw triple';
        $norm = Brocken::Katsuro::Platform::normalize_triple('x86_64-unknown-openbsd-elf');
        is $norm, 'x86_64-unknown-openbsd-elf', '4-field openbsd triple unchanged';
    };
    subtest 'known target triples' => sub {
        my @targets = <DATA>;
        chomp @targets;
        my $ok      = 0;
        my %arch_64 = map { $_ => 1 } qw[x86_64
            aarch64 aarch64_be arm64e
            riscv64
            powerpc64 powerpc64le
            mips64 mips64el
            loongarch64
            s390x sparc64
            wasm64
            nvptx64];
        my %count;

        for my $raw (@targets) {
            next if $raw =~ /^\s*#/ || $raw =~ /^\s*$/;
            my $p = Brocken::Katsuro::Platform::parse($raw);
            ok defined $p && $p->isa('Brocken::Katsuro::Platform'), "parse($raw)";
            $ok++;
            my $arch = $p->arch;
            $count{ $arch_64{$arch} ? '64' : ( $arch =~ /64/ ? '64' : 'other' ) }++;
        }
        diag "$ok targets parsed (" . ( $count{64} // 0 ) . ' 64-bit, ' . ( $count{other} // 0 ) . ' other)';
    };
};
subtest Lindsay => sub {
    subtest 'Lindsay::IR Types & Singletons' => sub {
        my $i32 = Brocken::Lindsay::IR::Type::i32();
        my $ptr = Brocken::Lindsay::IR::Type::ptr();
        is $i32->as_string, 'i32', 'i32 renders correctly';
        is $ptr->as_string, 'ptr', 'ptr renders correctly';

        # Prove they are singletons
        my $i32_again = Brocken::Lindsay::IR::Type::i32();
        ref_is $i32, $i32_again, 'Type singletons return the same memory reference';
    };
    subtest 'Lindsay::IR Values & Constants' => sub {
        my $val = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%my_var' );
        is $val->as_string, '%my_var', 'Value renders its name';
        my $const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => '42' );
        is $const->as_string, '42', 'Constant renders its underlying value';
    };
    subtest 'Lindsay::IR Builder' => sub {
        my $module = Brocken::Lindsay::IR::Module->new( name => 'test_mod' );

        # Setup Parameters
        my $param_a = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%a' );
        my $param_b = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%b' );

        # Setup Function
        my $func = Brocken::Lindsay::IR::Function->new(
            name        => 'add_nums',
            return_type => Brocken::Lindsay::IR::Type::i32(),
            params      => [ $param_a, $param_b ]
        );
        $module->add_function($func);

        # Use Builder
        my $builder = Brocken::Lindsay::IR::Builder->new();
        my $entry   = $func->append_block('entry');
        $builder->position_at_end($entry);

        # Generate instructions
        my $sum = $builder->build_add( $param_a, $param_b );    # Should assign %0 automatically
        $builder->build_ret($sum);

        # Verify Internal State
        is $sum->name,                         '%0', 'Builder assigned correct auto-incremented SSA id';
        is scalar( $entry->instructions->@* ), 2,    'Two instructions appended to basic block';

        # Verify Stringified IR Output
        my $expected_ir = <<~'IR';
    ; ModuleID = 'test_mod'

    define i32 @add_nums(i32 %a, i32 %b) {
    entry:
      %0 = add i32 %a, i32 %b
      ret i32 %0
    }

    IR
        is $module->as_string, $expected_ir, 'Generated IR matches LLVM-style expected output';
    };
    subtest 'Lindsay::IR Memory Operations' => sub {
        my $module      = Brocken::Lindsay::IR::Module->new( name => 'mem_test' );
        my $param_input = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%input' );
        my $func
            = Brocken::Lindsay::IR::Function->new( name => 'copy_val', return_type => Brocken::Lindsay::IR::Type::void(), params => [$param_input] );
        $module->add_function($func);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        # Allocate an i32 on the stack (yields a ptr)
        my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%my_ptr' );

        # Store the input parameter into the pointer
        $builder->build_store( $param_input, $ptr );

        # Load the value back out
        my $loaded = $builder->build_load( Brocken::Lindsay::IR::Type::i32(), $ptr, '%loaded_val' );

        # Return
        $builder->build_ret();
        my $expected_ir = <<~'IR';
    ; ModuleID = 'mem_test'

    define void @copy_val(i32 %input) {
    entry:
      %my_ptr = alloca i32
      store i32 %input, ptr %my_ptr
      %loaded_val = load i32, ptr %my_ptr
      ret void
    }

    IR
        is $module->as_string, $expected_ir, 'Generated Memory IR matches expected LLVM-style output';
    };
    subtest 'Lindsay::IR Gradual Typing (Boxing/Unboxing)' => sub {
        my $module = Brocken::Lindsay::IR::Module->new( name => 'gradual_typing' );

        # Input is a dynamic (Perl-like) scalar
        my $param_dyn = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::dynamic(), name => '%input_dyn' );

        # Returns a dynamic scalar
        my $func = Brocken::Lindsay::IR::Function->new( name => 'double_it', return_type => Brocken::Lindsay::IR::Type::dynamic(),
            params => [$param_dyn] );
        $module->add_function($func);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        # Unbox the dynamic variable into a native 64-bit integer
        my $native_i64 = $builder->build_unbox( $param_dyn, Brocken::Lindsay::IR::Type::i64(), '%native_val' );

        # Perform native math (zero GC overhead)
        my $doubled = $builder->build_add( $native_i64, $native_i64, '%doubled' );

        # Box it back into a dynamic variable to return it
        my $boxed_result = $builder->build_box( $doubled, '%boxed_res' );

        # Return the dynamic value
        $builder->build_ret($boxed_result);
        my $expected_ir = <<~'IR';
    ; ModuleID = 'gradual_typing'

    define dynamic @double_it(dynamic %input_dyn) {
    entry:
      %native_val = unbox dynamic %input_dyn to i64
      %doubled = add i64 %native_val, i64 %native_val
      %boxed_res = box i64 %doubled to dynamic
      ret dynamic %boxed_res
    }

    IR
        is $module->as_string, $expected_ir, 'Generated Boxing IR matches expected output';
    };
    subtest 'Lindsay::IR Control Flow (If/Else)' => sub {
        my $module  = Brocken::Lindsay::IR::Module->new( name => 'control_flow' );
        my $param_a = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%a' );
        my $param_b = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%b' );
        my $func    = Brocken::Lindsay::IR::Function->new(
            name        => 'max_val',
            return_type => Brocken::Lindsay::IR::Type::i32(),
            params      => [ $param_a, $param_b ]
        );
        $module->add_function($func);

        # Create the basic blocks
        my $entry_blk = $func->append_block('entry');
        my $then_blk  = $func->append_block('if.then');
        my $else_blk  = $func->append_block('if.else');
        my $builder   = Brocken::Lindsay::IR::Builder->new();

        # Entry Block
        $builder->position_at_end($entry_blk);

        # check if %a > %b (sgt = signed greater than)
        my $cond = $builder->build_icmp( 'sgt', $param_a, $param_b, '%cmp' );
        $builder->build_cond_br( $cond, $then_blk, $else_blk );

        # Then Block
        $builder->position_at_end($then_blk);
        $builder->build_ret($param_a);

        # Else Block
        $builder->position_at_end($else_blk);
        $builder->build_ret($param_b);
        my $expected_ir = <<~'IR';
    ; ModuleID = 'control_flow'

    define i32 @max_val(i32 %a, i32 %b) {
    entry:
      %cmp = icmp sgt i32 %a, %b
      br i1 %cmp, label %if.then, label %if.else
    if.then:
      ret i32 %a
    if.else:
      ret i32 %b
    }

    IR
        is $module->as_string, $expected_ir, 'Generated If/Else IR matches expected output';
    };
    subtest 'Lindsay::IR Function Calls and FFI' => sub {
        my $module = Brocken::Lindsay::IR::Module->new( name => 'call_test' );

        # Declare an external FFI function (e.g., C's puts)
        # int puts(char *str);
        my $ffi_param = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() );
        my $ffi_puts
            = Brocken::Lindsay::IR::Function->new( name => 'puts', return_type => Brocken::Lindsay::IR::Type::i32(), params => [$ffi_param] );
        $module->add_function($ffi_puts);

        # Define our local main function
        my $func_main = Brocken::Lindsay::IR::Function->new(
            name        => 'main',
            return_type => Brocken::Lindsay::IR::Type::i32(),
            params      => []                                   # no args
        );
        $module->add_function($func_main);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_main->append_block('entry') );

        # Simulate a global string pointer being passed in
        my $str_ptr = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '@hello_str' );

        # Call the external FFI function
        my $puts_res = $builder->build_call( $ffi_puts, [$str_ptr], '%puts_res' );

        # Return the result
        $builder->build_ret($puts_res);
        my $expected_ir = <<~'IR';
    ; ModuleID = 'call_test'

    declare i32 @puts(ptr)

    define i32 @main() {
    entry:
      %puts_res = call i32 @puts(ptr @hello_str)
      ret i32 %puts_res
    }

    IR
        is $module->as_string, $expected_ir, 'Generated IR supports FFI declarations and calls';
    };
};
subtest Jenny => sub {
    subtest 'Jenny::Linker Pure ELF-64 Generation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();

        # Build the IR: int main() { return 42; }
        my $module    = Brocken::Lindsay::IR::Module->new( name => 'standalone_elf' );
        my $func_main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_main);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_main->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );

        # Compile IR to native machine code based on host architecture
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new() :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_main);

        # Link and Write to raw ELF executable file
        my $output_file = './test_prog';
        my $linker      = Brocken::Jenny::Linker::ELF64->new();
        $linker->write_executable( $output_file, $machine_bytes, $platform );

        # Ensure the file was actually written
        ok -e $output_file, 'Binary executable file created successfully';

        # We can only execute this test on x86_64 Linux hosts
    SKIP: {
            skip 'ELF binary execution test requires Linux' unless $platform->is_linux || $platform->is_bsd || $platform->is_haiku;

            # Diagnostic: check executable bit and dump header bytes
            ok -x $output_file, 'Binary is executable';
            open my $diag_fh, '<:raw', $output_file or warn "Can't open $output_file: $!";
            if ($diag_fh) {
                read( $diag_fh, my $magic, 16 );
                close $diag_fh;
                note 'Binary magic hex: ' . unpack( 'H*', $magic );
            }

            # Execute the binary and inspect its exit code!
            system($output_file);
            my $exit_code = $? >> 8;
            is $exit_code, 42, 'Standalone binary executed natively and returned the correct exit code!';
            note $?;
            note $exit_code;
        }

        # Clean up
        unlink $output_file;
    };
    subtest 'Jenny::Linker Pure PE-64 Generation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();

        # Build the IR: int main() { return 42; }
        my $module    = Brocken::Lindsay::IR::Module->new( name => 'standalone_win' );
        my $func_main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_main);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_main->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );

        # Compile IR to native machine code based on host architecture
        my $codegen       = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new() : Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_main);

        # Link and Write to raw PE executable file (.exe)
        my $output_file = './test_prog.exe';
        my $linker      = Brocken::Jenny::Linker::PE->new();

        #~ $linker->link_executable( $output_file, $machine_bytes );
        $linker->write_executable( $output_file, $machine_bytes, $platform );
        ok -e $output_file, 'Windows executable file created successfully';
    SKIP: {
            skip 'PE binary execution test requires x86_64 Windows', 1 unless $platform->is_windows;

            # Execute the binary natively and inspect its exit code!
            system($output_file);
            my $exit_code = $? >> 8;
            is $exit_code, 42, 'Standalone Windows binary executed natively and returned the correct exit code!';
            note $?;
            note $exit_code;
        }

        # Clean up
        unlink $output_file;
    };
    subtest 'Jenny::Linker Pure Mach-O Generation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();

        # Build the IR: int main() { return 42; }
        my $module    = Brocken::Lindsay::IR::Module->new( name => 'standalone_macho' );
        my $func_main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_main);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_main->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );

        # Compile IR to native machine code based on host architecture
        my $codegen       = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new() : Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_main);

        # Link and Write to raw Mach-O executable
        my $output_file = './test_prog';
        my $linker      = Brocken::Jenny::Linker::MachO->new();
        $linker->write_executable( $output_file, $machine_bytes, $platform );

        # Ensure the file was actually written
        ok -e $output_file, 'Mach-O executable created successfully';
    SKIP: {
            skip 'Mach-O binary execution test requires macOS (x64 or ARM64)', 1 unless $platform->is_macos;

            # Execute natively and inspect the exit code!
            system($output_file);
            my $exit_code = $? >> 8;
            is $exit_code, 42, 'Standalone Mach-O binary executed natively and returned the correct exit code!';
            note $?;
            note $exit_code;

            # Diagnostic: compile reference binary and dump both for comparison
            if ( $exit_code != 42 ) {
                my $ref_src = 'ref_prog.c';
                my $ref_bin = 'ref_prog';
                open my $rfh, '>', $ref_src or warn "Can't write $ref_src: $!";
                print $rfh "int main(void) { return 42; }\n";
                close $rfh;
                my $rc = system( 'clang', '-o', $ref_bin, $ref_src );
                if ( ( $rc >> 8 ) == 0 ) {
                    note "=== Generated: otool -l ===";
                    note scalar `otool -l "$output_file" 2>&1`;
                    note "=== Reference: otool -l ===";
                    note scalar `otool -l "$ref_bin" 2>&1`;
                    note "=== Generated: od -A x -t x1 -c (first 1KB) ===";
                    note scalar `od -A x -t x1 -c -v -N 1024 "$output_file" 2>&1`;
                    note "=== Reference: od -A x -t x1 -c (first 1KB) ===";
                    note scalar `od -A x -t x1 -c -v -N 1024 "$ref_bin" 2>&1`;
                }
                else {
                    note "clang compilation failed, exit: " . ( $rc >> 8 );
                }
            }
        }

        # Clean up
        unlink $output_file;
    }
};
#
done_testing;
__DATA__
# GitHub runner triples
x86_64-pc-dragonflybsd
x86_64-pc-freebsd14.1
aarch64-pc-freebsd14.1
i86pc-unknown-solaris
x86_64-unknown-freebsd13.4
aarch64-unknown-netbsd
aarch64--netbsd
x86_64--netbsd
i386--netbsd
sparc64--netbsd
# Rust/LLVM triples from `rustc --print target-list` plus extra LLVM/Zig OS types
aarch64-apple-darwin
aarch64-apple-ios
aarch64-apple-ios-macabi
aarch64-apple-ios-sim
aarch64-apple-tvos
aarch64-apple-tvos-sim
aarch64-apple-visionos
aarch64-apple-visionos-sim
aarch64-apple-watchos
aarch64-apple-watchos-sim
aarch64-kmc-solid_asp3
aarch64-linux-android
aarch64-nintendo-switch-freestanding
aarch64-pc-windows-gnullvm
aarch64-pc-windows-msvc
aarch64-unknown-freebsd
aarch64-unknown-fuchsia
aarch64-unknown-helenos
aarch64-unknown-hermit
aarch64-unknown-illumos
aarch64-unknown-linux-gnu
aarch64-unknown-linux-gnu_ilp32
aarch64-unknown-linux-musl
aarch64-unknown-linux-ohos
aarch64-unknown-managarm-mlibc
aarch64-unknown-netbsd
aarch64-unknown-none
aarch64-unknown-none-softfloat
aarch64-unknown-nto-qnx700
aarch64-unknown-nto-qnx710
aarch64-unknown-nto-qnx710_iosock
aarch64-unknown-nto-qnx800
aarch64-unknown-nuttx
aarch64-unknown-openbsd
aarch64-unknown-redox
aarch64-unknown-teeos
aarch64-unknown-trusty
aarch64-unknown-uefi
aarch64-uwp-windows-msvc
aarch64-wrs-vxworks
aarch64_be-unknown-hermit
aarch64_be-unknown-linux-gnu
aarch64_be-unknown-linux-gnu_ilp32
aarch64_be-unknown-linux-musl
aarch64_be-unknown-netbsd
aarch64_be-unknown-none-softfloat
amdgcn-amd-amdhsa
arm-linux-androideabi
arm-unknown-linux-gnueabi
arm-unknown-linux-gnueabihf
arm-unknown-linux-musleabi
arm-unknown-linux-musleabihf
arm64_32-apple-watchos
arm64e-apple-darwin
arm64e-apple-ios
arm64e-apple-tvos
arm64ec-pc-windows-msvc
armeb-unknown-linux-gnueabi
armebv7r-none-eabi
armebv7r-none-eabihf
armv4t-none-eabi
armv4t-unknown-linux-gnueabi
armv5te-none-eabi
armv5te-unknown-linux-gnueabi
armv5te-unknown-linux-musleabi
armv5te-unknown-linux-uclibceabi
armv6-unknown-freebsd
armv6-unknown-netbsd-eabihf
armv6k-nintendo-3ds
armv7-linux-androideabi
armv7-rtems-eabihf
armv7-sony-vita-newlibeabihf
armv7-unknown-freebsd
armv7-unknown-linux-gnueabi
armv7-unknown-linux-gnueabihf
armv7-unknown-linux-musleabi
armv7-unknown-linux-musleabihf
armv7-unknown-linux-ohos
armv7-unknown-linux-uclibceabi
armv7-unknown-linux-uclibceabihf
armv7-unknown-netbsd-eabihf
armv7-unknown-trusty
armv7-wrs-vxworks-eabihf
armv7a-kmc-solid_asp3-eabi
armv7a-kmc-solid_asp3-eabihf
armv7a-none-eabi
armv7a-none-eabihf
armv7a-nuttx-eabi
armv7a-nuttx-eabihf
armv7a-vex-v5
armv7k-apple-watchos
armv7r-none-eabi
armv7r-none-eabihf
armv7s-apple-ios
armv8r-none-eabihf
avr-none
bpfeb-unknown-none
bpfel-unknown-none
csky-unknown-linux-gnuabiv2
csky-unknown-linux-gnuabiv2hf
hexagon-unknown-linux-musl
hexagon-unknown-none-elf
hexagon-unknown-qurt
i386-apple-ios
i586-unknown-linux-gnu
i586-unknown-linux-musl
i586-unknown-netbsd
i586-unknown-redox
i686-apple-darwin
i686-linux-android
i686-pc-nto-qnx700
i686-pc-windows-gnu
i686-pc-windows-gnullvm
i686-pc-windows-msvc
i686-unknown-freebsd
i686-unknown-haiku
i686-unknown-helenos
i686-unknown-hurd-gnu
i686-unknown-linux-gnu
i686-unknown-linux-musl
i686-unknown-netbsd
i686-unknown-openbsd
i686-unknown-uefi
i686-uwp-windows-gnu
i686-uwp-windows-msvc
i686-win7-windows-gnu
i686-win7-windows-msvc
i686-wrs-vxworks
loongarch32-unknown-none
loongarch32-unknown-none-softfloat
loongarch64-unknown-linux-gnu
loongarch64-unknown-linux-musl
loongarch64-unknown-linux-ohos
loongarch64-unknown-none
loongarch64-unknown-none-softfloat
m68k-unknown-linux-gnu
m68k-unknown-none-elf
mips-mti-none-elf
mips-unknown-linux-gnu
mips-unknown-linux-musl
mips-unknown-linux-uclibc
mips64-openwrt-linux-musl
mips64-unknown-linux-gnuabi64
mips64-unknown-linux-muslabi64
mips64el-unknown-linux-gnuabi64
mips64el-unknown-linux-muslabi64
mipsel-mti-none-elf
mipsel-sony-psp
mipsel-sony-psx
mipsel-unknown-linux-gnu
mipsel-unknown-linux-musl
mipsel-unknown-linux-uclibc
mipsel-unknown-netbsd
mipsel-unknown-none
mipsisa32r6-unknown-linux-gnu
mipsisa32r6el-unknown-linux-gnu
mipsisa64r6-unknown-linux-gnuabi64
mipsisa64r6el-unknown-linux-gnuabi64
msp430-none-elf
nvptx64-nvidia-cuda
powerpc-unknown-freebsd
powerpc-unknown-helenos
powerpc-unknown-linux-gnu
powerpc-unknown-linux-gnuspe
powerpc-unknown-linux-musl
powerpc-unknown-linux-muslspe
powerpc-unknown-netbsd
powerpc-unknown-openbsd
powerpc-wrs-vxworks
powerpc-wrs-vxworks-spe
powerpc64-ibm-aix
powerpc64-unknown-freebsd
powerpc64-unknown-linux-gnu
powerpc64-unknown-linux-musl
powerpc64-unknown-openbsd
powerpc64-wrs-vxworks
powerpc64le-unknown-freebsd
powerpc64le-unknown-linux-gnu
powerpc64le-unknown-linux-musl
riscv32-wrs-vxworks
riscv32e-unknown-none-elf
riscv32em-unknown-none-elf
riscv32emc-unknown-none-elf
riscv32gc-unknown-linux-gnu
riscv32gc-unknown-linux-musl
riscv32i-unknown-none-elf
riscv32im-risc0-zkvm-elf
riscv32im-unknown-none-elf
riscv32ima-unknown-none-elf
riscv32imac-esp-espidf
riscv32imac-unknown-none-elf
riscv32imac-unknown-nuttx-elf
riscv32imac-unknown-xous-elf
riscv32imafc-esp-espidf
riscv32imafc-unknown-none-elf
riscv32imafc-unknown-nuttx-elf
riscv32imc-esp-espidf
riscv32imc-unknown-none-elf
riscv32imc-unknown-nuttx-elf
riscv64-linux-android
riscv64-wrs-vxworks
riscv64a23-unknown-linux-gnu
riscv64gc-unknown-freebsd
riscv64gc-unknown-fuchsia
riscv64gc-unknown-hermit
riscv64gc-unknown-linux-gnu
riscv64gc-unknown-linux-musl
riscv64gc-unknown-managarm-mlibc
riscv64gc-unknown-netbsd
riscv64gc-unknown-none-elf
riscv64gc-unknown-nuttx-elf
riscv64gc-unknown-openbsd
riscv64gc-unknown-redox
riscv64im-unknown-none-elf
riscv64imac-unknown-none-elf
riscv64imac-unknown-nuttx-elf
s390x-unknown-linux-gnu
s390x-unknown-linux-musl
sparc-unknown-linux-gnu
sparc-unknown-none-elf
sparc64-unknown-helenos
sparc64-unknown-linux-gnu
sparc64-unknown-netbsd
sparc64-unknown-openbsd
sparcv9-sun-solaris
thumbv4t-none-eabi
thumbv5te-none-eabi
thumbv6m-none-eabi
thumbv6m-nuttx-eabi
thumbv7a-nuttx-eabi
thumbv7a-nuttx-eabihf
thumbv7a-pc-windows-msvc
thumbv7a-uwp-windows-msvc
thumbv7em-none-eabi
thumbv7em-none-eabihf
thumbv7em-nuttx-eabi
thumbv7em-nuttx-eabihf
thumbv7m-none-eabi
thumbv7m-nuttx-eabi
thumbv7neon-linux-androideabi
thumbv7neon-unknown-linux-gnueabihf
thumbv7neon-unknown-linux-musleabihf
thumbv8m.base-none-eabi
thumbv8m.base-nuttx-eabi
thumbv8m.main-none-eabi
thumbv8m.main-none-eabihf
thumbv8m.main-nuttx-eabi
thumbv8m.main-nuttx-eabihf
wasm32-unknown-emscripten
wasm32-unknown-unknown
wasm32-wali-linux-musl
wasm32-wasip1
wasm32-wasip1-threads
wasm32-wasip2
wasm32-wasip3
wasm32v1-none
wasm64-unknown-unknown
x86_64-apple-darwin
x86_64-apple-ios
x86_64-apple-ios-macabi
x86_64-apple-tvos
x86_64-apple-watchos-sim
x86_64-fortanix-unknown-sgx
x86_64-linux-android
x86_64-lynx-lynxos178
x86_64-pc-cygwin
x86_64-pc-nto-qnx710
x86_64-pc-nto-qnx710_iosock
x86_64-pc-nto-qnx800
x86_64-pc-solaris
x86_64-pc-windows-gnu
x86_64-pc-windows-gnullvm
x86_64-pc-windows-msvc
x86_64-unikraft-linux-musl
x86_64-unknown-dragonfly
x86_64-unknown-freebsd
x86_64-unknown-fuchsia
x86_64-unknown-haiku
x86_64-unknown-helenos
x86_64-unknown-hermit
x86_64-unknown-hurd-gnu
x86_64-unknown-illumos
x86_64-unknown-l4re-uclibc
x86_64-unknown-linux-gnu
x86_64-unknown-linux-gnux32
x86_64-unknown-linux-musl
x86_64-unknown-linux-none
x86_64-unknown-linux-ohos
x86_64-unknown-managarm-mlibc
x86_64-unknown-motor
x86_64-unknown-netbsd
x86_64-unknown-none
x86_64-unknown-openbsd
x86_64-unknown-redox
x86_64-unknown-trusty
x86_64-unknown-uefi
x86_64-uwp-windows-gnu
x86_64-uwp-windows-msvc
x86_64-win7-windows-gnu
x86_64-win7-windows-msvc
x86_64-wrs-vxworks
x86_64h-apple-darwin
xtensa-esp32-espidf
xtensa-esp32-none-elf
xtensa-esp32s2-espidf
xtensa-esp32s2-none-elf
xtensa-esp32s3-espidf
xtensa-esp32s3-none-elf
# Extra LLVM/Zig OS types not in Rust's target list
aarch64-apple-bridgeos
aarch64-apple-driverkit
arm-unknown-contiki
s390x-ibm-zos
x86_64-unknown-plan9
x86_64-unknown-rtems
x86_64-pc-serenity
