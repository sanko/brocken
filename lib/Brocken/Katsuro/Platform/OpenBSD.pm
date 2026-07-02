use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::BSD;

class Brocken::Katsuro::Platform::OpenBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_openbsd() {1}
    method libc_name()       {'libc.so.98.1'}
    method libpthread_name() {'libpthread.so'}
    method interpreter()     {'/usr/libexec/ld.so'}

    # OpenBSD uses its own syscall numbering lineage (derived from 4.4BSD with local changes).
    # Key difference from FreeBSD: mmap=197 (not 477). Other common syscalls share numbers
    # across all BSDs on x86_64.
    method syscalls() {
        return {
            x86_64 => {
                write     => 4,
                read      => 3,
                open      => 5,
                close     => 6,
                exit      => 1,
                fork      => 2,
                getpid    => 20,
                wait4     => 7,
                mmap      => 197,
                nanosleep => 240,
                brk       => 45
            },
            aarch64 => {
                write     => 4,
                read      => 3,
                open      => 5,
                close     => 6,
                exit      => 1,
                fork      => 2,
                getpid    => 20,
                wait4     => 7,
                mmap      => 197,
                nanosleep => 240,
                brk       => 45
            },
            riscv64 => {
                write     => 4,
                read      => 3,
                open      => 5,
                close     => 6,
                exit      => 1,
                fork      => 2,
                getpid    => 20,
                wait4     => 7,
                mmap      => 197,
                nanosleep => 240,
                brk       => 45
            },
        };
    }
}

=encoding utf-8

=head1 NAME

Brocken::Katsuro::Platform::OpenBSD - OpenBSD Platform

=head1 DESCRIPTION

Concrete platform class for OpenBSD. Inherits from B<BSD>.

=head1 METHODS

=head2 is_openbsd

Returns true (1).

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
