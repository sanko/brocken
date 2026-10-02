use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Ordering a float has no signed/unsigned split, and each backend spells the
# ordered predicates plainly. The frontend used to pick the integer s/u forms
# off is_signed, which no backend has in its float table, so every ordered
# float comparison -- `<`, `>`, `<=`, `>=` on any float width -- evaluated
# false. Equality happened to survive because `eq`/`ne` are spelled the same
# for both, which is why this went unnoticed next to the working `==`.
sub answers ( $src, $want, $name ) {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    return diag("not native") unless $host->is_native;
    my $module = eval { Brocken->new->compile($src) };
    if ($@) { fail("$name: compile died: $@"); return }
    my $funcs = $brocken->codegen->emit_functions( $module->functions );
    my $file  = $brocken->tmpdir . '/fo' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $host );
    system $file;
    is( $? >> 8, $want, $name );
    unlink $file;
    return;
}
subtest 'ordered comparison of two locals' => sub {
    for my $ty (qw[f32 f64]) {
        answers( "my $ty \$a = 1.0; my $ty \$b = 2.0; return \$a < \$b ? 1 : 0;", 1, "$ty 1.0 <  2.0" );
        answers( "my $ty \$a = 2.0; my $ty \$b = 1.0; return \$a < \$b ? 1 : 0;", 0, "$ty 2.0 <  1.0" );
        answers( "my $ty \$a = 1.0; my $ty \$b = 2.0; return \$a > \$b ? 1 : 0;", 0, "$ty 1.0 >  2.0" );
        answers( "my $ty \$a = 2.0; my $ty \$b = 1.0; return \$a > \$b ? 1 : 0;", 1, "$ty 2.0 >  1.0" );
    }
};
subtest 'the inclusive predicates' => sub {
    for my $ty (qw[f32 f64]) {
        answers( "my $ty \$a = 2.0; my $ty \$b = 2.0; return \$a <= \$b ? 1 : 0;", 1, "$ty 2.0 <= 2.0" );
        answers( "my $ty \$a = 2.0; my $ty \$b = 2.0; return \$a >= \$b ? 1 : 0;", 1, "$ty 2.0 >= 2.0" );
        answers( "my $ty \$a = 1.0; my $ty \$b = 2.0; return \$a <= \$b ? 1 : 0;", 1, "$ty 1.0 <= 2.0" );
        answers( "my $ty \$a = 1.0; my $ty \$b = 2.0; return \$a >= \$b ? 1 : 0;", 0, "$ty 1.0 >= 2.0" );
        answers( "my $ty \$a = 3.0; my $ty \$b = 2.0; return \$a <= \$b ? 1 : 0;", 0, "$ty 3.0 <= 2.0" );
    }
};
subtest 'negative values order as signed, not as raw patterns' => sub {

    # An f32 is sign-magnitude; -1.0 is 0xBF800000, which is a *smaller* i32.
    # Ordering the bit pattern instead of the value puts -1.0 below 0.0.
    answers( 'my f32 $a = -1.0; my f32 $b = 0.0; return $a < $b ? 1 : 0;',  1, 'f32 -1.0 <  0.0' );
    answers( 'my f32 $a = -2.0; my f32 $b = -1.0; return $a < $b ? 1 : 0;', 1, 'f32 -2.0 < -1.0' );
    answers( 'my f64 $a = -1.0; my f64 $b = 1.0;  return $a < $b ? 1 : 0;', 1, 'f64 -1.0 <  1.0' );
    answers( 'my f32 $a = -1.0; my f32 $b = 0.0; return $a > $b ? 1 : 0;',  0, 'f32 -1.0 >  0.0' );
};
subtest 'a float against a literal takes the literal\'s width' => sub {
    answers( 'my f32 $a = 1.5; return $a < 2.0 ? 1 : 0;', 1, 'f32 1.5 <  f64 2.0' );
    answers( 'my f32 $a = 1.5; return $a > 2.0 ? 1 : 0;', 0, 'f32 1.5 >  f64 2.0' );
    answers( 'my f64 $a = 1.5; return $a < 2 ? 1 : 0;',   1, 'f64 1.5 <  i64 2' );
};
subtest 'integer ordering is unchanged' => sub {
    answers( 'my i32 $a = 1; my i32 $b = 2; return $a < $b ? 1 : 0;',  1, 'i32 1 < 2' );
    answers( 'my i32 $a = 2; my i32 $b = 1; return $a > $b ? 1 : 0;',  1, 'i32 2 > 1' );
    answers( 'my i32 $a = 2; my i32 $b = 2; return $a <= $b ? 1 : 0;', 1, 'i32 2 <= 2' );
    answers( 'my u32 $a = 1; my u32 $b = 2; return $a < $b ? 1 : 0;',  1, 'u32 1 < 2' );
};
done_testing;
