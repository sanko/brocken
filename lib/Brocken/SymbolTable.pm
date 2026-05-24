use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Scope;

class Brocken::SymbolTable {
    field @scopes : reader;
    ADJUST {
        # Initialize with a global scope
        push @scopes, Brocken::Scope->new();
    }

    method push_scope() {
        push @scopes, Brocken::Scope->new();
    }

    method pop_scope() {
        pop @scopes if @scopes > 1;
    }

    method define( $name, $type ) {
        $scopes[-1]->define( $name, $type );
    }

    method lookup($name) {
        for ( my $i = $#scopes; $i >= 0; $i-- ) {
            return 1 if $scopes[$i]->exists($name);
        }
        return 0;
    }
}
1;
