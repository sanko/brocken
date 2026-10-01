use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
#
class Brocken v0.0.1 {
    use Brocken::Katsuro;
    use Brocken::Lindsay;
    use Brocken::Jenny;
    use Brocken::Jenny::Codegen::X86_64;
    use Brocken::Jenny::Codegen::ARM64;
    use Brocken::Jenny::Codegen::RISCV64;
    use Brocken::Jenny::Linker::MachO;
    use Brocken::Jenny::Linker::PE;
    use Brocken::Jenny::Linker::ELF64;
    use File::Temp;
    #
    our $default_fuel         = 1000000;    # initial fuel budget for entry function
    our $default_mem_limit    = 0;          # 0 = unlimited; max heap bytes per isolate
    our $default_capabilities = ~0;         # all capabilities enabled by default

    # Capability bitmask constants
    our $CAP_FS_READ  = 1 << 0;             # 1   - file system read
    our $CAP_FS_WRITE = 1 << 1;             # 2   - file system write
    our $CAP_NET      = 1 << 2;             # 4   - network access
    our $CAP_SYSTEM   = 1 << 3;             # 8   - system() / process spawn
    our $CAP_FFI      = 1 << 4;             # 16  - syscall / libc / raw FFI

    #
    field $platform    : reader : param = Brocken::Katsuro::Platform::parse();
    field $debug_level : reader : param = 0;
    field $codegen     : reader;
    field $linker      : reader;
    field $ext         : reader = '';
    field $tmpdir      : reader = File::Temp->newdir( CLEANUP => 1 );
    #
    ADJUST {
        if ( $platform->is_arm64 && $platform->is_macos ) {
            $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::MachO->new();
        }
        elsif ( $platform->is_arm64 && $platform->is_windows ) {
            $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::PE->new();
            $ext     = '.exe';
        }
        elsif ( $platform->is_arm64 ) {
            $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::ELF64->new();
        }
        elsif ( $platform->is_riscv64 ) {
            $codegen = Brocken::Jenny::Codegen::RISCV64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::ELF64->new();
        }
        elsif ( $platform->is_x64 && $platform->is_macos ) {
            $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::MachO->new();
        }
        elsif ( $platform->is_x64 && $platform->is_windows ) {
            $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::PE->new();
            $ext     = '.exe';
        }
        elsif ( $platform->is_x64 ) {
            $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::ELF64->new();
        }
        else {
            die 'Unsupported platform for Brocken: ' . $platform->friendly;
        }
    }
    method os()   { return $platform->os }
    method arch() { return $platform->arch }
};
#
1;
