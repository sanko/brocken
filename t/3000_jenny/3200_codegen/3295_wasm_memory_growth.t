use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
use Test2::Tools::Brocken qw(temp_path);
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $host          = Brocken::Katsuro::Platform::parse();
my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');

# The linker declares a single 64 KiB page of linear memory and no maximum, so a
# module *can* ask for more at runtime, but nothing did: `_init` recorded a
# 1 MiB limit against memory that did not exist, and the first write past the
# declared page trapped with no diagnostic. `bump_alloc` now grows on demand
# through the `memory_grow` intrinsic, and `_init` starts from the size the host
# actually granted so the limit is never a lie.
#
# Growing is not unbounded: the 1 MiB the host asked for is kept as a cap, so an
# allocation past it is refused (0) rather than quietly asking the host for
# whatever it takes. Native builds have a fixed host-carved region, `memory_size`
# reports 0 there, and `memory_grow` lowers to a constant -1, which routes those
# allocations down the same refusal path.
sub build_wasm {
    my ( $src, $name ) = @_;
    my $module  = Brocken::Compiler->new->compile($src);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $out     = temp_path($name) . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $out, $codegen->emit_functions( $module->functions ), $platform );
    return $out;
}

sub run_wasm {
    my ( $src, $name ) = @_;
    my $file = build_wasm( $src, $name );
    my $out  = qx["$wasmtime_path" run --invoke _BROCKEN_ENTRY "$file" 1024 2>&1];
    $out =~ s/^warning: using .*$//mg;
    $out =~ s/^\s+|\s+$//g;
    $out =~ s/\s*\n\s*/ | /g;
    unlink $file;
    return $out;
}

# --- The lowering: checkable without wasmtime -------------------------------
# `lower_intrinsic` built a store *before* dispatching on the intrinsic name, so
# every intrinsic that was not `ptr_add`..`load_i64` emitted a store with
# undefined operands ahead of its real instruction. `store_i64` got away with it
# only because the unconditional store happened to be the correct one, and
# `load_i32` had been unusable for the same reason. It surfaces as a backend
# crash on an undefined value rather than a miscompile, so it is worth pinning
# even though the runtime only needs `store_i64`.
{
    my $module = eval {
        Brocken::Compiler->new->compile(<<'BROCKEN');
my i32 $a = 1024;
my i32 $loaded = Brocken::load_i32($a);
my i32 $pages  = Brocken::memory_size();
my i32 $grew   = Brocken::memory_grow(1);
return $loaded + $pages + $grew;
BROCKEN
    };
    ok( $module, 'load_i32 and the memory intrinsics all lower' ) or diag $@;
    my @broken;
    for my $fn ( $module->functions->@* ) {
        for my $bb ( $fn->blocks->@* ) {
            for my $inst ( $bb->instructions->@* ) {
                for my $operand ( $inst->operands->@* ) {
                    push @broken, $fn->name . '/' . $inst->opcode if !defined $operand;
                }
            }
        }
    }
    is( \@broken, [], 'no instruction is left with an undefined operand' );
}

sub opcodes_of {
    my ($mf) = @_;
    my %opcodes;
    for my $mbb ( $mf->blocks->@* ) {
        $opcodes{ $_->opcode }++ for $mbb->instructions->@*;
    }
    return \%opcodes;
}

# The runtime has to actually reach the host.
{
    my $module  = Brocken::Compiler->new->compile('return 1;');
    my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
    my ($fn)    = grep { $_->name eq 'Brocken::Runtime::bump_alloc' } $module->functions->@*;
    my $sizes   = opcodes_of( $lowerer->lower($fn) );
    ok( $sizes->{memory_grow}, 'bump_alloc emits a memory.grow' );
    ok( $sizes->{memory_size}, 'bump_alloc asks the host how much memory it has' );
}

# `_init` seeds the cap from the heap the host asked for, and starts the limit
# at the memory that actually exists rather than eagerly growing to the cap.
{
    my $module  = Brocken::Compiler->new->compile('return 1;');
    my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
    my ($fn)    = grep { $_->name eq 'Brocken::Runtime::_init' } $module->functions->@*;
    my $sizes   = opcodes_of( $lowerer->lower($fn) );
    ok( $sizes->{memory_size},  '_init reads the granted memory size' );
    ok( !$sizes->{memory_grow}, '_init does not eagerly grow' );
}

# --- Execution --------------------------------------------------------------
my @cases = (

    # 30000 eight-byte objects is 240000 bytes: four times the single page the
    # linker declares, and each allocation past that page has to grow memory to
    # succeed. Before this, the run trapped partway through the loop.
    {   name => '30000 objects past the declared page grow memory',
        prog => <<'BROCKEN',
class P { field i64 $x :param :reader; }
BROCKEN
        tail => <<'BROCKEN',
my i64 $i = 0;
my i64 $t = 0;
while ($i < 30000) { my ptr $p = P->new($i); $t = $t + $p->x(); $i = $i + 1; }
return $t;
BROCKEN
        want => 449985000,
    },

    # A single block that starts inside one page and ends far outside it: this is
    # the case a limit seeded at heap_base + 1MiB would happily hand out without
    # ever asking the host, and it wrote out of bounds.
    {   name => 'one allocation spanning four pages is backed',
        prog => '',
        tail =>
            'my ptr $p = Brocken::Runtime::bump_alloc(1024, 900000); if ($p == 0) { return -1; } Brocken::store_i64($p, 42); return Brocken::load_i64($p);',
        want => 42,
    },

    # Growth is bounded by the heap the host asked for. A block past the cap is
    # refused instead of asking the host for however much it takes.
    {   name => 'an allocation past the 1MiB cap is refused',
        prog => '',
        tail => 'my ptr $p = Brocken::Runtime::bump_alloc(1024, 2097152); if ($p == 0) { return -1; } return 42;',
        want => -1,
    },

    # Escaping array slots used to be allocated by a second, module-local bump
    # cursor (`%heap_ptr`) rather than the runtime allocator. Both cursors
    # started at the heap base, so an array and an object could be handed the
    # same bytes -- a four-element array read back 111, 0 once enough objects
    # followed it -- and because that cursor had neither limit nor growth, any
    # array past the declared 64 KiB page trapped. Arrays now go through
    # `bump_alloc` like every other heap block: one cursor, one growth path, one
    # cap. This asserts the two no longer overlap.
    {   name => 'an array and the objects after it do not collide',
        prog => <<'BROCKEN',
class P { field i64 $x :param :reader; }
BROCKEN
        tail => <<'BROCKEN',
my [i64; 4] $a;
$a[0] = 111;
$a[1] = 222;
my i64 $i = 0;
my i64 $t = 0;
while ($i < 30000) { my ptr $p = P->new($i); $t = $t + $p->x(); $i = $i + 1; }
if ($a[0] != 111) { return 90; }
if ($a[1] != 222) { return 91; }
return $t;
BROCKEN
        want => 449985000,
    },

    # The case the uncapped cursor could not serve at all: a 128 KiB array, well
    # past the single declared page, now grows memory to be backed.
    {   name => 'an array larger than the declared page is backed',
        prog => '',
        tail => 'my [i64; 16384] $a; $a[0] = 7; $a[16383] = 9; if ($a[0] + $a[16383] != 16) { return 90; } return 11;',
        want => 11,
    },

    # Routing arrays through the shared allocator also puts them under the cap
    # the host asked for. This asserts the header is intact after an array: a
    # 2 MiB request is still refused, which only holds if `cap` survived.
    {   name => 'the cap still holds after an array is used',
        prog => '',
        tail => 'my [i64; 4] $a; $a[0] = 1; my ptr $p = Brocken::Runtime::bump_alloc(1024, 2097152); if ($p == 0) { return -1; } return 42;',
        want => -1,
    },
);
for my $case (@cases) {
SKIP: {
        skip 'wasmtime not available', 1 unless $wasmtime_path && -f $wasmtime_path;
        is( run_wasm( $case->{prog} . $case->{tail}, 'wasm_memgrow_exec' ), $case->{want}, "$case->{name}: returns $case->{want}" );
    }
}

# An exhausted allocator returns 0, and the class call site now checks that
# before the constructor writes to it. Unchecked, the constructor stored through
# a null pointer, which on wasm is a wild write rather than the allocation
# failure it is -- so this asserts the run *fails* instead of returning a value.
SKIP: {
    skip 'wasmtime not available', 1 unless $wasmtime_path && -f $wasmtime_path;

    # 2MiB of objects overflows the 1MiB cap partway through.
    my $out = run_wasm( <<'BROCKEN', 'wasm_memgrow_oom' );
class P { field i64 $x :param :reader; }
my i64 $i = 0;
my i64 $t = 0;
while ($i < 400000) { my ptr $p = P->new($i); $t = $t + $p->x(); $i = $i + 1; }
return $t;
BROCKEN
    isnt( $out, '', 'a class allocation past the cap does not quietly succeed' );

    # The same refusal, reached through the shared allocator by an array rather
    # than a constructor. 1.6 MiB of array is past the 1 MiB cap, so the slot
    # allocation is refused and `check_alloc` traps instead of the run returning.
    my $arr = run_wasm( <<'BROCKEN', 'wasm_memgrow_array_oom' );
my [i64; 200000] $a;
$a[0] = 1;
return 42;
BROCKEN
    isnt( $arr, '', 'an array past the cap is refused rather than writing past the heap' );
}

# --- Native -----------------------------------------------------------------
# A native build has a fixed host-carved region rather than a page it can grow,
# so `memory_size` reports 0 and `memory_grow` lowers to a constant -1. Both are
# asserted through behaviour rather than a hardcoded heap base: on native the base
# is a real `__heap_base` symbol, so passing 1024 as the Wasm entry does would be
# pointing at the PE image itself.
{
    my $brocken = Brocken->new();
SKIP: {
        skip 'Not native', 4 unless $brocken->platform->is_native;
        my $run = sub {
            my ( $name, $src, $want ) = @_;
            my $module = Brocken::Compiler->new->compile($src);
            my $funcs  = $brocken->codegen->emit_functions( $module->functions );
            my $file   = $brocken->tmpdir . "/$name" . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
            system $file;
            is( $? >> 8, $want, "native: $name returns $want" );
        };
        $run->( 'memgrow_size', <<'BROCKEN', 7 );
my i32 $pages = Brocken::memory_size();
if ($pages == 0) { return 7; }
return 9;
BROCKEN

        # Returning the refusal directly rather than comparing it: comparing an
        # i32 against a negative literal is broken independently of this work
        # (`my i32 $g = -1; if ($g == -1)` is false), so an equality test here
        # would be measuring that bug instead. -1 truncates to 255 as an exit
        # code, which is the refusal.
        $run->( 'memgrow_refuse', "return Brocken::memory_grow(1);\n", 255 );
    }
}
done_testing;
