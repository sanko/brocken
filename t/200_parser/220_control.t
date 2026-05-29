use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;
subtest 'Control Flow' => sub {
    my $source = 'if (1) { my $x = 10; }';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    my $stmt   = $ast->statements->[0];
    ok $stmt->isa('Brocken::AST::Stmt::If'),                    'If statement parses correctly';
    ok $stmt->condition->isa('Brocken::AST::Expr::IntLiteral'), 'Condition is IntLiteral';
    is $stmt->condition->value, 1, 'Condition value is 1';
    ok $stmt->then_block->isa('Brocken::AST::Stmt::Block'), 'Then is Block';
};
subtest 'Unless' => sub {
    my $source = 'unless (1) { my $x = 10; }';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    my $stmt   = $ast->statements->[0];
    ok $stmt->isa('Brocken::AST::Stmt::If'),                 'Unless becomes If';
    ok $stmt->condition->isa('Brocken::AST::Expr::UnaryOp'), 'Condition is negated';
    is $stmt->condition->op, '!', 'Negation op is !';
};
subtest Subroutines => sub {
    my $source = 'sub foo { my $x = 10; }';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    my $stmt   = $ast->statements->[0];
    ok $stmt->isa('Brocken::AST::OOP::Method'), 'Subroutine parses correctly';
    is $stmt->name, 'foo', 'Sub name is foo';
};
subtest 'Assignment Without Declaration' => sub {
    my $source = '$x = 10;';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    is scalar( @{ $ast->statements } ), 1, 'Should have 1 statement';
    ok $ast->statements->[0]->isa('Brocken::AST::Stmt::Assignment'), 'Assignment without my is Assignment';
};
done_testing;
