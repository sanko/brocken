use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform;

class Brocken::Katsuro::Platform::BSD : isa(Brocken::Katsuro::Platform) {
    method is_bsd() {1}
}

class Brocken::Katsuro::Platform::FreeBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_freebsd() {1}
}

class Brocken::Katsuro::Platform::OpenBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_openbsd() {1}
}

class Brocken::Katsuro::Platform::NetBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_netbsd() {1}
}

class Brocken::Katsuro::Platform::MidnightBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_midnightbsd() {1}
}

class Brocken::Katsuro::Platform::DragonflyBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_dragonflybsd() {1}
}
1;
