use Test2::V0;
use lib 'lib';
use Brocken::Scanner;
use Brocken::Parser;
#
my $scanner = Brocken::Scanner->new();
my $parser  = Brocken::Parser->new( mode => 'modern' );
my $source  = q{
    sub main :shared {
        my $x = 10;
        if (1) {
            our $y = 20;
            $x = $y + 5;
        }
        # say "Hello" if 0;
        print($x);
    }
};
my $tokens = $scanner->scan($source);
my $ast    = $parser->parse($tokens);
is scalar @$ast, 1, 'Should have 1 statement';
like $ast->[0]->to_string, qr/sub main :shared/, 'Full pipeline parses';
#
done_testing;
