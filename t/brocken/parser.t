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

# Empty source
my $ast = parse_ok('');
ok $ast->isa('Brocken::AST::Program'), 'Empty source gives Program';
is scalar(@{ $ast->stmts }), 0, 'Empty source has 0 stmts';

# Empty semicolons
$ast = parse_ok(';;');
is scalar(@{ $ast->stmts }), 0, 'Empty semicolons produce no stmts';

# Integer literal
$ast = parse_ok('42;');
is scalar(@{ $ast->stmts }), 1, 'One stmt for int';
is $ast->stmts->[0]->value, 42, 'IntLiteral value 42';

# Float literal
$ast = parse_ok('3.14;');
is $ast->stmts->[0]->value, 3.14, 'FloatLiteral value 3.14';

# String literal
$ast = parse_ok('"hello";');
is $ast->stmts->[0]->value, 'hello', 'StrLiteral value';

# my declaration
$ast = parse_ok('my $x = 10;');
my $s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::MyDecl'), 'my decl is MyDecl';
is $s->name, 'x', 'my var name x';
is $s->expr->value, 10, 'my var init 10';

# my without init
$ast = parse_ok('my $x;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::MyDecl'), 'my without init';
ok !defined($s->expr), 'No expr';

# my with type
$ast = parse_ok('my Int $x = 5;');
$s = $ast->stmts->[0];
is $s->type, 'Int', 'Type annotation Int';
is $s->name, 'x', 'Name x';
is $s->expr->value, 5, 'Value 5';

# Assignment
$ast = parse_ok('$x = 20;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::Assign'), 'Assign stmt';
is $s->name, 'x', 'Assign name x';
is $s->expr->value, 20, 'Assign value 20';

# Binary operation
$ast = parse_ok('1 + 2;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::BinOp'), 'BinOp stmt';
is $s->op, '+', 'Op is +';
is $s->left->value, 1, 'Left 1';
is $s->right->value, 2, 'Right 2';

# Precedence: 1 + 2 * 3
$ast = parse_ok('1 + 2 * 3;');
$s = $ast->stmts->[0];
is $s->op, '+', 'Top op is +';
ok $s->right->isa('Brocken::AST::BinOp'), 'Right is BinOp';
is $s->right->op, '*', 'Inner op is *';

# Parentheses
$ast = parse_ok('(1 + 2) * 3;');
$s = $ast->stmts->[0];
is $s->op, '*', 'Top op is *';
ok $s->left->isa('Brocken::AST::BinOp'), 'Left is BinOp (via parens)';

# Unary minus
$ast = parse_ok('-5;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::UnaryOp'), 'UnaryOp';
is $s->op, '-', 'Unary -';
is $s->operand->value, 5, 'Operand 5';

# Unary not
$ast = parse_ok('!$flag;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::UnaryOp'), 'UnaryOp for !';
is $s->op, '!', 'Op is !';

# Variable
$ast = parse_ok('$x;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::Var'), 'Var';
is $s->name, 'x', 'Var name x';

# Call with parens
$ast = parse_ok('print("hi");');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::Call'), 'Call';
is $s->name, 'print', 'Call name print';
is scalar(@{ $s->args }), 1, '1 arg';

# Bareword function call
$ast = parse_ok('die 42;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::Call'), 'Bare call is Call';
is $s->name, 'die', 'Bare call name die';
is $s->args->[0]->value, 42, 'Bare call arg 42';

# If statement
$ast = parse_ok('if (1) { $x = 10; }');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::If'), 'If stmt';
is $s->cond->value, 1, 'If cond 1';
ok $s->then->isa('Brocken::AST::Block'), 'If then Block';
ok !defined($s->else), 'If no else';

# If/else
$ast = parse_ok('if (1) { $x; } else { $y; }');
$s = $ast->stmts->[0];
ok defined($s->else), 'If with else';

# While
$ast = parse_ok('while (1) { $x; }');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::While'), 'While stmt';
is $s->cond->value, 1, 'While cond 1';

# Return
$ast = parse_ok('return;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::Return'), 'Return';
ok !defined($s->expr), 'Return no val';

$ast = parse_ok('return 42;');
$s = $ast->stmts->[0];
is $s->expr->value, 42, 'Return val 42';

# Flow statements
$ast = parse_ok('last; next; redo;');
is scalar(@{ $ast->stmts }), 3, '3 flow stmts';
is $ast->stmts->[0]->type, 'last', 'FlowStmt last';
is $ast->stmts->[1]->type, 'next', 'FlowStmt next';
is $ast->stmts->[2]->type, 'redo', 'FlowStmt redo';

# Sub declaration
$ast = parse_ok('sub foo { my $x = 1; }');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::SubDecl'), 'SubDecl';
is $s->name, 'foo', 'Sub name foo';
is scalar(@{ $s->params }), 0, 'Sub no params';

# Sub with params
$ast = parse_ok('sub add ($a, $b) { $a + $b; }');
$s = $ast->stmts->[0];
is scalar(@{ $s->params }), 2, 'Sub 2 params';
is $s->params->[0], 'a', 'Param a';

# Statement modifier: return if
$ast = parse_ok('return if $cond;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::If'), 'return if -> If';
ok $s->then->stmts->[0]->isa('Brocken::AST::Return'), 'If body has Return';

# Unless
$ast = parse_ok('unless ($x) { $y; }');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::If'), 'Unless becomes If';
ok $s->cond->isa('Brocken::AST::UnaryOp'), 'Unless wraps cond in !';

# elsif chain
$ast = parse_ok('if (1) { $a; } elsif (2) { $b; } else { $c; }');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::If'), 'If with elsif';
ok $s->else->stmts->[0]->isa('Brocken::AST::If'), 'Elsif is nested If';

# Compound assignment
$ast = parse_ok('$x += 5;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::Assign'), 'Compound assign';
ok $s->expr->isa('Brocken::AST::BinOp'), 'Compound assign value is BinOp';
is $s->expr->op, '+', 'Compound assign op +';

# Ternary
$ast = parse_ok('$x ? 1 : 2;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::Ternary'), 'Ternary';
is $s->if_true->value, 1, 'Ternary true branch';
is $s->if_false->value, 2, 'Ternary false branch';

# Error: unexpected token
my $err;
eval { parse_ok('}'); 1 } or $err = $@;
ok $err, 'Unexpected } dies';
like $err, qr/Unexpected/, 'Error mentions unexpected';

# Error: unterminated string in parser
$err = undef;
eval { parse_ok('"no end'); 1 } or $err = $@;
ok $err, 'Unterminated string dies';

# Method call via ->
$ast = parse_ok('$obj->foo;');
$s = $ast->stmts->[0];
ok $s->isa('Brocken::AST::BinOp'), '-> is BinOp';
is $s->op, '->', '-> op';
ok $s->right->isa('Brocken::AST::Call'), '-> right is Call';
is $s->right->name, 'foo', 'Method name foo';

# Method call with args
$ast = parse_ok('$obj->foo(1, 2);');
$s = $ast->stmts->[0];
is scalar(@{ $s->right->args }), 2, 'Method call 2 args';

done_testing;
