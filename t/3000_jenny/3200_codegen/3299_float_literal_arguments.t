use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Float literals passed straight to a parameter.
#
# A float argument is copied into its register with `fmov`.  Unlike an integer
# immediate, which `mov` can encode in the instruction, there is no x86
# instruction that loads a floating-point immediate into an XMM register, so a
# literal has to be materialised first: its bit pattern goes into a general
# register and is then moved across with `fmov_gp2f`.  The call path skipped
# that and handed the raw immediate to the encoder, which refused it
# (`Unexpected operand kind: imm`).  The return path already materialised, so
# only the arguments were wrong.
#
# The temporary the materialisation uses is an ordinary virtual register.  A
# call-argument copy is `fmov <xmm>, <virt>` and the destination carries no
# type, so the allocator did not know the register held a live argument and
# could hand the same XMM to a later literal's temporary.  With four literals
# the first argument then read back as its neighbour, and `1+2+3+4` arrived as
# 9 instead of 10.  The destination register is now taken from the instruction
# for the float class, not only from its type.
#
# The codegen-level check encodes a program with literal arguments without
# running it, which is what caught the original encoding failure.  The
# executing sweep then proves the values survive: distinct values make a
# clobbered argument change the sum.
my $brocken = Brocken->new;
is(
    dies {
        my $module
            = Brocken::Compiler->new->compile( 'sub g(f64 $a, f64 $b, f64 $c, f64 $d) -> i64 {' .
                ' my f64 $s = $a + $b + $c + $d; my i64 $j = $s; return $j; }' .
                ' return g(1.0, 2.0, 3.0, 4.0);' );
        $brocken->codegen->emit_functions( $module->functions );
    },
    undef,
    'a float literal argument is materialised, not handed to the encoder as an immediate'
);
SKIP: {
    skip 'Not native', 1 unless $brocken->platform->is_native;
    my $fp_args = scalar $brocken->platform->abi->fp_param_registers->@*;
    for my $width (qw[f32 f64]) {
        for my $n ( 1 .. $fp_args ) {
            my @params = map {"$width \$v$_"} 0 .. $n - 1;
            my @lit    = map { ( $_ + 1 ) . '.0' } 0 .. $n - 1;
            my $sum    = join ' + ', map {"\$v$_"} 0 .. $n - 1;
            my $total  = $n * ( $n + 1 ) / 2;
            my $src    = <<"BROCKEN";
sub g( @{[ join ', ', @params ]} ) -> i64 {
    my $width \$s = $sum;
    my i64 \$j = \$s;
    return \$j;
}
if (g( @{[ join ', ', @lit ]} ) == $total) { return 42; }
return 1;
BROCKEN
            is( run( $src, "lit_${width}_$n" ), 42, "native: $n $width literal argument(s)" );
        }
    }

    # An integer literal argument is retagged to the parameter's float type and
    # takes the same materialisation path.
    my $src = <<'BROCKEN';
sub g(f64 $a, f64 $b, f64 $c, f64 $d) -> i64 {
    my f64 $s = $a + $b + $c + $d;
    my i64 $j = $s;
    return $j;
}
if (g(1, 2, 3, 4) == 10) { return 42; }
return 1;
BROCKEN
    is( run( $src, 'lit_int' ), 42, 'native: integer literals to f64 parameters' );
}
done_testing;

sub run {
    my ( $src, $tag ) = @_;
    my $module = Brocken::Compiler->new->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = $brocken->tmpdir . "/floatlit_$tag" . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    system $file;
    return $? >> 8;
}
