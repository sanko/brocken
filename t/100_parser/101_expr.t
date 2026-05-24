use Test2::V0;
use lib 'lib';
use Brocken::Scanner;
use Brocken::Parser;
#
my $scanner = Brocken::Scanner->new();
my $parser  = Brocken::Parser->new( mode => 'modern' );
#
subtest Expressions => sub {
    my $source = 'my $x = 10 + 2 * 3;';
    my $tokens = $scanner->scan($source);
    my $ast    = $parser->parse($tokens);
    is scalar @$ast,         1,                             'Should have 1 statement';
    is $ast->[0]->to_string, '(ASSIGN $x= (10 + (2 * 3)))', 'Correct precedence';
};
#
done_testing;
