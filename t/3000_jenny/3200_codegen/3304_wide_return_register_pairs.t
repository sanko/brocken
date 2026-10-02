use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro;
use Brocken::Katsuro::Platform;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
use Brocken::Jenny::Lowerer::X86_64;
use Brocken::Jenny::Lowerer::ARM64;
use Brocken::Jenny::Lowerer::RISCV64;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# A 128-bit value occupies a consecutive register pair.  The pair a result
# comes back in was hard-coded in each lowerer (rdx on x86-64, x1 on ARM64, a1
# on RISC-V); the parameter pair came from an index into `param_registers`.  The
# ABI now answers both, so the lowerers no longer name a second register behind
# its back.
#
# The check lowers an i128-returning program on every backend from any host and
# reads the pair off the moves: the callee writes the result pair and the caller
# reads the same pair.  The comment tags the two halves, so the register is
# taken from the operand rather than assumed.
my %lowerer_for = (
    'x86_64-pc-linux-gnu'       => 'Brocken::Jenny::Lowerer::X86_64',
    'x86_64-pc-windows-msvc'    => 'Brocken::Jenny::Lowerer::X86_64',
    'aarch64-unknown-linux-gnu' => 'Brocken::Jenny::Lowerer::ARM64',
    'riscv64-unknown-linux-gnu' => 'Brocken::Jenny::Lowerer::RISCV64',
);
is( [ Brocken::Katsuro::Platform::ABI->new->return_pair_registers ],                             [], 'the base ABI names no wide return pair' );
is( [ Brocken::Katsuro::Platform::ABI->new->param_pair_registers(0) ],                           [], 'the base ABI names no wide parameter pair' );
is( [ Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu')->abi->return_pair_registers ],    [qw(rax rdx)], 'x86-64 returns an i128 in rax:rdx' );
is( [ Brocken::Katsuro::Platform::parse('x86_64-pc-windows-msvc')->abi->return_pair_registers ], [qw(rax rdx)], 'Win64 returns an i128 in rax:rdx' );
is( [ Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu')->abi->return_pair_registers ], [qw(x0 x1)], 'ARM64 returns an i128 in x0:x1' );
is( [ Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu')->abi->return_pair_registers ], [qw(a0 a1)], 'RISC-V returns an i128 in a0:a1' );
my $sysv = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu')->abi;
is( [ $sysv->param_pair_registers(0) ], [qw(rdi rsi)], 'SysV pairs the first two integer parameter registers' );
is( [ $sysv->param_pair_registers(4) ], [qw(r8 r9)],   'SysV pairs the last two integer parameter registers' );
is( [ $sysv->param_pair_registers(5) ], [],            'SysV has no pair once only one integer register is left' );
my $win64 = Brocken::Katsuro::Platform::parse('x86_64-pc-windows-msvc')->abi;
is( [ $win64->param_pair_registers(0) ], [qw(rcx rdx)], 'Win64 pairs the first two integer parameter registers' );
is( [ $win64->param_pair_registers(3) ], [],            'Win64 has no pair once only one integer register is left' );

# A 128-bit result for every backend, lowered on any host.
my $src = "use feature 'brocken_native_types';\n" . "sub g(i64 \$x) -> i128 { my i128 \$v = \$x; return \$v; }\n" . "return g(5);\n";
for my $arch ( sort keys %lowerer_for ) {
    my $platform = Brocken::Katsuro::Platform::parse($arch);
    my $abi      = $platform->abi;
    my $cls      = $lowerer_for{$arch};
    my $module   = Brocken::Compiler->new->compile($src);
    my %mf;
    for my $func ( $module->functions->@* ) {
        next unless $func->blocks->@*;
        $mf{ $func->name } = $cls->new( platform => $platform )->lower($func);
    }
    my ($callee) = grep {/^g$/} keys %mf;
    my ($caller) = grep {/^_BROCKEN_ENTRY$/} keys %mf;
    if ( !$callee || !$caller ) {
        fail("$arch: the callee and its caller were both lowered");
        next;
    }
    my @pair = sort $abi->return_pair_registers;
    is( tagged_registers( $mf{$callee}, 0, qr[\(i128 (?:lo|hi)\)] ),         \@pair, "$arch: the callee returns the wide result in the ABI pair" );
    is( tagged_registers( $mf{$caller}, 1, qr[retval i128 (?:lo|hi) from] ), \@pair, "$arch: the caller reads the wide result from the ABI pair" );
}
done_testing;

# The distinct physical registers named in the requested operand position of
# every instruction whose comment matches, sorted.
sub tagged_registers ( $mf, $which, $re ) {
    my %seen;
    for my $mbb ( $mf->blocks->@* ) {
        for my $inst ( $mbb->instructions->@* ) {
            my $comment = $inst->comment // '';
            next unless $comment =~ $re;
            my @ops = $inst->operands->@*;
            next unless @ops > $which;
            my $op = $ops[$which];
            $seen{ $op->value } = 1 if $op->kind eq 'phys_reg';
        }
    }
    return [ sort keys %seen ];
}
