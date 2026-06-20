use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::BSD;

class Brocken::Katsuro::Platform::DragonflyBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_dragonflybsd() {1}
}
1;
