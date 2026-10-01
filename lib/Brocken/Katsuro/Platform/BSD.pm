use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform;

class Brocken::Katsuro::Platform::BSD : isa(Brocken::Katsuro::Platform) {
    method is_bsd() {1}
}
1;
