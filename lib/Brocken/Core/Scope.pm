# lib/Brocken/Core/Scope.pm
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Core::Scope {
    field $parent : param : reader = undef;
    field $symbols : reader;

    # Defensively instantiate reference-types inside ADJUST to prevent compiler memory corruption
    ADJUST {
        $symbols = {};
    }

    # Register a new variable in the current scope
    method define ( $name, $reg ) {
        if ( exists $symbols->{$name} ) {
            die "Compilation Error: Variable '$name' is already defined in this scope\n";
        }
        $symbols->{$name} = $reg;
    }

    # Search for a variable, moving up the parent scopes if necessary
    method lookup ($name) {
        if ( exists $symbols->{$name} ) {
            return $symbols->{$name};
        }
        if ( defined $parent ) {
            return $parent->lookup($name);
        }
        return undef;    # Undefined means it might be a class field or global
    }
}
1;
