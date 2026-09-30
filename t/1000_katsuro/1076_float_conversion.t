use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# The x86-64 converter emitted the double form of every int/float conversion
# regardless of the float width: `F2 0F 2A` (cvtsi2sd) for int->float and
# `F2 0F 2C` (cvttsd2si) for float->int. The single-precision forms are the
# same opcodes under an `F3` prefix, so an f32 was converted by reading or
# writing eight bytes of a four-byte value. f64 worked, which is why the
# existing sitofp/fptosi tests all passed.
#
# Kept to values a single 32-bit compare can hold: `==` against a literal above
# 2^31 is a separate x86-64 immediate bug, tracked in TODO.md.

sub answers ( $src, $want, $name ) {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    return diag("not native") unless $host->is_native;
    my $module = eval { Brocken::Compiler->new->compile($src) };
    if ($@) { fail("$name: compile died: $@"); return }
    my $funcs = $brocken->codegen->emit_functions( $module->functions );
    my $file  = $brocken->tmpdir . '/fc' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $host );
    system $file;
    is( $? >> 8, $want, $name );
    unlink $file;
    return;
}

subtest 'float to integer, both widths' => sub {
    for my $ty (qw[f32 f64]) {
        answers( "my $ty \$t = 1.5; my i32 \$j = \$t; return \$j == 1 ? 1 : 0;",  1, "$ty 1.5 -> i32 1" );
        answers( "my $ty \$t = 3.9; my i32 \$j = \$t; return \$j == 3 ? 1 : 0;",  1, "$ty 3.9 truncates to 3" );
        answers( "my $ty \$t = 42.0; my i64 \$j = \$t; return \$j == 42 ? 1 : 0;", 1, "$ty 42.0 -> i64" );
    }
};

subtest 'truncation goes toward zero, not to minus infinity' => sub {
    for my $ty (qw[f32 f64]) {
        answers( "my $ty \$t = -3.9; my i32 \$j = \$t; return \$j == -3 ? 1 : 0;", 1, "$ty -3.9 -> -3" );
        answers( "my $ty \$t = -0.5; my i32 \$j = \$t; return \$j == 0 ? 1 : 0;",  1, "$ty -0.5 -> 0" );
        answers( "my $ty \$t = 0.5; my i32 \$j = \$t; return \$j == 0 ? 1 : 0;",   1, "$ty 0.5 -> 0" );
    }
};

subtest 'integer to float, both widths' => sub {
    for my $ty (qw[f32 f64]) {
        answers( "my i32 \$x = 42; my $ty \$y = \$x; return \$y == 42.0 ? 1 : 0;",  1, "i32 42 -> $ty" );
        answers( "my i32 \$x = -5; my $ty \$y = \$x; return \$y == -5.0 ? 1 : 0;", 1, "i32 -5 -> $ty" );
        answers( "my i64 \$x = 7; my $ty \$y = \$x; return \$y == 7.0 ? 1 : 0;",   1, "i64 7 -> $ty" );
        answers( "my i64 \$x = -5; my $ty \$y = \$x; return \$y == -5.0 ? 1 : 0;", 1, "i64 -5 -> $ty" );
    }
};

subtest 'a value stored and reloaded through the slot still converts' => sub {
    # The failure mode was reading the wrong width, so it only shows up once
    # the value has made the round trip through memory rather than sitting in
    # a register the whole way.
    for my $ty (qw[f32 f64]) {
        answers( "my $ty \$a = 6.0; my i32 \$j = \$a; my i32 \$k = \$j; return \$k == 6 ? 1 : 0;",
            1, "$ty 6.0 -> i32 -> i32" );
        answers( "my i32 \$x = 6; my $ty \$a = \$x; my i32 \$j = \$a; return \$j == 6 ? 1 : 0;",
            1, "i32 -> $ty -> i32" );
    }
};

subtest '2^24 stays exact in f32, which has 24 bits of significand' => sub {
    answers( 'my f32 $t = 16777216.0; my i64 $j = $t; return $j == 16777216 ? 1 : 0;', 1,
        'f32 2^24 -> i64' );
    answers( 'my i64 $x = 16777216; my f32 $y = $x; return $y == 16777216.0 ? 1 : 0;', 1,
        'i64 2^24 -> f32' );
};

subtest 'conversion is exact in both directions through an integer' => sub {
    answers( 'my f32 $t = 2.5; my i64 $j = $t; my f64 $d = $j; return $d == 2.0 ? 1 : 0;', 1,
        'f32 2.5 -> i64 -> f64' );
};

done_testing;
