use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;

my $source  = q{
    sub main {
        my $x = 10;
        if (1) {
            $x = $y + 5;
        }
        print($x);
    }
};
my $lexer  = Brocken::Lexer->new(source => $source);
my $parser = Brocken::Parser->new(lexer => $lexer);
my $ast    = $parser->parse();
is scalar( @{ $ast->stmts } ), 1, 'Should have 1 statement';
ok $ast->stmts->[0]->isa('Brocken::AST::SubDecl'), 'Subroutine parses';

done_testing;
