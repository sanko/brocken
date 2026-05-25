use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;

subtest 'Eval Parsing' => sub {
    my $source = 'eval("print 10");';
    my $lexer  = Brocken::Lexer->new(source => $source);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    my $ast    = $parser->parse();
    
    ok $ast->isa('Brocken::AST::Program'), 'AST is a Program';
    is scalar( @{ $ast->stmts } ), 1, 'Should have 1 statement';
    
    my $stmt = $ast->stmts->[0];
    ok $stmt->isa('Brocken::AST::Call'),     'Statement is a Call';
    is $stmt->name, 'eval',                  'Call name is eval';
    is $stmt->args->[0]->value, 'print 10',  'Argument value is "print 10"';
};

done_testing;
