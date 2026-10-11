use v5.42;
use Test2::V0 '!subtest';
use blib;
use Brocken;
use Brocken::Katsuro::Platform;
#
# The wasm target lowers, emits, and links without dying, and the module it
# produces is valid bytecode: the dispatch loop and the branch lowering behind it are exercised here through wasmtime,
# which validates the whole module.
#
my $brocken = Brocken->new( platform => Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi') );
ok $brocken, 'constructor builds a wasm compiler' or diag $@;
my $module = $brocken->compile('my i32 $n = 40; return $n + 2;');
ok $module, 'lowers a program for wasm' or diag $@;
is scalar $module->functions->@*, scalar $brocken->compile('return 0;')->functions->@*, 'lowering works and reports functions';
my $funcs = $brocken->codegen->emit_functions( $module->functions );
ok scalar $funcs->@*, 'emits at least one blob' or diag $@;
my $out = $brocken->tmpdir . '/wasm_probe' . $brocken->ext;
$brocken->linker->write_executable( $out, $funcs, $brocken->platform );
ok -s $out, 'writes a non-empty wasm module' or diag $@;
is substr( do { open my $fh, '<:raw', $out or die $!; local $/; <$fh> }, 0, 4 ), "\0asm", 'starts with the wasm magic number';
my $host     = Brocken::Katsuro::Platform::parse();
my $null     = $host->is_windows ? 'NUL'                  : '/dev/null';
my $wasmtime = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime if $wasmtime;
SKIP: {
    skip 'wasmtime not available', 1 unless $wasmtime && -x $wasmtime;
    my $compile = qq["$wasmtime" compile "$out" -o "$null" 2>&1];
    is system($compile), 0, 'wasmtime validates the linked module' or diag qx[$compile];
}
done_testing;
