use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;
my $source = q{
    sub main {
        my $x = 10;
        if (1) {
            $x = $y + 5;
        }
        print($x);
    }
};
my $lexer  = Brocken::Lexer->new( source => $source );
my $parser = Brocken::Parser->new( lexer => $lexer );
my $ast    = $parser->parse();
is scalar( @{ $ast->statements } ), 1, 'Should have 1 statement';
ok $ast->statements->[0]->isa('Brocken::AST::OOP::Method'), 'Subroutine parses';
done_testing;
