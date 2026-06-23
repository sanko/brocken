use v5.42;
use feature qw[class];
no warnings qw[experimental::class experimental::builtin];

class Brocken::Katsuro::Platform::ABI {

    sub parse ( $class, $arch, $os = undef ) {
        if ( $arch =~ /x86_64|x64|amd64/i && defined $os && $os =~ /windows|win32|mswin/i ) {
            $class = 'Brocken::Katsuro::Platform::ABI::X86_64_Win64';
        }
        elsif ( $arch =~ /x86_64|x64|amd64/i ) { $class = 'Brocken::Katsuro::Platform::ABI::X86_64' }
        elsif ( $arch =~ /aarch64|arm64/i )    { $class = 'Brocken::Katsuro::Platform::ABI::AArch64' }
        elsif ( $arch =~ /riscv64/i )          { $class = 'Brocken::Katsuro::Platform::ABI::RISCV64' }
        builtin::load_module $class;
        return $class->new;
    }
    method registers( $category = 'available' )    { [] }
    method fp_registers( $category = 'available' ) { [] }
    method caller_saved()                          { $self->registers('caller') }
    method callee_saved()                          { $self->registers('callee') }
    method frame_reg()                             {undef}
    method stack_reg()                             {undef}
    method dwarf_reg_num($name)                    {undef}
    method param_registers()                       { [] }
    method fp_param_registers()                    { [] }
    method return_register()                       {undef}
    method fp_return_register()                    {undef}
    method fiber_reg()                             {undef}
}

=head1 NAME

Brocken::Katsuro::Platform::ABI - Low-level Architecture Binary Interface details

=head1 DESCRIPTION

This class and its subclasses define the register sets and DWARF numbering for specific architectures. It abstracts the
differences between calling conventions (e.g., which registers are preserved across calls).

=cut

1;
