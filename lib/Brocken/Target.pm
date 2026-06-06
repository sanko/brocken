use v5.40;
use feature q[class];
no warnings qw[experimental::class experimental::builtin];
#
class Brocken::Target {
    field $triple : param;    # Triple format: arch-os-format (e.g., x86_64-linux-elf, arm64-macos-macho)
    field $arch   : reader;
    field $os     : reader;
    field $format : reader;

    # Run during object construction to load driver backends
    ADJUST {
        my ( $arch_name, $os_name, $format_name ) = split /-/, $triple;

        # Dynamically load the correct backend drivers
        my $arch_class   = "Brocken::Target::Architecture::" . uc($arch_name);
        my $os_class     = "Brocken::Target::OS::" . ucfirst($os_name);
        my $format_class = "Brocken::Target::Format::" . ucfirst($format_name);
        builtin::load_module $arch_class;
        builtin::load_module $os_class;
        builtin::load_module $format_class;
        $arch   = $arch_class->new();
        $os     = $os_class->new();
        $format = $format_class->new();
    }

    method compile ( $cfg, $output_file ) {

        # Lower the IR to target-specific assembly / instructions
        my $native_insts = $arch->lower_cfg($cfg);

        # Perform Register Allocation (assign physical registers / handle spills)
        my $allocated_code = $arch->allocate_registers($native_insts);

        # Assemble code into raw machine bytes
        my $code_bytes = $arch->assemble($allocated_code);

        # Hand off bytes to the file format emitter
        $format->write_executable( output_file => $output_file, code_bytes => $code_bytes, os => $os, arch => $arch, );
    }
}
#
1;
