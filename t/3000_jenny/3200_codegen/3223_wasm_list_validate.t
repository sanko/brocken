use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Linker::Wasm;
use Test2::Tools::Brocken qw[temp_path];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# A list built inside a subroutine failed to validate on Wasm.
#
# The list itself was never the fault. Every function whose IR return type is a
# pointer or a boxed value gets a fuel-exit block, and that block returns a zero
# constant of the function's return type. `_wasm_push` chose the constant width
# from `int` alone, so a `ptr` or `dynamic` zero was pushed as an i32 while the
# function signature -- and the `ret` -- wanted an i64. The validator reported
# `type mismatch: expected i64, found i32`, and because a list is normally
# returned from a helper declared `-> ptr`, every list of that shape hit it.
# The constant width now comes from `_scalar_bits`, which already counts a
# pointer and a boxed value as 64 bits.
#
# What this does NOT settle is the lifetime of a box handed out of a frame:
# Wasm reclaims a function's bump region on return, so a box built inside the
# helper is freed before the caller reads the list slot that points at it, and
# the program traps when it runs. That is the `box` -> `bump_alloc` item in
# TODO.md, separate from whether the module is well formed. These cases assert
# validation only, which is what was broken here.
my $host     = Brocken::Katsuro::Platform::parse();
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $brocken  = Brocken->new( platform => $platform );
my $null     = $host->is_windows ? 'NUL'                  : '/dev/null';
my $wasmtime = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime if $wasmtime;
my $node = $host->is_windows ? `where node 2>NUL` : `which node 2>/dev/null`;
chomp $node if $node;
my $runner = $wasmtime && -x $wasmtime ? 'wasmtime' : ( $node && -x $node ? 'node' : undef );

sub validates ( $src, $name ) {
    my $module = eval { $brocken->compile($src) };
    if ($@) { fail("$name: compile died: $@"); return }
    my $file = temp_path('wasm_list') . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $file, $brocken->codegen->emit_functions( $module->functions ), $platform );
SKIP: {
        skip 'no wasm binary runner available', 1 unless $runner;
        my $status = $runner eq 'wasmtime' ? system(qq["$wasmtime" compile "$file" -o "$null" 2>&1]) :
            system( 'node', '-e', "const fs=require('fs');process.exit(WebAssembly.validate(fs.readFileSync('$file'))?0:1);" );
        is $status, 0, $name or diag 'the module did not validate';
    }
    unlink $file if -e $file;
    return;
}
SKIP: {
    skip 'Neither wasmtime nor node are installed', 1 unless $runner;
    subtest 'a pointer-returning function' => sub {
        validates( 'sub f() -> ptr { return 0; } return 0;', 'a bare ptr return validates' );
    };
    subtest 'a boxed-returning function' => sub {
        validates( 'sub f() -> Any { my $x = 5; return $x; } return 0;', 'an Any return validates' );
    };
    subtest 'a list returned from a subroutine' => sub {
        validates( 'sub make_list() -> ptr { return (3, 4); } my ($a, $b) = make_list(); return $a + $b;', 'a two-element list validates' );
        validates( 'sub make_list() -> ptr { return (10, 20, 30); } my ($x, $y, $z) = make_list(); return $x + $y + $z;',
            'a three-element list validates' );
        validates( 'sub make_one() -> ptr { return (42); } my ($v) = make_one(); return $v;', 'a single-element list validates' );
        validates( 'sub make_list() -> ptr { my $x = 5; return ($x * 2, $x + 3); } my ($a, $b) = make_list(); return $a + $b;',
            'a list of expressions validates' );
        validates( 'sub make_list() -> ptr { my $u = 7; return ($u, 2); } my ($a, $b) = make_list(); return $a + $b;',
            'a list of an untyped and an integer validates' );
    };
    subtest 'a top-level list' => sub {
        validates( 'my ($a, $b) = (3, 4); return $a + $b;', 'a top-level list validates' );
    };
}
done_testing;
