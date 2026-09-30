use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
class Brocken::Katsuro::Platform::Solaris v0.0.1 : isa(Brocken::Katsuro::Platform) {
    method is_solaris()  {1}
    method format()      {'elf'}
    method libc_name()   {'libc.so.1'}
    method interpreter() {'/lib/64/ld.so.1'}
    }
    #
    1;
