use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;

subtest 'Control Flow' => sub {
    my $source = 'if (1) { my $x = 10; }';
    my $lexer  = Brocken::Lexer->new(source => $source);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    my $ast    = $parser->parse();
    my $stmt   = $ast->stmts->[0];
    ok $stmt->isa('Brocken::AST::If'), 'If statement parses correctly';
    ok $stmt->cond->isa('Brocken::AST::IntLiteral'), 'Condition is IntLiteral';
    is $stmt->cond->value, 1, 'Condition value is 1';
    ok $stmt->then->isa('Brocken::AST::Block'), 'Then is Block';
};

subtest 'Unless' => sub {
    my $source = 'unless (1) { my $x = 10; }';
    my $lexer  = Brocken::Lexer->new(source => $source);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    my $ast    = $parser->parse();
    my $stmt   = $ast->stmts->[0];
    ok $stmt->isa('Brocken::AST::If'), 'Unless becomes If';
    ok $stmt->cond->isa('Brocken::AST::UnaryOp'), 'Condition is negated';
    is $stmt->cond->op, '!', 'Negation op is !';
};

subtest Subroutines => sub {
    my $source = 'sub foo { my $x = 10; }';
    my $lexer  = Brocken::Lexer->new(source => $source);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    my $ast    = $parser->parse();
    my $stmt   = $ast->stmts->[0];
    ok $stmt->isa('Brocken::AST::SubDecl'), 'Subroutine parses correctly';
    is $stmt->name, 'foo', 'Sub name is foo';
};

subtest 'Assignment Without Declaration' => sub {
    my $source = '$x = 10;';
    my $lexer  = Brocken::Lexer->new(source => $source);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    my $ast    = $parser->parse();
    is scalar( @{ $ast->stmts } ), 1, 'Should have 1 statement';
    ok $ast->stmts->[0]->isa('Brocken::AST::Assign'), 'Assignment without my is Assign';
};

done_testing;
