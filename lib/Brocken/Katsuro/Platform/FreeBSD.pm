use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::BSD;

class Brocken::Katsuro::Platform::FreeBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_freebsd()              {1}
    method libc_name()               {'libc.so.7'}
    method libpthread_name()         {'libthr.so.3'}
    method interpreter()             {'/libexec/ld-elf.so.1'}
    method needs_sched_setaffinity() {1}
}

1;
