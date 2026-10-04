use v5.42;
use feature qw[class];
no warnings qw[experimental::class experimental::builtin];
class Brocken::Katsuro::Platform::ABI v0.0.1 {
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

    # Whether the two register classes share their positions.  SysV, AArch64,
    # and RISC-V keep an independent counter per class; Win64 numbers
    # positions 1-4 across both, so the position decides the register and the
    # fifth argument goes on the stack whatever its class.
    method positional_arguments() {0}

    # The pair of parameter registers a 128-bit argument takes when $spent
    # integer registers have already been consumed, or an empty list when fewer
    # than two remain and the value has to go on the stack.  The pair is always
    # consecutive in the parameter list.
    method param_pair_registers($spent) {
        my @gp = $self->param_registers->@*;
        return if $spent + 1 >= @gp;
        return @gp[ $spent, $spent + 1 ];
    }

    # The two registers a 128-bit result is returned in, the return register
    # first.  An ABI that returns a wide value in a different pair overrides
    # this.
    method return_pair_registers() {
        my $first = $self->return_register;
        return defined $first ? ($first) : ();
    }

    # Where each argument goes, in order.  $classes is an arrayref with one
    # class name per argument: 'int', 'float', or 'i128'.  Each entry of the
    # result is the name of the register the argument is passed in, [ $lo, $hi ]
    # for a 128-bit argument that takes a consecutive register pair, or
    # [ 'stack', $slot ] for an argument the registers cannot carry.  A 128-bit
    # stack argument names its low slot and occupies the next one as well.
    method argument_locations($classes) {
        return $self->positional_arguments ? $self->_positional_argument_locations($classes) : $self->_independent_argument_locations($classes);
    }

    method _independent_argument_locations($classes) {
        my @gp = $self->param_registers->@*;
        my @fp = $self->fp_param_registers->@*;
        my ( $gi, $fi, $si ) = ( 0, 0, 0 );
        my @out;
        for my $class (@$classes) {
            if ( $class eq 'i128' ) {
                my ( $lo, $hi ) = $self->param_pair_registers($gi);
                if ( defined $hi ) {
                    push @out, [ $lo, $hi ];
                    $gi += 2;
                }
                else {
                    push @out, [ 'stack', $si ];
                    $si += 2;
                }
            }
            elsif ( $class eq 'float' ) {
                push @out, $fi < @fp ? $fp[ $fi++ ] : [ 'stack', $si++ ];
            }
            else {
                push @out, $gi < @gp ? $gp[ $gi++ ] : [ 'stack', $si++ ];
            }
        }
        return \@out;
    }

    method _positional_argument_locations($classes) {
        my @gp        = $self->param_registers->@*;
        my @fp        = $self->fp_param_registers->@*;
        my $positions = @gp < @fp ? @gp : @fp;
        my ( $pos, $si ) = ( 0, 0 );
        my @out;
        for my $class (@$classes) {
            if ( $class eq 'i128' ) {
                if ( $pos + 1 < $positions ) {
                    push @out, [ $gp[$pos], $gp[ $pos + 1 ] ];
                }
                else {
                    push @out, [ 'stack', $si ];
                    $si += 2;
                }
                $pos += 2;
            }
            elsif ( $class eq 'float' ) {
                push @out, $pos < $positions ? $fp[$pos] : [ 'stack', $si++ ];
                $pos++;
            }
            else {
                push @out, $pos < $positions ? $gp[$pos] : [ 'stack', $si++ ];
                $pos++;
            }
        }
        return \@out;
    }
} 1;
