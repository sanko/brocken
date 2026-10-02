use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Jenny::Linker::Wasm;
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];
use Test2::Tools::Brocken qw(temp_path);
my $host          = Brocken::Katsuro::Platform::parse();
my $null          = $host->is_windows ? 'NUL'                  : '/dev/null';
my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;

# A `_start` whose body traps instead of calling the entry. Reached only when
# `wasmtime run` finds and runs `_start`, so a failing exit here is the proof
# that the stub really is what runs the module.
class TrapStart : isa(Brocken::Jenny::Linker::Wasm) {

    method _start_body( $entry_index, $entry = undef ) {
        return pack( 'C', 0x00 ) . pack( 'C', 0x00 ) . pack( 'C', 0x0B );    # no locals, unreachable, end
    }
}

# `_BROCKEN_ENTRY` takes the heap base as an i64, because a Wasm pointer is 64
# bits; `_start` has to pass one in a type the call accepts.
sub build_functions {
    my $i64  = Brocken::Lindsay::IR::Type::i64();
    my $i32  = Brocken::Lindsay::IR::Type::i32();
    my $b    = Brocken::Lindsay::IR::Builder->new();
    my $heap = Brocken::Lindsay::IR::Value->new( type => $i64, name => 'heap_base' );
    my $main = Brocken::Lindsay::IR::Function->new( name => '_BROCKEN_ENTRY', return_type => $i32, params => [$heap], );
    $b->position_at_end( $main->append_block('entry') );
    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );
    return [$main];
}

sub link_module {
    my ( $path, $linker ) = @_;
    my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
    my $codegen  = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $funcs    = $codegen->emit_functions( build_functions() );
    ( $linker //= Brocken::Jenny::Linker::Wasm->new() )->write_executable( $path, $funcs, $platform );
    return $path;
}
subtest 'Wasm module runs as a WASI command' => sub {
    skip_all('wasmtime not available') unless $wasmtime_path && -f $wasmtime_path;
    my $module = temp_path('wasm_start') . '.wasm';
    link_module($module);
    my $compile = qq["$wasmtime_path" compile "$module" -o "$null" 2>&1];
    is system($compile), 0, 'the module with _start validates' or diag qx[$compile];
    my $run = qq["$wasmtime_path" run "$module" 2>$null];
    is system($run), 0, 'wasmtime run exits cleanly';
    my $trapped = temp_path('wasm_start_trap') . '.wasm';
    link_module( $trapped, TrapStart->new() );
    my $trap_run = qq["$wasmtime_path" run "$trapped" 2>$null];
    isnt system($trap_run), 0, 'a trapping _start fails the run, so the clean exit above came from _start';
    unlink $trapped if -e $trapped;
    my $invoke = qx["$wasmtime_path" run --invoke _BROCKEN_ENTRY "$module" 1024 2>$null];
    chomp $invoke;
    is $invoke, 42, '_BROCKEN_ENTRY survives and still takes a heap base';
    unlink $module if -e $module;
};

# The runtime writes a 24-byte header at the base, so a base past the end of the
# first page needs a second one. The single page this used to emit covered 1024
# by coincidence.
subtest 'Wasm memory covers the heap base' => sub {
    is( Brocken::Jenny::Linker::Wasm->new->_initial_pages,                       1, 'the default base fits one page' );
    is( Brocken::Jenny::Linker::Wasm->new( heap_base => 65536 )->_initial_pages, 2, 'a base past 64KB needs two pages' );
    my $module = temp_path('wasm_pages') . '.wasm';
    link_module( $module, Brocken::Jenny::Linker::Wasm->new( heap_base => 70000 ) );
    my $bytes = do { open my $fh, '<', $module or die $!; binmode $fh; local $/; <$fh> };
    like $bytes, qr/\x05\x03\x01\x00\x02/, 'the emitted memory section declares two pages';
    unlink $module if -e $module;
};
done_testing;
