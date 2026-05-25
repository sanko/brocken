use Test2::V0;
use lib 'lib';
use Brocken::Scanner;
use Brocken::Parser;
use Brocken::Compiler::SemanticAnalyzer;

my $scanner = Brocken::Scanner->new();
my $parser  = Brocken::Parser->new( mode => 'modern' );

subtest 'Type Inference' => sub {
    my $source = 'my Int $x = 10; my $y = $x + 2.5;';
    my $tokens = $scanner->scan($source);
    my $ast    = $parser->parse($tokens);
    
    my $analyzer = Brocken::Compiler::SemanticAnalyzer->new(symbols => $parser->symbols);
    $analyzer->analyze($ast);
    
    # $x should be Int
    my $stmt1 = $ast->[0];
    is $stmt1->variable->type->to_string, 'Int', '$x inferred as Int';
    
    # $y should be Double (Int + Double)
    my $stmt2 = $ast->[1];
    is $stmt2->value->type->to_string, 'Double', '$x + 2.5 inferred as Double';
    
    # Check y in symbol table - should be refined to Double
    is $parser->symbols->lookup('$y')->to_string, 'Double', '$y refined from Any to Double';
};

done_testing;
