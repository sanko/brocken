# lib/Brocken/Core/AST.pm
use v5.38;
use feature 'class';
no warnings 'experimental::class';

# Base Node class enforcing positional context
class Brocken::Core::AST::Node {
    field $line : param : reader = undef;
    field $col  : param : reader = undef;
    method to_string() { die "Unimplemented to_string" }
}

# Literal values (e.g. 999, 42)
class Brocken::Core::AST::Literal : isa(Brocken::Core::AST::Node) {
    field $value : param : reader;
    field $type : param : reader = 'Int';
    method to_string() { return "$value" }
}

# Variable accesses (e.g. $age, $id)
class Brocken::Core::AST::Variable : isa(Brocken::Core::AST::Node) {
    field $name : param : reader;
    method to_string() { return $name }
}

# Binary operations (e.g. $x + 5)
class Brocken::Core::AST::BinaryOp : isa(Brocken::Core::AST::Node) {
    field $op    : param : reader;
    field $left  : param : reader;
    field $right : param : reader;

    method to_string() {
        return "(" . $left->to_string . " $op " . $right->to_string . ")";
    }
}

# Assignments (e.g. $y = 10)
class Brocken::Core::AST::Assign : isa(Brocken::Core::AST::Node) {
    field $op    : param : reader;
    field $left  : param : reader;
    field $right : param : reader;

    method to_string() {
        return $left->to_string . " $op " . $right->to_string;
    }
}

# Lexical declarations (e.g. my $x //= 999)
class Brocken::Core::AST::MyDecl : isa(Brocken::Core::AST::Node) {
    field $name       : param : reader;
    field $value      : param : reader = undef;
    field $type       : param : reader = undef;    # Set to Brocken::Core::Type object
    field $default_op : param : reader = '=';      # '=', '//=', or '||='

    method to_string() {
        my $type_str = ( defined $type && $type->to_string ne 'Any' ) ? $type->to_string . " "                      : "";
        my $val_str  = defined $value                                 ? " " . $default_op . " " . $value->to_string : "";
        return "my $type_str$name$val_str";
    }
}

# Conditional control blocks (if / elsif / else)
class Brocken::Core::AST::If : isa(Brocken::Core::AST::Node) {
    field $condition   : param : reader;
    field $then_branch : param : reader;
    field $else_branch : param : reader = undef;

    method to_string() {
        my $else_str = "";
        if ( defined $else_branch ) {
            if ( ref($else_branch) eq 'ARRAY' ) {
                $else_str = " else { ... }";
            }
            else {
                $else_str = " else " . $else_branch->to_string;
            }
        }
        return "if (" . $condition->to_string . ") { ... }$else_str";
    }
}

class Brocken::Core::AST::While : isa(Brocken::Core::AST::Node) {
    field $condition : param : reader;    # Expression AST node
    field $body      : param : reader;    # Arrayref of statements

    method to_string() {
        return "while (" . $condition->to_string . ") { ... }";
    }
}

class Brocken::Core::AST::Parameter : isa(Brocken::Core::AST::Node) {
    field $name         : param : reader;            # e.g., '$count'
    field $type         : param : reader = undef;    # Brocken::Core::Type object
    field $default_op   : param : reader = undef;    # '=', '//=', '||='
    field $default_expr : param : reader = undef;    # AST fallback expression

    method to_string() {
        my $type_str = ( defined $type && $type->to_string ne 'Any' ) ? $type->to_string . " "                     : "";
        my $def_str  = defined $default_op                            ? " $default_op " . $default_expr->to_string : "";
        return "$type_str$name$def_str";
    }
}

class Brocken::Core::AST::Signature : isa(Brocken::Core::AST::Node) {
    field $params : param : reader = [];             # Arrayref of Parameter nodes

    method to_string() {
        return "(" . join( ", ", map { $_->to_string } @$params ) . ")";
    }
}

class Brocken::Core::AST::Method : isa(Brocken::Core::AST::Node) {
    field $name      : param : reader;               # Method name string
    field $signature : param : reader;               # Signature node
    field $body      : param : reader = [];          # Arrayref of statements inside block

    method to_string() {
        return "method $name " . $signature->to_string . " { ... }";
    }
}

class Brocken::Core::AST::Return : isa(Brocken::Core::AST::Node) {
    field $value : param : reader = undef;           # Optional return expression AST node

    method to_string() {
        return defined $value ? "return " . $value->to_string : "return";
    }
}

class Brocken::Core::AST::SubDecl : isa(Brocken::Core::AST::Node) {
    field $name      : param : reader;
    field $signature : param : reader;
    field $body      : param : reader = [];

    method to_string() {
        return "sub $name " . $signature->to_string . " { ... }";
    }
}

class Brocken::Core::AST::FFIDecl : isa(Brocken::Core::AST::Node) {
    field $name      : param : reader;        # C function name (e.g. 'ExitProcess')
    field $signature : param : reader;        # Signature object
    field $lib_name  : param : reader;        # C library (e.g. 'kernel32' or 'libc')
    field $is_method : param : reader = 0;    # 1 if declared as an FFI method

    method to_string() {
        my $kind = $is_method ? 'method' : 'sub';
        return "ffi $kind $name " . $signature->to_string . " :lib($lib_name);";
    }
}

class Brocken::Core::AST::FiberBlock : isa(Brocken::Core::AST::Node) {
    field $body : param : reader = [];        # Arrayref of statements inside the fiber block

    method to_string() {
        return "fiber { ... }";
    }
}

class Brocken::Core::AST::YieldStmt : isa(Brocken::Core::AST::Node) {
    field $value : param : reader = undef;    # Optional yield expression AST node

    method to_string() {
        return defined $value ? "yield " . $value->to_string : "yield";
    }
}

class Brocken::Core::AST::TransferStmt : isa(Brocken::Core::AST::Node) {
    field $target : param : reader;           # Destination Fiber expression AST node
    field $value : param : reader = undef;    # Optional argument value to transfer

    method to_string() {
        my $val_str = defined $value ? ", " . $value->to_string : "";
        return "transfer " . $target->to_string . $val_str;
    }
}

class Brocken::Core::AST::IsolateBlock : isa(Brocken::Core::AST::Node) {
    field $body : param : reader = [];        # Arrayref of statements executing inside the isolate thread

    method to_string() {
        return "isolate { ... }";
    }
}

class Brocken::Core::AST::SendStmt : isa(Brocken::Core::AST::Node) {
    field $target : param : reader;           # Destination Isolate expression AST node
    field $value  : param : reader;           # Value expression node to send

    method to_string() {
        return "send " . $target->to_string . ", " . $value->to_string;
    }
}

class Brocken::Core::AST::ReceiveExpr : isa(Brocken::Core::AST::Node) {

    method to_string() {
        return "receive";
    }
}

class Brocken::Core::AST::StringLiteral : isa(Brocken::Core::AST::Node) {
    field $value : param : reader;

    method to_string() {
        return "'$value'";
    }
}

class Brocken::Core::AST::SayStmt : isa(Brocken::Core::AST::Node) {
    field $value : param : reader;

    method to_string() {
        return "say " . $value->to_string;
    }
}

class Brocken::Core::AST::TypedefDecl : isa(Brocken::Core::AST::Node) {
    field $name : param : reader;    # Alias name (e.g. 'Person')
    field $type : param : reader;    # Underlying Brocken::Core::Type object

    method to_string() {
        return "typedef $name => " . $type->to_string . ";";
    }
}

class Brocken::Core::AST::SubCall : isa(Brocken::Core::AST::Node) {
    field $name : param : reader;
    field $args : param : reader = [];

    method to_string() {
        return $name . "(" . join( ", ", map { $_->to_string } @$args ) . ")";
    }
}

class Brocken::Core::AST::MethodCall : isa(Brocken::Core::AST::Node) {
    field $invocand    : param : reader;         # Invocand AST Node (Variable or Identifier)
    field $method_name : param : reader;         # Method name string (e.g. 'new')
    field $args        : param : reader = [];    # Arrayref of call arguments

    method to_string() {
        return $invocand->to_string . "->" . $method_name . "(" . join( ", ", map { $_->to_string } @$args ) . ")";
    }
}
1;
