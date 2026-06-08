use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Core::Token {
    field $type  : param : reader;    # e.g., 'KEYWORD', 'IDENT', 'OP', 'ASSIGN_DEFAULT'
    field $value : param : reader;    # e.g., 'class', '$id', '//='
    field $line  : param : reader = 1;
    field $col   : param : reader = 1;

    method to_string() {
        return "[$type '$value' at $line:$col]";
    }
}
1;
