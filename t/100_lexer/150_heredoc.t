use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;

sub all_tokens {
    my $lexer = Brocken::Lexer->new( source => shift );
    my @tokens;
    while ( my $t = $lexer->next ) { push @tokens, $t }
    push @tokens, Brocken::Token->new( type => 'EOF', value => undef );
    return \@tokens;
}

# ---- Lexer-level heredoc tests ----
subtest 'Basic heredoc lexing' => sub {
    my $source = "say <<MSG\nhello world\nMSG\n";
    my $tokens = all_tokens($source);
    is scalar(@$tokens),    3,               'three tokens: IDENT, STRING, EOF';
    is $tokens->[0]->type,  'IDENT',         'say is IDENT';
    is $tokens->[1]->type,  'STRING',        'heredoc body is STRING';
    is $tokens->[1]->value, "hello world\n", 'heredoc content';
    is $tokens->[2]->type,  'EOF',           'ends with EOF';
};

subtest 'Heredoc with semicolon after marker (lexer)' => sub {
    my $source = "say <<END;\nline1\nline2\nEND\n";
    my $tokens = all_tokens($source);
    is scalar(@$tokens),    3,                'three tokens';
    is $tokens->[1]->value, "line1\nline2\n", 'content across multiple lines';
};

subtest 'Heredoc does not trigger for <<= operator' => sub {
    my $source = 'my $x = 1; $x <<= 2;';
    my $tokens = all_tokens($source);
    my $op     = ( grep { defined $_->value && $_->value eq '<<=' } @$tokens )[0];
    ok $op, '<<= is an operator, not heredoc';
};

subtest 'Heredoc does not trigger for << shift operator' => sub {
    my $source = 'my $x = 1 << 2;';
    my $tokens = all_tokens($source);
    my $op     = ( grep { defined $_->value && $_->value eq '<<' } @$tokens )[0];
    ok $op, '<< with following space/digit is shift operator';
};

subtest 'Empty heredoc lexing' => sub {
    my $source = "say <<EOS\nEOS\n";
    my $tokens = all_tokens($source);
    is $tokens->[1]->value, '', 'empty heredoc content';
};

subtest 'Heredoc with leading whitespace in marker line (lexer)' => sub {
    my $source = "say <<MARKER\n  indented content\nMARKER\n";
    my $tokens = all_tokens($source);
    is $tokens->[1]->value, "  indented content\n", 'preserves leading space in content';
};

# ---- Parser-level heredoc tests ----
subtest 'Basic heredoc in print (parser)' => sub {
    my $source = "print <<MARKER;\nhello\nMARKER\n";
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    is scalar( @{ $ast->statements } ), 1, 'one statement';
    ok $ast->statements->[0]->isa('Brocken::AST::Expr::Call'), 'statement is Call';
    is $ast->statements->[0]->name,                'print', 'calling print';
    is scalar( @{ $ast->statements->[0]->args } ), 1,       'one arg';
    ok $ast->statements->[0]->args->[0]->isa('Brocken::AST::Expr::StrLiteral'), 'arg is StrLiteral';
    is $ast->statements->[0]->args->[0]->value, "hello\n", 'heredoc content';
};

subtest 'Heredoc with semicolon after marker (parser)' => sub {
    my $source = "print <<MARKER;\nline1\nline2\nMARKER\n";
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    ok $ast->statements->[0]->isa('Brocken::AST::Expr::Call'), 'heredoc with semicolon parsed';
    is $ast->statements->[0]->args->[0]->value, "line1\nline2\n", 'multi-line content';
};

subtest 'Heredoc assignment (parser)' => sub {
    my $source = "my \$x = <<END;\ncontent\nEND\n";
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    ok $ast->statements->[0]->isa('Brocken::AST::Stmt::VarDecl'),           'heredoc assignment is VarDecl';
    ok $ast->statements->[0]->value->isa('Brocken::AST::Expr::StrLiteral'), 'initializer is StrLiteral';
    is $ast->statements->[0]->value->value, "content\n", 'heredoc content in assignment';
};

subtest 'Empty heredoc (parser)' => sub {
    my $source = "print <<END;\nEND\n";
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    ok $ast->statements->[0]->isa('Brocken::AST::Expr::Call'), 'empty heredoc parsed';
    is $ast->statements->[0]->args->[0]->value, '', 'empty content';
};

subtest 'Heredoc leading whitespace preserved (parser)' => sub {
    my $source = "print <<MARKER;\n  indented\nMARKER\n";
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    is $ast->statements->[0]->args->[0]->value, "  indented\n", 'leading whitespace preserved';
};

done_testing;
