use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;

subtest 'Assignment Without Declaration' => sub {
    my $source = '$x = 10;'; # No 'my'
    my $lexer  = Brocken::Lexer->new(source => $source);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    my $ast    = $parser->parse();
    
    ok $ast->isa('Brocken::AST::Program'), 'AST is a Program';
    is scalar( @{ $ast->stmts } ), 1, 'Should have 1 statement';
    ok $ast->stmts->[0]->isa('Brocken::AST::Assign'), 'Statement is an Assign';
    is $ast->stmts->[0]->name, 'x', 'Assign to x';
};

done_testing;
