use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::BSD;

class Brocken::Katsuro::Platform::DragonflyBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_dragonflybsd()         {1}
    method libc_name()               {'libc.so.8'}
    method libpthread_name()         {'libthread_xu.so.2'}
    method interpreter()             {'/libexec/ld-elf.so.2'}
    method exit_name()               {'exit'}
    method needs_sched_setaffinity() {1}
}
1;
