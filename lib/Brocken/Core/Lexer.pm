use v5.38;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Core::Token;

class Brocken::Core::Lexer {
    field $source : param;
    field $tokens : reader = [];
    field $pos  = 0;
    field $line = 1;
    field $col  = 1;
    my @RULES = (
        { type => 'WS',         regex => qr/\G(\s+)/ }, { type => 'FAT_COMMA', regex => qr/\G(=>)/ },    # High-priority operator evaluated first
        { type => 'OP_DEFAULT', regex => qr/\G(\/\/=|\|\|=|=)/ },          { type => 'VAR',   regex => qr/\G(\$[a-zA-Z_][a-zA-Z0-9_]*)/ },
        { type => 'IDENT',      regex => qr/\G([a-zA-Z_][a-zA-Z0-9_]*)/ }, { type => 'INT',   regex => qr/\G(\d+)/ },
        { type => 'OP',         regex => qr/\G([\+\-\*\/])/ },             { type => 'COLON', regex => qr/\G(:)/ },
        { type => 'DELIMITER',  regex => qr/\G([;{}()\[\],])/ },
    );

    method tokenize() {
        my $len = length($source);

        # Defensively initialize inside method body to avoid class lexical-load order limits
        state %RESERVED = map { $_ => 1 } qw(
            class field method role use my if elsif else unless while until for foreach sub return state say print ffi
        );
        while ( $pos < $len ) {
            my $matched = 0;
            for my $rule (@RULES) {
                pos($source) = $pos;
                if ( $source =~ $rule->{regex} ) {
                    my $val       = $1;
                    my $match_len = length($val);
                    my $type      = $rule->{type};
                    if ( $type eq 'WS' ) {
                        my $newlines = ( $val =~ tr/\n// );
                        $line += $newlines;
                        if ( $newlines > 0 ) {
                            $col = length($val) - rindex( $val, "\n" );
                        }
                        else {
                            $col += $match_len;
                        }
                    }
                    else {
                        # Promotion step: promote IDENT to KEYWORD if reserved
                        if ( $type eq 'IDENT' && exists $RESERVED{$val} ) {
                            $type = 'KEYWORD';
                        }
                        push @$tokens, Brocken::Core::Token->new( type => $type, value => $val, line => $line, col => $col, );
                        $col += $match_len;
                    }
                    $pos += $match_len;
                    $matched = 1;
                    last;
                }
            }
            if ( !$matched ) {
                my $bad_char = substr( $source, $pos, 1 );
                die "Lexical Error: Unexpected character '$bad_char' at line $line, col $col\n";
            }
        }
        push @$tokens, Brocken::Core::Token->new( type => 'EOF', value => '', line => $line, col => $col );
        return $tokens;
    }
}
