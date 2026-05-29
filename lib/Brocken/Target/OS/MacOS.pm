use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::OS::MacOS : isa(Brocken::Target::OS) {
    ADJUST {
        die "OS name mismatch" unless $self->name eq 'macos';
    }

    method syscall_num_reg ($arch) {
        return 'x16' if $arch eq 'arm64';
        return $self->SUPER::syscall_num_reg($arch);
    }

    method page_size ($arch) {
        return 0x4000 if $arch eq 'arm64';
        return $self->SUPER::page_size($arch);
    }

    method syscall_wait4 ($arch) {
        return 0x200000b;
    }
}
1;
