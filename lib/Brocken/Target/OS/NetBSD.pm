use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::OS::NetBSD : isa(Brocken::Target::OS) {
    ADJUST {
        die "OS name mismatch" unless $self->name eq 'netbsd';
    }

    method syscall_num_reg ($arch) {
        return undef if $arch eq 'arm64';
        return $self->SUPER::syscall_num_reg($arch);
    }
}
1;
