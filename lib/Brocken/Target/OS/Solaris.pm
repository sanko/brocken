use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::OS::Solaris : isa(Brocken::Target::OS) {
    ADJUST {
        die "OS name mismatch" unless $self->name eq 'solaris';
    }

    method syscall_fork ($arch) {
        return 2;    # fork
    }

    method syscall_wait4 ($arch) {
        return 257;    # waitid
    }
}
1;
