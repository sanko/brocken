use Test2::V0;
use lib 'lib';
use Brocken::Scanner;
use Brocken::Parser;
#
my $scanner = Brocken::Scanner->new();
my $parser  = Brocken::Parser->new( mode => 'modern' );
subtest 'Simple Statements' => sub {
    my $source = 'return 10; die 42; next;';
    my $tokens = $scanner->scan($source);
    my $ast    = $parser->parse($tokens);
    is scalar @$ast,         3,            'Should have 3 statements';
    is $ast->[0]->to_string, 'return(10)', 'Return parses';
    is $ast->[1]->to_string, 'die(42)',    'Die parses';
    is $ast->[2]->to_string, 'next()',     'Next parses';
};
#
done_testing;
