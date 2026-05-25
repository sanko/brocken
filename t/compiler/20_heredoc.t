use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Lexer;

sub all_tokens {
    my $lexer = Brocken::Lexer->new(source => shift);
    my @tokens;
    while (my $t = $lexer->next) { push @tokens, $t }
    push @tokens, { type => 'EOF', value => undef };
    return \@tokens;
}

subtest 'Basic heredoc' => sub {
    my $source = "say <<MSG\nhello world\nMSG\n";
    my $tokens = all_tokens($source);
    is scalar(@$tokens), 3, 'three tokens: IDENT, STRING, EOF';
    is $tokens->[0]{type},  'IDENT',  'say is IDENT';
    is $tokens->[1]{type},  'STRING', 'heredoc body is STRING';
    is $tokens->[1]{value}, "hello world\n", 'heredoc content';
    is $tokens->[2]{type},  'EOF',    'ends with EOF';
};

subtest 'Heredoc with semicolon after marker' => sub {
    my $source = "say <<END;\nline1\nline2\nEND\n";
    my $tokens = all_tokens($source);
    is scalar(@$tokens), 3, 'three tokens';
    is $tokens->[1]{value}, "line1\nline2\n", 'content across multiple lines';
};

subtest 'Heredoc does not trigger for <<= operator' => sub {
    my $source = 'my $x = 1; $x <<= 2;';
    my $tokens = all_tokens($source);
    my $op = ( grep { defined $_->{value} && $_->{value} eq '<<=' } @$tokens )[0];
    ok $op, '<<= is an operator, not heredoc';
};

subtest 'Heredoc does not trigger for << shift operator' => sub {
    my $source = 'my $x = 1 << 2;';
    my $tokens = all_tokens($source);
    my $op = ( grep { defined $_->{value} && $_->{value} eq '<<' } @$tokens )[0];
    ok $op, '<< with following space/digit is shift operator';
};

subtest 'Empty heredoc' => sub {
    my $source = "say <<EOS\nEOS\n";
    my $tokens = all_tokens($source);
    is $tokens->[1]{value}, '', 'empty heredoc content';
};

subtest 'Heredoc with leading whitespace in marker line' => sub {
    my $source = "say <<MARKER\n  indented content\nMARKER\n";
    my $tokens = all_tokens($source);
    is $tokens->[1]{value}, "  indented content\n", 'preserves leading space in content';
};

done_testing;
