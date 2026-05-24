use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::ABI {

    method cc ( $arch, $name ) {
        return { eq => 0, ne => 1, lt => 0xB, le => 0xD, gt => 0xC, ge => 0xA, z => 0, nz => 1 }->{$name} if $arch eq 'arm64';
        return { eq => 4, ne => 5, lt => 0xC, le => 0xE, gt => 0xF, ge => 0xD, z => 4, nz => 5 }->{$name};
    }
}
1;
