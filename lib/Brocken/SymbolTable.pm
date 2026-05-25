use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Scope;

class Brocken::SymbolTable {
    field $current_scope : reader;

    ADJUST {
        $current_scope = Brocken::Scope->new();
    }

    method push_scope() {
        $current_scope = Brocken::Scope->new( parent => $current_scope );
    }

    method pop_scope() {
        $current_scope = $current_scope->parent if $current_scope->parent;
    }

    method define( $name, $type ) {
        $current_scope->define( $name, $type );
    }

    method lookup($name) {
        return $current_scope->get($name);
    }
}
1;
