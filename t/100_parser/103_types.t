use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;

subtest 'Built-in Calls' => sub {
    my $source = 'print(10, 20);';
    my $lexer  = Brocken::Lexer->new(source => $source);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    my $ast    = $parser->parse();
    my $stmt   = $ast->stmts->[0];
    ok $stmt->isa('Brocken::AST::Call'), 'Print is a Call';
    is $stmt->name, 'print', 'Call name is print';
    is scalar( @{ $stmt->args } ), 2, 'Two arguments';
};

subtest 'Type Annotations' => sub {
    my $source = 'my Int $x = 10;';
    my $lexer  = Brocken::Lexer->new(source => $source);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    my $ast    = $parser->parse();
    my $stmt   = $ast->stmts->[0];
    ok $stmt->isa('Brocken::AST::MyDecl'), 'Declaration parses';
    is $stmt->type, 'Int', 'Type annotation Int';
    is $stmt->name, 'x', 'Variable name x';
};

done_testing;
