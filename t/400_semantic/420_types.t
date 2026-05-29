use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;
subtest 'Type Annotation Parsing' => sub {
    my $source = 'my Int $x = 10; my $y = $x + 2.5;';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();

    # Verify the AST structure
    ok $ast->isa('Brocken::AST::Stmt::Program'), 'AST is a Program';
    is scalar( @{ $ast->statements } ), 2, 'Should have 2 statements';
    my $s1 = $ast->statements->[0];
    ok $s1->isa('Brocken::AST::Stmt::VarDecl'), 'First stmt is VarDecl';
    is $s1->name, 'x',   'First var is x';
    is $s1->type, 'Int', 'Type annotation is Int';
    my $s2 = $ast->statements->[1];
    ok $s2->isa('Brocken::AST::Stmt::VarDecl'), 'Second stmt is VarDecl';
    is $s2->name, 'y', 'Second var is y';
};
done_testing;
