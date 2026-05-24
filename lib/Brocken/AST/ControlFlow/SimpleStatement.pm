use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::AST::Statement;
#
class Brocken::AST::ControlFlow::SimpleStatement : isa(Brocken::AST::Statement) {
    field $keyword : reader : param;
    field $args : reader : param = [];

    method to_string() {
        return sprintf( "%s(%s)", $keyword, join( ', ', map { $_->to_string } @$args ) );
    }
}
#
1;
