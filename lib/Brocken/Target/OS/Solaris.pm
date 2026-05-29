use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::OS::Solaris : isa(Brocken::Target::OS) {
    ADJUST {
        die "OS name mismatch" unless $self->name eq 'solaris';
    }
    method syscall_fork   ($arch) { return 2; }
    method syscall_wait4  ($arch) { return 114; }
    method syscall_exit   ($arch) { return 1; }
    method syscall_write  ($arch) { return 4; }
    method syscall_getpid ($arch) { return 20; }
}
1;
