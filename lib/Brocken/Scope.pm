use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Scope {
    field %symbols : reader;
    field $parent : reader : param = undef;

    method define( $name, $type ) {
        $symbols{$name} = { type => $type };
    }

    method get($name) {
        return $symbols{$name}->{type} if exists $symbols{$name};
        return $parent->get($name)     if $parent;
        return undef;
    }

    method exists($name) {
        return 1                      if exists $symbols{$name};
        return $parent->exists($name) if $parent;
        return 0;
    }
}
1;
