use Test2::V0;
use lib 'lib';
use Brocken::Scanner;
use Brocken::Parser;
#
my $scanner = Brocken::Scanner->new();
my $parser  = Brocken::Parser->new( mode => 'modern' );
subtest 'Control Flow' => sub {
    my $source_if = 'if (1) { my $x = 10; }';
    my $ast_if    = $parser->parse( $scanner->scan($source_if) );
    is $ast_if->[0]->to_string, 'if (1) { (ASSIGN $x= 10) }', 'If statement parses correctly';
    my $source_unless = 'unless (1) { my $x = 10; }';
    my $ast_unless    = $parser->parse( $scanner->scan($source_unless) );
    is $ast_unless->[0]->to_string, 'if (!(1)) { (ASSIGN $x= 10) }', 'Unless parses correctly as negated if';
    my $source_for = 'for (10) { my $x = 10; }';
    my $ast_for    = $parser->parse( $scanner->scan($source_for) );
    is $ast_for->[0]->to_string, 'while (10) { (ASSIGN $x= 10) }', 'For loop parses correctly';
};
subtest Subroutines => sub {
    my $source = 'sub foo { my $x = 10; }';
    my $ast    = $parser->parse( $scanner->scan($source) );
    like $ast->[0]->to_string, qr/sub foo/, 'Subroutine parses correctly';
};
subtest Scopes => sub {
    my $source_fail = '$x = 10;';
    my $tokens      = $scanner->scan($source_fail);
    eval { $parser->parse($tokens); };
    ok $@, 'Should catch error for undeclared variable';
    my $source_ok = 'my $x = 10; $x = 20;';
    my $ast       = $parser->parse( $scanner->scan($source_ok) );
    is scalar @$ast, 2, 'Should have 2 statements';
};
#
done_testing;
