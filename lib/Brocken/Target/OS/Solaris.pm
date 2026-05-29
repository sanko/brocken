use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::OS::Solaris : isa(Brocken::Target::OS) {
    ADJUST {
        die "OS name mismatch" unless $self->name eq 'solaris';
    }

    method syscall_fork ($arch) {
        return 142; # forksys
    }

    method syscall_wait4 ($arch) {
        return 257; # waitid
    }

    method syscall_nanosleep ($arch) {
        return 240;
    }
}
1;
