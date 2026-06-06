# t/optimizer.t
use v5.38;
use Test2::V0;
use lib qw[lib ../../lib];
use Brocken::Core::Lexer;
use Brocken::Core::Parser;
use Brocken::Core::Optimizer;
subtest 'Constant Folding Arithmetic' => sub {
    my $tests = [
        { code => '5 + 10',      expected => '15' },
        { code => '12 - 4',      expected => '8' },
        { code => '3 * 4',       expected => '12' },
        { code => '20 / 4',      expected => '5' },
        { code => '(2 + 3) * 4', expected => '20' }
    ];
    for my $t (@$tests) {
        my $lexer  = Brocken::Core::Lexer->new( source => $t->{code} );
        my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
        my $ast    = $parser->parse_expression(0);
        my $opt    = Brocken::Core::Optimizer->new();
        my $folded = $opt->fold_constants($ast);
        is $folded->to_string, $t->{expected}, "folded expression '" . $t->{code} . "' to " . $t->{expected};
    }
};
subtest 'Compile-time Safety Checks' => sub {
    my $lexer  = Brocken::Core::Lexer->new( source => '10 / 0' );
    my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $ast    = $parser->parse_expression(0);
    my $opt    = Brocken::Core::Optimizer->new();
    like dies { $opt->fold_constants($ast) }, qr/Compile Error: Division by zero/, 'compiler catches compile-time division by zero errors';
};
subtest 'Position Preservation' => sub {
    my $lexer  = Brocken::Core::Lexer->new( source => "\n\n   2 + 3" );
    my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $ast    = $parser->parse_expression(0);

    # Node starts at Line 3, Column 4
    is $ast->line, 3, 'addition op node is on line 3';
    is $ast->col,  6, 'addition op node is on col 6 (index of +)';
    my $opt    = Brocken::Core::Optimizer->new();
    my $folded = $opt->fold_constants($ast);
    is $folded->line, 3, 'folded literal retains line 3';
    is $folded->col,  6, 'folded literal retains col 6';
};
done_testing;
