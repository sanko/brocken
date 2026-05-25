use Test2::V0;
use lib 'lib';
use Brocken::Scanner;
use Brocken::Parser;

my $scanner = Brocken::Scanner->new();
my $parser  = Brocken::Parser->new( mode => 'perl' );

subtest 'Perl Mode Assignment' => sub {
    my $source = '$x = 10;'; # No 'my'
    my $tokens = $scanner->scan($source);
    my $ast    = $parser->parse($tokens);
    
    is $ast->[0]->isa('Brocken::AST::ControlFlow::Assignment'), 1, 'Assignment parses even without declaration in perl mode';
};

done_testing;
