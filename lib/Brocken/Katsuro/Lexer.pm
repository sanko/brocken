use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
class Brocken::Katsuro::Lexer v0.0.1 {
    use Carp qw[croak];
    field $source : param;
    field $filename : param = '(eval)';
    field $pos  = 0;
    field $line = 1;
    field $col  = 1;
    my %KEYWORDS = map { $_ => 1 } qw[
        my our state const type sub method class role has field ADJUST DESTROY
        return exit fiber yield transfer try catch finally throw defer
        if elsif else unless while until for foreach next last redo map say print
        true false True False __CLASS__ Int String Any Bool ptr int bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64
        use require
    ];

    method lex() {
        my @tokens;
        my $len = length($source);
        while ( $pos < $len ) {
            my $remaining = substr( $source, $pos );

            # 1. Skip Whitespace & Comments
            if ( $remaining =~ /^(\s+)/ ) {
                my $matched = $1;
                $self->_advance_pos( length($matched) );
                next;
            }
            if ( $remaining =~ /^(#[^\n]*)/ ) {
                my $matched = $1;
                $self->_advance_pos( length($matched) );
                next;
            }

            # 2. Match Identifiers & Package-qualified namespaces (e.g. Brocken::load_i64)
            if ( $remaining =~ /^([\$@%]?[a-zA-Z_]\w*(?:::[a-zA-Z_]\w*)*)/ ) {
                my $val  = $1;
                my $type = 'IDENT';
                if ( exists $KEYWORDS{$val} ) {
                    $type = 'KEYWORD';
                }
                elsif ( $val =~ /^[\$@%]/ ) {
                    $type = 'VAR';
                }
                push @tokens, $self->_token( $type, $val );
                $self->_advance_pos( length($val) );
                next;
            }

            # 3. Match Numbers
            #
            # A decimal point or an exponent makes it a float, and the lexer is
            # the only place that can know: it used to match the digits and stop
            # at the '.', so `my f64 $t = 3.0;` reached the parser as the integer
            # 3, a '.', and a 0, and the whole class of float literals a reader
            # reaches for first was unavailable.
            #
            # The digits after the point are required, so `1..2` still lexes as
            # the integer 1 and the `..` range rather than as a malformed `1.`.
            # An exponent may stand on its own -- `1e9` -- which is how it is
            # written everywhere else. A float is always f64; the parser tags
            # the token and a narrower slot re-tags the constant, so there is no
            # untyped float to carry through the IR.
            if ( $remaining =~ /^(\d+\.\d+(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+|\d+)/ ) {
                my $val      = $1;
                my $is_float = $val =~ /\.\d/ || $val =~ /[eE]/;
                push @tokens, $self->_token( 'NUM', $val, $is_float );
                $self->_advance_pos( length($val) );
                next;
            }

            # 4. Match Strings (Double or Single Quoted)
            if ( $remaining =~ /^"((?:[^"\\]|\\.)*)"/s || $remaining =~ /^'((?:[^'\\]|\\.)*)'/s ) {
                my $val = $1;
                push @tokens, $self->_token( 'STRING', $val );
                $self->_advance_pos( length($val) + 2 );    # account for quotes
                next;
            }

            # 5. Match Operators (multi-character first)
            if ( $remaining =~ /^(==|!=|<=|>=|<=>|=>|->|\&\&|\|\||\/\/=|\/\/|\.\.\.?)/ ) {
                my $val = $1;
                push @tokens, $self->_token( 'OP', $val );
                $self->_advance_pos( length($val) );
                next;
            }
            if ( $remaining =~ /^([+\-*\/%=<>!&|^~?:.])/ ) {
                my $val = $1;
                push @tokens, $self->_token( 'OP', $val );
                $self->_advance_pos(1);
                next;
            }

            # 6. Match Punctuation
            if ( $remaining =~ /^([{};(),\[\]])/ ) {
                my $val = $1;
                push @tokens, $self->_token( $val, $val );
                $self->_advance_pos(1);
                next;
            }

            # Lexical Error fallback
            my $bad_char = substr( $remaining, 0, 1 );
            croak "Lexical Error: Unexpected character '$bad_char' at $filename line $line, col $col";
        }
        push @tokens, $self->_token( 'EOF', '' );
        return \@tokens;
    }

    method _token( $type, $val, $float = 0 ) {
        return { type => $type, value => $val, line => $line, col => $col, ( $float ? ( float => 1 ) : () ) };
    }

    method _advance_pos($count) {
        for ( 1 .. $count ) {
            my $char = substr( $source, $pos++, 1 );
            if ( $char eq "\n" ) {
                $line++;
                $col = 1;
            }
            else {
                $col++;
            }
        }
    }
} 1;
