# lib/Brocken/Optimizer.pm
use v5.38;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Core::AST;

class Brocken::Core::Optimizer {

    method fold_constants($node) {
        return $node unless defined $node;
        if ( $node->isa('Brocken::Core::AST::BinaryOp') ) {
            my $left_folded  = $self->fold_constants( $node->left );
            my $right_folded = $self->fold_constants( $node->right );
            if ( $left_folded->isa('Brocken::Core::AST::Literal') && $right_folded->isa('Brocken::Core::AST::Literal') ) {
                my $lval = $left_folded->value;
                my $rval = $right_folded->value;
                my $op   = $node->op;
                my $result;
                if    ( $op eq '+' ) { $result = $lval + $rval; }
                elsif ( $op eq '-' ) { $result = $lval - $rval; }
                elsif ( $op eq '*' ) { $result = $lval * $rval; }
                elsif ( $op eq '/' ) {
                    die "Compile Error: Division by zero at line " . $node->line . "\n" if $rval == 0;
                    $result = $lval / $rval;
                }
                return Brocken::Core::AST::Literal->new( value => $result, line => $node->line, col => $node->col, );
            }
            return Brocken::Core::AST::BinaryOp->new(
                op    => $node->op,
                left  => $left_folded,
                right => $right_folded,
                line  => $node->line,
                col   => $node->col,
            );
        }
        if ( $node->isa('Brocken::Core::AST::Assign') ) {
            my $right_folded = $self->fold_constants( $node->right );
            return Brocken::Core::AST::Assign->new(
                op    => $node->op,
                left  => $node->left,
                right => $right_folded,
                line  => $node->line,
                col   => $node->col,
            );
        }
        return $node;
    }
}
1;
