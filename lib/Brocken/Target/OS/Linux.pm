use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::OS::Linux : isa(Brocken::Target::OS) {
    ADJUST {
        die "OS name mismatch" unless $self->name eq 'linux';
    }
}
1;
