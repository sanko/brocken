use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Scope {
    field %symbols;

    method define( $name, $type ) {
        $symbols{$name} = { type => $type };
    }

    method exists($name) {
        return exists $symbols{$name};
    }
}
1;
