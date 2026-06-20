use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::BSD;

class Brocken::Katsuro::Platform::NetBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_netbsd() {1}
}
1;
