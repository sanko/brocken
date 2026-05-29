use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::AST;
use Brocken::IR;

class Brocken::Compiler::Lowerer {
    field $vreg_count  = 0;
    field $label_count = 0;
    field $cfg;
    field $current_block;
    field @loop_stack;    # Each entry: { redo => label, next => label, last => label }
    method new_vreg()  { return sprintf( "v%d", $vreg_count++ ); }
    method new_label() { return sprintf( "L%d", $label_count++ ); }

    method start_block ($name) {
        my $block = Brocken::IR::BasicBlock->new( name => $name );
        $cfg->add_block($block);
        $current_block = $block;
        return $block;
    }

    method lower ($ast) {
        $cfg = Brocken::IR::CFG->new();
        $self->start_block('entry');
        $cfg->set_entry_block($current_block);
        if ( ref($ast) eq 'ARRAY' ) {
            for my $stmt (@$ast) {
                $self->lower_stmt($stmt);
            }
            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Return->new( val => 'undef' ) );
            }
            return $cfg;
        }
        if ( $ast->isa('Brocken::AST::Stmt::Program') ) {
            for my $stmt ( @{ $ast->statements } ) {
                $self->lower_stmt($stmt);
            }
        }
        else {
            for my $stmt (@$ast) {
                $self->lower_stmt($stmt);
            }
        }
        if ( !$current_block->terminator ) {
            $current_block->set_terminator( Brocken::IR::Return->new( val => 'undef' ) );
        }
        return $cfg;
    }

    method lower_stmt ($stmt) {
        if ( $stmt->isa('Brocken::AST::Stmt::Assignment') ) {
            my $val_reg = $self->lower_expr( $stmt->value );
            $current_block->add_instruction( Brocken::IR::Store->new( var => '$' . $stmt->name, src => $val_reg ) );
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::VarDecl') ) {
            if ( defined $stmt->value ) {
                my $val_reg = $self->lower_expr( $stmt->value );
                $current_block->add_instruction( Brocken::IR::Store->new( var => '$' . $stmt->name, src => $val_reg ) );
            }
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::OurDecl') ) {
            if ( defined $stmt->value ) {
                my $val_reg = $self->lower_expr( $stmt->value );
                $current_block->add_instruction( Brocken::IR::Store->new( var => '$' . $stmt->name, src => $val_reg ) );
            }
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::StateDecl') ) {
            if ( defined $stmt->value ) {
                my $val_reg = $self->lower_expr( $stmt->value );
                $current_block->add_instruction( Brocken::IR::Store->new( var => '$' . $stmt->name, src => $val_reg ) );
            }
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::If') ) {
            my $cond_reg = $self->lower_expr( $stmt->condition );
            my $l_then   = $self->new_label();
            my $l_else   = $self->new_label();
            my $l_end    = $self->new_label();
            $current_block->set_terminator( Brocken::IR::Branch->new( label => $l_else, cond => $cond_reg ) );
            $self->start_block($l_then);
            for my $s ( @{ $stmt->then_block->statements } ) {
                $self->lower_stmt($s);
            }
            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Jump->new( label => $l_end ) );
            }
            $self->start_block($l_else);
            if ( $stmt->else_block ) {
                for my $s ( @{ $stmt->else_block->statements } ) {
                    $self->lower_stmt($s);
                }
            }
            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Jump->new( label => $l_end ) );
            }
            $self->start_block($l_end);
        }
        elsif ( $stmt->isa('Brocken::AST::Expr::Call') &&
            $stmt->name eq 'spawn_thread' &&
            @{ $stmt->args } &&
            $stmt->args->[0]->isa('Brocken::AST::OOP::AnonSub') ) {
            $self->_lower_spawn_thread( $stmt->args->[0] );
        }
        elsif ( $stmt->isa('Brocken::AST::Expr::Call') ) {
            my @arg_regs;
            for my $arg ( @{ $stmt->args } ) {
                push @arg_regs, $self->lower_expr($arg);
            }
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => $stmt->name, args => \@arg_regs ) );
        }
        elsif ( $stmt->isa('Brocken::AST::Expr::MethodCall') ) {
            $self->lower_expr($stmt);
        }
        elsif ( $stmt->isa('Brocken::AST::Expr::IndexExpr') ) {
            $self->lower_expr($stmt);
        }
        elsif ( $stmt->isa('Brocken::AST::OOP::Method') ) {
            for my $s ( @{ $stmt->body->statements } ) {
                $self->lower_stmt($s);
            }
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::While') ) {
            my $l_cond = $self->new_label();
            my $l_body = $self->new_label();
            my $l_end  = $self->new_label();
            push @loop_stack, { redo => $l_body, next => $l_cond, last => $l_end };
            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Jump->new( label => $l_cond ) );
            }
            $self->start_block($l_cond);
            my $cond_reg = $self->lower_expr( $stmt->condition );
            $current_block->set_terminator( Brocken::IR::Branch->new( label => $l_end, cond => $cond_reg ) );
            $self->start_block($l_body);
            for my $s ( @{ $stmt->body->statements } ) {
                $self->lower_stmt($s);
            }
            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Jump->new( label => $l_cond ) );
            }
            $self->start_block($l_end);
            pop @loop_stack;
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::For') ) {
            my $f = $stmt;
            if ( defined $f->init ) {
                $self->lower_stmt($f->init);
            }
            my $l_cond = $self->new_label();
            my $l_body = $self->new_label();
            my $l_step = $self->new_label();
            my $l_end  = $self->new_label();
            push @loop_stack, { redo => $l_body, next => $l_step, last => $l_end };
            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Jump->new( label => $l_cond ) );
            }
            $self->start_block($l_cond);
            if ( defined $f->condition ) {
                my $cond_reg = $self->lower_expr($f->condition);
                $current_block->set_terminator( Brocken::IR::Branch->new( label => $l_end, cond => $cond_reg ) );
            }
            $self->start_block($l_body);
            $self->lower_stmt( $f->body );
            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Jump->new( label => $l_step ) );
            }
            $self->start_block($l_step);
            if ( defined $f->step ) {
                $self->lower_stmt($f->step);
            }
            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Jump->new( label => $l_cond ) );
            }
            $self->start_block($l_end);
            pop @loop_stack;
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::Next') ) {
            my $labels = $loop_stack[-1];
            die 'next outside loop' unless $labels;
            $current_block->set_terminator( Brocken::IR::Jump->new( label => $labels->{next} ) );
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::Last') ) {
            my $labels = $loop_stack[-1];
            die 'last outside loop' unless $labels;
            $current_block->set_terminator( Brocken::IR::Jump->new( label => $labels->{last} ) );
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::Redo') ) {
            my $labels = $loop_stack[-1];
            die 'redo outside loop' unless $labels;
            $current_block->set_terminator( Brocken::IR::Jump->new( label => $labels->{redo} ) );
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::Block') ) {
            for my $s ( @{ $stmt->statements } ) {
                $self->lower_stmt($s);
            }
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::Return') ) {
            if ( defined $stmt->expr ) {
                my $val_reg = $self->lower_expr( $stmt->expr );
                $current_block->set_terminator( Brocken::IR::Return->new( val => $val_reg ) );
            }
            else {
                $current_block->set_terminator( Brocken::IR::Return->new( val => 'undef' ) );
            }
        }
        elsif ( $stmt->isa('Brocken::AST::Async::FiberBlock') ) {
            $self->lower_stmt( $stmt->body );
        }
        elsif ( $stmt->isa('Brocken::AST::Async::Yield') ) {
            if ( defined $stmt->expr ) {
                my $val_reg = $self->lower_expr( $stmt->expr );
                $current_block->set_terminator( Brocken::IR::Return->new( val => $val_reg ) );
            }
            else {
                $current_block->set_terminator( Brocken::IR::Return->new( val => 'undef' ) );
            }
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::Exit') ) {
            if ( defined $stmt->expr ) {
                my $val_reg = $self->lower_expr( $stmt->expr );
                my $vreg    = $self->new_vreg();
                $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'exit', args => [$val_reg] ) );
            }
            else {
                my $vreg = $self->new_vreg();
                $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'exit', args => [] ) );
            }
        }
        elsif ( $stmt->isa('Brocken::AST::Exception::Die') ) {
            if ( defined $stmt->exception ) {
                my $val_reg = $self->lower_expr( $stmt->exception );
                my $vreg    = $self->new_vreg();
                $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'die', args => [$val_reg] ) );
            }
            else {
                my $vreg = $self->new_vreg();
                $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'die', args => [] ) );
            }
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::Eval') ) {
            die 'Eval is disabled';
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::Yada') ) {
            my $vreg = $self->new_vreg();
            my $msg  = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $msg, lhs => 'Unimplemented', op => '', rhs => '' ) );
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'die', args => [$msg] ) );
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::Map') ) {
            my $closure = $self->lower_expr( $stmt->expr );
            my $source  = $self->lower_expr( $stmt->source );
            my $vreg    = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'map', args => [$closure, $source] ) );
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::Defer') ) {
            for my $s ( @{ $stmt->block->statements } ) {
                $self->lower_stmt($s);
            }
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::Use') ) {
            warn "Use of module '${\$stmt->package}' not supported at compile time";
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => 1, op => '', rhs => '' ) );
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::Require') ) {
            warn "Require of module '${\$stmt->package}' not supported at compile time";
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => 1, op => '', rhs => '' ) );
        }
        elsif ( $stmt->isa('Brocken::AST::Exception::TryCatch') ) {
            for my $s ( @{ $stmt->try_block->statements } ) {
                $self->lower_stmt($s);
            }
            if ( $stmt->catch_block ) {
                for my $s ( @{ $stmt->catch_block->statements } ) {
                    $self->lower_stmt($s);
                }
            }
            if ( $stmt->finally_block ) {
                for my $s ( @{ $stmt->finally_block->statements } ) {
                    $self->lower_stmt($s);
                }
            }
        }
        elsif ( $stmt->isa('Brocken::AST::OOP::ClassDecl') ) {
            for my $method ( @{ $stmt->methods } ) {
                $self->lower_stmt($method);
            }
            my $name_vr = $self->lower_expr( Brocken::AST::Expr::StrLiteral->new( value => $stmt->name, type => 'String' ) );
            my $vreg    = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'class_register', args => [$name_vr] ) );
        }
        elsif ( $stmt->isa('Brocken::AST::NativeDecl') ) {
            die "NativeDecl (FFI) not supported";
        }
        else {
            die "Cannot lower statement: " . ref($stmt);
        }
    }

    method _lower_spawn_thread ($sub) {
        my $thread_label = $self->new_label();
        my $after_label  = $self->new_label();
        $current_block->set_terminator( Brocken::IR::Jump->new( label => $after_label ) );
        $self->start_block($thread_label);
        for my $s ( @{ $sub->body->statements } ) {
            $self->lower_stmt($s);
        }
        if ( !$current_block->terminator ) {
            $current_block->set_terminator( Brocken::IR::Return->new( val => 'EXIT_THREAD' ) );
        }
        $self->start_block($after_label);
        my $vreg = $self->new_vreg();
        $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => $thread_label, op => '', rhs => '' ) );
        $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'spawn_thread', args => [$vreg] ) );
        return $vreg;
    }

    method lower_expr ($expr) {
        if ( $expr->isa('Brocken::AST::Expr::IntLiteral') ) {
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => $expr->value, op => '', rhs => '' ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::FloatLiteral') ) {
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => $expr->value, op => '', rhs => '' ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::StrLiteral') ) {
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => $expr->value, op => '', rhs => '' ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::NilLiteral') ) {
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => 'undef', op => '', rhs => '' ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::BinOp') ) {
            my $left  = $self->lower_expr( $expr->left );
            my $right = $self->lower_expr( $expr->right );
            my $vreg  = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => $left, op => $expr->op, rhs => $right ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::UnaryOp') ) {
            my $sub_expr = $self->lower_expr( $expr->expr );
            my $vreg     = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => $sub_expr, op => $expr->op, rhs => '' ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::Ternary') ) {
            my $cond_reg  = $self->lower_expr( $expr->cond );
            my $l_else    = $self->new_label();
            my $l_end     = $self->new_label();
            my $result_vr = $self->new_vreg();
            $current_block->set_terminator( Brocken::IR::Branch->new( label => $l_else, cond => $cond_reg ) );
            $self->start_block($self->new_label());
            my $then_vr = $self->lower_expr( $expr->then );
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $result_vr, lhs => $then_vr, op => '', rhs => '' ) );
            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Jump->new( label => $l_end ) );
            }
            $self->start_block($l_else);
            my $else_vr = $self->lower_expr( $expr->else );
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $result_vr, lhs => $else_vr, op => '', rhs => '' ) );
            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Jump->new( label => $l_end ) );
            }
            $self->start_block($l_end);
            return $result_vr;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::Var') ) {
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Load->new( dest => $vreg, var => '$' . $expr->name ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::Call') &&
            $expr->name eq 'spawn_thread' &&
            @{ $expr->args } &&
            $expr->args->[0]->isa('Brocken::AST::OOP::AnonSub') ) {
            return $self->_lower_spawn_thread( $expr->args->[0] );
        }
        elsif ( $expr->isa('Brocken::AST::Expr::Call') ) {
            my @arg_regs;
            for my $arg ( @{ $expr->args } ) {
                push @arg_regs, $self->lower_expr($arg);
            }
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => $expr->name, args => \@arg_regs ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::MethodCall') ) {
            my $obj_vreg = $self->lower_expr( $expr->object );
            my @arg_regs;
            for my $arg ( @{ $expr->args } ) {
                push @arg_regs, $self->lower_expr($arg);
            }
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'method_call', args => [ $obj_vreg, $expr->method, @arg_regs ] ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::IndexExpr') ) {
            my $src_vreg = $self->lower_expr( $expr->source );
            my $idx_vreg = $self->lower_expr( $expr->index );
            my $vreg     = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'index_get', args => [ $src_vreg, $idx_vreg ] ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::AnonCall') ) {
            my $invocant = $self->lower_expr( $expr->invocant );
            my @arg_regs;
            for my $arg ( @{ $expr->args } ) {
                push @arg_regs, $self->lower_expr($arg);
            }
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'anon_call', args => [ $invocant, @arg_regs ] ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::ArrayLiteral') ) {
            my @elem_regs;
            for my $elem ( @{ $expr->elements } ) {
                push @elem_regs, $self->lower_expr($elem);
            }
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'array_literal', args => [ scalar @elem_regs, @elem_regs ] ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::HashLiteral') ) {
            my @pair_regs;
            for my $pair ( @{ $expr->pairs } ) {
                push @pair_regs, $self->lower_expr( $pair->{key} );
                push @pair_regs, $self->lower_expr( $pair->{value} );
            }
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'hash_literal', args => \@pair_regs ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::TupleLiteral') ) {
            my @elem_regs;
            for my $elem ( @{ $expr->elements } ) {
                push @elem_regs, $self->lower_expr($elem);
            }
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'tuple_literal', args => [ scalar @elem_regs, @elem_regs ] ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::Exists') ) {
            my $sub_vreg = $self->lower_expr( $expr->expr );
            my $vreg     = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'exists', args => [$sub_vreg] ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::Delete') ) {
            my $sub_vreg = $self->lower_expr( $expr->expr );
            my $vreg     = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'delete', args => [$sub_vreg] ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Exception::Die') ) {
            if ( defined $expr->exception ) {
                my $val_reg = $self->lower_expr( $expr->exception );
                my $vreg    = $self->new_vreg();
                $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'die', args => [$val_reg] ) );
                return $vreg;
            }
            else {
                my $vreg = $self->new_vreg();
                $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => 'die', args => [] ) );
                return $vreg;
            }
        }
        elsif ( $expr->isa('Brocken::AST::Async::FiberBlock') ) {
            $self->lower_expr( $expr->body );
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => 'undef', op => '', rhs => '' ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::OOP::AnonSub') ) {
            $self->lower_stmt( $expr->body );
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => 'undef', op => '', rhs => '' ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Async::Yield') ) {
            if ( defined $expr->expr ) {
                my $val_reg = $self->lower_expr( $expr->expr );
                $current_block->set_terminator( Brocken::IR::Return->new( val => $val_reg ) );
            }
            else {
                $current_block->set_terminator( Brocken::IR::Return->new( val => 'undef' ) );
            }
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => 'undef', op => '', rhs => '' ) );
            return $vreg;
        }
        die "Cannot lower expr: " . ref($expr);
    }
}
1;
