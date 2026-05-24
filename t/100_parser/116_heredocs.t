use Test2::V0;
use lib 'lib';
use Brocken::Scanner;
#
my $scanner = Brocken::Scanner->new();
my $source  = <<'CODE';
my $x = <<EOF;
line 1
line 2
EOF
CODE
my $tokens = $scanner->scan($source);

# Debug: print types
# for my $t (@$tokens) { say $t->type; }
is( $tokens->[3]->type,  'HEREDOC_INIT',     "Heredoc init found at index 3" );
is( $tokens->[4]->type,  'SEMICOLON',        "Semicolon found at index 4" );
is( $tokens->[5]->type,  'HEREDOC_BODY',     "Heredoc body found at index 5" );
is( $tokens->[5]->value, "line 1\nline 2\n", "Content matches" );
#
done_testing;
