use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::AST::Node;

class Brocken::Token : isa(Brocken::AST::Node) {
    field $type  : reader : param;
    field $value : reader : param;
    field $sigil : reader : param = undef;

    method to_string() {
        return sprintf( "%s [%s]: '%s'", $self->SUPER::to_string(), $type, $value );
    }
}
1;
