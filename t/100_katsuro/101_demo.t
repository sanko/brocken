use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', 'blib/lib', '../../blib/lib';
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
$|++;
#
class Brocken::Compiler { }

package Brocken::Katsuro {

=pod

=head1 NAME

Brocken::Katsuro - Platform and Architecture Abstraction Layer

=head1 DESCRIPTION

This package handles the detection, normalization, and abstraction of target
platforms (OS and Architecture). It provides a unified interface for querying
syscall numbers, register sets, and binary format requirements.

=head2 Target Triples

Brocken uses a four-part "normalized" triple format: C<arch-vendor-os-env>.

=over 4

=item * B<arch>: x86_64, aarch64, riscv64, etc.

=item * B<vendor>: pc, apple, unknown, etc.

=item * B<os>: linux, darwin, windows, freebsd, netbsd, openbsd, dragonfly, haiku, solaris, wasi.

=item * B<env>: gnu, msvc, macho, elf, wasi, musl, etc.

=back

=head2 References

=over 4

=item * Target Triplet Wiki: L<https://wiki.osdev.org/Target_Triplet>

=item * LLVM Triple Header: L<https://llvm.org/doxygen/Triple_8h_source.html>

=back

=cut

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
            esp lynx unikraft kmc wrs portbld
        );
        use Config;

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
            $parts[0] = 'aarch64' if ( $parts[0] // '' ) =~ /^arm64$/i;
            $parts[0] = 'x86_64'  if ( $parts[0] // '' ) =~ /^(amd64|x64|i86pc)$/i;
            $parts[0] = 'i386'    if ( $parts[0] // '' ) =~ /^i[3456]86$/i;
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

        # Instantiates the appropriate platform subclass based on the provided triple.
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
            elsif ( $os =~ /solaris|sunos|illumos/i )                       { $class = 'Brocken::Katsuro::Platform::Solaris' }
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
        method registers( $category = 'available' ) { $self->abi->registers($category) }
        method fp_registers( $category = 'available' ) { $self->abi->fp_registers($category) }
        method caller_saved()                       { $self->abi->caller_saved }
        method callee_saved()                       { $self->abi->callee_saved }
        method frame_reg()                          { $self->abi->frame_reg }
        method stack_reg()                          { $self->abi->stack_reg }

=pod

=head1 NAME

Brocken::Katsuro::Platform::ABI - Low-level Architecture Binary Interface details

=head1 DESCRIPTION

This class and its subclasses define the register sets and DWARF numbering
for specific architectures. It abstracts the differences between calling
conventions (e.g., which registers are preserved across calls).

=cut

        class Brocken::Katsuro::Platform::ABI {

            sub parse ( $class, $arch ) {
                if    ( $arch =~ /x86_64|x64|amd64/i ) { return Brocken::Katsuro::Platform::ABI::X86_64->new }
                elsif ( $arch =~ /aarch64|arm64/i )    { return Brocken::Katsuro::Platform::ABI::AArch64->new }
                elsif ( $arch =~ /riscv64/i )          { return Brocken::Katsuro::Platform::ABI::RISCV64->new }
                return $class->new;
            }
            method registers( $category = 'available' ) { [] }
            method fp_registers( $category = 'available' ) { [] }
            method caller_saved()                       { $self->registers('caller') }
            method callee_saved()                       { $self->registers('callee') }
            method frame_reg()                          {undef}
            method stack_reg()                          {undef}
            method dwarf_reg_num($name)                 {undef}
        }

        class Brocken::Katsuro::Platform::ABI::X86_64 : isa(Brocken::Katsuro::Platform::ABI) {

            # System V AMD64 Calling Convention
            # SCRATCH: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11
            # PRESERVED: rbx, rsp, rbp, r12, r13, r14, r15
            method registers( $category = 'available' ) {
                my %data = (
                    available => [qw[rax rcx rdx rbx rsi rdi r8 r9 r10 r11 r12 r13 r14 r15]],
                    caller    => [qw[rax rcx rdx rsi rdi r8 r9 r10 r11]],
                    callee    => [qw[rbx r12 r13 r14 r15]]
                );
                return $data{$category} // [];
            }
            # SSE/AVX XMM registers (all caller-saved on SysV AMD64)
            method fp_registers( $category = 'available' ) {
                my %data = (
                    available => [qw[xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7 xmm8 xmm9 xmm10 xmm11 xmm12 xmm13 xmm14 xmm15]],
                    caller    => [qw[xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7 xmm8 xmm9 xmm10 xmm11 xmm12 xmm13 xmm14 xmm15]],
                    callee    => [],
                );
                return $data{$category} // [];
            }
            method frame_reg() {'rbp'}
            method stack_reg() {'rsp'}

            # System V AMD64 DWARF register numbers (rax=0, rdx=1, etc.)
            # Reference: https://refspecs.linuxbase.org/elf/x86_64-abi-0.99.pdf
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

            # ARM64 Procedure Call Standard (AAPCS64)
            # SCRATCH: x0-x15
            # PRESERVED: x19-x28, sp, x29 (fp), x30 (lr)
            method registers( $category = 'available' ) {
                my %data = (
                    available => [qw[x0 x1 x2 x3 x4 x5 x6 x7 x9 x10 x11 x12 x13 x14 x15 x20 x21 x22 x23 x24 x25 x26 x27 x28]],
                    caller    => [qw[x0 x1 x2 x3 x4 x5 x6 x7 x9 x10 x11 x12 x13 x14 x15]],
                    callee    => [qw[x20 x21 x22 x23 x24 x25 x26 x27 x28]]
                );
                return $data{$category} // [];
            }
            method frame_reg() {'x29'}
            method stack_reg() {'sp'}

            # ARM64 FP/SIMD registers (AAPCS64 calling convention)
            # Note: v0-v7 are caller-saved, v8-v15 are callee-saved (only the lower 64 bits)
            method fp_registers( $category = 'available' ) {
                my %data = (
                    available => [qw[v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15]],
                    caller    => [qw[v0 v1 v2 v3 v4 v5 v6 v7]],
                    callee    => [qw[v8 v9 v10 v11 v12 v13 v14 v15]]
                );
                return $data{$category} // [];
            }

            # ARM64 standard DWARF mappings: x0-x30 map to 0-30, sp maps to 31
            method dwarf_reg_num($name) {
                return 31 if $name eq 'sp';
                return $1 if $name =~ /^x(\d+)$/;
                return $1 if $name =~ /^v(\d+)$/;
                return undef;
            }
        }

        class Brocken::Katsuro::Platform::ABI::RISCV64 : isa(Brocken::Katsuro::Platform::ABI) {

            # RISC-V Calling Convention (lp64)
            # SCRATCH: a0-a7, t0-t6
            # PRESERVED: s0-s11, sp, gp, tp, ra
            method registers( $category = 'available' ) {
                my %data = (
                    available => [qw[a0 a1 a2 a3 a4 a5 a6 a7 s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t0 t1 t2 t3 t4 t5 t6]],
                    caller    => [qw[a0 a1 a2 a3 a4 a5 a6 a7 t0 t1 t2 t3 t4 t5 t6]],
                    callee    => [qw[s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11]]
                );
                return $data{$category} // [];
            }
            method frame_reg() {'s0'}
            method stack_reg() {'sp'}

            # RISC-V ABI register mappings to x0-x31 (zero=0, ra=1, sp=2, etc.)
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

            # RISC-V FP registers (lp64d calling convention)
            method fp_registers( $category = 'available' ) {
                my %data = (
                    available => [qw[f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 f13 f14 f15 f16 f17 f18 f19 f20 f21 f22 f23 f24 f25 f26 f27 f28 f29 f30 f31]],
                    caller    => [qw[f0 f1 f2 f3 f4 f5 f6 f7 f10 f11 f12 f13 f14 f15 f16 f17 f28 f29 f30 f31]],
                    callee    => [qw[f8 f9 f18 f19 f20 f21 f22 f23 f24 f25 f26 f27]]
                );
                return $data{$category} // [];
            }
        }
    }

    class Brocken::Katsuro::Platform::Linux : isa(Brocken::Katsuro::Platform) {
        method is_linux() {1}
        method format()   {'elf'}

        # Linux-specific syscall numbers. These differ significantly from BSD.
        method syscalls() {
            state $syscalls //= {
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
                }
            };
            $syscalls;
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

        # macOS syscalls use a 0x2000000 offset for 64-bit processes to distinguish
        # from Mach-specific or 32-bit BSD syscalls.
        method syscalls() {
            state $syscalls;
            return $syscalls if defined $syscalls;
            my $off64 = 0x2000000;
            $syscalls = {
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

        # On ARM64 macOS, x16 is used for the syscall number instead of x8.
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

        # Haiku's syscall numbers are unstable and not officially exposed.
        # We use a heuristic by disassembling libroot.so functions to find the
        # 'mov eax, imm' instruction that precedes the syscall.
        sub _detect_syscall( $class, $name, $arch ) {
            my $lib = '/boot/system/lib/libroot.so';
            return undef unless -e $lib;
            my $stub //= {
                write  => '_kern_write',
                exit   => '_kern_exit_team',
                fork   => '_kern_fork',
                wait4  => '_kern_wait_for_child',
                read   => '_kern_read',
                open   => '_kern_open',
                close  => '_kern_close',
                getpid => '_kern_getpid'
            };
            my $fn  = $stub->{$name} or return undef;
            my $cmd = "objdump -d '$lib' | grep -A 20 '<$fn>:'";
            my $dis = `$cmd 2>/dev/null` or return undef;
            if ( $arch =~ /x86_64|x64|amd64/i ) {
                return hex($1) if $dis =~ /mov\s+\$0x([0-9a-f]+),\s*%[er]?ax/i || $dis =~ /mov\s+[er]?ax,\s*0x([0-9a-f]+)/i;
            }
            elsif ( $arch =~ /aarch64|arm64/i ) { return hex($1) if $dis =~ /mov\s+x8,\s*#0x([0-9a-f]+)/i }
            elsif ( $arch =~ /riscv64|riscv/i ) { return hex($1) if $dis =~ /li\s+a7,\s*#?0x([0-9a-f]+)/i }
            return undef;
        }

        method syscall($name) {
            return $cache{ $self->arch }{$name} if exists $cache{ $self->arch }{$name};
            my $num;
            $num = _detect_syscall( ref($self), $name, $self->arch ) if $self->is_native;
            unless ( defined $num ) {

                # Fallback syscall numbers for Haiku R1/beta4
                state $fallback //= {
                    x86_64 => {
                        write     => 144,
                        exit      => 38,
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
                        write     => 144,
                        exit      => 38,
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
                        write     => 144,
                        exit      => 38,
                        fork      => 47,
                        wait4     => 45,
                        read      => 148,
                        open      => 83,
                        close     => 42,
                        getpid    => 46,
                        mmap      => 103,
                        nanosleep => 156,
                        brk       => 110
                    }
                };
                $num = $fallback->{ $self->arch }{$name};
            }
            $cache{ $self->arch }{$name} = $num;
            return $num;
        }
    }

    class Brocken::Katsuro::Platform::Solaris : isa(Brocken::Katsuro::Platform) {
        method format() {'elf'}
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

=pod

=head1 NAME

Brocken::Lindsay - Intermediate Representation (IR) and Optimization Layer

=head1 DESCRIPTION

Lindsay is a platform-independent IR inspired by LLVM. It utilizes Static
Single Assignment (SSA) form, where every variable is assigned exactly once.

=head2 Type System

The IR supports basic native types (int, float, ptr) and a specialized
C<dynamic> type.

=over 4

=item * B<int>: Fixed-width integers (i1, i8, i16, i32, i64).

=item * B<ptr>: Opaque 64-bit memory addresses.

=item * B<dynamic>: A 128-bit "Fat Scalar" representing Brocken's internal
data type (SV* equivalent). It contains a type tag and a payload.

=back

=cut

    class Brocken::Lindsay::IR::Type {
        field $kind : reader : param;        # 'int', 'float', 'ptr', 'void', 'dynamic'
        field $bits : reader : param = 0;    # 8, 16, 32, 64, ...

        # Singletons for common types to save memory and allow `==` comparison
        sub i1      { state $t //= __PACKAGE__->new( kind => 'int', bits => 1 );       $t }    # bool
        sub i8      { state $t //= __PACKAGE__->new( kind => 'int', bits => 8 );       $t }    # byte / int8 / uint8
        sub i16     { state $t //= __PACKAGE__->new( kind => 'int', bits => 16 );      $t }    # short / int16 / uint16
        sub i32     { state $t //= __PACKAGE__->new( kind => 'int', bits => 32 );      $t }    # int / char / int32 / uint32
        sub i64     { state $t //= __PACKAGE__->new( kind => 'int', bits => 64 );      $t }    # long / int64 / uint64
        sub i128    { state $t //= __PACKAGE__->new( kind => 'int', bits => 128 );     $t }    # __int128
        sub f32     { state $t //= __PACKAGE__->new( kind => 'float', bits => 32 );    $t }    # float
        sub f64     { state $t //= __PACKAGE__->new( kind => 'float', bits => 64 );    $t }    # double
        sub ptr     { state $t //= __PACKAGE__->new( kind => 'ptr' );                  $t }    # opaque pointer
        sub void    { state $t //= __PACKAGE__->new( kind => 'void' );                 $t }
        sub dynamic { state $t //= __PACKAGE__->new( kind => 'dynamic', bits => 128 ); $t }    # 16-byte Fat Scalar (Tag + Payload), our SV*

        method as_string() {
            return "i$bits" if $kind eq 'int';
            return "f$bits" if $kind eq 'float';
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
            my $res = $self->type->kind eq 'void' ? '' : ( $self->name // '%<anon>' ) . ' = ';

            # Binary operations in LLVM usually take the form: <op> <type> <op1>, <op2>
            if ( scalar $operands->@* == 2 && $operands->[0]->type->as_string eq $operands->[1]->type->as_string ) {
                return sprintf "  %s%s %s %s, %s", $res, $opcode, $operands->[0]->type->as_string, $operands->[0]->as_string,
                    $operands->[1]->as_string;
            }
            my $ops = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $operands->@*;
            return "  $res$opcode $ops";
        }
    }

    class Brocken::Lindsay::IR::Instruction::ICmp : isa(Brocken::Lindsay::IR::Instruction) {
        field $predicate : reader : param;    # 'eq', 'ne', 'sgt' (signed greater than), 'slt', etc.

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

    class Brocken::Lindsay::IR::Instruction::Phi : isa(Brocken::Lindsay::IR::Instruction) {
        field $incoming : reader : param = [];    # Array of [Value, Block]

        method render() {
            my $incoming_str = join ', ', map { sprintf '[ %s, %%%s ]', $_->[0]->as_string, $_->[1]->name } $incoming->@*;
            return sprintf '  %s = phi %s %s', ( $self->name // '%<anon>' ), $self->type->as_string, $incoming_str;
        }

        method add_incoming( $val, $block ) {
            push $incoming->@*, [ $val, $block ];
        }
    }

    class Brocken::Lindsay::IR::Instruction::Select : isa(Brocken::Lindsay::IR::Instruction) {

        method render() {
            my ( $cond, $true_val, $false_val ) = $self->operands->@*;
            return sprintf '  %s = select %s %s, %s %s, %s %s', ( $self->name // '%<anon>' ), $cond->type->as_string, $cond->as_string,
                $true_val->type->as_string, $true_val->as_string, $false_val->type->as_string, $false_val->as_string;
        }
    }

    class Brocken::Lindsay::IR::Instruction::GetElementPtr : isa(Brocken::Lindsay::IR::Instruction) {
        field $base_type : reader : param;

        method render() {
            my ( $ptr, @indices ) = $self->operands->@*;
            my $idx_str = join ', ', map { $_->type->as_string . ' ' . $_->as_string } @indices;
            return sprintf '  %s = getelementptr %s, %s %s, %s', ( $self->name // '%<anon>' ), $base_type->as_string, $ptr->type->as_string,
                $ptr->as_string, $idx_str;
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

        method build_binop( $opcode, $lhs, $rhs, $name = undef ) {
            my $inst = Brocken::Lindsay::IR::Instruction->new(
                name     => $name // $self->_next_id(),
                type     => $lhs->type,
                opcode   => $opcode,
                operands => [ $lhs, $rhs ],
                parent   => $insert_block
            );
            return $insert_block->append_inst($inst);
        }
        method build_add( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'add',  $lhs, $rhs, $name ) }
        method build_sub( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'sub',  $lhs, $rhs, $name ) }
        method build_mul( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'mul',  $lhs, $rhs, $name ) }
        method build_div( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'div',  $lhs, $rhs, $name ) }
        method build_shl( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'shl',  $lhs, $rhs, $name ) }
        method build_lshr( $lhs, $rhs, $name = undef ) { $self->build_binop( 'lshr', $lhs, $rhs, $name ) }
        method build_ashr( $lhs, $rhs, $name = undef ) { $self->build_binop( 'ashr', $lhs, $rhs, $name ) }
        method build_and( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'and',  $lhs, $rhs, $name ) }
        method build_or( $lhs, $rhs, $name   = undef ) { $self->build_binop( 'or',   $lhs, $rhs, $name ) }
        method build_xor( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'xor',  $lhs, $rhs, $name ) }
        method build_min( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'min',  $lhs, $rhs, $name ) }
        method build_max( $lhs, $rhs, $name  = undef ) { $self->build_binop( 'max',  $lhs, $rhs, $name ) }

        method build_unop( $opcode, $operand, $name = undef ) {
            my $inst = Brocken::Lindsay::IR::Instruction->new(
                name     => $name // $self->_next_id(),
                type     => $operand->type,
                opcode   => $opcode,
                operands => [ $operand ],
                parent   => $insert_block
            );
            return $insert_block->append_inst($inst);
        }
        method build_neg( $operand, $name  = undef ) { $self->build_unop( 'neg',  $operand, $name ) }
        method build_abs( $operand, $name  = undef ) { $self->build_unop( 'abs',  $operand, $name ) }
        method build_sqrt( $operand, $name = undef ) { $self->build_unop( 'sqrt', $operand, $name ) }

        method build_phi( $type, $name = undef ) {
            my $inst = Brocken::Lindsay::IR::Instruction::Phi->new(
                name   => $name // $self->_next_id(),
                type   => $type,
                opcode => 'phi',
                parent => $insert_block
            );
            return $insert_block->append_inst($inst);
        }

        method build_select( $cond, $true_val, $false_val, $name = undef ) {
            my $inst = Brocken::Lindsay::IR::Instruction::Select->new(
                name     => $name // $self->_next_id(),
                type     => $true_val->type,
                opcode   => 'select',
                operands => [ $cond, $true_val, $false_val ],
                parent   => $insert_block
            );
            return $insert_block->append_inst($inst);
        }

        method build_gep( $base_type, $ptr, $indices, $name = undef ) {
            my $inst = Brocken::Lindsay::IR::Instruction::GetElementPtr->new(
                name      => $name // $self->_next_id(),
                type      => Brocken::Lindsay::IR::Type::ptr(),
                opcode    => 'getelementptr',
                base_type => $base_type,
                operands  => [ $ptr, $indices->@* ],
                parent    => $insert_block
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

=pod

=head1 NAME

Brocken::Jenny - Machine Code Generation and Linking Layer

=head1 DESCRIPTION

Jenny is responsible for lowering Lindsay IR into native machine code (Jenny::Codegen) and packaging those bytes into executable binary formats
like ELF, Mach-O, or PE (Jenny::Linker).

=cut

    class Brocken::Jenny::Codegen::X86_64 {
        field $platform : param = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');

        # Lower Lindsay IR to MIR, allocate registers, then encode to x86_64 machine code
        method emit_function($ir_func) {
            my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
            my $mf      = $lowerer->lower($ir_func);
            my $alloc   = Brocken::Jenny::RegAlloc::LinearScan->new();
            my $int_res = $alloc->allocate( $mf, $platform, 0 );
            $alloc->insert_spill_code( $mf, $int_res->{spill_slots}, $int_res->{spill_temp}, $platform->stack_reg, 0 );
            my $fp_res = $alloc->allocate( $mf, $platform, 1 );
            $alloc->insert_spill_code( $mf, $fp_res->{spill_slots}, $fp_res->{spill_temp}, $platform->stack_reg, 1 );
            my %assignment = ( $int_res->{assignment}->%*, $fp_res->{assignment}->%* );
            my %callee_seen;
            @callee_seen{ $int_res->{used_callee}->@* } = ();
            @callee_seen{ $fp_res->{used_callee}->@* } = ();
            my @used_callee = sort keys %callee_seen;
            return $self->_encode( $mf, \%assignment, \@used_callee );
        }

        # Encode MIR to x86_64 machine code bytes (registers pre-allocated)
        method _encode( $mf, $assignment, $used_callee ) {
            my $bytes       = '';
            my $total_frame = 0;
            my %reg_id_map  = ( rax => 0, rcx => 1, rdx => 2, rbx => 3, rsp => 4, rbp => 5, rsi => 6, rdi => 7 );
            for my $i ( 0 .. 15 ) { $reg_id_map{ "xmm$i" } = $i }
            my $reg_id = sub ($r) { return $reg_id_map{$r} // ( $r =~ /^r(\d+)$/ ? $1 : 0 ) };

            for my $reg ( $used_callee->@* ) {
                my $rid = $reg_id->($reg);
                if ( $rid < 8 ) { $bytes .= pack( 'C', 0x50 + $rid ) }
                else            { $bytes .= pack( 'CC', 0x41, 0x50 + ( $rid - 8 ) ) }
            }

            my $resolve = sub ($op) {
                return $assignment->{ $op->value } if $op->kind eq 'virt_reg';
                return $op->value                  if $op->kind eq 'phys_reg';
                die "Unexpected operand kind: ${\$op->kind}";
            };

            my %labels;
            my @fixups;
            my $current_offset = sub { return length $bytes };

            my $mem_modrm = sub ($mem_op, $reg_idx) {
                my $addr = $mem_op->value;
                my $base_r = $resolve->(
                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} )
                );
                my $bid  = $reg_id->($base_r);
                my $disp = $addr->{disp} // 0;
                my $rm   = $bid & 7;
                my ( $mod, @extra );

                if ( $rm == 4 ) {
                    $rm = 4;
                    if ( $disp == 0 )        { $mod = 0 }
                    elsif ( $disp >= -128 && $disp <= 127 ) { $mod = 1; @extra = ( pack( 'c', $disp ), "\x24" ) }
                    else                     { $mod = 2; @extra = ( pack( 'V', $disp ), "\x24" ) }
                }
                elsif ( $disp == 0 && $rm != 5 ) {
                    $mod = 0;
                }
                else {
                    if ( $disp >= -128 && $disp <= 127 ) { $mod = 1; @extra = ( pack( 'c', $disp ) ) }
                    else                                 { $mod = 2; @extra = ( pack( 'V', $disp ) ) }
                }
                my $modrm = ( $mod << 6 ) | ( ( $reg_idx & 7 ) << 3 ) | $rm;
                return ( $modrm, \@extra );
            };

            for my $mbb ( $mf->blocks->@* ) {
                for my $inst ( $mbb->instructions->@* ) {
                    my $opcode   = $inst->opcode;
                    my ( $dst, $src ) = $inst->operands->@*;

                    if ( $opcode eq 'mov' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;

                        if ( $src->kind eq 'imm' ) {
                            my $rex_w = ( $bits >= 64 ) ? 0x08 : 0x00;
                            my $rex_b = $did >= 8 ? 0x01 : 0x00;
                            if ( $rex_w && ( abs($src->value) > 0x7FFFFFFF ) ) {
                                $bytes .= pack( 'C', 0x48 | $rex_b ) . pack( 'C', 0xB8 + ( $did & 7 ) ) . pack( 'Q', $src->value );
                            }
                            elsif ( $rex_w ) {
                                $bytes .= pack( 'CCC', 0x48 | $rex_b, 0xC7, 0xC0 | ( $did & 7 ) );
                                $bytes .= pack( 'V', $src->value );
                            }
                            elsif ( $rex_b ) {
                                $bytes .= pack( 'CCV', 0x41, 0xB8 + ( $did & 7 ), $src->value );
                            }
                            else {
                                $bytes .= pack( 'CV', 0xB8 + $did, $src->value );
                            }
                        }
                        else {
                            my $src_r = $resolve->($src);
                            my $sid   = $reg_id->($src_r);
                            my $rex_w = ( $bits >= 64 ) ? 0x08 : 0x00;
                            my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                            my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                            $bytes .= pack( 'CCC', $rex, 0x8B, $modrm );
                        }
                    }
                    elsif ( $opcode eq 'add' || $opcode eq 'sub' || $opcode eq 'and' || $opcode eq 'or' || $opcode eq 'xor' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        my %imm_ext = ( add => 0, sub => 5, and => 4, or => 1, xor => 6 );
                        my %reg_op  = ( add => 0x01, sub => 0x29, and => 0x21, or => 0x09, xor => 0x31 );
                        my $rex_w = ( $bits >= 64 ) ? 0x08 : 0x00;

                        if ( $src->kind eq 'imm' ) {
                            my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                            my $ext   = $imm_ext{$opcode};
                            my $modrm = 0xC0 | ( $ext << 3 ) | ( $did & 7 );
                            $bytes .= pack( 'CCCV', $rex, 0x81, $modrm, $src->value );
                        }
                        else {
                            my $src_r = $resolve->($src);
                            my $sid   = $reg_id->($src_r);
                            my $rex   = 0x40 | $rex_w | ( $sid >= 8 ? 4 : 0 ) | ( $did >= 8 ? 1 : 0 );
                            my $op    = $reg_op{$opcode};
                            my $modrm = 0xC0 | ( ( $sid & 7 ) << 3 ) | ( $did & 7 );
                            $bytes .= pack( 'CCC', $rex, $op, $modrm );
                        }
                    }
                    elsif ( $opcode eq 'mul' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        my $rex_w = ( $bits >= 64 ) ? 0x08 : 0x00;
                        if ( $src->kind eq 'imm' ) {
                            # imul dst, dst, imm32  => REX.W 69 /r
                            my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                            my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $did & 7 );
                            $bytes .= pack( 'CCCV', $rex, 0x69, $modrm, $src->value );
                        }
                        else {
                            my $src_r = $resolve->($src);
                            my $sid   = $reg_id->($src_r);
                            my $rex   = 0x40 | $rex_w | ( $sid >= 8 ? 4 : 0 ) | ( $did >= 8 ? 1 : 0 );
                            # imul dst, src  => REX.W 0F AF /r
                            my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                            $bytes .= pack( 'CCC', $rex, 0x0F, 0xAF ) . pack( 'C', $modrm );
                        }
                    }
                    elsif ( $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' ) {
                        my $dst_r  = $resolve->($dst);
                        my $did    = $reg_id->($dst_r);
                        my $bits   = $dst->type ? $dst->type->bits : 64;
                        my %ext    = ( shl => 4, lshr => 5, ashr => 7 );
                        my $rex_w  = ( $bits >= 64 ) ? 0x08 : 0x00;
                        my $rex    = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                        my $extval = $ext{$opcode};
                        if ( $src->kind eq 'imm' ) {
                            # shift by imm8: REX.W C1 /ext ib
                            my $modrm = 0xC0 | ( $extval << 3 ) | ( $did & 7 );
                            $bytes .= pack( 'CCCC', $rex, 0xC1, $modrm, $src->value );
                        }
                        else {
                            die "x86_64 shift by register requires CL" . ( $src->value // '' );
                        }
                    }
                    elsif ( $opcode eq 'alloca' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $size  = $src->value;
                        $total_frame += $size;
                        # sub rsp, size  (48 81 EC <size32>) — rsp is always 64-bit
                        my $rex   = 0x48;
                        my $modrm = 0xC0 | ( 5 << 3 ) | 4;    # /5 = sub, r/m = rsp
                        $bytes .= pack( 'CCCV', $rex, 0x81, $modrm, $size );
                        # mov dst, rsp  (48 8B <modrm>) — rsp is always 64-bit
                        my $rex2  = 0x48 | ( $did >= 8 ? 4 : 0 );
                        my $mr2   = 0xC0 | ( ( $did & 7 ) << 3 ) | 4;
                        $bytes .= pack( 'CCC', $rex2, 0x8B, $mr2 );
                    }
                    elsif ( $opcode eq 'load' ) {
                        my $dst_r  = $resolve->($dst);
                        my $did    = $reg_id->($dst_r);
                        my ( $modrm, $extra ) = $mem_modrm->( $src, $did );
                        my $bits   = ( $dst->type && $dst->type->kind eq 'int' ) ? $dst->type->bits : 64;
                        my $rex = ( $bits == 64 ? 0x48 : 0 ) | ( $did >= 8 ? 4 : 0 );
                        if ( $rex ) { $bytes .= pack( 'C', $rex ) }
                        $bytes .= pack( 'C', 0x8B ) . pack( 'C', $modrm );
                        $bytes .= join '', $extra->@*;
                    }
                    elsif ( $opcode eq 'store' ) {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my ( $modrm, $extra ) = $mem_modrm->( $dst, $sid );
                        my $bits = ($src->type && $src->type->kind eq 'int') ? $src->type->bits : 64;
                        my $rex = ( $bits == 64 ? 0x48 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                        if ( $rex ) { $bytes .= pack( 'C', $rex ) }
                        $bytes .= pack( 'C', 0x89 ) . pack( 'C', $modrm );
                        $bytes .= join '', $extra->@*;
                    }
                    elsif ( $opcode eq 'store_imm' ) {
                        my ( $mem, $imm ) = $inst->operands->@*;
                        my ( $modrm, $extra ) = $mem_modrm->( $mem, 0 );    # /0 ext = mov
                        my $bits = ($imm->type && $imm->type->kind eq 'int') ? $imm->type->bits : 64;
                        my $rex = ( $bits == 64 ? 0x48 : 0 );
                        if ( $rex ) { $bytes .= pack( 'C', $rex ) }
                        $bytes .= pack( 'C', 0xC7 ) . pack( 'C', $modrm );
                        $bytes .= join '', $extra->@*;
                        $bytes .= pack( 'V', $imm->value );
                    }
                    # SSE float opcodes
                    elsif ( $opcode eq 'fload' ) {
                        my $dst_r  = $resolve->($dst);
                        my $did    = $reg_id->($dst_r);
                        my ( $modrm, $extra ) = $mem_modrm->( $src, $did );
                        my $bits   = $dst->type ? $dst->type->bits : 32;
                        my $op     = $bits >= 64 ? [ 0xF2, 0x0F, 0x10 ] : [ 0xF3, 0x0F, 0x10 ];
                        my $rex    = 0x40 | ( $did >= 8 ? 4 : 0 );
                        if ( $rex > 0x40 ) { $bytes .= pack( 'C', $rex ) }
                        $bytes .= pack( 'CCC', $op->@* ) . pack( 'C', $modrm );
                        $bytes .= join '', $extra->@*;
                    }
                    elsif ( $opcode eq 'fstore' ) {
                        my $src_r  = $resolve->($src);
                        my $sid    = $reg_id->($src_r);
                        my ( $modrm, $extra ) = $mem_modrm->( $dst, $sid );
                        my $bits   = $src->type ? $src->type->bits : 32;
                        my $op     = $bits >= 64 ? [ 0xF2, 0x0F, 0x11 ] : [ 0xF3, 0x0F, 0x11 ];
                        my $rex    = 0x40 | ( $sid >= 8 ? 1 : 0 );
                        if ( $rex > 0x40 ) { $bytes .= pack( 'C', $rex ) }
                        $bytes .= pack( 'CCC', $op->@* ) . pack( 'C', $modrm );
                        $bytes .= join '', $extra->@*;
                    }
                    elsif ( $opcode eq 'fmov' ) {
                        my $dst_r = $resolve->($dst);
                        my $src_r = $resolve->($src);
                        my $did   = $reg_id->($dst_r);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 32;
                        my $op    = $bits >= 64 ? [ 0xF2, 0x0F, 0x10 ] : [ 0xF3, 0x0F, 0x10 ];
                        my $rex   = 0x40 | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                        $bytes .= pack( 'CCCC', $rex, $op->[0], $op->[1], $op->[2] ) . pack( 'C', $modrm );
                    }
                    elsif ( $opcode eq 'fmov_gp2f' ) {
                        my $dst_r = $resolve->($dst);
                        my $src_r = $resolve->($src);
                        my $did   = $reg_id->($dst_r);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 32;
                        my $rex = $bits >= 64 ? 0x48 : 0x40;
                        $rex |= ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                        $bytes .= pack( 'C', $rex ) if $rex > 0x40;
                        $bytes .= pack( 'CCC', 0x66, 0x0F, 0x6E ) . pack( 'C', $modrm );
                    }
                    elsif ( $opcode eq 'fadd' || $opcode eq 'fsub' || $opcode eq 'fmul' || $opcode eq 'fdiv' || $opcode eq 'fsqrt' || $opcode eq 'fmin' || $opcode eq 'fmax' ) {
                        my $dst_r = $resolve->($dst);
                        my $src_r = $resolve->($src);
                        my $did   = $reg_id->($dst_r);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 32;
                        my %ss_op = ( fadd => 0x58, fsub => 0x5C, fmul => 0x59, fdiv => 0x5E, fsqrt => 0x51, fmin => 0x5D, fmax => 0x5F );
                        my $op    = $bits >= 64 ? [ 0xF2, 0x0F, $ss_op{$opcode} ] : [ 0xF3, 0x0F, $ss_op{$opcode} ];
                        my $rex   = 0x40 | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                        $bytes .= pack( 'CCCC', $rex, $op->[0], $op->[1], $op->[2] ) . pack( 'C', $modrm );
                    }
                    elsif ( $opcode eq 'fxor' || $opcode eq 'fand' ) {
                        my $dst_r = $resolve->($dst);
                        my $src_r = $resolve->($src);
                        my $did   = $reg_id->($dst_r);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 32;
                        my %ss_op = ( fxor => 0x57, fand => 0x54 );
                        my $op    = $bits >= 64 ? [ 0x66, 0x0F, $ss_op{$opcode} ] : [ 0x0F, $ss_op{$opcode} ];
                        my $rex   = 0x40 | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                        if ($bits >= 64) {
                            $bytes .= pack( 'CCCC', $rex, $op->[0], $op->[1], $op->[2] ) . pack( 'C', $modrm );
                        }
                        else {
                            $bytes .= pack( 'CCC', $rex, $op->[0], $op->[1] ) . pack( 'C', $modrm );
                        }
                    }
                    elsif ( $opcode eq 'fcmp' ) {
                        my $dst_r = $resolve->($dst);
                        my $src_r = $resolve->($src);
                        my $did   = $reg_id->($dst_r);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 32;
                        my $op    = $bits >= 64 ? [ 0x66, 0x0F, 0x2E ] : [ 0x0F, 0x2E ];
                        my $rex   = 0x40 | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                        $bytes .= pack( 'C' x ( $bits >= 64 ? 4 : 3 ), $rex, $op->@* ) . pack( 'C', $modrm );
                    }
                    elsif ( $opcode eq 'label' ) {
                        $labels{ $dst->value } = $current_offset->();
                    }
                    elsif ( $opcode eq 'jmp' ) {
                        push @fixups, { offset => $current_offset->(), type => 'jmp_rel32', target => $dst->value, size => 5 };
                        $bytes .= pack( 'C', 0xE9 ) . "\x00\x00\x00\x00";
                    }
                    elsif ( $opcode eq 'beq' || $opcode eq 'bne' ) {
                        my $cond_r = $resolve->($dst);
                        my $cid    = $reg_id->($cond_r);
                        # cmp reg, 0: REX.W 83 /7 0  (4 bytes)
                        my $rex   = 0x48 | ( $cid >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( 7 << 3 ) | ( $cid & 7 );
                        $bytes .= pack( 'CCCC', $rex, 0x83, $modrm, 0 );
                        my $jcc = ( $opcode eq 'beq' ? 0x84 : 0x85 );
                        push @fixups, { offset => $current_offset->(), type => 'jcc_rel32', jcc => $jcc, target => $src->value, size => 6 };
                        $bytes .= pack( 'CC', 0x0F, $jcc ) . "\x00\x00\x00\x00";
                    }
                    elsif ( $opcode eq 'cmp' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        my $rex_w = ( $bits >= 64 ) ? 0x08 : 0x00;
                        if ( $src->kind eq 'imm' ) {
                            my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                            my $modrm = 0xC0 | ( 7 << 3 ) | ( $did & 7 );
                            $bytes .= pack( 'CCCV', $rex, 0x81, $modrm, $src->value );
                        }
                        else {
                            my $src_r = $resolve->($src);
                            my $sid   = $reg_id->($src_r);
                            my $rex   = 0x40 | $rex_w | ( $sid >= 8 ? 4 : 0 ) | ( $did >= 8 ? 1 : 0 );
                            my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                            $bytes .= pack( 'CCC', $rex, 0x3B, $modrm );
                        }
                    }
                    elsif ( $opcode eq 'sete' || $opcode eq 'setne' || $opcode eq 'setl' || $opcode eq 'setg' || $opcode eq 'setle' || $opcode eq 'setge' || $opcode eq 'setb' || $opcode eq 'seta' || $opcode eq 'setbe' || $opcode eq 'setae' || $opcode eq 'setp' || $opcode eq 'setnp' ) {
                        my %cc = ( sete => 0x94, setne => 0x95, setl => 0x9C, setg => 0x9F, setle => 0x9E, setge => 0x9D, setb => 0x92, seta => 0x97, setbe => 0x96, setae => 0x93, setp => 0x9A, setnp => 0x9B );
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $rex   = 0x40 | ( $did >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $did & 7 );
                        $bytes .= pack( 'CCC', $rex, 0x0F, $cc{$opcode} ) . pack( 'C', $modrm );
                    }
                    elsif ( $opcode eq 'ret' ) {
                        if ( $total_frame > 0 ) {
                            $bytes .= pack( 'CCCV', 0x48, 0x81, 0xC0 | ( 0 << 3 ) | 4, $total_frame );
                        }
                        for my $reg ( reverse $used_callee->@* ) {
                            my $rid = $reg_id->($reg);
                            if ( $rid < 8 ) { $bytes .= pack( 'C', 0x58 + $rid ) }
                            else            { $bytes .= pack( 'CC', 0x41, 0x58 + ( $rid - 8 ) ) }
                        }
                        $bytes .= pack( 'C', 0xC3 );
                    }
                }
            }
            for my $fixup ( @fixups ) {
                my $target_pos = $labels{ $fixup->{target} };
                die "undefined label: $fixup->{target}" unless defined $target_pos;
                my $src_pos = $fixup->{offset};
                my $rel = $target_pos - ( $src_pos + $fixup->{size} );
                if ( $fixup->{type} eq 'jmp_rel32' ) {
                    substr $bytes, $fixup->{offset} + 1, 4, pack( 'V', $rel & 0xFFFFFFFF );
                }
                elsif ( $fixup->{type} eq 'jcc_rel32' ) {
                    substr $bytes, $fixup->{offset} + 2, 4, pack( 'V', $rel & 0xFFFFFFFF );
                }
            }
            return $bytes;
        }
    }

    class Brocken::Jenny::Codegen::RISCV64 {
        field $platform : param = Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu');

        method emit_function($ir_func) {
            my $lowerer = Brocken::Jenny::Lowerer::RISCV64->new();
            my $mf      = $lowerer->lower($ir_func);
            my $alloc   = Brocken::Jenny::RegAlloc::LinearScan->new();
            my $int_res = $alloc->allocate( $mf, $platform, 0 );
            $alloc->insert_spill_code( $mf, $int_res->{spill_slots}, $int_res->{spill_temp}, $platform->stack_reg, 0 );
            my $fp_res = $alloc->allocate( $mf, $platform, 1 );
            $alloc->insert_spill_code( $mf, $fp_res->{spill_slots}, $fp_res->{spill_temp}, $platform->stack_reg, 1 );
            my %assignment = ( $int_res->{assignment}->%*, $fp_res->{assignment}->%* );
            my %callee_seen;
            @callee_seen{ $int_res->{used_callee}->@* } = ();
            @callee_seen{ $fp_res->{used_callee}->@* } = ();
            my @used_callee = sort keys %callee_seen;
            return $self->_encode( $mf, \%assignment, \@used_callee );
        }

        method _encode( $mf, $assignment, $used_callee ) {
            my $bytes        = '';
            my $total_frame  = 0;
            my $callee_frame = scalar($used_callee->@*) * 8;
            my $reg_id    = sub ($r) {
                my %map = (
                    zero => 0, ra => 1, sp => 2, gp => 3, tp => 4,
                    t0 => 5, t1 => 6, t2 => 7, s0 => 8, fp => 8, s1 => 9,
                    a0 => 10, a1 => 11, a2 => 12, a3 => 13, a4 => 14, a5 => 15,
                    a6 => 16, a7 => 17, s2 => 18, s3 => 19, s4 => 20, s5 => 21,
                    s6 => 22, s7 => 23, s8 => 24, s9 => 25, s10 => 26, s11 => 27,
                    t3 => 28, t4 => 29, t5 => 30, t6 => 31
                );
                return $map{$r} if exists $map{$r};
                return $1 if $r =~ /^x(\d+)$/;
                return $1 if $r =~ /^f(\d+)$/ && $1 <= 31;
                return 0;
            };

            my $resolve = sub ($op) {
                return $assignment->{ $op->value } if $op->kind eq 'virt_reg';
                return $op->value                  if $op->kind eq 'phys_reg';
                die "Unexpected operand kind: ${\$op->kind}";
            };

            if ( $callee_frame > 0 ) {
                my $neg = ( -$callee_frame ) & 0xFFF;
                $bytes .= pack( 'V', ( $neg << 20 ) | ( 2 << 15 ) | ( 0 << 12 ) | ( 2 << 7 ) | 0x13 );
                for my $i ( 0 .. $used_callee->$#* ) {
                    my $rid    = $reg_id->( $used_callee->[$i] );
                    my $off    = $i * 8;
                    my $imm_lo = $off & 0x1F;
                    my $imm_hi = ( $off >> 5 ) & 0x7F;
                    $bytes .= pack( 'V', ( $imm_hi << 25 ) | ( $rid << 20 ) | ( 2 << 15 ) | ( 3 << 12 ) | ( $imm_lo << 7 ) | 0x23 );
                }
            }

            my %labels;
            my @fixups;
            my $current_offset = sub { return length $bytes };
            for my $mbb ( $mf->blocks->@* ) {
                for my $inst ( $mbb->instructions->@* ) {
                    my $opcode   = $inst->opcode;
                    my ( $dst, $src ) = $inst->operands->@*;

                    if ( $opcode eq 'label' ) {
                        $labels{ $dst->value } = $current_offset->();
                    }
                    elsif ( $opcode eq 'jmp' ) {
                        push @fixups, { offset => $current_offset->(), type => 'jal', target => $dst->value };
                        $bytes .= pack( 'V', 0x0000006F );
                    }
                    elsif ( $opcode eq 'beq' || $opcode eq 'bne' ) {
                        my $cond_r = $resolve->($dst);
                        my $cid    = $reg_id->($cond_r);
                        my $funct3 = ( $opcode eq 'bne' ? 1 : 0 );
                        # BEQ/BNE rs1=cond, rs2=x0, offset placeholder
                        push @fixups, { offset => $current_offset->(), type => 'bcc', target => $src->value, rs1 => $cid, funct3 => $funct3 };
                        $bytes .= pack( 'V', ( $cid << 15 ) | ( $funct3 << 12 ) | 0x63 );
                    }
                    elsif ( $opcode eq 'mv' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);

                        if ( $src->kind eq 'imm' ) {
                            # li rd, imm (addi rd, zero, imm)
                            my $imm = $src->value & 0xFFF;
                            $bytes .= pack( 'V', ( $imm << 20 ) | ( 0 << 15 ) | ( 0 << 12 ) | ( $did << 7 ) | 0x13 );
                        }
                        else {
                            my $src_r = $resolve->($src);
                            my $sid   = $reg_id->($src_r);
                            # mv rd, rs (addi rd, rs, 0)
                            $bytes .= pack( 'V', ( 0 << 20 ) | ( $sid << 15 ) | ( 0 << 12 ) | ( $did << 7 ) | 0x13 );
                        }
                    }
                    elsif ( $opcode eq 'add' || $opcode eq 'sub' || $opcode eq 'and' || $opcode eq 'or' || $opcode eq 'xor' || $opcode eq 'mul' || $opcode eq 'div' || $opcode eq 'slt' || $opcode eq 'sltu' || $opcode eq 'sltiu' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my %imm_f3 = ( add => 0, sub => 0, and => 7, or => 6, xor => 4, slt => 2, sltu => 3, sltiu => 3 );
                        my %reg_f7 = ( add => 0x00, sub => 0x20, mul => 0x01, div => 0x01, and => 0x00, or => 0x00, xor => 0x00, slt => 0x00, sltu => 0x00 );
                        my %reg_f3 = ( add => 0, sub => 0, mul => 0, div => 0, and => 7, or => 6, xor => 4, slt => 2, sltu => 3, sltiu => 3 );

                        if ( $src->kind eq 'imm' && exists $imm_f3{$opcode} ) {
                            # I-type: opcode 0x13, funct3 from %imm_f3
                            my $imm = $src->value;
                            $imm = -$imm if $opcode eq 'sub';
                            $imm &= 0xFFF;
                            $bytes .= pack( 'V', ( $imm << 20 ) | ( $did << 15 ) | ( $imm_f3{$opcode} << 12 ) | ( $did << 7 ) | 0x13 );
                        }
                        else {
                            my $src_r = $resolve->($src);
                            my $sid   = $reg_id->($src_r);
                            $bytes .= pack( 'V', ( $reg_f7{$opcode} << 25 ) | ( $sid << 20 ) | ( $did << 15 ) | ( $reg_f3{$opcode} << 12 ) | ( $did << 7 ) | 0x33 );
                        }
                    }
                    elsif ( $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        if ( $src->kind eq 'imm' ) {
                            # I-type shift: SLLI/SRLI/SRAI, funct3=1/5/5, opcode=0x13
                            my $shamt = $src->value;
                            my %f3 = ( shl => 1, lshr => 5, ashr => 5 );
                            my $extra = ( $opcode eq 'ashr' ? 0x40000000 : 0x00000000 );
                            $bytes .= pack( 'V', $extra | ( $shamt << 20 ) | ( $did << 15 ) | ( $f3{$opcode} << 12 ) | ( $did << 7 ) | 0x13 );
                        }
                        else {
                            # R-type shift: SLL/SRL/SRA, funct7=0x00/0x00/0x20, funct3=1/5/5
                            my $src_r = $resolve->($src);
                            my $sid   = $reg_id->($src_r);
                            my %f3 = ( shl => 1, lshr => 5, ashr => 5 );
                            my %f7 = ( shl => 0x00, lshr => 0x00, ashr => 0x20 );
                            $bytes .= pack( 'V', ( $f7{$opcode} << 25 ) | ( $sid << 20 ) | ( $did << 15 ) | ( $f3{$opcode} << 12 ) | ( $did << 7 ) | 0x33 );
                        }
                    }
                    elsif ( $opcode eq 'alloca' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $size  = $src->value;
                        $total_frame += $size;
                        # addi sp, sp, -size
                        my $neg_size = ( -$size ) & 0xFFF;
                        $bytes .= pack( 'V', ( $neg_size << 20 ) | ( 2 << 15 ) | ( 0 << 12 ) | ( 2 << 7 ) | 0x13 );
                        # addi xd, sp, 0
                        $bytes .= pack( 'V', ( 0 << 20 ) | ( 2 << 15 ) | ( 0 << 12 ) | ( $did << 7 ) | 0x13 );
                    }
                    elsif ( $opcode eq 'load' ) {
                        my $dst_r  = $resolve->($dst);
                        my $did    = $reg_id->($dst_r);
                        my $addr   = $src->value;
                        my $base_r = $resolve->(
                            Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} )
                        );
                        my $bid    = $reg_id->($base_r);
                        my $disp   = $addr->{disp} // 0;
                        my $bits   = ($dst->type && $dst->type->kind eq 'int') ? $dst->type->bits : 64;
                        my $funct3 = $bits == 32 ? 2 : 3;
                        $bytes .= pack( 'V', ( ( $disp & 0xFFF ) << 20 ) | ( $bid << 15 ) | ( $funct3 << 12 ) | ( $did << 7 ) | 0x03 );
                    }
                    elsif ( $opcode eq 'store' ) {
                        my $src_r  = $resolve->($src);
                        my $sid    = $reg_id->($src_r);
                        my $addr   = $dst->value;
                        my $base_r = $resolve->(
                            Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} )
                        );
                        my $bid    = $reg_id->($base_r);
                        my $disp   = $addr->{disp} // 0;
                        my $bits   = ($src->type && $src->type->kind eq 'int') ? $src->type->bits : 64;
                        my $funct3 = $bits == 32 ? 2 : 3;
                        my $imm_lo = $disp & 0x1F;
                        my $imm_hi = ( $disp >> 5 ) & 0x7F;
                        $bytes .= pack( 'V', ( $imm_hi << 25 ) | ( $sid << 20 ) | ( $bid << 15 ) | ( $funct3 << 12 ) | ( $imm_lo << 7 ) | 0x23 );
                    }
                    elsif ( $opcode eq 'store_imm' ) {
                        my ($mem, $imm) = $inst->operands->@*;
                        my $addr   = $mem->value;
                        my $base_r = $resolve->(
                            Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} )
                        );
                        my $bid    = $reg_id->($base_r);
                        my $disp   = $addr->{disp} // 0;
                        my $bits   = ($imm->type && $imm->type->kind eq 'int') ? $imm->type->bits : 64;
                        my $funct3 = $bits == 32 ? 2 : 3;
                        # find a temporary register not in use
                        my %used;
                        @used{ values %$assignment } = ();
                        my $tmp_r;
                        for my $r ( $platform->registers('caller')->@* ) { $tmp_r = $r, last unless exists $used{$r} }
                        die 'no temp register for store_imm' unless $tmp_r;
                        my $tid = $reg_id->($tmp_r);
                        # li xtmp, imm  (addi xtmp, zero, imm12)
                        my $im = $imm->value & 0xFFF;
                        $bytes .= pack( 'V', ( $im << 20 ) | ( 0 << 15 ) | ( 0 << 12 ) | ( $tid << 7 ) | 0x13 );
                        # sd/sw xtmp, disp(rs1)
                        my $imm_lo = $disp & 0x1F;
                        my $imm_hi = ( $disp >> 5 ) & 0x7F;
                        $bytes .= pack( 'V', ( $imm_hi << 25 ) | ( $tid << 20 ) | ( $bid << 15 ) | ( $funct3 << 12 ) | ( $imm_lo << 7 ) | 0x23 );
                    }
                    elsif ( $opcode eq 'fload' ) {
                        my $dst_r  = $resolve->($dst);
                        my $did    = $reg_id->($dst_r);
                        my $addr   = $src->value;
                        my $base_r = $resolve->(
                            Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} )
                        );
                        my $bid    = $reg_id->($base_r);
                        my $disp   = $addr->{disp} // 0;
                        my $funct3 = ($dst->type && $dst->type->bits <= 32) ? 2 : 3;
                        $bytes .= pack( 'V', ( ( $disp & 0xFFF ) << 20 ) | ( $bid << 15 ) | ( $funct3 << 12 ) | ( $did << 7 ) | 0x07 );
                    }
                    elsif ( $opcode eq 'fstore' ) {
                        my $src_r  = $resolve->($src);
                        my $sid    = $reg_id->($src_r);
                        my $addr   = $dst->value;
                        my $base_r = $resolve->(
                            Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} )
                        );
                        my $bid    = $reg_id->($base_r);
                        my $disp   = $addr->{disp} // 0;
                        my $funct3 = ($src->type && $src->type->bits <= 32) ? 2 : 3;
                        my $imm_lo = $disp & 0x1F;
                        my $imm_hi = ( $disp >> 5 ) & 0x7F;
                        $bytes .= pack( 'V', ( $imm_hi << 25 ) | ( $sid << 20 ) | ( $bid << 15 ) | ( $funct3 << 12 ) | ( $imm_lo << 7 ) | 0x27 );
                    }
                    elsif ( $opcode eq 'fmov' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        if ( $bits <= 32 ) {
                            # fmv.s = fsgnj.s rd, rs1, rs1: funct5=00100, fmt=00, rm=000
                            $bytes .= pack( 'V', 0x20000000 | ( $sid << 20 ) | ( $sid << 15 ) | ( $did << 7 ) | 0x53 );
                        }
                        else {
                            # fmv.d = fsgnj.d rd, rs1, rs1: funct5=00100, fmt=01, rm=000
                            $bytes .= pack( 'V', 0x22000000 | ( $sid << 20 ) | ( $sid << 15 ) | ( $did << 7 ) | 0x53 );
                        }
                    }
                    elsif ( $opcode eq 'fmov_gp2f' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        if ( $bits <= 32 ) {
                            # fmv.w.x: funct5=11110, fmt=00, rs2=0, rm=000
                            $bytes .= pack( 'V', 0xF0000000 | ( $sid << 15 ) | ( $did << 7 ) | 0x53 );
                        }
                        else {
                            # fmv.d.x: funct5=11110, fmt=01, rs2=0, rm=000
                            $bytes .= pack( 'V', 0xF2000000 | ( $sid << 15 ) | ( $did << 7 ) | 0x53 );
                        }
                    }
                    elsif ( $opcode eq 'fadd' || $opcode eq 'fsub' || $opcode eq 'fmul' || $opcode eq 'fdiv' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        my %fop5 = ( fadd => 0x00, fsub => 0x01, fmul => 0x02, fdiv => 0x03 );
                        my $funct5 = $fop5{$opcode};
                        my $enc = ( $funct5 << 27 ) | ( $sid << 20 ) | ( $did << 15 ) | ( $did << 7 ) | 0x53;
                        $enc |= ( 1 << 25 ) if $bits > 32;
                        $bytes .= pack( 'V', $enc );
                    }
                    elsif ( $opcode eq 'fneg' || $opcode eq 'fabs' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        # fsgnjn.s (fneg): funct5=00100, rm=001
                        # fsgnjx.s (fabs): funct5=00100, rm=010
                        my $rm = $opcode eq 'fneg' ? 1 : 2;
                        my $enc = 0x20000000 | ( $sid << 20 ) | ( $sid << 15 ) | ( $rm << 12 ) | ( $did << 7 ) | 0x53;
                        $enc |= ( 1 << 25 ) if $bits > 32;
                        $bytes .= pack( 'V', $enc );
                    }
                    elsif ( $opcode eq 'fmin' || $opcode eq 'fmax' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        # fmin.s: funct5=00101, rm=000
                        # fmax.s: funct5=00101, rm=001
                        my $rm = $opcode eq 'fmin' ? 0 : 1;
                        my $enc = 0x28000000 | ( $sid << 20 ) | ( $did << 15 ) | ( $rm << 12 ) | ( $did << 7 ) | 0x53;
                        $enc |= ( 1 << 25 ) if $bits > 32;
                        $bytes .= pack( 'V', $enc );
                    }
                    elsif ( $opcode eq 'fsqrt' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        # fsqrt.s: funct5=01011, fmt=00, rs2=0, rm=000
                        my $enc = 0x58000000 | ( $sid << 15 ) | ( $did << 7 ) | 0x53;
                        $enc |= ( 1 << 25 ) if $bits > 32;
                        $bytes .= pack( 'V', $enc );
                    }
                    elsif ( $opcode eq 'ret' ) {
                        if ( $total_frame > 0 ) {
                            $bytes .= pack( 'V', ( ( $total_frame & 0xFFF ) << 20 ) | ( 2 << 15 ) | ( 0 << 12 ) | ( 2 << 7 ) | 0x13 );
                        }
                        if ( $callee_frame > 0 ) {
                            for my $i ( reverse 0 .. $used_callee->$#* ) {
                                my $rid    = $reg_id->( $used_callee->[$i] );
                                my $off    = $i * 8;
                                $bytes .= pack( 'V', ( ( $off & 0xFFF ) << 20 ) | ( 2 << 15 ) | ( 3 << 12 ) | ( $rid << 7 ) | 0x03 );
                            }
                            $bytes .= pack( 'V', ( ( $callee_frame & 0xFFF ) << 20 ) | ( 2 << 15 ) | ( 0 << 12 ) | ( 2 << 7 ) | 0x13 );
                        }
                        $bytes .= pack( 'V', 0x00008067 );
                    }
                }
            }
            for my $fixup ( @fixups ) {
                my $target_pos = $labels{ $fixup->{target} };
                die "undefined label: $fixup->{target}" unless defined $target_pos;
                my $rel = $target_pos - ( $fixup->{offset} + 4 );
                if ( $fixup->{type} eq 'jal' ) {
                    my $imm20 = ( $rel >> 1 ) & 0x1FFFFF;
                    my $enc = ( ( $imm20 >> 20 ) & 1 ) << 31
                            | ( ( $imm20 & 0x7FE ) << 20 )
                            | ( ( $imm20 >> 11 ) & 1 ) << 20
                            | ( $imm20 & 0xFF000 )
                            | 0x6F;
                    substr $bytes, $fixup->{offset}, 4, pack( 'V', $enc );
                }
                elsif ( $fixup->{type} eq 'bcc' ) {
                    my $imm13 = ( $rel >> 1 ) & 0x1FFF;
                    my $enc = ( ( $imm13 >> 12 ) & 1 ) << 31
                            | ( ( $imm13 >> 5 ) & 0x3F ) << 25
                            | ( $fixup->{rs1} << 15 )
                            | ( $fixup->{funct3} << 12 )
                            | ( ( $imm13 & 0x1E ) << 7 )
                            | ( ( $imm13 >> 11 ) & 1 ) << 7
                            | 0x63;
                    substr $bytes, $fixup->{offset}, 4, pack( 'V', $enc );
                }
            }
            return $bytes;
        }
    }

    class Brocken::Jenny::Codegen::Wasm {
        field $platform : param = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');

        method emit_function($ir_func) {
            my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
            my $mf      = $lowerer->lower($ir_func);
            my %ir_types;
            for my $block ($ir_func->blocks->@*) {
                for my $inst ($block->instructions->@*) {
                    $ir_types{$inst->name} = $inst->type if $inst->name;
                }
            }
            return $self->_encode( $mf, $ir_func->params, \%ir_types, $ir_func->return_type );
        }

        method _encode( $mf, $ir_params, $ir_types, $return_type ) {
            my $bytes      = '';
            my %vreg_map   = ();
            my $next_local = scalar( $ir_params->@* );

            # Map parameters to locals 0..N-1
            for my $i ( 0 .. ( $next_local - 1 ) ) {
                $vreg_map{ $ir_params->[$i]->name } = $i;
            }

            # Reserve a local for the linear-memory heap bump pointer
            $vreg_map{'%heap_ptr'} = $next_local++;

            my @blocks = $mf->blocks->@*;
            my %label_to_block_idx;
            for my $bi ( 0 .. $#blocks ) {
                for my $inst ( $blocks[$bi]->instructions->@* ) {
                    $label_to_block_idx{ $inst->operands->[0]->value } = $bi if $inst->opcode eq 'label';
                }
            }
            my $num_non_entry = $#blocks;
            my $entry_bytes   = '';
            my @non_entry_bytes;

            for my $bi ( 0 .. $#blocks ) {
                my $mbb = $blocks[$bi];
                my $buf = $bi == 0 ? \$entry_bytes : \( $non_entry_bytes[ $bi - 1 ] = '' );
                for my $inst ( $mbb->instructions->@* ) {
                    next if $bi > 0 && $inst->opcode eq 'label';
                    my $opcode = $inst->opcode;
                    my @ops    = $inst->operands->@*;
                    print STDERR ">>> ENCODE block=$bi op=$opcode ops=" . join(',', map { ($_->value // 'undef') . '(' . ($_->kind // '?') . ')' } @ops) . "\n";

                    if ( $opcode eq 'bne' ) {
                        my $depth = $num_non_entry - $label_to_block_idx{ $ops[0]->value };
                        $$buf .= pack( 'C', 0x0D ) . $self->_uleb($depth);
                    }
                    elsif ( $opcode eq 'jmp' ) {
                        my $depth = $num_non_entry - $label_to_block_idx{ $ops[0]->value };
                        $$buf .= pack( 'C', 0x0C ) . $self->_uleb($depth);
                    }
                    elsif ( $opcode eq 'local_get' ) {
                        my $lid = $vreg_map{ $ops[0]->value } //= $next_local++;
                        $$buf .= pack( 'C', 0x20 ) . $self->_uleb($lid);
                    }
                    elsif ( $opcode eq 'i32_const' ) {
                        $$buf .= pack( 'C', 0x41 ) . $self->_sleb( $ops[0]->value );
                    }
                    elsif ( $opcode eq 'i64_const' ) {
                        $$buf .= pack( 'C', 0x42 ) . $self->_sleb( $ops[0]->value );
                    }
                    elsif ( $opcode eq 'f32_const' ) {
                        print STDERR ">>> f32_const value=" . $ops[0]->value . " hex=" . unpack('H*', pack('f', $ops[0]->value)) . "\n";
                        $$buf .= pack( 'C', 0x43 ) . pack( 'f', $ops[0]->value );
                    }
                    elsif ( $opcode eq 'f64_const' ) {
                        $$buf .= pack( 'C', 0x44 ) . pack( 'd', $ops[0]->value );
                    }
                    elsif ( $opcode eq 'i32_add' )   { $$buf .= pack( 'C', 0x6A ) }
                    elsif ( $opcode eq 'i32_sub' )   { $$buf .= pack( 'C', 0x6B ) }
                    elsif ( $opcode eq 'i32_mul' )   { $$buf .= pack( 'C', 0x6C ) }
                    elsif ( $opcode eq 'i32_and' )   { $$buf .= pack( 'C', 0x71 ) }
                    elsif ( $opcode eq 'i32_or' )    { $$buf .= pack( 'C', 0x72 ) }
                    elsif ( $opcode eq 'i32_xor' )   { $$buf .= pack( 'C', 0x73 ) }
                    elsif ( $opcode eq 'i32_shl' )   { $$buf .= pack( 'C', 0x74 ) }
                    elsif ( $opcode eq 'i32_shr_s' ) { $$buf .= pack( 'C', 0x75 ) }
                    elsif ( $opcode eq 'i32_shr_u' ) { $$buf .= pack( 'C', 0x76 ) }
                    elsif ( $opcode eq 'i64_add' )   { $$buf .= pack( 'C', 0x7C ) }
                    elsif ( $opcode eq 'i64_sub' )   { $$buf .= pack( 'C', 0x7D ) }
                    elsif ( $opcode eq 'i64_mul' )   { $$buf .= pack( 'C', 0x7E ) }
                    elsif ( $opcode eq 'i64_and' )   { $$buf .= pack( 'C', 0x83 ) }
                    elsif ( $opcode eq 'i64_or' )    { $$buf .= pack( 'C', 0x84 ) }
                    elsif ( $opcode eq 'i64_xor' )   { $$buf .= pack( 'C', 0x85 ) }
                    elsif ( $opcode eq 'i64_shl' )   { $$buf .= pack( 'C', 0x86 ) }
                    elsif ( $opcode eq 'i64_shr_s' ) { $$buf .= pack( 'C', 0x87 ) }
                    elsif ( $opcode eq 'i64_shr_u' ) { $$buf .= pack( 'C', 0x88 ) }
                    elsif ( $opcode eq 'i32_load' ) {
                        $$buf .= pack( 'C', 0x28 ) . $self->_uleb(2) . $self->_uleb(0);
                    }
                    elsif ( $opcode eq 'i64_load' ) {
                        $$buf .= pack( 'C', 0x29 ) . $self->_uleb(3) . $self->_uleb(0);
                    }
                    elsif ( $opcode eq 'i32_store' ) {
                        $$buf .= pack( 'C', 0x36 ) . $self->_uleb(2) . $self->_uleb(0);
                    }
                    elsif ( $opcode eq 'i64_store' ) {
                        $$buf .= pack( 'C', 0x37 ) . $self->_uleb(3) . $self->_uleb(0);
                    }
                    elsif ( $opcode eq 'i32_eq' )   { $$buf .= pack( 'C', 0x46 ) }
                    elsif ( $opcode eq 'i32_ne' )   { $$buf .= pack( 'C', 0x47 ) }
                    elsif ( $opcode eq 'i32_lt_s' ) { $$buf .= pack( 'C', 0x48 ) }
                    elsif ( $opcode eq 'i32_gt_s' ) { $$buf .= pack( 'C', 0x4A ) }
                    elsif ( $opcode eq 'i32_le_s' ) { $$buf .= pack( 'C', 0x4C ) }
                    elsif ( $opcode eq 'i32_ge_s' ) { $$buf .= pack( 'C', 0x4E ) }
                    elsif ( $opcode eq 'i32_lt_u' ) { $$buf .= pack( 'C', 0x49 ) }
                    elsif ( $opcode eq 'i32_gt_u' ) { $$buf .= pack( 'C', 0x4B ) }
                    elsif ( $opcode eq 'i32_le_u' ) { $$buf .= pack( 'C', 0x4D ) }
                    elsif ( $opcode eq 'i32_ge_u' ) { $$buf .= pack( 'C', 0x4F ) }
                    elsif ( $opcode eq 'i64_eq' )   { $$buf .= pack( 'C', 0x51 ) }
                    elsif ( $opcode eq 'i64_ne' )   { $$buf .= pack( 'C', 0x52 ) }
                    elsif ( $opcode eq 'i64_lt_s' ) { $$buf .= pack( 'C', 0x53 ) }
                    elsif ( $opcode eq 'i64_gt_s' ) { $$buf .= pack( 'C', 0x55 ) }
                    elsif ( $opcode eq 'i64_le_s' ) { $$buf .= pack( 'C', 0x57 ) }
                    elsif ( $opcode eq 'i64_ge_s' ) { $$buf .= pack( 'C', 0x59 ) }
                    elsif ( $opcode eq 'i64_lt_u' ) { $$buf .= pack( 'C', 0x54 ) }
                    elsif ( $opcode eq 'i64_gt_u' ) { $$buf .= pack( 'C', 0x56 ) }
                    elsif ( $opcode eq 'i64_le_u' ) { $$buf .= pack( 'C', 0x58 ) }
                    elsif ( $opcode eq 'i64_ge_u' ) { $$buf .= pack( 'C', 0x5A ) }
                    elsif ( $opcode eq 'f32_load' ) {
                        $$buf .= pack( 'C', 0x2A ) . $self->_uleb(2) . $self->_uleb(0);
                    }
                    elsif ( $opcode eq 'f64_load' ) {
                        $$buf .= pack( 'C', 0x2B ) . $self->_uleb(3) . $self->_uleb(0);
                    }
                    elsif ( $opcode eq 'f32_store' ) {
                        $$buf .= pack( 'C', 0x3A ) . $self->_uleb(2) . $self->_uleb(0);
                    }
                    elsif ( $opcode eq 'f64_store' ) {
                        $$buf .= pack( 'C', 0x3B ) . $self->_uleb(3) . $self->_uleb(0);
                    }
                    elsif ( $opcode eq 'f32_add' )   { $$buf .= pack( 'C', 0x92 ) }
                    elsif ( $opcode eq 'f32_sub' )   { $$buf .= pack( 'C', 0x93 ) }
                    elsif ( $opcode eq 'f32_mul' )   { $$buf .= pack( 'C', 0x94 ) }
                    elsif ( $opcode eq 'f32_div' )   { $$buf .= pack( 'C', 0x95 ) }
                    elsif ( $opcode eq 'f32_min' )   { $$buf .= pack( 'C', 0x96 ) }
                    elsif ( $opcode eq 'f32_max' )   { $$buf .= pack( 'C', 0x97 ) }
                    elsif ( $opcode eq 'f32_abs' )   { $$buf .= pack( 'C', 0x8B ) }
                    elsif ( $opcode eq 'f32_neg' )   { $$buf .= pack( 'C', 0x8C ) }
                    elsif ( $opcode eq 'f32_sqrt' )  { $$buf .= pack( 'C', 0x91 ) }
                    elsif ( $opcode eq 'f64_add' )   { $$buf .= pack( 'C', 0xA0 ) }
                    elsif ( $opcode eq 'f64_sub' )   { $$buf .= pack( 'C', 0xA1 ) }
                    elsif ( $opcode eq 'f64_mul' )   { $$buf .= pack( 'C', 0xA2 ) }
                    elsif ( $opcode eq 'f64_div' )   { $$buf .= pack( 'C', 0xA3 ) }
                    elsif ( $opcode eq 'f64_min' )   { $$buf .= pack( 'C', 0xA4 ) }
                    elsif ( $opcode eq 'f64_max' )   { $$buf .= pack( 'C', 0xA5 ) }
                    elsif ( $opcode eq 'f64_abs' )   { $$buf .= pack( 'C', 0x99 ) }
                    elsif ( $opcode eq 'f64_neg' )   { $$buf .= pack( 'C', 0x9A ) }
                    elsif ( $opcode eq 'f64_sqrt' )  { $$buf .= pack( 'C', 0x9F ) }
                    elsif ( $opcode eq 'f32_eq' )   { $$buf .= pack( 'C', 0x5B ) }
                    elsif ( $opcode eq 'f32_ne' )   { $$buf .= pack( 'C', 0x5C ) }
                    elsif ( $opcode eq 'f32_lt' )   { $$buf .= pack( 'C', 0x5D ) }
                    elsif ( $opcode eq 'f32_gt' )   { $$buf .= pack( 'C', 0x5E ) }
                    elsif ( $opcode eq 'f32_le' )   { $$buf .= pack( 'C', 0x5F ) }
                    elsif ( $opcode eq 'f32_ge' )   { $$buf .= pack( 'C', 0x60 ) }
                    elsif ( $opcode eq 'f64_eq' )   { $$buf .= pack( 'C', 0x61 ) }
                    elsif ( $opcode eq 'f64_ne' )   { $$buf .= pack( 'C', 0x62 ) }
                    elsif ( $opcode eq 'f64_lt' )   { $$buf .= pack( 'C', 0x63 ) }
                    elsif ( $opcode eq 'f64_gt' )   { $$buf .= pack( 'C', 0x64 ) }
                    elsif ( $opcode eq 'f64_le' )   { $$buf .= pack( 'C', 0x65 ) }
                    elsif ( $opcode eq 'f64_ge' )   { $$buf .= pack( 'C', 0x66 ) }
                    elsif ( $opcode eq 'ret' ) {
                        $$buf .= pack( 'C', 0x0F );
                    }
                    elsif ( $opcode eq 'local_set' ) {
                        my $lid = $vreg_map{ $ops[0]->value } //= $next_local++;
                        $$buf .= pack( 'C', 0x21 ) . $self->_uleb($lid);
                    }
                }
            }

            # Open nested blocks (outermost first).  br N targets N levels out;
            # after the matching `end`, control continues.  So each block's
            # body must come *after* that block's `end`, not before it.
            for my $bi ( 1 .. $num_non_entry ) {
                $bytes .= pack( 'C', 0x02 ) . pack( 'C', 0x40 );
            }
            $bytes .= $entry_bytes;
            # Close innermost first, emitting each block's code *after* its end
            for my $bi ( reverse 1 .. $num_non_entry ) {
                $bytes .= pack( 'C', 0x0B );
                $bytes .= $non_entry_bytes[ $bi - 1 ];
            }

            my $num_params       = scalar( $ir_params->@* );
            my $num_extra_locals = $next_local - $num_params;
            my $locals_block     = '';
            if ( $num_extra_locals > 0 ) {
                # Build reverse mapping: local_id => vreg name
                my %lid_to_name = reverse %vreg_map;
                # Scan locals sequentially and group consecutive same-type
                my @groups;
                my $prev_wt;
                for my $lid ( $num_params .. $next_local - 1 ) {
                    my $name  = $lid_to_name{$lid} // '';
                    my $itype = $name ? $ir_types->{$name} : undef;
                    my $wt    = $itype ? $self->_wasm_valtype($itype) : 0x7F;
                    if ( !defined $prev_wt || $wt ne $prev_wt ) {
                        push @groups, [ $wt, 0 ];
                        $prev_wt = $wt;
                    }
                    $groups[-1][1]++;
                }
                my $num_groups = scalar @groups;
                $locals_block = $self->_uleb($num_groups);
                for my $g (@groups) {
                    $locals_block .= $self->_uleb( $g->[1] ) . pack( 'C', $g->[0] );
                }
            }
            else {
                $locals_block = $self->_uleb(0);
            }
            my $ret_valtype = $return_type ? $self->_wasm_valtype($return_type) : 0x7F;
            return { body => $bytes . pack( 'C', 0x0B ), locals => $locals_block, num_locals => $next_local, return_valtype => $ret_valtype };
        }

        method _wasm_valtype($ir_type) {
            return 0x7F if $ir_type->kind eq 'int' && $ir_type->bits <= 32;    # i32
            return 0x7E if $ir_type->kind eq 'int' && $ir_type->bits == 64;    # i64
            return 0x7D if $ir_type->kind eq 'float' && $ir_type->bits <= 32;  # f32
            return 0x7C if $ir_type->kind eq 'float' && $ir_type->bits >= 64;  # f64
            return 0x7F;                                                        # default i32
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
    }

    class Brocken::Jenny::Codegen::ARM64 {
        field $platform : param = Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu');

        method emit_function($ir_func) {
            my $lowerer = Brocken::Jenny::Lowerer::ARM64->new();
            my $mf      = $lowerer->lower($ir_func);
            my $alloc   = Brocken::Jenny::RegAlloc::LinearScan->new();
            my $int_res = $alloc->allocate( $mf, $platform, 0 );
            $alloc->insert_spill_code( $mf, $int_res->{spill_slots}, $int_res->{spill_temp}, $platform->stack_reg, 0 );
            my $fp_res = $alloc->allocate( $mf, $platform, 1 );
            $alloc->insert_spill_code( $mf, $fp_res->{spill_slots}, $fp_res->{spill_temp}, $platform->stack_reg, 1 );
            my %assignment = ( $int_res->{assignment}->%*, $fp_res->{assignment}->%* );
            my %callee_seen;
            @callee_seen{ $int_res->{used_callee}->@* } = ();
            @callee_seen{ $fp_res->{used_callee}->@* } = ();
            my @used_callee = sort keys %callee_seen;
            return $self->_encode( $mf, \%assignment, \@used_callee );
        }

        method _encode( $mf, $assignment, $used_callee ) {
            my $bytes        = '';
            my $total_frame  = 0;
            my $callee_frame = scalar($used_callee->@*) * 8;
            my $reg_id    = sub ($r) {
                return 31 if $r eq 'sp';
                return $1 if $r =~ /^[xw](\d+)$/;
                return $1 if $r =~ /^v(\d+)$/;
                return 0;
            };

            my $resolve = sub ($op) {
                return $assignment->{ $op->value } if $op->kind eq 'virt_reg';
                return $op->value                  if $op->kind eq 'phys_reg';
                die "Unexpected operand kind: ${\$op->kind}";
            };

            if ( $callee_frame > 0 ) {
                my $call_stk = ( ( $callee_frame + 15 ) & ~15 );
                $bytes .= pack( 'V', 0xD10003FF | ( ( $call_stk & 0xFFF ) << 10 ) );
                for my $i ( 0 .. $used_callee->$#* ) {
                    my $reg = $used_callee->[$i];
                    my $rid = $reg_id->($reg);
                    my $base = $reg =~ /^v/ ? 0xFD000000 : 0xF9000000;
                    $bytes .= pack( 'V', $base | ( $i << 10 ) | ( 31 << 5 ) | $rid );
                }
            }

            my %labels;
            my @fixups;
            my $current_offset = sub { return length $bytes };
            for my $mbb ( $mf->blocks->@* ) {
                for my $inst ( $mbb->instructions->@* ) {
                    my $opcode   = $inst->opcode;
                    my ( $dst, $src ) = $inst->operands->@*;

                    if ( $opcode eq 'label' ) {
                        $labels{ $dst->value } = $current_offset->();
                    }
                    elsif ( $opcode eq 'jmp' ) {
                        push @fixups, { offset => $current_offset->(), type => 'b', target => $dst->value };
                        $bytes .= pack( 'V', 0x14000000 );
                    }
                    elsif ( $opcode eq 'beq' || $opcode eq 'bne' ) {
                        my $cond_r = $resolve->($dst);
                        my $cid    = $reg_id->($cond_r);
                        my $base   = ( $opcode eq 'bne' ? 0xB5000000 : 0xB4000000 );
                        push @fixups, { offset => $current_offset->(), type => 'cbz', target => $src->value, rid => $cid, base => $base };
                        $bytes .= pack( 'V', $base | $cid );
                    }
                    elsif ( $opcode eq 'mov' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);

                        if ( $src->kind eq 'imm' ) {
                            my $bits = $dst->type ? $dst->type->bits : 64;
                            my $sf   = ( $bits >= 64 ) ? 0x80000000 : 0x00000000;
                            $bytes .= pack( 'V', $sf | 0x52800000 | ( ( $src->value & 0xFFFF ) << 5 ) | $did );
                        }
                        else {
                            my $src_r = $resolve->($src);
                            my $sid   = $reg_id->($src_r);
                            # mov xd, xn -> orr xd, xzr, xn
                            $bytes .= pack( 'V', 0xAA0003E0 | ( $sid << 16 ) | $did );
                        }
                    }
                    elsif ( $opcode eq 'add' || $opcode eq 'sub' || $opcode eq 'and' || $opcode eq 'or' || $opcode eq 'xor' || $opcode eq 'mul' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;  # width-aware
                        my %reg_op = (
                            add => ($bits >= 64 ? 0x8B000000 : 0x0B000000),
                            sub => ($bits >= 64 ? 0xCB000000 : 0x4B000000),
                            and => ($bits >= 64 ? 0x8A000000 : 0x0A000000),
                            or  => ($bits >= 64 ? 0xAA000000 : 0x2A000000),
                            xor => ($bits >= 64 ? 0xCA000000 : 0x4A000000),
                            mul => ($bits >= 64 ? 0x9B007C00 : 0x1B007C00),
                        );

                        if ( $src->kind eq 'imm' && ( $opcode eq 'add' || $opcode eq 'sub' ) ) {
                            my $sf     = ( $bits >= 64 ) ? 0x80000000 : 0x00000000;
                            my $op     = $sf | ( $opcode eq 'add' ? 0x11000000 : 0x51000000 );
                            my $imm12  = $src->value & 0xFFF;
                            $bytes .= pack( 'V', $op | ( $imm12 << 10 ) | ( $did << 5 ) | $did );
                        }
                        else {
                            my $src_r = $resolve->($src);
                            my $sid   = $reg_id->($src_r);
                            my $op = $reg_op{$opcode};
                            $bytes .= pack( 'V', $op | ( $sid << 16 ) | ( $did << 5 ) | $did );
                        }
                    }
                    elsif ( $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        die "ARM64 shift requires immediate amount" unless $src->kind eq 'imm';
                        my $imm = $src->value;
                        if ( $opcode eq 'shl' ) {
                            # LSL Xd, Xn, #imm  = UBFM Xd, Xn, #(64-imm), #(63-imm)
                            my $immr = ( 64 - $imm ) & 0x3F;
                            my $imms = ( 63 - $imm ) & 0x3F;
                            $bytes .= pack( 'V', 0xD3400000 | ( $immr << 16 ) | ( $imms << 10 ) | ( $did << 5 ) | $did );
                        }
                        elsif ( $opcode eq 'lshr' ) {
                            # LSR Xd, Xn, #imm  = UBFM Xd, Xn, #imm, #63
                            $bytes .= pack( 'V', 0xD3400000 | ( $imm << 16 ) | ( 63 << 10 ) | ( $did << 5 ) | $did );
                        }
                        else {
                            # ASR Xd, Xn, #imm  = SBFM Xd, Xn, #imm, #63
                            $bytes .= pack( 'V', 0x93400000 | ( $imm << 16 ) | ( 63 << 10 ) | ( $did << 5 ) | $did );
                        }
                    }
                    elsif ( $opcode eq 'alloca' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $size  = $src->value;
                        $total_frame += $size;
                        # sub sp, sp, #size
                        $bytes .= pack( 'V', 0xD10003FF | ( ( $size & 0xFFF ) << 10 ) );
                        # mov xd, sp  (add xd, sp, #0)
                        $bytes .= pack( 'V', 0x910003E0 | $did );
                    }
                    elsif ( $opcode eq 'load' ) {
                        my $dst_r  = $resolve->($dst);
                        my $did    = $reg_id->($dst_r);
                        my $addr   = $src->value;
                        my $base_r = $resolve->(
                            Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} )
                        );
                        my $bid    = $reg_id->($base_r);
                        my $disp   = $addr->{disp} // 0;
                        my $bits   = ($dst->type && $dst->type->kind eq 'int') ? $dst->type->bits : 64;
                        my $imm12  = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $base   = $bits == 32 ? 0xB9400000 : 0xF9400000;
                        $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( $bid << 5 ) | $did );
                    }
                    elsif ( $opcode eq 'store' ) {
                        my $src_r  = $resolve->($src);
                        my $sid    = $reg_id->($src_r);
                        my $addr   = $dst->value;
                        my $base_r = $resolve->(
                            Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} )
                        );
                        my $bid    = $reg_id->($base_r);
                        my $disp   = $addr->{disp} // 0;
                        my $bits   = ($src->type && $src->type->kind eq 'int') ? $src->type->bits : 64;
                        my $imm12  = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $base   = $bits == 32 ? 0xB9000000 : 0xF9000000;
                        $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( $bid << 5 ) | $sid );
                    }
                    elsif ( $opcode eq 'store_imm' ) {
                        my ($mem, $imm) = $inst->operands->@*;
                        my $addr   = $mem->value;
                        my $base_r = $resolve->(
                            Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} )
                        );
                        my $bid    = $reg_id->($base_r);
                        my $disp   = $addr->{disp} // 0;
                        my $bits   = ($imm->type && $imm->type->kind eq 'int') ? $imm->type->bits : 64;
                        my $imm12  = $disp >> ( $bits == 32 ? 2 : 3 );
                        # find a temporary register not in use
                        my %used;
                        @used{ values %$assignment } = ();
                        my $tmp_r;
                        for my $r ( $platform->registers('caller')->@* ) { $tmp_r = $r, last unless exists $used{$r} }
                        die 'no temp register for store_imm' unless $tmp_r;
                        my $tid = $reg_id->($tmp_r);
                        if ( $bits == 32 ) {
                            # movz wtmp, #imm16  (32-bit)
                            $bytes .= pack( 'V', 0x52800000 | ( ( $imm->value & 0xFFFF ) << 5 ) | $tid );
                            # str wtmp, [xn, #pimm]  (32-bit)
                            $bytes .= pack( 'V', 0xB9000000 | ( $imm12 << 10 ) | ( $bid << 5 ) | $tid );
                        } else {
                            # movz xtmp, #imm16  (64-bit)
                            $bytes .= pack( 'V', 0xD2800000 | ( ( $imm->value & 0xFFFF ) << 5 ) | $tid );
                            # str xtmp, [xn, #pimm]  (64-bit)
                            $bytes .= pack( 'V', 0xF9000000 | ( $imm12 << 10 ) | ( $bid << 5 ) | $tid );
                        }
                    }
                    elsif ( $opcode eq 'cmp' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        my $sf    = ( $bits >= 64 ) ? 0x80000000 : 0x00000000;
                        if ( $src->kind eq 'imm' ) {
                            # SUBS XZR, Xn, #imm12
                            my $imm12 = $src->value & 0xFFF;
                            $bytes .= pack( 'V', $sf | 0x7100001F | ( $imm12 << 10 ) | ( $did << 5 ) );
                        }
                        else {
                            my $src_r = $resolve->($src);
                            my $sid   = $reg_id->($src_r);
                            # CMP Xn/Wn, Xm/Wm  => SUBS XZR, Xn, Xm
                            $bytes .= pack( 'V', $sf | 0x6B00001F | ( $sid << 16 ) | ( $did << 5 ) );
                        }
                    }
                    elsif ( $opcode eq 'cset_eq' || $opcode eq 'cset_ne' || $opcode eq 'cset_lt' || $opcode eq 'cset_gt' || $opcode eq 'cset_le' || $opcode eq 'cset_ge' || $opcode eq 'cset_cc' || $opcode eq 'cset_cs' || $opcode eq 'cset_hi' || $opcode eq 'cset_ls' || $opcode eq 'cset_vc' || $opcode eq 'cset_vs' ) {
                        my %arm_cond = ( cset_eq => 1, cset_ne => 0, cset_lt => 0xA, cset_gt => 0xD, cset_le => 0xC, cset_ge => 0xB, cset_cc => 2, cset_cs => 3, cset_hi => 9, cset_ls => 8, cset_vc => 6, cset_vs => 7 );
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $cond  = $arm_cond{$opcode};
                        # CSET Xd, cond  => CSINC Xd, XZR, XZR, inv(cond)
                        $bytes .= pack( 'V', 0x9A9F03E0 | ( $cond << 12 ) | $did );
                    }
                    elsif ( $opcode eq 'fload' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $addr  = $src->value;
                        my $base_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} ) );
                        my $bid   = $reg_id->($base_r);
                        my $disp  = $addr->{disp} // 0;
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        my $imm12 = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $base  = $bits == 32 ? 0xBD400000 : 0xFD400000;
                        $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( $bid << 5 ) | $did );
                    }
                    elsif ( $opcode eq 'fstore' ) {
                        my $mem    = $dst;
                        my $src_r  = $resolve->($src);
                        my $sid    = $reg_id->($src_r);
                        my $addr   = $mem->value;
                        my $base_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{base} ) );
                        my $bid    = $reg_id->($base_r);
                        my $disp   = $addr->{disp} // 0;
                        my $bits   = $src->type ? $src->type->bits : 64;
                        my $imm12  = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $base   = $bits == 32 ? 0xBD000000 : 0xFD000000;
                        $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( $bid << 5 ) | $sid );
                    }
                    elsif ( $opcode eq 'fmov' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        my $base  = $bits == 32 ? 0x1E204000 : 0x1E604000;
                        $bytes .= pack( 'V', $base | ( $sid << 5 ) | $did );
                    }
                    elsif ( $opcode eq 'fmov_gp2f' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        my $base  = $bits == 32 ? 0x1E270000 : 0x9E670000;
                        $bytes .= pack( 'V', $base | ( $sid << 5 ) | $did );
                    }
                    elsif ( $opcode eq 'fadd' || $opcode eq 'fsub' || $opcode eq 'fmul' || $opcode eq 'fdiv' || $opcode eq 'fmin' || $opcode eq 'fmax' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        my %fop   = ( fadd => 0x1E202800, fsub => 0x1E203800, fmul => 0x1E200800, fdiv => 0x1E201800, fmin => 0x1E205800, fmax => 0x1E204800 );
                        my $base  = $fop{$opcode};
                        $base = $bits == 32 ? $base : ( $base | 0x00400000 );
                        $bytes .= pack( 'V', $base | ( $sid << 16 ) | ( $did << 5 ) | $did );
                    }
                    elsif ( $opcode eq 'fsqrt' || $opcode eq 'fabs' || $opcode eq 'fneg' ) {
                        my $dst_r = $resolve->($dst);
                        my $did   = $reg_id->($dst_r);
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        my %fop   = ( fsqrt => 0x1E21C000, fabs => 0x1E20C000, fneg => 0x1E214000 );
                        my $base  = $fop{$opcode};
                        $base = $bits == 32 ? $base : ( $base | 0x00400000 );
                        $bytes .= pack( 'V', $base | ( $sid << 5 ) | $did );
                    }
                    elsif ( $opcode eq 'fcmp' ) {
                        my $lhs_r = $resolve->($dst);
                        my $lid   = $reg_id->($lhs_r);
                        my $rhs_r = $resolve->($src);
                        my $rid   = $reg_id->($rhs_r);
                        my $bits  = $dst->type ? $dst->type->bits : 64;
                        my $base  = $bits == 32 ? 0x1E202000 : 0x1E602000;
                        $bytes .= pack( 'V', $base | ( $rid << 16 ) | ( $lid << 5 ) );
                    }
                    elsif ( $opcode eq 'ret' ) {
                        if ( $total_frame > 0 ) {
                            $bytes .= pack( 'V', 0x910003FF | ( ( $total_frame & 0xFFF ) << 10 ) );
                        }
                        if ( $callee_frame > 0 ) {
                            for my $i ( reverse 0 .. $used_callee->$#* ) {
                                my $reg = $used_callee->[$i];
                                my $rid = $reg_id->($reg);
                                my $base = $reg =~ /^v/ ? 0xFD400000 : 0xF9400000;
                                $bytes .= pack( 'V', $base | ( $i << 10 ) | ( 31 << 5 ) | $rid );
                            }
                            my $call_stk = ( ( $callee_frame + 15 ) & ~15 );
                            $bytes .= pack( 'V', 0x910003FF | ( ( $call_stk & 0xFFF ) << 10 ) );
                        }
                        $bytes .= pack( 'V', 0xD65F03C0 );
                    }
                }
            }
            for my $fixup ( @fixups ) {
                my $target_pos = $labels{ $fixup->{target} };
                die "undefined label: $fixup->{target}" unless defined $target_pos;
                my $rel = $target_pos - ( $fixup->{offset} + 4 );
                if ( $fixup->{type} eq 'b' ) {
                    substr $bytes, $fixup->{offset}, 4, pack( 'V', 0x14000000 | ( ( $rel / 4 ) & 0x3FFFFFF ) );
                }
                elsif ( $fixup->{type} eq 'cbz' ) {
                    my $inst = unpack( 'V', substr $bytes, $fixup->{offset}, 4 );
                    $inst = ( $inst & 0xFF00001F ) | ( ( ( $rel / 4 ) & 0x7FFFF ) << 5 );
                    substr $bytes, $fixup->{offset}, 4, pack( 'V', $inst );
                }
            }
            return $bytes;
        }
    }

    # ---------------------------------------------------------------------------
    # Machine IR (MIR) - Target-agnostic intermediate representation
    # ---------------------------------------------------------------------------
    class Brocken::Jenny::MIR::MachineOperand {
        field $kind  :param :reader;
        field $value :param :reader;
        field $type  :param :reader = undef;
    }

    class Brocken::Jenny::MIR::MachineInstruction {
        field $opcode   :param :reader;
        field $operands :param :reader = [];
        field $comment  :param :reader = '';
    }

    class Brocken::Jenny::MIR::MachineBasicBlock {
        field $name         :param :reader;
        field $instructions :param :reader = [];
        method add_instruction($inst) { push $self->instructions->@*, $inst }
    }

    class Brocken::Jenny::MIR::MachineFunction {
        field $name       :param :reader;
        field $blocks     :param :reader = [];
        field $frame_size :param :reader = 0;
        method add_block($block) { push $self->blocks->@*, $block }
    }

    # ---------------------------------------------------------------------------
    # Register Allocator: Linear Scan
    # ---------------------------------------------------------------------------
    class Brocken::Jenny::RegAlloc::LiveInterval {
        field $name  :param :reader;
        field $start :param :reader;
        field $end   :param :reader;
    }

    class Brocken::Jenny::RegAlloc::LinearScan {
        method allocate($mf, $platform, $is_float = 0) {
            my @intervals = $self->_compute_live_intervals($mf, $is_float);
            return $self->_linear_scan(\@intervals, $platform, $is_float);
        }

        method _compute_live_intervals($mf, $is_float) {
            my (%first, %last);
            my $idx = 0;
            for my $bb ( $mf->blocks->@* ) {
                for my $inst ( $bb->instructions->@* ) {
                    for my $op ( $inst->operands->@* ) {
                        if ( $op->kind eq 'virt_reg' ) {
                            my $name = $op->value;
                            my $type = $op->type;
                            my $is_f = $type ? ($type->kind eq 'float') : 0;
                            next if $is_float != $is_f;
                            $first{$name} //= $idx;
                            $last{$name}  = $idx;
                        }
                        elsif ( $op->kind eq 'mem' ) {
                            my $base = $op->value->{base};
                            next if $is_float;
                            $first{$base} //= $idx;
                            $last{$base}  = $idx;
                        }
                    }
                    $idx++;
                }
            }
            my @intervals;
            for my $name ( sort { $first{$a} <=> $first{$b} } keys %first ) {
                push @intervals,
                    Brocken::Jenny::RegAlloc::LiveInterval->new(
                    name => $name, start => $first{$name}, end => $last{$name}
                    );
            }
            return @intervals;
        }

        method _linear_scan( $intervals, $platform, $is_float ) {
            my @caller_regs = $is_float ? $platform->fp_registers('caller')->@* : $platform->registers('caller')->@*;
            my @callee_regs = $is_float ? $platform->fp_registers('callee')->@* : $platform->registers('callee')->@*;
            my $spill_temp  = pop @caller_regs;
            my @regs        = ( @caller_regs, @callee_regs );

            my %assignment;
            my %used_callee;
            my %spill_slots;
            my @active;
            my $next_spill = 0;

            for my $int ( $intervals->@* ) {
                @active = grep { $_->end >= $int->start } @active;

                if ( @active < @regs ) {
                    my %taken;
                    for my $a (@active) { $taken{ $assignment{ $a->name } } = 1 }
                    my $free;
                    for my $r (@regs) { unless ( $taken{$r} ) { $free = $r; last } }
                    $assignment{ $int->name } = $free;
                    $used_callee{$free} = 1 if grep { $_ eq $free } @callee_regs;
                    push @active, $int;
                }
                else {
                    my ($spill) = sort { $b->end <=> $a->end } @active;
                    my $freed_reg = $assignment{ $spill->name };
                    $spill_slots{ $spill->name } = $next_spill++ * 8;
                    $assignment{ $spill->name }  = 'spill(' . $spill_slots{ $spill->name } . ')';
                    @active = grep { $_->name ne $spill->name } @active;
                    $assignment{ $int->name } = $freed_reg;
                    $used_callee{$freed_reg} = 1 if grep { $_ eq $freed_reg } @callee_regs;
                    push @active, $int;
                }
            }
            return {
                assignment  => \%assignment,
                used_callee => [ sort keys %used_callee ],
                spill_slots => \%spill_slots,
                spill_temp  => $spill_temp,
            };
        }

        method insert_spill_code( $mf, $spill_slots, $spill_temp, $stack_reg, $is_float = 0 ) {
            return unless $spill_slots && keys %$spill_slots;
            my $load_op  = $is_float ? 'fload' : 'load';
            my $store_op = $is_float ? 'fstore' : 'store';
            for my $vreg ( keys %$spill_slots ) {
                my $offset = $spill_slots->{$vreg};
                for my $bb ( $mf->blocks->@* ) {
                    my @new;
                    for my $inst ( $bb->instructions->@* ) {
                        my $opcode = $inst->opcode;
                        my @ops    = $inst->operands->@*;

                        my $spilled_dst = 0;
                        my $spilled_src = 0;
                        my $spilled_mem = 0;

                        if ( @ops >= 1 && $ops[0]->kind eq 'virt_reg' && $ops[0]->value eq $vreg ) {
                            $spilled_dst = 1;
                            $ops[0] = Brocken::Jenny::MIR::MachineOperand->new(
                                kind => 'phys_reg', value => $spill_temp, type => $ops[0]->type
                            );
                        }
                        if ( @ops >= 2 && $ops[1]->kind eq 'virt_reg' && $ops[1]->value eq $vreg ) {
                            $spilled_src = 1;
                            $ops[1] = Brocken::Jenny::MIR::MachineOperand->new(
                                kind => 'phys_reg', value => $spill_temp, type => $ops[1]->type
                            );
                        }
                        for my $op (@ops) {
                            next unless $op->kind eq 'mem';
                            if ( ( $op->value->{base} // '' ) eq $vreg ) {
                                $spilled_mem = 1;
                                $op->value->{base} = $spill_temp;
                            }
                        }

                        if ($spilled_src || $spilled_mem) {
                            my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'mem',
                                value => { base => $stack_reg, disp => $offset },
                                type  => undef,
                            );
                            push @new, Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => $load_op,
                                operands => [
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $spill_temp ),
                                    $mem,
                                ],
                                comment => 'spill-reload',
                            );
                        }

                        my $new_inst = Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => $opcode,
                            operands => \@ops,
                            comment  => $inst->comment,
                        );
                        push @new, $new_inst;

                        if ($spilled_dst) {
                            my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                                kind  => 'mem',
                                value => { base => $stack_reg, disp => $offset },
                                type  => undef,
                            );
                            push @new, Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => $store_op,
                                operands => [
                                    $mem,
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $spill_temp ),
                                ],
                                comment => 'spill-store',
                            );
                        }
                    }
                    $bb->instructions->@* = @new;
                }
            }
        }
    }

    # ---------------------------------------------------------------------------
    # Lowerer: Lindsay IR -> Machine IR (x86_64)
    # ---------------------------------------------------------------------------
     class Brocken::Jenny::Lowerer::X86_64 {
        method lower($ir_func) {
            my $mf = Brocken::Jenny::MIR::MachineFunction->new(name => $ir_func->name);
            for my $block ( $ir_func->blocks->@* ) {
                my $mbb = Brocken::Jenny::MIR::MachineBasicBlock->new(name => $block->name);
                if ( $ir_func->blocks->[0] != $block ) {
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode => 'label',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $block->name ) ],
                            comment => 'block: ' . $block->name
                        )
                    );
                }
                for my $inst ( $block->instructions->@* ) {
                    my $opcode = $inst->opcode;
                    if ( $opcode eq 'add' || $opcode eq 'sub' || $opcode eq 'mul' || $opcode eq 'div' || $opcode eq 'and' || $opcode eq 'or' || $opcode eq 'xor' || $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' || $opcode eq 'min' || $opcode eq 'max' ) {
                        my ( $lhs, $rhs ) = $inst->operands->@*;
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        my $is_float = $inst->type && $inst->type->kind eq 'float';
                        if ($is_float) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'fmov',
                                    operands => [ $dst, $self->_materialize($mbb, $lhs) ],
                                    comment  => 'fload ' . ( $lhs->name || $lhs->value )
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'f' . $opcode,
                                    operands => [ $dst, $self->_materialize($mbb, $rhs) ],
                                    comment  => 'f' . $opcode
                                )
                            );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'load ' . ( $lhs->name || $lhs->value )
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $opcode,
                                    operands => [ $dst, $self->_lower_opnd($rhs) ],
                                    comment  => $opcode
                                )
                            );
                        }
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Br') ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'jmp',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->dest_block->name ) ],
                                comment  => 'br ' . $inst->dest_block->name
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::CondBr') ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'bne',
                                operands => [ $self->_lower_opnd( $inst->operands->[0] ), Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->true_block->name ) ],
                                comment  => 'cond_br: true'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'jmp',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->false_block->name ) ],
                                comment  => 'cond_br: false'
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ICmp') ) {
                        my ($lhs, $rhs) = $inst->operands->@*;
                        my $pred = $inst->predicate;
                        my %cond = (eq => 'e', ne => 'ne', slt => 'l', sgt => 'g', sle => 'le', sge => 'ge', ult => 'b', ugt => 'a', ule => 'be', uge => 'ae');
                        my %fcond = (eq => 'e', ne => 'ne', lt => 'b', le => 'be', gt => 'a', ge => 'ae');
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        if ($lhs->type && $lhs->type->kind eq 'float') {
                            my $lhs_op = $self->_materialize($mbb, $lhs);
                            my $rhs_op = $self->_materialize($mbb, $rhs);
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode => 'fcmp', operands => [ $lhs_op, $rhs_op ],
                                    comment => 'fcmp ' . $pred
                                )
                            );
                            # NaN-correct float comparison (IEEE 754 ordered/unordered)
                            # After UCOMISS: PF=1 when unordered (NaN); only setnp/setp check PF.
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode => 'mov',
                                    operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new(kind => 'imm', value => 0) ],
                                    comment => 'zero dst'
                                )
                            );
                            if ( $pred eq 'ne' ) {
                                # ne: unordered OR not equal  => setp OR setne
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode => 'setp', operands => [$dst],
                                        comment => 'setp: unordered (PF=1)'
                                    )
                                );
                            }
                            else {
                                # ordered predicates: setnp AND setCC
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode => 'setnp', operands => [$dst],
                                        comment => 'setnp: ordered (PF=0)'
                                    )
                                );
                            }
                            my $tmp = Brocken::Jenny::MIR::MachineOperand->new(
                                kind => 'virt_reg', value => $inst->name . '_pf', type => Brocken::Lindsay::IR::Type::i1()
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode => 'set' . $fcond{$pred},
                                    operands => [$tmp],
                                    comment => 'set' . $fcond{$pred}
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode => ( $pred eq 'ne' ? 'or' : 'and' ),
                                    operands => [ $dst, $tmp ],
                                    comment => ( $pred eq 'ne' ? 'unordered OR not equal' : 'ordered AND condition' )
                                )
                            );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'load lhs'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'cmp',
                                    operands => [ $dst, $self->_lower_opnd($rhs) ],
                                    comment  => 'icmp ' . $pred
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'set' . $cond{$pred},
                                    operands => [$dst],
                                    comment  => 'set' . $cond{$pred}
                                )
                            );
                        }
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Ret') ) {
                        if ( $inst->type->kind ne 'void' ) {
                            my $val = $inst->operands->[0];
                            if ($inst->type->kind eq 'float') {
                                my $xmm0 = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'xmm0' );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'fmov',
                                        operands => [ $xmm0, $self->_materialize($mbb, $val) ],
                                        comment  => '=> xmm0'
                                    )
                                );
                            }
                            else {
                                my $rax = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'rax' );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $rax, $self->_lower_opnd($val) ],
                                        comment  => '=> rax'
                                    )
                                );
                            }
                        }
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'ret', operands => [], comment => ''
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Alloca') ) {
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        my $size = $inst->allocated_type->bits / 8;
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'alloca',
                                operands => [
                                    $dst,
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $size )
                                ],
                                comment => "alloca $size bytes"
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Load') ) {
                        my $ptr       = $inst->operands->[0];
                        my $mem       = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $ptr->name, disp => 0 },
                            type  => $inst->type
                        );
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        my $load_op = ($inst->type && $inst->type->kind eq 'float') ? 'fload' : 'load';
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => $load_op, operands => [ $dst, $mem ],
                                comment => 'load'
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Store') ) {
                        my ( $val, $ptr ) = $inst->operands->@*;
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $ptr->name, disp => 0 },
                            type  => $val->type
                        );
                        if ($val->type && $val->type->kind eq 'float') {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'fstore',
                                    operands => [ $mem, $self->_materialize($mbb, $val) ],
                                    comment  => 'fstore'
                                )
                            );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => ($val->isa('Brocken::Lindsay::IR::Constant') ? 'store_imm' : 'store'),
                                    operands => [ $mem, $self->_lower_opnd($val) ],
                                    comment  => 'store'
                                )
                            );
                        }
                    }
                    elsif ( $opcode eq 'neg' || $opcode eq 'abs' || $opcode eq 'sqrt' ) {
                        my ($val) = $inst->operands->@*;
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        if ( $inst->type && $inst->type->kind eq 'float' ) {
                            my $src = $self->_materialize($mbb, $val);
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode => 'fmov', operands => [ $dst, $src ],
                                    comment => 'load ' . $opcode . ' operand'
                                )
                            );
                            if ( $opcode eq 'sqrt' ) {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode => 'fsqrt', operands => [ $dst, $dst ],
                                        comment => 'fsqrt'
                                    )
                                );
                            }
                            else {
                                my $bits = $inst->type->bits;
                                my $mask_val = $opcode eq 'neg'
                                    ? ( $bits >= 64 ? 0x8000000000000000 : 0x80000000 )
                                    : ( $bits >= 64 ? 0x7FFFFFFFFFFFFFFF : 0x7FFFFFFF );
                                my $mname = $inst->name . '_m';
                                my $mask_gp = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind => 'virt_reg', value => $mname, type => Brocken::Lindsay::IR::Type::i64()
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode => 'mov',
                                        operands => [ $mask_gp, Brocken::Jenny::MIR::MachineOperand->new(kind => 'imm', value => $mask_val) ],
                                        comment => 'mask constant'
                                    )
                                );
                                my $mask_fp = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind => 'virt_reg', value => $mname . 'f', type => $inst->type
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode => 'fmov_gp2f',
                                        operands => [ $mask_fp, $mask_gp ],
                                        comment => 'mask -> XMM'
                                    )
                                );
                                my $fop = $opcode eq 'neg' ? 'fxor' : 'fand';
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode => $fop,
                                        operands => [ $dst, $mask_fp ],
                                        comment => $fop
                                    )
                                );
                            }
                        }
                        else {
                            die "Unsupported unary op $opcode for non-float type";
                        }
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Box') ) {
                        my $val  = $inst->operands->[0];
                        my $tag  = $self->_type_tag( $val->type );
                        my $size = 16;    # fat scalar: 16 bytes (8 payload + 8 tag)
                        my $dyn  = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        # alloca %dyn, 16
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'alloca',
                                operands => [
                                    $dyn,
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $size )
                                ],
                                comment => 'box: alloca 16'
                            )
                        );
                        # store [%dyn + 0], %val
                        my $mem_val = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $inst->name, disp => 0 },
                            type  => $val->type
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => ($val->isa('Brocken::Lindsay::IR::Constant') ? 'store_imm' : 'store'),
                                operands => [ $mem_val, $self->_lower_opnd($val) ],
                                comment  => 'box: store payload'
                            )
                        );
                        # store [%dyn + 8], tag
                        my $mem_tag = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $inst->name, disp => 8 },
                            type  => Brocken::Lindsay::IR::Type::i64()
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'store_imm',
                                operands => [
                                    $mem_tag,
                                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $tag, type => Brocken::Lindsay::IR::Type::i64() )
                                ],
                                comment => 'box: store tag'
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Unbox') ) {
                        my $dyn = $inst->operands->[0];
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => 'mem',
                            value => { base => $dyn->name, disp => 0 },
                            type  => $inst->type
                        );
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'load', operands => [ $dst, $mem ],
                                comment => 'unbox: load payload'
                            )
                        );
                    }
                }
                $mf->add_block($mbb);
            }
            return $mf;
        }

        method _type_tag($type) {
            return 1 if $type->kind eq 'int' && $type->bits <= 32;   # i1, i8, i16, i32
            return 2 if $type->kind eq 'int' && $type->bits == 64;
            return 3 if $type->kind eq 'float';                     # f32, f64
            return 4 if $type->kind eq 'ptr';
            return 5 if $type->kind eq 'dynamic';
            return 0;
        }

        method _materialize($mbb, $ir_val) {
            state $fc = 0;
            if ($ir_val->isa('Brocken::Lindsay::IR::Constant') && $ir_val->type && $ir_val->type->kind eq 'float') {
                my $bits = $ir_val->type->bits;
                my $value = $ir_val->value;
                my $bit_pattern = $bits >= 64 ? unpack('Q', pack('d', $value)) : unpack('V', pack('f', $value));
                my $gp_name = '%fmcgp_' . $fc++;
                my $fp_name = '%fmcfp_' . $fc++;
                my $gp_type = Brocken::Lindsay::IR::Type::i64();
                my $gp = Brocken::Jenny::MIR::MachineOperand->new(kind => 'virt_reg', value => $gp_name, type => $gp_type);
                my $fp = Brocken::Jenny::MIR::MachineOperand->new(kind => 'virt_reg', value => $fp_name, type => $ir_val->type);
                $mbb->add_instruction(
                    Brocken::Jenny::MIR::MachineInstruction->new(
                        opcode => 'mov', operands => [$gp, Brocken::Jenny::MIR::MachineOperand->new(kind => 'imm', value => $bit_pattern, type => $gp_type)],
                        comment => 'fmc: bit pattern'
                    )
                );
                $mbb->add_instruction(
                    Brocken::Jenny::MIR::MachineInstruction->new(
                        opcode => 'fmov_gp2f', operands => [$fp, $gp],
                        comment => 'fmc: gp->xmm'
                    )
                );
                return $fp;
            }
            return $self->_lower_opnd($ir_val);
        }

        method _lower_opnd($ir_val) {
            if ( $ir_val->isa('Brocken::Lindsay::IR::Constant') ) {
                return Brocken::Jenny::MIR::MachineOperand->new(
                    kind => 'imm', value => $ir_val->value, type => $ir_val->type
                );
            }
            return Brocken::Jenny::MIR::MachineOperand->new(
                kind => 'virt_reg', value => $ir_val->name, type => $ir_val->type
            );
        }
    }

    # ---------------------------------------------------------------------------
    # Lowerer: Lindsay IR -> Machine IR (ARM64 / AArch64)
    # ---------------------------------------------------------------------------
        class Brocken::Jenny::Lowerer::ARM64 {
        method lower($ir_func) {
            my $mf = Brocken::Jenny::MIR::MachineFunction->new(name => $ir_func->name);
            for my $block ( $ir_func->blocks->@* ) {
                my $mbb = Brocken::Jenny::MIR::MachineBasicBlock->new(name => $block->name);
                if ( $ir_func->blocks->[0] != $block ) {
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode => 'label',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $block->name ) ],
                            comment => 'block: ' . $block->name
                        )
                    );
                }
                for my $inst ( $block->instructions->@* ) {
                    my $opcode = $inst->opcode;
                    if ( $opcode eq 'add' || $opcode eq 'sub' || $opcode eq 'mul' || $opcode eq 'and' || $opcode eq 'or' || $opcode eq 'xor' || $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' || $opcode eq 'min' || $opcode eq 'max' ) {
                        my ( $lhs, $rhs ) = $inst->operands->@*;
                        my $is_float = $lhs->type && $lhs->type->kind eq 'float';
                        my $mop = $is_float ? "f$opcode" : $opcode;
                        $mop = $opcode if $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr';
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        if ($is_float) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'fmov',
                                    operands => [ $dst, $self->_materialize($mbb, $lhs) ],
                                    comment  => 'fload ' . ( $lhs->name || $lhs->value )
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $mop,
                                    operands => [ $dst, $self->_materialize($mbb, $rhs) ],
                                    comment  => $opcode
                                )
                            );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mov',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'load ' . ( $lhs->name || $lhs->value )
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $opcode,
                                    operands => [ $dst, $self->_lower_opnd($rhs) ],
                                    comment  => $opcode
                                )
                            );
                        }
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Br') ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'jmp',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->dest_block->name ) ],
                                comment  => 'br ' . $inst->dest_block->name
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::CondBr') ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'bne',
                                operands => [ $self->_lower_opnd( $inst->operands->[0] ), Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->true_block->name ) ],
                                comment  => 'cond_br: true'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'jmp',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->false_block->name ) ],
                                comment  => 'cond_br: false'
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Alloca') ) {
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        my $size = $inst->allocated_type->bits / 8;
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'alloca', operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $size ) ],
                                comment => "alloca $size bytes"
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Load') ) {
                        my $ptr = $inst->operands->[0];
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'mem', value => { base => $ptr->name, disp => 0 }, type => $inst->type
                        );
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        my $lop = ($inst->type && $inst->type->kind eq 'float') ? 'fload' : 'load';
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => $lop, operands => [ $dst, $mem ], comment => $lop
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Store') ) {
                        my ($val, $ptr) = $inst->operands->@*;
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'mem', value => { base => $ptr->name, disp => 0 }, type => $val->type
                        );
                        if ($val->type && $val->type->kind eq 'float') {
                            my $src = $val->isa('Brocken::Lindsay::IR::Constant') ? $self->_materialize($mbb, $val) : $self->_lower_opnd($val);
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode => 'fstore', operands => [ $mem, $src ], comment => 'fstore'
                                )
                            );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode => ($val->isa('Brocken::Lindsay::IR::Constant') ? 'store_imm' : 'store'), operands => [ $mem, $self->_lower_opnd($val) ], comment => 'store'
                                )
                            );
                        }
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Box') ) {
                        my $val  = $inst->operands->[0];
                        my $size = 16;
                        my $dyn  = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'alloca', operands => [ $dyn, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $size ) ],
                                comment => 'box: alloca 16'
                            )
                        );
                        my $payload_mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'mem', value => { base => $inst->name, disp => 0 }, type => $val->type
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => ($val->isa('Brocken::Lindsay::IR::Constant') ? 'store_imm' : 'store'), operands => [ $payload_mem, $self->_lower_opnd($val) ],
                                comment => 'box: store payload'
                            )
                        );
                        my $tag_mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'mem', value => { base => $inst->name, disp => 8 }, type => Brocken::Lindsay::IR::Type::i64()
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'store_imm', operands => [ $tag_mem, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $self->_type_tag($val->type), type => Brocken::Lindsay::IR::Type::i64() ) ],
                                comment => 'box: store tag'
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Unbox') ) {
                        my $dyn = $inst->operands->[0];
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'mem', value => { base => $dyn->name, disp => 0 }, type => $inst->type
                        );
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode => 'load', operands => [ $dst, $mem ], comment => 'unbox: load payload'
                                )
                            );
                        }
                        elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ICmp') ) {
                            my ($lhs, $rhs) = $inst->operands->@*;
                            my $pred = $inst->predicate;
                            my %cond = (eq => 'cset_eq', ne => 'cset_ne', slt => 'cset_lt', sgt => 'cset_gt', sle => 'cset_le', sge => 'cset_ge', ult => 'cset_cc', ugt => 'cset_hi', ule => 'cset_ls', uge => 'cset_cs');
                            my %fcond = (eq => 'cset_eq', ne => 'cset_ne', lt => 'cset_lt', le => 'cset_le', gt => 'cset_gt', ge => 'cset_ge');
                            my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                                kind => 'virt_reg', value => $inst->name, type => $inst->type
                            );
                            if ($lhs->type && $lhs->type->kind eq 'float') {
                                my $lhs_op = $self->_materialize($mbb, $lhs);
                                my $rhs_op = $self->_materialize($mbb, $rhs);
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode => 'fcmp', operands => [ $lhs_op, $rhs_op ],
                                        comment => 'fcmp ' . $pred
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode => 'mov',
                                        operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new(kind => 'imm', value => 0) ],
                                        comment => 'zero dst'
                                    )
                                );
                                my $tmp = Brocken::Jenny::MIR::MachineOperand->new(
                                    kind => 'virt_reg', value => $inst->name . '_pf', type => Brocken::Lindsay::IR::Type::i1()
                                );
                                if ( $pred eq 'ne' ) {
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode => 'cset_vs', operands => [$dst],
                                            comment => 'unordered'
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode => 'cset_ne', operands => [$tmp],
                                            comment => 'ne'
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode => 'or', operands => [ $dst, $tmp ],
                                            comment => 'unordered OR ne'
                                        )
                                    );
                                }
                                else {
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode => 'cset_vc', operands => [$dst],
                                            comment => 'ordered'
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode => $fcond{$pred}, operands => [$tmp],
                                            comment => $pred
                                        )
                                    );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode => 'and', operands => [ $dst, $tmp ],
                                            comment => 'ordered AND condition'
                                        )
                                    );
                                }
                            }
                            else {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mov',
                                        operands => [ $dst, $self->_lower_opnd($lhs) ],
                                        comment  => 'load lhs'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'cmp',
                                        operands => [ $dst, $self->_lower_opnd($rhs) ],
                                        comment  => 'icmp ' . $pred
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => $cond{$pred},
                                        operands => [$dst],
                                        comment  => $pred
                                    )
                                );
                            }
                        }
                        elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Ret') ) {
                            if ( $inst->type->kind ne 'void' ) {
                                my $val = $inst->operands->[0];
                                if ($inst->type->kind eq 'float') {
                                    my $v0 = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'v0' );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'fmov',
                                            operands => [ $v0, $self->_materialize($mbb, $val) ],
                                            comment  => '=> v0'
                                        )
                                    );
                                }
                                else {
                                    my $x0  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x0' );
                                    $mbb->add_instruction(
                                        Brocken::Jenny::MIR::MachineInstruction->new(
                                            opcode   => 'mov',
                                            operands => [ $x0, $self->_lower_opnd($val) ],
                                            comment  => '=> x0'
                                        )
                                    );
                                }
                            }
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode => 'ret', operands => [], comment => ''
                                )
                            );
                        }
                    }
                    $mf->add_block($mbb);
                }
                return $mf;
            }
    
        method _materialize($mbb, $ir_val) {
            state $fc = 0;
            if ($ir_val->isa('Brocken::Lindsay::IR::Constant') && $ir_val->type && $ir_val->type->kind eq 'float') {
                my $bits = $ir_val->type->bits;
                my $value = $ir_val->value;
                my $bit_pattern = $bits >= 64 ? unpack('Q', pack('d', $value)) : unpack('V', pack('f', $value));
                my $gp_name = '%fmcgp_' . $fc++;
                my $fp_name = '%fmcfp_' . $fc++;
                my $gp_type = Brocken::Lindsay::IR::Type::i64();
                my $gp = Brocken::Jenny::MIR::MachineOperand->new(kind => 'virt_reg', value => $gp_name, type => $gp_type);
                my $fp = Brocken::Jenny::MIR::MachineOperand->new(kind => 'virt_reg', value => $fp_name, type => $ir_val->type);
                $mbb->add_instruction(
                    Brocken::Jenny::MIR::MachineInstruction->new(
                        opcode => 'mov', operands => [$gp, Brocken::Jenny::MIR::MachineOperand->new(kind => 'imm', value => $bit_pattern, type => $gp_type)],
                        comment => 'fmc: bit pattern'
                    )
                );
                $mbb->add_instruction(
                    Brocken::Jenny::MIR::MachineInstruction->new(
                        opcode => 'fmov_gp2f', operands => [$fp, $gp],
                        comment => 'fmc: gp->fp'
                    )
                );
                return $fp;
            }
            return $self->_lower_opnd($ir_val);
        }

            method _lower_opnd($ir_val) {
            if ( $ir_val->isa('Brocken::Lindsay::IR::Constant') ) {
                return Brocken::Jenny::MIR::MachineOperand->new(
                    kind => 'imm', value => $ir_val->value, type => $ir_val->type
                );
            }
            return Brocken::Jenny::MIR::MachineOperand->new(
                kind => 'virt_reg', value => $ir_val->name, type => $ir_val->type
            );
        }

        method _type_tag($type) {
            return 1 if $type->kind eq 'int' && $type->bits <= 32;
            return 2 if $type->kind eq 'int' && $type->bits == 64;
            return 6 if $type->kind eq 'int' && $type->bits == 128;
            return 3 if $type->kind eq 'float';
            return 4 if $type->kind eq 'ptr';
            return 5 if $type->kind eq 'dynamic';
            return 0;
        }
    }

    # ---------------------------------------------------------------------------
    # Lowerer: Lindsay IR -> Machine IR (RISC-V 64)
    # ---------------------------------------------------------------------------
        class Brocken::Jenny::Lowerer::RISCV64 {
        method lower($ir_func) {
            my $mf = Brocken::Jenny::MIR::MachineFunction->new(name => $ir_func->name);
            for my $block ( $ir_func->blocks->@* ) {
                my $mbb = Brocken::Jenny::MIR::MachineBasicBlock->new(name => $block->name);
                if ( $ir_func->blocks->[0] != $block ) {
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode => 'label',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $block->name ) ],
                            comment => 'block: ' . $block->name
                        )
                    );
                }
                for my $inst ( $block->instructions->@* ) {
                    my $opcode = $inst->opcode;
                    if ( $opcode eq 'add' || $opcode eq 'sub' || $opcode eq 'mul' || $opcode eq 'div' || $opcode eq 'and' || $opcode eq 'or' || $opcode eq 'xor' || $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' ) {
                        my ( $lhs, $rhs ) = $inst->operands->@*;
                        my $is_float = $lhs->type && $lhs->type->kind eq 'float';
                        my $mop = $is_float ? "f$opcode" : $opcode;
                        $mop = $opcode if $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr';
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        if ($is_float) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'fmov',
                                    operands => [ $dst, $self->_materialize($mbb, $lhs) ],
                                    comment  => 'fload ' . ( $lhs->name || $lhs->value )
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $mop,
                                    operands => [ $dst, $self->_materialize($mbb, $rhs) ],
                                    comment  => $opcode
                                )
                            );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'load ' . ( $lhs->name || $lhs->value )
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => $mop,
                                    operands => [ $dst, $self->_lower_opnd($rhs) ],
                                    comment  => $opcode
                                )
                            );
                        }
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Br') ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'jmp',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->dest_block->name ) ],
                                comment  => 'br ' . $inst->dest_block->name
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::CondBr') ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'bne',
                                operands => [ $self->_lower_opnd( $inst->operands->[0] ), Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->true_block->name ) ],
                                comment  => 'cond_br: true'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'jmp',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->false_block->name ) ],
                                comment  => 'cond_br: false'
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Alloca') ) {
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        my $size = $inst->allocated_type->bits / 8;
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'alloca', operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $size ) ],
                                comment => "alloca $size bytes"
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Load') ) {
                        my $ptr = $inst->operands->[0];
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'mem', value => { base => $ptr->name, disp => 0 }, type => $inst->type
                        );
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        my $lop = ($inst->type && $inst->type->kind eq 'float') ? 'fload' : 'load';
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => $lop, operands => [ $dst, $mem ], comment => $lop
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Store') ) {
                        my ($val, $ptr) = $inst->operands->@*;
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'mem', value => { base => $ptr->name, disp => 0 }, type => $val->type
                        );
                        if ($val->type && $val->type->kind eq 'float') {
                            my $src = $val->isa('Brocken::Lindsay::IR::Constant') ? $self->_materialize($mbb, $val) : $self->_lower_opnd($val);
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode => 'fstore', operands => [ $mem, $src ], comment => 'fstore'
                                )
                            );
                        }
                        else {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode => ($val->isa('Brocken::Lindsay::IR::Constant') ? 'store_imm' : 'store'), operands => [ $mem, $self->_lower_opnd($val) ], comment => 'store'
                                )
                            );
                        }
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Box') ) {
                        my $val  = $inst->operands->[0];
                        my $size = 16;
                        my $dyn  = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'alloca', operands => [ $dyn, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $size ) ],
                                comment => 'box: alloca 16'
                            )
                        );
                        my $payload_mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'mem', value => { base => $inst->name, disp => 0 }, type => $val->type
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => ($val->isa('Brocken::Lindsay::IR::Constant') ? 'store_imm' : 'store'), operands => [ $payload_mem, $self->_lower_opnd($val) ],
                                comment => 'box: store payload'
                            )
                        );
                        my $tag_mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'mem', value => { base => $inst->name, disp => 8 }, type => Brocken::Lindsay::IR::Type::i64()
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'store_imm', operands => [ $tag_mem, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $self->_type_tag($val->type), type => Brocken::Lindsay::IR::Type::i64() ) ],
                                comment => 'box: store tag'
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Unbox') ) {
                        my $dyn = $inst->operands->[0];
                        my $mem = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'mem', value => { base => $dyn->name, disp => 0 }, type => $inst->type
                        );
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'load', operands => [ $dst, $mem ], comment => 'unbox: load payload'
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ICmp') ) {
                        my ($lhs, $rhs) = $inst->operands->@*;
                        my $pred = $inst->predicate;
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        if ( $pred eq 'eq' || $pred eq 'ne' ) {
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $dst, $self->_lower_opnd($lhs) ],
                                    comment  => 'icmp ' . $pred . ': mv lhs'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'xor',
                                    operands => [ $dst, $self->_lower_opnd($rhs) ],
                                    comment  => 'icmp ' . $pred . ': xor rhs'
                                )
                            );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'sltiu',
                                    operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ],
                                    comment  => 'seqz'
                                )
                            );
                            if ( $pred eq 'ne' ) {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'xor',
                                        operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ],
                                        comment  => 'xori 1'
                                    )
                                );
                            }
                        }
                        elsif ( $pred eq 'ult' || $pred eq 'ugt' || $pred eq 'ule' || $pred eq 'uge' ) {
                            # ult/ugt/ule/uge: sltu rd, rs1, rs2
                            if ( $pred eq 'ugt' || $pred eq 'ule' ) {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $dst, $self->_lower_opnd($rhs) ],
                                        comment  => 'icmp ' . $pred . ': mv rhs'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sltu',
                                        operands => [ $dst, $self->_lower_opnd($lhs) ],
                                        comment  => 'icmp ' . $pred . ': sltu'
                                    )
                                );
                            }
                            else {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $dst, $self->_lower_opnd($lhs) ],
                                        comment  => 'icmp ' . $pred . ': mv lhs'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'sltu',
                                        operands => [ $dst, $self->_lower_opnd($rhs) ],
                                        comment  => 'icmp ' . $pred . ': sltu'
                                    )
                                );
                            }
                            if ( $pred eq 'ule' || $pred eq 'uge' ) {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'xor',
                                        operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ],
                                        comment  => 'xori 1'
                                    )
                                );
                            }
                        }
                        else {
                            # slt/sgt/sle/sge: slt rd, rs1, rs2
                            if ( $pred eq 'sgt' || $pred eq 'sle' ) {
                                # slt dst, rhs, lhs  →  mv dst, rhs; slt dst, lhs
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $dst, $self->_lower_opnd($rhs) ],
                                        comment  => 'icmp ' . $pred . ': mv rhs'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'slt',
                                        operands => [ $dst, $self->_lower_opnd($lhs) ],
                                        comment  => 'icmp ' . $pred . ': slt'
                                    )
                                );
                            }
                            else {
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'mv',
                                        operands => [ $dst, $self->_lower_opnd($lhs) ],
                                        comment  => 'icmp ' . $pred . ': mv lhs'
                                    )
                                );
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'slt',
                                        operands => [ $dst, $self->_lower_opnd($rhs) ],
                                        comment  => 'icmp ' . $pred . ': slt'
                                    )
                                );
                            }
                            if ( $pred eq 'sle' || $pred eq 'sge' ) {
                                # xori dst, dst, 1
                                $mbb->add_instruction(
                                    Brocken::Jenny::MIR::MachineInstruction->new(
                                        opcode   => 'xor',
                                        operands => [ $dst, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ) ],
                                        comment  => 'xori 1'
                                    )
                                );
                            }
                        }
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Ret') ) {
                        if ( $inst->type->kind ne 'void' ) {
                            my $val = $inst->operands->[0];
                            my $a0  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'a0' );
                            $mbb->add_instruction(
                                Brocken::Jenny::MIR::MachineInstruction->new(
                                    opcode   => 'mv',
                                    operands => [ $a0, $self->_lower_opnd($val) ],
                                    comment  => '=> a0'
                                )
                            );
                        }
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'ret', operands => [], comment => ''
                            )
                        );
                    }
                }
                $mf->add_block($mbb);
            }
            return $mf;
        }

        method _materialize($mbb, $ir_val) {
            state $fc = 0;
            if ($ir_val->isa('Brocken::Lindsay::IR::Constant') && $ir_val->type && $ir_val->type->kind eq 'float') {
                my $bits = $ir_val->type->bits;
                my $value = $ir_val->value;
                my $bit_pattern = $bits >= 64 ? unpack('Q', pack('d', $value)) : unpack('V', pack('f', $value));
                my $gp_name = '%fmcgp_' . $fc++;
                my $fp_name = '%fmcfp_' . $fc++;
                my $gp_type = Brocken::Lindsay::IR::Type::i64();
                my $gp = Brocken::Jenny::MIR::MachineOperand->new(kind => 'virt_reg', value => $gp_name, type => $gp_type);
                my $fp = Brocken::Jenny::MIR::MachineOperand->new(kind => 'virt_reg', value => $fp_name, type => $ir_val->type);
                $mbb->add_instruction(
                    Brocken::Jenny::MIR::MachineInstruction->new(
                        opcode => 'mv', operands => [$gp, Brocken::Jenny::MIR::MachineOperand->new(kind => 'imm', value => $bit_pattern, type => $gp_type)],
                        comment => 'fmc: bit pattern'
                    )
                );
                $mbb->add_instruction(
                    Brocken::Jenny::MIR::MachineInstruction->new(
                        opcode => 'fmov_gp2f', operands => [$fp, $gp],
                        comment => 'fmc: gp->fp'
                    )
                );
                return $fp;
            }
            return $self->_lower_opnd($ir_val);
        }

        method _lower_opnd($ir_val) {
            if ( $ir_val->isa('Brocken::Lindsay::IR::Constant') ) {
                return Brocken::Jenny::MIR::MachineOperand->new(
                    kind => 'imm', value => $ir_val->value, type => $ir_val->type
                );
            }
            return Brocken::Jenny::MIR::MachineOperand->new(
                kind => 'virt_reg', value => $ir_val->name, type => $ir_val->type
            );
        }

        method _type_tag($type) {
            return 1 if $type->kind eq 'int' && $type->bits <= 32;
            return 2 if $type->kind eq 'int' && $type->bits == 64;
            return 6 if $type->kind eq 'int' && $type->bits == 128;
            return 3 if $type->kind eq 'float';
            return 4 if $type->kind eq 'ptr';
            return 5 if $type->kind eq 'dynamic';
            return 0;
        }
    }

    # ---------------------------------------------------------------------------
    # Lowerer: Lindsay IR -> Machine IR (Wasm)
    # ---------------------------------------------------------------------------
     class Brocken::Jenny::Lowerer::Wasm {
        method lower($ir_func) {
            my $mf = Brocken::Jenny::MIR::MachineFunction->new(name => $ir_func->name);
            for my $block ( $ir_func->blocks->@* ) {
                my $mbb = Brocken::Jenny::MIR::MachineBasicBlock->new(name => $block->name);
                if ( $ir_func->blocks->[0] != $block ) {
                    $mbb->add_instruction(
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode => 'label',
                            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $block->name ) ],
                            comment => 'block: ' . $block->name
                        )
                    );
                }
                for my $inst ( $block->instructions->@* ) {
                    my $opcode = $inst->opcode;
                    if ( $opcode eq 'add' || $opcode eq 'sub' || $opcode eq 'mul' || $opcode eq 'and' || $opcode eq 'or' || $opcode eq 'xor' || $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' || $opcode eq 'min' || $opcode eq 'max' ) {
                        my ( $lhs, $rhs ) = $inst->operands->@*;
                        my $p;
                        if ($inst->type && $inst->type->kind eq 'float') {
                            $p = $inst->type->bits >= 64 ? 'f64' : 'f32';
                        }
                        else {
                            my $bits = $inst->type && $inst->type->kind eq 'int' ? $inst->type->bits : 32;
                            $p = $bits >= 64 ? 'i64' : 'i32';
                        }

                        # Push LHS onto Wasm stack
                        $mbb->add_instruction( $self->_wasm_push( $lhs, 'LHS' ) );
                        # Push RHS onto Wasm stack
                        $mbb->add_instruction( $self->_wasm_push( $rhs, 'RHS' ) );
                        # Arithmetic/bitwise op (consumes 2, produces 1 on stack)
                        my %map = (
                            add => "${p}_add", sub => "${p}_sub", mul => "${p}_mul",
                            and => "${p}_and", or  => "${p}_or",  xor => "${p}_xor",
                            shl => "${p}_shl", lshr => "${p}_shr_u", ashr => "${p}_shr_s",
                            min => "${p}_min", max => "${p}_max",
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => $map{$opcode}, operands => [], comment => $opcode
                            )
                        );
                        # Store result from stack to a local
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'local_set', operands => [$dst], comment => 'store ' . $inst->name
                            )
                        );
                    }
                    elsif ( $opcode eq 'neg' || $opcode eq 'abs' || $opcode eq 'sqrt' ) {
                        my ($val) = $inst->operands->@*;
                        die "Wasm unary op $opcode requires float type" unless $inst->type && $inst->type->kind eq 'float';
                        my $p = $inst->type->bits >= 64 ? 'f64' : 'f32';
                        print STDERR ">>> UNARY $opcode: pushing val of type " . ($val->type ? $val->type->kind : 'undef') . " val=" . ($val->isa('Brocken::Lindsay::IR::Constant') ? 'Const:' . $val->value : ($val->name // 'anon')) . "\n";
                        $mbb->add_instruction( $self->_wasm_push( $val, 'unop: val' ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => "${p}_${opcode}", operands => [], comment => $opcode
                            )
                        );
                        my $dst = Brocken::Jenny::MIR::MachineOperand->new(
                            kind => 'virt_reg', value => $inst->name, type => $inst->type
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'local_set', operands => [$dst], comment => 'store ' . $inst->name
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Br') ) {
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'jmp',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->dest_block->name ) ],
                                comment  => 'br ' . $inst->dest_block->name
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::CondBr') ) {
                        $mbb->add_instruction( $self->_wasm_push( $inst->operands->[0], 'cond' ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'bne',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->true_block->name ) ],
                                comment  => 'cond_br: true'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'jmp',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $inst->false_block->name ) ],
                                comment  => 'cond_br: false'
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Alloca') ) {
                        my $size = $inst->allocated_type->bits / 8;
                        # save current heap_ptr as result
                        $mbb->add_instruction( $self->_wasm_push_vreg('%heap_ptr', 'alloca: push heap') );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'local_set',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                                comment => 'alloca: save to ' . $inst->name
                            )
                        );
                        # heap_ptr += size
                        $mbb->add_instruction( $self->_wasm_push_vreg('%heap_ptr', 'alloca: push heap') );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'i32_const',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $size ) ],
                                comment  => "alloca: size $size"
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_add', operands => [], comment => 'alloca: add' )
                        );
                        $mbb->add_instruction( $self->_wasm_set_vreg('%heap_ptr', 'alloca: save heap') );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Load') ) {
                        my $ptr = $inst->operands->[0];
                        my $op;
                        if ($inst->type && $inst->type->kind eq 'float') {
                            $op = $inst->type->bits >= 64 ? 'f64_load' : 'f32_load';
                        }
                        else {
                            my $bits = $inst->type && $inst->type->kind eq 'int' ? $inst->type->bits : 32;
                            $op = $bits >= 64 ? 'i64_load' : 'i32_load';
                        }
                        $mbb->add_instruction( $self->_wasm_push($ptr, 'load: ptr') );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => $op, operands => [], comment => 'load' )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'local_set',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                                comment => 'load: save to ' . $inst->name
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Store') ) {
                        my ($val, $ptr) = $inst->operands->@*;
                        my $op;
                        if ($val->type && $val->type->kind eq 'float') {
                            $op = $val->type->bits >= 64 ? 'f64_store' : 'f32_store';
                        }
                        else {
                            my $bits = $val->type && $val->type->kind eq 'int' ? $val->type->bits : 32;
                            $op = $bits >= 64 ? 'i64_store' : 'i32_store';
                        }
                        $mbb->add_instruction( $self->_wasm_push($ptr, 'store: ptr') );
                        $mbb->add_instruction( $self->_wasm_push($val, 'store: val') );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => $op, operands => [], comment => 'store' )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Box') ) {
                        my $val = $inst->operands->[0];
                        my $tag = $self->_type_tag($val->type);
                        # save heap_ptr as result
                        $mbb->add_instruction( $self->_wasm_push_vreg('%heap_ptr', 'box: push heap') );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'local_set',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                                comment => 'box: save to ' . $inst->name
                            )
                        );
                        # heap_ptr += 16
                        $mbb->add_instruction( $self->_wasm_push_vreg('%heap_ptr', 'box: push heap') );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'i32_const',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 16 ) ],
                                comment  => 'box: bump 16'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_add', operands => [], comment => 'box: add' )
                        );
                        $mbb->add_instruction( $self->_wasm_set_vreg('%heap_ptr', 'box: save heap') );
                        # store payload at [%dyn + 0]
                        $mbb->add_instruction( $self->_wasm_push_vreg($inst->name, 'box: push dyn') );
                        $mbb->add_instruction( $self->_wasm_push($val, 'box: push val') );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_store', operands => [], comment => 'box: store payload' )
                        );
                        # store tag at [%dyn + 8]
                        $mbb->add_instruction( $self->_wasm_push_vreg($inst->name, 'box: push dyn') );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'i32_const',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 8 ) ],
                                comment  => 'box: offset 8'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_add', operands => [], comment => 'box: add offset' )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode   => 'i32_const',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $tag ) ],
                                comment  => 'box: tag'
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_store', operands => [], comment => 'box: store tag' )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Unbox') ) {
                        my $dyn = $inst->operands->[0];
                        $mbb->add_instruction( $self->_wasm_push($dyn, 'unbox: push dyn') );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'i32_load', operands => [], comment => 'unbox: load payload' )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'local_set',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                                comment => 'unbox: save to ' . $inst->name
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::ICmp') ) {
                        my ($lhs, $rhs) = $inst->operands->@*;
                        my $pred = $inst->predicate;
                        my $p;
                        my $float = $lhs->type && $lhs->type->kind eq 'float';
                        if ($float) {
                            $p = $lhs->type->bits >= 64 ? 'f64' : 'f32';
                        }
                        else {
                            my $bits = $lhs->type && $lhs->type->kind eq 'int' ? $lhs->type->bits : 32;
                            $p = $bits >= 64 ? 'i64' : 'i32';
                        }
                        my %map = $float
                            ? (eq => "${p}_eq", ne => "${p}_ne", lt => "${p}_lt", gt => "${p}_gt", le => "${p}_le", ge => "${p}_ge")
                            : (eq => "${p}_eq", ne => "${p}_ne", slt => "${p}_lt_s", sgt => "${p}_gt_s", sle => "${p}_le_s", sge => "${p}_ge_s", ult => "${p}_lt_u", ugt => "${p}_gt_u", ule => "${p}_le_u", uge => "${p}_ge_u");
                        $mbb->add_instruction( $self->_wasm_push( $lhs, 'icmp lhs' ) );
                        $mbb->add_instruction( $self->_wasm_push( $rhs, 'icmp rhs' ) );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => $map{$pred}, operands => [], comment => 'icmp ' . $pred
                            )
                        );
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'local_set',
                                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $inst->name ) ],
                                comment => 'icmp store'
                            )
                        );
                    }
                    elsif ( $inst->isa('Brocken::Lindsay::IR::Instruction::Ret') ) {
                        if ( $inst->type->kind ne 'void' ) {
                            my $val = $inst->operands->[0];
                            $mbb->add_instruction( $self->_wasm_push( $val, 'retval' ) );
                        }
                        $mbb->add_instruction(
                            Brocken::Jenny::MIR::MachineInstruction->new(
                                opcode => 'ret', operands => [], comment => ''
                            )
                        );
                    }
                }
                $mf->add_block($mbb);
            }
            return $mf;
        }

        method _wasm_push( $ir_val, $label ) {
            if ( $ir_val->isa('Brocken::Lindsay::IR::Constant') ) {
                my $op;
                if ($ir_val->type && $ir_val->type->kind eq 'float') {
                    $op = $ir_val->type->bits >= 64 ? 'f64_const' : 'f32_const';
                }
                else {
                    my $bits = $ir_val->type && $ir_val->type->kind eq 'int' ? $ir_val->type->bits : 32;
                    $op = $bits >= 64 ? 'i64_const' : 'i32_const';
                }
                return Brocken::Jenny::MIR::MachineInstruction->new(
                    opcode   => $op,
                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $ir_val->value ) ],
                    comment  => "push $label=" . $ir_val->value
                );
            }
            return Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'local_get',
                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $ir_val->name ) ],
                comment  => "push $label=" . $ir_val->name
            );
        }

        method _wasm_push_vreg( $name, $label ) {
            return Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'local_get',
                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $name ) ],
                comment  => $label
            );
        }

        method _wasm_set_vreg( $name, $label ) {
            return Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'local_set',
                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $name ) ],
                comment  => $label
            );
        }

        method _type_tag($type) {
            return 1 if $type->kind eq 'int' && $type->bits <= 32;
            return 2 if $type->kind eq 'int' && $type->bits == 64;
            return 6 if $type->kind eq 'int' && $type->bits == 128;
            return 3 if $type->kind eq 'float';
            return 4 if $type->kind eq 'ptr';
            return 5 if $type->kind eq 'dynamic';
            return 0;
        }
    }

    class Brocken::Jenny::Linker {

=pod

=head1 NAME

Brocken::Jenny::Linker - Unified Binary Executable Generator

=head1 DESCRIPTION

The Linker class provides a platform-agnostic interface for taking machine code and data segments and packaging them into a final executable
or shared library.

It handles:

=over 4

=item * B<Layout Calculation>: Assigning file offsets and Virtual Addresses (RVAs).

=item * B<Symbol Resolution>: Mapping internal labels to RVAs.

=item * B<Debug Information>: Generating DWARF sections for source-level debugging.

=item * B<FFI Stubbing>: Generating Import Tables (GOT/PLT) for calling external functions.

=back

=cut

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

        # Prepares the memory and file layout for the binary.
        # This must handle different alignment requirements:
        # - x86_64 ELF: 4KB (0x1000)
        # - ARM64 ELF: 64KB (0x10000) for compatibility with Android/modern kernels.
        # - Mach-O (Apple Silicon): 16KB (0x4000).
        # - PE (Windows): 512B (0x200) for files, 4KB (0x1000) for memory.
        method pre_layout( $text_size, $data_size, $platform, $debug = 0 ) {
            my $page_align
                = $platform->is_macos ? ( $platform->is_arm64 ? 0x4000 : 0x1000 ) :
                $platform->is_windows ? 0x200 :
                $platform->is_arm64 ?
                0x10000    # 64KB alignment for ARM64 ELF
                :
                0x1000;
            $_layout = Brocken::Jenny::Linker::Layout->new( file_align => $page_align, section_align => $page_align );
            $self->_setup_layout( $_layout, $text_size, $data_size, $platform, $debug );
            $_layout->calculate($page_align);
        }
        method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 )           {...}
        method write_bin( $filename, $text, $data, $arch, $os, $type ) {...}
        method import_rva($name)                                       {...}
    }

    class Brocken::Jenny::Linker::Layout {

=pod

=head1 NAME

Brocken::Jenny::Linker::Layout - Binary Section Alignment and Placement

=head1 DESCRIPTION

This class calculates the physical file offsets and relative virtual
addresses (RVAs) for binary sections.

=cut

        field $file_align    : param : reader = 0x200;
        field $section_align : param : reader = 0x1000;
        field @sections;
        field $header_size : reader = 0;

        method add_section( $name, $size, $flags ) {
            push @sections, { name => $name, size => ( $size || 1 ), flags => $flags, rva => 0, off => 0 };
        }

        # Computes the alignment-corrected offsets and RVAs.
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

            #~ warn "Layout Error: Section $n not found";
        }
        method sections() {@sections}
    }

    class Brocken::Jenny::Linker::DWARF : isa(Brocken::Jenny::Linker) {

=pod

=head1 NAME

Brocken::Jenny::Linker::DWARF - Debug Information Generator

=head1 DESCRIPTION

Generates DWARF v2/v3 compliant debug sections.

=head2 Sections Generated:

=over 4

=item * B<.debug_line>: Maps machine code offsets to source lines.

=item * B<.debug_info>: The main Debug Information Entry (DIE) tree.

=item * B<.debug_abbrev>: Definitions of DIE abbreviations.

=item * B<.debug_frame>: Stack unwinding and frame pointer recovery data.

=item * B<.debug_aranges>: Rapid lookup table for address ranges.

=item * B<.eh_frame>: Exception handling frame data (LSDA compatible).

=back

=cut

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

        # Generates the line number program.
        # Uses standard DWARF opcodes:
        # - 0x02: Set Address (Extended)
        # - 0x03: Advance Line (Signed)
        # - 0x01: Copy (Append row to matrix)
        method build_debug_line () {
            my @entries   = sort { $a->{offset} <=> $b->{offset} } @$source_locs;
            my $program   = '';
            my $prev_line = 1;
            my $prev_addr = $text_base;
            for my $e (@entries) {
                my $addr = $text_base + $e->{offset};
                my $line = $e->{line};

                # Set Address (Opcode 0x02)
                $program .= "\x00" . $self->_uleb(9) . "\x02" . pack( 'Q<', $addr );

                # Advance Line (Opcode 0x03)
                $program .= "\x03" . $self->_sleb( $line - $prev_line );

                # Copy row (Opcode 0x01)
                $program .= "\x01";
                $prev_line = $line;
            }

            # End of sequence
            my $max_offset = 0;
            for my $fn (@$func_ranges) { $max_offset = $fn->{end} if ( $fn->{end} // 0 ) > $max_offset; }
            $program .= "\x00" . $self->_uleb(9) . "\x02" . pack( 'Q<', $text_base + $max_offset );
            $program .= "\x00" . $self->_uleb(1) . "\x01";

            # Line Number Program Prologue
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

        # Defines abbreviations used in .debug_info to reduce redundant tags.
        method build_debug_abbrev () {
            my $abbrev = '';

            # Abbrev 1: DW_TAG_compile_unit (0x11)
            $abbrev .= $self->_uleb(1) . $self->_uleb(0x11) . $self->_uleb(1);
            $abbrev .= $self->_uleb(0x10) . $self->_uleb(0x06);                  # DW_AT_stmt_list -> data4
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                  # DW_AT_name -> string
            $abbrev .= $self->_uleb(0x13) . $self->_uleb(0x0B);                  # DW_AT_language -> data1
            $abbrev .= $self->_uleb(0x11) . $self->_uleb(0x01);                  # DW_AT_low_pc -> addr
            $abbrev .= $self->_uleb(0x12) . $self->_uleb(0x01);                  # DW_AT_high_pc -> addr
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 2: DW_TAG_base_type (0x24)
            $abbrev .= $self->_uleb(2) . $self->_uleb(0x24) . $self->_uleb(0);
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                  # DW_AT_name -> string
            $abbrev .= $self->_uleb(0x0B) . $self->_uleb(0x0B);                  # DW_AT_byte_size -> data1
            $abbrev .= $self->_uleb(0x3E) . $self->_uleb(0x0B);                  # DW_AT_encoding -> data1
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 3: DW_TAG_subprogram (0x2E)
            $abbrev .= $self->_uleb(3) . $self->_uleb(0x2E) . $self->_uleb(1);
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                  # DW_AT_name
            $abbrev .= $self->_uleb(0x11) . $self->_uleb(0x01);                  # low_pc
            $abbrev .= $self->_uleb(0x12) . $self->_uleb(0x01);                  # high_pc
            $abbrev .= $self->_uleb(0x40) . $self->_uleb(0x18);                  # frame_base -> exprloc
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 4: DW_TAG_formal_parameter (0x05) / Abbrev 5: DW_TAG_variable (0x34)
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

        # Generates the main DIE tree describing functions, parameters, and types.
        method build_debug_info () {
            my $max_pc = 0;
            for my $fn (@$func_ranges) { $max_pc = $fn->{end} if ( $fn->{end} // 0 ) > $max_pc; }
            my $cu_body = '';
            $cu_body .= $self->_uleb(1);                       # DW_TAG_compile_unit
            $cu_body .= pack( 'L<', 0 );                       # stmt_list (offset into .debug_line)
            $cu_body .= "$source_file\0";
            $cu_body .= pack( 'C',  12 );                      # language (C99 - DW_LANG_C99)
            $cu_body .= pack( 'Q<', $text_base );              # low_pc
            $cu_body .= pack( 'Q<', $text_base + $max_pc );    # high_pc
            my $CU_HEADER_SIZE = 11;
            my $type_off       = {};

            # Built-in types
            for my $t ( [ 'Int', 5 ], [ 'Bool', 2 ], [ 'String', 1 ], [ 'Any', 1 ], [ 'ptr', 1 ], [ 'Array', 1 ] ) {
                $type_off->{ $t->[0] } = $CU_HEADER_SIZE + length($cu_body);
                $cu_body .= $self->_uleb(2) . "$t->[0]\0" . pack( 'CC', 8, $t->[1] );
            }

            # Function DIEs
            for my $fn ( sort { $a->{start} <=> $b->{start} } @$func_ranges ) {
                my $die_off = $CU_HEADER_SIZE + length($cu_body);
                push @pubnames, { offset => $die_off, name => ( $fn->{name} =~ s/^M_//r ) };
                $cu_body .= $self->_uleb(3);    # DW_TAG_subprogram
                $cu_body .= "$fn->{name}\0";
                $cu_body .= pack( 'Q<', $text_base + $fn->{start} );
                $cu_body .= pack( 'Q<', $text_base + ( $fn->{end} // $fn->{start} ) );

                # frame_base (DW_AT_frame_base: typically RBP relative on x64, X29 on ARM64)
                my $fb = pack( 'C', 0x70 + ( $arch =~ /aarch64|arm64/i ? 29 : 6 ) ) . "\x00";
                $cu_body .= $self->_uleb( length($fb) ) . $fb;

                # Parameter and Local Variable DIEs
                for my $v ( @{ $fn->{params} // [] }, @{ $fn->{locals} // [] } ) {
                    $cu_body .= $self->_uleb( exists $v->{slot} ? 5 : 4 );
                    ( my $n = $v->{name} ) =~ s/^\$//;
                    $cu_body .= "$n\0";

                    # Variable Location (DW_OP_fbreg + sleb128 offset)
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

        # Unsigned LEB128 encoding (Variable length integer)
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

        # Signed LEB128 encoding
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

        # Call Frame Information (CFI) for stack unwinding.
        method build_debug_frame () {

            # Basic CIE (Common Information Entry)
            # - code_alignment_factor: 1
            # - data_alignment_factor: -8
            # - return_address_register: 16 (x64), 30 (ARM64), or 1 (RISC-V ra)
            my $cie_ra  = $arch =~ /aarch64|arm64/i ? 30 : ( $arch eq 'riscv64' ? 1 : 16 );
            my $cie_cfa = $arch =~ /aarch64|arm64/i ? 31 : ( $arch eq 'riscv64' ? 2 : 7 );
            my $cie_fp  = $arch =~ /aarch64|arm64/i ? 29 : ( $arch eq 'riscv64' ? 8 : 6 );
            my $cie_body = pack( 'C', 3 ) . "\0" . $self->_uleb(1) . $self->_sleb(-8);
            $cie_body .= pack( 'C', $cie_ra );

            # Initial instructions: DW_CFA_def_cfa (0x0C) SP+8
            $cie_body .= "\x0C" . $self->_uleb($cie_cfa) . $self->_uleb(8);

            # Tell DWARF where the return address is saved (offset 1 * -8 from CFA)
            # DW_CFA_offset (0x80 | reg)
            if ( $arch eq 'x64' || $arch eq 'riscv64' ) {
                $cie_body .= pack( 'C', 0x80 | $cie_ra ) . $self->_uleb(1);
            }
            my $cie_pad = ( 8 - ( ( length($cie_body) + 8 ) % 8 ) ) % 8;
            $cie_body .= "\0" x $cie_pad;
            my $data = pack( 'L<', length($cie_body) + 4 ) . pack( 'L<', 0xFFFFFFFF ) . $cie_body;

            # FDE (Frame Description Entry) per function
            for my $fn (@$func_ranges) {

                # DW_CFA_def_cfa FP, offset (context_size + 8)
                my $instr           = "\x0C" . $self->_uleb($cie_fp) . $self->_uleb( $context_size + 8 );
                my $offset_from_cfa = -16;

                # Register preservation mapping
                for my $r (@$preserved_regs) {
                    my $reg_num      = $self->dwarf_reg_num($r) // 0;
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

        # Exception Handling frame (LSDA compatible).
        # Similar to .debug_frame but used at runtime for stack walking.
        method build_eh_frame () {
            return '' unless $eh_frame_base;
            my $reg  = $arch =~ /aarch64|arm64/i ? 30 : ( $arch eq 'riscv64' ? 1 : 16 );
            my $cfa  = $arch =~ /aarch64|arm64/i ? 31 : ( $arch eq 'riscv64' ? 2 : 7 );
            my $fpr  = $arch =~ /aarch64|arm64/i ? 29 : ( $arch eq 'riscv64' ? 8 : 6 );

            # CIE with 'zR' augmentation for pcrel FDE encoding
            my $cie_body = pack( 'C', 1 ) . "zR\0" . $self->_uleb(1) . $self->_sleb(-8);
            $cie_body .= pack( 'C', $reg );

            # Augmentation data length + FDE encoding (pcrel|sdata4 = 0x1B)
            $cie_body .= $self->_uleb(1) . "\x1B";

            # Initial instructions: def_cfa SP+8, offset ra at cfa-8
            $cie_body .= "\x0C" . $self->_uleb($cfa) . $self->_uleb(8);
            $cie_body .= pack( 'C', 0x80 | $reg ) . $self->_uleb(1);
            my $cie_pad = ( 4 - ( ( length($cie_body) + 4 ) % 4 ) ) % 4;
            $cie_body .= "\0" x $cie_pad;
            my $data = pack( 'L<', length($cie_body) + 4 ) . pack( 'L<', 0 ) . $cie_body;
            for my $fn (@$func_ranges) {
                my $fn_start = $fn->{start};
                my $fn_len   = ( $fn->{end} // $fn->{start} + 1 ) - $fn->{start};
                my $instr    = "\x0C" . $self->_uleb($fpr) . $self->_uleb( $context_size + 8 );
                for my $r (@$preserved_regs) {
                    my $reg_num      = $self->dwarf_reg_num($r) // 0;
                    my $factored_off = -16 / -8;
                    $instr .= pack( 'C', 0x80 | $reg_num ) . $self->_uleb($factored_off);
                }

                # pcrel initial_location: the file-relative offset to fn_start
                my $fde_body = pack( 'L<', $fn_start ) . pack( 'L<', $fn_len ) . $instr;
                my $fde_pad  = ( 4 - ( ( length($fde_body) + 4 ) % 4 ) ) % 4;
                $fde_body .= "\0" x $fde_pad;

                # CIE_pointer = offset of CIE_pointer_field - CIE_offset
                my $fde_offset = length($data);
                $data .= pack( 'L<', length($fde_body) + 4 ) . pack( 'L<', $fde_offset + 4 ) . $fde_body;
            }
            return $data;
        }
    };

    class Brocken::Jenny::Linker::MachO : isa(Brocken::Jenny::Linker) {

=pod

=head1 NAME

Brocken::Jenny::Linker::MachO - 64-bit Mach-O Executable Generator

=head1 DESCRIPTION

Generates Mach-O binaries compliant with macOS (Darwin) kernels.

=head2 Load Commands

Mach-O files use "Load Commands" to guide the dynamic linker (dyld).

=over 4

=item * B<LC_SEGMENT_64>: Maps file regions into virtual memory.

=item * B<LC_LOAD_DYLINKER>: Points to C</usr/lib/dyld>.

=item * B<LC_LOAD_DYLIB>: Links against C<libSystem.B.dylib>.

=item * B<LC_MAIN>: Specifies the C<_start> entry point offset.

=item * B<LC_DYLD_INFO_ONLY>: Describes exports and binding opcodes.

=back

=head2 Apple Silicon (ARM64) Quirks

=over 4

=item * B<Page Size>: Must be 16KB (0x4000).

=item * B<Code Signing>: ARM64 macOS strictly forbids execution of
unsigned binaries. We apply an ad-hoc signature using C<codesign -s ->.

=back

=cut

        field $has_ffi : reader = false;
        method set_has_ffi($v) { $has_ffi = $v; }

        method _setup_layout( $layout, $text_size, $data_size, $arch, $os, $dbg = 0 ) {
            $layout->add_section( '.text',     $text_size,           5 );                      # Read + Execute
            $layout->add_section( '.data',     $data_size,           3 ) if $data_size > 0;    # Read + Write
            $layout->add_section( '.got',      512,                  3 ) if $has_ffi;          # Global Offset Table
            $layout->add_section( '.linkedit', $has_ffi ? 4096 : 64, 1 );                      # Symbols, Strings, Dynamic linking info
            if ( $dbg >= 1 ) {
                $layout->add_section( '.debug_line',     4096, 0 );
                $layout->add_section( '.debug_info',     8192, 0 );
                $layout->add_section( '.debug_abbrev',   4096, 0 );
                $layout->add_section( '.debug_frame',    8192, 0 );
                $layout->add_section( '.debug_aranges',  4096, 0 );
                $layout->add_section( '.debug_pubnames', 4096, 0 );
            }
        }

        method import_rva($name) {
            my $imports = { dlopen => 0, dlsym => 8, pthread_create => 16 };
            return $self->layout->get('.got')->{rva} + ( $imports->{$name} // die 'Unknown Mach-O import: ' . $name );
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
                my $entry_stub = '';
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
                    $entry_stub = pack( 'V5', 0x94000005, $movz, $movk, 0xD4001001, 0xD4200000 );
                }
                else {
                    # x86_64 (Intel Mac) native exit stub:
                    # - call main:      e8 0c 00 00 00 (Relative call 12 bytes ahead)
                    # - mov rdi, rax:   48 89 c7       (Copy main's return code to first argument)
                    # - mov eax, sys:   b8 ...         (0x2000001 is exit syscall with macOS offset)
                    # - syscall:        0f 05
                    # - ud2:            0f 0b
                    $entry_stub = pack( 'C V', 0xE8, 12 );
                    $entry_stub .= pack( 'C3',  0x48, 0x89, 0xC7 );
                    $entry_stub .= pack( 'C V', 0xB8, $exit_sys );
                    $entry_stub .= pack( 'C2',  0x0F, 0x05 );
                    $entry_stub .= pack( 'C2',  0x0F, 0x0B );
                }
                $text = $entry_stub . $text_raw;
            }

            # Automatically calculate layout if it wasn't called beforehand
            if ( !defined $self->layout ) {
                $self->pre_layout( length($text), length($data_bytes), $platform );
            }
            my $base           = $self->image_base;
            my $page_size      = $platform->page_size;                                       # 16KB for Apple Silicon, 4KB for Intel
            my $cputype        = ( $arch =~ /aarch64|arm64/i ) ? 0x0100000c : 0x01000007;    # CPU_TYPE_ARM64 or CPU_TYPE_X86_64
            my $cpusubtype     = ( $arch =~ /aarch64|arm64/i ) ? 0          : 3;             # CPU_SUBTYPE_ARM64_ALL or CPU_SUBTYPE_I386_ALL
            my $filetype       = ( $self->type eq 'shared' ) ? 6 : 2;                        # MH_DYLIB or MH_EXECUTE
            my @debug_sections = grep { $_->{name} =~ /^\.debug/ } $self->layout->sections;
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
            my $got_sec        = $self->layout->get('.got');
            if ($got_sec) {
                my $data_sec = $self->layout->get('.data');
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

            # Hand-assemble both defined exports and undefined external imports
            # to make sure dyld dynamic linking validations are strictly met.
            my ( $trie, $symtab, $strtab, $lc_id_dylib ) = ( '', '', '', '' );
            my ( $num_syms, $le_off, $trie_size, $symtab_size, $strtab_size ) = ( 0, 0, 0, 0, 0 );
            my @syms;
            my %sym_types;
            my %sym_rvas;

            # Undefined dynamic external imports
            if ($got_sec) {
                for my $name ( '_dlopen', '_dlsym', '_pthread_create' ) {
                    push @syms, $name;
                    $sym_types{$name} = 0x01;    # N_UNDF | N_EXT
                    $sym_rvas{$name}  = 0;
                }
            }

            # Defined exports if shared library
            if ( $self->type eq 'shared' ) {
                require File::Basename;
                my $dylib_name     = File::Basename::basename($output_file);
                my $dylib_name_pad = $dylib_name . "\0";
                while ( length($dylib_name_pad) % 8 != 0 ) { $dylib_name_pad .= "\0"; }

                # LC_ID_DYLIB (Identifies the output dylib name)
                $lc_id_dylib = pack( 'L<6', 0xD, 24 + length($dylib_name_pad), 24, 1, 1, 1 ) . $dylib_name_pad;
                my @exports = @{ $self->exported_funcs // [] };
                for my $name (@exports) {
                    my $mangled = "_$name";
                    push @syms, $mangled;
                    $sym_types{$mangled} = 0x0f;                                                                       # N_SECT | N_EXT
                    $sym_rvas{$mangled}  = $self->layout->get('.text')->{rva} + ( $self->labels->{"E_$name"} // 0 );
                }
            }

            # Sort symbol definitions for LC_DYSYMTAB layout rules (defined first, then undefined)
            my @defined_ext   = grep { $sym_types{$_} == 0x0f } @syms;
            my @undefined_ext = grep { $sym_types{$_} == 0x01 } @syms;
            my @sorted_syms   = ( @defined_ext, @undefined_ext );
            $num_syms = scalar @sorted_syms;

            # Build string table
            $strtab = "\0";
            my %strx;
            for my $sym (@sorted_syms) {
                $strx{$sym} = length($strtab);
                $strtab .= $sym . "\0";
            }
            while ( length($strtab) % 8 != 0 ) { $strtab .= "\0"; }

            # Build symbol table entries (nlist_64 structures)
            for my $sym (@sorted_syms) {
                my $type = $sym_types{$sym};
                my $sect = ( $type == 0x0f ) ? 1                           : 0;
                my $val  = ( $type == 0x0f ) ? ( $base + $sym_rvas{$sym} ) : 0;
                $symtab .= pack( 'L< C C S< Q<', $strx{$sym}, $type, $sect, 0, $val );
            }

            # Build the Export Trie if compiling a shared dylib containing exports
            my $nextdefsym = scalar(@defined_ext);
            my $nundefsym  = scalar(@undefined_ext);
            if ( $self->type eq 'shared' && $nextdefsym > 0 ) {
                my @nodes;
                for my $sym (@defined_ext) {
                    my $rva        = $sym_rvas{$sym};
                    my $flags_u    = $_uleb->(0);
                    my $rva_u      = $_uleb->($rva);
                    my $term_data  = $flags_u . $rva_u;
                    my $node_bytes = $_uleb->( length($term_data) ) . $term_data . pack( 'C', 0 );
                    push @nodes, { sym => $sym, bytes => $node_bytes };
                }
                my %node_offsets;
                for ( 1 .. 3 ) {
                    my $root = pack( 'C', 0 ) . pack( 'C', $nextdefsym );
                    for my $n (@nodes) { $root .= $n->{sym} . "\0" . $_uleb->( $node_offsets{ $n->{sym} } // 1024 ); }
                    my $offset = length($root);
                    for my $n (@nodes) {
                        $node_offsets{ $n->{sym} } = $offset;
                        $offset += length( $n->{bytes} );
                    }
                }
                $trie = pack( 'C', 0 ) . pack( 'C', $nextdefsym );
                for my $n (@nodes) { $trie .= $n->{sym} . "\0" . $_uleb->( $node_offsets{ $n->{sym} } ); }
                for my $n (@nodes) { $trie .= $n->{bytes}; }
                while ( length($trie) % 8 != 0 ) { $trie .= "\0"; }
            }
            $trie_size   = length($trie);
            $symtab_size = length($symtab);
            $strtab_size = length($strtab);

            # Enforce Minimum Linkedit size to prevent sparse file truncation issues
            my $le_payload_size = length($bind_info) + $trie_size + $symtab_size + $strtab_size;
            $self->layout->get('.linkedit')->{size} = $le_payload_size > 64 ? $le_payload_size : 64;
            $self->layout->calculate($page_size);
            $le_off = $self->layout->get('.linkedit')->{off};
            my %seg_names = ( '.text' => '__TEXT', '.data' => '__DATA', '.got' => '__DATA' );
            my %sec_names = ( '.text' => '__text', '.data' => '__data', '.got' => '__got' );
            for my $s ( $self->layout->sections ) {
                if ( $s->{name} =~ /^\.debug_/ ) {
                    $seg_names{ $s->{name} } = '__DWARF';
                    ( my $macho_name = $s->{name} ) =~ s/^\./__/;
                    $sec_names{ $s->{name} } = $macho_name;
                }
            }
            my @text_sections = grep { $_->{name} eq '.text' } $self->layout->sections;
            my $t_sec         = $text_sections[0];
            my @data_sections = grep { $_->{name} eq '.data' || $_->{name} eq '.got' } $self->layout->sections;
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
            # Reference: https://opensource.apple.com/source/xnu/xnu-4570.1.46/EXTERNAL_HEADERS/mach-o/loader.h
            if ( $self->type ne 'shared' ) {
                push @cmds, pack(
                    'L<2 a16 Q<4 L<4', 0x19,    # cmd (LC_SEGMENT_64)
                    72,                         # cmdsize
                    '__PAGEZERO',               # segname
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
                '__TEXT',                   # segname
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
                    '__TEXT',   $base + $s->{rva},
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
                    '__DATA',                   # segname
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
                        '__DATA',   $base + $s->{rva},
                        $s->{size}, $s->{off}, 3, 0, 0, 0, 0, 0, 0
                    );
                }
                push @cmds, $d_cmd;
            }

            # LINKEDIT Segment Header
            my $le_sec      = $self->layout->get('.linkedit');
            my $le_seg_size = ( $le_sec->{size} + $page_size - 1 ) & ~( $page_size - 1 );
            push @cmds, pack(
                'L<2 a16 Q<4 L<4', 0x19,    # cmd (LC_SEGMENT_64)
                72,                         # cmdsize
                '__LINKEDIT',               # segname
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
            my $export_off = ( $self->type eq 'shared' && $nextdefsym > 0 ) ? $le_off + length($bind_info) : 0;
            my $export_sz  = ( $self->type eq 'shared' && $nextdefsym > 0 ) ? $trie_size                   : 0;
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
            my $iextdefsym = 0;
            my $iundefsym  = $nextdefsym;
            push @cmds, pack(
                'L<20', 0xB,                   # cmd
                80,                            # cmdsize
                0,           0,                # ilocalsym, nlocalsym
                $iextdefsym, $nextdefsym,      # iextdefsym, nextdefsym
                $iundefsym,  $nundefsym,       # iundefsym, nundefsym
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
                    0x19, $cmdsize, '__DWARF', $base + $dw_start_rva,
                    $dw_size_aligned, $dw_start_off, $dw_size_aligned, 0, 0, scalar(@debug_sections), 0 );
                for my $s (@debug_sections) {
                    $dw_cmd .= pack(
                        'a16 a16 Q<2 L<2 L<3 L<2 L<',
                        $sec_names{ $s->{name} },
                        '__DWARF',  $base + $s->{rva},
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
            my $d_sec_actual = $self->layout->get('.data');
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

            # ARM64 macOS mandatory ad-hoc signature
            if ( $os =~ /^(macos|darwin)/i ) {
                my $cs_out = `codesign -f -s - "$output_file" 2>&1`;
                warn 'codesign output: ' . $cs_out if length $cs_out;
                warn 'codesign exit: ' . ( $? >> 8 ) . "\n";
            }
            return $output_file;
        }
    }

    class Brocken::Jenny::Linker::PE : isa(Brocken::Jenny::Linker) {
        field $ENABLE_COFF = 0;

=pod

=head1 NAME

Brocken::Jenny::Linker::PE - 64-bit Portable Executable (PE32+) Generator

=head1 DESCRIPTION

Generates PE binaries for modern 64-bit Windows (x86_64 and ARM64).

=head2 Binary Structure

=over 4

=item * B<DOS MZ Header>: Legacy 64-byte header for compatibility.

=item * B<PE Signature>: "PE\0\0" magic.

=item * B<COFF File Header>: Specifies machine type and section count.

=item * B<Optional Header>: The real PE32+ header containing entry point,
image base, and security flags.

=back

=head2 Windows ARM64 Quirk

Windows on ARM64 strictly mandates the presence of a Base Relocation
Table (C<.reloc> section) even for executables that don't technically
need it. If omitted, the loader throws a "Corrupt Executable" error.
We generate a dummy relocation block to satisfy this.

=head2 Security Flags

We enable several modern Windows security features:

=over 4

=item * B<NX_COMPAT>: No-Execute/Data Execution Prevention (DEP).

=item * B<DYNAMIC_BASE>: ASLR support.

=item * B<HIGH_ENTROPY_VA>: 64-bit ASLR (high entropy).

=back

=cut

        method write_executable ( $output_file, $code_bytes, $platform, $passed_argument = undef, $debug_bytes = undef ) {

            # Ensure $platform is normalized into a platform object if a raw string is passed
            $platform = Brocken::Katsuro::Platform::parse($platform) unless ref $platform;
            my $full_code    = ref $code_bytes eq 'HASH' ? $code_bytes->{binary}                        : $code_bytes;
            my $writable_off = ref $code_bytes eq 'HASH' ? ( $code_bytes->{writable_data_offset} // 0 ) : 0;
            my $text_raw     = $writable_off             ? substr( $full_code, 0, $writable_off )       : $full_code;
            my $data_bytes   = $writable_off             ? substr( $full_code, $writable_off )          : '';
            my $text         = $text_raw;
            if ( $self->type eq 'exe' ) {
                my $entry_stub = '';
                if ( $platform->is_arm64 ) {

                    # Windows ARM64 Entry Stub:
                    # - stp x29, x30, [sp, #-16]!
                    # - mov x29, sp
                    # - bl main (relative call offset +12 bytes -> 3 instructions)
                    # - ldp x29, x30, [sp], #16
                    # - ret
                    $entry_stub = pack( 'V5', 0xA9BF7BFD, 0x910003FD, 0x94000003, 0xA8C17BFD, 0xD65F03C0 );
                }
                else {
                    # Windows x86_64 Entry Stub (with shadow space):
                    # - sub rsp, 40
                    # - call main (+5 bytes ahead)
                    # - add rsp, 40
                    # - ret
                    $entry_stub = pack( 'C4', 0x48, 0x83, 0xEC, 0x28 );
                    $entry_stub .= pack( 'C V', 0xE8, 5 );
                    $entry_stub .= pack( 'C4',  0x48, 0x83, 0xC4, 0x28 );
                    $entry_stub .= pack( 'C',   0xC3 );
                }
                $text = $entry_stub . $text_raw;
            }
            my $text_bytes = $text;
            my $has_data   = length($data_bytes) > 0;
            my $has_debug  = defined $debug_bytes ? 1 : 0;
            my $has_reloc  = 1;                              # ARM64 Windows strictly enforces ASLR / .reloc presence

            # Check for dynamic exports to write the .edata payload
            my $has_exports        = ( ref $self->exported_funcs eq 'ARRAY' && scalar( @{ $self->exported_funcs } ) > 0 ) ? 1 : 0;
            my $edata_bytes        = '';
            my $sec_raw_edata_size = 0;
            my $edata_rva          = 0;
            my @sorted_exports     = ();
            if ($has_exports) {
                my $text_rva = 0x1000;
                my $data_rva = 0x1000 + ( ( length($text_bytes) + 4095 ) & ~4095 );
                $edata_rva = $data_rva;
                if ($has_data) {
                    $edata_rva += ( ( length($data_bytes) + 4095 ) & ~4095 );
                }

                # Initialize with 40 placeholder bytes for the Export Directory Table at offset 0
                $edata_bytes = "\x00" x 40;
                require File::Basename;
                my $dll_name     = File::Basename::basename($output_file);
                my $dll_name_off = length($edata_bytes);
                $edata_bytes .= $dll_name . "\0";
                @sorted_exports = sort @{ $self->exported_funcs };
                my %name_offsets;

                for my $name (@sorted_exports) {
                    $name_offsets{$name} = length($edata_bytes);
                    $edata_bytes .= $name . "\0";
                }
                my $eat_off = length($edata_bytes);
                for my $name (@sorted_exports) {
                    my $label_val = $self->labels->{"E_$name"} // $self->labels->{$name} // 0;
                    my $func_rva  = $text_rva + $label_val;
                    $edata_bytes .= pack( 'V', $func_rva );
                }
                my $enpt_off = length($edata_bytes);
                for my $name (@sorted_exports) {
                    my $name_rva = $edata_rva + $name_offsets{$name};
                    $edata_bytes .= pack( 'V', $name_rva );
                }
                my $eot_off = length($edata_bytes);
                my $idx     = 0;
                for my $name (@sorted_exports) {
                    $edata_bytes .= pack( 'v', $idx++ );
                }

                # Pad with 4 trailing null bytes to satisfy strict peXXigen.c bounds checks (offset + size < datasize)
                $edata_bytes .= "\x00" x 4;

                # Overwrite the first 40 bytes with the actual Export Directory Table
                my $timestamp        = $ENV{SOURCE_DATE_EPOCH} || time();
                my $export_dir_table = pack( 'V2 v2 V7',
                    0, $timestamp, 0, 0, $edata_rva + $dll_name_off,
                    1, scalar(@sorted_exports), scalar(@sorted_exports),
                    $edata_rva + $eat_off,
                    $edata_rva + $enpt_off,
                    $edata_rva + $eot_off );
                substr( $edata_bytes, 0, 40, $export_dir_table );
            }
            my $num_sections = 1 + ( $has_data ? 1 : 0 ) + ( $has_exports ? 1 : 0 ) + $has_reloc + ( $has_debug ? 1 : 0 );
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

            # COFF File Header (Exactly 20 bytes)
            # Reference: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#coff-file-header-object-and-image
            my $machine   = $platform->is_arm64 ? 0xAA64 : 0x8664;    # IMAGE_FILE_MACHINE_ARM64 or AMD64
            my $timestamp = $ENV{SOURCE_DATE_EPOCH} || time();

            # Layout sections
            my $section_table   = '';
            my $size_of_headers = ( 392 + ( $num_sections * 40 ) + 511 ) & ~511;
            my $sec_raw_ptr     = $size_of_headers;
            my $sec_rva         = 0x1000;

            # .text section (Code)
            my $sec_raw_code_size = ( length($text_bytes) + 511 ) & ~511;
            $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                ".text\x00\x00\x00", length($text_bytes), $sec_rva, $sec_raw_code_size, $sec_raw_ptr, 0, 0, 0, 0, 0x60000020 );
            $sec_rva     += ( length($text_bytes) + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_code_size;

            # .data section (Initialized Data)
            my $sec_raw_data_size = 0;
            if ($has_data) {
                $sec_raw_data_size = ( length($data_bytes) + 511 ) & ~511;
                $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                    ".data\x00\x00\x00", length($data_bytes), $sec_rva, $sec_raw_data_size, $sec_raw_ptr, 0, 0, 0, 0, 0xC0000040 );
                $sec_rva     += ( length($data_bytes) + 4095 ) & ~4095;
                $sec_raw_ptr += $sec_raw_data_size;
            }

            # .edata section
            if ($has_exports) {
                $sec_raw_edata_size = ( length($edata_bytes) + 511 ) & ~511;
                $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                    ".edata\x00\x00", length($edata_bytes), $sec_rva, $sec_raw_edata_size, $sec_raw_ptr, 0, 0, 0, 0, 0x40000040 );
                $sec_rva     += ( length($edata_bytes) + 4095 ) & ~4095;
                $sec_raw_ptr += $sec_raw_edata_size;
            }

            # .reloc section (Mandatory for ARM64)
            my $reloc_bytes        = pack( 'V V v v', 0x1000, 12, 0, 0 );     # Base RVA, Block Size, TypeOffset entries (empty)
            my $reloc_rva          = $sec_rva;
            my $sec_raw_reloc_size = ( length($reloc_bytes) + 511 ) & ~511;
            $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                ".reloc\x00\x00", length($reloc_bytes), $sec_rva, $sec_raw_reloc_size, $sec_raw_ptr, 0, 0, 0, 0, 0x42000040 );
            $sec_rva     += ( length($reloc_bytes) + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_reloc_size;

            # .debug_l (Simplified debug section for Windows)
            my $sec_raw_debug_size = 0;
            if ($has_debug) {
                $sec_raw_debug_size = ( length($debug_bytes) + 511 ) & ~511;
                $section_table .= pack( 'a8 V2 V2 V2 v2 V', '.debug_l', length($debug_bytes), $sec_rva, $sec_raw_debug_size, $sec_raw_ptr, 0, 0, 0, 0,
                    0x42000040 );
                $sec_rva     += ( length($debug_bytes) + 4095 ) & ~4095;
                $sec_raw_ptr += $sec_raw_debug_size;
            }

            # Build the COFF Symbol Table (18 bytes per symbol) and String Table
            my $coff_symtab      = '';
            my $coff_strtab      = '';
            my $num_coff_symbols = 0;

            # Keeping legacy COFF Symbol Table fields zeroed out for pristine executables/libraries
            my $pointer_to_symbol_table = 0;
            if ( $ENABLE_COFF && $has_exports && scalar(@sorted_exports) > 0 ) {
                my $str_payload = '';
                my %coff_str_offsets;
                for my $name (@sorted_exports) {
                    $coff_str_offsets{$name} = 4 + length($str_payload);
                    $str_payload .= $name . "\0";
                }
                for my $name (@sorted_exports) {
                    my $label_val = $self->labels->{"E_$name"} // $self->labels->{$name} // 0;
                    my $func_rva  = 0x1000 + $label_val;                                         # .text section RVA starts at 0x1000
                    my $entry_name_field;
                    if ( length($name) <= 8 ) {
                        $entry_name_field = pack( 'a8', $name );
                    }
                    else {
                        $entry_name_field = pack( 'V2', 0, $coff_str_offsets{$name} );
                    }

                    # IMAGE_SYMBOL struct size is 18 bytes
                    $coff_symtab .= pack(
                        'a8 V v v C2', $entry_name_field,    # union: ShortName / Offset
                        $func_rva,                           # Value (Address relative to ImageBase)
                        1,                                   # SectionNumber (1-based index, .text is 1)
                        0x20,                                # Type (0x0020 = Function)
                        2,                                   # StorageClass (2 = External/Global)
                        0                                    # NumberOfAuxSymbols
                    );
                    $num_coff_symbols++;
                }
                if ( length($str_payload) > 0 ) {
                    $coff_strtab = pack( 'V', 4 + length($str_payload) ) . $str_payload;
                }

                # Position table offset directly after raw section data on disk
                $pointer_to_symbol_table = $sec_raw_ptr;
            }
            my $file_header = pack(
                'v2 V3 v2', $machine,        # Machine Architecture
                $num_sections,               # Number of Sections
                $timestamp,                  # TimeDateStamp
                $pointer_to_symbol_table,    # PointerToSymbolTable (zeroed for clean images)
                $num_coff_symbols,           # NumberOfSymbols (zeroed for clean images)
                240,                         # SizeOfOptionalHeader (240 bytes for PE32+)
                0x0022                       # Characteristics (EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE)
            );
            #
            my $size_of_image  = $sec_rva;
            my $size_of_code   = $sec_raw_code_size;
            my $init_data_size = $sec_raw_data_size + $sec_raw_reloc_size + $sec_raw_debug_size;
            my $os_ver         = 6;                                                                # Target Windows Vista/7+ compatibility

            # PE32+ Optional Header (Exactly 240 bytes)
            # Reference: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#optional-header-image-only
            my $opt_header = pack(
                'v C2 V3 V2 Q< V2 v4 v2 V V V V v2 Q<4 V2', 0x020b,                        # Magic Number (PE32+ 64-bit)
                14,                                         10,                            # Major/Minor LinkerVersion
                $size_of_code,                              $init_data_size, 0, 0x1000,    # AddressOfEntryPoint (RVA 0x1000)
                0x1000,                                                                    # BaseOfCode
                0x140000000,                                                               # ImageBase (Modern default 5GB base)
                4096,                                                                      # SectionAlignment
                512,                                                                       # FileAlignment
                $os_ver, 0,                                                                # Major/Minor OS
                0,       0,                                                                # Major/Minor Image
                $os_ver, 0,                                                                # Major/Minor Subsystem
                0,                                                                         # Win32VersionValue
                $size_of_image, $size_of_headers, 0,                                       # CheckSum (Optional for non-drivers)
                3,         # Subsystem (Windows Console)
                0x8160,    # DllCharacteristics (DYNAMIC_BASE | NX_COMPAT | TS_AWARE | HIGH_ENTROPY_VA)
                0x100000, 0x1000, 0x100000, 0x1000,    # Stack/Heap Reserve/Commit
                0,                                     # LoaderFlags
                16                                     # NumberOfRvaAndSizes (Data Directories)
            );

            # Data Directories (16 entries, 8 bytes each)
            my $data_dirs = "\x00" x 128;
            if ( ref $code_bytes eq 'HASH' ) {
                my $import_rva  = $code_bytes->{import_descriptor_rva}  // 0;
                my $import_size = $code_bytes->{import_descriptor_size} // 0;
                if ($import_rva) {

                    # Import Directory (Index 1)
                    substr $data_dirs, 8,  4, pack( 'V', $import_rva );
                    substr $data_dirs, 12, 4, pack( 'V', $import_size );
                }
            }
            #
            if ($has_exports) {

                # VirtualAddress points to standard RVA 0x2000; Size spans the entire export payload block
                substr $data_dirs, 0, 4, pack( 'V', $edata_rva );
                substr $data_dirs, 4, 4, pack( 'V', length($edata_bytes) );
            }

            # Insert Base Relocation Data Directory (Index 5 = Offset 40)
            substr $data_dirs, 40, 4, pack( 'V', $reloc_rva );
            substr $data_dirs, 44, 4, pack( 'V', length($reloc_bytes) );
            $opt_header .= $data_dirs;
            print $fh $dos_header, $dos_stub, $pe_signature, $file_header, $opt_header, $section_table;

            # Pad headers to FileAlignment
            my $headers_len
                = length($dos_header)
                + length($dos_stub)
                + length($pe_signature)
                + length($file_header)
                + length($opt_header)
                + length($section_table);
            print $fh ( "\x00" x ( $size_of_headers - $headers_len ) );

            # Write section payloads
            print $fh $text_bytes;
            print $fh ( "\x00" x ( $sec_raw_code_size - length($text_bytes) ) );
            if ($has_data) {
                print $fh $data_bytes;
                print $fh ( "\x00" x ( $sec_raw_data_size - length($data_bytes) ) );
            }
            if ($has_exports) {
                print $fh $edata_bytes;
                print $fh ( "\x00" x ( $sec_raw_edata_size - length($edata_bytes) ) );
            }
            if ($has_reloc) {
                print $fh $reloc_bytes;
                print $fh ( "\x00" x ( $sec_raw_reloc_size - length($reloc_bytes) ) );
            }
            if ($has_debug) {
                print $fh $debug_bytes;
                print $fh ( "\x00" x ( $sec_raw_debug_size - length($debug_bytes) ) );
            }

            # Append the dynamic COFF symbol table block at the calculated file offset
            if ( $pointer_to_symbol_table > 0 ) {
                print $fh $coff_symtab;
                print $fh $coff_strtab;
            }
            close $fh;
            chmod 0755, $output_file;
        }

        method write_shared_library ( $output_file, $code_bytes, $platform, $debug_bytes = undef ) {
            my $p = ref($platform) ? $platform : Brocken::Katsuro::Platform::parse($platform);
            $self->write_executable( $output_file, $code_bytes, $p, undef, $debug_bytes );
            open my $fh, '+<', $output_file or die $!;
            binmode $fh;
            seek $fh, 0x96, 0;                # Offset to COFF Characteristics
            print $fh pack( 'v', 0x2022 );    # EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE | IMAGE_FILE_DLL
            close $fh;
        }
    }

    class Brocken::Jenny::Linker::ELF64 : isa(Brocken::Jenny::Linker) {

=pod

=head1 NAME

Brocken::Jenny::Linker::ELF64 - 64-bit Executable and Linkable Format Generator

=head1 DESCRIPTION

Generates ELF64 binaries for Linux, BSDs, Haiku, and Solaris.

=head2 Binary Structure

=over 4

=item * B<Elf64_Ehdr>: Main header (64 bytes).

=item * B<Elf64_Phdr>: Program Headers defining memory segments (PT_LOAD, PT_DYNAMIC, etc.).

=item * B<Elf64_Shdr>: Section Headers describing the file's logical sections.

=back

=head2 Platform-Specific Workarounds

=over 4

=item * B<Haiku>: Requires C<_gSharedObjectHaikuABI> and C<_gSharedObjectHaikuVersion>
symbols in C<.dynsym> to enable modern POSIX APIs.

=item * B<BSDs>: FreeBSD, NetBSD, and DragonFly require C<environ> and
C<__progname> symbols to be mapped to writable memory to avoid early
crashes in C<libc> initialization.

=item * B<NetBSD>: Requires a C<PT_NOTE> containing C<NT_NETBSD_IDENT>
to be recognized as a native binary, plus PaX relaxation notes.

=item * B<OpenBSD>: Requires a C<PT_OPENBSD_PINTABLE> segment listing
allowed syscall entry points for its "syscall pinning" security feature.

=item * B<DragonFly BSD>: Requires a smaller C<PT_GNU_RELRO> segment
that doesn't overlap the GOT, or the dynamic linker will crash.

=back

=cut

        # Structurally compliant segment layout grouping all read-only sections
        # in the RX segment, and keeping only writable sections in the RW segment.
        method _setup_layout( $layout, $text_size, $data_size, $arch, $os, $dbg = 0 ) {

            #method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
            $layout->add_section( '.text', $text_size, 5 );    # RX (Read + Execute)

            # Read-only metadata sections (strictly mapped to RX segment)
            $layout->add_section( '.interp',   512,  2 ) if $self->type eq 'exe';
            $layout->add_section( '.dynstr',   4096, 2 );
            $layout->add_section( '.dynsym',   4096, 2 );
            $layout->add_section( '.rela.dyn', 4096, 2 );
            $layout->add_section( '.hash',     4096, 2 );

            # Writable data and dynamic linking tables (mapped to RW segment)
            $layout->add_section( '.dynamic', 4096,       3 );    # RW (Read + Write)
            $layout->add_section( '.data',    $data_size, 6 );    # RW
            $layout->add_section( '.got',     512,        6 );    # RW

            # Non-alloc symbol and string tables for static linking/debugging (nm)
            $layout->add_section( '.symtab', 4096, 0 );
            $layout->add_section( '.strtab', 4096, 0 );
            #
            if ( $dbg >= 1 ) {
                $layout->add_section( '.debug_line',     4096, 0 );
                $layout->add_section( '.debug_info',     4096, 0 );
                $layout->add_section( '.debug_abbrev',   4096, 0 );
                $layout->add_section( '.debug_frame',    4096, 0 );
                $layout->add_section( '.debug_aranges',  4096, 0 );
                $layout->add_section( '.debug_pubnames', 4096, 0 );
                $layout->add_section( '.eh_frame',       4096, 0 );
            }
        }

        method import_rva($name) {
            my $imports = { dlopen => 0, dlsym => 8, pthread_create => 16, exit => 24, _exit => 24 };
            return $self->layout->get('.got')->{rva} + ( $imports->{$name} // die 'Unknown ELF import: ' . $name );
        }
        method image_base () { return $self->type eq 'shared' ? 0 : 0x400000; }

        method write_executable ( $output_file, $code_bytes, $platform, $shared = false, $debug_bytes = undef ) {

            # Ensure $platform is normalized into a platform object if a raw string is passed
            $platform = Brocken::Katsuro::Platform::parse($platform) unless ref $platform;

            # Automatically calculate layout if it wasn't called beforehand
            if ( !defined $self->layout ) {

                # Allocate extra data space for platform-specific control variables
                my $extra_data = $platform->is_bsd ? 32 : ( $platform->is_haiku ? 8 : 0 );
                $self->pre_layout( length($code_bytes) + 32, $extra_data, $platform );
            }
            my $l          = $self->layout;
            my $is_pie     = $platform->is_bsd || $platform->is_haiku;
            my $base       = $is_pie ? 0 : $self->image_base;
            my $elf_type   = $shared ? 3 : ( $is_pie ? 3 : 2 );    # ET_DYN (3) for PIE, ET_EXEC (2) for static
            my $text_rva   = $self->layout->get('.text')->{rva};
            my $got_rva    = $self->layout->get('.got')->{rva};
            my $page_align = $self->layout->section_align;
            my $text       = $code_bytes;

            if ( $self->type eq 'exe' ) {
                my $entry_stub = '';
                if ( $platform->is_arm64 ) {

                    # ARM64 Dynamic Exit Stub:
                    # - bl main
                    # - adrp x8, :got:exit
                    # - ldr x8, [x8, :got_lo12:exit]
                    # - blr x8
                    # - brk #0
                    my $got_exit  = $got_rva + 24;
                    my $adrp_pc   = $text_rva + 4;
                    my $page_diff = ( $got_exit >> 12 ) - ( $adrp_pc >> 12 );
                    $page_diff &= 0x1FFFFF;
                    my $immlo   = $page_diff & 3;
                    my $immhi   = ( $page_diff >> 2 ) & 0x7FFFF;
                    my $adrp    = 0x90000000 | ( $immlo << 29 ) | ( $immhi << 5 ) | 8;
                    my $pimm    = ( $got_exit & 0xFFF ) >> 3;
                    my $ldr     = 0xF9400000 | ( $pimm << 10 ) | ( 8 << 5 ) | 8;
                    my $blr     = 0xD63F0100;
                    my $bl_main = 0x94000005;
                    my $brk     = 0xD4200000;
                    $entry_stub = pack( 'V5', $bl_main, $adrp, $ldr, $blr, $brk );
                }
                elsif ( $platform->is_riscv64 ) {

                    # RISC-V 64-bit Entry Stub:
                    # - jal ra, main
                    # - auipc t0, %pcrel_hi(exit)
                    # - ld t0, %pcrel_lo(auipc)(t0)
                    # - jalr ra, t0
                    # - ebreak
                    my $got_exit   = $got_rva + 24;
                    my $auipc_pc   = $text_rva + 4;
                    my $diff       = $got_exit - $auipc_pc;
                    my $hi20       = ( $diff + 0x800 ) >> 12;
                    my $lo12       = $diff & 0xFFF;
                    my $auipc      = ( ( $hi20 & 0xFFFFF ) << 12 ) | ( 5 << 7 ) | 0x17;
                    my $ld         = ( ( $lo12 & 0xFFF ) << 20 ) | ( 5 << 15 ) | ( 3 << 12 ) | ( 5 << 7 ) | 0x03;
                    my $jalr       = ( 0 << 20 ) | ( 5 << 15 ) | ( 0 << 12 ) | ( 0 << 7 ) | 0x67;
                    my $jal_offset = 20;
                    my $jal_imm = ( ( $jal_offset >> 20 ) & 1 ) << 31 | ( ( $jal_offset >> 1 ) & 0x3FF ) << 21 | ( ( $jal_offset >> 11 ) & 1 ) << 20
                        | ( ( $jal_offset >> 12 ) & 0xFF ) << 12;
                    my $jal    = $jal_imm | ( 1 << 7 ) | 0x6F;
                    my $ebreak = 0x00100073;
                    $entry_stub = pack( 'V5', $jal, $auipc, $ld, $jalr, $ebreak );
                }
                else {
                    # x86_64 Dynamic Exit Stub with System V RSP alignment.
                    # Reference: https://eg/ABI.md Section 1.1
                    my $got_exit = $got_rva + 24;
                    my $next_ip  = $text_rva + 18;
                    my $rel32    = $got_exit - $next_ip;
                    $entry_stub = pack( 'C4', 0x48, 0x83, 0xE4, 0xF0 );    # and rsp, -16
                    $entry_stub .= pack( 'C V',   0xE8, 11 );              # call main (rel)
                    $entry_stub .= pack( 'C3',    0x48, 0x89, 0xC7 );      # mov rdi, rax
                    $entry_stub .= pack( 'C2 l<', 0xFF, 0x15, $rel32 );    # call [rip + got_exit]
                    $entry_stub .= pack( 'C2',    0x0F, 0x0B );            # ud2 (Invalid instruction safety)
                }
                $text = $entry_stub . $code_bytes;
            }

            # Deterministic OSABI and ABI notes explicitly defined per platform.
            # Reference: https://eg/ABI.md Section 2.5
            my $osabi        = 0;
            my $note_data    = '';
            my $has_pintable = 0;
            if ( $platform->is_freebsd ) {
                $osabi     = 9;                                                    # ELFOSABI_FREEBSD
                $note_data = pack( 'L<3 a8 L<', 8, 4, 1, "FreeBSD\0", 1400097 );
            }
            elsif ( $platform->is_midnightbsd ) {
                $osabi     = 9;
                $note_data = pack( 'L<3 a12 L<', 12, 4, 1, "MidnightBSD\0", 300000 );
            }
            elsif ( $platform->is_netbsd ) {
                $osabi     = 2;                                                        # ELFOSABI_NETBSD
                $note_data = pack( 'L<3 a8 L<', 7, 4, 1, "NetBSD\0\0", 1099000000 );
                $note_data .= pack( 'L<3 a4 L<', 4, 4, 3, "PaX\0", 0x0a );             # Flag 0x0a relaxes PaX W^X
            }
            elsif ( $platform->is_openbsd ) {
                $osabi        = 0;
                $note_data    = pack( 'L<3 a8 L<', 8, 4, 1, "OpenBSD\0", 0 );
                $has_pintable = 1;
            }
            elsif ( $platform->is_dragonflybsd ) {
                $osabi     = 9;
                $note_data = pack( 'L<3 a12 L<', 10, 4, 1, "DragonFly\0\0\0", 600400 );
            }

            # Per-OS interpreter path for dynamic executables
            my %interp_map = (
                linux        => '/lib64/ld-linux-x86-64.so.2',
                linux_arm    => '/lib/ld-linux-aarch64.so.1',
                linux_riscv  => '/lib/ld-linux-riscv64-lp64d.so.1',
                freebsd      => '/libexec/ld-elf.so.1',
                netbsd       => '/usr/libexec/ld.elf_so',
                openbsd      => '/usr/libexec/ld.so',
                dragonfly    => '/usr/libexec/ld-elf.so.2',
                dragonflybsd => '/usr/libexec/ld-elf.so.2',
                solaris      => '/lib/64/ld.so.1',
                midnightbsd  => '/libexec/ld-elf.so.1',
                haiku        => '/boot/system/runtime_loader'
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
            if ( $has_pintable && $platform->is_openbsd ) {
                my $pos             = 0;
                my $text_rva_actual = $self->layout->get('.text')->{rva};
                my $exit_sys        = $platform->syscall('exit') // 1;
                if ( $platform->is_x64 ) {
                    while ( ( my $idx = index( $text, "\x0F\x05", $pos ) ) != -1 ) {
                        my $vaddr = $base + $text_rva_actual + $idx;

                        # OpenBSD ELF64 pintable entries are 16 bytes: uint64_t addr, uint32_t syscall, uint32_t pad
                        $pintable_data .= pack( 'Q< L< x4', $vaddr, $exit_sys );
                        $pos = $idx + 2;
                    }
                }
                else {
                    while ( ( my $idx = index( $text, "\x01\x00\x00\xd4", $pos ) ) != -1 ) {
                        my $vaddr = $base + $text_rva_actual + $idx;
                        $pintable_data .= pack( 'Q< L< x4', $vaddr, $exit_sys );
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
                    $interp                               = $ipath . "\0";
                    $self->layout->get('.interp')->{size} = length($interp);
                    $has_interp                           = 1;
                }
            }

            # Setup Dynamic Strings Table
            my @exports   = @{ $self->exported_funcs // [] };
            my $exit_name = $platform->is_haiku ? 'exit' : '_exit';                # Reference: eg/ABI.md Section 2.3
            my @imports   = ( 'dlopen', 'dlsym', 'pthread_create', $exit_name );
            my $libc      = $libc_map{$os_base} // 'libc.so';

            # Probe the exact dynamic libc.so name on the host filesystem when running natively
            if ( $platform->is_native ) {
                my @search_paths = (
                    '/usr/lib', '/lib', '/lib64', '/usr/lib64',
                    '/usr/lib/x86_64-linux-gnu', '/usr/lib/aarch64-linux-gnu', '/usr/lib/riscv64-linux-gnu',
                );
                my @found;
                for my $dir (@search_paths) {
                    next unless -d $dir;
                    my @matches = glob("$dir/libc.so.[0-9]*");
                    for my $m (@matches) {
                        next if $m =~ /_p\.so/;    # skip profiled
                        push @found, $m;
                    }
                }
                if (@found) {
                    my $best = (
                        sort {
                            my ( $amaj, $amin ) = $a =~ /libc\.so\.(\d+)(?:\.(\d+))?/;
                            my ( $bmaj, $bmin ) = $b =~ /libc\.so\.(\d+)(?:\.(\d+))?/;
                            ( $amaj // 0 ) <=> ( $bmaj // 0 ) || ( ( $amin // 0 ) <=> ( $bmin // 0 ) );
                        } @found
                    )[-1];
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
                        '/usr/lib', '/lib', '/lib64', '/usr/lib64',
                        '/usr/lib/x86_64-linux-gnu', '/usr/lib/aarch64-linux-gnu', '/usr/lib/riscv64-linux-gnu',
                    );
                    my @found;
                    my $prefix = $platform->is_freebsd || $platform->is_midnightbsd ? 'libthr' : 'libpthread';
                    for my $dir (@search_paths) {
                        next unless -d $dir;
                        my @matches = glob("$dir/$prefix.so.[0-9]*");
                        for my $m (@matches) {
                            next if $m =~ /_p\.so/;    # skip profiled
                            push @found, $m;
                        }
                    }
                    if (@found) {
                        my $best = (
                            sort {
                                my ( $amaj, $amin ) = $a =~ /\.so\.(\d+)(?:\.(\d+))?/;
                                my ( $bmaj, $bmin ) = $b =~ /\.so\.(\d+)(?:\.(\d+))?/;
                                ( $amaj // 0 ) <=> ( $bmaj // 0 ) || ( ( $amin // 0 ) <=> ( $bmin // 0 ) );
                            } @found
                        )[-1];
                        if ($best) {
                            require File::Basename;
                            $libpthread = File::Basename::basename($best);
                        }
                    }
                }
                push @libs, $libpthread;
            }
            my $dynstr = "\0";
            my %str_off;
            for my $s ( @libs, @imports, @exports ) {
                next if exists $str_off{$s};
                $str_off{$s} = length($dynstr);
                $dynstr .= $s . "\0";
            }

            # Map BSD internal symbols
            # Reference: eg/ABI.md Section 2.2
            if ( $platform->is_bsd ) {
                $str_off{'__progname'} = length($dynstr);
                $dynstr .= '__progname' . "\0";
                $str_off{'environ'} = length($dynstr);
                $dynstr .= 'environ' . "\0";
            }

            # Map Haiku ABI version symbols
            # Reference: eg/ABI.md Section 2.1
            if ( $platform->is_haiku ) {
                $str_off{'_gSharedObjectHaikuABI'} = length($dynstr);
                $dynstr .= "_gSharedObjectHaikuABI\0";
                $str_off{'_gSharedObjectHaikuVersion'} = length($dynstr);
                $dynstr .= "_gSharedObjectHaikuVersion\0";
            }
            $self->layout->get('.dynstr')->{size} = length($dynstr);

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
                    my $rva = $self->layout->get('.text')->{rva} + ( $self->labels->{"E_$name"} // 0 );
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
                    my $data_sec_idx;
                    my $sec_i = 1;
                    for my $s ( $self->layout->sections ) {
                        if ( $s->{name} eq '.data' ) {
                            $data_sec_idx = $sec_i;
                            last;
                        }
                        $sec_i++;
                    }
                    my $data_sec = $self->layout->get('.data');
                    $dynsym .= pack(
                        'L< C C S< Q< Q<', $progname_off,    # st_name
                        0x11,                                # st_info (STB_GLOBAL | STT_OBJECT)
                        0,                                   # st_other (STV_DEFAULT)
                        $data_sec_idx // 0,                  # st_shndx
                        $base + $data_sec->{rva} + 16,       # st_value (points to Offset 16 in .data)
                        8                                    # st_size (pointer size)
                    );
                }
            }

            # Define environ for BSD to satisfy libc's dynamic reference (e.g. DragonFly)
            if ( $platform->is_bsd ) {
                my $environ_off = $str_off{'environ'};
                if ( defined $environ_off ) {
                    $sym_indices{'environ'} = $sym_idx++;
                    my $data_sec_idx;
                    my $sec_i = 1;
                    for my $s ( $self->layout->sections ) {
                        if ( $s->{name} eq '.data' ) {
                            $data_sec_idx = $sec_i;
                            last;
                        }
                        $sec_i++;
                    }
                    my $data_sec = $self->layout->get('.data');
                    $dynsym .= pack(
                        'L< C C S< Q< Q<', $environ_off,    # st_name
                        0x11,                               # st_info (STB_GLOBAL | STT_OBJECT)
                        0,                                  # st_other (STV_DEFAULT)
                        $data_sec_idx // 0,                 # st_shndx
                        $base + $data_sec->{rva} + 8,       # st_value (points to Offset 8 in .data)
                        8                                   # st_size (pointer size)
                    );
                }
            }

            # Define Haiku ABI variables
            if ( $platform->is_haiku ) {
                my $abi_off = $str_off{'_gSharedObjectHaikuABI'};
                my $ver_off = $str_off{'_gSharedObjectHaikuVersion'};
                my $data_sec_idx;
                my $sec_i = 1;
                for my $s ( $self->layout->sections ) {
                    if ( $s->{name} eq '.data' ) {
                        $data_sec_idx = $sec_i;
                        last;
                    }
                    $sec_i++;
                }
                my $data_sec = $self->layout->get('.data');
                $sym_indices{'_gSharedObjectHaikuABI'} = $sym_idx++;
                $dynsym .= pack( 'L< C C S< Q< Q<', $abi_off, 0x11, 0, $data_sec_idx // 0, $base + $data_sec->{rva}, 4 );
                $sym_indices{'_gSharedObjectHaikuVersion'} = $sym_idx++;
                $dynsym .= pack( 'L< C C S< Q< Q<', $ver_off, 0x11, 0, $data_sec_idx // 0, $base + $data_sec->{rva} + 4, 4 );
            }
            $self->layout->get('.dynsym')->{size} = length($dynsym);

            # Setup Relocations (.rela.dyn)
            my $rel_type = $platform->is_arm64 ? 1025 : ( $platform->is_riscv64 ? 20 : 6 );    # R_RISCV_GLOB_DAT (20) or R_AARCH64_GLOB_DAT (1025) or R_X86_64_GLOB_DAT (6)
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

            # Elf64_Rela (24 bytes) for exit mapping
            my $exit_slot    = $base + $got_rva + 24;
            my $exit_sym_idx = $sym_indices{$exit_name};
            $rela_dyn .= pack(
                'Q< Q< q<', $exit_slot,                    # r_offset
                ( $exit_sym_idx << 32 ) | $rel_type,       # r_info
                0                                          # r_addend
            );
            $self->layout->get('.rela.dyn')->{size} = length($rela_dyn);

            # Setup GOT section payload (four zeroed slots: dlopen, dlsym, pthread_create, exit)
            my $got = pack( 'Q< Q< Q< Q<', 0, 0, 0, 0 );
            $self->layout->get('.got')->{size} = length($got);

            # Setup Hash Table (Standard System V Hash)
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
            $self->layout->get('.hash')->{size} = length($hash);

            # Size the static .symtab and .strtab sections before final layout calculations
            $self->layout->get('.symtab')->{size} = length($dynsym);
            $self->layout->get('.strtab')->{size} = length($dynstr);

            # Calculate to stabilize RVAs before building .dynamic
            $self->layout->calculate($page_align);

            # Setup .dynamic payload
            my $dyn_rva        = $self->layout->get('.dynamic')->{rva};
            my $str_rva        = $self->layout->get('.dynstr')->{rva};
            my $sym_rva        = $self->layout->get('.dynsym')->{rva};
            my $hash_rva       = $self->layout->get('.hash')->{rva};
            my $rela_rva       = $self->layout->get('.rela.dyn')->{rva};
            my $got_rva_actual = $self->layout->get('.got')->{rva};
            my $dynamic        = '';

            # Elf64_Dyn (16 bytes each) entries
            for my $lib (@libs) {
                $dynamic .= pack( 'Q< Q<', 1, $str_off{$lib} );    # DT_NEEDED (string offset)
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

            if ($is_pie) {
                $dynamic .= pack( 'Q< Q<', 0x6ffffffb, 8 );              # DT_FLAGS_1 with DF_1_PIE
            }
            $dynamic .= pack( 'Q< Q<', 0, 0 );                           # DT_NULL
            $self->layout->get('.dynamic')->{size} = length($dynamic);

            # Final layout calculation
            $self->layout->calculate($page_align);

            # Build Section Names String Table (.shstrtab)
            my $shstrtab = "\0";
            my %sh_name_off;
            for my $s ( $self->layout->sections ) {
                $sh_name_off{ $s->{name} } = length($shstrtab);
                $shstrtab .= $s->{name} . "\0";
            }
            $sh_name_off{'.shstrtab'} = length($shstrtab);
            $shstrtab .= ".shstrtab\0";
            $sh_name_off{'.note.GNU-stack'} = length($shstrtab);
            $shstrtab .= ".note.GNU-stack\0";
            my $sec_idx = 1;
            my %sec_indices;
            for my $s ( $self->layout->sections ) { $sec_indices{ $s->{name} } = $sec_idx++; }

            # Open file and write payloads based on layout
            open my $fh, '>', $output_file or die $!;
            binmode $fh;
            for my $s ( $self->layout->sections ) {
                my $payload = "\0" x $s->{size};
                if ( $s->{name} eq '.text' ) {
                    $payload = $text;
                }
                elsif ( $s->{name} eq '.interp' ) {
                    $payload = $interp;
                }
                elsif ( $s->{name} eq '.dynstr' ) {
                    $payload = $dynstr;
                }
                elsif ( $s->{name} eq '.dynsym' ) {
                    $payload = $dynsym;
                }
                elsif ( $s->{name} eq '.symtab' ) {
                    $payload = $dynsym;
                }
                elsif ( $s->{name} eq '.strtab' ) {
                    $payload = $dynstr;
                }
                elsif ( $s->{name} eq '.rela.dyn' ) {
                    $payload = $rela_dyn;
                }
                elsif ( $s->{name} eq '.hash' ) {
                    $payload = $hash;
                }
                elsif ( $s->{name} eq '.dynamic' ) {
                    $payload = $dynamic;
                }
                elsif ( $s->{name} eq '.got' ) {
                    $payload = $got;
                }
                elsif ( $s->{name} eq '.data' ) {
                    if ( $platform->is_bsd && $s->{size} >= 32 ) {

                        # Satisfy __progname and environ expectations
                        my $empty_env_addr = $base + $s->{rva};
                        my $empty_str_addr = $base + $s->{rva} + 24;
                        $payload = pack( 'Q< Q< Q<', 0, $empty_env_addr, $empty_str_addr );
                    }
                    elsif ( $platform->is_haiku && $s->{size} >= 8 ) {
                        $payload = pack( 'L< L<', 4, 0 );    # Haiku ABI Version 4
                    }
                    else {
                        $payload = "\0" x $s->{size};
                    }
                }
                elsif ( $s->{name} =~ /^\.(debug|eh_frame)/ ) {
                    $payload = $self->debug_section( $s->{name} ) || "\0";
                }
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
            for my $s ( $self->layout->sections ) {
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
                elsif ( $s->{name} eq '.symtab' ) {
                    $type       = 2;                              # SHT_SYMTAB
                    $flags      = 0;                              # Not SHF_ALLOC
                    $sh_link    = $sec_indices{'.strtab'} // 0;
                    $sh_info    = 1;
                    $sh_entsize = 24;
                }
                elsif ( $s->{name} eq '.strtab' ) {
                    $type  = 3;                                   # SHT_STRTAB
                    $flags = 0;                                   # Not SHF_ALLOC
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
                    $type       = 6;                                         # SHT_DYNAMIC
                    $flags      = ( $platform->is_dragonflybsd ) ? 2 : 3;    # Read-only on DFly to avoid RELRO crash
                    $sh_link    = $sec_indices{'.dynstr'} // 0;
                    $sh_entsize = 16;
                }
                elsif ( $s->{name} eq '.got' ) {
                    $type       = 1;                                         # SHT_PROGBITS
                    $flags      = 3;                                         # SHF_ALLOC | SHF_WRITE
                    $sh_entsize = 8;
                }
                elsif ( $s->{name} =~ /^\.(debug|eh_frame)/ ) {
                    $flags = 0;                                              # Debug sections are not loaded
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
                0, 0, 0, 0, 0, 1, 0                                                  # sh_addr, sh_offset, sh_size, l, i, a, e
            );
            seek( $fh, $shoff, 0 );
            print $fh $_ for @shdrs;

            # Program Headers — Elf64_Phdr (56 bytes each)
            my $num_ph = 5;                       # PT_PHDR, PT_LOAD (RX), PT_LOAD (RW), PT_DYNAMIC, PT_GNU_STACK
            if ($has_interp)    { $num_ph++; }    # PT_INTERP
            if ($note_data)     { $num_ph++; }    # PT_NOTE
            if ($pintable_data) { $num_ph++; }    # PT_OPENBSD_PINTABLE
            if ($is_pie)        { $num_ph++; }    # PT_GNU_RELRO
            my @phdrs     = ();
            my $extra_off = 64 + ( $num_ph * 56 );

            # PT_PHDR (type 6) — Elf64_Phdr (56 bytes)
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

            # PT_INTERP (type 3) — Elf64_Phdr (56 bytes)
            if ($has_interp) {
                my $interp_sec = $self->layout->get('.interp');
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

            # PT_LOAD RX segment (Headers + .text through .hash) — Elf64_Phdr (56 bytes)
            my $hash_sec  = $self->layout->get('.hash');
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

            # PT_LOAD RW segment (Covers .dynamic through .got) — Elf64_Phdr (56 bytes)
            my $dyn_sec  = $self->layout->get('.dynamic');
            my $got_sec  = $self->layout->get('.got');
            my $rw_p_off = $dyn_sec->{off} & ~( $page_align - 1 );
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

            # PT_DYNAMIC (type 2) — Elf64_Phdr (56 bytes)
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

            # PT_GNU_RELRO (type 0x6474e552) — Elf64_Phdr (56 bytes)
            # Covers ONLY .dynamic to ensure .data and .got remain fully writable.
            # Reference: eg/ABI.md Section 2.4
            if ($is_pie) {
                my $relro_start = $dyn_sec->{off} & ~( $page_align - 1 );
                my $relro_size  = ( $dyn_sec->{off} + $dyn_sec->{size} - $relro_start + $page_align - 1 ) & ~( $page_align - 1 );
                push @phdrs, pack(
                    'L< L< Q< Q< Q< Q< Q< Q<', 0x6474e552,                 # p_type (PT_GNU_RELRO)
                    4,                                                     # p_flags (PF_R)
                    $relro_start,                                          # p_offset
                    $base + ( $dyn_sec->{rva} & ~( $page_align - 1 ) ),    # p_vaddr
                    $base + ( $dyn_sec->{rva} & ~( $page_align - 1 ) ),    # p_paddr
                    $relro_size,                                           # p_filesz
                    $relro_size,                                           # p_memsz
                    1                                                      # p_align
                );
            }

            # PT_NOTE — Elf64_Phdr (56 bytes)
            if ($note_data) {
                push @phdrs, pack(
                    'L< L< Q< Q< Q< Q< Q< Q<', 4,                          # p_type (PT_NOTE)
                    4,                                                     # p_flags (PF_R)
                    $extra_off,                                            # p_offset
                    $base + $extra_off,                                    # p_vaddr
                    $base + $extra_off,                                    # p_paddr
                    length($note_data),                                    # p_filesz
                    length($note_data),                                    # p_memsz
                    4                                                      # p_align
                );
                $extra_off += length($note_data);
            }

            # PT_OPENBSD_PINTABLE — Elf64_Phdr (56 bytes)
            if ($pintable_data) {
                push @phdrs, pack(
                    'L< L< Q< Q< Q< Q< Q< Q<', 0x65a3dbe9,                 # p_type (PT_OPENBSD_PINTABLE)
                    4,                                                     # p_flags (PF_R)
                    $extra_off,                                            # p_offset
                    $base + $extra_off,                                    # p_vaddr
                    $base + $extra_off,                                    # p_paddr
                    length($pintable_data),                                # p_filesz
                    length($pintable_data),                                # p_memsz
                    4                                                      # p_align
                );
                $extra_off += length($pintable_data);
            }

            # PT_GNU_STACK (type 0x6474e551) — Elf64_Phdr (56 bytes)
            # p_flags = 6 (PF_R|PF_W) for non-executable stack. Some BSD kernels
            # reject binaries with p_flags=0 on PT_GNU_STACK.
            push @phdrs, pack(
                'L< L< Q< Q< Q< Q< Q< Q<', 0x6474e551,    # p_type (PT_GNU_STACK)
                6, 0, 0, 0, 0, 0, 0x10                    # p_flags=6(PF_R|PF_W), p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align
            );
            my $entry_point = $self->type eq 'shared' ? 0 : $base + $self->layout->get('.text')->{rva};

            # Finalize ELF Header (Elf64_Ehdr - Exactly 64 bytes) and write program headers/extra data
            # Reference: https://refspecs.linuxbase.org/elf/gabi4+/ch4.eheader.html
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
                ( $platform->is_riscv64 ? 0x0004 : 0 ),                                   # e_flags (EF_RISCV_FLOAT_ABI_DOUBLE for RISC-V lp64d)
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
}
my $compiler = Brocken::Compiler->new();
subtest Katsuro => sub {
    subtest 'platform parsing' => sub {
        my $raw_triple = Brocken::Katsuro::Platform::gen_triple();
        diag 'Host raw triple: ' . $raw_triple;
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
        is $haiku->syscall('write'),  144, 'haiku x86_64 write fallback';
        is $haiku->syscall('exit'),   38,  'haiku x86_64 exit fallback';
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

class Brocken::Jenny::Linker::Wasm : isa(Brocken::Jenny::Linker) {

    method write_executable ( $output_file, $codegen_output, $platform ) {
        my $body     = $codegen_output->{body};
        my $locals   = $codegen_output->{locals};
        my $name     = 'main';                      # Hardcoded for now
        my $type_idx = 0;
        my $func_idx = 0;

        # Type Section (ID 1): () -> return_type
        my $ret_valtype = $codegen_output->{return_valtype} // 0x7F;
        my $type_sec = $ret_valtype eq 'void'
            ? pack( 'C', 0x60 ) . "\x00\x00"
            : pack( 'C', 0x60 ) . "\x00\x01" . pack( 'C', $ret_valtype );
        $type_sec = pack( 'C', 1 ) . $self->_uleb( length($type_sec) + 1 ) . $self->_uleb(1) . $type_sec;

        # Memory Section (ID 5): 1 page (64KB)
        my $mem_content = pack( 'C', 1 ) . pack( 'C', 0 ) . $self->_uleb(1);    # count=1, flags=0(no max), initial=1
        my $mem_sec     = pack( 'C', 5 ) . $self->_uleb( length($mem_content) ) . $mem_content;

        # Function Section (ID 3)
        my $func_sec = $self->_uleb(1) . $self->_uleb($type_idx);
        $func_sec = pack( 'C', 3 ) . $self->_uleb( length($func_sec) ) . $func_sec;

        # Export Section (ID 7)
        my $export_sec = $self->_uleb(1) . $self->_uleb( length($name) ) . $name . pack( 'C', 0x00 ) . $self->_uleb($func_idx);
        $export_sec = pack( 'C', 7 ) . $self->_uleb( length($export_sec) ) . $export_sec;

        # Code Section (ID 10)
        my $code_item = $self->_uleb( length($locals) + length($body) ) . $locals . $body;
        my $code_sec  = $self->_uleb(1) . $code_item;
        $code_sec = pack( 'C', 10 ) . $self->_uleb( length($code_sec) ) . $code_sec;
        open my $fh, '>:raw', $output_file or die $!;
        print $fh "\0asm\x01\x00\x00\x00";    # Magic + Version
        print $fh $type_sec, $func_sec, $mem_sec, $export_sec, $code_sec;
        close $fh;
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
}
subtest Lindsay => sub {
    subtest 'Lindsay::IR Types & Singletons' => sub {
        my $i1   = Brocken::Lindsay::IR::Type::i1();
        my $i8   = Brocken::Lindsay::IR::Type::i8();
        my $i16  = Brocken::Lindsay::IR::Type::i16();
        my $i32  = Brocken::Lindsay::IR::Type::i32();
        my $i64  = Brocken::Lindsay::IR::Type::i64();
        my $i128 = Brocken::Lindsay::IR::Type::i128();
        my $f32  = Brocken::Lindsay::IR::Type::f32();
        my $f64  = Brocken::Lindsay::IR::Type::f64();
        my $ptr  = Brocken::Lindsay::IR::Type::ptr();
        my $void = Brocken::Lindsay::IR::Type::void();
        my $dyn  = Brocken::Lindsay::IR::Type::dynamic();
        is $i1->as_string,   'i1',   'i1 renders correctly';
        is $i8->as_string,   'i8',   'i8 renders correctly';
        is $i16->as_string,  'i16',  'i16 renders correctly';
        is $i32->as_string,  'i32',  'i32 renders correctly';
        is $i64->as_string,  'i64',  'i64 renders correctly';
        is $i128->as_string, 'i128', 'i128 renders correctly';
        is $f32->as_string,  'f32',  'f32 renders correctly';
        is $f64->as_string,  'f64',  'f64 renders correctly';
        is $ptr->as_string,  'ptr',  'ptr renders correctly';
        is $void->as_string, 'void', 'void renders correctly';
        is $dyn->as_string,  'dynamic', 'dynamic renders correctly';

        # Prove they are singletons
        ref_is $i32, Brocken::Lindsay::IR::Type::i32(), 'i32 singleton';
        ref_is $i1,  Brocken::Lindsay::IR::Type::i1(),  'i1 singleton';
        ref_is $i8,  Brocken::Lindsay::IR::Type::i8(),  'i8 singleton';
        ref_is $i16, Brocken::Lindsay::IR::Type::i16(), 'i16 singleton';
        ref_is $i64, Brocken::Lindsay::IR::Type::i64(), 'i64 singleton';
        ref_is $i128, Brocken::Lindsay::IR::Type::i128(), 'i128 singleton';
        ref_is $f32, Brocken::Lindsay::IR::Type::f32(), 'f32 singleton';
        ref_is $f64, Brocken::Lindsay::IR::Type::f64(), 'f64 singleton';
        ref_is $ptr, Brocken::Lindsay::IR::Type::ptr(), 'ptr singleton';
        ref_is $void, Brocken::Lindsay::IR::Type::void(), 'void singleton';
        ref_is $dyn, Brocken::Lindsay::IR::Type::dynamic(), 'dynamic singleton';
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
      %0 = add i32 %a, %b
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
      %doubled = add i64 %native_val, %native_val
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
    subtest 'Lindsay::IR Binary Operators' => sub {
        my $module = Brocken::Lindsay::IR::Module->new( name => 'binops' );
        my $a      = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%a' );
        my $b      = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%b' );
        my $func   = Brocken::Lindsay::IR::Function->new( name => 'math', return_type => Brocken::Lindsay::IR::Type::void(), params => [ $a, $b ] );
        $module->add_function($func);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_sub( $a, $b );
        $builder->build_mul( $a, $b );
        $builder->build_and( $a, $b );
        $builder->build_or( $a, $b );
        $builder->build_xor( $a, $b );
        $builder->build_shl( $a, $b );
        $builder->build_lshr( $a, $b );
        $builder->build_ashr( $a, $b );
        $builder->build_ret();
        my $expected_ir = <<~'IR';
    ; ModuleID = 'binops'

    define void @math(i32 %a, i32 %b) {
    entry:
      %0 = sub i32 %a, %b
      %1 = mul i32 %a, %b
      %2 = and i32 %a, %b
      %3 = or i32 %a, %b
      %4 = xor i32 %a, %b
      %5 = shl i32 %a, %b
      %6 = lshr i32 %a, %b
      %7 = ashr i32 %a, %b
      ret void
    }

    IR
        is $module->as_string, $expected_ir, 'Generated Binary Operators IR matches expected output';
    };
    subtest 'Lindsay::IR Select & GEP' => sub {
        my $module = Brocken::Lindsay::IR::Module->new( name => 'select_gep' );
        my $func   = Brocken::Lindsay::IR::Function->new(
            name        => 'test',
            return_type => Brocken::Lindsay::IR::Type::ptr(),
            params      => [
                Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i1(),  name => '%cond' ),
                Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%base' )
            ]
        );
        $module->add_function($func);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $c1  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 10 );
        my $c2  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 20 );
        my $val = $builder->build_select( $func->params->[0], $c1, $c2, '%val' );
        my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(), $func->params->[1], [$val], '%element_ptr' );
        $builder->build_ret($gep);
        my $expected_ir = <<~'IR';
    ; ModuleID = 'select_gep'

    define ptr @test(i1 %cond, ptr %base) {
    entry:
      %val = select i1 %cond, i32 10, i32 20
      %element_ptr = getelementptr i32, ptr %base, i32 %val
      ret ptr %element_ptr
    }

    IR
        is $module->as_string, $expected_ir, 'Generated Select and GEP IR matches expected output';
    };
    subtest 'Lindsay::IR Loops' => sub {
        my $module = Brocken::Lindsay::IR::Module->new( name => 'loop_test' );
        my $func   = Brocken::Lindsay::IR::Function->new(
            name        => 'sum_to_n',
            return_type => Brocken::Lindsay::IR::Type::i32(),
            params      => [ Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%n' ) ]
        );
        $module->add_function($func);
        my $entry   = $func->append_block('entry');
        my $loop    = $func->append_block('loop');
        my $exit    = $func->append_block('exit');
        my $builder = Brocken::Lindsay::IR::Builder->new();

        # Entry
        $builder->position_at_end($entry);
        $builder->build_br($loop);

        # Loop
        $builder->position_at_end($loop);
        my $i   = $builder->build_phi( Brocken::Lindsay::IR::Type::i32(), '%i' );
        my $sum = $builder->build_phi( Brocken::Lindsay::IR::Type::i32(), '%sum' );
        my $next_i
            = $builder->build_add( $i, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ), '%next_i' );
        my $next_sum = $builder->build_add( $sum, $i, '%next_sum' );
        my $cond     = $builder->build_icmp( 'slt', $i, $func->params->[0], '%cond' );
        $builder->build_cond_br( $cond, $loop, $exit );
        $i->add_incoming( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), $entry );
        $i->add_incoming( $next_i,                                                                                      $loop );
        $sum->add_incoming( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), $entry );
        $sum->add_incoming( $next_sum,                                                                                    $loop );

        # Exit
        $builder->position_at_end($exit);
        $builder->build_ret($sum);
        my $expected_ir = <<~'IR';
    ; ModuleID = 'loop_test'

    define i32 @sum_to_n(i32 %n) {
    entry:
      br label %loop
    loop:
      %i = phi i32 [ 0, %entry ], [ %next_i, %loop ]
      %sum = phi i32 [ 0, %entry ], [ %next_sum, %loop ]
      %next_i = add i32 %i, 1
      %next_sum = add i32 %sum, %i
      %cond = icmp slt i32 %i, %n
      br i1 %cond, label %loop, label %exit
    exit:
      ret i32 %sum
    }

    IR
        is $module->as_string, $expected_ir, 'Generated Loop IR with PHI nodes matches expected output';
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
            my $signal    = $? & 127;
            my $core      = $? & 128;
            note "raw \$?=$? exit=$exit_code signal=$signal core=$core";
            is $exit_code, 42, 'Standalone binary executed natively and returned the correct exit code!';
        }

        # Clean up
        unlink $output_file;
    };
    subtest 'Jenny::Linker Pure ELF-64 Shared Library Generation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $module   = Brocken::Lindsay::IR::Module->new( name => 'shared_elf' );
        my $func_ext = Brocken::Lindsay::IR::Function->new( name => 'my_func', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_ext);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_ext->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new() :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_ext);
        my $output_file   = './libtest_prog.so';
        my $linker        = Brocken::Jenny::Linker::ELF64->new( type => 'shared' );
        $linker->set_exported_funcs( ['my_func'] );
        $linker->set_labels( { E_my_func => 0 } );
        $linker->write_executable( $output_file, $machine_bytes, $platform, 1 );
        ok -e $output_file, 'ELF Shared library created successfully';
    SKIP: {
            skip 'Shared library loading test requires Linux/BSD/Haiku native host', 1
                unless ( $platform->is_linux || $platform->is_bsd || $platform->is_haiku ) && $platform->is_native;
            require DynaLoader;
            require File::Spec;
            my $abs_path = File::Spec->rel2abs($output_file);
            my $libref   = DynaLoader::dl_load_file($abs_path);
            diag `nm $abs_path`;
            ok $libref, 'Loaded ELF shared library natively via DynaLoader';
            if ($libref) {
                my $symref = DynaLoader::dl_find_symbol( $libref, 'my_func' );
                ok $symref, 'Successfully resolved exported symbol "my_func"';
                DynaLoader::dl_unload_file($libref);
            }
        }
        unlink $output_file;
    };
    subtest 'Jenny::Linker Pure PE-64 Generation' => sub {
        my $platform  = Brocken::Katsuro::Platform::parse();
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
    subtest 'Jenny::Linker Pure PE-64 Shared Library Generation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $module   = Brocken::Lindsay::IR::Module->new( name => 'shared_pe' );
        my $func_ext = Brocken::Lindsay::IR::Function->new( name => 'my_func', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_ext);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_ext->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        my $codegen       = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new() : Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_ext);
        my $output_file   = './libtest_prog.dll';

        # The main PE Linker now supports symbol exporting natively
        my $linker = Brocken::Jenny::Linker::PE->new( type => 'shared' );
        $linker->set_exported_funcs( ['my_func'] );
        $linker->set_labels( { E_my_func => 0 } );
        $linker->write_shared_library( $output_file, $machine_bytes, $platform );
        ok -e $output_file, 'PE Shared library (DLL) created successfully';
    SKIP: {
            use Config;

            # Skip native loading test under emulation mismatch to prevent crash errors
            skip 'Shared library loading test requires native execution support (no emulation mismatch)', 1
                unless $platform->is_windows && $platform->is_native && ( $platform->is_arm64 ? ( $Config{archname} !~ /x86_64|x64/i ) : 1 );
            require DynaLoader;
            require File::Spec;
            my $abs_path = File::Spec->rel2abs($output_file);
            my $libref   = DynaLoader::dl_load_file($abs_path);
            ok $libref, 'Loaded PE DLL natively via DynaLoader';
            if ($libref) {
                my $symref = DynaLoader::dl_find_symbol( $libref, 'my_func' );
                ok $symref, 'Successfully resolved exported symbol "my_func" natively via DynaLoader';
                DynaLoader::dl_unload_file($libref);
            }
        }
        unlink $output_file;
    };
    subtest 'Jenny::Linker Pure Mach-O Generation' => sub {
        my $platform  = Brocken::Katsuro::Platform::parse();
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
                    note '=== Generated: otool -l ===';
                    note scalar `otool -l "$output_file" 2>&1`;
                    note '=== Reference: otool -l ===';
                    note scalar `otool -l "$ref_bin" 2>&1`;
                    note '=== Generated: od -A x -t x1 -c (first 1KB) ===';
                    note scalar `od -A x -t x1 -c -v -N 1024 "$output_file" 2>&1`;
                    note '=== Reference: od -A x -t x1 -c (first 1KB) ===';
                    note scalar `od -A x -t x1 -c -v -N 1024 "$ref_bin" 2>&1`;
                }
                else {
                    note 'clang compilation failed, exit: ' . ( $rc >> 8 );
                }
            }
        }

        # Clean up
        unlink $output_file;
    };
    subtest 'Jenny::Linker Pure Mach-O Shared Library Generation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $module   = Brocken::Lindsay::IR::Module->new( name => 'shared_macho' );
        my $func_ext = Brocken::Lindsay::IR::Function->new( name => 'my_func', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_ext);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_ext->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        my $codegen       = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new() : Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_ext);
        my $output_file   = './libtest_prog.dylib';
        my $linker        = Brocken::Jenny::Linker::MachO->new( type => 'shared' );
        $linker->set_exported_funcs( ['my_func'] );
        $linker->set_labels( { E_my_func => 0 } );
        $linker->write_executable( $output_file, $machine_bytes, $platform );
        ok -e $output_file, 'Mach-O Shared library created successfully';
    SKIP: {
            skip 'Shared library loading test requires macOS native host', 1 unless $platform->is_macos && $platform->is_native;
            require DynaLoader;
            require File::Spec;
            my $abs_path = File::Spec->rel2abs($output_file);
            my $libref   = DynaLoader::dl_load_file($abs_path);
            ok $libref, 'Loaded Mach-O shared library natively via DynaLoader';
            if ($libref) {
                my $symref = DynaLoader::dl_find_symbol( $libref, 'my_func' );
                ok $symref, 'Successfully resolved exported symbol "my_func"';
                diag $symref;
                DynaLoader::dl_unload_file($libref);
            }
        }
        unlink $output_file;
    };
    subtest 'Jenny::Linker Early FFI Integration Test' => sub {
        my $todo     = todo 'It is way too early to do this...';
        my $platform = Brocken::Katsuro::Platform::parse();

        # Determine platform properties
        my $is_arm64   = $platform->is_arm64;
        my $is_x64     = $platform->is_x64;
        my $is_windows = $platform->is_windows;
        my $is_posix   = $platform->is_posix;

        # Build the shared library IR: int my_func() { return 42; }
        my $module   = Brocken::Lindsay::IR::Module->new( name => 'shared_lib' );
        my $func_ext = Brocken::Lindsay::IR::Function->new( name => 'my_func', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_ext);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_ext->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        my $codegen
            = $is_arm64           ? Brocken::Jenny::Codegen::ARM64->new() :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_ext);
        my $ext           = $platform->lib_ext;
        my $lib_file      = './libtest_prog' . $ext;

        # Build and write shared library
        if ($is_windows) {
            my $shared_linker = Brocken::Jenny::Linker::PE->new( type => 'shared' );
            $shared_linker->set_exported_funcs( ['my_func'] );
            $shared_linker->set_labels( { E_my_func => 0 } );
            $shared_linker->write_shared_library( $lib_file, $machine_bytes, $platform );
        }
        elsif ( $platform->is_macos ) {
            my $shared_linker = Brocken::Jenny::Linker::MachO->new( type => 'shared' );
            $shared_linker->set_exported_funcs( ['my_func'] );
            $shared_linker->set_labels( { E_my_func => 0 } );
            $shared_linker->write_executable( $lib_file, $machine_bytes, $platform, 1 );
        }
        else {
            my $shared_linker = Brocken::Jenny::Linker::ELF64->new( type => 'shared' );
            $shared_linker->set_exported_funcs( ['my_func'] );
            $shared_linker->set_labels( { E_my_func => 0 } );
            $shared_linker->write_executable( $lib_file, $machine_bytes, $platform, 1 );
        }
        ok -e $lib_file, 'Shared library compiled at ' . $lib_file;

        # Verify that the expected symbol is physically exported in the binary via nm
        my $nm_out = $^O eq 'MSWin32' ? `objdump -p $lib_file` : `nm "$lib_file"`;
        diag $nm_out;
        diag `dumpbin /headers $lib_file`;
        diag `dumpbin /exports $lib_file`;
        diag `llvm-readobj --coff-exports $lib_file`;
        if ( $? == 0 && defined $nm_out && $nm_out ne '' ) {
            my $expected_sym = $platform->is_macos ? '_my_func' : 'my_func';
            like $nm_out, qr/\b$expected_sym\b/, "Verified via 'nm' that '$expected_sym' is present in $lib_file";
        }
        else {
            note 'nm is not available or failed; skipping symbol table extraction check';
        }

        # POSIX x86_64 Wrapper Generator with 16-byte Stack Alignment Fix
        my $make_x64_wrapper = sub {
            my ( $ext_str, $got, $text, $macho ) = @_;
            my $lib_path         = "./libtest_prog$ext_str\0";
            my $func_name        = "my_func\0";
            my $lib_path_offset  = 50;
            my $func_name_offset = $lib_path_offset + length($lib_path);
            my $disp_libpath     = $lib_path_offset - 12;
            my $disp_funcname    = $func_name_offset - 36;
            my $entry_stub_len   = $macho ? 17 : 20;
            my $main_rva         = $text + $entry_stub_len;
            my $disp_dlopen      = $got - ( $main_rva + 23 );
            my $disp_dlsym       = ( $got + 8 ) - ( $main_rva + 42 );
            my $code             = pack( 'C', 0x53 );                      # push rbx
            $code .= pack( 'C4',    0x48, 0x83, 0xEC, 0x10 );              # sub rsp, 16 (Keep stack aligned to 16-bytes)
            $code .= pack( 'C3 l<', 0x48, 0x8D, 0x3D, $disp_libpath );     # lea rdi, [rip + disp_libpath]
            $code .= pack( 'C5', 0xBE, 0x02, 0x00, 0x00, 0x00 );           # mov esi, 2 (RTLD_NOW)
            $code .= pack( 'C2 l<', 0xFF, 0x15, $disp_dlopen );            # call [rip + disp_dlopen]
            $code .= pack( 'C3',    0x48, 0x89, 0xC3 );                    # mov rbx, rax
            $code .= pack( 'C3',    0x48, 0x89, 0xDF );                    # mov rdi, rbx
            $code .= pack( 'C3 l<', 0x48, 0x8D, 0x35, $disp_funcname );    # lea rsi, [rip + disp_funcname]
            $code .= pack( 'C2 l<', 0xFF, 0x15, $disp_dlsym );             # call [rip + disp_dlsym]
            $code .= pack( 'C2', 0xFF, 0xD0 );                             # call rax
            $code .= pack( 'C4', 0x48, 0x83, 0xC4, 0x10 );                 # add rsp, 16
            $code .= pack( 'C', 0x5B );                                    # pop rbx
            $code .= pack( 'C', 0xC3 );                                    # ret
            $code .= "\x00" while length($code) < 50;
            $code .= $lib_path . $func_name;
            return $code;
        };

        # POSIX ARM64 Wrapper Generator
        my $make_arm64_wrapper = sub {
            my ( $ext_str, $got, $text, $macho ) = @_;
            my $lib_path         = "./libtest_prog$ext_str\0";
            my $func_name        = "my_func\0";
            my $lib_path_offset  = 64;
            my $func_name_offset = $lib_path_offset + length($lib_path);
            my $entry_stub_len   = $macho ? 17 : 20;
            my $main_rva         = $text + $entry_stub_len;
            my $disp_libpath     = $lib_path_offset - $entry_stub_len - 8;
            my $disp_funcname    = $func_name_offset - $entry_stub_len - 32;
            my $offset_dlopen    = $got - ( $main_rva + 16 );
            my $offset_dlsym     = ( $got + 8 ) - ( $main_rva + 36 );
            my $imm19_dlopen     = ( $offset_dlopen / 4 ) & 0x7FFFF;
            my $imm19_dlsym      = ( $offset_dlsym / 4 ) & 0x7FFFF;
            my $adr_x0           = ( ( $disp_libpath & 3 ) << 28 ) | ( ( ( $disp_libpath >> 2 ) & 0x7FFFF ) << 5 ) | 0;
            my $adr_x1           = ( ( $disp_funcname & 3 ) << 28 ) | ( ( ( $disp_funcname >> 2 ) & 0x7FFFF ) << 5 ) | 1;
            my $ldr_dlopen       = 0x58000008 | ( $imm19_dlopen << 5 );
            my $ldr_dlsym        = 0x58000008 | ( $imm19_dlsym << 5 );
            my $code             = pack(
                'V*', 0xA9BF7BFD,    # stp x29, x30, [sp, #-32]!
                0xF9000BE3,          # str x19, [sp, #16]
                $adr_x0,             # adr x0, lib_path
                0xD2800041,          # mov x1, #2 (RTLD_NOW)
                $ldr_dlopen,         # ldr x8, got_slot_dlopen
                0xD63F0100,          # blr x8
                0xAA0003F3,          # mov x19, x0
                0xAA1303E0,          # mov x0, x19
                $adr_x1,             # adr x1, func_name
                $ldr_dlsym,          # ldr x8, got_slot_dlsym
                0xD63F0100,          # blr x8
                0xD63F0000,          # blr x0
                0xF9400BE3,          # ldr x19, [sp, #16]
                0xA8C27BFD,          # ldp x29, x30, [sp], #32
                0xD65F03C0,          # ret
            );
            $code .= "\x00" while length($code) < 64;
            $code .= $lib_path . $func_name;
            return $code;
        };
    SKIP: {
            if ($is_windows) {

                # Load the compiled PE DLL natively via the standard Win32::API module
                # On Windows ARM64, an emulated x64 Perl process cannot load native ARM64 DLLs.
                skip 'Win32::API loader skipped due to emulation mismatch', 2 if $platform->is_arm64 && $Config{archname} =~ /x86_64|x64/i;
                require File::Spec;
                my $abs_path = File::Spec->rel2abs($lib_file);
                eval {
                    require Win32::API;
                    my $func = Win32::API->new( $abs_path, 'int my_func()' );
                    ok $func, 'Natively bound my_func from compiled DLL with exports';
                    if ($func) {
                        my $ret = $func->Call();
                        is $ret, 42, 'Invoked DLL export successfully via Win32::API, returned 42';
                    }
                };
                if ($@) {
                    skip 'Win32::API loader failure: ' . $@, 2;
                }
            }
            elsif ( $is_posix && ( $is_x64 || $is_arm64 ) ) {

                # Compile native POSIX binary wrapper
                my $wrapper_file = './test_wrapper';
                my $wrapper_linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new( type => 'exe' ) : Brocken::Jenny::Linker::ELF64->new( type => 'exe' );
                $wrapper_linker->set_has_ffi(1) if $platform->is_macos;

                # Pass a dummy byte array first to allow the linker to calculate
                # the exact metadata structures and final section tables.
                my $code_sz     = $is_arm64 ? 128 : 96;
                my $dummy_bytes = "\x00" x $code_sz;
                $wrapper_linker->write_executable( $wrapper_file, $dummy_bytes, $platform );

                # Extract stabilized, correct section RVAs and text file offset
                my $got_rva  = $wrapper_linker->layout->get('.got')->{rva};
                my $text_rva = $wrapper_linker->layout->get('.text')->{rva};
                my $text_off = $wrapper_linker->layout->get('.text')->{off};

                # Assemble the actual FFI machine code referencing the real RVAs
                my $wrapper_bytes = $is_arm64 ? $make_arm64_wrapper->( $ext, $got_rva, $text_rva, $platform->is_macos ) :
                    $make_x64_wrapper->( $ext, $got_rva, $text_rva, $platform->is_macos );

                # Patch the binary file at its physical entry offset directly
                my $entry_stub_len = $platform->is_macos ? 17 : 20;
                open my $fh, '+<:raw', $wrapper_file or die $!;
                seek( $fh, $text_off + $entry_stub_len, 0 );
                print $fh $wrapper_bytes;
                close $fh;

                # Re-apply ad-hoc code signature required strictly on macOS ARM64
                system("codesign -f -s - \"$wrapper_file\" 2>/dev/null") if $platform->is_macos;
                ok -e $wrapper_file, 'POSIX wrapper compiled at ' . $wrapper_file;
                ok -x $wrapper_file, 'POSIX wrapper has execution permissions';

                # Execute POSIX native executable
                local $ENV{LD_LIBRARY_PATH}   = join( ':', '.', $ENV{LD_LIBRARY_PATH}   // () );
                local $ENV{DYLD_LIBRARY_PATH} = join( ':', '.', $ENV{DYLD_LIBRARY_PATH} // () );
                system('./test_wrapper');
                my $status    = $?;
                my $exit_code = $status >> 8;
                my $signal    = $status & 127;
                is $signal,    0,  'Native wrapper ran cleanly without crash/segfault signals';
                is $exit_code, 42, 'Native wrapper loaded library, resolved symbol via GOT table FFI, and returned 42';
                unlink $wrapper_file;
            }
            else {
                skip 'No native FFI wrapper assembly available for ' . $platform->friendly, 2;
            }
        }
        unlink $lib_file;
    };
    subtest 'Jenny::Codegen Arithmetic (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'math', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        # %v1 = 40 + 10 (50)
        my $v1 = $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 40 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 10 ),
            '%v1'
        );

        # %v2 = %v1 - 8 (42)
        my $v2 = $builder->build_sub( $v1, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 8 ), '%v2' );
        $builder->build_ret($v2);

        # Choose Codegen
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated math bytes for ' . $platform->friendly );

        # Choose Linker
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();

        # Standalone execution test if native
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = './math_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -x $output_file || $platform->is_windows, 'Math binary exists' );

            # Execute and check exit code
            # system returns exit code shifted left by 8 in Perl's $?
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            system($cmd);
            my $exit_code = $? >> 8;
            is( $exit_code, 42, 'Math binary returned 42 on ' . $platform->friendly );
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen ICmp (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'icmp_signed', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        my $entry    = $func->append_block('entry');
        my $t_block  = $func->append_block('if.then');
        my $f_block  = $func->append_block('if.else');
        $builder->position_at_end($entry);
        my $cond = $builder->build_icmp('sgt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ),
            '%cmp'
        );
        $builder->build_cond_br( $cond, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated signed icmp bytes for ' . $platform->friendly );
        if ( $platform->is_arm64 ) {
            diag 'ARM64 ICmp bytes: ' . unpack( 'H*', $bytes );
            diag 'ARM64 ICmp length: ' . length($bytes);
        }
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = './icmp_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -e $output_file || $platform->is_windows, 'ICmp binary exists' );
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            system($cmd);
            my $exit_code = $? >> 8;
            is( $exit_code, 42, 'ICmp signed (42 sgt 0 = true) returned 42 on ' . $platform->friendly );
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen ICmp Unsigned (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'icmp_unsigned', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        my $entry    = $func->append_block('entry');
        my $t_block  = $func->append_block('if.then');
        my $f_block  = $func->append_block('if.else');
        $builder->position_at_end($entry);
        my $cond = $builder->build_icmp('ugt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ),
            '%cmp'
        );
        $builder->build_cond_br( $cond, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated unsigned icmp bytes for ' . $platform->friendly );
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = './icmp_unsigned_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -e $output_file || $platform->is_windows, 'ICmp unsigned binary exists' );
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            system($cmd);
            my $exit_code = $? >> 8;
            is( $exit_code, 42, 'ICmp unsigned (42 ugt 0 = true) returned 42 on ' . $platform->friendly );
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen ICmp (Wasm)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'icmp_wasm', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        my $entry    = $func->append_block('entry');
        my $t_block  = $func->append_block('if.then');
        my $f_block  = $func->append_block('if.else');
        $builder->position_at_end($entry);
        my $cond = $builder->build_icmp('sgt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ),
            '%cmp'
        );
        $builder->build_cond_br( $cond, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm icmp bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = './icmp_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm icmp file exists' );
        my $wasmtime_path = `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 42, 'Wasm icmp (42 sgt 0 = true) returned 42';
            }
            else {
                skip 'wasmtime not available', 1;
            }
        }
        unlink $output_file;
    };
    subtest 'Jenny::Codegen ICmp Unsigned (Wasm)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'icmp_unsigned_wasm', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        my $entry    = $func->append_block('entry');
        my $t_block  = $func->append_block('if.then');
        my $f_block  = $func->append_block('if.else');
        $builder->position_at_end($entry);
        my $cond = $builder->build_icmp('ugt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ),
            '%cmp'
        );
        $builder->build_cond_br( $cond, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm unsigned icmp bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = './icmp_unsigned_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm unsigned icmp file exists' );
        my $wasmtime_path = `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 42, 'Wasm unsigned icmp (42 ugt 0 = true) returned 42';
            }
            else {
                skip 'wasmtime not available', 1;
            }
        }
        unlink $output_file;
    };
    subtest 'Jenny::Codegen Arithmetic (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'math', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        # %v1 = 40 + 10 (50)
        my $v1 = $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 40 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 10 ),
            '%v1'
        );

        # %v2 = %v1 - 8 (42)
        my $v2 = $builder->build_sub( $v1, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 8 ), '%v2' );
        $builder->build_ret($v2);
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm math bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = './math_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm math file exists' );

        # Execute using wasmtime or node if available
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
        my $node_path = `which node 2>/dev/null`;
        chomp $node_path if $node_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 42, 'Math Wasm returned 42 via wasmtime';
            }
            elsif ( $node_path && -x $node_path ) {
                my $js = sprintf <<~'', $output_file;
                    const fs = require('fs'); const buf = fs.readFileSync('%s');
                    WebAssembly.instantiate(buf)
                        .then(res => { process.exit(res.instance.exports.main()); })
                        .catch(e => { console.error(e); process.exit(1); });

                system( 'node', '-e', $js );
                is $? >> 8, 42, 'Math Wasm returned 42 via node';
            }
            else {
                skip 'Neither wesmtime nor node are installed', 1;
            }
        }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen i64 Arithmetic (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i64() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        my $v1 = $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 4000000000 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1000000000 ),
            '%v1'
        );
        my $v2 = $builder->build_sub( $v1, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 8 ), '%v2' );
        $builder->build_ret($v2);
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i64 math bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = './i64_math_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i64 math file exists' );
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
        my $node_path = `which node 2>/dev/null`;
        chomp $node_path if $node_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 4999999992, 'i64 math (4000000000+1000000000-8=4999999992) via wasmtime';
            }
            elsif ( $node_path && -x $node_path ) {
                my $js = sprintf <<~'', $output_file;
                    const fs = require('fs'); const buf = fs.readFileSync('%s');
                    WebAssembly.instantiate(buf)
                        .then(res => {
                            const result = res.instance.exports.main();
                            const big = BigInt(result);
                            process.exit(big === 4999999992n ? 0 : 1);
                        })
                        .catch(e => { console.error(e); process.exit(1); });

                system( 'node', '-e', $js );
                is $? >> 8, 0, 'i64 math (4000000000+1000000000-8=4999999992) via node';
            }
            else {
                skip 'Neither wasmtime nor node are installed', 1;
            }
        }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen i64 Memory (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i64() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i64(), '%ptr' );
        $builder->build_store(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 5000000000 ),
            $ptr
        );
        my $val = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $ptr, '%val' );
        $builder->build_ret($val);

        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i64 memory bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = './i64_mem_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i64 memory file exists' );
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
        my $node_path = `which node 2>/dev/null`;
        chomp $node_path if $node_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 5000000000, 'i64 memory store/load 5000000000 via wasmtime';
            }
            elsif ( $node_path && -x $node_path ) {
                my $js = sprintf <<~'', $output_file;
                    const fs = require('fs'); const buf = fs.readFileSync('%s');
                    WebAssembly.instantiate(buf)
                        .then(res => {
                            const result = res.instance.exports.main();
                            const big = BigInt(result);
                            process.exit(big === 5000000000n ? 0 : 1);
                        })
                        .catch(e => { console.error(e); process.exit(1); });

                system( 'node', '-e', $js );
                is $? >> 8, 0, 'i64 memory store/load 5000000000 via node';
            }
            else {
                skip 'Neither wasmtime nor node are installed', 1;
            }
        }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen f32 Arithmetic (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::f32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $v1 = $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 20.5 ),
            '%v1'
        );
        $builder->build_ret($v1);
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm f32 math bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = './f32_math_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm f32 math file exists' );
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
        if ( $wasmtime_path && -x $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file];
            chomp $output;
            ok( abs( $output - 31.0 ) < 0.001, "f32 math (10.5+20.5=31.0) via wasmtime (got $output)" );
        }
        else {
            skip 'wasmtime not available', 1;
        } }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen f64 Arithmetic (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::f64() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $v1 = $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 100.5 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 200.25 ),
            '%v1'
        );
        $builder->build_ret($v1);
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm f64 math bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = './f64_math_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm f64 math file exists' );
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
        if ( $wasmtime_path && -x $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file];
            chomp $output;
            ok( abs( $output - 300.75 ) < 0.001, "f64 math (100.5+200.25=300.75) via wasmtime (got $output)" );
        }
        else {
            skip 'wasmtime not available', 1;
        } }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen Float ICmp (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $c1 = $builder->build_icmp('eq',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c1'
        );
        my $c2 = $builder->build_icmp('ne',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 0.0 ),
            '%c2'
        );
        my $c3 = $builder->build_icmp('lt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 20.5 ),
            '%c3'
        );
        my $c4 = $builder->build_icmp('gt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ),
            '%c4'
        );
        my $c5 = $builder->build_icmp('le',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c5'
        );
        my $c6 = $builder->build_icmp('ge',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ),
            '%c6'
        );
        my $all = $builder->build_and( $c1, $c2, '%a' );
        $all = $builder->build_and( $all, $c3, '%b' );
        $all = $builder->build_and( $all, $c4, '%c' );
        $all = $builder->build_and( $all, $c5, '%d' );
        $all = $builder->build_and( $all, $c6, '%e' );
        my $t_block = $func->append_block('if.then');
        my $f_block = $func->append_block('if.else');
        $builder->build_cond_br( $all, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        print STDERR "\n=== FLOAT ICMP BODY HEX ===\n" . unpack('H*', $res->{body}) . "\n===\n";
        print STDERR "\n=== FLOAT ICMP LOCALS ===\n" . unpack('H*', $res->{locals}) . "\n===\n";

        open my $dbg, '>>', './wasm_hex_dbg.txt' or warn "can't open debug $!";
        print $dbg "\n=== FLOAT ICMP BODY HEX ===\n" . unpack('H*', $res->{body}) . "\n===\n";
        print $dbg "\n=== FLOAT ICMP LOCALS ===\n" . unpack('H*', $res->{locals}) . "\n===\n";
        close $dbg;

        ok( length( $res->{body} ) > 0, 'Generated Wasm float icmp bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = './ficmp_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm float icmp file exists' );
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
        if ( $wasmtime_path && -x $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file];
            chomp $output;
            is( $output, 42, 'Float icmp Wasm returned 42 via wasmtime' );
        }
        else {
            skip 'wasmtime not available', 1;
        } }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen Float Unary MinMax (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $neg = $builder->build_neg(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -42.0 ),
            '%neg'
        );
        my $c1 = $builder->build_icmp('eq',
            $neg, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c1'
        );
        my $abs = $builder->build_abs(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -42.0 ),
            '%abs'
        );
        my $c2 = $builder->build_icmp('eq',
            $abs, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c2'
        );
        my $sqrt = $builder->build_sqrt(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 1764.0 ),
            '%sqrt'
        );
        my $c3 = $builder->build_icmp('eq',
            $sqrt, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c3'
        );
        my $min = $builder->build_min(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 99.0 ),
            '%min'
        );
        my $c4 = $builder->build_icmp('eq',
            $min, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c4'
        );
        my $max = $builder->build_max(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -1.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%max'
        );
        my $c5 = $builder->build_icmp('eq',
            $max, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c5'
        );
        my $all = $builder->build_and( $c1, $c2, '%a' );
        $all = $builder->build_and( $all, $c3, '%b' );
        $all = $builder->build_and( $all, $c4, '%c' );
        $all = $builder->build_and( $all, $c5, '%d' );
        my $t_block = $func->append_block('if.then');
        my $f_block = $func->append_block('if.else');
        $builder->build_cond_br( $all, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm float unary/minmax bytes' );
        open my $dbg2, '>>', './wasm_hex_dbg.txt' or warn "can't open debug $!";
        print $dbg2 "\n=== FLOAT UNARY BODY HEX ===\n" . unpack('H*', $res->{body}) . "\n===\n";
        print $dbg2 "\n=== FLOAT UNARY LOCALS ===\n" . unpack('H*', $res->{locals}) . "\n===\n";
        close $dbg2;
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = './fum_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm float unary/minmax file exists' );
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
        if ( $wasmtime_path && -x $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file];
            chomp $output;
            is( $output, 42, 'Float unary/minmax Wasm returned 42 via wasmtime' );
        }
        else {
            skip 'wasmtime not available', 1;
        } }
        if (-e $output_file) {
            open my $fh2, '<:raw', $output_file or die $!;
            my $data; read($fh2, $data, 999999); close $fh2;
            print STDERR "\n=== FULL WASM HEX ===\n" . unpack('H*', $data) . "\n===\n";
        }
        # unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen Memory Operations (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%ptr' );
        $builder->build_store(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
            $ptr
        );
        my $val = $builder->build_load( Brocken::Lindsay::IR::Type::i32(), $ptr, '%val' );
        $builder->build_ret($val);

        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated memory op bytes for ' . $platform->friendly );

        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();

    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = './mem_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -x $output_file || $platform->is_windows, 'Memory binary exists' );

            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            system($cmd);
            my $exit_code = $? >> 8;
            is( $exit_code, 42, 'Memory binary returned 42 on ' . $platform->friendly );
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen Box/Unbox (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        my $boxed = $builder->build_box(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
            '%boxed'
        );
        my $val = $builder->build_unbox( $boxed, Brocken::Lindsay::IR::Type::i32(), '%val' );
        $builder->build_ret($val);

        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated box/unbox bytes for ' . $platform->friendly );

        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();

    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = './box_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -x $output_file || $platform->is_windows, 'Box/unbox binary exists' );

            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            system($cmd);
            my $exit_code = $? >> 8;
            is( $exit_code, 42, 'Box/unbox binary returned 42 on ' . $platform->friendly );
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen Float Arithmetic (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $fptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::f32(), '%fptr' );
        $builder->build_store(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ),
            $fptr
        );
        my $fv = $builder->build_load( Brocken::Lindsay::IR::Type::f32(), $fptr, '%fv' );
        my $fres = $builder->build_add( $fv, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 20.5 ), '%fres' );
        $builder->build_store( $fres, $fptr );
        my $ret = $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 40 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 2 ),
            '%ret'
        );
        $builder->build_ret($ret);
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated float math bytes for ' . $platform->friendly );
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = './float_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -e $output_file, 'Float math binary exists' );
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            my $ret = system($cmd);
            SKIP: {
                skip "system() failed to spawn ($!)", 1 if $ret == -1;
                my $exit_code = $? >> 8;
                is( $exit_code, 42, 'Float math binary returned 42 on ' . $platform->friendly );
            }
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen Float ICmp (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'icmp_float', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        my $entry    = $func->append_block('entry');
        my $t_block  = $func->append_block('if.then');
        my $f_block  = $func->append_block('if.else');
        $builder->position_at_end($entry);
        my $cond = $builder->build_icmp('lt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 20.5 ),
            '%cmp'
        );
        $builder->build_cond_br( $cond, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated float icmp bytes for ' . $platform->friendly );
        if ( $platform->is_arm64 ) {
            diag 'ARM64 Float ICmp bytes: ' . unpack( 'H*', $bytes );
            diag 'ARM64 Float ICmp length: ' . length($bytes);
        }
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = './ficmp_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -e $output_file, 'Float icmp binary exists' );
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            my $ret = system($cmd);
            SKIP: {
                skip "system() failed to spawn ($!)", 1 if $ret == -1;
                my $exit_code = $? >> 8;
                is( $exit_code, 42, 'Float icmp returned 42 on ' . $platform->friendly );
            }
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen Float Arithmetic Battery (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        # f32 sub: 42.0 - 0.0 = 42.0, stored/loaded
        my $fptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::f32(), '%fptr' );
        $builder->build_store(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            $fptr
        );
        my $fv = $builder->build_load( Brocken::Lindsay::IR::Type::f32(), $fptr, '%fv' );
        $builder->build_sub( $fv, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 0.0 ), '%fres' );

        # f32 mul: 21.0 * 2.0 = 42.0
        my $fptr2 = $builder->build_alloca( Brocken::Lindsay::IR::Type::f32(), '%fptr2' );
        $builder->build_store(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 21.0 ),
            $fptr2
        );
        my $fv2 = $builder->build_load( Brocken::Lindsay::IR::Type::f32(), $fptr2, '%fv2' );
        $builder->build_mul( $fv2, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 2.0 ), '%fres2' );

        # f32 div: 84.0 / 2.0 = 42.0
        my $fptr3 = $builder->build_alloca( Brocken::Lindsay::IR::Type::f32(), '%fptr3' );
        $builder->build_store(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 84.0 ),
            $fptr3
        );
        my $fv3 = $builder->build_load( Brocken::Lindsay::IR::Type::f32(), $fptr3, '%fv3' );
        $builder->build_div( $fv3, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 2.0 ), '%fres3' );

        # f64 add: 21.25 + 20.75 = 42.0
        my $fptr4 = $builder->build_alloca( Brocken::Lindsay::IR::Type::f64(), '%fptr4' );
        $builder->build_store(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 21.25 ),
            $fptr4
        );
        my $fv4 = $builder->build_load( Brocken::Lindsay::IR::Type::f64(), $fptr4, '%fv4' );
        $builder->build_add( $fv4, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 20.75 ), '%fres4' );

        $builder->build_ret(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 )
        );
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated float battery bytes for ' . $platform->friendly );
        if ( $platform->is_arm64 ) {
            diag 'ARM64 Float Battery bytes: ' . unpack( 'H*', $bytes );
            diag 'ARM64 Float Battery length: ' . length($bytes);
        }
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = './fbat_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -e $output_file, 'Float battery binary exists' );
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            my $ret = system($cmd);
            SKIP: {
                skip "system() failed to spawn ($!)", 1 if $ret == -1;
                my $exit_code = $? >> 8;
                is( $exit_code, 42, 'Float battery returned 42 on ' . $platform->friendly );
            }
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen Float Unary MinMax (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        # f32 neg: neg(-42.0) == 42.0
        my $neg = $builder->build_neg(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -42.0 ),
            '%neg'
        );
        my $c1 = $builder->build_icmp('eq',
            $neg, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c1'
        );

        # f32 abs: abs(-42.0) == 42.0
        my $abs = $builder->build_abs(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -42.0 ),
            '%abs'
        );
        my $c2 = $builder->build_icmp('eq',
            $abs, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c2'
        );

        # f32 sqrt: sqrt(1764.0) == 42.0
        my $sqrt = $builder->build_sqrt(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 1764.0 ),
            '%sqrt'
        );
        my $c3 = $builder->build_icmp('eq',
            $sqrt, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c3'
        );

        # f32 min: min(42.0, 99.0) == 42.0
        my $min = $builder->build_min(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 99.0 ),
            '%min'
        );
        my $c4 = $builder->build_icmp('eq',
            $min, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c4'
        );

        # f32 max: max(-1.0, 42.0) == 42.0
        my $max = $builder->build_max(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -1.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%max'
        );
        my $c5 = $builder->build_icmp('eq',
            $max, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c5'
        );

        # Combine all conditions with AND
        my $all = $builder->build_and( $c1, $c2, '%a' );
        $all = $builder->build_and( $all, $c3, '%b' );
        $all = $builder->build_and( $all, $c4, '%c' );
        $all = $builder->build_and( $all, $c5, '%d' );

        my $t_block = $func->append_block('if.then');
        my $f_block = $func->append_block('if.else');
        $builder->build_cond_br( $all, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );

        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated float unary/minmax bytes for ' . $platform->friendly );
        if ( $platform->is_arm64 ) {
            diag 'ARM64 Float Unary bytes: ' . unpack( 'H*', $bytes );
            diag 'ARM64 Float Unary length: ' . length($bytes);
        }
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = './fum_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -e $output_file, 'Float unary/minmax binary exists' );
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            my $ret = system($cmd);
            SKIP: {
                skip "system() failed to spawn ($!)", 1 if $ret == -1;
                my $exit_code = $? >> 8;
                is( $exit_code, 42, 'Float unary/minmax returned 42 on ' . $platform->friendly );
            }
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen Memory Operations (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%ptr' );
        $builder->build_store(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
            $ptr
        );
        my $val = $builder->build_load( Brocken::Lindsay::IR::Type::i32(), $ptr, '%val' );
        $builder->build_ret($val);

        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm memory bytes' );

        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = './mem_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm memory file exists' );

        my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
        my $node_path = `which node 2>/dev/null`;
        chomp $node_path if $node_path;
    SKIP: {
            if ( $wasmtime_path && -f $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 42, 'Memory Wasm returned 42 via wasmtime';
            }
            elsif ( $node_path && -x $node_path ) {
                my $js = 'const fs=require("fs");const buf=fs.readFileSync("' . $output_file . '");'
                    . 'WebAssembly.instantiate(buf)'
                    . '.then(res=>{process.exit(res.instance.exports.main());})'
                    . '.catch(e=>{console.error(e);process.exit(1);});';
                system( 'node', '-e', $js );
                is $? >> 8, 42, 'Memory Wasm returned 42 via node';
            }
            else {
                skip 'Neither wasmtime nor node are installed', 1;
            }
        }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen Box/Unbox (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        my $boxed = $builder->build_box(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
            '%boxed'
        );
        my $val = $builder->build_unbox( $boxed, Brocken::Lindsay::IR::Type::i32(), '%val' );
        $builder->build_ret($val);

        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm box/unbox bytes' );

        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = './box_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm box/unbox file exists' );

        my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
        my $node_path = `which node 2>/dev/null`;
        chomp $node_path if $node_path;
    SKIP: {
            if ( $wasmtime_path && -f $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 42, 'Box/unbox Wasm returned 42 via wasmtime';
            }
            elsif ( $node_path && -x $node_path ) {
                my $js = 'const fs=require("fs");const buf=fs.readFileSync("' . $output_file . '");'
                    . 'WebAssembly.instantiate(buf)'
                    . '.then(res=>{process.exit(res.instance.exports.main());})'
                    . '.catch(e=>{console.error(e);process.exit(1);});';
                system( 'node', '-e', $js );
                is $? >> 8, 42, 'Box/unbox Wasm returned 42 via node';
            }
            else {
                skip 'Neither wasmtime nor node are installed', 1;
            }
        }
        unlink $output_file if -e $output_file;
    };
    subtest 'RegAlloc::LinearScan basic allocation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        my $mf = Brocken::Jenny::MIR::MachineFunction->new( name => 'test', blocks => [
            Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry', instructions => [
                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [
                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%0' ),
                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ),
                ] ),
                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [
                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%1' ),
                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 2 ),
                ] ),
                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] ),
            ] ),
        ] );
        my $alloc  = Brocken::Jenny::RegAlloc::LinearScan->new();
        my $result = $alloc->allocate( $mf, $platform );
        ok defined $result->{assignment}, 'assignment map returned';
        ok exists $result->{assignment}{'%0'}, '%0 allocated';
        ok exists $result->{assignment}{'%1'}, '%1 allocated';
        is scalar( $result->{used_callee}->@* ), 0, 'no callee regs used with 2 vregs on x86_64';
        is scalar( keys $result->{spill_slots}->%* ), 0, 'no spills needed';
        ok defined $result->{spill_temp}, 'spill temp defined';
    };
    subtest 'RegAlloc::LinearScan callee-saved allocation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        my $alloc  = Brocken::Jenny::RegAlloc::LinearScan->new();
        my @intervals;
        for my $i ( 0 .. 10 ) {
            push @intervals, Brocken::Jenny::RegAlloc::LiveInterval->new( name => "%$i", start => 0, end => 10 );
        }
        my $result = $alloc->_linear_scan( \@intervals, $platform, 0 );
        ok ( scalar( $result->{used_callee}->@* ) > 0 ), 'callee registers used when 11 overlapping vregs on x86_64';
    };
    subtest 'RegAlloc::LinearScan spilling' => sub {
        my $platform = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        my $alloc  = Brocken::Jenny::RegAlloc::LinearScan->new();
        my @intervals;
        for my $i ( 0 .. 19 ) {
            push @intervals, Brocken::Jenny::RegAlloc::LiveInterval->new( name => "%$i", start => 0, end => 10 );
        }
        my $result = $alloc->_linear_scan( \@intervals, $platform, 0 );
        ok ( scalar( keys $result->{spill_slots}->%* ) > 0 ), 'spill slots created with 20 overlapping vregs';
    };
    subtest 'RegAlloc::LinearScan insert_spill_code' => sub {
        my $mf = Brocken::Jenny::MIR::MachineFunction->new( name => 'test', blocks => [
            Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry', instructions => [
                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [
                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%v0' ),
                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 1 ),
                ] ),
                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [
                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%v1' ),
                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%v0' ),
                ] ),
                Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] ),
            ] ),
        ] );
        my $spill_slots = { '%v0' => 0, '%v1' => 8 };
        my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new();
        $alloc->insert_spill_code( $mf, $spill_slots, 'r9', 'rsp' );
        my @all_ops;
        for my $bb ( $mf->blocks->@* ) {
            for my $inst ( $bb->instructions->@* ) {
                push @all_ops, $inst->opcode;
            }
        }
        ok grep( /^load$/,  @all_ops ), 'spill-reload loads inserted';
        ok grep( /^store$/, @all_ops ), 'spill-store stores inserted';
    };
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
