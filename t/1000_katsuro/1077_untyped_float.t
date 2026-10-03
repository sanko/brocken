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
# Three faults had to be fixed before an untyped variable could hold a float and
# do arithmetic with one, and each one hid another on a different backend.
#
# In the frontend, `lower_binop` unboxed a dynamic operand to i64 before it knew
# what it was meeting, so `$x == 1.5` was built as a comparison of two integers
# and `$x + $y` read a float payload as its bit pattern. A dynamic operand is now
# read as whatever the context asks for: `Brocken::Runtime::unbox_f64` widens an
# integer payload, `unbox_i64` truncates a float payload toward zero, and both
# consult the tag first. Arithmetic on an untyped operand is done in f64, which is
# Perl's scalar rule -- `1.5 + 1` is 2.5 -- because the box might hold a float
# either way and nothing else would say so.
#
# Two of these faults used to cancel out on x86-64 for the simplest case: it
# truncated the literal and the value identically, so `trunc(trunc(1.5)) ==
# trunc(1.5)` was true and the bug looked like it worked. Fixing only the
# frontend makes that case *fail*, which is why the integer half is asserted
# alongside the float half here.
#
# Two more faults were not about floats at all but sat in the way:
#
# A mixed integer/float operation converted the *float* operand to the integer
# type rather than promoting the integer up, so in fully typed code
# `my i64 $a = 1; my f64 $b = 1.5; $a == $b` compared 1 against 1 and answered
# true, `$a < $b` compared 1 against 1 and answered false, and
# `my i64 $a = 2; $a * $b` computed 2. Nothing about an untyped value was
# involved; the fraction was thrown away in the lowering.
#
# A list slot is one untagged eight-byte cell with no recorded element type, so a
# list could not carry a float at all: the bits of 1.5 read back as an integer
# are 4607182418800017408. Every element is now boxed on the way in, which is the
# representation `gc_scan_list` and the `Any` incref on the reading side
# already assumed. See 1085_list_return.t.
#
# A float has no bits to shift and no bit pattern to mask, so `<< >> & | ^ && ||`
# and `%` keep an integer target when they meet an untyped operand, and a float
# remainder is not something the Wasm backend has at all.
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
        my $label   = $tag eq 'host' ? $name                                 : "$name [$tag]";
        my $brocken = $platform      ? Brocken->new( platform => $platform ) : Brocken->new();
        my $module  = eval { $brocken->compile($src) };
        if ($@) { fail("$label: compile died: $@"); next }
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        if ( $platform && $platform->arch =~ /^wasm/ ) {
            my $module_file = temp_path('uf') . '.wasm';
            Brocken::Jenny::Linker::Wasm->new->write_executable( $module_file, $funcs, $platform );
            my $output = qx["$WASMTIME" run --invoke _BROCKEN_ENTRY "$module_file" 1024 2>&1];
            my @lines  = grep {/\S/} split /\n/, $output;
            my $got    = @lines ? $lines[-1] : '';
            is( $got + 0, $want, $label );
            unlink $module_file if -e $module_file;
        }
        else {
            my $file = temp_path('uf') . $brocken->ext;

            # The linker's platform is the one the instance was built with,
            # not this loop's `$platform`, which is undef for the host target:
            # MachO reads `->arch` and `->os` off it to pick the slice.
            $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
            run_exec( $file, expected_exit => $want, platform => $platform, name => $label );
            unlink $file if -e $file;
        }
    }
}
subtest 'an untyped variable holding an integer is unchanged' => sub {
    answers( 'my $x = 7; return $x == 7 ? 1 : 0;',                 1, 'int untyped == 7' );
    answers( 'my $x = 7; return $x * 2 == 14 ? 1 : 0;',            1, 'int untyped * 2' );
    answers( 'my $x = 7; return $x + 1 == 8 ? 1 : 0;',             1, 'int untyped + 1' );
    answers( 'my $x = 7; my i64 $y = $x; return $y == 7 ? 1 : 0;', 1, 'int untyped -> i64' );
};
subtest 'an untyped variable holding a float compares as a float' => sub {
    answers( 'my $x = 1.5; return $x == 1.5 ? 1 : 0;',       1, 'untyped f64 == 1.5' );
    answers( 'my $x = 1.5; return $x != 1.5 ? 1 : 0;',       0, 'untyped f64 != 1.5' );
    answers( 'my $x = 2.5; return $x == 2.5 ? 1 : 0;',       1, 'untyped f64 == 2.5' );
    answers( 'my $x = 1.5; return $x < 2.0 ? 1 : 0;',        1, 'untyped f64 < 2.0' );
    answers( 'my $x = 1.5; return $x > 2.0 ? 1 : 0;',        0, 'untyped f64 > 2.0' );
    answers( 'my $x = 1.5; return $x * 2.0 == 3.0 ? 1 : 0;', 1, 'untyped f64 * 2.0' );
    answers( 'my $x = 1.5; return $x + 1.0 == 2.5 ? 1 : 0;', 1, 'untyped f64 + 1.0' );
};
subtest 'the comparison is a float comparison, not a truncated one' => sub {

    # 1.5 and 1.4 truncate to the same integer, so comparing them as integers
    # calls them equal. Only a float comparison can tell them apart.
    answers( 'my $x = 1.5; return $x == 1.4 ? 1 : 0;', 0, '1.5 vs 1.4, not equal' );
    answers( 'my $x = 1.5; return $x == 1.6 ? 1 : 0;', 0, '1.5 vs 1.6, not equal' );
    answers( 'my $x = 1.5; return $x == 2.5 ? 1 : 0;', 0, '1.5 vs 2.5, not equal' );
    answers( 'my $x = 0.1; return $x == 0.2 ? 1 : 0;', 0, '0.1 vs 0.2, not equal' );
};
subtest 'an untyped variable holding a float converts to a declared float' => sub {
    answers( 'my $x = 1.5; my f64 $y = $x; return $y == 1.5 ? 1 : 0;',                 1, 'untyped -> f64' );
    answers( 'my f64 $f = 1.5; my $x = $f; return $x == 1.5 ? 1 : 0;',                 1, 'f64 -> untyped' );
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
    answers( 'my $x = 1.5; my $y = 3; return $y == 3 && $x == 1.5 ? 1 : 0;',     1, 'float box first' );
    answers( 'my $x = 3; my $y = 1.5; return $x == 3 && $y == 1.5 ? 1 : 0;',     1, 'integer box first' );
    answers( 'my $x = 100; my $y = 1.5; return $x == 100 && $y == 1.5 ? 1 : 0;', 1, 'wide integer then float' );
};
subtest 'a payload is read as what the box actually holds' => sub {

    # The tag is consulted before the payload is read, so a payload crosses
    # between kinds and comes out meaning what it went in meaning.
    answers( 'my $x = 3; my f64 $y = $x; return $y == 3.0 ? 1 : 0;',   1, 'int payload into an f64' );
    answers( 'my $x = 2.5; my i64 $y = $x; return $y == 2 ? 1 : 0;',   1, 'float payload into an i64, truncated' );
    answers( 'my $x = -2.5; my i64 $y = $x; return $y == -2 ? 1 : 0;', 1, 'negative float truncates toward zero' );
    answers( 'my $x = 7; my i64 $y = $x; return $y == 7 ? 1 : 0;',     1, 'int payload into an i64' );

    # 2.5 as an f64 bit pattern is 4611686018427387904, so a payload read as raw
    # bits instead of converted would compare unequal to either of these.
    answers( 'my $x = 2.5; my i64 $y = $x; return $y == 4611686018427387904 ? 1 : 0;', 0, 'not the raw bit pattern' );
};
subtest 'arithmetic between two untyped values' => sub {
    answers( 'my $x = 1.5; my $y = 2.5; return ($x + $y) == 4.0 ? 1 : 0;',       1, 'float + float' );
    answers( 'my $x = 3; my $y = 4; return ($x + $y) == 7 ? 1 : 0;',             1, 'integer + integer' );
    answers( 'my $x = 3; my $y = 2.5; return ($x + $y) == 5.5 ? 1 : 0;',         1, 'integer + float' );
    answers( 'my $x = 1.5; my $y = 4; return ($x + $y) == 5.5 ? 1 : 0;',         1, 'float + integer' );
    answers( 'my $x = 1.5; my $y = 2.0; return ($x * $y) == 3.0 ? 1 : 0;',       1, 'float * float' );
    answers( 'my $x = 3.0; my $y = 2.0; return ($x / $y) == 1.5 ? 1 : 0;',       1, 'float / float' );
    answers( 'my $x = 10.5; my $y = 4; return ($x - $y) == 6.5 ? 1 : 0;',        1, 'float - integer' );
    answers( 'my $x = 1.5; my $y = 2.5; return ($x + $y + 0.5) == 4.5 ? 1 : 0;', 1, 'chained' );

    # Negative floats are where the old bit-pattern read was most obviously wrong:
    # the sign bit makes the pattern the *largest* unsigned value, so `>` and `<`
    # both inverted against the real ordering.
    answers( 'my $x = -1.5; my $y = -2.5; return ($x + $y) == -4.0 ? 1 : 0;', 1, 'negative float + float' );
    answers( 'my $x = -1.5; my $y = -2.5; return ($x > $y) ? 1 : 0;',         1, 'negative float ordering' );
};
subtest 'an untyped value meeting an integer is a float operation' => sub {

    # Perl's scalar rule: the box might hold a float, so `1.5 + 1` is 2.5 rather
    # than a truncation of the payload to 1.
    answers( 'my $x = 1.5; return ($x + 1) == 2.5 ? 1 : 0;', 1, 'float + 1' );
    answers( 'my $x = 1.5; return (1 + $x) == 2.5 ? 1 : 0;', 1, '1 + float' );
    answers( 'my $x = 3; return ($x + 1.5) == 4.5 ? 1 : 0;', 1, 'integer + 1.5' );
    answers( 'my $x = 7; return ($x + 1) == 8 ? 1 : 0;',     1, 'integer + 1' );
    answers( 'my $x = 7; return ($x * 2) == 14 ? 1 : 0;',    1, 'integer * 2' );

    # 2.5 and 2.0 are exactly representable, so this is 0 without a float compare.
    answers( 'my $x = 2.5; return ($x == 2) ? 1 : 0;',              0, '2.5 is not 2' );
    answers( 'my $x = 3.0; my $y = 3; return ($x == $y) ? 1 : 0;',  1, '3.0 equals 3' );
    answers( 'my $x = 3.5; my $y = 3; return ($x == $y) ? 1 : 0;',  0, '3.5 does not equal 3' );
    answers( 'my $x = 2.5; my $y = 1.5; return ($x > $y) ? 1 : 0;', 1, 'untyped >' );
    answers( 'my $x = 1.5; my $y = 2.5; return ($x < $y) ? 1 : 0;', 1, 'untyped <' );
};
subtest 'shifting and masking an untyped value stays integral' => sub {

    # A float has no bits to shift, so these keep an i64 target. Wasm has no
    # float shift or remainder at all, so promoting them would not even compile.
    #
    # Nothing here uses a payload wider than 32 bits. x86-64 loses the high half
    # of a box payload once it is read into a plain i64, and it miscompiles a
    # 64-bit dividend under a non-power-of-two modulus, so `$x >> 32`,
    # `$x % 65535` and `$x == 4294967296` all answer as though the box held 0.
    # Both faults predate this file and are in TODO.md. They are not about
    # floats, and they are not about an untyped operand either: a fully typed
    # `my i64 $x = 4294967296; return $x % 1000;` is miscompiled on x86-64 too.
    answers( 'my $x = 1; return ($x << 4) == 16 ? 1 : 0;', 1, 'untyped << 4' );
    answers( 'my $x = 12; return ($x & 10) == 8 ? 1 : 0;', 1, 'untyped & mask' );
    answers( 'my $x = 12; return ($x | 3) == 15 ? 1 : 0;', 1, 'untyped | mask' );
    answers( 'my $x = 12; return ($x ^ 10) == 6 ? 1 : 0;', 1, 'untyped ^ mask' );
    answers( 'my $x = 13; return ($x % 5) == 3 ? 1 : 0;',  1, 'untyped % 5' );
};
subtest 'a mixed integer and float operation keeps the fraction' => sub {

    # Nothing here is untyped. The lowering used to convert the float operand to
    # the integer type, which truncated it, so these were wrong on every backend.
    answers( 'my i64 $a = 1; my f64 $b = 1.5; return ($a == $b) ? 1 : 0;',       0, 'i64 == f64, not equal' );
    answers( 'my i64 $a = 1; my f64 $b = 1.5; return ($a < $b) ? 1 : 0;',        1, 'i64 < f64' );
    answers( 'my i64 $a = 2; my f64 $b = 1.5; return ($a > $b) ? 1 : 0;',        1, 'i64 > f64' );
    answers( 'my i64 $a = 2; my f64 $b = 1.5; return ($a * $b) == 3.0 ? 1 : 0;', 1, 'i64 * f64' );
    answers( 'my f64 $a = 1.5; my i64 $b = 1; return ($a - $b) == 0.5 ? 1 : 0;', 1, 'f64 - i64' );
    answers( 'my i64 $a = 3; my f64 $b = 3.0; return ($a == $b) ? 1 : 0;',       1, 'i64 == f64, equal' );
};
done_testing;
