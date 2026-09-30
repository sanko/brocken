use v5.40;
use feature 'class';
no warnings qw[experimental::class];

# The abstract base of the object file format layer. Each subclass implements one object format.
class Brocken::Target::Format v0.0.1 {
    method write_bin( $filename, $text, $data, $arch, $os )           {...}
    method write_lib( $filename, $text, $data, $arch, $os, $exports ) {...}
};
1;
