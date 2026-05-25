use v5.40;
use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;

sub parse_ok ($source) {
    my $lexer  = Brocken::Lexer->new(source => $source);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    return $parser->parse();
}

# --3 is unary
my $ast = parse_ok('-3;');
my $s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::UnaryOp'), '-3 is UnaryOp';
is $s->op, '-', 'op is -';

# --3 is prefix decrement
$ast = parse_ok('--3;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::UnaryOp'), '--3 is UnaryOp';
is $s->op, '--', 'op is --';

# $x - 3 is binary minus
$ast = parse_ok('$x - 3;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::BinOp'), '$x - 3 is BinOp';
is $s->op, '-', 'op is -';

# not/and/or precedence: not $x and $y → (not $x) and $y
$ast = parse_ok('not $x and $y;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::BinOp'), 'not $x and $y is BinOp';
is $s->op, 'and', 'top is and';
ok $s->left->isa('Brocken::AST::UnaryOp'), 'left is UnaryOp';
is $s->left->op, 'not', 'left op not';

# Comparison chain: 1 < 2 < 3 (right-assoc)
$ast = parse_ok('1 < 2 < 3;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::BinOp'), 'chained < is BinOp';
is $s->op, '<', 'top op <';
is $s->left->value, 1, 'left 1';
ok $s->right->isa('Brocken::AST::BinOp'), 'right is BinOp';
is $s->right->op, '<', 'inner op <';

# Bitwise: ~$x & $y | $z ^ 1
$ast = parse_ok('~$x & $y | $z ^ 1;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::BinOp'), 'bitwise chain top is BinOp';
is $s->op, '|', 'bitwise top is |';
ok $s->left->isa('Brocken::AST::BinOp'), '| left is BinOp';
is $s->left->op, '&', '| left op &';
ok $s->left->left->isa('Brocken::AST::UnaryOp'), '& left is UnaryOp ~';
ok $s->right->isa('Brocken::AST::BinOp'), '| right is BinOp';
is $s->right->op, '^', '| right op ^';

# Mixed arithmetic with ** right-assoc
$ast = parse_ok('2 ** 3 ** 2;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::BinOp'), '** chain is BinOp';
is $s->op, '**', 'top is **';
is $s->left->value, 2, 'left 2';
ok $s->right->isa('Brocken::AST::BinOp'), 'right is BinOp (** right-assoc)';
is $s->right->op, '**', 'inner op **';
is $s->right->left->value, 3, 'inner left 3';
is $s->right->right->value, 2, 'inner right 2';

# if with block uses bare {} correctly
$ast = parse_ok('if (1) { $x; }');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::If'), 'if with block';

# Nested if/else
$ast = parse_ok('if (1) { if (2) { $x; } else { $y; } }');
$s = $ast->stmts->[0];
ok $s->then->stmts->[0]->isa('Brocken::AST::If'), 'nested if';

# Statement modifier with complex expression
$ast = parse_ok('return $x + 1 if $cond;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::If'), 'return if is If';
is $s->then->stmts->[0]->expr->op, '+', 'return uses BinOp';

# Negative index
$ast = parse_ok('$x[-1];');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::Index'), 'negative index is Index';
ok $s->index->isa('Brocken::AST::UnaryOp'), 'index is UnaryOp';
is $s->index->op, '-', 'index op -';

# Ternary associativity (right-assoc)
$ast = parse_ok('$a ? $b ? 1 : 2 : 3;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::Ternary'), 'nested ternary top is Ternary';
ok $s->if_true->isa('Brocken::AST::Ternary'), 'if_true is Ternary';
is $s->if_true->if_true->value, 1, 'inner if_true 1';
is $s->if_true->if_false->value, 2, 'inner if_false 2';
is $s->if_false->value, 3, 'outer if_false 3';

# Sub with body
$ast = parse_ok('sub fib ($n) { if ($n < 2) { return $n; } return $n - 1 + $n - 2; }');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::SubDecl'), 'fib sub';
is scalar(@{ $s->params }), 1, '1 param';
is scalar(@{ $s->body->stmts }), 2, '2 body stmts';

# elsif chaining
$ast = parse_ok('if (1) { $x; } elsif (2) { $y; } elsif (3) { $z; } else { $w; }');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::If'), 'chained elsif top If';
ok $s->else->stmts->[0]->isa('Brocken::AST::If'), '1st elsif';
ok $s->else->stmts->[0]->else->stmts->[0]->isa('Brocken::AST::If'), '2nd elsif';
ok $s->else->stmts->[0]->else->stmts->[0]->else->isa('Brocken::AST::Block'), 'final else';

# Method call after if expression
$ast = parse_ok('$obj->method;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::BinOp'), 'method call is BinOp';
is $s->op, '->', 'op is ->';

done_testing;
