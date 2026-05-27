use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::OS::NetBSD : isa(Brocken::Target::OS) {
    ADJUST {
        die "OS name mismatch" unless $self->name eq 'netbsd';
    }

    # no need to override syscall_num_reg; base class returns 'x8' for arm64,
    # which is correct for both old (SVC immediate) and new (x8) NetBSD kernels.
    # Removing this override ensures x8 is set for ALL syscalls (exit, write, fork, wait4).
    method syscall_wait4 ($arch) {
        return 449;
    }
}
1;
