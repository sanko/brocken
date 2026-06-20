use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform;

class Brocken::Katsuro::Platform::MacOS : isa(Brocken::Katsuro::Platform) {
    method is_macos() {1}
    method lib_ext()  {'.dylib'}
    method format()   {'macho'}

    method shared_lib_name( $name, $version = undef ) {
        my $pre = $self->lib_prefix . $name;
        return $pre . $self->lib_ext if !defined $version;
        return "$pre.$version" . $self->lib_ext;
    }

    # macOS syscalls use a 0x2000000 offset for 64-bit processes to distinguish
    # from Mach-specific or 32-bit BSD syscalls.
    method syscalls() {
        state $syscalls;
        return $syscalls if defined $syscalls;
        my $off64 = 0x2000000;
        $syscalls = {
            x86_64 => {
                write     => $off64 + 4,
                read      => $off64 + 3,
                open      => $off64 + 5,
                close     => $off64 + 6,
                exit      => $off64 + 1,
                fork      => $off64 + 2,
                getpid    => $off64 + 20,
                wait4     => $off64 + 7,
                mmap      => $off64 + 197,
                nanosleep => $off64 + 101,
                brk       => $off64 + 45
            },
            aarch64 => {
                write     => $off64 + 4,
                read      => $off64 + 3,
                open      => $off64 + 5,
                close     => $off64 + 6,
                exit      => $off64 + 1,
                fork      => $off64 + 2,
                getpid    => $off64 + 20,
                wait4     => $off64 + 11,
                mmap      => $off64 + 197,
                nanosleep => $off64 + 101,
                brk       => $off64 + 45
            }
        };
    }

    # On ARM64 macOS, x16 is used for the syscall number instead of x8.
    method syscall_num_reg() {
        my %map = ( x86_64 => 'rax', aarch64 => 'x16', riscv64 => 'a7' );
        return $map{ $self->arch };
    }
}

=encoding utf-8

=head1 NAME

Brocken::Katsuro::Platform::MacOS - macOS Platform Abstraction

=head1 DESCRIPTION

Concrete platform class for macOS (Darwin). Provides Mach-O binary format support, macOS-specific syscall numbers (with
0x2000000 64-bit offset), and correct library naming conventions (.dylib). On ARM64 macOS, syscall numbers are passed
in x16 rather than x8.

=head1 METHODS

=head2 is_macos

Returns true (1).

=head2 lib_ext

Returns '.dylib'.

=head2 format

Returns 'macho'.

=head2 syscalls

Returns syscall number tables with the 64-bit offset (0x2000000) applied.

=head2 syscall_num_reg

Returns the register used to pass syscall numbers: rax (x86_64), x16 (aarch64), or a7 (riscv64). Note the x16 vs x8
difference on ARM64 macOS.

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
