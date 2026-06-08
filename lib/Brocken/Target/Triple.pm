# lib/Brocken/Target/Triple.pm
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Target::Triple {
    field $raw_string : param;
    field $arch       : reader = 'x86_64';
    field $vendor     : reader = 'unknown';
    field $os         : reader = 'linux';
    field $abi        : reader = 'gnu';
    field $format     : reader = 'elf';
    my %ARCH_MAP = ( 'x86_64' => 'X64', 'amd64' => 'X64', 'x64' => 'X64', 'aarch64' => 'ARM64', 'arm64' => 'ARM64', 'riscv64' => 'RISC64' );
    my %OS_MAP   = (
        'linux'   => 'Unix',
        'unix'    => 'Unix',
        'freebsd' => 'FreeBSD',
        'darwin'  => 'macOS',
        'macos'   => 'macOS',
        'windows' => 'Windows',
        'win32'   => 'Windows',
        'mswin'   => 'Windows'
    );
    my %FORMAT_MAP
        = ( 'elf' => 'ELF', 'macho' => 'MachO', 'mach-o' => 'MachO', 'darwin' => 'MachO', 'pe' => 'PE', 'coff' => 'PE', 'windows' => 'PE' );
    my %KNOWN_VENDORS = map { $_ => 1 } qw[pc apple unknown w64 ibm hp sun amd];
    ADJUST {
        my @parts = split /-/, $raw_string;
        if ( @parts == 4 ) {
            ( $arch, $vendor, $os, $abi ) = @parts;
        }
        elsif ( @parts == 3 ) {
            if ( exists $KNOWN_VENDORS{ lc( $parts[1] ) } ) {
                ( $arch, $vendor, $os ) = @parts;
                $abi = 'unknown';
            }
            else {
                ( $arch, $os, $abi ) = @parts;
                $vendor = 'unknown';
            }
        }
        elsif ( @parts == 2 ) {
            ( $arch, $os ) = @parts;
            $vendor = 'unknown';
            $abi    = 'unknown';
        }
        elsif ( @parts == 1 ) {
            $arch = $parts[0];
        }
        $arch   = lc($arch);
        $vendor = lc($vendor);
        $os     = lc($os);
        $abi    = lc($abi);
        if ( $os eq 'windows' || $abi eq 'pe' || $abi eq 'msvc' ) {
            $format = 'pe';
        }
        elsif ( $os eq 'macos' || $os eq 'darwin' || $abi eq 'macho' ) {
            $format = 'macho';
        }
        else {
            $format = 'elf';
        }
    }

    method class_arch() {
        return $ARCH_MAP{$arch} // uc($arch);
    }

    method class_os() {
        return $OS_MAP{$os} // ucfirst($os);
    }

    method class_format() {
        return $FORMAT_MAP{$format} // uc($format);
    }

    method is_x64() {
        return ( $self->class_arch eq 'X64' ) ? 1 : 0;
    }

    method is_arm64() {
        return ( $self->class_arch eq 'ARM64' ) ? 1 : 0;
    }

    method is_riscv64() {
        return ( $self->class_arch eq 'RISC64' ) ? 1 : 0;
    }

    method is_linux() {
        return ( $os eq 'linux' ) ? 1 : 0;
    }

    method is_windows() {
        return ( $self->class_os eq 'Windows' ) ? 1 : 0;
    }

    method is_macos() {
        return ( $self->class_os eq 'macOS' ) ? 1 : 0;
    }

    method to_string() {
        return "$arch-$vendor-$os-$abi";
    }
}
1;
