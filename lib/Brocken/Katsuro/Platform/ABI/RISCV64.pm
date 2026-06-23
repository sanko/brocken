use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::ABI;

class Brocken::Katsuro::Platform::ABI::RISCV64 : isa(Brocken::Katsuro::Platform::ABI) {

    # RISC-V Calling Convention (lp64)
    # SCRATCH: a0-a7, t0-t6
    # PRESERVED: s0-s11, sp, gp, tp, ra
    method registers( $category = 'available' ) {
        my %data = (

            # Order matters: t0-t6 (non-param caller regs) come before a1-a7 (param caller regs)
            # to avoid register allocator assigning vregs to param regs that get clobbered
            # by argument-setup mov instructions in the Lowerer.
            available => [qw[a0 t0 t1 t2 t3 t4 t5 t6 a1 a2 a3 a4 a5 a6 a7 s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11]],
            caller    => [qw[a0 t0 t1 t2 t3 t4 t5 t6 a1 a2 a3 a4 a5 a6 a7]],
            callee    => [qw[s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11]]
        );
        return $data{$category} // [];
    }
    method frame_reg()          {'s0'}
    method stack_reg()          {'sp'}
    method param_registers()       { [qw(a0 a1 a2 a3 a4 a5 a6 a7)] }
    method fp_param_registers()    { [qw(f0 f1 f2 f3 f4 f5 f6 f7)] }
    method return_register()       {'a0'}
    method fp_return_register()    {'f0'}
    method fiber_reg()             {'s11'}

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

=encoding utf-8

=head1 NAME

Brocken::Katsuro::Platform::ABI::RISCV64 - RISC-V 64-bit ABI Register Definitions

=head1 DESCRIPTION

Defines the RISC-V LP64/LP64D calling convention register sets: scratch (caller-saved), preserved (callee-saved),
parameter passing, and DWARF register numbering.

=head2 Register Ordering

The caller register list is intentionally ordered with non-parameter registers (t0-t6) before parameter registers
(a1-a7). This mirrors the same fix applied to the ARM64 ABI: it prevents the register allocator from assigning virtual
registers to a1-a7, which would be clobbered by argument-setup MOV instructions in the Lowerer.

=head2 Register Sets

=over 4

=item * B<Caller-saved>: a0, t0-t6, a1-a7

=item * B<Callee-saved>: s1-s11

=item * B<FP frame>: s0

=item * B<Stack>: sp

=item * B<Parameters>: a0-a7

=item * B<Return>: a0

=item * B<FP return>: v0

=item * B<FP caller-saved>: f0-f7, f10-f17, f28-f31

=item * B<FP callee-saved>: f8-f9, f18-f27

=back

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
