use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;
subtest Expressions => sub {
    my $source = 'my $x = 10 + 2 * 3;';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    is scalar( @{ $ast->statements } ), 1, 'Should have 1 statement';
    my $stmt = $ast->statements->[0];
    ok $stmt->isa('Brocken::AST::Stmt::VarDecl'),      'Statement is VarDecl';
    ok $stmt->value->isa('Brocken::AST::Expr::BinOp'), 'Expr is BinOp';
    is $stmt->value->op, '+', 'Top op is +';
    ok $stmt->value->right->isa('Brocken::AST::Expr::BinOp'), 'Right is BinOp';
    is $stmt->value->right->op, '*', 'Inner op is * (binds tighter)';
};
done_testing;
