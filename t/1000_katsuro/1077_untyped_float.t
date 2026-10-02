use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Linker::Wasm;
use Test2::Tools::Brocken qw[run_exec temp_path cross_available];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# An untyped variable is a box, and the box has always had room for a float --
# the header carried a type tag -- but nothing ever put one there or read one
# back.
#
# Two independent faults had to be fixed before an untyped variable could hold a
# float, and each one hid the other on a different backend.
#
# In the frontend, `lower_binop` unboxed a dynamic operand to i64 before it knew
# what the comparison was against, so `$x == 1.5` was built as a comparison of
# two integers. The float-ness of the literal was gone before the comparison
# existed, and no backend could recover it. Now a dynamic meeting a float
# operand unboxes to that float type.
#
# In every native backend, the box's payload store used `store_imm` whenever the
# value was a constant, and `store_imm` picks a 64-bit GP move for a memory
# operand that is not an int. `my $x = 1.5;` therefore stored the integer 1. All
# three now route a float payload through the FP store.
#
# These two faults used to cancel out on x86-64 for the simplest case: it
# truncated the literal and the value identically, so `trunc(trunc(1.5)) ==
# trunc(1.5)` was true and the bug looked like it worked. Fixing only the
# frontend makes that case *fail*, which is why the integer half is asserted
# alongside the float half here.
#
# Three cases remain wrong and are deliberately not asserted, because all three
# need the box tag consulted at run time and are tracked in TODO.md:
#
#   - a float payload read in an integer context (`my $x = 2.5; $x == 2`), which
#     reads the payload's bits as an integer;
#   - an integer payload read in a float context (`my $x = 3; my f64 $y = $x;`),
#     which was already wrong before this file existed and reads the payload's
#     bits as a double;
#   - arithmetic between two dynamics (`my $x = 1.5; my $y = 2.5; $x + $y`),
#     where neither side says it is a float.
#
# The first two are the same fault in opposite directions: a payload is read at
# whatever width the context asks for, with nothing checking that the box
# actually holds that kind of value.
#
# Assigning a box to another box and self-assigning are excluded here too. Both
# trap on Wasm for integers as well as floats, so they belong to the aliasing
# gap rather than to anything about floats.
#
# `f32` is excluded as well, and was already broken before any of this. The box
# payload is a single 8-byte slot and the IR has no fptrunc/fpext, so a float of
# one width cannot be put in a slot of the other -- the limitation is stated in
# Katsuro/Lowerer.pm. An f32 payload writes 4 bytes and the unbox reads 8, or the
# unbox reads 4 of an 8-byte f64. Every decimal literal is an f64, so nothing
# reaches a box as an f32 unless it is declared one on purpose.
#
# Every target that can actually execute runs these, for the same reason
# 1076_float_conversion.t does: the cross targets through BROCKEN_SYSROOT_*, and
# Wasm through wasmtime. Each is added only when its tooling is present.
sub _wasmtime {
    my $exe = $^O eq 'MSWin32' ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
    return undef unless defined $exe;
    chomp $exe;
    return ( length $exe && -f $exe ) ? $exe : undef;
}
my $WASMTIME = _wasmtime();
my @TARGETS  = ( [ 'host', undef ] );
for my $triple ( 'aarch64-unknown-linux-gnu', 'riscv64-unknown-linux-gnu' ) {
    my $platform = eval { Brocken::Katsuro::Platform::parse($triple) };
    push @TARGETS, [ $triple, $platform ] if $platform && cross_available($platform);
}
push @TARGETS, [ 'wasm32-unknown-wasi', Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi') ] if $WASMTIME;

sub answers ( $src, $want, $name ) {
    for my $target (@TARGETS) {
        my ( $tag, $platform ) = @$target;
        my $label = $tag eq 'host' ? $name : "$name [$tag]";
        my $brocken = $platform ? Brocken->new( platform => $platform ) : Brocken->new();
        my $module = eval { $brocken->compile($src) };
        if ($@) { fail("$label: compile died: $@"); next }
        my $funcs = $brocken->codegen->emit_functions( $module->functions );

        if ( $platform && $platform->arch =~ /^wasm/ ) {
            my $module_file = temp_path('uf') . '.wasm';
            Brocken::Jenny::Linker::Wasm->new->write_executable( $module_file, $funcs, $platform );
            my $output = qx["$WASMTIME" run --invoke _BROCKEN_ENTRY "$module_file" 1024 2>&1];
            my @lines  = grep { /\S/ } split /\n/, $output;
            my $got    = @lines ? $lines[-1] : '';
            is( $got + 0, $want, $label );
            unlink $module_file if -e $module_file;
        }
        else {
            my $file = temp_path('uf') . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $platform );
            run_exec( $file, expected_exit => $want, platform => $platform, name => $label );
            unlink $file if -e $file;
        }
    }
}
subtest 'an untyped variable holding an integer is unchanged' => sub {
    answers( 'my $x = 7; return $x == 7 ? 1 : 0;',            1, 'int untyped == 7' );
    answers( 'my $x = 7; return $x * 2 == 14 ? 1 : 0;',       1, 'int untyped * 2' );
    answers( 'my $x = 7; return $x + 1 == 8 ? 1 : 0;',        1, 'int untyped + 1' );
    answers( 'my $x = 7; my i64 $y = $x; return $y == 7 ? 1 : 0;', 1, 'int untyped -> i64' );
};
subtest 'an untyped variable holding a float compares as a float' => sub {
    answers( 'my $x = 1.5; return $x == 1.5 ? 1 : 0;',        1, 'untyped f64 == 1.5' );
    answers( 'my $x = 1.5; return $x != 1.5 ? 1 : 0;',        0, 'untyped f64 != 1.5' );
    answers( 'my $x = 2.5; return $x == 2.5 ? 1 : 0;',        1, 'untyped f64 == 2.5' );
    answers( 'my $x = 1.5; return $x < 2.0 ? 1 : 0;',         1, 'untyped f64 < 2.0' );
    answers( 'my $x = 1.5; return $x > 2.0 ? 1 : 0;',         0, 'untyped f64 > 2.0' );
    answers( 'my $x = 1.5; return $x * 2.0 == 3.0 ? 1 : 0;',  1, 'untyped f64 * 2.0' );
    answers( 'my $x = 1.5; return $x + 1.0 == 2.5 ? 1 : 0;',  1, 'untyped f64 + 1.0' );
};
subtest 'the comparison is a float comparison, not a truncated one' => sub {

    # 1.5 and 1.4 truncate to the same integer, so comparing them as integers
    # calls them equal. Only a float comparison can tell them apart.
    answers( 'my $x = 1.5; return $x == 1.4 ? 1 : 0;',        0, '1.5 vs 1.4, not equal' );
    answers( 'my $x = 1.5; return $x == 1.6 ? 1 : 0;',        0, '1.5 vs 1.6, not equal' );
    answers( 'my $x = 1.5; return $x == 2.5 ? 1 : 0;',        0, '1.5 vs 2.5, not equal' );
    answers( 'my $x = 0.1; return $x == 0.2 ? 1 : 0;',        0, '0.1 vs 0.2, not equal' );
};
subtest 'an untyped variable holding a float converts to a declared float' => sub {
    answers( 'my $x = 1.5; my f64 $y = $x; return $y == 1.5 ? 1 : 0;',      1, 'untyped -> f64' );
    answers( 'my f64 $f = 1.5; my $x = $f; return $x == 1.5 ? 1 : 0;',      1, 'f64 -> untyped' );
    answers( 'my $x = 1.5; my f64 $y = $x; my f64 $z = $y; return $z == 1.5 ? 1 : 0;', 1, 'untyped -> f64 -> f64' );
};
subtest 'a boxed float survives a store and a call' => sub {
    answers( 'sub get(f64 $v) -> f64 { return $v; } my $x = 1.5; my f64 $y = get($x); return $y == 1.5 ? 1 : 0;', 1, 'box -> call' );
    answers( 'my $a = 1.5; my $b = 2; return $a == 1.5 && $b == 2 ? 1 : 0;', 1, 'float and int boxes side by side' );
    answers( 'my $a = 2; my $b = 1.5; return $a == 2 && $b == 1.5 ? 1 : 0;', 1, 'int and float boxes side by side' );
};
subtest 'a float box and an integer box do not bleed into each other' => sub {

    # The header tag and the payload are written by separate instructions. If
    # the float payload store wrote its integer form instead, it would still be
    # 8 bytes and every neighbouring access would still line up, so only the
    # value proves it.
    answers( 'my $x = 1.5; my $y = 3; return $y == 3 && $x == 1.5 ? 1 : 0;', 1, 'float box first' );
    answers( 'my $x = 3; my $y = 1.5; return $x == 3 && $y == 1.5 ? 1 : 0;', 1, 'integer box first' );
    answers( 'my $x = 100; my $y = 1.5; return $x == 100 && $y == 1.5 ? 1 : 0;', 1, 'wide integer then float' );
};
done_testing;
