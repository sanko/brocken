use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;

sub parse {
    my $lexer  = Brocken::Lexer->new( source => shift );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    return $parser->parse();
}
subtest 'Arithmetic Precedence' => sub {
    my $ast = parse('1 + 2 * 3;');
    isa_ok( $ast, 'Brocken::AST::Stmt::Program' );
    my $stmts = $ast->statements;
    is( scalar @$stmts, 1, 'One statement' );
    my $node = $stmts->[0];
    isa_ok( $node, 'Brocken::AST::Expr::BinOp' );
    is( $node->op,          '+', 'Root is +' );
    is( $node->left->value, 1,   'Left is 1' );
    isa_ok( $node->right, 'Brocken::AST::Expr::BinOp' );
    is( $node->right->op,           '*', 'Right is *' );
    is( $node->right->left->value,  2,   '2' );
    is( $node->right->right->value, 3,   '3' );
};
subtest 'Parentheses' => sub {
    my $ast  = parse('(1 + 2) * 3;');
    my $node = $ast->statements->[0];
    is( $node->op,       '*', 'Root is * due to parens' );
    is( $node->left->op, '+', 'Left is +' );
};
subtest 'Variable Declaration and Assignment' => sub {
    my $ast   = parse('my Int $x = 10; $x = 20;');
    my $stmts = $ast->statements;
    is( scalar @$stmts, 2, 'Two statements' );
    isa_ok( $stmts->[0], 'Brocken::AST::Stmt::VarDecl' );
    is( $stmts->[0]->name, 'x',   'my $x stores name without sigil' );
    is( $stmts->[0]->type, 'Int', 'type Int' );
    isa_ok( $stmts->[1], 'Brocken::AST::Stmt::Assignment' );
    is( $stmts->[1]->name,         'x', 'assignment to $x stores name without sigil' );
    is( $stmts->[1]->value->value, 20,  'value 20' );
};
subtest 'Control Flow: If/Else' => sub {
    my $ast  = parse('if ($x) { say 1; } else { say 0; }');
    my $node = $ast->statements->[0];
    isa_ok( $node, 'Brocken::AST::Stmt::If' );
    ok( $node->condition, 'has condition' );
    isa_ok( $node->then_block, 'Brocken::AST::Stmt::Block' );
    isa_ok( $node->else_block, 'Brocken::AST::Stmt::Block' );
};
subtest 'Control Flow: While' => sub {
    my $ast  = parse('while (1) { say "loop"; }');
    my $node = $ast->statements->[0];
    isa_ok( $node, 'Brocken::AST::Stmt::While' );
    is( $node->condition->value, 1, 'while(1)' );
    isa_ok( $node->body, 'Brocken::AST::Stmt::Block' );
};
subtest 'Ternary Operator' => sub {
    my $ast  = parse('$x ? 1 : 0;');
    my $node = $ast->statements->[0];
    isa_ok( $node, 'Brocken::AST::Expr::Ternary' );
    is( $node->cond->name,  'x', 'cond $x (name without sigil)' );
    is( $node->then->value, 1,   'then 1' );
    is( $node->else->value, 0,   'else 0' );
};
subtest 'Method Call' => sub {
    my $ast  = parse('$obj->meth(1, 2);');
    my $node = $ast->statements->[0];

    # The parser actually produces an Expr::MethodCall now, but let's see.
    # The current parser returns an Expr::MethodCall if it matches '->'.
    # In the parser code:
    # if ($t eq '->') { ... return Brocken::AST::Expr::MethodCall->new(...) }
    isa_ok( $node, 'Brocken::AST::Expr::MethodCall' );
    is( $node->method,           'meth', 'method meth' );
    is( scalar @{ $node->args }, 2,      '2 args' );
};
done_testing;
