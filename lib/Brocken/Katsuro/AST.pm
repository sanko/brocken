use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
class Brocken::Katsuro::AST::Node v0.0.1 {
    field $file    : param : reader = '';
    field $line    : param : reader = 0;
    field $col     : param : reader = 0;
    field $package : param : reader = undef;    # namespace a `package NAME` declaration put this node in
    method set_package($name) { $package = $name; }
};
class Brocken::Katsuro::AST::Program v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $statements : param : reader = [];    # Array of Statement Nodes
};

# Statements
class Brocken::Katsuro::AST::Stmt::VarDecl v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $sigil : param : reader;              # '$', '@', '%'
    field $name  : param : reader;              # e.g. "cursor"
    field $type  : param : reader = 'Any';
    field $attrs : param : reader = [];         # [{name,arg}, ...] e.g. :weak
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
    field $op     : param : reader = '=';         # '=', '//=', '||='
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
    field $version : param : reader = undef;        # from `class NAME VERSION`
    field $attrs   : param : reader = [];           # Class attributes: [{name, arg}], e.g. :isa(Base)
    field $fields  : param : reader = [];           # Array of AST::Stmt::FieldDecl
    field $methods : param : reader = [];           # Array of AST::Stmt::MethodDecl
    field $adjusts : param : reader = [];           # Array of AST::Stmt::Adjust (run in declaration order)
    field $destroys : param : reader = [];          # Array of AST::Stmt::Adjust wrapping DESTROY blocks
};

# `package NAME;` prefixes the declarations that follow until the end of the enclosing scope; `package NAME { ... }`
# scopes the prefix to the block. The parser resolves the current package and stamps it onto every statement, so the
# lowerer reads `package` off the node rather than replaying the declarations.
class Brocken::Katsuro::AST::Stmt::PackageDecl v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $name    : param : reader;            # e.g. "Brocken::Runtime"
    field $body    : param : reader = undef;    # AST::Stmt::Block for the block form, undef for `name;`
    field $version : param : reader = undef;    # strict version literal (v1.2.3 or 1.2.3), or undef
};
class Brocken::Katsuro::AST::Stmt::FieldDecl v0.0.1 : isa(Brocken::Katsuro::AST::Node) {
    field $type       : param : reader;            # scalar type, or the array/hash element/value type
    field $name       : param : reader;            # without sigil
    field $attrs      : param : reader = [];       # [{ name => 'reader', arg => undef }, ...]
    field $default    : param : reader = undef;    # default value expression
    field $default_op : param : reader = undef;    # '=', '//=', or '||='

    # Array/hash fields. `kind` is 'scalar', 'array', or 'hash'. An array field written `[T; N] $name` is
    # `inline` (N elements of `elem_type` reserved in the object); one written `T @name` is a single pointer slot
    # to element data. A `%name` field is a pointer slot holding hash data. `size_expr` is only set for the inline
    # form.
    field $sigil     : param : reader = '$';
    field $kind      : param : reader = 'scalar';
    field $elem_type : param : reader = undef;
    field $size_expr : param : reader = undef;
    field $inline    : param : reader = 0;
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
