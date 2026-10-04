use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
class Brocken::Katsuro::AST::Node v0.0.1 {
    field $file : param : reader = '';
    field $line : param : reader = 0;
    field $col  : param : reader = 0;
};
class Brocken::Katsuro::AST::Program v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $statements : param : reader = [];    # Array of Statement Nodes
};

# Statements
class Brocken::Katsuro::AST::Stmt::VarDecl v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $sigil : param : reader;              # '$', '@', '%'
    field $name  : param : reader;              # e.g. "cursor"
    field $type  : param : reader = 'Any';
    field $init  : param : reader = undef;      # Initial expression Node
};
class Brocken::Katsuro::AST::Stmt::ArrayDecl v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $name      : param : reader;            # "arr" (without sigil)
    field $elem_type : param : reader;            # "i64"
    field $size_expr : param : reader;            # AST expression for size
    field $init      : param : reader = undef;    # optional array literal
};
class Brocken::Katsuro::AST::Stmt::Assign v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $target : param : reader;               # AST::Node
    field $expr   : param : reader;               # AST::Node
    field $op     : param : reader = '=';         # '=', '//='
};
class Brocken::Katsuro::AST::Stmt::Block v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $statements : param : reader = [];
};
class Brocken::Katsuro::AST::Stmt::If v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $cond  : param : reader;
    field $then  : param : reader;                # AST::Stmt::Block
    field $elsif : param : reader = [];           # Array of [cond, Block]
    field $else  : param : reader = undef;        # AST::Stmt::Block
};
class Brocken::Katsuro::AST::Stmt::While v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $cond : param : reader;
    field $body : param : reader;                 # AST::Stmt::Block
};
class Brocken::Katsuro::AST::Stmt::Break v0.0.1    : isa(Brocken::Katsuro::AST::Node) {};
class Brocken::Katsuro::AST::Stmt::Continue v0.0.1 : isa(Brocken::Katsuro::AST::Node) {};
class Brocken::Katsuro::AST::Stmt::Return v0.0.1   : isa(Brocken::Katsuro::AST::Node) {
    field $expr : param : reader = undef;
};

# Expressions
class Brocken::Katsuro::AST::Expr::BinOp v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $op  : param : reader;                  # '+', '-', '==', etc.
    field $lhs : param : reader;                  # AST::Node
    field $rhs : param : reader;                  # AST::Node
};
class Brocken::Katsuro::AST::Expr::UnOp v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $op   : param : reader;                 # '-', '!', 'not'
    field $expr : param : reader;                 # AST::Node
};
class Brocken::Katsuro::AST::Expr::Const v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $value : param : reader;
    field $type  : param : reader;                # 'Int', 'Float', 'String', 'Bool'
};
class Brocken::Katsuro::AST::Expr::Var v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $sigil : param : reader;
    field $name  : param : reader;
};

# Subroutine / Class Declarations
class Brocken::Katsuro::AST::Stmt::SubDecl v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $name        : param : reader;            # subroutine name
    field $params      : param : reader = [];       # Array of {type, sigil, name}
    field $return_type : param : reader = undef;    # undef -> infer from body
    field $body        : param : reader;            # AST::Stmt::Block
};
class Brocken::Katsuro::AST::Stmt::ClassDecl v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $name    : param : reader;
    field $fields  : param : reader = [];           # Array of AST::Stmt::FieldDecl
    field $methods : param : reader = [];           # Array of AST::Stmt::MethodDecl
    field $adjust  : param : reader = undef;        # AST::Stmt::Adjust | undef
};
class Brocken::Katsuro::AST::Stmt::FieldDecl v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $type       : param : reader;
    field $name       : param : reader;             # without sigil
    field $attrs      : param : reader = [];        # ['reader', 'writer', 'param']
    field $default    : param : reader = undef;     # default value expression
    field $default_op : param : reader = undef;     # '=' or '//='
};
class Brocken::Katsuro::AST::Stmt::MethodDecl v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $name        : param : reader;
    field $params      : param : reader = [];       # Array of {type, sigil, name}; does NOT include $self
    field $return_type : param : reader = undef;    # undef -> infer from body
    field $body        : param : reader;            # AST::Stmt::Block
};
class Brocken::Katsuro::AST::Stmt::Adjust v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $body : param : reader;                   # AST::Stmt::Block
};

# Expression helpers
class Brocken::Katsuro::AST::Expr::Paren v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $expr : param : reader;
};
class Brocken::Katsuro::AST::Expr::Ident v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $name : param : reader;                   # bare identifier (function name)
};
class Brocken::Katsuro::AST::Expr::FieldAccess v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $obj   : param : reader;                  # expression evaluating to an object pointer
    field $field : param : reader;                  # field name (without sigil)
};
class Brocken::Katsuro::AST::Expr::ArrayIndex v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $array : param : reader;                  # expression (usually Var)
    field $index : param : reader;                  # index expression (usually Const)
};
class Brocken::Katsuro::AST::Expr::MethodCall v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $obj    : param : reader;                 # expression evaluating to an object pointer
    field $method : param : reader;                 # method name
    field $args   : param : reader = [];            # Array of AST::Node
};
class Brocken::Katsuro::AST::Expr::ClassConst v0.0.1 : isa(Brocken::Katsuro::AST::Node) {

    # resolves to the current class name as a string constant
};

# Emitted specifically for Brocken::* pseudo-namespace memory operations
class Brocken::Katsuro::AST::Expr::IntrinsicCall v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $name : param : reader;                   # e.g. "load_i64"
    field $args : param : reader = [];              # Array of AST::Node
};
class Brocken::Katsuro::AST::Expr::Ternary v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $cond : param : reader;
    field $then : param : reader;
    field $else : param : reader;
};
class Brocken::Katsuro::AST::Expr::Want v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $context : param : reader;                # type name, 'list', 'scalar', or 'void'
};
class Brocken::Katsuro::AST::Expr::Call v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $func_name : param : reader;
    field $args : param : reader = [];
};

# List expressions and list assignment
class Brocken::Katsuro::AST::Expr::List v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $elements : param : reader;               # Array of AST::Node
};
class Brocken::Katsuro::AST::Expr::Hash v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $pairs : param : reader;                  # Array of { key => AST::Node, value => AST::Node }
};
class Brocken::Katsuro::AST::Stmt::ListVarDecl v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $targets : param : reader;                # Array of { sigil, name, type } (type optional, inferred)
    field $expr    : param : reader;                # AST::Node (RHS expression)
};
class Brocken::Katsuro::AST::Stmt::TryCatch v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $try_body     : param : reader;            # AST::Stmt::Block
    field $catch_var    : param : reader = undef;    # string (variable name) or undef
    field $catch_body   : param : reader = undef;    # AST::Stmt::Block or undef
    field $finally_body : param : reader = undef;    # AST::Stmt::Block or undef
};
class Brocken::Katsuro::AST::Stmt::Throw v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $expr : param : reader;                    # AST::Node expression to throw
} 1;
