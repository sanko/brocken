use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Type;

class Brocken::Compiler::SemanticAnalyzer {
    field $symbols : reader : param;

    method analyze($ast) {
        for my $stmt (@$ast) {
            $self->analyze_statement($stmt);
        }
        return $ast;
    }

    method analyze_statement($stmt) {
        if ($stmt->isa('Brocken::AST::ControlFlow::Assignment')) {
            my $val_type = $self->analyze_expr($stmt->value);
            my $var_name = $stmt->variable->value;
            my $var_type = $self->symbols->lookup($var_name);
            
            if ($var_type && $var_type->to_string eq 'Any' && $val_type->to_string ne 'Any') {
                # say "DEBUG: Refining $var_name from Any to " . $val_type->to_string;
                # We need a way to update the symbol table. 
                # Currently define() overwrites, which is what we want for refinement in the same scope.
                $self->symbols->define($var_name, $val_type);
                $stmt->variable->set_type($val_type);
            } else {
                $stmt->variable->set_type($var_type // Brocken::Type::Any->new(name => 'Any'));
            }
        }
        elsif ($stmt->isa('Brocken::AST::ControlFlow::IfStatement')) {
            $self->analyze_expr($stmt->condition);
            $self->analyze_block($stmt->then_block);
            $self->analyze_block($stmt->else_block) if $stmt->else_block;
        }
        elsif ($stmt->isa('Brocken::AST::ControlFlow::WhileStatement')) {
            $self->analyze_expr($stmt->condition);
            $self->analyze_block($stmt->body_block);
        }
        elsif ($stmt->isa('Brocken::AST::ControlFlow::Subroutine')) {
            $self->analyze_block($stmt->body);
        }
        elsif ($stmt->isa('Brocken::AST::ControlFlow::SimpleStatement')) {
            for my $arg (@{$stmt->args}) {
                $self->analyze_expr($arg);
            }
        }
    }

    method analyze_block($block) {
        # Note: SymbolTable handles scope pushing/popping if we were doing this during parsing,
        # but here we might need to manually trigger scope entry if we were re-walking.
        # For now, we assume the SymbolTable is already populated correctly from the Parse phase.
        for my $s (@{$block->statements}) {
            $self->analyze_statement($s);
        }
    }

    method analyze_expr($expr) {
        if ($expr->isa('Brocken::AST::Expr::Literal')) {
            # ... existing logic ...
            if ($expr->value =~ /^\d+$/) {
                $expr->set_type(Brocken::Type::Registry::get_type('Int'));
            } elsif ($expr->value =~ /^\d+\.\d+$/) {
                $expr->set_type(Brocken::Type::Registry::get_type('Double'));
            } else {
                $expr->set_type(Brocken::Type::Registry::get_type('String'));
            }
        }
        elsif ($expr->isa('Brocken::AST::Expr::Variable')) {
            my $type = $self->symbols->lookup($expr->value);
            die "Undefined variable " . $expr->value unless $type;
            $expr->set_type($type);
        }
        elsif ($expr->isa('Brocken::AST::Expr::BinaryOp')) {
            my $left_type  = $self->analyze_expr($expr->left);
            my $right_type = $self->analyze_expr($expr->right);
            
            # Simple promotion rules for primitives
            if ($left_type->isa('Brocken::Type::Primitive') && $right_type->isa('Brocken::Type::Primitive')) {
                if ($left_type->to_string eq 'Double' || $right_type->to_string eq 'Double') {
                    $expr->set_type(Brocken::Type::Registry::get_type('Double'));
                } else {
                    $expr->set_type(Brocken::Type::Registry::get_type('Int'));
                }
            } else {
                # Fallback for complex types or unknown
                $expr->set_type(Brocken::Type::Registry::get_type('Any'));
            }
        }
        elsif ($expr->isa('Brocken::AST::Expr::UnaryOp')) {
            $expr->set_type($self->analyze_expr($expr->expr));
        }
        elsif ($expr->isa('Brocken::AST::Expr::EvalCall')) {
            $expr->set_type(Brocken::Type::Registry::get_type('Any'));
        }
        elsif ($expr->isa('Brocken::AST::Expr::BuiltinCall')) {
            for my $arg (@{$expr->args}) {
                $self->analyze_expr($arg);
            }
            $expr->set_type(Brocken::Type::Registry::get_type('Any'));
        }
        return $expr->type;
    }
}
1;
