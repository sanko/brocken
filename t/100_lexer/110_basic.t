use v5.40;
use Test2::V0;
use lib 'lib';
use Brocken::Lexer;

sub tokens ($source) {
    my $l = Brocken::Lexer->new( source => $source );
    my @t;
    while ( my $t = $l->next() ) { push @t, $t }
    return @t;
}
sub tok ( $source, $idx ) { ( tokens($source) )[$idx] }

# Basic tokens
my @t = tokens('42');
is scalar(@t),   1,     'Single INT';
is $t[0]->type,  'INT', 'Type INT';
is $t[0]->value, 42,    'Value 42';

# Keywords
@t = tokens('if');
is $t[0]->type,  'KEYWORD', 'Keyword type';
is $t[0]->value, 'if',      'Keyword value if';

# Variables
@t = tokens('$x');
is $t[0]->type,  'VAR', 'VAR type';
is $t[0]->value, 'x',   'VAR name x';
is $t[0]->sigil, '$',   'VAR sigil $';
@t = tokens('@arr');
is $t[0]->sigil, '@', 'Array sigil @';

# Numbers
is tok( '3.14', 0 )->type,  'FLOAT', 'Float type';
is tok( '3.14', 0 )->value, 3.14,    'Float value 3.14';
is tok( '0',    0 )->type,  'INT',   'Zero type INT';
is tok( '0',    0 )->value, 0,       'Zero value 0';

# Strings
is tok( '"hello"', 0 )->value, 'hello', 'Double string value';
is tok( "'world'", 0 )->value, 'world', 'Single string value';

# Escape sequences
is tok( '"line\nbreak"', 0 )->value, "line\nbreak", 'String \\n';
is tok( '"tab\tstop"',   0 )->value, "tab\tstop",   'String \\t';
is tok( '"quote\\""',    0 )->value, 'quote"',      'String \\"';
is tok( '"back\\\\"',    0 )->value, 'back\\',      'String \\\\';

# \x{...} escape
is tok( '"\x{263A}"', 0 )->value, chr(0x263A), 'String \\x{...} unicode';

# Comments
@t = tokens("# comment\n42");
is scalar(@t),   1,  'Comment stripped';
is $t[0]->value, 42, 'INT after comment';

# Operators
is tok( '$x + $y',   1 )->type,  '+',   'Plus operator type';
is tok( '$x == $y',  1 )->type,  '==',  '== operator';
is tok( '$x <= $y',  1 )->type,  '<=',  '<= operator';
is tok( '$x <=> $y', 1 )->type,  '<=>', '<=> operator';
is tok( '$x += $y',  1 )->type,  '+=',  '+= operator';
is tok( '$x->foo',   1 )->type,  '->',  '-> operator';
is tok( '$x++',      1 )->value, '++',  '++ operator';

# Parentheses and semicolons
@t = tokens('(1);');
is $t[0]->type, '(',   'Left paren';
is $t[1]->type, 'INT', 'INT after paren';
is $t[2]->type, ')',   'Right paren';
is $t[3]->type, ';',   'Semicolon';

# Colons and commas
@t = tokens(': ,');
is $t[0]->type, ':', 'Colon';
is $t[1]->type, ',', 'Comma';

# Braces/brackets
@t = tokens('{ [ } ]');
is $t[0]->type, '{', 'Left brace';
is $t[1]->type, '[', 'Left bracket';
is $t[2]->type, '}', 'Right brace';
is $t[3]->type, ']', 'Right bracket';

# Multiple statements
@t = tokens('my $x = 10 + 2;');
is scalar(@t),   7,    '7 tokens for my $x = 10 + 2;';
is $t[0]->value, 'my', 'First token my';
is $t[1]->value, 'x',  'Second token x (VAR)';
is $t[2]->value, '=',  'Third token =';
is $t[3]->value, 10,   'Fourth token 10';
is $t[4]->value, '+',  'Fifth token +';
is $t[5]->value, 2,    'Sixth token 2';
is $t[6]->type,  ';',  'Seventh token ;';

# Identifiers (non-keyword)
@t = tokens('foo');
is $t[0]->type,  'IDENT', 'Non-keyword ident type';
is $t[0]->value, 'foo',   'Non-keyword ident value';

# Operator-words
@t = tokens('not and or xor');
is $t[0]->type, 'not', 'not token type';
is $t[1]->type, 'and', 'and token type';
is $t[2]->type, 'or',  'or token type';
is $t[3]->type, 'xor', 'xor token type';

# Line/column tracking
@t = tokens("my\n\$x\n");
is $t[0]->line, 1, 'my at line 1';
is $t[0]->col,  1, 'my at col 1';
is $t[1]->line, 2, '$x at line 2';
is $t[1]->col,  1, '$x at col 1';

# peek/unget
my $l  = Brocken::Lexer->new( source => '1 2 3' );
my $p1 = $l->peek();
my $p2 = $l->peek();
is $p1->value, 1, 'peek returns 1';
is $p2->value, 1, 'peek again returns 1 (same token)';
my $n1 = $l->next();
is $n1->value, 1, 'next returns 1';
$l->unget($n1);
my $n2 = $l->next();
is $n2->value, 1, 'unget then next returns 1 again';

# UTF-8 identifiers
@t = tokens('élève');
is $t[0]->type,  'IDENT', 'Unicode ident type';
is $t[0]->value, 'élève', 'Unicode ident value';

# UTF-8 source decoding
$l = Brocken::Lexer->new( source => "my \$x = \"héllo\";" );
@t = ();
while ( my $t = $l->next() ) { push @t, $t }
is scalar(@t),   5,       'UTF-8 source gives 5 tokens';
is $t[3]->value, 'héllo', 'UTF-8 string value';

# POD6
@t = tokens("=head1\nstuff");
is $t[0]->type,  'POD6',   'POD6 type';
is $t[0]->value, '=head1', 'POD6 value';

# True/False/Undef keywords
@t = tokens('true false undef');
is $t[0]->type,  'KEYWORD', 'true is keyword';
is $t[0]->value, 'true',    'true value';
is $t[1]->value, 'false',   'false value';
is $t[2]->value, 'undef',   'undef value';

# Error: unterminated string
$l = Brocken::Lexer->new( source => '"no end' );
my $err;
eval { $l->next(); 1 } or $err = $@;
ok $err, 'Unterminated string dies';
like $err, qr/Unterminated/, 'Error message mentions unterminated';

# Error: unexpected character
$l   = Brocken::Lexer->new( source => '@' );
$err = undef;
eval { $l->next(); 1 } or $err = $@;
ok $err, 'Bad sigil dies';
done_testing;
