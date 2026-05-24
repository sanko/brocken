use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::AST::Expression;
#
class Brocken::AST::Expr::Variable : isa(Brocken::AST::Expression) {
    field $name : reader : param;
    method value() { return $name; }

    method to_string() {
        return $name;
    }
}

class Brocken::AST::Expr::Literal : isa(Brocken::AST::Expression) {
    field $value : reader : param;

    method to_string() {
        return $value;
    }
}

class Brocken::AST::Expr::BinaryOp : isa(Brocken::AST::Expression) {
    field $left     : reader : param;
    field $operator : reader : param;
    field $right    : reader : param;

    method to_string() {
        return sprintf( "(%s %s %s)", $left->to_string, $operator, $right->to_string );
    }
}

class Brocken::AST::Expr::BuiltinCall : isa(Brocken::AST::Expression) {
    field $name : reader : param;
    field $args : reader : param;

    method to_string() {
        return sprintf( "%s(%s)", $name, join( ', ', map { $_->to_string } @$args ) );
    }
}

class Brocken::AST::Expr::Attribute : isa(Brocken::AST::Expression) {
    field $name : reader : param;

    method to_string() {
        return $name;
    }
}
1;

class Brocken::AST::Expr::Heredoc : isa(Brocken::AST::Expression) {
    field $content : reader : param;

    method to_string() {
        return sprintf( "Heredoc<%d_lines>", scalar( split( "\n", $content ) ) );
    }
}
#
1;
