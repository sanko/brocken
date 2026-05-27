use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Token;
use Encode ();

class Brocken::Scanner {

    # Simple regex-based tokenization
    my %TOKEN_PATTERNS = (
        KEYWORD =>
            qr/\b(my|sub|class|field|method|return|if|elsif|else|while|eval|print|say|our|local|state|use|no|package|for|foreach|do|given|when|default|continue|next|last|redo|goto|unless|until|grep|map|sort|die|warn|keys|values|each|defined|undef|exists|delete|and|or|not|xor|eq|ne|lt|gt|le|ge|cmp|abs|chr|hex|oct|ord|pack|reverse|sprintf|uc|lc|ucfirst|open|close|opendir|closedir|read|readline|write|printf|seek|tell|truncate|binmode|chdir|chmod|chown|chroot|unlink|rename|link|symlink|mkdir|rmdir|stat|lstat|exec|fork|system|kill|wait|waitpid|accept|bind|connect|listen|recv|send|socket|time|times|utime|require|import|length|substr|index|push|pop|shift|unshift|qq|q|qw|qr|qx|try|catch|finally)\b/u,
        OPERATOR     => qr/(\.\.\.|\.\.|<<=|>>=|&&=|\|\|=|\*\*=|->|=>|==|!=|<=|>=|&&|\|\||\*\*|<<|>>|[-+*\/%&|^=<>!~.])/u,
        FILE_TEST_OP => qr/-\w\b/u,
        VARIABLE     => qr/[\$@%&]\w+/u,
        IDENTIFIER   => qr/[a-zA-Z_][a-zA-Z0-9_]*/u,
        STRING       => qr/"[^"]*"|'[^']*'/u,
        NUMBER       => qr/\d+(\.\d+)?/u,
        SEMICOLON    => qr/;/u,
        COMMA        => qr/,/u,
        POD6_CMD     => qr/^=[a-zA-Z_]\w*/mu,
        ATTRIBUTE    => qr/:[a-zA-Z_][a-zA-Z0-9_]*/u,
        HEREDOC_INIT => qr/<<([a-zA-Z_]\w*)/u,
        LBRACE       => qr/\{/u,
        RBRACE       => qr/\}/u,
        LBRACKET     => qr/\[/u,
        RBRACKET     => qr/\]/u,
        LPAREN       => qr/\(/u,
        RPAREN       => qr/\)/u,
        WHITESPACE   => qr/\s+/u,
    );

    method scan( $source, $filename = 'input' ) {

        # Ensure source is decoded UTF-8
        $source = Encode::decode_utf8($source) unless utf8::is_utf8($source);
        my @tokens;
        my $line      = 1;
        my $col       = 1;
        my $remaining = $source;
        while ( length $remaining > 0 ) {
            my $matched = 0;

            # Consume whitespace and comments
            if ( $remaining =~ /^((?:\s+|#.*(?:\n|$))+)/u ) {
                my $match = $1;
                my @lines = split /\n/, $match, -1;
                if ( @lines > 1 ) {
                    $line += @lines - 1;
                    $col = length( $lines[-1] ) + 1;
                }
                else {
                    $col += length($match);
                }
                $remaining = substr( $remaining, length($match) );
                next;
            }

            # Heredoc detection (if we see <<IDENTIFIER)
            # NOTE: We check for HEREDOC_INIT BEFORE general OPERATORS because '<<' is an operator
            if ( $remaining =~ /^<<([a-zA-Z_]\w*)/u ) {
                my $marker = $1;
                my $match  = $&;
                push @tokens, Brocken::Token->new( type => 'HEREDOC_INIT', value => $marker, line => $line, column => $col, file => $filename );
                $col += length($match);
                $remaining = substr( $remaining, length($match) );

                # If there's a semicolon after the marker (with optional whitespace), consume it
                if ( $remaining =~ /^(\s*;)/ ) {
                    my $semi_match = $1;
                    push @tokens,
                        Brocken::Token->new(
                        type   => 'SEMICOLON',
                        value  => ';',
                        line   => $line,
                        column => $col + ( length($semi_match) - 1 ),
                        file   => $filename
                        );
                    $col += length($semi_match);
                    $remaining = substr( $remaining, length($semi_match) );
                }

                # Consume heredoc content
                my $content = "";

                # Consume newline after marker
                if ( $remaining =~ /^\n/ ) {
                    $remaining = substr( $remaining, 1 );
                    $line++;
                    $col = 1;
                }
                while ( $remaining =~ /^(.*(?:\n|$))/u ) {
                    my $line_content = $1;
                    if ( $line_content =~ /^$marker(?:\n|$)/u ) {
                        $remaining = substr( $remaining, length($line_content) );
                        $line++;
                        $col = 1;
                        last;
                    }
                    $content .= $line_content;
                    $remaining = substr( $remaining, length($line_content) );
                    $line++;
                    $col = 1;
                }
                push @tokens, Brocken::Token->new( type => 'HEREDOC_BODY', value => $content, line => $line, column => $col, file => $filename );
                $matched = 1;
                next;
            }

            # Try matching patterns in order
            foreach my $type (
                qw(KEYWORD FILE_TEST_OP VARIABLE IDENTIFIER STRING NUMBER SEMICOLON COMMA POD6_CMD ATTRIBUTE OPERATOR LBRACE RBRACE LBRACKET RBRACKET LPAREN RPAREN)
            ) {
                my $pattern = $TOKEN_PATTERNS{$type};
                if ( $remaining =~ /^($pattern)/ ) {
                    my $val = $1;
                    push @tokens, Brocken::Token->new( type => $type, value => $val, line => $line, column => $col, file => $filename, );
                    $col += length($val);
                    $remaining = substr( $remaining, length($val) );
                    $matched   = 1;
                    last;
                }
            }
            if ( !$matched ) {
                die sprintf( "Unknown token at %s:%d:%d, Remaining: '%s'", $filename, $line, $col, $remaining );
            }
        }
        return \@tokens;
    }
}
1;
