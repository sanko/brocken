use v5.42;
use feature qw[class];
no warnings qw[experimental::class experimental::builtin];
use Brocken::Katsuro::Platform::ABI;

class Brocken::Katsuro::Platform {
    use Config qw(%Config);

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
        esp lynx unikraft kmc wrs portbld
    );

    # Hide stderr appropriately for the host OS shell.
    # This is critical for feature detection where commands might fail.
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

    # Normalizes various triple formats (e.g., from clang or gcc) into our 4-part canonical form.
    # This ensures consistency across different toolchains.
    sub normalize_triple($raw) {
        my @parts = split( /-/, $raw );

        # Canonicalize architecture names before parsing.
        # We prefer 'aarch64' over 'arm64' for consistency with ELF/Linux naming.
        $parts[0] = 'aarch64' if ( $parts[0] // '' ) =~ /^arm64_32$/i;
        $parts[0] = 'aarch64' if ( $parts[0] // '' ) =~ /^arm64$/i;
        $parts[0] = 'x86_64'  if ( $parts[0] // '' ) =~ /^(amd64|x64|i86pc)$/i;
        $parts[0] = 'i386'    if ( $parts[0] // '' ) =~ /^i[3456]86$/i;
        $parts[0] = 'riscv64' if ( $parts[0] // '' ) =~ /^riscv64/i;
        return join( '-', @parts ) if @parts == 4;
        if ( @parts == 3 ) {
            my ( $p1, $p2, $p3 ) = @parts;

            # macOS/Darwin usually reports as <arch>-apple-darwin<ver>
            return join( '-', $p1, $p2, $p3, 'macho' ) if $p2 eq 'apple' && $p3 =~ /darwin/i;

            # Linux often reports as <arch>-pc-linux-gnu or similar
            return join( '-', $p1, 'pc', $p2, $p3 ) if $p2 eq 'linux';

            # MinGW on Windows
            return join( '-', $p1, 'pc', 'windows', 'gnu' ) if $p2 =~ /w64/i && $p3 =~ /mingw/i;

            # Handle arch--os (empty vendor) which is common in some cross-compilation environments
            if ( $p2 eq '' ) { return join( '-', $p1, 'unknown', $p3, 'unknown' ) }

            # Distinguish between vendor and OS if only 3 parts are present
            return $known_vendor{$p2} ? join( '-', $p1, $p2, $p3, 'unknown' ) : join( '-', $p1, 'unknown', $p2, $p3 );
        }
        if ( @parts == 2 ) { return join( '-', $parts[0], 'unknown', $parts[1], 'unknown' ) }
        push @parts, 'unknown' while @parts < 4;
        return join( '-', @parts[ 0 .. 3 ] );
    }

    # Generates a triple for the current host machine by probing compilers or Config.pm.
    sub gen_triple() {
        state $cached_host_triple;
        return $cached_host_triple if defined $cached_host_triple;

        # Try clang first as it provides the most modern triple format
        my $clang_out = get_cmd_output('clang --print-target-triple');
        if ($clang_out) {
            if ( $^O eq 'midnightbsd' ) { $clang_out =~ s/\bfreebsd[^-]*/midnightbsd/gi }
            return $cached_host_triple = normalize_triple($clang_out);
        }

        # Fallback to gcc machine dump
        my $gcc_out = get_cmd_output('gcc -dumpmachine');
        if ($gcc_out) {
            if ( $^O eq 'midnightbsd' ) { $gcc_out =~ s/\bfreebsd[^-]*/midnightbsd/gi }
            return $cached_host_triple = normalize_triple($gcc_out);
        }

        # Manual detection from Perl's Config and OS environment
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
            require POSIX;
            eval { my @uname = POSIX::uname(); $arch = $uname[4] };
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

    # Instantiates the appropriate platform subclass based on the provided triple.
    sub parse( $platform //= gen_triple() ) {
        $platform = normalize_triple($platform);
        my $host_triple = gen_triple();
        my $is_native   = ( $platform eq $host_triple ) ? 1 : 0;
        my ( $arch, $vendor, $os, $env ) = split /-/, $platform;
        my $os_version;
        if ( defined $os && $os =~ /^([a-z]+?)([\d._]+)$/i ) {
            $os_version = $2;
            $os         = $1;
        }
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
        elsif ( $os =~ /solaris|sunos|illumos/i )                       { $class = 'Brocken::Katsuro::Platform::Solaris' }
        elsif ( $arch =~ /^wasm/ || $os =~ /wasi/i || $env =~ /wasi/i ) { $class = 'Brocken::Katsuro::Platform::Wasm' }
        my $friendly;
        builtin::load_module $class;
        $class->new(
            arch       => $arch,
            vendor     => $vendor,
            os         => $os,
            os_version => $os_version,
            env        => $env,
            friendly   => $friendly,
            is_native  => $is_native
        );
    }
    field $arch       : reader : param;
    field $vendor     : reader : param;
    field $os         : reader : param = ();
    field $os_version : reader : param = undef;
    field $env        : reader : param = ();
    field $friendly   : reader : param = ();
    field $is_native  : reader : param = 0;
    field $abi        : reader = Brocken::Katsuro::Platform::ABI->parse($arch);
    ADJUST {
        # Assign friendly names for display purposes, particularly for Apple platforms.
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
    method bin_ext()              {''}
    method lib_ext()              {'.so'}
    method format()               {'elf'}
    method abi_name()             { $self->env }
    method lib_prefix()           {'lib'}
    method bin_name($name)        { $name . $self->bin_ext }
    method static_lib_ext()       {'.a'}
    method static_lib_name($name) { $self->lib_prefix . $name . $self->static_lib_ext }

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
    method is_solaris ()     {0}
    method is_wasm()         {0}
    method is_posix()        {1}
    #
    method is_arm64()   { $self->arch eq 'aarch64' }
    method is_riscv64() { $self->arch eq 'riscv64' }
    method is_x64()     { $self->arch eq 'x86_64' }
    #
    # Returns a mapping of common syscall names to their architecture-specific numbers.
    # Defaults to BSD-style syscall numbering which is shared by FreeBSD, NetBSD, OpenBSD,
    # DragonFly, and Mach (to some extent).
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

    # The register used to pass the syscall number to the kernel.
    method syscall_num_reg() {
        my %map = ( x86_64 => 'rax', aarch64 => 'x8', riscv64 => 'a7' );
        return $map{ $self->arch };
    }

    # The register where the kernel places the syscall's return value.
    method syscall_ret_reg() {
        my %map = ( x86_64 => 'rax', aarch64 => 'x0', riscv64 => 'a0' );
        return $map{ $self->arch };
    }

    # Operating system page size. Critical for segment alignment and mmap calls.
    # Apple Silicon (ARM64) macOS uses 16KB pages, while Intel uses 4KB.
    method page_size() {
        return 0x4000 if $self->arch =~ /aarch64|arm64/i;
        return 0x1000;
    }

    #~ Register queries from ABI
    method registers( $category = 'available' )    { $self->abi->registers($category) }
    method fp_registers( $category = 'available' ) { $self->abi->fp_registers($category) }
    method caller_saved()                          { $self->abi->caller_saved }
    method callee_saved()                          { $self->abi->callee_saved }
    method frame_reg()                             { $self->abi->frame_reg }
    method stack_reg()                             { $self->abi->stack_reg }
    method return_register()                       { $self->abi->return_register }
    method fp_return_register()                    { $self->abi->fp_return_register }
}
1;
