# lib/Brocken/Target.pm
use v5.40;
use feature q[class];
no warnings qw[experimental::class experimental::builtin];

class Brocken::Target {
    field $triple : param;
    field $arch   : reader;
    field $os     : reader;
    field $format : reader;
    ADJUST {
        my ( $arch_name, $os_name, $format_name ) = split /-/, $triple;
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
        my $native_insts   = $arch->lower_cfg($cfg);
        my $allocated_code = $arch->allocate_registers($native_insts);
        my $code_bytes     = $arch->assemble( $allocated_code, $os );
        $format->write_executable( $output_file, $code_bytes, $triple );
    }
}
1;
