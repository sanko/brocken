use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::AST::Node {
    field $line :reader :param = 0;
    field $col  :reader :param = 0;
}

# --- Statements ---

class Brocken::AST::Program :isa(Brocken::AST::Node) {
    field $stmts :reader :param;
}

class Brocken::AST::Block :isa(Brocken::AST::Node) {
    field $stmts :reader :param;
}

class Brocken::AST::MyDecl :isa(Brocken::AST::Node) {
    field $name :reader :param;
    field $type :reader :param = undef;
    field $expr :reader :param = undef;
}

class Brocken::AST::Assign :isa(Brocken::AST::Node) {
    field $name :reader :param;
    field $expr :reader :param;
}

class Brocken::AST::If :isa(Brocken::AST::Node) {
    field $cond :reader :param;
    field $then :reader :param;
    field $else :reader :param = undef;
}

class Brocken::AST::While :isa(Brocken::AST::Node) {
    field $cond :reader :param;
    field $body :reader :param;
}

class Brocken::AST::SubDecl :isa(Brocken::AST::Node) {
    field $name   :reader :param;
    field $params :reader :param = [];
    field $body   :reader :param;
}

class Brocken::AST::Return :isa(Brocken::AST::Node) {
    field $expr :reader :param = undef;
}

class Brocken::AST::FlowStmt :isa(Brocken::AST::Node) {
    field $type :reader :param;
}

class Brocken::AST::Call :isa(Brocken::AST::Node) {
    field $name :reader :param;
    field $args :reader :param = [];
}

class Brocken::AST::For :isa(Brocken::AST::Node) {
    field $init :reader :param = undef;
    field $cond :reader :param = undef;
    field $step :reader :param = undef;
    field $body :reader :param;
}

class Brocken::AST::Foreach :isa(Brocken::AST::Node) {
    field $var  :reader :param;
    field $expr :reader :param;
    field $body :reader :param;
}

# --- Expressions ---

class Brocken::AST::IntLiteral :isa(Brocken::AST::Node) {
    field $value :reader :param;
}

class Brocken::AST::FloatLiteral :isa(Brocken::AST::Node) {
    field $value :reader :param;
}

class Brocken::AST::StrLiteral :isa(Brocken::AST::Node) {
    field $value :reader :param;
}

class Brocken::AST::NilLiteral :isa(Brocken::AST::Node) {}

class Brocken::AST::Var :isa(Brocken::AST::Node) {
    field $name   :reader :param;
    field $sigil  :reader :param = '$';
}

class Brocken::AST::Ident :isa(Brocken::AST::Node) {
    field $name :reader :param;
}

class Brocken::AST::BinOp :isa(Brocken::AST::Node) {
    field $left  :reader :param;
    field $op    :reader :param;
    field $right :reader :param;
}

class Brocken::AST::UnaryOp :isa(Brocken::AST::Node) {
    field $op      :reader :param;
    field $operand :reader :param;
}

class Brocken::AST::Ternary :isa(Brocken::AST::Node) {
    field $cond     :reader :param;
    field $if_true  :reader :param;
    field $if_false :reader :param;
}

class Brocken::AST::Index :isa(Brocken::AST::Node) {
    field $target :reader :param;
    field $index  :reader :param;
}

require Brocken::AST::Async;

1;
