use v5.38;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Core::AST;

class Brocken::Core::Optimizer {

    # Recursively folds literal values across an AST expression tree
    method fold_constants($node) {
        return $node unless defined $node;

        # If it is a binary arithmetic operation, check if we can fold it
        if ( $node->isa('Brocken::Core::AST::BinaryOp') ) {

            # Fold left and right branches first
            my $left_folded  = $self->fold_constants( $node->left );
            my $right_folded = $self->fold_constants( $node->right );

            # If both sides are Literal nodes, evaluate them
            if ( $left_folded->isa('Brocken::Core::AST::Literal') && $right_folded->isa('Brocken::Core::AST::Literal') ) {
                my $lval = $left_folded->value;
                my $rval = $right_folded->value;
                my $op   = $node->op;

                # Perform the operation safely
                my $result;
                if    ( $op eq '+' ) { $result = $lval + $rval; }
                elsif ( $op eq '-' ) { $result = $lval - $rval; }
                elsif ( $op eq '*' ) { $result = $lval * $rval; }
                elsif ( $op eq '/' ) {
                    die 'Compile Error: Division by zero at line ' . $node->line . "\n" if $rval == 0;
                    $result = $lval / $rval;
                }

                # Return the folded literal, retaining the original node's line and column!
                return Brocken::Core::AST::Literal->new( value => $result, line => $node->line, col => $node->col );
            }

            # If they couldn't be folded, return a new BinaryOp with updated sub-branches
            return Brocken::Core::AST::BinaryOp->new(
                op    => $node->op,
                left  => $left_folded,
                right => $right_folded,
                line  => $node->line,
                col   => $node->col
            );
        }

        # Handle assignments
        if ( $node->isa('Brocken::Core::AST::Assign') ) {
            my $right_folded = $self->fold_constants( $node->right );
            return Brocken::Core::AST::Assign->new(
                op    => $node->op,
                left  => $node->left,
                right => $right_folded,
                line  => $node->line,
                col   => $node->col
            );
        }

        # Literal and Variable nodes are returned as-is
        return $node;
    }
}
1;
