use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
use Test2::Tools::Brocken qw(temp_path);
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];

my $host          = Brocken::Katsuro::Platform::parse();
my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;

# Control flow was never lowered for Wasm. The encoder opened one `block` per
# MIR block, in MIR order, and derived a branch depth from a single formula
# that only happened to be right for a branch out of the entry block, so any
# `if` produced a module the validator rejected with "unknown label" and any
# loop produced an index far past the end of the block stack. Three separate
# mistakes had to be fixed before a loop ran at all:
#
#   * A loop needs a `loop`, not a `block`, to branch back to, and it needs a
#     second plain `block` for the branch that enters it from outside. Neither
#     existed, so there was no label a back edge could target.
#
#   * A natural loop has to stop at the header. Walking predecessors from the
#     back edge pulls in every block that feeds the header, so a loop wrapped
#     in an `if` swallowed the `if` and the condition ended up inside the loop
#     it guards. `if ($i < 1) { while ($i < 3) {...} }` ran four times instead
#     of three.
#
#   * The emitted order has to put a join after both arms that reach it, and
#     each loop's blocks in one run. Reverse postorder does neither: it laid
#     the `if`'s continuation between a loop header and its body, and put an
#     `else` arm after the join that arm branches back to, which no stack of
#     labels can express because a label that has closed cannot be branched to
#     again. Ordering each region on its own, placing a block only once all of
#     its non-back-edge predecessors are placed, fixes both.
#
# Two bugs only showed up once blocks could be reordered. Call fixups were
# recorded against the start of their own block but applied to the whole
# function body, so the `_init` call in an `if` or a loop landed on the `call`
# opcode itself and the function called itself. And `return <expr>` ends a
# block with the value already parked in a local, which a stack machine has to
# be handed back explicitly.
#
# As in 3286_wasm_locals.t, `_BROCKEN_ENTRY` takes the bump allocator's base
# address, which the Wasm linker does not supply from a stub, so it goes on the
# command line. The value comes back on stdout, so each case asserts the
# computed answer rather than only that the module validates.
my @cases = (
    {
        name => 'if else',
        src  => 'my i32 $x = 4;' . "\n" . 'if ($x > 3) { return 1; } else { return 2; }',
        want => 1,
    },
    {
        name => 'return of an expression',
        src  => 'my i32 $x = 4;' . "\n" . 'return $x + 1;',
        want => 5,
    },
    {
        name => 'return of a call result',
        src  => "sub g(i64 \$x) -> i64 { return \$x * 2; }\nreturn g(3) + 1;",
        want => 7,
    },
    {
        name => 'while',
        src  => 'my i64 $i = 0; my i64 $s = 0; while ($i < 5) { $s = $s + $i; $i = $i + 1; } return $s * 10;',
        want => 100,
    },
    {
        name => 'while with division',
        src  => 'my i64 $i = 1; my i64 $s = 0; while ($i < 10) { $s = $s + $i / 2; $i = $i + 1; } return $s;',
        want => 20,
    },
    {
        name => 'nested loops',
        src  => 'my i64 $t = 0; my i64 $i = 0; while ($i < 3) { my i64 $j = 0; while ($j < 4) { $t = $t + 1; $j = $j + 1; } $i = $i + 1; } return $t;',
        want => 12,
    },
    {
        name => 'three levels of loop',
        src  => 'my i64 $a = 0; my i64 $i = 0; while ($i < 2) { my i64 $j = 0; while ($j < 3) { my i64 $k = 0; while ($k < 2) { $a = $a + 1; $k = $k + 1; } $j = $j + 1; } $i = $i + 1; } return $a;',
        want => 12,
    },
    {

        # A loop whose preheader is an `if` arm. The natural loop here has to
        # exclude the arm, or the condition runs inside the loop.
        name => 'loop inside an if',
        src  => 'my i64 $i = 0; my i64 $s = 0; if ($i < 1) { while ($i < 3) { $s = $s + 2; $i = $i + 1; } } return $s;',
        want => 6,
    },
    {
        name => 'loop after an if',
        src  => 'my i64 $i = 0; my i64 $s = 0; if ($i < 1) { $s = 100; } while ($i < 3) { $s = $s + 1; $i = $i + 1; } return $s;',
        want => 103,
    },
    {
        name => 'if and else inside a loop',
        src  => 'my i64 $i = 0; my i64 $s = 0; while ($i < 6) { if ($i % 2 == 0) { $s = $s + 10; } else { $s = $s + 1; } $i = $i + 1; } return $s;',
        want => 33,
    },
    {
        name => 'if inside a nested loop',
        src  => 'my i64 $i = 0; my i64 $s = 0; while ($i < 10) { my i64 $j = 0; while ($j < 10) { $j = $j + 1; if ($j > 2) { $s = $s + 1; } } $i = $i + 1; } return $s;',
        want => 80,
    },
    {
        name => 'return from inside a loop',
        src  => 'my i64 $i = 0; while ($i < 100) { if ($i == 7) { return $i * 3; } $i = $i + 1; } return 0;',
        want => 21,
    },
);

for my $case (@cases) {
    SKIP: {
        skip 'wasmtime not available', 1 and next unless $wasmtime_path && -f $wasmtime_path;

        my $platform    = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $module      = Brocken::Compiler->new->compile( $case->{src} );
        my $codegen     = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $funcs       = $codegen->emit_functions( $module->functions );
        my $safe        = $case->{name} =~ s/\W+/_/gr;
        my $output_file = temp_path("wasm_control_flow_$safe") . '.wasm';

        Brocken::Jenny::Linker::Wasm->new->write_executable( $output_file, $funcs, $platform );

        my $output = qx["$wasmtime_path" run --invoke _BROCKEN_ENTRY "$output_file" 1024 2>&1];
        $output =~ s/^warning: using .*$//mg;
        $output =~ s/^\s+|\s+$//g;

        is( $output, $case->{want}, "$case->{name}: module runs and returns $case->{want}" );

        unlink $output_file;
    }
}

done_testing;
