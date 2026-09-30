use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro;
use Brocken::Compiler;
use Brocken::Jenny;
use Test2::Tools::Brocken qw[temp_path];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# A WASI command entry, so `wasmtime run module.wasm` works.
#
# Until now the linker exported only `_BROCKEN_ENTRY`, whose one parameter is
# the bump allocator's base address, and there was no stub to supply it -- the
# native linkers have one (ELF64 carves the heap off the stack and passes rsp)
# and the Wasm one did not. Every invocation therefore had to name
# `--invoke _BROCKEN_ENTRY` and pass a heap base on the command line after the
# module path.
#
# `_start` is `() -> ()` because that is the only signature WASI allows a
# command's entry to have, so it cannot pass a base the way the parameter does
# and supplies the link-time one itself: `i32.const <base>; call <entry>; drop`.
#
# The drop is the part worth being explicit about. The entry's return value is
# discarded, because propagating it would mean importing
# `wasi_snapshot_preview1.proc_exit`, and this module has no import section at
# all. A program that returns 42 and one that returns 1 both exit 0. That is a
# real limitation and it is why this test cannot simply assert on the program's
# value through `_start`; the negative control below is what pins the wiring.
my $host          = Brocken::Katsuro::Platform::parse();
my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');

sub build_wasm {
    my ( $src, $name, $linker ) = @_;
    my $module  = Brocken::Compiler->new->compile($src);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $file    = temp_path($name) . '.wasm';
    my $l       = $linker // Brocken::Jenny::Linker::Wasm->new;
    $l->write_executable( $file, $codegen->emit_functions( $module->functions ), $platform );
    return $file;
}

# A linker whose `_start` traps instead of calling the entry.
class TrapStart : isa(Brocken::Jenny::Linker::Wasm) {

    method _start_body($entry_index) {
        return pack( 'C', 0x00 ) . pack( 'C', 0x00 ) . pack( 'C', 0x0B );
    }
}

# Walk the section list. A byte scan for 0x05 is not good enough: the payload
# of a data or export section can contain that byte, and it will be found first.
sub read_wasm {
    my ($file) = @_;
    open my $fh, '<:raw', $file or die $!;
    my $m = do { local $/; <$fh> };
    close $fh;
    return $m;
}

sub read_uleb {
    my ( $m, $pos ) = @_;
    my $value = 0;
    my $shift = 0;
    while (1) {
        my $b = ord substr( $m, $pos, 1 );
        $pos++;
        $value |= ( $b & 0x7F ) << $shift;
        last unless $b & 0x80;
        $shift += 7;
    }
    return ( $value, $pos );
}

# id => payload bytes, for every section in the module.
sub sections {
    my ($m) = @_;
    my %sec;
    my $pos = 8;    # magic and version
    while ( $pos < length $m ) {
        my $id = ord substr( $m, $pos, 1 );
        $pos++;
        my ( $size, $next ) = read_uleb( $m, $pos );
        $sec{$id} = substr( $m, $next, $size );
        $pos = $next + $size;
    }
    return \%sec;
}

# The memory section, as raw bytes, so the two emission paths can be compared
# directly. The header offset lived in both of them once and drifted, which is
# what stopped array growth on the single-function path only.
sub memory_section {
    my ($file) = @_;
    return sections( read_wasm($file) )->{5} // '';
}

# The declared initial page count, from the memory section's limits.
sub initial_pages {
    my ($file) = @_;
    my $sec = memory_section($file);
    return 0 unless length $sec;
    my ( undef,  $pos ) = read_uleb( $sec, 0 );      # count of memories
    my ( $flags, $p2 )  = read_uleb( $sec, $pos );
    my ($min) = read_uleb( $sec, $p2 );
    return $min;
}

# The export is present, alongside the old one
{
    my $file = build_wasm( 'return 42;', 'start_export' );
    my $m    = read_wasm($file);
    like( $m, qr/_start/,         'the module exports a _start' );
    like( $m, qr/_BROCKEN_ENTRY/, 'and still exports _BROCKEN_ENTRY, so the existing --invoke convention is untouched' );

    # The initial page count has to cover the base plus the 24-byte heap
    # header, or a base above 64KB puts the header itself out of bounds. The
    # old fixed single page covered 1024 by coincidence.
    is( initial_pages($file), 1, 'one page is declared, which covers the 1024 base and its header' );

    # A base past a single page must ask for more, rather than seeding the
    # header into memory the module does not own.
    my $big     = temp_path('start_bigbase') . '.wasm';
    my $module  = Brocken::Compiler->new->compile('return 42;');
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    Brocken::Jenny::Linker::Wasm->new( heap_base => 200000 )->write_executable( $big, $codegen->emit_functions( $module->functions ), $platform );
    is( initial_pages($big), 4, 'a 200000 base asks for 4 pages, since 200024 bytes needs more than three' );
    unlink $big;
    unlink $file;
}

# Both paths agree on the memory section
# The single-function path takes a bare record from emit_function. Its name is
# not the entry, so no _start is added, but the memory section must still be
# the same bytes: that section is what the runtime reads to decide how much
# heap it actually has.
{
    my $file        = build_wasm( 'return 42;', 'start_multipath' );
    my $multi       = memory_section($file);
    my $module      = Brocken::Compiler->new->compile('return 42;');
    my $ir          = ( grep { $_->name eq '_BROCKEN_ENTRY' } $module->functions->@* )[0];
    my $codegen     = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $single_file = temp_path('start_singlepath') . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $single_file, $codegen->emit_function($ir), $platform );
    my $single = memory_section($single_file);
    is( $single, $multi, 'the single-function path declares the same memory as the multi-function path' );
    isnt( $single, '', 'and the single-function module really does have a memory section to compare' );
    unlink $file, $single_file;
}

# `wasmtime run` reaches the entry
# Exit status alone proves nothing here: wasmtime exits 0 for a module with no
# _start at all, and it exits 0 for this one whether or not the program
# succeeded, because the return value is dropped. So the control is a linker
# whose _start traps -- if that traps, wasmtime is genuinely reaching _start,
# which is what makes the real module's clean exit mean the program ran.
SKIP: {
    skip 'wasmtime not available', 4 unless $wasmtime_path && -f $wasmtime_path;
    my $ok     = build_wasm( "my [i64; 100] \$a;\n\$a[0] = 7;\n\$a[99] = 9;\nreturn \$a[0] + \$a[99];", 'start_runs' );
    my $out    = qx["$wasmtime_path" run "$ok" 2>&1];
    my $status = $?;
    is( $status, 0, 'wasmtime run executes the module as a command, with no _start argument on the command line' ) or diag $out;
    unlike( $out, qr/unreachable/, 'a heap-using program does not trap on the _start path' );
    unlink $ok;
    my $trap = build_wasm( 'return 42;', 'start_trap', TrapStart->new );
    my $tout = qx["$wasmtime_path" run "$trap" 2>&1];
    isnt( $?, 0, 'a _start that traps fails the run, so a clean exit really does mean the entry ran' );
    like( $tout, qr/unreachable/, 'and the failure is the trap, not a parse error' );
    unlink $trap;
}
done_testing;
