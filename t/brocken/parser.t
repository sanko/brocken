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

# Empty source
my $ast = parse_ok('');
ok $ast->isa('Brocken::AST::Stmt::Program'), 'Empty source gives Program';
is scalar( @{ $ast->statements } ), 0, 'Empty source has 0 statements';

# Empty semicolons
$ast = parse_ok(';;');
is scalar( @{ $ast->statements } ), 0, 'Empty semicolons produce no statements';

# Integer literal
$ast = parse_ok('42;');
is scalar( @{ $ast->statements } ), 1,  'One stmt for int';
is $ast->statements->[0]->value,    42, 'IntLiteral value 42';

# Float literal
$ast = parse_ok('3.14;');
is $ast->statements->[0]->value, 3.14, 'FloatLiteral value 3.14';

# String literal
$ast = parse_ok('"hello";');
is $ast->statements->[0]->value, 'hello', 'StrLiteral value';

# my declaration
$ast = parse_ok('my $x = 10;');
my $s = $ast->statements->[0];
ok $s->isa('Brocken::AST::Stmt::VarDecl'), 'my decl is VarDecl';
is $s->name,         'x', 'my var name x';
is $s->value->value, 10,  'my var init 10';

# my without init
$ast = parse_ok('my $x;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Stmt::VarDecl'), 'my without init';
ok !defined( $s->value ),                  'No value';

# my with type
$ast = parse_ok('my Int $x = 5;');
$s   = $ast->statements->[0];
is $s->type,         'Int', 'Type annotation Int';
is $s->name,         'x',   'Name x';
is $s->value->value, 5,     'Value 5';

# Assignment
$ast = parse_ok('$x = 20;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Stmt::Assignment'), 'Assignment stmt';
is $s->name,         'x', 'Assignment name x';
is $s->value->value, 20,  'Assignment value 20';

# Binary operation
$ast = parse_ok('1 + 2;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::BinOp'), 'BinOp stmt';
is $s->op,           '+', 'Op is +';
is $s->left->value,  1,   'Left 1';
is $s->right->value, 2,   'Right 2';

# Precedence: 1 + 2 * 3
$ast = parse_ok('1 + 2 * 3;');
$s   = $ast->statements->[0];
is $s->op, '+', 'Top op is +';
ok $s->right->isa('Brocken::AST::Expr::BinOp'), 'Right is BinOp';
is $s->right->op, '*', 'Inner op is *';

# Parentheses
$ast = parse_ok('(1 + 2) * 3;');
$s   = $ast->statements->[0];
is $s->op, '*', 'Top op is *';
ok $s->left->isa('Brocken::AST::Expr::BinOp'), 'Left is BinOp (via parens)';

# Unary minus
$ast = parse_ok('-5;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::UnaryOp'), 'UnaryOp';
is $s->op,          '-', 'Unary -';
is $s->expr->value, 5,   'expr 5';

# Unary not
$ast = parse_ok('!$flag;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::UnaryOp'), 'UnaryOp for !';
is $s->op, '!', 'Op is !';

# Variable
$ast = parse_ok('$x;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::Var'), 'Var';
is $s->name, 'x', 'Var name x';

# Call with parens
$ast = parse_ok('print("hi");');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::Call'), 'Call';
is $s->name,                'print', 'Call name print';
is scalar( @{ $s->args } ), 1,       '1 arg';

# Bareword function call
$ast = parse_ok('die 42;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::Call'), 'Bare call is Call';
is $s->name,             'die', 'Bare call name die';
is $s->args->[0]->value, 42,    'Bare call arg 42';

# If statement
$ast = parse_ok('if (1) { $x = 10; }');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Stmt::If'), 'If stmt';
is $s->condition->value, 1, 'If condition 1';
ok $s->then_block->isa('Brocken::AST::Stmt::Block'), 'If then Block';
ok !defined( $s->else_block ),                       'If no else_block';

# If/else
$ast = parse_ok('if (1) { $x; } else { $y; }');
$s   = $ast->statements->[0];
ok defined( $s->else_block ), 'If with else_block';

# While
$ast = parse_ok('while (1) { $x; }');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Stmt::While'), 'While stmt';
is $s->condition->value, 1, 'While condition 1';

# Return
$ast = parse_ok('return;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Stmt::Return'), 'Return';
ok !defined( $s->expr ),                  'Return no val';
$ast = parse_ok('return 42;');
$s   = $ast->statements->[0];
is $s->expr->value, 42, 'Return val 42';

# Flow statements
$ast = parse_ok('last; next; redo;');
is scalar( @{ $ast->statements } ), 3, '3 flow stmts';
ok $ast->statements->[0]->isa('Brocken::AST::Stmt::Last'), 'Stmt::Last';
ok $ast->statements->[1]->isa('Brocken::AST::Stmt::Next'), 'Stmt::Next';
ok $ast->statements->[2]->isa('Brocken::AST::Stmt::Redo'), 'Stmt::Redo';

# Sub declaration
$ast = parse_ok('sub foo { my $x = 1; }');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::OOP::Method'), 'Method';
is $s->name,                  'foo', 'Sub name foo';
is scalar( @{ $s->params } ), 0,     'Sub no params';

# Sub with params
$ast = parse_ok('sub add ($a, $b) { $a + $b; }');
$s   = $ast->statements->[0];
is scalar( @{ $s->params } ), 2,   'Sub 2 params';
is $s->params->[0],           'a', 'Param a';

# Statement modifier: return if
$ast = parse_ok('return if $cond;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Stmt::If'),                                  'return if -> If';
ok $s->then_block->statements->[0]->isa('Brocken::AST::Stmt::Return'), 'If body has Return';

# Unless
$ast = parse_ok('unless ($x) { $y; }');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Stmt::If'),                 'Unless becomes If';
ok $s->condition->isa('Brocken::AST::Expr::UnaryOp'), 'Unless wraps cond in !';

# elsif chain
$ast = parse_ok('if (1) { $a; } elsif (2) { $b; } else { $c; }');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Stmt::If'),                              'If with elsif';
ok $s->else_block->statements->[0]->isa('Brocken::AST::Stmt::If'), 'Elsif is nested If';

# Compound assignment
$ast = parse_ok('$x += 5;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Stmt::Assignment'),   'Compound assignment';
ok $s->value->isa('Brocken::AST::Expr::BinOp'), 'Compound assignment value is BinOp';
is $s->value->op, '+', 'Compound assignment op +';

# Ternary
$ast = parse_ok('$x ? 1 : 2;');
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::Ternary'), 'Ternary';
is $s->then->value, 1, 'Ternary then branch';
is $s->else->value, 2, 'Ternary else branch';

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
$s   = $ast->statements->[0];
ok $s->isa('Brocken::AST::Expr::MethodCall'), '-> is MethodCall';
is $s->method, 'foo', 'Method name foo';

# Method call with args
$ast = parse_ok('$obj->foo(1, 2);');
$s   = $ast->statements->[0];
is scalar( @{ $s->args } ), 2, 'Method call 2 args';
done_testing;
