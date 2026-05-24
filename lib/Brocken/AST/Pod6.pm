use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::AST::Statement;
#
class Brocken::AST::Pod6::Block : isa(Brocken::AST::Statement) {
    field $type    : reader : param;
    field $content : reader : param;

    method to_string() {
        return sprintf( "=begin %s\n%s\n=end %s", $type, $content, $type );
    }
}

class Brocken::AST::Pod6::Para : isa(Brocken::AST::Statement) {
    field $content : reader : param;

    method to_string() {
        return sprintf( "P<%s>", $content );
    }
}
#
1;
