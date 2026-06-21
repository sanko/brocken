use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::ABI;

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
    method frame_reg()          {'rbp'}
    method stack_reg()          {'rsp'}
    method param_registers()    { [qw(rdi rsi rdx rcx r8 r9)] }
    method return_register()    {'rax'}
    method fp_return_register() {'xmm0'}
    method fiber_reg()          {'r12'}

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

=encoding utf-8

=head1 NAME

Brocken::Katsuro::Platform::ABI::X86_64 - x86_64 ABI Register Definitions

=head1 DESCRIPTION

Defines the System V AMD64 calling convention register sets: scratch (caller-saved), preserved (callee-saved),
parameter passing, and DWARF register numbering.

=head2 Register Sets

=over 4

=item * B<Caller-saved>: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11

=item * B<Callee-saved>: rbx, r12, r13, r14, r15

=item * B<Parameters>: rdi, rsi, rdx, rcx, r8, r9

=item * B<Return>: rax

=item * B<FP return>: xmm0

=item * B<FP caller-saved>: xmm0-xmm15 (all)

=back

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
