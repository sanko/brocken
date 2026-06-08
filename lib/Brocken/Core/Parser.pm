# lib/Brocken/Core/Parser.pm (Complete Source)
use v5.38;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Core::OOP;
use Brocken::Core::AST;
use Brocken::Core::Type;

# Defensively declare file-level lexicals outside the class block to prevent interpreter pad segfaults
my %PRECEDENCE = (
    'OP_DEFAULT' => 1,
    'ARROW'      => 4,    # High precedence for method calls
);

class Brocken::Core::Parser {
    field $tokens : param;
    field $pos = 0;
    field $classes : reader;

    # Isolate reference-types per-instance
    ADJUST {
        $classes = {};
    }

    method get_precedence($tok) {
        if ( $tok->type eq 'ARROW' ) {
            return 4;
        }
        if ( $tok->type eq 'OP' ) {
            my $v = $tok->value;
            return 2 if $v eq '+' || $v eq '-';
            return 3 if $v eq '*' || $v eq '/';
        }
        return $PRECEDENCE{ $tok->type } // 0;
    }
    method peek() { return $tokens->[$pos] }

    method advance() {
        my $tok = $tokens->[$pos];
        $pos++ if $pos < @$tokens - 1;
        return $tok;
    }

    method match( $type, $value = undef ) {
        my $tok = $self->peek();
        return 0 if $tok->type ne $type;
        return 0 if defined $value && $tok->value ne $value;
        return 1;
    }

    method consume( $type, $value = undef ) {
        my $tok = $self->advance();
        if ( $tok->type ne $type || ( defined $value && $tok->value ne $value ) ) {
            my $expected = $value // $type;
            die "Syntax Error: Expected '$expected', got '" . $tok->value . "' at line " . $tok->line . "\n";
        }
        return $tok;
    }

    method parse_program() {
        while ( $self->peek->type ne 'EOF' ) {
            $self->parse_statement();
        }
    }

    method parse_statement() {
        my $tok = $self->peek();

        # Defensively initialize inside method body to avoid package lexical-load order limits
        state %STATEMENT_REGISTRY = (
            'my'       => 'parse_lexical_decl',
            'if'       => 'parse_if_statement',
            'while'    => 'parse_while_statement',
            'class'    => 'parse_class',
            'ffi'      => 'parse_ffi_decl',
            'sub'      => 'parse_sub_decl',
            'return'   => 'parse_return_stmt',
            'yield'    => 'parse_yield_stmt',
            'transfer' => 'parse_transfer_stmt',
            'send'     => 'parse_send_stmt',
            'say'      => 'parse_say_stmt',
            'typedef'  => 'parse_typedef_decl',
        );

        # Route statement construction through our Dispatch table
        if ( $tok->type eq 'KEYWORD' ) {
            my $parser_method = $STATEMENT_REGISTRY{ $tok->value };
            if ( defined $parser_method ) {
                return $self->$parser_method();
            }
        }
        my $expr = $self->parse_expression(0);
        $self->consume( 'DELIMITER', ';' );
        return $expr;
    }

    method parse_class() {
        $self->consume( 'KEYWORD', 'class' );
        my $name_tok   = $self->consume('IDENT');
        my $class_name = $name_tok->value;
        my $superclass = undef;
        while ( $self->match('COLON') ) {
            $self->consume('COLON');
            my $attr_name = $self->consume('IDENT')->value;
            if ( $attr_name eq 'isa' ) {
                $self->consume( 'DELIMITER', '(' );
                $superclass = $self->consume('IDENT')->value;
                $self->consume( 'DELIMITER', ')' );
            }
            else {
                die "Syntax Error: Unknown class attribute ':$attr_name' at line " . $name_tok->line . "\n";
            }
        }
        my $class_meta = Brocken::Core::OOP::Class->new( name => $class_name, superclass_name => $superclass, );
        $self->consume( 'DELIMITER', '{' );
        while ( !$self->match( 'DELIMITER', '}' ) ) {
            my $tok = $self->peek();
            if ( $tok->type eq 'KEYWORD' && $tok->value eq 'field' ) {
                my $field = $self->parse_field();
                $class_meta->add_field($field);
            }
            elsif ( $tok->type eq 'KEYWORD' && $tok->value eq 'method' ) {
                $self->parse_method($class_meta);
            }
            else {
                die "Syntax Error: Unexpected token inside class body: '" . $tok->value . "' at line " . $tok->line . "\n";
            }
        }
        $self->consume( 'DELIMITER', '}' );
        $classes->{$class_name} = $class_meta;
        return $class_meta;
    }

    method parse_field() {
        $self->consume( 'KEYWORD', 'field' );
        my $var_tok  = $self->consume('VAR');
        my $var_name = $var_tok->value;
        my $is_param = 0;
        my $reader   = undef;
        my $writer   = undef;
        while ( $self->match('COLON') ) {
            $self->consume('COLON');
            my $attr = $self->consume('IDENT')->value;
            if ( $attr eq 'param' ) {
                $is_param = 1;
            }
            elsif ( $attr eq 'reader' ) {
                my $clean_name = $var_name =~ s/^\$//r;
                $reader = $clean_name;
            }
            elsif ( $attr eq 'writer' ) {
                my $clean_name = $var_name =~ s/^\$//r;
                $writer = "set_" . $clean_name;
            }
            else {
                die "Syntax Error: Unknown field attribute ':$attr' at line " . $var_tok->line . "\n";
            }
        }
        my $default_op   = undef;
        my $default_expr = undef;
        if ( $self->match('OP_DEFAULT') ) {
            $default_op   = $self->advance()->value;
            $default_expr = $self->parse_expression(0);
        }
        $self->consume( 'DELIMITER', ';' );
        return Brocken::Core::OOP::Field->new(
            name         => $var_name,
            is_param     => $is_param,
            reader_name  => $reader,
            writer_name  => $writer,
            default_op   => $default_op,
            default_expr => $default_expr,
        );
    }

    method parse_method($class_meta) {
        my $meth_tok = $self->consume( 'KEYWORD', 'method' );
        my $name     = $self->consume('IDENT')->value;
        my $sig      = $self->parse_signature();
        $self->consume( 'DELIMITER', '{' );
        my $body = [];
        while ( !$self->match( 'DELIMITER', '}' ) ) {
            push @$body, $self->parse_statement();
        }
        $self->consume( 'DELIMITER', '}' );
        my $method_node
            = Brocken::Core::AST::Method->new( name => $name, signature => $sig, body => $body, line => $meth_tok->line, col => $meth_tok->col, );
        $class_meta->add_method( $name, $method_node );
        return $method_node;
    }

    method parse_signature() {
        $self->consume( 'DELIMITER', '(' );
        my $params = [];
        while ( !$self->match( 'DELIMITER', ')' ) ) {
            my $type    = Brocken::Core::Type->new( name => 'Any' );
            my $var_tok = undef;

            # If we see an IDENT, it represents a type constraint
            if ( $self->match('IDENT') ) {
                $type    = $self->parse_type();
                $var_tok = $self->consume('VAR');
            }
            else {
                $var_tok = $self->consume('VAR');
            }
            my $name         = $var_tok->value;
            my $default_op   = undef;
            my $default_expr = undef;
            if ( $self->match('OP_DEFAULT') ) {
                $default_op   = $self->advance()->value;
                $default_expr = $self->parse_expression(0);
            }

            # Invariant Array type-inference by @ sigil
            if ( $name =~ /^\@/ ) {
                $type = Brocken::Core::Type->new( name => 'Array', parameter => $type );
            }
            push @$params, Brocken::Core::AST::Parameter->new(
                name         => $name,
                type         => $type,            # Bind the parsed Type object
                default_op   => $default_op,
                default_expr => $default_expr,
                line         => $var_tok->line,
                col          => $var_tok->col,
            );
            if ( $self->match( 'DELIMITER', ',' ) ) {
                $self->consume( 'DELIMITER', ',' );
            }
            else {
                last;
            }
        }
        $self->consume( 'DELIMITER', ')' );
        return Brocken::Core::AST::Signature->new( params => $params );
    }

    method parse_lexical_decl() {
        my $my_tok = $self->consume( 'KEYWORD', 'my' );

        # If the next token is an identifier, it designates a type constraint
        my $type = Brocken::Core::Type->new( name => 'Any' );
        if ( $self->match('IDENT') ) {
            $type = $self->parse_type();
        }
        my $var_tok    = $self->consume('VAR');
        my $name       = $var_tok->value;
        my $default_op = '=';
        my $value      = undef;
        if ( $self->match('OP_DEFAULT') ) {
            $default_op = $self->advance()->value;
            $value      = $self->parse_expression(0);
        }
        $self->consume( 'DELIMITER', ';' );

        # Invariant Array type-inference by @ sigil
        if ( $name =~ /^\@/ ) {
            $type = Brocken::Core::Type->new( name => 'Array', parameter => $type );
        }
        return Brocken::Core::AST::MyDecl->new(
            name       => $name,
            value      => $value,
            type       => $type,           # Bind the parsed Type object onto the AST node
            default_op => $default_op,
            line       => $my_tok->line,
            col        => $my_tok->col,
        );
    }

    method parse_if_statement() {
        my $if_tok = $self->consume( 'KEYWORD', 'if' );
        $self->consume( 'DELIMITER', '(' );
        my $cond = $self->parse_expression(0);
        $self->consume( 'DELIMITER', ')' );
        $self->consume( 'DELIMITER', '{' );
        my $then_stmts = [];
        while ( !$self->match( 'DELIMITER', '}' ) ) {
            push @$then_stmts, $self->parse_statement();
        }
        $self->consume( 'DELIMITER', '}' );
        my $else_branch = undef;
        if ( $self->match( 'KEYWORD', 'elsif' ) ) {
            $else_branch = $self->parse_elsif_statement();
        }
        elsif ( $self->match( 'KEYWORD', 'else' ) ) {
            $self->consume( 'KEYWORD',   'else' );
            $self->consume( 'DELIMITER', '{' );
            my $else_stmts = [];
            while ( !$self->match( 'DELIMITER', '}' ) ) {
                push @$else_stmts, $self->parse_statement();
            }
            $self->consume( 'DELIMITER', '}' );
            $else_branch = $else_stmts;
        }
        return Brocken::Core::AST::If->new(
            condition   => $cond,
            then_branch => $then_stmts,
            else_branch => $else_branch,
            line        => $if_tok->line,
            col         => $if_tok->col,
        );
    }

    method parse_elsif_statement() {
        my $elsif_tok = $self->consume( 'KEYWORD', 'elsif' );
        $self->consume( 'DELIMITER', '(' );
        my $cond = $self->parse_expression(0);
        $self->consume( 'DELIMITER', ')' );
        $self->consume( 'DELIMITER', '{' );
        my $then_stmts = [];
        while ( !$self->match( 'DELIMITER', '}' ) ) {
            push @$then_stmts, $self->parse_statement();
        }
        $self->consume( 'DELIMITER', '}' );
        my $else_branch = undef;
        if ( $self->match( 'KEYWORD', 'elsif' ) ) {
            $else_branch = $self->parse_elsif_statement();
        }
        elsif ( $self->match( 'KEYWORD', 'else' ) ) {
            $self->consume( 'KEYWORD',   'else' );
            $self->consume( 'DELIMITER', '{' );
            my $else_stmts = [];
            while ( !$self->match( 'DELIMITER', '}' ) ) {
                push @$else_stmts, $self->parse_statement();
            }
            $self->consume( 'DELIMITER', '}' );
            $else_branch = $else_stmts;
        }
        return Brocken::Core::AST::If->new(
            condition   => $cond,
            then_branch => $then_stmts,
            else_branch => $else_branch,
            line        => $elsif_tok->line,
            col         => $elsif_tok->col,
        );
    }

    method parse_while_statement() {
        my $while_tok = $self->consume( 'KEYWORD', 'while' );
        $self->consume( 'DELIMITER', '(' );
        my $cond = $self->parse_expression(0);
        $self->consume( 'DELIMITER', ')' );
        $self->consume( 'DELIMITER', '{' );
        my $body_stmts = [];
        while ( !$self->match( 'DELIMITER', '}' ) ) {
            push @$body_stmts, $self->parse_statement();
        }
        $self->consume( 'DELIMITER', '}' );
        return Brocken::Core::AST::While->new( condition => $cond, body => $body_stmts, line => $while_tok->line, col => $while_tok->col );
    }

    method parse_expression($precedence) {
        my $left = $self->parse_prefix();
        while ( $precedence < $self->get_precedence( $self->peek() ) ) {
            my $next_tok = $self->peek();
            $left = $self->parse_infix($left);
        }
        return $left;
    }

    method parse_prefix() {
        my $tok = $self->advance();

        # Handle inline fiber block expressions
        if ( $tok->type eq 'KEYWORD' && $tok->value eq 'fiber' ) {
            $self->consume( 'DELIMITER', '{' );
            my $body = [];
            while ( !$self->match( 'DELIMITER', '}' ) ) {
                push @$body, $self->parse_statement();
            }
            $self->consume( 'DELIMITER', '}' );
            return Brocken::Core::AST::FiberBlock->new( body => $body, line => $tok->line, col => $tok->col, );
        }

        # Handle block isolate expressions
        if ( $tok->type eq 'KEYWORD' && $tok->value eq 'isolate' ) {
            $self->consume( 'DELIMITER', '{' );
            my $body = [];
            while ( !$self->match( 'DELIMITER', '}' ) ) {
                push @$body, $self->parse_statement();
            }
            $self->consume( 'DELIMITER', '}' );
            return Brocken::Core::AST::IsolateBlock->new( body => $body, line => $tok->line, col => $tok->col, );
        }

        # Handle block receive expressions
        if ( $tok->type eq 'KEYWORD' && $tok->value eq 'receive' ) {
            return Brocken::Core::AST::ReceiveExpr->new( line => $tok->line, col => $tok->col, );
        }
        if ( $tok->type eq 'INT' ) {
            return Brocken::Core::AST::Literal->new( value => $tok->value, line => $tok->line, col => $tok->col, );
        }
        if ( $tok->type eq 'STRING' ) {
            my $raw = $tok->value;
            substr $raw,  0, 1, '';
            substr $raw, -1, 1, '';
            return Brocken::Core::AST::StringLiteral->new( value => $raw, line => $tok->line, col => $tok->col, );
        }
        if ( $tok->type eq 'VAR' ) {
            return Brocken::Core::AST::Variable->new( name => $tok->value, line => $tok->line, col => $tok->col, );
        }
        if ( $tok->type eq 'IDENT' && $self->match( 'DELIMITER', '(' ) ) {
            my $name = $tok->value;
            $self->consume( 'DELIMITER', '(' );
            my $args = [];
            while ( !$self->match( 'DELIMITER', ')' ) ) {
                push @$args, $self->parse_expression(0);
                if ( $self->match( 'DELIMITER', ',' ) ) {
                    $self->consume( 'DELIMITER', ',' );
                }
                else {
                    last;
                }
            }
            $self->consume( 'DELIMITER', ')' );
            return Brocken::Core::AST::SubCall->new( name => $name, args => $args, line => $tok->line, col => $tok->col, );
        }
        if ( $tok->type eq 'DELIMITER' && $tok->value eq '(' ) {
            my $expr = $self->parse_expression(0);
            $self->consume( 'DELIMITER', ')' );
            return $expr;
        }
        die "Syntax Error: Unexpected token in prefix position '" . $tok->value . "' at line " . $tok->line . "\n";
    }

    method parse_infix($left) {
        my $op_tok        = $self->advance();
        my $op_precedence = $self->get_precedence($op_tok);

        # Handle Object-Oriented Infix Arrow Calls
        if ( $op_tok->type eq 'ARROW' ) {
            my $meth_tok  = $self->consume('IDENT');
            my $meth_name = $meth_tok->value;
            my $args      = [];
            if ( $self->match( 'DELIMITER', '(' ) ) {
                $self->consume( 'DELIMITER', '(' );
                while ( !$self->match( 'DELIMITER', ')' ) ) {
                    push @$args, $self->parse_expression(0);
                    if ( $self->match( 'DELIMITER', ',' ) ) {
                        $self->consume( 'DELIMITER', ',' );
                    }
                    else {
                        last;
                    }
                }
                $self->consume( 'DELIMITER', ')' );
            }
            return Brocken::Core::AST::MethodCall->new(
                invocand    => $left,
                method_name => $meth_name,
                args        => $args,
                line        => $op_tok->line,
                col         => $op_tok->col,
            );
        }
        my $right_precedence = ( $op_tok->type eq 'OP_DEFAULT' ) ? ( $op_precedence - 1 ) : $op_precedence;
        my $right            = $self->parse_expression($right_precedence);
        if ( $op_tok->type eq 'OP_DEFAULT' ) {
            if ( !$left->isa('Brocken::Core::AST::Variable') ) {
                die "Compilation Error: Left side of assignment must be a variable at line " . $op_tok->line . "\n";
            }
            return Brocken::Core::AST::Assign->new( op => $op_tok->value, left => $left, right => $right, line => $op_tok->line, col => $op_tok->col,
            );
        }
        return Brocken::Core::AST::BinaryOp->new( op => $op_tok->value, left => $left, right => $right, line => $op_tok->line, col => $op_tok->col, );
    }

    method parse_ffi_decl() {
        my $ffi_tok  = $self->consume( 'KEYWORD', 'ffi' );
        my $kind_tok = $self->advance();
        die "Syntax Error: Expected 'method' or 'sub' after 'ffi' at line " . $kind_tok->line . "\n"
            unless $kind_tok->type eq 'KEYWORD' && ( $kind_tok->value eq 'method' || $kind_tok->value eq 'sub' );
        my $name_tok = $self->consume('IDENT');
        my $name     = $name_tok->value;
        my $sig      = $self->parse_signature();
        $self->consume('COLON');
        my $attr_tok = $self->consume('IDENT');
        die "Syntax Error: Expected 'lib' attribute after FFI declaration at line " . $attr_tok->line . "\n" unless $attr_tok->value eq 'lib';
        $self->consume( 'DELIMITER', '(' );
        my $lib_tok  = $self->consume('IDENT');
        my $lib_name = $lib_tok->value;
        $self->consume( 'DELIMITER', ')' );
        $self->consume( 'DELIMITER', ';' );
        return Brocken::Core::AST::FFIDecl->new(
            name      => $name,
            signature => $sig,
            lib_name  => $lib_name,
            is_method => ( $kind_tok->value eq 'method' ) ? 1 : 0,
            line      => $ffi_tok->line,
            col       => $ffi_tok->col,
        );
    }

    # Recursively parses complex, nested, and parametric types (including inline Struct)
    method parse_type() {
        my $name_tok = $self->consume('IDENT');
        my $name     = $name_tok->value;

        # Resolve typedef aliases immediately during compilation
        my $resolved_alias = Brocken::Core::Type::lookup_typedef($name);
        if ( defined $resolved_alias ) {
            return $resolved_alias;
        }
        my $parameter = undef;
        my $size      = undef;
        my $fields    = undef;
        if ( $self->match( 'DELIMITER', '[' ) ) {
            $self->consume( 'DELIMITER', '[' );
            if ( $name eq 'Struct' || $name eq 'Union' ) {

                # Parse inline Struct/Union key-value pairs (e.g. name => String, age => Int)
                $fields = {};
                while ( !$self->match( 'DELIMITER', ']' ) ) {
                    my $field_name_tok = $self->consume('IDENT');
                    my $field_name     = $field_name_tok->value;
                    $self->consume( 'FAT_COMMA', '=>' );

                    # Recursively parse the type constraint for this field
                    my $field_type = $self->parse_type();
                    $fields->{$field_name} = $field_type;
                    if ( $self->match( 'DELIMITER', ',' ) ) {
                        $self->consume( 'DELIMITER', ',' );
                    }
                    else {
                        last;
                    }
                }
            }
            else {
                # Standard parametric type (e.g. Pointer[Char], Array[Double, 10])
                $parameter = $self->parse_type();
                if ( $self->match( 'DELIMITER', ',' ) ) {
                    $self->consume( 'DELIMITER', ',' );
                    my $size_tok = $self->consume('INT');
                    $size = $size_tok->value;
                }
            }
            $self->consume( 'DELIMITER', ']' );
        }
        return Brocken::Core::Type->new( name => $name, parameter => $parameter, size => $size, fields => $fields, );
    }

    # Parses typedef declarations, e.g. typedef Person => Struct[name => String];
    method parse_typedef_decl() {
        my $typedef_tok = $self->consume( 'KEYWORD', 'typedef' );
        my $name_tok    = $self->consume('IDENT');
        my $name        = $name_tok->value;
        $self->consume( 'FAT_COMMA', '=>' );
        my $type = $self->parse_type();
        $self->consume( 'DELIMITER', ';' );

        # Register the alias in our global Type system
        Brocken::Core::Type::register_typedef( $name, $type );
        return Brocken::Core::AST::TypedefDecl->new( name => $name, type => $type, line => $typedef_tok->line, col => $typedef_tok->col, );
    }

    # Parses standard subroutines, registering them under a virtual 'main' class
    method parse_sub_decl() {
        my $sub_tok  = $self->consume( 'KEYWORD', 'sub' );
        my $name_tok = $self->consume('IDENT');
        my $name     = $name_tok->value;
        my $sig      = $self->parse_signature();
        $self->consume( 'DELIMITER', '{' );
        my $body = [];
        while ( !$self->match( 'DELIMITER', '}' ) ) {
            push @$body, $self->parse_statement();
        }
        $self->consume( 'DELIMITER', '}' );
        my $sub_node
            = Brocken::Core::AST::SubDecl->new( name => $name, signature => $sig, body => $body, line => $sub_tok->line, col => $sub_tok->col, );

        # Register the subroutine under a default virtual class 'main'
        $classes->{main} //= Brocken::Core::OOP::Class->new( name => 'main' );
        $classes->{main}->add_method( $name, $sub_node );
        return $sub_node;
    }

    # Parses return statements
    method parse_return_stmt() {
        my $ret_tok = $self->consume( 'KEYWORD', 'return' );
        my $expr    = undef;
        if ( !$self->match( 'DELIMITER', ';' ) ) {
            $expr = $self->parse_expression(0);
        }
        $self->consume( 'DELIMITER', ';' );
        return Brocken::Core::AST::Return->new( value => $expr, line => $ret_tok->line, col => $ret_tok->col, );
    }

    # Parses yield statements, e.g. yield $count; or yield;
    method parse_yield_stmt() {
        my $yield_tok = $self->consume( 'KEYWORD', 'yield' );
        my $expr      = undef;
        if ( !$self->match( 'DELIMITER', ';' ) ) {
            $expr = $self->parse_expression(0);
        }
        $self->consume( 'DELIMITER', ';' );
        return Brocken::Core::AST::YieldStmt->new( value => $expr, line => $yield_tok->line, col => $yield_tok->col, );
    }

    # Parses transfer statements, e.g. transfer $f, $val; or transfer $f;
    method parse_transfer_stmt() {
        my $trans_tok = $self->consume( 'KEYWORD', 'transfer' );
        my $target    = $self->parse_expression(0);
        my $val       = undef;
        if ( $self->match( 'DELIMITER', ',' ) ) {
            $self->consume( 'DELIMITER', ',' );
            $val = $self->parse_expression(0);
        }
        $self->consume( 'DELIMITER', ';' );
        return Brocken::Core::AST::TransferStmt->new( target => $target, value => $val, line => $trans_tok->line, col => $trans_tok->col, );
    }

    # Parses say statements, e.g. say 'hello';
    method parse_say_stmt() {
        my $say_tok = $self->consume( 'KEYWORD', 'say' );
        my $expr    = $self->parse_expression(0);
        $self->consume( 'DELIMITER', ';' );
        return Brocken::Core::AST::SayStmt->new( value => $expr, line => $say_tok->line, col => $say_tok->col, );
    }

    # Parses send statements, e.g. send $worker, $msg;
    method parse_send_stmt() {
        my $send_tok = $self->consume( 'KEYWORD', 'send' );
        my $target   = $self->parse_expression(0);
        $self->consume( 'DELIMITER', ',' );
        my $expr = $self->parse_expression(0);
        $self->consume( 'DELIMITER', ';' );
        return Brocken::Core::AST::SendStmt->new( target => $target, value => $expr, line => $send_tok->line, col => $send_tok->col, );
    }
}
1;
