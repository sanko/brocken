use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::ABI::X86_64;

class Brocken::Katsuro::Platform::ABI::X86_64_Win64 : isa(Brocken::Katsuro::Platform::ABI::X86_64) {

    # Windows x64 Calling Convention
    # SCRATCH: rax, rcx, rdx, r8, r9, r10, r11
    # PRESERVED: rbx, rsi, rdi, rbp, rsp, r12, r13, r14, r15
    # Key difference from SysV: rsi and rdi are callee-saved on Win64, caller-saved on SysV
    method registers( $category = 'available' ) {
        my %data = (
            available => [qw[rax rcx rdx rbx rsi rdi r8 r9 r10 r11 r12 r13 r14 r15]],
            caller    => [qw[rax rcx rdx r8 r9 r10 r11]],
            callee    => [qw[rbx rsi rdi r12 r13 r14 r15]]
        );
        return $data{$category} // [];
    }

    # Windows x64: xmm0-xmm5 volatile (caller-saved), xmm6-xmm15 non-volatile (callee-saved)
    method fp_registers( $category = 'available' ) {
        my %data = (
            available => [qw[xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7 xmm8 xmm9 xmm10 xmm11 xmm12 xmm13 xmm14 xmm15]],
            caller    => [qw[xmm0 xmm1 xmm2 xmm3 xmm4 xmm5]],
            callee    => [qw[xmm6 xmm7 xmm8 xmm9 xmm10 xmm11 xmm12 xmm13 xmm14 xmm15]],
        );
        return $data{$category} // [];
    }

    # Win64 parameter passing: rcx, rdx, r8, r9 (4 integer regs, versus 6 on SysV)
    method param_registers()    { [qw(rcx rdx r8 r9)] }
    method fp_param_registers() { [qw(xmm0 xmm1 xmm2 xmm3)] }
}

=encoding utf-8

=head1 NAME

Brocken::Katsuro::Platform::ABI::X86_64_Win64 - Windows x64 ABI Register Definitions

=head1 DESCRIPTION

Defines the Microsoft x64 calling convention register sets: volatile (caller-saved), non-volatile (callee-saved),
parameter passing, and DWARF register numbering.

=head2 Key Differences from SysV AMD64

=over 4

=item * B<Parameter registers>: rcx, rdx, r8, r9 (6 on SysV)

=item * B<FP parameter registers>: xmm0-xmm3 (8 on SysV)

=item * B<Callee-saved integers>: rbx, rsi, rdi, r12-r15 (rsi/rdi are caller-saved on SysV)

=item * B<Callee-saved FP>: xmm6-xmm15 (all xmm are caller-saved on SysV)

=item * B<Shadow space>: 32 bytes at top of caller's frame (home space for rcx, rdx, r8, r9)

=back

=head2 Register Sets

=over 4

=item * B<Caller-saved>: rax, rcx, rdx, r8, r9, r10, r11

=item * B<Callee-saved>: rbx, rsi, rdi, r12, r13, r14, r15

=item * B<Parameters>: rcx, rdx, r8, r9

=item * B<Return>: rax

=item * B<FP return>: xmm0

=item * B<FP caller-saved>: xmm0-xmm5

=item * B<FP callee-saved>: xmm6-xmm15

=back

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
