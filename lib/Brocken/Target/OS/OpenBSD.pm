use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::OS::OpenBSD : isa(Brocken::Target::OS) {
    ADJUST {
        die "OS name mismatch" unless $self->name eq 'openbsd';
    }

    method syscall_wait4 ($arch) {
        return 7;
    }

    method syscall_nanosleep ($arch) {
        return 240;
    }
}
1;
