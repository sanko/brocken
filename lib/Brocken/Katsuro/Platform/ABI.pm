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

    # Byte offset of the $index-th stack-passed parameter.
    # On entry %stack_reg points at the return address, so an offset of 8 is
    # the first byte above it.  undef means the ABI passes every parameter in
    # a register and has no stack argument area.
    method stack_param_offset($index) {undef}

    # Byte offset, from the caller's %stack_reg at the call instruction, where
    # the $index-th stack-passed argument has to be written.  This is *not*
    # the same as stack_param_offset: the return address the call pushes below
    # the arguments, and any shadow space, both sit between the two.
    method caller_stack_param_offset($index) {undef}
    method return_register()                 {undef}
    method fp_return_register()              {undef}
    method fiber_reg()                       {undef}
}
#
1;
