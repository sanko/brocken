use v5.40;
use feature 'class';
no warnings qw[portable experimental::class];
#
class Brocken::Target::OS::MidnightBSD v0.0.1 : isa(Brocken::Target::OS) {
    ADJUST {
        die "OS name mismatch" unless $self->name eq 'midnightbsd';
    }
};
#
1;
