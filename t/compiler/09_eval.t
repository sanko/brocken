use Test2::V0;
use lib 'lib';
use Brocken::Scanner;
use Brocken::Parser;
use Brocken::Compiler::SemanticAnalyzer;

my $scanner = Brocken::Scanner->new();
my $parser  = Brocken::Parser->new( mode => 'modern' );

subtest 'Eval Parsing and Analysis' => sub {
    my $source = 'eval("print 10");';
    my $tokens = $scanner->scan($source);
    my $ast    = $parser->parse($tokens);
    
    my $analyzer = Brocken::Compiler::SemanticAnalyzer->new(symbols => $parser->symbols);
    $analyzer->analyze($ast);
    
    is $ast->[0]->to_string, 'eval("print 10")', 'Eval parses correctly';
    is $ast->[0]->isa('Brocken::AST::ControlFlow::SimpleStatement'), 1, 'AST node type is correct';
};

done_testing;
