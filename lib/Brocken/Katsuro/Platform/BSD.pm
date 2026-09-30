use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
#
class Brocken::Katsuro::Platform::BSD v0.0.1 : isa(Brocken::Katsuro::Platform) {
    method is_bsd() {1}
};
#
1;
