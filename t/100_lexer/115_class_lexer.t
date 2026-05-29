use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Lexer;

sub all_tokens {
    my $lexer = Brocken::Lexer->new( source => shift );
    my @tokens;
    while ( my $t = $lexer->next ) { push @tokens, $t }
    push @tokens, Brocken::Token->new( type => 'EOF', value => undef );
    return \@tokens;
}
subtest 'Basic Tokenization' => sub {
    my $source = 'my Int $x = 42; say "hello world";';
    my $tokens = all_tokens($source);
    is( scalar @$tokens,     10,        'Correct number of tokens' );
    is( $tokens->[0]->type,  'KEYWORD', 'my' );
    is( $tokens->[1]->type,  'IDENT',   'Int is IDENT (not KEYWORD)' );
    is( $tokens->[2]->type,  'VAR',     '$x' );
    is( $tokens->[3]->value, '=',       'assignment' );
    is( $tokens->[4]->type,  'INT',     '42' );
    is( $tokens->[5]->value, ';',       'semicolon' );
    is( $tokens->[6]->type,  'IDENT',   'say is IDENT' );
    is( $tokens->[7]->type,  'STRING',  'string literal' );
    is( $tokens->[8]->value, ';',       'final semicolon' );
    is( $tokens->[9]->type,  'EOF',     'EOF' );
};
subtest 'Complex Operators' => sub {
    my $source = '$x == 10 && $y != 20 || !$z;';
    my $tokens = all_tokens($source);
    my @ops;
    for my $t (@$tokens) {
        next if $t->type eq 'VAR' || $t->type eq 'INT' || ( defined $t->value && $t->value eq ';' ) || $t->type eq 'EOF';
        push @ops, $t->value;
    }
    is( [@ops], [qw( == && != || ! )], 'Correct operator sequence' );
};
subtest 'Comments' => sub {
    my $source = 'my $x = 10; # this is a comment
say $x;';
    my $tokens = all_tokens($source);
    is( $tokens->[4]->value, ';',   'Tokens before comment' );
    is( $tokens->[5]->value, 'say', 'Tokens after comment' );
};
done_testing;
