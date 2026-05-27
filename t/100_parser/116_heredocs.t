use v5.40;
use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;
subtest 'Basic heredoc in print' => sub {
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
subtest 'Heredoc with semicolon after marker' => sub {
    my $source = "print <<MARKER;\nline1\nline2\nMARKER\n";
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    ok $ast->statements->[0]->isa('Brocken::AST::Expr::Call'), 'heredoc with semicolon parsed';
    is $ast->statements->[0]->args->[0]->value, "line1\nline2\n", 'multi-line content';
};
subtest 'Heredoc assignment' => sub {
    my $source = "my \$x = <<END;\ncontent\nEND\n";
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    ok $ast->statements->[0]->isa('Brocken::AST::Stmt::VarDecl'),           'heredoc assignment is MyDecl';
    ok $ast->statements->[0]->value->isa('Brocken::AST::Expr::StrLiteral'), 'initializer is StrLiteral';
    is $ast->statements->[0]->value->value, "content\n", 'heredoc content in assignment';
};
subtest 'Empty heredoc' => sub {
    my $source = "print <<END;\nEND\n";
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    ok $ast->statements->[0]->isa('Brocken::AST::Expr::Call'), 'empty heredoc parsed';
    is $ast->statements->[0]->args->[0]->value, '', 'empty content';
};
subtest 'Heredoc does not trigger for <<= operator' => sub {
    my $source = 'my $x = 1; $x <<= 2;';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    is scalar( @{ $ast->statements } ), 2, 'two statements';
    ok $ast->statements->[1]->isa('Brocken::AST::Stmt::Assignment'), 'second is Assign (not heredoc)';
};
subtest 'Heredoc leading whitespace preserved' => sub {
    my $source = "print <<MARKER;\n  indented\nMARKER\n";
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    is $ast->statements->[0]->args->[0]->value, "  indented\n", 'leading whitespace preserved';
};
done_testing;
