use Test2::V0;
use lib 'lib';
use Brocken::Scanner;
use Brocken::Parser;
#
my $scanner = Brocken::Scanner->new();
my $parser  = Brocken::Parser->new( mode => 'modern' );
subtest Vectors => sub {
    my $source = 'my Vec[Int64, 4] $v1 = 10;';
    my $ast    = $parser->parse( $scanner->scan($source) );
    is $ast->[0]->to_string, '(ASSIGN $v1= 10)', 'Vector annotation parses';
};
subtest Attributes => sub {
    my $source_sub = 'sub foo :lvalue { my $x = 10; }';
    my $ast_sub    = $parser->parse( $scanner->scan($source_sub) );
    like $ast_sub->[0]->to_string, qr/sub foo :lvalue/, "Sub with attributes parses";
    my $source_var = 'my $x :shared = 10;';
    my $ast_var    = $parser->parse( $scanner->scan($source_var) );
    is $ast_var->[0]->to_string, '(ASSIGN :shared $x= 10)', 'Var with attributes parses';
};
subtest 'Built-ins' => sub {
    my $source = 'print(10, 20);';
    my $ast    = $parser->parse( $scanner->scan($source) );
    is $ast->[0]->to_string, 'print(10, 20)', 'Print parses correctly';
};
#
done_testing;
