use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;

my $source = q{
    if (1) {
        my $x = 1;
    } elsif (2) {
        my $x = 2;
    } else {
        my $x = 3;
    }
};

my $lexer  = Brocken::Lexer->new(source => $source);
my $parser = Brocken::Parser->new(lexer => $lexer);
my $ast    = $parser->parse();

is scalar( @{ $ast->stmts } ), 1, 'Should have 1 statement (the if chain)';
my $if = $ast->stmts->[0];
ok $if->isa('Brocken::AST::If'), 'Top-level is If';
ok $if->else->isa('Brocken::AST::Block'), 'Else is a Block';
ok $if->else->stmts->[0]->isa('Brocken::AST::If'), 'Else block contains inner If (elsif)';

done_testing;
