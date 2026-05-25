use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::AST;

class Brocken::Parser {
    field $lexer :param;
    field $tok   = undef;

    my %BP = (
        '=' => 2,  '+=' => 2, '-=' => 2, '*=' => 2, '/=' => 2, '%=' => 2,
        '.' => 2,  '**=' => 2, '&=' => 2, '|=' => 2, '^=' => 2, '<<=' => 2, '>>=' => 2,
        'or' => 3,
        'and' => 4,
        'not' => 5,
        '||' => 6,
        '//' => 6,
        '&&' => 7,
        '|' => 8,
        '^' => 9,
        '&' => 10,
        '==' => 11, '!=' => 11, 'eq' => 11, 'ne' => 11, '~~' => 11,
        '<' => 12, '>' => 12, '<=' => 12, '>=' => 12, 'lt' => 12, 'gt' => 12, 'le' => 12, 'ge' => 12,
        'cmp' => 12, '<=>' => 12,
        '<<' => 13, '>>' => 13,
        '..' => 13, '...' => 13,
        '+' => 14, '-' => 14, '.' => 14,
        '*' => 15, '/' => 15, '%' => 15, 'x' => 15,
        '**' => 16,
        '++' => 17, '--' => 17,
        '[' => 18,
        '{' => 18,
        '(' => 18,
        '?' => 2,
        '->' => 19,
    );

    my %RIGHT_ASSOC = map { $_ => 1 } qw(
        = += -= *= /= %= **= &= |= ^= <<= >>= .=
        ** ?  // or and
        < > <= >= lt gt le ge cmp <=>
    );

    ADJUST {
        $tok = $lexer->next();
    }

    method _next () {
        my $t = $tok;
        $tok = $lexer->next();
        return $t;
    }

    method _expect ($type, $value = undef) {
        my $t = $tok;
        my $loc = $t ? "{$t->{line}:$t->{col}}" : '{EOF}';
        die "Expected $type" . (defined $value ? " '$value'" : '') . " at $loc" if !$t || $t->{type} ne $type;
        if (defined $value && $t->{value} ne $value) {
            my $got = $t->{value} // '<undef>';
            die "Expected '$value' but got '$got' at $loc";
        }
        $self->_next();
        return $t;
    }

    method _check ($type, $value = undef) {
        return $tok && $tok->{type} eq $type && (!defined $value || $tok->{value} eq $value);
    }

    method _is_right_assoc ($op) {
        return exists $RIGHT_ASSOC{$op};
    }

    # --- Public API ---

    method parse () {
        my @stmts;
        while ($tok) {
            my $s = $self->_parse_stmt();
            push @stmts, $s if defined $s;
        }
        return Brocken::AST::Program->new(stmts => \@stmts);
    }

    # --- Statement parsing ---

    method _parse_stmt () {
        return undef unless $tok;

        # Skip empty semicolons
        if ($tok->{type} eq ';') {
            $self->_next();
            return $self->_parse_stmt();
        }

        if ($tok->{type} eq 'KEYWORD') {
            my $val = $tok->{value};
            if ($val eq 'if')    { return $self->_parse_if_stmt() }
            if ($val eq 'unless') { return $self->_parse_unless_stmt() }
            if ($val eq 'while')  { return $self->_parse_while_stmt() }
            if ($val eq 'until')  { return $self->_parse_until_stmt() }
            if ($val eq 'for')    { return $self->_parse_for_stmt() }
            if ($val eq 'foreach') { return $self->_parse_foreach_stmt() }
            if ($val eq 'sub')    { return $self->_parse_sub_stmt() }
            if ($val eq 'my' || $val eq 'our' || $val eq 'state') {
                my $stmt = $self->_parse_my_decl($val);
                return $self->_finish_stmt($stmt);
            }
            if ($val eq 'return') {
                $self->_next();
                my $stmt;
                if ($tok && $tok->{type} ne ';' && $tok->{type} ne 'KEYWORD') {
                    my $expr = $self->_parse_expr(0);
                    $stmt = Brocken::AST::Return->new(expr => $expr);
                } else {
                    $stmt = Brocken::AST::Return->new();
                }
                return $self->_finish_stmt_with_modifier($stmt);
            }
            if ($val =~ /^(last|next|redo)$/) {
                $self->_next();
                my $stmt = Brocken::AST::FlowStmt->new(type => $val);
                $self->_expect(';');
                return $stmt;
            }
            if ($val eq 'spawn_thread') {
                $self->_next();  # consume 'spawn_thread'
                my $tok2 = $self->_next();
                my $sub = $self->_nud($tok2);
                my $stmt = Brocken::AST::Call->new(name => 'spawn_thread', args => [$sub]);
                return $self->_finish_stmt_with_modifier($stmt);
            }
        }

        # Bare IDENT at statement start → function call
        if ($tok && $tok->{type} eq 'IDENT') {
            my $name = $tok->{value};
            $self->_next();
            my @args;
            if ($tok && $tok->{type} eq '(') {
                $self->_next();
                @args = $self->_parse_args();
            }
            else {
                my %expr_keywords = map { $_ => 1 } qw(sub fiber yield);
                while ($tok && $tok->{type} ne ';') {
                    last if $tok->{type} eq 'KEYWORD' && !$expr_keywords{$tok->{value}};
                    push @args, $self->_parse_expr(0);
                    last unless $tok && $tok->{type} eq ',';
                    $self->_next();
                }
            }
            my $stmt = Brocken::AST::Call->new(name => $name, args => \@args);
            return $self->_finish_stmt_with_modifier($stmt);
        }

        # Expression statement
        my $expr = $self->_parse_expr(0);
        return $self->_finish_stmt_with_modifier($expr);
    }

    method _finish_stmt ($stmt) {
        if ($tok && $tok->{type} eq ';') {
            $self->_next();
        }
        return $stmt;
    }

    method _finish_stmt_with_modifier ($stmt) {
        if ($tok && $tok->{type} eq 'KEYWORD' && $tok->{value} =~ /^(if|unless|while|until)$/) {
            my $mod = $tok->{value};
            $self->_next();
            my $cond = $self->_parse_expr(0);
            my $block = Brocken::AST::Block->new(stmts => [$stmt]);
            if ($mod eq 'if') {
                return Brocken::AST::If->new(cond => $cond, then => $block);
            }
            if ($mod eq 'unless') {
                my $not_cond = Brocken::AST::UnaryOp->new(op => '!', operand => $cond);
                return Brocken::AST::If->new(cond => $not_cond, then => $block);
            }
            if ($mod eq 'while') {
                return Brocken::AST::While->new(cond => $cond, body => $block);
            }
            if ($mod eq 'until') {
                return Brocken::AST::While->new(cond => $cond, body => $block);
            }
        }
        if ($tok && $tok->{type} eq ';') {
            $self->_next();
        }
        return $stmt;
    }

    method _parse_block () {
        $self->_expect('{');
        my @stmts;
        while ($tok && $tok->{type} ne '}') {
            my $s = $self->_parse_stmt();
            push @stmts, $s if defined $s;
        }
        $self->_expect('}');
        return Brocken::AST::Block->new(stmts => \@stmts);
    }

    method _parse_if_stmt () {
        $self->_next();  # consume 'if'
        $self->_expect('(');
        my $cond = $self->_parse_expr(0);
        $self->_expect(')');
        my $then = $self->_parse_block();
        my $else;
        if ($tok && $tok->{type} eq 'KEYWORD' && $tok->{value} eq 'elsif') {
            my $inner_if = $self->_parse_if_stmt();
            $else = Brocken::AST::Block->new(stmts => [$inner_if]);
        }
        elsif ($tok && $tok->{type} eq 'KEYWORD' && $tok->{value} eq 'else') {
            $self->_next();
            $else = $self->_parse_block();
        }
        return Brocken::AST::If->new(cond => $cond, then => $then, else => $else);
    }

    method _parse_unless_stmt () {
        $self->_next();  # consume 'unless'
        $self->_expect('(');
        my $cond = $self->_parse_expr(0);
        $self->_expect(')');
        my $then = $self->_parse_block();
        my $not_cond = Brocken::AST::UnaryOp->new(op => '!', operand => $cond);
        my $else;
        if ($tok && $tok->{type} eq 'KEYWORD' && $tok->{value} eq 'else') {
            $self->_next();
            $else = $self->_parse_block();
        }
        return Brocken::AST::If->new(cond => $not_cond, then => $then, else => $else);
    }

    method _parse_while_stmt () {
        $self->_next();  # consume 'while'
        $self->_expect('(');
        my $cond = $self->_parse_expr(0);
        $self->_expect(')');
        my $body = $self->_parse_block();
        return Brocken::AST::While->new(cond => $cond, body => $body);
    }

    method _parse_until_stmt () {
        $self->_next();  # consume 'until'
        $self->_expect('(');
        my $cond = $self->_parse_expr(0);
        my $not_cond = Brocken::AST::UnaryOp->new(op => '!', operand => $cond);
        $self->_expect(')');
        my $body = $self->_parse_block();
        return Brocken::AST::While->new(cond => $not_cond, body => $body);
    }

    method _parse_my_decl ($keyword) {
        $self->_next();  # consume 'my'/'our'/'state'
        my $type = undef;
        # Optional type annotation: my Type $var
        if ($tok && $tok->{type} eq 'IDENT' && $lexer->peek() && $lexer->peek()->{type} eq 'VAR') {
            $type = $tok->{value};
            $self->_next();  # consume type name
        }
        my $var = $self->_expect('VAR');
        my $name = $var->{value};
        my $expr = undef;
        if ($tok && $tok->{type} eq '=') {
            $self->_next();  # consume '='
            $expr = $self->_parse_expr(0);
        }
        return Brocken::AST::MyDecl->new(name => $name, type => $type, expr => $expr);
    }

    method _parse_for_stmt () {
        $self->_next();  # consume 'for'
        $self->_expect('(');

        # C-style for: for (my $i = 0; $i < 10; $i++)
        my $init = undef;
        if ($tok && $tok->{type} ne ';') {
            if ($tok->{type} eq 'KEYWORD' && $tok->{value} =~ /^(my|our|state)$/) {
                $init = $self->_parse_my_decl($tok->{value});
            } else {
                $init = $self->_parse_expr(0);
            }
        }
        $self->_expect(';');

        my $cond = undef;
        if ($tok && $tok->{type} ne ';') {
            $cond = $self->_parse_expr(0);
        }
        $self->_expect(';');

        my $step = undef;
        if ($tok && $tok->{type} ne ')') {
            $step = $self->_parse_expr(0);
        }
        $self->_expect(')');

        my $body = $self->_parse_block();
        return Brocken::AST::For->new(init => $init, cond => $cond, step => $step, body => $body);
    }

    method _parse_foreach_stmt () {
        $self->_next();
        $self->_expect('(');
        my $var = $self->_expect('VAR');
        $self->_expect('(');
        my $expr = $self->_parse_expr(0);
        $self->_expect(')');
        $self->_expect(')');
        my $body = $self->_parse_block();
        return Brocken::AST::Foreach->new(var => $var->{value}, expr => $expr, body => $body);
    }

    method _parse_sub_stmt () {
        $self->_next();  # consume 'sub'
        my $name = $tok ? $tok->{value} : 'anon';
        if ($tok && $tok->{type} eq 'IDENT') {
            $self->_next();
        }
        my @params;
        if ($tok && $tok->{type} eq '(') {
            $self->_next();
            while ($tok && $tok->{type} ne ')') {
                my $p = $self->_expect('VAR');
                push @params, $p->{value};
                last unless $tok && $tok->{type} eq ',';
                $self->_next();
            }
            $self->_expect(')');
        }
        my $body = $self->_parse_block();
        return Brocken::AST::SubDecl->new(name => $name, params => \@params, body => $body);
    }

    # --- Expression parsing (Pratt) ---

    method _parse_expr ($min_bp) {
        my $cur = $self->_next();
        my $loc = $tok ? "{$tok->{line}:$tok->{col}}" : '{EOF}';
        die "Expected expression at $loc" unless $cur;
        my $left = $self->_nud($cur);

        while ($tok) {
            my $type = $tok->{type};
            last unless exists $BP{$type};
            my $bp = $BP{$type};
            last if $bp < $min_bp;
            my $op_tok = $self->_next();
            my $next_bp = $self->_is_right_assoc($type) ? $bp : $bp + 1;
            $left = $self->_led($op_tok, $left, $next_bp);
        }
        return $left;
    }

    method _nud ($tkn) {
        my $t    = $tkn->{type};
        my $val  = $tkn->{value};
        my $line = $tkn->{line};
        my $col  = $tkn->{col};

        if ($t eq 'INT')   { return Brocken::AST::IntLiteral->new(value => $val, line => $line, col => $col) }
        if ($t eq 'FLOAT') { return Brocken::AST::FloatLiteral->new(value => $val, line => $line, col => $col) }
        if ($t eq 'STRING') { return Brocken::AST::StrLiteral->new(value => $val, line => $line, col => $col) }

        if ($t eq 'VAR') {
            return Brocken::AST::Var->new(name => $val, sigil => $tkn->{sigil} // '$', line => $line, col => $col);
        }

        if ($t eq 'IDENT') {
            if ($tok && $tok->{type} eq '(') {
                $self->_next();
                my @args = $self->_parse_args();
                return Brocken::AST::Call->new(name => $val, args => \@args, line => $line, col => $col);
            }
            return Brocken::AST::Ident->new(name => $val, line => $line, col => $col);
        }

        if ($t eq 'KEYWORD' && $val eq 'sub') {
            my $name = 'anon';
            my @params;
            if ($tok && $tok->{type} eq '(') {
                $self->_next();
                while ($tok && $tok->{type} ne ')') {
                    my $p = $self->_expect('VAR');
                    push @params, $p->{value};
                    last unless $tok && $tok->{type} eq ',';
                    $self->_next();
                }
                $self->_expect(')');
            }
            my $body = $self->_parse_block();
            return Brocken::AST::SubDecl->new(name => $name, params => \@params, body => $body, line => $line, col => $col);
        }

        if ($t eq 'KEYWORD' && $val eq 'fiber') {
            my @params;
            if ($tok && $tok->{type} eq '(') {
                $self->_next();
                while ($tok && $tok->{type} ne ')') {
                    my $p = $self->_expect('VAR');
                    push @params, $p->{value};
                    last unless $tok && $tok->{type} eq ',';
                    $self->_next();
                }
                $self->_expect(')');
            }
            my $body = $self->_parse_block();
            return Brocken::AST::Async::FiberBlock->new(params => \@params, body => $body, line => $line, col => $col);
        }

        if ($t eq 'KEYWORD' && $val eq 'yield') {
            my $expr;
            if ($tok && $tok->{type} ne ';' && $tok->{type} ne 'KEYWORD') {
                $expr = $self->_parse_expr(0);
            }
            return Brocken::AST::Async::Yield->new(expr => $expr, line => $line, col => $col);
        }

        if ($t eq '-'  || $t eq '+' || $t eq '!' || $t eq '~' || $t eq 'not') {
            my $bp = 15;
            my $operand = $self->_parse_expr($bp);
            return Brocken::AST::UnaryOp->new(op => $t, operand => $operand, line => $line, col => $col);
        }
        if ($t eq '++' || $t eq '--') {
            my $operand = $self->_parse_expr(17);
            return Brocken::AST::UnaryOp->new(op => $t, operand => $operand, line => $line, col => $col);
        }

        if ($t eq '(') {
            my $expr = $self->_parse_expr(0);
            $self->_expect(')');
            return $expr;
        }

        my $loc = $tok ? "{$tok->{line}:$tok->{col}}" : '{EOF}';
        die "Unexpected token '$t' ($val) at $loc";
    }

    method _parse_args () {
        my @args;
        while ($tok && $tok->{type} ne ')') {
            push @args, $self->_parse_expr(0);
            last unless $tok && $tok->{type} eq ',';
            $self->_next();
        }
        $self->_expect(')');
        return @args;
    }

    method _led ($op_tok, $left, $next_bp) {
        my $t   = $op_tok->{type};
        my $val = $op_tok->{value};

        # Ternary: cond ? then : else
        if ($t eq '?') {
            my $then = $self->_parse_expr(0);
            $self->_expect(':');
            my $else = $self->_parse_expr($next_bp);
            return Brocken::AST::Ternary->new(cond => $left, if_true => $then, if_false => $else, line => $op_tok->{line}, col => $op_tok->{col});
        }

        # Assignment
        if ($t eq '=' || ($t =~ /=$/ && $t !~ /^[=!<>]=$/)) {
            die "Can't assign to non-variable at {$op_tok->{line}:$op_tok->{col}}" unless $left->isa('Brocken::AST::Var');
            my $right = $self->_parse_expr($next_bp);
            if ($t eq '=') {
                return Brocken::AST::Assign->new(name => $left->name, expr => $right, line => $op_tok->{line}, col => $op_tok->{col});
            }
            my $op = substr $t, 0, -1;
            my $bin = Brocken::AST::BinOp->new(left => $left, op => $op, right => $right);
            return Brocken::AST::Assign->new(name => $left->name, expr => $bin, line => $op_tok->{line}, col => $op_tok->{col});
        }

        # Index: $x[expr]
        if ($t eq '[') {
            my $index = $self->_parse_expr(0);
            $self->_expect(']');
            return Brocken::AST::Index->new(target => $left, index => $index, line => $op_tok->{line}, col => $op_tok->{col});
        }

        # Hash key: $x{key}
        if ($t eq '{') {
            my $key = $self->_parse_expr(0);
            $self->_expect('}');
            return Brocken::AST::Index->new(target => $left, index => $key, line => $op_tok->{line}, col => $op_tok->{col});
        }

        # Function call: foo(args)
        if ($t eq '(') {
            my @args = $self->_parse_args();
            return Brocken::AST::Call->new(name => $val, args => \@args, line => $op_tok->{line}, col => $op_tok->{col});
        }

        # Method/deref arrow: $x->method or $x->{key} or $x->[idx]
        if ($t eq '->') {
            my $next_tok = $tok;
            if ($next_tok && $next_tok->{type} eq '{') {
                $self->_next();
                my $key = $self->_parse_expr(0);
                $self->_expect('}');
                return Brocken::AST::Index->new(target => $left, index => $key, line => $op_tok->{line}, col => $op_tok->{col});
            }
            if ($next_tok && $next_tok->{type} eq '[') {
                $self->_next();
                my $index = $self->_parse_expr(0);
                $self->_expect(']');
                return Brocken::AST::Index->new(target => $left, index => $index, line => $op_tok->{line}, col => $op_tok->{col});
            }
            if ($next_tok && ($next_tok->{type} eq 'IDENT' || $next_tok->{type} eq 'KEYWORD')) {
                $self->_next();
                my $method_name = $next_tok->{value};
                my @args;
                if ($tok && $tok->{type} eq '(') {
                    $self->_next();
                    @args = $self->_parse_args();
                }
                my $call = Brocken::AST::Call->new(name => $method_name, args => \@args);
                return Brocken::AST::BinOp->new(left => $left, op => '->', right => $call, line => $op_tok->{line}, col => $op_tok->{col});
            }
            die "Expected method name or {...} or [...] after -> at {$op_tok->{line}:$op_tok->{col}}";
        }

        # Binary operator (default)
        my $right = $self->_parse_expr($next_bp);
        return Brocken::AST::BinOp->new(left => $left, op => $t, right => $right, line => $op_tok->{line}, col => $op_tok->{col});
    }
}

1;
