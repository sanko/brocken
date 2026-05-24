use v5.40;
use Test2::V0;
use lib 'lib';
use Brocken::Scanner;
#
my $scanner = Brocken::Scanner->new();
my $source  = 'my $x = "hellö 🌍";';
my $tokens  = $scanner->scan($source);
for my $t (@$tokens) { print $t->type . ' : ' . $t->value . "\n"; }
is scalar @$tokens,     5,           'Should have 5 tokens';
is $tokens->[3]->value, '"hellö 🌍"', 'Correct string value';
#
done_testing;
