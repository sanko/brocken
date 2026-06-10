use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', 'blib/lib', '../../blib/lib';
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
$|++;

class Brocken::Compiler { }

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
    my %hold;
    sub get_hold() { \%hold }
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
        return $raw if @parts == 4;
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
        my $clang_out = get_cmd_output('clang --print-target-triple');
        return normalize_triple($clang_out) if $clang_out;
        my $gcc_out = get_cmd_output('gcc -dumpmachine');
        return normalize_triple($gcc_out) if $gcc_out;
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
            $arch = 'aarch64' if $arch eq 'arm64';
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
        join '-', $arch || 'unknown', $vendor || 'unknown', $os || 'unknown', $env || 'unknown';
    }

    sub parse( $platform //= gen_triple() ) {
        my $host_triple = gen_triple();
        my $is_native   = ( $platform eq $host_triple ) ? 1 : 0;
        my @parts       = split /-/, $platform;
        my ( $arch, $vendor, $os, $env );
        if    ( @parts == 4 ) { ( $arch, $vendor, $os, $env ) = @parts }
        elsif ( @parts == 3 ) {
            if ( ( $parts[1] // '' ) eq '' ) {    # Handle arch--os
                $arch   = $parts[0];
                $vendor = 'unknown';
                $os     = $parts[2];
                $env    = 'unknown';
            }
            elsif ( $known_vendor{ $parts[1] // '' } ) {
                ( $arch, $vendor, $os ) = @parts;
                $env = 'unknown';
            }
            else {
                ( $arch, $os, $env ) = @parts;
                $vendor = 'unknown';
            }
        }
        elsif ( @parts == 2 ) { ( $arch, $os ) = @parts; $vendor = 'unknown'; $env = 'unknown' }
        else                  { $arch = $parts[0]; ( $vendor, $os, $env ) = ('unknown') x 3 }

        # Ensure no field is empty
        $arch   ||= 'unknown';
        $vendor ||= 'unknown';
        $os     ||= 'unknown';
        $env    ||= 'unknown';
        $hold{$vendor}{$arch}{ $os // '_' }{ $env // '_' } = $platform;
        my $class = 'Brocken::Katsuro::Platform::Generic';
        if    ( $os =~ /linux/i )                                       { $class = 'Brocken::Katsuro::Platform::Linux' }
        elsif ( $os =~ /darwin|macos|ios/i )                            { $class = 'Brocken::Katsuro::Platform::MacOS' }
        elsif ( $os =~ /windows|win32|mswin/i )                         { $class = 'Brocken::Katsuro::Platform::Windows' }
        elsif ( $os =~ /midnightbsd/i )                                 { $class = 'Brocken::Katsuro::Platform::MidnightBSD' }
        elsif ( $os =~ /freebsd|openbsd|netbsd|dragonfly|bsd/i )        { $class = 'Brocken::Katsuro::Platform::BSD' }
        elsif ( $os =~ /^haiku$/i )                                     { $class = 'Brocken::Katsuro::Platform::Haiku' }
        elsif ( $arch =~ /^wasm/ || $os =~ /wasi/i || $env =~ /wasi/i ) { $class = 'Brocken::Katsuro::Platform::Wasm' }
        my $friendly;

        if ( $vendor eq 'apple' ) {
            if ( $arch eq 'aarch64' ) {
                if    ( $os eq 'darwin' )   { $friendly = 'macOS on Apple Silicon' }
                elsif ( $os eq 'ios' )      { $friendly = 'iOS' }
                elsif ( $os eq 'tvos' )     { $friendly = 'Apple TV' }
                elsif ( $os eq 'visionos' ) { $friendly = 'Apple Vision' }
            }
            elsif ( $arch eq 'x86_64' ) {
                if    ( $os eq 'darwin' )  { $friendly = 'macOS on Intel' }
                elsif ( $os eq 'watchos' ) { $friendly = 'Apple Watch Simulator' }
            }
        }
        $class->new( arch => $arch, vendor => $vendor, os => $os, env => $env, friendly => $friendly, is_native => $is_native );
    }
    field $arch      : reader : param;
    field $vendor    : reader : param;
    field $os        : reader : param = ();
    field $env       : reader : param = ();
    field $friendly  : reader : param //= 'sand that does math';
    field $is_native : reader : param = 0;
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
    method is_windows()     {0}
    method is_macos()       {0}
    method is_linux()       {0}
    method is_bsd()         {0}
    method is_haiku()       {0}
    method is_midnightbsd() {0}
    method is_wasm()        {0}
    method is_posix()       {1}

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
    method registers( $category = 'available' ) {
        return Brocken::Katsuro::Platform::ABI->registers( $category, $self->arch );
    }
    method caller_saved() { $self->registers('caller') }
    method callee_saved() { $self->registers('callee') }
    method frame_reg()    { Brocken::Katsuro::Platform::ABI->frame_reg( $self->arch ) }
    method stack_reg()    { Brocken::Katsuro::Platform::ABI->stack_reg( $self->arch ) }

    class Brocken::Katsuro::Platform::ABI {

        sub registers( $class, $category = 'available', $arch = 'x86_64' ) {
            my %data = (
                x86_64 => {
                    available => [qw[rax rcx rdx rbx rsi rdi r8 r9 r10 r11 r12 r13 r14 r15]],
                    caller    => [qw[rax rcx rdx rsi rdi r8 r9 r10 r11]],
                    callee    => [qw[rbx r12 r13 r14 r15]],
                },
                aarch64 => {
                    available => [qw[x0 x1 x2 x3 x4 x5 x6 x7 x9 x10 x11 x12 x13 x14 x15 x20 x21 x22 x23 x24 x25 x26 x27 x28]],
                    caller    => [qw[x0 x1 x2 x3 x4 x5 x6 x7 x9 x10 x11 x12 x13 x14 x15]],
                    callee    => [qw[x20 x21 x22 x23 x24 x25 x26 x27 x28]],
                },
                riscv64 => {
                    available => [qw[a0 a1 a2 a3 a4 a5 a6 a7 s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t0 t1 t2 t3 t4 t5 t6]],
                    caller    => [qw[a0 a1 a2 a3 a4 a5 a6 a7 t0 t1 t2 t3 t4 t5 t6]],
                    callee    => [qw[s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11]],
                },
            );
            return $data{$arch}{$category} // [];
        }

        sub frame_reg( $class, $arch = 'x86_64' ) {
            my %map = ( x86_64 => 'rbp', aarch64 => 'x29', riscv64 => 's0' );
            return $map{$arch};
        }

        sub stack_reg( $class, $arch = 'x86_64' ) {
            my %map = ( x86_64 => 'rsp', aarch64 => 'sp', riscv64 => 'sp' );
            return $map{$arch};
        }
    }
}

class Brocken::Katsuro::Platform::Generic : isa(Brocken::Katsuro::Platform) { }

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
                write     => 4,
                read      => 3,
                open      => 5,
                close     => 6,
                exit      => 1,
                fork      => 2,
                getpid    => 20,
                wait4     => 11,
                mmap      => 197,
                nanosleep => 101,
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
                mmap      => 197,
                nanosleep => 101,
                brk       => 45
            },
        };
    }
}

class Brocken::Katsuro::Platform::Windows : isa(Brocken::Katsuro::Platform) {
    method is_windows()     {1}
    method is_posix()       {0}
    method bin_ext()        {'.exe'}
    method lib_ext()        {'.dll'}
    method format()         {'pe'}
    method lib_prefix()     {''}
    method static_lib_ext() {'.lib'}

    method shared_lib_name( $name, $version = undef ) {
        return $name . $self->lib_ext if !defined $version;
        return $name . '-' . $version . $self->lib_ext;
    }
}

class Brocken::Katsuro::Platform::BSD : isa(Brocken::Katsuro::Platform) {
    method is_bsd() {1}
}

class Brocken::Katsuro::Platform::MidnightBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_midnightbsd() {1}
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
        if    ( $arch =~ /x86_64|x64|amd64/i ) { return $1 if $dis =~ /mov\s+eax,\s*0x([0-9a-f]+)/i }
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

class Brocken::Katsuro { }

class Brocken::Lindsay { }

class Brocken::Jenny { }
#
my $compiler = Brocken::Compiler->new();
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
subtest 'platform naming' => sub {

    # Linux (ELF)
    my $linux = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
    is $linux->bin_name('foo'),                 'foo',           'linux bin_name';
    is $linux->static_lib_name('foo'),          'libfoo.a',      'linux static_lib_name';
    is $linux->shared_lib_name('foo'),          'libfoo.so',     'linux shared_lib_name';
    is $linux->shared_lib_name( 'foo', '1.2' ), 'libfoo.so.1.2', 'linux shared_lib_name with version';

    # Windows (PE)
    my $win = Brocken::Katsuro::Platform::parse('x86_64-pc-windows-msvc');
    is $win->bin_name('foo'),                 'foo.exe',     'windows bin_name';
    is $win->static_lib_name('foo'),          'foo.lib',     'windows static_lib_name';
    is $win->shared_lib_name('foo'),          'foo.dll',     'windows shared_lib_name';
    is $win->shared_lib_name( 'foo', '1.2' ), 'foo-1.2.dll', 'windows shared_lib_name with version';

    # MacOS (Mach-O)
    my $mac = Brocken::Katsuro::Platform::parse('aarch64-apple-darwin');
    is $mac->bin_name('foo'),                 'foo',              'macos bin_name';
    is $mac->static_lib_name('foo'),          'libfoo.a',         'macos static_lib_name';
    is $mac->shared_lib_name('foo'),          'libfoo.dylib',     'macos shared_lib_name';
    is $mac->shared_lib_name( 'foo', '1.2' ), 'libfoo.1.2.dylib', 'macos shared_lib_name with version';

    # Wasm
    my $wasm = Brocken::Katsuro::Platform::parse('wasm32-unknown-unknown');
    is $wasm->bin_name('foo'),        'foo.wasm', 'wasm bin_name';
    is $wasm->static_lib_name('foo'), 'foo.a',    'wasm static_lib_name';
    is $wasm->shared_lib_name('foo'), 'foo.wasm', 'wasm shared_lib_name';
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
    my %arch_64 = map { $_ => 1 }
        qw( x86_64 aarch64 aarch64_be arm64e riscv64 powerpc64 powerpc64le mips64 mips64el loongarch64 s390x sparc64 wasm64 nvptx64 );
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
