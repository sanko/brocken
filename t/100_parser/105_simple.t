use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;
subtest 'Simple Statements' => sub {
    my $source = 'return 10; die 42; next;';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    is scalar( @{ $ast->statements } ), 3, 'Should have 3 statements';
    ok $ast->statements->[0]->isa('Brocken::AST::Stmt::Return'), 'First stmt is Return';
    is $ast->statements->[0]->expr->value, 10, 'Return value is 10';
    ok $ast->statements->[1]->isa('Brocken::AST::Expr::Call'), 'Second stmt is Call (die)';
    is $ast->statements->[1]->name, 'die', 'Call name is die';
    ok $ast->statements->[2]->isa('Brocken::AST::Stmt::Next'), 'Third stmt is Next';
};
done_testing;
