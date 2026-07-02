use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::AST;
use Carp ();

class Brocken::Katsuro::Parser {
    field $tokens   : param;
    field $filename : param = '';
    field $pos      : param = 0;
    field $features = {};

    # Precedence constants
    use constant {
        PREC_LOWEST  => 0,
        PREC_ASSIGN  => 10,
        PREC_OR      => 15,
        PREC_AND     => 17,
        PREC_COMPARE => 20,
        PREC_SHIFT   => 25,
        PREC_SUM     => 30,
        PREC_PRODUCT => 40,
        PREC_UNARY   => 50,
        PREC_CALL    => 60,
        PREC_DEREF   => 65,
    };
    my %TYPE_KEYWORDS = map { $_ => 1 } qw(Int String Any Bool ptr int bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64);
    my %FEATURE_TYPES = ( i128 => 'brocken_native_types', u128 => 'brocken_native_types' );
    method peek()    { $tokens->[$pos] }
    method prev()    { $tokens->[ $pos - 1 ] }
    method advance() { $tokens->[ $pos++ ] }

    method _pos_token( $token = undef ) {
        $token //= $self->prev();
        return ( file => $filename, line => ( $token->{line} // 0 ), col => ( $token->{col} // 0 ) );
    }

    method check( $type, $value = undef ) {
        my $t = $self->peek();
        return 0 unless $t;
        return 0 unless $t->{type} eq $type;
        return 1 if !defined $value;
        return $t->{value} eq $value;
    }

    method _loc( $t = undef ) {
        $t //= $self->peek();
        return $t ? "$filename line $t->{line}, col $t->{col}" : 'end of input';
    }

    method consume( $type, $value = undef, $msg = undef ) {
        my $t = $self->peek();
        if ( !$msg ) {
            my $got = $t ? $t->{type} . " '" . $t->{value} . "'" : 'EOF';
            $msg = "Expected $type" . ( defined $value ? " '$value'" : '' ) . ", got $got at " . $self->_loc($t);
        }
        if ( !$t || $t->{type} ne $type || ( defined $value && $t->{value} ne $value ) ) {
            Carp::croak($msg);
        }
        return $self->advance();
    }

    method is_type($token) {
        return 0 unless $token && $token->{type} eq 'KEYWORD' && exists $TYPE_KEYWORDS{ $token->{value} };
        my $needs_feature = $FEATURE_TYPES{ $token->{value} };
        return $needs_feature ? ( $features->{$needs_feature} || 0 ) : 1;
    }

    # === Top level ===
    method parse_program() {
        my @stmts;
        while ( !$self->check('EOF') ) {
            my $stmt = $self->parse_decl_or_stmt();
            push @stmts, $stmt if defined $stmt;
        }
        return Brocken::Katsuro::AST::Program->new( $self->_pos_token( $tokens->[0] // $stmts[0] ), statements => \@stmts );
    }

    method parse_decl_or_stmt() {
        return $self->parse_class_decl() if $self->check( 'KEYWORD', 'class' );
        return $self->parse_sub_decl()   if $self->check( 'KEYWORD', 'sub' );
        return $self->parse_statement();
    }

    # === Statements ===
    method parse_statement() {
        if ( $self->check( 'KEYWORD', 'use' ) ) {
            $self->advance();
            my $feat = $self->consume( 'IDENT', undef, "Expected 'feature' after 'use'" );
            Carp::croak("Expected 'feature', got '$feat->{value}'") unless $feat->{value} eq 'feature';
            my $name_tok = $self->consume( 'STRING', undef, "Expected feature name string after 'use feature'" );
            $self->consume( ';', undef, "Expected ';' after use feature" );
            $features->{ $name_tok->{value} } = 1;
            return undef;
        }
        return $self->parse_var_decl() if $self->check( 'KEYWORD', 'my' );
        return $self->parse_if()       if $self->check( 'KEYWORD', 'if' );
        return $self->parse_while()    if $self->check( 'KEYWORD', 'while' );
        return $self->parse_return()   if $self->check( 'KEYWORD', 'return' );
        if ( $self->check( 'KEYWORD', 'say' ) || $self->check( 'KEYWORD', 'print' ) ) {
            return $self->parse_builtin_print();
        }
        if ( $self->check(';') ) {
            $self->advance();
            return undef;
        }
        my $expr = $self->parse_expression(0);
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
            Carp::croak( "Unexpected bare identifier '" . $expr->name . "' at " . $self->_loc() . ' -- did you forget parentheses?' );
        }
        if ( $self->check( 'OP', '=' ) || $self->check( 'OP', '//=' ) ) {
            my $op_tok = $self->advance();
            my $rhs    = $self->parse_expression(0);
            $self->consume( ';', undef, "Expected ';' after assignment" );
            return Brocken::Katsuro::AST::Stmt::Assign->new( $self->_pos_token($op_tok), target => $expr, expr => $rhs );
        }
        $self->consume( ';', undef, "Expected ';' after expression" );
        return $expr;
    }

    method parse_var_decl() {
        $self->advance();
        if ( $self->check('[') ) {
            return $self->parse_array_decl();
        }
        my $type = 'Any';
        if ( $self->is_type( $self->peek() ) ) {
            $type = $self->advance()->{value};
        }
        my $var_token = $self->consume( 'VAR', undef, "Expected variable name after 'my'" );
        my $sigil     = substr( $var_token->{value}, 0, 1 );
        my $name      = substr( $var_token->{value}, 1 );
        my $init      = undef;
        if ( $self->check( 'OP', '=' ) ) {
            $self->advance();
            $init = $self->parse_expression(0);
        }
        $self->consume( ';', undef, "Expected ';' after variable declaration" );
        return Brocken::Katsuro::AST::Stmt::VarDecl->new( $self->_pos_token($var_token), sigil => $sigil, name => $name, type => $type,
            init => $init );
    }

    method parse_array_decl() {
        $self->consume('[');
        my $elem_type = 'Any';
        if ( $self->is_type( $self->peek() ) ) {
            $elem_type = $self->advance()->{value};
        }
        my $size_expr = undef;
        if ( $self->check(';') ) {
            $self->advance();
            $size_expr = $self->parse_expression(0);
        }
        $self->consume(']');
        my $var_token = $self->consume( 'VAR', undef, "Expected array variable name" );
        my $sigil     = substr( $var_token->{value}, 0, 1 );
        my $name      = substr( $var_token->{value}, 1 );
        my $init      = undef;
        if ( $self->check( 'OP', '=' ) ) {
            $self->advance();
            $init = $self->parse_expression(0);
        }
        $self->consume( ';', undef, "Expected ';' after array declaration" );
        return Brocken::Katsuro::AST::Stmt::ArrayDecl->new(
            $self->_pos_token($var_token),
            name      => $name,
            elem_type => $elem_type,
            size_expr => $size_expr,
            init      => $init,
        );
    }

    method parse_if() {
        my $if_token = $self->advance();
        $self->consume('(');
        my $cond = $self->parse_expression(0);
        $self->consume(')');
        my $then = $self->parse_block();
        my @elsif;
        my $else = undef;
        while ( $self->check( 'KEYWORD', 'elsif' ) ) {
            $self->advance();
            $self->consume('(');
            my $e_cond = $self->parse_expression(0);
            $self->consume(')');
            my $e_body = $self->parse_block();
            push @elsif, [ $e_cond, $e_body ];
        }
        if ( $self->check( 'KEYWORD', 'else' ) ) {
            $self->advance();
            $else = $self->parse_block();
        }
        return Brocken::Katsuro::AST::Stmt::If->new( $self->_pos_token($if_token), cond => $cond, then => $then, elsif => \@elsif, else => $else );
    }

    method parse_while() {
        my $while_token = $self->advance();
        $self->consume('(');
        my $cond = $self->parse_expression(0);
        $self->consume(')');
        my $body = $self->parse_block();
        return Brocken::Katsuro::AST::Stmt::While->new( $self->_pos_token($while_token), cond => $cond, body => $body );
    }

    method parse_return() {
        my $ret_token = $self->advance();
        my $expr      = undef;
        unless ( $self->check(';') ) {
            $expr = $self->parse_expression(0);
        }
        $self->consume( ';', undef, "Expected ';' after return" );
        return Brocken::Katsuro::AST::Stmt::Return->new( $self->_pos_token($ret_token), expr => $expr );
    }

    method parse_builtin_print() {
        my $tok  = $self->advance();
        my $name = $tok->{value};
        $self->consume('(');
        my $args = $self->parse_call_args_after_paren();
        $self->consume( ';', undef, "Expected ';' after $name()" );
        return Brocken::Katsuro::AST::Expr::Call->new( $self->_pos_token($tok), func_name => $name, args => $args );
    }

    method parse_block() {
        my $brace_token = $self->consume('{');
        my @stmts;
        until ( $self->check('}') || $self->check('EOF') ) {
            my $stmt = $self->parse_statement();
            push @stmts, $stmt if defined $stmt;
        }
        $self->consume('}');
        return Brocken::Katsuro::AST::Stmt::Block->new( $self->_pos_token($brace_token), statements => \@stmts );
    }

    # === Sub declarations ===
    method parse_sub_decl() {
        my $sub_token  = $self->advance();
        my $name_token = $self->consume( 'IDENT', undef, "Expected subroutine name after 'sub'" );
        $self->consume('(');
        my @params;
        until ( $self->check(')') || $self->check('EOF') ) {
            if (@params) {
                $self->consume(',');
                last if $self->check(')');
            }
            my $ptype = 'Any';
            if ( $self->is_type( $self->peek() ) ) {
                $ptype = $self->advance()->{value};
            }
            my $var_token = $self->consume( 'VAR', undef, "Expected parameter variable" );
            my $psigil    = substr( $var_token->{value}, 0, 1 );
            my $pname     = substr( $var_token->{value}, 1 );
            push @params, { type => $ptype, sigil => $psigil, name => $pname };
        }
        $self->consume(')');
        my $return_type = 'void';
        if ( $self->check( 'OP', '->' ) ) {
            $self->advance();
            if ( $self->is_type( $self->peek() ) ) {
                $return_type = $self->advance()->{value};
            }
            else {
                my $t = $self->consume( 'IDENT', undef, "Expected return type after '->'" );
                $return_type = $t->{value};
            }
        }
        if ( $self->check(';') ) {
            $self->advance();
            return Brocken::Katsuro::AST::Stmt::SubDecl->new(
                $self->_pos_token($sub_token),
                name        => $name_token->{value},
                params      => \@params,
                return_type => $return_type,
                body        => Brocken::Katsuro::AST::Stmt::Block->new( statements => [] ),
            );
        }
        my $body = $self->parse_block();
        return Brocken::Katsuro::AST::Stmt::SubDecl->new(
            $self->_pos_token($sub_token),
            name        => $name_token->{value},
            params      => \@params,
            return_type => $return_type,
            body        => $body,
        );
    }

    # === Class declarations ===
    method parse_class_decl() {
        my $class_token = $self->advance();
        my $name_token  = $self->consume( 'IDENT', undef, "Expected class name after 'class'" );
        $self->consume('{');
        my @fields;
        my @methods;
        my $adjust = undef;
        until ( $self->check('}') || $self->check('EOF') ) {
            if ( $self->check( 'KEYWORD', 'field' ) ) {
                push @fields, $self->parse_field_decl();
            }
            elsif ( $self->check( 'KEYWORD', 'method' ) ) {
                push @methods, $self->parse_method_decl();
            }
            elsif ( $self->check( 'KEYWORD', 'ADJUST' ) ) {
                my $adjust_tok = $self->advance();
                $adjust = Brocken::Katsuro::AST::Stmt::Adjust->new( $self->_pos_token($adjust_tok), body => $self->parse_block() );
            }
            else {
                my $t = $self->peek();
                Carp::croak("Expected 'field', 'method', or 'ADJUST' in class body, got $t->{type} '$t->{value}' at line $t->{line}, col $t->{col}");
            }
        }
        $self->consume('}');
        return Brocken::Katsuro::AST::Stmt::ClassDecl->new(
            $self->_pos_token($class_token),
            name    => $name_token->{value},
            fields  => \@fields,
            methods => \@methods,
            adjust  => $adjust,
        );
    }

    method parse_field_decl() {
        my $field_tok = $self->advance();    # consume 'field'
        my $ft        = $self->peek();
        Carp::croak("Expected field type, got $ft->{type} '$ft->{value}' at line $ft->{line}, col $ft->{col}") unless $self->is_type($ft);
        my $ftype      = $self->advance()->{value};
        my $fvar_token = $self->consume( 'VAR', undef, "Expected field name" );
        my $fname      = substr( $fvar_token->{value}, 1 );
        my @attrs;
        while ( $self->check( 'OP', ':' ) ) {
            $self->advance();
            my $attr_token = $self->consume( 'IDENT', undef, "Expected attribute name after ':'" );
            push @attrs, $attr_token->{value};
        }
        my $default    = undef;
        my $default_op = undef;
        if ( $self->check( 'OP', '=' ) || $self->check( 'OP', '//=' ) ) {
            $default_op = $self->advance()->{value};
            $default    = $self->parse_expression(0);
        }
        $self->consume(';');
        return Brocken::Katsuro::AST::Stmt::FieldDecl->new(
            $self->_pos_token($field_tok),
            type       => $ftype,
            name       => $fname,
            attrs      => \@attrs,
            default    => $default,
            default_op => $default_op,
        );
    }

    method parse_method_decl() {
        my $method_tok = $self->advance();                                                          # consume 'method'
        my $name_token = $self->consume( 'IDENT', undef, "Expected method name after 'method'" );
        $self->consume('(');
        my @params;
        until ( $self->check(')') || $self->check('EOF') ) {
            if (@params) {
                $self->consume(',');
                last if $self->check(')');
            }
            my $ptype = 'Any';
            if ( $self->is_type( $self->peek() ) ) {
                $ptype = $self->advance()->{value};
            }
            my $var_token = $self->consume( 'VAR', undef, "Expected parameter variable" );
            my $psigil    = substr( $var_token->{value}, 0, 1 );
            my $pname     = substr( $var_token->{value}, 1 );
            push @params, { type => $ptype, sigil => $psigil, name => $pname };
        }
        $self->consume(')');
        my $return_type = 'void';
        if ( $self->check( 'OP', '->' ) ) {
            $self->advance();
            if ( $self->is_type( $self->peek() ) ) {
                $return_type = $self->advance()->{value};
            }
            else {
                my $t = $self->consume( 'IDENT', undef, "Expected return type after '->'" );
                $return_type = $t->{value};
            }
        }
        my $body = $self->parse_block();
        return Brocken::Katsuro::AST::Stmt::MethodDecl->new(
            $self->_pos_token($method_tok),
            name        => $name_token->{value},
            params      => \@params,
            return_type => $return_type,
            body        => $body,
        );
    }

    # === Expressions (Pratt Parser) ===
    method parse_expression($precedence) {
        my $token = $self->advance();
        my $left  = $self->nud($token);
        while ( $precedence < $self->get_precedence( $self->peek() ) ) {
            $token = $self->advance();
            $left  = $self->led( $left, $token );
        }
        return $left;
    }

    method nud($token) {
        if ( $token->{type} eq 'NUM' ) {
            return Brocken::Katsuro::AST::Expr::Const->new( $self->_pos_token($token), value => $token->{value}, type => 'Int' );
        }
        if ( $token->{type} eq 'STRING' ) {
            return Brocken::Katsuro::AST::Expr::Const->new( $self->_pos_token($token), value => $token->{value}, type => 'String' );
        }
        if ( $token->{type} eq 'VAR' ) {
            my $sigil = substr( $token->{value}, 0, 1 );
            my $name  = substr( $token->{value}, 1 );
            return Brocken::Katsuro::AST::Expr::Var->new( $self->_pos_token($token), sigil => $sigil, name => $name );
        }
        if ( $token->{type} eq 'IDENT' ) {
            return Brocken::Katsuro::AST::Expr::Ident->new( $self->_pos_token($token), name => $token->{value} );
        }
        if ( $token->{type} eq '(' ) {
            my $expr = $self->parse_expression(0);
            $self->consume(')');
            return Brocken::Katsuro::AST::Expr::Paren->new( $self->_pos_token($token), expr => $expr );
        }
        if ( $token->{type} eq 'KEYWORD' ) {
            return Brocken::Katsuro::AST::Expr::Const->new( $self->_pos_token($token), value => 1, type => 'Bool' ) if $token->{value} =~ /^true$/i;
            return Brocken::Katsuro::AST::Expr::Const->new( $self->_pos_token($token), value => 0, type => 'Bool' ) if $token->{value} =~ /^false$/i;
            return Brocken::Katsuro::AST::Expr::ClassConst->new( $self->_pos_token($token) ) if $token->{value} eq '__CLASS__';
            Carp::croak( "Unexpected keyword '$token->{value}' in expression at " . $self->_loc($token) );
        }
        if ( $token->{type} eq 'OP' ) {
            if ( $token->{value} eq '-' ) {
                return Brocken::Katsuro::AST::Expr::UnOp->new( $self->_pos_token($token), op => '-', expr => $self->parse_expression(PREC_UNARY) );
            }
            if ( $token->{value} eq '!' ) {
                return Brocken::Katsuro::AST::Expr::UnOp->new( $self->_pos_token($token), op => '!', expr => $self->parse_expression(PREC_UNARY) );
            }
        }
        Carp::croak( "Unexpected token $token->{type} '$token->{value}' in expression at " . $self->_loc($token) );
    }

    method led( $left, $token ) {
        if ( $token->{type} eq 'OP' ) {
            my $op = $token->{value};
            if ( $op eq '=' || $op eq '//=' ) {
                my $right = $self->parse_expression( PREC_ASSIGN - 1 );
                return Brocken::Katsuro::AST::Stmt::Assign->new( $self->_pos_token($token), target => $left, expr => $right, op => $op );
            }
            if ( $op eq '->' ) {
                my $ident = $self->consume( 'IDENT', undef, "Expected field or method name after '->'" );
                if ( $self->check('(') ) {
                    $self->advance();
                    my $args = $self->parse_call_args_after_paren();
                    return Brocken::Katsuro::AST::Expr::MethodCall->new(
                        $self->_pos_token($token),
                        obj    => $left,
                        method => $ident->{value},
                        args   => $args,
                    );
                }
                else {
                    return Brocken::Katsuro::AST::Expr::FieldAccess->new( $self->_pos_token($token), obj => $left, field => $ident->{value} );
                }
            }
            if ( $op eq '||' ) {
                return Brocken::Katsuro::AST::Expr::BinOp->new(
                    $self->_pos_token($token),
                    op  => $op,
                    lhs => $left,
                    rhs => $self->parse_expression(PREC_OR)
                );
            }
            if ( $op eq '&&' ) {
                return Brocken::Katsuro::AST::Expr::BinOp->new(
                    $self->_pos_token($token),
                    op  => $op,
                    lhs => $left,
                    rhs => $self->parse_expression(PREC_AND)
                );
            }
            if ( $op eq '==' || $op eq '!=' || $op eq '<' || $op eq '>' || $op eq '<=' || $op eq '>=' ) {
                return Brocken::Katsuro::AST::Expr::BinOp->new(
                    $self->_pos_token($token),
                    op  => $op,
                    lhs => $left,
                    rhs => $self->parse_expression(PREC_COMPARE)
                );
            }
            if ( $op eq '<<' || $op eq '>>' ) {
                return Brocken::Katsuro::AST::Expr::BinOp->new(
                    $self->_pos_token($token),
                    op  => $op,
                    lhs => $left,
                    rhs => $self->parse_expression(PREC_SHIFT)
                );
            }
            if ( $op eq '+' || $op eq '-' ) {
                return Brocken::Katsuro::AST::Expr::BinOp->new(
                    $self->_pos_token($token),
                    op  => $op,
                    lhs => $left,
                    rhs => $self->parse_expression(PREC_SUM)
                );
            }
            if ( $op eq '*' || $op eq '/' || $op eq '%' ) {
                return Brocken::Katsuro::AST::Expr::BinOp->new(
                    $self->_pos_token($token),
                    op  => $op,
                    lhs => $left,
                    rhs => $self->parse_expression(PREC_PRODUCT)
                );
            }
            Carp::croak( "Unknown operator '$op' at " . $self->_loc($token) );
        }
        if ( $token->{type} eq '[' ) {
            my $index = $self->parse_expression(0);
            $self->consume(']');
            return Brocken::Katsuro::AST::Expr::ArrayIndex->new( $self->_pos_token($token), array => $left, index => $index );
        }
        if ( $token->{type} eq '(' ) {
            my $name;
            if ( $left->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
                $name = $left->name;
            }
            else {
                Carp::croak( "Only identifiers can be called as functions at " . $self->_loc($token) );
            }
            my $args = $self->parse_call_args_after_paren();
            if ( $name =~ /^Brocken::([^:]+)$/ ) {
                return Brocken::Katsuro::AST::Expr::IntrinsicCall->new( $self->_pos_token($token), name => $1, args => $args );
            }
            return Brocken::Katsuro::AST::Expr::Call->new( $self->_pos_token($token), func_name => $name, args => $args );
        }
        Carp::croak( "Unexpected token $token->{type} '$token->{value}' after expression at " . $self->_loc($token) );
    }

    method parse_call_args_after_paren() {
        my @args;
        until ( $self->check(')') || $self->check('EOF') ) {
            if (@args) {
                $self->consume(',');
                last if $self->check(')');
            }
            push @args, $self->parse_expression(0);
        }
        $self->consume(')');
        return \@args;
    }

    method get_precedence($token) {
        return 0 unless $token;
        if ( $token->{type} eq 'OP' ) {
            my $op = $token->{value};
            return PREC_ASSIGN  if $op eq '=' || $op eq '//=';
            return PREC_DEREF   if $op eq '->';
            return PREC_OR      if $op eq '||';
            return PREC_AND     if $op eq '&&';
            return PREC_COMPARE if $op eq '==' || $op eq '!=' || $op eq '<' || $op eq '>' || $op eq '<=' || $op eq '>=';
            return PREC_SHIFT   if $op eq '<<' || $op eq '>>';
            return PREC_SUM     if $op eq '+'  || $op eq '-';
            return PREC_PRODUCT if $op eq '*'  || $op eq '/' || $op eq '%';
            return 0;
        }
        return PREC_DEREF if $token->{type} eq '[';
        return PREC_CALL  if $token->{type} eq '(';
        return 0;
    }
}
1;
