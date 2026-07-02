use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform;

class Brocken::Katsuro::Platform::Linux : isa(Brocken::Katsuro::Platform) {
    method is_linux() {1}
    method format()   {'elf'}

    method libc_name() {
        return 'libc.so.6';
    }
    method libpthread_name() {'libpthread.so.0'}

    method interpreter() {
        return '/lib/ld-linux-aarch64.so.1'       if $self->is_arm64;
        return '/lib/ld-linux-riscv64-lp64d.so.1' if $self->is_riscv64;
        return '/lib64/ld-linux-x86-64.so.2';
    }
    method needs_sched_setaffinity() {1}

    # Linux-specific syscall numbers. These differ significantly from BSD.
    method syscalls() {
        state $syscalls //= {
            x86_64 => {
                write     => 1,
                read      => 0,
                open      => 2,
                close     => 3,
                exit      => 60,
                fork      => 57,
                getpid    => 39,
                wait4     => 61,
                mmap      => 9,
                nanosleep => 35,
                futex     => 202,
                brk       => 12
            },
            aarch64 => {
                write     => 64,
                read      => 63,
                open      => 56,
                close     => 57,
                exit      => 93,
                fork      => 220,
                getpid    => 172,
                wait4     => 260,
                mmap      => 222,
                nanosleep => 101,
                futex     => 98,
                brk       => 214
            },
            riscv64 => {
                write     => 64,
                read      => 63,
                open      => 56,
                close     => 57,
                exit      => 93,
                fork      => 220,
                getpid    => 172,
                wait4     => 260,
                mmap      => 222,
                nanosleep => 101,
                futex     => 98,
                brk       => 214
            }
        };
        $syscalls;
    }
}

=encoding utf-8

=head1 NAME

Brocken::Katsuro::Platform::Linux - Linux Platform Abstraction

=head1 DESCRIPTION

Concrete platform class for Linux. Provides Linux-specific syscall numbers for x86_64, aarch64, and riscv64
architectures. Linux uses ELF binary format.

=head1 METHODS

=head2 is_linux

Returns true (1).

=head2 format

Returns 'elf'.

=head2 syscalls

Returns a hashref architecture-specific syscall number tables (write, read, open, close, exit, fork, getpid, wait4,
mmap, nanosleep, futex, brk).

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
