use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;

subtest 'Simple Statements' => sub {
    my $source = 'return 10; die 42; next;';
    my $lexer  = Brocken::Lexer->new(source => $source);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    my $ast    = $parser->parse();
    is scalar( @{ $ast->stmts } ), 3, 'Should have 3 statements';
    ok $ast->stmts->[0]->isa('Brocken::AST::Return'), 'First stmt is Return';
    is $ast->stmts->[0]->expr->value, 10, 'Return value is 10';
    ok $ast->stmts->[1]->isa('Brocken::AST::Call'), 'Second stmt is Call (die)';
    is $ast->stmts->[1]->name, 'die', 'Call name is die';
    ok $ast->stmts->[2]->isa('Brocken::AST::FlowStmt'), 'Third stmt is FlowStmt (next)';
    is $ast->stmts->[2]->type, 'next', 'Flow type is next';
};

done_testing;
