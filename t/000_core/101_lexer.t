# t/lexer.t
use v5.38;
use Test2::V0;
use lib qw[lib ../../lib];
use Brocken::Core::Lexer;
#
subtest 'Basic Tokenization' => sub {
    my $code  = 'class Foo :isa(Bar) { field $id :param //= 10; }';
    my $lexer = Brocken::Core::Lexer->new( source => $code );
    my $toks  = $lexer->tokenize();
    is( $toks->[0]->type,  'KEYWORD',    'first token is class keyword' );
    is( $toks->[0]->value, 'class',      'first value is class' );
    is( $toks->[1]->type,  'IDENT',      'second is identifier' );
    is( $toks->[1]->value, 'Foo',        'second value is Foo' );
    is( $toks->[2]->type,  'COLON',      'third is colon' );
    is( $toks->[3]->type,  'IDENT',      'fourth is isa' );
    is( $toks->[8]->type,  'KEYWORD',    'field keyword found at index 8' );
    is( $toks->[9]->type,  'VAR',        'variable found at index 9' );
    is( $toks->[9]->value, '$id',        'variable value is $id' );
    is( $toks->[12]->type, 'OP_DEFAULT', 'operator is //= at index 12' );
    is( $toks->[-1]->type, 'EOF',        'ends with EOF' );
};
subtest 'Coordinate Tracking' => sub {
    my $code  = "class A {\n    field \$x;\n}";
    my $lexer = Brocken::Core::Lexer->new( source => $code );
    my $toks  = $lexer->tokenize();

    # Token structure:
    # 0: class, 1: A, 2: {, 3: field, 4: $x, 5: ;, 6: }, 7: EOF
    is $toks->[0]->line, 1, 'class keyword is on line 1';
    is $toks->[0]->col,  1, 'class keyword is on col 1';
    is $toks->[3]->line, 2, 'field keyword is on line 2';
    is $toks->[3]->col,  5, 'field keyword is indented to col 5';
};
subtest 'Lexer Error Handling' => sub {
    my $lexer = Brocken::Core::Lexer->new( source => 'field $x @ 10;' );

    # Verify that invalid characters cause an expected exception
    like dies { $lexer->tokenize() }, qr/Lexical Error: Unexpected character '\@'/, 'lexer dies with positional info on invalid characters';
};
#
done_testing;
