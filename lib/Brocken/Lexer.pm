use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Encode 'decode';
use utf8;
use Brocken::Token;
#
my %KEYWORDS = map { $_ => 1 } qw(
    if elsif else unless while until for foreach
    sub my our state return last next redo do
    package use require no
    true false undef
    try catch finally
    class field
    fiber yield
    spawn_thread
);
my %OPKEY = map { $_ => 1 } qw(
    not and or xor
    eq ne lt gt le ge cmp
);

class Brocken::Lexer {
    field $source : param;
    field $pos  = 0;
    field $line = 1;
    field $col  = 1;
    field @buf;

    method ADJUST {
        utf8::decode($source);
    }

    method next () {
        return shift @buf if @buf;
        return $self->_scan();
    }

    method peek () {
        push @buf, $self->_scan() unless @buf;
        return $buf[0];
    }

    method unget ($tok) {
        unshift @buf, $tok;
    }

    method croak ($msg) {
        die "Brocken:$line:$col: $msg\n";
    }

    method _tok ( $type, $value ) {
        return Brocken::Token->new( type => $type, value => $value, line => $line, col => $col - length($value) );
    }

    method _tok_v ( $type, $value, $sigil ) {
        return Brocken::Token->new( type => $type, value => $value, sigil => $sigil, line => $line, col => $col - length($value) - 1 );
    }

    method _scan () {
        $self->_skip_ws();
        return undef if $pos >= length($source);
        my $ch = substr $source, $pos, 1;
        if ( $ch eq '=' && $pos + 1 < length($source) && substr( $source, $pos + 1, 1 ) =~ /[a-zA-Z_]/ ) {
            return $self->_scan_pod6();
        }
        return $self->_scan_ident()     if $ch =~ /[\p{ID_Start}_]/;
        return $self->_scan_number()    if $ch =~ /^[0-9]/;
        return $self->_scan_string($ch) if $ch eq "'" || $ch eq '"';
        if ( $ch eq '&' || $ch eq '%' ) {
            if ( $pos + 1 < length($source) && substr( $source, $pos + 1, 1 ) =~ /[\p{ID_Start}_]/ ) {
                return $self->_scan_var($ch);
            }
        }
        else {
            return $self->_scan_var($ch) if $ch =~ /^[\$\@\%]/;
        }
        if ( $ch eq '<' && $pos + 2 < length($source) && substr( $source, $pos + 1, 1 ) eq '<' && substr( $source, $pos + 2, 1 ) =~ /[a-zA-Z_]/ ) {
            return $self->_scan_heredoc();
        }
        return $self->_scan_operator();
    }

    method _scan_heredoc () {
        $pos += 2;
        $col += 2;
        my $start = $pos;
        while ( $pos < length($source) ) {
            my $ch = substr $source, $pos, 1;
            last unless $ch =~ /\p{ID_Continue}/;
            $pos++;
            $col++;
        }
        my $marker = substr $source, $start, $pos - $start;
        while ( $pos < length($source) && substr( $source, $pos, 1 ) =~ /^[ \t]/ ) {
            $pos++;
            $col++;
        }
        if ( $pos < length($source) && substr( $source, $pos, 1 ) eq ';' ) {
            $pos++;
            $col++;
        }
        if ( $pos < length($source) && substr( $source, $pos, 1 ) eq "\n" ) {
            $pos++;
            $line++;
            $col = 1;
        }
        my $content = '';
        while ( $pos < length($source) ) {
            my $line_start = $pos;
            while ( $pos < length($source) && substr( $source, $pos, 1 ) ne "\n" ) {
                $pos++;
                $col++;
            }
            my $line_text = substr $source, $line_start, $pos - $line_start;
            chomp $line_text;
            if ( $line_text eq $marker ) {
                if ( $pos < length($source) && substr( $source, $pos, 1 ) eq "\n" ) {
                    $pos++;
                    $line++;
                    $col = 1;
                }
                last;
            }
            $content .= substr $source, $line_start, $pos - $line_start + 1;
            if ( $pos < length($source) ) {
                $pos++;
                $line++;
                $col = 1;
            }
        }
        return $self->_tok( 'STRING', $content );
    }

    method _scan_pod6 () {
        my $start = $pos;
        $self->_skip_line();
        my $value = substr $source, $start, $pos - $start;
        return $self->_tok( 'POD6', $value );
    }

    method _skip_ws () {
        while ( $pos < length($source) ) {
            my $ch = substr $source, $pos, 1;
            last if $ch !~ /^[ \t\r\n\f]/ && $ch ne '#';
            if ( $ch eq '#' ) { $self->_skip_line() }
            else {
                if ( $ch eq "\n" ) { $line++; $col = 1 }
                else               { $col++ }
                $pos++;
            }
        }
    }

    method _skip_line () {
        $pos++;
        $col++;
        while ( $pos < length($source) ) {
            my $ch = substr $source, $pos, 1;
            last if $ch eq "\n";
            $col++;
            $pos++;
        }
    }

    method _scan_ident () {
        my $start = $pos;
        $pos++;
        $col++;
        while ( $pos < length($source) ) {
            my $ch = substr $source, $pos, 1;
            last unless $ch =~ /\p{ID_Continue}/;
            $pos++;
            $col++;
        }
        my $word = substr $source, $start, $pos - $start;
        return $self->_tok( 'KEYWORD', $word ) if exists $KEYWORDS{$word};
        return $self->_tok( $word,     $word ) if exists $OPKEY{$word};
        return $self->_tok( 'IDENT',   $word );
    }

    method _scan_number () {
        my $start    = $pos;
        my $is_float = 0;
        while ( $pos < length($source) ) {
            my $ch = substr $source, $pos, 1;
            last if $ch !~ /^[0-9]/;
            $pos++;
            $col++;
        }
        if ( $pos + 1 < length($source) && substr( $source, $pos, 1 ) eq '.' && substr( $source, $pos + 1, 1 ) =~ /^[0-9]/ ) {
            $is_float = 1;
            $pos++;
            $col++;
            while ( $pos < length($source) ) {
                my $ch = substr $source, $pos, 1;
                last if $ch !~ /^[0-9]/;
                $pos++;
                $col++;
            }
        }
        my $raw = substr $source, $start, $pos - $start;
        return $self->_tok( $is_float ? 'FLOAT' : 'INT', $is_float ? 0 + $raw : int($raw) );
    }

    method _scan_string ($delim) {
        $pos++;
        $col++;
        my $value = '';
        while ( $pos < length($source) ) {
            my $ch = substr $source, $pos, 1;
            $pos++;
            $col++;
            return $self->_tok( 'STRING', $value ) if $ch eq $delim;
            if ( $ch eq '\\' ) {
                my $next = substr $source, $pos++, 1 // '';
                $col++;
                if    ( $next eq 'n' )    { $value .= "\n" }
                elsif ( $next eq 't' )    { $value .= "\t" }
                elsif ( $next eq 'r' )    { $value .= "\r" }
                elsif ( $next eq '\\' )   { $value .= '\\' }
                elsif ( $next eq $delim ) { $value .= $delim }
                elsif ( $next eq 'x' ) {
                    if ( $pos < length($source) && substr( $source, $pos, 1 ) eq '{' ) {
                        $pos++;
                        $col++;
                        my $hex = '';
                        while ( $pos < length($source) ) {
                            my $h = substr $source, $pos, 1;
                            last if $h eq '}';
                            $hex .= $h;
                            $pos++;
                            $col++;
                        }
                        $self->croak("Unterminated hex escape") if $pos >= length($source);
                        $pos++;
                        $col++;
                        $value .= chr( hex($hex) );
                    }
                    else {
                        my $hex = substr( $source, $pos++, 1 ) // '';
                        $col++;
                        $value .= chr( hex($hex) );
                    }
                }
                else { $value .= $ch . $next }
            }
            else { $value .= $ch }
        }
        $self->croak("Unterminated string");
    }

    method _scan_var ($sigil) {
        $pos++;
        $col++;
        $self->croak("Expected variable name after '$sigil'") if $pos >= length($source);
        my $ch = substr $source, $pos, 1;
        $self->croak("Expected variable name after '$sigil', got '$ch'") if $ch !~ /[\p{ID_Start}_]/;
        my $start = $pos;
        while ( $pos < length($source) ) {
            my $ch = substr $source, $pos, 1;
            last unless $ch =~ /\p{ID_Continue}/;
            $pos++;
            $col++;
        }
        my $name = substr $source, $start, $pos - $start;
        return $self->_tok_v( 'VAR', $name, $sigil );
    }
    my %OPS = map { $_ => 1 } qw(
        => -> ++ -- ** == != <= >= <=> ~~ << >> && || // .. ...
        += -= *= /= %= .= **= &= |= ^= <<= >>=
    );
    my %SINGLES = map { $_ => 1 } split( '', '+ - * / % = < > ! ~ & | ^ ? . , ; ( ) { } [ ] \\' );

    method _scan_operator () {
        my $ch = substr $source, $pos, 1;
        if ( $ch eq ':' ) {
            $pos++;
            $col++;
            return $self->_tok( ':', ':' );
        }
        if ( $pos + 2 < length($source) ) {
            my $three = substr $source, $pos, 3;
            if ( exists $OPS{$three} ) {
                $pos += 3;
                $col += 3;
                return $self->_tok( $three, $three );
            }
        }
        if ( $pos + 1 < length($source) ) {
            my $two = substr $source, $pos, 2;
            if ( exists $OPS{$two} ) {
                $pos += 2;
                $col += 2;
                return $self->_tok( $two, $two );
            }
        }
        if ( exists $SINGLES{$ch} ) {
            $pos++;
            $col++;
            return $self->_tok( $ch, $ch );
        }
        $self->croak("Unexpected character '$ch'");
    }
}
#
1;
