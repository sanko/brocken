use v5.40;
use Test2::V0;
use lib 'lib';
use Brocken::Lexer;

my $lexer  = Brocken::Lexer->new(source => 'my $x = "hellö 🌍";');
my @tokens;
while ( my $t = $lexer->next() ) { push @tokens, $t }
is scalar @tokens, 5, 'Should have 5 tokens';
is $tokens[3]->{value}, "hellö 🌍", 'Correct string value';

done_testing;
