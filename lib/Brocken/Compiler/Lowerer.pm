use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::IR;

class Brocken::Compiler::Lowerer {
    field $vreg_count    = 0;
    field $label_count   = 0;
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
        for my $stmt (@$ast) {
            $self->lower_statement($stmt);
        }
        if ( !$current_block->terminator ) {
            $current_block->set_terminator( Brocken::IR::Return->new( val => 'undef' ) );
        }
        return $cfg;
    }

    method lower_statement ($stmt) {
        if ( $stmt->isa('Brocken::AST::ControlFlow::Assignment') ) {
            my $val_reg = $self->lower_expr( $stmt->value );
            $current_block->add_instruction( Brocken::IR::Store->new( var => $stmt->variable->value, src => $val_reg ) );
        }
        elsif ( $stmt->isa('Brocken::AST::ControlFlow::IfStatement') ) {
            my $cond_reg = $self->lower_expr( $stmt->condition );
            my $l_then   = $self->new_label();
            my $l_else   = $self->new_label();
            my $l_end    = $self->new_label();

            $current_block->set_terminator( Brocken::IR::Branch->new( label => $l_else, cond => $cond_reg ) );

            # Then block
            $self->start_block($l_then);
            for my $s ( @{ $stmt->then_block->statements } ) {
                $self->lower_statement($s);
            }
            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Jump->new( label => $l_end ) );
            }

            # Else block
            $self->start_block($l_else);
            if ( $stmt->else_block ) {
                for my $s ( @{ $stmt->else_block->statements } ) {
                    $self->lower_statement($s);
                }
            }
            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Jump->new( label => $l_end ) );
            }

            # End block
            $self->start_block($l_end);
        }
        elsif ( $stmt->isa('Brocken::AST::ControlFlow::SimpleStatement') ) {
            my @arg_regs;
            for my $arg ( @{ $stmt->args } ) {
                push @arg_regs, $self->lower_expr($arg);
            }
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => $stmt->keyword, args => \@arg_regs ) );
        }
        elsif ( $stmt->isa('Brocken::AST::ControlFlow::Subroutine') ) {
            for my $s ( @{ $stmt->body->statements } ) {
                $self->lower_statement($s);
            }
        }
        elsif ( $stmt->isa('Brocken::AST::ControlFlow::WhileStatement') ) {
            my $l_cond = $self->new_label();
            my $l_body = $self->new_label();
            my $l_end  = $self->new_label();

            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Jump->new( label => $l_cond ) );
            }

            # Condition block
            $self->start_block($l_cond);
            my $cond_reg = $self->lower_expr( $stmt->condition );
            $current_block->set_terminator( Brocken::IR::Branch->new( label => $l_end, cond => $cond_reg ) );

            # Body block
            $self->start_block($l_body);
            for my $s ( @{ $stmt->body_block->statements } ) {
                $self->lower_statement($s);
            }
            if ( !$current_block->terminator ) {
                $current_block->set_terminator( Brocken::IR::Jump->new( label => $l_cond ) );
            }

            # End block
            $self->start_block($l_end);
        }
    }

    method lower_expr ($expr) {
        if ( $expr->isa('Brocken::AST::Expr::Literal') ) {
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => $expr->value, op => '', rhs => '' ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::BinaryOp') ) {
            my $left  = $self->lower_expr( $expr->left );
            my $right = $self->lower_expr( $expr->right );
            my $vreg  = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => $left, op => $expr->operator, rhs => $right ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::UnaryOp') ) {
            my $sub_expr = $self->lower_expr( $expr->expr );
            my $vreg     = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Assign->new( dest => $vreg, lhs => $sub_expr, op => $expr->operator, rhs => '' ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::Variable') ) {
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Load->new( dest => $vreg, var => $expr->name ) );
            return $vreg;
        }
        elsif ( $expr->isa('Brocken::AST::Expr::BuiltinCall') ) {
            my @arg_regs;
            for my $arg ( @{ $expr->args } ) {
                push @arg_regs, $self->lower_expr($arg);
            }
            my $vreg = $self->new_vreg();
            $current_block->add_instruction( Brocken::IR::Call->new( dest => $vreg, func => $expr->name, args => \@arg_regs ) );
            return $vreg;
        }
        die "Cannot lower expr: " . ref($expr);
    }
}
1;
 1;
