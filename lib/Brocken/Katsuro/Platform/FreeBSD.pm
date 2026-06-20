use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::BSD;

class Brocken::Katsuro::Platform::FreeBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_freebsd() {1}
}
1;
