use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::AST::Statement;
#
class Brocken::AST::ControlFlow::Assignment : isa(Brocken::AST::Statement) {
    field $variable   : reader : param;
    field $value      : reader : param;
    field $attributes : reader : param;

    method to_string() {
        my $attr_str = @$attributes ? join( ' ', map { $_->to_string } @$attributes ) . ' ' : '';
        return sprintf( "(ASSIGN %s%s= %s)", $attr_str, $variable->value, $value->to_string );
    }
}

class Brocken::AST::ControlFlow::Block : isa(Brocken::AST::Statement) {
    field $statements : reader : param;

    method to_string() {
        return sprintf( "{ %s }", join( '; ', map { $_->to_string } @$statements ) );
    }
}

class Brocken::AST::ControlFlow::IfStatement : isa(Brocken::AST::Statement) {
    field $condition  : reader : param;
    field $then_block : reader : param;

    method to_string() {
        return sprintf( "if (%s) %s", $condition->to_string, $then_block->to_string );
    }
}

class Brocken::AST::ControlFlow::WhileStatement : isa(Brocken::AST::Statement) {
    field $condition  : reader : param;
    field $body_block : reader : param;

    method to_string() {
        return sprintf( "while (%s) %s", $condition->to_string, $body_block->to_string );
    }
}

class Brocken::AST::ControlFlow::Subroutine : isa(Brocken::AST::Statement) {
    field $name       : reader : param;
    field $body       : reader : param;
    field $attributes : reader : param;

    method to_string() {
        my $attr_str = join( ' ', map { $_->to_string } @$attributes );
        return sprintf( "sub %s %s %s", $name, $attr_str, $body->to_string );
    }
}
#
1;
