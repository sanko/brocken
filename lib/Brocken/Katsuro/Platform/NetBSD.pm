use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::BSD;

class Brocken::Katsuro::Platform::NetBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_netbsd()       {1}
    method libc_name()       {'libc.so.12'}
    method libpthread_name() {'libpthread.so.1'}
    method interpreter()     {'/usr/libexec/ld.elf_so'}

    # NetBSD uses its own syscall numbering lineage (derived from 4.4BSD with local changes).
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
#
1;
