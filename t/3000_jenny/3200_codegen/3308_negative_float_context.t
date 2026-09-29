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

# A negative value in a float context.
#
# This reads as a hole rather than a rule, because the neighbouring case works.
# `my f64 $t = -$i;` is accepted and `w() == -$i` was a hard error, from a
# diagnostic in a different place: the binary-op path refused a computed int
# against a float before the conversion that the initializer path performs had a
# chance to run. So the same value reached a float slot by one route and not the
# other, and the one that failed was the ordinary one.
#
# The fix is not a new fold. A computed int is not the same number under another
# tag the way a literal is, so re-tagging it would put integer bits in a float
# slot, which is wrong for everything past 2**52. It goes through sitofp, the
# same instruction the initializer uses, and the float operation runs on the
# result.
#
# Negating in float instead -- an xor against a sign mask, as the backends do it
# -- would also be correct, but it needs the int converted first, so converting
# the already-negated integer is the cheaper answer and the one that cannot
# disagree with the initializer.
#
# The values are chosen so a re-interpretation cannot pass. -7 is not what any
# bit pattern reads back as, and a conversion that did nothing at all would
# answer with 7.
my $brocken = Brocken->new;
SKIP: {
    skip 'Not native', 12 unless $brocken->platform->is_native;

    # The initializer and the comparison of the same value, which is the whole
    # point: these disagreed, and they have to agree.
    is( neg_in_init(), 0, 'native: a negated parameter reaches a float local' );
    is( neg_in_cmp(),  0, 'native: a negated parameter compares as a float' );

    # The negative side of the comparison in each position. The check was on
    # one side of the operator and the other was untested.
    is( neg_on_rhs(), 0, 'native: a negative computed int on the right of ==' );
    is( neg_on_lhs(), 0, 'native: a negative computed int on the left of ==' );
    is( neg_in_neq(), 0, 'native: a negative computed int on the right of !=' );
    is( neg_in_lt(),  0, 'native: a negative computed int on the right of <' );

    # Ordering, not just equality. A sign error that turned every ordering
    # predicate into the wrong one would still pass an == test.
    is( ordering(), 0, 'native: a negative float orders against a positive one' );

    # Mixed with the arithmetic the value is used in, so the conversion cannot
    # be applied to the comparison alone and skipped where it is consumed.
    is( arithmetic(), 0, 'native: a negative float takes part in arithmetic' );
    is( nested(),     0, 'native: a negative float survives a nested call' );

    # The narrow integer sources, which reach the convert by a different path: a
    # signed one has to be widened with its sign. A positive value is negated so
    # the result is negative, which is what a lost sign would break.
    is( convert_ok( 'i8',  7, -7 ), 0, 'native: a negative i8 comes from a signed one' );
    is( convert_ok( 'i16', 7, -7 ), 0, 'native: a negative i16 comes from a signed one' );
    is( convert_ok( 'i32', 7, -7 ), 0, 'native: a negative i32 comes from a signed one' );
}
done_testing;

sub neg_in_init {
    my $src = <<'BROCKEN';
sub w( i64 $i ) -> f64 {
    my f64 $t = -$i;
    return $t;
}
if ( w(7) != -7 ) { return 1; }
return 0;
BROCKEN
    return run($src);
}

sub neg_in_cmp {
    my $src = <<'BROCKEN';
sub w( i64 $i ) -> f64 {
    my f64 $t = -$i;
    return $t;
}
if ( w(7) == -7 ) { return 0; }
return 1;
BROCKEN
    return run($src);
}

sub neg_on_rhs {
    my $src = <<'BROCKEN';
sub w( i64 $i ) -> f64 {
    return -$i;
}
if ( w(7) == -7 ) { return 0; }
return 1;
BROCKEN
    return run($src);
}

# The operator is symmetric in the source and was not symmetric in the lowerer,
# because the check named one side and assigned the result to the other.
sub neg_on_lhs {
    my $src = <<'BROCKEN';
sub w( i64 $i ) -> f64 {
    return -$i;
}
if ( -7 == w(7) ) { return 0; }
return 1;
BROCKEN
    return run($src);
}

sub neg_in_neq {
    my $src = <<'BROCKEN';
sub w( i64 $i ) -> f64 {
    my f64 $t = -$i;
    return $t;
}
if ( w(7) != -7 ) { return 1; }
return 0;
BROCKEN
    return run($src);
}

sub neg_in_lt {
    my $src = <<'BROCKEN';
sub w( i64 $i ) -> f64 {
    my f64 $t = -$i;
    return $t;
}
if ( w(7) < -6 ) { return 0; }
return 1;
BROCKEN
    return run($src);
}

sub ordering {
    my $src = <<'BROCKEN';
sub w( f64 $x ) -> f64 {
    my f64 $t = -$x;
    return $t;
}
if ( w(2) != -2 ) { return 1; }
if ( !( w(2) < -1 ) ) { return 2; }
if ( w(2) > -1 ) { return 3; }
if ( w(2) == -1 ) { return 4; }
return 0;
BROCKEN
    return run($src);
}

sub arithmetic {
    my $src = <<'BROCKEN';
sub w( i64 $i ) -> f64 {
    my f64 $t = -$i;
    my f64 $u = $t + 10;
    return $u;
}
if ( w(7) != 3 ) { return 1; }
return 0;
BROCKEN
    return run($src);
}

sub nested {
    my $src = <<'BROCKEN';
sub g( f64 $x ) -> f64 {
    return $x;
}
sub w( i64 $i ) -> f64 {
    my f64 $t = -$i;
    return g($t);
}
if ( w(7) != -7 ) { return 1; }
return 0;
BROCKEN
    return run($src);
}

sub convert_ok {
    my ( $itype, $value, $want ) = @_;
    my $src = <<"BROCKEN";
sub w( $itype \$i ) -> f64 {
    my f64 \$t = -\$i;
    return \$t;
}
if ( w($value) != $want ) { return 1; }
return 0;
BROCKEN
    return run($src);
}

sub run {
    my ($src)  = @_;
    my $module = Brocken::Compiler->new->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = $brocken->tmpdir . '/negflt' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    system $file;
    return $? >> 8;
}
