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
        elsif ( $stmt->isa('Brocken::AST::OOP::Method') ) {
            for my $s ( @{ $stmt->body->statements } ) {
                $self->lower_stmt($s);
            }
        }
        elsif ( $stmt->isa('Brocken::AST::Stmt::While') ) {
            my $l_cond = $self->new_label();
            my $l_body = $self->new_label();
            my $l_end  = $self->new_label();
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
