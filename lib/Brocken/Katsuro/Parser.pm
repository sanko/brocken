use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
#
class Brocken::Katsuro::Parser v0.0.1 {
    use Brocken::Katsuro::AST;
    use Carp ();
    field $tokens   : param;
    field $filename : param = '';
    field $pos      : param = 0;
    field $features        = {};
    field $current_package = undef;    # namespace from a `package NAME` declaration; stamped onto following nodes

    # Precedence constants
    use constant {
        PREC_LOWEST  => 0,
        PREC_ASSIGN  => 10,
        PREC_TERNARY => 12,
        PREC_OR      => 15,
        PREC_AND     => 17,
        PREC_BITOR   => 18,
        PREC_BITXOR  => 19,
        PREC_BITAND  => 20,
        PREC_COMPARE => 25,
        PREC_SHIFT   => 30,
        PREC_SUM     => 35,
        PREC_PRODUCT => 45,
        PREC_UNARY   => 55,
        PREC_CALL    => 60,
        PREC_DEREF   => 65
    };
    my %TYPE_KEYWORDS = map { $_ => 1 } qw[Int String Any Bool ptr int bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64];
    my %FEATURE_TYPES = ( i128 => 'brocken_native_types', u128 => 'brocken_native_types' );

    # Assignment operators. `=` and the short-circuit forms keep their own lowering; the arithmetic/bitwise/string
    # compound forms (`$x += 1`) parse as `$x = $x OP 1`, so they reuse the ordinary `=` lowering and its reference
    # counting. The target sub-expressions are re-evaluated once (a `%map{key}` key is computed twice).
    my %ASSIGN_OPS = map { $_ => 1 } qw[= += -= *= /= %= &= |= ^= <<= >>= .= //= ||=];
    my %COMPOUND_ASSIGN = map { $_ => 1 } qw[+= -= *= /= %= &= |= ^= <<= >>= .=];
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
        return $self->parse_class_decl()   if $self->check( 'KEYWORD', 'class' );
        return $self->parse_sub_decl()     if $self->check( 'KEYWORD', 'sub' );
        return $self->parse_package_decl() if $self->check( 'KEYWORD', 'package' );
        return $self->parse_statement();
    }

    # `package NAME;` sets the namespace for later declarations in the same scope; `package NAME { ... }` scopes it to
    # the block. Either way the parser stamps its `$current_package` onto every node it builds, so the lowerer never has
    # to replay a package declaration.
    method parse_package_decl() {
        my $pkg_token  = $self->advance();
        my $name_token = $self->consume( 'IDENT', undef, "Expected package name after 'package'" );
        my $name       = $name_token->{value};
        my $version;
        if ( $self->check('VERSION') || $self->check('FLOAT') || $self->check('NUM') ) {
            $version = $self->advance()->{value};
        }
        if ( $self->check('{') ) {
            my $saved = $current_package;
            $current_package = $name;
            my $body = $self->parse_package_block();
            $current_package = $saved;
            return Brocken::Katsuro::AST::Stmt::PackageDecl->new( $self->_pos_token($pkg_token), name => $name, version => $version, body => $body );
        }
        $self->consume( ';', undef, "Expected ';' or '{' after 'package $name'" );
        $current_package = $name;
        return Brocken::Katsuro::AST::Stmt::PackageDecl->new( $self->_pos_token($pkg_token), name => $name, version => $version );
    }

    # A package block is a declaration scope, like the program itself: it holds sub/class/package declarations as well
    # as loose statements, so it is parsed with parse_decl_or_stmt rather than the statement-only parse_block.
    method parse_package_block() {
        my $brace_token = $self->consume('{');
        my @stmts;
        until ( $self->check('}') || $self->check('EOF') ) {
            my $stmt = $self->parse_decl_or_stmt();
            push @stmts, $stmt if defined $stmt;
        }
        $self->consume('}');
        return Brocken::Katsuro::AST::Stmt::Block->new( $self->_pos_token($brace_token), statements => \@stmts );
    }

    # === Statements ===
    # Every statement is stamped with the package in effect where it was written, so the lowerer can resolve an
    # unqualified name through the enclosing `package NAME` without replaying the declarations.
    method parse_statement() {
        my $stmt = $self->_parse_statement();
        $stmt->set_package($current_package) if defined $stmt;
        return $stmt;
    }

    method _parse_statement() {
        if ( $self->check( 'KEYWORD', 'use' ) ) {
            $self->advance();
            my $feat = $self->consume( 'IDENT', undef, "Expected 'feature' after 'use'" );
            Carp::croak("Expected 'feature', got '$feat->{value}'") unless $feat->{value} eq 'feature';
            my $name_tok = $self->consume( 'STRING', undef, "Expected feature name string after 'use feature'" );
            $self->consume( ';', undef, "Expected ';' after use feature" );
            $features->{ $name_tok->{value} } = 1;
            return undef;
        }
        return $self->parse_var_decl()     if $self->check( 'KEYWORD', 'my' );
        return $self->parse_if()           if $self->check( 'KEYWORD', 'if' );
        return $self->parse_while()        if $self->check( 'KEYWORD', 'while' );
        return $self->parse_for()          if $self->check( 'KEYWORD', 'for' ) || $self->check( 'KEYWORD', 'foreach' );
        return $self->parse_return()       if $self->check( 'KEYWORD', 'return' );
        return $self->parse_throw()        if $self->check( 'KEYWORD', 'throw' );
        return $self->parse_exit()         if $self->check( 'KEYWORD', 'exit' );
        return $self->parse_trycatch()     if $self->check( 'KEYWORD', 'try' );
        return $self->parse_loop_control() if $self->check( 'KEYWORD', 'last' ) || $self->check( 'KEYWORD', 'next' );

        if ( $self->check( 'KEYWORD', 'say' ) || $self->check( 'KEYWORD', 'print' ) ) {
            return $self->parse_builtin_print();
        }
        if ( $self->check(';') ) {
            $self->advance();
            return undef;
        }
        return $self->parse_block() if $self->check('{');
        my $expr = $self->parse_expression(0);
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
            Carp::croak( "Unexpected bare identifier '" . $expr->name . "' at " . $self->_loc() . ' -- did you forget parentheses?' );
        }
        my $assign_tok = $self->peek();
        if ( $assign_tok && $assign_tok->{type} eq 'OP' && $ASSIGN_OPS{ $assign_tok->{value} } ) {
            my $op_tok = $self->advance();
            my $rhs    = $self->parse_expression(0);
            my $assign = Brocken::Katsuro::AST::Stmt::Assign->new( $self->_pos_token($op_tok), target => $expr, expr => $rhs, op => $op_tok->{value} );
            return $self->_end_statement( $assign, "Expected ';' after assignment" );
        }
        return $self->_end_statement( $expr, "Expected ';' after expression" );
    }

    # Finish a simple statement. Normally that is just consuming the `;`; but when a postfix `if`/`unless` modifier
    # follows (`return 0 if $cond;`, `next unless $skip;`) the statement becomes the body of a one-statement `if`.
    # `unless COND { BODY }` runs the body when COND is false, which is an `if` whose then-branch is empty and whose
    # else-branch is the statement. Only simple statements take a modifier -- a compound statement needs no `;`, so an
    # `if` after one is a new statement, not a modifier.
    method _end_statement( $stmt, $what ) {
        if ( $self->check( 'KEYWORD', 'if' ) || $self->check( 'KEYWORD', 'unless' ) ) {
            my $modifier = $self->advance();
            $stmt->set_package($current_package);
            my $cond     = $self->parse_expression(0);
            $self->consume( ';', undef, "Expected ';' after postfix $modifier->{value}" );
            my $body = Brocken::Katsuro::AST::Stmt::Block->new( $self->_pos_token($modifier), statements => [$stmt] );
            if ( $modifier->{value} eq 'unless' ) {
                my $empty = Brocken::Katsuro::AST::Stmt::Block->new( $self->_pos_token($modifier), statements => [] );
                return Brocken::Katsuro::AST::Stmt::If->new( $self->_pos_token($modifier), cond => $cond, then => $empty, elsif => [], else => $body );
            }
            return Brocken::Katsuro::AST::Stmt::If->new( $self->_pos_token($modifier), cond => $cond, then => $body, elsif => [], else => undef );
        }
        $self->consume( ';', undef, $what );
        return $stmt;
    }

    method parse_var_decl() {
        $self->advance();
        if ( $self->check('[') ) {
            return $self->parse_array_decl();
        }

        # my ($a, $b) = expr -- list destructuring
        if ( $self->check('(') ) {
            return $self->parse_list_var_decl();
        }
        my $type = 'Any';
        if ( $self->is_type( $self->peek() ) ) {
            $type = $self->advance()->{value};
        }
        my $var_token = $self->consume( 'VAR', undef, "Expected variable name after 'my'" );
        my $sigil     = substr( $var_token->{value}, 0, 1 );
        my $name      = substr( $var_token->{value}, 1 );
        my $attrs     = $self->parse_attrs();
        my $init      = undef;
        if ( $self->check( 'OP', '=' ) || $self->check( 'OP', '//=' ) || $self->check( 'OP', '||=' ) ) {

            # A declaration has no previous value, so its initializer is always taken: `my $x //= 5` and `my $x ||= 5`
            # both set the fresh, undefined variable to 5, exactly as `my $x = 5` would. The distinct operators are
            # accepted here only so the Perl spelling parses; see the `state` work in TODO 3 for the form where the
            # condition is observable across calls.
            $self->advance();
            $init = $self->parse_expression(0);
        }
        $self->consume( ';', undef, "Expected ';' after variable declaration" );
        return Brocken::Katsuro::AST::Stmt::VarDecl->new( $self->_pos_token($var_token), sigil => $sigil, name => $name, type => $type,
            attrs => $attrs, init => $init );
    }

    # my ($a, $b) = expr
    method parse_list_var_decl() {
        $self->consume('(');
        my @targets;
        until ( $self->check(')') || $self->check('EOF') ) {
            if (@targets) {
                last if $self->check(')');
                $self->consume(',');
            }
            my $type = 'Any';
            if ( $self->is_type( $self->peek() ) ) {
                $type = $self->advance()->{value};
            }
            my $var_token = $self->consume( 'VAR', undef, "Expected variable name" );
            my $sigil     = substr( $var_token->{value}, 0, 1 );
            my $name      = substr( $var_token->{value}, 1 );
            push @targets, { sigil => $sigil, name => $name, type => $type };
        }
        $self->consume(')');
        my $expr = undef;
        if ( $self->check( 'OP', '=' ) ) {
            $self->advance();
            $expr = $self->parse_expression(0);
        }
        $self->consume( ';', undef, "Expected ';' after list variable declaration" );
        return Brocken::Katsuro::AST::Stmt::ListVarDecl->new( $self->_pos_token(), targets => \@targets, expr => $expr );
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

    # Perl-style list iteration:
    #
    #   for my $x (LIST) { ... }         one element per pass
    #   for my ($k, $v) (LIST) { ... }   one *stride* of elements per pass, bound left to right
    #
    # `LIST` is a parenthesized comma-separated expression list, evaluated once to a tag-7 list. A single element is
    # kept as the list-producing expression itself (so `(@a)` and `(builtin::indexed(@a))` pass through unchanged);
    # several make an `Expr::List`. The `my` is required: Brocken has no `$_` for the implicit form.
    method parse_for() {
        my $for_token = $self->advance();    # 'for' or 'foreach'
        $self->consume( 'KEYWORD', 'my', "Expected 'my' after '$for_token->{value}'" );
        my @targets;
        if ( $self->check('(') ) {
            $self->consume('(');
            until ( $self->check(')') || $self->check('EOF') ) {
                if (@targets) {
                    last if $self->check(')');
                    $self->consume(',');
                }
                push @targets, $self->parse_for_target();
            }
            $self->consume(')');
        }
        else {
            push @targets, $self->parse_for_target();
        }

        $self->consume( '(', undef, "Expected '(' before the '$for_token->{value}' list" );
        my @elements;
        until ( $self->check(')') || $self->check('EOF') ) {
            if (@elements) {
                last if $self->check(')');
                $self->consume(',');
            }
            push @elements, $self->parse_expression(0);
        }
        $self->consume(')');
        my $expr;
        if ( @elements == 0 )    { $expr = undef; }
        elsif ( @elements == 1 ) { $expr = $elements[0]; }
        else {
            $expr = Brocken::Katsuro::AST::Expr::List->new( $self->_pos_token($for_token), elements => \@elements );
        }

        my $body = $self->parse_block();
        return Brocken::Katsuro::AST::Stmt::For->new(
            $self->_pos_token($for_token),
            targets => \@targets,
            expr    => $expr,
            body    => $body,
        );
    }

    # One `for`/`foreach` loop variable: an optional type then a variable. Shares the target shape `parse_list_var_decl`
    # produces so the lowerer can bind them with the same code.
    method parse_for_target() {
        my $type = 'Any';
        if ( $self->is_type( $self->peek() ) ) {
            $type = $self->advance()->{value};
        }
        my $var_token = $self->consume( 'VAR', undef, 'Expected a loop variable' );
        return {
            sigil => substr( $var_token->{value}, 0, 1 ),
            name  => substr( $var_token->{value}, 1 ),
            type  => $type,
        };
    }

    method parse_return() {
        my $ret_token = $self->advance();
        my $expr      = undef;
        unless ( $self->check(';') ) {
            $expr = $self->parse_expression(0);
            if ( $expr->isa('Brocken::Katsuro::AST::Expr::Paren') ) {
                $expr = Brocken::Katsuro::AST::Expr::List->new( $self->_pos_token($ret_token), elements => [ $expr->expr ] );
            }
        }
        return $self->_end_statement(
            Brocken::Katsuro::AST::Stmt::Return->new( $self->_pos_token($ret_token), expr => $expr ),
            "Expected ';' after return" );
    }

    method parse_throw() {
        my $throw_token = $self->advance();
        my $expr        = $self->parse_expression(0);
        return $self->_end_statement(
            Brocken::Katsuro::AST::Stmt::Throw->new( $self->_pos_token($throw_token), expr => $expr ),
            "Expected ';' after throw" );
    }

    # `exit;` or `exit(EXPR);` -- terminate the process with the given status (0 when omitted). The status is optional
    # so both the bare form and the Perl-style parenthesized form parse; a postfix modifier (`exit(1) if $bad;`) is
    # handled by `_end_statement`.
    method parse_exit() {
        my $exit_token = $self->advance();
        my $code       = undef;
        if ( $self->check('(') ) {
            $self->advance();
            $code = $self->parse_expression(0) unless $self->check(')');
            $self->consume(')');
        }
        return $self->_end_statement(
            Brocken::Katsuro::AST::Stmt::Exit->new( $self->_pos_token($exit_token), code => $code ),
            "Expected ';' after exit" );
    }

    method parse_trycatch() {
        my $try_token    = $self->advance();
        my $try_body     = $self->parse_block();
        my $catch_var    = undef;
        my $catch_body   = undef;
        my $finally_body = undef;
        if ( $self->check( 'KEYWORD', 'catch' ) ) {
            $self->advance();
            if ( $self->check('(') ) {
                $self->consume('(');
                my $var_tok = $self->consume( 'VAR', undef, "Expected variable name in catch" );
                $catch_var = $var_tok->{value};
                $self->consume(')');
            }
            $catch_body = $self->parse_block();
        }
        if ( $self->check( 'KEYWORD', 'finally' ) ) {
            $self->advance();
            $finally_body = $self->parse_block();
        }
        Carp::croak( "Expected 'catch' or 'finally' after try block at " . $self->_loc() ) unless defined $catch_body || defined $finally_body;
        return Brocken::Katsuro::AST::Stmt::TryCatch->new(
            $self->_pos_token($try_token),
            try_body     => $try_body,
            catch_var    => $catch_var,
            catch_body   => $catch_body,
            finally_body => $finally_body,
        );
    }

    # Parse (expr, expr, ...) as a list expression
    method parse_paren_list_expr() {
        $self->consume('(');
        my @elements;
        until ( $self->check(')') || $self->check('EOF') ) {
            if (@elements) {
                last if $self->check(')');
                $self->consume(',');
            }
            push @elements, $self->parse_expression(0);
        }
        $self->consume(')');
        return Brocken::Katsuro::AST::Expr::List->new( $self->_pos_token(), elements => \@elements );
    }

    method parse_want($token) {
        $self->consume('(');
        my $context;
        if ( $self->check('STRING') ) {
            $context = $self->advance()->{value};
            Carp::croak( "want() context must be 'list', 'scalar', or 'void' at " . $self->_loc($token) )
                unless $context eq 'list' || $context eq 'scalar' || $context eq 'void';
        }
        elsif ( $self->check('KEYWORD') || $self->check('IDENT') ) {
            $context = $self->advance()->{value};
        }
        else {
            Carp::croak( "want() expects a type name or context string at " . $self->_loc($token) );
        }
        $self->consume(')');
        return Brocken::Katsuro::AST::Expr::Want->new( $self->_pos_token($token), context => $context );
    }

    method parse_builtin_print() {
        my $tok  = $self->advance();
        my $name = $tok->{value};
        $self->consume('(');
        my $args = $self->parse_call_args_after_paren();
        return $self->_end_statement(
            Brocken::Katsuro::AST::Expr::Call->new( $self->_pos_token($tok), func_name => $name, args => $args ),
            "Expected ';' after $name()" );
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

    # Parse an optional return annotation following a signature. Brocken uses the attribute form
    # ':returns(Type)' exclusively; the old '-> Type' spelling has been removed (TODO 3, spec 7.4).
    method parse_return_annotation() {
        return undef unless $self->check( 'OP', ':' );
        $self->advance();    # ':'
        my $attr = $self->consume( 'IDENT', undef, "Expected attribute name after ':'" );
        Carp::croak( "Unknown sub/method attribute ':" . $attr->{value} . "' at line $attr->{line}, col $attr->{col}" )
            unless $attr->{value} eq 'returns';
        $self->consume('(');
        my $type = $self->_parse_type_name("Expected type in ':returns(...)'");
        if ( $self->check(',') ) {
            my $t = $self->peek();
            Carp::croak("Tuple returns are not yet implemented at line $t->{line}, col $t->{col} (see TODO 3)");
        }
        $self->consume(')');
        return $type;
    }

    method _parse_type_name($msg) {
        return $self->advance()->{value} if $self->is_type( $self->peek() );
        return $self->consume( 'IDENT', undef, $msg )->{value};
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
            my $default   = undef;
            if ( $self->check( 'OP', '=' ) ) {
                $self->advance();
                $default = $self->parse_expression( PREC_ASSIGN - 1 );
            }
            push @params, { type => $ptype, sigil => $psigil, name => $pname, default => $default };
        }
        $self->consume(')');
        my $return_type = $self->parse_return_annotation();
        if ( $self->check(';') ) {
            $self->advance();
            return Brocken::Katsuro::AST::Stmt::SubDecl->new(
                $self->_pos_token($sub_token),
                name        => $name_token->{value},
                params      => \@params,
                return_type => $return_type,
                body        => Brocken::Katsuro::AST::Stmt::Block->new( statements => [] ),
                package     => $current_package,
            );
        }
        my $body = $self->parse_block();
        return Brocken::Katsuro::AST::Stmt::SubDecl->new(
            $self->_pos_token($sub_token),
            name        => $name_token->{value},
            params      => \@params,
            return_type => $return_type,
            body        => $body,
            package     => $current_package,
        );
    }

    # Class declarations
    # `:attr` / `:attr(arg)` records, shared by class declarations and fields. `arg` is undef for a plain `:reader`.
    method parse_attrs() {
        my @attrs;
        while ( $self->check( 'OP', ':' ) ) {
            $self->advance();
            my $attr_token = $self->consume( 'IDENT', undef, "Expected attribute name after ':'" );
            my $arg        = undef;
            if ( $self->check('(') ) {
                $self->advance();
                my $arg_token = $self->consume( 'IDENT', undef, "Expected attribute argument after '('" );
                $arg = $arg_token->{value};
                $self->consume( ')', undef, "Expected ')' after attribute argument" );
            }
            push @attrs, { name => $attr_token->{value}, arg => $arg };
        }
        return \@attrs;
    }

    method parse_class_decl() {
        my $class_token = $self->advance();
        my $name_token  = $self->consume( 'IDENT', undef, "Expected class name after 'class'" );

        # `class NAME VERSION :ATTRS { ... }`. VERSION is the same literal `package NAME VERSION` takes; the
        # attribute list is shared with fields (`:isa(Base)` today).
        my $version;
        if ( $self->check('VERSION') || $self->check('FLOAT') || $self->check('NUM') ) {
            $version = $self->advance()->{value};
        }
        my $attrs = $self->parse_attrs();

        # `class NAME;` is a forward declaration: it registers the name, version and attributes but carries no body.
        # A later block for the same name replaces it.
        if ( $self->check(';') ) {
            $self->advance();
            return Brocken::Katsuro::AST::Stmt::ClassDecl->new(
                $self->_pos_token($class_token),
                name    => $name_token->{value},
                version => $version,
                attrs   => $attrs,
                package => $current_package,
            );
        }

        $self->consume('{');
        my @fields;
        my @methods;
        my @adjusts;
        my @destroys;
        until ( $self->check('}') || $self->check('EOF') ) {
            if ( $self->check( 'KEYWORD', 'field' ) ) {
                push @fields, $self->parse_field_decl();
            }
            elsif ( $self->check( 'KEYWORD', 'method' ) ) {
                push @methods, $self->parse_method_decl();
            }
            elsif ( $self->check( 'KEYWORD', 'ADJUST' ) ) {
                my $adjust_tok = $self->advance();
                push @adjusts, Brocken::Katsuro::AST::Stmt::Adjust->new( $self->_pos_token($adjust_tok), body => $self->parse_block() );
            }
            elsif ( $self->check( 'KEYWORD', 'DESTROY' ) ) {
                my $destroy_tok = $self->advance();
                push @destroys, Brocken::Katsuro::AST::Stmt::Adjust->new( $self->_pos_token($destroy_tok), body => $self->parse_block() );
            }
            else {
                my $t = $self->peek();
                Carp::croak("Expected 'field', 'method', 'ADJUST', or 'DESTROY' in class body, got $t->{type} '$t->{value}' at line $t->{line}, col $t->{col}");
            }
        }
        $self->consume('}');
        return Brocken::Katsuro::AST::Stmt::ClassDecl->new(
            $self->_pos_token($class_token),
            name     => $name_token->{value},
            version  => $version,
            attrs    => $attrs,
            fields   => \@fields,
            methods  => \@methods,
            adjusts  => \@adjusts,
            destroys => \@destroys,
            package  => $current_package,
        );
    }

    method parse_field_decl() {
        my $field_tok = $self->advance();    # consume 'field'

        # Array/hash fields get two shapes beyond the scalar `field T $name`:
        #
        #   field [T; N] $name   -- N elements stored inline in the object
        #   field T @name        -- one pointer slot holding an array's element base
        #   field T %name        -- one pointer slot holding hash data
        #
        # The sigil in the variable token decides which of the latter two is meant; a `[` type is always inline.
        if ( $self->check('[') ) {
            $self->advance();
            my $elem = 'Any';
            $elem = $self->advance()->{value} if $self->is_type( $self->peek() );
            $self->consume( ';', undef, "Expected ';' between element type and size in inline array field" );
            my $size = $self->parse_expression(0);
            $self->consume( ']', undef, "Expected ']' after inline array field type" );
            my $fvar_token = $self->consume( 'VAR', undef, "Expected field name" );
            my $fname      = substr( $fvar_token->{value}, 1 );
            return $self->_finish_field_decl(
                $field_tok,
                type      => $elem,
                name      => $fname,
                sigil     => substr( $fvar_token->{value}, 0, 1 ),
                kind      => 'array',
                elem_type => $elem,
                size_expr => $size,
                inline    => 1,
            );
        }
        my $ft = $self->peek();
        Carp::croak("Expected field type, got $ft->{type} '$ft->{value}' at line $ft->{line}, col $ft->{col}") unless $self->is_type($ft);
        my $ftype      = $self->advance()->{value};
        my $fvar_token = $self->consume( 'VAR', undef, "Expected field name" );
        my $fname      = substr( $fvar_token->{value}, 1 );
        my $sigil      = substr( $fvar_token->{value}, 0, 1 );
        my $kind       = $sigil eq '@' ? 'array' : $sigil eq '%' ? 'hash' : 'scalar';
        return $self->_finish_field_decl(
            $field_tok,
            type      => $ftype,
            name      => $fname,
            sigil     => $sigil,
            kind      => $kind,
            elem_type => $kind eq 'array' ? $ftype : undef,
            inline    => 0,
        );
    }

    method _finish_field_decl( $field_tok, %args ) {
        my $attrs = $self->parse_attrs();
        my $default    = undef;
        my $default_op = undef;
        if ( $self->check( 'OP', '=' ) || $self->check( 'OP', '//=' ) || $self->check( 'OP', '||=' ) ) {
            $default_op = $self->advance()->{value};
            $default    = $self->parse_expression(0);
        }
        $self->consume(';');
        return Brocken::Katsuro::AST::Stmt::FieldDecl->new(
            $self->_pos_token($field_tok),
            type       => $args{type},
            name       => $args{name},
            sigil      => $args{sigil},
            kind       => $args{kind},
            elem_type  => $args{elem_type},
            size_expr  => $args{size_expr},
            inline     => $args{inline},
            attrs      => $attrs,
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
            my $default   = undef;
            if ( $self->check( 'OP', '=' ) ) {
                $self->advance();
                $default = $self->parse_expression( PREC_ASSIGN - 1 );
            }
            push @params, { type => $ptype, sigil => $psigil, name => $pname, default => $default };
        }
        $self->consume(')');
        my $return_type = $self->parse_return_annotation();
        my $body        = $self->parse_block();
        return Brocken::Katsuro::AST::Stmt::MethodDecl->new(
            $self->_pos_token($method_tok),
            name        => $name_token->{value},
            params      => \@params,
            return_type => $return_type,
            body        => $body,
        );
    }

    method parse_loop_control() {
        my $tok = $self->advance();
        my $stmt = $tok->{value} eq 'last'
            ? Brocken::Katsuro::AST::Stmt::Break->new( $self->_pos_token($tok) )
            : Brocken::Katsuro::AST::Stmt::Continue->new( $self->_pos_token($tok) );
        return $self->_end_statement( $stmt, "Expected ';' after '$tok->{value}'" );
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
        if ( $token->{type} eq 'FLOAT' ) {
            return Brocken::Katsuro::AST::Expr::Const->new( $self->_pos_token($token), value => $token->{value}, type => 'Float' );
        }
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
            my @elements;
            my $has_fat_comma = 0;
            until ( $self->check(')') || $self->check('EOF') ) {
                if (@elements) {
                    last if $self->check(')');
                    $self->consume(',');
                }
                my $expr = $self->parse_expression(0);
                if ( $self->check('OP') && $self->peek()->{value} eq '=>' ) {
                    $has_fat_comma = 1;
                    if ( $expr->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
                        $expr = Brocken::Katsuro::AST::Expr::Const->new(
                            file  => $expr->file,
                            line  => $expr->line,
                            col   => $expr->col,
                            value => $expr->name,
                            type  => 'String'
                        );
                    }
                    $self->advance();
                    my $rhs = $self->parse_expression(0);
                    push @elements, { key => $expr, value => $rhs };
                }
                else {
                    push @elements, { key => undef, value => $expr };
                }
            }
            $self->consume(')');
            if ($has_fat_comma) {
                my ( @positional, @pairs );
                for my $e (@elements) {
                    if ( defined $e->{key} ) { push @pairs, { key => $e->{key}, value => $e->{value} }; }
                    else                     { push @positional, $e->{value}; }
                }
                my $hash = Brocken::Katsuro::AST::Expr::Hash->new( $self->_pos_token($token), pairs => \@pairs );
                return $hash unless @positional;
                return Brocken::Katsuro::AST::Expr::List->new( $self->_pos_token($token), elements => [ @positional, $hash ] );
            }
            if ( scalar @elements == 0 ) {
                return Brocken::Katsuro::AST::Expr::Const->new( $self->_pos_token($token), value => 0, type => 'Int' );
            }
            if ( scalar @elements == 1 ) {
                return Brocken::Katsuro::AST::Expr::Paren->new( $self->_pos_token($token), expr => $elements[0]->{value} );
            }
            return Brocken::Katsuro::AST::Expr::List->new( $self->_pos_token($token), elements => [ map { $_->{value} } @elements ] );
        }
        if ( $token->{type} eq 'KEYWORD' ) {
            return Brocken::Katsuro::AST::Expr::Const->new( $self->_pos_token($token), value => 1, type => 'Bool' ) if $token->{value} =~ /^true$/i;
            return Brocken::Katsuro::AST::Expr::Const->new( $self->_pos_token($token), value => 0, type => 'Bool' ) if $token->{value} =~ /^false$/i;
            return Brocken::Katsuro::AST::Expr::ClassConst->new( $self->_pos_token($token) ) if $token->{value} eq '__CLASS__';
            return $self->parse_want($token)                                                 if $token->{value} eq 'want';
            if ( $token->{value} eq 'exists' ) {
                my $arg = $self->parse_expression(PREC_UNARY);
                return Brocken::Katsuro::AST::Expr::Exists->new( $self->_pos_token($token), expr => $arg );
            }
            if ( $token->{value} eq 'defined' ) {
                my $arg = $self->parse_expression(PREC_UNARY);
                return Brocken::Katsuro::AST::Expr::Defined->new( $self->_pos_token($token), expr => $arg );
            }
            if ( $token->{value} eq 'delete' ) {
                my $arg = $self->parse_expression(PREC_UNARY);
                return Brocken::Katsuro::AST::Expr::Delete->new( $self->_pos_token($token), expr => $arg );
            }
            if ( $token->{value} eq 'length' ) {
                $self->consume( '(', undef, "Expected '(' after 'length'" );
                my $arg = $self->parse_expression(0);
                $self->consume( ')', undef, "Expected ')' after length argument" );
                return Brocken::Katsuro::AST::Expr::Call->new( $self->_pos_token($token), func_name => 'length', args => [$arg] );
            }
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
            if ( $ASSIGN_OPS{$op} ) {
                my $right = $self->parse_expression( PREC_ASSIGN - 1 );

                # A compound assignment (`$x += 1`, `%h{k} .= "s"`) is sugar for `$x = $x OP 1`: build the read as a
                # `BinOp` over a second use of the target node and hand the whole thing to the ordinary `=`
                # assignment, so it reuses the established lowering and its reference counting. The target
                # sub-expressions are therefore re-evaluated once (a `%map{key}` key is computed twice), which is the
                # one place this differs from a dedicated single-evaluation lowering.
                if ( $COMPOUND_ASSIGN{$op} ) {
                    my $base = substr( $op, 0, -1 );
                    my $read = Brocken::Katsuro::AST::Expr::BinOp->new(
                        $self->_pos_token($token), op => $base, lhs => $left, rhs => $right );
                    return Brocken::Katsuro::AST::Stmt::Assign->new( $self->_pos_token($token), target => $left, expr => $read, op => '=' );
                }
                return Brocken::Katsuro::AST::Stmt::Assign->new( $self->_pos_token($token), target => $left, expr => $right, op => $op );
            }
            if ( $op eq '->' ) {
                my $ident;
                if ( $self->check('IDENT') ) {
                    $ident = $self->advance();
                }
                elsif ( $self->check( 'KEYWORD', 'DESTROY' ) ) {

                    # `$obj->DESTROY` is an ordinary method call even though the lexer reserves the word as the
                    # class-body DESTROY member.
                    $ident = $self->advance();
                }
                else {
                    my $t = $self->peek();
                    Carp::croak("Expected field or method name after '->' at line $t->{line}, col $t->{col}");
                }
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
            if ( $op eq '||' || $op eq '//' ) {
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
            if ( $op eq '&' ) {
                return Brocken::Katsuro::AST::Expr::BinOp->new(
                    $self->_pos_token($token),
                    op  => $op,
                    lhs => $left,
                    rhs => $self->parse_expression(PREC_BITAND)
                );
            }
            if ( $op eq '^' ) {
                return Brocken::Katsuro::AST::Expr::BinOp->new(
                    $self->_pos_token($token),
                    op  => $op,
                    lhs => $left,
                    rhs => $self->parse_expression(PREC_BITXOR)
                );
            }
            if ( $op eq '|' ) {
                return Brocken::Katsuro::AST::Expr::BinOp->new(
                    $self->_pos_token($token),
                    op  => $op,
                    lhs => $left,
                    rhs => $self->parse_expression(PREC_BITOR)
                );
            }
            if ( $op eq '+' || $op eq '-' || $op eq '.' ) {
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
            if ( $op eq '?' ) {
                my $then = $self->parse_expression(0);
                $self->consume( 'OP', ':', "Expected ':' after ternary then-expression" );
                my $else = $self->parse_expression(PREC_TERNARY);
                return Brocken::Katsuro::AST::Expr::Ternary->new( $self->_pos_token($token), cond => $left, then => $then, else => $else, );
            }
            Carp::croak( "Unknown operator '$op' at " . $self->_loc($token) );
        }
        if ( $token->{type} eq 'KEYWORD' ) {
            my $kw = $token->{value};
            if ( $kw eq 'eq' || $kw eq 'ne' || $kw eq 'lt' || $kw eq 'gt' || $kw eq 'le' || $kw eq 'ge' || $kw eq 'cmp' ) {
                return Brocken::Katsuro::AST::Expr::BinOp->new(
                    $self->_pos_token($token),
                    op  => $kw,
                    lhs => $left,
                    rhs => $self->parse_expression(PREC_COMPARE)
                );
            }
        }
        if ( $token->{type} eq '[' ) {
            my $index = $self->parse_expression(0);
            $self->consume(']');
            return Brocken::Katsuro::AST::Expr::ArrayIndex->new( $self->_pos_token($token), array => $left, index => $index );
        }
        if ( $token->{type} eq '{' && $left->isa('Brocken::Katsuro::AST::Expr::Var') && $left->sigil eq '%' ) {
            my $key = $self->parse_expression(0);
            $self->consume('}');
            return Brocken::Katsuro::AST::Expr::HashIndex->new( $self->_pos_token($token), hash => $left, key => $key );
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

            # The `builtin::` namespace mirrors Perl's `builtin` pragma: a utility function present in the
            # interpreter and callable by its fully-qualified name. It shares the intrinsic call node and is
            # dispatched by `lower_builtin`.
            if ( $name =~ /^builtin::([^:]+)$/ ) {
                return Brocken::Katsuro::AST::Expr::IntrinsicCall->new( $self->_pos_token($token), name => 'builtin::' . $1, args => $args );
            }
            return Brocken::Katsuro::AST::Expr::Call->new( $self->_pos_token($token), func_name => $name, args => $args );
        }
        Carp::croak( "Unexpected token $token->{type} '$token->{value}' after expression at " . $self->_loc($token) );
    }

    method parse_call_args_after_paren() {
        my @elements;
        my $has_fat_comma = 0;
        until ( $self->check(')') || $self->check('EOF') ) {
            if (@elements) {
                last if $self->check(')');
                $self->consume(',');
            }
            my $expr = $self->parse_expression(0);
            if ( $self->check('OP') && $self->peek()->{value} eq '=>' ) {
                $has_fat_comma = 1;
                if ( $expr->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
                    $expr = Brocken::Katsuro::AST::Expr::Const->new(
                        file  => $expr->file,
                        line  => $expr->line,
                        col   => $expr->col,
                        value => $expr->name,
                        type  => 'String'
                    );
                }
                $self->advance();
                my $rhs = $self->parse_expression(0);
                push @elements, { key => $expr, value => $rhs };
            }
            else {
                push @elements, { key => undef, value => $expr };
            }
        }
        $self->consume(')');
        if ($has_fat_comma) {
            my ( @positional, @pairs );
            for my $e (@elements) {
                if ( defined $e->{key} ) { push @pairs, { key => $e->{key}, value => $e->{value} }; }
                else                     { push @positional, $e->{value}; }
            }
            my @result = @positional;
            push @result, Brocken::Katsuro::AST::Expr::Hash->new( pairs => \@pairs ) if @pairs;
            return \@result;
        }
        return [ map { $_->{value} } @elements ];
    }

    method get_precedence($token) {
        return 0 unless $token;
        if ( $token->{type} eq 'OP' ) {
            my $op = $token->{value};
            return PREC_ASSIGN  if $ASSIGN_OPS{$op};
            return PREC_DEREF   if $op eq '->';
            return PREC_TERNARY if $op eq '?';
            return PREC_OR      if $op eq '||' || $op eq '//';
            return PREC_AND     if $op eq '&&';
            return PREC_BITOR   if $op eq '|';
            return PREC_BITXOR  if $op eq '^';
            return PREC_BITAND  if $op eq '&';
            return PREC_COMPARE if $op eq '==' || $op eq '!=' || $op eq '<' || $op eq '>' || $op eq '<=' || $op eq '>=';
            return PREC_SHIFT   if $op eq '<<' || $op eq '>>';
            return PREC_SUM     if $op eq '+'  || $op eq '-' || $op eq '.';
            return PREC_PRODUCT if $op eq '*'  || $op eq '/' || $op eq '%';
            return 0;
        }
        return PREC_DEREF if $token->{type} eq '[';
        return PREC_DEREF if $token->{type} eq '{';    # hash element access `%h{key}`; a block `{` never follows an expression
        return PREC_CALL  if $token->{type} eq '(';
        if ( $token->{type} eq 'KEYWORD' ) {
            my $kw = $token->{value};
            return PREC_COMPARE if $kw eq 'eq' || $kw eq 'ne' || $kw eq 'lt' || $kw eq 'gt' || $kw eq 'le' || $kw eq 'ge' || $kw eq 'cmp';
        }
        return 0;
    }
};
#
1;
