use v5.42;
use feature qw[class];
no warnings qw[experimental::class];

class Brocken::Katsuro::AST::Node {
    field $line : param : reader = 0;
    field $col  : param : reader = 0;
}

class Brocken::Katsuro::AST::Program : isa(Brocken::Katsuro::AST::Node) {
    field $statements : param : reader = [];    # Array of Statement Nodes
}

# -------------------------------------------------------------------
# Statements
# -------------------------------------------------------------------
class Brocken::Katsuro::AST::Stmt::VarDecl : isa(Brocken::Katsuro::AST::Node) {
    field $sigil : param : reader;            # '$', '@', '%'
    field $name  : param : reader;            # e.g. "cursor"
    field $type  : param : reader = 'Any';
    field $init  : param : reader = undef;    # Initial expression Node
}

class Brocken::Katsuro::AST::Stmt::Assign : isa(Brocken::Katsuro::AST::Node) {
    field $target : param : reader;           # AST::Node::Expr::Var
    field $expr   : param : reader;           # AST::Node
}

class Brocken::Katsuro::AST::Stmt::Block : isa(Brocken::Katsuro::AST::Node) {
    field $statements : param : reader = [];
}

class Brocken::Katsuro::AST::Stmt::If : isa(Brocken::Katsuro::AST::Node) {
    field $cond  : param : reader;
    field $then  : param : reader;            # AST::Stmt::Block
    field $elsif : param : reader = [];       # Array of [cond, Block]
    field $else  : param : reader = undef;    # AST::Stmt::Block
}

class Brocken::Katsuro::AST::Stmt::While : isa(Brocken::Katsuro::AST::Node) {
    field $cond : param : reader;
    field $body : param : reader;             # AST::Stmt::Block
}

class Brocken::Katsuro::AST::Stmt::Return : isa(Brocken::Katsuro::AST::Node) {
    field $expr : param : reader = undef;
}

# -------------------------------------------------------------------
# Expressions
# -------------------------------------------------------------------
class Brocken::Katsuro::AST::Expr::BinOp : isa(Brocken::Katsuro::AST::Node) {
    field $op  : param : reader;    # '+', '-', '==', etc.
    field $lhs : param : reader;    # AST::Node
    field $rhs : param : reader;    # AST::Node
}

class Brocken::Katsuro::AST::Expr::UnOp : isa(Brocken::Katsuro::AST::Node) {
    field $op   : param : reader;    # '-', '!', 'not'
    field $expr : param : reader;    # AST::Node
}

class Brocken::Katsuro::AST::Expr::Const : isa(Brocken::Katsuro::AST::Node) {
    field $value : param : reader;
    field $type  : param : reader;    # 'Int', 'String', 'Bool'
}

class Brocken::Katsuro::AST::Expr::Var : isa(Brocken::Katsuro::AST::Node) {
    field $sigil : param : reader;
    field $name  : param : reader;
}

# Emitted specifically for Brocken::* pseudo-namespace memory operations
class Brocken::Katsuro::AST::Expr::IntrinsicCall : isa(Brocken::Katsuro::AST::Node) {
    field $name : param : reader;         # e.g. "load_i64"
    field $args : param : reader = [];    # Array of AST::Node
}

class Brocken::Katsuro::AST::Expr::Call : isa(Brocken::Katsuro::AST::Node) {
    field $func_name : param : reader;
    field $args : param : reader = [];
}
1;
