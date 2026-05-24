use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Brocken::AST::Node {
    field $line   : reader : param = 0;
    field $column : reader : param = 0;
    field $file   : reader : param = 'unknown';

    method to_string() {
        return sprintf( "%s:%d:%d", $file, $line, $column );
    }
}
#
1;
