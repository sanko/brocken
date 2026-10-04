use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# `my i128 $x = 3;` fails to parse, but only because the 128-bit names are behind the `brocken_native_types` feature
# gate.  The parser declines to treat `i128` as a type without it, so `my` is left looking for a type and the error
# blames the variable name instead:
#
#     my i128 $x = 3;                          # Expected variable name after 'my'
#     use feature 'brocken_native_types';
#     my i128 $x = 3;                          # fine
#
# The gate is deliberate and documented in `Brocken::Katsuro::Parser`.  The claim that an i128 cannot be declared in
# source, and therefore has no end-to-end test, no longer holds: the declaration parses, the lowerer splits it across
# two registers, and the value computes.  This checks both halves -- the rejection without the gate, and a
# declare/widen/narrow round trip that executes on the host.
subtest 'the 128-bit names are feature-gated' => sub {
    for my $ty (qw[i128 u128]) {
        my $err = eval { Brocken->new->parse("my $ty \$x = 1;"); 1 } ? undef : $@;
        like( $err, qr/Expected variable name after 'my'/, "$ty without the feature is rejected as a bare name" );
        my $prog = eval { Brocken->new->parse("use feature 'brocken_native_types';\nmy $ty \$x = 1;") };
        ok( $prog, "$ty parses once the feature is requested" ) or diag($@);
        is( $prog->statements->[0]->type, $ty, "$ty is a declaration type behind the gate" );
    }
};
subtest 'an i128 survives a declare/widen/narrow round trip' => sub {
    my $brocken = Brocken->new;
    unless ( $brocken->platform->is_native ) { plan skip_all => 'not native'; return }
    answers( $brocken, "use feature 'brocken_native_types';" . ' my i128 $x = 3; my i64 $j = $x; return $j == 3 ? 1 : 0;',
        1, 'an i128 literal narrows to i64' );
    answers( $brocken, "use feature 'brocken_native_types';" . ' my i64 $a = 5; my i128 $b = $a; my i64 $j = $b; return $j == 5 ? 1 : 0;',
        1, 'an i64 widens to i128 and back' );
    answers( $brocken, "use feature 'brocken_native_types';" . ' my i128 $x = -3; my i64 $j = $x; return $j == -3 ? 1 : 0;',
        1, 'a negative i128 narrows to i64' );
    answers( $brocken, "use feature 'brocken_native_types';" . ' my i128 $x = 3; my i128 $y = $x + 4; my i64 $j = $y; return $j == 7 ? 1 : 0;',
        1, 'i128 arithmetic narrows to i64' );
};
done_testing;

sub answers ( $brocken, $src, $want, $name ) {
    my $module = eval { Brocken->new->compile($src) };
    if ($@) { fail("$name: compile died: $@"); return; }
    my $funcs = $brocken->codegen->emit_functions( $module->functions );
    my $file  = $brocken->tmpdir . '/i128syn' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    system $file;
    is( $? >> 8, $want, $name );
    unlink $file;
    return;
}
