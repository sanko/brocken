use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];
use Test2::Tools::Brocken qw(temp_path);

my $host          = Brocken::Katsuro::Platform::parse();
my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;

# Compiling any frontend program for Wasm pulled in the runtime and produced a
# module the validator rejected. Each of these was a real type error in the
# emitted bytes, not a missing encoder:
#
#   * literal operands to a typed op took their width from the literal's own
#     type, so a pointer-sized add fed an i64 constant to i32.add
#   * the op width came from the result type alone, so `ptr + i64` in the
#     runtime picked i32_add and fed it an i64 local
#   * a void function was declared as returning i32, so Brocken::Runtime::_init
#     demanded a value its body never pushed
#   * `return 0` in a function declared `-> ptr` was pushed as an i64 literal
#     into a function the type section declared as returning i32
#   * an i64 value assigned to a ptr local was stored without truncation, so an
#     i64 landed in an i32 local
#
# Each case asserts only that the module passes Wasm validation. Returning a
# value is not checked: the entry point the module exports is `_BROCKEN_ENTRY`,
# not `main`, and it takes a heap-base argument, so invoking it cannot work
# without a way to supply one. Validation is what regressed here, and a program
# as small as one local already exercises the whole runtime.
my @cases = (
    { name => 'i32 local', src => "my i32 \$x = 123;\nreturn \$x;" },
    { name => 'i64 local', src => "my i64 \$x = 123;\nreturn \$x;" },
    { name => 'neighbouring locals', src => "my i32 \$x = 123;\nmy i32 \$y = 0;\n\$y = 33;\nreturn \$x;" },
);

for my $case (@cases) {
    SKIP: {
        skip "wasmtime not available", 1 and last unless $wasmtime_path && -x $wasmtime_path;

        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $module   = Brocken::Compiler->new->compile( $case->{src} );
        my $codegen  = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $funcs    = $codegen->emit_functions( $module->functions );

        my $output_file = temp_path( 'wasm_locals_' . $case->{name} ) . '.wasm';
        Brocken::Jenny::Linker::Wasm->new->write_executable( $output_file, $funcs, $platform );

        my $output = qx["$wasmtime_path" run --invoke _BROCKEN_ENTRY $output_file 2>&1];
        chomp $output;

        unlike(
            $output,
            qr/failed to compile|Invalid input WebAssembly|translation error/,
            "$case->{name}: module passes Wasm validation"
        );

        unlink $output_file;
    }
}

done_testing;
