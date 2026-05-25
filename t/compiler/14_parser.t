use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;

sub parse {
    my $lexer  = Brocken::Lexer->new(source => shift);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    return $parser->parse();
}

subtest 'Arithmetic Precedence' => sub {
    my $ast = parse('1 + 2 * 3;');
    isa_ok( $ast, 'Brocken::AST::Program' );
    my $stmts = $ast->stmts;
    is( scalar @$stmts, 1, 'One statement' );
    my $node = $stmts->[0];
    isa_ok( $node, 'Brocken::AST::BinOp' );
    is( $node->op,              '+', 'Root is +' );
    is( $node->left->value,     1,   'Left is 1' );
    isa_ok( $node->right, 'Brocken::AST::BinOp' );
    is( $node->right->op,               '*', 'Right is *' );
    is( $node->right->left->value,      2,   '2' );
    is( $node->right->right->value,     3,   '3' );
};

subtest 'Parentheses' => sub {
    my $ast  = parse('(1 + 2) * 3;');
    my $node = $ast->stmts->[0];
    is( $node->op,       '*', 'Root is * due to parens' );
    is( $node->left->op, '+', 'Left is +' );
};

subtest 'Variable Declaration and Assignment' => sub {
    my $ast = parse('my Int $x = 10; $x = 20;');
    my $stmts = $ast->stmts;
    is( scalar @$stmts, 2, 'Two statements' );
    isa_ok( $stmts->[0], 'Brocken::AST::MyDecl' );
    is( $stmts->[0]->name, 'x',  'my $x stores name without sigil' );
    is( $stmts->[0]->type, 'Int', 'type Int' );
    isa_ok( $stmts->[1], 'Brocken::AST::Assign' );
    is( $stmts->[1]->name,          'x', 'assignment to $x stores name without sigil' );
    is( $stmts->[1]->expr->value,   20,   'value 20' );
};

subtest 'Control Flow: If/Else' => sub {
    my $ast  = parse('if ($x) { say 1; } else { say 0; }');
    my $node = $ast->stmts->[0];
    isa_ok( $node, 'Brocken::AST::If' );
    ok( $node->cond, 'has condition' );
    isa_ok( $node->then, 'Brocken::AST::Block' );
    isa_ok( $node->else, 'Brocken::AST::Block' );
};

subtest 'Control Flow: While' => sub {
    my $ast  = parse('while (1) { say "loop"; }');
    my $node = $ast->stmts->[0];
    isa_ok( $node, 'Brocken::AST::While' );
    is( $node->cond->value, 1, 'while(1)' );
    isa_ok( $node->body, 'Brocken::AST::Block' );
};

subtest 'Ternary Operator' => sub {
    my $ast  = parse('$x ? 1 : 0;');
    my $node = $ast->stmts->[0];
    isa_ok( $node, 'Brocken::AST::Ternary' );
    is( $node->cond->name,    'x', 'cond $x (name without sigil)' );
    is( $node->if_true->value, 1,   'then 1' );
    is( $node->if_false->value, 0,  'else 0' );
};

subtest 'Method Call' => sub {
    my $ast  = parse('$obj->meth(1, 2);');
    my $node = $ast->stmts->[0];
    isa_ok( $node, 'Brocken::AST::BinOp' );
    is( $node->op, '->', 'arrow operator' );
    is( $node->left->name, 'obj', 'invocant $obj (name without sigil)' );
    isa_ok( $node->right, 'Brocken::AST::Call' );
    is( $node->right->name, 'meth', 'method meth' );
    is( scalar @{ $node->right->args }, 2, '2 args' );
};

done_testing;
