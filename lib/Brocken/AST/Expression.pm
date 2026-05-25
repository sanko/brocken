use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::AST::Node;
#
class Brocken::AST::Expression : isa(Brocken::AST::Node) {
    field $type : reader : writer;
}
#
1;
