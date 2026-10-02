use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Floating-point parameters are captured and passed with `fmov`, not `mov`,
# and RISC-V spells an integer copy `mv`.  Two parallel moves meet a float
# argument, and both had a fixed order that a chain of them defeats.
#
# In the callee, the entry shuffle recognised only `mov`, so a run of
# floating-point captures was left unscheduled and a capture that wrote a
# register could land before one that read it -- an argument arrived as a copy
# of its neighbour.  That is the integer case in 3297 on the register class the
# shuffle skipped.
#
# In the caller, the argument copies are emitted in reverse order.  That is
# safe only while no copy's source is another copy's destination; with two
# floats in xmm1 and xmm2 it writes xmm1 first and destroys the source of the
# copy into xmm0, so the earlier argument reads back as its neighbour.  The
# arguments here are locals rather than literals so the copies have register
# sources and the hazard can form -- a literal is materialised straight into
# the argument register and cannot collide.  Both moves are now scheduled as
# parallel moves.
#
# The values are built at runtime from integers rather than written as float
# literals so the argument copies have register sources and the hazard can
# form; a literal is materialised straight into the argument register and
# cannot collide.  Literal arguments, including the materialisation they need,
# are covered by 3299.  The sum comes back through an integer for the same
# reason 1076 keeps its comparisons small: comparing a float against a literal
# is not what this test is about.
my $brocken = Brocken->new;
SKIP: {
    skip 'Not native', 1 unless $brocken->platform->is_native;
    my $fp_args = scalar $brocken->platform->abi->fp_param_registers->@*;
    for my $n ( 1 .. $fp_args ) {
        my @params = map {"f64 \$v$_"} 0 .. $n - 1;
        my $sum    = join( ' + ', map {"\$v$_"} 0 .. $n - 1 );
        my $seed   = 40;
        my $setup  = join "\n", map { "my f64 \$a$_ = \$base + " . ( $_ + 1 ) . ';' } 0 .. $n - 1;
        my $want   = join "\n", map { "\$want = \$want + ( \$base + " . ( $_ + 1 ) . ' );' } 0 .. $n - 1;
        my $call   = join ', ', map {"\$a$_"} 0 .. $n - 1;
        my $src    = <<"BROCKEN";
my i64 \$base = $seed;
sub g( @{[ join ', ', @params ]} ) -> i64 {
    my f64 \$s = $sum;
    my i64 \$j = \$s;
    return \$j;
}
$setup
my i64 \$want = 0;
$want
if (g( $call ) == \$want) { return 42; }
return 1;
BROCKEN
        is( run($src), 42, "native: $n of $fp_args f64 parameter(s) in registers" );
    }
}
done_testing;

sub run {
    my ($src)  = @_;
    my $module = Brocken->new->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = $brocken->tmpdir . '/fparams' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    system $file;
    return $? >> 8;
}
