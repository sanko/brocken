use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
#
class Brocken::Target::Format {
    method write_bin( $filename, $text, $data, $arch, $os )           {...}
    method write_lib( $filename, $text, $data, $arch, $os, $exports ) {...}
};
1;
