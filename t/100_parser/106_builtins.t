use Test2::V0;
use lib 'lib';
use Brocken::Scanner;
use Brocken::Parser;
#
my $scanner = Brocken::Scanner->new();
my $parser  = Brocken::Parser->new( mode => 'modern' );
subtest 'Built-ins Expansion' => sub {
    my $source = 'say(abs(10), reverse(20, 30));';
    my $tokens = $scanner->scan($source);
    my $ast    = $parser->parse($tokens);
    is scalar @$ast,         1,                               'Should have 1 statement';
    is $ast->[0]->to_string, 'say(abs(10), reverse(20, 30))', 'Built-ins parse correctly';
};
#
done_testing;
