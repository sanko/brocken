use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::ABI;

class Brocken::Katsuro::Platform::ABI::AArch64 : isa(Brocken::Katsuro::Platform::ABI) {

    # ARM64 Procedure Call Standard (AAPCS64)
    # SCRATCH: x0-x15
    # PRESERVED: x19-x28, sp, x29 (fp), x30 (lr)
    method registers( $category = 'available' ) {
        my %data = (

            # Order matters: x9-x15 (non-param caller regs) come before x1-x7 (param caller regs)
            # to avoid register allocator assigning vregs to param regs that get clobbered
            # by argument-setup mov instructions in the Lowerer.
            # x18 is the platform register per AAPCS64 - reserved on Android/iOS/macOS
            # x19-x28 are callee-saved
            available => [qw[x0 x9 x10 x11 x12 x13 x14 x15 x1 x2 x3 x4 x5 x6 x7 x19 x20 x21 x22 x23 x24 x25 x26 x27 x28]],
            caller    => [qw[x0 x9 x10 x11 x12 x13 x14 x15 x1 x2 x3 x4 x5 x6 x7]],
            callee    => [qw[x19 x20 x21 x22 x23 x24 x25 x26 x27 x28]]
        );
        return $data{$category} // [];
    }
    method frame_reg()          {'x29'}
    method stack_reg()          {'sp'}
    method param_registers()       { [qw(x0 x1 x2 x3 x4 x5 x6 x7)] }
    method fp_param_registers()    { [qw(v0 v1 v2 v3 v4 v5 v6 v7)] }
    method return_register()       {'x0'}
    method fp_return_register()    {'v0'}
    method fiber_reg()             {'x28'}

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

=encoding utf-8

=head1 NAME

Brocken::Katsuro::Platform::ABI::AArch64 - ARM64 ABI Register Definitions

=head1 DESCRIPTION

Defines the ARM64 Procedure Call Standard (AAPCS64) register sets: scratch (caller-saved), preserved (callee-saved),
parameter passing, and DWARF register numbering.

=head2 Register Ordering

The caller register list is intentionally ordered with non-parameter registers (x9-x15) before parameter registers
(x1-x7). This prevents the register allocator from assigning virtual registers to x1-x7, which would be clobbered by
argument-setup MOV instructions in the Lowerer.

=head2 Register Sets

=over 4

=item * B<Caller-saved>: x0, x9-x15, x1-x7

=item * B<Callee-saved>: x20-x28

=item * B<FP frame>: x29 (fp)

=item * B<Stack>: sp

=item * B<Parameters>: x0-x7

=item * B<Return>: x0

=item * B<FP return>: v0

=item * B<FP caller-saved>: v0-v7

=item * B<FP callee-saved>: v8-v15 (lower 64 bits only)

=back

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
