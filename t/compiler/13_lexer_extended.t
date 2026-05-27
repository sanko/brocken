use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib', '../../lib';
use Brocken::Lexer;

sub all_tokens {
    my $lexer = Brocken::Lexer->new( source => shift );
    my @tokens;
    while ( my $t = $lexer->next ) { push @tokens, $t }
    push @tokens, Brocken::Token->new( type => 'EOF', value => undef );
    return \@tokens;
}
subtest 'For loop keywords' => sub {
    my $tokens = all_tokens('for');
    is $tokens->[0]->type,  'KEYWORD', 'for is KEYWORD';
    is $tokens->[0]->value, 'for',     'for value';
};
subtest 'Loop control keywords' => sub {
    for my $kw (qw(next last redo)) {
        my $tokens = all_tokens($kw);
        is $tokens->[0]->type, 'KEYWORD', "$kw is KEYWORD";
    }
};
subtest 'Boolean literals' => sub {
    for my $kw (qw(true false undef)) {
        my $tokens = all_tokens($kw);
        is $tokens->[0]->type, 'KEYWORD', "$kw is KEYWORD";
    }
};
subtest 'Type identifiers' => sub {
    for my $kw (qw(Int String)) {
        my $tokens = all_tokens($kw);
        is $tokens->[0]->type, 'IDENT', "$kw is IDENT (not a keyword)";
    }
};
subtest 'Defined-or operator' => sub {
    my $tokens = all_tokens('//');
    is $tokens->[0]->value, '//', 'defined-or operator';
    is $tokens->[0]->type,  '//', '// is its own type';
};
subtest 'Arrow operator' => sub {
    my $tokens = all_tokens('->');
    is $tokens->[0]->value, '->', 'arrow operator';
    is $tokens->[0]->type,  '->', '-> is its own type';
};
subtest 'Fat comma' => sub {
    my $tokens = all_tokens('=>');
    is $tokens->[0]->value, '=>', 'fat comma';
    is $tokens->[0]->type,  '=>', '=> is its own type';
};
subtest 'Regular variables' => sub {
    for my $v (qw($x $_ $name)) {
        my $tokens = all_tokens($v);
        is $tokens->[0]->type, 'VAR', "$v is VAR";
    }
};
subtest 'Multiple operators sequence' => sub {
    my $tokens = all_tokens('$x <= 10 && $y >= 20 || !$z');
    my @ops;
    for my $t (@$tokens) {
        next if $t->type eq 'VAR' || $t->type eq 'INT' || $t->type eq 'EOF';
        push @ops, $t->value;
    }
    is scalar(@ops), 5,    '5 operators in sequence';
    is $ops[0],      '<=', 'first op is <=';
    is $ops[1],      '&&', 'second op is &&';
    is $ops[2],      '>=', 'third op is >=';
    is $ops[3],      '||', 'fourth op is ||';
    is $ops[4],      '!',  'fifth op is !';
};
subtest 'Comment handling' => sub {
    my $tokens = all_tokens("# just a comment\nsay 42");
    is scalar(@$tokens),    3,     'comment skipped: say, INT, EOF';
    is $tokens->[0]->value, 'say', 'first token after comment';
};
subtest 'Empty source' => sub {
    my $tokens = all_tokens('');
    is scalar(@$tokens),   1,     'only EOF for empty source';
    is $tokens->[0]->type, 'EOF', 'EOF token';
};
subtest 'Punctuation tokens' => sub {
    my @punct = ( '{', '}', ';', '(', ')', ',' );
    for my $p (@punct) {
        my $tokens = all_tokens($p);
        is $tokens->[0]->value, $p, "punctuation $p";
    }
};
done_testing;
