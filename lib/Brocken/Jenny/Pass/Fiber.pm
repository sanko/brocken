use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
#
class Brocken::Jenny::Pass::Fiber v0.0.1 {
    use Brocken::Lindsay::IR;

    method needs_lowering($ir_func) {
        for my $block ( $ir_func->blocks->@* ) {
            for my $inst ( $block->instructions->@* ) {
                return 1 if $inst->isa('Brocken::Lindsay::IR::Instruction::FiberYield');
            }
        }
        return 0;
    }

    method has_yield($ir_func) {
        return $self->needs_lowering($ir_func);
    }

    method lower($ir_func) {
        return $ir_func;
    }
} 1;
