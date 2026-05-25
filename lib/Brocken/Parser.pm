use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::AST::ControlFlow;
use Brocken::AST::Expr;
use Brocken::AST::ControlFlow::SimpleStatement;
use Brocken::SymbolTable;
use Brocken::Type;

class Brocken::Parser {
    field $tokens : reader;
    field $pos                   = 0;
    field $mode : reader : param = 'modern';                      # 'modern' or 'perl'
    field $symbols : reader     = Brocken::SymbolTable->new();
    my %PRECEDENCE = ( '=' => 1, '||' => 2, '&&' => 3, '==' => 4, '!=' => 4, '<' => 5, '>' => 5, '+' => 10, '-' => 10, '*' => 20, '/' => 20, );

    # Simplified builtin registry
    my %BUILTINS = map { $_ => { arity => -1 } } qw(
        print say die warn return next last redo map grep sort abs chr hex oct ord reverse uc lc ucfirst eval
    );

    method parse($token_list) {
        $tokens = $token_list;
        $pos    = 0;
        my @statements;
        while ( $pos < @$tokens ) {
            push @statements, $self->parse_statement();
        }
        return \@statements;
    }

    method parse_attributes() {
        my @attributes;
        while ( $self->peek() && $self->peek()->type eq 'ATTRIBUTE' ) {
            push @attributes, Brocken::AST::Expr::Attribute->new( name => $self->consume('ATTRIBUTE')->value );
        }
        return @attributes;
    }

    method parse_statement() {
        my $token = $self->peek();
        my $stmt;
        if ( $token->type eq 'KEYWORD' && ( $token->value eq 'my' || $token->value eq 'our' || $token->value eq 'local' ) ) {
            $stmt = $self->parse_declaration();
        }
        elsif ( $token->type eq 'VARIABLE' ) {
            $stmt = $self->parse_assignment();
        }
        elsif ( $token->type eq 'KEYWORD' && $token->value eq 'sub' ) {
            return $self->parse_subroutine();
        }
        elsif ( $token->type eq 'KEYWORD' && $token->value eq 'if' ) {
            return $self->parse_if();
        }
        elsif ( $token->type eq 'KEYWORD' && $token->value eq 'elsif' ) {
            return $self->parse_if();
        }
        elsif ( $token->type eq 'KEYWORD' && $token->value eq 'unless' ) {
            return $self->parse_unless();
        }
        elsif ( $token->type eq 'KEYWORD' && ( $token->value eq 'for' || $token->value eq 'foreach' ) ) {
            return $self->parse_for();
        }
        elsif ( $token->type eq 'KEYWORD' && $token->value eq 'while' ) {
            return $self->parse_while();
        }
        elsif ( $token->type eq 'KEYWORD' && exists $BUILTINS{ $token->value } ) {
            $stmt = $self->parse_generic_builtin( $token->value );
        }
        elsif ( $token->type eq 'POD6_CMD' ) {
            return $self->parse_pod6();
        }
        else {
            die "Unexpected token at " .
                $token->file . ":" .
                $token->line . ":" .
                $token->column .
                " [Type: " .
                $token->type .
                ", Value: " .
                $token->value . "]";
        }

        # Check for postfix modifier
        if ( $self->peek() && $self->peek()->type eq 'KEYWORD' && $self->peek()->value =~ /^(if|unless|while|until)$/ ) {
            my $modifier = $self->consume('KEYWORD')->value;
            my $cond     = $self->parse_expression(0);
            if ( $modifier eq 'if' || $modifier eq 'unless' ) {
                return Brocken::AST::ControlFlow::IfStatement->new(
                    condition  => $cond,
                    then_block => Brocken::AST::ControlFlow::Block->new( statements => [$stmt], line => 0, column => 0 ),
                    line       => 0,
                    column     => 0
                );
            }
            else {
                return Brocken::AST::ControlFlow::WhileStatement->new(
                    condition  => $cond,
                    body_block => Brocken::AST::ControlFlow::Block->new( statements => [$stmt], line => 0, column => 0 ),
                    line       => 0,
                    column     => 0
                );
            }
        }

        # Optional semicolon for statements
        if ( $self->peek() && $self->peek()->type eq 'SEMICOLON' ) {
            $self->consume('SEMICOLON');
        }
        return $stmt;
    }

    method parse_declaration() {
        $self->consume('KEYWORD');
        my $type_name = 'Any';
        if ( $self->peek()->type eq 'IDENTIFIER' ) {
            $type_name = $self->consume('IDENTIFIER')->value;
            if ( $self->peek() && $self->peek()->type eq 'LBRACKET' ) {
                $self->consume('LBRACKET');
                my $inner_type = $self->consume('IDENTIFIER')->value;
                $self->consume('COMMA');
                my $width = $self->consume('NUMBER')->value;
                $self->consume('RBRACKET');
                $type_name = "$type_name\[$inner_type, $width\]";
            }
        }
        my $type = Brocken::Type::Registry::get_type($type_name) // Brocken::Type::Any->new(name => $type_name);
        
        my $var_token = $self->consume('VARIABLE');
        my @attributes = $self->parse_attributes();
        $symbols->define( $var_token->value, $type );
        if ( $self->peek() && $self->peek()->type eq 'OPERATOR' && $self->peek()->value eq '=' ) {
            $self->consume( 'OPERATOR', '=' );
            my $expr = $self->parse_expression(0);
            return Brocken::AST::ControlFlow::Assignment->new(
                variable   => Brocken::AST::Expr::Variable->new( name => $var_token->value, line => $var_token->line, column => $var_token->column ),
                value      => $expr,
                line       => $var_token->line,
                column     => $var_token->column,
                attributes => \@attributes,
            );
        }
        return Brocken::AST::ControlFlow::Assignment->new(
            variable   => Brocken::AST::Expr::Variable->new( name => $var_token->value, line => $var_token->line, column => $var_token->column ),
            value      => Brocken::AST::Expr::Literal->new( value => 'undef', line => $var_token->line, column => $var_token->column ),
            line       => $var_token->line,
            column     => $var_token->column,
            attributes => \@attributes,
        );
    }

    method parse_assignment() {
        my $var_token = $self->consume('VARIABLE');
        if ( $mode eq 'modern' && !$symbols->lookup( $var_token->value ) ) {
            die "Variable " . $var_token->value . " not declared at " . $var_token->to_string();
        }
        if ($mode eq 'perl' && !$symbols->lookup($var_token->value)) {
            $symbols->define($var_token->value, Brocken::Type::Registry::get_type('Any'));
        }
        $self->consume( 'OPERATOR', '=' );
        my $expr = $self->parse_expression(0);
        return Brocken::AST::ControlFlow::Assignment->new(
            variable   => Brocken::AST::Expr::Variable->new( name => $var_token->value, line => $var_token->line, column => $var_token->column ),
            value      => $expr,
            line       => $var_token->line,
            column     => $var_token->column,
            attributes => [],
        );
    }

    method parse_builtin_call_no_consume($name) {
        $self->consume( 'KEYWORD', $name );

        my @args;
        if ( $self->peek() && $self->peek()->type eq 'LPAREN' ) {
            $self->consume('LPAREN');
            while ( $self->peek() && $self->peek()->type ne 'RPAREN' ) {
                push @args, $self->parse_expression(0);
                if ( $self->peek() && $self->peek()->type eq 'COMMA' ) {
                    $self->consume('COMMA');
                }
            }
            $self->consume('RPAREN');
        }
        return Brocken::AST::Expr::BuiltinCall->new( name => $name, args => \@args );
    }

    method parse_generic_builtin($name) {
        $self->consume( 'KEYWORD', $name );

        if ($name eq 'eval') {
            $self->consume('LPAREN');
            my $str = $self->consume('STRING');
            $self->consume('RPAREN');
            return Brocken::AST::ControlFlow::SimpleStatement->new( keyword => 'eval', args => [ Brocken::AST::Expr::Literal->new(value => $str->value, line => $str->line, column => $str->column) ] );
        }

        my @args;
        if ( $self->peek() && $self->peek()->type eq 'LPAREN' ) {
            $self->consume('LPAREN');
            while ( $self->peek() && $self->peek()->type ne 'RPAREN' ) {
                push @args, $self->parse_expression(0);
                if ( $self->peek() && $self->peek()->type eq 'COMMA' ) {
                    $self->consume('COMMA');
                }
            }
            $self->consume('RPAREN');
        }
        else {
            while ( $self->peek() && $self->peek()->type ne 'SEMICOLON' && $self->peek()->type ne 'KEYWORD' ) {
                push @args, $self->parse_expression(0);
                if ( $self->peek() && $self->peek()->type eq 'COMMA' ) {
                    $self->consume('COMMA');
                }
            }
        }
        return Brocken::AST::ControlFlow::SimpleStatement->new( keyword => $name, args => \@args );
    }

    method parse_subroutine() {
        $self->consume( 'KEYWORD', 'sub' );
        my $name       = $self->consume('IDENTIFIER')->value;
        my $attributes = [ $self->parse_attributes() ];
        my $body       = $self->parse_block();
        return Brocken::AST::ControlFlow::Subroutine->new( name => $name, body => $body, attributes => $attributes );
    }

    method parse_unless() {
        $self->consume( 'KEYWORD', 'unless' );
        $self->consume('LPAREN');
        my $condition = $self->parse_expression(0);
        $self->consume('RPAREN');
        my $then_block = $self->parse_block();
        return Brocken::AST::ControlFlow::IfStatement->new(
            condition  => Brocken::AST::Expr::UnaryOp->new(
                operator => '!',
                expr     => $condition,
                line     => $condition->line,
                column   => $condition->column
            ),
            then_block => $then_block,
            line       => $condition->line,
            column     => $condition->column,
        );
    }

    method parse_for() {
        $self->consume('KEYWORD');
        $self->consume('LPAREN');
        # TODO: Full for(my $i=0; $i<10; $i++) parsing
        my $expr = $self->parse_expression(0);
        $self->consume('RPAREN');
        my $body_block = $self->parse_block();
        return Brocken::AST::ControlFlow::WhileStatement->new(
            condition  => $expr,
            body_block => $body_block,
            line       => $expr->line,
            column     => $expr->column,
        );
    }

    method parse_if() {
        my $kw = $self->consume('KEYWORD')->value;
        die "Expected if or elsif but got $kw" unless $kw eq 'if' || $kw eq 'elsif';
        $self->consume('LPAREN');
        my $condition = $self->parse_expression(0);
        $self->consume('RPAREN');
        my $then_block = $self->parse_block();
        my $else_block;
        if ( $self->peek() && $self->peek()->type eq 'KEYWORD' && $self->peek()->value eq 'elsif' ) {
            my $peek = $self->peek();
            $else_block = Brocken::AST::ControlFlow::Block->new(
                statements => [ $self->parse_if() ],
                line       => $peek->line,
                column     => $peek->column
            );
        }
        elsif ( $self->peek() && $self->peek()->type eq 'KEYWORD' && $self->peek()->value eq 'else' ) {
            $self->consume( 'KEYWORD', 'else' );
            $else_block = $self->parse_block();
        }
        return Brocken::AST::ControlFlow::IfStatement->new(
            condition  => $condition,
            then_block => $then_block,
            else_block => $else_block,
            line       => $condition->line,
            column     => $condition->column,
        );
    }

    method parse_while() {
        $self->consume( 'KEYWORD', 'while' );
        $self->consume('LPAREN');
        my $condition = $self->parse_expression(0);
        $self->consume('RPAREN');
        my $body_block = $self->parse_block();
        return Brocken::AST::ControlFlow::WhileStatement->new(
            condition  => $condition,
            body_block => $body_block,
            line       => $condition->line,
            column     => $condition->column,
        );
    }

    method parse_block() {
        $symbols->push_scope();
        $self->consume('LBRACE');
        my @statements;
        while ( $self->peek() && $self->peek()->type ne 'RBRACE' ) {
            push @statements, $self->parse_statement();
        }
        $self->consume('RBRACE');
        $symbols->pop_scope();
        return Brocken::AST::ControlFlow::Block->new( statements => \@statements, line => 0, column => 0 );
    }

    method parse_pod6() {
        my $token = $self->consume('POD6_CMD');
        return Brocken::AST::Pod6::Para->new( content => $token->value, line => $token->line, column => $token->column );
    }

    method parse_expression($min_precedence) {
        my $left = $self->parse_primary();
        while ( my $token = $self->peek() ) {
            last if $token->type ne 'OPERATOR';
            my $precedence = $PRECEDENCE{ $token->value } // 0;
            last if $precedence < $min_precedence;
            my $op    = $self->consume('OPERATOR')->value;
            my $right = $self->parse_expression( $precedence + 1 );
            $left = Brocken::AST::Expr::BinaryOp->new( left => $left, operator => $op, right => $right );
        }
        return $left;
    }

    method parse_primary() {
        my $token = $self->peek();
        if ( $token->type eq 'VARIABLE' ) {
            $self->consume();
            if ( $mode eq 'modern' && !$symbols->lookup( $token->value ) ) {
                die "Variable " . $token->value . " not declared at " . $token->to_string();
            }
            # Always define if it doesn't exist to avoid subsequent lookup errors in perl mode
            if ($mode eq 'perl' && !$symbols->lookup($token->value)) {
                $symbols->define($token->value, Brocken::Type::Registry::get_type('Any'));
            }
            return Brocken::AST::Expr::Variable->new( name => $token->value, line => $token->line, column => $token->column );
        }
        if ( $token->type eq 'NUMBER' ) {
            $self->consume();
            return Brocken::AST::Expr::Literal->new( value => $token->value, line => $token->line, column => $token->column );
        }
        if ( $token->type eq 'KEYWORD' && exists $BUILTINS{ $token->value } ) {
            return $self->parse_builtin_call_no_consume( $token->value );
        }
        if ( $token->type eq 'LPAREN' ) {
            $self->consume();
            my $expr = $self->parse_expression(0);
            $self->consume('RPAREN');
            return $expr;
        }
        die "Unexpected primary token: " . $token->to_string();
    }

    method peek() { return $tokens->[$pos]; }

    method consume( $type = undef, $value = undef ) {
        my $token = $tokens->[ $pos++ ];
        if ( !$token || ( defined $type && $token->type ne $type ) || ( defined $value && $token->value ne $value ) ) {
            die "Expected " . ( $type // 'any' ) . ( defined $value ? " ($value)" : "" ) . " but got " . ( $token ? $token->to_string() : "EOF" );
        }
        return $token;
    }
}
1;
