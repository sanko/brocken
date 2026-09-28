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
# `_BROCKEN_ENTRY` takes the bump allocator's base address as its one
# parameter, which the native linkers supply from an entry stub (ELF64 carves
# the heap out of the stack and passes rsp). The Wasm linker has no such stub
# and exports the function directly, so the address is passed on the command
# line instead. Everything the program allocates then lives at 1024, and the
# value comes back on stdout, so these cases assert real behaviour rather than
# only that the bytes validate.
my @cases = (
    { name => 'i32 local', src => "my i32 \$x = 123;\nreturn \$x;", want => 123 },
    { name => 'i64 local', src => "my i64 \$x = 123;\nreturn \$x;", want => 123 },
    {
        name => 'neighbouring locals',
        src  => "my i32 \$x = 123;\nmy i32 \$y = 0;\n\$y = 33;\nreturn \$x;",
        want => 123,
    },
    { name => 'i32 reassigned', src => "my i32 \$x = 0;\n\$x = 55;\nreturn \$x;", want => 55 },
    { name => 'i64 arithmetic', src => "my i64 \$x = 40;\n\$x = \$x + 2;\nreturn \$x;", want => 42 },
    { name => 'null pointer', src => 'return 0;', want => 0 },
);

for my $case (@cases) {
    SKIP: {
        skip 'wasmtime not available', 1 and last unless $wasmtime_path && -f $wasmtime_path;

        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $module   = Brocken::Compiler->new->compile( $case->{src} );
        my $codegen  = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $funcs    = $codegen->emit_functions( $module->functions );

        # A path with a space in it has to stay quoted, or wasmtime reads
        # "wasm_locals_i32" as the module and the rest as a path it cannot
        # open. That failure used to slip through this test: the assertion
        # only rejected a few compile diagnostics, and "failed to open wasm
        # module" was not one of them, so the cases passed without the module
        # ever being validated.
        my $safe        = $case->{name} =~ s/\W+/_/gr;
        my $output_file = temp_path("wasm_locals_$safe") . '.wasm';
        Brocken::Jenny::Linker::Wasm->new->write_executable( $output_file, $funcs, $platform );

        my $output = qx["$wasmtime_path" run --invoke _BROCKEN_ENTRY "$output_file" 1024 2>&1];

        # wasmtime warns on stderr about --invoke with arguments and with a
        # return value; neither says anything about this module.
        $output =~ s/^warning: using .*$//mg;
        $output =~ s/^\s+|\s+$//g;

        is( $output, $case->{want}, "$case->{name}: module runs and returns $case->{want}" );

        unlink $output_file;
    }
}

done_testing;
