use v5.42;
use Test2::V0 '!subtest';
use blib;
use Brocken;
use Brocken::Katsuro;
use Brocken::Katsuro::Platform;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Jenny::Lowerer::RISCV64;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# RISC-V passes a floating-point argument in fa0-fa7, which the encoder spells f10-f17, and returns one in fa0 (f10).
# The register file was declared from f0 instead, so a float argument landed in ft0, a scratch register the callee is
# free to clobber.  Nothing failed internally because both halves agreed on the wrong register; it only broke against
# hand-written or external code.
#
# The two register files are indexed independently, so this does not have to be the same list as a0-a7.  The check
# lowers on any host and reads the physical registers off the moves, which is where the choice becomes visible: the
# integer file would have hidden it behind a `mv` and the offsets in 3300 never see which register a value arrived in.
my $platform = Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu');
my $abi      = $platform->abi;
is( $abi->fp_param_registers, [qw(f10 f11 f12 f13 f14 f15 f16 f17)], 'RISC-V floating-point arguments are fa0-fa7 (f10-f17)' );
is( $abi->fp_return_register, 'f10',                                 'RISC-V floating-point return is fa0 (f10)' );
my $module = Brocken->new->compile('sub g(f64 $a, f64 $b) -> f64 { return $b; } return g(1.0, 6.0);');
my %mf;
for my $func ( $module->functions->@* ) {
    next unless $func->blocks->@*;
    $mf{ $func->name } = Brocken::Jenny::Lowerer::RISCV64->new( platform => $platform )->lower($func);
}
my ($callee) = grep {/^g$/} keys %mf;
my ($caller) = grep {/^_BROCKEN_ENTRY$/} keys %mf;
if ( !$callee || !$caller ) {
    fail('the callee and its caller were both lowered');
    done_testing;
    exit;
}
ok( 1, 'the callee and its caller were both lowered' );

# In the callee the parameters are captured out of the argument registers.
is( [ sort { $a cmp $b } phys_operands( $mf{$callee}, 'fmov', 1 ) ], [qw(f10 f11)], 'the callee reads its two f64 parameters from fa0 and fa1' );

# A literal argument is materialised straight into the register it goes to, so the destination of the `fmov_gp2f` is the
# argument register itself.
is( [ sort { $a cmp $b } phys_operands( $mf{$caller}, 'fmov_gp2f', 0 ) ],
    [qw(f10 f11)], 'the caller places two literal f64 arguments in fa0 and fa1' );
ok( scalar( grep { $_ eq 'f0' || $_ eq 'f1' } phys_operands( $mf{$caller}, 'fmov_gp2f', 0 ) ) == 0, 'no argument is placed in ft0/ft1' );

# The return goes back in fa0, and the caller reads it from there.
ok( scalar( grep { $_ eq 'f10' } phys_operands( $mf{$callee}, 'fmov', 0 ) ), 'the callee returns its f64 result in fa0' );
ok( scalar( grep { $_ eq 'f10' } phys_operands( $mf{$caller}, 'fmov', 1 ) ), 'the caller reads the f64 result from fa0' );
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
