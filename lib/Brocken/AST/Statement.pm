use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::AST::Node;
#
class Brocken::AST::Statement : isa(Brocken::AST::Node) { }
#
1;
