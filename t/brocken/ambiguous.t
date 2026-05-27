use v5.40;
use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;

sub parse_ok ($source) {
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    return $parser->parse();
}

# --3 is unary
my $ast = parse_ok('-3;');
my $s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::UnaryOp'), '-3 is UnaryOp';
is $s->op, '-', 'op is -';

# --3 is prefix decrement
$ast = parse_ok('--3;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::UnaryOp'), '--3 is UnaryOp';
is $s->op, '--', 'op is --';

# $x - 3 is binary minus
$ast = parse_ok('$x - 3;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::BinOp'), '$x - 3 is BinOp';
is $s->op, '-', 'op is -';

# not/and/or precedence: not $x and $y → (not $x) and $y
$ast = parse_ok('not $x and $y;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::BinOp'), 'not $x and $y is BinOp';
is $s->op, 'and', 'top is and';
ok $s->left->isa('Brocken::AST::Expr::UnaryOp'), 'left is UnaryOp';
is $s->left->op, 'not', 'left op not';

# Comparison chain: 1 < 2 < 3 (right-assoc)
$ast = parse_ok('1 < 2 < 3;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::BinOp'), 'chained < is BinOp';
is $s->op,          '<', 'top op <';
is $s->left->value, 1,   'left 1';
ok $s->right->isa('Brocken::AST::Expr::BinOp'), 'right is BinOp';
is $s->right->op, '<', 'inner op <';

# Bitwise: ~$x & $y | $z ^ 1
$ast = parse_ok('~$x & $y | $z ^ 1;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::BinOp'), 'bitwise chain top is BinOp';
is $s->op, '|', 'bitwise top is |';
ok $s->left->isa('Brocken::AST::Expr::BinOp'), '| left is BinOp';
is $s->left->op, '&', '| left op &';
ok $s->left->left->isa('Brocken::AST::Expr::UnaryOp'), '& left is UnaryOp ~';
ok $s->right->isa('Brocken::AST::Expr::BinOp'),        '| right is BinOp';
is $s->right->op, '^', '| right op ^';

# Mixed arithmetic with ** right-assoc
$ast = parse_ok('2 ** 3 ** 2;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::BinOp'), '** chain is BinOp';
is $s->op,          '**', 'top is **';
is $s->left->value, 2,    'left 2';
ok $s->right->isa('Brocken::AST::Expr::BinOp'), 'right is BinOp (** right-assoc)';
is $s->right->op,           '**', 'inner op **';
is $s->right->left->value,  3,    'inner left 3';
is $s->right->right->value, 2,    'inner right 2';

# if with block uses bare {} correctly
$ast = parse_ok('if (1) { $x; }');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Stmt::If'), 'if with block';

# Nested if/else
$ast = parse_ok('if (1) { if (2) { $x; } else { $y; } }');
$s   = $ast->statements->[0];
ok $s->then_block->statements->[0]->isa('Brocken::AST::Stmt::If'), 'nested if';

# Statement modifier with complex expression
$ast = parse_ok('return $x + 1 if $cond;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Stmt::If'), 'return if is If';
is $s->then_block->statements->[0]->expr->op, '+', 'return uses BinOp';

# Negative index
$ast = parse_ok('$x[-1];');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::IndexExpr'),      'negative index is Index';
ok $s->index->isa('Brocken::AST::Expr::UnaryOp'), 'index is UnaryOp';
is $s->index->op, '-', 'index op -';

# Ternary associativity (right-assoc)
$ast = parse_ok('$a ? $b ? 1 : 2 : 3;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::Ternary'),       'nested ternary top is Ternary';
ok $s->then->isa('Brocken::AST::Expr::Ternary'), 'then is Ternary';
is $s->then->then->value, 1, 'inner then 1';
is $s->then->else->value, 2, 'inner else 2';
is $s->else->value,       3, 'outer else 3';

# Sub with body
$ast = parse_ok('sub fib ($n) { if ($n < 2) { return $n; } return $n - 1 + $n - 2; }');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::OOP::Method'), 'fib sub';
is scalar( @{ $s->params } ),           1, '1 param';
is scalar( @{ $s->body->statements } ), 2, '2 body stmts';

# elsif chaining
$ast = parse_ok('if (1) { $x; } elsif (2) { $y; } elsif (3) { $z; } else { $w; }');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Stmt::If'),                                                                          'chained elsif top If';
ok $s->else_block->statements->[0]->isa('Brocken::AST::Stmt::If'),                                             '1st elsif';
ok $s->else_block->statements->[0]->else_block->statements->[0]->isa('Brocken::AST::Stmt::If'),                '2nd elsif';
ok $s->else_block->statements->[0]->else_block->statements->[0]->else_block->isa('Brocken::AST::Stmt::Block'), 'final else';

# Method call after if expression
# Method call
$ast = parse_ok('$obj->method;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::MethodCall'), 'method call is MethodCall';
is $s->method, 'method', 'method name is method';
done_testing;
