use v5.42;
use Test2::V0 '!subtest';
use blib;
use Brocken;
use Brocken::Katsuro;
use Brocken::Katsuro::Platform;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Jenny::Lowerer::X86_64;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Win64 numbers argument positions 1-4 across both register files: the first
# argument is rcx or xmm0, the second rdx or xmm1, and so on, and the fifth
# argument and later go on the stack whatever their class.  SysV instead gives
# each class its own counter.  The two files were read with one counter each, so
# a mixed argument list landed in the wrong registers -- a float after an
# integer went to the second xmm rather than the position's xmm.
#
# The check lowers on any host and reads the physical registers off the moves.
# The callee of `g` has two hidden leading parameters, so the float `$y` is
# position 4 and belongs in xmm3; the old model put it in xmm0.  The literal
# argument is materialised straight into its argument register, so the
# destination of `fmov_gp2f` is that register.
my $win64 = Brocken::Katsuro::Platform::parse('x86_64-pc-windows-msvc');
my $sysv  = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
is(
    $win64->abi->argument_locations( [qw(int int float int float int)] ),
    [ 'rcx', 'rdx', 'xmm2', 'r9', [ 'stack', 0 ], [ 'stack', 1 ] ],
    'Win64 assigns positions across both register files and spills the fifth argument'
);
is(
    $sysv->abi->argument_locations( [qw(int int float int float int)] ),
    [ 'rdi', 'rsi', 'xmm0', 'rdx', 'xmm1', 'rcx' ],
    'SysV keeps an independent counter per register file'
);
my $module = Brocken->new->compile('sub g(i64 $x, f64 $y) -> f64 { return $y; } return g(7, 2.0);');
my %mf;
for my $func ( $module->functions->@* ) {
    next unless $func->blocks->@*;
    $mf{ $func->name } = Brocken::Jenny::Lowerer::X86_64->new( platform => $win64 )->lower($func);
}
my ($callee) = grep {/^g$/} keys %mf;
my ($caller) = grep {/^_BROCKEN_ENTRY$/} keys %mf;
if ( !$callee || !$caller ) {
    fail('the callee and its caller were both lowered');
    done_testing;
    exit;
}
ok( 1, 'the callee and its caller were both lowered' );

# The callee captures the f64 parameter out of the xmm for its position.
is( [ phys_operands( $mf{$callee}, 'fmov', 1 ) ], ['xmm3'], 'the callee reads its f64 parameter from xmm3, not xmm0' );

# The caller materialises the literal into the argument register itself.
is( [ phys_operands( $mf{$caller}, 'fmov_gp2f', 0 ) ], ['xmm3'], 'the caller places the literal f64 argument in xmm3' );
ok( scalar( grep { $_ eq 'xmm0' || $_ eq 'xmm1' } phys_operands( $mf{$caller}, 'fmov_gp2f', 0 ) ) == 0, 'no argument is placed in xmm0 or xmm1' );

# The return still comes back in the floating-point return register.
ok( scalar( grep { $_ eq 'xmm0' } phys_operands( $mf{$callee}, 'fmov', 0 ) ), 'the callee returns its f64 result in xmm0' );
done_testing;

# Every physical register named in the requested operand position of every
# instruction with the given opcode.
sub phys_operands ( $mf, $opcode, $which ) {
    my @names;
    for my $mbb ( $mf->blocks->@* ) {
        for my $inst ( $mbb->instructions->@* ) {
            next unless $inst->opcode eq $opcode;
            my @ops = $inst->operands->@*;
            next unless @ops > $which;
            my $op = $ops[$which];
            push @names, $op->value if $op->kind eq 'phys_reg';
        }
    }
    return @names;
}
