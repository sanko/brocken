use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform;

class Brocken::Katsuro::Platform::Solaris : isa(Brocken::Katsuro::Platform) {
    method is_solaris() {1}
    method format()     {'elf'}
}
1;
