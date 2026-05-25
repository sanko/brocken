use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;

subtest Expressions => sub {
    my $source = 'my $x = 10 + 2 * 3;';
    my $lexer  = Brocken::Lexer->new(source => $source);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    my $ast    = $parser->parse();
    is scalar( @{ $ast->stmts } ), 1, 'Should have 1 statement';
    my $stmt = $ast->stmts->[0];
    ok $stmt->isa('Brocken::AST::MyDecl'), 'Statement is MyDecl';
    ok $stmt->expr->isa('Brocken::AST::BinOp'), 'Expr is BinOp';
    is $stmt->expr->op, '+', 'Top op is +';
    ok $stmt->expr->right->isa('Brocken::AST::BinOp'), 'Right is BinOp';
    is $stmt->expr->right->op, '*', 'Inner op is * (binds tighter)';
};

done_testing;
