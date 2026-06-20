use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::BSD;

class Brocken::Katsuro::Platform::MidnightBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_midnightbsd() {1}
}
1;
